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
  set,
  type Database,
  type Unsubscribe,
} from "firebase/database";
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
  write: (envelope: SnapshotEnvelope) => Promise<void>;
};

export class SnapshotSync {
  private unsubscribe: Unsubscribe | null = null;
  private saveTimer: number | null = null;
  private retryTimer: number | null = null;
  private lastKnownJSON = "";
  private lastKnownVersion = 0;
  private queuedSnapshot: Snapshot | null = null;
  private isSaving = false;
  private hasLocalIntent = false;
  private stopped = false;

  constructor(
    private readonly client: FirebaseClient,
    private readonly ownerID: string,
    private readonly onRemote: (snapshot: Snapshot) => void,
    private readonly onState: (state: SyncState, detail?: string) => void,
    private readonly injectedBackend?: SnapshotBackend,
  ) {}

  beginLocalMutation(): void {
    this.hasLocalIntent = true;
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
      write: async (envelope) => {
        await set(this.snapshotRef, envelope);
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
            if (envelope?.payload) {
              this.acceptRemote(envelope);
              resolve();
            } else {
              void this.save(local).then(resolve, reject);
            }
            return;
          }
          if (envelope?.payload) this.acceptRemote(envelope);
        },
        (error) => reject(error),
      );
    });
    this.onState("synced");
  }

  scheduleSave(snapshot: Snapshot): void {
    const syncedSnapshot = snapshotForSync(snapshot);
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
    this.hasLocalIntent = false;
  }

  private acceptRemote(envelope: SnapshotEnvelope): void {
    const remote = snapshotForSync(normalizeSnapshot(envelope.payload));
    const json = stableStringify(remote);
    if (envelope.updatedAt <= this.lastKnownVersion || json === this.lastKnownJSON) return;
    this.lastKnownVersion = envelope.updatedAt;
    this.lastKnownJSON = json;
    if (!this.hasPendingLocalChanges) this.onRemote(normalizeSnapshot(envelope.payload));
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
    this.hasLocalIntent = false;
  }

  private async persistSnapshot(snapshot: Snapshot): Promise<void> {
    const syncedSnapshot = snapshotForSync(snapshot);
    const updatedAt = Date.now();
    await this.backend.write({ payload: syncedSnapshot, updatedAt });
    this.lastKnownJSON = stableStringify(syncedSnapshot);
    this.lastKnownVersion = Math.max(this.lastKnownVersion, updatedAt);
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
