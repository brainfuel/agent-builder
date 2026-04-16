import SwiftUI

// MARK: - Structure Chat Response Parsing

enum GenerateStructureError: LocalizedError {
    case invalidJSON(String)
    case emptyStructure

    var errorDescription: String? {
        switch self {
        case .invalidJSON(let detail):
            return "Invalid response format: \(detail)"
        case .emptyStructure:
            return "The model returned an empty structure with no nodes."
        }
    }
}

enum StructureChatTurnResult {
    case chat(String)
    case update(message: String, snapshot: HierarchySnapshot)
}

final class UndoClosureTarget: NSObject {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    @objc
    func invoke() {
        action()
    }
}

enum StructureChatMessageRole: String, Codable {
    case user
    case assistant
}

struct StructureChatMessageEntry: Codable, Identifiable {
    let id: UUID
    let role: StructureChatMessageRole
    let text: String
    let createdAt: Date
    let appliedStructureUpdate: Bool
    let rawResponse: String?

    init(
        id: UUID = UUID(),
        role: StructureChatMessageRole,
        text: String,
        createdAt: Date = Date(),
        appliedStructureUpdate: Bool = false,
        rawResponse: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.appliedStructureUpdate = appliedStructureUpdate
        self.rawResponse = rawResponse
    }
}

struct StructureChatStateBundle: Codable {
    var messages: [StructureChatMessageEntry]
    var providerRaw: String
}

struct StructureChatProviderDebugResult {
    let provider: APIKeyProvider
    let preferredModelID: String?
    let resolvedModelID: String?
    let responseText: String?
    let errorMessage: String?
}

struct StructureChatResponseEnvelope: Decodable {
    let mode: String?
    let message: String?
    let structure: GeneratedStructureResponse?
    let nodes: [GeneratedNode]?
    let links: [GeneratedLink]?
}

struct GeneratedStructureResponse: Codable {
    let nodes: [GeneratedNode]
    let links: [GeneratedLink]
}

struct GeneratedNode: Codable {
    let id: String
    let name: String
    let title: String?
    let department: String?
    let type: String
    let provider: String
    let roleDescription: String?
    let outputSchema: String?
    let outputSchemaDescription: String?
    let securityAccess: [String]?
    let assignedTools: [String]?
    let positionX: CGFloat?
    let positionY: CGFloat?

    /// Parse the string UUID, falling back to a deterministic new UUID.
    var parsedID: UUID {
        UUID(uuidString: id) ?? UUID()
    }
}

struct GeneratedLink: Codable {
    let fromID: String
    let toID: String
    let tone: String?
}
