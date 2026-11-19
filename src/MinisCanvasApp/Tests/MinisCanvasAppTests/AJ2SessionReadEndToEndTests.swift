import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private final class AJ2SessionReadProvider: LLMProvider, @unchecked Sendable {
    var name: String { "AJ2 session read test provider" }
    var model = LLMModel(id: "aj2-test", displayName: "AJ2 Test", provider: "Test")
    var capabilities: Set<ProviderCapability> { [.tools] }
    private var responses: [LLMResponse]
    struct Request {
        let messages: [LLMMessage]
        let systemPrompt: String?
        let toolNames: [String]
    }
    private var requestItems: [Request] = []
    private var outputItems: [String] = []
    private var actionItems: [ActionRecord] = []
    private var approvalItems: [ApprovalReceipt] = []
    private var traceItems: [String] = []
    var approvalReceipts: [ApprovalReceipt] { lock.lock(); defer { lock.unlock() }; return approvalItems }
    var approvalTrace: [String] { lock.lock(); defer { lock.unlock() }; return traceItems }
    func recordApproval(_ receipt: ApprovalReceipt) {
        lock.lock(); defer { lock.unlock() }
        approvalItems.append(receipt); traceItems.append("approval-receipt")
    }
    func recordApprovalTrace(_ stage: String) {
        lock.lock(); defer { lock.unlock() }; traceItems.append(stage)
    }
    var requests: [Request] { lock.lock(); defer { lock.unlock() }; return requestItems }
    var toolOutputs: [String] { lock.lock(); defer { lock.unlock() }; return outputItems }
    var actionRecords: [ActionRecord] { lock.lock(); defer { lock.unlock() }; return actionItems }
    private(set) var receivedToolNames: [String] = []
    private let lock = NSLock()

    init(responses: [String]) {
        self.responses = responses.map { LLMResponse(text: $0, stopReason: "stop", usage: nil) }
    }

    init(nativeResponses: [LLMResponse]) {
        self.responses = nativeResponses
    }

    func recordOutput(_ output: String) {
        lock.lock(); defer { lock.unlock() }
        outputItems.append(output)
    }

    func recordAction(_ action: ActionRecord) {
        lock.lock(); defer { lock.unlock() }
        actionItems.append(action)
    }

    private func recordRequest(messages: [LLMMessage], systemPrompt: String?) {
        lock.lock(); defer { lock.unlock() }
        requestItems.append(Request(messages: messages, systemPrompt: systemPrompt, toolNames: receivedToolNames))
    }

    private func takeResponse() -> LLMResponse {
        lock.lock()
        defer { lock.unlock() }
        return responses.isEmpty ? LLMResponse(text: "没有更多响应", stopReason: "stop", usage: nil) : responses.removeFirst()
    }

    private func recordTools(_ tools: [AgentToolDefinition]) {
        lock.lock()
        receivedToolNames = tools.map(\.name)
        lock.unlock()
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        recordRequest(messages: messages, systemPrompt: systemPrompt)
        return takeResponse()
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        recordTools(tools)
        return try await sendMessage(
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
            continuation.finish()
        }
    }
}

private actor AJ2SessionReadApprovalDelegate: ApprovalDelegate {
    private(set) var requests: [ApprovalRequest] = []

    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        requests.append(request)
        return ApprovalDecision(
            approved: true,
            reason: "AJ2 session_read lifecycle test approval",
            confirmed: true,
            requestID: request.requestID,
            bindingDigest: request.identityDigest
        )
    }
}

/// Card the user would see for a model `session_read` call: records it, checks
/// target ID and scope are shown, and answers with the configured decision.
private actor AJ2SessionReadCardApproval: ApprovalDelegate {
    let target: String
    let scope: String
    let allow: Bool
    private(set) var requests: [ApprovalRequest] = []

    init(target: String, scope: String, allow: Bool) {
        self.target = target; self.scope = scope; self.allow = allow
    }

    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        requests.append(request)
        let shown = request.toolName == SessionReadTool.toolName
            && request.requiresApproval
            && request.inputSummary.contains("session_id: \(target)")
            && request.inputSummary.contains("scope: \(scope)")
        let approved = shown && allow
        return ApprovalDecision(
            approved: approved,
            reason: approved ? "AJ2 card approved" : (shown ? "AJ2 card denied" : "AJ2 card unexpected"),
            confirmed: approved,
            requestID: request.requestID,
            bindingDigest: request.identityDigest
        )
    }
}

private func aj2ToolCallEnvelope(
    id: String,
    name: String,
    input: [String: Any]
) -> String {
    let object: [String: Any] = [
        "tool_calls": [["id": id, "name": name, "input": input]],
    ]
    let data = try! JSONSerialization.data(withJSONObject: object)
    return String(data: data, encoding: .utf8)!
}

private func aj2LifecycleInput(for sessionID: String) -> [String: Any] {
    [
        "session_id": sessionID,
        "scope": "messages",
        "offset": 0,
        "limit": 1,
        "max_chars": 200,
    ]
}

/// The production executor is held by a MainActor-owned BridgeStore in this
/// focused test. Keep the actor crossing at this explicit, test-only seam;
/// production protocol sendability is intentionally unchanged.
private final class AJ2SessionReadExecutorBox: SessionReadCapabilityAwareToolExecutor, PolicyRuntimeBoundToolExecutor, @unchecked Sendable {
    private let executorLock = NSLock()
    private var executor: any SessionReadCapabilityAwareToolExecutor

    private var currentExecutor: any SessionReadCapabilityAwareToolExecutor {
        executorLock.lock()
        defer { executorLock.unlock() }
        return executor
    }

    func observe(_ executor: any SessionReadCapabilityAwareToolExecutor) {
        executorLock.lock()
        defer { executorLock.unlock() }
        self.executor = executor
    }

    private let onOutput: @Sendable (String) -> Void
    private let onObservation: (@Sendable (String, String, String) -> Void)?
    var policyRuntimeBound: Bool {
        (currentExecutor as? any PolicyRuntimeBoundToolExecutor)?.policyRuntimeBound == true
    }

    init(executor: any SessionReadCapabilityAwareToolExecutor, onOutput: @escaping @Sendable (String) -> Void = { _ in },
         onObservation: (@Sendable (String, String, String) -> Void)? = nil) {
        self.executor = executor
        self.onOutput = onOutput
        self.onObservation = onObservation
    }

    func execute(name: String, input: [String: Any]) async throws -> String {
        onObservation?("legacy-enter", "", "")
        return try await currentExecutor.execute(name: name, input: input)
    }

    func executeSessionRead(
        input: [String: Any],
        authorization: CrossSessionReadAuthorization,
        context: SessionReadExecutionContext,
        now: Date
    ) async throws -> String {
        onObservation?("typed-enter", "", "")
        do {
            let output = try await currentExecutor.executeSessionRead(
                input: input,
                authorization: authorization,
                context: context,
                now: now
            )
            // Observe the exact returned body of the unchanged production chain;
            // do not synthesize a result or use the later fixed provider reply.
            onOutput(output)
            onObservation?("typed-success", "", "")
            return output
        } catch {
            onObservation?("typed-throw", String(reflecting: type(of: error)), error.localizedDescription)
            throw error
        }
    }
}

/// Counts only calls that cross the final capability-aware executor seam. A
/// denied model tool call must stop before this boundary and therefore before
/// SessionManager can load the target transcript.
private final class AJ2SessionReadCallCounter: SessionReadCapabilityAwareToolExecutor, @unchecked Sendable {
    private let base: any SessionReadCapabilityAwareToolExecutor
    private let lock = NSLock()
    private var count = 0

    init(base: any SessionReadCapabilityAwareToolExecutor) {
        self.base = base
    }

    var sessionReadCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    private func record(_ name: String) {
        guard name == SessionReadTool.toolName else { return }
        lock.lock()
        count += 1
        lock.unlock()
    }

    func execute(name: String, input: [String: Any]) async throws -> String {
        record(name)
        return try await base.execute(name: name, input: input)
    }

    func executeSessionRead(
        input: [String: Any],
        authorization: CrossSessionReadAuthorization,
        context: SessionReadExecutionContext,
        now: Date
    ) async throws -> String {
        record(SessionReadTool.toolName)
        return try await base.executeSessionRead(
            input: input,
            authorization: authorization,
            context: context,
            now: now
        )
    }
}

/// Keep the observation seam outside the freshly bound production executor.
/// The original callback still creates and installs the real task Goal/lease;
/// this decorator observes its result without reusing a prior task's authority.
@MainActor
private func observeAJ2TaskPolicy(
    bridge: BridgeStore,
    prepare: ((String, Date, UUID?, Bool) -> Bool)?,
    box: AJ2SessionReadExecutorBox,
    outerExecutor: any ToolExecutor
) {
    bridge.chat.prepareTopLevelTaskPolicy = { [weak bridge] taskID, createdAt, projectTargetID, projectTask in
        guard let bridge, let prepare, prepare(taskID, createdAt, projectTargetID, projectTask),
              let engine = bridge.chat.agentEngine as? AgentLoopChatEngine,
              let executor = engine.composedExecutor as? any SessionReadCapabilityAwareToolExecutor
        else { return false }
        box.observe(executor)
        bridge.chat.agentEngine = engine.withTopLevelTaskPolicy(
            executor: outerExecutor, facts: bridge.chat.composerPolicyFacts
        )
        return true
    }
}

