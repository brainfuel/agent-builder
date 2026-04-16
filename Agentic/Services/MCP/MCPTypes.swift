import Foundation

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

struct JSONRPCRequest: Encodable {
    let jsonrpc: String = "2.0"
    let id: Int?
    let method: String
    let params: JSONRPCParams?
}

enum JSONRPCParams: Encodable {
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

struct InitializeParams: Encodable {
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
        let name = "Agent Builder"
        let version = "1.0.0"
    }
}

struct ToolsListParams: Encodable {
    let cursor: String?
}

struct ToolsCallParams: Encodable {
    let name: String
    let arguments: [String: AnyCodableValue]
}

/// Wraps arbitrary JSON values so they can be sent as MCP tool arguments.
enum AnyCodableValue: Codable, Hashable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([AnyCodableValue])
    case object([String: AnyCodableValue])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .null: try container.encodeNil()
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Bool.self) { self = .bool(v) }
        else if let v = try? container.decode(Int.self) { self = .int(v) }
        else if let v = try? container.decode(Double.self) { self = .double(v) }
        else if let v = try? container.decode(String.self) { self = .string(v) }
        else if let v = try? container.decode([AnyCodableValue].self) { self = .array(v) }
        else if let v = try? container.decode([String: AnyCodableValue].self) { self = .object(v) }
        else { self = .null }
    }

    /// Converts an arbitrary Foundation value (from JSONSerialization) to AnyCodableValue.
    static func from(_ value: Any) -> AnyCodableValue {
        switch value {
        case let s as String: return .string(s)
        case let b as Bool: return .bool(b)
        case let i as Int: return .int(i)
        case let d as Double: return .double(d)
        case let n as NSNumber: return .double(n.doubleValue)
        case let arr as [Any]: return .array(arr.map { from($0) })
        case let dict as [String: Any]: return .object(dict.mapValues { from($0) })
        case is NSNull: return .null
        default: return .string(String(describing: value))
        }
    }
}

// MARK: - JSON-RPC Response Types

struct ParsedJSONRPCResponse {
    let id: Int?
    let result: [String: Any]?
    let error: ParsedJSONRPCError?
}

struct ParsedJSONRPCError {
    let code: Int
    let message: String
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
struct OAuthServerMetadata: Decodable {
    let issuer: String?
    let authorization_endpoint: String
    let token_endpoint: String
    let registration_endpoint: String?
    let scopes_supported: [String]?
    let response_types_supported: [String]?
    let code_challenge_methods_supported: [String]?
}

/// Protected resource metadata (RFC 9728).
struct ProtectedResourceMetadata: Decodable {
    let resource: String?
    let authorization_servers: [String]?
}

/// Dynamic client registration response (RFC 7591).
struct ClientRegistrationResponse: Decodable {
    let client_id: String
    let client_secret: String?
    let client_id_issued_at: Int?
}

/// Token endpoint response.
struct TokenResponse: Decodable {
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
