import SwiftUI

struct MenuBarCompanionView: View {
    @Bindable var store: TaskBoardStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack {
            Color(hex: "0A0D11")

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("taskboard")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)

                        Text("\(store.pendingTaskCount) open · \(store.boards.count) boards")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.44))
                    }

                    Spacer()

                Button("Open App") {
                    openWindow(id: SceneID.mainWindow)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.white)

                Button("Quick Capture") {
                    QuickCaptureController.shared.handleHotKey()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(store.boards) { board in
                            MenuBarBoardSection(store: store, board: board)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(width: 360, height: 420)
            }
            .padding(18)
        }
        .frame(width: 396)
        .preferredColorScheme(.dark)
    }
}

private struct MenuBarBoardSection: View {
    @Bindable var store: TaskBoardStore
    let board: TaskBoard

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MenuBarBoardHeader(board: board)
            MenuBarTaskList(store: store, board: board)
        }
        .padding(14)
        .background(Color(hex: "10141A"), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct MenuBarBoardHeader: View {
    let board: TaskBoard

    var body: some View {
        HStack {
            Text(board.title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)

            Spacer()

            Text("\(board.openTasks.count)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(board.theme.accentColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(board.theme.accentColor.opacity(0.12), in: Capsule())
        }
    }
}

private struct MenuBarTaskRow: View {
    @Bindable var store: TaskBoardStore
    let board: TaskBoard
    let task: TaskItem
    let isLast: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(task.title)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    store.copyTask(task)
                } label: {
                    Text(store.copiedTaskID == task.id ? "DONE" : "COPY")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(board.theme.accentColor)

                Button {
                    store.markTaskDone(taskID: task.id, in: board.id)
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.white.opacity(0.48))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(Color.white.opacity(0.025))
            .transition(.opacity.combined(with: .move(edge: .top)))

            if !isLast {
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 1)
            }
        }
    }
}

private struct MenuBarTaskList: View {
    @Bindable var store: TaskBoardStore
    let board: TaskBoard

    var body: some View {
        Group {
            if board.openTasks.isEmpty {
                Text("No open tasks")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.46))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 14)
            } else {
                VStack(spacing: 0) {
                    ForEach(board.openTasks) { task in
                        MenuBarTaskRow(
                            store: store,
                            board: board,
                            task: task,
                            isLast: task.id == board.openTasks.last?.id
                        )
                    }
                }
            }
        }
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
