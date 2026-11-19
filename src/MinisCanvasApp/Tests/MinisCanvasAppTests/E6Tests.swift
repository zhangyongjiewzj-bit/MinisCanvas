import os
import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - E6 MCP 管理面板接线（SettingsCenter ↔ MCPServerManager）

@Suite("MCP 管理面板接线")
@MainActor
struct MCPManagerWiringTests {

    /// 临时目录中心：所有 store 与 mcps.json 都落在临时目录，不碰 Application Support。
    private func makeCenter() -> (SettingsCenter, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("E6MCPTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mcpURL = dir.appendingPathComponent("mcps.json")
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: dir),
            envStore: EnvVarStore(directory: dir),
            memoryStore: MemoryStore(directory: dir),
            sessionStore: SessionStore(directory: dir),
            logManager: LogManager(directory: dir, ringCapacity: 50),
            mcpManager: MCPServerManager(fileURL: mcpURL)
        )
        return (center, mcpURL)
    }

    @Test func mcpServerCRUDAndSnapshot() throws {
        let (center, _) = makeCenter()
        #expect(center.mcpServers.isEmpty)

        // 新增（stdio + http 两种）
        #expect(center.addMCPServer(MCPServer(
            id: "files", name: "Files", type: .stdio,
            command: "npx", args: ["-y", "@modelcontextprotocol/server-filesystem"]
        )))
        #expect(center.addMCPServer(MCPServer(
            id: "remote", name: "Remote", type: .http, url: "https://example.com/mcp"
        )))

        // 快照按 id 升序
        #expect(center.mcpServers.count == 2)
        #expect(center.mcpServers.map(\.id) == ["files", "remote"])

        // 启用开关
        #expect(center.toggleMCPServer(id: "files", enabled: false))
        #expect(center.mcpServers.first { $0.id == "files" }?.enabled == false)
        #expect(center.mcpServers.filter(\.enabled).count == 1)

        // 删除
        #expect(center.removeMCPServer(id: "remote"))
        #expect(center.mcpServers.count == 1)
        #expect(center.mcpServers.first?.id == "files")
        #expect(center.mcpManager.trashedServers().map(\.id) == ["remote"])
    }

    @Test func mcpServerPersistsAcrossReload() throws {
        let (center, mcpURL) = makeCenter()
        #expect(center.addMCPServer(MCPServer(
            id: "github", name: "GitHub", type: .stdio,
            command: "npx", args: ["-y", "@modelcontextprotocol/server-github"]
        )))
        _ = center.toggleMCPServer(id: "github", enabled: false)

        // 用同一个文件 URL 重建 manager → 配置仍在，且禁用状态保持
        let reloaded = MCPServerManager(fileURL: mcpURL)
        let servers = reloaded.listServers()
        #expect(servers.count == 1)
        #expect(servers.first?.id == "github")
        #expect(servers.first?.enabled == false)
        #expect(servers.first?.transportSummary.contains("npx") == true)
    }
}

// MARK: - E6 工具审批 UI 接线（ApprovalPromptCenter ↔ AgentLoopChatEngine）

// 本地脚本 Provider：按序返回预设回复（工具调用 envelope / 最终文本）。
private final class E6ScriptedProvider: LLMProvider {
    var name: String { "E6Scripted" }
    var model = LLMModel(id: "e6", displayName: "E6 Scripted", provider: "E6Scripted")
    // This test double returns the same scripted envelope from the native-tools
    // entry point, so the approval tests exercise the real AgentLoop gate.
    var capabilities: Set<ProviderCapability> { [.tools] }
    var responses: [String]
    private(set) var lastReceivedMessages: [LLMMessage] = []

    init(responses: [String]) {
        self.responses = responses
    }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        lastReceivedMessages = messages
        let text = responses.isEmpty ? "" : responses.removeFirst()
        return LLMResponse(text: text, stopReason: nil, usage: nil)
    }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
        maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        try await sendMessage(
            messages: messages,
            systemPrompt: systemPrompt,
            maxTokens: maxTokens,
            temperature: temperature
        )
    }

    func streamMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

/// 记录工具调用（不真正执行）。
private final class E6RecordingExecutor: ToolExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    var executedNames: [String] { lock.withLock { names } }

    func execute(name: String, input: [String: Any]) async throws -> String {
        lock.withLock { names.append(name) }
        return "executed \(name)"
    }
}

private func e6PolicyBoundExecutor(_ executor: E6RecordingExecutor) -> PolicyEnforcedToolExecutor {
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    let goal = GoalEnvelope(
        scopeID: "e6:test",
        allowedCapabilities: ["file_read", "file_write", "shell_execute"],
        fileRoots: ["/tmp"],
        budget: 100,
        deadline: now.addingTimeInterval(3_600),
        concurrencyLimit: 1,
        autonomyLevel: .l2,
        creatorID: "E6Tests",
        createdAt: now
    )
    let lease = AutonomyLease(
        goalID: goal.goalID,
        scopeID: goal.scopeID,
        issuedAt: now,
        expiresAt: goal.deadline
    )
    return PolicyRuntimeBinding(
        goal: goal,
        lease: lease,
        clock: { now }
    ).wrap(executor)
}

