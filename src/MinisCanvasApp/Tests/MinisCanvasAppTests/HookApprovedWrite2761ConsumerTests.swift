import Foundation
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

private actor Hook2761Approval: ApprovalDelegate {
    private(set) var requests: [ApprovalRequest] = []

    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        requests.append(request)
        return ApprovalDecision(approved: true, confirmed: true,
            requestID: request.requestID, bindingDigest: request.identityDigest)
    }
}

private actor Hook2761Handler {
    enum Mode { case allow, awaitAllow }
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
        return ComposerHookResult(verdict: .allow,
            invocationIdentityDigest: invocation.identityDigest)
    }

    func release() { released = true; continuation?.resume(); continuation = nil }
}

private final class Hook2761Provider: LLMProvider, @unchecked Sendable {
    static let callID = "model-hook2761-write"
    let name = "hook2761-synthetic"
    var model = LLMModel(id: "hook2761", displayName: "Synthetic", provider: "synthetic")
    let capabilities: Set<ProviderCapability> = [.tools]
    let path: String
    private let lock = NSLock()
    private var recorded: [[LLMMessage]] = []
    var requests: [[LLMMessage]] { lock.withLock { recorded } }

    init(path: String) { self.path = path }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        try reply(messages)
    }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try reply(messages)
    }

    private func reply(_ messages: [LLMMessage]) throws -> LLMResponse {
        let count = lock.withLock { recorded.append(messages); return recorded.count }
        guard count == 1 else {
            return LLMResponse(text: "合成写入回合结束", stopReason: "stop", usage: nil)
        }
        let input: [String: Any] = ["path": path, "content": "owned-hook2761-body"]
        let arguments = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
        return LLMResponse(text: "", stopReason: "tool_calls", usage: nil, toolCalls: [
            LLMToolCall(id: Self.callID, name: "file_write",
                rawArguments: String(decoding: arguments, as: UTF8.self), arguments: input)
        ])
    }

    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        Issue.record("Hook2761 fixture unexpectedly streamed")
        return AsyncThrowingStream { $0.finish() }
    }
}

@Suite("D-HOOK2 registered callback through approved App write", .serialized)
@MainActor
struct HookApprovedWrite2761ConsumerTests {
    private struct Fixture {
        let file: URL
        let snapshot: ComposerSubmissionSnapshot
        let identity: AgentExecutionIdentity
        let engine: AgentLoopChatEngine
        let provider: Hook2761Provider
        let approval: Hook2761Approval
        let hook: Hook2761Handler
        let policy: PolicyEnforcedToolExecutor
        let ledger: ToolExecutionFactLedger
        let root: URL
        let runtime: HookRuntime?
    }

