import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - Agent 引擎接线（I4）

@Suite("Agent 引擎接线")
@MainActor
struct AgentEngineTests {
    @Test func defaultEngineIsAgentLoop() {
        let chat = ChatStore()
        // 默认走 B1b AgentLoop（isAvailable=true），而非回退直连
        #expect(chat.agentEngine.isAvailable)
    }

    @Test func agentLoopEngineStreamsFinalText() async throws {
        let engine = AgentLoopChatEngine()
        let history = [ChatMessageUI(role: .user, content: "你好")]
        let stream = try await engine.streamReply(
            provider: MockProvider.shared,
            history: history,
            systemPrompt: "test",
            maxTokens: 4096,
            conversationID: "agent-engine-stream-test",
            authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil,
            turnID: 1
        )
        var text = ""
        for try await event in stream {
            if case .textDelta(let t) = event { text += t }
        }
        // AgentLoop.run（sendMessage 非流式）→ 最终回复包装成 textDelta
        #expect(text.contains("收到：你好"))
    }

    @Test("生产引擎在 provider 调用前冻结 route，并只按序 fallback 一次")
    func agentLoopUsesFrozenProviderRuntimeRoute() async throws {
        let primary = RuntimeRouteTestProvider(
            name: "primary",
            modelID: "primary-model",
            sendError: LLMError.providerError(message: "primary unavailable")
        )
        let backup = RuntimeRouteTestProvider(
            name: "backup",
            modelID: "backup-model",
            responseText: "backup"
        )
        var builderCalls = 0
        let builder: AgentLoopChatEngine.ProviderRuntimeRouteBuilder = { box in
            builderCalls += 1
            let snapshot = try ProviderRuntimeSnapshot(
                providerID: box.value.model.provider,
                modelID: box.value.model.id,
                readinessEvidenceID: "live-settings:" + String(repeating: "a", count: 64),
                applyReceiptID: "provider-readiness-apply:test",
                fallbackProvenance: [
                    ProviderRuntimeFallback(
                        providerID: "backup",
                        modelID: "backup-model",
                        readinessEvidenceID: "mock-backup",
                        applyReceiptID: "provider-readiness-apply:backup"
                    )
                ]
            )
            return AgentLoopChatEngine.ProviderRuntimeRouteBox(
                try ProviderRuntimeRoute(
                    snapshot: snapshot,
                    primary: box.value,
                    fallbacks: [backup]
                )
            )
        }
        let engine = AgentLoopChatEngine(
            providerRuntimeRouteBuilder: builder,
            composerPolicyFacts: ComposerPolicyFactSource(
                knownCapabilities: [],
                grantedCapabilities: [],
                allowedWriteRoots: [],
                workspaceID: "agent-engine-route-workspace",
                revision: "agent-engine-route-revision",
                grantEpoch: "agent-engine-route-epoch",
                leaseID: "agent-engine-route-lease",
                expiresAt: .distantFuture,
                autonomyCeiling: .l3 // This fixture deliberately requests .auto.
            )
        )
        let turn = AgentTurnIdentity(
            sessionID: "agent-engine-route-session",
            turnID: 1,
            messageID: "agent-engine-route-message"
        )
        let composerSnapshot = ComposerSubmissionSnapshot(
            mode: .auto,
            approvalScope: .request,
            effort: .standard,
            sessionID: turn.sessionID,
            turnID: turn.turnID,
            taskID: "agent-engine-route-task",
            attemptID: "agent-engine-route-attempt",
            messageID: turn.messageID,
            inputDigest: "agent-engine-route-input",
            workspaceID: "agent-engine-route-workspace",
            createdAt: Date(),
            policyRevision: "agent-engine-route-revision",
            grantEpoch: "agent-engine-route-epoch",
            autonomyCeiling: .l3
        )
        let executionIdentity = AgentExecutionIdentity(
            turn: turn,
            operationID: "agent-engine-route-operation"
        )
        let skillStore = SkillStore(
            skillsRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "agent-engine-route-skills-\(UUID().uuidString)",
                    isDirectory: true
                )
        )
        let runtimeSnapshot = ChatTurnRuntimeSnapshot(
            turn: turn,
            skillInjector: SkillInjector(store: skillStore).snapshotForTurn(),
            mcpBridge: nil
        )
        let stream = try await engine.streamReply(
            provider: primary,
            history: [ChatMessageUI(role: .user, content: "hello")],
            systemPrompt: "test",
            maxTokens: 256,
            conversationID: turn.sessionID,
            authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil,
            turnID: turn.turnID,
            composerSnapshot: composerSnapshot,
            executionIdentity: executionIdentity,
            turnRuntimeSnapshot: runtimeSnapshot
        )
        var text = ""
        for try await event in stream {
            if case .textDelta(let value) = event {
                text += value
            }
        }

