import SwiftUI

/// Floating zoom in/out + "center on input node" control cluster overlaid on the canvas.
/// Reads/mutates canvas zoom and triggers a scroll-to-anchor on center tap.
struct ZoomControlsView: View {
    @Bindable var canvas: CanvasViewModel

    private let controlHeight: CGFloat = 46

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    canvas.viewport.adjustZoom(stepDelta: -1)
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .catalystTooltip("Zoom Out")

                Text("\(Int((canvas.viewport.zoom * 100).rounded()))%")
                    .frame(minWidth: 52)
                    .font(.system(.title3, design: .rounded).weight(.semibold))

                Button {
                    canvas.viewport.adjustZoom(stepDelta: 1)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .catalystTooltip("Zoom In")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.10), radius: 7, y: 2)
            .frame(height: controlHeight)

            Button {
                if let inputNode = canvas.nodes.first(where: { $0.type == .input }) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        canvas.viewport.canvasScrollProxy?.scrollTo(inputNode.id, anchor: .top)
                    }
                }
            } label: {
                Image(systemName: "location.north.line.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: controlHeight, height: controlHeight)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.ultraThinMaterial)
                    )
            }
            .buttonStyle(.plain)
            .shadow(color: .black.opacity(0.10), radius: 7, y: 2)
            .accessibilityLabel("Center View")
            .catalystTooltip("Center View")
        }
    }
}
