import AppKit
import SwiftUI

struct AppRootView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var setupController: SetupController
    @ObservedObject var hotkeyManager: HotkeyManager
    @ObservedObject var historyController: HistoryController
    @ObservedObject var transformController: TransformController
    @ObservedObject var scratchpadController: ScratchpadController
    @ObservedObject var navigation: HubNavigationModel

    var body: some View {
        Group {
            if setupController.isCompleted {
                HubView(
                    hotkeyManager: hotkeyManager,
                    historyController: historyController,
                    transformController: transformController,
                    scratchpadController: scratchpadController,
                    setupController: setupController,
                    navigation: navigation
                )
                .transition(.opacity)
            } else {
                SetupView(
                    controller: setupController,
                    hotkeyManager: hotkeyManager
                ) {
                    navigation.selection = .home
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.24), value: setupController.isCompleted)
        .environmentObject(appState)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            setupController.refreshReadiness()
        }
    }
}

struct SetupView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var audioInputController: AudioInputController
    @ObservedObject var controller: SetupController
    let onFinished: () -> Void

    private let initialHotkey: Hotkey
    private let updateHotkey: (Hotkey) -> Hotkey

    @State private var apiKeyInput = ""
    @State private var hotkeyKind: Hotkey.Kind = .carbon
    @State private var lastCarbonHotkey: Hotkey = .defaultCarbon
    @State private var selectedLanguageCode: String?
    @State private var languageSearchText = ""
    @State private var didInitializeLanguage = false
    @FocusState private var isAPIKeyFocused: Bool

    init(
        controller: SetupController,
        hotkeyManager: HotkeyManager,
        onFinished: @escaping () -> Void
    ) {
        self.controller = controller
        initialHotkey = hotkeyManager.currentHotkey
        updateHotkey = { [weak hotkeyManager] requestedHotkey in
            hotkeyManager?.updateHotkey(requestedHotkey)
            return hotkeyManager?.currentHotkey ?? requestedHotkey
        }
        self.onFinished = onFinished
    }

    init(
        controller: SetupController,
        currentHotkey: Hotkey,
        updateHotkey: @escaping (Hotkey) -> Hotkey,
        onFinished: @escaping () -> Void
    ) {
        self.controller = controller
        initialHotkey = currentHotkey
        self.updateHotkey = updateHotkey
        self.onFinished = onFinished
    }

    var body: some View {
        HStack(spacing: 0) {
            progressSidebar
                .frame(width: 252)

            ZStack {
                LinearGradient(
                    colors: [
                        Color(nsColor: .windowBackgroundColor),
                        Color(red: 0.96, green: 0.94, blue: 1).opacity(0.72)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    ScrollView {
                        stepContent
                            .frame(maxWidth: 640, alignment: .leading)
                            .padding(.horizontal, 56)
                            .padding(.top, controller.currentStep == .permissions ? 32 : 48)
                            .padding(.bottom, 24)
                    }

                    Divider()
                    footer
                        .padding(.horizontal, 56)
                        .padding(.vertical, 20)
                }
            }
        }
        .frame(minWidth: 820, minHeight: 580)
        .tint(Color(red: 0.48, green: 0.29, blue: 0.96))
        .onAppear {
            controller.refreshStoredAPIKey()
            controller.refreshPermissions()
            synchronizeHotkey(initialHotkey)
            focusAPIKeyIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refreshReadiness()
        }
        .onChange(of: controller.currentStep) { _ in
            focusAPIKeyIfNeeded()
        }
        .accessibilityIdentifier("setup.view")
    }

    private var progressSidebar: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.16, green: 0.10, blue: 0.31),
                    Color(red: 0.28, green: 0.16, blue: 0.52)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 11) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.white.opacity(0.14))
                        Image(systemName: "waveform")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 36, height: 36)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("WisprLocal")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("Set up dictation")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.62))
                    }
                }
                .padding(.bottom, 42)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(SetupStep.allCases) { step in
                        progressRow(step)
                    }
                }

                Spacer()

                Label("Your key stays in macOS Keychain", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
        }
    }

    private func progressRow(_ step: SetupStep) -> some View {
        let isCurrent = step == controller.currentStep
        let isPast = step.progressIndex < controller.currentStep.progressIndex

        return HStack(spacing: 11) {
            ZStack {
                Circle()
                    .fill(isCurrent ? Color.white : Color.white.opacity(isPast ? 0.20 : 0.08))
                if isPast {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: step.systemImage)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isCurrent ? Color(red: 0.36, green: 0.20, blue: 0.72) : .white.opacity(0.56))
                }
            }
            .frame(width: 25, height: 25)

            Text(step.title)
                .font(.callout.weight(isCurrent ? .semibold : .regular))
                .foregroundStyle(.white.opacity(isCurrent ? 1 : isPast ? 0.72 : 0.46))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            isCurrent ? Color.white.opacity(0.10) : Color.clear,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
    }

    @ViewBuilder
    private var stepContent: some View {
        switch controller.currentStep {
        case .welcome:
            welcomeStep
        case .apiKey:
            apiKeyStep
        case .permissions:
            permissionsStep
        case .shortcut:
            shortcutStep
        case .language:
            LanguageSetupStep(
                selectedCode: $selectedLanguageCode,
                searchText: $languageSearchText
            )
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 24) {
            setupHeroIcon("waveform.and.mic", colors: [
                Color(red: 0.43, green: 0.24, blue: 0.96),
                Color(red: 0.74, green: 0.39, blue: 0.94)
            ])

            VStack(alignment: .leading, spacing: 10) {
                Text("Write everywhere with your voice")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                Text("WisprLocal turns speech into polished text in any Mac app. You bring your own OpenAI API key, so usage and billing stay under your control.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 14) {
                setupBenefit(
                    "Fast, accurate dictation",
                    detail: "Transcribe and polish speech without a separate Wispr subscription.",
                    icon: "bolt.fill"
                )
                setupBenefit(
                    "Works across macOS",
                    detail: "Use one global shortcut in Mail, Messages, browsers, editors, and more.",
                    icon: "macwindow.on.rectangle"
                )
                setupBenefit(
                    "Private credential storage",
                    detail: "Your API key is stored in Keychain and sent only to OpenAI.",
                    icon: "lock.fill"
                )
            }
            .padding(.top, 6)
        }
    }

    private var apiKeyStep: some View {
        VStack(alignment: .leading, spacing: 24) {
            stepHeading(
                eyebrow: "Your account",
                title: "Connect OpenAI",
                subtitle: "WisprLocal uses your key for transcription and optional polishing. Validation checks access without creating billable model output."
            )

            VStack(alignment: .leading, spacing: 14) {
                Text("OpenAI API key")
                    .font(.headline)

                SecureField("Paste your secret key", text: $apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .focused($isAPIKeyFocused)
                    .onSubmit { validateAPIKey() }
                    .accessibilityIdentifier("setup.api-key.input")

                HStack {
                    Label("Stored only in macOS Keychain", systemImage: "lock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Link(
                        "Create or manage keys",
                        destination: URL(string: "https://platform.openai.com/api-keys")!
                    )
                    .font(.caption.weight(.medium))
                }

                apiKeyFeedback
            }
            .padding(20)
            .background(setupCardBackground)

            if controller.isStoredAPIKeyValidated {
                Label(
                    "A validated key is already stored. Enter a new one only if you want to replace it.",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.callout)
                .foregroundStyle(.green)
            } else if controller.hasStoredAPIKey {
                Label(
                    "A legacy key is stored in Keychain. Validate it once to continue.",
                    systemImage: "exclamationmark.shield.fill"
                )
                .font(.callout)
                .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var apiKeyFeedback: some View {
        switch controller.apiKeyState {
        case .idle:
            EmptyView()
        case .validating:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking access with OpenAI…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("setup.api-key.validating")
        case .valid:
            Label("Key validated and saved.", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .accessibilityIdentifier("setup.api-key.valid")
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("setup.api-key.error")
        }
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 24) {
            stepHeading(
                eyebrow: "System access",
                title: "Allow WisprLocal to work everywhere",
                subtitle: "Microphone access captures your voice. Accessibility lets WisprLocal paste the finished text into the app you’re using."
            )

            VStack(spacing: 12) {
                permissionRow(
                    title: "Microphone",
                    detail: microphoneDetail,
                    icon: "mic.fill",
                    isGranted: controller.microphoneStatus.isAuthorized,
                    buttonTitle: microphoneButtonTitle,
                    action: handleMicrophoneAction
                )

                permissionRow(
                    title: "Accessibility",
                    detail: controller.isAccessibilityGranted
                        ? "Ready to insert text into other apps."
                        : "Required to paste completed dictation at your cursor.",
                    icon: "accessibility",
                    isGranted: controller.isAccessibilityGranted,
                    buttonTitle: controller.isAccessibilityGranted
                        ? "Allowed"
                        : controller.hasRequestedAccessibility ? "Open Settings" : "Enable",
                    action: handleAccessibilityAction
                )
            }

            if controller.microphoneStatus.isAuthorized {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Test your microphone")
                        .font(.headline)
                    Text("Speak normally and confirm the bars move. You can also choose a different input.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    MicrophoneInputPanel()
                }
                .padding(18)
                .background(setupCardBackground)
                .accessibilityIdentifier("setup.microphone.test")
            }

            if !controller.isPermissionStepComplete {
                Label(
                    "After changing a permission in System Settings, return here and WisprLocal will refresh automatically.",
                    systemImage: "arrow.clockwise"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var shortcutStep: some View {
        VStack(alignment: .leading, spacing: 24) {
            stepHeading(
                eyebrow: "Write anywhere",
                title: "Choose your dictation shortcut",
                subtitle: "Use push-to-talk for quick thoughts or switch into hands-free recording when you want to keep speaking."
            )

            VStack(alignment: .leading, spacing: 18) {
                Picker("Shortcut type", selection: $hotkeyKind) {
                    Text("Fn key").tag(Hotkey.Kind.fnAlone)
                    Text("Custom").tag(Hotkey.Kind.carbon)
                }
                .pickerStyle(.segmented)
                .onChange(of: hotkeyKind) { kind in
                    switch kind {
                    case .fnAlone:
                        synchronizeHotkey(updateHotkey(.fnAlone))
                    case .carbon:
                        synchronizeHotkey(updateHotkey(lastCarbonHotkey))
                    }
                }

                HStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.purple.opacity(0.10))
                        Image(systemName: "keyboard")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(.purple)
                    }
                    .frame(width: 58, height: 58)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(hotkeyKind == .fnAlone ? "Press Fn to dictate" : "Your custom shortcut")
                            .font(.headline)
                        if hotkeyKind == .carbon {
                            HotkeyRecorder(hotkey: $lastCarbonHotkey) { hotkey in
                                synchronizeHotkey(updateHotkey(hotkey))
                            }
                        } else {
                            Text(appState.holdToTalk
                                 ? "Hold Fn to talk. Double-tap it to keep recording."
                                 : "Tap Fn once to start and again to stop.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }

                if let warning = hotkeyWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                HStack(spacing: 12) {
                    Image(systemName: "waveform.badge.plus")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.purple)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Press Fn + Space for hands-free")
                            .font(.callout.weight(.semibold))
                        Text("Click Stop when you’re done. Sessions warn at 19 minutes and stop at 20 minutes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
            .background(setupCardBackground)
        }
    }

    private var hotkeyWarning: String? {
        appState.hotkeyWarning
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 12) {
            if controller.currentStep != .welcome {
                Button("Back") {
                    controller.goBack()
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            switch controller.currentStep {
            case .welcome:
                Button("Get started") {
                    controller.advanceFromWelcome()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("setup.welcome.continue")
            case .apiKey:
                Button(apiKeyContinueTitle) {
                    validateAPIKey()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(
                    controller.apiKeyState.isValidating
                        || (apiKeyInput.trimmedOrNil == nil && !controller.hasStoredAPIKey)
                )
                .accessibilityIdentifier("setup.api-key.continue")
            case .permissions:
                Button("Continue") {
                    _ = controller.advanceFromPermissions()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!controller.isPermissionStepComplete)
                .accessibilityIdentifier("setup.permissions.continue")
            case .shortcut:
                Button("Continue") {
                    controller.advanceFromShortcut()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("setup.shortcut.continue")
            case .language:
                Button("Finish setup") {
                    if controller.complete(languageCode: selectedLanguageCode) {
                        onFinished()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("setup.language.finish")
            }
        }
        .frame(minHeight: 38)
    }

    private func stepHeading(eyebrow: String, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(eyebrow.uppercased())
                .font(.caption.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(.purple)
            Text(title)
                .font(.system(size: 29, weight: .bold, design: .rounded))
            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func setupHeroIcon(_ symbol: String, colors: [Color]) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: colors[0].opacity(0.25), radius: 18, y: 8)
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 84, height: 84)
    }

    private func setupBenefit(_ title: String, detail: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.purple)
                .frame(width: 27, height: 27)
                .background(Color.purple.opacity(0.10), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func permissionRow(
        title: String,
        detail: String,
        icon: String,
        isGranted: Bool,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 15) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isGranted ? Color.green.opacity(0.12) : Color.purple.opacity(0.10))
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(isGranted ? .green : .purple)
            }
            .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(title)
                        .font(.headline)
                    if isGranted {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 14)

            Button(buttonTitle, action: action)
                .buttonStyle(.borderedProminent)
                .disabled(isGranted)
        }
        .padding(17)
        .background(setupCardBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup.permission.\(title.lowercased())")
    }

    private var setupCardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.88))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.26), lineWidth: 1)
            }
    }

    private var microphoneDetail: String {
        switch controller.microphoneStatus {
        case .notDetermined:
            return "macOS has not asked for microphone access yet."
        case .authorized:
            return "Ready to capture your voice."
        case .denied:
            return "Access was denied. Enable WisprLocal in Privacy & Security."
        case .restricted:
            return "Microphone access is restricted on this Mac."
        }
    }

    private var microphoneButtonTitle: String {
        switch controller.microphoneStatus {
        case .notDetermined:
            return "Allow"
        case .authorized:
            return "Allowed"
        case .denied, .restricted:
            return "Open Settings"
        }
    }

    private func handleMicrophoneAction() {
        switch controller.microphoneStatus {
        case .notDetermined:
            Task { await controller.requestMicrophoneAccess() }
        case .denied, .restricted:
            controller.openMicrophoneSettings()
        case .authorized:
            break
        }
    }

    private func handleAccessibilityAction() {
        if controller.hasRequestedAccessibility {
            controller.openAccessibilitySettings()
        } else {
            controller.promptForAccessibility()
        }
    }

    private func validateAPIKey() {
        if apiKeyInput.trimmedOrNil == nil, controller.isStoredAPIKeyValidated {
            _ = controller.advanceFromAPIKey()
            return
        }
        Task {
            if await controller.validateAndStoreAPIKey(apiKeyInput) {
                apiKeyInput = ""
            }
        }
    }

    private var apiKeyContinueTitle: String {
        if controller.apiKeyState.isValidating {
            return "Validating…"
        }
        if apiKeyInput.trimmedOrNil == nil, controller.isStoredAPIKeyValidated {
            return "Continue"
        }
        if apiKeyInput.trimmedOrNil == nil, controller.hasStoredAPIKey {
            return "Validate existing key"
        }
        return "Validate and continue"
    }

    private func synchronizeHotkey(_ hotkey: Hotkey) {
        hotkeyKind = hotkey.kind
        if hotkey.kind == .carbon {
            lastCarbonHotkey = hotkey
        }
    }

    private func focusAPIKeyIfNeeded() {
        if controller.currentStep == .language, !didInitializeLanguage {
            selectedLanguageCode = controller.suggestedLanguageCode
            didInitializeLanguage = true
        }
        guard controller.currentStep == .apiKey, !controller.hasStoredAPIKey else { return }
        DispatchQueue.main.async {
            isAPIKeyFocused = true
        }
    }
}

private struct LanguageSetupStep: View {
    @Binding var selectedCode: String?
    @Binding var searchText: String

    private var filteredLanguages: [LanguageOption] {
        LanguageCatalog.search(searchText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 9) {
                Text("TRANSCRIPTION")
                    .font(.caption.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(.purple)
                Text("What language do you speak?")
                    .font(.system(size: 29, weight: .bold, design: .rounded))
                Text("Choose one language for faster, more accurate transcription, or let OpenAI detect it automatically.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                selectedCode = nil
            } label: {
                HStack(spacing: 13) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.purple)
                        .frame(width: 38, height: 38)
                        .background(Color.purple.opacity(0.10), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-detect")
                            .font(.callout.weight(.semibold))
                        Text("Best if you switch languages often")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    selectionIndicator(isSelected: selectedCode == nil)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(14)
            .background(languageCard(isSelected: selectedCode == nil))
            .accessibilityIdentifier("setup.language.auto")

            TextField("Search languages", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("setup.language.search")

            if filteredLanguages.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "globe")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("No languages found")
                        .font(.headline)
                    Text("Try a language name or two-letter code.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 148), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(filteredLanguages) { language in
                        languageButton(language)
                    }
                }
            }

        }
    }

    private func languageButton(_ language: LanguageOption) -> some View {
        let isSelected = selectedCode == language.code
        return Button {
            selectedCode = language.code
        } label: {
            HStack(spacing: 9) {
                Text(language.name)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 2)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.purple)
                } else {
                    Text(language.code.uppercased())
                        .font(.caption2.monospaced().weight(.medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(languageCard(isSelected: isSelected))
        .accessibilityIdentifier("setup.language.\(language.code)")
    }

    private func languageCard(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(
                isSelected
                    ? Color.purple.opacity(0.10)
                    : Color(nsColor: .controlBackgroundColor).opacity(0.84)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        isSelected ? Color.purple.opacity(0.55) : Color(nsColor: .separatorColor).opacity(0.24),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            }
    }

    private func selectionIndicator(isSelected: Bool) -> some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(isSelected ? Color.purple : Color.secondary.opacity(0.5))
    }
}
