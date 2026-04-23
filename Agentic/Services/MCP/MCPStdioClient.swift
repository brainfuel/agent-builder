#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
import Darwin

// Expose the process environment (`char **environ`) to Swift via the
// documented `_NSGetEnviron()` helper.
@_silgen_name("_NSGetEnviron")
private func _NSGetEnviron() -> UnsafeMutablePointer<UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?>

private func environ() -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? {
    guard let p = _NSGetEnviron().pointee else { return nil }
    return UnsafeMutablePointer(p)
}

// MARK: - MCP Stdio Client (macOS only)

/// Client for connecting to a local MCP server launched as a subprocess.
/// Communicates via newline-delimited JSON-RPC over stdin/stdout.
///
/// Unavailable on iOS / visionOS: those platforms forbid spawning arbitrary
/// subprocesses from inside the app sandbox.
actor MCPStdioClient {
    private let command: String
    private let arguments: [String]
    private let serverConnectionID: UUID
    private var nextRequestID = 1

    init(command: String, arguments: [String], serverConnectionID: UUID) {
        self.command = command
        self.arguments = arguments
        self.serverConnectionID = serverConnectionID
        Self.ignoreSIGPIPEOnce()
    }

    /// Make sure SIGPIPE never takes the app down. Runs once per process.
    private static let _sigpipeInstall: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()
    private static func ignoreSIGPIPEOnce() { _ = _sigpipeInstall }

    // MARK: - Public API

    /// What a stdio server told us about itself during the handshake.
    struct ServerDiscovery {
        let tools: [MCPRemoteTool]
        /// The `instructions` string from the server's `initialize` response,
        /// if any. MCP servers typically put a one-paragraph description here.
        let instructions: String?
        /// The `serverInfo.name` string, if provided.
        let serverName: String?
    }

    func discoverTools() async throws -> [MCPRemoteTool] {
        try await discover().tools
    }

    /// Full handshake: runs `initialize` + `tools/list` and surfaces the
    /// server-side `instructions` and `serverInfo.name` from the handshake
    /// response so callers can display them in the UI.
    func discover() async throws -> ServerDiscovery {
        let session = try await openSession()
        defer { session.terminate() }
        let initResult = try await initialize(session: session)
        let tools = try await listTools(session: session)
        return ServerDiscovery(
            tools: tools,
            instructions: initResult.instructions,
            serverName: initResult.serverName
        )
    }

    func callTool(name: String, arguments: [String: AnyCodableValue]) async throws -> MCPToolCallResult {
        let session = try await openSession()
        defer { session.terminate() }
        try await initialize(session: session)

        let request = JSONRPCRequest(
            id: getNextID(),
            method: "tools/call",
            params: .toolsCall(ToolsCallParams(name: name, arguments: arguments))
        )
        let response = try await sendRequest(request, session: session)
        let parsed = try parseJSONRPCResponse(response)

        if let error = parsed.error {
            throw MCPClientError.toolCallFailed("\(error.message) (code: \(error.code))")
        }
        guard let result = parsed.result else {
            throw MCPClientError.invalidResponse("Missing result in tools/call response.")
        }

        let isError = result["isError"] as? Bool ?? false
        var contentText = ""
        if let contentArray = result["content"] as? [[String: Any]] {
            for item in contentArray {
                if let text = item["text"] as? String {
                    if !contentText.isEmpty { contentText += "\n" }
                    contentText += text
                }
            }
        }
        return MCPToolCallResult(content: contentText, isError: isError)
    }

    // MARK: - Session

    /// Bundles a running subprocess with its pipes and a ready line-reader.
    /// Uses `posix_spawn` directly rather than `Foundation.Process` because
    /// `NSTask` is unavailable on Mac Catalyst.
    private final class Session: @unchecked Sendable {
        let pid: pid_t
        let stdinHandle: FileHandle
        let stdoutReader: LineReader
        let stderrHandle: FileHandle
        private var terminated = false

        // Stderr is drained into this buffer so that if the child dies before
        // responding we can surface its diagnostic output in the thrown error.
        private let stderrLock = NSLock()
        private var stderrBuffer = Data()

        init(pid: pid_t, stdinHandle: FileHandle, stdoutReader: LineReader, stderrHandle: FileHandle) {
            self.pid = pid
            self.stdinHandle = stdinHandle
            self.stdoutReader = stdoutReader
            self.stderrHandle = stderrHandle
        }

        func appendStderr(_ data: Data) {
            stderrLock.lock(); defer { stderrLock.unlock() }
            // Cap so a chatty child can't balloon memory.
            if stderrBuffer.count < 16_384 {
                stderrBuffer.append(data.prefix(16_384 - stderrBuffer.count))
            }
        }

        func stderrSnapshot() -> String {
            stderrLock.lock(); defer { stderrLock.unlock() }
            return String(data: stderrBuffer, encoding: .utf8) ?? ""
        }

        /// Non-blocking exit check. Returns the exit status string (e.g.
        /// "exit 1", "signal 11") if the child has already died, else nil.
        func exitStatusIfDead() -> String? {
            var status: Int32 = 0
            let r = waitpid(pid, &status, WNOHANG)
            guard r == pid else { return nil }
            if (status & 0x7f) == 0 {
                return "exit \((status >> 8) & 0xff)"
            } else {
                return "signal \(status & 0x7f)"
            }
        }

        func terminate() {
            guard !terminated else { return }
            terminated = true
            try? stdinHandle.close()
            stdoutReader.close()
            stderrHandle.readabilityHandler = nil
            try? stderrHandle.close()
            // Best-effort SIGTERM then reap to avoid zombies.
            kill(pid, SIGTERM)
            var status: Int32 = 0
            _ = waitpid(pid, &status, 0)
        }
    }

    private func openSession() async throws -> Session {
        guard !command.isEmpty else {
            throw MCPClientError.connectionFailed("No command specified for stdio MCP server.")
        }
        guard FileManager.default.isExecutableFile(atPath: command) else {
            throw MCPClientError.connectionFailed("Executable not found or not executable: \(command)")
        }

        // Create three pipes: [0] = read end, [1] = write end.
        var inPipe = [Int32](repeating: -1, count: 2)
        var outPipe = [Int32](repeating: -1, count: 2)
        var errPipe = [Int32](repeating: -1, count: 2)
        guard pipe(&inPipe) == 0, pipe(&outPipe) == 0, pipe(&errPipe) == 0 else {
            // Clean up any pipes that were opened.
            for fd in inPipe + outPipe + errPipe where fd >= 0 { close(fd) }
            throw MCPClientError.connectionFailed("Failed to create pipes for stdio MCP server.")
        }

        var fileActions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        // Child: stdin ← inPipe[0], stdout → outPipe[1], stderr → errPipe[1].
        posix_spawn_file_actions_adddup2(&fileActions, inPipe[0], 0)
        posix_spawn_file_actions_adddup2(&fileActions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&fileActions, errPipe[1], 2)
        // Close the parent ends in the child.
        posix_spawn_file_actions_addclose(&fileActions, inPipe[1])
        posix_spawn_file_actions_addclose(&fileActions, outPipe[0])
        posix_spawn_file_actions_addclose(&fileActions, errPipe[0])
        // Also close the child-side originals after dup2.
        posix_spawn_file_actions_addclose(&fileActions, inPipe[0])
        posix_spawn_file_actions_addclose(&fileActions, outPipe[1])
        posix_spawn_file_actions_addclose(&fileActions, errPipe[1])

        // argv = [command, args..., NULL]
        let argvStrings = [command] + arguments
        let cArgs: [UnsafeMutablePointer<CChar>?] = argvStrings.map { strdup($0) } + [nil]
        defer { for p in cArgs where p != nil { free(p) } }

        // Build a sanitized environment. Under Mac Catalyst the host app runs
        // with DYLD_* / __CF_USER_TEXT_ENCODING-adjacent settings pointing into
        // /System/iOSSupport. A native macOS child that inherits those will
        // try to load iOS-flavored dylibs and die. Strip anything that would
        // leak iOS support paths into the child.
        let blockedPrefixes = [
            "DYLD_",
            "__XPC_DYLD_",
            "__XCODE_BUILT_PRODUCTS_DIR_PATHS",
            "__XPC_",
            "SIMULATOR_",
            "CFFIXED_USER_HOME"
        ]
        var envStrings: [String] = []
        for (k, v) in ProcessInfo.processInfo.environment {
            if blockedPrefixes.contains(where: { k.hasPrefix($0) }) { continue }
            envStrings.append("\(k)=\(v)")
        }
        // Ensure PATH exists in the child so helpers like `fastlane` resolve.
        if !envStrings.contains(where: { $0.hasPrefix("PATH=") }) {
            envStrings.append("PATH=/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin")
        }
        let cEnv: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) } + [nil]
        defer { for p in cEnv where p != nil { free(p) } }

        var pid: pid_t = 0
        let rc = command.withCString { cPath in
            cEnv.withUnsafeBufferPointer { envBuf in
                posix_spawn(&pid, cPath, &fileActions, nil, cArgs,
                            UnsafeMutablePointer(mutating: envBuf.baseAddress))
            }
        }
        if rc != 0 {
            for fd in inPipe + outPipe + errPipe where fd >= 0 { close(fd) }
            throw MCPClientError.connectionFailed("posix_spawn failed for \(command): code \(rc)")
        }

        // Close the child ends in our process.
        close(inPipe[0])
        close(outPipe[1])
        close(errPipe[1])

        // Prevent SIGPIPE on write() when the child dies — we want EPIPE instead.
        var on: Int32 = 1
        _ = fcntl(inPipe[1], F_SETNOSIGPIPE, on)

        let stdinHandle = FileHandle(fileDescriptor: inPipe[1], closeOnDealloc: true)
        let stdoutHandle = FileHandle(fileDescriptor: outPipe[0], closeOnDealloc: true)
        let stderrHandle = FileHandle(fileDescriptor: errPipe[0], closeOnDealloc: true)

        let session = Session(
            pid: pid,
            stdinHandle: stdinHandle,
            stdoutReader: LineReader(handle: stdoutHandle),
            stderrHandle: stderrHandle
        )

        // Drain stderr into the session buffer so we can include it in errors.
        stderrHandle.readabilityHandler = { [weak session] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            session?.appendStderr(chunk)
        }

        _ = on // silence unused-var if compiler optimizes it away
        return session
    }

    private struct InitializeResult {
        let instructions: String?
        let serverName: String?
    }

    private func initialize(session: Session) async throws -> InitializeResult {
        let request = JSONRPCRequest(
            id: getNextID(),
            method: "initialize",
            params: .initialize(InitializeParams())
        )
        let responseData = try await sendRequest(request, session: session)
        let parsed = try parseJSONRPCResponse(responseData)
        if let error = parsed.error {
            throw MCPClientError.initializationFailed(error.message)
        }

        // Pull out the two interesting fields from the result — `instructions`
        // is free-form text about what the server does; `serverInfo.name` is
        // the server's self-reported display name.
        var instructions: String? = nil
        var serverName: String? = nil
        if let result = parsed.result {
            if let s = result["instructions"] as? String,
               !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                instructions = s
            }
            if let info = result["serverInfo"] as? [String: Any],
               let name = info["name"] as? String,
               !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                serverName = name
            }
        }

        let notification = JSONRPCRequest(
            id: nil,
            method: "notifications/initialized",
            params: .empty
        )
        try writeMessage(notification, to: session)

        return InitializeResult(instructions: instructions, serverName: serverName)
    }

    private func listTools(session: Session) async throws -> [MCPRemoteTool] {
        var allTools: [MCPRemoteTool] = []
        var cursor: String? = nil

        repeat {
            let request = JSONRPCRequest(
                id: getNextID(),
                method: "tools/list",
                params: .toolsList(ToolsListParams(cursor: cursor))
            )
            let responseData = try await sendRequest(request, session: session)
            let parsed = try parseJSONRPCResponse(responseData)

            if let error = parsed.error {
                throw MCPClientError.invalidResponse(error.message)
            }
            guard let result = parsed.result else {
                throw MCPClientError.invalidResponse("Missing result in tools/list response.")
            }

            if let toolsArray = result["tools"] as? [[String: Any]] {
                for toolDict in toolsArray {
                    let name = toolDict["name"] as? String ?? ""
                    let title = toolDict["title"] as? String
                    let description = toolDict["description"] as? String
                    var inputSchema: MCPToolInputSchema?
                    if let schemaDict = toolDict["inputSchema"] as? [String: Any] {
                        inputSchema = parseToolInputSchema(schemaDict)
                    }
                    allTools.append(MCPRemoteTool(
                        name: name,
                        title: title,
                        description: description,
                        inputSchema: inputSchema,
                        serverConnectionID: serverConnectionID
                    ))
                }
            }
            cursor = result["nextCursor"] as? String
        } while cursor != nil

        return allTools
    }

    // MARK: - Wire

    private func sendRequest(_ rpcRequest: JSONRPCRequest, session: Session) async throws -> Data {
        try writeMessage(rpcRequest, to: session)

        // Read lines until we get one matching our request id. Skip unrelated
        // notifications (e.g. the server's own logging).
        let targetID = rpcRequest.id
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            guard let line = try await session.stdoutReader.nextLine(deadline: deadline) else {
                // Give stderr a moment to flush, then build a useful message.
                try? await Task.sleep(nanoseconds: 100_000_000)
                let status = session.exitStatusIfDead() ?? "still running"
                let stderr = session.stderrSnapshot().trimmingCharacters(in: .whitespacesAndNewlines)
                let detail = stderr.isEmpty ? "" : " stderr: \(stderr)"
                throw MCPClientError.connectionFailed(
                    "Stdio MCP server closed output stream without responding (\(status)).\(detail)"
                )
            }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let data = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            // Only accept a response whose id matches, or if the request itself has no id.
            if targetID == nil {
                return data
            }
            if let idValue = obj["id"] {
                if let intID = idValue as? Int, intID == targetID { return data }
                if let strID = idValue as? String, Int(strID) == targetID { return data }
            }
            // Otherwise it's a server notification; keep reading.
        }
        throw MCPClientError.connectionFailed("Timed out waiting for stdio MCP response.")
    }

    private func writeMessage(_ rpcRequest: JSONRPCRequest, to session: Session) throws {
        var body = try JSONEncoder().encode(rpcRequest)
        body.append(0x0A) // newline
        do {
            try session.stdinHandle.write(contentsOf: body)
        } catch {
            let status = session.exitStatusIfDead() ?? "still running"
            let stderr = session.stderrSnapshot().trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = stderr.isEmpty ? "" : " stderr: \(stderr)"
            throw MCPClientError.connectionFailed(
                "Failed to write to stdio MCP server (\(status)): \(error.localizedDescription).\(detail)"
            )
        }
    }

    private func parseJSONRPCResponse(_ data: Data) throws -> ParsedJSONRPCResponse {
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let object = raw as? [String: Any] else {
            throw MCPClientError.invalidResponse("JSON-RPC response is not a dictionary.")
        }
        let responseID: Int?
        if let intID = object["id"] as? Int {
            responseID = intID
        } else if let stringID = object["id"] as? String, let intID = Int(stringID) {
            responseID = intID
        } else {
            responseID = nil
        }
        let parsedError: ParsedJSONRPCError?
        if let errorObject = object["error"] as? [String: Any] {
            let code = errorObject["code"] as? Int ?? -1
            let message = (errorObject["message"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            parsedError = ParsedJSONRPCError(
                code: code,
                message: (message?.isEmpty == false) ? (message ?? "") : "Unknown error"
            )
        } else {
            parsedError = nil
        }
        return ParsedJSONRPCResponse(
            id: responseID,
            result: object["result"] as? [String: Any],
            error: parsedError
        )
    }

    private func parseToolInputSchema(_ schemaDict: [String: Any]) -> MCPToolInputSchema {
        let required = schemaDict["required"] as? [String]
        let properties: [String: MCPSchemaProperty]?
        if let propertyDict = schemaDict["properties"] as? [String: Any] {
            var mapped: [String: MCPSchemaProperty] = [:]
            for (name, rawValue) in propertyDict {
                guard let value = rawValue as? [String: Any] else { continue }
                mapped[name] = MCPSchemaProperty(
                    type: value["type"] as? String,
                    description: value["description"] as? String
                )
            }
            properties = mapped.isEmpty ? nil : mapped
        } else {
            properties = nil
        }
        return MCPToolInputSchema(
            type: schemaDict["type"] as? String,
            properties: properties,
            required: required
        )
    }

    private func getNextID() -> Int {
        let id = nextRequestID
        nextRequestID += 1
        return id
    }
}

// MARK: - Line-buffered reader

/// Reads UTF-8 line-delimited output from a `FileHandle`, buffering partial
/// lines across reads. Used to demux JSON-RPC messages from a long-lived
/// child process.
private final class LineReader: @unchecked Sendable {
    private let handle: FileHandle
    private var buffer = Data()
    private let queue = DispatchQueue(label: "agentic.mcp.stdio.linereader")
    private var pending: [CheckedContinuation<String?, Error>] = []
    private var closed = false

    init(handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [weak self] h in
            guard let self else { return }
            let chunk = h.availableData
            if chunk.isEmpty {
                self.finish()
            } else {
                self.ingest(chunk)
            }
        }
    }

    func nextLine(deadline: Date) async throws -> String? {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                if let line = self.takeLineLocked() {
                    cont.resume(returning: line)
                    return
                }
                if self.closed {
                    cont.resume(returning: nil)
                    return
                }
                self.pending.append(cont)
            }
        }
    }

    func close() {
        queue.async {
            guard !self.closed else { return }
            self.closed = true
            self.handle.readabilityHandler = nil
            let pending = self.pending
            self.pending.removeAll()
            for cont in pending { cont.resume(returning: nil) }
        }
    }

    private func ingest(_ data: Data) {
        queue.async {
            self.buffer.append(data)
            self.flushLines()
        }
    }

    private func finish() {
        queue.async {
            self.closed = true
            self.handle.readabilityHandler = nil
            // Emit any remaining buffer as a final line.
            if !self.buffer.isEmpty, let tail = String(data: self.buffer, encoding: .utf8) {
                self.buffer.removeAll()
                if !self.pending.isEmpty {
                    let cont = self.pending.removeFirst()
                    cont.resume(returning: tail)
                }
            }
            let pending = self.pending
            self.pending.removeAll()
            for cont in pending { cont.resume(returning: nil) }
        }
    }

    private func flushLines() {
        while !pending.isEmpty, let line = takeLineLocked() {
            let cont = pending.removeFirst()
            cont.resume(returning: line)
        }
    }

    private func takeLineLocked() -> String? {
        guard let newlineIdx = buffer.firstIndex(of: 0x0A) else { return nil }
        let lineData = buffer.subdata(in: buffer.startIndex..<newlineIdx)
        buffer.removeSubrange(buffer.startIndex...newlineIdx)
        return String(data: lineData, encoding: .utf8) ?? ""
    }
}
#endif
