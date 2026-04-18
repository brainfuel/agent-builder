import Foundation

struct MCPToolDefinition: Identifiable, Hashable {
    let id: String
    let name: String
    let description: String
    let category: String
    let status: ToolStatus

    enum ToolStatus: String, Hashable {
        case active = "Active"
        case planned = "Coming Soon"
    }

    init(id: String, name: String, description: String, category: String, status: ToolStatus = .planned) {
        self.id = id
        self.name = name
        self.description = description
        self.category = category
        self.status = status
    }
}

enum MCPToolRegistry {
    static let allTools: [MCPToolDefinition] = [
        MCPToolDefinition(
            id: "web_search",
            name: "Web Search",
            description: "Search the web for current information via provider grounding.",
            category: "Search",
            status: .active
        ),
        MCPToolDefinition(
            id: "structured_output",
            name: "Structured Output",
            description: "Enforce strict JSON-schema output from this node.",
            category: "Output",
            status: .active
        ),
        MCPToolDefinition(
            id: "human_review",
            name: "Human Review",
            description: "Escalate output to a human for approval before continuing.",
            category: "Workflow",
            status: .active
        ),
    ]

    static let toolsByID: [String: MCPToolDefinition] = Dictionary(
        uniqueKeysWithValues: allTools.map { ($0.id, $0) }
    )

    static var categories: [String] {
        allTools.map(\.category).reduce(into: [String]()) { result, cat in
            if !result.contains(cat) { result.append(cat) }
        }
    }

    static func tools(in category: String) -> [MCPToolDefinition] {
        allTools.filter { $0.category == category }
    }
}

enum SecurityAccess: String, CaseIterable, Identifiable, Hashable, Codable {
    case workspaceRead
    case workspaceWrite
    case terminalExec
    case webAccess
    case secretsRead
    case auditLogs

    var id: String { rawValue }

    var label: String {
        switch self {
        case .workspaceRead:
            return "Connected Apps Read"
        case .workspaceWrite:
            return "Workspace Write"
        case .terminalExec:
            return "Terminal Execution"
        case .webAccess:
            return "Web Access"
        case .secretsRead:
            return "Secrets Read"
        case .auditLogs:
            return "Audit Logs"
        }
    }
}

