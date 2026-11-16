import Foundation
import Testing
@testable import MinisCore

// MARK: - Shared Test Doubles

/// Test error with a stable description (used for fallback assertions).
private struct TimeoutError: Error, LocalizedError {
    var errorDescription: String? { "request timed out" }
}

/// Scripted LLM provider: returns canned responses FIFO, or throws `failure`
/// when set. Records every received message history.
private final class ScriptedLLMProvider: LLMProvider, @unchecked Sendable {
    let id: String
    var model: LLMModel
    var responses: [String]
    var failure: Error?
    private(set) var receivedMessages: [[LLMMessage]] = []
    private(set) var callCount = 0

    init(id: String, model: LLMModel = .claudeHaiku45, responses: [String] = [], failure: Error? = nil) {
        self.id = id
        self.model = model
        self.responses = responses
        self.failure = failure
    }

    var name: String { id }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        callCount += 1
        receivedMessages.append(messages)
        if let failure { throw failure }
        let text = responses.isEmpty ? "" : responses.removeFirst()
        return LLMResponse(text: text, stopReason: nil, usage: nil)
    }

    func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

/// Tool executor with per-name delay and failure scripting.
private final class ScriptedToolExecutor: ToolExecutor, @unchecked Sendable {
    let delays: [String: Double]
    let failures: Set<String>
    let probe: ConcurrencyProbe?

    init(delays: [String: Double] = [:], failures: Set<String> = [], probe: ConcurrencyProbe? = nil) {
        self.delays = delays
        self.failures = failures
        self.probe = probe
    }

    func execute(name: String, input: [String: Any]) async throws -> String {
        if let probe {
            await probe.enter()
            let result: String
            do {
                result = try await perform(name: name)
            } catch {
                await probe.exit()
                throw error
            }
            await probe.exit()
            return result
        }
        return try await perform(name: name)
    }

    private func perform(name: String) async throws -> String {
        if failures.contains(name) {
            throw ToolExecutorError.unknownTool(name)
        }
        if let delay = delays[name], delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        return "out-\(name)"
    }
}

/// Actor tracking the maximum number of simultaneous executions.
private actor ConcurrencyProbe {
    private var current = 0
    private(set) var maxInFlight = 0

    func enter() async {
        current += 1
        if current > maxInFlight { maxInFlight = current }
    }

    func exit() {
        current -= 1
    }
}

private func invocation(_ name: String, id: String = "") -> ToolInvocation {
    ToolInvocation(id: id.isEmpty ? "call-\(name)" : id, name: name, input: ["name": name])
}

// MARK: - ConcurrentToolRunner

struct ConcurrentToolRunnerTests {

    @Test func resultsReturnedInInputOrderDespiteDifferentCompletionTimes() async {
        // Completion order will be b, d, c, a — but results must be a, b, c, d.
        let executor = ScriptedToolExecutor(delays: ["a": 0.15, "c": 0.05])
        let runner = ConcurrentToolRunner(maxConcurrent: 4)

        let results = await runner.run(
            [invocation("a"), invocation("b"), invocation("c"), invocation("d")],
            executor: executor
        )

        #expect(results.map(\.invocation.name) == ["a", "b", "c", "d"])
        #expect(results.map(\.output) == ["out-a", "out-b", "out-c", "out-d"])
        let allSucceeded = results.allSatisfy { $0.isSuccess }
        #expect(allSucceeded)
    }

    @Test func failingToolDoesNotBlockSiblings() async {
        let executor = ScriptedToolExecutor(failures: ["boom"])
        let runner = ConcurrentToolRunner(maxConcurrent: 4)

        let results = await runner.run(
            [invocation("ok1"), invocation("boom"), invocation("ok2")],
            executor: executor
        )

        #expect(results.count == 3)
        #expect(results[0].isSuccess)
        #expect(results[0].output == "out-ok1")
        #expect(!results[1].isSuccess)
        #expect(results[1].errorMessage != nil)
        #expect(results[1].errorMessage?.contains("boom") == true)
        #expect(results[2].isSuccess)
        #expect(results[2].output == "out-ok2")
    }

    @Test func concurrencyCapIsEnforced() async {
        let probe = ConcurrencyProbe()
        let executor = ScriptedToolExecutor(delays: [
            "t1": 0.05, "t2": 0.05, "t3": 0.05, "t4": 0.05, "t5": 0.05, "t6": 0.05,
        ], probe: probe)
        let runner = ConcurrentToolRunner(maxConcurrent: 2)

        let results = await runner.run(
            (1...6).map { invocation("t\($0)") },
            executor: executor
        )

        let maxInFlight = await probe.maxInFlight
        #expect(maxInFlight == 2)
        #expect(results.count == 6)
        #expect(results.map(\.invocation.name) == (1...6).map { "t\($0)" })
    }

