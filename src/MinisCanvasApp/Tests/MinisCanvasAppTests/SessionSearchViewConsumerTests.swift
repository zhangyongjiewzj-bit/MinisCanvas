import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("P3-SESSION-02 exact search consumer")
@MainActor
struct SessionSearchViewConsumerTests {
    private func settleSearch(_ model: SessionSearchModel) {
        // Query work is intentionally cancellable and asynchronous in production.
        // Tests need a deterministic snapshot before asserting stable identities.
        model.refresh()
    }

    private func source(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MinisCanvasAppTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // MinisCanvasApp
            .deletingLastPathComponent() // src
            .deletingLastPathComponent() // repository
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    @Test("normal session rows expose stable UUID focus and keyboard activation")
    func normalSessionRowsExposeStableUUIDFocusAndKeyboardActivation() throws {
        let sidebar = try source(
            "src/MinisCanvasApp/Sources/MinisCanvasApp/ChatSidebarView.swift"
        )
        let rowStart = try #require(sidebar.range(of: "private func sessionRow"))
        let rowEnd = try #require(sidebar.range(
            of: "    @ViewBuilder\n    private func conversationIndicatorSlot",
            range: rowStart.upperBound..<sidebar.endIndex
        ))
        let row = String(sidebar[rowStart.lowerBound..<rowEnd.lowerBound])

        for contract in [
            ".focusable(true)",
            ".focused(focusedSessionID, equals: sessionID)",
            ".accessibilityIdentifier(\"chat.session.row.\\(sessionID.uuidString)\")",
            ".accessibilityAddTraits(.isButton)",
            ".accessibilityAction(.default, onActivate)",
            ".onKeyPress(.return)",
            ".onKeyPress(.space)",
            "activateSessionRow(item.session.id)"
        ] {
            #expect(row.contains(contract), "Missing normal session-row contract: \(contract)")
        }