@Suite("AJ-2 App typed session_read")
struct AJ2SessionReadEndToEndTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aj2-app-session-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    @Test func approvedModelCallReachesCapabilityAwareExecutor() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SessionStore(directory: directory)
        let manager = SessionManager(
            store: store,
            badgeStore: SessionBadgeStore(directory: directory)
        )
        let targetID = "target-session"
        try store.updateSession(ChatSession(
            id: targetID,
            title: "授权读取目标",
            messages: [LLMMessage(role: .user, content: "历史内容")],
            modelID: "test-model",
            providerTypeRaw: "test-provider"
        ))

        let provider = AJ2SessionReadProvider(responses: [
            aj2ToolCallEnvelope(
                id: "read-1",
                name: "session_read",
                input: ["session_id": targetID, "scope": "metadata"]
            ),
            "已按授权读取会话元数据。",
        ])
        let executor = redactionChain(directory: directory, manager: manager, provider: provider)
        let engine = AgentLoopChatEngine(
            toolExecutor: executor,
            maxIterations: 3,
            approvalGate: ApprovalGate(delegate: AJ2SessionReadApprovalDelegate()),
            toolExecutionFactLedger: try ToolExecutionFactLedger(
                persistenceURL: directory.appendingPathComponent("tool-execution-facts-v4.json")
            )
        )
        let stream = try await engine.streamReply(
            provider: provider,
            history: [
                ChatMessageUI(
                    role: .user,
                    content: "请授权查看会话 \(targetID) 的模型信息"
                ),
            ],
            systemPrompt: ChatStore.systemPrompt,
            maxTokens: 512,
            conversationID: "current-conversation",
            authorizedSessionReadSessionID: targetID,
            authorizedSessionReadScope: .metadata,
            turnID: 1
        )

        var output = ""
        for try await event in stream {
            if case .textDelta(let text) = event {
                output += text
            }
        }

        #expect(output.contains("已按授权读取"))
        #expect(provider.receivedToolNames.contains("session_read"))
    }

    /// S3：沿生产组合链（Concurrent → Recording → Policy → Builtin，与
    /// BridgeStore 装配一致）回归 —— 显式授权的 `session_read` 必须带着类型化
    /// capability 穿过整条链并留下 ActionRecord；旧的无类型入口必须保持 fail-closed
    /// （模型工具调用不能凭空铸造跨会话目标）。
    @Test func productionComposedChainPreservesExplicitAuthorizationAndStaysFailClosed() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SessionStore(directory: directory)
        let manager = SessionManager(
            store: store,
            badgeStore: SessionBadgeStore(directory: directory)
        )
        let targetID = "target-session"
        try store.updateSession(ChatSession(
            id: targetID,
            title: "授权读取目标",
            messages: [LLMMessage(role: .user, content: "历史内容")],
            modelID: "test-model",
            providerTypeRaw: "test-provider"
        ))

        let builtin = BuiltinToolExecutor(allowedRoot: directory, sessionManager: manager)
        let now = Date()
        let goal = GoalEnvelope(
            scopeID: "session:app-test",
            allowedCapabilities: [SessionReadTool.toolName],
            fileRoots: [directory.path],
            networkDomains: [],
            budget: 100,
            deadline: now.addingTimeInterval(3600),
            concurrencyLimit: 2,
            autonomyLevel: .l3,
            creatorID: "user:test",
            createdAt: now.addingTimeInterval(-1)
        )
        let lease = AutonomyLease(
            goalID: goal.goalID,
            scopeID: goal.scopeID,
            issuedAt: now.addingTimeInterval(-1),
            expiresAt: now.addingTimeInterval(3600)
        )
        let policy = PolicyEnforcedToolExecutor(
            base: builtin,
            goal: goal,
            lease: lease,
            capabilityResolver: builtin
        )
        final class RecordBox: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [ActionRecord] = []
            func append(_ record: ActionRecord) {
                lock.lock(); defer { lock.unlock() }
                items.append(record)
            }
            var latest: ActionRecord? {
                lock.lock(); defer { lock.unlock() }
                return items.last
            }
        }
        let recordBox = RecordBox()
        let recording = RecordingToolExecutor(base: policy, onRecorded: { record in
            recordBox.append(record)
        })
        let chain: any SessionReadCapabilityAwareToolExecutor = ConcurrentToolLimitingExecutor(
            base: recording,
            maxConcurrent: 2
        )

        // 1. 显式授权经整条链到达底层执行器，并留下成功记录。
        let authorization = CrossSessionReadAuthorization.issue(
            currentConversationID: "current-conversation",
            authorizedSessionID: targetID,
            turnID: 1,
            issuedAt: now,
            lifetime: 60
        )
        let output = try await chain.executeSessionRead(
            input: ["session_id": targetID, "scope": "metadata"],
            authorization: authorization,
            context: SessionReadExecutionContext(
                currentConversationID: "current-conversation",
                turnID: 1
            ),
            now: Date()
        )
        #expect(output.contains(targetID))
        #expect(output.contains("授权读取目标"))
        #expect(recordBox.latest?.toolName == SessionReadTool.toolName)
        #expect(recordBox.latest?.succeeded == true)

        // 2. 模型工具调用不能铸造目标：无类型入口整链保持 fail-closed。
        await #expect(throws: CrossSessionReadAuthorizationError.capabilityRequired) {
            _ = try await recording.execute(
                name: SessionReadTool.toolName,
                input: ["session_id": targetID, "scope": "metadata"]
            )
        }
    }

    /// P3-AGENT-SESSIONREAD-01：验证 BridgeStore 真实生产链上的 Safe Mode
    /// wrapper 不会把 typed capability 降级为旧的 `[String: Any]` 入口。
    @Test @MainActor
    func productionSafetyGatePreservesTypedSessionReadCapability() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDirectory = root.appendingPathComponent("sessions", isDirectory: true)
        let sessionStore = SessionStore(directory: sessionDirectory)
        // ChatStore projects persisted sessions through UUID-backed UI IDs.
        // A stable UUID keeps that production round-trip from treating this
        // fixture as an orphan before the typed read reaches SessionManager.
        let targetID = "00000000-0000-0000-0000-000000000201"
        try sessionStore.updateSession(ChatSession(
            id: targetID,
            title: "安全门授权读取目标",
            messages: [LLMMessage(role: .user, content: "隔离历史")],
            modelID: "test-model",
            providerTypeRaw: "test-provider"
        ))
        let persisted = try #require(sessionStore.loadSession(id: targetID))
        #expect(persisted.title == "安全门授权读取目标")
        #expect(FileManager.default.fileExists(
            atPath: sessionStore.sessionsDirectory
                .appendingPathComponent("\(targetID).json")
                .path
        ))

        let bridge = BridgeStore(
            sessionDocumentStore: SessionDocumentStore(
                directory: root.appendingPathComponent("documents", isDirectory: true)
            ),
            canvasRuntimeState: .absent,
            memoryStore: MemoryStore(
                directory: root.appendingPathComponent("memory", isDirectory: true)
            )
        )
        bridge.attachProductionServices(
            fileAccessAllowedRoot: root,
            fileAccessDeniedRoots: [],
            sessionDirectory: sessionDirectory,
            mcpManager: MCPServerManager(
                fileURL: root.appendingPathComponent("mcps.json")
            ),
            canvasRuntimeState: .absent
        )

        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        #expect(
            engine.chatRuntimeDependencies?.sessionStore.directory.standardizedFileURL
                == sessionDirectory.standardizedFileURL
        )
        let executor = try #require(
            engine.composedExecutor as? any SessionReadCapabilityAwareToolExecutor
        )
        let executorBox = AJ2SessionReadExecutorBox(executor: executor)
        let now = Date()
        let authorization = CrossSessionReadAuthorization.issue(
            currentConversationID: "current-conversation",
            authorizedSessionID: targetID,
            turnID: 7,
            issuedAt: now,
            lifetime: 60
        )
        let output = try await executorBox.executeSessionRead(
            input: ["session_id": targetID, "scope": "metadata"],
            authorization: authorization,
            context: SessionReadExecutionContext(
                currentConversationID: "current-conversation",
                turnID: 7
            ),
            now: now
        )

        #expect(output.contains(targetID))
        #expect(output.contains("安全门授权读取目标"))
    }

    /// P3-AGENT-SESSIONREAD-01 residual: orchestration-enabled production
    /// must preserve the typed capability through its composite wrapper.
    @Test @MainActor
    func productionOrchestrationCompositePreservesTypedSessionReadCapability() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDirectory = root.appendingPathComponent("sessions", isDirectory: true)
        let sessionStore = SessionStore(directory: sessionDirectory)
        let targetID = "00000000-0000-0000-0000-000000000202"
        try sessionStore.updateSession(ChatSession(
            id: targetID,
            title: "编排链授权读取目标",
            messages: [LLMMessage(role: .user, content: "编排隔离历史")],
            modelID: "test-model",
            providerTypeRaw: "test-provider"
        ))
        let persisted = try #require(sessionStore.loadSession(id: targetID))
        #expect(persisted.title == "编排链授权读取目标")
        #expect(FileManager.default.fileExists(
            atPath: sessionStore.sessionsDirectory
                .appendingPathComponent("\(targetID).json")
                .path
        ))

        let bridge = BridgeStore(
            sessionDocumentStore: SessionDocumentStore(
                directory: root.appendingPathComponent("documents", isDirectory: true)
            ),
            canvasRuntimeState: .absent,
            memoryStore: MemoryStore(
                directory: root.appendingPathComponent("memory", isDirectory: true)
            )
        )
        bridge.attachProductionServices(
            fileAccessAllowedRoot: root,
            fileAccessDeniedRoots: [],
            sessionDirectory: sessionDirectory,
            mcpManager: MCPServerManager(
                fileURL: root.appendingPathComponent("mcps.json")
            ),
            enableOrchestration: true,
            canvasRuntimeState: .absent
        )

        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        #expect(
            engine.chatRuntimeDependencies?.sessionStore.directory.standardizedFileURL
                == sessionDirectory.standardizedFileURL
        )
        #expect(engine.hasOrchestrationCapability)
        let executor = try #require(
            engine.composedExecutor as? any SessionReadCapabilityAwareToolExecutor
        )
        let executorBox = AJ2SessionReadExecutorBox(executor: executor)
        let now = Date()
        let authorization = CrossSessionReadAuthorization.issue(
            currentConversationID: "current-conversation",
            authorizedSessionID: targetID,
            turnID: 8,
            issuedAt: now,
            lifetime: 60
        )
        let output = try await executorBox.executeSessionRead(
            input: ["session_id": targetID, "scope": "metadata"],
            authorization: authorization,
            context: SessionReadExecutionContext(
                currentConversationID: "current-conversation",
                turnID: 8
            ),
            now: now
        )

        #expect(output.contains(targetID))
        #expect(output.contains("编排链授权读取目标"))
    }

    /// P3-READ-01：真实 App 组合链的 session_read capability 生命周期回归。
    /// 有效同 scope 走 AgentLoop + ApprovalGate + BridgeStore 生产 executor；
    /// 撤销、过期和跨 turn 的旧 capability 均在 SessionManager 读取前拒绝，
    /// 新 turn 只能用新 capability 且只能成功消费一次。
    @Test @MainActor
    func productionAppSessionReadLifecycleFencesStaleCapabilities() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDirectory = root.appendingPathComponent("sessions", isDirectory: true)
        let sessionStore = SessionStore(directory: sessionDirectory)
        let targetID = "00000000-0000-0000-0000-000000000203"
        let secret = "sk-p3-read-lifecycle-ABCDEFGHIJKLMNOP"
        let rawMessage = "Bearer \(secret) " + String(repeating: "可见正文", count: 90)
        try sessionStore.updateSession(ChatSession(
            id: targetID,
            title: "P3_READ_LIFECYCLE_TARGET",
            messages: [LLMMessage(role: .user, content: rawMessage)],
            modelID: "lifecycle-model",
            providerTypeRaw: "lifecycle-provider"
        ))

        let bridge = BridgeStore(
            sessionDocumentStore: SessionDocumentStore(
                directory: root.appendingPathComponent("documents", isDirectory: true)
            ),
            canvasRuntimeState: .absent,
            memoryStore: MemoryStore(
                directory: root.appendingPathComponent("memory", isDirectory: true)
            )
        )
        bridge.attachProductionServices(
            fileAccessAllowedRoot: root,
            fileAccessDeniedRoots: [],
            sessionDirectory: sessionDirectory,
            mcpManager: MCPServerManager(
                fileURL: root.appendingPathComponent("mcps.json")
            ),
            canvasRuntimeState: .absent
        )
        let productionEngine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let productionExecutor = try #require(
            productionEngine.composedExecutor as? any SessionReadCapabilityAwareToolExecutor
        )
        let provider = AJ2SessionReadProvider(nativeResponses: [
            LLMResponse(
                text: aj2ToolCallEnvelope(
                    id: "p3-read-lifecycle-valid",
                    name: SessionReadTool.toolName,
                    input: [
                        "session_id": targetID,
                        "scope": "messages",
                        "offset": 0,
                        "limit": 1,
                        "max_chars": 200,
                    ]
                ),
                stopReason: "tool_calls",
                usage: nil
            ),
            LLMResponse(text: "已完成授权读取", stopReason: "stop", usage: nil),
        ])
        let executor = AJ2SessionReadExecutorBox(
            executor: productionExecutor,
            onOutput: { provider.recordOutput($0) },
            onObservation: { stage, errorType, errorText in
                provider.recordApprovalTrace(
                    "\(stage):\(errorType):\(errorText)"
                )
            }
        )
        let approval = AJ2SessionReadApprovalDelegate()
        let gate = ApprovalGate(
            policyByTool: [SessionReadTool.toolName: .alwaysAsk],
            delegate: approval
        )
        let agent = AgentLoopChatEngine(
            toolExecutor: executor,
            maxIterations: 3,
            approvalGate: gate,
            toolExecutionFactLedger: try ToolExecutionFactLedger(
                persistenceURL: root.appendingPathComponent("facts.json")
            )
        )
        let conversationID = "p3-read-lifecycle-source"
        let stream = try await agent.streamReply(
            provider: provider,
            history: [ChatMessageUI(
                role: .user,
                content: "请授权读取会话 \(targetID) 的消息"
            )],
            systemPrompt: ChatStore.systemPrompt,
            maxTokens: 2048,
            conversationID: conversationID,
            authorizedSessionReadSessionID: targetID,
            authorizedSessionReadScope: .messages,
            turnID: 1
        )
        for try await _ in stream { }

        let approvalRequests = await approval.requests
        #expect(approvalRequests.count == 1)
        #expect(provider.requests.count == 2)
        let validOutput = try #require(provider.toolOutputs.first)
        let validObject = try #require(
            JSONSerialization.jsonObject(
                with: Data(validOutput.utf8)
            ) as? [String: Any]
        )
        #expect(validObject["ok"] as? Bool == true)
        #expect(validObject["scope"] as? String == "messages")
        #expect(validObject["offset"] as? Int == 0)
        #expect(validObject["limit"] as? Int == 1)
        #expect(validObject["max_chars"] as? Int == 200)
        let validMessages = try #require(validObject["messages"] as? [[String: Any]])
        #expect(validMessages.count == 1)
        #expect(validMessages.first?["truncated"] as? Bool == true)
        #expect(!validOutput.contains(secret))
        #expect(validOutput.contains("可见正文"))
        let outputCountAfterValid = provider.toolOutputs.count
        for _ in 0..<3 { await Task.yield() }
        let successfulActionCountAfterValid = bridge.actionHistory.records.filter(\.succeeded).count
        #expect(successfulActionCountAfterValid == 1)
        let actionRecordCountBeforeStale = bridge.actionHistory.records.count

        let baseNow = Date(timeIntervalSince1970: 10_000)
        let revokedController = TurnController()
        let revokedTurn = await revokedController.beginTurn()
        let revoked = await revokedTurn.issueSessionReadAuthorization(
            currentConversationID: conversationID,
            authorizedSessionID: targetID,
            issuedAt: baseNow,
            lifetime: 60,
            scope: .messages
        )
        await revokedTurn.revoke()
        let revokedContext = SessionReadExecutionContext(
            currentConversationID: conversationID,
            turnID: revokedTurn.turnID
        )
        await #expect(throws: CrossSessionReadAuthorizationError.revoked) {
            _ = try await executor.executeSessionRead(
                input: aj2LifecycleInput(for: targetID),
                authorization: revoked,
                context: revokedContext,
                now: baseNow.addingTimeInterval(1)
            )
        }
        // A repeated late callback stays revoked and cannot become a replay.
        await #expect(throws: CrossSessionReadAuthorizationError.revoked) {
            _ = try await executor.executeSessionRead(
                input: aj2LifecycleInput(for: targetID),
                authorization: revoked,
                context: revokedContext,
                now: baseNow.addingTimeInterval(2)
            )
        }
        await revokedTurn.finish()

        let expiryController = TurnController()
        let expiryTurn = await expiryController.beginTurn()
        let expired = await expiryTurn.issueSessionReadAuthorization(
            currentConversationID: conversationID,
            authorizedSessionID: targetID,
            issuedAt: baseNow,
            expiresAt: baseNow.addingTimeInterval(1),
            scope: .messages
        )
        let expiredContext = SessionReadExecutionContext(
            currentConversationID: conversationID,
            turnID: expiryTurn.turnID
        )
        await #expect(throws: CrossSessionReadAuthorizationError.expired) {
            _ = try await executor.executeSessionRead(
                input: aj2LifecycleInput(for: targetID),
                authorization: expired,
                context: expiredContext,
                now: baseNow.addingTimeInterval(2)
            )
        }
        await #expect(throws: CrossSessionReadAuthorizationError.expired) {
            _ = try await executor.executeSessionRead(
                input: aj2LifecycleInput(for: targetID),
                authorization: expired,
                context: expiredContext,
                now: baseNow.addingTimeInterval(3)
            )
        }
        await expiryTurn.finish()

        let turnController = TurnController()
        let oldTurn = await turnController.beginTurn()
        let oldCapability = await oldTurn.issueSessionReadAuthorization(
            currentConversationID: conversationID,
            authorizedSessionID: targetID,
            issuedAt: baseNow,
            lifetime: 60,
            scope: .messages
        )
        await oldTurn.finish()
        let newTurn = await turnController.beginTurn()
        let newCapability = await newTurn.issueSessionReadAuthorization(
            currentConversationID: conversationID,
            authorizedSessionID: targetID,
            issuedAt: baseNow,
            lifetime: 60,
            scope: .messages
        )
        let oldTurnContext = SessionReadExecutionContext(
            currentConversationID: conversationID,
            turnID: newTurn.turnID
        )
        await #expect(throws: CrossSessionReadAuthorizationError.turnEnded) {
            _ = try await executor.executeSessionRead(
                input: aj2LifecycleInput(for: targetID),
                authorization: oldCapability,
                context: oldTurnContext,
                now: baseNow.addingTimeInterval(1)
            )
        }
        // The same old capability cannot be resurrected by a second callback
        // or by supplying its original turn number after a new turn exists.
        await #expect(throws: CrossSessionReadAuthorizationError.turnEnded) {
            _ = try await executor.executeSessionRead(
                input: aj2LifecycleInput(for: targetID),
                authorization: oldCapability,
                context: SessionReadExecutionContext(
                    currentConversationID: conversationID,
                    turnID: oldTurn.turnID
                ),
                now: baseNow.addingTimeInterval(2)
            )
        }

        // Snapshot the records produced by the revoked/expired/ended-turn
        // calls before issuing the next turn's legitimate capability. The
        // fresh success below is intentionally a separate accepted action.
        for _ in 0..<3 { await Task.yield() }
        let staleRecords = bridge.actionHistory.records.dropFirst(actionRecordCountBeforeStale)
        #expect(staleRecords.filter(\.succeeded).isEmpty)

        let freshOutput = try await executor.executeSessionRead(
            input: aj2LifecycleInput(for: targetID),
            authorization: newCapability,
            context: SessionReadExecutionContext(
                currentConversationID: conversationID,
                turnID: newTurn.turnID
            ),
            now: baseNow.addingTimeInterval(1)
        )
        #expect(freshOutput.contains(targetID))
        await #expect(throws: CrossSessionReadAuthorizationError.replayed) {
            _ = try await executor.executeSessionRead(
                input: aj2LifecycleInput(for: targetID),
                authorization: newCapability,
                context: SessionReadExecutionContext(
                    currentConversationID: conversationID,
                    turnID: newTurn.turnID
                ),
                now: baseNow.addingTimeInterval(2)
            )
        }
        await newTurn.finish()

        // Revoked/expired/ended-turn calls never return a reader output or a
        // successful action. Only the valid first read and fresh new-turn read
        // are allowed to consume the real production SessionManager path.
        #expect(provider.toolOutputs.count == outputCountAfterValid + 1)
        let trace = provider.approvalTrace
        #expect(trace.filter { $0.hasPrefix("typed-success:") }.count == 2)
        #expect(trace.filter { $0.hasPrefix("typed-throw:") }.count == 7)
        #expect(bridge.actionHistory.records.filter(\.succeeded).count == 2)
    }


    private func redactionChain(
        directory: URL,
        manager: SessionManager,
        provider: AJ2SessionReadProvider
    ) -> AJ2SessionReadExecutorBox {
        let builtin = BuiltinToolExecutor(allowedRoot: directory, sessionManager: manager)
        let now = Date()
        let goal = GoalEnvelope(scopeID: "session:d05-fixture", allowedCapabilities: [SessionReadTool.toolName],
            fileRoots: [directory.path], networkDomains: [], budget: 100,
            deadline: now.addingTimeInterval(3600), concurrencyLimit: 2, autonomyLevel: .l3,
            creatorID: "user:d05-test", createdAt: now.addingTimeInterval(-1))
        let lease = AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID,
            issuedAt: now.addingTimeInterval(-1), expiresAt: now.addingTimeInterval(3600))
        let policy = PolicyEnforcedToolExecutor(base: builtin, goal: goal, lease: lease, capabilityResolver: builtin)
        let recording = RecordingToolExecutor(base: policy, onRecorded: { provider.recordAction($0) })
        let chain = ConcurrentToolLimitingExecutor(base: recording, maxConcurrent: 2)
        return AJ2SessionReadExecutorBox(executor: chain, onOutput: { provider.recordOutput($0) })
    }

    private func responseForRead(native: Bool, id: String, input: [String: Any]) throws -> LLMResponse {
        if native {
            let data = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
            let arguments = try #require(String(data: data, encoding: .utf8))
            return LLMResponse(text: "", stopReason: "tool_calls", usage: nil,
                toolCalls: [LLMToolCall(id: id, name: SessionReadTool.toolName, rawArguments: arguments, arguments: input)])
        }
        return LLMResponse(text: aj2ToolCallEnvelope(id: id, name: SessionReadTool.toolName, input: input), stopReason: "stop", usage: nil)
    }

    private func nextRequestToolBody(_ request: AJ2SessionReadProvider.Request, native: Bool, callID: String, expectedError: Bool = false) throws -> String {
        if native {
            let toolMessages = request.messages.filter { $0.role == .tool && $0.toolCallID == callID }
            #expect(toolMessages.count == 1)
            return try #require(toolMessages.first?.content)
        }
        let blocks = request.messages.filter { $0.role == .user }.flatMap { message -> [[String: Any]] in
            guard let data = message.content.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
            return value.filter { $0["type"] as? String == "tool_result" && $0["tool_use_id"] as? String == callID }
        }
        #expect(blocks.count == 1)
        let block = try #require(blocks.first)
        #expect(block["is_error"] as? Bool == expectedError)
        return try #require(block["content"] as? String)
    }

    @Test(arguments: [false, true])
    func recognizedSecretsStayMaskedThroughBothProviderRequestRoutes(native: Bool) async throws {
        // Each scope/archive combination has a new isolated store, executor,
        // capability turn and offline provider. No real sessions or secrets.
        for archived in [false, true] {
            for scope in [SessionReadScope.metadata, .messages] {
                let directory = try makeDirectory()
                defer { try? FileManager.default.removeItem(at: directory) }
                let store = SessionStore(directory: directory)
                let manager = SessionManager(store: store, badgeStore: SessionBadgeStore(directory: directory))
                let key = "sk-D05AppSyntheticKeyInteriorABCDEFGHIJ"
                let bearer = "D05AppSyntheticBearerInterior0123456789"
                let cookie = "D05AppSyntheticCookieInteriorABCDEFGHIJ"
                // Secrets occur beyond the original 80-character ActionRecord
                // projection: its summary alone cannot prove this regression.
                let ordinary = String(repeating: "普通正文", count: 30)
                let raw = "\(ordinary) \(key)\nBearer \(bearer)\nCookie: \(cookie); theme=dark\n可读尾部"
                // Cookie names do not identify whether a value is a credential:
                // even a short preference value is masked in the read projection.
                let safe = "\(ordinary) \(ContentSecretRedactor.mask(key))\nBearer \(ContentSecretRedactor.mask(bearer))\nCookie: \(ContentSecretRedactor.mask(cookie)); theme=\(ContentSecretRedactor.mask("dark"))\n可读尾部"
                let targetID = "d05-app-target"
                try store.updateSession(ChatSession(id: targetID, title: "普通标题 \(key)",
                    messages: [LLMMessage(role: .user, content: raw)],
                    modelID: "Bearer \(bearer)", providerTypeRaw: "Cookie: \(cookie); theme=dark"))
                if archived { try manager.archive(sessionID: targetID) }
                let persistedURL = store.sessionsDirectory.appendingPathComponent(archived ? "_archive/\(targetID).json" : "\(targetID).json")
                let persistedBefore = try Data(contentsOf: persistedURL)
                let callID = "d05-\(native ? "native" : "envelope")-\(scope.rawValue)"
                let input: [String: Any] = ["session_id": targetID, "scope": scope.rawValue, "max_chars": 8000]
                let provider = AJ2SessionReadProvider(nativeResponses: [
                    try responseForRead(native: native, id: callID, input: input),
                    LLMResponse(text: "OFFLINE_FINAL_SENTINEL", stopReason: "stop", usage: nil),
                ])
                let box = redactionChain(directory: directory, manager: manager, provider: provider)
                let approval = AJ2ExactSyntheticApproval(
                    target: targetID,
                    scope: scope.rawValue,
                    expectedSummary: ApprovalGate.makeInputSummary(input),
                    expectedRiskLevel: .low,
                    expectedSecondConfirmation: false,
                    allow: true,
                    onDecision: { _ in }
                )
                let gate = ApprovalGate(
                    policyByTool: [SessionReadTool.toolName: .alwaysAsk],
                    delegate: approval
                )
                let engine = AgentLoopChatEngine(toolExecutor: box, maxIterations: 3, approvalGate: gate,
                    toolExecutionFactLedger: try ToolExecutionFactLedger(persistenceURL: directory.appendingPathComponent("facts.json")))
                let stream = try await engine.streamReply(provider: provider,
                    history: [ChatMessageUI(role: .user, content: "请授权查看会话 \(targetID) 的\(scope == .metadata ? "模型信息" : "消息")")],
                    systemPrompt: ChatStore.systemPrompt, maxTokens: 2048,
                    conversationID: "d05-source", authorizedSessionReadSessionID: targetID,
                    authorizedSessionReadScope: scope, turnID: 1)
                for try await _ in stream { }

                let approvalRequests = await approval.requests
                let approvalDecisions = await approval.decisions
                #expect(approvalRequests.count == 1 && approvalDecisions.count == 1)
                #expect(approvalDecisions.first?.approved == true)
                #expect(approvalDecisions.first?.bindingDigest == approvalRequests.first?.identityDigest)

                let outputs = provider.toolOutputs
                #expect(outputs.count == 1)
                let fullOutput = try #require(outputs.first)
                let object = try #require(JSONSerialization.jsonObject(with: Data(fullOutput.utf8)) as? [String: Any])
                #expect(object["ok"] as? Bool == true && object["scope"] as? String == scope.rawValue)
                if scope == .metadata {
                    let metadata = try #require(object["metadata"] as? [String: Any])
                    #expect(metadata["title"] as? String == "普通标题 \(ContentSecretRedactor.mask(key))")
                    #expect(metadata["model_id"] as? String == "Bearer \(ContentSecretRedactor.mask(bearer))")
                    #expect(metadata["provider"] as? String == "Cookie: \(ContentSecretRedactor.mask(cookie)); theme=\(ContentSecretRedactor.mask("dark"))")
                    #expect(metadata["session_id"] as? String == targetID)
                } else {
                    let messages = try #require(object["messages"] as? [[String: Any]])
                    #expect(messages.count == 1 && messages.first?["text"] as? String == safe)
                    #expect(messages.first?["truncated"] == nil)
                    #expect(object["total"] as? Int == 1)
                }
                let requests = provider.requests
                #expect(requests.count == 2)
                let next = try #require(requests.dropFirst().first)
                let forwardedBody = try nextRequestToolBody(next, native: native, callID: callID)
                #expect(forwardedBody == fullOutput)
                #expect(next.toolNames.contains(SessionReadTool.toolName))
                let encodedMessages = try JSONEncoder().encode(next.messages)
                let nextPayload = try #require(String(data: encodedMessages, encoding: .utf8)) + (next.systemPrompt ?? "")
                #expect(!fullOutput.contains("theme=dark") && !nextPayload.contains("theme=dark"))
                for secret in [key, bearer, cookie] {
                    #expect(!fullOutput.contains(secret) && !nextPayload.contains(secret))
                    let interior = String(secret.dropFirst(4).dropLast(4))
                    #expect(!fullOutput.contains(interior) && !nextPayload.contains(interior))
                    #expect(fullOutput.contains(ContentSecretRedactor.mask(secret)))
                }
                let records = provider.actionRecords
                #expect(records.count == 1)
                let record = try #require(records.first)
                #expect(record.toolName == SessionReadTool.toolName && record.succeeded)
                #expect(record.argsSummary == RecordingToolExecutor.summarize(input))
                #expect(record.resultSummary == RecordingToolExecutor.summarizeResult(fullOutput))
                #expect(fullOutput.count > record.resultSummary.count)
                #expect(!record.argsSummary.contains("theme=dark") && !record.resultSummary.contains("theme=dark"))
                for secret in [key, bearer, cookie] {
                    #expect(!record.argsSummary.contains(secret) && !record.resultSummary.contains(secret))
                }
                #expect(try Data(contentsOf: persistedURL) == persistedBefore)
            }
        }
    }

    @Test(arguments: [false, true])
    func noApprovalGateNeverReceivesTargetPayload(native: Bool) async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let manager = SessionManager(store: store, badgeStore: SessionBadgeStore(directory: directory))
        let secret = "sk-D05UnauthorizedAppInteriorABCDEFGHIJ"
        try store.updateSession(ChatSession(id: "d05-protected", title: "D05_PROTECTED_TITLE \(secret)", messages: [LLMMessage(role: .user, content: "D05_PROTECTED_BODY \(secret)")]))
        let file = store.sessionsDirectory.appendingPathComponent("d05-protected.json")
        let before = try Data(contentsOf: file)
        let provider = AJ2SessionReadProvider(nativeResponses: [
            try responseForRead(native: native, id: "d05-denied", input: ["session_id": "d05-protected", "scope": "messages"]),
            LLMResponse(text: "OFFLINE_FINAL_SENTINEL", stopReason: "stop", usage: nil),
        ])
        let box = redactionChain(directory: directory, manager: manager, provider: provider)
        let counter = AJ2SessionReadCallCounter(base: box)
        let engine = AgentLoopChatEngine(toolExecutor: counter, maxIterations: 3,
            toolExecutionFactLedger: try ToolExecutionFactLedger(persistenceURL: directory.appendingPathComponent("facts.json")))
        let stream = try await engine.streamReply(provider: provider,
            history: [ChatMessageUI(role: .user, content: "普通问题，没有审批通道")],
            systemPrompt: ChatStore.systemPrompt, maxTokens: 2048, conversationID: "d05-source",
            authorizedSessionReadSessionID: nil, authorizedSessionReadScope: nil, turnID: 1)
        for try await _ in stream { }
        #expect(provider.toolOutputs.isEmpty)
        #expect(provider.actionRecords.isEmpty)
        #expect(counter.sessionReadCallCount == 0)
        #expect(provider.requests.count == 2)
        let next = try #require(provider.requests.dropFirst().first)
        let refusal = try nextRequestToolBody(next, native: native, callID: "d05-denied", expectedError: true)
        #expect(refusal == "Error executing tool session_read: \(ToolExecutorError.approvalRequired(SessionReadTool.toolName).localizedDescription)")
        let encodedMessages = try JSONEncoder().encode(next.messages)
        let payload = try #require(String(data: encodedMessages, encoding: .utf8)) + (next.systemPrompt ?? "")
        #expect(!payload.contains(secret) && !payload.contains(ContentSecretRedactor.mask(secret)))
        #expect(!payload.contains("D05_PROTECTED_TITLE") && !payload.contains("D05_PROTECTED_BODY"))
        #expect(try Data(contentsOf: file) == before)
    }
}

