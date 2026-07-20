import Foundation
import LocalAuthentication
import Realtime
import Security

enum SupabasePreferences {
    static let urlKey = "supabaseProjectURL"
    static let anonKeyKey = "supabaseAnonKey"
    static let emailKey = "supabaseEmail"

    static var hasProjectConfiguration: Bool {
        let defaults = UserDefaults.standard
        return !(defaults.string(forKey: urlKey) ?? "").isEmpty
            && !(defaults.string(forKey: anonKeyKey) ?? "").isEmpty
    }

    static var isConfigured: Bool {
        hasProjectConfiguration && SupabaseSessionStore.load() != nil
    }
}

private struct SupabaseAuthSession: Codable {
    let accessToken: String
    let refreshToken: String
    let userID: UUID
}

private enum SupabaseSessionStore {
    private static let service = "com.wiktorjarochiewicz.taskboard.supabase.v2"
    private static let account = "session"

    static func load() -> SupabaseAuthSession? {
        if let migrationURL,
           let data = try? Data(contentsOf: migrationURL),
           let session = try? JSONDecoder().decode(SupabaseAuthSession.self, from: data) {
            do {
                try save(session)
                try? FileManager.default.removeItem(at: migrationURL)
            } catch {
                NSLog("taskboard session migration error: \(error.localizedDescription)")
            }
            return session
        }

        if let session = load(service: service) {
            return session
        }
        return nil
    }

