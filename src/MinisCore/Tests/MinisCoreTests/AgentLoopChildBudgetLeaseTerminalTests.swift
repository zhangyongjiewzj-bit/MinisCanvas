import Foundation
import Testing
@testable import MinisCore

/// Holds a real provider request after BudgetTracker.beginRequest has reserved
/// its slot. The test controls the exact order of parent cancellation and the
/// successful provider return; it does not replace AgentLoop or its budget.
private actor LeaseTerminalProviderBarrier {
    private var entered = false
    private var released = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func waitUntilEntered() async throws {
        // Keep a failed preflight from hanging the focused suite indefinitely.
        for _ in 0..<500 {
            if entered { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AgentLoopError.timedOut(5)
    }

    func holdUntilReleased() async {
        entered = true
        await withCheckedContinuation { continuation in
            if released { continuation.resume() }
            else { releaseWaiter = continuation }
        }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor LeaseTerminalCallCount {
    private(set) var value = 0
    func record() { value += 1 }
}

private final class LeaseTerminalProvider: LLMProvider, @unchecked Sendable {
    let name = "lease-terminal-synthetic-provider"
    var model = LLMModel(
        id: "lease-terminal-synthetic-model",
        displayName: "Synthetic lease terminal",
        provider: "lease-terminal-synthetic-provider"
    )
    let capabilities: Set<ProviderCapability> = [.streaming]
    private let barrier: LeaseTerminalProviderBarrier?
    private let callCount: LeaseTerminalCallCount?

    init(barrier: LeaseTerminalProviderBarrier? = nil, callCount: LeaseTerminalCallCount? = nil) {
        self.barrier = barrier
        self.callCount = callCount
    }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        await callCount?.record()
        if let barrier { await barrier.holdUntilReleased() }
        return LLMResponse(text: "done", stopReason: "stop", usage: nil)
    }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
        maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        try await sendMessage(
            messages: messages, systemPrompt: systemPrompt,
            maxTokens: maxTokens, temperature: temperature
        )
    }

    func streamMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct LeaseTerminalNoopExecutor: ToolExecutor {
    func execute(name: String, input: [String: Any]) async throws -> String {
        Issue.record("unexpected tool execution: \(name)")
        return "unreachable"
    }
}

@Suite("D-CONC2 child provider budget lease terminal", .serialized)
struct AgentLoopChildBudgetLeaseTerminalTests {
    @Test("parent cancellation after provider entry releases the failed child lease")
    func cancelledChildReleasesLeaseBeforeNextLegalRequest() async throws {
        let tracker = BudgetTracker(RequestBudget(
            maxRequestsPerSession: 1,
            overBudgetPolicy: .pause
        ))
        let controller = TurnController()
        let firstParent = await controller.beginTurn()
        let firstBoundary = try makeBoundary(
            parent: firstParent, tracker: tracker, suffix: "first"
        )
        let barrier = LeaseTerminalProviderBarrier()
        let firstProvider = LeaseTerminalProvider(barrier: barrier)
        let firstLoop = AgentLoop(
            maxIterations: 1, requestBudget: tracker,
            timeout: 10, childBoundary: firstBoundary
        )
        let firstRequest = Task {
            try await firstLoop.run(
                messages: [.init(role: .user, content: "first")],
                systemPrompt: nil, provider: firstProvider,
                toolExecutor: LeaseTerminalNoopExecutor(), tools: []
            )
        }

        try await barrier.waitUntilEntered()
        #expect(await tracker.pendingRequestCount == 1)
        // Exact order: the parent is cancelled only after the child has a
        // reserved, actively executing provider call; the provider then
        // returns a successful response rather than throwing cancellation.
        await firstParent.interrupt()
        await barrier.release()
        await #expect(throws: InterruptedError.self) {
            _ = try await firstRequest.value
        }
        #expect(await tracker.pendingRequestCount == 0,
                "terminal childBoundary rejection must release the request lease")

        // Production orchestrators can reuse a bounded inherited tracker.
        // A new, valid child on that same tracker must still be admitted.
        let secondParent = await controller.beginTurn()
        let secondBoundary = try makeBoundary(
            parent: secondParent, tracker: tracker, suffix: "second"
        )
        let secondLoop = AgentLoop(
            maxIterations: 1, requestBudget: tracker,
            timeout: 10, childBoundary: secondBoundary
        )
        let secondCallCount = LeaseTerminalCallCount()
        await #expect(throws: AgentLoopError.self) {
            _ = try await secondLoop.run(
                messages: [.init(role: .user, content: "second")],
                systemPrompt: nil,
                provider: LeaseTerminalProvider(callCount: secondCallCount),
                toolExecutor: LeaseTerminalNoopExecutor(), tools: []
            )
        }
        // At cap=1, a successful second response legitimately ends the turn
        // with budgetExhausted. Entry and the committed count distinguish that
        // from an early rejection caused by the leaked first lease.
        #expect(await secondCallCount.value == 1)
        #expect(await tracker.budget.usedRequests == 1)
        #expect(await tracker.pendingRequestCount == 0)
        await secondParent.finish()
    }

    @Test("valid child success settles one request without leaving a pending lease")
    func successfulChildSettlesExactlyOneRequest() async throws {
        let tracker = BudgetTracker(RequestBudget(
            maxRequestsPerSession: 2,
            overBudgetPolicy: .pause
        ))
        let controller = TurnController()
        let parent = await controller.beginTurn()
        let boundary = try makeBoundary(parent: parent, tracker: tracker, suffix: "success")
        let callCount = LeaseTerminalCallCount()
        let loop = AgentLoop(
            maxIterations: 1, requestBudget: tracker,
            timeout: 10, childBoundary: boundary
        )
        let result = try await loop.run(
            messages: [.init(role: .user, content: "success")],
            systemPrompt: nil,
            provider: LeaseTerminalProvider(callCount: callCount),
            toolExecutor: LeaseTerminalNoopExecutor(), tools: []
        )
        #expect(result.iterationCount == 1)
        #expect(result.toolCallsExecuted == 0)
        #expect(result.messages.last?.content == "done")
        #expect(await callCount.value == 1)
        #expect(await tracker.budget.usedRequests == 1)
        #expect(await tracker.pendingRequestCount == 0)
        #expect(!(await tracker.budget.isExhausted))
        await parent.finish()
    }

    private func makeBoundary(
        parent: TurnController.TurnHandle,
        tracker: BudgetTracker,
        suffix: String
    ) throws -> AgentChildBoundary {
        let parentIdentity = ParentRuntimeIdentity(
            sessionID: "synthetic-parent-session-\(suffix)",
            conversationID: "synthetic-parent-conversation-\(suffix)",
            turnID: "turn-handle:\(parent.turnID)",
            taskID: "synthetic-parent-task-\(suffix)",
            actorID: "lease-terminal-test"
        )
        let identity = try ChildRuntimeIdentity.derive(
            parent: parentIdentity,
            childSessionID: "synthetic-child-session-\(suffix)",
            childTaskID: "synthetic-child-task-\(suffix)",
            scopeID: "synthetic-scope-\(suffix)",
            requestedCapabilities: [.streaming],
            parentCapabilities: [.streaming],
            policyCapabilities: [.streaming],
            providerSnapshot: ParentContextSnapshotV1(
                providerID: "lease-terminal-synthetic-provider",
                modelID: "lease-terminal-synthetic-model",
                configurationFingerprint: "synthetic-lease-terminal-\(suffix)",
                conversationID: parentIdentity.conversationID
            ),
            memoryScopeID: "synthetic-memory-\(suffix)",
            workingDirectory: "/synthetic/no-read",
            cancelGeneration: parent.turnID,
            evidenceRoot: "synthetic-evidence-\(suffix)",
            parentTurnHandle: parent,
            childExecutionID: "synthetic-execution-\(suffix)"
        )
        return try AgentChildBoundary(
            identity: identity,
            parentCapabilities: [.streaming],
            requestedCapabilities: [.streaming],
            policy: AgentCapabilityPolicy(allowedCapabilities: [.streaming]),
            parentTools: [],
            budget: tracker,
            deadline: Date().addingTimeInterval(30),
            parentTurnHandle: parent
        )
    }
}
