import Foundation
import LocalAuthentication
import Security

enum FirebasePreferences {
    static let databaseURLKey = "firebaseDatabaseURL"
    static let apiKeyKey = "firebaseAPIKey"
    static let emailKey = "firebaseEmail"
    static let enabledKey = "firebaseSyncEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? hasProjectConfiguration
    }

    static var hasProjectConfiguration: Bool {
        let defaults = UserDefaults.standard
        return !(defaults.string(forKey: databaseURLKey) ?? "").isEmpty
            && !(defaults.string(forKey: apiKeyKey) ?? "").isEmpty
    }

    static var isConfigured: Bool {
        isEnabled && hasProjectConfiguration && FirebaseSessionStore.exists()
    }
}

struct FirebaseAuthSession: Codable, Sendable {
    var idToken: String
    var refreshToken: String
    let userID: String
}

private enum FirebaseSessionStore {
    private static let service = "com.wiktorjarochiewicz.taskboard.firebase.v1"
    private static let account = "session"

    static func exists() -> Bool {
        var query = nonInteractiveQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func load() -> FirebaseAuthSession? {
        var query = nonInteractiveQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            NSLog("taskboard Firebase Keychain session unavailable: %d", status)
            return nil
        }
        return try? JSONDecoder().decode(FirebaseAuthSession.self, from: data)
    }

    static func save(_ session: FirebaseAuthSession) throws {
        let data = try JSONEncoder().encode(session)
        let query = nonInteractiveQuery
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(updated))
        }
        var item = query
        item.removeValue(forKey: kSecUseAuthenticationContext as String)
        item[kSecValueData as String] = data
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func clear() {
        SecItemDelete(nonInteractiveQuery as CFDictionary)
    }

    private static var nonInteractiveQuery: [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: context,
        ]
    }
}

@MainActor
final class FirebaseSyncService {
    private struct SignInResponse: Decodable {
        let idToken: String
        let refreshToken: String
        let localId: String
    }

    private struct RefreshResponse: Decodable {
        let idToken: String
        let refreshToken: String
        let userId: String

        private enum CodingKeys: String, CodingKey {
            case idToken = "id_token"
            case refreshToken = "refresh_token"
            case userId = "user_id"
        }
    }

    private struct SnapshotEnvelope: Codable {
        let payload: TaskBoardSnapshot
        let updatedAt: Double
    }

    private struct PendingUpload: Codable {
        let databaseURL: String
        let userID: String?
        let email: String?
        let snapshot: TaskBoardSnapshot
        var baseline: TaskBoardSnapshot?
    }

