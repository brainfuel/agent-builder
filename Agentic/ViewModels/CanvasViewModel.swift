import SwiftUI

/// Owns canvas graph state (nodes, links, selection, linking gesture) and mutation lifecycle.
/// Delegates all pure layout/hit-test/graph-geometry math to `CanvasLayoutEngine`.
/// Delegates transient view-only state (zoom, search, scroll proxy) to `viewport`.
@Observable
final class CanvasViewModel {

    // MARK: - Graph State

    var nodes: [OrgNode] = OrgNode.sample
    var links: [NodeLink] = NodeLink.sample
    var selectedNodeID: OrgNode.ID?
    var selectedLinkID: UUID?

    // MARK: - Linking Gesture

    var linkingFromNodeID: UUID?
    var linkingPointer: CGPoint?
    var linkHoverTargetNodeID: UUID?

    // MARK: - Viewport (zoom / search / scroll proxy / animation flag)

    let viewport = CanvasViewportState()

    // MARK: - Persistence Coordination

    var suppressStoreSync = false
    var lastPersistedFingerprint = ""

    /// Loads graph state from a document, or resets to default layout if nil.
    func load(from document: GraphDocument?) {
        guard
            let document,
            let snapshot = try? JSONDecoder().decode(HierarchySnapshot.self, from: document.snapshotData)
        else {
            relayoutHierarchy()
            lastPersistedFingerprint = semanticFingerprint
            return
        }
        suppressStoreSync = true
        viewport.suppressLayoutAnimation = true
        setGraph(from: snapshot, resetViewState: false)
        suppressStoreSync = false
        DispatchQueue.main.async { [weak self] in self?.viewport.suppressLayoutAnimation = false }
        lastPersistedFingerprint = semanticFingerprint
    }

    /// Writes the current graph snapshot to the document and calls `onSave` if changed.
    func persistIfNeeded(for newFingerprint: String, to document: GraphDocument, onSave: () -> Void) {
        guard !suppressStoreSync else { return }
        guard newFingerprint != lastPersistedFingerprint else { return }
        guard let data = try? JSONEncoder().encode(captureStructureSnapshot()) else { return }
        document.snapshotData = data
        document.updatedAt = Date()
        onSave()
        lastPersistedFingerprint = newFingerprint
    }

    // MARK: - Undo

    weak var undoManager: UndoManager?

    // MARK: - Callbacks

    /// Called after a semantic mutation to persist the graph. Receives the new fingerprint.
    var onPersistNeeded: ((String) -> Void)?

    // MARK: - Computed Properties

    var visibleNodes: [OrgNode] {
        guard !viewport.searchText.isEmpty else { return nodes }
        return nodes.filter { node in
            node.name.localizedCaseInsensitiveContains(viewport.searchText) ||
            node.title.localizedCaseInsensitiveContains(viewport.searchText) ||
            node.department.localizedCaseInsensitiveContains(viewport.searchText)
        }
    }

    var canvasContentSize: CGSize {
        CanvasLayoutEngine.canvasContentSize(for: nodes)
    }

    var semanticFingerprint: String {
        let nodePart = nodes
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { node in
                let roles = node.selectedRoles.map(\.rawValue).sorted().joined(separator: ",")
                let access = node.securityAccess.map(\.rawValue).sorted().joined(separator: ",")
                return [
                    node.id.uuidString, node.name, node.title, node.department,
                    node.type.rawValue, node.provider.rawValue, node.roleDescription,
                    node.inputSchema, node.outputSchema, roles, access
                ].joined(separator: "§")
            }
            .joined(separator: "|")

        let linkPart = links
            .sorted { lhs, rhs in
                if lhs.fromID == rhs.fromID {
                    if lhs.toID == rhs.toID { return lhs.tone.rawValue < rhs.tone.rawValue }
                    return lhs.toID.uuidString < rhs.toID.uuidString
                }
                return lhs.fromID.uuidString < rhs.fromID.uuidString
            }
            .map { "\($0.fromID.uuidString)->\($0.toID.uuidString):\($0.tone.rawValue)" }
            .joined(separator: "|")

        return nodePart + "###" + linkPart
    }

