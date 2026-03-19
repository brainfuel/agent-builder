import SwiftUI
import SwiftData

struct ContentView: View {
    private let cardSize = CGSize(width: 264, height: 88)
    private let minimumCanvasSize = CGSize(width: 1900, height: 1200)
    private let minZoom: CGFloat = 0.6
    private let maxZoom: CGFloat = 1.5
    private let zoomStep: CGFloat = 0.1
    private let savedStructuresDefaultsKey = "agentic.savedStructures.v1"
    private let activeGraphKey = "active"

    @Environment(\.modelContext) private var modelContext
    @Environment(\.undoManager) private var undoManager
    @Query private var graphDocuments: [GraphDocument]
    @State private var nodes = OrgNode.sample
    @State private var links = NodeLink.sample
    @State private var selectedNodeID: OrgNode.ID?
    @State private var searchText = ""
    @State private var zoom: CGFloat = 1.0
    @State private var savedStructures: [SavedHierarchy] = []
    @State private var isShowingSaveStructurePrompt = false
    @State private var saveStructureName = ""
    @State private var suppressStoreSync = false
    @State private var lastPersistedFingerprint = ""
    @State private var selectedLinkID: UUID?
    @State private var linkingFromNodeID: UUID?
    @State private var linkingPointer: CGPoint?
    @State private var linkHoverTargetNodeID: UUID?
    @State private var orchestrationGoal = "Prepare a safe v1 launch plan"
    @State private var latestCoordinatorPlan: CoordinatorPlan?
    @State private var latestCoordinatorRun: CoordinatorRun?
    @State private var isExecutingCoordinator = false
    @State private var coordinatorRunMode: CoordinatorExecutionMode = .simulation
    @State private var coordinatorTrace: [CoordinatorTraceStep] = []

