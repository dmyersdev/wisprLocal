import Foundation

struct DictationSessionLimits: Equatable {
    static let standard = DictationSessionLimits(
        warningAfter: 19 * 60,
        maximumDuration: 20 * 60
    )

    let warningAfter: TimeInterval
    let maximumDuration: TimeInterval

    init(warningAfter: TimeInterval, maximumDuration: TimeInterval) {
        precondition(warningAfter >= 0)
        precondition(maximumDuration >= warningAfter)
        self.warningAfter = warningAfter
        self.maximumDuration = maximumDuration
    }
}

@MainActor
final class DictationController: ObservableObject {
    private let appState: AppState
    private let recorder: AudioRecording
    private let client: TranscriptionServing
    private let transformClient: TransformServing?
    private let injector: TextInjecting
    private let appContextProvider: StyleAppContextProviding
    private let isSetupComplete: () -> Bool
    private let onSetupRequired: () -> Void
    private let sessionLimits: DictationSessionLimits

    private var recordingTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var sessionLimitTask: Task<Void, Never>?
    private var currentOperationID: UUID?
    private var requestedRecordingMode: DictationRecordingMode?
    private var pendingStopOperationID: UUID?
    private var pendingRecordingURL: URL?
    private var targetAppContextTask: Task<StyleAppContext, Never>?
    private var recordingStartedAt: Date?
    private var pendingHistoryItemID: UUID?

    var canCancel: Bool {
        currentOperationID != nil
    }

    var isHandsFreeOperation: Bool {
        currentOperationID != nil && requestedRecordingMode == .handsFree
    }

    init(appState: AppState,
         recorder: AudioRecording,
         client: TranscriptionServing,
         transformClient: TransformServing? = nil,
         injector: TextInjecting,
         appContextProvider: StyleAppContextProviding,
         isSetupComplete: @escaping () -> Bool = { true },
         onSetupRequired: @escaping () -> Void = {},
         sessionLimits: DictationSessionLimits = .standard) {
        self.appState = appState
        self.recorder = recorder
        self.client = client
        self.transformClient = transformClient
        self.injector = injector
        self.appContextProvider = appContextProvider
        self.isSetupComplete = isSetupComplete
        self.onSetupRequired = onSetupRequired
        self.sessionLimits = sessionLimits
    }

    func toggle() {
        toggleHandsFree()
    }

    func toggleHandsFree() {
        if appState.state != .listening,
           recordingTask != nil,
           currentOperationID != nil {
            if isHandsFreeOperation {
                stopAndTranscribe()
            } else {
                lockHandsFree()
            }
            return
        }

        switch appState.state {
        case .idle, .error:
            startRecording(mode: .handsFree)
        case .listening:
            if isHandsFreeOperation {
                stopAndTranscribe()
            } else {
                lockHandsFree()
            }
        case .transcribing:
            break
        case .commandListening, .commandProcessing, .scratchpadListening, .scratchpadProcessing:
            break
        }
    }

    func startRecording(mode: DictationRecordingMode = .pushToTalk) {
        guard isSetupComplete() else {
            appState.setError(AppError.setupIncomplete)
            onSetupRequired()
            return
        }
        guard appState.state == .idle || isErrorState(appState.state) else {
            return
        }
        recordingTask?.cancel()
        transcriptionTask?.cancel()
        sessionLimitTask?.cancel()
        let operationID = UUID()
        currentOperationID = operationID
        requestedRecordingMode = mode
        pendingStopOperationID = nil
        targetAppContextTask?.cancel()
        targetAppContextTask = Task { [appContextProvider] in
            await appContextProvider.currentContext()
        }
        recordingTask = Task {
            do {
                try await recorder.startRecording()
                guard isCurrent(operationID), !Task.isCancelled else {
                    recorder.cancelRecording()
                    return
                }
                recordingTask = nil
                recordingStartedAt = Date()
                let activeMode = requestedRecordingMode ?? mode
                appState.setListening(mode: activeMode)
                startSessionLimit(for: operationID)
                if pendingStopOperationID == operationID {
                    pendingStopOperationID = nil
                    stopAndTranscribe()
                }
            } catch {
                guard isCurrent(operationID), !Task.isCancelled else { return }
                recordingTask = nil
                currentOperationID = nil
                requestedRecordingMode = nil
                pendingStopOperationID = nil
                targetAppContextTask?.cancel()
                targetAppContextTask = nil
                recordingStartedAt = nil
                appState.setState(.error(error.localizedDescription))
            }
        }
    }

