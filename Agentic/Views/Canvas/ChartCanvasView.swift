import SwiftUI

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
                .scaleEffect(canvas.viewport.zoom, anchor: .topLeading)
                .frame(
                    width: (canvasSize.width + 48) * canvas.viewport.zoom,
                    height: (canvasSize.height + 48) * canvas.viewport.zoom,
                    alignment: .topLeading
                )
            }
            .background(AppTheme.canvasBackground)
            .onAppear { canvas.viewport.canvasScrollProxy = scrollProxy }
            }

            ZoomControlsView(canvas: canvas)
                .padding(20)
        }
    }
}
