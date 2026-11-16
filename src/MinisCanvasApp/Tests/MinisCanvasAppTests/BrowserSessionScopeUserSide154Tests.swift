import Foundation
import Testing
@testable import MinisCanvasApp
@testable import MinisCore

// P3-BROWSER-01（A/B 会话隔离，内外部跟踪名 BROWSER-05 只是别名）：
// 用户侧浏览器面板必须携带由会话身份派生的稳定 BrowserSessionScope，
// 而不是每次构造都新掷一个 ephemeral UUID。本文件在源码/行为两级正向钉住：
// 1) 生产构造点显式传 scope；
// 2) 两个不同会话身份派生不同 BrowserSessionScope.id；
// 3) 同一身份重开派生同一 id（无每次构造新随机）；
// 4) 绑定 scope A 的 grant 不能授权 scope B（authorizes 失败关闭）。
// 断言不复制派生 key 的硬编码副本，全部经由派生函数本身求值。

@Suite("P3-BROWSER-01 user-side BrowserSessionScope (lane DEV-154)")
struct BrowserSessionScopeUserSide154Tests {

    // MARK: - 源码级正向钉：生产构造点

    private static func contextPanelSource() throws -> String {
        // 与 KeylineIconCoverageTests.repositoryRoot() 相同的定位方式：
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

    @Test("the only production BrowserSession construction on the user side passes an explicit scope")
    func productionSitePassesExplicitScope() throws {
        let source = try Self.contextPanelSource()
        // 唯一构造点（head 6bab94c6 实测 git grep "BrowserSession(" 在 app Sources 仅此一处）
        // 现在必须显式命名 scope，而不是落回 BrowserSession.init 的 .ephemeral() 默认值。
        let derivation = try #require(source.range(of:
            "let expectedScope = Self.userBrowserScope(\n"
                + "                for: conversationSessionID, workspaceID: workspaceID\n"
                + "            )"
        ))
        let construction = try #require(source.range(of: "let s = BrowserSession("))
        #expect(derivation.upperBound < construction.lowerBound)
        let constructor = source[construction.lowerBound...].prefix(400)
        #expect(constructor.contains("scope: expectedScope,"))
        #expect(source.components(separatedBy: "BrowserSession(").count == 2)
        // 身份来自面板渲染时读取的 ChatStore：调用点把 activeSessionID 传入面板。
        #expect(source.contains("conversationSessionID: chat.activeSessionID"))
        #expect(source.contains("workspaceID: chat.composerWorkspaceID"))
    }

    @Test("the app layer now names BrowserSessionScope at the user-side construction instead of relying on the default")
    func appLayerNamesScopeExplicitly() throws {
        let source = try Self.contextPanelSource()
        // 改动前此文件对 BrowserSessionScope 为 0 次命中（C0 实测）；改动后至少
        // 在派生函数返回类型与构造点各命中一次。
        var count = 0
        var searchRange = source.startIndex..<source.endIndex
        while let found = source.range(of: "BrowserSessionScope", range: searchRange) {
            count += 1
            searchRange = found.upperBound..<source.endIndex
        }
        #expect(count >= 2)
    }

    // MARK: - 行为级：稳定性与互异性（经由派生函数求值，不硬编码 key）

    @Test("two different conversation identities produce different BrowserSessionScope ids")
    @MainActor
    func distinctConversationsGetDistinctScopes() {
        let scopeA = BrowserTabView.userBrowserScope(for: UUID(), workspaceID: "workspace-a")
        let scopeB = BrowserTabView.userBrowserScope(for: UUID(), workspaceID: "workspace-a")
        #expect(scopeA.isValid)
        #expect(scopeB.isValid)
        #expect(scopeA.id != scopeB.id)
        #expect(scopeA != scopeB)
        #expect(scopeA.isolationKey?.surface == .userBrowser)
        #expect(scopeA.isolationKey?.workspace == "workspace-a")
    }

    @Test("the same identity reopened yields the same scope id (no fresh UUID per construction)")
    @MainActor
    func sameIdentityIsStableAcrossReopen() {
        let conversation = UUID()
        let firstOpen = BrowserTabView.userBrowserScope(for: conversation, workspaceID: "workspace-a")
        let secondOpen = BrowserTabView.userBrowserScope(for: conversation, workspaceID: "workspace-a")
        // 同一 ChatThread.id（let UUID，跨面板折叠/重开不变）两次派生必须逐字相等；
        // 旧行为（每次构造 ephemeral 新随机）在该断言下必然失败。
        #expect(firstOpen.id == secondOpen.id)
        #expect(firstOpen == secondOpen)
        // 且不再是 core 的每次构造随机 ephemeral 边界。
        #expect(!firstOpen.id.hasPrefix("ephemeral:"))
        // 一个 UUID 值经往返解析（等价于重开后从存储恢复的同一会话身份）复现同一 scope。
        let reparsed = UUID(uuidString: conversation.uuidString)
        #expect(reparsed != nil)
        if let reparsed {
            #expect(BrowserTabView.userBrowserScope(for: reparsed, workspaceID: "workspace-a").id == firstOpen.id)
        }
    }

    // MARK: - 行为级：grant 绑定不可跨会话授权

    @Test("a grant bound to scope A does not authorize scope B via authorizes(_:)")
    @MainActor
    func grantCannotCrossConversationBoundary() {
        let conversationA = UUID()
        let conversationB = UUID()
        let scopeA = BrowserTabView.userBrowserScope(for: conversationA, workspaceID: "workspace-a")
        let scopeB = BrowserTabView.userBrowserScope(for: conversationB, workspaceID: "workspace-a")

        let grant = BrowserWriteAuthorization(grantID: "lane-154-grant", scope: scopeA)
        #expect(grant.isValid)
        #expect(grant.boundScope == scopeA)
        #expect(grant.authorizes(scopeA))
        // 同会话重新派生的 scope 仍被授权（证明授权依赖的是稳定派生而非对象实例）。
        #expect(grant.authorizes(BrowserTabView.userBrowserScope(for: conversationA, workspaceID: "workspace-a")))
        // 另一会话的 scope 必须失败关闭。
        #expect(!grant.authorizes(scopeB))
    }

    // MARK: - 行为级：无会话身份时维持 fail-safe，不制造共享兜底 key

    @Test("absent conversation identity keeps the private ephemeral boundary and never a shared key")
    @MainActor
    func nilIdentityNeverSharesAFallbackKey() {
        let first = BrowserTabView.userBrowserScope(for: nil, workspaceID: "workspace-a")
        let second = BrowserTabView.userBrowserScope(for: nil, workspaceID: "workspace-a")
        // 无活动会话（退化态）时不得退化成固定共享兜底 key：两次派生仍互异。
        #expect(first.id != second.id)
        // 真实会话的 grant 也不能授权这种匿名 ephemeral 边界。
        let scopedGrant = BrowserWriteAuthorization(
            grantID: "lane-154-scoped",
            scope: BrowserTabView.userBrowserScope(for: UUID(), workspaceID: "workspace-a")
        )
        #expect(!scopedGrant.authorizes(first))
    }
    @Test("same conversation in another workspace or surface cannot share login scope")
    @MainActor
    func workspaceAndSurfaceAreIndependentBoundaries() {
        let conversation = UUID()
        let userA = BrowserTabView.userBrowserScope(for: conversation, workspaceID: "workspace-a")
        let userB = BrowserTabView.userBrowserScope(for: conversation, workspaceID: "workspace-b")
        let agentA = BrowserSessionScope(
            surface: .agentBrowser, profile: "production",
            session: conversation.uuidString, workspace: "workspace-a"
        )
        #expect(userA.isolationKey?.profile == "production")
        #expect(userA.id != userB.id)
        #expect(userA.id != agentA.id)
        let grant = BrowserWriteAuthorization(grantID: "synthetic-user-grant", scope: userA)
        #expect(!grant.authorizes(userB))
        #expect(!grant.authorizes(agentA))
    }

}
