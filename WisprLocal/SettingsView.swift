import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var hotkeyManager: HotkeyManager

    @State private var apiKeyInput: String = ""
    @State private var apiKeyStored: Bool = false
    @State private var apiKeyStatus: String?

    @State private var hotkeyKind: Hotkey.Kind = .carbon
    @State private var lastCarbonHotkey: Hotkey = .defaultCarbon

    var body: some View {
        ZStack {
            background

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    apiKeyCard
                    hotkeyCard
                    dictationCard
                    usageCard
                    injectionCard
                    historyCard
                }
                .padding(20)
            }
        }
        .onAppear {
            refreshAPIKeyState()
            hotkeyKind = hotkeyManager.currentHotkey.kind
            if hotkeyManager.currentHotkey.kind == .carbon {
                lastCarbonHotkey = hotkeyManager.currentHotkey
            }
        }
        .onReceive(hotkeyManager.$currentHotkey) { newHotkey in
            hotkeyKind = newHotkey.kind
            if newHotkey.kind == .carbon {
                lastCarbonHotkey = newHotkey
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
            if apiKeyStored {
                HStack(spacing: 10) {
                    Text("Key stored in Keychain.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Replace Key") {
                        apiKeyStored = false
                        apiKeyStatus = nil
                    }
                    .buttonStyle(.bordered)
                    Button("Clear") { clearAPIKey() }
                        .buttonStyle(.bordered)
                }
            } else {
                SecureField("sk-...", text: $apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 10) {
                    Button("Save") { saveAPIKey() }
                        .buttonStyle(.borderedProminent)
                    Button("Clear") { clearAPIKey() }
                        .buttonStyle(.bordered)
                }
            }
            if let apiKeyStatus {
                Text(apiKeyStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var hotkeyCard: some View {
        SettingsCard(title: "Hotkey", subtitle: "Global toggle for dictation.") {
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
            Text("Hold to talk starts recording on key down and stops on key up. Fn-alone does not support hold mode.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var dictationCard: some View {
        SettingsCard(title: "Dictation", subtitle: "Language and post-processing.") {
            TextField("Language (optional, e.g. en)", text: $appState.language)
                .textFieldStyle(.roundedBorder)
            Toggle("Polish transcript", isOn: $appState.polishEnabled)
            Text("Polish uses an extra LLM call to clean up corrections and formatting, which may slightly increase API cost.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var injectionCard: some View {
        SettingsCard(title: "Injection", subtitle: "How text is inserted.") {
            Picker("Method", selection: .constant(InjectionMethod.clipboardPaste)) {
                Text(InjectionMethod.clipboardPaste.displayName).tag(InjectionMethod.clipboardPaste)
            }
            .disabled(true)
        }
    }

    private var historyCard: some View {
        SettingsCard(title: "History", subtitle: "Last 10 dictations.") {
            if appState.history.isEmpty {
                Text("No dictations yet.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(appState.history.prefix(10)) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.text)
                                .font(.callout)
                                .lineLimit(2)
                            Text(item.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Divider()
                    }
                }
            }
        }
    }

    private var usageCard: some View {
        SettingsCard(title: "Usage", subtitle: "Tokens from polish calls.") {
            HStack {
                Text("Sent: \(appState.tokensSent)")
                Spacer()
                Text("Received: \(appState.tokensReceived)")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private func refreshAPIKeyState() {
        do {
            let key = try KeychainService.shared.loadAPIKey()
            apiKeyStored = (key?.isEmpty == false)
            apiKeyStatus = nil
        } catch {
            apiKeyStored = false
            apiKeyStatus = error.localizedDescription
        }
    }

    private func saveAPIKey() {
        guard !apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            apiKeyStatus = "Enter a key before saving."
            return
        }
        do {
            try KeychainService.shared.saveAPIKey(apiKeyInput)
            apiKeyInput = ""
            apiKeyStored = true
            apiKeyStatus = "Saved."
        } catch {
            apiKeyStatus = error.localizedDescription
        }
    }

    private func clearAPIKey() {
        do {
            try KeychainService.shared.deleteAPIKey()
            apiKeyStored = false
            apiKeyStatus = "Cleared."
        } catch {
            apiKeyStatus = error.localizedDescription
        }
    }
}

private struct SettingsCard<Content: View>: View {
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
