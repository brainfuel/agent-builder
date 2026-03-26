import Foundation

protocol GeminiServicing {
    func listGenerateContentModels() async throws -> [String]
    func generateReplyStream(
        modelID: String,
        systemInstruction: String,
        messages: [ChatMessage],
        latestUserAttachments: [PendingAttachment],
        webSearchEnabled: Bool
    ) -> AsyncThrowingStream<ModelReply, Error>
}

extension GeminiServicing {
    /// Convenience overload so existing callers that don't need web search still compile.
    func generateReplyStream(
        modelID: String,
        systemInstruction: String,
        messages: [ChatMessage],
        latestUserAttachments: [PendingAttachment]
    ) -> AsyncThrowingStream<ModelReply, Error> {
        generateReplyStream(
            modelID: modelID,
            systemInstruction: systemInstruction,
            messages: messages,
            latestUserAttachments: latestUserAttachments,
            webSearchEnabled: false
        )
    }
}

struct GeminiClient: GeminiServicing {
    let apiKey: String

    private let transientNetworkErrorCodes: Set<Int> = [
        NSURLErrorNetworkConnectionLost,
        NSURLErrorTimedOut,
        NSURLErrorCannotFindHost,
        NSURLErrorCannotConnectToHost
    ]

    func listGenerateContentModels() async throws -> [String] {
        var collected: [String] = []
        var pageToken: String?

        repeat {
            var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models")
            components?.queryItems = [
                URLQueryItem(name: "pageSize", value: "50")
            ]
            if let token = pageToken, !token.isEmpty {
                components?.queryItems?.append(URLQueryItem(name: "pageToken", value: token))
            }
            guard let url = components?.url else {
                throw GeminiError.invalidRequest
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 25
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

            let (data, response) = try await performWithRetry(request: request, maxAttempts: 3)
            guard let http = response as? HTTPURLResponse else {
                throw GeminiError.invalidResponse
            }
            if !(200...299).contains(http.statusCode) {
                if let apiError = try? JSONDecoder().decode(GeminiAPIErrorEnvelope.self, from: data) {
                    throw GeminiError.api(apiError.error.message)
                }
                throw GeminiError.api("Model list request failed with status \(http.statusCode).")
            }

            let decoded = try JSONDecoder().decode(GeminiListModelsResponse.self, from: data)
            let pageModels: [String] = decoded.models.compactMap { model in
                guard model.supportedGenerationMethods.contains("generateContent") else { return nil }
                if model.name.hasPrefix("models/") {
                    return String(model.name.dropFirst("models/".count))
                }
                return model.name
            }
            collected.append(contentsOf: pageModels)
            pageToken = decoded.nextPageToken
        } while pageToken != nil && !(pageToken?.isEmpty ?? true)

        return Array(Set(collected)).sorted()
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
                    let reply = try await generateReply(
                        modelID: modelID,
                        systemInstruction: systemInstruction,
                        messages: messages,
                        latestUserAttachments: latestUserAttachments,
                        webSearchEnabled: webSearchEnabled
                    )
                    continuation.yield(reply)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func generateReply(
        modelID: String,
        systemInstruction: String,
        messages: [ChatMessage],
        latestUserAttachments: [PendingAttachment],
        webSearchEnabled: Bool = false
    ) async throws -> ModelReply {
        let escapedModel = modelID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? modelID
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(escapedModel):generateContent") else {
            throw GeminiError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 120

        let lastUserIndex = messages.lastIndex { $0.role == .user }
        let tools: [GeminiTool]? = webSearchEnabled ? [GeminiTool(googleSearch: GeminiGoogleSearch())] : nil
        let payload = GeminiGenerateRequest(
            contents: messages.enumerated().map { index, message in
                var parts = [GeminiPart(text: message.text)]
                if let lastUserIndex, index == lastUserIndex, !latestUserAttachments.isEmpty {
                    parts.append(contentsOf: latestUserAttachments.map { attachment in
                        GeminiPart(
                            text: nil,
                            inlineData: GeminiInlineData(
                                mimeType: attachment.mimeType,
                                data: attachment.base64Data
                            )
                        )
                    })
                }
                return GeminiContent(
                    role: message.role == .user ? "user" : "model",
                    parts: parts
                )
            },
            systemInstruction: systemInstruction.isEmpty ? nil : GeminiContent(
                role: "user",
                parts: [GeminiPart(text: systemInstruction)]
            ),
            generationConfig: GeminiGenerationConfig(
                responseModalities: preferredResponseModalities(for: modelID)
            ),
            tools: tools
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiError.invalidResponse
        }

        if !(200...299).contains(http.statusCode) {
            if let apiError = try? JSONDecoder().decode(GeminiAPIErrorEnvelope.self, from: data) {
                throw GeminiError.api(apiError.error.message)
            }
            if let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !raw.isEmpty {
                throw GeminiError.api(raw)
            }
            throw GeminiError.api("Request failed with status \(http.statusCode).")
        }

        let decoded = try JSONDecoder().decode(GeminiGenerateResponse.self, from: data)
        guard let parts = decoded.candidates.first?.content.parts else {
            throw GeminiError.emptyReply
        }

        let text = parts.compactMap(\.text).joined()
        let media = parts.compactMap { part -> GeneratedMedia? in
            if let inline = part.inlineData, !inline.data.isEmpty {
                return GeneratedMedia(
                    kind: mediaKind(for: inline.mimeType),
                    mimeType: inline.mimeType,
                    base64Data: inline.data
                )
            }
            if let file = part.fileData,
               !file.fileURI.isEmpty,
               let url = URL(string: file.fileURI) {
                return GeneratedMedia(
                    kind: mediaKind(for: file.mimeType),
                    mimeType: file.mimeType,
                    remoteURL: url
                )
            }
            return nil
        }

        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && media.isEmpty {
            throw GeminiError.emptyReply
        }

        return ModelReply(
            text: text,
            generatedMedia: media,
            inputTokens: decoded.usageMetadata?.promptTokenCount ?? 0,
            outputTokens: decoded.usageMetadata?.candidatesTokenCount ?? 0
        )
    }

    private func performWithRetry(request: URLRequest, maxAttempts: Int) async throws -> (Data, URLResponse) {
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                return try await URLSession.shared.data(for: request)
            } catch {
                lastError = error
                guard shouldRetry(error: error), attempt < maxAttempts else {
                    throw error
                }

                let delayNanos = UInt64(attempt) * 700_000_000
                try? await Task.sleep(nanoseconds: delayNanos)
            }
        }

        throw lastError ?? GeminiError.invalidResponse
    }

