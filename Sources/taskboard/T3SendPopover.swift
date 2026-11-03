import SwiftUI

/// Favourites and projects fetched from T3 Code, shared by every popover so
/// reopening one shows the last list immediately while it refreshes.
@MainActor
@Observable
final class T3Catalog {
    static let shared = T3Catalog()

    private(set) var models: [T3ModelOption] = []
    private(set) var projects: [T3Project] = []
    private(set) var modelsError: String?
    private(set) var projectsError: String?
    private(set) var isLoadingModels = false
    private(set) var isLoadingProjects = false
    private(set) var hasLoadedModels = false
    private(set) var hasLoadedProjects = false

    func refreshModels() async {
        guard !isLoadingModels else { return }
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            models = try await T3CodeClient.shared.favoriteModels()
            modelsError = nil
        } catch {
            modelsError = error.localizedDescription
        }
        hasLoadedModels = true
    }

    func refreshProjects() async {
        guard !isLoadingProjects else { return }
        isLoadingProjects = true
        defer { isLoadingProjects = false }
        do {
            projects = try await T3CodeClient.shared.projects()
            projectsError = nil
        } catch {
            projectsError = error.localizedDescription
        }
        hasLoadedProjects = true
    }

    func suggestedProject(forFolder folderPath: String) -> T3Project? {
        let folder = folderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folder.isEmpty else { return nil }
        return projects.first { $0.workspaceRoot == folder }
    }
}

@MainActor
enum T3Dispatch {
    static let lastModelDefaultsKey = "t3LastModelID"

    /// Launches a T3 thread for the task, marks it running, and hands the thread
    /// to the background monitor. Failures move the task back to todo.
    static func send(
        taskID: TaskItem.ID,
        boardID: TaskBoard.ID,
        model: T3ModelOption,
        store: TaskBoardStore,
        onError: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        guard let board = store.board(for: boardID),
              let task = store.task(for: taskID, in: boardID) else {
            onError("This task no longer exists.")
            return
        }
        guard let projectID = board.t3ProjectID else {
            onError(T3CodeError.boardNotLinked.localizedDescription)
            return
        }

        UserDefaults.standard.set(model.id, forKey: lastModelDefaultsKey)
        store.moveTask(taskID: taskID, in: boardID, to: .running)
        let monitor = T3RunMonitor.shared
        let runID = monitor.start(
            boardID: boardID,
            taskID: taskID,
            projectID: projectID,
            modelLabel: model.displayTitle
        )
        let title = task.title
        let attachments = task.attachments
        // Reused if the launch is retried, so T3 never creates a duplicate.
        let clientRequestID = "taskboard-\(runID.uuidString)"

        Task {
            do {
                let receipt = try await T3CodeClient.shared.launchThread(
                    projectID: projectID,
                    title: title,
                    prompt: title,
                    attachments: attachments,
                    model: model,
                    clientRequestID: clientRequestID
                )
                monitor.attach(receipt, to: runID)
            } catch {
                monitor.fail(runID, error: error)
                store.moveTask(taskID: taskID, in: boardID, to: .todo)
                onError(error.localizedDescription)
            }
        }
    }

    static func preferredModel(from models: [T3ModelOption]) -> T3ModelOption? {
        let lastID = UserDefaults.standard.string(forKey: lastModelDefaultsKey)
        return models.first { $0.id == lastID } ?? models.first
    }
}

// MARK: - Glyph

struct T3Glyph: View {
    var size: CGFloat = 16
    var tint: Color
    var filled = false

    var body: some View {
        Text("t3")
            .font(.system(size: size * 0.56, weight: .heavy, design: .rounded))
            .tracking(-0.3)
            .foregroundStyle(filled ? Color.black.opacity(0.85) : tint)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .fill(filled ? tint : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .stroke(tint, lineWidth: filled ? 0 : 1.1)
            )
    }
}

/// The small t3 button on every task row; its dot reflects the latest run.
struct T3TaskButton: View {
    let board: TaskBoard
    let task: TaskItem
    let run: T3RunRecord?
    @Bindable var store: TaskBoardStore

