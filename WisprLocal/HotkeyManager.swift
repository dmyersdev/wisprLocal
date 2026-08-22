import AppKit
import Carbon
import Combine
import Foundation

struct Hotkey: Codable, Equatable {
    enum Kind: String, Codable {
        case carbon
        case fnAlone
    }

    var kind: Kind
    var keyCode: UInt16
    var modifiers: HotkeyModifiers

    static let defaultCarbon = Hotkey(kind: .carbon, keyCode: UInt16(kVK_F6), modifiers: [])
    static let fnAlone = Hotkey(kind: .fnAlone, keyCode: 0, modifiers: [])
    static let scratchpad = Hotkey(
        kind: .carbon,
        keyCode: UInt16(kVK_ANSI_S),
        modifiers: [.option]
    )
    static let handsFreeDefault = Hotkey(
        kind: .carbon,
        keyCode: UInt16(kVK_Space),
        modifiers: [.control, .option]
    )

    func displayString() -> String {
        switch kind {
        case .fnAlone:
            return "Fn (experimental)"
        case .carbon:
            var parts: [String] = []
            if modifiers.contains(.control) { parts.append("⌃") }
            if modifiers.contains(.option) { parts.append("⌥") }
            if modifiers.contains(.shift) { parts.append("⇧") }
            if modifiers.contains(.command) { parts.append("⌘") }
            parts.append(KeyCodeFormatter.string(for: keyCode))
            return parts.joined()
        }
    }
}

struct HotkeyModifiers: OptionSet, Codable, Equatable {
    let rawValue: Int

    static let command = HotkeyModifiers(rawValue: 1 << 0)
    static let option = HotkeyModifiers(rawValue: 1 << 1)
    static let control = HotkeyModifiers(rawValue: 1 << 2)
    static let shift = HotkeyModifiers(rawValue: 1 << 3)

    static func from(_ flags: NSEvent.ModifierFlags) -> HotkeyModifiers {
        var result: HotkeyModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.shift) { result.insert(.shift) }
        return result
    }

    func carbonFlags() -> UInt32 {
        var flags: UInt32 = 0
        if contains(.command) { flags |= UInt32(cmdKey) }
        if contains(.option) { flags |= UInt32(optionKey) }
        if contains(.control) { flags |= UInt32(controlKey) }
        if contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }
}

enum CancelShortcutPolicy {
    static func shouldConsume(keyCode: Int64, canCancel: Bool) -> Bool {
        keyCode == Int64(kVK_Escape) && canCancel
    }
}

enum DictationShortcutPolicy {
    static let doubleTapWindow: TimeInterval = 0.28
    static let maximumTapDuration: TimeInterval = 0.35

    static func shouldAwaitSecondTap(pressDuration: TimeInterval) -> Bool {
        pressDuration >= 0 && pressDuration <= maximumTapDuration
    }

    static func isSecondTap(
        firstReleaseTime: TimeInterval,
        secondPressTime: TimeInterval
    ) -> Bool {
        let interval = secondPressTime - firstReleaseTime
        return interval >= 0 && interval <= doubleTapWindow
    }
}

@MainActor
final class HotkeyManager: ObservableObject {
    @Published private(set) var currentHotkey: Hotkey

    private let appState: AppState
    private let dictationController: DictationController
    private let transformController: TransformController
    private let commandModeController: CommandModeController
    private let scratchpadController: ScratchpadController
    private let setupController: SetupController
    private var hotKeyRef: EventHotKeyRef?
    private var actionHotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var transformHotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var transformIDsByHotkeyID: [UInt32: UUID] = [:]
    private var eventHandlerRef: EventHandlerRef?

    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var cancelEventTap: CFMachPort?
    private var cancelEventTapSource: CFRunLoopSource?
    private var cancellables = Set<AnyCancellable>()

    private var fnDown = false
    private var fnUsedWithOtherKey = false
    private var fnDownTimestamp: UInt64 = 0
    private var fnDictationStarted = false
    private var pendingFnStartTask: Task<Void, Never>?
    private var pendingDictationReleaseTask: Task<Void, Never>?
    private var pendingDictationReleaseTime: TimeInterval?
    private var dictationPressStartedAt: TimeInterval?
    private var activeCommandShortcut: CommandShortcut?
    private var isGlobalActionsEnabled = false

