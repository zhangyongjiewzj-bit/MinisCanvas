import Foundation
import Testing
@testable import MinisCore

@Suite("Child envelope production settlement")
struct ChildEnvelopeProductionSettlementTests {
    @Test("production orchestration settles through supervisor and durable envelope")
    func productionSettlementPersistsCanonicalEnvelope() async throws {
        let controller = TurnController()
        let parentTurn = await controller.beginTurn()
        defer {
            Task { await parentTurn.finish() }
        }

        let store = AgentTaskStore()
        let provider = EnvelopeSettlementProvider()
        let orchestrator = AgentOrchestrator(
            provider: provider,
            toolExecutor: EnvelopeSettlementExecutor(),
            currentConversationID: "envelope-conversation",
            taskStore: store,
            parentID: "envelope-parent",
            parentBinding: ParentContextSnapshotV1(
                providerID: provider.name,
                modelID: provider.model.id,
                configurationFingerprint: "envelope-fingerprint",
                conversationID: "envelope-conversation"
            ),
            parentRuntimeIdentity: ParentRuntimeIdentity(
                sessionID: "envelope-session",
                conversationID: "envelope-conversation",
                turnID: "turn-handle:\(parentTurn.turnID)",
                taskID: "envelope-parent",
                actorID: "test"
            ),
            parentTurnHandle: parentTurn,
            runtimeMode: .production,
            capabilityPolicy: AgentCapabilityPolicy(
                allowedCapabilities: [.streaming],
                allowedToolNames: [],
                allowedMCPToolNames: []
            ),
            parentCapabilities: provider.capabilities
        )

        let reports = await orchestrator.orchestrate(
            tasks: [
                SubAgentTask(
                    id: "envelope-child",
                    title: "envelope child",
                    instructions: "complete"
                )
            ],
            strategy: .sequential
        )
        let receipt = try #require(store.allReceipts().first)
        let envelope = try #require(receipt.childResultEnvelope)

        #expect(reports.first?.result.isSuccess == true)
        #expect(envelope.taskID == receipt.taskID)
        #expect(envelope.runID == receipt.runID)
        #expect(envelope.attemptID == receipt.attemptID)
        #expect(envelope.parentContextSnapshotID == receipt.parentContextSnapshotID)
        #expect(envelope.attemptNumber > 0)
        #expect(envelope.sequence > 0)
        #expect(store.childResultEnvelope(runID: receipt.runID) == envelope)
        #expect(try store.settleChildResult(envelope) == receipt)
    }

