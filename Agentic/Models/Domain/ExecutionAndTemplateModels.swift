import Foundation
import CoreGraphics

func makeHierarchySnapshot(nodes: [OrgNode], links: [NodeLink]) -> HierarchySnapshot {
    let snapshotNodes = nodes.map { node in
        HierarchySnapshotNode(
            id: node.id,
            name: node.name,
            title: node.title,
            department: node.department,
            type: node.type,
            provider: node.provider,
            roleDescription: node.roleDescription,
            inputSchema: node.inputSchema,
            outputSchema: node.outputSchema,
            outputSchemaDescription: node.outputSchemaDescription,
            selectedRoles: node.selectedRoles.sorted { $0.rawValue < $1.rawValue },
            securityAccess: node.securityAccess.sorted { $0.rawValue < $1.rawValue },
            assignedTools: node.assignedTools.sorted(),
            positionX: node.position.x,
            positionY: node.position.y
        )
    }

    let snapshotLinks = links.map { link in
        HierarchySnapshotLink(fromID: link.fromID, toID: link.toID, tone: link.tone, edgeType: link.edgeType)
    }

    return HierarchySnapshot(nodes: snapshotNodes, links: snapshotLinks)
}

enum PresetHierarchyTemplate: String, CaseIterable, Identifiable {
    case baseline
    case researchOps
    case incidentResponse

    var id: String { rawValue }

    var title: String {
        switch self {
        case .baseline:
            return "Baseline Team"
        case .researchOps:
            return "Research + Delivery"
        case .incidentResponse:
            return "Incident Response"
        }
    }

    func snapshot() -> HierarchySnapshot {
        switch self {
        case .baseline:
            return makeHierarchySnapshot(nodes: OrgNode.sample, links: NodeLink.sample)
        case .researchOps:
            return researchOpsSnapshot()
        case .incidentResponse:
            return incidentResponseSnapshot()
        }
    }

    private func researchOpsSnapshot() -> HierarchySnapshot {
        let coordinatorID = UUID()
        let plannerID = UUID()
        let researchID = UUID()
        let buildID = UUID()
        let qualityID = UUID()
        let releaseID = UUID()

        let nodes: [OrgNode] = [
            OrgNode(id: coordinatorID, name: "Program Lead", title: "Coordinator", department: "Planning", type: .human, provider: .chatGPT, roleDescription: "Sets direction and approves release scope.", inputSchema: DefaultSchema.goalBrief, outputSchema: DefaultSchema.strategyPlan, outputSchemaDescription: DefaultSchema.defaultDescription(for: DefaultSchema.strategyPlan), selectedRoles: [.decisionMaker], securityAccess: [.workspaceRead, .auditLogs], position: .zero),
            OrgNode(id: plannerID, name: "Strategy Agent", title: "Planner", department: "Planning", type: .agent, provider: .chatGPT, roleDescription: "Breaks goals into implementation tracks.", inputSchema: DefaultSchema.strategyPlan, outputSchema: DefaultSchema.strategyPlan, outputSchemaDescription: DefaultSchema.defaultDescription(for: DefaultSchema.strategyPlan), selectedRoles: [.planner], securityAccess: [.workspaceRead, .workspaceWrite], position: .zero),
            OrgNode(id: researchID, name: "Research Agent", title: "Research", department: "Discovery", type: .agent, provider: .gemini, roleDescription: "Collects context and references for execution.", inputSchema: DefaultSchema.strategyPlan, outputSchema: DefaultSchema.researchBrief, outputSchemaDescription: DefaultSchema.defaultDescription(for: DefaultSchema.researchBrief), selectedRoles: [.researcher], securityAccess: [.workspaceRead, .webAccess], position: .zero),
            OrgNode(id: buildID, name: "Builder Agent", title: "Executor", department: "Delivery", type: .agent, provider: .claude, roleDescription: "Implements requested changes.", inputSchema: DefaultSchema.strategyPlan, outputSchema: DefaultSchema.buildPatch, outputSchemaDescription: DefaultSchema.defaultDescription(for: DefaultSchema.buildPatch), selectedRoles: [.executor], securityAccess: [.workspaceRead, .workspaceWrite, .terminalExec], position: .zero),
            OrgNode(id: qualityID, name: "QA Agent", title: "Reviewer", department: "Quality", type: .agent, provider: .grok, roleDescription: "Runs tests and validates behavior.", inputSchema: DefaultSchema.buildPatch, outputSchema: DefaultSchema.validationReport, outputSchemaDescription: DefaultSchema.defaultDescription(for: DefaultSchema.validationReport), selectedRoles: [.reviewer], securityAccess: [.workspaceRead, .terminalExec], position: .zero),
            OrgNode(id: releaseID, name: "Release Manager", title: "Human Signoff", department: "Operations", type: .human, provider: .chatGPT, roleDescription: "Approves deployment and communications.", inputSchema: DefaultSchema.validationReport, outputSchema: DefaultSchema.releaseDecision, outputSchemaDescription: DefaultSchema.defaultDescription(for: DefaultSchema.releaseDecision), selectedRoles: [.decisionMaker, .reviewer], securityAccess: [.workspaceRead, .auditLogs], position: .zero)
        ]

        let links: [NodeLink] = [
            NodeLink(fromID: coordinatorID, toID: plannerID, tone: .blue),
            NodeLink(fromID: coordinatorID, toID: researchID, tone: .blue),
            NodeLink(fromID: plannerID, toID: buildID, tone: .orange),
            NodeLink(fromID: plannerID, toID: qualityID, tone: .orange),
            NodeLink(fromID: buildID, toID: releaseID, tone: .teal)
        ]

        return makeHierarchySnapshot(nodes: nodes, links: links)
    }

