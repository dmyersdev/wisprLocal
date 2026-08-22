import Foundation

struct Snippet: Identifiable, Codable, Equatable {
    static let triggerCharacterLimit = 60
    static let expansionCharacterLimit = 4_000

    let id: UUID
    let trigger: String
    let expansion: String
    let createdAt: Date
    let editedAt: Date

    static func normalizedTrigger(_ trigger: String) -> String {
        trigger
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    var normalizedTrigger: String {
        Self.normalizedTrigger(trigger)
    }
}

struct DictionaryEntry: Identifiable, Codable, Equatable {
    static let termCharacterLimit = 60

    let id: UUID
    let word: String
    let misspelling: String?
    let isStarred: Bool
    let createdAt: Date
    let editedAt: Date

    static func normalizedTerm(_ term: String) -> String {
        term
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .precomposedStringWithCanonicalMapping
    }

    var normalizedWord: String {
        Self.normalizedTerm(word)
    }

    var normalizedMisspelling: String? {
        guard let misspelling else { return nil }
        let normalized = Self.normalizedTerm(misspelling)
        return normalized.isEmpty ? nil : normalized
    }

    var correctionSource: String {
        normalizedMisspelling ?? normalizedWord
    }
}

enum DictionarySortOrder: String, CaseIterable, Identifiable, Codable {
    case starredFirst
    case newestFirst
    case oldestFirst
    case alphabetical

    var id: Self { self }

    var title: String {
        switch self {
        case .starredFirst: return "Starred first"
        case .newestFirst: return "Newest first"
        case .oldestFirst: return "Oldest first"
        case .alphabetical: return "Alphabetical"
        }
    }

    func sorted(_ entries: [DictionaryEntry]) -> [DictionaryEntry] {
        entries.sorted { first, second in
            switch self {
            case .starredFirst:
                if first.isStarred != second.isStarred {
                    return first.isStarred
                }
                return first.editedAt > second.editedAt
            case .newestFirst:
                return first.createdAt > second.createdAt
            case .oldestFirst:
                return first.createdAt < second.createdAt
            case .alphabetical:
                return first.word.localizedCaseInsensitiveCompare(second.word) == .orderedAscending
            }
        }
    }
}

enum DictionaryValidationError: LocalizedError, Equatable {
    case emptyWord
    case emptyMisspelling
    case wordTooLong
    case misspellingTooLong
    case duplicateWord
    case duplicateCorrectionSource
    case duplicateIdentifier

    var errorDescription: String? {
        switch self {
        case .emptyWord:
            return "Please enter a word or short phrase."
        case .emptyMisspelling:
            return "Enter the spelling WisprLocal should correct."
        case .wordTooLong:
            return "Dictionary entries can be up to \(DictionaryEntry.termCharacterLimit) characters."
        case .misspellingTooLong:
            return "Misspellings can be up to \(DictionaryEntry.termCharacterLimit) characters."
        case .duplicateWord:
            return "This word is already in your dictionary."
        case .duplicateCorrectionSource:
            return "Another dictionary entry already uses this spelling."
        case .duplicateIdentifier:
            return "This dictionary entry conflicts with another saved entry."
        }
    }
}

enum SnippetValidationError: LocalizedError, Equatable {
    case emptyTrigger
    case emptyExpansion
    case triggerTooLong
    case expansionTooLong
    case duplicateTrigger

    var errorDescription: String? {
        switch self {
        case .emptyTrigger:
            return "Please enter a snippet trigger."
        case .emptyExpansion:
            return "Please enter a snippet expansion."
        case .triggerTooLong:
            return "Snippet triggers can be up to \(Snippet.triggerCharacterLimit) characters."
        case .expansionTooLong:
            return "Snippet expansions can be up to \(Snippet.expansionCharacterLimit) characters."
        case .duplicateTrigger:
            return "A snippet with this trigger already exists."
        }
    }
}

enum InjectionMethod: String, CaseIterable, Identifiable, Codable {
    case clipboardPaste

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .clipboardPaste: return "Clipboard Paste"
        }
    }
}

