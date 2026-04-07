import Foundation
import Combine
import AuthenticationServices
import CryptoKit

// MARK: - MCP Protocol Types

/// A tool discovered from an MCP server.
struct MCPRemoteTool: Identifiable, Codable, Hashable {
    var id: String { "\(serverConnectionID.uuidString)_\(name)" }
    let name: String
    let title: String?
    let description: String?
    let inputSchema: MCPToolInputSchema?
    /// Which server connection ID this tool belongs to.
    let serverConnectionID: UUID
}

struct MCPToolInputSchema: Codable, Hashable {
    let type: String?
    let properties: [String: MCPSchemaProperty]?
    let required: [String]?
}

struct MCPSchemaProperty: Codable, Hashable {
    let type: String?
    let description: String?
}

/// Result from calling an MCP tool.
struct MCPToolCallResult {
    let content: String
    let isError: Bool
}

// MARK: - JSON-RPC Types

private struct JSONRPCRequest: Encodable {
    let jsonrpc: String = "2.0"
    let id: Int?
    let method: String
    let params: JSONRPCParams?
}

private enum JSONRPCParams: Encodable {
    case initialize(InitializeParams)
    case toolsList(ToolsListParams)
    case toolsCall(ToolsCallParams)
    case empty

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .initialize(let p): try container.encode(p)
        case .toolsList(let p): try container.encode(p)
        case .toolsCall(let p): try container.encode(p)
        case .empty: try container.encode([String: String]())
        }
    }
}

private struct InitializeParams: Encodable {
    let protocolVersion = "2025-03-26"
    let capabilities = ClientCapabilities()
    let clientInfo = ClientInfo()

    struct ClientCapabilities: Encodable {
        let roots = RootsCapability()
        struct RootsCapability: Encodable {
            let listChanged = false
        }
    }
    struct ClientInfo: Encodable {
        let name = "Agentic"
        let version = "1.0.0"
    }
}

private struct ToolsListParams: Encodable {
    let cursor: String?
}

private struct ToolsCallParams: Encodable {
    let name: String
    let arguments: [String: String]
}

// MARK: - JSON-RPC Response Types

private struct JSONRPCResponse: Decodable {
    let jsonrpc: String
    let id: Int?
    let result: AnyCodable?
    let error: JSONRPCError?
}

private struct JSONRPCError: Decodable {
    let code: Int
    let message: String
}

/// Minimal any-value wrapper for decoding arbitrary JSON.
private struct AnyCodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else if let arr = try? container.decode([AnyCodable].self) {
            value = arr.map { $0.value }
        } else if let str = try? container.decode(String.self) {
            value = str
        } else if let num = try? container.decode(Double.self) {
            value = num
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else {
            value = NSNull()
        }
    }
}

// MARK: - OAuth 2.1 Types

/// Cached OAuth token for an MCP server connection.
struct MCPOAuthToken {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt
    }
}

/// OAuth authorization server metadata (RFC 8414).
private struct OAuthServerMetadata: Decodable {
    let issuer: String?
    let authorization_endpoint: String
    let token_endpoint: String
    let registration_endpoint: String?
    let scopes_supported: [String]?
    let response_types_supported: [String]?
    let code_challenge_methods_supported: [String]?
}

/// Protected resource metadata (RFC 9728).
private struct ProtectedResourceMetadata: Decodable {
    let resource: String?
    let authorization_servers: [String]?
}

/// Dynamic client registration response (RFC 7591).
private struct ClientRegistrationResponse: Decodable {
    let client_id: String
    let client_secret: String?
    let client_id_issued_at: Int?
}

/// Token endpoint response.
private struct TokenResponse: Decodable {
    let access_token: String
    let token_type: String?
    let expires_in: Int?
    let refresh_token: String?
    let scope: String?
}

// MARK: - MCP Client Errors

enum MCPClientError: LocalizedError {
    case connectionFailed(String)
    case initializationFailed(String)
    case toolsNotSupported
    case invalidResponse(String)
    case toolCallFailed(String)
    case oauthRequired(serverURL: URL)
    case oauthFailed(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "MCP connection failed: \(msg)"
        case .initializationFailed(let msg): return "MCP initialization failed: \(msg)"
        case .toolsNotSupported: return "This MCP server does not support tools."
        case .invalidResponse(let msg): return "Invalid MCP response: \(msg)"
        case .toolCallFailed(let msg): return "MCP tool call failed: \(msg)"
        case .oauthRequired: return "This server requires OAuth authentication."
        case .oauthFailed(let msg): return "OAuth failed: \(msg)"
        }
    }
}

// MARK: - OAuth Handler

