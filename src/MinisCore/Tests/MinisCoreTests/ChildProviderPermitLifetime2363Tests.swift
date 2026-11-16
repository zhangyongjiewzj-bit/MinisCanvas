import Foundation
import Testing
@testable import MinisCore

/// Counts real entries/exits of the provider protocol implementation. It does
/// not settle a child, return a synthetic receipt, or release a governor slot.
private actor Provider2363Lifetime {
    private(set) var names: [String] = []
    private(set) var active = 0
    private(set) var peak = 0
    private var held: CheckedContinuation<Void, Never>?
    private var released = false
    func invoke(_ name: String) async {
        names.append(name); active += 1; peak = max(peak, active)
        if name == "A", !released {
            // Intentionally ignores Task cancellation until the owned test
            // releases the actual call, as an uncooperative provider can.
            await withCheckedContinuation { held = $0 }
        }
        active -= 1
    }
    func releaseA() { released = true; held?.resume(); held = nil }
}

private final class Provider2363: LLMProvider {
    let name: String
    var model = LLMModel(id: "owned2363-model", displayName: "Owned", provider: "synthetic")
    var capabilities: Set<ProviderCapability> { [.streaming] }
    let lifetime: Provider2363Lifetime
    init(name: String, lifetime: Provider2363Lifetime) { self.name = name; self.lifetime = lifetime }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        await lifetime.invoke(name)
        return LLMResponse(text: "actual provider finished " + name, stopReason: "stop", usage: nil)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
private struct NoTools2363: ToolExecutor {
    func execute(name: String, input: [String: Any]) async throws -> String {
        throw ToolExecutorError.unknownTool(name)
    }
}
private actor Reports2363 {
    private(set) var reports: [SubAgentReport]?
    func record(_ value: [SubAgentReport]) { reports = value }
}


private final class SequentialProvider2913: LLMProvider {
    let name = "sequential2913"
    var model = LLMModel(id: "owned2913", displayName: "Owned", provider: "synthetic")
    private let lock = NSLock()
    private var calls = 0
    let lifetime: Provider2363Lifetime
    init(lifetime: Provider2363Lifetime) { self.lifetime = lifetime }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        let index = lock.withLock { calls += 1; return calls }
        await lifetime.invoke(index == 1 ? "A" : "B")
        return LLMResponse(text: "actual sequential provider finished", stopReason: "stop", usage: nil)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@Suite("CHILDD actual provider exit owns its global permit", .serialized)
struct ChildProviderPermitLifetime2363Tests {
    private func production(store: AgentTaskStore, governor: ChildConcurrencyGovernor?,
                            provider: any LLMProvider, handle: TurnController.TurnHandle,
                            timeout: TimeInterval) -> AgentOrchestrator {
        let session = "2363-" + provider.name
        let parent = ParentRuntimeIdentity(sessionID: session, conversationID: session,
            turnID: "turn-handle:\(handle.turnID)", taskID: session + "-parent", actorID: "owned2363")
        return AgentOrchestrator(provider: provider, toolExecutor: NoTools2363(), childTimeout: timeout,
            currentConversationID: session, taskStore: store, parentID: parent.taskID,
            parentBinding: ParentContextSnapshotV1(providerID: provider.name, modelID: provider.model.id,
                configurationFingerprint: "owned2363-frozen", conversationID: session),
            parentRuntimeIdentity: parent,
            parentGoal: GoalEnvelope(scopeID: session + "-scope", allowedCapabilities: ["orchestrate"],
                budget: 100, deadline: Date().addingTimeInterval(60), autonomyLevel: .l3),
            parentTurnHandle: handle, runtimeMode: .production,
            capabilityPolicy: AgentCapabilityPolicy(allowedCapabilities: [.streaming],
                allowedToolNames: [], allowedMCPToolNames: []), parentCapabilities: [.streaming],
            childGovernor: governor)
    }

