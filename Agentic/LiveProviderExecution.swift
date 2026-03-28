import Foundation

struct LiveProviderTaskRequest {
    let goal: String
    let objective: String
    let roleContext: String
    let requiredInputSchema: String
    let requiredOutputSchema: String
    let outputSchemaDescription: String
    let handoffSummaries: [String]
    let allowedPermissions: [String]
}

enum LiveProviderExecutionError: LocalizedError {
    case emptyResponse
    case api(message: String)
    case missingModel(provider: APIKeyProvider)

    var errorDescription: String? {
        switch self {
        case .emptyResponse:
            return "The provider returned an empty response."
        case .api(let message):
            return message
        case .missingModel(let provider):
            return "No compatible model was found for \(provider.label)."
        }
    }
}

enum LiveProviderExecutionService {
    private static let modelCacheLock = NSLock()
    private static var modelCache: [APIKeyProvider: String] = [:]

    static func execute(
        provider: APIKeyProvider,
        apiKey: String,
        request: LiveProviderTaskRequest,
        preferredModelID: String?
    ) async throws -> String {
        let modelID = try await resolveModel(for: provider, apiKey: apiKey, preferredModelID: preferredModelID)
        let client = makeClient(for: provider, apiKey: apiKey)
        let systemPrompt = makeSystemPrompt(for: request)
        let userPrompt = makeUserPrompt(for: request)
        let webSearchEnabled = request.allowedPermissions.contains("webAccess")

        let stream = client.generateReplyStream(
            modelID: modelID,
            systemInstruction: systemPrompt,
            messages: [
                ChatMessage(
                    role: .user,
                    text: userPrompt,
                    attachments: []
                )
            ],
            latestUserAttachments: [],
            webSearchEnabled: webSearchEnabled
        )

        var combinedText = ""
        var sawText = false

        do {
            for try await chunk in stream {
                let text = chunk.text
                if !text.isEmpty {
                    combinedText += text
                    sawText = true
                }
            }
        } catch {
            throw normalizedError(error)
        }

        let normalized = combinedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.isEmpty {
            return String(normalized.prefix(16000))
        }

        if sawText {
            return ""
        }
        throw LiveProviderExecutionError.emptyResponse
    }

    /// Public access to model resolution for direct client usage.
    static func resolveModelPublic(
        for provider: APIKeyProvider,
        apiKey: String,
        preferredModelID: String?
    ) async throws -> String {
        try await resolveModel(for: provider, apiKey: apiKey, preferredModelID: preferredModelID)
    }

    /// Public access to client creation for direct usage.
    static func makeClientPublic(for provider: APIKeyProvider, apiKey: String) -> any GeminiServicing {
        makeClient(for: provider, apiKey: apiKey)
    }

    static func fetchModels(provider: APIKeyProvider, apiKey: String) async throws -> [String] {
        let client = makeClient(for: provider, apiKey: apiKey)
        do {
            return try await client.listGenerateContentModels()
        } catch {
            throw normalizedError(error)
        }
    }

    private static func makeSystemPrompt(for request: LiveProviderTaskRequest) -> String {
        var lines = [
            "You are \(request.roleContext) operating inside a coordinator-managed multi-agent workflow.",
            "Write actionable output, concise and decision-oriented.",
            "Required output schema: \(request.requiredOutputSchema)."
        ]
        let desc = request.outputSchemaDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !desc.isEmpty {
            lines.append("Your output MUST conform to this format: \(desc)")
        }
        lines.append("If you are blocked or missing required data, start your response with 'BLOCKED:' and explain exactly what is missing.")
        return lines.joined(separator: "\n")
    }

    private static func makeUserPrompt(for request: LiveProviderTaskRequest) -> String {
        let handoffText: String
        if request.handoffSummaries.isEmpty {
            handoffText = "- (none)"
        } else {
            handoffText = request.handoffSummaries.map { "- \($0)" }.joined(separator: "\n")
        }

        let permissions = request.allowedPermissions.isEmpty
            ? "(none)"
            : request.allowedPermissions.sorted().joined(separator: ", ")

        return [
            "Global goal: \(request.goal)",
            "Task objective: \(request.objective)",
            "Expected input schema: \(request.requiredInputSchema)",
            "Expected output schema: \(request.requiredOutputSchema)",
            "Allowed permissions: \(permissions)",
            "Available handoffs:",
            handoffText
        ].joined(separator: "\n")
    }

    private static func resolveModel(
        for provider: APIKeyProvider,
        apiKey: String,
        preferredModelID: String?
    ) async throws -> String {
        if let cached = cachedModel(for: provider) {
            if let preferredModelID, preferredModelID != cached {
                cacheModel(preferredModelID, for: provider)
                return preferredModelID
            }
            return cached
        }

        let fetched = try await fetchModels(provider: provider, apiKey: apiKey)
        let sorted = Array(Set(fetched)).sorted()
        guard !sorted.isEmpty else {
            throw LiveProviderExecutionError.missingModel(provider: provider)
        }

        if let preferredModelID, sorted.contains(preferredModelID) {
            cacheModel(preferredModelID, for: provider)
            return preferredModelID
        }

        let preferredPrefixOrder: [String]
        switch provider {
        case .chatGPT:
            preferredPrefixOrder = ["gpt-4.1-mini", "gpt-4o-mini", "gpt-4.1", "gpt-4o", "o4-mini", "o3-mini"]
        case .gemini:
            preferredPrefixOrder = ["gemini-2.5-flash", "gemini-2.0-flash", "gemini-1.5-flash", "gemini-2.5-pro"]
        case .claude:
            preferredPrefixOrder = ["claude-3-7-sonnet", "claude-3-5-sonnet", "claude-3-5-haiku", "claude-3-haiku"]
        case .grok:
            preferredPrefixOrder = ["grok-4", "grok-3-mini", "grok-3", "grok-2"]
        }

        let chosen = preferredPrefixOrder.compactMap { prefix in
            sorted.first(where: { $0.hasPrefix(prefix) })
        }.first ?? sorted[0]

        cacheModel(chosen, for: provider)
        return chosen
    }

    private static func makeClient(for provider: APIKeyProvider, apiKey: String) -> any GeminiServicing {
        switch provider {
        case .chatGPT:
            return OpenAIClient(apiKey: apiKey)
        case .gemini:
            return GeminiClient(apiKey: apiKey)
        case .claude:
            return AnthropicClient(apiKey: apiKey)
        case .grok:
            return GrokClient(apiKey: apiKey)
        }
    }

    private static func normalizedError(_ error: Error) -> LiveProviderExecutionError {
        if let liveError = error as? LiveProviderExecutionError {
            return liveError
        }
        if let geminiError = error as? GeminiError {
            return .api(message: geminiError.errorDescription ?? "Provider request failed.")
        }
        return .api(message: error.localizedDescription)
    }

    private static func cachedModel(for provider: APIKeyProvider) -> String? {
        modelCacheLock.lock()
        defer { modelCacheLock.unlock() }
        return modelCache[provider]
    }

    private static func cacheModel(_ modelID: String, for provider: APIKeyProvider) {
        modelCacheLock.lock()
        defer { modelCacheLock.unlock() }
        modelCache[provider] = modelID
    }
}
