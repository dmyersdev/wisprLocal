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

@MainActor
final class HotkeyManager: ObservableObject {
    @Published private(set) var currentHotkey: Hotkey

    private let appState: AppState
    private let dictationController: DictationController
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var cancellables = Set<AnyCancellable>()

    private var fnDown = false
    private var fnUsedWithOtherKey = false
    private var fnDownTimestamp: UInt64 = 0

    private static let hotkeyID: UInt32 = 1
    private static let signature: OSType = 0x57535052 // 'WSPR'

    init(appState: AppState, dictationController: DictationController) {
        self.appState = appState
        self.dictationController = dictationController

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
    }

    func updateHotkey(_ hotkey: Hotkey) {
        applyHotkey(hotkey, persist: true)
    }

    func toggleFromMenu() {
        dictationController.toggle()
    }

    private func applyHotkey(_ hotkey: Hotkey, persist: Bool) {
        if hotkey.kind == .fnAlone {
            if startFnMonitor() {
                unregisterCarbonHotkey()
                currentHotkey = hotkey
                appState.hotkeyDisplay = "fn"
                appState.hotkeyWarning = nil
                if appState.holdToTalk {
                    appState.hotkeyWarning = "Hold-to-talk isn’t supported for Fn alone. Choose another hotkey or disable Hold to Talk."
                }
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

        stopFnMonitor()
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
        let hotKeyID = EventHotKeyID(signature: HotkeyManager.signature, id: HotkeyManager.hotkeyID)
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
                    manager.handleCarbonHotkey(kind: kind)
                }
            }
            return noErr
        }
        InstallEventHandler(GetEventDispatcherTarget(), callback, 2, &eventTypes, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()), &eventHandlerRef)
    }

    private func startFnMonitor() -> Bool {
        stopFnMonitor()
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
    }

    private func handleFnEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard currentHotkey.kind == .fnAlone else {
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        let fnOnly = flags.contains(.maskSecondaryFn) && flags.subtracting(.maskSecondaryFn).isEmpty

        switch type {
        case .flagsChanged:
            if fnOnly && !fnDown {
                fnDown = true
                fnUsedWithOtherKey = false
                fnDownTimestamp = event.timestamp
                if appState.holdToTalk {
                    DispatchQueue.main.async {
                        switch self.appState.state {
                        case .idle, .error:
                            self.dictationController.startRecording()
                        default:
                            break
                        }
                    }
                }
            } else if fnDown && !flags.contains(.maskSecondaryFn) {
                let duration = event.timestamp &- fnDownTimestamp
                let shortPress = duration < 900_000_000
                if appState.holdToTalk {
                    if !fnUsedWithOtherKey {
                        DispatchQueue.main.async {
                            if self.appState.state == .listening {
                                self.dictationController.stopAndTranscribe()
                            }
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
            }
        case .keyDown:
            if fnDown { fnUsedWithOtherKey = true }
        default:
            break
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleCarbonHotkey(kind: UInt32) {
        if appState.holdToTalk {
            if kind == UInt32(kEventHotKeyPressed) {
                switch appState.state {
                case .idle, .error:
                    dictationController.startRecording()
                default:
                    break
                }
            } else if kind == UInt32(kEventHotKeyReleased) {
                if appState.state == .listening {
                    dictationController.stopAndTranscribe()
                }
            }
        } else {
            if kind == UInt32(kEventHotKeyPressed) {
                dictationController.toggle()
            }
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
