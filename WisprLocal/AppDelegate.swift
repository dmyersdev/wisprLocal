import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = AppController.shared
    private var statusItem: NSStatusItem!
    private var stateCancellable: AnyCancellable?
    private var lastTranscriptCancellable: AnyCancellable?
    private var transformSettingsCancellable: AnyCancellable?
    private var transformResultCancellable: AnyCancellable?
    private var transformStateCancellable: AnyCancellable?
    private var commandStateCancellable: AnyCancellable?
    private var scratchpadStateCancellable: AnyCancellable?
    private var dictationModeCancellable: AnyCancellable?
    private var hudController: HUDWindowController?
    private var transformStatusController: TransformStatusWindowController?
    private var commandStatusController: CommandStatusWindowController?

    private var toggleItem: NSMenuItem?
    private var stateItem: NSMenuItem?
    private var cancelItem: NSMenuItem?
    private var pasteLastItem: NSMenuItem?
    private var copyLastItem: NSMenuItem?
    private var transformSubmenu: NSMenu?
    private var microphoneSubmenu: NSMenu?
    private var latestTransformItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        hudController = HUDWindowController(appState: controller.appState,
                                            dictationController: controller.dictationController)
        transformStatusController = TransformStatusWindowController(
            appState: controller.appState,
            transformController: controller.transformController
        )
        commandStatusController = CommandStatusWindowController(
            appState: controller.appState,
            commandModeController: controller.commandModeController
        )
        stateCancellable = controller.appState.$state.sink { [weak self] state in
            self?.updateStatus(state: state)
        }
        dictationModeCancellable = controller.appState.$activeDictationMode.sink { [weak self] _ in
            guard let self else { return }
            self.updateStatus(state: self.controller.appState.state)
        }
        lastTranscriptCancellable = controller.appState.$lastTranscript.sink { [weak self] transcript in
            self?.updateRecoveryItems(hasTranscript: !transcript.isEmpty)
        }
        transformSettingsCancellable = controller.appState.$transformSettings.sink { [weak self] settings in
            self?.rebuildTransformMenu(settings: settings)
        }
        transformResultCancellable = controller.appState.$lastTransformResult.sink { [weak self] result in
            self?.latestTransformItem?.isEnabled = result != nil
        }
        transformStateCancellable = controller.transformController.$state.sink { [weak self] _ in
            self?.updateCancelItem()
        }
        commandStateCancellable = controller.commandModeController.$state.sink { [weak self] _ in
            self?.updateCancelItem()
        }
        scratchpadStateCancellable = controller.scratchpadController.$state.sink { [weak self] _ in
            self?.updateCancelItem()
        }
        updateStatus(state: controller.appState.state)
        updateRecoveryItems(hasTranscript: !controller.appState.lastTranscript.isEmpty)
        rebuildTransformMenu(settings: controller.appState.transformSettings)
        if !controller.setupController.isCompleted {
            controller.settingsWindowController.show(destination: .home)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.scratchpadController.store.flushAutosave()
        controller.appState.flushHistoryPersistence()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        controller.audioInputController.refreshDevices()
        let wasReady = controller.setupController.isReady
        let isReady = controller.setupController.refreshReadiness()
        if wasReady, !isReady {
            controller.setupController.requestPresentation()
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = statusBarImage()
        }

        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Start Hands-Free Dictation", action: #selector(toggleDictation), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        toggleItem = toggle

        let state = NSMenuItem(title: "State: Idle", action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        stateItem = state

        let cancel = NSMenuItem(
            title: "Cancel Dictation",
            action: #selector(cancelDictation),
            keyEquivalent: ""
        )
        cancel.target = self
        menu.addItem(cancel)
        cancelItem = cancel

        menu.addItem(.separator())

        let pasteLast = NSMenuItem(
            title: "Paste Last Transcript",
            action: #selector(pasteLastTranscript),
            keyEquivalent: "v"
        )
        pasteLast.keyEquivalentModifierMask = [.command, .control]
        pasteLast.target = self
        menu.addItem(pasteLast)
        pasteLastItem = pasteLast

        let copyLast = NSMenuItem(
            title: "Copy Last Transcript",
            action: #selector(copyLastTranscript),
            keyEquivalent: "c"
        )
        copyLast.keyEquivalentModifierMask = [.command, .control]
        copyLast.target = self
        menu.addItem(copyLast)
        copyLastItem = copyLast

        menu.addItem(.separator())

        let microphone = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        let microphoneMenu = NSMenu(title: "Microphone")
        microphoneMenu.delegate = self
        microphone.submenu = microphoneMenu
        menu.addItem(microphone)
        microphoneSubmenu = microphoneMenu
        rebuildMicrophoneMenu()

        menu.addItem(.separator())

        let transformSelected = NSMenuItem(
            title: "Transform Selected Text",
            action: nil,
            keyEquivalent: ""
        )
        let transformMenu = NSMenu(title: "Transform Selected Text")
        transformSelected.submenu = transformMenu
        menu.addItem(transformSelected)
        transformSubmenu = transformMenu

        let latestTransform = NSMenuItem(
            title: "View Latest Transform",
            action: #selector(showLatestTransform),
            keyEquivalent: ""
        )
        latestTransform.target = self
        latestTransform.isEnabled = false
        menu.addItem(latestTransform)
        latestTransformItem = latestTransform

        menu.addItem(.separator())

        let openHub = NSMenuItem(title: "Open WisprLocal", action: #selector(openHub), keyEquivalent: "0")
        openHub.target = self
        menu.addItem(openHub)

        let dictionary = NSMenuItem(title: "Dictionary", action: #selector(openDictionary), keyEquivalent: "")
        dictionary.target = self
        menu.addItem(dictionary)

        let snippets = NSMenuItem(title: "Snippets", action: #selector(openSnippets), keyEquivalent: "")
        snippets.target = self
        menu.addItem(snippets)

        let styles = NSMenuItem(title: "Styles", action: #selector(openStyles), keyEquivalent: "")
        styles.target = self
        menu.addItem(styles)

        let transforms = NSMenuItem(title: "Transforms", action: #selector(openTransforms), keyEquivalent: "")
        transforms.target = self
        menu.addItem(transforms)

        let scratchpad = NSMenuItem(title: "Scratchpad", action: #selector(openScratchpad), keyEquivalent: "")
        scratchpad.target = self
        menu.addItem(scratchpad)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit WisprLocal", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === microphoneSubmenu else { return }
        controller.audioInputController.refreshDevices()
        rebuildMicrophoneMenu()
    }

    private func rebuildMicrophoneMenu() {
        guard let menu = microphoneSubmenu else { return }
        let audioInput = controller.audioInputController
        menu.removeAllItems()

        let automatic = NSMenuItem(
            title: audioInput.selectedDeviceUID == nil
                ? "Automatic (\(audioInput.effectiveDevice?.name ?? "No input"))"
                : "Automatic",
            action: #selector(selectMicrophone(_:)),
            keyEquivalent: ""
        )
        automatic.target = self
        automatic.representedObject = NSNull()
        automatic.state = audioInput.selectedDeviceUID == nil ? .on : .off
        menu.addItem(automatic)

        if audioInput.devices.isEmpty {
            let unavailable = NSMenuItem(title: "No microphones found", action: nil, keyEquivalent: "")
            unavailable.isEnabled = false
            menu.addItem(unavailable)
        } else {
            for device in audioInput.devices {
                let item = NSMenuItem(
                    title: device.name,
                    action: #selector(selectMicrophone(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = device.id
                item.state = audioInput.selectedDeviceUID == device.id ? .on : .off
                menu.addItem(item)
            }
        }

        if let selectedUID = audioInput.selectedDeviceUID,
           !audioInput.devices.contains(where: { $0.id == selectedUID }) {
            let missing = NSMenuItem(
                title: "\(audioInput.selectedDeviceName ?? "Saved microphone") (Unavailable)",
                action: nil,
                keyEquivalent: ""
            )
            missing.isEnabled = false
            missing.state = .on
            menu.addItem(missing)
        }

        if let warning = audioInput.selectionWarning {
            menu.addItem(.separator())
            let warningItem = NSMenuItem(title: warning, action: nil, keyEquivalent: "")
            warningItem.isEnabled = false
            warningItem.toolTip = warning
            menu.addItem(warningItem)
        }

        menu.addItem(.separator())
        let refresh = NSMenuItem(
            title: "Refresh Microphones",
            action: #selector(refreshMicrophones),
            keyEquivalent: ""
        )
        refresh.target = self
        menu.addItem(refresh)

        let soundSettings = NSMenuItem(
            title: "Sound Input Settings…",
            action: #selector(openSoundInputSettings),
            keyEquivalent: ""
        )
        soundSettings.target = self
        menu.addItem(soundSettings)
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        let uid = sender.representedObject as? String
        controller.audioInputController.setSelectedDeviceUID(uid)
        rebuildMicrophoneMenu()
    }

    @objc private func refreshMicrophones() {
        controller.audioInputController.refreshDevices()
        rebuildMicrophoneMenu()
    }

    @objc private func openSoundInputSettings() {
        controller.audioInputController.openSoundInputSettings()
    }

    private func updateStatus(state: AppState.State) {
        let title: String
        switch state {
        case .idle:
            title = "State: Idle"
            toggleItem?.title = "Start Hands-Free Dictation"
            toggleItem?.isEnabled = true
        case .listening:
            title = "State: Listening"
            toggleItem?.title = controller.appState.activeDictationMode == .handsFree
                ? "Stop Hands-Free Dictation"
                : "Continue Hands-Free"
            toggleItem?.isEnabled = true
        case .transcribing:
            title = "State: Transcribing"
            toggleItem?.title = "Transcribing…"
            toggleItem?.isEnabled = false
        case .commandListening:
            title = "State: Command Mode Listening"
            toggleItem?.title = "Command Mode…"
            toggleItem?.isEnabled = false
        case .commandProcessing:
            title = "State: Running Command"
            toggleItem?.title = "Running Command…"
            toggleItem?.isEnabled = false
        case .scratchpadListening:
            title = "State: Scratchpad Listening"
            toggleItem?.title = "Scratchpad…"
            toggleItem?.isEnabled = false
        case .scratchpadProcessing:
            title = "State: Adding to Scratchpad"
            toggleItem?.title = "Adding to Scratchpad…"
            toggleItem?.isEnabled = false
        case .error(let message):
            title = "State: Error — \(message)"
            toggleItem?.title = "Start Hands-Free Dictation"
            toggleItem?.isEnabled = true
        }
        updateCancelItem()
        stateItem?.title = title
        statusItem.button?.image = statusBarImage()
    }

    private func statusBarImage() -> NSImage? {
        let image = NSImage(named: "MenuBarIcon")
        image?.isTemplate = true
        return image
    }

    @objc private func toggleDictation() {
        controller.hotkeyManager.toggleFromMenu()
    }

    @objc private func cancelDictation() {
        controller.dictationController.cancelCurrentDictation()
        controller.transformController.cancelCurrentTransform()
        controller.commandModeController.cancelCurrentCommand()
        controller.scratchpadController.cancelCurrentAction()
    }

    @objc private func pasteLastTranscript() {
        guard controller.setupController.requireReady() else { return }
        controller.dictationController.pasteLastTranscript()
    }

    @objc private func copyLastTranscript() {
        guard controller.setupController.requireReady() else { return }
        controller.dictationController.copyLastTranscript()
    }

    private func updateRecoveryItems(hasTranscript: Bool) {
        pasteLastItem?.isEnabled = hasTranscript
        copyLastItem?.isEnabled = hasTranscript
    }

    private func updateCancelItem() {
        let canCancelDictation = controller.appState.state == .listening
            || controller.appState.state == .transcribing
        let canCancelTransform = controller.transformController.canCancel
        let canCancelCommand = controller.commandModeController.canCancel
        let canCancelScratchpad = controller.scratchpadController.canCancel
        cancelItem?.isEnabled = canCancelDictation || canCancelTransform || canCancelCommand || canCancelScratchpad
        if canCancelScratchpad {
            cancelItem?.title = "Cancel Scratchpad Action"
        } else if canCancelCommand {
            cancelItem?.title = "Cancel Command"
        } else if canCancelTransform {
            cancelItem?.title = "Cancel Transform"
        } else {
            cancelItem?.title = "Cancel Dictation"
        }
    }

    private func rebuildTransformMenu(settings: TransformSettings) {
        guard let transformSubmenu else { return }
        transformSubmenu.removeAllItems()

        for definition in settings.definitions {
            let shortcutSuffix = definition.hotkey.map { "  (\($0.displayString()))" } ?? ""
            let item = NSMenuItem(
                title: definition.name + shortcutSuffix,
                action: #selector(applyTransform(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = definition.id.uuidString
            item.isEnabled = settings.isEnabled
            if let hotkey = definition.hotkey {
                item.toolTip = "Shortcut: \(hotkey.displayString())"
            }
            transformSubmenu.addItem(item)
        }

        if !settings.isEnabled {
            transformSubmenu.addItem(.separator())
            let disabled = NSMenuItem(
                title: "Enable in Transforms…",
                action: #selector(openTransforms),
                keyEquivalent: ""
            )
            disabled.target = self
            transformSubmenu.addItem(disabled)
        }
    }

    @objc private func applyTransform(_ sender: NSMenuItem) {
        guard controller.setupController.requireReady() else { return }
        guard let rawID = sender.representedObject as? String,
              let id = UUID(uuidString: rawID) else { return }
        controller.transformController.apply(transformID: id)
    }

    @objc private func showLatestTransform() {
        guard controller.setupController.requireReady() else { return }
        controller.transformController.showLatestResult()
        controller.settingsWindowController.show(destination: .transforms)
    }

    @objc private func openSettings() {
        controller.settingsWindowController.show(destination: .settings)
    }

    @objc private func openHub() {
        controller.settingsWindowController.show(destination: .home)
    }

    @objc private func openSnippets() {
        controller.settingsWindowController.show(destination: .snippets)
    }

    @objc private func openStyles() {
        controller.settingsWindowController.show(destination: .styles)
    }

    @objc private func openTransforms() {
        controller.settingsWindowController.show(destination: .transforms)
    }

    @objc private func openScratchpad() {
        guard controller.setupController.requireReady() else { return }
        controller.scratchpadController.toggleWindow()
    }

    @objc private func openDictionary() {
        controller.settingsWindowController.show(destination: .dictionary)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
