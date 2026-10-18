import Foundation
import Observation

enum T3RunPhase: String, Codable, Sendable {
    case launching
    case starting
    case running
    case waiting
    case completed
    case stopped
    case settled
    case failed

    /// Maps a T3 durable run status onto the phase a task row shows.
    init(threadStatus: String) {
        switch threadStatus {
        case "running": self = .running
        case "waiting": self = .waiting
        case "completed": self = .completed
        case "interrupted", "failed", "cancelled", "rolled_back": self = .stopped
        default: self = .starting
        }
    }

    var isActive: Bool {
        switch self {
        case .launching, .starting, .running, .waiting: true
        case .completed, .stopped, .settled, .failed: false
        }
    }

    /// Runs the background job keeps polling until T3 settles the thread.
    var isMonitored: Bool {
        self != .settled && self != .failed && self != .launching
    }

    var title: String {
        switch self {
        case .launching: "Launching"
        case .starting: "Starting"
        case .running: "Running"
        case .waiting: "Needs input"
        case .completed: "Ready for review"
        case .stopped: "Stopped"
        case .settled: "Settled"
        case .failed: "Failed"
        }
    }

    var systemImage: String {
        switch self {
        case .launching: "paperplane"
        case .starting: "hourglass"
        case .running: "bolt.horizontal.circle"
        case .waiting: "hand.raised.fill"
        case .completed: "checkmark.bubble"
        case .stopped: "stop.circle"
        case .settled: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

struct T3RunRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let boardID: TaskBoard.ID
    let taskID: TaskItem.ID
    let projectID: String
    let modelLabel: String
    let startedAt: Date
    var updatedAt: Date
    var phase: T3RunPhase
    var threadID: String?
    var errorMessage: String?
}

protocol T3ThreadStateProviding: Sendable {
    func threadState(threadID: String) async throws -> T3ThreadState
}

extension T3CodeClient: T3ThreadStateProviding {}

/// Tracks threads Taskboard launched in T3 Code and polls them in the background.
/// When T3 settles a thread (the user or auto-settlement moves it out of the
/// active list), `onSettled` fires so the board can move the task to done.
@MainActor
@Observable
final class T3RunMonitor {
    static let shared = T3RunMonitor()

    private(set) var runs: [T3RunRecord]
    @ObservationIgnored var onSettled: ((T3RunRecord) -> Void)?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let provider: T3ThreadStateProviding
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    private let defaultsKey = "t3RunActivity"
    private let maximumStoredRuns = 60

    init(
        defaults: UserDefaults = .standard,
        provider: T3ThreadStateProviding = T3CodeClient.shared,
        pollInterval: Duration = .seconds(10)
    ) {
        self.defaults = defaults
        self.provider = provider
        self.pollInterval = pollInterval
        if let data = defaults.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode([T3RunRecord].self, from: data) {
            // A launch that never returned a thread id cannot be resumed.
            runs = saved.map { run in
                guard run.phase == .launching else { return run }
                var interrupted = run
                interrupted.phase = .failed
                interrupted.errorMessage = "Taskboard closed before T3 Code created the thread."
                return interrupted
            }
        } else {
            runs = []
        }
        persist()
    }

    var hasMonitoredRuns: Bool {
        runs.contains { $0.phase.isMonitored && $0.threadID != nil }
    }

    @discardableResult
    func start(boardID: TaskBoard.ID, taskID: TaskItem.ID, projectID: String, modelLabel: String) -> UUID {
        let run = T3RunRecord(
            id: UUID(),
            boardID: boardID,
            taskID: taskID,
            projectID: projectID,
            modelLabel: modelLabel,
            startedAt: .now,
            updatedAt: .now,
            phase: .launching
        )
        runs.insert(run, at: 0)
        if runs.count > maximumStoredRuns {
            runs.removeLast(runs.count - maximumStoredRuns)
        }
        persist()
        return run.id
    }

    func attach(_ receipt: T3LaunchReceipt, to runID: UUID) {
        guard let index = runs.firstIndex(where: { $0.id == runID }) else { return }
        runs[index].threadID = receipt.threadID
        runs[index].phase = receipt.status.map(T3RunPhase.init(threadStatus:)) ?? .starting
        runs[index].updatedAt = .now
        persist()
        startPolling()
    }

    func fail(_ runID: UUID, error: Error) {
        guard let index = runs.firstIndex(where: { $0.id == runID }) else { return }
        runs[index].phase = .failed
        runs[index].errorMessage = error.localizedDescription
        runs[index].updatedAt = .now
        persist()
    }

    func apply(_ state: T3ThreadState, to runID: UUID) {
        guard let index = runs.firstIndex(where: { $0.id == runID }),
              runs[index].phase.isMonitored else { return }
        let phase: T3RunPhase = state.settled ? .settled : T3RunPhase(threadStatus: state.status)
        guard runs[index].phase != phase || runs[index].errorMessage != nil else { return }
        runs[index].phase = phase
        runs[index].errorMessage = nil
        runs[index].updatedAt = .now
        persist()
        if phase == .settled {
            onSettled?(runs[index])
        }
    }

    func latestRun(for taskID: TaskItem.ID) -> T3RunRecord? {
        runs.first { $0.taskID == taskID }
    }

    func removeRuns(for taskID: TaskItem.ID) {
        let before = runs.count
        runs.removeAll { $0.taskID == taskID }
        if runs.count != before { persist() }
    }

    /// Polls every monitored thread once. Transient failures (T3 closed, network)
    /// leave the run as it was so the next tick retries.
    func pollOnce() async {
        let targets = runs.filter { $0.phase.isMonitored }.compactMap { run in
            run.threadID.map { (run.id, $0) }
        }
        for (runID, threadID) in targets {
            do {
                let state = try await provider.threadState(threadID: threadID)
                apply(state, to: runID)
            } catch T3CodeError.threadNotFound {
                if let index = runs.firstIndex(where: { $0.id == runID }) {
                    runs[index].phase = .failed
                    runs[index].errorMessage = "The T3 thread was deleted."
                    runs[index].updatedAt = .now
                    persist()
                }
            } catch {
                continue
            }
        }
    }

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.hasMonitoredRuns else { break }
                await self.pollOnce()
                try? await Task.sleep(for: self.pollInterval)
            }
            self?.pollTask = nil
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(runs) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
