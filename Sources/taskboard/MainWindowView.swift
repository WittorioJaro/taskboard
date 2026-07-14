import AppKit
import SwiftUI
import UniformTypeIdentifiers

private extension UTType {
    static let taskboardTask = UTType(exportedAs: "com.taskboard.task")
}

struct MainWindowView: View {
    @Bindable var store: TaskBoardStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    @State private var showingCreateBoardSheet = false
    @State private var quickTaskTitle = ""
    @State private var quickTaskAttachments: [TaskAttachment] = []
    @State private var draggedBoardID: TaskBoard.ID?
    @State private var isWindowHovered = false
    @AppStorage("didApplyCompactMainWindowSizeV1") private var didApplyCompactWindowSize = false
    @AppStorage(WindowPreferences.openMainWindowInCurrentSpaceDefaultsKey)
    private var openMainWindowInCurrentSpace = WindowPreferences.openMainWindowInCurrentSpaceDefaultValue
    @FocusState private var isQuickEntryFocused: Bool

    var body: some View {
        ZStack {
            TaskBoardBackdrop()

            VStack(alignment: .leading, spacing: 0) {
                CompactWindowHeader(
                    boards: store.boards,
                    selectedBoardID: store.selectedBoardID,
                    draggedBoardID: $draggedBoardID,
                    onSelectBoard: store.selectBoard,
                    onCreateBoard: { showingCreateBoardSheet = true },
                    onOpenSettings: { openSettings() },
                    onMoveBoard: store.moveBoard,
                    showWindowControls: isWindowHovered,
                    onCloseWindow: { mainWindow()?.performClose(nil) },
                    onMinimizeWindow: { mainWindow()?.miniaturize(nil) },
                    onZoomWindow: { mainWindow()?.zoom(nil) }
                )

                QuickEntryBar(
                    taskTitle: $quickTaskTitle,
                    attachments: $quickTaskAttachments,
                    boardTitle: store.selectedBoard?.title ?? "board",
                    isQuickEntryFocused: $isQuickEntryFocused,
                    onSubmit: submitQuickTask
                )
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)

                if let selectedBoardID = store.selectedBoardID,
                   store.board(for: selectedBoardID) != nil {
                    ScrollView {
                        VStack(spacing: 0) {
                            BoardColumnView(
                                store: store,
                                boardID: selectedBoardID
                            )
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                        .id(selectedBoardID)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                    .scrollIndicators(.hidden)
                    .animation(.spring(response: 0.3, dampingFraction: 0.88), value: selectedBoardID)
                } else {
                    ContentUnavailableView(
                        "No board selected",
                        systemImage: "rectangle.stack",
                        description: Text("Create a board to start collecting tasks.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .foregroundStyle(Color.primary.opacity(0.52))
                }
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .background {
            WindowHoverSensor { isHovering in
                withAnimation(.easeOut(duration: 0.14)) {
                    isWindowHovered = isHovering
                }
            }
        }
        .sheet(isPresented: $showingCreateBoardSheet) {
            CreateBoardSheet(store: store, isPresented: $showingCreateBoardSheet)
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
        .onReceive(NotificationCenter.default.publisher(for: .cloudKitDataDidChange)) { _ in
            store.handleRemoteNotification()
        }
        .onChange(of: openMainWindowInCurrentSpace) { _, isEnabled in
            guard let mainWindow = mainWindow() else { return }
            MainWindowSpaceBehavior.apply(to: mainWindow, enabled: isEnabled)
        }
        .onAppear {
            Task { @MainActor in
                NSApp.activate(ignoringOtherApps: true)
                configureFloatingWindow()
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

    private func configureFloatingWindow() {
        guard let mainWindow = mainWindow() else { return }

        mainWindow.title = ""
        mainWindow.titleVisibility = .hidden
        mainWindow.titlebarAppearsTransparent = true
        mainWindow.titlebarSeparatorStyle = .none
        mainWindow.styleMask.insert(.fullSizeContentView)
        mainWindow.backgroundColor = NSColor(
            srgbRed: 12.0 / 255.0,
            green: 15.0 / 255.0,
            blue: 19.0 / 255.0,
            alpha: 1
        )
        mainWindow.isMovableByWindowBackground = false
        mainWindow.hasShadow = true
        mainWindow.standardWindowButton(.closeButton)?.isHidden = true
        mainWindow.standardWindowButton(.miniaturizeButton)?.isHidden = true
        mainWindow.standardWindowButton(.zoomButton)?.isHidden = true
        MainWindowSpaceBehavior.apply(to: mainWindow, enabled: openMainWindowInCurrentSpace)

        if !didApplyCompactWindowSize {
            mainWindow.setContentSize(NSSize(width: 390, height: 700))
            mainWindow.center()
            didApplyCompactWindowSize = true
        }
    }

    private func mainWindow() -> NSWindow? {
        MainWindowSpaceBehavior.mainWindow()
            ?? NSApp.keyWindow
            ?? NSApp.windows.first
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

        store.selectBoard(id: boardID)
        store.addTask(to: boardID, title: trimmed, attachments: quickTaskAttachments)
        quickTaskTitle = ""
        quickTaskAttachments = []
        requestQuickEntryFocus()
    }
}

private struct WindowHoverSensor: NSViewRepresentable {
    let onHoverChanged: (Bool) -> Void

    func makeNSView(context: Context) -> WindowHoverTrackingView {
        let view = WindowHoverTrackingView()
        view.onHoverChanged = onHoverChanged
        return view
    }

    func updateNSView(_ nsView: WindowHoverTrackingView, context: Context) {
        nsView.onHoverChanged = onHoverChanged
    }
}

private final class WindowHoverTrackingView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        onHoverChanged?(window.frame.contains(NSEvent.mouseLocation))
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let hoverTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(hoverTrackingArea)
        self.hoverTrackingArea = hoverTrackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }
}

private struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragHandleView {
        WindowDragHandleView()
    }

    func updateNSView(_ nsView: WindowDragHandleView, context: Context) {}
}

private final class WindowDragHandleView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

private struct CompactWindowHeader: View {
    let boards: [TaskBoard]
    let selectedBoardID: TaskBoard.ID?
    @Binding var draggedBoardID: TaskBoard.ID?
    let onSelectBoard: (TaskBoard.ID) -> Void
    let onCreateBoard: () -> Void
    let onOpenSettings: () -> Void
    let onMoveBoard: (TaskBoard.ID, TaskBoard.ID) -> Void
    let showWindowControls: Bool
    let onCloseWindow: () -> Void
    let onMinimizeWindow: () -> Void
    let onZoomWindow: () -> Void

    @State private var isTitleBarHovered = false

    private var windowControlsAreVisible: Bool {
        showWindowControls || isTitleBarHovered
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                WindowDragHandle()
                    .frame(width: 180, height: 30)

                Text("taskboard")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.primary.opacity(0.5))
                    .allowsHitTesting(false)

                HStack(spacing: 0) {
                    HStack(spacing: 8) {
                        WindowControlButton(
                            color: Color(red: 1, green: 0.37, blue: 0.34),
                            systemImage: "xmark",
                            help: "Close",
                            action: onCloseWindow
                        )
                        WindowControlButton(
                            color: Color(red: 1, green: 0.74, blue: 0.18),
                            systemImage: "minus",
                            help: "Minimize",
                            action: onMinimizeWindow
                        )
                        WindowControlButton(
                            color: Color(red: 0.16, green: 0.78, blue: 0.29),
                            systemImage: "plus",
                            help: "Zoom",
                            action: onZoomWindow
                        )
                    }
                    .opacity(windowControlsAreVisible ? 1 : 0)
                    .allowsHitTesting(windowControlsAreVisible)

                    Spacer()

                    Button(action: onOpenSettings) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.primary.opacity(0.44))
                            .frame(width: 28, height: 26)
                    }
                    .buttonStyle(.plain)
                    .help("Settings")
                }
                .padding(.horizontal, 12)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .contentShape(Rectangle())
            .onHover { isHovering in
                withAnimation(.easeOut(duration: 0.12)) {
                    isTitleBarHovered = isHovering
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(boards) { board in
                        BoardTab(
                            board: board,
                            isSelected: selectedBoardID == board.id,
                            onSelect: { onSelectBoard(board.id) }
                        )
                        .onDrag {
                            draggedBoardID = board.id
                            return NSItemProvider(object: board.id.uuidString as NSString)
                        } preview: {
                            DragPreview()
                        }
                        .onDrop(
                            of: [UTType.text],
                            delegate: CompactBoardDropDelegate(
                                targetBoardID: board.id,
                                draggedBoardID: $draggedBoardID,
                                onMoveBoard: onMoveBoard
                            )
                        )
                    }

                    Button(action: onCreateBoard) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.primary.opacity(0.48))
                            .frame(width: 28, height: 28)
                            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .help("New board")
                }
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 9)

            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 1)
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.96))
    }
}

