import AppKit
import Carbon
import SwiftUI

struct QuickCaptureShortcut: Equatable {
    static let keyCodeDefaultsKey = "quickCaptureShortcutKeyCode"
    static let modifiersDefaultsKey = "quickCaptureShortcutModifiers"
    static let displayKeyDefaultsKey = "quickCaptureShortcutDisplayKey"

    let keyCode: UInt32
    let carbonModifiers: UInt32
    let displayKey: String

    static let defaultShortcut = QuickCaptureShortcut(
        keyCode: UInt32(kVK_Space),
        carbonModifiers: UInt32(controlKey | optionKey),
        displayKey: "Space"
    )

    static func fromDefaults(_ defaults: UserDefaults = .standard) -> QuickCaptureShortcut {
        let keyCode = defaults.object(forKey: keyCodeDefaultsKey) as? Int ?? Int(defaultShortcut.keyCode)
        let modifiers = defaults.object(forKey: modifiersDefaultsKey) as? Int ?? Int(defaultShortcut.carbonModifiers)
        let displayKey = defaults.string(forKey: displayKeyDefaultsKey) ?? defaultShortcut.displayKey

        return QuickCaptureShortcut(
            keyCode: UInt32(keyCode),
            carbonModifiers: UInt32(modifiers),
            displayKey: displayKey
        )
    }

    var displayString: String {
        let parts = modifierParts + [displayKey]
        return parts.joined(separator: " + ")
    }

    var hasModifier: Bool {
        carbonModifiers != 0
    }

    private var modifierParts: [String] {
        var parts: [String] = []
        if carbonModifiers & UInt32(controlKey) != 0 { parts.append("Control") }
        if carbonModifiers & UInt32(optionKey) != 0 { parts.append("Option") }
        if carbonModifiers & UInt32(shiftKey) != 0 { parts.append("Shift") }
        if carbonModifiers & UInt32(cmdKey) != 0 { parts.append("Command") }
        return parts
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }

    static func displayKey(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space:
            return "Space"
        case kVK_Return:
            return "Return"
        case kVK_Tab:
            return "Tab"
        case kVK_Delete:
            return "Delete"
        case kVK_ForwardDelete:
            return "Forward Delete"
        case kVK_Escape:
            return "Escape"
        case kVK_LeftArrow:
            return "Left"
        case kVK_RightArrow:
            return "Right"
        case kVK_UpArrow:
            return "Up"
        case kVK_DownArrow:
            return "Down"
        default:
            let raw = event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return raw.isEmpty ? "Key \(event.keyCode)" : raw.uppercased()
        }
    }
}

enum QuickCaptureHotKeyStatus {
    case registered
    case invalid(String)
    case unavailable(String)

    var message: String {
        switch self {
        case .registered:
            "Shortcut registered and ready."
        case .invalid(let message), .unavailable(let message):
            message
        }
    }

    var isSuccess: Bool {
        if case .registered = self {
            return true
        }
        return false
    }
}

enum QuickCapturePreferences {
    static let closeAfterSubmitDefaultsKey = "quickCaptureCloseAfterSubmit"
    static let closeAfterSubmitDefaultValue = true
}

@MainActor
final class QuickCaptureController: NSObject, ObservableObject {
    static let shared = QuickCaptureController()

    @Published var draftTitle = ""
    @Published var selectedBoardID: TaskBoard.ID?
    @Published private(set) var boardOptions: [TaskBoard] = []
    @Published var focusSeed = 0
    @Published private(set) var hotKeyStatus: QuickCaptureHotKeyStatus = .registered
    @Published var isCaptureWindowVisible = false
    @Published private(set) var isOpeningCaptureWindow = false

    private weak var store: TaskBoardStore?
    private weak var captureWindow: NSWindow?
    private let hotKeyManager = GlobalHotKeyManager()
    private var openCaptureWindow: (() -> Void)?
    private var openSettingsAction: (() -> Void)?