    @State private var isPresented = false
    @State private var isHovered = false
    @State private var sendError: String?

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            T3Glyph(size: 15, tint: glyphTint, filled: run?.phase.isActive == true)
                .frame(width: 26, height: 26)
                .overlay(alignment: .topTrailing) {
                    if let run {
                        PulseDot(color: statusColor(for: run.phase), isActive: run.phase.isActive)
                            .offset(x: -3, y: 3)
                    }
                }
                .scaleEffect(isHovered ? 1.08 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { isHovered = hovering }
        }
        .help(helpText)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            T3SendPopover(
                board: board,
                task: task,
                run: run,
                store: store,
                onSend: { model in
                    T3Dispatch.send(taskID: task.id, boardID: board.id, model: model, store: store) { message in
                        sendError = message
                    }
                },
                onDismiss: { isPresented = false }
            )
        }
        .alert("Could not send to T3 Code", isPresented: Binding(
            get: { sendError != nil },
            set: { if !$0 { sendError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(sendError ?? "")
        }
    }

    private var glyphTint: Color {
        guard let run else { return isHovered ? board.theme.accentColor : Color.primary.opacity(0.36) }
        return statusColor(for: run.phase)
    }

    private func statusColor(for phase: T3RunPhase) -> Color {
        switch phase {
        case .completed, .settled: .green
        case .waiting, .stopped, .failed: .orange
        default: board.theme.accentColor
        }
    }

    private var helpText: String {
        guard let run else { return "Send to T3 Code" }
        if let error = run.errorMessage { return error }
        return "\(run.phase.title) · \(run.modelLabel)"
    }
}

private struct PulseDot: View {
    let color: Color
    let isActive: Bool
    @State private var expanded = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 5, height: 5)
            .background {
                if isActive {
                    Circle()
                        .fill(color.opacity(expanded ? 0 : 0.55))
                        .scaleEffect(expanded ? 3 : 1)
                        .onAppear {
                            withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                                expanded = true
                            }
                        }
                }
            }
    }
}

// MARK: - Send popover

struct T3SendPopover: View {
    let board: TaskBoard
    let task: TaskItem
    let run: T3RunRecord?
    @Bindable var store: TaskBoardStore
    let onSend: (T3ModelOption) -> Void
    let onDismiss: () -> Void

    @State private var catalog = T3Catalog.shared
    @State private var appeared = false
    @State private var launchingModelID: T3ModelOption.ID?
    @State private var hoveredModelID: T3ModelOption.ID?

    private var accent: Color { board.theme.accentColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 12)

            Divider().opacity(0.5)

            Group {
                if board.t3ProjectID == nil {
                    T3ProjectList(
                        board: board,
                        store: store,
                        caption: "LINK THIS BOARD TO A T3 PROJECT"
                    )
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        if let run {
                            T3RunStatusCard(run: run, accent: accent)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                        modelSection
                    }
                    .padding(12)
                }
            }
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))
        }
        .frame(width: 304)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: board.t3ProjectID)
        .scaleEffect(appeared ? 1 : 0.94, anchor: .top)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) { appeared = true }
        }
        .task {
            async let models: Void = catalog.refreshModels()
            if board.t3ProjectID == nil { await catalog.refreshProjects() }
            await models
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            T3Glyph(size: 28, tint: accent, filled: true)
                .rotationEffect(.degrees(appeared ? 0 : -12))
                .scaleEffect(appeared ? 1 : 0.6)

            VStack(alignment: .leading, spacing: 3) {
                Text("Send to T3 Code")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text(task.title)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.primary.opacity(0.5))
                    .lineLimit(2)
                if let project = board.t3ProjectTitle {
                    Label(project, systemImage: "folder")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(accent.opacity(0.9))
                        .labelStyle(.titleAndIcon)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var modelSection: some View {
        HStack {
            Text("FAVOURITES")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(Color.primary.opacity(0.4))
            Spacer()
            if catalog.isLoadingModels {
                ProgressView().controlSize(.mini)
            }
        }

        if !catalog.hasLoadedModels && catalog.models.isEmpty {
            VStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { index in
                    ShimmerRow(delay: Double(index) * 0.12)
                }
            }
        } else if catalog.models.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(catalog.modelsError ?? "No favourite models yet. Star models in T3 Code's model picker and they appear here.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(catalog.modelsError == nil ? Color.primary.opacity(0.5) : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry") { Task { await catalog.refreshModels() } }
                    .controlSize(.small)
            }
        } else {
            VStack(spacing: 3) {
                ForEach(Array(catalog.models.enumerated()), id: \.element.id) { index, model in
                    modelRow(model, index: index)
                }
            }
        }
    }

    private func modelRow(_ model: T3ModelOption, index: Int) -> some View {
        let isLaunching = launchingModelID == model.id
        let isHovered = hoveredModelID == model.id
        let isPreferred = T3Dispatch.preferredModel(from: catalog.models)?.id == model.id
        let providerTint = model.accentHex.map(Color.init(hex:)) ?? accent

        return Button {
            launch(model)
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(providerTint)
                    .frame(width: 7, height: 7)
                    .shadow(color: providerTint.opacity(0.6), radius: isHovered ? 4 : 0)

                VStack(alignment: .leading, spacing: 1) {
                    Text(model.modelLabel)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(isLaunching ? Color.black.opacity(0.85) : .primary)
                    Text(model.providerName)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(isLaunching ? Color.black.opacity(0.55) : Color.primary.opacity(0.42))
                }

                Spacer(minLength: 6)

                if isLaunching {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.black.opacity(0.8))
                        .transition(.move(edge: .leading).combined(with: .opacity))
                } else if index < 9 {
                    Text("\(index + 1)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(isPreferred ? 0.6 : 0.28))
                        .frame(width: 16, height: 16)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(Color.primary.opacity(isPreferred ? 0.3 : 0.12))
                        )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isLaunching ? accent : Color.primary.opacity(isHovered ? 0.07 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(launchingModelID != nil)
        .keyboardShortcut(index < 9 ? KeyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: []) : nil)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { hoveredModelID = hovering ? model.id : nil }
        }
        .offset(y: appeared ? 0 : 10)
        .opacity(appeared ? 1 : 0)
        .animation(
            .spring(response: 0.42, dampingFraction: 0.8).delay(0.05 + Double(index) * 0.04),
            value: appeared
        )
        .help(isPreferred ? "\(model.displayTitle) · last used" : model.displayTitle)
    }

    private func launch(_ model: T3ModelOption) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
            launchingModelID = model.id
        }
        onSend(model)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(420))
            onDismiss()
        }
    }
}

