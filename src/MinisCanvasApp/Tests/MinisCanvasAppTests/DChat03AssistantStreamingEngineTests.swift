import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

// D-CHAT-03（补生产流式接线）—— 生产回合的 App 层回归：
// provider 增量 → 重试/用量/工具计数包装层 → AgentLoop 接缝 → 引擎事件流。
//
// 冻结需求：issues/三期初期合拢-App逐项功能验收清单-20260826.md:160
// `CHAT-03`「助手回复能流式显示，生成中状态清晰」；
// docs/research/MinisCanvas三期_Phistory与ZCode综合评估优化可执行报告-20260921.md:100
// D-CHAT-03 验收：首段在完整回复前到达、连续多段、终态一次。

// MARK: - Test doubles

/// 按脚本流出增量的 provider：每段之间真实让出时间，最后发出权威 `.completed`。
private final class ChunkedStreamingProvider: AssistantStreamingLLMProvider, @unchecked Sendable {
    var name: String { "ChunkedStreaming" }
    var model = LLMModel(id: "d-chat-03-engine", displayName: "D-CHAT-03 Engine", provider: "Test")
    var capabilities: Set<ProviderCapability> { [.tools] }

    private let lock = NSLock()
    private let deltas: [String]
    private let terminalText: String
    private let gap: Duration
    private var _completedEmitted = false

    init(deltas: [String], terminalText: String? = nil, gap: Duration = .milliseconds(40)) {
        self.deltas = deltas
        self.terminalText = terminalText ?? deltas.joined()
        self.gap = gap
    }

    /// 消费者收到首个增量时该标志必须仍为 false —— 证明首段早于终态。
    var completedEmitted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _completedEmitted
    }

    private func markCompletedEmitted() {
        lock.lock()
        _completedEmitted = true
        lock.unlock()
    }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        LLMResponse(text: terminalText, stopReason: "end_turn", usage: nil)
    }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
        maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        try await sendMessage(
            messages: messages,
            systemPrompt: systemPrompt,
            maxTokens: maxTokens,
            temperature: temperature
        )
    }

    func streamMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func streamAssistantMessage(
        messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
        maxTokens: Int, temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMAssistantStreamEvent, Error> {
        let script = deltas
        let terminal = terminalText
        let gap = self.gap
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for delta in script {
                        try await Task.sleep(for: gap)
                        continuation.yield(.textDelta(delta))
                    }
                    try await Task.sleep(for: gap)
                    markCompletedEmitted()
                    continuation.yield(
                        .completed(LLMResponse(text: terminal, stopReason: "end_turn", usage: nil))
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { termination in
                guard case .cancelled = termination else { return }
                task.cancel()
            }
        }
    }
}

/// 今天的默认生产 provider：只有缓冲终态，没有任何增量流实现。
private final class PlainBufferedProvider: LLMProvider, @unchecked Sendable {
    var name: String { "PlainBuffered" }
    var model = LLMModel(id: "d-chat-03-plain", displayName: "D-CHAT-03 Plain", provider: "Test")
    var capabilities: Set<ProviderCapability> { [.tools] }
    private let text: String

    init(text: String) { self.text = text }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        LLMResponse(text: text, stopReason: "end_turn", usage: nil)
    }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
        maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        try await sendMessage(
            messages: messages,
            systemPrompt: systemPrompt,
            maxTokens: maxTokens,
            temperature: temperature
        )
    }

    func streamMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct EngineTurnReceipt {
    var deltas: [String] = []
    var doneCount = 0
    var otherEventCount = 0
}

private func consume(
    _ stream: AsyncThrowingStream<AgentStreamEvent, Error>
) async throws -> EngineTurnReceipt {
    var receipt = EngineTurnReceipt()
    for try await event in stream {
        if case .textDelta(let delta) = event {
            receipt.deltas.append(delta)
        } else if case .done = event {
            receipt.doneCount += 1
        } else {
            receipt.otherEventCount += 1
        }
    }
    return receipt
}

// MARK: - Regression

@Suite("D-CHAT-03 生产回合增量流式（引擎事件流）")
struct DChat03AssistantStreamingEngineTests {

    /// 首段早于终态、连续多段、终态只出现一次、终态不重复已流出文本。
    @Test func streamingProviderDeltasReachEngineStreamBeforeTerminalWithoutDuplication() async throws {
        let provider = ChunkedStreamingProvider(deltas: ["第一段。", "第二段。", "第三段。"])
        let engine = AgentLoopChatEngine()
        let stream = try await engine.streamReply(
            provider: provider,
            history: [ChatMessageUI(role: .user, content: "分三段回答")],
            systemPrompt: "test",
            maxTokens: 128,
            conversationID: "d-chat-03-stream",
            authorizedSessionReadSessionID: nil,
            turnID: 1 // Each fresh engine begins with TurnController handle 1.
        )

        var deltas: [String] = []
        var doneCount = 0
        for try await event in stream {
            if case .textDelta(let delta) = event {
                if deltas.isEmpty {
                    #expect(
                        !provider.completedEmitted,
                        "首段必须在 provider 终态之前到达，否则不是真实流式"
                    )
                }
                deltas.append(delta)
            } else if case .done = event {
                doneCount += 1
            }
        }

        #expect(deltas.count >= 3, "连续多段：实际收到 \(deltas)")
        #expect(deltas.joined() == "第一段。第二段。第三段。", "终态不得重发已流出文本")
        #expect(doneCount == 1, "终态一次")
        #expect(provider.completedEmitted, "回合确实走到了 provider 终态")
    }

    /// 流出内容只是权威文本的前缀时，终态只补差量、不重发全文。
    @Test func terminalOnlySupplementsTheRemainderOfTheAuthoritativeText() async throws {
        let provider = ChunkedStreamingProvider(deltas: ["前半"], terminalText: "前半段完整回复")
        let engine = AgentLoopChatEngine()
        let stream = try await engine.streamReply(
            provider: provider,
            history: [ChatMessageUI(role: .user, content: "补差量")],
            systemPrompt: "test",
            maxTokens: 128,
            conversationID: "d-chat-03-prefix",
            authorizedSessionReadSessionID: nil,
            turnID: 1
        )

        let receipt = try await consume(stream)
        #expect(receipt.deltas == ["前半", "段完整回复"], "只补差量：\(receipt.deltas)")
        #expect(receipt.deltas.joined() == "前半段完整回复")
        #expect(receipt.doneCount == 1)
    }

    /// 未迁移 provider 的零行为变化：仍是终态一条完整文本（今天的生产语义）。
    @Test func bufferedProviderKeepsSingleFinalDelta() async throws {
        let provider = PlainBufferedProvider(text: "缓冲的完整回复。")
        let engine = AgentLoopChatEngine()
        let stream = try await engine.streamReply(
            provider: provider,
            history: [ChatMessageUI(role: .user, content: "普通问题")],
            systemPrompt: "test",
            maxTokens: 128,
            conversationID: "d-chat-03-buffered",
            authorizedSessionReadSessionID: nil,
            turnID: 1
        )

        let receipt = try await consume(stream)
        #expect(receipt.deltas == ["缓冲的完整回复。"])
        #expect(receipt.doneCount == 1)
    }
}