/// 构造工具调用 envelope 回复。
private func e6ToolCallEnvelope(id: String, name: String, input: [String: Any]) -> String {
    let object: [String: Any] = ["tool_calls": [["id": id, "name": name, "input": input]]]
    let data = try! JSONSerialization.data(withJSONObject: object)
    return String(data: data, encoding: .utf8)!
}

@Suite("工具审批 UI 接线")
@MainActor
struct ApprovalUIBridgingTests {

    private func makeCenter() -> ApprovalPromptCenter { ApprovalPromptCenter() }

    private func makeRequest(
        id: String = "call_1", tool: String = "shell_execute",
        summary: String = "command: echo hi", risk: ApprovalRiskLevel = .high
    ) -> ApprovalRequest {
        ApprovalRequest(
            id: id, toolName: tool, inputSummary: summary,
            riskLevel: risk, requiresApproval: true
        )
    }

    // MARK: - ApprovalPromptCenter continuation 桥接

    @Test func presentThenAllowResolvesApproved() async {
        let center = makeCenter()
        let request = makeRequest()
        let task = Task { await center.present(request) }

        // 等待弹窗状态出现
        for _ in 0..<50 where center.pendingRequest == nil {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(center.pendingRequest?.toolName == "shell_execute")
        #expect(center.pendingRequest?.riskLevel == .high)
        #expect(center.pendingRequest?.inputSummary == "command: echo hi")

        center.resolve(approved: true, reason: "用户允许", confirmed: true)
        let decision = await task.value
        #expect(decision.approved)
        #expect(decision.reason == "用户允许")
        #expect(center.pendingRequest == nil)
    }

    @Test func presentThenDenyResolvesDenied() async {
        let center = makeCenter()
        let task = Task { await center.present(makeRequest(id: "call_2", tool: "file_write", summary: "path: /tmp/a.txt, content: <redacted>")) }

        for _ in 0..<50 where center.pendingRequest == nil {
            try? await Task.sleep(for: .milliseconds(20))
        }
        center.resolve(approved: false, reason: "用户拒绝", confirmed: false)
        let decision = await task.value
        #expect(!decision.approved)
        #expect(decision.reason == "用户拒绝")
    }

    @Test func dismissPendingTreatsAsDeny() async {
        let center = makeCenter()
        let task = Task { await center.present(makeRequest()) }

        for _ in 0..<50 where center.pendingRequest == nil {
            try? await Task.sleep(for: .milliseconds(20))
        }
        center.dismissPending()
        let decision = await task.value
        #expect(!decision.approved)
    }

    @Test func overlappingRequestIsDeniedImmediately() async {
        let center = makeCenter()
        let first = Task { await center.present(makeRequest(id: "a")) }
        for _ in 0..<50 where center.pendingRequest == nil {
            try? await Task.sleep(for: .milliseconds(20))
        }
        // 第二个请求在第一个未裁决时直接拒绝，不悬挂
        let second = await center.present(makeRequest(id: "b"))
        #expect(!second.approved)
        center.resolve(approved: true, confirmed: true)
        #expect((await first.value).approved)
    }

    // MARK: - AgentLoopChatEngine 装配审批门

    @Test func engineWithoutDelegateKeepsNoGate() {
        let engine = AgentLoopChatEngine()
        #expect(engine.loop.approvalGate == nil) // 行为与 E6 之前完全一致
    }

    @Test func engineWithDelegateWiresApprovalGate() {
        let center = makeCenter()
        let engine = AgentLoopChatEngine(approvalDelegate: ApprovalPromptDelegate(center: center))
        #expect(engine.loop.approvalGate != nil)
    }

    // MARK: - 端到端：只在工具执行时触发审批

    /// Real App loop, presented actions and durable tool facts share one owned
    /// append target. A second execution changes bytes, not a fixture counter.
    @Test func repeatedPresentedConsentAndEnvelopeProduceOneDurableFileEffect769() async throws {
        actor Receipts {
            var values: [ApprovalReceipt] = []
            func append(_ value: ApprovalReceipt) { values.append(value) }
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Approval769-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = root.appendingPathComponent("once.txt")
        let marker = "owned-769-once\n"
        let factURL = root.appendingPathComponent("facts.json")
        let turnURL = root.appendingPathComponent("turns.json")
        let facts = try ToolExecutionFactLedger(persistenceURL: factURL)
        let changes = FileChangeLedger(workspaceRoot: root.path)
        let session = "approval769-\(UUID().uuidString)"
        let callID = "write769"
        let identity = AgentExecutionIdentity(
            turn: .init(sessionID: session, turnID: 1, messageID: "assistant:\(session):1"),
            operationID: "chat:\(session):1", attempt: 1)
        let builtin = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        builtin.fileChangeLedger = changes
        builtin.fileChangeSessionID = session
        let now = Date()
        let goal = GoalEnvelope(scopeID: session, allowedCapabilities: ["file_write"],
            fileRoots: [root.path], budget: 10, deadline: now.addingTimeInterval(120),
            concurrencyLimit: 1, autonomyLevel: .l2, creatorID: "approval769", createdAt: now)
        let lease = AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID,
                                  issuedAt: now, expiresAt: goal.deadline)
        let executor = PolicyRuntimeBinding(goal: goal, lease: lease).wrap(builtin)
        let center = makeCenter()
        let receipts = Receipts()
        let gate = ApprovalGate(delegate: ApprovalPromptDelegate(center: center),
            onApprovalReceipt: { await receipts.append($0) })
        var engine = AgentLoopChatEngine(toolExecutor: executor, maxIterations: 4,
            executionTimeout: 30, approvalGate: gate,
            contextWritebackStorePersistenceURL: turnURL, toolExecutionFactLedger: facts)
        // Exercise approval replay rather than stopping at the separate loop detector.
        engine.loop.loopDetector = nil
        let envelope = e6ToolCallEnvelope(id: callID, name: "file_write",
            input: ["path": file.path, "content": marker, "append": true])
        let provider = E6ScriptedProvider(responses: [envelope, envelope, "owned complete"])
        let stream = try await engine.streamReply(provider: provider,
            history: [ChatMessageUI(role: .user, content: "append owned marker once")],
            systemPrompt: "synthetic approval consumer", maxTokens: 512,
            conversationID: session, authorizedSessionReadSessionID: nil, turnID: 1)
        let consume = Task { for try await _ in stream { } }
        defer { consume.cancel(); center.dismissPending() }
        for _ in 0..<100 where center.pendingRequest == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let request = try #require(center.pendingRequest)
        #expect(request.requestID == callID)
        #expect(request.riskLevel == .high)
        // Production rendered actions require 0.5s at each approval stage.
        try await Task.sleep(for: .milliseconds(550))
        let first = center.actionsForPresentedRequest()
        // 2026-11-16 起 file_write 只需一次点击；重复点击同一张卡仍只能产生一次效果。
        first.approve()
        first.approve()
        try await consume.value

        #expect(try Data(contentsOf: file) == Data(marker.utf8))
        #expect(facts.facts.count == 1)
        #expect(facts.pendingReceipts.isEmpty)
        let fact = try #require(facts.facts.first)
        #expect(fact.status == .succeeded)
        #expect(fact.executionIdentity == identity)
        let key = try #require(fact.compositeKey)
        #expect(key.sessionID == session && key.turnID == 1)
        #expect(key.messageID == identity.turn.messageID && key.operationID == identity.operationID)
        #expect(key.attemptID == fact.attemptID && key.attemptNumber == 1 && key.toolCallID == callID)
        let accepted = await receipts.values
        #expect(accepted.count == 1)
        let receipt = try #require(accepted.first)
        #expect(receipt.requestID == callID && receipt.sessionID == session)
        #expect(receipt.identityDigest == request.identityDigest && receipt.identityDigest != nil)
        #expect(receipt.attemptID == fact.attemptID)
        let records = changes.records(sessionID: session)
        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(record.producerReceiptID == fact.receiptID && record.producerCompositeKey == key)
        let outcomes = provider.lastReceivedMessages.flatMap { $0.toAgentContentParts() }
            .compactMap { part -> Bool? in
                guard case .toolResult(let id, _, _, let isError, _, _, _, _) = part,
                      id == callID else { return nil }
                return isError
            }
        #expect(outcomes == [false, true])
        let terminal = try #require(engine.contextWritebackGate.lifecycleStore?.record(for: identity))
        #expect(terminal.status == .completed && terminal.terminalTruth?.outcome == .succeeded)

        first.approve()
        first.approve()
        #expect(center.pendingRequest == nil)
        #expect(try Data(contentsOf: file) == Data(marker.utf8))
        #expect(await receipts.values == accepted)
        #expect(facts.facts == [fact] && facts.pendingReceipts.isEmpty)
        #expect(changes.records(sessionID: session) == records)
        // Reopen only after the producer is terminal: opening the durable fact
        // ledger takes over its writer fence. FileChangeLedger stays in memory.
        let reopenedFacts = try ToolExecutionFactLedger(persistenceURL: factURL)
        #expect(reopenedFacts.facts == [fact] && reopenedFacts.pendingReceipts.isEmpty)
        #expect(reopenedFacts.fact(compositeKey: key, receiptID: fact.receiptID) == fact)
        let reopenedTurns = try AgentTurnContextStore(persistenceURL: turnURL)
        #expect(reopenedTurns.record(for: identity) == terminal)
    }

    @Test func alwaysAskToolTriggersApprovalAndExecutesAfterAllow() async throws {
        let center = makeCenter()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("E6AlwaysAsk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try ToolExecutionFactLedger(
            persistenceURL: root.appendingPathComponent("tool-execution-facts-v4.json")
        )
        let executor = E6RecordingExecutor()
        let engine = AgentLoopChatEngine(
            toolExecutor: e6PolicyBoundExecutor(executor),
            approvalDelegate: ApprovalPromptDelegate(center: center),
            toolExecutionFactLedger: ledger
        )
        let provider = E6ScriptedProvider(responses: [
            e6ToolCallEnvelope(id: "call_1", name: "file_write", input: ["path": "/tmp/a.txt", "content": "SECRET_BODY"]),
            "写入完成。",
        ])
        let stream = try await engine.streamReply(
            provider: provider,
            history: [ChatMessageUI(role: .user, content: "写个文件")],
            systemPrompt: "test",
            maxTokens: 1024,
            conversationID: "e6-always-ask",
            authorizedSessionReadSessionID: nil,
            turnID: 1
        )
        let consume = Task {
            var text = ""
            for try await event in stream {
                if case .textDelta(let t) = event { text += t }
            }
            return text
        }

        // 工具调用被拦截 → 弹窗出现（脱敏摘要已由 ApprovalGate 生成）
        for _ in 0..<100 where center.pendingRequest == nil {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let request = try #require(center.pendingRequest)
        #expect(request.toolName == "file_write")
        #expect(request.riskLevel == .high)
        #expect(!request.inputSummary.contains("SECRET_BODY")) // content 被脱敏
        #expect(request.inputSummary.contains("/tmp/a.txt"))

        center.resolve(approved: true, confirmed: true)
        let text = try await consume.value
        #expect(executor.executedNames == ["file_write"])
        #expect(text.contains("写入完成。"))
    }

    @Test func deniedToolNeverExecutes() async throws {
        let center = makeCenter()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("E6Denied-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try ToolExecutionFactLedger(
            persistenceURL: root.appendingPathComponent("tool-execution-facts-v4.json")
        )
        let executor = E6RecordingExecutor()
        let engine = AgentLoopChatEngine(
            toolExecutor: e6PolicyBoundExecutor(executor),
            approvalDelegate: ApprovalPromptDelegate(center: center),
            toolExecutionFactLedger: ledger
        )
        let provider = E6ScriptedProvider(responses: [
            e6ToolCallEnvelope(id: "call_1", name: "shell_execute", input: ["command": "rm -rf /"]),
            "已停止，未执行。",
        ])
        let stream = try await engine.streamReply(
            provider: provider,
            history: [ChatMessageUI(role: .user, content: "跑命令")],
            systemPrompt: "test",
            maxTokens: 1024,
            conversationID: "e6-denied",
            authorizedSessionReadSessionID: nil,
            turnID: 1
        )
        let consume = Task {
            var text = ""
            for try await event in stream {
                if case .textDelta(let t) = event { text += t }
            }
            return text
        }

        for _ in 0..<100 where center.pendingRequest == nil {
            try? await Task.sleep(for: .milliseconds(20))
        }
        center.resolve(approved: false, reason: "用户拒绝", confirmed: false)

        let text = try await consume.value
        #expect(executor.executedNames.isEmpty) // 拒绝的工具未执行
        #expect(text.contains("已停止，未执行。"))
    }

    @Test func autoApproveToolSkipsDialog() async throws {
        let center = makeCenter()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("E6AutoApprove-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try ToolExecutionFactLedger(
            persistenceURL: root.appendingPathComponent("tool-execution-facts-v4.json")
        )
        let executor = E6RecordingExecutor()
        let engine = AgentLoopChatEngine(
            toolExecutor: e6PolicyBoundExecutor(executor),
            approvalDelegate: ApprovalPromptDelegate(center: center),
            toolExecutionFactLedger: ledger
        )
        let provider = E6ScriptedProvider(responses: [
            e6ToolCallEnvelope(id: "call_1", name: "file_read", input: ["path": "/tmp/a.txt"]),
            "读取完成。",
        ])
        let stream = try await engine.streamReply(
            provider: provider,
            history: [ChatMessageUI(role: .user, content: "读文件")],
            systemPrompt: "test",
            maxTokens: 1024,
            conversationID: "e6-auto-approve",
            authorizedSessionReadSessionID: nil,
            turnID: 1
        )
        var text = ""
        for try await event in stream {
            if case .textDelta(let t) = event { text += t }
        }
        #expect(executor.executedNames == ["file_read"])
        #expect(center.pendingRequest == nil) // 低风险工具不弹窗
        #expect(text.contains("读取完成。"))
    }

    @Test func plainTextReplyNeverTriggersApproval() async throws {
        let center = makeCenter()
        let executor = E6RecordingExecutor()
        let engine = AgentLoopChatEngine(
            toolExecutor: e6PolicyBoundExecutor(executor),
            approvalDelegate: ApprovalPromptDelegate(center: center)
        )
        let provider = E6ScriptedProvider(responses: ["你好，我是助手。"])
        let stream = try await engine.streamReply(
            provider: provider,
            history: [ChatMessageUI(role: .user, content: "你好")],
            systemPrompt: "test",
            maxTokens: 1024,
            conversationID: "e6-plain-text",
            authorizedSessionReadSessionID: nil,
            turnID: 1
        )
        var text = ""
        for try await event in stream {
            if case .textDelta(let t) = event { text += t }
        }
        #expect(center.pendingRequest == nil)
        #expect(text.contains("你好，我是助手。"))
    }
}


private struct E6CallerState: Sendable {
    var request: ApprovalRequest?
    var decision: ApprovalDecision?
    var approvedReceipts = 0
    var streamTerminationCancelled = false
    var consumerEnded = false
}

private typealias E6CallerRecorder = OSAllocatedUnfairLock<E6CallerState>

/// Transparent recording around the actual production delegate, with no verdict
/// substitution. The provider, executor and policy wrapper above are reused.
private struct E6CallerRecordingDelegate: ApprovalDelegate {
    let base: ApprovalPromptDelegate
    let recorder: E6CallerRecorder

    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        recorder.withLock { $0.request = request }
        let decision = await base.requestApproval(request)
        recorder.withLock { $0.decision = decision }
        return decision
    }
}

@Suite("D-TOOL-08 real approval cancellation callers 346")
@MainActor
struct ApprovalCancellationCaller346Tests {
    private struct Fixture {
        let profile: RuntimeIsolationProfile
        let center: ApprovalPromptCenter
        let chat: ChatStore
        let engine: AgentLoopChatEngine
        let executor: E6RecordingExecutor
        let recorder: E6CallerRecorder
    }

