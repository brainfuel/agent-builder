import Foundation

// Compatibility models used by provider clients imported from AI Tools.
enum MessageRole: String, Codable {
    case user
    case assistant
}

struct AttachmentSummary: Identifiable, Codable {
    let id: UUID
    let name: String
    let mimeType: String?
    let previewBase64Data: String?

    init(
        id: UUID = UUID(),
        name: String,
        mimeType: String? = nil,
        previewBase64Data: String? = nil
    ) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.previewBase64Data = previewBase64Data
    }
}

enum GeneratedMediaKind: String, Codable {
    case image
    case audio
    case video
    case pdf
    case text
    case json
    case csv
    case file
}

struct GeneratedMedia: Identifiable, Codable {
    let id: UUID
    let kind: GeneratedMediaKind
    let mimeType: String
    let base64Data: String?
    let remoteURL: URL?

    init(
        id: UUID = UUID(),
        kind: GeneratedMediaKind,
        mimeType: String,
        base64Data: String? = nil,
        remoteURL: URL? = nil
    ) {
        self.id = id
        self.kind = kind
        self.mimeType = mimeType
        self.base64Data = base64Data
        self.remoteURL = remoteURL
    }
}

struct ChatMessage: Identifiable, Codable {
    let id: UUID
    let role: MessageRole
    let text: String
    let createdAt: Date?
    let attachments: [AttachmentSummary]
    let generatedMedia: [GeneratedMedia]
    let inputTokens: Int
    let outputTokens: Int
    let modelID: String?

    init(
        id: UUID = UUID(),
        role: MessageRole,
        text: String,
        createdAt: Date? = Date(),
        attachments: [AttachmentSummary] = [],
        generatedMedia: [GeneratedMedia] = [],
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        modelID: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.attachments = attachments
        self.generatedMedia = generatedMedia
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.modelID = modelID
    }
}

struct ModelReply {
    let text: String
    let generatedMedia: [GeneratedMedia]
    let inputTokens: Int
    let outputTokens: Int

    init(
        text: String,
        generatedMedia: [GeneratedMedia],
        inputTokens: Int = 0,
        outputTokens: Int = 0
    ) {
        self.text = text
        self.generatedMedia = generatedMedia
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

struct PendingAttachment: Identifiable {
    let id: UUID
    let name: String
    let mimeType: String
    let base64Data: String
    let previewJPEGData: Data?

    init(
        id: UUID = UUID(),
        name: String,
        mimeType: String,
        base64Data: String,
        previewJPEGData: Data? = nil
    ) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.base64Data = base64Data
        self.previewJPEGData = previewJPEGData
    }
}
