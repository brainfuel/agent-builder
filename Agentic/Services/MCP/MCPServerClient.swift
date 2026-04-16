import Foundation

// MARK: - MCP Server Client

/// Client for connecting to MCP servers over Streamable HTTP.
/// Supports both API key auth and OAuth 2.1.
actor MCPServerClient {
    private let serverURL: URL
    private let apiKey: String
    private var oauthToken: String?
    private let serverConnectionID: UUID
    private var sessionID: String?
    private var nextRequestID = 1
    private let session: URLSession

    init(url: URL, apiKey: String, serverConnectionID: UUID, oauthToken: String? = nil) {
        self.serverURL = url
        self.apiKey = apiKey
        self.oauthToken = oauthToken
        self.serverConnectionID = serverConnectionID
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    /// Sets the OAuth token for authenticated requests.
    func setOAuthToken(_ token: String) {
        self.oauthToken = token
    }

    // MARK: - Public API

    /// Connects to the MCP server, performs initialization handshake, and discovers tools.
    func discoverTools() async throws -> [MCPRemoteTool] {
        try await initialize()
        return try await listTools()
    }

    /// Calls a tool on the MCP server and returns the result.
    func callTool(name: String, arguments: [String: AnyCodableValue]) async throws -> MCPToolCallResult {
        let id = getNextID()
        let request = JSONRPCRequest(
            id: id,
            method: "tools/call",
            params: .toolsCall(ToolsCallParams(name: name, arguments: arguments))
        )

        let responseData = try await sendRequest(request)
        let parsed = try parseJSONRPCResponse(responseData)

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

    // MARK: - Private

    private func initialize() async throws {
        let id = getNextID()
        let request = JSONRPCRequest(
            id: id,
            method: "initialize",
            params: .initialize(InitializeParams())
        )

        let responseData = try await sendRequest(request)
        let parsed = try parseJSONRPCResponse(responseData)

        if let error = parsed.error {
            throw MCPClientError.initializationFailed(error.message)
        }

        let notification = JSONRPCRequest(
            id: nil,
            method: "notifications/initialized",
            params: .empty
        )
        _ = try? await sendRequest(notification, expectResponse: false)
    }

    private func listTools() async throws -> [MCPRemoteTool] {
        var allTools: [MCPRemoteTool] = []
        var cursor: String? = nil

        repeat {
            let id = getNextID()
            let request = JSONRPCRequest(
                id: id,
                method: "tools/list",
                params: .toolsList(ToolsListParams(cursor: cursor))
            )

            let responseData = try await sendRequest(request)
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

    private func sendRequest(_ rpcRequest: JSONRPCRequest, expectResponse: Bool = true) async throws -> Data {
        var urlRequest = URLRequest(url: serverURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")

        // Auth: prefer OAuth token, fall back to API key
        if let oauthToken {
            urlRequest.setValue("Bearer \(oauthToken)", forHTTPHeaderField: "Authorization")
        } else if !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        if let sessionID {
            urlRequest.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }

        let body = try JSONEncoder().encode(rpcRequest)
        urlRequest.httpBody = body

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPClientError.connectionFailed("Non-HTTP response received.")
        }

        if let sid = httpResponse.value(forHTTPHeaderField: "Mcp-Session-Id") {
            self.sessionID = sid
        }

        // Detect OAuth requirement
        if httpResponse.statusCode == 401 {
            throw MCPClientError.oauthRequired(serverURL: serverURL)
        }

        if httpResponse.statusCode == 202 {
            return Data()
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "No body"
            throw MCPClientError.connectionFailed(
                "HTTP \(httpResponse.statusCode) at \(serverURL.absoluteString): \(body)"
            )
        }

        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
        if contentType.contains("text/event-stream") {
            return extractJSONFromSSE(data)
        }

        return data
    }

    private func extractJSONFromSSE(_ data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("data: ") {
                let json = String(trimmed.dropFirst(6))
                if json.hasPrefix("{") {
                    return Data(json.utf8)
                }
            }
        }
        return data
    }

    private func getNextID() -> Int {
        let id = nextRequestID
        nextRequestID += 1
        return id
    }
}
