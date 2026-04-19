import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct ContentView: View {
    private static let appDisplayName = "Agent Builder"
    private let cardSize = AppConfiguration.Canvas.cardSize
    private let minimumCanvasSize = AppConfiguration.Canvas.minimumSize
    private let minZoom: CGFloat = AppConfiguration.Canvas.minZoom
    private let maxZoom: CGFloat = AppConfiguration.Canvas.maxZoom
    private let zoomStep: CGFloat = AppConfiguration.Canvas.zoomStep
    @Environment(\.modelContext) private var modelContext
    @Environment(\.undoManager) private var undoManager
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.apiKeyStore) private var apiKeyStore
    @Environment(\.providerModelStore) private var providerModelStore
    @Environment(\.liveProviderExecutor) private var liveProviderExecutor
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var mcpManager: MCPServerManager
    @Query private var graphDocuments: [GraphDocument]
    @Query private var mcpServerConnections: [MCPServerConnection]
    @Query(sort: \UserNodeTemplate.updatedAt, order: .reverse)
    private var userNodeTemplates: [UserNodeTemplate]
    @Query(sort: \UserStructureTemplate.updatedAt, order: .reverse)
    private var userStructureTemplates: [UserStructureTemplate]
    // MARK: - ViewModels
    @State private var canvas = CanvasViewModel()
    @State private var execution = ExecutionViewModel()
    @State private var structure = StructureViewModel()
    @State private var graphPersistence: (any GraphPersistenceServicing)?
    @State private var scrollPersistTask: Task<Void, Never>?

    // MARK: - UI Chrome State
    @State private var navigation = NavigationCoordinator()
    @State private var newTaskTitle = ""
    @State private var newTaskGoal = ""
    @State private var newTaskContext = ""
    @State private var newTaskStructureStrategy = ""
    @State private var newTaskCreationOption: DraftCreationOption = .simpleTask
    @State private var newTaskCustomTemplateID: UUID?
    @State private var inspectorPanelTab: InspectorPanelTab = .nodeDetails
    @State private var isInspectorPanelVisible = true
    @State private var activeDraftInfo: DraftInfoTopic?
    @State private var templateSavedName: String?
    @State private var isShowingWipeDataConfirmation = false
    @State private var isShowingDeleteTaskConfirmation = false
    @State private var traceDisplayMode: TraceDisplayMode = .trace
    @State private var resultsDrawerOpen = false
    @State private var scrollToTraceID: String?
    @FocusState private var focusedDraftField: DraftField?

    init() {}

    private var visibleNodes: [OrgNode] { canvas.visibleNodes }
    private var canvasContentSize: CGSize { canvas.canvasContentSize }
    private var synthesisPreview: SynthesisPreviewSummary? {
        guard let snapshot = structure.synthesizedStructure else { return nil }
        return summarizeSynthesisPreview(for: snapshot)
    }
    private var pendingHumanPacket: CoordinatorTaskPacket? { execution.pendingHumanPacket }

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

    private var activeTaskTitleTextBinding: Binding<String> {
        Binding(
            get: {
                activeGraphDocument?.title ?? ""
            },
            set: { newValue in
                updateActiveTaskTitle(newValue)
            }
        )
    }

    private var normalizedTaskQuestion: String {
        execution.orchestrationGoal.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedStructureStrategy: String {
        execution.orchestrationStrategy.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var effectiveStructureStrategy: String {
        if !normalizedStructureStrategy.isEmpty {
            return normalizedStructureStrategy
        }
        return normalizedTaskQuestion
    }

    private var usesTaskSplitView: Bool {
#if targetEnvironment(macCatalyst)
        true
#else
        horizontalSizeClass == .regular
#endif
    }

    @ViewBuilder
    private var rootLayout: some View {
        if usesTaskSplitView {
            NavigationSplitView(
                columnVisibility: Binding(
                    get: { navigation.splitViewVisibility },
                    set: { navigation.splitViewVisibility = $0 }
                )
            ) {
                taskListView
                    .frame(minWidth: 360, idealWidth: 420, maxWidth: 480)
            } detail: {
                editorWorkspace
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar(.hidden, for: .navigationBar)
                    .toolbarBackground(.hidden, for: .navigationBar)
            }
            .navigationSplitViewStyle(.balanced)
        } else {
            ZStack {
                if navigation.isShowingTaskList {
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
        }
    }

    private var lifecycleModifiedLayout: some View {
        rootLayout
            .background(AppTheme.surfaceGrouped)
            .overlay(alignment: .bottom) {
                if let templateSavedName {
                    Text("Saved \"\(templateSavedName)\" as node template")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: templateSavedName)
            .animation(.easeInOut(duration: 0.18), value: canvas.selectedNodeID)
            .animation(.snappy(duration: 0.28, extraBounce: 0.02), value: navigation.isShowingTaskList)
            .onAppear {
                if graphPersistence == nil {
                    graphPersistence = SwiftDataGraphPersistenceService(modelContext: modelContext)
                }
                graphPersistence?.configure(undoManager: undoManager)
                canvas.undoManager = undoManager
                configureWindowTitleIfNeeded()
                configureViewModelCallbacks()
                ensureAnyGraphDocument()
                navigation.selectFirstTaskIfNeeded(taskKeys: taskDocuments.map(\.key))
                syncGraphFromStore()
            }
            .onChange(of: navigation.currentGraphKey) { _, _ in
                syncGraphFromStore()
            }
            .onChange(of: graphDocuments.count) { _, _ in
                let previousKey = navigation.currentGraphKey
                navigation.reconcileCurrentTaskSelection(taskKeys: taskDocuments.map(\.key))
                if navigation.currentGraphKey != previousKey {
                    syncGraphFromStore()
                }
            }
            .onChange(of: canvas.semanticFingerprint) { _, newValue in
                persistGraphIfNeeded(for: newValue)
            }
            .onChange(of: canvas.viewport.scrollOffset) { _, _ in
                scheduleScrollOffsetPersist()
            }
            .onChange(of: canvas.viewport.zoom) { _, _ in
                scheduleScrollOffsetPersist()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase != .active {
                    flushScrollOffsetPersist()
                }
            }
            .onChange(of: execution.orchestrationGoal) { _, _ in
                persistActiveTaskMetadata()
            }
            .onChange(of: execution.orchestrationStrategy) { _, _ in
                persistActiveTaskMetadata()
            }
            .onChange(of: structure.synthesisContext) { _, _ in
                persistActiveTaskMetadata()
            }
            .onChange(of: execution.humanActorIdentity) { _, _ in
                persistCoordinatorExecutionState()
            }
            .onChange(of: mcpServerConnections) { _, new in
                execution.mcpServerConnections = Array(new)
                structure.mcpServerConnections = Array(new)
            }
            .confirmationDialog("Wipe All Data?", isPresented: $isShowingWipeDataConfirmation) {
                Button("Wipe All Data", role: .destructive) {
                    wipeAllDataForTesting()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This temporary testing action will delete all tasks and execution history. API keys and provider model preferences are preserved.")
            }
            .confirmationDialog("Delete Task?", isPresented: $isShowingDeleteTaskConfirmation) {
                Button("Delete Task", role: .destructive) {
                    deleteCurrentTask()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete the selected task and its run history.")
            }
    }

    var body: some View {
        lifecycleModifiedLayout
            .sheet(isPresented: $execution.isShowingHumanInbox) {
                HumanInboxPanel(
                    pendingPacket: pendingHumanPacket,
                    actorIdentity: $execution.humanActorIdentity,
                    decisionNote: $execution.humanDecisionNote,
                    auditTrail: execution.humanDecisionAudit,
                    onApprove: { resolveHumanTask(.approve) },
                    onReject: { resolveHumanTask(.reject) },
                    onNeedsInfo: { resolveHumanTask(.needsInfo) }
                )
                .presentationDetents([.medium, .large])
            }
            .sheet(
                item: Binding(
                    get: { navigation.taskResultsTarget },
                    set: { navigation.taskResultsTarget = $0 }
                )
            ) { target in
                TaskResultsPanel(
                    document: taskDocuments.first(where: { $0.key == target.id }),
                    onClose: {
                        navigation.closeTaskResults()
                    }
                )
                .presentationDetents([.medium, .large])
            }
            .sheet(
                isPresented: Binding(
                    get: { navigation.isShowingNodeTemplateLibrary },
                    set: { navigation.isShowingNodeTemplateLibrary = $0 }
                )
            ) {
                NodeTemplateLibrarySheet(onInsert: { userTemplate in
                    navigation.isShowingNodeTemplateLibrary = false
                    canvas.addNodeFromUserTemplate(userTemplate)
                })
                .presentationDetents([.medium, .large])
            }
            .sheet(
                isPresented: Binding(
                    get: { navigation.isShowingSettingsPlaceholderSheet },
                    set: { navigation.isShowingSettingsPlaceholderSheet = $0 }
                )
            ) {
                NavigationStack {
                    VStack(spacing: 12) {
                        Image(systemName: "gearshape.2")
                            .font(.system(size: 30))
                            .foregroundStyle(.secondary)
                        Text("Settings Placeholder")
                            .font(.headline)
                        Text("Settings controls will be added here.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle("Settings")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button {
                                navigation.isShowingSettingsPlaceholderSheet = false
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .accessibilityLabel("Close Settings")
                            .help("Close Settings")
                        }
                    }
                }
                .presentationDetents([.medium])
            }
            .sheet(isPresented: Binding(
                get: { execution.runFromHereNodeID != nil },
                set: { if !$0 { execution.runFromHereNodeID = nil } }
            )) {
                if let nodeID = execution.runFromHereNodeID {
                    RunFromHereSheet(
                        nodeName: canvas.nodes.first(where: { $0.id == nodeID })?.name ?? "Node",
                        prompt: $execution.runFromHerePrompt,
                        onRun: {
                            let context = execution.runFromHerePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                            execution.runFromHereNodeID = nil
                            runCoordinatorFromNode(nodeID, additionalContext: context.isEmpty ? nil : context)
                        },
                        onCancel: {
                            execution.runFromHereNodeID = nil
                        }
                    )
                    .presentationDetents([.medium])
                }
            }
    }

    private func configureViewModelCallbacks() {
        canvas.onPersistNeeded = { [self] fingerprint in
            persistGraphIfNeeded(for: fingerprint)
        }
        execution.onPersistNeeded = { [self] in
            persistCoordinatorExecutionState()
        }
        structure.onPersistChatState = { [self] in
            persistStructureChatState()
        }
        structure.onApplySnapshot = { [self] snapshot, registerUndo in
            canvas.applyStructureSnapshot(snapshot, registerUndo: registerUndo)
        }

        let deps = AppDependencies(
            apiKeyStore: apiKeyStore,
            providerModelStore: providerModelStore,
            liveProviderExecutor: liveProviderExecutor,
            mcpManager: mcpManager
        )
        execution.dependencies = deps
        structure.dependencies = deps
        execution.mcpServerConnections = Array(mcpServerConnections)
        structure.mcpServerConnections = Array(mcpServerConnections)
    }

    private func configureWindowTitleIfNeeded() {
#if targetEnvironment(macCatalyst)
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .forEach { scene in
                scene.title = Self.appDisplayName
                scene.titlebar?.titleVisibility = .hidden
                if let restrictions = scene.sizeRestrictions {
                    let currentMinimum = restrictions.minimumSize
                    let enforcedMinimum = CGSize(
                        width: max(currentMinimum.width, 888),
                        height: max(currentMinimum.height, 620)
                    )
                    restrictions.minimumSize = enforcedMinimum
                }
            }
#endif
    }

    private var editorWorkspace: some View {
        VStack(spacing: 0) {
            header
            Divider()
            orchestrationConfigStrip
            schemaControlsBar
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    chartCanvas
                    Divider()
                    resultsDrawer
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if isInspectorPanelVisible {
                    Divider()
                    inspectorPanel
                        .frame(minWidth: 320, idealWidth: 360, maxWidth: 420)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    Divider()
                    inspectorToggleRail
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
#if targetEnvironment(macCatalyst)
            Button("") {
                canvas.deleteCurrentSelection()
            }
            .keyboardShortcut(.delete, modifiers: [])
            .opacity(0.001)
            .allowsHitTesting(false)
#else
            EmptyView()
#endif
        }
    }

    /// The trace steps to display — either the live/current trace, or a historical one.
    private var displayedTrace: [CoordinatorTraceStep] { execution.displayedTrace }
    private var displayedRun: CoordinatorRun? { execution.displayedRun }
    private var isViewingHistoricalRun: Bool { execution.isViewingHistoricalRun }

    private var resultsDrawer: some View {
        ResultsDrawerView(
            execution: execution,
            resultsDrawerOpen: $resultsDrawerOpen,
            traceDisplayMode: $traceDisplayMode,
            scrollToTraceID: $scrollToTraceID,
            pendingHumanPacket: pendingHumanPacket,
            displayedTrace: displayedTrace,
            displayedRun: displayedRun,
            isViewingHistoricalRun: isViewingHistoricalRun,
            appDisplayName: Self.appDisplayName,
            traceResolution: { traceResolution(for: $0) },
            onApplyTraceResolution: { applyTraceResolution(for: $0) },
            onRunFromHere: { nodeID in
                execution.runFromHerePrompt = ""
                execution.runFromHereNodeID = nodeID
            },
            canRunFromNode: { nodeID in canRunFromNode(nodeID) },
            onResolveHumanTask: { resolveHumanTask($0) },
            onContinueExecution: { await continueCoordinatorExecution() },
            onPersistCoordinatorExecutionState: { persistCoordinatorExecutionState() }
        )
    }

    private var schemaControlsBar: some View {
        SchemaControlsBar(
            canvas: canvas,
            viewport: canvas.viewport,
            execution: execution,
            canRunCoordinator: !execution.isExecutingCoordinator && !orchestrationGraph.nodes.isEmpty && execution.pendingCoordinatorExecution == nil,
            onRunCoordinator: { runCoordinatorPipeline() },
            onStopExecution: { stopCoordinatorExecution() }
        )
    }

    private var taskListView: some View {
        TaskListView(
            navigation: navigation,
            taskDocuments: taskDocuments,
            usesTaskSplitView: usesTaskSplitView,
            navigationTitle: Self.appDisplayName,
            newTaskTitle: $newTaskTitle,
            newTaskGoal: $newTaskGoal,
            newTaskContext: $newTaskContext,
            newTaskStructureStrategy: $newTaskStructureStrategy,
            newTaskCreationOption: $newTaskCreationOption,
            newTaskCustomTemplateID: $newTaskCustomTemplateID,
            activeDraftInfo: $activeDraftInfo,
            focusedDraftField: $focusedDraftField,
            onCreateTask: { createTaskFromDraftSelection() },
            runStatus: { runStatus(for: $0) },
            isTaskRunning: { isTaskRunningFromList($0) },
            canRunTask: { canRunTaskFromList($0) },
            pendingHumanApprovalCount: { pendingHumanApprovalCount(for: $0) },
            currentGraphKey: navigation.currentGraphKey,
            taskRunButtonIcon: { taskRunButtonIcon(for: $0) },
            taskRunButtonLabel: { taskRunButtonLabel(for: $0) },
            onOpenResults: { openTaskResults(for: $0) },
            onOpenHumanInbox: { openHumanInbox(for: $0) },
            onOpenEditor: { openTaskEditor(key: $0) },
            onRunOrContinue: { runOrContinueTask(for: $0) }
        )
    }

    private func startFreshStructureChat() {
        structure.startFreshChat()
        persistStructureChatState()
    }

    private func runStructureChatDebugBroadcast(for entry: StructureChatMessageEntry) {
        structure.runStructureChatDebugBroadcast(for: entry, currentSnapshotJSON: currentGraphSnapshotJSONString())
    }

    private func applyTemplateFromStructureChat(_ template: PresetHierarchyTemplate?, label: String) {
        structure.applyTemplateFromStructureChat(
            template,
            label: label,
            simpleTaskSnapshot: canvas.simpleTaskSnapshot()
        )
    }

    private func applyUserStructureTemplate(_ template: UserStructureTemplate) {
        guard let snapshot = try? JSONDecoder().decode(HierarchySnapshot.self, from: template.snapshotData) else { return }
        structure.applyUserStructureTemplate(snapshot: snapshot, label: template.name)
    }

    private func saveCurrentStructureAsTemplate(named name: String) {
        let snapshot = makeHierarchySnapshot(nodes: canvas.nodes, links: canvas.links)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let template = UserStructureTemplate(name: name, snapshotData: data)
        modelContext.insert(template)
        _ = saveModelContext(operation: "save structure template")
    }

    private func submitStructureChatTurn() {
        structure.submitStructureChatTurn(currentSnapshotJSON: currentGraphSnapshotJSONString())
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

    private func executionBundle(for document: GraphDocument) -> CoordinatorExecutionStateBundle? {
        guard
            let data = document.executionStateData,
            let decoded = try? JSONDecoder().decode(CoordinatorExecutionStateBundle.self, from: data)
        else {
            return nil
        }
        return decoded
    }

    private func isTaskRunningFromList(_ document: GraphDocument) -> Bool {
        execution.isExecutingCoordinator && navigation.currentGraphKey == document.key
    }

    private func canRunTaskFromList(_ document: GraphDocument) -> Bool {
        if execution.isExecutingCoordinator && navigation.currentGraphKey != document.key {
            return false
        }
        guard let bundle = executionBundle(for: document) else { return true }
        if bundle.pendingExecution?.awaitingHumanPacketID != nil {
            return false
        }
        return true
    }

    private func taskRunButtonLabel(for document: GraphDocument) -> String {
        guard let bundle = executionBundle(for: document) else { return "Run" }
        if bundle.pendingExecution?.awaitingHumanPacketID != nil {
            return "Waiting Human"
        }
        return bundle.pendingExecution == nil ? "Run" : "Continue"
    }

    private func taskRunButtonIcon(for document: GraphDocument) -> String {
        let label = taskRunButtonLabel(for: document)
        if label == "Continue" {
            return "arrow.clockwise"
        }
        if label == "Waiting Human" {
            return "pause.fill"
        }
        return "play.fill"
    }

    private func pendingHumanApprovalCount(for document: GraphDocument) -> Int {
        guard let bundle = executionBundle(for: document) else { return 0 }
        return bundle.pendingExecution?.awaitingHumanPacketID == nil ? 0 : 1
    }

    private var header: some View {
        HeaderBarView(
            execution: execution,
            viewport: canvas.viewport,
            activeTaskTitle: activeTaskTitle,
            usesTaskSplitView: usesTaskSplitView,
            splitViewVisibility: navigation.splitViewVisibility,
            pendingHumanPacket: pendingHumanPacket,
            canDeleteTask: activeGraphDocument != nil,
            canCopyDebugPayload: !canvas.nodes.isEmpty,
            canUndo: undoManager?.canUndo ?? false,
            canRedo: undoManager?.canRedo ?? false,
            debugClipboardText: { debugClipboardText },
            onShowTaskList: {
                withAnimation(.snappy(duration: 0.28, extraBounce: 0.02)) {
                    navigation.showTaskList()
                }
            },
            onShowAllColumns: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    navigation.showAllColumns()
                }
            },
            onOpenHumanInbox: { execution.isShowingHumanInbox = true },
            onCopyDebug: { copyTextToClipboard(debugClipboardText) },
            onRequestDeleteTask: { isShowingDeleteTaskConfirmation = true },
            onUndo: { canvas.undo(syncGraphFromStore: syncGraphFromStore) },
            onRedo: { canvas.redo(syncGraphFromStore: syncGraphFromStore) }
        )
    }

    private var orchestrationConfigStrip: some View {
        OrchestrationConfigStripView(
            execution: execution,
            structure: structure,
            activeTaskTitleText: activeTaskTitleTextBinding,
            orphanCount: orphanNodeIDsInCurrentGraph.count,
            synthesisPreview: synthesisPreview,
            onApplySynthesizedStructure: { applySynthesizedStructure() },
            onDiscardSynthesizedStructure: { discardSynthesizedStructure() }
        )
    }

    private var inspectorPanel: some View {
        InspectorPanelView(
            canvas: canvas,
            structure: structure,
            inspectorPanelTab: $inspectorPanelTab,
            isInspectorPanelVisible: $isInspectorPanelVisible,
            inspectorNodeBinding: inspectorNodeBinding,
            availableProviders: { availableGenerateProviders() },
            providerIcon: { providerIcon(for: $0) },
            onPersistStructureChatState: { persistStructureChatState() },
            onSaveNodeAsTemplate: { node in saveNodeAsTemplate(node) },
            onDeleteSelectedNode: { canvas.deleteSelectedNode() },
            onApplyTemplateFromStructureChat: { template, label in
                applyTemplateFromStructureChat(template, label: label)
            },
            onApplyUserStructureTemplate: { template in
                applyUserStructureTemplate(template)
            },
            onSaveCurrentAsStructureTemplate: { name in
                saveCurrentStructureAsTemplate(named: name)
            },
            onStartFreshStructureChat: { startFreshStructureChat() },
            onSubmitStructureChatTurn: { submitStructureChatTurn() },
            onRunStructureChatDebugBroadcast: { entry in
                runStructureChatDebugBroadcast(for: entry)
            }
        )
    }

    private var inspectorToggleRail: some View {
        InspectorToggleRail(isInspectorPanelVisible: $isInspectorPanelVisible)
    }

    private var chartCanvas: some View {
        ChartCanvasView(
            canvas: canvas,
            execution: execution,
            navigation: navigation,
            visibleNodes: visibleNodes,
            canvasContentSize: canvasContentSize,
            cardSize: cardSize,
            orphanNodeIDs: orphanNodeIDsInCurrentGraph,
            linkDraft: linkDraft,
            userNodeTemplates: Array(userNodeTemplates),
            onNodeTap: { node in handleNodeTap(node) }
        )
    }

    private var inspectorNodeBinding: Binding<OrgNode>? {
        guard let selectedNodeID = canvas.selectedNodeID else { return nil }
        return Binding(
            get: {
                canvas.nodes.first(where: { $0.id == selectedNodeID }) ?? OrgNode.placeholder(id: selectedNodeID)
            },
            set: { updatedNode in
                guard let index = canvas.nodes.firstIndex(where: { $0.id == selectedNodeID }) else { return }
                canvas.nodes[index] = updatedNode
            }
        )
    }

    private var linkDraft: LinkDraft? {
        guard let sourceID = canvas.linkingFromNodeID, let pointer = canvas.linkingPointer else { return nil }
        return LinkDraft(
            sourceID: sourceID,
            currentPoint: pointer,
            hoveredTargetID: canvas.linkHoverTargetNodeID
        )
    }

    private var orphanNodeIDsInCurrentGraph: Set<UUID> { canvas.orphanNodeIDs }
    private var runnableNodeIDsInCurrentGraph: Set<UUID> {
        CanvasLayoutEngine.computeRunnableNodeIDs(nodes: canvas.nodes, links: canvas.links)
    }
    private var orchestrationGraph: OrchestrationGraph { canvas.orchestrationGraph }

    private func runCoordinatorPipeline() {
        runCoordinatorPipelineWithFeedback(nil)
    }

    private func stopCoordinatorExecution() {
        execution.stopExecution()
    }

    /// A node can be "run from here" only if data is available to feed it:
    /// every executing parent (agent/human) must have succeeded. Non-executing parents
    /// (Input / Output / system) are treated as always-ready since they don't produce runtime output.
    /// Nodes with no executing parents are always runnable (they're effectively roots).
    private func canRunFromNode(_ nodeID: UUID) -> Bool {
        let parentIDs = canvas.links.filter { $0.toID == nodeID }.map(\.fromID)
        let executingParentIDs = parentIDs.filter { parentID in
            guard let parent = canvas.nodes.first(where: { $0.id == parentID }) else { return false }
            return parent.type == .agent || parent.type == .human
        }
        if executingParentIDs.isEmpty {
            return true
        }
        return executingParentIDs.allSatisfy { execution.executionState(for: $0) == .succeeded }
    }

    private func runCoordinatorFromNode(_ nodeID: UUID, additionalContext: String? = nil) {
        withAnimation(.snappy(duration: 0.3)) { resultsDrawerOpen = true }
        execution.runFromNode(nodeID, additionalContext: additionalContext, nodes: canvas.nodes)
    }

    private func continueCoordinatorExecution() async {
        await execution.continueExecution(nodes: canvas.nodes)
    }

    private func runCoordinatorPipelineWithFeedback(_ feedback: String?) {
        withAnimation(.snappy(duration: 0.3)) { resultsDrawerOpen = true }
        execution.runPipelineWithFeedback(feedback, orchestrationGraph: orchestrationGraph, nodes: canvas.nodes)
    }

    @MainActor
    private func resolveHumanTask(_ decision: HumanTaskDecision) {
        execution.resolveHumanTask(decision, nodes: canvas.nodes)
    }

    private func simulatePacketExecution(
        _ packet: CoordinatorTaskPacket,
        handoffSummaries: [String]
    ) async -> MCPTaskResponse {
        await execution.simulatePacketExecution(packet, handoffSummaries: handoffSummaries)
    }

    private func validateRequiredHandoffs(
        for packet: CoordinatorTaskPacket,
        outputsByNodeID: [UUID: ProducedHandoff],
        goal: String
    ) -> HandoffValidation {
        execution.validateRequiredHandoffs(for: packet, outputsByNodeID: outputsByNodeID, goal: goal)
    }

    private func inferredMissingPermission(from summary: String?) -> SecurityAccess? {
        execution.inferredMissingPermission(from: summary)
    }

    private func traceResolution(for step: CoordinatorTraceStep) -> TraceResolutionRecommendation? {
        execution.traceResolution(for: step, nodes: canvas.nodes)
    }

    private func applyTraceResolution(for step: CoordinatorTraceStep) {
        guard let resolution = traceResolution(for: step) else { return }
        switch resolution.action {
        case .grantPermission(let nodeID, let permission):
            canvas.performSemanticMutation {
                guard let index = canvas.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
                canvas.nodes[index].securityAccess.insert(permission)
                canvas.selectedNodeID = canvas.nodes[index].id
                canvas.selectedLinkID = nil
            }
        }
    }

    private func generateSuggestedStructure() {
        structure.generateSuggestedStructure(
            taskQuestion: normalizedTaskQuestion,
            structureStrategy: effectiveStructureStrategy
        )
    }

    private func availableGenerateProviders() -> [APIKeyProvider] {
        APIKeyProvider.allCases.filter { provider in
            switch loadAPIKey(for: provider) {
            case .success:
                return true
            case .failure:
                return false
            }
        }
    }

    private func loadAPIKey(for provider: APIKeyProvider) -> Result<String, WorkflowError> {
        do {
            let key = (try apiKeyStore.key(for: provider) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                return .failure(.missingAPIKey(provider: provider))
            }
            return .success(key)
        } catch {
            return .failure(.apiKeyReadFailed(provider: provider, underlying: error))
        }
    }

    private func providerIcon(for provider: APIKeyProvider) -> String {
        switch provider {
        case .chatGPT: return "brain.head.profile"
        case .gemini:  return "diamond"
        case .claude:  return "text.bubble"
        case .grok:    return "bolt"
        }
    }

    @MainActor
    private func generateStructureWithLLM(provider: APIKeyProvider) async {
        await structure.generateStructureWithLLM(
            provider: provider,
            taskQuestion: normalizedTaskQuestion,
            structureStrategy: effectiveStructureStrategy
        )
    }

    private func currentGraphSnapshotJSONString() -> String {
        let snapshot = canvas.captureStructureSnapshot()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot), let text = String(data: data, encoding: .utf8) else {
            return "{\"nodes\":[],\"links\":[]}"
        }
        return text
    }

    private func applySynthesizedStructure() {
        guard let synthesizedStructure = structure.synthesizedStructure else { return }
        canvas.applyStructureSnapshot(synthesizedStructure)
        structure.synthesizedStructure = nil
        structure.synthesisStatusMessage = "Applied suggested structure."
    }

    private func discardSynthesizedStructure() {
        structure.synthesizedStructure = nil
        structure.synthesisStatusMessage = "Suggestion discarded."
    }

    private func summarizeSynthesisPreview(for snapshot: HierarchySnapshot) -> SynthesisPreviewSummary {
        structure.summarizeSynthesisPreview(for: snapshot, currentNodes: canvas.nodes)
    }

    private func handleNodeTap(_ node: OrgNode) {
        if let sourceID = canvas.linkingFromNodeID {
            guard sourceID != node.id else {
                canvas.clearLinkDragState()
                canvas.selectedNodeID = node.id
                return
            }
            canvas.completeLinkSelection(sourceID: sourceID, targetID: node.id)
            return
        }

        canvas.selectNode(node)

        // If there's a trace step for this node, open the drawer and scroll to it
        if let traceStep = execution.coordinatorTrace.first(where: { $0.assignedNodeID == node.id }) {
            if !resultsDrawerOpen {
                withAnimation(.snappy(duration: 0.3)) {
                    resultsDrawerOpen = true
                }
            }
            Task {
                try? await Task.sleep(
                    for: resultsDrawerOpen
                        ? AppConfiguration.Timing.scrollDelayWhenDrawerOpen
                        : AppConfiguration.Timing.scrollDelayWhenDrawerClosed
                )
                scrollToTraceID = traceStep.id
            }
        }
    }

    // MARK: - Node Template Persistence
    private func saveNodeAsTemplate(_ node: OrgNode) {
        let template = UserNodeTemplate(
            label: node.name,
            icon: "star",
            name: node.name,
            title: node.title,
            department: node.department,
            nodeTypeRaw: node.type.rawValue,
            providerRaw: node.provider.rawValue,
            roleDescription: node.roleDescription,
            outputSchema: node.outputSchema,
            outputSchemaDescription: node.outputSchemaDescription,
            securityAccessRaw: node.securityAccess.map(\.rawValue),
            assignedToolsRaw: node.assignedTools.sorted()
        )
        graphPersistence?.insertTemplate(template)
        templateSavedName = node.name
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if templateSavedName == node.name {
                templateSavedName = nil
            }
        }
    }


    private var activeGraphDocument: GraphDocument? {
        if let currentGraphKey = navigation.currentGraphKey,
           let exact = graphDocuments.first(where: { $0.key == currentGraphKey }) {
            return exact
        }
        return taskDocuments.first
    }

    private func reportNonFatalWorkflowError(_ error: WorkflowError) {
        print("[WorkflowError] \(error.debugMessage)")
    }

    @discardableResult
    private func saveModelContext(operation: String) -> Bool {
        guard let graphPersistence else {
            reportNonFatalWorkflowError(
                .persistenceFailed(
                    operation: operation,
                    underlying: NSError(
                        domain: "GraphPersistenceService",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Persistence service is unavailable."]
                    )
                )
            )
            return false
        }

        switch graphPersistence.save(operation: operation) {
        case .success:
            return true
        case .failure(let error):
            reportNonFatalWorkflowError(error)
            return false
        }
    }

    private func encodeData<T: Encodable>(_ value: T, operation: String) -> Data? {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            reportNonFatalWorkflowError(
                .encodingFailed(operation: operation, underlying: error)
            )
            return nil
        }
    }

    private func ensureAnyGraphDocument() {
        if !graphDocuments.isEmpty { return }
        guard let data = encodeData(canvas.simpleTaskSnapshot(), operation: "create default task snapshot") else {
            return
        }

        let document = GraphDocument(
            title: "New Coordinator Task",
            goal: execution.orchestrationGoal,
            structureStrategy: execution.orchestrationStrategy,
            snapshotData: data,
            executionStateData: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        graphPersistence?.insertGraphDocument(document)
        _ = saveModelContext(operation: "create default task")
        navigation.currentGraphKey = document.key
    }

    private func createTaskFromDraftSelection() {
        if let customID = newTaskCustomTemplateID,
           let template = userStructureTemplates.first(where: { $0.id == customID }) {
            createTaskFromUserStructureTemplate(template)
            return
        }
        switch newTaskCreationOption {
        case .generateStructure:
            createGeneratedTaskFromDraft()
        case .simpleTask:
            createSimpleTask()
        case .baselineTeam, .researchDelivery, .incidentResponse:
            guard let template = newTaskCreationOption.template else { return }
            createTaskFromTemplate(template)
        }
    }

    private func createTaskFromUserStructureTemplate(_ template: UserStructureTemplate) {
        guard let snapshot = try? JSONDecoder().decode(HierarchySnapshot.self, from: template.snapshotData) else { return }
        let title = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let goal = newTaskGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        createTaskDocument(
            title: title.isEmpty ? template.name : title,
            goal: goal.isEmpty ? execution.orchestrationGoal : goal,
            structureStrategy: execution.orchestrationStrategy,
            snapshot: snapshot
        )
        resetTaskDraft()
    }

    private func resetTaskDraft() {
        newTaskTitle = ""
        newTaskGoal = ""
        newTaskContext = ""
        newTaskStructureStrategy = ""
        newTaskCreationOption = .simpleTask
        newTaskCustomTemplateID = nil
    }

    private func openTaskEditor(key: String) {
        navigation.currentGraphKey = key
        execution.isShowingHumanInbox = false
        if !usesTaskSplitView {
            withAnimation(.snappy(duration: 0.28, extraBounce: 0.02)) {
                navigation.showEditor()
            }
        }
        syncGraphFromStore()
    }

    private func openHumanInbox(for key: String) {
        navigation.currentGraphKey = key
        syncGraphFromStore()
        execution.isShowingHumanInbox = true
    }

    private func createSimpleTask() {
        let draftTitle = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let draftGoal = newTaskGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = draftTitle.isEmpty
            ? "Task \(Date().formatted(.dateTime.month().day().hour().minute()))"
            : draftTitle
        let goal = draftGoal.isEmpty ? execution.orchestrationGoal : draftGoal
        createTaskDocument(
            title: title,
            goal: goal,
            structureStrategy: execution.orchestrationStrategy,
            snapshot: canvas.simpleTaskSnapshot()
        )
        resetTaskDraft()
    }

    private func createGeneratedTaskFromDraft() {
        let rawGoal = newTaskGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawContext = newTaskContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = rawContext.isEmpty ? structure.synthesisContext : rawContext
        let title = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawStrategy = newTaskStructureStrategy.trimmingCharacters(in: .whitespacesAndNewlines)
        let strategy = rawStrategy.isEmpty ? execution.orchestrationStrategy : rawStrategy
        let goal = rawGoal.isEmpty ? execution.orchestrationGoal : rawGoal

        let synthesisContextValue: String
        if strategy.isEmpty {
            synthesisContextValue = context
        } else if context.isEmpty {
            synthesisContextValue = "Structure strategy: \(strategy)"
        } else {
            synthesisContextValue = "\(context)\n\nStructure strategy: \(strategy)"
        }

        let synthesizer = TeamStructureSynthesizer()
        let snapshot = synthesizer.synthesize(
            goal: goal.isEmpty ? "Execute coordinator objective" : goal,
            context: synthesisContextValue,
            answers: [:]
        )
        createTaskDocument(
            title: title.isEmpty ? "Generated Task" : title,
            goal: goal,
            structureStrategy: strategy,
            snapshot: snapshot
        )
        resetTaskDraft()
    }

    private func createTaskFromTemplate(_ template: PresetHierarchyTemplate) {
        let title = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let goal = newTaskGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        createTaskDocument(
            title: title.isEmpty ? template.title : title,
            goal: goal.isEmpty ? execution.orchestrationGoal : goal,
            structureStrategy: execution.orchestrationStrategy,
            snapshot: template.snapshot()
        )
        resetTaskDraft()
    }

    private func openTaskResults(for key: String) {
        navigation.openTaskResults(for: key)
    }

    private func runOrContinueTask(for key: String) {
        if execution.isExecutingCoordinator {
            return
        }

        navigation.currentGraphKey = key
        syncGraphFromStore()
        withAnimation(.snappy(duration: 0.2)) {
            resultsDrawerOpen = true
        }

        if let pending = execution.pendingCoordinatorExecution {
            if pending.awaitingHumanPacketID != nil {
                execution.isShowingHumanInbox = true
                return
            }
            execution.isExecutingCoordinator = true
            execution.executionTask = Task {
                await continueCoordinatorExecution()
            }
            return
        }

        runCoordinatorPipeline()
    }

    private func createTaskDocument(
        title: String,
        goal: String,
        structureStrategy: String? = nil,
        snapshot: HierarchySnapshot
    ) {
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
        let anchored = CanvasLayoutEngine.normalizeAnchorNodes(inputNodes: restoredNodes, inputLinks: restoredLinks)
        let normalizedSnapshot = makeHierarchySnapshot(nodes: anchored.nodes, links: anchored.links)

        guard let data = encodeData(normalizedSnapshot, operation: "create task document snapshot") else { return }

        let document = GraphDocument(
            title: title,
            goal: goal,
            structureStrategy: (structureStrategy ?? goal).trimmingCharacters(in: .whitespacesAndNewlines),
            snapshotData: data,
            executionStateData: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        graphPersistence?.insertGraphDocument(document)
        _ = saveModelContext(operation: "create task document")

        navigation.currentGraphKey = document.key
        if !usesTaskSplitView {
            withAnimation(.snappy(duration: 0.28, extraBounce: 0.02)) {
                navigation.showEditor()
            }
        }
        syncGraphFromStore()
    }

    private func deleteCurrentTask() {
        guard let document = activeGraphDocument else { return }
        let fallbackKey = taskDocuments.first(where: { $0.key != document.key })?.key

        graphPersistence?.deleteGraphDocument(document)
        _ = saveModelContext(operation: "delete task")

        navigation.currentGraphKey = fallbackKey
        canvas.selectedNodeID = nil
        canvas.selectedLinkID = nil
        canvas.clearLinkDragState()

        if navigation.currentGraphKey == nil {
            ensureAnyGraphDocument()
            if navigation.currentGraphKey == nil {
                navigation.currentGraphKey = taskDocuments.first?.key
            }
        }
        syncGraphFromStore()
    }

    private func wipeAllDataForTesting() {
        // Clear persisted graph documents.
        graphPersistence?.deleteGraphDocuments(graphDocuments)
        _ = saveModelContext(operation: "wipe all graph documents")

        // Reset editor/list state so UI reflects an empty project immediately.
        navigation.currentGraphKey = nil
        canvas.nodes = []
        canvas.links = []
        canvas.selectedNodeID = nil
        canvas.selectedLinkID = nil
        canvas.linkingFromNodeID = nil
        canvas.linkingPointer = nil
        canvas.linkHoverTargetNodeID = nil
        canvas.viewport.searchText = ""
        canvas.viewport.zoom = 1.0
        execution.latestCoordinatorPlan = nil
        execution.latestCoordinatorRun = nil
        execution.pendingCoordinatorExecution = nil
        execution.lastCompletedExecution = nil
        execution.coordinatorTrace = []
        execution.coordinatorRunHistory = []
        execution.selectedHistoryRunID = nil
        execution.humanDecisionAudit = []
        execution.humanDecisionNote = ""
        execution.isShowingHumanInbox = false
        navigation.closeTaskResults()
        execution.isExecutingCoordinator = false
        execution.orchestrationStrategy = ExecutionViewModel.defaultOrchestrationStrategy
        structure.synthesisContext = ""
        structure.synthesisQuestions = []
        structure.synthesizedStructure = nil
        structure.synthesisStatusMessage = nil
        resetTaskDraft()
        if !usesTaskSplitView {
            navigation.showTaskList()
        }
    }


    private func persistActiveTaskMetadata() {
        guard let document = activeGraphDocument else { return }
        let normalizedQuestion = execution.orchestrationGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedStrategy = execution.orchestrationStrategy.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedContext = structure.synthesisContext
        var changed = false

        if (document.goal ?? "") != normalizedQuestion {
            document.goal = normalizedQuestion
            changed = true
        }
        if (document.structureStrategy ?? "") != normalizedStrategy {
            document.structureStrategy = normalizedStrategy
            changed = true
        }
        if (document.context ?? "") != normalizedContext {
            document.context = normalizedContext
            changed = true
        }

        if changed {
            document.updatedAt = Date()
            _ = saveModelContext(operation: "persist task metadata")
        }
    }

    private func updateActiveTaskTitle(_ title: String) {
        ensureAnyGraphDocument()
        guard let document = activeGraphDocument else { return }
        guard (document.title ?? "") != title else { return }
        document.title = title
        document.updatedAt = Date()
        _ = saveModelContext(operation: "update task title")
    }

    private var debugClipboardText: String {
        let activeDocument = activeGraphDocument
        let formatter = ISO8601DateFormatter()
        let generatedAt = formatter.string(from: Date())
        let nodeByID = Dictionary(uniqueKeysWithValues: canvas.nodes.map { ($0.id, $0) })
        let outgoingByNodeID = Dictionary(grouping: canvas.links, by: \.fromID)
        let incomingByNodeID = Dictionary(grouping: canvas.links, by: \.toID)
        let selectedNodeSummary = canvas.selectedNodeID
            .flatMap { id in canvas.nodes.first(where: { $0.id == id }) }
            .map { "\(debugInlineText($0.name, fallback: "Unnamed")) (\($0.id.uuidString))" }
            ?? "none"

        var lines: [String] = [
            "\(Self.appDisplayName) Debug Context",
            "Generated At: \(generatedAt)",
            "",
            "Task",
            "- Key: \(activeDocument?.key ?? "none")",
            "- Title: \(activeTaskTitle)",
            "- Task Question: \(debugInlineText(execution.orchestrationGoal, fallback: "No question set"))",
            "- Structure Strategy: \(debugInlineText(execution.orchestrationStrategy, fallback: "No strategy set"))",
            "- Context: \(debugInlineText(structure.synthesisContext, fallback: "No extra context"))",
            "- Execution Mode: Live API",
            "- Is Executing: \(execution.isExecutingCoordinator ? "yes" : "no")",
            "- Selected Node: \(selectedNodeSummary)"
        ]

        if let latestCoordinatorPlan = execution.latestCoordinatorPlan {
            lines.append("- Latest Plan: \(latestCoordinatorPlan.planID), \(latestCoordinatorPlan.packets.count) packets")
        } else {
            lines.append("- Latest Plan: none")
        }

        if let pendingCoordinatorExecution = execution.pendingCoordinatorExecution {
            let nextPacketNumber = min(pendingCoordinatorExecution.nextPacketIndex + 1, pendingCoordinatorExecution.plan.packets.count)
            let waitState = pendingCoordinatorExecution.awaitingHumanPacketID == nil ? "no" : "yes"
            lines.append("- Pending Run: \(pendingCoordinatorExecution.runID), next packet \(nextPacketNumber)/\(pendingCoordinatorExecution.plan.packets.count), awaiting human \(waitState)")
        } else {
            lines.append("- Pending Run: none")
        }

        if let latestCoordinatorRun = execution.latestCoordinatorRun {
            lines.append("- Latest Run: \(latestCoordinatorRun.runID), succeeded \(latestCoordinatorRun.succeededCount)/\(latestCoordinatorRun.results.count)")
        } else {
            lines.append("- Latest Run: none")
        }

        lines.append("")
        lines.append("Nodes (\(canvas.nodes.count))")

        let sortedNodes = canvas.nodes.sorted { lhs, rhs in
            if lhs.position.y != rhs.position.y { return lhs.position.y < rhs.position.y }
            if lhs.position.x != rhs.position.x { return lhs.position.x < rhs.position.x }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        for (index, node) in sortedNodes.enumerated() {
            let roleList = node.selectedRoles
                .map(\.label)
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            let permissionList = node.securityAccess
                .map(\.label)
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

            let parentNames = (incomingByNodeID[node.id] ?? []).compactMap { edge in
                nodeByID[edge.fromID].map { debugInlineText($0.name, fallback: edge.fromID.uuidString) }
            }
            let childNames = (outgoingByNodeID[node.id] ?? []).compactMap { edge in
                nodeByID[edge.toID].map { debugInlineText($0.name, fallback: edge.toID.uuidString) }
            }

            lines.append("\(index + 1). \(debugInlineText(node.name, fallback: "Unnamed")) [\(node.type.label)]")
            lines.append("   ID: \(node.id.uuidString)")
            lines.append("   Title: \(debugInlineText(node.title, fallback: "n/a"))")
            lines.append("   Department: \(debugInlineText(node.department, fallback: "n/a"))")
            lines.append("   Provider: \(node.provider.label)")
            lines.append("   Roles: \(roleList.isEmpty ? "none" : roleList.joined(separator: ", "))")
            lines.append("   Permissions: \(permissionList.isEmpty ? "none" : permissionList.joined(separator: ", "))")
            lines.append("   Schemas: \(debugInlineText(node.inputSchema, fallback: "n/a")) -> \(debugInlineText(node.outputSchema, fallback: "n/a"))")
            lines.append("   Role Description: \(debugInlineText(node.roleDescription, fallback: "n/a"))")
            lines.append("   Output Description: \(debugInlineText(node.outputSchemaDescription, fallback: "n/a"))")
            lines.append("   Parents: \(parentNames.isEmpty ? "none" : parentNames.joined(separator: ", "))")
            lines.append("   Children: \(childNames.isEmpty ? "none" : childNames.joined(separator: ", "))")
            lines.append("   Position: x=\(Int(node.position.x.rounded())), y=\(Int(node.position.y.rounded()))")
            lines.append("")
        }

        lines.append("Links (\(canvas.links.count))")
        for (index, link) in canvas.links.enumerated() {
            let fromName = debugInlineText(nodeByID[link.fromID]?.name ?? link.fromID.uuidString, fallback: link.fromID.uuidString)
            let toName = debugInlineText(nodeByID[link.toID]?.name ?? link.toID.uuidString, fallback: link.toID.uuidString)
            lines.append("\(index + 1). \(fromName) -> \(toName) [tone: \(link.tone.rawValue), type: \(link.edgeType.rawValue)]")
        }

        return lines.joined(separator: "\n")
    }

    private func debugInlineText(_ text: String, fallback: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? fallback : collapsed
    }

    private func syncGraphFromStore() {
        let doc = activeGraphDocument
        canvas.load(from: doc)
        execution.load(from: doc)
        structure.load(from: doc, defaultProvider: availableGenerateProviders().first ?? .chatGPT)
    }

    private func persistGraphIfNeeded(for newFingerprint: String) {
        guard let document = activeGraphDocument else { return }
        canvas.persistIfNeeded(for: newFingerprint, to: document) {
            _ = saveModelContext(operation: "persist graph snapshot")
        }
    }

    /// Write scroll offset to the document immediately (SwiftData in-memory update is cheap)
    /// and debounce the explicit save() call. Ensures we never lose the last position even
    /// if the app is backgrounded before a debounce completes.
    private func scheduleScrollOffsetPersist() {
        guard let document = activeGraphDocument else { return }
        // Update the SwiftData object in-memory right now — this survives background
        // autosave even if our debounced save task is cancelled by app termination.
        document.scrollOffsetX = Double(canvas.viewport.scrollOffset.x)
        document.scrollOffsetY = Double(canvas.viewport.scrollOffset.y)
        document.zoom = Double(canvas.viewport.zoom)

        scrollPersistTask?.cancel()
        scrollPersistTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000) // 0.2s idle
            guard !Task.isCancelled else { return }
            _ = saveModelContext(operation: "persist canvas viewport")
        }
    }

    /// Synchronously flush any pending viewport save. Called on scenePhase changes
    /// so position/zoom survive backgrounding / termination even mid-debounce.
    private func flushScrollOffsetPersist() {
        scrollPersistTask?.cancel()
        scrollPersistTask = nil
        guard let document = activeGraphDocument else { return }
        document.scrollOffsetX = Double(canvas.viewport.scrollOffset.x)
        document.scrollOffsetY = Double(canvas.viewport.scrollOffset.y)
        document.zoom = Double(canvas.viewport.zoom)
        _ = saveModelContext(operation: "flush canvas viewport")
    }

    private func persistCoordinatorExecutionState() {
        ensureAnyGraphDocument()
        guard let document = activeGraphDocument else { return }
        execution.persist(to: document) {
            _ = saveModelContext(operation: "persist coordinator execution state")
        }
    }

    private func persistStructureChatState() {
        ensureAnyGraphDocument()
        guard let document = activeGraphDocument else { return }
        structure.persist(to: document) {
            _ = saveModelContext(operation: "persist structure chat state")
        }
    }

}

#Preview {
    ContentView()
        .environmentObject(MCPServerManager.shared)
}
