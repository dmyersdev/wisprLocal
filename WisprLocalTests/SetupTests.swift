import AppKit
import CoreAudio
import SwiftUI
import XCTest
@testable import WisprLocal

@MainActor
final class SetupControllerTests: XCTestCase {
    func testFreshInstallStartsAtWelcomeAndPersistsTheNextStep() async throws {
        let fixture = try makeSetupFixture()
        defer { fixture.cleanUp() }

        XCTAssertFalse(fixture.controller.isCompleted)
        XCTAssertEqual(fixture.controller.currentStep, .welcome)

        fixture.controller.advanceFromWelcome()
        XCTAssertEqual(fixture.controller.currentStep, .apiKey)

        let restarted = fixture.makeController()
        XCTAssertEqual(restarted.currentStep, .apiKey)
        XCTAssertFalse(restarted.isCompleted)
    }

    func testLegacyStoredKeyRequiresOneTimeValidation() async throws {
        let keyStore = InMemoryAPIKeyStore(key: "existing-key")
        let validator = StubAPIKeyValidator()
        let fixture = try makeSetupFixture(
            keyStore: keyStore,
            validator: validator,
            markStoredKeyValidated: false
        )
        defer { fixture.cleanUp() }

        XCTAssertTrue(fixture.controller.hasStoredAPIKey)
        XCTAssertFalse(fixture.controller.isStoredAPIKeyValidated)
        XCTAssertEqual(fixture.controller.currentStep, .apiKey)
        XCTAssertFalse(fixture.controller.isCompleted)
        XCTAssertEqual(keyStore.key, "existing-key")

        let validated = await fixture.controller.validateAndStoreAPIKey("")
        XCTAssertTrue(validated)
        XCTAssertEqual(validator.validatedKeys, ["existing-key"])
        XCTAssertTrue(fixture.controller.isStoredAPIKeyValidated)
        XCTAssertEqual(fixture.controller.currentStep, .permissions)
    }

    func testPersistedCompletionWithoutAKeyReturnsToCredentialEntry() throws {
        let fixture = try makeSetupFixture(configureDefaults: { defaults in
            defaults.set(true, forKey: DefaultsKeys.setupCompleted)
            defaults.set(SetupStep.language.rawValue, forKey: DefaultsKeys.setupStep)
        })
        defer { fixture.cleanUp() }

        XCTAssertFalse(fixture.controller.isCompleted)
        XCTAssertEqual(fixture.controller.currentStep, .apiKey)
    }

    func testValidKeyIsTrimmedStoredAndAdvances() async throws {
        let keyStore = InMemoryAPIKeyStore()
        let validator = StubAPIKeyValidator()
        let fixture = try makeSetupFixture(
            keyStore: keyStore,
            validator: validator
        )
        defer { fixture.cleanUp() }
        fixture.controller.advanceFromWelcome()

        let succeeded = await fixture.controller.validateAndStoreAPIKey("  project-key  \n")

        XCTAssertTrue(succeeded)
        XCTAssertEqual(validator.validatedKeys, ["project-key"])
        XCTAssertEqual(keyStore.key, "project-key")
        XCTAssertTrue(fixture.controller.hasStoredAPIKey)
        XCTAssertTrue(fixture.controller.isStoredAPIKeyValidated)
        XCTAssertEqual(
            fixture.defaults.string(forKey: DefaultsKeys.setupValidatedKeyFingerprint),
            SetupController.keyFingerprint(for: "project-key")
        )
        XCTAssertEqual(fixture.controller.currentStep, .permissions)
        XCTAssertEqual(fixture.controller.apiKeyState, .valid)
    }

    func testRejectedKeyIsNeverStored() async throws {
        let keyStore = InMemoryAPIKeyStore()
        let validator = StubAPIKeyValidator(error: APIKeyValidationError.unauthorized)
        let fixture = try makeSetupFixture(
            keyStore: keyStore,
            validator: validator
        )
        defer { fixture.cleanUp() }
        fixture.controller.advanceFromWelcome()

        let succeeded = await fixture.controller.validateAndStoreAPIKey("bad-key")

        XCTAssertFalse(succeeded)
        XCTAssertNil(keyStore.key)
        XCTAssertEqual(fixture.controller.currentStep, .apiKey)
        guard case .failed(let message) = fixture.controller.apiKeyState else {
            return XCTFail("Expected a validation failure")
        }
        XCTAssertTrue(message.contains("rejected"))
    }