    @Test("an interrupted exact parent retains its cancellation error while actual local permit is held")
    func interruptedParentAtHeldLocalGate2976() async throws {
        let store = AgentTaskStore(), lifetime = Provider2363Lifetime()
        let controller = TurnController(), handle = await controller.beginTurn()
        defer { Task { await lifetime.releaseA(); await handle.finish() } }
        let orchestrator = production(store: store, governor: nil,
            provider: SequentialProvider2913(lifetime: lifetime), handle: handle, timeout: 10)
        let observed = Reports2363()
        let work = Task {
            await observed.record(orchestrator.orchestrate(tasks: [
                SubAgentTask(id: "A", title: "Held", instructions: "Complete"),
                SubAgentTask(id: "B", title: "Never dispatch", instructions: "Complete")
            ], strategy: .sequential))
        }
        defer { work.cancel() }
        var deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await lifetime.names.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(await lifetime.names == ["A"])
        await handle.interrupt()
        deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await observed.reports == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let reports = try #require(await observed.reports)
        print("TASK2976 held actual parent cancellation reports=\(reports.map { $0.result })")
        #expect(reports.map { $0.taskID } == ["A", "B"])
        #expect(reports.allSatisfy { $0.result == .failed(error: "任务已取消") })
        #expect(await lifetime.names == ["A"], "cancelled parent must make zero B Provider calls")
        #expect(await lifetime.active == 1, "logical cancellation does not release actual local permit")
        let parentID = "2363-sequential2913-parent"
        #expect(store.snapshot(taskID: "B", parentID: parentID) == nil)
        let cancelledReceipt = try #require(store.allReceipts().first { $0.taskID == "A" })
        #expect(cancelledReceipt.outcome == .cancelled)
        await lifetime.releaseA()
        await work.value
        deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await lifetime.active != 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await lifetime.active == 0)
        #expect(store.allReceipts() == [cancelledReceipt], "late physical completion cannot rewrite cancellation")
    }

    @Test(arguments: [false, true], [false, true])
    func outwardTerminalCannotAdmitAnotherActualProvider(cancelParent: Bool, parallelA: Bool) async throws {
        let formal = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = formal.rootDirectory.appendingPathComponent("child2363-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json"))
        let governor = ChildConcurrencyGovernor(policy: .init(globalHardCeiling: 1))
        let lifetime = Provider2363Lifetime()
        let controllerA = TurnController(), controllerB = TurnController()
        let handleA = await controllerA.beginTurn(), handleB = await controllerB.beginTurn()
        defer { Task { await lifetime.releaseA(); await handleA.finish(); await handleB.finish() } }
        let a = production(store: store, governor: governor, provider: Provider2363(name: "A", lifetime: lifetime),
            handle: handleA, timeout: cancelParent ? 5 : 0.1)
        let probeA = Reports2363()
        let workA = Task {
            await probeA.record(a.orchestrate(tasks: [SubAgentTask(id: "A", title: "Held", instructions: "Complete")],
                strategy: parallelA ? .parallelWithLimit(limit: 1) : .sequential))
        }
        defer { workA.cancel() }
        var deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await lifetime.names.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let enteredA = await lifetime.names
        try #require(enteredA == ["A"])
        if cancelParent { await handleA.interrupt() }
        deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await probeA.reports == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let reportsA = try #require(await probeA.reports)
        #expect(reportsA.count == 1 && reportsA.first?.result.isSuccess == false)
        let receiptA = try #require(store.allReceipts().first { $0.taskID == "A" })
        #expect(receiptA.outcome == (cancelParent ? .cancelled : .failed(reason: "execution-failed")))
        #expect(await lifetime.active == 1, "outward terminal is not actual provider exit")

