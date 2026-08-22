import AppKit
import Carbon
import XCTest
@testable import WisprLocal

final class CancelShortcutPolicyTests: XCTestCase {
    func testEscapePassesThroughWhenNoDictationCanBeCancelled() {
        XCTAssertFalse(
            CancelShortcutPolicy.shouldConsume(
                keyCode: Int64(kVK_Escape),
                canCancel: false
            )
        )
    }

    func testEscapeIsConsumedOnlyWhileDictationCanBeCancelled() {
        XCTAssertTrue(
            CancelShortcutPolicy.shouldConsume(
                keyCode: Int64(kVK_Escape),
                canCancel: true
            )
        )
        XCTAssertFalse(
            CancelShortcutPolicy.shouldConsume(
                keyCode: Int64(kVK_Return),
                canCancel: true
            )
        )
    }
}

final class DictationShortcutPolicyTests: XCTestCase {
    func testOnlyShortPressesWaitForASecondTap() {
        XCTAssertTrue(DictationShortcutPolicy.shouldAwaitSecondTap(pressDuration: 0.2))
        XCTAssertTrue(DictationShortcutPolicy.shouldAwaitSecondTap(pressDuration: 0.35))
        XCTAssertFalse(DictationShortcutPolicy.shouldAwaitSecondTap(pressDuration: 0.36))
    }

    func testSecondTapMustArriveInsideTheLockWindow() {
        XCTAssertTrue(
            DictationShortcutPolicy.isSecondTap(
                firstReleaseTime: 10,
                secondPressTime: 10.28
            )
        )
        XCTAssertFalse(
            DictationShortcutPolicy.isSecondTap(
                firstReleaseTime: 10,
                secondPressTime: 10.281
            )
        )
    }
}

final class OpenAIAudioContentTypeTests: XCTestCase {
    func testM4AUsesAnAllowlistedAudioContentType() {
        XCTAssertEqual(
            OpenAIClient.audioContentType(for: URL(fileURLWithPath: "/tmp/take.m4a")),
            "audio/mp4"
        )
    }

    func testLegacyWAVKeepsItsAudioContentTypeForHistoryRetries() {
        XCTAssertEqual(
            OpenAIClient.audioContentType(for: URL(fileURLWithPath: "/tmp/take.wav")),
            "audio/wav"
        )
    }
}

@MainActor
final class HandsFreePreferenceTests: XCTestCase {
    func testDefaultsUsePushToTalkAndPersistTheHandsFreeFallback() throws {
        let suiteName = "HandsFreePreferenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)

        let initialState = AppState(defaults: defaults)
        XCTAssertTrue(initialState.holdToTalk)
        XCTAssertEqual(initialState.handsFreeHotkey, .handsFreeDefault)

        let custom = Hotkey(
            kind: .carbon,
            keyCode: UInt16(kVK_F8),
            modifiers: [.control, .shift]
        )
        initialState.handsFreeHotkey = custom

        let reloadedState = AppState(defaults: defaults)
        XCTAssertEqual(reloadedState.handsFreeHotkey, custom)
    }
}

final class OutputCommandParserTests: XCTestCase {
    func testRemovesTerminalPressEnterCaseInsensitively() {
        let result = OutputCommandParser.parse(
            "Hello world. PRESS ENTER.",
            pressEnterEnabled: true
        )

        XCTAssertEqual(result, DictationOutputCommand(text: "Hello world.", pressesEnter: true))
    }

    func testPressEnterAloneProducesReturnOnlyCommand() {
        let result = OutputCommandParser.parse("Press enter!", pressEnterEnabled: true)

        XCTAssertEqual(result, DictationOutputCommand(text: "", pressesEnter: true))
    }

    func testQuotedPressEnterIsRecognized() {
        let result = OutputCommandParser.parse(
            "Send it now “press enter”",
            pressEnterEnabled: true
        )

        XCTAssertEqual(result, DictationOutputCommand(text: "Send it now", pressesEnter: true))
    }

    func testEmbeddedPressEnterRemainsLiteral() {
        let text = "Please press enter after the form loads."

        let result = OutputCommandParser.parse(text, pressEnterEnabled: true)

        XCTAssertEqual(result, DictationOutputCommand(text: text, pressesEnter: false))
    }

