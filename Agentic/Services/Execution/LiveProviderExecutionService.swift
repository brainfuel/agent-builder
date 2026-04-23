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
    let assignedTools: [String]
    let assignedToolNames: [String]
    /// Schema descriptions for remote MCP tools, keyed by tool name.
    let remoteToolSchemas: [String: String]
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

struct LiveProviderExecutionResult {
    let text: String
    let inputTokens: Int
    let outputTokens: Int
    let modelID: String
    let systemPrompt: String
    let userPrompt: String
    let rawResponse: String
}

enum LiveProviderExecutionService {
    /// Shared status message for live UI updates during execution.
    @MainActor static var liveStatus: String = ""

    private enum Config {
        static let maxFinalTextLength = 16_000
        static let structuredOutputRetryGuidance = "Your response was not valid JSON. Respond with ONLY the raw JSON object — no markdown, no code fences, no explanation. Just the JSON."
    }

    private static let modelCacheLock = NSLock()
    private static var modelCache: [APIKeyProvider: String] = [:]

    static func execute(
        provider: APIKeyProvider,
        apiKey: String,
        request: LiveProviderTaskRequest,
        preferredModelID: String?
    ) async throws -> LiveProviderExecutionResult {
        let modelID = try await resolveModel(for: provider, apiKey: apiKey, preferredModelID: preferredModelID)
        let client = makeClient(for: provider, apiKey: apiKey)
        let systemPrompt = makeSystemPrompt(for: request)
        let userPrompt = makeUserPrompt(for: request)
        let webSearchEnabled = request.assignedTools.contains("web_search")
            || request.allowedPermissions.contains("webAccess") // backward compat

        let hasExecutableTools = request.assignedTools.contains(where: { $0 != "web_search" })
        let engine = ToolExecutionEngine.shared

        var messages: [ChatMessage] = [
            ChatMessage(role: .user, text: userPrompt, attachments: [])
        ]

        var finalOutput = ""
        var rawLLMOutput = ""
        var totalInputTokens = 0
        var totalOutputTokens = 0

        for iteration in 0..<(hasExecutableTools ? ToolExecutionEngine.maxIterations : 1) {
            await MainActor.run { Self.liveStatus = iteration == 0 ? "Generating response…" : "Re-prompting (turn \(iteration + 1))…" }
            let stream = client.generateReplyStream(
                modelID: modelID,
                systemInstruction: systemPrompt,
                messages: messages,
                latestUserAttachments: [],
                webSearchEnabled: webSearchEnabled
            )

            var combinedText = ""
            var sawText = false
            var chunkInputTokens = 0
            var chunkOutputTokens = 0

            do {
                for try await chunk in stream {
                    let text = chunk.text
                    if !text.isEmpty {
                        combinedText += text
                        sawText = true
                    }
                    // Track the latest token counts from this stream
                    if chunk.inputTokens > 0 { chunkInputTokens = chunk.inputTokens }
                    if chunk.outputTokens > 0 { chunkOutputTokens = chunk.outputTokens }
                }
            } catch {
                // Record partial usage before throwing
                totalInputTokens += chunkInputTokens
                totalOutputTokens += chunkOutputTokens
                UsageTracker.shared.record(provider: provider, modelID: modelID, inputTokens: totalInputTokens, outputTokens: totalOutputTokens)
                throw normalizedError(error)
            }

            totalInputTokens += chunkInputTokens
            totalOutputTokens += chunkOutputTokens

            // Capture raw LLM output for debugging
            if !combinedText.isEmpty {
                if rawLLMOutput.isEmpty {
                    rawLLMOutput = combinedText
                } else {
                    rawLLMOutput += "\n---\n" + combinedText
                }
            }

            let normalized = combinedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty || sawText else {
                if iteration == 0 { throw LiveProviderExecutionError.emptyResponse }
                break
            }

            // Check for tool calls in the response
            let toolCalls = engine.parseToolCalls(from: normalized)
            let declaredToolCall = normalized.contains("[TOOL_CALL:")
            if toolCalls.isEmpty || !hasExecutableTools {
                if hasExecutableTools && declaredToolCall {
                    messages.append(ChatMessage(role: .assistant, text: normalized, attachments: []))
                    messages.append(ChatMessage(
                        role: .user,
                        text: """
                        Your tool call could not be parsed.
                        Re-emit tool calls exactly in this format:
                        [TOOL_CALL: tool_name({"param1": "value1", "param2": "value2"})]
                        Arguments must be a valid JSON object. Use a tool name exactly as listed in Available tools.
                        """,
                        attachments: []
                    ))
                    continue
                }
                finalOutput = normalized
                break
            }

            // Execute each tool call and collect results
            var toolResultsText = ""
            for (i, call) in toolCalls.enumerated() {
                await MainActor.run { Self.liveStatus = "Calling tool \(i + 1)/\(toolCalls.count): \(call.name)…" }
                let result = await engine.execute(call, assignedTools: request.assignedTools)
                toolResultsText += "[TOOL_RESULT: \(call.name) → \(result.output)]\n"
            }

            // Append the assistant response and tool results for the next iteration
            messages.append(ChatMessage(role: .assistant, text: normalized, attachments: []))
            messages.append(ChatMessage(role: .user, text: "Tool results:\n\(toolResultsText)\nContinue your response incorporating the tool results above.", attachments: []))

            // If this is the last iteration, use what we have
            if iteration == ToolExecutionEngine.maxIterations - 1 {
                finalOutput = normalized + "\n" + toolResultsText
            }
        }

        var result = finalOutput.trimmingCharacters(in: .whitespacesAndNewlines)

        // Structured output enforcement: validate JSON and retry once if invalid
        let enforceJSON = request.assignedTools.contains("structured_output")
        if enforceJSON && !result.isEmpty {
            let cleaned = Self.stripCodeFences(result)
            if Self.isValidJSON(cleaned) {
                result = cleaned
            } else {
                // One retry: tell the LLM its output wasn't valid JSON
                messages.append(ChatMessage(role: .assistant, text: finalOutput, attachments: []))
                messages.append(
                    ChatMessage(
                        role: .user,
                        text: Config.structuredOutputRetryGuidance,
                        attachments: []
                    )
                )

                let retryStream = client.generateReplyStream(
                    modelID: modelID,
                    systemInstruction: systemPrompt,
                    messages: messages,
                    latestUserAttachments: [],
                    webSearchEnabled: false
                )
                var retryText = ""
                do {
                    for try await chunk in retryStream {
                        if !chunk.text.isEmpty { retryText += chunk.text }
                        if chunk.inputTokens > 0 { totalInputTokens += chunk.inputTokens }
                        if chunk.outputTokens > 0 { totalOutputTokens += chunk.outputTokens }
                    }
                } catch {
                    // Keep original output if retry fails
                }
                let retryCleaned = Self.stripCodeFences(retryText.trimmingCharacters(in: .whitespacesAndNewlines))
                if Self.isValidJSON(retryCleaned) {
                    result = retryCleaned
                }
                // If retry also fails, return original — best effort
            }
        }

        // Record token usage for cost tracking
        UsageTracker.shared.record(provider: provider, modelID: modelID, inputTokens: totalInputTokens, outputTokens: totalOutputTokens)
        await MainActor.run { Self.liveStatus = "" }

        let finalText = result.isEmpty ? "" : String(result.prefix(Config.maxFinalTextLength))
        return LiveProviderExecutionResult(
            text: finalText,
            inputTokens: totalInputTokens,
            outputTokens: totalOutputTokens,
            modelID: modelID,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            rawResponse: rawLLMOutput
        )
    }

