import AppKit
import CryptoKit
import Foundation
import Security

struct T3Project: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let workspaceRoot: String
}

struct T3ModelOption: Identifiable, Hashable, Sendable {
    let instanceID: String
    let model: String
    let providerName: String
    let modelLabel: String
    let accentHex: String?

    var id: String { "\(instanceID)/\(model)" }
    var displayTitle: String { "\(modelLabel) · \(providerName)" }
}

struct T3ThreadState: Equatable, Sendable {
    let threadID: String
    let status: String
    let settled: Bool
    let archived: Bool
    let pendingRequestCount: Int
}

struct T3LaunchReceipt: Equatable, Sendable {
    let threadID: String
    let status: String?
}

struct T3FavoriteModel: Equatable, Sendable {
    let instanceID: String
    let model: String
}

enum T3CodeError: LocalizedError, Equatable {
    case serverUnavailable(String)
    case cliMissing
    case authorizationFailed(String)
    case toolFailed(String)
    case invalidResponse(String)
    case boardNotLinked
    case threadNotFound(String)

    var errorDescription: String? {
        switch self {
        case let .serverUnavailable(origin):
            "T3 Code is not reachable at \(origin). Open T3 Code and try again."
        case .cliMissing:
            "Could not find the t3 command. Open T3 Code once so it installs ~/.t3/bin/t3."
        case let .authorizationFailed(message):
            "Taskboard could not sign in to T3 Code: \(message)"
        case let .toolFailed(message):
            message
        case let .invalidResponse(message):
            "T3 Code returned an unexpected response: \(message)"
        case .boardNotLinked:
            "Link this board to a T3 Code project first."
        case let .threadNotFound(threadID):
            "The T3 thread \(threadID) no longer exists."
        }
    }
}

