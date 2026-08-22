import Foundation

enum DictionaryEntryValidator {
    struct NormalizedValues {
        let word: String
        let misspelling: String?
    }

    static func validate(
        word: String,
        misspelling: String?,
        against entries: [DictionaryEntry]
    ) throws -> NormalizedValues {
        let normalizedWord = DictionaryEntry.normalizedTerm(word)
        let normalizedMisspelling = misspelling
            .map(DictionaryEntry.normalizedTerm(_:))
            .flatMap { $0.isEmpty ? nil : $0 }

        guard !normalizedWord.isEmpty else {
            throw DictionaryValidationError.emptyWord
        }
        guard normalizedWord.count <= DictionaryEntry.termCharacterLimit else {
            throw DictionaryValidationError.wordTooLong
        }
        if misspelling != nil, normalizedMisspelling == nil {
            throw DictionaryValidationError.emptyMisspelling
        }
        if let normalizedMisspelling,
           normalizedMisspelling.count > DictionaryEntry.termCharacterLimit {
            throw DictionaryValidationError.misspellingTooLong
        }

        guard !entries.contains(where: {
            termsAreEqual($0.normalizedWord, normalizedWord)
        }) else {
            throw DictionaryValidationError.duplicateWord
        }

        let proposedSource = normalizedMisspelling ?? normalizedWord
        let hasAmbiguousMapping = entries.contains { entry in
            termsAreEqual(entry.correctionSource, proposedSource)
                || termsAreEqual(entry.normalizedWord, proposedSource)
                || termsAreEqual(entry.correctionSource, normalizedWord)
        }
        guard !hasAmbiguousMapping else {
            throw DictionaryValidationError.duplicateCorrectionSource
        }

        return NormalizedValues(word: normalizedWord, misspelling: normalizedMisspelling)
    }

    static func validated(
        _ entry: DictionaryEntry,
        against entries: [DictionaryEntry]
    ) throws -> DictionaryEntry {
        guard !entries.contains(where: { $0.id == entry.id }) else {
            throw DictionaryValidationError.duplicateIdentifier
        }

        let normalized = try validate(
            word: entry.word,
            misspelling: entry.misspelling,
            against: entries
        )
        return DictionaryEntry(
            id: entry.id,
            word: normalized.word,
            misspelling: normalized.misspelling,
            isStarred: entry.isStarred,
            createdAt: entry.createdAt,
            editedAt: entry.editedAt
        )
    }

    private static func termsAreEqual(_ first: String, _ second: String) -> Bool {
        first.caseInsensitiveCompare(second) == .orderedSame
    }
}

enum DictionaryStore {
    static let currentVersion = 1

    struct LoadResult {
        let entries: [DictionaryEntry]
        let rejectedRecordCount: Int
        let needsMigration: Bool

        var shouldBackUpOriginal: Bool {
            rejectedRecordCount > 0
        }
    }

    private struct Envelope: Codable {
        let version: Int
        let entries: [DictionaryEntry]
    }

    static func encode(_ entries: [DictionaryEntry]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Envelope(version: currentVersion, entries: entries))
    }

    static func decode(_ data: Data) -> LoadResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            return LoadResult(entries: [], rejectedRecordCount: 1, needsMigration: false)
        }

        let records: [Any]
        let needsMigration: Bool
        if let envelope = root as? [String: Any] {
            guard let version = envelope["version"] as? Int,
                  version == currentVersion,
                  let entries = envelope["entries"] as? [Any] else {
                return LoadResult(entries: [], rejectedRecordCount: 1, needsMigration: false)
            }
            records = entries
            needsMigration = false
        } else if let legacyEntries = root as? [Any] {
            records = legacyEntries
            needsMigration = true
        } else {
            return LoadResult(entries: [], rejectedRecordCount: 1, needsMigration: false)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var decodedEntries: [DictionaryEntry] = []
        var rejectedRecordCount = 0

        for record in records {
            guard JSONSerialization.isValidJSONObject(record),
                  let recordData = try? JSONSerialization.data(withJSONObject: record),
                  let entry = try? decoder.decode(DictionaryEntry.self, from: recordData),
                  let validatedEntry = try? DictionaryEntryValidator.validated(
                    entry,
                    against: decodedEntries
                  ) else {
                rejectedRecordCount += 1
                continue
            }
            decodedEntries.append(validatedEntry)
        }

        return LoadResult(
            entries: decodedEntries.sorted { $0.editedAt > $1.editedAt },
            rejectedRecordCount: rejectedRecordCount,
            needsMigration: needsMigration
        )
    }
}

enum DictionaryPromptBuilder {
    static let characterLimit = 4_000

    static func prompt(for entries: [DictionaryEntry]) -> String? {
        let orderedEntries = entries.sorted { first, second in
            if first.isStarred != second.isStarred {
                return first.isStarred
            }
            if first.editedAt != second.editedAt {
                return first.editedAt > second.editedAt
            }
            return first.word.localizedCaseInsensitiveCompare(second.word) == .orderedAscending
        }

        var words: [String] = []
        var characterCount = 0
        for entry in orderedEntries {
            let word = entry.normalizedWord
            guard !word.isEmpty else { continue }

            let separatorCount = words.isEmpty ? 0 : 2
            guard characterCount + separatorCount + word.count <= characterLimit else {
                continue
            }
            words.append(word)
            characterCount += separatorCount + word.count
        }
        return words.joined(separator: ", ").trimmedOrNil
    }
}

enum DictionaryCorrector {
    static func correct(_ text: String, using entries: [DictionaryEntry]) -> String {
        let orderedEntries = entries.sorted {
            $0.correctionSource.count > $1.correctionSource.count
        }
        guard !text.isEmpty, !orderedEntries.isEmpty else { return text }
        let normalizedText = text.precomposedStringWithCanonicalMapping

        let alternatives = orderedEntries.map {
            "(" + regexPattern(for: $0.correctionSource) + ")"
        }
        let combinedPattern = #"(?<![\p{L}\p{M}\p{N}_])(?:"#
            + alternatives.joined(separator: "|")
            + #")(?![\p{L}\p{M}\p{N}_])"#
        guard let expression = try? NSRegularExpression(
            pattern: combinedPattern,
            options: [.caseInsensitive]
        ) else {
            return text
        }

        let original = normalizedText as NSString
        let matches = expression.matches(
            in: normalizedText,
            range: NSRange(location: 0, length: original.length)
        )
        guard !matches.isEmpty else { return text }

        let corrected = NSMutableString(string: normalizedText)
        for match in matches.reversed() {
            guard let alternativeIndex = (1..<match.numberOfRanges).first(where: {
                match.range(at: $0).location != NSNotFound
            }) else { continue }

            corrected.replaceCharacters(
                in: match.range(at: alternativeIndex),
                with: orderedEntries[alternativeIndex - 1].word
            )
        }
        return corrected as String
    }

    private static func regexPattern(for term: String) -> String {
        DictionaryEntry.normalizedTerm(term)
            .split(whereSeparator: \.isWhitespace)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: #"\s+"#)
    }
}

enum TranscriptPersonalizer {
    static func personalize(
        _ text: String,
        dictionaryEntries: [DictionaryEntry],
        snippets: [Snippet]
    ) -> String {
        let correctedText = DictionaryCorrector.correct(text, using: dictionaryEntries)
        return SnippetExpander.expand(correctedText, using: snippets)
    }
}
