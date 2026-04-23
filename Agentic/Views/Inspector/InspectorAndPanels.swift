import SwiftUI
import SwiftData

struct NodeInspector: View {
    private struct ConnectedAppEntry: Identifiable {
        let connection: MCPServerConnection
        let tools: [MCPRemoteTool]
        let status: MCPServerManager.ConnectionStatus?

        var id: UUID { connection.id }
        var hasTools: Bool { !tools.isEmpty }

        var statusText: String {
            if hasTools {
                return "\(tools.count) tool\(tools.count == 1 ? "" : "s")"
            }
            if let status {
                switch status {
                case .connecting:
                    return "Connecting…"
                case .awaitingOAuth:
                    return "Authorizing…"
                case .failed:
                    return "No tools discovered (connection failed)"
                case .connected:
                    return "No tools discovered"
                case .disconnected:
                    return "Disconnected"
                }
            }
            return "No tools discovered yet"
        }
    }

    @Binding var node: OrgNode
    @Query private var savedServers: [MCPServerConnection]
    @EnvironmentObject private var mcpManager: MCPServerManager
    let onDelete: () -> Void
    var onSaveAsTemplate: (() -> Void)?
    var headerTitle: String = "Node Details"

    @State private var isShowingDeleteNodeConfirmation = false

    private let editableTypes: [NodeType] = [.human, .agent]

    private var connectedServerTools: [ConnectedAppEntry] {
        savedServers
            .filter(\.isEnabled)
            .map { connection in
                let tools = toolsForServer(connection.id)
                let status = mcpManager.connectionStatus[connection.id]
                return ConnectedAppEntry(connection: connection, tools: tools, status: status)
            }
            .sorted { lhs, rhs in
                lhs.connection.name.localizedCaseInsensitiveCompare(rhs.connection.name) == .orderedAscending
            }
    }

    private func toolsForServer(_ connectionID: UUID) -> [MCPRemoteTool] {
        let liveTools = mcpManager.discoveredTools[connectionID] ?? []
        let sourceTools = liveTools.isEmpty ? mcpManager.cachedTools(for: connectionID) : liveTools
        return sourceTools.sorted { lhs, rhs in
            let lhsLabel = lhs.title ?? lhs.name
            let rhsLabel = rhs.title ?? rhs.name
            return lhsLabel.localizedCaseInsensitiveCompare(rhsLabel) == .orderedAscending
        }
    }

    private func hasAllAssigned(_ tools: [MCPRemoteTool]) -> Bool {
        !tools.isEmpty && tools.allSatisfy { node.assignedTools.contains($0.name) }
    }

    private func hasAnyAssigned(_ tools: [MCPRemoteTool]) -> Bool {
        tools.contains { node.assignedTools.contains($0.name) }
    }

    private func setAssignment(for tools: [MCPRemoteTool], enabled: Bool) {
        if enabled {
            for tool in tools {
                node.assignedTools.insert(tool.name)
            }
            // Connected app tools require workspace read+write access.
            node.securityAccess.insert(.workspaceRead)
            node.securityAccess.insert(.workspaceWrite)
        } else {
            for tool in tools {
                node.assignedTools.remove(tool.name)
            }
        }
    }