    private func incidentResponseSnapshot() -> HierarchySnapshot {
        let commanderID = UUID()
        let triageID = UUID()
        let remediationID = UUID()
        let commsID = UUID()
        let forensicsID = UUID()
        let approverID = UUID()

        let nodes: [OrgNode] = [
            OrgNode(id: commanderID, name: "Incident Commander", title: "Coordinator", department: "Security", type: .human, provider: .chatGPT, roleDescription: "Owns response decisions and escalation.", inputSchema: DefaultSchema.goalBrief, outputSchema: DefaultSchema.strategyPlan, outputSchemaDescription: DefaultSchema.defaultDescription(for: DefaultSchema.strategyPlan), selectedRoles: [.coordinator, .decisionMaker], securityAccess: [.workspaceRead, .auditLogs], position: .zero),
            OrgNode(id: triageID, name: "Triage Agent", title: "Classifier", department: "Security", type: .agent, provider: .chatGPT, roleDescription: "Classifies impact and routes tasks.", inputSchema: DefaultSchema.strategyPlan, outputSchema: DefaultSchema.taskResult, outputSchemaDescription: DefaultSchema.defaultDescription(for: DefaultSchema.taskResult), selectedRoles: [.planner, .summarizer], securityAccess: [.workspaceRead, .webAccess], position: .zero),
            OrgNode(id: remediationID, name: "Remediation Agent", title: "Executor", department: "Engineering", type: .agent, provider: .claude, roleDescription: "Applies fixes and executes rollback plans.", inputSchema: DefaultSchema.taskResult, outputSchema: DefaultSchema.buildPatch, outputSchemaDescription: DefaultSchema.defaultDescription(for: DefaultSchema.buildPatch), selectedRoles: [.executor], securityAccess: [.workspaceRead, .workspaceWrite, .terminalExec], position: .zero),
            OrgNode(id: commsID, name: "Comms Agent", title: "Status Reporter", department: "Comms", type: .agent, provider: .gemini, roleDescription: "Produces executive and customer updates.", inputSchema: DefaultSchema.taskResult, outputSchema: DefaultSchema.taskResult, outputSchemaDescription: DefaultSchema.defaultDescription(for: DefaultSchema.taskResult), selectedRoles: [.summarizer], securityAccess: [.workspaceRead], position: .zero),
            OrgNode(id: forensicsID, name: "Forensics Agent", title: "Investigator", department: "Security", type: .agent, provider: .grok, roleDescription: "Collects traces and root-cause timeline.", inputSchema: DefaultSchema.taskResult, outputSchema: DefaultSchema.researchBrief, outputSchemaDescription: DefaultSchema.defaultDescription(for: DefaultSchema.researchBrief), selectedRoles: [.researcher, .reviewer], securityAccess: [.workspaceRead, .terminalExec], position: .zero),
            OrgNode(id: approverID, name: "Approver", title: "Human Gate", department: "Leadership", type: .human, provider: .chatGPT, roleDescription: "Approves high-impact remediations.", inputSchema: DefaultSchema.buildPatch, outputSchema: DefaultSchema.releaseDecision, outputSchemaDescription: DefaultSchema.defaultDescription(for: DefaultSchema.releaseDecision), selectedRoles: [.decisionMaker], securityAccess: [.auditLogs], position: .zero)
        ]

        let links: [NodeLink] = [
            NodeLink(fromID: commanderID, toID: triageID, tone: .indigo),
            NodeLink(fromID: triageID, toID: remediationID, tone: .orange),
            NodeLink(fromID: triageID, toID: commsID, tone: .orange),
            NodeLink(fromID: triageID, toID: forensicsID, tone: .orange),
            NodeLink(fromID: remediationID, toID: approverID, tone: .teal)
        ]

        return makeHierarchySnapshot(nodes: nodes, links: links)
    }
}

