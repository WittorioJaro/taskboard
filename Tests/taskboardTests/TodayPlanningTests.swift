import Foundation
import XCTest
@testable import taskboard

@MainActor
final class TodayPlanningTests: XCTestCase {
    func testTodayProjectsOriginalTasksInPriorityOrderAndCompletionChangesSource() throws {
        let first = TaskItem(title: "First")
        let second = TaskItem(title: "Second")
        let today = TaskBoard(title: "Today", tasks: [TaskItem(title: "Personal")])
        let project = TaskBoard(title: "Project", t3ProjectID: "original-project", tasks: [first, second])
        try withStore([today, project]) { store in
            store.planTask(taskID: second.id, in: project.id)
            store.planTask(taskID: first.id, in: project.id)
            XCTAssertEqual(store.displayBoard(for: today.id)?.openTasks.map(\.title), ["Second", "First", "Personal"])
            XCTAssertEqual(store.board(for: today.id)?.tasks.count, 1)
            XCTAssertEqual(store.sourceBoard(for: second.id)?.t3ProjectID, "original-project")
            store.markTaskDone(taskID: second.id, in: store.sourceBoard(for: second.id)!.id)
            XCTAssertTrue(store.task(for: second.id, in: project.id)!.isCompleted)
            XCTAssertEqual(store.displayBoard(for: today.id)?.openTasks.map(\.title), ["First", "Personal"])
        }
    }

    func testDatedPlansExpireWithoutRemovingTheProjectTask() throws {
        let task = TaskItem(title: "Yesterday", plannedFor: "2026-10-30", todayOrder: 0)
        let today = TaskBoard(title: " Today ")
        let project = TaskBoard(title: "Project", tasks: [task])
        try withStore([today, project]) { store in
            let date = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 31))!
            XCTAssertTrue(store.displayBoard(for: today.id, on: date)!.tasks.isEmpty)
            XCTAssertEqual(store.board(for: project.id)?.tasks, [task])
        }
    }

    func testPlanningCreatesTodayAndUnplanningKeepsTheOriginal() throws {
        let task = TaskItem(title: "Project task")
        let project = TaskBoard(title: "Project", tasks: [task])
        try withStore([project]) { store in
            store.planTask(taskID: task.id, in: project.id)
            let today = try XCTUnwrap(store.boards.first(where: \.isTodayBoard))
            XCTAssertEqual(store.displayBoard(for: today.id)?.tasks.map(\.id), [task.id])
            store.planTask(taskID: task.id, in: project.id, for: nil)
            XCTAssertTrue(store.displayBoard(for: today.id)!.tasks.isEmpty)
            XCTAssertEqual(store.board(for: project.id)?.tasks.count, 1)
        }
    }

    func testPriorityOrderSurvivesReloadWithoutMovingTasksBetweenBoards() throws {
        let first = TaskItem(title: "First", plannedFor: TaskBoardStore.dayKey(), todayOrder: 0)
        let second = TaskItem(title: "Second", plannedFor: TaskBoardStore.dayKey(), todayOrder: 1)
        let today = TaskBoard(title: "Today")
        let a = TaskBoard(title: "A", tasks: [first])
        let b = TaskBoard(title: "B", tasks: [second])
        try withStore([today, a, b]) { store in
            store.prioritizeTodayTask(taskID: second.id, before: first.id)
            XCTAssertEqual(store.displayBoard(for: today.id)?.tasks.map(\.id), [second.id, first.id])
            XCTAssertEqual(store.board(for: a.id)?.tasks.map(\.id), [first.id])
            XCTAssertEqual(store.board(for: b.id)?.tasks.map(\.id), [second.id])
            let encoded = try JSONEncoder().encode(TaskBoardSnapshot(boards: store.boards))
            let decoded = try JSONDecoder().decode(TaskBoardSnapshot.self, from: encoded)
            XCTAssertEqual(decoded.boards, store.boards)
        }
    }

    func testExternalKindleCompletionAndAgentPlanMergeWithLocalRename() {
        let task = TaskItem(title: "Original")
        let base = TaskBoardSnapshot(boards: [TaskBoard(title: "Project", tasks: [task])])
        var local = base
        local.boards[0].tasks[0].title = "Edited on Mac"
        var remote = base
        remote.boards[0].tasks[0].plannedFor = "2026-10-31"
        remote.boards[0].tasks[0].todayOrder = 2
        remote.boards[0].tasks[0].isCompleted = true
        remote.boards[0].tasks[0].completedAt = Date(timeIntervalSince1970: 100)
        let merged = local.mergingExternalChanges(from: remote, since: base).boards[0].tasks[0]
        XCTAssertEqual(merged.title, "Edited on Mac")
        XCTAssertEqual(merged.plannedFor, "2026-10-31")
        XCTAssertEqual(merged.todayOrder, 2)
        XCTAssertTrue(merged.isCompleted)
    }

    private func withStore(_ boards: [TaskBoard], body: (TaskBoardStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = directory.appendingPathComponent("boards.json")
        try JSONEncoder().encode(TaskBoardSnapshot(boards: boards, selectedBoardID: boards.first?.id)).write(to: storage)
        let store = TaskBoardStore(enablesCloudSync: false, storageURL: storage, watchesExternalEdits: false)
        try body(store)
    }
}