    private var visibleNodes: [OrgNode] {
        guard !searchText.isEmpty else { return nodes }
        return nodes.filter { node in
            node.name.localizedCaseInsensitiveContains(searchText) ||
            node.title.localizedCaseInsensitiveContains(searchText) ||
            node.department.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var canvasContentSize: CGSize {
        let maxNodeX = nodes.map(\.position.x).max() ?? 0
        let maxNodeY = nodes.map(\.position.y).max() ?? 0
        let requiredWidth = maxNodeX + (cardSize.width / 2) + 240
        let requiredHeight = maxNodeY + (cardSize.height / 2) + 220

        return CGSize(
            width: max(minimumCanvasSize.width, requiredWidth),
            height: max(minimumCanvasSize.height, requiredHeight)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            orchestrationBar
            Divider()
            HStack(spacing: 0) {
                chartCanvas
                if selectedIndex != nil {
                    Divider()
                    inspectorPanel
                        .frame(minWidth: 320, idealWidth: 360, maxWidth: 420)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .animation(.easeInOut(duration: 0.18), value: selectedNodeID)
        .onAppear {
            loadSavedHierarchies()
            modelContext.undoManager = undoManager
            ensureActiveGraphDocument()
            syncGraphFromStore()
            DispatchQueue.main.async {
                syncGraphFromStore()
            }
        }
        .onChange(of: semanticFingerprint) { _, newValue in
            persistGraphIfNeeded(for: newValue)
        }
        .alert("Save Structure", isPresented: $isShowingSaveStructurePrompt) {
            TextField("Structure name", text: $saveStructureName)
            Button("Cancel", role: .cancel) {
                saveStructureName = ""
            }
            Button("Save") {
                let trimmed = saveStructureName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                saveCurrentStructure(named: trimmed)
                saveStructureName = ""
            }
        } message: {
            Text("Save the current hierarchy so you can reload it later.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Agent Hierarchy Builder")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Design structures of humans and AI agents.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search node", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(width: 300)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemBackground))
                )

                Button {
                    addNode(type: .agent)
                } label: {
                    Label("Add Agent", systemImage: "sparkles")
                        .font(.headline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    addNode(type: .human)
                } label: {
                    Label("Add Human", systemImage: "person.badge.plus")
                        .font(.headline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)

                Menu {
                    ForEach(PresetHierarchyTemplate.allCases) { template in
                        Button(template.title) {
                            applyStructureSnapshot(template.snapshot())
                        }
                    }
                } label: {
                    Label("Templates", systemImage: "square.grid.2x2")
                        .font(.headline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)

                Menu {
                    Button {
                        saveStructureName = suggestedSaveName()
                        isShowingSaveStructurePrompt = true
                    } label: {
                        Label("Save Current Structure", systemImage: "square.and.arrow.down")
                    }

                    if !savedStructures.isEmpty {
                        Divider()
                        ForEach(savedStructures) { saved in
                            Button(saved.name) {
                                applyStructureSnapshot(saved.snapshot)
                            }
                        }
                        Divider()
                        Menu("Delete Saved Structure") {
                            ForEach(savedStructures) { saved in
                                Button(role: .destructive) {
                                    deleteSavedStructure(id: saved.id)
                                } label: {
                                    Text(saved.name)
                                }
                            }
                        }
                    }
                } label: {
                    Label("Structures", systemImage: "tray.full")
                        .font(.headline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)

                Button {
                    undo()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                        .font(.headline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .disabled(!(undoManager?.canUndo ?? false))
                .keyboardShortcut("z", modifiers: [.command])

                Button {
                    redo()
                } label: {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                        .font(.headline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .disabled(!(undoManager?.canRedo ?? false))
                .keyboardShortcut("Z", modifiers: [.command, .shift])

                Button(role: .destructive) {
                    deleteCurrentSelection()
                } label: {
                    Label(selectedLinkID == nil ? "Delete Node" : "Delete Link", systemImage: "trash")
                        .font(.headline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .disabled(selectedNodeID == nil && selectedLinkID == nil)
                .keyboardShortcut(.delete, modifiers: [])
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(Color(uiColor: .systemBackground))
    }

    private var orchestrationBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label("Coordinator Goal", systemImage: "point.3.filled.connected.trianglepath.dotted")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                TextField("Describe what the coordinator should delegate...", text: $orchestrationGoal)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1)

                Picker("Execution Mode", selection: $coordinatorRunMode) {
                    ForEach(CoordinatorExecutionMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)

                Button {
                    runCoordinatorPipeline()
                } label: {
                    if isExecutingCoordinator {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(coordinatorRunMode == .simulation ? "Simulate" : "Run Live")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isExecutingCoordinator || nodes.isEmpty)
            }

            if let latestCoordinatorPlan {
                Text("Planned \(latestCoordinatorPlan.packets.count) task packets from coordinator \(latestCoordinatorPlan.coordinatorName).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let latestCoordinatorRun {
                Text(
                    "Last \(latestCoordinatorRun.mode.label.lowercased()) run: \(latestCoordinatorRun.succeededCount)/\(latestCoordinatorRun.results.count) tasks succeeded."
                )
                    .font(.footnote)
                    .foregroundStyle(latestCoordinatorRun.succeededCount == latestCoordinatorRun.results.count ? .green : .orange)
            }

            if !coordinatorTrace.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Run Trace")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear") {
                            coordinatorTrace = []
                        }
                        .buttonStyle(.borderless)
                        .font(.footnote)
                        .disabled(isExecutingCoordinator)
                    }

                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(Array(coordinatorTrace.enumerated()), id: \.element.id) { index, step in
                                CoordinatorTraceRow(stepNumber: index + 1, step: step)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(maxHeight: 200)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private var inspectorPanel: some View {
        ScrollView {
            if let selectedIndex {
                NodeInspector(node: $nodes[selectedIndex])
                    .padding(20)
            }
        }
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private var chartCanvas: some View {
        let canvasSize = canvasContentSize
        let visibleIDs = Set(visibleNodes.map(\.id))
        let visibleLinks = links.filter { link in
            visibleIDs.contains(link.fromID) && visibleIDs.contains(link.toID)
        }

        return ZStack(alignment: .bottomTrailing) {
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    DotGridBackground()
                        .frame(width: canvasSize.width, height: canvasSize.height)

                    ConnectionLayer(
                        nodes: visibleNodes,
                        links: visibleLinks,
                        cardSize: cardSize,
                        selectedLinkID: selectedLinkID,
                        draft: linkDraft
                    )
                    .frame(width: canvasSize.width, height: canvasSize.height)

                    ForEach(visibleNodes) { node in
                        NodeCard(
                            node: node,
                            isSelected: node.id == selectedNodeID,
                            isLinkTargeted: node.id == linkHoverTargetNodeID
                        )
                            .frame(width: cardSize.width, height: cardSize.height)
                            .position(node.position)
                            .animation(.spring(response: 0.5, dampingFraction: 0.82), value: node.position.x)
                            .animation(.spring(response: 0.5, dampingFraction: 0.82), value: node.position.y)
                            .onTapGesture {
                                clearLinkDragState()
                                selectedLinkID = nil
                                selectedNodeID = (selectedNodeID == node.id) ? nil : node.id
                            }
                    }

                    if
                        let selectedNodeID,
                        let selectedNode = visibleNodes.first(where: { $0.id == selectedNodeID })
                    {
                        LinkHandle(isActive: linkingFromNodeID == selectedNodeID)
                            .position(
                                x: selectedNode.position.x,
                                y: selectedNode.position.y + (cardSize.height / 2) + 18
                            )
                            .gesture(
                                DragGesture(minimumDistance: 0, coordinateSpace: .named("chart-canvas"))
                                    .onChanged { value in
                                        updateLinkDrag(
                                            sourceID: selectedNodeID,
                                            pointer: value.location,
                                            candidateNodes: visibleNodes
                                        )
                                    }
                                    .onEnded { _ in
                                        completeLinkDrag(candidateNodes: visibleNodes)
                                    }
                            )
                    }
                }
                .coordinateSpace(name: "chart-canvas")
                .simultaneousGesture(
                    SpatialTapGesture(coordinateSpace: .named("chart-canvas"))
                        .onEnded { value in
                            handleCanvasTap(
                                at: value.location,
                                visibleNodes: visibleNodes,
                                visibleLinks: visibleLinks
                            )
                        }
                )
                .padding(24)
                .scaleEffect(zoom, anchor: .topLeading)
                .frame(
                    width: (canvasSize.width + 48) * zoom,
                    height: (canvasSize.height + 48) * zoom,
                    alignment: .topLeading
                )
            }
            .background(Color(red: 0.92, green: 0.93, blue: 0.96))

            zoomControls
                .padding(20)
        }
    }

    private var zoomControls: some View {
        VStack(alignment: .trailing, spacing: 10) {
            Button {
                zoom = 1.0
            } label: {
                Text("Center View")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.indigo)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            HStack(spacing: 12) {
                Button {
                    adjustZoom(stepDelta: -1)
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 46, height: 46)
                        .contentShape(Rectangle())
                }
                Text("\(Int((zoom * 100).rounded()))%")
                    .frame(minWidth: 48)
                    .font(.system(.headline, design: .rounded))
                Button {
                    adjustZoom(stepDelta: 1)
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 28, height: 28)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        }
    }

    private var selectedIndex: Int? {
        guard let selectedNodeID else { return nil }
        return nodes.firstIndex(where: { $0.id == selectedNodeID })
    }

    private var linkDraft: LinkDraft? {
        guard let sourceID = linkingFromNodeID, let pointer = linkingPointer else { return nil }
        return LinkDraft(
            sourceID: sourceID,
            currentPoint: pointer,
            hoveredTargetID: linkHoverTargetNodeID
        )
    }

    private var orchestrationGraph: OrchestrationGraph {
        let graphNodes = nodes.map { node in
            OrchestrationNode(
                id: node.id,
                name: node.name,
                title: node.title,
                type: node.type == .agent ? .agent : .human,
                provider: node.provider.rawValue,
                roleDescription: node.roleDescription,
                securityAccess: Set(node.securityAccess.map(\.rawValue))
            )
        }
        let graphEdges = links.map { link in
            OrchestrationEdge(parentID: link.fromID, childID: link.toID)
        }
        return OrchestrationGraph(nodes: graphNodes, edges: graphEdges)
    }

    private func runCoordinatorPipeline() {
        guard !nodes.isEmpty else { return }
        let normalizedGoal = orchestrationGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        let planner = CoordinatorOrchestrator()
        let plan = planner.plan(
            goal: normalizedGoal.isEmpty
                ? "Execute coordinator objective"
                : normalizedGoal,
            graph: orchestrationGraph
        )
        let mode = coordinatorRunMode
        latestCoordinatorPlan = plan
        latestCoordinatorRun = nil
        coordinatorTrace = plan.packets.map {
            CoordinatorTraceStep(
                packetID: $0.id,
                assignedNodeName: $0.assignedNodeName,
                objective: $0.objective,
                status: .queued,
                summary: nil,
                confidence: nil,
                startedAt: nil,
                finishedAt: nil
            )
        }

        isExecutingCoordinator = true
        Task {
            let run = await executeCoordinatorPlan(plan: plan, mode: mode)
            await MainActor.run {
                latestCoordinatorRun = run
                isExecutingCoordinator = false
            }
        }
    }

    private func executeCoordinatorPlan(
        plan: CoordinatorPlan,
        mode: CoordinatorExecutionMode
    ) async -> CoordinatorRun {
        let startedAt = Date()
        let client = MockMCPClient()
        var results: [CoordinatorTaskResult] = []
        results.reserveCapacity(plan.packets.count)

        for packet in plan.packets {
            let startedAtStep = Date()
            await MainActor.run {
                updateTraceStep(
                    packetID: packet.id,
                    status: .running,
                    startedAt: startedAtStep
                )
            }

            let response: MCPTaskResponse
            switch mode {
            case .simulation:
                response = await simulatePacketExecution(packet)
            case .liveMCP:
                response = await client.execute(
                    MCPTaskRequest(
                        packetID: packet.id,
                        objective: packet.objective,
                        schema: packet.requiredOutputSchema,
                        roleContext: packet.assignedNodeName
                    )
                )
            }

            let finishedAtStep = Date()
            let completed = response.completed
            let result = CoordinatorTaskResult(
                id: UUID().uuidString,
                packetID: packet.id,
                assignedNodeName: packet.assignedNodeName,
                summary: response.summary,
                confidence: response.confidence,
                completed: completed,
                finishedAt: finishedAtStep
            )
            results.append(result)

            await MainActor.run {
                updateTraceStep(
                    packetID: packet.id,
                    status: completed ? .succeeded : .failed,
                    summary: response.summary,
                    confidence: response.confidence,
                    finishedAt: finishedAtStep
                )
            }
        }

        return CoordinatorRun(
            runID: "RUN-\(UUID().uuidString.prefix(8))",
            planID: plan.planID,
            mode: mode,
            results: results,
            startedAt: startedAt,
            finishedAt: Date()
        )
    }

    private func simulatePacketExecution(_ packet: CoordinatorTaskPacket) async -> MCPTaskResponse {
        let permissionPreview = packet.allowedPermissions.prefix(3).joined(separator: ", ")
        let hasRestrictedAccess = packet.allowedPermissions.contains(SecurityAccess.secretsRead.rawValue)
            || packet.allowedPermissions.contains(SecurityAccess.terminalExec.rawValue)

        let delay: UInt64 = hasRestrictedAccess ? 280_000_000 : 180_000_000
        try? await Task.sleep(nanoseconds: delay)

        let summary = [
            "Simulated output for \(packet.assignedNodeName).",
            "Objective: \(packet.objective)",
            permissionPreview.isEmpty ? "Policy check: no elevated permissions required." : "Policy check: \(permissionPreview).",
            "Output schema: \(packet.requiredOutputSchema)."
        ].joined(separator: " ")

        return MCPTaskResponse(
            summary: summary,
            confidence: hasRestrictedAccess ? 0.79 : 0.86,
            completed: true
        )
    }

    @MainActor
    private func updateTraceStep(
        packetID: String,
        status: CoordinatorTraceStatus,
        summary: String? = nil,
        confidence: Double? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil
    ) {
        guard let index = coordinatorTrace.firstIndex(where: { $0.packetID == packetID }) else { return }
        coordinatorTrace[index].status = status
        if let summary {
            coordinatorTrace[index].summary = summary
        }
        if let confidence {
            coordinatorTrace[index].confidence = confidence
        }
        if let startedAt {
            coordinatorTrace[index].startedAt = startedAt
        }
        if let finishedAt {
            coordinatorTrace[index].finishedAt = finishedAt
        }
    }

    private func handleCanvasTap(at point: CGPoint, visibleNodes: [OrgNode], visibleLinks: [NodeLink]) {
        guard linkingFromNodeID == nil else { return }

        if node(at: point, in: visibleNodes) != nil {
            return
        }

        if let hitLinkID = nearestLinkID(to: point, nodes: visibleNodes, links: visibleLinks) {
            selectedLinkID = (selectedLinkID == hitLinkID) ? nil : hitLinkID
            selectedNodeID = nil
        } else {
            selectedLinkID = nil
        }
    }

    private func updateLinkDrag(sourceID: UUID, pointer: CGPoint, candidateNodes: [OrgNode]) {
        if linkingFromNodeID == nil {
            linkingFromNodeID = sourceID
            selectedNodeID = sourceID
            selectedLinkID = nil
        }

        linkingPointer = pointer
        linkHoverTargetNodeID = node(at: pointer, in: candidateNodes, excluding: sourceID)?.id
    }

    private func completeLinkDrag(candidateNodes: [OrgNode]) {
        defer { clearLinkDragState() }
        guard
            let sourceID = linkingFromNodeID,
            let targetID = linkHoverTargetNodeID,
            candidateNodes.contains(where: { $0.id == targetID }),
            sourceID != targetID
        else { return }

        performSemanticMutation {
            if let existing = links.first(where: { $0.fromID == sourceID && $0.toID == targetID }) {
                selectedLinkID = existing.id
                selectedNodeID = nil
                return
            }

            // Structural constraint: only one parent per child.
            let prunedParents = links.filter { !($0.toID == targetID && $0.fromID != sourceID) }
            guard !wouldCreateCycle(from: sourceID, to: targetID, links: prunedParents) else {
                return
            }

            let inheritedTone =
                links.first(where: { $0.fromID == sourceID })?.tone
                ?? links.first(where: { $0.toID == sourceID })?.tone
                ?? .blue

            let created = NodeLink(fromID: sourceID, toID: targetID, tone: inheritedTone)
            links = prunedParents.filter { !($0.fromID == sourceID && $0.toID == targetID) }
            links.append(created)
            selectedLinkID = created.id
            selectedNodeID = nil
            relayoutHierarchy()
        }
    }

    private func clearLinkDragState() {
        linkingFromNodeID = nil
        linkingPointer = nil
        linkHoverTargetNodeID = nil
    }

    private func node(at point: CGPoint, in list: [OrgNode], excluding excludedID: UUID? = nil) -> OrgNode? {
        for node in list {
            if node.id == excludedID { continue }
            let rect = CGRect(
                x: node.position.x - (cardSize.width / 2),
                y: node.position.y - (cardSize.height / 2),
                width: cardSize.width,
                height: cardSize.height
            )
            if rect.contains(point) {
                return node
            }
        }
        return nil
    }

    private func nearestLinkID(to point: CGPoint, nodes: [OrgNode], links: [NodeLink]) -> UUID? {
        let geometries = buildLinkGeometries(nodes: nodes, links: links, cardSize: cardSize)
        let threshold: CGFloat = 16

        var nearest: (id: UUID, distance: CGFloat)?
        for geometry in geometries {
            let distance = minimumDistance(from: point, toPolyline: geometry.points)
            if distance > threshold { continue }
            if let current = nearest {
                if distance < current.distance {
                    nearest = (geometry.link.id, distance)
                }
            } else {
                nearest = (geometry.link.id, distance)
            }
        }

        return nearest?.id
    }

    private func minimumDistance(from point: CGPoint, toPolyline points: [CGPoint]) -> CGFloat {
        guard points.count > 1 else { return .greatestFiniteMagnitude }
        var minimum = CGFloat.greatestFiniteMagnitude
        for index in 0..<(points.count - 1) {
            let value = distance(from: point, toSegmentStart: points[index], end: points[index + 1])
            minimum = min(minimum, value)
        }
        return minimum
    }

    private func distance(from point: CGPoint, toSegmentStart start: CGPoint, end: CGPoint) -> CGFloat {
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

    private func wouldCreateCycle(from parentID: UUID, to childID: UUID, links: [NodeLink]) -> Bool {
        if parentID == childID { return true }
        let candidate = links + [NodeLink(fromID: parentID, toID: childID, tone: .blue)]
        return pathExists(from: childID, to: parentID, links: candidate)
    }

    private func pathExists(from startID: UUID, to targetID: UUID, links: [NodeLink]) -> Bool {
        if startID == targetID { return true }

        let adjacency = Dictionary(grouping: links, by: \.fromID)
        var visited: Set<UUID> = []
        var queue: [UUID] = [startID]
        var index = 0

        while index < queue.count {
            let current = queue[index]
            index += 1

            if current == targetID { return true }
            if visited.contains(current) { continue }
            visited.insert(current)

            for link in adjacency[current] ?? [] {
                if !visited.contains(link.toID) {
                    queue.append(link.toID)
                }
            }
        }

        return false
    }

    private func normalizeStructuralLinks(nodes: [OrgNode], links: [NodeLink]) -> [NodeLink] {
        let validNodeIDs = Set(nodes.map(\.id))
        var result: [NodeLink] = []
        var parentByChildID: [UUID: UUID] = [:]
        var seenPair: Set<String> = []

        for link in links {
            guard validNodeIDs.contains(link.fromID), validNodeIDs.contains(link.toID), link.fromID != link.toID else {
                continue
            }

            let key = "\(link.fromID.uuidString)->\(link.toID.uuidString)"
            guard !seenPair.contains(key) else { continue }
            seenPair.insert(key)

            if parentByChildID[link.toID] != nil {
                continue
            }

            if wouldCreateCycle(from: link.fromID, to: link.toID, links: result) {
                continue
            }

            parentByChildID[link.toID] = link.fromID
            result.append(link)
        }

        return result
    }

    private var semanticFingerprint: String {
        let nodePart = nodes
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { node in
                let roles = node.selectedRoles.map(\.rawValue).sorted().joined(separator: ",")
                let access = node.securityAccess.map(\.rawValue).sorted().joined(separator: ",")
                return [
                    node.id.uuidString,
                    node.name,
                    node.title,
                    node.department,
                    node.type.rawValue,
                    node.provider.rawValue,
                    node.roleDescription,
                    roles,
                    access
                ].joined(separator: "§")
            }
            .joined(separator: "|")

        let linkPart = links
            .sorted { lhs, rhs in
                if lhs.fromID == rhs.fromID {
                    if lhs.toID == rhs.toID {
                        return lhs.tone.rawValue < rhs.tone.rawValue
                    }
                    return lhs.toID.uuidString < rhs.toID.uuidString
                }
                return lhs.fromID.uuidString < rhs.fromID.uuidString
            }
            .map { "\($0.fromID.uuidString)->\($0.toID.uuidString):\($0.tone.rawValue)" }
            .joined(separator: "|")

        return nodePart + "###" + linkPart
    }

    private func addNode(type: NodeType) {
        let fallbackPosition = CGPoint(
            x: CGFloat(Int.random(in: 400...1700)),
            y: CGFloat(Int.random(in: 120...1080))
        )

        var newPosition = fallbackPosition
        var parentIDForNewNode: UUID?
        var parentLinkToneForNewNode: LinkTone = .blue

        if
            let selectedNodeID,
            let selectedNode = nodes.first(where: { $0.id == selectedNodeID })
        {
            let childIDs = Set(
                links
                    .filter { $0.fromID == selectedNodeID }
                    .map(\.toID)
            )
            let children = nodes.filter { childIDs.contains($0.id) }

            let preferredChildY: CGFloat? = {
                guard let parentParentID = links.first(where: { $0.toID == selectedNodeID })?.fromID else {
                    return nil
                }

                let siblingIDs = Set(
                    links
                        .filter { $0.fromID == parentParentID && $0.toID != selectedNodeID }
                        .map(\.toID)
                )

                let cousinChildYs = links
                    .filter { siblingIDs.contains($0.fromID) }
                    .compactMap { link in
                        nodes.first(where: { $0.id == link.toID })?.position.y
                    }

                return cousinChildYs.sorted().first
            }()

            newPosition = nextChildPosition(
                parent: selectedNode,
                existingChildren: children,
                preferredY: preferredChildY
            )
            parentIDForNewNode = selectedNodeID
            parentLinkToneForNewNode =
                links.first(where: { $0.fromID == selectedNodeID })?.tone
                ?? links.first(where: { $0.toID == selectedNodeID })?.tone
                ?? .blue
        }

        let newNodeID = UUID()
        let newNode = OrgNode(
            id: newNodeID,
            name: type == .agent ? "New Agent" : "New Human",
            title: "Role Title",
            department: type == .agent ? "Automation" : "Operations",
            type: type,
            provider: .chatGPT,
            roleDescription: type == .agent
                ? "Autonomous specialist handling scoped tasks with explicit escalation boundaries."
                : "Human lead responsible for reviewing AI output and making final decisions.",
            selectedRoles: [.planner],
            securityAccess: [.workspaceRead],
            position: newPosition
        )

        performSemanticMutation {
            nodes.append(newNode)

            if let parentIDForNewNode {
                links.append(
                    NodeLink(
                        fromID: parentIDForNewNode,
                        toID: newNodeID,
                        tone: parentLinkToneForNewNode
                    )
                )
            }

            stabilizeLayout(afterAddingAtY: newPosition.y, parentID: parentIDForNewNode)
            selectedLinkID = nil
            selectedNodeID = newNode.id
        }
    }

    private func nextChildPosition(
        parent: OrgNode,
        existingChildren: [OrgNode],
        preferredY: CGFloat?
    ) -> CGPoint {
        let minX = (cardSize.width / 2) + 24
        let maxY = canvasContentSize.height - (cardSize.height / 2) - 24
        let horizontalStep = cardSize.width + 40
        let verticalStep: CGFloat = 200

        let baselineDropY = parent.position.y + verticalStep
        let childY = min(max(preferredY ?? baselineDropY, 80), maxY)

        if existingChildren.isEmpty {
            let alignedX = max(parent.position.x, minX)
            return CGPoint(x: alignedX, y: childY)
        }

        let rightMostX = existingChildren.map(\.position.x).max() ?? parent.position.x
        let proposedX = rightMostX + horizontalStep
        let baselineY = existingChildren.first?.position.y ?? childY

        return CGPoint(x: proposedX, y: baselineY)
    }

    private func adjustZoom(stepDelta: Int) {
        let minScaled = Int((minZoom / zoomStep).rounded())
        let maxScaled = Int((maxZoom / zoomStep).rounded())
        let currentScaled = Int((zoom / zoomStep).rounded())
        let nextScaled = min(maxScaled, max(minScaled, currentScaled + stepDelta))
        zoom = CGFloat(nextScaled) * zoomStep
    }

    private func deleteSelectedNode() {
        guard let selected = selectedNodeID else { return }

        let nodeToDelete = selected
        performSemanticMutation {
            nodes.removeAll { $0.id == nodeToDelete }
            links.removeAll { $0.fromID == nodeToDelete || $0.toID == nodeToDelete }
            selectedNodeID = nil

            withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) {
                relayoutHierarchy()
            }
        }
    }

    private func deleteSelectedLink() {
        guard let selectedLinkID else { return }
        performSemanticMutation {
            links.removeAll { $0.id == selectedLinkID }
            self.selectedLinkID = nil
            relayoutHierarchy()
        }
    }

    private func deleteCurrentSelection() {
        if selectedLinkID != nil {
            deleteSelectedLink()
            return
        }
        deleteSelectedNode()
    }

    private func suggestedSaveName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "Structure \(formatter.string(from: Date()))"
    }

    private func saveCurrentStructure(named name: String) {
        let snapshot = captureStructureSnapshot()

        if let existingIndex = savedStructures.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            savedStructures[existingIndex].snapshot = snapshot
            savedStructures[existingIndex].updatedAt = Date()
        } else {
            savedStructures.append(
                SavedHierarchy(
                    id: UUID(),
                    name: name,
                    createdAt: Date(),
                    updatedAt: Date(),
                    snapshot: snapshot
                )
            )
        }

        savedStructures.sort { $0.updatedAt > $1.updatedAt }
        persistSavedHierarchies()
    }

    private func deleteSavedStructure(id: UUID) {
        savedStructures.removeAll { $0.id == id }
        persistSavedHierarchies()
    }

    private func loadSavedHierarchies() {
        guard let data = UserDefaults.standard.data(forKey: savedStructuresDefaultsKey) else {
            savedStructures = []
            return
        }

        do {
            let decoded = try JSONDecoder().decode([SavedHierarchy].self, from: data)
            savedStructures = decoded.sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            savedStructures = []
        }
    }

    private func persistSavedHierarchies() {
        do {
            let data = try JSONEncoder().encode(savedStructures)
            UserDefaults.standard.set(data, forKey: savedStructuresDefaultsKey)
        } catch {
            return
        }
    }

    private func captureStructureSnapshot() -> HierarchySnapshot {
        makeHierarchySnapshot(nodes: nodes, links: links)
    }

    private func applyStructureSnapshot(_ snapshot: HierarchySnapshot) {
        performSemanticMutation {
            setGraph(from: snapshot, resetViewState: true)
        }
    }

    private func setGraph(from snapshot: HierarchySnapshot, resetViewState: Bool) {
        let restoredNodes = snapshot.nodes.map { entry in
            OrgNode(
                id: entry.id,
                name: entry.name,
                title: entry.title,
                department: entry.department,
                type: entry.type,
                provider: entry.provider,
                roleDescription: entry.roleDescription,
                selectedRoles: Set(entry.selectedRoles),
                securityAccess: Set(entry.securityAccess),
                position: CGPoint(x: entry.positionX, y: entry.positionY)
            )
        }

        let restoredLinks = snapshot.links.map { entry in
            NodeLink(fromID: entry.fromID, toID: entry.toID, tone: entry.tone)
        }

        guard !restoredNodes.isEmpty else { return }
        let normalizedLinks = normalizeStructuralLinks(nodes: restoredNodes, links: restoredLinks)

        let previouslySelected = selectedNodeID
        selectedNodeID = nil
        selectedLinkID = nil
        clearLinkDragState()
        if resetViewState {
            searchText = ""
            zoom = 1.0
        }
        nodes = restoredNodes
        links = normalizedLinks
        relayoutHierarchy()

        if let previouslySelected, nodes.contains(where: { $0.id == previouslySelected }) {
            selectedNodeID = previouslySelected
        }
    }

    private func performSemanticMutation(_ mutation: () -> Void) {
        suppressStoreSync = true
        mutation()
        suppressStoreSync = false
        persistGraphIfNeeded(for: semanticFingerprint)
    }

    private func undo() {
        guard let undoManager else { return }
        undoManager.undo()
        DispatchQueue.main.async {
            syncGraphFromStore()
        }
    }

    private func redo() {
        guard let undoManager else { return }
        undoManager.redo()
        DispatchQueue.main.async {
            syncGraphFromStore()
        }
    }

    private var activeGraphDocument: GraphDocument? {
        if let exact = graphDocuments.first(where: { $0.key == activeGraphKey }) {
            return exact
        }
        return graphDocuments.first
    }

    private func ensureActiveGraphDocument() {
        if activeGraphDocument != nil { return }
        guard let data = try? JSONEncoder().encode(makeHierarchySnapshot(nodes: OrgNode.sample, links: NodeLink.sample)) else {
            return
        }

        let document = GraphDocument(
            key: activeGraphKey,
            snapshotData: data,
            updatedAt: Date()
        )
        modelContext.insert(document)
        try? modelContext.save()
    }

    private func syncGraphFromStore() {
        guard
            let document = activeGraphDocument,
            let snapshot = try? JSONDecoder().decode(HierarchySnapshot.self, from: document.snapshotData)
        else {
            relayoutHierarchy()
            lastPersistedFingerprint = semanticFingerprint
            return
        }

        suppressStoreSync = true
        setGraph(from: snapshot, resetViewState: false)
        suppressStoreSync = false
        lastPersistedFingerprint = semanticFingerprint
    }

    private func persistGraphIfNeeded(for newFingerprint: String) {
        guard !suppressStoreSync else { return }
        guard newFingerprint != lastPersistedFingerprint else { return }
        ensureActiveGraphDocument()
        guard
            let document = activeGraphDocument,
            let data = try? JSONEncoder().encode(captureStructureSnapshot())
        else { return }

        document.snapshotData = data
        document.updatedAt = Date()
        try? modelContext.save()
        lastPersistedFingerprint = newFingerprint
    }

    private func stabilizeLayout(afterAddingAtY rowY: CGFloat, parentID: UUID?) {
        _ = rowY
        _ = parentID
        withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
            relayoutHierarchy()
        }
    }

    private func relayoutHierarchy() {
        guard !nodes.isEmpty else { return }

        let minX = (cardSize.width / 2) + 16
        let topY: CGFloat = 132
        let rowSpacing: CGFloat = 208
        let siblingGap: CGFloat = 24
        let rootGap: CGFloat = 40

        let allNodeIDs = Set(nodes.map(\.id))
        let nodeByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let currentXByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.position.x) })
        let primaryParentByChildID = computePrimaryParentByChild(
            nodeIDs: allNodeIDs,
            links: links,
            currentXByID: currentXByID
        )

        var treeChildrenByParentID: [UUID: [UUID]] = [:]
        for link in links where primaryParentByChildID[link.toID] == link.fromID {
            treeChildrenByParentID[link.fromID, default: []].append(link.toID)
        }
        for (parentID, children) in treeChildrenByParentID {
            treeChildrenByParentID[parentID] = children.sorted { lhs, rhs in
                let lx = currentXByID[lhs] ?? 0
                let rx = currentXByID[rhs] ?? 0
                if lx == rx {
                    return lhs.uuidString < rhs.uuidString
                }
                return lx < rx
            }
        }

        let rootIDs = allNodeIDs.filter { primaryParentByChildID[$0] == nil }.sorted { lhs, rhs in
            let lx = currentXByID[lhs] ?? 0
            let rx = currentXByID[rhs] ?? 0
            if lx == rx {
                return lhs.uuidString < rhs.uuidString
            }
            return lx < rx
        }

        var depthByID: [UUID: Int] = [:]
        var queue = rootIDs
        var head = 0

        for rootID in rootIDs {
            depthByID[rootID] = 0
        }

        while head < queue.count {
            let nodeID = queue[head]
            head += 1
            let depth = depthByID[nodeID] ?? 0

            for childID in treeChildrenByParentID[nodeID] ?? [] {
                let childDepth = depth + 1
                if depthByID[childID] == nil || childDepth < (depthByID[childID] ?? childDepth) {
                    depthByID[childID] = childDepth
                    queue.append(childID)
                }
            }
        }

        for nodeID in allNodeIDs where depthByID[nodeID] == nil {
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
            if let cached = subtreeWidthByID[nodeID] {
                return cached
            }
            if visiting.contains(nodeID) {
                return cardSize.width
            }

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

        let missingIDs = allNodeIDs.subtracting(Set(xByID.keys)).sorted { lhs, rhs in
            let lx = currentXByID[lhs] ?? 0
            let rx = currentXByID[rhs] ?? 0
            if lx == rx {
                return lhs.uuidString < rhs.uuidString
            }
            return lx < rx
        }
        for nodeID in missingIDs {
            xByID[nodeID] = rootCursor + (cardSize.width / 2)
            rootCursor += cardSize.width + rootGap
        }

        withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
            for index in nodes.indices {
                let nodeID = nodes[index].id
                let depth = depthByID[nodeID] ?? 0
                nodes[index].position = CGPoint(
                    x: xByID[nodeID] ?? minX,
                    y: topY + CGFloat(depth) * rowSpacing
                )
            }
        }
    }
}

private struct NodeInspector: View {
    @Binding var node: OrgNode

    private let allRoles = PresetRole.allCases
    private let allAccess = SecurityAccess.allCases

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Node Details")
                .font(.title2.bold())

            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    TextField("Display Name", text: $node.name)
                        .textFieldStyle(.roundedBorder)

                    TextField("Role Title", text: $node.title)
                        .textFieldStyle(.roundedBorder)

                    TextField("Department", text: $node.department)
                        .textFieldStyle(.roundedBorder)
                }
            } label: {
                Text("Identity")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Node Type", selection: $node.type) {
                        ForEach(NodeType.allCases) { type in
                            Text(type.label).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)

                    if node.type == .agent {
                        Picker("Model", selection: $node.provider) {
                            ForEach(LLMProvider.allCases) { provider in
                                Text(provider.label).tag(provider)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
            } label: {
                Text("Type")
            }

            GroupBox {
                TextEditor(text: $node.roleDescription)
                    .frame(minHeight: 110)
                    .padding(6)
                    .background(Color(uiColor: .systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } label: {
                Text("Role Description")
            }

            GroupBox {
                FlowLayout(items: allRoles, spacing: 8) { role in
                    let selected = node.selectedRoles.contains(role)
                    Button {
                        if selected {
                            node.selectedRoles.remove(role)
                        } else {
                            node.selectedRoles.insert(role)
                        }
                    } label: {
                        Text(role.label)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                Capsule()
                                    .fill(selected ? Color.blue.opacity(0.18) : Color.gray.opacity(0.14))
                            )
                            .overlay(
                                Capsule()
                                    .stroke(selected ? Color.blue : Color.gray.opacity(0.35), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            } label: {
                Text("Preset Roles")
            }

            GroupBox {
                VStack(spacing: 10) {
                    ForEach(allAccess) { access in
                        Toggle(
                            access.label,
                            isOn: Binding(
                                get: { node.securityAccess.contains(access) },
                                set: { isEnabled in
                                    if isEnabled {
                                        node.securityAccess.insert(access)
                                    } else {
                                        node.securityAccess.remove(access)
                                    }
                                }
                            )
                        )
                    }
                }
            } label: {
                Text("Security Access")
            }
        }
    }
}

private struct CoordinatorTraceRow: View {
    let stepNumber: Int
    let step: CoordinatorTraceStep

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(stepNumber). \(step.assignedNodeName)")
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(step.status.label)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(step.status.color.opacity(0.16))
                    )
                    .foregroundStyle(step.status.color)

                if let durationText = step.durationText {
                    Text(durationText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Text(step.objective)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if let summary = step.summary {
                Text(summary)
                    .font(.caption)
                    .lineLimit(3)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(uiColor: .systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct ConnectionLayer: View {
    let nodes: [OrgNode]
    let links: [NodeLink]
    let cardSize: CGSize
    let selectedLinkID: UUID?
    let draft: LinkDraft?

    var body: some View {
        Canvas { context, _ in
            let geometries = buildLinkGeometries(nodes: nodes, links: links, cardSize: cardSize)

            for geometry in geometries {
                var path = Path()
                guard let first = geometry.points.first else { continue }
                path.move(to: first)
                for point in geometry.points.dropFirst() {
                    path.addLine(to: point)
                }

                let isSelected = geometry.link.id == selectedLinkID
                let strokeStyle = StrokeStyle(
                    lineWidth: isSelected ? 3.8 : (geometry.isSecondary ? 1.8 : 2.2),
                    lineCap: .round,
                    lineJoin: .round,
                    dash: geometry.isSecondary ? [6, 4] : []
                )
                let strokeColor = isSelected ? Color.red : geometry.link.color.opacity(geometry.isSecondary ? 0.9 : 1)
                context.stroke(path, with: .color(strokeColor), style: strokeStyle)
            }

            if
                let draft,
                let source = nodes.first(where: { $0.id == draft.sourceID })
            {
                let start = CGPoint(
                    x: source.position.x,
                    y: source.position.y + (cardSize.height / 2) - 4
                )

                var previewPath = Path()
                previewPath.move(to: start)
                previewPath.addLine(to: draft.currentPoint)

                context.stroke(
                    previewPath,
                    with: .color(draft.hoveredTargetID == nil ? Color.blue : Color.green),
                    style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round, dash: [5, 4])
                )
            }
        }
    }
}

private struct LinkHandle: View {
    let isActive: Bool

    var body: some View {
        Circle()
            .fill(isActive ? Color.green : Color.blue)
            .overlay(
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            )
            .frame(width: 24, height: 24)
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }
}

private struct LinkDraft {
    let sourceID: UUID
    let currentPoint: CGPoint
    let hoveredTargetID: UUID?
}

private struct LinkGeometry {
    let link: NodeLink
    let points: [CGPoint]
    let isSecondary: Bool
}

private func buildLinkGeometries(
    nodes: [OrgNode],
    links: [NodeLink],
    cardSize: CGSize
) -> [LinkGeometry] {
    let nodeMap = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
    let currentXByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.position.x) })
    let primaryParentByChildID = computePrimaryParentByChild(
        nodeIDs: Set(nodes.map(\.id)),
        links: links,
        currentXByID: currentXByID
    )

    let primaryLinks = links.filter { primaryParentByChildID[$0.toID] == $0.fromID }
    let secondaryLinks = links.filter { primaryParentByChildID[$0.toID] != $0.fromID }

    let parentIDs = Set(primaryLinks.map(\.fromID))
    let parentNodes = nodes.filter { parentIDs.contains($0.id) }
    var groupedParents: [Int: [OrgNode]] = [:]
    for parent in parentNodes {
        let levelKey = Int((parent.position.y / 10).rounded())
        groupedParents[levelKey, default: []].append(parent)
    }

    var laneOffsetByParentID: [UUID: CGFloat] = [:]
    let levelStep: CGFloat = 14
    for (_, parentsAtLevel) in groupedParents {
        let sorted = parentsAtLevel.sorted { $0.position.x < $1.position.x }
        let midpoint = CGFloat(sorted.count - 1) / 2
        for (index, parent) in sorted.enumerated() {
            laneOffsetByParentID[parent.id] = (CGFloat(index) - midpoint) * levelStep
        }
    }

    let groupedPrimary = Dictionary(grouping: primaryLinks, by: \.fromID)
    var laneYByParentID: [UUID: CGFloat] = [:]
    for (parentID, parentLinks) in groupedPrimary {
        guard let parent = nodeMap[parentID] else { continue }
        let children = parentLinks.compactMap { link in nodeMap[link.toID] }
        guard !children.isEmpty else { continue }

        let parentBottomY = parent.position.y + (cardSize.height / 2) - 4
        let childTopYs = children.map { $0.position.y - (cardSize.height / 2) + 4 }
        let childTopMinY = childTopYs.min() ?? parentBottomY + 40
        let baseLaneY = parentBottomY + 52 + (laneOffsetByParentID[parentID] ?? 0)
        laneYByParentID[parentID] = min(max(parentBottomY + 14, baseLaneY), childTopMinY - 16)
    }

    var result: [LinkGeometry] = []

    for link in primaryLinks {
        guard
            let parent = nodeMap[link.fromID],
            let child = nodeMap[link.toID]
        else { continue }

        let start = CGPoint(
            x: parent.position.x,
            y: parent.position.y + (cardSize.height / 2) - 4
        )
        let end = CGPoint(
            x: child.position.x,
            y: child.position.y - (cardSize.height / 2) + 4
        )
        let laneY = laneYByParentID[link.fromID] ?? ((start.y + end.y) / 2)
        result.append(
            LinkGeometry(
                link: link,
                points: [start, CGPoint(x: start.x, y: laneY), CGPoint(x: end.x, y: laneY), end],
                isSecondary: false
            )
        )
    }

    let sortedSecondary = secondaryLinks.sorted { lhs, rhs in
        if lhs.fromID == rhs.fromID {
            return lhs.toID.uuidString < rhs.toID.uuidString
        }
        return lhs.fromID.uuidString < rhs.fromID.uuidString
    }
    for (index, link) in sortedSecondary.enumerated() {
        guard
            let from = nodeMap[link.fromID],
            let to = nodeMap[link.toID]
        else { continue }

        let start = CGPoint(
            x: from.position.x,
            y: from.position.y + (cardSize.height / 2) - 4
        )
        let end = CGPoint(
            x: to.position.x,
            y: to.position.y - (cardSize.height / 2) + 4
        )
        let detourY = max(start.y, end.y) + 70 + CGFloat(index % 4) * 14
        result.append(
            LinkGeometry(
                link: link,
                points: [start, CGPoint(x: start.x, y: detourY), CGPoint(x: end.x, y: detourY), end],
                isSecondary: true
            )
        )
    }

    return result
}

private struct DotGridBackground: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 28
            let dotSize: CGFloat = 1.6
            let dotColor = Color.gray.opacity(0.28)

            for x in stride(from: CGFloat(0), through: size.width, by: spacing) {
                for y in stride(from: CGFloat(0), through: size.height, by: spacing) {
                    let dot = Path(
                        ellipseIn: CGRect(
                            x: x - dotSize / 2,
                            y: y - dotSize / 2,
                            width: dotSize,
                            height: dotSize
                        )
                    )
                    context.fill(dot, with: .color(dotColor))
                }
            }
        }
    }
}

private struct NodeCard: View {
    let node: OrgNode
    let isSelected: Bool
    let isLinkTargeted: Bool

    var body: some View {
        HStack(spacing: 12) {
            avatar

            VStack(alignment: .leading, spacing: 4) {
                Text(node.name)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(node.title)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                    Text(node.department)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                .font(.subheadline)
                HStack(spacing: 8) {
                    typeBadge
                    if node.type == .agent {
                        modelBadge
                    }
                }
            }
            Spacer(minLength: 4)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    isSelected ? Color.orange : (isLinkTargeted ? Color.green : Color.black.opacity(0.08)),
                    lineWidth: isSelected || isLinkTargeted ? 2 : 1
                )
        )
        .shadow(color: .black.opacity(0.08), radius: 10, y: 2)
    }

    private var avatar: some View {
        Circle()
            .fill(LinearGradient(
                colors: [Color.orange.opacity(0.5), Color.blue.opacity(0.5)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            .overlay(
                Text(node.initials)
                    .font(.subheadline.bold())
            )
            .frame(width: 42, height: 42)
    }

    private var typeBadge: some View {
        Text(node.type.label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(node.type == .agent ? Color.blue.opacity(0.16) : Color.green.opacity(0.18))
            )
    }

    private var modelBadge: some View {
        Text(node.provider.label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color.gray.opacity(0.15))
            )
    }
}

private struct FlowLayout<Item: Hashable, Content: View>: View {
    let items: [Item]
    let spacing: CGFloat
    let content: (Item) -> Content

    init(
        items: [Item],
        spacing: CGFloat,
        @ViewBuilder content: @escaping (Item) -> Content
    ) {
        self.items = items
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        GeometryReader { proxy in
            generateContent(in: proxy)
        }
        .frame(minHeight: 96)
    }

    private func generateContent(in geo: GeometryProxy) -> some View {
        var width = CGFloat.zero
        var height = CGFloat.zero

        return ZStack(alignment: .topLeading) {
            ForEach(items, id: \.self) { item in
                content(item)
                    .padding(.all, spacing / 2)
                    .alignmentGuide(.leading) { dimensions in
                        if abs(width - dimensions.width) > geo.size.width {
                            width = 0
                            height -= dimensions.height + spacing
                        }
                        let result = width
                        if item == items.last {
                            width = 0
                        } else {
                            width -= dimensions.width + spacing
                        }
                        return result
                    }
                    .alignmentGuide(.top) { _ in
                        let result = height
                        if item == items.last {
                            height = 0
                        }
                        return result
                    }
            }
        }
    }
}

private struct OrgNode: Identifiable {
    let id: UUID
    var name: String
    var title: String
    var department: String
    var type: NodeType
    var provider: LLMProvider
    var roleDescription: String
    var selectedRoles: Set<PresetRole>
    var securityAccess: Set<SecurityAccess>
    var position: CGPoint

    var initials: String {
        let words = name.split(separator: " ")
        let first = words.first?.first.map(String.init) ?? ""
        let second = words.dropFirst().first?.first.map(String.init) ?? ""
        return (first + second).uppercased()
    }

    static let sample: [OrgNode] = [
        OrgNode(
            id: UUID(uuidString: "A5E8B12B-2207-43B4-B363-C6D0E0F55541")!,
            name: "Coordinator",
            title: "Root Supervisor",
            department: "Control Plane",
            type: .agent,
            provider: .chatGPT,
            roleDescription: "Routes goals into sub-workflows, enforces policy checks, and merges outputs.",
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
            selectedRoles: [.researcher],
            securityAccess: [.workspaceRead, .webAccess],
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
            selectedRoles: [.executor],
            securityAccess: [.workspaceRead],
            position: CGPoint(x: 940, y: 680)
        )
    ]
}

private struct NodeLink: Identifiable {
    let id = UUID()
    let fromID: UUID
    let toID: UUID
    let tone: LinkTone

    var color: Color { tone.color }

    static let sample: [NodeLink] = [
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
        )
    ]
}

private enum LinkTone: String, CaseIterable, Codable {
    case blue
    case orange
    case teal
    case green
    case indigo

    var color: Color {
        switch self {
        case .blue:
            return .blue
        case .orange:
            return .orange
        case .teal:
            return .teal
        case .green:
            return .green
        case .indigo:
            return .indigo
        }
    }
}

private struct HierarchySnapshot: Codable {
    var nodes: [HierarchySnapshotNode]
    var links: [HierarchySnapshotLink]
}

private struct HierarchySnapshotNode: Codable {
    var id: UUID
    var name: String
    var title: String
    var department: String
    var type: NodeType
    var provider: LLMProvider
    var roleDescription: String
    var selectedRoles: [PresetRole]
    var securityAccess: [SecurityAccess]
    var positionX: CGFloat
    var positionY: CGFloat
}

private struct HierarchySnapshotLink: Codable {
    var fromID: UUID
    var toID: UUID
    var tone: LinkTone
}

private struct SavedHierarchy: Identifiable, Codable {
    var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var snapshot: HierarchySnapshot
}

private func makeHierarchySnapshot(nodes: [OrgNode], links: [NodeLink]) -> HierarchySnapshot {
    let snapshotNodes = nodes.map { node in
        HierarchySnapshotNode(
            id: node.id,
            name: node.name,
            title: node.title,
            department: node.department,
            type: node.type,
            provider: node.provider,
            roleDescription: node.roleDescription,
            selectedRoles: node.selectedRoles.sorted { $0.rawValue < $1.rawValue },
            securityAccess: node.securityAccess.sorted { $0.rawValue < $1.rawValue },
            positionX: node.position.x,
            positionY: node.position.y
        )
    }

    let snapshotLinks = links.map { link in
        HierarchySnapshotLink(fromID: link.fromID, toID: link.toID, tone: link.tone)
    }

    return HierarchySnapshot(nodes: snapshotNodes, links: snapshotLinks)
}

private enum PresetHierarchyTemplate: String, CaseIterable, Identifiable {
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
            OrgNode(id: coordinatorID, name: "Program Lead", title: "Coordinator", department: "Planning", type: .human, provider: .chatGPT, roleDescription: "Sets direction and approves release scope.", selectedRoles: [.decisionMaker], securityAccess: [.workspaceRead, .auditLogs], position: .zero),
            OrgNode(id: plannerID, name: "Strategy Agent", title: "Planner", department: "Planning", type: .agent, provider: .chatGPT, roleDescription: "Breaks goals into implementation tracks.", selectedRoles: [.planner], securityAccess: [.workspaceRead, .workspaceWrite], position: .zero),
            OrgNode(id: researchID, name: "Research Agent", title: "Research", department: "Discovery", type: .agent, provider: .gemini, roleDescription: "Collects context and references for execution.", selectedRoles: [.researcher], securityAccess: [.workspaceRead, .webAccess], position: .zero),
            OrgNode(id: buildID, name: "Builder Agent", title: "Executor", department: "Delivery", type: .agent, provider: .claude, roleDescription: "Implements requested changes.", selectedRoles: [.executor], securityAccess: [.workspaceRead, .workspaceWrite, .terminalExec], position: .zero),
            OrgNode(id: qualityID, name: "QA Agent", title: "Reviewer", department: "Quality", type: .agent, provider: .grok, roleDescription: "Runs tests and validates behavior.", selectedRoles: [.reviewer], securityAccess: [.workspaceRead, .terminalExec], position: .zero),
            OrgNode(id: releaseID, name: "Release Manager", title: "Human Signoff", department: "Operations", type: .human, provider: .chatGPT, roleDescription: "Approves deployment and communications.", selectedRoles: [.decisionMaker, .reviewer], securityAccess: [.workspaceRead, .auditLogs], position: .zero)
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
            OrgNode(id: commanderID, name: "Incident Commander", title: "Coordinator", department: "Security", type: .human, provider: .chatGPT, roleDescription: "Owns response decisions and escalation.", selectedRoles: [.coordinator, .decisionMaker], securityAccess: [.workspaceRead, .auditLogs], position: .zero),
            OrgNode(id: triageID, name: "Triage Agent", title: "Classifier", department: "Security", type: .agent, provider: .chatGPT, roleDescription: "Classifies impact and routes tasks.", selectedRoles: [.planner, .summarizer], securityAccess: [.workspaceRead, .webAccess], position: .zero),
            OrgNode(id: remediationID, name: "Remediation Agent", title: "Executor", department: "Engineering", type: .agent, provider: .claude, roleDescription: "Applies fixes and executes rollback plans.", selectedRoles: [.executor], securityAccess: [.workspaceRead, .workspaceWrite, .terminalExec], position: .zero),
            OrgNode(id: commsID, name: "Comms Agent", title: "Status Reporter", department: "Comms", type: .agent, provider: .gemini, roleDescription: "Produces executive and customer updates.", selectedRoles: [.summarizer], securityAccess: [.workspaceRead], position: .zero),
            OrgNode(id: forensicsID, name: "Forensics Agent", title: "Investigator", department: "Security", type: .agent, provider: .grok, roleDescription: "Collects traces and root-cause timeline.", selectedRoles: [.researcher, .reviewer], securityAccess: [.workspaceRead, .terminalExec], position: .zero),
            OrgNode(id: approverID, name: "Approver", title: "Human Gate", department: "Leadership", type: .human, provider: .chatGPT, roleDescription: "Approves high-impact remediations.", selectedRoles: [.decisionMaker], securityAccess: [.auditLogs], position: .zero)
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

private enum OrchestrationNodeKind: String, Codable {
    case human
    case agent
}

private enum CoordinatorExecutionMode: String, CaseIterable, Identifiable, Codable {
    case simulation
    case liveMCP

    var id: String { rawValue }

    var label: String {
        switch self {
        case .simulation:
            return "Simulation"
        case .liveMCP:
            return "Live MCP"
        }
    }
}

private enum CoordinatorTraceStatus: String, Codable {
    case queued
    case running
    case succeeded
    case failed

    var label: String {
        switch self {
        case .queued:
            return "Queued"
        case .running:
            return "Running"
        case .succeeded:
            return "Succeeded"
        case .failed:
            return "Failed"
        }
    }

    var color: Color {
        switch self {
        case .queued:
            return .gray
        case .running:
            return .blue
        case .succeeded:
            return .green
        case .failed:
            return .red
        }
    }
}

private struct CoordinatorTraceStep: Identifiable {
    var id: String { packetID }
    let packetID: String
    let assignedNodeName: String
    let objective: String
    var status: CoordinatorTraceStatus
    var summary: String?
    var confidence: Double?
    var startedAt: Date?
    var finishedAt: Date?

    var durationText: String? {
        guard let startedAt else { return nil }
        let endTime = finishedAt ?? Date()
        let duration = endTime.timeIntervalSince(startedAt)
        if duration < 1 {
            return String(format: "%.0fms", duration * 1000)
        }
        return String(format: "%.2fs", duration)
    }
}

private struct OrchestrationNode: Identifiable, Codable {
    let id: UUID
    let name: String
    let title: String
    let type: OrchestrationNodeKind
    let provider: String
    let roleDescription: String
    let securityAccess: Set<String>
}

private struct OrchestrationEdge: Codable {
    let parentID: UUID
    let childID: UUID
}

private struct OrchestrationGraph: Codable {
    let nodes: [OrchestrationNode]
    let edges: [OrchestrationEdge]
}

private struct CoordinatorTaskPacket: Identifiable, Codable {
    let id: String
    let parentTaskID: String
    let assignedNodeID: UUID
    let assignedNodeName: String
    let objective: String
    let requiredOutputSchema: String
    let allowedPermissions: [String]
}

private struct CoordinatorPlan: Codable {
    let planID: String
    let coordinatorID: UUID
    let coordinatorName: String
    let goal: String
    let packets: [CoordinatorTaskPacket]
    let createdAt: Date
}

private struct MCPTaskRequest: Codable {
    let packetID: String
    let objective: String
    let schema: String
    let roleContext: String
}

private struct MCPTaskResponse: Codable {
    let summary: String
    let confidence: Double
    let completed: Bool
}

private struct CoordinatorTaskResult: Identifiable, Codable {
    let id: String
    let packetID: String
    let assignedNodeName: String
    let summary: String
    let confidence: Double
    let completed: Bool
    let finishedAt: Date
}

private struct CoordinatorRun: Codable {
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

private protocol MCPClient {
    func execute(_ request: MCPTaskRequest) async -> MCPTaskResponse
}

private struct MockMCPClient: MCPClient {
    func execute(_ request: MCPTaskRequest) async -> MCPTaskResponse {
        try? await Task.sleep(nanoseconds: 120_000_000)
        let normalizedObjective = request.objective.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = "Completed: \(normalizedObjective). Output conforms to \(request.schema)."
        return MCPTaskResponse(summary: summary, confidence: 0.82, completed: true)
    }
}

private struct CoordinatorOrchestrator {
    func plan(goal: String, graph: OrchestrationGraph) -> CoordinatorPlan {
        precondition(!graph.nodes.isEmpty, "Graph must contain at least one node")
        let nodeByID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        let outgoingByParentID = Dictionary(grouping: graph.edges, by: \.parentID)
        let childIDs = Set(graph.edges.map(\.childID))
        let rootCandidates = graph.nodes.filter { !childIDs.contains($0.id) }

        let coordinator = preferredCoordinator(from: rootCandidates, fallback: graph.nodes)
        let delegateNodes = collectDescendantNodes(
            under: coordinator.id,
            nodeByID: nodeByID,
            outgoingByParentID: outgoingByParentID
        )

        let parentTaskID = "TASK-\(UUID().uuidString.prefix(8))"
        let packets = delegateNodes.enumerated().map { index, node in
            CoordinatorTaskPacket(
                id: "\(parentTaskID)-\(index + 1)",
                parentTaskID: parentTaskID,
                assignedNodeID: node.id,
                assignedNodeName: node.name,
                objective: objectiveForNode(node, globalGoal: goal),
                requiredOutputSchema: schemaForNode(node),
                allowedPermissions: node.securityAccess.sorted()
            )
        }

        return CoordinatorPlan(
            planID: "PLAN-\(UUID().uuidString.prefix(8))",
            coordinatorID: coordinator.id,
            coordinatorName: coordinator.name,
            goal: goal,
            packets: packets,
            createdAt: Date()
        )
    }

    private func collectDescendantNodes(
        under coordinatorID: UUID,
        nodeByID: [UUID: OrchestrationNode],
        outgoingByParentID: [UUID: [OrchestrationEdge]]
    ) -> [OrchestrationNode] {
        var ordered: [OrchestrationNode] = []
        var visited: Set<UUID> = [coordinatorID]
        var queue: [UUID] = [coordinatorID]
        var head = 0

        while head < queue.count {
            let currentID = queue[head]
            head += 1

            let children = (outgoingByParentID[currentID] ?? [])
                .map(\.childID)
                .sorted { lhs, rhs in
                    let left = nodeByID[lhs]?.name ?? lhs.uuidString
                    let right = nodeByID[rhs]?.name ?? rhs.uuidString
                    if left == right { return lhs.uuidString < rhs.uuidString }
                    return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
                }

            for childID in children {
                guard !visited.contains(childID) else { continue }
                visited.insert(childID)
                queue.append(childID)
                if let child = nodeByID[childID] {
                    ordered.append(child)
                }
            }
        }

        // Safety fallback for malformed/disconnected structures.
        if ordered.isEmpty {
            return nodeByID.values
                .filter { $0.id != coordinatorID }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        return ordered
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
                    schema: packet.requiredOutputSchema,
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

    private func schemaForNode(_ node: OrchestrationNode) -> String {
        switch node.type {
        case .human:
            return "human_approval_v1"
        case .agent:
            if node.roleDescription.localizedCaseInsensitiveContains("research") {
                return "research_brief_v1"
            }
            if node.roleDescription.localizedCaseInsensitiveContains("test")
                || node.roleDescription.localizedCaseInsensitiveContains("review")
            {
                return "validation_report_v1"
            }
            return "task_result_v1"
        }
    }
}

private func computePrimaryParentByChild(
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

private enum NodeType: String, CaseIterable, Identifiable, Codable {
    case human
    case agent

    var id: String { rawValue }

    var label: String {
        switch self {
        case .human:
            return "Human"
        case .agent:
            return "Agent"
        }
    }
}

private enum LLMProvider: String, CaseIterable, Identifiable, Codable {
    case grok
    case chatGPT
    case gemini
    case claude

    var id: String { rawValue }

    var label: String {
        switch self {
        case .grok:
            return "Grok"
        case .chatGPT:
            return "ChatGPT"
        case .gemini:
            return "Gemini"
        case .claude:
            return "Claude"
        }
    }
}

private enum PresetRole: String, CaseIterable, Identifiable, Hashable, Codable {
    case coordinator
    case planner
    case executor
    case reviewer
    case researcher
    case summarizer
    case decisionMaker

    var id: String { rawValue }

    var label: String {
        switch self {
        case .coordinator:
            return "Coordinator"
        case .planner:
            return "Planner"
        case .executor:
            return "Operator"
        case .reviewer:
            return "Reviewer"
        case .researcher:
            return "Researcher"
        case .summarizer:
            return "Summarizer"
        case .decisionMaker:
            return "Decision Maker"
        }
    }
}

private enum SecurityAccess: String, CaseIterable, Identifiable, Hashable, Codable {
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
            return "Workspace Read"
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

#Preview {
    ContentView()
}