    @Test func emptyInputReturnsEmptyResults() async {
        let runner = ConcurrentToolRunner(maxConcurrent: 2)
        let results = await runner.run([], executor: ScriptedToolExecutor())
        #expect(results.isEmpty)
    }
}

// MARK: - RequestBudget

struct RequestBudgetTests {

    @Test func countsRequestsAndTriggersPolicyOnRequestCap() {
        // `.warn` is an explicit product choice; production defaults to `.pause`.
        var budget = RequestBudget(maxRequestsPerSession: 2, overBudgetPolicy: .warn)

        #expect(budget.record(requestTokens: 10) == nil)
        #expect(budget.usedRequests == 1)
        #expect(!budget.isExhausted)

        // Second call crosses the cap → this test explicitly selected .warn.
        #expect(budget.record(requestTokens: 10) == .warn)
        #expect(budget.isExhausted)
        #expect(budget.requestsRemaining == 0)

        // Every subsequent call keeps reporting the policy.
        #expect(budget.record(requestTokens: 10) == .warn)
    }

    @Test func countsTokensAndTriggersPolicyOnTokenCap() {
        var budget = RequestBudget(
            maxTokensPerSession: 100,
            overBudgetPolicy: .autoCompact
        )

        #expect(budget.record(requestTokens: 60) == nil)
        #expect(budget.usedTokens == 60)
        #expect(budget.usageFraction == 0.6)

        #expect(budget.record(requestTokens: 60) == .autoCompact)
        #expect(budget.usedTokens == 120)
        #expect(budget.tokensRemaining == 0)
        #expect(budget.usageFraction == 1.0)
    }

    @Test func pausePolicyAndReset() {
        var budget = RequestBudget(
            maxRequestsPerSession: 1,
            maxTokensPerSession: nil,
            overBudgetPolicy: .pause
        )

        #expect(budget.record(requestTokens: 0) == .pause)
        #expect(budget.isExhausted)

        budget.reset()
        #expect(budget.usedRequests == 0)
        #expect(budget.usedTokens == 0)
        #expect(!budget.isExhausted)
    }

    @Test func noCapsNeverExhausted() {
        var budget = RequestBudget()
        #expect(budget.record(requestTokens: 999_999) == nil)
        #expect(!budget.isExhausted)
        #expect(budget.requestsRemaining == nil)
        #expect(budget.tokensRemaining == nil)
        #expect(budget.usageFraction == 0)
    }
}

// MARK: - Compactor

struct CompactorTests {

    private func makeMessages(_ count: Int) -> [LLMMessage] {
        (1...count).map { i in
            LLMMessage(
                role: i.isMultiple(of: 2) ? .assistant : .user,
                content: "message-\(i)-\(String(repeating: "x", count: 30))"
            )
        }
    }

    @Test func truncationStrategyKeepsRecentTailAndSummarizesOld() async throws {
        let compactor = Compactor(keepRecentMessages: 2, truncationPrefixChars: 10)
        let messages = makeMessages(5)

        let result = try await compactor.compact(messages: messages)

        // 1 summary message + 2 verbatim tail messages.
        #expect(result.messages.count == 3)
        #expect(result.compactedCount == 3)
        #expect(result.summary != nil)

        // Tail preserved verbatim.
        #expect(result.messages[1] == messages[3])
        #expect(result.messages[2] == messages[4])

        // Summary is the truncation of the old prefix, wrapped in the envelope.
        let summary = result.messages[0]
        #expect(summary.role == .user)
        #expect(summary.content.contains("<context-summary>"))
        #expect(summary.content.contains("[user]"))
        #expect(summary.content.contains("…"))
        // The full long content of an old message must NOT survive verbatim.
        #expect(!summary.content.contains("message-1-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"))
        #expect(!result.messages[1].content.contains("<context-summary>"))
    }

    @Test func llmSummarizationUsesProviderAndFallsBackOnFailure() async throws {
        let compactor = Compactor(keepRecentMessages: 1)
        let messages = makeMessages(4)

        // Provider path: summary comes from the LLM reply.
        let okProvider = ScriptedLLMProvider(id: "summarizer", responses: ["这是旧对话的摘要"])
        let okResult = try await compactor.compact(messages: messages, summarizeUsing: okProvider)

        #expect(okProvider.callCount == 1)
        #expect(okResult.messages.count == 2)  // summary + 1 tail
        #expect(okResult.messages[0].content.contains("这是旧对话的摘要"))
        // The summarizer must have received the old transcript.
        #expect(okProvider.receivedMessages.first?.first?.content.contains("message-1-") == true)

        // Failure path: summarization must never break the conversation → truncation fallback.
        let failingProvider = ScriptedLLMProvider(id: "broken", failure: TimeoutError())
        let failResult = try await compactor.compact(messages: messages, summarizeUsing: failingProvider)
        #expect(failResult.summary != nil)
        #expect(failResult.summary?.contains("message-1-") == true)
        #expect(failResult.messages.count == 2)
        #expect(failResult.messages[0].content.contains("<context-summary>"))
    }

