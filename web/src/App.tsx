import {
  DndContext,
  DragOverlay,
  MouseSensor,
  TouchSensor,
  useDraggable,
  useDroppable,
  useSensor,
  useSensors,
  type DragEndEvent,
  type DragStartEvent,
} from "@dnd-kit/core";
import { memo, useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { deadlineLabel, isOverdue, parseDeadline } from "./deadlines";
import { loadSnapshot, loadSyncBaseline, mergeRemoteSnapshot, saveSnapshot, saveSyncBaseline } from "./storage";
import {
  authenticate as authenticateFirebase,
  clearConfig,
  currentUser,
  loadConfig,
  makeClient,
  saveConfig,
  SnapshotSync,
  type FirebaseConfig,
  type SyncState,
} from "./firebase";
import { dayKey, displayBoard, isTodayBoard, appleReferenceSeconds, themeFor, themes, type Snapshot, type TaskBoard, type TaskItem, type TaskStatus } from "./types";

const laneOrder: TaskStatus[] = ["done", "running", "todo"];
const laneMeta: Record<TaskStatus, { label: string; icon: string; empty: string; color: string }> = {
  done: { label: "DONE", icon: "✓", empty: "Finished tasks land here", color: "#35d86f" },
  running: { label: "RUNNING", icon: "≋", empty: "Nothing in motion", color: "var(--accent)" },
  todo: { label: "TODO", icon: "○", empty: "Nothing waiting", color: "#a6a9b0" },
};

type ArchivedTask = { boardID: string; task: TaskItem };

function App() {
  const [snapshot, setSnapshot] = useState<Snapshot>(loadSnapshot);
  const [day, setDay] = useState(dayKey);
  useEffect(() => {
    const timer = window.setInterval(() => setDay(dayKey()), 30_000);
    return () => window.clearInterval(timer);
  }, []);
  const [syncState, setSyncState] = useState<SyncState>("offline");
  const [syncDetail, setSyncDetail] = useState("");
  const [showConnection, setShowConnection] = useState(false);
  const [showNewBoard, setShowNewBoard] = useState(false);
  const [newBoardTitle, setNewBoardTitle] = useState("");
  const [quickTitle, setQuickTitle] = useState("");
  const [activeTaskID, setActiveTaskID] = useState<string | null>(null);
  const [connectionVersion, setConnectionVersion] = useState(0);
  const [pendingUndo, setPendingUndo] = useState<ArchivedTask | null>(null);
  const syncRef = useRef<SnapshotSync | null>(null);
  const undoTimerRef = useRef<number | null>(null);
  const isDraggingRef = useRef(false);
  const pendingRemoteRef = useRef<Snapshot | null>(null);

  const selectedBoard = useMemo(() => {
    return snapshot.boards.find((board) => board.id === snapshot.selectedBoardID) ?? snapshot.boards[0];
  }, [snapshot.boards, snapshot.selectedBoardID]);
  const theme = themeFor(selectedBoard?.themeID ?? "cobalt");
  const visibleBoard = useMemo(() => displayBoard(snapshot, selectedBoard, day), [snapshot, selectedBoard, day]);
  const sourceBoards = useMemo(() => {
    const sources = new Map<string, TaskBoard>();
    for (const board of snapshot.boards) for (const task of board.tasks) sources.set(task.id, board);
    return sources;
  }, [snapshot.boards]);

  const sensors = useSensors(
    useSensor(MouseSensor, { activationConstraint: { distance: 6 } }),
    useSensor(TouchSensor, { activationConstraint: { delay: 300, tolerance: 8 } }),
  );

  const applyRemote = useCallback((remote: Snapshot) => {
    if (isDraggingRef.current) {
      pendingRemoteRef.current = remote;
      return;
    }
    setSnapshot((local) => mergeRemoteSnapshot(local, remote));
  }, []);

  // Once a touch drag is active, block native scrolling for the rest of the
  // gesture — touch-action can't be changed mid-gesture, so this listener is
  // the only thing stopping the page from panning along with the card.
  useEffect(() => {
    if (!activeTaskID) return;
    const blockScroll = (event: TouchEvent) => event.preventDefault();
    window.addEventListener("touchmove", blockScroll, { passive: false });
    return () => window.removeEventListener("touchmove", blockScroll);
  }, [activeTaskID]);

  const openTaskCounts = useMemo(() => {
    const counts = new Map<string, number>();
    for (const board of snapshot.boards) {
      let count = 0;
      for (const task of displayBoard(snapshot, board, day).tasks) {
        if (!task.isCompleted) count += 1;
      }
      counts.set(board.id, count);
    }
    return counts;
  }, [snapshot, day]);

  const tasksByLane = useMemo<Record<TaskStatus, TaskItem[]>>(() => {
    const lanes: Record<TaskStatus, TaskItem[]> = { done: [], running: [], todo: [] };
    for (const task of visibleBoard.tasks) {
      if (task.isCompleted) continue;
      const status = task.statusOverride === "running" || task.statusOverride === "done"
        ? task.statusOverride
        : "todo";
      lanes[status].push(task);
    }
    return lanes;
  }, [visibleBoard.tasks]);

  const beginLocalMutation = useCallback(() => {
    syncRef.current?.beginLocalMutation();
  }, []);

  const latestSnapshotRef = useRef(snapshot);
  useEffect(() => {
    latestSnapshotRef.current = snapshot;
    saveSnapshot(snapshot);
    // SnapshotSync ignores this until its first cloud value, then reconciles
    // with latestSnapshotRef so taps made while it loads are kept.
    syncRef.current?.scheduleSave(snapshot);
  }, [snapshot]);

  useEffect(() => () => {
    if (undoTimerRef.current !== null) window.clearTimeout(undoTimerRef.current);
  }, []);

  useEffect(() => {
    let cancelled = false;
    const config = loadConfig();
    if (!config) {
      setSyncState("offline");
      return;
    }
    const client = makeClient(config);
    // Edits made before the first cloud value are measured against this.
    const loadedSnapshot = latestSnapshotRef.current;

    async function start() {
      setSyncState("connecting");
      const user = await currentUser(client.auth);
      if (cancelled) return;
      if (!user) {
        setSyncState("offline");
        setSyncDetail("Sign in to sync");
        return;
      }

      const sync = new SnapshotSync(
        client,
        user.uid,
        applyRemote,
        (state, detail) => {
          setSyncState(state);
          setSyncDetail(detail ?? "");
        },
        undefined,
        {
          getLocal: () => latestSnapshotRef.current,
          baseline: loadSyncBaseline(user.uid),
          onBaseline: (value) => saveSyncBaseline(user.uid, value),
        },
      );
      syncRef.current = sync;
      try {
        await sync.start(loadedSnapshot);
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
    };
  }, [connectionVersion]);

  const updateSelectedBoard = useCallback((mutate: (board: TaskBoard) => TaskBoard) => {
    beginLocalMutation();
    setSnapshot((current) => ({
      ...current,
      boards: current.boards.map((board) =>
        board.id === (current.selectedBoardID ?? current.boards[0]?.id) ? mutate(board) : board,
      ),
    }));
  }, [beginLocalMutation]);

  const updateTask = useCallback((taskID: string, mutate: (task: TaskItem) => TaskItem) => {
    beginLocalMutation();
    setSnapshot((current) => ({
      ...current,
      boards: current.boards.map((board) => board.tasks.some((task) => task.id === taskID)
        ? { ...board, tasks: board.tasks.map((task) => task.id === taskID ? mutate(task) : task) }
        : board),
    }));
  }, [beginLocalMutation]);

  const setDeadline = useCallback((taskID: string, dueDate: string | null) => {
    if (dueDate !== null && !parseDeadline(dueDate)) return;
    updateTask(taskID, (task) => ({ ...task, dueDate }));
  }, [updateTask]);

  const planTask = useCallback((taskID: string) => {
    beginLocalMutation();
    setSnapshot((current) => {
      const nextOrder = Math.max(-1, ...current.boards.flatMap((board) => board.tasks)
        .filter((task) => task.plannedFor === day).map((task) => task.todayOrder ?? -1)) + 1;
      const boards = current.boards.map((board) => ({
        ...board,
        tasks: board.tasks.map((task) => task.id === taskID ? {
          ...task,
          plannedFor: task.plannedFor === day ? null : day,
          todayOrder: task.plannedFor === day ? null : nextOrder,
        } : task),
      }));
      if (!boards.some(isTodayBoard)) boards.unshift({
        id: crypto.randomUUID(), title: "Today", themeID: "sunrise", folderPath: "",
        createdAt: appleReferenceSeconds(), isExpanded: true, isPinned: false, tasks: [],
      });
      return { ...current, boards };
    });
  }, [beginLocalMutation, day]);

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
      updateTask(taskID, (task) => task.isCompleted ? task : { ...task, statusOverride: status });
      navigator.vibrate?.(18);
    },
    [updateTask],
  );

  const armUndo = useCallback((archived: ArchivedTask) => {
    if (undoTimerRef.current !== null) window.clearTimeout(undoTimerRef.current);
    setPendingUndo(archived);
    undoTimerRef.current = window.setTimeout(() => {
      setPendingUndo(null);
      undoTimerRef.current = null;
    }, 6000);
  }, []);

  const completeTask = useCallback((taskID: string) => {
    const board = sourceBoards.get(taskID);
    const boardID = board?.id;
    const task = board?.tasks.find((candidate) => candidate.id === taskID);
    if (!boardID || !task) return;

    beginLocalMutation();
    armUndo({ boardID, task });
    setSnapshot((current) => ({
      ...current,
      boards: current.boards.map((candidate) => candidate.id === boardID
        ? {
            ...candidate,
            tasks: candidate.tasks.map((item) => item.id === taskID
              ? { ...item, isCompleted: true, statusOverride: null, completedAt: appleReferenceSeconds() }
              : item),
          }
        : candidate),
    }));
    navigator.vibrate?.([15, 35, 15]);
  }, [armUndo, beginLocalMutation, sourceBoards]);

  const undoArchive = useCallback(() => {
    if (!pendingUndo) return;
    if (undoTimerRef.current !== null) window.clearTimeout(undoTimerRef.current);
    const archived = pendingUndo;
    beginLocalMutation();
    setSnapshot((current) => ({
      ...current,
      boards: current.boards.map((board) => board.id === archived.boardID
        ? {
            ...board,
            tasks: board.tasks.map((task) => task.id === archived.task.id ? archived.task : task),
          }
        : board),
    }));
    setPendingUndo(null);
    undoTimerRef.current = null;
    navigator.vibrate?.(12);
  }, [beginLocalMutation, pendingUndo]);

  const renameTask = useCallback(
    (taskID: string, rawTitle: string) => {
      const title = rawTitle.trim();
      if (!title) return;
      updateTask(taskID, (task) => task.title === title ? task : { ...task, title });
    },
    [updateTask],
  );

  const createBoard = () => {
    const title = newBoardTitle.trim() || `Board ${snapshot.boards.length + 1}`;
    const boardID = crypto.randomUUID();
    const usedThemes = new Set(snapshot.boards.map((board) => board.themeID));
    const nextTheme = themes.find((candidate) => !usedThemes.has(candidate.id)) ?? themes[snapshot.boards.length % themes.length];
    beginLocalMutation();
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

  const flushPendingRemote = () => {
    const remote = pendingRemoteRef.current;
    pendingRemoteRef.current = null;
    if (remote) applyRemote(remote);
  };

  const handleDragEnd = ({ active, over }: DragEndEvent) => {
    setActiveTaskID(null);
    isDraggingRef.current = false;
    if (!over || typeof over.id !== "string" || !over.id.startsWith("lane:")) {
      flushPendingRemote();
      return;
    }
    // The drop is the newest edit; discard any remote snapshot that arrived
    // mid-drag so it can't revert the move (our save will overwrite it).
    pendingRemoteRef.current = null;
    moveTask(String(active.id), over.id.slice(5) as TaskStatus);
  };

  const activeTask = visibleBoard.tasks.find((task) => task.id === activeTaskID);

  return (
    <main className={`app-shell ${activeTaskID ? "is-dragging" : ""}`} style={{ "--accent": theme.accent } as React.CSSProperties}>
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
          const count = openTaskCounts.get(board.id) ?? 0;
          const selected = board.id === selectedBoard.id;
          return (
            <button
              className={`board-tab ${selected ? "selected" : ""}`}
              key={board.id}
              onClick={() => {
                setSnapshot((current) => ({ ...current, selectedBoardID: board.id }));
              }}
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

      {isTodayBoard(selectedBoard) ? <p className="today-caption">Your priorities, with each task linked to its project.</p> : null}

      <DndContext
        sensors={sensors}
        onDragStart={({ active }: DragStartEvent) => {
          navigator.vibrate?.(16);
          isDraggingRef.current = true;
          setActiveTaskID(String(active.id));
        }}
        onDragCancel={() => {
          setActiveTaskID(null);
          isDraggingRef.current = false;
          flushPendingRemote();
        }}
        onDragEnd={handleDragEnd}
      >
        <section className="lanes">
          {laneOrder.map((status) => {
            return (
              <Lane
                key={status}
                status={status}
                tasks={tasksByLane[status]}
                onComplete={completeTask}
                onRename={renameTask}
                onDeadline={setDeadline}
                onPlan={planTask}
                sourceBoards={sourceBoards}
                showsProject={isTodayBoard(selectedBoard)}
                day={day}
              />
            );
          })}
        </section>
        <DragOverlay dropAnimation={{ duration: 180, easing: "cubic-bezier(.2,.8,.2,1)" }}>
          {activeTask ? <DragPreview task={activeTask} /> : null}
        </DragOverlay>
      </DndContext>

      {pendingUndo ? (
        <div className="undo-toast" role="status" aria-live="polite">
          <span className="undo-message"><i aria-hidden="true">✓</i>Task archived</span>
          <button type="button" onClick={undoArchive}>Undo</button>
        </div>
      ) : null}

      {showConnection ? (
        <ConnectionSheet
          detail={syncDetail}
          onClose={() => setShowConnection(false)}
          onConnected={() => {
            setShowConnection(false);
            setConnectionVersion((version) => version + 1);
          }}
          onImport={(imported) => {
            beginLocalMutation();
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
  onDeadline,
  onPlan,
  sourceBoards,
  showsProject,
  day,
}: {
  onDeadline: (id: string, dueDate: string | null) => void;
  onPlan: (id: string) => void;
  sourceBoards: Map<string, TaskBoard>;
  showsProject: boolean;
  day: string;
  status: TaskStatus;
  tasks: TaskItem[];
  onComplete: (id: string) => void;
  onRename: (taskID: string, title: string) => void;
}) {
  const { setNodeRef, isOver } = useDroppable({ id: `lane:${status}` });
  const meta = laneMeta[status];
  return (
    <section ref={setNodeRef} className={`lane ${isOver ? "targeted" : ""}`} style={{ "--lane": meta.color } as React.CSSProperties}>
      <header className="lane-header">
        <span className="lane-icon">{meta.icon}</span>
        <span>{meta.label}</span>
        <b>{tasks.length}</b>
      </header>
      <div className="lane-content">
        {tasks.length === 0 ? (
          <div className="empty-lane"><span>{meta.icon}</span>{meta.empty}</div>
        ) : (
          tasks.map((task) => <TaskCard key={task.id} task={task} onComplete={onComplete} onRename={onRename}
            onPlan={onPlan} onDeadline={onDeadline} source={sourceBoards.get(task.id)} showsProject={showsProject} day={day} />)
        )}
      </div>
    </section>
  );
});

const TaskCard = memo(function TaskCard({
  task,
  onComplete,
  onRename,
  onDeadline,
  onPlan,
  source,
  showsProject,
  day,
}: {
  onDeadline: (id: string, dueDate: string | null) => void;
  onPlan: (id: string) => void;
  source?: TaskBoard;
  showsProject: boolean;
  day: string;
  task: TaskItem;
  onComplete: (id: string) => void;
  onRename: (taskID: string, title: string) => void;
}) {
  const { listeners, setNodeRef, transform, isDragging } = useDraggable({ id: task.id });
  const [isEditing, setIsEditing] = useState(false);
  const [isEditingDeadline, setIsEditingDeadline] = useState(false);
  const [draft, setDraft] = useState("");
  const cancelledRef = useRef(false);
  const editorRef = useRef<HTMLTextAreaElement>(null);
  const style = transform ? { transform: `translate3d(${transform.x}px, ${transform.y}px, 0)` } : undefined;

  useLayoutEffect(() => {
    if (!isEditing || !editorRef.current) return;
    const editor = editorRef.current;
    editor.style.height = "0";
    editor.style.height = `${editor.scrollHeight}px`;
  }, [draft, isEditing]);

  useLayoutEffect(() => {
    if (!isEditing || !editorRef.current) return;
    const editor = editorRef.current;
    const end = editor.value.length;
    editor.focus();
    editor.setSelectionRange(end, end);
  }, [isEditing]);

  const commitRename = () => {
    if (cancelledRef.current) return;
    setIsEditing(false);
    onRename(task.id, draft);
  };

  return (
    <article
      ref={setNodeRef}
      className={`task-card ${isDragging ? "dragging" : ""}`}
      style={style}
      aria-label={`Task: ${task.title}. Long press to move.`}
      onContextMenu={(event) => event.preventDefault()}
      {...listeners}
    >
      <button
        className="complete-button"
        aria-label="Archive task"
        onPointerDown={(event) => event.stopPropagation()}
        onClick={() => onComplete(task.id)}
      />
      <div className="task-content">
      {isEditing ? (
        <textarea
          ref={editorRef}
          className="task-title-input"
          autoFocus
          rows={1}
          value={draft}
          onChange={(event) => setDraft(event.target.value)}
          onPointerDown={(event) => event.stopPropagation()}
          onBlur={commitRename}
          onKeyDown={(event) => {
            if (event.key === "Enter") {
              event.preventDefault();
              commitRename();
            }
            if (event.key === "Escape") {
              cancelledRef.current = true;
              setIsEditing(false);
            }
          }}
        />
      ) : (
        <button
          className="task-title"
          onPointerDown={(event) => event.stopPropagation()}
          onClick={() => {
            cancelledRef.current = false;
            setDraft(task.title);
            setIsEditing(true);
          }}
        >
          {task.title}
        </button>
      )}
      <div className="task-metadata">
        {showsProject && source ? <span className="project-label" style={{ color: themeFor(source.themeID).accent }}>{isTodayBoard(source) ? "Personal" : source.title}</span> : null}
        {isEditingDeadline ? <div className="deadline-editor" onPointerDown={(event) => event.stopPropagation()}>
          <input type="date" aria-label={`Deadline for ${task.title}`} value={task.dueDate ?? ""}
            onChange={(event) => onDeadline(task.id, event.target.value || null)}
            onKeyDown={(event) => {
              if (event.key === "Enter" || event.key === "Escape") {
                event.preventDefault();
                setIsEditingDeadline(false);
              }
            }} />
          {task.dueDate ? <button type="button" onClick={() => onDeadline(task.id, null)}>Clear</button> : null}
          <button type="button" onClick={() => setIsEditingDeadline(false)}>Done</button>
        </div> : <button type="button" className={`deadline-button ${isOverdue(task.dueDate, day) ? "overdue" : task.dueDate === day ? "due-today" : ""}`}
          onPointerDown={(event) => event.stopPropagation()}
          onClick={() => setIsEditingDeadline(true)} aria-label={`Edit deadline for ${task.title}`}>
          <span aria-hidden="true">▦</span> {deadlineLabel(task.dueDate, day) ?? "Set deadline"}
        </button>}
      </div>
      </div>
      {source && !isTodayBoard(source) ? <button
        className={`today-button ${task.plannedFor === day ? "planned" : ""}`}
        aria-label={task.plannedFor === day ? "Remove from Today" : "Plan for Today"}
        aria-pressed={task.plannedFor === day}
        onPointerDown={(event) => event.stopPropagation()}
        onClick={() => onPlan(task.id)}
      >☀</button> : null}
    </article>
  );
});

function DragPreview({ task }: { task: TaskItem }) {
  return (
    <div className="drag-preview">
      <span className="drag-preview-check" aria-hidden="true" />
      <span className="drag-preview-title">{task.title}</span>
    </div>
  );
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
  const [apiKey, setApiKey] = useState(existing?.apiKey ?? "");
  const [authDomain, setAuthDomain] = useState(existing?.authDomain ?? "");
  const [databaseURL, setDatabaseURL] = useState(existing?.databaseURL ?? "");
  const [projectId, setProjectId] = useState(existing?.projectId ?? "");
  const [appId, setAppId] = useState(existing?.appId ?? "");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [message, setMessage] = useState(detail);
  const [busy, setBusy] = useState(false);

  const connect = async (createAccount: boolean) => {
    const config: FirebaseConfig = {
      apiKey: apiKey.trim(),
      authDomain: authDomain.trim(),
      databaseURL: databaseURL.trim(),
      projectId: projectId.trim(),
      appId: appId.trim(),
    };
    if (!Object.values(config).every(Boolean) || !email || !password) {
      setMessage("Fill in all Firebase and account fields.");
      return;
    }
    setBusy(true);
    try {
      const client = makeClient(config);
      await authenticateFirebase(client, email, password, createAccount);
      saveConfig(config);
      setMessage("Connected.");
      onConnected();
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
        <div className="sheet-heading"><div><span>SYNC</span><h2>Connect Firebase</h2></div><button onClick={onClose}>×</button></div>
        <p>The Firebase web configuration is public client configuration. Your task data is protected by your Firebase login and database rules.</p>
        <label>Web API key<input value={apiKey} onChange={(event) => setApiKey(event.target.value)} type="password" /></label>
        <label>Auth domain<input value={authDomain} onChange={(event) => setAuthDomain(event.target.value)} placeholder="project.firebaseapp.com" /></label>
        <label>Realtime Database URL<input value={databaseURL} onChange={(event) => setDatabaseURL(event.target.value)} placeholder="https://project-default-rtdb…firebasedatabase.app" /></label>
        <label>Project ID<input value={projectId} onChange={(event) => setProjectId(event.target.value)} /></label>
        <label>App ID<input value={appId} onChange={(event) => setAppId(event.target.value)} /></label>
        <div className="credentials">
          <label>Email<input value={email} onChange={(event) => setEmail(event.target.value)} type="email" /></label>
          <label>Password<input value={password} onChange={(event) => setPassword(event.target.value)} type="password" /></label>
        </div>
        {message ? <div className="connection-message">{message}</div> : null}
        <div className="sheet-actions">
          <button className="primary-button" disabled={busy} onClick={() => void connect(false)}>Sign in</button>
          <button className="secondary-button" disabled={busy} onClick={() => void connect(true)}>Create account</button>
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
