import Foundation
import Testing
@testable import MinisCore

// D-CHAT-03（补生产流式接线）—— AgentLoop 侧 assistant 增量流接缝回归。
//
// 冻结需求：issues/三期初期合拢-App逐项功能验收清单-20260826.md:160 `CHAT-03`
// 「助手回复能流式显示，生成中状态清晰」；docs/research/
// MinisCanvas三期_Phistory与ZCode综合评估优化可执行报告-20260921.md:100
// D-CHAT-03 验收：首段在完整回复前到达、连续多段、终态一次。
//
// 本文件只覆盖本 lane 拥有的一半：`AssistantStreamingLLMProvider` 接缝 +
// `AgentLoop.onAssistantTextDelta` 生产端。真实 wire provider（Anthropic/
// OpenAI SSE）迁移不在本 lane 写集内，见回执的 donor 段落。

// MARK: - Test doubles

private final class DeltaRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [(iteration: Int, delta: String)] = []

    func append(iteration: Int, delta: String) {
        lock.lock()
        defer { lock.unlock() }
        events.append((iteration, delta))
    }

    var snapshot: [(iteration: Int, delta: String)] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

/// 增量流式 provider：每次调用按脚本发出 textDelta，随后发出携带权威终态
/// 文本的 `.completed`（接缝契约要求的最后一个事件）。
private final class ScriptedStreamingProvider: AssistantStreamingLLMProvider, @unchecked Sendable {
    var name: String { "ScriptedStreaming" }
    var model = LLMModel(id: "d-chat-03-stream", displayName: "D-CHAT-03", provider: "Test")
    var capabilities: Set<ProviderCapability> { [.tools] }

    private let lock = NSLock()
    private let deltasPerCall: [[String]]
    private let terminalTexts: [String]
    private var callCount = 0
    private var bufferedSendMessageCalls = 0

    init(deltasPerCall: [[String]], terminalTexts: [String]? = nil) {
        self.deltasPerCall = deltasPerCall
        self.terminalTexts = terminalTexts ?? deltasPerCall.map { $0.joined() }
    }

    var bufferedCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return bufferedSendMessageCalls
    }

    private func nextScript() -> (deltas: [String], terminal: String) {
        lock.lock()
        defer { lock.unlock() }
        let index = min(callCount, deltasPerCall.count - 1)
        callCount += 1
        return (deltasPerCall[index], terminalTexts[index])
    }

    private func recordBufferedCall() {
        lock.lock()
        bufferedSendMessageCalls += 1
        lock.unlock()
    }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        recordBufferedCall()
        return LLMResponse(text: nextScript().terminal, stopReason: "end_turn", usage: nil)
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
        let script = nextScript()
        return AsyncThrowingStream { continuation in
            for delta in script.deltas {
                continuation.yield(.textDelta(delta))
            }
            continuation.yield(
                .completed(LLMResponse(text: script.terminal, stopReason: "end_turn", usage: nil))
            )
            continuation.finish()
        }
    }
}

/// 未实现增量流接缝的普通缓冲 provider（今天的生产默认）。
private final class BufferedOnlyProvider: LLMProvider, @unchecked Sendable {
    var name: String { "BufferedOnly" }
    var model = LLMModel(id: "d-chat-03-buffered", displayName: "D-CHAT-03 Buffered", provider: "Test")
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

/// 接缝在发出任何事件之前就失败：错误语义必须与缓冲路径一致。
private struct StreamingAcquisitionError: Error, Equatable {}

private final class FailingStreamingProvider: AssistantStreamingLLMProvider, @unchecked Sendable {
    var name: String { "FailingStreaming" }
    var model = LLMModel(id: "d-chat-03-fail", displayName: "D-CHAT-03 Fail", provider: "Test")
    var capabilities: Set<ProviderCapability> { [.tools] }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        LLMResponse(text: "unreachable", stopReason: nil, usage: nil)
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
        throw StreamingAcquisitionError()
    }
}

private func makeExecutor() -> BuiltinToolExecutor {
    BuiltinToolExecutor(
        allowedRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent("d-chat-03-\(UUID().uuidString)", isDirectory: true)
    )
}