    private func shouldRetry(error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return transientNetworkErrorCodes.contains(urlError.errorCode)
    }

    private func preferredResponseModalities(for modelID: String) -> [String] {
        if supportsImageOutput(modelID: modelID) {
            return ["TEXT", "IMAGE"]
        }
        return ["TEXT"]
    }

    private func supportsImageOutput(modelID: String) -> Bool {
        let normalized = modelID.lowercased()
        return normalized.contains("image") || normalized.contains("nano-banana")
    }

    private func mediaKind(for mimeType: String) -> GeneratedMediaKind {
        if mimeType.hasPrefix("image/") { return .image }
        if mimeType.hasPrefix("audio/") { return .audio }
        if mimeType.hasPrefix("video/") { return .video }
        if mimeType == "application/pdf" { return .pdf }
        if mimeType == "application/json" { return .json }
        if mimeType == "text/csv" { return .csv }
        if mimeType.hasPrefix("text/") { return .text }
        return .file
    }
}

enum GeminiError: LocalizedError {
    case invalidRequest
    case invalidResponse
    case emptyReply
    case api(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "Invalid request configuration."
        case .invalidResponse: return "Invalid server response."
        case .emptyReply: return "No text returned by the model."
        case .api(let message): return message
        }
    }
}

struct GeminiGenerateRequest: Encodable {
    let contents: [GeminiContent]
    let systemInstruction: GeminiContent?
    let generationConfig: GeminiGenerationConfig?
    let tools: [GeminiTool]?

    enum CodingKeys: String, CodingKey {
        case contents
        case systemInstruction = "system_instruction"
        case generationConfig = "generation_config"
        case tools
    }
}

