import Foundation
import Testing
@testable import MinisCore

// NOTE: This suite runs on the CLT-only toolchain (no Xcode). XCTest.framework
// does not exist there; Swift Testing (`import Testing`) ships with the CLT and
// is the only runnable test framework. Run with the documented flags:
//   swift test -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks \
//              -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks

// MARK: - Mock Provider

/// Scripted LLM provider: returns one canned response per `sendMessage` call.
final class MockLLMProvider: LLMProvider, ProviderRuntimeConfigurationIdentity {
    var name: String { "Mock" }
    var model: LLMModel
    var capabilities: Set<ProviderCapability> { [.tools] }
    var runtimeConfigurationMaterial: String?
    private(set) var capturedParentBinding: ParentContextSnapshotV1?
    /// Responses are consumed in order; the last one repeats if exhausted.
    var responses: [String]
    /// Every message history sent to the provider (for round-trip assertions).
    private(set) var receivedHistory: [[LLMMessage]] = []

    init(
        model: LLMModel = .claudeHaiku45,
        responses: [String],
        runtimeConfigurationMaterial: String? = nil
    ) {
        self.model = model
        self.responses = responses
        self.runtimeConfigurationMaterial = runtimeConfigurationMaterial
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        receivedHistory.append(messages)
        capturedParentBinding = AgentExecutionContext.current?.parentBinding
        let text = responses.isEmpty ? "" : responses.removeFirst()
        return LLMResponse(text: text, stopReason: nil, usage: nil)
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
            continuation.finish()
        }
    }
}

/// Helper: build a tool-call envelope response string.
private func toolCallEnvelope(id: String, name: String, input: [String: Any]) -> String {
    let object: [String: Any] = ["tool_calls": [["id": id, "name": name, "input": input]]]
    let data = try! JSONSerialization.data(withJSONObject: object)
    return String(data: data, encoding: .utf8)!
}

func minisCoreToolContractRoot(_ name: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MinisCoreToolContract-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

func minisCoreToolContractLedger(at root: URL) throws -> ToolExecutionFactLedger {
    try ToolExecutionFactLedger(
        persistenceURL: root.appendingPathComponent("tool-execution-facts-v4.json")
    )
}

func minisCoreToolContractIdentity(
    _ name: String,
    sessionID: String? = nil,
    turnID: Int = 1,
    messageID: String? = nil
) -> AgentExecutionIdentity {
    AgentExecutionIdentity(
        turn: AgentTurnIdentity(
            sessionID: sessionID ?? "session:\(name)",
            turnID: turnID,
            messageID: messageID ?? "message:\(name)"
        ),
        operationID: "operation:\(name)",
        attempt: 1
    )
}

func minisCoreToolContractCatalog(_ names: [String]) -> [AgentToolDefinition] {
    let canonical = AgentToolCatalog.makeTools()
    return names.map { name in
        canonical.first(where: { $0.name == name })
            ?? AgentToolDefinition(
                name: name,
                description: "Explicit test tool contract",
                parameters: [:],
                required: []
            )
    }
}

// MARK: - Fixture

private struct ProjectWorkspaceApproval: ApprovalDelegate {
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        ApprovalDecision(approved: true, confirmed: true, requestID: request.requestID,
            bindingDigest: request.identityDigest, filePreview: request.filePreview)
    }
}

private struct AgentLoopFixture {
    let root: URL
    let executor: BuiltinToolExecutor

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentLoopTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        executor = BuiltinToolExecutor(allowedRoot: root)
    }
}

@concurrent
private func runRouteBoundAgentLoop(
    route: ProviderRuntimeRoute,
    allowedRoot: URL
) async throws {
    _ = try await AgentLoop(maxIterations: 1).run(
        messages: [.init(role: .user, content: "hello")],
        systemPrompt: nil,
        provider: route,
        providerRuntimeRoute: route,
        toolExecutor: BuiltinToolExecutor(allowedRoot: allowedRoot),
        tools: [],
        currentConversationID: "route-session"
    )
}

// MARK: - Agent Loop

struct AgentLoopTests {