    var orphanNodeIDs: Set<UUID> {
        CanvasLayoutEngine.computeOrphanNodeIDs(nodes: nodes, links: links)
    }

    var orchestrationGraph: OrchestrationGraph {
        let runnableIDs = CanvasLayoutEngine.computeRunnableNodeIDs(nodes: nodes, links: links)
        let graphNodes = nodes
            .filter { runnableIDs.contains($0.id) && ($0.type == .agent || $0.type == .human) }
            .map { node in
                OrchestrationNode(
                    id: node.id, name: node.name, title: node.title,
                    type: node.type == .agent ? .agent : .human,
                    provider: node.provider.rawValue,
                    roleDescription: node.roleDescription,
                    inputSchema: node.inputSchema, outputSchema: node.outputSchema,
                    outputSchemaDescription: node.outputSchemaDescription,
                    securityAccess: Set(node.securityAccess.map(\.rawValue)),
                    assignedTools: node.assignedTools,
                    positionX: node.position.x
                )
            }
        let validNodeIDs = Set(graphNodes.map(\.id))
        let graphEdges = links
            .filter { validNodeIDs.contains($0.fromID) && validNodeIDs.contains($0.toID) }
            .map { OrchestrationEdge(parentID: $0.fromID, childID: $0.toID) }
        return OrchestrationGraph(nodes: graphNodes, edges: graphEdges)
    }

    // MARK: - Snapshot

    func captureStructureSnapshot() -> HierarchySnapshot {
        makeHierarchySnapshot(nodes: nodes, links: links)
    }

    // MARK: - Semantic Mutation

    func performSemanticMutation(_ mutation: () -> Void) {
        suppressStoreSync = true
        mutation()
        suppressStoreSync = false
        onPersistNeeded?(semanticFingerprint)
    }

    // MARK: - Selection

    func clearLinkDragState() {
        linkingFromNodeID = nil
        linkingPointer = nil
        linkHoverTargetNodeID = nil
    }

    func selectNode(_ node: OrgNode) {
        clearLinkDragState()
        selectedLinkID = nil
        selectedNodeID = (selectedNodeID == node.id) ? nil : node.id
    }

    // MARK: - Canvas Tap

    func handleCanvasTap(at point: CGPoint, visibleNodes: [OrgNode], visibleLinks: [NodeLink]) {
        guard linkingFromNodeID == nil else { return }

        if CanvasLayoutEngine.nodeAt(point, in: visibleNodes) != nil {
            return
        }

        if let hitLinkID = CanvasLayoutEngine.nearestLinkID(to: point, nodes: nodes, links: links) {
            selectedLinkID = (selectedLinkID == hitLinkID) ? nil : hitLinkID
            selectedNodeID = nil
        } else {
            selectedLinkID = nil
        }
    }

    // MARK: - Linking

    func toggleLinkStart(for nodeID: UUID) {
        if linkingFromNodeID == nodeID {
            clearLinkDragState()
            return
        }
        linkingFromNodeID = nodeID
        linkingPointer = nil
        linkHoverTargetNodeID = nil
        selectedNodeID = nodeID
        selectedLinkID = nil
    }