    var body: some View {
        Group {
            // Belt-and-braces guard so full inspector never renders for fixed anchors.
            if node.type == .input || node.type == .output {
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 10) {
                        Text(headerTitle)
                            .font(.title2.bold())
                        Spacer()
                        if let onSaveAsTemplate {
                            Button {
                                onSaveAsTemplate()
                            } label: {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.body.weight(.semibold))
                            }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Save as Node Template")
                            .help("Save this node as a reusable template")
                        }
                        Button(role: .destructive) {
                            isShowingDeleteNodeConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.body.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Delete")
                        .help("Delete this node")
                        .confirmationDialog(
                            "Delete Node?",
                            isPresented: $isShowingDeleteNodeConfirmation
                        ) {
                            Button("Delete Node", role: .destructive) {
                                onDelete()
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("This will permanently delete \(node.name.isEmpty ? "this node" : "\u{201C}\(node.name)\u{201D}") and any links attached to it.")
                        }
                    }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 14) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Display Name")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                TextField("Display Name", text: $node.name)
                                    .textFieldStyle(.roundedBorder)
                                    .help("Node display name")
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Role Title")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                TextField("Role Title", text: $node.title)
                                    .textFieldStyle(.roundedBorder)
                                    .help("Role title for this node")
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Department")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                TextField("Department", text: $node.department)
                                    .textFieldStyle(.roundedBorder)
                                    .help("Department or group label")
                            }
                        }
                    } label: {
                        Text("Identity")
                    }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 14) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Node Type")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Picker("Node Type", selection: $node.type) {
                                    ForEach(editableTypes) { type in
                                        Text(type.label).tag(type)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .help("Pick node type")
                            }

                            if node.type == .agent {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Model")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Picker("Model", selection: $node.provider) {
                                        ForEach(LLMProvider.allCases) { provider in
                                            Text(provider.label).tag(provider)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .help("Pick the model provider")
                                }
                            }
                        }
                    } label: {
                        Text("Type")
                    }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Description")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            TextEditor(text: $node.roleDescription)
                                .frame(minHeight: 110)
                                .padding(6)
                                .background(AppTheme.surfacePrimary)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .help("Describe this node's role and behavior")
                        }
                    } label: {
                        Text("Role Description")
                    }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 14) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Output Schema")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                TextField("e.g. Research Brief, Interview Scorecard", text: $node.outputSchema)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.callout)
                                    .help("Name of the output schema")
                                    .onChange(of: node.outputSchema) { _, newSchema in
                                        let suggested = DefaultSchema.defaultDescription(for: newSchema)
                                        if !suggested.isEmpty {
                                            node.outputSchemaDescription = suggested
                                        }
                                    }
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Output Format Description")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                TextEditor(text: $node.outputSchemaDescription)
                                    .font(.caption)
                                    .frame(minHeight: 60, maxHeight: 100)
                                    .scrollContentBackground(.hidden)
                                    .padding(6)
                                    .background(Color.gray.opacity(0.08))
                                    .cornerRadius(6)
                                    .help("Describe the expected output format")
                            }
                        }
                    } label: {
                        Text("Typed Handoffs")
                    }

                    // Preset Roles removed — node templates now pre-fill role descriptions on creation.
                    // Security Access removed — workspaceRead is auto-granted by Connected Apps
                    // or Global Tool Access; webAccess is handled by the Web Search tool toggle.

                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(MCPToolRegistry.categories, id: \.self) { category in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(category)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    ForEach(MCPToolRegistry.tools(in: category)) { tool in
                                        Toggle(isOn: Binding(
                                            get: { node.assignedTools.contains(tool.id) },
                                            set: { enabled in
                                                if enabled {
                                                    node.assignedTools.insert(tool.id)
                                                } else {
                                                    node.assignedTools.remove(tool.id)
                                                }
                                            }
                                        )) {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(tool.name)
                                                    .font(.callout)
                                                Text(tool.description)
                                                    .font(.caption2)
                                                    .foregroundStyle(.tertiary)
                                            }
                                        }
                                        .help("Toggle \(tool.name) for this node")
                                    }
                                }
                            }

                            // Only show per-node Connected Apps section when global access is off
                            if !mcpManager.globalToolAccess {
                                Divider()
                                    .padding(.vertical, 4)

                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Connected Apps")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)

                                    if connectedServerTools.isEmpty {
                                        Text("No connected app tools found. Connect an MCP server in Tool Catalog to enable app-level switches here.")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    } else {
                                        ForEach(connectedServerTools) { entry in
                                            Toggle(
                                                isOn: Binding(
                                                    get: { hasAllAssigned(entry.tools) },
                                                    set: { enabled in
                                                        setAssignment(for: entry.tools, enabled: enabled)
                                                    }
                                                )
                                            ) {
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(entry.connection.name)
                                                        .font(.callout)
                                                    Text("\(entry.statusText)\(entry.hasTools && hasAnyAssigned(entry.tools) && !hasAllAssigned(entry.tools) ? " (partially assigned)" : "")")
                                                        .font(.caption2)
                                                        .foregroundStyle(entry.hasTools ? .tertiary : .secondary)
                                                }
                                            }
                                            .disabled(!entry.hasTools)
                                            .help("Assign \(entry.connection.name) tools to this node")
                                        }
                                    }
                                }
                            } else if !connectedServerTools.isEmpty {
                                Divider()
                                    .padding(.vertical, 4)

                                Text("Connected app tools are available globally. Manage in Tool Catalog.")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    } label: {
                        Text("Tools")
                    }
                }
            }
        }
    }
}

struct FixedNodeInspector: View {
    @Binding var node: OrgNode

