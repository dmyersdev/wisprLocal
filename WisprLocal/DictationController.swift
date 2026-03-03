import Foundation

@MainActor
final class DictationController: ObservableObject {
    enum RecordingSource {
        case hotkey
        case hud
    }

    private let appState: AppState
    private let recorder: AudioRecorder
    private let client: OpenAIClient
    private let injector: TextInjector

    private var transcriptionTask: Task<Void, Never>?

    init(appState: AppState,
         recorder: AudioRecorder,
         client: OpenAIClient,
         injector: TextInjector) {
        self.appState = appState
        self.recorder = recorder
        self.client = client
        self.injector = injector
    }

    func toggle() {
        switch appState.state {
        case .idle, .error:
            startRecording()
        case .listening:
            stopAndTranscribe()
        case .transcribing:
            break
        }
    }

    func startRecording(source: RecordingSource = .hotkey) {
        if appState.state == .listening || appState.state == .transcribing {
            return
        }
        appState.listeningStartedFromHUD = (source == .hud)
        transcriptionTask?.cancel()
        Task {
            do {
                try await recorder.startRecording()
                appState.setState(.listening)
            } catch {
                appState.listeningStartedFromHUD = false
                appState.setState(.error(error.localizedDescription))
            }
        }
    }

    func stopAndTranscribe() {
        if appState.state != .listening {
            return
        }
        appState.listeningStartedFromHUD = false
        appState.setState(.transcribing)
        let recordingURL: URL
        do {
            recordingURL = try recorder.stopRecording()
        } catch {
            appState.setState(.error(error.localizedDescription))
            return
        }

        transcriptionTask?.cancel()
        transcriptionTask = Task {
            defer { try? FileManager.default.removeItem(at: recordingURL) }
            do {
                let text = try await client.transcribe(fileURL: recordingURL, language: appState.language.trimmedOrNil)
                let finalText: String
                if appState.polishEnabled {
                    let polished = try await client.polishTranscript(text: text)
                    finalText = polished.text
                    appState.addTokenUsage(prompt: polished.promptTokens, completion: polished.completionTokens)
                } else {
                    finalText = text
                }
                appState.lastTranscript = finalText
                appState.addHistory(text: finalText)
                try injector.paste(text: finalText)
                appState.setState(.idle)
            } catch {
                appState.setState(.error(error.localizedDescription))
            }
        }
    }
}
