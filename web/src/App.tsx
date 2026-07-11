import {
  DndContext,
  DragOverlay,
  PointerSensor,
  TouchSensor,
  useDraggable,
  useDroppable,
  useSensor,
  useSensors,
  type DragEndEvent,
  type DragStartEvent,
} from "@dnd-kit/core";
import { memo, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { hasUserContent, loadSnapshot, saveSnapshot } from "./storage";
import {
  clearConfig,
  loadConfig,
  makeClient,
  saveConfig,
  SnapshotSync,
  type SupabaseConfig,
  type SyncState,
} from "./supabase";
import { appleReferenceSeconds, themeFor, themes, type Snapshot, type TaskBoard, type TaskItem, type TaskStatus } from "./types";

const laneOrder: TaskStatus[] = ["done", "running", "todo"];
const laneMeta: Record<TaskStatus, { label: string; icon: string; empty: string; color: string }> = {
  done: { label: "DONE", icon: "✓", empty: "Finished tasks land here", color: "#35d86f" },
  running: { label: "RUNNING", icon: "≋", empty: "Nothing in motion", color: "var(--accent)" },
  todo: { label: "TODO", icon: "○", empty: "Nothing waiting", color: "#a6a9b0" },
};

function App() {
  const [snapshot, setSnapshot] = useState<Snapshot>(loadSnapshot);
  const [syncState, setSyncState] = useState<SyncState>("offline");
  const [syncDetail, setSyncDetail] = useState("");
  const [showConnection, setShowConnection] = useState(false);
  const [showNewBoard, setShowNewBoard] = useState(false);
  const [newBoardTitle, setNewBoardTitle] = useState("");
  const [quickTitle, setQuickTitle] = useState("");
  const [activeTaskID, setActiveTaskID] = useState<string | null>(null);
  const [connectionVersion, setConnectionVersion] = useState(0);
  const syncRef = useRef<SnapshotSync | null>(null);
  const didInitializeSync = useRef(false);

  const selectedBoard = useMemo(() => {
    return snapshot.boards.find((board) => board.id === snapshot.selectedBoardID) ?? snapshot.boards[0];
  }, [snapshot.boards, snapshot.selectedBoardID]);
  const theme = themeFor(selectedBoard?.themeID ?? "cobalt");

  const sensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: { distance: 7 } }),
    useSensor(TouchSensor, { activationConstraint: { delay: 180, tolerance: 7 } }),
  );

  useEffect(() => {
    saveSnapshot(snapshot);
    if (didInitializeSync.current) syncRef.current?.scheduleSave(snapshot);
  }, [snapshot]);

  useEffect(() => {
    let cancelled = false;
    const config = loadConfig();
    if (!config) {
      setSyncState("offline");
      return;
    }
    const client = makeClient(config);

    async function start() {
      setSyncState("connecting");
      const { data } = await client.auth.getSession();
      if (cancelled) return;
      const user = data.session?.user;
      if (!user) {
        setSyncState("offline");
        setSyncDetail("Sign in to sync");
        return;
      }

      const sync = new SnapshotSync(
        client,
        user.id,
        (remote) => {
          setSnapshot((local) => (hasUserContent(local) && !hasUserContent(remote) ? local : remote));
        },
        (state, detail) => {
          setSyncState(state);
          setSyncDetail(detail ?? "");
        },
      );
      syncRef.current = sync;
      try {
        await sync.start(snapshot);
        didInitializeSync.current = true;
      } catch (error) {
        setSyncState("error");
        setSyncDetail(error instanceof Error ? error.message : "Sync failed");
      }
    }
    void start();

    return () => {
      cancelled = true;
      syncRef.current?.stop();
      syncRef.current = null;
      didInitializeSync.current = false;
    };
  }, [connectionVersion]);

  const updateSelectedBoard = useCallback((mutate: (board: TaskBoard) => TaskBoard) => {
    setSnapshot((current) => ({
      ...current,
      boards: current.boards.map((board) =>
        board.id === (current.selectedBoardID ?? current.boards[0]?.id) ? mutate(board) : board,
      ),
    }));
  }, []);

  const addTask = useCallback(() => {
    const title = quickTitle.trim();
    if (!title) return;
    updateSelectedBoard((board) => ({
      ...board,
      tasks: [
        ...board.tasks,
        {
          id: crypto.randomUUID(),
          title,
          createdAt: appleReferenceSeconds(),
          isCompleted: false,
          statusOverride: null,
          completedAt: null,
          attachments: [],
        },
      ],
    }));
    setQuickTitle("");
    navigator.vibrate?.(12);
  }, [quickTitle, updateSelectedBoard]);

  const moveTask = useCallback(
    (taskID: string, status: TaskStatus) => {
      updateSelectedBoard((board) => ({
        ...board,
        tasks: board.tasks.map((task) =>
          task.id === taskID && !task.isCompleted ? { ...task, statusOverride: status } : task,
        ),
      }));
      navigator.vibrate?.(18);
    },
    [updateSelectedBoard],
  );

  const completeTask = useCallback(
    (taskID: string) => {
      updateSelectedBoard((board) => ({
        ...board,
        tasks: board.tasks.map((task) =>
          task.id === taskID
            ? { ...task, isCompleted: true, statusOverride: null, completedAt: appleReferenceSeconds() }
            : task,
        ),
      }));
      navigator.vibrate?.([15, 35, 15]);
    },
    [updateSelectedBoard],
  );

  const renameTask = useCallback(
    (task: TaskItem) => {
      const title = window.prompt("Rename task", task.title)?.trim();
      if (!title || title === task.title) return;
      updateSelectedBoard((board) => ({
        ...board,
        tasks: board.tasks.map((candidate) => (candidate.id === task.id ? { ...candidate, title } : candidate)),
      }));
    },
    [updateSelectedBoard],
  );

  const createBoard = () => {
    const title = newBoardTitle.trim() || `Board ${snapshot.boards.length + 1}`;
    const boardID = crypto.randomUUID();
    const usedThemes = new Set(snapshot.boards.map((board) => board.themeID));
    const nextTheme = themes.find((candidate) => !usedThemes.has(candidate.id)) ?? themes[snapshot.boards.length % themes.length];
    setSnapshot((current) => ({
      selectedBoardID: boardID,
      boards: [
        {
          id: boardID,
          title,
          themeID: nextTheme.id,
          folderPath: "",
          createdAt: appleReferenceSeconds(),
          isExpanded: true,
          isPinned: false,
          tasks: [],
        },
        ...current.boards,
      ],
    }));
    setNewBoardTitle("");
    setShowNewBoard(false);
  };

  const handleDragEnd = ({ active, over }: DragEndEvent) => {
    setActiveTaskID(null);
    if (!over || typeof over.id !== "string" || !over.id.startsWith("lane:")) return;
    moveTask(String(active.id), over.id.slice(5) as TaskStatus);
  };

  const activeTask = selectedBoard?.tasks.find((task) => task.id === activeTaskID);

  return (
    <main className="app-shell" style={{ "--accent": theme.accent } as React.CSSProperties}>
      <div className="aurora" aria-hidden="true" />
      <header className="app-header">
        <span className="wordmark">taskboard</span>
        <button className={`sync-chip ${syncState}`} onClick={() => setShowConnection(true)}>
          <span>{syncState === "synced" ? "✓" : syncState === "connecting" ? "↻" : "⌁"}</span>
          {syncState === "synced" ? "Synced" : syncState === "connecting" ? "Syncing" : "Offline"}
        </button>
      </header>

      <nav className="board-strip" aria-label="Boards">
        {snapshot.boards.map((board) => {
          const boardTheme = themeFor(board.themeID);
          const count = board.tasks.filter((task) => !task.isCompleted).length;
          const selected = board.id === selectedBoard.id;
          return (
            <button
              className={`board-tab ${selected ? "selected" : ""}`}
              key={board.id}
              onClick={() => setSnapshot((current) => ({ ...current, selectedBoardID: board.id }))}
            >
              <span className="board-dot" style={{ background: boardTheme.accent }} />
              <span>{board.title}</span>
              {count > 0 ? <b style={{ color: selected ? boardTheme.accent : undefined }}>{count}</b> : null}
            </button>
          );
        })}
        <button className="add-board" aria-label="New board" onClick={() => setShowNewBoard(true)}>+</button>
      </nav>

      <form
        className="quick-entry"
        onSubmit={(event) => {
          event.preventDefault();
          addTask();
        }}
      >
        <span className="spark">✦</span>
        <input value={quickTitle} onChange={(event) => setQuickTitle(event.target.value)} placeholder="What needs doing?" />
        <button type="submit" disabled={!quickTitle.trim()} aria-label="Add task">↑</button>
      </form>

      <DndContext
        sensors={sensors}
        onDragStart={({ active }: DragStartEvent) => setActiveTaskID(String(active.id))}
        onDragCancel={() => setActiveTaskID(null)}
        onDragEnd={handleDragEnd}
      >
        <section className="lanes">
          {laneOrder.map((status) => {
            const tasks = selectedBoard.tasks.filter((task) => {
              if (task.isCompleted) return false;
              if (status === "todo") return !task.statusOverride || task.statusOverride === "todo";
              return task.statusOverride === status;
            });
            return (
              <Lane
                key={status}
                status={status}
                tasks={tasks}
                onComplete={completeTask}
                onRename={renameTask}
              />
            );
          })}
        </section>
        <DragOverlay>{activeTask ? <DragPreview task={activeTask} /> : null}</DragOverlay>
      </DndContext>

      {showConnection ? (
        <ConnectionSheet
          detail={syncDetail}
          onClose={() => setShowConnection(false)}
          onConnected={() => {
            setShowConnection(false);
            setConnectionVersion((version) => version + 1);
          }}
          onImport={(imported) => {
            setSnapshot(imported);
            setShowConnection(false);
          }}
          snapshot={snapshot}
        />
      ) : null}

      {showNewBoard ? (
        <div className="modal-backdrop" onMouseDown={() => setShowNewBoard(false)}>
          <section className="sheet small-sheet" onMouseDown={(event) => event.stopPropagation()}>
            <div className="sheet-handle" />
            <h2>New board</h2>
            <input autoFocus value={newBoardTitle} onChange={(event) => setNewBoardTitle(event.target.value)} placeholder="Board name" />
            <button className="primary-button" onClick={createBoard}>Create board</button>
          </section>
        </div>
      ) : null}
    </main>
  );
}