    @Test("production child keeps exact parent turn through terminal settlement and reopen", arguments: ["success", "denied", "cancelled"])
    func productionParentOriginSurvivesSettlement823(scenario: String) async throws {
        let profile = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = profile.rootDirectory.appendingPathComponent("child823-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ledgerURL = root.appendingPathComponent("tasks.json")
        let store = try AgentTaskStore(persistenceURL: ledgerURL)
        let controller = TurnController()
        let oldTurn = await controller.beginTurn()
        await oldTurn.finish()
        let turn = await controller.beginTurn()
        defer { Task { await turn.finish() } }
        let parent = try ParentRuntimeIdentitySeed(sessionID: "823-source-session",
            conversationID: "823-source-conversation", taskID: "823-parent-task", actorID: "test")
            .makeIdentity(using: turn)
        #expect(turn.turnID > oldTurn.turnID)
        if scenario == "cancelled" { await controller.interrupt(turnID: turn.turnID) }
        let provider = EnvelopeSettlementProvider()
        let orchestrator = AgentOrchestrator(provider: provider,
            toolExecutor: EnvelopeSettlementExecutor(), currentConversationID: parent.conversationID,
            taskStore: store, parentID: parent.taskID,
            parentBinding: ParentContextSnapshotV1(providerID: provider.name,
                modelID: provider.model.id, configurationFingerprint: "823-frozen",
                conversationID: parent.conversationID),
            parentRuntimeIdentity: parent, parentTurnHandle: turn, runtimeMode: .production,
            capabilityPolicy: AgentCapabilityPolicy(allowedCapabilities: [.streaming],
                allowedToolNames: [], allowedMCPToolNames: []), parentCapabilities: provider.capabilities)
        let reports = await orchestrator.orchestrate(tasks: [SubAgentTask(id: "823-child",
            title: "owned child", instructions: "complete",
            requiredCapabilities: scenario == "denied" ? [.vision] : [])], strategy: .sequential)
        #expect(reports.count == 1)
        #expect(reports.first?.result.isSuccess == (scenario == "success"))
        let receipt = try #require(store.allReceipts().first)
        let envelope = receipt.childResultEnvelope
        if scenario == "cancelled" {
            // The original pre-dispatch cancellation path settles via finish:
            // it must not manufacture a child completion envelope.
            #expect(receipt.outcome == .cancelled && envelope == nil)
            #expect(try store.finish(runID: receipt.runID, outcome: .succeeded) == receipt)
        } else {
            let envelope = try #require(envelope)
            #expect(envelope.taskID == receipt.taskID && envelope.runID == receipt.runID)
            #expect(envelope.attemptID == receipt.attemptID)
            #expect(try store.settleChildResult(envelope) == receipt)
        }
        #expect(store.allReceipts() == [receipt])
        let reopened = try AgentTaskStore(persistenceURL: ledgerURL)
        if let envelope {
            #expect(try reopened.settleChildResult(envelope) == receipt)
        } else {
            #expect(try reopened.finish(runID: receipt.runID, outcome: .succeeded) == receipt)
            let late = ChildResultEnvelope(taskID: receipt.taskID, runID: receipt.runID,
                attemptID: receipt.attemptID, parentContextSnapshotID: receipt.parentContextSnapshotID,
                childExecutionID: "823-late", outcome: .succeeded, resultDigest: "823-late")
            #expect(throws: AgentTaskStoreError.childResultCancelled) {
                try reopened.settleChildResult(late)
            }
        }
        #expect(reopened.allReceipts() == [receipt])
        let captured = try #require(reopened.taskSnapshot(runID: receipt.runID))
        // Inspect the persisted production DTO, so the same assertion compiles
        // on the original baseline where the optional origin was absent.
        struct Origin: Decodable { let parentRuntimeIdentity: ParentRuntimeIdentity? }
        let origin = try JSONDecoder().decode(Origin.self, from: JSONEncoder().encode(captured))
        #expect(origin.parentRuntimeIdentity == parent)
        #expect(captured.sourceSessionID == parent.sessionID)
        let projection = TaskCenterObservationSnapshot(taskStore: reopened)
        #expect(projection.selecting(TaskCenterObservationFilter(sourceSessionIDs: [parent.sessionID])) == [captured])
        #expect(projection.selecting(TaskCenterObservationFilter(sourceSessionIDs: ["823-unrelated"])) == [])
        let stale = ChildResultEnvelope(taskID: receipt.taskID, runID: receipt.runID,
            attemptID: "823-foreign-attempt", parentContextSnapshotID: receipt.parentContextSnapshotID,
            childExecutionID: envelope?.childExecutionID ?? "823-late", outcome: .succeeded, resultDigest: "823-stale")
        #expect(throws: AgentTaskStoreError.childResultIdentityMismatch) {
            try reopened.settleChildResult(stale)
        }
        #expect(reopened.allReceipts() == [receipt])
    }

    @Test("legacy missing origin stays unknown; malformed claimed origin cannot survive reload")
    func legacyAndForeignParentOrigin823() throws {
        let profile = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = profile.rootDirectory.appendingPathComponent("child823-schema-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ledgerURL = root.appendingPathComponent("legacy.json")
        let store = try AgentTaskStore(persistenceURL: ledgerURL)
        let task = try store.enqueue(taskID: "823-legacy-child", parentID: "823-legacy-parent",
            providerID: "owned", modelID: "owned")
        let reopened = try AgentTaskStore(persistenceURL: ledgerURL)
        #expect(reopened.snapshot(taskID: task.taskID, parentID: task.parentID) == task)
        #expect(task.sourceSessionID == nil)
        var payload = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: ledgerURL)) as? [String: Any])
        var state = try #require(payload["state"] as? [String: Any])
        var tasks = try #require(state["tasks"] as? [String: Any])
        let key = try #require(tasks.keys.first)
        var record = try #require(tasks[key] as? [String: Any])
        record["parentRuntimeIdentity"] = ["sessionID": "823-foreign-session", "conversationID": "823-foreign",
            "turnID": "turn-handle:2", "taskID": "823-WRONG-parent", "actorID": "test"]
        tasks[key] = record; state["tasks"] = tasks; payload["state"] = state
        let tamperedURL = root.appendingPathComponent("foreign.json")
        try JSONSerialization.data(withJSONObject: payload).write(to: tamperedURL)
        #expect(throws: AgentTaskStoreError.persistenceFailed) {
            _ = try AgentTaskStore(persistenceURL: tamperedURL)
        }
        #expect(try Data(contentsOf: ledgerURL) != Data(contentsOf: tamperedURL))
    }

    @Test("stale attempt cannot settle the durable current run")
    func staleAttemptCannotSettleCurrentRun() throws {
        let store = AgentTaskStore()
        let task = try store.enqueue(
            taskID: "stale-task",
            parentID: "stale-parent",
            providerID: "provider",
            modelID: "model",
            parentContextSnapshotID: "stale-snapshot"
        )
        let run = try store.startRun(
            taskID: task.taskID,
            parentID: task.parentID,
            runID: "stale-run"
        )
        let envelope = ChildResultEnvelope(
            taskID: task.taskID,
            runID: run.runID,
            attemptID: "stale-attempt",
            parentContextSnapshotID: task.parentContextSnapshotID,
            childExecutionID: "stale-execution",
            outcome: .succeeded,
            resultDigest: "sha256:stale"
        )

        #expect(store.canonicalAttemptID(runID: run.runID) == "stale-run:attempt:1")
        #expect(store.attempt(runID: run.runID, attemptID: envelope.attemptID) == nil)
        #expect(throws: AgentTaskStoreError.childResultIdentityMismatch) {
            try store.settleChildResult(envelope)
        }
        #expect(store.allReceipts().isEmpty)
    }

    @Test("late envelope after terminal receipt is rejected while exact replay remains stable")
    func lateEnvelopeAfterTerminalReceiptIsRejected() throws {
        let store = AgentTaskStore()
        let task = try store.enqueue(
            taskID: "late-task",
            parentID: "late-parent",
            providerID: "provider",
            modelID: "model"
        )
        let run = try store.startRun(
            taskID: task.taskID,
            parentID: task.parentID,
            runID: "late-run"
        )
        let attemptID = try #require(store.canonicalAttemptID(runID: run.runID))
        let envelope = ChildResultEnvelope(
            taskID: task.taskID,
            runID: run.runID,
            attemptID: attemptID,
            parentContextSnapshotID: task.parentContextSnapshotID,
            childExecutionID: "late-execution",
            outcome: .succeeded,
            resultDigest: "sha256:late"
        )
        let receipt = try store.settleChildResult(envelope)
        #expect(try store.settleChildResult(envelope) == receipt)

        let lateFailure = ChildResultEnvelope(
            taskID: envelope.taskID,
            runID: envelope.runID,
            attemptID: envelope.attemptID,
            parentContextSnapshotID: envelope.parentContextSnapshotID,
            childExecutionID: envelope.childExecutionID,
            outcome: .failed(reason: "late"),
            resultDigest: "sha256:late-failure"
        )
        #expect(throws: AgentTaskStoreError.childResultIdempotencyConflict) {
            try store.settleChildResult(lateFailure)
        }
        #expect(store.receipt(runID: run.runID) == receipt)
    }

    @Test("payload drift is rejected while exact terminal replay remains idempotent")
    func payloadDriftCannotReplaceReceipt() throws {
        let store = AgentTaskStore()
        let task = try store.enqueue(
            taskID: "drift-task",
            parentID: "drift-parent",
            providerID: "provider",
            modelID: "model"
        )
        let run = try store.startRun(
            taskID: task.taskID,
            parentID: task.parentID,
            runID: "drift-run"
        )
        let attemptID = try #require(store.canonicalAttemptID(runID: run.runID))
        let envelope = ChildResultEnvelope(
            taskID: task.taskID,
            runID: run.runID,
            attemptID: attemptID,
            parentContextSnapshotID: task.parentContextSnapshotID,
            childExecutionID: "drift-execution",
            outcome: .succeeded,
            resultDigest: "sha256:original"
        )
        let receipt = try store.settleChildResult(envelope)
        #expect(try store.settleChildResult(envelope) == receipt)

        let drifted = ChildResultEnvelope(
            taskID: envelope.taskID,
            runID: envelope.runID,
            attemptID: envelope.attemptID,
            parentContextSnapshotID: envelope.parentContextSnapshotID,
            childExecutionID: envelope.childExecutionID,
            outcome: .failed(reason: "drift"),
            resultDigest: "sha256:drift"
        )
        #expect(throws: AgentTaskStoreError.childResultIdempotencyConflict) {
            try store.settleChildResult(drifted)
        }
        #expect(store.allReceipts() == [receipt])
    }

    @Test("cancelled run rejects a late success envelope")
    func cancelledRunRejectsLateEnvelope() throws {
        let store = AgentTaskStore()
        let task = try store.enqueue(
            taskID: "cancel-task",
            parentID: "cancel-parent",
            providerID: "provider",
            modelID: "model"
        )
        let run = try store.startRun(
            taskID: task.taskID,
            parentID: task.parentID,
            runID: "cancel-run"
        )
        let attemptID = try #require(store.canonicalAttemptID(runID: run.runID))
        _ = try store.finish(runID: run.runID, outcome: .cancelled)
        let late = ChildResultEnvelope(
            taskID: task.taskID,
            runID: run.runID,
            attemptID: attemptID,
            parentContextSnapshotID: task.parentContextSnapshotID,
            childExecutionID: "cancel-execution",
            outcome: .succeeded,
            resultDigest: "sha256:late"
        )

        #expect(throws: AgentTaskStoreError.childResultCancelled) {
            try store.settleChildResult(late)
        }
        #expect(store.receipt(runID: run.runID)?.outcome == .cancelled)
    }

    @Test("reload preserves exact envelope replay and rejects stale identity")
    func reloadedStoreRejectsStaleAttemptAndAcceptsExactReplay() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("H2-v2-reload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledgerURL = directory.appendingPathComponent("ledger.json")

        let store = try AgentTaskStore(persistenceURL: ledgerURL)
        let task = try store.enqueue(
            taskID: "reload-task",
            parentID: "reload-parent",
            providerID: "provider",
            modelID: "model"
        )
        let run = try store.startRun(
            taskID: task.taskID,
            parentID: task.parentID,
            runID: "reload-run"
        )
        let attemptID = try #require(store.canonicalAttemptID(runID: run.runID))
        let envelope = ChildResultEnvelope(
            taskID: task.taskID,
            runID: run.runID,
            attemptID: attemptID,
            parentContextSnapshotID: task.parentContextSnapshotID,
            childExecutionID: "reload-execution",
            outcome: .succeeded,
            resultDigest: "sha256:reload"
        )
        let receipt = try store.settleChildResult(envelope)

        let reloaded = try AgentTaskStore(persistenceURL: ledgerURL)
        #expect(try reloaded.settleChildResult(envelope) == receipt)
        let stale = ChildResultEnvelope(
            taskID: envelope.taskID,
            runID: envelope.runID,
            attemptID: "reload-run:attempt:0",
            parentContextSnapshotID: envelope.parentContextSnapshotID,
            childExecutionID: envelope.childExecutionID,
            outcome: .succeeded,
            resultDigest: "sha256:stale"
        )
        #expect(throws: AgentTaskStoreError.childResultIdentityMismatch) {
            try reloaded.settleChildResult(stale)
        }
    }

    @Test("reopen rejects a durable envelope whose attempt binding drifted")
    func reloadedStoreRejectsPersistedAttemptDrift1776() throws {
        let profile = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = profile.rootDirectory.appendingPathComponent("child1776-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ledgerURL = root.appendingPathComponent("tasks.json")
        let store = try AgentTaskStore(persistenceURL: ledgerURL)
        let task = try store.enqueue(taskID: "1776-child", parentID: "1776-parent",
            providerID: "provider", modelID: "model")
        let run = try store.startRun(taskID: task.taskID, parentID: task.parentID,
            runID: "1776-run")
        let attemptID = try #require(store.canonicalAttemptID(runID: run.runID))
        let envelope = ChildResultEnvelope(taskID: task.taskID, runID: run.runID,
            attemptID: attemptID, parentContextSnapshotID: task.parentContextSnapshotID,
            childExecutionID: "1776-execution", outcome: .succeeded,
            resultDigest: "sha256:1776")
        let receipt = try store.settleChildResult(envelope)
        let reopened = try AgentTaskStore(persistenceURL: ledgerURL)
        #expect(reopened.childResultEnvelope(taskID: task.taskID,
            parentID: task.parentID, runID: run.runID) == envelope)
        #expect(try reopened.settleChildResult(envelope) == receipt)

        let original = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: ledgerURL)) as? [String: Any])
        func state(from document: [String: Any]) throws -> [String: Any] {
            try #require(document["state"] as? [String: Any])
        }
        func writeInvalid(_ document: [String: Any], name: String) throws {
            let url = root.appendingPathComponent(name)
            try JSONSerialization.data(withJSONObject: document).write(to: url)
            #expect(throws: AgentTaskStoreError.persistenceFailed) {
                _ = try AgentTaskStore(persistenceURL: url)
            }
        }

        // The value remains positive and Codable, but no longer names the
        // durable attempt number that produced this receipt.
        var numberDrift = original
        var numberState = try state(from: numberDrift)
        var receipts = try #require(numberState["receiptByRunID"] as? [String: Any])
        var receiptRecord = try #require(receipts[run.runID] as? [String: Any])
        var envelopeRecord = try #require(receiptRecord["childResultEnvelope"] as? [String: Any])
        envelopeRecord["attemptNumber"] = 2
        receiptRecord["childResultEnvelope"] = envelopeRecord
        receipts[run.runID] = receiptRecord
        numberState["receiptByRunID"] = receipts
        numberDrift["state"] = numberState
        try writeInvalid(numberDrift, name: "wrong-number.json")

        // A second attempt entry for the same run is syntactically valid, yet
        // the canonical map must not be allowed to redirect the stored receipt.
        var canonicalDrift = original
        var canonicalState = try state(from: canonicalDrift)
        var attempts = try #require(canonicalState["attempts"] as? [String: Any])
        var copiedAttempt = try #require(attempts[attemptID] as? [String: Any])
        let foreignAttemptID = "1776-run:attempt:2"
        copiedAttempt["attemptID"] = foreignAttemptID
        copiedAttempt["attempt"] = 2
        attempts[foreignAttemptID] = copiedAttempt
        canonicalState["attempts"] = attempts
        var canonicalMap = try #require(canonicalState["attemptIDByRunID"] as? [String: Any])
        canonicalMap[run.runID] = foreignAttemptID
        canonicalState["attemptIDByRunID"] = canonicalMap
        canonicalDrift["state"] = canonicalState
        try writeInvalid(canonicalDrift, name: "wrong-canonical-attempt.json")
    }
}

private struct EnvelopeSettlementExecutor: ToolExecutor {
    func execute(name: String, input: [String: Any]) async throws -> String {
        "ok"
    }
}

private struct EnvelopeSettlementProvider: LLMProvider {
    let name = "envelope-settlement-provider"
    var model = LLMModel(
        id: "envelope-settlement-model",
        displayName: "Envelope settlement model",
        provider: "envelope-settlement-provider"
    )
    let capabilities: Set<ProviderCapability> = [.streaming]

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        LLMResponse(text: "child complete", stopReason: "stop", usage: nil)
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
