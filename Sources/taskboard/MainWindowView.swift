import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MainWindowView: View {
    @Bindable var store: TaskBoardStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    @State private var showingCreateBoardSheet = false
    @State private var quickTaskTitle = ""
    @State private var quickTaskAttachments: [TaskAttachment] = []
    @State private var draggedBoardID: TaskBoard.ID?
    @AppStorage("boardColumnCount") private var boardColumnCount = 3
    @FocusState private var isQuickEntryFocused: Bool

    private var clampedColumnCount: Int {
        min(max(boardColumnCount, 1), 5)
    }

    private var gridColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 260, maximum: 420), spacing: 18, alignment: .top),
            count: clampedColumnCount
        )
    }

    private var pinnedBoard: TaskBoard? {
        store.boards.first(where: \.isPinned)
    }

    private var unpinnedBoards: [TaskBoard] {
        store.boards.filter { !$0.isPinned }
    }

    var body: some View {
        ZStack {
            TaskBoardBackdrop()

            VStack(alignment: .leading, spacing: 18) {
                QuickEntryBar(
                    taskTitle: $quickTaskTitle,
                    attachments: $quickTaskAttachments,
                    selectedBoardID: $store.selectedBoardID,
                    boards: store.boards,
                    isQuickEntryFocused: $isQuickEntryFocused,
                    onSubmit: submitQuickTask,
                    onCreateBoard: {
                        showingCreateBoardSheet = true
                    }
                )

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let pinnedBoard {
                            BoardColumnView(
                                store: store,
                                boardID: pinnedBoard.id,
                                draggedBoardID: $draggedBoardID
                            )
                            .frame(maxWidth: .infinity)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 18) {
                            ForEach(unpinnedBoards) { board in
                                BoardColumnView(
                                    store: store,
                                    boardID: board.id,
                                    draggedBoardID: $draggedBoardID
                                )
                            }
                        }
                    }
                    .animation(.spring(response: 0.32, dampingFraction: 0.9), value: store.boards)
                }
                .scrollIndicators(.hidden)
            }
            .padding(24)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingCreateBoardSheet) {
            CreateBoardSheet(store: store, isPresented: $showingCreateBoardSheet)
                .preferredColorScheme(.dark)
        }
        .task {
            ensureSelectedBoard()
            requestQuickEntryFocus()
        }
        .onChange(of: showingCreateBoardSheet) { _, isPresented in
            if !isPresented {
                requestQuickEntryFocus()
            }
        }
        .onChange(of: store.boards.count) { _, _ in
            ensureSelectedBoard()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            requestQuickEntryFocus()
        }
        .onAppear {
            Task { @MainActor in
                NSApp.activate(ignoringOtherApps: true)
            }
            QuickCaptureController.shared.installWindowActions(
                openCaptureWindow: {
                    openWindow(id: SceneID.quickCaptureWindow)
                },
                openSettings: {
                    openSettings()
                }
            )
        }
    }

    private func ensureSelectedBoard() {
        if store.selectedBoardID == nil {
            store.selectedBoardID = store.boards.first?.id
        }
    }

    private func requestQuickEntryFocus() {
        guard !showingCreateBoardSheet else {
            return
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(160))
            isQuickEntryFocused = true
        }
    }

    private func submitQuickTask() {
        let trimmed = quickTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            requestQuickEntryFocus()
            return
        }

        guard let boardID = store.selectedBoardID ?? store.boards.first?.id else {
            return
        }

        store.selectedBoardID = boardID
        store.addTask(to: boardID, title: trimmed, attachments: quickTaskAttachments)
        quickTaskTitle = ""
        quickTaskAttachments = []
        requestQuickEntryFocus()
    }
}

