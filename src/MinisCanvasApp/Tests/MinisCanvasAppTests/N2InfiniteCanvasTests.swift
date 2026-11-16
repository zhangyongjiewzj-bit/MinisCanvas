import Testing
import Foundation
import CoreGraphics
import CanvasCore
@testable import MinisCanvasApp

// MARK: - N2 画布真无限化：
// 世界坐标 + 视口平移 + 渲染层缩放——节点 position / 端口锚点 / 连线控制点全用世界坐标
// （不随 zoom 变），scaleEffect 只作用渲染层；平移边界远超旧 4000pt 固定画布。

@Suite("N2 画布真无限化：世界坐标 + 视口平移 + 渲染层缩放")
@MainActor
struct N2InfiniteCanvasTests {

    // MARK: - 世界坐标与渲染坐标分离（zoom 变化节点世界坐标不变）

    @Test func nodeWorldPositionUnaffectedByZoom() {
        let store = CanvasStore(graph: NodeGraph(nodes: [
            CanvasNode(type: "llm", title: "LLM", position: Point(x: 312, y: 218),
                       inputs: [], outputs: []),
        ], edges: []))
        let node = store.graph.nodes[0]
        let world = node.position

        for zoom in [0.2, 0.5, 1.0, 2.0, 2.5, 3.0] {
            let viewport = ViewportTransform(zoom: zoom)
            // 世界坐标不随 zoom 变
            #expect(store.graph.nodes[0].position == world)
            // 渲染坐标（屏幕）随 zoom 缩放：screen = world × zoom + pan
            // （显式转 Double 比较，规避 CGFloat==Double 混合比较在 #expect 下的异常）
            let screen = viewport.screen(world)
            #expect(abs(Double(screen.x) - world.x * zoom) < 0.0001)
            #expect(abs(Double(screen.y) - world.y * zoom) < 0.0001)
            // 屏幕 → 世界 逆变换还原
            let back = viewport.world(screen)
            #expect(abs(back.x - world.x) < 0.0001)
            #expect(abs(back.y - world.y) < 0.0001)
        }
    }

    @Test func portAnchorIsWorldCoordinateIndependentOfZoom() {
        let outPort = CanvasCore.Port(name: "out", direction: .output, dataType: "string")
        let node = CanvasNode(type: "test", title: "A", position: Point(x: 300, y: 300),
                              inputs: [], outputs: [outPort])
        let store = CanvasStore(graph: NodeGraph(nodes: [node], edges: []))
        let anchor = store.portAnchor(for: node, port: outPort)
        // 锚点只由世界坐标节点 position + 布局度量决定，与 zoom 无关
        #expect(anchor.x == node.position.x + NodeMetrics.nodeWidth / 2)
        // U-1：Y 中心语义 = position.y + localY − nodeHeight/2
        let nodeH = NodeMetrics.nodeHeight(inputs: 0, outputs: 1)
        #expect(anchor.y == node.position.y + (NodeMetrics.headerHeight + NodeMetrics.rowHeight / 2) - nodeH / 2)
    }

    @Test func viewportTransformRoundtripsScreenAndWorld() {
        let viewport = ViewportTransform(zoom: 1.7, pan: CGPoint(x: -480, y: 260))
        let worldPoint = Point(x: 1234.5, y: -678.9)
        let screen = viewport.screen(worldPoint)
        let back = viewport.world(screen)
        #expect(abs(back.x - worldPoint.x) < 0.0001)
        #expect(abs(back.y - worldPoint.y) < 0.0001)

        let screenPoint = CGPoint(x: 900, y: 300)
        let world = viewport.world(screenPoint)
        let screenAgain = viewport.screen(world)
        #expect(abs(screenAgain.x - screenPoint.x) < 0.0001)
        #expect(abs(screenAgain.y - screenPoint.y) < 0.0001)
    }

