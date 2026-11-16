import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// C5 (user 11/1): when a model has no explicit window (neither the user's
/// custom window nor a catalog hit) the turn runs on the 128,000 fallback, and
/// the context-occupancy chip says so ("按 128k 估计"). A custom window or a
/// catalog hit is a known window and carries no label.
@Suite("C5 estimated-window label on the occupancy chip", .serialized)
@MainActor
struct EstimatedWindowLabel_C5_Tests {
    typealias Fixture = OrdinaryAutoCompactionCancellation2669Tests.Fixture
    typealias Dialogue = OrdinaryAutoCompactionCancellation2669Tests.Dialogue

    private func waitUntil(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }

    /// Runs one real turn on a model with `modelID` / `window` and returns the
    /// occupancy the chip would show afterwards.
    ///
    /// The occupancy sample is written only by the production turn path: the
    /// `AgentLoopChatEngine` usage consumer (ChatStore `withContextSources`
    /// closure) or the `.usage` event, both fenced by the provider/model the turn
    /// was admitted with. The Fixture's readiness record names only
    /// `Dialogue.modelID`, so the record for `modelID` is added to the same
    /// readiness store the way the Fixture adds its own (no new hook).
    private func occupancyAfterTurn(modelID: String, window: Int?) async throws -> ChatContextOccupancy {
        let fixture = try Fixture(initialHistory: [])
        let dialogue = Dialogue(replyUsage: LLMUsage(inputTokens: 1_200, outputTokens: 100,
            cacheReadInputTokens: 0, cacheHitInputTokens: 1_200))
        dialogue.model = LLMModel(id: modelID, displayName: "C5 owned", provider: Dialogue.providerID,
                                  contextWindow: window)
        let chat = fixture.bridge.chat
        defer {
            chat.stopAllStreamingForSafety()
            dialogue.releaseReplyCompletion()
            withExtendedLifetime(fixture.settings) {}
        }
        await fixture.attach()
        let readiness = try #require(chat.providerReadinessStore)
        try #require(readiness.upsert([ProviderReadinessPersistenceRecord(
            providerID: Dialogue.providerID, modelID: modelID, status: .passed, readinessState: .mock,
            checkedAt: Date(timeIntervalSince1970: 1_000), evidenceID: "readiness-c5-\(modelID)",
            isApplied: true, discoveryReceiptID: "discovery-c5-\(modelID)",
            discoveredAt: Date(timeIntervalSince1970: 1_000),
            applyReceiptID: "provider-readiness-apply:c5-\(modelID)",
            appliedAt: Date(timeIntervalSince1970: 1_001))]))
        #expect(chat.applySwitchSession(id: fixture.sessionID))
        chat.streamingProviderOverride = dialogue
        chat.draftText = "C5_ESTIMATED_WINDOW_SEND"
        chat.submitComposer()
        let live = await waitUntil {
            chat.messages.last?.isStreaming == true && chat.messages.last?.content == "CURRENT_REPLY_2669"
        }
        try #require(live, "the turn must reach its streamed reply")
        dialogue.releaseReplyCompletion()
        let ended = await waitUntil { !chat.hasStreamingTasksForSafety }
        try #require(ended)
        // The usage consumer is awaited inside the Provider request, i.e. before the turn ends.
        return try #require(chat.contextOccupancy, "the reported usage must produce an occupancy sample")
    }

    @Test func unknownModelWithoutExplicitWindowIsLabelledAsA128kEstimate() async throws {
        let sample = try await occupancyAfterTurn(modelID: "synthetic-unknown-model", window: nil)
        #expect(sample.windowTokens == 128_000)
        #expect(sample.display.contains("按 128k 估计"))
    }

    @Test func unknownModelWithCustomWindowIsNotLabelled() async throws {
        let sample = try await occupancyAfterTurn(modelID: "synthetic-unknown-model", window: 32_000)
        #expect(sample.windowTokens == 32_000)
        #expect(!sample.display.contains("按 128k 估计"))
    }

    @Test func catalogHitIsNotLabelled() async throws {
        let sample = try await occupancyAfterTurn(modelID: "gpt-4.1", window: nil)
        #expect(sample.windowTokens == 1_047_576)
        #expect(!sample.display.contains("按 128k 估计"))
    }
}
