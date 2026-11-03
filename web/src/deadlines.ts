import { dayKey } from "./types";

export function parseDeadline(value?: string | null): Date | null {
  if (!value || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return null;
  // Local noon avoids treating a date-only value as a UTC timestamp.
  const date = new Date(`${value}T12:00:00`);
  return Number.isFinite(date.getTime()) && date.getFullYear() > 0 && dayKey(date) === value ? date : null;
}

export function isOverdue(value: string | null | undefined, day = dayKey()): boolean {
  return parseDeadline(value) !== null && value! < day;
}

export function deadlineLabel(value: string | null | undefined, day = dayKey()): string | null {
  const date = parseDeadline(value);
  if (!date) return null;
  if (value === day) return "Due today";
  const tomorrow = parseDeadline(day);
  if (tomorrow) {
    tomorrow.setDate(tomorrow.getDate() + 1);
    if (value === dayKey(tomorrow)) return "Due tomorrow";
  }
  const formatted = date.toLocaleDateString(undefined, {
    day: "numeric", month: "short",
    ...(date.getFullYear() !== Number(day.slice(0, 4)) ? { year: "numeric" as const } : {}),
  });
  return `${isOverdue(value, day) ? "Overdue" : "Due"} · ${formatted}`;
}
