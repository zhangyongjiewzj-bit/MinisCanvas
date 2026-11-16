import Foundation
import Testing
@testable import MinisCore

// MARK: - Mock provider that can return native tool_calls

/// Scripted LLMProvider that returns structured `LLMResponse`s (including native
/// `toolCalls`) and records the tools passed to the tools-aware `sendMessage`.
final class NativeToolMockProvider: LLMProvider {
    var name: String { "NativeMock" }
    var model: LLMModel
    /// Responses consumed in order; the last one repeats if exhausted.
    var responses: [LLMResponse]
    /// Every message history passed to the provider (for round-trip assertions).
    private(set) var receivedHistory: [[LLMMessage]] = []
    /// Every tools array passed to the tools-aware `sendMessage`.
    private(set) var receivedTools: [[AgentToolDefinition]] = []

    init(model: LLMModel = .deepSeekChat, responses: [LLMResponse]) {
        self.model = model
        self.responses = responses
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        receivedHistory.append(messages)
        return responses.isEmpty ? LLMResponse(text: "", stopReason: nil, usage: nil) : responses.removeFirst()
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        receivedHistory.append(messages)
        receivedTools.append(tools)
        return responses.isEmpty ? LLMResponse(text: "", stopReason: nil, usage: nil) : responses.removeFirst()
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

// MARK: - Fixture helper

private struct NativeToolApprovalDelegate: ApprovalDelegate {
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        ApprovalDecision(
            approved: true,
            confirmed: true,
            requestID: request.requestID,
            bindingDigest: request.identityDigest
        )
    }
}

private actor NativeToolRecordingApprovalDelegate: ApprovalDelegate {
    private(set) var requests: [ApprovalRequest] = []

    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        requests.append(request)
        return ApprovalDecision(
            approved: true,
            confirmed: true,
            requestID: request.requestID,
            bindingDigest: request.identityDigest
        )
    }
}

private final class NativeToolFailingExecutor: ToolExecutor, @unchecked Sendable {
    let failure: ToolExecutorError
    private let lock = NSLock()
    private var names: [String] = []
    private var errors: [ToolExecutorError] = []
    var executedNames: [String] { lock.withLock { names } }
    var observedErrors: [ToolExecutorError] { lock.withLock { errors } }

    init(failure: ToolExecutorError) {
        self.failure = failure
    }

    func execute(name: String, input: [String: Any]) async throws -> String {
        lock.withLock {
            names.append(name)
            errors.append(failure)
        }
        throw failure
    }
}

// Observe the existing dispatcher; authorization remains in the real wrappers.
private final class NativeToolDispatchObserver1006: ToolCatalogValidatingExecutor, @unchecked Sendable {
    private let base: BuiltinToolExecutor
    private let lock = NSLock()
    private var names: [String] = []

    init(base: BuiltinToolExecutor) { self.base = base }

    var executedNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return names
    }

    private func record(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        names.append(name)
    }

    func validateToolCatalog(_ tools: [AgentToolDefinition]) throws {
        try base.validateToolCatalog(tools)
    }

    func execute(name: String, input: [String: Any]) async throws -> String {
        record(name)
        return try await base.execute(name: name, input: input)
    }
}

private struct NativeToolFixture {
    let root: URL
    let executor: BuiltinToolExecutor
    let policyRuntime: PolicyRuntimeBinding
    let approvalGate: ApprovalGate
    let ledger: ToolExecutionFactLedger
    let identity: AgentExecutionIdentity

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeToolCallsTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        executor = BuiltinToolExecutor(allowedRoot: root)
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let goal = GoalEnvelope(
            scopeID: "native-tool-calls:test",
            allowedCapabilities: ["file_read", "shell_execute"],
            fileRoots: [root.path],
            budget: 100,
            deadline: now.addingTimeInterval(3_600),
            concurrencyLimit: 1,
            autonomyLevel: .l2,
            creatorID: "NativeToolCallsTests",
            createdAt: now
        )
        let lease = AutonomyLease(
            goalID: goal.goalID,
            scopeID: goal.scopeID,
            issuedAt: now,
            expiresAt: goal.deadline
        )
        policyRuntime = PolicyRuntimeBinding(
            goal: goal,
            lease: lease,
            clock: { now }
        )
        approvalGate = ApprovalGate(delegate: NativeToolApprovalDelegate())
        ledger = try! minisCoreToolContractLedger(at: root)
        identity = minisCoreToolContractIdentity("native-tool-calls")
    }

    func makeLoop(maxIterations: Int = 5) -> AgentLoop {
        var loop = SecureAgentLoopFactory.make(
            maxIterations: maxIterations,
            approvalGate: approvalGate,
            policyRuntime: policyRuntime,
            turnController: TurnController()
        )
        loop.toolExecutionFactLedger = ledger
        return loop
    }
}