    private static let dictationHotkeyID: UInt32 = 1
    private static let pasteLastHotkeyID: UInt32 = 2
    private static let copyLastHotkeyID: UInt32 = 3
    private static let scratchpadHotkeyID: UInt32 = 4
    private static let handsFreeHotkeyID: UInt32 = 5
    private static let viewTransformResultHotkeyID: UInt32 = 90
    private static let transformHotkeyIDStart: UInt32 = 100
    private static let signature: OSType = 0x57535052 // 'WSPR'

    var onShowTransformResult: (() -> Void)?

    init(
        appState: AppState,
        dictationController: DictationController,
        transformController: TransformController,
        commandModeController: CommandModeController,
        scratchpadController: ScratchpadController,
        setupController: SetupController
    ) {
        self.appState = appState
        self.dictationController = dictationController
        self.transformController = transformController
        self.commandModeController = commandModeController
        self.scratchpadController = scratchpadController
        self.setupController = setupController

        if let stored = HotkeyManager.loadStoredHotkey() {
            currentHotkey = stored
        } else {
            currentHotkey = .fnAlone
        }

        applyHotkey(currentHotkey, persist: true)

        appState.$holdToTalk
            .sink { [weak self] _ in
                guard let self else { return }
                self.applyHotkey(self.currentHotkey, persist: true)
            }
            .store(in: &cancellables)

        appState.$handsFreeHotkey
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                self?.registerActionHotkeys()
            }
            .store(in: &cancellables)

        appState.$transformSettings
            .removeDuplicates()
            .sink { [weak self] settings in
                self?.registerTransformHotkeys(settings: settings)
            }
            .store(in: &cancellables)

