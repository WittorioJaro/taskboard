import Foundation
import Observation
import SwiftUI
#if os(macOS)
import AppKit
import Darwin
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
    private let enablesCloudSync: Bool
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var cloudSync: CloudKitSyncService?
#if os(macOS)
    private var firebaseSync: FirebaseSyncService?
    private var supabaseSync: SupabaseSyncService?
    private var supabaseFallbackTask: Task<Void, Never>?
    private var firebaseFallbackTask: Task<Void, Never>?
    private var lastDiskSnapshot: TaskBoardSnapshot?
    private var externalEditTask: Task<Void, Never>?
#endif

    init(
        fileManager: FileManager = .default,
        enablesCloudSync: Bool = true,
        storageURL: URL? = nil,
        watchesExternalEdits: Bool = true
    ) {
        persistenceURL = storageURL ?? Self.makePersistenceURL(fileManager: fileManager)
        self.enablesCloudSync = enablesCloudSync
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
#if os(macOS)
            lastDiskSnapshot = snapshot
#endif
        } else {
            boards = [
                TaskBoard(title: "Inbox", themeID: BoardTheme.defaultTheme.id),
            ]
            selectedBoardID = boards.first?.id
            writeSnapshotToDisk(currentSnapshot)
        }

        #if os(macOS)
        if watchesExternalEdits {
            externalEditTask = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(2))
                    } catch {
                        return
                    }
                    self?.reloadExternalEdits()
                }
            }
        }
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

#if os(macOS)
    isolated deinit {
        externalEditTask?.cancel()
        firebaseFallbackTask?.cancel()
    }
