import SwiftUI

struct ContentView: View {
    private let cardSize = CGSize(width: 264, height: 88)
    private let minimumCanvasSize = CGSize(width: 1900, height: 1200)
    private let minZoom: CGFloat = 0.6
    private let maxZoom: CGFloat = 1.5
    private let zoomStep: CGFloat = 0.1
    private let savedStructuresDefaultsKey = "agentic.savedStructures.v1"

    @State private var nodes = OrgNode.sample
    @State private var links = NodeLink.sample
    @State private var selectedNodeID: OrgNode.ID?
    @State private var searchText = ""
    @State private var zoom: CGFloat = 1.0
    @State private var savedStructures: [SavedHierarchy] = []
    @State private var isShowingSaveStructurePrompt = false
    @State private var saveStructureName = ""

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
            relayoutHierarchy()
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

                Button(role: .destructive) {
                    deleteSelectedNode()
                } label: {
                    Label("Delete Node", systemImage: "trash")
                        .font(.headline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .disabled(selectedNodeID == nil)
                .keyboardShortcut(.delete, modifiers: [])
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(Color(uiColor: .systemBackground))
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
                        cardSize: cardSize
                    )
                    .frame(width: canvasSize.width, height: canvasSize.height)

                    ForEach(visibleNodes) { node in
                        NodeCard(node: node, isSelected: node.id == selectedNodeID)
                            .frame(width: cardSize.width, height: cardSize.height)
                            .position(node.position)
                            .animation(.spring(response: 0.5, dampingFraction: 0.82), value: node.position.x)
                            .animation(.spring(response: 0.5, dampingFraction: 0.82), value: node.position.y)
                            .onTapGesture {
                                selectedNodeID = (selectedNodeID == node.id) ? nil : node.id
                            }
                    }
                }
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
        selectedNodeID = newNode.id
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
        nodes.removeAll { $0.id == nodeToDelete }
        links.removeAll { $0.fromID == nodeToDelete || $0.toID == nodeToDelete }
        selectedNodeID = nil

        withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) {
            relayoutHierarchy()
        }
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

        selectedNodeID = nil
        searchText = ""
        zoom = 1.0
        nodes = restoredNodes
        links = restoredLinks
        relayoutHierarchy()
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

private struct ConnectionLayer: View {
    let nodes: [OrgNode]
    let links: [NodeLink]
    let cardSize: CGSize

    private var nodeMap: [UUID: OrgNode] {
        Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
    }

    private var primaryParentByChildID: [UUID: UUID] {
        let currentXByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.position.x) })
        return computePrimaryParentByChild(
            nodeIDs: Set(nodes.map(\.id)),
            links: links,
            currentXByID: currentXByID
        )
    }

    private var primaryLinks: [NodeLink] {
        let primary = primaryParentByChildID
        return links.filter { primary[$0.toID] == $0.fromID }
    }

    private var secondaryLinks: [NodeLink] {
        let primary = primaryParentByChildID
        return links.filter { primary[$0.toID] != $0.fromID }
    }

    private var laneOffsetByParentID: [UUID: CGFloat] {
        let parentIDs = Set(primaryLinks.map(\.fromID))
        let parentNodes = nodes.filter { parentIDs.contains($0.id) }
        var grouped: [Int: [OrgNode]] = [:]
        let levelStep: CGFloat = 14

        for parent in parentNodes {
            let levelKey = Int((parent.position.y / 10).rounded())
            grouped[levelKey, default: []].append(parent)
        }

        var offsets: [UUID: CGFloat] = [:]
        for (_, parentsAtLevel) in grouped {
            let sorted = parentsAtLevel.sorted { $0.position.x < $1.position.x }
            let midpoint = CGFloat(sorted.count - 1) / 2

            for (index, parent) in sorted.enumerated() {
                let laneIndex = CGFloat(index) - midpoint
                offsets[parent.id] = laneIndex * levelStep
            }
        }

        return offsets
    }

    var body: some View {
        Canvas { context, _ in
            let linksByParentID = Dictionary(grouping: primaryLinks, by: \.fromID)

            for (parentID, parentLinks) in linksByParentID {
                guard
                    let parent = nodeMap[parentID]
                else { continue }

                let children = parentLinks
                    .compactMap { link -> (node: OrgNode, color: Color)? in
                        guard let child = nodeMap[link.toID] else { return nil }
                        return (child, link.color)
                    }
                    .sorted { $0.node.position.x < $1.node.position.x }

                guard !children.isEmpty else { continue }

                let parentBottomY = parent.position.y + (cardSize.height / 2) - 4
                let childTopYs = children.map { $0.node.position.y - (cardSize.height / 2) + 4 }
                let childTopMinY = childTopYs.min() ?? parentBottomY + 40
                let baseLaneY = parentBottomY + 52 + (laneOffsetByParentID[parentID] ?? 0)
                let laneY = min(max(parentBottomY + 14, baseLaneY), childTopMinY - 16)
                let color = children.first?.color ?? .blue

                let childXs = children.map { $0.node.position.x }
                let minChildX = childXs.min() ?? parent.position.x
                let maxChildX = childXs.max() ?? parent.position.x

                var path = Path()
                path.move(to: CGPoint(x: parent.position.x, y: parentBottomY))
                path.addLine(to: CGPoint(x: parent.position.x, y: laneY))

                if children.count > 1 || abs(parent.position.x - minChildX) > 1 {
                    path.addLine(to: CGPoint(x: minChildX, y: laneY))
                }

                if children.count > 1 || abs(maxChildX - minChildX) > 1 {
                    path.move(to: CGPoint(x: minChildX, y: laneY))
                    path.addLine(to: CGPoint(x: maxChildX, y: laneY))
                }

                for child in children {
                    let childTopY = child.node.position.y - (cardSize.height / 2) + 4
                    path.move(to: CGPoint(x: child.node.position.x, y: laneY))
                    path.addLine(to: CGPoint(x: child.node.position.x, y: childTopY))
                }

                context.stroke(
                    path,
                    with: .color(color),
                    style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
                )
            }

            for (index, link) in secondaryLinks.enumerated() {
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

                var path = Path()
                path.move(to: start)
                path.addLine(to: CGPoint(x: start.x, y: detourY))
                path.addLine(to: CGPoint(x: end.x, y: detourY))
                path.addLine(to: end)

                context.stroke(
                    path,
                    with: .color(link.color.opacity(0.9)),
                    style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round, dash: [6, 4])
                )
            }
        }
    }
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
                    isSelected ? Color.orange : Color.black.opacity(0.08),
                    lineWidth: isSelected ? 2 : 1
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
        ),
        NodeLink(
            fromID: UUID(uuidString: "6246D613-DBB4-4D30-8168-08D0A1ED2BB3")!,
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
            NodeLink(fromID: buildID, toID: releaseID, tone: .teal),
            NodeLink(fromID: qualityID, toID: releaseID, tone: .orange)
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
            NodeLink(fromID: remediationID, toID: approverID, tone: .teal),
            NodeLink(fromID: forensicsID, toID: approverID, tone: .green)
        ]

        return makeHierarchySnapshot(nodes: nodes, links: links)
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
