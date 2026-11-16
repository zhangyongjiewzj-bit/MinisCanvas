import Foundation
import Testing
@testable import MinisCore

@Suite("R34 child lifecycle")
struct R34ChildLifecycleTests {

    @Test("child catalog is the parent and policy capability intersection")
    func childCatalogDoesNotRecreateParentPermissions() async throws {
        let controller = TurnController()
        let parentTurn = await controller.beginTurn()
        defer { Task { await parentTurn.finish() } }

        let provider = R34Provider(
            capabilities: [.streaming, .tools],
            responses: ["done"]
        )
        let parentTools = [
            r34Tool("file_read"),
            r34Tool("file_write"),
        ]
        let parent = AgentContext(
            toolExecutor: R34RecordingExecutor(),
            provider: provider,
            tools: parentTools,
            turnController: controller,
            currentConversationID: "r34-parent-conversation",
            parentTurnHandle: parentTurn,
        )
        let identity = try r34Identity(parentTurn: parentTurn, execution: "1")

        let child = try parent.deriveChild(
            identity: identity,
            requestedCapabilities: [.tools],
            policy: AgentCapabilityPolicy(
                allowedCapabilities: [.streaming, .tools],
                allowedToolNames: ["file_read", "shell_execute"]
            ),
            budget: BudgetTracker(RequestBudget(maxRequestsPerSession: 2))
        )

        #expect(child.tools.map(\.name) == ["file_read"])
        #expect(child.childBoundary?.grantedCapabilities == [.tools])
        #expect(child.childBoundary?.identity.childTaskID == "child-1")
        #expect(child.childBoundary?.identity.parentTaskID == "r34-parent")
    }

