import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum TraceDisplayMode: String, CaseIterable {
    case trace = "Trace"
    case rawAPI = "Raw API"
}

/// Bottom-docked drawer showing a run's trace (or raw API view), with a history picker and export controls.
struct ResultsDrawerView: View {
    @Bindable var execution: ExecutionViewModel

    @Binding var resultsDrawerOpen: Bool
    @Binding var traceDisplayMode: TraceDisplayMode
    @Binding var scrollToTraceID: String?

    let pendingHumanPacket: CoordinatorTaskPacket?
    let displayedTrace: [CoordinatorTraceStep]
    let displayedRun: CoordinatorRun?
    let isViewingHistoricalRun: Bool
    let appDisplayName: String

    let traceResolution: (CoordinatorTraceStep) -> TraceResolutionRecommendation?
    let onApplyTraceResolution: (CoordinatorTraceStep) -> Void
    let onRunFromHere: (UUID) -> Void
    let canRunFromNode: (UUID) -> Bool
    let onResolveHumanTask: (HumanTaskDecision) -> Void
    let onContinueExecution: () async -> Void
    let onPersistCoordinatorExecutionState: () -> Void

    var body: some View {
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
                    .help("Switch between trace and raw API view")
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
                        Text(Self.runHistoryLabel(for: entry))
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
        .help("Pick a run from history")
    }

    private static func runHistoryLabel(for entry: CoordinatorRunHistoryEntry) -> String {
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
        let md = execution.exportTraceMarkdown(appDisplayName: appDisplayName)
        guard !md.isEmpty else { return }
        presentExportText(md)
    }

    private func exportRawAPIResults() {
        let md = execution.exportRawAPIMarkdown(appDisplayName: appDisplayName)
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
                                execution.executionTask = Task { await onContinueExecution() }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .help("Continue the paused run")
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
                                    Button("Approve") { onResolveHumanTask(.approve) }
                                        .buttonStyle(.borderedProminent)
                                        .help("Approve this human task")
                                    Button("Reject") { onResolveHumanTask(.reject) }
                                        .buttonStyle(.bordered)
                                        .help("Reject this human task")
                                    Button("Inbox") { execution.isShowingHumanInbox = true }
                                        .buttonStyle(.bordered)
                                        .help("Open the human inbox")
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
                                onPersistCoordinatorExecutionState()
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
                                let resolution = isViewingHistoricalRun ? nil : traceResolution(step)
                                let isHighlighted = scrollToTraceID == step.id
                                CoordinatorTraceRow(
                                    stepNumber: index + 1,
                                    step: step,
                                    resolution: resolution.map { $0.presentation },
                                    onResolve: resolution == nil
                                        ? nil
                                        : { onApplyTraceResolution(step) },
                                    onRunFromHere: isViewingHistoricalRun || execution.isExecutingCoordinator
                                        ? nil
                                        : { nodeID in onRunFromHere(nodeID) },
                                    canRunFromNode: canRunFromNode
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
}