private final class D05MemoryCredentialBacking: KeychainBacking, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var reads = 0
    func set(_ value: String, forKey key: String) -> Bool {
        lock.withLock { values[key] = value }; return true
    }
    func get(_ key: String) -> String? {
        lock.withLock { reads += 1; return values[key] }
    }
    func delete(_ key: String) -> Bool {
        _ = lock.withLock { values.removeValue(forKey: key) }; return true
    }
    var readCount: Int { lock.withLock { reads } }
}

// An explicit fixture decision through the real gate, with no policy override.
private actor AJ2ExactSyntheticApproval: ApprovalDelegate {
    let target: String
    let scope: String
    let expectedSummary: String
    let expectedRiskLevel: ApprovalRiskLevel
    let expectedSecondConfirmation: Bool
    let allow: Bool
    let onDecision: @Sendable (String) -> Void
    private var seen: Set<String> = []
    private(set) var requests: [ApprovalRequest] = []
    private(set) var decisions: [ApprovalDecision] = []

    init(target: String, scope: String, expectedSummary: String,
         expectedRiskLevel: ApprovalRiskLevel = .high,
         expectedSecondConfirmation: Bool = false, allow: Bool,
         onDecision: @escaping @Sendable (String) -> Void) {
        self.target = target; self.scope = scope; self.expectedSummary = expectedSummary
        self.expectedRiskLevel = expectedRiskLevel
        self.expectedSecondConfirmation = expectedSecondConfirmation
        self.allow = allow; self.onDecision = onDecision
    }

    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        requests.append(request)
        let matches = request.toolName == SessionReadTool.toolName
            && request.inputSummary == expectedSummary
            && request.inputSummary.contains("session_id: \(target)")
            && request.inputSummary.contains("scope: \(scope)")
            && request.riskLevel == expectedRiskLevel && request.inputRiskLevel == expectedRiskLevel
            && request.requiresApproval
            && request.requiresSecondConfirmation == expectedSecondConfirmation
            && request.id == request.requestID && request.callID == request.requestID
            && request.binding != nil && request.identityDigest != nil
            && seen.insert(request.requestID).inserted
        let approved = matches && allow
        let decision = ApprovalDecision(approved: approved,
            reason: approved ? "AJ2 exact synthetic request approved"
                : (matches ? "AJ2 exact synthetic request denied" : "AJ2 unexpected synthetic approval request"),
            confirmed: approved, requestID: request.requestID,
            bindingDigest: request.identityDigest)
        decisions.append(decision)
        onDecision(approved ? "approval-decision" : "approval-denied")
        return decision
    }
}

