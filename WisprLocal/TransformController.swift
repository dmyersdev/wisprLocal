import Foundation

struct TransformResult: Identifiable {
    enum Source: Equatable {
        case selectedText
        case automaticDictation
    }

    let id: UUID
    let invocation: TransformInvocation
    let originalText: String
    let transformedText: String
    let createdAt: Date
    let source: Source
    let replacementReceipt: TextReplacementReceipt?
    let isUndone: Bool

    var canUndo: Bool {
        replacementReceipt != nil && !isUndone
    }
}

@MainActor
final class TransformController: ObservableObject {
    enum State: Equatable {
        case idle
        case processing(String)
        case success(String)
        case unchanged
        case error(String)
    }

    @Published private(set) var state: State = .idle

    private let appState: AppState
    private let client: TransformServing
    private let editor: SelectedTextEditing
    private let injector: TextInjecting
    private let isSetupComplete: () -> Bool
    private let onSetupRequired: () -> Void
    private var operationTask: Task<Void, Never>?
    private var operationID: UUID?
    private var isCommittingReplacement = false

    var canCancel: Bool {
        operationID != nil && !isCommittingReplacement
    }

    var isActive: Bool {
        operationID != nil
    }

    init(
        appState: AppState,
        client: TransformServing,
        editor: SelectedTextEditing,
        injector: TextInjecting,
        isSetupComplete: @escaping () -> Bool = { true },
        onSetupRequired: @escaping () -> Void = {}
    ) {
        self.appState = appState
        self.client = client
        self.editor = editor
        self.injector = injector
        self.isSetupComplete = isSetupComplete
        self.onSetupRequired = onSetupRequired
    }