#endif

    var selectedBoard: TaskBoard? {
        boards.first(where: { $0.id == selectedBoardID })
    }

    static func dayKey(for date: Date = .now) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    func sourceBoard(for taskID: TaskItem.ID) -> TaskBoard? {
        boards.first { $0.tasks.contains { $0.id == taskID } }
    }

    /// A Today board is a projection. Its stored tasks remain personal captures;
    /// project tasks are selected by date and never copied or moved.
    func displayBoard(for boardID: TaskBoard.ID, on date: Date = .now) -> TaskBoard? {
        guard var board = board(for: boardID) else { return nil }
        guard board.isTodayBoard else { return board }
        let day = Self.dayKey(for: date)
        board.tasks = boards.flatMap { source in
            source.tasks.filter { source.id == boardID || $0.plannedFor == day }
        }.enumerated().sorted { left, right in
            let lhs = left.element.plannedFor == day ? left.element.todayOrder ?? Int.max : Int.max
            let rhs = right.element.plannedFor == day ? right.element.todayOrder ?? Int.max : Int.max
            return lhs == rhs ? left.offset < right.offset : lhs < rhs
        }.map(\.element)
        return board
    }

    func setTaskDeadline(taskID: TaskItem.ID, in boardID: TaskBoard.ID, date: Date?) {
        guard let b = boards.firstIndex(where: { $0.id == boardID }),
              let t = boards[b].tasks.firstIndex(where: { $0.id == taskID }) else { return }
        let dueDate = date.map { TaskDeadline.key(for: $0) }
        guard boards[b].tasks[t].dueDate != dueDate else { return }
        boards[b].tasks[t].dueDate = dueDate
        persist("Set Deadline")
    }

    func planTask(taskID: TaskItem.ID, in boardID: TaskBoard.ID, for date: Date? = .now) {
        guard let b = boards.firstIndex(where: { $0.id == boardID }),
              let t = boards[b].tasks.firstIndex(where: { $0.id == taskID }) else { return }
        if date != nil && !boards.contains(where: \.isTodayBoard) {
            boards.insert(TaskBoard(title: "Today", themeID: "sunrise"), at: 0)
            planTask(taskID: taskID, in: boardID, for: date)
            return
        }
        let day = date.map { Self.dayKey(for: $0) }
        let next = boards.flatMap(\.tasks).filter { $0.plannedFor == day }.compactMap(\.todayOrder).max() ?? -1
        boards[b].tasks[t].plannedFor = day
        boards[b].tasks[t].todayOrder = day == nil ? nil : next + 1
        persist("Plan for Today")
    }

    func prioritizeTodayTask(taskID: TaskItem.ID, before targetID: TaskItem.ID) {
        guard let today = boards.first(where: \.isTodayBoard),
              var tasks = displayBoard(for: today.id)?.openTasks,
              let from = tasks.firstIndex(where: { $0.id == taskID }),
              tasks.contains(where: { $0.id == targetID }), taskID != targetID else { return }
        let task = tasks.remove(at: from)
        tasks.insert(task, at: tasks.firstIndex(where: { $0.id == targetID })!)
        for (order, task) in tasks.enumerated() {
            guard let b = boards.firstIndex(where: { $0.tasks.contains { $0.id == task.id } }),
                  let t = boards[b].tasks.firstIndex(where: { $0.id == task.id }) else { continue }
            boards[b].tasks[t].plannedFor = Self.dayKey()
            boards[b].tasks[t].todayOrder = order
        }
        persist("Reorder Today")
    }

    /// Changes the board shown on this device. Selection is local UI state:
    /// remote snapshots may update board content, but must not navigate the user.
    func selectBoard(id: TaskBoard.ID) {
        guard boards.contains(where: { $0.id == id }), selectedBoardID != id else { return }
        selectedBoardID = id
        if writeSnapshotToDisk(currentSnapshot) {
            scheduleCloudSave()
        }
    }

    var pendingTaskCount: Int {
        boards.reduce(into: 0) { partialResult, board in
            partialResult += board.openTasks.count
        }
    }

    func addBoard(named rawTitle: String, folderPath rawFolderPath: String = "", t3Project: (id: String, title: String)? = nil) {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let folderPath = rawFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = title.isEmpty ? suggestedBoardTitle() : title
        let board = TaskBoard(
            title: finalTitle,
            themeID: BoardTheme.random(excluding: Set(boards.map(\.themeID))).id,
            folderPath: folderPath,
            t3ProjectID: t3Project?.id,
            t3ProjectTitle: t3Project?.title
        )

        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
            boards.insert(board, at: 0)
            selectedBoardID = board.id
        }
        persist("Add Board")
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

        persist("Delete Board")
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
        persist("Add Task")
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
        persist("Rename Task")
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
        persist("Move Task")
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

        if didChange { persist("Move Task") }
    }

    func toggleBoardExpansion(id: TaskBoard.ID) {
        guard let boardIndex = boards.firstIndex(where: { $0.id == id }) else {
            return
        }

        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            boards[boardIndex].isExpanded.toggle()
        }
        persist(undoName: nil)
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
        persist("Pin Board")
    }

    func setFolderPath(_ rawFolderPath: String, for boardID: TaskBoard.ID) {
        guard let boardIndex = boards.firstIndex(where: { $0.id == boardID }) else {
            return
        }

        boards[boardIndex].folderPath = rawFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        persist("Set Folder")
    }

    func linkT3Project(id projectID: String?, title: String?, for boardID: TaskBoard.ID) {
        guard let boardIndex = boards.firstIndex(where: { $0.id == boardID }),
              boards[boardIndex].t3ProjectID != projectID || boards[boardIndex].t3ProjectTitle != title else {
            return
        }

        boards[boardIndex].t3ProjectID = projectID
        boards[boardIndex].t3ProjectTitle = projectID == nil ? nil : title
        persist("Link Project")
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
        persist("Move Board")
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
        persist("Reorder Tasks")
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
        T3RunMonitor.shared.removeRuns(for: taskID)
#endif
        persist("Mark Done")
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
            persist("Mark Done")
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
        if FirebasePreferences.isEnabled && FirebasePreferences.hasProjectConfiguration {
            syncStatus = .syncing
            guard let firebaseSync = await FirebaseSyncService.configured() else {
                syncStatus = .error("Firebase sign-in is unavailable. Reconnect in Settings → Firebase Sync.")
                return
            }
            await startFirebaseSync(firebaseSync)
        } else if let supabaseSync = SupabaseSyncService() {
            self.supabaseSync = supabaseSync
            await startSupabaseSync()
        } else if CloudKitSyncService.isEntitled {
            let cloudSync = CloudKitSyncService()
            self.cloudSync = cloudSync
            await startCloudSync()
        }
    }

    func startFirebaseSync(_ firebaseSync: FirebaseSyncService, enablesRealtime: Bool = true) async {
        self.firebaseSync = firebaseSync
        firebaseSync.onSyncResult = { [weak self] result in self?.applySyncResult(result) }
        firebaseSync.onSavedSnapshot = { [weak self] snapshot in
            guard let self, snapshot.cloudRepresentation != self.currentSnapshot.cloudRepresentation else { return }
            self.apply(snapshot)
        }
        syncStatus = .syncing
        do {
            // Durable local edits must be uploaded before accepting cloud data.
            if firebaseSync.hasPendingSave {
                try await firebaseSync.save(snapshot: currentSnapshot)
            } else if let remoteSnapshot = try await firebaseSync.fetchSnapshot() {
                if firebaseSync.hasPendingSave {
                    try await firebaseSync.save(snapshot: currentSnapshot)
                } else if currentSnapshot.hasUserContent && !remoteSnapshot.hasUserContent {
                    try await firebaseSync.save(snapshot: currentSnapshot)
                } else {
                    apply(remoteSnapshot)
                }
            } else {
                try await firebaseSync.save(snapshot: currentSnapshot)
            }
            if !firebaseSync.hasPendingSave { syncStatus = .synced }
        } catch {
            syncStatus = .error(error.localizedDescription)
            NSLog("taskboard Firebase startup error: %@", error.localizedDescription)
        }
        // A temporary startup failure must not disable sync until next launch.
        guard enablesRealtime else { return }
        firebaseSync.startRealtime(onSnapshot: { [weak self] remoteSnapshot in
                guard let self, self.firebaseSync?.hasPendingSave != true else { return }
                if remoteSnapshot.cloudRepresentation != self.currentSnapshot.cloudRepresentation {
                    self.apply(remoteSnapshot)
                }
                // Each reconnect delivers the full value; clear a stale stream error.
                self.syncStatus = .synced
        }, onError: { [weak self] error in
            self?.syncStatus = .error(error.localizedDescription)
        })
        beginFirebaseFallback(firebaseSync)
    }

    private func beginFirebaseFallback(_ service: FirebaseSyncService) {
        firebaseFallbackTask?.cancel()
        firebaseFallbackTask = Task { [weak self, weak service] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self, let service, self.firebaseSync === service else { return }
                guard !service.hasPendingSave,
                      (try? await service.remoteChangedSinceLastRead()) == true else { continue }
                await self.refreshFromFirebase(service)
            }
        }
    }

    func reconnectCloudSync() async {
        syncStatus = .idle
        firebaseSync?.stop()
        firebaseSync = nil
        firebaseFallbackTask?.cancel()
        supabaseFallbackTask?.cancel()
        supabaseSync = nil
        await startPreferredCloudSync()
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

    /// Also checked before every write, so a save between polls preserves edits
    /// already written by another local tool such as the Kindle dashboard.
    func reloadExternalEdits() {
        guard let external = Self.loadSnapshot(from: persistenceURL, decoder: decoder),
              !external.boards.isEmpty,
              external.cloudRepresentation != lastDiskSnapshot?.cloudRepresentation else { return }
        if writeSnapshotToDisk(currentSnapshot) {
            scheduleCloudSave()
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
        if writeSnapshotToDisk(currentSnapshot) {
            scheduleCloudSave()
        }
    }

    private func persist(_ actionName: String) {
        persist(undoName: actionName)
    }

    private func persist(undoName: String? = "Change") {
#if os(macOS)
        let before = lastDiskSnapshot
        let after = currentSnapshot
#endif
        writeSnapshotToDisk(currentSnapshot)
        scheduleCloudSave()
#if os(macOS)
        if let undoName, let before { registerUndo(undoName, before: before, after: after) }
#endif
    }

#if os(macOS)
    private var suppressesUndo = false
    @ObservationIgnored var undoManagerProvider: @MainActor () -> UndoManager? = {
        NSApp?.keyWindow?.undoManager ?? NSApp?.mainWindow?.undoManager
    }

    /// Runs automatic changes, such as a settled T3 thread moving its task,
    /// without adding them to the user's undo history.
    func withoutUndo(_ body: () -> Void) {
        let previous = suppressesUndo
        suppressesUndo = true
        defer { suppressesUndo = previous }
        body()
    }

    /// Registers with the key window's undo manager, the same stack text
    /// fields use, so ⌘Z after adding a task removes the task first.
    private func registerUndo(_ name: String, before: TaskBoardSnapshot, after: TaskBoardSnapshot) {
        guard !suppressesUndo,
              before.cloudRepresentation != after.cloudRepresentation,
              let manager = undoManagerProvider() else { return }
        manager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated {
                store.revert(name, to: before, from: after)
            }
        }
        manager.setActionName(name)
    }

    /// Reverts only what the action changed. Edits that arrived since, from
    /// sync or another tool, are kept by merging against the action's result.
    private func revert(_ name: String, to before: TaskBoardSnapshot, from after: TaskBoardSnapshot) {
        let current = currentSnapshot
        let restored = before.mergingExternalChanges(from: current, since: after)
        withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
            boards = restored.boards.isEmpty ? current.boards : restored.boards
            if let selected = selectedBoardID, !boards.contains(where: { $0.id == selected }) {
                selectedBoardID = boards.first?.id
            }
        }
        // Registering while the undo manager is undoing creates the redo entry.
        persist(undoName: name)
    }
