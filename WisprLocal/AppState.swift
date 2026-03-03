import Foundation

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    enum State: Equatable {
        case idle
        case listening
        case transcribing
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
    @Published var history: [HistoryItem] = []
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
    @Published var tokensSent: Int {
        didSet { defaults.set(tokensSent, forKey: DefaultsKeys.tokensSent) }
    }
    @Published var tokensReceived: Int {
        didSet { defaults.set(tokensReceived, forKey: DefaultsKeys.tokensReceived) }
    }
    @Published var hotkeyWarning: String?
    @Published var listeningStartedFromHUD: Bool = false

    private let defaults = UserDefaults.standard

    private init() {
        language = defaults.string(forKey: DefaultsKeys.language) ?? ""
        if defaults.object(forKey: DefaultsKeys.polishEnabled) == nil {
            polishEnabled = true
        } else {
            polishEnabled = defaults.bool(forKey: DefaultsKeys.polishEnabled)
        }
        holdToTalk = defaults.bool(forKey: DefaultsKeys.holdToTalk)
        tokensSent = defaults.integer(forKey: DefaultsKeys.tokensSent)
        tokensReceived = defaults.integer(forKey: DefaultsKeys.tokensReceived)
        history = Self.loadHistory(defaults: defaults)
        lastTranscript = history.first?.text ?? ""
    }

    func setState(_ newState: State) {
        if newState != .listening {
            listeningStartedFromHUD = false
        }
        state = newState
    }

    func setError(_ error: Error) {
        state = .error(error.localizedDescription)
    }

    func addHistory(text: String) {
        let item = HistoryItem(id: UUID(), date: Date(), text: text)
        history.insert(item, at: 0)
        if history.count > 20 {
            history = Array(history.prefix(20))
        }
        persistHistory()
    }

    func addTokenUsage(prompt: Int, completion: Int) {
        tokensSent += prompt
        tokensReceived += completion
    }

    private func persistHistory() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(history) {
            defaults.set(data, forKey: DefaultsKeys.history)
        }
    }

    private static func loadHistory(defaults: UserDefaults) -> [HistoryItem] {
        guard let data = defaults.data(forKey: DefaultsKeys.history) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([HistoryItem].self, from: data)) ?? []
    }
}
