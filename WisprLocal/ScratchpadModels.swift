import AppKit
import Combine
import Foundation

enum ScratchpadVersionSource: String, Codable, CaseIterable, Equatable {
    case created
    case typed
    case dictated
    case transform
    case customTransform
    case restored

    var title: String {
        switch self {
        case .created: return "Created"
        case .typed: return "Typed edits"
        case .dictated: return "Dictated"
        case .transform: return "Transform"
        case .customTransform: return "Custom transform"
        case .restored: return "Restored"
        }
    }
}

enum ScratchpadOpenBehavior: String, Codable, CaseIterable, Identifiable {
    case resumeLastNote
    case openNewTab
    case openLastPinnedNote

    var id: Self { self }

    var title: String {
        switch self {
        case .resumeLastNote: return "Resume last note"
        case .openNewTab: return "Open in new tab"
        case .openLastPinnedNote: return "Open last active pinned note"
        }
    }
}

struct ScratchpadNote: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var preview: String
    let createdAt: Date
    var modifiedAt: Date
    var isPinned: Bool
    var imageCount: Int
}

struct ScratchpadVersion: Identifiable, Codable, Equatable {
    let id: UUID
    let noteID: UUID
    var createdAt: Date
    var source: ScratchpadVersionSource
}

struct ScratchpadWorkspace: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    var notes: [ScratchpadNote]
    var versions: [ScratchpadVersion]
    var openTabs: [UUID]
    var selectedNoteID: UUID?
    var lastActivePinnedNoteID: UUID?
    var openBehavior: ScratchpadOpenBehavior

    static let empty = ScratchpadWorkspace(
        version: currentVersion,
        notes: [],
        versions: [],
        openTabs: [],
        selectedNoteID: nil,
        lastActivePinnedNoteID: nil,
        openBehavior: .resumeLastNote
    )
}

enum ScratchpadError: LocalizedError, Equatable {
    case tabLimitReached
    case noteNotFound
    case versionNotFound
    case corruptWorkspace
    case corruptContent
    case imageLimitReached
    case imageTooLarge
    case noActiveNote
    case actionInProgress
    case emptyTransformPrompt
    case dictationTargetChanged

    var errorDescription: String? {
        switch self {
        case .tabLimitReached:
            return "Scratchpad supports up to five open tabs. Close a tab before opening another note."
        case .noteNotFound:
            return "That Scratchpad note is no longer available."
        case .versionNotFound:
            return "That Scratchpad version is no longer available."
        case .corruptWorkspace:
            return "Scratchpad metadata couldn’t be read. The original file was saved to Recovery."
        case .corruptContent:
            return "This note couldn’t be read. Its original content was saved to Recovery."
        case .imageLimitReached:
            return "A Scratchpad note can contain up to 10 images."
        case .imageTooLarge:
            return "Each Scratchpad image must be 5 MB or smaller."
        case .noActiveNote:
            return "Open a Scratchpad note first."
        case .actionInProgress:
            return "Another Scratchpad action is already running."
        case .emptyTransformPrompt:
            return "Enter a transform instruction first."
        case .dictationTargetChanged:
            return "The active Scratchpad note changed before dictation finished. No text was inserted."
        }
    }
}

enum ScratchpadDocumentCodec {
    static let imageLimit = 10
    static let imageByteLimit = 5 * 1_024 * 1_024

    static func encode(_ content: NSAttributedString) throws -> Data {
        try validateAttachments(in: content)
        return try content.data(
            from: NSRange(location: 0, length: content.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        )
    }

    static func decode(_ data: Data) throws -> NSAttributedString {
        guard let value = NSAttributedString(
            rtfd: data,
            documentAttributes: nil
        ) else {
            throw ScratchpadError.corruptContent
        }
        return value
    }

    static func noteSummary(
        id: UUID,
        content: NSAttributedString,
        createdAt: Date,
        modifiedAt: Date,
        isPinned: Bool
    ) throws -> ScratchpadNote {
        try validateAttachments(in: content)
        let normalizedLines = content.string
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let title = normalizedLines.first.map { String($0.prefix(80)) } ?? "Untitled note"
        let preview = content.string
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ScratchpadNote(
            id: id,
            title: title,
            preview: String(preview.prefix(180)),
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            isPinned: isPinned,
            imageCount: attachmentSizes(in: content).count
        )
    }

    static func validateAttachments(in content: NSAttributedString) throws {
        let sizes = attachmentSizes(in: content)
        guard sizes.count <= imageLimit else {
            throw ScratchpadError.imageLimitReached
        }
        guard sizes.allSatisfy({ $0 <= imageByteLimit }) else {
            throw ScratchpadError.imageTooLarge
        }
    }

    private static func attachmentSizes(in content: NSAttributedString) -> [Int] {
        var sizes: [Int] = []
        content.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: content.length)
        ) { value, _, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            if let size = attachment.fileWrapper?.regularFileContents?.count {
                sizes.append(size)
            } else if let image = attachment.image,
                      let data = image.tiffRepresentation {
                sizes.append(data.count)
            } else {
                sizes.append(0)
            }
        }
        return sizes
    }
}

