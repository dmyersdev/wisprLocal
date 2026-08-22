import Foundation

enum SnippetStore {
    static let currentVersion = 1

    struct LoadResult {
        let snippets: [Snippet]
        let rejectedRecordCount: Int
        let needsMigration: Bool

        var shouldBackUpOriginal: Bool {
            rejectedRecordCount > 0
        }
    }

    private struct Envelope: Codable {
        let version: Int
        let snippets: [Snippet]
    }

    static func encode(_ snippets: [Snippet]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Envelope(version: currentVersion, snippets: snippets))
    }

    static func decode(_ data: Data) -> LoadResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            return LoadResult(snippets: [], rejectedRecordCount: 1, needsMigration: false)
        }

        let records: [Any]
        let needsMigration: Bool
        if let envelope = root as? [String: Any] {
            guard let version = envelope["version"] as? Int,
                  version == currentVersion,
                  let snippets = envelope["snippets"] as? [Any] else {
                return LoadResult(snippets: [], rejectedRecordCount: 1, needsMigration: false)
            }
            records = snippets
            needsMigration = false
        } else if let legacySnippets = root as? [Any] {
            records = legacySnippets
            needsMigration = true
        } else {
            return LoadResult(snippets: [], rejectedRecordCount: 1, needsMigration: false)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var decodedSnippets: [Snippet] = []
        var rejectedRecordCount = 0

        for record in records {
            guard JSONSerialization.isValidJSONObject(record),
                  let recordData = try? JSONSerialization.data(withJSONObject: record),
                  let snippet = try? decoder.decode(Snippet.self, from: recordData) else {
                rejectedRecordCount += 1
                continue
            }
            decodedSnippets.append(snippet)
        }

        return LoadResult(
            snippets: decodedSnippets.sorted { $0.editedAt > $1.editedAt },
            rejectedRecordCount: rejectedRecordCount,
            needsMigration: needsMigration
        )
    }
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    enum State: Equatable {
        case idle
        case listening
        case transcribing
        case commandListening
        case commandProcessing
        case scratchpadListening
        case scratchpadProcessing
        case error(String)
    }

    @Published var state: State = .idle {
        didSet {
            if case .error(let message) = state {
                lastErrorMessage = message
            }
        }
    }
    @Published var lastTranscript: String = ""
    @Published private(set) var history: [HistoryItem] = []
    @Published private(set) var historyRecoveryMessage: String?
    @Published var historyFeedbackMessage: String?
    @Published private(set) var snippets: [Snippet] = []
    @Published private(set) var snippetRecoveryMessage: String?
    @Published private(set) var dictionaryEntries: [DictionaryEntry] = []
    @Published private(set) var dictionaryRecoveryMessage: String?
    @Published private(set) var stylePreferences: StylePreferences
    @Published private(set) var styleRecoveryMessage: String?
    @Published private(set) var transformSettings: TransformSettings
    @Published private(set) var transformRecoveryMessage: String?
    @Published var transformFeedbackMessage: String?
    @Published var isTransformResultPresented = false
    @Published var lastTransformResult: TransformResult?
    @Published var commandFeedbackMessage: String?
    @Published var lastCommandResult: CommandModeResult?
    @Published var dictionarySortOrder: DictionarySortOrder {
        didSet { defaults.set(dictionarySortOrder.rawValue, forKey: DefaultsKeys.dictionarySortOrder) }
    }
    @Published var lastErrorMessage: String?
    @Published var hotkeyDisplay: String = "fn"
    @Published var holdToTalk: Bool {
        didSet { defaults.set(holdToTalk, forKey: DefaultsKeys.holdToTalk) }
    }
    @Published var language: String {
        didSet { defaults.set(language, forKey: DefaultsKeys.language) }
    }
    @Published var polishEnabled: Bool {
        didSet { defaults.set(polishEnabled, forKey: DefaultsKeys.polishEnabled) }
    }
    @Published var pressEnterEnabled: Bool {
        didSet { defaults.set(pressEnterEnabled, forKey: DefaultsKeys.pressEnterEnabled) }
    }
    @Published var commandModeEnabled: Bool {
        didSet { defaults.set(commandModeEnabled, forKey: DefaultsKeys.commandModeEnabled) }
    }
    @Published var tokensSent: Int {
        didSet { defaults.set(tokensSent, forKey: DefaultsKeys.tokensSent) }
    }
    @Published var tokensReceived: Int {
        didSet { defaults.set(tokensReceived, forKey: DefaultsKeys.tokensReceived) }
    }
    @Published var hotkeyWarning: String?
    @Published var handsFreeHotkeyWarning: String?
    @Published var recoveryHotkeyWarning: String?
    @Published var transformHotkeyWarning: String?
    @Published var commandHotkeyWarning: String?
    @Published var scratchpadHotkeyWarning: String?
    @Published private(set) var activeDictationMode: DictationRecordingMode?
    @Published private(set) var dictationSessionWarning: String?
    @Published var handsFreeHotkey: Hotkey {
        didSet {
            if let data = try? JSONEncoder().encode(handsFreeHotkey) {
                defaults.set(data, forKey: DefaultsKeys.handsFreeHotkey)
            }
        }
    }

    private let defaults: UserDefaults
    private let historyRepository: HistoryPersisting
    private let historyPersistence: HistoryPersistenceCoordinator

    init(
        defaults: UserDefaults = .standard,
        historyRepository: HistoryPersisting? = nil
    ) {
        self.defaults = defaults
        let resolvedHistoryRepository = historyRepository
            ?? (defaults === UserDefaults.standard
                ? FileHistoryRepository()
                : DefaultsHistoryRepository(defaults: defaults))
        self.historyRepository = resolvedHistoryRepository
        historyPersistence = HistoryPersistenceCoordinator(
            repository: resolvedHistoryRepository
        )
        language = defaults.string(forKey: DefaultsKeys.language) ?? ""
        if defaults.object(forKey: DefaultsKeys.polishEnabled) == nil {
            polishEnabled = true
        } else {
            polishEnabled = defaults.bool(forKey: DefaultsKeys.polishEnabled)
        }
        if defaults.object(forKey: DefaultsKeys.pressEnterEnabled) == nil {
            pressEnterEnabled = true
        } else {
            pressEnterEnabled = defaults.bool(forKey: DefaultsKeys.pressEnterEnabled)
        }
        commandModeEnabled = defaults.bool(forKey: DefaultsKeys.commandModeEnabled)
        if defaults.object(forKey: DefaultsKeys.holdToTalk) == nil {
            holdToTalk = true
        } else {
            holdToTalk = defaults.bool(forKey: DefaultsKeys.holdToTalk)
        }
        tokensSent = defaults.integer(forKey: DefaultsKeys.tokensSent)
        tokensReceived = defaults.integer(forKey: DefaultsKeys.tokensReceived)
        if let data = defaults.data(forKey: DefaultsKeys.handsFreeHotkey),
           let storedHotkey = try? JSONDecoder().decode(Hotkey.self, from: data),
           storedHotkey.kind == .carbon {
            handsFreeHotkey = storedHotkey
        } else {
            handsFreeHotkey = .handsFreeDefault
        }
        dictionarySortOrder = DictionarySortOrder(
            rawValue: defaults.string(forKey: DefaultsKeys.dictionarySortOrder) ?? ""
        ) ?? .starredFirst
        let loadedHistory = self.historyRepository.loadHistory(
            legacyData: defaults.data(forKey: DefaultsKeys.history)
        )
        history = loadedHistory.items
        historyRecoveryMessage = loadedHistory.recoveryMessage
        if loadedHistory.didImportLegacyHistory {
            defaults.removeObject(forKey: DefaultsKeys.history)
        }
        let loadedSnippets = Self.loadSnippets(defaults: defaults)
        snippets = loadedSnippets.snippets
        snippetRecoveryMessage = loadedSnippets.recoveryMessage
        let loadedDictionary = Self.loadDictionary(defaults: defaults)
        dictionaryEntries = loadedDictionary.entries
        dictionaryRecoveryMessage = loadedDictionary.recoveryMessage
        let loadedStyles = Self.loadStyles(defaults: defaults)
        stylePreferences = loadedStyles.preferences
        styleRecoveryMessage = loadedStyles.recoveryMessage
        let loadedTransforms = Self.loadTransforms(defaults: defaults)
        transformSettings = loadedTransforms.settings
        transformRecoveryMessage = loadedTransforms.recoveryMessage
        lastTranscript = history.first {
            $0.status == .succeeded && !$0.text.isEmpty
        }?.text ?? ""
    }

    func setState(_ newState: State) {
        if newState != .listening {
            activeDictationMode = nil
            dictationSessionWarning = nil
        }
        state = newState
    }

    func setListening(mode: DictationRecordingMode) {
        activeDictationMode = mode
        dictationSessionWarning = nil
        state = .listening
    }

    func updateActiveDictationMode(_ mode: DictationRecordingMode) {
        guard state == .listening else { return }
        activeDictationMode = mode
    }

    func setDictationSessionWarning(_ warning: String?) {
        guard state == .listening else { return }
        dictationSessionWarning = warning
    }

    func setError(_ error: Error) {
        state = .error(error.localizedDescription)
    }

    @discardableResult
    func addHistory(text: String) -> UUID {
        let item = HistoryItem(
            id: UUID(),
            date: Date(),
            text: text,
            status: text.trimmedOrNil == nil ? .empty : .succeeded
        )
        history.insert(item, at: 0)
        persistHistoryBestEffort()
        return item.id
    }

    func beginHistoryRecording(
        date: Date,
        durationSeconds: TimeInterval?,
        language: String?,
        context: StyleAppContext?,
        recordingURL: URL
    ) -> HistoryRecordingStart {
        let itemID = UUID()
        let archivedAsset: HistoryRecordingAsset?
        do {
            archivedAsset = try historyRepository.archiveAudio(
                from: recordingURL,
                itemID: itemID
            )
        } catch {
            archivedAsset = nil
            historyFeedbackMessage = "The transcript will be saved, but its recording couldn’t be retained for retry."
        }

        let item = HistoryItem(
            id: itemID,
            date: date,
            text: "",
            status: .transcribing,
            durationSeconds: durationSeconds,
            bundleIdentifier: context?.bundleIdentifier,
            applicationName: context?.applicationName,
            language: language,
            audioFilename: archivedAsset?.filename
        )
        history.insert(item, at: 0)

        persistHistoryBestEffort()

        return HistoryRecordingStart(
            itemID: itemID,
            transcriptionURL: archivedAsset?.url ?? recordingURL,
            shouldDeleteTranscriptionURL: archivedAsset == nil
        )
    }

    func updateHistoryContext(id: UUID, context: StyleAppContext?) {
        guard let index = history.firstIndex(where: { $0.id == id }) else { return }
        history[index].bundleIdentifier = context?.bundleIdentifier
        history[index].applicationName = context?.applicationName
        persistHistoryBestEffort()
    }

    func finishHistoryItem(id: UUID, text: String) {
        guard let index = history.firstIndex(where: { $0.id == id }) else { return }
        history[index].text = text
        history[index].status = text.trimmedOrNil == nil ? .empty : .succeeded
        history[index].errorMessage = nil
        let audioToDelete = history[index].status == .succeeded
            ? history[index].audioFilename
            : nil
        if audioToDelete != nil {
            history[index].audioFilename = nil
        }
        if !text.isEmpty {
            lastTranscript = text
        }
        persistHistoryBestEffort(deletingAudioFilename: audioToDelete)
    }

    func failHistoryItem(id: UUID, message: String) {
        guard let index = history.firstIndex(where: { $0.id == id }),
              history[index].status.isInProgress else {
            return
        }
        history[index].status = .failed
        history[index].errorMessage = message
        persistHistoryBestEffort()
    }

    @discardableResult
    func markHistoryItemRetrying(id: UUID) -> Bool {
        guard let index = history.firstIndex(where: { $0.id == id }),
              history[index].status == .failed || history[index].status == .empty,
              historyAudioURL(for: id) != nil else {
            return false
        }
        history[index].status = .retrying
        history[index].errorMessage = nil
        persistHistoryBestEffort()
        return true
    }

    func historyItem(id: UUID) -> HistoryItem? {
        history.first { $0.id == id }
    }

    func historyAudioURL(for id: UUID) -> URL? {
        guard let filename = historyItem(id: id)?.audioFilename else { return nil }
        return historyRepository.audioURL(for: filename)
    }

    func deleteHistoryItem(id: UUID) throws {
        guard let index = history.firstIndex(where: { $0.id == id }) else { return }
        let item = history.remove(at: index)
        do {
            try persistHistory()
            if let filename = item.audioFilename {
                try historyRepository.deleteAudio(filename: filename)
            }
        } catch {
            var restoredItem = item
            if restoredItem.status.isInProgress {
                restoredItem.status = .failed
                restoredItem.errorMessage = "Deletion failed. You can retry this transcript again."
            }
            history.insert(restoredItem, at: min(index, history.count))
            try? persistHistory()
            throw error
        }
        if lastTranscript == item.text {
            lastTranscript = history.first(where: { $0.status == .succeeded })?.text ?? ""
        }
    }

    func addTokenUsage(prompt: Int, completion: Int) {
        tokensSent += prompt
        tokensReceived += completion
    }

    func flushHistoryPersistence() {
        do {
            try persistHistory()
        } catch {
            historyFeedbackMessage = "History couldn’t be saved to disk. Recent changes may not survive a restart."
        }
    }

    @discardableResult
    func saveSnippet(id: UUID? = nil, trigger: String, expansion: String) throws -> Snippet {
        let normalizedTrigger = Snippet.normalizedTrigger(trigger)

        guard !normalizedTrigger.isEmpty else {
            throw SnippetValidationError.emptyTrigger
        }
        guard !expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SnippetValidationError.emptyExpansion
        }
        guard normalizedTrigger.count <= Snippet.triggerCharacterLimit else {
            throw SnippetValidationError.triggerTooLong
        }
        guard expansion.count <= Snippet.expansionCharacterLimit else {
            throw SnippetValidationError.expansionTooLong
        }

        let hasDuplicate = snippets.contains { snippet in
            snippet.id != id && snippet.normalizedTrigger.caseInsensitiveCompare(normalizedTrigger) == .orderedSame
        }
        guard !hasDuplicate else {
            throw SnippetValidationError.duplicateTrigger
        }

        let now = Date()
        let snippet: Snippet
        if let id, let index = snippets.firstIndex(where: { $0.id == id }) {
            snippet = Snippet(
                id: id,
                trigger: normalizedTrigger,
                expansion: expansion,
                createdAt: snippets[index].createdAt,
                editedAt: now
            )
            snippets[index] = snippet
        } else {
            snippet = Snippet(
                id: id ?? UUID(),
                trigger: normalizedTrigger,
                expansion: expansion,
                createdAt: now,
                editedAt: now
            )
            snippets.append(snippet)
        }

        snippets.sort { $0.editedAt > $1.editedAt }
        persistSnippets()
        return snippet
    }

    func deleteSnippet(id: UUID) {
        snippets.removeAll { $0.id == id }
        persistSnippets()
    }

    @discardableResult
    func saveDictionaryEntry(
        id: UUID? = nil,
        word: String,
        misspelling: String?,
        isStarred: Bool
    ) throws -> DictionaryEntry {
        let otherEntries = dictionaryEntries.filter { $0.id != id }
        let normalized = try DictionaryEntryValidator.validate(
            word: word,
            misspelling: misspelling,
            against: otherEntries
        )

        let now = Date()
        let entry: DictionaryEntry
        if let id, let index = dictionaryEntries.firstIndex(where: { $0.id == id }) {
            entry = DictionaryEntry(
                id: id,
                word: normalized.word,
                misspelling: normalized.misspelling,
                isStarred: isStarred,
                createdAt: dictionaryEntries[index].createdAt,
                editedAt: now
            )
            dictionaryEntries[index] = entry
        } else {
            entry = DictionaryEntry(
                id: id ?? UUID(),
                word: normalized.word,
                misspelling: normalized.misspelling,
                isStarred: isStarred,
                createdAt: now,
                editedAt: now
            )
            dictionaryEntries.append(entry)
        }

        dictionaryEntries.sort { $0.editedAt > $1.editedAt }
        persistDictionary()
        return entry
    }

    func toggleDictionaryEntryStarred(id: UUID) {
        guard let index = dictionaryEntries.firstIndex(where: { $0.id == id }) else { return }
        let existing = dictionaryEntries[index]
        dictionaryEntries[index] = DictionaryEntry(
            id: existing.id,
            word: existing.word,
            misspelling: existing.misspelling,
            isStarred: !existing.isStarred,
            createdAt: existing.createdAt,
            editedAt: Date()
        )
        dictionaryEntries.sort { $0.editedAt > $1.editedAt }
        persistDictionary()
    }

    func deleteDictionaryEntry(id: UUID) {
        dictionaryEntries.removeAll { $0.id == id }
        persistDictionary()
    }

    func completeStyleSetup(selections: [StyleAppCategory: WritingStyle]) {
        var validatedSelections = StylePreferences.defaultSelections
        for category in StyleAppCategory.allCases {
            guard let style = selections[category],
                  WritingStyle.available(for: category).contains(style) else {
                continue
            }
            validatedSelections[category] = style
        }
        stylePreferences.hasCompletedSetup = true
        stylePreferences.selections = validatedSelections
        persistStylePreferences()
    }

    func setWritingStyle(_ style: WritingStyle, for category: StyleAppCategory) {
        guard stylePreferences.hasCompletedSetup,
              WritingStyle.available(for: category).contains(style) else {
            return
        }
        stylePreferences.selections[category] = style
        persistStylePreferences()
    }

    func assignStyleApplication(
        bundleIdentifier: String,
        applicationName: String,
        to category: StyleAppCategory
    ) {
        let identifier = bundleIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let name = applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty, !name.isEmpty else { return }

        stylePreferences.customAssignments.removeAll {
            $0.bundleIdentifier.caseInsensitiveCompare(identifier) == .orderedSame
        }
        stylePreferences.customAssignments.append(
            StyleAppAssignment(
                bundleIdentifier: identifier,
                applicationName: name,
                category: category
            )
        )
        stylePreferences.customAssignments.sort {
            $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName) == .orderedAscending
        }
        persistStylePreferences()
    }

    func removeStyleAssignment(bundleIdentifier: String) {
        let previousCount = stylePreferences.customAssignments.count
        stylePreferences.customAssignments.removeAll {
            $0.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
        }
        guard stylePreferences.customAssignments.count != previousCount else { return }
        persistStylePreferences()
    }

    func styledDictation(_ text: String, for context: StyleAppContext?) -> String {
        guard stylePreferences.hasCompletedSetup,
              WritingStyleLanguagePolicy.shouldApply(
                  configuredLanguage: language,
                  to: text
              ),
              let context else {
            return text
        }
        let category = StyleAppClassifier.category(
            for: context,
            preferences: stylePreferences
        )
        return TranscriptStyleFormatter.format(
            text,
            as: stylePreferences.style(for: category)
        )
    }

    func setTransformsEnabled(_ isEnabled: Bool) {
        transformSettings.isEnabled = isEnabled
        persistTransformSettings()
    }

    @discardableResult
    func saveTransform(
        id: UUID? = nil,
        kind: TransformKind = .custom,
        name: String,
        prompt: String,
        hotkey: Hotkey?,
        writingSamples: [TransformWritingSample]
    ) throws -> TransformDefinition {
        let now = Date()
        let definition: TransformDefinition

        switch kind {
        case .custom:
            let existing = id.flatMap { candidate in
                transformSettings.definitions.first { $0.id == candidate }
            }
            guard id != TransformDefinition.polishID,
                  id != TransformDefinition.promptEngineerID,
                  existing?.kind != .polish,
                  existing?.kind != .promptEngineer else {
                throw TransformValidationError.invalidIdentifier
            }
            if existing == nil,
               transformSettings.customDefinitions.count >= TransformDefinition.customTransformLimit {
                throw TransformValidationError.customTransformLimitReached
            }
            let normalized = try TransformDefinitionValidator.validateCustom(
                name: name,
                prompt: prompt,
                hotkey: hotkey,
                writingSamples: writingSamples,
                editingID: id,
                existingDefinitions: transformSettings.definitions
            )
            try validateAgainstDictationHotkey(normalized.hotkey)
            definition = TransformDefinition(
                id: id ?? UUID(),
                kind: .custom,
                name: normalized.name,
                prompt: normalized.prompt,
                hotkey: normalized.hotkey,
                writingSamples: normalized.writingSamples,
                createdAt: existing?.createdAt ?? now,
                editedAt: now
            )
        case .polish, .promptEngineer:
            definition = try makeUpdatedBuiltInTransform(
                kind: kind,
                prompt: prompt,
                hotkey: hotkey,
                writingSamples: writingSamples,
                editedAt: now
            )
        }

        if let index = transformSettings.definitions.firstIndex(where: {
            $0.id == definition.id
        }) {
            transformSettings.definitions[index] = definition
        } else {
            transformSettings.definitions.append(definition)
        }
        sortTransforms()
        persistTransformSettings()
        return definition
    }

    func deleteTransform(id: UUID) {
        guard let definition = transformSettings.definition(id: id),
              definition.kind == .custom else { return }
        transformSettings.definitions.removeAll { $0.id == id }
        if transformSettings.autoApplyTransformID == id {
            transformSettings.autoApplyTransformID = nil
        }
        persistTransformSettings()
    }

    func savePolishConfiguration(_ configuration: PolishConfiguration) throws {
        transformSettings.polishConfiguration = try validatedPolishConfiguration(configuration)
        persistTransformSettings()
    }

    @discardableResult
    func savePolishTransform(
        configuration: PolishConfiguration,
        hotkey: Hotkey?,
        writingSamples: [TransformWritingSample]
    ) throws -> TransformDefinition {
        let validatedConfiguration = try validatedPolishConfiguration(configuration)
        guard let existing = transformSettings.definition(id: TransformDefinition.polishID) else {
            throw TransformValidationError.invalidIdentifier
        }
        let definition = try makeUpdatedBuiltInTransform(
            kind: .polish,
            prompt: existing.prompt,
            hotkey: hotkey,
            writingSamples: writingSamples,
            editedAt: Date()
        )
        guard let index = transformSettings.definitions.firstIndex(where: {
            $0.id == TransformDefinition.polishID
        }) else {
            throw TransformValidationError.invalidIdentifier
        }
        transformSettings.polishConfiguration = validatedConfiguration
        transformSettings.definitions[index] = definition
        sortTransforms()
        persistTransformSettings()
        return definition
    }

    private func validatedPolishConfiguration(
        _ configuration: PolishConfiguration
    ) throws -> PolishConfiguration {
        var acceptedInstructions: [String] = []
        for instruction in configuration.customInstructions {
            let normalized = try TransformDefinitionValidator.validateCustomInstruction(
                instruction,
                existingInstructions: acceptedInstructions
            )
            acceptedInstructions.append(normalized)
        }
        var validated = configuration
        validated.customInstructions = acceptedInstructions
        return validated
    }

    func setAutoApplyTransformID(_ id: UUID?) {
        if let id, transformSettings.definition(id: id) == nil { return }
        transformSettings.autoApplyTransformID = id
        persistTransformSettings()
    }

    private func makeUpdatedBuiltInTransform(
        kind: TransformKind,
        prompt: String,
        hotkey: Hotkey?,
        writingSamples: [TransformWritingSample],
        editedAt: Date
    ) throws -> TransformDefinition {
        let builtInID = kind == .polish
            ? TransformDefinition.polishID
            : TransformDefinition.promptEngineerID
        guard let existing = transformSettings.definition(id: builtInID) else {
            throw TransformValidationError.emptyPrompt
        }
        let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPrompt.isEmpty else { throw TransformValidationError.emptyPrompt }
        guard normalizedPrompt.count <= TransformDefinition.promptCharacterLimit else {
            throw TransformValidationError.promptTooLong
        }
        guard let hotkey else { throw TransformValidationError.missingShortcut }
        guard TransformShortcutValidator.isAllowed(hotkey) else {
            throw TransformValidationError.invalidShortcut
        }
        try validateAgainstDictationHotkey(hotkey)
        guard !transformSettings.definitions.contains(where: {
            $0.id != builtInID && $0.hotkey == hotkey
        }) else {
            throw TransformValidationError.duplicateShortcut
        }
        guard writingSamples.count <= TransformDefinition.writingSampleLimit else {
            throw TransformValidationError.writingSampleLimitReached
        }
        try writingSamples.forEach(TransformDefinitionValidator.validateWritingSample)
        return TransformDefinition(
            id: builtInID,
            kind: kind,
            name: existing.name,
            prompt: normalizedPrompt,
            hotkey: hotkey,
            writingSamples: writingSamples,
            createdAt: existing.createdAt,
            editedAt: editedAt
        )
    }

    private func validateAgainstDictationHotkey(_ hotkey: Hotkey) throws {
        guard let data = defaults.data(forKey: DefaultsKeys.hotkey),
              let dictationHotkey = try? JSONDecoder().decode(Hotkey.self, from: data),
              dictationHotkey.kind == .carbon else {
            return
        }
        guard dictationHotkey != hotkey else {
            throw TransformValidationError.duplicateShortcut
        }
    }

    private func persistHistory() throws {
        try historyPersistence.saveSynchronously(history)
    }

    private func persistHistoryBestEffort(deletingAudioFilename: String? = nil) {
        historyPersistence.save(
            history,
            deletingAudioFilename: deletingAudioFilename
        ) { [weak self] error in
            guard error != nil else { return }
            self?.historyFeedbackMessage = deletingAudioFilename == nil
                ? "History couldn’t be saved to disk. Recent changes may not survive a restart."
                : "The transcript was saved, but its recording couldn’t be removed from disk."
        }
    }

    private func persistSnippets() {
        if let data = try? SnippetStore.encode(snippets) {
            defaults.set(data, forKey: DefaultsKeys.snippets)
        }
    }

    private func persistDictionary() {
        if let data = try? DictionaryStore.encode(dictionaryEntries) {
            defaults.set(data, forKey: DefaultsKeys.dictionaryEntries)
        }
    }

    private func persistStylePreferences() {
        if let data = try? StyleStore.encode(stylePreferences) {
            defaults.set(data, forKey: DefaultsKeys.stylePreferences)
        }
    }

    private func persistTransformSettings() {
        if let data = try? TransformStore.encode(transformSettings) {
            defaults.set(data, forKey: DefaultsKeys.transformSettings)
        }
    }

    private func sortTransforms() {
        transformSettings.definitions.sort { first, second in
            let firstRank = Self.transformRank(first.kind)
            let secondRank = Self.transformRank(second.kind)
            if firstRank != secondRank { return firstRank < secondRank }
            return first.editedAt > second.editedAt
        }
    }

    private static func transformRank(_ kind: TransformKind) -> Int {
        switch kind {
        case .polish: return 0
        case .promptEngineer: return 1
        case .custom: return 2
        }
    }

    private static func loadSnippets(defaults: UserDefaults) -> (snippets: [Snippet], recoveryMessage: String?) {
        guard let data = defaults.data(forKey: DefaultsKeys.snippets) else { return ([], nil) }

        let result = SnippetStore.decode(data)
        if result.shouldBackUpOriginal {
            defaults.set(data, forKey: DefaultsKeys.snippetsRecovery)
        }
        if result.needsMigration, result.rejectedRecordCount == 0,
           let migratedData = try? SnippetStore.encode(result.snippets) {
            defaults.set(migratedData, forKey: DefaultsKeys.snippets)
        }

        let recoveryMessage: String?
        if result.rejectedRecordCount > 0 {
            let noun = result.rejectedRecordCount == 1 ? "snippet" : "snippets"
            recoveryMessage = "Couldn’t read \(result.rejectedRecordCount) saved \(noun). The original data was kept as a recovery backup."
        } else {
            recoveryMessage = nil
        }
        return (result.snippets, recoveryMessage)
    }

    private static func loadDictionary(
        defaults: UserDefaults
    ) -> (entries: [DictionaryEntry], recoveryMessage: String?) {
        guard let data = defaults.data(forKey: DefaultsKeys.dictionaryEntries) else {
            return ([], nil)
        }

        let result = DictionaryStore.decode(data)
        if result.shouldBackUpOriginal {
            defaults.set(data, forKey: DefaultsKeys.dictionaryRecovery)
        }
        if result.needsMigration, result.rejectedRecordCount == 0,
           let migratedData = try? DictionaryStore.encode(result.entries) {
            defaults.set(migratedData, forKey: DefaultsKeys.dictionaryEntries)
        }

        let recoveryMessage: String?
        if result.rejectedRecordCount > 0 {
            let noun = result.rejectedRecordCount == 1 ? "entry" : "entries"
            recoveryMessage = "Couldn’t read \(result.rejectedRecordCount) saved dictionary \(noun). The original data was kept as a recovery backup."
        } else {
            recoveryMessage = nil
        }
        return (result.entries, recoveryMessage)
    }

    private static func loadStyles(
        defaults: UserDefaults
    ) -> (preferences: StylePreferences, recoveryMessage: String?) {
        guard let data = defaults.data(forKey: DefaultsKeys.stylePreferences) else {
            return (.default, nil)
        }

        let result = StyleStore.decode(data)
        if result.shouldBackUpOriginal {
            defaults.set(data, forKey: DefaultsKeys.styleRecovery)
            if let recoveredData = try? StyleStore.encode(result.preferences) {
                defaults.set(recoveredData, forKey: DefaultsKeys.stylePreferences)
            }
        } else if result.needsMigration,
                  let migratedData = try? StyleStore.encode(result.preferences) {
            defaults.set(migratedData, forKey: DefaultsKeys.stylePreferences)
        }
        let recoveryMessage = result.rejectedRecordCount > 0
            ? "Recovered writing styles after ignoring invalid saved settings. The original data was backed up locally."
            : nil
        return (result.preferences, recoveryMessage)
    }

    private static func loadTransforms(
        defaults: UserDefaults
    ) -> (settings: TransformSettings, recoveryMessage: String?) {
        guard let data = defaults.data(forKey: DefaultsKeys.transformSettings) else {
            return (.default, nil)
        }

        let result = TransformStore.decode(data)
        if result.shouldBackUpOriginal {
            defaults.set(data, forKey: DefaultsKeys.transformRecovery)
            if let recoveredData = try? TransformStore.encode(result.settings) {
                defaults.set(recoveredData, forKey: DefaultsKeys.transformSettings)
            }
        }
        let recoveryMessage: String?
        if result.rejectedRecordCount > 0 {
            let noun = result.rejectedRecordCount == 1 ? "record" : "records"
            recoveryMessage = "Recovered transforms after ignoring \(result.rejectedRecordCount) invalid \(noun). The original data was backed up locally."
        } else {
            recoveryMessage = nil
        }
        return (result.settings, recoveryMessage)
    }
}
