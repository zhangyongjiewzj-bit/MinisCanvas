import Foundation
import Testing
@testable import MinisCore

private final class WorkflowToolProvider: LLMProvider, @unchecked Sendable {
    let name = "workflow-provider"
    var model = LLMModel(id: "workflow-model", displayName: "Workflow Model", provider: "workflow-provider")
    var capabilities: Set<ProviderCapability> { [] }
    private var responseIndex = 0

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        defer { responseIndex += 1 }
        if responseIndex == 0 {
            return LLMResponse(
                text: "调用工具",
                stopReason: "tool_calls",
                usage: nil,
                toolCalls: [LLMToolCall(
                    id: "call-workflow-1",
                    name: "web_search",
                    rawArguments: "{\"query\":\"MinisCanvas\"}",
                    arguments: ["query": "MinisCanvas"]
                )]
            )
        }
        return LLMResponse(text: "工具结果已收到", stopReason: "stop", usage: nil)
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
        AsyncThrowingStream { $0.finish() }
    }
}

private struct WorkflowProviderFailure: Error, LocalizedError, Equatable, Sendable {
    var errorDescription: String? { "workflow provider failed" }
}

private func workflowToolCatalog() -> [AgentToolDefinition] {
    [
        AgentToolDefinition(
            name: "web_search",
            description: "Search the configured web provider.",
            parameters: [
                "query": AgentToolParam(type: .string, description: "Search query"),
            ],
            required: ["query"]
        ),
    ]
}

private func workflowExecutionIdentity(
    sessionID: String,
    turnID: String,
    attempt: Int
) -> AgentExecutionIdentity {
    AgentExecutionIdentity(
        turn: AgentTurnIdentity(
            sessionID: sessionID,
            turnID: max(0, attempt - 1),
            messageID: "assistant:\(sessionID):\(turnID)"
        ),
        operationID: "workflow:\(sessionID):\(turnID)",
        attempt: attempt
    )
}

private func workflowLedger(root: URL) throws -> ToolExecutionFactLedger {
    try ToolExecutionFactLedger(
        persistenceURL: root.appendingPathComponent("tool-execution-facts-v4.json")
    )
}

private func workflowFact(
    identity: AgentExecutionIdentity,
    toolCallID: String,
    toolName: String,
    status: ToolExecutionStatus = .succeeded
) -> ToolExecutionFact {
    let key = ToolExecutionCompositeKey(
        sessionID: identity.turn.sessionID,
        turnID: identity.turn.turnID,
        messageID: identity.turn.messageID,
        operationID: identity.operationID,
        attemptID: "\(identity.operationID):attempt:\(identity.attempt)",
        attemptNumber: identity.attempt,
        toolCallID: toolCallID
    )
    return ToolExecutionFact(
        toolCallID: toolCallID,
        receiptID: "receipt-\(toolCallID)",
        toolName: toolName,
        status: status,
        attemptID: key.attemptID,
        attemptNumber: identity.attempt,
        executionIdentity: identity,
        compositeKey: key
    )
}

private func makeWorkflowRuntime<P: LLMProvider & Sendable>(
    root: URL,
    sessions: SessionStore,
    provider: P,
    startupReady: Bool = true
) throws -> ChatSessionRuntime {
    ChatSessionRuntime(
        sessionStore: sessions,
        memoryStore: MemoryStore(directory: root),
        skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
        soulStore: SoulStore(directory: root),
        provider: provider,
        toolExecutor: WorkflowToolExecutor(),
        startupReady: startupReady,
        toolCatalog: workflowToolCatalog(),
        toolExecutionFactLedger: try workflowLedger(root: root)
    )
}

private final class FailingWorkflowProvider: LLMProvider, @unchecked Sendable {
    let name = "failing-workflow-provider"
    var model = LLMModel(
        id: "failing-workflow-model",
        displayName: "Failing Workflow Model",
        provider: "failing-workflow-provider"
    )
    var capabilities: Set<ProviderCapability> { [] }
    private(set) var sendCount = 0
    private var responseIndex = 0

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        sendCount += 1
        if responseIndex == 0 {
            responseIndex += 1
            return LLMResponse(
                text: "先调用工具",
                stopReason: "tool_calls",
                usage: nil,
                toolCalls: [LLMToolCall(
                    id: "call-failing-1",
                    name: "web_search",
                    rawArguments: "{\"query\":\"failure\"}",
                    arguments: ["query": "failure"]
                )]
            )
        }
        throw WorkflowProviderFailure()
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
        AsyncThrowingStream { $0.finish() }
    }
}

