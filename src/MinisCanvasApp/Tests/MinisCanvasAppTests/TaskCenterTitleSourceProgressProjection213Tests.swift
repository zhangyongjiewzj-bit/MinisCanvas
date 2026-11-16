import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// P3-TASK-01 focused projections: the Task Center row surface must carry the
/// canonical user-authored title, the canonical source session, and the
/// canonical event-ledger progress — and must invent none of them when the
/// store holds no such fact (real dispatched agent children).
@Suite("Task Center title/source/progress canonical projection")
struct TaskCenterTitleSourceProgressProjection213Tests {
    private var creationSource: ParentRuntimeIdentity {
        ParentRuntimeIdentity(
            sessionID: "source-session-213",
            conversationID: "conversation-213",
            turnID: "turn-handle:213",
            taskID: "parent-213",
            actorID: "actor-213"
        )
    }

    private func creationMetadata(title: String) -> SessionActionCreationMetadata {
        SessionActionCreationMetadata(
            scopeID: "scope-213",
            idempotencyKey: "create-213-\(UUID().uuidString)",
            action: .new(
                title: title,
                projectID: "project-213",
                workingDirectory: "/tmp/project-213",
                switchAfterCreate: false,
                source: creationSource
            )
        )
    }

    @Test
    func sessionCreatedTaskProjectsCanonicalTitleAndSource() throws {
        let store = AgentTaskStore()
        _ = try store.enqueueIdempotent(
            taskID: "created-task",
            parentID: "parent-213",
            providerID: "offline",
            modelID: "test",
            creation: creationMetadata(title: "重建角色设定工作流")
        )
        let row = try #require(
            TaskCenterControlConsumer(store: store)
                .receiptRows()
                .first { $0.taskID == "created-task" }
        )
        #expect(row.userTitle == "重建角色设定工作流")
        #expect(row.sourceSessionID == "source-session-213")
        #expect(row.accessibilityLabel.contains("标题 重建角色设定工作流"))
        #expect(row.accessibilityLabel.contains("来源会话 source-session-213"))
    }

    @Test
    func realAgentChildIsProjectedWithLedgerProgress() throws {
        let store = AgentTaskStore()
        let task = try store.enqueue(
            taskID: "agent-child-213",
            parentID: "parent-213",
            providerID: "offline",
            modelID: "test",
            parentContextSnapshotID: "session-213"
        )
        let run = try store.startRun(
            taskID: task.taskID,
            parentID: task.parentID,
            runID: "run-213"
        )
        _ = try store.appendEvent(runID: run.runID, kind: .started, detail: "child-dispatched")
        _ = try store.appendEvent(runID: run.runID, kind: .progress, detail: "child-supervisor-started")

        let consumer = TaskCenterControlConsumer(store: store)
        let row = try #require(consumer.receiptRows().first { $0.taskID == "agent-child-213" })
        // A dispatched agent child has no canonical title or creation source;
        // the projection must keep both nil instead of fabricating values.
        #expect(row.userTitle == nil)
        #expect(row.sourceSessionID == nil)
        #expect(!row.accessibilityLabel.contains("标题"))
        #expect(row.lastEventKind == .progress)
        #expect(row.observationIdentity.eventSequence == 2)
        #expect(row.currentStepTitle == "进展")
        #expect(row.eventProgressTitle == "事件 2（进展）")
        #expect(row.durationTitle() == "未记录")
        #expect(row.resultSummaryTitle == "尚无结果")
        #expect(row.cancelAvailable)
    }

    @Test
    func legacyRowJSONDecodesWithoutNewFields() throws {
        let store = AgentTaskStore()
        _ = try store.enqueueIdempotent(
            taskID: "legacy-decode-task",
            parentID: "parent-213",
            providerID: "offline",
            modelID: "test",
            creation: creationMetadata(title: "旧账本回链任务")
        )
        let row = try #require(
            TaskCenterControlConsumer(store: store)
                .receiptRows()
                .first { $0.taskID == "legacy-decode-task" }
        )
        #expect(row.userTitle == "旧账本回链任务")

        var payload = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any]
        )
        payload.removeValue(forKey: "userTitle")
        let legacyData = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try JSONDecoder().decode(TaskCenterReceiptRow.self, from: legacyData)
        #expect(decoded.userTitle == nil)
        #expect(decoded.lastEventKind == nil)
        #expect(decoded.eventProgressTitle == nil)
        #expect(decoded.taskID == row.taskID)
        #expect(decoded.sourceSessionID == row.sourceSessionID)
    }

    @Test
    func projectionIsReadOnlyAndStable() throws {
        let store = AgentTaskStore()
        let task = try store.enqueue(
            taskID: "stable-task",
            parentID: "parent-213",
            providerID: "offline",
            modelID: "test"
        )
        _ = try store.startRun(taskID: task.taskID, parentID: task.parentID, runID: "run-stable")
        let consumer = TaskCenterControlConsumer(store: store)
        let ledgerBefore = store.taskCenterSnapshots()
        let first = consumer.receiptRows(now: Date(timeIntervalSince1970: 1_850_000_000))
        let second = consumer.receiptRows(now: Date(timeIntervalSince1970: 1_850_000_000))
        #expect(first == second)
        #expect(store.taskCenterSnapshots() == ledgerBefore)
        #expect(store.snapshot(taskID: task.taskID, parentID: task.parentID)?.status == .running)
    }

    @Test
    func eventKindTitlesAreTotal() {
        let kinds: [AgentTaskEventKind?] = [
            .started, .progress, .approvalRequired, .inputRequired,
            .submissionUnknown, .completed, .failed, .cancelled,
            .terminalDuplicate, nil
        ]
        var titles: Set<String> = []
        for kind in kinds {
            let title = TaskCenterEventKindLabel.title(for: kind)
            #expect(!title.isEmpty)
            titles.insert(title)
        }
        #expect(titles.count == kinds.count)
    }
}
