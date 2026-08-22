import XCTest
@testable import WisprLocal

final class SnippetExpanderTests: XCTestCase {
    func testExpandsWholePhraseCaseInsensitively() {
        let snippets = [snippet(trigger: "my address", expansion: "123 Main Street")]

        let result = SnippetExpander.expand("Send it to MY ADDRESS, please.", using: snippets)

        XCTAssertEqual(result, "Send it to 123 Main Street, please.")
    }

    func testDoesNotExpandTriggerInsideLongerWords() {
        let snippets = [snippet(trigger: "cat", expansion: "dog")]

        let result = SnippetExpander.expand("Concatenate the category, then say cat.", using: snippets)

        XCTAssertEqual(result, "Concatenate the category, then say dog.")
    }

    func testPrefersLongestOverlappingTrigger() {
        let snippets = [
            snippet(trigger: "link", expansion: "short"),
            snippet(trigger: "meeting link", expansion: "https://meet.example.com/dylan")
        ]

        let result = SnippetExpander.expand("Open my meeting link.", using: snippets)

        XCTAssertEqual(result, "Open my https://meet.example.com/dylan.")
    }

    func testMatchesNormalizedWhitespace() {
        let snippets = [snippet(trigger: "my email signature", expansion: "Best,\nDylan")]

        let result = SnippetExpander.expand("Use my   email\nsignature", using: snippets)

        XCTAssertEqual(result, "Use Best,\nDylan")
    }

    func testDoesNotRecursivelyExpandInsertedText() {
        let snippets = [
            snippet(trigger: "my greeting", expansion: "meeting link"),
            snippet(trigger: "meeting link", expansion: "https://meet.example.com")
        ]

        let result = SnippetExpander.expand("my greeting", using: snippets)

        XCTAssertEqual(result, "meeting link")
    }

    func testUsesUnicodeCaseInsensitiveMatchForGreekFinalSigma() {
        let snippets = [snippet(trigger: "ΟΣ", expansion: "matched")]

        let result = SnippetExpander.expand("ος", using: snippets)

        XCTAssertEqual(result, "matched")
    }

    func testMatchesCanonicallyEquivalentUnicode() {
        let snippets = [snippet(trigger: "Café", expansion: "matched")]

        let result = SnippetExpander.expand("cafe\u{301}", using: snippets)

        XCTAssertEqual(result, "matched")
    }

    func testDoesNotMatchInsideACombiningCharacterSequence() {
        let snippets = [snippet(trigger: "a", expansion: "matched")]
        let keycapSequence = "a\u{20E3}"

        let result = SnippetExpander.expand(keycapSequence, using: snippets)

        XCTAssertEqual(result, keycapSequence)
    }

    private func snippet(trigger: String, expansion: String) -> Snippet {
        Snippet(
            id: UUID(),
            trigger: trigger,
            expansion: expansion,
            createdAt: .distantPast,
            editedAt: .distantPast
        )
    }
}

final class SnippetStoreTests: XCTestCase {
    @MainActor
    func testEditingSnippetPreservesIdentityAndCreationDateAcrossReload() throws {
        let suiteName = "SnippetStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let state = AppState(defaults: defaults)
        let original = try state.saveSnippet(trigger: "my address", expansion: "123 Main Street")
        let edited = try state.saveSnippet(
            id: original.id,
            trigger: "my home address",
            expansion: "456 Oak Avenue"
        )

        XCTAssertEqual(edited.id, original.id)
        XCTAssertEqual(edited.createdAt, original.createdAt)
        XCTAssertGreaterThanOrEqual(edited.editedAt, original.editedAt)

        let reloadedState = AppState(defaults: defaults)
        let reloaded = try XCTUnwrap(reloadedState.snippets.first)
        XCTAssertEqual(reloaded.id, edited.id)
        XCTAssertEqual(reloaded.trigger, edited.trigger)
        XCTAssertEqual(reloaded.expansion, edited.expansion)
        XCTAssertEqual(reloaded.createdAt.timeIntervalSince1970, edited.createdAt.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(reloaded.editedAt.timeIntervalSince1970, edited.editedAt.timeIntervalSince1970, accuracy: 1)
    }

    func testVersionedStorageRoundTripsStableIdentifiersAndDates() throws {
        let original = Snippet(
            id: UUID(),
            trigger: "my address",
            expansion: "123 Main Street",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            editedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )

        let data = try SnippetStore.encode([original])
        let result = SnippetStore.decode(data)

        XCTAssertEqual(result.snippets, [original])
        XCTAssertEqual(result.rejectedRecordCount, 0)
        XCTAssertFalse(result.needsMigration)
    }

    func testMalformedRecordDoesNotHideValidRecords() throws {
        let valid = Snippet(
            id: UUID(),
            trigger: "my email",
            expansion: "dylan@example.com",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            editedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let validData = try JSONEncoder.iso8601.encode(valid)
        let validObject = try JSONSerialization.jsonObject(with: validData)
        let root: [String: Any] = [
            "version": SnippetStore.currentVersion,
            "snippets": [validObject, ["id": "not-a-uuid"]]
        ]
        let data = try JSONSerialization.data(withJSONObject: root)

        let result = SnippetStore.decode(data)

        XCTAssertEqual(result.snippets, [valid])
        XCTAssertEqual(result.rejectedRecordCount, 1)
        XCTAssertTrue(result.shouldBackUpOriginal)
    }

    @MainActor
    func testAppStateMigratesLegacyStorageAndPreservesRecoveryBackup() throws {
        let suiteName = "SnippetStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let valid = Snippet(
            id: UUID(),
            trigger: "my phone",
            expansion: "555-0100",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            editedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let validData = try JSONEncoder.iso8601.encode(valid)
        let validObject = try JSONSerialization.jsonObject(with: validData)
        let legacyData = try JSONSerialization.data(withJSONObject: [validObject, ["broken": true]])
        defaults.set(legacyData, forKey: DefaultsKeys.snippets)

        let state = AppState(defaults: defaults)

        XCTAssertEqual(state.snippets, [valid])
        XCTAssertNotNil(state.snippetRecoveryMessage)
        XCTAssertEqual(defaults.data(forKey: DefaultsKeys.snippetsRecovery), legacyData)

        _ = try state.saveSnippet(trigger: "my address", expansion: "123 Main Street")
        XCTAssertEqual(defaults.data(forKey: DefaultsKeys.snippetsRecovery), legacyData)
        XCTAssertEqual(SnippetStore.decode(try XCTUnwrap(defaults.data(forKey: DefaultsKeys.snippets))).snippets.count, 2)
    }
}

private extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
