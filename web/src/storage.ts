import { makeEmptySnapshot, normalizeSnapshot, type Snapshot } from "./types";

const STORAGE_KEY = "taskboard.snapshot.v1";

export function loadSnapshot(): Snapshot {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return makeEmptySnapshot();
    const snapshot = JSON.parse(raw) as Snapshot;
    return snapshot.boards?.length ? normalizeSnapshot(snapshot) : makeEmptySnapshot();
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

export function mergeRemoteSnapshot(local: Snapshot, remote: Snapshot): Snapshot {
  remote = normalizeSnapshot(remote);
  if (hasUserContent(local) && !hasUserContent(remote)) return local;
  const localSelectionStillExists = remote.boards.some((board) => board.id === local.selectedBoardID);
  return {
    ...remote,
    // Selection is device-local UI state; remote content must not navigate this client.
    selectedBoardID: localSelectionStillExists ? local.selectedBoardID : remote.selectedBoardID,
  };
}

const BASELINE_KEY = "taskboard.syncBaseline.v1";

/** The last snapshot this device and the cloud agreed on, per account. */
export function loadSyncBaseline(ownerID: string): Snapshot | null {
  try {
    const raw = localStorage.getItem(BASELINE_KEY);
    if (!raw) return null;
    const stored = JSON.parse(raw) as { ownerID?: string; snapshot?: Snapshot };
    return stored.ownerID === ownerID && stored.snapshot?.boards ? normalizeSnapshot(stored.snapshot) : null;
  } catch {
    return null;
  }
}

export function saveSyncBaseline(ownerID: string, snapshot: Snapshot): void {
  try {
    localStorage.setItem(BASELINE_KEY, JSON.stringify({ ownerID, snapshot }));
  } catch {
    // A missing baseline only makes the next launch prefer cloud data.
  }
}