    @Test func shortHistoryIsNotCompacted() async throws {
        let compactor = Compactor(keepRecentMessages: 5)
        let messages = makeMessages(3)

        let result = try await compactor.compact(messages: messages)

        #expect(result.messages == messages)
        #expect(result.summary == nil)
        #expect(result.compactedCount == 0)
        #expect(!compactor.needsCompaction(messages: messages))
    }

    @Test func emptyMessagesAreNoOp() async throws {
        let compactor = Compactor()
        let result = try await compactor.compact(messages: [])
        #expect(result.messages.isEmpty)
        #expect(result.summary == nil)
        #expect(result.compactedCount == 0)
        #expect(!compactor.needsCompaction(messages: []))
    }

    @Test func compactionThresholdBoundary() async throws {
        // 恰好 keepRecentMessages 条 → 不压缩；多 1 条 → 压缩
        let compactor = Compactor(keepRecentMessages: 3)
        let atThreshold = makeMessages(3)
        #expect(!compactor.needsCompaction(messages: atThreshold))
        let result = try await compactor.compact(messages: atThreshold)
        #expect(result.compactedCount == 0)
        #expect(result.messages == atThreshold)

        let overThreshold = makeMessages(4)
        #expect(compactor.needsCompaction(messages: overThreshold))
        let compacted = try await compactor.compact(messages: overThreshold)
        #expect(compacted.compactedCount == 1)
    }

    @Test func truncationBoundaryAtExactCap() async throws {
        // 恰好等于 cap 的消息不加省略号；超 1 字符才截断加 …
        let compactor = Compactor(keepRecentMessages: 0, truncationPrefixChars: 10)
        let exact = LLMMessage(role: .user, content: String(repeating: "a", count: 10))
        let over = LLMMessage(role: .user, content: String(repeating: "b", count: 11))
        let result = try await compactor.compact(messages: [exact, over])
        #expect(result.compactedCount == 2)
        #expect(result.summary?.contains("aaaaaaaaaa") == true)
        #expect(!(result.summary?.contains("aaaaaaaaaa…") ?? true))
        // 11 字符超 cap → 截到前 10 字符 + "…"（10 个 b + 省略号）
        #expect(result.summary?.contains("bbbbbbbbbb…") == true)
        // 截断后的省略号版本不应包含未截断的原文
        #expect(!(result.summary?.contains("bbbbbbbbbbb…") ?? true))
    }

    @Test func keepRecentZeroFoldsEverything() async throws {
        let compactor = Compactor(keepRecentMessages: 0)
        let messages = makeMessages(4)
        let result = try await compactor.compact(messages: messages)
        #expect(result.compactedCount == 4)
        #expect(result.messages.count == 1)
        #expect(result.summary != nil)
    }
}

// MARK: - FallbackRouter

struct FallbackRouterTests {

    @Test func fallsBackToBackupWhenPrimaryFails() async throws {
        let primary = ScriptedLLMProvider(id: "primary", failure: TimeoutError())
        let backup = ScriptedLLMProvider(id: "backup", responses: ["来自备份模型"])
        let providers: [String: ScriptedLLMProvider] = ["primary": primary, "backup": backup]

        var router = FallbackRouter(providerIDs: ["primary", "backup"])
        let result = try await router.sendMessage(
            messages: [LLMMessage(role: .user, content: "hi")],
            systemPrompt: nil,
            maxTokens: 128,
            temperature: nil
        ) { id in
            providers[id]!
        }

        #expect(result.providerID == "backup")
        #expect(result.response.text == "来自备份模型")
        #expect(primary.callCount == 1)
        #expect(backup.callCount == 1)
        #expect(router.events.count == 1)
        #expect(router.events.first?.providerID == "primary")
        #expect(router.events.first?.errorDescription == "Provider error")
        #expect(router.events.first?.attempt == 1)
    }

    @Test func primarySuccessRecordsNoFallback() async throws {
        let primary = ScriptedLLMProvider(id: "primary", responses: ["ok"])
        let backup = ScriptedLLMProvider(id: "backup", responses: ["must-not-run"])
        var router = FallbackRouter(providerIDs: ["primary", "backup"])

        let result = try await router.sendMessage(
            messages: [],
            systemPrompt: nil,
            maxTokens: 128,
            temperature: nil
        ) { id in
            id == "primary" ? primary : backup
        }

        #expect(result.providerID == "primary")
        #expect(result.response.text == "ok")
        #expect(primary.callCount == 1)
        #expect(backup.callCount == 0)
        #expect(router.events.isEmpty)
    }