    private func fixture(mode: Hook2761Handler.Mode, realPreToolFailure: String? = nil,
                         deniedPolicyFileRoots: Bool = false) throws -> Fixture {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.temporaryDirectory.appendingPathComponent("hook2761-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let file = root.appendingPathComponent("approved.txt")
        if deniedPolicyFileRoots { try Data("owned-denied-root-original".utf8).write(to: file) }
        let stamp = Date()
        let snapshot = ComposerSubmissionSnapshot(
            mode: .manual, approvalScope: .request, effort: .standard,
            sessionID: "hook2761-session", turnID: 1, taskID: "hook2761-task",
            attemptID: "hook2761-attempt", messageID: "hook2761-message",
            workspaceID: root.path, createdAt: stamp, policyRevision: "hook2761-revision",
            grantEpoch: "hook2761-epoch", autonomyCeiling: .l3)
        let facts = ComposerPolicyFactSource(
            knownCapabilities: ["file_write"], grantedCapabilities: ["file_write"],
            allowedWriteRoots: [root.path], workspaceID: snapshot.workspaceID,
            revision: snapshot.policyRevision, grantEpoch: snapshot.grantEpoch,
            leaseID: "hook2761-lease", expiresAt: stamp.addingTimeInterval(600),
            autonomyCeiling: .l3)
        let goal = GoalEnvelope(scopeID: root.path, allowedCapabilities: ["file_write"],
            fileRoots: deniedPolicyFileRoots ? [] : [root.path], networkDomains: [], budget: 16,
            deadline: stamp.addingTimeInterval(600), concurrencyLimit: 1,
            autonomyLevel: .l3, creatorID: "owned-hook2761", createdAt: stamp)
        let lease = AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID,
            issuedAt: stamp, expiresAt: goal.deadline)
        let policy = PolicyEnforcedToolExecutor(
            base: BuiltinToolExecutor(allowedRoot: root, deniedRoots: []), goal: goal, lease: lease)
        let approval = Hook2761Approval()
        let gate = ApprovalGate(policyByTool: ["file_write": .alwaysAsk], delegate: approval)
        let hook = Hook2761Handler(mode: mode)
        var runtime: HookRuntime?
        if let realPreToolFailure {
            let config = root.appendingPathComponent(HookConfigStore.projectRelativePath)
            let scripts = config.deletingLastPathComponent().appendingPathComponent("hooks")
            try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let script = scripts.appendingPathComponent("pre.sh")
            let body = realPreToolFailure == "timeout"
                ? "#!/bin/sh\n/bin/sleep 2\nprintf '%s\\n' '{\"decision\":\"approve\"}'\n"
                : "#!/bin/sh\nprintf '%s\\n' '{\"decision\":\"approve\"}'\n"
            let scriptBody: String
            if realPreToolFailure == "exit-two" {
                scriptBody = "#!/bin/sh\nprintf '%s\\n' 'HOOK2761_EXIT2_BLOCK' >&2\nexit 2\n"
            } else if realPreToolFailure == "ordinary-nonzero" {
                scriptBody = "#!/bin/sh\nexit 3\n"
            } else { scriptBody = body }
            try Data(scriptBody.utf8).write(to: script)
            let definition = HookDefinition(id: "owned-real-pre", event: .preToolUse,
                matcher: "file_write", command: "/bin/sh '\(script.path)'", timeoutSeconds: 0.1)
            try JSONEncoder().encode(HookConfigurationFile(hooks: [definition])).write(to: config)
            let store = HookConfigStore(directory: root.appendingPathComponent("hook-settings"))
            let hash = try #require(store.projectSnapshot(projectRoot: root).contentHash)
            try store.trustProjectHooks(projectRoot: root, expectedHash: hash)
            #expect(store.projectSnapshot(projectRoot: root).trust == .trusted)
            if realPreToolFailure == "changed-script" {
                try Data((body + "# owned change after review\n").utf8).write(to: script)
                #expect(store.projectSnapshot(projectRoot: root).needsTrustDecision)
            }
            runtime = HookRuntime(store: store, environment: {
                if realPreToolFailure == "environment" {
                    throw NSError(domain: "owned-hook-environment", code: 1)
                }
                return [:]
            })
        }
        let realRuntime = runtime
        let registered = ComposerPolicyEnforcedToolExecutor(base: policy,
            controller: ComposerAuthorizationController(snapshot: snapshot, facts: facts),
            approvalGate: gate, hookHandler: { invocation in
                if let realRuntime { return try await realRuntime.preToolUse(invocation) }
                return try await hook.invoke(invocation)
            })
        let ledger = try ToolExecutionFactLedger(
            persistenceURL: root.appendingPathComponent("facts.json"))
        let engine = AgentLoopChatEngine(toolExecutor: registered, maxIterations: 3,
            executionTimeout: 10, approvalGate: gate,
            toolExecutionFactLedger: ledger, composerPolicyFacts: facts)
        let turn = AgentTurnIdentity(sessionID: snapshot.sessionID, turnID: snapshot.turnID,
            messageID: snapshot.messageID)
        return Fixture(file: file, snapshot: snapshot,
            identity: AgentExecutionIdentity(turn: turn,
                operationID: "chat:\(turn.sessionID):\(turn.turnID):\(turn.messageID)", attempt: 1),
            engine: engine, provider: Hook2761Provider(path: file.path), approval: approval,
            hook: hook, policy: policy, ledger: ledger, root: root, runtime: runtime)
    }