struct ScratchpadWorkspaceLoadResult {
    let workspace: ScratchpadWorkspace
    let recoveryMessage: String?
}

@MainActor
protocol ScratchpadPersisting: AnyObject {
    func loadWorkspace() -> ScratchpadWorkspaceLoadResult
    func saveWorkspace(_ workspace: ScratchpadWorkspace) throws
    func loadNoteContent(id: UUID) throws -> NSAttributedString
    func saveNoteContent(_ content: NSAttributedString, id: UUID) throws
    func loadVersionContent(id: UUID) throws -> NSAttributedString
    func saveVersionContent(_ content: NSAttributedString, id: UUID) throws
    func deleteNoteContent(id: UUID, versionIDs: [UUID]) throws
    func deleteVersionContent(id: UUID) throws
}

@MainActor
final class FileScratchpadRepository: ScratchpadPersisting {
    private let rootURL: URL
    private let fileManager: FileManager

    private var metadataURL: URL { rootURL.appendingPathComponent("workspace.json") }
    private var documentsURL: URL { rootURL.appendingPathComponent("Documents", isDirectory: true) }
    private var versionsURL: URL { rootURL.appendingPathComponent("Versions", isDirectory: true) }
    private var recoveryURL: URL { rootURL.appendingPathComponent("Recovery", isDirectory: true) }

    convenience init(fileManager: FileManager = .default) {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        self.init(
            rootURL: applicationSupport
                .appendingPathComponent("WisprLocal", isDirectory: true)
                .appendingPathComponent("Scratchpad", isDirectory: true),
            fileManager: fileManager
        )
    }

    init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    func loadWorkspace() -> ScratchpadWorkspaceLoadResult {
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            return ScratchpadWorkspaceLoadResult(workspace: .empty, recoveryMessage: nil)
        }
        do {
            let data = try Data(contentsOf: metadataURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let workspace = try decoder.decode(ScratchpadWorkspace.self, from: data)
            guard workspace.version == ScratchpadWorkspace.currentVersion else {
                throw ScratchpadError.corruptWorkspace
            }
            return ScratchpadWorkspaceLoadResult(workspace: workspace, recoveryMessage: nil)
        } catch {
            try? backUp(metadataURL, prefix: "workspace")
            return ScratchpadWorkspaceLoadResult(
                workspace: .empty,
                recoveryMessage: ScratchpadError.corruptWorkspace.localizedDescription
            )
        }
    }

    func saveWorkspace(_ workspace: ScratchpadWorkspace) throws {
        try ensureDirectories()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(workspace).write(to: metadataURL, options: .atomic)
    }

    func loadNoteContent(id: UUID) throws -> NSAttributedString {
        try loadContent(at: noteURL(id))
    }

    func saveNoteContent(_ content: NSAttributedString, id: UUID) throws {
        try saveContent(content, at: noteURL(id))
    }

    func loadVersionContent(id: UUID) throws -> NSAttributedString {
        try loadContent(at: versionURL(id))
    }

    func saveVersionContent(_ content: NSAttributedString, id: UUID) throws {
        try saveContent(content, at: versionURL(id))
    }

    func deleteNoteContent(id: UUID, versionIDs: [UUID]) throws {
        if fileManager.fileExists(atPath: noteURL(id).path) {
            try fileManager.removeItem(at: noteURL(id))
        }
        for versionID in versionIDs where fileManager.fileExists(atPath: versionURL(versionID).path) {
            try fileManager.removeItem(at: versionURL(versionID))
        }
    }

