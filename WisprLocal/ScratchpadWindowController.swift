import AppKit
import SwiftUI

@MainActor
final class ScratchpadWindowController: NSObject, NSWindowDelegate {
    private let controller: ScratchpadController
    private var panel: NSPanel?
    private var hasPositionedWindow = false

    init(controller: ScratchpadController) {
        self.controller = controller
        super.init()

        controller.onShowWindow = { [weak self] in self?.show() }
        controller.onHideWindow = { [weak self] in self?.hide() }
        controller.isWindowVisible = { [weak self] in self?.panel?.isVisible == true }
    }

    func show() {
        let panel = panel ?? makePanel()
        if !hasPositionedWindow {
            position(panel)
            hasPositionedWindow = true
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        Task { [weak controller] in
            await Task.yield()
            controller?.editorBridge.focus()
        }
    }

    func hide() {
        controller.store.flushAutosave()
        panel?.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    func windowDidResignKey(_ notification: Notification) {
        controller.store.flushAutosave()
    }

    private func makePanel() -> NSPanel {
        let content = ScratchpadView(controller: controller)
        let hostingController = NSHostingController(rootView: content)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Scratchpad"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentMinSize = NSSize(width: 620, height: 440)
        panel.contentViewController = hostingController
        panel.delegate = self
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else {
            panel.center()
            return
        }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.maxX - panel.frame.width - 28,
            y: visible.maxY - panel.frame.height - 28
        )
        panel.setFrameOrigin(origin)
    }
}
