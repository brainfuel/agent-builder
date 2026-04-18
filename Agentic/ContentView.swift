import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

private extension View {
    @ViewBuilder
    func catalystTooltip(_ text: String) -> some View {
#if targetEnvironment(macCatalyst)
        self.help(text)
#else
        self
#endif
    }
}

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
    @EnvironmentObject private var mcpManager: MCPServerManager
    @Query private var graphDocuments: [GraphDocument]
    @Query private var mcpServerConnections: [MCPServerConnection]
    @Query(sort: \UserNodeTemplate.updatedAt, order: .reverse)
    private var userNodeTemplates: [UserNodeTemplate]
    // MARK: - ViewModels
    @State private var canvas = CanvasViewModel()
    @State private var execution = ExecutionViewModel()
    @State private var structure = StructureViewModel()
    @State private var graphPersistence: (any GraphPersistenceServicing)?

    // MARK: - UI Chrome State
    @State private var navigation = NavigationCoordinator()
    @State private var newTaskTitle = ""
    @State private var newTaskGoal = ""
    @State private var newTaskContext = ""
    @State private var newTaskStructureStrategy = ""
    @State private var newTaskCreationOption: DraftCreationOption = .simpleTask
    @State private var inspectorPanelTab: InspectorPanelTab = .nodeDetails
    @State private var isInspectorPanelVisible = true
    @State private var activeDraftInfo: DraftInfoTopic?
    @State private var templateSavedName: String?
    @State private var isShowingWipeDataConfirmation = false
    @State private var isShowingDeleteTaskConfirmation = false
    private enum TraceDisplayMode: String, CaseIterable {
        case trace = "Trace"
        case rawAPI = "Raw API"
    }
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

    private enum DraftField: Hashable {
        case title
        case goal
        case context
        case structureStrategy
    }

    private enum DraftCreationOption: String, CaseIterable, Hashable, Identifiable {
        case generateStructure
        case simpleTask
        case baselineTeam
        case researchDelivery
        case incidentResponse

        var id: String { rawValue }

        var title: String {
            switch self {
            case .generateStructure: return "Generate Structure"
            case .simpleTask: return "Simple Task"
            case .baselineTeam: return "Baseline Team"
            case .researchDelivery: return "Research + Delivery"
            case .incidentResponse: return "Incident Response"
            }
        }

        var usesStructureStrategyField: Bool {
            self == .generateStructure
        }

        var template: PresetHierarchyTemplate? {
            switch self {
            case .baselineTeam: return .baseline
            case .researchDelivery: return .researchOps
            case .incidentResponse: return .incidentResponse
            default: return nil
            }
        }
    }

    private enum DraftInfoTopic: String, Hashable {
        case title
        case question
        case context
        case structureStrategy
        case creationMode

        var title: String {
            switch self {
            case .title: return "Task Title"
            case .question: return "Question"
            case .context: return "Context"
            case .structureStrategy: return "Structure Strategy"
            case .creationMode: return "Creation Mode"
            }
        }

        var message: String {
            switch self {
            case .title:
                return "Give the task a short, searchable name so you can identify it later."
            case .question:
                return "Describe what you want the agents to answer or produce."
            case .context:
                return "Add relevant background, constraints, canvas.links, or assumptions."
            case .structureStrategy:
                return "Describe how generated teams should approach planning, execution, and decision making."
            case .creationMode:
                return "Choose whether to generate a new team structure, start from a simple task, or use a preset team."
            }
        }
    }

    private enum InspectorPanelTab: String, CaseIterable, Identifiable {
        case nodeDetails = "Node Details"
        case structureChat = "Structure Chat"

        var id: String { rawValue }
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
            .onChange(of: execution.orchestrationGoal) { _, _ in
                persistActiveTaskMetadata()
            }
            .onChange(of: execution.orchestrationStrategy) { _, _ in
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
                    },
                    onRetryWithFeedback: execution.isExecutingCoordinator
                        ? nil
                        : { feedback in
                            navigation.closeTaskResults()
                            retryPipelineWithFeedback(feedback, from: nil)
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
            }
#endif
    }

    private var editorWorkspace: some View {
        VStack(spacing: 0) {
            header
            Divider()
            orchestrationConfigStrip
            Divider()
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
        VStack(spacing: 0) {
            // Header row with inline history picker
#if targetEnvironment(macCatalyst)
            HStack(spacing: 8) {
                Button {
                    withAnimation(.snappy(duration: 0.3)) { resultsDrawerOpen.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "text.line.last.and.arrowtriangle.forward")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.brandTint)

                        Text("Run Trace")
                            .font(.subheadline.weight(.semibold))

                        if !displayedTrace.isEmpty {
                            Text("\(displayedTrace.count)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(AppTheme.brandTint, in: Capsule())
                        }
                    }
                }
                .buttonStyle(.plain)
                .catalystTooltip(resultsDrawerOpen ? "Collapse Run Trace" : "Expand Run Trace")

                if execution.coordinatorRunHistory.count > 1 {
                    runHistoryPicker
                }

                if resultsDrawerOpen, !displayedTrace.isEmpty {
                    Picker("Display", selection: $traceDisplayMode) {
                        ForEach(TraceDisplayMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }

                Spacer()

                Button {
                    withAnimation(.snappy(duration: 0.3)) { resultsDrawerOpen.toggle() }
                } label: {
                    Image(systemName: "rectangle.bottomthird.inset.filled")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.brandTint)
                }
                .buttonStyle(.plain)
                .catalystTooltip(resultsDrawerOpen ? "Collapse Run Trace" : "Expand Run Trace")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
#else
            VStack(spacing: 6) {
                Capsule()
                    .fill(Color(uiColor: .tertiaryLabel))
                    .frame(width: 36, height: 5)
                    .padding(.top, 8)

                HStack(spacing: 8) {
                    Button {
                        withAnimation(.snappy(duration: 0.3)) { resultsDrawerOpen.toggle() }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "text.line.last.and.arrowtriangle.forward")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AppTheme.brandTint)

                            Text("Run Trace")
                                .font(.subheadline.weight(.semibold))

                            if !displayedTrace.isEmpty {
                                Text("\(displayedTrace.count)")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(AppTheme.brandTint, in: Capsule())
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .catalystTooltip(resultsDrawerOpen ? "Collapse Run Trace" : "Expand Run Trace")

                    if execution.coordinatorRunHistory.count > 1 {
                        runHistoryPicker
                    }

                    if resultsDrawerOpen, !displayedTrace.isEmpty {
                        Picker("Display", selection: $traceDisplayMode) {
                            ForEach(TraceDisplayMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 160)
                    }

                    Spacer()

                    Button {
                        withAnimation(.snappy(duration: 0.3)) { resultsDrawerOpen.toggle() }
                    } label: {
                        Image(systemName: "rectangle.bottomthird.inset.filled")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.brandTint)
                    }
                    .buttonStyle(.plain)
                    .catalystTooltip(resultsDrawerOpen ? "Collapse Run Trace" : "Expand Run Trace")
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }
#endif

            if resultsDrawerOpen {
                Divider()
                resultsDrawerContent
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: resultsDrawerOpen ? 16 : 12, style: .continuous))
        .frame(maxHeight: resultsDrawerOpen ? UIScreen.main.bounds.height * 0.45 : nil)
        .animation(.snappy(duration: 0.3), value: resultsDrawerOpen)
    }

    private var runHistoryPicker: some View {
        Menu {
            // Current / latest run option
            Button {
                withAnimation(.snappy(duration: 0.2)) { execution.selectedHistoryRunID = nil }
            } label: {
                HStack {
                    Text("Latest Run")
                    if execution.selectedHistoryRunID == nil {
                        Image(systemName: "checkmark")
                    }
                }
            }

            Divider()

            // Historical runs (newest first)
            ForEach(execution.coordinatorRunHistory.reversed()) { entry in
                Button {
                    withAnimation(.snappy(duration: 0.2)) { execution.selectedHistoryRunID = entry.run.runID }
                } label: {
                    HStack {
                        let allSucceeded = entry.run.succeededCount == entry.run.results.count
                        Image(systemName: allSucceeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        Text(runHistoryLabel(for: entry))
                        if execution.selectedHistoryRunID == entry.run.runID {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10, weight: .semibold))
                Text(execution.selectedHistoryRunID == nil ? "Latest" : runHistoryPickerTitle)
                    .font(.caption.weight(.medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(isViewingHistoricalRun ? AppTheme.brandTint : .secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isViewingHistoricalRun ? AppTheme.brandTint.opacity(0.12) : Color(uiColor: .tertiarySystemFill))
            )
        }
    }

    private func runHistoryLabel(for entry: CoordinatorRunHistoryEntry) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        let succeeded = entry.run.succeededCount
        let total = entry.run.results.count
        return "\(formatter.string(from: entry.run.finishedAt)) — \(succeeded)/\(total) succeeded"
    }

    private var runHistoryPickerTitle: String {
        guard let selectedHistoryRunID = execution.selectedHistoryRunID,
              let entry = execution.coordinatorRunHistory.first(where: { $0.run.runID == selectedHistoryRunID }) else {
            return "Latest Run"
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return "Run at \(formatter.string(from: entry.run.finishedAt))"
    }

    private func exportCurrentResults() {
        switch traceDisplayMode {
        case .trace:
            exportTraceResults()
        case .rawAPI:
            exportRawAPIResults()
        }
    }

    private func exportTraceResults() {
        let md = execution.exportTraceMarkdown(appDisplayName: Self.appDisplayName)
        guard !md.isEmpty else { return }
        presentExportText(md)
    }

    private func exportRawAPIResults() {
        let md = execution.exportRawAPIMarkdown(appDisplayName: Self.appDisplayName)
        guard !md.isEmpty else { return }
        presentExportText(md)
    }

    private func presentExportText(_ text: String) {
        #if targetEnvironment(macCatalyst)
        let activityVC = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            var topVC = rootVC
            while let presented = topVC.presentedViewController { topVC = presented }
            activityVC.popoverPresentationController?.sourceView = topVC.view
            activityVC.popoverPresentationController?.sourceRect = CGRect(
                x: topVC.view.bounds.midX, y: topVC.view.bounds.midY, width: 0, height: 0
            )
            activityVC.popoverPresentationController?.permittedArrowDirections = []
            topVC.present(activityVC, animated: true)
        }
        #else
        UIPasteboard.general.string = text
        #endif
    }

    private var resultsDrawerContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Run config summary
                    if let latestCoordinatorPlan = execution.latestCoordinatorPlan {
                        Label(
                            "Planned \(latestCoordinatorPlan.packets.count) task packets from \(latestCoordinatorPlan.coordinatorName).",
                            systemImage: "doc.plaintext"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    if let run = displayedRun {
                        HStack(spacing: 12) {
                            Label(
                                "\(isViewingHistoricalRun ? "Run" : "Last run"): \(run.succeededCount)/\(run.results.count) tasks succeeded.",
                                systemImage: run.succeededCount == run.results.count
                                    ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                            )
                            .font(.caption.weight(.medium))
                            .foregroundStyle(
                                run.succeededCount == run.results.count
                                    ? .green : .orange
                            )

                            let totalIn = displayedTrace.compactMap(\.inputTokens).reduce(0, +)
                            let totalOut = displayedTrace.compactMap(\.outputTokens).reduce(0, +)
                            if totalIn + totalOut > 0 {
                                Label(
                                    "\(CoordinatorTraceStep.formatTokens(totalIn + totalOut)) tokens",
                                    systemImage: "circle.grid.3x3.fill"
                                )
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }

                    // Resume / Human inbox — only for current run, not historical
                    if !isViewingHistoricalRun {
                        if let pendingCoordinatorExecution = execution.pendingCoordinatorExecution,
                            pendingCoordinatorExecution.awaitingHumanPacketID == nil,
                            !execution.isExecutingCoordinator
                        {
                            Button("Resume Pending Run") {
                                execution.isExecutingCoordinator = true
                                execution.executionTask = Task { await continueCoordinatorExecution() }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }

                        if let pendingHumanPacket {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Human Decision Required", systemImage: "person.badge.clock")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.orange)

                                Text("\(pendingHumanPacket.assignedNodeName): \(pendingHumanPacket.objective)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)

                                HStack(spacing: 8) {
                                    Button("Approve") { resolveHumanTask(.approve) }
                                        .buttonStyle(.borderedProminent)
                                    Button("Reject") { resolveHumanTask(.reject) }
                                        .buttonStyle(.bordered)
                                    Button("Inbox") { execution.isShowingHumanInbox = true }
                                        .buttonStyle(.bordered)
                                }
                                .controlSize(.small)
                            }
                            .padding(10)
                            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }

                    // Trace list header
                    HStack {
                        Text(traceDisplayMode == .trace ? "Trace" : "Raw API")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !displayedTrace.isEmpty {
                            Button {
                                exportCurrentResults()
                            } label: {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(traceDisplayMode == .trace ? "Export Trace" : "Export Raw API")
                            .catalystTooltip(traceDisplayMode == .trace ? "Export Trace" : "Export Raw API")
                        }
                        if !isViewingHistoricalRun, !execution.coordinatorTrace.isEmpty {
                            Button("Clear") {
                                execution.coordinatorTrace = []
                                persistCoordinatorExecutionState()
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .disabled(execution.isExecutingCoordinator)
                            .catalystTooltip("Clear current run trace")
                        }
                    }

                    let traceToShow = displayedTrace
                    if traceToShow.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.title3)
                                .foregroundStyle(.tertiary)
                            Text("No results yet. Run the coordinator to generate trace.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    } else if traceDisplayMode == .trace {
                        LazyVStack(spacing: 8) {
                            ForEach(Array(traceToShow.enumerated()), id: \.element.id) { index, step in
                                let resolution = isViewingHistoricalRun ? nil : traceResolution(for: step)
                                let isHighlighted = scrollToTraceID == step.id
                                CoordinatorTraceRow(
                                    stepNumber: index + 1,
                                    step: step,
                                    resolution: resolution.map { $0.presentation },
                                    onResolve: resolution == nil
                                        ? nil
                                        : { applyTraceResolution(for: step) },
                                    onRetryWithFeedback: isViewingHistoricalRun || execution.isExecutingCoordinator
                                        ? nil
                                        : { feedback in retryPipelineWithFeedback(feedback, from: step) }
                                )
                                .id(step.id)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(AppTheme.brandTint, lineWidth: isHighlighted ? 2 : 0)
                                )
                                .animation(.easeInOut(duration: 0.3), value: isHighlighted)
                            }
                        }
                    } else {
                        LazyVStack(spacing: 8) {
                            ForEach(Array(traceToShow.enumerated()), id: \.element.id) { index, step in
                                RawAPITraceRow(stepNumber: index + 1, step: step)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .onChange(of: scrollToTraceID) { _, newID in
                guard let newID else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
                // Clear highlight after a brief moment
                Task {
                    try? await Task.sleep(for: AppConfiguration.Timing.copyIndicatorResetDelay)
                    if scrollToTraceID == newID {
                        withAnimation { scrollToTraceID = nil }
                    }
                }
            }
        }
    }

    private var schemaControlsBar: some View {
        let headerControlHeight: CGFloat = 42
        let canUndo = undoManager?.canUndo ?? false
        let canRedo = undoManager?.canRedo ?? false

        return HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search node", text: $canvas.searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 14)
            .frame(width: 300, height: headerControlHeight)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppTheme.surfaceSecondary)
            )

            Spacer(minLength: 0)

            Button {
                canvas.undo(syncGraphFromStore: syncGraphFromStore)
            } label: {
                headerControlLabel(
                    title: "Undo",
                    systemImage: "arrow.uturn.backward",
                    height: headerControlHeight,
                    prominent: false,
                    enabled: canUndo
                )
            }
            .buttonStyle(.plain)
            .disabled(!canUndo)
            .keyboardShortcut("z", modifiers: [.command])
            .catalystTooltip("Undo")

            Button {
                canvas.redo(syncGraphFromStore: syncGraphFromStore)
            } label: {
                headerControlLabel(
                    title: "Redo",
                    systemImage: "arrow.uturn.forward",
                    height: headerControlHeight,
                    prominent: false,
                    enabled: canRedo
                )
            }
            .buttonStyle(.plain)
            .disabled(!canRedo)
            .keyboardShortcut("Z", modifiers: [.command, .shift])
            .catalystTooltip("Redo")

        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(AppTheme.surfacePrimary)
    }

    private var taskListView: some View {
        VStack(spacing: 0) {
            // Tab picker
            Picker(
                "Sidebar",
                selection: Binding(
                    get: { navigation.sidebarTab },
                    set: { navigation.sidebarTab = $0 }
                )
            ) {
                ForEach(SidebarTab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.icon).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            switch navigation.sidebarTab {
            case .tasks:
                sidebarTasksContent
            case .tools:
                ToolCatalogSheet(embedded: true)
            case .settings:
                sidebarSettingsContent
            }
        }
        .navigationTitle(usesTaskSplitView ? Self.appDisplayName : "")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var sidebarTasksContent: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("New Task Draft")
                    .font(.headline)
                Text("Set title, question, context, and creation mode, then create.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                draftTextField("Task title", text: $newTaskTitle, field: .title, infoTopic: .title)
                draftTextField("Question", text: $newTaskGoal, field: .goal, infoTopic: .question)
                draftTextField("Context", text: $newTaskContext, field: .context, infoTopic: .context)
                if newTaskCreationOption.usesStructureStrategyField {
                    draftTextField(
                        "Structure strategy",
                        text: $newTaskStructureStrategy,
                        field: .structureStrategy,
                        infoTopic: .structureStrategy
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                HStack(spacing: 10) {
                    Menu {
                        draftCreationOptionMenuItem(.generateStructure)
                        Divider()
                        draftCreationOptionMenuItem(.simpleTask)
                        draftCreationOptionMenuItem(.baselineTeam)
                        draftCreationOptionMenuItem(.researchDelivery)
                        draftCreationOptionMenuItem(.incidentResponse)
                    } label: {
                        HStack(spacing: 6) {
                            Text(newTaskCreationOption.title)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }

                    draftInfoButton(topic: .creationMode)

                    Spacer()

                    Button {
                        createTaskFromDraftSelection()
                    } label: {
                        Label("Create", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(AppTheme.surfacePrimary)
            .animation(.easeInOut(duration: 0.2), value: newTaskCreationOption.usesStructureStrategyField)

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

    private var sidebarSettingsContent: some View {
        APIKeysSheet(embedded: true)
    }

    private func taskRow(_ document: GraphDocument) -> some View {
        let status = runStatus(for: document)
        let viewModel = TaskCardViewModel(document: document, status: status)
        let selectedKey = navigation.currentGraphKey ?? taskDocuments.first?.key
        let isSelectedTask = document.key == selectedKey
        let isRunning = isTaskRunningFromList(document)
        let canRun = canRunTaskFromList(document)
        let inboxBadgeCount = pendingHumanApprovalCount(for: document)
        return VStack(alignment: .leading, spacing: 10) {
            Text(viewModel.titleText)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)

            HStack(spacing: 10) {
                Text(viewModel.goalText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                Text(status.label)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(viewModel.statusColor.opacity(0.18))
                    )
                    .foregroundStyle(viewModel.statusColor)
                    .fixedSize(horizontal: true, vertical: false)
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Updated")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(viewModel.updatedText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if runStatus(for: document) == .completed {
                    Button {
                        openTaskResults(for: document.key)
                    } label: {
                        Image(systemName: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("View Results")
                    .catalystTooltip("View Results")
                }

                Button {
                    openHumanInbox(for: document.key)
                } label: {
                    HumanInboxButtonLabel(pendingCount: inboxBadgeCount, showsTitle: false)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Human Inbox")
                .catalystTooltip("Open Human Inbox")

                Button {
                    openTaskEditor(key: document.key)
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Edit Task")
                .catalystTooltip("Edit Task")

                Button {
                    runOrContinueTask(for: document.key)
                } label: {
                    if isRunning {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: taskRunButtonIcon(for: document))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canRun)
                .accessibilityLabel(taskRunButtonLabel(for: document))
                .catalystTooltip(taskRunButtonLabel(for: document))
            }
        }
        .padding(16)
        .contentShape(Rectangle())
        .onTapGesture {
            openTaskEditor(key: document.key)
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    isSelectedTask
                        ? AppTheme.brandTint.opacity(0.12)
                        : AppTheme.surfaceSecondary
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    isSelectedTask
                        ? AppTheme.brandTint.opacity(0.45)
                        : Color.black.opacity(0.06),
                    lineWidth: isSelectedTask ? 1.5 : 1
                )
        )
    }

    private func draftTextField(
        _ placeholder: String,
        text: Binding<String>,
        field: DraftField,
        infoTopic: DraftInfoTopic
    ) -> some View {
        let isFocused = focusedDraftField == field
        return HStack(spacing: 8) {
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .focused($focusedDraftField, equals: field)
            draftInfoButton(topic: infoTopic)
        }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppTheme.surfacePrimary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        isFocused ? AppTheme.brandTint.opacity(0.9) : Color.black.opacity(0.12),
                        lineWidth: isFocused ? 2 : 1
                    )
            )
    }

    private func draftInfoButton(topic: DraftInfoTopic) -> some View {
        Button {
            activeDraftInfo = topic
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .popover(
            isPresented: Binding(
                get: { activeDraftInfo == topic },
                set: { isPresented in
                    if !isPresented, activeDraftInfo == topic {
                        activeDraftInfo = nil
                    }
                }
            ),
            attachmentAnchor: .point(.trailing),
            arrowEdge: .trailing
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text(topic.title)
                    .font(.headline)
                Text(topic.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(width: 280, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func draftCreationOptionMenuItem(_ option: DraftCreationOption) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                newTaskCreationOption = option
            }
        } label: {
            if newTaskCreationOption == option {
                Label(option.title, systemImage: "checkmark")
            } else {
                Text(option.title)
            }
        }
    }

    private func structureChatMessageRow(_ entry: StructureChatMessageEntry) -> some View {
        let isUser = entry.role == .user
        let debugJSON = entry.role == .assistant ? structureDebugJSONIfPresent(in: entry.text) : nil
        let isDebugRunning = structure.structureChatDebugRunningMessageIDs.contains(entry.id)
        let isDebugCompleted = structure.structureChatDebugCompletedMessageIDs.contains(entry.id)
        return HStack {
            if isUser { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(entry.role == .user ? "You" : "Structure Copilot")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if isUser {
                        Button {
                            runStructureChatDebugBroadcast(for: entry)
                        } label: {
                            Group {
                                if isDebugRunning {
                                    ProgressView()
                                        .controlSize(.mini)
                                } else if isDebugCompleted {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.green)
                                } else {
                                    Image(systemName: "ladybug")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 16, height: 16)
                        }
                        .buttonStyle(.plain)
                        .disabled(structure.isStructureChatRunning || isDebugRunning)
                        .help("Debug all providers and copy prompts/responses")
                    }
                    if let debugJSON {
                        Button {
                            copyTextToClipboard(debugJSON)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Copy JSON")
                    }
                    if !isUser, let rawResponse = entry.rawResponse, !rawResponse.isEmpty {
                        Button {
                            copyTextToClipboard(rawResponse)
                        } label: {
                            Image(systemName: "doc.on.clipboard")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Copy raw LLM response")
                    }
                }
                if debugJSON != nil {
                    Text("Custom structure applied")
                        .font(.subheadline.weight(.semibold))
                } else {
                    SelectableText(
                        markdown: entry.text,
                        font: .preferredFont(forTextStyle: .subheadline)
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if entry.appliedStructureUpdate {
                    Label("Applied to canvas", systemImage: "checkmark.circle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isUser ? AppTheme.brandTint.opacity(0.12) : AppTheme.surfacePrimary)
            )
            if !isUser { Spacer(minLength: 40) }
        }
    }

    private func structureDebugJSONIfPresent(in text: String) -> String? {
        let cleaned = StructureResponseParserService.stripCodeFences(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.first == "{", cleaned.last == "}" else { return nil }
        guard let data = cleaned.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let looksLikeStructurePayload =
            object["mode"] != nil ||
            object["structure"] != nil ||
            object["canvas.nodes"] != nil ||
            object["canvas.links"] != nil ||
            object["edges"] != nil
        return looksLikeStructurePayload ? cleaned : nil
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
        let headerControlHeight: CGFloat = 42
        let canDeleteTask = activeGraphDocument != nil
        let canRunCoordinator = !execution.isExecutingCoordinator && !orchestrationGraph.nodes.isEmpty && execution.pendingCoordinatorExecution == nil
        let canCopyDebugPayload = !canvas.nodes.isEmpty

        return VStack(spacing: 12) {
            HStack(spacing: 12) {
                if !usesTaskSplitView {
                    Button {
                        withAnimation(.snappy(duration: 0.28, extraBounce: 0.02)) {
                            navigation.showTaskList()
                        }
                    } label: {
                        headerControlLabel(
                            title: "Tasks",
                            systemImage: "chevron.left",
                            height: headerControlHeight,
                            prominent: false,
                            enabled: true
                        )
                    }
                    .buttonStyle(.plain)
                    .catalystTooltip("Show Tasks")
                } else if navigation.splitViewVisibility == .detailOnly {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            navigation.showAllColumns()
                        }
                    } label: {
                        Image(systemName: "sidebar.leading")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 38, height: 38)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Color(uiColor: .tertiarySystemFill))
                            )
                    }
                .buttonStyle(.plain)
                .catalystTooltip("Show Task List")
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(activeTaskTitle)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("Visual agent workflow builder")
                        .foregroundStyle(.secondary)
                }
                Spacer()

                
                
               
                
                Button {
                    execution.isShowingHumanInbox = true
                } label: {
                    headerControlLabel(
                        title: "Human Inbox",
                        systemImage: "tray.full",
                        height: headerControlHeight,
                        prominent: false,
                        enabled: true
                    )
                    .overlay(alignment: .topTrailing) {
                        let pendingCount = pendingHumanPacket == nil ? 0 : 1
                        if pendingCount > 0 {
                            InboxAttentionBadge(count: pendingCount)
                                .offset(x: 6, y: -6)
                        }
                    }
                }
                .buttonStyle(.plain)
                .catalystTooltip("Open Human Inbox")

                Button {
                    copyTextToClipboard(debugClipboardText)
                } label: {
                    headerControlLabel(
                        title: "Copy Debug",
                        systemImage: "ladybug",
                        height: headerControlHeight,
                        prominent: false,
                        enabled: canCopyDebugPayload
                    )
                }
                .buttonStyle(.plain)
                .disabled(!canCopyDebugPayload)
                .catalystTooltip("Copy Debug Context")

                Button(role: .destructive) {
                    isShowingDeleteTaskConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .font(.headline)
                        .frame(width: headerControlHeight, height: headerControlHeight)
                        .foregroundStyle(
                            headerControlForeground(
                                prominent: false,
                                enabled: canDeleteTask,
                                destructive: true
                            )
                        )
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(
                                    headerControlBackground(
                                        prominent: false,
                                        enabled: canDeleteTask
                                    )
                                )
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete Task")
                .disabled(!canDeleteTask)
                .catalystTooltip("Delete Task")


                if execution.isExecutingCoordinator {
                    Button {
                        stopCoordinatorExecution()
                    } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.red)
                                .frame(width: 16, height: 16)
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        }
                        .frame(height: headerControlHeight)
                        .padding(.horizontal, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.red.opacity(0.15))
                        )
                    }
                    .buttonStyle(.plain)
                    .catalystTooltip("Stop Execution")
                } else {
                    Button {
                        runCoordinatorPipeline()
                    } label: {
                        headerControlLabel(
                            title: "Run",
                            systemImage: "play.fill",
                            height: headerControlHeight,
                            prominent: true,
                            enabled: canRunCoordinator
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canRunCoordinator)
                    .catalystTooltip("Run Task")
                }

                
            }
            .padding(.horizontal, 24)

            if execution.isExecutingCoordinator, !execution.liveStatusMessage.isEmpty {
                HStack(spacing: 10) {
                    Circle()
                        .fill(AppTheme.brandTint)
                        .frame(width: 8, height: 8)
                        .opacity(execution.liveStatusBannerPulse ? 0.55 : 1)

                    Text(execution.liveStatusMessage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.brandTint.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    ProgressView()
                        .controlSize(.small)
                        .tint(AppTheme.brandTint.opacity(0.9))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AppTheme.brandTint.opacity(execution.liveStatusBannerPulse ? 0.08 : 0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(AppTheme.brandTint.opacity(execution.liveStatusBannerPulse ? 0.25 : 0.12), lineWidth: 1)
                )
                .padding(.horizontal, 24)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onAppear {
                    execution.liveStatusBannerPulse = false
                    withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                        execution.liveStatusBannerPulse = true
                    }
                }
                .onDisappear {
                    execution.liveStatusBannerPulse = false
                }
            }
        }
        .padding(.top, usesTaskSplitView ? 0 : 18)
        .padding(.bottom, 14)
        .background(AppTheme.surfacePrimary)
        .animation(.easeInOut(duration: 0.2), value: execution.liveStatusMessage)
        .animation(.easeInOut(duration: 0.2), value: execution.isExecutingCoordinator)
    }

    private func headerControlLabel(
        title: String,
        systemImage: String,
        height: CGFloat,
        prominent: Bool,
        enabled: Bool,
        destructive: Bool = false
    ) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .lineLimit(1)
            .padding(.horizontal, 16)
            .frame(height: height)
            .foregroundStyle(headerControlForeground(prominent: prominent, enabled: enabled, destructive: destructive))
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(headerControlBackground(prominent: prominent, enabled: enabled))
            )
    }

    private func headerControlForeground(prominent: Bool, enabled: Bool, destructive: Bool) -> Color {
        if !enabled {
            return Color(uiColor: .tertiaryLabel)
        }
        if prominent {
            return .white
        }
        if destructive {
            return .red
        }
        return AppTheme.brandTint
    }

    private func headerControlBackground(prominent: Bool, enabled: Bool) -> Color {
        if prominent {
            return enabled ? AppTheme.brandTint : AppTheme.brandTint.opacity(0.45)
        }
        return enabled
            ? AppTheme.surfaceSecondary
            : Color(uiColor: .tertiarySystemFill)
    }

    private var orchestrationConfigStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "textformat")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                TextField("Task title", text: activeTaskTitleTextBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .lineLimit(1)

                Image(systemName: "text.bubble")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                TextField("What should the team answer?", text: $execution.orchestrationGoal)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .lineLimit(1)

                Image(systemName: "doc.text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                TextField("Context (optional)", text: $structure.synthesisContext)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .lineLimit(1)
            }

            let orphanCount = orphanNodeIDsInCurrentGraph.count
            if orphanCount > 0 {
                Text(
                    "\(orphanCount) orphan \(orphanCount == 1 ? "node" : "canvas.nodes") disconnected — excluded from runs."
                )
                .font(.caption2)
                .foregroundStyle(.orange)
            }

            if !structure.synthesisQuestions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Discovery Questions")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach($structure.synthesisQuestions) { $question in
                        HStack(spacing: 6) {
                            Text(question.key.prompt)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            TextField("Answer", text: $question.answer)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption2)
                        }
                    }
                }
            }

            if let synthesisPreview {
                HStack(spacing: 8) {
                    Text(
                        "Suggested: \(synthesisPreview.suggestedNodeCount) canvas.nodes (\(synthesisPreview.nodeDeltaString)), \(synthesisPreview.suggestedLinkCount) canvas.links (\(synthesisPreview.linkDeltaString))"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                    Button {
                        applySynthesizedStructure()
                    } label: {
                        Label("Apply", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)

                    Button("Discard", role: .destructive) {
                        discardSynthesizedStructure()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }

            if let synthesisStatusMessage = structure.synthesisStatusMessage {
                Text(synthesisStatusMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let generateStructureError = structure.generateStructureError {
                Text(generateStructureError)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(AppTheme.surfaceSecondary)
    }

    private var inspectorPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Inspector Tab", selection: $inspectorPanelTab) {
                    ForEach(InspectorPanelTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isInspectorPanelVisible = false
                    }
                } label: {
                    Image(systemName: "sidebar.trailing")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(uiColor: .tertiarySystemFill))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hide Inspector")
                .help("Hide Inspector")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            switch inspectorPanelTab {
            case .nodeDetails:
                nodeDetailsInspectorContent
            case .structureChat:
                structureChatInspectorContent
            }
        }
        .background(AppTheme.surfaceSecondary)
    }

    private var inspectorToggleRail: some View {
        VStack {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isInspectorPanelVisible = true
                }
            } label: {
                Image(systemName: "sidebar.trailing")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color(uiColor: .tertiarySystemFill))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show Inspector")
            .help("Show Inspector")

            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.top, 10)
        .frame(width: 44)
        .background(AppTheme.surfaceSecondary)
    }

    private var nodeDetailsInspectorContent: some View {
        ScrollView {
            if let inspectorNodeBinding {
                if inspectorNodeBinding.wrappedValue.type == .input || inspectorNodeBinding.wrappedValue.type == .output {
                    FixedNodeInspector(node: inspectorNodeBinding)
                        .padding(20)
                } else {
                    NodeInspector(
                        node: inspectorNodeBinding,
                        onDelete: { canvas.deleteSelectedNode() },
                        onSaveAsTemplate: { saveNodeAsTemplate(inspectorNodeBinding.wrappedValue) },
                        headerTitle: "Node Details"
                    )
                        .padding(20)
                }
            } else {
                ContentUnavailableView(
                    "No Node Selected",
                    systemImage: "cursorarrow.click",
                    description: Text("Select a node to edit schema and details.")
                )
                    .padding(20)
            }
        }
    }

    private var structureChatInspectorContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(availableGenerateProviders(), id: \.self) { provider in
                        Button {
                            structure.structureChatProvider = provider
                            persistStructureChatState()
                        } label: {
                            if structure.structureChatProvider == provider {
                                Label(provider.label, systemImage: "checkmark")
                            } else {
                                Text(provider.label)
                            }
                        }
                    }
                } label: {
                    Label("Model: \(structure.structureChatProvider.label)", systemImage: providerIcon(for: structure.structureChatProvider))
                }
                .buttonStyle(.bordered)

                Menu {
                    Button("Simple Task") {
                        applyTemplateFromStructureChat(nil, label: "Simple Task")
                    }
                    ForEach(PresetHierarchyTemplate.allCases) { template in
                        Button(template.title) {
                            applyTemplateFromStructureChat(template, label: template.title)
                        }
                    }
                } label: {
                    Label("Templates", systemImage: "square.grid.2x2")
                }
                .buttonStyle(.bordered)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            HStack {
                Spacer()
                Button("Clear", role: .destructive) {
                    startFreshStructureChat()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .font(.caption.weight(.semibold))
                .disabled(structure.isStructureChatRunning || structure.structureChatMessages.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(uiColor: .tertiarySystemFill))

            Divider()

            ScrollView {
                if structure.structureChatMessages.isEmpty {
                    ContentUnavailableView(
                        "No Structure Chat Yet",
                        systemImage: "text.bubble",
                        description: Text("Describe the team structure you want, then iterate with follow-up messages.")
                    )
                    .padding(20)
                } else {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(structure.structureChatMessages) { entry in
                            structureChatMessageRow(entry)
                        }
                    }
                    .padding(12)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                if let structureChatStatusMessage = structure.structureChatStatusMessage {
                    Text(structureChatStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Ask for structure changes…", text: $structure.structureChatInput, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                        .disabled(structure.isStructureChatRunning)

                    Button {
                        submitStructureChatTurn()
                    } label: {
                        if structure.isStructureChatRunning {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 32, height: 32)
                        } else {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title3)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(structure.isStructureChatRunning || structure.structureChatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(12)
        }
    }

    private var chartCanvas: some View {
        let canvasSize = canvasContentSize
        let selectedNodeControlOffset: CGFloat = 19
        let visibleIDs = Set(visibleNodes.map(\.id))
        let orphanIDs = orphanNodeIDsInCurrentGraph
        let visibleLinks = canvas.links.filter { link in
            visibleIDs.contains(link.fromID) && visibleIDs.contains(link.toID)
        }

        return ZStack(alignment: .bottomTrailing) {
            ScrollViewReader { scrollProxy in
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    DotGridBackground()
                        .frame(width: canvasSize.width, height: canvasSize.height)

                    ConnectionLayer(
                        nodes: visibleNodes,
                        links: visibleLinks,
                        cardSize: cardSize,
                        selectedLinkID: canvas.selectedLinkID,
                        draft: linkDraft
                    )
                    .frame(width: canvasSize.width, height: canvasSize.height)

                    ForEach(visibleNodes) { node in
                        NodeCard(
                            node: node,
                            isSelected: node.id == canvas.selectedNodeID,
                            isLinkTargeted: node.id == canvas.linkHoverTargetNodeID,
                            isOrphan: orphanIDs.contains(node.id),
                            executionState: execution.executionState(for: node.id)
                        )
                            .frame(width: cardSize.width, height: cardSize.height)
                            .id(node.id)
                            .position(node.position)
                            .animation(
                                canvas.suppressLayoutAnimation
                                    ? nil
                                    : .spring(
                                        response: AppConfiguration.Motion.layoutSpringResponse,
                                        dampingFraction: AppConfiguration.Motion.layoutSpringDamping
                                    ),
                                value: node.position.x
                            )
                            .animation(
                                canvas.suppressLayoutAnimation
                                    ? nil
                                    : .spring(
                                        response: AppConfiguration.Motion.layoutSpringResponse,
                                        dampingFraction: AppConfiguration.Motion.layoutSpringDamping
                                    ),
                                value: node.position.y
                            )
                            .onTapGesture {
                                handleNodeTap(node)
                            }
                    }

                    if let selectedNodeID = canvas.selectedNodeID,
                        let selectedNode = visibleNodes.first(where: { $0.id == selectedNodeID }),
                        selectedNode.type != .input,
                        selectedNode.type != .output
                    {
                        HStack(spacing: 8) {
                            LinkHandle(isActive: canvas.linkingFromNodeID == selectedNodeID)
                                .onTapGesture {
                                        canvas.toggleLinkStart(for: selectedNodeID)
                                }
                                .gesture(
                                    DragGesture(minimumDistance: 4, coordinateSpace: .named("chart-canvas"))
                                        .onChanged { value in
                                            canvas.updateLinkDrag(
                                                sourceID: selectedNodeID,
                                                pointer: value.location,
                                                candidateNodes: visibleNodes
                                            )
                                        }
                                        .onEnded { _ in
                                            canvas.completeLinkDrag(candidateNodes: visibleNodes)
                                        }
                                )

                            Menu {
                                if !userNodeTemplates.isEmpty {
                                    Section("My Node Templates") {
                                        ForEach(userNodeTemplates) { userTemplate in
                                            Button {
                                                canvas.addNodeFromUserTemplate(userTemplate, forcedParentID: canvas.selectedNodeID)
                                            } label: {
                                                Label(userTemplate.label, systemImage: userTemplate.icon)
                                            }
                                        }
                                    }
                                }
                                Section("Built-in") {
                                    ForEach(NodeTemplate.allCases) { template in
                                        Button {
                                            canvas.addNode(template: template, forcedParentID: canvas.selectedNodeID)
                                        } label: {
                                            Label(template.label, systemImage: template.icon)
                                        }
                                    }
                                }
                                Section {
                                    Button {
                                        navigation.isShowingNodeTemplateLibrary = true
                                    } label: {
                                        Label("Edit Node Templates…", systemImage: "rectangle.stack.badge.person.crop")
                                    }
                                }
                            } label: {
                                AddChildHandle()
                            }
                            .menuStyle(.borderlessButton)
                        }
                        .position(
                            x: selectedNode.position.x,
                            y: selectedNode.position.y + (cardSize.height / 2) + selectedNodeControlOffset
                        )
                    }

                    // "Run from here" button on completed/failed nodes that are selected.
                    if let selID = canvas.selectedNodeID,
                       let selNode = visibleNodes.first(where: { $0.id == selID }),
                       selNode.type == .agent || selNode.type == .human,
                       !execution.isExecutingCoordinator,
                       execution.pendingCoordinatorExecution != nil || execution.lastCompletedExecution != nil
                    {
                        let nodeExecState = execution.executionState(for: selID)
                        if nodeExecState == .succeeded || nodeExecState == .failed {
                            Button {
                                execution.runFromHerePrompt = ""
                                execution.runFromHereNodeID = selID
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 11, weight: .bold))
                                    Text("Run from here")
                                        .font(.caption.weight(.semibold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule()
                                        .fill(Color.green)
                                )
                                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                            }
                            .buttonStyle(.plain)
                            .position(
                                x: selNode.position.x,
                                y: selNode.position.y - (cardSize.height / 2) - selectedNodeControlOffset
                            )
                        }
                    }
                }
                .coordinateSpace(name: "chart-canvas")
                .simultaneousGesture(
                    SpatialTapGesture(coordinateSpace: .named("chart-canvas"))
                        .onEnded { value in
                            canvas.handleCanvasTap(
                                at: value.location,
                                visibleNodes: visibleNodes,
                                visibleLinks: visibleLinks
                            )
                        }
                )
                .padding(24)
                .scaleEffect(canvas.zoom, anchor: .topLeading)
                .frame(
                    width: (canvasSize.width + 48) * canvas.zoom,
                    height: (canvasSize.height + 48) * canvas.zoom,
                    alignment: .topLeading
                )
            }
            .background(AppTheme.canvasBackground)
            .onAppear { canvas.canvasScrollProxy = scrollProxy }
            }

            zoomControls
                .padding(20)
        }
    }

    private var zoomControls: some View {
        let zoomControlHeight: CGFloat = 46
        return HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    canvas.adjustZoom(stepDelta: -1)
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .catalystTooltip("Zoom Out")
                Text("\(Int((canvas.zoom * 100).rounded()))%")
                    .frame(minWidth: 52)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                Button {
                    canvas.adjustZoom(stepDelta: 1)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .catalystTooltip("Zoom In")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.10), radius: 7, y: 2)
            .frame(height: zoomControlHeight)

            Button {
                canvas.zoom = 1.0
                if let inputNode = canvas.nodes.first(where: { $0.type == .input }) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        canvas.canvasScrollProxy?.scrollTo(inputNode.id, anchor: .top)
                    }
                }
            } label: {
                Image(systemName: "location.north.line.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: zoomControlHeight, height: zoomControlHeight)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(AppTheme.brandTint)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Center View")
            .catalystTooltip("Center View")
        }
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
        CanvasViewModel.computeRunnableNodeIDs(nodes: canvas.nodes, links: canvas.links)
    }
    private var orchestrationGraph: OrchestrationGraph { canvas.orchestrationGraph }

    private func runCoordinatorPipeline() {
        runCoordinatorPipelineWithFeedback(nil)
    }

    private func stopCoordinatorExecution() {
        execution.stopExecution()
    }

    private func runCoordinatorFromNode(_ nodeID: UUID, additionalContext: String? = nil) {
        withAnimation(.snappy(duration: 0.3)) { resultsDrawerOpen = true }
        execution.runFromNode(nodeID, additionalContext: additionalContext, nodes: canvas.nodes)
    }

    private func continueCoordinatorExecution() async {
        await execution.continueExecution(nodes: canvas.nodes)
    }

    private func retryPipelineWithFeedback(_ feedback: String, from step: CoordinatorTraceStep?) {
        withAnimation(.snappy(duration: 0.3)) { resultsDrawerOpen = true }
        execution.retryPipelineWithFeedback(feedback, from: step, orchestrationGraph: orchestrationGraph, nodes: canvas.nodes)
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

    private func resetTaskDraft() {
        newTaskTitle = ""
        newTaskGoal = ""
        newTaskContext = ""
        newTaskStructureStrategy = ""
        newTaskCreationOption = .simpleTask
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
                inputSchema: entry.inputSchema ?? CanvasViewModel.defaultInputSchema(for: entry.type),
                outputSchema: entry.outputSchema ?? CanvasViewModel.defaultOutputSchema(for: entry.type),
                outputSchemaDescription: entry.outputSchemaDescription ?? DefaultSchema.defaultDescription(for: entry.outputSchema ?? CanvasViewModel.defaultOutputSchema(for: entry.type)),
                selectedRoles: Set(entry.selectedRoles),
                securityAccess: Set(entry.securityAccess),
                assignedTools: Set(entry.assignedTools ?? []),
                position: CGPoint(x: entry.positionX, y: entry.positionY)
            )
        }
        let restoredLinks = snapshot.links.map { entry in
            NodeLink(fromID: entry.fromID, toID: entry.toID, tone: entry.tone, edgeType: entry.edgeType)
        }
        let anchored = canvas.normalizeAnchorNodes(inputNodes: restoredNodes, inputLinks: restoredLinks)
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
        canvas.searchText = ""
        canvas.zoom = 1.0
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
        var changed = false

        if (document.goal ?? "") != normalizedQuestion {
            document.goal = normalizedQuestion
            changed = true
        }
        if (document.structureStrategy ?? "") != normalizedStrategy {
            document.structureStrategy = normalizedStrategy
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