    func completeLinkSelection(sourceID: UUID, targetID: UUID) {
        defer { clearLinkDragState() }
        guard
            sourceID != targetID,
            nodes.contains(where: { $0.id == targetID }),
            CanvasLayoutEngine.canLinkDownward(from: sourceID, to: targetID, candidates: nodes)
        else { return }

        performSemanticMutation {
            guard !CanvasLayoutEngine.wouldCreateCycle(from: sourceID, to: targetID, links: links) else { return }

            if let targetNode = nodes.first(where: { $0.id == targetID }), targetNode.type == .output {
                let existingOutputLinks = links.filter { $0.toID == targetID }
                if let existing = existingOutputLinks.first(where: { $0.fromID == sourceID }) {
                    selectedLinkID = existing.id
                    selectedNodeID = nil
                    return
                }

                let outputTone = existingOutputLinks.first?.tone ?? .teal
                let outputEdgeType = existingOutputLinks.first?.edgeType ?? .primary
                links.removeAll { $0.toID == targetID }

                let created = NodeLink(fromID: sourceID, toID: targetID, tone: outputTone, edgeType: outputEdgeType)
                links.append(created)
                selectedLinkID = created.id
                selectedNodeID = nil
                relayoutHierarchy()
                return
            }

            if let existing = links.first(where: { $0.fromID == sourceID && $0.toID == targetID }) {
                selectedLinkID = existing.id
                selectedNodeID = nil
                return
            }

            let inheritedTone =
                links.first(where: { $0.fromID == sourceID })?.tone
                ?? links.first(where: { $0.toID == sourceID })?.tone
                ?? .blue

            let created = NodeLink(fromID: sourceID, toID: targetID, tone: inheritedTone)
            links.append(created)
            selectedLinkID = created.id
            selectedNodeID = nil
            relayoutHierarchy()
        }
    }

    func updateLinkDrag(sourceID: UUID, pointer: CGPoint, candidateNodes: [OrgNode]) {
        if linkingFromNodeID == nil {
            linkingFromNodeID = sourceID
            selectedNodeID = sourceID
            selectedLinkID = nil
        }

        linkingPointer = pointer
        if
            let hoveredNode = CanvasLayoutEngine.nodeAt(pointer, in: candidateNodes, excluding: sourceID),
            CanvasLayoutEngine.canLinkDownward(from: sourceID, to: hoveredNode.id, candidates: candidateNodes)
        {
            linkHoverTargetNodeID = hoveredNode.id
        } else {
            linkHoverTargetNodeID = nil
        }
    }

    func completeLinkDrag(candidateNodes: [OrgNode]) {
        defer { clearLinkDragState() }
        guard
            let sourceID = linkingFromNodeID,
            let targetID = linkHoverTargetNodeID,
            candidateNodes.contains(where: { $0.id == targetID }),
            sourceID != targetID,
            CanvasLayoutEngine.canLinkDownward(from: sourceID, to: targetID, candidates: candidateNodes)
        else { return }

        performSemanticMutation {
            guard !CanvasLayoutEngine.wouldCreateCycle(from: sourceID, to: targetID, links: links) else { return }

            if let targetNode = nodes.first(where: { $0.id == targetID }), targetNode.type == .output {
                let existingOutputLinks = links.filter { $0.toID == targetID }
                if let existing = existingOutputLinks.first(where: { $0.fromID == sourceID }) {
                    selectedLinkID = existing.id
                    selectedNodeID = nil
                    return
                }

                let outputTone = existingOutputLinks.first?.tone ?? .teal
                let outputEdgeType = existingOutputLinks.first?.edgeType ?? .primary
                links.removeAll { $0.toID == targetID }

                let created = NodeLink(fromID: sourceID, toID: targetID, tone: outputTone, edgeType: outputEdgeType)
                links.append(created)
                selectedLinkID = created.id
                selectedNodeID = nil
                relayoutHierarchy()
                return
            }

            if let existing = links.first(where: { $0.fromID == sourceID && $0.toID == targetID }) {
                selectedLinkID = existing.id
                selectedNodeID = nil
                return
            }

            let inheritedTone =
                links.first(where: { $0.fromID == sourceID })?.tone
                ?? links.first(where: { $0.toID == sourceID })?.tone
                ?? .blue

            let created = NodeLink(fromID: sourceID, toID: targetID, tone: inheritedTone)
            links.append(created)
            selectedLinkID = created.id
            selectedNodeID = nil
            relayoutHierarchy()
        }
    }

    // MARK: - Node CRUD

