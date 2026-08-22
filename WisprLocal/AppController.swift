import Foundation

@MainActor
final class AppController {
    static let shared = AppController()

    let appState: AppState
    let audioInputController: AudioInputController
    let setupController: SetupController
    let dictationController: DictationController
    let historyController: HistoryController
    let transformController: TransformController
    let commandModeController: CommandModeController
    let scratchpadController: ScratchpadController
    let scratchpadWindowController: ScratchpadWindowController
    let hotkeyManager: HotkeyManager
    let settingsWindowController: SettingsWindowController

    private init() {
        let appState = AppState.shared
        self.appState = appState
        let audioInputController = AudioInputController()
        audioInputController.startObservingDeviceChanges(SystemAudioInputDeviceChangeObserver())
        self.audioInputController = audioInputController
        let keychain = KeychainService.shared
        let setupController = SetupController(
            keyStore: keychain,
            keyValidator: OpenAIAPIKeyValidator(),
            permissions: SystemSetupPermissionService(),
            languageProvider: { appState.language },
            languageSetter: { appState.language = $0 }
        )
        self.setupController = setupController
        let openAIClient = OpenAIClient(keychain: keychain)
        let injector = TextInjector()
        let selectedTextEditor = SystemSelectedTextEditor(injector: injector)
        dictationController = DictationController(appState: appState,
                                                 recorder: AudioRecorder(audioInputController: audioInputController),
                                                 client: openAIClient,
                                                 transformClient: openAIClient,
                                                 injector: injector,
                                                 appContextProvider: SystemStyleAppContextProvider(),
                                                 isSetupComplete: { setupController.isReady },
                                                 onSetupRequired: { setupController.requestPresentation() })
        historyController = HistoryController(
            appState: appState,
            transcriptionClient: openAIClient,
            transformClient: openAIClient,
            injector: injector
        )
        let transformController = TransformController(
            appState: appState,
            client: openAIClient,
            editor: selectedTextEditor,
            injector: injector,
            isSetupComplete: { setupController.isReady },
            onSetupRequired: { setupController.requestPresentation() }
        )
        self.transformController = transformController
        commandModeController = CommandModeController(
            appState: appState,
            recorder: AudioRecorder(audioInputController: audioInputController),
            transcriptionClient: openAIClient,
            commandClient: openAIClient,
            editor: selectedTextEditor,
            isOtherActionInProgress: { [weak transformController] in
                transformController?.isActive ?? false
            },
            isSetupComplete: { setupController.isReady },
            onSetupRequired: { setupController.requestPresentation() }
        )
        let scratchpadController = ScratchpadController(
            appState: appState,
            store: ScratchpadStore(),
            editorBridge: ScratchpadEditorBridge(),
            recorder: AudioRecorder(audioInputController: audioInputController),
            transcriptionClient: openAIClient,
            transformClient: openAIClient,
            isSetupComplete: { setupController.isReady },
            onSetupRequired: { setupController.requestPresentation() }
        )
        self.scratchpadController = scratchpadController
        scratchpadWindowController = ScratchpadWindowController(
            controller: scratchpadController
        )
        hotkeyManager = HotkeyManager(
            appState: appState,
            dictationController: dictationController,
            transformController: transformController,
            commandModeController: commandModeController,
            scratchpadController: scratchpadController,
            setupController: setupController
        )
        let windowController = SettingsWindowController(
            appState: appState,
            hotkeyManager: hotkeyManager,
            historyController: historyController,
            transformController: transformController,
            scratchpadController: scratchpadController,
            setupController: setupController,
            audioInputController: audioInputController
        )
        settingsWindowController = windowController
        setupController.onPresentationRequested = { [weak windowController] in
            windowController?.show(destination: .home)
        }
        hotkeyManager.onShowTransformResult = { [weak self] in
            self?.settingsWindowController.show(destination: .transforms)
        }
    }
}
