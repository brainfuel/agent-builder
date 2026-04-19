import SwiftUI
import SwiftData

enum DraftField: Hashable {
    case title
    case goal
    case context
    case structureStrategy
}

enum DraftCreationOption: String, CaseIterable, Hashable, Identifiable {
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

enum DraftInfoTopic: String, Hashable {
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

/// Task list sidebar: segmented tabs (tasks / tools / settings), draft form, and task rows.
struct TaskListView: View {
    @Bindable var navigation: NavigationCoordinator

    let taskDocuments: [GraphDocument]
    let usesTaskSplitView: Bool
    let navigationTitle: String

    @Binding var newTaskTitle: String
    @Binding var newTaskGoal: String
    @Binding var newTaskContext: String
    @Binding var newTaskStructureStrategy: String
    @Binding var newTaskCreationOption: DraftCreationOption
    @Binding var newTaskCustomTemplateID: UUID?
    @Binding var activeDraftInfo: DraftInfoTopic?
    var focusedDraftField: FocusState<DraftField?>.Binding

    @Query(sort: \UserStructureTemplate.updatedAt, order: .reverse)
    private var userStructureTemplates: [UserStructureTemplate]

    private var selectedCustomTemplate: UserStructureTemplate? {
        guard let id = newTaskCustomTemplateID else { return nil }
        return userStructureTemplates.first { $0.id == id }
    }

    private var creationOptionLabel: String {
        selectedCustomTemplate?.name ?? newTaskCreationOption.title
    }

    let onCreateTask: () -> Void
    let runStatus: (GraphDocument) -> TaskRunStatus
    let isTaskRunning: (GraphDocument) -> Bool
    let canRunTask: (GraphDocument) -> Bool
    let pendingHumanApprovalCount: (GraphDocument) -> Int
    let currentGraphKey: String?
    let taskRunButtonIcon: (GraphDocument) -> String
    let taskRunButtonLabel: (GraphDocument) -> String
    let onOpenResults: (String) -> Void
    let onOpenHumanInbox: (String) -> Void
    let onOpenEditor: (String) -> Void
    let onRunOrContinue: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
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
            .help("Switch sidebar section")

            Divider()

            switch navigation.sidebarTab {
            case .tasks:
                sidebarTasksContent
            case .tools:
                ToolCatalogSheet(embedded: true)
            case .settings:
                APIKeysSheet(embedded: true)
            }
        }
        .navigationTitle(usesTaskSplitView ? navigationTitle : "")
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
                if newTaskCreationOption.usesStructureStrategyField && newTaskCustomTemplateID == nil {
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
                        ForEach(userStructureTemplates) { template in
                            customTemplateMenuItem(template)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(creationOptionLabel)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .help("Choose how to create this task")

                    draftInfoButton(topic: .creationMode)

                    Spacer()

                    Button {
                        onCreateTask()
                    } label: {
                        Label("Create", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Create a new task from this draft")
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(AppTheme.surfacePrimary)
            .animation(
                .easeInOut(duration: 0.2),
                value: newTaskCreationOption.usesStructureStrategyField && newTaskCustomTemplateID == nil
            )

            Divider()

            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(taskDocuments, id: \.key) { document in
                        TaskRow(
                            document: document,
                            status: runStatus(document),
                            isSelected: document.key == (currentGraphKey ?? taskDocuments.first?.key),
                            isRunning: isTaskRunning(document),
                            canRun: canRunTask(document),
                            inboxBadgeCount: pendingHumanApprovalCount(document),
                            runButtonIcon: taskRunButtonIcon(document),
                            runButtonLabel: taskRunButtonLabel(document),
                            onOpenResults: { onOpenResults(document.key) },
                            onOpenHumanInbox: { onOpenHumanInbox(document.key) },
                            onOpenEditor: { onOpenEditor(document.key) },
                            onRunOrContinue: { onRunOrContinue(document.key) }
                        )
                    }
                }
                .padding(24)
            }
        }
    }

    private func draftTextField(
        _ placeholder: String,
        text: Binding<String>,
        field: DraftField,
        infoTopic: DraftInfoTopic
    ) -> some View {
        let isFocused = focusedDraftField.wrappedValue == field
        return HStack(spacing: 8) {
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .focused(focusedDraftField, equals: field)
                .help(placeholder)
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
        .help("Show info about \(topic.title)")
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
                newTaskCustomTemplateID = nil
            }
        } label: {
            if newTaskCreationOption == option && newTaskCustomTemplateID == nil {
                Label(option.title, systemImage: "checkmark")
            } else {
                Text(option.title)
            }
        }
    }

    private func customTemplateMenuItem(_ template: UserStructureTemplate) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                newTaskCustomTemplateID = template.id
            }
        } label: {
            if newTaskCustomTemplateID == template.id {
                Label(template.name, systemImage: "checkmark")
            } else {
                Text(template.name)
            }
        }
    }
}

struct TaskRow: View {
    let document: GraphDocument
    let status: TaskRunStatus
    let isSelected: Bool
    let isRunning: Bool
    let canRun: Bool
    let inboxBadgeCount: Int
    let runButtonIcon: String
    let runButtonLabel: String
    let onOpenResults: () -> Void
    let onOpenHumanInbox: () -> Void
    let onOpenEditor: () -> Void
    let onRunOrContinue: () -> Void

    var body: some View {
        let viewModel = TaskCardViewModel(document: document, status: status)
        VStack(alignment: .leading, spacing: 10) {
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

                if status == .completed {
                    Button {
                        onOpenResults()
                    } label: {
                        Image(systemName: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("View Results")
                    .catalystTooltip("View Results")
                }

                if inboxBadgeCount > 0 {
                    Button {
                        onOpenHumanInbox()
                    } label: {
                        HumanInboxButtonLabel(pendingCount: inboxBadgeCount, showsTitle: false)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Human Inbox")
                    .catalystTooltip("Open Human Inbox")
                }

                Button {
                    onOpenEditor()
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Edit Task")
                .catalystTooltip("Edit Task")

                Button {
                    onRunOrContinue()
                } label: {
                    if isRunning {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: runButtonIcon)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canRun)
                .accessibilityLabel(runButtonLabel)
                .catalystTooltip(runButtonLabel)
            }
        }
        .padding(16)
        .contentShape(Rectangle())
        .onTapGesture {
            onOpenEditor()
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    isSelected
                        ? AppTheme.brandTint.opacity(0.12)
                        : AppTheme.surfaceSecondary
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    isSelected
                        ? AppTheme.brandTint.opacity(0.45)
                        : Color.black.opacity(0.06),
                    lineWidth: isSelected ? 1.5 : 1
                )
        )
    }
}