    func addNode(template: NodeTemplate = .blank, forcedParentID: UUID? = nil) {
        let type = template.nodeType
        let fallbackPosition = CGPoint(
            x: CGFloat(Int.random(in: 400...1700)),
            y: CGFloat(Int.random(in: 120...1080))
        )

        var newPosition = fallbackPosition
        var parentIDForNewNode: UUID?
        var parentLinkToneForNewNode: LinkTone = .blue
        var inheritedInputSchemaForNewNode: String?

        let requestedParentID = forcedParentID ?? selectedNodeID
        let resolvedParentID: UUID? = {
            guard
                let requestedParentID,
                let requestedNode = nodes.first(where: { $0.id == requestedParentID })
            else { return nil }
            switch requestedNode.type {
            case .input:
                return CanvasLayoutEngine.anchorAttachmentNodeIDs(nodes: nodes, links: links).rootID
            case .output:
                return CanvasLayoutEngine.anchorAttachmentNodeIDs(nodes: nodes, links: links).sinkID
            case .agent, .human:
                return requestedParentID
            }
        }()

        if
            let parentSeedID = resolvedParentID,
            let selectedNode = nodes.first(where: { $0.id == parentSeedID })
        {
            let childIDs = Set(links.filter { $0.fromID == parentSeedID }.map(\.toID))
            let children = nodes.filter {
                childIDs.contains($0.id) && $0.type != .input && $0.type != .output
            }

            let preferredChildY: CGFloat? = {
                guard let parentParentID = links.first(where: { $0.toID == parentSeedID })?.fromID else { return nil }
                let siblingIDs = Set(
                    links.filter { $0.fromID == parentParentID && $0.toID != parentSeedID }.map(\.toID)
                )
                let cousinChildLinks = links.filter { siblingIDs.contains($0.fromID) }
                let cousinChildYs: [CGFloat] = cousinChildLinks.compactMap { link -> CGFloat? in
                    guard let childNode = nodes.first(where: { $0.id == link.toID }) else { return nil }
                    guard childNode.type != .input && childNode.type != .output else { return nil }
                    return childNode.position.y
                }
                return cousinChildYs.sorted().first
            }()

            newPosition = CanvasLayoutEngine.nextChildPosition(
                parent: selectedNode,
                existingChildren: children,
                preferredY: preferredChildY
            )
            parentIDForNewNode = parentSeedID
            inheritedInputSchemaForNewNode = selectedNode.outputSchema
            parentLinkToneForNewNode =
                links.first(where: { $0.fromID == parentSeedID })?.tone
                ?? links.first(where: { $0.toID == parentSeedID })?.tone
                ?? .blue
        }

        let newNodeID = UUID()
        let newNode = OrgNode(
            id: newNodeID,
            name: template.name,
            title: template.title,
            department: template.department,
            type: type,
            provider: .chatGPT,
            roleDescription: template.roleDescription,
            inputSchema: inheritedInputSchemaForNewNode ?? CanvasLayoutEngine.defaultInputSchema(for: type),
            outputSchema: CanvasLayoutEngine.defaultOutputSchema(for: type),
            outputSchemaDescription: template.outputSchemaDescription,
            selectedRoles: [],
            securityAccess: template.securityAccess,
            assignedTools: template.defaultTools,
            position: newPosition
        )

        performSemanticMutation {
            nodes.append(newNode)

            if let parentIDForNewNode {
                links.append(
                    NodeLink(fromID: parentIDForNewNode, toID: newNodeID, tone: parentLinkToneForNewNode)
                )

                if
                    let outputID = nodes.first(where: { $0.type == .output })?.id,
                    let parentToOutputIndex = links.firstIndex(where: {
                        $0.fromID == parentIDForNewNode && $0.toID == outputID
                    })
                {
                    let redirectedLink = links[parentToOutputIndex]
                    links.remove(at: parentToOutputIndex)

                    if !links.contains(where: { $0.fromID == newNodeID && $0.toID == outputID }) {
                        links.append(
                            NodeLink(
                                fromID: newNodeID, toID: outputID,
                                tone: redirectedLink.tone, edgeType: redirectedLink.edgeType
                            )
                        )
                    }
                }
            }

            relayoutHierarchy()
            selectedLinkID = nil
            selectedNodeID = newNode.id
        }
    }

