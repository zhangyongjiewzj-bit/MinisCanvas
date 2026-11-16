import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// R4 修补：95% 拦截后点“新会话继续”，被拦截的那最后一句用户输入要带进新会话
/// （放回输入框，等用户确认发送，不自动发送）。真实 ChatStore / AgentLoop；Provider 是外部边界。
@Suite("Window full continue carries the blocked input", .serialized)
@MainActor
struct WindowFullContinueCarriesInputR4Tests {
    typealias Fixture = OrdinaryAutoCompactionCancellation2669Tests.Fixture
    typealias Dialogue = OrdinaryAutoCompactionCancellation2669Tests.Dialogue

    private func waitUntil(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }

    @Test func blockedLastInputIsRestoredInTheContinuedSession() async throws {
        let short = (0..<8).map { index in
            LLMMessage(role: index.isMultiple(of: 2) ? .user : .assistant, content: "short-\(index)")
        }
        let fixture = try Fixture(initialHistory: short)
        let dialogue = Dialogue()
        let chat = fixture.bridge.chat
        defer {
            chat.stopAllStreamingForSafety()
            withExtendedLifetime(fixture.settings) {}
        }
        await fixture.attach()
        #expect(chat.applySwitchSession(id: fixture.sessionID))
        chat.recordWindowOccupancy(sessionID: fixture.sessionID, providerID: Dialogue.providerID,
            modelID: Dialogue.modelID, sentMessageCount: short.count, inputTokens: 124_000)  // 97%
        chat.compactionProviderOverride = dialogue
        chat.streamingProviderOverride = dialogue
        chat.draftText = "R4_BLOCKED_LAST_INPUT"
        chat.submitComposer()
        #expect(await waitUntil { !chat.hasStreamingTasksForSafety })
        #expect(chat.canContinueAfterContextLimit)

        chat.continueAfterContextLimit()
        let draft = try #require(chat.sessionContinuationDraft)
        _ = await waitUntil { !draft.isGenerating }
        chat.confirmSessionContinuation()
        #expect(chat.activeSessionID != fixture.sessionID)
        // 被拦的那句回到新会话输入框，不自动发送。
        #expect(chat.draftText == "R4_BLOCKED_LAST_INPUT")
        #expect(!chat.messages.contains { $0.role == .user && $0.content == "R4_BLOCKED_LAST_INPUT" })
    }
}
