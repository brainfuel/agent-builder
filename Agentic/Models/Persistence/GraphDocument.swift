import Foundation
import SwiftData

@Model
final class GraphDocument {
    @Attribute(.unique) var key: String
    var title: String?
    var goal: String?
    var structureStrategy: String?
    var snapshotData: Data
    var executionStateData: Data?
    var structureChatData: Data?
    var createdAt: Date?
    var updatedAt: Date
    var scrollOffsetX: Double?
    var scrollOffsetY: Double?

    init(
        key: String = UUID().uuidString,
        title: String? = "Untitled Task",
        goal: String? = "",
        structureStrategy: String? = "",
        snapshotData: Data,
        executionStateData: Data? = nil,
        structureChatData: Data? = nil,
        createdAt: Date? = Date(),
        updatedAt: Date = Date(),
        scrollOffsetX: Double? = nil,
        scrollOffsetY: Double? = nil
    ) {
        self.key = key
        self.title = title
        self.goal = goal
        self.structureStrategy = structureStrategy
        self.snapshotData = snapshotData
        self.executionStateData = executionStateData
        self.structureChatData = structureChatData
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.scrollOffsetX = scrollOffsetX
        self.scrollOffsetY = scrollOffsetY
    }
}
