import Foundation
import Combine

// MARK: - MCP Server Manager

/// Manages connections to MCP servers and caches discovered tools.
@MainActor
final class MCPServerManager: ObservableObject {
    static let shared = MCPServerManager()
    private let cacheKeyPrefix = "mcp.cachedTools."
    private static let globalAccessKey = "mcp.globalToolAccess"

    /// When true, all connected MCP tools are available to every node
    /// without per-node assignment. Persisted across app launches.
    @Published var globalToolAccess: Bool {
        didSet { UserDefaults.standard.set(globalToolAccess, forKey: Self.globalAccessKey) }
    }

    /// Tools discovered from all connected MCP servers, keyed by server connection ID.
    @Published var discoveredTools: [UUID: [MCPRemoteTool]] = [:]

    /// Connection status per server, keyed by server connection ID.
    @Published var connectionStatus: [UUID: ConnectionStatus] = [:]
    private var activeConnections: [UUID: MCPServerConnection] = [:]

    private init() {
        self.globalToolAccess = UserDefaults.standard.bool(forKey: Self.globalAccessKey)
    }

    enum ConnectionStatus: Equatable {
        case disconnected
        case connecting
        case connected(toolCount: Int)
        case awaitingOAuth
        case failed(String)
    }

    /// All discovered tools across all connected servers, flattened.
    var allRemoteTools: [MCPRemoteTool] {
        discoveredTools.values.flatMap { $0 }
    }

    /// Connects to an MCP server, performing OAuth if required.
    func connect(to connection: MCPServerConnection) async {
        activeConnections[connection.id] = connection

        // Stdio (local) transport — macOS only, completely separate code path.
        if connection.isStdio {
            await connectStdio(connection)
            return
        }

        guard let url = normalizedURL(for: connection) else {
            connectionStatus[connection.id] = .failed("Invalid URL")
            return
        }

        connectionStatus[connection.id] = .connecting

        // First try with API key (if provided)
        let client = MCPServerClient(
            url: url,
            apiKey: connection.apiKey,
            serverConnectionID: connection.id
        )

        do {
            let tools = try await client.discoverTools()
            discoveredTools[connection.id] = tools
            cacheDiscoveredTools(tools, on: connection)
            connectionStatus[connection.id] = .connected(toolCount: tools.count)
        } catch let error as MCPClientError {
            if case .oauthRequired = error {
                // OAuth needed — run the flow
                await connectWithOAuth(connection: connection, url: url)
            } else if case .connectionFailed(let msg) = error, msg.contains("401") {
                // Also catch 401 from initial connection
                await connectWithOAuth(connection: connection, url: url)
            } else if case .connectionFailed(let msg) = error,
                      msg.contains("404"),
                      let fallbackURL = fallbackURLForNotFound(from: url) {
                await connectUsingFallbackURL(connection: connection, fallbackURL: fallbackURL)
            } else {
                connectionStatus[connection.id] = .failed(error.localizedDescription)
                discoveredTools[connection.id] = nil
            }
        } catch {
            connectionStatus[connection.id] = .failed(error.localizedDescription)
            discoveredTools[connection.id] = nil
        }
    }

    /// Runs the OAuth flow and retries connection.
    private func connectWithOAuth(connection: MCPServerConnection, url: URL) async {
        connectionStatus[connection.id] = .awaitingOAuth

        do {
            let token = try await MCPOAuthHandler.shared.accessToken(for: url)

            connectionStatus[connection.id] = .connecting

            let client = MCPServerClient(
                url: url,
                apiKey: "",
                serverConnectionID: connection.id,
                oauthToken: token
            )

            let tools = try await client.discoverTools()
            discoveredTools[connection.id] = tools
            cacheDiscoveredTools(tools, on: connection)
            connectionStatus[connection.id] = .connected(toolCount: tools.count)
        } catch let error as MCPClientError {
            let msg: String
            switch error {
            case .oauthFailed(let detail): msg = "OAuth failed: \(detail)"
            case .connectionFailed(let detail): msg = detail
            case .toolCallFailed(let detail): msg = detail
            default: msg = error.localizedDescription
            }
            connectionStatus[connection.id] = .failed(msg)
            discoveredTools[connection.id] = nil
        } catch {
            connectionStatus[connection.id] = .failed(error.localizedDescription)
            discoveredTools[connection.id] = nil
        }
    }

