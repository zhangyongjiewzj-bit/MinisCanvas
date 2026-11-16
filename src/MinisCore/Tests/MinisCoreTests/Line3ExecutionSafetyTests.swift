import Foundation
import Testing
@testable import MinisCore

private final class Line3Provider: LLMProvider, @unchecked Sendable {
    let response: LLMResponse
    let delay: TimeInterval
    var responses: [LLMResponse]
    private(set) var callCount = 0

    init(response: LLMResponse = LLMResponse(text: "done", stopReason: nil, usage: nil), delay: TimeInterval = 0) {
        self.response = response
        self.delay = delay
        self.responses = []
    }

    init(responses: [LLMResponse], delay: TimeInterval = 0) {
        self.response = responses.last ?? LLMResponse(text: "done", stopReason: nil, usage: nil)
        self.responses = responses
        self.delay = delay
    }

    var name: String { "line3" }
    var model = LLMModel(id: "line3", displayName: "line3", provider: "test")
    var capabilities: Set<ProviderCapability> { [.tools] }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        try await sendMessage(
            messages: messages,
            systemPrompt: systemPrompt,
            tools: [],
            maxTokens: maxTokens,
            temperature: temperature
        )
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        callCount += 1
        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        return responses.isEmpty ? response : responses.removeFirst()
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

private final class Line3RecordingExecutor: ToolExecutor, @unchecked Sendable {
    private(set) var calls: [String] = []

    func execute(name: String, input: [String: Any]) async throws -> String {
        calls.append(name)
        return "ok"
    }
}

private final class IgnoringCancellationProvider: LLMProvider, @unchecked Sendable {
    var name: String { "ignoring-cancellation" }
    var model = LLMModel(id: "ignoring-cancellation", displayName: "ignoring-cancellation", provider: "test")
    var capabilities: Set<ProviderCapability> { [] }
    private let continuationLock = NSLock()
    private var continuation: CheckedContinuation<LLMResponse, Never>?
    private let startProbe = Line3StartProbe()

    func waitUntilStarted() async -> Bool {
        await startProbe.waitUntilStarted()
    }

    func release() {
        takeContinuation()?.resume(returning: LLMResponse(text: "late", stopReason: nil, usage: nil))
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        return await withCheckedContinuation { continuation in
            // Publish the continuation before signalling readiness. Otherwise the
            // test may release between the probe signal and continuation storage.
            storeContinuation(continuation)
            startProbe.markStarted()
        }
    }

    private func storeContinuation(_ continuation: CheckedContinuation<LLMResponse, Never>) {
        continuationLock.lock()
        self.continuation = continuation
        continuationLock.unlock()
    }

    private func takeContinuation() -> CheckedContinuation<LLMResponse, Never>? {
        continuationLock.lock()
        defer { continuationLock.unlock() }
        let continuation = self.continuation
        self.continuation = nil
        return continuation
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

private final class IgnoringCancellationExecutor: ToolExecutor, @unchecked Sendable {
    private let continuationLock = NSLock()
    private var continuation: CheckedContinuation<String, Never>?
    private let startProbe = Line3StartProbe()

    func waitUntilStarted() async -> Bool {
        await startProbe.waitUntilStarted()
    }

    func release() {
        takeContinuation()?.resume(returning: "late")
    }

    func execute(name: String, input: [String: Any]) async throws -> String {
        return await withCheckedContinuation { continuation in
            // Publish the continuation before signalling readiness.
            storeContinuation(continuation)
            startProbe.markStarted()
        }
    }

    private func storeContinuation(_ continuation: CheckedContinuation<String, Never>) {
        continuationLock.lock()
        self.continuation = continuation
        continuationLock.unlock()
    }

    private func takeContinuation() -> CheckedContinuation<String, Never>? {
        continuationLock.lock()
        defer { continuationLock.unlock() }
        let continuation = self.continuation
        self.continuation = nil
        return continuation
    }
}

private final class Line3StartProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false

    func markStarted() {
        lock.lock()
        started = true
        lock.unlock()
    }

    func waitUntilStarted() async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if isStarted() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return isStarted()
    }

    private func isStarted() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }
}

private actor Line3CompletionProbe {
    private(set) var completed = false
    private(set) var results: [ToolRunResult]?

    func markCompleted(_ results: [ToolRunResult]? = nil) {
        self.results = results
        completed = true
    }

    func waitUntilCompleted() async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if completed { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return completed
    }
}

private struct QueuedRunRecordingExecutor: ToolExecutor, Sendable {
    private actor CallLog {
        private(set) var calls: [String] = []
        func record(_ name: String) { calls.append(name) }
    }
    private let log = CallLog()

    var calls: [String] { get async { await log.calls } }

