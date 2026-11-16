import Testing
import Foundation
import CoreGraphics
import CanvasCore
@testable import MinisCanvasApp

// MARK: - AJ-16 画布 minimap：内容包围盒 / 缩略缩放 / 视口矩形映射 / 点击跳转（纯几何逻辑）

@Suite("AJ-16 画布 minimap：小地图几何 + 视口跳转")
struct AJ16MiniMapTests {

    private let mapSize = CGSize(width: 180, height: 140)

    private func makeNode(_ x: Double, _ y: Double, inputs: Int = 0, outputs: Int = 0) -> CanvasNode {
        CanvasNode(type: "test", title: "N", position: Point(x: x, y: y),
                   inputs: (0..<inputs).map { _ in CanvasCore.Port(name: "i", direction: .input, dataType: "string") },
                   outputs: (0..<outputs).map { _ in CanvasCore.Port(name: "o", direction: .output, dataType: "string") })
    }

    // MARK: - 内容包围盒

    @Test func emptyCanvasHasNoBounds() {
        #expect(MiniMapGeometry.contentBounds(of: []) == nil)
    }

    @Test func contentBoundsIncludesNodeSize() {
        let nodes = [makeNode(300, 200, inputs: 2, outputs: 1)]
        let bounds = MiniMapGeometry.contentBounds(of: nodes)
        let h = NodeMetrics.nodeHeight(inputs: 2, outputs: 1)
        #expect(abs(Double(bounds!.origin.x) - 300) < 0.0001)
        #expect(abs(Double(bounds!.origin.y) - 200) < 0.0001)
        #expect(abs(Double(bounds!.width) - NodeMetrics.nodeWidth) < 0.0001)
        #expect(abs(Double(bounds!.height) - h) < 0.0001)
    }

    @Test func contentBoundsSpansMultipleNodes() {
        let nodes = [makeNode(100, 100), makeNode(500, 300)]
        let bounds = MiniMapGeometry.contentBounds(of: nodes)!
        #expect(abs(Double(bounds.minX) - 100) < 0.0001)
        #expect(abs(Double(bounds.minY) - 100) < 0.0001)
        #expect(abs(Double(bounds.maxX) - (500 + NodeMetrics.nodeWidth)) < 0.0001)
        #expect(abs(Double(bounds.maxY) - (300 + NodeMetrics.nodeHeight(inputs: 0, outputs: 0))) < 0.0001)
    }

    // MARK: - 世界 ↔ 小地图换算

    @Test func worldMapRoundtrip() {
        let nodes = [makeNode(100, 100), makeNode(900, 500)]
        let bounds = MiniMapGeometry.contentBounds(of: nodes)!
        let geo = MiniMapGeometry(mapSize: mapSize, contentBounds: bounds)
        #expect(geo.worldToMap(Point(x: 100, y: 100)) == geo.contentOriginInMap)
        let world = Point(x: 500, y: 300)
        let mapped = geo.worldToMap(world)
        let back = geo.mapToWorld(mapped)
        #expect(abs(back!.x - world.x) < 0.0001)
        #expect(abs(back!.y - world.y) < 0.0001)
    }

    @Test func emptyMapHasNoWorldMapping() {
        let geo = MiniMapGeometry(mapSize: mapSize, contentBounds: nil)
        #expect(geo.mapToWorld(.zero) == nil)
        #expect(geo.hasContent == false)
    }

    // MARK: - 视口世界矩形

    @Test func viewportWorldRectFromTransform() {
        // zoom 1, pan 0 → 左上角世界 (0,0)，右下角 = 视口尺寸
        let vp = ViewportTransform(zoom: 1.0, pan: .zero)
        let rect = MiniMapGeometry.viewportWorldRect(viewport: vp, viewportSize: CGSize(width: 800, height: 600))
        #expect(rect.origin.x == 0 && rect.origin.y == 0)
        #expect(rect.width == 800 && rect.height == 600)
    }