private struct QuickEntryBar: View {
    @Binding var taskTitle: String
    @Binding var attachments: [TaskAttachment]
    @Binding var selectedBoardID: TaskBoard.ID?
    let boards: [TaskBoard]
    let isQuickEntryFocused: FocusState<Bool>.Binding
    let onSubmit: () -> Void
    let onCreateBoard: () -> Void
    @Environment(\.openSettings) private var openSettings

    private var isSubmitDisabled: Bool {
        taskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 14) {
            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    taskComposer
                    AttachmentDraftStrip(attachments: attachments) { attachment in
                        attachments.removeAll { $0.id == attachment.id }
                        TaskAttachmentStore.delete(attachment)
                    }
                }
                boardPicker
                PasteAttachmentButton(action: pasteAttachment)
                submitButton
                createBoardButton
                settingsButton
            }
            .frame(maxWidth: .infinity)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private var taskComposer: some View {
        TextField("Add a task", text: $taskTitle, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 15, weight: .medium, design: .rounded))
            .foregroundStyle(.white)
            .focused(isQuickEntryFocused)
            .lineLimit(1...6)
            .taskSubmitBehavior(onSubmit: onSubmit)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .frame(maxWidth: .infinity)
        .frame(minHeight: 44, alignment: .topLeading)
        .onKeyPress("v", phases: [.down]) { keyPress in
            guard keyPress.modifiers == .command, TaskAttachmentStore.hasImageOnPasteboard else {
                return .ignored
            }
            pasteAttachment()
            return .handled
        }
    }

    private func pasteAttachment() {
        if let attachment = TaskAttachmentStore.pasteImage() {
            attachments.append(attachment)
        }
    }

    private var boardPicker: some View {
        Picker("Board", selection: $selectedBoardID) {
            ForEach(boards) { board in
                Text(board.title).tag(board.id as TaskBoard.ID?)
            }
        }
        .pickerStyle(.menu)
        .frame(width: 160)
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var submitButton: some View {
        Button(action: onSubmit) {
            Image(systemName: "arrow.up")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 44, height: 44)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isSubmitDisabled)
        .opacity(isSubmitDisabled ? 0.45 : 1)
    }

    private var createBoardButton: some View {
        Button(action: onCreateBoard) {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("New Board")
    }

    private var settingsButton: some View {
        Button {
            openSettings()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white.opacity(0.72))
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Settings")
    }
}

private struct BoardColumnView: View {
    @Bindable var store: TaskBoardStore
    let boardID: TaskBoard.ID
    @Binding var draggedBoardID: TaskBoard.ID?

    @State private var inlineTaskTitle = ""
    @State private var inlineTaskAttachments: [TaskAttachment] = []
    @State private var isAddingInlineTask = false
    @State private var draggedTaskID: TaskItem.ID?
    @State private var showingDeleteConfirmation = false
    @State private var showingCodexSheet = false
    @State private var directSendError: String?
    @State private var runMonitor = CodexRunMonitor.shared
    @FocusState private var isInlineTaskFocused: Bool

    private var board: TaskBoard? {
        store.board(for: boardID)
    }

    var body: some View {
        if let board {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Button {
                        store.selectedBoardID = board.id
                        store.toggleBoardExpansion(id: board.id)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: board.isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Color.white.opacity(0.56))

                            VStack(alignment: .leading, spacing: 6) {
                                Text(board.title)
                                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)

                                Text("\(board.openTasks.count) open · \(board.completedCount) done")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Color.white.opacity(0.42))
                            }

