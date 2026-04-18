import SwiftUI

/// View-side canvas state that is NOT part of the persisted graph:
/// zoom, search filter, scroll proxy reference, and animation suppression flag.
/// Kept separate from `CanvasViewModel` so graph-state observers don't
/// invalidate on transient viewport changes (and vice versa).
@Observable
final class CanvasViewportState {
    var zoom: CGFloat = 1.0
    var searchText: String = ""
    var suppressLayoutAnimation: Bool = false
    var canvasScrollProxy: ScrollViewProxy?

    /// Current scroll offset of the canvas ScrollView, written by the view as the user scrolls.
    var scrollOffset: CGPoint = .zero

    /// One-shot restore request: set by `CanvasViewModel.load` so the view can scroll
    /// to the persisted offset on the next layout pass. The view clears it after applying.
    var pendingRestoreOffset: CGPoint?

    func adjustZoom(stepDelta: Int) {
        let raw = zoom + CGFloat(stepDelta) * AppConfiguration.Canvas.zoomStep
        zoom = min(max(raw, AppConfiguration.Canvas.minZoom), AppConfiguration.Canvas.maxZoom)
    }
}
