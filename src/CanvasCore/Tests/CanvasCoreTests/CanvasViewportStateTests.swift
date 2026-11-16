import Testing
@testable import CanvasCore

struct CanvasViewportStateTests {
    @Test func zoomIsClampedAndNonFinitePanIsIgnored() {
        var state = CanvasViewportState(zoom: 100)
        #expect(state.zoom == 8)
        state.pan(by: Point(x: .infinity, y: 2))
        #expect(state.center == Point(x: 0, y: 0))
        state.pan(by: Point(x: 3, y: -2))
        #expect(state.center == Point(x: 3, y: -2))
    }

    @Test func minimapMapsAndClampsCanvasCoordinates() {
        let state = CanvasViewportState(canvasSize: Size(width: 1000, height: 500))
        #expect(state.minimapPoint(for: Point(x: 500, y: 250), in: Size(width: 200, height: 100)) == Point(x: 100, y: 50))
        #expect(state.minimapPoint(for: Point(x: 2000, y: -1), in: Size(width: 200, height: 100)) == Point(x: 200, y: 0))
    }
}