    @Test("empty child tool intersection fails closed before provider execution")
    func emptyChildCatalogCannotBecomeSuccessfulWithToolsEmpty() async throws {
        let controller = TurnController()
        let parentTurn = await controller.beginTurn()
        defer { Task { await parentTurn.finish() } }

        let provider = R34Provider(
            capabilities: [.streaming, .tools],
            responses: [r34ToolEnvelope(name: "file_read"), "done"]
        )
        let executor = R34RecordingExecutor()
        let parent = AgentContext(
            toolExecutor: executor,
            provider: provider,
            tools: [r34Tool("file_read")],
            turnController: controller,
            currentConversationID: "r34-parent-conversation",
            parentTurnHandle: parentTurn,
        )
        let identity = try r34Identity(parentTurn: parentTurn, execution: "child-empty")

        #expect(throws: AgentChildLifecycleError.self) {
            _ = try parent.deriveChild(
                identity: identity,
                requestedCapabilities: [.tools],
                policy: AgentCapabilityPolicy(
                    allowedCapabilities: [.streaming, .tools],
                    allowedToolNames: []
                ),
                budget: BudgetTracker(RequestBudget(maxRequestsPerSession: 2))
            )
        }
        #expect(provider.callCount == 0)
        #expect(await executor.names.isEmpty)
    }

    @Test("unknown child capability never reaches the parent executor")
    func unknownToolIsRejectedByChildBoundary() async throws {
        let controller = TurnController()
        let parentTurn = await controller.beginTurn()
        defer { Task { await parentTurn.finish() } }

        let provider = R34Provider(
            capabilities: [.streaming, .tools],
            responses: [r34ToolEnvelope(name: "shell_execute"), "done"]
        )
        let executor = R34RecordingExecutor()
        let parent = AgentContext(
            toolExecutor: executor,
            provider: provider,
            tools: [r34Tool("file_read")],
            turnController: controller,
            currentConversationID: "r34-parent-conversation",
            parentTurnHandle: parentTurn,
        )
        let identity = try r34Identity(parentTurn: parentTurn, execution: "child-unknown")
        var child = try parent.deriveChild(
            identity: identity,
            requestedCapabilities: [.tools],
            policy: AgentCapabilityPolicy(
                allowedCapabilities: [.streaming, .tools],
                allowedToolNames: ["file_read"]
            ),
            budget: BudgetTracker(RequestBudget(maxRequestsPerSession: 3))
        )

        _ = try await child.run(userMessage: "read")

        #expect(await executor.names.isEmpty)
        #expect(provider.offeredToolNames == [["file_read"], ["file_read"]])
    }

    @Test("a child without the tools grant cannot inherit parent tools")
    func missingToolsCapabilityProducesNoChildCatalog() async throws {
        let controller = TurnController()
        let parentTurn = await controller.beginTurn()
        defer { Task { await parentTurn.finish() } }

        let provider = R34Provider(
            capabilities: [.streaming, .tools],
            responses: [r34ToolEnvelope(name: "file_read"), "done"]
        )
        let executor = R34RecordingExecutor()
        let parent = AgentContext(
            toolExecutor: executor,
            provider: provider,
            tools: [r34Tool("file_read")],
            turnController: controller,
            currentConversationID: "r34-parent-conversation",
            parentTurnHandle: parentTurn
        )
        let identity = try r34Identity(
            parentTurn: parentTurn,
            execution: "streaming-only",
            requestedCapabilities: [.streaming]
        )
        var child = try parent.deriveChild(
            identity: identity,
            requestedCapabilities: [.streaming],
            policy: AgentCapabilityPolicy(
                allowedCapabilities: [.streaming, .tools],
                allowedToolNames: ["file_read"]
            ),
            budget: BudgetTracker(RequestBudget(maxRequestsPerSession: 3))
        )

        _ = try await child.run(userMessage: "no tools")

        #expect(child.tools.isEmpty)
        #expect(provider.offeredToolNames == [[], []])
        #expect(await executor.names.isEmpty)
    }

    @Test("unknown raw child capability fails closed")
    func unknownCapabilityFailsClosed() {
        #expect(throws: AgentChildLifecycleError.unknownCapability("network_admin")) {
            _ = try AgentChildLifecycleError.resolveCapabilities(["network_admin"])
        }
    }

    @Test("a nested child cannot regain a capability absent from its parent grant")
    func nestedChildCannotRegainParentCapability() async throws {
        let controller = TurnController()
        let parentTurn = await controller.beginTurn()
        defer { Task { await parentTurn.finish() } }

        let provider = R34Provider(
            capabilities: [.streaming, .tools],
            responses: ["done"]
        )
        let parent = AgentContext(
            toolExecutor: R34RecordingExecutor(),
            provider: provider,
            tools: [r34Tool("file_read")],
            turnController: controller,
            currentConversationID: "r34-parent-conversation",
            parentTurnHandle: parentTurn
        )
        let childIdentity = try r34Identity(parentTurn: parentTurn, execution: "nested-parent")
        let child = try parent.deriveChild(
            identity: childIdentity,
            requestedCapabilities: [.tools],
            policy: AgentCapabilityPolicy(
                allowedCapabilities: [.streaming, .tools],
                allowedToolNames: ["file_read"]
            ),
            budget: BudgetTracker(RequestBudget(maxRequestsPerSession: 2))
        )
        let nestedIdentity = try r34Identity(parentTurn: parentTurn, execution: "nested-child")

        #expect(throws: AgentChildLifecycleError.self) {
            _ = try child.deriveChild(
                identity: nestedIdentity,
                requestedCapabilities: [.streaming],
                policy: AgentCapabilityPolicy(
                    allowedCapabilities: [.streaming, .tools],
                    allowedToolNames: ["file_read"]
                ),
                budget: BudgetTracker(RequestBudget(maxRequestsPerSession: 2))
            )
        }
    }

    @Test("child approval is scoped to child identity and attempt")
    func approvalDoesNotReuseParentIdentity() async throws {
        let controller = TurnController()
        let parentTurn = await controller.beginTurn()
        defer { Task { await parentTurn.finish() } }

        let approvalProbe = R34ApprovalProbe()
        let gate = ApprovalGate(
            delegate: R34ApprovalDelegate(probe: approvalProbe)
        )
        let provider = R34Provider(
            capabilities: [.streaming, .tools],
            responses: [r34ToolEnvelope(name: "file_write"), "done"]
        )
        let executor = R34RecordingExecutor()
        let parent = AgentContext(
            toolExecutor: executor,
            provider: provider,
            tools: [r34Tool("file_write")],
            approvalGate: gate,
            turnController: controller,
            currentConversationID: "r34-parent-conversation",
            parentTurnHandle: parentTurn,
        )
        let identity = try r34Identity(parentTurn: parentTurn, execution: "child-approval")
        let childTurnController = TurnController()
        let childExecutionIdentity = AgentExecutionIdentity(
            turn: AgentTurnIdentity(
                sessionID: identity.childSessionID,
                turnID: identity.cancelGeneration,
                messageID: identity.childTaskID
            ),
            operationID: try #require(identity.generationID),
            attempt: 1
        )
        var child = try parent.deriveChild(
            identity: identity,
            requestedCapabilities: [.tools],
            policy: AgentCapabilityPolicy(
                allowedCapabilities: [.streaming, .tools],
                allowedToolNames: ["file_write"]
            ),
            budget: BudgetTracker(RequestBudget(maxRequestsPerSession: 3)),
            deadline: Date().addingTimeInterval(60),
            childTurnController: childTurnController,
            executionIdentity: childExecutionIdentity
        )

        _ = try await child.run(userMessage: "write")

        let request = try #require(await approvalProbe.request)
        #expect(request.taskID == identity.childTaskID)
        #expect(request.attemptID == identity.generationID)
        #expect(request.approvalScope == identity.scopeID)
        #expect(request.sessionID == identity.childSessionID)
        #expect(await executor.names.isEmpty)
    }

    @Test("parent cancellation stops a child before provider execution")
    func parentCancellationStopsChildBeforeProvider() async throws {
        let controller = TurnController()
        let parentTurn = await controller.beginTurn()
        await parentTurn.interrupt()
        defer { Task { await parentTurn.finish() } }

        let provider = R34Provider(
            capabilities: [.streaming, .tools],
            responses: ["done"]
        )
        let parent = AgentContext(
            toolExecutor: R34RecordingExecutor(),
            provider: provider,
            tools: [r34Tool("file_read")],
            turnController: controller,
            currentConversationID: "r34-parent-conversation",
            parentTurnHandle: parentTurn
        )
        let identity = try r34Identity(parentTurn: parentTurn, execution: "parent-cancel")
        var child = try parent.deriveChild(
            identity: identity,
            requestedCapabilities: [.tools],
            policy: AgentCapabilityPolicy(
                allowedCapabilities: [.streaming, .tools],
                allowedToolNames: ["file_read"]
            ),
            budget: BudgetTracker(RequestBudget(maxRequestsPerSession: 2))
        )

        await #expect(throws: InterruptedError.self) {
            _ = try await child.run(userMessage: "cancelled")
        }
        #expect(provider.callCount == 0)
        #expect(await child.childBoundary?.receiptLedger.snapshot()?.outcome == .cancelled)
    }

    @Test("expired child deadline produces a timed-out receipt")
    func expiredChildDeadlineProducesTimedOutReceipt() async throws {
        let controller = TurnController()
        let parentTurn = await controller.beginTurn()
        defer { Task { await parentTurn.finish() } }

        let provider = R34Provider(
            capabilities: [.streaming, .tools],
            responses: ["done"]
        )
        let parent = AgentContext(
            toolExecutor: R34RecordingExecutor(),
            provider: provider,
            tools: [r34Tool("file_read")],
            turnController: controller,
            currentConversationID: "r34-parent-conversation",
            parentTurnHandle: parentTurn
        )
        let identity = try r34Identity(parentTurn: parentTurn, execution: "deadline")
        var child = try parent.deriveChild(
            identity: identity,
            requestedCapabilities: [.tools],
            policy: AgentCapabilityPolicy(
                allowedCapabilities: [.streaming, .tools],
                allowedToolNames: ["file_read"]
            ),
            budget: BudgetTracker(RequestBudget(maxRequestsPerSession: 2)),
            deadline: Date().addingTimeInterval(-1)
        )

        do {
            _ = try await child.run(userMessage: "expired")
            Issue.record("expected child deadline to fail")
        } catch let error as AgentLoopError {
            guard case .timedOut = error else {
                Issue.record("expected timedOut, got \(error)")
                return
            }
        }
        #expect(provider.callCount == 0)
        #expect(await child.childBoundary?.receiptLedger.snapshot()?.outcome == .timedOut)
    }

    @Test("child budget is independent and bounded")
    func childBudgetDoesNotChargeParentBudget() async throws {
        let controller = TurnController()
        let parentTurn = await controller.beginTurn()
        defer { Task { await parentTurn.finish() } }

        let parentBudget = BudgetTracker(RequestBudget(maxRequestsPerSession: 20))
        let childBudget = BudgetTracker(RequestBudget(maxRequestsPerSession: 1))
        let provider = R34Provider(
            capabilities: [.streaming, .tools],
            responses: [
                r34ToolEnvelope(name: "file_read"),
                r34ToolEnvelope(name: "file_read"),
            ]
        )
        let parent = AgentContext(
            toolExecutor: R34RecordingExecutor(),
            provider: provider,
            tools: [r34Tool("file_read")],
            turnController: controller,
            requestBudget: parentBudget,
            currentConversationID: "r34-parent-conversation",
            parentTurnHandle: parentTurn,
        )
        let identity = try r34Identity(parentTurn: parentTurn, execution: "child-budget")
        var child = try parent.deriveChild(
            identity: identity,
            requestedCapabilities: [.tools],
            policy: AgentCapabilityPolicy(
                allowedCapabilities: [.streaming, .tools],
                allowedToolNames: ["file_read"]
            ),
            budget: childBudget,
            maxIterations: 2
        )

        await #expect(throws: AgentLoopError.budgetExhausted) {
            _ = try await child.run(userMessage: "two requests")
        }
        #expect(await parentBudget.budget.usedRequests == 0)
        #expect(await childBudget.budget.usedRequests == 1)
    }

    @Test("cancelled receipt rejects late result and accepts a recovered attempt")
    func cancellationRecoveryRejectsLateResult() async throws {
        let controller = TurnController()
        let parentTurn = await controller.beginTurn()
        defer { Task { await parentTurn.finish() } }
        let firstIdentity = try r34Identity(parentTurn: parentTurn, execution: "attempt-1")
        let secondIdentity = try r34Identity(parentTurn: parentTurn, execution: "attempt-2")
        let ledger = AgentChildReceiptLedger()

        #expect(await ledger.begin(identity: firstIdentity, attemptID: "attempt-1"))
        #expect(await ledger.cancel(identity: firstIdentity, attemptID: "attempt-1", detail: "parent-cancelled"))
        #expect(!(await ledger.settle(
            identity: firstIdentity,
            attemptID: "attempt-1",
            outcome: .succeeded,
            detail: "late"
        )))
        #expect(await ledger.recover(from: firstIdentity, nextAttemptID: "attempt-2"))
        #expect(await ledger.begin(identity: secondIdentity, attemptID: "attempt-2"))
        #expect(await ledger.settle(
            identity: secondIdentity,
            attemptID: "attempt-2",
            outcome: .succeeded,
            detail: "recovered"
        ))
        #expect(await ledger.snapshot()?.attemptID == "attempt-2")
        #expect(await ledger.snapshot()?.outcome == .succeeded)
    }

    @Test("runner uses the context-owned running receipt")
    func runnerDoesNotBeginOrSettleContextReceipt() async throws {
        let controller = TurnController()
        let parentTurn = await controller.beginTurn()
        defer { Task { await parentTurn.finish() } }
        let identity = try r34Identity(parentTurn: parentTurn, execution: "runner")
        let boundary = try AgentChildBoundary(
            identity: identity,
            parentCapabilities: [.streaming, .tools],
            requestedCapabilities: [.tools],
            policy: AgentCapabilityPolicy(
                allowedCapabilities: [.streaming, .tools],
                allowedToolNames: ["file_read"]
            ),
            parentTools: [r34Tool("file_read")],
            budget: BudgetTracker(RequestBudget(maxRequestsPerSession: 2)),
            parentTurnHandle: parentTurn
        )
        let executor = R34SlowExecutor()
        let attemptID = try #require(identity.generationID)
        #expect(await boundary.receiptLedger.begin(
            identity: identity,
            attemptID: attemptID
        ))
        let results = await ConcurrentToolRunner(maxConcurrent: 2).run(
            [
                ToolInvocation(name: "file_read"),
                ToolInvocation(name: "shell_execute"),
            ],
            executor: executor,
            childBoundary: boundary
        )

        #expect(results.count == 2)
        #expect(results[0].isSuccess)
        #expect(!results[1].isSuccess)
        #expect(await executor.names == ["file_read"])
        #expect(await boundary.receiptLedger.snapshot()?.outcome == .running)
        #expect(await boundary.receiptLedger.settle(
            identity: identity,
            attemptID: attemptID,
            outcome: .succeeded,
            detail: "r34-test-owner"
        ))
    }
}

