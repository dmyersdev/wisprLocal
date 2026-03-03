import Foundation

@MainActor
final class AppController {
    static let shared = AppController()

    let appState: AppState
    let dictationController: DictationController
    let hotkeyManager: HotkeyManager
    let settingsWindowController: SettingsWindowController

    private init() {
        appState = AppState.shared
        dictationController = DictationController(appState: appState,
                                                 recorder: AudioRecorder(),
                                                 client: OpenAIClient(),
                                                 injector: TextInjector())
        hotkeyManager = HotkeyManager(appState: appState, dictationController: dictationController)
        settingsWindowController = SettingsWindowController(appState: appState, hotkeyManager: hotkeyManager)
    }
}
