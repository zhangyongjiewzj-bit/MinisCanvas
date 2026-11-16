import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

// Batch2L (user decision 11/12, "整体去掉"): the pre-send text gate for session
// reads is removed, aligning with Claude Code / Codex. Ordinary text always
// reaches the model. When the model calls `session_read`, the call goes through
// the normal approval card (target session ID + scope are shown); the user's
// own words never mint an authorization.
//
// Fixture is a self-contained copy of the AJ2SessionReadEndToEndTests production
// composition (real BridgeStore/ChatStore/AgentLoop/ApprovalGate, offline
// Provider). The gate is built with NO policy override so the default
// `session_read` policy is what is under test.

// MARK: - Offline provider

private final class Batch2LProvider: LLMProvider, @unchecked Sendable {
    var name: String { "Batch2L offline provider" }
    var model = LLMModel(id: "batch2l-test", displayName: "Batch2L Test", provider: "Test")
    var capabilities: Set<ProviderCapability> { [.tools] }
    struct Request {
        let messages: [LLMMessage]
        let systemPrompt: String?
    }
    private let lock = NSLock()
    private var responses: [LLMResponse]
    private var requestItems: [Request] = []
    private var outputItems: [String] = []

    var requests: [Request] { lock.withLock { requestItems } }
    var toolOutputs: [String] { lock.withLock { outputItems } }

    init(responses: [LLMResponse]) { self.responses = responses }

    func recordOutput(_ output: String) { lock.withLock { outputItems.append(output) } }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        lock.withLock {
            requestItems.append(Request(messages: messages, systemPrompt: systemPrompt))
            return responses.isEmpty
                ? LLMResponse(text: "没有更多响应", stopReason: "stop", usage: nil)
                : responses.removeFirst()
        }
    }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
        maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        try await sendMessage(
            messages: messages, systemPrompt: systemPrompt,
            maxTokens: maxTokens, temperature: temperature)
    }

    func streamMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

// MARK: - Approval delegate (records the card the user would see)

private actor Batch2LApproval: ApprovalDelegate {
    let allow: Bool
    private(set) var requests: [ApprovalRequest] = []
    init(allow: Bool) { self.allow = allow }

    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        requests.append(request)
        return ApprovalDecision(
            approved: allow,
            reason: allow ? "Batch2L user allowed" : "Batch2L user denied",
            confirmed: allow,
            requestID: request.requestID,
            bindingDigest: request.identityDigest
        )
    }
}

// MARK: - Executor seam (copies of the AJ2 box/counter; only the real executor runs)

private final class Batch2LExecutorBox: SessionReadCapabilityAwareToolExecutor, PolicyRuntimeBoundToolExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var executor: any SessionReadCapabilityAwareToolExecutor
    private let onOutput: @Sendable (String) -> Void
    var policyRuntimeBound: Bool {
        (current as? any PolicyRuntimeBoundToolExecutor)?.policyRuntimeBound == true
    }
    private var current: any SessionReadCapabilityAwareToolExecutor { lock.withLock { executor } }

    init(executor: any SessionReadCapabilityAwareToolExecutor, onOutput: @escaping @Sendable (String) -> Void) {
        self.executor = executor
        self.onOutput = onOutput
    }

    func observe(_ executor: any SessionReadCapabilityAwareToolExecutor) {
        lock.withLock { self.executor = executor }
    }

    func execute(name: String, input: [String: Any]) async throws -> String {
        try await current.execute(name: name, input: input)
    }

    func executeSessionRead(
        input: [String: Any], authorization: CrossSessionReadAuthorization,
        context: SessionReadExecutionContext, now: Date
    ) async throws -> String {
        let output = try await current.executeSessionRead(
            input: input, authorization: authorization, context: context, now: now)
        onOutput(output)
        return output
    }
}

private final class Batch2LCallCounter: SessionReadCapabilityAwareToolExecutor, @unchecked Sendable {
    private let base: any SessionReadCapabilityAwareToolExecutor
    private let lock = NSLock()
    private var count = 0
    init(base: any SessionReadCapabilityAwareToolExecutor) { self.base = base }
    var sessionReadCallCount: Int { lock.withLock { count } }

    private func record(_ name: String) {
        guard name == SessionReadTool.toolName else { return }
        lock.withLock { count += 1 }
    }

    func execute(name: String, input: [String: Any]) async throws -> String {
        record(name)
        return try await base.execute(name: name, input: input)
    }

    func executeSessionRead(
        input: [String: Any], authorization: CrossSessionReadAuthorization,
        context: SessionReadExecutionContext, now: Date
    ) async throws -> String {
        record(SessionReadTool.toolName)
        return try await base.executeSessionRead(
            input: input, authorization: authorization, context: context, now: now)
    }
}