const Lane = memo(function Lane({
  status,
  tasks,
  onComplete,
  onRename,
}: {
  status: TaskStatus;
  tasks: TaskItem[];
  onComplete: (id: string) => void;
  onRename: (task: TaskItem) => void;
}) {
  const { setNodeRef, isOver } = useDroppable({ id: `lane:${status}` });
  const meta = laneMeta[status];
  return (
    <section ref={setNodeRef} className={`lane ${isOver ? "targeted" : ""}`} style={{ "--lane": meta.color } as React.CSSProperties}>
      <header className="lane-header">
        <span className="lane-icon">{meta.icon}</span>
        <span>{meta.label}</span>
        <b>{tasks.length}</b>
        {isOver ? <em>DROP</em> : null}
      </header>
      <div className="lane-content">
        {tasks.length === 0 ? (
          <div className="empty-lane"><span>{meta.icon}</span>{meta.empty}</div>
        ) : (
          tasks.map((task) => <TaskCard key={task.id} task={task} onComplete={onComplete} onRename={onRename} />)
        )}
      </div>
    </section>
  );
});

const TaskCard = memo(function TaskCard({
  task,
  onComplete,
  onRename,
}: {
  task: TaskItem;
  onComplete: (id: string) => void;
  onRename: (task: TaskItem) => void;
}) {
  const { listeners, setNodeRef, transform, isDragging } = useDraggable({ id: task.id });
  const style = transform ? { transform: `translate3d(${transform.x}px, ${transform.y}px, 0)` } : undefined;
  return (
    <article ref={setNodeRef} className={`task-card ${isDragging ? "dragging" : ""}`} style={style} {...listeners}>
      <button
        className="complete-button"
        aria-label="Archive task"
        onPointerDown={(event) => event.stopPropagation()}
        onClick={() => onComplete(task.id)}
      />
      <button
        className="task-title"
        onPointerDown={(event) => event.stopPropagation()}
        onClick={() => onRename(task)}
      >
        {task.title}
      </button>
      {task.statusOverride === "running" ? <span className="bolt">⚡</span> : null}
    </article>
  );
});

