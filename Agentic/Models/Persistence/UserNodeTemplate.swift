import Foundation
import SwiftData

@Model
final class UserNodeTemplate {
    @Attribute(.unique) var id: UUID
    var label: String
    var icon: String
    var name: String
    var title: String
    var department: String
    var nodeTypeRaw: String
    var providerRaw: String
    var roleDescription: String
    var outputSchema: String
    var outputSchemaDescription: String
    var securityAccessRaw: [String]
    var assignedToolsRaw: [String] = []
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        label: String,
        icon: String = "star",
        name: String,
        title: String,
        department: String,
        nodeTypeRaw: String,
        providerRaw: String,
        roleDescription: String,
        outputSchema: String,
        outputSchemaDescription: String,
        securityAccessRaw: [String],
        assignedToolsRaw: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.label = label
        self.icon = icon
        self.name = name
        self.title = title
        self.department = department
        self.nodeTypeRaw = nodeTypeRaw
        self.providerRaw = providerRaw
        self.roleDescription = roleDescription
        self.outputSchema = outputSchema
        self.outputSchemaDescription = outputSchemaDescription
        self.securityAccessRaw = securityAccessRaw
        self.assignedToolsRaw = assignedToolsRaw
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
