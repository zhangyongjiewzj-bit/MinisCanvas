import Foundation
import Testing
@testable import MinisCore

// MARK: - Lane QODER-DEV-W13-GOVSESSION-188: cross-session governor identity isolation
//
// P3-CHILD-40 residual (lane 142 open finding E, left unfixed by lane 150's
// Kill-Switch/checkpoint wiring): `AgentOrchestrator.governorSessionKey`
// ended in the shared literal "orchestration", so every orchestrator
// constructed WITHOUT runtime identity / parentID / conversationID — the
// static `OrchestrationToolExecutor` orchestrator built in
// BridgeStore.attachProductionServices and identity-less
// `SecureAgentLoopFactory.makeOrchestrator` callers — collapsed onto ONE
// governor per-session ledger key, defeating per-session accounting and
// cross-session fairness on that path. The fallback is now instance-unique
// ("orchestration:<fresh per-instance UUID>"); every higher-precedence term
// of the chain keeps its exact previous value. These tests drive the real
// sequential `orchestrate` admission path (requestLaunch/releaseLaunch on a
// shared `ChildConcurrencyGovernor`) and read the governor's checkpoint
// ledger; nothing asserts on source text.

// MARK: - Fixtures

/// Holds each child's provider call until the test releases it, and lets the
/// test await "N children have entered" without sleep-based timing.
actor ChildHoldGate188 {
    private var arrivals = 0
    private var held: [CheckedContinuation<Void, Never>] = []
    private var releaseFutureArrivals = false

    /// Called from the fake provider: records the arrival, then suspends the
    /// child (keeping its governor slot granted) until `releaseAll`.
    func arriveAndHold() async {
        arrivals += 1
        if releaseFutureArrivals { return }
        await withCheckedContinuation { held.append($0) }
    }

    /// A missing provider call must fail the test, not leave its child parked
    /// forever. On timeout, drain any held child and let later arrivals finish.
    func waitUntilArrivals(atLeast threshold: Int) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while arrivals < threshold && clock.now < deadline && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if arrivals >= threshold { return true }
        releaseFutureArrivals = true
        releaseAll()
        return false
    }

    func releaseAll() {
        let pending = held
        held.removeAll()
        for cont in pending { cont.resume() }
    }

}

/// Text-only provider whose every child call parks on the hold gate, so the
/// orchestration is observably mid-flight (slot granted, child not finished).
final class HoldingChildProvider188: LLMProvider {
    var name: String { "Holding188" }
    var model: LLMModel = .claudeHaiku45
    private let gate: ChildHoldGate188

