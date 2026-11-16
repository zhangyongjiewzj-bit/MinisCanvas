import Foundation
import Testing
@testable import MinisCanvasApp

@Suite("D-APP-14 可见分隔条拖拽起点")
@MainActor
struct AdaptiveDividerVisibleDrag1970Tests {
    @Test("窄窗夹取不改记忆；用户从可见左缘内收立即改变宽度")
    func leftDragStartsAtVisibleDivider() {
        let requested = 999.0
        let decision = AdaptiveLayoutPolicy.decision(
            for: 1_280, preferredLeftWidth: requested, preferredRightWidth: 300
        )
        #expect(decision.leftWidth < requested)
        var memory = SidebarWidthMemory(width: requested)
        #expect(memory.rememberedWidth == requested)

        memory.resize(
            to: decision.leftWidth - 40,
            within: AdaptiveLayoutPolicy.persistentLeftMinimumWidth...decision.leftMaximumWidth
        )
        #expect(memory.width == decision.leftWidth - 40)
        #expect(memory.rememberedWidth == memory.width)

        memory.resize(
            to: decision.leftWidth + 10_000,
            within: AdaptiveLayoutPolicy.persistentLeftMinimumWidth...decision.leftMaximumWidth
        )
        #expect(memory.width == decision.leftMaximumWidth)
    }

    @Test("右栏过大记忆不因缩窗写回，真实拖拽按可见起点与动态范围持久化")
    func rightDragStartsAtVisibleDivider() throws {
        let suite = "AdaptiveDivider1970-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let requested = 10_300.0
        defaults.set(requested, forKey: ContextPanelWidthDragState.settingsKey)
        let decision = AdaptiveLayoutPolicy.decision(
            for: 1_280, preferredLeftWidth: 240, preferredRightWidth: requested
        )
        #expect(decision.rightWidth < requested)
        var drag = ContextPanelWidthDragState(defaults: defaults)
        #expect(drag.width == requested)

        let range = AdaptiveLayoutPolicy.persistentRightMinimumWidth...decision.rightMaximumWidth
        drag.applyPersistedTranslation(
            40, visibleWidth: decision.rightWidth, visibleRange: range, defaults: defaults
        )
        #expect(drag.width == decision.rightWidth - 40)
        #expect(defaults.double(forKey: ContextPanelWidthDragState.settingsKey) == drag.width)
        drag.applyPersistedTranslation(
            -10_000, visibleWidth: decision.rightWidth, visibleRange: range, defaults: defaults
        )
        #expect(drag.width == decision.rightMaximumWidth)
        drag.applyPersistedTranslation(
            10, visibleWidth: decision.rightWidth, visibleRange: range, defaults: defaults
        )
        #expect(drag.width == decision.rightWidth - 10)
        drag.endDrag()
        #expect(ContextPanelWidthDragState(defaults: defaults).width == decision.rightWidth - 10)
    }
}
