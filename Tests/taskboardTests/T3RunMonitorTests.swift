import Foundation
import XCTest
@testable import taskboard

@MainActor
final class T3RunMonitorTests: XCTestCase {
    func testPollingMovesRunThroughPhasesAndReportsSettlement() async {
        let provider = StubThreadStateProvider()
        let monitor = T3RunMonitor(defaults: makeDefaults(), provider: provider, pollInterval: .seconds(60))
        let taskID = UUID()
        var settledTaskIDs: [TaskItem.ID] = []
        monitor.onSettled = { settledTaskIDs.append($0.taskID) }

        let runID = monitor.start(boardID: UUID(), taskID: taskID, projectID: "p1", modelLabel: "GPT · Codex")
        XCTAssertEqual(monitor.latestRun(for: taskID)?.phase, .launching)

        monitor.attach(T3LaunchReceipt(threadID: "t1", status: "starting"), to: runID)
        monitor.stopPolling()
        XCTAssertEqual(monitor.latestRun(for: taskID)?.phase, .starting)

        await provider.set(T3ThreadState(threadID: "t1", status: "running", settled: false, archived: false, pendingRequestCount: 0))
        await monitor.pollOnce()
        XCTAssertEqual(monitor.latestRun(for: taskID)?.phase, .running)

        await provider.set(T3ThreadState(threadID: "t1", status: "completed", settled: false, archived: false, pendingRequestCount: 0))
        await monitor.pollOnce()
        XCTAssertEqual(monitor.latestRun(for: taskID)?.phase, .completed)
        XCTAssertTrue(settledTaskIDs.isEmpty)

        await provider.set(T3ThreadState(threadID: "t1", status: "completed", settled: true, archived: false, pendingRequestCount: 0))
        await monitor.pollOnce()
        XCTAssertEqual(monitor.latestRun(for: taskID)?.phase, .settled)
        XCTAssertEqual(settledTaskIDs, [taskID])

        // Settled runs are no longer polled, so the callback fires once.
        await monitor.pollOnce()
        XCTAssertEqual(settledTaskIDs, [taskID])
        XCTAssertFalse(monitor.hasMonitoredRuns)
    }

    func testMonitoredRunsSurviveRestartButUnfinishedLaunchesFail() {
        let defaults = makeDefaults()
        let monitor = T3RunMonitor(defaults: defaults, provider: StubThreadStateProvider())
        let runningTask = UUID()
        let launchingTask = UUID()
        let runID = monitor.start(boardID: UUID(), taskID: runningTask, projectID: "p1", modelLabel: "m")
        monitor.attach(T3LaunchReceipt(threadID: "t1", status: "running"), to: runID)
        monitor.stopPolling()
        monitor.start(boardID: UUID(), taskID: launchingTask, projectID: "p1", modelLabel: "m")

        let restored = T3RunMonitor(defaults: defaults, provider: StubThreadStateProvider())
        XCTAssertEqual(restored.latestRun(for: runningTask)?.phase, .running)
        XCTAssertEqual(restored.latestRun(for: runningTask)?.threadID, "t1")
        XCTAssertTrue(restored.hasMonitoredRuns)
        XCTAssertEqual(restored.latestRun(for: launchingTask)?.phase, .failed)
    }

    func testDeletedThreadFailsRunWithoutSettling() async {
        let provider = StubThreadStateProvider()
        await provider.setError(T3CodeError.threadNotFound("t1"))
        let monitor = T3RunMonitor(defaults: makeDefaults(), provider: provider)
        var didSettle = false
        monitor.onSettled = { _ in didSettle = true }
        let taskID = UUID()
        let runID = monitor.start(boardID: UUID(), taskID: taskID, projectID: "p1", modelLabel: "m")
        monitor.attach(T3LaunchReceipt(threadID: "t1", status: "running"), to: runID)
        monitor.stopPolling()

        await monitor.pollOnce()

        XCTAssertEqual(monitor.latestRun(for: taskID)?.phase, .failed)
        XCTAssertFalse(didSettle)
    }

    func testTransientErrorsKeepPolling() async {
        let provider = StubThreadStateProvider()
        await provider.setError(T3CodeError.serverUnavailable("http://127.0.0.1:3773"))
        let monitor = T3RunMonitor(defaults: makeDefaults(), provider: provider)
        let taskID = UUID()
        let runID = monitor.start(boardID: UUID(), taskID: taskID, projectID: "p1", modelLabel: "m")
        monitor.attach(T3LaunchReceipt(threadID: "t1", status: "running"), to: runID)
        monitor.stopPolling()

        await monitor.pollOnce()

        XCTAssertEqual(monitor.latestRun(for: taskID)?.phase, .running)
        XCTAssertTrue(monitor.hasMonitoredRuns)
    }

    func testRemovingTaskRunsClearsActivity() {
        let monitor = T3RunMonitor(defaults: makeDefaults(), provider: StubThreadStateProvider())
        let taskID = UUID()
        monitor.start(boardID: UUID(), taskID: taskID, projectID: "p1", modelLabel: "m")
        monitor.removeRuns(for: taskID)
        XCTAssertNil(monitor.latestRun(for: taskID))
    }

    func testMapsThreadStatuses() {
        XCTAssertEqual(T3RunPhase(threadStatus: "queued"), .starting)
        XCTAssertEqual(T3RunPhase(threadStatus: "running"), .running)
        XCTAssertEqual(T3RunPhase(threadStatus: "waiting"), .waiting)
        XCTAssertEqual(T3RunPhase(threadStatus: "completed"), .completed)
        XCTAssertEqual(T3RunPhase(threadStatus: "interrupted"), .stopped)
        XCTAssertTrue(T3RunPhase.stopped.isMonitored)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "T3RunMonitorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private actor StubThreadStateProvider: T3ThreadStateProviding {
    private var state: T3ThreadState?
    private var error: Error?

    func set(_ state: T3ThreadState) {
        self.state = state
        error = nil
    }

    func setError(_ error: Error) {
        self.error = error
    }

    func threadState(threadID: String) async throws -> T3ThreadState {
        if let error { throw error }
        guard let state else { throw T3CodeError.serverUnavailable("stub") }
        return state
    }
}