                            Spacer(minLength: 8)
                        }
                    }
                    .buttonStyle(.plain)

                    Text("\(board.openTasks.count)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(board.theme.accentColor)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(board.theme.accentColor.opacity(0.12), in: Capsule())

                    Button {
                        store.selectedBoardID = board.id
                        store.toggleBoardPin(id: board.id)
                    } label: {
                        Image(systemName: board.isPinned ? "pin.fill" : "pin")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(board.isPinned ? board.theme.accentColor : Color.white.opacity(0.48))
                            .frame(width: 30, height: 30)
                            .background(
                                board.isPinned ? board.theme.accentColor.opacity(0.12) : Color.white.opacity(0.04),
                                in: Circle()
                            )
                    }
                    .buttonStyle(.plain)
                    .help(board.isPinned ? "Unpin board" : "Pin board above all others")

                    Button(action: chooseBoardFolder) {
                        Image(systemName: board.folderPath.isEmpty ? "folder.badge.plus" : "folder.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(board.folderPath.isEmpty ? Color.orange.opacity(0.9) : Color.white.opacity(0.62))
                            .frame(width: 30, height: 30)
                            .background(Color.white.opacity(0.04), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help(board.folderPath.isEmpty ? "Choose this board's folder" : board.folderPath)

                    Button {
                        store.selectedBoardID = board.id
                        showingCodexSheet = true
                    } label: {
                        Label("Codex", systemImage: "paperplane")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.06), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Send selected tasks to Codex")
                    .disabled(board.openTasks.isEmpty)
                    .opacity(board.openTasks.isEmpty ? 0.45 : 1)

                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.44))
                            .frame(width: 30, height: 30)
                            .background(Color.white.opacity(0.04), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(18)

                if board.isExpanded {
                    VStack(alignment: .leading, spacing: 0) {
                        Rectangle()
                            .fill(Color.white.opacity(0.07))
                            .frame(height: 1)

                        let doneTasks = board.openTasks.filter {
                            runMonitor.latestRun(for: $0.id)?.phase == .completed
                        }
                        let runningTasks = board.openTasks.filter {
                            runMonitor.latestRun(for: $0.id)?.phase.isActive == true
                        }
                        let todoTasks = board.openTasks.filter {
                            guard let phase = runMonitor.latestRun(for: $0.id)?.phase else { return true }
                            return !phase.isActive && phase != .completed
                        }

                        TaskSectionHeader(
                            title: "DONE",
                            count: doneTasks.count,
                            systemImage: "checkmark",
                            tint: .green
                        )

                        TaskSectionSurface(isEmpty: doneTasks.isEmpty, emptyText: "Completed tasks will land here") {
                            ForEach(doneTasks) { task in
                                MinimalTaskRow(
                                    board: board,
                                    task: task,
                                    isCopied: store.copiedTaskID == task.id,
                                    onCopy: { store.copyTask(task) },
                                    codexRun: runMonitor.latestRun(for: task.id),
                                    onSendToCodex: { _ in },
                                    onDone: {
                                        store.selectedBoardID = board.id
                                        store.markTaskDone(taskID: task.id, in: board.id)
                                    },
                                    onRename: { newTitle in
                                        store.renameTask(taskID: task.id, in: board.id, title: newTitle)
                                    },
                                    onDragStart: {}
                                )
                            }
                        }

                        TaskSectionHeader(
                            title: "RUNNING",
                            count: runningTasks.count,
                            systemImage: "waveform.path",
                            tint: board.theme.accentColor
                        )

                        TaskSectionSurface(isEmpty: runningTasks.isEmpty, emptyText: "Nothing is running") {
                            ForEach(runningTasks) { task in
                                MinimalTaskRow(
                                    board: board,
                                    task: task,
                                    isCopied: store.copiedTaskID == task.id,
                                    onCopy: { store.copyTask(task) },
                                    codexRun: runMonitor.latestRun(for: task.id),
                                    onSendToCodex: { _ in },
                                    onDone: {
                                        store.markTaskDone(taskID: task.id, in: board.id)
                                    },
                                    onRename: { newTitle in
                                        store.renameTask(taskID: task.id, in: board.id, title: newTitle)
                                    },
                                    onDragStart: {}
                                )
                            }
                        }

                        TaskSectionHeader(
                            title: "TODO",
                            count: todoTasks.count,
                            systemImage: "circle",
                            tint: Color.white.opacity(0.48)
                        )

                        TaskSectionSurface(isEmpty: todoTasks.isEmpty, emptyText: "No tasks waiting") {
                            ForEach(todoTasks) { task in
                                MinimalTaskRow(
                                    board: board,
                                    task: task,
                                    isCopied: store.copiedTaskID == task.id,
                                    onCopy: {
                                        store.selectedBoardID = board.id
                                        store.copyTask(task)
                                    },
                                    codexRun: runMonitor.latestRun(for: task.id),
                                    onSendToCodex: { taskID in
                                        sendDirectlyToCodex(taskID: taskID, boardID: board.id)
                                    },
                                    onDone: {
                                        store.selectedBoardID = board.id
                                        store.markTaskDone(taskID: task.id, in: board.id)
                                    },
                                    onRename: { newTitle in
                                        store.selectedBoardID = board.id
                                        store.renameTask(taskID: task.id, in: board.id, title: newTitle)
                                    },
                                    onDragStart: {
                                        draggedTaskID = task.id
                                        store.selectedBoardID = board.id
                                    }
                                )
                                .onDrop(
                                    of: [UTType.text],
                                    delegate: TaskReorderDropDelegate(
                                        store: store,
                                        boardID: board.id,
                                        targetTaskID: task.id,
                                        draggedTaskID: $draggedTaskID
                                    )
                                )
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }

                        InlineTaskEntryRow(
                            board: board,
                            taskTitle: $inlineTaskTitle,
                            attachments: $inlineTaskAttachments,
                            isAdding: $isAddingInlineTask,
                            isFocused: $isInlineTaskFocused,
                            onBegin: beginInlineEntry,
                            onSubmit: submitInlineTask,
                            onCancel: cancelInlineEntry
                        )
                        .padding(.horizontal, 18)
                        .padding(.top, 10)
                        .padding(.bottom, 18)
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(hex: "0E1116"))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
            .overlay(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(board.theme.accentColor.opacity(0.22), lineWidth: 1)
                    .padding(1)
            }
            .shadow(color: .black.opacity(0.22), radius: 26, x: 0, y: 18)
            .animation(.spring(response: 0.3, dampingFraction: 0.9), value: board.isExpanded)
            .animation(.spring(response: 0.3, dampingFraction: 0.9), value: board.tasks)
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .onDrag {
                draggedBoardID = board.id
                store.selectedBoardID = board.id
                return NSItemProvider(object: board.id.uuidString as NSString)
            } preview: {
                DragPreview()
            }
            .onDrop(
                of: [UTType.text],
                delegate: BoardReorderDropDelegate(
                    store: store,
                    targetBoardID: board.id,
                    draggedBoardID: $draggedBoardID
                )
            )
            .alert("Delete board?", isPresented: $showingDeleteConfirmation) {
                Button("Delete", role: .destructive) {
                    store.deleteBoard(id: board.id)
                }

                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently remove \"\(board.title)\" and every task inside it.")
            }
            .sheet(isPresented: $showingCodexSheet) {
                CodexSendSheet(store: store, boardID: board.id, isPresented: $showingCodexSheet)
                    .preferredColorScheme(.dark)
            }
            .alert("Could not send to Codex", isPresented: Binding(
                get: { directSendError != nil },
                set: { if !$0 { directSendError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(directSendError ?? "")
            }
            .onChange(of: isInlineTaskFocused) { _, isFocused in
                if !isFocused && inlineTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    isAddingInlineTask = false
                }
            }
        }
    }

    private func beginInlineEntry() {
        store.selectedBoardID = boardID
        if let board, !board.isExpanded {
            store.toggleBoardExpansion(id: board.id)
        }

        isAddingInlineTask = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            isInlineTaskFocused = true
        }
    }

    private func cancelInlineEntry() {
        inlineTaskAttachments.forEach(TaskAttachmentStore.delete)
        inlineTaskTitle = ""
        inlineTaskAttachments = []
        isAddingInlineTask = false
        isInlineTaskFocused = false
    }

    private func submitInlineTask() {
        let trimmed = inlineTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            cancelInlineEntry()
            return
        }

        store.selectedBoardID = boardID
        store.addTask(to: boardID, title: trimmed, attachments: inlineTaskAttachments)
        inlineTaskTitle = ""
        inlineTaskAttachments = []

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            isInlineTaskFocused = true
        }
    }

    private func chooseBoardFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            store.setFolderPath(url.path, for: boardID)
        }
    }

    private func sendDirectlyToCodex(taskID: TaskItem.ID, boardID: TaskBoard.ID) {
        guard let board = store.board(for: boardID),
              let task = store.task(for: taskID, in: boardID) else {
            directSendError = "This task no longer exists."
            return
        }

        let prompt = task.title
        directSendError = nil
        let runID = runMonitor.start(
            boardID: boardID,
            taskID: taskID,
            title: prompt,
            kind: .direct
        )
        Task {
            do {
                let receipt = try await CodexTaskDispatcher.shared.sendDirect(
                    boardTitle: board.title,
                    prompt: prompt,
                    attachments: task.attachments,
                    workspacePath: board.folderPath
                ) { status in
                    await MainActor.run {
                        runMonitor.apply(status, to: runID)
                    }
                }
                await MainActor.run {
                    runMonitor.complete(runID, receipt: receipt)
                }
            } catch {
                await MainActor.run {
                    runMonitor.fail(runID, error: error)
                    directSendError = error.localizedDescription
                }
            }
        }
    }
}