struct SynthesisPreviewSummary {
    let suggestedNodeCount: Int
    let suggestedLinkCount: Int
    let nodeDelta: Int
    let linkDelta: Int
    let addedNodeNames: [String]
    let removedNodeNames: [String]

    var nodeDeltaString: String {
        nodeDelta >= 0 ? "+\(nodeDelta)" : "\(nodeDelta)"
    }

    var linkDeltaString: String {
        linkDelta >= 0 ? "+\(linkDelta)" : "\(linkDelta)"
    }
}

enum TaskRunStatus {
    case draft
    case inProgress
    case needsAttention
    case completed

    var label: String {
        switch self {
        case .draft:
            return "Draft"
        case .inProgress:
            return "In Progress"
        case .needsAttention:
            return "Needs Attention"
        case .completed:
            return "Completed"
        }
    }

}

struct SynthesisQuestionState: Identifiable {
    let key: SynthesisQuestionKey
    var answer: String

    var id: String { key.rawValue }
}

enum SynthesisQuestionKey: String, CaseIterable, Identifiable, Hashable {
    case deadline
    case riskTolerance
    case needsHumanApproval

    var id: String { rawValue }

    var prompt: String {
        switch self {
        case .deadline:
            return "What deadline or delivery window should this team optimize for?"
        case .riskTolerance:
            return "What is your risk tolerance (low, medium, high)?"
        case .needsHumanApproval:
            return "Do you require a human approval gate before launch/execution?"
        }
    }
}

struct TeamStructureSynthesizer {
    func discoveryQuestions(goal: String, context: String) -> [SynthesisQuestionKey] {
        let combined = "\(goal) \(context)".lowercased()
        var questions: [SynthesisQuestionKey] = []

        if !containsAny(combined, keywords: ["today", "tomorrow", "week", "month", "q1", "q2", "q3", "q4", "deadline", "by "]) {
            questions.append(.deadline)
        }
        if !containsAny(combined, keywords: ["risk", "safe", "strict", "experimental", "compliance"]) {
            questions.append(.riskTolerance)
        }
        if !containsAny(combined, keywords: ["approval", "signoff", "human", "review"]) {
            questions.append(.needsHumanApproval)
        }

        return questions
    }