// MARK: - Native tool_calls (OpenAI-compatible path)

@Suite("NativeToolCalls")
struct NativeToolCallsTests {

    // MARK: Response parsing

    @Test func parseNativeToolCallsDecodesOpenAIResponse() {
        let message: [String: Any] = [
            "tool_calls": [
                ["id": "call_123", "type": "function", "function": ["name": "shell_execute", "arguments": "{\"command\":\"echo hi\"}"]],
                ["id": "call_456", "type": "function", "function": ["name": "file_read", "arguments": "{\"path\":\"/tmp/x\"}"]],
            ],
        ]
        let calls = OpenAICompatibleProvider.parseNativeToolCalls(from: message)
        #expect(calls.count == 2)
        #expect(calls[0].id == "call_123")
        #expect(calls[0].name == "shell_execute")
        #expect((calls[0].arguments["command"] as? String) == "echo hi")
        #expect(calls[0].rawArguments == "{\"command\":\"echo hi\"}")
        #expect(calls[1].name == "file_read")
        #expect((calls[1].arguments["path"] as? String) == "/tmp/x")
    }

    @Test func parseNativeToolCallsSkipsMissingName() {
        let message: [String: Any] = [
            "tool_calls": [
                ["id": "x", "type": "function", "function": ["arguments": "{}"]],
                ["id": "y", "type": "function", "function": ["name": "ok", "arguments": "{}"]],
            ],
        ]
        let calls = OpenAICompatibleProvider.parseNativeToolCalls(from: message)
        #expect(calls.count == 1)
        #expect(calls[0].name == "ok")
    }

    @Test func parseNativeToolCallsEmptyWhenNoToolCalls() {
        let message: [String: Any] = ["content": "plain reply"]
        #expect(OpenAICompatibleProvider.parseNativeToolCalls(from: message).isEmpty)
    }

    @Test func chatCompletionsResultPopulatesToolCalls() {
        let json: [String: Any] = [
            "choices": [[
                "message": [
                    "content": "calling",
                    "tool_calls": [["id": "c1", "type": "function", "function": ["name": "shell_execute", "arguments": "{\"command\":\"ls\"}"]]],
                ],
                "finish_reason": "tool_calls",
            ]],
            "usage": ["prompt_tokens": 10, "completion_tokens": 5],
        ]
        let response = OpenAICompatibleProvider.parseChatCompletionsResult(json)
        #expect(response.text == "calling")
        #expect(response.toolCalls.count == 1)
        #expect(response.toolCalls[0].name == "shell_execute")
        #expect(response.stopReason == "tool_calls")
    }

    @Test func chatCompletionsResultPlainTextHasNoToolCalls() {
        let json: [String: Any] = [
            "choices": [["message": ["content": "just text"], "finish_reason": "stop"]],
        ]
        let response = OpenAICompatibleProvider.parseChatCompletionsResult(json)
        #expect(response.text == "just text")
        #expect(response.toolCalls.isEmpty)
    }

    // MARK: Request serialization

    @Test func openAIMessageDictSerializesToolRole() {
        let msg = LLMMessage(role: .tool, content: "done", toolCallID: "call_1")
        let dict = OpenAICompatibleProvider.openAIMessageDict(msg)
        #expect(dict["role"] as? String == "tool")
        #expect(dict["tool_call_id"] as? String == "call_1")
        #expect(dict["content"] as? String == "done")
    }

    @Test func openAIMessageDictSerializesToolRoleWithoutImages() {
        // A tool message must NOT be forced into the multi-part content path.
        let msg = LLMMessage(role: .tool, content: "result", toolCallID: "call_9")
        let dict = OpenAICompatibleProvider.openAIMessageDict(msg)
        #expect(dict["content"] as? String == "result")
        #expect(dict["tool_call_id"] as? String == "call_9")
    }

