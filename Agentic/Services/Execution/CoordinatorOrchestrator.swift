import SwiftUI

// MARK: - Coordinator Execution

protocol MCPClient {
    func execute(_ request: MCPTaskRequest) async -> MCPTaskResponse
}

struct MockMCPClient: MCPClient {
    func execute(_ request: MCPTaskRequest) async -> MCPTaskResponse {
        try? await Task.sleep(nanoseconds: AppConfiguration.MockCoordinator.responseDelayNanoseconds)
        let normalizedObjective = request.objective.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = "Completed: \(normalizedObjective). Input \(request.inputSchema) -> output \(request.outputSchema)."
        return MCPTaskResponse(
            summary: summary,
            confidence: AppConfiguration.MockCoordinator.confidence,
            completed: true
        )
    }
}

struct CoordinatorOrchestrator {
    func plan(goal: String, graph: OrchestrationGraph) -> CoordinatorPlan {
        precondition(!graph.nodes.isEmpty, "Graph must contain at least one node")
        let nodeByID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        let outgoingByParentID = Dictionary(grouping: graph.edges, by: \.parentID)
        let incomingByChildID = Dictionary(grouping: graph.edges, by: \.childID)
        let childIDs = Set(graph.edges.map(\.childID))
        let rootCandidates = graph.nodes.filter { !childIDs.contains($0.id) }

        let coordinator = preferredCoordinator(from: rootCandidates, fallback: graph.nodes)
        let reachableIDs = collectReachableNodeIDs(
            under: coordinator.id,
            outgoingByParentID: outgoingByParentID
        )
        let dispatchOrder = collectExecutionNodesPreOrder(
            under: coordinator.id,
            nodeByID: nodeByID,
            outgoingByParentID: outgoingByParentID,
            reachableIDs: reachableIDs
        )
        let parentTaskID = "TASK-\(UUID().uuidString.prefix(8))"
        var packets: [CoordinatorTaskPacket] = []
        packets.reserveCapacity(dispatchOrder.count)
        var packetIndex = 1

        // Phase 1: top-down delegation/input propagation (parent -> child)
        for node in dispatchOrder {
            let handoffs = (incomingByChildID[node.id] ?? [])
                .filter { reachableIDs.contains($0.parentID) }
                .compactMap { edge -> CoordinatorHandoffRequirement? in
                    guard let parent = nodeByID[edge.parentID] else { return nil }
                    return CoordinatorHandoffRequirement(
                        fromNodeID: parent.id,
                        fromNodeName: parent.name,
                        outputSchema: parent.outputSchema
                    )
                }

            packets.append(
                CoordinatorTaskPacket(
                    id: "\(parentTaskID)-\(packetIndex)",
                    parentTaskID: parentTaskID,
                    assignedNodeID: node.id,
                    assignedNodeName: node.name,
                    assignedNodeKind: node.type,
                    objective: objectiveForNode(node, globalGoal: goal),
                    requiredInputSchema: handoffs.first?.outputSchema ?? node.inputSchema,
                    requiredOutputSchema: node.outputSchema,
                    outputSchemaDescription: node.outputSchemaDescription,
                    requiredHandoffs: handoffs,
                    allowedPermissions: node.securityAccess.sorted(),
                    assignedTools: node.assignedTools.sorted()
                )
            )
            packetIndex += 1
        }

        return CoordinatorPlan(
            planID: "PLAN-\(UUID().uuidString.prefix(8))",
            coordinatorID: coordinator.id,
            coordinatorName: coordinator.name,
            coordinatorOutputSchema: coordinator.outputSchema,
            goal: goal,
            packets: packets,
            createdAt: Date()
        )
    }

    private func collectReachableNodeIDs(
        under coordinatorID: UUID,
        outgoingByParentID: [UUID: [OrchestrationEdge]]
    ) -> Set<UUID> {
        var reachable: Set<UUID> = [coordinatorID]
        var queue: [UUID] = [coordinatorID]
        var head = 0

        while head < queue.count {
            let currentID = queue[head]
            head += 1
            for childID in (outgoingByParentID[currentID] ?? []).map(\.childID) where !reachable.contains(childID) {
                reachable.insert(childID)
                queue.append(childID)
            }
        }

        return reachable
    }

