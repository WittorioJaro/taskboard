import Foundation
import Security

enum SupabasePreferences {
    static let urlKey = "supabaseProjectURL"
    static let anonKeyKey = "supabaseAnonKey"
    static let emailKey = "supabaseEmail"

    static var isConfigured: Bool {
        let defaults = UserDefaults.standard
        return !(defaults.string(forKey: urlKey) ?? "").isEmpty
            && !(defaults.string(forKey: anonKeyKey) ?? "").isEmpty
            && SupabaseSessionStore.load() != nil
    }
}

private struct SupabaseAuthSession: Codable {
    let accessToken: String
    let refreshToken: String
    let userID: UUID
}

private enum SupabaseSessionStore {
    private static let service = "com.wiktorjarochiewicz.taskboard.supabase"
    private static let account = "session"

    static func load() -> SupabaseAuthSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(SupabaseAuthSession.self, from: data)
    }

    static func save(_ session: SupabaseAuthSession) throws {
        let data = try JSONEncoder().encode(session)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
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

    private struct SnapshotRow: Decodable { let payload: TaskBoardSnapshot }
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
            URLQueryItem(name: "select", value: "payload"),
        ])
        let data = try await authenticatedRequest(url: url)
        return try decoder.decode([SnapshotRow].self, from: data).first?.payload
    }

    func save(snapshot: TaskBoardSnapshot) async throws {
        let url = baseURL.appending(path: "rest/v1/taskboard_snapshots").appending(queryItems: [
            URLQueryItem(name: "on_conflict", value: "owner_id,id"),
        ])
        let body = try encoder.encode(SnapshotUpsert(ownerID: session.userID, payload: snapshot))
        _ = try await authenticatedRequest(
            url: url,
            method: "POST",
            body: body,
            headers: ["Prefer": "resolution=merge-duplicates,return=minimal"]
        )
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