private struct TaskSectionHeader: View {
    let title: String
    let count: Int
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 16, height: 16)

            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(1.1)
                .foregroundStyle(Color.white.opacity(0.48))

            Spacer()

            Text("\(count)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(count == 0 ? Color.white.opacity(0.24) : tint)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }
}

private struct TaskSectionSurface<Content: View>: View {
    let isEmpty: Bool
    let emptyText: String
    @ViewBuilder let content: Content

    var body: some View {
        Group {
            if isEmpty {
                Text(emptyText)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.28))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    content
                }
            }
        }
        .background(Color.white.opacity(0.026), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.055), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 18)
    }
}

private struct InlineTaskEntryRow: View {
    let board: TaskBoard
    @Binding var taskTitle: String
    @Binding var attachments: [TaskAttachment]
    @Binding var isAdding: Bool
    let isFocused: FocusState<Bool>.Binding
    let onBegin: () -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        Group {
            if isAdding {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "circle")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.28))
                        .padding(.top, 10)

                    VStack(alignment: .leading, spacing: 8) {
                        TextField("New task", text: $taskTitle, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.92))
                            .focused(isFocused)
                            .lineLimit(1...8)
                            .taskSubmitBehavior(onSubmit: onSubmit)
                            .onKeyPress("v", phases: [.down]) { keyPress in
                                guard keyPress.modifiers == .command, TaskAttachmentStore.hasImageOnPasteboard else {
                                    return .ignored
                                }
                                pasteAttachment()
                                return .handled
                            }
                            .padding(.top, 7)

                        AttachmentDraftStrip(attachments: attachments) { attachment in
                            attachments.removeAll { $0.id == attachment.id }
                            TaskAttachmentStore.delete(attachment)
                        }
                    }

                    Button(action: pasteAttachment) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.56))
                            .frame(width: 28, height: 28)
                            .background(Color.white.opacity(0.05), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Paste image from clipboard")
                    .padding(.top, 6)

                    Button(action: onSubmit) {
                        Text("ADD")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(board.theme.accentColor, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .opacity(taskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.55 : 1)
                    .padding(.top, 6)

                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.42))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.07), lineWidth: 1)
                )
            } else {
                Button(action: onBegin) {
                    HStack(spacing: 12) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.36))

                        Text("Click to add a task")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.42))

                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private func pasteAttachment() {
        if let attachment = TaskAttachmentStore.pasteImage() {
            attachments.append(attachment)
        }
    }
}