        setupController.$isCompleted
            .removeDuplicates()
            .sink { [weak self] isCompleted in
                self?.setGlobalActionsEnabled(isCompleted)
            }
            .store(in: &cancellables)
    }

    func updateHotkey(_ hotkey: Hotkey) {
        applyHotkey(hotkey, persist: true)
    }

    func updateHandsFreeHotkey(_ hotkey: Hotkey) {
        guard hotkey.kind == .carbon else { return }
        appState.handsFreeHotkey = hotkey
    }

    func toggleFromMenu() {
        guard setupController.requireReady() else { return }
        dictationController.toggle()
    }

    private func applyHotkey(_ hotkey: Hotkey, persist: Bool) {
        if !isGlobalActionsEnabled {
            let resolvedHotkey = hotkey == .scratchpad ? Hotkey.defaultCarbon : hotkey
            currentHotkey = resolvedHotkey
            appState.hotkeyDisplay = resolvedHotkey.kind == .fnAlone
                ? "fn"
                : resolvedHotkey.displayString()
            appState.hotkeyWarning = hotkey == .scratchpad
                ? "⌥S is reserved for Scratchpad. Dictation was reset to F6."
                : nil
            if persist { storeHotkey(resolvedHotkey) }
            return
        }

        if hotkey == .scratchpad {
            let fallback = Hotkey.defaultCarbon
            currentHotkey = fallback
            registerCarbonHotkey(fallback)
            appState.hotkeyDisplay = fallback.displayString()
            appState.hotkeyWarning = "⌥S is reserved for Scratchpad. Dictation was reset to F6."
            if persist { storeHotkey(fallback) }
            return
        }

        if hotkey.kind == .fnAlone {
            if startFnMonitor() {
                unregisterCarbonHotkey()
                currentHotkey = hotkey
                appState.hotkeyDisplay = "fn"
                appState.hotkeyWarning = nil
                if persist { storeHotkey(hotkey) }
                return
            } else {
                let fallback = Hotkey.defaultCarbon
                currentHotkey = fallback
                registerCarbonHotkey(fallback)
                appState.hotkeyDisplay = fallback.displayString()
                appState.hotkeyWarning = "Fn alone isn’t supported on this Mac. Defaulting to F6. You can remap in Settings."
                if persist { storeHotkey(fallback) }
                return
            }
        }

        if !startFnMonitor() {
            appState.commandHotkeyWarning = "Command Mode shortcuts need Accessibility permission."
        }
        currentHotkey = hotkey
        registerCarbonHotkey(hotkey)
        appState.hotkeyDisplay = hotkey.displayString()
        appState.hotkeyWarning = nil
        if persist { storeHotkey(hotkey) }
    }

    private func registerCarbonHotkey(_ hotkey: Hotkey) {
        unregisterCarbonHotkey()
        installEventHandlerIfNeeded()
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(
            signature: HotkeyManager.signature,
            id: HotkeyManager.dictationHotkeyID
        )
        let status = RegisterEventHotKey(UInt32(hotkey.keyCode), hotkey.modifiers.carbonFlags(), hotKeyID, GetEventDispatcherTarget(), 0, &hotKeyRef)
        if status == noErr {
            self.hotKeyRef = hotKeyRef
        } else {
            appState.hotkeyWarning = "Failed to register hotkey. Try another key."
        }
    }

    private func unregisterCarbonHotkey() {
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let callback: EventHandlerUPP = { _, eventRef, userData in
            guard let userData else { return noErr }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(eventRef, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            if status == noErr && hotKeyID.signature == HotkeyManager.signature {
                let kind = GetEventKind(eventRef)
                DispatchQueue.main.async {
                    manager.handleCarbonHotkey(id: hotKeyID.id, kind: kind)
                }
            }
            return noErr
        }
        InstallEventHandler(GetEventDispatcherTarget(), callback, 2, &eventTypes, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()), &eventHandlerRef)
    }

    private func startFnMonitor() -> Bool {
        if eventTap != nil { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { proxy, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
            return manager.handleFnEvent(proxy: proxy, type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask),
                                          callback: callback,
                                          userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        eventTapSource = source
        appState.commandHotkeyWarning = nil
        return true
    }

    private func stopFnMonitor() {
        if let source = eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        eventTapSource = nil
        fnDown = false
        fnUsedWithOtherKey = false
        fnDownTimestamp = 0
        fnDictationStarted = false
        pendingFnStartTask?.cancel()
        pendingFnStartTask = nil
        activeCommandShortcut = nil
    }

    private func handleFnEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        let fnHeld = flags.contains(.maskSecondaryFn)
        let modifiers = commandModifiers(from: flags)
        let commandShortcut = CommandShortcutMatcher.match(
            fnHeld: fnHeld,
            modifiers: modifiers
        )

        switch type {
        case .flagsChanged:
            if let commandShortcut {
                if activeCommandShortcut == nil {
                    let shouldCancelFnDictation = fnDictationStarted
                    activeCommandShortcut = commandShortcut
                    pendingFnStartTask?.cancel()
                    pendingFnStartTask = nil
                    fnDown = false
                    fnUsedWithOtherKey = false
                    fnDictationStarted = false
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        if shouldCancelFnDictation {
                            self.dictationController.cancelCurrentDictation()
                        }
                        self.commandModeController.startRecording()
                    }
                }
                return Unmanaged.passUnretained(event)
            }

            if activeCommandShortcut != nil {
                activeCommandShortcut = nil
                pendingFnStartTask?.cancel()
                pendingFnStartTask = nil
                fnDown = false
                fnUsedWithOtherKey = false
                fnDictationStarted = false
                DispatchQueue.main.async { [weak self] in
                    self?.commandModeController.stopAndExecute()
                }
                return Unmanaged.passUnretained(event)
            }

            guard currentHotkey.kind == .fnAlone else {
                return Unmanaged.passUnretained(event)
            }

            let fnOnly = fnHeld && modifiers.isEmpty
            if fnOnly && !fnDown {
                fnDown = true
                fnUsedWithOtherKey = false
                fnDownTimestamp = event.timestamp
                if appState.holdToTalk {
                    if continueAsHandsFreeIfAwaitingSecondTap(
                        at: Double(event.timestamp) / 1_000_000_000
                    ) {
                        fnDictationStarted = true
                        return Unmanaged.passUnretained(event)
                    }
                    pendingFnStartTask?.cancel()
                    pendingFnStartTask = Task { [weak self] in
                        do {
                            try await Task.sleep(nanoseconds: 120_000_000)
                        } catch {
                            return
                        }
                        guard let self,
                              !Task.isCancelled,
                              self.fnDown,
                              self.activeCommandShortcut == nil,
                              self.currentHotkey.kind == .fnAlone,
                              self.appState.holdToTalk else { return }
                        self.fnDictationStarted = true
                        self.dictationPressStartedAt = Double(self.fnDownTimestamp) / 1_000_000_000
                        self.dictationController.startRecording(mode: .pushToTalk)
                    }
                }
            } else if fnDown && !fnHeld {
                let duration = event.timestamp &- fnDownTimestamp
                let shortPress = duration < 900_000_000
                pendingFnStartTask?.cancel()
                pendingFnStartTask = nil
                if appState.holdToTalk {
                    if fnDictationStarted && !fnUsedWithOtherKey {
                        let releaseTime = Double(event.timestamp) / 1_000_000_000
                        DispatchQueue.main.async { [weak self] in
                            self?.handlePushToTalkRelease(at: releaseTime)
                        }
                    }
                } else {
                    if !fnUsedWithOtherKey && shortPress {
                        DispatchQueue.main.async {
                            self.dictationController.toggle()
                        }
                    }
                }
                fnDown = false
                fnUsedWithOtherKey = false
                fnDictationStarted = false
            } else if fnDown && !modifiers.isEmpty {
                fnUsedWithOtherKey = true
                pendingFnStartTask?.cancel()
                pendingFnStartTask = nil
                if fnDictationStarted {
                    DispatchQueue.main.async { [weak self] in
                        self?.dictationController.stopAndTranscribe()
                    }
                    fnDictationStarted = false
                }
            }
        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if fnHeld,
               modifiers.isEmpty,
               keyCode == Int64(kVK_Space) {
                pendingFnStartTask?.cancel()
                pendingFnStartTask = nil
                fnUsedWithOtherKey = true
                fnDictationStarted = false
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    DispatchQueue.main.async { [weak self] in
                        self?.dictationController.toggleHandsFree()
                    }
                }
                return nil
            }
            if CommandShortcutMatcher.shouldCancelForKeyDown(
                activeShortcut: activeCommandShortcut
            ) {
                activeCommandShortcut = nil
                pendingFnStartTask?.cancel()
                pendingFnStartTask = nil
                fnDown = false
                fnUsedWithOtherKey = false
                fnDictationStarted = false
                DispatchQueue.main.async { [weak self] in
                    self?.commandModeController.cancelCurrentCommand()
                }
                return Unmanaged.passUnretained(event)
            }
            if fnDown { fnUsedWithOtherKey = true }
        default:
            break
        }

        return Unmanaged.passUnretained(event)
    }

    private func commandModifiers(from flags: CGEventFlags) -> HotkeyModifiers {
        var modifiers: HotkeyModifiers = []
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        return modifiers
    }

    private func handleCarbonHotkey(id: UInt32, kind: UInt32) {
        guard setupController.requireReady() else { return }
        switch id {
        case Self.dictationHotkeyID:
            handleDictationHotkey(kind: kind)
        case Self.pasteLastHotkeyID where kind == UInt32(kEventHotKeyPressed):
            dictationController.pasteLastTranscript()
        case Self.copyLastHotkeyID where kind == UInt32(kEventHotKeyPressed):
            dictationController.copyLastTranscript()
        case Self.scratchpadHotkeyID:
            if kind == UInt32(kEventHotKeyPressed) {
                scratchpadController.shortcutPressed()
            } else if kind == UInt32(kEventHotKeyReleased) {
                scratchpadController.shortcutReleased()
            }
        case Self.handsFreeHotkeyID where kind == UInt32(kEventHotKeyPressed):
            dictationController.toggleHandsFree()
        case Self.viewTransformResultHotkeyID where kind == UInt32(kEventHotKeyPressed):
            transformController.showLatestResult()
            onShowTransformResult?()
        case let hotkeyID where kind == UInt32(kEventHotKeyPressed):
            if let transformID = transformIDsByHotkeyID[hotkeyID] {
                transformController.apply(transformID: transformID)
            }
        default:
            break
        }
    }

    private func handleDictationHotkey(kind: UInt32) {
        if appState.holdToTalk, kind == UInt32(kEventHotKeyPressed) {
            if continueAsHandsFreeIfAwaitingSecondTap(
                at: ProcessInfo.processInfo.systemUptime
            ) {
                return
            }
            switch appState.state {
            case .idle, .error:
                dictationPressStartedAt = ProcessInfo.processInfo.systemUptime
                dictationController.startRecording(mode: .pushToTalk)
            default:
                break
            }
        } else if appState.holdToTalk, kind == UInt32(kEventHotKeyReleased) {
            handlePushToTalkRelease(at: ProcessInfo.processInfo.systemUptime)
        } else if kind == UInt32(kEventHotKeyPressed) {
            dictationController.toggleHandsFree()
        }
    }

    private func continueAsHandsFreeIfAwaitingSecondTap(
        at pressTime: TimeInterval
    ) -> Bool {
        guard pendingDictationReleaseTask != nil,
              let releaseTime = pendingDictationReleaseTime,
              DictationShortcutPolicy.isSecondTap(
                firstReleaseTime: releaseTime,
                secondPressTime: pressTime
              ) else { return false }
        pendingDictationReleaseTask?.cancel()
        pendingDictationReleaseTask = nil
        pendingDictationReleaseTime = nil
        dictationPressStartedAt = nil
        dictationController.lockHandsFree()
        return true
    }

    private func handlePushToTalkRelease(at releaseTime: TimeInterval) {
        guard !dictationController.isHandsFreeOperation else {
            dictationPressStartedAt = nil
            return
        }
        guard let pressStartedAt = dictationPressStartedAt else { return }
        dictationPressStartedAt = nil
        let duration = max(0, releaseTime - pressStartedAt)
        guard DictationShortcutPolicy.shouldAwaitSecondTap(pressDuration: duration) else {
            dictationController.stopAndTranscribe()
            return
        }

        pendingDictationReleaseTask?.cancel()
        pendingDictationReleaseTime = releaseTime
        pendingDictationReleaseTask = Task { [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(DictationShortcutPolicy.doubleTapWindow * 1_000_000_000)
                )
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.pendingDictationReleaseTask = nil
            self.pendingDictationReleaseTime = nil
            self.dictationController.stopAndTranscribe()
        }
    }

    private func registerActionHotkeys() {
        for reference in actionHotKeyRefs.values {
            UnregisterEventHotKey(reference)
        }
        actionHotKeyRefs.removeAll()
        guard isGlobalActionsEnabled else { return }
        installEventHandlerIfNeeded()

        let recoveryModifiers: HotkeyModifiers = [.command, .control]
        let actions: [(id: UInt32, keyCode: UInt32, modifiers: UInt32, name: String)] = [
            (
                Self.pasteLastHotkeyID,
                UInt32(kVK_ANSI_V),
                recoveryModifiers.carbonFlags(),
                "Paste last transcript (⌃⌘V)"
            ),
            (
                Self.copyLastHotkeyID,
                UInt32(kVK_ANSI_C),
                recoveryModifiers.carbonFlags(),
                "Copy last transcript (⌃⌘C)"
            ),
            (
                Self.scratchpadHotkeyID,
                UInt32(Hotkey.scratchpad.keyCode),
                Hotkey.scratchpad.modifiers.carbonFlags(),
                "Scratchpad (⌥S)"
            ),
            (
                Self.handsFreeHotkeyID,
                UInt32(appState.handsFreeHotkey.keyCode),
                appState.handsFreeHotkey.modifiers.carbonFlags(),
                "Hands-free dictation (\(appState.handsFreeHotkey.displayString()))"
            )
        ]

        var failures: [String] = []
        for action in actions {
            var reference: EventHotKeyRef?
            let identifier = EventHotKeyID(signature: Self.signature, id: action.id)
            let status = RegisterEventHotKey(
                action.keyCode,
                action.modifiers,
                identifier,
                GetEventDispatcherTarget(),
                0,
                &reference
            )
            if status == noErr, let reference {
                actionHotKeyRefs[action.id] = reference
            } else {
                failures.append(action.name)
            }
        }

        if !startCancelMonitor() {
            failures.append("Cancel dictation (Esc)")
        }

        appState.recoveryHotkeyWarning = failures.isEmpty
            ? nil
            : "Couldn’t enable: \(failures.joined(separator: ", ")). Check Accessibility permission and shortcut conflicts."
        appState.scratchpadHotkeyWarning = failures.contains("Scratchpad (⌥S)")
            ? "Couldn’t enable ⌥S. Quit the app using that shortcut, then relaunch WisprLocal."
            : nil
        appState.handsFreeHotkeyWarning = failures.contains {
            $0.hasPrefix("Hands-free dictation")
        } ? "Couldn’t enable the hands-free shortcut. Choose another shortcut in Settings." : nil
    }

    private func registerTransformHotkeys(settings: TransformSettings) {
        for reference in transformHotKeyRefs.values {
            UnregisterEventHotKey(reference)
        }
        transformHotKeyRefs.removeAll()
        transformIDsByHotkeyID.removeAll()
        appState.transformHotkeyWarning = nil

        guard isGlobalActionsEnabled, settings.isEnabled else { return }
        installEventHandlerIfNeeded()

        var registrations: [(id: UInt32, hotkey: Hotkey, name: String, transformID: UUID?)] = []
        for (index, definition) in settings.definitions.enumerated() {
            guard let hotkey = definition.hotkey,
                  hotkey.kind == .carbon else { continue }
            registrations.append((
                Self.transformHotkeyIDStart + UInt32(index),
                hotkey,
                definition.name,
                definition.id
            ))
        }
        registrations.append((
            Self.viewTransformResultHotkeyID,
            Hotkey(
                kind: .carbon,
                keyCode: UInt16(kVK_ANSI_O),
                modifiers: [.option]
            ),
            "View latest transform",
            nil
        ))

        var failures: [String] = []
        for registration in registrations {
            var reference: EventHotKeyRef?
            let identifier = EventHotKeyID(
                signature: Self.signature,
                id: registration.id
            )
            let status = RegisterEventHotKey(
                UInt32(registration.hotkey.keyCode),
                registration.hotkey.modifiers.carbonFlags(),
                identifier,
                GetEventDispatcherTarget(),
                0,
                &reference
            )
            if status == noErr, let reference {
                transformHotKeyRefs[registration.id] = reference
                if let transformID = registration.transformID {
                    transformIDsByHotkeyID[registration.id] = transformID
                }
            } else {
                failures.append(registration.name)
            }
        }

        if !failures.isEmpty {
            appState.transformHotkeyWarning = "Couldn’t enable shortcuts for: \(failures.joined(separator: ", ")). Reassign conflicting shortcuts."
        }
    }

    private func startCancelMonitor() -> Bool {
        stopCancelMonitor()
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
            return manager.handleCancelEvent(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        cancelEventTap = tap
        cancelEventTapSource = source
        return true
    }

    private func setGlobalActionsEnabled(_ isEnabled: Bool) {
        guard isEnabled != isGlobalActionsEnabled else { return }
        isGlobalActionsEnabled = isEnabled

        if isEnabled {
            applyHotkey(currentHotkey, persist: false)
            registerActionHotkeys()
            registerTransformHotkeys(settings: appState.transformSettings)
        } else {
            pendingFnStartTask?.cancel()
            pendingFnStartTask = nil
            pendingDictationReleaseTask?.cancel()
            pendingDictationReleaseTask = nil
            pendingDictationReleaseTime = nil
            dictationPressStartedAt = nil
            unregisterCarbonHotkey()
            stopFnMonitor()
            stopCancelMonitor()
            for reference in actionHotKeyRefs.values {
                UnregisterEventHotKey(reference)
            }
            actionHotKeyRefs.removeAll()
            for reference in transformHotKeyRefs.values {
                UnregisterEventHotKey(reference)
            }
            transformHotKeyRefs.removeAll()
            transformIDsByHotkeyID.removeAll()
            dictationController.cancelCurrentDictation()
            transformController.cancelCurrentTransform()
            commandModeController.cancelCurrentCommand()
            scratchpadController.cancelCurrentAction()
        }
    }

    private func handleCancelEvent(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let cancelEventTap {
                CGEvent.tapEnable(tap: cancelEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let canCancel = dictationController.canCancel
            || transformController.canCancel
            || commandModeController.canCancel
            || scratchpadController.canCancel
        guard CancelShortcutPolicy.shouldConsume(
            keyCode: event.getIntegerValueField(.keyboardEventKeycode),
            canCancel: canCancel
        ) else {
            return Unmanaged.passUnretained(event)
        }

        DispatchQueue.main.async { [weak self] in
            self?.dictationController.cancelCurrentDictation()
            self?.transformController.cancelCurrentTransform()
            self?.commandModeController.cancelCurrentCommand()
            self?.scratchpadController.cancelCurrentAction()
        }
        return nil
    }

    private func stopCancelMonitor() {
        if let source = cancelEventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        cancelEventTap = nil
        cancelEventTapSource = nil
    }

    deinit {
        pendingFnStartTask?.cancel()
        pendingDictationReleaseTask?.cancel()
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        for reference in actionHotKeyRefs.values {
            UnregisterEventHotKey(reference)
        }
        for reference in transformHotKeyRefs.values {
            UnregisterEventHotKey(reference)
        }
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        }
        if let cancelEventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), cancelEventTapSource, .commonModes)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    private static func loadStoredHotkey() -> Hotkey? {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKeys.hotkey) else { return nil }
        return try? JSONDecoder().decode(Hotkey.self, from: data)
    }

    private func storeHotkey(_ hotkey: Hotkey) {
        if let data = try? JSONEncoder().encode(hotkey) {
            UserDefaults.standard.set(data, forKey: DefaultsKeys.hotkey)
        }
    }

    private func storedHotkeyExists() -> Bool {
        return UserDefaults.standard.data(forKey: DefaultsKeys.hotkey) != nil
    }
}

