import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = AppController.shared
    private var statusItem: NSStatusItem!
    private var stateCancellable: AnyCancellable?
    private var hudController: HUDWindowController?

    private var toggleItem: NSMenuItem?
    private var stateItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        hudController = HUDWindowController(appState: controller.appState,
                                            dictationController: controller.dictationController)
        stateCancellable = controller.appState.$state.sink { [weak self] state in
            self?.updateStatus(state: state)
        }
        updateStatus(state: controller.appState.state)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = statusBarImage()
        }

        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Start Dictation", action: #selector(toggleDictation), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        toggleItem = toggle

        let state = NSMenuItem(title: "State: Idle", action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        stateItem = state

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit WisprLocal", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func updateStatus(state: AppState.State) {
        let title: String
        switch state {
        case .idle:
            title = "State: Idle"
            toggleItem?.title = "Start Dictation"
            toggleItem?.isEnabled = true
        case .listening:
            title = "State: Listening"
            toggleItem?.title = "Stop Dictation"
            toggleItem?.isEnabled = true
        case .transcribing:
            title = "State: Transcribing"
            toggleItem?.title = "Transcribing…"
            toggleItem?.isEnabled = false
        case .error(let message):
            title = "State: Error — \(message)"
            toggleItem?.title = "Start Dictation"
            toggleItem?.isEnabled = true
        }
        stateItem?.title = title
        statusItem.button?.image = statusBarImage()
    }

    private func statusBarImage() -> NSImage? {
        let image = NSImage(named: "MenuBarIcon")
        image?.isTemplate = true
        return image
    }

    @objc private func toggleDictation() {
        controller.dictationController.toggle()
    }

    @objc private func openSettings() {
        controller.settingsWindowController.show()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