// Only the isolated synthetic known-value fixture opts into this observer.
// Redact complete fields before truncation; never snapshot the trusted provider.
private func aj2KnownValueObservation(native: Bool, archived: Bool, scope: String,
    stage: String, details: [String: String], knownSecrets: [String]) {
    var fields = ["native": String(native), "archived": String(archived), "scope": scope, "stage": stage]
    for (key, value) in details {
        fields[key] = String(ContentSecretRedactor.redact(value, knownSecrets: knownSecrets).prefix(512))
    }
    if let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) {
        print("AJ2_KNOWN_VALUE_OBSERVATION " + String(decoding: data, as: UTF8.self))
    }
}

extension AJ2SessionReadEndToEndTests {


    /// D-SESSIONREAD-04: every page is returned by the actual Bridge executor
    /// and received by the next real AgentLoop Provider request. Only the
    /// external model response is scripted; no page getter or result is faked.
    @Test(arguments: [false, true]) @MainActor
    func successiveBoundedPagesReachBothActualProviderRequestRoutes(native: Bool) async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "AJ2-pages759", processEnvironment: [:],
            processArguments: ["AJ2SessionReadTests.xctest"], canvasRuntimeState: .disabled
        )
        let root = profile.rootDirectory
        let defaults = profile.makeUserDefaults()
        defer {
            if let suite = profile.userDefaultsSuiteName {
                defaults.removePersistentDomain(forName: suite)
            }
            try? profile.cleanupDisposableRoots()
        }
        let sessions = SessionStore(directory: profile.sessionDirectory)
        let badges = SessionBadgeStore(directory: root.appendingPathComponent("badges759"))
        let keychain = KeychainStore(backing: D05MemoryCredentialBacking())
        let secrets = EnvVarStore(directory: root.appendingPathComponent("env759"), keychain: keychain)
        // Seed persisted roots before the one-shot bootstrap so the real
        // ChatStore owns B/C in its canonical list; a post-bootstrap external
        // root would legitimately be treated as an orphan by persistence.
        let targetID = "00000000-0000-0000-0000-000000000759"
        let otherID = "00000000-0000-0000-0000-000000000760"
        let markers = (0..<5).map { "AJ2_759_PAGE_\($0)_" }
        let texts = markers.enumerated().map { index, marker in
            index == 0 ? marker + String(repeating: "👩🏽‍💻e\u{301}正文", count: 90) + "AJ2_759_HIDDEN_TAIL"
                : marker + "owned ordinary message \(index)"
        }
        let messages = texts.enumerated().map { index, text in
            LLMMessage(role: index.isMultiple(of: 2) ? .user : .assistant, content: text)
        }
        try sessions.updateSession(ChatSession(id: targetID, title: "AJ2_759_TARGET_TITLE", messages: messages))
        try sessions.updateSession(ChatSession(id: otherID, title: "AJ2_759_FOREIGN_TITLE",
            messages: [LLMMessage(role: .user, content: "AJ2_759_FOREIGN_BODY")]))
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            logManager: profile.makeLogManager(),
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("Workflows759")),
            sessionDocumentStore: SessionDocumentStore(directory: profile.sessionDirectory),
            canvasRuntimeState: .disabled,
            memoryStore: MemoryStore(directory: profile.memoryDirectory),
            taskCenterBindingPersistenceURL: root.appendingPathComponent("task-bindings759.json"),
            canvasFeatureLane: .phase3NonCanvas
        )
        #expect(bridge.chat.attachPersistence(sessions, badgeStore: badges))
        let skills = SkillStore(skillsRoot: root.appendingPathComponent("skills759"))
        bridge.attachProductionServices(
            fileAccessAllowedRoot: root, fileAccessDeniedRoots: [],
            sessionDirectory: sessions.directory,
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps759.json"), keychain: keychain),
            skillStore: skills,
            canvasRuntimeState: .disabled, externalNetworkAllowed: false,
            sessionReadSecretStore: secrets
        )
        bridge.chat.newSession()
        let manager = try #require(bridge.chat.sessionManager)
        #expect(bridge.chat.sessions.contains(where: { $0.id.uuidString == targetID }))
        #expect(bridge.chat.sessions.contains(where: { $0.id.uuidString == otherID }))
        #expect(bridge.chat.activeSessionID?.uuidString != targetID && bridge.chat.activeSessionID?.uuidString != otherID)
        #expect(manager.store === sessions && manager.badgeStore === badges)
        let production = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let composed = try #require(production.composedExecutor as? any SessionReadCapabilityAwareToolExecutor)
        let originalTaskPolicy = bridge.chat.prepareTopLevelTaskPolicy
        defer { bridge.chat.prepareTopLevelTaskPolicy = originalTaskPolicy }
        #expect(production.chatRuntimeDependencies?.sessionStore === sessions)
        let targetFile = sessions.sessionsDirectory.appendingPathComponent("\(targetID).json")
        let foreignFile = sessions.sessionsDirectory.appendingPathComponent("\(otherID).json")
        let targetBefore = try Data(contentsOf: targetFile)
        let foreignBefore = try Data(contentsOf: foreignFile)
        let persistedBefore = try #require(manager.loadSessionIncludingArchived(id: targetID))
        let facts = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts759.json"))
        let sourceID = try #require(bridge.chat.activeSessionID)
        let originalCommandHandler = bridge.chat.onSendCommand
        let originalEngine = bridge.chat.agentEngine
        let originalProvider = bridge.chat.streamingProviderOverride
        let originalRuntimeFactory = bridge.chat.turnRuntimeSnapshotFactory
        // Reuse the existing 460 offline Provider boundary: the real ordinary
        // ChatStore pipeline still freezes the owned SkillStore and sends its
        // own execution identity. No production route/grant is fabricated.
        bridge.chat.turnRuntimeSnapshotFactory = { turn, _ in
            .init(turn: turn, skillInjector: SkillInjector(store: skills).snapshotForTurn(), mcpBridge: nil)
        }
        var producedSnapshot: ComposerSubmissionSnapshot?
        bridge.chat.onSendCommand = { _, snapshot in
            producedSnapshot = snapshot
            // Observe the producer, then let the ordinary ChatStore caller
            // create and pass the matching executionIdentity to AgentLoop.
            return false
        }
        defer {
            bridge.chat.stopAllStreamingForSafety()
            bridge.chat.onSendCommand = originalCommandHandler
            bridge.chat.agentEngine = originalEngine
            bridge.chat.streamingProviderOverride = originalProvider
            bridge.chat.turnRuntimeSnapshotFactory = originalRuntimeFactory
        }
        var offset = 0
        var observedTexts: [String] = []
        var turnIDs: [Int] = []
        for pageIndex in 0..<3 {
            let pageStart = offset
            let callID = "aj2-pages759-\(pageIndex)"
            let input: [String: Any] = ["session_id": targetID, "scope": "messages",
                "offset": pageStart, "limit": 2, "max_chars": 200]
            let provider = AJ2SessionReadProvider(nativeResponses: [
                try responseForRead(native: native, id: callID, input: input),
                LLMResponse(text: "OFFLINE_FINAL_SENTINEL", stopReason: "stop", usage: nil),
            ])
            let approval = AJ2SessionReadApprovalDelegate()
            // Each model session_read call raises its own approval card; the
            // user's words never mint a grant.
            let gate = ApprovalGate(delegate: approval)
            let box = AJ2SessionReadExecutorBox(executor: composed, onOutput: { provider.recordOutput($0) },
                onObservation: { stage, errorType, errorText in
                    provider.recordApprovalTrace(stage)
                    if stage == "typed-throw" {
                        // Classify only fixed error prefixes. Never emit the
                        // localized payload, source text, or any secret value.
                        let safeCode = errorText.hasPrefix("File not found:") ? "fileNotFound"
                            : errorText.hasPrefix("Invalid parameter") ? "invalidParameter"
                            : errorText.hasPrefix("Missing required parameter") ? "missingParameter"
                            : "otherTypedError"
                        print("AJ2_759_TYPED_ERROR type=\(errorType) code=\(safeCode)")
                    }
                })
            bridge.chat.agentEngine = AgentLoopChatEngine(toolExecutor: box, maxIterations: 3,
                approvalGate: gate, toolExecutionFactLedger: facts,
                composerPolicyFacts: bridge.chat.composerPolicyFacts,
                composerGrantStore: bridge.chat.composerGrantStore)
            bridge.chat.streamingProviderOverride = provider
            producedSnapshot = nil
            bridge.chat.draftText = "请授权读取会话 \(targetID) 的消息，本次从 \(pageStart) 开始"
            observeAJ2TaskPolicy(bridge: bridge, prepare: originalTaskPolicy,
                box: box, outerExecutor: box)
            bridge.chat.submitComposer()
            let submission = try #require(producedSnapshot)
            let sent = try #require(bridge.chat.messages.last(where: { $0.role == .user }))
            #expect(bridge.chat.activeSessionID == sourceID)
            #expect(submission == bridge.chat.lastComposerSubmissionSnapshot)
            #expect(submission.sessionID == sourceID.uuidString && submission.messageID == sent.id.uuidString)
            #expect(submission.turnID == pageIndex)
            // Join the ordinary Composer's own task before inspecting its
            // terminal UI state. A fixed six-second observation window can
            // expire after the final Provider reply but before stream cleanup.
            if let turnTask = bridge.chat.turnTaskForTests(sessionID: sourceID) {
                await turnTask.value
            }
            try #require(!bridge.chat.isStreaming)
            #expect(bridge.chat.turnTaskForTests(sessionID: sourceID) == nil)
            #expect(bridge.chat.messages.last(where: { $0.role == .assistant })?.content.hasSuffix("OFFLINE_FINAL_SENTINEL") == true)
            print("AJ2_759_OWNED_FILE_STATE target_exists=\(FileManager.default.fileExists(atPath: targetFile.path)) foreign_exists=\(FileManager.default.fileExists(atPath: foreignFile.path))")
            let approvalRequests = await approval.requests
            // The allowed card mints the turn capability for this one call.
            #expect(approvalRequests.count == 1)
            #expect(provider.toolOutputs.count == 1 && provider.requests.count == 2)
            #expect(provider.approvalTrace == ["typed-enter", "typed-success"])
            let body = try #require(provider.toolOutputs.first)
            let nextRequest = try #require(provider.requests.dropFirst().first)
            #expect(try nextRequestToolBody(nextRequest, native: native, callID: callID) == body)
            let object = try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
            #expect(object["ok"] as? Bool == true && object["scope"] as? String == "messages")
            #expect(object["session_id"] as? String == targetID)
            #expect(object["offset"] as? Int == pageStart && object["cursor_offset"] as? Int == pageStart)
            #expect(object["limit"] as? Int == 2 && object["max_chars"] as? Int == 200)
            #expect(object["total"] as? Int == messages.count)
            // streamReply owns a fresh local cancellation handle for each
            // stream (ID 1); the actual Composer owns durable A turns 0/1/2.
            #expect(object["turn_id"] as? Int == 1)
            turnIDs.append(submission.turnID)
            let page = try #require(object["messages"] as? [[String: Any]])
            let expectedIndices = Array(pageStart..<min(pageStart + 2, texts.count))
            #expect(page.count == expectedIndices.count && page.count <= 2 && page.count < messages.count)
            for (item, index) in zip(page, expectedIndices) {
                let text = try #require(item["text"] as? String)
                // Expected bytes are derived from the owned input, not the
                // production bounded getter whose behavior is under test.
                #expect(text == String(texts[index].prefix(200)))
                #expect(item["role"] as? String == messages[index].role.rawValue)
                #expect(text.count <= 200 && text.utf8.count <= 64_000)
                #expect(item["character_count"] as? Int == text.count)
                #expect(item["byte_count"] as? Int == text.utf8.count)
                #expect(item["source_character_count"] as? Int == texts[index].count)
                #expect(item["source_byte_count"] as? Int == texts[index].utf8.count)
                #expect(item["max_characters"] as? Int == 200)
                #expect(item["max_bytes"] as? Int == 64_000)
                #expect(index == 0 ? item["truncated"] as? Bool == true : item["truncated"] == nil)
                observedTexts.append(text)
            }
            let payload = String(decoding: try JSONEncoder().encode(nextRequest.messages), as: UTF8.self)
                + (nextRequest.systemPrompt ?? "")
            for (index, marker) in markers.enumerated() {
                #expect(body.contains(marker) == expectedIndices.contains(index))
                // Earlier pages (index < pageStart) may stay in history as an
                // executed-result excerpt; a page not read yet (index >= pageStart
                // outside this page) must never appear in any request.
                if expectedIndices.contains(index) {
                    #expect(payload.contains(marker))
                } else if index >= pageStart {
                    #expect(!payload.contains(marker))
                }
            }
            for forbidden in ["AJ2_759_HIDDEN_TAIL", "AJ2_759_FOREIGN_TITLE", "AJ2_759_FOREIGN_BODY"] {
                #expect(!body.contains(forbidden) && !payload.contains(forbidden))
            }
            if pageIndex < 2 {
                #expect(object["has_more"] as? Bool == true)
                // The next request uses the actual consumer result, while this
                // equality guards against a skipped/repeated continuation.
                offset = try #require(object["next_offset"] as? Int)
                #expect(offset == pageStart + page.count)
            } else {
                #expect(object["has_more"] as? Bool == false)
                #expect(object["next_offset"] is NSNull)
            }
            #expect(try Data(contentsOf: targetFile) == targetBefore)
            #expect(try Data(contentsOf: foreignFile) == foreignBefore)
        }
        #expect(observedTexts == texts.map { String($0.prefix(200)) })
        #expect(turnIDs == [0, 1, 2])
        #expect(facts.facts.count == 3)
        #expect(facts.facts.allSatisfy { $0.toolName == SessionReadTool.toolName && $0.status == .succeeded })
        let reopened = try #require(SessionStore(directory: sessions.directory).loadSession(id: targetID))
        #expect(reopened.messages == persistedBefore.messages)
        #expect(reopened.transcriptRevision == persistedBefore.transcriptRevision)
        #expect(try Data(contentsOf: targetFile) == targetBefore)
        #expect(try Data(contentsOf: foreignFile) == foreignBefore)
    }
    @Test(arguments: [false, true]) @MainActor
    func knownBareValuesStayMaskedInFullOutputAndBothNextPayloads(native: Bool) async throws {
        for archived in [false, true] {
            for scope in [SessionReadScope.metadata, .messages] {
                let directory = try makeDirectory()
                defer { try? FileManager.default.removeItem(at: directory) }
                let store = SessionStore(directory: directory)
                let manager = SessionManager(store: store, badgeStore: SessionBadgeStore(directory: directory))
                let long = "HEAD" + String(repeating: "BAREVALUE_INTERIOR", count: 40) + "TAIL"
                let short = "z8!"
                let unicode = "可信👩🏽‍💻e\u{301}私密裸值"
                let ordinary = "普通值不应被模型指定遮蔽"
                let backing = D05MemoryCredentialBacking()
                let secretStore = EnvVarStore(directory: directory.appendingPathComponent("env"),
                    keychain: KeychainStore(backing: backing))
                for index in 0..<3 {
                    #expect(secretStore.setEnvVar(name: "D05_SYNTHETIC_\(index)", value: "BEFORE_ATTACH_PLACEHOLDER_\(index)", isSecret: true))
                }
                #expect(secretStore.setEnvVar(name: "D05_ORDINARY", value: ordinary, isSecret: false))
                let prefix = String(repeating: "前", count: 185) + "👩🏽‍💻e\u{301} "
                let raw = prefix + long + " 正文尾部"
                // Compute the full-mask contract independently of the production redactor.
                let longMask = String(repeating: "*", count: long.count)
                let shortMask = String(repeating: "*", count: short.count)
                let unicodeMask = String(repeating: "*", count: unicode.count)
                let projected = prefix + longMask + " 正文尾部"
                let boundedProjection = String(projected.prefix(200))
                #expect(raw.count == projected.count && projected.count > 200)
                #expect(boundedProjection.count == 200)
                #expect(boundedProjection == prefix + String(repeating: "*", count: 200 - prefix.count))
                let (bridge, settings, usageSuite) = await makeKnownValueProductionComposition(
                    root: directory, sessionStore: store, secretStore: secretStore,
                    keychain: KeychainStore(backing: backing))
                defer { UserDefaults(suiteName: usageSuite)?.removePersistentDomain(forName: usageSuite) }
                bridge.chat.newSession()
                let source = try #require(bridge.chat.activeSessionID)
                let sourceID = source.uuidString
                let sourcePersisted = manager.loadSessionIncludingArchived(id: sourceID) != nil
                try #require(sourcePersisted)
                let target = "00000000-0000-0000-0000-000000000207"
                let distinctSourceAndTarget = sourceID != target
                try #require(distinctSourceAndTarget)
                try store.updateSession(ChatSession(id: target, title: "\(ordinary) \(long)", messages: [
                    LLMMessage(role: .user, content: raw),
                    LLMMessage(role: .assistant, content: "\(ordinary) \(short) \(unicode)"),
                ], modelID: short, providerTypeRaw: unicode))
                if archived { try manager.archive(sessionID: target) }
                let persisted = store.sessionsDirectory.appendingPathComponent(archived ? "_archive/\(target).json" : "\(target).json")
                // Mutate the actual SettingsCenter store after executor creation.
                #expect(settings.envStore === secretStore)
                for (index, value) in [long, short, unicode].enumerated() {
                    #expect(settings.envStore.setEnvVar(name: "D05_SYNTHETIC_\(index)", value: value, isSecret: true))
                }
                let storedTarget = try #require(manager.loadSessionIncludingArchived(id: target))
                let targetModelIntact = storedTarget.modelID == short
                let targetProviderIntact = storedTarget.providerTypeRaw == unicode
                let sourceActiveBeforeRead = bridge.chat.activeSessionID == source
                try #require(targetModelIntact)
                try #require(targetProviderIntact)
                try #require(sourceActiveBeforeRead)
                aj2KnownValueObservation(native: native, archived: archived, scope: scope.rawValue, stage: "setup-before-read",
                    details: ["distinct_source_target": String(distinctSourceAndTarget), "source_active": String(sourceActiveBeforeRead),
                        "model_intact": String(targetModelIntact), "provider_intact": String(targetProviderIntact)], knownSecrets: [])
                let before = try Data(contentsOf: persisted)
                let callID = "d05-known-\(native)-\(scope.rawValue)"
                let input: [String: Any] = ["session_id": target, "scope": scope.rawValue, "max_chars": 200,
                    "knownSecrets": [ordinary], "knownSecretsProvider": "model-input-is-not-trusted"]
                let provider = AJ2SessionReadProvider(nativeResponses: [
                    try responseForRead(native: native, id: callID, input: input),
                    LLMResponse(text: "OFFLINE_FINAL_SENTINEL", stopReason: "stop", usage: nil),
                ])
                let production = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
                let composed = try #require(production.composedExecutor as? any SessionReadCapabilityAwareToolExecutor)
                let knownValues = [long, short, unicode]
                let scopeName = scope.rawValue
                let approval = AJ2ExactSyntheticApproval(target: target, scope: scopeName,
                    expectedSummary: ApprovalGate.makeInputSummary(input), allow: true,
                    onDecision: { provider.recordApprovalTrace($0) })
                let gate = ApprovalGate(delegate: approval, onApprovalReceipt: { provider.recordApproval($0) })
                let box = AJ2SessionReadExecutorBox(executor: composed, onOutput: {
                    provider.recordOutput($0); provider.recordApprovalTrace("output")
                }, onObservation: { stage, errorType, errorText in
                        provider.recordApprovalTrace(stage)
                        aj2KnownValueObservation(native: native, archived: archived, scope: scopeName, stage: stage,
                            details: ["error_type": errorType, "error_text": errorText], knownSecrets: knownValues)
                    })
                let engine = AgentLoopChatEngine(toolExecutor: box, maxIterations: 3, approvalGate: gate,
                    toolExecutionFactLedger: try ToolExecutionFactLedger(persistenceURL: directory.appendingPathComponent("facts.json")))
                let stream = try await engine.streamReply(provider: provider,
                    history: [ChatMessageUI(role: .user, content: "请授权查看会话 \(target)")],
                    systemPrompt: ChatStore.systemPrompt, maxTokens: 2048, conversationID: sourceID,
                    authorizedSessionReadSessionID: target, authorizedSessionReadScope: scope, turnID: 1)
                for try await _ in stream { }
                let observedRequests = provider.requests
                var details = ["requests": String(observedRequests.count), "outputs": String(provider.toolOutputs.count),
                    "next_request": "missing", "tool_result_count": "0", "is_error": "unavailable"]
                if let next = observedRequests.dropFirst().first {
                    details["next_request"] = "present"
                    if native {
                        let results = next.messages.filter { $0.role == .tool && $0.toolCallID == callID }
                        details["tool_result_count"] = String(results.count)
                        details["body"] = results.first?.content ?? ""
                    } else {
                        let results = next.messages.filter { $0.role == .user }.flatMap { message -> [[String: Any]] in
                            guard let data = message.content.data(using: .utf8),
                                  let blocks = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
                            return blocks.filter { $0["type"] as? String == "tool_result" && $0["tool_use_id"] as? String == callID }
                        }
                        details["tool_result_count"] = String(results.count)
                        details["is_error"] = (results.first?["is_error"] as? Bool).map { String($0) } ?? "missing"
                        details["body"] = results.first?["content"] as? String ?? ""
                    }
                }
                aj2KnownValueObservation(native: native, archived: archived, scope: scopeName, stage: "before-require",
                    details: details, knownSecrets: knownValues)
                let approvalRequests = await approval.requests
                let approvalDecisions = await approval.decisions
                #expect(approvalRequests.count == 1 && approvalDecisions.count == 1)
                let approvedRequest = try #require(approvalRequests.first)
                let approvedDecision = try #require(approvalDecisions.first)
                #expect(approvedDecision.approved && approvedDecision.confirmed)
                #expect(approvedDecision.requestID == approvedRequest.requestID)
                #expect(approvedDecision.bindingDigest == approvedRequest.identityDigest)
                #expect(provider.approvalReceipts.count == 1)
                let receipt = try #require(provider.approvalReceipts.first)
                #expect(receipt.requestID == approvedRequest.requestID && receipt.status == .approved)
                #expect(receipt.inputSummary == approvedRequest.inputSummary && receipt.riskLevel == .high)
                #expect(receipt.policy == ApprovalGate.defaultPolicies[SessionReadTool.toolName])
                #expect(provider.approvalTrace == ["approval-decision", "approval-receipt", "typed-enter", "output", "typed-success"])
                #expect(provider.toolOutputs.count == 1 && provider.requests.count == 2)
                let output = try #require(provider.toolOutputs.first)
                let json = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
                if scope == .metadata {
                    let metadata = try #require(json["metadata"] as? [String: Any])
                    #expect(metadata["title"] as? String == "\(ordinary) \(longMask)")
                    #expect(metadata["model_id"] as? String == shortMask)
                    #expect(metadata["provider"] as? String == unicodeMask)
                } else {
                    let messages = try #require(json["messages"] as? [[String: Any]])
                    #expect(messages.count == 2 && messages[0]["text"] as? String == boundedProjection)
                    #expect(messages[0]["truncated"] as? Bool == true)
                    #expect(messages[0]["character_count"] as? Int == 200)
                    #expect(messages[0]["byte_count"] as? Int == boundedProjection.utf8.count)
                    #expect(messages[0]["source_character_count"] as? Int == projected.count)
                    #expect(messages[1]["text"] as? String == "\(ordinary) \(shortMask) \(unicodeMask)")
                    #expect(ContentSecretRedactor.redact(String(raw.prefix(200)), knownSecrets: [long]) != String(projected.prefix(200)))
                }
                let next = try #require(provider.requests.dropFirst().first)
                #expect(try nextRequestToolBody(next, native: native, callID: callID) == output)
                let payload = String(decoding: try JSONEncoder().encode(next.messages), as: UTF8.self) + (next.systemPrompt ?? "")
                #expect(output.contains(ordinary) && payload.contains(ordinary))
                #expect(!output.contains("BAREVALUE_INTERIOR") && !payload.contains("BAREVALUE_INTERIOR"))
                let records = bridge.actionHistory.records
                #expect(records.count == 1)
                let record = try #require(records.first)
                #expect(record.succeeded && record.toolName == SessionReadTool.toolName)
                #expect(record.resultSummary == RecordingToolExecutor.summarizeResult(output))
                for secret in [long, short, unicode] {
                    #expect(!output.contains(secret) && !payload.contains(secret))
                    // A bounded message includes only the mask's visible prefix;
                    // exact metadata/message assertions above prove its cardinality.
                    let characters = Array(secret)
                    if characters.count >= 4 {
                        let exposesFragment = (0...(characters.count - 4)).contains { offset in
                            let fragment = String(characters[offset..<(offset + 4)])
                            return output.contains(fragment) || payload.contains(fragment)
                                || record.resultSummary.contains(fragment) || record.argsSummary.contains(fragment)
                        }
                        #expect(!exposesFragment, "no original four-character secret fragment reaches any output sink")
                    }
                    #expect(!record.resultSummary.contains(secret) && !record.argsSummary.contains(secret))
                }
                #expect(try Data(contentsOf: persisted) == before)
                #expect(backing.readCount == 0)
                let sourceActiveAfterRead = bridge.chat.activeSessionID == source
                #expect(sourceActiveAfterRead && distinctSourceAndTarget)
                aj2KnownValueObservation(native: native, archived: archived, scope: scope.rawValue, stage: "setup-after-read",
                    details: ["distinct_source_target": String(distinctSourceAndTarget), "source_active": String(sourceActiveAfterRead)], knownSecrets: [])
            }
        }
    }

    @Test(arguments: [false, true]) @MainActor
    func highRiskKnownValueReadRequiresExplicitApproval(native: Bool) async throws {
        for explicitDeny in [false, true] {
            let directory = try makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = SessionStore(directory: directory)
            let target = "00000000-0000-0000-0000-000000000209"
            let secret = "AJ2SyntheticProtectedBareInteriorTAIL"
            let backing = D05MemoryCredentialBacking()
            let keychain = KeychainStore(backing: backing)
            let secretStore = EnvVarStore(directory: directory.appendingPathComponent("env"), keychain: keychain)
            #expect(secretStore.setEnvVar(name: "AJ2_SYNTHETIC", value: secret, isSecret: true))
            try store.updateSession(ChatSession(id: target, title: "AJ2_APPROVAL_PROTECTED_TITLE \(secret)",
                messages: [LLMMessage(role: .user, content: "AJ2_APPROVAL_PROTECTED_BODY \(secret)")]))
            let persisted = store.sessionsDirectory.appendingPathComponent("\(target).json")
            let before = try Data(contentsOf: persisted)
            let (bridge, settings, usageSuite) = await makeKnownValueProductionComposition(
                root: directory, sessionStore: store, secretStore: secretStore, keychain: keychain)
            defer { UserDefaults(suiteName: usageSuite)?.removePersistentDomain(forName: usageSuite) }
            #expect(settings.envStore === secretStore)
            let callID = "aj2-approval-\(native)-\(explicitDeny)"
            let input: [String: Any] = ["session_id": target, "scope": "metadata", "max_chars": 200,
                "knownSecrets": ["普通值不应被模型指定遮蔽"], "knownSecretsProvider": "model-input-is-not-trusted"]
            let provider = AJ2SessionReadProvider(nativeResponses: [
                try responseForRead(native: native, id: callID, input: input),
                LLMResponse(text: "OFFLINE_FINAL_SENTINEL", stopReason: "stop", usage: nil),
            ])
            let approval = AJ2ExactSyntheticApproval(target: target, scope: "metadata",
                expectedSummary: ApprovalGate.makeInputSummary(input), allow: false,
                onDecision: { provider.recordApprovalTrace($0) })
            let gate: ApprovalGate? = explicitDeny
                ? ApprovalGate(delegate: approval, onApprovalReceipt: { provider.recordApproval($0) }) : nil
            let production = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
            let composed = try #require(production.composedExecutor as? any SessionReadCapabilityAwareToolExecutor)
            let box = AJ2SessionReadExecutorBox(executor: composed, onOutput: { provider.recordOutput($0) },
                onObservation: { stage, _, _ in provider.recordApprovalTrace(stage) })
            let engine = AgentLoopChatEngine(toolExecutor: box, maxIterations: 3, approvalGate: gate,
                toolExecutionFactLedger: try ToolExecutionFactLedger(persistenceURL: directory.appendingPathComponent("facts.json")))
            let stream = try await engine.streamReply(provider: provider,
                history: [ChatMessageUI(role: .user, content: "请授权查看会话 \(target)")],
                systemPrompt: ChatStore.systemPrompt, maxTokens: 2048, conversationID: "aj2-approval-source",
                authorizedSessionReadSessionID: target, authorizedSessionReadScope: .metadata, turnID: 1)
            for try await _ in stream { }
            let requests = await approval.requests
            let decisions = await approval.decisions
            #expect(requests.count == (explicitDeny ? 1 : 0) && decisions.count == (explicitDeny ? 1 : 0))
            #expect(decisions.allSatisfy { !$0.approved && !$0.confirmed })
            #expect(provider.approvalTrace == (explicitDeny ? ["approval-denied"] : []))
            #expect(provider.approvalReceipts.isEmpty && provider.toolOutputs.isEmpty)
            #expect(bridge.actionHistory.records.isEmpty && backing.readCount == 0)
            #expect(provider.requests.count == 2)
            let next = try #require(provider.requests.dropFirst().first)
            let refusal = try nextRequestToolBody(next, native: native, callID: callID, expectedError: true)
            let expected = explicitDeny
                ? ApprovalError.denied(reason: "AJ2 exact synthetic request denied").localizedDescription
                : ToolExecutorError.approvalRequired(SessionReadTool.toolName).localizedDescription
            #expect(refusal == "Error executing tool session_read: \(expected)")
            let payload = String(decoding: try JSONEncoder().encode(next.messages), as: UTF8.self) + (next.systemPrompt ?? "")
            for protected in [secret, ContentSecretRedactor.mask(secret), "AJ2_APPROVAL_PROTECTED_TITLE", "AJ2_APPROVAL_PROTECTED_BODY"] {
                #expect(!refusal.contains(protected) && !payload.contains(protected))
            }
            #expect(try Data(contentsOf: persisted) == before)
            aj2KnownValueObservation(native: native, archived: false, scope: "metadata", stage: "approval-negative",
                details: ["explicit_deny": String(explicitDeny), "requests": String(provider.requests.count),
                    "outputs": String(provider.toolOutputs.count), "trace": provider.approvalTrace.joined(separator: ","),
                    "body": refusal], knownSecrets: [secret])
        }
    }

    @MainActor
    private func makeKnownValueProductionComposition(
        root: URL, sessionStore: SessionStore, secretStore: EnvVarStore, keychain: KeychainStore
    ) async -> (BridgeStore, SettingsCenter, String) {
        let usageSuite = "D05-known-values-\(UUID().uuidString)"
        let usage = UsageStore(domain: .suite(usageSuite))
        let memory = MemoryStore(directory: root.appendingPathComponent("memory"))
        let settings = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: secretStore, memoryStore: memory, sessionStore: sessionStore,
            logManager: LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 20),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")), usageStore: usage)
        _ = await usage.waitForPersistence()
        let bridge = BridgeStore(sessionDocumentStore: SessionDocumentStore(directory: root.appendingPathComponent("documents")),
            canvasRuntimeState: .absent, memoryStore: memory)
        let initialAttachment = ProductionOrchestrationDefaults.attachProductionServices(to: bridge,
            fileAccessAllowedRoot: root, fileAccessDeniedRoots: [], sessionDirectory: sessionStore.directory,
            mcpManager: settings.mcpManager, skillStore: settings.skillStore, canvasRuntimeState: .absent,
            externalNetworkAllowed: false, sessionReadSecretStore: settings.envStore)
        await initialAttachment.value
        return (bridge, settings, usageSuite)
    }

    @Test @MainActor
    func productionReattachRetainsTheSameSettingsSecretStore() async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "D05-known-reattach",
            processEnvironment: ["SWIFT_TESTING_ENABLED": "1"], processArguments: ["D05.xctest"], canvasRuntimeState: .absent)
        let root = profile.rootDirectory
        defer { try? FileManager.default.removeItem(at: root) }
        let backing = D05MemoryCredentialBacking()
        let keychain = KeychainStore(backing: backing)
        let secretStore = EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain)
        let old = "OLDUnformattedKnownPrivateValueTAIL"
        let updated = "NEWUnformattedKnownPrivateValueTAIL"
        #expect(secretStore.setEnvVar(name: "D05_OLD", value: old, isSecret: true))
        let store = SessionStore(directory: profile.sessionDirectory)
        let target = "00000000-0000-0000-0000-000000000208"
        try store.updateSession(ChatSession(id: target, title: "\(old) \(updated)"))
        let (bridge, settings, usageSuite) = await makeKnownValueProductionComposition(
            root: root, sessionStore: store, secretStore: secretStore, keychain: keychain)
        defer { UserDefaults(suiteName: usageSuite)?.removePersistentDomain(forName: usageSuite) }
        #expect(settings.envStore === secretStore)
        #expect(settings.envStore.setEnvVar(name: "D05_NEW", value: updated, isSecret: true))
        ProductionOrchestrationDefaults.bindChildConcurrencySelection(to: bridge, settings: settings, profile: profile)
        let selected = settings.childConcurrencyUserSelected == 12 ? 13 : 12
        settings.childConcurrencyUserSelected = selected
        // The SettingsCenter callback queues the real production re-attach.
        // Wait for that exact retained-governor transaction before reading its
        // replacement engine or attempting a session read.
        let reattachment = try #require(bridge.lastChildGovernorSafetyTask)
        await reattachment.value
        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        #expect(bridge.childConcurrencySelection.userSelected == selected)
        let composed = try #require(engine.composedExecutor as? any SessionReadCapabilityAwareToolExecutor)
        let box = AJ2SessionReadExecutorBox(executor: composed)
        let path = store.sessionsDirectory.appendingPathComponent("\(target).json")
        let before = try Data(contentsOf: path)
        let now = Date()
        let authorization = CrossSessionReadAuthorization.issue(currentConversationID: "d05-reattach-source",
            authorizedSessionID: target, turnID: 21, issuedAt: now, lifetime: 60)
        let output = try await box.executeSessionRead(input: ["session_id": target, "scope": "metadata"],
            authorization: authorization,
            context: SessionReadExecutionContext(currentConversationID: "d05-reattach-source", turnID: 21), now: now)
        let json = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let metadata = try #require(json["metadata"] as? [String: Any])
        #expect(metadata["title"] as? String == "\(ContentSecretRedactor.mask(old)) \(ContentSecretRedactor.mask(updated))")
        #expect(!output.contains(old) && !output.contains(updated))
        #expect(backing.readCount == 0)
        #expect(try Data(contentsOf: path) == before)
    }
}

