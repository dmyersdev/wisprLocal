import Foundation

enum HistoryStatus: String, Codable, Equatable {
    case transcribing
    case succeeded
    case empty
    case failed
    case retrying

    var isInProgress: Bool {
        self == .transcribing || self == .retrying
    }
}

struct HistoryItem: Identifiable, Codable, Equatable {
    let id: UUID
    let date: Date
    var text: String
    var status: HistoryStatus
    var errorMessage: String?
    var durationSeconds: TimeInterval?
    var bundleIdentifier: String?
    var applicationName: String?
    var language: String?
    var audioFilename: String?

    var wordCount: Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    var wordsPerMinute: Int? {
        guard status == .succeeded,
              wordCount > 0,
              let durationSeconds,
              durationSeconds >= 1 else {
            return nil
        }
        return Int((Double(wordCount) * 60 / durationSeconds).rounded())
    }

    var displayApplicationName: String {
        applicationName?.trimmedOrNil ?? "Unknown app"
    }

    init(
        id: UUID,
        date: Date,
        text: String,
        status: HistoryStatus = .succeeded,
        errorMessage: String? = nil,
        durationSeconds: TimeInterval? = nil,
        bundleIdentifier: String? = nil,
        applicationName: String? = nil,
        language: String? = nil,
        audioFilename: String? = nil
    ) {
        self.id = id
        self.date = date
        self.text = text
        self.status = status
        self.errorMessage = errorMessage
        self.durationSeconds = durationSeconds
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.language = language
        self.audioFilename = audioFilename
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case date
        case text
        case status
        case errorMessage
        case durationSeconds
        case bundleIdentifier
        case applicationName
        case language
        case audioFilename
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        date = try container.decode(Date.self, forKey: .date)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        status = try container.decodeIfPresent(HistoryStatus.self, forKey: .status)
            ?? (text.isEmpty ? .empty : .succeeded)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        durationSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .durationSeconds)
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        applicationName = try container.decodeIfPresent(String.self, forKey: .applicationName)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        audioFilename = try container.decodeIfPresent(String.self, forKey: .audioFilename)
    }
}

struct HistoryStatistics: Equatable {
    let totalWords: Int
    let totalDictations: Int
    let daysUsed: Int
    let currentStreak: Int
    let averageWordsPerMinute: Int?

    init(
        items: [HistoryItem],
        calendar: Calendar = .autoupdatingCurrent,
        now: Date = Date()
    ) {
        let successfulItems = items.filter { $0.status == .succeeded }
        totalWords = successfulItems.reduce(0) { $0 + $1.wordCount }
        totalDictations = successfulItems.count

        let usedDays = Set(successfulItems.map { calendar.startOfDay(for: $0.date) })
        daysUsed = usedDays.count
        currentStreak = Self.streak(usedDays: usedDays, calendar: calendar, now: now)

        let timedItems = successfulItems.filter {
            $0.wordCount > 0 && ($0.durationSeconds ?? 0) >= 1
        }
        let timedWords = timedItems.reduce(0) { $0 + $1.wordCount }
        let timedDuration = timedItems.reduce(0.0) { $0 + ($1.durationSeconds ?? 0) }
        averageWordsPerMinute = timedDuration > 0
            ? Int((Double(timedWords) * 60 / timedDuration).rounded())
            : nil
    }

    private static func streak(
        usedDays: Set<Date>,
        calendar: Calendar,
        now: Date
    ) -> Int {
        var cursor = calendar.startOfDay(for: now)
        if !usedDays.contains(cursor) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor),
                  usedDays.contains(yesterday) else {
                return 0
            }
            cursor = yesterday
        }

        var result = 0
        while usedDays.contains(cursor) {
            result += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else {
                break
            }
            cursor = previous
        }
        return result
    }
}

struct HistoryDaySection: Identifiable, Equatable {
    let day: Date
    let items: [HistoryItem]

    var id: Date { day }

    func title(calendar: Calendar = .autoupdatingCurrent) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }
}

enum HistoryTimeline {
    static func sections(
        from items: [HistoryItem],
        matching query: String,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [HistoryDaySection] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty ? items : items.filter {
            $0.text.localizedCaseInsensitiveContains(query)
                || $0.displayApplicationName.localizedCaseInsensitiveContains(query)
        }
        let groups = Dictionary(grouping: filtered) {
            calendar.startOfDay(for: $0.date)
        }
        return groups.keys.sorted(by: >).map { day in
            HistoryDaySection(
                day: day,
                items: groups[day, default: []].sorted { $0.date > $1.date }
            )
        }
    }
}

