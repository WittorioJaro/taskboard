import AppKit
import SwiftUI

struct CodexSendSheet: View {
    @Bindable var store: TaskBoardStore
    let boardID: TaskBoard.ID
    @Binding var isPresented: Bool

    @State private var selectedTaskIDs: Set<TaskItem.ID> = []
    @State private var threadStartTaskIDs: Set<TaskItem.ID> = []
    @State private var model: CodexModel = .recommended
    @State private var availableModels = CodexModel.fallbackModels
    @State private var isLoadingModels = false
    @State private var effort: CodexReasoningEffort = .medium
    @State private var branchMode = BranchMode.new
    @State private var newBranchName = ""
    @State private var existingBranch = "main"
    @State private var availableBranches: [String] = []
    @State private var isLoadingBranches = false
    @State private var isSending = false
    @State private var completedCount = 0
    @State private var activeGroupIndex: Int?
    @State private var completedGroupIndices: Set<Int> = []
    @State private var errorMessage: String?
    @State private var receipts: [CodexLaunchReceipt] = []
    @State private var dispatchStatus = CodexDispatchStatus(.waiting)
    @State private var runMonitor = CodexRunMonitor.shared

    private var board: TaskBoard? { store.board(for: boardID) }
    private var selectedTasks: [TaskItem] {
        board?.openTasks.filter { selectedTaskIDs.contains($0.id) } ?? []
    }
    private var taskGroups: [[TaskItem]] {
        CodexThreadPlan.groups(
            orderedTasks: selectedTasks,
            threadStartTaskIDs: threadStartTaskIDs
        )
    }
    private var threadNumberByTaskID: [TaskItem.ID: Int] {
        Dictionary(uniqueKeysWithValues: taskGroups.enumerated().flatMap { groupIndex, tasks in
            tasks.map { ($0.id, groupIndex + 1) }
        })
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()

            if let board {
                VStack(alignment: .leading, spacing: 18) {
                    header(board)
                    folderSection(board)
                    taskSection(board)
                    configurationSection
                    statusSection
                    footer
                }
                .padding(24)
            }
        }
        .frame(width: 740, height: 820)
        .task {
            await loadModels()
            await loadBranches()
        }
    }

    private func header(_ board: TaskBoard) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Codex Queue")
                .font(.system(size: 25, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
            Text("Split selected prompts across focused threads that all work on one branch.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color.primary.opacity(0.52))
        }
    }

    private func folderSection(_ board: TaskBoard) -> some View {
        section("Board Folder") {
            HStack(spacing: 10) {
                Text(board.folderPath.isEmpty ? "No folder selected" : board.folderPath)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(board.folderPath.isEmpty ? Color.orange : Color.primary.opacity(0.78))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button("Choose", action: chooseFolder)
                    .buttonStyle(.borderedProminent)
                    .tint(.primary)
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
            }
        }
    }

    private func taskSection(_ board: TaskBoard) -> some View {
        section("Thread Plan · \(selectedTasks.count) selected") {
            HStack(spacing: 10) {
                Text(threadPlanSummary)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(selectedTasks.isEmpty ? Color.primary.opacity(0.42) : board.theme.accentColor)
                Spacer()
                Button(selectedTaskIDs.count == board.openTasks.count ? "Clear" : "Select all") {
                    toggleAllTasks(in: board)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.primary.opacity(0.55))
            }

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(board.openTasks) { task in
                        HStack(alignment: .top, spacing: 10) {
                            Button {
                                toggleTask(task)
                            } label: {
                                Image(systemName: selectedTaskIDs.contains(task.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(selectedTaskIDs.contains(task.id) ? board.theme.accentColor : Color.primary.opacity(0.3))
                                    .padding(.top, 1)
                            }
                            .buttonStyle(.plain)

                            Button {
                                toggleTask(task)
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(task.title)
                                        .font(.system(size: 14, weight: .medium, design: .rounded))
                                        .foregroundStyle(.primary.opacity(0.9))
                                        .multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    AttachmentDraftStrip(attachments: task.attachments)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if let threadNumber = threadNumberByTaskID[task.id] {
                                Button {
                                    toggleThreadStart(before: task)
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: threadBadgeImage(for: task))
                                            .font(.system(size: 9, weight: .bold))
                                        Text("T\(threadNumber)")
                                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    }
                                    .foregroundStyle(threadColor(threadNumber))
                                    .padding(.horizontal, 9)
                                    .frame(height: 28)
                                    .background(threadColor(threadNumber).opacity(0.13), in: Capsule())
                                    .overlay(Capsule().stroke(threadColor(threadNumber).opacity(0.22)))
                                }
                                .buttonStyle(.plain)
                                .disabled(task.id == selectedTasks.first?.id)
                                .opacity(task.id == selectedTasks.first?.id ? 0.65 : 1)
                                .help(threadStartTaskIDs.contains(task.id)
                                    ? "Merge this task and the following prompts into the previous thread"
                                    : "Start a new Codex thread with this task")
                            }
                        }
                        .padding(13)
                        .background(Color.primary.opacity(selectedTaskIDs.contains(task.id) ? 0.08 : 0.035), in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
            .frame(maxHeight: 255)

            Text("Click a task’s thread badge to split before it. Threads run in order and share the branch and worktree.")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color.primary.opacity(0.46))
        }
    }

    private var configurationSection: some View {
        section("Run Configuration") {
            HStack(spacing: 12) {
                labeledPicker("Model", selection: $model, values: availableModels)
                    .disabled(isLoadingModels)
                labeledPicker("Thinking", selection: $effort, values: model.supportedReasoningEfforts)
            }
            .onChange(of: model) { _, selectedModel in
                if !selectedModel.supportedReasoningEfforts.contains(effort) {
                    effort = selectedModel.defaultReasoningEffort
                }
            }

            Picker("Branch", selection: $branchMode) {
                Text("New branch").tag(BranchMode.new)
                Text("Existing branch").tag(BranchMode.existing)
            }
            .pickerStyle(.segmented)

            if branchMode == .new {
                TextField("codex/feature-name", text: $newBranchName)
                    .textFieldStyle(.plain)
                    .fieldChrome()
            } else {
                Picker("Existing branch", selection: $existingBranch) {
                    ForEach(availableBranches, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                .fieldChrome()
                .disabled(isLoadingBranches)
            }

            Text("Runs in the background. The persisted thread will appear in Codex history without focusing the Codex window.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.primary.opacity(0.48))
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if isSending {
            HStack(spacing: 12) {
                Image(systemName: dispatchStatus.phase.systemImage)
                    .foregroundStyle(.primary)
                    .symbolEffect(.pulse, isActive: dispatchStatus.phase.isActive)
                VStack(alignment: .leading, spacing: 3) {
                    Text(dispatchStatus.phase.title)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.8))
                    Text(queueStatusDetail)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.46))
                }
            }
        } else if !receipts.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("Queue complete · \(receipts.count) thread\(receipts.count == 1 ? "" : "s") · \(completedCount) prompts")
                    .foregroundStyle(Color.green.opacity(0.9))
                ForEach(Array(receipts.enumerated()), id: \.offset) { index, receipt in
                    Text("T\(index + 1) · …\(CodexDisplayText.threadID(receipt.threadID))")
                }
                if let worktreePath = receipts.first?.worktreePath {
                    Text(worktreePath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.primary.opacity(0.56))
        } else if let errorMessage {
            Text(errorMessage)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.orange.opacity(0.94))
        }
    }

    private var footer: some View {
        HStack {
            Button("Close") { isPresented = false }
                .buttonStyle(.plain)
                .foregroundStyle(Color.primary.opacity(0.6))
            Spacer()
            Button(action: sendQueue) {
                Text("Run \(selectedTasks.count) Prompt\(selectedTasks.count == 1 ? "" : "s") in \(taskGroups.count) Thread\(taskGroups.count == 1 ? "" : "s")")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
            }
            .buttonStyle(.borderedProminent)
            .tint(.primary)
            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
            .disabled(!canSend)
        }
    }

    private var canSend: Bool {
        guard let board else { return false }
        let branchReady = branchMode == .existing
            ? !existingBranch.isEmpty
            : !newBranchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return !isSending && !selectedTasks.isEmpty && !board.folderPath.isEmpty && branchReady
    }

    private var queueStatusDetail: String {
        if let threadID = dispatchStatus.threadID {
            let groupNumber = (activeGroupIndex ?? 0) + 1
            let promptNumber = min(completedCount + 1, max(selectedTasks.count, 1))
            return "Thread \(groupNumber)/\(taskGroups.count) · prompt \(promptNumber)/\(selectedTasks.count) · …\(CodexDisplayText.threadID(threadID))"
        }
        if let activeGroupIndex {
            return "Preparing thread \(activeGroupIndex + 1)/\(taskGroups.count) on the shared branch"
        }
        return "Codex threads have not been created yet"
    }

    private var threadPlanSummary: String {
        guard !taskGroups.isEmpty else { return "Select prompts to build a thread plan" }
        return "\(taskGroups.count) thread\(taskGroups.count == 1 ? "" : "s") · "
            + taskGroups.map { String($0.count) }.joined(separator: " / ")
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.primary.opacity(0.42))
            content()
        }
        .padding(16)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.07)))
    }

    private func labeledPicker<Value: Hashable & Identifiable>(
        _ title: String,
        selection: Binding<Value>,
        values: [Value]
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.primary.opacity(0.42))
            Picker(title, selection: selection) {
                ForEach(values) { value in
                    Text(displayTitle(value)).tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fieldChrome()
        }
        .frame(maxWidth: .infinity)
    }

    private func displayTitle<Value>(_ value: Value) -> String {
        if let value = value as? CodexModel { return value.title }
        if let value = value as? CodexReasoningEffort { return value.title }
        return String(describing: value)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            store.setFolderPath(url.path, for: boardID)
            Task { await loadBranches() }
        }
    }

    private func toggleTask(_ task: TaskItem) {
        if selectedTaskIDs.contains(task.id) {
            selectedTaskIDs.remove(task.id)
            threadStartTaskIDs.remove(task.id)
        } else {
            selectedTaskIDs.insert(task.id)
        }
        pruneThreadStarts()
        suggestBranchName()
    }

    private func toggleAllTasks(in board: TaskBoard) {
        if selectedTaskIDs.count == board.openTasks.count {
            selectedTaskIDs.removeAll()
            threadStartTaskIDs.removeAll()
        } else {
            selectedTaskIDs = Set(board.openTasks.map(\.id))
            pruneThreadStarts()
        }
        suggestBranchName()
    }

    private func toggleThreadStart(before task: TaskItem) {
        guard task.id != selectedTasks.first?.id else { return }
        if threadStartTaskIDs.contains(task.id) {
            threadStartTaskIDs.remove(task.id)
        } else {
            threadStartTaskIDs.insert(task.id)
        }
    }

    private func pruneThreadStarts() {
        threadStartTaskIDs.formIntersection(selectedTaskIDs)
        if let firstTaskID = selectedTasks.first?.id {
            threadStartTaskIDs.remove(firstTaskID)
        }
    }

    private func threadColor(_ number: Int) -> Color {
        let colors: [Color] = [.blue, .orange, .purple, .green, .pink, .teal]
        return colors[(max(number, 1) - 1) % colors.count]
    }

    private func suggestBranchName() {
        guard let board, branchMode == .new else { return }
        newBranchName = CodexBranchNameBuilder.suggestedBranchName(
            boardTitle: board.title,
            taskTitles: selectedTasks.map(\.title)
        )
    }

    private func loadBranches() async {
        guard let board, !board.folderPath.isEmpty else { return }
        isLoadingBranches = true
        do {
            let branches = try await CodexTaskDispatcher.shared.availableBranches(workspacePath: board.folderPath)
            availableBranches = branches
            if !branches.contains(existingBranch) { existingBranch = branches.first ?? "" }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoadingBranches = false
    }

    private func loadModels() async {
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            let models = try await CodexTaskDispatcher.shared.availableModels()
            availableModels = models
            model = models.first(where: \.isDefault) ?? models[0]
            effort = model.defaultReasoningEffort
        } catch {
            availableModels = CodexModel.fallbackModels
            model = .recommended
        }
    }

    private func sendQueue() {
        guard let board else { return }
        let groups = taskGroups
        let tasks = groups.flatMap { $0 }
        let choice: CodexBranchChoice = branchMode == .new
            ? .new(newBranchName)
            : .existing(existingBranch)
        isSending = true
        completedCount = 0
        activeGroupIndex = nil
        completedGroupIndices = []
        errorMessage = nil
        receipts = []
        dispatchStatus = .init(.waiting, totalCount: tasks.count)
        store.clearTaskStatusOverride(taskIDs: tasks.map(\.id), in: board.id)
        let runIDs = groups.enumerated().map { groupIndex, group in
            runMonitor.start(
                boardID: board.id,
                taskID: nil,
                taskIDs: group.map(\.id),
                title: "Thread \(groupIndex + 1) · \(group.count) prompt\(group.count == 1 ? "" : "s") · \(board.title)",
                kind: .queue,
                totalCount: group.count
            )
        }

        Task {
            do {
                let result = try await CodexTaskDispatcher.shared.sendGroupedQueue(
                    boardTitle: board.title,
                    taskGroups: groups,
                    workspacePath: board.folderPath,
                    branchChoice: choice,
                    model: model,
                    effort: effort,
                    status: { update in
                        await MainActor.run {
                            dispatchStatus = update.groupStatus
                            activeGroupIndex = update.groupIndex
                            if let groupIndex = update.groupIndex,
                               runIDs.indices.contains(groupIndex) {
                                runMonitor.apply(update.groupStatus, to: runIDs[groupIndex])
                            } else {
                                for (index, runID) in runIDs.enumerated()
                                where !completedGroupIndices.contains(index) {
                                    runMonitor.apply(
                                        .init(
                                            update.groupStatus.phase,
                                            completedCount: 0,
                                            totalCount: groups[index].count
                                        ),
                                        to: runID
                                    )
                                }
                            }
                        }
                    },
                    groupCompleted: { groupIndex, receipt in
                        await MainActor.run {
                            completedGroupIndices.insert(groupIndex)
                            receipts.append(receipt)
                            if runIDs.indices.contains(groupIndex) {
                                runMonitor.complete(runIDs[groupIndex], receipt: receipt)
                            }
                        }
                    },
                    progress: { completed, _ in
                        await MainActor.run { completedCount = completed }
                    }
                )
                await MainActor.run {
                    receipts = result.threads
                    completedCount = result.completedTaskCount
                    isSending = false
                    activeGroupIndex = nil
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSending = false
                    activeGroupIndex = nil
                    for (index, runID) in runIDs.enumerated()
                    where !completedGroupIndices.contains(index) {
                        runMonitor.fail(runID, error: error)
                    }
                }
            }
        }
    }

    private enum BranchMode: Hashable {
        case new
        case existing
    }

    private func threadBadgeImage(for task: TaskItem) -> String {
        if task.id == selectedTasks.first?.id { return "text.bubble.fill" }
        return threadStartTaskIDs.contains(task.id) ? "arrow.triangle.branch" : "plus"
    }
}

enum CodexThreadPlan {
    static func groups(
        orderedTasks: [TaskItem],
        threadStartTaskIDs: Set<TaskItem.ID>
    ) -> [[TaskItem]] {
        guard let firstTask = orderedTasks.first else { return [] }

        var groups: [[TaskItem]] = [[firstTask]]
        for task in orderedTasks.dropFirst() {
            if threadStartTaskIDs.contains(task.id) {
                groups.append([task])
            } else {
                groups[groups.count - 1].append(task)
            }
        }
        return groups
    }
}

private extension View {
    func fieldChrome() -> some View {
        padding(.horizontal, 12)
            .frame(minHeight: 42)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.primary.opacity(0.08)))
    }
}