/// Locations T3 Code writes on this machine. Only read; the server owns them.
enum T3Environment {
    static var home: URL {
        if let override = ProcessInfo.processInfo.environment["T3CODE_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".t3", isDirectory: true)
    }

    static var userData: URL {
        home.appendingPathComponent("userdata", isDirectory: true)
    }

    static var cliURL: URL {
        home.appendingPathComponent("bin/t3")
    }

    static func serverOrigin() -> URL {
        let runtimeURL = userData.appendingPathComponent("server-runtime.json")
        if let data = try? Data(contentsOf: runtimeURL),
           let origin = T3Parsing.serverOrigin(fromRuntime: data) {
            return origin
        }
        return URL(string: "http://127.0.0.1:3773")!
    }

    static func environmentID() -> String? {
        let url = userData.appendingPathComponent("environment-id")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func settingsData() -> Data? {
        try? Data(contentsOf: userData.appendingPathComponent("settings.json"))
    }

    static func threadURL(_ threadID: String) -> URL? {
        guard let environmentID = environmentID() else { return nil }
        return URL(string: "t3code://threads/\(environmentID)/\(threadID)")
    }

    @MainActor
    static func openThread(_ threadID: String) {
        if let url = threadURL(threadID) {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Pure decoding of T3 payloads, kept separate so it can be tested without a server.
enum T3Parsing {
    static func serverOrigin(fromRuntime data: Data) -> URL? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let origin = object["origin"] as? String else { return nil }
        return URL(string: origin)
    }

    static func favorites(fromSettings data: Data) -> [T3FavoriteModel] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let favorites = object["favorites"] as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        return favorites.compactMap { entry in
            guard let instanceID = entry["provider"] as? String ?? entry["instanceId"] as? String,
                  let model = entry["model"] as? String,
                  seen.insert("\(instanceID)/\(model)").inserted else { return nil }
            return T3FavoriteModel(instanceID: instanceID, model: model)
        }
    }

    static func providerAccents(fromSettings data: Data) -> [String: String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let instances = object["providerInstances"] as? [String: [String: Any]] else { return [:] }
        return instances.compactMapValues { $0["accentColor"] as? String }
    }

    /// Joins the favourites from settings with the live catalog's display names.
    /// Favourites whose provider is not in the catalog (disabled or removed) are dropped;
    /// a model the catalog does not list keeps its raw id so custom models still work.
    static func modelOptions(
        favorites: [T3FavoriteModel],
        capabilities: [String: Any]?,
        accents: [String: String] = [:]
    ) -> [T3ModelOption] {
        let providers = capabilities?["providers"] as? [[String: Any]]
        return favorites.compactMap { favorite in
            guard let providers else {
                return T3ModelOption(
                    instanceID: favorite.instanceID,
                    model: favorite.model,
                    providerName: favorite.instanceID,
                    modelLabel: favorite.model,
                    accentHex: accents[favorite.instanceID]
                )
            }
            guard let provider = providers.first(where: {
                $0["providerInstanceId"] as? String == favorite.instanceID
            }) else { return nil }
            let models = provider["models"] as? [[String: Any]] ?? []
            let label = models.first(where: { $0["id"] as? String == favorite.model })?["label"] as? String
            return T3ModelOption(
                instanceID: favorite.instanceID,
                model: favorite.model,
                providerName: provider["displayName"] as? String ?? favorite.instanceID,
                modelLabel: label ?? favorite.model,
                accentHex: accents[favorite.instanceID]
            )
        }
    }

    static func projects(from payload: [String: Any]) -> [T3Project] {
        let items = payload["projects"] as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard item["deletedAt"] is NSNull || item["deletedAt"] == nil,
                  let id = item["id"] as? String,
                  let title = item["title"] as? String else { return nil }
            return T3Project(id: id, title: title, workspaceRoot: item["workspaceRoot"] as? String ?? "")
        }
    }

    static func threadState(from payload: [String: Any]) -> T3ThreadState? {
        guard let thread = payload["thread"] as? [String: Any],
              let threadID = thread["threadId"] as? String else { return nil }
        return T3ThreadState(
            threadID: threadID,
            status: thread["status"] as? String ?? "idle",
            settled: thread["settled"] as? Bool ?? false,
            archived: thread["archived"] as? Bool ?? false,
            pendingRequestCount: thread["pendingRequestCount"] as? Int ?? 0
        )
    }

    static func launchReceipt(from payload: [String: Any]) -> T3LaunchReceipt? {
        guard let threadID = payload["threadId"] as? String else { return nil }
        return T3LaunchReceipt(threadID: threadID, status: payload["status"] as? String)
    }

    /// The CLI prints the pairing JSON on stdout; Electron may add log lines around it.
    static func pairingCode(fromCLIOutput output: String) -> String? {
        guard let start = output.firstIndex(of: "{"),
              let end = output.lastIndex(of: "}"),
              start < end,
              let data = String(output[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["credential"] as? String
    }

    static func authorizationCode(fromRedirect redirect: String) -> String? {
        URLComponents(string: redirect)?.queryItems?.first(where: { $0.name == "code" })?.value
    }

    static func pkceChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Streamable HTTP may answer with JSON or with an SSE stream carrying the response.
    static func rpcMessage(from data: Data, contentType: String?, id: Int) -> [String: Any]? {
        if contentType?.contains("text/event-stream") == true {
            let text = String(decoding: data, as: UTF8.self)
            for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("data:") {
                let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if let message = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                   message["id"] as? Int == id {
                    return message
                }
            }
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// The structured result of a `tools/call`, or the tool's own error text.
    static func toolResult(from message: [String: Any]) throws -> [String: Any] {
        if let error = message["error"] as? [String: Any] {
            throw T3CodeError.toolFailed(error["message"] as? String ?? "T3 Code rejected the request.")
        }
        guard let result = message["result"] as? [String: Any] else {
            throw T3CodeError.invalidResponse("Missing tool result.")
        }
        let text = (result["content"] as? [[String: Any]])?
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
        if result["isError"] as? Bool == true {
            throw T3CodeError.toolFailed(Self.failureMessage(from: text) ?? "T3 Code could not complete the request.")
        }
        if let structured = result["structuredContent"] as? [String: Any] {
            return structured
        }
        if let text, let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            return object
        }
        throw T3CodeError.invalidResponse("Tool result had no structured content.")
    }

    private static func failureMessage(from text: String?) -> String? {
        guard let text else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
           let message = object["message"] as? String {
            return message
        }
        return text.isEmpty ? nil : text
    }
}

/// Talks to the local T3 Code server through its `/mcp` endpoint, the same tool
/// surface T3 exposes to outside agents. Taskboard signs in once as an MCP OAuth
/// client, approving itself with a pairing code minted by the local `t3` CLI.
actor T3CodeClient {
    static let shared = T3CodeClient()

    private let urlSession: URLSession
    private var token: String?
    private var mcpSessionID: String?
    private var sessionTask: Task<Void, Error>?
    private var nextRequestID = 1
    private var cachedCapabilities: [String: Any]?

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    // MARK: Public API

    func projects() async throws -> [T3Project] {
        var projects: [T3Project] = []
        var cursor: Int?
        repeat {
            var arguments: [String: Any] = ["limit": 100]
            if let cursor { arguments["cursor"] = cursor }
            let page = try await callTool("t3_project_list", arguments: arguments)
            projects.append(contentsOf: T3Parsing.projects(from: page))
            cursor = page["nextCursor"] as? Int
        } while cursor != nil
        return projects
    }

    func favoriteModels() async throws -> [T3ModelOption] {
        let settings = T3Environment.settingsData()
        let favorites = settings.map(T3Parsing.favorites(fromSettings:)) ?? []
        let accents = settings.map(T3Parsing.providerAccents(fromSettings:)) ?? [:]
        guard !favorites.isEmpty else { return [] }
        let capabilities: [String: Any]?
        do {
            capabilities = try await callTool("orchestrator_capabilities", arguments: [:])
            cachedCapabilities = capabilities
        } catch {
            capabilities = cachedCapabilities
            if capabilities == nil { throw error }
        }
        return T3Parsing.modelOptions(favorites: favorites, capabilities: capabilities, accents: accents)
    }

    func launchThread(
        projectID: String,
        title: String,
        prompt: String,
        attachments: [TaskAttachment],
        model: T3ModelOption
    ) async throws -> T3LaunchReceipt {
        var arguments: [String: Any] = [
            "projectId": projectID,
            "title": String(title.prefix(80)),
            "message": prompt,
            "modelSelection": ["instanceId": model.instanceID, "model": model.model],
            "runtimeMode": "full-access",
            "interactionMode": "default",
        ]
        let uploaded = try await uploadAttachments(attachments)
        if !uploaded.isEmpty { arguments["attachments"] = uploaded }

        let payload = try await callTool("t3_thread_launch", arguments: arguments)
        guard let receipt = T3Parsing.launchReceipt(from: payload) else {
            throw T3CodeError.invalidResponse("t3_thread_launch returned no thread id.")
        }
        return receipt
    }

    func threadState(threadID: String) async throws -> T3ThreadState {
        let payload: [String: Any]
        do {
            payload = try await callTool("t3_thread_read", arguments: [
                "threadId": threadID,
                "limit": 1,
                "maxCharsPerItem": 1,
            ])
        } catch let T3CodeError.toolFailed(message) where message.localizedCaseInsensitiveContains("not found") {
            throw T3CodeError.threadNotFound(threadID)
        }
        guard let state = T3Parsing.threadState(from: payload) else {
            throw T3CodeError.invalidResponse("t3_thread_read returned no thread.")
        }
        return state
    }

    // MARK: Attachments

    private func uploadAttachments(_ attachments: [TaskAttachment]) async throws -> [[String: Any]] {
        var uploaded: [[String: Any]] = []
        for attachment in attachments {
            let url = URL(fileURLWithPath: attachment.path)
            guard let mimeType = Self.imageMimeType(for: url),
                  let data = try? Data(contentsOf: url), !data.isEmpty else { continue }
            let metadata: [String: Any] = [
                "type": "image",
                "name": attachment.fileName,
                "mimeType": mimeType,
                "sizeBytes": data.count,
            ]
            let prepared = try await callTool("t3_attachment_prepare_upload", arguments: ["upload": metadata])
            guard let attachmentID = prepared["attachmentId"] as? String,
                  let relativeURL = prepared["relativeUrl"] as? String,
                  let uploadURL = URL(string: relativeURL, relativeTo: T3Environment.serverOrigin()) else {
                throw T3CodeError.invalidResponse("t3_attachment_prepare_upload returned no upload URL.")
            }
            var request = URLRequest(url: uploadURL)
            request.httpMethod = "POST"
            request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let (_, response) = try await urlSession.upload(for: request, from: data)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw T3CodeError.toolFailed("T3 Code rejected the attachment \(attachment.fileName).")
            }
            var reference = metadata
            reference["id"] = attachmentID
            uploaded.append(reference)
        }
        return uploaded
    }

    private static func imageMimeType(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        default: nil
        }
    }

    // MARK: MCP transport

    private func callTool(_ name: String, arguments: [String: Any]) async throws -> [String: Any] {
        let attemptedSession = sessionTask
        do {
            return try await callToolOnce(name, arguments: arguments)
        } catch MCPTransportError.unauthorized {
            // The stored credential expired or was revoked in T3's connections list.
            // Only the first caller to notice resets; others reuse its new session.
            if sessionTask == nil || sessionTask == attemptedSession {
                token = nil
                mcpSessionID = nil
                sessionTask = nil
                T3TokenStore.clear()
            }
            return try await callToolOnce(name, arguments: arguments)
        } catch MCPTransportError.sessionExpired {
            if sessionTask == nil || sessionTask == attemptedSession {
                mcpSessionID = nil
                sessionTask = nil
            }
            return try await callToolOnce(name, arguments: arguments)
        }
    }

    private func callToolOnce(_ name: String, arguments: [String: Any]) async throws -> [String: Any] {
        try await ensureSession()
        let message = try await rpc(method: "tools/call", params: ["name": name, "arguments": arguments])
        return try T3Parsing.toolResult(from: message)
    }

    /// Concurrent callers share one sign-in and one MCP session; without this,
    /// actor reentrancy lets two first calls each mint their own credential.
    private func ensureSession() async throws {
        if let sessionTask {
            return try await sessionTask.value
        }
        let task = Task { try await establishSession() }
        sessionTask = task
        do {
            try await task.value
        } catch {
            sessionTask = nil
            throw error
        }
    }

    private func establishSession() async throws {
        if token == nil { token = T3TokenStore.load() }
        if token == nil { token = try await authorize() }
        mcpSessionID = nil
        _ = try await rpc(method: "initialize", params: [
            "protocolVersion": "2025-06-18",
            "capabilities": [:],
            "clientInfo": ["name": "taskboard", "title": "Taskboard", "version": "0.3.0"],
        ])
        try await notify(method: "notifications/initialized")
    }

    private func rpc(method: String, params: [String: Any]) async throws -> [String: Any] {
        let id = nextRequestID
        nextRequestID += 1
        let (data, response) = try await post(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        if method == "initialize", let sessionID = response.value(forHTTPHeaderField: "mcp-session-id") {
            mcpSessionID = sessionID
        }
        guard let message = T3Parsing.rpcMessage(
            from: data,
            contentType: response.value(forHTTPHeaderField: "Content-Type"),
            id: id
        ) else {
            throw T3CodeError.invalidResponse("Unreadable reply to \(method).")
        }
        return message
    }

    private func notify(method: String) async throws {
        _ = try await post(["jsonrpc": "2.0", "method": method])
    }

    private func post(_ body: [String: Any]) async throws -> (Data, HTTPURLResponse) {
        let origin = T3Environment.serverOrigin()
        var request = URLRequest(url: origin.appendingPathComponent("mcp"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let mcpSessionID { request.setValue(mcpSessionID, forHTTPHeaderField: "mcp-session-id") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw T3CodeError.serverUnavailable(origin.absoluteString)
        }
        guard let http = response as? HTTPURLResponse else {
            throw T3CodeError.invalidResponse("Not an HTTP response.")
        }
        switch http.statusCode {
        case 200..<300: return (data, http)
        case 401: throw MCPTransportError.unauthorized
        case 404 where mcpSessionID != nil: throw MCPTransportError.sessionExpired
        default:
            throw T3CodeError.invalidResponse("HTTP \(http.statusCode) from /mcp.")
        }
    }

    private enum MCPTransportError: Error {
        case unauthorized
        case sessionExpired
    }

    // MARK: Sign-in

    /// OAuth 2.1 authorization-code flow with PKCE against T3's MCP authorization
    /// server. The approval step uses a one-time pairing code from the local CLI,
    /// so it completes without a browser and grants full access (agents can run
    /// without stopping for approvals).
    private func authorize() async throws -> String {
        let origin = T3Environment.serverOrigin()
        let resource = origin.appendingPathComponent("mcp").absoluteString
        let redirectURI = "http://127.0.0.1:47123/taskboard/callback"
        let pairingCode = try await Self.mintPairingCode()

        let registration = try await postJSON(origin.appendingPathComponent("oauth/mcp/register"), body: [
            "client_name": "Taskboard",
            "redirect_uris": [redirectURI],
            "token_endpoint_auth_method": "none",
        ])
        guard let clientID = registration["client_id"] as? String else {
            throw T3CodeError.authorizationFailed("Client registration returned no client id.")
        }

        var verifierBytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, verifierBytes.count, &verifierBytes)
        let verifier = T3Parsing.base64URL(Data(verifierBytes))
        let state = UUID().uuidString

        let decision = try await postJSON(origin.appendingPathComponent("oauth/mcp/decision"), body: [
            "authorization": [
                "response_type": "code",
                "client_id": clientID,
                "redirect_uri": redirectURI,
                "code_challenge": T3Parsing.pkceChallenge(for: verifier),
                "code_challenge_method": "S256",
                "state": state,
                "resource": resource,
            ],
            "decision": ["_tag": "pairing-code", "access": "full-access", "code": pairingCode],
        ])
        guard let redirect = decision["redirectTo"] as? String,
              let code = T3Parsing.authorizationCode(fromRedirect: redirect) else {
            throw T3CodeError.authorizationFailed(decision["message"] as? String ?? "The sign-in was not approved.")
        }

        var tokenRequest = URLRequest(url: origin.appendingPathComponent("oauth/mcp/token"))
        tokenRequest.httpMethod = "POST"
        tokenRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            .init(name: "grant_type", value: "authorization_code"),
            .init(name: "code", value: code),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "client_id", value: clientID),
            .init(name: "code_verifier", value: verifier),
            .init(name: "resource", value: resource),
        ]
        tokenRequest.httpBody = Data((form.percentEncodedQuery ?? "")
            .replacingOccurrences(of: "+", with: "%2B").utf8)
        let tokenPayload = try await send(tokenRequest)
        guard let accessToken = tokenPayload["access_token"] as? String else {
            throw T3CodeError.authorizationFailed(
                tokenPayload["error_description"] as? String ?? "The token exchange failed."
            )
        }
        T3TokenStore.save(accessToken)
        return accessToken
    }

    private func postJSON(_ url: URL, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        let data: Data
        do {
            (data, _) = try await urlSession.data(for: request)
        } catch {
            throw T3CodeError.serverUnavailable(T3Environment.serverOrigin().absoluteString)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw T3CodeError.authorizationFailed("Unreadable reply from \(request.url?.path ?? "T3 Code").")
        }
        return object
    }

    private static func mintPairingCode() async throws -> String {
        let cli = T3Environment.cliURL
        guard FileManager.default.isExecutableFile(atPath: cli.path) else {
            throw T3CodeError.cliMissing
        }
        return try await Task.detached {
            let process = Process()
            let stdout = Pipe()
            process.executableURL = cli
            process.arguments = ["auth", "pairing", "create", "--json", "--ttl", "5m", "--label", "Taskboard"]
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            try process.run()
            let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            guard let code = T3Parsing.pairingCode(fromCLIOutput: output) else {
                throw T3CodeError.authorizationFailed("`t3 auth pairing create` did not return a pairing code.")
            }
            return code
        }.value
    }
}

/// The MCP credential lives in a user-only file rather than the keychain: any
/// process running as this user can mint an equivalent one with the local `t3`
/// CLI, so the keychain adds no protection, only an access prompt after every
/// ad-hoc rebuild.
private enum T3TokenStore {
    private static var url: URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return applicationSupport
            .appendingPathComponent("taskboard", isDirectory: true)
            .appendingPathComponent("t3-mcp-token", isDirectory: false)
    }

    static func load() -> String? {
        guard let token = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func save(_ token: String) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fileManager.createFile(atPath: url.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
