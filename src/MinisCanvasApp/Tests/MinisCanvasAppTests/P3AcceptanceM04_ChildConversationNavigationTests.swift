import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-AGENT-09 persisted child conversation consumer")
struct P3AcceptanceM04_ChildConversationNavigationTests {
    @Test("active parent projects only its unknown-source children and their ledger states")
    func activeParentScopesChildProgressWithoutLeakingOtherSession() throws {
        let tasks = AgentTaskStore()
        _ = try tasks.enqueue(
            taskID: "parent-A", parentID: "root-A",
            providerID: "offline", modelID: "synthetic"
        )
        _ = try tasks.enqueue(
            taskID: "parent-B", parentID: "root-B",
            providerID: "offline", modelID: "synthetic"
        )
        for (taskID, parentID) in [
            ("A-running", "parent-A"), ("A-approval", "parent-A"),
            ("A-failed", "parent-A"), ("A-completed", "parent-A"),
            ("B-running", "parent-B")
        ] {
            _ = try tasks.enqueue(
                taskID: taskID, parentID: parentID,
                providerID: "offline", modelID: "synthetic"
            )
            let run = try tasks.startRun(
                taskID: taskID, parentID: parentID, runID: "run-\(taskID)"
            )
            _ = try tasks.appendEvent(
                runID: run.runID, kind: .started, detail: "synthetic-start"
            )
            switch taskID {
            case "A-running":
                _ = try tasks.appendEvent(
                    runID: run.runID, kind: .progress, detail: "synthetic-progress"
                )
            case "A-approval":
                _ = try tasks.appendEvent(
                    runID: run.runID, kind: .approvalRequired, detail: "synthetic-approval"
                )
            case "A-failed":
                _ = try tasks.finish(runID: run.runID, outcome: .failed(reason: "synthetic-failure"))
            case "A-completed":
                _ = try tasks.finish(runID: run.runID, outcome: .succeeded)
            default:
                break
            }
        }

        let rows = TaskCenterControlConsumer(store: tasks).receiptRows()
        #expect(rows.allSatisfy { $0.sourceSessionID == nil })
        let scopedSnapshots = TaskCenterObservationSnapshot(taskStore: tasks)
            .taskSnapshots.filter {
                ChatInspectorTaskScope.includes(
                    sourceSessionID: $0.sourceSessionID,
                    taskID: $0.taskID, parentID: $0.parentID,
                    viewerSessionID: "session-A", currentTaskID: "parent-A"
                )
            }
        #expect(scopedSnapshots.count == 5)
        let scopedA = rows.filter {
            ChatInspectorTaskScope.includes(
                sourceSessionID: $0.sourceSessionID,
                taskID: $0.taskID, parentID: $0.parentID,
                viewerSessionID: "session-A", currentTaskID: "parent-A"
            )
        }
        #expect(Set(scopedA.map(\.taskID)) == [
            "parent-A", "A-running", "A-approval", "A-failed", "A-completed"
        ])
        #expect(scopedA.first { $0.taskID == "A-running" }?.lastEventKind == .progress)
        #expect(scopedA.first { $0.taskID == "A-approval" }?.lifecycleState == .approvalRequired)
        #expect(scopedA.first { $0.taskID == "A-failed" }?.lifecycleState == .failed)
        #expect(scopedA.first { $0.taskID == "A-completed" }?.lifecycleState == .completed)
        #expect(rows.filter {
            ChatInspectorTaskScope.includes(
                sourceSessionID: $0.sourceSessionID,
                taskID: $0.taskID, parentID: $0.parentID,
                viewerSessionID: "session-B", currentTaskID: "parent-B"
            )
        }.map(\.taskID).sorted() == ["B-running", "parent-B"])
        #expect(rows.filter {
            ChatInspectorTaskScope.includes(
                sourceSessionID: $0.sourceSessionID,
                taskID: $0.taskID, parentID: $0.parentID,
                viewerSessionID: "session-A", currentTaskID: nil
            )
        }.isEmpty)
    }

    @Test("ledger-bound child content reopens after restart without changing its parent")
    func childTranscriptReopensWithFrozenParentIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("m04-child-navigation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionsURL = root.appendingPathComponent("sessions", isDirectory: true)
        let ledgerURL = root.appendingPathComponent("agent-tasks.json")
        let sessions = SessionStore(directory: sessionsURL)
        let parent = try sessions.createSession(id: "synthetic-parent", title: "父会话")
        try sessions.saveMessage(
            LLMMessage(role: .user, content: "父会话原文"), sessionID: parent.id
        )
        let parentBefore = try #require(sessions.loadSession(id: parent.id))

        let tasks = try AgentTaskStore(persistenceURL: ledgerURL)
        let task = try tasks.enqueue(
            taskID: "synthetic-child-task", parentID: parent.id,
            providerID: "offline", modelID: "synthetic",
            parentContextSnapshotID: "frozen-parent-context"
        )
        let run = try tasks.startRun(
            taskID: task.taskID, parentID: task.parentID, runID: "synthetic-child-run"
        )
        let attempt = try #require(tasks.attempts(runID: run.runID).first)
        let child = try sessions.forkSession(
            from: parent.id, id: "synthetic-child-session", title: "子会话",
            throughMessageIndex: 0,
            createdByTaskID: task.taskID, createdByRunID: run.runID
        )
        try sessions.saveMessage(
            LLMMessage(role: .user, content: "子任务输入"), sessionID: child.id
        )
        try sessions.saveMessage(
            LLMMessage(role: .assistant, content: "子任务结果"), sessionID: child.id
        )
        // T1-3：工具调用和结果在记录里已被概括/省略，任务中心要显示工具名，而不只是“已省略”。
        try sessions.saveMessage(
            LLMMessage(role: .assistant, content: "[工具调用参数已省略]\n工具：file_read <path>",
                       toolCalls: [LLMToolCall(id: "call-1", name: "file_read", rawArguments: "{}", arguments: [:])]),
            sessionID: child.id
        )
        try sessions.saveMessage(
            LLMMessage(role: .tool, content: "[工具结果内容已省略]", toolCallID: "call-1"), sessionID: child.id
        )
        let locator = ChildTranscriptLocator(
            childSessionID: child.id, parentSessionID: parent.id,
            taskID: task.taskID, parentID: task.parentID,
            runID: run.runID, attemptID: attempt.attemptID,
            childExecutionID: "synthetic-child-execution",
            parentContextSnapshotID: task.parentContextSnapshotID,
            lineageVersion: child.lineageVersion
        )
        _ = try tasks.bindChildTranscript(locator)
        _ = try tasks.settleChildResult(ChildResultEnvelope(
            taskID: task.taskID, runID: run.runID,
            attemptID: attempt.attemptID,
            parentContextSnapshotID: task.parentContextSnapshotID,
            childExecutionID: locator.childExecutionID,
            outcome: .succeeded, resultDigest: "synthetic-digest",
            childTranscriptLocator: locator
        ))

        let consumer = TaskCenterControlConsumer(
            store: tasks, childTranscriptSessionStore: sessions
        )
        let row = try #require(consumer.receiptRows().first {
            $0.taskID == task.taskID && $0.parentID == task.parentID
        })
        let navigation = try #require(row.childNavigation)
        #expect(navigation.parentSessionID == parent.id)
        #expect(navigation.childSessionID == child.id)
        let first = try #require(consumer.childTranscript(navigation: navigation))
        #expect(first.messages.map(\.roleTitle) == ["任务输入", "子代理", "子代理", "工具结果"])
        #expect(first.messages.map(\.content) == [
            "子任务输入", "子任务结果",
            "[工具调用参数已省略]\n工具：file_read <path>",
            "[工具结果内容已省略] 工具：file_read",
        ])

        let reopenedSessions = SessionStore(directory: sessionsURL)
        let reopenedTasks = try AgentTaskStore(persistenceURL: ledgerURL)
        let reopenedConsumer = TaskCenterControlConsumer(
            store: reopenedTasks, childTranscriptSessionStore: reopenedSessions
        )
        let reopened = try #require(reopenedConsumer.childTranscript(navigation: navigation))
        #expect(reopened.navigation == navigation)
        #expect(reopened.messages == first.messages)
        #expect(reopenedSessions.loadSession(id: parent.id) == parentBefore)
    }
}
