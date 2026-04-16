import Foundation

/// Tracks LLM token usage per provider for cost estimation.
final class UsageTracker: @unchecked Sendable {
    static let shared = UsageTracker()

    private let lock = NSLock()
    private let storageKey = "usage.records"
    private let maxAge: TimeInterval = 30 * 24 * 3600 // 30 days

    struct UsageRecord: Codable {
        let provider: String
        let modelID: String
        let inputTokens: Int
        let outputTokens: Int
        let timestamp: Date
    }

    /// Records a completed LLM call's token usage.
    func record(provider: APIKeyProvider, modelID: String, inputTokens: Int, outputTokens: Int) {
        guard inputTokens > 0 || outputTokens > 0 else { return }
        let record = UsageRecord(
            provider: provider.rawValue,
            modelID: modelID,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            timestamp: Date()
        )

        lock.lock()
        var records = loadRecords()
        records.append(record)
        saveRecords(records)
        lock.unlock()
    }

    /// Returns estimated cost for a provider over the last N days.
    func estimatedCost(for provider: APIKeyProvider, days: Int = 7) -> Double {
        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 3600)
        lock.lock()
        let records = loadRecords().filter {
            $0.provider == provider.rawValue && $0.timestamp >= cutoff
        }
        lock.unlock()

        var total: Double = 0
        for record in records {
            let pricing = Self.pricing(for: record.modelID, provider: provider)
            total += Double(record.inputTokens) / 1_000_000 * pricing.inputPerMillion
            total += Double(record.outputTokens) / 1_000_000 * pricing.outputPerMillion
        }
        return total
    }

    /// Returns token totals for a provider over the last N days.
    func tokenTotals(for provider: APIKeyProvider, days: Int = 7) -> (input: Int, output: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 3600)
        lock.lock()
        let records = loadRecords().filter {
            $0.provider == provider.rawValue && $0.timestamp >= cutoff
        }
        lock.unlock()

        let input = records.reduce(0) { $0 + $1.inputTokens }
        let output = records.reduce(0) { $0 + $1.outputTokens }
        return (input, output)
    }

    /// Prunes records older than maxAge.
    func pruneOldRecords() {
        let cutoff = Date().addingTimeInterval(-maxAge)
        lock.lock()
        var records = loadRecords()
        records.removeAll { $0.timestamp < cutoff }
        saveRecords(records)
        lock.unlock()
    }

    // MARK: - Persistence

    private func loadRecords() -> [UsageRecord] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let records = try? JSONDecoder().decode([UsageRecord].self, from: data) else {
            return []
        }
        return records
    }

    private func saveRecords(_ records: [UsageRecord]) {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    // MARK: - Pricing (per million tokens, USD)

    private struct TokenPricing {
        let inputPerMillion: Double
        let outputPerMillion: Double
    }

    /// Returns approximate pricing for a model. Falls back to provider defaults.
    private static func pricing(for modelID: String, provider: APIKeyProvider) -> TokenPricing {
        let id = modelID.lowercased()

        // OpenAI
        if id.contains("gpt-4o-mini") {
            return TokenPricing(inputPerMillion: 0.15, outputPerMillion: 0.60)
        }
        if id.contains("gpt-4o") || id.contains("gpt-4.1") {
            return TokenPricing(inputPerMillion: 2.50, outputPerMillion: 10.00)
        }
        if id.contains("gpt-4.5") {
            return TokenPricing(inputPerMillion: 75.00, outputPerMillion: 150.00)
        }
        if id.contains("gpt-5") || id.contains("gpt-5.3") {
            return TokenPricing(inputPerMillion: 2.50, outputPerMillion: 10.00)
        }
        if id.contains("o3-mini") {
            return TokenPricing(inputPerMillion: 1.10, outputPerMillion: 4.40)
        }
        if id.contains("o3") || id.contains("o4-mini") {
            return TokenPricing(inputPerMillion: 1.10, outputPerMillion: 4.40)
        }

        // Anthropic
        if id.contains("claude-3-5-haiku") || id.contains("claude-3.5-haiku") {
            return TokenPricing(inputPerMillion: 0.80, outputPerMillion: 4.00)
        }
        if id.contains("claude-3-5-sonnet") || id.contains("claude-3.5-sonnet") {
            return TokenPricing(inputPerMillion: 3.00, outputPerMillion: 15.00)
        }
        if id.contains("claude-sonnet") || id.contains("claude-4-sonnet") {
            return TokenPricing(inputPerMillion: 3.00, outputPerMillion: 15.00)
        }
        if id.contains("claude-opus") || id.contains("claude-4-opus") {
            return TokenPricing(inputPerMillion: 15.00, outputPerMillion: 75.00)
        }

        // Gemini
        if id.contains("gemini-2.0-flash") || id.contains("gemini-2.5-flash") {
            return TokenPricing(inputPerMillion: 0.10, outputPerMillion: 0.40)
        }
        if id.contains("gemini-2.5-pro") || id.contains("gemini-2.0-pro") {
            return TokenPricing(inputPerMillion: 1.25, outputPerMillion: 10.00)
        }
        if id.contains("gemini-1.5-pro") {
            return TokenPricing(inputPerMillion: 1.25, outputPerMillion: 5.00)
        }
        if id.contains("gemini-1.5-flash") {
            return TokenPricing(inputPerMillion: 0.075, outputPerMillion: 0.30)
        }

        // Grok (xAI)
        if id.contains("grok-3-mini") {
            return TokenPricing(inputPerMillion: 0.30, outputPerMillion: 0.50)
        }
        if id.contains("grok-3") {
            return TokenPricing(inputPerMillion: 3.00, outputPerMillion: 15.00)
        }
        if id.contains("grok-2") {
            return TokenPricing(inputPerMillion: 2.00, outputPerMillion: 10.00)
        }

        // Provider-level fallbacks
        switch provider {
        case .chatGPT:
            return TokenPricing(inputPerMillion: 2.50, outputPerMillion: 10.00)
        case .gemini:
            return TokenPricing(inputPerMillion: 0.50, outputPerMillion: 1.50)
        case .claude:
            return TokenPricing(inputPerMillion: 3.00, outputPerMillion: 15.00)
        case .grok:
            return TokenPricing(inputPerMillion: 3.00, outputPerMillion: 15.00)
        }
    }
}
