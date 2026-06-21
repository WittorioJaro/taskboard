import Foundation
import Observation

enum CodexRunPhase: String, Codable, Sendable {
    case waiting
    case connecting
    case creatingThread
    case sending
    case running
    case completed
    case failed

    var isActive: Bool {
        switch self {
        case .waiting, .connecting, .creatingThread, .sending, .running:
            true
        case .completed, .failed:
            false
        }
    }

    var title: String {
        switch self {
        case .waiting: "Waiting"
        case .connecting: "Connecting"
        case .creatingThread: "Creating thread"
        case .sending: "Sending"
        case .running: "Running"
        case .completed: "Done"
        case .failed: "Failed"
        }
    }

    var systemImage: String {
        switch self {
        case .waiting: "clock"
        case .connecting: "point.3.connected.trianglepath.dotted"
        case .creatingThread: "text.bubble"
        case .sending: "paperplane"
        case .running: "bolt.horizontal.circle"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

struct CodexDispatchStatus: Sendable {
    let phase: CodexRunPhase
    let threadID: String?
    let completedCount: Int
    let totalCount: Int

    init(
        _ phase: CodexRunPhase,
        threadID: String? = nil,
        completedCount: Int = 0,
        totalCount: Int = 1
    ) {
        self.phase = phase
        self.threadID = threadID
        self.completedCount = completedCount
        self.totalCount = totalCount
    }
}

struct CodexRunRecord: Identifiable, Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case direct
        case queue
    }

    let id: UUID
    let boardID: TaskBoard.ID
    let taskID: TaskItem.ID?
    let title: String
    let kind: Kind
    let startedAt: Date
    var updatedAt: Date
    var phase: CodexRunPhase
    var threadID: String?
    var completedCount: Int
    var totalCount: Int
    var errorMessage: String?

    var progressText: String? {
        guard totalCount > 1 else { return nil }
        return "\(completedCount)/\(totalCount)"
    }
}

@MainActor
@Observable
final class CodexRunMonitor {
    static let shared = CodexRunMonitor()

    private(set) var runs: [CodexRunRecord]
    private let defaults: UserDefaults
    private let defaultsKey = "codexRunActivity"
    private let maximumStoredRuns = 30

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: defaultsKey),
           let savedRuns = try? JSONDecoder().decode([CodexRunRecord].self, from: data) {
            runs = savedRuns.map { run in
                guard run.phase.isActive else { return run }
                var interrupted = run
                interrupted.phase = .failed
                interrupted.updatedAt = .now
                interrupted.errorMessage = "Taskboard closed before this run finished."
                return interrupted
            }
        } else {
            runs = []
        }
        persist()
    }

    @discardableResult
    func start(
        boardID: TaskBoard.ID,
        taskID: TaskItem.ID?,
        title: String,
        kind: CodexRunRecord.Kind,
        totalCount: Int = 1
    ) -> UUID {
        let run = CodexRunRecord(
            id: UUID(),
            boardID: boardID,
            taskID: taskID,
            title: title,
            kind: kind,
            startedAt: .now,
            updatedAt: .now,
            phase: .waiting,
            completedCount: 0,
            totalCount: totalCount,
            errorMessage: nil
        )
        runs.insert(run, at: 0)
        trimAndPersist()
        return run.id
    }

    func apply(_ status: CodexDispatchStatus, to runID: UUID) {
        guard let index = runs.firstIndex(where: { $0.id == runID }) else { return }
        runs[index].phase = status.phase
        runs[index].updatedAt = .now
        runs[index].completedCount = status.completedCount
        runs[index].totalCount = status.totalCount
        if let threadID = status.threadID {
            runs[index].threadID = threadID
        }
        persist()
    }

    func complete(_ runID: UUID, receipt: CodexLaunchReceipt) {
        guard let index = runs.firstIndex(where: { $0.id == runID }) else { return }
        runs[index].phase = .completed
        runs[index].updatedAt = .now
        runs[index].threadID = receipt.threadID
        runs[index].completedCount = receipt.completedTaskCount
        runs[index].errorMessage = nil
        persist()
    }

    func fail(_ runID: UUID, error: Error) {
        guard let index = runs.firstIndex(where: { $0.id == runID }) else { return }
        runs[index].phase = .failed
        runs[index].updatedAt = .now
        runs[index].errorMessage = error.localizedDescription
        persist()
    }

    func recentRuns(for boardID: TaskBoard.ID, limit: Int = 3) -> [CodexRunRecord] {
        Array(runs.lazy.filter { $0.boardID == boardID }.prefix(limit))
    }

    func latestRun(for taskID: TaskItem.ID) -> CodexRunRecord? {
        runs.first(where: { $0.taskID == taskID })
    }

    func clearFinished(for boardID: TaskBoard.ID) {
        runs.removeAll { $0.boardID == boardID && !$0.phase.isActive }
        persist()
    }

    func removeRuns(for taskID: TaskItem.ID) {
        runs.removeAll { $0.taskID == taskID }
        persist()
    }

    private func trimAndPersist() {
        if runs.count > maximumStoredRuns {
            runs.removeLast(runs.count - maximumStoredRuns)
        }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(runs) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
