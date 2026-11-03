import Foundation
import XCTest
@testable import taskboard

@MainActor
final class UndoTests: XCTestCase {
    func testUndoRemovesAnAddedTaskAndRedoRestoresIt() throws {
        let board = TaskBoard(title: "Inbox", tasks: [TaskItem(title: "Existing")])
        try withStore([board]) { store, undo in
            var added: TaskItem.ID?
            step(undo) { added = store.addTask(to: board.id, title: "New") }
            let addedID = try XCTUnwrap(added)
            XCTAssertEqual(undo.undoActionName, "Add Task")
            undo.undo()
            XCTAssertNil(store.task(for: addedID, in: board.id))
            XCTAssertEqual(store.board(for: board.id)?.tasks.map(\.title), ["Existing"])
            undo.redo()
            XCTAssertEqual(store.board(for: board.id)?.tasks.map(\.title), ["Existing", "New"])
        }
    }

    func testUndoMarkDoneRestoresTheOpenTaskInPlace() throws {
        let first = TaskItem(title: "First", statusOverride: .running)
        let second = TaskItem(title: "Second")
        let board = TaskBoard(title: "Inbox", tasks: [first, second])
        try withStore([board]) { store, undo in
            step(undo) { store.markTaskDone(taskID: first.id, in: board.id) }
            XCTAssertTrue(store.task(for: first.id, in: board.id)!.isCompleted)
            undo.undo()
            let restored = try XCTUnwrap(store.task(for: first.id, in: board.id))
            XCTAssertFalse(restored.isCompleted)
            XCTAssertEqual(restored.statusOverride, .running)
            XCTAssertNil(restored.completedAt)
            XCTAssertEqual(store.board(for: board.id)?.tasks.map(\.title), ["First", "Second"])
        }
    }

    func testUndoKeepsEditsMadeElsewhereAfterTheAction() throws {
        let task = TaskItem(title: "Synced")
        let board = TaskBoard(title: "Inbox", tasks: [task])
        try withStore([board]) { store, undo in
            step(undo) { store.markTaskDone(taskID: task.id, in: board.id) }
            // Another change lands later, e.g. a rename from the phone.
            store.withoutUndo { store.renameTask(taskID: task.id, in: board.id, title: "Renamed on phone") }
            undo.undo()
            let restored = try XCTUnwrap(store.task(for: task.id, in: board.id))
            XCTAssertFalse(restored.isCompleted)
            XCTAssertEqual(restored.title, "Renamed on phone")
        }
    }

    func testAutomaticChangesAreNotUndoable() throws {
        let task = TaskItem(title: "Agent task")
        let board = TaskBoard(title: "Inbox", tasks: [task])
        try withStore([board]) { store, undo in
            store.withoutUndo { store.moveTask(taskID: task.id, in: board.id, to: .done) }
            XCTAssertFalse(undo.canUndo)
        }
    }

    /// AppKit opens one undo group per event; mirror that for each action.
    private func step(_ undo: UndoManager, _ action: () -> Void) {
        undo.beginUndoGrouping()
        action()
        undo.endUndoGrouping()
    }

    private func withStore(_ boards: [TaskBoard], body: (TaskBoardStore, UndoManager) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("boards.json")
        try JSONEncoder().encode(TaskBoardSnapshot(boards: boards, selectedBoardID: boards.first?.id))
            .write(to: url, options: .atomic)
        let store = TaskBoardStore(enablesCloudSync: false, storageURL: url, watchesExternalEdits: false)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManagerProvider = { undo }
        try body(store, undo)
    }
}
