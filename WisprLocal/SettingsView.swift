import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject private var audioInputController: AudioInputController
    @ObservedObject var hotkeyManager: HotkeyManager
    @ObservedObject var scratchpadStore: ScratchpadStore
    @ObservedObject var setupController: SetupController

    @State private var apiKeyInput: String = ""
    @State private var isReplacingAPIKey = false
    @State private var presentedSheet: SettingsSheet?

    @State private var hotkeyKind: Hotkey.Kind = .carbon
    @State private var lastCarbonHotkey: Hotkey = .defaultCarbon
    @State private var handsFreeHotkey: Hotkey = .handsFreeDefault

    var body: some View {
        ZStack {
            background

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    apiKeyCard
                    MicrophoneSettingsCard()
                    hotkeyCard
                    commandModeCard
                    ScratchpadSettingsCard(store: scratchpadStore)
                    dictationCard
                    usageCard
                    injectionCard
                }
                .padding(20)
            }
        }
        .onAppear {
            setupController.refreshStoredAPIKey()
            hotkeyKind = hotkeyManager.currentHotkey.kind
            if hotkeyManager.currentHotkey.kind == .carbon {
                lastCarbonHotkey = hotkeyManager.currentHotkey
            }
            handsFreeHotkey = appState.handsFreeHotkey
        }
        .onReceive(hotkeyManager.$currentHotkey) { newHotkey in
            hotkeyKind = newHotkey.kind
            if newHotkey.kind == .carbon {
                lastCarbonHotkey = newHotkey
            }
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .setup:
                SetupView(
                    controller: setupController,
                    hotkeyManager: hotkeyManager
                ) {
                    presentedSheet = nil
                }
                .frame(width: 920, height: 640)
                .environmentObject(appState)
                .environmentObject(audioInputController)
            }
        }
    }

    private var background: some View {
        LinearGradient(colors: [
            Color(nsColor: .windowBackgroundColor),
            Color(nsColor: .controlBackgroundColor).opacity(0.65)
        ], startPoint: .topLeading, endPoint: .bottomTrailing)
        .ignoresSafeArea()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("WisprLocal")
                .font(.system(size: 20, weight: .semibold))
            Text("Settings")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }

    private var apiKeyCard: some View {
        SettingsCard(title: "OpenAI API Key", subtitle: "Stored securely in Keychain.") {
            if setupController.isStoredAPIKeyValidated, !isReplacingAPIKey {
                HStack(spacing: 10) {
                    Label("Validated key stored in Keychain", systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Replace Key") {
                        isReplacingAPIKey = true
                    }
                    .buttonStyle(.bordered)
                    Button("Clear") { clearAPIKey() }
                        .buttonStyle(.bordered)
                }
            } else {
                SecureField("sk-...", text: $apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 10) {
                    Button(settingsAPIKeyActionTitle) {
                        saveAPIKey()
                    }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            (apiKeyInput.trimmedOrNil == nil && !setupController.hasStoredAPIKey)
                                || setupController.apiKeyState.isValidating
                        )
                    if setupController.hasStoredAPIKey {
                        Button("Cancel") {
                            apiKeyInput = ""
                            isReplacingAPIKey = false
                        }
                        .buttonStyle(.bordered)
                    }
                    Button("Clear") { clearAPIKey() }
                        .buttonStyle(.bordered)
                }
            }

            switch setupController.apiKeyState {
            case .idle:
                EmptyView()
            case .validating:
                Label("Checking access with OpenAI…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .valid:
                Label("Key validated and saved.", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Guided setup")
                        .font(.callout.weight(.medium))
                    Text("Review your key, permissions, shortcut, and language.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Run Setup…") {
                    setupController.beginReview()
                    presentedSheet = .setup
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("settings.setup.open")
            }
        }
    }

    private var hotkeyCard: some View {
        SettingsCard(title: "Shortcuts", subtitle: "Push-to-talk and hands-free dictation.") {
            Picker("Shortcut Type", selection: $hotkeyKind) {
                Text("Custom").tag(Hotkey.Kind.carbon)
                Text("Fn alone (experimental)").tag(Hotkey.Kind.fnAlone)
            }
            .pickerStyle(.segmented)
            .onChange(of: hotkeyKind) { newKind in
                switch newKind {
                case .fnAlone:
                    hotkeyManager.updateHotkey(.fnAlone)
                case .carbon:
                    hotkeyManager.updateHotkey(lastCarbonHotkey)
                }
            }

            if hotkeyKind == .carbon {
                HotkeyRecorder(hotkey: $lastCarbonHotkey) { newHotkey in
                    hotkeyManager.updateHotkey(newHotkey)
                }
            } else {
                Text("Fn alone requires Input Monitoring. If unsupported, the app will fall back to F6.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let warning = appState.hotkeyWarning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Toggle("Press and hold to talk", isOn: $appState.holdToTalk)
            Text("Hold to talk starts on key down and stops on key up. Double-tap the shortcut to keep recording hands-free.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Hands-free dictation")
                        .font(.callout.weight(.medium))
                    Text("Press Fn + Space, click the Flow Bar, or use this fallback shortcut.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HotkeyRecorder(
                    hotkey: $handsFreeHotkey,
                    allowsFnAlone: false
                ) { newHotkey in
                    hotkeyManager.updateHandsFreeHotkey(newHotkey)
                }
            }

            Text("Hands-free sessions show a one-minute warning and stop automatically after 20 minutes.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let warning = appState.handsFreeHotkeyWarning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var commandModeCard: some View {
        CommandModeSettingsCard()
    }

    private var dictationCard: some View {
        SettingsCard(title: "Dictation", subtitle: "Language and post-processing.") {
            Picker("Transcription language", selection: $appState.language) {
                Text("Auto-detect").tag("")
                ForEach(LanguageCatalog.options) { language in
                    Text(language.name).tag(language.code)
                }
            }
            .accessibilityIdentifier("settings.dictation.language")
            Toggle("Polish transcript", isOn: $appState.polishEnabled)
            Text("Polish uses an extra LLM call to clean up corrections and formatting, which may slightly increase API cost.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var injectionCard: some View {
        SettingsCard(title: "Output & recovery", subtitle: "How dictation is inserted and recovered.") {
            Picker("Method", selection: .constant(InjectionMethod.clipboardPaste)) {
                Text(InjectionMethod.clipboardPaste.displayName).tag(InjectionMethod.clipboardPaste)
            }
            .disabled(true)

            Text("WisprLocal temporarily uses the clipboard to paste, then restores common clipboard content when it still owns the pasteboard.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Toggle("Say “press enter” to submit", isOn: $appState.pressEnterEnabled)
            Text("When the phrase is at the end of a dictation, WisprLocal removes it and presses Return after inserting your text.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("This voice command is disabled automatically while using Command Mode.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            ShortcutDescriptionRow(
                title: "Paste last transcript",
                shortcut: "⌃⌘V"
            )
            ShortcutDescriptionRow(
                title: "Copy last transcript",
                shortcut: "⌃⌘C"
            )
            ShortcutDescriptionRow(
                title: "Cancel dictation",
                shortcut: "Esc"
            )

            if let warning = appState.recoveryHotkeyWarning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var usageCard: some View {
        SettingsCard(title: "Usage", subtitle: "Tokens from polish, Transform, and Command Mode calls.") {
            HStack {
                Text("Sent: \(appState.tokensSent)")
                Spacer()
                Text("Received: \(appState.tokensReceived)")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private func saveAPIKey() {
        Task {
            if await setupController.validateAndStoreAPIKey(apiKeyInput) {
                apiKeyInput = ""
                isReplacingAPIKey = false
            }
        }
    }

    private var settingsAPIKeyActionTitle: String {
        if setupController.apiKeyState.isValidating {
            return "Validating…"
        }
        if apiKeyInput.trimmedOrNil == nil, setupController.hasStoredAPIKey {
            return "Validate existing key"
        }
        return "Validate and save"
    }

    private func clearAPIKey() {
        if setupController.clearAPIKey() {
            apiKeyInput = ""
            isReplacingAPIKey = false
        }
    }
}

private enum SettingsSheet: String, Identifiable {
    case setup

    var id: String { rawValue }
}

struct CommandModeSettingsCard: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        SettingsCard(
            title: "Experimental",
            subtitle: "Speak an instruction to edit selected text or write at the cursor."
        ) {
            Toggle("Command Mode", isOn: $appState.commandModeEnabled)
                .accessibilityIdentifier("settings.commandMode.enabled")

            Text("Hold a Command Mode shortcut, speak your instruction, then release to run it. Press Escape before the edit commits to cancel.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            ShortcutDescriptionRow(
                title: "Command Mode",
                shortcut: "fn ⌃"
            )
            ShortcutDescriptionRow(
                title: "Without an Apple Fn key",
                shortcut: "⌘ ⌃ ⌥"
            )

            Text("Examples: select a paragraph and say “make this concise,” or place the cursor and say “write a friendly follow-up.” The “press enter” dictation command is always disabled in Command Mode.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let warning = appState.commandHotkeyWarning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let result = appState.lastCommandResult {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last command")
                        .font(.caption.weight(.semibold))
                    Text(result.instruction)
                        .font(.callout)
                        .lineLimit(1)
                    Text(result.generatedText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                .accessibilityIdentifier("settings.commandMode.lastResult")
            }
        }
    }
}

struct ShortcutDescriptionRow: View {
    let title: String
    let shortcut: String

    var body: some View {
        HStack {
            Text(title)
                .font(.callout)
            Spacer()
            Text(shortcut)
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Color(nsColor: .quaternaryLabelColor).opacity(0.18),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .accessibilityLabel(shortcut)
        }
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.85))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 1)
        )
    }
}
