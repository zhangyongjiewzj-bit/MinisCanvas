import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// R6 (package finding): a custom OpenAI-compatible Provider that reports only
/// `usage.prompt_tokens`, on a model without an explicit window, kept the chip at
/// "—" and the next send never compacted at 82%. The Provider is the external
/// boundary; its usage comes from the real Chat Completions parser. The turn,
/// occupancy sample and compaction admission are the real ChatStore path.
@Suite("R6 prompt-only usage drives occupancy and compaction", .serialized)
@MainActor
struct PromptOnlyUsageOccupancy_R6_Tests {
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

    private func promptOnlyUsage(_ promptTokens: Int) -> LLMUsage {
        OpenAICompatibleProvider.parseChatCompletionsUsage(
            ["prompt_tokens": promptTokens, "completion_tokens": 50])
    }

    private func registerModel(_ chat: ChatStore, modelID: String) throws {
        let readiness = try #require(chat.providerReadinessStore)
        try #require(readiness.upsert([ProviderReadinessPersistenceRecord(
            providerID: Dialogue.providerID, modelID: modelID, status: .passed, readinessState: .mock,
            checkedAt: Date(timeIntervalSince1970: 1_000), evidenceID: "readiness-r6-\(modelID)",
            isApplied: true, discoveryReceiptID: "discovery-r6-\(modelID)",
            discoveredAt: Date(timeIntervalSince1970: 1_000),
            applyReceiptID: "provider-readiness-apply:r6-\(modelID)",
            appliedAt: Date(timeIntervalSince1970: 1_001))]))
    }

    private func finishTurn(_ chat: ChatStore, _ dialogue: Dialogue, text: String) async throws {
        chat.draftText = text
        chat.submitComposer()
        try #require(await waitUntil {
            chat.messages.last?.isStreaming == true && chat.messages.last?.content.hasPrefix("CURRENT_REPLY_2669 ") == true
        }, "the turn must reach its streamed reply")
        dialogue.releaseReplyCompletion()
        try #require(await waitUntil { !chat.hasStreamingTasksForSafety })
    }

    @Test func modelWithoutExplicitWindowShowsOccupancyAgainst128kAfterPromptOnlyUsage() async throws {
        let modelID = "synthetic-r6-unknown-model"
        let fixture = try Fixture(initialHistory: [])
        let dialogue = Dialogue(replyText: "CURRENT_REPLY_2669 streamed.", replyUsage: promptOnlyUsage(32_000))
        dialogue.model = LLMModel(id: modelID, displayName: "R6 owned", provider: Dialogue.providerID,
                                  contextWindow: nil)
        let chat = fixture.bridge.chat
        defer {
            chat.stopAllStreamingForSafety()
            dialogue.releaseReplyCompletion()
            withExtendedLifetime(fixture.settings) {}
        }
        await fixture.attach()
        try registerModel(chat, modelID: modelID)
        #expect(chat.applySwitchSession(id: fixture.sessionID))
        chat.streamingProviderOverride = dialogue
        try await finishTurn(chat, dialogue, text: "R6_FIRST_SEND")
        let sample = try #require(chat.contextOccupancy, "prompt_tokens alone must produce an occupancy sample")
        #expect(sample.inputTokens == 32_000)
        #expect(sample.windowTokens == 128_000)
        #expect(sample.display.contains("按 128k 估计"))
    }

    @Test func catalogModelWithoutExplicitWindowUsesCatalogWindowAfterPromptOnlyUsage() async throws {
        let fixture = try Fixture(initialHistory: [])
        let dialogue = Dialogue(replyText: "CURRENT_REPLY_2669 streamed.", replyUsage: promptOnlyUsage(32_000))
        dialogue.model = LLMModel(id: "gpt-4.1", displayName: "R6 catalog", provider: Dialogue.providerID,
                                  contextWindow: nil)
        let chat = fixture.bridge.chat
        defer {
            chat.stopAllStreamingForSafety()
            dialogue.releaseReplyCompletion()
            withExtendedLifetime(fixture.settings) {}
        }
        await fixture.attach()
        try registerModel(chat, modelID: "gpt-4.1")
        #expect(chat.applySwitchSession(id: fixture.sessionID))
        chat.streamingProviderOverride = dialogue
        try await finishTurn(chat, dialogue, text: "R6_CATALOG_SEND")
        let sample = try #require(chat.contextOccupancy)
        #expect(sample.inputTokens == 32_000)
        #expect(sample.windowTokens == 1_047_576)
        #expect(!sample.display.contains("按 128k 估计"))
    }

    @Test func reportedEightyTwoPercentCompactsTheNextSendOnAWindowlessModel() async throws {
        let modelID = "synthetic-r6-unknown-model"
        let fixture = try Fixture()
        let summary = HeldSummary(lateFailure: false)
        let dialogue = Dialogue(replyText: "CURRENT_REPLY_2669 streamed.", replyUsage: promptOnlyUsage(104_960))
        dialogue.model = LLMModel(id: modelID, displayName: "R6 owned", provider: Dialogue.providerID,
                                  contextWindow: nil)
        let chat = fixture.bridge.chat
        defer {
            chat.stopAllStreamingForSafety()
            dialogue.releaseReplyCompletion()
            summary.releaseAll()
            withExtendedLifetime(fixture.settings) {}
        }
        await fixture.attach()
        try registerModel(chat, modelID: modelID)
        #expect(chat.applySwitchSession(id: fixture.sessionID))
        chat.streamingProviderOverride = dialogue
        try await finishTurn(chat, dialogue, text: "R6_REPORT_82")
        let sample = try #require(chat.contextOccupancy, "the 82% report must be recorded")
        #expect(sample.inputTokens == 104_960)
        chat.compactionProviderOverride = summary
        chat.draftText = "R6_SECOND_SEND"
        chat.submitComposer()
        let entered = await waitUntil { summary.calls == 1 && summary.active == 1 }
        #expect(entered, "82% reported occupancy is above the 0.8 trigger and must start compaction before the send")
        summary.release(1)
        _ = await waitUntil { !chat.hasStreamingTasksForSafety && summary.active == 0 }
    }
}
