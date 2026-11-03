import { getApps, initializeApp, type FirebaseApp } from "firebase/app";
import {
  browserLocalPersistence,
  createUserWithEmailAndPassword,
  getAuth,
  onAuthStateChanged,
  setPersistence,
  signInWithEmailAndPassword,
  type Auth,
  type User,
} from "firebase/auth";
import {
  getDatabase,
  onValue,
  ref,
  runTransaction,
  type Database,
  type Unsubscribe,
} from "firebase/database";
import { mergeCloudChanges, withoutUndefined } from "./snapshotMerge";
import { normalizeSnapshot, type Snapshot } from "./types";

export type FirebaseConfig = {
  apiKey: string;
  authDomain: string;
  databaseURL: string;
  projectId: string;
  appId: string;
};
export type SyncState = "offline" | "connecting" | "synced" | "error";
export type FirebaseClient = { app: FirebaseApp; auth: Auth; database: Database };

const CONFIG_KEY = "taskboard.firebase.config.v1";

export function loadConfig(): FirebaseConfig | null {
  const envConfig: FirebaseConfig = {
    apiKey: import.meta.env.VITE_FIREBASE_API_KEY ?? "",
    authDomain: import.meta.env.VITE_FIREBASE_AUTH_DOMAIN ?? "",
    databaseURL: import.meta.env.VITE_FIREBASE_DATABASE_URL ?? "",
    projectId: import.meta.env.VITE_FIREBASE_PROJECT_ID ?? "",
    appId: import.meta.env.VITE_FIREBASE_APP_ID ?? "",
  };
  if (Object.values(envConfig).every(Boolean)) return envConfig;
  try {
    const raw = localStorage.getItem(CONFIG_KEY);
    return raw ? (JSON.parse(raw) as FirebaseConfig) : null;
  } catch {
    return null;
  }
}

export function saveConfig(config: FirebaseConfig): void {
  localStorage.setItem(CONFIG_KEY, JSON.stringify(config));
}

export function clearConfig(): void {
  localStorage.removeItem(CONFIG_KEY);
}

export function makeClient(config: FirebaseConfig): FirebaseClient {
  const existing = getApps().find((app) => app.name === "taskboard");
  const app = existing ?? initializeApp(config, "taskboard");
  const auth = getAuth(app);
  return { app, auth, database: getDatabase(app) };
}

export function currentUser(auth: Auth): Promise<User | null> {
  if (auth.currentUser) return Promise.resolve(auth.currentUser);
  return new Promise((resolve) => {
    const unsubscribe = onAuthStateChanged(auth, (user) => {
      unsubscribe();
      resolve(user);
    });
  });
}

export async function authenticate(
  client: FirebaseClient,
  email: string,
  password: string,
  createAccount: boolean,
): Promise<User> {
  await setPersistence(client.auth, browserLocalPersistence);
  const credential = createAccount
    ? await createUserWithEmailAndPassword(client.auth, email, password)
    : await signInWithEmailAndPassword(client.auth, email, password);
  return credential.user;
}

// JSON object key order is not stable across cloud round-trips.
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

export function snapshotForSync(snapshot: Snapshot): Snapshot {
  return { ...snapshot, selectedBoardID: null };
}

type SnapshotEnvelope = { payload: Snapshot; updatedAt: number };
type SnapshotBackend = {
  listen: (
    onData: (envelope: SnapshotEnvelope | null) => void,
    onError: (error: Error) => void,
  ) => Unsubscribe;
  write: (envelope: SnapshotEnvelope, baseline: Snapshot | null) => Promise<SnapshotEnvelope | void>;
};

export type SnapshotSyncOptions = {
  /** Latest UI snapshot, read when the first cloud value arrives. */
  getLocal?: () => Snapshot;
  /** The last snapshot this device and the cloud agreed on, kept across reloads. */
  baseline?: Snapshot | null;
  onBaseline?: (snapshot: Snapshot) => void;
};

export class SnapshotSync {
  private unsubscribe: Unsubscribe | null = null;
  private saveTimer: number | null = null;
  private retryTimer: number | null = null;
  private lastSyncedSnapshot: Snapshot | null = null;
  private mutationVersion = 0;
  private lastKnownJSON = "";
  private lastKnownVersion = 0;
  private queuedSnapshot: Snapshot | null = null;
  private deferredRemote: SnapshotEnvelope | null = null;
  private isSaving = false;
  private hasLocalIntent = false;
  private started = false;
  private stopped = false;
  /** mutationVersion when the UI last handed us a snapshot. */
  private queuedVersion = 0;
  /**
   * Remote changes merged into the queue that the UI has not received yet:
   * `to` is the rebased queue, `from` the UI content it was rebased from.
   */
  private uiBehind: { from: Snapshot; to: Snapshot } | null = null;

