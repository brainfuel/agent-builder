import SwiftData
import SwiftUI

enum InspectorPanelTab: String, CaseIterable, Identifiable {
    case nodeDetails = "Node Details"
    case structureChat = "Structure Chat"

    var id: String { rawValue }
}

/// Right-hand inspector panel shell that hosts either the selected-node details or the structure chat.
struct InspectorPanelView: View {
    let canvas: CanvasViewModel
    @Bindable var structure: StructureViewModel

    @Binding var inspectorPanelTab: InspectorPanelTab
    @Binding var isInspectorPanelVisible: Bool

    let inspectorNodeBinding: Binding<OrgNode>?
    let availableProviders: () -> [APIKeyProvider]
    let providerIcon: (APIKeyProvider) -> String
    /// When true, shows both node details and structure chat as read-only
    /// (historical run context) so the graph can't be mutated out from under
    /// the historical snapshot.
    let isReadOnly: Bool

    let onPersistStructureChatState: () -> Void
    let onSaveNodeAsTemplate: (OrgNode) -> Void
    let onDeleteSelectedNode: () -> Void
    let onApplyTemplateFromStructureChat: (PresetHierarchyTemplate?, String) -> Void
    let onApplyUserStructureTemplate: (UserStructureTemplate) -> Void
    let onSaveCurrentAsStructureTemplate: (String) -> Void
    let onStartFreshStructureChat: () -> Void
    let onSubmitStructureChatTurn: () -> Void
    let onRunStructureChatDebugBroadcast: (StructureChatMessageEntry) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Inspector Tab", selection: $inspectorPanelTab) {
                    ForEach(InspectorPanelTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .help("Switch inspector tab")

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
                NodeDetailsInspectorContent(
                    inspectorNodeBinding: inspectorNodeBinding,
                    isReadOnly: isReadOnly,
                    onDelete: onDeleteSelectedNode,
                    onSaveAsTemplate: onSaveNodeAsTemplate
                )
            case .structureChat:
                VStack(spacing: 0) {
                    if isReadOnly {
                        readOnlyStructureChatBanner
                    }
                    StructureChatInspectorContent(
                        structure: structure,
                        availableProviders: availableProviders,
                        providerIcon: providerIcon,
                        onPersistStructureChatState: onPersistStructureChatState,
                        onApplyTemplateFromStructureChat: onApplyTemplateFromStructureChat,
                        onApplyUserStructureTemplate: onApplyUserStructureTemplate,
                        onSaveCurrentAsStructureTemplate: onSaveCurrentAsStructureTemplate,
                        onStartFreshStructureChat: onStartFreshStructureChat,
                        onSubmitStructureChatTurn: onSubmitStructureChatTurn,
                        onRunStructureChatDebugBroadcast: onRunStructureChatDebugBroadcast
                    )
                    .disabled(isReadOnly)
                }
            }
        }
        .background(AppTheme.surfaceSecondary)
    }

    private var readOnlyStructureChatBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.caption.weight(.semibold))
            Text("Historical — read-only")
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(Color.red)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.10))
        .overlay(
            Rectangle()
                .fill(Color.red.opacity(0.30))
                .frame(height: 1),
            alignment: .bottom
        )
    }
}

/// Narrow collapsed rail shown when the inspector is hidden; tapping expands it again.
struct InspectorToggleRail: View {
    @Binding var isInspectorPanelVisible: Bool

    var body: some View {
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
}

/// "Push request" payload handed up from NodeInspector when the user taps
/// a Connected Apps row. We use a state-driven view swap (rather than a real
/// NavigationLink) so the detail view is guaranteed to stay inside the
/// inspector pane — a nested NavigationStack inside NavigationSplitView's
/// detail column tends to get hijacked by the split view's implicit
/// navigation on Catalyst, pushing the detail onto the entire right pane.
struct ConnectedAppPushRequest: Identifiable {
    let id = UUID()
    let connectionName: String
    let tools: [MCPRemoteTool]
}

struct NodeDetailsInspectorContent: View {
    let inspectorNodeBinding: Binding<OrgNode>?
    let isReadOnly: Bool
    let onDelete: () -> Void
    let onSaveAsTemplate: (OrgNode) -> Void

