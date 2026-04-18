import SwiftUI

/// Top header bar with title, navigation/task-list toggle, human inbox, debug, delete, and run controls,
/// plus the live status banner that appears during execution.
struct HeaderBarView: View {
    @Bindable var execution: ExecutionViewModel

    let activeTaskTitle: String
    let usesTaskSplitView: Bool
    let splitViewVisibility: NavigationSplitViewVisibility
    let pendingHumanPacket: CoordinatorTaskPacket?
    let canDeleteTask: Bool
    let canRunCoordinator: Bool
    let canCopyDebugPayload: Bool
    let debugClipboardText: () -> String

    let onShowTaskList: () -> Void
    let onShowAllColumns: () -> Void
    let onOpenHumanInbox: () -> Void
    let onCopyDebug: () -> Void
    let onRequestDeleteTask: () -> Void
    let onStopExecution: () -> Void
    let onRunCoordinator: () -> Void

    private let headerControlHeight: CGFloat = 42

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                if !usesTaskSplitView {
                    Button {
                        onShowTaskList()
                    } label: {
                        HeaderControlLabel(
                            title: "Tasks",
                            systemImage: "chevron.left",
                            height: headerControlHeight,
                            prominent: false,
                            enabled: true
                        )
                    }
                    .buttonStyle(.plain)
                    .catalystTooltip("Show Tasks")
                } else if splitViewVisibility == .detailOnly {
                    Button {
                        onShowAllColumns()
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
                    onOpenHumanInbox()
                } label: {
                    HeaderControlLabel(
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
                    onCopyDebug()
                } label: {
                    HeaderControlLabel(
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
                    onRequestDeleteTask()
                } label: {
                    Image(systemName: "trash")
                        .font(.headline)
                        .frame(width: headerControlHeight, height: headerControlHeight)
                        .foregroundStyle(
                            HeaderControlStyle.foreground(
                                prominent: false,
                                enabled: canDeleteTask,
                                destructive: true
                            )
                        )
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(
                                    HeaderControlStyle.background(
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
                        onStopExecution()
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
                        onRunCoordinator()
                    } label: {
                        HeaderControlLabel(
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
}
