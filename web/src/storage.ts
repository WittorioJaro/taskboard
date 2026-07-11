import { makeEmptySnapshot, type Snapshot } from "./types";

const STORAGE_KEY = "taskboard.snapshot.v1";

export function loadSnapshot(): Snapshot {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return makeEmptySnapshot();
    const snapshot = JSON.parse(raw) as Snapshot;
    return snapshot.boards?.length ? snapshot : makeEmptySnapshot();
  } catch {
    return makeEmptySnapshot();
  }
}

export function saveSnapshot(snapshot: Snapshot): void {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(snapshot));
}

export function hasUserContent(snapshot: Snapshot): boolean {
  return (
    snapshot.boards.length > 1 ||
    snapshot.boards.some((board) => board.title !== "Inbox" || board.tasks.length > 0 || board.folderPath.length > 0)
  );
}
