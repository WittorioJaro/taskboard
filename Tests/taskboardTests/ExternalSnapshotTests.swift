import Foundation
import XCTest
@testable import taskboard

final class ExternalSnapshotTests: XCTestCase {
    @MainActor
    func testSaveBeforePollPreservesExternalTickAndLocalRename() throws {
        let task = TaskItem(title: "Before")
        let board = TaskBoard(title: "Inbox", tasks: [task])
        try withStore(boards: [board]) { store, url, baseline in
            var external = baseline
            external.boards[0].tasks[0].isCompleted = true
            external.boards[0].tasks[0].completedAt = Date(timeIntervalSince1970: 123)
            try writeExternal(external, to: url)

            store.renameTask(taskID: task.id, in: board.id, title: "Renamed on Mac")

            let saved = try readSnapshot(url)
            XCTAssertEqual(saved.boards[0].tasks[0].title, "Renamed on Mac")
            XCTAssertTrue(saved.boards[0].tasks[0].isCompleted)
            XCTAssertEqual(saved.boards[0].tasks[0].completedAt, external.boards[0].tasks[0].completedAt)
            XCTAssertEqual(store.boards, saved.boards)
        }
    }

    @MainActor
    func testMergesExternalAndLocalTaskInsertions() throws {
        let board = TaskBoard(title: "Inbox", tasks: [TaskItem(title: "Original")])
        try withStore(boards: [board]) { store, url, baseline in
            var external = baseline
            let kindleTask = TaskItem(title: "From Kindle")
            external.boards[0].tasks.append(kindleTask)
            try writeExternal(external, to: url)

            let macTaskID = store.addTask(to: board.id, title: "From Mac")

            XCTAssertEqual(store.boards[0].tasks.count, 3)
            XCTAssertTrue(store.boards[0].tasks.contains { $0.id == kindleTask.id })
            XCTAssertTrue(store.boards[0].tasks.contains { $0.id == macTaskID })
            XCTAssertEqual(try readSnapshot(url).boards, store.boards)
        }
    }

    @MainActor
    func testExternalDeletionDoesNotDiscardOtherLocalTaskEdit() throws {
        let removed = TaskItem(title: "Remove me")
        let kept = TaskItem(title: "Keep me")
        let board = TaskBoard(title: "Inbox", tasks: [removed, kept])
        try withStore(boards: [board]) { store, url, baseline in
            var external = baseline
            external.boards[0].tasks.removeFirst()
            try writeExternal(external, to: url)

            store.renameTask(taskID: kept.id, in: board.id, title: "Edited")

            XCTAssertEqual(store.boards[0].tasks.map(\.id), [kept.id])
            XCTAssertEqual(store.boards[0].tasks[0].title, "Edited")
        }
    }

    @MainActor
    func testExternalBoardDeletionRepairsSelection() throws {
        let first = TaskBoard(title: "First")
        let second = TaskBoard(title: "Second")
        try withStore(boards: [first, second]) { store, url, baseline in
            var external = baseline
            external.boards.removeFirst()
            // Simulate an external writer retaining the now-invalid selection.
            try writeExternal(external, to: url)

            store.reloadExternalEdits()

            XCTAssertEqual(store.selectedBoardID, second.id)
            XCTAssertEqual(store.selectedBoard?.id, second.id)
            XCTAssertEqual(try readSnapshot(url).selectedBoardID, second.id)
        }
    }

    @MainActor
    func testSelectionSaveAlsoPreservesUnpolledExternalChanges() throws {
        let first = TaskBoard(title: "First", tasks: [TaskItem(title: "Tick me")])
        let second = TaskBoard(title: "Second")
        try withStore(boards: [first, second]) { store, url, baseline in
            var external = baseline
            external.boards[0].tasks[0].isCompleted = true
            try writeExternal(external, to: url)

            store.selectBoard(id: second.id)

            XCTAssertEqual(store.selectedBoardID, second.id)
            XCTAssertTrue(store.boards[0].tasks[0].isCompleted)
            XCTAssertTrue(try readSnapshot(url).boards[0].tasks[0].isCompleted)
        }
    }

    @MainActor
    func testExternalSelectionDoesNotNavigateTheMac() throws {
        let first = TaskBoard(title: "First")
        let second = TaskBoard(title: "Second")
        try withStore(boards: [first, second]) { store, url, baseline in
            var external = baseline
            external.selectedBoardID = second.id
            external.boards[1].title = "Renamed externally"
            try writeExternal(external, to: url)

            store.reloadExternalEdits()

            XCTAssertEqual(store.selectedBoardID, first.id)
            XCTAssertEqual(store.boards[1].title, "Renamed externally")
        }
    }

