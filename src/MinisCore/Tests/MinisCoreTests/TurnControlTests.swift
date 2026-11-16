import Foundation
import Testing
@testable import MinisCore

// E2 对话控制测试：TurnController 中断 / SteerSupport 转向与编辑消息。
// Swift Testing（CLT 无 XCTest），与本包其他测试文件同约定。

// MARK: - Mock Provider

/// Scripted provider for turn-control tests.
///
/// `@unchecked Sendable` so it can be captured by the `Task` that drives the
/// loop while the test interrupts it from the test thread. All mutable state
/// is written only by the loop thread and read only after the run joins, so
/// there is no concurrent access.
private final class TurnControlMockProvider: LLMProvider, @unchecked Sendable {
    var name: String { "TurnControlMock" }
    var model: LLMModel
    var capabilities: Set<ProviderCapability> { [.tools] }
    /// Canned responses, consumed in order; the last one repeats if exhausted.
    var responses: [String]
    /// Every `systemPrompt` seen per call (for steer assertions).
    private(set) var receivedSystemPrompts: [String?] = []
    private let firstCallReleaseStream: AsyncStream<Void>
    private let firstCallReleaseContinuation: AsyncStream<Void>.Continuation
    private let holdFirstCall: Bool
    private let callCounter = TurnCallCounter()
    private var firstCallPassed = false

    func callCount() async -> Int {
        await callCounter.value
    }

    init(
        model: LLMModel = .claudeHaiku45,
        responses: [String],
        holdFirstCall: Bool = false
    ) {
        self.model = model
        self.responses = responses
        self.holdFirstCall = holdFirstCall
        var releaseContinuation: AsyncStream<Void>.Continuation!
        firstCallReleaseStream = AsyncStream { releaseContinuation = $0 }
        firstCallReleaseContinuation = releaseContinuation
    }

    func releaseFirstCall() {
        firstCallReleaseContinuation.yield(())
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        receivedSystemPrompts.append(systemPrompt)
        await callCounter.increment()
        if !firstCallPassed {
            firstCallPassed = true
            if holdFirstCall {
                var iterator = firstCallReleaseStream.makeAsyncIterator()
                _ = await iterator.next()
            }
        }
        let text = responses.isEmpty ? "" : responses.removeFirst()
        return LLMResponse(text: text, stopReason: nil, usage: nil)
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        try await sendMessage(
            messages: messages,
            systemPrompt: systemPrompt,
            maxTokens: maxTokens,
            temperature: temperature
        )
    }

    func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private actor TurnCallCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private func waitForProviderCall(
    _ provider: TurnControlMockProvider,
    timeout: Duration = .seconds(1)
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while await provider.callCount() == 0 {
        if clock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return true
}

/// Helper: build a tool-call envelope response string.
private func toolCallEnvelope(id: String, name: String, input: [String: Any]) -> String {
    let object: [String: Any] = ["tool_calls": [["id": id, "name": name, "input": input]]]
    let data = try! JSONSerialization.data(withJSONObject: object)
    return String(data: data, encoding: .utf8)!
}

/// Helper: throwaway sandbox root + executor (mirrors AgentLoopTests fixture).
private struct TurnControlFixture {
    let executor: BuiltinToolExecutor

    init() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurnControlTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        executor = BuiltinToolExecutor(allowedRoot: root)
    }
}

// MARK: - Tests

struct TurnControlTests {

    @Test func interruptStopsLoopAtIterationBoundary() async throws {
        let fixture = TurnControlFixture()
        // Every round-trip asks for a tool, so the loop would never end on its
        // own — only the interrupt can stop it.
        let envelope = toolCallEnvelope(id: "call_1", name: "web_search", input: ["query": "x"])
        let mock = TurnControlMockProvider(
            responses: [envelope, envelope, envelope],
            holdFirstCall: true
        )
        let controller = TurnController()
        let loop = AgentLoop(maxIterations: 10, turnController: controller)

        let task = Task {
            try await loop.run(
                messages: [],
                systemPrompt: nil,
                provider: mock,
                toolExecutor: fixture.executor,
                tools: AgentToolCatalog.makeTools()
            )
        }

        #expect(await waitForProviderCall(mock), "provider was never called")
        await controller.interrupt()
        mock.releaseFirstCall()

        await #expect(throws: InterruptedError.self) {
            _ = try await task.value
        }
        // The interrupted turn reports itself as finished.
        #expect(await controller.isRunning == false)
    }