    /// Strips markdown code fences (```json ... ```) that LLMs often wrap JSON in.
    private static func stripCodeFences(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            // Remove opening fence (with optional language tag)
            if let endOfFirstLine = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: endOfFirstLine)...])
            }
        }
        if s.hasSuffix("```") {
            s = String(s.dropLast(3))
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Checks whether a string is valid JSON (object or array).
    private static func isValidJSON(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
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

    static func makeSystemPrompt(for request: LiveProviderTaskRequest) -> String {
        var lines = [
            "You are \(request.roleContext) operating inside a coordinator-managed multi-agent workflow.",
            "Write actionable output, concise and decision-oriented."
        ]
        let enforceJSON = request.assignedTools.contains("structured_output")
        let hasExecutableRemoteTools = request.assignedTools.contains { $0 != "web_search" && $0 != "structured_output" && $0 != "human_review" }
        let desc = request.outputSchemaDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if enforceJSON {
            lines.append("Required output schema: \(request.requiredOutputSchema).")
            if !desc.isEmpty {
                lines.append("Your output MUST be ONLY valid JSON conforming to this format: \(desc)")
            } else {
                lines.append("Your output MUST be ONLY valid JSON matching the schema: \(request.requiredOutputSchema).")
            }
            lines.append("CRITICAL: Respond with ONLY the JSON object. No prose, no markdown, no code fences, no explanation before or after. Just the raw JSON.")
        } else if hasExecutableRemoteTools {
            // Tools are assigned — the node's purpose is to CALL a tool, not
            // to synthesize text matching an output schema. Mention the schema
            // only as a downstream hint so the tool result can be framed
            // appropriately, without pressuring the model toward prose.
            if !request.requiredOutputSchema.isEmpty {
                lines.append("Downstream output schema (for context only): \(request.requiredOutputSchema).")
            }
            if !desc.isEmpty {
                lines.append("Output format hint (for context): \(desc)")
            }
            lines.append("Your primary job is to call the appropriate tool from the list below. Do NOT fabricate output — call the tool and return its result.")
        } else {
            lines.append("Required output schema: \(request.requiredOutputSchema).")
            if !desc.isEmpty {
                lines.append("Your output MUST conform to this format: \(desc)")
            }
        }
        let executableTools = request.assignedTools.filter { $0 != "web_search" }
        if !executableTools.isEmpty {
            // Separate built-in tools from remote MCP tools
            let builtInToolIDs: Set<String> = ["structured_output", "human_review"]
            let builtInTools = executableTools.filter { builtInToolIDs.contains($0) }
            let remoteTools = executableTools.filter { !builtInToolIDs.contains($0) }

            // List all tool IDs (LLM must use these exact IDs in tool calls)
            lines.append("Available tools: \(executableTools.joined(separator: ", ")).")

            // Add schema descriptions for remote MCP tools
            if !remoteTools.isEmpty {
                var schemaBlock = "Remote tool schemas:"
                for toolID in remoteTools {
                    if let schema = request.remoteToolSchemas[toolID] {
                        schemaBlock += "\n" + schema
                    } else {
                        schemaBlock += "\n- \(toolID): (no schema available — use best guess for parameters)"
                    }
                }
                lines.append(schemaBlock)
            }

            lines.append("""
                To call a tool, use this exact format in your response:
                [TOOL_CALL: tool_name({"param1": "value1", "param2": "value2"})]
                Arguments MUST be a valid JSON object inside the parentheses.
                Use tool names exactly as listed above (the machine-readable ID, not the display name).
                ONLY use the parameters listed in each tool's schema above. Do NOT invent parameters (e.g. teamId, workspaceId, authToken) that aren't shown — tools that list no parameters take none; call them with {}.
                Tool results will be provided if you use a tool call. You may continue your response after receiving results.
                """)

            if !builtInTools.isEmpty {
                lines.append("Built-in tool examples:")
                if builtInTools.contains("structured_output") {
                    lines.append(#"[TOOL_CALL: structured_output({"result": "your data here"})]"#)
                }
                if builtInTools.contains("human_review") {
                    lines.append(#"[TOOL_CALL: human_review({"question": "Should we proceed?", "context": "details here"})]"#)
                }
            }
        } else if !request.assignedToolNames.isEmpty {
            lines.append("Available tools: \(request.assignedToolNames.joined(separator: ", ")).")
        }
        lines.append("If you are blocked or missing required data, start your response with 'BLOCKED:' and explain exactly what is missing.")
        return lines.joined(separator: "\n")
    }

    static func makeUserPrompt(for request: LiveProviderTaskRequest) -> String {
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

    static func makeClient(for provider: APIKeyProvider, apiKey: String) -> any GeminiServicing {
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
