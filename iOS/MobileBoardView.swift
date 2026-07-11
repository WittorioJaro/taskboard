import SwiftUI

struct MobileBoardView: View {
    @Bindable var store: TaskBoardStore

    @State private var taskTitle = ""
    @State private var showingNewBoard = false
    @State private var editingTask: TaskItem?
    @State private var editedTitle = ""
    @State private var targetedLane: MobileLane?
    @FocusState private var entryFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                MobileBackdrop()

                ScrollView {
                    LazyVStack(spacing: 18) {
                        appHeader
                        boardSlider
                        quickEntry
                        lanesBoard
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 40)
                }
                .refreshable { await store.refreshFromCloud() }
                .scrollDismissesKeyboard(.interactively)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(isPresented: $showingNewBoard) {
            NewBoardSheet(store: store)
                .presentationDetents([.height(260)])
                .presentationDragIndicator(.visible)
        }
        .alert("Rename task", isPresented: renameAlertBinding) {
            TextField("Task title", text: $editedTitle)
            Button("Cancel", role: .cancel) { editingTask = nil }
            Button("Save") { saveRename() }
        }
    }

    private var appHeader: some View {
        HStack(spacing: 10) {
            Text("taskboard")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))

            Spacer()

            HStack(spacing: 5) {
                Image(systemName: store.syncStatus.systemImage)
                Text(store.syncStatus.label)
            }
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.34))
        }
        .padding(.horizontal, 2)
    }

    private var boardSlider: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(store.boards) { board in
                        MobileBoardTab(
                            board: board,
                            isSelected: store.selectedBoardID == board.id,
                            onSelect: {
                                withAnimation(.snappy(duration: 0.25)) {
                                    store.selectedBoardID = board.id
                                }
                            }
                        )
                        .id(board.id)
                    }

                    Button { showingNewBoard = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white.opacity(0.48))
                            .frame(width: 36, height: 36)
                            .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .accessibilityLabel("New board")
                }
            }
            .scrollIndicators(.hidden)
            .onChange(of: store.selectedBoardID) { _, selectedID in
                guard let selectedID else { return }
                withAnimation(.snappy) { proxy.scrollTo(selectedID, anchor: .center) }
            }
        }
    }

    private var quickEntry: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(store.selectedBoard?.theme.accentColor ?? .blue)

            TextField("What needs doing?", text: $taskTitle)
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .focused($entryFocused)
                .submitLabel(.done)
                .onSubmit(addTask)

            Button(action: addTask) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(.black)
                    .frame(width: 32, height: 32)
                    .background(store.selectedBoard?.theme.accentColor ?? .white, in: Circle())
            }
            .disabled(taskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(taskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.3 : 1)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.09)))
    }

    @ViewBuilder
    private var lanesBoard: some View {
        if let board = store.selectedBoard {
            LazyVStack(spacing: 12) {
                ForEach(MobileLane.displayOrder) { lane in
                    MobileTaskLane(
                        lane: lane,
                        tasks: tasks(for: lane),
                        boardAccent: board.theme.accentColor,
                        isTargeted: targetedLane == lane,
                        onTargeted: { isTargeted in
                            withAnimation(.easeOut(duration: 0.16)) {
                                if isTargeted {
                                    targetedLane = lane
                                } else if targetedLane == lane {
                                    targetedLane = nil
                                }
                            }
                        },
                        onDropTask: { taskID in move(taskID, to: lane.status) },
                        onComplete: complete,
                        onMove: move,
                        onRename: { task in
                            editedTitle = task.title
                            editingTask = task
                        },
                        onCopy: store.copyTask
                    )
                }
            }
            .animation(.snappy(duration: 0.28), value: board.tasks)
        }
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(get: { editingTask != nil }, set: { if !$0 { editingTask = nil } })
    }

    private func tasks(for lane: MobileLane) -> [TaskItem] {
        guard let board = store.selectedBoard else { return [] }
        switch lane {
        case .todo:
            return board.tasks.filter { !$0.isCompleted && ($0.statusOverride == nil || $0.statusOverride == .todo) }
        case .running:
            return board.tasks.filter { !$0.isCompleted && $0.statusOverride == .running }
        case .done:
            return board.tasks.filter { !$0.isCompleted && $0.statusOverride == .done }
        }
    }

    private func addTask() {
        guard let boardID = store.selectedBoardID else { return }
        if store.addTask(to: boardID, title: taskTitle) != nil {
            taskTitle = ""
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    private func complete(_ task: TaskItem) {
        guard let boardID = store.selectedBoardID else { return }
        store.markTaskDone(taskID: task.id, in: boardID)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func move(_ task: TaskItem, to status: TaskStatus) {
        move(task.id, to: status)
    }

    private func move(_ taskID: TaskItem.ID, to status: TaskStatus) {
        guard let boardID = store.selectedBoardID else { return }
        store.moveTask(taskID: taskID, in: boardID, to: status)
        targetedLane = nil
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func saveRename() {
        guard let task = editingTask, let boardID = store.selectedBoardID else { return }
        store.renameTask(taskID: task.id, in: boardID, title: editedTitle)
        editingTask = nil
    }
}

private struct MobileBoardTab: View {
    let board: TaskBoard
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 7) {
                Circle()
                    .fill(board.theme.accentColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: board.theme.accentColor.opacity(isSelected ? 0.8 : 0), radius: 4)

                Text(board.title)
                    .lineLimit(1)

                if !board.openTasks.isEmpty {
                    Text("\(board.openTasks.count)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(isSelected ? board.theme.accentColor : .white.opacity(0.3))
                }
            }
            .font(.system(size: 12, weight: isSelected ? .semibold : .medium, design: .rounded))
            .foregroundStyle(isSelected ? .white.opacity(0.94) : .white.opacity(0.46))
            .padding(.horizontal, 13)
            .frame(height: 36)
            .background(
                isSelected ? .white.opacity(0.075) : .clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? .white.opacity(0.08) : .clear)
            }
        }
        .buttonStyle(.plain)
    }
}

