import AppKit
import SwiftUI
import XCTest
@testable import WisprLocal

final class ScratchpadShortcutPolicyTests: XCTestCase {
    func testDoubleTapRequiresVisibleWindowAndRecentRelease() {
        let first = Date(timeIntervalSince1970: 100)

        XCTAssertTrue(
            ScratchpadShortcutPolicy.isDoubleTap(
                previousRelease: first,
                currentRelease: first.addingTimeInterval(0.20),
                isWindowVisible: true
            )
        )
        XCTAssertFalse(
            ScratchpadShortcutPolicy.isDoubleTap(
                previousRelease: first,
                currentRelease: first.addingTimeInterval(0.30),
                isWindowVisible: true
            )
        )
        XCTAssertFalse(
            ScratchpadShortcutPolicy.isDoubleTap(
                previousRelease: first,
                currentRelease: first.addingTimeInterval(0.20),
                isWindowVisible: false
            )
        )
    }
}

@MainActor
final class ScratchpadDocumentTests: XCTestCase {
    func testRTFDRoundTripPreservesFormattingAndImageAttachment() throws {
        let content = NSMutableAttributedString(
            string: "Project update\n",
            attributes: [.font: NSFont.systemFont(ofSize: 16)]
        )
        content.addAttribute(
            .font,
            value: NSFont.boldSystemFont(ofSize: 16),
            range: NSRange(location: 0, length: 7)
        )
        content.append(NSAttributedString(attachment: try makeAttachment()))

        let decoded = try ScratchpadDocumentCodec.decode(
            ScratchpadDocumentCodec.encode(content)
        )

        XCTAssertEqual(decoded.string, content.string)
        let font = try XCTUnwrap(decoded.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        XCTAssertEqual(attachmentCount(in: decoded), 1)
        XCTAssertEqual(
            try ScratchpadDocumentCodec.noteSummary(
                id: UUID(),
                content: decoded,
                createdAt: Date(),
                modifiedAt: Date(),
                isPinned: false
            ).imageCount,
            1
        )
    }

    func testEditorTransformPreservesImageAndRejectsTargetDrift() throws {
        let content = NSMutableAttributedString(string: "Before ")
        content.append(NSAttributedString(attachment: try makeAttachment()))
        content.append(NSAttributedString(string: " after"))
        let textView = NSTextView()
        textView.textStorage?.setAttributedString(content)
        let bridge = ScratchpadEditorBridge()
        bridge.attach(textView)
        let noteID = UUID()

        let target = try bridge.captureTransformTarget(noteID: noteID)
        let marker = try XCTUnwrap(target.attachments.first?.marker)
        try bridge.applyTransform(
            "Updated \(marker) done",
            target: target,
            currentNoteID: noteID
        )

        XCTAssertEqual(textView.string, "Updated \u{fffc} done")
        XCTAssertEqual(attachmentCount(in: textView.attributedString()), 1)

        let staleTarget = try bridge.captureTransformTarget(noteID: noteID)
        textView.textStorage?.replaceCharacters(
            in: NSRange(location: 0, length: 1),
            with: "C"
        )
        XCTAssertThrowsError(
            try bridge.applyTransform(
                "Replacement \(marker)",
                target: staleTarget,
                currentNoteID: noteID
            )
        ) { error in
            guard case AppError.selectedTextChanged = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    private func makeAttachment() throws -> NSTextAttachment {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus()
        NSColor.systemPurple.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 16, height: 16)).fill()
        image.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        return NSTextAttachment(data: png, ofType: "public.png")
    }

    private func attachmentCount(in content: NSAttributedString) -> Int {
        var count = 0
        content.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: content.length)
        ) { value, _, _ in
            if value != nil { count += 1 }
        }
        return count
    }
}

@MainActor
final class ScratchpadStoreTests: XCTestCase {
    func testStorePersistsNotesPinsTabsAndVersionRestoreAcrossRestart() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let firstID = try fixture.store.createNote(initialText: "First draft")
        fixture.store.updateActiveContent(NSAttributedString(string: "First edited"))
        try fixture.store.saveActiveContent(source: .typed, coalesceTyped: true)
        fixture.store.togglePin(id: firstID)
        let secondID = try fixture.store.createNote(initialText: "Second draft")

        XCTAssertEqual(fixture.store.notes.first?.id, firstID)
        XCTAssertEqual(fixture.store.openTabs, [firstID, secondID])
        XCTAssertEqual(fixture.store.selectedNoteID, secondID)