    @State private var pushedApp: ConnectedAppPushRequest?

    var body: some View {
        VStack(spacing: 0) {
            if isReadOnly {
                readOnlyBanner
            }
            ZStack {
                rootContent
                    .opacity(pushedApp == nil ? 1 : 0)
                if let pushedApp, let inspectorNodeBinding {
                    pushedAppView(pushedApp, node: inspectorNodeBinding)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.22), value: pushedApp?.id)
        }
    }

    @ViewBuilder
    private var rootContent: some View {
        ScrollView {
            Group {
                if let inspectorNodeBinding {
                    if inspectorNodeBinding.wrappedValue.type == .input || inspectorNodeBinding.wrappedValue.type == .output {
                        FixedNodeInspector(node: inspectorNodeBinding)
                            .padding(20)
                    } else {
                        NodeInspector(
                            node: inspectorNodeBinding,
                            onDelete: onDelete,
                            onSaveAsTemplate: { onSaveAsTemplate(inspectorNodeBinding.wrappedValue) },
                            headerTitle: "Node Details",
                            onPushConnectedApp: { request in
                                pushedApp = request
                            }
                        )
                            .padding(20)
                    }
                } else {
                    ContentUnavailableView(
                        "No Node Selected",
                        systemImage: "cursorarrow.click",
                        description: Text(isReadOnly
                            ? "Select a node to view its historical details."
                            : "Select a node to edit schema and details."
                        )
                    )
                        .padding(20)
                }
            }
            .disabled(isReadOnly)
        }
    }

    @ViewBuilder
    private func pushedAppView(_ request: ConnectedAppPushRequest, node: Binding<OrgNode>) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    pushedApp = nil
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(uiColor: .tertiarySystemFill))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                .help("Back to Node Details")

                Text(request.connectionName)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ConnectedAppToolsDetail(
                connectionName: request.connectionName,
                tools: request.tools,
                assignedTools: Binding(
                    get: { node.wrappedValue.assignedTools },
                    set: { node.wrappedValue.assignedTools = $0 }
                ),
                onGrantWorkspaceAccess: {
                    node.wrappedValue.securityAccess.insert(.workspaceRead)
                    node.wrappedValue.securityAccess.insert(.workspaceWrite)
                }
            )
            .disabled(isReadOnly)
        }
        .background(AppTheme.surfaceSecondary)
    }

    private var readOnlyBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.caption.weight(.semibold))
            Text("Historical — read-only")
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(Color.red)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.10))
        .overlay(
            Rectangle()
                .fill(Color.red.opacity(0.30))
                .frame(height: 1),
            alignment: .bottom
        )
    }
}

struct StructureChatInspectorContent: View {
    @Bindable var structure: StructureViewModel
    let availableProviders: () -> [APIKeyProvider]
    let providerIcon: (APIKeyProvider) -> String

    let onPersistStructureChatState: () -> Void
    let onApplyTemplateFromStructureChat: (PresetHierarchyTemplate?, String) -> Void
    let onApplyUserStructureTemplate: (UserStructureTemplate) -> Void
    let onSaveCurrentAsStructureTemplate: (String) -> Void
    let onStartFreshStructureChat: () -> Void
    let onSubmitStructureChatTurn: () -> Void
    let onRunStructureChatDebugBroadcast: (StructureChatMessageEntry) -> Void

    @Query(sort: \UserStructureTemplate.updatedAt, order: .reverse)
    private var userStructureTemplates: [UserStructureTemplate]

    @AppStorage("hiddenPresetStructureTemplateIDs") private var hiddenPresetIDsRaw: String = ""

