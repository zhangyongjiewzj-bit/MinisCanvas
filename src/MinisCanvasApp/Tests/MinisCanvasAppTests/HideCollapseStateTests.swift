import Testing
import Foundation
@testable import MinisCanvasApp

// MARK: - AJ-69 全界面隐藏/折叠按钮统一状态机回归测试
// 需求：折叠 = 显示宽度置 0 + collapsed 标志；展开 = 恢复用户记忆宽度，布局按窗口临时夹取；
//       0 宽不渲染（无 1px 残留条）；记忆宽度跨折叠/展开往返不丢失。
// 覆盖入口：主侧栏 F5/⌘⇧C、伴随对话栏、右栏上下文面板（三栏共用 SidebarWidthMemory 状态机）。

@Suite("AJ-69 隐藏/折叠统一状态机")
struct HideCollapseStateTests {

    // MARK: - 统一 toggle 入口（工具栏按钮 / 快捷键 / 栏内按钮共用）

    @Test("toggle 往返：折叠记住宽度，展开恢复原宽度（记忆宽度不丢失）")
    func toggleRoundTripPreservesWidth() {
        var m = SidebarWidthMemory(width: 280)
        m.toggle()   // 折叠
        #expect(m.isCollapsed)
        #expect(m.width == 0)
        #expect(m.rememberedWidth == 280)
        m.toggle()   // 展开
        #expect(!m.isCollapsed)
        // 恢复原宽度（非默认 240），记忆宽度未丢失
        #expect(m.width == 280)
        #expect(m.rememberedWidth == 280)
    }

    @Test("toggle 默认宽度往返：折叠→展开回到 240")
    func toggleDefaultWidthRoundTrip() {
        var m = SidebarWidthMemory()
        m.toggle()
        #expect(m.width == 0)
        m.toggle()
        #expect(m.width == SidebarWidthMemory.defaultWidth)
    }

    @Test("collapse/expand 往返多次：宽度稳定不漂移")
    func repeatedToggleKeepsWidthStable() {
        var m = SidebarWidthMemory(width: 200)
        for _ in 0..<4 {
            m.toggle()   // 折叠
            #expect(m.width == 0)
            m.toggle()   // 展开
            #expect(m.width == 200)
        }
        #expect(m.rememberedWidth == 200)
    }

    // MARK: - 展开恢复请求宽度（保留最小值，窗口有效上界不写回记忆）

    @Test("折叠后展开：恢复请求宽度且窗口收缩不覆盖记忆")
    func expandRestoresRequestedWidthAcrossWindowSizes() {
        var m = SidebarWidthMemory(width: 240)
        m.collapse()
        m.loadPersisted(500)
        #expect(m.width == 0)
        #expect(m.rememberedWidth == 500)
        m.expand()
        #expect(m.width == 500)
        #expect(!m.isCollapsed)

        let shrunk = DeterministicSplitGeometry.effectiveSidebarWidth(
            containerWidth: 600,
            requestedSidebarWidth: m.width,
            mainMinimumWidth: 420
        )
        #expect(shrunk == 180)
        #expect(m.rememberedWidth == 500)
        let expanded = DeterministicSplitGeometry.effectiveSidebarWidth(
            containerWidth: 1_280,
            requestedSidebarWidth: m.width,
            mainMinimumWidth: 420
        )
        #expect(expanded == 500)
        #expect(m.width == 500)
        #expect(m.rememberedWidth == 500)
    }

    @Test("折叠后展开：超下界记忆宽度被夹取到 minWidth")
    func expandClampsToMin() {
        var m = SidebarWidthMemory(width: 240)
        m.collapse()
        // 折叠中载入超下界持久化宽度：记忆被夹取到 min，宽度保持 0
        m.loadPersisted(10)
        #expect(m.rememberedWidth == SidebarWidthMemory.minWidth)
        m.expand()
        #expect(m.width == SidebarWidthMemory.minWidth)
        #expect(!m.isCollapsed)
    }

    // MARK: - 0 宽折叠契约（DeterministicSplitView 对 w < 1 不渲染 → 无 1px 残留）

    @Test("折叠态宽度恒为 0（0 宽不渲染契约，杜绝 1px 残留条）")
    func collapsedWidthIsExactlyZero() {
        var m = SidebarWidthMemory(width: 300)
        m.collapse()
        #expect(m.width == 0)
        // 折叠中载入持久化宽度：宽度保持 0，仅更新记忆值
        m.loadPersisted(310)
        #expect(m.isCollapsed)
        #expect(m.width == 0)
        #expect(m.rememberedWidth == 310)
        // 展开恢复载入后的记忆宽度
        m.expand()
        #expect(m.width == 310)
        #expect(!m.isCollapsed)
    }

    @Test("拖拽调宽后 toggle 往返：恢复拖拽后的新宽度")
    func resizeThenToggleRoundTrip() {
        var m = SidebarWidthMemory(width: 240)
        m.resize(to: 310)
        m.toggle()   // 折叠
        #expect(m.width == 0)
        m.toggle()   // 展开
        #expect(m.width == 310)
    }

    // MARK: - 右栏上下文面板状态机（与主侧栏/伴随栏同构：默认请求宽度 300）

    @Test("右栏默认请求宽度保持可用并服从当前布局上界")
    func contextPanelDefaultWithinBounds() {
        let m = SidebarWidthMemory(width: 300)
        #expect(m.width == 300)
        #expect(m.rememberedWidth == 300)
        #expect(m.width >= SidebarWidthMemory.minWidth)
        let decision = AdaptiveLayoutPolicy.decision(
            for: 1_280,
            preferredLeftWidth: 240,
            preferredRightWidth: m.width
        )
        #expect(decision.rightWidth == 300)
        #expect(decision.rightWidth <= decision.rightMaximumWidth)
    }
}