    @MainActor
    func testLocalCompletionConflictKeepsConsistentState() throws {
        let task = TaskItem(title: "Conflict")
        let board = TaskBoard(title: "Inbox", tasks: [task])
        try withStore(boards: [board]) { store, url, baseline in
            var external = baseline
            external.boards[0].tasks[0].isCompleted = true
            external.boards[0].tasks[0].completedAt = .now
            try writeExternal(external, to: url)

            store.moveTask(taskID: task.id, in: board.id, to: .running)

            let merged = store.boards[0].tasks[0]
            XCTAssertFalse(merged.isCompleted)
            XCTAssertEqual(merged.statusOverride, .running)
            XCTAssertNil(merged.completedAt)
        }
    }

    @MainActor
    func testLocalReorderingSurvivesExternalTick() throws {
        let first = TaskItem(title: "First")
        let second = TaskItem(title: "Second")
        let board = TaskBoard(title: "Inbox", tasks: [first, second])
        try withStore(boards: [board]) { store, url, baseline in
            var external = baseline
            external.boards[0].tasks[0].isCompleted = true
            try writeExternal(external, to: url)

            store.moveOpenTask(draggedID: second.id, in: board.id, to: first.id)

            XCTAssertEqual(store.boards[0].tasks.map(\.id), [second.id, first.id])
            XCTAssertTrue(store.boards[0].tasks[1].isCompleted)
        }
    }

    @MainActor
    func testNewMacBoardKeepsItsPositionAndExternalTick() throws {
        let board = TaskBoard(title: "Existing", tasks: [TaskItem(title: "Task")])
        try withStore(boards: [board]) { store, url, baseline in
            var external = baseline
            external.boards[0].tasks[0].isCompleted = true
            try writeExternal(external, to: url)

            store.addBoard(named: "New on Mac")

            XCTAssertEqual(store.boards.map(\.title), ["New on Mac", "Existing"])
            XCTAssertEqual(store.selectedBoardID, store.boards[0].id)
            XCTAssertTrue(store.boards[1].tasks[0].isCompleted)
        }
    }

    @MainActor
    func testConcurrentBoardDeletionsKeepAValidFallbackBoard() throws {
        let first = TaskBoard(title: "First")
        let second = TaskBoard(title: "Second")
        try withStore(boards: [first, second]) { store, url, baseline in
            var external = baseline
            external.boards.removeFirst()
            try writeExternal(external, to: url)

            store.deleteBoard(id: second.id)

            XCTAssertEqual(store.boards.count, 1)
            XCTAssertEqual(store.selectedBoard?.title, "Inbox")
            XCTAssertEqual(try readSnapshot(url).boards, store.boards)
        }
    }

    @MainActor
    func testPollDetectsChangedContentWithUnchangedModificationDate() throws {
        let board = TaskBoard(title: "Inbox", tasks: [TaskItem(title: "Task")])
        try withStore(boards: [board]) { store, url, baseline in
            let modified = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate])
            var external = baseline
            external.boards[0].tasks[0].isCompleted = true
            try writeExternal(external, to: url)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)

            store.reloadExternalEdits()

            XCTAssertTrue(store.boards[0].tasks[0].isCompleted)
        }
    }

    @MainActor
    func testPollIgnoresIncompleteSnapshotAndRetriesValidEdit() throws {
        let board = TaskBoard(title: "Inbox", tasks: [TaskItem(title: "Task")])
        try withStore(boards: [board]) { store, url, baseline in
            let incomplete = Data("{\"boards\":".utf8)
            try incomplete.write(to: url, options: .atomic)
            store.reloadExternalEdits()
            XCTAssertEqual(try Data(contentsOf: url), incomplete)
            XCTAssertEqual(store.boards, baseline.boards)

            var external = baseline
            external.boards[0].tasks[0].isCompleted = true
            try writeExternal(external, to: url)
            store.reloadExternalEdits()
            XCTAssertTrue(store.boards[0].tasks[0].isCompleted)
        }
    }

    @MainActor
    private func withStore(
        boards: [TaskBoard],
        body: (TaskBoardStore, URL, TaskBoardSnapshot) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("boards.json")
        let baseline = TaskBoardSnapshot(boards: boards, selectedBoardID: boards.first?.id)
        try JSONEncoder().encode(baseline).write(to: url, options: .atomic)
        let store = TaskBoardStore(enablesCloudSync: false, storageURL: url, watchesExternalEdits: false)
        try body(store, url, baseline)
    }

    private func writeExternal(_ snapshot: TaskBoardSnapshot, to url: URL) throws {
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }

    private func readSnapshot(_ url: URL) throws -> TaskBoardSnapshot {
        try JSONDecoder().decode(TaskBoardSnapshot.self, from: Data(contentsOf: url))
    }
}
