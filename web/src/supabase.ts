import { createClient, type RealtimeChannel, type SupabaseClient } from "@supabase/supabase-js";
import type { Snapshot } from "./types";

export type SupabaseConfig = { url: string; anonKey: string };
export type SyncState = "offline" | "connecting" | "synced" | "error";

const CONFIG_KEY = "taskboard.supabase.config.v1";

export function loadConfig(): SupabaseConfig | null {
  const envURL = import.meta.env.VITE_SUPABASE_URL as string | undefined;
  const envKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined;
  if (envURL && envKey) return { url: envURL, anonKey: envKey };
  try {
    const raw = localStorage.getItem(CONFIG_KEY);
    return raw ? (JSON.parse(raw) as SupabaseConfig) : null;
  } catch {
    return null;
  }
}

export function saveConfig(config: SupabaseConfig): void {
  localStorage.setItem(CONFIG_KEY, JSON.stringify(config));
}

export function clearConfig(): void {
  localStorage.removeItem(CONFIG_KEY);
}

export function makeClient(config: SupabaseConfig): SupabaseClient {
  return createClient(config.url.replace(/\/$/, ""), config.anonKey, {
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true },
  });
}

// Postgres jsonb does not preserve object key order, so plain JSON.stringify
// comparisons misidentify our own realtime echoes as remote changes.
export function stableStringify(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map((item) => stableStringify(item ?? null)).join(",")}]`;
  const record = value as Record<string, unknown>;
  const entries = Object.keys(record)
    .filter((key) => record[key] !== undefined)
    .sort()
    .map((key) => `${JSON.stringify(key)}:${stableStringify(record[key])}`);
  return `{${entries.join(",")}}`;
}

export class SnapshotSync {
  private channel: RealtimeChannel | null = null;
  private saveTimer: number | null = null;
  private retryTimer: number | null = null;
  private lastKnownJSON = "";
  private lastKnownVersion = 0;
  private queuedSnapshot: Snapshot | null = null;
  private isSaving = false;
  private hasLocalIntent = false;
  private stopped = false;

  constructor(
    private readonly client: SupabaseClient,
    private readonly ownerID: string,
    private readonly onRemote: (snapshot: Snapshot) => void,
    private readonly onState: (state: SyncState, detail?: string) => void,
  ) {}

  beginLocalMutation(): void {
    this.hasLocalIntent = true;
  }

  private get hasPendingLocalChanges(): boolean {
    return this.hasLocalIntent || this.queuedSnapshot !== null || this.isSaving || this.saveTimer !== null;
  }

  private static version(updatedAt: string | undefined): number {
    if (!updatedAt) return 0;
    const value = Date.parse(updatedAt);
    return Number.isFinite(value) ? value : 0;
  }

  async start(local: Snapshot): Promise<void> {
    this.onState("connecting");
    const { data, error } = await this.client
      .from("taskboard_snapshots")
      .select("payload,updated_at")
      .eq("owner_id", this.ownerID)
      .eq("id", "primary")
      .maybeSingle();
    if (error) throw error;

    if (data?.payload) {
      const remote = data.payload as Snapshot;
      this.lastKnownJSON = stableStringify(remote);
      this.lastKnownVersion = SnapshotSync.version(data.updated_at as string | undefined);
      this.onRemote(remote);
    } else {
      await this.save(local);
    }

    this.channel = this.client
      .channel(`taskboard:${this.ownerID}`)
      .on(
        "postgres_changes",
        {
          event: "*",
          schema: "public",
          table: "taskboard_snapshots",
          filter: `owner_id=eq.${this.ownerID}`,
        },
        (event) => {
          const row = event.new as { payload?: Snapshot; updated_at?: string };
          const payload = row.payload;
          if (!payload) return;
          const version = SnapshotSync.version(row.updated_at);
          if (version > 0 && version <= this.lastKnownVersion) return;
          const json = stableStringify(payload);
          if (json === this.lastKnownJSON) {
            this.lastKnownVersion = Math.max(this.lastKnownVersion, version);
            return;
          }
          // A local edit is queued or in flight. Mismatching events are older
          // server echoes and must never replace the optimistic local state.
          if (this.hasPendingLocalChanges) return;
          this.lastKnownJSON = json;
          this.lastKnownVersion = Math.max(this.lastKnownVersion, version);
          this.onRemote(payload);
        },
      )
      .subscribe((status) => {
        if (status === "SUBSCRIBED") this.onState("synced");
        if (status === "CHANNEL_ERROR" || status === "TIMED_OUT") this.onState("error", status);
      });
  }

  scheduleSave(snapshot: Snapshot): void {
    const json = stableStringify(snapshot);
    if (!this.hasLocalIntent && !this.isSaving && this.queuedSnapshot === null && json === this.lastKnownJSON) return;
    this.hasLocalIntent = true;
    this.queuedSnapshot = snapshot;
    if (this.saveTimer !== null) window.clearTimeout(this.saveTimer);
    if (this.retryTimer !== null) {
      window.clearTimeout(this.retryTimer);
      this.retryTimer = null;
    }
    this.saveTimer = window.setTimeout(() => {
      this.saveTimer = null;
      void this.flushSaveQueue();
    }, 350);
  }

  async save(snapshot: Snapshot): Promise<void> {
    this.beginLocalMutation();
    await this.persistSnapshot(snapshot);
    this.hasLocalIntent = false;
  }

  private async flushSaveQueue(): Promise<void> {
    if (this.stopped || this.isSaving || !this.queuedSnapshot) return;

    const snapshot = this.queuedSnapshot;
    this.queuedSnapshot = null;
    this.isSaving = true;
    let failed = false;
    try {
      await this.persistSnapshot(snapshot);
    } catch {
      failed = true;
      if (!this.queuedSnapshot) this.queuedSnapshot = snapshot;
    } finally {
      this.isSaving = false;
    }

    if (this.stopped) return;
    if (failed && this.queuedSnapshot) {
      this.retryTimer = window.setTimeout(() => {
        this.retryTimer = null;
        void this.flushSaveQueue();
      }, 2000);
      return;
    }
    if (this.queuedSnapshot) {
      // Serialize writes: the latest state always reaches the server after
      // any older request, regardless of network response timing.
      await this.flushSaveQueue();
      return;
    }
    this.hasLocalIntent = false;
  }

  private async persistSnapshot(snapshot: Snapshot): Promise<void> {
    const { data, error } = await this.client.from("taskboard_snapshots").upsert({
      owner_id: this.ownerID,
      id: "primary",
      payload: snapshot,
      updated_at: new Date().toISOString(),
    }).select("payload,updated_at").single();
    if (error) {
      this.onState("error", error.message);
      throw error;
    }
    const saved = (data?.payload as Snapshot | undefined) ?? snapshot;
    this.lastKnownJSON = stableStringify(saved);
    this.lastKnownVersion = Math.max(
      this.lastKnownVersion,
      SnapshotSync.version(data?.updated_at as string | undefined),
    );
    this.onState("synced");
  }

  stop(): void {
    this.stopped = true;
    if (this.saveTimer !== null) window.clearTimeout(this.saveTimer);
    if (this.retryTimer !== null) window.clearTimeout(this.retryTimer);
    if (this.channel) void this.client.removeChannel(this.channel);
  }
}
