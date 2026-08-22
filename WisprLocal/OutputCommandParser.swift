import Foundation

struct DictationOutputCommand: Equatable {
    let text: String
    let pressesEnter: Bool
}

enum OutputCommandParser {
    private static let pressEnterExpression = try! NSRegularExpression(
        pattern: #"(?:^|\s)[\"'“”]?press\s+enter[\"'“”]?[\s.!?]*$"#,
        options: [.caseInsensitive]
    )

    static func parse(_ text: String, pressEnterEnabled: Bool) -> DictationOutputCommand {
        guard pressEnterEnabled, !text.isEmpty else {
            return DictationOutputCommand(text: text, pressesEnter: false)
        }

        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = pressEnterExpression.firstMatch(in: text, range: fullRange),
              let removalRange = Range(match.range, in: text) else {
            return DictationOutputCommand(text: text, pressesEnter: false)
        }

        let outputText = String(text[..<removalRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return DictationOutputCommand(text: outputText, pressesEnter: true)
    }
}
