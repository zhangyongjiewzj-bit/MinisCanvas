import Foundation
import Testing
@testable import MinisCore

/// D-SESSIONREAD-04: expose bounded-page continuation facts to the real
/// session_read consumer without widening its authorization or data scope.
struct SessionReadPaginationContractTests {
    private func makeManager() throws -> (SessionManager, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCore-SessionReadPagination-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SessionStore(directory: directory)
        return (SessionManager(store: store, badgeStore: SessionBadgeStore(directory: directory)), directory)
    }

    private func readPage(
        sessionID: String,
        manager: SessionManager,
        offset: Int,
        limit: Int,
        maxChars: Int? = nil,
        cursorRevision: String? = nil,
        cursorTurnID: Int? = nil
    ) throws -> [String: Any] {
        let now = Date(timeIntervalSince1970: 10_000)
        let authorization = CrossSessionReadAuthorization.issue(
            currentConversationID: "pagination-source",
            authorizedSessionID: sessionID,
            turnID: offset,
            issuedAt: now,
            lifetime: 60,
            scope: .messages
        )
        var input: [String: Any] = [
            "session_id": sessionID,
            "scope": "messages",
            "offset": offset,
            "limit": limit,
        ]
        if let maxChars {
            input["max_chars"] = maxChars
        }
        if let cursorRevision {
            input["revision"] = cursorRevision
        }
        if let cursorTurnID {
            input["turn_id"] = cursorTurnID
        }
        let output = try SessionReadTool.read(
            input: input,
            manager: manager,
            authorization: authorization,
            context: SessionReadExecutionContext(
                currentConversationID: "pagination-source",
                turnID: offset
            ),
            now: now
        )
        let data = try #require(output.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func boundedProjectionIsWiredAfterRedactionAndBindsCursor() throws {
        let (manager, directory) = try makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        let content = String(repeating: "A", count: 200) + "👩🏽‍💻"
        let session = ChatSession(
            id: "unicode-pagination-session",
            title: "Unicode 分页",
            messages: [LLMMessage(role: .assistant, content: content)]
        )
        try manager.store.updateSession(session)

        let page = try readPage(
            sessionID: session.id,
            manager: manager,
            offset: 0,
            limit: 1,
            maxChars: 200,
            cursorRevision: "initial:0",
            cursorTurnID: 0
        )
        let message = try #require((page["messages"] as? [[String: Any]])?.first)
        #expect(page["revision"] as? String == "initial:0")
        #expect(page["turn_id"] as? Int == 0)
        #expect(page["cursor_offset"] as? Int == 0)
        #expect(page["max_bytes"] as? Int == SessionReadBoundedTextProjection.maximumBytes)
        #expect(message["text"] as? String == String(repeating: "A", count: 200))
        #expect(message["character_count"] as? Int == 200)
        #expect(message["byte_count"] as? Int == 200)
        #expect(message["source_character_count"] as? Int == 201)
        #expect(message["source_byte_count"] as? Int == 215)
        #expect(message["max_characters"] as? Int == 200)
        #expect(message["max_bytes"] as? Int == SessionReadBoundedTextProjection.maximumBytes)
        #expect(message["truncated"] as? Bool == true)
        #expect(page["has_more"] as? Bool == false)
        #expect(page["next_offset"] is NSNull)

        #expect(throws: SessionReadBoundedTextProjectionError.cursorRevisionMismatch) {
            _ = try readPage(
                sessionID: session.id,
                manager: manager,
                offset: 0,
                limit: 1,
                cursorRevision: "initial:1"
            )
        }
        #expect(throws: SessionReadBoundedTextProjectionError.cursorTurnMismatch) {
            _ = try readPage(
                sessionID: session.id,
                manager: manager,
                offset: 0,
                limit: 1,
                cursorTurnID: 1
            )
        }
    }

    @Test func boundedPagesExposeOnlyValidContinuation() throws {
        let (manager, directory) = try makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = ChatSession(
            id: "pagination-session",
            title: "分页",
            messages: [
                LLMMessage(role: .user, content: "一"),
                LLMMessage(role: .assistant, content: "二"),
                LLMMessage(role: .user, content: "三"),
            ]
        )
        try manager.store.updateSession(session)

        let first = try readPage(sessionID: session.id, manager: manager, offset: 0, limit: 2)
        #expect(first["total"] as? Int == 3)
        #expect(first["has_more"] as? Bool == true)
        #expect(first["next_offset"] as? Int == 2)
        #expect((first["messages"] as? [[String: Any]])?.count == 2)

        let last = try readPage(sessionID: session.id, manager: manager, offset: 2, limit: 2)
        #expect(last["has_more"] as? Bool == false)
        #expect(last["next_offset"] is NSNull)
        #expect((last["messages"] as? [[String: Any]])?.count == 1)

        let beyondEnd = try readPage(sessionID: session.id, manager: manager, offset: 99, limit: 2)
        #expect(beyondEnd["has_more"] as? Bool == false)
        #expect(beyondEnd["next_offset"] is NSNull)
        #expect((beyondEnd["messages"] as? [[String: Any]])?.isEmpty == true)
    }
}
