import XCTest
import MinisCore
@testable import MinisCanvasApp

@MainActor
final class O15InlineToolPresentationTests: XCTestCase {
    private func event(_ id: String, session: UUID, turn: String = "turn", callID: String, sequence: Int64) -> MinisCore.ConversationEvent {
        MinisCore.ConversationEvent(id: id, identity: ConversationEventIdentity(
            sessionID: session.uuidString, turnID: turn, taskID: "task", attempt: 1, scopeID: "scope")!,
            sequence: sequence, occurredAt: Date(timeIntervalSince1970: Double(sequence)),
            kind: .tool, status: .succeeded, summary: "工具调用", toolName: "file_read", toolCallID: callID)
    }

    func testLegacyCallsStayGroupedInOrderWithoutInventingTextPosition() {
        let session = UUID()
        let groups = ChatTranscriptToolGroup.groups(events: [
            event("second", session: session, callID: "two", sequence: 2),
            event("first", session: session, callID: "one", sequence: 1)
        ], sessionID: session)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.title, "本轮 2 次工具调用")
        XCTAssertEqual(groups.first?.events.map(\.id), ["first", "second"])
    }

    func testUnmatchedHistoryDoesNotInventMessagePositionOrLeakOtherSession() {
        let session = UUID()
        let groups = ChatTranscriptToolGroup.groups(events: [
            event("history", session: session, callID: "missing", sequence: 1),
            event("other", session: UUID(), callID: "missing", sequence: 2)
        ], sessionID: session)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.events.map(\.id), ["history"])
    }
}