    @Test func openAIMessageDictSerializesAssistantNativeToolCalls() {
        let call = LLMToolCall(id: "call_1", name: "shell_execute", rawArguments: "{\"command\":\"ls\"}", arguments: ["command": "ls"])
        let msg = LLMMessage(role: .assistant, content: "calling", toolCalls: [call])
        let dict = OpenAICompatibleProvider.openAIMessageDict(msg)
        let toolCalls = dict["tool_calls"] as? [[String: Any]]
        #expect(toolCalls?.count == 1)
        let function = toolCalls?[0]["function"] as? [String: Any]
        #expect(function?["name"] as? String == "shell_execute")
        #expect(function?["arguments"] as? String == "{\"command\":\"ls\"}")
        #expect(toolCalls?[0]["id"] as? String == "call_1")
    }

    @Test func openAIToolSchemaDictMatchesOpenAIFunctionFormat() {
        let tools = AgentToolCatalog.makeTools()
        let shell = tools.first { $0.name == "shell_execute" }
        let dict = try! #require(shell).openAIFunctionDict
        #expect(dict["type"] as? String == "function")
        let function = dict["function"] as? [String: Any]
        #expect(function?["name"] as? String == "shell_execute")
        let params = function?["parameters"] as? [String: Any]
        #expect(params?["type"] as? String == "object")
    }

    // MARK: Agent loop integration

    @Test func agentLoopExecutesNativeToolCallsAndFeedsBackToolRole() async throws {
        let fixture = NativeToolFixture()
        let nativeCall = LLMToolCall(
            id: "call_1",
            name: "shell_execute",
            rawArguments: "{\"command\":\"echo native-ok\"}",
            arguments: ["command": "echo native-ok"]
        )
        let mock = NativeToolMockProvider(responses: [
            LLMResponse(text: "calling", stopReason: "tool_calls", usage: nil, toolCalls: [nativeCall]),
            LLMResponse(text: "最终结果", stopReason: nil, usage: nil),
        ])
        let loop = fixture.makeLoop()
        let result = try await loop.run(
            messages: [LLMMessage(role: .user, content: "跑一下")],
            systemPrompt: "test",
            provider: mock,
            toolExecutor: fixture.executor,
            tools: AgentToolCatalog.makeTools(),
            currentConversationID: fixture.identity.turn.sessionID,
            parentIdentitySeed: ParentRuntimeIdentitySeed(
                sessionID: fixture.identity.turn.sessionID,
                conversationID: fixture.identity.turn.sessionID,
                taskID: "task:native-tool-calls",
                actorID: "test"
            ),
            executionIdentity: fixture.identity
        )

        #expect(result.toolCallsExecuted == 1)
        #expect(result.messages.last?.content == "最终结果")

        // The second provider call must include a native tool-role message tagged
        // with the executed tool_call_id.
        let secondCall = mock.receivedHistory[1]
        let toolMsg = secondCall.first { $0.role == .tool }
        #expect(toolMsg != nil)
        #expect(toolMsg?.toolCallID == "call_1")
        #expect(toolMsg?.content.contains("native-ok") == true)

        // The assistant message carries native toolCalls so they survive round-trip.
        let assistantMsg = secondCall.first { $0.role == .assistant && !$0.toolCalls.isEmpty }
        #expect(assistantMsg != nil)
        #expect(assistantMsg?.toolCalls.first?.id == "call_1")

        // The tools-aware sendMessage received the offered tool schemas.
        #expect(!mock.receivedTools.isEmpty)
        #expect(mock.receivedTools[0].contains { $0.name == "shell_execute" })
    }

    @Test func agentLoopFallsBackToTextEnvelopeWithoutNativeCalls() async throws {
        let fixture = NativeToolFixture()
        let mock = NativeToolMockProvider(responses: [
            LLMResponse(
                text: "{\"tool_calls\": [{\"id\": \"c1\", \"name\": \"shell_execute\", \"input\": {\"command\": \"echo text-ok\"}}]}",
                stopReason: nil,
                usage: nil
            ),
            LLMResponse(text: "完成", stopReason: nil, usage: nil),
        ])
        let loop = fixture.makeLoop()
        let result = try await loop.run(
            messages: [LLMMessage(role: .user, content: "test")],
            systemPrompt: "test",
            provider: mock,
            toolExecutor: fixture.executor,
            tools: AgentToolCatalog.makeTools(),
            currentConversationID: fixture.identity.turn.sessionID,
            parentIdentitySeed: ParentRuntimeIdentitySeed(
                sessionID: fixture.identity.turn.sessionID,
                conversationID: fixture.identity.turn.sessionID,
                taskID: "task:native-tool-calls",
                actorID: "test"
            ),
            executionIdentity: fixture.identity
        )

        #expect(result.toolCallsExecuted == 1)
        #expect(result.messages.last?.content == "完成")
        // Fallback path feeds back a user tool_result envelope — no tool role.
        let secondCall = mock.receivedHistory[1]
        #expect(!secondCall.contains { $0.role == .tool })
        #expect(secondCall.contains { $0.role == .user && $0.content.contains("text-ok") })
    }