// D-SESSIONREAD-01: the Core refusal must survive the ordinary Bridge ->
// ChatStore consumer, rather than existing only in the next model request.
// The scripted model emits a tool call and then an unrelated final sentence;
// it never supplies the refusal text used in the transcript assertions.
extension AJ2SessionReadEndToEndTests {
    @Test(arguments: [false, true]) @MainActor
    func deniedReadRefusalIsPersistedInSourceConversation1568(native: Bool) async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "SessionRead1568", processEnvironment: [:],
            processArguments: ["AJ2SessionReadTests.xctest"], canvasRuntimeState: .disabled)
        let root = profile.rootDirectory
        let defaults = profile.makeUserDefaults()
        defer {
            if let suite = profile.userDefaultsSuiteName {
                defaults.removePersistentDomain(forName: suite)
            }
            try? profile.cleanupDisposableRoots()
        }
        let sessions = SessionStore(directory: profile.sessionDirectory)
        let badges = SessionBadgeStore(directory: root.appendingPathComponent("badges1568"))
        let targetID = "00000000-0000-0000-0000-000000001568"
        let targetTitle = "SESSIONREAD1568_B_TITLE"
        let targetBody = "SESSIONREAD1568_B_HISTORY"
        try sessions.updateSession(ChatSession(id: targetID, title: targetTitle,
            messages: [LLMMessage(role: .user, content: targetBody)]))
        let targetFile = sessions.sessionsDirectory.appendingPathComponent("\(targetID).json")
        let keychain = KeychainStore(backing: D05MemoryCredentialBacking())
        let skills = SkillStore(skillsRoot: root.appendingPathComponent("skills1568"))
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            logManager: profile.makeLogManager(),
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("Workflows1568")),
            sessionDocumentStore: SessionDocumentStore(directory: profile.sessionDirectory),
            canvasRuntimeState: .disabled,
            memoryStore: MemoryStore(directory: profile.memoryDirectory),
            taskCenterBindingPersistenceURL: root.appendingPathComponent("task-bindings1568.json"),
            canvasFeatureLane: .phase3NonCanvas)
        try #require(bridge.chat.attachPersistence(sessions, badgeStore: badges))
        let attachment = bridge.attachProductionServices(fileAccessAllowedRoot: root, fileAccessDeniedRoots: [],
            sessionDirectory: sessions.directory,
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps1568.json"), keychain: keychain),
            skillStore: skills, canvasRuntimeState: .disabled, externalNetworkAllowed: false,
            sessionReadSecretStore: EnvVarStore(directory: root.appendingPathComponent("env1568"), keychain: keychain))
        await attachment.value
        bridge.chat.newSession()
        defer { bridge.chat.stopAllStreamingForSafety() }
        let targetBefore = try Data(contentsOf: targetFile)
        let sourceID = try #require(bridge.chat.activeSessionID)
        let production = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let composed = try #require(production.composedExecutor as? any SessionReadCapabilityAwareToolExecutor)
        let originalTaskPolicy = bridge.chat.prepareTopLevelTaskPolicy
        defer { bridge.chat.prepareTopLevelTaskPolicy = originalTaskPolicy }
        #expect(production.chatRuntimeDependencies?.sessionStore === sessions)
        #expect(bridge.chat.sessionManager?.store === sessions)
        bridge.chat.turnRuntimeSnapshotFactory = { turn, _ in
            .init(turn: turn, skillInjector: SkillInjector(store: skills).snapshotForTurn(), mcpBridge: nil)
        }
        let callID = "sessionread1568-denied-\(native)"
        let provider = AJ2SessionReadProvider(nativeResponses: [
            try responseForRead(native: native, id: callID,
                input: ["session_id": targetID, "scope": "messages"]),
            LLMResponse(text: "1568 ordinary final answer", stopReason: "stop", usage: nil),
        ])
        let box = AJ2SessionReadExecutorBox(executor: composed)
        let counter = AJ2SessionReadCallCounter(base: box)
        let approval = AJ2SessionReadCardApproval(target: targetID, scope: "messages", allow: false)
        bridge.chat.agentEngine = AgentLoopChatEngine(toolExecutor: counter, maxIterations: 3,
            approvalGate: ApprovalGate(delegate: approval),
            toolExecutionFactLedger: try ToolExecutionFactLedger(
                persistenceURL: root.appendingPathComponent("facts1568.json")),
            composerPolicyFacts: bridge.chat.composerPolicyFacts,
            composerGrantStore: bridge.chat.composerGrantStore)
        bridge.chat.streamingProviderOverride = provider

        bridge.chat.draftText = "请回答一个普通问题。"
        observeAJ2TaskPolicy(bridge: bridge, prepare: originalTaskPolicy,
            box: box, outerExecutor: counter)
        bridge.chat.submitComposer()
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while bridge.chat.isStreaming && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!bridge.chat.isStreaming)
        #expect(bridge.chat.activeSessionID == sourceID)
        #expect(provider.requests.count == 2)
        let secondRequest = try #require(provider.requests.dropFirst().first)
        let refusal = try nextRequestToolBody(secondRequest, native: native,
            callID: callID, expectedError: true)
        #expect(refusal.contains("AJ2 card denied"))
        #expect(await approval.requests.count == 1, "the model call must raise one approval card")
        #expect(counter.sessionReadCallCount == 0, "B-read must stop before the real reader")
        #expect(try Data(contentsOf: targetFile) == targetBefore)

        let visible = bridge.chat.messages.map(\.content).joined(separator: "\n")
        #expect(visible.contains("工具调用未执行"), "A must show the typed non-execution refusal, not merely send it to the model")
        #expect(!visible.contains(targetTitle) && !visible.contains(targetBody))
        let reopenedA = try #require(SessionStore(directory: sessions.directory)
            .loadSession(id: sourceID.uuidString))
        let persisted = reopenedA.messages.map(\.content).joined(separator: "\n")
        #expect(persisted.contains("工具调用未执行"), "A refusal must survive transcript reload")
        #expect(!persisted.contains(targetTitle) && !persisted.contains(targetBody))
        #expect(try Data(contentsOf: targetFile) == targetBefore)
    }
}

