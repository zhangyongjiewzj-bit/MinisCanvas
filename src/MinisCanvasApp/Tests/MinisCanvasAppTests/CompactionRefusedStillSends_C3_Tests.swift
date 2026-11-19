import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// C3 (user decision 1101:10): a compaction the Compactor refuses no longer stops
/// the send while the window is below 95%; at or above 95%, when neither request
/// reduction nor compaction can lower it, the send is refused visibly with no
/// Provider request. Real `ChatStore` / `AgentLoop` / `Compactor`; Providers are
/// the external boundary. Since C3-05 (11/17) a failed summary request or a
/// checkpoint that did not validate is handled like a refusal; conflicts and
/// cancellation are not refusals and keep failing the turn (see the migrated
/// 2669 suite).
///
/// Depends on C-L2's `AgentLoop.contextAdmission` and `AgentLoopError.contextWindowFull`.
@Suite("C3 refused compaction still sends below 95%", .serialized)
@MainActor
struct CompactionRefusedStillSends_C3_Tests {
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

    /// An empty summary is the Compactor's own refusal (same shape as a media refusal).
    @Test func refusedCompactionBelowNinetyFivePercentStillSends() async throws {
        let fixture = try Fixture()
        let summary = HeldSummary(lateFailure: false, summaryText: "   ")
        let dialogue = Dialogue()
        let chat = fixture.bridge.chat
        defer {
            chat.stopAllStreamingForSafety()
            summary.releaseAll()
            withExtendedLifetime(fixture.settings) {}
        }
        await fixture.attach()
        #expect(chat.applySwitchSession(id: fixture.sessionID))
        let original = try #require(fixture.settings.sessionStore.loadSession(id: fixture.sessionID.uuidString))
        chat.recordWindowOccupancy(sessionID: fixture.sessionID, providerID: Dialogue.providerID,
            modelID: Dialogue.modelID, sentMessageCount: original.messages.count)  // 86%
        chat.compactionProviderOverride = summary
        chat.streamingProviderOverride = dialogue
        chat.draftText = "C3_REFUSED_BELOW_HARD_BLOCK"
        chat.submitComposer()
        let entered = await waitUntil { summary.calls == 1 && summary.active == 1 }
        #expect(entered)
        guard entered else { return }
        summary.release(1)
        let ended = await waitUntil { !chat.hasStreamingTasksForSafety && summary.active == 0 }
        #expect(ended)
        #expect(dialogue.requests.count == 1, "the refused compaction must not stop the send")
        #expect(!chat.messages.contains { $0.content.contains("自动压缩未完成") })
        // 1101:10 "仍发送，并给一张原因卡": one quiet line, not a failure card.
        #expect(chat.messages.filter { $0.role == .system
            && $0.content == ChatStore.compactionNotExecutedNoticeText }.count == 1)
        #expect(chat.contextLimitReason == nil && !chat.canContinueAfterContextLimit)
        #expect(try fixture.settings.sessionStore.loadLatestCompactionCheckpoint(
            sessionID: fixture.sessionID.uuidString) == nil)
        let canonical = try #require(fixture.settings.sessionStore.loadSession(id: fixture.sessionID.uuidString))
        #expect(Array(canonical.messages.prefix(original.messages.count)) == original.messages)
        // The notice is a UI system row; asPersisted drops system rows, so the canonical
        // transcript still ends with the reply.
        #expect(canonical.messages.last?.content == "CURRENT_REPLY_2669")
    }

    /// C3-12: a message sent while a manual compaction is still summarizing does not interrupt it and
    /// does not change the history under the summary: it waits in the queue and goes out afterwards.
    @Test func messageSentWhileManualCompactionRunsWaitsInTheQueueAndSendsAfterwards() async throws {
        let fixture = try Fixture()
        let dialogue = Dialogue()
        let chat = fixture.bridge.chat
        defer {
            chat.stopAllStreamingForSafety()
            withExtendedLifetime(fixture.settings) {}
        }
        await fixture.attach()
        #expect(chat.applySwitchSession(id: fixture.sessionID))
        let original = try #require(fixture.settings.sessionStore.loadSession(id: fixture.sessionID.uuidString))
        chat.streamingProviderOverride = dialogue
        let requestID = chat.beginCompactionPresentation(sessionID: fixture.sessionID)
        #expect(chat.isActiveSessionManualCompacting)

        let text = "C3_12_SENT_DURING_COMPACTION"
        chat.draftText = text
        chat.submitComposer()
        #expect(chat.activeQueuedComposerMessages.map(\.text) == [text])
        #expect(chat.draftText.isEmpty)
        #expect(dialogue.requests.isEmpty)
        #expect(!chat.isActiveSessionGenerating)
        let untouched = try #require(fixture.settings.sessionStore.loadSession(id: fixture.sessionID.uuidString))
        #expect(untouched.messages == original.messages, "the history under the summary must not change")

        chat.finishCompactionPresentation(requestID: requestID, sessionID: fixture.sessionID, state: .succeeded)
        let sent = await waitUntil { dialogue.requests.count == 1 && !chat.hasStreamingTasksForSafety }
        #expect(sent)
        #expect(chat.activeQueuedComposerMessages.isEmpty)
        let canonical = try #require(fixture.settings.sessionStore.loadSession(id: fixture.sessionID.uuidString))
        #expect(canonical.messages.filter { $0.content == text }.count == 1)
    }

    /// C3-11: one message's images (base64 is a third larger) must stay clear of the 32 MB request
    /// body limit, and be reachable by the history media budget that already counts the newest message.
    @Test func composerImageTotalCapLeavesRoomUnderTheRequestBodyLimit() {
        let cap = ChatStore.maxComposerImageTotalBytes
        #expect(cap == 18 * 1024 * 1024)
        #expect(cap * 4 / 3 < 28 * 1024 * 1024)
        #expect(cap >= HistoryMediaBudget.defaultMaxBytes)
    }

    /// 97% of the window and a history that can neither be compacted nor reduced
    /// (a handful of short messages): the send is refused visibly, no ordinary
    /// Provider request is made, and the transcript is untouched.
    @Test func refusedCompactionAtNinetyFivePercentBlocksVisibly() async throws {
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
        chat.draftText = "C3_REFUSED_AT_HARD_BLOCK"
        chat.submitComposer()
        let ended = await waitUntil { !chat.hasStreamingTasksForSafety }
        #expect(ended)
        // Summary attempts, if the Compactor made any, go through the same double;
        // an ordinary request is one that is not a summary request.
        #expect(dialogue.requests.count == dialogue.summaryRequests.count,
            "at 97% with nothing to reduce, no ordinary Provider request may be made")
        // AgentLoopError.contextWindowFull's text follows Locale.current (zh or en), so
        // accept either rendering of the same fixed message (as the 2669 truncation check does).
        let visible = chat.messages.last?.content ?? ""
        #expect(visible.contains("无法压缩或缩减") || visible.contains("cannot be compacted or reduced"),
            "visible refusal text was: \(visible)")
        #expect(chat.executionSnapshot(forSessionID: fixture.sessionID)?.state == .failed)
        #expect(try fixture.settings.sessionStore.loadLatestCompactionCheckpoint(
            sessionID: fixture.sessionID.uuidString) == nil)
        let canonical = try #require(fixture.settings.sessionStore.loadSession(id: fixture.sessionID.uuidString))
        #expect(Array(canonical.messages.prefix(short.count)) == short)
    }
}