function DragPreview({ task }: { task: TaskItem }) {
  return <div className="drag-preview"><span />{task.title}</div>;
}

function ConnectionSheet({
  onClose,
  onConnected,
  onImport,
  snapshot,
  detail,
}: {
  onClose: () => void;
  onConnected: () => void;
  onImport: (snapshot: Snapshot) => void;
  snapshot: Snapshot;
  detail: string;
}) {
  const existing = loadConfig();
  const [url, setURL] = useState(existing?.url ?? "");
  const [anonKey, setAnonKey] = useState(existing?.anonKey ?? "");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [message, setMessage] = useState(detail);
  const [busy, setBusy] = useState(false);

  const authenticate = async (createAccount: boolean) => {
    const config: SupabaseConfig = { url: url.trim(), anonKey: anonKey.trim() };
    if (!config.url || !config.anonKey || !email || !password) {
      setMessage("Fill in all four fields.");
      return;
    }
    setBusy(true);
    try {
      const client = makeClient(config);
      const result = createAccount
        ? await client.auth.signUp({ email, password })
        : await client.auth.signInWithPassword({ email, password });
      if (result.error) throw result.error;
      saveConfig(config);
      setMessage(createAccount && !result.data.session ? "Check your email, then sign in." : "Connected.");
      if (result.data.session) onConnected();
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "Could not connect");
    } finally {
      setBusy(false);
    }
  };

  const exportSnapshot = () => {
    const blob = new Blob([JSON.stringify(snapshot, null, 2)], { type: "application/json" });
    const anchor = document.createElement("a");
    anchor.href = URL.createObjectURL(blob);
    anchor.download = "taskboard-backup.json";
    anchor.click();
    URL.revokeObjectURL(anchor.href);
  };

  return (
    <div className="modal-backdrop" onMouseDown={onClose}>
      <section className="sheet" onMouseDown={(event) => event.stopPropagation()}>
        <div className="sheet-handle" />
        <div className="sheet-heading"><div><span>SYNC</span><h2>Connect Supabase</h2></div><button onClick={onClose}>×</button></div>
        <p>Your project URL and public anon key are stored only on this device. Your task data is protected by your Supabase login.</p>
        <label>Project URL<input value={url} onChange={(event) => setURL(event.target.value)} placeholder="https://…supabase.co" /></label>
        <label>Anon key<input value={anonKey} onChange={(event) => setAnonKey(event.target.value)} type="password" placeholder="eyJ…" /></label>
        <div className="credentials">
          <label>Email<input value={email} onChange={(event) => setEmail(event.target.value)} type="email" /></label>
          <label>Password<input value={password} onChange={(event) => setPassword(event.target.value)} type="password" /></label>
        </div>
        {message ? <div className="connection-message">{message}</div> : null}
        <div className="sheet-actions">
          <button className="primary-button" disabled={busy} onClick={() => void authenticate(false)}>Sign in</button>
          <button className="secondary-button" disabled={busy} onClick={() => void authenticate(true)}>Create account</button>
        </div>
        <div className="backup-row">
          <label className="file-button">Import JSON<input type="file" accept="application/json" onChange={async (event) => {
            const file = event.target.files?.[0];
            if (!file) return;
            try {
              const imported = JSON.parse(await file.text()) as Snapshot;
              if (!imported.boards?.length) throw new Error("No boards found");
              onImport(imported);
            } catch { setMessage("That file is not a taskboard snapshot."); }
          }} /></label>
          <button className="text-button" onClick={exportSnapshot}>Export backup</button>
          {existing ? <button className="text-button danger" onClick={() => { clearConfig(); window.location.reload(); }}>Disconnect</button> : null}
        </div>
      </section>
    </div>
  );
}

export default App;