    // MARK: - 缩放后拖拽 / 连线几何正确（不再 /zoom 换算错位）

    @Test func dragTranslationMapsToWorldDeltaAtAnyZoom() {
        // 缩放层内 DragGesture.translation 即世界位移：世界位移 = 屏幕位移 / zoom。
        // 拖拽换算：start + translation（世界坐标），与旧实现 start + translation/zoom 一致。
        let start = Point(x: 300, y: 200)
        let screenDelta = CGPoint(x: 40, y: -20)
        for zoom in [0.5, 1.0, 2.0, 3.0] {
            let viewport = ViewportTransform(zoom: zoom)
            let translation = CGPoint(x: screenDelta.x / zoom, y: screenDelta.y / zoom)
            let moved = Point(x: start.x + translation.x, y: start.y + translation.y)
            // 换算后的世界坐标 = 屏幕位移经世界逆变换
            let expected = viewport.world(CGPoint(x: viewport.screen(start).x + screenDelta.x,
                                                  y: viewport.screen(start).y + screenDelta.y))
            #expect(abs(moved.x - expected.x) < 0.0001)
            #expect(abs(moved.y - expected.y) < 0.0001)
        }
    }

    @Test func edgeGeometryIsWorldCoordinateAndZoomInvariant() {
        let from = Point(x: 300, y: 300)
        let to = Point(x: 900, y: 420)
        let (c1, c2) = EdgeGeometry.controlPoints(from: from, to: to, direction: 1.0)
        // 控制点与端点同属世界坐标：偏移只取决于世界坐标，与 zoom 完全无关
        #expect(c1.x == from.x + EdgeGeometry.controlOffset(from: from, to: to))
        #expect(c1.y == from.y)
        #expect(c2.x == to.x - EdgeGeometry.controlOffset(from: from, to: to))
        #expect(c2.y == to.y)
        // 世界坐标下缩放任意倍数，控制点几何关系不变（渲染层统一 scaleEffect）
        for zoom in [0.2, 1.0, 3.0] {
            #expect(c1.x * zoom >= from.x * zoom && c1.x * zoom <= to.x * zoom)
            #expect(c2.x * zoom >= from.x * zoom && c2.x * zoom <= to.x * zoom)
        }
    }

    @Test func pendingEdgeConnectSnapsInWorldCoordinatesAtAnyZoom() {
        let outPort = CanvasCore.Port(name: "out", direction: .output, dataType: "string")
        let inPort = CanvasCore.Port(name: "in", direction: .input, dataType: "string")
        let a = CanvasNode(type: "test", title: "A", position: Point(x: 100, y: 100),
                           inputs: [], outputs: [outPort])
        let b = CanvasNode(type: "test", title: "B", position: Point(x: 500, y: 100),
                           inputs: [inPort], outputs: [])
        let store = CanvasStore(graph: NodeGraph(nodes: [a, b], edges: []))

        let outAnchor = store.portAnchor(for: a, port: outPort)
        let inAnchor = store.portAnchor(for: b, port: inPort)
        // 模拟拖线：全部世界坐标（缩放层内 translation 即世界位移，zoom 不参与换算）
        store.beginEdge(from: a.id, portID: outPort.id, at: outAnchor)
        store.updateEdgeEnd(inAnchor)
        #expect(store.pendingEdge?.end == inAnchor)
        store.endEdge(at: inAnchor)
        #expect(store.graph.edges.count == 1)
        #expect(store.graph.edges[0].fromNode == a.id && store.graph.edges[0].toNode == b.id)
    }