private enum MobileLane: String, CaseIterable, Identifiable {
    case todo, running, done
    static let displayOrder: [MobileLane] = [.done, .running, .todo]
    var id: Self { self }
    var title: String { rawValue.capitalized }
    var status: TaskStatus {
        switch self { case .todo: .todo; case .running: .running; case .done: .done }
    }
    var color: Color {
        switch self { case .todo: .gray; case .running: .orange; case .done: .green }
    }
    var icon: String {
        switch self { case .todo: "circle"; case .running: "waveform.path"; case .done: "checkmark" }
    }
    var emptyIcon: String {
        switch self { case .todo: "tray"; case .running: "bolt"; case .done: "checkmark.circle" }
    }
    var emptyMessage: String {
        switch self { case .todo: "Nothing waiting"; case .running: "Nothing in motion"; case .done: "Finished tasks land here" }
    }
}

private struct MobileTaskLane: View {
    let lane: MobileLane
    let tasks: [TaskItem]
    let boardAccent: Color
    let isTargeted: Bool
    let onTargeted: (Bool) -> Void
    let onDropTask: (TaskItem.ID) -> Void
    let onComplete: (TaskItem) -> Void
    let onMove: (TaskItem, TaskStatus) -> Void
    let onRename: (TaskItem) -> Void
    let onCopy: (TaskItem) -> Void

