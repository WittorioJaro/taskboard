import AppKit
import SwiftUI

enum SceneID {
    static let mainWindow = "main-window"
    static let quickCaptureWindow = "quick-capture-window"
}

@main
struct TaskBoardApp: App {
    @NSApplicationDelegateAdaptor(TaskBoardApplicationDelegate.self) private var appDelegate
    @State private var store = TaskBoardStore()

    var body: some Scene {
        Window("taskboard", id: SceneID.mainWindow) {
            MainWindowView(store: store)
                .frame(minWidth: 980, minHeight: 680)
                .preferredColorScheme(.dark)
                .task {
                    QuickCaptureController.shared.configure(store: store)
                }
        }
        .defaultSize(width: 1180, height: 760)

        Window("Quick Capture", id: SceneID.quickCaptureWindow) {
            QuickCaptureWindowView(controller: QuickCaptureController.shared)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 460, height: 244)
        .windowResizability(.contentSize)

        MenuBarExtra("taskboard", systemImage: "checklist") {
            MenuBarCompanionView(store: store)
                .preferredColorScheme(.dark)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .preferredColorScheme(.dark)
        }
    }
}

final class TaskBoardApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        configureApplicationIcon()
        NSApp.setActivationPolicy(.regular)
        QuickCaptureController.shared.registerHotKey()
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        !QuickCaptureController.shared.suppressMainWindowReopen
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
