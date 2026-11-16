import Foundation
import Testing
@testable import MinisCanvasApp
@testable import MinisCore

// P3-BROWSER-01（A/B 会话隔离，腿 (b)：切换对话时面板必须重新派生 scope）。
// 154 只完成了用户侧 scope 派生并披露残差：BrowserSession 在 onAppear 一次性
// 按当时的 conversationSessionID 构造，对话切换而面板存活时旧面板继续携带首个
// scope，直到面板被重建。193 按仓库既有身份模式（同 switch 内 .terminal 分支
// 的 `.id(terminalContextSnapshot)`）把 BrowserTabView 的视图身份绑定到
// 可信会话和工作区。本文件在源码/逻辑两级正向钉住：
// 1) 生产调用点：BrowserTabView 同时收到可信身份和父面板生命周期 owner，
//    并以复合 `.id(browserPaneIdentity)` 绑定重建；
// 2) scope 仍只经 154 的唯一派生链构造（会话与可信 workspace
//    一起传入 userBrowserScope），193 未新增第二派生；
// 3) 身份键语义：同一对话跨重渲染键相等（无 churn），不同对话键不等（重建
//    并重新派生），切回原对话键恢复原值且重新派生的 scope 逐字等于原 scope；
// 4) 切换后按新身份构造的 scope 与原 scope 互异，且原会话 grant 不能授权
//    新会话 scope（失败关闭跨界面依然成立）。
// 断言全部经由派生函数/身份值本身求值，不硬编码派生 key 副本。
// SwiftUI 在 .id 变化时销毁并重建 @State 属框架文档行为，本文件不运行真实
// 视图树；运行时 A/B 隔离旅程由打包阶段 L06 复验（见收据）。

@Suite("P3-BROWSER-01 pane scope re-derivation on conversation switch (lane DEV-193)")
struct BrowserPaneScopeRederive193Tests {

    // MARK: - 源码级正向钉：调用点身份绑定与唯一派生链