  constructor(
    private readonly client: FirebaseClient,
    private readonly ownerID: string,
    private readonly onRemote: (snapshot: Snapshot) => void,
    private readonly onState: (state: SyncState, detail?: string) => void,
    private readonly injectedBackend?: SnapshotBackend,
    private readonly options: SnapshotSyncOptions = {},
  ) {}

  beginLocalMutation(): void {
    this.hasLocalIntent = true;
    this.mutationVersion += 1;
  }

  private get hasPendingLocalChanges(): boolean {
    return this.hasLocalIntent || this.queuedSnapshot !== null || this.isSaving || this.saveTimer !== null;
  }

  private get snapshotRef() {
    return ref(this.client.database, `taskboardSnapshots/${this.ownerID}`);
  }

  private get backend(): SnapshotBackend {
    return this.injectedBackend ?? {
      listen: (onData, onError) => onValue(
        this.snapshotRef,
        (data) => onData(data.val() as SnapshotEnvelope | null),
        onError,
      ),
      write: async (envelope, baseline) => {
        const result = await runTransaction(this.snapshotRef, (current: SnapshotEnvelope | null) => ({
          payload: current?.payload
            ? mergeCloudChanges(envelope.payload, normalizeSnapshot(current.payload), baseline)
            : withoutUndefined(envelope.payload),
          updatedAt: Math.max(Date.now(), (current?.updatedAt ?? 0) + 1),
        }), { applyLocally: false });
        return result.snapshot.val() as SnapshotEnvelope;
      },
    };
  }

  async start(local: Snapshot): Promise<void> {
    this.onState("connecting");
    let handledInitialValue = false;
    await new Promise<void>((resolve, reject) => {
      this.unsubscribe = this.backend.listen(
        (envelope) => {
          if (!handledInitialValue) {
            handledInitialValue = true;
            this.started = true;
            this.reconcileInitialValue(envelope, local).then(resolve, reject);
            return;
          }
          if (envelope?.payload) this.acceptRemote(envelope);
        },
        (error) => reject(error),
      );
    });
    this.onState("synced");
  }

  /**
   * iOS usually relaunches a Home Screen app from scratch, so the UI starts
   * from localStorage and the user can tap before the cloud value arrives.
   * Those edits, and any made offline in an earlier session, are merged into
   * the cloud value instead of being replaced by it.
   */
  private async reconcileInitialValue(envelope: SnapshotEnvelope | null, loaded: Snapshot): Promise<void> {
    const current = snapshotForSync(normalizeSnapshot(this.options.getLocal?.() ?? loaded));
    if (!envelope?.payload) {
      await this.save(current);
      return;
    }
    const reference = snapshotForSync(normalizeSnapshot(this.options.baseline ?? loaded));
    if (stableStringify(current) === stableStringify(reference)) {
      this.hasLocalIntent = this.queuedSnapshot !== null;
      this.acceptRemote(envelope);
      return;
    }
    const remote = snapshotForSync(normalizeSnapshot(envelope.payload));
    this.lastKnownVersion = envelope.updatedAt;
    this.lastKnownJSON = stableStringify(remote);
    this.setBaseline(reference);
    this.hasLocalIntent = true;
    this.queuedSnapshot = current;
    await this.flushSaveQueue();
  }

  scheduleSave(snapshot: Snapshot): void {
    if (!this.started) return; // The initial reconciliation reads the latest UI snapshot.
    let syncedSnapshot = snapshotForSync(snapshot);
    if (this.uiBehind) {
      // Keep remote changes the queue already merged even if this UI snapshot predates them.
      const incoming = stableStringify(syncedSnapshot);
      syncedSnapshot = mergeCloudChanges(syncedSnapshot, this.uiBehind.to, this.uiBehind.from);
      if (stableStringify(syncedSnapshot) === incoming) this.uiCaughtUp();
    }
    this.queuedVersion = this.mutationVersion;
    const json = stableStringify(syncedSnapshot);
    if (!this.hasLocalIntent && !this.isSaving && this.queuedSnapshot === null && json === this.lastKnownJSON) return;
    this.hasLocalIntent = true;
    this.queuedSnapshot = syncedSnapshot;
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
    this.finishLocalChanges();
  }