// D-SESSIONREAD-02, user-confirmed interpretation A (Claude 2155 / user 2206).
// Reuses the existing 759 ordinary Composer/Bridge/AgentLoop fixture components.
extension AJ2SessionReadEndToEndTests {
    @Test(arguments: [false, true]) @MainActor
    func approvedMessagesScopeAndBoundsReachBothActualProviderRequestRoutes(native: Bool) async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "AJ2-pages768", processEnvironment: [:],
            processArguments: ["AJ2SessionReadTests.xctest"], canvasRuntimeState: .disabled
        )
        let root = profile.rootDirectory
        let defaults = profile.makeUserDefaults()
        defer {
            if let suite = profile.userDefaultsSuiteName {
                defaults.removePersistentDomain(forName: suite)
            }
            try? profile.cleanupDisposableRoots()
        }
        let sessions = SessionStore(directory: profile.sessionDirectory)
        let badges = SessionBadgeStore(directory: root.appendingPathComponent("badges768"))
        let keychain = KeychainStore(backing: D05MemoryCredentialBacking())
        let secrets = EnvVarStore(directory: root.appendingPathComponent("env768"), keychain: keychain)
        // Seed persisted roots before the one-shot bootstrap so the real
        // ChatStore owns B/C in its canonical list; a post-bootstrap external
        // root would legitimately be treated as an orphan by persistence.
        let targetID = "00000000-0000-0000-0000-000000000768"
        let otherID = "00000000-0000-0000-0000-000000000769"
        let markers = (0..<55).map { "AJ2_768_PAGE_\($0)_" }
        let texts = markers.enumerated().map { index, marker in
            index == 0 ? marker + String(repeating: "👩🏽‍💻e\u{301}正文", count: 4_000) + "AJ2_768_HIDDEN_TAIL"
                : marker + "owned ordinary message \(index)"
        }
        let messages = texts.enumerated().map { index, text in
            LLMMessage(role: index.isMultiple(of: 2) ? .user : .assistant, content: text)
        }
        try sessions.updateSession(ChatSession(id: targetID, title: "AJ2_768_TARGET_TITLE", messages: messages))
        try sessions.updateSession(ChatSession(id: otherID, title: "AJ2_768_FOREIGN_TITLE",
            messages: [LLMMessage(role: .user, content: "AJ2_768_FOREIGN_BODY")]))
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            logManager: profile.makeLogManager(),
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("Workflows768")),
            sessionDocumentStore: SessionDocumentStore(directory: profile.sessionDirectory),
            canvasRuntimeState: .disabled,
            memoryStore: MemoryStore(directory: profile.memoryDirectory),
            taskCenterBindingPersistenceURL: root.appendingPathComponent("task-bindings768.json"),
            canvasFeatureLane: .phase3NonCanvas
        )
        #expect(bridge.chat.attachPersistence(sessions, badgeStore: badges))
        let skills = SkillStore(skillsRoot: root.appendingPathComponent("skills768"))
        let attachment = bridge.attachProductionServices(
            fileAccessAllowedRoot: root, fileAccessDeniedRoots: [],
            sessionDirectory: sessions.directory,
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps768.json"), keychain: keychain),
            skillStore: skills,
            canvasRuntimeState: .disabled, externalNetworkAllowed: false,
            sessionReadSecretStore: secrets
        )
        await attachment.value
        bridge.chat.newSession()
        let manager = try #require(bridge.chat.sessionManager)
        #expect(bridge.chat.sessions.contains(where: { $0.id.uuidString == targetID }))
        #expect(bridge.chat.sessions.contains(where: { $0.id.uuidString == otherID }))
        #expect(bridge.chat.activeSessionID?.uuidString != targetID && bridge.chat.activeSessionID?.uuidString != otherID)
        #expect(manager.store === sessions && manager.badgeStore === badges)
        let production = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let composed = try #require(production.composedExecutor as? any SessionReadCapabilityAwareToolExecutor)
        let originalTaskPolicy = bridge.chat.prepareTopLevelTaskPolicy
        defer { bridge.chat.prepareTopLevelTaskPolicy = originalTaskPolicy }
        #expect(production.chatRuntimeDependencies?.sessionStore === sessions)
        let targetFile = sessions.sessionsDirectory.appendingPathComponent("\(targetID).json")
        let foreignFile = sessions.sessionsDirectory.appendingPathComponent("\(otherID).json")
        let targetBefore = try Data(contentsOf: targetFile)
        let foreignBefore = try Data(contentsOf: foreignFile)
        let persistedBefore = try #require(manager.loadSessionIncludingArchived(id: targetID))
        let facts = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts768.json"))
        let sourceID = try #require(bridge.chat.activeSessionID)
        let originalCommandHandler = bridge.chat.onSendCommand
        let originalEngine = bridge.chat.agentEngine
        let originalProvider = bridge.chat.streamingProviderOverride
        let originalRuntimeFactory = bridge.chat.turnRuntimeSnapshotFactory
        // Reuse the existing 460 offline Provider boundary: the real ordinary
        // ChatStore pipeline still freezes the owned SkillStore and sends its
        // own execution identity. No production route/grant is fabricated.
        bridge.chat.turnRuntimeSnapshotFactory = { turn, _ in
            .init(turn: turn, skillInjector: SkillInjector(store: skills).snapshotForTurn(), mcpBridge: nil)
        }
        var producedSnapshot: ComposerSubmissionSnapshot?
        bridge.chat.onSendCommand = { _, snapshot in
            producedSnapshot = snapshot
            // Observe the producer, then let the ordinary ChatStore caller
            // create and pass the matching executionIdentity to AgentLoop.
            return false
        }
        defer {
            bridge.chat.stopAllStreamingForSafety()
            bridge.chat.onSendCommand = originalCommandHandler
            bridge.chat.agentEngine = originalEngine
            bridge.chat.streamingProviderOverride = originalProvider
            bridge.chat.turnRuntimeSnapshotFactory = originalRuntimeFactory
        }
        let scenarios: [(label: String, input: [String: Any], error: String?)] = [
            ("lower-bounds", ["session_id": targetID, "scope": "messages", "offset": -9, "limit": 0, "max_chars": 1], nil),
            ("upper-bounds", ["session_id": targetID, "scope": "messages", "offset": 0, "limit": 999, "max_chars": 99_999], nil),
            ("empty-page", ["session_id": targetID, "scope": "messages", "offset": 999, "limit": 2, "max_chars": 200], nil),
            ("invalid-scope", ["session_id": targetID, "scope": "not-a-scope"], ToolExecutorError.invalidParameter("scope").localizedDescription),
        ]
        for (index, scenario) in scenarios.enumerated() {
            let callID = "aj2-scope768-\(scenario.label)"
            let provider = AJ2SessionReadProvider(nativeResponses: [
                try responseForRead(native: native, id: callID, input: scenario.input),
                LLMResponse(text: "OFFLINE_FINAL_SENTINEL", stopReason: "stop", usage: nil),
            ])
            let approval = AJ2SessionReadApprovalDelegate()
            let gate = ApprovalGate(delegate: approval)
            let box = AJ2SessionReadExecutorBox(executor: composed, onOutput: { provider.recordOutput($0) },
                onObservation: { stage, _, _ in provider.recordApprovalTrace(stage) })
            let counter = AJ2SessionReadCallCounter(base: box)
            #expect(box.policyRuntimeBound)
            #expect(counter.policyRuntimeBound == box.policyRuntimeBound)
            bridge.chat.agentEngine = AgentLoopChatEngine(toolExecutor: counter, maxIterations: 3,
                approvalGate: gate, toolExecutionFactLedger: facts,
                composerPolicyFacts: bridge.chat.composerPolicyFacts,
                composerGrantStore: bridge.chat.composerGrantStore)
            bridge.chat.streamingProviderOverride = provider
            producedSnapshot = nil
            // The user's words mint nothing; every model call is bounded by
            // the single-use capability issued from the approved card.
            bridge.chat.draftText = "请授权读取会话 \(targetID) 的消息。AJ2_768_SOURCE_INTENT"
            observeAJ2TaskPolicy(bridge: bridge, prepare: originalTaskPolicy,
                box: box, outerExecutor: counter)
            bridge.chat.submitComposer()
            let submission = try #require(producedSnapshot)
            let sent = try #require(bridge.chat.messages.last(where: { $0.role == .user }))
            #expect(submission == bridge.chat.lastComposerSubmissionSnapshot)
            #expect(submission.sessionID == sourceID.uuidString && submission.messageID == sent.id.uuidString)
            #expect(submission.turnID == index && bridge.chat.activeSessionID == sourceID)
            // The provider reply and the durable turn finalizer are distinct.
            // Join the actual turn so a busy full-suite run does not mistake
            // a six-second observation timeout for a terminal lifecycle.
            if let turnTask = bridge.chat.turnTaskForTests(sessionID: sourceID) {
                await turnTask.value
            }
            try #require(!bridge.chat.isStreaming)
            #expect(bridge.chat.turnTaskForTests(sessionID: sourceID) == nil)
            let execution = bridge.chat.executionSnapshot(forSessionID: sourceID)
            let reason = execution?.failureReason ?? ""
            let assistant = bridge.chat.messages.last(where: { $0.role == .assistant })?.content ?? ""
            let knownErrors: [(String, any Error)] = [
                ("policyRuntimeRequired", SecureAgentLoopError.policyRuntimeRequired),
                ("executionIdentityMismatch", AgentLoopError.executionIdentityMismatch),
                ("budgetExhausted", AgentLoopError.budgetExhausted),
                ("outputTokenCeilingExhausted", AgentLoopError.outputTokenCeilingExhausted),
                ("composerSnapshotMismatch", AgentLoopError.composerSnapshotMismatch),
                ("composerAuthorizationUnavailable", AgentLoopError.composerAuthorizationUnavailable),
                ("missingPolicyFacts", ComposerEngineError.missingPolicyFacts),
                ("missingRuntimeSnapshot", ChatTurnRuntimeSnapshotError.missingRequiredSnapshot),
                ("runtimeIdentityMismatch", ChatTurnRuntimeSnapshotError.identityMismatch),
                ("partialHistoryInvalid", ChatSessionRuntimeError.partialHistoryInvalid),
                ("contextMismatch", ChatSessionRuntimeError.contextMismatch),
                ("personaMismatch", ChatSessionRuntimeError.personaMismatch),
                ("skillScopeMismatch", ChatSessionRuntimeError.skillScopeMismatch),
                ("invalidSession", ChatSessionRuntimeError.invalidSession),
                ("invalidScope", ChatSessionRuntimeError.invalidScope),
                ("startupNotReady", ChatSessionRuntimeError.startupNotReady),
            ]
            // Emit only known enum labels/counts from this owned runtime.
            // Neither the localized reason nor transcript/provider body is logged.
            let classes = knownErrors.compactMap { label, error in
                let fixed = ChatStore.userErrorMessage(error)
                return reason.contains(fixed) || assistant.contains(fixed) ? label : nil
            }.joined(separator: ",")
            print("AJ2_768_RUNTIME scenario=\(scenario.label) index=\(index) state=\(execution?.state.rawValue ?? "none") class=\(classes.isEmpty ? "unclassified" : classes) requests=\(provider.requests.count) outputs=\(provider.toolOutputs.count) counter=\(counter.sessionReadCallCount) facts=\(facts.facts.count)")
            let finalModelReply = "OFFLINE_FINAL_SENTINEL"
            let modelSegments = assistant.components(separatedBy: finalModelReply)
            #expect(modelSegments.count == 2, "the provider's complete final reply must appear exactly once")
            #expect(modelSegments.last == "", "no confirmed pre-dispatch refusal may be invented")
            let approvalRequests = await approval.requests
            #expect(approvalRequests.count == 1 || scenario.label == "invalid-scope")
            try #require(provider.requests.count == 2)
            let nextRequest = try #require(provider.requests.dropFirst().first)
            let body = try nextRequestToolBody(nextRequest, native: native, callID: callID,
                expectedError: scenario.error != nil)
            if let error = scenario.error {
                #expect(body == "Error executing tool session_read: \(error)")
                // This observer wraps the actual Bridge reader chain: zero
                // delegation stops before its SessionManager load boundary.
                #expect(counter.sessionReadCallCount == 0)
                #expect(provider.toolOutputs.isEmpty && provider.approvalTrace.isEmpty)
                for forbidden in markers + ["AJ2_768_TARGET_TITLE", "AJ2_768_FOREIGN_TITLE", "AJ2_768_FOREIGN_BODY"] {
                    #expect(!body.contains(forbidden))
                }
                #expect(facts.facts.filter { $0.status == .succeeded }.count == 3)
            } else {
                #expect(counter.sessionReadCallCount == 1)
                try #require(provider.toolOutputs.count == 1)
                let rawOutput = try #require(provider.toolOutputs.first)
                #expect(body == MCPOutputLimiter.project(rawOutput))
                #expect(body.count <= MCPOutputLimiter.defaultMaximumCharacters)
                let modelProjection = try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
                if rawOutput.count > MCPOutputLimiter.defaultMaximumCharacters {
                    #expect(modelProjection["truncated"] as? Bool == true)
                    #expect(modelProjection["preview"] is String)
                } else {
                    #expect(modelProjection["ok"] as? Bool == true)
                }
                #expect(provider.approvalTrace == ["typed-enter", "typed-success"])
                // Authorization and page bounds belong to the actual reader result;
                // the next Provider sees the same universal O13 projection as other tools.
                let object = try #require(JSONSerialization.jsonObject(with: Data(rawOutput.utf8)) as? [String: Any])
                #expect(object["ok"] as? Bool == true && object["scope"] as? String == "messages")
                #expect(object["session_id"] as? String == targetID && object["total"] as? Int == 55)
                #expect(object["turn_id"] as? Int == 1)
                let page = try #require(object["messages"] as? [[String: Any]])
                let count = index == 0 ? 1 : index == 1 ? 50 : 0
                let maxChars = index == 1 ? 8_000 : 200
                #expect(page.count == count && page.count < texts.count)
                #expect(object["offset"] as? Int == (index == 2 ? 999 : 0))
                #expect(object["cursor_offset"] as? Int == (index == 2 ? 55 : 0))
                #expect(object["limit"] as? Int == (index == 0 ? 1 : index == 1 ? 50 : 2))
                #expect(object["max_chars"] as? Int == maxChars)
                #expect(object["has_more"] as? Bool == (index != 2))
                if index == 2 { #expect(object["next_offset"] is NSNull) }
                else { #expect(object["next_offset"] as? Int == count) }
                for (item, position) in zip(page, 0..<count) {
                    let text = try #require(item["text"] as? String)
                    #expect(text == String(texts[position].prefix(maxChars)))
                    #expect(item["role"] as? String == messages[position].role.rawValue)
                    #expect(text.count <= maxChars && text.utf8.count <= 64_000)
                    #expect(item["character_count"] as? Int == text.count)
                    #expect(item["byte_count"] as? Int == text.utf8.count)
                }
                for (position, marker) in markers.enumerated() {
                    #expect(rawOutput.contains(marker) == (position < count))
                }
                for forbidden in ["AJ2_768_SOURCE_INTENT", "AJ2_768_FOREIGN_TITLE", "AJ2_768_FOREIGN_BODY", "AJ2_768_HIDDEN_TAIL"] {
                    #expect(!rawOutput.contains(forbidden) && !body.contains(forbidden))
                }
            }
            let payload = String(decoding: try JSONEncoder().encode(nextRequest.messages), as: UTF8.self)
                + (nextRequest.systemPrompt ?? "")
            #expect(!payload.contains("AJ2_768_FOREIGN_TITLE") && !payload.contains("AJ2_768_FOREIGN_BODY"))
            #expect(try Data(contentsOf: targetFile) == targetBefore)
            #expect(try Data(contentsOf: foreignFile) == foreignBefore)
        }
        #expect(facts.facts.filter { $0.status == .succeeded }.count == 3)
        let reopened = try #require(SessionStore(directory: sessions.directory).loadSession(id: targetID))
        #expect(reopened.messages == persistedBefore.messages && reopened.transcriptRevision == persistedBefore.transcriptRevision)
        #expect(try Data(contentsOf: targetFile) == targetBefore)
        #expect(try Data(contentsOf: foreignFile) == foreignBefore)
    }
}