extension Batch2LCallCounter: PolicyRuntimeBoundToolExecutor {
    var policyRuntimeBound: Bool {
        (base as? any PolicyRuntimeBoundToolExecutor)?.policyRuntimeBound == true
    }
}

private final class Batch2LKeychainBacking: KeychainBacking, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func set(_ value: String, forKey key: String) -> Bool { lock.withLock { values[key] = value }; return true }
    func get(_ key: String) -> String? { lock.withLock { values[key] } }
    func delete(_ key: String) -> Bool { _ = lock.withLock { values.removeValue(forKey: key) }; return true }
}

@MainActor
private func observeBatch2LTaskPolicy(
    bridge: BridgeStore,
    prepare: ((String, Date, UUID?, Bool) -> Bool)?,
    box: Batch2LExecutorBox,
    outerExecutor: any ToolExecutor
) {
    bridge.chat.prepareTopLevelTaskPolicy = { [weak bridge] taskID, createdAt, projectTargetID, projectTask in
        guard let bridge, let prepare, prepare(taskID, createdAt, projectTargetID, projectTask),
              let engine = bridge.chat.agentEngine as? AgentLoopChatEngine,
              let executor = engine.composedExecutor as? any SessionReadCapabilityAwareToolExecutor
        else { return false }
        box.observe(executor)
        bridge.chat.agentEngine = engine.withTopLevelTaskPolicy(
            executor: outerExecutor, facts: bridge.chat.composerPolicyFacts)
        return true
    }
}

// MARK: - Harness

private func batch2LToolCall(native: Bool, id: String, input: [String: Any]) throws -> LLMResponse {
    if native {
        let data = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
        let arguments = try #require(String(data: data, encoding: .utf8))
        return LLMResponse(text: "", stopReason: "tool_calls", usage: nil,
            toolCalls: [LLMToolCall(id: id, name: SessionReadTool.toolName, rawArguments: arguments, arguments: input)])
    }
    let envelope: [String: Any] = ["tool_calls": [["id": id, "name": SessionReadTool.toolName, "input": input]]]
    let data = try JSONSerialization.data(withJSONObject: envelope)
    return LLMResponse(text: String(decoding: data, as: UTF8.self), stopReason: "stop", usage: nil)
}

/// Body of the tool result the Provider received for `callID` on a follow-up request.
private func batch2LToolResultBody(_ request: Batch2LProvider.Request, native: Bool, callID: String) -> String? {
    if native {
        return request.messages.first(where: { $0.role == .tool && $0.toolCallID == callID })?.content
    }
    for message in request.messages where message.role == .user {
        guard let data = message.content.data(using: .utf8),
              let blocks = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
        if let block = blocks.first(where: {
            $0["type"] as? String == "tool_result" && $0["tool_use_id"] as? String == callID
        }) { return block["content"] as? String }
    }
    return nil
}

private let batch2LClarificationMarker = "需要明确授权及读取范围"

@MainActor
private final class Batch2LHarness {
    static let targetID = "00000000-0000-0000-0000-0000000b2101"
    static let targetText = "BATCH2L_TARGET_HISTORY_TEXT"
    static let targetTitle = "BATCH2L_TARGET_TITLE"

    let profile: RuntimeIsolationProfile
    let root: URL
    let defaults: UserDefaults
    let sessions: SessionStore
    let bridge: BridgeStore
    let composed: any SessionReadCapabilityAwareToolExecutor
    let originalTaskPolicy: ((String, Date, UUID?, Bool) -> Bool)?
    let targetFile: URL
    let targetBefore: Data
    private var turn = 0

