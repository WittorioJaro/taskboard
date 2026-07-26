import Foundation
import Observation
import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

@MainActor
@Observable
final class TaskBoardStore {
    var boards: [TaskBoard]
    var selectedBoardID: TaskBoard.ID?
    var copiedTaskID: TaskItem.ID?
    private(set) var syncStatus: CloudSyncStatus = .idle

    private let persistenceURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var cloudSync: CloudKitSyncService?
#if os(macOS)
    private var firebaseSync: FirebaseSyncService?
    private var supabaseSync: SupabaseSyncService?
    private var supabaseFallbackTask: Task<Void, Never>?
#endif

    init(fileManager: FileManager = .default, enablesCloudSync: Bool = true) {
        persistenceURL = Self.makePersistenceURL(fileManager: fileManager)
#if os(macOS)
        firebaseSync = nil
        supabaseSync = nil
        cloudSync = nil
#else
        cloudSync = enablesCloudSync && CloudKitSyncService.isEntitled ? CloudKitSyncService() : nil
#endif
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        if let snapshot = Self.loadSnapshot(from: persistenceURL, decoder: decoder) {
            boards = snapshot.boards
            selectedBoardID = snapshot.selectedBoardID ?? snapshot.boards.first?.id
        } else {
            boards = [
                TaskBoard(title: "Inbox", themeID: BoardTheme.defaultTheme.id),
            ]
            selectedBoardID = boards.first?.id
            writeSnapshotToDisk(currentSnapshot)
        }

        #if os(macOS)
        if enablesCloudSync {
            Task { [weak self] in
                // Keychain access can block while macOS validates a newly
                // installed signature. Let AppKit finish launching first so
                // any access prompt can be displayed instead of hanging init.
                try? await Task.sleep(for: .milliseconds(500))
                await self?.startPreferredCloudSync()
            }
        }
        #else
        if cloudSync != nil {
            Task { [weak self] in
                await self?.startCloudSync()
            }
        }
        #endif
    }

    var selectedBoard: TaskBoard? {
        boards.first(where: { $0.id == selectedBoardID })
    }

    /// Changes the board shown on this device. Selection is local UI state:
    /// remote snapshots may update board content, but must not navigate the user.
    func selectBoard(id: TaskBoard.ID) {
        guard boards.contains(where: { $0.id == id }), selectedBoardID != id else { return }
        selectedBoardID = id
        writeSnapshotToDisk(currentSnapshot)
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
#if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(task.title, forType: .string)
#elseif os(iOS)
        UIPasteboard.general.string = task.title
#endif
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
#if os(macOS)
        CodexRunMonitor.shared.removeRuns(for: taskID)
#endif
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

    func refreshFromCloud() async {
#if os(macOS)
        if let firebaseSync {
            await refreshFromFirebase(firebaseSync)
            return
        }
        if let supabaseSync {
            await refreshFromSupabase(supabaseSync)
            return
        }
#endif
        guard let cloudSync else { return }
        syncStatus = .syncing
        do {
            if let remoteSnapshot = try await cloudSync.fetchSnapshot() {
                apply(remoteSnapshot)
            }
            syncStatus = .synced
        } catch {
            syncStatus = .error(error.localizedDescription)
        }
    }

    func handleRemoteNotification() {
        Task { [weak self] in
            await self?.refreshFromCloud()
        }
    }

    private func startCloudSync() async {
        guard let cloudSync else { return }
        syncStatus = .syncing

        do {
            if let remoteSnapshot = try await cloudSync.start() {
                if currentSnapshot.hasUserContent && !remoteSnapshot.hasUserContent {
                    try await cloudSync.save(snapshot: currentSnapshot)
                } else {
                    apply(remoteSnapshot)
                }
            } else {
                try await cloudSync.save(snapshot: currentSnapshot)
            }
            try await cloudSync.createSubscriptionIfNeeded()
            syncStatus = .synced
        } catch {
            syncStatus = .error(error.localizedDescription)
        }
    }

#if os(macOS)
    private func startPreferredCloudSync() async {
        if let firebaseSync = FirebaseSyncService() {
            self.firebaseSync = firebaseSync
            await startFirebaseSync()
        } else if let supabaseSync = SupabaseSyncService() {
            self.supabaseSync = supabaseSync
            await startSupabaseSync()
        } else if CloudKitSyncService.isEntitled {
            let cloudSync = CloudKitSyncService()
            self.cloudSync = cloudSync
            await startCloudSync()
        }
    }

    private func startFirebaseSync() async {
        guard let firebaseSync else { return }
        syncStatus = .syncing
        do {
            if let remoteSnapshot = try await firebaseSync.fetchSnapshot() {
                if currentSnapshot.hasUserContent && !remoteSnapshot.hasUserContent {
                    try await firebaseSync.save(snapshot: currentSnapshot)
                } else {
                    apply(remoteSnapshot)
                }
            } else {
                try await firebaseSync.save(snapshot: currentSnapshot)
            }
            firebaseSync.startRealtime { [weak self] remoteSnapshot in
                guard let self,
                      self.firebaseSync?.hasPendingSave != true,
                      remoteSnapshot.cloudRepresentation != self.currentSnapshot.cloudRepresentation else {
                    return
                }
                self.apply(remoteSnapshot)
                self.syncStatus = .synced
            }
            syncStatus = .synced
        } catch {
            syncStatus = .error(error.localizedDescription)
        }
    }

    private func refreshFromFirebase(_ service: FirebaseSyncService) async {
        guard !service.hasPendingSave else { return }
        do {
            if let remoteSnapshot = try await service.fetchSnapshot(),
               remoteSnapshot.cloudRepresentation != currentSnapshot.cloudRepresentation,
               !service.hasPendingSave {
                apply(remoteSnapshot)
            }
            syncStatus = .synced
        } catch {
            syncStatus = .error(error.localizedDescription)
        }
    }

    private func startSupabaseSync() async {
        guard let supabaseSync else { return }
        syncStatus = .syncing
        do {
            if let remoteSnapshot = try await supabaseSync.fetchSnapshot() {
                if currentSnapshot.hasUserContent && !remoteSnapshot.hasUserContent {
                    try await supabaseSync.save(snapshot: currentSnapshot)
                } else {
                    apply(remoteSnapshot)
                }
            } else {
                try await supabaseSync.save(snapshot: currentSnapshot)
            }
            try await supabaseSync.startRealtime { [weak self] remoteSnapshot in
                guard let self,
                      self.supabaseSync?.hasPendingSave != true,
                      remoteSnapshot.cloudRepresentation != self.currentSnapshot.cloudRepresentation else {
                    return
                }
                self.apply(remoteSnapshot)
                self.syncStatus = .synced
            }
            syncStatus = .synced
        } catch {
            syncStatus = .error(error.localizedDescription)
        }
        // Realtime is the primary path. This tiny metadata request is a safety
        // net for missed websocket events and refreshes expired auth sessions.
        beginSupabaseFallback()
    }

    private func refreshFromSupabase(_ service: SupabaseSyncService) async {
        guard !service.hasPendingSave else { return }
        do {
            if let remoteSnapshot = try await service.fetchSnapshotIfChanged(),
               remoteSnapshot.cloudRepresentation != currentSnapshot.cloudRepresentation,
               !service.hasPendingSave {
                apply(remoteSnapshot)
            }
            syncStatus = .synced
        } catch {
            syncStatus = .error(error.localizedDescription)
        }
    }

    private func beginSupabaseFallback() {
        supabaseFallbackTask?.cancel()
        supabaseFallbackTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self, let service = self.supabaseSync else { return }
                await self.refreshFromSupabase(service)
            }
        }
    }
