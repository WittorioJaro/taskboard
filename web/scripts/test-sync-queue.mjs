import assert from "node:assert/strict";
import { createServer } from "vite";

globalThis.window = globalThis;

const delay = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));
const snapshotWithStatus = (statusOverride) => ({
  selectedBoardID: "board",
  boards: [{
    id: "board",
    title: "Inbox",
    themeID: "cobalt",
    folderPath: "",
    createdAt: 0,
    isExpanded: true,
    isPinned: false,
    tasks: [{
      id: "task",
      title: "Race test",
      createdAt: 0,
      isCompleted: false,
      statusOverride,
      completedAt: null,
      attachments: [],
    }],
  }],
});

const base = snapshotWithStatus("todo");
const running = snapshotWithStatus("running");
const todo = snapshotWithStatus("todo");
const pendingWrites = [];
const remoteSnapshots = [];
let realtimeHandler;

const backend = {
  listen(onData) {
    realtimeHandler = onData;
    queueMicrotask(() => onData({ payload: base, updatedAt: 1 }));
    return () => {};
  },
  write(envelope) {
    return new Promise((resolve) => pendingWrites.push({ envelope, resolve }));
  },
};

const vite = await createServer({ server: { middlewareMode: true }, appType: "custom" });
try {
  const { SnapshotSync, snapshotForSync } = await vite.ssrLoadModule("/src/firebase.ts");
  const { mergeRemoteSnapshot } = await vite.ssrLoadModule("/src/storage.ts");

  const otherBoard = { ...base.boards[0], id: "other", title: "Other", tasks: [] };
  const localOnOtherTab = { ...base, selectedBoardID: "other", boards: [base.boards[0], otherBoard] };
  const remoteOnOldTab = {
    ...running,
    selectedBoardID: "board",
    boards: [running.boards[0], otherBoard],
  };
  assert.equal(
    mergeRemoteSnapshot(localOnOtherTab, remoteOnOldTab).selectedBoardID,
    "other",
    "remote content must not switch the browser back to another tab",
  );
  assert.equal(snapshotForSync(localOnOtherTab).selectedBoardID, null);
  const firebaseShape = {
    ...base,
    boards: base.boards.map((board) => ({
      ...board,
      tasks: board.tasks.map(({ attachments: _attachments, ...task }) => task),
    })),
  };
  assert.deepEqual(
    mergeRemoteSnapshot(base, firebaseShape).boards[0].tasks[0].attachments,
    [],
    "Firebase-omitted empty arrays must be restored",
  );

  const sync = new SnapshotSync(
    {},
    "owner",
    (snapshot) => remoteSnapshots.push(snapshot),
    () => {},
    backend,
  );
  await sync.start(base);

  sync.beginLocalMutation();
  sync.scheduleSave(running);
  await delay(380);
  assert.equal(pendingWrites.length, 1, "the first write should be in flight");
  assert.equal(pendingWrites[0].envelope.payload.selectedBoardID, null, "device selection must not be uploaded");

  sync.beginLocalMutation();
  sync.scheduleSave(todo);
  await delay(380);
  assert.equal(pendingWrites.length, 1, "the newer write must wait for the first write");

  const firstVersion = pendingWrites[0].envelope.updatedAt;
  pendingWrites[0].resolve();
  await delay(0);
  assert.equal(pendingWrites.length, 2, "the queued TODO write should start after RUNNING finishes");
  assert.equal(pendingWrites[1].envelope.payload.boards[0].tasks[0].statusOverride, "todo");

  const secondVersion = pendingWrites[1].envelope.updatedAt;
  pendingWrites[1].resolve();
  await delay(0);

  realtimeHandler({ payload: running, updatedAt: firstVersion });
  assert.equal(remoteSnapshots.length, 1, "a stale RUNNING echo must be ignored");

  realtimeHandler({ payload: running, updatedAt: secondVersion + 1 });
  assert.equal(remoteSnapshots.length, 2, "a genuinely newer remote edit must still apply");
  sync.stop();
} finally {
  await vite.close();
}

console.log("sync queue race test passed");
