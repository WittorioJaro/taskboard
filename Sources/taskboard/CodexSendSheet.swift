import AppKit
import SwiftUI

struct CodexSendSheet: View {
    @Bindable var store: TaskBoardStore
    let boardID: TaskBoard.ID
    @Binding var isPresented: Bool

    @State private var selectedTaskIDs: Set<TaskItem.ID> = []
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
    @State private var errorMessage: String?
    @State private var receipt: CodexLaunchReceipt?
    @State private var dispatchStatus = CodexDispatchStatus(.waiting)
    @State private var runMonitor = CodexRunMonitor.shared

    private var board: TaskBoard? { store.board(for: boardID) }
    private var selectedTasks: [TaskItem] {
        board?.openTasks.filter { selectedTaskIDs.contains($0.id) } ?? []
    }

    var body: some View {
        ZStack {
            Color(hex: "0B0E13").ignoresSafeArea()

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
        .frame(width: 720, height: 780)
        .task {
            await loadModels()
            await loadBranches()
        }
    }

    private func header(_ board: TaskBoard) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Codex Queue")
                .font(.system(size: 25, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Text("Send prompts from \(board.title) one by one into one persistent Codex thread.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.52))
        }
    }

    private func folderSection(_ board: TaskBoard) -> some View {
        section("Board Folder") {
            HStack(spacing: 10) {
                Text(board.folderPath.isEmpty ? "No folder selected" : board.folderPath)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(board.folderPath.isEmpty ? Color.orange : Color.white.opacity(0.78))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button("Choose", action: chooseFolder)
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
            }
        }
    }

    private func taskSection(_ board: TaskBoard) -> some View {
        section("Prompts · \(selectedTasks.count) selected") {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(board.openTasks) { task in
                        Button {
                            if selectedTaskIDs.contains(task.id) {
                                selectedTaskIDs.remove(task.id)
                            } else {
                                selectedTaskIDs.insert(task.id)
                            }
                            suggestBranchName()
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: selectedTaskIDs.contains(task.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(selectedTaskIDs.contains(task.id) ? board.theme.accentColor : Color.white.opacity(0.3))
                                    .padding(.top, 1)
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(task.title)
                                        .font(.system(size: 14, weight: .medium, design: .rounded))
                                        .foregroundStyle(.white.opacity(0.9))
                                        .multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    AttachmentDraftStrip(attachments: task.attachments)
                                }
                            }
                            .padding(13)
                            .background(Color.white.opacity(selectedTaskIDs.contains(task.id) ? 0.08 : 0.035), in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 250)
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
                .foregroundStyle(Color.white.opacity(0.48))
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if isSending {
            HStack(spacing: 12) {
                Image(systemName: dispatchStatus.phase.systemImage)
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, isActive: dispatchStatus.phase.isActive)
                VStack(alignment: .leading, spacing: 3) {
                    Text(dispatchStatus.phase.title)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.8))
                    Text(queueStatusDetail)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.46))
                }
            }
        } else if let receipt {
            VStack(alignment: .leading, spacing: 5) {
                Text("Queue complete · \(receipt.completedTaskCount) prompts")
                    .foregroundStyle(Color.green.opacity(0.9))
                Text("Thread \(receipt.threadID)")
                Text(receipt.worktreePath)
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.white.opacity(0.56))
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
                .foregroundStyle(Color.white.opacity(0.6))
            Spacer()
            Button(action: sendQueue) {
                Text("Run \(selectedTasks.count) Prompt\(selectedTasks.count == 1 ? "" : "s")")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundStyle(.black)
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
            let promptNumber = min(completedCount + 1, max(selectedTasks.count, 1))
            return "Prompt \(promptNumber)/\(selectedTasks.count) · thread …\(CodexDisplayText.threadID(threadID))"
        }
        return "Codex thread has not been created yet"
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.42))
            content()
        }
        .padding(16)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.07)))
    }

    private func labeledPicker<Value: Hashable & Identifiable>(
        _ title: String,
        selection: Binding<Value>,
        values: [Value]
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.42))
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
        let tasks = selectedTasks
        let choice: CodexBranchChoice = branchMode == .new
            ? .new(newBranchName)
            : .existing(existingBranch)
        isSending = true
        completedCount = 0
        errorMessage = nil
        receipt = nil
        dispatchStatus = .init(.waiting, totalCount: tasks.count)
        store.clearTaskStatusOverride(taskIDs: tasks.map(\.id), in: board.id)
        let runID = runMonitor.start(
            boardID: board.id,
            taskID: nil,
            taskIDs: tasks.map(\.id),
            title: "\(tasks.count) prompt\(tasks.count == 1 ? "" : "s") · \(board.title)",
            kind: .queue,
            totalCount: tasks.count
        )

        Task {
            do {
                let result = try await CodexTaskDispatcher.shared.sendQueue(
                    boardTitle: board.title,
                    tasks: tasks,
                    workspacePath: board.folderPath,
                    branchChoice: choice,
                    model: model,
                    effort: effort,
                    status: { status in
                        await MainActor.run {
                            dispatchStatus = status
                            runMonitor.apply(status, to: runID)
                        }
                    },
                    progress: { completed, _ in
                        await MainActor.run { completedCount = completed }
                    }
                )
                await MainActor.run {
                    receipt = result
                    isSending = false
                    runMonitor.complete(runID, receipt: result)
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSending = false
                    runMonitor.fail(runID, error: error)
                }
            }
        }
    }

    private enum BranchMode: Hashable {
        case new
        case existing
    }
}

private extension View {
    func fieldChrome() -> some View {
        padding(.horizontal, 12)
            .frame(minHeight: 42)
            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.white.opacity(0.08)))
    }
}
