import Foundation

protocol TranscriptionServing: AnyObject {
    func transcribe(
        fileURL: URL,
        language: String?,
        vocabularyPrompt: String?
    ) async throws -> String

    func polishTranscript(text: String) async throws -> PolishResult
}

protocol TransformServing: AnyObject {
    func transform(
        text: String,
        invocation: TransformInvocation
    ) async throws -> TransformGenerationResult
}

final class OpenAIClient: TranscriptionServing, TransformServing, CommandServing {
    private let keychain: KeychainService
    private let session: URLSession
    private let maxFileSizeBytes: Int64 = 25 * 1024 * 1024

    init(keychain: KeychainService = .shared) {
        self.keychain = keychain
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
    }

    static func audioContentType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "m4a", "mp4":
            return "audio/mp4"
        case "wav":
            return "audio/wav"
        case "mp3", "mpeg", "mpga":
            return "audio/mpeg"
        case "webm":
            return "audio/webm"
        default:
            return "application/octet-stream"
        }
    }

    func transcribe(
        fileURL: URL,
        language: String?,
        vocabularyPrompt: String?
    ) async throws -> String {
        guard let apiKey = try keychain.loadAPIKey(), !apiKey.isEmpty else {
            throw AppError.missingAPIKey
        }

        let fileSize = try fileSizeBytes(for: fileURL)
        if fileSize > maxFileSizeBytes {
            throw AppError.fileTooLarge
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        let url = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let fields = Self.transcriptionFields(
            language: language,
            vocabularyPrompt: vocabularyPrompt
        )

        request.httpBody = try createMultipartBody(fileURL: fileURL, boundary: boundary, fields: fields)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AppError.transcriptionFailed("Invalid response.")
            }

            switch http.statusCode {
            case 200...299:
                if let response = try? JSONDecoder().decode(AudioTranscriptionResponse.self, from: data),
                   let text = response.text.trimmedOrNil {
                    return text
                }
                throw AppError.transcriptionFailed("Empty response.")
            case 401:
                throw AppError.unauthorized
            case 403:
                throw AppError.forbidden
            default:
                let message = parseAPIErrorMessage(data: data)
                throw AppError.transcriptionFailed(message ?? "HTTP \(http.statusCode)")
            }
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.network(error.localizedDescription)
        }
    }

    static func transcriptionFields(
        language: String?,
        vocabularyPrompt: String?
    ) -> [String: String] {
        var fields = [
            "model": "gpt-4o-mini-transcribe",
            "response_format": "json"
        ]
        if let language = language?.trimmedOrNil {
            fields["language"] = language
        }
        if let vocabularyPrompt = vocabularyPrompt?.trimmedOrNil {
            fields["prompt"] = vocabularyPrompt
        }
        return fields
    }

    func polishTranscript(text: String) async throws -> PolishResult {
        guard let apiKey = try keychain.loadAPIKey(), !apiKey.isEmpty else {
            throw AppError.missingAPIKey
        }

        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let systemPrompt = """
        You are a transcription cleanup engine. Improve casing, punctuation, and minor grammar only. Do NOT summarize or add new information. Preserve meaning and keep all content, but resolve self-corrections by keeping only the final intended wording (remove the superseded clause and keep the correction). If a sentence includes a correction like “X… no, sorry… Y”, output only Y. Remove obvious filler words only if they are part of a correction. If the speaker is listing distinct points or steps, format those lines as bullet points using "-" while preserving the original order and wording.
        Example:
        Input: "I'm doing a project where I'm hanging photos on my wall. Oh wait, no, actually, I'm hanging photos on my ceiling. I need to do three things: buy a picture frame, buy nails, buy a hammer."
        Output: "I'm doing a project where I'm hanging photos on my ceiling. I need to do three things:\n- Buy a picture frame\n- Buy nails\n- Buy a hammer"
        """
        let payload = ChatCompletionRequest(
            model: "gpt-4.1-nano",
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: text)
            ]
        )

        request.httpBody = try JSONEncoder().encode(payload)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AppError.transcriptionFailed("Invalid response.")
            }

            switch http.statusCode {
            case 200...299:
                let result = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
                if let content = result.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !content.isEmpty {
                    let promptTokens = result.usage?.promptTokens ?? 0
                    let completionTokens = result.usage?.completionTokens ?? 0
                    return PolishResult(text: content, promptTokens: promptTokens, completionTokens: completionTokens)
                }
                throw AppError.transcriptionFailed("Empty polish response.")
            case 401:
                throw AppError.unauthorized
            case 403:
                throw AppError.forbidden
            default:
                let message = parseAPIErrorMessage(data: data)
                throw AppError.transcriptionFailed(message ?? "HTTP \(http.statusCode)")
            }
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.network(error.localizedDescription)
        }
    }

    func transform(
        text: String,
        invocation: TransformInvocation
    ) async throws -> TransformGenerationResult {
        guard let apiKey = try keychain.loadAPIKey(), !apiKey.isEmpty else {
            throw AppError.missingAPIKey
        }

        let url = URL(string: "https://api.openai.com/v1/responses")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            TextResponseRequest(
                model: "gpt-4.1-nano",
                instructions: TransformPromptBuilder.instructions(for: invocation),
                input: text,
                maxOutputTokens: 4_096,
                store: false
            )
        )

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AppError.transformFailed("Invalid response.")
            }
            switch http.statusCode {
            case 200...299:
                do {
                    return try Self.decodeTransformResponse(data)
                } catch let error as AppError {
                    throw error
                } catch {
                    throw AppError.transformFailed("Invalid response.")
                }
            case 401:
                throw AppError.unauthorized
            case 403:
                throw AppError.forbidden
            default:
                let message = parseAPIErrorMessage(data: data)
                throw AppError.transformFailed(message ?? "HTTP \(http.statusCode)")
            }
        } catch let error as AppError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AppError.network(error.localizedDescription)
        }
    }

    static func decodeTransformResponse(_ data: Data) throws -> TransformGenerationResult {
        let response = try decodeTextResponse(
            data,
            emptyError: .transformReturnedNoText,
            failure: AppError.transformFailed
        )
        return TransformGenerationResult(
            text: response.text,
            inputTokens: response.inputTokens,
            outputTokens: response.outputTokens
        )
    }

    func executeCommand(_ command: CommandModeRequest) async throws -> CommandGenerationResult {
        guard let apiKey = try keychain.loadAPIKey(), !apiKey.isEmpty else {
            throw AppError.missingAPIKey
        }

        let url = URL(string: "https://api.openai.com/v1/responses")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            TextResponseRequest(
                model: "gpt-4.1-nano",
                instructions: CommandModePromptBuilder.instructions(
                    hasSelection: command.selectedText != nil
                ),
                input: try CommandModePromptBuilder.input(for: command),
                maxOutputTokens: 4_096,
                store: false
            )
        )

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AppError.commandFailed("Invalid response.")
            }
            switch http.statusCode {
            case 200...299:
                return try Self.decodeCommandResponse(data)
            case 401:
                throw AppError.unauthorized
            case 403:
                throw AppError.forbidden
            default:
                let message = parseAPIErrorMessage(data: data)
                throw AppError.commandFailed(message ?? "HTTP \(http.statusCode)")
            }
        } catch let error as AppError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AppError.network(error.localizedDescription)
        }
    }

    static func decodeCommandResponse(_ data: Data) throws -> CommandGenerationResult {
        let response = try decodeTextResponse(
            data,
            emptyError: .commandReturnedNoText,
            failure: AppError.commandFailed
        )
        return CommandGenerationResult(
            text: response.text,
            inputTokens: response.inputTokens,
            outputTokens: response.outputTokens
        )
    }

    private static func decodeTextResponse(
        _ data: Data,
        emptyError: AppError,
        failure: (String) -> AppError
    ) throws -> DecodedTextResponse {
        let response = try JSONDecoder().decode(TransformResponseEnvelope.self, from: data)
        guard response.status == "completed" else {
            if let message = response.error?.message {
                throw failure(message)
            }
            let status = response.status ?? "unknown"
            throw failure(
                response.incompleteDetails?.reason
                    ?? "The model response ended with status \(status)."
            )
        }
        let text = response.output
            .filter { $0.type == "message" }
            .flatMap(\.content)
            .filter { $0.type == "output_text" }
            .compactMap(\.text)
            .joined()
        guard text.trimmedOrNil != nil else {
            if let refusal = response.output
                .filter({ $0.type == "message" })
                .flatMap(\.content)
                .compactMap(\.refusal)
                .first {
                throw failure(refusal)
            }
            throw emptyError
        }
        return DecodedTextResponse(
            text: text,
            inputTokens: response.usage?.inputTokens ?? 0,
            outputTokens: response.usage?.outputTokens ?? 0
        )
    }


    private func fileSizeBytes(for url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    private func parseAPIErrorMessage(data: Data) -> String? {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(OpenAIErrorEnvelope.self, from: data) {
            return envelope.error?.message
        }
        return nil
    }

    private func createMultipartBody(fileURL: URL, boundary: String, fields: [String: String]) throws -> Data {
        var body = Data()
        for (name, value) in fields {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }

        let filename = fileURL.lastPathComponent
        let fileData = try Data(contentsOf: fileURL)
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: \(Self.audioContentType(for: fileURL))\r\n\r\n")
        body.append(fileData)
        body.append("\r\n")
        body.append("--\(boundary)--\r\n")
        return body
    }
}

