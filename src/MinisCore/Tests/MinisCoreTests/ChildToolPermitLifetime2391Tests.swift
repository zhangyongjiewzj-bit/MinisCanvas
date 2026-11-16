import Foundation
import Testing
@testable import MinisCore

private final class Tool2391Lifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    private var active = 0
    private var maximum = 0
    private var released = false
    private var held: CheckedContinuation<Void, Never>?
    func enter(_ name: String) { lock.withLock {
        entries.append(name); active += 1; maximum = max(maximum, active)
    } }
    func exit() { lock.withLock { active -= 1 } }
    func hold(_ name: String) async {
        guard name == "A" else { return }
        await withCheckedContinuation { continuation in
            lock.withLock {
                if released { continuation.resume() } else { held = continuation }
            }
        }
    }
    func releaseA() {
        let value = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true; let result = held; held = nil; return result
        }
        value?.resume()
    }
    var names: [String] { lock.withLock { entries } }
    var activeCount: Int { lock.withLock { active } }
    var peak: Int { lock.withLock { maximum } }
}

private final class Tool2391Executor: BuiltinOwnerBoundToolExecutor, @unchecked Sendable {
    let owner: BuiltinToolExecutor
    let name: String
    let lifetime: Tool2391Lifetime
    init(owner: BuiltinToolExecutor, name: String, lifetime: Tool2391Lifetime) {
        self.owner = owner; self.name = name; self.lifetime = lifetime
    }
    var currentBuiltinOwner: BuiltinToolExecutor? { owner }
    func executeBoundToBuiltinOwner(_ expectedOwner: BuiltinToolExecutor,
                                   name: String, input: [String: Any]) async throws -> String {
        guard owner === expectedOwner else { throw ToolExecutorError.resourceScopeInvalid }
        lifetime.enter(self.name)
        defer { lifetime.exit() }
        // Controlled suspension ignores cancellation. After release the real
        // bound builtin consumes only the owned synthetic file_read input.
        await lifetime.hold(self.name)
        return try await owner.executeBoundToBuiltinOwner(expectedOwner, name: name, input: input)
    }
    func execute(name: String, input: [String: Any]) async throws -> String {
        throw ToolExecutorError.resourceScopeInvalid
    }
}

private final class Tool2391Provider: LLMProvider {
    let name: String
    var model = LLMModel(id: "tool2391-model", displayName: "Owned", provider: "synthetic")
    var capabilities: Set<ProviderCapability> { [.tools, .streaming] }
    private let lock = NSLock()
    private var sends = 0
    let path: String
    init(name: String, path: String) { self.name = name; self.path = path }
    var callCount: Int { lock.withLock { sends } }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        let first = lock.withLock { sends += 1; return sends == 1 }
        if !first { return LLMResponse(text: "done", stopReason: "stop", usage: nil) }
        let data = try JSONSerialization.data(withJSONObject: ["tool_calls": [["id": "2391-" + name,
            "name": "file_read", "input": ["path": path]]]])
        return LLMResponse(text: String(decoding: data, as: UTF8.self), stopReason: "tool_use", usage: nil)
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
}
private actor Tool2391Reports {
    private(set) var reports: [SubAgentReport]?
    func record(_ reports: [SubAgentReport]) { self.reports = reports }
}

@Suite("CHILDD actual tool exit retains the existing child global permit", .serialized)
struct ChildToolPermitLifetime2391Tests {
    private func production(store: AgentTaskStore, ledger: ToolExecutionFactLedger,
                            governor: ChildConcurrencyGovernor, provider: Tool2391Provider,
                            executor: Tool2391Executor, budget: BudgetTracker,
                            handle: TurnController.TurnHandle, timeout: TimeInterval) -> AgentOrchestrator {
        let session = "2391-" + provider.name
        let parent = ParentRuntimeIdentity(sessionID: session, conversationID: session,
            turnID: "turn-handle:\(handle.turnID)", taskID: session + "-parent", actorID: "owned2391")
        return AgentOrchestrator(maxIterationsPerTask: 4, provider: provider, toolExecutor: executor,
            makeChildBudget: { budget }, childTimeout: timeout, currentConversationID: session,
            taskStore: store, toolExecutionFactLedger: ledger, parentID: parent.taskID,
            parentBinding: ParentContextSnapshotV1(providerID: provider.name, modelID: provider.model.id,
                configurationFingerprint: "2391-frozen", conversationID: session), parentRuntimeIdentity: parent,
            parentGoal: GoalEnvelope(scopeID: session + "-scope", allowedCapabilities: ["orchestrate", "file_read"],
                budget: 100, deadline: Date().addingTimeInterval(60), autonomyLevel: .l3),
            parentTurnHandle: handle, runtimeMode: .production,
            capabilityPolicy: AgentCapabilityPolicy(allowedCapabilities: [.streaming, .tools],
                allowedToolNames: ["file_read"], allowedMCPToolNames: []),
            parentCapabilities: [.streaming, .tools],
            parentFileAccessCeiling: ChildParentFileAccessCeiling(executor: executor.owner),
            concreteBuiltinToolExecutorOwner: executor.owner, childGovernor: governor)
    }