    @State private var isShowingSaveTemplateAlert = false
    @State private var newTemplateName = ""
    @State private var isShowingEditTemplatesSheet = false

    private var hiddenPresetIDs: Set<String> {
        Set(hiddenPresetIDsRaw.split(separator: ",").map(String.init))
    }

    private var visiblePresetTemplates: [PresetHierarchyTemplate] {
        PresetHierarchyTemplate.allCases.filter { !hiddenPresetIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(availableProviders(), id: \.self) { provider in
                        Button {
                            structure.structureChatProvider = provider
                            onPersistStructureChatState()
                        } label: {
                            if structure.structureChatProvider == provider {
                                Label(provider.label, systemImage: "checkmark")
                            } else {
                                Text(provider.label)
                            }
                        }
                    }
                } label: {
                    Label("Model: \(structure.structureChatProvider.label)", systemImage: providerIcon(structure.structureChatProvider))
                        .font(.caption)
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Pick the model for structure chat")

                Menu {
                    Button("Simple Task") {
                        onApplyTemplateFromStructureChat(nil, "Simple Task")
                    }
                    ForEach(visiblePresetTemplates) { template in
                        Button(template.title) {
                            onApplyTemplateFromStructureChat(template, template.title)
                        }
                    }

                    ForEach(userStructureTemplates) { template in
                        Button(template.name) {
                            onApplyUserStructureTemplate(template)
                        }
                    }

                    Divider()
                    Button {
                        newTemplateName = ""
                        isShowingSaveTemplateAlert = true
                    } label: {
                        Label("Save current as template…", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        isShowingEditTemplatesSheet = true
                    } label: {
                        Label("Edit templates…", systemImage: "pencil")
                    }
                    .disabled(userStructureTemplates.isEmpty && visiblePresetTemplates.isEmpty)
                } label: {
                    Label("Templates", systemImage: "square.grid.2x2")
                        .font(.caption)
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Apply a preset or saved team template")
                .alert("Save Template", isPresented: $isShowingSaveTemplateAlert) {
                    TextField("Template name", text: $newTemplateName)
                    Button("Save") {
                        let trimmed = newTemplateName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        onSaveCurrentAsStructureTemplate(trimmed)
                        newTemplateName = ""
                    }
                    .disabled(newTemplateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Cancel", role: .cancel) {
                        newTemplateName = ""
                    }
                } message: {
                    Text("Save the current team structure as a reusable template.")
                }
                .sheet(isPresented: $isShowingEditTemplatesSheet) {
                    EditStructureTemplatesSheet(
                        templates: userStructureTemplates,
                        visiblePresets: visiblePresetTemplates,
                        onHidePreset: { preset in
                            var current = hiddenPresetIDs
                            current.insert(preset.id)
                            hiddenPresetIDsRaw = current.sorted().joined(separator: ",")
                        },
                        onDismiss: { isShowingEditTemplatesSheet = false }
                    )
                    .frame(minWidth: 420, minHeight: 360)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            HStack {
                Spacer()
                Button("Clear", role: .destructive) {
                    onStartFreshStructureChat()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .font(.caption.weight(.semibold))
                .disabled(structure.isStructureChatRunning || structure.structureChatMessages.isEmpty)
                .help("Clear the structure chat history")
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
                            StructureChatMessageRow(
                                entry: entry,
                                structure: structure,
                                onRunDebugBroadcast: { onRunStructureChatDebugBroadcast(entry) }
                            )
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
                        .help("Describe the structure change you want")

                    Button {
                        onSubmitStructureChatTurn()
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
                    .help("Send structure chat message")
                }
            }
            .padding(12)
        }
    }
}

struct StructureChatMessageRow: View {
    let entry: StructureChatMessageEntry
    let structure: StructureViewModel
    let onRunDebugBroadcast: () -> Void

    var body: some View {
        let isUser = entry.role == .user
        let debugJSON = entry.role == .assistant ? structureDebugJSONIfPresent(in: entry.text) : nil
        let isDebugRunning = structure.structureChatDebugRunningMessageIDs.contains(entry.id)
        let isDebugCompleted = structure.structureChatDebugCompletedMessageIDs.contains(entry.id)
        HStack {
            if isUser { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(entry.role == .user ? "You" : "Structure Copilot")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    #if DEBUG
                    if isUser {
                        Button {
                            onRunDebugBroadcast()
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
                    #endif
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

/// Sheet for renaming / deleting user-saved structure templates.
struct EditStructureTemplatesSheet: View {
    let templates: [UserStructureTemplate]
    let visiblePresets: [PresetHierarchyTemplate]
    let onHidePreset: (PresetHierarchyTemplate) -> Void
    let onDismiss: () -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var editingName: [String: String] = [:]

    var body: some View {
        NavigationStack {
            Group {
                if templates.isEmpty && visiblePresets.isEmpty {
                    ContentUnavailableView(
                        "No Templates",
                        systemImage: "square.grid.2x2",
                        description: Text("Save a team structure from the Templates menu to edit it here.")
                    )
                } else {
                    List {
                        Section("Templates") {
                            ForEach(visiblePresets) { preset in
                                row(
                                    key: "preset:\(preset.id)",
                                    currentName: preset.title,
                                    onRename: { newName in materializePreset(preset, newName: newName) },
                                    onDelete: { onHidePreset(preset) }
                                )
                            }
                            ForEach(templates) { template in
                                row(
                                    key: "user:\(template.id.uuidString)",
                                    currentName: template.name,
                                    onRename: { newName in rename(template, to: newName) },
                                    onDelete: { delete(template) }
                                )
                            }
                        }
                    }
                }
            }
            .navigationTitle("Edit Templates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .accessibilityLabel("Close")
                    .help("Close")
                }
            }
        }
    }

    @ViewBuilder
    private func row(
        key: String,
        currentName: String,
        onRename: @escaping (String) -> Void,
        onDelete: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            TextField(
                "Template name",
                text: Binding(
                    get: { editingName[key] ?? currentName },
                    set: { editingName[key] = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)
            .onSubmit { commitPending(key: key, currentName: currentName, onRename: onRename) }
            .help("Rename this template")

            Button {
                commitPending(key: key, currentName: currentName, onRename: onRename)
            } label: {
                Label("Save", systemImage: "checkmark")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!isRenamePending(key: key, currentName: currentName))
            .help("Save new name")

            Button(role: .destructive) {
                onDelete()
                editingName[key] = nil
            } label: {
                Label("Delete", systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Delete this template")
        }
        .padding(.vertical, 4)
    }

    private func isRenamePending(key: String, currentName: String) -> Bool {
        guard let pending = editingName[key] else { return false }
        let trimmed = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != currentName
    }

    private func commitPending(key: String, currentName: String, onRename: (String) -> Void) {
        guard let pending = editingName[key] else { return }
        let trimmed = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != currentName else { return }
        onRename(trimmed)
        editingName[key] = nil
    }

    private func rename(_ template: UserStructureTemplate, to newName: String) {
        template.name = newName
        template.updatedAt = Date()
        try? modelContext.save()
    }

    private func delete(_ template: UserStructureTemplate) {
        modelContext.delete(template)
        try? modelContext.save()
    }

    /// Renaming a built-in preset "materializes" it as a user-owned template (captured
    /// from the preset's snapshot) and hides the original preset, so it becomes a single
    /// editable/deletable entry going forward.
    private func materializePreset(_ preset: PresetHierarchyTemplate, newName: String) {
        let snapshot = preset.snapshot()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let template = UserStructureTemplate(name: newName, snapshotData: data)
        modelContext.insert(template)
        try? modelContext.save()
        onHidePreset(preset)
    }
}
