import Foundation
import Testing
@testable import MinisCore

// A 线先行契约测试：这些测试描述执行层授权、预算结算、回合隔离和
// 异步写回身份的最小行为。实现前应先以失败证据落盘。

private final class ALineCountingProvider: LLMProvider, @unchecked Sendable {
    var name: String { "A-Line-Counting" }
    var model = LLMModel(id: "a-line", displayName: "A Line", provider: "Test")
    var capabilities: Set<ProviderCapability> { [.tools] }
    var responses: [LLMResponse]
    var failure: Error?
    private(set) var callCount = 0

    init(responses: [LLMResponse] = [], failure: Error? = nil) {
        self.responses = responses
        self.failure = failure
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        callCount += 1
        if let failure { throw failure }
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

private struct ALineNoopExecutor: ToolExecutor, Sendable {
    func execute(name: String, input: [String: Any]) async throws -> String { "ok" }
}

private struct ALineProviderFailure: Error, Equatable {}

private enum ALineTestTimeout: Error {
    case providerCalls
}

private actor ALineProviderReleaseGate {
    private(set) var callCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func waitForRelease() async {
        callCount += 1
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func releaseAll() {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private final class ALineBlockingProvider: LLMProvider, @unchecked Sendable {
    let name = "A-Line-Blocking"
    var model = LLMModel(id: "a-line-blocking", displayName: "A Line Blocking", provider: "Test")
    let gate: ALineProviderReleaseGate

    init(gate: ALineProviderReleaseGate) {
        self.gate = gate
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        await gate.waitForRelease()
        return LLMResponse(text: "完成", stopReason: nil, usage: nil)
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

private func waitForProviderCalls(
    _ gate: ALineProviderReleaseGate,
    count: Int
) async throws {
    for _ in 0..<2_000 {
        if await gate.callCount >= count { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw ALineTestTimeout.providerCalls
}

struct ALineCapabilityContractTests {

    private func makeManager() throws -> (SessionManager, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MinisCore-A-Line-Session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manager = SessionManager(
            store: SessionStore(directory: directory),
            badgeStore: SessionBadgeStore(directory: directory)
        )
        return (manager, directory)
    }

    private func context(
        conversationID: String = "conversation-A",
        turnID: Int = 7,
        stopped: Bool = false
    ) -> SessionReadExecutionContext {
        SessionReadExecutionContext(
            currentConversationID: conversationID,
            turnID: turnID,
            isStopped: stopped
        )
    }

    private func capability(
        currentConversationID: String = "conversation-A",
        authorizedSessionID: String = "conversation-A",
        turnID: Int = 7,
        issuedAt: Date = Date(timeIntervalSince1970: 1_000),
        expiresAt: Date = Date(timeIntervalSince1970: 1_060)
    ) -> CrossSessionReadAuthorization {
        CrossSessionReadAuthorization(
            currentConversationID: currentConversationID,
            authorizedSessionID: authorizedSessionID,
            turnID: turnID,
            issuedAt: issuedAt,
            expiresAt: expiresAt
        )
    }

    @Test func sessionReadWithoutExplicitCapabilityIsRejected() throws {
        let (manager, directory) = try makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: CrossSessionReadAuthorizationError.capabilityRequired) {
            _ = try SessionReadTool.read(
                input: ["session_id": "conversation-A", "scope": "metadata"],
                manager: manager
            )
        }
    }

    @Test func capabilityAllowsAReadAButRejectsAReadB() throws {
        let (manager, directory) = try makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        try manager.store.updateSession(ChatSession(id: "conversation-A", title: "A"))
        try manager.store.updateSession(ChatSession(id: "conversation-B", title: "B"))

        let authorization = capability()
        let output = try SessionReadTool.read(
            input: ["session_id": "conversation-A", "scope": "metadata"],
            manager: manager,
            authorization: authorization,
            context: context(),
            now: Date(timeIntervalSince1970: 1_010)
        )
        #expect(output.contains("conversation-A"))

        #expect(throws: CrossSessionReadAuthorizationError.sessionNotAuthorized) {
            _ = try SessionReadTool.read(
                input: ["session_id": "conversation-B", "scope": "metadata"],
                manager: manager,
                authorization: authorization,
                context: context(),
                now: Date(timeIntervalSince1970: 1_010)
            )
        }
    }

    @Test func expiredStoppedAndEndedTurnCapabilitiesAreRejected() throws {
        let (manager, directory) = try makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        try manager.store.updateSession(ChatSession(id: "conversation-A", title: "A"))
        let input: [String: Any] = ["session_id": "conversation-A", "scope": "metadata"]

        #expect(throws: CrossSessionReadAuthorizationError.expired) {
            _ = try SessionReadTool.read(
                input: input,
                manager: manager,
                authorization: capability(expiresAt: Date(timeIntervalSince1970: 1_001)),
                context: context(),
                now: Date(timeIntervalSince1970: 1_002)
            )
        }

        let stopped = capability()
        stopped.invalidate(reason: .stopped)
        #expect(throws: CrossSessionReadAuthorizationError.stopped) {
            _ = try SessionReadTool.read(
                input: input,
                manager: manager,
                authorization: stopped,
                context: context(stopped: true),
                now: Date(timeIntervalSince1970: 1_010)
            )
        }

        let ended = capability()
        ended.invalidate(reason: .turnEnded)
        #expect(throws: CrossSessionReadAuthorizationError.turnEnded) {
            _ = try SessionReadTool.read(
                input: input,
                manager: manager,
                authorization: ended,
                context: context(),
                now: Date(timeIntervalSince1970: 1_010)
            )
        }
    }

    @Test func modelInputCannotSupplyOrReplaceAuthorization() throws {
        let (manager, directory) = try makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        try manager.store.updateSession(ChatSession(id: "conversation-A", title: "A"))

        #expect(throws: CrossSessionReadAuthorizationError.capabilityRequired) {
            _ = try SessionReadTool.read(
                input: [
                    "session_id": "conversation-A",
                    "scope": "metadata",
                    "authorization": "forged-model-token",
                ],
                manager: manager
            )
        }
    }

    @Test func turnControllerStopsOnlyTheTargetTurnAndInvalidatesItsCapability() async throws {
        let controller = TurnController()
        let first = await controller.beginTurn()
        let second = await controller.beginTurn()
        let firstCapability = await first.issueSessionReadAuthorization(
            currentConversationID: "A",
            authorizedSessionID: "A",
            issuedAt: Date(timeIntervalSince1970: 1_000),
            expiresAt: Date(timeIntervalSince1970: 1_060)
        )
        let secondCapability = await second.issueSessionReadAuthorization(
            currentConversationID: "B",
            authorizedSessionID: "B",
            issuedAt: Date(timeIntervalSince1970: 1_000),
            expiresAt: Date(timeIntervalSince1970: 1_060)
        )

        await first.interrupt()
        #expect(await first.isCancelled())
        #expect(await second.isCancelled() == false)
        #expect(firstCapability.isActive == false)
        #expect(secondCapability.isActive)

        await first.finish()
        #expect(await second.isCancelled() == false)
        await second.finish()
        #expect(secondCapability.isActive == false)
    }

    @Test func resetRevokesCapabilitiesForEveryActiveTurn() async {
        let controller = TurnController()
        let first = await controller.beginTurn()
        let second = await controller.beginTurn()
        let firstCapability = await first.issueSessionReadAuthorization(
            currentConversationID: "A",
            authorizedSessionID: "A",
            issuedAt: Date(timeIntervalSince1970: 1_000),
            expiresAt: Date(timeIntervalSince1970: 1_060)
        )
        let secondCapability = await second.issueSessionReadAuthorization(
            currentConversationID: "B",
            authorizedSessionID: "B",
            issuedAt: Date(timeIntervalSince1970: 1_000),
            expiresAt: Date(timeIntervalSince1970: 1_060)
        )

        await controller.reset()

        #expect(firstCapability.isActive == false)
        #expect(firstCapability.invalidationReason == .revoked)
        #expect(secondCapability.isActive == false)
        #expect(secondCapability.invalidationReason == .revoked)
        await first.finish()
        await second.finish()
    }

    @Test func switchingConversationInvalidatesCapability() throws {
        let (manager, directory) = try makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        let authorization = capability()

        #expect(throws: CrossSessionReadAuthorizationError.conversationMismatch) {
            _ = try SessionReadTool.read(
                input: ["session_id": "conversation-A", "scope": "metadata"],
                manager: manager,
                authorization: authorization,
                context: context(conversationID: "conversation-B"),
                now: Date(timeIntervalSince1970: 1_010)
            )
        }
        #expect(authorization.isActive == false)
        #expect(authorization.invalidationReason == .conversationChanged)

        #expect(throws: CrossSessionReadAuthorizationError.conversationChanged) {
            _ = try SessionReadTool.read(
                input: ["session_id": "conversation-A", "scope": "metadata"],
                manager: manager,
                authorization: authorization,
                context: context(),
                now: Date(timeIntervalSince1970: 1_010)
            )
        }
    }

    @Test func writebackIdentityRequiresExactSessionTurnAndMessageMatch() async {
        let registry = AgentTurnWritebackRegistry()
        let first = AgentTurnIdentity(sessionID: "A", turnID: 1, messageID: "m1")
        let otherMessage = AgentTurnIdentity(sessionID: "A", turnID: 1, messageID: "m2")
        let otherTurn = AgentTurnIdentity(sessionID: "A", turnID: 2, messageID: "m1")
        let otherSession = AgentTurnIdentity(sessionID: "B", turnID: 1, messageID: "m1")

        await registry.begin(first)
        #expect(await registry.accepts(first))
        #expect(await registry.accepts(otherMessage) == false)
        #expect(await registry.accepts(otherTurn) == false)
        #expect(await registry.accepts(otherSession) == false)

        await registry.finish(first)
        #expect(await registry.accepts(first) == false)
    }

    @Test func finishedWritebackIdentityCannotBeResumed() async {
        let registry = AgentTurnWritebackRegistry()
        let identity = AgentTurnIdentity(sessionID: "A", turnID: 1, messageID: "m1")

        await registry.begin(identity)
        await registry.finish(identity)
        await registry.begin(identity)

        #expect(await registry.accepts(identity) == false)
    }

    @Test func agentLoopRoutesApprovedSessionReadThroughTypedCapability() async throws {
        let (manager, directory) = try makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        try manager.store.updateSession(ChatSession(
            id: "readable",
            title: "可读会话",
            modelID: "gpt-5"
        ))

        let envelope = """
        {"tool_calls":[{"id":"read-1","name":"session_read","input":{"session_id":"readable","scope":"metadata"}}]}
        """
        let provider = ALineCountingProvider(responses: [
            LLMResponse(text: envelope, stopReason: "tool_calls", usage: nil),
            LLMResponse(text: "已读取", stopReason: "stop", usage: nil),
        ])
        let controller = TurnController()
        let identity = minisCoreToolContractIdentity(
            "agent-core-session-read",
            sessionID: "conversation-A"
        )
        let loop = AgentLoop(
            maxIterations: 3,
            approvalGate: ApprovalGate(delegate: AgentCoreSessionReadApproveAll()),
            turnController: controller,
            loopDetector: nil,
            timeout: 30,
            toolExecutionFactLedger: try minisCoreToolContractLedger(at: directory)
        )
        let executor = BuiltinToolExecutor(
            allowedRoot: directory,
            sessionManager: manager
        )

        let result = try await loop.run(
            messages: [LLMMessage(role: .user, content: "授权查看 readable")],
            systemPrompt: nil,
            provider: provider,
            toolExecutor: executor,
            tools: minisCoreToolContractCatalog([SessionReadTool.toolName]),
            currentConversationID: "conversation-A",
            parentIdentitySeed: AgentCoreContractTestsSeed(for: identity),
            executionIdentity: identity
        )
        #expect(result.messages.contains { $0.content.contains("gpt-5") })
    }
}


private func AgentCoreContractTestsSeed(for identity: AgentExecutionIdentity) -> ParentRuntimeIdentitySeed {
    ParentRuntimeIdentitySeed(
        sessionID: identity.turn.sessionID,
        conversationID: identity.turn.sessionID,
        taskID: "task:\(identity.operationID)",
        actorID: "test"
    )
}

private struct AgentCoreSessionReadApproveAll: ApprovalDelegate {
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        ApprovalDecision(
            approved: true, reason: "approved", confirmed: true,
            requestID: request.requestID, bindingDigest: request.identityDigest)
    }
}