private enum WorkflowCancellationMode: Sendable {
    case cancellation
    case interrupted
}

private final class CancellationWorkflowProvider: LLMProvider, @unchecked Sendable {
    let name = "cancellation-workflow-provider"
    var model = LLMModel(
        id: "cancellation-workflow-model",
        displayName: "Cancellation Workflow Model",
        provider: "cancellation-workflow-provider"
    )
    var capabilities: Set<ProviderCapability> { [] }
    let mode: WorkflowCancellationMode

    init(mode: WorkflowCancellationMode) {
        self.mode = mode
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        switch mode {
        case .cancellation:
            throw CancellationError()
        case .interrupted:
            throw InterruptedError()
        }
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
        AsyncThrowingStream { $0.finish() }
    }
}

private struct WorkflowToolExecutor: ToolExecutor {
    func execute(name: String, input: [String: Any]) async throws -> String {
        #expect(name == "web_search")
        return "search-result"
    }
}

struct ChatSessionToolCallWorkflowTests {
    @Test("CancellationError remains cancellation and does not mint retry envelope")
    func cancellationDoesNotCreateRetryEnvelope() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCore-CancellationRetry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let sessions = SessionStore(directory: root)
        let session = try sessions.createSession(id: "cancel-session", projectID: "cancel-project")
        let runtime = try makeWorkflowRuntime(
            root: root,
            sessions: sessions,
            provider: CancellationWorkflowProvider(mode: .cancellation)
        )
        let context = try await runtime.makeContext(sessionID: session.id)
        let request = ChatTurnRequest(
            text: "取消",
            context: context,
            turnID: "cancel-turn",
            taskID: "cancel-task",
            policySnapshotID: "policy-cancel",
            grantSnapshotID: "grant-cancel",
            executionIdentity: workflowExecutionIdentity(
                sessionID: session.id,
                turnID: "cancel-turn",
                attempt: 1
            )
        )

