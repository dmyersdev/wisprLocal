import AppKit
import SwiftUI
import XCTest
@testable import WisprLocal

final class HistoryStoreTests: XCTestCase {
    func testLegacyArrayMigratesWithCompatibleDefaults() throws {
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let legacyObject: [[String: Any]] = [[
            "id": id.uuidString,
            "date": ISO8601DateFormatter().string(from: date),
            "text": "A legacy transcript"
        ]]

        let result = HistoryStore.decode(
            try JSONSerialization.data(withJSONObject: legacyObject)
        )

        XCTAssertTrue(result.needsMigration)
        XCTAssertEqual(result.rejectedRecordCount, 0)
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items[0].id, id)
        XCTAssertEqual(result.items[0].text, "A legacy transcript")
        XCTAssertEqual(result.items[0].status, .succeeded)
    }

    func testInvalidRecordDoesNotDiscardValidHistory() throws {
        let valid = HistoryItem(
            id: UUID(),
            date: Date(timeIntervalSince1970: 1_750_000_000),
            text: "Keep me"
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: HistoryStore.encode([valid])) as? [String: Any]
        )
        object["records"] = [
            try XCTUnwrap((object["records"] as? [Any])?.first),
            ["text": "Missing required identity and date"]
        ]

        let result = HistoryStore.decode(
            try JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(result.items, [valid])
        XCTAssertEqual(result.rejectedRecordCount, 1)
        XCTAssertTrue(result.shouldBackUpOriginal)
    }

    func testInterruptedAndUnsafeRecordsRecoverToSafeRetryableState() throws {
        let interrupted = HistoryItem(
            id: UUID(),
            date: Date(),
            text: "",
            status: .retrying,
            audioFilename: "../outside.wav"
        )

        let result = HistoryStore.decode(try HistoryStore.encode([interrupted]))

        XCTAssertEqual(result.recoveredInterruptedCount, 1)
        XCTAssertEqual(result.items.first?.status, .failed)
        XCTAssertNil(result.items.first?.audioFilename)
        XCTAssertEqual(
            result.items.first?.errorMessage,
            "Dictation was interrupted before transcription finished."
        )
    }

    func testFutureVersionIsLeftUnsupportedInsteadOfTreatedAsCorruption() throws {
        let futureStore: [String: Any] = [
            "version": HistoryStore.currentVersion + 1,
            "records": []
        ]

        let result = HistoryStore.decode(
            try JSONSerialization.data(withJSONObject: futureStore)
        )

        XCTAssertTrue(result.isUnsupportedVersion)
        XCTAssertFalse(result.needsRewrite)
        XCTAssertFalse(result.shouldBackUpOriginal)
    }
}

final class HistoryStatisticsTests: XCTestCase {
    func testStatisticsUseSuccessfulHistoryAndWeightedDuration() throws {
        let calendar = utcCalendar()
        let now = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 22, hour: 12))
        )
        let today = HistoryItem(
            id: UUID(),
            date: now,
            text: "one two three",
            durationSeconds: 30,
            applicationName: "Notes"
        )
        let yesterday = HistoryItem(
            id: UUID(),
            date: try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: now)),
            text: "four five",
            durationSeconds: 30,
            applicationName: "Mail"
        )
        let older = HistoryItem(
            id: UUID(),
            date: try XCTUnwrap(calendar.date(byAdding: .day, value: -3, to: now)),
            text: "six",
            durationSeconds: 30,
            applicationName: "Terminal"
        )
        let failed = HistoryItem(
            id: UUID(),
            date: now,
            text: "not counted",
            status: .failed,
            durationSeconds: 10
        )

        let statistics = HistoryStatistics(
            items: [older, failed, yesterday, today],
            calendar: calendar,
            now: now
        )

        XCTAssertEqual(statistics.totalWords, 6)
        XCTAssertEqual(statistics.totalDictations, 3)
        XCTAssertEqual(statistics.daysUsed, 3)
        XCTAssertEqual(statistics.currentStreak, 2)
        XCTAssertEqual(statistics.averageWordsPerMinute, 4)
    }

    func testTimelineGroupsNewestFirstAndSearchesApplicationName() throws {
        let calendar = utcCalendar()
        let now = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 22, hour: 12))
        )
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: now))
        let items = [
            HistoryItem(id: UUID(), date: yesterday, text: "Status update", applicationName: "Mail"),
            HistoryItem(id: UUID(), date: now, text: "Meeting notes", applicationName: "Notes"),
            HistoryItem(id: UUID(), date: now.addingTimeInterval(-60), text: "Follow up", applicationName: "Mail")
        ]

        let sections = HistoryTimeline.sections(
            from: items,
            matching: "mail",
            calendar: calendar
        )

        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections.flatMap(\.items).count, 2)
        XCTAssertGreaterThan(sections[0].day, sections[1].day)
        XCTAssertTrue(sections.flatMap(\.items).allSatisfy { $0.applicationName == "Mail" })
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try! XCTUnwrap(TimeZone(secondsFromGMT: 0))
        return calendar
    }
}