// MARK: - Regression

@Suite("D-CHAT-03 AgentLoop assistant 增量流接缝")
struct AgentLoopAssistantStreamingTests {

    /// 接缝契约 1+2：连续多段实时回调、按迭代打标，终态以 `.completed` 为权威。
    @Test func streamedDeltasReachHandlerLiveAndCarryIterationTag() async throws {
        let provider = ScriptedStreamingProvider(deltasPerCall: [["你", "好", "，世界"]])
        var loop = AgentLoop(maxIterations: 2)
        let recorder = DeltaRecorder()
        loop.onAssistantTextDelta = { iteration, delta in
            recorder.append(iteration: iteration, delta: delta)
        }

        let result = try await loop.run(
            messages: [.init(role: .user, content: "hi")],
            systemPrompt: nil,
            provider: provider,
            toolExecutor: makeExecutor(),
            tools: []
        )

        #expect(
            recorder.snapshot.map(\.delta) == ["你", "好", "，世界"],
            "provider 流出的每个增量都必须按序、实时送达回调"
        )
        #expect(
            Set(recorder.snapshot.map(\.iteration)) == [1],
            "首段属于第 1 次 provider 往返，迭代号必须如实携带"
        )
        #expect(result.iterationCount == 1)
        #expect(result.messages.last(where: { $0.role == .assistant })?.content == "你好，世界")
        #expect(provider.bufferedCalls == 0, "真实流式 provider 不得回落到缓冲 sendMessage")
    }

    /// 接缝契约 1：终态文本以 `.completed` 为准，即使流出内容只是它的前缀。
    @Test func completedResponseIsAuthoritativeOverStreamedPrefix() async throws {
        let provider = ScriptedStreamingProvider(
            deltasPerCall: [["前半"]],
            terminalTexts: ["前半段完整回复"]
        )
        var loop = AgentLoop(maxIterations: 2)
        let recorder = DeltaRecorder()
        loop.onAssistantTextDelta = { iteration, delta in
            recorder.append(iteration: iteration, delta: delta)
        }

        let result = try await loop.run(
            messages: [.init(role: .user, content: "hi")],
            systemPrompt: nil,
            provider: provider,
            toolExecutor: makeExecutor(),
            tools: []
        )

        #expect(recorder.snapshot.map(\.delta) == ["前半"])
        #expect(
            result.messages.last(where: { $0.role == .assistant })?.content == "前半段完整回复",
            "终态必须是 completed 的权威文本，不是已流出前缀"
        )
    }

    /// 未迁移 provider：一次回调都不发生，缓冲路径逐字节保持。
    @Test func nonStreamingProviderNeverTouchesTheDeltaHandler() async throws {
        let provider = BufferedOnlyProvider(text: "缓冲答案。")
        var loop = AgentLoop(maxIterations: 2)
        let recorder = DeltaRecorder()
        loop.onAssistantTextDelta = { iteration, delta in
            recorder.append(iteration: iteration, delta: delta)
        }

        let result = try await loop.run(
            messages: [.init(role: .user, content: "hi")],
            systemPrompt: nil,
            provider: provider,
            toolExecutor: makeExecutor(),
            tools: []
        )

        #expect(recorder.snapshot.isEmpty, "未实现接缝的 provider 不得凭空造出增量")
        #expect(result.messages.last(where: { $0.role == .assistant })?.content == "缓冲答案。")
    }

    /// 接缝契约 3：获取失败（未发出任何事件）沿用缓冲错误语义，原样抛出。
    @Test func streamingAcquisitionFailureKeepsBufferedErrorSemantics() async throws {
        var loop = AgentLoop(maxIterations: 2)
        loop.onAssistantTextDelta = { _, _ in }
        await #expect(throws: StreamingAcquisitionError.self) {
            _ = try await loop.run(
                messages: [.init(role: .user, content: "hi")],
                systemPrompt: nil,
                provider: FailingStreamingProvider(),
                toolExecutor: makeExecutor(),
                tools: []
            )
        }
    }
}