private struct WindowControlButton: View {
    let color: Color
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 11, height: 11)
                .overlay {
                    Image(systemName: systemImage)
                        .font(.system(size: 5, weight: .black))
                        .foregroundStyle(Color.black.opacity(0.58))
                }
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct BoardTab: View {
    let board: TaskBoard
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 7) {
                Circle()
                    .fill(board.theme.accentColor)
                    .frame(width: 6, height: 6)
                    .shadow(color: board.theme.accentColor.opacity(isSelected ? 0.8 : 0), radius: 4)

                Text(board.title)
                    .lineLimit(1)

                if board.openTasks.count > 0 {
                    Text("\(board.openTasks.count)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(isSelected ? board.theme.accentColor : Color.primary.opacity(0.3))
                }
            }
            .font(.system(size: 11, weight: isSelected ? .semibold : .medium, design: .rounded))
            .foregroundStyle(isSelected ? Color.primary.opacity(0.94) : Color.primary.opacity(0.46))
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(
                isSelected ? Color.primary.opacity(0.075) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.primary.opacity(0.08) : Color.clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct CompactBoardDropDelegate: DropDelegate {
    let targetBoardID: TaskBoard.ID
    @Binding var draggedBoardID: TaskBoard.ID?
    let onMoveBoard: (TaskBoard.ID, TaskBoard.ID) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedBoardID, draggedBoardID != targetBoardID else { return }
        onMoveBoard(draggedBoardID, targetBoardID)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedBoardID = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

private struct QuickEntryBar: View {
    @Binding var taskTitle: String
    @Binding var attachments: [TaskAttachment]
    let boardTitle: String
    let isQuickEntryFocused: FocusState<Bool>.Binding
    let onSubmit: () -> Void

    private var isSubmitDisabled: Bool {
        taskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.primary.opacity(0.32))
                    .frame(width: 28, height: 28)

                taskComposer

                Button(action: pasteAttachment) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.42))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .help("Paste image from clipboard")

                submitButton
            }

            AttachmentDraftStrip(attachments: attachments) { attachment in
                attachments.removeAll { $0.id == attachment.id }
                TaskAttachmentStore.delete(attachment)
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.primary.opacity(0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                )
        )
    }

    private var taskComposer: some View {
        TextField("Add a task to \(boardTitle)", text: $taskTitle, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(.primary)
            .focused(isQuickEntryFocused)
            .lineLimit(1...3)
            .taskSubmitBehavior(onSubmit: onSubmit)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 30, alignment: .topLeading)
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

    private var submitButton: some View {
        Button(action: onSubmit) {
            Image(systemName: "arrow.up")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                .frame(width: 30, height: 30)
                .background(Color.primary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isSubmitDisabled)
        .opacity(isSubmitDisabled ? 0.45 : 1)
    }

}

private struct BoardColumnView: View {
    @Bindable var store: TaskBoardStore
    let boardID: TaskBoard.ID

    @State private var inlineTaskTitle = ""
    @State private var inlineTaskAttachments: [TaskAttachment] = []
    @State private var isAddingInlineTask = false
    @State private var draggedTaskID: TaskItem.ID?
    @State private var targetedStatus: TaskStatus?
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
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(board.title)
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.primary.opacity(0.94))
                            .lineLimit(1)

                        Text("\(board.openTasks.count) active · \(board.completedCount) archived")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.primary.opacity(0.34))
                    }

                    Spacer(minLength: 8)

                    Button(action: chooseBoardFolder) {
                        Image(systemName: board.folderPath.isEmpty ? "folder.badge.plus" : "folder.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(board.folderPath.isEmpty ? Color.orange.opacity(0.72) : Color.primary.opacity(0.48))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help(board.folderPath.isEmpty ? "Choose this board's folder" : board.folderPath)

                    Button {
                        store.selectBoard(id: board.id)
                        showingCodexSheet = true
                    } label: {
                        Image(systemName: "paperplane")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(board.theme.accentColor)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help("Send selected tasks to Codex")
                    .disabled(board.openTasks.isEmpty)
                    .opacity(board.openTasks.isEmpty ? 0.45 : 1)

                    Menu {
                        Button(board.isPinned ? "Unpin board" : "Pin board") {
                            store.toggleBoardPin(id: board.id)
                        }

                        Button("Delete board", role: .destructive) {
                            showingDeleteConfirmation = true
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.primary.opacity(0.4))
                            .frame(width: 28, height: 28)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .padding(.top, 13)
                .padding(.bottom, 13)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.055))
                        .frame(height: 1)
                }

                let doneTasks = tasks(in: .done, for: board)
                let runningTasks = tasks(in: .running, for: board)
                let todoTasks = tasks(in: .todo, for: board)

                TaskLaneDropZone(
                    tint: .green,
                    isTargeted: laneTargetBinding(for: .done),
                    onEnter: { moveDraggedTask(to: .done) },
                    onDrop: { performStatusDrop(to: .done) }
                ) {
                    TaskSectionHeader(
                        title: "DONE",
                        count: doneTasks.count,
                        systemImage: "checkmark",
                        tint: .green
                    )
                    TaskSectionSurface(
                        isEmpty: doneTasks.isEmpty,
                        emptyText: emptyText(for: .done)
                    ) {
                        ForEach(doneTasks) { task in
                            MinimalTaskRow(
                                board: board,
                                task: task,
                                isCopied: store.copiedTaskID == task.id,
                                onCopy: { store.copyTask(task) },
                                codexRun: runMonitor.latestRun(for: task.id),
                                onSendToCodex: { taskID in
                                    sendDirectlyToCodex(taskID: taskID, boardID: board.id)
                                },
                                onDone: {
                                    store.markTaskDone(taskID: task.id, in: board.id)
                                },
                                onRename: { newTitle in
                                    store.renameTask(taskID: task.id, in: board.id, title: newTitle)
                                },
                                isDragged: draggedTaskID == task.id,
                                onDragStart: { draggedTaskID = task.id }
                            )
                        }
                    }
                }

                TaskLaneDropZone(
                    tint: board.theme.accentColor,
                    isTargeted: laneTargetBinding(for: .running),
                    onEnter: { moveDraggedTask(to: .running) },
                    onDrop: { performStatusDrop(to: .running) }
                ) {
                    TaskSectionHeader(
                        title: "RUNNING",
                        count: runningTasks.count,
                        systemImage: "waveform.path",
                        tint: board.theme.accentColor
                    )
                    TaskSectionSurface(
                        isEmpty: runningTasks.isEmpty,
                        emptyText: emptyText(for: .running)
                    ) {
                        ForEach(runningTasks) { task in
                            MinimalTaskRow(
                                board: board,
                                task: task,
                                isCopied: store.copiedTaskID == task.id,
                                onCopy: { store.copyTask(task) },
                                codexRun: runMonitor.latestRun(for: task.id),
                                onSendToCodex: { taskID in
                                    sendDirectlyToCodex(taskID: taskID, boardID: board.id)
                                },
                                onDone: {
                                    store.markTaskDone(taskID: task.id, in: board.id)
                                },
                                onRename: { newTitle in
                                    store.renameTask(taskID: task.id, in: board.id, title: newTitle)
                                },
                                isDragged: draggedTaskID == task.id,
                                onDragStart: { draggedTaskID = task.id }
                            )
                        }
                    }
                }

                TaskLaneDropZone(
                    tint: Color.primary.opacity(0.48),
                    isTargeted: laneTargetBinding(for: .todo),
                    onEnter: { moveDraggedTask(to: .todo) },
                    onDrop: { performStatusDrop(to: .todo) }
                ) {
                    TaskSectionHeader(
                        title: "TODO",
                        count: todoTasks.count,
                        systemImage: "circle",
                        tint: Color.primary.opacity(0.48)
                    )
                    TaskSectionSurface(
                        isEmpty: todoTasks.isEmpty,
                        emptyText: emptyText(for: .todo)
                    ) {
                        ForEach(todoTasks) { task in
                            MinimalTaskRow(
                                board: board,
                                task: task,
                                isCopied: store.copiedTaskID == task.id,
                                onCopy: { store.copyTask(task) },
                                codexRun: runMonitor.latestRun(for: task.id),
                                onSendToCodex: { taskID in
                                    sendDirectlyToCodex(taskID: taskID, boardID: board.id)
                                },
                                onDone: {
                                    store.markTaskDone(taskID: task.id, in: board.id)
                                },
                                onRename: { newTitle in
                                    store.renameTask(taskID: task.id, in: board.id, title: newTitle)
                                },
                                isDragged: draggedTaskID == task.id,
                                onDragStart: { draggedTaskID = task.id }
                            )
                            .onDrop(
                                of: [UTType.taskboardTask],
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
                .padding(.top, 8)
                .padding(.bottom, 10)
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.9), value: board.tasks)
            .onChange(of: draggedTaskID) { _, newValue in
                guard let newValue else { return }
                let originLane = currentLane(of: newValue)
                Task { @MainActor in
                    while draggedTaskID == newValue, NSEvent.pressedMouseButtons & 0x1 != 0 {
                        try? await Task.sleep(for: .milliseconds(120))
                    }
                    try? await Task.sleep(for: .milliseconds(200))
                    if draggedTaskID == newValue {
                        if let originLane {
                            store.moveTask(taskID: newValue, in: boardID, to: originLane)
                        }
                        draggedTaskID = nil
                        targetedStatus = nil
                    }
                }
            }
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

    private func tasks(in lane: TaskStatus, for board: TaskBoard) -> [TaskItem] {
        board.openTasks.filter { task in
            if let statusOverride = task.statusOverride {
                return statusOverride == lane
            }

            let phase = runMonitor.latestRun(for: task.id)?.phase
            switch lane {
            case .done:
                return phase == .completed
            case .running:
                return phase?.isActive == true
            case .todo:
                guard let phase else { return true }
                return !phase.isActive && phase != .completed
            }
        }
    }

    private func laneTargetBinding(for status: TaskStatus) -> Binding<Bool> {
        Binding(
            get: { targetedStatus == status },
            set: { isTargeted in
                if isTargeted {
                    targetedStatus = status
                } else if targetedStatus == status {
                    targetedStatus = nil
                }
            }
        )
    }

    private func moveDraggedTask(to status: TaskStatus) {
        guard let draggedTaskID else { return }
        store.moveTask(taskID: draggedTaskID, in: boardID, to: status)
    }

    private func performStatusDrop(to status: TaskStatus) -> Bool {
        guard let draggedTaskID else { return false }
        store.moveTask(taskID: draggedTaskID, in: boardID, to: status)
        self.draggedTaskID = nil
        targetedStatus = nil
        return true
    }

    private func currentLane(of taskID: TaskItem.ID) -> TaskStatus? {
        guard let board else { return nil }
        for lane in [TaskStatus.done, .running, .todo]
        where tasks(in: lane, for: board).contains(where: { $0.id == taskID }) {
            return lane
        }
        return nil
    }

    private func emptyText(for lane: TaskStatus) -> String {
        switch lane {
        case .todo: "Nothing waiting. You’re clear."
        case .running: "No tasks are running right now."
        case .done: "Drop finished tasks here."
        }
    }

    private func beginInlineEntry() {
        store.selectBoard(id: boardID)
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

        store.selectBoard(id: boardID)
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
        store.clearTaskStatusOverride(taskIDs: [taskID], in: boardID)
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
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 16, height: 16)

            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(1.1)
                .foregroundStyle(Color.primary.opacity(0.48))

            Spacer()

            Text("\(count)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(count == 0 ? Color.primary.opacity(0.24) : tint)
        }
        .padding(.bottom, 7)
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
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.primary.opacity(0.25))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 26)
                    .padding(.vertical, 9)
            } else {
                VStack(spacing: 0) {
                    content
                }
            }
        }
    }
}