    func addNodeFromUserTemplate(_ userTemplate: UserNodeTemplate, forcedParentID: UUID? = nil) {
        let type = NodeType(rawValue: userTemplate.nodeTypeRaw) ?? .agent
        let fallbackPosition = CGPoint(
            x: CGFloat(Int.random(in: 400...1700)),
            y: CGFloat(Int.random(in: 120...1080))
        )

        var newPosition = fallbackPosition
        var parentIDForNewNode: UUID?
        var parentLinkToneForNewNode: LinkTone = .blue
        var inheritedInputSchemaForNewNode: String?

        let requestedParentID = forcedParentID ?? selectedNodeID
        let resolvedParentID: UUID? = {
            guard
                let requestedParentID,
                let requestedNode = nodes.first(where: { $0.id == requestedParentID })
            else { return nil }
            switch requestedNode.type {
            case .input: return CanvasLayoutEngine.anchorAttachmentNodeIDs(nodes: nodes, links: links).rootID
            case .output: return CanvasLayoutEngine.anchorAttachmentNodeIDs(nodes: nodes, links: links).sinkID
            case .agent, .human: return requestedParentID
            }
        }()

        if
            let parentSeedID = resolvedParentID,
            let selectedNode = nodes.first(where: { $0.id == parentSeedID })
        {
            let childIDs = Set(links.filter { $0.fromID == parentSeedID }.map(\.toID))
            let children = nodes.filter {
                childIDs.contains($0.id) && $0.type != .input && $0.type != .output
            }
            let preferredChildY: CGFloat? = {
                guard let parentParentID = links.first(where: { $0.toID == parentSeedID })?.fromID else { return nil }
                let siblingIDs = Set(
                    links.filter { $0.fromID == parentParentID && $0.toID != parentSeedID }.map(\.toID)
                )
                let cousinChildLinks = links.filter { siblingIDs.contains($0.fromID) }
                return cousinChildLinks.compactMap { link -> CGFloat? in
                    guard let childNode = nodes.first(where: { $0.id == link.toID }) else { return nil }
                    guard childNode.type != .input && childNode.type != .output else { return nil }
                    return childNode.position.y
                }.sorted().first
            }()

            newPosition = CanvasLayoutEngine.nextChildPosition(parent: selectedNode, existingChildren: children, preferredY: preferredChildY)
            parentIDForNewNode = parentSeedID
            inheritedInputSchemaForNewNode = selectedNode.outputSchema
            parentLinkToneForNewNode =
                links.first(where: { $0.fromID == parentSeedID })?.tone
                ?? links.first(where: { $0.toID == parentSeedID })?.tone
                ?? .blue
        }

        let provider = LLMProvider(rawValue: userTemplate.providerRaw) ?? .chatGPT
        let newNodeID = UUID()
        let newNode = OrgNode(
            id: newNodeID,
            name: userTemplate.name,
            title: userTemplate.title,
            department: userTemplate.department,
            type: type,
            provider: provider,
            roleDescription: userTemplate.roleDescription,
            inputSchema: inheritedInputSchemaForNewNode ?? CanvasLayoutEngine.defaultInputSchema(for: type),
            outputSchema: userTemplate.outputSchema.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? CanvasLayoutEngine.defaultOutputSchema(for: type)
                : userTemplate.outputSchema,
            outputSchemaDescription: userTemplate.outputSchemaDescription,
            selectedRoles: [],
            securityAccess: Set(userTemplate.securityAccessRaw.compactMap { SecurityAccess(rawValue: $0) }),
            assignedTools: Set(userTemplate.assignedToolsRaw),
            position: newPosition
        )

        performSemanticMutation {
            nodes.append(newNode)

            if let parentIDForNewNode {
                links.append(
                    NodeLink(fromID: parentIDForNewNode, toID: newNodeID, tone: parentLinkToneForNewNode)
                )

                if
                    let outputID = nodes.first(where: { $0.type == .output })?.id,
                    let parentToOutputIndex = links.firstIndex(where: {
                        $0.fromID == parentIDForNewNode && $0.toID == outputID
                    })
                {
                    let redirectedLink = links[parentToOutputIndex]
                    links.remove(at: parentToOutputIndex)

                    if !links.contains(where: { $0.fromID == newNodeID && $0.toID == outputID }) {
                        links.append(
                            NodeLink(
                                fromID: newNodeID, toID: outputID,
                                tone: redirectedLink.tone, edgeType: redirectedLink.edgeType
                            )
                        )
                    }
                }
            }

            relayoutHierarchy()
            selectedLinkID = nil
            selectedNodeID = newNode.id
        }
    }

