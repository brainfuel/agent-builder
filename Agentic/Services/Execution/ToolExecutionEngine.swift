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

    /// Fallback for key=value style args (no JSON object). Lazy `.*?` is
    /// safe here because `)]` won't appear inside a key=value pair.
    private static let toolCallKVPattern = try! NSRegularExpression(
        pattern: #"\[TOOL_CALL:\s*([A-Za-z0-9_.:-]+)\(([^{].*?)\)\]"#,
        options: [.dotMatchesLineSeparators]
    )

    /// Parses all tool calls from an LLM response.
    ///
    /// JSON-args calls (`[TOOL_CALL: name({...})]`) are extracted with a
    /// brace-counting scanner — a regex can't simultaneously handle nested
    /// braces AND multiple sequential calls in one response. The scanner
    /// finds each `[TOOL_CALL: name(` (or bare `[name(`) header, then walks
    /// the JSON literal counting `{`/`}` (string/escape aware) to find the
    /// matching `})]` for that call only.
    ///
    /// Key=value calls fall back to a lazy regex.
    func parseToolCalls(from text: String) -> [ToolCall] {
        var out: [ToolCall] = []
        out.append(contentsOf: scanJSONCalls(in: text, requirePrefix: true))

        // Key=value variant of [TOOL_CALL: …]. Only emit these for spans the
        // JSON scanner didn't already cover, so we don't double-extract.
        let kvNS = NSRange(text.startIndex..., in: text)
        for match in Self.toolCallKVPattern.matches(in: text, range: kvNS) {
            guard match.numberOfRanges == 3,
                  let nameRange = Range(match.range(at: 1), in: text),
                  let argsRange = Range(match.range(at: 2), in: text),
                  let fullRange = Range(match.range, in: text) else { continue }
            // Skip if we already extracted a JSON-args call covering this span.
            if out.contains(where: { $0.fullMatch.range(of: String(text[fullRange])) != nil }) { continue }
            out.append(ToolCall(
                name: String(text[nameRange]),
                arguments: String(text[argsRange]),
                fullMatch: String(text[fullRange])
            ))
        }

        if !out.isEmpty { return out }

        // Lenient: bare `[tool_name({...})]` — some models drop the
        // TOOL_CALL: prefix. Downstream `execute` rejects names not in
        // assignedTools, so stray bracketed text won't execute.
        return scanJSONCalls(in: text, requirePrefix: false)
    }

    /// Walk the response left-to-right pulling out `[TOOL_CALL: name({…})]`
    /// (or bare `[name({…})]` when `requirePrefix` is false). Brace counting
    /// is string/escape aware so JSON containing `}` inside a quoted value
    /// doesn't terminate the call early.
    private func scanJSONCalls(in text: String, requirePrefix: Bool) -> [ToolCall] {
        var out: [ToolCall] = []
        let chars = Array(text)
        let n = chars.count
        var i = 0
        let prefix = Array("[TOOL_CALL:")
        let identifierChars: Set<Character> = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.:-")

        outer: while i < n {
            let headerStart = i
            if requirePrefix {
                // Match literal "[TOOL_CALL:" followed by optional whitespace.
                guard i + prefix.count <= n, Array(chars[i..<i + prefix.count]) == prefix else {
                    i += 1; continue
                }
                i += prefix.count
                while i < n, chars[i].isWhitespace { i += 1 }
            } else {
                guard chars[i] == "[" else { i += 1; continue }
                i += 1
            }

            // Read tool name.
            let nameStart = i
            while i < n, identifierChars.contains(chars[i]) { i += 1 }
            let nameEnd = i
            guard nameEnd > nameStart, i < n, chars[i] == "(" else {
                i = headerStart + 1; continue
            }
            let name = String(chars[nameStart..<nameEnd])
            i += 1 // past '('
            guard i < n, chars[i] == "{" else {
                i = headerStart + 1; continue
            }

            // Brace-count to the matching '}'.
            let argsStart = i
            var depth = 0
            var inString = false
            var escape = false
            while i < n {
                let c = chars[i]
                if inString {
                    if escape { escape = false }
                    else if c == "\\" { escape = true }
                    else if c == "\"" { inString = false }
                } else {
                    if c == "\"" { inString = true }
                    else if c == "{" { depth += 1 }
                    else if c == "}" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                }
                i += 1
            }
            guard i < n, depth == 0 else { i = headerStart + 1; continue outer }
            let argsEnd = i + 1 // include closing '}'

            // Expect `)]` to follow.
            guard argsEnd + 1 < n, chars[argsEnd] == ")", chars[argsEnd + 1] == "]" else {
                i = headerStart + 1; continue
            }
            let args = String(chars[argsStart..<argsEnd])
            let fullEnd = argsEnd + 2
            let full = String(chars[headerStart..<fullEnd])
            out.append(ToolCall(name: name, arguments: args, fullMatch: full))
            i = fullEnd
        }
        return out
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
