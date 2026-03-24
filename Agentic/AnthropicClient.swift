import Foundation

struct AnthropicClient: GeminiServicing {
    let apiKey: String
    private let apiVersion = "2023-06-01"

    func listGenerateContentModels() async throws -> [String] {
        guard let url = URL(string: "https://api.anthropic.com/v1/models") else {
            throw GeminiError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 25

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiError.invalidResponse
        }
        if !(200...299).contains(http.statusCode) {
            if let apiError = try? JSONDecoder().decode(AnthropicErrorEnvelope.self, from: data) {
                throw GeminiError.api(apiError.error.message)
            }
            throw GeminiError.api("Model list request failed with status \(http.statusCode).")
        }

        let decoded = try JSONDecoder().decode(AnthropicModelsResponse.self, from: data)
        return decoded.data.map(\.id)
    }

    func generateReplyStream(
        modelID: String,
        systemInstruction: String,
        messages: [ChatMessage],
        latestUserAttachments: [PendingAttachment]
    ) -> AsyncThrowingStream<ModelReply, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
                        throw GeminiError.invalidRequest
                    }

                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.timeoutInterval = 120

                    let payloadMessages = normalizedPayloadMessages(
                        from: messages,
                        latestUserAttachments: latestUserAttachments
                    )
                    guard !payloadMessages.isEmpty else {
                        throw GeminiError.api("Cannot send an empty conversation to Anthropic.")
                    }

                    let payload = AnthropicMessagesRequest(
                        model: modelID,
                        maxTokens: 1024,
                        system: systemInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : systemInstruction,
                        messages: payloadMessages
                    )
                    request.httpBody = try JSONEncoder().encode(payload)

                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw GeminiError.invalidResponse
                    }

                    if !(200...299).contains(http.statusCode) {
                        if let apiError = try? JSONDecoder().decode(AnthropicErrorEnvelope.self, from: data) {
                            throw GeminiError.api(apiError.error.message)
                        }
                        if let raw = String(data: data, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                           !raw.isEmpty {
                            throw GeminiError.api(raw)
                        }
                        throw GeminiError.api("Anthropic request failed with status \(http.statusCode).")
                    }

                    let decoded = try JSONDecoder().decode(AnthropicMessagesResponse.self, from: data)
                    let responseText = decoded.content.compactMap(\.text).joined()
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if responseText.isEmpty {
                        throw GeminiError.emptyReply
                    }

                    continuation.yield(
                        ModelReply(
                            text: responseText,
                            generatedMedia: [],
                            inputTokens: decoded.usage?.inputTokens ?? 0,
                            outputTokens: decoded.usage?.outputTokens ?? 0
                        )
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func normalizedPayloadMessages(
        from messages: [ChatMessage],
        latestUserAttachments: [PendingAttachment]
    ) -> [AnthropicMessage] {
        var collapsed: [(role: String, text: String)] = []

        for message in messages {
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let role = message.role == .assistant ? "assistant" : "user"
            if let last = collapsed.last, last.role == role {
                collapsed[collapsed.count - 1].text += "\n\n\(text)"
            } else {
                collapsed.append((role: role, text: text))
            }
        }

        var payloadMessages = collapsed.map { pair in
            AnthropicMessage(role: pair.role, content: [.text(pair.text)])
        }

        guard !latestUserAttachments.isEmpty else {
            return payloadMessages
        }

        let imageBlocks = latestUserAttachments.compactMap(makeImageBlock)
        let unsupportedCount = latestUserAttachments.count - imageBlocks.count
        let unsupportedNote: AnthropicContentBlock? = unsupportedCount > 0
            ? .text("Note: \(unsupportedCount) attachment(s) were skipped because Anthropic currently only supports image attachments in this app.")
            : nil

        var attachmentBlocks = imageBlocks
        if let unsupportedNote {
            attachmentBlocks.append(unsupportedNote)
        }

        guard !attachmentBlocks.isEmpty else {
            return payloadMessages
        }

        if let lastUserIndex = payloadMessages.lastIndex(where: { $0.role == "user" }) {
            payloadMessages[lastUserIndex].content.append(contentsOf: attachmentBlocks)
        } else {
            payloadMessages.append(
                AnthropicMessage(role: "user", content: attachmentBlocks)
            )
        }

        return payloadMessages
    }

    private func makeImageBlock(from attachment: PendingAttachment) -> AnthropicContentBlock? {
        guard attachment.mimeType.hasPrefix("image/"), !attachment.base64Data.isEmpty else {
            return nil
        }
        return .image(
            AnthropicImageSource(
                type: "base64",
                mediaType: attachment.mimeType,
                data: attachment.base64Data
            )
        )
    }
}

private struct AnthropicModelsResponse: Decodable {
    let data: [AnthropicModel]
}

private struct AnthropicModel: Decodable {
    let id: String
}

private struct AnthropicMessagesRequest: Encodable {
    let model: String
    let maxTokens: Int
    let system: String?
    let messages: [AnthropicMessage]

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
    }
}

private struct AnthropicMessage: Codable {
    let role: String
    var content: [AnthropicContentBlock]
}

private enum AnthropicContentBlock: Codable {
    case text(String)
    case image(AnthropicImageSource)

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case source
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try container.decode(String.self, forKey: .text))
        case "image":
            if let source = try container.decodeIfPresent(AnthropicImageSource.self, forKey: .source) {
                self = .image(source)
            } else {
                self = .text("")
            }
        default:
            self = .text("")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try container.encode("text", forKey: .type)
            try container.encode(value, forKey: .text)
        case .image(let source):
            try container.encode("image", forKey: .type)
            try container.encode(source, forKey: .source)
        }
    }
}

private struct AnthropicImageSource: Codable {
    let type: String
    let mediaType: String
    let data: String

    enum CodingKeys: String, CodingKey {
        case type
        case mediaType = "media_type"
        case data
    }
}

private struct AnthropicMessagesResponse: Decodable {
    let content: [AnthropicResponseContentBlock]
    let usage: AnthropicUsage?
}

private struct AnthropicResponseContentBlock: Decodable {
    let type: String
    let text: String?
}

private struct AnthropicUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

private struct AnthropicErrorEnvelope: Decodable {
    let error: AnthropicErrorBody
}

private struct AnthropicErrorBody: Decodable {
    let message: String
}