    init(gate: ChildHoldGate188) {
        self.gate = gate
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        await gate.arriveAndHold()
        return LLMResponse(text: "子任务完成", stopReason: nil, usage: nil)
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

private func childTask188(_ id: String) -> SubAgentTask {
    SubAgentTask(id: id, title: "任务 \(id)", instructions: "执行 \(id) 的指令")
}

private func activeLedger(_ checkpoint: ChildConcurrencyCheckpoint) -> [String: Int] {
    checkpoint.perSessionActive.filter { $0.value > 0 }
}

// MARK: - Tests

struct GovernorSessionKeyIsolation188Tests {

    @Test("two identity-less orchestrators never collapse onto one governor key")
    func identityLessOrchestratorsGetDistinctSessionKeys() async {
        let governor = ChildConcurrencyGovernor(policy: .init(globalHardCeiling: 4))
        let gateA = ChildHoldGate188()
        let gateB = ChildHoldGate188()
        // Both instances carry NO runtime identity, parentID or conversationID
        // — exactly the static-executor shape of lane 142 open finding E.
        let orchA = AgentOrchestrator(
            provider: HoldingChildProvider188(gate: gateA),
            toolExecutor: NoopToolExecutor(),
            childGovernor: governor
        )
        let orchB = AgentOrchestrator(
            provider: HoldingChildProvider188(gate: gateB),
            toolExecutor: NoopToolExecutor(),
            childGovernor: governor
        )

        async let reportsA: [SubAgentReport] = orchA.orchestrate(
            tasks: [childTask188("a-1")], strategy: .sequential
        )
        async let reportsB: [SubAgentReport] = orchB.orchestrate(
            tasks: [childTask188("b-1")], strategy: .sequential
        )
        let enteredA = await gateA.waitUntilArrivals(atLeast: 1)
        let enteredB = await gateB.waitUntilArrivals(atLeast: 1)
        #expect(enteredA && enteredB, "both child providers must enter before checkpoint")

        let mid = await governor.checkpoint()
        let ledger = activeLedger(mid)
        // The collapse at base head put BOTH launches under the single literal
        // "orchestration" (one ledger entry of value 2). Post-fix each
        // instance owns a distinct instance-unique key with exactly one grant.
        #expect(ledger.count == 2, "distinct sessions must not share one key: \(ledger)")
        #expect(ledger.values.reduce(0, +) == 2)
        #expect(ledger["orchestration"] == nil, "the shared literal key must never appear")
        for key in ledger.keys {
            #expect(key.hasPrefix("orchestration:"))
            #expect(!key.trimmingCharacters(in: .whitespaces).isEmpty)
        }

        await gateA.releaseAll()
        await gateB.releaseAll()
        let reports = await (reportsA, reportsB)
        #expect(reports.0.count == 1 && reports.1.count == 1)

        // Grant/release symmetry on the unique keys: each sequential path
        // releases synchronously with the SAME key it granted, so the ledger
        // must drain to zero. A mismatched fallback (e.g. re-minting the key
        // per access) would leave phantom grants and desync globalActive.
        let after = await governor.checkpoint()
        #expect(activeLedger(after).isEmpty)
        #expect(after.globalActive == 0)
    }

    @Test("the fallback key is stable for every child of one orchestration")
    func fallbackKeyStableAcrossChildrenOfOneInstance() async {
        let governor = ChildConcurrencyGovernor(policy: .init(globalHardCeiling: 4))
        let gate = ChildHoldGate188()
        let orchestrator = AgentOrchestrator(
            provider: HoldingChildProvider188(gate: gate),
            toolExecutor: NoopToolExecutor(),
            childGovernor: governor
        )

        let running = Task {
            await orchestrator.orchestrate(
                tasks: [childTask188("s-1"), childTask188("s-2"), childTask188("s-3")],
                strategy: .sequential
            )
        }

        var observedKeys: [String] = []
        for arrival in 1...3 {
            let entered = await gate.waitUntilArrivals(atLeast: arrival)
            #expect(entered, "child \(arrival) did not reach its provider before checkpoint")
            let ledger = activeLedger(await governor.checkpoint())
            #expect(ledger.count == 1, "one instance in flight owns exactly one key: \(ledger)")
            #expect(ledger.values.first == 1)
            observedKeys.append(contentsOf: ledger.keys)
            await gate.releaseAll()
        }
        _ = await running.value

        // Same instance => same fallback key across children (release matches
        // the grant), and the final ledger is fully drained.
        #expect(Set(observedKeys).count == 1)
        #expect(observedKeys.first?.hasPrefix("orchestration:") == true)
        let after = await governor.checkpoint()
        #expect(activeLedger(after).isEmpty)
        #expect(after.globalActive == 0)
    }

    @Test("parentID keeps precedence over the instance fallback")
    func parentIDIdentityStillWins() async {
        let governor = ChildConcurrencyGovernor(policy: .init(globalHardCeiling: 4))
        let gate = ChildHoldGate188()
        let orchestrator = AgentOrchestrator(
            provider: HoldingChildProvider188(gate: gate),
            toolExecutor: NoopToolExecutor(),
            parentID: "lane188-parent",
            childGovernor: governor
        )
        let running = Task {
            await orchestrator.orchestrate(
                tasks: [childTask188("p-1")], strategy: .sequential
            )
        }
        let entered = await gate.waitUntilArrivals(atLeast: 1)
        #expect(entered, "the parentID child did not reach its provider")
        let ledger = activeLedger(await governor.checkpoint())
        #expect(ledger == ["lane188-parent": 1])
        await gate.releaseAll()
        _ = await running.value
    }

    @Test("conversationID keeps precedence over the instance fallback")
    func conversationIDIdentityStillWins() async {
        let governor = ChildConcurrencyGovernor(policy: .init(globalHardCeiling: 4))
        let gate = ChildHoldGate188()
        let orchestrator = AgentOrchestrator(
            provider: HoldingChildProvider188(gate: gate),
            toolExecutor: NoopToolExecutor(),
            currentConversationID: "lane188-conv",
            childGovernor: governor
        )
        let running = Task {
            await orchestrator.orchestrate(
                tasks: [childTask188("c-1")], strategy: .sequential
            )
        }
        let entered = await gate.waitUntilArrivals(atLeast: 1)
        #expect(entered, "the conversationID child did not reach its provider")
        let ledger = activeLedger(await governor.checkpoint())
        #expect(ledger == ["lane188-conv": 1])
        await gate.releaseAll()
        _ = await running.value
    }
}
