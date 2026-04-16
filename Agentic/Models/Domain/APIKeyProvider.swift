import Foundation

enum APIKeyProvider: String, CaseIterable, Identifiable {
    case chatGPT
    case gemini
    case claude
    case grok

    var id: String { rawValue }

    var label: String {
        switch self {
        case .chatGPT:
            return "ChatGPT (OpenAI)"
        case .gemini:
            return "Gemini"
        case .claude:
            return "Claude (Anthropic)"
        case .grok:
            return "Grok (xAI)"
        }
    }

    var placeholder: String {
        switch self {
        case .chatGPT:
            return "OpenAI API key"
        case .gemini:
            return "Gemini API key"
        case .claude:
            return "Anthropic API key"
        case .grok:
            return "xAI API key"
        }
    }

    var account: String {
        "provider.\(rawValue).apiKey"
    }
}

protocol APIKeyStoring {
    func key(for provider: APIKeyProvider) throws -> String?
    func setKey(_ key: String, for provider: APIKeyProvider) throws
    func removeKey(for provider: APIKeyProvider) throws
}

protocol ProviderModelPreferencesStoring {
    func cachedModels(for provider: APIKeyProvider) -> [String]
    func persistCachedModels(_ models: [String], for provider: APIKeyProvider)
    func defaultModel(for provider: APIKeyProvider) -> String?
    func persistDefaultModel(_ modelID: String?, for provider: APIKeyProvider)
}

struct UserDefaultsProviderModelStore: ProviderModelPreferencesStoring {
    private let defaults: UserDefaults
    private let cachePrefix = "api.provider.models."
    private let defaultPrefix = "api.provider.defaultModel."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func cachedModels(for provider: APIKeyProvider) -> [String] {
        defaults.stringArray(forKey: cachePrefix + provider.rawValue) ?? []
    }

    func persistCachedModels(_ models: [String], for provider: APIKeyProvider) {
        let normalized = Array(Set(models)).sorted()
        defaults.set(normalized, forKey: cachePrefix + provider.rawValue)
    }

    func defaultModel(for provider: APIKeyProvider) -> String? {
        defaults.string(forKey: defaultPrefix + provider.rawValue)
    }

    func persistDefaultModel(_ modelID: String?, for provider: APIKeyProvider) {
        defaults.set(modelID, forKey: defaultPrefix + provider.rawValue)
    }
}

struct KeychainAPIKeyStore: APIKeyStoring {
    private let keychain: KeychainStore

    init(service: String = "com.moosia.Agentic") {
        self.keychain = KeychainStore(service: service)
    }

    func key(for provider: APIKeyProvider) throws -> String? {
        try keychain.string(for: provider.account)
    }

    func setKey(_ key: String, for provider: APIKeyProvider) throws {
        try keychain.setString(key, for: provider.account)
    }

    func removeKey(for provider: APIKeyProvider) throws {
        try keychain.removeValue(for: provider.account)
    }
}
