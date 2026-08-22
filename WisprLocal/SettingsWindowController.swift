import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let appState: AppState
    private let hotkeyManager: HotkeyManager
    private let historyController: HistoryController
    private let transformController: TransformController
    private let scratchpadController: ScratchpadController
    private let setupController: SetupController
    private let audioInputController: AudioInputController
    private let navigation = HubNavigationModel()
    private var globalMonitor: Any?
    private var lastShowTime: TimeInterval = 0

    init(
        appState: AppState,
        hotkeyManager: HotkeyManager,
        historyController: HistoryController,
        transformController: TransformController,
        scratchpadController: ScratchpadController,
        setupController: SetupController,
        audioInputController: AudioInputController
    ) {
        self.appState = appState
        self.hotkeyManager = hotkeyManager
        self.historyController = historyController
        self.transformController = transformController
        self.scratchpadController = scratchpadController
        self.setupController = setupController
        self.audioInputController = audioInputController
    }

    func show(destination: HubDestination = .home) {
        navigation.selection = destination
        NSLog("SettingsWindowController.show invoked")
        if window == nil {
            let view = AppRootView(
                setupController: setupController,
                hotkeyManager: hotkeyManager,
                historyController: historyController,
                transformController: transformController,
                scratchpadController: scratchpadController,
                navigation: navigation
            )
                .environmentObject(appState)
                .environmentObject(audioInputController)
            let hostingController = NSHostingController(rootView: view)
            hostingController.view.autoresizingMask = [.width, .height]

            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                       backing: .buffered,
                                       defer: false)
            window.title = "WisprLocal"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 920, height: 640))
            window.contentMinSize = NSSize(width: 780, height: 540)
            window.center()
            window.contentViewController = hostingController
            hostingController.view.frame = NSRect(x: 0, y: 0, width: 920, height: 640)
            self.window = window
        }

        NSApp.activate(ignoringOtherApps: true)
        if let window {
            if let screen = NSScreen.main {
                let frame = screen.visibleFrame
                let size = window.frame.size
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
