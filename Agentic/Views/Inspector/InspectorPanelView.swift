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

    let onPersistStructureChatState: () -> Void
    let onSaveNodeAsTemplate: (OrgNode) -> Void
    let onDeleteSelectedNode: () -> Void
    let onApplyTemplateFromStructureChat: (PresetHierarchyTemplate?, String) -> Void
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
                    onDelete: onDeleteSelectedNode,
                    onSaveAsTemplate: onSaveNodeAsTemplate
                )
            case .structureChat:
                StructureChatInspectorContent(
                    structure: structure,
                    availableProviders: availableProviders,
                    providerIcon: providerIcon,
                    onPersistStructureChatState: onPersistStructureChatState,
                    onApplyTemplateFromStructureChat: onApplyTemplateFromStructureChat,
                    onStartFreshStructureChat: onStartFreshStructureChat,
                    onSubmitStructureChatTurn: onSubmitStructureChatTurn,
                    onRunStructureChatDebugBroadcast: onRunStructureChatDebugBroadcast
                )
            }
        }
        .background(AppTheme.surfaceSecondary)
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

struct NodeDetailsInspectorContent: View {
    let inspectorNodeBinding: Binding<OrgNode>?
    let onDelete: () -> Void
    let onSaveAsTemplate: (OrgNode) -> Void

    var body: some View {
        ScrollView {
            if let inspectorNodeBinding {
                if inspectorNodeBinding.wrappedValue.type == .input || inspectorNodeBinding.wrappedValue.type == .output {
                    FixedNodeInspector(node: inspectorNodeBinding)
                        .padding(20)
                } else {
                    NodeInspector(
                        node: inspectorNodeBinding,
                        onDelete: onDelete,
                        onSaveAsTemplate: { onSaveAsTemplate(inspectorNodeBinding.wrappedValue) },
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
}

struct StructureChatInspectorContent: View {
    @Bindable var structure: StructureViewModel
    let availableProviders: () -> [APIKeyProvider]
    let providerIcon: (APIKeyProvider) -> String

    let onPersistStructureChatState: () -> Void
    let onApplyTemplateFromStructureChat: (PresetHierarchyTemplate?, String) -> Void
    let onStartFreshStructureChat: () -> Void
    let onSubmitStructureChatTurn: () -> Void
    let onRunStructureChatDebugBroadcast: (StructureChatMessageEntry) -> Void

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
                }
                .buttonStyle(.bordered)

                Menu {
                    Button("Simple Task") {
                        onApplyTemplateFromStructureChat(nil, "Simple Task")
                    }
                    ForEach(PresetHierarchyTemplate.allCases) { template in
                        Button(template.title) {
                            onApplyTemplateFromStructureChat(template, template.title)
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
                    onStartFreshStructureChat()
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
