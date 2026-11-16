import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-TASK-12 canonical task destinations")
struct P3AcceptanceM04_TaskDestinationConsumerTests {
    @Test("source session opens from exact task provenance and rejects stale or foreign identity")
    func sourceSessionDestinationRevalidatesTaskAndTranscript() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("m04-task-destination-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let sourceA = try sessions.createSession(id: "synthetic-source-A", title: "A")
        let sourceB = try sessions.createSession(id: "synthetic-source-B", title: "B")
        try sessions.saveMessage(
            LLMMessage(role: .user, content: "A 的原始请求"), sessionID: sourceA.id
        )
        try sessions.saveMessage(
            LLMMessage(role: .assistant, content: "A 的回复"), sessionID: sourceA.id
        )
        try sessions.saveMessage(
            LLMMessage(role: .user, content: "B 的私有请求"), sessionID: sourceB.id
        )

        let tasks = AgentTaskStore()
        let source = ParentRuntimeIdentity(
            sessionID: sourceA.id, conversationID: "conversation-A",
            turnID: "turn-A", taskID: "parent-A", actorID: "actor-A"
        )
        let creation = SessionActionCreationMetadata(
            scopeID: "scope-A", idempotencyKey: "create-A",
            action: .new(title: "A 的任务", projectID: "synthetic", source: source)
        )
        _ = try tasks.enqueueIdempotent(
            taskID: "task-A", parentID: "parent-A",
            providerID: "offline", modelID: "synthetic", creation: creation
        )
        let consumer = TaskCenterControlConsumer(
            store: tasks, childTranscriptSessionStore: sessions
        )
        let row = try #require(consumer.receiptRows().first)
        let navigation = try #require(consumer.sourceSessionNavigation(for: row))
        #expect(navigation.sourceSessionID == sourceA.id)
        let transcript = try #require(consumer.sourceTranscript(navigation: navigation))
        #expect(transcript.messages.map(\.content) == ["A 的原始请求", "A 的回复"])
        #expect(!transcript.messages.map(\.content).joined().contains("B 的私有请求"))

        let foreign = TaskCenterSourceSessionNavigation(
            taskID: navigation.taskID, parentID: navigation.parentID,
            sourceSessionID: sourceB.id, runID: navigation.runID,
            attemptID: navigation.attemptID
        )
        #expect(consumer.sourceTranscript(navigation: foreign) == nil)

        _ = try tasks.startRun(
            taskID: navigation.taskID, parentID: navigation.parentID,
            runID: "run-A"
        )
        #expect(consumer.sourceTranscript(navigation: navigation) == nil)
    }

    @Test("tasks with unknown provenance have no source destination")
    func unknownSourceNeverBorrowsTheCurrentSession() throws {
        let tasks = AgentTaskStore()
        _ = try tasks.enqueue(
            taskID: "legacy-task", parentID: "synthetic-source-A",
            providerID: "offline", modelID: "synthetic"
        )
        let consumer = TaskCenterControlConsumer(store: tasks)
        let row = try #require(consumer.receiptRows().first)
        #expect(row.sourceSessionID == nil)
        #expect(consumer.sourceSessionNavigation(for: row) == nil)
    }

    @Test("result opens only the exact canonical task attempt without exporting evidence refs")
    func resultDestinationUsesCurrentEnvelopeIdentity() throws {
        let tasks = AgentTaskStore()
        let task = try tasks.enqueue(
            taskID: "result-task", parentID: "result-parent",
            providerID: "offline", modelID: "synthetic",
            parentContextSnapshotID: "synthetic-context"
        )
        let run = try tasks.startRun(
            taskID: task.taskID, parentID: task.parentID, runID: "result-run"
        )
        let attempt = try #require(tasks.attempts(runID: run.runID).first)
        _ = try tasks.settleChildResult(ChildResultEnvelope(
            taskID: task.taskID, runID: run.runID,
            attemptID: attempt.attemptID,
            parentContextSnapshotID: task.parentContextSnapshotID,
            childExecutionID: "synthetic-child-execution",
            outcome: .succeeded, resultDigest: "synthetic-digest",
            evidenceRefs: ["synthetic-private-reference"],
            output: "合成任务结果"
        ))

        let consumer = TaskCenterControlConsumer(store: tasks)
        let row = try #require(consumer.receiptRows().first)
        let navigation = try #require(consumer.resultNavigation(for: row))
        let detail = try #require(consumer.resultDetail(navigation: navigation))
        #expect(detail.statusTitle == "已完成")
        #expect(detail.displayOutput == "合成任务结果")
        #expect(detail.outputDigest == "synthetic-digest")
        #expect(detail.evidenceCount == 1)
        #expect(detail.displayOutput?.contains("synthetic-private-reference") == false)

        let foreignAttempt = TaskCenterResultNavigation(
            taskID: navigation.taskID, parentID: navigation.parentID,
            runID: navigation.runID, attemptID: "foreign-attempt",
            resultIdempotencyKey: navigation.resultIdempotencyKey
        )
        #expect(consumer.resultDetail(navigation: foreignAttempt) == nil)
    }
}