enum HistoryStore {
    static let currentVersion = 1

    struct LoadResult {
        let items: [HistoryItem]
        let rejectedRecordCount: Int
        let needsMigration: Bool
        let recoveredInterruptedCount: Int
        let isUnsupportedVersion: Bool

        var shouldBackUpOriginal: Bool { rejectedRecordCount > 0 }
        var needsRewrite: Bool {
            needsMigration || rejectedRecordCount > 0 || recoveredInterruptedCount > 0
        }
    }

    private struct Envelope: Encodable {
        let version: Int
        let records: [HistoryItem]
    }

    static func encode(_ items: [HistoryItem]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(
            Envelope(
                version: currentVersion,
                records: items.sorted { $0.date > $1.date }
            )
        )
    }

    static func decode(_ data: Data) -> LoadResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            return LoadResult(
                items: [],
                rejectedRecordCount: 1,
                needsMigration: false,
                recoveredInterruptedCount: 0,
                isUnsupportedVersion: false
            )
        }

        let rawRecords: [Any]
        let needsMigration: Bool
        if let legacyRecords = root as? [Any] {
            rawRecords = legacyRecords
            needsMigration = true
        } else if let envelope = root as? [String: Any],
                  let version = envelope["version"] as? Int {
            guard version == currentVersion else {
                return LoadResult(
                    items: [],
                    rejectedRecordCount: 0,
                    needsMigration: false,
                    recoveredInterruptedCount: 0,
                    isUnsupportedVersion: true
                )
            }
            guard let records = envelope["records"] as? [Any] else {
                return LoadResult(
                    items: [],
                    rejectedRecordCount: 1,
                    needsMigration: false,
                    recoveredInterruptedCount: 0,
                    isUnsupportedVersion: false
                )
            }
            rawRecords = records
            needsMigration = false
        } else {
            return LoadResult(
                items: [],
                rejectedRecordCount: 1,
                needsMigration: false,
                recoveredInterruptedCount: 0,
                isUnsupportedVersion: false
            )
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var items: [HistoryItem] = []
        var seenIdentifiers = Set<UUID>()
        var rejectedRecordCount = 0
        var recoveredInterruptedCount = 0

        for rawRecord in rawRecords {
            guard JSONSerialization.isValidJSONObject(rawRecord),
                  let recordData = try? JSONSerialization.data(withJSONObject: rawRecord),
                  var item = try? decoder.decode(HistoryItem.self, from: recordData),
                  seenIdentifiers.insert(item.id).inserted else {
                rejectedRecordCount += 1
                continue
            }

            item = normalized(item)
            if item.status.isInProgress {
                item.status = .failed
                item.errorMessage = "Dictation was interrupted before transcription finished."
                recoveredInterruptedCount += 1
            }
            items.append(item)
        }

        return LoadResult(
            items: items.sorted { $0.date > $1.date },
            rejectedRecordCount: rejectedRecordCount,
            needsMigration: needsMigration,
            recoveredInterruptedCount: recoveredInterruptedCount,
            isUnsupportedVersion: false
        )
    }

    private static func normalized(_ item: HistoryItem) -> HistoryItem {
        var item = item
        if item.status == .succeeded, item.text.trimmedOrNil == nil {
            item.status = .empty
        }
        if let duration = item.durationSeconds,
           !duration.isFinite || duration <= 0 {
            item.durationSeconds = nil
        }
        item.bundleIdentifier = item.bundleIdentifier?.trimmedOrNil?.lowercased()
        item.applicationName = item.applicationName?.trimmedOrNil
        item.language = item.language?.trimmedOrNil
        if let filename = item.audioFilename?.trimmedOrNil,
           filename == (filename as NSString).lastPathComponent,
           filename != ".",
           filename != ".." {
            item.audioFilename = filename
        } else {
            item.audioFilename = nil
        }
        item.errorMessage = item.errorMessage?.trimmedOrNil
        return item
    }
}

struct HistoryLoadResult {
    let items: [HistoryItem]
    let recoveryMessage: String?
    let didImportLegacyHistory: Bool

    init(
        items: [HistoryItem],
        recoveryMessage: String?,
        didImportLegacyHistory: Bool = false
    ) {
        self.items = items
        self.recoveryMessage = recoveryMessage
        self.didImportLegacyHistory = didImportLegacyHistory
    }
}