/// Handles the MCP OAuth 2.1 flow: discovery → registration → PKCE auth → token exchange.
@MainActor
final class MCPOAuthHandler: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = MCPOAuthHandler()

    /// Cached tokens keyed by server URL string.
    private var tokenCache: [String: MCPOAuthToken] = [:]

    /// Cached client registrations keyed by authorization server URL.
    private var clientCache: [String: (clientID: String, clientSecret: String?)] = [:]

    private static let callbackScheme = "agentic"
    private static let redirectURI = "agentic://oauth/callback"

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if targetEnvironment(macCatalyst)
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow }) ?? ASPresentationAnchor()
        #else
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow }) ?? ASPresentationAnchor()
        #endif
    }

    /// Returns a valid access token for the given server, performing OAuth if needed.
    func accessToken(for serverURL: URL) async throws -> String {
        let key = serverURL.absoluteString

        // Check cache
        if let cached = tokenCache[key], !cached.isExpired {
            return cached.accessToken
        }

        // Try refresh
        if let cached = tokenCache[key], let refreshToken = cached.refreshToken {
            if let refreshed = try? await refreshAccessToken(refreshToken, for: serverURL) {
                tokenCache[key] = refreshed
                return refreshed.accessToken
            }
        }

        // Full OAuth flow
        let token = try await performOAuthFlow(for: serverURL)
        tokenCache[key] = token
        return token.accessToken
    }

    /// Checks if a server requires OAuth by probing it.
    func requiresOAuth(serverURL: URL) async -> Bool {
        var request = URLRequest(url: serverURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(
            JSONRPCRequest(id: 1, method: "initialize", params: .initialize(InitializeParams()))
        )

        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else {
            return false
        }

        return http.statusCode == 401
    }

    /// Clears cached tokens for a server.
    func clearToken(for serverURL: URL) {
        tokenCache.removeValue(forKey: serverURL.absoluteString)
    }

    // MARK: - OAuth Flow Steps

    private func performOAuthFlow(for serverURL: URL) async throws -> MCPOAuthToken {
        // Step 1: Discover authorization server
        let (authServerURL, resourceMetadata) = try await discoverAuthServer(for: serverURL)

        // Step 2: Get authorization server metadata
        let asMetadata = try await fetchAuthServerMetadata(authServerURL: authServerURL)

        // Step 3: Dynamic client registration (if supported)
        let (clientID, clientSecret) = try await registerClient(
            asMetadata: asMetadata,
            serverURL: serverURL
        )

        // Step 4: PKCE authorization code flow
        let authCode = try await authorizeWithBrowser(
            asMetadata: asMetadata,
            clientID: clientID,
            serverURL: serverURL
        )

        // Step 5: Exchange code for token
        let token = try await exchangeCodeForToken(
            code: authCode.code,
            codeVerifier: authCode.codeVerifier,
            asMetadata: asMetadata,
            clientID: clientID,
            clientSecret: clientSecret,
            serverURL: serverURL
        )

        return token
    }

    /// Step 1: Discover the authorization server from protected resource metadata.
    private func discoverAuthServer(for serverURL: URL) async throws -> (URL, ProtectedResourceMetadata?) {
        // Try /.well-known/oauth-protected-resource
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)!
        let originalPath = components.path
        components.path = "/.well-known/oauth-protected-resource" + (originalPath == "/" ? "" : originalPath)

        if let metadataURL = components.url {
            var request = URLRequest(url: metadataURL)
            request.httpMethod = "GET"

            if let (data, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse,
               http.statusCode == 200,
               let metadata = try? JSONDecoder().decode(ProtectedResourceMetadata.self, from: data),
               let authServers = metadata.authorization_servers,
               let firstAS = authServers.first,
               let asURL = URL(string: firstAS) {
                return (asURL, metadata)
            }
        }

        // Fallback: probe the server and parse WWW-Authenticate header
        var probeRequest = URLRequest(url: serverURL)
        probeRequest.httpMethod = "POST"
        probeRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        probeRequest.httpBody = try JSONEncoder().encode(
            JSONRPCRequest(id: 1, method: "initialize", params: .initialize(InitializeParams()))
        )

        let (_, probeResponse) = try await URLSession.shared.data(for: probeRequest)
        if let http = probeResponse as? HTTPURLResponse,
           http.statusCode == 401,
           let wwwAuth = http.value(forHTTPHeaderField: "WWW-Authenticate") {
            // Parse: Bearer resource_metadata="https://..."
            if let metadataURLString = parseWWWAuthenticate(wwwAuth, key: "resource_metadata"),
               let metadataURL = URL(string: metadataURLString) {
                let (data, _) = try await URLSession.shared.data(from: metadataURL)
                let metadata = try JSONDecoder().decode(ProtectedResourceMetadata.self, from: data)
                if let authServers = metadata.authorization_servers,
                   let firstAS = authServers.first,
                   let asURL = URL(string: firstAS) {
                    return (asURL, metadata)
                }
            }
        }

        // Last resort: assume auth server is same origin
        var fallback = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)!
        fallback.path = ""
        guard let fallbackURL = fallback.url else {
            throw MCPClientError.oauthFailed("Could not discover authorization server.")
        }
        return (fallbackURL, nil)
    }

    /// Step 2: Fetch OAuth authorization server metadata (RFC 8414).
    private func fetchAuthServerMetadata(authServerURL: URL) async throws -> OAuthServerMetadata {
        var components = URLComponents(url: authServerURL, resolvingAgainstBaseURL: false)!
        components.path = "/.well-known/oauth-authorization-server"

        guard let metadataURL = components.url else {
            throw MCPClientError.oauthFailed("Invalid authorization server URL.")
        }

        let (data, response) = try await URLSession.shared.data(from: metadataURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw MCPClientError.oauthFailed("Failed to fetch authorization server metadata.")
        }

        return try JSONDecoder().decode(OAuthServerMetadata.self, from: data)
    }

    /// Step 3: Dynamic client registration (RFC 7591).
    private func registerClient(
        asMetadata: OAuthServerMetadata,
        serverURL: URL
    ) async throws -> (clientID: String, clientSecret: String?) {
        let cacheKey = asMetadata.authorization_endpoint

        // Use cached registration
        if let cached = clientCache[cacheKey] {
            return cached
        }

        // Try dynamic registration
        if let regEndpoint = asMetadata.registration_endpoint,
           let regURL = URL(string: regEndpoint) {
            var request = URLRequest(url: regURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body: [String: Any] = [
                "client_name": "Agentic",
                "redirect_uris": [Self.redirectURI],
                "grant_types": ["authorization_code"],
                "response_types": ["code"],
                "token_endpoint_auth_method": "none"
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse,
               (200..<300).contains(http.statusCode) {
                let reg = try JSONDecoder().decode(ClientRegistrationResponse.self, from: data)
                let result = (reg.client_id, reg.client_secret)
                clientCache[cacheKey] = result
                return result
            }
        }

        throw MCPClientError.oauthFailed(
            "This server requires OAuth but does not support dynamic client registration. A pre-registered client ID is needed."
        )
    }

    /// Step 4: PKCE authorization code flow via ASWebAuthenticationSession.
    private func authorizeWithBrowser(
        asMetadata: OAuthServerMetadata,
        clientID: String,
        serverURL: URL
    ) async throws -> (code: String, codeVerifier: String) {
        let codeVerifier = generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(from: codeVerifier)
        let state = UUID().uuidString

        var components = URLComponents(string: asMetadata.authorization_endpoint)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "resource", value: serverURL.absoluteString),
        ]

        // Add scope if supported
        if let scopes = asMetadata.scopes_supported, !scopes.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "scope", value: scopes.joined(separator: " ")))
        }

        guard let authURL = components.url else {
            throw MCPClientError.oauthFailed("Could not build authorization URL.")
        }

        let callbackURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: Self.callbackScheme
            ) { callbackURL, error in
                if let error {
                    continuation.resume(throwing: MCPClientError.oauthFailed(error.localizedDescription))
                } else if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: MCPClientError.oauthFailed("No callback URL received."))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }

        // Parse authorization code from callback
        guard let callbackComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let code = callbackComponents.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw MCPClientError.oauthFailed("No authorization code in callback.")
        }

        // Verify state
        let returnedState = callbackComponents.queryItems?.first(where: { $0.name == "state" })?.value
        if returnedState != state {
            throw MCPClientError.oauthFailed("OAuth state mismatch — possible CSRF attack.")
        }

        return (code, codeVerifier)
    }

    /// Step 5: Exchange authorization code for access token.
    private func exchangeCodeForToken(
        code: String,
        codeVerifier: String,
        asMetadata: OAuthServerMetadata,
        clientID: String,
        clientSecret: String?,
        serverURL: URL
    ) async throws -> MCPOAuthToken {
        guard let tokenURL = URL(string: asMetadata.token_endpoint) else {
            throw MCPClientError.oauthFailed("Invalid token endpoint.")
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var params = [
            "grant_type=authorization_code",
            "code=\(code)",
            "redirect_uri=\(Self.redirectURI.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? Self.redirectURI)",
            "client_id=\(clientID)",
            "code_verifier=\(codeVerifier)",
            "resource=\(serverURL.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? serverURL.absoluteString)"
        ]

        if let secret = clientSecret {
            params.append("client_secret=\(secret)")
        }

        request.httpBody = params.joined(separator: "&").data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw MCPClientError.oauthFailed("Token exchange failed: \(body)")
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)

        let expiresAt: Date?
        if let expiresIn = tokenResponse.expires_in {
            expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        } else {
            expiresAt = nil
        }

        return MCPOAuthToken(
            accessToken: tokenResponse.access_token,
            refreshToken: tokenResponse.refresh_token,
            expiresAt: expiresAt
        )
    }

    /// Refresh an expired access token.
    private func refreshAccessToken(_ refreshToken: String, for serverURL: URL) async throws -> MCPOAuthToken {
        let (authServerURL, _) = try await discoverAuthServer(for: serverURL)
        let asMetadata = try await fetchAuthServerMetadata(authServerURL: authServerURL)

        guard let tokenURL = URL(string: asMetadata.token_endpoint) else {
            throw MCPClientError.oauthFailed("Invalid token endpoint for refresh.")
        }

        let cacheKey = asMetadata.authorization_endpoint
        guard let client = clientCache[cacheKey] else {
            throw MCPClientError.oauthFailed("No registered client for token refresh.")
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var params = [
            "grant_type=refresh_token",
            "refresh_token=\(refreshToken)",
            "client_id=\(client.clientID)",
            "resource=\(serverURL.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? serverURL.absoluteString)"
        ]
        if let secret = client.clientSecret {
            params.append("client_secret=\(secret)")
        }
        request.httpBody = params.joined(separator: "&").data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MCPClientError.oauthFailed("Token refresh failed.")
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        return MCPOAuthToken(
            accessToken: tokenResponse.access_token,
            refreshToken: tokenResponse.refresh_token ?? refreshToken,
            expiresAt: tokenResponse.expires_in.map { Date().addingTimeInterval(TimeInterval($0)) }
        )
    }

    // MARK: - PKCE Helpers

    private func generateCodeVerifier() -> String {
        var buffer = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        return Data(buffer).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        guard let data = verifier.data(using: .utf8) else { return verifier }
        let hash = SHA256.hash(data: data)
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Parsing Helpers

    private func parseWWWAuthenticate(_ header: String, key: String) -> String? {
        // Parses: Bearer resource_metadata="https://..."
        let pattern = "\(key)=\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
              let range = Range(match.range(at: 1), in: header) else {
            return nil
        }
        return String(header[range])
    }
}

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
    func callTool(name: String, arguments: [String: String]) async throws -> MCPToolCallResult {
        let id = getNextID()
        let request = JSONRPCRequest(
            id: id,
            method: "tools/call",
            params: .toolsCall(ToolsCallParams(name: name, arguments: arguments))
        )

        let responseData = try await sendRequest(request)
        let parsed = try JSONDecoder().decode(JSONRPCResponse.self, from: responseData)

        if let error = parsed.error {
            throw MCPClientError.toolCallFailed("\(error.message) (code: \(error.code))")
        }

        guard let result = parsed.result?.value as? [String: Any] else {
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
        let parsed = try JSONDecoder().decode(JSONRPCResponse.self, from: responseData)

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
            let parsed = try JSONDecoder().decode(JSONRPCResponse.self, from: responseData)

            if let error = parsed.error {
                throw MCPClientError.invalidResponse(error.message)
            }

            guard let result = parsed.result?.value as? [String: Any] else {
                throw MCPClientError.invalidResponse("Missing result in tools/list response.")
            }

            if let toolsArray = result["tools"] as? [[String: Any]] {
                for toolDict in toolsArray {
                    let name = toolDict["name"] as? String ?? ""
                    let title = toolDict["title"] as? String
                    let description = toolDict["description"] as? String

                    var inputSchema: MCPToolInputSchema? = nil
                    if let schemaDict = toolDict["inputSchema"],
                       let schemaData = try? JSONSerialization.data(withJSONObject: schemaDict),
                       let decoded = try? JSONDecoder().decode(MCPToolInputSchema.self, from: schemaData) {
                        inputSchema = decoded
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

// MARK: - MCP Server Manager

/// Manages connections to MCP servers and caches discovered tools.
@MainActor
final class MCPServerManager: ObservableObject {
    static let shared = MCPServerManager()
    private let cacheKeyPrefix = "mcp.cachedTools."

    /// Tools discovered from all connected MCP servers, keyed by server connection ID.
    @Published var discoveredTools: [UUID: [MCPRemoteTool]] = [:]

    /// Connection status per server, keyed by server connection ID.
    @Published var connectionStatus: [UUID: ConnectionStatus] = [:]

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
        } catch {
            connectionStatus[connection.id] = .failed(error.localizedDescription)
            discoveredTools[connection.id] = nil
        }
    }

    /// Disconnects from a server and clears its tools.
    func disconnect(id: UUID) {
        discoveredTools[id] = nil
        connectionStatus[id] = .disconnected
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

    /// Calls a tool on the appropriate MCP server.
    func callTool(name: String, arguments: [String: String], on connection: MCPServerConnection) async throws -> MCPToolCallResult {
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
            "mcp.linear.app": "/sse",
            "mcp.notion.com": "/mcp",
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
