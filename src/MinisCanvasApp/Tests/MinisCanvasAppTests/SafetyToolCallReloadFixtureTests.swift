import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("L04 safe tool-call reload fixtures")
@MainActor
struct SafetyToolCallReloadFixtureTests {
    private func makeSettingsCenter(at directory: URL) -> SettingsCenter {
        SettingsCenter(
            settingsStore: SettingsStore(directory: directory),
            envStore: EnvVarStore(directory: directory),
            memoryStore: MemoryStore(directory: directory),
            sessionStore: SessionStore(directory: directory),
            logManager: LogManager(directory: directory, ringCapacity: 10)
        )
    }

    private func makeToolCall(id: String = "call-safe-reload-1") -> LLMToolCall {
        LLMToolCall(
            id: id,
            name: "file_read",
            rawArguments: #"{"path":"notes.md"}"#,
            arguments: ["path": "notes.md"]
        )
    }

    @Test("assistant toolCalls survive a real SessionStore reload while execution stays disabled")
    func assistantToolCallsSurviveReloadWhileExecutionIsDisabled() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("safe-tool-reload-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let safety = makeSettingsCenter(at: directory)
        safety.enableSafeMode()
        let bridge = BridgeStore()
        bridge.updateSafetyRuntimeSnapshot(safety.safetyRuntimeSnapshot)
        #expect(bridge.isSafetyFeatureEnabled(.mcp) == false)
        #expect(bridge.isSafetyFeatureEnabled(.chat))

        let writer = SessionStore(directory: directory)
        let session = try writer.createSession(id: "safe-tool-session")
        let call = makeToolCall()
        let assistant = LLMMessage(role: .assistant, content: "", toolCalls: [call])
        try writer.saveMessage(assistant, sessionID: session.id)

        let reloaded = try #require(SessionStore(directory: directory).loadSession(id: session.id))
        #expect(reloaded.messages == [assistant])
        #expect(reloaded.messages[0].toolCalls == [call])
        #expect(reloaded.messages[0].toolCalls.first?.id == "call-safe-reload-1")
    }

    @Test("tool role and toolCallID survive App bridge reload without re-execution")
    func toolRoleAndToolCallIDSurviveReloadWithoutExecution() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("safe-tool-bridge-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let call = makeToolCall()
        let thread = ChatThread(
            title: "安全恢复",
            messages: [
                ChatMessageUI(
                    role: .assistant,
                    content: "",
                    toolCalls: [call]
                ),
                ChatMessageUI(
                    role: .tool,
                    content: "读取完成",
                    toolCallID: call.id
                )
            ]
        )
        let persisted = thread.asPersisted()
        let restoredThread = persisted.asThread()
        #expect(restoredThread.messages.map(\.role) == [.assistant, .tool])
        #expect(restoredThread.messages[0].toolCalls == [call])
        #expect(restoredThread.messages[1].toolCallID == call.id)

        let store = SessionStore(directory: directory)
        try store.updateSession(persisted)

        let bridge = BridgeStore()
        #expect(bridge.chat.attachPersistence(SessionStore(directory: directory)))
        #expect(bridge.chat.isStreaming == false)
        #expect(bridge.chat.messages.map(\.role) == [.assistant, .tool])
        #expect(bridge.chat.messages[0].toolCalls == [call])
        #expect(bridge.chat.messages[1].toolCallID == call.id)
        #expect(bridge.chat.messages[1].role == .tool)
    }

