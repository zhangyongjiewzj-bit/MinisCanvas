import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// C1: the automatic-compaction trigger is the window occupancy of the next
/// request (user decisions 2130 / 1101:9), not the cumulative-usage budget.
/// Real `ChatStore` / `Compactor` / `SessionStore` through the ordinary Composer
/// path; the Providers are the external boundary. Fixtures are borrowed from the
/// ordinary-compaction suite (`OrdinaryAutoCompactionCancellation2669Tests`).
///
/// Depends on C-L2's `ContextWindowPolicy` and `AgentLoop.contextAdmission`.
@Suite("C1 compaction trigger is window occupancy", .serialized)
@MainActor
struct WindowOccupancyCompactionTrigger_C1_Tests {
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

    /// Before C1 the "unlimited" mode had no cap, so the usage fraction was 0 and
    /// compaction never fired. The window is full regardless of what is billed.
    @Test func unlimitedBudgetStillCompactsAtWindowThreshold() async throws {
        let fixture = try Fixture()
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
        var unlimited = fixture.settings.settings.agent
        unlimited.tokenBudgetUnlimited = true
        chat.configureBudget(from: unlimited)
        #expect(chat.budgetCapTokens == nil)
        let original = try #require(fixture.settings.sessionStore.loadSession(id: fixture.sessionID.uuidString))
        chat.recordWindowOccupancy(sessionID: fixture.sessionID, providerID: Dialogue.providerID,
            modelID: Dialogue.modelID, sentMessageCount: original.messages.count)
        chat.compactionProviderOverride = summary
        chat.streamingProviderOverride = dialogue
        chat.draftText = "C1_UNLIMITED_SEND"
        chat.submitComposer()
        let entered = await waitUntil { summary.calls == 1 && summary.active == 1 }
        #expect(entered, "86% window occupancy must start the compaction although the usage budget is unlimited")
        guard entered else { return }
        summary.release(1)
        let ended = await waitUntil { !chat.hasStreamingTasksForSafety && summary.active == 0 }
        #expect(ended)
        let checkpoint = try #require(try fixture.settings.sessionStore.loadLatestCompactionCheckpoint(
            sessionID: fixture.sessionID.uuidString))
        #expect(checkpoint.replacementHistory.count < original.messages.count)
        #expect(dialogue.requests.count == 1)
        let request = try #require(dialogue.requests.first)
        #expect(request.count < original.messages.count + 1, "the request body must be smaller than the uncompacted history")
        #expect(request.contains { $0.content == "C1_UNLIMITED_SEND" })
        let canonical = try #require(fixture.settings.sessionStore.loadSession(id: fixture.sessionID.uuidString))
        #expect(Array(canonical.messages.prefix(original.messages.count)) == original.messages)
    }

    /// The old trigger would compact here (cumulative usage 90% of a 100_000 cap).
    /// The window is almost empty, so nothing is compacted.
    @Test func roomyWindowDoesNotCompactEvenWhenCumulativeUsageIsNearItsCap() async throws {
        let fixture = try Fixture()
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
        var capped = fixture.settings.settings.agent
        capped.maxTokensPerSession = 100_000
        chat.configureBudget(from: capped)
        await chat.budgetTracker.record(requestTokens: 90_000)
        chat.requestBudget = await chat.budgetTracker.budget
        #expect(chat.requestBudget.usageFraction == 0.9 && !chat.requestBudget.isExhausted)
        let original = try #require(fixture.settings.sessionStore.loadSession(id: fixture.sessionID.uuidString))
        chat.recordWindowOccupancy(sessionID: fixture.sessionID, providerID: Dialogue.providerID,
            modelID: Dialogue.modelID, sentMessageCount: original.messages.count, inputTokens: 12_000)
        chat.compactionProviderOverride = summary
        chat.streamingProviderOverride = dialogue
        chat.draftText = "C1_ROOMY_SEND"
        chat.submitComposer()
        let ended = await waitUntil { dialogue.requests.count == 1 && !chat.hasStreamingTasksForSafety }
        #expect(ended)
        #expect(summary.calls == 0)
        #expect(try fixture.settings.sessionStore.loadLatestCompactionCheckpoint(
            sessionID: fixture.sessionID.uuidString) == nil)
        #expect(chat.contextLimitReason == nil)
        let request = try #require(dialogue.requests.first)
        #expect(request.count == original.messages.count + 1, "uncompacted history plus the new message")
    }
}
