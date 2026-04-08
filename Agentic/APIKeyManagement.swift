import SwiftUI
import Security

enum AppTheme {
    static let brandTint = Color(red: 76.0 / 255.0, green: 117.0 / 255.0, blue: 161.0 / 255.0)
}

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

struct APIKeysSheet: View {
    let store: any APIKeyStoring
    let modelStore: any ProviderModelPreferencesStoring

    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [APIKeyProvider: String] = [:]
    @State private var savedProviders: Set<APIKeyProvider> = []
    @State private var revealedProviders: Set<APIKeyProvider> = []
    @State private var availableModelsByProvider: [APIKeyProvider: [String]] = [:]
    @State private var selectedModelByProvider: [APIKeyProvider: String] = [:]
    @State private var loadingProviders: Set<APIKeyProvider> = []
    @State private var feedbackMessage: String?
    @State private var feedbackIsError = false

    init(
        store: any APIKeyStoring,
        modelStore: any ProviderModelPreferencesStoring = UserDefaultsProviderModelStore()
    ) {
        self.store = store
        self.modelStore = modelStore
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Store provider keys securely in Keychain. This can be swapped for a different store when merged into another app.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    ForEach(APIKeyProvider.allCases) { provider in
                        providerRow(provider)
                    }

                    if let feedbackMessage {
                        Text(feedbackMessage)
                            .font(.footnote)
                            .foregroundStyle(feedbackIsError ? .red : .secondary)
                            .padding(.top, 4)
                    }
                }
                .padding(20)
            }
            .navigationTitle("API Keys")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
        .onAppear(perform: loadStoredState)
    }

    private func providerRow(_ provider: APIKeyProvider) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(provider.label)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if savedProviders.contains(provider) {
                    let cost = UsageTracker.shared.estimatedCost(for: provider, days: 7)
                    if cost > 0 {
                        Text("~$\(cost, specifier: "%.2f") / 7d")
                            .font(.caption2.weight(.medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.gray.opacity(0.12), in: Capsule())
                    }
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }

            HStack(spacing: 8) {
                Group {
                    if shouldShowStoredMask(for: provider) {
                        storedMaskField(provider)
                    } else if revealedProviders.contains(provider) {
                        TextField(provider.placeholder, text: binding(for: provider))
                    } else {
                        SecureField(provider.placeholder, text: binding(for: provider))
                    }
                }
                .modifier(APIKeyFieldStylingModifier())

                Button {
                    toggleReveal(for: provider)
                } label: {
                    Image(systemName: revealedProviders.contains(provider) ? "eye.slash" : "eye")
                }
                .buttonStyle(.bordered)

                Button("Save") {
                    saveKey(for: provider)
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimmedValue(for: provider).isEmpty)

                Button("Clear", role: .destructive) {
                    clearKey(for: provider)
                }
                .buttonStyle(.bordered)
                .disabled(!savedProviders.contains(provider) && trimmedValue(for: provider).isEmpty)
            }

            HStack(spacing: 8) {
                Button {
                    Task { await loadModels(for: provider, reportErrors: true) }
                } label: {
                    if loadingProviders.contains(provider) {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading…")
                        }
                    } else {
                        Label("Load Models", systemImage: "arrow.down.circle")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(loadingProviders.contains(provider) || !savedProviders.contains(provider))

                Menu {
                    let models = availableModels(for: provider)
                    if models.isEmpty {
                        Button("No models loaded") {}
                            .disabled(true)
                    } else {
                        ForEach(models, id: \.self) { model in
                            Button {
                                selectModel(model, for: provider)
                            } label: {
                                HStack {
                                    Text(model)
                                    if selectedModelByProvider[provider] == model {
                                        Spacer()
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    Label(
                        selectedModelByProvider[provider] ?? "Default Model",
                        systemImage: "chevron.up.chevron.down"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(availableModels(for: provider).isEmpty)

                Spacer()
            }

            if savedProviders.contains(provider), trimmedValue(for: provider).isEmpty {
                Text("Stored securely in Keychain. Enter a new key to replace.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }

    private func loadStoredState() {
        var nextSaved: Set<APIKeyProvider> = []
        for provider in APIKeyProvider.allCases {
            let value = try? store.key(for: provider)
            if let value, !value.isEmpty {
                nextSaved.insert(provider)
            }
            drafts[provider] = ""
            let cached = modelStore.cachedModels(for: provider)
            availableModelsByProvider[provider] = cached
            if let persistedDefault = modelStore.defaultModel(for: provider), cached.contains(persistedDefault) {
                selectedModelByProvider[provider] = persistedDefault
            } else if let first = cached.first {
                selectedModelByProvider[provider] = first
                modelStore.persistDefaultModel(first, for: provider)
            }
        }
        savedProviders = nextSaved
    }

    private func binding(for provider: APIKeyProvider) -> Binding<String> {
        Binding(
            get: { drafts[provider] ?? "" },
            set: { drafts[provider] = $0 }
        )
    }

    private func trimmedValue(for provider: APIKeyProvider) -> String {
        (drafts[provider] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func toggleReveal(for provider: APIKeyProvider) {
        if revealedProviders.contains(provider) {
            revealedProviders.remove(provider)
            if savedProviders.contains(provider) {
                drafts[provider] = ""
            }
        } else {
            if savedProviders.contains(provider), trimmedValue(for: provider).isEmpty {
                if let stored = storedKey(for: provider), !stored.isEmpty {
                    drafts[provider] = stored
                }
            }
            revealedProviders.insert(provider)
        }
    }

    private func saveKey(for provider: APIKeyProvider) {
        let key = trimmedValue(for: provider)
        guard !key.isEmpty else { return }
        do {
            try store.setKey(key, for: provider)
            savedProviders.insert(provider)
            drafts[provider] = key
            feedbackMessage = "\(provider.label) key saved."
            feedbackIsError = false
            Task { await loadModels(for: provider, reportErrors: false) }
        } catch {
            feedbackMessage = error.localizedDescription
            feedbackIsError = true
        }
    }

    private func clearKey(for provider: APIKeyProvider) {
        do {
            try store.removeKey(for: provider)
            savedProviders.remove(provider)
            drafts[provider] = ""
            availableModelsByProvider[provider] = []
            selectedModelByProvider[provider] = nil
            modelStore.persistCachedModels([], for: provider)
            modelStore.persistDefaultModel(nil, for: provider)
            feedbackMessage = "\(provider.label) key removed."
            feedbackIsError = false
        } catch {
            feedbackMessage = error.localizedDescription
            feedbackIsError = true
        }
    }

    private func availableModels(for provider: APIKeyProvider) -> [String] {
        availableModelsByProvider[provider] ?? []
    }

    private func selectModel(_ modelID: String, for provider: APIKeyProvider) {
        selectedModelByProvider[provider] = modelID
        modelStore.persistDefaultModel(modelID, for: provider)
        feedbackMessage = "\(provider.label) default model set to \(modelID)."
        feedbackIsError = false
    }

    @MainActor
    private func loadModels(for provider: APIKeyProvider, reportErrors: Bool) async {
        guard savedProviders.contains(provider) else { return }
        loadingProviders.insert(provider)
        defer { loadingProviders.remove(provider) }

        let key = storedKey(for: provider)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else { return }

        do {
            let fetched = try await LiveProviderExecutionService.fetchModels(provider: provider, apiKey: key)
            let normalized = Array(Set(fetched)).sorted()
            availableModelsByProvider[provider] = normalized
            modelStore.persistCachedModels(normalized, for: provider)

            let current = selectedModelByProvider[provider]
            if let current, normalized.contains(current) {
                modelStore.persistDefaultModel(current, for: provider)
            } else if let persisted = modelStore.defaultModel(for: provider), normalized.contains(persisted) {
                selectedModelByProvider[provider] = persisted
            } else if let first = normalized.first {
                selectedModelByProvider[provider] = first
                modelStore.persistDefaultModel(first, for: provider)
            } else {
                selectedModelByProvider[provider] = nil
                modelStore.persistDefaultModel(nil, for: provider)
            }

            feedbackMessage = normalized.isEmpty
                ? "No models returned for \(provider.label)."
                : "Loaded \(normalized.count) models for \(provider.label)."
            feedbackIsError = false
        } catch {
            guard reportErrors else { return }
            if let urlError = error as? URLError, urlError.code == .cannotFindHost {
                feedbackMessage = "Could not resolve provider host. Check internet access/VPN/DNS and make sure the app is rebuilt after enabling network entitlement."
            } else {
                feedbackMessage = error.localizedDescription
            }
            feedbackIsError = true
        }
    }

    private func shouldShowStoredMask(for provider: APIKeyProvider) -> Bool {
        savedProviders.contains(provider)
            && !revealedProviders.contains(provider)
            && trimmedValue(for: provider).isEmpty
    }

    @ViewBuilder
    private func storedMaskField(_ provider: APIKeyProvider) -> some View {
        HStack(spacing: 8) {
            Text(maskedStoredPlaceholder(for: provider))
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(uiColor: .systemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(uiColor: .separator), lineWidth: 1)
                )
        )
        .accessibilityLabel("\(provider.label) API key is saved and masked")
    }

    private func maskedStoredPlaceholder(for provider: APIKeyProvider) -> String {
        if let stored = storedKey(for: provider), !stored.isEmpty {
            let count = min(max(stored.count, 8), 24)
            return String(repeating: "•", count: count)
        }
        return "••••••••••••"
    }

    private func storedKey(for provider: APIKeyProvider) -> String? {
        do {
            return try store.key(for: provider)
        } catch {
            return nil
        }
    }
}

private struct APIKeyFieldStylingModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.roundedBorder)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .textContentType(.oneTimeCode)
    }
}

struct KeychainStore {
    let service: String

    private struct CacheKey: Hashable {
        let service: String
        let account: String
    }

    private enum CacheEntry {
        case value(String)
        case missing
    }

    private static let cacheLock = NSLock()
    private static var cache: [CacheKey: CacheEntry] = [:]

    init(service: String) {
        self.service = service
    }

    func string(for account: String) throws -> String? {
        let cacheKey = CacheKey(service: service, account: account)
        if let cached = Self.cachedEntry(for: cacheKey) {
            switch cached {
            case .value(let value):
                return value
            case .missing:
                return nil
            }
        }

        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
                throw KeychainStoreError.unexpectedData
            }
            Self.storeCache(entry: .value(value), for: cacheKey)
            return value
        case errSecItemNotFound:
            Self.storeCache(entry: .missing, for: cacheKey)
            return nil
        default:
            throw KeychainStoreError.unexpectedStatus(status, operation: "read")
        }
    }

    func setString(_ value: String, for account: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account: account)
        let cacheKey = CacheKey(service: service, account: account)

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let attributesToUpdate = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainStoreError.unexpectedStatus(updateStatus, operation: "update")
            }
            Self.storeCache(entry: .value(value), for: cacheKey)
            return
        }

        guard addStatus == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(addStatus, operation: "add")
        }
        Self.storeCache(entry: .value(value), for: cacheKey)
    }

    func removeValue(for account: String) throws {
        let cacheKey = CacheKey(service: service, account: account)
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status, operation: "delete")
        }
        Self.storeCache(entry: .missing, for: cacheKey)
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static func cachedEntry(for key: CacheKey) -> CacheEntry? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache[key]
    }

    private static func storeCache(entry: CacheEntry, for key: CacheKey) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache[key] = entry
    }
}

enum KeychainStoreError: LocalizedError {
    case unexpectedData
    case unexpectedStatus(OSStatus, operation: String)

    var errorDescription: String? {
        switch self {
        case .unexpectedData:
            return "Keychain data had an unexpected format."
        case .unexpectedStatus(let status, let operation):
            if status == errSecMissingEntitlement {
                return "Keychain \(operation) failed (\(status)): missing entitlement. In Xcode, enable Signing for this target and add the Keychain Sharing capability."
            }
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
            return "Keychain \(operation) failed (\(status)): \(message)"
        }
    }
}
