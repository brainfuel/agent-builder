import SwiftUI

/// Owns coordinator execution pipeline state: planning, running, trace, history, and human-in-the-loop.
/// Contains all execution business logic extracted from ContentView.
@Observable
final class ExecutionViewModel {

    // MARK: - Task Configuration

    static let defaultOrchestrationStrategy = "Design a structure that best answers the task question, compares candidate outputs when useful, and returns one clear final response."

    var orchestrationGoal = "Prepare a safe v1 launch plan"
    var orchestrationStrategy = "Design a structure that best answers the task question, compares candidate outputs when useful, and returns one clear final response."

    // MARK: - Execution State

    var latestCoordinatorPlan: CoordinatorPlan?
    var latestCoordinatorRun: CoordinatorRun?
    var isExecutingCoordinator = false
    var executionTask: Task<Void, Never>?
    var liveStatusMessage = ""
    var liveStatusBannerPulse = false

    // MARK: - Trace

    var coordinatorTrace: [CoordinatorTraceStep] = []
    var pendingCoordinatorExecution: PendingCoordinatorExecution?
    var lastCompletedExecution: PendingCoordinatorExecution?

    // MARK: - Run History

    var coordinatorRunHistory: [CoordinatorRunHistoryEntry] = []
    var selectedHistoryRunID: String?

    // MARK: - Run From Here

    var runFromHereNodeID: UUID?
    var runFromHerePrompt = ""

    // MARK: - Human-in-the-Loop

    var humanDecisionAudit: [HumanDecisionAuditEvent] = []
    var isShowingHumanInbox = false
    var humanDecisionNote = ""
    var humanActorIdentity = "Human Reviewer"

    // MARK: - Callbacks

    /// Called after execution state changes that should be persisted.
    var onPersistNeeded: (() -> Void)?

    // MARK: - Computed Properties

    var displayedTrace: [CoordinatorTraceStep] {
        if let selectedHistoryRunID,
           let entry = coordinatorRunHistory.first(where: { $0.run.runID == selectedHistoryRunID }) {
            return entry.trace
        }
        return coordinatorTrace
    }

    var displayedRun: CoordinatorRun? {
        if let selectedHistoryRunID,
           let entry = coordinatorRunHistory.first(where: { $0.run.runID == selectedHistoryRunID }) {
            return entry.run
        }
        return latestCoordinatorRun
    }

    var isViewingHistoricalRun: Bool {
        selectedHistoryRunID != nil
    }

    var pendingHumanPacket: CoordinatorTaskPacket? {
        guard
            let pendingCoordinatorExecution,
            let packetID = pendingCoordinatorExecution.awaitingHumanPacketID
        else { return nil }
        return pendingCoordinatorExecution.plan.packets.first(where: { $0.id == packetID })
    }

    // MARK: - Execution State Query

    func executionState(for nodeID: UUID) -> NodeExecutionState {
        guard let step = coordinatorTrace.first(where: { $0.assignedNodeID == nodeID }) else {
            return .idle
        }
        switch step.status {
        case .running, .waitingHuman:
            return .running
        case .succeeded, .approved:
            return .succeeded
        case .failed, .blocked, .rejected, .needsInfo:
            return .failed
        case .queued:
            return .idle
        }
    }

    func stopExecution() {
        executionTask?.cancel()
        executionTask = nil
    }

    // MARK: - Trace Step Updates