        let b = production(store: store, governor: governor, provider: Provider2363(name: "B", lifetime: lifetime),
            handle: handleB, timeout: 5)
        let probeB = Reports2363()
        let workB = Task {
            await probeB.record(b.orchestrate(tasks: [SubAgentTask(id: "B", title: "Next", instructions: "Complete")],
                strategy: .sequential))
        }
        defer { workB.cancel() }
        deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            let queued = await governor.checkpoint().queuedSessions
            let names = await lifetime.names
            if queued == ["2363-B-parent"] || names.contains("B") { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let beforeExit = await governor.checkpoint()
        let beforeNames = await lifetime.names
        let beforePeak = await lifetime.peak
        print("TASK2363 cancel=\(cancelParent) parallelA=\(parallelA) beforeActualAExit active=\(beforeExit.globalActive) queued=\(beforeExit.queuedSessions) providerEntries=\(beforeNames) peak=\(beforePeak)")
        #expect(beforeExit.globalActive == 1)
        #expect(beforeExit.queuedSessions == ["2363-B-parent"])
        #expect(beforeNames == ["A"], "B actual dispatch must wait for A actual exit")
        #expect(beforePeak == 1)

        // Cleanup and genuine positive control, even when the negative is RED.
        await lifetime.releaseA()
        await workA.value
        deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await probeB.reports == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let finishedB = await probeB.reports != nil
        #expect(finishedB, "actual A exit must restore the queued B resource handoff")
        if !finishedB { workB.cancel() }
        await workB.value
        let reportsB = try #require(await probeB.reports)
        #expect(reportsB.first?.result.isSuccess == true)
        #expect(await lifetime.names == ["A", "B"])
        #expect(await lifetime.active == 0)
        #expect(store.receipt(runID: receiptA.runID) == receiptA,
            "late A success cannot overwrite canonical timeout/cancel")
        let receiptB = store.allReceipts().first { $0.taskID == "B" }
        #expect(receiptB?.outcome == .succeeded)
    }
    @Test
    func parentCancellationAbandonsGlobalWaiterBeforeActualSiblingExit() async throws {
        let formal = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = formal.rootDirectory.appendingPathComponent("child2363-global-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json"))
        let governor = ChildConcurrencyGovernor(policy: .init(globalHardCeiling: 1))
        let lifetime = Provider2363Lifetime()
        let controller = TurnController()
        let handle = await controller.beginTurn()
        defer { Task { await lifetime.releaseA(); await handle.finish() } }
        let a = production(store: store, governor: governor,
            provider: Provider2363(name: "A", lifetime: lifetime), handle: handle, timeout: 5)
        let probe = Reports2363()
        let work = Task {
            await probe.record(a.orchestrate(tasks: [
                SubAgentTask(id: "A1", title: "One", instructions: "Complete"),
                SubAgentTask(id: "A2", title: "Two", instructions: "Complete")
            ], strategy: .parallelWithLimit(limit: 2)))
        }
        defer { work.cancel() }
        var deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            let names = await lifetime.names
            let queued = await governor.checkpoint().queuedSessions
            if names == ["A"] && queued == ["2363-A-parent"] { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let initial = await governor.checkpoint()
        try #require(initial.queuedSessions == ["2363-A-parent"])
        try #require(await lifetime.names == ["A"])
        await handle.interrupt()
        deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await probe.reports == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let beforeReports = await probe.reports
        let beforeExit = await governor.checkpoint()
        #expect(beforeReports?.count == 2, "cancelled global waiter must not delay outward reports until actual sibling exit")
        #expect(beforeExit.queuedSessions.isEmpty)
        #expect(beforeExit.globalActive == 1)
        #expect(await lifetime.active == 1)
        let terminal = try #require(store.allReceipts().first)
        #expect(terminal.outcome == .cancelled)
        await lifetime.releaseA()
        await work.value
        #expect(store.receipt(runID: terminal.runID) == terminal)
        #expect(await lifetime.names == ["A"], "cancelled queued sibling never dispatches")
    }

