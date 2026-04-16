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

    func makeServerToolExpansionMap(connections: [MCPServerConnection]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for connection in connections where connection.isEnabled {
            let tools = mcpManager.discoveredTools[connection.id] ?? mcpManager.cachedTools(for: connection.id)
            if !tools.isEmpty {
                result[connection.name.lowercased()] = tools.map(\.name)
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