    @Test func agentLoopNativeToolErrorIsFedBackAsToolRole() async throws {
        let fixture = NativeToolFixture()
        // PolicyRuntime rejects out-of-root paths before the executor. This
        // test isolates native error feedback using an in-scope synthetic path;
        // the Builtin path boundary has separate direct coverage.
        let syntheticPath = fixture.root.appendingPathComponent("synthetic-input.txt").path
        let failure = ToolExecutorError.readFailed("synthetic fixture read failure")
        let executor = NativeToolFailingExecutor(failure: failure)
        let delegate = NativeToolRecordingApprovalDelegate()
        let loop = SecureAgentLoopFactory.make(
            maxIterations: 5,
            approvalGate: ApprovalGate(policyByTool: ["file_read": .alwaysAsk], delegate: delegate),
            policyRuntime: fixture.policyRuntime,
            toolExecutionFactLedger: fixture.ledger,
            turnController: TurnController()
        )
        let nativeCall = LLMToolCall(
            id: "call_2",
            name: "file_read",
            rawArguments: "{\"path\":\"\(syntheticPath)\"}",
            arguments: ["path": syntheticPath]
        )
        let mock = NativeToolMockProvider(responses: [
            LLMResponse(text: "read", stopReason: "tool_calls", usage: nil, toolCalls: [nativeCall]),
            LLMResponse(text: "已收到错误", stopReason: nil, usage: nil),
        ])
        let result = try await loop.run(
            messages: [LLMMessage(role: .user, content: "读文件")],
            systemPrompt: "test",
            provider: mock,
            toolExecutor: executor,
            tools: AgentToolCatalog.makeTools(),
            currentConversationID: fixture.identity.turn.sessionID,
            parentIdentitySeed: ParentRuntimeIdentitySeed(
                sessionID: fixture.identity.turn.sessionID,
                conversationID: fixture.identity.turn.sessionID,
                taskID: "task:native-tool-read-error",
                actorID: "test"
            ),
            executionIdentity: fixture.identity
        )
        #expect(result.toolCallsExecuted == 1)
        #expect(executor.executedNames == ["file_read"])
        #expect(executor.observedErrors == [failure])
        #expect(result.toolExecutionFacts.count == 1)
        #expect(result.toolExecutionFacts.first?.status == .failed)
        let requests = await delegate.requests
        #expect(requests.count == 1)
        #expect(requests.first?.binding != nil)
        let toolMsg = mock.receivedHistory[1].first { $0.role == .tool }
        #expect(toolMsg != nil)
        #expect(toolMsg?.toolCallID == "call_2")
        #expect(toolMsg?.content.contains(failure.localizedDescription) == true)
    }

