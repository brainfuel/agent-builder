import Foundation
import AuthenticationServices
import CryptoKit

// MARK: - OAuth Handler

/// Handles the MCP OAuth 2.1 flow: discovery -> registration -> PKCE auth -> token exchange.
@MainActor
final class MCPOAuthHandler: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = MCPOAuthHandler()

    /// Cached tokens keyed by server URL string.
    private var tokenCache: [String: MCPOAuthToken] = [:]

    /// Cached client registrations keyed by authorization server URL.
    private var clientCache: [String: (clientID: String, clientSecret: String?)] = [:]
    private var activeWebAuthSession: ASWebAuthenticationSession?

    private static let callbackScheme = "agentic"
    private static let redirectURI = "agentic://oauth/callback"
    private static let authTimeoutNanoseconds: UInt64 = 60_000_000_000

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if targetEnvironment(macCatalyst)
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        return windows.first(where: { $0.isKeyWindow }) ?? windows.first ?? ASPresentationAnchor()
        #else
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        return windows.first(where: { $0.isKeyWindow }) ?? windows.first ?? ASPresentationAnchor()
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
        let resource = resourceMetadata?.resource ?? serverURL.absoluteString

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
            resource: resource
        )

        // Step 5: Exchange code for token
        let token = try await exchangeCodeForToken(
            code: authCode.code,
            codeVerifier: authCode.codeVerifier,
            asMetadata: asMetadata,
            clientID: clientID,
            clientSecret: clientSecret,
            resource: resource
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

    /// Step 2: Fetch OAuth authorization server metadata.
    ///
    /// Per the MCP spec, clients must try RFC 8414 (`oauth-authorization-server`) and
    /// should also try OpenID Connect Discovery (`openid-configuration`). Each must be
    /// attempted both at the root of the authorization server and, if the auth server
    /// URL has a non-root path, with the well-known segment inserted before that path.
    private func fetchAuthServerMetadata(authServerURL: URL) async throws -> OAuthServerMetadata {
        let candidates = metadataCandidateURLs(for: authServerURL)
        guard !candidates.isEmpty else {
            throw MCPClientError.oauthFailed("Invalid authorization server URL.")
        }

        var lastStatus: Int?
        for url in candidates {
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse else {
                continue
            }
            lastStatus = http.statusCode
            guard http.statusCode == 200 else { continue }
            if let metadata = try? JSONDecoder().decode(OAuthServerMetadata.self, from: data) {
                return metadata
            }
        }

        let hostDescription = authServerURL.host.map { "\($0)" } ?? authServerURL.absoluteString
        if lastStatus == 404 || lastStatus == nil {
            throw MCPClientError.oauthFailed(
                "\(hostDescription) does not expose OAuth discovery metadata. This provider likely requires a pre-configured client ID and manual OAuth setup, which this app does not yet support."
            )
        }
        throw MCPClientError.oauthFailed(
            "Failed to fetch authorization server metadata from \(hostDescription) (status \(lastStatus.map(String.init) ?? "n/a"))."
        )
    }

    /// Build the ordered list of discovery URLs to probe, per MCP / RFC 8414 / OIDC Discovery.
    private func metadataCandidateURLs(for authServerURL: URL) -> [URL] {
        guard var components = URLComponents(url: authServerURL, resolvingAgainstBaseURL: false) else {
            return []
        }
        // Normalise a trailing slash-only path to empty so path logic is consistent.
        let originalPath = components.path == "/" ? "" : components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let wellKnownSuffixes = [
            "oauth-authorization-server",
            "openid-configuration"
        ]

        var urls: [URL] = []
        for suffix in wellKnownSuffixes {
            // 1. Root-level: https://host/.well-known/<suffix>
            components.path = "/.well-known/\(suffix)"
            components.query = nil
            if let url = components.url { urls.append(url) }

            // 2. Path-preserving: https://host/.well-known/<suffix>/<path>  (RFC 8414 §3)
            if !originalPath.isEmpty {
                components.path = "/.well-known/\(suffix)/\(originalPath)"
                if let url = components.url { urls.append(url) }

                // 3. Under-path variant: https://host/<path>/.well-known/<suffix>  (OIDC-style)
                components.path = "/\(originalPath)/.well-known/\(suffix)"
                if let url = components.url { urls.append(url) }
            }
        }
        // De-duplicate while preserving order.
        var seen = Set<String>()
        return urls.filter { seen.insert($0.absoluteString).inserted }
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
                "client_name": "Agent Builder",
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
        resource: String
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
            URLQueryItem(name: "resource", value: resource),
        ]

        // Add scope if supported
        if let scopes = asMetadata.scopes_supported, !scopes.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "scope", value: scopes.joined(separator: " ")))
        }

        guard let authURL = components.url else {
            throw MCPClientError.oauthFailed("Could not build authorization URL.")
        }

        let callbackURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            var didResume = false
            var timeoutTask: Task<Void, Never>?

            @MainActor
            func finish(_ result: Result<URL, Error>) {
                guard !didResume else { return }
                didResume = true
                timeoutTask?.cancel()
                self.activeWebAuthSession = nil
                switch result {
                case .success(let callback):
                    continuation.resume(returning: callback)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: Self.callbackScheme
            ) { callbackURL, error in
                Task { @MainActor in
                    if let error {
                        finish(.failure(MCPClientError.oauthFailed(error.localizedDescription)))
                    } else if let callbackURL {
                        finish(.success(callbackURL))
                    } else {
                        finish(.failure(MCPClientError.oauthFailed("No callback URL received.")))
                    }
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false

            // Cancel any stale in-flight auth session before starting a new one.
            self.activeWebAuthSession?.cancel()
            self.activeWebAuthSession = session
            let started = session.start()
            if !started {
                Task { @MainActor in
                    finish(.failure(MCPClientError.oauthFailed("Could not start browser authentication session.")))
                }
                return
            }

            timeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: Self.authTimeoutNanoseconds)
                guard !didResume else { return }
                self.activeWebAuthSession?.cancel()
                finish(.failure(MCPClientError.oauthFailed("Authentication timed out before returning to Agent Builder.")))
            }
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
        resource: String
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
            "resource=\(resource.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? resource)"
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
        let (authServerURL, resourceMetadata) = try await discoverAuthServer(for: serverURL)
        let resource = resourceMetadata?.resource ?? serverURL.absoluteString
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
            "resource=\(resource.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? resource)"
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
