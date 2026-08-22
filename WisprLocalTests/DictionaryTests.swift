import XCTest
@testable import WisprLocal

final class DictionaryCorrectorTests: XCTestCase {
    func testCorrectsMisspellingAsCaseInsensitiveWholePhrase() {
        let entries = [entry(word: "Draft", misspelling: "Draught")]

        let result = DictionaryCorrector.correct(
            "Use DRAUGHT, but leave draughtsmanship alone.",
            using: entries
        )

        XCTAssertEqual(result, "Use Draft, but leave draughtsmanship alone.")
    }

    func testPlainEntryRestoresExactSavedCasing() {
        let entries = [entry(word: "API")]

        let result = DictionaryCorrector.correct("The api response uses apis.", using: entries)

        XCTAssertEqual(result, "The API response uses apis.")
    }

    func testPrefersLongestOverlappingCorrectionSource() {
        let entries = [
            entry(word: "Northstar", misspelling: "north star"),
            entry(word: "Project Northstar", misspelling: "project north star")
        ]

        let result = DictionaryCorrector.correct("Open project north star.", using: entries)

        XCTAssertEqual(result, "Open Project Northstar.")
    }

    func testUsesUnicodeCaseInsensitiveMatching() {
        let entries = [entry(word: "ΟΣ")]

        let result = DictionaryCorrector.correct("ος", using: entries)

        XCTAssertEqual(result, "ΟΣ")
    }

    func testMatchesCanonicallyEquivalentUnicode() {
        let entries = [entry(word: "Café")]

        let result = DictionaryCorrector.correct("Try cafe\u{301}.", using: entries)

        XCTAssertEqual(result, "Try Café.")
    }

    func testDoesNotMatchInsideACombiningCharacterSequence() {
        let entries = [entry(word: "a")]
        let keycapSequence = "a\u{20E3}"

        let result = DictionaryCorrector.correct(keycapSequence, using: entries)

        XCTAssertEqual(result, keycapSequence)
    }

    func testDictionaryCorrectionRunsBeforeSnippetExpansion() {
        let dictionaryEntries = [entry(word: "meeting link", misspelling: "meeting ling")]
        let snippets = [
            Snippet(
                id: UUID(),
                trigger: "meeting link",
                expansion: "https://meet.example.com/dylan",
                createdAt: .distantPast,
                editedAt: .distantPast
            )
        ]

        let result = TranscriptPersonalizer.personalize(
            "Open meeting ling.",
            dictionaryEntries: dictionaryEntries,
            snippets: snippets
        )

        XCTAssertEqual(result, "Open https://meet.example.com/dylan.")
    }

    private func entry(
        word: String,
        misspelling: String? = nil,
        isStarred: Bool = false,
        editedAt: Date = .distantPast
    ) -> DictionaryEntry {
        DictionaryEntry(
            id: UUID(),
            word: word,
            misspelling: misspelling,
            isStarred: isStarred,
            createdAt: .distantPast,
            editedAt: editedAt
        )
    }
}

final class DictionaryPromptBuilderTests: XCTestCase {
    func testPromptPrioritizesStarredEntriesAndStaysBounded() throws {
        var entries = (0..<100).map { index in
            entry(
                word: "term-\(index)-\(String(repeating: "x", count: 50))",
                editedAt: Date(timeIntervalSince1970: Double(index))
            )
        }
        entries.append(entry(word: "PriorityTerm", isStarred: true, editedAt: .distantPast))

        let prompt = try XCTUnwrap(DictionaryPromptBuilder.prompt(for: entries))

        XCTAssertTrue(prompt.hasPrefix("PriorityTerm"))
        XCTAssertLessThanOrEqual(prompt.count, DictionaryPromptBuilder.characterLimit)
    }

    func testEmptyDictionaryProducesNoPrompt() {
        XCTAssertNil(DictionaryPromptBuilder.prompt(for: []))
    }

