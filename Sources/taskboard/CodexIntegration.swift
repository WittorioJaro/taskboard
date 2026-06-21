import Darwin
import Foundation
import AppKit

struct CodexModel: Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let isDefault: Bool
    let supportedReasoningEfforts: [CodexReasoningEffort]
    let defaultReasoningEffort: CodexReasoningEffort

    var rawValue: String { id }

    static let recommended = CodexModel(
        id: "",
        title: "Codex default",
        isDefault: true,
        supportedReasoningEfforts: CodexReasoningEffort.allCases,
        defaultReasoningEffort: .medium
    )

    static let fallbackModels = [recommended]

    init(
        id: String,
        title: String,
        isDefault: Bool,
        supportedReasoningEfforts: [CodexReasoningEffort] = CodexReasoningEffort.allCases,
        defaultReasoningEffort: CodexReasoningEffort = .medium
    ) {
        self.id = id
        self.title = title
        self.isDefault = isDefault
        self.supportedReasoningEfforts = supportedReasoningEfforts.isEmpty
            ? CodexReasoningEffort.allCases
            : supportedReasoningEfforts
        self.defaultReasoningEffort = defaultReasoningEffort
    }
}

enum CodexReasoningEffort: String, CaseIterable, Identifiable, Sendable {
    case low
    case medium
    case high
    case xhigh

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra high"
        }
    }
}

enum CodexBranchChoice: Equatable {
    case existing(String)
    case new(String)
}

struct CodexLaunchReceipt: Sendable {
    let threadID: String
    let branchName: String?
    let worktreePath: String
    let completedTaskCount: Int
}

enum CodexIntegrationError: LocalizedError {
    case workspacePathMissing
    case workspaceNotFound(String)
    case notGitRepository(String)
    case mainBranchRequired(String)
    case invalidResponse(String)
    case requestTimedOut(String)
    case turnTimedOut
    case appServerExited(Int32)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .workspacePathMissing:
            "Choose a folder for this board first."
        case let .workspaceNotFound(path):
            "The board folder does not exist: \(path)"
        case let .notGitRepository(path):
            "The board folder is not a Git repository: \(path)"
        case let .mainBranchRequired(branch):
            "Direct send works on main without creating a branch. This folder is currently on \(branch)."
        case let .invalidResponse(message):
            "Codex returned an unexpected response: \(message)"
        case let .requestTimedOut(method):
            "Codex did not respond to \(method) within 20 seconds. The request was stopped instead of waiting forever."
        case .turnTimedOut:
            "Codex did not finish the task within 10 minutes. The background connection was reset."
        case let .appServerExited(code):
            "The Codex app server exited unexpectedly (exit code \(code))."
        case let .commandFailed(message):
            message
        }
    }
}

enum CodexTurnOutcome: Equatable {
    case completed
    case failed(String)
}

enum CodexAppServerMessage {
    static func responseID(from payload: [String: Any]) -> Int? {
        payload["id"] as? Int
    }

    static func responseError(from payload: [String: Any]) -> String? {
        guard let error = payload["error"] as? [String: Any] else {
            return nil
        }
        return error["message"] as? String ?? "Unknown app-server error"
    }

    static func turnCompletion(from payload: [String: Any]) -> (turnID: String, outcome: CodexTurnOutcome)? {
        guard payload["method"] as? String == "turn/completed",
              let params = payload["params"] as? [String: Any],
              let turn = params["turn"] as? [String: Any],
              let turnID = turn["id"] as? String else {
            return nil
        }

        let status = turn["status"] as? String ?? "failed"
        if status == "completed" {
            return (turnID, .completed)
        }

        let error = turn["error"] as? [String: Any]
        let message = error?["message"] as? String
            ?? "Codex turn ended with status \(status)."
        return (turnID, .failed(message))
    }

}

struct JSONLineBuffer {
    private var data = Data()

    mutating func append(_ newData: Data) -> [String] {
        data.append(newData)
        var lines: [String] = []

        while let newlineIndex = data.firstIndex(of: 0x0A) {
            let lineData = data[..<newlineIndex]
            data.removeSubrange(...newlineIndex)
            if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                lines.append(line)
            }
        }

        return lines
    }
}

