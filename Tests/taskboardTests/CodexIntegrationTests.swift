import Foundation
import XCTest
@testable import taskboard

final class CodexIntegrationTests: XCTestCase {
    func testTurnInputIncludesLocalImageAlongsidePrompt() throws {
        let attachment = TaskAttachment(fileName: "shot.png", path: "/tmp/shot.png")
        let input = CodexTurnInput.make(prompt: "Inspect this", attachments: [attachment])

        XCTAssertEqual(input.count, 2)
        XCTAssertEqual(input[0]["type"] as? String, "text")
        XCTAssertEqual(input[0]["text"] as? String, "Inspect this")
        XCTAssertEqual(input[1]["type"] as? String, "localImage")
        XCTAssertEqual(input[1]["path"] as? String, "/tmp/shot.png")
    }

    func testBranchNameSanitizesUserInput() {
        XCTAssertEqual(
            CodexBranchNameBuilder.sanitize("  My Feature / Fix It!  "),
            "codex/my-feature-/fix-it"
        )
    }

    func testSuggestedBranchUsesBoardAndPromptText() {
        XCTAssertEqual(
            CodexBranchNameBuilder.suggestedBranchName(
                boardTitle: "Payments",
                taskTitles: ["Add retry logic", "Cover timeouts"]
            ),
            "codex/payments-add-retry-logic-cover-timeouts"
        )
    }

    func testParsesSuccessfulTurnCompletion() {
        let payload: [String: Any] = [
            "method": "turn/completed",
            "params": [
                "turn": [
                    "id": "turn-1",
                    "status": "completed",
                    "error": NSNull(),
                ],
            ],
        ]

        XCTAssertEqual(CodexAppServerMessage.turnCompletion(from: payload)?.turnID, "turn-1")
        XCTAssertEqual(CodexAppServerMessage.turnCompletion(from: payload)?.outcome, .completed)
    }

    func testParsesFailedTurnCompletionMessage() {
        let payload: [String: Any] = [
            "method": "turn/completed",
            "params": [
                "turn": [
                    "id": "turn-2",
                    "status": "failed",
                    "error": ["message": "Authentication expired"],
                ],
            ],
        ]

        XCTAssertEqual(CodexAppServerMessage.turnCompletion(from: payload)?.turnID, "turn-2")
        XCTAssertEqual(
            CodexAppServerMessage.turnCompletion(from: payload)?.outcome,
            .failed("Authentication expired")
        )
    }

    func testIgnoresUnrelatedNotification() {
        let payload: [String: Any] = [
            "method": "item/completed",
            "params": [:],
        ]

        XCTAssertNil(CodexAppServerMessage.turnCompletion(from: payload))
    }

    func testDoesNotTreatFinalMessageAsAuthoritativeTurnCompletion() {
        let finalMessage: [String: Any] = [
            "method": "item/completed",
            "params": [
                "turnId": "turn-3",
                "item": [
                    "type": "agentMessage",
                    "phase": "final_answer",
                ],
            ],
        ]

        XCTAssertNil(CodexAppServerMessage.turnCompletion(from: finalMessage))
    }

    func testParsesRequestError() {
        let payload: [String: Any] = [
            "id": 7,
            "error": ["message": "Invalid effort"],
        ]

        XCTAssertEqual(CodexAppServerMessage.responseID(from: payload), 7)
        XCTAssertEqual(CodexAppServerMessage.responseError(from: payload), "Invalid effort")
    }