    private func consume(_ f: Fixture) async throws {
        let stream = try await f.engine.streamReply(provider: f.provider,
            history: [ChatMessageUI(role: .user, content: "Write the owned synthetic note")],
            systemPrompt: "Use one file_write, then finish", maxTokens: 128,
            conversationID: f.snapshot.sessionID, authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil, turnID: f.snapshot.turnID,
            composerSnapshot: f.snapshot, executionIdentity: f.identity,
            turnRuntimeSnapshot: ChatTurnRuntimeSnapshot(turn: f.identity.turn,
                skillInjector: SkillInjector(store: SkillStore(
                    skillsRoot: f.root.appendingPathComponent("skills"))).snapshotForTurn(),
                mcpBridge: nil))
        for try await _ in stream {}
    }

    @Test("real PreToolUse timeout or changed trusted script cannot be rescued by approval",
          arguments: ["timeout", "changed-script", "environment"])
    func realPreToolFailureDeniesApprovedWrite(failure: String) async throws {
        let f = try fixture(mode: .allow, realPreToolFailure: failure)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let runtime = try #require(f.runtime)
        _ = await runtime.beginTurn(sessionID: f.snapshot.sessionID,
            prompt: "owned real hook write", projectRoot: f.root)
        try await consume(f)
        // The existing delegate really approves. Its approval is not evidence
        // that a failed or no-longer-trusted PreToolUse check may be skipped.
        #expect(await f.approval.requests.count >= 1)
        #expect(f.policy.acceptedExecutionCount == 0)
        #expect(!FileManager.default.fileExists(atPath: f.file.path))
        if failure == "timeout" {
            #expect(runtime.recentRuns().contains { $0.event == .preToolUse && $0.status == .timedOut })
        } else if failure == "environment" {
            #expect(runtime.store.projectSnapshot(projectRoot: f.root).trust == .trusted)
            let record = try #require(runtime.recentRuns().first)
            #expect(record.event == .preToolUse && record.status == .launchFailed)
            #expect(record.decision == "deny")
            #expect(record.summary == "PreToolUse 启动失败，本次工具调用已拒绝")
            #expect(f.ledger.facts.allSatisfy { $0.executionIdentity == f.identity })
        } else {
            #expect(runtime.store.projectSnapshot(projectRoot: f.root).needsTrustDecision)
            #expect(runtime.recentRuns().count == 1)
            #expect(runtime.recentRuns().first?.decision == "deny")
            #expect(runtime.recentRuns().first?.summary.contains("重新查看并信任") == true)
        }
    }

