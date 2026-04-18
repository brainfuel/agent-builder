import SwiftUI

/// Canvas top toolbar: search, undo, and redo controls.
struct SchemaControlsBar: View {
    @Bindable var canvas: CanvasViewModel
    @Bindable var viewport: CanvasViewportState
    @Bindable var execution: ExecutionViewModel
    let canUndo: Bool
    let canRedo: Bool
    let onUndo: () -> Void
    let onRedo: () -> Void

    private let headerControlHeight: CGFloat = 42

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search node", text: $viewport.searchText)
                    .textFieldStyle(.plain)
                    .help("Search nodes by name")
            }
            .padding(.horizontal, 14)
            .frame(width: 300, height: headerControlHeight)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppTheme.surfaceSecondary)
            )

            Spacer(minLength: 0)

            Button {
                onUndo()
            } label: {
                HeaderControlLabel(
                    title: "Undo",
                    systemImage: "arrow.uturn.backward",
                    height: headerControlHeight,
                    prominent: false,
                    enabled: canUndo
                )
            }
            .buttonStyle(.plain)
            .disabled(!canUndo)
            .keyboardShortcut("z", modifiers: [.command])
            .catalystTooltip("Undo")

            Button {
                onRedo()
            } label: {
                HeaderControlLabel(
                    title: "Redo",
                    systemImage: "arrow.uturn.forward",
                    height: headerControlHeight,
                    prominent: false,
                    enabled: canRedo
                )
            }
            .buttonStyle(.plain)
            .disabled(!canRedo)
            .keyboardShortcut("Z", modifiers: [.command, .shift])
            .catalystTooltip("Redo")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(AppTheme.surfacePrimary)
    }
}
