import AppKit
@preconcurrency import ApplicationServices
import AVFoundation
import CryptoKit
import Foundation

protocol APIKeyStoring: AnyObject {
    func saveAPIKey(_ key: String) throws
    func loadAPIKey() throws -> String?
    func deleteAPIKey() throws
}

protocol APIKeyValidating: AnyObject {
    func validate(apiKey: String) async throws
}

enum APIKeyValidationError: LocalizedError, Equatable {
    case empty
    case unauthorized
    case forbidden
    case rateLimited
    case service(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Enter an OpenAI API key to continue."
        case .unauthorized:
            return "OpenAI rejected this key. Check that you copied the complete key."
        case .forbidden:
            return "This key is valid but does not have permission to use the OpenAI API."
        case .rateLimited:
            return "OpenAI is temporarily rate limiting this key. Wait a moment, then try again."
        case .service(let message):
            return "OpenAI could not validate this key: \(message)"
        case .network(let message):
            return "Could not reach OpenAI: \(message)"
        }
    }
}

final class OpenAIAPIKeyValidator: APIKeyValidating {
    private let session: URLSession
    private let endpoint: URL

    convenience init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        self.init(session: URLSession(configuration: configuration))
    }

    init(
        session: URLSession,
        endpoint: URL = URL(string: "https://api.openai.com/v1/models")!
    ) {
        self.session = session
        self.endpoint = endpoint
    }

    func validate(apiKey: String) async throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw APIKeyValidationError.empty }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw APIKeyValidationError.service("OpenAI returned an invalid response.")
            }
            if let error = Self.validationError(
                statusCode: response.statusCode,
                responseData: data
            ) {
                throw error
            }
        } catch let error as APIKeyValidationError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw APIKeyValidationError.network(error.localizedDescription)
        }
    }

    static func validationError(
        statusCode: Int,
        responseData: Data = Data()
    ) -> APIKeyValidationError? {
        switch statusCode {
        case 200..<300:
            return nil
        case 401:
            return .unauthorized
        case 403:
            return .forbidden
        case 429:
            return .rateLimited
        default:
            let message = openAIErrorMessage(from: responseData)
                ?? "the service returned HTTP \(statusCode)."
            return .service(message)
        }
    }

    private static func openAIErrorMessage(from data: Data) -> String? {
        struct ErrorEnvelope: Decodable {
            struct APIError: Decodable {
                let message: String
            }

            let error: APIError
        }

        return (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?
            .error.message.trimmedOrNil
    }
}

enum SetupAuthorizationStatus: String, Equatable {
    case notDetermined
    case authorized
    case denied
    case restricted

    var isAuthorized: Bool { self == .authorized }
}

enum AccessibilityTrust {
    static func isProcessTrusted(prompt: Bool) -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}

@MainActor
protocol SetupPermissionServing: AnyObject {
    var microphoneStatus: SetupAuthorizationStatus { get }
    var isAccessibilityGranted: Bool { get }

    func requestMicrophoneAccess() async -> SetupAuthorizationStatus
    @discardableResult func promptForAccessibility() -> Bool
    func openMicrophoneSettings()
    func openAccessibilitySettings()
}

@MainActor
final class SystemSetupPermissionService: SetupPermissionServing {
    var microphoneStatus: SetupAuthorizationStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            return .notDetermined
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        @unknown default:
            return .restricted
        }
    }

    var isAccessibilityGranted: Bool {
        AccessibilityTrust.isProcessTrusted(prompt: false)
    }

    func requestMicrophoneAccess() async -> SetupAuthorizationStatus {
        guard microphoneStatus == .notDetermined else { return microphoneStatus }
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        return microphoneStatus
    }

    @discardableResult
    func promptForAccessibility() -> Bool {
        AccessibilityTrust.isProcessTrusted(prompt: true)
    }

    func openMicrophoneSettings() {
        openPrivacyPane(anchor: "Privacy_Microphone")
    }

    func openAccessibilitySettings() {
        openPrivacyPane(anchor: "Privacy_Accessibility")
    }

    private func openPrivacyPane(anchor: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

enum SetupStep: String, CaseIterable, Identifiable {
    case welcome
    case apiKey
    case permissions
    case shortcut
    case language

    var id: Self { self }

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .apiKey: return "API key"
        case .permissions: return "Permissions"
        case .shortcut: return "Shortcut"
        case .language: return "Language"
        }
    }

    var systemImage: String {
        switch self {
        case .welcome: return "sparkles"
        case .apiKey: return "key"
        case .permissions: return "checkmark.shield"
        case .shortcut: return "keyboard"
        case .language: return "globe"
        }
    }

    var progressIndex: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }
}

