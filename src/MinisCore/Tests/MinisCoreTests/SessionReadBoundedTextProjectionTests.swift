import Foundation
import Testing
@testable import MinisCore

struct SessionReadBoundedTextProjectionTests {
    @Test func unicodeBudgetKeepsGraphemesAndReportsUTF8Bytes() throws {
        let source = "A👩🏽‍💻e\u{301}中文"
        let firstThree = String(source.prefix(3))
        let projection = try SessionReadBoundedTextProjection(
            text: source,
            maxCharacters: 10,
            maxBytes: firstThree.utf8.count
        )

        #expect(projection.text == firstThree)
        #expect(projection.characterCount == firstThree.count)
        #expect(projection.byteCount == firstThree.utf8.count)
        #expect(projection.characterCount <= projection.maxCharacters)
        #expect(projection.byteCount <= projection.maxBytes)
        #expect(projection.sourceCharacterCount == source.count)
        #expect(projection.sourceByteCount == source.utf8.count)
        #expect(projection.isTruncated)
        #expect(String(data: Data(projection.text.utf8), encoding: .utf8) == projection.text)
    }

    @Test func invalidUTF8IsRejectedBeforeProjection() throws {
        let invalid = Data([0xF0, 0x28, 0x8C, 0x28])
        #expect(throws: SessionReadBoundedTextProjectionError.invalidUTF8) {
            try SessionReadBoundedTextProjection(
                utf8: invalid,
                maxCharacters: 200,
                maxBytes: 800
            )
        }
    }

    @Test func sameRevisionAndOffsetProduceEqualStablePages() throws {
        let messages = ["一", "👩🏽‍💻", "e\u{301}", "四"]
        let cursor = try SessionReadPageCursor(
            sessionID: "session-1",
            scope: .messages,
            revision: "session-revision-7",
            turnID: 7,
            offset: 1,
            limit: 2
        )
        let first = try SessionReadPageProjection.project(
            messages: messages,
            cursor: cursor,
            maxCharacters: 200,
            maxBytes: 800,
            expectedSessionID: "session-1",
            expectedScope: .messages,
            expectedRevision: "session-revision-7",
            expectedTurnID: 7
        )
        let second = try SessionReadPageProjection.project(
            messages: messages,
            cursor: cursor,
            maxCharacters: 200,
            maxBytes: 800,
            expectedSessionID: "session-1",
            expectedScope: .messages,
            expectedRevision: "session-revision-7",
            expectedTurnID: 7
        )

        #expect(first == second)
        #expect(first.sessionID == "session-1" && first.scope == .messages)
        #expect(first.revision == "session-revision-7" && first.turnID == 7)
        #expect(first.offset == 1 && first.limit == 2 && first.total == 4)
        #expect(first.messages.map(\.text) == ["👩🏽‍💻", "e\u{301}"])
        #expect(first.hasMore)
        #expect(first.nextOffset == 3)
        #expect(first.nextCursor == (try? SessionReadPageCursor(
            sessionID: "session-1",
            scope: .messages,
            revision: "session-revision-7",
            turnID: 7,
            offset: 3,
            limit: 2
        )))
    }

    @Test func wrongBindingAndOutOfRangeFailClosed() throws {
        let cursor = try SessionReadPageCursor(
            sessionID: "session-1",
            scope: .messages,
            revision: "session-revision-7",
            turnID: 7,
            offset: 1,
            limit: 2
        )
        #expect(throws: SessionReadBoundedTextProjectionError.cursorSessionMismatch) {
            try SessionReadPageProjection.project(
                messages: ["一", "二"],
                cursor: cursor,
                maxCharacters: 200,
                maxBytes: 800,
                expectedSessionID: "session-2"
            )
        }
        #expect(throws: SessionReadBoundedTextProjectionError.cursorRevisionMismatch) {
            try SessionReadPageProjection.project(
                messages: ["一", "二"],
                cursor: cursor,
                maxCharacters: 200,
                maxBytes: 800,
                expectedRevision: "session-revision-8"
            )
        }
        #expect(throws: SessionReadBoundedTextProjectionError.cursorTurnMismatch) {
            try SessionReadPageProjection.project(
                messages: ["一", "二"],
                cursor: cursor,
                maxCharacters: 200,
                maxBytes: 800,
                expectedTurnID: 8
            )
        }
        #expect(throws: SessionReadBoundedTextProjectionError.cursorOutOfRange) {
            let outOfRange = try SessionReadPageCursor(
                sessionID: "session-1",
                scope: .messages,
                revision: "session-revision-7",
                turnID: 7,
                offset: 3,
                limit: 1
            )
            _ = try SessionReadPageProjection.project(
                messages: ["一", "二"],
                cursor: outOfRange,
                maxCharacters: 200,
                maxBytes: 800,
                expectedSessionID: "session-1",
                expectedScope: .messages,
                expectedRevision: "session-revision-7",
                expectedTurnID: 7
            )
        }
        #expect(throws: SessionReadBoundedTextProjectionError.invalidCursor) {
            try SessionReadPageCursor(
                sessionID: "session-1",
                scope: .messages,
                revision: "session-revision-7",
                turnID: 7,
                offset: 0,
                limit: 51
            )
        }
    }

    @Test func invalidMessageCannotReturnPseudoContinuation() throws {
        let cursor = try SessionReadPageCursor(
            sessionID: "session-1",
            scope: .messages,
            revision: "session-revision-7",
            turnID: 7,
            offset: 0,
            limit: 2
        )
        let invalid = Data([0xC3, 0x28])
        #expect(throws: SessionReadBoundedTextProjectionError.invalidUTF8) {
            try SessionReadPageProjection.project(
                utf8Messages: [Data("ok".utf8), invalid],
                cursor: cursor,
                maxCharacters: 200,
                maxBytes: 800,
                expectedSessionID: "session-1",
                expectedScope: .messages,
                expectedRevision: "session-revision-7",
                expectedTurnID: 7
            )
        }
    }

    @Test func terminalPageHasNoContinuation() throws {
        let page = try SessionReadPageProjection.project(
            messages: ["一", "二", "三"],
            sessionID: "session-1",
            scope: .messages,
            revision: "session-revision-7",
            turnID: 7,
            offset: 2,
            limit: 2,
            maxCharacters: 200,
            maxBytes: 800
        )
        #expect(page.messages.map(\.text) == ["三"])
        #expect(page.hasMore == false)
        #expect(page.nextOffset == nil)
        #expect(page.nextCursor == nil)
    }
}