    func deleteVersionContent(id: UUID) throws {
        let url = versionURL(id)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func saveContent(_ content: NSAttributedString, at url: URL) throws {
        try ensureDirectories()
        try ScratchpadDocumentCodec.encode(content).write(to: url, options: .atomic)
    }

    private func loadContent(at url: URL) throws -> NSAttributedString {
        do {
            return try ScratchpadDocumentCodec.decode(Data(contentsOf: url))
        } catch {
            try? backUp(url, prefix: url.deletingPathExtension().lastPathComponent)
            throw ScratchpadError.corruptContent
        }
    }

    private func ensureDirectories() throws {
        for url in [rootURL, documentsURL, versionsURL, recoveryURL] {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        }
    }

    private func backUp(_ url: URL, prefix: String) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try ensureDirectories()
        let timestamp = Int(Date().timeIntervalSince1970)
        let destination = recoveryURL.appendingPathComponent("\(prefix)-\(timestamp).backup")
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: url, to: destination)
    }

    private func noteURL(_ id: UUID) -> URL {
        documentsURL.appendingPathComponent(id.uuidString).appendingPathExtension("rtfd")
    }

    private func versionURL(_ id: UUID) -> URL {
        versionsURL.appendingPathComponent(id.uuidString).appendingPathExtension("rtfd")
    }
}

@MainActor
final class ScratchpadStore: ObservableObject {
    static let maximumOpenTabs = 5
    static let maximumVersionsPerNote = 50
    static let typedVersionCoalescingInterval: TimeInterval = 60

    @Published private(set) var notes: [ScratchpadNote] = []
    @Published private(set) var versions: [ScratchpadVersion] = []
    @Published private(set) var openTabs: [UUID] = []
    @Published private(set) var selectedNoteID: UUID?
    @Published private(set) var activeContent = NSAttributedString(string: "")
    @Published var isSidebarVisible = true
    @Published var message: String?
    @Published private(set) var recoveryMessage: String?
    @Published var openBehavior: ScratchpadOpenBehavior {
        didSet { persistWorkspace() }
    }

    private let repository: ScratchpadPersisting
    private var lastActivePinnedNoteID: UUID?
    private var autosaveTask: Task<Void, Never>?
    private var isHydrating = false

    convenience init() {
        self.init(repository: FileScratchpadRepository())
    }

    init(repository: ScratchpadPersisting) {
        self.repository = repository
        let loaded = repository.loadWorkspace()
        let workspace = loaded.workspace
        openBehavior = workspace.openBehavior
        recoveryMessage = loaded.recoveryMessage
        notes = Self.sorted(workspace.notes)
        versions = workspace.versions
        let noteIDs = Set(notes.map(\.id))
        openTabs = Array(workspace.openTabs.filter(noteIDs.contains).prefix(Self.maximumOpenTabs))
        selectedNoteID = workspace.selectedNoteID.map(noteIDs.contains) == true
            ? workspace.selectedNoteID
            : openTabs.first
        lastActivePinnedNoteID = workspace.lastActivePinnedNoteID.map(noteIDs.contains) == true
            ? workspace.lastActivePinnedNoteID
            : nil
        if let selectedNoteID {
            loadContent(for: selectedNoteID)
        }
    }

    var selectedNote: ScratchpadNote? {
        guard let selectedNoteID else { return nil }
        return notes.first { $0.id == selectedNoteID }
    }

    var selectedVersions: [ScratchpadVersion] {
        guard let selectedNoteID else { return [] }
        return versions
            .filter { $0.noteID == selectedNoteID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var selectedNoteIndex: Int? {
        selectedNoteID.flatMap { id in notes.firstIndex { $0.id == id } }
    }

    func filteredNotes(query: String) -> [ScratchpadNote] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return notes }
        return notes.filter {
            $0.title.localizedCaseInsensitiveContains(normalized)
                || $0.preview.localizedCaseInsensitiveContains(normalized)
        }
    }

    @discardableResult
    func createNote(initialText: String = "") throws -> UUID {
        guard openTabs.count < Self.maximumOpenTabs else {
            throw ScratchpadError.tabLimitReached
        }
        flushAutosave()
        let now = Date()
        let id = UUID()
        let content = NSAttributedString(
            string: initialText,
            attributes: [.font: NSFont.systemFont(ofSize: 16)]
        )
        let note = try ScratchpadDocumentCodec.noteSummary(
            id: id,
            content: content,
            createdAt: now,
            modifiedAt: now,
            isPinned: false
        )
        let version = ScratchpadVersion(
            id: UUID(),
            noteID: id,
            createdAt: now,
            source: .created
        )
        try repository.saveNoteContent(content, id: id)
        try repository.saveVersionContent(content, id: version.id)
        notes.append(note)
        notes = Self.sorted(notes)
        versions.append(version)
        openTabs.append(id)
        selectedNoteID = id
        activeContent = content
        persistWorkspace()
        return id
    }

