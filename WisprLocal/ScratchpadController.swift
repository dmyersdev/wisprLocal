import Foundation

enum ScratchpadShortcutPolicy {
    static let holdDelayNanoseconds: UInt64 = 280_000_000
    static let doubleTapDelayNanoseconds: UInt64 = 260_000_000

    static func isDoubleTap(
        previousRelease: Date?,
        currentRelease: Date,
        isWindowVisible: Bool
    ) -> Bool {
        guard isWindowVisible, let previousRelease else { return false }
        return currentRelease.timeIntervalSince(previousRelease) <= 0.26
    }
}

@MainActor
final class ScratchpadController: ObservableObject {
    enum RecordingMode: Equatable {
        case hold
        case handsFree
    }

    enum State: Equatable {
        case idle
        case starting(RecordingMode)
        case listening(RecordingMode)
        case processing
        case transforming(String)
        case success(String)
        case error(String)
    }

    @Published private(set) var state: State = .idle

    let store: ScratchpadStore
    let editorBridge: ScratchpadEditorBridge

    var onShowWindow: (() -> Void)?
    var onHideWindow: (() -> Void)?
    var isWindowVisible: (() -> Bool) = { false }

    private let appState: AppState
    private let recorder: AudioRecording
    private let transcriptionClient: TranscriptionServing
    private let transformClient: TransformServing
    private let isSetupComplete: () -> Bool
    private let onSetupRequired: () -> Void

    private var operationID: UUID?
    private var recordingTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var holdStartTask: Task<Void, Never>?
    private var singleTapTask: Task<Void, Never>?
    private var pressStartedAt: Date?
    private var lastTapReleaseAt: Date?
    private var pendingRecordingURL: URL?
    private var recordingNoteID: UUID?

    var canCancel: Bool {
        operationID != nil
    }

    var isActive: Bool {
        operationID != nil
    }

    var availableTransforms: [TransformDefinition] {
        appState.transformSettings.definitions
    }

    init(
        appState: AppState,
        store: ScratchpadStore,
        editorBridge: ScratchpadEditorBridge,
        recorder: AudioRecording,
        transcriptionClient: TranscriptionServing,
        transformClient: TransformServing,
        isSetupComplete: @escaping () -> Bool = { true },
        onSetupRequired: @escaping () -> Void = {}
    ) {
        self.appState = appState
        self.store = store
        self.editorBridge = editorBridge
        self.recorder = recorder
        self.transcriptionClient = transcriptionClient
        self.transformClient = transformClient
        self.isSetupComplete = isSetupComplete
        self.onSetupRequired = onSetupRequired
    }