    private func makeFixture() throws -> Fixture {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "approval-caller346", canvasRuntimeState: .disabled
        )
        #expect(!profile.allowsExternalNetwork)
        let chat = ChatStore(
            preferencesDefaults: profile.makeUserDefaults(), logManager: profile.makeLogManager()
        )
        let center = ApprovalPromptCenter()
        let recorder = E6CallerRecorder(initialState: E6CallerState())
        let facts = ComposerPolicyFactSource(
            knownCapabilities: ["file_write"], grantedCapabilities: ["file_write"],
            allowedWriteRoots: ["/tmp"], workspaceID: chat.composerWorkspaceID,
            revision: "caller346-policy", grantEpoch: "caller346-epoch",
            leaseID: UUID().uuidString, expiresAt: Date().addingTimeInterval(60),
            autonomyCeiling: .l2
        )
        chat.configureComposerPolicy(facts)
        let executor = E6RecordingExecutor()
        let delegate = E6CallerRecordingDelegate(
            base: ApprovalPromptDelegate(center: center), recorder: recorder
        )
        let gate = ApprovalGate(delegate: delegate, onApprovalReceipt: { _ in
            recorder.withLock { $0.approvedReceipts += 1 }
        })
        // Real tool execution requires durable fact authority after approval.
        // Keep that authority in this synthetic profile, as in the E6 allow fixture.
        let toolFacts = try ToolExecutionFactLedger(
            persistenceURL: profile.rootDirectory.appendingPathComponent("tool-execution-facts-v4.json")
        )
        let engine = AgentLoopChatEngine(
            toolExecutor: e6PolicyBoundExecutor(executor), approvalGate: gate,
            contextWritebackGate: ContextOrchestrator.AgentLoopWritebackGate(),
            toolExecutionFactLedger: toolFacts,
            composerPolicyFacts: facts,
            onComposerApprovalReceipt: { _ in recorder.withLock { $0.approvedReceipts += 1 } },
            onRetryLifecycleEvent: { event in
                if event == .cancelled { recorder.withLock { $0.streamTerminationCancelled = true } }
            }
        )
        chat.agentEngine = engine
        // Reuse the ordinary-send runtime contract from AgentEngineTests.
        // Real AgentLoop submissions fail closed without this frozen snapshot.
        let injector = SkillInjector(store: SkillStore(skillsRoot: profile.hermesSkillsDirectory))
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            ChatTurnRuntimeSnapshot(turn: turn, skillInjector: injector.snapshotForTurn(), mcpBridge: nil)
        }
        chat.streamingProviderOverride = scriptedProvider(callID: "caller346-old")
        print("CALLER346_ISOLATED_PROFILE=" + profile.rootDirectory.path)
        return Fixture(profile: profile, center: center, chat: chat,
                       engine: engine, executor: executor, recorder: recorder)
    }

    private func scriptedProvider(callID: String) -> E6ScriptedProvider {
        E6ScriptedProvider(responses: [
            e6ToolCallEnvelope(id: callID, name: "file_write",
                              input: ["path": "/tmp/caller346-synthetic.txt", "content": "synthetic"]),
            "synthetic complete"
        ])
    }

    private func observe(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private func cleanUp(_ fixture: Fixture, consumer: Task<Void, Never>? = nil) async {
        consumer?.cancel()
        fixture.chat.stopAllStreamingForSafety()
        fixture.center.stopGeneration()
        if fixture.recorder.withLock({ $0.request != nil }) {
            #expect(await observe { fixture.recorder.withLock { $0.decision != nil } },
                    "own approval fixture must finish after cleanup")
        }
        if consumer != nil {
            #expect(await observe { fixture.recorder.withLock { $0.consumerEnded } },
                    "own stream consumer must finish after cleanup")
        }
        // Profiles and original evidence are retained; no deletion/Keychain cleanup.
    }

    private func expectCancelledWithoutToolEffects(_ fixture: Fixture, reason: String? = nil) {
        let state = fixture.recorder.withLock { $0 }
        #expect(state.request != nil, "the actual gate must reach the real delegate")
        #expect(state.decision?.approved == false)
        #expect(state.decision?.confirmed == false)
        #expect(state.decision?.status == .cancelled)
        #expect(state.decision?.requestID == state.request?.requestID)
        #expect(state.decision?.bindingDigest == state.request?.identityDigest)
        if let reason { #expect(state.decision?.reason == reason) }
        #expect(fixture.center.pendingRequest == nil)
        #expect(fixture.executor.executedNames.isEmpty)
        #expect(state.approvedReceipts == 0)
    }

    @Test func submitComposerStopUsesProductionStopAssembly() async throws {
        let fixture = try makeFixture()
        // This is the same method invoked by attachProductionServices, without
        // constructing BridgeStore's unrelated default Workflow/Browser services.
        BridgeStore.bindApprovalStopLifecycle(chat: fixture.chat, approvalCenter: fixture.center)
        fixture.chat.draftText = "synthetic stop while awaiting approval"
        fixture.chat.submitComposer()
        guard await observe({ fixture.center.pendingRequest != nil }) else {
            Issue.record("production submission did not reach approval; synthetic transcript: \(fixture.chat.messages.map(\.content))")
            await cleanUp(fixture)
            return
        }
        #expect(fixture.chat.isActiveSessionStreaming)
        #expect(fixture.executor.executedNames.isEmpty)
        fixture.chat.stopStreaming()
        #expect(await observe { fixture.recorder.withLock { $0.decision != nil } })
        #expect(await observe { fixture.recorder.withLock { $0.streamTerminationCancelled } })
        expectCancelledWithoutToolEffects(fixture, reason: "生成已停止")
        #expect(!fixture.chat.isActiveSessionStreaming)
        // Late UI approval cannot execute the stopped call.
        fixture.center.approvePending()
        fixture.center.confirmPending()
        #expect(fixture.executor.executedNames.isEmpty)
        await cleanUp(fixture)
    }

    @Test func deletingNonactiveWaitingSessionCancelsOnlyItsRealStream() async throws {
        let fixture = try makeFixture()
        let chat = fixture.chat
        let sessionA = try #require(chat.activeSessionID)
        // This deletion branch has no global stop callback. It must propagate
        // cancellation through the real stream consumer and its onTermination.
        #expect(chat.onStreamingStopped == nil)
        chat.draftText = "synthetic background approval"
        chat.submitComposer()
        guard await observe({ fixture.center.pendingRequest != nil }) else {
            Issue.record("session A did not reach approval; synthetic transcript: \(chat.messages.map(\.content))")
            await cleanUp(fixture)
            return
        }
        #expect(fixture.center.pendingRequest?.sessionID == sessionA.uuidString)
        let sessionB = chat.applyNewSession(title: "synthetic keeper")
        chat.draftText = "keeper draft"
        let keeperMessages = chat.messages.map(\.content)
        #expect(chat.activeSessionID == sessionB)
        #expect(fixture.center.pendingRequest != nil, "switch preserves the background A turn")
        let intent = try chat.previewDeletion(id: sessionA)
        // The target is in-memory synthetic data, and the original deletion
        // gate still requires its bound two-step confirmations.
        let confirmed = intent.withFirstConfirmation("synthetic preview checked")
            .withSecondConfirmation("永久删除")
        _ = try chat.deleteSession(id: sessionA, intent: confirmed)
        #expect(await observe { fixture.recorder.withLock { $0.decision != nil } })
        #expect(await observe { fixture.recorder.withLock { $0.streamTerminationCancelled } })
        expectCancelledWithoutToolEffects(fixture, reason: "审批调用任务已取消")
        #expect(!chat.sessions.contains { $0.id == sessionA })
        #expect(chat.activeSessionID == sessionB)
        #expect(chat.draftText == "keeper draft")
        #expect(chat.messages.map(\.content) == keeperMessages)

        // Positive control: the same real consumer reaches the executor only
        // after a fresh B request is approved, so zero effects above are not
        // explained by an unreachable/always-blocked execution fixture.
        fixture.recorder.withLock { $0 = E6CallerState() }
        let freshProvider = scriptedProvider(callID: "caller346-fresh")
        chat.streamingProviderOverride = freshProvider
        chat.draftText = "synthetic fresh approved turn"
        chat.submitComposer()
        guard await observe({ fixture.center.pendingRequest != nil }) else {
            Issue.record("fresh keeper turn did not reach approval")
            await cleanUp(fixture)
            return
        }
        #expect(fixture.center.pendingRequest?.sessionID == sessionB.uuidString)
        #expect(fixture.center.pendingRequest?.callID == "caller346-fresh")
        // file_write 不是不可逆操作：一次点击即执行（2026-11-16）。
        #expect(fixture.center.pendingRequest?.requiresSecondConfirmation == false)
        #expect(fixture.executor.executedNames.isEmpty)
        #expect(fixture.recorder.withLock { $0.approvedReceipts } == 0)
        fixture.center.approvePending()
        #expect(await observe { !chat.isActiveSessionStreaming })
        #expect(fixture.executor.executedNames == ["file_write"],
                "synthetic provider tool results: \(freshProvider.lastReceivedMessages.map(\.content))")
        #expect(fixture.recorder.withLock { $0.approvedReceipts } == 1)
        await cleanUp(fixture)
    }

    @Test func cancelledRealEngineStreamConsumerTerminatesPendingApproval() async throws {
        let fixture = try makeFixture()
        let stream = try await fixture.engine.streamReply(
            provider: scriptedProvider(callID: "caller346-termination"),
            history: [ChatMessageUI(role: .user, content: "synthetic stream termination")],
            systemPrompt: "synthetic", maxTokens: 1024,
            conversationID: UUID().uuidString, authorizedSessionReadSessionID: nil, turnID: 1
        )
        let consumer = Task {
            do { for try await _ in stream {} } catch {}
            fixture.recorder.withLock { $0.consumerEnded = true }
        }
        guard await observe({ fixture.center.pendingRequest != nil }) else {
            Issue.record("engine stream did not reach approval")
            await cleanUp(fixture, consumer: consumer)
            return
        }
        consumer.cancel()
        #expect(await observe { fixture.recorder.withLock { $0.consumerEnded && $0.decision != nil } })
        #expect(fixture.recorder.withLock { $0.streamTerminationCancelled })
        expectCancelledWithoutToolEffects(fixture, reason: "审批调用任务已取消")
        await cleanUp(fixture, consumer: consumer)
    }

    @Test func lateStopFromCompletedTurnPreservesFreshSameSessionApproval788() async throws {
        let fixture = try makeFixture()
        let chat = fixture.chat
        BridgeStore.bindApprovalStopLifecycle(chat: chat, approvalCenter: fixture.center)
        let session = try #require(chat.activeSessionID)
        chat.draftText = "synthetic first approved turn"
        chat.submitComposer()
        guard await observe({ fixture.center.pendingRequest != nil }) else {
            Issue.record("first same-session turn did not reach approval")
            await cleanUp(fixture)
            return
        }
        let oldIdentity = try #require(chat.activeExecutionIdentity(for: session))
        #expect(fixture.executor.executedNames.isEmpty)
        fixture.center.approvePending()
        #expect(await observe { !chat.isActiveSessionStreaming })
        #expect(fixture.executor.executedNames == ["file_write"])
        #expect(fixture.recorder.withLock { $0.approvedReceipts } == 1)

        fixture.recorder.withLock { $0 = E6CallerState() }
        chat.streamingProviderOverride = scriptedProvider(callID: "caller788-same-session-fresh")
        chat.draftText = "synthetic fresh same-session approval"
        chat.submitComposer()
        guard await observe({ fixture.center.pendingRequest != nil }) else {
            Issue.record("fresh same-session turn did not reach approval")
            await cleanUp(fixture)
            return
        }
        let freshRequest = try #require(fixture.center.pendingRequest)
        let freshIdentity = try #require(chat.activeExecutionIdentity(for: session))
        #expect(oldIdentity.turn.sessionID == freshIdentity.turn.sessionID)
        #expect(oldIdentity != freshIdentity)
        // Deliver a delayed stop through the exact endpoint installed by Bridge,
        // carrying a real previous producer identity, rather than a guessed UUID.
        let scopedStop = try #require(chat.onTurnStreamingStopped)
        scopedStop(oldIdentity)
        #expect(fixture.center.pendingRequest?.identityDigest == freshRequest.identityDigest)
        #expect(fixture.recorder.withLock { $0.decision == nil })
        #expect(chat.isActiveSessionStreaming)
        #expect(fixture.executor.executedNames == ["file_write"])
        #expect(fixture.recorder.withLock { $0.approvedReceipts } == 0)
        // The actual fresh owner must still settle its prompt, so a no-op
        // scoped implementation cannot satisfy both sides of this test.
        chat.stopStreaming()
        #expect(await observe { fixture.recorder.withLock { $0.decision != nil } })
        #expect(fixture.recorder.withLock { $0.decision?.reason } == "生成已停止")
        #expect(!chat.isActiveSessionStreaming)
        #expect(fixture.executor.executedNames == ["file_write"])
        #expect(fixture.recorder.withLock { $0.approvedReceipts } == 0)
        fixture.center.approvePending()
        fixture.center.confirmPending()
        #expect(fixture.executor.executedNames == ["file_write"])
        await cleanUp(fixture)
    }

    @Test(arguments: ["foreign", "own", "all"])
    func stopUsesActualTurnWithoutCancellingAnotherSessionsApproval788(_ action: String) async throws {
        let fixture = try makeFixture()
        let chat = fixture.chat
        BridgeStore.bindApprovalStopLifecycle(chat: chat, approvalCenter: fixture.center)
        let paused = E6PausedProvider788()
        chat.streamingProviderOverride = paused
        let sessionA = try #require(chat.activeSessionID)
        chat.draftText = "synthetic A waits in actual Provider"
        chat.submitComposer()
        guard await observe({ paused.started }) else {
            Issue.record("A did not reach the actual Provider")
            await cleanUp(fixture)
            return
        }
        let sessionB = chat.applyNewSession(title: "synthetic B approval")
        chat.streamingProviderOverride = scriptedProvider(callID: "caller788-B")
        chat.draftText = "synthetic B waits in real approval"
        chat.submitComposer()
        guard await observe({ fixture.center.pendingRequest != nil }) else {
            Issue.record("B did not reach the real approval consumer")
            await cleanUp(fixture)
            return
        }
        let requestB = try #require(fixture.center.pendingRequest)
        #expect(requestB.sessionID == sessionB.uuidString)
        #expect(fixture.executor.executedNames.isEmpty)
        #expect(fixture.recorder.withLock { $0.approvedReceipts } == 0)
        if action == "foreign" {
            chat.switchSession(id: sessionA)
            #expect(chat.isActiveSessionStreaming)
            chat.stopStreaming()
            #expect(await observe { paused.cancelled })
            #expect(!chat.isActiveSessionStreaming)
            #expect(fixture.center.pendingRequest?.identityDigest == requestB.identityDigest,
                    "stopping A must preserve B's exact pending approval")
            #expect(fixture.recorder.withLock { $0.decision == nil },
                    "A's stop must not decide B's request")
            chat.switchSession(id: sessionB)
            #expect(chat.isActiveSessionStreaming)
            guard fixture.center.pendingRequest != nil else {
                await cleanUp(fixture)
                return
            }
            #expect(fixture.executor.executedNames.isEmpty)
            fixture.center.approvePending()
            #expect(await observe { !chat.isActiveSessionStreaming })
            #expect(fixture.executor.executedNames == ["file_write"])
            #expect(fixture.recorder.withLock { $0.approvedReceipts } == 1)
            #expect(fixture.recorder.withLock { $0.decision?.bindingDigest } == requestB.identityDigest)
        } else if action == "own" {
            chat.stopStreaming()
            #expect(await observe { fixture.recorder.withLock { $0.decision != nil } })
            expectCancelledWithoutToolEffects(fixture, reason: "生成已停止")
            chat.switchSession(id: sessionA)
            #expect(chat.isActiveSessionStreaming)
            #expect(!paused.cancelled, "B's stop must preserve A's actual Provider")
        } else {
            chat.stopAllStreamingForSafety()
            #expect(await observe { paused.cancelled })
            #expect(await observe { fixture.recorder.withLock { $0.decision != nil } })
            expectCancelledWithoutToolEffects(fixture, reason: "生成已停止")
            #expect(!chat.isStreaming)
        }
        await cleanUp(fixture)
        #expect(await observe { paused.cancelled })
    }
}

/// Synthetic cancellable Provider; the real AgentLoop/ChatStore own its task.
private final class E6PausedProvider788: LLMProvider {
    var name: String { "E6Paused788" }
    var model = LLMModel(id: "paused788", displayName: "Paused788", provider: "E6Paused788")
    var capabilities: Set<ProviderCapability> { [.tools] }
    private let state = OSAllocatedUnfairLock(initialState: (started: false, cancelled: false))
    var started: Bool { state.withLock { $0.started } }
    var cancelled: Bool { state.withLock { $0.cancelled } }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        state.withLock { $0.started = true }
        do { try await Task.sleep(for: .seconds(60)) }
        catch {
            state.withLock { $0.cancelled = true }
            throw error
        }
        return LLMResponse(text: "synthetic A complete", stopReason: nil, usage: nil)
    }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt,
                              maxTokens: maxTokens, temperature: temperature)
    }

    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