struct ALineBudgetContractTests {

    @Test func resetInvalidatesInFlightLeaseFromPreviousSession() async throws {
        let tracker = BudgetTracker(RequestBudget(
            maxRequestsPerSession: 1,
            maxTokensPerSession: 100,
            overBudgetPolicy: .pause
        ))
        let oldLease = try await tracker.beginRequest()

        await tracker.reset()
        #expect(await tracker.completeRequest(
            oldLease,
            usage: LLMUsage(inputTokens: 10, outputTokens: 5)
        ) == nil)
        let budgetAfterReset = await tracker.budget
        #expect(budgetAfterReset.usedRequests == 0)
        #expect(budgetAfterReset.usedTokens == 0)

        _ = try await tracker.beginRequest()
    }

    @Test func productionBudgetDefaultsToPause() {
        #expect(RequestBudget().overBudgetPolicy == .pause)
    }

    @Test func failedProviderCallWithNoUsageDoesNotChargeBudget() async throws {
        let tracker = BudgetTracker(RequestBudget(maxRequestsPerSession: 3, maxTokensPerSession: 100, overBudgetPolicy: .pause))
        let provider = ALineCountingProvider(failure: ALineProviderFailure())
        let loop = AgentLoop(maxIterations: 2, loopDetector: nil, requestBudget: tracker)

        await #expect(throws: ALineProviderFailure.self) {
            _ = try await loop.run(
                messages: [LLMMessage(role: .user, content: "失败" )],
                systemPrompt: nil,
                provider: provider,
                toolExecutor: ALineNoopExecutor(),
                tools: []
            )
        }
        let budget = await tracker.budget
        #expect(provider.callCount == 1)
        #expect(budget.usedRequests == 0)
        #expect(budget.usedTokens == 0)
    }

    @Test func canceledInFlightProviderResponseReleasesLeaseBeforeSettlement() async throws {
        let tracker = BudgetTracker(RequestBudget(
            maxRequestsPerSession: 3,
            maxTokensPerSession: 100,
            overBudgetPolicy: .pause
        ))
        let controller = TurnController()
        let gate = ALineProviderReleaseGate()
        let provider = ALineBlockingProvider(gate: gate)
        let loop = AgentLoop(
            maxIterations: 1,
            turnController: controller,
            loopDetector: nil,
            requestBudget: tracker
        )

        let task = Task {
            try await loop.run(
                messages: [LLMMessage(role: .user, content: "取消中的迟到响应")],
                systemPrompt: nil,
                provider: provider,
                toolExecutor: ALineNoopExecutor(),
                tools: []
            )
        }
        try await waitForProviderCalls(gate, count: 1)

        await controller.interrupt(turnID: 1)
        await gate.releaseAll()

        await #expect(throws: InterruptedError.self) {
            _ = try await task.value
        }
        let budget = await tracker.budget
        #expect(budget.usedRequests == 0)
        #expect(budget.usedTokens == 0)
    }

    @Test func autoCompactDoesNotMakeAnExtraProviderRequest() async throws {
        let tracker = BudgetTracker(RequestBudget(maxTokensPerSession: 1, overBudgetPolicy: .autoCompact))
        let provider = ALineCountingProvider(responses: [
            LLMResponse(text: "完成", stopReason: nil, usage: LLMUsage(inputTokens: 1, outputTokens: 1)),
        ])
        let loop = AgentLoop(
            maxIterations: 2,
            loopDetector: nil,
            requestBudget: tracker,
            compactor: Compactor(keepRecentMessages: 0)
        )

        _ = try await loop.run(
            messages: Array(repeating: LLMMessage(role: .user,
                content: "Repeated ordinary chat context with one exact constraint."), count: 40),
            systemPrompt: nil,
            provider: provider,
            toolExecutor: ALineNoopExecutor(),
            tools: []
        )
        #expect(provider.callCount == 1)
    }

    @Test func stoppingOneConcurrentLoopLeavesSiblingTurnRunning() async throws {
        let controller = TurnController()
        let gate = ALineProviderReleaseGate()
        let provider = ALineBlockingProvider(gate: gate)
        let loop = AgentLoop(maxIterations: 1, turnController: controller, loopDetector: nil)
        let initialMessages = [LLMMessage(role: .user, content: "并发回合")]

        let firstTask = Task {
            try await loop.run(
                messages: initialMessages,
                systemPrompt: nil,
                provider: provider,
                toolExecutor: ALineNoopExecutor(),
                tools: []
            )
        }
        try await waitForProviderCalls(gate, count: 1)

        let secondTask = Task {
            try await loop.run(
                messages: initialMessages,
                systemPrompt: nil,
                provider: provider,
                toolExecutor: ALineNoopExecutor(),
                tools: []
            )
        }
        try await waitForProviderCalls(gate, count: 2)

        await controller.interrupt(turnID: 1)
        await gate.releaseAll()

        await #expect(throws: InterruptedError.self) {
            _ = try await firstTask.value
        }
        let secondResult = try await secondTask.value
        #expect(secondResult.iterationCount == 1)
        #expect(secondResult.messages.last?.content == "完成")
        #expect(await controller.isRunning == false)
    }
}