        await #expect(throws: CancellationError.self) {
            try await runtime.send(request)
        }
        #expect(await runtime.latestRetryEnvelope == nil)
    }

    @Test("InterruptedError remains interrupted and does not mint retry envelope")
    func interruptedDoesNotCreateRetryEnvelope() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCore-InterruptedRetry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let sessions = SessionStore(directory: root)
        let session = try sessions.createSession(id: "interrupted-session", projectID: "interrupted-project")
        let runtime = try makeWorkflowRuntime(
            root: root,
            sessions: sessions,
            provider: CancellationWorkflowProvider(mode: .interrupted)
        )
        let context = try await runtime.makeContext(sessionID: session.id)
        let request = ChatTurnRequest(
            text: "中断",
            context: context,
            turnID: "interrupted-turn",
            taskID: "interrupted-task",
            policySnapshotID: "policy-interrupted",
            grantSnapshotID: "grant-interrupted",
            executionIdentity: workflowExecutionIdentity(
                sessionID: session.id,
                turnID: "interrupted-turn",
                attempt: 1
            )
        )

        await #expect(throws: InterruptedError.self) {
            try await runtime.send(request)
        }
        #expect(await runtime.latestRetryEnvelope == nil)
    }

    @Test("sendProduction checks startup readiness before route availability")
    func sendProductionStartupGatePrecedesRouteRequirement() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCore-ChatProductionStartupGate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let sessions = SessionStore(directory: root)
        let session = try sessions.createSession(id: "production-startup-session", projectID: "production-project")
        let runtime = try makeWorkflowRuntime(
            root: root,
            sessions: sessions,
            provider: WorkflowToolProvider(),
            startupReady: false
        )
        let context = try await runtime.makeContext(sessionID: session.id)

        await #expect(throws: ChatSessionRuntimeError.startupNotReady) {
            try await runtime.sendProduction(
                ChatTurnRequest(
                    text: "startup gate",
                    context: context,
                    executionIdentity: workflowExecutionIdentity(
                        sessionID: session.id,
                        turnID: context.conversationID,
                        attempt: 1
                    )
                )
            )
        }
    }

    @Test("provider failure creates and attaches a frozen retry envelope")
    func failedSendThrowsFrozenRetryEnvelope() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCore-ChatFailedRetryEnvelope-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let sessions = SessionStore(directory: root)
        let session = try sessions.createSession(id: "failed-retry-session", projectID: "failed-retry-project")
        let provider = FailingWorkflowProvider()
        let runtime = try makeWorkflowRuntime(
            root: root,
            sessions: sessions,
            provider: provider
        )
        let context = try await runtime.makeContext(sessionID: session.id)
        let request = ChatTurnRequest(
            text: "失败后可重试",
            context: context,
            turnID: "failed-turn",
            taskID: "failed-task",
            attempt: 2,
            policySnapshotID: "policy-frozen",
            grantSnapshotID: "grant-frozen",
            executionIdentity: workflowExecutionIdentity(
                sessionID: session.id,
                turnID: "failed-turn",
                attempt: 2
            )
        )

        var captured: ChatRetryEnvelope?
        do {
            _ = try await runtime.send(request)
            Issue.record("expected provider failure")
        } catch let error as ChatSessionRuntimeError {
            guard case .turnFailed(let envelope) = error else {
                Issue.record("unexpected runtime error: \(error)")
                return
            }
            captured = envelope
        }

        let envelope = try #require(captured)
        #expect(provider.sendCount == 2)
        #expect(envelope.sessionID == session.id)
        #expect(envelope.turnID == "failed-turn")
        #expect(envelope.taskID == "failed-task")
        #expect(envelope.attempt == 2)
        #expect(envelope.policySnapshotID == "policy-frozen")
        #expect(envelope.grantSnapshotID == "grant-frozen")
        #expect(envelope.toolCallIDs == ["call-failing-1"])
        #expect(envelope.partialMessages.map(\.role) == [.user, .assistant, .tool])
        #expect(envelope.partialMessages[1].toolCalls.first?.rawArguments == "{\"query\":\"failure\"}")
        #expect(envelope.partialMessages[2].content == "search-result")
        #expect(envelope.toolExecutionFacts.count == 1)
        #expect(envelope.toolExecutionFacts.first?.executionIdentity == envelope.executionIdentity)
        #expect(envelope.toolExecutionFacts.first?.compositeKey?.sessionID == session.id)
        #expect(envelope.toolExecutionFacts.first?.attemptNumber == envelope.attempt)
        #expect(await runtime.latestRetryEnvelope == envelope)
    }

    @Test("Composer policy wrapper records real args and results on provider failure")
    func composerRecorderPreservesFailureHistory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCore-ComposerWorkflowRecorder-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: ToolExecutionFactLedgerError.persistenceFailed) {
            try workflowLedger(root: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ledger = try workflowLedger(root: root)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = ComposerSubmissionSnapshot(
            mode: .auto,
            approvalScope: .request,
            effort: .standard,
            sessionID: "composer-session",
            turnID: 1,
            taskID: "composer-task",
            attemptID: "composer-attempt",
            messageID: "composer-message",
            workspaceID: "composer-workspace",
            createdAt: now,
            policyRevision: "policy-composer",
            grantEpoch: "grant-composer",
            autonomyCeiling: .l3
        )
        let policyFacts = ComposerPolicyFactSource(
            knownCapabilities: ["web_search"],
            grantedCapabilities: ["web_search"],
            allowedWriteRoots: [],
            workspaceID: "composer-workspace",
            revision: "policy-composer",
            grantEpoch: "grant-composer",
            leaseID: "composer-lease",
            expiresAt: now.addingTimeInterval(600),
            autonomyCeiling: .l3
        )
        let composer = ComposerPolicyEnforcedToolExecutor(
            base: WorkflowToolExecutor(),
            controller: ComposerAuthorizationController(
                snapshot: snapshot,
                facts: policyFacts,
                now: { now }
            )
        )
        let identity = AgentExecutionIdentity(
            turn: AgentTurnIdentity(
                sessionID: snapshot.sessionID,
                turnID: snapshot.turnID,
                messageID: snapshot.messageID
            ),
            operationID: "workflow:composer-session:composer-turn",
            attempt: 1
        )
        var context = AgentContext(
            toolExecutor: composer,
            provider: FailingWorkflowProvider(),
            tools: workflowToolCatalog(),
            toolExecutionFactLedger: ledger,
            executionIdentity: identity,
            composerSnapshot: snapshot
        )

        do {
            _ = try await context.run(userMessage: "composer failure")
            Issue.record("expected Composer provider failure")
        } catch is WorkflowProviderFailure {
            // The provider failed after the tool result was recorded.
        } catch {
            Issue.record("unexpected Composer workflow error: \(type(of: error))")
        }

        let capturedFacts = ledger.facts(
            executionIdentity: identity,
            attemptID: snapshot.attemptID,
            attemptNumber: identity.attempt
        )
        #expect(capturedFacts.count == 1)
        #expect(capturedFacts.first?.toolName == "web_search")
        #expect(context.lastPartialMessages.map(\.role) == [.user, .assistant, .tool])
        try #require(context.lastPartialMessages.count >= 3)
        #expect(context.lastPartialMessages[1].toolCalls.first?.rawArguments == "{\"query\":\"failure\"}")
        #expect(context.lastPartialMessages[2].content == "search-result")
        let composerCall = try #require(context.lastPartialMessages[1].toolCalls.first)
        let composerEnvelope = ChatRetryEnvelope(
            envelopeID: "composer-envelope",
            inputText: "composer failure",
            sessionID: identity.turn.sessionID,
            conversationID: "composer-conversation",
            turnID: "composer-turn",
            taskID: snapshot.taskID,
            attempt: identity.attempt,
            providerID: "composer-provider",
            modelID: "composer-model",
            configurationFingerprint: "composer-fingerprint",
            policySnapshotID: snapshot.policyRevision,
            grantSnapshotID: snapshot.grantEpoch,
            executionIdentity: identity,
            canonicalAttemptID: snapshot.attemptID,
            toolCalls: [composerCall],
            partialMessages: context.lastPartialMessages,
            toolExecutionFacts: capturedFacts,
            failureMessage: "composer failed"
        )
        #expect(composerEnvelope.rejection == nil)
        #expect(composerEnvelope.canonicalAttemptID == snapshot.attemptID)
        #expect(try JSONDecoder().decode(
            ChatRetryEnvelope.self,
            from: JSONEncoder().encode(composerEnvelope)
        ) == composerEnvelope)
    }

    @Test("retry envelope rejects missing policy or grant snapshots")
    func retryEnvelopeRequiresFrozenAuthorizationSnapshots() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCore-ChatRetrySnapshotGate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let sessions = SessionStore(directory: root)
        let session = try sessions.createSession(id: "retry-snapshot-session", projectID: "retry-snapshot-project")
        let runtime = try makeWorkflowRuntime(
            root: root,
            sessions: sessions,
            provider: WorkflowToolProvider()
        )
        let context = try await runtime.makeContext(sessionID: session.id)

        await #expect(throws: ChatSessionRuntimeError.retrySnapshotMissing) {
            _ = try await runtime.makeRetryEnvelope(
                request: ChatTurnRequest(
                    text: "缺授权快照",
                    context: context,
                    executionIdentity: workflowExecutionIdentity(
                        sessionID: session.id,
                        turnID: context.conversationID,
                        attempt: 1
                    )
                ),
                failureMessage: "failed"
            )
        }
    }

    @Test("retry envelope decode rejects missing identity facts and invalid toolCall IDs")
    func retryEnvelopeDecodeIsFailClosed() async throws {
        let invalidPublicEnvelope = ChatRetryEnvelope(
            envelopeID: "invalid-public-envelope",
            inputText: "invalid",
            sessionID: "invalid-session",
            conversationID: "invalid-conversation",
            turnID: "invalid-turn",
            taskID: "invalid-task",
            attempt: 1,
            providerID: "invalid-provider",
            modelID: "invalid-model",
            configurationFingerprint: "invalid-fingerprint",
            policySnapshotID: "invalid-policy",
            grantSnapshotID: "invalid-grant",
            toolCalls: [LLMToolCall(
                id: "invalid-call",
                name: "web_search",
                rawArguments: "{}",
                arguments: [:]
            )],
            failureMessage: "invalid"
        )
        #expect(invalidPublicEnvelope.rejection == .invalidIdentity)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCore-RetryEnvelopeValidation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try makeWorkflowRuntime(
            root: root,
            sessions: SessionStore(directory: root),
            provider: WorkflowToolProvider()
        )
        #expect(await runtime.retryEnvelope(invalidPublicEnvelope).rejection == .invalidIdentity)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                ChatRetryEnvelope.self,
                from: JSONEncoder().encode(invalidPublicEnvelope)
            )
        }

        let blankPublicEnvelope = ChatRetryEnvelope(
            envelopeID: "blank-public-envelope",
            inputText: "blank",
            sessionID: " ",
            conversationID: "blank-conversation",
            turnID: "blank-turn",
            taskID: "blank-task",
            attempt: 1,
            providerID: "blank-provider",
            modelID: "blank-model",
            configurationFingerprint: "blank-fingerprint",
            policySnapshotID: "blank-policy",
            grantSnapshotID: "blank-grant",
            executionIdentity: workflowExecutionIdentity(
                sessionID: "",
                turnID: "blank-turn",
                attempt: 1
            ),
            failureMessage: "blank"
        )
        #expect(blankPublicEnvelope.rejection == .invalidIdentity)
        #expect(await runtime.retryEnvelope(blankPublicEnvelope).rejection == .invalidIdentity)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                ChatRetryEnvelope.self,
                from: JSONEncoder().encode(blankPublicEnvelope)
            )
        }

        let envelope = ChatRetryEnvelope(
            envelopeID: "decode-envelope",
            inputText: "decode",
            sessionID: "session-decode",
            conversationID: "conversation-decode",
            turnID: "turn-decode",
            taskID: "task-decode",
            attempt: 1,
            providerID: "provider-decode",
            modelID: "model-decode",
            configurationFingerprint: "fingerprint-decode",
            policySnapshotID: "policy-decode",
            grantSnapshotID: "grant-decode",
            executionIdentity: workflowExecutionIdentity(
                sessionID: "session-decode",
                turnID: "turn-decode",
                attempt: 1
            ),
            toolCalls: [LLMToolCall(
                id: "call-decode",
                name: "web_search",
                rawArguments: "{\"query\":\"decode\"}",
                arguments: ["query": "decode"]
            )],
            partialMessages: [
                LLMMessage(role: .user, content: "decode"),
                LLMMessage(
                    role: .assistant,
                    content: "",
                    toolCalls: [LLMToolCall(
                        id: "call-decode",
                        name: "web_search",
                        rawArguments: "{\"query\":\"decode\"}",
                        arguments: ["query": "decode"]
                    )]
                ),
                LLMMessage(
                    role: .tool,
                    content: "search-result",
                    toolCallID: "call-decode"
                ),
            ],
            toolExecutionFacts: [workflowFact(
                identity: workflowExecutionIdentity(
                    sessionID: "session-decode",
                    turnID: "turn-decode",
                    attempt: 1
                ),
                toolCallID: "call-decode",
                toolName: "web_search"
            )],
            failureMessage: "failed"
        )
        let data = try JSONEncoder().encode(envelope)
        let valid = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        for key in ["sessionID", "conversationID", "turnID", "taskID",
                    "providerID", "modelID", "configurationFingerprint",
                    "policySnapshotID", "grantSnapshotID", "executionIdentity"] {
            var object = valid
            object[key] = key == "executionIdentity" ? NSNull() : ""
            let invalidData = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(ChatRetryEnvelope.self, from: invalidData)
            }
        }

        var invalidAttempt = valid
        invalidAttempt["attempt"] = 0
        let invalidAttemptData = try JSONSerialization.data(withJSONObject: invalidAttempt)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ChatRetryEnvelope.self, from: invalidAttemptData)
        }
        let attemptZero = ChatRetryEnvelope(
            envelopeID: "attempt-zero",
            inputText: "attempt zero",
            sessionID: "attempt-zero-session",
            conversationID: "attempt-zero-conversation",
            turnID: "attempt-zero-turn",
            taskID: "attempt-zero-task",
            attempt: 0,
            providerID: "attempt-zero-provider",
            modelID: "attempt-zero-model",
            configurationFingerprint: "attempt-zero-fingerprint",
            policySnapshotID: "attempt-zero-policy",
            grantSnapshotID: "attempt-zero-grant",
            failureMessage: "attempt zero"
        )
        #expect(attemptZero.rejection == .invalidAttempt)
        #expect(await runtime.retryEnvelope(attemptZero).rejection == .invalidAttempt)

        var invalidCalls = valid
        invalidCalls["toolCalls"] = [[
            "id": "",
            "name": "web_search",
            "rawArguments": "{}"
        ]]
        let invalidCallData = try JSONSerialization.data(withJSONObject: invalidCalls)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ChatRetryEnvelope.self, from: invalidCallData)
        }

        var duplicateCalls = valid
        duplicateCalls["toolCalls"] = [
            ["id": "call-decode", "name": "web_search", "rawArguments": "{}"],
            ["id": "call-decode", "name": "web_search", "rawArguments": "{}"],
        ]
        let duplicateCallData = try JSONSerialization.data(withJSONObject: duplicateCalls)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ChatRetryEnvelope.self, from: duplicateCallData)
        }

        var incompleteHistory = valid
        if var partialMessages = incompleteHistory["partialMessages"] as? [[String: Any]] {
            partialMessages.removeLast()
            incompleteHistory["partialMessages"] = partialMessages
        }
        let incompleteHistoryData = try JSONSerialization.data(withJSONObject: incompleteHistory)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ChatRetryEnvelope.self, from: incompleteHistoryData)
        }
    }

    @Test("failure retry returns the frozen envelope without consulting active runtime state")
    func retryEnvelopePreservesFrozenIdentityAndToolCalls() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCore-ChatRetryEnvelope-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let sessions = SessionStore(directory: root)
        let session = try sessions.createSession(id: "retry-session", projectID: "retry-project")
        let provider = WorkflowToolProvider()
        let runtime = try makeWorkflowRuntime(
            root: root,
            sessions: sessions,
            provider: provider
        )
        let context = try await runtime.makeContext(
            sessionID: session.id,
            conversationID: "conversation-original"
        )
        let call = LLMToolCall(
            id: "call-retry-1",
            name: "web_search",
            rawArguments: "{\"query\":\"frozen\"}",
            arguments: ["query": "frozen"]
        )
        let request = ChatTurnRequest(
            text: "原始失败消息",
            context: context,
            turnID: "turn-original",
            taskID: "task-original",
            attempt: 3,
            policySnapshotID: "policy-snapshot-original",
            grantSnapshotID: "grant-snapshot-original",
            executionIdentity: workflowExecutionIdentity(
                sessionID: session.id,
                turnID: "turn-original",
                attempt: 3
            )
        )

        let envelope = try await runtime.makeRetryEnvelope(
            request: request,
            failureMessage: "provider failed",
            toolCalls: [call],
            partialMessages: [
                LLMMessage(role: .user, content: "原始失败消息"),
                LLMMessage(role: .assistant, content: "", toolCalls: [call]),
                LLMMessage(role: .tool, content: "search-result", toolCallID: call.id),
            ],
            toolExecutionFacts: [workflowFact(
                identity: workflowExecutionIdentity(
                    sessionID: session.id,
                    turnID: "turn-original",
                    attempt: 3
                ),
                toolCallID: call.id,
                toolName: call.name
            )],
            envelopeID: "retry-envelope-1",
            createdAt: Date(timeIntervalSince1970: 123)
        )
        provider.model = LLMModel(
            id: "active-model-drifted",
            displayName: "Drifted",
            provider: provider.name
        )

        let retried = await runtime.retryEnvelope(envelope)
        #expect(retried == envelope)
        #expect(retried.sessionID == "retry-session")
        #expect(retried.conversationID == "conversation-original")
        #expect(retried.turnID == "turn-original")
        #expect(retried.taskID == "task-original")
        #expect(retried.attempt == 3)
        #expect(retried.providerID == context.providerID)
        #expect(retried.modelID == context.modelID)
        #expect(retried.configurationFingerprint == context.snapshot.configurationFingerprint)
        #expect(retried.policySnapshotID == "policy-snapshot-original")
        #expect(retried.grantSnapshotID == "grant-snapshot-original")
        #expect(retried.toolCallIDs == ["call-retry-1"])
        #expect(retried.executionIdentity == request.executionIdentity)
        #expect(retried.partialMessages.map(\.role) == [.user, .assistant, .tool])

        let encoded = try JSONEncoder().encode(retried)
        let decoded = try JSONDecoder().decode(ChatRetryEnvelope.self, from: encoded)
        #expect(decoded == retried)
    }

    @Test("runtime blocks sends until startup readiness is explicitly released")
    func startupReadyGateBlocksEarlySend() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCore-ChatSessionStartupGate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let sessions = SessionStore(directory: root)
        let session = try sessions.createSession(id: "startup-session", projectID: "startup-project")
        let runtime = try makeWorkflowRuntime(
            root: root,
            sessions: sessions,
            provider: WorkflowToolProvider(),
            startupReady: false
        )
        let context = try await runtime.makeContext(sessionID: session.id)

        await #expect(throws: ChatSessionRuntimeError.startupNotReady) {
            try await runtime.send(ChatTurnRequest(
                text: "启动前不可发送",
                context: context,
                executionIdentity: workflowExecutionIdentity(
                    sessionID: session.id,
                    turnID: context.conversationID,
                    attempt: 1
                )
            ))
        }
        #expect(sessions.loadSession(id: session.id)?.messages.isEmpty == true)

        await runtime.markStartupReady()
        _ = try await runtime.send(ChatTurnRequest(
            text: "启动后可发送",
            context: context,
            executionIdentity: workflowExecutionIdentity(
                sessionID: session.id,
                turnID: context.conversationID,
                attempt: 1
            )
        ))
        #expect(sessions.loadSession(id: session.id)?.messages.isEmpty == false)
    }

    @Test("runtime persists native tool-call assistant and tool result across restart")
    func nativeToolCallHistorySurvivesRestart() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCore-ChatSessionToolCallWorkflow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let sessions = SessionStore(directory: root)
        let session = try sessions.createSession(id: "workflow-session", projectID: "workflow-project")
        let runtime = try makeWorkflowRuntime(
            root: root,
            sessions: sessions,
            provider: WorkflowToolProvider()
        )
        let context = try await runtime.makeContext(sessionID: session.id)

        let result = try await runtime.send(
            ChatTurnRequest(
                text: "搜索 MinisCanvas",
                context: context,
                executionIdentity: workflowExecutionIdentity(
                    sessionID: session.id,
                    turnID: context.conversationID,
                    attempt: 1
                )
            )
        )

        #expect(result.messages.map(\.role) == [.user, .assistant, .tool, .assistant])
        let reloaded = try #require(SessionStore(directory: root).loadSession(id: session.id))
        #expect(reloaded.messages.map(\.role) == [.user, .assistant, .tool, .assistant])
        #expect(reloaded.messages[1].toolCalls.map(\.id) == ["call-workflow-1"])
        #expect(reloaded.messages[2].toolCallID == "call-workflow-1")
        #expect(reloaded.messages[2].content == "search-result")
        #expect(result.toolExecutionFacts.count == 1)
        #expect(result.toolExecutionFacts.first?.status == .succeeded)
        #expect(result.executionIdentity?.attempt == 1)
        let reloadedFacts = try workflowLedger(root: root)
        #expect(reloadedFacts.facts == result.toolExecutionFacts)
    }

    @Test("retry envelope rejects reordered duplicate and composite-drifted facts")
    func retryEnvelopeFactsRequireOrderedCompositeIdentity() throws {
        let identity = workflowExecutionIdentity(
            sessionID: "ordered-session",
            turnID: "ordered-turn",
            attempt: 2
        )
        #expect(
            ChatRetryEnvelope.identityBinding(
                identity: identity,
                canonicalAttemptID: "attempt-ordered",
                turnID: "a|b",
                taskID: "c"
            )
            != ChatRetryEnvelope.identityBinding(
                identity: identity,
                canonicalAttemptID: "attempt-ordered",
                turnID: "a",
                taskID: "b|c"
            )
        )
        let calls = [
            LLMToolCall(
                id: "call-ordered-1",
                name: "web_search",
                rawArguments: "{\"query\":\"one\"}",
                arguments: ["query": "one"]
            ),
            LLMToolCall(
                id: "call-ordered-2",
                name: "web_search",
                rawArguments: "{\"query\":\"two\"}",
                arguments: ["query": "two"]
            ),
        ]
        let facts = calls.map {
            workflowFact(identity: identity, toolCallID: $0.id, toolName: $0.name)
        }
        let envelope = ChatRetryEnvelope(
            envelopeID: "ordered-envelope",
            inputText: "ordered",
            sessionID: identity.turn.sessionID,
            conversationID: "ordered-conversation",
            turnID: "ordered-turn",
            taskID: "ordered-task",
            attempt: identity.attempt,
            providerID: "ordered-provider",
            modelID: "ordered-model",
            configurationFingerprint: "ordered-fingerprint",
            policySnapshotID: "ordered-policy",
            grantSnapshotID: "ordered-grant",
            executionIdentity: identity,
            toolCalls: calls,
            partialMessages: [
                LLMMessage(role: .user, content: "ordered"),
                LLMMessage(role: .assistant, content: "", toolCalls: calls),
                LLMMessage(role: .tool, content: "one", toolCallID: calls[0].id),
                LLMMessage(role: .tool, content: "two", toolCallID: calls[1].id),
            ],
            toolExecutionFacts: facts,
            failureMessage: "failed"
        )
        let data = try JSONEncoder().encode(envelope)
        let valid = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        var reorderedFacts = valid
        reorderedFacts["toolExecutionFacts"] = [
            try #require((valid["toolExecutionFacts"] as? [[String: Any]])?[1]),
            try #require((valid["toolExecutionFacts"] as? [[String: Any]])?[0]),
        ]
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                ChatRetryEnvelope.self,
                from: JSONSerialization.data(withJSONObject: reorderedFacts)
            )
        }

        var duplicateFacts = valid
        duplicateFacts["toolExecutionFacts"] = [
            try #require((valid["toolExecutionFacts"] as? [[String: Any]])?[0]),
            try #require((valid["toolExecutionFacts"] as? [[String: Any]])?[0]),
        ]
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                ChatRetryEnvelope.self,
                from: JSONSerialization.data(withJSONObject: duplicateFacts)
            )
        }

        var compositeDrift = valid
        var driftedFacts = try #require(valid["toolExecutionFacts"] as? [[String: Any]])
        var driftedComposite = try #require(driftedFacts[0]["compositeKey"] as? [String: Any])
        driftedComposite["messageID"] = "drifted-message"
        driftedFacts[0]["compositeKey"] = driftedComposite
        compositeDrift["toolExecutionFacts"] = driftedFacts
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                ChatRetryEnvelope.self,
                from: JSONSerialization.data(withJSONObject: compositeDrift)
            )
        }

        var turnDrift = valid
        turnDrift["turnID"] = "other-turn"
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                ChatRetryEnvelope.self,
                from: JSONSerialization.data(withJSONObject: turnDrift)
            )
        }

        var taskDrift = valid
        taskDrift["taskID"] = "other-task"
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                ChatRetryEnvelope.self,
                from: JSONSerialization.data(withJSONObject: taskDrift)
            )
        }
    }

    @Test("child context preserves child-scoped canonical identity and ledger")
    func childContextUsesChildCanonicalIdentity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCore-ChildWorkflowIdentity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ledger = try workflowLedger(root: root)
        let controller = TurnController()
        let parentTurn = await controller.beginTurn()
        defer { Task { await parentTurn.finish() } }
        let parent = AgentContext(
            toolExecutor: WorkflowToolExecutor(),
            provider: WorkflowToolProvider(),
            tools: workflowToolCatalog(),
            turnController: controller,
            currentConversationID: "child-parent",
            parentTurnHandle: parentTurn,
            toolExecutionFactLedger: ledger,
            executionIdentity: workflowExecutionIdentity(
                sessionID: "child-parent",
                turnID: "parent-turn",
                attempt: 1
            )
        )
        let childIdentity = try ChildRuntimeIdentity.derive(
            parent: ParentRuntimeIdentity(
                sessionID: "child-parent",
                conversationID: "child-parent",
                turnID: "turn-handle:\(parentTurn.turnID)",
                taskID: "parent-task",
                actorID: "workflow-test"
            ),
            childSessionID: "child-session",
            childTaskID: "child-task",
            scopeID: "child-scope",
            requestedCapabilities: [],
            parentCapabilities: [],
            policyCapabilities: [],
            providerSnapshot: ParentContextSnapshotV1(
                providerID: "workflow-provider",
                modelID: "workflow-model",
                configurationFingerprint: "workflow-fingerprint",
                conversationID: "child-parent"
            ),
            memoryScopeID: "child-memory",
            workingDirectory: "/tmp/workflow-child",
            cancelGeneration: parentTurn.turnID,
            evidenceRoot: "child-evidence",
            parentTurnHandle: parentTurn,
            childExecutionID: "child-execution"
        )
        let childExecutionIdentity = AgentExecutionIdentity(
            turn: AgentTurnIdentity(
                sessionID: childIdentity.childSessionID,
                turnID: childIdentity.cancelGeneration,
                messageID: childIdentity.childTaskID
            ),
            operationID: try #require(childIdentity.generationID),
            attempt: 2
        )
        let child = try parent.deriveChild(
            identity: childIdentity,
            requestedCapabilities: [],
            policy: AgentCapabilityPolicy(
                allowedCapabilities: [],
                allowedToolNames: []
            ),
            budget: BudgetTracker(RequestBudget(maxRequestsPerSession: 1)),
            executionIdentity: childExecutionIdentity
        )
        #expect(child.toolExecutionFactLedger === ledger)
        #expect(child.executionIdentity == childExecutionIdentity)
        #expect(child.executionIdentity?.turn.turnID == childIdentity.cancelGeneration)
        #expect(child.executionIdentity?.attempt == 2)
        let childAttemptID = try #require(childIdentity.generationID)
        let childReceipt = try ledger.mint(
            toolCallID: "child-call",
            toolName: "web_search",
            attemptID: childAttemptID,
            attemptNumber: childExecutionIdentity.attempt,
            executionIdentity: childExecutionIdentity
        )
        _ = try ledger.settle(childReceipt, status: .succeeded)
        #expect(
            ledger.facts(
                executionIdentity: childExecutionIdentity,
                attemptID: childAttemptID,
                attemptNumber: childExecutionIdentity.attempt
            ).map(\.toolCallID) == ["child-call"]
        )
    }
}
