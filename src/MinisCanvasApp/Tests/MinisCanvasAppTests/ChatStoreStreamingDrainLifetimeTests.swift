import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

/// P3-P0-02: a large delta must retain every character without a forced
/// character-by-character display tail. Stop/quiet-tail/order regressions live
/// in ChatStoreStreamFrameCoalescingTests and ChatStreamFrameCoalescerTests.
@Suite("P3-P0-02 streaming drain lifetime")
@MainActor
struct ChatStoreStreamingDrainLifetimeTests {

    /// Preserve the existing large-delta completeness/finite-lifetime contract.
    @Test("single large delta streams to completion within bounded frames")
    func singleLargeDeltaCompletesWithinBoundedFrames() async throws {
        let text = String(repeating: "alpha bravo charlie ", count: 42) // 20×42=840
        let chat = ChatStore()
        chat.streamingProviderOverride = ScriptedDeltaProvider(chunks: [text])
        chat.agentEngine = ComposerSnapshotMockChatEngine()
        chat.draftText = "长会话流式首帧"
        let startedAt = ContinuousClock.now
        chat.sendDraft()
        var waited: TimeInterval = 0
        while chat.isStreaming && waited < 10 {
            try await Task.sleep(for: .milliseconds(25))
            waited += 0.025
        }
        let elapsed = ContinuousClock.now - startedAt
        #expect(!chat.isStreaming)
        #expect(elapsed < .seconds(2.5), "drain 仍以字符数/3 帧的固定速率挂住回合")
        #expect(chat.messages.last?.content == text)
        #expect(chat.messages.last?.isStreaming == false)
    }
}

/// 脚本化 Provider：把给定分片作为连续的 `.text` 块一次性推出，用于复现
/// Provider 突发（单大 delta / 粗分片）场景。结构体成员全为 Sendable，
/// 不引入任何 unchecked 豁免。
private struct ScriptedDeltaProvider: LLMProvider, Sendable {
    let chunks: [String]
    var name: String { "Scripted" }
    var model: LLMModel = LLMModel(
        id: "scripted-drain", displayName: "Scripted Drain", provider: "Scripted"
    )
    var capabilities: Set<ProviderCapability> { [.streaming] }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        LLMResponse(
            text: chunks.joined(),
            stopReason: "end_turn",
            usage: LLMUsage(inputTokens: 0, outputTokens: 0)
        )
    }

    func streamMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        let chunks = self.chunks
        return AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.started)
                for chunk in chunks {
                    if Task.isCancelled { break }
                    continuation.yield(.text(chunk))
                }
                continuation.yield(.finished(stopReason: "end_turn"))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
