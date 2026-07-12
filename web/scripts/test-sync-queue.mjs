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

const client = {
  from() {
    return {
      select() {
        const query = {
          eq() { return query; },
          async maybeSingle() {
            return { data: { payload: base, updated_at: "2026-01-01T00:00:00.000Z" }, error: null };
          },
        };
        return query;
      },
      upsert(row) {
        return {
          select() {
            return {
              single() {
                return new Promise((resolve) => pendingWrites.push({ row, resolve }));
              },
            };
          },
        };
      },
    };
  },
  channel() {
    return {
      on(_event, _filter, handler) { realtimeHandler = handler; return this; },
      subscribe(handler) { handler("SUBSCRIBED"); return this; },
    };
  },
  async removeChannel() {},
};

const vite = await createServer({ server: { middlewareMode: true }, appType: "custom" });
try {
  const { SnapshotSync } = await vite.ssrLoadModule("/src/supabase.ts");
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

  const sync = new SnapshotSync(
    client,
    "owner",
    (snapshot) => remoteSnapshots.push(snapshot),
    () => {},
  );
  await sync.start(base);

  sync.beginLocalMutation();
  sync.scheduleSave(running);
  await delay(380);
  assert.equal(pendingWrites.length, 1, "the first write should be in flight");

  sync.beginLocalMutation();
  sync.scheduleSave(todo);
  await delay(380);
  assert.equal(pendingWrites.length, 1, "the newer write must wait for the first write");

  pendingWrites[0].resolve({
    data: { payload: running, updated_at: "2026-01-01T00:00:01.000Z" },
    error: null,
  });
  await delay(0);
  assert.equal(pendingWrites.length, 2, "the queued TODO write should start after RUNNING finishes");
  assert.equal(pendingWrites[1].row.payload.boards[0].tasks[0].statusOverride, "todo");

  pendingWrites[1].resolve({
    data: { payload: todo, updated_at: "2026-01-01T00:00:02.000Z" },
    error: null,
  });
  await delay(0);

  realtimeHandler({ new: { payload: running, updated_at: "2026-01-01T00:00:01.000Z" } });
  assert.equal(remoteSnapshots.length, 1, "a stale RUNNING echo must be ignored");

  realtimeHandler({ new: { payload: running, updated_at: "2026-01-01T00:00:03.000Z" } });
  assert.equal(remoteSnapshots.length, 2, "a genuinely newer remote edit must still apply");
  sync.stop();
} finally {
  await vite.close();
}

console.log("sync queue race test passed");