    func execute(name: String, input: [String: Any]) async throws -> String {
        await log.record(name)
        return "ok"
    }
}

private func line3Envelope(name: String, input: [String: Any] = [:]) -> String {
    let object: [String: Any] = [
        "tool_calls": [["id": "line3-call", "name": name, "input": input]],
    ]
    return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
}

@Suite("线3执行安全")
struct Line3ExecutionSafetyTests {
    @Test func queuedCancellationRacingGrantDoesNotLeakOrOverReleasePermit() async {
        for _ in 0..<12 {
            let runner = ConcurrentToolRunner(maxConcurrent: 1)
            let held = IgnoringCancellationExecutor()
            let activeCompletion = Line3CompletionProbe()
            let active = Task {
                let results = await runner.run([ToolInvocation(name: "active")], executor: held)
                await activeCompletion.markCompleted(results)
            }
            defer { held.release(); active.cancel() }
            #expect(await held.waitUntilStarted())
            let executor = QueuedRunRecordingExecutor()
            let queuedCompletion = Line3CompletionProbe()
            let queued = Task {
                let results = await runner.run([ToolInvocation(name: "queued")], executor: executor)
                await queuedCompletion.markCompleted(results)
            }
            defer { queued.cancel() }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            while clock.now < deadline {
                if await runner.queuedInvocationCount == 1 { break }
                try? await Task.sleep(for: .milliseconds(1))
            }
            #expect(await runner.queuedInvocationCount == 1)
            // cancelWaiter and the detached release can reach the actor in either
            // order. Both must resume at most once and conserve the same permit.
            queued.cancel()
            held.release()
            let activeDone = await activeCompletion.waitUntilCompleted()
            let queuedDone = await queuedCompletion.waitUntilCompleted()
            #expect(activeDone)
            #expect(queuedDone)
            guard activeDone && queuedDone else { return }
            let cancelled = await queuedCompletion.results ?? []
            #expect(cancelled.first?.terminalStatus == .cancelled)
            #expect(await executor.calls.isEmpty)
            let nextCompletion = Line3CompletionProbe()
            let next = Task {
                let results = await runner.run([ToolInvocation(name: "next")], executor: executor)
                await nextCompletion.markCompleted(results)
            }
            defer { next.cancel() }
            let nextDone = await nextCompletion.waitUntilCompleted()
            #expect(nextDone, "A dropped permit must fail within the observation deadline")
            guard nextDone else { return }
            #expect(await nextCompletion.results?.first?.output == "ok")
            #expect(await executor.calls == ["next"])
        }
    }

    @Test func cancellingQueuedRunReturnsBeforeActiveRunAndPreservesNextPermit() async {
        let runner = ConcurrentToolRunner(maxConcurrent: 1)
        let heldExecutor = IgnoringCancellationExecutor()
        let activeCompletion = Line3CompletionProbe()
        let active = Task {
            let results = await runner.run([ToolInvocation(name: "active")], executor: heldExecutor)
            await activeCompletion.markCompleted(results)
        }
        defer { heldExecutor.release(); active.cancel() }
        #expect(await heldExecutor.waitUntilStarted())

        let cancelledExecutor = QueuedRunRecordingExecutor()
        let completion = Line3CompletionProbe()
        let queued = Task {
            let result = await runner.run([ToolInvocation(name: "cancelled")], executor: cancelledExecutor)
            await completion.markCompleted(result)
        }
        defer { queued.cancel() }
        func waitForQueue(_ count: Int) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            while clock.now < deadline {
                if await runner.queuedInvocationCount == count { return true }
                try? await Task.sleep(for: .milliseconds(1))
            }
            return await runner.queuedInvocationCount == count
        }
        #expect(await waitForQueue(1), "B must actually queue behind A before cancellation")
        let nextExecutor = QueuedRunRecordingExecutor()
        let nextCompletion = Line3CompletionProbe()
        let next = Task {
            let results = await runner.run([ToolInvocation(name: "next")], executor: nextExecutor)
            await nextCompletion.markCompleted(results)
        }
        defer { next.cancel() }
        #expect(await waitForQueue(2))
        queued.cancel()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if await completion.completed { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        // Negative control: with the old acquire() B is still suspended here.
        // Releasing A below is teardown, so a red assertion cannot hang the test.
        #expect(await completion.completed, "Cancelled B must settle while A still holds its permit")
        #expect(await runner.queuedInvocationCount == 1, "Only C remains queued")
        #expect(await cancelledExecutor.calls.isEmpty)
        #expect(await nextExecutor.calls.isEmpty, "Cancelling B must not release A's permit")
        heldExecutor.release()
        let activeDone = await activeCompletion.waitUntilCompleted()
        let queuedDone = await completion.waitUntilCompleted()
        let nextDone = await nextCompletion.waitUntilCompleted()
        #expect(activeDone)
        #expect(queuedDone)
        #expect(nextDone)
        guard activeDone && queuedDone && nextDone else { return }
        let activeResults = await activeCompletion.results ?? []
        let cancelledResults = await completion.results ?? []
        let nextResults = await nextCompletion.results ?? []
        #expect(activeResults.first?.output == "late")
        #expect(cancelledResults.first?.terminalStatus == .cancelled)
        #expect(cancelledResults.first?.executionElapsedNanoseconds == nil)
        #expect(nextResults.first?.output == "ok")
        #expect(await nextExecutor.calls == ["next"])
    }

