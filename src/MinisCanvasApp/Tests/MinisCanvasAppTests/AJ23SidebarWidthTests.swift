import Testing
import Foundation
@testable import MinisCanvasApp

// MARK: - AJ-23 侧栏宽度记忆 / 恢复 / 拖拽持久化
// 需求：隐藏侧栏前记住当前请求宽度 → 展开恢复原宽度；effective 上限由当前布局空间动态提供。

@Suite("AJ-23 侧栏宽度记忆恢复")
struct SidebarWidthMemoryTests {

    // MARK: - 默认值

    @Test func defaultWidthBounds() {
        #expect(SidebarWidthMemory.defaultWidth == 240)
        #expect(SidebarWidthMemory.minWidth == 56)
        #expect(SidebarWidthMemory.defaultWidth > SidebarWidthMemory.minWidth)
    }

    @Test func defaultInitIsExpandedAndClamped() {
        let m = SidebarWidthMemory()
        #expect(!m.isCollapsed)
        #expect(m.width == SidebarWidthMemory.defaultWidth)
        #expect(m.rememberedWidth == SidebarWidthMemory.defaultWidth)
    }

    // MARK: - 折叠记忆 / 展开恢复

    @Test func collapseRemembersWidthThenZero() {
        var m = SidebarWidthMemory(width: 280)
        m.collapse()
        #expect(m.isCollapsed)
        #expect(m.width == 0)
        // 折叠前记住宽度
        #expect(m.rememberedWidth == 280)
    }

    @Test func expandRestoresOriginalWidth() {
        var m = SidebarWidthMemory(width: 300)
        m.collapse()
        m.expand()
        #expect(!m.isCollapsed)
        // 恢复原宽度（非默认 240）
        #expect(m.width == 300)
    }

    @Test func collapseExpandRoundTripKeepsWidth() {
        var m = SidebarWidthMemory(width: 200)
        m.collapse()
        m.expand()
        m.collapse()
        m.expand()
        #expect(m.width == 200)
        #expect(m.rememberedWidth == 200)
    }

    // MARK: - 拖拽调整（夹取 [min, max]）

    @Test func resizeClampsToMin() {
        var m = SidebarWidthMemory(width: 240)
        m.resize(to: 10)
        #expect(m.width == SidebarWidthMemory.minWidth)
        #expect(m.rememberedWidth == SidebarWidthMemory.minWidth)
    }

    @Test func resizePreservesLargeRequestedWidthForDynamicLayout() {
        var m = SidebarWidthMemory(width: 240)
        m.resize(to: 999)
        #expect(m.width == 999)
        #expect(m.rememberedWidth == 999)
    }

    @Test func resizeWithinBounds() {
        var m = SidebarWidthMemory(width: 240)
        m.resize(to: 275)
        #expect(m.width == 275)
        #expect(m.rememberedWidth == 275)
    }

    @Test func resizeThenExpandUsesNewWidth() {
        var m = SidebarWidthMemory(width: 240)
        m.resize(to: 300)
        m.collapse()
        m.expand()
        // 拖拽后的新宽度被记住，展开恢复拖拽后的宽度
        #expect(m.width == 300)
    }

    // MARK: - 持久化载入

    @Test func loadPersistedAppliesWhenExpanded() {
        var m = SidebarWidthMemory(width: 240)
        m.loadPersisted(300)
        #expect(m.width == 300)
        #expect(m.rememberedWidth == 300)
    }

    @Test func loadPersistedPreservesLargePreferenceAndClampsOnlyInvalidLowValue() {
        var m = SidebarWidthMemory(width: 240)
        m.loadPersisted(500)
        #expect(m.width == 500)
        m.loadPersisted(-5)
        #expect(m.width == SidebarWidthMemory.minWidth)
    }

    @Test func loadPersistedKeepsCollapsedState() {
        var m = SidebarWidthMemory(width: 240)
        m.collapse()
        m.loadPersisted(300)
        // 折叠中不强制应用宽度，但记住持久化值
        #expect(m.isCollapsed)
        #expect(m.rememberedWidth == 300)
    }
}
