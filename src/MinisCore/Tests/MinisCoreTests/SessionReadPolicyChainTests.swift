import Foundation
import Testing
@testable import MinisCore

/// S3 `session_read` capability/scope hardening regression (production seam).
///
/// Production composes the executor as
/// `Recording → PolicyEnforced → Builtin(sessionManager)` (BridgeStore). The
/// policy layer must be `SessionReadCapabilityAwareToolExecutor`-transparent:
/// an explicitly authorized read must reach the builtin with its typed,
/// turn-bound capability intact, while every fail-closed boundary stays:
///
/// 1. an approved model `session_read` call must reach the builtin through the
///    policy wrapper with a typed, call-scoped capability;
/// 2. without an approval gate a model-created call is refused before any read.
private struct SessionReadChainApproveAll: ApprovalDelegate {
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        ApprovalDecision(
            approved: true, reason: "approved", confirmed: true,
            requestID: request.requestID, bindingDigest: request.identityDigest)
    }
}


private func SessionReadPolicyChainTestsSeed(for identity: AgentExecutionIdentity) -> ParentRuntimeIdentitySeed {
    ParentRuntimeIdentitySeed(
        sessionID: identity.turn.sessionID,
        conversationID: identity.turn.sessionID,
        taskID: "task:\(identity.operationID)",
        actorID: "test"
    )
}

private final class SessionReadChainCountingProvider: LLMProvider, @unchecked Sendable {
    var name: String { "SessionReadChainCounting" }
    var model = LLMModel(id: "chain-test", displayName: "Chain Test", provider: "Test")
    var capabilities: Set<ProviderCapability> { [.tools] }
    var responses: [LLMResponse]
    private(set) var callCount = 0

