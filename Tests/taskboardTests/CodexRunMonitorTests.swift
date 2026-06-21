import Foundation
import XCTest
@testable import taskboard

@MainActor
final class CodexRunMonitorTests: XCTestCase {
    func testTracksAndPersistsRunLifecycle() {
        let defaults = makeDefaults()
        let monitor = CodexRunMonitor(defaults: defaults)
        let boardID = UUID()
        let taskID = UUID()
        let runID = monitor.start(
            boardID: boardID,
            taskID: taskID,
            title: "Fix the send flow",
            kind: .direct
        )

        monitor.apply(.init(.creatingThread), to: runID)
        monitor.apply(.init(.running, threadID: "thread-123"), to: runID)
        monitor.complete(
            runID,
            receipt: CodexLaunchReceipt(
                threadID: "thread-123",
                branchName: nil,
                worktreePath: "/tmp/repo",
                completedTaskCount: 1
            )
        )

        let run = monitor.latestRun(for: taskID)
        XCTAssertEqual(run?.phase, .completed)
        XCTAssertEqual(run?.threadID, "thread-123")

        let restored = CodexRunMonitor(defaults: defaults)
        XCTAssertEqual(restored.latestRun(for: taskID)?.phase, .completed)
        XCTAssertEqual(restored.recentRuns(for: boardID).count, 1)
    }

    func testMarksPersistedActiveRunAsFailedAfterRestart() {
        let defaults = makeDefaults()
        let monitor = CodexRunMonitor(defaults: defaults)
        let taskID = UUID()
        let runID = monitor.start(
            boardID: UUID(),
            taskID: taskID,
            title: "Long-running task",
            kind: .direct
        )
        monitor.apply(.init(.running, threadID: "thread-456"), to: runID)

        let restored = CodexRunMonitor(defaults: defaults)
        let run = restored.latestRun(for: taskID)
        XCTAssertEqual(run?.phase, .failed)
        XCTAssertEqual(run?.threadID, "thread-456")
        XCTAssertEqual(run?.errorMessage, "Taskboard closed before this run finished.")
    }

    func testRemovingTaskRunsClearsActiveAndFinishedActivity() {
        let monitor = CodexRunMonitor(defaults: makeDefaults())
        let boardID = UUID()
        let taskID = UUID()
        let activeRunID = monitor.start(
            boardID: boardID,
            taskID: taskID,
            title: "Active task",
            kind: .direct
        )
        monitor.apply(.init(.running, threadID: "thread-active"), to: activeRunID)
        _ = monitor.start(
            boardID: boardID,
            taskID: taskID,
            title: "Previous task run",
            kind: .direct
        )
        _ = monitor.start(
            boardID: boardID,
            taskID: nil,
            title: "Board queue",
            kind: .queue
        )

        monitor.removeRuns(for: taskID)

        XCTAssertNil(monitor.latestRun(for: taskID))
        XCTAssertEqual(monitor.recentRuns(for: boardID).count, 1)
        XCTAssertEqual(monitor.recentRuns(for: boardID).first?.kind, .queue)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "CodexRunMonitorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}