    @Test func zoomChangeDoesNotCorruptPendingEdgeWorldGeometry() {
        let outPort = CanvasCore.Port(name: "out", direction: .output, dataType: "string")
        let a = CanvasNode(type: "test", title: "A", position: Point(x: 100, y: 100),
                           inputs: [], outputs: [outPort])
        let store = CanvasStore(graph: NodeGraph(nodes: [a], edges: []))
        let anchor = store.portAnchor(for: a, port: outPort)
        let end = Point(x: 600, y: 300)
        store.beginEdge(from: a.id, portID: outPort.id, at: anchor)
        store.updateEdgeEnd(end)
        guard let pending = store.pendingEdge else {
            Issue.record("pendingEdge 应为非 nil")
            return
        }
        // 拖线端点是世界坐标：与 zoom 完全解耦（渲染层统一缩放）
        #expect(pending.end == end)
        let (c1, c2) = EdgeGeometry.controlPoints(from: anchor, to: end, direction: 1.0)
        for zoom in [0.5, 2.0] {
            // 任意 zoom 下控制点相对端点几何关系一致
            let f = CGPoint(x: anchor.x * zoom, y: anchor.y * zoom)
            let t = CGPoint(x: end.x * zoom, y: end.y * zoom)
            let s1 = CGPoint(x: c1.x * zoom, y: c1.y * zoom)
            let s2 = CGPoint(x: c2.x * zoom, y: c2.y * zoom)
            #expect(s1.x >= f.x && s1.x <= t.x)
            #expect(s2.x >= f.x && s2.x <= t.x)
        }
    }

    // MARK: - 大画布平移边界（100000pt 世界层，远超旧 4000pt）

    @Test func panClampsToLooseBoundsOnHugeCanvas() {
        let canvasW = 100_000.0
        let canvasH = 100_000.0
        let viewport = ViewportTransform(zoom: 1.0)
        // ±60% 画布尺寸：单方向可平移 60000pt（旧实现画布仅 4000pt，无法到达）
        let far = viewport.pannedBy(70_000, 80_000, canvasWidth: canvasW, canvasHeight: canvasH)
        #expect(far.pan.x == 60_000)
        #expect(far.pan.y == 60_000)
        let farNeg = viewport.pannedBy(-70_000, -80_000, canvasWidth: canvasW, canvasHeight: canvasH)
        #expect(farNeg.pan.x == -60_000)
        #expect(farNeg.pan.y == -60_000)
        // 边界随 zoom 放大（放大时可视世界范围缩小，允许平移的屏幕范围随之增大）
        let zoomed = ViewportTransform(zoom: 3.0)
            .pannedBy(400_000, 400_000, canvasWidth: canvasW, canvasHeight: canvasH)
        #expect(zoomed.pan.x == 180_000)
        #expect(zoomed.pan.y == 180_000)
    }

    @Test func nanPanTargetIsRejectedAndViewportUnchanged() {
        // AJ-66 防御：NaN/Infinity 落点直接拒绝（Swift min/max 遇 NaN 会传播，
        // 一旦 pan 被污染视口永久崩坏，只能重启恢复）。拒绝 = 视口保持原样。
        let viewport = ViewportTransform(zoom: 1.0, pan: CGPoint(x: 10, y: 20))
        let nanResult = viewport.clampedPan(canvasWidth: 1000, canvasHeight: 1000,
                                            at: CGPoint(x: Double.nan, y: Double.nan))
        #expect(nanResult.pan.x == 10)
        #expect(nanResult.pan.y == 20)
        let infResult = viewport.clampedPan(canvasWidth: 1000, canvasHeight: 1000,
                                            at: CGPoint(x: Double.infinity, y: -500))
        #expect(infResult.pan.x == 10)
        #expect(infResult.pan.y == 20)
    }

    @Test func panReachesFarBeyondOld4000ptCanvas() {
        let canvasW = 100_000.0
        let canvasH = 100_000.0
        // 旧实现：ScrollView 内容 4000pt，节点超过 4000pt 就不可达
        let viewport = ViewportTransform(zoom: 1.0)
            .pannedBy(20_000, -15_000, canvasWidth: canvasW, canvasHeight: canvasH)
        #expect(viewport.pan.x == 20_000)
        #expect(viewport.pan.y == -15_000)
        // 视口内可见的世界坐标：20000pt 外的节点在屏幕中心附近可达
        let worldAtCenter = viewport.world(CGPoint(x: 20_000, y: -15_000))
        #expect(abs(worldAtCenter.x) < 0.0001)
        #expect(abs(worldAtCenter.y) < 0.0001)
    }

