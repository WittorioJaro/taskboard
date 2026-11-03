export type TaskStatus = "todo" | "running" | "done";

export type TaskItem = {
  id: string;
  title: string;
  createdAt: number;
  isCompleted: boolean;
  statusOverride?: TaskStatus | null;
  completedAt?: number | null;
  plannedFor?: string | null;
  todayOrder?: number | null;
  dueDate?: string | null;
  attachments: Array<{ id: string; fileName: string; path: string }>;
};

export type TaskBoard = {
  id: string;
  title: string;
  themeID: string;
  folderPath: string;
  t3ProjectID?: string | null;
  t3ProjectTitle?: string | null;
  createdAt: number;
  isExpanded: boolean;
  isPinned: boolean;
  tasks: TaskItem[];
};

export type Snapshot = {
  boards: TaskBoard[];
  selectedBoardID?: string | null;
};

export function normalizeSnapshot(snapshot: Snapshot): Snapshot {
  return {
    ...snapshot,
    boards: (snapshot.boards ?? []).map((board) => ({
      ...board,
      tasks: (board.tasks ?? []).map((task) => ({
        ...task,
        attachments: task.attachments ?? [],
      })),
    })),
  };
}

export type Theme = {
  id: string;
  start: string;
  end: string;
  accent: string;
};

export const themes: Theme[] = [
  { id: "cobalt", start: "#172554", end: "#1d4ed8", accent: "#60a5fa" },
  { id: "mint", start: "#052e2b", end: "#0f766e", accent: "#5eead4" },
  { id: "sunrise", start: "#431407", end: "#c2410c", accent: "#fdba74" },
  { id: "rose", start: "#4a0d22", end: "#be123c", accent: "#fda4af" },
  { id: "forest", start: "#0b1f17", end: "#166534", accent: "#86efac" },
  { id: "slate", start: "#111827", end: "#334155", accent: "#cbd5e1" },
];

export const themeFor = (id: string) => themes.find((theme) => theme.id === id) ?? themes[0];

export const appleReferenceSeconds = () => (Date.now() - Date.UTC(2001, 0, 1)) / 1000;

/** New IDs match Swift's uppercase UUID encoding, so Mac round-trips keep the same string. */
export const newID = () => crypto.randomUUID().toUpperCase();

export function makeEmptySnapshot(): Snapshot {
  const boardID = newID();
  return {
    selectedBoardID: boardID,
    boards: [
      {
        id: boardID,
        title: "Inbox",
        themeID: "cobalt",
        folderPath: "",
        createdAt: appleReferenceSeconds(),
        isExpanded: true,
        isPinned: false,
        tasks: [],
      },
    ],
  };
}

// Calendar dates use the device's local timezone, never UTC's date boundary.
export function dayKey(date = new Date()): string {
  return `${String(date.getFullYear()).padStart(4, "0")}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
}

export const isTodayBoard = (board: TaskBoard) => board.title.trim().toLowerCase() === "today";

export function displayBoard(snapshot: Snapshot, board: TaskBoard, day = dayKey()): TaskBoard {
  if (!isTodayBoard(board)) return board;
  return {
    ...board,
    tasks: snapshot.boards.flatMap((source) => source.tasks.filter((task) =>
      source.id === board.id || task.plannedFor === day,
    )).sort((left, right) =>
      (left.plannedFor === day ? left.todayOrder ?? Number.MAX_SAFE_INTEGER : Number.MAX_SAFE_INTEGER) -
      (right.plannedFor === day ? right.todayOrder ?? Number.MAX_SAFE_INTEGER : Number.MAX_SAFE_INTEGER)),
  };
}
