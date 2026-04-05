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
    var structureStrategy: String?
    var snapshotData: Data
    var executionStateData: Data?
    var createdAt: Date?
    var updatedAt: Date

    init(
        key: String = UUID().uuidString,
        title: String? = "Untitled Task",
        goal: String? = "",
        structureStrategy: String? = "",
        snapshotData: Data,
        executionStateData: Data? = nil,
        createdAt: Date? = Date(),
        updatedAt: Date = Date()
    ) {
        self.key = key
        self.title = title
        self.goal = goal
        self.structureStrategy = structureStrategy
        self.snapshotData = snapshotData
        self.executionStateData = executionStateData
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

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
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
