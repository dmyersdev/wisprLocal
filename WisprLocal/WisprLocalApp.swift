import SwiftUI

@main
struct WisprLocalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let controller = AppController.shared

    var body: some Scene {
        Settings {
            SettingsView(
                hotkeyManager: controller.hotkeyManager,
                scratchpadStore: controller.scratchpadController.store,
                setupController: controller.setupController
            )
                .environmentObject(controller.appState)
                .environmentObject(controller.audioInputController)
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    controller.settingsWindowController.show(destination: .settings)
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandGroup(after: .appInfo) {
                Button("Open WisprLocal") {
                    controller.settingsWindowController.show(destination: .home)
                }
                .keyboardShortcut("0", modifiers: .command)

                Button("Open Dictionary") {
                    controller.settingsWindowController.show(destination: .dictionary)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Button("Open Snippets") {
                    controller.settingsWindowController.show(destination: .snippets)
                }
                .keyboardShortcut("1", modifiers: [.command, .shift])

                Button("Open Styles") {
                    controller.settingsWindowController.show(destination: .styles)
                }
                .keyboardShortcut("2", modifiers: [.command, .shift])

                Button("Open Transforms") {
                    controller.settingsWindowController.show(destination: .transforms)
                }
                .keyboardShortcut("3", modifiers: [.command, .shift])

                Button("Open Scratchpad") {
                    guard controller.setupController.requireReady() else { return }
                    controller.scratchpadController.toggleWindow()
                }
            }
        }
    }
}
