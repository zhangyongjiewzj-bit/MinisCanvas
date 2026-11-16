import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// The held effect is the only test double in this chain. The limiter, runner,
/// speech availability gate, Composer authorization wrapper, and AgentContext's
/// per-run recording wrapper are the production implementations.
private final class HeldPhysicalTool: ToolExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private let firstReady = PhysicalToolReadyBarrier()
    private var releaseFirstContinuation: CheckedContinuation<Void, Never>?
    private var enteredQueries: [String] = []
    private var active = 0
    private var peak = 0

    func execute(name: String, input: [String: Any]) async throws -> String {
        let query = input["query"] as? String ?? ""
        let holdsFirst = lock.withLock { () -> Bool in
            enteredQueries.append(query)
            active += 1
            peak = max(peak, active)
            return query == "first"
        }
        if holdsFirst {
            // Install the continuation before signaling readiness. Cancellation
            // is intentionally ignored so logical timeout precedes physical exit.
            await withCheckedContinuation { continuation in
                lock.withLock { releaseFirstContinuation = continuation }
                Task { await firstReady.signal() }
            }
        }
        lock.withLock { active -= 1 }
        return "physical:\(query)"
    }

    func waitForFirstPhysicalEntry() async -> Bool {
        await firstReady.wait()
    }

    func releaseFirst() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            let value = releaseFirstContinuation
            releaseFirstContinuation = nil
            return value
        }
        continuation?.resume()
    }

    var entries: [String] { lock.withLock { enteredQueries } }
    var activeCount: Int { lock.withLock { active } }
    var peakActiveCount: Int { lock.withLock { peak } }
}

private actor PhysicalToolReadyBarrier {
    private var ready = false
    private var waiter: CheckedContinuation<Bool, Never>?
    private var watchdog: Task<Void, Never>?

    func signal() {
        ready = true
        watchdog?.cancel()
        watchdog = nil
        waiter?.resume(returning: true)
        waiter = nil
    }

    func wait() async -> Bool {
        if ready { return true }
        return await withCheckedContinuation { continuation in
            waiter = continuation
            watchdog = Task {
                try? await Task.sleep(for: .seconds(5))
                expire()
            }
        }
    }

    private func expire() {
        guard !ready else { return }
        waiter?.resume(returning: false)
        waiter = nil
        watchdog = nil
    }
}

private final class OnePhysicalToolCallProvider: LLMProvider, @unchecked Sendable {
    let name = "physical-tail-offline"
    var model = LLMModel(
        id: "physical-tail-model", displayName: "Physical Tail", provider: "physical-tail-offline"
    )
    let capabilities: Set<ProviderCapability> = [.tools]
    let query: String
    private let lock = NSLock()
    private var calls = 0

    init(query: String) { self.query = query }
    var requestCount: Int { lock.withLock { calls } }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        try await sendMessage(
            messages: messages, systemPrompt: systemPrompt, tools: [],
            maxTokens: maxTokens, temperature: temperature
        )
    }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
        maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        let request = lock.withLock { () -> Int in
            calls += 1
            return calls
        }
        guard request == 1 else {
            return LLMResponse(text: "done", stopReason: "stop", usage: nil)
        }
        let input: [String: Any] = ["query": query]
        return LLMResponse(text: "", stopReason: "tool_calls", usage: nil, toolCalls: [
            LLMToolCall(
                id: "physical-\(query)", name: "web_search",
                rawArguments: "{\"query\":\"\(query)\"}", arguments: input
            )
        ])
    }

    func streamMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct PhysicalTurnResult: Sendable {
    let timedOut: Bool
    let succeeded: Bool
    let unexpectedError: String?
    let facts: [ToolExecutionFact]
    let providerRequests: Int
}

@Suite("D-CONC2 production wrapper physical tail across turns", .serialized)
struct ProductionToolPhysicalTailAcrossTurnsTests {
    private let sessionID = "physical-tail-session"
    private let workspaceID = "physical-tail-workspace"
    private let policyRevision = "physical-tail-policy"
    private let grantEpoch = "physical-tail-epoch"

