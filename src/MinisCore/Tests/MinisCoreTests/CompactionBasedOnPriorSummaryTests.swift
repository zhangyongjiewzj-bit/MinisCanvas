import Foundation
import Testing
@testable import MinisCore

private final class PriorSummaryRecordingProvider: LLMProvider, @unchecked Sendable {
    var name: String { "PriorSummaryRecording" }
    var model = LLMModel(id: "prior-summary-window", displayName: "PriorSummary", provider: "test",
                         contextWindow: 200_000)
    private(set) var requests: [[LLMMessage]] = []
    var reply = "SECOND_SUMMARY"
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        requests.append(messages)
        return LLMResponse(text: reply, stopReason: "end_turn", usage: nil)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt, maxTokens: maxTokens,
                              temperature: temperature)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@Suite("Second compaction builds on the previous summary")
struct CompactionBasedOnPriorSummaryTests {
    private func history(_ count: Int) -> [LLMMessage] {
        (0..<count).map { LLMMessage(role: $0 % 2 == 0 ? .user : .assistant, content: "MSG_\($0)_正文") }
    }

    @Test func secondCompactionSendsPreviousSummaryInsteadOfCoveredRawMessages() async throws {
        let provider = PriorSummaryRecordingProvider()
        provider.reply = "FIRST_SUMMARY_GOAL_ALPHA"
        let all = history(12)
        let firstSource = Array(all.prefix(8))
        let first = try await LossySummaryCompaction.compact(
            messages: firstSource, keepRecent: 2, provider: provider)
        let checkpoint = try CompactionCheckpoint.makeProjection(
            sessionID: "s1", sourceTranscriptRevision: 1, sourceMessages: firstSource, result: first)

        let prior = LossySummaryCompaction.priorSummary(checkpoint: checkpoint, messages: all)
        #expect(prior?.coveredCount == first.compactedCount)

        provider.reply = "SECOND_SUMMARY"
        _ = try await LossySummaryCompaction.compact(
            messages: all, keepRecent: 2, provider: provider, priorSummary: prior)
        let request = try #require(provider.requests.last?.first?.content)
        #expect(request.contains("FIRST_SUMMARY_GOAL_ALPHA"))
        #expect(!request.contains("MSG_0_"))
        #expect(request.contains("MSG_\(first.compactedCount)_"))
    }

    @Test func editedHistoryDropsThePreviousSummary() async throws {
        let provider = PriorSummaryRecordingProvider()
        let all = history(12)
        let firstSource = Array(all.prefix(8))
        let first = try await LossySummaryCompaction.compact(
            messages: firstSource, keepRecent: 2, provider: provider)
        let checkpoint = try CompactionCheckpoint.makeProjection(
            sessionID: "s1", sourceTranscriptRevision: 1, sourceMessages: firstSource, result: first)
        var changed = all
        changed[0] = LLMMessage(role: .user, content: "EDITED")
        #expect(LossySummaryCompaction.priorSummary(checkpoint: checkpoint, messages: changed) == nil)
    }

    @Test func imagesCountTowardTheLocalEstimate() {
        let plain = AgentContextTokenBudget.estimatedMessagesCost([LLMMessage(role: .user, content: "看图")])
        let withImage = AgentContextTokenBudget.estimatedMessagesCost([
            LLMMessage(role: .user, content: "看图",
                       images: [.init(mimeType: "image/png", data: Data([1, 2, 3]))])])
        #expect((withImage ?? 0) - (plain ?? 0) == AgentContextTokenBudget.estimatedImageTokens)
    }
}
