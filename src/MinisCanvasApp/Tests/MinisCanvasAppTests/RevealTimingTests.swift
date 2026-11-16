import Testing
import Foundation
import CanvasCore
@testable import MinisCanvasApp

// MARK: - AJ-2 粘贴 reveal 时序：viewportSize 为零时粘贴后仍能定位
//
// 病根：viewportSize 是 @State，首帧前 / 画布非当前可见 pane 时为 .zero。
// 若 reveal 请求在此时到达，旧代码用 0 尺寸算出 targetPan = -center*zoom，
// 节点被贴到视口外 → 用户感知"粘贴后看不到"。
// 修法：resolveReveal 在视口未就绪（宽/高 ≤ 0）时返回 nil（推迟），
// 待布局完成后再 flushPendingReveal 补执行。

@Suite("AJ-2 粘贴 reveal 时序：viewportSize 为零时节点仍可见")
@MainActor
struct RevealTimingTests {

    private let canvasW = 100_000.0
    private let canvasH = 100_000.0

    private func makeRequest(center: Point) -> RevealRequest {
        RevealRequest(center: center, token: UUID())
    }

    @Test func zeroViewportSizeDefersReveal() {
        // 首布局未完成：viewportSize 为 0 → 必须返回 nil（推迟），不能算错误平移
        let req = makeRequest(center: Point(x: 5000, y: 5000))
        let resolved = CanvasView.resolveReveal(
            request: req,
            viewportSize: .zero,
            viewport: ViewportTransform(zoom: 1.0, pan: .zero),
            canvasWidth: canvasW, canvasHeight: canvasH)
        #expect(resolved == nil, "viewportSize 为零时必须推迟 reveal，避免节点贴到视口外")
    }

    @Test func zeroWidthOrHeightAlsoDefers() {
        let req = makeRequest(center: Point(x: 100, y: 100))
        // 仅宽为 0（部分未布局）也应推迟
        #expect(CanvasView.resolveReveal(
            request: req, viewportSize: CGSize(width: 0, height: 800),
            viewport: ViewportTransform(), canvasWidth: canvasW, canvasHeight: canvasH) == nil)
        // 仅高为 0 也应推迟
        #expect(CanvasView.resolveReveal(
            request: req, viewportSize: CGSize(width: 1200, height: 0),
            viewport: ViewportTransform(), canvasWidth: canvasW, canvasHeight: canvasH) == nil)
    }

    @Test func validViewportSizeCentersRevealedContent() {
        let size = CGSize(width: 1200, height: 800)
        let center = Point(x: 5000, y: 3000)
        let vp = ViewportTransform(zoom: 1.0, pan: .zero)
        let resolved = CanvasView.resolveReveal(
            request: makeRequest(center: center),
            viewportSize: size, viewport: vp,
            canvasWidth: canvasW, canvasHeight: canvasH)
        #expect(resolved != nil)
        // targetPan = size/2 - center*zoom → 粘贴内容中心应落在视口中心
        #expect(abs(resolved!.pan.x - (size.width / 2 - center.x)) < 0.001)
        #expect(abs(resolved!.pan.y - (size.height / 2 - center.y)) < 0.001)
    }

    @Test func resolveIsClampedToCanvasBounds() {
        // 极端远的落点：pan 必须被夹到 ±60% 画布尺寸，不能飞出世界
        let req = makeRequest(center: Point(x: 90_000, y: 90_000))
        let resolved = CanvasView.resolveReveal(
            request: req,
            viewportSize: CGSize(width: 1200, height: 800),
            viewport: ViewportTransform(zoom: 1.0, pan: .zero),
            canvasWidth: canvasW, canvasHeight: canvasH)
        #expect(resolved != nil)
        let limitX = canvasW * 1.0 * 0.6
        let limitY = canvasH * 1.0 * 0.6
        #expect(abs(resolved!.pan.x) <= limitX + 0.001)
        #expect(abs(resolved!.pan.y) <= limitY + 0.001)
    }

    @Test func zoomIsRespectedInTargetPan() {
        // zoom=2 时同样的世界中心应得到更远的平移（screen = world*zoom + pan）
        let size = CGSize(width: 1000, height: 1000)
        let center = Point(x: 1000, y: 1000)
        let resolved = CanvasView.resolveReveal(
            request: makeRequest(center: center),
            viewportSize: size,
            viewport: ViewportTransform(zoom: 2.0, pan: .zero),
            canvasWidth: canvasW, canvasHeight: canvasH)
        #expect(resolved != nil)
        #expect(abs(resolved!.pan.x - (500 - 1000 * 2.0)) < 0.001)
        #expect(abs(resolved!.pan.y - (500 - 1000 * 2.0)) < 0.001)
    }

    @Test func nanRevealRequestOrPollutedViewportIsDropped() {
        // AJ-66 防御：NaN/Infinity 揭示请求直接丢弃（污染视口后只能重启恢复）。
        let nanCenter = CanvasView.resolveReveal(
            request: makeRequest(center: Point(x: Double.nan, y: Double.nan)),
            viewportSize: CGSize(width: 1200, height: 800),
            viewport: ViewportTransform(zoom: 1.0, pan: .zero),
            canvasWidth: canvasW, canvasHeight: canvasH)
        #expect(nanCenter == nil)
        // 视口自身 pan 已被污染（历史 NaN 源）→ 同样拒绝，不产出更坏的平移
        let pollutedViewport = CanvasView.resolveReveal(
            request: makeRequest(center: Point(x: 100, y: 100)),
            viewportSize: CGSize(width: 1200, height: 800),
            viewport: ViewportTransform(zoom: 1.0, pan: CGPoint(x: Double.nan, y: 0)),
            canvasWidth: canvasW, canvasHeight: canvasH)
        #expect(pollutedViewport == nil)
    }

    @Test func revealRequestCenterFiniteCheck() {
        // AJ-66：handleReveal 缓存前先查中心有限性——非有限请求直接丢弃，
        // 绝不缓存进 pendingReveal（resolveReveal 的 nil 也可能是「视口未布局」，两者必须区分）
        let nanReq = makeRequest(center: Point(x: Double.nan, y: 300))
        #expect(CanvasView.revealRequestCenterIsFinite(nanReq) == false)
        let infReq = makeRequest(center: Point(x: 0, y: Double.infinity))
        #expect(CanvasView.revealRequestCenterIsFinite(infReq) == false)
        let okReq = makeRequest(center: Point(x: 100, y: 300))
        #expect(CanvasView.revealRequestCenterIsFinite(okReq) == true)
    }
}