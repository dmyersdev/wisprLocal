import Foundation

protocol CommandServing: AnyObject {
    func executeCommand(_ request: CommandModeRequest) async throws -> CommandGenerationResult
}

@MainActor
final class CommandModeController: ObservableObject {
    enum State: Equatable {
        case idle
        case starting
        case listening
        case processing
        case success
        case unchanged
        case error(String)
    }

    @Published private(set) var state: State = .idle

    private let appState: AppState
    private let recorder: AudioRecording
    private let transcriptionClient: TranscriptionServing
    private let commandClient: CommandServing
    private let editor: SelectedTextEditing
    private let isOtherActionInProgress: () -> Bool
    private let isSetupComplete: () -> Bool
    private let onSetupRequired: () -> Void

    private var recordingTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var operationID: UUID?
    private var pendingRecordingURL: URL?
    private var stopRequested = false
    private var isCommitting = false

    var canCancel: Bool {
        operationID != nil && !isCommitting
    }

    var isActive: Bool {
        operationID != nil
    }

    init(
        appState: AppState,
        recorder: AudioRecording,
        transcriptionClient: TranscriptionServing,
        commandClient: CommandServing,
        editor: SelectedTextEditing,
        isOtherActionInProgress: @escaping () -> Bool = { false },
        isSetupComplete: @escaping () -> Bool = { true },
        onSetupRequired: @escaping () -> Void = {}
    ) {
        self.appState = appState
        self.recorder = recorder
        self.transcriptionClient = transcriptionClient
        self.commandClient = commandClient
        self.editor = editor
        self.isOtherActionInProgress = isOtherActionInProgress
        self.isSetupComplete = isSetupComplete
        self.onSetupRequired = onSetupRequired
    }

