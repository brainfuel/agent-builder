import Foundation

struct GrokClient: GeminiServicing {
    let apiKey: String

    func listGenerateContentModels() async throws -> [String] {
        guard let url = URL(string: "https://api.x.ai/v1/models") else {
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
            if let apiError = try? JSONDecoder().decode(GrokErrorEnvelope.self, from: data) {
                throw GeminiError.api(apiError.error.message)
            }
            throw GeminiError.api("Model list request failed with status \(http.statusCode).")
        }

        let decoded = try JSONDecoder().decode(GrokModelsResponse.self, from: data)
        let uniqueSorted = Array(Set(decoded.data.map(\.id))).sorted()
        return uniqueSorted
    }

    func generateReplyStream(
        modelID: String,
        systemInstruction: String,
        messages: [ChatMessage],
        latestUserAttachments: [PendingAttachment],
        webSearchEnabled: Bool = false
    ) -> AsyncThrowingStream<ModelReply, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    if webSearchEnabled {
                        // Use the Responses API with native web_search tool.
                        let reply = try await fetchResponsesFallbackReply(
                            modelID: modelID,
                            systemInstruction: systemInstruction,
                            messages: messages,
                            latestUserAttachments: latestUserAttachments,
                            webSearchEnabled: true
                        )
                        continuation.yield(reply)
                        continuation.finish()
                    } else {
                        try await streamChatReply(
                            modelID: modelID,
                            systemInstruction: systemInstruction,
                            messages: messages,
                            latestUserAttachments: latestUserAttachments,
                            continuation: continuation
                        )
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
        guard let url = URL(string: "https://api.x.ai/v1/chat/completions") else {
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

            let hasImageAttachments = latestUserAttachments.contains(where: isSupportedImageAttachment)
            let shouldUseResponsesFallback =
                hasImageAttachments || requiresResponsesAPI(statusCode: http.statusCode, data: errorData)

            if shouldUseResponsesFallback {
                do {
                    let fallbackReply = try await fetchResponsesFallbackReply(
                        modelID: modelID,
                        systemInstruction: systemInstruction,
                        messages: messages,
                        latestUserAttachments: latestUserAttachments
                    )
                    continuation.yield(fallbackReply)
                    continuation.finish()
                    return
                } catch {
                    // Keep original chat-completions failure as the surfaced error below.
                }
            }
            throw makeAPIError(statusCode: http.statusCode, data: errorData, prefix: "Request failed with status")
        }

        var yieldedAnything = false
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6))
            guard jsonString != "[DONE]" else { break }
            guard let data = jsonString.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(GrokStreamChunk.self, from: data) else {
                continue
            }

            let content = chunk.choices.first?.delta.content ?? ""
            let inputTokens = chunk.usage?.promptTokens ?? 0
            let outputTokens = chunk.usage?.completionTokens ?? 0
            if !content.isEmpty || inputTokens > 0 || outputTokens > 0 {
                continuation.yield(
                    ModelReply(
                        text: content,
                        generatedMedia: [],
                        inputTokens: inputTokens,
                        outputTokens: outputTokens
                    )
                )
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
        let payload = GrokChatStreamRequest(
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
    ) -> [GrokChatMessage] {
        var payloadMessages: [GrokChatMessage] = []

        if !systemInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payloadMessages.append(GrokChatMessage(role: "system", content: systemInstruction))
        }

        let lastUserIndex = messages.lastIndex { $0.role == .user }
        for (index, message) in messages.enumerated() {
            let role = message.role == .assistant ? "assistant" : "user"
            guard let lastUserIndex,
                  index == lastUserIndex,
                  !latestUserAttachments.isEmpty else {
                payloadMessages.append(GrokChatMessage(role: role, content: message.text))
                continue
            }

            var parts: [GrokChatContentPart] = []
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                parts.append(GrokChatContentPart(text: message.text))
            }

            let imageAttachments = latestUserAttachments.filter(isSupportedImageAttachment)
            parts.append(contentsOf: imageAttachments.map { attachment in
                GrokChatContentPart(
                    imageDataURL: "data:\(attachment.mimeType);base64,\(attachment.base64Data)",
                    detail: "high"
                )
            })

            let unsupportedCount = latestUserAttachments.count - imageAttachments.count
            if unsupportedCount > 0 {
                parts.append(
                    GrokChatContentPart(
                        text: "Note: \(unsupportedCount) non-image attachment(s) were skipped for Grok in this app."
                    )
                )
            }

            if parts.isEmpty {
                parts.append(GrokChatContentPart(text: "(Attachment only)"))
            }

            payloadMessages.append(GrokChatMessage(role: role, contentParts: parts))
        }

        if lastUserIndex == nil, !latestUserAttachments.isEmpty {
            let parts = latestUserAttachments
                .filter(isSupportedImageAttachment)
                .map { attachment in
                    GrokChatContentPart(
                        imageDataURL: "data:\(attachment.mimeType);base64,\(attachment.base64Data)",
                        detail: "high"
                    )
                }

            if parts.isEmpty {
                payloadMessages.append(GrokChatMessage(role: "user", content: "(Attachment only)"))
            } else {
                payloadMessages.append(GrokChatMessage(role: "user", contentParts: parts))
            }
        }

        return payloadMessages
    }

    private func fetchResponsesFallbackReply(
        modelID: String,
        systemInstruction: String,
        messages: [ChatMessage],
        latestUserAttachments: [PendingAttachment],
        webSearchEnabled: Bool = false
    ) async throws -> ModelReply {
        guard let url = URL(string: "https://api.x.ai/v1/responses") else {
            throw GeminiError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try makeResponsesRequestBody(
            modelID: modelID,
            systemInstruction: systemInstruction,
            messages: messages,
            latestUserAttachments: latestUserAttachments,
            webSearchEnabled: webSearchEnabled
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw makeAPIError(statusCode: http.statusCode, data: data, prefix: "Responses fallback failed with status")
        }

        let decoded = try JSONDecoder().decode(GrokResponsesCreateResponse.self, from: data)
        let outputText = extractResponsesOutputText(from: decoded)
        guard !outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GeminiError.emptyReply
        }

        return ModelReply(
            text: outputText,
            generatedMedia: [],
            inputTokens: decoded.usage?.inputTokens ?? 0,
            outputTokens: decoded.usage?.outputTokens ?? 0
        )
    }

    private func makeResponsesRequestBody(
        modelID: String,
        systemInstruction: String,
        messages: [ChatMessage],
        latestUserAttachments: [PendingAttachment],
        webSearchEnabled: Bool = false
    ) throws -> Data {
        let tools: [GrokResponsesTool]? = webSearchEnabled ? [GrokResponsesTool(type: "web_search")] : nil
        let payload = GrokResponsesCreateRequest(
            model: modelID,
            input: buildResponsesInput(
                systemInstruction: systemInstruction,
                messages: messages,
                latestUserAttachments: latestUserAttachments
            ),
            tools: tools
        )
        return try JSONEncoder().encode(payload)
    }

    private func buildResponsesInput(
        systemInstruction: String,
        messages: [ChatMessage],
        latestUserAttachments: [PendingAttachment]
    ) -> [GrokResponsesInputMessage] {
        var inputMessages: [GrokResponsesInputMessage] = []

        let trimmedSystem = systemInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSystem.isEmpty {
            inputMessages.append(GrokResponsesInputMessage(role: "system", content: trimmedSystem))
        }

        let lastUserIndex = messages.lastIndex { $0.role == .user }
        for (index, message) in messages.enumerated() {
            let role = message.role == .assistant ? "assistant" : "user"
            guard let lastUserIndex,
                  index == lastUserIndex,
                  !latestUserAttachments.isEmpty else {
                inputMessages.append(GrokResponsesInputMessage(role: role, content: message.text))
                continue
            }

            var parts: [GrokResponsesInputPart] = []
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                parts.append(GrokResponsesInputPart(inputText: message.text))
            }

            let imageAttachments = latestUserAttachments.filter(isSupportedImageAttachment)
            parts.append(contentsOf: imageAttachments.map { attachment in
                GrokResponsesInputPart(
                    imageURL: "data:\(attachment.mimeType);base64,\(attachment.base64Data)",
                    detail: "high"
                )
            })

            let unsupportedCount = latestUserAttachments.count - imageAttachments.count
            if unsupportedCount > 0 {
                parts.append(
                    GrokResponsesInputPart(
                        inputText: "Note: \(unsupportedCount) non-image attachment(s) were skipped for Grok in this app."
                    )
                )
            }

            if parts.isEmpty {
                parts.append(GrokResponsesInputPart(inputText: "(Attachment only)"))
            }
            inputMessages.append(GrokResponsesInputMessage(role: role, contentParts: parts))
        }

        if lastUserIndex == nil, !latestUserAttachments.isEmpty {
            let imageParts = latestUserAttachments
                .filter(isSupportedImageAttachment)
                .map { attachment in
                    GrokResponsesInputPart(
                        imageURL: "data:\(attachment.mimeType);base64,\(attachment.base64Data)",
                        detail: "high"
                    )
                }

            if imageParts.isEmpty {
                inputMessages.append(GrokResponsesInputMessage(role: "user", content: "(Attachment only)"))
            } else {
                inputMessages.append(GrokResponsesInputMessage(role: "user", contentParts: imageParts))
            }
        }

        return inputMessages
    }

    private func extractResponsesOutputText(from response: GrokResponsesCreateResponse) -> String {
        if let outputText = response.outputText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !outputText.isEmpty {
            return outputText
        }

        return response.output?
            .flatMap { $0.content ?? [] }
            .compactMap { content in
                let text = content.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return text.isEmpty ? nil : text
            }
            .joined(separator: "\n") ?? ""
    }

    private func isSupportedImageAttachment(_ attachment: PendingAttachment) -> Bool {
        let mimeType = attachment.mimeType.lowercased()
        let isSupportedMimeType = mimeType == "image/jpeg" || mimeType == "image/jpg" || mimeType == "image/png"
        return isSupportedMimeType && !attachment.base64Data.isEmpty
    }

    private func requiresResponsesAPI(statusCode: Int, data: Data) -> Bool {
        guard statusCode == 400 || statusCode == 422 else { return false }
        let message: String
        if let apiError = try? JSONDecoder().decode(GrokErrorEnvelope.self, from: data) {
            message = apiError.error.message
        } else {
            message = String(data: data, encoding: .utf8) ?? ""
        }
        let normalized = message.lowercased()
        return normalized.contains("multi agent requests are not allowed on chat completions")
            || normalized.contains("not allowed on chat completions")
    }

    private func makeAPIError(statusCode: Int, data: Data, prefix: String) -> GeminiError {
        if let apiError = try? JSONDecoder().decode(GrokErrorEnvelope.self, from: data) {
            return .api(apiError.error.message)
        }
        if let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return .api(raw)
        }

        if statusCode == 429 {
            return .api("Request failed with status 429 (rate limit or quota exceeded).")
        }
        return .api("\(prefix) \(statusCode).")
    }
}

