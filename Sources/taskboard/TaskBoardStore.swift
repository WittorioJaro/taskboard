import AppKit
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class TaskBoardStore {
    var boards: [TaskBoard]
    var selectedBoardID: TaskBoard.ID?
    var copiedTaskID: TaskItem.ID?

    private let persistenceURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default) {
        persistenceURL = Self.makePersistenceURL(fileManager: fileManager)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        if let snapshot = Self.loadSnapshot(from: persistenceURL, decoder: decoder) {
            boards = snapshot.boards
            selectedBoardID = snapshot.selectedBoardID ?? snapshot.boards.first?.id
        } else {
            boards = [
                TaskBoard(title: "Inbox", themeID: BoardTheme.defaultTheme.id),
            ]
            selectedBoardID = boards.first?.id
            persist()
        }
    }

    var selectedBoard: TaskBoard? {
        boards.first(where: { $0.id == selectedBoardID })
    }

    var pendingTaskCount: Int {
        boards.reduce(into: 0) { partialResult, board in
            partialResult += board.openTasks.count
        }
    }

    func addBoard(named rawTitle: String, folderPath rawFolderPath: String = "") {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let folderPath = rawFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = title.isEmpty ? suggestedBoardTitle() : title
        let board = TaskBoard(
            title: finalTitle,
            themeID: BoardTheme.random(excluding: Set(boards.map(\.themeID))).id,
            folderPath: folderPath
        )

        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
            boards.insert(board, at: 0)
            selectedBoardID = board.id
        }
        persist()
    }

    func deleteBoard(id: TaskBoard.ID) {
        guard let boardIndex = boards.firstIndex(where: { $0.id == id }) else {
            return
        }

        withAnimation(.spring(response: 0.35, dampingFraction: 0.92)) {
            boards.remove(at: boardIndex)
            if selectedBoardID == id {
                selectedBoardID = boards.first?.id
            }
        }

        if boards.isEmpty {
            let fallbackBoard = TaskBoard(title: "Inbox", themeID: BoardTheme.defaultTheme.id)
            boards = [fallbackBoard]
            selectedBoardID = fallbackBoard.id
        }

        persist()
    }

    @discardableResult
    func addTask(
        to boardID: TaskBoard.ID,
        title rawTitle: String,
        attachments: [TaskAttachment] = []
    ) -> TaskItem.ID? {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let boardIndex = boards.firstIndex(where: { $0.id == boardID }) else {
            return nil
        }

        let task = TaskItem(title: title, attachments: attachments)
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            boards[boardIndex].tasks.append(task)
        }
        persist()
        return task.id
    }

    func renameTask(taskID: TaskItem.ID, in boardID: TaskBoard.ID, title rawTitle: String) {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !title.isEmpty,
            let boardIndex = boards.firstIndex(where: { $0.id == boardID }),
            let taskIndex = boards[boardIndex].tasks.firstIndex(where: { $0.id == taskID })
        else {
            return
        }

        guard boards[boardIndex].tasks[taskIndex].title != title else {
            return
        }

        boards[boardIndex].tasks[taskIndex].title = title
        persist()
    }

    func moveTask(taskID: TaskItem.ID, in boardID: TaskBoard.ID, to status: TaskStatus) {
        guard
            let boardIndex = boards.firstIndex(where: { $0.id == boardID }),
            let taskIndex = boards[boardIndex].tasks.firstIndex(where: { $0.id == taskID }),
            !boards[boardIndex].tasks[taskIndex].isCompleted,
            boards[boardIndex].tasks[taskIndex].statusOverride != status
        else {
            return
        }

        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            boards[boardIndex].tasks[taskIndex].statusOverride = status
        }
        persist()
    }

    func clearTaskStatusOverride(taskIDs: [TaskItem.ID], in boardID: TaskBoard.ID) {
        guard let boardIndex = boards.firstIndex(where: { $0.id == boardID }) else { return }
        let taskIDs = Set(taskIDs)
        var didChange = false

        for taskIndex in boards[boardIndex].tasks.indices
        where taskIDs.contains(boards[boardIndex].tasks[taskIndex].id)
            && boards[boardIndex].tasks[taskIndex].statusOverride != nil {
            boards[boardIndex].tasks[taskIndex].statusOverride = nil
            didChange = true
        }

        if didChange { persist() }
    }

    func toggleBoardExpansion(id: TaskBoard.ID) {
        guard let boardIndex = boards.firstIndex(where: { $0.id == id }) else {
            return
        }

        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            boards[boardIndex].isExpanded.toggle()
        }
        persist()
    }

    func toggleBoardPin(id: TaskBoard.ID) {
        guard let boardIndex = boards.firstIndex(where: { $0.id == id }) else {
            return
        }

        let shouldPin = !boards[boardIndex].isPinned
        withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) {
            for index in boards.indices {
                boards[index].isPinned = shouldPin && index == boardIndex
            }
        }
        persist()
    }

    func setFolderPath(_ rawFolderPath: String, for boardID: TaskBoard.ID) {
        guard let boardIndex = boards.firstIndex(where: { $0.id == boardID }) else {
            return
        }

        boards[boardIndex].folderPath = rawFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        persist()
    }

    func moveBoard(draggedID: TaskBoard.ID, to targetID: TaskBoard.ID) {
        guard
            draggedID != targetID,
            let fromIndex = boards.firstIndex(where: { $0.id == draggedID }),
            let toIndex = boards.firstIndex(where: { $0.id == targetID })
        else {
            return
        }

        withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
            boards.move(
                fromOffsets: IndexSet(integer: fromIndex),
                toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
            )
        }
        persist()
    }

    func moveOpenTask(draggedID: TaskItem.ID, in boardID: TaskBoard.ID, to targetID: TaskItem.ID) {
        guard let boardIndex = boards.firstIndex(where: { $0.id == boardID }) else {
            return
        }

        var openTasks = boards[boardIndex].openTasks
        let completedTasks = boards[boardIndex].tasks.filter(\.isCompleted)

        guard
            draggedID != targetID,
            let fromIndex = openTasks.firstIndex(where: { $0.id == draggedID }),
            let toIndex = openTasks.firstIndex(where: { $0.id == targetID })
        else {
            return
        }

        withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
            openTasks.move(
                fromOffsets: IndexSet(integer: fromIndex),
                toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
            )
            boards[boardIndex].tasks = openTasks + completedTasks
        }
        persist()
    }

    func copyTask(_ task: TaskItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(task.title, forType: .string)
        copiedTaskID = task.id

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard self?.copiedTaskID == task.id else {
                return
            }
            self?.copiedTaskID = nil
        }
    }

    func markTaskDone(taskID: TaskItem.ID, in boardID: TaskBoard.ID) {
        guard
            let boardIndex = boards.firstIndex(where: { $0.id == boardID }),
            let taskIndex = boards[boardIndex].tasks.firstIndex(where: { $0.id == taskID })
        else {
            return
        }

        guard !boards[boardIndex].tasks[taskIndex].isCompleted else {
            return
        }

        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
            var task = boards[boardIndex].tasks.remove(at: taskIndex)
            task.isCompleted = true
            task.statusOverride = nil
            task.completedAt = .now
            boards[boardIndex].tasks.append(task)
        }
        CodexRunMonitor.shared.removeRuns(for: taskID)
        persist()
    }

    func markTasksDone(taskIDs: Set<TaskItem.ID>, in boardID: TaskBoard.ID) {
        guard
            !taskIDs.isEmpty,
            let boardIndex = boards.firstIndex(where: { $0.id == boardID })
        else {
            return
        }

        var didChange = false
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
            for taskIndex in boards[boardIndex].tasks.indices
            where taskIDs.contains(boards[boardIndex].tasks[taskIndex].id)
                && !boards[boardIndex].tasks[taskIndex].isCompleted {
                boards[boardIndex].tasks[taskIndex].isCompleted = true
                boards[boardIndex].tasks[taskIndex].statusOverride = nil
                boards[boardIndex].tasks[taskIndex].completedAt = .now
                didChange = true
            }

            if didChange {
                boards[boardIndex].tasks = boards[boardIndex].openTasks
                    + boards[boardIndex].tasks.filter(\.isCompleted)
            }
        }

        if didChange {
            persist()
        }
    }

    func board(for boardID: TaskBoard.ID) -> TaskBoard? {
        boards.first(where: { $0.id == boardID })
    }

    func task(for taskID: TaskItem.ID, in boardID: TaskBoard.ID) -> TaskItem? {
        board(for: boardID)?.tasks.first(where: { $0.id == taskID })
    }

    private func suggestedBoardTitle() -> String {
        let base = "Board"
        let existingTitles = Set(boards.map(\.title))
        var index = 1

        while existingTitles.contains("\(base) \(index)") {
            index += 1
        }

        return "\(base) \(index)"
    }

    private func persist() {
        let snapshot = TaskBoardSnapshot(boards: boards, selectedBoardID: selectedBoardID)

        do {
            let data = try encoder.encode(snapshot)
            let directory = persistenceURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: persistenceURL, options: .atomic)
        } catch {
            NSLog("taskboard persistence error: \(error.localizedDescription)")
        }
    }

    private static func loadSnapshot(from url: URL, decoder: JSONDecoder) -> TaskBoardSnapshot? {
        do {
            let data = try Data(contentsOf: url)
            return try decoder.decode(TaskBoardSnapshot.self, from: data)
        } catch {
            return nil
        }
    }

    private static func makePersistenceURL(fileManager: FileManager) -> URL {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())

        return applicationSupport
            .appendingPathComponent("taskboard", isDirectory: true)
            .appendingPathComponent("boards.json", isDirectory: false)
    }
}

private struct TaskBoardSnapshot: Codable {
    var boards: [TaskBoard]
    var selectedBoardID: TaskBoard.ID?
}