        let restored = ScratchpadStore(
            repository: FileScratchpadRepository(rootURL: fixture.rootURL)
        )
        XCTAssertEqual(restored.notes.first?.id, firstID)
        XCTAssertEqual(restored.openTabs, [firstID, secondID])
        XCTAssertEqual(restored.selectedNoteID, secondID)

        try restored.openNote(id: firstID)
        let created = try XCTUnwrap(
            restored.selectedVersions.last(where: { $0.source == .created })
        )
        try restored.restore(versionID: created.id)
        XCTAssertEqual(restored.activeContent.string, "First draft")
        XCTAssertEqual(restored.selectedVersions.first?.source, .restored)
    }

    func testStoreEnforcesFiveTabLimitAndDeletesVersionFiles() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        var ids: [UUID] = []
        for index in 0..<ScratchpadStore.maximumOpenTabs {
            ids.append(try fixture.store.createNote(initialText: "Note \(index)"))
        }

        XCTAssertThrowsError(try fixture.store.createNote()) { error in
            XCTAssertEqual(error as? ScratchpadError, .tabLimitReached)
        }

        let deletedID = ids[2]
        try fixture.store.deleteNote(id: deletedID)
        XCTAssertFalse(fixture.store.notes.contains { $0.id == deletedID })
        XCTAssertFalse(fixture.store.openTabs.contains(deletedID))
        XCTAssertNoThrow(try fixture.store.createNote(initialText: "Replacement"))
    }

    func testShortcutDictationReusesBlankTabAndCreatesTabForExistingContent() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let blankID = try fixture.store.createNote()

        try fixture.store.prepareForShortcutDictation()
        XCTAssertEqual(fixture.store.openTabs, [blankID])

        fixture.store.updateActiveContent(NSAttributedString(string: "Existing thought"))
        try fixture.store.saveActiveContent(source: .typed, coalesceTyped: true)
        try fixture.store.prepareForShortcutDictation()

        XCTAssertEqual(fixture.store.openTabs.count, 2)
        XCTAssertEqual(fixture.store.activeContent.string, "")
        XCTAssertNotEqual(fixture.store.selectedNoteID, blankID)
    }

    func testTypedVersionDoesNotCoalesceAcrossTransformBoundary() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        _ = try fixture.store.createNote(initialText: "Created")
        fixture.store.updateActiveContent(NSAttributedString(string: "Typed before transform"))
        try fixture.store.saveActiveContent(source: .typed, coalesceTyped: true)
        let originalTypedVersion = try XCTUnwrap(
            fixture.store.selectedVersions.first(where: { $0.source == .typed })
        )

        fixture.store.updateActiveContent(NSAttributedString(string: "Transformed"))
        try fixture.store.saveActiveContent(source: .transform)
        fixture.store.updateActiveContent(NSAttributedString(string: "Typed after transform"))
        try fixture.store.saveActiveContent(source: .typed, coalesceTyped: true)

        XCTAssertEqual(
            fixture.store.selectedVersions.filter { $0.source == .typed }.count,
            2
        )
        try fixture.store.restore(versionID: originalTypedVersion.id)
        XCTAssertEqual(fixture.store.activeContent.string, "Typed before transform")
    }

    func testSaveFailureIsThrownAndPublished() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("scratchpad-save-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let repository = ControllableScratchpadRepository(
            base: FileScratchpadRepository(rootURL: rootURL)
        )
        let store = ScratchpadStore(repository: repository)
        _ = try store.createNote(initialText: "Original")
        store.updateActiveContent(NSAttributedString(string: "Unsaved edit"))
        repository.shouldFailWorkspaceSave = true

        XCTAssertThrowsError(try store.saveActiveContent(source: .typed))
        XCTAssertEqual(store.message, ScratchpadTestError.forced.localizedDescription)
    }

    func testCorruptWorkspaceIsBackedUpAndRecoveredEmpty() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("scratchpad-corrupt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: rootURL.appendingPathComponent("workspace.json"))

        let result = FileScratchpadRepository(rootURL: rootURL).loadWorkspace()

        XCTAssertEqual(result.workspace, .empty)
        XCTAssertEqual(
            result.recoveryMessage,
            ScratchpadError.corruptWorkspace.localizedDescription
        )
        let recoveryFiles = try FileManager.default.contentsOfDirectory(
            at: rootURL.appendingPathComponent("Recovery"),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(recoveryFiles.count, 1)
    }

    private func makeFixture() throws -> ScratchpadStoreFixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("scratchpad-store-\(UUID().uuidString)", isDirectory: true)
        let repository = FileScratchpadRepository(rootURL: rootURL)
        return ScratchpadStoreFixture(
            rootURL: rootURL,
            store: ScratchpadStore(repository: repository)
        )
    }
}