    @Test func interruptWinsOverEmptyResponse() async throws {
        let fixture = TurnControlFixture()
        let mock = TurnControlMockProvider(responses: [""], holdFirstCall: true)
        let controller = TurnController()
        let loop = AgentLoop(maxIterations: 10, turnController: controller)

        let task = Task {
            try await loop.run(
                messages: [],
                systemPrompt: nil,
                provider: mock,
                toolExecutor: fixture.executor,
                tools: AgentToolCatalog.makeTools()
            )
        }

        #expect(await waitForProviderCall(mock), "provider was never called")
        await controller.interrupt()
        mock.releaseFirstCall()

        await #expect(throws: InterruptedError.self) {
            _ = try await task.value
        }
        #expect(await controller.isRunning == false)
    }

    @Test func steerInstructionInjectedIntoNextTurnSystemPrompt() async throws {
        let fixture = TurnControlFixture()
        let mock = TurnControlMockProvider(responses: ["完成。"])

        var context = AgentContext(
            toolExecutor: fixture.executor,
            provider: mock,
            systemPrompt: "基础系统提示"
        )
        context.addSteer(SteerInstruction(text: "从现在起用中文回复", applyTo: .currentTurn))

        _ = try await context.run(userMessage: "你好")

        // The steer must reach the provider's system prompt on the next turn.
        #expect(mock.receivedSystemPrompts.count == 1)
        let prompt = mock.receivedSystemPrompts.first ?? nil
        #expect(prompt?.contains("基础系统提示") == true)
        #expect(prompt?.contains("从现在起用中文回复") == true)
    }

    @Test func nextTurnSteerSkipsOneRunThenPersists() async throws {
        let fixture = TurnControlFixture()
        let mock = TurnControlMockProvider(responses: ["第一轮", "第二轮"])
        var context = AgentContext(
            toolExecutor: fixture.executor,
            provider: mock,
            systemPrompt: "基础系统提示"
        )
        context.addSteer(SteerInstruction(text: "第二轮才生效", applyTo: .nextTurn))

        _ = try await context.run(userMessage: "第一问")
        _ = try await context.run(userMessage: "第二问")

        #expect(mock.receivedSystemPrompts.count == 2)
        #expect(mock.receivedSystemPrompts[0]?.contains("第二轮才生效") == false)
        #expect(mock.receivedSystemPrompts[1]?.contains("[转向指令] 第二轮才生效") == true)
    }

    @Test func editLastUserMessageReplacesLastUserTurn() async throws {
        let fixture = TurnControlFixture()
        let mock = TurnControlMockProvider(responses: ["完成。"])

        var context = AgentContext(
            messages: [
                LLMMessage(role: .user, content: "旧问题"),
                LLMMessage(role: .assistant, content: "旧回答"),
            ],
            toolExecutor: fixture.executor,
            provider: mock,
            systemPrompt: nil
        )

        let replaced = context.editLastUserMessage("新问题")
        #expect(replaced)
        // The last user message is replaced in place; later messages untouched.
        #expect(context.messages.first?.role == .user)
        #expect(context.messages.first?.content == "新问题")
        #expect(context.messages.last?.content == "旧回答")

        // No user message in history → no-op, returns false.
        var assistantOnly = AgentContext(
            messages: [LLMMessage(role: .assistant, content: "hi")],
            toolExecutor: fixture.executor,
            provider: mock,
            systemPrompt: nil
        )
        let noUser = assistantOnly.editLastUserMessage("x")
        #expect(!noUser)
        #expect(assistantOnly.messages.count == 1)
    }

    @Test func steerInstructionDefaultsAndInterruptedErrorEquality() {
        #expect(SteerInstruction(text: "hi").applyTo == .currentTurn)
        #expect(SteerInstruction(text: "hi", applyTo: .nextTurn).applyTo == .nextTurn)
        #expect(SteerInstruction(text: "a") == SteerInstruction(text: "a"))
        #expect(InterruptedError() == InterruptedError())
    }

    // MARK: F19 (P2-9) — interrupt/start 竞态：停止信号不得被下一次 start() 吞掉

    @Test func interruptBeforeStartSurvivesNextStartAndCancelsNewTurn() async throws {
        // 竞态场景：stopStreaming 的 interrupt() 恰好在下一回合 run()/start()
        // 之前到达。旧实现 start() 无条件清标志 → 信号丢失；修复后中断必须
        // 作用于新回合并立即生效。
        let controller = TurnController()
        await controller.interrupt() // 无回合在跑 → 挂起给下一个回合

        // start() 不得清除该挂起中断。
        await controller.start()
        #expect(await controller.isCancelled())
        #expect(await controller.turnID == 1)
        await controller.finish()
    }

    @Test func interruptBeforeStartThrowsAtFirstLoopBoundary() async throws {
        // 端到端：先 interrupt，再跑 AgentLoop —— 必须在第一次迭代边界就抛
        // InterruptedError，provider 一次都不该被调用。
        let fixture = TurnControlFixture()
        let controller = TurnController()
        await controller.interrupt()
        let mock = TurnControlMockProvider(responses: ["不该看到我"])
        let loop = AgentLoop(maxIterations: 5, turnController: controller)

        await #expect(throws: InterruptedError.self) {
            _ = try await loop.run(
                messages: [],
                systemPrompt: nil,
                provider: mock,
                toolExecutor: fixture.executor,
                tools: []
            )
        }
        #expect(mock.receivedSystemPrompts.isEmpty, "中断必须在首个 provider 调用前生效")
        #expect(await controller.isRunning == false)
    }

    @Test func interruptTargetingFinishedTurnIsDiscardedByLaterStart() async throws {
        // 回合 1 运行中收到中断 → 目标=回合1；回合 1 结束后（中断已"消费"于
        // 该回合），回合 2 的 start() 应清除这条过期中断，新回合正常运行。
        let controller = TurnController()
        await controller.start()          // turn 1
        #expect(await controller.turnID == 1)
        await controller.interrupt()      // 目标 turn 1
        #expect(await controller.isCancelled())
        await controller.finish()

        await controller.start()          // turn 2：turnID=2 > 挂起的 1 → 清除
        #expect(await controller.turnID == 2)
        #expect(await controller.isCancelled() == false)
        await controller.finish()
    }

    @Test func interruptWhileRunningTargetsCurrentTurnOnly() async {
        // 运行中中断只针对当前回合；finish 后不残留到未来回合。
        let controller = TurnController()
        await controller.start()
        await controller.interrupt()
        #expect(await controller.isCancelled())
        await controller.finish()
        // 未显式 start 时，isCancelled 对"未来回合"仍报告挂起（turnID 未变）——
        // 这是刻意的：停止信号的清除只发生在 start()（回合语义）或 reset()。
        #expect(await controller.isCancelled())
        await controller.start()
        #expect(await controller.isCancelled() == false)
    }

    @Test func resetClearsPendingInterruptExplicitly() async {
        let controller = TurnController()
        await controller.interrupt() // 挂起给下一回合
        #expect(await controller.isCancelled() == false) // turnID=0，尚无回合
        await controller.reset()     // 显式丢弃（如用户发起全新回合）
        await controller.start()
        #expect(await controller.isCancelled() == false)
    }

    @Test func turnIDIncrementsMonotonicallyPerStart() async {
        let controller = TurnController()
        #expect(await controller.turnID == 0)
        for expected in 1...3 {
            await controller.start()
            #expect(await controller.turnID == expected)
            await controller.finish()
        }
    }
}
