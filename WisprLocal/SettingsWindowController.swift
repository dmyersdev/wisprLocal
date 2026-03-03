import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let appState: AppState
    private let hotkeyManager: HotkeyManager
    private var globalMonitor: Any?
    private var lastShowTime: TimeInterval = 0

    init(appState: AppState, hotkeyManager: HotkeyManager) {
        self.appState = appState
        self.hotkeyManager = hotkeyManager
    }

    func show() {
        NSLog("SettingsWindowController.show invoked")
        if window == nil {
            let view = SettingsView(hotkeyManager: hotkeyManager)
                .environmentObject(appState)
            let hostingController = NSHostingController(rootView: view)
            hostingController.view.autoresizingMask = [.width, .height]

            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                       backing: .buffered,
                                       defer: false)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 520, height: 560))
            window.contentMinSize = NSSize(width: 520, height: 560)
            window.contentMaxSize = NSSize(width: 520, height: 560)
            window.center()
            window.contentViewController = hostingController
            hostingController.view.frame = NSRect(x: 0, y: 0, width: 520, height: 560)
            self.window = window
        }

        NSApp.activate(ignoringOtherApps: true)
        if let window {
            if let screen = NSScreen.main {
                let frame = screen.visibleFrame
                let size = NSSize(width: 520, height: 560)
                let x = frame.midX - size.width / 2
                let y = frame.midY - size.height / 2
                window.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: false)
            }
            window.makeKeyAndOrderFront(nil)
            window.makeKey()
            window.displayIfNeeded()
            NSLog("Settings window frame: %@", NSStringFromRect(window.frame))
        }
        lastShowTime = Date().timeIntervalSinceReferenceDate
        // Temporarily disable outside-click monitor while debugging visibility.
    }

    func windowWillClose(_ notification: Notification) {
        removeOutsideClickMonitor()
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let window = self.window, window.isVisible else { return }
            let now = Date().timeIntervalSinceReferenceDate
            if now - self.lastShowTime < 0.2 {
                return
            }
            let clickPoint = NSEvent.mouseLocation
            if !window.frame.contains(clickPoint) {
                window.orderOut(nil)
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
    }
}
