import AppKit
import SwiftUI

struct HotkeyRecorder: View {
    @Binding var hotkey: Hotkey
    var onCapture: (Hotkey) -> Void

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button(action: beginCapture) {
            Text(isRecording ? "Press shortcut…" : hotkey.displayString())
                .frame(minWidth: 140)
        }
        .buttonStyle(.bordered)
        .onDisappear {
            endCapture()
        }
    }

    private func beginCapture() {
        guard !isRecording else { return }
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .flagsChanged, event.modifierFlags.contains(.function) {
                let newHotkey = Hotkey.fnAlone
                hotkey = newHotkey
                onCapture(newHotkey)
                endCapture()
                return nil
            }
            if event.type == .keyDown {
                let modifiers = HotkeyModifiers.from(event.modifierFlags)
                let newHotkey = Hotkey(kind: .carbon, keyCode: event.keyCode, modifiers: modifiers)
                hotkey = newHotkey
                onCapture(newHotkey)
                endCapture()
                return nil
            }
            return event
        }
    }

    private func endCapture() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isRecording = false
    }
}