    @Test func nilApprovalRejectsHighRiskCallBeforeExecutor() async throws {
        let executor = Line3RecordingExecutor()
        let loop = AgentLoop(maxIterations: 2, loopDetector: nil)
        let result = try await loop.run(
            messages: [],
            systemPrompt: nil,
            provider: Line3Provider(responses: [
                LLMResponse(text: line3Envelope(name: "shell_execute", input: ["command": "echo no"]), stopReason: nil, usage: nil),
                LLMResponse(text: "done", stopReason: nil, usage: nil),
            ], delay: 0),
            toolExecutor: executor,
            tools: AgentToolCatalog.makeTools()
        )

        #expect(executor.calls.isEmpty)
        #expect(result.messages.contains { $0.content.contains("Approval") || $0.content.contains("审批") })
    }

    @Test func toolCallOutsideOfferedCatalogIsRejected() async throws {
        let executor = Line3RecordingExecutor()
        let provider = Line3Provider(responses: [
            LLMResponse(text: line3Envelope(name: "shell_execute"), stopReason: nil, usage: nil),
            LLMResponse(text: "done", stopReason: nil, usage: nil),
        ])
        let tools = [AgentToolDefinition(name: "file_read", description: "read", parameters: [:], required: [])]
        let result = try await AgentLoop(maxIterations: 2, loopDetector: nil).run(
            messages: [], systemPrompt: nil, provider: provider, toolExecutor: executor, tools: tools
        )

        #expect(executor.calls.isEmpty)
        #expect(result.messages.contains { $0.content.contains(ToolExecutorError.unknownTool("shell_execute").localizedDescription) })
    }

    @Test func emptyCatalogCannotAuthorizeAnUnknownExecutorTool() async throws {
        let executor = Line3RecordingExecutor()
        let provider = Line3Provider(responses: [
            LLMResponse(text: line3Envelope(name: "forged_tool"), stopReason: nil, usage: nil),
            LLMResponse(text: "done", stopReason: nil, usage: nil),
        ])
        let result = try await AgentLoop(maxIterations: 2, loopDetector: nil).run(
            messages: [], systemPrompt: nil, provider: provider, toolExecutor: executor, tools: []
        )

        #expect(executor.calls.isEmpty)
        #expect(result.messages.contains { $0.content.contains(ToolExecutorError.unknownTool("forged_tool").localizedDescription) })
    }