    private var descriptionText: String {
        switch node.type {
        case .input:
            return "Fixed entry point for all task inputs."
        case .output:
            return "Fixed exit point for all task outputs."
        case .agent, .human:
            return ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Node Details")
                .font(.title2.bold())

            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Display Name")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField(
                            "Display Name",
                            text: .constant(
                                node.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? node.type.label
                                    : node.name
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .disabled(true)
                    }
                }
            } label: {
                Text("Identity")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Description")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(descriptionText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 10)
                        .background(AppTheme.surfacePrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            } label: {
                Text("Role Description")
            }

            Spacer(minLength: 0)
        }
    }
}

struct CoordinatorTraceResolutionPresentation {
    let title: String
    let detail: String
    let buttonTitle: String
}

enum TraceResolutionAction {
    case grantPermission(nodeID: UUID, permission: SecurityAccess)
}

struct TraceResolutionRecommendation {
    let presentation: CoordinatorTraceResolutionPresentation
    let action: TraceResolutionAction
}

struct RunFromHereSheet: View {
    let nodeName: String
    @Binding var prompt: String
    let onRun: () -> Void
    let onCancel: () -> Void
    @FocusState private var isPromptFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "play.fill")
                        .font(.title3)
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Run from \(nodeName)")
                            .font(.headline)
                        Text("Re-run the pipeline starting at this node.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Additional context (optional)")
                        .font(.subheadline.weight(.medium))
                    Text("Provide extra instructions or information to help the AI succeed — e.g. correct data, clarifications, or constraints.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextEditor(text: $prompt)
                        .font(.body)
                        .frame(minHeight: 140, maxHeight: .infinity)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(AppTheme.surfaceSecondary)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color(uiColor: .separator), lineWidth: 0.5)
                        )
                        .focused($isPromptFocused)
                        .help("Add extra context for this run")
                }
                .frame(maxHeight: .infinity, alignment: .top)

                HStack(spacing: 12) {
                    Spacer()
                    Button("Cancel") { onCancel() }
                        .buttonStyle(.bordered)
                        .help("Cancel run-from-here")
                    Button {
                        onRun()
                    } label: {
                        Label("Run", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .help("Run workflow from this node")
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear { isPromptFocused = true }
    }
}

struct CoordinatorTraceRow: View {
    let stepNumber: Int
    let step: CoordinatorTraceStep
    let resolution: CoordinatorTraceResolutionPresentation?
    let onResolve: (() -> Void)?
    let onRunFromHere: ((UUID) -> Void)?
    var canRunFromNode: ((UUID) -> Bool)? = nil
    @State private var isExpanded = false
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

                Button {
                    copyMarkdownToClipboard(stepClipboardMarkdown)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy trace section")
                .help("Copy this trace step")

                if let tokenText = step.tokenText {
                    HStack(spacing: 2) {
                        Image(systemName: "circle.grid.3x3.fill")
                            .font(.system(size: 7))
                        Text(tokenText)
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }

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

            if let resolution {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                        Text(resolution.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    Text(resolution.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if let onResolve {
                        Button {
                            onResolve()
                        } label: {
                            Label(resolution.buttonTitle, systemImage: "checkmark.shield")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .help(resolution.buttonTitle)
                    }
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.orange.opacity(0.08))
                )
            }

            if let summary = step.summary {
                VStack(alignment: .leading, spacing: 4) {
                    SelectableText(markdown: summary, font: .preferredFont(forTextStyle: .caption1))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(maxHeight: isExpanded ? .none : 72, alignment: .top)
                        .clipped()

                    HStack(spacing: 12) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isExpanded.toggle()
                            }
                        } label: {
                            Text(isExpanded ? "Show less" : "Show more")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(AppTheme.brandTint)
                        }
                        .buttonStyle(.plain)
                        .help(isExpanded ? "Collapse summary" : "Expand summary")

                        if let onRunFromHere,
                           let assignedNodeID = step.assignedNodeID,
                           canRunFromNode?(assignedNodeID) ?? true {
                            Button {
                                onRunFromHere(assignedNodeID)
                            } label: {
                                Label("Run from here", systemImage: "play.fill")
                                    .font(.caption2.weight(.semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .tint(.green)
                            .help("Re-run the pipeline starting from this node")
                        }
                    }
                }
            }

        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppTheme.surfacePrimary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppTheme.cardBorder, lineWidth: 1)
        )
    }

    private var stepClipboardMarkdown: String {
        var sections: [String] = []
        sections.append("**\(step.assignedNodeName) • \(step.status.label)**")
        sections.append(step.objective)
        if let summary = step.summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(summary)
        }
        return sections.joined(separator: "\n\n")
    }
}

