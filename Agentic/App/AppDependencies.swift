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