    @Test func providerTimeoutStopsAStalledTurn() async {
        let provider = Line3Provider(delay: 1)
        await #expect(throws: AgentLoopError.timedOut(0.01)) {
            _ = try await AgentLoop(maxIterations: 1, loopDetector: nil, timeout: 0.01).run(
                messages: [], systemPrompt: nil, provider: provider,
                toolExecutor: Line3RecordingExecutor(), tools: []
            )
        }
    }

    @Test func providerDeadlineReturnsWhileProviderIgnoresCancellation() async throws {
        let provider = IgnoringCancellationProvider()
        let probe = Line3CompletionProbe()
        let task = Task { () -> Bool in
            do {
                _ = try await AgentLoop(maxIterations: 1, loopDetector: nil, timeout: 0.01).run(
                    messages: [], systemPrompt: nil, provider: provider,
                    toolExecutor: Line3RecordingExecutor(), tools: []
                )
                await probe.markCompleted()
                return false
            } catch let error as AgentLoopError {
                await probe.markCompleted()
                return error == .timedOut(0.01)
            } catch {
                await probe.markCompleted()
                return false
            }
        }

        #expect(await provider.waitUntilStarted())
        let result = await task.value
        #expect(await probe.completed, "deadline did not return before the provider released")
        #expect(result)
        provider.release()
    }

    @Test func providerLateResponseCannotReplaceTimeoutResult() async throws {
        let provider = IgnoringCancellationProvider()
        let task = Task { () -> AgentLoopError? in
            do {
                _ = try await AgentLoop(maxIterations: 1, loopDetector: nil, timeout: 0.01).run(
                    messages: [], systemPrompt: nil, provider: provider,
                    toolExecutor: Line3RecordingExecutor(), tools: []
                )
                return nil
            } catch let error as AgentLoopError {
                return error
            } catch {
                return nil
            }
        }

        #expect(await provider.waitUntilStarted())
        let timeoutResult = await task.value
        #expect(timeoutResult == .timedOut(0.01))

        // The provider completes only after the caller has already received
        // timeout. The late response must be ignored by the race.
        provider.release()
        #expect(timeoutResult == .timedOut(0.01))
    }

    @Test func cancellationReturnsWhileProviderIgnoresCancellation() async throws {
        let provider = IgnoringCancellationProvider()
        let probe = Line3CompletionProbe()
        let task = Task { () -> Bool in
            do {
                _ = try await AgentLoop(maxIterations: 1, loopDetector: nil, timeout: 30).run(
                    messages: [], systemPrompt: nil, provider: provider,
                    toolExecutor: Line3RecordingExecutor(), tools: []
                )
                await probe.markCompleted()
                return false
            } catch is CancellationError {
                await probe.markCompleted()
                return true
            } catch {
                await probe.markCompleted()
                return false
            }
        }

        #expect(await provider.waitUntilStarted())
        task.cancel()
        let result = await task.value
        #expect(await probe.completed, "cancellation waited for the provider release")
        #expect(result)
        provider.release()
    }

    @Test func registryInterruptsRegisteredTurnOnSharedController() async {
        let controller = TurnController()
        let first = await controller.beginTurn()
        let second = await controller.beginTurn()
        let registry = AgentTurnRegistry()
        await registry.register(controller, for: first.turnID)
        await registry.register(controller, for: second.turnID)

        await registry.interrupt(turnID: first.turnID)

        #expect(await first.isCancelled())
        #expect(!(await second.isCancelled()))
        await first.finish()
        await second.finish()
    }

    @Test func concurrentToolRunnerReturnsTimeoutErrorAndDoesNotHang() async throws {
        struct SlowExecutor: ToolExecutor {
            func execute(name: String, input: [String: Any]) async throws -> String {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                return "late"
            }
        }

        let results = await ConcurrentToolRunner(maxConcurrent: 1).run(
            [ToolInvocation(name: "slow")], executor: SlowExecutor(), timeout: 0.01
        )
        #expect(results.count == 1)
        #expect(results[0].output == nil)
        #expect(results[0].errorMessage?.contains("timed out") == true)
    }

    @Test func toolDeadlineReturnsWhileExecutorIgnoresCancellation() async throws {
        let executor = IgnoringCancellationExecutor()
        let probe = Line3CompletionProbe()
        let task = Task {
            let results = await ConcurrentToolRunner(maxConcurrent: 1).run(
                [ToolInvocation(name: "slow")], executor: executor, timeout: 0.01
            )
            await probe.markCompleted()
            return results
        }

        #expect(await executor.waitUntilStarted())
        let results = await task.value
        #expect(await probe.completed, "deadline did not return before the executor released")
        executor.release()
        #expect(results.count == 1)
        #expect(results[0].output == nil)
        #expect(results[0].errorMessage?.contains("timed out") == true)
    }

    @Test func toolLateResponseCannotReplaceTimeoutResult() async throws {
        let executor = IgnoringCancellationExecutor()
        let task = Task {
            await ConcurrentToolRunner(maxConcurrent: 1).run(
                [ToolInvocation(name: "slow")], executor: executor, timeout: 0.01
            )
        }

        #expect(await executor.waitUntilStarted())
        let timeoutResults = await task.value
        #expect(timeoutResults.count == 1)
        #expect(timeoutResults[0].output == nil)
        #expect(timeoutResults[0].errorMessage?.contains("timed out") == true)

        // A late executor completion is not allowed to overwrite the already
        // returned timeout result.
        executor.release()
        #expect(timeoutResults[0].output == nil)
        #expect(timeoutResults[0].errorMessage?.contains("timed out") == true)
    }

    @Test func timeoutNilKeepsLegacyProviderAndToolBehavior() async throws {
        let provider = Line3Provider(response: LLMResponse(text: "done", stopReason: nil, usage: nil))
        let loopResult = try await AgentLoop(maxIterations: 1, loopDetector: nil, timeout: nil).run(
            messages: [], systemPrompt: nil, provider: provider,
            toolExecutor: Line3RecordingExecutor(), tools: []
        )
        #expect(provider.callCount == 1)
        #expect(loopResult.messages.last?.content == "done")

        let toolResults = await ConcurrentToolRunner(maxConcurrent: 1).run(
            [ToolInvocation(name: "fast")], executor: Line3RecordingExecutor(), timeout: nil
        )
        #expect(toolResults.count == 1)
        #expect(toolResults[0].output == "ok")
        #expect(toolResults[0].errorMessage == nil)
    }
}