    func startRecording() {
        guard isSetupComplete() else {
            publish(error: AppError.setupIncomplete)
            onSetupRequired()
            return
        }
        guard appState.commandModeEnabled else {
            state = .error("Command mode is toggled off")
            appState.commandFeedbackMessage = "Command mode is toggled off"
            return
        }
        guard operationID == nil else {
            publish(error: AppError.commandInProgress)
            return
        }
        guard appState.state == .idle || isErrorState(appState.state),
              !isOtherActionInProgress() else {
            publish(error: AppError.commandUnavailableWhileBusy)
            return
        }

        let currentID = UUID()
        operationID = currentID
        stopRequested = false
        state = .starting
        appState.setState(.commandListening)
        appState.commandFeedbackMessage = nil
        recordingTask?.cancel()
        recordingTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await recorder.startRecording()
                guard isCurrent(currentID), !Task.isCancelled else {
                    recorder.cancelRecording()
                    return
                }
                state = .listening
                appState.setState(.commandListening)
                if stopRequested {
                    stopAndExecute()
                }
            } catch {
                guard isCurrent(currentID), !Task.isCancelled else { return }
                finishWithError(error, operationID: currentID)
            }
        }
    }

    func stopAndExecute() {
        guard let currentID = operationID else { return }
        if state == .starting {
            stopRequested = true
            return
        }
        guard state == .listening else { return }

        recordingTask = nil
        state = .processing
        appState.setState(.commandProcessing)
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
                let target = try await captureTarget()
                if case .selection(let selection) = target,
                   !(1...1_000).contains(selection.wordCount) {
                    throw AppError.commandSelectionTooLong
                }
                try Task.checkCancellation()

                let instruction = try await transcriptionClient.transcribe(
                    fileURL: recordingURL,
                    language: appState.language.trimmedOrNil,
                    vocabularyPrompt: DictionaryPromptBuilder.prompt(
                        for: appState.dictionaryEntries
                    )
                )
                guard let instruction = instruction.trimmedOrNil else {
                    throw AppError.commandFailed("No spoken instruction was detected.")
                }
                try Task.checkCancellation()
                guard isCurrent(currentID) else { return }

                let generated = try await commandClient.executeCommand(
                    CommandModeRequest(
                        instruction: instruction,
                        selectedText: target.selectedText
                    )
                )
                try Task.checkCancellation()
                guard generated.text.trimmedOrNil != nil else {
                    throw AppError.commandReturnedNoText
                }
                guard isCurrent(currentID) else { return }

                appState.addTokenUsage(
                    prompt: generated.inputTokens,
                    completion: generated.outputTokens
                )

                if case .selection(let selection) = target,
                   generated.text == selection.text {
                    appState.lastCommandResult = CommandModeResult(
                        id: UUID(),
                        instruction: instruction,
                        originalText: selection.text,
                        generatedText: generated.text,
                        createdAt: Date(),
                        replacementReceipt: nil
                    )
                    finish(
                        currentID,
                        state: .unchanged,
                        message: "Command complete. Your selected text didn’t need changes."
                    )
                    return
                }

                isCommitting = true
                let receipt: TextReplacementReceipt?
                switch target {
                case .selection(let selection):
                    receipt = try await editor.replaceSelection(
                        selection,
                        with: generated.text
                    )
                case .insertion(let insertionTarget):
                    try await editor.insert(generated.text, at: insertionTarget)
                    receipt = nil
                }
                isCommitting = false
                guard isCurrent(currentID) else { return }

                appState.lastCommandResult = CommandModeResult(
                    id: UUID(),
                    instruction: instruction,
                    originalText: target.selectedText,
                    generatedText: generated.text,
                    createdAt: Date(),
                    replacementReceipt: receipt
                )
                let message = target.selectedText == nil
                    ? "Command complete. Inserted generated text."
                    : "Command complete. Updated selected text."
                finish(currentID, state: .success, message: message)
            } catch is CancellationError {
                guard isCurrent(currentID) else { return }
                finish(currentID, state: .idle, message: "Command cancelled.")
            } catch {
                guard isCurrent(currentID) else { return }
                finishWithError(error, operationID: currentID)
            }
        }
    }

    func cancelCurrentCommand() {
        guard operationID != nil, !isCommitting else { return }
        operationID = nil
        stopRequested = false
        recordingTask?.cancel()
        processingTask?.cancel()
        recordingTask = nil
        processingTask = nil
        recorder.cancelRecording()
        if let pendingRecordingURL {
            try? FileManager.default.removeItem(at: pendingRecordingURL)
            self.pendingRecordingURL = nil
        }
        state = .idle
        appState.setState(.idle)
        appState.commandFeedbackMessage = "Command cancelled."
    }

    private enum Target {
        case selection(CapturedTextSelection)
        case insertion(CapturedTextInsertionTarget)

        var selectedText: String? {
            if case .selection(let selection) = self {
                return selection.text
            }
            return nil
        }
    }

    private func captureTarget() async throws -> Target {
        do {
            return .selection(try await editor.captureSelection())
        } catch let error as AppError {
            if case .noTextSelected = error {
                return .insertion(try editor.captureInsertionTarget())
            }
            throw error
        }
    }

    private func isCurrent(_ id: UUID) -> Bool {
        operationID == id
    }

    private func isErrorState(_ state: AppState.State) -> Bool {
        if case .error = state { return true }
        return false
    }

    private func finish(_ id: UUID, state: State, message: String) {
        guard isCurrent(id) else { return }
        operationID = nil
        recordingTask = nil
        processingTask = nil
        stopRequested = false
        isCommitting = false
        self.state = state
        appState.setState(.idle)
        appState.commandFeedbackMessage = message
    }

    private func finishWithError(_ error: Error, operationID: UUID) {
        guard isCurrent(operationID) else { return }
        self.operationID = nil
        recordingTask = nil
        processingTask = nil
        stopRequested = false
        isCommitting = false
        recorder.cancelRecording()
        let message = error.localizedDescription
        state = .error(message)
        appState.commandFeedbackMessage = message
        appState.setState(.error(message))
    }

    private func publish(error: Error) {
        let message = error.localizedDescription
        state = .error(message)
        appState.commandFeedbackMessage = message
    }
}