// MARK: - Raw API Trace Row

struct RawAPITraceRow: View {
    let stepNumber: Int
    let step: CoordinatorTraceStep

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(stepNumber). \(step.assignedNodeName)")
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)

                Spacer()

                if let modelID = step.modelID {
                    Text(modelID)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if let input = step.inputTokens, let output = step.outputTokens, input + output > 0 {
                    Text("\(CoordinatorTraceStep.formatTokens(input + output)) tokens")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let systemPrompt = step.systemPrompt, !systemPrompt.isEmpty {
                apiDetailBlock(title: "System Prompt", content: systemPrompt)
            }
            if let userPrompt = step.userPrompt, !userPrompt.isEmpty {
                apiDetailBlock(title: "User Prompt", content: userPrompt)
            }
            if let rawResponse = step.rawResponse, !rawResponse.isEmpty {
                apiDetailBlock(title: "Raw Response", content: rawResponse)
            }

            if step.systemPrompt == nil, step.userPrompt == nil, step.rawResponse == nil {
                Text("No API data recorded for this step.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppTheme.surfacePrimary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppTheme.cardBorder, lineWidth: 1)
        )
    }

    private func apiDetailBlock(title: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    copyMarkdownToClipboard(content)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Copy \(title)")
            }
            SelectablePlainText(
                text: content,
                font: .monospacedSystemFont(ofSize: 11, weight: .regular),
                textColor: UIColor.label.withAlphaComponent(0.8)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(AppTheme.surfaceSecondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color(uiColor: .separator).opacity(0.3), lineWidth: 0.5)
            )
        }
    }
}

// MARK: - Node Template Library