@MainActor
final class ScratchpadControllerTests: XCTestCase {
    func testHoldDictationInsertsAtCursorAndCreatesDictatedVersion() async throws {
        let fixture = try makeControllerFixture(transcript: "A dictated thought.")
        defer { fixture.cleanUp() }
        _ = try fixture.store.createNote(initialText: "Start: ")
        let hostingView = NSHostingView(
            rootView: ScratchpadView(controller: fixture.controller)
                .frame(width: 780, height: 580)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 780, height: 580)
        hostingView.layoutSubtreeIfNeeded()

        fixture.controller.startRecording(mode: .hold)
        await waitUntil { fixture.controller.state == .listening(.hold) }
        fixture.controller.stopAndTranscribe()
        await waitUntil {
            if case .success = fixture.controller.state { return true }
            return false
        }

        XCTAssertTrue(fixture.store.activeContent.string.contains("A dictated thought."))
        XCTAssertEqual(fixture.store.selectedVersions.first?.source, .dictated)
        XCTAssertEqual(fixture.state.state, .idle)
    }

    func testTransformReplacesWholeNoteAndTracksUsage() async throws {
        let fixture = try makeControllerFixture(
            transform: .init(text: "A concise draft.", inputTokens: 8, outputTokens: 4)
        )
        defer { fixture.cleanUp() }
        _ = try fixture.store.createNote(initialText: "A very long draft.")
        let hostingView = NSHostingView(
            rootView: ScratchpadView(controller: fixture.controller)
                .frame(width: 780, height: 580)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 780, height: 580)
        hostingView.layoutSubtreeIfNeeded()

        fixture.controller.applyTransform(definition: .defaultPolish)
        await waitUntil {
            if case .success = fixture.controller.state { return true }
            return false
        }

        XCTAssertEqual(fixture.store.activeContent.string, "A concise draft.")
        XCTAssertEqual(fixture.store.selectedVersions.first?.source, .transform)
        XCTAssertEqual(fixture.state.tokensSent, 8)
        XCTAssertEqual(fixture.state.tokensReceived, 4)
    }

    func testDictationRejectsNoteSwitchWhileTranscriptionIsPending() async throws {
        let suspendedClient = SuspendedScratchpadTranscriptionClient()
        let fixture = try makeControllerFixture(transcriptionClient: suspendedClient)
        defer { fixture.cleanUp() }
        let originalID = try fixture.store.createNote(initialText: "Original note")
        let hostingView = NSHostingView(
            rootView: ScratchpadView(controller: fixture.controller)
                .frame(width: 780, height: 580)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 780, height: 580)
        hostingView.layoutSubtreeIfNeeded()

        fixture.controller.startRecording(mode: .hold)
        await waitUntil { fixture.controller.state == .listening(.hold) }
        fixture.controller.stopAndTranscribe()
        await waitUntil { suspendedClient.isWaiting }
        _ = try fixture.store.createNote(initialText: "Other note")
        suspendedClient.finish(with: "Late dictation")
        await waitUntil {
            if case .error = fixture.controller.state { return true }
            return false
        }

        XCTAssertEqual(fixture.store.activeContent.string, "Other note")
        XCTAssertEqual(
            fixture.store.message,
            ScratchpadError.dictationTargetChanged.localizedDescription
        )
        try fixture.store.openNote(id: originalID)
        XCTAssertEqual(fixture.store.activeContent.string, "Original note")
    }

    func testBusyGlobalStateDoesNotCreateOrShowShortcutNote() async throws {
        let fixture = try makeControllerFixture()
        defer { fixture.cleanUp() }
        var showCount = 0
        fixture.controller.onShowWindow = { showCount += 1 }
        fixture.state.setState(.transcribing)

        fixture.controller.shortcutPressed()
        try? await Task.sleep(nanoseconds: 320_000_000)
        fixture.controller.shortcutReleased()
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(fixture.store.notes.isEmpty)
        XCTAssertEqual(showCount, 0)
        XCTAssertEqual(fixture.state.state, .transcribing)
    }

    func testSetupGateBlocksScratchpadShortcutAndPresentsOnboarding() throws {
        var presentationCount = 0
        let fixture = try makeControllerFixture(
            isSetupComplete: { false },
            onSetupRequired: { presentationCount += 1 }
        )
        defer { fixture.cleanUp() }
        var showCount = 0
        fixture.controller.onShowWindow = { showCount += 1 }

        fixture.controller.shortcutPressed()

        XCTAssertTrue(fixture.store.notes.isEmpty)
        XCTAssertEqual(showCount, 0)
        XCTAssertEqual(presentationCount, 1)
        XCTAssertEqual(
            fixture.store.message,
            AppError.setupIncomplete.localizedDescription
        )
    }

