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

export class SnapshotSync {
  private channel: RealtimeChannel | null = null;
  private saveTimer: number | null = null;
  private latestRemoteJSON = "";

  constructor(
    private readonly client: SupabaseClient,
    private readonly ownerID: string,
    private readonly onRemote: (snapshot: Snapshot) => void,
    private readonly onState: (state: SyncState, detail?: string) => void,
  ) {}

  async start(local: Snapshot): Promise<void> {
    this.onState("connecting");
    const { data, error } = await this.client
      .from("taskboard_snapshots")
      .select("payload")
      .eq("owner_id", this.ownerID)
      .eq("id", "primary")
      .maybeSingle();
    if (error) throw error;

    if (data?.payload) {
      const remote = data.payload as Snapshot;
      this.latestRemoteJSON = JSON.stringify(remote);
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
          const payload = (event.new as { payload?: Snapshot }).payload;
          if (!payload) return;
          const json = JSON.stringify(payload);
          if (json === this.latestRemoteJSON) return;
          this.latestRemoteJSON = json;
          this.onRemote(payload);
        },
      )
      .subscribe((status) => {
        if (status === "SUBSCRIBED") this.onState("synced");
        if (status === "CHANNEL_ERROR" || status === "TIMED_OUT") this.onState("error", status);
      });
  }

  scheduleSave(snapshot: Snapshot): void {
    if (this.saveTimer !== null) window.clearTimeout(this.saveTimer);
    this.saveTimer = window.setTimeout(() => void this.save(snapshot), 500);
  }

  async save(snapshot: Snapshot): Promise<void> {
    const json = JSON.stringify(snapshot);
    this.latestRemoteJSON = json;
    const { error } = await this.client.from("taskboard_snapshots").upsert({
      owner_id: this.ownerID,
      id: "primary",
      payload: snapshot,
      updated_at: new Date().toISOString(),
    });
    if (error) {
      this.onState("error", error.message);
      throw error;
    }
    this.onState("synced");
  }

  stop(): void {
    if (this.saveTimer !== null) window.clearTimeout(this.saveTimer);
    if (this.channel) void this.client.removeChannel(this.channel);
  }
}
