import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// R8 (package finding, journey J03 step 2): a session with only two prior messages
/// whose Provider-reported occupancy is 85% of the window is judged "compaction due",
/// but the compaction has too little history to fold (history.count <= keepRecent) and
/// returns "unchanged" without throwing. The send proceeds as is, and the C3 contract
/// ("due but not executed, send went on -> exactly one quiet reason row") must hold for
/// this path too, not only for the Compactor's refusal. Real `ChatStore` / `AgentLoop` /
/// `Compactor`; Providers are the external boundary.
@Suite("R8 due-but-unchanged compaction still explains itself", .serialized)
@MainActor
struct CompactionUnchangedNotice_R8_Tests {
    typealias Fixture = OrdinaryAutoCompactionCancellation2669Tests.Fixture
    typealias HeldSummary = OrdinaryAutoCompactionCancellation2669Tests.HeldSummary
    typealias Dialogue = OrdinaryAutoCompactionCancellation2669Tests.Dialogue

    private func waitUntil(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }

    private let shortHistory = [
        LLMMessage(role: .user, content: "J03-IMG"),
        LLMMessage(role: .assistant, content: "J03 reply")
    ]

    private func noticeCount(_ chat: ChatStore) -> Int {
        chat.messages.filter { $0.role == .system
            && $0.content == ChatStore.compactionNotExecutedNoticeText }.count
    }

    /// 108_800 of 128_000 is 85%, above the 0.8 trigger; two messages cannot be compacted.
    @Test func dueButNothingToFoldStillSendsAndShowsTheNotice() async throws {
        let fixture = try Fixture(initialHistory: shortHistory)
        let summary = HeldSummary(lateFailure: false)
        let dialogue = Dialogue()
        let chat = fixture.bridge.chat
        defer {
            chat.stopAllStreamingForSafety()
            summary.releaseAll()
            withExtendedLifetime(fixture.settings) {}
        }
        await fixture.attach()
        #expect(chat.applySwitchSession(id: fixture.sessionID))
        chat.recordWindowOccupancy(sessionID: fixture.sessionID, providerID: Dialogue.providerID,
            modelID: Dialogue.modelID, sentMessageCount: shortHistory.count, inputTokens: 108_800)
        chat.compactionProviderOverride = summary
        chat.streamingProviderOverride = dialogue
        chat.draftText = "R8_DUE_BUT_UNCHANGED"
        chat.submitComposer()
        let sent = await waitUntil { dialogue.requests.count == 1 }
        #expect(sent, "the unchanged compaction must not stop the send")
        let ended = await waitUntil { !chat.hasStreamingTasksForSafety }
        #expect(ended)
        #expect(dialogue.requests.count == 1)
        #expect(dialogue.summaryRequests.isEmpty && summary.calls == 0, "nothing to fold: no summary request")
        #expect(!chat.messages.contains { $0.content.contains("自动压缩未完成") })
        #expect(chat.contextLimitReason == nil && !chat.canContinueAfterContextLimit)
        #expect(noticeCount(chat) == 1)
        #expect(try fixture.settings.sessionStore.loadLatestCompactionCheckpoint(
            sessionID: fixture.sessionID.uuidString) == nil)
    }

    /// Contrast: the same short session below the trigger was never due, so no row.
    @Test func belowTheTriggerThereIsNoNotice() async throws {
        let fixture = try Fixture(initialHistory: shortHistory)
        let summary = HeldSummary(lateFailure: false)
        let dialogue = Dialogue()
        let chat = fixture.bridge.chat
        defer {
            chat.stopAllStreamingForSafety()
            summary.releaseAll()
            withExtendedLifetime(fixture.settings) {}
        }
        await fixture.attach()
        #expect(chat.applySwitchSession(id: fixture.sessionID))
        chat.recordWindowOccupancy(sessionID: fixture.sessionID, providerID: Dialogue.providerID,
            modelID: Dialogue.modelID, sentMessageCount: shortHistory.count, inputTokens: 20_000)
        chat.compactionProviderOverride = summary
        chat.streamingProviderOverride = dialogue
        chat.draftText = "R8_BELOW_TRIGGER"
        chat.submitComposer()
        let sent = await waitUntil { dialogue.requests.count == 1 }
        #expect(sent)
        let ended = await waitUntil { !chat.hasStreamingTasksForSafety }
        #expect(ended)
        #expect(dialogue.summaryRequests.isEmpty && summary.calls == 0)
        #expect(noticeCount(chat) == 0)
    }
}