    func testPermissionsBlockProgressUntilBothAreGranted() throws {
        let permissions = StubSetupPermissionService(
            microphoneStatus: .authorized,
            isAccessibilityGranted: false
        )
        let fixture = try makeSetupFixture(
            keyStore: InMemoryAPIKeyStore(key: "valid-key"),
            permissions: permissions
        )
        defer { fixture.cleanUp() }

        XCTAssertFalse(fixture.controller.advanceFromPermissions())
        XCTAssertEqual(fixture.controller.currentStep, .permissions)

        permissions.isAccessibilityGranted = true
        XCTAssertTrue(fixture.controller.advanceFromPermissions())
        XCTAssertEqual(fixture.controller.currentStep, .shortcut)
    }

    func testAccessibilityPromptMarksTheRequestAndInvokesRegistration() throws {
        let permissions = StubSetupPermissionService(isAccessibilityGranted: false)
        let fixture = try makeSetupFixture(permissions: permissions)
        defer { fixture.cleanUp() }

        fixture.controller.promptForAccessibility()

        XCTAssertTrue(fixture.controller.hasRequestedAccessibility)
        XCTAssertFalse(fixture.controller.isAccessibilityGranted)
        XCTAssertEqual(permissions.accessibilityPromptCount, 1)
    }

    func testAccessibilityRequestStateSurvivesRelaunch() throws {
        let permissions = StubSetupPermissionService(isAccessibilityGranted: false)
        let fixture = try makeSetupFixture(permissions: permissions)
        defer { fixture.cleanUp() }

        fixture.controller.promptForAccessibility()
        let restarted = fixture.makeController()

        XCTAssertTrue(restarted.hasRequestedAccessibility)
        restarted.openAccessibilitySettings()
        XCTAssertEqual(permissions.accessibilityPromptCount, 2)
        XCTAssertEqual(permissions.accessibilitySettingsOpenCount, 1)
    }

    func testOpeningAccessibilitySettingsRetriesRegistrationBeforeNavigating() throws {
        let permissions = StubSetupPermissionService(isAccessibilityGranted: false)
        let fixture = try makeSetupFixture(permissions: permissions)
        defer { fixture.cleanUp() }

        fixture.controller.promptForAccessibility()
        fixture.controller.openAccessibilitySettings()

        XCTAssertEqual(permissions.accessibilityPromptCount, 2)
        XCTAssertEqual(permissions.accessibilitySettingsOpenCount, 1)
    }

    func testOpeningAccessibilitySettingsSkipsNavigationWhenRetryIsGranted() throws {
        let permissions = StubSetupPermissionService(isAccessibilityGranted: false)
        let fixture = try makeSetupFixture(permissions: permissions)
        defer { fixture.cleanUp() }

        fixture.controller.promptForAccessibility()
        permissions.isAccessibilityGranted = true
        fixture.controller.openAccessibilitySettings()

        XCTAssertTrue(fixture.controller.isAccessibilityGranted)
        XCTAssertEqual(permissions.accessibilityPromptCount, 2)
        XCTAssertEqual(permissions.accessibilitySettingsOpenCount, 0)
    }

    func testHappyPathCompletesAndSurvivesRelaunch() throws {
        let permissions = StubSetupPermissionService(
            microphoneStatus: .authorized,
            isAccessibilityGranted: true
        )
        let fixture = try makeSetupFixture(
            keyStore: InMemoryAPIKeyStore(key: "valid-key"),
            permissions: permissions
        )
        defer { fixture.cleanUp() }

        XCTAssertTrue(fixture.controller.advanceFromPermissions())
        fixture.controller.advanceFromShortcut()
        XCTAssertTrue(fixture.controller.complete(languageCode: "EN"))

        XCTAssertTrue(fixture.controller.isCompleted)
        XCTAssertEqual(fixture.language.value, "en")
        XCTAssertTrue(fixture.defaults.bool(forKey: DefaultsKeys.setupCompleted))

        let restarted = fixture.makeController()
        XCTAssertTrue(restarted.isCompleted)
    }

