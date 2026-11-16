import Foundation
import Testing
@testable import MinisCanvasApp

/// These exercise the preference/gesture consumers used by the actual views.
/// They do not mount a substitute view, enable Canvas, or claim sheet geometry.
@Suite("D-APP-05 现有面板宽度与重开消费者")
@MainActor
struct RightPanelWidthConsumer556Tests {
    private struct Fixture {
        let root: URL
        let suiteName: String
        let defaults: UserDefaults

        init() throws {
            let id = UUID().uuidString
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("RightPanel556-\(id)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            suiteName = "RightPanel556-\(id)"
            defaults = try #require(UserDefaults(suiteName: suiteName))
        }

        func reopenedDefaults() throws -> UserDefaults {
            defaults.synchronize()
            return try #require(UserDefaults(suiteName: suiteName))
        }
    }

    @Test("资产实际拖拽使用累积位移，夹取后反拖仍以原起点计算")
    func assetDragUsesGestureOriginAndBounds() throws {
        let fixture = try Fixture()
        let setting = AssetPanelWidthSetting(defaults: fixture.defaults)
        #expect(setting.width == 720)
        setting.applyDragTranslation(100)
        #expect(setting.width == 820)
        setting.applyDragTranslation(200)
        #expect(setting.width == 920)
        setting.applyDragTranslation(10_000)
        #expect(setting.width == 1_120)
        setting.applyDragTranslation(120)
        #expect(setting.width == 840)
        setting.applyDragTranslation(-10_000)
        #expect(setting.width == 720)
        setting.endDrag()
        setting.applyDragTranslation(80)
        #expect(setting.width == 800)
        #expect(fixture.defaults.double(forKey: AssetPanelWidthSetting.settingsKey) == 800)
    }

    @Test("资产关闭销毁消费者后重开从同一个自有preferences域恢复")
    func assetReopenRetainsDraggedWidth() throws {
        let fixture = try Fixture()
        do {
            let setting = AssetPanelWidthSetting(defaults: fixture.defaults)
            setting.applyDragTranslation(240)
            setting.endDrag()
            #expect(setting.width == 960)
        }
        let reopened = AssetPanelWidthSetting(defaults: try fixture.reopenedDefaults())
        #expect(reopened.width == 960)
        reopened.applyDragTranslation(-40)
        #expect(reopened.width == 920)
        reopened.endDrag()
        #expect(AssetPanelWidthSetting(defaults: fixture.defaults).width == 920)
    }

    @Test("资产合法范围与错误偏好值不会形成非有限或不可读布局")
    func assetPreferenceNormalizationAndInvalidDrag() throws {
        let fixture = try Fixture()
        let cases: [(Double, Double)] = [(-1, 720), (720, 720), (900, 900),
                                        (1_120, 1_120), (9_000, 1_120),
                                        (.nan, 720), (.infinity, 720), (-.infinity, 720)]
        for (raw, expected) in cases {
            fixture.defaults.set(raw, forKey: AssetPanelWidthSetting.settingsKey)
            let setting = AssetPanelWidthSetting(defaults: fixture.defaults)
            #expect(setting.width == expected)
        }
        fixture.defaults.set("invalid synthetic width", forKey: AssetPanelWidthSetting.settingsKey)
        #expect(AssetPanelWidthSetting(defaults: fixture.defaults).width == 720)
        let setting = AssetPanelWidthSetting(defaults: fixture.defaults)
        setting.write(880)
        for invalid in [Double.nan, .infinity, -.infinity] {
            setting.applyDragTranslation(invalid)
            setting.adjust(by: invalid)
            #expect(setting.width == 880)
            #expect(fixture.defaults.double(forKey: AssetPanelWidthSetting.settingsKey) == 880)
        }
    }

    @Test("资产AX调宽和指针使用同一持久值且结束旧gesture")
    func assetAdjustmentUsesTheSameConsumer() throws {
        let fixture = try Fixture()
        let setting = AssetPanelWidthSetting(defaults: fixture.defaults)
        setting.applyDragTranslation(200)
        setting.adjust(by: 40)
        #expect(setting.width == 960)
        setting.applyDragTranslation(-40)
        #expect(setting.width == 920)
        setting.endDrag()
        setting.adjust(by: 10_000)
        #expect(setting.width == 1_120)
        setting.adjust(by: -10_000)
        #expect(setting.width == 720)
        #expect(AssetPanelWidthSetting(defaults: fixture.defaults).width == 720)
    }

