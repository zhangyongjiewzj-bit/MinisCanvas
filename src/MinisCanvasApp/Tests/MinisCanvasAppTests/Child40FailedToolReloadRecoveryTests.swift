import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Child40 failed tool reload recovery")
@MainActor
struct Child40FailedToolReloadRecoveryTests {
    @Test func mixedToolOutcomeReloadKeepsFailedChatAndQueuedChildProjection() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("child40-failed-tool-reload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let sessionID = UUID(uuidString: "F040F040-F040-4F40-8F40-F040F040F040")!
        let firstCall = LLMToolCall(
            id: "call-child40-success",
            name: "file_read",
            rawArguments: #"{"path":"notes.md"}"#,
            arguments: ["path": "notes.md"]
        )
        let secondCall = LLMToolCall(
            id: "call-child40-failed",
            name: "file_read",
            rawArguments: #"{"path":"private.md"}"#,
            arguments: ["path": "private.md"]
        )
        let thread = ChatThread(
            id: sessionID,
            title: "Child40 工具恢复",
            messages: [
                ChatMessageUI(role: .user, content: "读取两个文件"),
                ChatMessageUI(
                    role: .assistant,
                    content: "",
                    toolCalls: [firstCall, secondCall]
                ),
                ChatMessageUI(
                    role: .tool,
                    content: "读取完成",
                    toolCallID: firstCall.id
                ),
                ChatMessageUI(
                    role: .tool,
                    content: "工具失败：权限不足",
                    toolCallID: secondCall.id
                )
            ],
            transcriptRevision: 14
        )
        let sessionStore = SessionStore(directory: directory)
        try sessionStore.updateSession(thread.asPersisted())

        let restoredThread = try #require(
            SessionStore(directory: directory).loadSession(id: sessionID.uuidString)
        ).asThread()
        #expect(restoredThread.messages.map(\.role) == [.user, .assistant, .tool, .tool])
        #expect(restoredThread.messages[1].toolCalls.map(\.id) == [firstCall.id, secondCall.id])
        #expect(restoredThread.messages[2].toolCallID == firstCall.id)
        #expect(restoredThread.messages[3].toolCallID == secondCall.id)
        #expect(restoredThread.messages[3].content == "工具失败：权限不足")
        #expect(restoredThread.transcriptRevision == 14)

        let firstChat = ChatStore()
        #expect(firstChat.attachPersistence(SessionStore(directory: directory)))
        firstChat.markExecutionRunning(
            sessionID: sessionID,
            turnID: 140,
            taskID: "child40-failed-tool-task",
            updatedAt: Date(timeIntervalSince1970: 140)
        )
        firstChat.markExecutionFailed(
            sessionID: sessionID,
            reason: "第二个工具结果失败",
            updatedAt: Date(timeIntervalSince1970: 141)
        )

        let childSelection = try ChildConcurrencySelection(
            userSelected: 12,
            recommended: 4,
            effective: 8,
            enabledSessionCount: 2
        )
        let ledgerURL = directory.appendingPathComponent("agent-tasks.json")
        do {
            let taskStore = try AgentTaskStore(persistenceURL: ledgerURL)
            _ = try taskStore.enqueue(
                taskID: "child40-tool-success",
                parentID: sessionID.uuidString,
                providerID: "offline",
                modelID: "test",
                parentContextSnapshotID: firstCall.id
            )
            _ = try taskStore.enqueue(
                taskID: "child40-tool-failed",
                parentID: sessionID.uuidString,
                providerID: "offline",
                modelID: "test",
                parentContextSnapshotID: secondCall.id
            )

            let bridge = BridgeStore(agentTaskStore: taskStore)
            bridge.attachProductionServices(
                sessionDirectory: directory,
                childConcurrencySelection: childSelection
            )
            #expect(bridge.taskCenterObservation.counts.queued == 2)
            #expect(bridge.taskCenterObservation.counts.total == 2)
            #expect(bridge.childConcurrencyQueuedCount == 2)
            #expect(bridge.childConcurrencySelection == childSelection)
            #expect(bridge.childConcurrencySelection.effective == 8)
            #expect(
                bridge.childConcurrencySelection.effective
                    <= ChildConcurrencySelection.hardMaximum
            )
            #expect(taskStore.allReceipts().isEmpty)
        }

        let restartedChat = ChatStore()
        #expect(restartedChat.attachPersistence(SessionStore(directory: directory)))
        #expect(restartedChat.messages.map(\.role) == [.user, .assistant, .tool, .tool])
        #expect(restartedChat.messages[1].toolCalls.map(\.id) == [firstCall.id, secondCall.id])
        #expect(restartedChat.messages[3].toolCallID == secondCall.id)
        #expect(
            restartedChat.sessionList.first?.indicator
                == .failed(reason: "第二个工具结果失败")
        )
        let retryIdentity = try #require(restartedChat.sessionList.first?.retryIdentity)
        #expect(retryIdentity.sessionID == sessionID)
        #expect(retryIdentity.turnID == 140)
        #expect(retryIdentity.taskID == "child40-failed-tool-task")

        let restartedTaskStore = try AgentTaskStore(persistenceURL: ledgerURL)
        let restartedBridge = BridgeStore(agentTaskStore: restartedTaskStore)
        restartedBridge.attachProductionServices(
            sessionDirectory: directory,
            childConcurrencySelection: childSelection
        )
        #expect(restartedBridge.taskCenterObservation.counts.queued == 2)
        #expect(restartedBridge.taskCenterObservation.counts.total == 2)
        #expect(restartedBridge.childConcurrencyQueuedCount == 2)
        #expect(restartedBridge.childConcurrencySelection.effective == 8)
        #expect(restartedBridge.childConcurrencySelection.userSelected == 12)
        #expect(restartedBridge.childConcurrencySelection.recommended == 4)
        #expect(restartedTaskStore.allReceipts().isEmpty)
        #expect(
            Set(restartedBridge.taskCenterObservation.taskSnapshots.map(\.taskID))
                == ["child40-tool-success", "child40-tool-failed"]
        )
    }
}