    init(responses: [LLMResponse] = []) {
        self.responses = responses
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        callCount += 1
        return responses.isEmpty
            ? LLMResponse(text: "完成", stopReason: nil, usage: nil)
            : responses.removeFirst()
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

private func sessionReadEnvelope(sessionID: String, id: String = "read-1") -> String {
    """
    {"tool_calls":[{"id":"\(id)","name":"session_read","input":{"session_id":"\(sessionID)","scope":"metadata"}}]}
    """
}

struct SessionReadPolicyChainTests {

    private func makeManager() throws -> (SessionManager, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCore-SessionReadPolicy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manager = SessionManager(
            store: SessionStore(directory: directory),
            badgeStore: SessionBadgeStore(directory: directory)
        )
        return (manager, directory)
    }

    /// Production-like policy layer: `PolicyEnforcedToolExecutor` over a
    /// `BuiltinToolExecutor` wired to the session manager, with `session_read`
    /// allowed by the goal (production allowlist = registered tool names).
    private func makePolicyChain(
        manager: SessionManager,
        directory: URL
    ) -> PolicyEnforcedToolExecutor {
        let builtin = BuiltinToolExecutor(allowedRoot: directory, sessionManager: manager)
        let now = Date()
        let goal = GoalEnvelope(
            scopeID: "session:test",
            allowedCapabilities: [SessionReadTool.toolName],
            fileRoots: [directory.path],
            networkDomains: [],
            budget: 100,
            deadline: now.addingTimeInterval(3600),
            concurrencyLimit: 1,
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
        return PolicyEnforcedToolExecutor(
            base: builtin,
            goal: goal,
            lease: lease,
            capabilityResolver: builtin,
            clock: { Date() }
        )
    }

    @Test func approvedReadSurvivesPolicyChain() async throws {
        let (manager, directory) = try makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        try manager.store.updateSession(ChatSession(
            id: "readable",
            title: "可读会话",
            modelID: "gpt-5"
        ))

        let policy = makePolicyChain(manager: manager, directory: directory)
        let provider = SessionReadChainCountingProvider(responses: [
            LLMResponse(text: sessionReadEnvelope(sessionID: "readable"), stopReason: "tool_calls", usage: nil),
            LLMResponse(text: "已读取", stopReason: "stop", usage: nil),
        ])
        let identity = minisCoreToolContractIdentity(
            "session-read-explicit",
            sessionID: "conversation-A"
        )
        let loop = AgentLoop(
            maxIterations: 3,
            approvalGate: ApprovalGate(delegate: SessionReadChainApproveAll()),
            turnController: TurnController(),
            loopDetector: nil,
            timeout: 30,
            toolExecutionFactLedger: try minisCoreToolContractLedger(at: directory)
        )

        let result = try await loop.run(
            messages: [LLMMessage(role: .user, content: "请查看会话 readable")],
            systemPrompt: nil,
            provider: provider,
            toolExecutor: policy,
            tools: minisCoreToolContractCatalog([SessionReadTool.toolName]),
            currentConversationID: "conversation-A",
            parentIdentitySeed: SessionReadPolicyChainTestsSeed(for: identity),
            executionIdentity: identity
        )

        // The approved read must reach the builtin — the policy
        // wrapper must not drop it to capabilityRequired.
        #expect(result.messages.contains { $0.content.contains("gpt-5") })
        #expect(policy.acceptedExecutionCount == 1)
        #expect(policy.deniedExecutionCount == 0)
    }

    @Test func modelCallWithoutApprovalGateCannotReadTarget() async throws {
        let (manager, directory) = try makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        try manager.store.updateSession(ChatSession(
            id: "victim",
            title: "机密会话",
            modelID: "secret-model"
        ))
        let victimFile = manager.store.sessionsDirectory.appendingPathComponent("victim.json")
        let victimBefore = try Data(contentsOf: victimFile)

        let policy = makePolicyChain(manager: manager, directory: directory)
        // No approval gate: a model-created call can neither mint a
        // cross-session target nor reach the reader.
        let provider = SessionReadChainCountingProvider(responses: [
            LLMResponse(text: sessionReadEnvelope(sessionID: "victim"), stopReason: "tool_calls", usage: nil),
            LLMResponse(text: "完成", stopReason: "stop", usage: nil),
        ])
        let identity = minisCoreToolContractIdentity(
            "session-read-model-text",
            sessionID: "conversation-A"
        )
        let loop = AgentLoop(
            maxIterations: 3,
            turnController: TurnController(),
            loopDetector: nil,
            toolExecutionFactLedger: try minisCoreToolContractLedger(at: directory)
        )

        let result = try await loop.run(
            messages: [LLMMessage(role: .user, content: "你好")],
            systemPrompt: nil,
            provider: provider,
            toolExecutor: policy,
            tools: minisCoreToolContractCatalog([SessionReadTool.toolName]),
            currentConversationID: "conversation-A",
            executionIdentity: identity
        )

        // The victim's data never surfaces and the boundary error is reported.
        #expect(result.messages.contains {
            $0.content.contains("机密会话") || $0.content.contains("secret-model")
        } == false)
        let refusal = "Error executing tool session_read: \(ToolExecutorError.approvalRequired(SessionReadTool.toolName).localizedDescription)"
        // The legacy envelope route serializes the tool result into a user-role
        // protocol block; the provider's final "完成" is deliberately not a refusal.
        #expect(result.messages.contains { $0.content.contains(refusal) })
        #expect(provider.callCount == 2)
        #expect(policy.acceptedExecutionCount == 0)
        #expect(policy.deniedExecutionCount == 0)
        #expect(try Data(contentsOf: victimFile) == victimBefore)
    }

    @Test func wrongConversationContextIsRejectedThroughPolicyChain() async throws {
        let (manager, directory) = try makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        try manager.store.updateSession(ChatSession(id: "readable", title: "可读会话"))

        let policy = makePolicyChain(manager: manager, directory: directory)
        let authorization = CrossSessionReadAuthorization.issue(
            currentConversationID: "conversation-A",
            authorizedSessionID: "readable",
            turnID: 7,
            issuedAt: Date(timeIntervalSince1970: 1_000),
            lifetime: 60
        )

        // The capability is bound to conversation-A; a read executed in the
        // context of conversation-B must fail through the whole chain and must
        // not fall back to the legacy untyped path.
        await #expect(throws: CrossSessionReadAuthorizationError.conversationMismatch) {
            _ = try await policy.executeSessionRead(
                input: ["session_id": "readable", "scope": "metadata"],
                authorization: authorization,
                context: SessionReadExecutionContext(
                    currentConversationID: "conversation-B",
                    turnID: 7
                ),
                now: Date(timeIntervalSince1970: 1_010)
            )
        }
        // The mismatch permanently invalidates the capability: even a later
        // attempt with the original conversation context stays rejected.
        #expect(authorization.isActive == false)
        #expect(authorization.invalidationReason == .conversationChanged)
    }

