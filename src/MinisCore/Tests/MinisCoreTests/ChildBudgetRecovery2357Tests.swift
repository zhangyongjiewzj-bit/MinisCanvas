import Foundation
import Testing
@testable import MinisCore

private actor ChildBudgetGate2357 {
    private var arrivals = 0
    private var waiting: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var open = false

    var arrivalCount: Int { arrivals }

    func enter() async throws {
        let id = UUID()
        arrivals += 1
        if open { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if open {
                    continuation.resume()
                } else {
                    waiting[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func releaseAll() {
        open = true
        let held = waiting.values
        waiting.removeAll()
        for continuation in held { continuation.resume() }
    }

    private func cancel(_ id: UUID) {
        waiting.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

private final class ControlledChildProvider2357: LLMProvider {
    let name = "ControlledChild2357"
    var model: LLMModel = .claudeHaiku45
    var capabilities: Set<ProviderCapability> { [.streaming] }
    private let gate: ChildBudgetGate2357

    init(gate: ChildBudgetGate2357) { self.gate = gate }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        try await gate.enter()
        return LLMResponse(text: "done", stopReason: nil, usage: nil)
    }

    func streamMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private final class NoopChildExecutor2357: ToolExecutor {
    func execute(name: String, input: [String: Any]) async throws -> String { "ok" }
}

private enum ChildCheckpointWriteFailure3065: Error { case unavailable }

private actor ChildCheckpointRecorder3065 {
    private var value: ChildConcurrencyCheckpoint?
    func append(_ checkpoint: ChildConcurrencyCheckpoint) { value = checkpoint }
    func latest() -> ChildConcurrencyCheckpoint? { value }
}

@Suite("D-CHILDE real orchestrator budget recovery", .serialized)
struct ChildBudgetRecovery2357Tests {
    private func holdForResourceSampling(_ phase: String, active: Int,
                                         milliseconds: Int = 1200) async throws {
        guard let path = ProcessInfo.processInfo.environment["CHILDE_RESOURCE_PHASE_FILE"] else {
            return
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let line = "pid=\(pid) phase=\(phase) active=\(active) epoch=\(Date().timeIntervalSince1970)\n"
        try Data(line.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        try await Task.sleep(for: .milliseconds(milliseconds))
    }

    private func makeStore(_ label: String) throws -> AgentTaskStore {
        let formal = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = formal.rootDirectory.appendingPathComponent(
            "child2357-\(label)-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        return try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json"))
    }

    private func eventually(
        seconds: Int = 15, _ predicate: () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(seconds))
        while clock.now < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await predicate()
    }

    private func makeOrchestrator(
        session: Int, sessions: Int, gate: ChildBudgetGate2357,
        governor: ChildConcurrencyGovernor, store: AgentTaskStore,
        handle: TurnController.TurnHandle, selected: Int = 40
    ) throws -> AgentOrchestrator {
        let selection = try ChildConcurrencySelection(
            userSelected: selected, recommended: selected, effective: selected,
            enabledSessionCount: sessions
        )
        let provider = ControlledChildProvider2357(gate: gate)
        let name = "2357-session-\(session)"
        let parent = ParentRuntimeIdentity(
            sessionID: name, conversationID: name,
            turnID: "turn-handle:\(handle.turnID)",
            taskID: name, actorID: "controlled2357"
        )
        return AgentOrchestrator(
            defaultMaxConcurrent: selected,
            childConcurrencySelection: selection,
            provider: provider,
            toolExecutor: NoopChildExecutor2357(),
            currentConversationID: name,
            taskStore: store,
            parentID: name,
            parentBinding: ParentContextSnapshotV1(
                providerID: provider.name, modelID: provider.model.id,
                configurationFingerprint: "controlled2357-frozen",
                conversationID: name
            ),
            parentRuntimeIdentity: parent,
            parentGoal: GoalEnvelope(
                scopeID: name + "-scope", allowedCapabilities: ["orchestrate"],
                budget: 10_000, deadline: Date().addingTimeInterval(600),
                autonomyLevel: .l3
            ),
            parentTurnHandle: handle,
            runtimeMode: .production,
            capabilityPolicy: AgentCapabilityPolicy(
                allowedCapabilities: [.streaming], allowedToolNames: [],
                allowedMCPToolNames: []
            ),
            parentCapabilities: [.streaming],
            childGovernor: governor
        )
    }

    private func tasks(session: Int, round: Int) -> [SubAgentTask] {
        (0..<40).map { index in
            SubAgentTask(
                id: "2357-s\(session)-r\(round)-\(index)",
                title: "controlled child", instructions: "synthetic completion"
            )
        }
    }

    @Test("single-session staircase respects every selected limit and recovers it")
    func singleSessionStaircase() async throws {
        let store = try makeStore("staircase")
        let controller = TurnController()
        let handle = await controller.beginTurn()
        defer { Task { await handle.finish() } }
        for selected in [1, 2, 4, 8, 16, 24, 32, 40] {
            let governor = ChildConcurrencyGovernor(
                policy: .init(globalHardCeiling: 40)
            )
            let gate = ChildBudgetGate2357()
            let orchestrator = try makeOrchestrator(
                session: 0, sessions: 1, gate: gate,
                governor: governor, store: store, handle: handle,
                selected: selected
            )
            let run = Task {
                await orchestrator.orchestrate(
                    tasks: Array(tasks(session: 0, round: selected).prefix(selected)),
                    strategy: .parallelWithLimit(limit: 40)
                )
            }
            let entered = await eventually {
                await gate.arrivalCount == selected
            }
            let mid = await governor.checkpoint()
            if !entered { await governor.engageKillSwitch() }
            if entered {
                try await holdForResourceSampling("single-\(selected)", active: mid.globalActive)
            }
            await gate.releaseAll()
            let reports = await run.value
            #expect(entered, "staircase step \(selected) never reached the provider")
            #expect(mid.globalActive == selected)
            #expect(mid.perSessionActive["2357-session-0"] == selected)
            #expect(reports.count == selected)
            let allSucceeded = reports.allSatisfy { $0.result.isSuccess }
            #expect(allSucceeded)
            #expect(await eventually { await governor.checkpoint().globalActive == 0 })
            try await holdForResourceSampling("single-\(selected)-released", active: 0,
                                              milliseconds: 800)
        }
    }

    @Test("selected 24 holds the 25th physical provider call at the local gate, then admits it")
    func selectedTwentyFourBoundsActualProviderEntry() async throws {
        let store = try makeStore("selected-24-local")
        let controller = TurnController()
        let handle = await controller.beginTurn()
        defer { Task { await handle.finish() } }
        let governor = ChildConcurrencyGovernor(policy: .init(globalHardCeiling: 40))
        let gate = ChildBudgetGate2357()
        let orchestrator = try makeOrchestrator(
            session: 0, sessions: 1, gate: gate,
            governor: governor, store: store, handle: handle,
            selected: 24
        )
        let run = Task {
            await orchestrator.orchestrate(
                tasks: Array(tasks(session: 0, round: 24).prefix(25)),
                strategy: .parallelWithLimit(limit: 40)
            )
        }
        let localFull = await eventually {
            let checkpoint = await governor.checkpoint()
            let providerEntries = await gate.arrivalCount
            return checkpoint.globalActive == 25 && providerEntries == 24
        }
        let entriesBeforeRelease = await gate.arrivalCount
        let checkpointBeforeRelease = await governor.checkpoint()
        var fillFailureEvidence = ""
        if !localFull {
            // One finite pre-release observation; Store and governor are not an atomic snapshot.
            let expectedIDs = Set(tasks(session: 0, round: 24).prefix(25).map(\.id))
            let owned = store.taskCenterSnapshots().filter {
                $0.parentID == "2357-session-0" && expectedIDs.contains($0.taskID)
            }
            var states = [25 - owned.count, 0, 0, 0, 0, 0]
            for task in owned {
                switch task.status {
                case .queued: states[1] += 1
                case .running: states[2] += 1
                case .succeeded: states[3] += 1
                case .failed: states[4] += 1
                case .cancelled: states[5] += 1
                }
            }
            fillFailureEvidence = "; beforeRelease globalActive=\(checkpointBeforeRelease.globalActive) perSessionActive=\(checkpointBeforeRelease.perSessionActive["2357-session-0", default: 0]) localWaiting=\(checkpointBeforeRelease.localWaitingRequests) queuedRequests=\(checkpointBeforeRelease.queuedRequests.count) providerEntries=\(entriesBeforeRelease) taskStates[missing,queued,running,succeeded,failed,cancelled]=\(states)"
        }
        await gate.releaseAll()
        let reports = await run.value
        #expect(localFull, Comment(rawValue: "the 25th child should hold a global grant while waiting at the selected local limit" + fillFailureEvidence))
        #expect(entriesBeforeRelease == 24, "local selection must bound actual provider entry")
        #expect(checkpointBeforeRelease.globalActive == 25)
        #expect(reports.count == 25 && reports.allSatisfy { $0.result.isSuccess })
        #expect(await gate.arrivalCount == 25, "the waiting child must enter after local capacity returns")
        #expect(await eventually { await governor.checkpoint().globalActive == 0 })
    }

    @Test("2x40, 3x40 and 4x40 grants return after real provider completion, then admit the next round")
    func completeAndReuseEveryBudget() async throws {
        let controller = TurnController()
        let handle = await controller.beginTurn()
        defer { Task { await handle.finish() } }
        for sessions in [2, 3, 4] {
            let capacity = sessions * 40
            let governor = ChildConcurrencyGovernor(
                policy: .init(globalHardCeiling: capacity)
            )
            // Each round drives the production orchestration path, with all
            // provider calls held until the authority reports N distinct
            // sessions and exactly 40 live children per session.
            for round in 0..<2 {
                let store = try makeStore("multisession-\(sessions)-\(round)")
                let gates = (0..<sessions).map { _ in ChildBudgetGate2357() }
                let active = try (0..<sessions).map { session in
                    try makeOrchestrator(session: session, sessions: sessions,
                                         gate: gates[session], governor: governor,
                                         store: store, handle: handle)
                }
                let runs = (0..<sessions).map { session in
                    Task {
                        await active[session].orchestrate(
                            tasks: tasks(session: session,
                                         round: sessions * 10 + round),
                            strategy: .parallelWithLimit(limit: 40)
                        )
                    }
                }
                let entered = await eventually(seconds: 60) {
                    for gate in gates {
                        if await gate.arrivalCount != 40 { return false }
                    }
                    return true
                }
                let mid = await governor.checkpoint()
                if !entered { await governor.engageKillSwitch() }
                if entered {
                    try await holdForResourceSampling("multi-\(sessions)x40-round-\(round)",
                                                      active: mid.globalActive)
                }
                for gate in gates { await gate.releaseAll() }
                let reports = await withTaskGroup(of: [SubAgentReport].self) { group in
                    for run in runs { group.addTask { await run.value } }
                    var all: [[SubAgentReport]] = []
                    for await result in group { all.append(result) }
                    return all
                }
                #expect(entered, "\(sessions)x40 round \(round) did not reach all providers")
                #expect(mid.globalActive == capacity)
                #expect(mid.queuedSessions.isEmpty)
                #expect(mid.perSessionActive.count == sessions)
                for session in 0..<sessions {
                    #expect(mid.perSessionActive["2357-session-\(session)"] == 40)
                }
                #expect(reports.count == sessions)
                let allSucceeded = reports.allSatisfy { sessionReports in
                    sessionReports.count == 40
                        && sessionReports.allSatisfy { $0.result.isSuccess }
                }
                #expect(allSucceeded)
                #expect(await eventually { await governor.checkpoint().globalActive == 0 },
                        "\(sessions)x40 round \(round) did not return all permits")
                let after = await governor.checkpoint()
                let allReleased = after.perSessionActive.values.allSatisfy { $0 == 0 }
                #expect(allReleased)
                #expect(after.queuedSessions.isEmpty)
                try await holdForResourceSampling("multi-\(sessions)x40-round-\(round)-released",
                                                  active: after.globalActive,
                                                  milliseconds: 800)
                if !entered { break }
            }
        }
    }

    @Test("cancelling forty held children returns their grants while another session completes")
    func cancellationReleasesOneSession() async throws {
        let store = try makeStore("cancel")
        let controller = TurnController()
        let handle = await controller.beginTurn()
        defer { Task { await handle.finish() } }
        let governor = ChildConcurrencyGovernor(policy: .init(globalHardCeiling: 80))
        let cancelledGate = ChildBudgetGate2357()
        let completedGate = ChildBudgetGate2357()
        let cancelled = try makeOrchestrator(
            session: 0, sessions: 2, gate: cancelledGate,
            governor: governor, store: store, handle: handle
        )
        let completed = try makeOrchestrator(
            session: 1, sessions: 2, gate: completedGate,
            governor: governor, store: store, handle: handle
        )
        let cancelledRun = Task {
            await cancelled.orchestrate(tasks: tasks(session: 0, round: 2),
                                         strategy: .parallelWithLimit(limit: 40))
        }
        let completedRun = Task {
            await completed.orchestrate(tasks: tasks(session: 1, round: 2),
                                         strategy: .parallelWithLimit(limit: 40))
        }
        let entered = await eventually(seconds: 25) {
            let cancelledArrivals = await cancelledGate.arrivalCount
            let completedArrivals = await completedGate.arrivalCount
            return cancelledArrivals == 40 && completedArrivals == 40
        }
        let mid = await governor.checkpoint()
        if entered {
            try await holdForResourceSampling("cancel-2x40", active: mid.globalActive)
        }
        cancelledRun.cancel()
        if !entered { completedRun.cancel() }
        // Release both gates even after a failed arrival assertion, so a RED
        // never leaves a provider parked indefinitely.
        await cancelledGate.releaseAll()
        await completedGate.releaseAll()
        let cancelledReports = await cancelledRun.value
        let completedReports = await completedRun.value
        #expect(entered)
        #expect(mid.globalActive == 80)
        #expect(cancelledReports.count == 40)
        #expect(completedReports.count == 40)
        let completedSessionSucceeded = completedReports.allSatisfy { $0.result.isSuccess }
        #expect(completedSessionSucceeded)
        #expect(await eventually { await governor.checkpoint().globalActive == 0 })
        let after = await governor.checkpoint()
        let allReleased = after.perSessionActive.values.allSatisfy { $0 == 0 }
        #expect(allReleased)
        try await holdForResourceSampling("cancel-2x40-released", active: after.globalActive,
                                          milliseconds: 800)
    }

    @Test("restored checkpoint blocks the real consumer until resume, then returns its permit")
    func restoredPolicyControlsActualLaunch() async throws {
        let store = try makeStore("restore")
        let controller = TurnController()
        let handle = await controller.beginTurn()
        defer { Task { await handle.finish() } }
        let original = ChildConcurrencyGovernor(policy: .init(globalHardCeiling: 1))
        await original.engageKillSwitch()
        let encoded = try JSONEncoder().encode(await original.checkpoint())
        let decoded = try JSONDecoder().decode(
            ChildConcurrencyCheckpoint.self, from: encoded
        )
        let restored = ChildConcurrencyGovernor.restored(
            from: decoded, policy: .init(globalHardCeiling: 1)
        )
        let gate = ChildBudgetGate2357()
        let orchestrator = try makeOrchestrator(
            session: 0, sessions: 2, gate: gate,
            governor: restored, store: store, handle: handle
        )
        let task = tasks(session: 0, round: 3)[0]
        let blocked = await orchestrator.orchestrate(
            tasks: [task], strategy: .sequential
        )
        #expect(blocked.count == 1)
        #expect(blocked[0].result.error == "GLOBAL_CHILD_BUDGET_KILL_SWITCH")
        #expect(await gate.arrivalCount == 0)
        #expect(await restored.checkpoint().globalActive == 0)

        await restored.liftKillSwitch()
        let resumed = Task {
            await orchestrator.orchestrate(tasks: [task], strategy: .sequential)
        }
        let entered = await eventually { await gate.arrivalCount == 1 }
        let mid = await restored.checkpoint()
        await gate.releaseAll()
        let reports = await resumed.value
        #expect(entered)
        #expect(mid.globalActive == 1)
        #expect(reports.count == 1 && reports[0].result.isSuccess)
        #expect(await restored.checkpoint().globalActive == 0)
    }

    @Test("failed admission checkpoint reports the returned budget and never enters the provider")
    func failedImmediateCheckpointPublishesReturnedBudget3065() async throws {
        let store = try makeStore("3065-admission-write-failure")
        let controller = TurnController()
        let handle = await controller.beginTurn()
        defer { Task { await handle.finish() } }
        let governor = ChildConcurrencyGovernor(
            policy: .init(globalHardCeiling: 1),
            checkpointPersistence: { _ in throw ChildCheckpointWriteFailure3065.unavailable }
        )
        let stream = await governor.checkpointUpdates()
        let recorder = ChildCheckpointRecorder3065()
        let observation = Task {
            for await value in stream { await recorder.append(value) }
        }
        defer { observation.cancel() }
        #expect(await eventually { await recorder.latest()?.globalActive == 0 })
        let gate = ChildBudgetGate2357()
        let orchestrator = try makeOrchestrator(
            session: 0, sessions: 1, gate: gate, governor: governor,
            store: store, handle: handle, selected: 1
        )
        let reports = await orchestrator.orchestrate(
            tasks: [tasks(session: 0, round: 30650)[0]], strategy: .sequential
        )
        #expect(reports.count == 1)
        #expect(reports.first?.result.error == "CHILD_CHECKPOINT_UNAVAILABLE")
        #expect(await gate.arrivalCount == 0)
        let completed = await governor.checkpoint()
        #expect(completed.globalActive == 0)
        #expect(completed.activeRequests.isEmpty)
        #expect(completed.localWaitingRequests == 0)
        #expect(await governor.remainingBudget == 1)
        #expect(await eventually { await recorder.latest() == completed },
                "the production checkpoint stream must publish the rolled-back admission, not its provisional grant")
        let retry = await orchestrator.orchestrate(
            tasks: [tasks(session: 0, round: 30651)[0]], strategy: .sequential
        )
        #expect(retry.first?.result.error == "CHILD_CHECKPOINT_UNAVAILABLE")
        #expect(await gate.arrivalCount == 0)
    }

    @Test("failed queue checkpoint removes only refused work and reports the live holder exactly")
    func failedQueuedCheckpointPublishesDrainedQueue3065() async throws {
        let store = try makeStore("3065-queue-write-failure")
        let controller = TurnController()
        let handle = await controller.beginTurn()
        defer { Task { await handle.finish() } }
        let governor = ChildConcurrencyGovernor(
            policy: .init(globalHardCeiling: 1),
            checkpointPersistence: { snapshot in
                if !snapshot.queuedRequests.isEmpty {
                    throw ChildCheckpointWriteFailure3065.unavailable
                }
            }
        )
        let stream = await governor.checkpointUpdates()
        let recorder = ChildCheckpointRecorder3065()
        let observation = Task {
            for await value in stream { await recorder.append(value) }
        }
        defer { observation.cancel() }
        let holderGate = ChildBudgetGate2357()
        let refusedGate = ChildBudgetGate2357()
        let holder = try makeOrchestrator(
            session: 0, sessions: 2, gate: holderGate, governor: governor,
            store: store, handle: handle, selected: 1
        )
        let refused = try makeOrchestrator(
            session: 1, sessions: 2, gate: refusedGate, governor: governor,
            store: store, handle: handle, selected: 1
        )
        let running = Task {
            await holder.orchestrate(
                tasks: [tasks(session: 0, round: 30652)[0]], strategy: .sequential
            )
        }
        defer {
            running.cancel()
            Task { await holderGate.releaseAll() }
        }
        let entered = await eventually { await holderGate.arrivalCount == 1 }
        #expect(entered)
        #expect(await eventually { await recorder.latest()?.globalActive == 1 })
        let reports = await refused.orchestrate(
            tasks: [tasks(session: 1, round: 30652)[0]], strategy: .sequential
        )
        #expect(reports.count == 1)
        #expect(reports.first?.result.error == "CHILD_CHECKPOINT_UNAVAILABLE")
        #expect(await refusedGate.arrivalCount == 0)
        let completed = await governor.checkpoint()
        #expect(completed.globalActive == 1)
        #expect(completed.activeRequests.count == 1)
        #expect(completed.queuedRequests.isEmpty && completed.queuedSessions.isEmpty)
        #expect(await governor.remainingBudget == 0)
        #expect(await eventually { await recorder.latest() == completed },
                "the production checkpoint stream must not retain the refused queue entry")
        await holderGate.releaseAll()
        let holderReports = await running.value
        #expect(holderReports.count == 1 && holderReports[0].result.isSuccess)
        #expect(await eventually { await governor.checkpoint().globalActive == 0 })
        let released = await governor.checkpoint()
        #expect(await eventually { await recorder.latest() == released })
        #expect(await governor.remainingBudget == 1)
    }
}
