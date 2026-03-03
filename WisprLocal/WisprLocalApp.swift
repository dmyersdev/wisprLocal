import SwiftUI

@main
struct WisprLocalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let controller = AppController.shared

    var body: some Scene {
        Settings {
            SettingsView(hotkeyManager: controller.hotkeyManager)
                .environmentObject(controller.appState)
        }
    }
}