struct NodeTemplateLibrarySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \UserNodeTemplate.updatedAt, order: .reverse)
    private var templates: [UserNodeTemplate]
    let onInsert: ((UserNodeTemplate) -> Void)?

    init(onInsert: ((UserNodeTemplate) -> Void)? = nil) {
        self.onInsert = onInsert
    }

    var body: some View {
        NavigationStack {
            Group {
                if templates.isEmpty {
                    ContentUnavailableView(
                        "No Node Templates",
                        systemImage: "rectangle.stack",
                        description: Text("Select a node in the editor and tap the save button to create a reusable node template.")
                    )
                } else {
                    List {
                        Section {
                            ForEach(templates) { template in
                                NavigationLink {
                                    NodeTemplateEditorForm(template: template)
                                } label: {
                                    nodeTemplateRow(template)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        modelContext.delete(template)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .contextMenu {
                                    if let onInsert {
                                        Button {
                                            onInsert(template)
                                        } label: {
                                            Label("Insert into Graph", systemImage: "plus.circle")
                                        }
                                    }
                                    Button {
                                        duplicateTemplate(template)
                                    } label: {
                                        Label("Duplicate", systemImage: "plus.square.on.square")
                                    }
                                    Button(role: .destructive) {
                                        modelContext.delete(template)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        } header: {
                            Text("My Node Templates")
                        }

                        Section {
                            ForEach(NodeTemplate.allCases) { builtIn in
                                HStack(spacing: 12) {
                                    Image(systemName: builtIn.icon)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 28)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(builtIn.label)
                                            .font(.subheadline.weight(.medium))
                                        Text(builtIn.title)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        } header: {
                            Text("Built-in")
                        }
                    }
                }
            }
            .navigationTitle("Node Templates")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                    }
                    .help("Close node templates")
                }
            }
        }
    }

    private func nodeTemplateRow(_ template: UserNodeTemplate) -> some View {
        HStack(spacing: 12) {
            Image(systemName: template.icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(template.label)
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 6) {
                    Text(template.title)
                    Text("·")
                    Text(template.department)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func duplicateTemplate(_ source: UserNodeTemplate) {
        let copy = UserNodeTemplate(
            label: "\(source.label) Copy",
            icon: source.icon,
            name: source.name,
            title: source.title,
            department: source.department,
            nodeTypeRaw: source.nodeTypeRaw,
            providerRaw: source.providerRaw,
            roleDescription: source.roleDescription,
            outputSchema: source.outputSchema,
            outputSchemaDescription: source.outputSchemaDescription,
            securityAccessRaw: source.securityAccessRaw,
            assignedToolsRaw: source.assignedToolsRaw
        )
        modelContext.insert(copy)
    }
}

/// Wraps NodeInspector to edit a UserNodeTemplate by maintaining a transient OrgNode
/// and syncing changes back to the SwiftData model.
struct NodeTemplateEditorForm: View {
    @Bindable var template: UserNodeTemplate
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var node: OrgNode
    @State private var isShowingDeleteConfirmation = false

    private static let iconChoices = [
        "star", "bolt", "shield.checkered", "magnifyingglass",
        "exclamationmark.bubble", "checkmark.seal", "text.justify.left",
        "arrow.triangle.branch", "person.badge.clock", "gearshape",
        "brain.head.profile", "doc.text", "network", "cpu",
        "lock.shield", "eye", "lightbulb", "wrench.and.screwdriver"
    ]

    init(template: UserNodeTemplate) {
        self.template = template
        self._node = State(initialValue: OrgNode(
            id: UUID(),
            name: template.name,
            title: template.title,
            department: template.department,
            type: NodeType(rawValue: template.nodeTypeRaw) ?? .agent,
            provider: LLMProvider(rawValue: template.providerRaw) ?? .chatGPT,
            roleDescription: template.roleDescription,
            inputSchema: "",
            outputSchema: template.outputSchema,
            outputSchemaDescription: template.outputSchemaDescription,
            selectedRoles: [],
            securityAccess: Set(template.securityAccessRaw.compactMap { SecurityAccess(rawValue: $0) }),
            assignedTools: Set(template.assignedToolsRaw),
            position: .zero
        ))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Template-specific fields: icon picker and label
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Icon")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Menu {
                                    ForEach(Self.iconChoices, id: \.self) { icon in
                                        Button {
                                            template.icon = icon
                                            template.updatedAt = Date()
                                        } label: {
                                            Label(icon, systemImage: icon)
                                        }
                                    }
                                } label: {
                                    Image(systemName: template.icon)
                                        .font(.title3)
                                        .frame(width: 36, height: 36)
                                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                                }
                                .help("Pick template icon")
                            }
                            Spacer()
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Node Template Label")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            TextField("Node Template Label", text: $template.label)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: template.label) { _, _ in template.updatedAt = Date() }
                                .help("Template label")
                        }
                    }
                } label: {
                    Text("Node Template Identity")
                }

                // Reuse the NodeInspector for all node properties
                NodeInspector(
                    node: $node,
                    onDelete: { isShowingDeleteConfirmation = true },
                    headerTitle: "Node Template Details"
                )
            }
            .padding(20)
        }
        .navigationTitle("Edit Node Template")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete Node Template?", isPresented: $isShowingDeleteConfirmation) {
            Button("Delete Node Template", role: .destructive) {
                modelContext.delete(template)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete the \"\(template.label)\" node template.")
        }
        .onChange(of: node.name) { _, val in template.name = val; template.updatedAt = Date() }
        .onChange(of: node.title) { _, val in template.title = val; template.updatedAt = Date() }
        .onChange(of: node.department) { _, val in template.department = val; template.updatedAt = Date() }
        .onChange(of: node.type) { _, val in template.nodeTypeRaw = val.rawValue; template.updatedAt = Date() }
        .onChange(of: node.provider) { _, val in template.providerRaw = val.rawValue; template.updatedAt = Date() }
        .onChange(of: node.roleDescription) { _, val in template.roleDescription = val; template.updatedAt = Date() }
        .onChange(of: node.outputSchema) { _, val in template.outputSchema = val; template.updatedAt = Date() }
        .onChange(of: node.outputSchemaDescription) { _, val in template.outputSchemaDescription = val; template.updatedAt = Date() }
        .onChange(of: node.securityAccess) { _, val in template.securityAccessRaw = val.map(\.rawValue); template.updatedAt = Date() }
        .onChange(of: node.assignedTools) { _, val in template.assignedToolsRaw = val.sorted(); template.updatedAt = Date() }
    }
}

