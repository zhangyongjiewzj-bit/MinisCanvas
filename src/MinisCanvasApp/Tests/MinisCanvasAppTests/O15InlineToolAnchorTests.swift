import XCTest
import MinisCore
@testable import MinisCanvasApp

@MainActor
final class O15InlineToolAnchorTests: XCTestCase {
    private func key(_ call: String, attempt: Int = 1) -> ToolExecutionCompositeKey {
        ToolExecutionCompositeKey(sessionID: "session", turnID: 1, messageID: "message",
            operationID: "operation", attemptID: "attempt-\(attempt)", attemptNumber: attempt, toolCallID: call)
    }

    func testTextAroundCallsKeepsExactUnicodeBoundariesAndRetryIdentity() {
        var message = ChatMessageUI(role: .assistant, content: "先检查👨‍👩‍👧‍👦。")
        let firstBoundary = message.content.utf16.count
        message.captureInlineToolAnchor(for: key("read"))
        message.content += "再核对结果。"
        message.captureInlineToolAnchor(for: key("read", attempt: 2))
        message.captureInlineToolAnchor(for: key("read"))
        XCTAssertEqual(message.inlineToolAnchors.map(\.utf16Offset), [firstBoundary, message.content.utf16.count])
        XCTAssertEqual(message.inlineToolAnchors.map(\.compositeKey.attemptNumber), [1, 2])
        XCTAssertEqual(message.asLLMMessage().content, message.content)
        let insideFamily = ChatInlineToolAnchor(compositeKey: key("invalid"), utf16Offset: 4)
        XCTAssertEqual(ChatInlineToolAnchor.validated(message.inlineToolAnchors + [insideFamily],
            in: message.content), message.inlineToolAnchors)
    }

    func testExistingSidecarRestoresOnlyTheUnchangedMessage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("o15-anchor-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var message = ChatMessageUI(role: .assistant, content: "前文")
        message.captureInlineToolAnchor(for: key("read"))
        message.content += "后文"
        let thread = ChatThread(id: UUID(), messages: [message])
        try ChatAttachmentPersistence.save(sessions: [thread], to: root)
        let loaded = try ChatAttachmentPersistence.load(from: root)
        let records = try XCTUnwrap(loaded[thread.id.uuidString])
        let restored = ChatAttachmentPersistence.restoreAttachments(from: thread.asPersisted(), records: records)
        XCTAssertEqual(restored.messages.first?.inlineToolAnchors, message.inlineToolAnchors)
        let edited = MinisCore.ChatSession(id: thread.id.uuidString,
            messages: [LLMMessage(role: .assistant, content: "不同正文")])
        XCTAssertTrue(ChatAttachmentPersistence.restoreAttachments(from: edited, records: records)
            .messages[0].inlineToolAnchors.isEmpty)
    }

    func testLegacyMessagesAndReplacedTextDoNotInventOldBoundaries() throws {
        var message = ChatMessageUI(role: .assistant, content: "e\u{301}")
        message.captureInlineToolAnchor(for: key("read"))
        message.replaceContent("é")
        XCTAssertTrue(message.inlineToolAnchors.isEmpty)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
        object.removeValue(forKey: "inlineToolAnchors")
        let legacy = try JSONDecoder().decode(ChatMessageUI.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(legacy.inlineToolAnchors.isEmpty)
    }
}