    func synthesize(
        goal: String,
        context: String,
        answers: [SynthesisQuestionKey: String]
    ) -> HierarchySnapshot {
        let combined = "\(goal) \(context) \(answers.values.joined(separator: " "))".lowercased()
        let requiresResearch = containsAny(combined, keywords: ["research", "discover", "analyze", "investigate", "market"])
        let requiresBuild = containsAny(combined, keywords: ["build", "ship", "launch", "implement", "feature", "product"])
        let requiresValidation = requiresBuild || containsAny(combined, keywords: ["qa", "test", "validate", "quality"])
        let requiresComms = containsAny(combined, keywords: ["launch", "announce", "stakeholder", "report", "comms"])
        let requiresSecurity = containsAny(combined, keywords: ["security", "compliance", "privacy", "safety", "policy"])

        let riskAnswer = answers[.riskTolerance]?.lowercased() ?? ""
        let needsApprovalFromAnswer = parseBool(answers[.needsHumanApproval])
        let requiresHumanApproval = needsApprovalFromAnswer
            || riskAnswer.contains("low")
            || containsAny(combined, keywords: ["production", "customer", "security", "compliance"])

        let coordinatorID = UUID()
        var nodes: [OrgNode] = [
            OrgNode(
                id: coordinatorID,
                name: "Coordinator Agent",
                title: "Orchestration",
                department: "Control Plane",
                type: .agent,
                provider: .chatGPT,
                roleDescription: "Decomposes goal, routes work packets, enforces policy and schema contracts.",
                inputSchema: DefaultSchema.goalBrief,
                outputSchema: DefaultSchema.strategyPlan,
                outputSchemaDescription: DefaultSchema.defaultDescription(for: DefaultSchema.strategyPlan),
                selectedRoles: [.coordinator, .planner],
                securityAccess: [.workspaceRead, .workspaceWrite],
                position: .zero
            )
        ]
        var links: [NodeLink] = []

        @discardableResult
        func addNode(
            name: String,
            title: String,
            department: String,
            type: NodeType,
            provider: LLMProvider,
            roleDescription: String,
            inputSchema: String,
            outputSchema: String,
            roles: Set<PresetRole>,
            access: Set<SecurityAccess>,
            parentID: UUID,
            tone: LinkTone
        ) -> UUID {
            let id = UUID()
            nodes.append(
                OrgNode(
                    id: id,
                    name: name,
                    title: title,
                    department: department,
                    type: type,
                    provider: provider,
                    roleDescription: roleDescription,
                    inputSchema: inputSchema,
                    outputSchema: outputSchema,
                    outputSchemaDescription: DefaultSchema.defaultDescription(for: outputSchema),
                    selectedRoles: roles,
                    securityAccess: access,
                    position: .zero
                )
            )
            links.append(NodeLink(fromID: parentID, toID: id, tone: tone))
            return id
        }

        let strategyID = addNode(
            name: "Strategy Agent",
            title: "Planner",
            department: "Planning",
            type: .agent,
            provider: .chatGPT,
            roleDescription: "Translates goals into executable tracks and success checkpoints.",
            inputSchema: DefaultSchema.strategyPlan,
            outputSchema: DefaultSchema.strategyPlan,
            roles: [.planner],
            access: [.workspaceRead, .workspaceWrite],
            parentID: coordinatorID,
            tone: .blue
        )

        if requiresResearch {
            _ = addNode(
                name: "Research Agent",
                title: "Research",
                department: "Discovery",
                type: .agent,
                provider: .gemini,
                roleDescription: "Builds evidence brief and constraints from available data.",
                inputSchema: DefaultSchema.strategyPlan,
                outputSchema: DefaultSchema.researchBrief,
                roles: [.researcher],
                access: [.workspaceRead, .webAccess],
                parentID: coordinatorID,
                tone: .blue
            )
        }

        let buildID: UUID? = requiresBuild
            ? addNode(
                name: "Builder Agent",
                title: "Executor",
                department: "Delivery",
                type: .agent,
                provider: .claude,
                roleDescription: "Implements scoped changes and returns patch artifacts.",
                inputSchema: DefaultSchema.strategyPlan,
                outputSchema: DefaultSchema.buildPatch,
                roles: [.executor],
                access: [.workspaceRead, .workspaceWrite, .terminalExec],
                parentID: strategyID,
                tone: .orange
            )
            : nil

        let qaID: UUID? = requiresValidation
            ? addNode(
                name: "QA Agent",
                title: "Reviewer",
                department: "Quality",
                type: .agent,
                provider: .grok,
                roleDescription: "Validates outcomes and enforces quality gates.",
                inputSchema: buildID == nil ? DefaultSchema.strategyPlan : DefaultSchema.buildPatch,
                outputSchema: DefaultSchema.validationReport,
                roles: [.reviewer],
                access: [.workspaceRead, .terminalExec],
                parentID: buildID ?? strategyID,
                tone: .orange
            )
            : nil

        let securityID: UUID? = requiresSecurity
            ? addNode(
                name: "Security Agent",
                title: "Policy Reviewer",
                department: "Security",
                type: .agent,
                provider: .chatGPT,
                roleDescription: "Checks policy, compliance, and sensitive-access boundaries.",
                inputSchema: DefaultSchema.buildPatch,
                outputSchema: DefaultSchema.validationReport,
                roles: [.reviewer],
                access: [.workspaceRead, .auditLogs],
                parentID: buildID ?? strategyID,
                tone: .teal
            )
            : nil

        if requiresComms {
            _ = addNode(
                name: "Reporting Agent",
                title: "Comms",
                department: "Stakeholder Updates",
                type: .agent,
                provider: .chatGPT,
                roleDescription: "Produces clear updates for stakeholders and release notes.",
                inputSchema: DefaultSchema.strategyPlan,
                outputSchema: DefaultSchema.taskResult,
                roles: [.summarizer],
                access: [.workspaceRead],
                parentID: coordinatorID,
                tone: .blue
            )
        }

        if requiresHumanApproval {
            _ = addNode(
                name: "Release Manager",
                title: "Human Approval Gate",
                department: "Operations",
                type: .human,
                provider: .chatGPT,
                roleDescription: "Approves or rejects high-impact actions before rollout.",
                inputSchema: DefaultSchema.validationReport,
                outputSchema: DefaultSchema.releaseDecision,
                roles: [.decisionMaker, .reviewer],
                access: [.workspaceRead, .auditLogs],
                parentID: securityID ?? qaID ?? buildID ?? strategyID,
                tone: .indigo
            )
        }

        return makeHierarchySnapshot(nodes: nodes, links: links)
    }

