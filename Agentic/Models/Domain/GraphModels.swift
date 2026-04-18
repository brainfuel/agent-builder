import Foundation
import CoreGraphics

struct OrgNode: Identifiable {
    let id: UUID
    var name: String
    var title: String
    var department: String
    var type: NodeType
    var provider: LLMProvider
    var roleDescription: String
    var inputSchema: String
    var outputSchema: String
    var outputSchemaDescription: String
    var selectedRoles: Set<PresetRole>
    var securityAccess: Set<SecurityAccess>
    var assignedTools: Set<String> = []
    var position: CGPoint

    var initials: String {
        let words = name.split(separator: " ")
        let first = words.first?.first.map(String.init) ?? ""
        let second = words.dropFirst().first?.first.map(String.init) ?? ""
        return (first + second).uppercased()
    }

    static func placeholder(id: UUID) -> OrgNode {
        OrgNode(
            id: id,
            name: "",
            title: "",
            department: "",
            type: .agent,
            provider: .chatGPT,
            roleDescription: "",
            inputSchema: DefaultSchema.taskResult,
            outputSchema: DefaultSchema.taskResult,
            outputSchemaDescription: DefaultSchema.defaultDescription(for: DefaultSchema.taskResult),
            selectedRoles: [],
            securityAccess: [],
            position: .zero
        )
    }