enum APIKeySetupState: Equatable {
    case idle
    case validating
    case valid
    case failed(String)

    var isValidating: Bool { self == .validating }
}

@MainActor
final class SetupController: ObservableObject {
    static let currentPersistenceVersion = 1

    @Published private(set) var currentStep: SetupStep = .welcome
    @Published private(set) var isCompleted = false
    @Published private(set) var hasStoredAPIKey = false
    @Published private(set) var isStoredAPIKeyValidated = false
    @Published private(set) var apiKeyState: APIKeySetupState = .idle
    @Published private(set) var microphoneStatus: SetupAuthorizationStatus = .notDetermined
    @Published private(set) var isAccessibilityGranted = false
    @Published private(set) var hasRequestedAccessibility = false

    var onPresentationRequested: (() -> Void)?

    private let defaults: UserDefaults
    private let keyStore: APIKeyStoring
    private let keyValidator: APIKeyValidating
    private let permissions: SetupPermissionServing
    private let languageProvider: () -> String
    private let languageSetter: (String) -> Void
    private var validationGeneration = 0

    init(
        defaults: UserDefaults = .standard,
        keyStore: APIKeyStoring,
        keyValidator: APIKeyValidating,
        permissions: SetupPermissionServing,
        languageProvider: @escaping () -> String,
        languageSetter: @escaping (String) -> Void
    ) {
        self.defaults = defaults
        self.keyStore = keyStore
        self.keyValidator = keyValidator
        self.permissions = permissions
        self.languageProvider = languageProvider
        self.languageSetter = languageSetter

        let storedKey: String?
        do {
            storedKey = try keyStore.loadAPIKey()?.trimmedOrNil
        } catch {
            storedKey = nil
            apiKeyState = .failed(error.localizedDescription)
        }
        hasStoredAPIKey = storedKey != nil
        isStoredAPIKeyValidated = storedKey.map {
            defaults.string(forKey: DefaultsKeys.setupValidatedKeyFingerprint)
                == Self.keyFingerprint(for: $0)
        } ?? false

        let storedStep = defaults.string(forKey: DefaultsKeys.setupStep)
            .flatMap(SetupStep.init(rawValue:))
        let persistedCompletion = defaults.bool(forKey: DefaultsKeys.setupCompleted)
        hasRequestedAccessibility = defaults.bool(
            forKey: DefaultsKeys.setupAccessibilityRequested
        )

        if persistedCompletion, hasStoredAPIKey, isStoredAPIKeyValidated {
            isCompleted = true
            currentStep = storedStep ?? .welcome
        } else {
            isCompleted = false
            currentStep = storedStep
                ?? (hasStoredAPIKey
                    ? (isStoredAPIKeyValidated ? .permissions : .apiKey)
                    : .welcome)
            if !isStoredAPIKeyValidated,
               currentStep.progressIndex > SetupStep.apiKey.progressIndex {
                currentStep = .apiKey
            }
        }

        refreshPermissions()
        persistState()
    }

    var isPermissionStepComplete: Bool {
        microphoneStatus.isAuthorized && isAccessibilityGranted
    }

    var isReady: Bool {
        isCompleted
            && hasStoredAPIKey
            && isStoredAPIKeyValidated
            && isPermissionStepComplete
    }

    var selectedLanguageCode: String? {
        languageProvider().trimmedOrNil
    }

    var suggestedLanguageCode: String? {
        if let selectedLanguageCode,
           LanguageCatalog.option(for: selectedLanguageCode) != nil {
            return selectedLanguageCode
        }
        return LanguageCatalog.suggestedLanguageCode
    }

    func advanceFromWelcome() {
        move(to: isStoredAPIKeyValidated ? .permissions : .apiKey)
    }