#endif

    private var currentSnapshot: TaskBoardSnapshot {
        TaskBoardSnapshot(boards: boards, selectedBoardID: selectedBoardID)
    }

    private func apply(_ snapshot: TaskBoardSnapshot) {
        guard !snapshot.boards.isEmpty else { return }
        let localSelection = selectedBoardID
        boards = snapshot.boards
        selectedBoardID = localSelection.flatMap { selected in
            snapshot.boards.contains(where: { $0.id == selected }) ? selected : nil
        } ?? snapshot.selectedBoardID.flatMap { selected in
            snapshot.boards.contains(where: { $0.id == selected }) ? selected : nil
        } ?? snapshot.boards.first?.id
        writeSnapshotToDisk(currentSnapshot)
    }

    private func persist() {
        let snapshot = TaskBoardSnapshot(boards: boards, selectedBoardID: selectedBoardID)
        writeSnapshotToDisk(snapshot)
#if os(macOS)
        if let firebaseSync {
            firebaseSync.scheduleSave(snapshot: snapshot) { [weak self] result in
                self?.applySyncResult(result)
            }
            return
        }
        if let supabaseSync {
            supabaseSync.scheduleSave(snapshot: snapshot) { [weak self] result in
                self?.applySyncResult(result)
            }
            return
        }
#endif
        cloudSync?.scheduleSave(snapshot: snapshot) { [weak self] result in
            self?.applySyncResult(result)
        }
    }

    private func applySyncResult(_ result: Result<Void, Error>) {
        switch result {
        case .success:
            syncStatus = .synced
        case .failure(let error):
            syncStatus = .error(error.localizedDescription)
        }
    }

    private func writeSnapshotToDisk(_ snapshot: TaskBoardSnapshot) {
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

struct TaskBoardSnapshot: Codable, Sendable, Equatable {
    var boards: [TaskBoard]
    var selectedBoardID: TaskBoard.ID?

    var hasUserContent: Bool {
        boards.count > 1
            || boards.contains { !$0.tasks.isEmpty || $0.title != "Inbox" || !$0.folderPath.isEmpty }
    }

    var cloudRepresentation: Self {
        Self(boards: boards, selectedBoardID: nil)
    }
}