    static let sample: [OrgNode] = [
        OrgNode(
            id: UUID(uuidString: "2F4C58B8-A0AA-4C2D-8D84-8F1476AE2129")!,
            name: "Input",
            title: "Entry Point",
            department: "System",
            type: .input,
            provider: .chatGPT,
            roleDescription: "Fixed start node for task inputs.",
            inputSchema: DefaultSchema.goalBrief,
            outputSchema: DefaultSchema.goalBrief,
            outputSchemaDescription: DefaultSchema.defaultDescription(for: DefaultSchema.goalBrief),
            selectedRoles: [],
            securityAccess: [],
            position: CGPoint(x: 950, y: 68)
        ),
        OrgNode(
            id: UUID(uuidString: "A5E8B12B-2207-43B4-B363-C6D0E0F55541")!,
            name: "Coordinator",
            title: "Root Supervisor",
            department: "Control Plane",
            type: .agent,
            provider: .chatGPT,
            roleDescription: "Routes goals into sub-workflows, enforces policy checks, and merges outputs.",
            inputSchema: DefaultSchema.goalBrief,
            outputSchema: DefaultSchema.strategyPlan,
            outputSchemaDescription: DefaultSchema.defaultDescription(for: DefaultSchema.strategyPlan),
            selectedRoles: [.coordinator, .reviewer],
            securityAccess: [.workspaceRead, .workspaceWrite, .secretsRead],
            position: CGPoint(x: 940, y: 120)
        ),
        OrgNode(
            id: UUID(uuidString: "C32A313D-5D44-4375-A3A2-7AA6B229BFCE")!,
            name: "Product Lead",
            title: "Human Sponsor",
            department: "Strategy",
            type: .human,
            provider: .chatGPT,
            roleDescription: "Defines intent, approves policy changes, and signs off production actions.",
            inputSchema: DefaultSchema.goalBrief,
            outputSchema: DefaultSchema.releaseDecision,
            outputSchemaDescription: DefaultSchema.defaultDescription(for: DefaultSchema.releaseDecision),
            selectedRoles: [.decisionMaker],
            securityAccess: [.workspaceRead, .auditLogs],
            position: CGPoint(x: 560, y: 280)
        ),
        OrgNode(
            id: UUID(uuidString: "E3D7D3CF-B0D5-4A8B-8FD4-994706A44512")!,
            name: "Research Agent",
            title: "Knowledge Scout",
            department: "Discovery",
            type: .agent,
            provider: .gemini,
            roleDescription: "Runs discovery queries, consolidates sources, and drafts evidence summaries.",
            inputSchema: DefaultSchema.strategyPlan,
            outputSchema: DefaultSchema.researchBrief,
            outputSchemaDescription: DefaultSchema.defaultDescription(for: DefaultSchema.researchBrief),
            selectedRoles: [.researcher],
            securityAccess: [.workspaceRead, .webAccess],
            assignedTools: ["web_search"],
            position: CGPoint(x: 940, y: 280)
        ),
        OrgNode(
            id: UUID(uuidString: "16F4A95B-94E1-45B0-B09E-4D0CF17CCAA4")!,
            name: "Execution Agent",
            title: "Task Operator",
            department: "Automation",
            type: .agent,
            provider: .claude,
            roleDescription: "Executes approved changes, runs commands, and reports diffs plus verification.",
            inputSchema: DefaultSchema.strategyPlan,
            outputSchema: DefaultSchema.buildPatch,
            outputSchemaDescription: DefaultSchema.defaultDescription(for: DefaultSchema.buildPatch),
            selectedRoles: [.executor, .planner],
            securityAccess: [.workspaceRead, .workspaceWrite, .terminalExec],
            position: CGPoint(x: 1320, y: 280)
        ),
        OrgNode(
            id: UUID(uuidString: "B4D2B27C-0C57-494C-89CA-61B8BE0064F7")!,
            name: "QA Agent",
            title: "Validation",
            department: "Quality",
            type: .agent,
            provider: .grok,
            roleDescription: "Runs test suites and static checks before actions are marked as complete.",
            inputSchema: DefaultSchema.buildPatch,
            outputSchema: DefaultSchema.validationReport,
            outputSchemaDescription: DefaultSchema.defaultDescription(for: DefaultSchema.validationReport),
            selectedRoles: [.reviewer],
            securityAccess: [.workspaceRead, .terminalExec],
            position: CGPoint(x: 760, y: 480)
        ),
        OrgNode(
            id: UUID(uuidString: "6246D613-DBB4-4D30-8168-08D0A1ED2BB3")!,
            name: "Security Officer",
            title: "Human Gatekeeper",
            department: "Security",
            type: .human,
            provider: .chatGPT,
            roleDescription: "Reviews privileged actions and controls secret/materialized access policies.",
            inputSchema: DefaultSchema.buildPatch,
            outputSchema: DefaultSchema.releaseDecision,
            outputSchemaDescription: DefaultSchema.defaultDescription(for: DefaultSchema.releaseDecision),
            selectedRoles: [.decisionMaker, .reviewer],
            securityAccess: [.auditLogs],
            position: CGPoint(x: 1120, y: 480)
        ),
        OrgNode(
            id: UUID(uuidString: "BB45A13F-F6AB-412A-BDC7-4A9852B8F2AA")!,
            name: "Reporting Agent",
            title: "Narrative Builder",
            department: "Comms",
            type: .agent,
            provider: .chatGPT,
            roleDescription: "Creates concise updates and incident summaries for stakeholders.",
            inputSchema: DefaultSchema.strategyPlan,
            outputSchema: DefaultSchema.taskResult,
            outputSchemaDescription: DefaultSchema.defaultDescription(for: DefaultSchema.taskResult),
            selectedRoles: [.summarizer],
            securityAccess: [.workspaceRead],
            position: CGPoint(x: 1500, y: 480)
        ),
        OrgNode(
            id: UUID(uuidString: "731E68C0-1D97-4FCA-9EED-EA5C8D13661D")!,
            name: "Ops Team",
            title: "Human Executor",
            department: "Operations",
            type: .human,
            provider: .chatGPT,
            roleDescription: "Handles real-world execution beyond automation boundaries.",
            inputSchema: DefaultSchema.validationReport,
            outputSchema: DefaultSchema.releaseDecision,
            outputSchemaDescription: DefaultSchema.defaultDescription(for: DefaultSchema.releaseDecision),
            selectedRoles: [.executor],
            securityAccess: [.workspaceRead],
            position: CGPoint(x: 940, y: 680)
        ),
        OrgNode(
            id: UUID(uuidString: "7F90796C-66A8-47D3-9A52-8AE3B3E931EF")!,
            name: "Output",
            title: "Final Result",
            department: "System",
            type: .output,
            provider: .chatGPT,
            roleDescription: "Fixed end node for final outputs.",
            inputSchema: DefaultSchema.taskResult,
            outputSchema: DefaultSchema.taskResult,
            outputSchemaDescription: DefaultSchema.defaultDescription(for: DefaultSchema.taskResult),
            selectedRoles: [],
            securityAccess: [],
            position: CGPoint(x: 950, y: 1132)
        )
    ]
}

struct NodeLink: Identifiable {
    let id: UUID
    let fromID: UUID
    let toID: UUID
    let tone: LinkTone
    let edgeType: EdgeType

    init(
        id: UUID = UUID(),
        fromID: UUID,
        toID: UUID,
        tone: LinkTone,
        edgeType: EdgeType = .primary
    ) {
        self.id = id
        self.fromID = fromID
        self.toID = toID
        self.tone = tone
        self.edgeType = edgeType
    }

