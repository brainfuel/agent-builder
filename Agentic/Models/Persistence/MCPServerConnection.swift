import Foundation
import SwiftData

@Model
final class MCPServerConnection {
    @Attribute(.unique) var id: UUID
    var name: String
    var url: String
    var apiKey: String
    var icon: String
    var category: String
    var serverDescription: String
    var isEnabled: Bool
    var addedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        url: String,
        apiKey: String = "",
        icon: String = "server.rack",
        category: String = "General",
        serverDescription: String = "",
        isEnabled: Bool = false,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.apiKey = apiKey
        self.icon = icon
        self.category = category
        self.serverDescription = serverDescription
        self.isEnabled = isEnabled
        self.addedAt = addedAt
    }
}
