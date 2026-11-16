import Foundation
import Darwin
import Testing
import MinisCore
@testable import MinisCanvasApp

enum ColdRestart0545Error: Error { case missingFormalRoot, unsupportedPhase }

struct ColdRestartSeed0545: Codable {
    let pid: Int32
    let goal: GoalEnvelope
    let lease: AutonomyLease
    let oldEnvelope: ChildResultEnvelope
    let oldRetry: TaskCenterControlRequest
    let sourceNavigation: TaskCenterSourceSessionNavigation
    let runtime: ExternalSessionRuntimeSnapshot
}

struct ColdRestartResult0545: Codable {
    let pid: Int32
    let seedPID: Int32
    let newRun: String
    let newAttempt: String
    let sourceContents: [String]
    let currentOutcome: AgentTaskOutcome
    let unknownRecovery: TaskCenterRecoveryState
    let unknownReceiptAbsent: Bool
    let runtimeCheckpointAttempt: String?
    let runtimeStillRequiresReconciliation: Bool
}

@MainActor
enum ColdRestartOwnedChild0545 {
    static let now = Date(timeIntervalSince1970: 1_850_000_000)
    static let sourceSession = "source-session0545"
    static let parentID = "parent0545"

    static func run(phase: String, root: URL) async throws {
        switch phase {
        case "seed": try await seed(root)
        case "reopen": try await reopen(root)
        default: throw ColdRestart0545Error.unsupportedPhase
        }
    }