    /// Connects to a local stdio MCP server by spawning the configured binary.
    /// Available only on macOS; on other platforms this records a failure.
    private func connectStdio(_ connection: MCPServerConnection) async {
        #if os(macOS) || targetEnvironment(macCatalyst)
        connectionStatus[connection.id] = .connecting
        let args = splitArguments(connection.arguments)
        let client = MCPStdioClient(
            command: connection.command,
            arguments: args,
            serverConnectionID: connection.id
        )
        do {
            let discovery = try await client.discover()
            discoveredTools[connection.id] = discovery.tools
            cacheDiscoveredTools(discovery.tools, on: connection)
            // Persist the server's self-reported description / name so the
            // inspector row can display them instead of just the binary path.
            if let instructions = discovery.instructions {
                let current = connection.serverDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                // Overwrite when empty or when it still holds the auto-seeded
                // binary path from the create-sheet (pre-discovery placeholder).
                if current.isEmpty || current == connection.command {
                    connection.serverDescription = instructions
                }
            }
            connectionStatus[connection.id] = .connected(toolCount: discovery.tools.count)
        } catch {
            connectionStatus[connection.id] = .failed(error.localizedDescription)
            discoveredTools[connection.id] = nil
        }
        #else
        connectionStatus[connection.id] = .failed("Local (stdio) MCP servers are only supported on macOS.")
        discoveredTools[connection.id] = nil
        #endif
    }