    @Test func stoppedCapabilityCannotBeReauthorizedThroughPolicyChain() async throws {
        let (manager, directory) = try makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        try manager.store.updateSession(ChatSession(id: "readable", title: "可读会话"))

        let policy = makePolicyChain(manager: manager, directory: directory)
        let now = Date(timeIntervalSince1970: 2_000)
        let authorization = CrossSessionReadAuthorization.issue(
            currentConversationID: "conversation-A",
            authorizedSessionID: "readable",
            turnID: 8,
            issuedAt: now,
            lifetime: 60,
            scope: .metadata
        )
        let input: [String: Any] = [
            "session_id": "readable",
            "scope": "metadata",
        ]

        await #expect(throws: CrossSessionReadAuthorizationError.stopped) {
            _ = try await policy.executeSessionRead(
                input: input,
                authorization: authorization,
                context: SessionReadExecutionContext(
                    currentConversationID: "conversation-A",
                    turnID: 8,
                    isStopped: true
                ),
                now: now
            )
        }
        #expect(authorization.isActive == false)
        #expect(authorization.invalidationReason == .stopped)
        await #expect(throws: CrossSessionReadAuthorizationError.stopped) {
            _ = try await policy.executeSessionRead(
                input: input,
                authorization: authorization,
                context: SessionReadExecutionContext(
                    currentConversationID: "conversation-A",
                    turnID: 8
                ),
                now: now
            )
        }
    }

    @Test func policyChainRejectsScopeSubstitutionBeforeReading() async throws {
        let (manager, directory) = try makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        try manager.store.updateSession(ChatSession(id: "readable", title: "可读会话"))

        let policy = makePolicyChain(manager: manager, directory: directory)
        let now = Date(timeIntervalSince1970: 3_000)
        let authorization = CrossSessionReadAuthorization.issue(
            currentConversationID: "conversation-A",
            authorizedSessionID: "readable",
            turnID: 9,
            issuedAt: now,
            lifetime: 60,
            scope: .metadata
        )
        await #expect(throws: CrossSessionReadAuthorizationError.scopeNotAuthorized) {
            _ = try await policy.executeSessionRead(
                input: ["session_id": "readable", "scope": "messages"],
                authorization: authorization,
                context: SessionReadExecutionContext(
                    currentConversationID: "conversation-A",
                    turnID: 9
                ),
                now: now
            )
        }
        #expect(authorization.isActive)
    }

    @Test func policyChainRejectsInvalidCapabilityIdentity() async throws {
        let (manager, directory) = try makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        try manager.store.updateSession(ChatSession(id: "readable", title: "可读会话"))

        let policy = makePolicyChain(manager: manager, directory: directory)
        let now = Date(timeIntervalSince1970: 4_000)
        let authorization = CrossSessionReadAuthorization.issue(
            currentConversationID: "conversation-A",
            authorizedSessionID: " \t",
            turnID: 10,
            issuedAt: now,
            lifetime: 60
        )
        await #expect(throws: CrossSessionReadAuthorizationError.invalidIdentity) {
            _ = try await policy.executeSessionRead(
                input: ["session_id": "readable", "scope": "metadata"],
                authorization: authorization,
                context: SessionReadExecutionContext(
                    currentConversationID: "conversation-A",
                    turnID: 10
                ),
                now: now
            )
        }
    }
}