private struct GrokModelsResponse: Decodable {
    let data: [GrokModel]
}

private struct GrokModel: Decodable {
    let id: String
}

private struct GrokChatStreamRequest: Encodable {
    let model: String
    let messages: [GrokChatMessage]
    let stream: Bool = true
    let streamOptions: GrokStreamOptions = GrokStreamOptions()

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case stream
        case streamOptions = "stream_options"
    }
}

private struct GrokStreamOptions: Encodable {
    let includeUsage: Bool = true

    enum CodingKeys: String, CodingKey {
        case includeUsage = "include_usage"
    }
}

private struct GrokChatMessage: Encodable {
    let role: String
    private let contentValue: GrokChatContentValue

    init(role: String, content: String) {
        self.role = role
        self.contentValue = .text(content)
    }

    init(role: String, contentParts: [GrokChatContentPart]) {
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

private enum GrokChatContentValue {
    case text(String)
    case parts([GrokChatContentPart])
}

private struct GrokChatContentPart: Encodable {
    let type: String
    let text: String?
    let imageURL: GrokImageURLPart?

    init(text: String) {
        self.type = "text"
        self.text = text
        self.imageURL = nil
    }

    init(imageDataURL: String, detail: String = "high") {
        self.type = "image_url"
        self.text = nil
        self.imageURL = GrokImageURLPart(url: imageDataURL, detail: detail)
    }

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
    }
}

private struct GrokImageURLPart: Encodable {
    let url: String
    let detail: String?
}

private struct GrokStreamChunk: Decodable {
    let choices: [GrokStreamChoice]
    let usage: GrokUsage?
}

private struct GrokStreamChoice: Decodable {
    let delta: GrokStreamDelta
}

private struct GrokStreamDelta: Decodable {
    let content: String?
}

private struct GrokUsage: Decodable {
    let promptTokens: Int
    let completionTokens: Int

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
    }
}