    func testDoubleTapStartsHandsFreeAndCancellationDisarmsRelease() async throws {
        let fixture = try makeControllerFixture()
        defer { fixture.cleanUp() }
        var showCount = 0
        var hideCount = 0
        fixture.controller.onShowWindow = { showCount += 1 }
        fixture.controller.onHideWindow = { hideCount += 1 }
        fixture.controller.isWindowVisible = { true }
        let firstRelease = Date()

        fixture.controller.shortcutPressed()
        fixture.controller.shortcutReleased(at: firstRelease)
        fixture.controller.shortcutPressed()
        fixture.controller.shortcutReleased(at: firstRelease.addingTimeInterval(0.10))
        await waitUntil { fixture.controller.state == .listening(.handsFree) }
        fixture.controller.cancelCurrentAction()
        fixture.controller.shortcutReleased(at: firstRelease.addingTimeInterval(0.15))
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(fixture.controller.state, .idle)
        XCTAssertEqual(showCount, 1)
        XCTAssertEqual(hideCount, 0)
    }

    private func makeControllerFixture(
        transcript: String = "Unused",
        transform: TransformGenerationResult = .init(text: "Unused", inputTokens: 0, outputTokens: 0),
        transcriptionClient: TranscriptionServing? = nil,
        isSetupComplete: @escaping () -> Bool = { true },
        onSetupRequired: @escaping () -> Void = {}
    ) throws -> ScratchpadControllerFixture {
        let suiteName = "ScratchpadControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(false, forKey: DefaultsKeys.polishEnabled)
        let state = AppState(defaults: defaults)
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("scratchpad-controller-\(UUID().uuidString)", isDirectory: true)
        let store = ScratchpadStore(
            repository: FileScratchpadRepository(rootURL: rootURL)
        )
        let recorder = ScratchpadTestAudioRecorder()
        let controller = ScratchpadController(
            appState: state,
            store: store,
            editorBridge: ScratchpadEditorBridge(),
            recorder: recorder,
            transcriptionClient: transcriptionClient
                ?? ScratchpadTestTranscriptionClient(text: transcript),
            transformClient: ScratchpadTestTransformClient(result: transform),
            isSetupComplete: isSetupComplete,
            onSetupRequired: onSetupRequired
        )
        return ScratchpadControllerFixture(
            state: state,
            store: store,
            controller: controller,
            defaultsSuiteName: suiteName,
            rootURL: rootURL,
            recordingURL: recorder.recordingURL
        )
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }
}

@MainActor
final class ScratchpadViewSmokeTests: XCTestCase {
    func testHubAndFloatingEditorRender() throws {
        let fixture = try makeViewFixture()
        defer { fixture.cleanUp() }
        _ = try fixture.store.createNote(
            initialText: "Launch notes\nPolish onboarding copy and verify the shortcut."
        )
        fixture.store.togglePin(id: try XCTUnwrap(fixture.store.selectedNoteID))

        try capture(
            ScratchpadHubView(controller: fixture.controller)
                .frame(width: 920, height: 640),
            size: NSSize(width: 920, height: 640),
            name: "Scratchpad Hub"
        )
        try capture(
            ScratchpadView(controller: fixture.controller)
                .frame(width: 780, height: 580),
            size: NSSize(width: 780, height: 580),
            name: "Scratchpad Floating Editor"
        )
    }

    private func makeViewFixture() throws -> ScratchpadControllerFixture {
        let suiteName = "ScratchpadViewSmokeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let state = AppState(defaults: defaults)
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("scratchpad-view-\(UUID().uuidString)", isDirectory: true)
        let store = ScratchpadStore(
            repository: FileScratchpadRepository(rootURL: rootURL)
        )
        let recorder = ScratchpadTestAudioRecorder()
        let controller = ScratchpadController(
            appState: state,
            store: store,
            editorBridge: ScratchpadEditorBridge(),
            recorder: recorder,
            transcriptionClient: ScratchpadTestTranscriptionClient(text: ""),
            transformClient: ScratchpadTestTransformClient(
                result: .init(text: "", inputTokens: 0, outputTokens: 0)
            )
        )
        return ScratchpadControllerFixture(
            state: state,
            store: store,
            controller: controller,
            defaultsSuiteName: suiteName,
            rootURL: rootURL,
            recordingURL: recorder.recordingURL
        )
    }