    @Test func allProvidersFailedThrowsWithFullTrail() async {
        let primary = ScriptedLLMProvider(id: "primary", failure: TimeoutError())
        let backup = ScriptedLLMProvider(id: "backup", failure: TimeoutError())
        let providers: [String: ScriptedLLMProvider] = ["primary": primary, "backup": backup]

        var router = FallbackRouter(providerIDs: ["primary", "backup"])

        do {
            _ = try await router.sendMessage(
                messages: [],
                systemPrompt: nil,
                maxTokens: 128,
                temperature: nil
            ) { id in providers[id]! }
            Issue.record("expected allProvidersFailed")
        } catch {
            #expect(error is FallbackRouterError)
            if case .allProvidersFailed(let events) = (error as? FallbackRouterError) {
                #expect(events.count == 2)
            }
        }
        #expect(router.events.count == 2)
        #expect(router.events.map(\.providerID) == ["primary", "backup"])
    }

    @Test func factoryErrorAlsoTriggersFallback() async throws {
        let backup = ScriptedLLMProvider(id: "backup", responses: ["saved"])
        var router = FallbackRouter(providerIDs: ["ghost", "backup"])

        let result = try await router.sendMessage(
            messages: [],
            systemPrompt: nil,
            maxTokens: 128,
            temperature: nil
        ) { id in
            if id == "ghost" { throw ToolExecutorError.unknownTool("factory") }
            return backup
        }

        #expect(result.providerID == "backup")
        #expect(router.events.count == 1)
        #expect(router.events.first?.providerID == "ghost")
    }

    @Test func shouldFallbackFilterPropagatesOriginalError() async {
        let primary = ScriptedLLMProvider(id: "primary", failure: TimeoutError())
        var router = FallbackRouter(providerIDs: ["primary", "backup"])
        router.shouldFallback = { _ in false }  // only non-fallbackable errors expected

        do {
            _ = try await router.sendMessage(
                messages: [],
                systemPrompt: nil,
                maxTokens: 128,
                temperature: nil
            ) { id in primary }
            Issue.record("expected original error to propagate")
        } catch {
            #expect(error is TimeoutError)
        }
        // No fallback attempted, no trail recorded.
        #expect(router.events.isEmpty)
    }

    @Test func emptyChainThrows() async {
        var router = FallbackRouter(providerIDs: [])
        do {
            _ = try await router.sendMessage(
                messages: [],
                systemPrompt: nil,
                maxTokens: 128,
                temperature: nil
            ) { _ in ScriptedLLMProvider(id: "unused") }
            Issue.record("expected emptyChain")
        } catch {
            #expect(error is FallbackRouterError)
            #expect((error as? FallbackRouterError) == .emptyChain)
        }
    }

    @Test func emptyChainThrowsOnStreamMessage() async {
        // 边界：stream 路径空链同样抛 emptyChain，不崩
        var router = FallbackRouter(providerIDs: [])
        do {
            _ = try await router.streamMessage(
                messages: [],
                systemPrompt: nil,
                maxTokens: 128,
                temperature: nil
            ) { _ in ScriptedLLMProvider(id: "unused") }
            Issue.record("expected emptyChain")
        } catch {
            #expect((error as? FallbackRouterError) == .emptyChain)
        }
    }

    @Test func duplicateProviderIDsTriedOnlyOnce() async throws {
        // 边界：链中重复的 provider id 只尝试一次，trail 不重复计数
        let failing = ScriptedLLMProvider(id: "dup", failure: TimeoutError())
        let backup = ScriptedLLMProvider(id: "backup", responses: ["ok"])
        var router = FallbackRouter(providerIDs: ["dup", "dup", "dup", "backup"])
        let result = try await router.sendMessage(
            messages: [],
            systemPrompt: nil,
            maxTokens: 128,
            temperature: nil
        ) { id in
            id == "dup" ? failing : backup
        }
        #expect(result.providerID == "backup")
        #expect(router.events.count == 1)
        #expect(router.events.first?.providerID == "dup")
    }

    @Test func allFailTrailAttemptsAreSequential() async {
        // 边界：全失败 trail 的 attempt 从 1 递增，顺序 = 链顺序
        var router = FallbackRouter(providerIDs: ["a", "b", "c"])
        do {
            _ = try await router.sendMessage(
                messages: [],
                systemPrompt: nil,
                maxTokens: 128,
                temperature: nil
            ) { id in
                ScriptedLLMProvider(id: id, failure: TimeoutError())
            }
            Issue.record("expected allProvidersFailed")
        } catch let error as FallbackRouterError {
            guard case .allProvidersFailed(let events) = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(events.map(\.providerID) == ["a", "b", "c"])
            #expect(events.map(\.attempt) == [1, 2, 3])
            #expect(events.allSatisfy { !$0.errorDescription.isEmpty })
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}