    func testAutoDetectClearsTheLanguageHint() throws {
        let permissions = StubSetupPermissionService(
            microphoneStatus: .authorized,
            isAccessibilityGranted: true
        )
        let fixture = try makeSetupFixture(
            keyStore: InMemoryAPIKeyStore(key: "valid-key"),
            permissions: permissions,
            language: "fr"
        )
        defer { fixture.cleanUp() }

        XCTAssertTrue(fixture.controller.complete(languageCode: nil))
        XCTAssertEqual(fixture.language.value, "")
    }

    func testClearingTheKeyRelocksSetupAndRequestsPresentation() throws {
        let fixture = try makeSetupFixture(
            keyStore: InMemoryAPIKeyStore(key: "valid-key"),
            permissions: StubSetupPermissionService(
                microphoneStatus: .authorized,
                isAccessibilityGranted: true
            ),
            configureDefaults: { defaults in
                defaults.set(true, forKey: DefaultsKeys.setupCompleted)
            }
        )
        defer { fixture.cleanUp() }
        var presentationCount = 0
        fixture.controller.onPresentationRequested = { presentationCount += 1 }

        XCTAssertTrue(fixture.controller.clearAPIKey())

        XCTAssertFalse(fixture.controller.isCompleted)
        XCTAssertFalse(fixture.controller.hasStoredAPIKey)
        XCTAssertFalse(fixture.controller.isStoredAPIKeyValidated)
        XCTAssertEqual(fixture.controller.currentStep, .apiKey)
        XCTAssertEqual(presentationCount, 1)
        XCTAssertNil(
            fixture.defaults.string(forKey: DefaultsKeys.setupValidatedKeyFingerprint)
        )
    }

    func testCompletionCannotBypassKeyOrPermissions() throws {
        let fixture = try makeSetupFixture()
        defer { fixture.cleanUp() }

        XCTAssertFalse(fixture.controller.complete(languageCode: "en"))
        XCTAssertFalse(fixture.controller.isCompleted)
    }

    func testRevokedPermissionRelocksCompletedSetupAndSurvivesRelaunch() throws {
        let permissions = StubSetupPermissionService(
            microphoneStatus: .authorized,
            isAccessibilityGranted: true
        )
        let fixture = try makeSetupFixture(
            keyStore: InMemoryAPIKeyStore(key: "valid-key"),
            permissions: permissions,
            configureDefaults: { defaults in
                defaults.set(true, forKey: DefaultsKeys.setupCompleted)
            }
        )
        defer { fixture.cleanUp() }
        XCTAssertTrue(fixture.controller.isReady)

        permissions.microphoneStatus = .denied

        XCTAssertFalse(fixture.controller.refreshReadiness())
        XCTAssertFalse(fixture.controller.isCompleted)
        XCTAssertEqual(fixture.controller.currentStep, .permissions)
        XCTAssertFalse(fixture.defaults.bool(forKey: DefaultsKeys.setupCompleted))

        let restarted = fixture.makeController()
        XCTAssertFalse(restarted.isCompleted)
        XCTAssertEqual(restarted.currentStep, .permissions)
    }

    func testClearingKeyInvalidatesInFlightValidation() async throws {
        let validator = SuspendedAPIKeyValidator()
        let keyStore = InMemoryAPIKeyStore()
        let fixture = try makeSetupFixture(
            keyStore: keyStore,
            validator: validator
        )
        defer { fixture.cleanUp() }
        fixture.controller.advanceFromWelcome()

        let validation = Task {
            await fixture.controller.validateAndStoreAPIKey("pending-key")
        }
        await validator.waitUntilStarted()

        XCTAssertTrue(fixture.controller.clearAPIKey())
        await validator.succeed()

        let validationSucceeded = await validation.value
        XCTAssertFalse(validationSucceeded)
        XCTAssertNil(keyStore.key)
        XCTAssertFalse(fixture.controller.isStoredAPIKeyValidated)
        XCTAssertEqual(fixture.controller.apiKeyState, .idle)
    }

    func testRequireReadyPresentsSetupInsteadOfAllowingGlobalAction() throws {
        let fixture = try makeSetupFixture()
        defer { fixture.cleanUp() }
        var presentationCount = 0
        fixture.controller.onPresentationRequested = { presentationCount += 1 }

        XCTAssertFalse(fixture.controller.requireReady())
        XCTAssertEqual(presentationCount, 1)
    }
}

