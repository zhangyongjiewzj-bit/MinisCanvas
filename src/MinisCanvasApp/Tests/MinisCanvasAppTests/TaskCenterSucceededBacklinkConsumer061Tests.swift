import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

// QODER-DEV-W5-TASKCENTER-SUCCEEDED-061 (wave-5, 2026-09-22):
// 1. A settled child-task success must project a durable terminal backlink
//    (run/attempt/terminal-event identity plus bounded digest) through the
//    canonical receiptRows pipeline and the derived succeededBacklinks API.
// 2. Nothing may be projected as a success before it is proven: unsettled,
//    failed and cancelled work keeps the backlink unrecorded.
// 3. The projection survives a ledger reopen because it is derived only from
//    durable canonical store facts, not from an in-memory UI state source.
// 4. orchestrationTaskStore verdict: it is a test-only identity seam
//    ("not a second state source"); production has no reader of the property.
//    These tests pin the durable contract instead of inventing a consumer:
//    when orchestration is attached, its ledger is identical to the canonical
//    store Task Center already projects, and with the default composition no
//    orchestration ledger is attached at all.
@Suite("Task Center 061 succeeded terminal backlink consumer")
struct TaskCenterSucceededBacklinkConsumer061Tests {

    @Test func settledChildSuccessProjectsCanonicalTerminalBacklink() throws {
        let store = AgentTaskStore()
        let task = try store.enqueue(
            taskID: "child-061-task",
            parentID: "parent-061",
            providerID: "offline",
            modelID: "test",
            parentContextSnapshotID: "session-061"
        )
        let run = try store.startRun(
            taskID: task.taskID,
            parentID: task.parentID,
            runID: "child-061-run"
        )
        let envelope = ChildResultEnvelope(
            taskID: task.taskID,
            runID: run.runID,
            attemptID: "\(run.runID):attempt:1",
            parentContextSnapshotID: task.parentContextSnapshotID,
            childExecutionID: "child-061-execution",
            outcome: .succeeded,
            outputDigest: "digest-061",
            evidenceRefs: ["artifact-061"],
            idempotencyKey: "child-061-idempotency"
        )
        _ = try store.settleChildResult(envelope)

        let consumer = TaskCenterControlConsumer(store: store)
        let row = try #require(consumer.receiptRows().first)
        #expect(row.lifecycleState == .completed)
        #expect(row.observationState == .terminal)
        let backlink = try #require(row.succeededBacklink)
        #expect(backlink.taskID == task.taskID)
        #expect(backlink.parentID == task.parentID)
        #expect(backlink.sourceSessionID == task.sourceSessionID)
        #expect(backlink.runID == run.runID)
        #expect(backlink.attemptID == envelope.attemptID)
        #expect(backlink.terminalEventSequence == store.events(runID: run.runID).last?.sequence)
        #expect(backlink.resultIdempotencyKey == envelope.idempotencyKey)
        #expect(backlink.outputDigest == "digest-061")
        #expect(backlink.evidenceReferences == ["artifact-061"])
        #expect(
            consumer.succeededBacklinks().map(\.taskID) == [task.taskID]
        )
        #expect(backlink.accessibilityLabel.contains("成功回执回链"))
        #expect(row.accessibilityLabel.contains("成功回执回链"))
    }

    @Test func plainFinishedSuccessProjectsBacklinkWithoutEnvelopeFields() throws {
        let store = AgentTaskStore()
        let task = try store.enqueue(
            taskID: "plain-061-task",
            parentID: "parent-061-plain",
            providerID: "offline",
            modelID: "test"
        )
        let run = try store.startRun(
            taskID: task.taskID,
            parentID: task.parentID,
            runID: "plain-061-run"
        )
        let receipt = try store.finish(runID: run.runID, outcome: .succeeded)

        let row = try #require(TaskCenterControlConsumer(store: store).receiptRows().first)
        let backlink = try #require(row.succeededBacklink)
        #expect(backlink.runID == receipt.runID)
        #expect(backlink.attemptID == receipt.attemptID)
        #expect(backlink.resultIdempotencyKey == nil)
        #expect(backlink.outputDigest == nil)
        #expect(backlink.evidenceReferences.isEmpty)
    }

    @Test func unsettledFailedAndCancelledSuccessBacklinkStaysUnrecorded() throws {
        let store = AgentTaskStore()

        let running = try store.enqueue(
            taskID: "running-061",
            parentID: "parent-061-unsettled",
            providerID: "offline",
            modelID: "test"
        )
        _ = try store.startRun(
            taskID: running.taskID,
            parentID: running.parentID,
            runID: "running-061-run"
        )

        let failed = try store.enqueue(
            taskID: "failed-061",
            parentID: "parent-061-failed",
            providerID: "offline",
            modelID: "test"
        )
        let failedRun = try store.startRun(
            taskID: failed.taskID,
            parentID: failed.parentID,
            runID: "failed-061-run"
        )
        _ = try store.finish(runID: failedRun.runID, outcome: .failed(reason: "redacted"))

        let cancelled = try store.enqueue(
            taskID: "cancelled-061",
            parentID: "parent-061-cancelled",
            providerID: "offline",
            modelID: "test"
        )
        let cancelledRun = try store.startRun(
            taskID: cancelled.taskID,
            parentID: cancelled.parentID,
            runID: "cancelled-061-run"
        )
        _ = try store.finish(runID: cancelledRun.runID, outcome: .cancelled)

        let rows = TaskCenterControlConsumer(store: store).receiptRows()
        #expect(rows.count == 3)
        #expect(rows.allSatisfy { $0.succeededBacklink == nil })
        #expect(TaskCenterControlConsumer(store: store).succeededBacklinks().isEmpty)
    }

    @Test func successBacklinkSurvivesLedgerReopen() throws {
        try BB7AffectedOwnedDirectory.withDirectory { directory in
        let ledgerURL = directory.appendingPathComponent("agent-tasks.json")

        let expected: TaskCenterSucceededBacklink
        do {
            let store = try AgentTaskStore(persistenceURL: ledgerURL)
            let task = try store.enqueue(
                taskID: "durable-061",
                parentID: "parent-061-durable",
                providerID: "offline",
                modelID: "test",
                parentContextSnapshotID: "session-061-durable"
            )
            let run = try store.startRun(
                taskID: task.taskID,
                parentID: task.parentID,
                runID: "durable-061-run"
            )
            let envelope = ChildResultEnvelope(
                taskID: task.taskID,
                runID: run.runID,
                attemptID: "\(run.runID):attempt:1",
                parentContextSnapshotID: task.parentContextSnapshotID,
                childExecutionID: "durable-061-execution",
                outcome: .succeeded,
                outputDigest: "digest-061-durable",
                idempotencyKey: "durable-061-idempotency"
            )
            _ = try store.settleChildResult(envelope)
            expected = try #require(
                TaskCenterControlConsumer(store: store).receiptRows().first?.succeededBacklink
            )
        }

        let reopened = try AgentTaskStore(persistenceURL: ledgerURL)
        let restored = try #require(
            TaskCenterControlConsumer(store: reopened).receiptRows().first?.succeededBacklink
        )
        #expect(restored == expected)
        }
    }

    @Test func archivedSuccessOnlyAppearsWithIncludeArchived() throws {
        let store = AgentTaskStore()
        let task = try store.enqueue(
            taskID: "archived-061",
            parentID: "parent-061-archive",
            providerID: "offline",
            modelID: "test"
        )
        let run = try store.startRun(
            taskID: task.taskID,
            parentID: task.parentID,
            runID: "archived-061-run"
        )
        _ = try store.finish(runID: run.runID, outcome: .succeeded)
        let consumer = TaskCenterControlConsumer(store: store)
        let row = try #require(consumer.receiptRows().first)
        #expect(row.archiveAvailable)
        #expect(row.succeededBacklink != nil)

        _ = try consumer.applyArchive(
            TaskCenterArchiveRequest(
                taskID: task.taskID,
                parentID: task.parentID,
                actorID: "w5-061-test",
                idempotencyKey: "w5-061-archive:\(task.taskID)",
                action: .archive
            )
        )
        #expect(consumer.succeededBacklinks().isEmpty)
        #expect(
            consumer.succeededBacklinks(includeArchived: true).map(\.taskID) == [task.taskID]
        )
    }
}

