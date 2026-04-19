import CoreText
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
            // Current / live-editable structure option
            Button {
                withAnimation(.snappy(duration: 0.2)) { execution.selectedHistoryRunID = nil }
            } label: {
                HStack {
                    Text("Current Structure")
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
                Text(execution.selectedHistoryRunID == nil ? "Current" : runHistoryPickerTitle)
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
            return "Current Structure"
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

    private func exportCurrentResultsAsPDF() {
        let md: String
        let titleSuffix: String
        switch traceDisplayMode {
        case .trace:
            md = execution.exportTraceMarkdown(appDisplayName: appDisplayName)
            titleSuffix = "Trace"
        case .rawAPI:
            md = execution.exportRawAPIMarkdown(appDisplayName: appDisplayName)
            titleSuffix = "Raw API"
        }
        guard !md.isEmpty else { return }

        let attributed = Self.renderMarkdownToAttributed(md)
        let filename = Self.pdfFilename(appDisplayName: appDisplayName, suffix: titleSuffix)
        guard let pdfURL = Self.renderPDF(from: attributed, filename: filename) else { return }
        presentExportFile(pdfURL)
    }

    private static func pdfFilename(appDisplayName: String, suffix: String) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd-HHmm"
        let stamp = df.string(from: Date())
        let base = "\(appDisplayName)-\(suffix)-\(stamp)"
            .replacingOccurrences(of: " ", with: "-")
        return base + ".pdf"
    }

    private static func renderMarkdownToAttributed(_ markdown: String) -> NSAttributedString {
        // Per-line parsing so we can honour headings, bullets and code fences without
        // relying on the limited Foundation AttributedString(markdown:) block support.
        let result = NSMutableAttributedString()
        let body = UIFont.systemFont(ofSize: 11, weight: .regular)
        let bodyBold = UIFont.systemFont(ofSize: 11, weight: .semibold)
        let h1 = UIFont.systemFont(ofSize: 20, weight: .bold)
        let h2 = UIFont.systemFont(ofSize: 16, weight: .semibold)
        let h3 = UIFont.systemFont(ofSize: 13, weight: .semibold)
        let mono = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)

        var inCode = false
        let lines = markdown.components(separatedBy: "\n")

        for raw in lines {
            var line = raw
            if line.hasPrefix("```") {
                inCode.toggle()
                result.append(NSAttributedString(string: "\n"))
                continue
            }
            if inCode {
                let para = NSMutableParagraphStyle()
                para.paragraphSpacing = 0
                para.firstLineHeadIndent = 8
                para.headIndent = 8
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: mono,
                    .foregroundColor: UIColor.label,
                    .backgroundColor: UIColor.secondarySystemFill,
                    .paragraphStyle: para
                ]
                result.append(NSAttributedString(string: line + "\n", attributes: attrs))
                continue
            }

            // Headings
            if line.hasPrefix("### ") {
                line.removeFirst(4)
                result.append(styledLine(line, font: h3, spacingAbove: 6, spacingBelow: 2))
                continue
            }
            if line.hasPrefix("## ") {
                line.removeFirst(3)
                result.append(styledLine(line, font: h2, spacingAbove: 8, spacingBelow: 3))
                continue
            }
            if line.hasPrefix("# ") {
                line.removeFirst(2)
                result.append(styledLine(line, font: h1, spacingAbove: 10, spacingBelow: 4))
                continue
            }
            // Horizontal rule
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                let para = NSMutableParagraphStyle()
                para.paragraphSpacing = 4
                let line = NSAttributedString(
                    string: String(repeating: "─", count: 40) + "\n",
                    attributes: [.font: body, .foregroundColor: UIColor.tertiaryLabel, .paragraphStyle: para]
                )
                result.append(line)
                continue
            }
            // Bullets
            if let bulletText = bulletPayload(line) {
                let para = NSMutableParagraphStyle()
                para.firstLineHeadIndent = 12
                para.headIndent = 24
                para.paragraphSpacing = 2
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: body,
                    .foregroundColor: UIColor.label,
                    .paragraphStyle: para
                ]
                let inline = renderInline(bulletText, baseFont: body, boldFont: bodyBold)
                let prefix = NSMutableAttributedString(string: "•  ", attributes: attrs)
                prefix.append(inline)
                prefix.append(NSAttributedString(string: "\n", attributes: attrs))
                prefix.addAttributes(attrs, range: NSRange(location: 0, length: prefix.length))
                // Re-apply bold runs from inline
                inline.enumerateAttribute(.font, in: NSRange(location: 0, length: inline.length)) { value, range, _ in
                    if let f = value as? UIFont, f == bodyBold {
                        prefix.addAttribute(.font, value: bodyBold, range: NSRange(location: range.location + 3, length: range.length))
                    }
                }
                result.append(prefix)
                continue
            }

            // Plain paragraph (supports **bold** inline)
            let para = NSMutableParagraphStyle()
            para.paragraphSpacing = 4
            let inline = NSMutableAttributedString(attributedString: renderInline(line, baseFont: body, boldFont: bodyBold))
            inline.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: inline.length))
            inline.append(NSAttributedString(string: "\n", attributes: [.font: body, .paragraphStyle: para]))
            result.append(inline)
        }

        return result
    }

    private static func bulletPayload(_ line: String) -> String? {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        for prefix in ["- ", "* ", "• "] {
            if trimmed.hasPrefix(prefix) {
                return String(trimmed.dropFirst(prefix.count))
            }
        }
        return nil
    }

    private static func styledLine(_ text: String, font: UIFont, spacingAbove: CGFloat, spacingBelow: CGFloat) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.paragraphSpacingBefore = spacingAbove
        para.paragraphSpacing = spacingBelow
        return NSAttributedString(
            string: text + "\n",
            attributes: [
                .font: font,
                .foregroundColor: UIColor.label,
                .paragraphStyle: para
            ]
        )
    }

    private static func renderInline(_ text: String, baseFont: UIFont, boldFont: UIFont) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        var remaining = text[...]
        while let range = remaining.range(of: "**") {
            let before = remaining[remaining.startIndex..<range.lowerBound]
            out.append(NSAttributedString(string: String(before), attributes: [.font: baseFont, .foregroundColor: UIColor.label]))
            let rest = remaining[range.upperBound...]
            if let end = rest.range(of: "**") {
                let bold = rest[rest.startIndex..<end.lowerBound]
                out.append(NSAttributedString(string: String(bold), attributes: [.font: boldFont, .foregroundColor: UIColor.label]))
                remaining = rest[end.upperBound...]
            } else {
                out.append(NSAttributedString(string: String(rest), attributes: [.font: baseFont, .foregroundColor: UIColor.label]))
                remaining = "".prefix(0)
                break
            }
        }
        if !remaining.isEmpty {
            out.append(NSAttributedString(string: String(remaining), attributes: [.font: baseFont, .foregroundColor: UIColor.label]))
        }
        return out
    }

    private static func renderPDF(from attributed: NSAttributedString, filename: String) -> URL? {
        // US Letter at 72dpi.
        let pageSize = CGSize(width: 612, height: 792)
        let margin: CGFloat = 48
        let textRect = CGRect(
            x: margin, y: margin,
            width: pageSize.width - margin * 2,
            height: pageSize.height - margin * 2
        )

        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextCreator as String: "Agentic",
            kCGPDFContextTitle as String: filename
        ]
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(origin: .zero, size: pageSize),
            format: format
        )

        do {
            try renderer.writePDF(to: tmpURL) { ctx in
                let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
                var currentRange = CFRange(location: 0, length: 0)
                var done = false
                while !done {
                    ctx.beginPage()
                    let cgCtx = ctx.cgContext
                    // Flip coordinate system for CoreText.
                    cgCtx.saveGState()
                    cgCtx.translateBy(x: 0, y: pageSize.height)
                    cgCtx.scaleBy(x: 1, y: -1)

                    let flippedRect = CGRect(
                        x: textRect.origin.x,
                        y: pageSize.height - textRect.origin.y - textRect.height,
                        width: textRect.width,
                        height: textRect.height
                    )
                    let path = CGPath(rect: flippedRect, transform: nil)
                    let frame = CTFramesetterCreateFrame(framesetter, currentRange, path, nil)
                    CTFrameDraw(frame, cgCtx)

                    let visible = CTFrameGetVisibleStringRange(frame)
                    currentRange = CFRange(
                        location: visible.location + visible.length,
                        length: 0
                    )
                    cgCtx.restoreGState()

                    if currentRange.location >= attributed.length {
                        done = true
                    }
                }
            }
            return tmpURL
        } catch {
            return nil
        }
    }

    private func presentExportFile(_ url: URL) {
        #if targetEnvironment(macCatalyst)
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
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
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            var topVC = rootVC
            while let presented = topVC.presentedViewController { topVC = presented }
            topVC.present(activityVC, animated: true)
        }
        #endif
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
                            .accessibilityLabel(traceDisplayMode == .trace ? "Export Trace as Text" : "Export Raw API as Text")
                            .catalystTooltip(traceDisplayMode == .trace ? "Export Trace as Text" : "Export Raw API as Text")
                            .help("Export as plain text / markdown")

                            Button {
                                exportCurrentResultsAsPDF()
                            } label: {
                                Image(systemName: "doc.richtext")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(traceDisplayMode == .trace ? "Export Trace as PDF" : "Export Raw API as PDF")
                            .catalystTooltip(traceDisplayMode == .trace ? "Export Trace as PDF" : "Export Raw API as PDF")
                            .help("Export as formatted PDF report")
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