    private func runTurn(
        query: String,
        turnID: Int,
        timeout: TimeInterval,
        executor: any ToolExecutor,
        ledger: ToolExecutionFactLedger
    ) async -> PhysicalTurnResult {
        let messageID = "physical-message-\(turnID)"
        let attemptID = "physical-attempt-\(turnID)"
        let snapshot = ComposerSubmissionSnapshot(
            mode: .auto, approvalScope: .request, effort: .standard,
            sessionID: sessionID, turnID: turnID,
            taskID: "physical-task-\(turnID)", attemptID: attemptID,
            messageID: messageID, workspaceID: workspaceID, createdAt: Date(),
            policyRevision: policyRevision, grantEpoch: grantEpoch,
            autonomyCeiling: .l3
        )
        let facts = ComposerPolicyFactSource(
            knownCapabilities: ["web_search"], grantedCapabilities: ["web_search"],
            allowedWriteRoots: [], workspaceID: workspaceID, revision: policyRevision,
            grantEpoch: grantEpoch, leaseID: "physical-lease",
            expiresAt: .distantFuture, autonomyCeiling: .l3
        )
        let identity = AgentExecutionIdentity(
            turn: AgentTurnIdentity(
                sessionID: sessionID, turnID: turnID, messageID: messageID
            ),
            operationID: "physical-operation-\(turnID)", attempt: 1
        )
        let provider = OnePhysicalToolCallProvider(query: query)
        let speechGated = SpeechAvailabilityGatedToolExecutor(
            base: executor, availability: nil
        )
        let composer = ComposerPolicyEnforcedToolExecutor(
            base: speechGated,
            controller: ComposerAuthorizationController(snapshot: snapshot, facts: facts)
        )
        var context = AgentContext(
            toolExecutor: composer, provider: provider,
            tools: [AgentToolDefinition(
                name: "web_search", description: "Controlled physical search",
                parameters: ["query": AgentToolParam(type: .string, description: "Query")],
                required: ["query"]
            )],
            maxIterations: 2, timeout: timeout,
            currentConversationID: sessionID,
            toolExecutionFactLedger: ledger,
            executionIdentity: identity, composerSnapshot: snapshot
        )
        var timedOut = false
        var succeeded = false
        var unexpectedError: String?
        do {
            _ = try await context.run(userMessage: query)
            succeeded = true
        } catch let error as ToolExecutorError {
            if case .toolTimeout = error {
                timedOut = true
            } else {
                unexpectedError = String(describing: error)
            }
        } catch {
            unexpectedError = String(describing: error)
        }
        return PhysicalTurnResult(
            timedOut: timedOut, succeeded: succeeded, unexpectedError: unexpectedError,
            facts: ledger.facts(
                executionIdentity: identity,
                attemptID: attemptID,
                attemptNumber: identity.attempt
            ),
            providerRequests: provider.requestCount
        )
    }

    @Test("a timed-out physical effect excludes the next real turn until it exits")
    func logicalTimeoutCannotReleaseThePhysicalTail() async throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory
            .appendingPathComponent("physical-tail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try ToolExecutionFactLedger(
            persistenceURL: root.appendingPathComponent("tool-facts.json")
        )
        let physical = HeldPhysicalTool()
        // The App constructor creates the actual limiter and shared runner.
        let engine = AgentLoopChatEngine(toolExecutor: physical, concurrentToolLimit: 2)
        let productionLimiter = engine.composedExecutor
        #expect(productionLimiter is ConcurrentToolLimitingExecutor)

        let first = Task {
            await runTurn(
                query: "first", turnID: 1, timeout: 0.2,
                executor: productionLimiter, ledger: ledger
            )
        }
        defer { physical.releaseFirst(); first.cancel() }
        try #require(await physical.waitForFirstPhysicalEntry(),
                     "The first call must cross the real wrappers into the physical executor")
        let firstResult = await first.value
        #expect(firstResult.timedOut)
        #expect(firstResult.unexpectedError == nil)
        #expect(firstResult.facts.count == 1)
        #expect(firstResult.facts.first?.status == .failed)
        #expect(firstResult.facts.first?.failureCategory == .timeout)
        #expect(physical.entries == ["first"])
        #expect(physical.activeCount == 1)

        // A second complete turn is the readiness barrier: it has obtained a
        // terminal fact. If the same physical tail is enforced, it times out
        // while queued and never enters the base effect.
        let secondResult = await runTurn(
            query: "second", turnID: 2, timeout: 0.2,
            executor: productionLimiter, ledger: ledger
        )
        #expect(secondResult.timedOut)
        #expect(secondResult.unexpectedError == nil)
        #expect(secondResult.facts.count == 1)
        #expect(secondResult.facts.first?.status == .failed)
        #expect(secondResult.facts.first?.failureCategory == .timeout)
        #expect(physical.entries == ["first"])
        #expect(physical.peakActiveCount == 1)

        physical.releaseFirst()
        let thirdResult = await runTurn(
            query: "third", turnID: 3, timeout: 2,
            executor: productionLimiter, ledger: ledger
        )
        #expect(thirdResult.succeeded, "third turn must succeed")
        #expect(thirdResult.providerRequests == 2)
        #expect(thirdResult.facts.count == 1)
        #expect(thirdResult.facts.first?.status == .succeeded)
        #expect(physical.entries == ["first", "third"],
                "A queued timed-out second turn must never dispatch after release")
        #expect(physical.activeCount == 0)
        #expect(physical.peakActiveCount == 1)
        #expect(firstResult.facts.first?.status == .failed,
                "Late physical completion must not overwrite the first timeout")
    }
}
