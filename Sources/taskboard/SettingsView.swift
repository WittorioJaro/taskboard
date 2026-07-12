import AppKit
import Carbon
import SwiftUI

struct SettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var quickCaptureController = QuickCaptureController.shared
    @AppStorage(AppearancePreferences.modeDefaultsKey)
    private var appearanceMode = AppearancePreferences.initialModeRawValue
    @AppStorage(WindowPreferences.openMainWindowInCurrentSpaceDefaultsKey)
    private var openMainWindowInCurrentSpace = WindowPreferences.openMainWindowInCurrentSpaceDefaultValue
    @AppStorage(QuickCapturePreferences.closeAfterSubmitDefaultsKey)
    private var quickCaptureCloseAfterSubmit = QuickCapturePreferences.closeAfterSubmitDefaultValue
    @AppStorage(QuickCaptureShortcut.keyCodeDefaultsKey) private var quickCaptureKeyCode = Int(QuickCaptureShortcut.defaultShortcut.keyCode)
    @AppStorage(QuickCaptureShortcut.modifiersDefaultsKey) private var quickCaptureModifiers = Int(QuickCaptureShortcut.defaultShortcut.carbonModifiers)
    @AppStorage(QuickCaptureShortcut.displayKeyDefaultsKey) private var quickCaptureDisplayKey = QuickCaptureShortcut.defaultShortcut.displayKey

    var body: some View {
        ZStack {
            settingsBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                Text("Settings")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Appearance")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Appearance", selection: $appearanceMode) {
                            ForEach(AppearancePreferences.Mode.allCases) { mode in
                                Text(mode.title).tag(mode.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)

                        Text("System follows your Mac's current appearance automatically.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .padding(18)
                    .background(settingsCardBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(settingsBorder, lineWidth: 1)
                    }
                }

                SupabaseSyncSettingsSection()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Window")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.48))
                        .textCase(.uppercase)

                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(isOn: $openMainWindowInCurrentSpace) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Open on current desktop")
                                    .font(.system(size: 15, weight: .medium, design: .rounded))
                                    .foregroundStyle(.primary)

                                Text("Clicking the Dock icon brings taskboard to the desktop you're using instead of switching Spaces.")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(Color.primary.opacity(0.46))
                            }
                        }
                        .toggleStyle(.switch)
                    }
                    .padding(18)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                            )
                    )
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Quick Capture")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.48))
                        .textCase(.uppercase)

                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("Shortcut")
                                .font(.system(size: 15, weight: .medium, design: .rounded))
                                .foregroundStyle(.primary)

                            Spacer()

                            ShortcutRecorderButton(
                                keyCode: $quickCaptureKeyCode,
                                modifiers: $quickCaptureModifiers,
                                displayKey: $quickCaptureDisplayKey
                            )
                        }

                        Toggle(isOn: $quickCaptureCloseAfterSubmit) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Close after submit")
                                    .font(.system(size: 15, weight: .medium, design: .rounded))
                                    .foregroundStyle(.primary)

                                Text("Escape, the close button, and pressing the shortcut again dismiss the popup.")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(Color.primary.opacity(0.46))
                            }
                        }
                        .toggleStyle(.switch)

                        Text(quickCaptureController.hotKeyStatus.message)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(quickCaptureController.hotKeyStatus.isSuccess ? Color.green.opacity(0.85) : Color.orange.opacity(0.88))
                    }
                    .padding(18)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                            )
                    )
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Codex")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.48))
                        .textCase(.uppercase)

                    VStack(alignment: .leading, spacing: 14) {
                        Text("Each board owns its own repository folder. Set or change it with the folder button in the board header.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.primary.opacity(0.56))

                        Text("Codex work runs in the background. Created threads remain available in Codex history without opening or focusing the Codex app.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.primary.opacity(0.46))
                    }
                    .padding(18)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                            )
                    )
                }

                }
                .padding(24)
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: 540, height: 720)
        .onChange(of: quickCaptureKeyCode) { _, _ in
            QuickCaptureController.shared.reloadShortcut()
        }
        .onChange(of: quickCaptureModifiers) { _, _ in
            QuickCaptureController.shared.reloadShortcut()
        }
        .onChange(of: quickCaptureDisplayKey) { _, _ in
            QuickCaptureController.shared.reloadShortcut()
        }
    }

    private var settingsBackground: Color {
        colorScheme == .light ? Color(hex: "FCFCFD") : Color(hex: "0B0E13")
    }

    private var settingsCardBackground: Color {
        colorScheme == .light ? Color(hex: "FFFFFF").opacity(0.72) : Color.primary.opacity(0.05)
    }

    private var settingsBorder: Color {
        colorScheme == .light ? Color.black.opacity(0.09) : Color.primary.opacity(0.08)
    }

}

