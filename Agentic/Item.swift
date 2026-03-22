//
//  Item.swift
//  Agentic
//
//  Created by Ben Milford on 15/03/2026.
//

import Foundation
import SwiftData

@Model
final class GraphDocument {
    @Attribute(.unique) var key: String
    var title: String?
    var goal: String?
    var snapshotData: Data
    var executionStateData: Data?
    var createdAt: Date?
    var updatedAt: Date

    init(
        key: String = UUID().uuidString,
        title: String? = "Untitled Task",
        goal: String? = "",
        snapshotData: Data,
        executionStateData: Data? = nil,
        createdAt: Date? = Date(),
        updatedAt: Date = Date()
    ) {
        self.key = key
        self.title = title
        self.goal = goal
        self.snapshotData = snapshotData
        self.executionStateData = executionStateData
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
