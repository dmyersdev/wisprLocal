import Foundation

@MainActor
final class HistoryController: ObservableObject {
    @Published var feedbackMessage: String?

    private let appState: AppState
    private let transcriptionClient: TranscriptionServing
    private let transformClient: TransformServing?
    private let injector: TextInjecting
    private var retryTasks: [UUID: Task<Void, Never>] = [:]

    init(
        appState: AppState,
        transcriptionClient: TranscriptionServing,
        transformClient: TransformServing? = nil,
        injector: TextInjecting
    ) {
        self.appState = appState
        self.transcriptionClient = transcriptionClient
        self.transformClient = transformClient
        self.injector = injector
    }

    func copy(itemID: UUID) {
        guard let item = appState.historyItem(id: itemID),
              item.status == .succeeded,
              !item.text.isEmpty else {
            return
        }
        do {
            try injector.copy(text: item.text)
            feedbackMessage = "Copied transcript"
        } catch {
            feedbackMessage = error.localizedDescription
        }
    }

    func retry(itemID: UUID) {
        guard retryTasks[itemID] == nil,
              let item = appState.historyItem(id: itemID),
              let audioURL = appState.historyAudioURL(for: itemID) else {
            feedbackMessage = "The recording for this transcript is no longer available."
            return
        }
        guard appState.markHistoryItemRetrying(id: itemID) else { return }

        retryTasks[itemID] = Task { [weak self] in
            guard let self else { return }
            defer { retryTasks[itemID] = nil }
            do {
                let text = try await transcriptionClient.transcribe(
                    fileURL: audioURL,
                    language: item.language,
                    vocabularyPrompt: DictionaryPromptBuilder.prompt(
                        for: appState.dictionaryEntries
                    )
                )
                try Task.checkCancellation()
                let processedText = try await processRetry(text, item: item)
                try Task.checkCancellation()
                appState.finishHistoryItem(id: itemID, text: processedText)
                feedbackMessage = processedText.isEmpty
                    ? "Retry completed with no speech detected."
                    : "Transcript retried"
            } catch is CancellationError {
                // Deletion or task teardown owns the final state.
            } catch {
                guard !Task.isCancelled else { return }
                appState.failHistoryItem(id: itemID, message: error.localizedDescription)
                feedbackMessage = "Retry failed: \(error.localizedDescription)"
            }
        }
    }

    func delete(itemID: UUID) {
        retryTasks[itemID]?.cancel()
        retryTasks[itemID] = nil
        do {
            try appState.deleteHistoryItem(id: itemID)
            feedbackMessage = "Transcript deleted"
        } catch {
            feedbackMessage = "Couldn’t delete transcript: \(error.localizedDescription)"
        }
    }

    private func processRetry(
        _ text: String,
        item: HistoryItem
    ) async throws -> String {
        let polishedText: String
        if appState.polishEnabled {
            let polished = try await transcriptionClient.polishTranscript(text: text)
            try Task.checkCancellation()
            appState.addTokenUsage(
                prompt: polished.promptTokens,
                completion: polished.completionTokens
            )
            polishedText = polished.text
        } else {
            polishedText = text
        }

        let outputCommand = OutputCommandParser.parse(
            polishedText,
            pressEnterEnabled: appState.pressEnterEnabled
        )
        let correctedText = DictionaryCorrector.correct(
            outputCommand.text,
            using: appState.dictionaryEntries
        )
        let transformedText = try await applyAutomaticTransformIfNeeded(correctedText)
        try Task.checkCancellation()

        let context = StyleAppContext(
            bundleIdentifier: item.bundleIdentifier,
            applicationName: item.applicationName,
            documentURL: nil
        )
        let styledText: String
        if appState.stylePreferences.hasCompletedSetup,
           WritingStyleLanguagePolicy.shouldApply(
               configuredLanguage: item.language ?? "",
               to: transformedText
           ) {
            let category = StyleAppClassifier.category(
                for: context,
                preferences: appState.stylePreferences
            )
            styledText = TranscriptStyleFormatter.format(
                transformedText,
                as: appState.stylePreferences.style(for: category)
            )
        } else {
            styledText = transformedText
        }
        return SnippetExpander.expand(styledText, using: appState.snippets)
    }

    private func applyAutomaticTransformIfNeeded(_ text: String) async throws -> String {
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
            return generated.text
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            appState.transformFeedbackMessage = "Auto-transform failed during retry. Kept the transcription instead."
            return text
        }
    }
}