  private setBaseline(snapshot: Snapshot): void {
    this.lastSyncedSnapshot = snapshot;
    // While the UI lacks merged remote content, keep the stored baseline at the older
    // value: a relaunch would otherwise read that content's absence as a deletion.
    if (!this.uiBehind) this.options.onBaseline?.(snapshot);
  }

  private uiCaughtUp(): void {
    if (!this.uiBehind) return;
    this.uiBehind = null;
    if (this.lastSyncedSnapshot) this.options.onBaseline?.(this.lastSyncedSnapshot);
  }

  private acceptRemote(envelope: SnapshotEnvelope): void {
    const remote = snapshotForSync(normalizeSnapshot(envelope.payload));
    const json = stableStringify(remote);
    if (envelope.updatedAt <= this.lastKnownVersion || json === this.lastKnownJSON) return;
    if (this.hasPendingLocalChanges) {
      // Our transaction merges anything committed before it. Keep the newest
      // value so a write committed after ours is applied once we finish.
      if (!this.deferredRemote || envelope.updatedAt > this.deferredRemote.updatedAt) this.deferredRemote = envelope;
      return;
    }
    this.lastKnownVersion = envelope.updatedAt;
    this.lastKnownJSON = json;
    this.setBaseline(remote);
    this.onRemote(normalizeSnapshot(envelope.payload));
    this.uiCaughtUp(); // The UI now holds the full remote value.
  }

  private finishLocalChanges(): void {
    this.hasLocalIntent = false;
    const deferred = this.deferredRemote;
    this.deferredRemote = null;
    if (deferred && !this.hasPendingLocalChanges) this.acceptRemote(deferred);
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
      }, 2_000);
      return;
    }
    if (this.queuedSnapshot) {
      await this.flushSaveQueue();
      return;
    }
    this.finishLocalChanges();
  }

  private async persistSnapshot(snapshot: Snapshot): Promise<void> {
    const syncedSnapshot = snapshotForSync(snapshot);
    const version = this.mutationVersion;
    const envelope = { payload: syncedSnapshot, updatedAt: Date.now() };
    const saved = await this.backend.write(envelope, this.lastSyncedSnapshot) ?? envelope;
    // A replacement sync owns the UI and stored baseline after a stop.
    if (this.stopped) return;
    const acknowledged = snapshotForSync(normalizeSnapshot(saved.payload));
    if (this.queuedSnapshot) {
      const before = this.queuedSnapshot;
      const rebased = mergeCloudChanges(before, acknowledged, syncedSnapshot);
      this.queuedSnapshot = rebased;
      if (stableStringify(rebased) !== stableStringify(before)) {
        this.uiBehind = { from: this.uiBehind?.from ?? before, to: rebased };
      }
      this.setBaseline(acknowledged);
      // With no edit since the UI's last snapshot, the UI equals the queue: hand it the
      // merge now so later edits (and the stored copy) include the remote changes.
      if (this.uiBehind && this.queuedVersion === this.mutationVersion) {
        this.onRemote(rebased);
        this.uiCaughtUp();
      }
    } else if (version === this.mutationVersion) {
      this.setBaseline(acknowledged);
      // A queued write may already include a remote merge absent from the UI.
      // Apply the final acknowledgement even when this write needed no new merge.
      this.onRemote(acknowledged);
      this.uiCaughtUp();
    } else {
      // A UI edit started meanwhile; its snapshot will be merged with this result.
      if (stableStringify(acknowledged) !== stableStringify(syncedSnapshot)) {
        this.uiBehind = { from: this.uiBehind?.from ?? syncedSnapshot, to: acknowledged };
      }
      this.setBaseline(acknowledged);
    }
    this.lastKnownJSON = stableStringify(acknowledged);
    this.lastKnownVersion = Math.max(this.lastKnownVersion, saved.updatedAt);
    this.onState("synced");
  }

  stop(): void {
    this.stopped = true;
    if (this.saveTimer !== null) window.clearTimeout(this.saveTimer);
    if (this.retryTimer !== null) window.clearTimeout(this.retryTimer);
    this.unsubscribe?.();
    this.unsubscribe = null;
  }
}