    @MainActor
    func updateTraceStep(
        packetID: String,
        status: CoordinatorTraceStatus,
        summary: String? = nil,
        confidence: Double? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        modelID: String? = nil,
        systemPrompt: String? = nil,
        userPrompt: String? = nil,
        rawResponse: String? = nil
    ) {
        guard let index = coordinatorTrace.firstIndex(where: { $0.packetID == packetID }) else { return }
        coordinatorTrace[index].status = status
        if let summary { coordinatorTrace[index].summary = summary }
        if let confidence { coordinatorTrace[index].confidence = confidence }
        if let startedAt { coordinatorTrace[index].startedAt = startedAt }
        if let finishedAt { coordinatorTrace[index].finishedAt = finishedAt }
        if let inputTokens { coordinatorTrace[index].inputTokens = inputTokens }
        if let outputTokens { coordinatorTrace[index].outputTokens = outputTokens }
        if let modelID { coordinatorTrace[index].modelID = modelID }
        if let systemPrompt { coordinatorTrace[index].systemPrompt = systemPrompt }
        if let userPrompt { coordinatorTrace[index].userPrompt = userPrompt }
        if let rawResponse { coordinatorTrace[index].rawResponse = rawResponse }
    }

    // MARK: - Handoff Validation

    func validateRequiredHandoffs(
        for packet: CoordinatorTaskPacket,
        outputsByNodeID: [UUID: ProducedHandoff],
        goal: String
    ) -> HandoffValidation {
        if packet.requiredHandoffs.isEmpty {
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
                    message: "Blocked: \(requirement.fromNodeName) produced \(handoff.schema), expected \(requirement.outputSchema).",
                    handoffSummaries: []
                )
            }