    func testOpenAIFieldsUseJSONAndIncludeVocabularyGuidance() {
        let fields = OpenAIClient.transcriptionFields(
            language: " en ",
            vocabularyPrompt: " McKenzie, API "
        )

        XCTAssertEqual(fields["model"], "gpt-4o-mini-transcribe")
        XCTAssertEqual(fields["response_format"], "json")
        XCTAssertEqual(fields["language"], "en")
        XCTAssertEqual(fields["prompt"], "McKenzie, API")
    }

    private func entry(
        word: String,
        isStarred: Bool = false,
        editedAt: Date
    ) -> DictionaryEntry {
        DictionaryEntry(
            id: UUID(),
            word: word,
            misspelling: nil,
            isStarred: isStarred,
            createdAt: editedAt,
            editedAt: editedAt
        )
    }
}

final class DictionaryStoreTests: XCTestCase {
    func testVersionedStorageRoundTripsEntries() throws {
        let original = entry(
            word: "McKenzie",
            misspelling: "Mackenzie",
            isStarred: true,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            editedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )

        let data = try DictionaryStore.encode([original])
        let result = DictionaryStore.decode(data)

        XCTAssertEqual(result.entries, [original])
        XCTAssertEqual(result.rejectedRecordCount, 0)
        XCTAssertFalse(result.needsMigration)
    }