private struct MinimalTaskRow: View {
    let board: TaskBoard
    let task: TaskItem
    let isCopied: Bool
    let onCopy: () -> Void
    let codexRun: CodexRunRecord?
    let onSendToCodex: (TaskItem.ID) -> Void
    let onDone: () -> Void
    let onRename: (String) -> Void
    let onDragStart: () -> Void

    @State private var draftTitle = ""
    @State private var isEditingTitle = false
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onDone) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.48))
            }
            .buttonStyle(.plain)
            .help("Mark done")
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 8) {
                Group {
                    if isEditingTitle {
                    TextField("Task title", text: $draftTitle, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.96))
                        .focused($isTitleFocused)
                        .lineLimit(2...10)
                        .onExitCommand(perform: cancelTitleEdit)
                    } else {
                    Button(action: beginTitleEdit) {
                        Text(task.title)
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(nil)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    }
                }

                AttachmentDraftStrip(attachments: task.attachments)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 10)

            Button(action: codexButtonAction) {
                HStack(spacing: 5) {
                    Image(systemName: codexRun?.phase.systemImage ?? "paperplane.fill")
                        .symbolEffect(.pulse, isActive: codexRun?.phase.isActive == true)
                    if codexRun != nil {
                        Text(codexButtonTitle)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                    }
                }
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(codexStatusColor)
                .padding(.horizontal, codexRun == nil ? 9 : 8)
                .frame(height: 28)
                .background(codexStatusColor.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(codexRun?.phase.isActive == true)
            .help(codexHelpText)

            Button(action: onCopy) {
                Text(isCopied ? "COPIED" : "COPY")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(isCopied ? .black : board.theme.accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        isCopied ? board.theme.accentColor : board.theme.accentColor.opacity(0.12),
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onDrag {
            onDragStart()
            return NSItemProvider(object: task.id.uuidString as NSString)
        } preview: {
            DragPreview()
        }
        .onAppear {
            draftTitle = task.title
        }
        .onChange(of: task.title) { _, newValue in
            if !isEditingTitle {
                draftTitle = newValue
            }
        }
        .onChange(of: isTitleFocused) { _, isFocused in
            if !isFocused && isEditingTitle {
                commitTitleEdit()
            }
        }
    }

    private var codexStatusColor: Color {
        guard let phase = codexRun?.phase else { return board.theme.accentColor }
        switch phase {
        case .completed: return .green
        case .failed: return .orange
        default: return board.theme.accentColor
        }
    }

    private var codexHelpText: String {
        guard let codexRun else { return "Send directly to Codex on main" }
        if let error = codexRun.errorMessage {
            return error
        }
        if let threadID = codexRun.threadID {
            return "\(codexRun.phase.title) · Thread \(threadID)"
        }
        return codexRun.phase.title
    }

    private var codexButtonTitle: String {
        codexRun?.phase == .completed ? "VIEW THREAD" : (codexRun?.phase.title.uppercased() ?? "")
    }

    private func codexButtonAction() {
        if codexRun?.phase == .completed, let threadID = codexRun?.threadID {
            CodexDesktopBridge.openThread(threadID)
        } else {
            onSendToCodex(task.id)
        }
    }

    private func beginTitleEdit() {
        draftTitle = task.title
        isEditingTitle = true

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(40))
            isTitleFocused = true
        }
    }

    private func commitTitleEdit() {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmed.isEmpty && trimmed != task.title {
            onRename(trimmed)
        } else {
            draftTitle = task.title
        }

        isEditingTitle = false
        isTitleFocused = false
    }

    private func cancelTitleEdit() {
        draftTitle = task.title
        isEditingTitle = false
        isTitleFocused = false
    }
}

