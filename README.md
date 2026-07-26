# taskboard

A small, local-first task manager for macOS, with an optional installable iPhone web app.

taskboard is designed for fast capture and a quiet workflow: create boards, move tasks between Todo, Running, and Done, and send repository-backed work to Codex without leaving the app. The Mac app works entirely offline. Firebase sync is optional and only needed if you want the iPhone PWA and Mac app to share data.

## Features

- Native SwiftUI macOS app with light, dark, and system appearance
- Multiple boards with local JSON persistence
- Todo, Running, and Done lanes with drag and drop
- Menu bar companion for open tasks
- Global Quick Capture window with a configurable shortcut
- Per-board repository folders
- Codex queues with branch, model, and reasoning controls
- Direct prompts to Codex from a board's `main` checkout
- Optional Firebase Realtime Database sync with an installable iPhone PWA
- Offline storage on both Mac and iPhone

## Choose your setup

| What you want | What you need |
| --- | --- |
| Mac app only | macOS 15 and Swift 6.2/Xcode 16 or newer |
| Mac app + iPhone sync | The Mac requirements, Node.js 22, and a free Firebase project |
| PWA development only | Node.js 22 and a free Firebase project |

The Mac app has no third-party Swift package dependencies. An Apple Developer account is not required for local builds or for installing the PWA.

## Quick start: macOS

Clone the repository and run the app directly:

```bash
git clone https://github.com/WittorioJaro/taskboard.git
cd taskboard
swift run taskboard
```

You can also open [`Package.swift`](./Package.swift) in Xcode, select the `taskboard` scheme, and press Run.

### Build an app for Applications

On an Apple silicon Mac, run:

```bash
./scripts/build-app.sh
```

The script creates an ad-hoc signed app at `dist/taskboard.app`. Install or replace it with:

```bash
rm -rf /Applications/taskboard.app
ditto dist/taskboard.app /Applications/taskboard.app
open /Applications/taskboard.app
```

The included logo is converted to a macOS `.icns` file automatically. For distribution with your own Developer ID, provide a signing identity:

```bash
TASKBOARD_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  ./scripts/build-app.sh
```

The script signs the build but does not notarize it.

## Optional: iPhone PWA and sync

The PWA is the supported iPhone client. It runs in Safari, can be added to the Home Screen, and syncs through your own Firebase project.

### 1. Create the Firebase backend

1. Create a Firebase project on the free Spark plan. Do not attach a billing account.
2. In **Build → Authentication → Sign-in method**, enable **Email/Password**.
3. In **Build → Realtime Database**, create a database in locked mode.
4. Open the database **Rules** tab, paste [`web/firebase/database.rules.json`](./web/firebase/database.rules.json), and publish it.
5. In **Project settings → Your apps**, add a Web app and copy its Firebase configuration.

The rules allow an authenticated user to access only `taskboardSnapshots/{their uid}`. Firebase Web API keys are public client configuration; never provide an Admin SDK service-account key.

### 2. Run the PWA locally

```bash
cd web
npm install
npm run dev
```

Vite prints a local development URL. For on-device PWA testing, use an HTTPS deployment or HTTPS development tunnel; service workers and installation require a secure context.

Firebase configuration can be entered in the PWA's connection screen. For development or deployment, copy `web/.env.example` to `web/.env.local` and fill in:

```bash
VITE_FIREBASE_API_KEY="..."
VITE_FIREBASE_AUTH_DOMAIN="your-project.firebaseapp.com"
VITE_FIREBASE_DATABASE_URL="https://your-project-default-rtdb.europe-west1.firebasedatabase.app"
VITE_FIREBASE_PROJECT_ID="your-project"
VITE_FIREBASE_APP_ID="..."
```

These values will be present in the browser bundle. Security comes from Firebase Authentication and the included Realtime Database rules.

### 3. Deploy the PWA

The repository includes [`web/vercel.json`](./web/vercel.json), so Vercel can build the PWA without additional routing configuration:

```bash
cd web
npx vercel --prod
```

Alternatively, run `npm run build` and deploy the generated `web/dist` directory to any HTTPS static host with SPA fallback routing.

On iPhone, open the deployed URL in Safari, tap **Share**, choose **Add to Home Screen**, and launch taskboard from the new icon.