// The existing counting decorator must preserve the real base policy binding;
// this cannot grant policy authority to an unbound executor.
extension AJ2SessionReadCallCounter: PolicyRuntimeBoundToolExecutor {
    var policyRuntimeBound: Bool {
        (base as? any PolicyRuntimeBoundToolExecutor)?.policyRuntimeBound == true
    }
}

// D-COMPOSER-18: ordinary Composer, unchanged Bridge reader and actual AgentLoop.
// Only the external model's answer/tool call is scripted; no local routing or
// capability/approval result is replaced. Positive typed intent proves the
// counting boundary and the same owned target can actually be read.
extension AJ2SessionReadEndToEndTests {
    @Test(arguments: [false, true]) @MainActor
    func referencePasteDoesNotDecideSessionReadApprovalInOrdinaryComposer(native: Bool) async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "AJ2-reference793", processEnvironment: [:],
            processArguments: ["AJ2SessionReadTests.xctest"], canvasRuntimeState: .disabled)
        let root = profile.rootDirectory
        let defaults = profile.makeUserDefaults()
        defer {
            if let suite = profile.userDefaultsSuiteName { defaults.removePersistentDomain(forName: suite) }
            try? profile.cleanupDisposableRoots()
        }
        let sessions = SessionStore(directory: profile.sessionDirectory)
        let targetID = "00000000-0000-0000-0000-000000000793"
        let targetText = "AJ2_793_OWNED_FOREIGN_CONTENT"
        try sessions.updateSession(ChatSession(id: targetID, title: "AJ2_793_OWNED_TARGET",
            messages: [LLMMessage(role: .user, content: targetText)]))
        let keychain = KeychainStore(backing: D05MemoryCredentialBacking())
        let bridge = BridgeStore(shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            logManager: profile.makeLogManager(),
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("Workflows793")),
            sessionDocumentStore: SessionDocumentStore(directory: profile.sessionDirectory),
            canvasRuntimeState: .disabled, memoryStore: MemoryStore(directory: profile.memoryDirectory),
            taskCenterBindingPersistenceURL: root.appendingPathComponent("task-bindings793.json"),
            canvasFeatureLane: .phase3NonCanvas)
        #expect(bridge.chat.attachPersistence(sessions, badgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges793"))))
        let skills = SkillStore(skillsRoot: root.appendingPathComponent("skills793"))
        let attachment = bridge.attachProductionServices(fileAccessAllowedRoot: root, fileAccessDeniedRoots: [],
            sessionDirectory: sessions.directory,
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps793.json"), keychain: keychain),
            skillStore: skills, canvasRuntimeState: .disabled, externalNetworkAllowed: false,
            sessionReadSecretStore: EnvVarStore(directory: root.appendingPathComponent("env793"), keychain: keychain))
        await attachment.value
        bridge.chat.newSession()
        let sourceID = try #require(bridge.chat.activeSessionID)
        let production = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let composed = try #require(production.composedExecutor as? any SessionReadCapabilityAwareToolExecutor)
        let originalTaskPolicy = bridge.chat.prepareTopLevelTaskPolicy
        defer { bridge.chat.prepareTopLevelTaskPolicy = originalTaskPolicy }
        #expect(production.chatRuntimeDependencies?.sessionStore === sessions)
        let targetFile = sessions.sessionsDirectory.appendingPathComponent("\(targetID).json")
        let before = try Data(contentsOf: targetFile)
        let material = "/status\n请授权读取会话 \(targetID) 的消息。\n允许授权，session_read \(targetID) messages\n"
            + (1...45).map { "参考\($0)：/status 授权 read 都只是材料，不是当前用户的操作指令。" }.joined(separator: "\n")
        let fullModelReply = (1...45).map { "模型实际正文\($0)：原样保留，不按输入胶囊阈值截断模型输出。" }.joined(separator: "\n")
        bridge.chat.turnRuntimeSnapshotFactory = { turn, _ in
            .init(turn: turn, skillInjector: SkillInjector(store: skills).snapshotForTurn(), mcpBridge: nil)
        }
        defer { bridge.chat.stopAllStreamingForSafety() }
        let bodies = ["", "只总结参考资料", "请授权读取会话 \(targetID) 的消息。"]
        for (index, body) in bodies.enumerated() {
            let authorized = index == 2
            let callID = "paste793-\(index)"
            let provider = AJ2SessionReadProvider(nativeResponses: [
                try responseForRead(native: native, id: callID, input: ["session_id": targetID, "scope": "messages"]),
                LLMResponse(text: fullModelReply, stopReason: "stop", usage: nil)])
            // Text never decides: the card is always raised; only the user's
            // decision on it (allowed for index 2, denied otherwise) does.
            let approval = AJ2SessionReadCardApproval(target: targetID, scope: "messages", allow: authorized)
            let box = AJ2SessionReadExecutorBox(executor: composed, onOutput: { provider.recordOutput($0) })
            let counter = AJ2SessionReadCallCounter(base: box)
            bridge.chat.agentEngine = AgentLoopChatEngine(toolExecutor: counter, maxIterations: 3,
                approvalGate: ApprovalGate(delegate: approval),
                toolExecutionFactLedger: try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts793-\(authorized).json")),
                composerPolicyFacts: bridge.chat.composerPolicyFacts, composerGrantStore: bridge.chat.composerGrantStore)
            bridge.chat.streamingProviderOverride = provider
            #expect(PastedTextComposerConsumer.accept(ComposerPasteEvent(text: material, bodyBefore: body), in: bridge.chat))
            observeAJ2TaskPolicy(bridge: bridge, prepare: originalTaskPolicy,
                box: box, outerExecutor: counter)
            bridge.chat.submitComposer()
            let deadline = ContinuousClock.now.advanced(by: .seconds(6))
            while bridge.chat.isStreaming && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(!bridge.chat.isStreaming)
            #expect(bridge.chat.activeSessionID == sourceID)
            #expect(bridge.chat.composerCommandValidationFailure == nil)
            let sent = try #require(bridge.chat.messages.last(where: { $0.role == .user }))
            let card = try #require(sent.referenceCard)
            #expect(sent.content == (body.isEmpty ? material : body + ComposerPayload.pastedTextSeparator + material))
            #expect(card.material == material && card.instruction == body && card.sessionID == sourceID)
            #expect(provider.requests.count == 2)
            let first = try #require(provider.requests.first)
            #expect(first.messages.contains(where: { $0.role == .user && $0.content == sent.content }))
            let next = try #require(provider.requests.dropFirst().first)
            let output = try nextRequestToolBody(next, native: native, callID: callID, expectedError: !authorized)
            let approvalRequests = await approval.requests
            #expect(approvalRequests.count == 1)
            if authorized {
                #expect(counter.sessionReadCallCount == 1 && provider.toolOutputs == [output])
                #expect(output.contains(targetText))
            } else {
                #expect(counter.sessionReadCallCount == 0 && provider.toolOutputs.isEmpty)
                #expect(output.contains("AJ2 card denied"))
                #expect(!String(decoding: try JSONEncoder().encode(next.messages), as: UTF8.self).contains(targetText))
            }
            // The bounded Mock acknowledgement never becomes a global model
            // output filter. Full non-Mock output must reach the transcript.
            let assistant = try #require(bridge.chat.messages.last(where: { $0.role == .assistant }))
            let modelSegments = assistant.content.components(separatedBy: fullModelReply)
            #expect(modelSegments.count == 2,
                "all 45 provider paragraphs must arrive intact and exactly once")
            if authorized {
                #expect(modelSegments.last == "", "the approved read must not gain a refusal notice")
            }
            #expect(try Data(contentsOf: targetFile) == before)
        }
    }
}