    static var defaultPendingUploadURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("taskboard/firebase-pending-upload.json")
    }

    /// Keep offline edits even when the saved sign-in is temporarily inaccessible.
    static func stagePendingUpload(_ snapshot: TaskBoardSnapshot, databaseURL: URL, email: String, at url: URL) throws {
        let pending = PendingUpload(databaseURL: databaseURL.absoluteString, userID: nil, email: email, snapshot: snapshot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(pending).write(to: url, options: .atomic)
    }

    private let databaseURL: URL
    private let apiKey: String
    private var session: FirebaseAuthSession
    private var streamTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var lastSyncedSnapshot: TaskBoardSnapshot?
    /// The cloud `updatedAt` of the last snapshot this process read or wrote.
    private var lastRemoteUpdatedAt: Double?
    var onSavedSnapshot: (@MainActor (TaskBoardSnapshot) -> Void)?
    private var queuedSnapshot: TaskBoardSnapshot?
    private var queuedWaiters: [CheckedContinuation<Void, Error>] = []
    var onSyncResult: (@MainActor (Result<Void, Error>) -> Void)?
    private var isSaving = false
    private(set) var requiresSignIn = false
    private var stopped = false
    private var refreshTask: Task<FirebaseAuthSession, Error>?
    private let pendingUploadURL: URL?
    private let accountEmail: String?
    private let debounceDelay: Duration
    private let retryDelay: Duration
    private let requestData: @MainActor (URLRequest) async throws -> (Data, URLResponse)
    private let persistSession: @MainActor (FirebaseAuthSession) async throws -> Void
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    var hasPendingSave: Bool {
        debounceTask != nil || queuedSnapshot != nil || isSaving
    }

    static func configured() async -> FirebaseSyncService? {
        let defaults = UserDefaults.standard
        guard let rawURL = defaults.string(forKey: FirebasePreferences.databaseURLKey),
              let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https",
              let key = defaults.string(forKey: FirebasePreferences.apiKeyKey),
              !key.isEmpty else {
            return nil
        }
        // The legacy macOS Keychain can block for approval even with a
        // noninteractive LAContext. Never make AppKit wait for that operation.
        guard let session = await Task.detached(priority: .userInitiated, operation: {
            FirebaseSessionStore.load()
        }).value else { return nil }
        return FirebaseSyncService(
            databaseURL: url,
            apiKey: key,
            session: session,
            pendingUploadURL: Self.defaultPendingUploadURL,
            accountEmail: defaults.string(forKey: FirebasePreferences.emailKey),
            persistSession: { session in
                try await Task.detached { try FirebaseSessionStore.save(session) }.value
            }
        )
    }

    init(
        databaseURL: URL,
        apiKey: String,
        session: FirebaseAuthSession,
        pendingUploadURL: URL? = nil,
        accountEmail: String? = nil,
        debounceDelay: Duration = .milliseconds(650),
        retryDelay: Duration = .seconds(3),
        requestData: @escaping @MainActor (URLRequest) async throws -> (Data, URLResponse) = {
            try await URLSession.shared.data(for: $0)
        },
        persistSession: @escaping @MainActor (FirebaseAuthSession) async throws -> Void = { _ in }
    ) {
        self.databaseURL = databaseURL
        self.apiKey = apiKey
        self.session = session
        self.pendingUploadURL = pendingUploadURL
        self.accountEmail = accountEmail
        self.debounceDelay = debounceDelay
        self.retryDelay = retryDelay
        self.requestData = requestData
        self.persistSession = persistSession
        if let pendingUploadURL,
           let data = try? Data(contentsOf: pendingUploadURL),
           let pending = try? decoder.decode(PendingUpload.self, from: data),
           pending.databaseURL == databaseURL.absoluteString,
           (pending.userID == session.userID ||
            (pending.userID == nil && pending.email == accountEmail && !(accountEmail ?? "").isEmpty)) {
            queuedSnapshot = pending.snapshot
            lastSyncedSnapshot = pending.baseline
        }
    }

    deinit {
        streamTask?.cancel()
        debounceTask?.cancel()
        refreshTask?.cancel()
    }

    func stop() {
        stopped = true
        streamTask?.cancel()
        debounceTask?.cancel()
        refreshTask?.cancel()
        queuedWaiters.forEach { $0.resume(throwing: CancellationError()) }
        queuedWaiters.removeAll()
    }

    static func authenticate(
        databaseURL: String,
        apiKey: String,
        email: String,
        password: String,
        createAccount: Bool
    ) async throws {
        guard let baseURL = URL(string: databaseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              baseURL.scheme == "https" else {
            throw URLError(.badURL)
        }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let operation = createAccount ? "signUp" : "signInWithPassword"
        var components = URLComponents(string: "https://identitytoolkit.googleapis.com/v1/accounts:\(operation)")
        components?.queryItems = [URLQueryItem(name: "key", value: key)]
        guard let url = components?.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "email": email,
            "password": password,
            "returnSecureToken": true,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        let auth = try JSONDecoder().decode(SignInResponse.self, from: data)
        let session = FirebaseAuthSession(
            idToken: auth.idToken,
            refreshToken: auth.refreshToken,
            userID: auth.localId
        )
        try await Task.detached { try FirebaseSessionStore.save(session) }.value
        let defaults = UserDefaults.standard
        defaults.set(baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")), forKey: FirebasePreferences.databaseURLKey)
        defaults.set(key, forKey: FirebasePreferences.apiKeyKey)
        defaults.set(email.trimmingCharacters(in: .whitespacesAndNewlines), forKey: FirebasePreferences.emailKey)
        defaults.set(true, forKey: FirebasePreferences.enabledKey)
    }

    static func disconnect() {
        FirebaseSessionStore.clear()
        UserDefaults.standard.set(false, forKey: FirebasePreferences.enabledKey)
    }

    func fetchSnapshot() async throws -> TaskBoardSnapshot? {
        let data = try await authenticatedRequest(path: snapshotPath)
        if data == Data("null".utf8) { return nil }
        let envelope = try decoder.decode(SnapshotEnvelope.self, from: data)
        if !hasPendingSave {
            lastSyncedSnapshot = envelope.payload
            lastRemoteUpdatedAt = envelope.updatedAt
        }
        return envelope.payload
    }

    /// A tiny request that backs up the realtime stream, which can silently
    /// miss events across sleep, network changes, and token expiry.
    func remoteChangedSinceLastRead() async throws -> Bool {
        let data = try await authenticatedRequest(path: snapshotPath + "/updatedAt")
        let value = (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) as? NSNumber
        return value?.doubleValue != lastRemoteUpdatedAt
    }

    func save(snapshot: TaskBoardSnapshot) async throws {
        try await withCheckedThrowingContinuation { continuation in
            do {
                try enqueue(snapshot)
                guard !requiresSignIn else { throw Self.signInRequiredError }
                queuedWaiters.append(continuation)
                scheduleFlush(after: .zero)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func upload(snapshot: TaskBoardSnapshot) async throws -> TaskBoardSnapshot {
        for _ in 0..<8 {
            let (data, response) = try await authenticatedResponse(path: snapshotPath, headers: ["X-Firebase-ETag": "true"])
            guard let etag = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag") else {
                throw URLError(.badServerResponse)
            }
            let remote = data == Data("null".utf8) ? nil : try decoder.decode(SnapshotEnvelope.self, from: data)
            let merged = remote.map { snapshot.mergingCloudChanges(from: $0.payload, since: lastSyncedSnapshot) } ?? snapshot
            let envelope = SnapshotEnvelope(payload: merged.cloudRepresentation,
                updatedAt: max(Date.now.timeIntervalSince1970 * 1_000, (remote?.updatedAt ?? 0) + 1))
            do {
                _ = try await authenticatedResponse(path: snapshotPath, method: "PUT",
                    body: try encoder.encode(envelope), headers: ["if-match": etag])
                lastRemoteUpdatedAt = envelope.updatedAt
                return merged
            } catch let error as NSError where error.domain == "taskboard.firebase" && error.code == 412 {
                continue // Another device or the agent wrote after our read.
            }
        }
        throw NSError(domain: "taskboard.firebase", code: 412,
                      userInfo: [NSLocalizedDescriptionKey: "Tasks changed during sync. Retrying shortly."])
    }

    func startRealtime(
        onSnapshot: @escaping @MainActor (TaskBoardSnapshot) -> Void,
        onError: @escaping @MainActor (Error) -> Void = { _ in }
    ) {
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            while !Task.isCancelled, let self, !self.stopped {
                do {
                    try await self.consumeStream(onSnapshot: onSnapshot)
                } catch is CancellationError {
                    return
                } catch {
                    if Task.isCancelled { return }
                    onError(error)
                    NSLog("taskboard Firebase stream error: %@", error.localizedDescription)
                    do { try await self.refreshSession() } catch { onError(error) }
                    if self.requiresSignIn { return }
                }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }

    func scheduleSave(
        snapshot: TaskBoardSnapshot,
        completion: @escaping @MainActor (Result<Void, Error>) -> Void
    ) {
        onSyncResult = completion
        do {
            try enqueue(snapshot)
            guard !requiresSignIn else { throw Self.signInRequiredError }
            scheduleFlush(after: debounceDelay)
        } catch {
            completion(.failure(error))
        }
    }

    private func enqueue(_ snapshot: TaskBoardSnapshot) throws {
        if let pendingUploadURL {
            let pending = PendingUpload(databaseURL: databaseURL.absoluteString, userID: session.userID, email: accountEmail, snapshot: snapshot, baseline: lastSyncedSnapshot)
            try FileManager.default.createDirectory(at: pendingUploadURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(pending).write(to: pendingUploadURL, options: .atomic)
        }
        queuedSnapshot = snapshot
    }

    private func scheduleFlush(after delay: Duration) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                self.debounceTask = nil
                await self.flushSaveQueue()
            } catch {
                return
            }
        }
    }

    private var snapshotPath: String {
        "taskboardSnapshots/\(session.userID)"
    }

    private func flushSaveQueue() async {
        guard !stopped, !isSaving, let snapshot = queuedSnapshot else { return }
        let waiters = queuedWaiters
        queuedWaiters.removeAll()
        queuedSnapshot = nil
        isSaving = true
        do {
            let saved = try await upload(snapshot: snapshot)
            lastSyncedSnapshot = saved
            if let queued = queuedSnapshot {
                queuedSnapshot = queued.mergingExternalChanges(from: saved, since: snapshot)
                if let pendingUploadURL {
                    let pending = PendingUpload(databaseURL: databaseURL.absoluteString, userID: session.userID,
                        email: accountEmail, snapshot: queuedSnapshot!, baseline: saved)
                    try encoder.encode(pending).write(to: pendingUploadURL, options: .atomic)
                }
            }
            isSaving = false
            waiters.forEach { $0.resume() }
            if queuedSnapshot == nil {
                if let pendingUploadURL { try? FileManager.default.removeItem(at: pendingUploadURL) }
                onSavedSnapshot?(saved)
                onSyncResult?(.success(()))
            }
        } catch {
            isSaving = false
            if queuedSnapshot == nil { queuedSnapshot = snapshot }
            waiters.forEach { $0.resume(throwing: error) }
            onSyncResult?(.failure(error))
            NSLog("taskboard Firebase upload error: %@", error.localizedDescription)
            if !stopped && !requiresSignIn { scheduleFlush(after: retryDelay) }
            return
        }
        if queuedSnapshot != nil {
            debounceTask?.cancel()
            debounceTask = nil
            await flushSaveQueue()
        }
    }

    private func consumeStream(
        onSnapshot: @escaping @MainActor (TaskBoardSnapshot) -> Void
    ) async throws {
        let url = try authenticatedURL(path: snapshotPath)
        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "taskboard.firebase", code: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        var event = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if line.hasPrefix("event:") {
                event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                if event == "auth_revoked" || event == "cancel" {
                    throw URLError(.userAuthenticationRequired)
                }
                continue
            }
            guard line.hasPrefix("data:"), event == "put" || event == "patch" else { continue }
            event = ""
            guard !hasPendingSave, let remote = try await fetchSnapshot() else { continue }
            onSnapshot(remote)
        }
    }

    private func authenticatedRequest(path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        try await authenticatedResponse(path: path, method: method, body: body).0
    }

    private func authenticatedResponse(
        path: String,
        method: String = "GET",
        body: Data? = nil,
        headers: [String: String] = [:],
        canRetry: Bool = true
    ) async throws -> (Data, URLResponse) {
        guard !requiresSignIn else { throw Self.signInRequiredError }
        let url = try authenticatedURL(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await requestData(request)
        if (response as? HTTPURLResponse)?.statusCode == 401, canRetry {
            try await refreshSession()
            return try await authenticatedResponse(path: path, method: method, body: body, headers: headers, canRetry: false)
        }
        try Self.validate(response: response, data: data)
        return (data, response)
    }

    private func authenticatedURL(path: String) throws -> URL {
        let base = databaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var components = URLComponents(string: "\(base)/\(path).json")
        components?.queryItems = [URLQueryItem(name: "auth", value: session.idToken)]
        guard let url = components?.url else { throw URLError(.badURL) }
        return url
    }

    private func refreshSession() async throws {
        if let refreshTask {
            session = try await refreshTask.value
            return
        }
        let refreshTask = Task { try await self.fetchRefreshedSession() }
        self.refreshTask = refreshTask
        defer { self.refreshTask = nil }
        session = try await refreshTask.value
        try await persistSession(session)
    }

    private func fetchRefreshedSession() async throws -> FirebaseAuthSession {
        var components = URLComponents(string: "https://securetoken.googleapis.com/v1/token")
        components?.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components?.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let formCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encodedToken = session.refreshToken.addingPercentEncoding(withAllowedCharacters: formCharacters) ?? session.refreshToken
        request.httpBody = Data("grant_type=refresh_token&refresh_token=\(encodedToken)".utf8)
        let (data, response) = try await requestData(request)
        do {
            try Self.validate(response: response, data: data)
        } catch {
            let code = (error as NSError).localizedDescription
            if ["TOKEN_EXPIRED", "INVALID_REFRESH_TOKEN", "USER_DISABLED", "USER_NOT_FOUND", "INVALID_GRANT"].contains(code) {
                requiresSignIn = true
                throw Self.signInRequiredError
            }
            throw error
        }
        let auth = try decoder.decode(RefreshResponse.self, from: data)
        guard auth.userId == session.userID else { throw URLError(.userAuthenticationRequired) }
        return .init(idToken: auth.idToken, refreshToken: auth.refreshToken, userID: auth.userId)
    }

    private static var signInRequiredError: NSError {
        NSError(domain: "taskboard.firebase", code: 401, userInfo: [NSLocalizedDescriptionKey:
            "Firebase session expired. Sign in again in Settings → Firebase Sync"])
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["error"] as? [String: Any] }
                .flatMap { $0["message"] as? String }
                ?? "Firebase request failed"
            throw NSError(
                domain: "taskboard.firebase",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }
}