    private var tint: Color {
        lane == .running ? boardAccent : lane.color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: lane.icon)
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(tint)
                Text(lane.title.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.62))
                Text("\(tasks.count)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
                Spacer()
                if isTargeted {
                    Text("DROP")
                        .font(.system(size: 8, weight: .black, design: .rounded))
                        .foregroundStyle(tint)
                }
            }
            .padding(.horizontal, 3)

            VStack(spacing: 8) {
                if tasks.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: lane.emptyIcon)
                        Text(lane.emptyMessage)
                    }
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(isTargeted ? 0.58 : 0.25))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 48)
                } else {
                    ForEach(tasks) { task in
                        MobileTaskRow(
                            task: task,
                            accent: tint,
                            onComplete: { onComplete(task) },
                            onMove: { onMove(task, $0) },
                            onRename: { onRename(task) },
                            onCopy: { onCopy(task) }
                        )
                        .draggable(task.id.uuidString) {
                            MobileTaskDragPreview(task: task, tint: tint)
                        }
                        .transition(.blurReplace.combined(with: .move(edge: .top)))
                    }
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(tint.opacity(0.08))
                        .padding(-6)
                        .allowsHitTesting(false)
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(tint.opacity(0.65), lineWidth: 1.5)
                        .padding(-6)
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: String.self) { values, _ in
                guard let value = values.first, let taskID = UUID(uuidString: value) else { return false }
                onDropTask(taskID)
                return true
            } isTargeted: { onTargeted($0) }
        }
    }
}

private struct MobileTaskDragPreview: View {
    let task: TaskItem
    let tint: Color

    var body: some View {
        HStack(spacing: 9) {
            Circle().fill(tint).frame(width: 8, height: 8)
            Text(task.title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .lineLimit(2)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: 260, alignment: .leading)
        .background(Color(hex: "171B22"), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(tint.opacity(0.5)))
    }
}

private struct MobileTaskRow: View {
    let task: TaskItem
    let accent: Color
    let onComplete: () -> Void
    let onMove: (TaskStatus) -> Void
    let onRename: () -> Void
    let onCopy: () -> Void

    var body: some View {
        HStack(spacing: 13) {
            Button(action: onComplete) {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(task.isCompleted ? .green : accent.opacity(0.75))
            }
            .disabled(task.isCompleted)

            Text(task.title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(task.isCompleted ? 0.42 : 0.9))
                .strikethrough(task.isCompleted, color: .white.opacity(0.25))
                .frame(maxWidth: .infinity, alignment: .leading)

            if task.statusOverride == .running {
                Image(systemName: "bolt.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 16)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(.white.opacity(0.07)))
        .contextMenu {
            if !task.isCompleted {
                Button("Move to Todo", systemImage: "circle") { onMove(.todo) }
                Button("Move to Running", systemImage: "bolt") { onMove(.running) }
                Button("Mark Done", systemImage: "checkmark") { onMove(.done) }
                Divider()
                Button("Rename", systemImage: "pencil", action: onRename)
            }
            Button("Copy", systemImage: "doc.on.doc", action: onCopy)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if !task.isCompleted {
                Button(action: onComplete) { Label("Done", systemImage: "checkmark") }
                    .tint(.green)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if !task.isCompleted {
                Button { onMove(task.statusOverride == .running ? .todo : .running) } label: {
                    Label(task.statusOverride == .running ? "Todo" : "Running", systemImage: "bolt")
                }
                .tint(.orange)
            }
        }
    }
}

private struct NewBoardSheet: View {
    @Bindable var store: TaskBoardStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("New board")
                .font(.system(size: 24, weight: .heavy, design: .rounded))
            TextField("Board name", text: $title)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .padding(15)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 15))
                .submitLabel(.done)
                .onSubmit(create)
            Button(action: create) {
                Text("Create board")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(.white, in: RoundedRectangle(cornerRadius: 15))
            }
        }
        .padding(24)
        .background(Color(hex: "0C0F13"))
    }

    private func create() {
        store.addBoard(named: title)
        dismiss()
    }
}

private struct MobileBackdrop: View {
    var body: some View {
        ZStack {
            Color(hex: "080A0E")
            RadialGradient(
                colors: [Color(hex: "1D4ED8").opacity(0.17), .clear],
                center: UnitPoint(x: 0.12, y: 0.04),
                startRadius: 10,
                endRadius: 430
            )
            Rectangle()
                .fill(.ultraThinMaterial.opacity(0.08))
                .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom))
        }
        .ignoresSafeArea()
    }
}