    @Test(arguments: [false, true])
    func outwardToolTerminalDoesNotReturnAnExecutingChildPermit(cancelParent: Bool) async throws {
        let formal = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = formal.rootDirectory.appendingPathComponent("tool2391-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileA = root.appendingPathComponent("A.txt"), fileB = root.appendingPathComponent("B.txt")
        try "owned A".write(to: fileA, atomically: true, encoding: .utf8)
        try "owned B".write(to: fileB, atomically: true, encoding: .utf8)
        let store = try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json"))
        let ledger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts.json"))
        let governor = ChildConcurrencyGovernor(policy: .init(globalHardCeiling: 1))
        let lifetime = Tool2391Lifetime()
        let controllerA = TurnController(), controllerB = TurnController()
        let handleA = await controllerA.beginTurn(), handleB = await controllerB.beginTurn()
        defer { lifetime.releaseA(); Task { await handleA.finish(); await handleB.finish() } }
        let owner = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        let providerA = Tool2391Provider(name: "A", path: fileA.path)
        let providerB = Tool2391Provider(name: "B", path: fileB.path)
        let budgetA = BudgetTracker(RequestBudget(maxRequestsPerSession: 4, overBudgetPolicy: .pause))
        let budgetB = BudgetTracker(RequestBudget(maxRequestsPerSession: 4, overBudgetPolicy: .pause))
        let a = production(store: store, ledger: ledger, governor: governor, provider: providerA,
            executor: Tool2391Executor(owner: owner, name: "A", lifetime: lifetime), budget: budgetA,
            handle: handleA, timeout: cancelParent ? 5 : 0.1)
        let b = production(store: store, ledger: ledger, governor: governor, provider: providerB,
            executor: Tool2391Executor(owner: owner, name: "B", lifetime: lifetime), budget: budgetB,
            handle: handleB, timeout: 5)
        let taskA = SubAgentTask(id: "A", title: "Held tool", instructions: "Read owned file",
            requiredCapabilities: [.tools], resourceRequest: SubAgentResourceRequest(
                allowedToolNames: ["file_read"], allowedReadRoots: [root.path]))
        let taskB = SubAgentTask(id: "B", title: "Next tool", instructions: "Read owned file",
            requiredCapabilities: [.tools], resourceRequest: SubAgentResourceRequest(
                allowedToolNames: ["file_read"], allowedReadRoots: [root.path]))
        let probeA = Tool2391Reports(), probeB = Tool2391Reports()
        let workA = Task { await probeA.record(a.orchestrate(tasks: [taskA], strategy: .parallelWithLimit(limit: 1))) }
        defer { workA.cancel() }
        var deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while lifetime.names.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(lifetime.names == ["A"], "valid bound actual tool must enter before testing its timeout/cancel")
        if cancelParent { await handleA.interrupt() }
        deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await probeA.reports == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let outwardA = try #require(await probeA.reports)
        #expect(outwardA.first?.result.isSuccess == false)
        let receiptA = try #require(store.allReceipts().first { $0.taskID == "A" })
        #expect(receiptA.outcome == (cancelParent ? .cancelled : .failed(reason: "execution-failed")))
        let factsA = ledger.facts
        #expect(factsA.count == 1 && factsA.first?.status != .succeeded)
        #expect(lifetime.activeCount == 1)
        let workB = Task { await probeB.record(b.orchestrate(tasks: [taskB], strategy: .sequential)) }
        defer { workB.cancel() }
        deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            let queued = await governor.checkpoint().queuedSessions
            if queued == ["2391-B-parent"] || providerB.callCount > 0 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let checkpoint = await governor.checkpoint()
        print("TASK2391 cancel=\(cancelParent) heldTool entries=\(lifetime.names) providerB=\(providerB.callCount) peak=\(lifetime.peak) active=\(checkpoint.globalActive) queue=\(checkpoint.queuedSessions)")
        #expect(checkpoint.globalActive == 1 && checkpoint.queuedSessions == ["2391-B-parent"])
        #expect(providerB.callCount == 0 && lifetime.names == ["A"])
        #expect(lifetime.peak == 1)
        lifetime.releaseA()
        await workA.value
        deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await probeB.reports == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let doneB = await probeB.reports != nil
        #expect(doneB)
        if !doneB { workB.cancel() }
        await workB.value
        #expect(await probeB.reports?.first?.result.isSuccess == true)
        #expect(lifetime.names == ["A", "B"] && lifetime.activeCount == 0)
        #expect(store.receipt(runID: receiptA.runID) == receiptA)
        #expect(ledger.facts.filter { factsA.contains($0) } == factsA)
        #expect(ledger.facts.contains { $0.status == .succeeded })
        #expect(await budgetA.budget.usedRequests == 1)
        #expect(await budgetB.budget.usedRequests == 2)
    }
}