            if requirement.outputSchema != packet.requiredInputSchema {
                summaries.append("[\(requirement.fromNodeName) (\(requirement.outputSchema) → \(packet.requiredInputSchema))]: \(handoff.summary)")
            } else {
                summaries.append("\(requirement.fromNodeName): \(handoff.summary)")
            }
        }

        return HandoffValidation(isValid: true, message: "", handoffSummaries: summaries)
    }

    // MARK: - Simulated Execution

    func simulatePacketExecution(
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
            "Input schema: \(packet.requiredInputSchema).",
            inputPreview,
            permissionPreview.isEmpty ? "Policy check: no elevated permissions required." : "Policy check: \(permissionPreview).",
            "Output schema: \(packet.requiredOutputSchema)."
        ].joined(separator: " ")

        return MCPTaskResponse(
            summary: summary,
            confidence: hasRestrictedAccess ? 0.79 : 0.86,
            completed: true
        )
    }

    // MARK: - Trace Resolution

    func inferredMissingPermission(from summary: String?) -> SecurityAccess? {
        guard let summary else { return nil }
        let normalized = summary.lowercased()

        if normalized.contains("missing web")
            || normalized.contains("no web access")
            || normalized.contains("missing webaccess")
            || normalized.contains("missing browse")
            || normalized.contains("missing search")
            || normalized.contains("school directory tool")
            || normalized.contains("browse_page")
        { return .webAccess }
        if normalized.contains("missing workspace read")
            || normalized.contains("workspace read is required")
            || normalized.contains("missing workspaceread")
        { return .workspaceRead }
        if normalized.contains("missing workspace write")
            || normalized.contains("workspace write is required")
            || normalized.contains("missing workspacewrite")
            || normalized.contains("write permission")
        { return .workspaceWrite }
        if normalized.contains("missing terminal")
            || normalized.contains("terminal execution")
            || normalized.contains("shell access")
            || normalized.contains("command execution")
        { return .terminalExec }
        if normalized.contains("missing secrets")
            || normalized.contains("secrets read")
            || normalized.contains("secret access")
        { return .secretsRead }
        if normalized.contains("missing audit")
            || normalized.contains("audit logs")
        { return .auditLogs }

        return nil
    }

    func traceResolution(for step: CoordinatorTraceStep, nodes: [OrgNode]) -> TraceResolutionRecommendation? {
        guard step.status == .failed || step.status == .blocked else { return nil }
        guard let summary = step.summary else { return nil }

        let nodeID: UUID? = {
            if let assignedNodeID = step.assignedNodeID {
                return assignedNodeID
            }
            return nodes.first(where: { $0.name.caseInsensitiveCompare(step.assignedNodeName) == .orderedSame })?.id
        }()

        if let missingPermission = inferredMissingPermission(from: summary) {
            if
                let nodeID,
                let node = nodes.first(where: { $0.id == nodeID }),
                !node.securityAccess.contains(missingPermission)
            {
                let title = "Missing permission: \(missingPermission.label)"
                let detail = "\(node.name) cannot complete this task without \(missingPermission.label)."
                return TraceResolutionRecommendation(
                    presentation: CoordinatorTraceResolutionPresentation(
                        title: title,
                        detail: detail,
                        buttonTitle: "Allow \(missingPermission.label)"
                    ),
                    action: .grantPermission(nodeID: nodeID, permission: missingPermission)
                )
            }
        }

        return nil
    }

    // MARK: - Pipeline Execution

    /// Runs the coordinator pipeline, building a plan from the orchestration graph and executing it.
    func runPipelineWithFeedback(
        _ feedback: String?,
        orchestrationGraph: OrchestrationGraph,
        nodes: [OrgNode],
        apiKeyStore: any APIKeyStoring,
        providerModelStore: any ProviderModelPreferencesStoring,
        liveProviderExecutor: any LiveProviderExecuting,
        mcpManager: MCPServerManager,
        mcpServerConnections: [MCPServerConnection]
    ) {
        guard !orchestrationGraph.nodes.isEmpty else { return }
        ToolExecutionEngine.shared.resetMemory()
        var normalizedGoal = orchestrationGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedGoal.isEmpty { normalizedGoal = "Execute coordinator objective" }

        if let feedback, !feedback.isEmpty {
            normalizedGoal += "\n\n\(feedback)"
        }

        let planner = CoordinatorOrchestrator()
        let plan = planner.plan(goal: normalizedGoal, graph: orchestrationGraph)
        let mode: CoordinatorExecutionMode = .liveMCP
        latestCoordinatorPlan = plan
        latestCoordinatorRun = nil
        humanDecisionNote = ""
        coordinatorTrace = plan.packets.map {
            CoordinatorTraceStep(
                packetID: $0.id,
                assignedNodeID: $0.assignedNodeID,
                assignedNodeName: $0.assignedNodeName,
                objective: $0.objective,
                status: .queued,
                summary: nil, confidence: nil, startedAt: nil, finishedAt: nil
            )
        }

        lastCompletedExecution = nil
        selectedHistoryRunID = nil
        pendingCoordinatorExecution = PendingCoordinatorExecution(
            runID: "RUN-\(UUID().uuidString.prefix(8))",
            plan: plan, mode: mode, nextPacketIndex: 0,
            results: [], outputsByNodeID: [:], startedAt: Date(),
            awaitingHumanPacketID: nil, retryFeedback: feedback
        )
        isExecutingCoordinator = true
        liveStatusMessage = "Planning execution…"
        onPersistNeeded?()
        executionTask = Task { [weak self] in
            await self?.continueExecution(
                nodes: nodes,
                apiKeyStore: apiKeyStore,
                providerModelStore: providerModelStore,
                liveProviderExecutor: liveProviderExecutor,
                mcpManager: mcpManager,
                mcpServerConnections: mcpServerConnections
            )
        }
    }

    /// Resumes from a specific node, reusing cached upstream outputs.
    func runFromNode(
        _ nodeID: UUID,
        additionalContext: String? = nil,
        nodes: [OrgNode],
        apiKeyStore: any APIKeyStoring,
        providerModelStore: any ProviderModelPreferencesStoring,
        liveProviderExecutor: any LiveProviderExecuting,
        mcpManager: MCPServerManager,
        mcpServerConnections: [MCPServerConnection]
    ) {
        guard !isExecutingCoordinator else { return }
        guard let previousPending = pendingCoordinatorExecution ?? lastCompletedExecution else { return }

        let plan = previousPending.plan
        guard let startIndex = plan.packets.firstIndex(where: { $0.assignedNodeID == nodeID }) else { return }

        var cachedOutputs: [UUID: ProducedHandoff] = [:]
        for i in 0..<startIndex {
            let packet = plan.packets[i]
            if let output = previousPending.outputsByNodeID[packet.assignedNodeID] {
                cachedOutputs[packet.assignedNodeID] = output
            }
        }

        let keptResults = Array(previousPending.results.prefix(startIndex))

        coordinatorTrace = plan.packets.enumerated().map { index, packet in
            if index < startIndex, let existingStep = coordinatorTrace.first(where: { $0.packetID == packet.id }) {
                return existingStep
            }
            return CoordinatorTraceStep(
                packetID: packet.id,
                assignedNodeID: packet.assignedNodeID,
                assignedNodeName: packet.assignedNodeName,
                objective: packet.objective,
                status: .queued,
                summary: nil, confidence: nil, startedAt: nil, finishedAt: nil
            )
        }

        selectedHistoryRunID = nil
        pendingCoordinatorExecution = PendingCoordinatorExecution(
            runID: "RUN-\(UUID().uuidString.prefix(8))",
            plan: plan, mode: previousPending.mode,
            nextPacketIndex: startIndex, results: keptResults,
            outputsByNodeID: cachedOutputs, startedAt: Date(),
            awaitingHumanPacketID: nil, retryFeedback: nil,
            runFromHereContext: additionalContext,
            runFromHereStartNodeID: additionalContext != nil ? nodeID : nil
        )
        isExecutingCoordinator = true
        liveStatusMessage = "Resuming from \(plan.packets[startIndex].assignedNodeName)…"
        onPersistNeeded?()
        executionTask = Task { [weak self] in
            await self?.continueExecution(
                nodes: nodes,
                apiKeyStore: apiKeyStore,
                providerModelStore: providerModelStore,
                liveProviderExecutor: liveProviderExecutor,
                mcpManager: mcpManager,
                mcpServerConnections: mcpServerConnections
            )
        }
    }

    /// Core execution loop — processes packets sequentially.
    @MainActor
    func continueExecution(
        nodes: [OrgNode],
        apiKeyStore: any APIKeyStoring,
        providerModelStore: any ProviderModelPreferencesStoring,
        liveProviderExecutor: any LiveProviderExecuting,
        mcpManager: MCPServerManager,
        mcpServerConnections: [MCPServerConnection]
    ) async {
        guard var pending = pendingCoordinatorExecution else { return }

        while pending.nextPacketIndex < pending.plan.packets.count {
            if Task.isCancelled {
                liveStatusMessage = ""
                isExecutingCoordinator = false
                pendingCoordinatorExecution = pending
                onPersistNeeded?()
                return
            }

            let packet = pending.plan.packets[pending.nextPacketIndex]
            let startedAtStep = Date()
            let nodeIndex = pending.nextPacketIndex + 1
            let nodeTotal = pending.plan.packets.count
            liveStatusMessage = "Node \(nodeIndex)/\(nodeTotal): \(packet.assignedNodeName) — starting…"

            updateTraceStep(packetID: packet.id, status: .running, startedAt: startedAtStep)

            let handoffValidation = validateRequiredHandoffs(
                for: packet,
                outputsByNodeID: pending.outputsByNodeID,
                goal: pending.plan.goal
            )

            if !handoffValidation.isValid {
                let finishedAtStep = Date()
                let blockedResult = CoordinatorTaskResult(
                    id: UUID().uuidString, packetID: packet.id,
                    assignedNodeName: packet.assignedNodeName,
                    summary: handoffValidation.message, confidence: 0,
                    completed: false, finishedAt: finishedAtStep
                )
                pending.results.append(blockedResult)
                pending.nextPacketIndex += 1
                updateTraceStep(
                    packetID: packet.id, status: .blocked,
                    summary: handoffValidation.message, confidence: 0,
                    finishedAt: finishedAtStep
                )
                pendingCoordinatorExecution = pending
                onPersistNeeded?()
                continue
            }

            if packet.assignedNodeKind == .human {
                pending.awaitingHumanPacketID = packet.id
                pendingCoordinatorExecution = pending
                isExecutingCoordinator = false
                updateTraceStep(
                    packetID: packet.id, status: .waitingHuman,
                    summary: "Awaiting human decision.", confidence: nil, finishedAt: nil
                )
                onPersistNeeded?()
                return
            }

            liveStatusMessage = "Node \(nodeIndex)/\(nodeTotal): \(packet.assignedNodeName) — calling LLM…"
            let statusPrefix = "Node \(nodeIndex)/\(nodeTotal): \(packet.assignedNodeName)"

            let statusTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: AppConfiguration.Timing.liveStatusPollIntervalNanoseconds)
                    let detail = liveProviderExecutor.liveStatus
                    if !detail.isEmpty {
                        self?.liveStatusMessage = "\(statusPrefix) · \(detail)"
                    }
                }
            }

            var effectiveGoal = pending.plan.goal
            if let context = pending.runFromHereContext,
               !context.isEmpty,
               packet.assignedNodeID == pending.runFromHereStartNodeID {
                effectiveGoal += "\n\nADDITIONAL CONTEXT FROM USER: \(context)"
            }

            let packetExecutionService = CoordinatorPacketExecutionService(
                nodes: nodes,
                apiKeyStore: apiKeyStore,
                providerModelStore: providerModelStore,
                liveProviderExecutor: liveProviderExecutor,
                mcpManager: mcpManager,
                mcpServerConnections: mcpServerConnections
            )
            let response = await packetExecutionService.executeLiveProviderPacket(
                packet,
                handoffSummaries: handoffValidation.handoffSummaries,
                goal: effectiveGoal
            )
            statusTask.cancel()

            if Task.isCancelled {
                updateTraceStep(packetID: packet.id, status: .failed, summary: "Stopped by user.", finishedAt: Date())
                liveStatusMessage = ""
                isExecutingCoordinator = false
                pendingCoordinatorExecution = pending
                onPersistNeeded?()
                return
            }

            let finishedAtStep = Date()
            let completed = response.completed
            liveStatusMessage = "\(statusPrefix) — \(completed ? "done ✓" : "failed ✗")"
            let result = CoordinatorTaskResult(
                id: UUID().uuidString, packetID: packet.id,
                assignedNodeName: packet.assignedNodeName,
                summary: response.summary, confidence: response.confidence,
                completed: completed, finishedAt: finishedAtStep,
                inputTokens: response.inputTokens, outputTokens: response.outputTokens
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
                summary: response.summary, confidence: response.confidence,
                finishedAt: finishedAtStep,
                inputTokens: response.inputTokens, outputTokens: response.outputTokens,
                modelID: response.modelID, systemPrompt: response.systemPrompt,
                userPrompt: response.userPrompt, rawResponse: response.rawResponse
            )
            pendingCoordinatorExecution = pending
            onPersistNeeded?()
        }

        let completedRun = CoordinatorRun(
            runID: pending.runID, planID: pending.plan.planID,
            mode: pending.mode, results: pending.results,
            startedAt: pending.startedAt, finishedAt: Date()
        )
        latestCoordinatorRun = completedRun
        coordinatorRunHistory.append(CoordinatorRunHistoryEntry(run: completedRun, trace: coordinatorTrace))
        selectedHistoryRunID = nil
        lastCompletedExecution = pending
        pendingCoordinatorExecution = nil
        isExecutingCoordinator = false
        liveStatusMessage = ""
        onPersistNeeded?()
    }

    // MARK: - Retry with Feedback

    func retryPipelineWithFeedback(
        _ feedback: String,
        from step: CoordinatorTraceStep?,
        orchestrationGraph: OrchestrationGraph,
        nodes: [OrgNode],
        apiKeyStore: any APIKeyStoring,
        providerModelStore: any ProviderModelPreferencesStoring,
        liveProviderExecutor: any LiveProviderExecuting,
        mcpManager: MCPServerManager,
        mcpServerConnections: [MCPServerConnection]
    ) {
        guard !isExecutingCoordinator else { return }
        let source = step?.assignedNodeName ?? "previous run"
        let feedbackText = "FEEDBACK FROM \(source): \(feedback)"
        print("[RetryWithFeedback] Injecting feedback from \(source), length: \(feedback.count) chars")

        runPipelineWithFeedback(
            feedbackText,
            orchestrationGraph: orchestrationGraph,
            nodes: nodes,
            apiKeyStore: apiKeyStore,
            providerModelStore: providerModelStore,
            liveProviderExecutor: liveProviderExecutor,
            mcpManager: mcpManager,
            mcpServerConnections: mcpServerConnections
        )
    }

    // MARK: - Human Task Resolution

    @MainActor
    func resolveHumanTask(
        _ decision: HumanTaskDecision,
        nodes: [OrgNode],
        apiKeyStore: any APIKeyStoring,
        providerModelStore: any ProviderModelPreferencesStoring,
        liveProviderExecutor: any LiveProviderExecuting,
        mcpManager: MCPServerManager,
        mcpServerConnections: [MCPServerConnection]
    ) {
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
                id: UUID().uuidString, packetID: packet.id,
                assignedNodeName: packet.assignedNodeName,
                summary: summary, confidence: 1,
                completed: completed, finishedAt: finishedAt
            )
        )
        pending.nextPacketIndex += 1
        pending.awaitingHumanPacketID = nil
        humanDecisionAudit.append(
            HumanDecisionAuditEvent(
                id: UUID().uuidString, runID: pending.runID,
                packetID: packet.id, nodeName: packet.assignedNodeName,
                decision: decision, note: note, actorIdentity: actor,
                decidedAt: finishedAt
            )
        )

        updateTraceStep(
            packetID: packet.id, status: status,
            summary: summary, confidence: 1, finishedAt: finishedAt
        )

        switch decision {
        case .approve:
            pendingCoordinatorExecution = pending
            isExecutingCoordinator = true
            onPersistNeeded?()
            executionTask = Task { [weak self] in
                await self?.continueExecution(
                    nodes: nodes,
                    apiKeyStore: apiKeyStore,
                    providerModelStore: providerModelStore,
                    liveProviderExecutor: liveProviderExecutor,
                    mcpManager: mcpManager,
                    mcpServerConnections: mcpServerConnections
                )
            }
        case .reject, .needsInfo:
            let completedRun = CoordinatorRun(
                runID: pending.runID, planID: pending.plan.planID,
                mode: pending.mode, results: pending.results,
                startedAt: pending.startedAt, finishedAt: Date()
            )
            latestCoordinatorRun = completedRun
            coordinatorRunHistory.append(CoordinatorRunHistoryEntry(run: completedRun, trace: coordinatorTrace))
            selectedHistoryRunID = nil
            lastCompletedExecution = pending
            pendingCoordinatorExecution = nil
            isExecutingCoordinator = false
            onPersistNeeded?()
        }
    }

    // MARK: - Export

    func exportTraceMarkdown(appDisplayName: String) -> String {
        let trace = displayedTrace
        let run = displayedRun
        guard !trace.isEmpty else { return "" }

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .medium

        var md = "# Run Trace Report\n\n"

        let goal = orchestrationGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        if !goal.isEmpty { md += "**Goal:** \(goal)\n\n" }
        if let run {
            md += "**Run ID:** \(run.runID)\n"
            md += "**Started:** \(dateFormatter.string(from: run.startedAt))\n"
            md += "**Finished:** \(dateFormatter.string(from: run.finishedAt))\n"
            let duration = run.finishedAt.timeIntervalSince(run.startedAt)
            md += "**Duration:** \(String(format: "%.1fs", duration))\n"
            md += "**Result:** \(run.succeededCount)/\(run.results.count) tasks succeeded\n\n"
        }
        md += "---\n\n"

        for (index, step) in trace.enumerated() {
            let statusEmoji: String
            switch step.status {
            case .succeeded, .approved: statusEmoji = "\u{2705}"
            case .failed, .blocked, .rejected, .needsInfo: statusEmoji = "\u{274C}"
            case .running, .waitingHuman: statusEmoji = "\u{23F3}"
            case .queued: statusEmoji = "\u{1F7E1}"
            }

            md += "## \(index + 1). \(step.assignedNodeName) \(statusEmoji)\n\n"
            md += "**Objective:** \(step.objective)\n"
            md += "**Status:** \(step.status.rawValue)\n"
            if let duration = step.durationText { md += "**Duration:** \(duration)\n" }
            if let input = step.inputTokens, let output = step.outputTokens, input + output > 0 {
                md += "**Tokens:** \(input) in / \(output) out (\(input + output) total)\n"
            }
            if let confidence = step.confidence {
                md += "**Confidence:** \(String(format: "%.0f%%", confidence * 100))\n"
            }
            if let modelID = step.modelID { md += "**Model:** \(modelID)\n" }
            md += "\n"
            if let summary = step.summary, !summary.isEmpty { md += "**Result:**\n\(summary)\n\n" }
            if let systemPrompt = step.systemPrompt, !systemPrompt.isEmpty {
                md += "<details><summary>System Prompt</summary>\n\n```\n\(systemPrompt)\n```\n</details>\n\n"
            }
            if let userPrompt = step.userPrompt, !userPrompt.isEmpty {
                md += "<details><summary>User Prompt</summary>\n\n```\n\(userPrompt)\n```\n</details>\n\n"
            }
            if let rawResponse = step.rawResponse, !rawResponse.isEmpty {
                md += "<details><summary>Raw Response</summary>\n\n```\n\(rawResponse)\n```\n</details>\n\n"
            }
            md += "---\n\n"
        }

        let totalInput = trace.compactMap(\.inputTokens).reduce(0, +)
        let totalOutput = trace.compactMap(\.outputTokens).reduce(0, +)
        if totalInput + totalOutput > 0 {
            md += "**Total Tokens:** \(totalInput) in / \(totalOutput) out (\(totalInput + totalOutput) total)\n\n"
        }
        md += "*Exported from \(appDisplayName) on \(dateFormatter.string(from: Date()))*\n"
        return md
    }

    func exportRawAPIMarkdown(appDisplayName: String) -> String {
        let trace = displayedTrace
        let run = displayedRun
        guard !trace.isEmpty else { return "" }

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .medium

        var md = "# Raw API Report\n\n"
        let goal = orchestrationGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        if !goal.isEmpty { md += "**Goal:** \(goal)\n\n" }
        if let run {
            md += "**Run ID:** \(run.runID)\n"
            md += "**Started:** \(dateFormatter.string(from: run.startedAt))\n"
            md += "**Finished:** \(dateFormatter.string(from: run.finishedAt))\n\n"
        }
        md += "---\n\n"

        for (index, step) in trace.enumerated() {
            md += "## \(index + 1). \(step.assignedNodeName)\n\n"
            if let modelID = step.modelID { md += "**Model:** \(modelID)\n" }
            if let input = step.inputTokens, let output = step.outputTokens, input + output > 0 {
                md += "**Tokens:** \(input) in / \(output) out (\(input + output) total)\n"
            }
            md += "\n"
            if let systemPrompt = step.systemPrompt, !systemPrompt.isEmpty {
                md += "### System Prompt\n\n```\n\(systemPrompt)\n```\n\n"
            }
            if let userPrompt = step.userPrompt, !userPrompt.isEmpty {
                md += "### User Prompt\n\n```\n\(userPrompt)\n```\n\n"
            }
            if let rawResponse = step.rawResponse, !rawResponse.isEmpty {
                md += "### Raw Response\n\n```\n\(rawResponse)\n```\n\n"
            }
            md += "---\n\n"
        }
        md += "*Exported from \(appDisplayName) on \(dateFormatter.string(from: Date()))*\n"
        return md
    }

    // MARK: - State Sync

    func syncFromBundle(_ decoded: CoordinatorExecutionStateBundle) {
        pendingCoordinatorExecution = decoded.pendingExecution
        lastCompletedExecution = decoded.lastCompletedExecution
        latestCoordinatorRun = decoded.latestRun
        coordinatorTrace = decoded.trace
        coordinatorRunHistory = decoded.runHistory ?? []
        selectedHistoryRunID = nil
        humanDecisionAudit = decoded.humanDecisionAudit
        humanActorIdentity = decoded.humanActorIdentity
        isExecutingCoordinator = false
    }

    func resetState() {
        pendingCoordinatorExecution = nil
        lastCompletedExecution = nil
        latestCoordinatorRun = nil
        coordinatorTrace = []
        coordinatorRunHistory = []
        selectedHistoryRunID = nil
        humanDecisionAudit = []
        if humanActorIdentity.isEmpty {
            humanActorIdentity = "Human Reviewer"
        }
        isExecutingCoordinator = false
    }

    func buildStateBundle() -> CoordinatorExecutionStateBundle {
        CoordinatorExecutionStateBundle(
            pendingExecution: pendingCoordinatorExecution,
            latestRun: latestCoordinatorRun,
            trace: coordinatorTrace,
            humanDecisionAudit: humanDecisionAudit,
            humanActorIdentity: humanActorIdentity,
            lastCompletedExecution: lastCompletedExecution,
            runHistory: coordinatorRunHistory
        )
    }

    // MARK: - Document Sync

    /// Restores orchestration config and execution state from a persisted document.
    func load(from document: GraphDocument?) {
        let storedGoal = document?.goal ?? ""
        if orchestrationGoal != storedGoal { orchestrationGoal = storedGoal }

        let fallback = storedGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.defaultOrchestrationStrategy
            : storedGoal
        let stored = (document?.structureStrategy ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = stored.isEmpty ? fallback : stored
        if orchestrationStrategy != resolved { orchestrationStrategy = resolved }

        guard
            let data = document?.executionStateData,
            let decoded = try? JSONDecoder().decode(CoordinatorExecutionStateBundle.self, from: data)
        else {
            resetState()
            return
        }

        pendingCoordinatorExecution = decoded.pendingExecution
        lastCompletedExecution = decoded.lastCompletedExecution
        latestCoordinatorRun = decoded.latestRun
        coordinatorTrace = decoded.trace
        coordinatorRunHistory = decoded.runHistory ?? []
        selectedHistoryRunID = nil
        humanDecisionAudit = decoded.humanDecisionAudit
        humanActorIdentity = decoded.humanActorIdentity
        isExecutingCoordinator = false
    }

    /// Writes execution state to the document and calls `onSave`.
    func persist(to document: GraphDocument, onSave: () -> Void) {
        let sanitized = humanActorIdentity.trimmingCharacters(in: .whitespacesAndNewlines)
        humanActorIdentity = sanitized.isEmpty ? "Human Reviewer" : sanitized

        guard
            pendingCoordinatorExecution != nil ||
            latestCoordinatorRun != nil ||
            !coordinatorTrace.isEmpty ||
            !humanDecisionAudit.isEmpty
        else {
            document.executionStateData = nil
            document.updatedAt = Date()
            onSave()
            return
        }

        let bundle = CoordinatorExecutionStateBundle(
            pendingExecution: pendingCoordinatorExecution,
            latestRun: latestCoordinatorRun,
            trace: coordinatorTrace,
            humanDecisionAudit: humanDecisionAudit,
            humanActorIdentity: humanActorIdentity,
            lastCompletedExecution: lastCompletedExecution,
            runHistory: coordinatorRunHistory.isEmpty ? nil : coordinatorRunHistory
        )
        guard let data = try? JSONEncoder().encode(bundle) else { return }
        document.executionStateData = data
        document.updatedAt = Date()
        onSave()
    }
}
