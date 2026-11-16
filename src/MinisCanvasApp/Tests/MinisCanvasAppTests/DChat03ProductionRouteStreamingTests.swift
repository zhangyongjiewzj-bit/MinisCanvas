import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

// D-CHAT-03（生产路由流式转发 · App 消费链可达性）。
//
// 冻结需求：issues/三期初期合拢-App逐项功能验收清单-20260826.md:160 `CHAT-03`
// 「助手回复能流式显示，生成中状态清晰」。
//
// 本文件固定生产消费链可达性：`ProviderRuntimeRoute` 正是
// BridgeStore.swift:1412/:2030/:2054 与 ChatSessionRuntime.swift:768 构建并
// 冻结给回合的运行时路由。此前该路由的 `streamAssistantMessage` 经缓冲
// `sendMessageWithReceipt` 合成单 `.completed`，生产整链（AgentLoopChatEngine
// → ToolCallTrackingProvider → BudgetRecordingProvider/Route → FallbackRouter
// → wire provider）永远只收到一个终态事件、零实时增量。修复后：符合
// `AssistantStreamingLLMProvider` 的 provider 的真实增量必须穿过
// `engine.streamReply` 的 `.textDelta` 通道逐段到达消费者；不符形 provider
// 保持旧的单条最终文本行为不变。
//
// 注意：本 lane 为普通 DEV 线，不执行 swift build/test；本文件在交付时是
// compile-unchecked（见回执）。

// MARK: - Test doubles

/// 符合 assistant 增量流接缝的 wire-等效 provider：按脚本实时流出
/// textDelta，终态 `.completed` 携带权威全文；缓冲重载一旦被调用即计数
/// （生产流式路径不得触碰）。
private final class DChat03StreamingProvider: AssistantStreamingLLMProvider, @unchecked Sendable {
    let name = "d-chat-03-stream-provider"
    var model = LLMModel(
        id: "d-chat-03-stream-model",
        displayName: "D-CHAT-03 Stream",
        provider: "d-chat-03-stream-provider"
    )
    var capabilities: Set<ProviderCapability> { [.tools] }

    private let lock = NSLock()
    private var bufferedSendCalls = 0

    var observedBufferedCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return bufferedSendCalls
    }

    private func recordBufferedCall() {
        lock.lock()
        bufferedSendCalls += 1
        lock.unlock()
    }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        recordBufferedCall()
        return LLMResponse(text: "unexpected-buffered", stopReason: "stop", usage: nil)
    }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
        maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        recordBufferedCall()
        return LLMResponse(text: "unexpected-buffered-tools", stopReason: "stop", usage: nil)
    }

    func streamMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func streamAssistantMessage(
        messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
        maxTokens: Int, temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMAssistantStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            for delta in ["你", "好", "，世界"] {
                continuation.yield(.textDelta(delta))
            }
            continuation.yield(
                .completed(
                    LLMResponse(text: "你好，世界", stopReason: "end_turn", usage: nil)
                )
            )
            continuation.finish()
        }
    }
}

/// 未迁移接缝的缓冲 provider（对照组：内置 Mock 一类）。
private final class DChat03BufferedProvider: LLMProvider, @unchecked Sendable {
    let name = "d-chat-03-buffered-provider"
    var model = LLMModel(
        id: "d-chat-03-buffered-model",
        displayName: "D-CHAT-03 Buffered",
        provider: "d-chat-03-buffered-provider"
    )
    var capabilities: Set<ProviderCapability> { [.tools] }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        LLMResponse(text: "缓冲完整回复。", stopReason: "stop", usage: nil)
    }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
        maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        LLMResponse(text: "缓冲完整回复。", stopReason: "stop", usage: nil)
    }

    func streamMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct DChat03ToolExecutor: ToolExecutor {
    func execute(name: String, input: [String: Any]) async throws -> String {
        "tool-ok"
    }
}

// MARK: - Fixture

@Suite("D-CHAT-03 production route streaming consumer reachability")
@MainActor
struct DChat03ProductionRouteStreamingTests {
    private struct Fixture {
        let contextSettingsOwner: SettingsCenter
        let root: URL
        let engine: AgentLoopChatEngine
        let composerSnapshot: ComposerSubmissionSnapshot
        let executionIdentity: AgentExecutionIdentity
        let runtimeSnapshot: ChatTurnRuntimeSnapshot
        let sessionID: String
        let turnID: Int
    }