@MainActor
final class HistoryRepositoryTests: XCTestCase {
    func testLegacyImportMovesMetadataOutOfDefaultsAndSurvivesRestart() throws {
        let fixture = try makeRepositoryFixture()
        defer { fixture.cleanUp() }
        let id = UUID()
        let legacyObject: [[String: Any]] = [[
            "id": id.uuidString,
            "date": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_750_000_000)),
            "text": "Migrated"
        ]]
        fixture.defaults.set(
            try JSONSerialization.data(withJSONObject: legacyObject),
            forKey: DefaultsKeys.history
        )

        let firstState = AppState(
            defaults: fixture.defaults,
            historyRepository: FileHistoryRepository(rootURL: fixture.rootURL)
        )

        XCTAssertEqual(firstState.history.map(\.text), ["Migrated"])
        XCTAssertNil(fixture.defaults.data(forKey: DefaultsKeys.history))

        let restartedState = AppState(
            defaults: fixture.defaults,
            historyRepository: FileHistoryRepository(rootURL: fixture.rootURL)
        )
        XCTAssertEqual(restartedState.history.map(\.id), [id])
    }

    func testFailedLegacyMigrationKeepsTheOnlyPersistedCopy() throws {
        let fixture = try makeRepositoryFixture()
        defer { fixture.cleanUp() }
        try Data("This path is a file, not a directory".utf8).write(
            to: fixture.rootURL,
            options: .atomic
        )
        let legacyObject: [[String: Any]] = [[
            "id": UUID().uuidString,
            "date": ISO8601DateFormatter().string(from: Date()),
            "text": "Do not lose me"
        ]]
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        fixture.defaults.set(legacyData, forKey: DefaultsKeys.history)

        let state = AppState(
            defaults: fixture.defaults,
            historyRepository: FileHistoryRepository(rootURL: fixture.rootURL)
        )

        XCTAssertEqual(state.history.map(\.text), ["Do not lose me"])
        XCTAssertEqual(fixture.defaults.data(forKey: DefaultsKeys.history), legacyData)
        XCTAssertTrue(state.historyRecoveryMessage?.contains("left untouched") == true)
    }

    func testFutureVersionFileIsNotRewritten() throws {
        let fixture = try makeRepositoryFixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(
            at: fixture.rootURL,
            withIntermediateDirectories: true
        )
        let futureData = try JSONSerialization.data(withJSONObject: [
            "version": HistoryStore.currentVersion + 1,
            "records": [["future": "shape"]]
        ])
        let metadataURL = fixture.rootURL.appendingPathComponent("history.json")
        try futureData.write(to: metadataURL, options: .atomic)

        let result = FileHistoryRepository(rootURL: fixture.rootURL).loadHistory(
            legacyData: nil
        )

        XCTAssertTrue(result.items.isEmpty)
        XCTAssertTrue(result.recoveryMessage?.contains("newer version") == true)
        XCTAssertEqual(try Data(contentsOf: metadataURL), futureData)
    }

    func testRecordingLifecyclePersistsMetadataAndDeletesRetainedAudio() throws {
        let fixture = try makeRepositoryFixture()
        defer { fixture.cleanUp() }
        let recordingURL = fixture.rootURL
            .deletingLastPathComponent()
            .appendingPathComponent("source-\(UUID().uuidString).wav")
        try Data("audio".utf8).write(to: recordingURL, options: .atomic)
        let state = AppState(
            defaults: fixture.defaults,
            historyRepository: FileHistoryRepository(rootURL: fixture.rootURL)
        )

        let started = state.beginHistoryRecording(
            date: Date(timeIntervalSince1970: 1_750_000_000),
            durationSeconds: 12,
            language: "en",
            context: StyleAppContext(
                bundleIdentifier: "com.apple.notes",
                applicationName: "Notes",
                documentURL: nil
            ),
            recordingURL: recordingURL
        )

        XCTAssertEqual(state.historyItem(id: started.itemID)?.status, .transcribing)
        XCTAssertFalse(started.shouldDeleteTranscriptionURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordingURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.transcriptionURL.path))
        state.failHistoryItem(id: started.itemID, message: "Offline")
        state.flushHistoryPersistence()

        let restartedState = AppState(
            defaults: fixture.defaults,
            historyRepository: FileHistoryRepository(rootURL: fixture.rootURL)
        )
        XCTAssertEqual(restartedState.historyItem(id: started.itemID)?.status, .failed)
        XCTAssertTrue(restartedState.markHistoryItemRetrying(id: started.itemID))
        restartedState.finishHistoryItem(id: started.itemID, text: "Recovered transcript")
        restartedState.flushHistoryPersistence()
        XCTAssertEqual(restartedState.history.count, 1)
        XCTAssertEqual(restartedState.history[0].status, .succeeded)
        XCTAssertEqual(restartedState.history[0].durationSeconds, 12)
        XCTAssertNil(restartedState.history[0].audioFilename)
        XCTAssertFalse(FileManager.default.fileExists(atPath: started.transcriptionURL.path))

        try restartedState.deleteHistoryItem(id: started.itemID)

        XCTAssertTrue(restartedState.history.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: started.transcriptionURL.path))
    }

    func testRestartChoosesLatestSuccessfulTranscriptForRecovery() throws {
        let fixture = try makeRepositoryFixture()
        defer { fixture.cleanUp() }
        let repository = FileHistoryRepository(rootURL: fixture.rootURL)
        try repository.saveHistory([
            HistoryItem(
                id: UUID(),
                date: Date(),
                text: "",
                status: .failed,
                errorMessage: "Offline"
            ),
            HistoryItem(
                id: UUID(),
                date: Date().addingTimeInterval(-60),
                text: "Recover this transcript"
            )
        ])

        let state = AppState(defaults: fixture.defaults, historyRepository: repository)

        XCTAssertEqual(state.lastTranscript, "Recover this transcript")
    }

    func testRoutineHistorySaveDoesNotBlockTheMainActor() throws {
        let suiteName = "HistoryRepositoryTests.Performance.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let repository = SlowHistoryRepository()
        let state = AppState(defaults: defaults, historyRepository: repository)

        let startedAt = Date()
        _ = state.addHistory(text: "Responsive history")
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertLessThan(elapsed, 0.1)
        state.flushHistoryPersistence()
        XCTAssertGreaterThanOrEqual(repository.saveCount, 1)
    }

    private func makeRepositoryFixture() throws -> RepositoryFixture {
        let suiteName = "HistoryRepositoryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WisprLocal-HistoryTests-\(UUID().uuidString)", isDirectory: true)
        return RepositoryFixture(
            suiteName: suiteName,
            defaults: defaults,
            rootURL: rootURL
        )
    }
}