private struct CodexActivityPanel: View {
    let runs: [CodexRunRecord]
    let accentColor: Color
    let onClear: () -> Void

    private var hasFinishedRuns: Bool {
        runs.contains { !$0.phase.isActive }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("CODEX ACTIVITY")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.42))
                Spacer()
                Button("Clear finished", action: onClear)
                    .buttonStyle(.plain)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.35))
                    .disabled(!hasFinishedRuns)
                    .opacity(hasFinishedRuns ? 1 : 0.4)
            }

            ForEach(runs) { run in
                HStack(spacing: 9) {
                    Image(systemName: run.phase.systemImage)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(color(for: run.phase))
                        .frame(width: 16)
                        .symbolEffect(.pulse, isActive: run.phase.isActive)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(run.title)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(2)

                        HStack(spacing: 5) {
                            Text(run.phase.title)
                            if let progress = run.progressText {
                                Text("· \(progress)")
                            }
                            if let threadID = run.threadID {
                                Text("· …\(CodexDisplayText.threadID(threadID))")
                            } else if run.phase.isActive {
                                Text("· thread pending")
                            }
                        }
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(color(for: run.phase).opacity(0.8))
                    }

                    Spacer()

                    Text(run.updatedAt, style: .relative)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.3))
                }
                .help(run.errorMessage ?? run.threadID.map { "Codex thread \($0)" } ?? run.phase.title)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.06)))
    }

    private func color(for phase: CodexRunPhase) -> Color {
        switch phase {
        case .completed: .green
        case .failed: .orange
        default: accentColor
        }
    }
}

