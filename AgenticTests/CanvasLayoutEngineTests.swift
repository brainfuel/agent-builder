import Testing
import Foundation
import CoreGraphics
@testable import Agentic

/// Unit tests for `CanvasLayoutEngine`.
/// The engine is pure (Foundation + CoreGraphics only), so these tests exercise
/// graph semantics — cycle detection, reachability, link normalization, default
/// schemas — without needing a SwiftUI host.
struct CanvasLayoutEngineTests {

    // MARK: - Helpers

    private func node(
        _ id: UUID = UUID(),
        type: NodeType = .agent,
        at position: CGPoint = .zero,
        name: String = "N"
    ) -> OrgNode {
        OrgNode(
            id: id,
            name: name,
            title: "t",
            department: "d",
            type: type,
            provider: .chatGPT,
            roleDescription: "",
            inputSchema: DefaultSchema.goalBrief,
            outputSchema: DefaultSchema.taskResult,
            outputSchemaDescription: DefaultSchema.defaultDescription(for: DefaultSchema.taskResult),
            selectedRoles: [],
            securityAccess: [],
            position: position
        )
    }

    private func link(from: UUID, to: UUID, tone: LinkTone = .blue) -> NodeLink {
        NodeLink(fromID: from, toID: to, tone: tone)
    }

    // MARK: - Cycle Detection

    @Test func wouldCreateCycle_detectsSelfLoop() {
        let a = UUID()
        #expect(CanvasLayoutEngine.wouldCreateCycle(from: a, to: a, links: []))
    }

    @Test func wouldCreateCycle_detectsDirectBackEdge() {
        let a = UUID(); let b = UUID()
        let links = [link(from: a, to: b)]
        // Adding b → a would close a cycle.
        #expect(CanvasLayoutEngine.wouldCreateCycle(from: b, to: a, links: links))
    }

    @Test func wouldCreateCycle_detectsTransitiveCycle() {
        let a = UUID(); let b = UUID(); let c = UUID()
        let links = [link(from: a, to: b), link(from: b, to: c)]
        // Adding c → a would close a → b → c → a.
        #expect(CanvasLayoutEngine.wouldCreateCycle(from: c, to: a, links: links))
    }

    @Test func wouldCreateCycle_allowsTreeExtensions() {
        let a = UUID(); let b = UUID(); let c = UUID()
        let links = [link(from: a, to: b)]
        // Adding a → c does not create a cycle.
        #expect(!CanvasLayoutEngine.wouldCreateCycle(from: a, to: c, links: links))
    }

    // MARK: - pathExists

    @Test func pathExists_sameNode() {
        let a = UUID()
        #expect(CanvasLayoutEngine.pathExists(from: a, to: a, in: []))
    }

    @Test func pathExists_transitive() {
        let a = UUID(); let b = UUID(); let c = UUID()
        let links = [link(from: a, to: b), link(from: b, to: c)]
        #expect(CanvasLayoutEngine.pathExists(from: a, to: c, in: links))
    }

    @Test func pathExists_returnsFalseWhenDisconnected() {
        let a = UUID(); let b = UUID(); let c = UUID()
        let links = [link(from: a, to: b)]
        #expect(!CanvasLayoutEngine.pathExists(from: a, to: c, in: links))
    }

    @Test func pathExists_respectsEdgeDirection() {
        let a = UUID(); let b = UUID()
        let links = [link(from: a, to: b)]
        // Edges are directed — b → a is not a path.
        #expect(!CanvasLayoutEngine.pathExists(from: b, to: a, in: links))
    }

    // MARK: - Orphan / Runnable

    @Test func computeOrphanNodeIDs_flagsUnreachableWorkNodes() {
        let inputID = UUID(); let a = UUID(); let orphanID = UUID(); let outputID = UUID()
        let nodes = [
            node(inputID, type: .input),
            node(a, type: .agent),
            node(orphanID, type: .agent),
            node(outputID, type: .output),
        ]
        let links = [link(from: inputID, to: a), link(from: a, to: outputID)]
        let orphans = CanvasLayoutEngine.computeOrphanNodeIDs(nodes: nodes, links: links)
        #expect(orphans == [orphanID])
    }

    @Test func computeOrphanNodeIDs_returnsAllWhenNoInputExists() {
        let a = UUID(); let b = UUID()
        let nodes = [node(a, type: .agent), node(b, type: .agent)]
        let orphans = CanvasLayoutEngine.computeOrphanNodeIDs(nodes: nodes, links: [])
        #expect(orphans == Set([a, b]))
    }

    @Test func computeRunnableNodeIDs_returnsReachableFromInput() {
        let inputID = UUID(); let a = UUID(); let b = UUID(); let orphanID = UUID()
        let nodes = [
            node(inputID, type: .input),
            node(a, type: .agent),
            node(b, type: .agent),
            node(orphanID, type: .agent),
        ]
        let links = [link(from: inputID, to: a), link(from: a, to: b)]
        let runnable = CanvasLayoutEngine.computeRunnableNodeIDs(nodes: nodes, links: links)
        #expect(runnable == Set([inputID, a, b]))
        #expect(!runnable.contains(orphanID))
    }