private struct GrokErrorEnvelope: Decodable {
    let error: GrokErrorBody
}

private struct GrokErrorBody: Decodable {
    let message: String
}

private struct GrokResponsesCreateRequest: Encodable {
    let model: String
    let input: [GrokResponsesInputMessage]
    let tools: [GrokResponsesTool]?
}

/// Grok Responses API built-in tool. Use `type: "web_search"` for native web search.
private struct GrokResponsesTool: Encodable {
    let type: String
}

private struct GrokResponsesInputMessage: Encodable {
    let role: String
    private let contentValue: GrokResponsesInputContentValue

    init(role: String, content: String) {
        self.role = role
        self.contentValue = .text(content)
    }

    init(role: String, contentParts: [GrokResponsesInputPart]) {
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

private enum GrokResponsesInputContentValue {
    case text(String)
    case parts([GrokResponsesInputPart])
}

private struct GrokResponsesInputPart: Encodable {
    let type: String
    let text: String?
    let imageURL: String?
    let detail: String?

    init(inputText: String) {
        self.type = "input_text"
        self.text = inputText
        self.imageURL = nil
        self.detail = nil
    }

    init(imageURL: String, detail: String = "high") {
        self.type = "input_image"
        self.text = nil
        self.imageURL = imageURL
        self.detail = detail
    }

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
        case detail
    }
}

private struct GrokResponsesCreateResponse: Decodable {
    let outputText: String?
    let output: [GrokResponsesOutputItem]?
    let usage: GrokResponsesUsage?

    enum CodingKeys: String, CodingKey {
        case outputText = "output_text"
        case output
        case usage
    }
}

private struct GrokResponsesOutputItem: Decodable {
    let content: [GrokResponsesOutputContent]?
}

private struct GrokResponsesOutputContent: Decodable {
    let text: String?
}

private struct GrokResponsesUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}
