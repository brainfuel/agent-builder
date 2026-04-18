import Testing
import Foundation
@testable import Agentic

/// Unit tests for `CanvasViewportState` — the small @Observable wrapper for
/// transient viewport state (zoom, search). We only verify `adjustZoom`
/// clamping and default values; scroll proxy is a SwiftUI concern left to
/// integration.
struct CanvasViewportStateTests {

    @Test func defaultsAreNeutral() {
        let viewport = CanvasViewportState()
        #expect(viewport.zoom == 1.0)
        #expect(viewport.searchText.isEmpty)
        #expect(viewport.suppressLayoutAnimation == false)
    }

    @Test func adjustZoom_clampsToMinimum() {
        let viewport = CanvasViewportState()
        for _ in 0..<1000 { viewport.adjustZoom(stepDelta: -1) }
        #expect(viewport.zoom >= AppConfiguration.Canvas.minZoom)
        #expect(viewport.zoom == AppConfiguration.Canvas.minZoom)
    }

    @Test func adjustZoom_clampsToMaximum() {
        let viewport = CanvasViewportState()
        for _ in 0..<1000 { viewport.adjustZoom(stepDelta: 1) }
        #expect(viewport.zoom <= AppConfiguration.Canvas.maxZoom)
        #expect(viewport.zoom == AppConfiguration.Canvas.maxZoom)
    }

    @Test func adjustZoom_stepsByConfiguredIncrement() {
        let viewport = CanvasViewportState()
        let start = viewport.zoom
        viewport.adjustZoom(stepDelta: 1)
        #expect(abs(viewport.zoom - (start + AppConfiguration.Canvas.zoomStep)) < 0.0001)
    }
}