@MainActor
final class HistoryControllerTests: XCTestCase {
    func testRetryUpdatesSameRecordAndCopyDoesNotInsert() async throws {
        let suiteName = "HistoryControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WisprLocal-HistoryControllerTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: rootURL)
        }
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-controller-source-\(UUID().uuidString).wav")
        try Data("audio".utf8).write(to: sourceURL, options: .atomic)
        let state = AppState(
            defaults: defaults,
            historyRepository: FileHistoryRepository(rootURL: rootURL)
        )
        state.polishEnabled = false
        let started = state.beginHistoryRecording(
            date: Date(),
            durationSeconds: 5,
            language: "en",
            context: nil,
            recordingURL: sourceURL
        )
        state.failHistoryItem(id: started.itemID, message: "Network unavailable")
        let injector = HistoryTestInjector()
        let controller = HistoryController(
            appState: state,
            transcriptionClient: ImmediateHistoryTranscriptionClient(text: "Retry succeeded"),
            injector: injector
        )

        controller.retry(itemID: started.itemID)
        await waitUntil {
            state.historyItem(id: started.itemID)?.status == .succeeded
        }

        XCTAssertEqual(state.history.count, 1)
        XCTAssertEqual(state.history[0].id, started.itemID)
        XCTAssertEqual(state.history[0].text, "Retry succeeded")
        XCTAssertTrue(injector.insertions.isEmpty)