    @Test func viewportWorldRectWithPanAndZoom() {
        let vp = ViewportTransform(zoom: 2.0, pan: CGPoint(x: 100, y: -50))
        let rect = MiniMapGeometry.viewportWorldRect(viewport: vp, viewportSize: CGSize(width: 800, height: 600))
        // world = (screen - pan)/zoom
        #expect(abs(rect.minX - (0 - 100) / 2) < 0.0001)
        #expect(abs(rect.minY - (0 - (-50)) / 2) < 0.0001)
        #expect(abs(rect.width - 800 / 2) < 0.0001)
        #expect(abs(rect.height - 600 / 2) < 0.0001)
    }

    // MARK: - 视口矩形映射到小地图

    @Test func viewportRectMapsToMiniCoords() {
        let nodes = [makeNode(100, 100), makeNode(900, 500)]
        let bounds = MiniMapGeometry.contentBounds(of: nodes)!
        let geo = MiniMapGeometry(mapSize: mapSize, contentBounds: bounds)
        let vpRect = CGRect(x: 100, y: 100, width: 400, height: 200)
        let mini = geo.rect(of: vpRect)
        // 左上角内容 → 内容起点
        let tl = geo.worldToMap(Point(x: 100, y: 100))
        #expect(abs(mini.minX - tl.x) < 0.0001)
        #expect(abs(mini.minY - tl.y) < 0.0001)
        // 尺寸按 scale 缩放
        #expect(abs(mini.width - 400 * geo.scale) < 0.0001)
        #expect(abs(mini.height - 200 * geo.scale) < 0.0001)
    }

    // MARK: - 点击跳转视口

    @Test func jumpViewportCentersTappedWorldPoint() {
        let nodes = [makeNode(100, 100), makeNode(900, 500)]
        let bounds = MiniMapGeometry.contentBounds(of: nodes)!
        let vpSize = CGSize(width: 800, height: 600)
        let original = ViewportTransform(zoom: 1.0, pan: .zero)
        // 点小地图中心 → 世界坐标中心居中
        let center = CGPoint(x: mapSize.width / 2, y: mapSize.height / 2)
        let next = MiniMapGeometry.jumpViewport(
            tapInMap: center, mapSize: mapSize, contentBounds: bounds,
            viewportSize: vpSize, viewport: original, canvasWidth: 100_000, canvasHeight: 100_000)
        let worldCenter = MiniMapGeometry(mapSize: mapSize, contentBounds: bounds).mapToWorld(center)!
        // 新视口中心应对准点击的世界点
        let newCenter = next!.world(CGPoint(x: vpSize.width / 2, y: vpSize.height / 2))
        #expect(abs(newCenter.x - worldCenter.x) < 0.0001)
        #expect(abs(newCenter.y - worldCenter.y) < 0.0001)
        // zoom 保持
        #expect(next!.zoom == 1.0)
    }

    @Test func jumpPreservesZoom() {
        let nodes = [makeNode(0, 0), makeNode(1000, 1000)]
        let bounds = MiniMapGeometry.contentBounds(of: nodes)!
        let original = ViewportTransform(zoom: 2.5, pan: .zero)
        let next = MiniMapGeometry.jumpViewport(
            tapInMap: CGPoint(x: 10, y: 10), mapSize: mapSize, contentBounds: bounds,
            viewportSize: CGSize(width: 800, height: 600), viewport: original,
            canvasWidth: 100_000, canvasHeight: 100_000)
        #expect(next?.zoom == 2.5)
    }

    @Test func jumpOnEmptyCanvasReturnsNil() {
        let next = MiniMapGeometry.jumpViewport(
            tapInMap: .zero, mapSize: mapSize, contentBounds: nil,
            viewportSize: CGSize(width: 800, height: 600), viewport: ViewportTransform(),
            canvasWidth: 100_000, canvasHeight: 100_000)
        #expect(next == nil)
    }
}