struct HistoryRecordingAsset {
    let filename: String
    let url: URL
}

struct HistoryRecordingStart {
    let itemID: UUID
    let transcriptionURL: URL
    let shouldDeleteTranscriptionURL: Bool
}

protocol HistoryPersisting: AnyObject {
    func loadHistory(legacyData: Data?) -> HistoryLoadResult
    func saveHistory(_ items: [HistoryItem]) throws
    func archiveAudio(from sourceURL: URL, itemID: UUID) throws -> HistoryRecordingAsset
    func audioURL(for filename: String) -> URL?
    func deleteAudio(filename: String) throws
}

final class HistoryPersistenceCoordinator {
    private let repository: HistoryPersisting
    private let queue = DispatchQueue(
        label: "com.wisprlocal.history-persistence",
        qos: .utility
    )

    init(repository: HistoryPersisting) {
        self.repository = repository
    }

    func save(
        _ items: [HistoryItem],
        deletingAudioFilename: String? = nil,
        completion: @escaping @MainActor (Error?) -> Void
    ) {
        queue.async { [repository] in
            let result: Error?
            do {
                try repository.saveHistory(items)
                if let deletingAudioFilename {
                    try repository.deleteAudio(filename: deletingAudioFilename)
                }
                result = nil
            } catch {
                result = error
            }
            Task { @MainActor in
                completion(result)
            }
        }
    }

    func saveSynchronously(
        _ items: [HistoryItem],
        deletingAudioFilename: String? = nil
    ) throws {
        try queue.sync { [repository] in
            try repository.saveHistory(items)
            if let deletingAudioFilename {
                try repository.deleteAudio(filename: deletingAudioFilename)
            }
        }
    }
}

final class FileHistoryRepository: HistoryPersisting {
    private let rootURL: URL
    private let fileManager: FileManager

    private var metadataURL: URL { rootURL.appendingPathComponent("history.json") }
    private var audioDirectoryURL: URL { rootURL.appendingPathComponent("Audio", isDirectory: true) }
    private var recoveryDirectoryURL: URL { rootURL.appendingPathComponent("Recovery", isDirectory: true) }

    convenience init(fileManager: FileManager = .default) {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        self.init(
            rootURL: applicationSupport
                .appendingPathComponent("WisprLocal", isDirectory: true)
                .appendingPathComponent("History", isDirectory: true),
            fileManager: fileManager
        )
    }

    init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    func loadHistory(legacyData: Data?) -> HistoryLoadResult {
        let sourceData: Data
        let sourceURL: URL?
        if fileManager.fileExists(atPath: metadataURL.path) {
            do {
                sourceData = try Data(contentsOf: metadataURL)
            } catch {
                return HistoryLoadResult(
                    items: [],
                    recoveryMessage: "History couldn’t be read from disk. The original file was left untouched."
                )
            }
            sourceURL = metadataURL
        } else if let legacyData {
            sourceData = legacyData
            sourceURL = nil
        } else {
            return HistoryLoadResult(items: [], recoveryMessage: nil)
        }

        let result = HistoryStore.decode(sourceData)
        if result.isUnsupportedVersion {
            return HistoryLoadResult(
                items: [],
                recoveryMessage: "History was created by a newer version of WisprLocal and was left untouched."
            )
        }

        var maintenanceMessages: [String] = []
        var backupSucceeded = true
        if result.shouldBackUpOriginal {
            do {
                try backUp(data: sourceData, sourceURL: sourceURL)
            } catch {
                backupSucceeded = false
                maintenanceMessages.append(
                    "The original history couldn’t be backed up, so it was left untouched."
                )
            }
        }

        var rewriteSucceeded = !result.needsRewrite
        if result.needsRewrite, backupSucceeded {
            do {
                try saveHistory(result.items)
                rewriteSucceeded = true
            } catch {
                maintenanceMessages.append(
                    "Recovered history is available for this session, but couldn’t be saved; the original was left untouched."
                )
            }
        }

        let messages = [
            result.rejectedRecordCount > 0
                ? "Recovered history after ignoring \(result.rejectedRecordCount) invalid saved record\(result.rejectedRecordCount == 1 ? "" : "s")."
                : nil,
            result.recoveredInterruptedCount > 0
                ? "Marked \(result.recoveredInterruptedCount) interrupted dictation\(result.recoveredInterruptedCount == 1 ? "" : "s") as retryable."
                : nil
        ].compactMap { $0 } + maintenanceMessages
        return HistoryLoadResult(
            items: result.items,
            recoveryMessage: messages.isEmpty ? nil : messages.joined(separator: " "),
            didImportLegacyHistory: sourceURL == nil && rewriteSucceeded
        )
    }

