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
    var snapshotData: Data
    var executionStateData: Data?
    var updatedAt: Date

    init(
        key: String = "active",
        snapshotData: Data,
        executionStateData: Data? = nil,
        updatedAt: Date = Date()
    ) {
        self.key = key
        self.snapshotData = snapshotData
        self.executionStateData = executionStateData
        self.updatedAt = updatedAt
    }
}
