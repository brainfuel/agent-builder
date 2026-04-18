import Foundation
import CoreGraphics

/// Pure, stateless layout and graph-geometry algorithms for the canvas editor.
/// Deliberately does not import SwiftUI — all functions take inputs and return outputs
/// so they can be unit-tested without any view or ViewModel machinery.
enum CanvasLayoutEngine {

    // MARK: - Size

    static var cardSize: CGSize { AppConfiguration.Canvas.cardSize }
    static var minimumCanvasSize: CGSize { AppConfiguration.Canvas.minimumSize }

    static func canvasContentSize(for nodes: [OrgNode]) -> CGSize {
        let maxNodeX = nodes.map(\.position.x).max() ?? 0
        let maxNodeY = nodes.map(\.position.y).max() ?? 0
        let requiredWidth = maxNodeX + (cardSize.width / 2) + AppConfiguration.Canvas.horizontalPadding
        let requiredHeight = maxNodeY + (cardSize.height / 2) + AppConfiguration.Canvas.verticalPadding
        return CGSize(
            width: max(minimumCanvasSize.width, requiredWidth),
            height: max(minimumCanvasSize.height, requiredHeight)
        )
    }

    // MARK: - Link Validation

    static func canLinkDownward(from sourceID: UUID, to targetID: UUID, candidates: [OrgNode]) -> Bool {
        guard
            let source = candidates.first(where: { $0.id == sourceID }),
            let target = candidates.first(where: { $0.id == targetID })
        else { return false }

        if source.type == .output || target.type == .input { return false }

        if target.type == .output {
            return source.type == .agent || source.type == .human
        }

        return target.position.y > source.position.y + 8
    }

    // MARK: - Hit Testing

    static func nodeAt(_ point: CGPoint, in list: [OrgNode], excluding excludedID: UUID? = nil) -> OrgNode? {
        for node in list {
            if node.id == excludedID { continue }
            let rect = CGRect(
                x: node.position.x - (cardSize.width / 2),
                y: node.position.y - (cardSize.height / 2),
                width: cardSize.width,
                height: cardSize.height
            )
            if rect.contains(point) { return node }
        }
        return nil
    }

    static func nearestLinkID(to point: CGPoint, nodes: [OrgNode], links: [NodeLink]) -> UUID? {
        let geometries = buildLinkGeometries(nodes: nodes, links: links, cardSize: cardSize)
        let threshold: CGFloat = 16

        var nearest: (id: UUID, distance: CGFloat)?
        for geometry in geometries {
            let dist = minimumDistance(from: point, toPolyline: geometry.points)
            if dist > threshold { continue }
            if let current = nearest {
                if dist < current.distance { nearest = (geometry.link.id, dist) }
            } else {
                nearest = (geometry.link.id, dist)
            }
        }
        return nearest?.id
    }

    // MARK: - Geometry Helpers

    static func minimumDistance(from point: CGPoint, toPolyline points: [CGPoint]) -> CGFloat {
        guard points.count > 1 else { return .greatestFiniteMagnitude }
        var minimum = CGFloat.greatestFiniteMagnitude
        for index in 0..<(points.count - 1) {
            let value = distance(from: point, toSegmentStart: points[index], end: points[index + 1])
            minimum = min(minimum, value)
        }
        return minimum
    }

