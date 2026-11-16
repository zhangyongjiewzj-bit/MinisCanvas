import Foundation
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

// Registers only the existing public callback seam. Default App composition
// does not register a hook; these consumers do not claim otherwise.
@Suite("Registered hook through the App tool consumer", .serialized)
@MainActor
struct HookRegisteredAppConsumer704Tests {
    private struct Fixture {
        let root: URL
        let input: ComposerToolInput
        let snapshot: ComposerSubmissionSnapshot
        let facts: ComposerPolicyFactSource
        let identity: AgentExecutionIdentity
        let registered: ComposerPolicyEnforcedToolExecutor
        let policy: PolicyEnforcedToolExecutor
        let ledger: ToolExecutionFactLedger
        let engine: AgentLoopChatEngine
        let provider: Hook704Provider
        let hook: Hook704Handler
    }

    private func fixture(mode: Hook704Handler.Mode, root: URL? = nil,
                         frozen: ComposerSubmissionSnapshot? = nil) throws -> Fixture {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = root ?? formal.temporaryDirectory.appendingPathComponent("hook704-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("owned.txt")
        if !FileManager.default.fileExists(atPath: file.path) {
            try "owned-hook704-content".write(to: file, atomically: true, encoding: .utf8)
        }
        let stamp = Date()
        let snapshot = frozen ?? ComposerSubmissionSnapshot(
            mode: .auto, approvalScope: .request, effort: .standard,
            sessionID: "hook704-session", turnID: 1, taskID: "hook704-task",
            attemptID: "hook704-attempt", messageID: "hook704-message",
            workspaceID: root.path, createdAt: stamp, policyRevision: "hook704-revision",
            grantEpoch: "hook704-epoch", autonomyCeiling: .l3)
        let facts = ComposerPolicyFactSource(
            knownCapabilities: ["file_read"], grantedCapabilities: ["file_read"],
            allowedWriteRoots: [root.path], workspaceID: snapshot.workspaceID,
            revision: snapshot.policyRevision, grantEpoch: snapshot.grantEpoch,
            leaseID: "hook704-lease", expiresAt: snapshot.createdAt.addingTimeInterval(600),
            autonomyCeiling: .l3)
        let goal = GoalEnvelope(scopeID: root.path, allowedCapabilities: ["file_read"],
            fileRoots: [root.path], networkDomains: [], budget: 16,
            deadline: snapshot.createdAt.addingTimeInterval(600), concurrencyLimit: 1,
            autonomyLevel: .l3, creatorID: "owned-hook704", createdAt: snapshot.createdAt)
        let lease = AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID,
            issuedAt: snapshot.createdAt, expiresAt: goal.deadline)
        let policy = PolicyEnforcedToolExecutor(base: BuiltinToolExecutor(allowedRoot: root),
            goal: goal, lease: lease)
        let hook = Hook704Handler(mode: mode)
        let registered = ComposerPolicyEnforcedToolExecutor(base: policy,
            controller: ComposerAuthorizationController(snapshot: snapshot, facts: facts),
            hookHandler: { invocation in try await hook.invoke(invocation) })
        let ledger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent(UUID().uuidString + "-facts.json"))
        let engine = AgentLoopChatEngine(toolExecutor: registered, maxIterations: 3,
            executionTimeout: 10, approvalGate: ApprovalGate(), toolExecutionFactLedger: ledger,
            composerPolicyFacts: facts)
        let input = try ComposerToolInput(["path": file.path])
        let provider = Hook704Provider(path: file.path)
        let turn = AgentTurnIdentity(sessionID: snapshot.sessionID, turnID: snapshot.turnID,
            messageID: snapshot.messageID)
        return Fixture(root: root, input: input, snapshot: snapshot, facts: facts,
            identity: AgentExecutionIdentity(turn: turn,
                operationID: "chat:\(turn.sessionID):\(turn.turnID):\(turn.messageID)", attempt: 1),
            registered: registered, policy: policy, ledger: ledger,
            engine: engine, provider: provider, hook: hook)
    }

    private func consume(_ f: Fixture) async throws {
        let stream = try await f.engine.streamReply(provider: f.provider,
            history: [ChatMessageUI(role: .user, content: "Read this owned synthetic note")],
            systemPrompt: "Use one file_read, then finish", maxTokens: 128,
            conversationID: f.snapshot.sessionID, authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil, turnID: f.snapshot.turnID,
            composerSnapshot: f.snapshot, executionIdentity: f.identity,
            turnRuntimeSnapshot: ChatTurnRuntimeSnapshot(turn: f.identity.turn,
                skillInjector: SkillInjector(store: SkillStore(skillsRoot: f.root.appendingPathComponent("skills"))).snapshotForTurn(),
                mcpBridge: nil))
        for try await _ in stream {}
    }

    private func assertInvocation(_ invocation: ComposerHookInvocation, fixture f: Fixture) {
        #expect(invocation.callID == Hook704Provider.callID)
        #expect(invocation.capability == "file_read")
        #expect(invocation.input == f.input)
        #expect(!invocation.identityDigest.isEmpty)
        #expect(invocation.identityDigest != "invalid")
    }

    @Test("original model call identity survives registration, await, App dispatch and deterministic replay")
    func registeredHandlerPreservesModelCallAndReplay() async throws {
        let first = try fixture(mode: .allow)
        try await consume(first)
        let calls = await first.hook.invocations
        #expect(calls.count == 1)
        let invocation = try #require(calls.first)
        assertInvocation(invocation, fixture: first)
        #expect(first.policy.acceptedExecutionCount == 1)
        #expect(first.policy.deniedExecutionCount == 0)
        let firstFact = try #require(first.ledger.facts.first)
        #expect(first.ledger.facts.count == 1)
        #expect(firstFact.toolCallID == Hook704Provider.callID)
        #expect(firstFact.executionIdentity == first.identity)
        #expect(firstFact.status == .succeeded)
        #expect(firstFact.failureCategory == nil)
        #expect(firstFact.outputSummary != nil)
        #expect(first.provider.requests.count == 2)
        #expect(first.provider.requests.last?.contains(where: { $0.role == .tool && $0.content.contains("owned-hook704-content") }) == true)

        let replay = try fixture(mode: .allow, root: first.root, frozen: first.snapshot)
        try await consume(replay)
        let replayCalls = await replay.hook.invocations
        #expect(replayCalls.count == 1)
        let replayInvocation = try #require(replayCalls.first)
        assertInvocation(replayInvocation, fixture: replay)
        #expect(replayInvocation.identityDigest == invocation.identityDigest)
        #expect(replay.policy.acceptedExecutionCount == 1)
        let replayFact = try #require(replay.ledger.facts.first)
        #expect(replay.ledger.facts.count == 1)
        #expect(replayFact.toolCallID == firstFact.toolCallID)
        #expect(replayFact.executionIdentity == firstFact.executionIdentity)
        #expect(replayFact.status == firstFact.status)
        #expect(replayFact.outputSummary == firstFact.outputSummary)
        #expect(replayFact.failureCategory == firstFact.failureCategory)
        #expect(replay.provider.requests.last?.last?.content == first.provider.requests.last?.last?.content)
    }

    @Test("registered deny and foreign result cannot be reopened by later allow layers", arguments: [Hook704Handler.Mode.deny, .foreignIdentity])
    fileprivate func registeredResultDeniesActualEffect(mode: Hook704Handler.Mode) async throws {
        let f = try fixture(mode: mode)
        try await consume(f)
        let invocations = await f.hook.invocations
        #expect(invocations.count == 1)
        let invocation = try #require(invocations.first)
        assertInvocation(invocation, fixture: f)
        #expect(f.policy.acceptedExecutionCount == 0)
        #expect(f.policy.deniedExecutionCount == 0)
        #expect(f.ledger.facts.count == 1)
        let fact = try #require(f.ledger.facts.first)
        #expect(fact.toolCallID == Hook704Provider.callID)
        #expect(fact.executionIdentity == f.identity)
        #expect(fact.status == .failed)
        #expect(fact.outputSummary == nil)
        let reason: HookDecisionReason = mode == .deny ? .hookDeny : .hookHandlerIdentityMismatch
        #expect(f.provider.requests.count == 2)
        let result = try #require(f.provider.requests.last?.last)
        #expect(result.role == .tool)
        #expect(result.toolCallID == Hook704Provider.callID)
        let expected = mode == .deny
            ? ComposerAuthorizationError.hookRejected("Hook 阻止本次工具调用").localizedDescription
            : ComposerAuthorizationError.hookDecisionDenied(reason).localizedDescription
        #expect(result.content == "Error executing tool file_read: " + expected)
    }

    fileprivate enum ReceiptMismatch: CaseIterable, Sendable {
        case toolName, session, turn, message, attemptID, attemptNumber, operation, callID
    }

    @Test("a foreign current receipt cannot fall back to direct or reach the hook or primitive",
          arguments: ReceiptMismatch.allCases)
    fileprivate func mismatchedReceiptRejectsBeforeEffect(_ mismatch: ReceiptMismatch) async throws {
        let f = try fixture(mode: .allow)
        let identity = AgentExecutionIdentity(turn: AgentTurnIdentity(
            sessionID: mismatch == .session ? "foreign-session" : f.identity.turn.sessionID,
            turnID: mismatch == .turn ? f.identity.turn.turnID + 1 : f.identity.turn.turnID,
            messageID: mismatch == .message ? "foreign-message" : f.identity.turn.messageID),
            operationID: f.identity.operationID,
            attempt: mismatch == .attemptNumber ? 2 : f.identity.attempt)
        let minted = try f.ledger.mint(toolCallID: Hook704Provider.callID,
            toolName: mismatch == .toolName ? "file_write" : "file_read",
            attemptID: mismatch == .attemptID ? "foreign-attempt" : f.snapshot.attemptID,
            attemptNumber: identity.attempt, executionIdentity: identity)
        let key: ToolExecutionCompositeKey = try #require(minted.compositeKey)
        let receipt = ToolExecutionReceipt(toolCallID: minted.toolCallID,
            receiptID: minted.receiptID, toolName: minted.toolName,
            attemptID: minted.attemptID,
            attemptNumber: mismatch == .attemptNumber ? f.identity.attempt : minted.attemptNumber,
            executionIdentity: minted.executionIdentity,
            compositeKey: ToolExecutionCompositeKey(sessionID: key.sessionID, turnID: key.turnID,
                messageID: key.messageID,
                operationID: mismatch == .operation ? "foreign-operation" : key.operationID,
                attemptID: key.attemptID, attemptNumber: key.attemptNumber,
                toolCallID: mismatch == .callID ? "foreign-call" : key.toolCallID))
        await #expect(throws: ComposerAuthorizationError.authorizationBindingMismatch) {
            try await ToolExecutionReceiptContext.$current.withValue(receipt) {
                try await f.registered.execute(name: "file_read",
                    input: ["path": f.root.appendingPathComponent("owned.txt").path])
            }
        }
        #expect(await f.hook.invocations.isEmpty)
        #expect(f.policy.acceptedExecutionCount == 0)
        #expect(f.policy.deniedExecutionCount == 0)
        #expect(f.ledger.facts.isEmpty)
        #expect(f.provider.requests.isEmpty)
    }

    @Test("an unbound legacy direct call retains its original call identity")
    func receiptFreeDirectCallRemainsCompatible() async throws {
        let f = try fixture(mode: .allow)
        let output = try await ToolExecutionReceiptContext.$current.withValue(nil) {
            try await f.registered.execute(name: "file_read",
                input: ["path": f.root.appendingPathComponent("owned.txt").path])
        }
        #expect(output.contains("owned-hook704-content"))
        let calls = await f.hook.invocations
        #expect(calls.count == 1)
        let invocation: ComposerHookInvocation = try #require(calls.first)
        #expect(invocation.callID == "direct")
        #expect(invocation.input == f.input)
        #expect(f.policy.acceptedExecutionCount == 1)
        #expect(f.policy.deniedExecutionCount == 0)
        #expect(f.ledger.facts.isEmpty)
        #expect(f.provider.requests.isEmpty)
    }

    @Test("real parent stop while handler awaits stays denied after its late allow result")
    func stoppedAwaitCannotDispatchLateAllow() async throws {
        let f = try fixture(mode: .awaitAllow)
        let operation = Task { try await consume(f) }
        defer { Task { await f.hook.release() } }
        var reached = false
        for _ in 0..<1000 {
            if await f.hook.waiting { reached = true; break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        try #require(reached)
        let handle: TurnController.TurnHandle = try #require(await f.hook.parentHandle)
        #expect(await handle.isActive())
        await handle.interrupt()
        #expect(await handle.isCancelled())
        await f.hook.release()
        await #expect(throws: InterruptedError.self) { try await operation.value }
        let invocations = await f.hook.invocations
        #expect(invocations.count == 1)
        let invocation = try #require(invocations.first)
        assertInvocation(invocation, fixture: f)
        #expect(f.policy.acceptedExecutionCount == 0)
        #expect(f.policy.deniedExecutionCount == 0)
        #expect(f.ledger.facts.count == 1)
        let fact = try #require(f.ledger.facts.first)
        #expect(fact.toolCallID == Hook704Provider.callID)
        #expect(fact.executionIdentity == f.identity)
        #expect(fact.status == .cancelled)
        #expect(fact.outputSummary == nil)
        #expect(f.provider.requests.count == 1)
    }
}

private actor Hook704Handler {
    enum Mode: Sendable { case allow, deny, foreignIdentity, awaitAllow }
    let mode: Mode
    private(set) var invocations: [ComposerHookInvocation] = []
    private(set) var parentHandle: TurnController.TurnHandle?
    private(set) var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    init(mode: Mode) { self.mode = mode }
    func invoke(_ invocation: ComposerHookInvocation) async throws -> ComposerHookResult {
        invocations.append(invocation)
        parentHandle = AgentExecutionContext.current?.parentTurnHandle
        if mode == .awaitAllow {
            waiting = true
            if !released { await withCheckedContinuation { continuation = $0 } }
        }
        return ComposerHookResult(verdict: mode == .deny ? .deny : .allow,
            invocationIdentityDigest: mode == .foreignIdentity ? "foreign:" + invocation.identityDigest : invocation.identityDigest)
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

private final class Hook704Provider: LLMProvider, @unchecked Sendable {
    static let callID = "model-hook704-call"
    let name = "owned-hook704-provider"
    var model = LLMModel(id: "hook704-model", displayName: "Owned Hook704", provider: "synthetic", contextWindow: 8192, maxOutputTokens: 512)
    let capabilities: Set<ProviderCapability> = [.tools]
    let path: String
    private let lock = NSLock()
    private var history: [[LLMMessage]] = []
    var requests: [[LLMMessage]] { lock.withLock { history } }
    init(path: String) { self.path = path }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try respond(messages)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition], maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try respond(messages)
    }
    private func respond(_ messages: [LLMMessage]) throws -> LLMResponse {
        let index = lock.withLock { history.append(messages); return history.count }
        if index == 1 {
            return LLMResponse(text: "", stopReason: "tool_calls", usage: nil, toolCalls: [
                LLMToolCall(id: Self.callID, name: "file_read", rawArguments: String(decoding: try JSONSerialization.data(withJSONObject: ["path": path], options: [.sortedKeys]), as: UTF8.self), arguments: ["path": path])
            ])
        }
        return LLMResponse(text: "done", stopReason: "stop", usage: nil)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish(throwing: Hook704UnexpectedStream()) }
    }
}
private struct Hook704UnexpectedStream: Error {}
