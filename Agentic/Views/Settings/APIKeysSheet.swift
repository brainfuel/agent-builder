import SwiftUI

struct APIKeysSheet: View {
    var embedded: Bool = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.apiKeyStore) private var store
    @Environment(\.providerModelStore) private var modelStore
    @Environment(\.liveProviderExecutor) private var liveProviderExecutor
    @State private var drafts: [APIKeyProvider: String] = [:]
    @State private var savedProviders: Set<APIKeyProvider> = []
    @State private var revealedProviders: Set<APIKeyProvider> = []
    @State private var availableModelsByProvider: [APIKeyProvider: [String]] = [:]
    @State private var selectedModelByProvider: [APIKeyProvider: String] = [:]
    @State private var loadingProviders: Set<APIKeyProvider> = []
    @State private var feedbackMessage: String?
    @State private var feedbackIsError = false

    var body: some View {
        if embedded {
            apiKeysContent
                .onAppear(perform: loadStoredState)
        } else {
            NavigationStack {
                apiKeysContent
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
    }

    private var apiKeysContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !embedded {
                    Text("Store provider keys securely in Keychain. This can be swapped for a different store when merged into another app.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Provider API keys stored in Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

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
                .submitLabel(.done)
                .onSubmit {
                    saveKeyIfNeeded(for: provider)
                }

                Button {
                    toggleReveal(for: provider)
                } label: {
                    Image(systemName: revealedProviders.contains(provider) ? "eye.slash" : "eye")
                }
                .buttonStyle(.bordered)
            }

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    saveKeyIfNeeded(for: provider)
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
                .disabled(
                    loadingProviders.contains(provider)
                    || (!savedProviders.contains(provider) && trimmedValue(for: provider).isEmpty)
                )

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

    private func saveKeyIfNeeded(for provider: APIKeyProvider) {
        let key = trimmedValue(for: provider)
        guard !key.isEmpty else { return }
        let existing = storedKey(for: provider)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard existing != key else { return }
        saveKey(for: provider)
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
            let fetched = try await liveProviderExecutor.fetchModels(provider: provider, apiKey: key)
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