    func deleteSelectedNode() {
        guard let selected = selectedNodeID else { return }
        guard let selectedNode = nodes.first(where: { $0.id == selected }) else { return }
        guard selectedNode.type != .input, selectedNode.type != .output else { return }

        let nodeToDelete = selected
        performSemanticMutation {
            nodes.removeAll { $0.id == nodeToDelete }
            links.removeAll { $0.fromID == nodeToDelete || $0.toID == nodeToDelete }
            selectedNodeID = nil
            relayoutHierarchy()
        }
    }

    func deleteSelectedLink() {
        guard let selectedLinkID else { return }
        performSemanticMutation {
            links.removeAll { $0.id == selectedLinkID }
            self.selectedLinkID = nil
            relayoutHierarchy()
        }
    }

    func deleteCurrentSelection() {
        if selectedLinkID != nil {
            deleteSelectedLink()
            return
        }
        deleteSelectedNode()
    }

    // MARK: - Snapshot Application

    func applyStructureSnapshot(_ snapshot: HierarchySnapshot, registerUndo: Bool = false) {
        let previousSnapshot = registerUndo ? captureStructureSnapshot() : nil
        performSemanticMutation {
            setGraph(from: snapshot, resetViewState: true)
        }
        if registerUndo, let previousSnapshot {
            let undoTarget = UndoClosureTarget { [weak self] in
                self?.applyStructureSnapshot(previousSnapshot, registerUndo: true)
            }
            undoManager?.registerUndo(withTarget: undoTarget) { target in
                target.invoke()
            }
            undoManager?.setActionName("Apply Structure Update")
        }
    }

    func setGraph(from snapshot: HierarchySnapshot, resetViewState: Bool) {
        let restoredNodes = snapshot.nodes.map { entry in
            OrgNode(
                id: entry.id,
                name: entry.name,
                title: entry.title,
                department: entry.department,
                type: entry.type,
                provider: entry.provider,
                roleDescription: entry.roleDescription,
                inputSchema: entry.inputSchema ?? CanvasLayoutEngine.defaultInputSchema(for: entry.type),
                outputSchema: entry.outputSchema ?? CanvasLayoutEngine.defaultOutputSchema(for: entry.type),
                outputSchemaDescription: entry.outputSchemaDescription ?? DefaultSchema.defaultDescription(for: entry.outputSchema ?? CanvasLayoutEngine.defaultOutputSchema(for: entry.type)),
                selectedRoles: Set(entry.selectedRoles),
                securityAccess: Set(entry.securityAccess),
                assignedTools: Set(entry.assignedTools ?? []),
                position: CGPoint(x: entry.positionX, y: entry.positionY)
            )
        }

        let restoredLinks = snapshot.links.map { entry in
            NodeLink(fromID: entry.fromID, toID: entry.toID, tone: entry.tone, edgeType: entry.edgeType)
        }

        guard !restoredNodes.isEmpty else { return }
        let anchored = CanvasLayoutEngine.normalizeAnchorNodes(inputNodes: restoredNodes, inputLinks: restoredLinks)
        let normalizedLinks = CanvasLayoutEngine.normalizeStructuralLinks(forNodes: anchored.nodes, forLinks: anchored.links)

        let previouslySelected = selectedNodeID
        selectedNodeID = nil
        selectedLinkID = nil
        clearLinkDragState()
        if resetViewState {
            viewport.searchText = ""
            viewport.zoom = 1.0
        }
        nodes = anchored.nodes
        links = normalizedLinks
        relayoutHierarchy()

        if let previouslySelected, nodes.contains(where: { $0.id == previouslySelected }) {
            selectedNodeID = previouslySelected
        }
    }