    static let sample: [NodeLink] = [
        NodeLink(
            fromID: UUID(uuidString: "2F4C58B8-A0AA-4C2D-8D84-8F1476AE2129")!,
            toID: UUID(uuidString: "A5E8B12B-2207-43B4-B363-C6D0E0F55541")!,
            tone: .blue
        ),
        NodeLink(
            fromID: UUID(uuidString: "A5E8B12B-2207-43B4-B363-C6D0E0F55541")!,
            toID: UUID(uuidString: "C32A313D-5D44-4375-A3A2-7AA6B229BFCE")!,
            tone: .blue
        ),
        NodeLink(
            fromID: UUID(uuidString: "A5E8B12B-2207-43B4-B363-C6D0E0F55541")!,
            toID: UUID(uuidString: "E3D7D3CF-B0D5-4A8B-8FD4-994706A44512")!,
            tone: .blue
        ),
        NodeLink(
            fromID: UUID(uuidString: "A5E8B12B-2207-43B4-B363-C6D0E0F55541")!,
            toID: UUID(uuidString: "16F4A95B-94E1-45B0-B09E-4D0CF17CCAA4")!,
            tone: .blue
        ),
        NodeLink(
            fromID: UUID(uuidString: "E3D7D3CF-B0D5-4A8B-8FD4-994706A44512")!,
            toID: UUID(uuidString: "B4D2B27C-0C57-494C-89CA-61B8BE0064F7")!,
            tone: .orange
        ),
        NodeLink(
            fromID: UUID(uuidString: "E3D7D3CF-B0D5-4A8B-8FD4-994706A44512")!,
            toID: UUID(uuidString: "6246D613-DBB4-4D30-8168-08D0A1ED2BB3")!,
            tone: .orange
        ),
        NodeLink(
            fromID: UUID(uuidString: "16F4A95B-94E1-45B0-B09E-4D0CF17CCAA4")!,
            toID: UUID(uuidString: "BB45A13F-F6AB-412A-BDC7-4A9852B8F2AA")!,
            tone: .teal
        ),
        NodeLink(
            fromID: UUID(uuidString: "B4D2B27C-0C57-494C-89CA-61B8BE0064F7")!,
            toID: UUID(uuidString: "731E68C0-1D97-4FCA-9EED-EA5C8D13661D")!,
            tone: .orange
        ),
        NodeLink(
            fromID: UUID(uuidString: "731E68C0-1D97-4FCA-9EED-EA5C8D13661D")!,
            toID: UUID(uuidString: "7F90796C-66A8-47D3-9A52-8AE3B3E931EF")!,
            tone: .teal
        )
    ]
}

enum LinkTone: String, CaseIterable, Codable {
    case blue
    case orange
    case teal
    case green
    case indigo
}

enum EdgeType: String, Codable {
    case primary
    case tap
}

struct HierarchySnapshot: Codable {
    var nodes: [HierarchySnapshotNode]
    var links: [HierarchySnapshotLink]
}

struct HierarchySnapshotNode: Codable {
    var id: UUID
    var name: String
    var title: String
    var department: String
    var type: NodeType
    var provider: LLMProvider
    var roleDescription: String
    var inputSchema: String?
    var outputSchema: String?
    var outputSchemaDescription: String?
    var selectedRoles: [PresetRole]
    var securityAccess: [SecurityAccess]
    var assignedTools: [String]?
    var positionX: CGFloat
    var positionY: CGFloat
}

struct HierarchySnapshotLink: Codable {
    var fromID: UUID
    var toID: UUID
    var tone: LinkTone
    var edgeType: EdgeType

    init(fromID: UUID, toID: UUID, tone: LinkTone, edgeType: EdgeType = .primary) {
        self.fromID = fromID
        self.toID = toID
        self.tone = tone
        self.edgeType = edgeType
    }

    enum CodingKeys: String, CodingKey {
        case fromID
        case toID
        case tone
        case edgeType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fromID = try container.decode(UUID.self, forKey: .fromID)
        toID = try container.decode(UUID.self, forKey: .toID)
        tone = try container.decode(LinkTone.self, forKey: .tone)
        edgeType = try container.decodeIfPresent(EdgeType.self, forKey: .edgeType) ?? .primary
    }
}

// MARK: - LLM Structure Generation Types
