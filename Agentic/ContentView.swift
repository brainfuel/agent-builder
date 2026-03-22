import SwiftUI
import SwiftData

struct ContentView: View {
    private let cardSize = CGSize(width: 264, height: 88)
    private let minimumCanvasSize = CGSize(width: 1900, height: 1200)
    private let minZoom: CGFloat = 0.6
    private let maxZoom: CGFloat = 1.5
    private let zoomStep: CGFloat = 0.1
    private let savedStructuresDefaultsKey = "agentic.savedStructures.v1"

    @Environment(\.modelContext) private var modelContext
    @Environment(\.undoManager) private var undoManager
    @Query private var graphDocuments: [GraphDocument]
    @State private var isShowingTaskList = true
    @State private var currentGraphKey: String?
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
    @State private var pendingCoordinatorExecution: PendingCoordinatorExecution?
    @State private var humanDecisionAudit: [HumanDecisionAuditEvent] = []
    @State private var isShowingHumanInbox = false
    @State private var humanDecisionNote = ""
    @State private var humanActorIdentity = "Human Reviewer"
    @State private var synthesisContext = ""
    @State private var synthesisQuestions: [SynthesisQuestionState] = []
    @State private var synthesizedStructure: HierarchySnapshot?
    @State private var synthesisStatusMessage: String?
    @State private var isShowingNewTaskOptions = false
    @State private var newTaskTitle = ""
    @State private var newTaskGoal = ""
    @State private var newTaskContext = ""

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

    private var synthesisPreview: SynthesisPreviewSummary? {
        guard let synthesizedStructure else { return nil }
        return summarizeSynthesisPreview(for: synthesizedStructure)
    }

    private var pendingHumanPacket: CoordinatorTaskPacket? {
        guard
            let pendingCoordinatorExecution,
            let packetID = pendingCoordinatorExecution.awaitingHumanPacketID
        else { return nil }
        return pendingCoordinatorExecution.plan.packets.first(where: { $0.id == packetID })
    }

