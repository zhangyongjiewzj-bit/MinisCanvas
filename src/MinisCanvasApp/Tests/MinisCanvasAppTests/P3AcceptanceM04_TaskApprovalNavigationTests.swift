import Foundation
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

@Suite("D-TASK-12 canonical pending approval destination")
@MainActor
struct P3AcceptanceM04_TaskApprovalNavigationTests {
    @Test("the task row uses its own run and attempt while the request keeps its effect identity")
    func mappedApprovalRevalidatesLivePendingAndRetry() async throws {
        let fixture = try await makeFixture()
        defer { B1ARCHOriginalFixtureSupport.cleanupRoot(fixture.root) }
        let consumer = fixture.consumer
        let row = fixture.row
        let now = fixture.now
        let request = fixture.request
        let navigation = try #require(consumer.approvalNavigation(
            for: row, pendingRequest: request, now: now
        ))
        #expect(request.runID != row.runID)
        #expect(request.attemptID != row.attemptID)
        #expect(navigation.runID == row.runID)
        #expect(navigation.attemptID == row.attemptID)
        #expect(navigation.sessionID == fixture.childSessionID)
        #expect(consumer.pendingApproval(
            navigation: navigation, pendingRequest: request, now: now
        ) == request)
        #expect(consumer.pendingApproval(
            navigation: navigation, pendingRequest: nil, now: now
        ) == nil)

        let replacement = makeRequest(
            fixture: fixture, requestID: "replacement-request"
        )
        #expect(consumer.pendingApproval(
            navigation: navigation, pendingRequest: replacement, now: now
        ) == nil)
        #expect(consumer.approvalNavigation(
            for: row, pendingRequest: request, now: fixture.expiresAt
        ) == nil)

        _ = try fixture.tasks.finish(runID: fixture.taskRunID, outcome: .cancelled)
        #expect(consumer.pendingApproval(
            navigation: navigation, pendingRequest: request, now: now
        ) == nil)
        _ = try fixture.tasks.startRun(
            taskID: row.taskID, parentID: row.parentID, runID: "retry-run"
        )
        #expect(consumer.approvalNavigation(
            for: row, pendingRequest: request, now: now
        ) == nil)
    }

    @Test("a mapped task never borrows a foreign request or stale approval fact")
    func mappedApprovalRejectsCrossIdentityAndHistoricalEvent() async throws {
        let fixture = try await makeFixture()
        defer { B1ARCHOriginalFixtureSupport.cleanupRoot(fixture.root) }
        for request in [
            makeRequest(fixture: fixture, taskID: "foreign-task"),
            makeRequest(fixture: fixture, sessionID: "foreign-session"),
            makeRequest(fixture: fixture, approvalRunID: "foreign-generation"),
            makeRequest(fixture: fixture, approvalAttemptID: "foreign-attempt")
        ] {
            #expect(fixture.consumer.approvalNavigation(
                for: fixture.row, pendingRequest: request, now: fixture.now
            ) == nil)
        }
        let legacy = ApprovalRequest(
            id: "legacy", toolName: "shell_execute", inputSummary: "redacted",
            riskLevel: .medium, requiresApproval: true
        )
        #expect(fixture.consumer.approvalNavigation(
            for: fixture.row, pendingRequest: legacy, now: fixture.now
        ) == nil)

        fixture.tasks.endPendingChildApproval(fixture.mapping)
        #expect(fixture.tasks.events(runID: fixture.taskRunID).last?.kind == .approvalRequired)
        #expect(fixture.consumer.approvalNavigation(
            for: fixture.row, pendingRequest: fixture.request, now: fixture.now
        ) == nil)
    }

    private struct Fixture {
        let root: URL
        let tasks: AgentTaskStore
        let consumer: TaskCenterControlConsumer
        let row: TaskCenterReceiptRow
        let mapping: AgentTaskApprovalNavigationBinding
        let request: ApprovalRequest
        let taskRunID: String
        let childSessionID: String
        let generationID: String
        let now: Date
        let expiresAt: Date
    }

    private func makeFixture() async throws -> Fixture {
        let root = try B1ARCHOriginalFixtureSupport.makeRoot("m04-approval-navigation")
        var fixtureComplete = false
        defer { if !fixtureComplete { B1ARCHOriginalFixtureSupport.cleanupRoot(root) } }
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let parent = try sessions.createSession(id: "synthetic-parent-session")
        let child = try sessions.forkSession(
            from: parent.id, id: "synthetic-child-session", title: "Synthetic child",
            throughMessageIndex: 0,
            createdByTaskID: "synthetic-child-task", createdByRunID: "synthetic-task-run"
        )
        let tasks = AgentTaskStore()
        let task = try tasks.enqueue(
            taskID: "synthetic-child-task", parentID: "synthetic-parent-task",
            providerID: "offline", modelID: "synthetic"
        )
        let run = try tasks.startRun(
            taskID: task.taskID, parentID: task.parentID, runID: "synthetic-task-run"
        )
        let attempt = try #require(tasks.attempts(runID: run.runID).last)
        let controller = TurnController()
        let handle = await controller.beginTurn()
        let parentIdentity = ParentRuntimeIdentity(
            sessionID: parent.id, conversationID: parent.id,
            turnID: "turn-handle:\(handle.turnID)", taskID: task.parentID,
            actorID: "synthetic-actor"
        )
        let identity = try ChildRuntimeIdentity.derive(
            parent: parentIdentity, childSessionID: child.id,
            childTaskID: task.taskID, scopeID: "synthetic-scope",
            requestedCapabilities: [.tools], parentCapabilities: [.tools],
            policyCapabilities: [.tools],
            providerSnapshot: ParentContextSnapshotV1(
                providerID: "offline", modelID: "synthetic",
                configurationFingerprint: "synthetic", conversationID: child.id
            ),
            memoryScopeID: "synthetic-memory", workingDirectory: root.path,
            cancelGeneration: handle.turnID, evidenceRoot: "synthetic-evidence",
            parentTurnHandle: handle, childExecutionID: "synthetic-execution"
        )
        let generationID = try #require(identity.generationID)
        let locator = ChildTranscriptLocator(
            childSessionID: child.id, parentSessionID: parent.id,
            taskID: task.taskID, parentID: task.parentID,
            runID: run.runID, attemptID: attempt.attemptID,
            childExecutionID: "synthetic-execution",
            parentContextSnapshotID: task.parentContextSnapshotID,
            lineageVersion: child.lineageVersion
        )
        _ = try tasks.bindChildTranscript(locator)
        let now = Date(timeIntervalSince1970: 1_850_000_000)
        let expiresAt = now.addingTimeInterval(60)
        let binding = ApprovalAuthorizationContext(
            actorID: "child:\(child.id)", sessionID: child.id,
            turnID: handle.turnID, taskID: task.taskID,
            runID: generationID, attemptID: generationID,
            effectID: "request-A", scope: identity.scopeID,
            payloadDigest: "synthetic-digest", expiresAt: expiresAt,
            policyRevision: "synthetic-policy", grantEpoch: generationID,
            toolName: "shell_execute"
        )
        let request = request(from: binding, requestID: "request-A")
        let mapping = try tasks.beginPendingChildApproval(
            taskRunID: run.runID, taskAttemptID: attempt.attemptID,
            childIdentity: identity, request: request, now: now
        )
        let consumer = TaskCenterControlConsumer(
            store: tasks, childTranscriptSessionStore: sessions
        )
        let row = try #require(consumer.receiptRows(now: now).first)
        #expect(row.childSessionID == child.id)
        fixtureComplete = true
        return Fixture(
            root: root, tasks: tasks, consumer: consumer, row: row,
            mapping: mapping, request: request, taskRunID: run.runID,
            childSessionID: child.id, generationID: generationID,
            now: now, expiresAt: expiresAt
        )
    }

    private func makeRequest(
        fixture: Fixture,
        taskID: String? = nil,
        sessionID: String? = nil,
        approvalRunID: String? = nil,
        approvalAttemptID: String? = nil,
        requestID: String = "request-A"
    ) -> ApprovalRequest {
        let original = fixture.request.binding!
        let binding = ApprovalAuthorizationContext(
            actorID: original.actorID, sessionID: sessionID ?? original.sessionID,
            turnID: original.turnID, taskID: taskID ?? original.taskID,
            runID: approvalRunID ?? original.runID,
            attemptID: approvalAttemptID ?? original.attemptID,
            effectID: requestID, scope: original.scope,
            payloadDigest: original.payloadDigest, expiresAt: original.expiresAt,
            policyRevision: original.policyRevision, grantEpoch: original.grantEpoch,
            toolName: original.toolName
        )
        return request(from: binding, requestID: requestID)
    }

    private func request(
        from binding: ApprovalAuthorizationContext, requestID: String
    ) -> ApprovalRequest {
        ApprovalRequest(
            id: requestID, requestID: requestID, callID: requestID,
            toolName: binding.toolName, inputSummary: "redacted",
            riskLevel: .medium, requiresApproval: true,
            sessionID: binding.sessionID, turnID: binding.turnID,
            taskID: binding.taskID, attemptID: binding.attemptID,
            approvalScope: binding.scope,
            policyRevision: binding.policyRevision,
            grantEpoch: binding.grantEpoch,
            inputDigest: binding.payloadDigest,
            identityDigest: binding.identityDigest,
            actorID: binding.actorID, runID: binding.runID,
            effectID: binding.effectID, expiresAt: binding.expiresAt
        )
    }
}
