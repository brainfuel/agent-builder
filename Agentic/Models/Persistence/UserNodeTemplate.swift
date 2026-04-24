import Foundation
import SwiftData

@Model
final class UserNodeTemplate {
    // Dropped `@Attribute(.unique)` — CloudKit rejects unique constraints.
    // UUIDs are cryptographically unique in practice; duplicate IDs would only
    // appear as a CloudKit merge anomaly and should be deduplicated on read.
    var id: UUID = UUID()
    var label: String = ""
    var icon: String = "star"
    var name: String = ""
    var title: String = ""
    var department: String = ""
    var nodeTypeRaw: String = ""
    var providerRaw: String = ""
    var roleDescription: String = ""
    var outputSchema: String = ""
    var outputSchemaDescription: String = ""
    var securityAccessRaw: [String] = []
    var assignedToolsRaw: [String] = []
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

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