        controller.copy(itemID: started.itemID)

        XCTAssertEqual(injector.copiedTexts, ["Retry succeeded"])
        XCTAssertEqual(controller.feedbackMessage, "Copied transcript")
        state.flushHistoryPersistence()
    }

    func testFailedDeletionDuringRetryRestoresActionableFailedState() async throws {
        let suiteName = "HistoryControllerTests.DeleteFailure.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let repository = FailingDeleteHistoryRepository()
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-delete-source-\(UUID().uuidString).wav")
        try Data("audio".utf8).write(to: sourceURL, options: .atomic)
        let state = AppState(defaults: defaults, historyRepository: repository)
        state.polishEnabled = false
        let started = state.beginHistoryRecording(
            date: Date(),
            durationSeconds: 4,
            language: "en",
            context: nil,
            recordingURL: sourceURL
        )
        state.failHistoryItem(id: started.itemID, message: "Offline")
        let controller = HistoryController(
            appState: state,
            transcriptionClient: CancellableHistoryTranscriptionClient(),
            injector: HistoryTestInjector()
        )
        controller.retry(itemID: started.itemID)
        await waitUntil {
            state.historyItem(id: started.itemID)?.status == .retrying
        }

        controller.delete(itemID: started.itemID)
        await Task.yield()

        XCTAssertEqual(state.historyItem(id: started.itemID)?.status, .failed)
        XCTAssertEqual(
            state.historyItem(id: started.itemID)?.errorMessage,
            "Deletion failed. You can retry this transcript again."
        )
        XCTAssertTrue(controller.feedbackMessage?.contains("Couldn’t delete transcript") == true)
        XCTAssertNotNil(state.historyAudioURL(for: started.itemID))
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
final class HomeViewSmokeTests: XCTestCase {
    func testHomeViewRendersGroupedHistoryStatesAndStats() throws {
        let suiteName = "HomeViewSmokeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WisprLocal-HomeViewTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: rootURL)
        }
        let repository = FileHistoryRepository(rootURL: rootURL)
        let audioSource = FileManager.default.temporaryDirectory
            .appendingPathComponent("home-view-source-\(UUID().uuidString).wav")
        try Data("audio".utf8).write(to: audioSource, options: .atomic)
        let failedID = UUID()
        let audio = try repository.archiveAudio(from: audioSource, itemID: failedID)
        let now = Date()
        try repository.saveHistory([
            HistoryItem(
                id: UUID(),
                date: now,
                text: "Draft the launch summary for the product team.",
                durationSeconds: 8,
                bundleIdentifier: "com.apple.Notes",
                applicationName: "Notes",
                language: "en"
            ),
            HistoryItem(
                id: failedID,
                date: now.addingTimeInterval(-300),
                text: "",
                status: .failed,
                errorMessage: "The network connection was lost.",
                durationSeconds: 5,
                bundleIdentifier: "com.apple.mail",
                applicationName: "Mail",
                language: "en",
                audioFilename: audio.filename
            ),
            HistoryItem(
                id: UUID(),
                date: Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now,
                text: "Yesterday’s follow-up is ready to send.",
                durationSeconds: 7,
                applicationName: "Messages"
            )
        ])
        let state = AppState(defaults: defaults, historyRepository: repository)
        let controller = HistoryController(
            appState: state,
            transcriptionClient: ImmediateHistoryTranscriptionClient(text: "Retried"),
            injector: HistoryTestInjector()
        )
        let size = NSSize(width: 920, height: 760)
        let hostingView = NSHostingView(
            rootView: HomeView(controller: controller)
                .environmentObject(state)
                .frame(width: size.width, height: size.height)
        )
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let representation = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let image = NSImage(size: size)
        image.addRepresentation(representation)
        let attachment = XCTAttachment(image: image)
        attachment.name = "Flow-style Home History"
        attachment.lifetime = .keepAlways
        add(attachment)
        let pngData = try XCTUnwrap(
            representation.representation(using: .png, properties: [:])
        )
        try pngData.write(
            to: URL(fileURLWithPath: "/tmp/wisprlocal-home-history.png"),
            options: .atomic
        )

        XCTAssertEqual(hostingView.bounds.size, size)
        XCTAssertGreaterThan(pngData.count, 10_000)
    }
}