    @Test("trusted real PreToolUse exit two blocks an actually approved write and returns the error")
    func realTrustedExitTwoDeniesApprovedWriteAndReturnsReason() async throws {
        let f = try fixture(mode: .allow, realPreToolFailure: "exit-two")
        defer { try? FileManager.default.removeItem(at: f.root) }
        let runtime = try #require(f.runtime)
        _ = await runtime.beginTurn(sessionID: f.snapshot.sessionID,
            prompt: "owned exit-two hook", projectRoot: f.root)
        try await consume(f)
        #expect(await f.hook.invocations.isEmpty)
        #expect(runtime.store.projectSnapshot(projectRoot: f.root).trust == .trusted)
        #expect(await f.approval.requests.count >= 1)
        #expect(f.policy.acceptedExecutionCount == 0)
        #expect(!FileManager.default.fileExists(atPath: f.file.path))
        let runs = runtime.recentRuns()
        try #require(runs.count == 1)
        #expect(runs[0].event == .preToolUse && runs[0].status == .nonZeroExit)
        #expect(runs[0].exitCode == 2 && runs[0].decision == "deny")
        #expect(runs[0].summary == "HOOK2761_EXIT2_BLOCK")
        // The actual App engine adds an outer turn Composer before the
        // registered hook wrapper. Its receipt is minted before the inner
        // PreToolUse denial, then settled failed without reaching Policy/Builtin.
        // The original empty-ledger expectation failed in the actual 8-case
        // run; denial never required an empty audit ledger. Keep effect guards
        // above and verify the exact canonical failed attempt instead.
        let failedFacts = f.ledger.facts
        try #require(failedFacts.count == 1)
        let failedFact = try #require(failedFacts.first)
        #expect(failedFact.status == .failed)
        #expect(failedFact.toolCallID == Hook2761Provider.callID && failedFact.toolName == "file_write")
        #expect(failedFact.executionIdentity == f.identity)
        let key = try #require(failedFact.compositeKey)
        #expect(key.isValid && key.sessionID == f.identity.turn.sessionID)
        #expect(key.turnID == f.identity.turn.turnID && key.messageID == f.identity.turn.messageID)
        #expect(key.operationID == f.identity.operationID && key.toolCallID == Hook2761Provider.callID)
        let expectedAttempt = AgentToolExecutionAttemptID.canonical(
            executionIdentity: f.identity, composerSnapshot: f.snapshot, childBoundary: nil)
        #expect(failedFact.attemptID == expectedAttempt && failedFact.attemptNumber == f.identity.attempt)
        #expect(key.attemptID == expectedAttempt && key.attemptNumber == f.identity.attempt)
        #expect(f.ledger.fact(compositeKey: key, receiptID: failedFact.receiptID) == failedFact)
        #expect(f.ledger.pendingReceipts.isEmpty)
        try #require(f.provider.requests.count == 2)
        let returned = f.provider.requests[1].flatMap { message -> [String] in
            if message.role == .tool && message.toolCallID == Hook2761Provider.callID { return [message.content] }
            return message.toAgentContentParts().compactMap { part in
                guard case .toolResult(let id, _, let body, let isError, _, _, _, _) = part,
                      id == Hook2761Provider.callID, isError else { return nil }
                return body
            }
        }
        #expect(returned.contains { $0.contains("HOOK2761_EXIT2_BLOCK") })
        #expect(!returned.contains { $0.contains("owned-hook2761-body") })
    }