    func testDisabledCommandLeavesTerminalPhraseLiteral() {
        let text = "Hello world. Press enter."

        let result = OutputCommandParser.parse(text, pressEnterEnabled: false)

        XCTAssertEqual(result, DictationOutputCommand(text: text, pressesEnter: false))
    }
}

@MainActor
final class SystemPasteboardTests: XCTestCase {
    func testSnapshotsAndRestoresCommonMultiItemClipboardData() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let firstItem = NSPasteboardItem()
        firstItem.setString("Original text", forType: .string)
        firstItem.setData(try XCTUnwrap("<b>Original text</b>".data(using: .utf8)), forType: .html)
        let secondItem = NSPasteboardItem()
        secondItem.setString("Second item", forType: .string)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([firstItem, secondItem]))

        let controller = SystemPasteboard(pasteboard: pasteboard)
        let snapshot = try XCTUnwrap(controller.snapshot())
        let temporaryChangeCount = try XCTUnwrap(controller.writeTemporaryText("Dictated text"))

        XCTAssertEqual(pasteboard.string(forType: .string), "Dictated text")
        XCTAssertNotNil(pasteboard.data(forType: SystemPasteboard.concealedType))
        XCTAssertTrue(
            controller.restore(snapshot, ifChangeCountMatches: temporaryChangeCount)
        )
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 2)
        XCTAssertEqual(pasteboard.pasteboardItems?.first?.string(forType: .string), "Original text")
        XCTAssertEqual(
            pasteboard.pasteboardItems?.first?.data(forType: .html),
            "<b>Original text</b>".data(using: .utf8)
        )
        XCTAssertEqual(pasteboard.pasteboardItems?.last?.string(forType: .string), "Second item")
    }

    func testRestoreDoesNotOverwriteInterveningClipboardChange() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("Original", forType: .string)
        let controller = SystemPasteboard(pasteboard: pasteboard)
        let snapshot = try XCTUnwrap(controller.snapshot())
        let temporaryChangeCount = try XCTUnwrap(controller.writeTemporaryText("Dictated"))

        pasteboard.clearContents()
        pasteboard.setString("User copied this", forType: .string)

        XCTAssertFalse(
            controller.restore(snapshot, ifChangeCountMatches: temporaryChangeCount)
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "User copied this")
    }

    func testExcludedFileClipboardIsNotPartiallySnapshotted() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let fileItem = NSPasteboardItem()
        fileItem.setString("file:///tmp/example.txt", forType: .fileURL)
        fileItem.setString("example.txt", forType: .string)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([fileItem]))

        XCTAssertNil(SystemPasteboard(pasteboard: pasteboard).snapshot())
    }
}

@MainActor
final class TextInjectorTests: XCTestCase {
    func testInsertPastesThenPressesReturnAndRestoresOwnedClipboard() async throws {
        let snapshot = PasteboardSnapshot(items: [
            .init(representations: [
                .init(typeIdentifier: NSPasteboard.PasteboardType.string.rawValue, data: Data("Before".utf8))
            ])
        ])
        let pasteboard = FakePasteboard(snapshot: snapshot)
        let events = FakeKeyboardEventPoster()
        let injector = TextInjector(
            pasteboard: pasteboard,
            eventPoster: events,
            accessibilityAuthorizer: FakeAccessibilityAuthorizer(isAllowed: true),
            pasteConsumptionDelay: {}
        )

        try await injector.insert(text: "After", pressEnter: true)

        XCTAssertEqual(events.events, [.paste, .return])
        XCTAssertEqual(pasteboard.temporaryText, "After")
        XCTAssertEqual(pasteboard.restoredSnapshot, snapshot)
    }

    func testReturnOnlyCommandDoesNotTouchClipboard() async throws {
        let pasteboard = FakePasteboard(snapshot: .init(items: []))
        let events = FakeKeyboardEventPoster()
        let injector = TextInjector(
            pasteboard: pasteboard,
            eventPoster: events,
            accessibilityAuthorizer: FakeAccessibilityAuthorizer(isAllowed: true),
            pasteConsumptionDelay: {}
        )

        try await injector.insert(text: "", pressEnter: true)

        XCTAssertEqual(events.events, [.return])
        XCTAssertNil(pasteboard.temporaryText)
        XCTAssertNil(pasteboard.restoredSnapshot)
    }

