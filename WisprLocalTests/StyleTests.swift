import AppKit
import SwiftUI
import XCTest
@testable import WisprLocal

final class WritingStyleTests: XCTestCase {
    func testAvailableStylesMatchFlowCategories() {
        XCTAssertEqual(WritingStyle.available(for: .personal), [.formal, .casual, .veryCasual])
        XCTAssertEqual(WritingStyle.available(for: .work), [.formal, .casual, .excited])
        XCTAssertEqual(WritingStyle.available(for: .email), [.formal, .casual, .excited])
        XCTAssertEqual(WritingStyle.available(for: .other), [.formal, .casual, .excited])
    }

    func testFormatterAppliesCapitalizationAndTerminalPunctuation() {
        XCTAssertEqual(
            TranscriptStyleFormatter.format("hello world", as: .formal),
            "Hello world."
        )
        XCTAssertEqual(
            TranscriptStyleFormatter.format("hello, world.", as: .casual),
            "Hello, world"
        )
        XCTAssertEqual(
            TranscriptStyleFormatter.format("Hello, world.", as: .veryCasual),
            "hello world"
        )
        XCTAssertEqual(
            TranscriptStyleFormatter.format("the update is ready.", as: .excited),
            "The update is ready!"
        )
        XCTAssertEqual(
            TranscriptStyleFormatter.format("hello. This is ready.", as: .veryCasual),
            "hello. this is ready"
        )
        XCTAssertEqual(
            TranscriptStyleFormatter.format("first update. second update.", as: .excited),
            "First update! Second update!"
        )
        XCTAssertEqual(
            TranscriptStyleFormatter.format("she said “hello”", as: .formal),
            "She said “hello.”"
        )
    }

    func testVeryCasualPreservesLeadingAcronymCapitalization() {
        XCTAssertEqual(
            TranscriptStyleFormatter.format("API responses are ready.", as: .veryCasual),
            "API responses are ready"
        )
    }

    func testFormatterPreservesDecimalsVersionsAndAbbreviations() {
        XCTAssertEqual(
            TranscriptStyleFormatter.format("Version 2.0 is ready", as: .formal),
            "Version 2.0 is ready."
        )
        XCTAssertEqual(
            TranscriptStyleFormatter.format("Release v2.1 is ready.", as: .excited),
            "Release v2.1 is ready!"
        )
        XCTAssertEqual(
            TranscriptStyleFormatter.format("Dr. Smith is here.", as: .formal),
            "Dr. Smith is here."
        )
        XCTAssertEqual(
            TranscriptStyleFormatter.format("Dr. Smith is here.", as: .excited),
            "Dr. Smith is here!"
        )
        XCTAssertEqual(
            TranscriptStyleFormatter.format("Meet at 3 p.m. tomorrow.", as: .excited),
            "Meet at 3 p.m. tomorrow!"
        )
    }

    func testFormatterLeavesListsURLsAndCodeLikeLinesUnchanged() {
        let text = "- Keep this.\nhttps://example.com/path\nlet value = { answer: 42 }"
        XCTAssertEqual(TranscriptStyleFormatter.format(text, as: .excited), text)
    }
}

final class StyleAppClassifierTests: XCTestCase {
    func testClassifiesKnownDesktopApps() {
        let context = StyleAppContext(
            bundleIdentifier: "com.apple.MobileSMS",
            applicationName: "Messages",
            documentURL: nil
        )

        XCTAssertEqual(
            StyleAppClassifier.category(for: context, preferences: .default),
            .personal
        )
    }

    func testClassifiesSupportedWebAppsByHost() {
        let context = StyleAppContext(
            bundleIdentifier: "com.apple.Safari",
            applicationName: "Safari",
            documentURL: URL(string: "https://mail.google.com/mail/u/0/#inbox")
        )

        XCTAssertEqual(
            StyleAppClassifier.category(for: context, preferences: .default),
            .email
        )
    }

    func testCustomAssignmentOverridesBuiltInCategory() {
        var preferences = StylePreferences.default
        preferences.customAssignments = [
            StyleAppAssignment(
                bundleIdentifier: "com.tinyspeck.slackmacgap",
                applicationName: "Slack",
                category: .personal
            )
        ]
        let context = StyleAppContext(
            bundleIdentifier: "COM.TINYSPECK.SLACKMACGAP",
            applicationName: "Slack",
            documentURL: nil
        )

        XCTAssertEqual(
            StyleAppClassifier.category(for: context, preferences: preferences),
            .personal
        )
    }

    func testCustomAssignmentRemovesBuiltInPresentationDuplicate() {
        var preferences = StylePreferences.default
        preferences.customAssignments = [
            StyleAppAssignment(
                bundleIdentifier: "COM.TINYSPECK.SLACKMACGAP",
                applicationName: "Slack",
                category: .personal
            )
        ]

        XCTAssertFalse(
            StyleAppCatalog.visibleApplications(
                for: .work,
                preferences: preferences
            ).contains { $0.name == "Slack" }
        )
        XCTAssertEqual(
            StyleAppCatalog.visibleApplications(
                for: .personal,
                preferences: preferences
            ).filter { $0.name == "Slack" }.count,
            0
        )
    }
}

final class StyleStoreTests: XCTestCase {
    func testVersionedStoreRoundTripsPreferences() throws {
        let preferences = StylePreferences(
            hasCompletedSetup: true,
            selections: [
                .personal: .veryCasual,
                .work: .casual,
                .email: .excited,
                .other: .formal
            ],
            customAssignments: [
                StyleAppAssignment(
                    bundleIdentifier: "com.example.notes",
                    applicationName: "Example Notes",
                    category: .work
                )
            ]
        )

        let result = StyleStore.decode(try StyleStore.encode(preferences))

        XCTAssertEqual(result.preferences, preferences)
        XCTAssertEqual(result.rejectedRecordCount, 0)
        XCTAssertFalse(result.needsMigration)
    }