    init() async throws {
        profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "Batch2L", processEnvironment: [:],
            processArguments: ["Batch2LSessionReadTests.xctest"], canvasRuntimeState: .disabled)
        root = profile.rootDirectory
        defaults = profile.makeUserDefaults()
        sessions = SessionStore(directory: profile.sessionDirectory)
        try sessions.updateSession(ChatSession(
            id: Self.targetID, title: Self.targetTitle,
            messages: [LLMMessage(role: .user, content: Self.targetText)]))
        targetFile = sessions.sessionsDirectory.appendingPathComponent("\(Self.targetID).json")
        targetBefore = try Data(contentsOf: targetFile)
        let keychain = KeychainStore(backing: Batch2LKeychainBacking())
        let skills = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            logManager: profile.makeLogManager(),
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("Workflows")),
            sessionDocumentStore: SessionDocumentStore(directory: profile.sessionDirectory),
            canvasRuntimeState: .disabled, memoryStore: MemoryStore(directory: profile.memoryDirectory),
            taskCenterBindingPersistenceURL: root.appendingPathComponent("task-bindings.json"),
            canvasFeatureLane: .phase3NonCanvas)
        try #require(bridge.chat.attachPersistence(
            sessions, badgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges"))))
        let attachment = bridge.attachProductionServices(
            fileAccessAllowedRoot: root, fileAccessDeniedRoots: [],
            sessionDirectory: sessions.directory,
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain),
            skillStore: skills, canvasRuntimeState: .disabled, externalNetworkAllowed: false,
            sessionReadSecretStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain))
        await attachment.value
        bridge.chat.newSession()
        let production = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        composed = try #require(production.composedExecutor as? any SessionReadCapabilityAwareToolExecutor)
        originalTaskPolicy = bridge.chat.prepareTopLevelTaskPolicy
        bridge.chat.turnRuntimeSnapshotFactory = { turn, _ in
            .init(turn: turn, skillInjector: SkillInjector(store: skills).snapshotForTurn(), mcpBridge: nil)
        }
    }

    func tearDown() {
        bridge.chat.stopAllStreamingForSafety()
        bridge.chat.prepareTopLevelTaskPolicy = originalTaskPolicy
        if let suite = profile.userDefaultsSuiteName { defaults.removePersistentDomain(forName: suite) }
        try? profile.cleanupDisposableRoots()
    }

    /// Sends `text` through the real Composer with the default-policy gate and
    /// waits for the turn to finish.
    func send(
        _ text: String, provider: Batch2LProvider, allow: Bool
    ) async throws -> (approval: Batch2LApproval, counter: Batch2LCallCounter) {
        turn += 1
        let approval = Batch2LApproval(allow: allow)
        let box = Batch2LExecutorBox(executor: composed, onOutput: { provider.recordOutput($0) })
        let counter = Batch2LCallCounter(base: box)
        bridge.chat.agentEngine = AgentLoopChatEngine(
            toolExecutor: counter, maxIterations: 3,
            approvalGate: ApprovalGate(delegate: approval),
            toolExecutionFactLedger: try ToolExecutionFactLedger(
                persistenceURL: root.appendingPathComponent("facts-\(turn).json")),
            composerPolicyFacts: bridge.chat.composerPolicyFacts,
            composerGrantStore: bridge.chat.composerGrantStore)
        bridge.chat.streamingProviderOverride = provider
        bridge.chat.draftText = text
        observeBatch2LTaskPolicy(bridge: bridge, prepare: originalTaskPolicy, box: box, outerExecutor: counter)
        bridge.chat.submitComposer()
        if let task = bridge.chat.turnTaskForTests(sessionID: bridge.chat.activeSessionID) {
            await task.value
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while bridge.chat.isStreaming && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!bridge.chat.isStreaming)
        return (approval, counter)
    }

    var assistantText: String {
        bridge.chat.messages.filter { $0.role == .assistant }.map(\.content).joined(separator: "\n")
    }
}

// MARK: - Tests

@Suite("Batch2L session_read: no pre-send text gate, approval card for model calls")
struct Batch2L_SessionReadNoTextGateTests {

    /// 1. Ordinary wording about conversations/history is never intercepted.
    @Test(arguments: [
        "回顾我们之前的对话历史",
        "帮我写一段对话，里面有人查看消息",
        "怎么查看会话列表",
        "请读取 ChatGPT 的对话记录",
        "你能读取 codex 桌面客户端的对话么？",
    ]) @MainActor
    func ordinaryPhrasingReachesProvider(phrase: String) async throws {
        let harness = try await Batch2LHarness()
        defer { harness.tearDown() }
        let reply = "BATCH2L_ORDINARY_REPLY"
        let provider = Batch2LProvider(responses: [
            LLMResponse(text: reply, stopReason: "stop", usage: nil),
        ])
        let (approval, counter) = try await harness.send(phrase, provider: provider, allow: true)

        #expect(provider.requests.count == 1, "\(phrase): the model must receive the turn")
        let request = try #require(provider.requests.first)
        #expect(request.messages.contains { $0.role == .user && $0.content.contains(phrase) })
        #expect(!harness.assistantText.contains(batch2LClarificationMarker), "\(phrase)")
        #expect(harness.assistantText.contains(reply))
        #expect(counter.sessionReadCallCount == 0)
        #expect(await approval.requests.isEmpty)
    }

