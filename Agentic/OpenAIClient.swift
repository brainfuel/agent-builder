import Foundation

struct OpenAIClient: GeminiServicing {
    let apiKey: String
    private let explicitlyUnsupportedPrefixes: [String] = [
        "gpt-audio",
        "gpt-realtime",
        "gpt-4o-audio",
        "gpt-4o-mini-audio",
        "gpt-4o-mini-realtime",
        "gpt-4o-mini-search",
        "omni-moderation",
        "text-embedding",
        "tts-",
        "whisper-",
        "sora-",
        "computer-use-",
        "babbage-",
        "davinci-"
    ]

    func listGenerateContentModels() async throws -> [String] {
        guard let url = URL(string: "https://api.openai.com/v1/models") else {
            throw GeminiError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 25

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiError.invalidResponse
        }
        if !(200...299).contains(http.statusCode) {
            if let apiError = try? JSONDecoder().decode(OpenAIErrorEnvelope.self, from: data) {
                throw GeminiError.api(apiError.error.message)
            }
            throw GeminiError.api("Model list request failed with status \(http.statusCode).")
        }

        let decoded = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
        let supported = decoded.data
            .map(\.id)
            .filter { modelKind(for: $0) != .unsupported }
        return Array(Set(supported)).sorted()
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
                    switch modelKind(for: modelID) {
                    case .imageGeneration:
                        let reply = try await generateImageReply(modelID: modelID, messages: messages)
                        continuation.yield(reply)
                        continuation.finish()
                    case .chatText:
                        try await streamChatReply(
                            modelID: modelID,
                            systemInstruction: systemInstruction,
                            messages: messages,
                            latestUserAttachments: latestUserAttachments,
                            continuation: continuation
                        )
                    case .unsupported:
                        throw GeminiError.api("Model '\(modelID)' is not supported by this app yet.")
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func streamChatReply(
        modelID: String,
        systemInstruction: String,
        messages: [ChatMessage],
        latestUserAttachments: [PendingAttachment],
        continuation: AsyncThrowingStream<ModelReply, Error>.Continuation
    ) async throws {
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw GeminiError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        request.httpBody = try makeChatRequestBody(
            modelID: modelID,
            systemInstruction: systemInstruction,
            messages: messages,
            latestUserAttachments: latestUserAttachments
        )

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiError.invalidResponse
        }

        if !(200...299).contains(http.statusCode) {
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
                if errorData.count > 4096 { break }
            }
            if let apiError = try? JSONDecoder().decode(OpenAIErrorEnvelope.self, from: errorData) {
                throw GeminiError.api(apiError.error.message)
            }
            throw GeminiError.api("Request failed with status \(http.statusCode).")
        }

        var yieldedAnything = false
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6))
            guard jsonString != "[DONE]" else { break }
            guard let data = jsonString.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(OpenAIStreamChunk.self, from: data) else {
                continue
            }
            let content = chunk.choices.first?.delta.content ?? ""
            let inputTokens = chunk.usage?.promptTokens ?? 0
            let outputTokens = chunk.usage?.completionTokens ?? 0
            if !content.isEmpty || inputTokens > 0 || outputTokens > 0 {
                continuation.yield(ModelReply(
                    text: content,
                    generatedMedia: [],
                    inputTokens: inputTokens,
                    outputTokens: outputTokens
                ))
                if !content.isEmpty { yieldedAnything = true }
            }
        }

        if !yieldedAnything {
            throw GeminiError.emptyReply
        }
        continuation.finish()
    }

    func makeChatRequestBody(
        modelID: String,
        systemInstruction: String,
        messages: [ChatMessage],
        latestUserAttachments: [PendingAttachment]
    ) throws -> Data {
        let payload = OpenAIChatStreamRequest(
            model: modelID,
            messages: buildChatPayloadMessages(
                systemInstruction: systemInstruction,
                messages: messages,
                latestUserAttachments: latestUserAttachments
            )
        )
        return try JSONEncoder().encode(payload)
    }

    private func buildChatPayloadMessages(
        systemInstruction: String,
        messages: [ChatMessage],
        latestUserAttachments: [PendingAttachment]
    ) -> [OpenAIChatMessage] {
        var payloadMessages: [OpenAIChatMessage] = []

        if !systemInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payloadMessages.append(OpenAIChatMessage(role: "system", content: systemInstruction))
        }

        let lastUserIndex = messages.lastIndex { $0.role == .user }
        for (index, message) in messages.enumerated() {
            let role = message.role == .assistant ? "assistant" : "user"
            guard let lastUserIndex,
                  index == lastUserIndex,
                  !latestUserAttachments.isEmpty else {
                payloadMessages.append(OpenAIChatMessage(role: role, content: message.text))
                continue
            }

            var parts: [OpenAIChatContentPart] = []
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                parts.append(OpenAIChatContentPart(text: message.text))
            }

            let imageAttachments = latestUserAttachments.filter {
                $0.mimeType.hasPrefix("image/") && !$0.base64Data.isEmpty
            }
            parts.append(contentsOf: imageAttachments.map { attachment in
                OpenAIChatContentPart(imageDataURL: "data:\(attachment.mimeType);base64,\(attachment.base64Data)")
            })

            let unsupportedCount = latestUserAttachments.count - imageAttachments.count
            if unsupportedCount > 0 {
                parts.append(
                    OpenAIChatContentPart(
                        text: "Note: \(unsupportedCount) non-image attachment(s) were skipped for ChatGPT in this app."
                    )
                )
            }

            if parts.isEmpty {
                parts.append(OpenAIChatContentPart(text: "(Attachment only)"))
            }

            payloadMessages.append(OpenAIChatMessage(role: role, contentParts: parts))
        }

        if lastUserIndex == nil, !latestUserAttachments.isEmpty {
            let parts = latestUserAttachments
                .filter { $0.mimeType.hasPrefix("image/") && !$0.base64Data.isEmpty }
                .map { attachment in
                    OpenAIChatContentPart(imageDataURL: "data:\(attachment.mimeType);base64,\(attachment.base64Data)")
                }

            if parts.isEmpty {
                payloadMessages.append(OpenAIChatMessage(role: "user", content: "(Attachment only)"))
            } else {
                payloadMessages.append(OpenAIChatMessage(role: "user", contentParts: parts))
            }
        }

        return payloadMessages
    }

    private func generateImageReply(modelID: String, messages: [ChatMessage]) async throws -> ModelReply {
        guard let prompt = messages.last(where: { $0.role == .user })?.text.trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty else {
            throw GeminiError.api("Image generation requires a user prompt.")
        }

        guard let url = URL(string: "https://api.openai.com/v1/images/generations") else {
            throw GeminiError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        let payload = OpenAIImageRequest(model: modelID, prompt: prompt)
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiError.invalidResponse
        }
        if !(200...299).contains(http.statusCode) {
            if let apiError = try? JSONDecoder().decode(OpenAIErrorEnvelope.self, from: data) {
                throw GeminiError.api(apiError.error.message)
            }
            throw GeminiError.api("Image request failed with status \(http.statusCode).")
        }

        let decoded = try JSONDecoder().decode(OpenAIImageResponse.self, from: data)
        let media = decoded.data.compactMap { item -> GeneratedMedia? in
            if let b64 = item.base64JSON, !b64.isEmpty {
                return GeneratedMedia(kind: .image, mimeType: "image/png", base64Data: b64)
            }
            if let urlString = item.url, let remoteURL = URL(string: urlString) {
                return GeneratedMedia(kind: .image, mimeType: "image/png", remoteURL: remoteURL)
            }
            return nil
        }

        if media.isEmpty {
            throw GeminiError.emptyReply
        }

        return ModelReply(text: "", generatedMedia: media)
    }

    private func modelKind(for modelID: String) -> OpenAIModelKind {
        if explicitlyUnsupportedPrefixes.contains(where: { modelID.hasPrefix($0) }) {
            return .unsupported
        }

        if modelID.hasPrefix("gpt-image-") || modelID.hasPrefix("dall-e-") || modelID == "chatgpt-image-latest" {
            return .imageGeneration
        }

        if modelID.hasPrefix("gpt-") || modelID.hasPrefix("o1") || modelID.hasPrefix("o3") || modelID.hasPrefix("o4") {
            return .chatText
        }

        return .unsupported
    }
}