    func testStoreKeepsValidRecordsWhenOneSavedRecordIsInvalid() throws {
        let storedObject: [String: Any] = [
            "version": StyleStore.currentVersion,
            "preferences": [
                "hasCompletedSetup": true,
                "selections": [
                    ["category": "personal", "style": "veryCasual"],
                    ["category": "work", "style": "casual"],
                    ["category": "email", "style": "excited"],
                    ["category": "other", "style": "formal"],
                    ["category": "unknown", "style": "formal"]
                ],
                "customAssignments": [
                    [
                        "bundleIdentifier": "com.example.notes",
                        "applicationName": "Example Notes",
                        "category": "work"
                    ],
                    [
                        "bundleIdentifier": 42,
                        "applicationName": "Invalid",
                        "category": "work"
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: storedObject)

        let result = StyleStore.decode(data)

        XCTAssertTrue(result.preferences.hasCompletedSetup)
        XCTAssertEqual(result.preferences.style(for: .personal), .veryCasual)
        XCTAssertEqual(result.preferences.style(for: .work), .casual)
        XCTAssertEqual(result.preferences.style(for: .email), .excited)
        XCTAssertEqual(
            result.preferences.customAssignments,
            [
                StyleAppAssignment(
                    bundleIdentifier: "com.example.notes",
                    applicationName: "Example Notes",
                    category: .work
                )
            ]
        )
        XCTAssertEqual(result.rejectedRecordCount, 2)
        XCTAssertTrue(result.shouldBackUpOriginal)
    }

    func testStoreReadsLegacyVersionOneAndRequestsMigration() throws {
        let storedObject: [String: Any] = [
            "version": 1,
            "preferences": [
                "hasCompletedSetup": true,
                "selections": [
                    "personal", "veryCasual",
                    "work", "casual",
                    "email", "excited",
                    "other", "formal"
                ],
                "customAssignments": []
            ]
        ]

        let result = StyleStore.decode(
            try JSONSerialization.data(withJSONObject: storedObject)
        )

        XCTAssertEqual(result.rejectedRecordCount, 0)
        XCTAssertTrue(result.needsMigration)
        XCTAssertEqual(result.preferences.style(for: .personal), .veryCasual)
    }

    @MainActor
    func testAppStatePersistsStylesAndCustomAssignments() throws {
        let suiteName = "StyleStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let state = AppState(defaults: defaults)
        var selections = StylePreferences.defaultSelections
        selections[.personal] = .veryCasual
        state.completeStyleSetup(selections: selections)
        state.assignStyleApplication(
            bundleIdentifier: "com.example.notes",
            applicationName: "Example Notes",
            to: .personal
        )

        let reloaded = AppState(defaults: defaults)

        XCTAssertTrue(reloaded.stylePreferences.hasCompletedSetup)
        XCTAssertEqual(reloaded.stylePreferences.style(for: .personal), .veryCasual)
        XCTAssertEqual(reloaded.stylePreferences.customAssignments.first?.category, .personal)
    }

    @MainActor
    func testMalformedStyleDataIsBackedUpAndRecoversDefaults() throws {
        let suiteName = "StyleStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let malformed = Data("not-json".utf8)
        defaults.set(malformed, forKey: DefaultsKeys.stylePreferences)

        let state = AppState(defaults: defaults)

        XCTAssertEqual(state.stylePreferences, .default)
        XCTAssertNotNil(state.styleRecoveryMessage)
        XCTAssertEqual(defaults.data(forKey: DefaultsKeys.styleRecovery), malformed)
    }

    @MainActor
    func testStylesStayInactiveUntilSetupAndForNonEnglishLanguage() throws {
        let suiteName = "StyleStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(defaults: defaults)
        let context = StyleAppContext(
            bundleIdentifier: "com.apple.MobileSMS",
            applicationName: "Messages",
            documentURL: nil
        )

        XCTAssertEqual(state.styledDictation("Hello there.", for: context), "Hello there.")

        var selections = StylePreferences.defaultSelections
        selections[.personal] = .veryCasual
        state.completeStyleSetup(selections: selections)
        XCTAssertEqual(state.styledDictation("Hello there.", for: context), "hello there")

        state.language = "fr"
        XCTAssertEqual(state.styledDictation("Bonjour.", for: context), "Bonjour.")

        state.language = ""
        XCTAssertEqual(
            state.styledDictation("Hola, ¿cómo estás?", for: context),
            "Hola, ¿cómo estás?"
        )
    }
}

@MainActor
final class StyleViewSmokeTests: XCTestCase {
    func testSetupViewRendersAtHubDetailSize() throws {
        let suiteName = "StyleViewSmokeTests.Setup.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(defaults: defaults)

        try capture(
            StyleView().environmentObject(state),
            name: "Styles Setup View"
        )
    }

    func testConfiguredViewRendersAtHubDetailSize() throws {
        let suiteName = "StyleViewSmokeTests.Configured.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(defaults: defaults)

        var selections = StylePreferences.defaultSelections
        selections[.personal] = .veryCasual
        selections[.work] = .casual
        selections[.email] = .excited
        state.completeStyleSetup(selections: selections)

        try capture(
            StyleView().environmentObject(state),
            name: "Styles Configured View"
        )
    }

    private func capture<V: View>(_ view: V, name: String) throws {
        let size = NSSize(width: 700, height: 640)
        let hostingView = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()
        let representation = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let image = NSImage(size: size)
        image.addRepresentation(representation)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertGreaterThan(
            try XCTUnwrap(representation.representation(using: .png, properties: [:])).count,
            10_000
        )
    }
}