    // MARK: - Undo / Redo

    func undo(syncGraphFromStore: @escaping () -> Void) {
        guard let undoManager else { return }
        undoManager.undo()
        DispatchQueue.main.async { syncGraphFromStore() }
    }

    func redo(syncGraphFromStore: @escaping () -> Void) {
        guard let undoManager else { return }
        undoManager.redo()
        DispatchQueue.main.async { syncGraphFromStore() }
    }

    // MARK: - Simple Task Snapshot

    func simpleTaskSnapshot() -> HierarchySnapshot {
        let inputID = UUID()
        let agentID = UUID()
        let outputID = UUID()
        let cardSize = AppConfiguration.Canvas.cardSize
        let minimumCanvasSize = AppConfiguration.Canvas.minimumSize
        let centerX = minimumCanvasSize.width / 2
        let inputY = (cardSize.height / 2) + AppConfiguration.Canvas.anchorVerticalInset
        let outputY = minimumCanvasSize.height - (cardSize.height / 2) - AppConfiguration.Canvas.anchorVerticalInset
        let agentY = minimumCanvasSize.height / 2
        let basicNodes: [OrgNode] = [
            OrgNode(
                id: inputID, name: "Input", title: "Entry Point", department: "System",
                type: .input, provider: .chatGPT,
                roleDescription: "Fixed start node for task inputs.",
                inputSchema: DefaultSchema.goalBrief, outputSchema: DefaultSchema.goalBrief,
                outputSchemaDescription: DefaultSchema.defaultDescription(for: DefaultSchema.goalBrief),
                selectedRoles: [], securityAccess: [],
                position: CGPoint(x: centerX, y: inputY)
            ),
            OrgNode(
                id: agentID, name: "Task Agent", title: "Generalist", department: "Automation",
                type: .agent, provider: .chatGPT,
                roleDescription: "Handles the task directly end-to-end as a single autonomous worker.",
                inputSchema: DefaultSchema.goalBrief, outputSchema: DefaultSchema.taskResult,
                outputSchemaDescription: DefaultSchema.defaultDescription(for: DefaultSchema.taskResult),
                selectedRoles: [.executor, .planner], securityAccess: [.workspaceRead],
                position: CGPoint(x: centerX, y: agentY)
            ),
            OrgNode(
                id: outputID, name: "Output", title: "Final Result", department: "System",
                type: .output, provider: .chatGPT,
                roleDescription: "Fixed end node for final outputs.",
                inputSchema: DefaultSchema.taskResult, outputSchema: DefaultSchema.taskResult,
                outputSchemaDescription: DefaultSchema.defaultDescription(for: DefaultSchema.taskResult),
                selectedRoles: [], securityAccess: [],
                position: CGPoint(x: centerX, y: outputY)
            )
        ]
        let basicLinks: [NodeLink] = [
            NodeLink(fromID: inputID, toID: agentID, tone: .blue, edgeType: .primary),
            NodeLink(fromID: agentID, toID: outputID, tone: .teal, edgeType: .primary)
        ]
        return makeHierarchySnapshot(nodes: basicNodes, links: basicLinks)
    }

    // MARK: - Layout (delegated to CanvasLayoutEngine)

    func stabilizeLayout(afterAddingAtY rowY: CGFloat, parentID: UUID?) {
        _ = rowY
        _ = parentID
        relayoutHierarchy()
    }

    func relayoutHierarchy() {
        let out = CanvasLayoutEngine.layout(nodes: nodes, links: links)
        nodes = out.nodes
        links = out.links
    }
}