    @discardableResult
    func advanceFromAPIKey() -> Bool {
        guard hasStoredAPIKey, isStoredAPIKeyValidated else { return false }
        move(to: .permissions)
        return true
    }

    @discardableResult
    func validateAndStoreAPIKey(_ input: String) async -> Bool {
        guard !apiKeyState.isValidating else { return false }
        let enteredKey = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingKey = (try? keyStore.loadAPIKey()) ?? nil
        let key: String
        let shouldReplaceStoredKey: Bool
        if !enteredKey.isEmpty {
            key = enteredKey
            shouldReplaceStoredKey = true
        } else if let storedKey = existingKey?.trimmedOrNil {
            key = storedKey
            shouldReplaceStoredKey = false
        } else {
            apiKeyState = .failed(APIKeyValidationError.empty.localizedDescription)
            return false
        }

        validationGeneration += 1
        let generation = validationGeneration
        apiKeyState = .validating
        do {
            try await keyValidator.validate(apiKey: key)
            try Task.checkCancellation()
            guard generation == validationGeneration else { return false }
            if shouldReplaceStoredKey {
                try keyStore.saveAPIKey(key)
            }
            guard generation == validationGeneration else { return false }
            defaults.set(
                Self.keyFingerprint(for: key),
                forKey: DefaultsKeys.setupValidatedKeyFingerprint
            )
            hasStoredAPIKey = true
            isStoredAPIKeyValidated = true
            apiKeyState = .valid
            if currentStep == .apiKey {
                move(to: .permissions)
            }
            return true
        } catch is CancellationError {
            if generation == validationGeneration {
                apiKeyState = .idle
            }
            return false
        } catch {
            if generation == validationGeneration {
                apiKeyState = .failed(error.localizedDescription)
            }
            return false
        }
    }

    @discardableResult
    func clearAPIKey() -> Bool {
        validationGeneration += 1
        do {
            try keyStore.deleteAPIKey()
            defaults.removeObject(forKey: DefaultsKeys.setupValidatedKeyFingerprint)
            hasStoredAPIKey = false
            isStoredAPIKeyValidated = false
            apiKeyState = .idle
            isCompleted = false
            move(to: .apiKey)
            requestPresentation()
            return true
        } catch {
            apiKeyState = .failed(error.localizedDescription)
            return false
        }
    }

    func refreshStoredAPIKey() {
        do {
            let storedKey = try keyStore.loadAPIKey()?.trimmedOrNil
            hasStoredAPIKey = storedKey != nil
            isStoredAPIKeyValidated = storedKey.map {
                defaults.string(forKey: DefaultsKeys.setupValidatedKeyFingerprint)
                    == Self.keyFingerprint(for: $0)
            } ?? false
            reconcileCompletion()
        } catch {
            apiKeyState = .failed(error.localizedDescription)
        }
    }

    func refreshPermissions() {
        microphoneStatus = permissions.microphoneStatus
        isAccessibilityGranted = permissions.isAccessibilityGranted
        reconcileCompletion()
    }

    @discardableResult
    func refreshReadiness() -> Bool {
        refreshStoredAPIKey()
        refreshPermissions()
        return isReady
    }

    @discardableResult
    func requireReady() -> Bool {
        guard refreshReadiness() else {
            requestPresentation()
            return false
        }
        return true
    }

    func requestMicrophoneAccess() async {
        microphoneStatus = await permissions.requestMicrophoneAccess()
    }

    func promptForAccessibility() {
        hasRequestedAccessibility = true
        persistState()
        isAccessibilityGranted = permissions.promptForAccessibility()
    }

    func openMicrophoneSettings() {
        permissions.openMicrophoneSettings()
    }

    func openAccessibilitySettings() {
        hasRequestedAccessibility = true
        persistState()
        isAccessibilityGranted = permissions.promptForAccessibility()
        if !isAccessibilityGranted {
            permissions.openAccessibilitySettings()
        }
    }

    @discardableResult
    func advanceFromPermissions() -> Bool {
        refreshPermissions()
        guard isPermissionStepComplete else { return false }
        move(to: .shortcut)
        return true
    }

    func advanceFromShortcut() {
        move(to: .language)
    }

