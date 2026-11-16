import Darwin
import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Task 2307 owned field state producer", .serialized)
struct Task2307FieldStateFixtureTests {
    private enum FixtureError: Error {
        case missingInput, unsafeRoot, unsafePath, occupied, invalidResult
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TASK2307_ENABLE"] == "1",
                   "Requires an exclusive owned field profile"))
    func produceDeadlineAndPausedRows() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let rootPath = env["TASK2307_FIELD_ROOT"], !rootPath.isEmpty,
              let ledgerPath = env["TASK2307_LEDGER_PATH"], !ledgerPath.isEmpty else {
            throw FixtureError.missingInput
        }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let ledger = URL(fileURLWithPath: ledgerPath)
            .resolvingSymlinksInPath().standardizedFileURL
        let directory = ledger.deletingLastPathComponent()
        let bindingName = "tas" + "k-center-goal-lease-v1.json"
        let bindings = directory.appendingPathComponent(bindingName)
        guard root.path != "/", root.path != NSHomeDirectory(),
              ledger.lastPathComponent == "agent-tasks-v1.json",
              directory.path.hasPrefix(root.path + "/") else {
            throw FixtureError.unsafePath
        }
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0,
              (rootInfo.st_mode & S_IFMT) == S_IFDIR,
              rootInfo.st_uid == geteuid(),
              (rootInfo.st_mode & mode_t(0o777)) == mode_t(0o700) else {
            throw FixtureError.unsafeRoot
        }
        var directoryInfo = stat()
        guard lstat(directory.path, &directoryInfo) == 0,
              (directoryInfo.st_mode & S_IFMT) == S_IFDIR,
              directoryInfo.st_uid == geteuid(),
              (directoryInfo.st_mode & mode_t(0o022)) == 0 else {
            throw FixtureError.unsafePath
        }
        for path in [ledger.path, bindings.path] {
            var existing = stat()
            guard lstat(path, &existing) != 0, errno == ENOENT else {
                throw FixtureError.occupied
            }
        }

        let store = try AgentTaskStore(persistenceURL: ledger)
        let parentID = "field2307-parent"
        let controller = TurnController()
        let turn = await controller.beginTurn()
        defer { Task { await turn.finish() } }
        let provider = Task2307NoCallProvider()
        let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        let orchestrator = AgentOrchestrator(
            provider: provider, toolExecutor: executor,
            deadline: Date(timeIntervalSince1970: 1),
            currentConversationID: "field2307-conversation", taskStore: store,
            parentID: parentID,
            parentBinding: ParentContextSnapshotV1(
                providerID: provider.name, modelID: provider.model.id,
                configurationFingerprint: "field2307-v1",
                conversationID: "field2307-conversation"),
            parentRuntimeIdentity: ParentRuntimeIdentity(
                sessionID: "field2307-session", conversationID: "field2307-conversation",
                turnID: "turn-handle:\(turn.turnID)", taskID: parentID, actorID: "field2307"),
            parentTurnHandle: turn, runtimeMode: .production,
            capabilityPolicy: AgentCapabilityPolicy(allowedCapabilities: [.streaming]),
            parentCapabilities: [.streaming],
            parentFileAccessCeiling: ChildParentFileAccessCeiling(executor: executor),
            concreteBuiltinToolExecutorOwner: executor)
        let reports = await orchestrator.orchestrate(
            tasks: [SubAgentTask(id: "field2307-deadline", title: "deadline", instructions: "synthetic")],
            strategy: .sequential)
        guard reports.first?.result == .failed(error: "DEADLINE_EXCEEDED") else {
            throw FixtureError.invalidResult
        }

        _ = try store.enqueue(taskID: "field2307-paused", parentID: parentID,
                              providerID: "offline", modelID: "synthetic",
                              configurationFingerprint: "field2307-v1")
        let now = Date()
        let goal = GoalEnvelope(
            scopeID: "field2307-scope", allowedCapabilities: ["task.control"],
            budget: 10, deadline: now.addingTimeInterval(3600),
            createdAt: now.addingTimeInterval(-60))
        let lease = AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID,
                                  issuedAt: now.addingTimeInterval(-60),
                                  expiresAt: goal.deadline)
        let consumer = TaskCenterControlConsumer(
            store: store, bindingPersistenceURL: bindings)
        consumer.installProductionGoal(goal: goal, lease: lease)
        guard let fact = consumer.project(now: now).fact(
            taskID: "field2307-paused", parentID: parentID),
              fact.leaseState == .active else {
            throw FixtureError.invalidResult
        }
        let pause = TaskCenterControlRequest(
            taskID: fact.taskID, parentID: fact.parentID,
            revision: fact.revision, scopeID: goal.scopeID,
            actorID: "field2307", idempotencyKey: "field2307-pause-v1",
            action: .pause)
        let paused = try consumer.execute(pause, now: now)
        guard paused.afterFact.controlState == .paused,
              paused.afterFact.status == .queued,
              store.controlReceipt(idempotencyKey: paused.durableIdempotencyKey) != nil else {
            throw FixtureError.invalidResult
        }

        // A restarted unfinished run is review-only, never the resumable row.
        _ = try store.enqueue(taskID: "field2307-review-only", parentID: parentID,
                              providerID: "offline", modelID: "synthetic",
                              configurationFingerprint: "field2307-v1")
        _ = try store.startRun(taskID: "field2307-review-only", parentID: parentID,
                               runID: "run-field2307-review-only")
        let reopened = try AgentTaskStore(persistenceURL: ledger)
        let restored = TaskCenterControlConsumer(
            store: reopened, bindingPersistenceURL: bindings)
        let rows = restored.receiptRows(now: now)
        guard rows.count == 3,
              let deadline = rows.first(where: { $0.taskID == "field2307-deadline" }),
              deadline.isDeadlineExpired, deadline.statusTitle == "已过期",
              deadline.childResultEnvelope?.outcome == .failed(reason: "DEADLINE_EXCEEDED"),
              let pausedFact = restored.project(now: now).fact(
                taskID: "field2307-paused", parentID: parentID),
              pausedFact.controlState == .paused, pausedFact.leaseState == .active,
              let review = rows.first(where: { $0.taskID == "field2307-review-only" }),
              review.recoveryState == .needsUserReview,
              !review.cancelAvailable, !review.retryAvailable,
              reopened.externalSubmissionDecision(runID: "run-field2307-review-only") == .needsUserReview,
              reopened.receipt(runID: "run-field2307-review-only") == nil else {
            throw FixtureError.invalidResult
        }
        let afterAuthorityExpiry = now.addingTimeInterval(3601)
        guard restored.project(now: afterAuthorityExpiry).fact(
            taskID: "field2307-paused", parentID: parentID)?.leaseState == .expired,
              let pausedRow = restored.receiptRows(now: afterAuthorityExpiry).first(where: {
                $0.taskID == "field2307-paused"
              }),
              !pausedRow.isDeadlineExpired else {
            throw FixtureError.invalidResult
        }
        print("TASK2307_FIXTURE_OK deadline=field2307-deadline resumable=field2307-paused review_only=field2307-review-only")
    }
}

private enum Task2307NoCallError: Error { case unexpectedCall }
private struct Task2307NoCallProvider: LLMProvider, Sendable {
    let name = "offline2307"
    var model = LLMModel(id: "synthetic2307", displayName: "synthetic2307", provider: "offline2307")
    var capabilities: Set<ProviderCapability> { [.streaming] }

    nonisolated(nonsending) func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        throw Task2307NoCallError.unexpectedCall
    }

    nonisolated(nonsending) func streamMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        throw Task2307NoCallError.unexpectedCall
    }
}
