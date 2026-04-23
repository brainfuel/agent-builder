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

    /// Transport kind. "http" (default, existing behaviour) or "stdio" (macOS only).
    /// Stored as a string so SwiftData lightweight migration keeps old records loading.
    var transport: String = "http"
    /// Absolute path to a local executable when `transport == "stdio"`.
    var command: String = ""
    /// Space-separated CLI arguments passed to the stdio command.
    var arguments: String = ""

    init(
        id: UUID = UUID(),
        name: String,
        url: String = "",
        apiKey: String = "",
        icon: String = "server.rack",
        category: String = "General",
        serverDescription: String = "",
        isEnabled: Bool = false,
        addedAt: Date = Date(),
        transport: String = "http",
        command: String = "",
        arguments: String = ""
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
        self.transport = transport
        self.command = command
        self.arguments = arguments
    }

    /// Convenience: is this a local (stdio) connection?
    var isStdio: Bool { transport == "stdio" }
}
