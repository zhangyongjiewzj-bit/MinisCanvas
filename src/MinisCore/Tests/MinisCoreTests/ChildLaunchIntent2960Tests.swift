import Foundation
import Testing
@testable import MinisCore

// A completion observer is unstructured: a deadline never joins an operation
// that ignores cancellation. Case cleanup separately releases its owned barrier.
private actor Intent2960Value<Value: Sendable> {
    var value: Value?
    func store(_ value: Value) { self.value = value }
}

private func intent2960Value<Value: Sendable>(
    _ task: Task<Value, Never>, phase: String
) async -> Value? {
    let box = Intent2960Value<Value>()
    Task { await box.store(await task.value) }
    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
    while ContinuousClock.now < deadline {
        if let value = await box.value { return value }
        try? await Task.sleep(for: .milliseconds(5))
    }
    task.cancel()
    Issue.record("TASK2960 fixture did not finish: \(phase) within 15s")
    return nil
}

private func releaseIntent2960Barrier(_ barrier: ConcurrentBarrier) {
    // Both arrivals are scheduled without awaiting the first. This also releases
    // cleanup when the provider never entered, and late provider arrivals pass.
    Task { await barrier.arrive() }
    Task { await barrier.arrive() }
}

@Suite("TASK2960 actual prequeue intent producer", .serialized)
struct ChildLaunchIntent2960Tests {
    private func paths() throws -> (URL, URL) {
        let formal = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = formal.rootDirectory.appendingPathComponent("intent2960-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root.appendingPathComponent("old.json"), root.appendingPathComponent("reopened.json"))
    }

    private func eventually(_ predicate: @escaping @Sendable () async -> Bool) async -> Bool {
        let polling = Task {
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while !Task.isCancelled && ContinuousClock.now < deadline {
                if await predicate() { return true }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return false
        }
        return await intent2960Value(polling, phase: "eventually predicate") ?? false
    }

    private func production(store: AgentTaskStore, governor: ChildConcurrencyGovernor,
                            provider: any LLMProvider, handle: TurnController.TurnHandle,
                            goal: GoalEnvelope, parentTaskID: String = "2960-parent",
                            fingerprint: String = "2960-frozen") -> AgentOrchestrator {
        let parent = ParentRuntimeIdentity(sessionID: "2960-session", conversationID: "2960-session",
            turnID: "turn-handle:\(handle.turnID)", taskID: parentTaskID, actorID: "2960-owner")
        return AgentOrchestrator(provider: provider, toolExecutor: NoopToolExecutor(),
            childTimeout: 10, currentConversationID: parent.conversationID, taskStore: store,
            parentID: parent.taskID,
            parentBinding: ParentContextSnapshotV1(providerID: provider.name, modelID: provider.model.id,
                configurationFingerprint: fingerprint, conversationID: parent.conversationID),
            parentRuntimeIdentity: parent, parentGoal: goal, parentTurnHandle: handle,
            runtimeMode: .production,
            capabilityPolicy: AgentCapabilityPolicy(allowedCapabilities: [.streaming],
                allowedToolNames: [], allowedMCPToolNames: []), parentCapabilities: [.streaming],
            childGovernor: governor)
    }

    private func goal() -> GoalEnvelope {
        GoalEnvelope(scopeID: "2960-root", allowedCapabilities: ["orchestrate"],
            budget: 100, deadline: Date().addingTimeInterval(60), autonomyLevel: .l3)
    }

    @Test("actual queued request reopens inert and links only a new active producer request, even when both turn counters are 1")
    func actualQueuedIntentAndFreshTurnCounterCollision() async throws {
        let (oldPath, reopenedPath) = try paths()
        let store = try AgentTaskStore(persistenceURL: oldPath)
        let governor = ChildConcurrencyGovernor(policy: .init(globalHardCeiling: 1))
        let barrier = ConcurrentBarrier(expected: 2), oldProbe = OrchestrationProbe()
        let controller = TurnController(), freshController = TurnController()
        let handle = await controller.beginTurn(), freshHandle = await freshController.beginTurn()
        let boundary = goal()
        let old = production(store: store, governor: governor,
            provider: ProbeLLMProvider(probe: oldProbe, barrier: barrier), handle: handle, goal: boundary)
        let holder = Task { await old.orchestrate(tasks: [SubAgentTask(id: "holder", title: "Held", instructions: "hold")]) }
        defer { holder.cancel(); releaseIntent2960Barrier(barrier); Task { await handle.finish(); await freshHandle.finish() } }
        let entered = await eventually { await oldProbe.maxActive == 1 }
        #expect(entered)
        guard entered else { return }
        let queuedTask = SubAgentTask(id: "waiting", title: "Queued", instructions: "synthetic bounded task",
            context: "original bounded context", expectedOutput: "done")
        let waiting = Task { await old.orchestrate(tasks: [queuedTask]) }
        defer { waiting.cancel() }
        #expect(await eventually {
            let checkpoint = await governor.checkpoint()
            return store.childLaunchIntents().contains { $0.intent.taskID == "waiting" && $0.status == .queued }
                && !checkpoint.queuedSessions.isEmpty
        })
        let queued = try #require(store.childLaunchIntents().first { $0.intent.taskID == "waiting" })
        #expect(queued.intent.runID == nil && queued.intent.attemptID == nil && queued.intent.executionID == nil)
        #expect(store.snapshot(taskID: "waiting", parentID: "2960-parent") == nil,
                "a waiting intent is not a fabricated dispatched task/run")
        let oldCheckpoint = await governor.checkpoint()
        try Data(contentsOf: oldPath).write(to: reopenedPath)
        await handle.interrupt()
        let release = Task { await barrier.arrive() }
        guard await intent2960Value(release, phase: "release held provider barrier") != nil else { return }
        guard await intent2960Value(waiting, phase: "waiting completion") != nil else { return }
        guard await intent2960Value(holder, phase: "holder completion") != nil else { return }
        #expect(await eventually { await governor.checkpoint().globalActive == 0 })