    private func contextSettingsOwner(root: URL, sessionStore: SessionStore) -> SettingsCenter {
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        return SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("context-settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("context-env"), keychain: keychain),
            memoryStore: MemoryStore(directory: root),
            memoryFileStore: MemoryFileStore(directory: root.appendingPathComponent("context-memory-files")),
            sessionStore: sessionStore,
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("context-badges")),
            logManager: LogManager(directory: root.appendingPathComponent("context-logs"), ringCapacity: 20),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("context-mcps.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite(root.lastPathComponent)),
            providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("context-readiness"))
        )
    }

    private func makeFixture(provider: any LLMProvider) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "D-CHAT-03-production-route-\(UUID().uuidString)",
                isDirectory: true
            )
        let sessionID = "dchat03-route-session"
        let turnID = 1
        let sessionStore = SessionStore(directory: root)
        _ = try sessionStore.createSession(id: sessionID, projectID: "dchat03-project")
        // 生产消费者从持久化转录恢复，而不是调用方 UI 历史；预置同一轮用户
        // 消息（与 ChatStore 提交前持久化的一致）。
        try sessionStore.saveMessage(
            ChatMessageUI(role: .user, content: "d-chat-03 streaming").asLLMMessage(),
            sessionID: sessionID
        )
        let memoryStore = MemoryStore(directory: root)
        let skillStore = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let soulStore = SoulStore(directory: root)

        // 生产冻结路由：与 BridgeStore.makeProviderRuntimeRoute /
        // ChatSessionRuntime 相同的构造入口。
        let snapshot = try ProviderRuntimeSnapshot(
            providerID: provider.model.provider,
            modelID: provider.model.id,
            readinessEvidenceID: "live-settings:" + String(repeating: "a", count: 64),
            applyReceiptID: "provider-readiness-apply:dchat03"
        )
        let route = try ProviderRuntimeRoute(snapshot: snapshot, primary: provider)

        let turn = AgentTurnIdentity(
            sessionID: sessionID,
            turnID: turnID,
            messageID: "dchat03-message"
        )
        let settingsOwner = contextSettingsOwner(root: root, sessionStore: sessionStore)
        let settingsCapture = ChatContextSettingsCapture(
            sessionStore: settingsOwner.sessionStore, sessionID: sessionID, model: provider.model
        )
        let runtimeSnapshot = ChatTurnRuntimeSnapshot(
            turn: turn,
            skillInjector: SkillInjector(store: skillStore).snapshotForTurn(),
            mcpBridge: nil,
            providerRuntimeRoute: route,
            requiresProviderRuntimeRoute: true,
            contextSettingsCapture: settingsCapture
        )
        let composerSnapshot = ComposerSubmissionSnapshot(
            mode: .auto,
            approvalScope: .request,
            effort: .standard,
            sessionID: sessionID,
            turnID: turnID,
            taskID: "dchat03-task",
            attemptID: "dchat03-attempt",
            messageID: turn.messageID,
            inputDigest: "dchat03-input",
            workspaceID: "dchat03-workspace",
            createdAt: Date(),
            policyRevision: "dchat03-policy",
            grantEpoch: "dchat03-grant",
            autonomyCeiling: .l3
        )
        let engine = AgentLoopChatEngine(
            toolExecutor: DChat03ToolExecutor(),
            maxIterations: 10,
            chatRuntimeDependencies: .init(
                sessionStore: sessionStore,
                memoryStore: memoryStore,
                skillStore: skillStore,
                soulStore: soulStore
            ),
            contextWritebackStorePersistenceURL: root.appendingPathComponent("context.json"),
            resultExecutionIdentityOverride: nil,
            onToolExecutionFactForwarded: nil,
            composerPolicyFacts: ComposerPolicyFactSource(
                knownCapabilities: [BrowserTool.toolName],
                grantedCapabilities: [BrowserTool.toolName],
                allowedWriteRoots: [],
                workspaceID: "dchat03-workspace",
                revision: "dchat03-policy",
                grantEpoch: "dchat03-grant",
                leaseID: "dchat03-lease",
                expiresAt: .distantFuture,
                autonomyCeiling: .l3 // Existing .auto route fixture explicitly permits L3.
            ),
            onRetryLifecycleEvent: nil
        )
        return Fixture(
            contextSettingsOwner: settingsOwner,
            root: root,
            engine: engine,
            composerSnapshot: composerSnapshot,
            executionIdentity: AgentExecutionIdentity(
                turn: turn,
                operationID: "dchat03-operation",
                attempt: 1
            ),
            runtimeSnapshot: runtimeSnapshot,
            sessionID: sessionID,
            turnID: turnID
        )
    }

    private func collectTextDeltas(
        _ stream: AsyncThrowingStream<AgentStreamEvent, Error>
    ) async throws -> (deltas: [String], sawDone: Bool) {
        var deltas: [String] = []
        var sawDone = false
        for try await event in stream {
            switch event {
            case .textDelta(let text):
                deltas.append(text)
            case .done:
                sawDone = true
            default:
                break
            }
        }
        return (deltas, sawDone)
    }

    // Swift 6 严格并发（C2T 站点 :260:47 修复）：本 helper 处于 @MainActor
    // 隔离域，裸 `any LLMProvider`（非 Sendable 协议 existential）参数绑定被
    // 借传给非隔离的 ChatAgentEngine.streamReply 即跨隔离送出，触发
    // `sending 'provider' risks causing data races`。本文件真实契约是
    // provider 替身均为 @unchecked Sendable + NSLock 保护可变状态（见上方
    // 两个替身自声明），故把该事实写进参数类型 `any (LLMProvider & Sendable)`：
    // Sendable 值可跨隔离，:260 传递成立；streamReply 收到的仍是
    // `any LLMProvider`（存在集合隐式放宽）。与生产 ChatStore:4566→:4571
    // 经 Sendable 盒子读出再转发的既有模式在测试边界等价。判别证据、被否
    // 候选（helper 参数加 sending 关键字 / runTurn 改 nonisolated）与理由见
    // QODER-DEV-267-DCHATSEND.raw.log；非抑制、未改生产签名与断言语义。
    private func runTurn(fixture: Fixture, provider: any (LLMProvider & Sendable)) async throws
        -> (deltas: [String], sawDone: Bool)
    {
        let stream = try await fixture.engine.streamReply(
            provider: provider,
            history: [ChatMessageUI(role: .user, content: "d-chat-03 streaming")],
            systemPrompt: "test",
            maxTokens: 128,
            conversationID: fixture.sessionID,
            authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil,
            turnID: fixture.turnID,
            composerSnapshot: fixture.composerSnapshot,
            executionIdentity: fixture.executionIdentity,
            turnRuntimeSnapshot: fixture.runtimeSnapshot
        )
        return try await collectTextDeltas(stream)
    }

    /// CHAT-03 生产可达性：符合接缝的 provider 经冻结的 ProviderRuntimeRoute
    /// 流过 `streamReply` 时，消费者必须收到多段实时 `.textDelta`（修复前
    /// 恒为一条终态合成文本），且拼接等于权威全文、不重复补发。
    @Test func productionRouteForwardsLiveDeltasToEngineConsumer() async throws {
        let provider = DChat03StreamingProvider()
        let fixture = try makeFixture(provider: provider)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let outcome = try await runTurn(fixture: fixture, provider: provider)

        #expect(
            outcome.deltas == ["你", "好", "，世界"],
            "生产消费链必须逐段收到 wire provider 的真实增量，而不是单条合成终态"
        )
        #expect(outcome.deltas.count > 1, "「流式显示」要求至少两段实时增量")
        #expect(outcome.deltas.joined() == "你好，世界")
        #expect(outcome.sawDone)
        #expect(
            provider.observedBufferedCalls == 0,
            "流式路径不得再经缓冲 sendMessage 命中 wire provider（双发请求）"
        )
    }

    /// 零行为变化对照：不符形的缓冲 provider 在同一生产消费链上仍得到恰好
    /// 一条最终文本（旧合成行为保持不变）。
    @Test func productionRouteKeepsBufferedSynthesisForNonConformingProvider() async throws {
        let provider = DChat03BufferedProvider()
        let fixture = try makeFixture(provider: provider)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let outcome = try await runTurn(fixture: fixture, provider: provider)

        #expect(
            outcome.deltas == ["缓冲完整回复。"],
            "未迁移 provider 必须保持单条终态文本的旧生产行为"
        )
        #expect(outcome.sawDone)
    }
}