    @discardableResult
    func complete(languageCode: String?) -> Bool {
        refreshStoredAPIKey()
        refreshPermissions()
        guard hasStoredAPIKey,
              isStoredAPIKeyValidated,
              isPermissionStepComplete else { return false }
        let normalizedCode = languageCode?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedCode,
           !normalizedCode.isEmpty,
           LanguageCatalog.option(for: normalizedCode) == nil {
            return false
        }

        languageSetter(normalizedCode?.lowercased() ?? "")
        isCompleted = true
        currentStep = .welcome
        apiKeyState = .idle
        persistState()
        return true
    }

    func beginReview() {
        currentStep = .welcome
        apiKeyState = .idle
        refreshPermissions()
        persistState()
    }

    func goBack() {
        guard let index = SetupStep.allCases.firstIndex(of: currentStep), index > 0 else {
            return
        }
        move(to: SetupStep.allCases[index - 1])
    }

    func requestPresentation() {
        onPresentationRequested?()
    }

    private func move(to step: SetupStep) {
        currentStep = step
        persistState()
    }

    private func persistState() {
        defaults.set(Self.currentPersistenceVersion, forKey: DefaultsKeys.setupVersion)
        defaults.set(currentStep.rawValue, forKey: DefaultsKeys.setupStep)
        defaults.set(isCompleted, forKey: DefaultsKeys.setupCompleted)
        defaults.set(
            hasRequestedAccessibility,
            forKey: DefaultsKeys.setupAccessibilityRequested
        )
    }

    private func reconcileCompletion() {
        guard isCompleted else { return }
        if !hasStoredAPIKey || !isStoredAPIKeyValidated {
            isCompleted = false
            currentStep = .apiKey
            persistState()
        } else if !isPermissionStepComplete {
            isCompleted = false
            currentStep = .permissions
            persistState()
        }
    }

    static func keyFingerprint(for key: String) -> String {
        SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct LanguageOption: Identifiable, Equatable {
    let code: String
    let name: String

    var id: String { code }
}

enum LanguageCatalog {
    // OpenAI accepts ISO-639-1 language hints. This list mirrors the broad
    // language set exposed by Whisper-family transcription models.
    private static let supportedCodes = [
        "af", "am", "ar", "as", "az", "ba", "be", "bg", "bn", "bo",
        "br", "bs", "ca", "cs", "cy", "da", "de", "el", "en", "es",
        "et", "eu", "fa", "fi", "fo", "fr", "gl", "gu", "ha",
        "he", "hi", "hr", "ht", "hu", "hy", "id", "is", "it", "ja",
        "jw", "ka", "kk", "km", "kn", "ko", "la", "lb", "ln", "lo",
        "lt", "lv", "mg", "mi", "mk", "ml", "mn", "mr", "ms", "mt",
        "my", "ne", "nl", "nn", "no", "oc", "pa", "pl", "ps", "pt",
        "ro", "ru", "sa", "sd", "si", "sk", "sl", "sn", "so", "sq",
        "sr", "su", "sv", "sw", "ta", "te", "tg", "th", "tk", "tl",
        "tr", "tt", "uk", "ur", "uz", "vi", "yi", "yo", "zh"
    ]

    static let options: [LanguageOption] = supportedCodes
        .map { code in
            let localizedName = Locale.autoupdatingCurrent.localizedString(
                forLanguageCode: code
            )
            return LanguageOption(
                code: code,
                name: localizedName?.capitalized(with: Locale.autoupdatingCurrent)
                    ?? code.uppercased()
            )
        }
        .sorted { first, second in
            first.name.localizedCaseInsensitiveCompare(second.name) == .orderedAscending
        }

    static var suggestedLanguageCode: String? {
        for identifier in Locale.preferredLanguages {
            let code = Locale(identifier: identifier)
                .language.languageCode?.identifier.lowercased()
            if let code, option(for: code) != nil {
                return code
            }
        }
        return nil
    }

    static func option(for code: String) -> LanguageOption? {
        let normalized = code.lowercased()
        return options.first { $0.code == normalized }
    }

    static func search(_ query: String) -> [LanguageOption] {
        guard let query = query.trimmedOrNil else { return options }
        return options.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.code.localizedCaseInsensitiveContains(query)
        }
    }
}