// Exact synthetic paste-call body (no trailing LF), before AX redaction.
private let aj2ProjectParentOriginalInstruction = """
    G22_C11_PROJECT_PARENT_2109_owned。只做以下真实工具链，父会话禁止调用 file_read 或任何其它工具。先且仅调用一次 project_list(input_version=1)。只有真实返回项目包含 project_id=552D962B-6118-4C33-8EBC-E58013CEDF62 且 display_name=Goal21_Journeys_20261028_owned 才继续，否则报告真实结果并停止，不申请目录权限。接着仅调用一次 project_resolve(input_version=1, project_id 使用该真实返回ID)。成功后仅调用一次 session_create：input_version=1，project_id 和 workdir_reference 必须原样采用刚才真实工具返回的不透明引用；title=Goal22 合成项目任务 目标只读；idempotency_key=G22_C11_PROJECT_210510_own；switch_after_create=false；省略 source_session_id、source_turn_id、capsule。initial_task 原文为：只调用 file_read 一次读取 /Users/alice/Desktop/测试_TASK12G1/Goal21_Journeys_20261028_owned/Goal22_output_owned_20261030T191602+0800_82e68736/owned-content.txt 。若实际返回内容精确为 G22_OWNED_OUTPUT04_PRODUCED 加一个 LF（28 字节），只回复 G22_C11_PROJECT_READ_OK。拒绝或不符时只报告真实原因；不调用其它工具，不重试，不写入，不扩大权限。父会话任一步失败立即报告公开 typed 原因并停止，不猜引用、不重试、不代替目标读文件。
    """

// Read-looking typed text must reach the real Provider, without minting a
// read grant. The same current instruction and reference payload travel through
// Composer -> Bridge-bound AgentLoop; only model output is scripted.
extension AJ2SessionReadEndToEndTests {
    @Test @MainActor
    func readLookingTextReachesOrdinaryProviderThroughComposer821() async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "AJ2-reference821", processEnvironment: [:],
            processArguments: ["AJ2SessionReadTests.xctest"], canvasRuntimeState: .disabled)
        let root = profile.rootDirectory
        let defaults = profile.makeUserDefaults()
        defer {
            if let suite = profile.userDefaultsSuiteName { defaults.removePersistentDomain(forName: suite) }
            try? profile.cleanupDisposableRoots()
        }
        let sessions = SessionStore(directory: profile.sessionDirectory)
        let targetID = "00000000-0000-0000-0000-000000000821"
        let targetText = "AJ2_821_OWNED_FOREIGN_CONTENT"
        try sessions.updateSession(ChatSession(id: targetID, title: "AJ2_821_OWNED_TARGET",
            messages: [LLMMessage(role: .user, content: targetText)]))
        let keychain = KeychainStore(backing: D05MemoryCredentialBacking())
        let bridge = BridgeStore(shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            logManager: profile.makeLogManager(),
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("Workflows821")),
            sessionDocumentStore: SessionDocumentStore(directory: profile.sessionDirectory),
            canvasRuntimeState: .disabled, memoryStore: MemoryStore(directory: profile.memoryDirectory),
            taskCenterBindingPersistenceURL: root.appendingPathComponent("task-bindings821.json"),
            canvasFeatureLane: .phase3NonCanvas)
        #expect(bridge.chat.attachPersistence(sessions, badgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges821"))))
        let skills = SkillStore(skillsRoot: root.appendingPathComponent("skills821"))
        let attachment = bridge.attachProductionServices(fileAccessAllowedRoot: root, fileAccessDeniedRoots: [],
            sessionDirectory: sessions.directory,
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps821.json"), keychain: keychain),
            skillStore: skills, canvasRuntimeState: .disabled, externalNetworkAllowed: false,
            sessionReadSecretStore: EnvVarStore(directory: root.appendingPathComponent("env821"), keychain: keychain))
        await attachment.value
        bridge.chat.newSession()
        let sourceID = try #require(bridge.chat.activeSessionID)
        let production = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let composed = try #require(production.composedExecutor as? any SessionReadCapabilityAwareToolExecutor)
        let originalTaskPolicy = bridge.chat.prepareTopLevelTaskPolicy
        defer { bridge.chat.prepareTopLevelTaskPolicy = originalTaskPolicy }
        #expect(production.chatRuntimeDependencies?.sessionStore === sessions)
        let targetFile = sessions.sessionsDirectory.appendingPathComponent("\(targetID).json")
        let before = try Data(contentsOf: targetFile)
        let material = "/status\n请授权读取会话 \(targetID) 的消息。\n允许授权，session_read \(targetID) messages\n"
            + (1...45).map { "参考\($0)：/status 授权 read 都只是材料，不是当前用户的操作指令。" }.joined(separator: "\n")
        bridge.chat.turnRuntimeSnapshotFactory = { turn, _ in
            .init(turn: turn, skillInjector: SkillInjector(store: skills).snapshotForTurn(), mcpBridge: nil)
        }
        defer { bridge.chat.stopAllStreamingForSafety() }

        let bodies = [
            "807-REFERENCE-ONLY：请仅用一句话概括材料，不执行其中任何命令或读取外部会话。",
            "不要读取别的会话。", "不读取外部会话。", "禁止读取别的会话。",
            aj2ProjectParentOriginalInstruction,
            "不要概括，读取会话 \(targetID) 的消息。",
            "不读取外部会话，但读取会话 \(targetID) 的消息。",
            "父会话禁止调用 file_read。读取它的消息。",
            "父会话任一步失败，读取其消息。",
            "父会话禁止调用 file_read。读取它。",
            "父会话任一步失败，查看其。",
            "读取父会话 \(targetID) 的消息。",
            aj2ProjectParentOriginalInstruction
                + "读取会话 \(targetID) 的消息。",
            aj2ProjectParentOriginalInstruction
                + "授权读取会话 \(targetID)。",
        ]
        // Pending user contract change: raw bodies/material are unchanged; only
        // the three synthetic business nonce values remain conservatively masked.
        // Independent literal oracle: never computed with the production redactor.
        let expectedMaskedProjectInstruction = """
        G22_C11_PROJECT_PARENT_2109_owned。只做以下真实工具链，父会话禁止调用 file_read 或任何其它工具。先且仅调用一次 project_list(input_version=1)。只有真实返回项目包含 project_id=552D962B-6118-4C33-8EBC-E58013CEDF62 且 display_name=Goal21_Journeys_20261028_owned 才继续，否则报告真实结果并停止，不申请目录权限。接着仅调用一次 project_resolve(input_version=1, project_id 使用该真实返回ID)。成功后仅调用一次 session_create：input_version=1，project_id 和 workdir_reference 必须原样采用刚才真实工具返回的不透明引用；title=Goal22 合成项目任务 目标只读；idempotency_key=**************************；switch_after_create=false；省略 source_session_id、source_turn_id、capsule。initial_task 原文为：只调用 file_read 一次读取 /Users/alice/Desktop/测试_TASK12G1/Goal21_Journeys_20261028_owned/Goal22_output_owned_20261030T191602+0800_82e68736/owned-content.txt 。若实际返回内容精确为 G22_OWNED_OUTPUT04_PRODUCED 加一个 LF（28 字节），只回复 G22_C11_PROJECT_READ_OK。拒绝或不符时只报告真实原因；不调用其它工具，不重试，不写入，不扩大权限。父会话任一步失败立即报告公开 typed 原因并停止，不猜引用、不重试、不代替目标读文件。
        """
        let expectedInstructions: [Int: String] = [
            4: expectedMaskedProjectInstruction,
            12: expectedMaskedProjectInstruction + "读取会话 \(targetID) 的消息。",
            13: expectedMaskedProjectInstruction + "授权读取会话 \(targetID)。",
        ]
        for (index, body) in bodies.enumerated() {
            let expectedInstruction = expectedInstructions[index] ?? body
            let reply = "821_ORDINARY_PROVIDER_REPLY_\(index)"
            let provider = AJ2SessionReadProvider(responses: [reply])
            let approval = AJ2SessionReadApprovalDelegate()
            let box = AJ2SessionReadExecutorBox(executor: composed, onOutput: { provider.recordOutput($0) })
            let counter = AJ2SessionReadCallCounter(base: box)
            bridge.chat.agentEngine = AgentLoopChatEngine(toolExecutor: counter, maxIterations: 3,
                approvalGate: ApprovalGate(policyByTool: [SessionReadTool.toolName: .alwaysAsk], delegate: approval),
                toolExecutionFactLedger: try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts821-\(index).json")),
                composerPolicyFacts: bridge.chat.composerPolicyFacts, composerGrantStore: bridge.chat.composerGrantStore)
            bridge.chat.streamingProviderOverride = provider
            #expect(PastedTextComposerConsumer.accept(ComposerPasteEvent(text: material, bodyBefore: body), in: bridge.chat))
            observeAJ2TaskPolicy(bridge: bridge, prepare: originalTaskPolicy,
                box: box, outerExecutor: counter)
            bridge.chat.submitComposer()
            let deadline = ContinuousClock.now.advanced(by: .seconds(6))
            while bridge.chat.isStreaming && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(!bridge.chat.isStreaming)
            #expect(bridge.chat.activeSessionID == sourceID)
            #expect(bridge.chat.composerCommandValidationFailure == nil)
            let sent = try #require(bridge.chat.messages.last(where: { $0.role == .user }))
            let card = try #require(sent.referenceCard)
            #expect(sent.content == expectedInstruction + ComposerPayload.pastedTextSeparator + material)
            #expect(card.material == material && card.instruction == expectedInstruction && card.sessionID == sourceID)
            #expect(counter.sessionReadCallCount == 0 && provider.toolOutputs.isEmpty)
            let approvals = await approval.requests
            #expect(approvals.isEmpty)
            let assistant = try #require(bridge.chat.messages.last(where: { $0.role == .assistant }))
            // No pre-send text gate: every body reaches the model.
            #expect(provider.requests.count == 1)
            let request = try #require(provider.requests.first)
            #expect(request.messages.contains(where: { $0.role == .user && $0.content == sent.content }))
            #expect(assistant.content == reply)
            #expect(!String(decoding: try JSONEncoder().encode(request.messages), as: UTF8.self).contains(targetText))
            #expect(try Data(contentsOf: targetFile) == before)
            print("AJ2_821_RUNTIME scenario=\(index) providerRequests=\(provider.requests.count) readerCalls=\(counter.sessionReadCallCount)")
        }
    }
}