struct HumanInboxPanel: View {
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
                    GroupBox("Pending Human Task") {
                        if let pendingPacket {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(pendingPacket.assignedNodeName)
                                    .font(.headline)
                                Text(pendingPacket.objective)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)

                                Text("Expected output schema: \(pendingPacket.requiredOutputSchema)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                TextField("Actor identity", text: $actorIdentity)
                                    .textFieldStyle(.roundedBorder)
                                    .help("Your name or identifier")

                                TextField("Decision note (optional)", text: $decisionNote)
                                    .textFieldStyle(.roundedBorder)
                                    .help("Add an optional note for this decision")

                                HStack(spacing: 10) {
                                    Button("Approve & Continue") {
                                        onApprove()
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .help("Approve and continue the run")

                                    Button("Reject") {
                                        onReject()
                                    }
                                    .buttonStyle(.bordered)
                                    .help("Reject this human task")

                                    Button("Needs Info") {
                                        onNeedsInfo()
                                    }
                                    .buttonStyle(.bordered)
                                    .help("Request more information")
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
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.headline.weight(.semibold))
                    }
                    .accessibilityLabel("Close")
                    .keyboardShortcut(.escape, modifiers: [])
                    .help("Close Human Inbox")
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

struct TaskResultsPanel: View {
    let document: GraphDocument?
    let onClose: () -> Void

    var body: some View {
        // Access executionStateData directly in body so SwiftData observation
        // picks up changes that arrive after the sheet opens.
        let stateData = document?.executionStateData
        let bundle = stateData.flatMap { try? JSONDecoder().decode(CoordinatorExecutionStateBundle.self, from: $0) }
        let latestRun = bundle?.latestRun

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let document {
                        Text(document.title?.isEmpty == false ? (document.title ?? "") : "Task Results")
                            .font(.headline)
                        Text(document.goal?.isEmpty == false ? (document.goal ?? "") : "No goal set.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if let run = latestRun {
                        HStack(spacing: 8) {
                            Text("Run \(run.runID)")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(AppTheme.brandTint.opacity(0.12), in: Capsule())
                            Text("\(run.succeededCount)/\(run.results.count) tasks succeeded")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(run.finishedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        ForEach(run.results) { result in
                            TaskResultCard(result: result)
                        }
                    } else {
                        Text("No completed results for this task yet.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
            .textSelection(.enabled)
            .navigationTitle("Task Results")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.headline.weight(.semibold))
                    }
                    .accessibilityLabel("Close")
                    .keyboardShortcut(.escape, modifiers: [])
                    .help("Close task results")
                }
            }
        }
    }
}

struct TaskResultCard: View {
    let result: CoordinatorTaskResult
    @State private var isExpanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(result.assignedNodeName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(result.completed ? "Succeeded" : "Failed")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(result.completed ? .green : .red)
                Button {
                    copyMarkdownToClipboard(resultClipboardMarkdown)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy result section")
                .help("Copy this result")
            }

            SelectableText(markdown: result.summary, font: .preferredFont(forTextStyle: .caption1))
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(maxHeight: isExpanded ? .none : 100, alignment: .top)
                .clipped()

            HStack(spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Text(isExpanded ? "Show less" : "Show more")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Collapse result" : "Expand result")
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppTheme.surfaceSecondary)
        )
    }

    private var resultClipboardMarkdown: String {
        "**\(result.assignedNodeName) • \(result.completed ? "Succeeded" : "Failed")**\n\n\(result.summary)"
    }
}

struct SelectableResponsePanel: View {
    let title: String
    let markdown: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SelectableText(markdown: markdown)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        copyMarkdownToClipboard(markdown)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .help("Copy response")
                }

                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                    .help("Close panel")
                }
            }
        }
    }
}

struct InboxAttentionBadge: View {
    let count: Int
    @State private var isPulsing = false

    var body: some View {
        Text(badgeText)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(Circle().fill(Color.red))
            .scaleEffect(isPulsing ? 1.08 : 0.92)
            .opacity(isPulsing ? 1 : 0.82)
            .animation(
                .easeInOut(duration: 0.85).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear {
                isPulsing = true
            }
    }

    private var badgeText: String {
        if count > 9 { return "9+" }
        return "\(count)"
    }
}

struct HumanInboxButtonLabel: View {
    let pendingCount: Int
    var showsTitle: Bool = true

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                if pendingCount > 0 {
                    InboxAttentionBadge(count: pendingCount)
                } else {
                    Image(systemName: "tray.full")
                        .font(.body.weight(.semibold))
                }
            }
            .frame(width: 18, height: 18)

            if showsTitle {
                Text("Human Inbox")
            }
        }
    }
}