enum AppError: LocalizedError {
    case setupIncomplete
    case missingAPIKey
    case microphonePermissionDenied
    case recordingFailed(String)
    case transcriptionFailed(String)
    case network(String)
    case unauthorized
    case forbidden
    case fileTooLarge
    case accessibilityDenied
    case pasteboardUnavailable
    case clipboardCannotBePreserved
    case noTextSelected
    case selectionCaptureUnavailable
    case transformSelectionTooLong
    case selectedTextChanged
    case transformFailed(String)
    case transformReturnedNoText
    case transformInProgress
    case transformUnavailableWhileDictating
    case transformUndoUnavailable
    case commandModeDisabled
    case commandInProgress
    case commandUnavailableWhileBusy
    case commandSelectionTooLong
    case commandTargetChanged
    case commandFailed(String)
    case commandReturnedNoText
    case hotkeyUnavailable(String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .setupIncomplete:
            return "Finish WisprLocal setup before starting dictation."
        case .missingAPIKey:
            return "Missing OpenAI API key. Add it in Settings."
        case .microphonePermissionDenied:
            return "Microphone permission denied. Enable it in System Settings."
        case .recordingFailed(let message):
            return "Recording failed: \(message)"
        case .transcriptionFailed(let message):
            return "Transcription failed: \(message)"
        case .network(let message):
            return "Network error: \(message)"
        case .unauthorized:
            return "Unauthorized (401). Check your API key."
        case .forbidden:
            return "Forbidden (403). Check your API key permissions."
        case .fileTooLarge:
            return "Audio too large. Try a shorter dictation."
        case .accessibilityDenied:
            return "Accessibility permission is required to paste into other apps."
        case .pasteboardUnavailable:
            return "The clipboard is unavailable. Your latest transcript is still saved in WisprLocal."
        case .clipboardCannotBePreserved:
            return "WisprLocal left your text unchanged because the current clipboard content can’t be restored safely. Copy or remove that clipboard item, then try again."
        case .noTextSelected:
            return "Select text before running a transform."
        case .selectionCaptureUnavailable:
            return "WisprLocal couldn’t read the selection without replacing unsupported clipboard content."
        case .transformSelectionTooLong:
            return "Transforms support selections from 1 to 1,000 words."
        case .selectedTextChanged:
            return "The selected text or focused app changed before the transform finished. Nothing was replaced."
        case .transformFailed(let message):
            return "Transform failed: \(message)"
        case .transformReturnedNoText:
            return "The transform returned no text. Your original selection was left unchanged."
        case .transformInProgress:
            return "Another transform is already running."
        case .transformUnavailableWhileDictating:
            return "Transforms aren’t available while dictation, Command Mode, or another text action is active."
        case .transformUndoUnavailable:
            return "WisprLocal couldn’t safely edit the original result. Make sure the original editor is still open and the transformed text is unchanged, then try again."
        case .commandModeDisabled:
            return "Command mode is toggled off"
        case .commandInProgress:
            return "Another command is already running."
        case .commandUnavailableWhileBusy:
            return "Command Mode isn’t available while dictation or another text action is active."
        case .commandSelectionTooLong:
            return "Command Mode supports selections from 1 to 1,000 words."
        case .commandTargetChanged:
            return "The target text field or cursor changed before the command finished. Nothing was inserted."
        case .commandFailed(let message):
            return "Command failed: \(message)"
        case .commandReturnedNoText:
            return "The command returned no text. Nothing was changed."
        case .hotkeyUnavailable(let message):
            return message
        case .unknown(let message):
            return "Error: \(message)"
        }
    }
}

struct TextPolisher {
    static func polish(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        result = result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\s+([,.;:!?])", with: "$1", options: .regularExpression)
        if let first = result.first {
            let upper = String(first).uppercased()
            result.replaceSubrange(result.startIndex...result.startIndex, with: upper)
        }
        return result
    }
}

enum DefaultsKeys {
    static let audioInputDeviceUID = "wispr.audio.inputDeviceUID"
    static let audioInputDeviceName = "wispr.audio.inputDeviceName"
    static let setupVersion = "wispr.setup.version"
    static let setupStep = "wispr.setup.step"
    static let setupCompleted = "wispr.setup.completed"
    static let setupAccessibilityRequested = "wispr.setup.accessibilityRequested"
    static let setupValidatedKeyFingerprint = "wispr.setup.validatedKeyFingerprint"
    static let language = "wispr.language"
    static let polishEnabled = "wispr.polishEnabled"
    static let history = "wispr.history"
    static let historyRecovery = "wispr.history.recovery"
    static let hotkey = "wispr.hotkey"
    static let handsFreeHotkey = "wispr.handsFreeHotkey"
    static let holdToTalk = "wispr.holdToTalk"
    static let tokensSent = "wispr.tokensSent"
    static let tokensReceived = "wispr.tokensReceived"
    static let snippets = "wispr.snippets"
    static let snippetsRecovery = "wispr.snippets.recovery"
    static let dictionaryEntries = "wispr.dictionary.entries"
    static let dictionaryRecovery = "wispr.dictionary.recovery"
    static let dictionarySortOrder = "wispr.dictionary.sortOrder"
    static let stylePreferences = "wispr.styles.preferences"
    static let styleRecovery = "wispr.styles.recovery"
    static let pressEnterEnabled = "wispr.pressEnterEnabled"
    static let transformSettings = "wispr.transforms.settings"
    static let transformRecovery = "wispr.transforms.recovery"
    static let commandModeEnabled = "wispr.commandModeEnabled"
}

enum DictationRecordingMode: Equatable {
    case pushToTalk
    case handsFree
}

extension String {
    var trimmedOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