struct CodexBranchNameBuilder {
    static func suggestedBranchName(boardTitle: String, taskTitles: [String]) -> String {
        let boardSlug = slug(boardTitle)
        let taskSlug = taskTitles.prefix(2).map(slug).filter { !$0.isEmpty }.joined(separator: "-")
        return sanitize("codex/\(boardSlug)-\(taskSlug.isEmpty ? "queue" : taskSlug)")
    }

    static func sanitize(_ rawValue: String) -> String {
        let lowered = rawValue.lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/-"))
        let scalars = lowered.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        var cleaned = String(scalars)
            .replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "/-+", with: "/", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-/"))

        if cleaned.isEmpty { cleaned = "taskboard-queue" }
        if !cleaned.hasPrefix("codex/") { cleaned = "codex/\(cleaned)" }
        return cleaned
    }

    private static func slug(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

struct CodexDisplayText {
    static func threadID(_ threadID: String) -> String {
        let suffix = threadID.suffix(8)
        return suffix.isEmpty ? threadID : String(suffix)
    }
}

enum CodexTurnInput {
    static func make(prompt: String, attachments: [TaskAttachment]) -> [[String: Any]] {
        var input: [[String: Any]] = [["type": "text", "text": prompt, "text_elements": []]]
        input.append(contentsOf: attachments.map { ["type": "localImage", "path": $0.path] })
        return input
    }
}

actor CodexTaskDispatcher {
    static let shared = CodexTaskDispatcher()
    private var sessionTask: Task<CodexAppServerSession, Error>?
    private let executionGate = CodexExecutionGate()

    func availableModels() async throws -> [CodexModel] {
        let session = try await sharedSession()
        return try await session.availableModels()
    }

    func availableBranches(workspacePath: String) throws -> [String] {
        let root = try Self.repositoryRoot(workspacePath: workspacePath)
        let output = try ShellCommand.run([
            "/usr/bin/env", "git", "-C", root.path, "for-each-ref",
            "--format=%(refname:short)", "refs/heads/",
        ])
        return output.split(separator: "\n").map(String.init).sorted()
    }

    func sendQueue(
        boardTitle: String,
        tasks: [TaskItem],
        workspacePath: String,
        branchChoice: CodexBranchChoice,
        model: CodexModel,
        effort: CodexReasoningEffort,
        status: @escaping @Sendable (CodexDispatchStatus) async -> Void = { _ in },
        progress: @escaping @Sendable (Int, Int) async -> Void
    ) async throws -> CodexLaunchReceipt {
        await status(.init(.waiting, totalCount: tasks.count))
        await executionGate.acquire()
        do {
            await status(.init(.connecting, totalCount: tasks.count))
            let receipt = try await performQueue(
                boardTitle: boardTitle,
                tasks: tasks,
                workspacePath: workspacePath,
                branchChoice: branchChoice,
                model: model,
                effort: effort,
                status: status,
                progress: progress
            )
            await executionGate.release()
            return receipt
        } catch {
            await status(.init(.failed, totalCount: tasks.count))
            await resetSession()
            await executionGate.release()
            throw error
        }
    }

    private func performQueue(
        boardTitle: String,
        tasks: [TaskItem],
        workspacePath: String,
        branchChoice: CodexBranchChoice,
        model: CodexModel,
        effort: CodexReasoningEffort,
        status: @escaping @Sendable (CodexDispatchStatus) async -> Void,
        progress: @escaping @Sendable (Int, Int) async -> Void
    ) async throws -> CodexLaunchReceipt {
        let prepared = try Self.prepareQueueWorkspace(
            workspacePath: workspacePath,
            branchChoice: branchChoice
        )
        let session = try await sharedSession()
        await status(.init(.creatingThread, totalCount: tasks.count))
        let threadID = try await session.startThread(
            cwd: prepared.worktreeURL.path,
            model: model
        )
        await session.refreshThreadHistory(threadID: threadID)

        for (index, task) in tasks.enumerated() {
            await progress(index, tasks.count)
            await status(.init(
                .sending,
                threadID: threadID,
                completedCount: index,
                totalCount: tasks.count
            ))
            try await session.startTurn(
                threadID: threadID,
                cwd: prepared.worktreeURL.path,
                prompt: task.title,
                attachments: task.attachments,
                model: model,
                effort: effort
            )
            await status(.init(
                .running,
                threadID: threadID,
                completedCount: index,
                totalCount: tasks.count
            ))
            try await session.waitForTurnCompletion()
            await session.refreshThreadHistory(threadID: threadID)
            await progress(index + 1, tasks.count)
        }
        return CodexLaunchReceipt(
            threadID: threadID,
            branchName: prepared.branchName,
            worktreePath: prepared.worktreeURL.path,
            completedTaskCount: tasks.count
        )
    }

    func sendDirect(
        boardTitle: String,
        prompt: String,
        attachments: [TaskAttachment] = [],
        workspacePath: String,
        status: @escaping @Sendable (CodexDispatchStatus) async -> Void = { _ in }
    ) async throws -> CodexLaunchReceipt {
        await status(.init(.waiting))
        await executionGate.acquire()
        do {
            await status(.init(.connecting))
            let receipt = try await performDirect(
                boardTitle: boardTitle,
                prompt: prompt,
                attachments: attachments,
                workspacePath: workspacePath,
                status: status
            )
            await executionGate.release()
            return receipt
        } catch {
            await status(.init(.failed))
            await resetSession()
            await executionGate.release()
            throw error
        }
    }

    private func performDirect(
        boardTitle: String,
        prompt: String,
        attachments: [TaskAttachment],
        workspacePath: String,
        status: @escaping @Sendable (CodexDispatchStatus) async -> Void
    ) async throws -> CodexLaunchReceipt {
        let root = try Self.repositoryRoot(workspacePath: workspacePath)
        let branch = try ShellCommand.run([
            "/usr/bin/env", "git", "-C", root.path, "branch", "--show-current",
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard branch == "main" else {
            throw CodexIntegrationError.mainBranchRequired(branch.isEmpty ? "a detached HEAD" : branch)
        }

        let session = try await sharedSession()
        await status(.init(.creatingThread))
        let threadID = try await session.startThread(cwd: root.path, model: .recommended)
        await session.refreshThreadHistory(threadID: threadID)
        await status(.init(.sending, threadID: threadID))
        try await session.startTurn(
            threadID: threadID,
            cwd: root.path,
            prompt: prompt,
            attachments: attachments,
            model: .recommended,
            effort: .medium
        )
        await status(.init(.running, threadID: threadID))
        try await session.waitForTurnCompletion()
        await session.refreshThreadHistory(threadID: threadID)
        return CodexLaunchReceipt(
            threadID: threadID,
            branchName: nil,
            worktreePath: root.path,
            completedTaskCount: 1
        )
    }

    func shutdownForTesting() async {
        await resetSession()
    }

    private func sharedSession() async throws -> CodexAppServerSession {
        if let sessionTask {
            return try await sessionTask.value
        }

        let task = Task {
            let session = try CodexAppServerSession()
            try await session.initialize()
            return session
        }
        sessionTask = task

        do {
            return try await task.value
        } catch {
            sessionTask = nil
            throw error
        }
    }

    private func resetSession() async {
        guard let sessionTask else { return }
        self.sessionTask = nil
        if let session = try? await sessionTask.value {
            await session.stop()
        }
    }

    private static func repositoryRoot(workspacePath: String) throws -> URL {
        let trimmed = workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CodexIntegrationError.workspacePathMissing }
        let url = URL(fileURLWithPath: trimmed)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CodexIntegrationError.workspaceNotFound(url.path)
        }

        do {
            let root = try ShellCommand.run([
                "/usr/bin/env", "git", "-C", url.path, "rev-parse", "--show-toplevel",
            ]).trimmingCharacters(in: .whitespacesAndNewlines)
            return URL(fileURLWithPath: root)
        } catch {
            throw CodexIntegrationError.notGitRepository(url.path)
        }
    }

    private static func prepareQueueWorkspace(
        workspacePath: String,
        branchChoice: CodexBranchChoice
    ) throws -> PreparedWorkspace {
        let root = try repositoryRoot(workspacePath: workspacePath)
        let branchName: String
        let createBranch: Bool
        switch branchChoice {
        case let .existing(name):
            branchName = name
            createBranch = false
        case let .new(name):
            branchName = CodexBranchNameBuilder.sanitize(name)
            createBranch = true
        }

        let worktreeBase = root.deletingLastPathComponent()
            .appendingPathComponent(".taskboard-codex-worktrees", isDirectory: true)
        let worktree = worktreeBase.appendingPathComponent(
            branchName.replacingOccurrences(of: "/", with: "__"),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: worktreeBase, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: worktree.path) {
            let existing = try ShellCommand.run([
                "/usr/bin/env", "git", "-C", worktree.path, "branch", "--show-current",
            ]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard existing == branchName else {
                throw CodexIntegrationError.commandFailed("The worktree folder is already used by \(existing).")
            }
            return PreparedWorkspace(worktreeURL: worktree, branchName: branchName)
        }

        if createBranch {
            let exists = try ShellCommand.status([
                "/usr/bin/env", "git", "-C", root.path, "show-ref", "--verify", "--quiet",
                "refs/heads/\(branchName)",
            ]) == 0
            guard !exists else {
                throw CodexIntegrationError.commandFailed("Branch \(branchName) already exists. Choose it as an existing branch.")
            }
            _ = try ShellCommand.run([
                "/usr/bin/env", "git", "-C", root.path, "worktree", "add", "-b",
                branchName, worktree.path, "HEAD",
            ])
        } else {
            let currentBranch = try ShellCommand.run([
                "/usr/bin/env", "git", "-C", root.path, "branch", "--show-current",
            ]).trimmingCharacters(in: .whitespacesAndNewlines)
            if currentBranch == branchName {
                return PreparedWorkspace(worktreeURL: root, branchName: branchName)
            }
            _ = try ShellCommand.run([
                "/usr/bin/env", "git", "-C", root.path, "worktree", "add", worktree.path, branchName,
            ])
        }

        return PreparedWorkspace(worktreeURL: worktree, branchName: branchName)
    }

}

private actor CodexExecutionGate {
    private var isRunning = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isRunning {
            isRunning = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isRunning = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

private struct PreparedWorkspace {
    let worktreeURL: URL
    let branchName: String
}

private enum ShellCommand {
    static func run(_ command: [String]) throws -> String {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let message = error.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CodexIntegrationError.commandFailed(message.isEmpty ? output : message)
        }
        return output
    }

    static func status(_ command: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

private actor CodexAppServerSession {
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdinPipe = Pipe()
    private var nextRequestID = 0
    private var pendingResponses: [Int: PendingResponse] = [:]
    private var turnWaiter: CheckedContinuation<Void, Error>?
    private var completedTurnPending = false
    private var failedTurnPendingMessage: String?
    private var activeTurnID: String?
    private var turnTimeoutTask: Task<Void, Never>?
    private var isTerminated = false
    private var lastStderrLine: String?
    private var stdoutBuffer = JSONLineBuffer()

    init() throws {
        process.executableURL = try CodexExecutable.resolve()
        process.arguments = ["app-server"]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe
        process.terminationHandler = { [weak self] process in
            Task { await self?.handleTermination(exitCode: process.terminationStatus) }
        }
        try process.run()
    }

    func initialize() async throws {
        startReadersIfNeeded()
        _ = try await request(method: "initialize", params: [
            "clientInfo": ["name": "taskboard", "title": "Taskboard", "version": "0.2.0"],
        ])
        try send(method: "initialized", id: nil, params: [:])
    }

    func availableModels() async throws -> [CodexModel] {
        var models: [CodexModel] = []
        var cursor: String?

        repeat {
            var params: [String: Any] = ["includeHidden": false, "limit": 100]
            if let cursor { params["cursor"] = cursor }
            let response = try await request(method: "model/list", params: params)
            guard let result = response["result"] as? [String: Any],
                  let data = result["data"] as? [[String: Any]] else {
                throw CodexIntegrationError.invalidResponse("Missing model data from model/list.")
            }

            models.append(contentsOf: data.compactMap(Self.parseModel))
            cursor = result["nextCursor"] as? String
        } while cursor != nil

        guard !models.isEmpty else {
            throw CodexIntegrationError.invalidResponse("Codex returned no selectable models.")
        }
        return models
    }

    private static func parseModel(_ payload: [String: Any]) -> CodexModel? {
        guard let id = payload["model"] as? String,
              let title = payload["displayName"] as? String else { return nil }

        let effortPayloads = payload["supportedReasoningEfforts"] as? [[String: Any]] ?? []
        let efforts = effortPayloads.compactMap { item in
            (item["reasoningEffort"] as? String).flatMap(CodexReasoningEffort.init(rawValue:))
        }
        let defaultEffort = (payload["defaultReasoningEffort"] as? String)
            .flatMap(CodexReasoningEffort.init(rawValue:)) ?? efforts.first ?? .medium

        return CodexModel(
            id: id,
            title: title,
            isDefault: payload["isDefault"] as? Bool ?? false,
            supportedReasoningEfforts: efforts,
            defaultReasoningEffort: defaultEffort
        )
    }

    private func startReadersIfNeeded() {
        let stdoutHandle = stdoutPipe.fileHandleForReading
        guard stdoutHandle.readabilityHandler == nil else {
            return
        }

        stdoutHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            Task { await self?.handleStdout(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            Task { await self?.recordStderr(text) }
        }
    }

    private func handleStdout(_ data: Data) {
        for line in stdoutBuffer.append(data) {
            handle(line: line)
        }
    }

    func startThread(cwd: String, model: CodexModel) async throws -> String {
        var params: [String: Any] = [
            "cwd": cwd,
            "approvalPolicy": "never",
            "sandbox": "danger-full-access",
        ]
        if !model.rawValue.isEmpty { params["model"] = model.rawValue }
        let response = try await request(method: "thread/start", params: params)
        guard let result = response["result"] as? [String: Any],
              let thread = result["thread"] as? [String: Any],
              let id = thread["id"] as? String else {
            throw CodexIntegrationError.invalidResponse("Missing thread id from thread/start.")
        }
        return id
    }

    func refreshThreadHistory(threadID: String) async {
        _ = try? await request(method: "thread/read", params: [
            "threadId": threadID,
            "includeTurns": false,
        ])
        _ = try? await request(method: "thread/list", params: [
            "limit": 50,
            "sortKey": "updated_at",
            "sortDirection": "desc",
            "sourceKinds": ["appServer"],
            "useStateDbOnly": false,
        ])
    }

    func runTurn(
        threadID: String,
        cwd: String,
        prompt: String,
        attachments: [TaskAttachment] = [],
        model: CodexModel,
        effort: CodexReasoningEffort
    ) async throws {
        try await startTurn(
            threadID: threadID,
            cwd: cwd,
            prompt: prompt,
            attachments: attachments,
            model: model,
            effort: effort
        )
        try await waitForTurnCompletion()
        try await Task.sleep(for: .milliseconds(250))
    }

    func startTurn(
        threadID: String,
        cwd: String,
        prompt: String,
        attachments: [TaskAttachment] = [],
        model: CodexModel,
        effort: CodexReasoningEffort
    ) async throws {
        completedTurnPending = false
        failedTurnPendingMessage = nil
        var params: [String: Any] = [
            "threadId": threadID,
            "cwd": cwd,
            "approvalPolicy": "never",
            "sandboxPolicy": ["type": "dangerFullAccess"],
            "effort": effort.rawValue,
            "input": CodexTurnInput.make(prompt: prompt, attachments: attachments),
        ]
        if !model.rawValue.isEmpty { params["model"] = model.rawValue }
        let response = try await request(method: "turn/start", params: params)
        guard let result = response["result"] as? [String: Any],
              let turn = result["turn"] as? [String: Any],
              let turnID = turn["id"] as? String else {
            throw CodexIntegrationError.invalidResponse("Missing turn id from turn/start.")
        }
        activeTurnID = turnID
    }

    func waitForTurnCompletion() async throws {
        if let message = failedTurnPendingMessage {
            failedTurnPendingMessage = nil
            throw CodexIntegrationError.commandFailed(message)
        }
        if completedTurnPending {
            completedTurnPending = false
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            turnWaiter = continuation
            turnTimeoutTask = Task.detached { [weak self] in
                try? await Task.sleep(for: .seconds(600))
                await self?.expireTurn()
            }
        }
    }

    private func expireTurn() {
        guard let waiter = turnWaiter else {
            return
        }
        turnWaiter = nil
        activeTurnID = nil
        turnTimeoutTask = nil
        waiter.resume(throwing: CodexIntegrationError.turnTimedOut)
    }

    func stop() {
        isTerminated = true
        shutdownProcess()
    }

    private func shutdownProcess() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        try? stdinPipe.fileHandleForWriting.close()
        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()
        let processID = process.processIdentifier
        if processID > 0 {
            process.terminate()
            Darwin.kill(processID, SIGKILL)
        }
    }

    private func request(method: String, params: [String: Any]) async throws -> [String: Any] {
        let id = nextRequestID
        nextRequestID += 1
        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task.detached { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                await self?.expireRequest(id: id)
            }
            pendingResponses[id] = PendingResponse(
                method: method,
                continuation: continuation,
                timeoutTask: timeoutTask
            )
            do {
                try send(method: method, id: id, params: params)
            } catch {
                pendingResponses.removeValue(forKey: id)?.timeoutTask.cancel()
                continuation.resume(throwing: error)
            }
        }
    }

    private func expireRequest(id: Int) {
        guard let pending = pendingResponses.removeValue(forKey: id) else {
            return
        }
        pending.continuation.resume(throwing: CodexIntegrationError.requestTimedOut(pending.method))
    }

    private func send(method: String, id: Int?, params: [String: Any]) throws {
        guard !isTerminated else {
            throw CodexIntegrationError.commandFailed("The Codex app server is no longer running.")
        }
        var payload: [String: Any] = ["method": method, "params": params]
        if let id { payload["id"] = id }
        let data = try JSONSerialization.data(withJSONObject: payload)
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
        try stdinPipe.fileHandleForWriting.write(contentsOf: Data([0x0A]))
    }

    private func handle(line: String) {
        guard let data = line.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let id = CodexAppServerMessage.responseID(from: payload),
           let pending = pendingResponses.removeValue(forKey: id) {
            pending.timeoutTask.cancel()
            if let error = CodexAppServerMessage.responseError(from: payload) {
                pending.continuation.resume(throwing: CodexIntegrationError.commandFailed(error))
            } else {
                pending.continuation.resume(returning: payload)
            }
            return
        }

        if let completion = CodexAppServerMessage.turnCompletion(from: payload),
           completion.turnID == activeTurnID {
            completeActiveTurn(with: completion.outcome)
        }
    }

    private func completeActiveTurn(with outcome: CodexTurnOutcome) {
        activeTurnID = nil
        turnTimeoutTask?.cancel()
        turnTimeoutTask = nil
        if let waiter = turnWaiter {
            turnWaiter = nil
            switch outcome {
            case .completed:
                waiter.resume()
            case let .failed(message):
                waiter.resume(throwing: CodexIntegrationError.commandFailed(message))
            }
        } else {
            switch outcome {
            case .completed:
                completedTurnPending = true
            case let .failed(message):
                failedTurnPendingMessage = message
            }
        }
    }

    private func recordStderr(_ line: String) {
        let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { lastStderrLine = value }
    }

    private func handleTermination(exitCode: Int32, message: String? = nil) {
        guard !isTerminated else { return }
        isTerminated = true
        shutdownProcess()
        let error = CodexIntegrationError.commandFailed(message ?? lastStderrLine ?? "Codex app server exited (\(exitCode)).")
        pendingResponses.values.forEach { $0.continuation.resume(throwing: error) }
        pendingResponses.values.forEach { $0.timeoutTask.cancel() }
        pendingResponses.removeAll()
        turnTimeoutTask?.cancel()
        turnTimeoutTask = nil
        turnWaiter?.resume(throwing: error)
        turnWaiter = nil
    }

    private struct PendingResponse {
        let method: String
        let continuation: CheckedContinuation<[String: Any], Error>
        let timeoutTask: Task<Void, Never>
    }
}

@MainActor
enum CodexDesktopBridge {
    private static let bundleIdentifier = "com.openai.codex"

    static func threadURL(_ threadID: String) -> URL? {
        URL(string: "codex://threads/\(threadID)")
    }

    static func openThread(_ threadID: String) {
        guard let url = threadURL(threadID) else { return }
        NSWorkspace.shared.open(url)
    }

}

private enum CodexExecutable {
    static func resolve() throws -> URL {
        let candidates = [
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/codex").path,
        ]

        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }

        let path = try ShellCommand.run([
            "/bin/zsh", "-lc", "command -v codex",
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else {
            throw CodexIntegrationError.commandFailed(
                "Could not find the Codex CLI. Install Codex or make the `codex` command available in your login shell."
            )
        }
        return URL(fileURLWithPath: path)
    }
}
