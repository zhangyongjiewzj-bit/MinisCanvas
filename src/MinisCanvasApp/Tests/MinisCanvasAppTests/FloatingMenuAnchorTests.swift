import Testing
import AppKit
import Foundation
import CoreGraphics
@testable import MinisCanvasApp

// G10 P2-2 浮动菜单防溢出 clamp（FloatingMenuOverlay.anchorOffset 纯函数）。
// 窗口坐标（AppKit 左下原点）先翻转为 SwiftUI 左上原点；x/y 双轴 clamp 到窗口内，
// 各留 8pt 边距。菜单宽度固定 232，高度由内容实测（含展开子菜单）。
@Suite("浮动菜单锚点 clamp（G10 P2-2）")
struct FloatingMenuAnchorTests {

    @Test("hidden and clipped native catchers cannot steal a visible row")
    @MainActor
    func hiddenAndClippedCatchersAreIneligible() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        window.contentView = root
        let visible = RightClickCatcher.CatcherView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        root.addSubview(visible)
        let hiddenParent = NSView(frame: root.bounds)
        hiddenParent.isHidden = true
        let hidden = RightClickCatcher.CatcherView(frame: NSRect(x: 10, y: 10, width: 20, height: 20))
        hiddenParent.addSubview(hidden)
        root.addSubview(hiddenParent)
        #expect(FloatingMenuHost.findBestCatcher(containing: NSPoint(x: 15, y: 15), in: root) === visible)
        let clip = NSClipView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let clipped = RightClickCatcher.CatcherView(frame: NSRect(x: 10, y: 10, width: 20, height: 20))
        document.addSubview(clipped)
        clip.documentView = document
        root.addSubview(clip)
        #expect(FloatingMenuHost.findBestCatcher(containing: NSPoint(x: 15, y: 15), in: root) === visible)
        visible.isHidden = true
        #expect(FloatingMenuHost.findBestCatcher(containing: NSPoint(x: 15, y: 15), in: root) == nil)
    }

    /// 常规：鼠标在窗口上部（AppKit y 大），向下展开空间充足 → 不触发 clamp，锚定鼠标右下 +8pt。
    @Test func centerPointUnclamped() {
        let offset = FloatingMenuOverlay.anchorOffset(
            windowPoint: CGPoint(x: 400, y: 400), // AppKit 左下原点
            size: CGSize(width: 800, height: 600),
            menuSize: CGSize(width: 232, height: 300)
        )
        // SwiftUI 左上原点：y = 600 - 400 + 8 = 208；菜单底 208+300=508 ≤ 592，无溢出
        #expect(offset.width == 408)
        #expect(offset.height == 208)
    }

    /// 右缘：鼠标靠近窗口右缘 → x clamp，菜单右缘距窗口右缘 8pt。
    @Test func rightEdgeClampsX() {
        let offset = FloatingMenuOverlay.anchorOffset(
            windowPoint: CGPoint(x: 790, y: 300),
            size: CGSize(width: 800, height: 600),
            menuSize: CGSize(width: 232, height: 300)
        )
        // x 上限 = 800 - 232 - 8 = 560
        #expect(offset.width == 560)
    }

    /// 左缘：鼠标靠近窗口左缘 → x clamp 下限 8pt（菜单不被推出窗口左侧）。
    @Test func leftEdgeClampsX() {
        let offset = FloatingMenuOverlay.anchorOffset(
            windowPoint: CGPoint(x: 0, y: 300),
            size: CGSize(width: 800, height: 600),
            menuSize: CGSize(width: 232, height: 300)
        )
        #expect(offset.width == 8)
    }

    /// 底部：鼠标靠近窗口底部（AppKit y 小）→ y clamp，菜单底部距窗口底部 8pt。
    @Test func bottomEdgeClampsY() {
        let offset = FloatingMenuOverlay.anchorOffset(
            windowPoint: CGPoint(x: 400, y: 10),
            size: CGSize(width: 800, height: 600),
            menuSize: CGSize(width: 232, height: 300)
        )
        // y 上限 = 600 - 300 - 8 = 292（菜单底部贴 8pt 边距）
        #expect(offset.height == 292)
    }

    /// 顶部：窗口高度不足以放下菜单（窗口比菜单矮）→ y clamp 下限 8pt（菜单顶部贴 8pt，允许上溢出）。
    @Test func tinyWindowClampsToTop() {
        let offset = FloatingMenuOverlay.anchorOffset(
            windowPoint: CGPoint(x: 400, y: 100), // 鼠标在窗口内（窗口高 200）
            size: CGSize(width: 400, height: 200), // 窗口比菜单矮
            menuSize: CGSize(width: 232, height: 300)
        )
        // max(8, 200 - 300 - 8) = 8 → min(200-100+8=108, 8) = 8
        #expect(offset.height == 8)
    }

    /// 高度未知（首次渲染 menuHeight=0）→ 按底部边界保守处理，不误判。
    @Test func unknownHeightFallsBackToBottom() {
        let offset = FloatingMenuOverlay.anchorOffset(
            windowPoint: CGPoint(x: 400, y: 300),
            size: CGSize(width: 800, height: 600),
            menuSize: CGSize(width: 232, height: 0)
        )
        // y = min(308, max(8, 600-0-8=592)) = 308（未触发 clamp）
        #expect(offset.height == 308)
    }

    /// 11/19 包上：会话右键菜单（15 行 + 4 条分隔线）在窗口下半部弹出时伸出窗口底部。
    /// 实测高度没进 clamp 时，按菜单项估出的高度也要把菜单整块收进窗口。
    @Test func sessionMenuStaysInsideWindowWithoutMeasuredHeight() {
        var items: [FloatingMenuItem] = []
        for index in 0..<15 {
            items.append(FloatingMenuItem(kind: .button(title: "项\(index)", icon: nil, role: nil, help: nil) {}))
            if [2, 4, 6, 10].contains(index) { items.append(FloatingMenuItem(kind: .divider)) }
        }
        let estimated = FloatingMenuOverlay.estimatedPanelHeight(items)
        // 15×26 + 4×5 + 18×2 + 10 = 456
        #expect(estimated == 456)
        let size = CGSize(width: 1000, height: 830)
        let offset = FloatingMenuOverlay.anchorOffset(
            windowPoint: CGPoint(x: 150, y: 830 - 665), // 截图里的点击位置：离窗口顶部 665pt
            size: size,
            menuSize: CGSize(width: 232, height: max(0, estimated))
        )
        #expect(offset.height + estimated <= size.height - 8)
        #expect(FloatingMenuOverlay.estimatedPanelHeight([]) == 0)
    }
}
