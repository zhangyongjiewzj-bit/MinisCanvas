import Foundation
import Testing
@testable import MinisCore

private actor Child2069CallCounter {
    private(set) var calls = 0

    func record() {
        calls += 1
    }
}

private final class Child2069CountingProvider: LLMProvider {
    let name = "Child2069"
    var model: LLMModel = .claudeHaiku45
    var capabilities: Set<ProviderCapability> { [.streaming] }
    let counter: Child2069CallCounter

    init(counter: Child2069CallCounter) {
        self.counter = counter
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        await counter.record()
        return LLMResponse(text: "done", stopReason: nil, usage: nil)
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

/// Test-only observation of the actual provider method's return boundary.
private final class Child2069ExitProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var exited = false
    var hasExited: Bool {
        lock.lock(); defer { lock.unlock() }; return exited
    }
    func markExited() {
        lock.lock(); exited = true; lock.unlock()
    }
}

private final class Child2069HoldingProvider: LLMProvider {
    let name = "Child2069Hold"
    var model: LLMModel = .claudeHaiku45
    var capabilities: Set<ProviderCapability> { [.streaming] }
    let gate: ChildHoldGate188
    let exitProbe = Child2069ExitProbe()

    init(gate: ChildHoldGate188) {
        self.gate = gate
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        defer { exitProbe.markExited() }
        await gate.arriveAndHold()
        return LLMResponse(text: "done", stopReason: nil, usage: nil)
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

@Suite("CHILDD cancelled local gate waiter returns its global permit")
struct ChildGateCancelledWaiter2069Tests {
    @Test(arguments: ["task", "turn"])
    func cancelledWaiterDoesNotStarveNextSessionBehindLiveSibling(_ cancellation: String) async {
        let governor = ChildConcurrencyGovernor(policy: .init(globalHardCeiling: 2))
        let held = ChildHoldGate188()
        let otherCalls = Child2069CallCounter()
        let controller = TurnController()
        let turn = await controller.beginTurn()
        defer { Task { await turn.finish() } }
        let holdingProvider = Child2069HoldingProvider(gate: held)
        let parent = ParentRuntimeIdentity(
            sessionID: "session-A",
            conversationID: "session-A",
            turnID: "turn-handle:\(turn.turnID)",
            taskID: "session-A",
            actorID: "test"
        )
        let first = AgentOrchestrator(
            provider: holdingProvider,
            toolExecutor: NoopToolExecutor(),
            turnController: controller,
            currentConversationID: parent.conversationID,
            taskStore: AgentTaskStore(),
            parentID: "session-A",
            parentBinding: ParentContextSnapshotV1(
                providerID: holdingProvider.name,
                modelID: holdingProvider.model.id,
                configurationFingerprint: "child2069-frozen",
                conversationID: parent.conversationID
            ),
            parentRuntimeIdentity: parent,
            parentTurnHandle: turn,
            runtimeMode: .production,
            capabilityPolicy: AgentCapabilityPolicy(
                allowedCapabilities: [.streaming],
                allowedToolNames: [],
                allowedMCPToolNames: []
            ),
            parentCapabilities: [.streaming],
            childGovernor: governor
        )
        let other = AgentOrchestrator(
            provider: Child2069CountingProvider(counter: otherCalls),
            toolExecutor: NoopToolExecutor(),
            parentID: "session-B",
            childGovernor: governor
        )

        let running = Task {
            await first.orchestrate(tasks: [
                SubAgentTask(id: "A-1", title: "holder", instructions: "hold"),
                SubAgentTask(id: "A-2", title: "queued", instructions: "must not launch")
            ], strategy: .parallelWithLimit(limit: 1))
        }
        let entered = await held.waitUntilArrivals(atLeast: 1)
        #expect(entered, "A-1 must hold the local gate before the race")

        // The second A child has a global grant but waits for A-1's local
        // gate. A distinct session must then be queued at the global ceiling.
        var occupied = false
        for _ in 0..<100 {
            let checkpoint = await governor.checkpoint()
            if checkpoint.globalActive == 2
                && checkpoint.perSessionActive["session-A"] == 2 {
                occupied = true
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(occupied, "both A permits must be observable before cancellation")
        let nextSession = Task {
            await other.orchestrate(
                tasks: [SubAgentTask(id: "B-1", title: "next", instructions: "run")],
                strategy: .sequential
            )
        }
        var queued = false
        for _ in 0..<100 {
            if await governor.checkpoint().queuedSessions == ["session-B"] {
                queued = true
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(queued, "B must be behind the two A grants before cancellation")

        if cancellation == "task" {
            running.cancel()
        } else {
            await controller.interrupt(turnID: turn.turnID)
        }
        var otherStartedBeforeHolderReleased = false
        for _ in 0..<100 {
            if await otherCalls.calls == 1 {
                otherStartedBeforeHolderReleased = true
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let beforeRelease = await governor.checkpoint()

        // Always release the synthetic holder so a RED cannot hang the suite.
        await held.releaseAll()
        let firstReports = await running.value
        let otherReports = await nextSession.value

        #expect(otherStartedBeforeHolderReleased,
            "cancelled A-2 must return its global grant while A-1 still holds the local gate")
        #expect(beforeRelease.perSessionActive["session-A", default: 0] <= 1,
            "A-2 must not remain a ghost global permit after its owner is cancelled")
        #expect(beforeRelease.queuedSessions.isEmpty,
            "B must be granted in FIFO order without waiting for A-1 to finish")
        #expect(firstReports.count == 2)
        #expect(otherReports.count == 1)
        #expect(await otherCalls.calls == 1)
        // Releasing the fixture continuation and receiving the canonical
        // report do not prove the uncooperative provider actually returned.
        let exitDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < exitDeadline {
            if holdingProvider.exitProbe.hasExited {
                let checkpoint = await governor.checkpoint()
                if checkpoint.globalActive == 0 { break }
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(holdingProvider.exitProbe.hasExited)
        #expect(await governor.checkpoint().globalActive == 0)
    }
}
