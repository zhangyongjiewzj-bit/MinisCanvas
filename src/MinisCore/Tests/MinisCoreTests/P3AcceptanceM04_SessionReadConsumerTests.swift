import Foundation
import Testing
@testable import MinisCore

/// Synthetic consumer checks for the bounded, single-target session_read contract.
struct P3AcceptanceM04_SessionReadConsumerTests {
    private func makeManager() throws -> (SessionManager, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("P3AcceptanceM04-SessionRead-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SessionStore(directory: directory)
        return (SessionManager(store: store, badgeStore: SessionBadgeStore(directory: directory)), directory)
    }

    private func object(_ output: String) throws -> [String: Any] {
        let data = try #require(output.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func successiveBoundedPagesPreserveMessageOrderWithoutRepeatingContent() throws {
        let (manager, directory) = try makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = ChatSession(
            id: "m04-pages",
            title: "分页会话",
            messages: [
                LLMMessage(role: .user, content: "第一段"),
                LLMMessage(role: .assistant, content: "第二段"),
                LLMMessage(role: .user, content: "第三段"),
            ]
        )
        try manager.store.updateSession(session)
        let now = Date(timeIntervalSince1970: 10_000)
        let context = SessionReadExecutionContext(currentConversationID: "m04-reader", turnID: 7)
        var offset = 0
        var collected: [String] = []
        var reachedEnd = false

        for _ in 0..<3 {
            let grant = CrossSessionReadAuthorization.issue(
                currentConversationID: "m04-reader",
                authorizedSessionID: session.id,
                turnID: 7,
                issuedAt: now,
                lifetime: 60,
                scope: .messages
            )
            let page = try object(SessionReadTool.read(
                input: ["session_id": session.id, "scope": "messages", "offset": offset, "limit": 2],
                manager: manager,
                authorization: grant,
                context: context,
                now: now.addingTimeInterval(1)
            ))
            let messages = try #require(page["messages"] as? [[String: Any]])
            #expect(messages.count <= 2)
            #expect(page["total"] as? Int == 3)
            #expect(page["cursor_offset"] as? Int == offset)
            collected += try messages.map { try #require($0["text"] as? String) }
            if page["has_more"] as? Bool == true {
                let next = try #require((page["next_offset"] as? Int).flatMap {
                    $0 > offset ? $0 : nil
                })
                offset = next
            } else {
                #expect(page["next_offset"] is NSNull)
                reachedEnd = true
                break
            }
        }

        #expect(reachedEnd)
        #expect(collected == ["第一段", "第二段", "第三段"])
        #expect(manager.loadSessionIncludingArchived(id: session.id)?.messages.map(\.content)
            == ["第一段", "第二段", "第三段"])
    }

    @Test func wrongTargetCannotConsumeSingleTargetGrantOrExposeOtherSession() throws {
        let (manager, directory) = try makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        let allowed = ChatSession(
            id: "m04-allowed",
            title: "允许读取",
            messages: [LLMMessage(role: .user, content: "允许正文")]
        )
        let other = ChatSession(
            id: "m04-other",
            title: "不允许读取",
            messages: [LLMMessage(role: .user, content: "隔离正文")]
        )
        try manager.store.updateSession(allowed)
        try manager.store.updateSession(other)
        let now = Date(timeIntervalSince1970: 20_000)
        let grant = CrossSessionReadAuthorization.issue(
            currentConversationID: "m04-reader",
            authorizedSessionID: allowed.id,
            turnID: 8,
            issuedAt: now,
            lifetime: 60,
            scope: .messages
        )
        let context = SessionReadExecutionContext(currentConversationID: "m04-reader", turnID: 8)
        let otherInput: [String: Any] = ["session_id": other.id, "scope": "messages"]
        let allowedInput: [String: Any] = ["session_id": allowed.id, "scope": "messages"]

        #expect(throws: CrossSessionReadAuthorizationError.sessionNotAuthorized) {
            _ = try SessionReadTool.read(
                input: otherInput,
                manager: manager,
                authorization: grant,
                context: context,
                now: now.addingTimeInterval(1)
            )
        }
        let allowedOutput = try SessionReadTool.read(
            input: allowedInput,
            manager: manager,
            authorization: grant,
            context: context,
            now: now.addingTimeInterval(1)
        )
        let outputObject = try object(allowedOutput)
        let messages = try #require(outputObject["messages"] as? [[String: Any]])
        let text = try #require(messages.first?["text"] as? String)
        #expect(outputObject["session_id"] as? String == allowed.id)
        #expect(messages.count == 1)
        #expect(text == "允许正文")
        #expect(!allowedOutput.contains("隔离正文"))
        #expect(throws: CrossSessionReadAuthorizationError.replayed) {
            _ = try SessionReadTool.read(
                input: allowedInput,
                manager: manager,
                authorization: grant,
                context: context,
                now: now.addingTimeInterval(1)
            )
        }
        #expect(manager.loadSessionIncludingArchived(id: allowed.id)?.title == allowed.title)
        #expect(manager.loadSessionIncludingArchived(id: other.id)?.title == other.title)
        #expect(manager.loadSessionIncludingArchived(id: other.id)?.messages.first?.content == "隔离正文")
    }
}