    func testAccessibilityFailureDoesNotTouchClipboardOrKeyboard() async {
        let pasteboard = FakePasteboard(snapshot: .init(items: []))
        let events = FakeKeyboardEventPoster()
        let injector = TextInjector(
            pasteboard: pasteboard,
            eventPoster: events,
            accessibilityAuthorizer: FakeAccessibilityAuthorizer(isAllowed: false),
            pasteConsumptionDelay: {}
        )

        do {
            try await injector.insert(text: "Never pasted", pressEnter: false)
            XCTFail("Expected accessibility failure")
        } catch AppError.accessibilityDenied {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(events.events.isEmpty)
        XCTAssertNil(pasteboard.temporaryText)
    }

    func testUnsupportedClipboardIsNeverOverwritten() async {
        let pasteboard = FakePasteboard(snapshot: nil)
        let events = FakeKeyboardEventPoster()
        let injector = TextInjector(
            pasteboard: pasteboard,
            eventPoster: events,
            accessibilityAuthorizer: FakeAccessibilityAuthorizer(isAllowed: true),
            pasteConsumptionDelay: {}
        )

        do {
            try await injector.insert(text: "Must not be pasted", pressEnter: false)
            XCTFail("Expected safe clipboard failure")
        } catch AppError.clipboardCannotBePreserved {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertNil(pasteboard.temporaryText)
        XCTAssertTrue(events.events.isEmpty)
    }

    func testTargetDriftBeforePasteRestoresClipboardWithoutPostingKeys() async {
        let snapshot = PasteboardSnapshot(items: [
            .init(representations: [
                .init(
                    typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
                    data: Data("Before".utf8)
                )
            ])
        ])
        let pasteboard = FakePasteboard(snapshot: snapshot)
        let events = FakeKeyboardEventPoster()
        let injector = TextInjector(
            pasteboard: pasteboard,
            eventPoster: events,
            accessibilityAuthorizer: FakeAccessibilityAuthorizer(isAllowed: true),
            pasteConsumptionDelay: {}
        )

        do {
            try await injector.insert(
                text: "Must stay out of the new target",
                pressEnter: false,
                validatingTarget: { throw AppError.commandTargetChanged }
            )
            XCTFail("Expected target drift failure")
        } catch AppError.commandTargetChanged {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertTrue(events.events.isEmpty)
        XCTAssertEqual(pasteboard.restoredSnapshot, snapshot)
    }
}

@MainActor
final class DictationControllerTests: XCTestCase {
    func testHandsFreeToggleStartsAndStopsTheSameOperation() async throws {
        let fixture = try makeFixture()

        fixture.controller.toggleHandsFree()
        await waitUntil { fixture.state.state == .listening }

        XCTAssertEqual(fixture.state.activeDictationMode, .handsFree)
        fixture.controller.toggleHandsFree()
        await waitUntil { fixture.client.isWaitingForTranscription }

        XCTAssertEqual(fixture.state.state, .transcribing)
        XCTAssertNil(fixture.state.activeDictationMode)
        fixture.controller.cancelCurrentDictation()
    }

    func testHandsFreeCanLockARecordingWhileRecorderStartupIsPending() async throws {
        let suiteName = "DictationPendingStartTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(defaults: defaults)
        state.polishEnabled = false
        let recorder = SuspendedStartAudioRecorder()
        let client = SuspendedTranscriptionClient()
        let controller = DictationController(
            appState: state,
            recorder: recorder,
            client: client,
            injector: FakeTextInjector(),
            appContextProvider: FakeStyleAppContextProvider(
                context: StyleAppContext(
                    bundleIdentifier: "com.example.Editor",
                    applicationName: "Editor",
                    documentURL: nil
                )
            )
        )

        controller.startRecording(mode: .pushToTalk)
        await waitUntil { recorder.isWaitingToStart }
        controller.toggleHandsFree()
        recorder.finishStarting()
        await waitUntil { state.state == .listening }

        XCTAssertEqual(state.activeDictationMode, .handsFree)
        controller.toggleHandsFree()
        await waitUntil { client.isWaitingForTranscription }
        XCTAssertEqual(recorder.stopCount, 1)
        controller.cancelCurrentDictation()
    }

    func testReleaseDuringRecorderStartupStopsAfterStartupCompletes() async throws {
        let suiteName = "DictationPendingReleaseTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(defaults: defaults)
        state.polishEnabled = false
        let recorder = SuspendedStartAudioRecorder()
        let client = SuspendedTranscriptionClient()
        let controller = DictationController(
            appState: state,
            recorder: recorder,
            client: client,
            injector: FakeTextInjector(),
            appContextProvider: FakeStyleAppContextProvider(
                context: StyleAppContext(
                    bundleIdentifier: "com.example.Editor",
                    applicationName: "Editor",
                    documentURL: nil
                )
            )
        )

        controller.startRecording(mode: .pushToTalk)
        await waitUntil { recorder.isWaitingToStart }
        controller.stopAndTranscribe()
        recorder.finishStarting()
        await waitUntil { client.isWaitingForTranscription }

        XCTAssertEqual(recorder.stopCount, 1)
        XCTAssertEqual(state.state, .transcribing)
        controller.cancelCurrentDictation()
    }

    func testSessionWarnsThenStopsAtTheConfiguredLimit() async throws {
        let fixture = try makeFixture(
            sessionLimits: DictationSessionLimits(
                warningAfter: 0.02,
                maximumDuration: 0.06
            )
        )
        fixture.controller.startRecording(mode: .handsFree)
        await waitUntil { fixture.state.dictationSessionWarning == "1 min left" }

        XCTAssertEqual(fixture.state.activeDictationMode, .handsFree)
        await waitUntil { fixture.client.isWaitingForTranscription }
        XCTAssertEqual(fixture.state.state, .transcribing)
        XCTAssertNil(fixture.state.dictationSessionWarning)
        fixture.controller.cancelCurrentDictation()
    }

    func testCancelledSessionTimerCannotWarnANewerOperation() async throws {
        let fixture = try makeFixture(
            sessionLimits: DictationSessionLimits(
                warningAfter: 0.2,
                maximumDuration: 0.5
            )
        )
        fixture.controller.startRecording()
        await waitUntil { fixture.state.state == .listening }
        try await Task.sleep(nanoseconds: 100_000_000)
        fixture.controller.cancelCurrentDictation()

        fixture.controller.startRecording()
        await waitUntil { fixture.state.state == .listening }
        try await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertEqual(fixture.state.state, .listening)
        XCTAssertNil(fixture.state.dictationSessionWarning)
        fixture.controller.cancelCurrentDictation()
    }

    func testCancelWhileListeningStopsRecorderWithoutHistoryOrPaste() async throws {
        let fixture = try makeFixture()
        fixture.controller.startRecording()
        await waitUntil { fixture.state.state == .listening }

        fixture.controller.cancelCurrentDictation()

        XCTAssertEqual(fixture.state.state, .idle)
        XCTAssertTrue(fixture.recorder.wasCancelled)
        XCTAssertTrue(fixture.state.history.isEmpty)
        XCTAssertTrue(fixture.injector.insertions.isEmpty)
    }

    func testCancelDuringTranscriptionInvalidatesLateResponseAndRetainsRetryAudio() async throws {
        let fixture = try makeFixture()
        fixture.controller.startRecording()
        await waitUntil { fixture.state.state == .listening }
        fixture.controller.stopAndTranscribe()
        await waitUntil { fixture.client.isWaitingForTranscription }

        fixture.controller.cancelCurrentDictation()
        fixture.client.finishTranscription(with: "Late response")
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(fixture.state.state, .idle)
        XCTAssertEqual(fixture.state.history.count, 1)
        XCTAssertEqual(fixture.state.history.first?.status, .failed)
        XCTAssertEqual(
            fixture.state.history.first?.errorMessage,
            "Dictation was canceled before transcription finished."
        )
        XCTAssertNotNil(fixture.state.history.first?.audioFilename)
        XCTAssertTrue(fixture.injector.insertions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.recorder.recordingURL.path))
    }

    func testTerminalPressEnterFlowsThroughPersonalizationHistoryAndInsertion() async throws {
        let fixture = try makeFixture()
        fixture.controller.startRecording()
        await waitUntil { fixture.state.state == .listening }
        fixture.controller.stopAndTranscribe()
        await waitUntil { fixture.client.isWaitingForTranscription }

        fixture.client.finishTranscription(with: "Hello world. Press enter.")
        await waitUntil { fixture.injector.insertions.count == 1 }

        XCTAssertEqual(
            fixture.injector.insertions,
            [.init(text: "Hello world.", pressEnter: true)]
        )
        XCTAssertEqual(fixture.state.history.map(\.text), ["Hello world."])
        XCTAssertEqual(fixture.state.lastTranscript, "Hello world.")
        XCTAssertEqual(fixture.state.state, .idle)
    }

    func testCopyAndPasteLastTranscriptDoNotDuplicateHistory() async throws {
        let fixture = try makeFixture()
        fixture.state.lastTranscript = "Recover me"

        fixture.controller.copyLastTranscript()
        fixture.controller.pasteLastTranscript()
        await waitUntil { fixture.injector.insertions.count == 1 }

        XCTAssertEqual(fixture.injector.copiedTexts, ["Recover me"])
        XCTAssertEqual(
            fixture.injector.insertions,
            [.init(text: "Recover me", pressEnter: false)]
        )
        XCTAssertTrue(fixture.state.history.isEmpty)
    }

    func testAutomaticTransformRunsBeforeHistoryAndInsertion() async throws {
        let transformClient = DictationTransformClient(
            result: .success(
                .init(text: "A clearer dictation.", inputTokens: 7, outputTokens: 4)
            )
        )
        let fixture = try makeFixture(transformClient: transformClient)
        fixture.state.setTransformsEnabled(true)
        fixture.state.setAutoApplyTransformID(TransformDefinition.polishID)
        fixture.controller.startRecording()
        await waitUntil { fixture.state.state == .listening }
        fixture.controller.stopAndTranscribe()
        await waitUntil { fixture.client.isWaitingForTranscription }

        fixture.client.finishTranscription(with: "a rough dictation")
        await waitUntil { fixture.injector.insertions.count == 1 }

        XCTAssertEqual(transformClient.receivedTexts, ["a rough dictation"])
        XCTAssertEqual(fixture.state.history.map(\.text), ["A clearer dictation."])
        XCTAssertEqual(
            fixture.injector.insertions,
            [.init(text: "A clearer dictation.", pressEnter: false)]
        )
        XCTAssertEqual(fixture.state.tokensSent, 7)
        XCTAssertEqual(fixture.state.tokensReceived, 4)
        XCTAssertEqual(fixture.state.lastTransformResult?.source, .automaticDictation)
    }

    func testAutomaticTransformFailureFallsBackToOriginal() async throws {
        let transformClient = DictationTransformClient(
            result: .failure(AppError.network("Offline"))
        )
        let fixture = try makeFixture(transformClient: transformClient)
        fixture.state.setTransformsEnabled(true)
        fixture.state.setAutoApplyTransformID(TransformDefinition.polishID)
        fixture.controller.startRecording()
        await waitUntil { fixture.state.state == .listening }
        fixture.controller.stopAndTranscribe()
        await waitUntil { fixture.client.isWaitingForTranscription }

        fixture.client.finishTranscription(with: "Keep the original")
        await waitUntil { fixture.injector.insertions.count == 1 }

        XCTAssertEqual(fixture.state.history.map(\.text), ["Keep the original"])
        XCTAssertEqual(
            fixture.injector.insertions,
            [.init(text: "Keep the original", pressEnter: false)]
        )
        XCTAssertEqual(
            fixture.state.transformFeedbackMessage,
            "Auto-transform failed. Pasted the original dictation instead."
        )
    }

    func testWritingStyleUsesRecordingTargetAndPreservesSnippetExpansion() async throws {
        let contextProvider = FakeStyleAppContextProvider(
            context: StyleAppContext(
                bundleIdentifier: "com.apple.MobileSMS",
                applicationName: "Messages",
                documentURL: nil
            )
        )
        let fixture = try makeFixture(appContextProvider: contextProvider)
        var selections = StylePreferences.defaultSelections
        selections[.personal] = .veryCasual
        fixture.state.completeStyleSetup(selections: selections)
        _ = try fixture.state.saveSnippet(
            trigger: "my signature",
            expansion: "Best,\nDylan"
        )

        fixture.controller.startRecording()
        await waitUntil { fixture.state.state == .listening }
        contextProvider.context = StyleAppContext(
            bundleIdentifier: "com.apple.mail",
            applicationName: "Mail",
            documentURL: nil
        )
        fixture.controller.stopAndTranscribe()
        await waitUntil { fixture.client.isWaitingForTranscription }

        fixture.client.finishTranscription(with: "Hello, my signature.")
        await waitUntil { fixture.injector.insertions.count == 1 }

        XCTAssertEqual(contextProvider.captureCount, 1)
        XCTAssertEqual(
            fixture.injector.insertions,
            [.init(text: "hello Best,\nDylan", pressEnter: false)]
        )
        XCTAssertEqual(fixture.state.history.map(\.text), ["hello Best,\nDylan"])
    }

    func testRecordingStartsWithoutWaitingForAppContextLookup() async throws {
        let contextProvider = SuspendedStyleAppContextProvider()
        let fixture = try makeFixture(appContextProvider: contextProvider)

        fixture.controller.startRecording()

        await waitUntil { fixture.state.state == .listening }
        XCTAssertTrue(contextProvider.isWaiting)
        contextProvider.finish(
            with: StyleAppContext(
                bundleIdentifier: "com.example.Editor",
                applicationName: "Editor",
                documentURL: nil
            )
        )
        fixture.controller.cancelCurrentDictation()
    }

    private func makeFixture(
        transformClient: TransformServing? = nil,
        appContextProvider: StyleAppContextProviding? = nil,
        sessionLimits: DictationSessionLimits = .standard
    ) throws -> CancellationFixture {
        let suiteName = "DictationControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let state = AppState(defaults: defaults)
        state.polishEnabled = false
        let recorder = FakeAudioRecorder()
        let client = SuspendedTranscriptionClient()
        let injector = FakeTextInjector()
        let resolvedContextProvider = appContextProvider ?? FakeStyleAppContextProvider(
            context: StyleAppContext(
                bundleIdentifier: "com.example.Editor",
                applicationName: "Editor",
                documentURL: nil
            )
        )
        let controller = DictationController(
            appState: state,
            recorder: recorder,
            client: client,
            transformClient: transformClient,
            injector: injector,
            appContextProvider: resolvedContextProvider,
            sessionLimits: sessionLimits
        )
        return CancellationFixture(
            state: state,
            recorder: recorder,
            client: client,
            injector: injector,
            controller: controller,
            defaultsSuiteName: suiteName
        )
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Condition was not met", file: file, line: line)
    }
}

@MainActor
private final class FakeStyleAppContextProvider: StyleAppContextProviding {
    var context: StyleAppContext
    private(set) var captureCount = 0

    init(context: StyleAppContext) {
        self.context = context
    }

    func currentContext() async -> StyleAppContext {
        captureCount += 1
        return context
    }
}

@MainActor
private final class SuspendedStyleAppContextProvider: StyleAppContextProviding {
    private var continuation: CheckedContinuation<StyleAppContext, Never>?

    var isWaiting: Bool { continuation != nil }

    func currentContext() async -> StyleAppContext {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func finish(with context: StyleAppContext) {
        continuation?.resume(returning: context)
        continuation = nil
    }
}

@MainActor
private final class DictationTransformClient: TransformServing {
    let result: Result<TransformGenerationResult, Error>
    private(set) var receivedTexts: [String] = []

    init(result: Result<TransformGenerationResult, Error>) {
        self.result = result
    }

    func transform(
        text: String,
        invocation: TransformInvocation
    ) async throws -> TransformGenerationResult {
        receivedTexts.append(text)
        return try result.get()
    }
}

@MainActor
private final class FakePasteboard: PasteboardAccessing {
    var changeCount = 0
    let storedSnapshot: PasteboardSnapshot?
    var temporaryText: String?
    var restoredSnapshot: PasteboardSnapshot?

    init(snapshot: PasteboardSnapshot?) {
        storedSnapshot = snapshot
    }

    func snapshot() -> PasteboardSnapshot? {
        storedSnapshot
    }

    func readString() -> String? {
        temporaryText
    }

    func writeTemporaryText(_ text: String) -> Int? {
        temporaryText = text
        changeCount += 1
        return changeCount
    }

    func copyText(_ text: String) -> Bool {
        temporaryText = text
        changeCount += 1
        return true
    }

    func restore(
        _ snapshot: PasteboardSnapshot,
        ifChangeCountMatches expectedChangeCount: Int
    ) -> Bool {
        guard changeCount == expectedChangeCount else { return false }
        restoredSnapshot = snapshot
        changeCount += 1
        return true
    }
}

@MainActor
private final class FakeKeyboardEventPoster: KeyboardEventPosting {
    enum Event: Equatable {
        case copy
        case paste
        case `return`
    }

    var events: [Event] = []

    func postCopy() {
        events.append(.copy)
    }

    func postPaste() {
        events.append(.paste)
    }

    func postReturn() {
        events.append(.return)
    }
}

@MainActor
private final class FakeAccessibilityAuthorizer: AccessibilityAuthorizing {
    let isAllowed: Bool

    init(isAllowed: Bool) {
        self.isAllowed = isAllowed
    }

    func ensureAccessibility() -> Bool {
        isAllowed
    }
}

@MainActor
private final class FakeAudioRecorder: AudioRecording {
    let recordingURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wispr-cancellation-\(UUID().uuidString).wav")
    var wasCancelled = false
    private var isRecording = false

    func startRecording() async throws {
        try Data("audio".utf8).write(to: recordingURL)
        isRecording = true
    }

    func stopRecording() throws -> URL {
        isRecording = false
        return recordingURL
    }

    func cancelRecording() {
        wasCancelled = true
        if isRecording {
            try? FileManager.default.removeItem(at: recordingURL)
            isRecording = false
        }
    }
}

@MainActor
private final class SuspendedStartAudioRecorder: AudioRecording {
    let recordingURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wispr-pending-start-\(UUID().uuidString).m4a")
    private var startContinuation: CheckedContinuation<Void, Never>?
    private(set) var stopCount = 0

    var isWaitingToStart: Bool { startContinuation != nil }

    func startRecording() async throws {
        try Data("audio".utf8).write(to: recordingURL)
        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
    }

    func finishStarting() {
        startContinuation?.resume()
        startContinuation = nil
    }

    func stopRecording() throws -> URL {
        stopCount += 1
        return recordingURL
    }

    func cancelRecording() {
        startContinuation?.resume()
        startContinuation = nil
        try? FileManager.default.removeItem(at: recordingURL)
    }
}

private final class SuspendedTranscriptionClient: TranscriptionServing {
    private(set) var isWaitingForTranscription = false
    private var continuation: CheckedContinuation<String, Error>?

    func transcribe(
        fileURL: URL,
        language: String?,
        vocabularyPrompt: String?
    ) async throws -> String {
        isWaitingForTranscription = true
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func polishTranscript(text: String) async throws -> PolishResult {
        PolishResult(text: text, promptTokens: 0, completionTokens: 0)
    }

    func finishTranscription(with text: String) {
        continuation?.resume(returning: text)
        continuation = nil
        isWaitingForTranscription = false
    }
}

@MainActor
private final class FakeTextInjector: TextInjecting {
    struct Insertion: Equatable {
        let text: String
        let pressEnter: Bool
    }

    var insertions: [Insertion] = []
    var copiedTexts: [String] = []

    func insert(text: String, pressEnter: Bool) async throws {
        insertions.append(.init(text: text, pressEnter: pressEnter))
    }

    func copy(text: String) throws {
        copiedTexts.append(text)
    }
}

@MainActor
private final class CancellationFixture {
    let state: AppState
    let recorder: FakeAudioRecorder
    let client: SuspendedTranscriptionClient
    let injector: FakeTextInjector
    let controller: DictationController
    let defaultsSuiteName: String

    init(
        state: AppState,
        recorder: FakeAudioRecorder,
        client: SuspendedTranscriptionClient,
        injector: FakeTextInjector,
        controller: DictationController,
        defaultsSuiteName: String
    ) {
        self.state = state
        self.recorder = recorder
        self.client = client
        self.injector = injector
        self.controller = controller
        self.defaultsSuiteName = defaultsSuiteName
    }

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: defaultsSuiteName)
    }
}
