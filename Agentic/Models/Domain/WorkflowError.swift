import Foundation

enum WorkflowError: LocalizedError {
    case missingAPIKey(provider: APIKeyProvider)
    case apiKeyReadFailed(provider: APIKeyProvider, underlying: Error)
    case modelResolutionFailed(provider: APIKeyProvider, underlying: Error)
    case streamFailed(provider: APIKeyProvider, underlying: Error)
    case emptyModelResponse(provider: APIKeyProvider)
    case providerExecutionFailed(provider: APIKeyProvider, underlying: Error)
    case persistenceFailed(operation: String, underlying: Error)
    case encodingFailed(operation: String, underlying: Error)
    case decodingFailed(operation: String, underlying: Error)

    var errorDescription: String? { userMessage }

    var userMessage: String {
        switch self {
        case .missingAPIKey(let provider):
            return "No API key found for \(provider.label). Add one in Keys first."
        case .apiKeyReadFailed(let provider, _):
            return "Could not read the \(provider.label) API key."
        case .modelResolutionFailed(let provider, _):
            return "Could not resolve a model for \(provider.label)."
        case .streamFailed(let provider, _):
            return "\(provider.label) did not return a valid response."
        case .emptyModelResponse(let provider):
            return "\(provider.label) returned an empty response."
        case .providerExecutionFailed(let provider, _):
            return "Live run failed for \(provider.label)."
        case .persistenceFailed(let operation, _):
            return "Could not save changes (\(operation))."
        case .encodingFailed(let operation, _):
            return "Could not encode data (\(operation))."
        case .decodingFailed(let operation, _):
            return "Could not restore saved data (\(operation))."
        }
    }

    var debugMessage: String {
        switch self {
        case .missingAPIKey:
            return userMessage
        case .apiKeyReadFailed(_, let underlying),
                .modelResolutionFailed(_, let underlying),
                .streamFailed(_, let underlying),
                .providerExecutionFailed(_, let underlying),
                .persistenceFailed(_, let underlying),
                .encodingFailed(_, let underlying),
                .decodingFailed(_, let underlying):
            return "\(userMessage) \(underlying.localizedDescription)"
        case .emptyModelResponse:
            return userMessage
        }
    }
}
