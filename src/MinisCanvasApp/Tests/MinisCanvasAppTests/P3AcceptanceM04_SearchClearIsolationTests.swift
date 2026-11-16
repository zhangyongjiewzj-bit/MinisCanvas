import Foundation
import Testing
@testable import MinisCanvasApp

@Suite("P3-SESSION-02 清除搜索隔离")
@MainActor
struct P3AcceptanceM04_SearchClearIsolationTests {
    @Test("清空后恢复完整会话列表，旧命中和排队查询均失效")
    func clearRestoresSessionsAndRejectsStaleResults() async throws {
        let chat = ChatStore()
        chat.appendUser("甲会话独有片段")
        chat.newSession()
        chat.appendUser("乙会话独有片段")
        #expect(chat.sessionList.count == 2)

        let model = SessionSearchModel(chat: chat)
        model.updateQuery("甲会话")
        model.refresh()
        let oldHit = try #require(model.results.first)
        #expect(chat.sessionList.count == 1)

        model.clear()
        #expect(model.query.isEmpty)
        #expect(chat.searchText.isEmpty)
        #expect(model.results.isEmpty)
        #expect(model.selectedResultID == nil)
        #expect(chat.sessionList.count == 2)
        #expect(!model.select(oldHit))

        model.updateQuery("乙会话")
        model.clear()
        await Task.yield()
        #expect(model.results.isEmpty)
        #expect(chat.sessionList.count == 2)
        #expect(!model.select(oldHit))
    }
}
