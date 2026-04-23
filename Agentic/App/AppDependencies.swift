import SwiftUI

protocol LiveProviderExecuting {
    var liveStatus: String { get }

    func execute(
        provider: APIKeyProvider,
        apiKey: String,
        request: LiveProviderTaskRequest,
        preferredModelID: String?
    ) async throws -> LiveProviderExecutionResult

    func resolveModel(
        for provider: APIKeyProvider,
        apiKey: String,
        preferredModelID: String?
    ) async throws -> String

    func makeClient(for provider: APIKeyProvider, apiKey: String) -> any GeminiServicing

    func fetchModels(provider: APIKeyProvider, apiKey: String) async throws -> [String]
}

struct DefaultLiveProviderExecutor: LiveProviderExecuting {
    var liveStatus: String {
        LiveProviderExecutionService.liveStatus
    }

    func execute(
        provider: APIKeyProvider,
        apiKey: String,
        request: LiveProviderTaskRequest,
        preferredModelID: String?
    ) async throws -> LiveProviderExecutionResult {
        try await LiveProviderExecutionService.execute(
            provider: provider,
            apiKey: apiKey,
            request: request,
            preferredModelID: preferredModelID
        )
    }

    func resolveModel(
        for provider: APIKeyProvider,
        apiKey: String,
        preferredModelID: String?
    ) async throws -> String {
        try await LiveProviderExecutionService.resolveModelPublic(
            for: provider,
            apiKey: apiKey,
            preferredModelID: preferredModelID
        )
    }

    func makeClient(for provider: APIKeyProvider, apiKey: String) -> any GeminiServicing {
        LiveProviderExecutionService.makeClientPublic(for: provider, apiKey: apiKey)
    }

    func fetchModels(provider: APIKeyProvider, apiKey: String) async throws -> [String] {
        try await LiveProviderExecutionService.fetchModels(provider: provider, apiKey: apiKey)
    }
}

private struct APIKeyStoreEnvironmentKey: EnvironmentKey {
    static let defaultValue: any APIKeyStoring = KeychainAPIKeyStore()
}

private struct ProviderModelStoreEnvironmentKey: EnvironmentKey {
    static let defaultValue: any ProviderModelPreferencesStoring = UserDefaultsProviderModelStore()
}

private struct LiveProviderExecutorEnvironmentKey: EnvironmentKey {
    static let defaultValue: any LiveProviderExecuting = DefaultLiveProviderExecutor()
}

/// Bundles the four app-level services that ViewModels need for LLM execution and key management.
/// Injected once via `ContentView.configureViewModelCallbacks()` — not passed on every call.
struct AppDependencies {
    let apiKeyStore: any APIKeyStoring
    let providerModelStore: any ProviderModelPreferencesStoring
    let liveProviderExecutor: any LiveProviderExecuting
    let mcpManager: MCPServerManager

    func loadAPIKey(for provider: APIKeyProvider) -> Result<String, WorkflowError> {
        do {
            let key = (try apiKeyStore.key(for: provider) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                return .failure(.missingAPIKey(provider: provider))
            }
            return .success(key)
        } catch {
            return .failure(.apiKeyReadFailed(provider: provider, underlying: error))
        }
    }

    func availableProviders() -> [APIKeyProvider] {
        APIKeyProvider.allCases.filter {
            if case .success = loadAPIKey(for: $0) { return true }
            return false
        }
    }

    /// Produces a lookup used by the structure parser to expand tool references
    /// written by the Copilot into the full set of tools for a server.
    ///
    /// Picking the right specific tool has proven unreliable in practice —
    /// the Copilot sometimes picks a sibling tool on the same server, or
    /// fails to pick anything. To make the UX robust we auto-expand: if the
    /// Copilot names EITHER a server or any tool whose name is uniquely owned
    /// by one server, the node ends up with every tool on that server
    /// assigned. Users can then narrow the selection in the inspector.
    ///
    /// Ambiguous tool names (the same name on ≥2 servers — e.g. `get_project`
    /// is on Publisher, Vercel, Supabase) are intentionally omitted from the
    /// map so they don't cross-contaminate across servers. They pass through
    /// unchanged and the inspector's disambiguation heuristic handles them.
    func makeServerToolExpansionMap(connections: [MCPServerConnection]) -> [String: [String]] {
        var toolOwners: [String: [UUID]] = [:]
        var namesByConnection: [UUID: [String]] = [:]

        for connection in connections where connection.isEnabled {
            let tools = mcpManager.discoveredTools[connection.id] ?? mcpManager.cachedTools(for: connection.id)
            guard !tools.isEmpty else { continue }
            let names = tools.map(\.name)
            namesByConnection[connection.id] = names
            for name in names {
                toolOwners[name.lowercased(), default: []].append(connection.id)
            }
        }

        var result: [String: [String]] = [:]
        for connection in connections where connection.isEnabled {
            guard let names = namesByConnection[connection.id] else { continue }
            result[connection.name.lowercased()] = names
            for name in names {
                let key = name.lowercased()
                // Only map tool name → server tools when exactly one server
                // owns that tool name — otherwise expansion is ambiguous.
                if toolOwners[key]?.count == 1, result[key] == nil {
                    result[key] = names
                }
            }
        }
        return result
    }
}

extension EnvironmentValues {
    var apiKeyStore: any APIKeyStoring {
        get { self[APIKeyStoreEnvironmentKey.self] }
        set { self[APIKeyStoreEnvironmentKey.self] = newValue }
    }

    var providerModelStore: any ProviderModelPreferencesStoring {
        get { self[ProviderModelStoreEnvironmentKey.self] }
        set { self[ProviderModelStoreEnvironmentKey.self] = newValue }
    }

    var liveProviderExecutor: any LiveProviderExecuting {
        get { self[LiveProviderExecutorEnvironmentKey.self] }
        set { self[LiveProviderExecutorEnvironmentKey.self] = newValue }
    }
}
