import type { Snapshot, TaskBoard, TaskItem } from "./types";

function canonical(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  const object = value as Record<string, unknown>;
  return `{${Object.keys(object).filter((key) => object[key] !== undefined).sort()
    .map((key) => `${JSON.stringify(key)}:${canonical(object[key])}`).join(",")}}`;
}
const equal = (left: unknown, right: unknown) => canonical(left) === canonical(right);
const field = <T>(base: T, local: T, remote: T): T => equal(base, local) ? remote : local;

function mergeItems<T extends { id: string }>(base: T[], local: T[], remote: T[], merge: (base: T, local: T, remote: T) => T): T[] {
  const bases = new Map(base.map((item) => [item.id, item]));
  const locals = new Map(local.map((item) => [item.id, item]));
  const remotes = new Map(remote.map((item) => [item.id, item]));
  const localOrderChanged = !equal(base.map((item) => item.id), local.map((item) => item.id));
  const order = localOrderChanged ? [...local, ...remote] : [...remote, ...local];
  const seen = new Set<string>();
  const result: T[] = [];
  for (const item of order) {
    if (seen.has(item.id)) continue;
    seen.add(item.id);
    const original = bases.get(item.id), ours = locals.get(item.id), theirs = remotes.get(item.id);
    if (original && ours && theirs) result.push(merge(original, ours, theirs));
    else if (original && ours && !theirs) { if (!equal(original, ours)) result.push(ours); }
    else if (original && !ours) continue;
    else if (ours ?? theirs) result.push((ours ?? theirs)!);
  }
  return result;
}

function mergeTask(base: TaskItem, local: TaskItem, remote: TaskItem): TaskItem {
  const completionUnchanged = equal([base.isCompleted, base.statusOverride ?? null, base.completedAt ?? null],
    [local.isCompleted, local.statusOverride ?? null, local.completedAt ?? null]);
  const planUnchanged = equal([base.plannedFor ?? null, base.todayOrder ?? null], [local.plannedFor ?? null, local.todayOrder ?? null]);
  return {
    ...remote, ...local,
    title: field(base.title, local.title, remote.title),
    dueDate: field(base.dueDate ?? null, local.dueDate ?? null, remote.dueDate ?? null),
    attachments: field(base.attachments, local.attachments, remote.attachments),
    ...(completionUnchanged ? { isCompleted: remote.isCompleted, statusOverride: remote.statusOverride, completedAt: remote.completedAt } : {}),
    ...(planUnchanged ? { plannedFor: remote.plannedFor, todayOrder: remote.todayOrder } : {}),
  };
}

function mergeBoard(base: TaskBoard, local: TaskBoard, remote: TaskBoard): TaskBoard {
  const projectUnchanged = equal([base.t3ProjectID ?? null, base.t3ProjectTitle ?? null], [local.t3ProjectID ?? null, local.t3ProjectTitle ?? null]);
  return {
    ...remote, ...local,
    title: field(base.title, local.title, remote.title),
    themeID: field(base.themeID, local.themeID, remote.themeID),
    folderPath: field(base.folderPath, local.folderPath, remote.folderPath),
    isExpanded: field(base.isExpanded, local.isExpanded, remote.isExpanded),
    isPinned: field(base.isPinned, local.isPinned, remote.isPinned),
    ...(projectUnchanged ? { t3ProjectID: remote.t3ProjectID, t3ProjectTitle: remote.t3ProjectTitle } : {}),
    tasks: mergeItems(base.tasks, local.tasks, remote.tasks, mergeTask),
  };
}

export function mergeCloudChanges(local: Snapshot, remote: Snapshot, baseline: Snapshot | null): Snapshot {
  // Without a saved baseline, preserve additions instead of assuming deletes.
  const base = baseline ?? {
    boards: remote.boards.filter((board) => local.boards.some((candidate) => candidate.id === board.id)).map((board) => ({
      ...board,
      tasks: board.tasks.filter((task) => local.boards.find((candidate) => candidate.id === board.id)!.tasks.some((candidate) => candidate.id === task.id)),
    })),
  };
  return { ...local, boards: mergeItems(base.boards, local.boards, remote.boards, mergeBoard) };
}