private enum OpenAIModelKind {
    case chatText
    case imageGeneration
    case unsupported
}

private struct OpenAIModelsResponse: Decodable {
    let data: [OpenAIModel]
}

private struct OpenAIModel: Decodable {
    let id: String
}

private struct OpenAIChatStreamRequest: Encodable {
    let model: String
    let messages: [OpenAIChatMessage]
    let stream: Bool = true
    let streamOptions: OpenAIStreamOptions = OpenAIStreamOptions()

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case stream
        case streamOptions = "stream_options"
    }
}

private struct OpenAIStreamOptions: Encodable {
    let includeUsage: Bool = true

    enum CodingKeys: String, CodingKey {
        case includeUsage = "include_usage"
    }
}

private struct OpenAIImageRequest: Encodable {
    let model: String
    let prompt: String
}

private struct OpenAIImageResponse: Decodable {
    let data: [OpenAIImageData]
}

private struct OpenAIImageData: Decodable {
    let url: String?
    let base64JSON: String?

    enum CodingKeys: String, CodingKey {
        case url
        case base64JSON = "b64_json"
    }
}

private struct OpenAIChatMessage: Encodable {
    let role: String
    private let contentValue: OpenAIChatContentValue

    init(role: String, content: String) {
        self.role = role
        self.contentValue = .text(content)
    }

    init(role: String, contentParts: [OpenAIChatContentPart]) {
        self.role = role
        self.contentValue = .parts(contentParts)
    }

    enum CodingKeys: String, CodingKey {
        case role
        case content
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        switch contentValue {
        case .text(let text):
            try container.encode(text, forKey: .content)
        case .parts(let parts):
            try container.encode(parts, forKey: .content)
        }
    }
}

private enum OpenAIChatContentValue {
    case text(String)
    case parts([OpenAIChatContentPart])
}

private struct OpenAIChatContentPart: Encodable {
    let type: String
    let text: String?
    let imageURL: OpenAIImageURLPart?

    init(text: String) {
        self.type = "text"
        self.text = text
        self.imageURL = nil
    }

    init(imageDataURL: String) {
        self.type = "image_url"
        self.text = nil
        self.imageURL = OpenAIImageURLPart(url: imageDataURL)
    }

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
    }
}

private struct OpenAIImageURLPart: Encodable {
    let url: String
}

private struct OpenAIStreamChunk: Decodable {
    let choices: [OpenAIStreamChoice]
    let usage: OpenAIUsage?
}

private struct OpenAIStreamChoice: Decodable {
    let delta: OpenAIStreamDelta
}

private struct OpenAIStreamDelta: Decodable {
    let content: String?
}

private struct OpenAIUsage: Decodable {
    let promptTokens: Int
    let completionTokens: Int

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
    }
}

private struct OpenAIErrorEnvelope: Decodable {
    let error: OpenAIErrorBody
}

private struct OpenAIErrorBody: Decodable {
    let message: String
}
