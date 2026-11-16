import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Task Center deadline and retry consumers (546)")
struct TaskCenterStateAttempt546ConsumerTests {
    @Test func productionDeadlineReceiptIsDistinctFromFailureAndLeaseExpiry() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = root.appendingPathComponent("tasks.json")
        let store = try AgentTaskStore(persistenceURL: ledger)
        let controller = TurnController()
        let turn = await controller.beginTurn()
        defer { Task { await turn.finish() } }
        let provider = Task546UnusedProvider()
        let owner = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        let orchestrator = AgentOrchestrator(
            provider: provider, toolExecutor: owner,
            deadline: Date(timeIntervalSince1970: 1),
            currentConversationID: "conversation546", taskStore: store,
            parentID: "parent546",
            parentBinding: ParentContextSnapshotV1(
                providerID: provider.name, modelID: provider.model.id,
                configurationFingerprint: "fixture546", conversationID: "conversation546"),
            parentRuntimeIdentity: ParentRuntimeIdentity(
                sessionID: "session546", conversationID: "conversation546",
                turnID: "turn-handle:\(turn.turnID)", taskID: "parent546", actorID: "fixture546"),
            parentTurnHandle: turn, runtimeMode: .production,
            capabilityPolicy: AgentCapabilityPolicy(allowedCapabilities: [.streaming]),
            parentCapabilities: [.streaming],
            parentFileAccessCeiling: ChildParentFileAccessCeiling(executor: owner),
            concreteBuiltinToolExecutorOwner: owner)
        let reports = await orchestrator.orchestrate(
            tasks: [SubAgentTask(id: "expired546", title: "expired546", instructions: "synthetic")],
            strategy: .sequential)
        #expect(reports.first?.result == .failed(error: "DEADLINE_EXCEEDED"))
        let receipt = try #require(store.allReceipts().first)
        #expect(receipt.outcome == .failed(reason: "execution-failed"))
        #expect(receipt.childResultEnvelope?.outcome == .failed(reason: "DEADLINE_EXCEEDED"))
        let consumer = makeConsumer(store)
        let row = try #require(consumer.receiptRows(now: now).first)
        #expect(row.runID == receipt.runID)
        #expect(row.attemptID == receipt.attemptID)
        #expect(row.lifecycleState == .failed)
        #expect(row.isDeadlineExpired)
        #expect(row.statusTitle == "已过期")
        #expect(row.currentStepTitle == "已过期")
        #expect(row.resultSummaryTitle == "已过期")
        #expect(row.accessibilityLabel.contains("Task 状态 已过期"))
        #expect(row.retryAvailable)
        #expect(row.succeededBacklink == nil)
        let fact = try #require(consumer.project(now: now).fact(taskID: row.taskID, parentID: row.parentID))
        #expect(fact.status == .failed)
        #expect(fact.leaseState == .active)
        let reloaded = try AgentTaskStore(persistenceURL: ledger)
        #expect(reloaded.receipt(runID: receipt.runID) == receipt)
        let restored = try #require(makeConsumer(reloaded).receiptRows(now: now).first)
        #expect(restored.isDeadlineExpired)
        #expect(restored.statusTitle == row.statusTitle)
        #expect(restored.observationIdentity == row.observationIdentity)
    }

    @Test func onlyExactExecutionDeadlineCauseChangesTheTaskPresentation() throws {
        let store = AgentTaskStore()
        let outcomes: [(String, AgentTaskOutcome)] = [
            ("ordinary546", .failed(reason: "private error")),
            ("similar546", .failed(reason: "prefix DEADLINE_EXCEEDED suffix")),
            ("lowercase546", .failed(reason: "deadline_exceeded")),
            ("success546", .succeeded), ("cancel546", .cancelled)]
        for (id, outcome) in outcomes {
            let task = try store.enqueue(taskID: id, parentID: "parent546", providerID: "offline", modelID: "test")
            let run = try store.startRun(taskID: id, parentID: task.parentID, runID: "run-" + id)
            _ = try store.settleChildResult(envelope(task, runID: run.runID, outcome: outcome))
        }
        let consumer = makeConsumer(store, expiresAt: now.addingTimeInterval(-1))
        let rows = consumer.receiptRows(now: now)
        #expect(rows.count == outcomes.count)
        for row in rows {
            #expect(!row.isDeadlineExpired)
            let fact = try #require(consumer.project(now: now).fact(taskID: row.taskID, parentID: row.parentID))
            #expect(fact.leaseState == .expired)
            switch row.taskID {
            case "success546":
                #expect(row.statusTitle == "已完成")
                #expect(row.childResultEnvelope?.outcome == .succeeded)
            case "cancel546": #expect(row.statusTitle == "已取消")
            default: #expect(row.statusTitle == "失败")
            }
        }
        let unbound = TaskCenterControlConsumer(store: store)
        #expect(unbound.project(now: now).tasks.allSatisfy { !$0.isGoalBound && $0.leaseState == .invalid })
        #expect(unbound.receiptRows(now: now).allSatisfy { !$0.isDeadlineExpired })
    }

    @Test func appRetryFencesLateChildAndRestoresOnlyTheNewAttemptResult() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = root.appendingPathComponent("tasks.json")
        let store = try AgentTaskStore(persistenceURL: ledger)
        let task = try store.enqueue(taskID: "retry546", parentID: "parent546", providerID: "offline", modelID: "test")
        let oldRun = try store.startRun(taskID: task.taskID, parentID: task.parentID, runID: "old546")
        let failed = try store.settleChildResult(envelope(task, runID: oldRun.runID, outcome: .failed(reason: "synthetic")))
        let foreignTask = try store.enqueue(taskID: task.taskID, parentID: "foreign546", providerID: "offline", modelID: "test")
        let foreignRun = try store.startRun(taskID: foreignTask.taskID, parentID: foreignTask.parentID, runID: "foreign-run546")
        let foreignBefore = store.snapshot(taskID: foreignTask.taskID, parentID: foreignTask.parentID)
        let consumer = makeConsumer(store)
        let fact = try #require(consumer.project(now: now).fact(taskID: task.taskID, parentID: task.parentID))
        let request = TaskCenterControlRequest(taskID: task.taskID, parentID: task.parentID,
            revision: fact.revision, scopeID: try #require(fact.scopeID), actorID: "fixture546",
            idempotencyKey: "retry546-key", action: .retry, runID: oldRun.runID)
        let retried = try consumer.execute(request, now: now)
        let newRun = try #require(retried.resultingRunID)
        let newAttempt = try #require(store.canonicalAttemptID(runID: newRun))
        #expect(newRun != oldRun.runID)
        #expect(newAttempt != failed.attemptID)
        let running = try #require(consumer.receiptRows(now: now).first { $0.parentID == task.parentID })
        #expect(running.runID == newRun)
        #expect(running.attemptID == newAttempt)
        #expect(running.lifecycleState == .retrying)
        #expect(running.childResultEnvelope == nil)
        let eventsBefore = store.events(runID: newRun)
        let receiptsBefore = store.allReceipts()
        // A complete old identity is terminal payload drift, not a foreign attempt.
        let terminalPayloadDrift = envelope(task, runID: oldRun.runID, outcome: .failed(reason: "DEADLINE_EXCEEDED"))
        #expect(throws: AgentTaskStoreError.childResultIdempotencyConflict) { _ = try store.settleChildResult(terminalPayloadDrift) }
        let late = envelope(task, runID: oldRun.runID, outcome: .failed(reason: "DEADLINE_EXCEEDED"), attemptID: newAttempt)
        #expect(throws: AgentTaskStoreError.childResultIdentityMismatch) { _ = try store.settleChildResult(late) }
        #expect(try store.finish(runID: oldRun.runID, outcome: .succeeded) == failed)
        let wrongAttempt = envelope(task, runID: newRun, outcome: .failed(reason: "DEADLINE_EXCEEDED"), attemptID: failed.attemptID)
        #expect(throws: AgentTaskStoreError.childResultIdentityMismatch) { _ = try store.settleChildResult(wrongAttempt) }
        let wrongContext = ChildResultEnvelope(taskID: task.taskID, runID: newRun, attemptID: newAttempt,
            parentContextSnapshotID: "foreign-context", childExecutionID: "foreign-execution",
            outcome: .failed(reason: "DEADLINE_EXCEEDED"), outputDigest: "synthetic-digest")
        #expect(throws: AgentTaskStoreError.childResultIdentityMismatch) { _ = try store.settleChildResult(wrongContext) }
        let foreignEnvelope = envelope(foreignTask, runID: foreignRun.runID,
                                       outcome: .failed(reason: "DEADLINE_EXCEEDED"), attemptID: newAttempt)
        #expect(throws: AgentTaskStoreError.childResultIdentityMismatch) { _ = try store.settleChildResult(foreignEnvelope) }
        #expect(store.events(runID: newRun) == eventsBefore)
        #expect(store.allReceipts() == receiptsBefore)
        let afterLate = try #require(consumer.receiptRows(now: now).first { $0.parentID == task.parentID })
        #expect(afterLate.observationIdentity == running.observationIdentity)
        #expect(!afterLate.isDeadlineExpired)
        #expect(afterLate.childResultEnvelope == nil)
        let result = envelope(task, runID: newRun, outcome: .succeeded)
        let terminal = try store.settleChildResult(result)
        #expect(try store.settleChildResult(result) == terminal)
        #expect(throws: AgentTaskStoreError.childResultIdempotencyConflict) { _ = try store.settleChildResult(terminalPayloadDrift) }
        #expect(throws: AgentTaskStoreError.childResultIdentityMismatch) { _ = try store.settleChildResult(late) }
        #expect(store.receipt(runID: newRun) == terminal)
        #expect(store.childResultEnvelope(taskID: task.taskID, runID: newRun) == nil)
        #expect(store.childResultEnvelope(taskID: task.taskID, parentID: task.parentID, runID: newRun) == result)
        #expect(store.childResultEnvelope(taskID: task.taskID, parentID: foreignTask.parentID, runID: newRun) == nil)
        #expect(store.events(runID: newRun).filter { $0.kind == .completed }.count == 1)
        #expect(store.allReceipts().count == receiptsBefore.count + 1)
        #expect(store.snapshot(taskID: foreignTask.taskID, parentID: foreignTask.parentID) == foreignBefore)
        #expect(store.taskSnapshot(runID: foreignRun.runID)?.parentID == foreignTask.parentID)
        let row = try #require(consumer.receiptRows(now: now).first { $0.parentID == task.parentID })
        #expect(row.statusTitle == "已完成")
        #expect(row.childResultEnvelope == result)
        #expect(row.succeededBacklink?.attemptID == newAttempt)
        #expect(!row.isDeadlineExpired)
        let restoredStore = try AgentTaskStore(persistenceURL: ledger)
        let restoredConsumer = makeConsumer(restoredStore)
        let restored = try #require(restoredConsumer.receiptRows(now: now).first { $0.parentID == task.parentID })
        #expect(restored.observationIdentity == row.observationIdentity)
        #expect(restored.childResultEnvelope == result)
        #expect(restored.statusTitle == "已完成")
        #expect(restored.succeededBacklink == row.succeededBacklink)
        #expect(try restoredConsumer.execute(request, now: now) == retried)
        #expect(restoredStore.events(runID: newRun) == store.events(runID: newRun))
        #expect(restoredStore.allReceipts() == store.allReceipts())
        let recoveredForeign = try #require(restoredConsumer.receiptRows(now: now).first { $0.parentID == foreignTask.parentID })
        #expect(recoveredForeign.recoveryState == .needsUserReview)
        #expect(recoveredForeign.lifecycleState == .running)
        #expect(!recoveredForeign.cancelAvailable)
        #expect(!recoveredForeign.isDeadlineExpired)
    }

    private var now: Date { Date(timeIntervalSince1970: 1_850_000_000) }

    private func fixtureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tasks546-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeConsumer(_ store: AgentTaskStore, expiresAt: Date? = nil) -> TaskCenterControlConsumer {
        TaskCenterControlConsumer(store: store, bindingProvider: { snapshot in
            let issued = Date(timeIntervalSince1970: 1_800_000_000)
            let deadline = Date(timeIntervalSince1970: 1_900_000_000)
            let goal = GoalEnvelope(goalID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!, scopeID: "scope546", allowedCapabilities: ["task.control"],
                                    budget: 10, deadline: deadline, createdAt: issued)
            let lease = AutonomyLease(leaseID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, goalID: goal.goalID, scopeID: goal.scopeID,
                                      issuedAt: issued, expiresAt: expiresAt ?? deadline)
            return GoalTaskCenterBinding(taskID: snapshot.taskID, parentID: snapshot.parentID, goal: goal, lease: lease)
        })
    }

    private func envelope(_ task: AgentTaskSnapshot, runID: String, outcome: AgentTaskOutcome,
                          attemptID: String? = nil) -> ChildResultEnvelope {
        ChildResultEnvelope(taskID: task.taskID, runID: runID, attemptID: attemptID ?? "\(runID):attempt:1",
                            parentContextSnapshotID: task.parentContextSnapshotID,
                            childExecutionID: "execution-" + runID, outcome: outcome, outputDigest: "digest-" + runID)
    }
}

private enum Task546ProviderError: Error { case unexpectedCall }
private struct Task546UnusedProvider: LLMProvider, Sendable {
    let name = "offline546"
    var model = LLMModel(id: "synthetic546", displayName: "synthetic546", provider: "offline546")
    var capabilities: Set<ProviderCapability> { [.streaming] }
    nonisolated(nonsending) func sendMessage(messages: [LLMMessage], systemPrompt: String?,
        maxTokens: Int, temperature: Double?) async throws -> LLMResponse { throw Task546ProviderError.unexpectedCall }
    nonisolated(nonsending) func streamMessage(messages: [LLMMessage], systemPrompt: String?,
        maxTokens: Int, temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        throw Task546ProviderError.unexpectedCall
    }
}
