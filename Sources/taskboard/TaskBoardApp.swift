import AppKit
import SwiftUI

enum SceneID {
    static let mainWindow = "main-window"
    static let quickCaptureWindow = "quick-capture-window"
}

enum WindowPreferences {
    static let openMainWindowInCurrentSpaceDefaultsKey = "openMainWindowInCurrentSpace"
    static let openMainWindowInCurrentSpaceDefaultValue = true

    static var opensMainWindowInCurrentSpace: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: openMainWindowInCurrentSpaceDefaultsKey) != nil else {
            return openMainWindowInCurrentSpaceDefaultValue
        }
        return defaults.bool(forKey: openMainWindowInCurrentSpaceDefaultsKey)
    }
}

enum AppearancePreferences {
    enum Mode: String, CaseIterable, Identifiable {
        case system
        case light
        case dark

        var id: Self { self }
        var title: String { rawValue.capitalized }

        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    static let modeDefaultsKey = "appearanceMode"
    static let lightModeDefaultsKey = "lightModeEnabled"

    static var initialModeRawValue: String {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: modeDefaultsKey), Mode(rawValue: stored) != nil {
            return stored
        }
        return defaults.bool(forKey: lightModeDefaultsKey) ? Mode.light.rawValue : Mode.dark.rawValue
    }
}

@MainActor
enum MainWindowSpaceBehavior {
    static func apply(to window: NSWindow, enabled: Bool = WindowPreferences.opensMainWindowInCurrentSpace) {
        var behavior = window.collectionBehavior
        behavior.remove(.canJoinAllSpaces)

        if enabled {
            behavior.insert(.moveToActiveSpace)
        } else {
            behavior.remove(.moveToActiveSpace)
        }

        window.collectionBehavior = behavior
    }

    static func mainWindow(in application: NSApplication = NSApp) -> NSWindow? {
        application.windows.first(where: { $0.identifier?.rawValue == SceneID.mainWindow })
    }

    static func bringToCurrentSpace(_ window: NSWindow, in application: NSApplication = NSApp) {
        apply(to: window, enabled: true)

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }

        window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
    }
}

@main
struct TaskBoardApp: App {
    @NSApplicationDelegateAdaptor(TaskBoardApplicationDelegate.self) private var appDelegate
    @State private var store = TaskBoardStore()
    @AppStorage(AppearancePreferences.modeDefaultsKey)
    private var appearanceMode = AppearancePreferences.initialModeRawValue

    private var preferredColorScheme: ColorScheme? {
        AppearancePreferences.Mode(rawValue: appearanceMode)?.colorScheme
    }

    var body: some Scene {
        Window("taskboard", id: SceneID.mainWindow) {
            MainWindowView(store: store)
                .frame(minWidth: 360, minHeight: 520)
                .preferredColorScheme(preferredColorScheme)
                .task {
                    QuickCaptureController.shared.configure(store: store)
                }
        }
        .defaultSize(width: 390, height: 700)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)

        Window("Quick Capture", id: SceneID.quickCaptureWindow) {
            QuickCaptureWindowView(controller: QuickCaptureController.shared)
                .preferredColorScheme(preferredColorScheme)
        }
        .defaultSize(width: 500, height: 282)
        .windowResizability(.contentSize)

        MenuBarExtra("taskboard", systemImage: "checklist") {
            MenuBarCompanionView(store: store)
                .preferredColorScheme(preferredColorScheme)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .preferredColorScheme(preferredColorScheme)
        }
    }
}

final class TaskBoardApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        configureApplicationIcon()
        NSApp.setActivationPolicy(.regular)
        QuickCaptureController.shared.registerHotKey()
        NSApp.registerForRemoteNotifications()
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func application(
        _ application: NSApplication,
        didReceiveRemoteNotification userInfo: [String: Any]
    ) {
        NotificationCenter.default.post(name: .cloudKitDataDidChange, object: nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !QuickCaptureController.shared.suppressMainWindowReopen else {
            return false
        }

        guard WindowPreferences.opensMainWindowInCurrentSpace,
              let mainWindow = MainWindowSpaceBehavior.mainWindow(in: sender) else {
            return true
        }

        MainWindowSpaceBehavior.bringToCurrentSpace(mainWindow, in: sender)
        return false
    }

    @MainActor
    private func configureApplicationIcon() {
        guard let iconURL = Bundle.main.url(forResource: "taskboard", withExtension: "icns"),
              let iconImage = NSImage(contentsOf: iconURL) else {
            return
        }

        NSApp.applicationIconImage = iconImage
    }
}