    /// The same registered file_read and owned file distinguish capability
    /// rejection from a broken catalog, invalid identity or an always-deny reader.
    @Test(arguments: [false, true])
    func agentLoopCallAwareCapabilityDenialAndRealRead1006(knownCapability: Bool) async throws {
        let fixture = NativeToolFixture()
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let file = fixture.root.appendingPathComponent("tool1006.txt")
        let originalBytes = Data("TOOL1006 real owned reader positive\n完整正文".utf8)
        try originalBytes.write(to: file)
        // Preserve the owned root for the raw/readback consumer; never touch
        // a user file or delete the post-run ledger and positive file proof.
        print("TOOL1006 ownedRoot=\(fixture.root.path) knownCapability=\(knownCapability)")
        let observer = NativeToolDispatchObserver1006(base: fixture.executor)
        let snapshot = ComposerSubmissionSnapshot(
            mode: .manual,
            approvalScope: .request,
            effort: .standard,
            sessionID: fixture.identity.turn.sessionID,
            turnID: fixture.identity.turn.turnID,
            taskID: "task:native-tool-calls",
            attemptID: "attempt:tool1006",
            messageID: fixture.identity.turn.messageID,
            workspaceID: "workspace:tool1006",
            createdAt: now,
            policyRevision: "revision:tool1006",
            grantEpoch: "epoch:tool1006",
            autonomyCeiling: .l2
        )
        let facts = ComposerPolicyFactSource(
            knownCapabilities: knownCapability ? ["file_read"] : [],
            // Hold the grant constant so the negative is specifically unknown
            // capability, rather than a missing grant or different path scope.
            grantedCapabilities: ["file_read"],
            allowedWriteRoots: [fixture.root.path],
            workspaceID: snapshot.workspaceID,
            revision: snapshot.policyRevision,
            grantEpoch: snapshot.grantEpoch,
            leaseID: "lease:tool1006",
            expiresAt: now.addingTimeInterval(600),
            autonomyCeiling: .l2
        )
        let executor = ComposerPolicyEnforcedToolExecutor(
            base: fixture.policyRuntime.wrap(observer),
            controller: ComposerAuthorizationController(snapshot: snapshot, facts: facts, now: { now }),
            approvalGate: fixture.approvalGate
        )
        let input: [String: Any] = ["path": file.path]
        let callID = "call:tool1006"
        if !knownCapability {
            // AgentLoop exposes failures as tool feedback. Corroborate its exact
            // typed cause at that same call-aware seam, without public execute.
            await #expect(throws: ComposerAuthorizationError.unknownCapability("file_read")) {
                _ = try await executor.authorizeExecution(callID: callID, name: "file_read", input: input)
            }
            #expect(observer.executedNames.isEmpty)
        }
        let rawArguments = String(decoding: try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]), as: UTF8.self)
        let provider = NativeToolMockProvider(responses: [
            LLMResponse(text: "read", stopReason: "tool_calls", usage: nil, toolCalls: [
                LLMToolCall(id: callID, name: "file_read", rawArguments: rawArguments, arguments: input)
            ]),
            LLMResponse(text: "TOOL1006 final", stopReason: nil, usage: nil)
        ])
        let result = try await fixture.makeLoop().run(
            messages: [LLMMessage(role: .user, content: "Read the owned fixture")],
            systemPrompt: "test",
            provider: provider,
            toolExecutor: executor,
            tools: minisCoreToolContractCatalog(["file_read"]),
            currentConversationID: fixture.identity.turn.sessionID,
            parentIdentitySeed: ParentRuntimeIdentitySeed(
                sessionID: fixture.identity.turn.sessionID,
                conversationID: fixture.identity.turn.sessionID,
                taskID: snapshot.taskID,
                actorID: "test"
            ),
            composerSnapshot: snapshot,
            executionIdentity: fixture.identity
        )
        #expect(provider.receivedHistory.count == 2)
        let feedback = try #require(provider.receivedHistory.last?.first(where: { $0.role == .tool }))
        #expect(feedback.toolCallID == callID)
        #expect(result.messages.contains { $0.role == .tool && $0.toolCallID == callID && $0.content == feedback.content })
        #expect(result.messages.last?.content == "TOOL1006 final")
        let unchangedBytes = try Data(contentsOf: file)
        #expect(unchangedBytes == originalBytes)
        let reopenedLedger = try minisCoreToolContractLedger(at: fixture.root)
        let persistedFacts = reopenedLedger.facts(
            executionIdentity: fixture.identity,
            attemptID: snapshot.attemptID,
            attemptNumber: fixture.identity.attempt
        )
        #expect(persistedFacts == result.toolExecutionFacts)
        if knownCapability {
            #expect(observer.executedNames == ["file_read"])
            #expect(feedback.content == String(decoding: originalBytes, as: UTF8.self))
            #expect(result.toolCallsExecuted == 1)
            #expect(result.toolExecutionFacts.count == 1)
            let fact = try #require(result.toolExecutionFacts.first)
            #expect(fact.status == .succeeded)
            #expect(fact.toolName == "file_read")
            #expect(fact.executionIdentity == fixture.identity)
            #expect(fact.compositeKey == ToolExecutionCompositeKey(
                sessionID: fixture.identity.turn.sessionID,
                turnID: fixture.identity.turn.turnID,
                messageID: fixture.identity.turn.messageID,
                operationID: fixture.identity.operationID,
                attemptID: snapshot.attemptID,
                attemptNumber: fixture.identity.attempt,
                toolCallID: callID
            ))
        } else {
            let error = ComposerAuthorizationError.unknownCapability("file_read")
            #expect(feedback.content == "Error executing tool file_read: \(error.localizedDescription)")
            #expect(observer.executedNames.isEmpty)
            #expect(result.toolCallsExecuted == 0)
            #expect(result.toolExecutionFacts.isEmpty)
        }
    }
}
