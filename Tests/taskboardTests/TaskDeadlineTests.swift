import Foundation
import XCTest
@testable import taskboard

@MainActor
final class TaskDeadlineTests: XCTestCase {
    func testDateOnlyValidationAndYearBoundaryLabels() throws {
        XCTAssertNotNil(TaskDeadline.date(for: "2028-02-29"))
        for invalid in ["2026-02-29", "2026-02-30", "2026-13-01", "2026-1-01", "2026-11-01T00:00:00Z", ""] {
            XCTAssertNil(TaskDeadline.date(for: invalid), invalid)
        }
        let today = try XCTUnwrap(TaskDeadline.date(for: "2026-12-31"))
        XCTAssertEqual(TaskDeadline.label(for: "2026-12-31", relativeTo: today), "Due today")
        XCTAssertEqual(TaskDeadline.label(for: "2027-01-01", relativeTo: today), "Due tomorrow")
        XCTAssertTrue(TaskDeadline.label(for: "2026-12-30", relativeTo: today)!.hasPrefix("Overdue"))
        let lateToday = Calendar.current.date(byAdding: .hour, value: 23, to: today)!
        XCTAssertFalse(TaskDeadline.isOverdue("2026-12-31", on: lateToday))
        XCTAssertTrue(TaskDeadline.isOverdue("2026-12-30", on: today))
        XCTAssertFalse(TaskDeadline.isOverdue("invalid", on: today))
    }

    func testDeadlineRoundTripsAndOldTasksRemainUndated() throws {
        let task = TaskItem(title: "Old task")
        XCTAssertNil(try JSONDecoder().decode(TaskItem.self, from: JSONEncoder().encode(task)).dueDate)
        let dated = TaskItem(title: "Dated", plannedFor: "2026-11-01", todayOrder: 2, dueDate: "2026-11-04")
        XCTAssertEqual(try JSONDecoder().decode(TaskItem.self, from: JSONEncoder().encode(dated)), dated)
    }

    func testChangingDeadlineFromTodayEditsSourceAndPreservesThePlan() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = directory.appendingPathComponent("boards.json")
        let task = TaskItem(title: "Project task", plannedFor: TaskBoardStore.dayKey(), todayOrder: 0)
        let today = TaskBoard(title: "Today")
        let project = TaskBoard(title: "Project", t3ProjectID: "original-project", tasks: [task])
        try JSONEncoder().encode(TaskBoardSnapshot(boards: [today, project], selectedBoardID: today.id)).write(to: storage)
        let store = TaskBoardStore(enablesCloudSync: false, storageURL: storage, watchesExternalEdits: false)
        store.setTaskDeadline(taskID: task.id, in: store.sourceBoard(for: task.id)!.id, date: TaskDeadline.date(for: "2026-11-04"))
        XCTAssertEqual(store.displayBoard(for: today.id)?.tasks.first?.dueDate, "2026-11-04")
        XCTAssertEqual(store.board(for: project.id)?.t3ProjectID, "original-project")
        XCTAssertTrue(store.board(for: today.id)!.tasks.isEmpty)
        XCTAssertEqual(store.task(for: task.id, in: project.id)?.plannedFor, task.plannedFor)
        store.setTaskDeadline(taskID: task.id, in: project.id, date: nil)
        let saved = try JSONDecoder().decode(TaskBoardSnapshot.self, from: Data(contentsOf: storage))
        XCTAssertNil(saved.boards[1].tasks[0].dueDate)
        XCTAssertEqual(saved.boards[1].tasks[0].todayOrder, 0)
    }

    func testDeadlineMergesIndependentlyFromPlanAndCompletion() {
        let base = TaskBoardSnapshot(boards: [TaskBoard(title: "Project", tasks: [TaskItem(title: "Task", dueDate: "2026-11-04")])])
        var local = base
        local.boards[0].tasks[0].plannedFor = "2026-11-01"
        var remote = base
        remote.boards[0].tasks[0].dueDate = "2026-11-02"
        remote.boards[0].tasks[0].isCompleted = true
        let merged = local.mergingExternalChanges(from: remote, since: base).boards[0].tasks[0]
        XCTAssertEqual(merged.plannedFor, "2026-11-01")
        XCTAssertEqual(merged.dueDate, "2026-11-02")
        XCTAssertTrue(merged.isCompleted)
        local.boards[0].tasks[0].dueDate = nil
        XCTAssertNil(local.mergingExternalChanges(from: remote, since: base).boards[0].tasks[0].dueDate)
    }
}