    @Test func capturedProjectWorkspaceKeepsTheOriginalTurnsShellDirectory() async throws {
        let root = try minisCoreToolContractRoot("project-cwd").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("project-a", isDirectory: true)
        let b = root.appendingPathComponent("project-b", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let owner = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        let ledger = try minisCoreToolContractLedger(at: root)
        var next = AgentLoop(maxIterations: 2,
            approvalGate: ApprovalGate(delegate: ProjectWorkspaceApproval()),
            turnController: TurnController(), timeout: 30, toolExecutionFactLedger: ledger)
        try next.captureToolWorkspace(directory: a, owner: owner)
        let admittedA = next
        // These are independent conversation turns. AgentLoop is a value,
        // but its detector is a reference: give each turn its own default
        // detector rather than counting A/B/fallback as one looping turn.
        next.loopDetector = ToolLoopDetector()
        try next.captureToolWorkspace(directory: b, owner: owner)
        let admittedB = next
        next.loopDetector = ToolLoopDetector()
        try next.captureToolWorkspace(directory: root, owner: owner, projectScoped: false)
        // A was captured before the user selected B. Run it afterwards: cwd
        // must still be A; B and the no-project fallback have their own copies.
        for (index, pair) in [(admittedA, a), (admittedB, b), (next, root)].enumerated() {
            let provider = MockLLMProvider(responses: [
                toolCallEnvelope(id: "project-pwd-\(index)", name: "shell_execute", input: ["command": "pwd"]),
                "done"])
            let identity = minisCoreToolContractIdentity("project-pwd-\(index)", turnID: index + 1)
            let result = try await pair.0.run(messages: [.init(role: .user, content: "Report cwd")],
                systemPrompt: nil, provider: provider, toolExecutor: owner,
                tools: minisCoreToolContractCatalog(["shell_execute"]),
                currentConversationID: identity.turn.sessionID,
                parentIdentitySeed: ParentRuntimeIdentitySeed(
                    sessionID: identity.turn.sessionID,
                    conversationID: identity.turn.sessionID,
                    taskID: "project-pwd-\(index)", actorID: "test"),
                executionIdentity: identity)
            #expect(result.toolCallsExecuted == 1)
            let feedback = try #require(provider.receivedHistory.last?.last)
            let parts = feedback.toAgentContentParts().compactMap { part -> (content: String, isError: Bool)? in
                if case .toolResult(_, _, let content, let isError, _, _, _, _) = part {
                    return (content, isError)
                }
                return nil
            }
            #expect(parts.count == 1)
            let toolFeedback = try #require(parts.first)
            #expect(!toolFeedback.isError, "actual tool feedback: \(toolFeedback.content)")
            guard !toolFeedback.isError else { continue }
            let shell = try #require(JSONSerialization.jsonObject(with: Data(toolFeedback.content.utf8)) as? [String: Any])
            let stdout = try #require(shell["stdout"] as? String).trimmingCharacters(in: .whitespacesAndNewlines)
            let actualDirectory = try #require(PolicyRuntimePathBoundary.canonicalPath(stdout))
            let expectedDirectory = try #require(PolicyRuntimePathBoundary.canonicalPath(pair.1.path))
            #expect(actualDirectory == expectedDirectory)
        }
        #expect(owner.allowedRoot == root)
        #expect(owner.effectiveWorkingDirectory == root)
    }

    @Test("preflight refusal stays failed when the same call is later approved and retried")
    func preflightRefusedCallCannotBeReauthorizedByRetry() async throws {
        let fixture = AgentLoopFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let identity = minisCoreToolContractIdentity("preflight-retry")
        let ledger = try minisCoreToolContractLedger(at: fixture.root)
        let refused = fixture.root.deletingLastPathComponent().appendingPathComponent("refused-\(UUID()).txt")
        let retry = fixture.root.appendingPathComponent("approved-retry.txt")
        let provider = MockLLMProvider(responses: [
            toolCallEnvelope(id: "same-call", name: "file_write", input: ["path": refused.path, "content": "refused"]),
            toolCallEnvelope(id: "same-call", name: "file_write", input: ["path": retry.path, "content": "later approved"]),
            "finished"
        ])
        let approval = PreflightRetryApproval()
        let loop = AgentLoop(maxIterations: 3, approvalGate: ApprovalGate(delegate: approval),
            turnController: TurnController(), timeout: 30, toolExecutionFactLedger: ledger)
        _ = try await loop.run(messages: [.init(role: .user, content: "write the requested file")],
            systemPrompt: nil, provider: provider, toolExecutor: fixture.executor,
            tools: minisCoreToolContractCatalog(["file_write"]), currentConversationID: identity.turn.sessionID,
            parentIdentitySeed: ParentRuntimeIdentitySeed(sessionID: identity.turn.sessionID,
                conversationID: identity.turn.sessionID, taskID: "preflight-retry", actorID: "test"),
            executionIdentity: identity)
        #expect(ledger.facts.count == 1 && ledger.facts.first?.status == .failed)
        #expect(ledger.pendingReceipts.isEmpty)
        #expect(await approval.count == 1)
        #expect(!FileManager.default.fileExists(atPath: refused.path))
        #expect(!FileManager.default.fileExists(atPath: retry.path))
        #expect(provider.receivedHistory.last?.contains {
            $0.content.contains("[TOOL CALL BLOCKED] duplicate or late tool call identity")
        } == true)
    }

    @Test func toolUseExecutedResultFedBackThenFinalText() async throws {
        let fixture = AgentLoopFixture()
        let identity = minisCoreToolContractIdentity("agent-loop-shell")
        let mock = MockLLMProvider(responses: [
            toolCallEnvelope(id: "call_1", name: "shell_execute", input: ["command": "echo hello-from-shell"]),
            "工具执行完成，结果已收到。",
        ])
        var context = AgentContext(
            toolExecutor: fixture.executor,
            provider: mock,
            systemPrompt: "You are a test agent.",
            maxIterations: 5,
            approvalGate: ApprovalGate(delegate: AgentLoopApproveAllDelegate()),
            turnController: TurnController(),
            timeout: 30,
            currentConversationID: identity.turn.sessionID,
            parentIdentitySeed: ParentRuntimeIdentitySeed(
                sessionID: identity.turn.sessionID,
                conversationID: identity.turn.sessionID,
                taskID: "agent-loop-shell",
                actorID: "test"
            ),
            toolExecutionFactLedger: try minisCoreToolContractLedger(at: fixture.root),
            executionIdentity: identity
        )

        let history = try await context.run(userMessage: "运行一条命令")

        // Two round-trips: tool call, then final text.
        #expect(mock.receivedHistory.count == 2)

        // History: [user, assistant(envelope), user(tool_result), assistant(final)]
        #expect(history.count == 4)
        #expect(history.first?.role == .user)
        #expect(history.first?.content == "运行一条命令")
        #expect(history.last?.role == .assistant)
        #expect(history.last?.content == "工具执行完成，结果已收到。")

        // Tool result was fed back as a user message (Anthropic-style envelope).
        let toolResults = history.compactMap { msg -> String? in
            for part in msg.toAgentContentParts() {
                if case .toolResult(_, _, let content, let isError, _, _, _, _) = part, !isError {
                    return content
                }
            }
            return nil
        }
        #expect(toolResults.count == 1)
        #expect(toolResults.first?.contains("hello-from-shell") == true)

        // The second provider call must include the tool_result message.
        let secondCall = mock.receivedHistory[1]
        let secondCallContainsResult = secondCall.contains { msg in
            msg.toAgentContentParts().contains {
                if case .toolResult(_, _, _, _, _, _, _, _) = $0 { return true }
                return false
            }
        }
        #expect(secondCallContainsResult)

        // Context keeps the updated history.
        #expect(context.messages == history)
    }

    @Test func shellToolExecutesEchoCommand() async throws {
        let fixture = AgentLoopFixture()
        let output = try await fixture.executor.execute(
            name: "shell_execute",
            input: ["command": "echo hello-from-shell"]
        )
        #expect(output.contains("hello-from-shell"))
        #expect(output.contains("\"exit_code\":0"))
    }

    @Test func shellToolSurfacesNonZeroExit() async throws {
        let fixture = AgentLoopFixture()
        try Data().write(to: fixture.root.appendingPathComponent("empty.txt"))
        let output = try await fixture.executor.execute(
            name: "shell_execute",
            input: ["command": "grep -q needle empty.txt"]
        )
        #expect(output.contains("\"exit_code\":1"))
    }

    @Test func cancellingLongRunningShellDoesNotWaitForDescendantProcess() async throws {
        let fixture = AgentLoopFixture()
        let clock = ContinuousClock()
        let task = Task {
            try await fixture.executor.execute(
                name: "shell_execute",
                input: [
                    "command": "python3 -c \"import subprocess, time; subprocess.Popen(['sleep','2']); time.sleep(30)\""
                ]
            )
        }

        try await Task.sleep(for: .milliseconds(100))
        let cancellationStarted = clock.now
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(cancellationStarted.duration(to: clock.now) < .seconds(1))
    }

    @Test func cancellingShellThatIgnoresTerminationDoesNotHang() async throws {
        let fixture = AgentLoopFixture()
        let clock = ContinuousClock()
        let task = Task {
            try await fixture.executor.execute(
                name: "shell_execute",
                input: [
                    "command": "python3 -c \"import signal,subprocess,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);subprocess.Popen(['sleep','30']);time.sleep(30)\""
                ]
            )
        }

        try await Task.sleep(for: .milliseconds(100))
        let cancellationStarted = clock.now
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(cancellationStarted.duration(to: clock.now) < .seconds(1))
    }

    @Test func shellTimeoutDoesNotWaitForDescendantHoldingPipes() async throws {
        let fixture = AgentLoopFixture()
        let clock = ContinuousClock()
        let started = clock.now

        await #expect(throws: ToolExecutorError.self) {
            _ = try await fixture.executor.execute(
                name: "shell_execute",
                input: [
                    "command": "python3 -c \"import subprocess,time;subprocess.Popen(['sleep','30']);time.sleep(30)\"",
                    "timeout": 1,
                ]
            )
        }
        #expect(started.duration(to: clock.now) < .seconds(3))
    }

    @Test func builtinShellTimeoutKeepsTypedFactAndReturnsOriginalToolErrorToModel() async throws {
        let fixture = AgentLoopFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let ledger = try minisCoreToolContractLedger(at: fixture.root)
        let identity = minisCoreToolContractIdentity("shell-timeout-category")
        let provider = MockLLMProvider(responses: [
            toolCallEnvelope(id: "native-shell-timeout", name: "shell_execute",
                input: ["command": "printf START; sleep 2; printf LATE", "timeout": 0.1]),
            "model received the failed tool result"
        ])
        let loop = AgentLoop(maxIterations: 2,
            approvalGate: ApprovalGate(delegate: ProjectWorkspaceApproval()),
            turnController: TurnController(), timeout: 30, toolExecutionFactLedger: ledger)
        let outcome = await loop.runOutcome(messages: [], systemPrompt: nil, provider: provider,
            toolExecutor: fixture.executor, tools: minisCoreToolContractCatalog(["shell_execute"]),
            currentConversationID: identity.turn.sessionID,
            parentIdentitySeed: ParentRuntimeIdentitySeed(sessionID: identity.turn.sessionID,
                conversationID: identity.turn.sessionID, taskID: "timeout-category", actorID: "test"),
            executionIdentity: identity)
        #expect(outcome.failure == nil && outcome.result != nil)
        let fact = try #require(ledger.facts.first)
        #expect(ledger.facts.count == 1 && ledger.pendingReceipts.isEmpty)
        #expect(fact.toolCallID == "native-shell-timeout" && fact.executionIdentity == identity)
        #expect(fact.status == .failed && fact.failureCategory == .timeout)
        #expect(fact.elapsedMilliseconds != nil && fact.compositeKey != nil)
        #expect(outcome.toolExecutionFacts == ledger.facts)
        #expect(provider.receivedHistory.count == 2)
        let errors = provider.receivedHistory[1].flatMap { $0.toAgentContentParts() }.compactMap { part -> Bool? in
            guard case .toolResult(let id, _, _, let isError, _, _, _, _) = part,
                  id == "native-shell-timeout" else { return nil }
            return isError
        }
        #expect(errors == [true])
        #expect(provider.receivedHistory[1].contains { $0.content.contains("终端命令执行超时") })
    }

    @Test func shellTimeoutHonorsSubsecondInput() async throws {
        let fixture = AgentLoopFixture()

        do {
            _ = try await fixture.executor.execute(
                name: "shell_execute",
                input: [
                    "command": "python3 -c \"import time;time.sleep(2)\"",
                    "timeout": 0.1,
                ]
            )
            Issue.record("subsecond command deadline must throw a typed shell timeout")
        } catch let error as ToolExecutorError {
            guard case .shellTimeout(let detail) = error else { throw error }
            let envelope = try #require(try JSONSerialization.jsonObject(
                with: Data(detail.utf8)) as? [String: Any])
            #expect(Set(envelope.keys) == Set(["timed_out", "timeout_seconds", "stdout", "stderr"]))
            #expect(envelope["timed_out"] as? Bool == true)
            #expect(envelope["timeout_seconds"] as? Double == 0.1)
            #expect(envelope["stdout"] as? String == "")
            #expect(envelope["stderr"] as? String == "")
        }
    }

    @Test func shellExitDoesNotWaitForDescendantHoldingPipes() async throws {
        let fixture = AgentLoopFixture()
        let clock = ContinuousClock()
        let started = clock.now

        let output = try await fixture.executor.execute(
            name: "shell_execute",
            input: [
                "command": "python3 -c \"import subprocess;subprocess.Popen(['sleep','30'])\""
            ]
        )
        #expect(output.contains("\"exit_code\":0"))
        #expect(started.duration(to: clock.now) < .seconds(3))
    }

    @Test func fileReadRejectsPathsOutsideAllowedRoot() async throws {
        let fixture = AgentLoopFixture()

        // Absolute path outside the root must be rejected.
        await #expect(throws: ToolExecutorError.pathViolation("/etc/passwd")) {
            _ = try await fixture.executor.execute(name: "file_read", input: ["path": "/etc/passwd"])
        }
        // Relative paths are rejected outright.
        await #expect(throws: ToolExecutorError.pathViolation("etc/passwd")) {
            _ = try await fixture.executor.execute(name: "file_read", input: ["path": "etc/passwd"])
        }
        // Traversal that escapes the root is rejected after standardization.
        await #expect(throws: ToolExecutorError.pathViolation("/tmp/../../etc/passwd")) {
            _ = try await fixture.executor.execute(name: "file_read", input: ["path": "/tmp/../../etc/passwd"])
        }
    }

    @Test func fileWriteAndReadRoundTripInsideRoot() async throws {
        let fixture = AgentLoopFixture()
        let target = fixture.root.appendingPathComponent("notes/sub.txt").path

        let writeOut = try await fixture.executor.execute(
            name: "file_write",
            input: ["path": target, "content": "line one\nline two\nline three", "create_dirs": true]
        )
        #expect(writeOut.contains("Wrote"))

        let readOut = try await fixture.executor.execute(
            name: "file_read",
            input: ["path": target, "lines": 2]
        )
        #expect(readOut.contains("line one"))
        #expect(readOut.contains("line two"))
        #expect(!readOut.contains("line three"))

        // Missing file inside the root → fileNotFound.
        let missing = fixture.root.appendingPathComponent("nope.txt").path
        await #expect(throws: ToolExecutorError.fileNotFound(missing)) {
            _ = try await fixture.executor.execute(
                name: "file_read",
                input: ["path": missing]
            )
        }
    }

    @Test func webSearchFailsHonestlyAsUnwiredCapability() async throws {
        // P3-P1-05 重钉（原 webSearchIsPlaceholder）：旧契约要求 execute 成功
        // 返回含「未接入」的说明文本 —— 该假成功已被诚实失败契约取代。
        // 新契约：web_search 不在默认白名单，默认组合的调用在闸门处即抛
        // unknownTool，AgentLoop 将其记录为 is_error:true 的 tool_result，
        // 绝不产生可被模型误读为搜索成功的占位输出。
        let fixture = AgentLoopFixture()
        await #expect(throws: ToolExecutorError.unknownTool("web_search")) {
            _ = try await fixture.executor.execute(name: "web_search", input: ["query": "swift"])
        }
    }

    @Test func unknownToolThrows() async throws {
        let fixture = AgentLoopFixture()
        await #expect(throws: ToolExecutorError.unknownTool("bogus_tool")) {
            _ = try await fixture.executor.execute(name: "bogus_tool", input: [:])
        }
    }

    @Test func loopStopsAtMaxIterations() async throws {
        let fixture = AgentLoopFixture()
        // Always asks for a tool — the loop must give up after 2 iterations.
        let mock = MockLLMProvider(responses: [
            toolCallEnvelope(id: "call_1", name: "web_search", input: ["query": "x"]),
            toolCallEnvelope(id: "call_2", name: "web_search", input: ["query": "y"]),
        ])
        let loop = AgentLoop(maxIterations: 2)
        await #expect(throws: AgentLoopError.maxIterationsExceeded(2)) {
            _ = try await loop.run(
                messages: [],
                systemPrompt: nil,
                provider: mock,
                toolExecutor: fixture.executor,
                tools: AgentToolCatalog.makeTools()
            )
        }
        #expect(mock.receivedHistory.count == 2)
    }

    @Test func runCarriesCompositionRootExecutionIdentityIntoResult() async throws {
        let fixture = AgentLoopFixture()
        let mock = MockLLMProvider(responses: ["固定身份回写。"])
        let expected = AgentExecutionIdentity(
            turn: AgentTurnIdentity(
                sessionID: "identity-session",
                turnID: 12,
                messageID: "assistant-placeholder"
            ),
            operationID: "identity-operation",
            attempt: 1
        )
        let loop = AgentLoop(maxIterations: 1)

        let result = try await loop.run(
            messages: [.init(role: .user, content: "hello")],
            systemPrompt: nil,
            provider: mock,
            toolExecutor: fixture.executor,
            tools: [],
            currentConversationID: "identity-session",
            executionIdentity: expected
        )

        #expect(result.executionIdentity == expected)
        #expect(result.messages.last?.content == "固定身份回写。")
    }

    @Test func suppliedExecutionIdentityRejectsWrongSessionBeforeProviderCall() async throws {
        let fixture = AgentLoopFixture()
        let mock = MockLLMProvider(responses: ["不得调用。"])
        let identity = minisCoreToolContractIdentity(
            "agent-loop-identity-mismatch",
            sessionID: "stale-session"
        )
        let loop = AgentLoop(maxIterations: 1)

        await #expect(throws: AgentLoopError.executionIdentityMismatch) {
            _ = try await loop.run(
                messages: [.init(role: .user, content: "hello")],
                systemPrompt: nil,
                provider: mock,
                toolExecutor: fixture.executor,
                tools: [],
                currentConversationID: "current-session",
                executionIdentity: identity
            )
        }
        #expect(mock.receivedHistory.isEmpty)
    }

    @Test func suppliedExecutionIdentityRejectsWrongTurnHandle() async throws {
        let fixture = AgentLoopFixture()
        let mock = MockLLMProvider(responses: ["不得调用。"])
        let identity = minisCoreToolContractIdentity(
            "agent-loop-turn-mismatch",
            sessionID: "turn-session",
            turnID: 99
        )
        let loop = AgentLoop(
            maxIterations: 1,
            turnController: TurnController()
        )

        await #expect(throws: AgentLoopError.executionIdentityMismatch) {
            _ = try await loop.run(
                messages: [.init(role: .user, content: "hello")],
                systemPrompt: nil,
                provider: mock,
                toolExecutor: fixture.executor,
                tools: [],
                currentConversationID: "turn-session",
                executionIdentity: identity
            )
        }
        #expect(mock.receivedHistory.isEmpty)
    }

    @Test func composerIdentityUsesPersistentTurnRatherThanLocalCancellationHandle() async throws {
        let fixture = AgentLoopFixture()
        let snapshot = ComposerSubmissionSnapshot(
            mode: .manual,
            approvalScope: .request,
            effort: .standard,
            sessionID: "persistent-session",
            turnID: 8,
            taskID: "persistent-task",
            messageID: "assistant-placeholder",
            workspaceID: "persistent-session",
            createdAt: Date(timeIntervalSince1970: 1),
            policyRevision: "policy-1",
            grantEpoch: "grant-1"
        )
        let identity = minisCoreToolContractIdentity(
            "persistent-turn",
            sessionID: snapshot.sessionID,
            turnID: snapshot.turnID,
            messageID: snapshot.messageID
        )
        let mock = MockLLMProvider(responses: ["persistent-turn-ok"])
        let loop = AgentLoop(maxIterations: 1, turnController: TurnController())

        let result = try await loop.run(
            messages: [.init(role: .user, content: "hello")],
            systemPrompt: nil,
            provider: mock,
            toolExecutor: fixture.executor,
            tools: [],
            currentConversationID: snapshot.sessionID,
            composerSnapshot: snapshot,
            executionIdentity: identity
        )
        #expect(result.executionIdentity == identity)
        #expect(mock.receivedHistory.count == 1)

        for (name, rejectedIdentity) in [
            ("wrong-session", minisCoreToolContractIdentity(
                "wrong-session", sessionID: "other-session", turnID: 8,
                messageID: snapshot.messageID
            )),
            ("wrong-turn", minisCoreToolContractIdentity(
                "wrong-turn", sessionID: snapshot.sessionID, turnID: 9,
                messageID: snapshot.messageID
            )),
            ("wrong-message", minisCoreToolContractIdentity(
                "wrong-message", sessionID: snapshot.sessionID, turnID: 8,
                messageID: "other-message"
            )),
        ] {
            let rejectedProvider = MockLLMProvider(responses: ["must not call: \(name)"])
            await #expect(throws: AgentLoopError.executionIdentityMismatch) {
                _ = try await loop.run(
                    messages: [.init(role: .user, content: "hello")],
                    systemPrompt: nil,
                    provider: rejectedProvider,
                    toolExecutor: fixture.executor,
                    tools: [],
                    currentConversationID: snapshot.sessionID,
                    composerSnapshot: snapshot,
                    executionIdentity: rejectedIdentity
                )
            }
            #expect(rejectedProvider.receivedHistory.isEmpty)
        }
    }

    @Test @MainActor func providerRouteBindingReachesExecutionContext() async throws {
        let fixture = AgentLoopFixture()
        let model = LLMModel(
            id: "route-model",
            displayName: "Route Model",
            provider: "Mock"
        )
        let mock = MockLLMProvider(
            model: model,
            responses: ["route-bound"],
            runtimeConfigurationMaterial: "route-material"
        )
        let fingerprint = ProviderRuntimeSnapshot.configurationFingerprint(
            providerID: mock.name,
            modelID: model.id,
            capabilities: mock.capabilities,
            configurationMaterial: "route-material"
        )
        let snapshot = try ProviderRuntimeSnapshot(
            providerID: mock.name,
            modelID: model.id,
            readinessEvidenceID: "live-settings:" + String(repeating: "a", count: 64),
            applyReceiptID: "provider-readiness-apply:agent-loop-route",
            capabilities: mock.capabilities,
            configurationFingerprint: fingerprint
        )
        let route = try ProviderRuntimeRoute(snapshot: snapshot, primary: mock)
        try await runRouteBoundAgentLoop(route: route, allowedRoot: fixture.root)

        #expect(mock.capturedParentBinding?.providerID == mock.name)
        #expect(mock.capturedParentBinding?.modelID == model.id)
        #expect(mock.capturedParentBinding?.configurationFingerprint == fingerprint)
    }

    @Test func wrappedProviderKeepsRouteBindingWithoutReplacingTheExecutor() async throws {
        let fixture = AgentLoopFixture()
        let model = LLMModel(id: "wrapped-model", displayName: "Wrapped", provider: "Mock")
        let mock = MockLLMProvider(model: model, responses: ["wrapped-ok"])
        let fingerprint = ProviderRuntimeSnapshot.configurationFingerprint(
            providerID: mock.name,
            modelID: model.id,
            capabilities: mock.capabilities,
            configurationMaterial: "actual-route"
        )
        let snapshot = try ProviderRuntimeSnapshot(
            providerID: mock.name,
            modelID: model.id,
            readinessEvidenceID: "live-settings:" + String(repeating: "b", count: 64),
            applyReceiptID: "provider-readiness-apply:wrapped",
            capabilities: mock.capabilities,
            configurationFingerprint: fingerprint
        )

        _ = try await AgentLoop(maxIterations: 1).run(
            messages: [.init(role: .user, content: "hello")],
            systemPrompt: nil,
            provider: mock,
            providerRuntimeRouteSnapshot: snapshot,
            toolExecutor: fixture.executor,
            tools: [],
            currentConversationID: "wrapped-session"
        )

        #expect(mock.receivedHistory.count == 1)
        #expect(mock.capturedParentBinding?.configurationFingerprint == fingerprint)

        let mismatched = try ProviderRuntimeSnapshot(
            providerID: mock.name,
            modelID: "other-model",
            readinessEvidenceID: "live-settings:" + String(repeating: "c", count: 64),
            applyReceiptID: "provider-readiness-apply:mismatch",
            capabilities: mock.capabilities,
            configurationFingerprint: fingerprint
        )
        let rejectedProvider = MockLLMProvider(model: model, responses: ["must not call"])
        await #expect(throws: ProviderRuntimeSnapshotError.modelBindingMismatch("other-model")) {
            _ = try await AgentLoop(maxIterations: 1).run(
                messages: [.init(role: .user, content: "hello")],
                systemPrompt: nil,
                provider: rejectedProvider,
                providerRuntimeRouteSnapshot: mismatched,
                toolExecutor: fixture.executor,
                tools: []
            )
        }
        #expect(rejectedProvider.receivedHistory.isEmpty)
    }

    @Test func toolErrorIsFedBackAsErrorResult() async throws {
        let fixture = AgentLoopFixture()
        let identity = minisCoreToolContractIdentity("agent-loop-tool-error")
        // Calls file_read on a path outside the root → executor throws.
        let mock = MockLLMProvider(responses: [
            toolCallEnvelope(id: "call_1", name: "file_read", input: ["path": "/etc/passwd"]),
            "已收到错误。",
        ])
        var context = AgentContext(
            toolExecutor: fixture.executor,
            provider: mock,
            maxIterations: 5,
            toolExecutionFactLedger: try minisCoreToolContractLedger(at: fixture.root),
            executionIdentity: identity
        )
        let history = try await context.run(userMessage: "读 /etc/passwd")

        let errorResults = history.compactMap { msg -> Bool? in
            for part in msg.toAgentContentParts() {
                if case .toolResult(_, _, let content, let isError, _, _, _, _) = part {
                    return isError && content.contains(ToolExecutorError.pathViolation("/etc/passwd").localizedDescription)
                }
            }
            return nil
        }
        #expect(errorResults.count == 1)
        #expect(errorResults.first == true)
        #expect(history.last?.content == "已收到错误。")
    }

    @Test func agentMessageConversionRoundTripsToolUseAndResult() throws {
        // AgentMessage → LLMMessage → AgentContentPart preserves tool_use and tool_result.
        let agentMsg = AgentMessage(role: .assistant, parts: [
            .text("calling now"),
            .toolUse(id: "call_9", name: "shell_execute", input: ["command": "pwd"]),
        ])
        let llmMessages = agentMsg.toLLMMessages()
        #expect(llmMessages.count == 2)

        let toolUseParts = llmMessages[1].toAgentContentParts()
        guard case .toolUse(let id, let name, let input) = toolUseParts[0] else {
            Issue.record("expected toolUse part, got \(toolUseParts)")
            return
        }
        #expect(id == "call_9")
        #expect(name == "shell_execute")
        #expect((input["command"] as? String) == "pwd")

        let resultMsg = LLMMessage(role: .user, content: """
        {"type":"tool_result","tool_use_id":"call_9","content":"/Users\\n","is_error":false}
        """)
        let resultParts = resultMsg.toAgentContentParts()
        guard case .toolResult(let rid, _, let content, let isError, _, _, _, _) = resultParts[0] else {
            Issue.record("expected toolResult part, got \(resultParts)")
            return
        }
        #expect(rid == "call_9")
        #expect(content == "/Users\n")
        #expect(!isError)
    }

    @Test func plainTextRoundTripsAsTextPart() throws {
        let msg = LLMMessage(role: .assistant, content: "just a reply")
        let parts = msg.toAgentContentParts()
        guard case .text(let text) = parts[0] else {
            Issue.record("expected text part, got \(parts)")
            return
        }
        #expect(text == "just a reply")
    }

    @Test func emptyToolTableStillFeedsToolErrorBack() async throws {
        // 边界：tools: []（空工具表）时模型仍请求工具 → executor 抛
        // unknownTool → 以 is_error tool_result 回传，循环不崩、不空转。
        let fixture = AgentLoopFixture()
        let mock = MockLLMProvider(responses: [
            toolCallEnvelope(id: "call_1", name: "bogus_tool", input: [:]),
            "已知道没有可用工具。",
        ])
        var context = AgentContext(
            toolExecutor: fixture.executor,
            provider: mock,
            tools: [], // 空工具表
            maxIterations: 5
        )
        let history = try await context.run(userMessage: "搜一下")
        #expect(history.last?.content == "已知道没有可用工具。")
        // 空表下的工具调用被回传为 is_error 结果
        let errorResults = history.compactMap { msg -> Bool? in
            for part in msg.toAgentContentParts() {
                if case .toolResult(_, _, let content, let isError, _, _, _, _) = part {
                    return isError && content.contains(ToolExecutorError.unknownTool("bogus_tool").localizedDescription)
                }
            }
            return nil
        }
        #expect(errorResults.count == 1)
        #expect(errorResults.first == true)
    }

    @Test func allToolsFailingLoopStillTerminatesWithFinalText() async throws {
        // 边界：每一轮工具调用都失败（全失败）→ 循环持续回传 is_error，
        // 模型最终给出纯文本时正常结束，不抛 maxIterationsExceeded。
        let fixture = AgentLoopFixture()
        let mock = MockLLMProvider(responses: [
            toolCallEnvelope(id: "c1", name: "bogus_1", input: [:]),
            toolCallEnvelope(id: "c2", name: "bogus_2", input: [:]),
            "最终文本。",
        ])
        var context = AgentContext(
            toolExecutor: fixture.executor,
            provider: mock,
            maxIterations: 5
        )
        let history = try await context.run(userMessage: "全失败测试")
        #expect(history.last?.content == "最终文本。")
        let errorCount = history.compactMap { msg -> Bool? in
            for part in msg.toAgentContentParts() {
                if case .toolResult(_, _, _, let isError, _, _, _, _) = part { return isError }
            }
            return nil
        }
        #expect(errorCount.count == 2)
        #expect(errorCount.allSatisfy { $0 == true })
    }

    @Test func emptyResponseThrows() async throws {
        // 边界：provider 返回空白文本且无工具调用 → 抛 emptyResponse
        let fixture = AgentLoopFixture()
        let mock = MockLLMProvider(responses: ["   \n  "])
        var context = AgentContext(
            toolExecutor: fixture.executor,
            provider: mock,
            maxIterations: 3
        )
        await #expect(throws: AgentLoopError.emptyResponse) {
            _ = try await context.run(userMessage: "你好")
        }
    }

    @Test func mixedApprovalAndFailurePerCallKeepsOrder() async throws {
        // 边界：同一轮多个工具调用，一个被审批拒绝、一个执行失败、一个成功；
        // 回传顺序必须与请求顺序一致，且各结果 is_error 标记正确。
        final class RecordingExecutor2: ToolExecutor {
            func execute(name: String, input: [String: Any]) async throws -> String {
                if name == "file_read" { throw ToolExecutorError.fileNotFound("/nope") }
                return "ok-\(name)"
            }
        }
        final class DenyAllDelegate: ApprovalDelegate {
            func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
                .deny
            }
        }
        let gate = ApprovalGate(
            policyByTool: ["file_write": .alwaysAsk],
            delegate: DenyAllDelegate()
        )
        let root = try minisCoreToolContractRoot("agent-loop-mixed-order")
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = minisCoreToolContractIdentity("agent-loop-mixed-order")
        let loop = AgentLoop(
            maxIterations: 5,
            approvalGate: gate,
            toolExecutionFactLedger: try minisCoreToolContractLedger(at: root)
        )
        let mock = MockLLMProvider(responses: [
            """
            {"tool_calls": [
              {"id": "c1", "name": "file_write", "input": {"path": "/tmp/a"}},
              {"id": "c2", "name": "file_read", "input": {"path": "/nope"}},
              {"id": "c3", "name": "web_search", "input": {"query": "x"}}
            ]}
            """,
            "完成。",
        ])
        let result = try await loop.run(
            messages: [],
            systemPrompt: "test",
            provider: mock,
            toolExecutor: RecordingExecutor2(),
            tools: minisCoreToolContractCatalog(["file_write", "file_read", "web_search"]),
            executionIdentity: identity
        )
        let parts = result.messages.compactMap { msg -> [AgentContentPart]? in
            let p = msg.toAgentContentParts()
            return p.contains { if case .toolResult = $0 { return true }; return false } ? p : nil
        }
        // 一轮 tool_result 数组，3 个结果按 c1 c2 c3 顺序
        #expect(parts.count == 1)
        let results = parts[0]
        #expect(results.count == 3)
        if case .toolResult(let id1, _, _, let e1, _, _, _, _) = results[0] {
            #expect(id1 == "c1")
            #expect(e1) // 审批拒绝 → is_error
        }
        if case .toolResult(let id2, _, _, let e2, _, _, _, _) = results[1] {
            #expect(id2 == "c2")
            #expect(e2) // 执行失败 → is_error
        }
        if case .toolResult(let id3, _, let content3, let e3, _, _, _, _) = results[2] {
            #expect(id3 == "c3")
            #expect(!e3)
            #expect(content3 == "ok-web_search")
        }
        #expect(result.toolCallsExecuted == 2) // 拒绝的不计，失败的成功执行都计
    }

    @Test func browserBackEmptyHistoryProducesBoundedFailedTerminal() throws {
        let hiddenScope = "scope:synthetic-private-marker"
        let raw = try BrowserToolResponse(
            outcome: "failed", action: "back", scopeID: hiddenScope,
            failureCode: "cannot_go_back"
        ).encoded()
        let terminal = try #require(AgentLoop.browserTerminal(
            toolName: BrowserTool.toolName,
            input: ["action": "back"],
            output: raw
        ))
        #expect(terminal.status == .failed)
        #expect(terminal.isError)
        #expect(terminal.detail?.action == "back")
        #expect(terminal.detail?.outcome == "failed")
        #expect(terminal.detail?.failureCode == "cannot_go_back")
        #expect(terminal.feedback == "[BROWSER BACK FAILED] cannot_go_back")
        #expect(!terminal.feedback.contains(hiddenScope))

        let wrongAction = try BrowserToolResponse(
            outcome: "failed", action: "click", scopeID: hiddenScope,
            failureCode: "cannot_go_back"
        ).encoded()
        let malformed = try #require(AgentLoop.browserTerminal(
            toolName: BrowserTool.toolName,
            input: ["action": "click"],
            output: wrongAction
        ))
        #expect(malformed.detail == nil)
        #expect(malformed.isError)
        #expect(malformed.feedback == "[BROWSER RESULT INVALID]")

        let priorSuccess = try BrowserToolResponse(
            outcome: "succeeded", action: "back", scopeID: hiddenScope,
            result: "synthetic-untrusted-result"
        ).encoded()
        let success = try #require(AgentLoop.browserTerminal(
            toolName: BrowserTool.toolName,
            input: ["action": "back"],
            output: priorSuccess
        ))
        #expect(success.status == .succeeded)
        #expect(!success.isError)
        #expect(success.detail?.failureCode == nil)
    }

}

private struct AgentLoopApproveAllDelegate: ApprovalDelegate {
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        ApprovalDecision(
            approved: true,
            reason: "synthetic approval",
            confirmed: true,
            requestID: request.requestID,
            bindingDigest: request.identityDigest
        )
    }
}

private actor PreflightRetryApproval: ApprovalDelegate {
    private(set) var count = 0
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        count += 1
        return ApprovalDecision(approved: true, confirmed: true,
            requestID: request.requestID, bindingDigest: request.identityDigest)
    }
}
