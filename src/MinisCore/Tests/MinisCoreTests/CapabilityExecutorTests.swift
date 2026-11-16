import Foundation
import Testing
@testable import MinisCore

private final class CapabilityExecutorProvider: LLMProvider, @unchecked Sendable {
    var name: String { "CapabilityExecutorProvider" }
    var model: LLMModel = .claudeHaiku45
    var capabilities: Set<ProviderCapability> { [.tools] }
    var responses: [String]

    init(responses: [String]) {
        self.responses = responses
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        LLMResponse(
            text: responses.isEmpty ? "done" : responses.removeFirst(),
            stopReason: nil,
            usage: nil
        )
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

private final class CapabilityAwareCountingExecutor:
    SessionReadCapabilityAwareToolExecutor,
    @unchecked Sendable
{
    private(set) var callCount = 0

    func execute(name: String, input: [String: Any]) async throws -> String {
        throw ToolExecutorError.unknownTool(name)
    }

    func executeSessionRead(
        input: [String: Any],
        authorization: CrossSessionReadAuthorization,
        context: SessionReadExecutionContext,
        now: Date
    ) async throws -> String {
        callCount += 1
        return "ok"
    }
}

private struct CapabilityExecutorApproveAll: ApprovalDelegate {
    var allow = true
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        ApprovalDecision(
            approved: allow, reason: allow ? "approved" : "denied", confirmed: allow,
            requestID: request.requestID, bindingDigest: request.identityDigest)
    }
}


private func CapabilityExecutorTestsSeed(for identity: AgentExecutionIdentity) -> ParentRuntimeIdentitySeed {
    ParentRuntimeIdentitySeed(
        sessionID: identity.turn.sessionID,
        conversationID: identity.turn.sessionID,
        taskID: "task:\(identity.operationID)",
        actorID: "test"
    )
}

struct CapabilityExecutorTests {
    @Test("provider manifest grants typed capabilities and rejects unknown or descriptive claims")
    func capabilityManifestAuthorizationIsTypedAndFailClosed() throws {
        let manifest = CapabilityManifest(
            providerID: "provider-a",
            capabilities: [.streaming, .tools]
        )

        let typed = manifest.authorizationSnapshot(required: [.tools])
        #expect(typed.isAuthorized)
        #expect(typed.allows(.tools))
        #expect(typed.rejectedClaims.isEmpty)

        let mixed = manifest.authorizationSnapshot(rawClaims: ["tools", "future_capability"])
        #expect(!mixed.isAuthorized)
        #expect(mixed.allows(.tools))
        #expect(mixed.rejectedClaims == ["future_capability"])

        let descriptive = manifest.authorizationSnapshot(claims: [
            .description("supports tools and browsing")
        ])
        #expect(!descriptive.isAuthorized)
        #expect(descriptive.grantedCapabilities.isEmpty)
        #expect(descriptive.rejectedClaims == ["supports tools and browsing"])

        #expect(throws: CapabilityManifestError.unknownCapability("future_capability")) {
            _ = try manifest.validatedAuthorizationSnapshot(rawClaims: ["tools", "future_capability"])
        }
    }

    @Test("production provider capability query consumes the manifest decision")
    func providerCapabilityQueryUsesManifest() {
        let provider = CapabilityExecutorProvider(responses: [])
        #expect(provider.supportsDeclaredCapability(.tools))
        #expect(!provider.supportsDeclaredCapability(.vision))
        #expect(provider.capabilityAuthorizationSnapshot.manifestHash == provider.capabilityManifest.hash)
    }

    private func envelope(
        id: String,
        name: String = SessionReadTool.toolName,
        input: [String: Any]
    ) -> String {
        let object: [String: Any] = [
            "tool_calls": [["id": id, "name": name, "input": input]]
        ]
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)!
    }

    private func run(
        root: URL,
        response: String,
        allow: Bool = true,
        executor: any ToolExecutor = CapabilityAwareCountingExecutor()
    ) async throws -> (AgentLoopResult, ToolExecutionFactLedger, AgentExecutionIdentity, CapabilityAwareCountingExecutor?) {
        let identity = minisCoreToolContractIdentity(
            "capability-guard-before-mint",
            sessionID: "conversation-A"
        )
        let ledger = try minisCoreToolContractLedger(at: root)
        let turnController = TurnController()
        let loop = AgentLoop(
            maxIterations: 2,
            approvalGate: ApprovalGate(delegate: CapabilityExecutorApproveAll(allow: allow)),
            turnController: turnController,
            timeout: 30,
            toolExecutionFactLedger: ledger
        )
        let result = try await loop.run(
            messages: [LLMMessage(role: .user, content: "read")],
            systemPrompt: nil,
            provider: CapabilityExecutorProvider(responses: [response, "done"]),
            toolExecutor: executor,
            tools: minisCoreToolContractCatalog([SessionReadTool.toolName]),
            maxTokens: 256,
            currentConversationID: "conversation-A",
            parentIdentitySeed: CapabilityExecutorTestsSeed(for: identity),
            executionIdentity: identity
        )
        return (result, ledger, identity, executor as? CapabilityAwareCountingExecutor)
    }

    private func facts(
        _ ledger: ToolExecutionFactLedger,
        identity: AgentExecutionIdentity
    ) -> [ToolExecutionFact] {
        guard let attemptID = AgentToolExecutionAttemptID.canonical(
            executionIdentity: identity,
            composerSnapshot: nil,
            childBoundary: nil
        ) else {
            return []
        }
        return ledger.facts(
            executionIdentity: identity,
            attemptID: attemptID,
            attemptNumber: identity.attempt
        )
    }

    @Test
    func deniedApprovalMintsNoToolReceiptBeforeExecution() async throws {
        let root = try minisCoreToolContractRoot("approval-denied")
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = CapabilityAwareCountingExecutor()
        let (_, ledger, identity, _) = try await run(
            root: root,
            response: envelope(
                id: "denied-call",
                input: ["session_id": "target", "scope": "metadata"]
            ),
            allow: false,
            executor: executor
        )

        #expect(executor.callCount == 0)
        #expect(facts(ledger, identity: identity).isEmpty)
    }

    @Test
    func forgedToolNameMintsNoReceipt() async throws {
        let root = try minisCoreToolContractRoot("forged-tool")
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, ledger, identity, _) = try await run(
            root: root,
            response: envelope(
                id: "forged-call",
                name: "forged_tool",
                input: [:]
            )
        )

        #expect(facts(ledger, identity: identity).isEmpty)
    }

    @Test
    func approvedCallMintsCapabilityAndExactlyOneReceipt() async throws {
        let root = try minisCoreToolContractRoot("capability-valid")
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = CapabilityAwareCountingExecutor()
        let (_, ledger, identity, typedExecutor) = try await run(
            root: root,
            response: envelope(
                id: "valid-call",
                input: ["session_id": "target", "scope": "metadata"]
            ),
            executor: executor
        )

        #expect(typedExecutor === executor)
        #expect(executor.callCount == 1)
        #expect(facts(ledger, identity: identity).count == 1)
    }
}