    func testMalformedRecordDoesNotHideValidEntries() throws {
        let valid = entry(
            word: "FigJam",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            editedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let validData = try makeISO8601Encoder().encode(valid)
        let validObject = try JSONSerialization.jsonObject(with: validData)
        let root: [String: Any] = [
            "version": DictionaryStore.currentVersion,
            "entries": [validObject, ["id": "not-a-uuid"]]
        ]
        let data = try JSONSerialization.data(withJSONObject: root)

        let result = DictionaryStore.decode(data)

        XCTAssertEqual(result.entries, [valid])
        XCTAssertEqual(result.rejectedRecordCount, 1)
        XCTAssertTrue(result.shouldBackUpOriginal)
    }

    func testSemanticallyInvalidRecordsAreRejectedDuringRecovery() throws {
        let valid = entry(
            word: "Alpha",
            misspelling: "Beta",
            createdAt: Date(timeIntervalSince1970: 1),
            editedAt: Date(timeIntervalSince1970: 1)
        )
        let records = [
            valid,
            entry(word: "", createdAt: .distantPast, editedAt: .distantPast),
            entry(
                word: String(repeating: "x", count: DictionaryEntry.termCharacterLimit + 1),
                createdAt: .distantPast,
                editedAt: .distantPast
            ),
            entry(
                id: valid.id,
                word: "Duplicate identifier",
                createdAt: .distantPast,
                editedAt: .distantPast
            ),
            entry(word: "alpha", createdAt: .distantPast, editedAt: .distantPast),
            entry(
                word: "Beta",
                misspelling: "Gamma",
                createdAt: .distantPast,
                editedAt: .distantPast
            )
        ]

        let result = DictionaryStore.decode(try DictionaryStore.encode(records))

        XCTAssertEqual(result.entries, [valid])
        XCTAssertEqual(result.rejectedRecordCount, 5)
        XCTAssertTrue(result.shouldBackUpOriginal)
    }

    @MainActor
    func testAppStatePersistsStableIdentityStarAndSortPreference() throws {
        let suiteName = "DictionaryStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let state = AppState(defaults: defaults)
        let original = try state.saveDictionaryEntry(
            word: "McKenzie",
            misspelling: "Mackenzie",
            isStarred: false
        )
        state.toggleDictionaryEntryStarred(id: original.id)
        state.dictionarySortOrder = .alphabetical

        let reloadedState = AppState(defaults: defaults)
        let reloaded = try XCTUnwrap(reloadedState.dictionaryEntries.first)
        XCTAssertEqual(reloaded.id, original.id)
        XCTAssertEqual(reloaded.createdAt.timeIntervalSince1970, original.createdAt.timeIntervalSince1970, accuracy: 1)
        XCTAssertTrue(reloaded.isStarred)
        XCTAssertEqual(reloadedState.dictionarySortOrder, .alphabetical)
    }

    @MainActor
    func testAppStateRejectsDuplicateWordsAndCorrectionSources() throws {
        let suiteName = "DictionaryStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let state = AppState(defaults: defaults)
        _ = try state.saveDictionaryEntry(word: "API", misspelling: nil, isStarred: false)

        XCTAssertThrowsError(
            try state.saveDictionaryEntry(word: "api", misspelling: nil, isStarred: false)
        ) { error in
            XCTAssertEqual(error as? DictionaryValidationError, .duplicateWord)
        }

        XCTAssertThrowsError(
            try state.saveDictionaryEntry(
                word: "Application Programming Interface",
                misspelling: "api",
                isStarred: false
            )
        ) { error in
            XCTAssertEqual(error as? DictionaryValidationError, .duplicateCorrectionSource)
        }
    }

    @MainActor
    func testAppStateRejectsCrossTargetAndSourceCollisionsOnCreateAndEdit() throws {
        let suiteName = "DictionaryStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let state = AppState(defaults: defaults)
        let alpha = try state.saveDictionaryEntry(
            word: "Alpha",
            misspelling: "Beta",
            isStarred: false
        )
        let gamma = try state.saveDictionaryEntry(
            word: "Gamma",
            misspelling: "Delta",
            isStarred: false
        )

        XCTAssertThrowsError(
            try state.saveDictionaryEntry(
                word: "Beta",
                misspelling: "Epsilon",
                isStarred: false
            )
        ) { error in
            XCTAssertEqual(error as? DictionaryValidationError, .duplicateCorrectionSource)
        }

        XCTAssertThrowsError(
            try state.saveDictionaryEntry(
                word: "Epsilon",
                misspelling: "Alpha",
                isStarred: false
            )
        ) { error in
            XCTAssertEqual(error as? DictionaryValidationError, .duplicateCorrectionSource)
        }

        XCTAssertThrowsError(
            try state.saveDictionaryEntry(
                id: gamma.id,
                word: "Beta",
                misspelling: "Delta",
                isStarred: false
            )
        ) { error in
            XCTAssertEqual(error as? DictionaryValidationError, .duplicateCorrectionSource)
        }

        XCTAssertEqual(Set(state.dictionaryEntries.map(\.id)), Set([alpha.id, gamma.id]))
    }

    func testSortOrdersMatchDesktopDictionaryChoices() {
        let oldest = entry(
            word: "Zulu",
            createdAt: Date(timeIntervalSince1970: 10),
            editedAt: Date(timeIntervalSince1970: 10)
        )
        let newest = entry(
            word: "Alpha",
            createdAt: Date(timeIntervalSince1970: 30),
            editedAt: Date(timeIntervalSince1970: 30)
        )
        let starred = entry(
            word: "Middle",
            isStarred: true,
            createdAt: Date(timeIntervalSince1970: 20),
            editedAt: Date(timeIntervalSince1970: 20)
        )
        let entries = [oldest, newest, starred]

        XCTAssertEqual(DictionarySortOrder.starredFirst.sorted(entries).first?.id, starred.id)
        XCTAssertEqual(DictionarySortOrder.newestFirst.sorted(entries).first?.id, newest.id)
        XCTAssertEqual(DictionarySortOrder.oldestFirst.sorted(entries).first?.id, oldest.id)
        XCTAssertEqual(DictionarySortOrder.alphabetical.sorted(entries).map(\.word), ["Alpha", "Middle", "Zulu"])
    }

    private func entry(
        id: UUID = UUID(),
        word: String,
        misspelling: String? = nil,
        isStarred: Bool = false,
        createdAt: Date,
        editedAt: Date
    ) -> DictionaryEntry {
        DictionaryEntry(
            id: id,
            word: word,
            misspelling: misspelling,
            isStarred: isStarred,
            createdAt: createdAt,
            editedAt: editedAt
        )
    }

    private func makeISO8601Encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