    /// 2. A model `session_read` call raises an approval card showing the target
    /// session ID and scope. Deny: nothing is read. Allow: the target text is read.
    @Test(arguments: [false, true], [false, true]) @MainActor
    func modelSessionReadAsksApprovalWithTargetAndScope(native: Bool, allow: Bool) async throws {
        let harness = try await Batch2LHarness()
        defer { harness.tearDown() }
        let callID = "batch2l-read-\(native)-\(allow)"
        let provider = Batch2LProvider(responses: [
            try batch2LToolCall(native: native, id: callID,
                input: ["session_id": Batch2LHarness.targetID, "scope": "messages"]),
            LLMResponse(text: "BATCH2L_FINAL", stopReason: "stop", usage: nil),
        ])
        let (approval, counter) = try await harness.send(
            "回顾我们之前的对话历史", provider: provider, allow: allow)

        let requests = await approval.requests
        #expect(requests.count == 1, "session_read must be asked through the approval card")
        let card = try #require(requests.first)
        #expect(card.toolName == SessionReadTool.toolName)
        #expect(card.requiresApproval)
        #expect(card.inputSummary.contains("session_id: \(Batch2LHarness.targetID)"))
        #expect(card.inputSummary.contains("scope: messages"))

        #expect(provider.requests.count == 2)
        let followUp = try #require(provider.requests.dropFirst().first)
        let body = try #require(batch2LToolResultBody(followUp, native: native, callID: callID))
        if allow {
            #expect(counter.sessionReadCallCount == 1)
            #expect(provider.toolOutputs.joined().contains(Batch2LHarness.targetText))
            #expect(body.contains(Batch2LHarness.targetText))
        } else {
            #expect(counter.sessionReadCallCount == 0, "denied: the reader must not run")
            #expect(provider.toolOutputs.isEmpty)
            let payload = String(decoding: try JSONEncoder().encode(followUp.messages), as: UTF8.self)
            #expect(!payload.contains(Batch2LHarness.targetText))
            #expect(!payload.contains(Batch2LHarness.targetTitle))
        }
        #expect(try Data(contentsOf: harness.targetFile) == harness.targetBefore)
    }

    /// 3. The user's own words ("授权只读查看会话 X，读取消息") no longer mint a
    /// grant: the call still goes through the approval card, and deny blocks it.
    @Test(arguments: [false, true]) @MainActor
    func userAuthorizationWordsDoNotBypassApprovalCard(native: Bool) async throws {
        let harness = try await Batch2LHarness()
        defer { harness.tearDown() }
        let callID = "batch2l-text-grant-\(native)"
        let provider = Batch2LProvider(responses: [
            try batch2LToolCall(native: native, id: callID,
                input: ["session_id": Batch2LHarness.targetID, "scope": "messages"]),
            LLMResponse(text: "BATCH2L_FINAL", stopReason: "stop", usage: nil),
        ])
        let text = "授权只读查看会话 \(Batch2LHarness.targetID)，读取消息"
        let (approval, counter) = try await harness.send(text, provider: provider, allow: false)

        #expect(provider.requests.count == 2, "the text reaches the model; no pre-send interception")
        #expect(await approval.requests.count == 1, "text must not replace the approval card")
        #expect(counter.sessionReadCallCount == 0, "user denied the card: nothing is read")
        #expect(provider.toolOutputs.isEmpty)
        let followUp = try #require(provider.requests.dropFirst().first)
        let payload = String(decoding: try JSONEncoder().encode(followUp.messages), as: UTF8.self)
        #expect(!payload.contains(Batch2LHarness.targetText))
        #expect(!harness.assistantText.contains(batch2LClarificationMarker))
    }

    /// 4. Unsafe IDs are still refused by the tool layer, even when the user
    /// would allow the card, and no file outside the sessions directory is read.
    @Test(arguments: [false, true]) @MainActor
    func unsafeSessionIDIsRefusedByToolLayer(native: Bool) async throws {
        let harness = try await Batch2LHarness()
        defer { harness.tearDown() }
        let marker = "BATCH2L_VICTIM_SECRET_MARKER"
        let victim = harness.sessions.sessionsDirectory
            .deletingLastPathComponent().appendingPathComponent("victim.json")
        try Data("{\"id\":\"victim\",\"title\":\"\(marker)\"}".utf8).write(to: victim)
        let callID = "batch2l-unsafe-\(native)"
        let provider = Batch2LProvider(responses: [
            try batch2LToolCall(native: native, id: callID,
                input: ["session_id": "../victim", "scope": "messages"]),
            LLMResponse(text: "BATCH2L_FINAL", stopReason: "stop", usage: nil),
        ])
        _ = try await harness.send("看看别的会话", provider: provider, allow: true)

        #expect(provider.requests.count == 2)
        let followUp = try #require(provider.requests.dropFirst().first)
        let body = try #require(batch2LToolResultBody(followUp, native: native, callID: callID))
        #expect(body.contains(ToolExecutorError.invalidParameter("session_id").localizedDescription))
        #expect(!body.contains(marker))
        #expect(provider.toolOutputs.isEmpty)
    }
}