private func r34Tool(_ name: String) -> AgentToolDefinition {
    AgentToolDefinition(name: name, description: name, parameters: [:], required: [])
}

private func r34ToolEnvelope(name: String) -> String {
    let object: [String: Any] = [
        "tool_calls": [[
            "id": "r34-call",
            "name": name,
            "input": [:],
        ]],
    ]
    let data = try! JSONSerialization.data(withJSONObject: object)
    return String(data: data, encoding: .utf8)!
}

private func r34Identity(
    parentTurn: TurnController.TurnHandle,
    execution: String,
    requestedCapabilities: Set<ProviderCapability> = [.tools]
) throws -> ChildRuntimeIdentity {
    try ChildRuntimeIdentity.derive(
        parent: ParentRuntimeIdentity(
            sessionID: "r34-parent-session",
            conversationID: "r34-parent-conversation",
            turnID: "turn-handle:\(parentTurn.turnID)",
            taskID: "r34-parent",
            actorID: "r34-test"
        ),
        childSessionID: "r34-child-session-\(execution)",
        childTaskID: "child-\(execution)",
        scopeID: "r34-scope-\(execution)",
        requestedCapabilities: requestedCapabilities,
        parentCapabilities: [.streaming, .tools],
        policyCapabilities: [.streaming, .tools],
        providerSnapshot: ParentContextSnapshotV1(
            providerID: "r34-provider",
            modelID: "r34-model",
            configurationFingerprint: "r34-fingerprint",
            conversationID: "r34-parent-conversation"
        ),
        memoryScopeID: "r34-memory-\(execution)",
        workingDirectory: "/tmp/r34",
        cancelGeneration: parentTurn.turnID,
        evidenceRoot: "r34-evidence-\(execution)",
        parentTurnHandle: parentTurn,
        childExecutionID: execution
    )
}

