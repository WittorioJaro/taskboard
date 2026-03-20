import Carbon
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var quickCaptureController = QuickCaptureController.shared
    @AppStorage("boardColumnCount") private var boardColumnCount = 3
    @AppStorage(QuickCapturePreferences.closeAfterSubmitDefaultsKey)
    private var quickCaptureCloseAfterSubmit = QuickCapturePreferences.closeAfterSubmitDefaultValue
    @AppStorage(QuickCaptureShortcut.keyCodeDefaultsKey) private var quickCaptureKeyCode = Int(QuickCaptureShortcut.defaultShortcut.keyCode)
    @AppStorage(QuickCaptureShortcut.modifiersDefaultsKey) private var quickCaptureModifiers = Int(QuickCaptureShortcut.defaultShortcut.carbonModifiers)
    @AppStorage(QuickCaptureShortcut.displayKeyDefaultsKey) private var quickCaptureDisplayKey = QuickCaptureShortcut.defaultShortcut.displayKey

    var body: some View {
        ZStack {
            Color(hex: "0B0E13").ignoresSafeArea()

            VStack(alignment: .leading, spacing: 22) {
                Text("Settings")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Board Layout")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.48))
                        .textCase(.uppercase)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Horizontal lists")
                                .font(.system(size: 15, weight: .medium, design: .rounded))
                                .foregroundStyle(.white)

                            Spacer()

                            Text("\(boardColumnCount)")
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.72))
                        }

                        Stepper(value: $boardColumnCount, in: 1...5) {
                            EmptyView()
                        }
                        .labelsHidden()

                        Text("Choose how many boards appear side by side in the main window.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.46))
                    }
                    .padding(18)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Color.white.opacity(0.05))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            )
                    )
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Quick Capture")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.48))
                        .textCase(.uppercase)

                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("Shortcut")
                                .font(.system(size: 15, weight: .medium, design: .rounded))
                                .foregroundStyle(.white)

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
                                    .foregroundStyle(.white)

                                Text("Outside click and pressing the shortcut again always dismiss the popup.")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(Color.white.opacity(0.46))
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
                            .fill(Color.white.opacity(0.05))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            )
                    )
                }

                Spacer()
            }
            .padding(24)
        }
        .frame(width: 460, height: 430)
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
                    .foregroundStyle(.white.opacity(0.84))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color.white.opacity(isRecording ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
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
            .foregroundStyle(Color.white.opacity(0.56))
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