    private static func contextPanelSource() throws -> String {
        // 与 BrowserSessionScopeUserSide154Tests 相同的定位方式：
        // Tests/MinisCanvasAppTests/<file> 向上 5 层到仓库根。
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(
                "src/MinisCanvasApp/Sources/MinisCanvasApp/ContextPanelView.swift"
            ),
            encoding: .utf8
        )
    }

    @Test("the BrowserTabView call site binds view identity to conversation and workspace")
    func callSiteBindsIdentityToConversation() throws {
        let source = try Self.contextPanelSource()
        // 精确多行片段：可信身份、owner 与复合 .id
        // 身份绑定必须同时出现在 BrowserTabView 调用点上（.id 直接挂在
        // BrowserTabView(…) 之后，而不是文件里任意位置的 .id）。
        let boundBrowserCall = [
            "BrowserTabView(",
            "                settings: SettingsCenter.active,",
            "                conversationSessionID: chat.activeSessionID,",
            "                workspaceID: chat.composerWorkspaceID,",
            "                lifecycleOwner: browserSessionOwner",
            "            )",
            "                .id(browserPaneIdentity)",
        ].joined(separator: "\n")
        #expect(source.contains(boundBrowserCall))
        // 仓库既有同类模式的旁证：terminal 分支早已用 .id(上下文快照) 强制
        // 随上下文重建 —— 193 沿用的正是这个身份模式而非新发明机制。
        #expect(source.contains(".id(terminalContextSnapshot)"))
    }

    @Test("scope still flows only through the single lane-154 derivation at the BrowserSession construction")
    func constructionStillUsesSingleDerivation() throws {
        let source = try Self.contextPanelSource()
        // 154 的构造点原样保留（身份绑定不改变 scope 派生来源）。
        #expect(source.contains(
            "let expectedScope = Self.userBrowserScope(\n"
                + "                for: conversationSessionID, workspaceID: workspaceID\n"
                + "            )"
        ))
        #expect(source.contains("scope: expectedScope,"))
        // 用户侧生产构造点仍全文件唯一：193 没有新增第二处 BrowserSession(
        // 构造或第二条 scope 派生路径。
        var constructionCount = 0
        var searchRange = source.startIndex..<source.endIndex
        while let found = source.range(of: "BrowserSession(", range: searchRange) {
            constructionCount += 1
            searchRange = found.upperBound..<source.endIndex
        }
        #expect(constructionCount == 1)
    }

    // MARK: - 逻辑级：身份键的 churn 语义（对齐 SwiftUI .id 的相等性判定）

    @Test("the identity key persists across same-conversation re-render and changes only on conversation switch")
    func identityKeyHasExactChurnSemantics() {
        let conversationA = UUID()
        let conversationB = UUID()
        // 同一会话/工作区跨重渲染键相等 ⇒ 不重建，无 churn。
        let firstRender = BrowserPaneOwnerIdentity(sessionID: conversationA, workspaceID: "workspace-a")
        let reRender = BrowserPaneOwnerIdentity(
            sessionID: UUID(uuidString: conversationA.uuidString)!, workspaceID: "workspace-a"
        )
        #expect(firstRender == reRender)
        // 切换对话 ⇒ 键不等 ⇒ 面板重建并重新派生 scope。
        #expect(firstRender != BrowserPaneOwnerIdentity(sessionID: conversationB, workspaceID: "workspace-a"))
        #expect(firstRender != BrowserPaneOwnerIdentity(sessionID: conversationA, workspaceID: "workspace-b"))
        // 切回原对话 ⇒ 键恢复原值（ChatThread.id 为 let UUID，跨切换稳定）。
        #expect(reRender == firstRender)
        // 退化态：无活动会话与有活动会话的键互异，不会互相误重建。
        #expect(BrowserPaneOwnerIdentity(sessionID: nil, workspaceID: "workspace-a") != firstRender)
    }

    @Test("scope re-derived after a switch is distinct from the previous conversation and exact on switch back")
    @MainActor
    func scopeFollowsIdentityAcrossSwitch() {
        let conversationA = UUID()
        let conversationB = UUID()
        let workspaceID = "synthetic-workspace-193"
        let scopeBeforeSwitch = BrowserTabView.userBrowserScope(
            for: conversationA, workspaceID: workspaceID
        )
        // 身份键变化后重建的面板按新 conversationSessionID 走同一派生函数：
        // 两个活跃对话绝不共享一个 live scope。
        let scopeAfterSwitch = BrowserTabView.userBrowserScope(
            for: conversationB, workspaceID: workspaceID
        )
        #expect(scopeBeforeSwitch.id != scopeAfterSwitch.id)
        // 切回对话 A（面板第三次重建）时重新派生的 scope 与最初逐字相等，
        // 不是每次重建再掷随机 —— 这正是 154 稳定性结论在切换路径上的延伸。
        let scopeBackOnA = BrowserTabView.userBrowserScope(
            for: UUID(uuidString: conversationA.uuidString)!, workspaceID: workspaceID
        )
        #expect(scopeBackOnA == scopeBeforeSwitch)
    }

    @Test("a grant bound to the previous conversation's pane scope cannot authorize the switched-in scope")
    @MainActor
    func staleGrantFailsClosedAcrossSwitch() {
        let conversationA = UUID()
        let conversationB = UUID()
        let workspaceID = "synthetic-workspace-193"
        let scopeA = BrowserTabView.userBrowserScope(for: conversationA, workspaceID: workspaceID)
        let scopeB = BrowserTabView.userBrowserScope(for: conversationB, workspaceID: workspaceID)
        let grantA = BrowserWriteAuthorization(grantID: "lane-193-grant-a", scope: scopeA)
        #expect(grantA.isValid)
        #expect(grantA.authorizes(scopeA))
        // 切换后的面板携带 scope B：旧 A 面板遗留的 grant 必须失败关闭。
        #expect(!grantA.authorizes(scopeB))
    }
}