        #expect(sidebar.contains("@FocusState private var focusedSessionID: UUID?"))
        #expect(sidebar.contains("chat.switchSession(id: id)"))
        #expect(sidebar.contains("private var visibleSessionRowIDs: Set<UUID>"))
        #expect(sidebar.contains(".onChange(of: collapsed)"))
        #expect(sidebar.contains("focusedSessionID = nil"))
        #expect(sidebar.contains("guard chat.activeSessionID == id"))
        #expect(!sidebar.contains("private func activateSessionRow(_ id: String)"))
    }

    /// MC4-040：后台重搜期间旧结果标记为“更新中”（界面置灰禁点），完成后恢复且可点。
    @Test("background refresh marks stale results as updating until new results arrive")
    func backgroundRefreshMarksStaleResultsAsUpdating() async throws {
        let chat = ChatStore()
        chat.appendUser("命中精确片段")
        let model = SessionSearchModel(chat: chat)
        model.updateQuery("精确片段")
        settleSearch(model)
        #expect(!model.results.isEmpty)
        #expect(!model.isUpdating)

        model.refreshInBackground()
        #expect(model.isUpdating)
        for _ in 0..<200 where model.isUpdating { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!model.isUpdating)
        let hit = try #require(model.results.first)
        #expect(model.select(hit))
    }

    @Test("search hit carries stable locator and opens the exact message")
    func searchHitCarriesStableLocatorAndOpensExactMessage() async throws {
        let chat = ChatStore()
        chat.appendUser("前置消息")
        let targetSessionID = chat.applyNewSession(title: "目标会话")
        chat.appendUser("命中精确片段")

        let model = SessionSearchModel(chat: chat)
        model.updateQuery("精确片段")
        settleSearch(model)
        let hit = try #require(model.results.first)

        #expect(hit.sessionID == targetSessionID)
        #expect(hit.transcriptIndex == 0)
        #expect(!hit.messageID.isEmpty)
        #expect(hit.snippet.contains("命中精确片段"))
        #expect(model.select(hit))
        #expect(chat.activeSessionID == targetSessionID)
        #expect(chat.searchScrollTarget?.sessionID == targetSessionID)
        #expect(chat.searchScrollTarget?.messageID == hit.uiMessageID)
        #expect(chat.searchScrollTarget?.stableMessageID == hit.messageID)
    }

    @Test("background snapshot search returns the same hits as the in-place search")
    func backgroundSnapshotSearchMatchesInPlaceSearch() async throws {
        let chat = ChatStore()
        chat.appendUser("快照检索命中内容")
        _ = chat.applyNewSession(title: "第二个")
        chat.appendUser("另一条快照检索")

        let snapshot = chat.sessionSearchSnapshot()
        let background = await Task.detached {
            ChatStore.searchMessageResults(in: snapshot, query: "快照检索", limit: 100)
        }.value
        let direct = chat.searchMessageResults(query: "快照检索", limit: 100)
        #expect(background.count == 2)
        #expect(background == direct)
    }

    @Test("sidebar revision moves on summary changes, list reflects rename and search")
    func sidebarRevisionTracksSummaryChanges() async throws {
        let chat = ChatStore()
        chat.appendUser("侧栏摘要第一条")
        let id = try #require(chat.activeSessionID)
        let before = chat.sidebarRevision
        chat.renameSession(id: id, title: "改名后的会话")
        #expect(chat.sidebarRevision != before)
        #expect(chat.sessionList.first(where: { $0.session.id == id })?.session.title == "改名后的会话")

        chat.searchText = "摘要第一条"
        #expect(chat.sessionList.contains(where: { $0.session.id == id }))
        chat.searchText = "完全不存在的词"
        #expect(!chat.sessionList.contains(where: { $0.session.id == id }))
        chat.searchText = ""
    }

    @Test("streaming body growth does not move the sidebar revision unless a search is active")
    func streamingGrowthDoesNotMoveSidebarRevision() async throws {
        let chat = ChatStore()
        chat.appendUser("流式测试")
        chat.appendAssistant(String(repeating: "字", count: 80))
        let countBefore = chat.activeMessageCount
        let before = chat.sidebarRevision
        for _ in 0..<5 {
            chat.messages[chat.messages.count - 1].content += "追加的流式正文"
        }
        #expect(chat.sidebarRevision == before, "流式正文增长不得让侧栏摘要失效")
        #expect(chat.activeMessageCount == countBefore)

        chat.appendAssistant("新的一条")
        #expect(chat.sidebarRevision != before)
        #expect(chat.activeMessageCount == countBefore + 1)

        // 正在检索时，命中集合随正文变化，修订号照常推进。
        chat.searchText = "追加"
        let searching = chat.sidebarRevision
        chat.messages[chat.messages.count - 1].content += "再追加"
        #expect(chat.sidebarRevision != searching)
        chat.searchText = ""
    }

    @Test("changed transcript rejects an old result before navigation")
    func changedTranscriptRejectsOldResult() async throws {
        let chat = ChatStore()
        chat.appendUser("稳定命中消息")
        let model = SessionSearchModel(chat: chat)
        model.updateQuery("稳定命中")
        settleSearch(model)
        let hit = try #require(model.results.first)

        chat.appendAssistant("后来追加的消息")
        #expect(!chat.openSearchResult(hit))
        #expect(chat.searchScrollTarget == nil)
    }

    @Test("rename preserves exact identity and fork cannot redirect a hit")
    func renamePreservesExactIdentityAndForkCannotRedirectAHit() async throws {
        let chat = ChatStore()
        let sourceID = try #require(chat.activeSessionID)
        chat.appendUser("谱系命中内容")
        let model = SessionSearchModel(chat: chat)
        model.updateQuery("谱系命中")
        settleSearch(model)
        let hit = try #require(model.results.first)

        chat.renameSession(id: sourceID, title: "重命名后的会话")
        #expect(chat.openSearchResult(hit))
        #expect(chat.activeSessionID == sourceID)

        let forkID = try #require(chat.duplicateSession(id: sourceID))
        #expect(forkID != sourceID)
        #expect(chat.activeSessionID == forkID)
        #expect(chat.openSearchResult(hit))
        #expect(chat.activeSessionID == sourceID)
        #expect(chat.searchScrollTarget?.messageID == hit.uiMessageID)
    }

    @Test("archived result restores the same session before exact navigation")
    func archivedResultRestoresSameSessionBeforeExactNavigation() async throws {
        let chat = ChatStore()
        let targetID = try #require(chat.activeSessionID)
        chat.appendUser("归档后仍可定位")
        chat.newSession()
        let model = SessionSearchModel(chat: chat)
        model.updateQuery("归档后仍可定位")
        settleSearch(model)
        let hit = try #require(model.results.first)
        #expect(hit.sessionID == targetID)

        chat.archiveSession(id: targetID)
        #expect(chat.archivedSessions.contains { $0.id == targetID })
        #expect(chat.openSearchResult(hit))
        #expect(chat.activeSessionID == targetID)
        #expect(!chat.archivedSessions.contains { $0.id == targetID })
    }

    @Test("deleted result and cancelled older query fail closed")
    func deletedResultAndCancelledOlderQueryFailClosed() async throws {
        let chat = ChatStore()
        let deletedID = try #require(chat.activeSessionID)
        chat.appendUser("待删除命中")
        chat.newSession()
        let model = SessionSearchModel(chat: chat)
        model.updateQuery("待删除命中")
        settleSearch(model)
        let deletedHit = try #require(model.results.first)

        let intent = try chat.previewDeletion(id: deletedID)
            .withFirstConfirmation("我已核对这份精确预览")
            .withSecondConfirmation("永久删除")
        _ = try chat.deleteSession(id: deletedID, intent: intent)
        #expect(!chat.openSearchResult(deletedHit))

        chat.appendUser("新查询结果")
        model.updateQuery("待删除")
        settleSearch(model)
        let oldQueryHit = deletedHit
        model.updateQuery("新查询结果")
        #expect(!model.select(oldQueryHit))
        settleSearch(model)
        #expect(model.results.allSatisfy { $0.snippet.contains("新查询结果") })
    }

    @Test("reopen after a corrupt state rebuilds the same query")
    func reopenAfterCorruptStateRebuildsSameQuery() async throws {
        let chat = ChatStore()
        chat.appendUser("重开后可恢复搜索")
        let model = SessionSearchModel(chat: chat)
        model.updateQuery("重开后可恢复")
        settleSearch(model)
        #expect(model.results.count == 1)

        model.markCorrupt()
        #expect(model.results.isEmpty)
        model.reopen()
        #expect(model.state == .ready)
        #expect(model.results.count == 1)
        #expect(model.results[0].snippet.contains("重开后可恢复搜索"))
    }

    @Test("fresh persistence reopen keeps the same locator and exact target")
    func freshPersistenceReopenKeepsSameLocatorAndExactTarget() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("P3-SESSION-02-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SessionStore(directory: directory)
        let chat = ChatStore()
        #expect(chat.attachPersistence(store))
        let sessionID = try #require(chat.activeSessionID)
        chat.appendUser("写入磁盘后重开命中")
        let before = try #require(chat.searchMessageResults(query: "磁盘后重开").first)

        let reopened = ChatStore()
        #expect(reopened.attachPersistence(store))
        let after = try #require(reopened.searchMessageResults(query: "磁盘后重开").first)
        #expect(after.sessionID == sessionID)
        #expect(after.messageID == before.messageID)
        #expect(after.transcriptIndex == before.transcriptIndex)
        #expect(reopened.openSearchResult(after))
        #expect(reopened.activeSessionID == sessionID)
        #expect(reopened.searchScrollTarget?.messageID == after.uiMessageID)
    }

    @Test("tool envelopes and credential-shaped content never enter results")
    func toolEnvelopesAndCredentialShapedContentNeverEnterResults() async throws {
        let chat = ChatStore()
        chat.appendAssistant("tool_call arguments={\"api_key\":\"sk-search-secret\"}")
        chat.appendUser("普通可见消息")
        let model = SessionSearchModel(chat: chat)
        model.updateQuery("sk-search-secret")
        settleSearch(model)
        #expect(model.results.isEmpty)

        model.updateQuery("普通可见")
        settleSearch(model)
        #expect(model.results.count == 1)
        let visible = try #require(model.results.first)
        #expect(!visible.snippet.contains("sk-search-secret"))
    }
}

extension SessionSearchViewConsumerTests {
    @Test("a keyword after the first 160 characters is found and the snippet shows it")
    func keywordBeyondSnippetLengthIsFound() throws {
        let chat = ChatStore()
        chat.appendUser(String(repeating: "前文填充", count: 100) + "远处的关键词" + String(repeating: "后文", count: 50))
        let model = SessionSearchModel(chat: chat)
        model.updateQuery("远处的关键词")
        model.refresh()
        let hit = try #require(model.results.first)
        #expect(hit.snippet.contains("远处的关键词"))
        #expect(hit.snippet.count <= 170)
    }
}