private struct TaskLaneDropZone<Content: View>: View {
    let tint: Color
    @Binding var isTargeted: Bool
    let onEnter: () -> Void
    let onDrop: () -> Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(isTargeted ? 0.065 : 0))
                .padding(.horizontal, -8)
        }
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(tint)
                .frame(width: 3)
                .padding(.vertical, 3)
                .offset(x: -11)
                .opacity(isTargeted ? 1 : 0)
        }
        .padding(.top, 16)
        .animation(.easeOut(duration: 0.14), value: isTargeted)
        .onDrop(
            of: [UTType.taskboardTask],
            delegate: TaskLaneDropDelegate(
                isTargeted: $isTargeted,
                onEnter: onEnter,
                onFinish: onDrop
            )
        )
    }
}

private struct TaskLaneDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let onEnter: () -> Void
    let onFinish: () -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.taskboardTask])
    }

    func dropEntered(info: DropInfo) {
        isTargeted = true
        onEnter()
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        return onFinish()
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
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Color.primary.opacity(0.28))
                        .frame(width: 14)
                        .padding(.top, 10)

                    VStack(alignment: .leading, spacing: 8) {
                        TextField("New task", text: $taskTitle, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.primary.opacity(0.92))
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
                            .foregroundStyle(Color.primary.opacity(0.56))
                            .frame(width: 28, height: 28)
                            .background(Color.primary.opacity(0.05), in: Circle())
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
                            .foregroundStyle(Color.primary.opacity(0.42))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                }
                .padding(.vertical, 10)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.055))
                        .frame(height: 1)
                }
            } else {
                Button(action: onBegin) {
                    HStack(spacing: 12) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.primary.opacity(0.36))
                            .frame(width: 14)

                        Text("Click to add a task")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.primary.opacity(0.42))

                        Spacer()
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.045))
                        .frame(height: 1)
                }
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
    let isDragged: Bool
    let onDragStart: () -> Void

    @State private var draftTitle = ""
    @State private var isEditingTitle = false
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: onDone) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Color.primary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .help("Mark done")

            VStack(alignment: .leading, spacing: 8) {
                Group {
                    if isEditingTitle {
                    TextField("Task title", text: $draftTitle, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.96))
                        .focused($isTitleFocused)
                        .lineLimit(2...10)
                        .onExitCommand(perform: cancelTitleEdit)
                    } else {
                    Text(task.title)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.92))
                        .lineLimit(nil)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2, perform: beginTitleEdit)
                        .help("Double-click to edit · Drag to change status or copy text")
                        .accessibilityAddTraits(.isButton)
                    }
                }

                AttachmentDraftStrip(attachments: task.attachments)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 10)

            Button(action: onCopy) {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(isCopied ? Color.black : board.theme.accentColor)
                    .frame(width: 26, height: 26)
                    .background(
                        isCopied ? board.theme.accentColor : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
            }
            .buttonStyle(.plain)
            .help(isCopied ? "Copied" : "Copy task")

            Menu {
                Button(action: codexButtonAction) {
                    Label(codexMenuTitle, systemImage: codexMenuImage)
                }
                .disabled(codexRun?.phase.isActive == true)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(codexRun == nil ? Color.primary.opacity(0.34) : codexStatusColor)
                    .frame(width: 26, height: 26)
                    .overlay(alignment: .topTrailing) {
                        if codexRun != nil {
                            Circle()
                                .fill(codexStatusColor)
                                .frame(width: 4, height: 4)
                                .symbolEffect(.pulse, isActive: codexRun?.phase.isActive == true)
                        }
                    }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(codexHelpText)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.045))
                .frame(height: 1)
                .padding(.leading, 26)
        }
        .opacity(isDragged ? 0.3 : 1)
        .animation(.easeOut(duration: 0.15), value: isDragged)
        .onDrag {
            onDragStart()
            ExternalDragPreviewController.shared.begin(
                title: task.title,
                accent: board.theme.accentColor
            )
            return taskDragProvider()
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

    private func taskDragProvider() -> NSItemProvider {
        let provider = NSItemProvider(object: task.title as NSString)
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.taskboardTask.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(task.id.uuidString.data(using: .utf8), nil)
            return nil
        }
        return provider
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

    private var codexMenuTitle: String {
        guard let phase = codexRun?.phase else { return "Send to Codex" }
        return switch phase {
        case .completed: "Open Codex Thread"
        case .failed: "Retry in Codex"
        default: phase.title
        }
    }

    private var codexMenuImage: String {
        guard let phase = codexRun?.phase else { return "paperplane" }
        return switch phase {
        case .completed: "arrow.up.right.square"
        case .failed: "arrow.clockwise"
        default: phase.systemImage
        }
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
                    .foregroundStyle(Color.primary.opacity(0.42))
                Spacer()
                Button("Clear finished", action: onClear)
                    .buttonStyle(.plain)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.primary.opacity(0.35))
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
                            .foregroundStyle(.primary.opacity(0.82))
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
                        .foregroundStyle(Color.primary.opacity(0.3))
                }
                .help(run.errorMessage ?? run.threadID.map { "Codex thread \($0)" } ?? run.phase.title)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.06)))
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

        store.moveTask(taskID: draggedTaskID, in: boardID, to: .todo)
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
        // A fully transparent preview makes macOS fall back to snapshotting
        // the dragged view; keep a single near-invisible pixel instead.
        Rectangle()
            .fill(Color.black.opacity(0.02))
            .frame(width: 2, height: 2)
    }
}

