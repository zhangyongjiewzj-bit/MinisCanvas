import Testing
import Foundation
import CanvasCore
@testable import MinisCanvasApp

// MARK: - AJ-2 粘贴定位：鼠标不在画布上时用视口中心
//
// 病根（08-04 用户仍实测"⌘V 粘贴的节点找不到"）：⌘V 用 NSEvent.mouseLocation 换算
// 画布本地坐标作为落点。当鼠标悬在工具栏/侧栏/窗口外时，换算出的本地坐标出画布 bounds，
// 世界坐标极远 → 粘贴节点被贴到画布外，用户看不见。
// 修法：CanvasKeyboardCatcher 判定鼠标是否在画布 bounds 内，不在则传 nil；
// CanvasView.pasteTargetWorld 对 nil 改用视口中心世界坐标。

@Suite("AJ-2 粘贴定位：鼠标不在画布时用视口中心")
@MainActor
struct AJ2PasteTargetTests {

    @Test func mouseOnCanvasUsesMouseWorldPoint() {
        let vp = ViewportTransform(zoom: 1.0, pan: CGPoint(x: 100, y: 50))
        let screen = CGPoint(x: 300, y: 200)
        // world = (screen - pan) / zoom
        let target = CanvasView.pasteTargetWorld(screen: screen, viewport: vp, viewportSize: CGSize(width: 1200, height: 800))
        #expect(abs(target.x - 200) < 0.001)   // (300-100)/1
        #expect(abs(target.y - 150) < 0.001)   // (200-50)/1
    }

    @Test func mouseOffCanvasUsesViewportCenter() {
        let vp = ViewportTransform(zoom: 1.0, pan: CGPoint(x: 100, y: 50))
        // 鼠标在画布外 → screen 为 nil → 用视口中心 (1200/2, 800/2)
        let target = CanvasView.pasteTargetWorld(screen: nil, viewport: vp, viewportSize: CGSize(width: 1200, height: 800))
        #expect(abs(target.x - (600 - 100)) < 0.001)   // (600-100)/1
        #expect(abs(target.y - (400 - 50)) < 0.001)    // (400-50)/1
    }

    @Test func mouseOffCanvasCentersInCurrentViewport() {
        // 平移后视口中心改变 → 落点跟随当前视口中心（不是固定原点）
        let vp = ViewportTransform(zoom: 1.0, pan: CGPoint(x: 500, y: 300))
        let target = CanvasView.pasteTargetWorld(screen: nil, viewport: vp, viewportSize: CGSize(width: 1000, height: 600))
        #expect(abs(target.x - (500 - 500)) < 0.001)   // 中心 500 → 500-500=0
        #expect(abs(target.y - (300 - 300)) < 0.001)   // 中心 300 → 300-300=0
    }

    @Test func mouseOffCanvasRespectsZoom() {
        // zoom=2 时视口中心世界坐标 = (screenCenter - pan)/zoom
        let vp = ViewportTransform(zoom: 2.0, pan: CGPoint(x: 0, y: 0))
        let target = CanvasView.pasteTargetWorld(screen: nil, viewport: vp, viewportSize: CGSize(width: 1000, height: 500))
        #expect(abs(target.x - 250) < 0.001)   // 500/2
        #expect(abs(target.y - 125) < 0.001)   // 250/2
    }

    @Test func zeroViewportSizeStillProducesReasonablePoint() {
        // viewportSize 未布局（0）时退化为 pan 处世界点，由 reveal 兜底居中，不崩
        let vp = ViewportTransform(zoom: 1.0, pan: CGPoint(x: 100, y: 100))
        let target = CanvasView.pasteTargetWorld(screen: nil, viewport: vp, viewportSize: .zero)
        #expect(abs(target.x - (-100)) < 0.001)
        #expect(abs(target.y - (-100)) < 0.001)
    }

    @Test func pollutedViewportStillProducesFinitePasteTarget() {
        // AJ-66：视口已被污染（NaN zoom）时 pasteTargetWorld 仍产出有限落点
        //（world() 防线退化 .zero；若此处放行 NaN，store.paste 会落 (400,300) 兜底）
        let polluted = ViewportTransform(zoom: Double.nan, pan: .zero)
        let target = CanvasView.pasteTargetWorld(screen: nil, viewport: polluted,
                                                 viewportSize: CGSize(width: 800, height: 600))
        #expect(target.x.isFinite && target.y.isFinite)
    }
}