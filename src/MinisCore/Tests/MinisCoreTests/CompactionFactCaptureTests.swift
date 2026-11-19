import Foundation
import Testing
@testable import MinisCore

@Suite("Compaction canonical fact capture")
struct CompactionFactCaptureTests {
    @Test func captureExcludesForeignSessionAndRequiresFullReceiptIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("compact-fact-capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts.json"))
        for session in ["source", "foreign"] {
            let identity = AgentExecutionIdentity(turn: .init(sessionID: session, turnID: 2,
                messageID: "message"), operationID: "operation", attempt: 1)
            let receipt = try ledger.mint(toolCallID: "same-call", toolName: "file_read",
                attemptID: "attempt", attemptNumber: 1, executionIdentity: identity)
            // 只有非成功终态的回执才会被带进压缩背景。
            _ = try ledger.settle(receipt, status: .failed)
        }
        let messages = [LLMMessage(role: .user, content: "Continue safely")]
        let facts = CompactionFactCapture.capture(sessionID: "source", revision: 7,
            messages: messages, taskStore: nil, effectLedger: ledger)
        #expect(facts.count == 1)
        let source = try #require(facts.first?.source)
        #expect(source.sessionID == "source")
        #expect(source.transcriptRevision == 7)
        #expect(source.matchesTranscript(messages))
        #expect(!source.matchesTranscript([.init(role: .user, content: "changed source")]))
        #expect(CompactionFactCapture.verifyStores(facts, taskStore: nil,
            effectLedger: ledger))
        #expect(!CompactionFactCapture.verifyStores(facts, taskStore: nil,
            effectLedger: ToolExecutionFactLedger()))
        let background = try #require(CompactionFactCapture.backgroundMessage(facts))
        #expect(background.toolCalls.isEmpty)
        #expect(background.toolCallID == nil)
        #expect(background.content.contains("No authorization"))
        #expect(background.content.contains("Do not replay"))
        #expect(ledger.facts.count == 2)
        #expect(ledger.pendingReceipts.isEmpty)
    }

    @Test func captureDropsEverySucceededReceiptAndKeepsOnlyFailedOrCancelledOnes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("compact-fact-bound-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts.json"))
        // 600 条成功回执（超过检查点 512 条上限）加 1 条失败、1 条取消。
        let total = 600
        for index in 0..<total {
            let identity = AgentExecutionIdentity(turn: .init(sessionID: "source", turnID: 2,
                messageID: "message-\(index)"), operationID: "operation-\(index)", attempt: 1)
            let receipt = try ledger.mint(toolCallID: "call-\(index)", toolName: "file_read",
                attemptID: "attempt-\(index)", attemptNumber: 1, executionIdentity: identity)
            let status: ToolExecutionStatus = index == 0 ? .failed : (index == total - 1 ? .cancelled : .succeeded)
            _ = try ledger.settle(receipt, status: status)
        }
        let messages = [LLMMessage(role: .user, content: "Continue safely")]
        let facts = CompactionFactCapture.capture(sessionID: "source", revision: 1,
            messages: messages, taskStore: nil, effectLedger: ledger)
        let calls = facts.compactMap { $0.source?.effect?.toolCallID }
        #expect(calls == ["call-0", "call-\(total - 1)"])
        #expect(CompactionFactCapture.verifyStores(facts, taskStore: nil, effectLedger: ledger))
        #expect(CompactionCheckpoint.fitsPersistenceBounds(
            [LLMMessage(role: .user, content: "summary")] + (CompactionFactCapture.backgroundMessage(facts).map { [$0] } ?? []),
            facts: facts))
        // 已成功的回执本身仍在账本里，账本据此拒绝重复派发；压缩背景不再重复列出它。
        #expect(ledger.facts.count == total)
    }

    @Test func captureKeepsOnlyUnfinishedTasks() throws {
        let tasks = AgentTaskStore()
        let parent = ParentRuntimeIdentity(sessionID: "source", conversationID: "source",
            turnID: "turn", taskID: "parent", actorID: "actor")
        for id in ["queued-task", "running-task", "done-task", "cancelled-task"] {
            _ = try tasks.enqueue(taskID: id, parentID: "parent", providerID: nil, modelID: nil,
                parentRuntimeIdentity: parent)
        }
        _ = try tasks.startRun(taskID: "running-task", parentID: "parent", runID: "run-running")
        _ = try tasks.startRun(taskID: "done-task", parentID: "parent", runID: "run-done")
        _ = try tasks.finish(runID: "run-done", outcome: .succeeded)
        _ = try tasks.startRun(taskID: "cancelled-task", parentID: "parent", runID: "run-cancelled")
        _ = try tasks.finish(runID: "run-cancelled", outcome: .cancelled)
        let facts = CompactionFactCapture.capture(sessionID: "source", revision: 1,
            messages: [LLMMessage(role: .user, content: "Continue")], taskStore: tasks, effectLedger: nil)
        #expect(Set(facts.compactMap { $0.source?.task?.taskID }) == ["queued-task", "running-task"])
        #expect(facts.allSatisfy { $0.kind == .unfinishedTask })
    }

    @Test func taskFactStaysValidAtCommitAfterItsStatusMovedOn() throws {
        let tasks = AgentTaskStore()
        let parent = ParentRuntimeIdentity(sessionID: "source", conversationID: "source",
            turnID: "turn", taskID: "parent", actorID: "actor")
        _ = try tasks.enqueue(taskID: "open", parentID: "parent", providerID: nil, modelID: nil,
            parentRuntimeIdentity: parent)
        let facts = CompactionFactCapture.capture(sessionID: "source", revision: 1,
            messages: [LLMMessage(role: .user, content: "Continue")], taskStore: tasks, effectLedger: nil)
        #expect(facts.count == 1)
        // 摘要请求进行期间任务开跑、又结束：事实只要求任务还在、归属没变。
        _ = try tasks.startRun(taskID: "open", parentID: "parent", runID: "run-open")
        _ = try tasks.finish(runID: "run-open", outcome: .succeeded)
        #expect(CompactionFactCapture.verifyStores(facts, taskStore: tasks, effectLedger: nil))
        // 任务不在了才算无效。
        #expect(!CompactionFactCapture.verifyStores(facts, taskStore: AgentTaskStore(), effectLedger: nil))
        // 下一轮恢复时重建背景：已结束的任务不再出现。
        #expect(CompactionFactCapture.capture(sessionID: "source", revision: 1,
            messages: [LLMMessage(role: .user, content: "Continue")], taskStore: tasks, effectLedger: nil).isEmpty)
    }

    @Test func taskLocatorRequiresCompleteParentAndSessionBinding() {
        func task(parentSession: String, parent: String) -> AgentTaskSnapshot {
            AgentTaskSnapshot(taskID: "child", parentID: "parent", parentContextSnapshotID: "binding",
                providerID: nil, modelID: nil, configurationFingerprint: nil, routeReceiptID: nil,
                status: .running, childTranscriptLocator: .init(childSessionID: "child-session",
                    parentSessionID: parentSession, taskID: "child", parentID: parent,
                    runID: "run", attemptID: "attempt", childExecutionID: "execution",
                    parentContextSnapshotID: "binding"))
        }
        #expect(CompactionFactCapture.taskBelongs(task(parentSession: "source", parent: "parent"), to: "source"))
        #expect(!CompactionFactCapture.taskBelongs(task(parentSession: "foreign", parent: "parent"), to: "source"))
        #expect(!CompactionFactCapture.taskBelongs(task(parentSession: "source", parent: "foreign-parent"), to: "source"))
    }

    @Test func arbitraryTaskParentDoesNotEstablishSourceSession() throws {
        let tasks = AgentTaskStore()
        _ = try tasks.enqueue(taskID: "guess", parentID: "source", providerID: nil, modelID: nil)
        #expect(CompactionFactCapture.capture(sessionID: "source", revision: 1,
            messages: [.init(role: .user, content: "Continue")], taskStore: tasks,
            effectLedger: nil).isEmpty)
    }
}
