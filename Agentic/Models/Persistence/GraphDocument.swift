import Foundation
import SwiftData

@Model
final class GraphDocument {
    // Dropped `@Attribute(.unique)` — CloudKit does not allow unique constraints.
    // Uniqueness is enforced at the application level (see ContentView lookups by key).
    var key: String = ""
    var title: String?
    var goal: String?
    var context: String?
    var structureStrategy: String?
    var snapshotData: Data = Data()
    var executionStateData: Data?
    var structureChatData: Data?
    var createdAt: Date?
    var updatedAt: Date = Date()
    var scrollOffsetX: Double?
    var scrollOffsetY: Double?
    var zoom: Double?

    init(
        key: String = UUID().uuidString,
        title: String? = "Untitled Task",
        goal: String? = "",
        context: String? = "",
        structureStrategy: String? = "",
        snapshotData: Data,
        executionStateData: Data? = nil,
        structureChatData: Data? = nil,
        createdAt: Date? = Date(),
        updatedAt: Date = Date(),
        scrollOffsetX: Double? = nil,
        scrollOffsetY: Double? = nil,
        zoom: Double? = nil
    ) {
        self.key = key
        self.title = title
        self.goal = goal
        self.context = context
        self.structureStrategy = structureStrategy
        self.snapshotData = snapshotData
        self.executionStateData = executionStateData
        self.structureChatData = structureChatData
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.scrollOffsetX = scrollOffsetX
        self.scrollOffsetY = scrollOffsetY
        self.zoom = zoom
    }
}