    private var taskDocuments: [GraphDocument] {
        graphDocuments.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return (lhs.createdAt ?? .distantPast) > (rhs.createdAt ?? .distantPast)
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private var activeTaskTitle: String {
        let title = activeGraphDocument?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Task" : title
    }

    var body: some View {
        ZStack {
            if isShowingTaskList {
                taskListView
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .leading).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        )
                    )
            } else {
                editorWorkspace
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        )
                    )
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .animation(.easeInOut(duration: 0.18), value: selectedNodeID)
        .animation(.snappy(duration: 0.28, extraBounce: 0.02), value: isShowingTaskList)
        .onAppear {
            loadSavedHierarchies()
            modelContext.undoManager = undoManager
            ensureAnyGraphDocument()
            if currentGraphKey == nil {
                currentGraphKey = taskDocuments.first?.key
            }
            syncGraphFromStore()
        }
        .onChange(of: currentGraphKey) { _, _ in
            syncGraphFromStore()
        }
        .onChange(of: graphDocuments.count) { _, _ in
            if currentGraphKey == nil {
                currentGraphKey = taskDocuments.first?.key
                if !isShowingTaskList {
                    syncGraphFromStore()
                }
            } else if let currentGraphKey, !graphDocuments.contains(where: { $0.key == currentGraphKey }) {
                self.currentGraphKey = taskDocuments.first?.key
            }
        }
        .onChange(of: semanticFingerprint) { _, newValue in
            persistGraphIfNeeded(for: newValue)
        }
        .onChange(of: orchestrationGoal) { _, _ in
            persistActiveTaskMetadata()
        }
        .onChange(of: humanActorIdentity) { _, _ in
            persistCoordinatorExecutionState()
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
        .confirmationDialog("Create Top-Level Task", isPresented: $isShowingNewTaskOptions) {
            Button("Simple Task") {
                createSimpleTask()
            }
            Button("Generate Structure") {
                createGeneratedTaskFromDraft()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Choose how to create the new coordinator task.")
        }
        .sheet(isPresented: $isShowingHumanInbox) {
            HumanInboxPanel(
                pendingPacket: pendingHumanPacket,
                actorIdentity: $humanActorIdentity,
                decisionNote: $humanDecisionNote,
                auditTrail: humanDecisionAudit,
                onApprove: { resolveHumanTask(.approve) },
                onReject: { resolveHumanTask(.reject) },
                onNeedsInfo: { resolveHumanTask(.needsInfo) }
            )
            .presentationDetents([.medium, .large])
        }
    }

    private var editorWorkspace: some View {
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
    }

    private var taskListView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Coordinator Tasks")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("Manage top-level task structures and human inbox attention.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    presentTaskCreationOptions()
                } label: {
                    Label("New Task", systemImage: "plus")
                        .font(.headline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .background(Color(uiColor: .systemBackground))

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("New Task Draft")
                    .font(.headline)
                Text("Set title, goal, and context once, then choose Simple Task or Generate Structure.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    TextField("Task title", text: $newTaskTitle)
                        .textFieldStyle(.roundedBorder)
                    TextField("Goal", text: $newTaskGoal)
                        .textFieldStyle(.roundedBorder)
                    TextField("Context", text: $newTaskContext)
                        .textFieldStyle(.roundedBorder)
                }

                HStack(spacing: 10) {
                    Button {
                        presentTaskCreationOptions()
                    } label: {
                        Label("Create", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Clear") {
                        resetTaskDraft()
                    }
                    .buttonStyle(.bordered)
                    .disabled(
                        newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                        newTaskGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                        newTaskContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(Color(uiColor: .systemBackground))

            Divider()

            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(taskDocuments, id: \.key) { document in
                        taskRow(document)
                    }
                }
                .padding(24)
            }
        }
    }

    private func taskRow(_ document: GraphDocument) -> some View {
        let status = runStatus(for: document)
        let title = document.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let goal = document.goal?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title.isEmpty ? "Untitled Task" : title)
                        .font(.headline)
                    Text(goal.isEmpty ? "No goal set." : goal)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Text(status.label)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(status.color.opacity(0.18))
                    )
                    .foregroundStyle(status.color)
            }

            HStack(spacing: 10) {
                Button {
                    openTaskEditor(key: document.key)
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    openHumanInbox(for: document.key)
                } label: {
                    Label("Human Inbox", systemImage: "tray.full")
                }
                .buttonStyle(.bordered)

                Spacer()
                Text("Updated \(document.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
    }

    private func runStatus(for document: GraphDocument) -> TaskRunStatus {
        guard
            let data = document.executionStateData,
            let bundle = try? JSONDecoder().decode(CoordinatorExecutionStateBundle.self, from: data)
        else {
            return .draft
        }

        if bundle.pendingExecution?.awaitingHumanPacketID != nil {
            return .needsAttention
        }
        if bundle.pendingExecution != nil {
            return .inProgress
        }
        if let run = bundle.latestRun, !run.results.isEmpty {
            return run.succeededCount == run.results.count ? .completed : .needsAttention
        }
        return .draft
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(activeTaskTitle)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Hierarchy editor for humans and AI agents.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 12) {
                Button {
                    withAnimation(.snappy(duration: 0.28, extraBounce: 0.02)) {
                        isShowingTaskList = true
                    }
                } label: {
                    Label("Tasks", systemImage: "chevron.left")
                        .font(.headline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)

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
                .disabled(isExecutingCoordinator || nodes.isEmpty || pendingCoordinatorExecution != nil)

                Button {
                    isShowingHumanInbox = true
                } label: {
                    Label(
                        pendingHumanPacket == nil ? "Human Inbox" : "Human Inbox (1)",
                        systemImage: "tray.full"
                    )
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 10) {
                TextField("Optional context (data sources, constraints, risk tolerance)...", text: $synthesisContext)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1)

                Button {
                    generateSuggestedStructure()
                } label: {
                    Label("Generate Structure", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .disabled(orchestrationGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if !synthesisQuestions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Discovery Questions")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach($synthesisQuestions) { $question in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(question.key.prompt)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("Optional answer", text: $question.answer)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }

            if let synthesisPreview {
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        "Suggested structure: \(synthesisPreview.suggestedNodeCount) nodes (\(synthesisPreview.nodeDeltaString)), \(synthesisPreview.suggestedLinkCount) links (\(synthesisPreview.linkDeltaString))."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    if !synthesisPreview.addedNodeNames.isEmpty {
                        Text("Adds: \(synthesisPreview.addedNodeNames.joined(separator: ", "))")
                            .font(.footnote)
                    }

                    if !synthesisPreview.removedNodeNames.isEmpty {
                        Text("Replaces: \(synthesisPreview.removedNodeNames.joined(separator: ", "))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 10) {
                        Button {
                            applySynthesizedStructure()
                        } label: {
                            Label("Apply Suggested Structure", systemImage: "checkmark.circle")
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Discard Suggestion", role: .destructive) {
                            discardSynthesizedStructure()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            if let synthesisStatusMessage {
                Text(synthesisStatusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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

            if
                let pendingCoordinatorExecution,
                pendingCoordinatorExecution.awaitingHumanPacketID == nil,
                !isExecutingCoordinator
            {
                Button("Resume Pending Run") {
                    isExecutingCoordinator = true
                    Task { await continueCoordinatorExecution() }
                }
                .buttonStyle(.borderedProminent)
            }

            if let pendingHumanPacket {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Human Inbox")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text("\(pendingHumanPacket.assignedNodeName) is waiting for a human decision.")
                        .font(.footnote)

                    Text(pendingHumanPacket.objective)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)

                    Text("Expected output: \(pendingHumanPacket.requiredOutputSchema.label)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("Decision note (optional)", text: $humanDecisionNote)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 10) {
                        Button("Approve & Continue") {
                            resolveHumanTask(.approve)
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Reject") {
                            resolveHumanTask(.reject)
                        }
                        .buttonStyle(.bordered)

                        Button("Needs Info") {
                            resolveHumanTask(.needsInfo)
                        }
                        .buttonStyle(.bordered)

                        Button("Open Inbox") {
                            isShowingHumanInbox = true
                        }
                        .buttonStyle(.bordered)
                    }
                }
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
                            persistCoordinatorExecutionState()
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
                inputSchema: node.inputSchema,
                outputSchema: node.outputSchema,
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
        humanDecisionNote = ""
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

        pendingCoordinatorExecution = PendingCoordinatorExecution(
            runID: "RUN-\(UUID().uuidString.prefix(8))",
            plan: plan,
            mode: mode,
            nextPacketIndex: 0,
            results: [],
            outputsByNodeID: [
                plan.coordinatorID: ProducedHandoff(
                    schema: plan.coordinatorOutputSchema,
                    summary: "Coordinator goal packet: \(plan.goal)"
                )
            ],
            startedAt: Date(),
            awaitingHumanPacketID: nil
        )
        isExecutingCoordinator = true
        persistCoordinatorExecutionState()
        Task {
            await continueCoordinatorExecution()
        }
    }

    @MainActor
    private func continueCoordinatorExecution() async {
        guard var pending = pendingCoordinatorExecution else { return }
        let client = MockMCPClient()

        while pending.nextPacketIndex < pending.plan.packets.count {
            let packet = pending.plan.packets[pending.nextPacketIndex]
            let startedAtStep = Date()
            updateTraceStep(
                packetID: packet.id,
                status: .running,
                startedAt: startedAtStep
            )

            let handoffValidation = validateRequiredHandoffs(
                for: packet,
                outputsByNodeID: pending.outputsByNodeID,
                goal: pending.plan.goal
            )

            if !handoffValidation.isValid {
                let finishedAtStep = Date()
                let blockedResult = CoordinatorTaskResult(
                    id: UUID().uuidString,
                    packetID: packet.id,
                    assignedNodeName: packet.assignedNodeName,
                    summary: handoffValidation.message,
                    confidence: 0,
                    completed: false,
                    finishedAt: finishedAtStep
                )
                pending.results.append(blockedResult)
                pending.nextPacketIndex += 1
                updateTraceStep(
                    packetID: packet.id,
                    status: .blocked,
                    summary: handoffValidation.message,
                    confidence: 0,
                    finishedAt: finishedAtStep
                )
                pendingCoordinatorExecution = pending
                persistCoordinatorExecutionState()
                continue
            }

            if packet.assignedNodeKind == .human {
                pending.awaitingHumanPacketID = packet.id
                pendingCoordinatorExecution = pending
                isExecutingCoordinator = false
                updateTraceStep(
                    packetID: packet.id,
                    status: .waitingHuman,
                    summary: "Awaiting human decision.",
                    confidence: nil,
                    finishedAt: nil
                )
                persistCoordinatorExecutionState()
                return
            }

            let response: MCPTaskResponse
            switch pending.mode {
            case .simulation:
                response = await simulatePacketExecution(
                    packet,
                    handoffSummaries: handoffValidation.handoffSummaries
                )
            case .liveMCP:
                response = await client.execute(
                    MCPTaskRequest(
                        packetID: packet.id,
                        objective: packet.objective,
                        inputSchema: packet.requiredInputSchema,
                        outputSchema: packet.requiredOutputSchema,
                        handoffSummaries: handoffValidation.handoffSummaries,
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
            pending.results.append(result)
            if completed {
                pending.outputsByNodeID[packet.assignedNodeID] = ProducedHandoff(
                    schema: packet.requiredOutputSchema,
                    summary: response.summary
                )
            }
            pending.nextPacketIndex += 1

            updateTraceStep(
                packetID: packet.id,
                status: completed ? .succeeded : .failed,
                summary: response.summary,
                confidence: response.confidence,
                finishedAt: finishedAtStep
            )
            pendingCoordinatorExecution = pending
            persistCoordinatorExecutionState()
        }

        latestCoordinatorRun = CoordinatorRun(
            runID: pending.runID,
            planID: pending.plan.planID,
            mode: pending.mode,
            results: pending.results,
            startedAt: pending.startedAt,
            finishedAt: Date()
        )
        pendingCoordinatorExecution = nil
        isExecutingCoordinator = false
        persistCoordinatorExecutionState()
    }

    @MainActor
    private func resolveHumanTask(_ decision: HumanTaskDecision) {
        guard
            var pending = pendingCoordinatorExecution,
            let packetID = pending.awaitingHumanPacketID,
            let packet = pending.plan.packets.first(where: { $0.id == packetID })
        else { return }

        let finishedAt = Date()
        let note = humanDecisionNote.trimmingCharacters(in: .whitespacesAndNewlines)
        humanDecisionNote = ""

        let actor = humanActorIdentity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Human Reviewer"
            : humanActorIdentity.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary: String
        let status: CoordinatorTraceStatus
        let completed: Bool

        switch decision {
        case .approve:
            summary = note.isEmpty ? "Approved by \(actor)." : "Approved by \(actor): \(note)"
            status = .approved
            completed = true
            pending.outputsByNodeID[packet.assignedNodeID] = ProducedHandoff(
                schema: packet.requiredOutputSchema,
                summary: summary
            )
        case .reject:
            summary = note.isEmpty ? "Rejected by \(actor)." : "Rejected by \(actor): \(note)"
            status = .rejected
            completed = false
        case .needsInfo:
            summary = note.isEmpty ? "\(actor) requested additional information before decision." : "\(actor) needs info: \(note)"
            status = .needsInfo
            completed = false
        }

        pending.results.append(
            CoordinatorTaskResult(
                id: UUID().uuidString,
                packetID: packet.id,
                assignedNodeName: packet.assignedNodeName,
                summary: summary,
                confidence: 1,
                completed: completed,
                finishedAt: finishedAt
            )
        )
        pending.nextPacketIndex += 1
        pending.awaitingHumanPacketID = nil
        humanDecisionAudit.append(
            HumanDecisionAuditEvent(
                id: UUID().uuidString,
                runID: pending.runID,
                packetID: packet.id,
                nodeName: packet.assignedNodeName,
                decision: decision,
                note: note,
                actorIdentity: actor,
                decidedAt: finishedAt
            )
        )

        updateTraceStep(
            packetID: packet.id,
            status: status,
            summary: summary,
            confidence: 1,
            finishedAt: finishedAt
        )

        switch decision {
        case .approve:
            pendingCoordinatorExecution = pending
            isExecutingCoordinator = true
            persistCoordinatorExecutionState()
            Task {
                await continueCoordinatorExecution()
            }
        case .reject, .needsInfo:
            latestCoordinatorRun = CoordinatorRun(
                runID: pending.runID,
                planID: pending.plan.planID,
                mode: pending.mode,
                results: pending.results,
                startedAt: pending.startedAt,
                finishedAt: Date()
            )
            pendingCoordinatorExecution = nil
            isExecutingCoordinator = false
            persistCoordinatorExecutionState()
        }
    }

    private func simulatePacketExecution(
        _ packet: CoordinatorTaskPacket,
        handoffSummaries: [String]
    ) async -> MCPTaskResponse {
        let permissionPreview = packet.allowedPermissions.prefix(3).joined(separator: ", ")
        let hasRestrictedAccess = packet.allowedPermissions.contains(SecurityAccess.secretsRead.rawValue)
            || packet.allowedPermissions.contains(SecurityAccess.terminalExec.rawValue)

        let delay: UInt64 = hasRestrictedAccess ? 280_000_000 : 180_000_000
        try? await Task.sleep(nanoseconds: delay)

        let inputPreview = handoffSummaries.isEmpty
            ? "No upstream handoff (root context)."
            : "Handoffs: \(handoffSummaries.joined(separator: " | "))"
        let summary = [
            "Simulated output for \(packet.assignedNodeName).",
            "Objective: \(packet.objective)",
            "Input schema: \(packet.requiredInputSchema.rawValue).",
            inputPreview,
            permissionPreview.isEmpty ? "Policy check: no elevated permissions required." : "Policy check: \(permissionPreview).",
            "Output schema: \(packet.requiredOutputSchema.rawValue)."
        ].joined(separator: " ")

        return MCPTaskResponse(
            summary: summary,
            confidence: hasRestrictedAccess ? 0.79 : 0.86,
            completed: true
        )
    }

    private func validateRequiredHandoffs(
        for packet: CoordinatorTaskPacket,
        outputsByNodeID: [UUID: ProducedHandoff],
        goal: String
    ) -> HandoffValidation {
        if packet.requiredHandoffs.isEmpty {
            if packet.requiredInputSchema != .goalBriefV1 {
                return HandoffValidation(
                    isValid: false,
                    message: "Blocked: \(packet.assignedNodeName) expects \(packet.requiredInputSchema.label) but has no parent handoff.",
                    handoffSummaries: []
                )
            }
            return HandoffValidation(
                isValid: true,
                message: "",
                handoffSummaries: ["Coordinator goal: \(goal)"]
            )
        }

        var summaries: [String] = []
        for requirement in packet.requiredHandoffs {
            guard let handoff = outputsByNodeID[requirement.fromNodeID] else {
                return HandoffValidation(
                    isValid: false,
                    message: "Blocked: missing handoff from \(requirement.fromNodeName).",
                    handoffSummaries: []
                )
            }

            if handoff.schema != requirement.outputSchema {
                return HandoffValidation(
                    isValid: false,
                    message: "Blocked: \(requirement.fromNodeName) produced \(handoff.schema.label), expected \(requirement.outputSchema.label).",
                    handoffSummaries: []
                )
            }

            if requirement.outputSchema != packet.requiredInputSchema {
                return HandoffValidation(
                    isValid: false,
                    message: "Blocked: \(packet.assignedNodeName) requires \(packet.requiredInputSchema.label) but parent \(requirement.fromNodeName) outputs \(requirement.outputSchema.label).",
                    handoffSummaries: []
                )
            }

            summaries.append("\(requirement.fromNodeName): \(handoff.summary)")
        }

        return HandoffValidation(
            isValid: true,
            message: "",
            handoffSummaries: summaries
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

    private func generateSuggestedStructure() {
        let normalizedGoal = orchestrationGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedGoal.isEmpty else {
            synthesisStatusMessage = "Enter a coordinator goal first."
            return
        }

        let synthesizer = TeamStructureSynthesizer()
        let requiredQuestions = synthesizer.discoveryQuestions(goal: normalizedGoal, context: synthesisContext)
        let previousAnswers = Dictionary(uniqueKeysWithValues: synthesisQuestions.map { ($0.key, $0.answer) })
        synthesisQuestions = requiredQuestions.map {
            SynthesisQuestionState(key: $0, answer: previousAnswers[$0] ?? "")
        }

        let answers = Dictionary(uniqueKeysWithValues: synthesisQuestions.map {
            ($0.key, $0.answer.trimmingCharacters(in: .whitespacesAndNewlines))
        })

        synthesizedStructure = synthesizer.synthesize(
            goal: normalizedGoal,
            context: synthesisContext,
            answers: answers
        )

        let unansweredCount = synthesisQuestions.filter {
            $0.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count

        if unansweredCount > 0 {
            synthesisStatusMessage =
                "Draft generated. \(unansweredCount) discovery question(s) are unanswered; fill them and re-generate for a tighter team plan."
        } else {
            synthesisStatusMessage = "Suggested structure generated from goal, context, and discovery answers."
        }
    }

    private func applySynthesizedStructure() {
        guard let synthesizedStructure else { return }
        applyStructureSnapshot(synthesizedStructure)
        self.synthesizedStructure = nil
        synthesisStatusMessage = "Applied suggested structure."
    }

    private func discardSynthesizedStructure() {
        synthesizedStructure = nil
        synthesisStatusMessage = "Suggestion discarded."
    }

    private func summarizeSynthesisPreview(for snapshot: HierarchySnapshot) -> SynthesisPreviewSummary {
        let currentNames = Set(nodes.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        let suggestedNames = Set(snapshot.nodes.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })

        let addedNames = snapshot.nodes
            .map(\.name)
            .filter { !currentNames.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
            .sorted()
        let removedNames = nodes
            .map(\.name)
            .filter { !suggestedNames.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
            .sorted()

        return SynthesisPreviewSummary(
            suggestedNodeCount: snapshot.nodes.count,
            suggestedLinkCount: snapshot.links.count,
            nodeDelta: snapshot.nodes.count - nodes.count,
            linkDelta: snapshot.links.count - links.count,
            addedNodeNames: Array(addedNames.prefix(8)),
            removedNodeNames: Array(removedNames.prefix(8))
        )
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
                    node.inputSchema.rawValue,
                    node.outputSchema.rawValue,
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
        var inheritedInputSchemaForNewNode: HandoffSchema?

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
            inheritedInputSchemaForNewNode = selectedNode.outputSchema
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
            inputSchema: inheritedInputSchemaForNewNode ?? defaultInputSchema(for: type),
            outputSchema: defaultOutputSchema(for: type),
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
                inputSchema: entry.inputSchema ?? defaultInputSchema(for: entry.type),
                outputSchema: entry.outputSchema ?? defaultOutputSchema(for: entry.type),
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

    private func defaultInputSchema(for type: NodeType) -> HandoffSchema {
        switch type {
        case .human:
            return .taskResultV1
        case .agent:
            return .taskResultV1
        }
    }

    private func defaultOutputSchema(for type: NodeType) -> HandoffSchema {
        switch type {
        case .human:
            return .releaseDecisionV1
        case .agent:
            return .taskResultV1
        }
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
        if let currentGraphKey, let exact = graphDocuments.first(where: { $0.key == currentGraphKey }) {
            return exact
        }
        return taskDocuments.first
    }

    private func ensureAnyGraphDocument() {
        if !graphDocuments.isEmpty { return }
        guard let data = try? JSONEncoder().encode(simpleTaskSnapshot()) else {
            return
        }

        let document = GraphDocument(
            title: "New Coordinator Task",
            goal: orchestrationGoal,
            snapshotData: data,
            executionStateData: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        modelContext.insert(document)
        try? modelContext.save()
        currentGraphKey = document.key
    }

    private func presentTaskCreationOptions() {
        if newTaskGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            newTaskGoal = orchestrationGoal
        }
        if newTaskContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            newTaskContext = synthesisContext
        }
        isShowingNewTaskOptions = true
    }

    private func resetTaskDraft() {
        newTaskTitle = ""
        newTaskGoal = ""
        newTaskContext = ""
    }

    private func openTaskEditor(key: String) {
        currentGraphKey = key
        isShowingHumanInbox = false
        withAnimation(.snappy(duration: 0.28, extraBounce: 0.02)) {
            isShowingTaskList = false
        }
        syncGraphFromStore()
    }

    private func openHumanInbox(for key: String) {
        currentGraphKey = key
        syncGraphFromStore()
        isShowingHumanInbox = true
    }

    private func createSimpleTask() {
        let draftTitle = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let draftGoal = newTaskGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = draftTitle.isEmpty
            ? "Task \(Date().formatted(.dateTime.month().day().hour().minute()))"
            : draftTitle
        let goal = draftGoal.isEmpty ? orchestrationGoal : draftGoal
        createTaskDocument(
            title: title,
            goal: goal,
            snapshot: simpleTaskSnapshot()
        )
        resetTaskDraft()
    }

    private func createGeneratedTaskFromDraft() {
        let rawGoal = newTaskGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = newTaskContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let goal = rawGoal.isEmpty ? orchestrationGoal : rawGoal

        let synthesizer = TeamStructureSynthesizer()
        let snapshot = synthesizer.synthesize(
            goal: goal.isEmpty ? "Execute coordinator objective" : goal,
            context: context,
            answers: [:]
        )
        createTaskDocument(
            title: title.isEmpty ? "Generated Task" : title,
            goal: goal,
            snapshot: snapshot
        )
        resetTaskDraft()
    }

    private func createTaskDocument(title: String, goal: String, snapshot: HierarchySnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }

        let document = GraphDocument(
            title: title,
            goal: goal,
            snapshotData: data,
            executionStateData: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        modelContext.insert(document)
        try? modelContext.save()

        currentGraphKey = document.key
        withAnimation(.snappy(duration: 0.28, extraBounce: 0.02)) {
            isShowingTaskList = false
        }
        syncGraphFromStore()
    }

    private func simpleTaskSnapshot() -> HierarchySnapshot {
        let coordinatorID = UUID()
        let executionID = UUID()
        let qaID = UUID()
        let releaseID = UUID()

        let basicNodes: [OrgNode] = [
            OrgNode(id: coordinatorID, name: "Coordinator", title: "Task Lead", department: "Control Plane", type: .agent, provider: .chatGPT, roleDescription: "Coordinates planning and execution workflow.", inputSchema: .goalBriefV1, outputSchema: .strategyPlanV1, selectedRoles: [.coordinator, .planner], securityAccess: [.workspaceRead, .workspaceWrite], position: .zero),
            OrgNode(id: executionID, name: "Execution Agent", title: "Builder", department: "Delivery", type: .agent, provider: .claude, roleDescription: "Implements scoped execution steps.", inputSchema: .strategyPlanV1, outputSchema: .buildPatchV1, selectedRoles: [.executor], securityAccess: [.workspaceRead, .workspaceWrite, .terminalExec], position: .zero),
            OrgNode(id: qaID, name: "QA Agent", title: "Validator", department: "Quality", type: .agent, provider: .grok, roleDescription: "Validates outputs and runs checks.", inputSchema: .buildPatchV1, outputSchema: .validationReportV1, selectedRoles: [.reviewer], securityAccess: [.workspaceRead, .terminalExec], position: .zero),
            OrgNode(id: releaseID, name: "Release Manager", title: "Human Approval", department: "Operations", type: .human, provider: .chatGPT, roleDescription: "Approves final rollout decision.", inputSchema: .validationReportV1, outputSchema: .releaseDecisionV1, selectedRoles: [.decisionMaker, .reviewer], securityAccess: [.workspaceRead, .auditLogs], position: .zero)
        ]

        let basicLinks: [NodeLink] = [
            NodeLink(fromID: coordinatorID, toID: executionID, tone: .blue),
            NodeLink(fromID: executionID, toID: qaID, tone: .orange),
            NodeLink(fromID: qaID, toID: releaseID, tone: .indigo)
        ]

        return makeHierarchySnapshot(nodes: basicNodes, links: basicLinks)
    }

    private func persistActiveTaskMetadata() {
        guard let document = activeGraphDocument else { return }
        if (document.goal ?? "") != orchestrationGoal {
            document.goal = orchestrationGoal
            document.updatedAt = Date()
            try? modelContext.save()
        }
    }

    private func syncGraphFromStore() {
        guard
            let document = activeGraphDocument,
            let snapshot = try? JSONDecoder().decode(HierarchySnapshot.self, from: document.snapshotData)
        else {
            relayoutHierarchy()
            syncCoordinatorExecutionState(from: nil)
            lastPersistedFingerprint = semanticFingerprint
            return
        }

        suppressStoreSync = true
        setGraph(from: snapshot, resetViewState: false)
        suppressStoreSync = false
        if orchestrationGoal != (document.goal ?? "") {
            orchestrationGoal = document.goal ?? ""
        }
        syncCoordinatorExecutionState(from: document)
        lastPersistedFingerprint = semanticFingerprint
    }

    private func persistGraphIfNeeded(for newFingerprint: String) {
        guard !suppressStoreSync else { return }
        guard newFingerprint != lastPersistedFingerprint else { return }
        guard
            let document = activeGraphDocument,
            let data = try? JSONEncoder().encode(captureStructureSnapshot())
        else { return }

        document.snapshotData = data
        document.updatedAt = Date()
        try? modelContext.save()
        lastPersistedFingerprint = newFingerprint
    }

    private func syncCoordinatorExecutionState(from document: GraphDocument?) {
        guard
            let data = document?.executionStateData,
            let decoded = try? JSONDecoder().decode(CoordinatorExecutionStateBundle.self, from: data)
        else {
            pendingCoordinatorExecution = nil
            latestCoordinatorRun = nil
            coordinatorTrace = []
            humanDecisionAudit = []
            if humanActorIdentity.isEmpty {
                humanActorIdentity = "Human Reviewer"
            }
            isExecutingCoordinator = false
            return
        }

        pendingCoordinatorExecution = decoded.pendingExecution
        latestCoordinatorRun = decoded.latestRun
        coordinatorTrace = decoded.trace
        humanDecisionAudit = decoded.humanDecisionAudit
        humanActorIdentity = decoded.humanActorIdentity
        isExecutingCoordinator = false
    }

    private func persistCoordinatorExecutionState() {
        ensureAnyGraphDocument()
        guard let document = activeGraphDocument else { return }

        let sanitizedActor = humanActorIdentity.trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitizedActor.isEmpty {
            humanActorIdentity = "Human Reviewer"
        } else {
            humanActorIdentity = sanitizedActor
        }

        if
            pendingCoordinatorExecution == nil,
            latestCoordinatorRun == nil,
            coordinatorTrace.isEmpty,
            humanDecisionAudit.isEmpty
        {
            document.executionStateData = nil
            document.updatedAt = Date()
            try? modelContext.save()
            return
        }

        let bundle = CoordinatorExecutionStateBundle(
            pendingExecution: pendingCoordinatorExecution,
            latestRun: latestCoordinatorRun,
            trace: coordinatorTrace,
            humanDecisionAudit: humanDecisionAudit,
            humanActorIdentity: humanActorIdentity
        )
        guard let data = try? JSONEncoder().encode(bundle) else { return }

        document.executionStateData = data
        document.updatedAt = Date()
        try? modelContext.save()
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
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Input Schema", selection: $node.inputSchema) {
                        ForEach(HandoffSchema.allCases) { schema in
                            Text(schema.label).tag(schema)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("Output Schema", selection: $node.outputSchema) {
                        ForEach(HandoffSchema.allCases) { schema in
                            Text(schema.label).tag(schema)
                        }
                    }
                    .pickerStyle(.menu)
                }
            } label: {
                Text("Typed Handoffs")
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

private struct HumanInboxPanel: View {
    @Environment(\.dismiss) private var dismiss
    let pendingPacket: CoordinatorTaskPacket?
    @Binding var actorIdentity: String
    @Binding var decisionNote: String
    let auditTrail: [HumanDecisionAuditEvent]
    let onApprove: () -> Void
    let onReject: () -> Void
    let onNeedsInfo: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Spacer()
                        Button("Close") {
                            dismiss()
                        }
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.escape, modifiers: [])
                    }

                    GroupBox("Pending Human Task") {
                        if let pendingPacket {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(pendingPacket.assignedNodeName)
                                    .font(.headline)
                                Text(pendingPacket.objective)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)

                                Text("Expected output schema: \(pendingPacket.requiredOutputSchema.label)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                TextField("Actor identity", text: $actorIdentity)
                                    .textFieldStyle(.roundedBorder)

                                TextField("Decision note (optional)", text: $decisionNote)
                                    .textFieldStyle(.roundedBorder)

                                HStack(spacing: 10) {
                                    Button("Approve & Continue") {
                                        onApprove()
                                    }
                                    .buttonStyle(.borderedProminent)

                                    Button("Reject") {
                                        onReject()
                                    }
                                    .buttonStyle(.bordered)

                                    Button("Needs Info") {
                                        onNeedsInfo()
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .padding(.top, 4)
                        } else {
                            Text("No pending human tasks.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 4)
                        }
                    }

                    GroupBox("Decision Audit Trail") {
                        if auditTrail.isEmpty {
                            Text("No recorded human decisions yet.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 4)
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(auditTrail.sorted { $0.decidedAt > $1.decidedAt }) { event in
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(event.nodeName)
                                                .font(.subheadline.weight(.semibold))
                                            Spacer()
                                            Text(event.decision.label)
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(decisionColor(for: event.decision))
                                        }
                                        Text("Actor: \(event.actorIdentity)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text("Run: \(event.runID) • \(event.decidedAt.formatted(.dateTime))")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        if !event.note.isEmpty {
                                            Text(event.note)
                                                .font(.caption)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("Human Inbox")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func decisionColor(for decision: HumanTaskDecision) -> Color {
        switch decision {
        case .approve:
            return .green
        case .reject:
            return .red
        case .needsInfo:
            return .orange
        }
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
    var inputSchema: HandoffSchema
    var outputSchema: HandoffSchema
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
            inputSchema: .goalBriefV1,
            outputSchema: .strategyPlanV1,
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
            inputSchema: .goalBriefV1,
            outputSchema: .releaseDecisionV1,
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
            inputSchema: .strategyPlanV1,
            outputSchema: .researchBriefV1,
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
            inputSchema: .strategyPlanV1,
            outputSchema: .buildPatchV1,
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
            inputSchema: .buildPatchV1,
            outputSchema: .validationReportV1,
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
            inputSchema: .buildPatchV1,
            outputSchema: .releaseDecisionV1,
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
            inputSchema: .strategyPlanV1,
            outputSchema: .taskResultV1,
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
            inputSchema: .validationReportV1,
            outputSchema: .releaseDecisionV1,
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
    var inputSchema: HandoffSchema?
    var outputSchema: HandoffSchema?
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
            inputSchema: node.inputSchema,
            outputSchema: node.outputSchema,
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
            OrgNode(id: coordinatorID, name: "Program Lead", title: "Coordinator", department: "Planning", type: .human, provider: .chatGPT, roleDescription: "Sets direction and approves release scope.", inputSchema: .goalBriefV1, outputSchema: .strategyPlanV1, selectedRoles: [.decisionMaker], securityAccess: [.workspaceRead, .auditLogs], position: .zero),
            OrgNode(id: plannerID, name: "Strategy Agent", title: "Planner", department: "Planning", type: .agent, provider: .chatGPT, roleDescription: "Breaks goals into implementation tracks.", inputSchema: .strategyPlanV1, outputSchema: .strategyPlanV1, selectedRoles: [.planner], securityAccess: [.workspaceRead, .workspaceWrite], position: .zero),
            OrgNode(id: researchID, name: "Research Agent", title: "Research", department: "Discovery", type: .agent, provider: .gemini, roleDescription: "Collects context and references for execution.", inputSchema: .strategyPlanV1, outputSchema: .researchBriefV1, selectedRoles: [.researcher], securityAccess: [.workspaceRead, .webAccess], position: .zero),
            OrgNode(id: buildID, name: "Builder Agent", title: "Executor", department: "Delivery", type: .agent, provider: .claude, roleDescription: "Implements requested changes.", inputSchema: .strategyPlanV1, outputSchema: .buildPatchV1, selectedRoles: [.executor], securityAccess: [.workspaceRead, .workspaceWrite, .terminalExec], position: .zero),
            OrgNode(id: qualityID, name: "QA Agent", title: "Reviewer", department: "Quality", type: .agent, provider: .grok, roleDescription: "Runs tests and validates behavior.", inputSchema: .buildPatchV1, outputSchema: .validationReportV1, selectedRoles: [.reviewer], securityAccess: [.workspaceRead, .terminalExec], position: .zero),
            OrgNode(id: releaseID, name: "Release Manager", title: "Human Signoff", department: "Operations", type: .human, provider: .chatGPT, roleDescription: "Approves deployment and communications.", inputSchema: .validationReportV1, outputSchema: .releaseDecisionV1, selectedRoles: [.decisionMaker, .reviewer], securityAccess: [.workspaceRead, .auditLogs], position: .zero)
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
            OrgNode(id: commanderID, name: "Incident Commander", title: "Coordinator", department: "Security", type: .human, provider: .chatGPT, roleDescription: "Owns response decisions and escalation.", inputSchema: .goalBriefV1, outputSchema: .strategyPlanV1, selectedRoles: [.coordinator, .decisionMaker], securityAccess: [.workspaceRead, .auditLogs], position: .zero),
            OrgNode(id: triageID, name: "Triage Agent", title: "Classifier", department: "Security", type: .agent, provider: .chatGPT, roleDescription: "Classifies impact and routes tasks.", inputSchema: .strategyPlanV1, outputSchema: .taskResultV1, selectedRoles: [.planner, .summarizer], securityAccess: [.workspaceRead, .webAccess], position: .zero),
            OrgNode(id: remediationID, name: "Remediation Agent", title: "Executor", department: "Engineering", type: .agent, provider: .claude, roleDescription: "Applies fixes and executes rollback plans.", inputSchema: .taskResultV1, outputSchema: .buildPatchV1, selectedRoles: [.executor], securityAccess: [.workspaceRead, .workspaceWrite, .terminalExec], position: .zero),
            OrgNode(id: commsID, name: "Comms Agent", title: "Status Reporter", department: "Comms", type: .agent, provider: .gemini, roleDescription: "Produces executive and customer updates.", inputSchema: .taskResultV1, outputSchema: .taskResultV1, selectedRoles: [.summarizer], securityAccess: [.workspaceRead], position: .zero),
            OrgNode(id: forensicsID, name: "Forensics Agent", title: "Investigator", department: "Security", type: .agent, provider: .grok, roleDescription: "Collects traces and root-cause timeline.", inputSchema: .taskResultV1, outputSchema: .researchBriefV1, selectedRoles: [.researcher, .reviewer], securityAccess: [.workspaceRead, .terminalExec], position: .zero),
            OrgNode(id: approverID, name: "Approver", title: "Human Gate", department: "Leadership", type: .human, provider: .chatGPT, roleDescription: "Approves high-impact remediations.", inputSchema: .buildPatchV1, outputSchema: .releaseDecisionV1, selectedRoles: [.decisionMaker], securityAccess: [.auditLogs], position: .zero)
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

private struct SynthesisPreviewSummary {
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

private enum TaskRunStatus {
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

    var color: Color {
        switch self {
        case .draft:
            return .gray
        case .inProgress:
            return .blue
        case .needsAttention:
            return .orange
        case .completed:
            return .green
        }
    }
}

private struct SynthesisQuestionState: Identifiable {
    let key: SynthesisQuestionKey
    var answer: String

    var id: String { key.rawValue }
}

private enum SynthesisQuestionKey: String, CaseIterable, Identifiable, Hashable {
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

private struct TeamStructureSynthesizer {
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
                inputSchema: .goalBriefV1,
                outputSchema: .strategyPlanV1,
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
            inputSchema: HandoffSchema,
            outputSchema: HandoffSchema,
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
            inputSchema: .strategyPlanV1,
            outputSchema: .strategyPlanV1,
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
                inputSchema: .strategyPlanV1,
                outputSchema: .researchBriefV1,
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
                inputSchema: .strategyPlanV1,
                outputSchema: .buildPatchV1,
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
                inputSchema: buildID == nil ? .strategyPlanV1 : .buildPatchV1,
                outputSchema: .validationReportV1,
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
                inputSchema: .buildPatchV1,
                outputSchema: .validationReportV1,
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
                inputSchema: .strategyPlanV1,
                outputSchema: .taskResultV1,
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
                inputSchema: .validationReportV1,
                outputSchema: .releaseDecisionV1,
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

    var color: Color {
        switch self {
        case .queued:
            return .gray
        case .running:
            return .blue
        case .waitingHuman:
            return .indigo
        case .succeeded:
            return .green
        case .approved:
            return .green
        case .rejected:
            return .red
        case .needsInfo:
            return .orange
        case .blocked:
            return .orange
        case .failed:
            return .red
        }
    }
}

private struct CoordinatorTraceStep: Identifiable, Codable {
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
    let inputSchema: HandoffSchema
    let outputSchema: HandoffSchema
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
    let assignedNodeKind: OrchestrationNodeKind
    let objective: String
    let requiredInputSchema: HandoffSchema
    let requiredOutputSchema: HandoffSchema
    let requiredHandoffs: [CoordinatorHandoffRequirement]
    let allowedPermissions: [String]
}

private struct PendingCoordinatorExecution: Codable {
    let runID: String
    let plan: CoordinatorPlan
    let mode: CoordinatorExecutionMode
    var nextPacketIndex: Int
    var results: [CoordinatorTaskResult]
    var outputsByNodeID: [UUID: ProducedHandoff]
    let startedAt: Date
    var awaitingHumanPacketID: String?
}

private enum HumanTaskDecision: String, Codable {
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

private struct CoordinatorHandoffRequirement: Identifiable, Codable, Hashable {
    var id: String { fromNodeID.uuidString }
    let fromNodeID: UUID
    let fromNodeName: String
    let outputSchema: HandoffSchema
}

private struct ProducedHandoff: Codable {
    let schema: HandoffSchema
    let summary: String
}

private struct HumanDecisionAuditEvent: Identifiable, Codable {
    let id: String
    let runID: String
    let packetID: String
    let nodeName: String
    let decision: HumanTaskDecision
    let note: String
    let actorIdentity: String
    let decidedAt: Date
}

private struct CoordinatorExecutionStateBundle: Codable {
    let pendingExecution: PendingCoordinatorExecution?
    let latestRun: CoordinatorRun?
    let trace: [CoordinatorTraceStep]
    let humanDecisionAudit: [HumanDecisionAuditEvent]
    let humanActorIdentity: String
}

private struct HandoffValidation {
    let isValid: Bool
    let message: String
    let handoffSummaries: [String]
}

private struct CoordinatorPlan: Codable {
    let planID: String
    let coordinatorID: UUID
    let coordinatorName: String
    let coordinatorOutputSchema: HandoffSchema
    let goal: String
    let packets: [CoordinatorTaskPacket]
    let createdAt: Date
}

private struct MCPTaskRequest: Codable {
    let packetID: String
    let objective: String
    let inputSchema: HandoffSchema
    let outputSchema: HandoffSchema
    let handoffSummaries: [String]
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
        let summary = "Completed: \(normalizedObjective). Input \(request.inputSchema.rawValue) -> output \(request.outputSchema.rawValue)."
        return MCPTaskResponse(summary: summary, confidence: 0.82, completed: true)
    }
}

private struct CoordinatorOrchestrator {
    func plan(goal: String, graph: OrchestrationGraph) -> CoordinatorPlan {
        precondition(!graph.nodes.isEmpty, "Graph must contain at least one node")
        let nodeByID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        let outgoingByParentID = Dictionary(grouping: graph.edges, by: \.parentID)
        let incomingByChildID = Dictionary(grouping: graph.edges, by: \.childID)
        let childIDs = Set(graph.edges.map(\.childID))
        let rootCandidates = graph.nodes.filter { !childIDs.contains($0.id) }

        let coordinator = preferredCoordinator(from: rootCandidates, fallback: graph.nodes)
        let delegateNodes = collectDescendantNodes(
            under: coordinator.id,
            nodeByID: nodeByID,
            outgoingByParentID: outgoingByParentID
        )

        let parentTaskID = "TASK-\(UUID().uuidString.prefix(8))"
        let packets: [CoordinatorTaskPacket] = delegateNodes.enumerated().map { index, node in
            let handoffs = (incomingByChildID[node.id] ?? [])
                .compactMap { edge -> CoordinatorHandoffRequirement? in
                    guard let parent = nodeByID[edge.parentID] else { return nil }
                    return CoordinatorHandoffRequirement(
                        fromNodeID: parent.id,
                        fromNodeName: parent.name,
                        outputSchema: parent.outputSchema
                    )
                }
            return CoordinatorTaskPacket(
                id: "\(parentTaskID)-\(index + 1)",
                parentTaskID: parentTaskID,
                assignedNodeID: node.id,
                assignedNodeName: node.name,
                assignedNodeKind: node.type,
                objective: objectiveForNode(node, globalGoal: goal),
                requiredInputSchema: node.inputSchema,
                requiredOutputSchema: node.outputSchema,
                requiredHandoffs: handoffs,
                allowedPermissions: node.securityAccess.sorted()
            )
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

private enum HandoffSchema: String, CaseIterable, Identifiable, Codable {
    case goalBriefV1 = "goal_brief_v1"
    case strategyPlanV1 = "strategy_plan_v1"
    case researchBriefV1 = "research_brief_v1"
    case taskResultV1 = "task_result_v1"
    case buildPatchV1 = "build_patch_v1"
    case validationReportV1 = "validation_report_v1"
    case releaseDecisionV1 = "release_decision_v1"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .goalBriefV1:
            return "Goal Brief v1"
        case .strategyPlanV1:
            return "Strategy Plan v1"
        case .researchBriefV1:
            return "Research Brief v1"
        case .taskResultV1:
            return "Task Result v1"
        case .buildPatchV1:
            return "Build Patch v1"
        case .validationReportV1:
            return "Validation Report v1"
        case .releaseDecisionV1:
            return "Release Decision v1"
        }
    }
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
