import Foundation

struct HistoryItem: Identifiable, Codable, Equatable {
    let id: UUID
    let date: Date
    let text: String
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
    case missingAPIKey
    case microphonePermissionDenied
    case recordingFailed(String)
    case transcriptionFailed(String)
    case network(String)
    case unauthorized
    case forbidden
    case fileTooLarge
    case accessibilityDenied
    case hotkeyUnavailable(String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
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
    static let language = "wispr.language"
    static let polishEnabled = "wispr.polishEnabled"
    static let history = "wispr.history"
    static let hotkey = "wispr.hotkey"
    static let holdToTalk = "wispr.holdToTalk"
    static let tokensSent = "wispr.tokensSent"
    static let tokensReceived = "wispr.tokensReceived"
}

extension String {
    var trimmedOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
