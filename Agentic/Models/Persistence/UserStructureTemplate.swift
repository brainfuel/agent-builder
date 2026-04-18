import Foundation
import SwiftData

/// Persisted user-created structure template — a named snapshot of the whole team hierarchy.
@Model
final class UserStructureTemplate {
    @Attribute(.unique) var id: UUID
    var name: String
    var snapshotData: Data
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        snapshotData: Data,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.snapshotData = snapshotData
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
