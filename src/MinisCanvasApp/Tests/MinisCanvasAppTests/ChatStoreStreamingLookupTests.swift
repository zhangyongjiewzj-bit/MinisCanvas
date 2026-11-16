import Testing
import Foundation
@testable import MinisCanvasApp

@Suite("PERF50 streaming transcript lookup")
@MainActor
struct ChatStoreStreamingLookupTests {
    @Test("streaming writeback keeps the assistant tail after a long history")
    func streamingWritebackKeepsAssistantTailAfterLongHistory() async throws {
        let chat = ChatStore()
        for index in 0..<256 {
            chat.messages.append(
                ChatMessageUI(role: .user, content: "history-\(index)")
            )
        }

        chat.agentEngine = ComposerSnapshotMockChatEngine()
        chat.draftText = "tail writeback"
        chat.sendDraft()

        var waited: TimeInterval = 0
        while chat.isStreaming && waited < 10 {
            try await Task.sleep(for: .milliseconds(100))
            waited += 0.1
        }

        #expect(!chat.isStreaming)
        #expect(chat.messages.last?.role == .assistant)
        #expect(chat.messages.last?.content.contains("收到：tail writeback") == true)
        #expect(chat.messages.dropLast().count == 258)
    }
}