final class APIKeyValidationTests: XCTestCase {
    func testMapsAuthorizationAndServiceResponses() throws {
        XCTAssertNil(OpenAIAPIKeyValidator.validationError(statusCode: 200))
        XCTAssertEqual(
            OpenAIAPIKeyValidator.validationError(statusCode: 401),
            .unauthorized
        )
        XCTAssertEqual(
            OpenAIAPIKeyValidator.validationError(statusCode: 403),
            .forbidden
        )
        XCTAssertEqual(
            OpenAIAPIKeyValidator.validationError(statusCode: 429),
            .rateLimited
        )

        let data = try JSONSerialization.data(withJSONObject: [
            "error": ["message": "Service unavailable"]
        ])
        XCTAssertEqual(
            OpenAIAPIKeyValidator.validationError(
                statusCode: 503,
                responseData: data
            ),
            .service("Service unavailable")
        )
    }

    func testLanguageCatalogIsUniqueSearchableAndUsesISOHints() {
        let codes = LanguageCatalog.options.map(\.code)

        XCTAssertGreaterThanOrEqual(codes.count, 90)
        XCTAssertEqual(Set(codes).count, codes.count)
        XCTAssertTrue(codes.allSatisfy { $0.count == 2 && $0 == $0.lowercased() })
        XCTAssertEqual(LanguageCatalog.option(for: "EN")?.code, "en")
        XCTAssertEqual(LanguageCatalog.search("english").map(\.code), ["en"])
    }
}

@MainActor
final class SetupDictationGateTests: XCTestCase {
    func testDictationDoesNotTouchTheMicrophoneBeforeSetupCompletes() throws {
        let suiteName = "SetupDictationGateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(defaults: defaults)
        let recorder = CountingAudioRecorder()
        var presentationCount = 0
        let controller = DictationController(
            appState: state,
            recorder: recorder,
            client: NoOpTranscriptionClient(),
            injector: NoOpTextInjector(),
            appContextProvider: NoOpStyleContextProvider(),
            isSetupComplete: { false },
            onSetupRequired: { presentationCount += 1 }
        )

        controller.startRecording()

        XCTAssertEqual(recorder.startCount, 0)
        XCTAssertEqual(presentationCount, 1)
        XCTAssertEqual(
            state.state,
            .error(AppError.setupIncomplete.localizedDescription)
        )
    }
}

@MainActor
final class SetupViewSmokeTests: XCTestCase {
    func testWelcomeStepRendersAtHubWindowSize() throws {
        let fixture = try makeSetupFixture()
        defer { fixture.cleanUp() }
        let state = AppState(defaults: fixture.defaults)
        let size = NSSize(width: 920, height: 640)
        let hostingView = NSHostingView(
            rootView: SetupView(
                controller: fixture.controller,
                currentHotkey: .defaultCarbon,
                updateHotkey: { $0 },
                onFinished: {}
            )
            .environmentObject(state)
            .frame(width: size.width, height: size.height)
        )
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let representation = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let image = NSImage(size: size)
        image.addRepresentation(representation)
        let attachment = XCTAttachment(image: image)
        attachment.name = "Flow-style First-run Setup"
        attachment.lifetime = .keepAlways
        add(attachment)

        let pngData = try XCTUnwrap(
            representation.representation(using: .png, properties: [:])
        )
        try pngData.write(
            to: URL(fileURLWithPath: "/tmp/wisprlocal-first-run-setup.png"),
            options: .atomic
        )
        XCTAssertGreaterThan(pngData.count, 10_000)
    }

