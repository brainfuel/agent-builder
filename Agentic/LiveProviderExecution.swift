import Foundation

// MARK: - Tool Execution Engine

/// Lightweight local tool runtime for executing tool calls within agent responses.
/// Tools run in-process; no external servers or sandbox escapes.
final class ToolExecutionEngine {
    static let shared = ToolExecutionEngine()

    /// Persistent key-value memory that survives across tool calls within a run.
    private var memoryStore: [String: String] = [:]
    private let lock = NSLock()

    /// Maximum number of tool-call → re-prompt iterations per packet.
    static let maxIterations = 5

    /// Regex matching `[TOOL_CALL: tool_name("arg")]` or `[TOOL_CALL: tool_name(key=value)]`
    private static let toolCallPattern = try! NSRegularExpression(
        pattern: #"\[TOOL_CALL:\s*(\w+)\(([^)]*)\)\]"#,
        options: []
    )

    /// Parses all tool calls from an LLM response.
    func parseToolCalls(from text: String) -> [ToolCall] {
        let range = NSRange(text.startIndex..., in: text)
        return Self.toolCallPattern.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges == 3,
                  let nameRange = Range(match.range(at: 1), in: text),
                  let argsRange = Range(match.range(at: 2), in: text) else { return nil }
            let fullRange = Range(match.range, in: text)!
            return ToolCall(
                name: String(text[nameRange]),
                arguments: String(text[argsRange]),
                fullMatch: String(text[fullRange])
            )
        }
    }

    /// Executes a single tool call and returns the result string.
    /// Handles both built-in tools (sync) and remote MCP tools (async).
    func execute(_ call: ToolCall, assignedTools: [String], mcpConnections: [MCPServerConnection] = []) async -> ToolResult {
        guard assignedTools.contains(call.name) else {
            return ToolResult(toolName: call.name, output: "Error: tool '\(call.name)' is not assigned to this node.", success: false)
        }

        switch call.name {
        case "memory_store":
            return executeMemoryStore(call.arguments)
        case "memory_recall":
            return executeMemoryRecall(call.arguments)
        case "structured_output":
            return executeStructuredOutput(call.arguments)
        case "human_review":
            return ToolResult(toolName: call.name, output: "HUMAN_REVIEW_REQUESTED: \(call.arguments)", success: true)
        default:
            // Try remote MCP tool execution
            return await executeRemoteTool(call, mcpConnections: mcpConnections)
        }
    }

    /// Attempts to execute a tool call on a connected MCP server.
    private func executeRemoteTool(_ call: ToolCall, mcpConnections: [MCPServerConnection]) async -> ToolResult {
        // Find which server has this tool
        let manager = await MCPServerManager.shared
        let remoteTool = await manager.allRemoteTools.first(where: { $0.name == call.name })

        guard let remoteTool else {
            return ToolResult(toolName: call.name, output: "Error: tool '\(call.name)' has no local or remote executor.", success: false)
        }

        guard let connection = mcpConnections.first(where: { $0.id == remoteTool.serverConnectionID }) else {
            return ToolResult(toolName: call.name, output: "Error: MCP server for tool '\(call.name)' is not connected.", success: false)
        }

        do {
            let args = parseKeyValue(call.arguments)
            let result = try await manager.callTool(name: call.name, arguments: args, on: connection)
            return ToolResult(toolName: call.name, output: result.content, success: !result.isError)
        } catch {
            return ToolResult(toolName: call.name, output: "MCP error: \(error.localizedDescription)", success: false)
        }
    }

    /// Clears the memory store between workflow runs.
    func resetMemory() {
        lock.lock()
        defer { lock.unlock() }
        memoryStore.removeAll()
    }

    // MARK: - Tool Implementations

    private func executeMemoryStore(_ args: String) -> ToolResult {
        let parts = parseKeyValue(args)
        guard let key = parts["key"], let value = parts["value"] else {
            return ToolResult(toolName: "memory_store", output: "Error: requires key and value arguments (e.g., key=\"name\", value=\"data\").", success: false)
        }
        lock.lock()
        memoryStore[key] = value
        lock.unlock()
        return ToolResult(toolName: "memory_store", output: "Stored: \(key) = \(value)", success: true)
    }

    private func executeMemoryRecall(_ args: String) -> ToolResult {
        let key = args.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        let parts = parseKeyValue(args)
        let lookupKey = parts["key"] ?? key

        lock.lock()
        let value = memoryStore[lookupKey]
        lock.unlock()

        if let value {
            return ToolResult(toolName: "memory_recall", output: value, success: true)
        } else {
            return ToolResult(toolName: "memory_recall", output: "No value stored for key '\(lookupKey)'.", success: true)
        }
    }

    private func executeStructuredOutput(_ args: String) -> ToolResult {
        // Validates that the argument looks like JSON; passes it through.
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return ToolResult(toolName: "structured_output", output: trimmed, success: true)
        }
        return ToolResult(toolName: "structured_output", output: "Error: argument must be valid JSON.", success: false)
    }

    /// Parses `key="value", key2="value2"` style arguments.
    private func parseKeyValue(_ args: String) -> [String: String] {
        var result: [String: String] = [:]
        let kvPattern = try! NSRegularExpression(pattern: #"(\w+)\s*=\s*\"([^\"]*)\""#)
        let range = NSRange(args.startIndex..., in: args)
        for match in kvPattern.matches(in: args, range: range) {
            if let keyRange = Range(match.range(at: 1), in: args),
               let valRange = Range(match.range(at: 2), in: args) {
                result[String(args[keyRange])] = String(args[valRange])
            }
        }
        return result
    }
}

