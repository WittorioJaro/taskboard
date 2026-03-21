import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MainWindowView: View {
    @Bindable var store: TaskBoardStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    @State private var showingCreateBoardSheet = false
    @State private var quickTaskTitle = ""
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

    var body: some View {
        ZStack {
            TaskBoardBackdrop()

            VStack(alignment: .leading, spacing: 18) {
                QuickEntryBar(
                    taskTitle: $quickTaskTitle,
                    selectedBoardID: $store.selectedBoardID,
                    boards: store.boards,
                    isQuickEntryFocused: $isQuickEntryFocused,
                    onSubmit: submitQuickTask,
                    onCreateBoard: {
                        showingCreateBoardSheet = true
                    }
                )

                ScrollView {
                    LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 18) {
                        ForEach(store.boards) { board in
                            BoardColumnView(
                                store: store,
                                boardID: board.id,
                                draggedBoardID: $draggedBoardID
                            )
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
        store.addTask(to: boardID, title: trimmed)
        quickTaskTitle = ""
        requestQuickEntryFocus()
    }
}

private struct QuickEntryBar: View {
    @Binding var taskTitle: String
    @Binding var selectedBoardID: TaskBoard.ID?
    let boards: [TaskBoard]
    let isQuickEntryFocused: FocusState<Bool>.Binding
    let onSubmit: () -> Void
    let onCreateBoard: () -> Void
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("taskboard")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)

                Text("Quick add to any board, then handle the rest inline.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.5))
            }

            Spacer(minLength: 12)

            HStack(spacing: 10) {
                TextField("Add a task", text: $taskTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .focused(isQuickEntryFocused)
                    .onSubmit(onSubmit)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
                    .frame(width: 320, height: 44)

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

                Button(action: onSubmit) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 44, height: 44)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(taskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(taskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)

                Button(action: onCreateBoard) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("New Board")

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
            .frame(maxWidth: 760)
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
}

private struct BoardColumnView: View {
    @Bindable var store: TaskBoardStore
    let boardID: TaskBoard.ID
    @Binding var draggedBoardID: TaskBoard.ID?

    @State private var inlineTaskTitle = ""
    @State private var isAddingInlineTask = false
    @State private var draggedTaskID: TaskItem.ID?
    @State private var showingDeleteConfirmation = false
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

                        if board.openTasks.isEmpty {
                            Text("No tasks yet")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.white.opacity(0.36))
                                .padding(.horizontal, 18)
                                .padding(.top, 16)
                        }

                        VStack(spacing: 0) {
                            ForEach(board.openTasks) { task in
                                MinimalTaskRow(
                                    board: board,
                                    task: task,
                                    isCopied: store.copiedTaskID == task.id,
                                    onCopy: {
                                        store.selectedBoardID = board.id
                                        store.copyTask(task)
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

                                if task.id != board.openTasks.last?.id {
                                    Rectangle()
                                        .fill(Color.white.opacity(0.05))
                                        .frame(height: 1)
                                        .padding(.horizontal, 18)
                                }
                            }
                        }
                        .padding(.top, board.openTasks.isEmpty ? 8 : 4)
                        .padding(.bottom, 4)

                        InlineTaskEntryRow(
                            board: board,
                            taskTitle: $inlineTaskTitle,
                            isAdding: $isAddingInlineTask,
                            isFocused: $isInlineTaskFocused,
                            onBegin: beginInlineEntry,
                            onSubmit: submitInlineTask,
                            onCancel: cancelInlineEntry
                        )
                        .padding(.horizontal, 18)
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
            .animation(.spring(response: 0.3, dampingFraction: 0.9), value: board.openTasks)
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
        inlineTaskTitle = ""
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
        store.addTask(to: boardID, title: trimmed)
        inlineTaskTitle = ""

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            isInlineTaskFocused = true
        }
    }
}

private struct InlineTaskEntryRow: View {
    let board: TaskBoard
    @Binding var taskTitle: String
    @Binding var isAdding: Bool
    let isFocused: FocusState<Bool>.Binding
    let onBegin: () -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        Group {
            if isAdding {
                HStack(spacing: 12) {
                    Image(systemName: "circle")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.28))

                    TextField("New task", text: $taskTitle)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                        .focused(isFocused)
                        .onSubmit(onSubmit)

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

                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.42))
                    }
                    .buttonStyle(.plain)
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
}

private struct MinimalTaskRow: View {
    let board: TaskBoard
    let task: TaskItem
    let isCopied: Bool
    let onCopy: () -> Void
    let onDone: () -> Void
    let onRename: (String) -> Void
    let onDragStart: () -> Void

    @State private var draftTitle = ""
    @State private var isEditingTitle = false
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onDone) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.48))
            }
            .buttonStyle(.plain)
            .help("Mark done")

            Group {
                if isEditingTitle {
                    TextField("Task title", text: $draftTitle)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.96))
                        .focused($isTitleFocused)
                        .onSubmit(commitTitleEdit)
                        .onExitCommand(perform: cancelTitleEdit)
                } else {
                    Button(action: beginTitleEdit) {
                        Text(task.title)
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.92))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 10)

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
        .frame(width: 360)
        .background(Color(hex: "11151B"))
        .task {
            try? await Task.sleep(for: .milliseconds(100))
            isBoardNameFocused = true
        }
    }

    private func createBoard() {
        store.addBoard(named: boardTitle)
        boardTitle = ""
        isPresented = false
    }
}