    func testMicrophonePermissionStepRendersLiveInputPanel() throws {
        let fixture = try makeSetupFixture(
            keyStore: InMemoryAPIKeyStore(key: "valid-key"),
            permissions: StubSetupPermissionService(
                microphoneStatus: .authorized,
                isAccessibilityGranted: true
            ),
            configureDefaults: { defaults in
                defaults.set(SetupStep.permissions.rawValue, forKey: DefaultsKeys.setupStep)
            }
        )
        defer { fixture.cleanUp() }
        XCTAssertEqual(fixture.controller.currentStep, .permissions)

        let appState = AppState(defaults: fixture.defaults)
        let inputController = AudioInputController(
            provider: SetupPreviewAudioInputProvider(),
            monitor: SetupPreviewAudioLevelMonitor(),
            defaults: fixture.defaults,
            isMicrophoneAuthorized: { true }
        )
        let size = NSSize(width: 920, height: 640)
        let hostingView = NSHostingView(
            rootView: SetupView(
                controller: fixture.controller,
                currentHotkey: .defaultCarbon,
                updateHotkey: { $0 },
                onFinished: {}
            )
            .environmentObject(appState)
            .environmentObject(inputController)
            .frame(width: size.width, height: size.height)
        )
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let representation = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let image = NSImage(size: size)
        image.addRepresentation(representation)
        let attachment = XCTAttachment(image: image)
        attachment.name = "Flow-style Microphone Setup"
        attachment.lifetime = .keepAlways
        add(attachment)

        let pngData = try XCTUnwrap(
            representation.representation(using: .png, properties: [:])
        )
        try pngData.write(
            to: URL(fileURLWithPath: "/tmp/wisprlocal-microphone-setup.png"),
            options: .atomic
        )
        XCTAssertGreaterThan(pngData.count, 10_000)
    }

    func testShortcutStepRendersPushToTalkAndHandsFreeGuidance() throws {
        let fixture = try makeSetupFixture(
            keyStore: InMemoryAPIKeyStore(key: "valid-key"),
            permissions: StubSetupPermissionService(
                microphoneStatus: .authorized,
                isAccessibilityGranted: true
            ),
            configureDefaults: { defaults in
                defaults.set(SetupStep.shortcut.rawValue, forKey: DefaultsKeys.setupStep)
            }
        )
        defer { fixture.cleanUp() }
        XCTAssertEqual(fixture.controller.currentStep, .shortcut)

        let appState = AppState(defaults: fixture.defaults)
        let size = NSSize(width: 920, height: 640)
        let hostingView = NSHostingView(
            rootView: SetupView(
                controller: fixture.controller,
                currentHotkey: .fnAlone,
                updateHotkey: { $0 },
                onFinished: {}
            )
            .environmentObject(appState)
            .frame(width: size.width, height: size.height)
        )
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let representation = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let image = NSImage(size: size)
        image.addRepresentation(representation)
        let attachment = XCTAttachment(image: image)
        attachment.name = "Push-to-talk and Hands-free Setup"
        attachment.lifetime = .keepAlways
        add(attachment)

        let pngData = try XCTUnwrap(
            representation.representation(using: .png, properties: [:])
        )
        try pngData.write(
            to: URL(fileURLWithPath: "/tmp/wisprlocal-hands-free-setup.png"),
            options: .atomic
        )
        XCTAssertGreaterThan(pngData.count, 10_000)
    }
}

private struct SetupPreviewAudioInputProvider: AudioInputDeviceProviding {
    func snapshot() throws -> AudioInputSnapshot {
        AudioInputSnapshot(
            devices: [
                AudioInputDevice(
                    id: "preview-microphone",
                    audioDeviceID: 1,
                    name: "MacBook Microphone"
                )
            ],
            defaultDeviceID: 1
        )
    }
}

private final class SetupPreviewAudioLevelMonitor: AudioLevelMonitoring {
    func startMonitoring(
        deviceID: AudioDeviceID,
        levelHandler: @escaping @MainActor @Sendable (Float) -> Void
    ) throws {
        levelHandler(0.62)
    }

    func stopMonitoring() {}
}

@MainActor
private struct SetupFixture {
    let suiteName: String
    let defaults: UserDefaults
    let keyStore: InMemoryAPIKeyStore
    let validator: APIKeyValidating
    let permissions: StubSetupPermissionService
    let language: LanguageBox
    let controller: SetupController