    private func collectExecutionNodesPreOrder(
        under coordinatorID: UUID,
        nodeByID: [UUID: OrchestrationNode],
        outgoingByParentID: [UUID: [OrchestrationEdge]],
        reachableIDs: Set<UUID>
    ) -> [OrchestrationNode] {
        func sortNodeIDs(_ lhs: UUID, _ rhs: UUID) -> Bool {
            if lhs == coordinatorID { return true }
            if rhs == coordinatorID { return false }

            // Sort by X position (left-to-right) when available
            let leftX = nodeByID[lhs]?.positionX ?? .greatestFiniteMagnitude
            let rightX = nodeByID[rhs]?.positionX ?? .greatestFiniteMagnitude
            if leftX != rightX { return leftX < rightX }

            // Fallback to name-based ordering
            let left = nodeByID[lhs]?.name ?? lhs.uuidString
            let right = nodeByID[rhs]?.name ?? rhs.uuidString
            if left == right { return lhs.uuidString < rhs.uuidString }
            return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
        }

        var indegreeByID: [UUID: Int] = Dictionary(uniqueKeysWithValues: reachableIDs.map { ($0, 0) })
        var childrenByParentID: [UUID: [UUID]] = [:]

        for parentID in reachableIDs {
            let children = (outgoingByParentID[parentID] ?? [])
                .map(\.childID)
                .filter { reachableIDs.contains($0) }
            if !children.isEmpty {
                childrenByParentID[parentID] = children
            }
            for childID in children {
                indegreeByID[childID, default: 0] += 1
            }
        }

        var availableIDs = indegreeByID
            .filter { $0.value == 0 }
            .map(\.key)
            .sorted(by: sortNodeIDs)

        var orderedIDs: [UUID] = []
        orderedIDs.reserveCapacity(reachableIDs.count)

        while !availableIDs.isEmpty {
            let nodeID = availableIDs.removeFirst()
            orderedIDs.append(nodeID)

            let sortedChildren = (childrenByParentID[nodeID] ?? []).sorted(by: sortNodeIDs)
            for childID in sortedChildren {
                let newValue = (indegreeByID[childID] ?? 0) - 1
                indegreeByID[childID] = newValue
                if newValue == 0 {
                    availableIDs.append(childID)
                }
            }

            availableIDs.sort(by: sortNodeIDs)
        }

        if orderedIDs.count < reachableIDs.count {
            let visited = Set(orderedIDs)
            let unresolved = reachableIDs
                .filter { !visited.contains($0) }
                .sorted(by: sortNodeIDs)
            orderedIDs.append(contentsOf: unresolved)
        }

        return orderedIDs.compactMap { nodeByID[$0] }
    }

    func execute(plan: CoordinatorPlan, using client: MCPClient) async -> CoordinatorRun {
        let startedAt = Date()
        var results: [CoordinatorTaskResult] = []
        results.reserveCapacity(plan.packets.count)

        for packet in plan.packets {
            let response = await client.execute(
                MCPTaskRequest(
                    packetID: packet.id,
                    objective: packet.objective,
                    inputSchema: packet.requiredInputSchema,
                    outputSchema: packet.requiredOutputSchema,
                    handoffSummaries: [],
                    roleContext: packet.assignedNodeName
                )
            )
            let result = CoordinatorTaskResult(
                id: UUID().uuidString,
                packetID: packet.id,
                assignedNodeName: packet.assignedNodeName,
                summary: response.summary,
                confidence: response.confidence,
                completed: response.completed,
                finishedAt: Date()
            )
            results.append(result)
        }

        return CoordinatorRun(
            runID: "RUN-\(UUID().uuidString.prefix(8))",
            planID: plan.planID,
            mode: .liveMCP,
            results: results,
            startedAt: startedAt,
            finishedAt: Date()
        )
    }

    private func preferredCoordinator(from roots: [OrchestrationNode], fallback allNodes: [OrchestrationNode]) -> OrchestrationNode {
        let source = roots.isEmpty ? allNodes : roots
        if let preferred = source.first(where: {
            $0.name.localizedCaseInsensitiveContains("coordinator")
                || $0.title.localizedCaseInsensitiveContains("coordinator")
                || $0.name.localizedCaseInsensitiveContains("lead")
                || $0.title.localizedCaseInsensitiveContains("lead")
        }) {
            return preferred
        }
        return source.sorted { $0.name < $1.name }.first ?? allNodes.first!
    }

    private func objectiveForNode(_ node: OrchestrationNode, globalGoal: String) -> String {
        let context = node.roleDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if context.isEmpty {
            return "Contribute to goal: \(globalGoal)"
        }
        return "For goal '\(globalGoal)', handle this scope: \(context)"
    }

}

func computePrimaryParentByChild(
    nodeIDs: Set<UUID>,
    links: [NodeLink],
    currentXByID: [UUID: CGFloat]
) -> [UUID: UUID] {
    var parentsByChildID: [UUID: [UUID]] = [:]
    for link in links where nodeIDs.contains(link.fromID) && nodeIDs.contains(link.toID) {
        parentsByChildID[link.toID, default: []].append(link.fromID)
    }

    var primaryByChildID: [UUID: UUID] = [:]
    for (childID, parentIDs) in parentsByChildID {
        if parentIDs.count == 1 {
            primaryByChildID[childID] = parentIDs[0]
            continue
        }

        let childX = currentXByID[childID] ?? 0
        let chosen = parentIDs.min { lhs, rhs in
            let leftDelta = abs((currentXByID[lhs] ?? childX) - childX)
            let rightDelta = abs((currentXByID[rhs] ?? childX) - childX)
            if leftDelta == rightDelta {
                return lhs.uuidString < rhs.uuidString
            }
            return leftDelta < rightDelta
        } ?? parentIDs[0]

        primaryByChildID[childID] = chosen
    }

    return primaryByChildID
}
