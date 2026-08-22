import Foundation

enum SnippetExpander {
    static func expand(_ text: String, using snippets: [Snippet]) -> String {
        let orderedSnippets = snippets.sorted {
            $0.normalizedTrigger.count > $1.normalizedTrigger.count
        }

        guard !text.isEmpty, !orderedSnippets.isEmpty else { return text }
        let normalizedText = text.precomposedStringWithCanonicalMapping

        let alternatives = orderedSnippets.map {
            "(" + regexPattern(for: $0.normalizedTrigger) + ")"
        }
        let combinedPattern = #"(?<![\p{L}\p{M}\p{N}_])(?:"#
            + alternatives.joined(separator: "|")
            + #")(?![\p{L}\p{M}\p{N}_])"#
        guard let expression = try? NSRegularExpression(pattern: combinedPattern, options: [.caseInsensitive]) else {
            return text
        }

        let original = normalizedText as NSString
        let matches = expression.matches(
            in: normalizedText,
            range: NSRange(location: 0, length: original.length)
        )
        guard !matches.isEmpty else { return text }

        let expanded = NSMutableString(string: normalizedText)
        for match in matches.reversed() {
            guard let alternativeIndex = (1..<match.numberOfRanges).first(where: {
                match.range(at: $0).location != NSNotFound
            }) else { continue }

            let triggerRange = match.range(at: alternativeIndex)
            let snippet = orderedSnippets[alternativeIndex - 1]
            expanded.replaceCharacters(in: triggerRange, with: snippet.expansion)
        }
        return expanded as String
    }

    private static func regexPattern(for trigger: String) -> String {
        Snippet.normalizedTrigger(trigger).precomposedStringWithCanonicalMapping
            .split(whereSeparator: \.isWhitespace)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: #"\s+"#)
    }
}