    static func seed(_ root: URL) async throws {
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        _ = try sessions.createSession(id: sourceSession, title: "owned source0545")
        try sessions.saveMessage(LLMMessage(role: .user, content: "来源0545真实持久正文"), sessionID: sourceSession)
        let store = try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json"))
        let source = ParentRuntimeIdentity(sessionID: sourceSession, conversationID: "conversation0545",
            turnID: "turn0545", taskID: parentID, actorID: "owned0545")
        let creation = SessionActionCreationMetadata(scopeID: "scope0545", idempotencyKey: "create0545",
            action: .new(title: "cold retry0545", projectID: "synthetic0545", source: source))
        let task = try store.enqueueIdempotent(taskID: "retry0545", parentID: parentID,
            providerID: "offline", modelID: "synthetic", creation: creation).snapshot
        let oldRun = try store.startRun(taskID: task.taskID, parentID: parentID, runID: "old0545")
        let old = envelope(task, runID: oldRun.runID, outcome: .failed(reason: "seed-owned-failure"))
        _ = try store.settleChildResult(old)
        _ = try store.enqueue(taskID: "unknown0545", parentID: parentID, providerID: "offline", modelID: "synthetic")
        _ = try store.startRun(taskID: "unknown0545", parentID: parentID, runID: "unknown-run0545")
        try store.markExternalSubmissionUnknown(runID: "unknown-run0545")
        let goal = GoalEnvelope(goalID: UUID(), scopeID: "scope0545", allowedCapabilities: ["task.control"],
            budget: 10, deadline: now.addingTimeInterval(3_600), createdAt: now.addingTimeInterval(-60))
        let lease = AutonomyLease(leaseID: UUID(), goalID: goal.goalID, scopeID: goal.scopeID,
            issuedAt: now.addingTimeInterval(-60), expiresAt: goal.deadline)
        let consumer = TaskCenterControlConsumer(store: store, bindingPersistenceURL: root.appendingPathComponent("goal-lease.json"),
                                                childTranscriptSessionStore: sessions)
        consumer.installProductionGoal(goal: goal, lease: lease)
        let fact = try #require(consumer.project(now: now).fact(taskID: task.taskID, parentID: parentID))
        let row = try #require(consumer.receiptRows(now: now).first { $0.taskID == task.taskID })
        let sourceNavigation = try #require(consumer.sourceSessionNavigation(for: row))
        #expect(consumer.sourceTranscript(navigation: sourceNavigation)?.messages.map(\.content) == ["来源0545真实持久正文"])
        let retry = TaskCenterControlRequest(taskID: task.taskID, parentID: parentID, revision: fact.revision,
            scopeID: goal.scopeID, actorID: "owned0545", idempotencyKey: "current-retry0545", action: .retry, runID: oldRun.runID)
        let adapter = runtimeAdapter(root)
        consumer.bindExternalSessionRuntime(from: adapter)
        let connected = try await adapter.connect(readGrant: statusGrant)
        let owner = try #require(connected.ownerID)
        #expect(adapter.beginExternalAttempt(correlationID: "runtime0545", attemptID: "old-runtime0545", ownerID: owner))
        #expect(try await adapter.consumeExternalEvent(event("old-event0545", sequence: 1), correlationID: "runtime0545",
            attemptID: "old-runtime0545", ownerID: owner, connectionGeneration: connected.generation, readGrant: eventGrant) == .accepted)
        #expect(consumer.externalSessionRuntime?.snapshot.eventCheckpoint?.identity.attemptID == "old-runtime0545")
        let proof = ColdRestartSeed0545(pid: getpid(), goal: goal, lease: lease, oldEnvelope: old, oldRetry: retry,
                                       sourceNavigation: sourceNavigation, runtime: adapter.runtimeSnapshot)
        try JSONEncoder().encode(proof).write(to: root.appendingPathComponent("seed.json"), options: .atomic)
        // Natural process exit leaves an active durable checkpoint and UNKNOWN submission;
        // no adapter stop/reset or synthetic success is injected before the exec boundary.
    }

    static func reopen(_ root: URL) async throws {
        let old = try JSONDecoder().decode(ColdRestartSeed0545.self, from: Data(contentsOf: root.appendingPathComponent("seed.json")))
        #expect(old.pid != getpid())
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let store = try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json"))
        let consumer = TaskCenterControlConsumer(store: store, bindingPersistenceURL: root.appendingPathComponent("goal-lease.json"),
                                                childTranscriptSessionStore: sessions)
        #expect(consumer.isAvailable)
        let oldFact = try #require(consumer.project(now: now).fact(taskID: "retry0545", parentID: parentID))
        #expect(oldFact.scopeID == old.goal.scopeID)
        #expect(oldFact.leaseState == .active)
        #expect(consumer.sourceTranscript(navigation: old.sourceNavigation)?.messages.map(\.content) == ["来源0545真实持久正文"])
        let retried = try consumer.execute(old.oldRetry, now: now)
        let newRun = try #require(retried.resultingRunID)
        let newAttempt = try #require(store.canonicalAttemptID(runID: newRun))
        #expect(newRun != old.oldEnvelope.runID)
        #expect(newAttempt != old.oldEnvelope.attemptID)
        let currentTask = try #require(store.snapshot(taskID: "retry0545", parentID: parentID))
        let beforeEvents = store.events(runID: newRun)
        let beforeReceipts = store.allReceipts()
        let beforeSessions = try Data(contentsOf: sessions.sessionsDirectory.appendingPathComponent(sourceSession + ".json"))
        let staleRevision = TaskCenterControlRequest(taskID: "retry0545", parentID: parentID,
            revision: old.oldRetry.revision, scopeID: old.goal.scopeID, actorID: "owned0545",
            idempotencyKey: "old-revision0545", action: .cancel, runID: newRun)
        #expect(throws: TaskCenterControlConsumerError.facade(.revisionMismatch)) { _ = try consumer.execute(staleRevision, now: now) }
        let wrongAttempt = envelope(currentTask, runID: newRun, outcome: .succeeded, attemptID: old.oldEnvelope.attemptID)
        #expect(throws: AgentTaskStoreError.childResultIdentityMismatch) { _ = try store.settleChildResult(wrongAttempt) }
        let staleResult = envelope(currentTask, runID: old.oldEnvelope.runID, outcome: .succeeded)
        #expect(throws: AgentTaskStoreError.childResultIdempotencyConflict) { _ = try store.settleChildResult(staleResult) }
        #expect(consumer.sourceTranscript(navigation: old.sourceNavigation) == nil)
        #expect(store.events(runID: newRun) == beforeEvents)
        #expect(store.allReceipts() == beforeReceipts)
        #expect(store.snapshot(taskID: "retry0545", parentID: parentID) == currentTask)
        #expect(try Data(contentsOf: sessions.sessionsDirectory.appendingPathComponent(sourceSession + ".json")) == beforeSessions)
        let valid = envelope(currentTask, runID: newRun, outcome: .succeeded, attemptID: newAttempt)
        let settled = try store.settleChildResult(valid)
        #expect(try store.settleChildResult(valid) == settled)
        #expect(settled.outcome == .succeeded)
        #expect(store.events(runID: newRun).filter { $0.kind == .completed }.count == 1)
        let currentRow = try #require(consumer.receiptRows(now: now).first { $0.taskID == "retry0545" })
        #expect(currentRow.succeededBacklink?.attemptID == newAttempt)
        let currentNavigation = try #require(consumer.sourceSessionNavigation(for: currentRow))
        let contents = try #require(consumer.sourceTranscript(navigation: currentNavigation)).messages.map(\.content)
        #expect(contents == ["来源0545真实持久正文"])
        consumer.bindChildTranscriptSessionStore(nil)
        #expect(consumer.sourceTranscript(navigation: currentNavigation) == nil)
        consumer.bindChildTranscriptSessionStore(sessions)
        #expect(consumer.sourceTranscript(navigation: currentNavigation)?.messages.map(\.content) == contents)
        let expired = TaskCenterControlRequest(taskID: "retry0545", parentID: parentID,
            revision: try #require(consumer.project(now: now).fact(taskID: "retry0545", parentID: parentID)).revision,
            scopeID: old.goal.scopeID, actorID: "owned0545", idempotencyKey: "expired-lease0545", action: .retry, runID: newRun)
        #expect(throws: TaskCenterControlConsumerError.facade(.leaseNotActive(.expired))) {
            _ = try consumer.execute(expired, now: old.lease.expiresAt.addingTimeInterval(1))
        }
        let unknown = try #require(consumer.receiptRows(now: now).first { $0.taskID == "unknown0545" })
        #expect(unknown.recoveryState == .needsUserReview)
        #expect(unknown.lifecycleState == .running)
        #expect(!unknown.cancelAvailable && !unknown.retryAvailable)
        #expect(unknown.succeededBacklink == nil)
        #expect(store.externalSubmissionDecision(runID: "unknown-run0545") == .needsUserReview)
        #expect(store.receipt(runID: "unknown-run0545") == nil)
        let unknownFact = try #require(consumer.project(now: now).fact(taskID: "unknown0545", parentID: parentID))
        let unknownRequest = TaskCenterControlRequest(taskID: "unknown0545", parentID: parentID, revision: unknownFact.revision,
            scopeID: old.goal.scopeID, actorID: "owned0545", idempotencyKey: "unknown-cancel0545", action: .cancel, runID: "unknown-run0545")
        let unknownBefore = store.events(runID: "unknown-run0545")
        #expect(throws: TaskCenterControlConsumerError.executor(.needsUserReview(.externalSubmissionUnknown))) {
            _ = try consumer.execute(unknownRequest, now: now)
        }
        #expect(store.events(runID: "unknown-run0545") == unknownBefore)
        #expect(store.receipt(runID: "unknown-run0545") == nil)
        let adapter = runtimeAdapter(root)
        consumer.bindExternalSessionRuntime(from: adapter)
        #expect(adapter.runtimeSnapshot.state == .recoveryRequired)
        #expect(adapter.runtimeSnapshot.requiresSideEffectReconciliation)
        let checkpoint = try #require(adapter.runtimeSnapshot.eventCheckpoint)
        #expect(checkpoint == old.runtime.eventCheckpoint)
        #expect(try await adapter.consumeExternalEvent(event("late0545", sequence: 99), correlationID: "runtime0545",
            attemptID: "old-runtime0545", ownerID: try #require(old.runtime.ownerID),
            connectionGeneration: old.runtime.generation, readGrant: eventGrant) == .rejectedDisconnected)
        #expect(adapter.runtimeSnapshot.eventCheckpoint == checkpoint)
        #expect(consumer.externalSessionRuntime?.snapshot.requiresSideEffectReconciliation == true)
        let proof = ColdRestartResult0545(pid: getpid(), seedPID: old.pid, newRun: newRun, newAttempt: newAttempt,
            sourceContents: contents, currentOutcome: settled.outcome, unknownRecovery: unknown.recoveryState,
            unknownReceiptAbsent: store.receipt(runID: "unknown-run0545") == nil,
            runtimeCheckpointAttempt: adapter.runtimeSnapshot.eventCheckpoint?.identity.attemptID,
            runtimeStillRequiresReconciliation: adapter.runtimeSnapshot.requiresSideEffectReconciliation)
        try JSONEncoder().encode(proof).write(to: root.appendingPathComponent("reopen.json"), options: .atomic)
    }

    static func envelope(_ task: AgentTaskSnapshot, runID: String, outcome: AgentTaskOutcome, attemptID: String? = nil) -> ChildResultEnvelope {
        ChildResultEnvelope(taskID: task.taskID, runID: runID, attemptID: attemptID ?? runID + ":attempt:1",
            parentContextSnapshotID: task.parentContextSnapshotID, childExecutionID: "execution-" + runID,
            outcome: outcome, outputDigest: "owned-digest-" + runID, output: "owned-result-" + runID)
    }
    static let sourceID = ExternalSessionSourceID(rawValue: "owned-source0545")
    static let profileID = ExternalSessionProfileID(rawValue: "owned-profile0545")
    static let threadID = ExternalSessionThreadID(rawValue: "owned-thread0545")
    static let statusGrant = ExternalSessionReadGrantV1(authorizationID: .init(rawValue: "owned-status0545"),
        sourceID: sourceID, profileID: profileID, target: .source(sourceID), scopes: [.status],
        issuedAt: Date(timeIntervalSince1970: 100), expiresAt: Date(timeIntervalSince1970: 300), revocationEpoch: 0)
    static let eventGrant = ExternalSessionReadGrantV1(authorizationID: .init(rawValue: "owned-event0545"),
        sourceID: sourceID, profileID: profileID, target: .thread(threadID), scopes: [.events],
        issuedAt: Date(timeIntervalSince1970: 100), expiresAt: Date(timeIntervalSince1970: 300), revocationEpoch: 0)
    static func runtimeAdapter(_ root: URL) -> ExternalSessionAppAdapter {
        ExternalSessionAppAdapter(implementation: ColdRestartRuntimeProbe0545(source: ExternalSessionSourceV1(
            sourceID: sourceID, kind: .codex, adapterVersion: "owned/0545", profileID: profileID, hostID: "isolated",
            capabilities: [.status, .stream], authState: .authorized)), clock: { Date(timeIntervalSince1970: 200) },
            runtimePersistenceURL: root.appendingPathComponent("runtime.json"))
    }
    static func event(_ id: String, sequence: UInt64) -> ExternalSessionEventV1 {
        ExternalSessionEventV1(eventID: .init(rawValue: id), sourceID: sourceID, threadID: threadID, sequence: sequence,
            sourceCursor: .init(rawValue: "cursor-" + id), occurredAt: Date(timeIntervalSince1970: 201), required: false,
            kind: .progress, payload: .init(kind: "progress", summary: "owned bounded event"), sourceRef: "synthetic")
    }
}

private struct ColdRestartRuntimeProbe0545: ExistingAgentSessionAdapter, Sendable {
    let source: ExternalSessionSourceV1
    func listThreads(query: ExternalSessionThreadQueryV1, readGrant: ExternalSessionReadGrantV1) async throws -> ExternalSessionThreadPageV1 {
        .init(sourceID: source.sourceID, threads: [], observedCursor: query.cursor)
    }
    func read(request: ExternalSessionReadRequestV1, readGrant: ExternalSessionReadGrantV1) async throws -> ExternalSessionReadPageV1 {
        .init(sourceID: source.sourceID, threadID: request.threadID, turns: [], events: [], observedCursor: request.cursor)
    }
    func status(target: ExternalSessionStatusTargetV1, readGrant: ExternalSessionReadGrantV1) async throws -> ExternalSessionStatusV1 {
        .init(sourceID: source.sourceID, threadID: target.threadID, turnID: target.turnID,
              threadStatus: .active, observedCursor: .beginning, latestSequence: 0)
    }
    func control(request: ExternalSessionControlRequestV1, controlGrant: ExternalSessionControlGrantV1) async throws -> ExternalSessionControlReceiptV1 {
        throw ColdRestart0545Error.unsupportedPhase
    }
}