private struct BoardReorderDropDelegate: DropDelegate {
    let store: TaskBoardStore
    let targetBoardID: TaskBoard.ID
    @Binding var draggedBoardID: TaskBoard.ID?

    func dropEntered(info: DropInfo) {
        guard let draggedBoardID else {
            return
        }

        store.moveBoard(draggedID: draggedBoardID, to: targetBoardID)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedBoardID = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {}
}

private struct TaskReorderDropDelegate: DropDelegate {
    let store: TaskBoardStore
    let boardID: TaskBoard.ID
    let targetTaskID: TaskItem.ID
    @Binding var draggedTaskID: TaskItem.ID?

    func dropEntered(info: DropInfo) {
        guard let draggedTaskID else {
            return
        }

        store.moveOpenTask(draggedID: draggedTaskID, in: boardID, to: targetTaskID)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedTaskID = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {}
}

private struct DragPreview: View {
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
    }
}

private struct TaskBoardBackdrop: View {
    var body: some View {
        Color(hex: "080A0D")
            .ignoresSafeArea()
    }
}

private struct CreateBoardSheet: View {
    @Bindable var store: TaskBoardStore
    @Binding var isPresented: Bool

    @State private var boardTitle = ""
    @State private var folderPath = ""
    @FocusState private var isBoardNameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New Board")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)

            Text("Keep it short. You can add tasks from the top bar or directly inside the list.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.54))

            TextField("Board name", text: $boardTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
                .focused($isBoardNameFocused)
                .onSubmit(createBoard)

            HStack(spacing: 10) {
                Text(folderPath.isEmpty ? "Choose the repository for this board" : folderPath)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(folderPath.isEmpty ? 0.42 : 0.72))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button("Choose Folder", action: chooseFolder)
                    .buttonStyle(.bordered)
            }

            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.white.opacity(0.62))

                Spacer()

                Button("Create", action: createBoard)
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
            }
        }
        .padding(24)
        .frame(width: 440)
        .background(Color(hex: "11151B"))
        .task {
            try? await Task.sleep(for: .milliseconds(100))
            isBoardNameFocused = true
        }
    }

    private func createBoard() {
        store.addBoard(named: boardTitle, folderPath: folderPath)
        boardTitle = ""
        folderPath = ""
        isPresented = false
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            folderPath = url.path
        }
    }
}