/// Wraps a single Gemini tool entry. Currently only Google Search grounding is supported.
struct GeminiTool: Encodable {
    let googleSearch: GeminiGoogleSearch?

    enum CodingKeys: String, CodingKey {
        case googleSearch = "google_search"
    }
}

/// Empty object – presence in the tools array enables Google Search grounding.
struct GeminiGoogleSearch: Encodable {}

struct GeminiGenerationConfig: Codable {
    let responseModalities: [String]

    enum CodingKeys: String, CodingKey {
        case responseModalities = "response_modalities"
    }
}

struct GeminiContent: Codable {
    let role: String
    let parts: [GeminiPart]
}

struct GeminiPart: Codable {
    let text: String?
    let inlineData: GeminiInlineData?
    let fileData: GeminiFileData?

    init(text: String? = nil, inlineData: GeminiInlineData? = nil, fileData: GeminiFileData? = nil) {
        self.text = text
        self.inlineData = inlineData
        self.fileData = fileData
    }

    enum CodingKeys: String, CodingKey {
        case text
        case inlineData = "inline_data"
        case inlineDataCamel = "inlineData"
        case fileData = "file_data"
        case fileDataCamel = "fileData"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        if let snake = try container.decodeIfPresent(GeminiInlineData.self, forKey: .inlineData) {
            inlineData = snake
        } else {
            inlineData = try container.decodeIfPresent(GeminiInlineData.self, forKey: .inlineDataCamel)
        }
        if let snake = try container.decodeIfPresent(GeminiFileData.self, forKey: .fileData) {
            fileData = snake
        } else {
            fileData = try container.decodeIfPresent(GeminiFileData.self, forKey: .fileDataCamel)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(inlineData, forKey: .inlineData)
        try container.encodeIfPresent(fileData, forKey: .fileData)
    }
}

struct GeminiInlineData: Codable {
    let mimeType: String
    let data: String

    init(mimeType: String, data: String) {
        self.mimeType = mimeType
        self.data = data
    }

    enum CodingKeys: String, CodingKey {
        case mimeType = "mime_type"
        case mimeTypeCamel = "mimeType"
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let snake = try container.decodeIfPresent(String.self, forKey: .mimeType)
        let camel = try container.decodeIfPresent(String.self, forKey: .mimeTypeCamel)
        mimeType = snake ?? camel ?? "application/octet-stream"
        data = try container.decode(String.self, forKey: .data)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mimeType, forKey: .mimeType)
        try container.encode(data, forKey: .data)
    }
}

struct GeminiFileData: Codable {
    let mimeType: String
    let fileURI: String

    init(mimeType: String, fileURI: String) {
        self.mimeType = mimeType
        self.fileURI = fileURI
    }

    enum CodingKeys: String, CodingKey {
        case mimeType = "mime_type"
        case mimeTypeCamel = "mimeType"
        case fileURI = "file_uri"
        case fileURICamel = "fileUri"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let snakeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        let camelType = try container.decodeIfPresent(String.self, forKey: .mimeTypeCamel)
        mimeType = snakeType ?? camelType ?? "application/octet-stream"

        let snakeURI = try container.decodeIfPresent(String.self, forKey: .fileURI)
        let camelURI = try container.decodeIfPresent(String.self, forKey: .fileURICamel)
        fileURI = snakeURI ?? camelURI ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mimeType, forKey: .mimeType)
        try container.encode(fileURI, forKey: .fileURI)
    }
}

struct GeminiGenerateResponse: Decodable {
    let candidates: [GeminiCandidate]
    let usageMetadata: GeminiUsageMetadata?
}

struct GeminiCandidate: Decodable {
    let content: GeminiContent
}

struct GeminiUsageMetadata: Decodable {
    let promptTokenCount: Int?
    let candidatesTokenCount: Int?
}

struct GeminiAPIErrorEnvelope: Decodable {
    let error: GeminiAPIError
}

struct GeminiAPIError: Decodable {
    let message: String
}

struct GeminiListModelsResponse: Decodable {
    let models: [GeminiModel]
    let nextPageToken: String?
}

struct GeminiModel: Decodable {
    let name: String
    let supportedGenerationMethods: [String]
}
