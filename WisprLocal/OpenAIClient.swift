import Foundation

final class OpenAIClient {
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

    func transcribe(fileURL: URL, language: String?) async throws -> String {
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

        var fields: [String: String] = [
            "model": "gpt-4o-mini-transcribe",
            "response_format": "text"
        ]
        if let language, !language.isEmpty {
            fields["language"] = language
        }

        request.httpBody = try createMultipartBody(fileURL: fileURL, boundary: boundary, fields: fields)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AppError.transcriptionFailed("Invalid response.")
            }

            switch http.statusCode {
            case 200...299:
                if let text = String(data: data, encoding: .utf8) {
                    return text.trimmingCharacters(in: .whitespacesAndNewlines)
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
        body.append("Content-Type: audio/wav\r\n\r\n")
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