    private func containsAny(_ text: String, keywords: [String]) -> Bool {
        keywords.contains { text.contains($0) }
    }

    private func parseBool(_ value: String?) -> Bool {
        guard let value else { return false }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty { return false }
        return ["yes", "y", "true", "required", "need", "must"].contains { token in
            normalized.contains(token)
        }
    }
}

enum OrchestrationNodeKind: String, Codable {
    case human
    case agent
}

enum CoordinatorExecutionMode: String, CaseIterable, Identifiable, Codable {
    case simulation
    case liveMCP

    var id: String { rawValue }

    var label: String {
        switch self {
        case .simulation:
            return "Simulation"
        case .liveMCP:
            return "Live API"
        }
    }
}

enum CoordinatorTraceStatus: String, Codable {
    case queued
    case running
    case waitingHuman
    case succeeded
    case approved
    case rejected
    case needsInfo
    case blocked
    case failed

    var label: String {
        switch self {
        case .queued:
            return "Queued"
        case .running:
            return "Running"
        case .waitingHuman:
            return "Waiting Human"
        case .succeeded:
            return "Succeeded"
        case .approved:
            return "Approved"
        case .rejected:
            return "Rejected"
        case .needsInfo:
            return "Needs Info"
        case .blocked:
            return "Blocked"
        case .failed:
            return "Failed"
        }
    }

}

struct CoordinatorTraceStep: Identifiable, Codable {
    var id: String { packetID }
    let packetID: String
    let assignedNodeID: UUID?
    let assignedNodeName: String
    let objective: String
    var status: CoordinatorTraceStatus
    var summary: String?
    var confidence: Double?
    var startedAt: Date?
    var finishedAt: Date?
    var inputTokens: Int?
    var outputTokens: Int?
    var modelID: String?
    var systemPrompt: String?
    var userPrompt: String?
    var rawResponse: String?

    var durationText: String? {
        guard let startedAt else { return nil }
        let endTime = finishedAt ?? Date()
        let duration = endTime.timeIntervalSince(startedAt)
        if duration < 1 {
            return String(format: "%.0fms", duration * 1000)
        }
        return String(format: "%.2fs", duration)
    }

    var tokenText: String? {
        guard let input = inputTokens, let output = outputTokens, input + output > 0 else { return nil }
        return "\(Self.formatTokenCount(input + output)) tok"
    }

    static func formatTokens(_ count: Int) -> String {
        formatTokenCount(count)
    }

    private static func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }
}

struct OrchestrationNode: Identifiable, Codable {
    let id: UUID
    let name: String
    let title: String
    let type: OrchestrationNodeKind
    let provider: String
    let roleDescription: String
    let inputSchema: String
    let outputSchema: String
    let outputSchemaDescription: String
    let securityAccess: Set<String>
    let assignedTools: Set<String>
    var positionX: CGFloat?
}

struct OrchestrationEdge: Codable {
    let parentID: UUID
    let childID: UUID
}