private final class R34Provider: LLMProvider, @unchecked Sendable {
    let name = "r34-provider"
    var model = LLMModel(id: "r34-model", displayName: "R34", provider: "r34-provider")
    let capabilities: Set<ProviderCapability>
    private let lock = NSLock()
    private var responses: [String]
    private var _callCount = 0
    private var _offeredToolNames: [[String]] = []

    init(capabilities: Set<ProviderCapability>, responses: [String]) {
        self.capabilities = capabilities
        self.responses = responses
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _callCount
    }

    var offeredToolNames: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return _offeredToolNames
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        try await send(tools: [])
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        try await send(tools: tools.map(\.name))
    }

    func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    private func send(tools: [String]) async throws -> LLMResponse {
        let response = nextResponse(tools: tools)
        return LLMResponse(text: response, stopReason: nil, usage: nil)
    }

    private func nextResponse(tools: [String]) -> String {
        lock.lock()
        _callCount += 1
        _offeredToolNames.append(tools)
        let response = responses.isEmpty ? "done" : responses.removeFirst()
        lock.unlock()
        return response
    }
}

private actor R34ApprovalProbe {
    private(set) var request: ApprovalRequest?

    func record(_ request: ApprovalRequest) {
        self.request = request
    }
}

private struct R34ApprovalDelegate: ApprovalDelegate {
    let probe: R34ApprovalProbe

    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        await probe.record(request)
        return .deny
    }
}

private final class R34RecordingExecutor: ToolExecutor, @unchecked Sendable {
    private let probe = R34Names()

    var names: [String] {
        get async { await probe.names }
    }

    func execute(name: String, input: [String: Any]) async throws -> String {
        await probe.record(name)
        return "ok"
    }
}

private final class R34SlowExecutor: ToolExecutor, @unchecked Sendable {
    private let probe = R34Names()

    var names: [String] {
        get async { await probe.names }
    }

    func execute(name: String, input: [String: Any]) async throws -> String {
        await probe.record(name)
        return "ok"
    }
}

private actor R34Names {
    private(set) var names: [String] = []

    func record(_ name: String) {
        names.append(name)
    }
}
