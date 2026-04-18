import SwiftUI

/// Canvas top toolbar: team-goal field and run control.
struct SchemaControlsBar: View {
    @Bindable var canvas: CanvasViewModel
    @Bindable var viewport: CanvasViewportState
    @Bindable var execution: ExecutionViewModel
    let canRunCoordinator: Bool
    let onRunCoordinator: () -> Void
    let onStopExecution: () -> Void

    private let headerControlHeight: CGFloat = 42

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble")
                    .foregroundStyle(.secondary)
                TextField("What should the team answer?", text: $execution.orchestrationGoal)
                    .textFieldStyle(.plain)
                    .truncationMode(.tail)
                    .lineLimit(1)
                    .help("Describe the team's goal")

                if !execution.orchestrationGoal.isEmpty {
                    Button {
                        execution.orchestrationGoal = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear team goal")
                    .help("Clear")
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .frame(height: headerControlHeight)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppTheme.surfaceSecondary)
            )

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
        .padding(.leading, 16)
        .padding(.trailing, 16)
        .padding(.vertical, 10)
        .background(AppTheme.surfacePrimary)
    }
}
