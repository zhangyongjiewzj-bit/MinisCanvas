import Foundation
import Testing
@testable import MinisCore

@Suite("Session history locator")
struct SessionHistoryLocatorTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCore-HistoryLocator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("stable message ID locates the exact transcript index and snippet")
    func stableMessageIDLocatesExactMessage() throws {
        let locator = SessionHistoryLocator(snippetLimit: 8)
        let session = ChatSession(
            id: "history-session",
            title: "历史",
            messages: [
                LLMMessage(role: .user, content: "第一条"),
                LLMMessage(role: .assistant, content: "第二条：含有关键片段"),
            ]
        )
        let messageID = locator.messageID(for: session.messages[1], transcriptIndex: 1)

        let result = try #require(locator.locate(session: session, messageID: messageID))

        #expect(result.sessionID == session.id)
        #expect(result.transcriptIndex == 1)
        #expect(result.messageID == messageID)
        #expect(result.role.rawValue == LLMMessage.Role.assistant.rawValue)
        #expect(result.snippet == "第二条：含有关键")
    }

    @Test("search returns matching message IDs and exact matched text in transcript order")
    func searchReturnsMessageIDsAndMatchedText() {
        let locator = SessionHistoryLocator()
        let session = ChatSession(
            id: "search-session",
            messages: [
                LLMMessage(role: .user, content: "请查找晴天"),
                LLMMessage(role: .assistant, content: "已记录：晴天"),
                LLMMessage(role: .user, content: "无关"),
            ]
        )

        let results = locator.search(session: session, query: "晴天")

        #expect(results.map(\.transcriptIndex) == [0, 1])
        #expect(results.map(\.matchedText) == ["晴天", "晴天"])
        #expect(Set(results.map(\.messageID)).count == 2)
    }

    @Test("SessionManager production consumer searches archived history and discovers unread state")
    func sessionManagerSearchesArchivedAndDiscoversState() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let badges = SessionBadgeStore(directory: directory)
        let manager = SessionManager(store: store, badgeStore: badges)
        let session = ChatSession(
            id: "archived-history",
            title: "归档线程",
            updatedAt: Date(timeIntervalSince1970: 100),
            messages: [
                LLMMessage(role: .user, content: "归档里的目标片段"),
            ]
        )
        try store.updateSession(session)
        badges.increment(for: session.id)
        try manager.archive(sessionID: session.id)

        let matches = manager.searchHistory(
            query: "目标片段",
            includeArchived: true
        )
        let states = manager.discoverThreadStates(includeArchived: true)

        #expect(matches.count == 1)
        #expect(matches[0].sessionID == session.id)
        #expect(matches[0].transcriptIndex == 0)
        #expect(states.count == 1)
        #expect(states[0].isArchived)
        #expect(states[0].unreadCount == 1)
        #expect(states[0].lastMessageID == matches[0].messageID)
        #expect(states[0].lastMessageSnippet == "归档里的目标片段")
    }

    @Test("empty query and zero limit fail closed")
    func emptyQueryAndZeroLimitFailClosed() throws {
        let locator = SessionHistoryLocator()
        let session = ChatSession(
            id: "empty-query",
            messages: [LLMMessage(role: .user, content: "内容")]
        )

        #expect(locator.search(session: session, query: " ").isEmpty)
        #expect(locator.search(session: session, query: "内容", limit: 0).isEmpty)
        #expect(locator.locate(session: session, messageID: " ").map { _ in false } ?? true)
    }
}