    /// Splits a CLI arguments string on whitespace, honoring simple quoting.
    private func splitArguments(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        var args: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        for ch in trimmed {
            if ch == "'" && !inDouble { inSingle.toggle(); continue }
            if ch == "\"" && !inSingle { inDouble.toggle(); continue }
            if ch == " " && !inSingle && !inDouble {
                if !current.isEmpty { args.append(current); current = "" }
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty { args.append(current) }
        return args
    }

    /// Disconnects from a server and clears its tools.
    func disconnect(id: UUID) {
        discoveredTools[id] = nil
        connectionStatus[id] = .disconnected
        activeConnections[id] = nil
    }

    /// Registers enabled server connections so tool calls can resolve by server ID.
    func registerKnownConnections(_ connections: [MCPServerConnection]) {
        for connection in connections where connection.isEnabled {
            activeConnections[connection.id] = connection
        }
    }

    /// Returns cached tools from local storage for a connection.
    func cachedTools(for connectionID: UUID) -> [MCPRemoteTool] {
        let key = cacheKeyPrefix + connectionID.uuidString
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([MCPRemoteTool].self, from: data) else {
            return []
        }
        return decoded
    }

    /// Returns cached tool count from local storage for a connection.
    func cachedToolCount(for connectionID: UUID) -> Int {
        cachedTools(for: connectionID).count
    }

    /// Resolves which connected server should handle a remote tool.
    /// Returns a prompt-friendly description of a remote tool including its parameter schema.
    func toolSchemaDescription(forToolName toolName: String) -> String? {
        let tool: MCPRemoteTool? = allRemoteTools.first(where: { $0.name == toolName })
            ?? discoveredTools.values.flatMap({ $0 }).first(where: { $0.name == toolName })

        guard let tool else { return nil }

        var desc = "- \(tool.name)"
        if let title = tool.title, !title.isEmpty { desc += " (\(title))" }
        desc += ": "
        if let d = tool.description, !d.isEmpty {
            // Truncate to first 120 chars to keep prompt compact
            let cleaned = d.replacingOccurrences(of: "\n", with: " ")
            desc += String(cleaned.prefix(120))
        }

        if let schema = tool.inputSchema, let props = schema.properties, !props.isEmpty {
            let required = Set(schema.required ?? [])
            let paramDescs = props.sorted(by: { $0.key < $1.key }).map { key, prop in
                let typeStr = prop.type ?? "any"
                let reqStr = required.contains(key) ? ", required" : ""
                let propDesc = prop.description.map { " — \(String($0.prefix(60)))" } ?? ""
                return "    \(key) (\(typeStr)\(reqStr))\(propDesc)"
            }
            desc += "\n  Parameters:\n" + paramDescs.joined(separator: "\n")
        }

        return desc
    }

    func serverConnectionID(forToolName toolName: String) -> UUID? {
        if let live = allRemoteTools.first(where: { $0.name == toolName }) {
            return live.serverConnectionID
        }

        for (connectionID, _) in activeConnections {
            if cachedTools(for: connectionID).contains(where: { $0.name == toolName }) {
                return connectionID
            }
        }

        return nil
    }

    /// Calls a tool on a known MCP server by connection ID.
    func callTool(
        name: String,
        arguments: [String: AnyCodableValue],
        onServerWithID serverConnectionID: UUID
    ) async throws -> MCPToolCallResult {
        guard let connection = activeConnections[serverConnectionID] else {
            throw MCPClientError.connectionFailed("MCP server for tool '\(name)' is not connected.")
        }
        return try await callTool(name: name, arguments: arguments, on: connection)
    }

    /// Calls a tool on the appropriate MCP server.
    func callTool(name: String, arguments: [String: AnyCodableValue], on connection: MCPServerConnection) async throws -> MCPToolCallResult {
        if connection.isStdio {
            #if os(macOS) || targetEnvironment(macCatalyst)
            let client = MCPStdioClient(
                command: connection.command,
                arguments: splitArguments(connection.arguments),
                serverConnectionID: connection.id
            )
            return try await client.callTool(name: name, arguments: arguments)
            #else
            throw MCPClientError.connectionFailed("Local (stdio) MCP servers are only supported on macOS.")
            #endif
        }

        guard let url = normalizedURL(for: connection) else {
            throw MCPClientError.connectionFailed("Invalid URL")
        }

        // Try to get OAuth token if available
        let oauthToken = try? await MCPOAuthHandler.shared.accessToken(for: url)

        let client = MCPServerClient(
            url: url,
            apiKey: connection.apiKey,
            serverConnectionID: connection.id,
            oauthToken: oauthToken
        )

        _ = try await client.discoverTools()
        return try await client.callTool(name: name, arguments: arguments)
    }

    /// Normalizes known MCP host endpoints to avoid stale root URLs causing 404s.
    private func normalizedURL(for connection: MCPServerConnection) -> URL? {
        let raw = connection.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: raw) else { return nil }

        let defaultPathByHost: [String: String] = [
            "api.githubcopilot.com": "/mcp",
            "mcp.exa.ai": "/mcp",
            "mcp.linear.app": "/mcp",
            "mcp.notion.com": "/mcp",
            "mcp.slack.com": "/mcp",
            "mcp.supabase.com": "/mcp"
        ]

        if let host = components.host?.lowercased(),
           let defaultPath = defaultPathByHost[host],
           components.path.isEmpty || components.path == "/" {
            components.path = defaultPath
        }

        guard let normalized = components.url else { return nil }
        let normalizedString = normalized.absoluteString
        if normalizedString != connection.url {
            connection.url = normalizedString
        }
        return normalized
    }

    private func fallbackURLForNotFound(from url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased() else {
            return nil
        }

        switch host {
        case "mcp.notion.com":
            if components.path == "/mcp" {
                components.path = "/sse"
            } else if components.path == "/sse" {
                components.path = "/mcp"
            } else {
                components.path = "/mcp"
            }
        default:
            return nil
        }

        return components.url
    }

    private func connectUsingFallbackURL(connection: MCPServerConnection, fallbackURL: URL) async {
        let fallbackClient = MCPServerClient(
            url: fallbackURL,
            apiKey: connection.apiKey,
            serverConnectionID: connection.id
        )

        do {
            let tools = try await fallbackClient.discoverTools()
            connection.url = fallbackURL.absoluteString
            discoveredTools[connection.id] = tools
            cacheDiscoveredTools(tools, on: connection)
            connectionStatus[connection.id] = .connected(toolCount: tools.count)
        } catch let error as MCPClientError {
            if case .oauthRequired = error {
                connection.url = fallbackURL.absoluteString
                await connectWithOAuth(connection: connection, url: fallbackURL)
            } else if case .connectionFailed(let msg) = error, msg.contains("401") {
                connection.url = fallbackURL.absoluteString
                await connectWithOAuth(connection: connection, url: fallbackURL)
            } else {
                connectionStatus[connection.id] = .failed(error.localizedDescription)
                discoveredTools[connection.id] = nil
            }
        } catch {
            connectionStatus[connection.id] = .failed(error.localizedDescription)
            discoveredTools[connection.id] = nil
        }
    }

    private func cacheDiscoveredTools(_ tools: [MCPRemoteTool], on connection: MCPServerConnection) {
        if let data = try? JSONEncoder().encode(tools) {
            let key = cacheKeyPrefix + connection.id.uuidString
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
