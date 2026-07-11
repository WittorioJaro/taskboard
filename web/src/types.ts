export type TaskStatus = "todo" | "running" | "done";

export type TaskItem = {
  id: string;
  title: string;
  createdAt: number;
  isCompleted: boolean;
  statusOverride?: TaskStatus | null;
  completedAt?: number | null;
  attachments: Array<{ id: string; fileName: string; path: string }>;
};

export type TaskBoard = {
  id: string;
  title: string;
  themeID: string;
  folderPath: string;
  createdAt: number;
  isExpanded: boolean;
  isPinned: boolean;
  tasks: TaskItem[];
};

export type Snapshot = {
  boards: TaskBoard[];
  selectedBoardID?: string | null;
};

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

export function makeEmptySnapshot(): Snapshot {
  const boardID = crypto.randomUUID();
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