struct ToolCall {
    let name: String
    let arguments: String
    let fullMatch: String
}

struct ToolResult {
    let toolName: String
    let output: String
    let success: Bool
}

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
        let webSearchEnabled = request.assignedTools.contains("web_search")
            || request.allowedPermissions.contains("webAccess") // backward compat

        let hasExecutableTools = request.assignedTools.contains(where: { $0 != "web_search" })
        let engine = ToolExecutionEngine.shared

        var messages: [ChatMessage] = [
            ChatMessage(role: .user, text: userPrompt, attachments: [])
        ]

        var finalOutput = ""

        for iteration in 0..<(hasExecutableTools ? ToolExecutionEngine.maxIterations : 1) {
            let stream = client.generateReplyStream(
                modelID: modelID,
                systemInstruction: systemPrompt,
                messages: messages,
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
            guard !normalized.isEmpty || sawText else {
                if iteration == 0 { throw LiveProviderExecutionError.emptyResponse }
                break
            }

            // Check for tool calls in the response
            let toolCalls = engine.parseToolCalls(from: normalized)
            if toolCalls.isEmpty || !hasExecutableTools {
                finalOutput = normalized
                break
            }

            // Execute each tool call and collect results
            var toolResultsText = ""
            for call in toolCalls {
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
                messages.append(ChatMessage(role: .user, text: "Your response was not valid JSON. Respond with ONLY the raw JSON object — no markdown, no code fences, no explanation. Just the JSON.", attachments: []))

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

        return result.isEmpty ? "" : String(result.prefix(16000))
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

    private static func makeSystemPrompt(for request: LiveProviderTaskRequest) -> String {
        var lines = [
            "You are \(request.roleContext) operating inside a coordinator-managed multi-agent workflow.",
            "Write actionable output, concise and decision-oriented.",
            "Required output schema: \(request.requiredOutputSchema)."
        ]
        let enforceJSON = request.assignedTools.contains("structured_output")
        let desc = request.outputSchemaDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if enforceJSON {
            if !desc.isEmpty {
                lines.append("Your output MUST be ONLY valid JSON conforming to this format: \(desc)")
            } else {
                lines.append("Your output MUST be ONLY valid JSON matching the schema: \(request.requiredOutputSchema).")
            }
            lines.append("CRITICAL: Respond with ONLY the JSON object. No prose, no markdown, no code fences, no explanation before or after. Just the raw JSON.")
        } else if !desc.isEmpty {
            lines.append("Your output MUST conform to this format: \(desc)")
        }
        let executableTools = request.assignedTools.filter { $0 != "web_search" }
        if !executableTools.isEmpty {
            let toolNames = executableTools.compactMap { id -> String? in
                request.assignedToolNames.isEmpty ? id : nil
            }
            let displayNames = request.assignedToolNames.filter { name in
                name != "Web Search"
            }
            let names = displayNames.isEmpty ? executableTools : displayNames
            lines.append("Available tools: \(names.joined(separator: ", ")).")
            lines.append("""
                To call a tool, use this exact format in your response:
                [TOOL_CALL: structured_output({"key": "value"})]
                [TOOL_CALL: human_review(reason for review)]
                Tool results will be provided if you use a tool call. You may continue your response after receiving results.
                """)
        } else if !request.assignedToolNames.isEmpty {
            lines.append("Available tools: \(request.assignedToolNames.joined(separator: ", ")).")
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