private struct SupabaseSyncSettingsSection: View {
    @AppStorage(SupabasePreferences.urlKey) private var projectURL = ""
    @AppStorage(SupabasePreferences.anonKeyKey) private var anonKey = ""
    @AppStorage(SupabasePreferences.emailKey) private var email = ""
    @State private var password = ""
    @State private var statusMessage = SupabasePreferences.isConfigured
        ? "Connected. taskboard syncs every few seconds."
        : "Connect the same Supabase account used by the iPhone web app."
    @State private var isConnecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sync")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.primary.opacity(0.48))
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 12) {
                TextField("Supabase project URL", text: $projectURL)
                    .textFieldStyle(.roundedBorder)
                SecureField("Public anon key", text: $anonKey)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    TextField("Email", text: $email)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Button(isConnecting ? "Connecting…" : "Connect Supabase") {
                        connect()
                    }
                    .disabled(isConnecting || projectURL.isEmpty || anonKey.isEmpty || email.isEmpty || password.isEmpty)

                    if SupabasePreferences.isConfigured {
                        Button("Disconnect") {
                            SupabaseSyncService.disconnect()
                            statusMessage = "Disconnected. Restart taskboard to use local storage only."
                        }
                        .foregroundStyle(Color.red.opacity(0.82))
                    }
                }

                Text(statusMessage)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.primary.opacity(0.5))
            }
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
            )
        }
    }

    private func connect() {
        isConnecting = true
        statusMessage = "Signing in…"
        Task {
            do {
                try await SupabaseSyncService.signIn(
                    projectURL: projectURL,
                    anonKey: anonKey,
                    email: email,
                    password: password
                )
                password = ""
                statusMessage = "Connected. Restart taskboard once to start syncing."
            } catch {
                statusMessage = error.localizedDescription
            }
            isConnecting = false
        }
    }
}

private struct ShortcutRecorderButton: View {
    @Binding var keyCode: Int
    @Binding var modifiers: Int
    @Binding var displayKey: String

    @State private var isRecording = false
    @State private var eventMonitor: Any?

    private var currentShortcutDisplay: String {
        QuickCaptureShortcut(
            keyCode: UInt32(keyCode),
            carbonModifiers: UInt32(modifiers),
            displayKey: displayKey
        ).displayString
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggleRecording) {
                Text(isRecording ? "Press Keys..." : currentShortcutDisplay)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.84))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color.primary.opacity(isRecording ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            Button("Reset") {
                let shortcut = QuickCaptureShortcut.defaultShortcut
                keyCode = Int(shortcut.keyCode)
                modifiers = Int(shortcut.carbonModifiers)
                displayKey = shortcut.displayKey
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(Color.primary.opacity(0.56))
        }
        .onDisappear {
            stopRecording()
        }
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        stopRecording()
        isRecording = true

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
                return nil
            }

            let shortcut = QuickCaptureShortcut(
                keyCode: UInt32(event.keyCode),
                carbonModifiers: QuickCaptureShortcut.carbonModifiers(from: event.modifierFlags),
                displayKey: QuickCaptureShortcut.displayKey(for: event)
            )

            guard shortcut.hasModifier else {
                return nil
            }

            keyCode = Int(shortcut.keyCode)
            modifiers = Int(shortcut.carbonModifiers)
            displayKey = shortcut.displayKey
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        isRecording = false
    }
}