    static func distance(from point: CGPoint, toSegmentStart start: CGPoint, end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        if abs(dx) < 0.0001 && abs(dy) < 0.0001 {
            let px = point.x - start.x
            let py = point.y - start.y
            return sqrt(px * px + py * py)
        }
        let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / (dx * dx + dy * dy)))
        let projection = CGPoint(x: start.x + t * dx, y: start.y + t * dy)
        let px = point.x - projection.x
        let py = point.y - projection.y
        return sqrt(px * px + py * py)
    }

    // MARK: - Cycle Detection

    static func wouldCreateCycle(from parentID: UUID, to childID: UUID, links: [NodeLink]) -> Bool {
        if parentID == childID { return true }
        let candidate = links + [NodeLink(fromID: parentID, toID: childID, tone: .blue)]
        return pathExists(from: childID, to: parentID, in: candidate)
    }

    static func pathExists(from startID: UUID, to targetID: UUID, in links: [NodeLink]) -> Bool {
        if startID == targetID { return true }
        let adjacency = Dictionary(grouping: links, by: \.fromID)
        var visited: Set<UUID> = []
        var queue: [UUID] = [startID]
        var index = 0
        while index < queue.count {
            let current = queue[index]; index += 1
            if current == targetID { return true }
            if visited.contains(current) { continue }
            visited.insert(current)
            for link in adjacency[current] ?? [] where !visited.contains(link.toID) {
                queue.append(link.toID)
            }
        }
        return false
    }

    // MARK: - Child Position

    static func nextChildPosition(
        parent: OrgNode,
        existingChildren: [OrgNode],
        preferredY: CGFloat?
    ) -> CGPoint {
        let rowSpacing = AppConfiguration.Layout.rowSpacing
        let siblingGap = AppConfiguration.Layout.siblingGap

        let childY = preferredY ?? (parent.position.y + rowSpacing)

        if existingChildren.isEmpty {
            return CGPoint(x: parent.position.x, y: childY)
        }

        let sortedByX = existingChildren.sorted { $0.position.x < $1.position.x }
        let rightmostX = sortedByX.last?.position.x ?? parent.position.x
        let newX = rightmostX + cardSize.width + siblingGap

        return CGPoint(x: newX, y: childY)
    }

    // MARK: - Graph Analysis

    static func computeOrphanNodeIDs(nodes: [OrgNode], links: [NodeLink]) -> Set<UUID> {
        let allIDs = Set(nodes.map(\.id))
        guard let inputID = nodes.first(where: { $0.type == .input })?.id else { return allIDs }

        let adjacency = Dictionary(grouping: links, by: \.fromID).mapValues { $0.map(\.toID) }
        var reachable: Set<UUID> = [inputID]
        var queue = [inputID]
        var head = 0
        while head < queue.count {
            let current = queue[head]; head += 1
            for neighbor in adjacency[current] ?? [] where !reachable.contains(neighbor) {
                reachable.insert(neighbor); queue.append(neighbor)
            }
        }

        if let outputID = nodes.first(where: { $0.type == .output })?.id, !reachable.contains(outputID) {
            reachable.insert(outputID)
        }
        return allIDs.subtracting(reachable)
    }

    static func computeRunnableNodeIDs(nodes: [OrgNode], links: [NodeLink]) -> Set<UUID> {
        guard let inputID = nodes.first(where: { $0.type == .input })?.id else {
            return Set(nodes.map(\.id))
        }
        let adjacency = Dictionary(grouping: links, by: \.fromID).mapValues { $0.map(\.toID) }
        var reachable: Set<UUID> = [inputID]
        var queue = [inputID]
        var head = 0
        while head < queue.count {
            let current = queue[head]; head += 1
            for neighbor in adjacency[current] ?? [] where !reachable.contains(neighbor) {
                reachable.insert(neighbor); queue.append(neighbor)
            }
        }
        return reachable
    }

    // MARK: - Default Schemas

    static func defaultInputSchema(for type: NodeType) -> String {
        switch type {
        case .human: return DefaultSchema.taskResult
        case .agent: return DefaultSchema.goalBrief
        case .input: return DefaultSchema.goalBrief
        case .output: return DefaultSchema.taskResult
        }
    }

    static func defaultOutputSchema(for type: NodeType) -> String {
        switch type {
        case .human: return DefaultSchema.taskResult
        case .agent: return DefaultSchema.taskResult
        case .input: return DefaultSchema.goalBrief
        case .output: return DefaultSchema.taskResult
        }
    }

    // MARK: - Structural Link Normalization

    static func normalizeStructuralLinks(forNodes inputNodes: [OrgNode], forLinks inputLinks: [NodeLink]) -> [NodeLink] {
        let validNodeIDs = Set(inputNodes.map(\.id))
        var result: [NodeLink] = []
        var seen: Set<String> = []

        for link in inputLinks {
            guard validNodeIDs.contains(link.fromID), validNodeIDs.contains(link.toID) else { continue }
            guard link.fromID != link.toID else { continue }

            let key = "\(link.fromID)→\(link.toID)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            if let targetNode = inputNodes.first(where: { $0.id == link.toID }), targetNode.type == .input {
                continue
            }
            if let sourceNode = inputNodes.first(where: { $0.id == link.fromID }), sourceNode.type == .output {
                continue
            }

            result.append(link)
        }

        return result
    }

    // MARK: - Anchor Node Management

    static func anchorAttachmentNodeIDs(nodes: [OrgNode], links: [NodeLink]) -> (rootID: UUID?, sinkID: UUID?) {
        let workNodes = nodes.filter { $0.type != .input && $0.type != .output }
        guard !workNodes.isEmpty else { return (nil, nil) }

        let workNodeIDs = Set(workNodes.map(\.id))
        let internalLinks = links.filter { workNodeIDs.contains($0.fromID) && workNodeIDs.contains($0.toID) }
        let incomingByChildID = Dictionary(grouping: internalLinks, by: \.toID)
        let outgoingByParentID = Dictionary(grouping: internalLinks, by: \.fromID)

        let canvasCenterX = workNodes.map(\.position.x).reduce(0, +) / CGFloat(workNodes.count)
        let rootCandidates = workNodes.filter { incomingByChildID[$0.id] == nil }
        let resolvedRootCandidates = rootCandidates.isEmpty ? workNodes : rootCandidates

        let rootID = resolvedRootCandidates.sorted { lhs, rhs in
            let leftPriority = (lhs.name.localizedCaseInsensitiveContains("coordinator")
                || lhs.title.localizedCaseInsensitiveContains("coordinator")
                || lhs.name.localizedCaseInsensitiveContains("lead")
                || lhs.title.localizedCaseInsensitiveContains("lead")
                || lhs.name.localizedCaseInsensitiveContains("program")
                || lhs.title.localizedCaseInsensitiveContains("program")
                || lhs.name.localizedCaseInsensitiveContains("root")) ? 0 : 1
            let rightPriority = (rhs.name.localizedCaseInsensitiveContains("coordinator")
                || rhs.title.localizedCaseInsensitiveContains("coordinator")
                || rhs.name.localizedCaseInsensitiveContains("lead")
                || rhs.title.localizedCaseInsensitiveContains("lead")
                || rhs.name.localizedCaseInsensitiveContains("program")
                || rhs.title.localizedCaseInsensitiveContains("program")
                || rhs.name.localizedCaseInsensitiveContains("root")) ? 0 : 1
            if leftPriority != rightPriority { return leftPriority < rightPriority }
            if lhs.position.y != rhs.position.y { return lhs.position.y < rhs.position.y }
            let leftCenterDelta = abs(lhs.position.x - canvasCenterX)
            let rightCenterDelta = abs(rhs.position.x - canvasCenterX)
            if leftCenterDelta != rightCenterDelta { return leftCenterDelta < rightCenterDelta }
            return lhs.id.uuidString < rhs.id.uuidString
        }.first?.id

        let leafCandidates = workNodes.filter { outgoingByParentID[$0.id] == nil }
        let resolvedLeafCandidates = leafCandidates.isEmpty ? workNodes : leafCandidates
        let rootX = workNodes.first(where: { $0.id == rootID })?.position.x ?? canvasCenterX

        let sinkID = resolvedLeafCandidates.sorted { lhs, rhs in
            if lhs.position.y != rhs.position.y { return lhs.position.y > rhs.position.y }
            let leftRootDelta = abs(lhs.position.x - rootX)
            let rightRootDelta = abs(rhs.position.x - rootX)
            if leftRootDelta != rightRootDelta { return leftRootDelta < rightRootDelta }
            return lhs.id.uuidString < rhs.id.uuidString
        }.first?.id

        return (rootID, sinkID)
    }

    static func anchorCanvasSize(for anchorNodes: [OrgNode]) -> CGSize {
        let maxNodeX = anchorNodes.map(\.position.x).max() ?? (minimumCanvasSize.width / 2)
        let maxNodeY = anchorNodes.map(\.position.y).max() ?? (minimumCanvasSize.height / 2)
        let requiredWidth = maxNodeX + (cardSize.width / 2) + AppConfiguration.Canvas.horizontalPadding
        let requiredHeight = maxNodeY + (cardSize.height / 2) + AppConfiguration.Canvas.verticalPadding
        return CGSize(
            width: max(minimumCanvasSize.width, requiredWidth),
            height: max(minimumCanvasSize.height, requiredHeight)
        )
    }

    static func preferredAnchorPositions(for anchorNodes: [OrgNode], links anchorLinks: [NodeLink]) -> (input: CGPoint, output: CGPoint) {
        let canvasSize = anchorCanvasSize(for: anchorNodes)
        let defaultCenterX = canvasSize.width / 2
        let topInset = (cardSize.height / 2) + AppConfiguration.Canvas.anchorVerticalInset
        let bottomInset = canvasSize.height - (cardSize.height / 2) - AppConfiguration.Canvas.anchorVerticalInset
        let verticalOffset: CGFloat = 164

        let attachments = anchorAttachmentNodeIDs(nodes: anchorNodes, links: anchorLinks)
        let rootNode = attachments.rootID.flatMap { id in anchorNodes.first(where: { $0.id == id }) }
        let sinkNode = attachments.sinkID.flatMap { id in anchorNodes.first(where: { $0.id == id }) }
        let inputID = anchorNodes.first(where: { $0.type == .input })?.id
        let outputID = anchorNodes.first(where: { $0.type == .output })?.id

        let inputChildNodes: [OrgNode] = {
            guard let inputID else { return [] }
            let childIDs = Set(anchorLinks.filter { $0.fromID == inputID }.map(\.toID))
            return anchorNodes.filter { childIDs.contains($0.id) && $0.type != .input && $0.type != .output }
        }()
        let outputParentNodes: [OrgNode] = {
            guard let outputID else { return [] }
            let outputParentIDs = Set(anchorLinks.filter { $0.toID == outputID }.map(\.fromID))
            return anchorNodes.filter { outputParentIDs.contains($0.id) && $0.type != .input && $0.type != .output }
        }()

        let inputX: CGFloat
        let topChildY: CGFloat
        if !inputChildNodes.isEmpty {
            inputX = inputChildNodes.map(\.position.x).reduce(0, +) / CGFloat(inputChildNodes.count)
            topChildY = inputChildNodes.map(\.position.y).min() ?? topInset
        } else {
            inputX = rootNode?.position.x ?? defaultCenterX
            topChildY = rootNode?.position.y ?? topInset
        }
        let inputY = max(topInset, topChildY - verticalOffset)

        let outputX: CGFloat
        let proposedOutputY: CGFloat
        if outputParentNodes.isEmpty {
            outputX = sinkNode?.position.x ?? defaultCenterX
            proposedOutputY = (sinkNode?.position.y ?? (bottomInset - verticalOffset)) + verticalOffset
        } else {
            outputX = outputParentNodes.map(\.position.x).reduce(0, +) / CGFloat(outputParentNodes.count)
            let maxParentY = outputParentNodes.map(\.position.y).max() ?? (bottomInset - verticalOffset)
            proposedOutputY = maxParentY + verticalOffset
        }
        let outputY = min(bottomInset, max(inputY + 180, proposedOutputY))

        return (
            input: CGPoint(x: inputX, y: inputY),
            output: CGPoint(x: outputX, y: outputY)
        )
    }

    static func makeAnchorNode(type: NodeType, id: UUID, position: CGPoint) -> OrgNode {
        let isInput = type == .input
        return OrgNode(
            id: id,
            name: isInput ? "Input" : "Output",
            title: isInput ? "Entry Point" : "Final Result",
            department: "System",
            type: type,
            provider: .chatGPT,
            roleDescription: isInput
                ? "Fixed start node for task inputs."
                : "Fixed end node for final outputs.",
            inputSchema: defaultInputSchema(for: type),
            outputSchema: defaultOutputSchema(for: type),
            outputSchemaDescription: DefaultSchema.defaultDescription(for: defaultOutputSchema(for: type)),
            selectedRoles: [],
            securityAccess: [],
            position: position
        )
    }

    static func normalizeAnchorNodes(inputNodes: [OrgNode], inputLinks: [NodeLink]) -> (nodes: [OrgNode], links: [NodeLink]) {
        var mutableNodes = inputNodes
        var mutableLinks = inputLinks

        let inputCandidates = mutableNodes.enumerated().filter { $0.element.type == .input }.map(\.offset)
        let outputCandidates = mutableNodes.enumerated().filter { $0.element.type == .output }.map(\.offset)

        var removalIDs: Set<UUID> = []
        for index in inputCandidates.dropFirst() { removalIDs.insert(mutableNodes[index].id) }
        for index in outputCandidates.dropFirst() { removalIDs.insert(mutableNodes[index].id) }
        if !removalIDs.isEmpty {
            mutableNodes.removeAll { removalIDs.contains($0.id) }
            mutableLinks.removeAll { removalIDs.contains($0.fromID) || removalIDs.contains($0.toID) }
        }

        let defaultCenterX = anchorCanvasSize(for: mutableNodes).width / 2
        let defaultInputPosition = CGPoint(
            x: defaultCenterX,
            y: (cardSize.height / 2) + AppConfiguration.Canvas.anchorVerticalInset
        )
        let defaultOutputPosition = CGPoint(
            x: defaultCenterX,
            y: anchorCanvasSize(for: mutableNodes).height - (cardSize.height / 2) - AppConfiguration.Canvas.anchorVerticalInset
        )

        if mutableNodes.firstIndex(where: { $0.type == .input }) == nil {
            mutableNodes.append(makeAnchorNode(type: .input, id: UUID(), position: defaultInputPosition))
        }
        if mutableNodes.firstIndex(where: { $0.type == .output }) == nil {
            mutableNodes.append(makeAnchorNode(type: .output, id: UUID(), position: defaultOutputPosition))
        }

        guard
            let inputIndex = mutableNodes.firstIndex(where: { $0.type == .input }),
            let outputIndex = mutableNodes.firstIndex(where: { $0.type == .output })
        else { return (nodes: mutableNodes, links: mutableLinks) }

        let inputID = mutableNodes[inputIndex].id
        let outputID = mutableNodes[outputIndex].id

        let validIDs = Set(mutableNodes.map(\.id))
        mutableLinks = mutableLinks.filter {
            validIDs.contains($0.fromID) && validIDs.contains($0.toID) && $0.fromID != $0.toID
        }
        let workNodeIDs = Set(mutableNodes.filter { $0.type != .input && $0.type != .output }.map(\.id))
        let preferredRootID = mutableLinks.first(where: { $0.fromID == inputID && workNodeIDs.contains($0.toID) })?.toID
        let preferredOutputParentIDs = mutableLinks
            .filter { $0.toID == outputID && workNodeIDs.contains($0.fromID) }
            .map(\.fromID)
        mutableLinks.removeAll {
            $0.fromID == inputID || $0.toID == inputID || $0.fromID == outputID || $0.toID == outputID
        }

        let attachments = anchorAttachmentNodeIDs(nodes: mutableNodes, links: mutableLinks)

        let internalLinks = mutableLinks.filter { workNodeIDs.contains($0.fromID) && workNodeIDs.contains($0.toID) }
        let incomingByChildID = Dictionary(grouping: internalLinks, by: \.toID)
        let allRootIDs = mutableNodes
            .filter { workNodeIDs.contains($0.id) && incomingByChildID[$0.id] == nil }
            .map(\.id)

        let resolvedRootIDs: [UUID]
        if !allRootIDs.isEmpty {
            resolvedRootIDs = allRootIDs
        } else if let preferredRootID, workNodeIDs.contains(preferredRootID) {
            resolvedRootIDs = [preferredRootID]
        } else if let fallback = attachments.rootID {
            resolvedRootIDs = [fallback]
        } else {
            resolvedRootIDs = []
        }
        let resolvedRootID = resolvedRootIDs.first
        for rootID in resolvedRootIDs {
            mutableLinks.append(NodeLink(fromID: inputID, toID: rootID, tone: .blue, edgeType: .primary))
        }

        let resolvedSinkIDs: [UUID] = {
            guard let resolvedRootID, workNodeIDs.contains(resolvedRootID) else {
                let preferred = preferredOutputParentIDs.filter { workNodeIDs.contains($0) }
                if !preferred.isEmpty { return preferred }
                if let sinkID = attachments.sinkID { return [sinkID] }
                return []
            }

            let internalLinks = mutableLinks.filter { workNodeIDs.contains($0.fromID) && workNodeIDs.contains($0.toID) }
            let outgoingByParentID = Dictionary(grouping: internalLinks, by: \.fromID)

            var reachable: Set<UUID> = []
            var queue: [UUID] = resolvedRootIDs
            var head = 0
            while head < queue.count {
                let nodeID = queue[head]; head += 1
                if reachable.contains(nodeID) { continue }
                reachable.insert(nodeID)
                for childID in (outgoingByParentID[nodeID] ?? []).map(\.toID) where !reachable.contains(childID) {
                    queue.append(childID)
                }
            }

            guard !reachable.isEmpty else {
                if let sinkID = attachments.sinkID { return [sinkID] }
                return []
            }

            let leaves = reachable.filter { outgoingByParentID[$0] == nil }
            if leaves.isEmpty {
                let rootX = mutableNodes.first(where: { $0.id == resolvedRootID })?.position.x ?? 0
                if let best = reachable.sorted(by: { lhs, rhs in
                    let leftY = mutableNodes.first(where: { $0.id == lhs })?.position.y ?? 0
                    let rightY = mutableNodes.first(where: { $0.id == rhs })?.position.y ?? 0
                    if leftY != rightY { return leftY > rightY }
                    let leftDelta = abs((mutableNodes.first(where: { $0.id == lhs })?.position.x ?? 0) - rootX)
                    let rightDelta = abs((mutableNodes.first(where: { $0.id == rhs })?.position.x ?? 0) - rootX)
                    return leftDelta < rightDelta
                }).first {
                    return [best]
                }
                return []
            }

            return Array(leaves)
        }()
        for sinkID in resolvedSinkIDs {
            mutableLinks.append(NodeLink(fromID: sinkID, toID: outputID, tone: .teal, edgeType: .primary))
        }

        let anchorPositions = preferredAnchorPositions(for: mutableNodes, links: mutableLinks)
        mutableNodes[inputIndex].position = anchorPositions.input
        mutableNodes[outputIndex].position = anchorPositions.output

        mutableNodes[inputIndex].provider = .chatGPT
        mutableNodes[outputIndex].provider = .chatGPT
        mutableNodes[inputIndex].inputSchema = defaultInputSchema(for: .input)
        mutableNodes[inputIndex].outputSchema = defaultOutputSchema(for: .input)
        mutableNodes[outputIndex].inputSchema = defaultInputSchema(for: .output)
        mutableNodes[outputIndex].outputSchema = defaultOutputSchema(for: .output)
        mutableNodes[inputIndex].securityAccess = []
        mutableNodes[outputIndex].securityAccess = []
        mutableNodes[inputIndex].selectedRoles = []
        mutableNodes[outputIndex].selectedRoles = []
        if mutableNodes[inputIndex].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            mutableNodes[inputIndex].name = "Input"
        }
        if mutableNodes[outputIndex].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            mutableNodes[outputIndex].name = "Output"
        }

        return (nodes: mutableNodes, links: mutableLinks)
    }

    // MARK: - Hierarchy Layout

    /// Core tree-layout algorithm. Takes nodes and links, returns a new layout with
    /// repositioned nodes (anchor-normalized, row-packed, horizontally centered, orphans at bottom).
    /// Completely pure — no reads of external state, no side effects.
    static func layout(nodes inputNodes: [OrgNode], links inputLinks: [NodeLink]) -> (nodes: [OrgNode], links: [NodeLink]) {
        let anchored = normalizeAnchorNodes(inputNodes: inputNodes, inputLinks: inputLinks)
        var nodes = anchored.nodes
        let links = anchored.links

        guard !nodes.isEmpty else { return (nodes, links) }

        let minX = (cardSize.width / 2) + AppConfiguration.Canvas.layoutHorizontalInset
        let topY = AppConfiguration.Layout.topY
        let rowSpacing = AppConfiguration.Layout.rowSpacing
        let siblingGap = AppConfiguration.Layout.siblingGap
        let rootGap = AppConfiguration.Layout.rootGap

        let allNodeIDs = Set(nodes.map(\.id))
        let orphanIDs = computeOrphanNodeIDs(nodes: nodes, links: links)
        let layoutNodeIDs = allNodeIDs.subtracting(orphanIDs)
        let nodeByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let currentXByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.position.x) })
        let layoutLinks = links.filter { layoutNodeIDs.contains($0.fromID) && layoutNodeIDs.contains($0.toID) }
        let primaryParentByChildID = computePrimaryParentByChild(
            nodeIDs: layoutNodeIDs,
            links: layoutLinks,
            currentXByID: currentXByID
        )

        var treeChildrenByParentID: [UUID: [UUID]] = [:]
        for link in layoutLinks where primaryParentByChildID[link.toID] == link.fromID {
            treeChildrenByParentID[link.fromID, default: []].append(link.toID)
        }
        for (parentID, children) in treeChildrenByParentID {
            treeChildrenByParentID[parentID] = children.sorted { lhs, rhs in
                let lx = currentXByID[lhs] ?? 0
                let rx = currentXByID[rhs] ?? 0
                if lx == rx { return lhs.uuidString < rhs.uuidString }
                return lx < rx
            }
        }

        let rootIDs = layoutNodeIDs.filter { primaryParentByChildID[$0] == nil }.sorted { lhs, rhs in
            let lx = currentXByID[lhs] ?? 0
            let rx = currentXByID[rhs] ?? 0
            if lx == rx { return lhs.uuidString < rhs.uuidString }
            return lx < rx
        }

        var depthByID: [UUID: Int] = [:]
        var queue = rootIDs
        var head = 0

        for rootID in rootIDs { depthByID[rootID] = 0 }

        while head < queue.count {
            let nodeID = queue[head]; head += 1
            let depth = depthByID[nodeID] ?? 0
            for childID in treeChildrenByParentID[nodeID] ?? [] {
                let childDepth = depth + 1
                if depthByID[childID] == nil || childDepth < (depthByID[childID] ?? childDepth) {
                    depthByID[childID] = childDepth
                    queue.append(childID)
                }
            }
        }

        for nodeID in layoutNodeIDs where depthByID[nodeID] == nil {
            if let node = nodeByID[nodeID] {
                let approxDepth = Int(((node.position.y - topY) / rowSpacing).rounded())
                depthByID[nodeID] = max(0, approxDepth)
            } else {
                depthByID[nodeID] = 0
            }
        }

        var subtreeWidthByID: [UUID: CGFloat] = [:]
        var xByID: [UUID: CGFloat] = [:]

        func subtreeWidth(for nodeID: UUID, visiting: inout Set<UUID>) -> CGFloat {
            if let cached = subtreeWidthByID[nodeID] { return cached }
            if visiting.contains(nodeID) { return cardSize.width }

            visiting.insert(nodeID)
            let children = treeChildrenByParentID[nodeID] ?? []
            if children.isEmpty {
                visiting.remove(nodeID)
                subtreeWidthByID[nodeID] = cardSize.width
                return cardSize.width
            }

            let totalChildrenWidth = children.reduce(CGFloat(0)) { partial, childID in
                partial + subtreeWidth(for: childID, visiting: &visiting)
            } + CGFloat(max(0, children.count - 1)) * siblingGap

            let width = max(cardSize.width, totalChildrenWidth)
            visiting.remove(nodeID)
            subtreeWidthByID[nodeID] = width
            return width
        }

        for rootID in rootIDs {
            var visiting: Set<UUID> = []
            _ = subtreeWidth(for: rootID, visiting: &visiting)
        }

        func placeSubtree(_ nodeID: UUID, left: CGFloat, visiting: inout Set<UUID>) {
            if visiting.contains(nodeID) { return }
            visiting.insert(nodeID)

            let children = treeChildrenByParentID[nodeID] ?? []
            let nodeWidth = subtreeWidthByID[nodeID] ?? cardSize.width

            if children.isEmpty {
                xByID[nodeID] = left + (nodeWidth / 2)
                visiting.remove(nodeID)
                return
            }

            let totalChildrenWidth = children.reduce(CGFloat(0)) { partial, childID in
                partial + (subtreeWidthByID[childID] ?? cardSize.width)
            } + CGFloat(max(0, children.count - 1)) * siblingGap
            var cursor = left + ((nodeWidth - totalChildrenWidth) / 2)

            for childID in children {
                placeSubtree(childID, left: cursor, visiting: &visiting)
                cursor += (subtreeWidthByID[childID] ?? cardSize.width) + siblingGap
            }

            let childXs = children.compactMap { xByID[$0] }
            if let minChildX = childXs.min(), let maxChildX = childXs.max() {
                xByID[nodeID] = (minChildX + maxChildX) / 2
            } else {
                xByID[nodeID] = left + (nodeWidth / 2)
            }
            visiting.remove(nodeID)
        }

        var rootCursor = minX
        for rootID in rootIDs {
            let rootWidth = subtreeWidthByID[rootID] ?? cardSize.width
            var visiting: Set<UUID> = []
            placeSubtree(rootID, left: rootCursor, visiting: &visiting)
            rootCursor += rootWidth + rootGap
        }

        let missingIDs = layoutNodeIDs.subtracting(Set(xByID.keys)).sorted { lhs, rhs in
            let lx = currentXByID[lhs] ?? 0
            let rx = currentXByID[rhs] ?? 0
            if lx == rx { return lhs.uuidString < rhs.uuidString }
            return lx < rx
        }
        for nodeID in missingIDs {
            xByID[nodeID] = rootCursor + (cardSize.width / 2)
            rootCursor += cardSize.width + rootGap
        }

        // Multi-parent alignment
        let incomingParentIDsByChild = Dictionary(grouping: layoutLinks, by: \.toID).mapValues { grouped in
            grouped.map(\.fromID)
        }

        func shiftSubtree(_ nodeID: UUID, delta: CGFloat) {
            for childID in treeChildrenByParentID[nodeID] ?? [] {
                xByID[childID] = (xByID[childID] ?? 0) + delta
                shiftSubtree(childID, delta: delta)
            }
        }

        let multiParentIDs = incomingParentIDsByChild
            .filter { $0.value.count > 1 }
            .keys
            .sorted { (depthByID[$0] ?? 0) < (depthByID[$1] ?? 0) }

        for childID in multiParentIDs {
            guard let parentIDs = incomingParentIDsByChild[childID], parentIDs.count > 1 else { continue }
            let parentXs = parentIDs.compactMap { xByID[$0] }
            guard !parentXs.isEmpty else { continue }
            let idealX = parentXs.reduce(0, +) / CGFloat(parentXs.count)
            let currentX = xByID[childID] ?? 0
            let delta = idealX - currentX
            if abs(delta) > 1 {
                xByID[childID] = idealX
                shiftSubtree(childID, delta: delta)
            }
        }

        // Row packing: ensure minimum horizontal separation between same-depth nodes
        let minimumHorizontalSeparation = cardSize.width + siblingGap
        let maxDepth = depthByID.values.max() ?? 0
        for depth in 0...maxDepth {
            var rowIDs: [UUID] = layoutNodeIDs.filter { depthByID[$0] == depth }
            rowIDs = rowIDs.filter { id in
                guard let node = nodeByID[id] else { return false }
                return node.type != .input && node.type != .output
            }
            if rowIDs.count < 2 { continue }

            rowIDs.sort { lhs, rhs in
                let lx = xByID[lhs] ?? 0
                let rx = xByID[rhs] ?? 0
                if lx == rx { return lhs.uuidString < rhs.uuidString }
                return lx < rx
            }

            var packed: [UUID: CGFloat] = [:]
            var cursor = max(minX, xByID[rowIDs[0]] ?? minX)
            packed[rowIDs[0]] = cursor

            for id in rowIDs.dropFirst() {
                let target = xByID[id] ?? cursor
                cursor = max(target, cursor + minimumHorizontalSeparation)
                packed[id] = cursor
            }

            // Preserve row center after packing to avoid cumulative drift
            let targetCenter = rowIDs.compactMap { xByID[$0] }.reduce(0, +) / CGFloat(rowIDs.count)
            let packedCenter = rowIDs.compactMap { packed[$0] }.reduce(0, +) / CGFloat(rowIDs.count)
            let centerDelta = targetCenter - packedCenter
            if abs(centerDelta) > 0.001 {
                for id in rowIDs { packed[id] = (packed[id] ?? 0) + centerDelta }
                var repackCursor = max(minX, packed[rowIDs[0]] ?? minX)
                packed[rowIDs[0]] = repackCursor
                for id in rowIDs.dropFirst() {
                    let target = packed[id] ?? repackCursor
                    repackCursor = max(target, repackCursor + minimumHorizontalSeparation)
                    packed[id] = repackCursor
                }
            }

            for id in rowIDs {
                if let packedX = packed[id] { xByID[id] = packedX }
            }
        }

        // Center the entire layout horizontally in the canvas so the graph
        // isn't left-aligned and the centering button works correctly.
        let workLayoutXValues = layoutNodeIDs.filter { id in
            nodeByID[id].map { $0.type != .input && $0.type != .output } ?? false
        }.compactMap { xByID[$0] }
        if let layoutMinX = workLayoutXValues.min(), let layoutMaxX = workLayoutXValues.max() {
            let layoutCenter = (layoutMinX + layoutMaxX) / 2
            let canvasCenter = max(minimumCanvasSize.width, (layoutMaxX + cardSize.width / 2 + AppConfiguration.Canvas.horizontalPadding)) / 2
            let shift = canvasCenter - layoutCenter
            if abs(shift) > 1 {
                for id in layoutNodeIDs { xByID[id] = (xByID[id] ?? 0) + shift }
            }
        }

        // Apply final positions for all layout nodes
        for i in nodes.indices {
            let nodeID = nodes[i].id
            guard layoutNodeIDs.contains(nodeID) else { continue }
            let depth = depthByID[nodeID] ?? 0
            let y = topY + CGFloat(depth) * rowSpacing
            let x = xByID[nodeID] ?? nodes[i].position.x
            nodes[i].position = CGPoint(x: x, y: y)
        }

        // Re-apply anchor positions so Input/Output align to the now-centered tree
        let anchorPositions = preferredAnchorPositions(for: nodes, links: links)
        if let inputIndex = nodes.firstIndex(where: { $0.type == .input }) {
            nodes[inputIndex].position = anchorPositions.input
        }
        if let outputIndex = nodes.firstIndex(where: { $0.type == .output }) {
            nodes[outputIndex].position = anchorPositions.output
        }

        // Position orphans at the bottom
        let orphanList = nodes.filter { orphanIDs.contains($0.id) && $0.type != .input && $0.type != .output }
        if !orphanList.isEmpty {
            let maxLayoutY = nodes
                .filter { layoutNodeIDs.contains($0.id) }
                .map(\.position.y).max() ?? topY
            let orphanStartY = maxLayoutY + rowSpacing * 1.5
            var orphanCursor = minX
            for orphan in orphanList {
                guard let idx = nodes.firstIndex(where: { $0.id == orphan.id }) else { continue }
                nodes[idx].position = CGPoint(x: orphanCursor + (cardSize.width / 2), y: orphanStartY)
                orphanCursor += cardSize.width + siblingGap
            }
        }

        return (nodes, links)
    }
}
