import Foundation
import Testing
@testable import MinisCore

private actor StreamingDeltaProbe2584 {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private final class TurnStreamProvider2584: AssistantStreamingLLMProvider, @unchecked Sendable {
    let name = "owned-turn-stream-2584"
    var model = LLMModel(id: "stream2584", displayName: "Owned stream", provider: "test")
    var capabilities: Set<ProviderCapability> { [.tools] }
    private let lock = NSLock()
    private var buffered = 0
    private var streamed = 0
    var counts: (buffered: Int, streamed: Int) { lock.withLock { (buffered, streamed) } }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        lock.withLock { buffered += 1 }
        return LLMResponse(text: "wrong buffered route", stopReason: "stop", usage: nil)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt,
                              maxTokens: maxTokens, temperature: temperature)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func streamAssistantMessage(messages: [LLMMessage], systemPrompt: String?,
                                tools: [AgentToolDefinition], maxTokens: Int,
                                temperature: Double?) async throws -> AsyncThrowingStream<LLMAssistantStreamEvent, Error> {
        lock.withLock { streamed += 1 }
        // Ordered provider events; the actual consumer awaits the first handler
        // before consuming the second event, so no sleep or scheduler race is needed.
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("before-stop"))
            continuation.yield(.textDelta("after-stop"))
            continuation.yield(.completed(LLMResponse(text: "before-stopafter-stop",
                stopReason: "stop", usage: nil)))
            continuation.finish()
        }
    }
}

private final class StreamingExecutor2584: ToolExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var dispatched = 0
    var count: Int { lock.withLock { dispatched } }
    func execute(name: String, input: [String: Any]) async throws -> String {
        lock.withLock { dispatched += 1 }
        return "unexpected tool dispatch"
    }
}

@Suite("D-CONC3 actual streaming turn cancellation", .serialized)
struct AgentLoopStreamingTurnRevocation2584Tests {
    @Test(arguments: [false, true])
    func stoppedTurnCannotForwardAnotherProviderDelta(revoke: Bool) async throws {
        let controller = TurnController()
        let provider = TurnStreamProvider2584()
        let probe = StreamingDeltaProbe2584()
        let executor = StreamingExecutor2584()
        var loop = AgentLoop(maxIterations: 2, turnController: controller, timeout: 2)
        loop.onAssistantTextDelta = { _, delta in
            await probe.append(delta)
            if delta == "before-stop" {
                // Public exact-turn stop; not cancellation of the outer Task.
                // This is the documented TurnController interrupt path.
                if revoke { await controller.revoke(turnID: 1) }
                else { await controller.interrupt(turnID: 1) }
            }
        }
        do {
            _ = try await loop.run(messages: [.init(role: .user, content: "owned stream")],
                systemPrompt: nil, provider: provider, toolExecutor: executor, tools: [])
            Issue.record("stopped turn unexpectedly completed")
        } catch is InterruptedError {
            // Canonical controller cancellation, not a successful provider result.
        }
        let deltas = await probe.values
        #expect(deltas == ["before-stop"], "exact stopped turn must reject its next live delta")
        #expect(provider.counts.streamed == 1)
        #expect(provider.counts.buffered == 0)
        #expect(executor.count == 0)
        #expect(await controller.isRunning == false)
    }

    @Test func activeTurnStillForwardsBothDeltasAndCompletes() async throws {
        let controller = TurnController()
        let provider = TurnStreamProvider2584()
        let probe = StreamingDeltaProbe2584()
        let executor = StreamingExecutor2584()
        var loop = AgentLoop(maxIterations: 2, turnController: controller, timeout: 2)
        loop.onAssistantTextDelta = { _, delta in await probe.append(delta) }
        let result = try await loop.run(messages: [.init(role: .user, content: "owned stream")],
            systemPrompt: nil, provider: provider, toolExecutor: executor, tools: [])
        let deltas = await probe.values
        #expect(deltas == ["before-stop", "after-stop"])
        #expect(result.messages.last(where: { $0.role == .assistant })?.content == "before-stopafter-stop")
        #expect(provider.counts.streamed == 1)
        #expect(provider.counts.buffered == 0)
        #expect(executor.count == 0)
        #expect(await controller.isRunning == false)
    }
}