    @Test("trusted real PreToolUse allow cannot override the actual policy file-root boundary")
    func realTrustedAllowCannotBypassPolicyFileRootBoundary() async throws {
        let f = try fixture(mode: .allow, realPreToolFailure: "allow", deniedPolicyFileRoots: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let original = try Data(contentsOf: f.file)
        let runtime = try #require(f.runtime)
        _ = await runtime.beginTurn(sessionID: f.snapshot.sessionID,
            prompt: "owned allow below denied-root floor", projectRoot: f.root)
        try await consume(f)
        #expect(await f.hook.invocations.isEmpty)
        #expect(runtime.store.projectSnapshot(projectRoot: f.root).trust == .trusted)
        #expect(await f.approval.requests.count >= 1)
        let runs = runtime.recentRuns()
        try #require(runs.count == 1)
        #expect(runs[0].event == .preToolUse && runs[0].status == .completed)
        #expect(runs[0].exitCode == 0 && runs[0].decision == "allow")
        // Physical preflight stays valid. The real lower Policy then rejects
        // the path after the trusted hook and human approval have both run.
        #expect(f.policy.acceptedExecutionCount == 0 && f.policy.deniedExecutionCount == 1)
        #expect(try Data(contentsOf: f.file) == original)
        let fact = try #require(f.ledger.facts.first)
        #expect(f.ledger.facts.count == 1 && f.ledger.pendingReceipts.isEmpty)
        #expect(fact.toolCallID == Hook2761Provider.callID && fact.executionIdentity == f.identity)
        #expect(fact.status == .failed)
        try #require(f.provider.requests.count == 2)
        let returned = f.provider.requests[1].flatMap { message -> [String] in
            if message.role == .tool && message.toolCallID == Hook2761Provider.callID { return [message.content] }
            return message.toAgentContentParts().compactMap { part in
                guard case .toolResult(let id, _, let body, let isError, _, _, _, _) = part,
                      id == Hook2761Provider.callID, isError else { return nil }
                return body
            }
        }
        #expect(returned.contains { $0.contains(PolicyEnforcedToolExecutorError.policyViolation(.fileRootNotAllowed).localizedDescription) })
        #expect(!returned.contains { $0.contains("Policy violation") || $0.contains("fileRootNotAllowed") })
        #expect(!returned.contains { $0.contains("owned-hook2761-body") })
    }

    @Test("ordinary nonzero PreToolUse exit remains neutral after real approval")
    func realOrdinaryNonzeroExitDoesNotBecomeADenial() async throws {
        let f = try fixture(mode: .allow, realPreToolFailure: "ordinary-nonzero")
        defer { try? FileManager.default.removeItem(at: f.root) }
        let runtime = try #require(f.runtime)
        _ = await runtime.beginTurn(sessionID: f.snapshot.sessionID,
            prompt: "owned ordinary nonzero hook", projectRoot: f.root)
        try await consume(f)
        #expect(await f.approval.requests.count >= 1)
        #expect(f.policy.acceptedExecutionCount == 1)
        #expect(try String(contentsOf: f.file, encoding: .utf8) == "owned-hook2761-body")
        #expect(runtime.recentRuns().first?.exitCode == 3)
        #expect(runtime.recentRuns().first?.decision == nil)
    }

    @Test("approved registered callback reaches one owned write")
    func approvedAllowReachesBuiltin() async throws {
        let f = try fixture(mode: .allow)
        try await consume(f)
        #expect(await f.approval.requests.count >= 1)
        #expect(await f.approval.requests.allSatisfy { $0.toolName == "file_write" })
        let invocations = await f.hook.invocations
        #expect(invocations.count == 1)
        #expect(invocations.first?.callID == Hook2761Provider.callID)
        #expect(f.policy.acceptedExecutionCount == 1)
        #expect(try String(contentsOf: f.file, encoding: .utf8) == "owned-hook2761-body")
        let fact = try #require(f.ledger.facts.first)
        #expect(fact.toolCallID == Hook2761Provider.callID)
        #expect(fact.executionIdentity == f.identity)
        #expect(fact.status == .succeeded)
    }

    @Test("parent stop while approved callback awaits cannot be reopened by late allow")
    func approvedAwaitStopDeniesLateAllowWithoutFileEffect() async throws {
        let f = try fixture(mode: .awaitAllow)
        let operation = Task { try await consume(f) }
        defer { Task { await f.hook.release() } }
        var reached = false
        for _ in 0..<1_000 {
            if await f.hook.waiting { reached = true; break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        try #require(reached)
        #expect(await f.approval.requests.count >= 1)
        let handle: TurnController.TurnHandle = try #require(await f.hook.parentHandle)
        await handle.interrupt()
        #expect(await handle.isCancelled())
        await f.hook.release()
        await #expect(throws: InterruptedError.self) { try await operation.value }
        #expect(await f.hook.invocations.count == 1)
        #expect(f.policy.acceptedExecutionCount == 0)
        #expect(f.policy.deniedExecutionCount == 0)
        #expect(!FileManager.default.fileExists(atPath: f.file.path))
        let fact = try #require(f.ledger.facts.first)
        #expect(fact.toolCallID == Hook2761Provider.callID)
        #expect(fact.executionIdentity == f.identity)
        #expect(fact.status == .cancelled)
        #expect(f.provider.requests.count == 1)
    }
}
