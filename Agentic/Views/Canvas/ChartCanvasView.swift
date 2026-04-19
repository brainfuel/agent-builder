import SwiftUI
import UIKit

/// Walks up the UIKit view hierarchy at `onFound` time to find the enclosing
/// `UIScrollView`. Must be placed *inside* the SwiftUI ScrollView's content so
/// its superview chain includes the scroll view. We use this to bypass SwiftUI's
/// `ScrollPosition` APIs, which in a 2D `ScrollView([.horizontal, .vertical])`
/// on Mac Catalyst silently clamp negative X values — the underlying
/// UIScrollView's bounds origin can be negative, so a "valid" saved scroll
/// position can have X < 0 and SwiftUI will throw it away. Setting
/// `contentOffset` on the UIScrollView directly avoids this.
private struct ScrollViewIntrospector: UIViewRepresentable {
    var onFound: (UIScrollView) -> Void

    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        DispatchQueue.main.async { [weak v] in
            guard let v else { return }
            var candidate: UIView? = v.superview
            while let c = candidate {
                if let scroll = c as? UIScrollView {
                    onFound(scroll)
                    return
                }
                candidate = c.superview
            }
        }
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// The main scrollable, zoomable node canvas — draws nodes, link connection layer, link handles,
/// add-child menu, and the "Run from here" control. Reads canvas/execution state and forwards
/// taps to callbacks on the owning view.
struct ChartCanvasView: View {
    @Bindable var canvas: CanvasViewModel
    @Bindable var execution: ExecutionViewModel
    @Bindable var navigation: NavigationCoordinator

    let visibleNodes: [OrgNode]
    let canvasContentSize: CGSize
    let cardSize: CGSize
    let orphanNodeIDs: Set<UUID>
    let linkDraft: LinkDraft?
    let userNodeTemplates: [UserNodeTemplate]

    let onNodeTap: (OrgNode) -> Void

    // Direct reference to the underlying UIScrollView (captured via a
    // UIViewRepresentable introspector). Using this instead of SwiftUI's
    // `ScrollPosition` is necessary because the 2D `ScrollPosition` coord
    // system doesn't match `contentOffset`, which caused horizontal restore
    // to clamp or miss entirely.
    @State private var underlyingScrollView: UIScrollView?

    var body: some View {
        let canvasSize = canvasContentSize
        let selectedNodeControlOffset: CGFloat = 19
        let visibleIDs = Set(visibleNodes.map(\.id))
        let orphanIDs = orphanNodeIDs
        let visibleLinks = canvas.links.filter { link in
            visibleIDs.contains(link.fromID) && visibleIDs.contains(link.toID)
        }

        return ZStack(alignment: .bottomTrailing) {
            ScrollViewReader { scrollProxy in
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    // Introspector placed INSIDE the scroll content so its
                    // UIView's superview chain includes the UIScrollView.
                    ScrollViewIntrospector { scrollView in
                        if self.underlyingScrollView !== scrollView {
                            self.underlyingScrollView = scrollView
                            applyPendingRestoreIfPossible()
                        }
                    }
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)

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
                                canvas.viewport.suppressLayoutAnimation
                                    ? nil
                                    : .spring(
                                        response: AppConfiguration.Motion.layoutSpringResponse,
                                        dampingFraction: AppConfiguration.Motion.layoutSpringDamping
                                    ),
                                value: node.position.x
                            )
                            .animation(
                                canvas.viewport.suppressLayoutAnimation
                                    ? nil
                                    : .spring(
                                        response: AppConfiguration.Motion.layoutSpringResponse,
                                        dampingFraction: AppConfiguration.Motion.layoutSpringDamping
                                    ),
                                value: node.position.y
                            )
                            .onTapGesture {
                                onNodeTap(node)
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
                            .help("Add a child node")
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
                        let parentIDs = canvas.links.filter { $0.toID == selID }.map(\.fromID)
                        let executingParentIDs = parentIDs.filter { pid in
                            guard let p = canvas.nodes.first(where: { $0.id == pid }) else { return false }
                            return p.type == .agent || p.type == .human
                        }
                        let parentsReady = executingParentIDs.isEmpty
                            || executingParentIDs.allSatisfy { execution.executionState(for: $0) == .succeeded }
                        if parentsReady {
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
                            .help("Run workflow from this node")
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
                .scaleEffect(canvas.viewport.zoom, anchor: .topLeading)
                .frame(
                    width: (canvasSize.width + 48) * canvas.viewport.zoom,
                    height: (canvasSize.height + 48) * canvas.viewport.zoom,
                    alignment: .topLeading
                )
            }
            .background(AppTheme.canvasBackground)
            .defaultScrollAnchor(.topLeading)
            .onScrollGeometryChange(for: CGPoint.self) { geo in
                geo.contentOffset
            } action: { _, newOffset in
                // Save user-driven scroll positions only once any pending
                // restore has been applied. This avoids clobbering a saved
                // offset with the ScrollView's "natural" resting offset
                // before restoration runs.
                guard canvas.viewport.pendingRestoreOffset == nil else { return }
                // UIScrollView truth is authoritative; if it's available, use
                // its contentOffset rather than the SwiftUI-reported value.
                let auth = underlyingScrollView?.contentOffset ?? newOffset
                canvas.viewport.scrollOffset = auth
            }
            .onAppear {
                canvas.viewport.canvasScrollProxy = scrollProxy
                applyPendingRestoreIfPossible()
            }
            .onChange(of: canvas.viewport.pendingRestoreOffset) { _, newValue in
                guard newValue != nil else { return }
                applyPendingRestoreIfPossible()
            }
            }

            ZoomControlsView(canvas: canvas)
                .padding(20)
        }
    }

    /// Schedules a restore of the persisted scroll offset onto the underlying
    /// UIScrollView. We retry a few times because contentSize may not be fully
    /// measured on the first layout pass — setContentOffset silently clamps
    /// values outside `[0, contentSize-bounds]`, so we re-issue until the
    /// ScrollView's own reading matches the target.
    private func applyPendingRestoreIfPossible() {
        guard let pending = canvas.viewport.pendingRestoreOffset else { return }
        guard let scrollView = underlyingScrollView else {
            // Safety net: if we still haven't discovered the scroll view
            // after a reasonable time, release the restore guard so user
            // scrolls don't get silently dropped forever.
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(750)) {
                if self.underlyingScrollView == nil,
                   canvas.viewport.pendingRestoreOffset != nil {
                    canvas.viewport.pendingRestoreOffset = nil
                }
            }
            return
        }
        canvas.viewport.scrollOffset = pending

        let delaysMs: [Int] = [0, 40, 100, 200, 350, 600]
        for (i, ms) in delaysMs.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) {
                guard let pending = canvas.viewport.pendingRestoreOffset else { return }
                // Don't clamp — this ScrollView has a negative origin (bounds
                // can start at x < 0), so the valid scroll range extends into
                // negative X values. UIScrollView will internally snap to its
                // own valid range if we overshoot, which is fine.
                scrollView.setContentOffset(pending, animated: false)

                if i == delaysMs.count - 1 {
                    canvas.viewport.scrollOffset = scrollView.contentOffset
                    canvas.viewport.pendingRestoreOffset = nil
                }
            }
        }
    }
}