    // MARK: - canLinkDownward

    @Test func canLinkDownward_rejectsUpwardLinks() {
        let topID = UUID(); let bottomID = UUID()
        let nodes = [
            node(topID, at: CGPoint(x: 100, y: 100)),
            node(bottomID, at: CGPoint(x: 100, y: 400)),
        ]
        // bottom → top is upward → must be rejected.
        #expect(!CanvasLayoutEngine.canLinkDownward(from: bottomID, to: topID, candidates: nodes))
    }

    @Test func canLinkDownward_acceptsDownwardLinks() {
        let topID = UUID(); let bottomID = UUID()
        let nodes = [
            node(topID, at: CGPoint(x: 100, y: 100)),
            node(bottomID, at: CGPoint(x: 100, y: 400)),
        ]
        #expect(CanvasLayoutEngine.canLinkDownward(from: topID, to: bottomID, candidates: nodes))
    }

    @Test func canLinkDownward_rejectsSelf() {
        let a = UUID()
        let nodes = [node(a, at: .zero)]
        #expect(!CanvasLayoutEngine.canLinkDownward(from: a, to: a, candidates: nodes))
    }

    // MARK: - Default Schemas

    @Test func defaultInputSchema_mapsByType() {
        #expect(CanvasLayoutEngine.defaultInputSchema(for: .input) == DefaultSchema.goalBrief)
        #expect(CanvasLayoutEngine.defaultInputSchema(for: .agent) == DefaultSchema.goalBrief)
        #expect(CanvasLayoutEngine.defaultInputSchema(for: .human) == DefaultSchema.taskResult)
        #expect(CanvasLayoutEngine.defaultInputSchema(for: .output) == DefaultSchema.taskResult)
    }

    @Test func defaultOutputSchema_mapsByType() {
        #expect(CanvasLayoutEngine.defaultOutputSchema(for: .input) == DefaultSchema.goalBrief)
        #expect(CanvasLayoutEngine.defaultOutputSchema(for: .agent) == DefaultSchema.taskResult)
        #expect(CanvasLayoutEngine.defaultOutputSchema(for: .human) == DefaultSchema.taskResult)
        #expect(CanvasLayoutEngine.defaultOutputSchema(for: .output) == DefaultSchema.taskResult)
    }

    // MARK: - normalizeStructuralLinks

    @Test func normalizeStructuralLinks_dropsDuplicates() {
        let a = UUID(); let b = UUID()
        let nodes = [node(a), node(b)]
        let links = [link(from: a, to: b), link(from: a, to: b, tone: .orange)]
        let result = CanvasLayoutEngine.normalizeStructuralLinks(forNodes: nodes, forLinks: links)
        #expect(result.count == 1)
    }

    @Test func normalizeStructuralLinks_dropsSelfLoops() {
        let a = UUID()
        let nodes = [node(a)]
        let result = CanvasLayoutEngine.normalizeStructuralLinks(
            forNodes: nodes,
            forLinks: [link(from: a, to: a)]
        )
        #expect(result.isEmpty)
    }

    @Test func normalizeStructuralLinks_dropsLinksWithMissingEndpoints() {
        let a = UUID(); let ghost = UUID()
        let nodes = [node(a)]
        let result = CanvasLayoutEngine.normalizeStructuralLinks(
            forNodes: nodes,
            forLinks: [link(from: a, to: ghost)]
        )
        #expect(result.isEmpty)
    }

    @Test func normalizeStructuralLinks_dropsLinksIntoInput() {
        let inputID = UUID(); let a = UUID()
        let nodes = [node(inputID, type: .input), node(a, type: .agent)]
        let result = CanvasLayoutEngine.normalizeStructuralLinks(
            forNodes: nodes,
            forLinks: [link(from: a, to: inputID)]
        )
        #expect(result.isEmpty)
    }

    @Test func normalizeStructuralLinks_dropsLinksFromOutput() {
        let outputID = UUID(); let a = UUID()
        let nodes = [node(outputID, type: .output), node(a, type: .agent)]
        let result = CanvasLayoutEngine.normalizeStructuralLinks(
            forNodes: nodes,
            forLinks: [link(from: outputID, to: a)]
        )
        #expect(result.isEmpty)
    }

    @Test func normalizeStructuralLinks_preservesValidLinks() {
        let a = UUID(); let b = UUID(); let c = UUID()
        let nodes = [node(a), node(b), node(c)]
        let input = [link(from: a, to: b), link(from: b, to: c)]
        let result = CanvasLayoutEngine.normalizeStructuralLinks(forNodes: nodes, forLinks: input)
        #expect(result.count == 2)
    }
}