    func testJSONLineBufferHandlesFragmentedResponse() {
        var buffer = JSONLineBuffer()

        XCTAssertTrue(buffer.append(Data(#"{"id":0,"res"#.utf8)).isEmpty)
        XCTAssertEqual(
            buffer.append(Data(#"ult":{}}"# .utf8) + Data([0x0A])),
            [#"{"id":0,"result":{}}"#]
        )
    }

    func testJSONLineBufferReturnsMultipleResponses() {
        var buffer = JSONLineBuffer()
        let data = Data("{\"id\":0}\n{\"method\":\"turn/completed\"}\n".utf8)

        XCTAssertEqual(
            buffer.append(data),
            [#"{"id":0}"#, #"{"method":"turn/completed"}"#]
        )
    }

    @MainActor
    func testCodexThreadDeepLink() {
        XCTAssertEqual(
            CodexDesktopBridge.threadURL("019abc-thread")?.absoluteString,
            "codex://threads/019abc-thread"
        )
    }

    func testThreadIDDisplayUsesUniqueSuffix() {
        XCTAssertEqual(
            CodexDisplayText.threadID("019ecc1f-b995-77e1-8352-b4d94f9b5855"),
            "4f9b5855"
        )
        XCTAssertEqual(
            CodexDisplayText.threadID("019ecc1f-f105-7702-87f4-0a73b75ad48e"),
            "b75ad48e"
        )
    }

    func testThreadPlanSplitsEightOrderedTasksIntoThreeTwoThree() {
        let tasks = (1...8).map { TaskItem(title: "Task \($0)") }
        let groups = CodexThreadPlan.groups(
            orderedTasks: tasks,
            threadStartTaskIDs: [tasks[3].id, tasks[5].id]
        )

        XCTAssertEqual(groups.map(\.count), [3, 2, 3])
        XCTAssertEqual(groups.map { $0.map(\.title) }, [
            ["Task 1", "Task 2", "Task 3"],
            ["Task 4", "Task 5"],
            ["Task 6", "Task 7", "Task 8"],
        ])
    }

    func testThreadPlanIgnoresAFirstTaskSplitMarker() {
        let tasks = (1...3).map { TaskItem(title: "Task \($0)") }
        let groups = CodexThreadPlan.groups(
            orderedTasks: tasks,
            threadStartTaskIDs: [tasks[0].id, tasks[2].id]
        )

        XCTAssertEqual(groups.map(\.count), [2, 1])
    }

    func testLiveCodexQueueCompletesWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["TASKBOARD_RUN_CODEX_INTEGRATION_TESTS"] == "1" else {
            throw XCTSkip("Set TASKBOARD_RUN_CODEX_INTEGRATION_TESTS=1 to run the live Codex test.")
        }

        let repo = try makeTemporaryMainRepository()
        let progress = ProgressRecorder()
        let receipt = try await CodexTaskDispatcher.shared.sendQueue(
            boardTitle: "Taskboard Integration Test",
            tasks: [TaskItem(title: "Reply with exactly OK. Do not edit files.")],
            workspacePath: repo.path,
            branchChoice: .existing("main"),
            model: .recommended,
            effort: .low
        ) { completed, total in
            await progress.record(completed: completed, total: total)
        }

        XCTAssertFalse(receipt.threadID.isEmpty)
        XCTAssertEqual(
            URL(fileURLWithPath: receipt.worktreePath).resolvingSymlinksInPath().path,
            repo.resolvingSymlinksInPath().path
        )
        XCTAssertEqual(receipt.branchName, "main")
        XCTAssertEqual(receipt.completedTaskCount, 1)
        let progressValues = await progress.values
        XCTAssertEqual(progressValues, [.init(completed: 0, total: 1), .init(completed: 1, total: 1)])
        await CodexTaskDispatcher.shared.shutdownForTesting()
    }

    func testLiveGroupedQueueCreatesSeparateThreadsOnOneBranchWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["TASKBOARD_RUN_CODEX_GROUP_TESTS"] == "1" else {
            throw XCTSkip("Set TASKBOARD_RUN_CODEX_GROUP_TESTS=1 to run the grouped queue test.")
        }

        let repo = try makeTemporaryMainRepository()
        let markers = (1...3).map { "TASKBOARD_GROUP_\($0)_\(UUID().uuidString)" }
        let groups = markers.map { marker in
            [TaskItem(title: "Reply with exactly \(marker). Do not edit files.")]
        }
        let progress = ProgressRecorder()
        let receipt = try await CodexTaskDispatcher.shared.sendGroupedQueue(
            boardTitle: "Taskboard Grouped Queue Test",
            taskGroups: groups,
            workspacePath: repo.path,
            branchChoice: .existing("main"),
            model: .recommended,
            effort: .low,
            progress: { completed, total in
                await progress.record(completed: completed, total: total)
            }
        )

        XCTAssertEqual(receipt.threads.count, 3)
        XCTAssertEqual(Set(receipt.threads.map(\.threadID)).count, 3)
        XCTAssertEqual(Set(receipt.threads.compactMap(\.branchName)), ["main"])
        XCTAssertEqual(Set(receipt.threads.map(\.worktreePath)).count, 1)
        XCTAssertEqual(receipt.completedTaskCount, 3)

        for (index, thread) in receipt.threads.enumerated() {
            let session = try persistedSession(threadID: thread.threadID)
            XCTAssertTrue(session.contains(markers[index]))
            for otherMarker in markers where otherMarker != markers[index] {
                XCTAssertFalse(session.contains(otherMarker))
            }
        }

        let progressValues = await progress.values
        XCTAssertEqual(progressValues.first, .init(completed: 0, total: 3))
        XCTAssertEqual(progressValues.last, .init(completed: 3, total: 3))
        await CodexTaskDispatcher.shared.shutdownForTesting()
    }

    func testLiveCodexDirectSendPersistsPromptWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["TASKBOARD_RUN_CODEX_INTEGRATION_TESTS"] == "1" else {
            throw XCTSkip("Set TASKBOARD_RUN_CODEX_INTEGRATION_TESTS=1 to run the live Codex test.")
        }

        let repo = try makeTemporaryMainRepository()
        let marker = "TASKBOARD_DIRECT_\(UUID().uuidString)"
        let statuses = StatusRecorder()
        let receipt = try await CodexTaskDispatcher.shared.sendDirect(
            boardTitle: "Taskboard Direct Test",
            prompt: "Reply with exactly \(marker). Do not edit files.",
            workspacePath: repo.path,
            status: { status in await statuses.record(status) }
        )

        XCTAssertFalse(receipt.threadID.isEmpty)
        XCTAssertEqual(receipt.completedTaskCount, 1)
        let session = try persistedSession(threadID: receipt.threadID)
        XCTAssertTrue(session.contains("Reply with exactly \(marker). Do not edit files."))
        XCTAssertFalse(session.contains("Sent directly from Taskboard"))
        XCTAssertFalse(session.contains("finish with a concise summary"))
        let history = try persistedHistory(threadID: receipt.threadID)
        XCTAssertEqual(history.title, "Reply with exactly \(marker). Do not edit files.")
        XCTAssertFalse(history.preview.isEmpty)
        let capturedStatuses = await statuses.values
        XCTAssertEqual(
            capturedStatuses.map(\.phase),
            [.waiting, .connecting, .creatingThread, .sending, .running]
        )
        XCTAssertNil(capturedStatuses[2].threadID)
        XCTAssertEqual(capturedStatuses[3].threadID, receipt.threadID)
        XCTAssertEqual(capturedStatuses[4].threadID, receipt.threadID)
        await CodexTaskDispatcher.shared.shutdownForTesting()
    }

    func testLiveTwoConsecutiveDirectSendsWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["TASKBOARD_RUN_CODEX_INTEGRATION_TESTS"] == "1" else {
            throw XCTSkip("Set TASKBOARD_RUN_CODEX_INTEGRATION_TESTS=1 to run the live Codex test.")
        }

        let repo = try makeTemporaryMainRepository()
        let firstMarker = "TASKBOARD_FIRST_\(UUID().uuidString)"
        let secondMarker = "TASKBOARD_SECOND_\(UUID().uuidString)"

        let first = try await CodexTaskDispatcher.shared.sendDirect(
            boardTitle: "First Direct Test",
            prompt: "Reply with exactly \(firstMarker). Do not edit files.",
            workspacePath: repo.path
        )
        let second = try await CodexTaskDispatcher.shared.sendDirect(
            boardTitle: "Second Direct Test",
            prompt: "Reply with exactly \(secondMarker). Do not edit files.",
            workspacePath: repo.path
        )

        XCTAssertNotEqual(first.threadID, second.threadID)
        XCTAssertTrue(try persistedSession(threadID: first.threadID).contains(firstMarker))
        XCTAssertTrue(try persistedSession(threadID: second.threadID).contains(secondMarker))
        await CodexTaskDispatcher.shared.shutdownForTesting()
    }

    func testLiveTwoConcurrentDirectSendsWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["TASKBOARD_RUN_CODEX_INTEGRATION_TESTS"] == "1" else {
            throw XCTSkip("Set TASKBOARD_RUN_CODEX_INTEGRATION_TESTS=1 to run the live Codex test.")
        }

        let repo = try makeTemporaryMainRepository()
        let firstMarker = "TASKBOARD_CONCURRENT_FIRST_\(UUID().uuidString)"
        let secondMarker = "TASKBOARD_CONCURRENT_SECOND_\(UUID().uuidString)"

        async let first = CodexTaskDispatcher.shared.sendDirect(
            boardTitle: "Concurrent First",
            prompt: "Reply with exactly \(firstMarker). Do not edit files.",
            workspacePath: repo.path
        )
        async let second = CodexTaskDispatcher.shared.sendDirect(
            boardTitle: "Concurrent Second",
            prompt: "Reply with exactly \(secondMarker). Do not edit files.",
            workspacePath: repo.path
        )

        let (firstReceipt, secondReceipt) = try await (first, second)
        XCTAssertNotEqual(firstReceipt.threadID, secondReceipt.threadID)
        XCTAssertTrue(try persistedSession(threadID: firstReceipt.threadID).contains(firstMarker))
        XCTAssertTrue(try persistedSession(threadID: secondReceipt.threadID).contains(secondMarker))
        await CodexTaskDispatcher.shared.shutdownForTesting()
    }

    private func makeTemporaryMainRepository() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("taskboard-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try run(["git", "init", "-b", "main"], at: url)
        try run(["git", "config", "user.email", "taskboard-tests@example.com"], at: url)
        try run(["git", "config", "user.name", "Taskboard Tests"], at: url)
        try Data("integration test\n".utf8).write(to: url.appendingPathComponent("README.md"))
        try run(["git", "add", "README.md"], at: url)
        try run(["git", "commit", "-m", "Initial commit"], at: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func run(_ arguments: [String], at directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "Command failed: \(arguments.joined(separator: " "))")
    }

    private func persistedSession(threadID: String) throws -> String {
        let sessionsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsURL,
            includingPropertiesForKeys: nil
        ) else {
            return ""
        }

        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let contents = try String(contentsOf: url, encoding: .utf8)
            if contents.contains(threadID) {
                return contents
            }
        }
        return ""
    }

    private func persistedHistory(threadID: String) throws -> (title: String, preview: String) {
        let database = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/state_5.sqlite").path
        let escapedID = threadID.replacingOccurrences(of: "'", with: "''")
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-separator", "\u{1F}", database,
            "select title, preview from threads where id = '\(escapedID)';"]
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let value = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .newlines)
            .split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
            .map(String.init)
        XCTAssertEqual(value.count, 2, "Thread was not present in Codex history")
        return (value.first ?? "", value.count > 1 ? value[1] : "")
    }
}

private actor ProgressRecorder {
    struct Value: Equatable {
        let completed: Int
        let total: Int
    }

    private(set) var values: [Value] = []

    func record(completed: Int, total: Int) {
        values.append(Value(completed: completed, total: total))
    }
}

private actor StatusRecorder {
    private(set) var values: [CodexDispatchStatus] = []

    func record(_ status: CodexDispatchStatus) {
        values.append(status)
    }
}