    private override init() {
        super.init()
        reloadShortcut()
        hotKeyManager.handler = { [weak self] in
            Task { @MainActor in
                self?.handleHotKey()
            }
        }

        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reloadShortcut()
            }
        }
    }

    func configure(store: TaskBoardStore) {
        self.store = store
        syncBoards()
    }

    func installWindowActions(
        openCaptureWindow: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) {
        self.openCaptureWindow = openCaptureWindow
        self.openSettingsAction = openSettings
    }

    func registerCaptureWindow(_ window: NSWindow) {
        captureWindow = window
    }

    func registerHotKey() {
        hotKeyStatus = hotKeyManager.register(shortcut: QuickCaptureShortcut.fromDefaults())
    }

    func reloadShortcut() {
        let shortcut = QuickCaptureShortcut.fromDefaults()
        hotKeyStatus = hotKeyManager.register(shortcut: shortcut)
    }

    func handleHotKey() {
        if isCaptureWindowVisible {
            closeCaptureWindow()
            return
        }

        showCaptureWindow()
    }

    func showCaptureWindow() {
        syncBoards()
        if selectedBoardID == nil {
            selectedBoardID = store?.selectedBoardID ?? boardOptions.first?.id
        }

        draftTitle = ""
        isOpeningCaptureWindow = true
        isCaptureWindowVisible = true

        if captureWindow == nil {
            openCaptureWindow?()
        }

        requestCaptureWindowFocus()
        focusSeed += 1
        NSApp.activate(ignoringOtherApps: true)
        scheduleCaptureWindowFocusRefresh()
    }

    func closeCaptureWindow() {
        isOpeningCaptureWindow = false
        isCaptureWindowVisible = false
        if let captureWindow {
            captureWindow.orderOut(nil)
        }
    }

    func quickCaptureWindowLostFocus() {
        isOpeningCaptureWindow = false
        if isCaptureWindowVisible {
            closeCaptureWindow()
        }
    }

    func quickCaptureWindowBecameKey() {
        isOpeningCaptureWindow = false
        if isCaptureWindowVisible {
            focusSeed += 1
        }
    }

    func applicationDidBecomeActive() {
        guard isCaptureWindowVisible else {
            return
        }

        requestCaptureWindowFocus()
        focusSeed += 1
    }

    var suppressMainWindowReopen: Bool {
        isOpeningCaptureWindow || isCaptureWindowVisible
    }

    func openSettings() {
        openSettingsAction?()
    }

    func submitTask() {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            focusSeed += 1
            return
        }

        guard let store, let boardID = selectedBoardID ?? boardOptions.first?.id else {
            return
        }

        store.selectedBoardID = boardID
        store.addTask(to: boardID, title: trimmed)
        draftTitle = ""
        syncBoards()

        if closesAfterSubmit {
            closeCaptureWindow()
        } else {
            focusSeed += 1
        }
    }

    func cycleBoardSelection(reverse: Bool = false) {
        guard !boardOptions.isEmpty else {
            return
        }

        guard let selectedBoardID,
              let currentIndex = boardOptions.firstIndex(where: { $0.id == selectedBoardID }) else {
            self.selectedBoardID = boardOptions.first?.id
            focusSeed += 1
            return
        }

        let offset = reverse ? -1 : 1
        let nextIndex = (currentIndex + offset + boardOptions.count) % boardOptions.count
        self.selectedBoardID = boardOptions[nextIndex].id
        focusSeed += 1
    }

    private func syncBoards() {
        guard let store else {
            boardOptions = []
            return
        }

        boardOptions = store.boards
        if selectedBoardID == nil || boardOptions.contains(where: { $0.id == selectedBoardID }) == false {
            selectedBoardID = store.selectedBoardID ?? boardOptions.first?.id
        }
    }

    private func requestCaptureWindowFocus() {
        guard let captureWindow else {
            return
        }

        captureWindow.orderFrontRegardless()
        captureWindow.makeMain()
        captureWindow.makeKeyAndOrderFront(nil)
    }

    private func scheduleCaptureWindowFocusRefresh() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            guard isCaptureWindowVisible else {
                return
            }

            requestCaptureWindowFocus()
            focusSeed += 1

            try? await Task.sleep(for: .milliseconds(160))
            guard isCaptureWindowVisible else {
                return
            }

            requestCaptureWindowFocus()
            focusSeed += 1
        }
    }

    private var closesAfterSubmit: Bool {
        UserDefaults.standard.object(forKey: QuickCapturePreferences.closeAfterSubmitDefaultsKey) as? Bool
            ?? QuickCapturePreferences.closeAfterSubmitDefaultValue
    }
}

struct QuickCaptureWindowView: View {
    @ObservedObject var controller: QuickCaptureController
    @FocusState private var isTaskFieldFocused: Bool

    private var isSubmitDisabled: Bool {
        controller.draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var selectedBoardTitle: String {
        controller.boardOptions.first(where: { $0.id == controller.selectedBoardID })?.title ?? "Choose board"
    }

    var body: some View {
        ZStack {
            Color(hex: "0B0E13").ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Quick Capture")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)

                        Text("Drop a task into the right board and keep moving.")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.46))
                    }

                    Spacer()

