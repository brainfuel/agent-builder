import Foundation

// MARK: - Tool Execution Engine

/// Lightweight local tool runtime for executing tool calls within agent responses.
/// Tools run in-process; no external servers or sandbox escapes.
final class ToolExecutionEngine {
    static let shared = ToolExecutionEngine()

    /// Persistent key-value memory that survives across tool calls within a run.
    private var memoryStore: [String: String] = [:]
    private let lock = NSLock()

    /// Maximum number of tool-call -> re-prompt iterations per packet.
    static let maxIterations = 5

    /// Regex matching `[TOOL_CALL: tool-name({...})]` (JSON args) or `[TOOL_CALL: tool-name(key="val")]`.
    /// The JSON variant uses a greedy match up to `})]` to handle nested braces.
    private static let toolCallJSONPattern = try! NSRegularExpression(
        pattern: #"\[TOOL_CALL:\s*([A-Za-z0-9_.:-]+)\((\{.*\})\)\]"#,
        options: [.dotMatchesLineSeparators]
    )
    /// Fallback for key=value style args.
    private static let toolCallKVPattern = try! NSRegularExpression(
        pattern: #"\[TOOL_CALL:\s*([A-Za-z0-9_.:-]+)\((.*?)\)\]"#,
        options: [.dotMatchesLineSeparators]
    )
    /// Lenient fallback: some models drop the `TOOL_CALL:` prefix and emit just
    /// `[tool_name({...})]`. We only parse the JSON-args form (too permissive
    /// otherwise) and downstream `execute` enforces that the name is in the
    /// node's assigned tools, so stray bracketed text can't be hijacked.
    private static let bareToolCallJSONPattern = try! NSRegularExpression(
        pattern: #"\[([A-Za-z0-9_.:-]+)\((\{.*\})\)\]"#,
        options: [.dotMatchesLineSeparators]
    )

    /// Parses all tool calls from an LLM response.
    /// Tries JSON argument format first `({...})`, then falls back to key=value format.
    /// If neither finds anything, tries the bare (missing `TOOL_CALL:` prefix) variants —
    /// some models drop the prefix and write `[tool_name({...})]` directly.
    func parseToolCalls(from text: String) -> [ToolCall] {
        let range = NSRange(text.startIndex..., in: text)

        func apply(_ pattern: NSRegularExpression) -> [ToolCall] {
            pattern.matches(in: text, range: range).compactMap { match -> ToolCall? in
                guard match.numberOfRanges == 3,
                      let nameRange = Range(match.range(at: 1), in: text),
                      let argsRange = Range(match.range(at: 2), in: text),
                      let fullRange = Range(match.range, in: text) else { return nil }
                return ToolCall(
                    name: String(text[nameRange]),
                    arguments: String(text[argsRange]),
                    fullMatch: String(text[fullRange])
                )
            }
        }

        // Preferred: [TOOL_CALL: …] with JSON args
        let jsonMatches = apply(Self.toolCallJSONPattern)
        if !jsonMatches.isEmpty { return jsonMatches }

        // Key=value variant of [TOOL_CALL: …]
        let kvMatches = apply(Self.toolCallKVPattern)
        if !kvMatches.isEmpty { return kvMatches }

        // Bare `[tool_name({...})]` with no TOOL_CALL prefix — some models
        // drop it. Downstream `execute` rejects names not in assignedTools,
        // so stray bracketed text won't execute.
        return apply(Self.bareToolCallJSONPattern)
    }

    /// Executes a single tool call and returns the result string.
    /// Handles both built-in tools (sync) and remote MCP tools (async).
    func execute(_ call: ToolCall, assignedTools: [String]) async -> ToolResult {
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
            return await executeRemoteTool(call)
        }
    }

    /// Attempts to execute a tool call on a connected MCP server.
    private func executeRemoteTool(_ call: ToolCall) async -> ToolResult {
        let manager = MCPServerManager.shared
        guard let serverConnectionID = manager.serverConnectionID(forToolName: call.name) else {
            return ToolResult(toolName: call.name, output: "Error: tool '\(call.name)' has no local or remote executor.", success: false)
        }

        do {
            let args = parseJSONArguments(call.arguments)
            let result = try await manager.callTool(
                name: call.name,
                arguments: args,
                onServerWithID: serverConnectionID
            )
            return ToolResult(toolName: call.name, output: result.content, success: !result.isError)
        } catch {
            return ToolResult(toolName: call.name, output: "MCP error: \(error.localizedDescription)", success: false)
        }
    }

    /// Parses tool call arguments as JSON, falling back to key=value parsing for compatibility.
    private func parseJSONArguments(_ args: String) -> [String: AnyCodableValue] {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }

        // Try JSON first
        if trimmed.hasPrefix("{"),
           let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json.mapValues { AnyCodableValue.from($0) }
        }

        // Fallback: convert key=value pairs to string values
        let kv = parseKeyValue(args)
        return kv.mapValues { AnyCodableValue.string($0) }
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
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }

        // Support JSON object arguments:
        // [TOOL_CALL: tool_name({"query":"test","page_size":3})]
        if trimmed.hasPrefix("{"),
           let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var jsonResult: [String: String] = [:]
            for (key, value) in json {
                switch value {
                case let string as String:
                    jsonResult[key] = string
                case let number as NSNumber:
                    jsonResult[key] = number.stringValue
                case is NSNull:
                    continue
                default:
                    if let nested = try? JSONSerialization.data(withJSONObject: value),
                       let nestedText = String(data: nested, encoding: .utf8) {
                        jsonResult[key] = nestedText
                    }
                }
            }
            if !jsonResult.isEmpty { return jsonResult }
        }

        var result: [String: String] = [:]
        let kvPattern = try! NSRegularExpression(
            pattern: #"([A-Za-z0-9_.:-]+)\s*[:=]\s*(?:\"((?:\\.|[^\"])*)\"|'((?:\\.|[^'])*)'|([^,\)]+))"#
        )
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        for match in kvPattern.matches(in: trimmed, range: range) {
            guard let keyRange = Range(match.range(at: 1), in: trimmed) else { continue }
            let key = String(trimmed[keyRange])
            let value: String? = {
                if let doubleQuoted = Range(match.range(at: 2), in: trimmed) {
                    return String(trimmed[doubleQuoted])
                        .replacingOccurrences(of: #"\""#, with: "\"")
                        .replacingOccurrences(of: #"\\\\"#, with: #"\"#)
                }
                if let singleQuoted = Range(match.range(at: 3), in: trimmed) {
                    return String(trimmed[singleQuoted])
                        .replacingOccurrences(of: #"\'"#, with: "'")
                        .replacingOccurrences(of: #"\\\\"#, with: #"\"#)
                }
                if let bare = Range(match.range(at: 4), in: trimmed) {
                    return String(trimmed[bare]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return nil
            }()
            if let value, !value.isEmpty {
                result[key] = value
            }
        }

        // Fallback for positional calls like:
        // [TOOL_CALL: notion-search("test")]
        if result.isEmpty {
            let positional = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            if !positional.isEmpty {
                result["query"] = positional
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