@MainActor
private enum InputMonitoringPrompter { }

private enum KeyCodeFormatter {
    static func string(for keyCode: UInt16) -> String {
        switch keyCode {
        case UInt16(kVK_F1): return "F1"
        case UInt16(kVK_F2): return "F2"
        case UInt16(kVK_F3): return "F3"
        case UInt16(kVK_F4): return "F4"
        case UInt16(kVK_F5): return "F5"
        case UInt16(kVK_F6): return "F6"
        case UInt16(kVK_F7): return "F7"
        case UInt16(kVK_F8): return "F8"
        case UInt16(kVK_F9): return "F9"
        case UInt16(kVK_F10): return "F10"
        case UInt16(kVK_F11): return "F11"
        case UInt16(kVK_F12): return "F12"
        default:
            if let key = translateKeyCode(keyCode) {
                return key.uppercased()
            }
            return "Key \(keyCode)"
        }
    }

    private static func translateKeyCode(_ keyCode: UInt16) -> String? {
        guard let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let data = unsafeBitCast(layoutData, to: CFData.self)
        guard let pointer = CFDataGetBytePtr(data) else { return nil }
        let keyLayout = UnsafeRawPointer(pointer).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKeyState: UInt32 = 0
        var chars: [UniChar] = [0, 0, 0, 0]
        var actualLength: Int = 0
        let modifiers: UInt32 = 0
        let result = UCKeyTranslate(keyLayout, keyCode, UInt16(kUCKeyActionDisplay), modifiers, UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &actualLength, &chars)
        guard result == noErr, actualLength > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: actualLength)
    }
}