        let reopened = try AgentTaskStore(persistenceURL: reopenedPath)
        let recovered = try #require(reopened.childLaunchIntent(intentID: queued.intent.intentID))
        #expect(recovered == queued && recovered.task == queuedTask)
        #expect(handle.turnID == freshHandle.turnID, "real distinct controllers start at the same counter")
        let freshProbe = OrchestrationProbe()
        let freshGovernor = ChildConcurrencyGovernor.restored(
            from: oldCheckpoint, policy: .init(globalHardCeiling: 1))
        let currentGoal = goal()
        let fresh = production(store: reopened, governor: freshGovernor,
            provider: ProbeLLMProvider(probe: freshProbe), handle: freshHandle,
            goal: currentGoal, parentTaskID: "2960-fresh-parent")
        let freshRun = Task { await fresh.orchestrate(tasks: [queuedTask], strategy: .sequential) }
        guard let reports = await intent2960Value(freshRun, phase: "fresh queued recovery") else { return }
        #expect(reports.count == 1 && reports[0].result.isSuccess)
        #expect(await freshProbe.maxActive == 1)
        let linked = try #require(reopened.childLaunchIntents().first {
            $0.intent.recoveredFromIntentID == queued.intent.intentID
        })
        #expect(linked.intent.intentID != queued.intent.intentID)
        #expect(linked.intent.parent.taskID == "2960-fresh-parent")
        #expect(linked.intent.parent.taskID != queued.intent.parent.taskID)
        #expect(linked.intent.parent.sessionID == queued.intent.parent.sessionID)
        #expect(linked.intent.parent.conversationID == queued.intent.parent.conversationID)
        #expect(linked.intent.parent.actorID == queued.intent.parent.actorID)
        #expect(linked.intent.parent.turnID == queued.intent.parent.turnID)
        #expect(linked.parentGoal == currentGoal && linked.parentGoal != queued.parentGoal)
        #expect(reopened.snapshot(taskID: queuedTask.id, parentID: "2960-fresh-parent")?
            .childRuntimeIdentity?.parentGoalID == currentGoal.goalID)
        #expect(linked.status == .admitted)
        let runID = try #require(linked.intent.runID)
        #expect(linked.intent.attemptID == reopened.canonicalAttemptID(runID: runID))
        #expect(reopened.attempts(runID: runID).count == 1)
        #expect(reopened.receipt(runID: runID)?.outcome == .succeeded)
        let final = try AgentTaskStore(persistenceURL: reopenedPath)
        #expect(final.childLaunchIntent(intentID: linked.intent.intentID) == linked)
        #expect(final.childLaunchIntent(intentID: queued.intent.intentID) == queued)
        #expect(await eventually { await freshGovernor.checkpoint().globalActive == 0 })
    }

    @Test("a reopened admitted physical request cannot become a new effect, including a changed payload")
    func admittedUnknownEffectRefusesFreshRedispatch() async throws {
        let (oldPath, reopenedPath) = try paths()
        let store = try AgentTaskStore(persistenceURL: oldPath)
        let governor = ChildConcurrencyGovernor(policy: .init(globalHardCeiling: 1))
        let barrier = ConcurrentBarrier(expected: 2), oldProbe = OrchestrationProbe()
        let controller = TurnController(), freshController = TurnController()
        let handle = await controller.beginTurn(), freshHandle = await freshController.beginTurn()
        let boundary = goal()
        let old = production(store: store, governor: governor,
            provider: ProbeLLMProvider(probe: oldProbe, barrier: barrier), handle: handle, goal: boundary)
        let work = Task { await old.orchestrate(tasks: [SubAgentTask(id: "same-child", title: "Held", instructions: "hold")]) }
        defer { work.cancel(); releaseIntent2960Barrier(barrier); Task { await handle.finish(); await freshHandle.finish() } }
        let entered = await eventually { await oldProbe.maxActive == 1 }
        #expect(entered)
        guard entered else { return }
        let admitted = try #require(store.childLaunchIntents().first)
        #expect(admitted.status == .admitted && admitted.intent.runID != nil && admitted.intent.attemptID != nil)
        try Data(contentsOf: oldPath).write(to: reopenedPath)
        let release = Task { await barrier.arrive() }
        guard await intent2960Value(release, phase: "release held provider barrier") != nil else { return }
        guard await intent2960Value(work, phase: "work completion") != nil else { return }
        #expect(await eventually { await governor.checkpoint().globalActive == 0 })
        let original = try Data(contentsOf: reopenedPath)
        let reopened = try AgentTaskStore(persistenceURL: reopenedPath)
        let freshProbe = OrchestrationProbe()
        let freshGovernor = ChildConcurrencyGovernor(policy: .init(globalHardCeiling: 1))
        let fresh = production(store: reopened, governor: freshGovernor,
            provider: ProbeLLMProvider(probe: freshProbe), handle: freshHandle,
            goal: goal(), parentTaskID: "2960-fresh-parent")
        let freshRun = Task { await fresh.orchestrate(tasks: [SubAgentTask(id: "same-child", title: "Changed", instructions: "changed effect")]) }
        guard let reports = await intent2960Value(freshRun, phase: "admitted redispatch refusal") else { return }
        #expect(reports.count == 1 && reports[0].result.error == "CHILD_CHECKPOINT_UNAVAILABLE")
        #expect(await freshProbe.maxActive == 0)
        #expect(await freshGovernor.checkpoint().globalActive == 0)
        #expect(reopened.childLaunchIntents() == [admitted])
        #expect(try Data(contentsOf: reopenedPath) == original)
    }

    @Test("a real fresh request cannot consume queued work under a foreign context", arguments: [false, true])
    func foreignContextRefusesQueuedRecovery(changeProviderBinding: Bool) async throws {
        let (oldPath, reopenedPath) = try paths()
        let store = try AgentTaskStore(persistenceURL: oldPath)
        let governor = ChildConcurrencyGovernor(policy: .init(globalHardCeiling: 1))
        let barrier = ConcurrentBarrier(expected: 2), oldProbe = OrchestrationProbe()
        let controller = TurnController(), freshController = TurnController()
        let handle = await controller.beginTurn(), freshHandle = await freshController.beginTurn()
        let old = production(store: store, governor: governor,
            provider: ProbeLLMProvider(probe: oldProbe, barrier: barrier), handle: handle, goal: goal())
        let holder = Task { await old.orchestrate(tasks: [SubAgentTask(id: "holder", title: "Held", instructions: "hold")]) }
        defer { holder.cancel(); releaseIntent2960Barrier(barrier); Task { await handle.finish(); await freshHandle.finish() } }
        let entered = await eventually { await oldProbe.maxActive == 1 }
        #expect(entered)
        guard entered else { return }
        let task = SubAgentTask(id: "waiting", title: "Queued", instructions: "synthetic request", context: "original context")
        let waiting = Task { await old.orchestrate(tasks: [task]) }
        defer { waiting.cancel() }
        #expect(await eventually {
            let checkpoint = await governor.checkpoint()
            return !checkpoint.queuedSessions.isEmpty
                && store.childLaunchIntents().contains { $0.intent.taskID == task.id && $0.status == .queued }
        })
        let queued = try #require(store.childLaunchIntents().first { $0.intent.taskID == task.id })
        let checkpoint = await governor.checkpoint()
        try Data(contentsOf: oldPath).write(to: reopenedPath)
        await handle.interrupt()
        let release = Task { await barrier.arrive() }
        guard await intent2960Value(release, phase: "release held provider barrier") != nil else { return }
        guard await intent2960Value(holder, phase: "holder completion") != nil else { return }
        guard await intent2960Value(waiting, phase: "waiting completion") != nil else { return }
        #expect(await eventually { await governor.checkpoint().globalActive == 0 })
        let reopened = try AgentTaskStore(persistenceURL: reopenedPath)
        let originalBytes = try Data(contentsOf: reopenedPath)
        let before = reopened.childLaunchIntents()

        // Explicit decoded/foreign recovery claims cannot bypass the actual
        // producer. The original queued fact came from the real held workload.
        for foreign in ["session", "actor", "recoveredID"] {
            let parent = ParentRuntimeIdentity(
                sessionID: foreign == "session" ? "foreign-session" : queued.intent.parent.sessionID,
                conversationID: queued.intent.parent.conversationID,
                turnID: "turn-handle:\(freshHandle.turnID)", taskID: "2960-fresh-parent",
                actorID: foreign == "actor" ? "foreign-actor" : queued.intent.parent.actorID)
            let claim = ChildLaunchRequestIntent(intentID: UUID().uuidString, taskID: task.id,
                parent: parent, parentContextSnapshotID: queued.intent.parentContextSnapshotID,
                recoveredFromIntentID: foreign == "recoveredID" ? "foreign-intent" : queued.intent.intentID)
            #expect(throws: ChildLaunchIntentError.invalidIntent) {
                try reopened.recordChildLaunchIntent(claim, task: task,
                    parentBinding: queued.parentBinding, parentGoal: goal())
            }
        }
        #expect(reopened.childLaunchIntents() == before)
        #expect(try Data(contentsOf: reopenedPath) == originalBytes)

        let freshProbe = OrchestrationProbe()
        let freshGovernor = ChildConcurrencyGovernor.restored(from: checkpoint, policy: .init(globalHardCeiling: 1))
        let fresh = production(store: reopened, governor: freshGovernor,
            provider: ProbeLLMProvider(probe: freshProbe), handle: freshHandle,
            goal: goal(), parentTaskID: "2960-fresh-parent",
            fingerprint: changeProviderBinding ? "foreign-context-binding" : "2960-frozen")
        let changedTask = changeProviderBinding ? task : SubAgentTask(id: task.id, title: task.title,
            instructions: task.instructions, context: "foreign task context")
        let freshRun = Task { await fresh.orchestrate(tasks: [changedTask]) }
        guard let reports = await intent2960Value(freshRun, phase: "foreign-context recovery refusal") else { return }
        #expect(reports.count == 1 && reports[0].result.error == "CHILD_CHECKPOINT_UNAVAILABLE")
        #expect(await freshProbe.maxActive == 0)
        #expect(reopened.snapshot(taskID: task.id, parentID: "2960-fresh-parent") == nil)
        #expect(reopened.childLaunchIntents() == before)
        #expect(reopened.allReceipts().allSatisfy { $0.outcome != .succeeded })
        #expect(try Data(contentsOf: reopenedPath) == originalBytes)
    }

    @Test("the same actual queued intent is idempotent only with its exact current Goal")
    func sameIntentCannotReplaceCurrentGoal() async throws {
        let (path, _) = try paths()
        let store = try AgentTaskStore(persistenceURL: path)
        let governor = ChildConcurrencyGovernor(policy: .init(globalHardCeiling: 1))
        let barrier = ConcurrentBarrier(expected: 2), probe = OrchestrationProbe()
        let controller = TurnController(), handle = await controller.beginTurn()
        let currentGoal = goal()
        let producer = production(store: store, governor: governor,
            provider: ProbeLLMProvider(probe: probe, barrier: barrier),
            handle: handle, goal: currentGoal)
        let holder = Task { await producer.orchestrate(tasks: [SubAgentTask(id: "holder", title: "Held", instructions: "hold")]) }
        defer { holder.cancel(); releaseIntent2960Barrier(barrier); Task { await handle.finish() } }
        let entered = await eventually { await probe.maxActive == 1 }
        #expect(entered)
        guard entered else { return }
        let task = SubAgentTask(id: "waiting", title: "Queued", instructions: "synthetic bounded request")
        let waiting = Task { await producer.orchestrate(tasks: [task]) }
        defer { waiting.cancel() }
        #expect(await eventually {
            let checkpoint = await governor.checkpoint()
            return !checkpoint.queuedSessions.isEmpty
                && store.childLaunchIntents().contains { $0.intent.taskID == task.id && $0.status == .queued }
        })
        let queued = try #require(store.childLaunchIntents().first { $0.intent.taskID == task.id })
        #expect(queued.parentGoal == currentGoal)
        let bytes = try Data(contentsOf: path), records = store.childLaunchIntents()
        let replay = try store.recordChildLaunchIntent(queued.intent, task: queued.task,
            parentBinding: queued.parentBinding, parentGoal: currentGoal)
        #expect(replay == queued)
        let changedGoal = goal()
        #expect(changedGoal != currentGoal)
        #expect(throws: ChildLaunchIntentError.conflictingIntent) {
            try store.recordChildLaunchIntent(queued.intent, task: queued.task,
                parentBinding: queued.parentBinding, parentGoal: changedGoal)
        }
        #expect(store.childLaunchIntents() == records)
        #expect(try Data(contentsOf: path) == bytes)
        let reopened = try AgentTaskStore(persistenceURL: path)
        #expect(reopened.childLaunchIntent(intentID: queued.intent.intentID) == queued)
        #expect(reopened.childLaunchIntent(intentID: queued.intent.intentID)?.parentGoal == currentGoal)
        await handle.interrupt()
        let release = Task { await barrier.arrive() }
        guard await intent2960Value(release, phase: "release held provider barrier") != nil else { return }
        guard await intent2960Value(waiting, phase: "waiting completion") != nil else { return }
        guard await intent2960Value(holder, phase: "holder completion") != nil else { return }
        #expect(await eventually { await governor.checkpoint().globalActive == 0 })
    }

}