### 4. Connect both clients

1. Export a JSON backup from the PWA connection panel before changing providers.
2. In the Mac app, open **Settings → Sync**.
3. Enter the Realtime Database URL, Web API key, email, and password.
4. Select **Create Account**, then restart taskboard so its local snapshot seeds Firebase.
5. In the PWA, open the **Offline** connection panel, enter the Firebase web configuration, and sign in with the same account.

Both clients keep a local copy and remain usable while offline. When the Firebase account is empty, the first Mac connection seeds it with the Mac's current snapshot. Verify edits in both directions before disconnecting the legacy Supabase sync.

For the full migration and rollback sequence, see [`docs/firebase-migration.md`](./docs/firebase-migration.md).

## Codex integration

Assign a local Git repository folder to a board using the folder button in its header.

- **Queue runs** can split selected tasks across multiple focused Codex threads. The threads run in order and share one worktree on a new or existing branch.
- **Direct sends** send one task immediately, without creating a worktree or branch. The configured repository must currently be on `main`.

Codex integration expects the Codex desktop app or its bundled CLI to be installed locally. Task management itself does not depend on Codex.

## Data and privacy

Without sync, task data never needs to leave the Mac. The native app stores its board snapshot at:

```text
~/Library/Application Support/taskboard/boards.json
```

The PWA caches data in browser storage. When Firebase sync is enabled, each authenticated user can access only their own snapshot through the Realtime Database rules. The Mac stores its refresh token in Keychain; project configuration remains local to each client.

Before experimenting with sync or schema changes, exporting a PWA JSON backup is recommended.

## Development

### Mac app

```bash
swift test
swift run taskboard
```

Four live Codex integration tests are skipped by default. Run them only when you intentionally want the test suite to invoke a locally installed Codex environment:

```bash
TASKBOARD_RUN_CODEX_INTEGRATION_TESTS=1 swift test
```

### Web app

```bash
cd web
npm install
npm run build
npm run test:sync
npm run preview
```

## Project structure

```text
Sources/taskboard/
  TaskBoardApp.swift          App entry point, windows, and appearance
  MainWindowView.swift        Main board interface and drag and drop
  MenuBarCompanionView.swift  Menu bar interface
  QuickCaptureSupport.swift   Global shortcut and Quick Capture window
  SettingsView.swift          Appearance, sync, and app preferences
  TaskBoardStore.swift        State, task operations, and persistence
  Models.swift                Board, task, attachment, and theme models
  CodexIntegration.swift      Codex threads, queues, and worktrees
  FirebaseSyncService.swift   Preferred Mac authentication and snapshot sync
  SupabaseSyncService.swift   Legacy rollback sync
web/
  src/                        React PWA and realtime sync client
  public/                     Manifest, icons, and service worker
  firebase/database.rules.json Database security rules
scripts/
  build-app.sh                Release app bundle and signing script
iOS/                          Experimental legacy native iPhone source
taskboard-ios.xcodeproj/      Experimental legacy CloudKit project
```

The legacy native iPhone target remains for experimentation, but device builds using CloudKit require Apple signing. The PWA is the recommended no-fee iPhone installation path.

## Troubleshooting

### The Mac app will not open

The locally built bundle is ad-hoc signed rather than notarized. If macOS blocks it, Control-click the app, choose **Open**, and confirm once.

### The PWA stays offline

- Confirm that all five Web app configuration fields belong to the same Firebase project.
- Confirm that Email/Password authentication is enabled.
- Confirm that [`web/firebase/database.rules.json`](./web/firebase/database.rules.json) is published.
- Do not use an Admin SDK service-account key.

### Realtime changes do not arrive

Confirm that the Realtime Database URL is exact, including its region, and that the database rules are published.

## Contributing

Issues and pull requests are welcome. For changes, please include:

- A concise explanation of the behavior being changed
- The platforms you tested
- `swift test` results for Mac changes
- `npm run build` and `npm run test:sync` results for PWA changes
- Screenshots or a short recording for visible UI changes

Please keep credentials, local task data, build products, and signing identities out of commits.

## License

taskboard is available under the [MIT License](./LICENSE).
