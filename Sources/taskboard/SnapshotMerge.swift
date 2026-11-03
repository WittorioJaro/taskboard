import Foundation

extension TaskBoardSnapshot {
    /// On the first upload after an older client upgrade there may be no saved
    /// sync baseline. Preserve remote additions; let local fields win for shared
    /// IDs rather than interpreting missing records as intentional deletions.
    func mergingCloudChanges(from remote: Self, since baseline: Self?) -> Self {
        let base = baseline ?? Self(boards: remote.boards.compactMap { board in
            guard let local = boards.first(where: { $0.id == board.id }) else { return nil }
            var common = board
            common.tasks = board.tasks.filter { task in local.tasks.contains { $0.id == task.id } }
            return common
        })
        return mergingExternalChanges(from: remote, since: base)
    }

    /// Merge against the last snapshot this process read or wrote. Changes to
    /// different fields survive; a local edit wins a conflict on the same field.
    func mergingExternalChanges(from external: Self, since baseline: Self) -> Self {
        Self(
            boards: mergeItems(baseline.boards, boards, external.boards) { base, local, remote in
                var merged = local
                merged.title = mergeValue(base.title, local.title, remote.title)
                merged.themeID = mergeValue(base.themeID, local.themeID, remote.themeID)
                merged.folderPath = mergeValue(base.folderPath, local.folderPath, remote.folderPath)
                // Keep the linked project's ID and display title together.
                if local.t3ProjectID == base.t3ProjectID && local.t3ProjectTitle == base.t3ProjectTitle {
                    merged.t3ProjectID = remote.t3ProjectID
                    merged.t3ProjectTitle = remote.t3ProjectTitle
                }
                merged.isExpanded = mergeValue(base.isExpanded, local.isExpanded, remote.isExpanded)
                merged.isPinned = mergeValue(base.isPinned, local.isPinned, remote.isPinned)
                merged.tasks = mergeItems(base.tasks, local.tasks, remote.tasks) { base, local, remote in
                    var merged = local
                    merged.title = mergeValue(base.title, local.title, remote.title)
                    merged.dueDate = mergeValue(base.dueDate, local.dueDate, remote.dueDate)
                    if local.plannedFor == base.plannedFor && local.todayOrder == base.todayOrder {
                        merged.plannedFor = remote.plannedFor
                        merged.todayOrder = remote.todayOrder
                    }
                    merged.attachments = mergeValue(base.attachments, local.attachments, remote.attachments)
                    // Completion state is one edit; mixing its fields could
                    // produce a completed task with a running override.
                    if local.isCompleted == base.isCompleted,
                       local.statusOverride == base.statusOverride,
                       local.completedAt == base.completedAt {
                        merged.isCompleted = remote.isCompleted
                        merged.statusOverride = remote.statusOverride
                        merged.completedAt = remote.completedAt
                    }
                    return merged
                }
                return merged
            },
            selectedBoardID: selectedBoardID
        )
    }
}

private func mergeValue<Value: Equatable>(_ base: Value, _ local: Value, _ remote: Value) -> Value {
    local == base ? remote : local
}

private func mergeItems<Item: Identifiable & Equatable>(
    _ base: [Item],
    _ local: [Item],
    _ remote: [Item],
    merge: (Item, Item, Item) -> Item
) -> [Item] {
    // Do not trap on a malformed external snapshot with duplicate IDs.
    let baseByID = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let localByID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let remoteByID = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let localOrderChanged = base.map(\.id) != local.map(\.id)
    let ordered = localOrderChanged ? local + remote : remote + local
    var seen = Set<Item.ID>()
    return ordered.compactMap { item in
        guard seen.insert(item.id).inserted else { return nil }
        let original = baseByID[item.id]
        let ours = localByID[item.id]
        let theirs = remoteByID[item.id]
        switch (original, ours, theirs) {
        case let (base?, local?, remote?):
            return merge(base, local, remote)
        case let (base?, local?, nil):
            // Preserve an edited item; otherwise accept external deletion.
            return local == base ? nil : local
        case (_?, nil, _):
            return nil // An intentional local deletion wins.
        default:
            return ours ?? theirs // New items from either writer survive.
        }
    }
}
