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

  const { displayBoard } = await vite.ssrLoadModule("/src/types.ts");
  const { mergeCloudChanges } = await vite.ssrLoadModule("/src/snapshotMerge.ts");
  const { parseDeadline, deadlineLabel, isOverdue } = await vite.ssrLoadModule("/src/deadlines.ts");
  const { dayKey } = await vite.ssrLoadModule("/src/types.ts");
  assert.equal(deadlineLabel("2026-12-31", "2026-12-31"), "Due today");
  assert.equal(deadlineLabel("2027-01-01", "2026-12-31"), "Due tomorrow");
  assert.equal(isOverdue("2026-10-31", "2026-11-01"), true);
  assert.equal(isOverdue("2026-11-01", "2026-11-01"), false);
  assert.equal(dayKey(parseDeadline("2026-11-01")), "2026-11-01", "date must stay on its calendar day across time zones");
  assert.equal(dayKey(parseDeadline("2028-02-29")), "2028-02-29");
  for (const invalid of ["2026-02-29", "2026-02-30", "2026-1-01", "2026-13-01", "2026-11-01T00:00:00Z", ""]) {
    assert.equal(parseDeadline(invalid), null);
  }
  const deadlineBaseline = structuredClone(base);
  deadlineBaseline.boards[0].tasks[0].dueDate = "2026-11-04";
  const phonePlan = structuredClone(deadlineBaseline);
  phonePlan.boards[0].tasks[0].plannedFor = "2026-11-01";
  const remoteDeadline = structuredClone(deadlineBaseline);
  remoteDeadline.boards[0].tasks[0].dueDate = "2026-11-02";
  remoteDeadline.boards[0].tasks[0].isCompleted = true;
  const deadlineMerge = mergeCloudChanges(phonePlan, remoteDeadline, deadlineBaseline).boards[0].tasks[0];
  assert.equal(deadlineMerge.dueDate, "2026-11-02");
  assert.equal(deadlineMerge.plannedFor, "2026-11-01");
  assert.equal(deadlineMerge.isCompleted, true);
  phonePlan.boards[0].tasks[0].dueDate = null;
  assert.equal(mergeCloudChanges(phonePlan, remoteDeadline, deadlineBaseline).boards[0].tasks[0].dueDate, null, "clearing a deadline must survive concurrent plan and completion edits");

  const todayBoard = { ...base.boards[0], id: "today", title: "Today", tasks: [] };
  const planned = structuredClone(base);
  planned.boards.unshift(todayBoard);
  planned.boards[1].tasks[0].plannedFor = "2026-10-31";
  planned.boards[1].tasks[0].todayOrder = 0;
  assert.equal(displayBoard(planned, todayBoard, "2026-10-31").tasks[0].id, "task");
  assert.equal(displayBoard(planned, todayBoard, "2026-11-01").tasks.length, 0);
  assert.equal(planned.boards[0].tasks.length, 0, "Today must not store copies of project tasks");
  const localRename = structuredClone(base);
  localRename.boards[0].tasks[0].title = "Edited on phone";
  const agentPlan = structuredClone(base);
  agentPlan.boards[0].tasks[0].plannedFor = "2026-10-31";
  agentPlan.boards[0].tasks[0].todayOrder = 2;
  agentPlan.boards[0].tasks.push({ ...base.boards[0].tasks[0], id: "new-from-agent" });
  const merged = mergeCloudChanges(localRename, agentPlan, base);
  assert.equal(merged.boards[0].tasks[0].title, "Edited on phone");
  assert.equal(merged.boards[0].tasks[0].plannedFor, "2026-10-31");
  assert.equal(merged.boards[0].tasks[0].todayOrder, 2);
  assert.equal(merged.boards[0].tasks[1].id, "new-from-agent");
  const kindleTick = structuredClone(base);
  kindleTick.boards[0].tasks[0].isCompleted = true;
  kindleTick.boards[0].tasks[0].completedAt = 123;
  assert.equal(mergeCloudChanges(localRename, kindleTick, base).boards[0].tasks[0].isCompleted, true);

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

  const acknowledgedCount = remoteSnapshots.length;
  realtimeHandler({ payload: running, updatedAt: firstVersion });
  assert.equal(remoteSnapshots.length, acknowledgedCount, "a stale RUNNING echo must be ignored");

  realtimeHandler({ payload: running, updatedAt: secondVersion + 1 });
  assert.equal(remoteSnapshots.length, acknowledgedCount + 1, "a genuinely newer remote edit must still apply");
  sync.stop();

  // An agent addition merged into the first upload must also reach the UI
  // after a newer local edit was queued while that upload was in flight.
  let finishFirst;
  const firstStarted = new Promise((resolve) => { finishFirst = resolve; });
  let releaseUpload;
  let cloud = structuredClone(base);
  const acknowledgements = [];
  let writeCount = 0;
  const mergingBackend = {
    listen(onData) {
      queueMicrotask(() => onData({ payload: cloud, updatedAt: 1 }));
      return () => {};
    },
    async write(envelope, baseline) {
      writeCount += 1;
      if (writeCount === 1) {
        finishFirst();
        await new Promise((resolve) => { releaseUpload = resolve; });
        cloud = structuredClone(cloud);
        cloud.boards[0].tasks.push({ ...cloud.boards[0].tasks[0], id: "agent-addition" });
      }
      cloud = mergeCloudChanges(envelope.payload, cloud, baseline);
      return { payload: cloud, updatedAt: envelope.updatedAt };
    },
  };
  const mergingSync = new SnapshotSync({}, "owner", (value) => acknowledgements.push(value), () => {}, mergingBackend);
  await mergingSync.start(base);
  mergingSync.beginLocalMutation();
  mergingSync.scheduleSave(running);
  await firstStarted;
  mergingSync.beginLocalMutation();
  mergingSync.scheduleSave(todo);
  releaseUpload();
  await delay(420);
  assert.equal(writeCount, 2);
  const acknowledged = acknowledgements.at(-1);
  assert.equal(acknowledged.boards[0].tasks[0].statusOverride, "todo");
  assert.equal(acknowledged.boards[0].tasks[1].id, "agent-addition", "queued merge must reach the UI before its next edit");
  mergingSync.stop();

  // iOS relaunches the PWA from localStorage. A tap made before the first
  // cloud value must be merged with the cloud, not replaced by it.
  const macRename = structuredClone(base);
  macRename.boards[0].tasks[0].title = "Renamed on Mac";
  const tapped = structuredClone(base);
  tapped.boards[0].tasks[0].isCompleted = true;
  tapped.boards[0].tasks[0].completedAt = 42;
  for (const baseline of [base, undefined]) {
    let cloudValue = structuredClone(macRename);
    const writes = [];
    const applied = [];
    const startupBackend = {
      listen(onData) {
        queueMicrotask(() => onData({ payload: cloudValue, updatedAt: 5 }));
        return () => {};
      },
      async write(envelope, writeBaseline) {
        writes.push(envelope);
        cloudValue = mergeCloudChanges(envelope.payload, cloudValue, writeBaseline);
        return { payload: cloudValue, updatedAt: 6 };
      },
    };
    const baselines = [];
    const startupSync = new SnapshotSync({}, "owner", (value) => applied.push(value), () => {}, startupBackend, {
      getLocal: () => tapped,
      baseline,
      onBaseline: (value) => baselines.push(value),
    });
    startupSync.scheduleSave(tapped);
    await startupSync.start(base);
    const label = baseline ? "with a stored baseline" : "without a stored baseline";
    assert.equal(writes.length, 1, `a startup tap must be uploaded ${label}`);
    const result = applied.at(-1).boards[0].tasks[0];
    assert.equal(result.isCompleted, true, `the startup tap must survive ${label}`);
    assert.equal(result.title, "Renamed on Mac", `the Mac edit must survive ${label}`);
    assert.equal(baselines.at(-1).boards[0].tasks[0].isCompleted, true, "the acknowledged value becomes the baseline");
    startupSync.stop();
  }

  // Unchanged local data takes the cloud value without writing.
  {
    const writes = [];
    const applied = [];
    const quietSync = new SnapshotSync({}, "owner", (value) => applied.push(value), () => {}, {
      listen(onData) {
        queueMicrotask(() => onData({ payload: macRename, updatedAt: 5 }));
        return () => {};
      },
      async write(envelope) { writes.push(envelope); },
    }, { getLocal: () => base, baseline: base });
    await quietSync.start(base);
    assert.equal(writes.length, 0);
    assert.equal(applied.at(-1).boards[0].tasks[0].title, "Renamed on Mac");
    quietSync.stop();
  }

  // A cloud write committed after ours, but delivered while ours was still
  // finishing, must not be dropped.
  {
    let push;
    let release;
    const applied = [];
    const lateSync = new SnapshotSync({}, "owner", (value) => applied.push(value), () => {}, {
      listen(onData) {
        push = onData;
        queueMicrotask(() => onData({ payload: base, updatedAt: 1 }));
        return () => {};
      },
      write(envelope) {
        return new Promise((resolve) => { release = () => resolve({ payload: envelope.payload, updatedAt: 10 }); });
      },
    }, { getLocal: () => base, baseline: base });
    await lateSync.start(base);
    lateSync.beginLocalMutation();
    lateSync.scheduleSave(running);
    await delay(380);
    push({ payload: macRename, updatedAt: 11 });
    release();
    await delay(0);
    assert.equal(applied.at(-1).boards[0].tasks[0].title, "Renamed on Mac", "a newer cloud write must apply after our save");
    lateSync.stop();
  }
} finally {
  await vite.close();
}

console.log("sync queue race test passed");