    func lockHandsFree() {
        guard currentOperationID != nil,
              recordingTask != nil || appState.state == .listening else { return }
        requestedRecordingMode = .handsFree
        if appState.state == .listening {
            appState.updateActiveDictationMode(.handsFree)
        }
    }

    func stopAndTranscribe() {
        guard let operationID = currentOperationID else { return }
        if appState.state != .listening {
            if recordingTask != nil {
                pendingStopOperationID = operationID
            }
            return
        }
        recordingTask = nil
        requestedRecordingMode = nil
        pendingStopOperationID = nil
        sessionLimitTask?.cancel()
        sessionLimitTask = nil
        appState.setState(.transcribing)
        let recordingURL: URL
        do {
            recordingURL = try recorder.stopRecording()
        } catch {
            currentOperationID = nil
            requestedRecordingMode = nil
            pendingStopOperationID = nil
            targetAppContextTask?.cancel()
            targetAppContextTask = nil
            recordingStartedAt = nil
            appState.setState(.error(error.localizedDescription))
            return
        }

        let stoppedAt = Date()
        let durationSeconds = recordingStartedAt.map {
            max(0, stoppedAt.timeIntervalSince($0))
        }
        recordingStartedAt = nil
        let historyStart = appState.beginHistoryRecording(
            date: stoppedAt,
            durationSeconds: durationSeconds,
            language: appState.language.trimmedOrNil,
            context: nil,
            recordingURL: recordingURL
        )
        pendingHistoryItemID = historyStart.itemID
        let transcriptionURL = historyStart.transcriptionURL
        pendingRecordingURL = historyStart.shouldDeleteTranscriptionURL
            ? transcriptionURL
            : nil

        transcriptionTask?.cancel()
        let contextTask = targetAppContextTask
        transcriptionTask = Task {
            defer {
                if historyStart.shouldDeleteTranscriptionURL {
                    try? FileManager.default.removeItem(at: transcriptionURL)
                }
                if pendingRecordingURL == transcriptionURL {
                    pendingRecordingURL = nil
                }
            }
            do {
                let vocabularyPrompt = DictionaryPromptBuilder.prompt(for: appState.dictionaryEntries)
                let text = try await client.transcribe(
                    fileURL: transcriptionURL,
                    language: appState.language.trimmedOrNil,
                    vocabularyPrompt: vocabularyPrompt
                )
                guard isCurrent(operationID), !Task.isCancelled else { return }
                let finalText: String
                if appState.polishEnabled {
                    let polished = try await client.polishTranscript(text: text)
                    guard isCurrent(operationID), !Task.isCancelled else { return }
                    finalText = polished.text
                    appState.addTokenUsage(prompt: polished.promptTokens, completion: polished.completionTokens)
                } else {
                    finalText = text
                }
                let outputCommand = OutputCommandParser.parse(
                    finalText,
                    pressEnterEnabled: appState.pressEnterEnabled
                )
                let correctedText = DictionaryCorrector.correct(
                    outputCommand.text,
                    using: appState.dictionaryEntries
                )
                guard isCurrent(operationID), !Task.isCancelled else { return }
                let transformedText = try await applyAutomaticTransformIfNeeded(
                    correctedText,
                    operationID: operationID
                )
                guard isCurrent(operationID), !Task.isCancelled else { return }
                let targetAppContext = await contextTask?.value
                guard isCurrent(operationID), !Task.isCancelled else { return }
                appState.updateHistoryContext(
                    id: historyStart.itemID,
                    context: targetAppContext
                )
                let styledText = appState.styledDictation(
                    transformedText,
                    for: targetAppContext
                )
                let expandedText = SnippetExpander.expand(
                    styledText,
                    using: appState.snippets
                )
                appState.finishHistoryItem(id: historyStart.itemID, text: expandedText)
                try await injector.insert(
                    text: expandedText,
                    pressEnter: outputCommand.pressesEnter
                )
                guard isCurrent(operationID), !Task.isCancelled else { return }
                currentOperationID = nil
                requestedRecordingMode = nil
                pendingStopOperationID = nil
                targetAppContextTask = nil
                pendingHistoryItemID = nil
                appState.setState(.idle)
            } catch {
                guard isCurrent(operationID), !Task.isCancelled else { return }
                appState.failHistoryItem(
                    id: historyStart.itemID,
                    message: error.localizedDescription
                )
                currentOperationID = nil
                requestedRecordingMode = nil
                pendingStopOperationID = nil
                targetAppContextTask?.cancel()
                targetAppContextTask = nil
                pendingHistoryItemID = nil
                appState.setState(.error(error.localizedDescription))
            }
        }
    }