struct OrchestrationGraph: Codable {
    let nodes: [OrchestrationNode]
    let edges: [OrchestrationEdge]
}

struct CoordinatorTaskPacket: Identifiable, Codable {
    let id: String
    let parentTaskID: String
    let assignedNodeID: UUID
    let assignedNodeName: String
    let assignedNodeKind: OrchestrationNodeKind
    let objective: String
    let requiredInputSchema: String
    let requiredOutputSchema: String
    let outputSchemaDescription: String
    let requiredHandoffs: [CoordinatorHandoffRequirement]
    let allowedPermissions: [String]
    let assignedTools: [String]
}

struct PendingCoordinatorExecution: Codable {
    let runID: String
    let plan: CoordinatorPlan
    let mode: CoordinatorExecutionMode
    var nextPacketIndex: Int
    var results: [CoordinatorTaskResult]
    var outputsByNodeID: [UUID: ProducedHandoff]
    let startedAt: Date
    var awaitingHumanPacketID: String?
    var retryFeedback: String?
    var runFromHereContext: String?
    var runFromHereStartNodeID: UUID?
}

enum HumanTaskDecision: String, Codable {
    case approve
    case reject
    case needsInfo

    var label: String {
        switch self {
        case .approve:
            return "Approve"
        case .reject:
            return "Reject"
        case .needsInfo:
            return "Needs Info"
        }
    }
}

struct CoordinatorHandoffRequirement: Identifiable, Codable, Hashable {
    var id: String { fromNodeID.uuidString }
    let fromNodeID: UUID
    let fromNodeName: String
    let outputSchema: String
}

struct ProducedHandoff: Codable {
    let schema: String
    let summary: String
}

struct HumanDecisionAuditEvent: Identifiable, Codable {
    let id: String
    let runID: String
    let packetID: String
    let nodeName: String
    let decision: HumanTaskDecision
    let note: String
    let actorIdentity: String
    let decidedAt: Date
}

struct CoordinatorExecutionStateBundle: Codable {
    let pendingExecution: PendingCoordinatorExecution?
    let latestRun: CoordinatorRun?
    let trace: [CoordinatorTraceStep]
    let humanDecisionAudit: [HumanDecisionAuditEvent]
    let humanActorIdentity: String
    var lastCompletedExecution: PendingCoordinatorExecution?
    var runHistory: [CoordinatorRunHistoryEntry]?
}

struct HandoffValidation {
    let isValid: Bool
    let message: String
    let handoffSummaries: [String]
}

struct CoordinatorPlan: Codable {
    let planID: String
    let coordinatorID: UUID
    let coordinatorName: String
    let coordinatorOutputSchema: String
    let goal: String
    let packets: [CoordinatorTaskPacket]
    let createdAt: Date
}

struct MCPTaskRequest: Codable {
    let packetID: String
    let objective: String
    let inputSchema: String
    let outputSchema: String
    let handoffSummaries: [String]
    let roleContext: String
}

struct MCPTaskResponse: Codable {
    let summary: String
    let confidence: Double
    let completed: Bool
    var inputTokens: Int?
    var outputTokens: Int?
    var modelID: String?
    var systemPrompt: String?
    var userPrompt: String?
    var rawResponse: String?
}

struct CoordinatorTaskResult: Identifiable, Codable {
    let id: String
    let packetID: String
    let assignedNodeName: String
    let summary: String
    let confidence: Double
    let completed: Bool
    let finishedAt: Date
    var inputTokens: Int?
    var outputTokens: Int?
}

struct CoordinatorRun: Codable, Identifiable {
    var id: String { runID }
    let runID: String
    let planID: String
    let mode: CoordinatorExecutionMode
    let results: [CoordinatorTaskResult]
    let startedAt: Date
    let finishedAt: Date

    var succeededCount: Int {
        results.filter(\.completed).count
    }
}

struct CoordinatorRunHistoryEntry: Codable, Identifiable {
    var id: String { run.runID }
    let run: CoordinatorRun
    let trace: [CoordinatorTraceStep]
    /// Snapshot of the graph structure as it existed at run time. Used to render
    /// the correct canvas when the user selects this run in history. Optional so
    /// run-history entries written before this field existed still decode.
    var structureSnapshot: HierarchySnapshot?
}