    @Test("optional tools remain blocked while a restored transcript stays readable")
    func optionalToolsStayBlockedWhileTranscriptRemainsReadable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("safe-tool-transcript-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let safety = makeSettingsCenter(at: directory)
        safety.enableSafeMode()
        let bridge = BridgeStore()
        bridge.updateSafetyRuntimeSnapshot(safety.safetyRuntimeSnapshot)
        #expect(bridge.isSafetyFeatureEnabled(.mcp) == false)
        #expect(bridge.isSafetyFeatureEnabled(.externalAgents) == false)
        #expect(bridge.isSafetyFeatureEnabled(.chat))
        #expect(bridge.isSafetyFeatureEnabled(.backup))
        #expect(bridge.isSafetyFeatureEnabled(.recovery))

        let call = makeToolCall(id: "call-safe-readable-1")
        let session = MinisCore.ChatSession(
            id: "safe-readable-session",
            title: "可读历史",
            messages: [
                LLMMessage(role: .user, content: "读取 notes.md"),
                LLMMessage(role: .assistant, content: "", toolCalls: [call]),
                LLMMessage(role: .tool, content: "读取完成", toolCallID: call.id),
                LLMMessage(role: .assistant, content: "已读取 notes.md")
            ],
            transcriptRevision: 4
        )
        let store = SessionStore(directory: directory)
        try store.updateSession(session)

        #expect(bridge.chat.attachPersistence(SessionStore(directory: directory)))
        #expect(bridge.chat.isStreaming == false)
        #expect(bridge.chat.messages.map(\.role) == [.user, .assistant, .tool, .assistant])
        #expect(bridge.chat.messages[1].toolCalls.first?.id == call.id)
        #expect(bridge.chat.messages[2].toolCallID == call.id)
        #expect(bridge.chat.messages.count == 4)
    }

    @Test("failed-message retry identity and terminal tool fact survive one restart")
    func failedMessageRetryIdentityAndTerminalToolFactSurviveRestart() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("safe-failed-tool-retry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sessionStore = SessionStore(directory: directory)
        let chat = ChatStore()
        #expect(chat.attachPersistence(sessionStore))
        let sessionID = try #require(chat.activeSessionID)
        chat.appendUser("重试失败的工具请求")
        chat.markExecutionRunning(
            sessionID: sessionID,
            turnID: 41,
            taskID: "task-failed-tool-reload",
            updatedAt: Date(timeIntervalSince1970: 41)
        )
        chat.markExecutionFailed(
            sessionID: sessionID,
            reason: "工具执行在重启时失败",
            updatedAt: Date(timeIntervalSince1970: 42)
        )

        let persisted = try #require(sessionStore.loadSession(id: sessionID.uuidString))
        #expect(persisted.messages.last?.content == "重试失败的工具请求")

        let ledgerURL = directory.appendingPathComponent("tool-execution-facts.json")
        let ledger = try ToolExecutionFactLedger(persistenceURL: ledgerURL)
        let executionIdentity = AgentExecutionIdentity(
            turn: AgentTurnIdentity(
                sessionID: sessionID.uuidString,
                turnID: 41,
                messageID: "failed-tool-reload-message"
            ),
            operationID: "failed-tool-reload-operation",
            attempt: 1
        )
        _ = try ledger.mint(
            toolCallID: "call-failed-tool-reload",
            toolName: "file_read",
            attemptID: "failed-tool-reload-attempt",
            attemptNumber: 1,
            executionIdentity: executionIdentity
        )

        let reloadedLedger = try ToolExecutionFactLedger(persistenceURL: ledgerURL)
        #expect(throws: ToolExecutionFactLedgerError.externalOutcomeUnverified) {
            try reloadedLedger.reconcilePending()
        }
        #expect(reloadedLedger.pendingReceipts.count == 1)
        #expect(reloadedLedger.pendingReceipts.first?.toolCallID == "call-failed-tool-reload")
        #expect(reloadedLedger.pendingReceipts.first?.executionIdentity == executionIdentity)
        #expect(reloadedLedger.facts.isEmpty)

        // The Chat retry indicator below comes from its separately persisted
        // execution failure above, not from a fabricated tool-fact outcome.
        let restoredChat = ChatStore()
        #expect(restoredChat.attachPersistence(SessionStore(directory: directory)))
        let retryIdentity = try #require(restoredChat.sessionList.first?.retryIdentity)
        #expect(retryIdentity.sessionID == sessionID)
        #expect(retryIdentity.turnID == 41)
        #expect(retryIdentity.taskID == "task-failed-tool-reload")
        #expect(restoredChat.executionSnapshot(forSessionID: sessionID)?.state == .failed)
        #expect(
            restoredChat.sessionList.first?.indicator
                == .failed(reason: "工具执行在重启时失败")
        )
    }
}