    func prepareForShortcutOpen() throws {
        switch openBehavior {
        case .resumeLastNote:
            try ensureSelection()
        case .openNewTab:
            _ = try createNote()
        case .openLastPinnedNote:
            if let lastActivePinnedNoteID,
               notes.contains(where: { $0.id == lastActivePinnedNoteID && $0.isPinned }) {
                try openNote(id: lastActivePinnedNoteID)
            } else if let pinned = notes.first(where: \.isPinned) {
                try openNote(id: pinned.id)
            } else {
                try ensureSelection()
            }
        }
    }

    func prepareForShortcutDictation() throws {
        try prepareForShortcutOpen()
        if activeContent.length > 0 {
            _ = try createNote()
        }
    }

    func openNote(id: UUID) throws {
        guard notes.contains(where: { $0.id == id }) else {
            throw ScratchpadError.noteNotFound
        }
        flushAutosave()
        if !openTabs.contains(id) {
            guard openTabs.count < Self.maximumOpenTabs else {
                throw ScratchpadError.tabLimitReached
            }
            openTabs.append(id)
        }
        selectedNoteID = id
        loadContent(for: id)
        rememberPinnedSelection(id)
        persistWorkspace()
    }

    func selectTab(id: UUID) {
        guard openTabs.contains(id), selectedNoteID != id else { return }
        flushAutosave()
        selectedNoteID = id
        loadContent(for: id)
        rememberPinnedSelection(id)
        persistWorkspace()
    }

    func closeTab(id: UUID) {
        guard let index = openTabs.firstIndex(of: id) else { return }
        if selectedNoteID == id { flushAutosave() }
        openTabs.remove(at: index)
        if selectedNoteID == id {
            selectedNoteID = openTabs.indices.contains(index)
                ? openTabs[index]
                : openTabs.last
            if let selectedNoteID {
                loadContent(for: selectedNoteID)
            } else {
                activeContent = NSAttributedString(string: "")
            }
        }
        persistWorkspace()
    }