    func makeController() -> SetupController {
        SetupController(
            defaults: defaults,
            keyStore: keyStore,
            keyValidator: validator,
            permissions: permissions,
            languageProvider: { language.value },
            languageSetter: { language.value = $0 }
        )
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
private func makeSetupFixture(
    keyStore: InMemoryAPIKeyStore = InMemoryAPIKeyStore(),
    validator: APIKeyValidating = StubAPIKeyValidator(),
    permissions: StubSetupPermissionService? = nil,
    language: String = "",
    markStoredKeyValidated: Bool = true,
    configureDefaults: (UserDefaults) -> Void = { _ in }
) throws -> SetupFixture {
    let suiteName = "SetupFixture.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    configureDefaults(defaults)
    if markStoredKeyValidated, let key = keyStore.key?.trimmedOrNil {
        defaults.set(
            SetupController.keyFingerprint(for: key),
            forKey: DefaultsKeys.setupValidatedKeyFingerprint
        )
    }
    let languageBox = LanguageBox(language)
    let resolvedPermissions = permissions ?? StubSetupPermissionService()
    let controller = SetupController(
        defaults: defaults,
        keyStore: keyStore,
        keyValidator: validator,
        permissions: resolvedPermissions,
        languageProvider: { languageBox.value },
        languageSetter: { languageBox.value = $0 }
    )
    return SetupFixture(
        suiteName: suiteName,
        defaults: defaults,
        keyStore: keyStore,
        validator: validator,
        permissions: resolvedPermissions,
        language: languageBox,
        controller: controller
    )
}

private final class InMemoryAPIKeyStore: APIKeyStoring {
    var key: String?

    init(key: String? = nil) {
        self.key = key
    }

    func saveAPIKey(_ key: String) throws {
        self.key = key
    }

    func loadAPIKey() throws -> String? {
        key
    }

    func deleteAPIKey() throws {
        key = nil
    }
}

private final class StubAPIKeyValidator: APIKeyValidating {
    private let error: Error?
    private(set) var validatedKeys: [String] = []

    init(error: Error? = nil) {
        self.error = error
    }

    func validate(apiKey: String) async throws {
        validatedKeys.append(apiKey)
        if let error { throw error }
    }
}

private actor SuspendedAPIKeyValidator: APIKeyValidating {
    private var isStarted = false
    private var validationContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func validate(apiKey: String) async throws {
        isStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            validationContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !isStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func succeed() {
        validationContinuation?.resume()
        validationContinuation = nil
    }
}

@MainActor
private final class StubSetupPermissionService: SetupPermissionServing {
    var microphoneStatus: SetupAuthorizationStatus
    var isAccessibilityGranted: Bool
    private(set) var microphoneSettingsOpenCount = 0
    private(set) var accessibilityPromptCount = 0
    private(set) var accessibilitySettingsOpenCount = 0

    init(
        microphoneStatus: SetupAuthorizationStatus = .notDetermined,
        isAccessibilityGranted: Bool = false
    ) {
        self.microphoneStatus = microphoneStatus
        self.isAccessibilityGranted = isAccessibilityGranted
    }

    func requestMicrophoneAccess() async -> SetupAuthorizationStatus {
        microphoneStatus
    }

    func promptForAccessibility() -> Bool {
        accessibilityPromptCount += 1
        return isAccessibilityGranted
    }

    func openMicrophoneSettings() {
        microphoneSettingsOpenCount += 1
    }

    func openAccessibilitySettings() {
        accessibilitySettingsOpenCount += 1
    }
}

private final class LanguageBox {
    var value: String

    init(_ value: String) {
        self.value = value
    }
}

@MainActor
private final class CountingAudioRecorder: AudioRecording {
    private(set) var startCount = 0

    func startRecording() async throws {
        startCount += 1
    }

    func stopRecording() throws -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("unused.wav")
    }

    func cancelRecording() {}
}

private final class NoOpTranscriptionClient: TranscriptionServing {
    func transcribe(
        fileURL: URL,
        language: String?,
        vocabularyPrompt: String?
    ) async throws -> String {
        ""
    }

    func polishTranscript(text: String) async throws -> PolishResult {
        PolishResult(text: text, promptTokens: 0, completionTokens: 0)
    }
}

@MainActor
private final class NoOpTextInjector: TextInjecting {
    func insert(text: String, pressEnter: Bool) async throws {}
    func copy(text: String) throws {}
}

@MainActor
private final class NoOpStyleContextProvider: StyleAppContextProviding {
    func currentContext() async -> StyleAppContext {
        StyleAppContext(
            bundleIdentifier: nil,
            applicationName: nil,
            documentURL: nil
        )
    }
}