@MainActor
private final class HistoryTestInjector: TextInjecting {
    struct Insertion: Equatable {
        let text: String
        let pressEnter: Bool
    }

    private(set) var insertions: [Insertion] = []
    private(set) var copiedTexts: [String] = []

    func insert(text: String, pressEnter: Bool) async throws {
        insertions.append(.init(text: text, pressEnter: pressEnter))
    }

    func copy(text: String) throws {
        copiedTexts.append(text)
    }
}

private final class ImmediateHistoryTranscriptionClient: TranscriptionServing {
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
        PolishResult(text: text, promptTokens: 0, completionTokens: 0)
    }
}

private final class CancellableHistoryTranscriptionClient: TranscriptionServing {
    func transcribe(
        fileURL: URL,
        language: String?,
        vocabularyPrompt: String?
    ) async throws -> String {
        try await Task.sleep(nanoseconds: 30_000_000_000)
        return "Too late"
    }

    func polishTranscript(text: String) async throws -> PolishResult {
        PolishResult(text: text, promptTokens: 0, completionTokens: 0)
    }
}

private final class SlowHistoryRepository: HistoryPersisting {
    private let lock = NSLock()
    private(set) var saveCount = 0

    func loadHistory(legacyData: Data?) -> HistoryLoadResult {
        HistoryLoadResult(items: [], recoveryMessage: nil)
    }

    func saveHistory(_ items: [HistoryItem]) throws {
        Thread.sleep(forTimeInterval: 0.2)
        lock.lock()
        saveCount += 1
        lock.unlock()
    }

    func archiveAudio(from sourceURL: URL, itemID: UUID) throws -> HistoryRecordingAsset {
        HistoryRecordingAsset(filename: sourceURL.lastPathComponent, url: sourceURL)
    }

    func audioURL(for filename: String) -> URL? { nil }
    func deleteAudio(filename: String) throws {}
}

private final class FailingDeleteHistoryRepository: HistoryPersisting {
    private var retainedAudioURL: URL?

    func loadHistory(legacyData: Data?) -> HistoryLoadResult {
        HistoryLoadResult(items: [], recoveryMessage: nil)
    }

    func saveHistory(_ items: [HistoryItem]) throws {}

    func archiveAudio(from sourceURL: URL, itemID: UUID) throws -> HistoryRecordingAsset {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-delete-retained-\(itemID.uuidString).wav")
        try FileManager.default.moveItem(at: sourceURL, to: destination)
        retainedAudioURL = destination
        return HistoryRecordingAsset(filename: destination.lastPathComponent, url: destination)
    }

    func audioURL(for filename: String) -> URL? {
        guard let retainedAudioURL,
              FileManager.default.fileExists(atPath: retainedAudioURL.path) else {
            return nil
        }
        return retainedAudioURL
    }

    func deleteAudio(filename: String) throws {
        throw HistoryTestError.forcedDeleteFailure
    }
}

private enum HistoryTestError: LocalizedError {
    case forcedDeleteFailure

    var errorDescription: String? {
        "Forced audio deletion failure"
    }
}

private struct RepositoryFixture {
    let suiteName: String
    let defaults: UserDefaults
    let rootURL: URL

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: rootURL)
    }
}