    func shortcutPressed() {
        guard requireSetup() else { return }
        if case .listening(.handsFree) = state {
            stopAndTranscribe()
            return
        }
        guard pressStartedAt == nil, operationID == nil else { return }
        singleTapTask?.cancel()
        singleTapTask = nil
        pressStartedAt = Date()
        holdStartTask?.cancel()
        holdStartTask = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: ScratchpadShortcutPolicy.holdDelayNanoseconds
            )
            guard let self, !Task.isCancelled, self.pressStartedAt != nil else { return }
            self.singleTapTask?.cancel()
            self.lastTapReleaseAt = nil
            self.startShortcutRecording(mode: .hold)
        }
    }

    func shortcutReleased(at date: Date = Date()) {
        guard pressStartedAt != nil else { return }
        pressStartedAt = nil
        holdStartTask?.cancel()
        holdStartTask = nil

        if case .starting(.hold) = state {
            stopAndTranscribe()
            return
        }
        if case .listening(.hold) = state {
            stopAndTranscribe()
            return
        }

        if ScratchpadShortcutPolicy.isDoubleTap(
            previousRelease: lastTapReleaseAt,
            currentRelease: date,
            isWindowVisible: isWindowVisible()
        ) {
            singleTapTask?.cancel()
            singleTapTask = nil
            lastTapReleaseAt = nil
            startShortcutRecording(mode: .handsFree)
            return
        }

        lastTapReleaseAt = date
        singleTapTask?.cancel()
        singleTapTask = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: ScratchpadShortcutPolicy.doubleTapDelayNanoseconds
            )
            guard let self, !Task.isCancelled else { return }
            self.lastTapReleaseAt = nil
            self.toggleWindow()
        }
    }

    func toggleWindow() {
        guard requireSetup() else { return }
        if isWindowVisible() {
            store.flushAutosave()
            onHideWindow?()
        } else {
            openForEditing()
        }
    }

    func openNote(id: UUID) {
        guard requireSetup() else { return }
        do {
            try store.openNote(id: id)
            onShowWindow?()
            Task { [weak self] in
                await Task.yield()
                self?.editorBridge.focus()
            }
        } catch {
            publish(error)
        }
    }

    func createAndOpenNote() {
        guard requireSetup() else { return }
        do {
            _ = try store.createNote()
            onShowWindow?()
            Task { [weak self] in
                await Task.yield()
                self?.editorBridge.focus()
            }
        } catch {
            publish(error)
        }
    }

    func startRecording(mode: RecordingMode) {
        guard requireSetup() else { return }
        guard operationID == nil else {
            publish(ScratchpadError.actionInProgress)
            return
        }
        guard isGloballyAvailable else {
            publish(ScratchpadError.actionInProgress)
            return
        }
        if store.selectedNoteID == nil {
            do {
                try store.prepareForShortcutOpen()
            } catch {
                publish(error)
                return
            }
        }

        guard let selectedNoteID = store.selectedNoteID else {
            publish(ScratchpadError.noActiveNote)
            return
        }

        onShowWindow?()
        let currentID = UUID()
        operationID = currentID
        recordingNoteID = selectedNoteID
        state = .starting(mode)
        appState.setState(.scratchpadListening)
        recordingTask?.cancel()
        recordingTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await recorder.startRecording()
                guard isCurrent(currentID), !Task.isCancelled else {
                    recorder.cancelRecording()
                    return
                }
                state = .listening(mode)
            } catch {
                guard isCurrent(currentID), !Task.isCancelled else { return }
                finishWithError(error, operationID: currentID)
            }
        }
    }

    func stopAndTranscribe() {
        guard let currentID = operationID else { return }
        if case .starting = state {
            processingTask = Task { [weak self] in
                guard let self else { return }
                for _ in 0..<200 {
                    if !self.isCurrent(currentID) { return }
                    if case .listening = self.state {
                        self.stopAndTranscribe()
                        return
                    }
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                self.finishWithError(
                    AppError.recordingFailed("Scratchpad recording did not start."),
                    operationID: currentID
                )
            }
            return
        }
        guard case .listening = state else { return }
        recordingTask = nil
        state = .processing
        appState.setState(.scratchpadProcessing)

        let recordingURL: URL
        do {
            recordingURL = try recorder.stopRecording()
            pendingRecordingURL = recordingURL
        } catch {
            finishWithError(error, operationID: currentID)
            return
        }

        processingTask?.cancel()
        processingTask = Task { [weak self] in
            guard let self else { return }
            defer {
                try? FileManager.default.removeItem(at: recordingURL)
                if pendingRecordingURL == recordingURL {
                    pendingRecordingURL = nil
                }
            }
            do {
                let rawText = try await transcriptionClient.transcribe(
                    fileURL: recordingURL,
                    language: appState.language.trimmedOrNil,
                    vocabularyPrompt: DictionaryPromptBuilder.prompt(
                        for: appState.dictionaryEntries
                    )
                )
                try Task.checkCancellation()
                guard isCurrent(currentID) else { return }

                let finalText: String
                if appState.polishEnabled {
                    let polished = try await transcriptionClient.polishTranscript(text: rawText)
                    appState.addTokenUsage(
                        prompt: polished.promptTokens,
                        completion: polished.completionTokens
                    )
                    finalText = polished.text
                } else {
                    finalText = rawText
                }
                try Task.checkCancellation()
                guard isCurrent(currentID) else { return }

                let personalized = TranscriptPersonalizer.personalize(
                    finalText,
                    dictionaryEntries: appState.dictionaryEntries,
                    snippets: appState.snippets
                )
                guard store.selectedNoteID == recordingNoteID else {
                    throw ScratchpadError.dictationTargetChanged
                }
                try editorBridge.insertPlainText(personalized)
                try store.saveActiveContent(source: .dictated)
                finish(
                    currentID,
                    state: .success("Dictated"),
                    message: "Dictation added to Scratchpad."
                )
            } catch is CancellationError {
                guard isCurrent(currentID) else { return }
                finish(currentID, state: .idle, message: "Scratchpad dictation cancelled.")
            } catch {
                guard isCurrent(currentID) else { return }
                finishWithError(error, operationID: currentID)
            }
        }
    }

    func applyTransform(definition: TransformDefinition) {
        guard requireSetup() else { return }
        runTransform(
            invocation: appState.transformSettings.invocation(for: definition),
            versionSource: .transform
        )
    }

    func applyCustomTransform(prompt: String) {
        guard requireSetup() else { return }
        let normalized = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            publish(ScratchpadError.emptyTransformPrompt)
            return
        }
        runTransform(
            invocation: TransformInvocation(
                transformID: UUID(),
                name: "Custom transform",
                instruction: normalized,
                writingSamples: []
            ),
            versionSource: .customTransform
        )
    }

    func cancelCurrentAction() {
        let hadOperation = operationID != nil
        resetShortcutGestureState()
        guard hadOperation else { return }
        operationID = nil
        recordingTask?.cancel()
        processingTask?.cancel()
        recordingTask = nil
        processingTask = nil
        recorder.cancelRecording()
        recordingNoteID = nil
        if let pendingRecordingURL {
            try? FileManager.default.removeItem(at: pendingRecordingURL)
            self.pendingRecordingURL = nil
        }
        state = .idle
        appState.setState(.idle)
        store.message = "Scratchpad action cancelled."
    }

    private func runTransform(
        invocation: TransformInvocation,
        versionSource: ScratchpadVersionSource
    ) {
        guard operationID == nil else {
            publish(ScratchpadError.actionInProgress)
            return
        }
        guard appState.state == .idle || isErrorState(appState.state),
              let noteID = store.selectedNoteID else {
            publish(ScratchpadError.noActiveNote)
            return
        }
        let target: ScratchpadTransformTarget
        do {
            target = try editorBridge.captureTransformTarget(noteID: noteID)
        } catch {
            publish(error)
            return
        }
        guard target.promptText.trimmedOrNil != nil else {
            publish(AppError.transformReturnedNoText)
            return
        }

        let imageRule = target.attachments.isEmpty
            ? invocation.instruction
            : invocation.instruction
                + "\nPreserve every image marker exactly and in order: "
                + target.attachments.map(\.marker).joined(separator: ", ")
        let effectiveInvocation = TransformInvocation(
            transformID: invocation.transformID,
            name: invocation.name,
            instruction: imageRule,
            writingSamples: invocation.writingSamples
        )
        let currentID = UUID()
        operationID = currentID
        state = .transforming(invocation.name)
        appState.setState(.scratchpadProcessing)
        processingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let generated = try await transformClient.transform(
                    text: target.promptText,
                    invocation: effectiveInvocation
                )
                try Task.checkCancellation()
                guard isCurrent(currentID),
                      let currentNoteID = store.selectedNoteID else { return }
                appState.addTokenUsage(
                    prompt: generated.inputTokens,
                    completion: generated.outputTokens
                )
                try editorBridge.applyTransform(
                    generated.text,
                    target: target,
                    currentNoteID: currentNoteID
                )
                try store.saveActiveContent(source: versionSource)
                finish(
                    currentID,
                    state: .success(invocation.name),
                    message: "Applied \(invocation.name)."
                )
            } catch is CancellationError {
                guard isCurrent(currentID) else { return }
                finish(currentID, state: .idle, message: "Scratchpad transform cancelled.")
            } catch {
                guard isCurrent(currentID) else { return }
                finishWithError(error, operationID: currentID)
            }
        }
    }

    private func openForEditing() {
        guard requireSetup() else { return }
        do {
            try store.prepareForShortcutOpen()
            onShowWindow?()
            Task { [weak self] in
                await Task.yield()
                self?.editorBridge.focus()
            }
        } catch {
            publish(error)
        }
    }

    private func startShortcutRecording(mode: RecordingMode) {
        guard requireSetup() else {
            resetShortcutGestureState()
            return
        }
        guard operationID == nil, isGloballyAvailable else {
            resetShortcutGestureState()
            publish(ScratchpadError.actionInProgress)
            return
        }
        do {
            try store.prepareForShortcutDictation()
            startRecording(mode: mode)
        } catch {
            resetShortcutGestureState()
            publish(error)
        }
    }

    private func finish(
        _ id: UUID,
        state: State,
        message: String
    ) {
        guard isCurrent(id) else { return }
        operationID = nil
        recordingNoteID = nil
        recordingTask = nil
        processingTask = nil
        self.state = state
        appState.setState(.idle)
        store.message = message
    }

    private func finishWithError(_ error: Error, operationID: UUID) {
        guard isCurrent(operationID) else { return }
        self.operationID = nil
        recordingNoteID = nil
        recordingTask = nil
        processingTask = nil
        recorder.cancelRecording()
        let message = error.localizedDescription
        state = .error(message)
        store.message = message
        appState.setState(.error(message))
    }

    private func requireSetup() -> Bool {
        guard isSetupComplete() else {
            publish(AppError.setupIncomplete)
            onSetupRequired()
            return false
        }
        return true
    }

    private func publish(_ error: Error) {
        let message = error.localizedDescription
        state = .error(message)
        store.message = message
    }

    private func isCurrent(_ id: UUID) -> Bool {
        operationID == id
    }

    private func isErrorState(_ state: AppState.State) -> Bool {
        if case .error = state { return true }
        return false
    }

    private var isGloballyAvailable: Bool {
        appState.state == .idle || isErrorState(appState.state)
    }

    private func resetShortcutGestureState() {
        holdStartTask?.cancel()
        singleTapTask?.cancel()
        holdStartTask = nil
        singleTapTask = nil
        pressStartedAt = nil
        lastTapReleaseAt = nil
    }
}