    func apply(transformID: UUID) {
        guard requireSetup() else { return }
        guard appState.transformSettings.isEnabled else { return }
        guard appState.state == .idle else {
            publish(error: AppError.transformUnavailableWhileDictating)
            return
        }
        guard operationID == nil else {
            publish(error: AppError.transformInProgress)
            return
        }
        guard let definition = appState.transformSettings.definition(id: transformID) else {
            return
        }

        let invocation = appState.transformSettings.invocation(for: definition)
        let currentID = UUID()
        operationID = currentID
        state = .processing(definition.name)
        appState.transformFeedbackMessage = "Using \(definition.name)…"
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let selection = try await editor.captureSelection()
                guard (1...1_000).contains(selection.wordCount) else {
                    throw AppError.transformSelectionTooLong
                }
                try Task.checkCancellation()
                let generated = try await client.transform(
                    text: selection.text,
                    invocation: invocation
                )
                try Task.checkCancellation()
                guard generated.text.trimmedOrNil != nil else {
                    throw AppError.transformReturnedNoText
                }
                guard isCurrent(currentID) else { return }
                appState.addTokenUsage(
                    prompt: generated.inputTokens,
                    completion: generated.outputTokens
                )

                if generated.text == selection.text {
                    let result = TransformResult(
                        id: UUID(),
                        invocation: invocation,
                        originalText: selection.text,
                        transformedText: generated.text,
                        createdAt: Date(),
                        source: .selectedText,
                        replacementReceipt: nil,
                        isUndone: false
                    )
                    appState.lastTransformResult = result
                    finish(currentID, state: .unchanged, message: "Your text already looks good.")
                    return
                }

                isCommittingReplacement = true
                let receipt = try await editor.replaceSelection(
                    selection,
                    with: generated.text
                )
                isCommittingReplacement = false
                guard isCurrent(currentID) else { return }
                appState.lastTransformResult = TransformResult(
                    id: UUID(),
                    invocation: invocation,
                    originalText: selection.text,
                    transformedText: generated.text,
                    createdAt: Date(),
                    source: .selectedText,
                    replacementReceipt: receipt,
                    isUndone: false
                )
                let suffix = receipt == nil ? " Undo isn’t available in this editor." : ""
                finish(
                    currentID,
                    state: .success(definition.name),
                    message: "Applied \(definition.name).\(suffix)"
                )
            } catch is CancellationError {
                guard isCurrent(currentID) else { return }
                finish(currentID, state: .idle, message: "Transform cancelled.")
            } catch {
                guard isCurrent(currentID) else { return }
                publish(error: error, operationID: currentID)
            }
        }
    }

    func retryLastTransform() {
        guard requireSetup() else { return }
        guard appState.state == .idle else {
            publish(error: AppError.transformUnavailableWhileDictating)
            return
        }
        guard operationID == nil else {
            publish(error: AppError.transformInProgress)
            return
        }
        guard let previousResult = appState.lastTransformResult else { return }

        let currentID = UUID()
        operationID = currentID
        state = .processing(previousResult.invocation.name)
        appState.transformFeedbackMessage = "Retrying \(previousResult.invocation.name)…"
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let generated = try await client.transform(
                    text: previousResult.originalText,
                    invocation: previousResult.invocation
                )
                try Task.checkCancellation()
                guard generated.text.trimmedOrNil != nil else {
                    throw AppError.transformReturnedNoText
                }
                guard isCurrent(currentID) else { return }
                appState.addTokenUsage(
                    prompt: generated.inputTokens,
                    completion: generated.outputTokens
                )

                var receipt: TextReplacementReceipt?
                if let previousReceipt = previousResult.replacementReceipt,
                   !previousResult.isUndone {
                    receipt = try editor.replaceAppliedText(
                        previousReceipt,
                        with: generated.text
                    )
                }
                appState.lastTransformResult = TransformResult(
                    id: UUID(),
                    invocation: previousResult.invocation,
                    originalText: previousResult.originalText,
                    transformedText: generated.text,
                    createdAt: Date(),
                    source: previousResult.source,
                    replacementReceipt: receipt,
                    isUndone: false
                )
                let message = receipt == nil
                    ? "Retry complete. Review or copy the result."
                    : "Reapplied \(previousResult.invocation.name)."
                finish(
                    currentID,
                    state: generated.text == previousResult.originalText
                        ? .unchanged
                        : .success(previousResult.invocation.name),
                    message: message
                )
            } catch is CancellationError {
                guard isCurrent(currentID) else { return }
                finish(currentID, state: .idle, message: "Transform cancelled.")
            } catch {
                guard isCurrent(currentID) else { return }
                publish(error: error, operationID: currentID)
            }
        }
    }

    func undoLastTransform() {
        guard requireSetup() else { return }
        guard appState.state == .idle else {
            publish(error: AppError.transformUnavailableWhileDictating)
            return
        }
        guard operationID == nil else {
            publish(error: AppError.transformInProgress)
            return
        }
        guard let result = appState.lastTransformResult,
              let receipt = result.replacementReceipt,
              result.canUndo else {
            publish(error: AppError.transformUndoUnavailable)
            return
        }
        do {
            try editor.undo(receipt)
            appState.lastTransformResult = TransformResult(
                id: result.id,
                invocation: result.invocation,
                originalText: result.originalText,
                transformedText: result.transformedText,
                createdAt: result.createdAt,
                source: result.source,
                replacementReceipt: nil,
                isUndone: true
            )
            state = .success("Undo")
            appState.transformFeedbackMessage = "Transform undone."
        } catch {
            publish(error: error)
        }
    }

    func copyLastTransform() {
        guard requireSetup() else { return }
        guard let result = appState.lastTransformResult else { return }
        do {
            try injector.copy(text: result.transformedText)
            appState.transformFeedbackMessage = "Transformed text copied."
        } catch {
            publish(error: error)
        }
    }

    func showLatestResult() {
        guard requireSetup() else { return }
        guard appState.lastTransformResult != nil else { return }
        appState.isTransformResultPresented = true
    }

    func cancelCurrentTransform() {
        guard operationID != nil, !isCommittingReplacement else { return }
        operationID = nil
        operationTask?.cancel()
        operationTask = nil
        state = .idle
        appState.transformFeedbackMessage = "Transform cancelled."
    }

    private func isCurrent(_ id: UUID) -> Bool {
        operationID == id
    }

    private func finish(_ id: UUID, state: State, message: String) {
        guard isCurrent(id) else { return }
        operationID = nil
        operationTask = nil
        isCommittingReplacement = false
        self.state = state
        appState.transformFeedbackMessage = message
    }

    private func publish(error: Error, operationID: UUID? = nil) {
        if let operationID {
            guard isCurrent(operationID) else { return }
            self.operationID = nil
            operationTask = nil
        }
        isCommittingReplacement = false
        let message = error.localizedDescription
        state = .error(message)
        appState.transformFeedbackMessage = message
    }

    private func requireSetup() -> Bool {
        guard isSetupComplete() else {
            publish(error: AppError.setupIncomplete)
            onSetupRequired()
            return false
        }
        return true
    }
}