private struct ShimmerRow: View {
    let delay: Double
    @State private var phase = false

    var body: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.primary.opacity(phase ? 0.09 : 0.04))
            .frame(height: 34)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever().delay(delay)) { phase = true }
            }
    }
}

private struct T3RunStatusCard: View {
    let run: T3RunRecord
    let accent: Color

    private var tint: Color {
        switch run.phase {
        case .completed, .settled: .green
        case .waiting, .stopped, .failed: .orange
        default: accent
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: run.phase.systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(tint)
                .symbolEffect(.pulse, isActive: run.phase.isActive)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(run.phase.title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                Text(run.errorMessage ?? run.modelLabel)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(run.errorMessage == nil ? Color.primary.opacity(0.45) : Color.orange)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            if let link = run.threadLink ?? run.threadID.flatMap(T3Environment.threadLink) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link, forType: .string)
                } label: {
                    Image(systemName: "link")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .buttonStyle(.plain)
                .help("Copy thread link to reference it in another T3 thread")
            }

            if let threadID = run.threadID {
                Button {
                    T3Environment.openThread(threadID)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .buttonStyle(.plain)
                .help("Open thread in T3 Code")
            }
        }
        .padding(10)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(tint.opacity(0.18)))
    }
}

// MARK: - Project linking

/// Lists T3 projects; picking one links the board. Used in the send popover for
/// unlinked boards and in the board header's project popover.
struct T3ProjectList: View {
    let board: TaskBoard
    @Bindable var store: TaskBoardStore
    let caption: String
    var onLinked: () -> Void = {}

    @State private var catalog = T3Catalog.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(caption)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(Color.primary.opacity(0.4))
                Spacer()
                if catalog.isLoadingProjects { ProgressView().controlSize(.mini) }
            }

            if let error = catalog.projectsError, catalog.projects.isEmpty {
                Text(error)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry") { Task { await catalog.refreshProjects() } }
                    .controlSize(.small)
            } else if !catalog.hasLoadedProjects && catalog.projects.isEmpty {
                ForEach(0..<3, id: \.self) { index in
                    ShimmerRow(delay: Double(index) * 0.12)
                }
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(sortedProjects) { project in
                            projectRow(project)
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .padding(12)
        .task { await catalog.refreshProjects() }
    }

    private var suggestedID: String? {
        catalog.suggestedProject(forFolder: board.folderPath)?.id
    }

    private var sortedProjects: [T3Project] {
        catalog.projects.sorted { lhs, rhs in
            if lhs.id == suggestedID { return true }
            if rhs.id == suggestedID { return false }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private func projectRow(_ project: T3Project) -> some View {
        let isLinked = board.t3ProjectID == project.id
        return Button {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                store.linkT3Project(id: project.id, title: project.title, for: board.id)
            }
            onLinked()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: isLinked ? "checkmark.circle.fill" : "folder")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isLinked ? board.theme.accentColor : Color.primary.opacity(0.45))
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(project.title)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                        if project.id == suggestedID {
                            Text("FOLDER MATCH")
                                .font(.system(size: 7, weight: .heavy, design: .monospaced))
                                .foregroundStyle(board.theme.accentColor)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(board.theme.accentColor.opacity(0.14), in: Capsule())
                        }
                    }
                    Text(abbreviatedPath(project.workspaceRoot))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.38))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isLinked ? board.theme.accentColor.opacity(0.1) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func abbreviatedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// Board header control showing the linked T3 project.
struct T3ProjectLinkButton: View {
    let board: TaskBoard
    @Bindable var store: TaskBoardStore

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 5) {
                T3Glyph(size: 13, tint: board.t3ProjectID == nil ? Color.orange.opacity(0.8) : board.theme.accentColor)
                if let title = board.t3ProjectTitle {
                    Text(title)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.5))
                        .lineLimit(1)
                        .frame(maxWidth: 90)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(board.t3ProjectTitle.map { "Linked to T3 project \($0)" } ?? "Link this board to a T3 Code project")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                T3ProjectList(board: board, store: store, caption: "T3 PROJECT") {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(250))
                        isPresented = false
                    }
                }
                if board.t3ProjectID != nil {
                    Divider().opacity(0.5)
                    Button("Unlink project", role: .destructive) {
                        store.linkT3Project(id: nil, title: nil, for: board.id)
                        isPresented = false
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.red.opacity(0.8))
                    .padding(12)
                }
            }
            .frame(width: 300)
        }
    }
}