    @Test(arguments: [false, true])
    func sequentialWithoutGlobalGovernorWaitsForActualProviderExit2913(cancelQueued: Bool) async throws {
        let formal = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = formal.rootDirectory.appendingPathComponent("sequential2913-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json"))
        let lifetime = Provider2363Lifetime()
        let controller = TurnController()
        let handle = await controller.beginTurn()
        defer { Task { await lifetime.releaseA(); await handle.finish() } }
        let orchestrator = production(store: store, governor: nil,
            provider: SequentialProvider2913(lifetime: lifetime), handle: handle, timeout: 0.1)
        let probe = Reports2363()
        let work = Task { await probe.record(orchestrator.orchestrate(tasks: [
            SubAgentTask(id: "2913-A", title: "Held", instructions: "Complete"),
            SubAgentTask(id: "2913-B", title: "Next", instructions: "Complete")
        ], strategy: .sequential)) }
        defer { work.cancel() }
        var deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while store.allReceipts().first(where: { $0.taskID == "2913-A" }) == nil,
              ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let first = try #require(store.allReceipts().first { $0.taskID == "2913-A" })
        #expect(first.outcome == .failed(reason: "execution-failed"))
        // Give the same owning loop a bounded opportunity to dispatch B after
        // A's genuine outward terminal. B must remain behind A's actual call.
        for _ in 0..<100 {
            if await lifetime.names.contains("B") { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let namesBeforeExit = await lifetime.names
        let peakBeforeExit = await lifetime.peak
        print("TASK2913 beforeActualExit names=\(namesBeforeExit) peak=\(peakBeforeExit)")
        #expect(namesBeforeExit == ["A"], "sequential B cannot dispatch before actual A exits")
        #expect(peakBeforeExit == 1)
        if cancelQueued {
            await handle.interrupt()
            deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while await probe.reports == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(await probe.reports?.count == 2,
                    "parent cancellation must abandon B's local waiter before actual A exit")
            #expect(await probe.reports?.last?.result.isSuccess == false)
            #expect(await lifetime.names == ["A"])
        }
        await lifetime.releaseA()
        deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await probe.reports == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let done = await probe.reports != nil
        #expect(done, "actual A exit must hand the local sequential permit to B")
        if !done { work.cancel() }
        await work.value
        let reports = try #require(await probe.reports)
        #expect(reports.count == 2 && reports.last?.result.isSuccess == !cancelQueued)
        #expect(await lifetime.names == (cancelQueued ? ["A"] : ["A", "B"]))
        deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await lifetime.active != 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await lifetime.active == 0)
        #expect(await lifetime.peak == 1)
        #expect(store.receipt(runID: first.runID) == first,
                "late A response cannot overwrite its canonical timeout")
    }

    @Test(arguments: [false, true])
    func parallelWithoutGlobalGovernorWaitsForActualProviderExit2935(cancelQueued: Bool) async throws {
        let formal = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = formal.rootDirectory.appendingPathComponent("parallel2935-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json"))
        let lifetime = Provider2363Lifetime()
        let controller = TurnController()
        let handle = await controller.beginTurn()
        defer { Task { await lifetime.releaseA(); await handle.finish() } }
        let orchestrator = production(store: store, governor: nil,
            provider: SequentialProvider2913(lifetime: lifetime), handle: handle, timeout: 0.1)
        let probe = Reports2363()
        let work = Task { await probe.record(orchestrator.orchestrate(tasks: [
            SubAgentTask(id: "2935-A", title: "Held", instructions: "Complete"),
            SubAgentTask(id: "2935-B", title: "Next", instructions: "Complete")
        ], strategy: .parallelWithLimit(limit: 1))) }
        defer { work.cancel() }
        var deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while store.allReceipts().isEmpty,
              ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let first = try #require(store.allReceipts().first)
        #expect(first.outcome == .failed(reason: "execution-failed"))
        // Give the parallel task group a bounded opportunity to dispatch B after
        // A's genuine outward terminal. B must remain behind A's actual call.
        for _ in 0..<100 {
            if await lifetime.names.contains("B") { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let namesBeforeExit = await lifetime.names
        let peakBeforeExit = await lifetime.peak
        print("TASK2935 beforeActualExit names=\(namesBeforeExit) peak=\(peakBeforeExit)")
        #expect(namesBeforeExit == ["A"], "parallel B cannot dispatch before actual A exits")
        #expect(peakBeforeExit == 1)
        if cancelQueued {
            await handle.interrupt()
            deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while await probe.reports == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(await probe.reports?.count == 2,
                    "parent cancellation must abandon B's local waiter before actual A exit")
            #expect(await probe.reports?.filter { $0.result.isSuccess }.count == 0)
            #expect(await lifetime.names == ["A"])
        }
        await lifetime.releaseA()
        deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await probe.reports == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let done = await probe.reports != nil
        #expect(done, "actual A exit must hand the local parallel permit to B")
        if !done { work.cancel() }
        await work.value
        let reports = try #require(await probe.reports)
        #expect(reports.count == 2)
        #expect(reports.filter { $0.result.isSuccess }.count == (cancelQueued ? 0 : 1))
        #expect(await lifetime.names == (cancelQueued ? ["A"] : ["A", "B"]))
        deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await lifetime.active != 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await lifetime.active == 0)
        #expect(await lifetime.peak == 1)
        #expect(Set(reports.map { $0.taskID }) == Set(["2935-A", "2935-B"]))
        #expect(store.receipt(runID: first.runID) == first,
                "late A response cannot overwrite its canonical timeout")
    }

}