    private static func load(service: String) -> SupabaseAuthSession? {
        var query = nonInteractiveQuery(service: service)
        query.merge([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { _, new in new }
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(SupabaseAuthSession.self, from: data)
    }

    static func save(_ session: SupabaseAuthSession) throws {
        let data = try JSONEncoder().encode(session)
        let query = nonInteractiveQuery(service: service)
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
        let query = nonInteractiveQuery(service: service)
        SecItemDelete(query as CFDictionary)
        if let migrationURL {
            try? FileManager.default.removeItem(at: migrationURL)
        }
    }

    private static var migrationURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("taskboard", isDirectory: true)
            .appendingPathComponent("supabase-session-migration.json", isDirectory: false)
    }

    private static func nonInteractiveQuery(service: String) -> [String: Any] {
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
final class SupabaseSyncService {
    private struct AuthResponse: Decodable {
        struct User: Decodable { let id: UUID }
        let accessToken: String
        let refreshToken: String
        let user: User

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case user
        }
    }

    private struct SnapshotRow: Decodable {
        let payload: TaskBoardSnapshot
        let updatedAt: String

        private enum CodingKeys: String, CodingKey {
            case payload
            case updatedAt = "updated_at"
        }
    }
    private struct SnapshotVersionRow: Decodable {
        let updatedAt: String

        private enum CodingKeys: String, CodingKey {
            case updatedAt = "updated_at"
        }
    }
    private struct SnapshotUpsert: Encodable {
        let ownerID: UUID
        let id = "primary"
        let payload: TaskBoardSnapshot
        let updatedAt = ISO8601DateFormatter().string(from: .now)

        private enum CodingKeys: String, CodingKey {
            case ownerID = "owner_id"
            case id, payload
            case updatedAt = "updated_at"
        }
    }

    private let baseURL: URL
    private let anonKey: String
    private var session: SupabaseAuthSession
    private let realtimeClient: RealtimeClientV2
    private var realtimeChannel: RealtimeChannelV2?
    private var realtimeSubscriptions: Set<RealtimeSubscription> = []
    private var lastKnownUpdatedAt: String?
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
        guard let rawURL = defaults.string(forKey: SupabasePreferences.urlKey),
              let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = defaults.string(forKey: SupabasePreferences.anonKeyKey),
              !key.isEmpty,
              let session = SupabaseSessionStore.load() else {
            return nil
        }
        baseURL = url
        anonKey = key
        self.session = session
        realtimeClient = RealtimeClientV2(
            url: url.appending(path: "realtime/v1"),
            options: RealtimeClientOptions(headers: [
                "apikey": key,
                "Authorization": "Bearer \(session.accessToken)",
            ])
        )
    }

    static func signIn(projectURL: String, anonKey: String, email: String, password: String) async throws {
        guard let baseURL = URL(string: projectURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw URLError(.badURL)
        }
        let url = baseURL.appending(path: "auth/v1/token").appending(queryItems: [
            URLQueryItem(name: "grant_type", value: "password"),
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        let auth = try JSONDecoder().decode(AuthResponse.self, from: data)
        try SupabaseSessionStore.save(.init(
            accessToken: auth.accessToken,
            refreshToken: auth.refreshToken,
            userID: auth.user.id
        ))
        let defaults = UserDefaults.standard
        defaults.set(projectURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: SupabasePreferences.urlKey)
        defaults.set(anonKey.trimmingCharacters(in: .whitespacesAndNewlines), forKey: SupabasePreferences.anonKeyKey)
        defaults.set(email.trimmingCharacters(in: .whitespacesAndNewlines), forKey: SupabasePreferences.emailKey)
    }

    static func disconnect() {
        SupabaseSessionStore.clear()
    }

    func fetchSnapshot() async throws -> TaskBoardSnapshot? {
        let url = baseURL.appending(path: "rest/v1/taskboard_snapshots").appending(queryItems: [
            URLQueryItem(name: "owner_id", value: "eq.\(session.userID.uuidString.lowercased())"),
            URLQueryItem(name: "id", value: "eq.primary"),
            URLQueryItem(name: "select", value: "payload,updated_at"),
        ])
        let data = try await authenticatedRequest(url: url)
        guard let row = try decoder.decode([SnapshotRow].self, from: data).first else {
            lastKnownUpdatedAt = nil
            return nil
        }
        lastKnownUpdatedAt = row.updatedAt
        return row.payload
    }

    func fetchSnapshotIfChanged() async throws -> TaskBoardSnapshot? {
        let url = baseURL.appending(path: "rest/v1/taskboard_snapshots").appending(queryItems: [
            URLQueryItem(name: "owner_id", value: "eq.\(session.userID.uuidString.lowercased())"),
            URLQueryItem(name: "id", value: "eq.primary"),
            URLQueryItem(name: "select", value: "updated_at"),
        ])
        let data = try await authenticatedRequest(url: url)
        guard let version = try decoder.decode([SnapshotVersionRow].self, from: data).first?.updatedAt else {
            return nil
        }
        guard version != lastKnownUpdatedAt else { return nil }
        return try await fetchSnapshot()
    }

    func save(snapshot: TaskBoardSnapshot) async throws {
        let url = baseURL.appending(path: "rest/v1/taskboard_snapshots").appending(queryItems: [
            URLQueryItem(name: "on_conflict", value: "owner_id,id"),
            URLQueryItem(name: "select", value: "updated_at"),
        ])
        let body = try encoder.encode(SnapshotUpsert(
            ownerID: session.userID,
            payload: snapshot.cloudRepresentation
        ))
        let data = try await authenticatedRequest(
            url: url,
            method: "POST",
            body: body,
            headers: ["Prefer": "resolution=merge-duplicates,return=representation"]
        )
        lastKnownUpdatedAt = try decoder.decode([SnapshotVersionRow].self, from: data).first?.updatedAt
    }

    func startRealtime(
        onSnapshot: @escaping @MainActor (TaskBoardSnapshot) -> Void
    ) async throws {
        guard realtimeChannel == nil else { return }

        let ownerFilter = "owner_id=eq.\(session.userID.uuidString.lowercased())"
        let channel = realtimeClient.channel("taskboard:\(session.userID.uuidString.lowercased())")
        realtimeChannel = channel

        channel.onPostgresChange(
            InsertAction.self,
            schema: "public",
            table: "taskboard_snapshots",
            filter: ownerFilter
        ) { [weak self] action in
            Task { @MainActor [weak self] in
                self?.handleRealtimeRecord(action.record, onSnapshot: onSnapshot)
            }
        }
        .store(in: &realtimeSubscriptions)

        channel.onPostgresChange(
            UpdateAction.self,
            schema: "public",
            table: "taskboard_snapshots",
            filter: ownerFilter
        ) { [weak self] action in
            Task { @MainActor [weak self] in
                self?.handleRealtimeRecord(action.record, onSnapshot: onSnapshot)
            }
        }
        .store(in: &realtimeSubscriptions)

        do {
            try await channel.subscribeWithError()
        } catch {
            realtimeSubscriptions.removeAll()
            realtimeChannel = nil
            await realtimeClient.removeChannel(channel)
            throw error
        }
    }

    private func handleRealtimeRecord(
        _ record: [String: AnyJSON],
        onSnapshot: @MainActor (TaskBoardSnapshot) -> Void
    ) {
        do {
            let row = try record.decode(as: SnapshotRow.self, decoder: decoder)
            lastKnownUpdatedAt = row.updatedAt
            onSnapshot(row.payload)
        } catch {
            NSLog("taskboard realtime decode error: \(error.localizedDescription)")
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
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
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

        // Never overlap writes. If another edit arrived while the request was
        // in flight, persist that newer snapshot only after this one finishes.
        if queuedSnapshot != nil {
            debounceTask?.cancel()
            debounceTask = nil
            await flushSaveQueue()
        }
    }

    private func authenticatedRequest(
        url: URL,
        method: String = "GET",
        body: Data? = nil,
        headers: [String: String] = [:],
        canRetry: Bool = true
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, response) = try await URLSession.shared.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 401, canRetry {
            try await refreshSession()
            return try await authenticatedRequest(
                url: url,
                method: method,
                body: body,
                headers: headers,
                canRetry: false
            )
        }
        try Self.validate(response: response, data: data)
        return data
    }

    private func refreshSession() async throws {
        let url = baseURL.appending(path: "auth/v1/token").appending(queryItems: [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": session.refreshToken])
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response: response, data: data)
        let auth = try decoder.decode(AuthResponse.self, from: data)
        session = .init(accessToken: auth.accessToken, refreshToken: auth.refreshToken, userID: auth.user.id)
        try SupabaseSessionStore.save(session)
        await realtimeClient.setAuth(session.accessToken)
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["msg"] ?? $0["message"] ?? $0["error_description"]) as? String }
                ?? "Supabase request failed"
            throw NSError(
                domain: "taskboard.supabase",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }
}
