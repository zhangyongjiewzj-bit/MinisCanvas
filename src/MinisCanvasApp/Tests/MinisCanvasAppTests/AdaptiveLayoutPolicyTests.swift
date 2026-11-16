import Foundation
import Testing

@testable import MinisCanvasApp

@Suite("A7-A 全 App 自适应布局合同")
struct AdaptiveLayoutPolicyTests {
    private func state(after events: [AdaptiveLayoutEvent]) -> AdaptiveLayoutState {
        events.reduce(into: AdaptiveLayoutState()) { state, event in
            state = AdaptiveLayoutReducer.reduce(state, event)
        }
    }

    private func contentViewSource() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MinisCanvasAppTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // MinisCanvasApp
            .deletingLastPathComponent() // src
            .deletingLastPathComponent() // repository
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "src/MinisCanvasApp/Sources/MinisCanvasApp/ContentView.swift"
            ),
            encoding: .utf8
        )
    }

    @Test("600–1600pt 矩阵映射到四档宽度类")
    func widthClassMatrix() {
        #expect(AdaptiveLayoutPolicy.widthClass(for: 600) == .compact)
        #expect(AdaptiveLayoutPolicy.widthClass(for: 799) == .compact)
        #expect(AdaptiveLayoutPolicy.widthClass(for: 800) == .medium)
        #expect(AdaptiveLayoutPolicy.widthClass(for: 1_000) == .medium)
        #expect(AdaptiveLayoutPolicy.widthClass(for: 1_099) == .medium)
        #expect(AdaptiveLayoutPolicy.widthClass(for: 1_100) == .regular)
        #expect(AdaptiveLayoutPolicy.widthClass(for: 1_280) == .regular)
        #expect(AdaptiveLayoutPolicy.widthClass(for: 1_399) == .regular)
        #expect(AdaptiveLayoutPolicy.widthClass(for: 1_400) == .wide)
        #expect(AdaptiveLayoutPolicy.widthClass(for: 1_600) == .wide)
    }

    @Test("Settings metrics reuse the global adaptive width policy")
    func settingsMetricsShareGlobalWidthClasses() {
        #expect(SettingsLayoutMetrics.forWidth(600).adaptiveWidthClass == .compact)
        #expect(SettingsLayoutMetrics.forWidth(800).adaptiveWidthClass == .medium)
        #expect(SettingsLayoutMetrics.forWidth(1_100).adaptiveWidthClass == .regular)
        #expect(SettingsLayoutMetrics.forWidth(1_600).adaptiveWidthClass == .wide)
    }

    @Test("紧凑屏左右栏均转 overlay，主区保留全宽")
    func compactUsesTwoOverlays() {
        let decision = AdaptiveLayoutPolicy.decision(
            for: 600,
            preferredLeftWidth: 280,
            preferredRightWidth: 300
        )

        #expect(decision.widthClass == .compact)
        #expect(decision.leftPanel == .overlay)
        #expect(decision.rightPanel == .overlay)
        #expect(decision.mainMinimumWidth == 600)
        #expect(!decision.showsSecondaryToolbarLabels)
    }

    @Test("中档保留可调左栏，右栏先转 overlay")
    func mediumKeepsLeftAndOverlaysRight() {
        let decision = AdaptiveLayoutPolicy.decision(
            for: 1_000,
            preferredLeftWidth: 280,
            preferredRightWidth: 300
        )

        #expect(decision.leftPanel == .persistent)
        #expect(decision.leftWidth == 280)
        #expect(decision.rightPanel == .overlay)
        #expect(decision.mainMinimumWidth == 520)
    }

    @Test("常规和宽屏按当前可用空间计算两栏 effective width")
    func regularAndWideKeepPersistentPanels() {
        let regular = AdaptiveLayoutPolicy.decision(
            for: 1_280,
            preferredLeftWidth: 999,
            preferredRightWidth: 40
        )
        #expect(regular.leftPanel == .persistent)
        #expect(regular.leftWidth == 470)
        #expect(regular.rightPanel == .persistentCollapsible)
        #expect(regular.rightWidth == 248)
        #expect(regular.mainMinimumWidth == 560)

        let wide = AdaptiveLayoutPolicy.decision(
            for: 1_600,
            preferredLeftWidth: 244,
            preferredRightWidth: 280
        )
        #expect(wide.leftPanel == .persistent)
        #expect(wide.rightPanel == .persistentCollapsible)
        #expect(wide.leftWidth == 244)
        #expect(wide.rightWidth == 280)
        #expect(wide.mainMinimumWidth == 680)
    }

    @Test("effective panel width grows with available space without a fixed 300/320 cap")
    func effectivePanelWidthGrowsWithAvailableSpace() {
        let widths = [1_100.0, 1_280.0, 1_600.0]
        let decisions = widths.map {
            AdaptiveLayoutPolicy.decision(
                for: $0,
                preferredLeftWidth: 900,
                preferredRightWidth: 900
            )
        }

        #expect(decisions[0].leftWidth <= decisions[1].leftWidth)
        #expect(decisions[1].leftWidth < decisions[2].leftWidth)
        #expect(decisions[2].leftWidth > 320)
        #expect(decisions[2].rightWidth > 320)
        for (width, decision) in zip(widths, decisions) {
            #expect(decision.leftWidth >= AdaptiveLayoutPolicy.persistentLeftMinimumWidth)
            #expect(decision.rightWidth >= AdaptiveLayoutPolicy.persistentRightMinimumWidth)
            #expect(decision.leftWidth <= decision.leftMaximumWidth)
            #expect(decision.rightWidth <= decision.rightMaximumWidth)
            #expect(decision.leftWidth + decision.rightWidth + decision.mainMinimumWidth <=
                    max(width, AdaptiveLayoutPolicy.minimumSupportedWidth))
        }
    }

    @Test("持久化载入前不施加自动折叠")
    func persistenceMustLoadBeforeAutomaticCollapse() {
        let beforeLoad = state(after: [.widthClassChanged(.compact)])

        #expect(beforeLoad.widthClass == .compact)
        #expect(!beforeLoad.persistenceLoaded)
        #expect(!beforeLoad.sessionSidebarCollapsed)
        #expect(beforeLoad.contextPanelVisible)

        let afterLoad = AdaptiveLayoutReducer.reduce(beforeLoad, .persistenceLoaded)
        #expect(afterLoad.persistenceLoaded)
        #expect(afterLoad.sessionSidebarCollapsed)
        #expect(!afterLoad.contextPanelVisible)
    }

    @Test("compact 回到 medium 恢复请求的左栏宽度且右栏继续 overlay")
    func compactToMediumRestoresLeftPanel() {
        let compact = state(after: [
            .persistenceLoaded,
            .widthClassChanged(.compact)
        ])
        let medium = AdaptiveLayoutReducer.reduce(compact, .widthClassChanged(.medium))
        let decision = AdaptiveLayoutPolicy.decision(
            for: 800,
            preferredLeftWidth: 280,
            preferredRightWidth: 300
        )

        #expect(compact.sessionSidebarCollapsed)
        #expect(!compact.contextPanelVisible)
        #expect(!medium.sessionSidebarCollapsed)
        #expect(!medium.contextPanelVisible)
        #expect(decision.leftPanel == .persistent)
        #expect(decision.leftWidth == 279)
        #expect(decision.rightPanel == .overlay)
    }

    @Test("medium → compact → medium 不会把左栏永久留在自动折叠")
    func mediumCompactMediumRestoresLeftPanel() {
        let medium = state(after: [
            .persistenceLoaded,
            .widthClassChanged(.medium)
        ])
        let compact = AdaptiveLayoutReducer.reduce(medium, .widthClassChanged(.compact))
        let restored = AdaptiveLayoutReducer.reduce(compact, .widthClassChanged(.medium))

        #expect(!medium.sessionSidebarCollapsed)
        #expect(!medium.contextPanelVisible)
        #expect(compact.sessionSidebarCollapsed)
        #expect(!compact.contextPanelVisible)
        #expect(!restored.sessionSidebarCollapsed)
        #expect(!restored.contextPanelVisible)
    }

    @Test("用户显式折叠独立于自动折叠并跨宽度类保留")
    func userCollapseSurvivesAutomaticTransitions() {
        var state = self.state(after: [
            .persistenceLoaded,
            .widthClassChanged(.regular),
            .userSetSessionSidebarCollapsed(true),
            .userSetContextPanelCollapsed(true)
        ])

        #expect(state.sessionSidebarCollapsed)
        #expect(!state.contextPanelVisible)

        for widthClass in [AdaptiveWidthClass.compact, .medium, .regular, .wide] {
            state = AdaptiveLayoutReducer.reduce(state, .widthClassChanged(widthClass))
            #expect(state.sessionSidebarCollapsed)
            #expect(!state.contextPanelVisible)
        }

        state = AdaptiveLayoutReducer.reduce(state, .userSetSessionSidebarCollapsed(false))
        state = AdaptiveLayoutReducer.reduce(state, .userSetContextPanelCollapsed(false))
        #expect(!state.sessionSidebarCollapsed)
        #expect(state.contextPanelVisible)
    }

    @Test("overlay 可由用户重新打开且不会被同一宽度事件立即关闭")
    func overlayReopenClearsAutomaticCollapse() {
        var state = self.state(after: [
            .persistenceLoaded,
            .widthClassChanged(.compact)
        ])

        state = AdaptiveLayoutReducer.reduce(state, .userSetContextPanelCollapsed(false))
        #expect(state.contextPanelVisible)
        state = AdaptiveLayoutReducer.reduce(state, .widthClassChanged(.compact))
        #expect(state.contextPanelVisible)

        state = AdaptiveLayoutReducer.reduce(state, .userSetContextPanelCollapsed(true))
        #expect(!state.contextPanelVisible)
        state = AdaptiveLayoutReducer.reduce(state, .userSetContextPanelCollapsed(false))
        #expect(state.contextPanelVisible)
    }

    @Test("compact 交替打开抽屉互斥且不改变用户偏好")
    func compactOverlayRequestsAreExclusiveAndTemporary() {
        var state = self.state(after: [
            .persistenceLoaded,
            .widthClassChanged(.compact)
        ])
        state = AdaptiveLayoutReducer.reduce(state, .userSetSessionSidebarCollapsed(false))
        state = AdaptiveLayoutReducer.reduce(state, .compactOverlayOpened(.sessionSidebar))
        #expect(!state.sessionSidebarCollapsed)
        #expect(!state.contextPanelVisible)

        state = AdaptiveLayoutReducer.reduce(state, .userSetContextPanelCollapsed(false))
        state = AdaptiveLayoutReducer.reduce(state, .compactOverlayOpened(.contextPanel))
        #expect(state.sessionSidebarCollapsed)
        #expect(state.contextPanelVisible)
        #expect(!state.userSessionSidebarCollapsed)
        #expect(!state.userContextPanelCollapsed)

        state = AdaptiveLayoutReducer.reduce(state, .widthClassChanged(.regular))
        #expect(!state.sessionSidebarCollapsed)
        #expect(state.contextPanelVisible)
    }

    @Test("主窗口消费统一策略且不再锁死 960pt")
    func contentViewUsesAdaptivePolicy() throws {
        let source = try contentViewSource()

        #expect(source.contains("AdaptiveLayoutPolicy.decision("))
        #expect(source.contains(".frame(minWidth: AdaptiveLayoutPolicy.minimumSupportedWidth"))
        #expect(source.contains("let leftIsOverlay = decision.leftPanel == .overlay"))
        #expect(source.contains("let rightIsOverlay = decision.rightPanel == .overlay"))
        #expect(source.contains("mainMinWidth: decision.mainMinimumWidth"))
        #expect(source.contains("toolbar(decision: decision)"))
        #expect(source.contains("showsTitle: decision.showsSecondaryToolbarLabels"))
        #expect(!source.contains(".frame(minWidth: 960, minHeight: 620)"))
    }

    @Test("ContentView 先载入宽度持久化再允许 adaptive collapse")
    func contentViewLoadsPersistenceBeforeReducer() throws {
        let source = try contentViewSource()
        let loaded = try #require(source.range(of: ".persistenceLoaded"))
        let storedWidth = try #require(source.range(of: "sidebarWidth = SidebarWidthMemory(width: storedSidebarWidth).width"))

        #expect(storedWidth.lowerBound < loaded.lowerBound)
        #expect(source.contains("guard !adaptiveLayoutState.persistenceLoaded else { return }"))
        #expect(source.contains("guard adaptiveLayoutState.persistenceLoaded else { return }"))
        #expect(!source.contains("applyAdaptiveWidthClass"))
    }
}
