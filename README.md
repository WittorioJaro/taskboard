# taskboard

`taskboard` is a native macOS task manager built with SwiftUI. It gives you lightweight boards for organizing work, a menu bar companion for quick access, and a global quick-capture flow for getting ideas out of your head fast.

The app is intentionally local-first: your boards live on your Mac, the UI feels native, and there are no accounts, sync services, or backend dependencies to set up.

## Highlights

- Multiple boards with persistent local storage
- Fast inline task creation and completion
- One-click copy actions for moving tasks into other tools
- Menu bar companion for browsing and acting on open tasks
- Global quick-capture popup with a customizable keyboard shortcut
- Native macOS interface built with SwiftUI and AppKit integrations

## Requirements

- macOS 15 or newer
- Xcode 16+ or a recent Swift 6.2 toolchain

The package manifest targets macOS 15 in [`Package.swift`](./Package.swift).

## Running The App

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

`taskboard` is a small native app with three main surfaces:

- Main window: browse boards, add tasks quickly, and complete or copy items inline
- Menu bar companion: check open work without switching to the main window
- Quick capture popup: add a task from anywhere using a global shortcut

Task data is stored locally as JSON, so the app starts fast and works without network access.

## Storage And Privacy

All task data is stored locally on your machine:

```text
~/Library/Application Support/taskboard/boards.json
```

The app does not require an account and does not depend on a remote backend.

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
```

## Development Notes

- State is managed in a local observable store.
- Persistence uses JSON in Application Support.
- The project is intentionally lightweight and currently has no external dependencies.

## Contributing

Contributions, issues, and improvement ideas are welcome.

If you open a pull request, a short note about the change and any manual testing helps a lot.

## License

This project is licensed under the MIT License. You can use, copy, modify, publish, distribute, sublicense, and sell it, as long as the license notice is included.

See [`LICENSE`](./LICENSE) for the full text.