                    Button {
                        controller.closeCaptureWindow()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.58))
                            .frame(width: 28, height: 28)
                            .background(Color.white.opacity(0.05), in: Circle())
                    }
                    .buttonStyle(.plain)
                }

                VStack(alignment: .leading, spacing: 12) {
                    TextField("Add a task", text: $controller.draftTitle, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                        .focused($isTaskFieldFocused)
                        .defaultFocus($isTaskFieldFocused, true)
                        .lineLimit(1...6)
                        .onKeyPress(.tab, phases: [.down, .repeat]) { keyPress in
                            controller.cycleBoardSelection(reverse: keyPress.modifiers.contains(.shift))
                            return .handled
                        }
                        .taskSubmitBehavior(onSubmit: controller.submitTask)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                        .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)

                    HStack(alignment: .bottom, spacing: 10) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Board")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.42))

                            Menu {
                                ForEach(controller.boardOptions) { board in
                                    Button(board.title) {
                                        controller.selectedBoardID = board.id
                                    }
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    Text(selectedBoardTitle)
                                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)

                                    Spacer(minLength: 10)

                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(Color.white.opacity(0.5))
                                }
                                .padding(.horizontal, 14)
                                .frame(height: 46)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Button(action: controller.submitTask) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.black)
                                .frame(width: 46, height: 46)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(isSubmitDisabled)
                        .opacity(isSubmitDisabled ? 0.45 : 1)
                    }
                }
            }
            .padding(18)
        }
        .frame(width: 460, height: 244)
        .background(QuickCaptureWindowObserver())
        .task {
            controller.isCaptureWindowVisible = true
            requestFocus()
        }
        .onDisappear {
            controller.isCaptureWindowVisible = false
        }
        .onChange(of: controller.focusSeed) { _, _ in
            requestFocus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.applicationDidBecomeActive()
            requestFocus(delay: .milliseconds(30))
        }
    }

    private func requestFocus(delay: Duration = .milliseconds(80)) {
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            isTaskFieldFocused = true
        }
    }
}

private struct QuickCaptureWindowObserver: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                QuickCaptureController.shared.registerCaptureWindow(window)
                window.delegate = context.coordinator
                window.level = .floating
                // AppKit rejects combining canJoinAllSpaces with moveToActiveSpace.
                // For the shortcut popup, follow the active Space and stay available over fullscreen apps.
                window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
                window.standardWindowButton(.closeButton)?.isHidden = true
                window.standardWindowButton(.zoomButton)?.isHidden = true
                window.standardWindowButton(.miniaturizeButton)?.isHidden = true
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.isMovableByWindowBackground = true
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                QuickCaptureController.shared.registerCaptureWindow(window)
                window.delegate = context.coordinator
                window.isMovableByWindowBackground = true
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        func windowDidBecomeKey(_ notification: Notification) {
            Task { @MainActor in
                QuickCaptureController.shared.quickCaptureWindowBecameKey()
            }
        }

        func windowDidResignKey(_ notification: Notification) {
            Task { @MainActor in
                QuickCaptureController.shared.quickCaptureWindowLostFocus()
            }
        }
    }
}

private final class GlobalHotKeyManager {
    var handler: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let hotKeySignature: OSType = 0x54424B31

    func register(shortcut: QuickCaptureShortcut) -> QuickCaptureHotKeyStatus {
        guard shortcut.hasModifier else {
            return .invalid("Add at least one modifier key to the shortcut.")
        }

        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        if eventHandler == nil {
            let installStatus = InstallEventHandler(
                GetApplicationEventTarget(),
                { _, eventRef, userData in
                    guard let eventRef, let userData else {
                        return noErr
                    }

                    var hotKeyID = EventHotKeyID()
                    GetEventParameter(
                        eventRef,
                        EventParamName(kEventParamDirectObject),
                        EventParamType(typeEventHotKeyID),
                        nil,
                        MemoryLayout<EventHotKeyID>.size,
                        nil,
                        &hotKeyID
                    )

                    let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                    if hotKeyID.signature == manager.hotKeySignature {
                        manager.handler?()
                    }

                    return noErr
                },
                1,
                &eventSpec,
                UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
                &eventHandler
            )

            guard installStatus == noErr else {
                return .unavailable("The app could not install its hotkey handler. OSStatus \(installStatus).")
            }
        }

        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: 1)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr else {
            return .unavailable(Self.message(for: status))
        }

        return .registered
    }

    private static func message(for status: OSStatus) -> String {
        switch status {
        case OSStatus(eventHotKeyExistsErr):
            return "That shortcut is already in use by another app or system command."
        case OSStatus(paramErr):
            return "That shortcut is not valid. Try a key with modifiers like Control or Option."
        default:
            return "The shortcut could not be registered. OSStatus \(status)."
        }
    }
}