    func cancelCurrentDictation() {
        guard currentOperationID != nil else { return }
        if let pendingHistoryItemID {
            appState.failHistoryItem(
                id: pendingHistoryItemID,
                message: "Dictation was canceled before transcription finished."
            )
        }
        currentOperationID = nil
        requestedRecordingMode = nil
        pendingStopOperationID = nil
        recordingTask?.cancel()
        transcriptionTask?.cancel()
        sessionLimitTask?.cancel()
        recordingTask = nil
        transcriptionTask = nil
        sessionLimitTask = nil
        recorder.cancelRecording()
        targetAppContextTask?.cancel()
        targetAppContextTask = nil
        recordingStartedAt = nil
        pendingHistoryItemID = nil
        if let pendingRecordingURL {
            try? FileManager.default.removeItem(at: pendingRecordingURL)
            self.pendingRecordingURL = nil
        }
        appState.setState(.idle)
    }

    func pasteLastTranscript() {
        guard !appState.lastTranscript.isEmpty else { return }
        guard appState.state != .listening, appState.state != .transcribing else { return }

        let transcript = appState.lastTranscript
        Task {
            do {
                try await injector.insert(text: transcript)
                if case .error = appState.state {
                    appState.setState(.idle)
                }
            } catch {
                appState.setState(.error(error.localizedDescription))
            }
        }
    }

    func copyLastTranscript() {
        guard !appState.lastTranscript.isEmpty else { return }
        do {
            try injector.copy(text: appState.lastTranscript)
        } catch {
            appState.setState(.error(error.localizedDescription))
        }
    }

    private func isCurrent(_ operationID: UUID) -> Bool {
        currentOperationID == operationID
    }

    private func startSessionLimit(for operationID: UUID) {
        sessionLimitTask?.cancel()
        let limits = sessionLimits
        sessionLimitTask = Task { [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: Self.nanoseconds(for: limits.warningAfter)
                )
            } catch {
                return
            }
            guard let self,
                  self.isCurrent(operationID),
                  self.appState.state == .listening else { return }
            self.appState.setDictationSessionWarning("1 min left")

            do {
                try await Task.sleep(
                    nanoseconds: Self.nanoseconds(
                        for: limits.maximumDuration - limits.warningAfter
                    )
                )
            } catch {
                return
            }
            guard self.isCurrent(operationID),
                  self.appState.state == .listening else { return }
            self.stopAndTranscribe()
        }
    }

    private static func nanoseconds(for interval: TimeInterval) -> UInt64 {
        UInt64(max(0, interval) * 1_000_000_000)
    }

    private func isErrorState(_ state: AppState.State) -> Bool {
        if case .error = state { return true }
        return false
    }

    private func applyAutomaticTransformIfNeeded(
        _ text: String,
        operationID: UUID
    ) async throws -> String {
        guard !text.isEmpty,
              appState.transformSettings.isEnabled,
              let transformID = appState.transformSettings.autoApplyTransformID,
              let definition = appState.transformSettings.definition(id: transformID),
              let transformClient else {
            return text
        }

        let invocation = appState.transformSettings.invocation(for: definition)
        do {
            let generated = try await transformClient.transform(
                text: text,
                invocation: invocation
            )
            try Task.checkCancellation()
            guard generated.text.trimmedOrNil != nil else {
                throw AppError.transformReturnedNoText
            }
            guard isCurrent(operationID) else { throw CancellationError() }
            appState.addTokenUsage(
                prompt: generated.inputTokens,
                completion: generated.outputTokens
            )
            appState.lastTransformResult = TransformResult(
                id: UUID(),
                invocation: invocation,
                originalText: text,
                transformedText: generated.text,
                createdAt: Date(),
                source: .automaticDictation,
                replacementReceipt: nil,
                isUndone: false
            )
            appState.transformFeedbackMessage = generated.text == text
                ? "Auto-transform made no changes."
                : "Applied \(definition.name) to your dictation."
            return generated.text
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            appState.transformFeedbackMessage = "Auto-transform failed. Pasted the original dictation instead."
            return text
        }
    }
}