        #expect(text == "backup")
        #expect(builderCalls == 1)
        #expect(primary.sendCalls == 1)
        #expect(backup.sendCalls == 1)
    }

    @Test("ordinary send 走 production engine，并使用冻结 route 完成 fallback")
    func ordinarySendUsesFrozenRuntimeRoute() async throws {
        let primary = RuntimeRouteTestProvider(
            name: "primary",
            modelID: "primary-model",
            sendError: LLMError.providerError(message: "primary unavailable")
        )
        let backup = RuntimeRouteTestProvider(
            name: "backup",
            modelID: "backup-model",
            responseText: "ordinary backup"
        )
        let chat = ChatStore()
        let facts = ComposerPolicyFactSource(
            knownCapabilities: [],
            grantedCapabilities: [],
            allowedWriteRoots: [],
            workspaceID: chat.composerWorkspaceID,
            revision: "ordinary-send-revision",
            grantEpoch: "ordinary-send-epoch",
            leaseID: "ordinary-send-lease",
            expiresAt: .distantFuture,
            autonomyCeiling: .l1 // ChatStore's default manual mode needs L1.
        )
        chat.configureComposerPolicy(facts)
        chat.streamingProviderOverride = primary

        var builderCalls = 0
        var capturedSnapshot: ProviderRuntimeSnapshot?
        let builder: AgentLoopChatEngine.ProviderRuntimeRouteBuilder = { box in
            builderCalls += 1
            let snapshot = try ProviderRuntimeSnapshot(
                providerID: box.value.model.provider,
                modelID: box.value.model.id,
                readinessEvidenceID: "ordinary-readiness",
                applyReceiptID: "provider-readiness-apply:ordinary",
                fallbackProvenance: [
                    ProviderRuntimeFallback(
                        providerID: "backup",
                        modelID: "backup-model",
                        readinessEvidenceID: "backup-readiness",
                        applyReceiptID: "provider-readiness-apply:backup"
                    )
                ]
            )
            capturedSnapshot = snapshot
            return AgentLoopChatEngine.ProviderRuntimeRouteBox(
                try ProviderRuntimeRoute(
                    snapshot: snapshot,
                    primary: box.value,
                    fallbacks: [backup]
                )
            )
        }
        chat.agentEngine = AgentLoopChatEngine(
            fallbackEnabled: true,
            providerRuntimeRouteBuilder: builder,
            composerPolicyFacts: facts
        )
        let skillStore = SkillStore(
            skillsRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "ordinary-send-skills-\(UUID().uuidString)",
                    isDirectory: true
                )
        )
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            ChatTurnRuntimeSnapshot(
                turn: turn,
                skillInjector: SkillInjector(store: skillStore).snapshotForTurn(),
                mcpBridge: nil
            )
        }

        chat.draftText = "ordinary route contract"
        chat.sendDraft()
        for _ in 0..<200 where chat.isStreaming {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(!chat.isStreaming)
        #expect(chat.messages.last?.content == "ordinary backup")
        #expect(builderCalls == 1)
        #expect(primary.sendCalls == 1)
        #expect(backup.sendCalls == 1)

        let snapshot = try #require(capturedSnapshot)
        let encoded = try String(
            data: JSONEncoder().encode(snapshot),
            encoding: .utf8
        )
        #expect(encoded?.contains("ordinary-readiness") == true)
        #expect(encoded?.contains("https://") == false)
        #expect(encoded?.contains("api_key") == false)
    }

    @Test func fallbackEngineStillStreams() async throws {
        let engine = FallbackChatEngine()
        #expect(!engine.isAvailable)
        let history = [ChatMessageUI(role: .user, content: "回退测试")]
        let stream = try await engine.streamReply(
            provider: MockProvider.shared,
            history: history,
            systemPrompt: "test",
            maxTokens: 4096
        )
        var text = ""
        for try await event in stream {
            if case .textDelta(let t) = event { text += t }
        }
        #expect(text.contains("收到：回退测试"))
    }
}

private final class RuntimeRouteTestProvider: @unchecked Sendable, LLMProvider {
    let name: String
    var model: LLMModel
    let sendError: Error?
    let responseText: String?
    private(set) var sendCalls = 0

    init(
        name: String,
        modelID: String,
        sendError: Error? = nil,
        responseText: String? = nil
    ) {
        self.name = name
        self.model = LLMModel(id: modelID, displayName: modelID, provider: name)
        self.sendError = sendError
        self.responseText = responseText
    }

    var capabilities: Set<ProviderCapability> { [.streaming, .tools] }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        sendCalls += 1
        if let sendError {
            throw sendError
        }
        return LLMResponse(
            text: responseText ?? "ok",
            stopReason: "stop",
            usage: nil
        )
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        try await sendMessage(
            messages: messages,
            systemPrompt: systemPrompt,
            maxTokens: maxTokens,
            temperature: temperature
        )
    }

    func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.text(responseText ?? "ok"))
            continuation.yield(.finished(stopReason: "stop"))
            continuation.finish()
        }
    }
}

// MARK: - 会话持久化（B1d SessionStore 接入）

@Suite("会话持久化")
@MainActor
struct SessionPersistenceTests {
    @Test func persistenceRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniscanvas-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)

        // 装配 → 写入
        let chat = ChatStore()
        chat.attachPersistence(store)
        chat.appendUser("持久化测试")
        chat.appendAssistant("这是回复")

        let disk = store.listSessions()
        #expect(disk.count == 1)
        #expect(disk.first?.messages.count == 3) // 欢迎语 + 用户 + 助手
        #expect(disk.first?.title == "持久化测试")

        // 重新装配 → 从磁盘恢复
        let chat2 = ChatStore()
        chat2.attachPersistence(store)
        #expect(chat2.sessions.count == 1)
        #expect(chat2.messages.contains { $0.content == "持久化测试" })
        #expect(chat2.messages.contains { $0.content == "这是回复" })
    }
}
