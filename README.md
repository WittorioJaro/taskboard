# taskboard

`taskboard` is a native SwiftUI task manager on macOS with an installable iPhone web app. It gives you lightweight boards, a menu bar companion and global quick capture on Mac, a touch-first PWA on iPhone, and realtime synchronization through Supabase.

The app is intentionally local-first: your boards live on your Mac, the UI feels native, and there are no accounts, sync services, or backend dependencies to set up.

## Highlights

- Multiple boards with offline-first local storage and Supabase sync
- Installable iPhone PWA with quick capture and touch drag-and-drop lanes
- Fast inline task creation and completion
- One-click copy actions for moving tasks into other tools
- Menu bar companion for browsing and acting on open tasks
- Global quick-capture popup with a customizable keyboard shortcut
- Per-board repository folders
- Sequential Codex queues with branch, model, and reasoning controls
- One-click direct prompts to Codex on a repository's `main` checkout
- Native macOS interface built with SwiftUI and AppKit integrations

## Requirements

- macOS 15 or newer
- Xcode 16+ or a recent Swift 6.2 toolchain
- Node.js 20 or newer for PWA development
- A free Supabase project for cross-device sync

The package manifest targets macOS 15 in [`Package.swift`](./Package.swift).

## Running The App

### iPhone PWA

The PWA installs from Safari and does not require an Apple Developer account.

1. Create a free Supabase project.
2. Open its **SQL Editor** and run [`web/supabase/schema.sql`](./web/supabase/schema.sql).
3. From the `web` directory, install and test the app:

```bash
cd web
npm install
npm run dev
```

4. Deploy it to an HTTPS host. Vercel works with the included configuration:

```bash
cd web
npx vercel --prod
```

5. Open the deployed URL in Safari on iPhone, tap **Share**, choose **Add to Home Screen**, then open taskboard from its new icon.
6. Tap **Offline** in taskboard. Enter the Supabase project URL and public anon key from **Project Settings → API**, then create an account.

Supabase may require email confirmation before the first sign-in. Keep the anon key public; never enter the service-role key in the PWA.

### Connect the Mac app

1. Create or sign into the PWA account first.
2. In the Mac app, open **Settings → Sync**.
3. Enter the same Supabase URL, anon key, email, and password.
4. Click **Connect Supabase**, then restart taskboard once.

On the first connection, the Mac snapshot seeds an empty remote taskboard. The PWA receives subsequent changes through Supabase Realtime; the Mac checks for remote changes every four seconds. Both clients retain a local copy while offline.

### Legacy native iPhone target

The experimental `taskboard-ios.xcodeproj` remains in the repository, but CloudKit device builds require a paid Apple Developer membership. The PWA is the supported no-fee iPhone installation path.

### Xcode

1. Open [`Package.swift`](./Package.swift) in Xcode.
2. Select the `taskboard` scheme.
3. Build and run the app.

### Command Line

```bash
swift run taskboard
```

### Build An App Bundle

If you want something you can move into `Applications`, build the `.app` bundle:

```bash
./scripts/build-app.sh
```

If `Assets/taskboard-logo.png` exists, the build script also converts it into a proper macOS app icon and embeds it into the bundle.

That creates:

```text
dist/taskboard.app
```

Then install it with:

```bash
cp -R dist/taskboard.app /Applications/
```

## How It Works

`taskboard` has five main surfaces:

- Main window: browse boards, add tasks quickly, and complete or copy items inline
- Menu bar companion: check open work without switching to the main window
- Quick capture popup: add a task from anywhere using a global shortcut
- Codex queue: send ordered tasks as separate prompts in one persistent Codex thread
- iPhone PWA: capture, organize, rename, move, and complete synced tasks

Each board can point at its own local Git repository. Queue runs use a dedicated worktree on an existing or new branch. Direct sends skip the queue and branch creation, and require that board folder to be checked out on `main`.

Task data is stored locally as JSON on Mac and in browser storage in the PWA, so both apps start fast and work without network access. Supabase stores one authenticated snapshot per user and publishes realtime changes to the PWA.

## Storage And Privacy

Task data is cached locally on each device and synced through a row-level-security-protected Supabase record:

```text
~/Library/Application Support/taskboard/boards.json
```

Only the authenticated Supabase user can read or update their snapshot. The project URL and anon key are stored locally; the Mac refresh token is stored in Keychain. Without Supabase, both clients continue to work locally and report an offline state.

## Project Structure

```text
Sources/taskboard/
  TaskBoardApp.swift          App entry point and scene setup
  MainWindowView.swift        Main board UI
  MenuBarCompanionView.swift  Menu bar companion UI
  QuickCaptureSupport.swift   Global shortcut and quick capture flow
  SettingsView.swift          App preferences
  TaskBoardStore.swift        Observable store and persistence
  Models.swift                Task, board, and theme models
  CloudKitSyncService.swift   Private database sync and change subscriptions
  SupabaseSyncService.swift   Authenticated REST sync for the Mac app
web/
  src/                        React PWA, offline state, and realtime adapter
  supabase/schema.sql         Database table and row-level security
iOS/
  TaskBoardMobileApp.swift    Legacy native iPhone target
taskboard-ios.xcodeproj/      Legacy CloudKit Xcode project
```

## Development Notes

- State is managed in a local observable store.
- Persistence uses JSON in Application Support.
- The native Mac target has no external package dependencies.
- The PWA is built with React, dnd-kit, Vite, and Supabase JS.

## Contributing

Contributions, issues, and improvement ideas are welcome.

If you open a pull request, a short note about the change and any manual testing helps a lot.

## License

This project is licensed under the MIT License. You can use, copy, modify, publish, distribute, sublicense, and sell it, as long as the license notice is included.

See [`LICENSE`](./LICENSE) for the full text.
