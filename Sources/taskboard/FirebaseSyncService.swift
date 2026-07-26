import Foundation
import LocalAuthentication
import Security

enum FirebasePreferences {
    static let databaseURLKey = "firebaseDatabaseURL"
    static let apiKeyKey = "firebaseAPIKey"
    static let emailKey = "firebaseEmail"

    static var hasProjectConfiguration: Bool {
        let defaults = UserDefaults.standard
        return !(defaults.string(forKey: databaseURLKey) ?? "").isEmpty
            && !(defaults.string(forKey: apiKeyKey) ?? "").isEmpty
    }

    static var isConfigured: Bool {
        hasProjectConfiguration && FirebaseSessionStore.load() != nil
    }
}

private struct FirebaseAuthSession: Codable {
    var idToken: String
    var refreshToken: String
    let userID: String
}

private enum FirebaseSessionStore {
    private static let service = "com.wiktorjarochiewicz.taskboard.firebase.v1"
    private static let account = "session"

    static func load() -> FirebaseAuthSession? {
        var query = nonInteractiveQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(FirebaseAuthSession.self, from: data)
    }

    static func save(_ session: FirebaseAuthSession) throws {
        let data = try JSONEncoder().encode(session)
        let query = nonInteractiveQuery
        SecItemDelete(query as CFDictionary)
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

    private let databaseURL: URL
    private let apiKey: String
    private var session: FirebaseAuthSession
    private var streamTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var queuedSnapshot: TaskBoardSnapshot?
    private var queuedCompletion: (@MainActor (Result<Void, Error>) -> Void)?
    private var isSaving = false
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    var hasPendingSave: Bool {
        debounceTask != nil || queuedSnapshot != nil || isSaving
    }

    init?() {
        let defaults = UserDefaults.standard
        guard let rawURL = defaults.string(forKey: FirebasePreferences.databaseURLKey),
              let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https",
              let key = defaults.string(forKey: FirebasePreferences.apiKeyKey),
              !key.isEmpty,
              let session = FirebaseSessionStore.load() else {
            return nil
        }
        databaseURL = url
        apiKey = key
        self.session = session
    }

    deinit {
        streamTask?.cancel()
        debounceTask?.cancel()
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
        try FirebaseSessionStore.save(.init(
            idToken: auth.idToken,
            refreshToken: auth.refreshToken,
            userID: auth.localId
        ))
        let defaults = UserDefaults.standard
        defaults.set(baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")), forKey: FirebasePreferences.databaseURLKey)
        defaults.set(key, forKey: FirebasePreferences.apiKeyKey)
        defaults.set(email.trimmingCharacters(in: .whitespacesAndNewlines), forKey: FirebasePreferences.emailKey)
    }

    static func disconnect() {
        FirebaseSessionStore.clear()
    }

    func fetchSnapshot() async throws -> TaskBoardSnapshot? {
        let data = try await authenticatedRequest(path: snapshotPath)
        if data == Data("null".utf8) { return nil }
        return try decoder.decode(SnapshotEnvelope.self, from: data).payload
    }

    func save(snapshot: TaskBoardSnapshot) async throws {
        let envelope = SnapshotEnvelope(
            payload: snapshot.cloudRepresentation,
            updatedAt: Date.now.timeIntervalSince1970 * 1_000
        )
        _ = try await authenticatedRequest(
            path: snapshotPath,
            method: "PUT",
            body: try encoder.encode(envelope)
        )
    }

    func startRealtime(onSnapshot: @escaping @MainActor (TaskBoardSnapshot) -> Void) {
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            while !Task.isCancelled, let self {
                do {
                    try await self.consumeStream(onSnapshot: onSnapshot)
                } catch is CancellationError {
                    return
                } catch {
                    if Task.isCancelled { return }
                    try? await Task.sleep(for: .seconds(2))
                    try? await self.refreshSession()
                }
            }
        }
    }

    func scheduleSave(
        snapshot: TaskBoardSnapshot,
        completion: @escaping @MainActor (Result<Void, Error>) -> Void
    ) {
        queuedSnapshot = snapshot
        queuedCompletion = completion
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(650))
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
        guard !isSaving, let snapshot = queuedSnapshot else { return }
        let completion = queuedCompletion
        queuedSnapshot = nil
        queuedCompletion = nil
        isSaving = true
        do {
            try await save(snapshot: snapshot)
            isSaving = false
            completion?(.success(()))
        } catch {
            isSaving = false
            completion?(.failure(error))
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
                continue
            }
            guard line.hasPrefix("data:"), event == "put" || event == "patch" else { continue }
            event = ""
            guard !hasPendingSave, let remote = try await fetchSnapshot() else { continue }
            onSnapshot(remote)
        }
    }

    private func authenticatedRequest(
        path: String,
        method: String = "GET",
        body: Data? = nil,
        canRetry: Bool = true
    ) async throws -> Data {
        let url = try authenticatedURL(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 401, canRetry {
            try await refreshSession()
            return try await authenticatedRequest(path: path, method: method, body: body, canRetry: false)
        }
        try Self.validate(response: response, data: data)
        return data
    }

    private func authenticatedURL(path: String) throws -> URL {
        let base = databaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var components = URLComponents(string: "\(base)/\(path).json")
        components?.queryItems = [URLQueryItem(name: "auth", value: session.idToken)]
        guard let url = components?.url else { throw URLError(.badURL) }
        return url
    }

    private func refreshSession() async throws {
        var components = URLComponents(string: "https://securetoken.googleapis.com/v1/token")
        components?.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components?.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let encodedToken = session.refreshToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? session.refreshToken
        request.httpBody = Data("grant_type=refresh_token&refresh_token=\(encodedToken)".utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response: response, data: data)
        let auth = try decoder.decode(RefreshResponse.self, from: data)
        session = .init(idToken: auth.idToken, refreshToken: auth.refreshToken, userID: auth.userId)
        try FirebaseSessionStore.save(session)
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