@Suite("Task Center 061 orchestration ledger seam verdict")
@MainActor
struct TaskCenterOrchestrationLedger061VerdictTests {
    // Verdict recorded by this lane (确证未接): `BridgeStore.orchestrationTaskStore`
    // (BridgeStore.swift:654) has no production consumer in this candidate. It is
    // documented at its declaration as an identity seam for production wiring
    // tests and explicitly "not a second state source". This lane does not
    // invent a fake consumer for it; instead these assertions pin the durable
    // contract the seam guarantees: attached orchestration shares the exact
    // canonical ledger Task Center projects, and the default composition never
    // attaches a second ledger at all.

    @Test func defaultCompositionAttachesNoOrchestrationLedger() {
        let bridge = BridgeStore()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("w5-061-orchestration-default-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        bridge.attachProductionServices(sessionDirectory: directory)
        #expect(bridge.orchestrationTaskStore == nil)
    }

    @Test func attachedOrchestrationLedgerIsTheCanonicalTaskCenterStore() throws {
        let bridge = BridgeStore()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("w5-061-orchestration-attached-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        ProductionOrchestrationDefaults.attachProductionServices(
            to: bridge,
            sessionDirectory: directory
        )
        let orchestrationStore = try #require(bridge.orchestrationTaskStore)
        // Identity seam, not a second state source: the orchestrator ledger and
        // the canonical store projected by Task Center are the same instance.
        #expect(orchestrationStore === bridge.agentTaskStore)

        let task = try orchestrationStore.enqueue(
            taskID: "w5-061-through-orchestration",
            parentID: "parent-061-shared",
            providerID: "offline",
            modelID: "test"
        )
        let run = try orchestrationStore.startRun(
            taskID: task.taskID,
            parentID: task.parentID,
            runID: "w5-061-shared-run"
        )
        _ = try orchestrationStore.finish(runID: run.runID, outcome: .succeeded)

        // The single projection pipeline already surfaces success written through
        // either name of the ledger; no parallel observation path exists.
        let row = try #require(
            bridge.taskCenterControlConsumer.receiptRows()
                .first { $0.taskID == task.taskID }
        )
        #expect(row.succeededBacklink?.runID == run.runID)
    }
}