#endif

    private func scheduleCloudSave() {
        let snapshot = currentSnapshot
#if os(macOS)
        if let firebaseSync {
            syncStatus = .syncing
            firebaseSync.scheduleSave(snapshot: snapshot) { [weak self] result in
                self?.applySyncResult(result)
            }
            return
        }
        if enablesCloudSync && FirebasePreferences.isEnabled && FirebasePreferences.hasProjectConfiguration,
           let rawURL = UserDefaults.standard.string(forKey: FirebasePreferences.databaseURLKey),
           let url = URL(string: rawURL),
           let email = UserDefaults.standard.string(forKey: FirebasePreferences.emailKey) {
            do {
                try FirebaseSyncService.stagePendingUpload(snapshot, databaseURL: url, email: email, at: FirebaseSyncService.defaultPendingUploadURL)
            } catch {
                syncStatus = .error(error.localizedDescription)
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

    /// Returns whether external content was incorporated and needs uploading.
    @discardableResult
    private func writeSnapshotToDisk(_ proposedSnapshot: TaskBoardSnapshot) -> Bool {
#if os(macOS)
        do {
            try FileManager.default.createDirectory(at: persistenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            NSLog("taskboard persistence directory error: %@", error.localizedDescription)
            return false
        }
        let descriptor = open(persistenceURL.appendingPathExtension("lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { return false }
        defer { flock(descriptor, LOCK_UN) }
#endif
        var snapshot = proposedSnapshot
#if os(macOS)
        if let baseline = lastDiskSnapshot,
           let external = Self.loadSnapshot(from: persistenceURL, decoder: decoder),
           !external.boards.isEmpty,
           external.cloudRepresentation != baseline.cloudRepresentation {
            snapshot = proposedSnapshot.mergingExternalChanges(from: external, since: baseline)
        }
#endif
        if snapshot.boards.isEmpty {
            snapshot.boards = [TaskBoard(title: "Inbox")]
        }
        let incorporatedExternalContent = snapshot.cloudRepresentation != proposedSnapshot.cloudRepresentation
        boards = snapshot.boards
        selectedBoardID = snapshot.selectedBoardID.flatMap { selected in
            boards.contains(where: { $0.id == selected }) ? selected : nil
        } ?? boards.first?.id
        snapshot = currentSnapshot
        do {
            let data = try encoder.encode(snapshot)
            let directory = persistenceURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: persistenceURL, options: .atomic)
#if os(macOS)
            lastDiskSnapshot = snapshot
#endif
        } catch {
            NSLog("taskboard persistence error: \(error.localizedDescription)")
        }
        return incorporatedExternalContent
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