    @Test("上下文现有左缘handle使用真实方向和同源preferences重开")
    func contextHandlePersistsAndReopensWithoutAccumulation() throws {
        let fixture = try Fixture()
        fixture.defaults.set(380, forKey: ContextPanelWidthDragState.settingsKey)
        var state = ContextPanelWidthDragState(defaults: fixture.defaults)
        state.applyPersistedTranslation(-40, defaults: fixture.defaults)
        #expect(state.width == 420)
        state.applyPersistedTranslation(-80, defaults: fixture.defaults)
        #expect(state.width == 460)
        state.endDrag()
        var reopened = ContextPanelWidthDragState(defaults: try fixture.reopenedDefaults())
        #expect(reopened.width == 460)
        reopened.applyPersistedTranslation(40, defaults: fixture.defaults)
        #expect(reopened.width == 420)
        reopened.endDrag()
        #expect(ContextPanelWidthDragState(defaults: fixture.defaults).width == 420)
    }

    @Test("上下文临时空间上界与用户隐藏不覆盖拖宽后的重开记忆")
    func contextLayoutProjectionKeepsRequestedWidth() throws {
        let fixture = try Fixture()
        var drag = ContextPanelWidthDragState(defaults: fixture.defaults)
        drag.applyPersistedTranslation(-10_000, defaults: fixture.defaults)
        drag.endDrag()
        for containerWidth in [600.0, 800.0, 1_000.0, 1_280.0, 1_600.0] {
            let recovered = ContextPanelWidthDragState(defaults: fixture.defaults)
            let decision = AdaptiveLayoutPolicy.decision(for: containerWidth,
                preferredLeftWidth: 240, preferredRightWidth: recovered.width)
            #expect(recovered.width == 10_300)
            #expect(decision.rightWidth <= decision.rightMaximumWidth)
            #expect(decision.rightWidth < recovered.width)
            var layout = AdaptiveLayoutState(persistenceLoaded: true)
            layout = AdaptiveLayoutReducer.reduce(layout, .widthClassChanged(decision.widthClass))
            layout = AdaptiveLayoutReducer.reduce(layout, .userSetContextPanelCollapsed(true))
            #expect(!layout.contextPanelVisible)
            layout = AdaptiveLayoutReducer.reduce(layout, .userSetContextPanelCollapsed(false))
            #expect(layout.contextPanelVisible)
            #expect(ContextPanelWidthDragState(defaults: fixture.defaults).width == 10_300)
        }
        var reopened = ContextPanelWidthDragState(defaults: fixture.defaults)
        reopened.applyPersistedTranslation(20_000, defaults: fixture.defaults)
        #expect(reopened.width == SidebarWidthMemory.minWidth)
        for invalid in [Double.nan, .infinity, -.infinity] {
            reopened.applyPersistedTranslation(invalid, defaults: fixture.defaults)
            #expect(reopened.width == SidebarWidthMemory.minWidth)
        }
        #expect(ContextPanelWidthDragState(defaults: fixture.defaults).width == SidebarWidthMemory.minWidth)
    }

    @Test("上下文用户显隐和资产关闭重开均保留独立偏好，不向宽度写0")
    func bothPanelPreferencesStaySeparateAcrossPresentationLifecycle() throws {
        let fixture = try Fixture()
        fixture.defaults.set("owned sentinel", forKey: "unrelated556")
        fixture.defaults.set(470, forKey: ContextPanelWidthDragState.settingsKey)
        let asset = AssetPanelWidthSetting(defaults: fixture.defaults)
        asset.write(940)
        var layout = AdaptiveLayoutState(persistenceLoaded: true)
        for collapsed in [true, false] {
            layout = AdaptiveLayoutReducer.reduce(layout, .userSetContextPanelCollapsed(collapsed))
            #expect(layout.contextPanelVisible == !collapsed)
            #expect(ContextPanelWidthDragState(defaults: fixture.defaults).width == 470)
            // AssetPanelView.onDisappear ends its active drag; a new sheet
            // reconstructs this same consumer from its injected preferences.
            asset.endDrag()
            #expect(AssetPanelWidthSetting(defaults: fixture.defaults).width == 940)
            #expect(fixture.defaults.string(forKey: "unrelated556") == "owned sentinel")
        }
        var context = ContextPanelWidthDragState(defaults: fixture.defaults)
        context.applyPersistedTranslation(-50, defaults: fixture.defaults)
        #expect(context.width == 520)
        #expect(asset.width == 940)
        asset.adjust(by: 40)
        #expect(asset.width == 980)
        #expect(ContextPanelWidthDragState(defaults: fixture.defaults).width == 520)
    }

    @Test("独立自有preferences域不继承其他窗口测试的width")
    func separatePreferenceDomainsStayIndependent() throws {
        let first = try Fixture()
        let second = try Fixture()
        let setting = AssetPanelWidthSetting(defaults: first.defaults)
        setting.write(1_080)
        var context = ContextPanelWidthDragState(defaults: first.defaults)
        context.applyPersistedTranslation(-150, defaults: first.defaults)
        #expect(AssetPanelWidthSetting(defaults: second.defaults).width == 720)
        #expect(ContextPanelWidthDragState(defaults: second.defaults).width == 300)
        #expect(AssetPanelWidthSetting(defaults: first.defaults).width == 1_080)
        #expect(ContextPanelWidthDragState(defaults: first.defaults).width == 450)
    }
}