    func updateActiveContent(_ content: NSAttributedString) {
        guard selectedNoteID != nil, !isHydrating else { return }
        activeContent = NSAttributedString(attributedString: content)
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled else { return }
            do {
                try self?.saveActiveContent(source: .typed, coalesceTyped: true)
            } catch {
                // saveActiveContent publishes the actionable persistence error.
            }
        }
    }

    func saveActiveContent(
        source: ScratchpadVersionSource,
        coalesceTyped: Bool = false
    ) throws {
        autosaveTask?.cancel()
        autosaveTask = nil
        guard let selectedNoteID,
              let noteIndex = notes.firstIndex(where: { $0.id == selectedNoteID }) else {
            throw ScratchpadError.noActiveNote
        }
        do {
            let now = Date()
            try repository.saveNoteContent(activeContent, id: selectedNoteID)
            notes[noteIndex] = try ScratchpadDocumentCodec.noteSummary(
                id: selectedNoteID,
                content: activeContent,
                createdAt: notes[noteIndex].createdAt,
                modifiedAt: now,
                isPinned: notes[noteIndex].isPinned
            )
            try saveVersion(
                noteID: selectedNoteID,
                content: activeContent,
                source: source,
                at: now,
                coalesceTyped: coalesceTyped
            )
            notes = Self.sorted(notes)
            try saveWorkspace()
            message = source == .typed ? nil : "Saved \(source.title.lowercased())."
        } catch {
            message = error.localizedDescription
            throw error
        }
    }

    func restore(versionID: UUID) throws {
        guard let version = versions.first(where: { $0.id == versionID }),
              version.noteID == selectedNoteID else {
            throw ScratchpadError.versionNotFound
        }
        let content = try repository.loadVersionContent(id: versionID)
        activeContent = content
        try saveActiveContent(source: .restored)
    }

    func togglePin(id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].isPinned.toggle()
        notes[index].modifiedAt = Date()
        if notes[index].isPinned {
            lastActivePinnedNoteID = id
        } else if lastActivePinnedNoteID == id {
            lastActivePinnedNoteID = notes.first(where: { $0.isPinned && $0.id != id })?.id
        }
        notes = Self.sorted(notes)
        persistWorkspace()
    }

    func deleteNote(id: UUID) throws {
        guard notes.contains(where: { $0.id == id }) else {
            throw ScratchpadError.noteNotFound
        }
        if selectedNoteID == id { autosaveTask?.cancel() }
        let versionIDs = versions.filter { $0.noteID == id }.map(\.id)
        try repository.deleteNoteContent(id: id, versionIDs: versionIDs)
        notes.removeAll { $0.id == id }
        versions.removeAll { $0.noteID == id }
        openTabs.removeAll { $0 == id }
        if lastActivePinnedNoteID == id {
            lastActivePinnedNoteID = notes.first(where: \.isPinned)?.id
        }
        if selectedNoteID == id {
            selectedNoteID = openTabs.last
            if let selectedNoteID {
                loadContent(for: selectedNoteID)
            } else {
                activeContent = NSAttributedString(string: "")
            }
        }
        persistWorkspace()
    }

    func refresh() {
        flushAutosave()
        let loaded = repository.loadWorkspace()
        recoveryMessage = loaded.recoveryMessage
        let workspace = loaded.workspace
        notes = Self.sorted(workspace.notes)
        versions = workspace.versions
        let noteIDs = Set(notes.map(\.id))
        openTabs = Array(workspace.openTabs.filter(noteIDs.contains).prefix(Self.maximumOpenTabs))
        selectedNoteID = workspace.selectedNoteID.map(noteIDs.contains) == true
            ? workspace.selectedNoteID
            : openTabs.first
        lastActivePinnedNoteID = workspace.lastActivePinnedNoteID.map(noteIDs.contains) == true
            ? workspace.lastActivePinnedNoteID
            : nil
        openBehavior = workspace.openBehavior
        if let selectedNoteID {
            loadContent(for: selectedNoteID)
        } else {
            activeContent = NSAttributedString(string: "")
        }
    }

    func flushAutosave() {
        guard autosaveTask != nil else { return }
        do {
            try saveActiveContent(source: .typed, coalesceTyped: true)
        } catch {
            // saveActiveContent publishes the actionable persistence error.
        }
    }

    private func ensureSelection() throws {
        if let selectedNoteID, notes.contains(where: { $0.id == selectedNoteID }) {
            try openNote(id: selectedNoteID)
        } else if let first = notes.first {
            try openNote(id: first.id)
        } else {
            _ = try createNote()
        }
    }

    private func loadContent(for noteID: UUID) {
        isHydrating = true
        defer { isHydrating = false }
        do {
            activeContent = try repository.loadNoteContent(id: noteID)
            message = nil
        } catch {
            activeContent = NSAttributedString(string: "")
            message = error.localizedDescription
            recoveryMessage = error.localizedDescription
        }
    }

    private func saveVersion(
        noteID: UUID,
        content: NSAttributedString,
        source: ScratchpadVersionSource,
        at date: Date,
        coalesceTyped: Bool
    ) throws {
        let latestVersionIndex = versions.indices
            .filter { versions[$0].noteID == noteID }
            .max { versions[$0].createdAt < versions[$1].createdAt }
        if coalesceTyped,
           source == .typed,
           let index = latestVersionIndex,
           versions[index].source == .typed,
           date.timeIntervalSince(versions[index].createdAt) <= Self.typedVersionCoalescingInterval {
            versions[index].createdAt = date
            try repository.saveVersionContent(content, id: versions[index].id)
        } else {
            let version = ScratchpadVersion(
                id: UUID(),
                noteID: noteID,
                createdAt: date,
                source: source
            )
            try repository.saveVersionContent(content, id: version.id)
            versions.append(version)
        }

        let ordered = versions
            .filter { $0.noteID == noteID }
            .sorted { $0.createdAt > $1.createdAt }
        for obsolete in ordered.dropFirst(Self.maximumVersionsPerNote) {
            try repository.deleteVersionContent(id: obsolete.id)
            versions.removeAll { $0.id == obsolete.id }
        }
    }

    private func rememberPinnedSelection(_ id: UUID) {
        guard notes.first(where: { $0.id == id })?.isPinned == true else { return }
        lastActivePinnedNoteID = id
    }

    private func persistWorkspace() {
        guard !isHydrating else { return }
        do {
            try saveWorkspace()
        } catch {
            message = error.localizedDescription
        }
    }

    private func saveWorkspace() throws {
        guard !isHydrating else { return }
        try repository.saveWorkspace(
            ScratchpadWorkspace(
                version: ScratchpadWorkspace.currentVersion,
                notes: notes,
                versions: versions,
                openTabs: openTabs,
                selectedNoteID: selectedNoteID,
                lastActivePinnedNoteID: lastActivePinnedNoteID,
                openBehavior: openBehavior
            )
        )
    }

    private static func sorted(_ notes: [ScratchpadNote]) -> [ScratchpadNote] {
        notes.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.modifiedAt > $1.modifiedAt
        }
    }
}