private struct OpenAIErrorEnvelope: Decodable {
    struct APIError: Decodable {
        let message: String?
    }
    let error: APIError?
}

private struct AudioTranscriptionResponse: Decodable {
    let text: String
}

private struct ChatCompletionRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }
        let message: Message
    }
    let choices: [Choice]
    let usage: Usage?

    struct Usage: Decodable {
        let promptTokens: Int
        let completionTokens: Int
        let totalTokens: Int?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
        }
    }
}

private struct TextResponseRequest: Encodable {
    let model: String
    let instructions: String
    let input: String
    let maxOutputTokens: Int
    let store: Bool

    enum CodingKeys: String, CodingKey {
        case model
        case instructions
        case input
        case maxOutputTokens = "max_output_tokens"
        case store
    }
}

private struct DecodedTextResponse {
    let text: String
    let inputTokens: Int
    let outputTokens: Int
}

private struct TransformResponseEnvelope: Decodable {
    struct OutputItem: Decodable {
        struct ContentItem: Decodable {
            let type: String
            let text: String?
            let refusal: String?
        }

        let type: String
        let content: [ContentItem]

        enum CodingKeys: String, CodingKey {
            case type
            case content
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decode(String.self, forKey: .type)
            content = try container.decodeIfPresent([ContentItem].self, forKey: .content) ?? []
        }
    }

    struct Usage: Decodable {
        let inputTokens: Int
        let outputTokens: Int

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }

    struct IncompleteDetails: Decodable {
        let reason: String?
    }

    struct ResponseError: Decodable {
        let message: String?
    }

    let output: [OutputItem]
    let usage: Usage?
    let status: String?
    let incompleteDetails: IncompleteDetails?
    let error: ResponseError?

    enum CodingKeys: String, CodingKey {
        case output
        case usage
        case status
        case incompleteDetails = "incomplete_details"
        case error
    }
}

struct PolishResult {
    let text: String
    let promptTokens: Int
    let completionTokens: Int
}


private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