@MainActor
private final class ExternalDragPreviewController {
    static let shared = ExternalDragPreviewController()

    private var panel: NSPanel?
    private var monitorTask: Task<Void, Never>?
    private var sourceWindowFrame: NSRect = .zero

    func begin(title: String, accent: Color) {
        stop()

        sourceWindowFrame = NSApp.keyWindow?.frame ?? .zero
        let preview = ExternalTaskDragPreview(title: title, accent: accent)
        let hostingView = NSHostingView(rootView: preview)
        hostingView.frame = NSRect(x: 0, y: 0, width: 280, height: 72)

        let panel = NSPanel(
            contentRect: hostingView.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = hostingView
        self.panel = panel

        monitorTask = Task { [weak self] in
            while !Task.isCancelled, NSEvent.pressedMouseButtons & 0x1 != 0 {
                self?.updatePanelPosition()
                try? await Task.sleep(for: .milliseconds(16))
            }
            self?.stop()
        }
    }

    private func updatePanelPosition() {
        guard let panel else { return }
        let pointer = NSEvent.mouseLocation

        guard !sourceWindowFrame.contains(pointer) else {
            panel.orderOut(nil)
            return
        }

        panel.setFrameOrigin(NSPoint(x: pointer.x + 16, y: pointer.y - 36))
        panel.orderFrontRegardless()
    }

    private func stop() {
        monitorTask?.cancel()
        monitorTask = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct ExternalTaskDragPreview: View {
    let title: String
    let accent: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accent)

            Text(title)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color(hex: "FFFFFF").opacity(0.94))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .frame(width: 280, height: 72)
        .background(Color(hex: "171A1F"), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(accent.opacity(0.55), lineWidth: 1)
        }
    }
}

private struct TaskBoardBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        (colorScheme == .light ? Color(hex: "FCFCFD") : Color(hex: "080A0D"))
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
                .foregroundStyle(.primary)

            Text("Keep it short. You can add tasks from the top bar or directly inside the list.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color.primary.opacity(0.54))

            TextField("Board name", text: $boardTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .focused($isBoardNameFocused)
                .onSubmit(createBoard)

            HStack(spacing: 10) {
                Text(folderPath.isEmpty ? "Choose the repository for this board" : folderPath)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.primary.opacity(folderPath.isEmpty ? 0.42 : 0.72))
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
                .foregroundStyle(Color.primary.opacity(0.62))

                Spacer()

                Button("Create", action: createBoard)
                    .buttonStyle(.borderedProminent)
                    .tint(.primary)
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
            }
        }
        .padding(24)
        .frame(width: 440)
        .background(Color(nsColor: .windowBackgroundColor))
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