    func saveHistory(_ items: [HistoryItem]) throws {
        try ensureDirectories()
        try HistoryStore.encode(items).write(to: metadataURL, options: .atomic)
    }

    func archiveAudio(from sourceURL: URL, itemID: UUID) throws -> HistoryRecordingAsset {
        try ensureDirectories()
        let pathExtension = sourceURL.pathExtension.isEmpty ? "wav" : sourceURL.pathExtension
        let filename = itemID.uuidString.lowercased() + "." + pathExtension.lowercased()
        let destinationURL = audioDirectoryURL.appendingPathComponent(filename)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
        return HistoryRecordingAsset(filename: filename, url: destinationURL)
    }

    func audioURL(for filename: String) -> URL? {
        guard let url = safeAudioURL(for: filename) else { return nil }
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func deleteAudio(filename: String) throws {
        guard let url = safeAudioURL(for: filename) else { return }
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func ensureDirectories() throws {
        for url in [rootURL, audioDirectoryURL, recoveryDirectoryURL] {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        }
    }

    private func backUp(data: Data, sourceURL: URL?) throws {
        try ensureDirectories()
        let timestamp = Int(Date().timeIntervalSince1970)
        let prefix = sourceURL == nil ? "legacy-history" : "history"
        let destination = recoveryDirectoryURL
            .appendingPathComponent("\(prefix)-\(timestamp)-\(UUID().uuidString).backup")
        try data.write(to: destination, options: .atomic)
    }

    private func safeAudioURL(for filename: String) -> URL? {
        guard filename == (filename as NSString).lastPathComponent,
              filename != ".",
              filename != ".." else {
            return nil
        }
        return audioDirectoryURL.appendingPathComponent(filename)
    }
}

final class DefaultsHistoryRepository: HistoryPersisting {
    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let audioDirectoryURL: URL

    init(defaults: UserDefaults, fileManager: FileManager = .default) {
        self.defaults = defaults
        self.fileManager = fileManager
        audioDirectoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("WisprLocal-History-\(UUID().uuidString)", isDirectory: true)
    }

    func loadHistory(legacyData: Data?) -> HistoryLoadResult {
        guard let legacyData else {
            return HistoryLoadResult(items: [], recoveryMessage: nil)
        }
        let result = HistoryStore.decode(legacyData)
        if result.isUnsupportedVersion {
            return HistoryLoadResult(
                items: [],
                recoveryMessage: "History was created by a newer version of WisprLocal and was left untouched."
            )
        }
        if result.shouldBackUpOriginal {
            defaults.set(legacyData, forKey: DefaultsKeys.historyRecovery)
        }
        if result.needsRewrite {
            try? saveHistory(result.items)
        }
        let recoveryMessage = result.rejectedRecordCount > 0
            ? "Recovered history after ignoring invalid saved records."
            : nil
        return HistoryLoadResult(items: result.items, recoveryMessage: recoveryMessage)
    }

    func saveHistory(_ items: [HistoryItem]) throws {
        defaults.set(try HistoryStore.encode(items), forKey: DefaultsKeys.history)
    }

    func archiveAudio(from sourceURL: URL, itemID: UUID) throws -> HistoryRecordingAsset {
        try fileManager.createDirectory(
            at: audioDirectoryURL,
            withIntermediateDirectories: true
        )
        let pathExtension = sourceURL.pathExtension.isEmpty ? "wav" : sourceURL.pathExtension
        let filename = itemID.uuidString.lowercased() + "." + pathExtension.lowercased()
        let destinationURL = audioDirectoryURL.appendingPathComponent(filename)
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
        return HistoryRecordingAsset(filename: filename, url: destinationURL)
    }

    func audioURL(for filename: String) -> URL? {
        guard let url = safeAudioURL(for: filename) else { return nil }
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func deleteAudio(filename: String) throws {
        guard let url = safeAudioURL(for: filename) else { return }
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func safeAudioURL(for filename: String) -> URL? {
        guard filename == (filename as NSString).lastPathComponent,
              filename != ".",
              filename != ".." else {
            return nil
        }
        return audioDirectoryURL.appendingPathComponent(filename)
    }
}