    @Test func zoomKeepsAnchorWorldPointFixed() {
        // 光标/中心锚定：缩放前后锚点下的世界点不动（Codex/ComfyUI pan+zoom 语义）
        let canvasW = 100_000.0
        let canvasH = 100_000.0
        let anchor = CGPoint(x: 400, y: 300)
        let before = ViewportTransform(zoom: 1.0, pan: CGPoint(x: 100, y: 50))
        let worldUnderAnchor = before.world(anchor)

        for newZoom in [0.5, 1.5, 2.0, 3.0] {
            let after = before.zoomed(to: newZoom, anchor: anchor,
                                      canvasWidth: canvasW, canvasHeight: canvasH)
            #expect(after.zoom == newZoom)
            let kept = after.world(anchor)
            #expect(abs(kept.x - worldUnderAnchor.x) < 0.0001)
            #expect(abs(kept.y - worldUnderAnchor.y) < 0.0001)
        }
    }

    @Test func zoomIsClampedToRange() {
        let canvasW = 100_000.0
        let canvasH = 100_000.0
        let viewport = ViewportTransform()
        #expect(viewport.zoomed(to: 0.01, anchor: .zero, canvasWidth: canvasW, canvasHeight: canvasH).zoom == ViewportTransform.minZoom)
        #expect(viewport.zoomed(to: 99, anchor: .zero, canvasWidth: canvasW, canvasHeight: canvasH).zoom == ViewportTransform.maxZoom)
    }

    // MARK: - AJ-66 防线完备性：视口数学写点 NaN/Infinity 拒绝 + 有限性兜底

    @Test func zoomedWithNonFiniteInputsIsRejectedViewportUnchanged() {
        // AJ-66：缩放请求任一输入非有限 → 返回自身（NaN 不写进 viewport.zoom/pan）
        let canvasW = 100_000.0
        let canvasH = 100_000.0
        let anchor = CGPoint(x: 400, y: 300)
        let viewport = ViewportTransform(zoom: 1.5, pan: CGPoint(x: 10, y: 20))
        let nanZoom = viewport.zoomed(to: Double.nan, anchor: anchor,
                                      canvasWidth: canvasW, canvasHeight: canvasH)
        #expect(nanZoom.zoom == 1.5)
        #expect(nanZoom.pan.x == 10 && nanZoom.pan.y == 20)
        let infZoom = viewport.zoomed(to: Double.infinity, anchor: anchor,
                                      canvasWidth: canvasW, canvasHeight: canvasH)
        #expect(infZoom.zoom == 1.5)
        let nanAnchor = viewport.zoomed(to: 2.0, anchor: CGPoint(x: Double.nan, y: 0),
                                        canvasWidth: canvasW, canvasHeight: canvasH)
        #expect(nanAnchor.zoom == 1.5)
        // 视口自身已被污染（历史 NaN 源）：拒绝新缩放，保持污染值原样（不再传播/不再产出更坏值）
        let polluted = ViewportTransform(zoom: Double.nan, pan: CGPoint(x: 10, y: 20))
        let onPolluted = polluted.zoomed(to: 2.0, anchor: anchor,
                                         canvasWidth: canvasW, canvasHeight: canvasH)
        #expect(onPolluted.zoom.isNaN)
    }

