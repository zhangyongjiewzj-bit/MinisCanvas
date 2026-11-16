import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private enum AppChildProviderFailure2441: Error { case controlled }

private actor AppChildGate2441 {
    private var arrivals = 0
    private var activeCalls = 0
    private var failedCalls = 0
    private var pending: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var released = false
    private var failAfterRelease = false

    var arrivalCount: Int { arrivals }
    var activeCallCount: Int { activeCalls }
    var failureCount: Int { failedCalls }

    func enter() async throws {
        let id = UUID()
        arrivals += 1
        activeCalls += 1
        defer { activeCalls -= 1 }
        if released {
            if failAfterRelease {
                failedCalls += 1
                throw AppChildProviderFailure2441.controlled
            }
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if released {
                    continuation.resume()
                } else {
                    pending[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        if failAfterRelease {
            failedCalls += 1
            throw AppChildProviderFailure2441.controlled
        }
    }

    func releaseAll(failing: Bool = false) {
        guard !released else { return }
        released = true
        failAfterRelease = failing
        let held = pending.values
        pending.removeAll()
        for item in held { item.resume() }
    }

    private func cancel(_ id: UUID) {
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

private final class AppControlledChildProvider2441: LLMProvider {
    let name = "controlled-app-child-2441"
    var model = LLMModel(
        id: "synthetic-2441", displayName: "synthetic-2441",
        provider: "controlled-app-child-2441"
    )
    var capabilities: Set<ProviderCapability> { [.streaming] }
    private let gate: AppChildGate2441

    init(gate: AppChildGate2441) { self.gate = gate }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        try await gate.enter()
        return LLMResponse(text: "TASK2441 synthetic completion", stopReason: nil, usage: nil)
    }

    func streamMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private enum AppChildToolFailure2441: Error { case unexpected }
private final class AppNoopChildTool2441: ToolExecutor {
    func execute(name: String, input: [String: Any]) async throws -> String {
        throw AppChildToolFailure2441.unexpected
    }
}

@Suite("TASK2441 App canonical four-session child budget", .serialized)
@MainActor
struct AppChildBudgetCanonical2441Tests {
    private func eventually(
        seconds: Int = 30,
        _ predicate: () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let until = clock.now.advanced(by: .seconds(seconds))
        while clock.now < until {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await predicate()
    }

    @Test("A/B/C/D fill 160 physical calls; cancel, failure and completion return owned budget",
          arguments: [false, true])
    func fourSessionsUseSharedAppGovernorAndCanonicalTaskCenter(failOneSession: Bool) async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "app-child2441", canvasRuntimeState: .disabled
        )
        let sessions = SessionStore(directory: profile.sessionDirectory)
        let store = try AgentTaskStore(persistenceURL: profile.agentTaskStorePersistenceURL)
        let bridge = BridgeStore(
            preferencesDefaults: profile.makeUserDefaults(),
            logManager: profile.makeLogManager(),
            sessionDocumentStore: SessionDocumentStore(directory: profile.sessionDirectory),
            sessionStore: sessions, canvasRuntimeState: .disabled,
            agentTaskStore: store, canvasFeatureLane: .phase3NonCanvas
        )
        let selection = try ChildConcurrencySelection(
            userSelected: 40, recommended: 40, effective: 40,
            enabledSessionCount: 4
        )
        await bridge.attachProductionServices(
            fileAccessAllowedRoot: profile.rootDirectory,
            sessionDirectory: profile.sessionDirectory,
            enableOrchestration: true,
            childConcurrencySelection: selection,
            canvasRuntimeState: .disabled,
            externalNetworkAllowed: false
        ).value
        let governor = try #require(bridge.orchestrationChildGovernor)
        #expect(bridge.childConcurrencySelection.userSelected == 40)
        #expect(bridge.childConcurrencySelection.effective == 40)
        #expect(await governor.globalBudget == 160)

        let labels = ["A", "B", "C", "D", "E"]
        let controllers = labels.map { _ in TurnController() }
        var acquiredTurns: [TurnController.TurnHandle] = []
        for controller in controllers {
            acquiredTurns.append(await controller.beginTurn())
        }
        let turns = acquiredTurns
        defer { Task { for turn in turns { await turn.finish() } } }
        let gates = labels.map { _ in AppChildGate2441() }
        var parents: [ChatSession] = []
        for label in labels {
            let parent = ChatSession(title: "TASK2441 \(label) parent")
            try sessions.updateSession(parent)
            parents.append(parent)
        }
        func makeOrchestrator(
            _ index: Int, turn: TurnController.TurnHandle
        ) -> AgentOrchestrator {
            let parent = parents[index]
            let provider = AppControlledChildProvider2441(gate: gates[index])
            return AgentOrchestrator(
                defaultMaxConcurrent: 40,
                childConcurrencySelection: bridge.childConcurrencySelection,
                provider: provider, toolExecutor: AppNoopChildTool2441(),
                currentConversationID: parent.id,
                taskStore: bridge.agentTaskStore, sessionStore: sessions,
                parentID: parent.id,
                parentBinding: ParentContextSnapshotV1(
                    providerID: provider.name, modelID: provider.model.id,
                    configurationFingerprint: "controlled-app-2441",
                    conversationID: parent.id
                ),
                parentRuntimeIdentity: ParentRuntimeIdentity(
                    sessionID: parent.id, conversationID: parent.id,
                    turnID: "turn-handle:\(turn.turnID)",
                    taskID: parent.id, actorID: "app-child-2441"
                ),
                parentGoal: GoalEnvelope(
                    scopeID: "app-child-2441-\(index)",
                    allowedCapabilities: ["orchestrate"], budget: 10_000,
                    deadline: Date().addingTimeInterval(600), autonomyLevel: .l3
                ),
                parentTurnHandle: turn, runtimeMode: .production,
                capabilityPolicy: AgentCapabilityPolicy(
                    allowedCapabilities: [.streaming],
                    allowedToolNames: [], allowedMCPToolNames: []
                ),
                parentCapabilities: [.streaming],
                childGovernor: governor
            )
        }
        func tasks(_ label: String, count: Int) -> [SubAgentTask] {
            (0..<count).map { item in
                SubAgentTask(
                    id: "2441-\(label)-\(item)", title: "\(label) child \(item)",
                    instructions: "synthetic controlled child"
                )
            }
        }
        let orchestrators = labels.indices.map { index in
            makeOrchestrator(index, turn: turns[index])
        }
        let runs = (0..<4).map { index in
            Task {
                await orchestrators[index].orchestrate(
                    tasks: tasks(labels[index], count: 40),
                    strategy: .parallelWithLimit(limit: 40)
                )
            }
        }
        defer {
            for run in runs { run.cancel() }
            Task {
                for turn in turns { await turn.revoke() }
                for gate in gates { await gate.releaseAll() }
            }
        }
        let filled = await eventually(seconds: 60) {
            for gate in gates.prefix(4) {
                if await gate.arrivalCount != 40 { return false }
            }
            return await governor.checkpoint().globalActive == 160
        }
        guard filled else {
            var arrivals: [Int] = []
            var activeCalls: [Int] = []
            for gate in gates.prefix(4) {
                arrivals.append(await gate.arrivalCount)
                activeCalls.append(await gate.activeCallCount)
            }
            let beforeCancel = await governor.checkpoint()
            let perSessionActive = parents.prefix(4).map {
                beforeCancel.perSessionActive[$0.id, default: 0]
            }
            // One failure-only observation, not an atomic cross-store snapshot.
            // Read before cancellation so cleanup cannot create these terminals.
            let beforeCancelTasks = store.taskCenterSnapshots()
            var taskStates: [[Int]] = [] // missing, queued, running, succeeded, failed, cancelled
            var boundChildTranscriptCounts: [Int] = []
            var attemptTimes: [[Double]] = [] // started/finished count, first/last epoch; -1 = absent
            for (index, parent) in parents.prefix(4).enumerated() {
                let expectedIDs = Set(tasks(labels[index], count: 40).map(\.id))
                let owned = beforeCancelTasks.filter { $0.parentID == parent.id && expectedIDs.contains($0.taskID) }
                var states = [40 - owned.count, 0, 0, 0, 0, 0]
                var boundChildTranscripts = 0
                var starts: [Double] = []
                var finishes: [Double] = []
                for snapshot in owned {
                    if snapshot.childTranscriptLocator != nil { boundChildTranscripts += 1 }
                    switch snapshot.status {
                    case .queued: states[1] += 1
                    case .running: states[2] += 1
                    case .succeeded: states[3] += 1
                    case .failed: states[4] += 1
                    case .cancelled: states[5] += 1
                    }
                    // Restrict reads to the original finite tasks, not another run.
                    guard let runID = store.controlSnapshot(taskID: snapshot.taskID, parentID: parent.id)?.runID else { continue }
                    for attempt in store.attempts(runID: runID) {
                        if let started = attempt.startedAt { starts.append(started.timeIntervalSince1970) }
                        if let finished = attempt.finishedAt { finishes.append(finished.timeIntervalSince1970) }
                    }
                }
                taskStates.append(states)
                boundChildTranscriptCounts.append(boundChildTranscripts)
                attemptTimes.append([Double(starts.count), Double(finishes.count),
                                     starts.min() ?? -1, starts.max() ?? -1,
                                     finishes.min() ?? -1, finishes.max() ?? -1])
            }
            for run in runs { run.cancel() }
            for turn in turns { await turn.revoke() }
            for gate in gates { await gate.releaseAll() }
            var succeededReports: [Int] = []
            var failedReports: [Int] = []
            for run in runs {
                var succeeded = 0
                var failed = 0
                for report in await run.value {
                    // The failure payload is arbitrary text, not a typed error
                    // code. Observe only the existing closed result cases.
                    switch report.result {
                    case .succeeded: succeeded += 1
                    case .failed: failed += 1
                    }
                }
                succeededReports.append(succeeded)
                failedReports.append(failed)
            }
            Issue.record("A/B/C/D provider arrivals did not fill the App governor; beforeCancel arrivals=\(arrivals) activeCalls=\(activeCalls) globalActive=\(beforeCancel.globalActive) perSessionActive=\(perSessionActive) queuedSessions=\(beforeCancel.queuedSessions.count) queuedRequests=\(beforeCancel.queuedRequests.count) localWaiting=\(beforeCancel.localWaitingRequests); beforeCancel taskStates[missing,queued,running,succeeded,failed,cancelled]=\(taskStates) boundChildTranscriptCounts=\(boundChildTranscriptCounts) attemptTimes[startedCount,finishedCount,firstStart,lastStart,firstFinish,lastFinish;epochSeconds;-1Absent]=\(attemptTimes); joinedAfterCancel succeeded=\(succeededReports) failed=\(failedReports)")
            return
        }
        let full = await governor.checkpoint()
        #expect(full.globalActive == 160)
        #expect(await governor.remainingBudget == 0)
        #expect(full.perSessionActive.values.filter { $0 == 40 }.count == 4)
        for gate in gates.prefix(4) { #expect(await gate.activeCallCount == 40) }
        let activeRows = bridge.taskCenterControlConsumer.receiptRows()
        #expect(activeRows.count == 160)
        #expect(activeRows.allSatisfy { $0.lifecycleState == .running })
        #expect(activeRows.allSatisfy { $0.childNavigation != nil })
        #expect(Set(activeRows.compactMap(\.sourceSessionID))
            == Set(parents.prefix(4).map(\.id)))

        let queued = Task {
            await orchestrators[4].orchestrate(
                tasks: tasks("E", count: 1), strategy: .sequential
            )
        }
        defer { queued.cancel() }
        let eQueued = await eventually {
            await governor.checkpoint().queuedSessions.contains(parents[4].id)
        }
        guard eQueued else {
            queued.cancel()
            for run in runs { run.cancel() }
            for turn in turns { await turn.revoke() }
            for gate in gates { await gate.releaseAll() }
            for run in runs { _ = await run.value }
            _ = await queued.value
            Issue.record("E did not enter the real shared governor queue")
            return
        }
        #expect(await gates[4].arrivalCount == 0)
        #expect(await governor.checkpoint().globalActive == 160)
        #expect(await governor.remainingBudget == 0)

        runs[0].cancel()
        await turns[0].revoke()
        let cancelled = await runs[0].value
        #expect(cancelled.count == 40)
        #expect(Set(cancelled.map(\.taskID)) == Set(tasks("A", count: 40).map(\.id)))
        #expect(await eventually { await gates[0].activeCallCount == 0 })
        let eAdmitted = await eventually {
            await gates[4].arrivalCount == 1
        }
        guard eAdmitted else {
            queued.cancel()
            for run in runs { run.cancel() }
            for turn in turns { await turn.revoke() }
            for gate in gates { await gate.releaseAll() }
            for run in runs { _ = await run.value }
            _ = await queued.value
            Issue.record("cancelled A did not admit E into the actual provider")
            return
        }
        let afterCancel = await governor.checkpoint()
        #expect(afterCancel.globalActive == 121)
        #expect(await governor.remainingBudget == 39)
        #expect(afterCancel.queuedSessions.isEmpty)
        let cancelledRows = bridge.taskCenterControlConsumer.receiptRows().filter {
            $0.parentID == parents[0].id
        }
        #expect(cancelledRows.count == 40)
        #expect(cancelledRows.allSatisfy { $0.lifecycleState == .cancelled })

        for (index, gate) in gates.enumerated() {
            await gate.releaseAll(failing: failOneSession && index == 1)
        }
        let remaining = await withTaskGroup(of: (Int, [SubAgentReport]).self) { group in
            for index in 1..<4 { group.addTask { (index, await runs[index].value) } }
            group.addTask { (4, await queued.value) }
            var result: [Int: [SubAgentReport]] = [:]
            for await (index, reports) in group { result[index] = reports }
            return result
        }
        #expect(remaining.count == 4)
        for index in 1...4 {
            let reports = try #require(remaining[index])
            #expect(reports.count == (index == 4 ? 1 : 40))
            let expectedTasks = tasks(labels[index], count: index == 4 ? 1 : 40)
            #expect(Set(reports.map(\.taskID)) == Set(expectedTasks.map(\.id)))
            #expect(reports.allSatisfy { $0.result.isSuccess == !(failOneSession && index == 1) })
            if failOneSession && index == 1 {
                #expect(reports.allSatisfy { $0.result.error != nil })
            }
        }
        #expect(await eventually {
            let checkpoint = await governor.checkpoint()
            return checkpoint.globalActive == 0 && checkpoint.queuedSessions.isEmpty
        })
        let drained = await governor.checkpoint()
        #expect(drained.globalActive == 0 && drained.queuedSessions.isEmpty)
        #expect(drained.perSessionActive.values.allSatisfy { $0 == 0 })
        #expect(await governor.remainingBudget == 160)
        for (index, gate) in gates.enumerated() {
            #expect(await gate.activeCallCount == 0)
            #expect(await gate.failureCount == (failOneSession && index == 1 ? 40 : 0))
        }

        await turns[0].finish()
        let retryTurn = await controllers[0].beginTurn()
        defer { Task { await retryTurn.finish() } }
        let retry = await makeOrchestrator(0, turn: retryTurn).orchestrate(
            tasks: [SubAgentTask(
                id: "2441-A-next-attempt", title: "A next attempt",
                instructions: "synthetic retry after permit return"
            )], strategy: .sequential
        )
        #expect(retry.count == 1 && retry[0].result.isSuccess)
        #expect(bridge.childConcurrencySelection.userSelected == 40)
        #expect(await governor.checkpoint().globalActive == 0)
        #expect(await governor.checkpoint().queuedSessions.isEmpty)
        #expect(await governor.remainingBudget == 160)
        let finalRows = bridge.taskCenterControlConsumer.receiptRows()
        #expect(finalRows.count == 162)
        #expect(Set(finalRows.map(\.stableID)).count == finalRows.count)
        #expect(Set(finalRows.map(\.receiptID)).count == finalRows.count)
        #expect(Set(finalRows.compactMap(\.childSessionID)).count == finalRows.count)
        let expectedTaskIDs = Set(labels.prefix(4).flatMap { tasks($0, count: 40).map(\.id) }
            + ["2441-E-0", "2441-A-next-attempt"])
        #expect(Set(finalRows.map(\.taskID)) == expectedTaskIDs)
        #expect(finalRows.filter { $0.lifecycleState == .completed }.count == (failOneSession ? 82 : 122))
        #expect(finalRows.filter { $0.lifecycleState == .failed }.count == (failOneSession ? 40 : 0))
        #expect(finalRows.filter { $0.lifecycleState == .cancelled }.count == 40)
        for (index, parent) in parents.enumerated() {
            let ownedRows = finalRows.filter { $0.parentID == parent.id }
            #expect(ownedRows.count == (index == 0 ? 41 : index == 4 ? 1 : 40))
            #expect(ownedRows.allSatisfy { $0.sourceSessionID == parent.id })
        }
        for row in finalRows {
            let navigation = try #require(row.childNavigation)
            let locator = try #require(navigation.locator)
            #expect(navigation.parentSessionID == row.parentID)
            #expect(navigation.taskID == row.taskID && locator.taskID == row.taskID)
            #expect(locator.runID == row.runID && locator.attemptID == row.attemptID)
            let child = try #require(sessions.loadSession(id: navigation.childSessionID))
            #expect(child.parentSessionID == row.parentID)
            #expect(child.createdByTaskID == row.taskID && child.createdByRunID == row.runID)
            #expect(child.messages.filter { $0.role == .user }.count == 1)
            let completions = child.messages.filter { $0.role == .assistant }
            #expect(completions.count == (row.lifecycleState == .completed ? 1 : 0))
            #expect(completions.allSatisfy { $0.content == "TASK2441 synthetic completion" })
            #expect(child.transcriptRevision == UInt64(child.messages.count))
        }
        for parent in parents {
            let saved = try #require(sessions.loadSession(id: parent.id))
            #expect(saved.messages.isEmpty)
        }
        #expect(await gates[0].arrivalCount == 41)
        #expect(await gates[0].activeCallCount == 0)
        #expect(finalRows.first(where: { $0.taskID == "2441-A-next-attempt" })?
            .succeededBacklink != nil)
    }
}