    private func capture<V: View>(
        _ view: V,
        size: NSSize,
        name: String
    ) throws {
        let hostingView = NSHostingView(rootView: view)
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

@MainActor
private final class ScratchpadStoreFixture {
    let rootURL: URL
    let store: ScratchpadStore

    init(rootURL: URL, store: ScratchpadStore) {
        self.rootURL = rootURL
        self.store = store
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

@MainActor
private final class ScratchpadControllerFixture {
    let state: AppState
    let store: ScratchpadStore
    let controller: ScratchpadController
    let defaultsSuiteName: String
    let rootURL: URL
    let recordingURL: URL

    init(
        state: AppState,
        store: ScratchpadStore,
        controller: ScratchpadController,
        defaultsSuiteName: String,
        rootURL: URL,
        recordingURL: URL
    ) {
        self.state = state
        self.store = store
        self.controller = controller
        self.defaultsSuiteName = defaultsSuiteName
        self.rootURL = rootURL
        self.recordingURL = recordingURL
    }

    func cleanUp() {
        UserDefaults.standard.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: rootURL)
        try? FileManager.default.removeItem(at: recordingURL)
    }
}

@MainActor
private final class ScratchpadTestAudioRecorder: AudioRecording {
    let recordingURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("scratchpad-audio-\(UUID().uuidString).wav")

    func startRecording() async throws {
        try Data("audio".utf8).write(to: recordingURL)
    }

    func stopRecording() throws -> URL {
        recordingURL
    }

    func cancelRecording() {
        try? FileManager.default.removeItem(at: recordingURL)
    }
}

private final class ScratchpadTestTranscriptionClient: TranscriptionServing {
    let text: String

    init(text: String) {
        self.text = text
    }

    func transcribe(
        fileURL: URL,
        language: String?,
        vocabularyPrompt: String?
    ) async throws -> String {
        text
    }

    func polishTranscript(text: String) async throws -> PolishResult {
        .init(text: text, promptTokens: 0, completionTokens: 0)
    }
}

private final class SuspendedScratchpadTranscriptionClient: TranscriptionServing {
    private(set) var isWaiting = false
    private var continuation: CheckedContinuation<String, Error>?

    func transcribe(
        fileURL: URL,
        language: String?,
        vocabularyPrompt: String?
    ) async throws -> String {
        isWaiting = true
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func polishTranscript(text: String) async throws -> PolishResult {
        .init(text: text, promptTokens: 0, completionTokens: 0)
    }

    func finish(with text: String) {
        continuation?.resume(returning: text)
        continuation = nil
        isWaiting = false
    }
}

@MainActor
private final class ScratchpadTestTransformClient: TransformServing {
    let result: TransformGenerationResult
    private(set) var invocations: [TransformInvocation] = []

    init(result: TransformGenerationResult) {
        self.result = result
    }

    func transform(
        text: String,
        invocation: TransformInvocation
    ) async throws -> TransformGenerationResult {
        invocations.append(invocation)
        return result
    }
}

private enum ScratchpadTestError: LocalizedError {
    case forced

    var errorDescription: String? {
        "Forced Scratchpad persistence failure."
    }
}

@MainActor
private final class ControllableScratchpadRepository: ScratchpadPersisting {
    let base: ScratchpadPersisting
    var shouldFailWorkspaceSave = false

    init(base: ScratchpadPersisting) {
        self.base = base
    }

    func loadWorkspace() -> ScratchpadWorkspaceLoadResult {
        base.loadWorkspace()
    }

    func saveWorkspace(_ workspace: ScratchpadWorkspace) throws {
        if shouldFailWorkspaceSave { throw ScratchpadTestError.forced }
        try base.saveWorkspace(workspace)
    }

    func loadNoteContent(id: UUID) throws -> NSAttributedString {
        try base.loadNoteContent(id: id)
    }

    func saveNoteContent(_ content: NSAttributedString, id: UUID) throws {
        try base.saveNoteContent(content, id: id)
    }

    func loadVersionContent(id: UUID) throws -> NSAttributedString {
        try base.loadVersionContent(id: id)
    }

    func saveVersionContent(_ content: NSAttributedString, id: UUID) throws {
        try base.saveVersionContent(content, id: id)
    }

    func deleteNoteContent(id: UUID, versionIDs: [UUID]) throws {
        try base.deleteNoteContent(id: id, versionIDs: versionIDs)
    }

    func deleteVersionContent(id: UUID) throws {
        try base.deleteVersionContent(id: id)
    }
}