    @Test func clampedZoomRejectsNonFiniteInputKeepsCurrent() {
        // AJ-66：clampedZoom(NaN/Infinity) 返回当前 zoom——杜绝 NaN 经 min/max 传播
        let viewport = ViewportTransform(zoom: 1.5)
        #expect(viewport.clampedZoom(Double.nan) == 1.5)
        #expect(viewport.clampedZoom(Double.infinity) == 1.5)
        #expect(viewport.clampedZoom(-Double.infinity) == 1.5)
        // 有限值行为不变（maxZoom 已放宽 3.0 → 8.0：大画布缩放无感反馈，见 ViewportTransform）
        #expect(viewport.clampedZoom(99) == ViewportTransform.maxZoom)
        #expect(viewport.clampedZoom(0.05) == ViewportTransform.minZoom)
    }

    @Test func screenAndWorldFallBackToZeroForNonFinite() {
        // AJ-66：world()/screen() 结果非有限 → 退化 .zero（粘贴落点/双击搜索/右键建节点/框选共用此防线）
        let polluted = ViewportTransform(zoom: Double.nan, pan: CGPoint(x: 10, y: 20))
        let s = polluted.screen(Point(x: 100, y: 100))
        #expect(s.x.isFinite && s.y.isFinite)
        let w = polluted.world(CGPoint(x: 100, y: 100))
        #expect(w.x.isFinite && w.y.isFinite)
        // 输入非有限同样拒绝
        let ok = ViewportTransform(zoom: 1.0)
        let badWorld = ok.screen(Point(x: Double.nan, y: 5))
        #expect(badWorld.x.isFinite && badWorld.y.isFinite)
        let badScreen = ok.world(CGPoint(x: Double.infinity, y: 5))
        #expect(badScreen.x.isFinite && badScreen.y.isFinite)
        // zoom=0 除零 → 非有限 → 退化 .zero
        let zero = ViewportTransform(zoom: 0)
        let zeroWorld = zero.world(CGPoint(x: 100, y: 100))
        #expect(zeroWorld.x.isFinite && zeroWorld.y.isFinite)
    }

    @Test func fitViewportRejectsNonFiniteNodePositions() {
        // AJ-66：任一节点位置非有限 → nil（不动视口），NaN 不污染 targetZoom/pan
        let good = CanvasNode(type: "text", title: "A", position: Point(x: 100, y: 100),
                              inputs: [], outputs: [])
        let bad = CanvasNode(type: "text", title: "B", position: Point(x: Double.nan, y: 50),
                             inputs: [], outputs: [])
        let nilResult = CanvasView.fitViewport(for: [good, bad], viewportSize: CGSize(width: 800, height: 600),
                                               canvasWidth: 100_000, canvasHeight: 100_000, currentZoom: 1.0)
        #expect(nilResult == nil)
    }

    @Test func fitViewportProducesFiniteClampedViewport() {
        // 正常节点 → 有限 zoom/pan 且 zoom 在 [0.2, 3.0]；空节点/零尺寸 → nil
        let nodes = [
            CanvasNode(type: "text", title: "A", position: Point(x: 100, y: 100), inputs: [], outputs: []),
            CanvasNode(type: "text", title: "B", position: Point(x: 900, y: 700), inputs: [], outputs: []),
        ]
        let fitted = CanvasView.fitViewport(for: nodes, viewportSize: CGSize(width: 800, height: 600),
                                            canvasWidth: 100_000, canvasHeight: 100_000, currentZoom: 1.0)
        #expect(fitted != nil)
        #expect(fitted!.zoom.isFinite && fitted!.pan.x.isFinite && fitted!.pan.y.isFinite)
        #expect(fitted!.zoom >= 0.2 && fitted!.zoom <= 3.0)
        #expect(CanvasView.fitViewport(for: [], viewportSize: CGSize(width: 800, height: 600),
                                       canvasWidth: 100_000, canvasHeight: 100_000, currentZoom: 1.0) == nil)
        #expect(CanvasView.fitViewport(for: nodes, viewportSize: .zero,
                                       canvasWidth: 100_000, canvasHeight: 100_000, currentZoom: 1.0) == nil)
    }
}
