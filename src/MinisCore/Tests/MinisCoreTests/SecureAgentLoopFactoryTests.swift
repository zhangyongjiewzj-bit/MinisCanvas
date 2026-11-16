import Testing
import Foundation
@testable import MinisCore

struct SecureAgentLoopFactoryTests {
    @Test func secureFactoryAlwaysInstallsGate() throws {
        let loop = SecureAgentLoopFactory.make(approvalGate: ApprovalGate())
        try loop.requireApprovalGate()
    }

    @Test func secureOrchestratorFactoryRequiresApprovalAndPropagatesChildControls() {
        let orchestrator = SecureAgentLoopFactory.makeOrchestrator(
            approvalDelegate: ApproveAllDelegate(),
            makeChildBudget: { nil },
            childTimeout: 2.0,
            currentConversationID: "root-conversation"
        )
        #expect(orchestrator.approvalGate != nil)
        #expect(orchestrator.childTimeout == 2.0)
        #expect(orchestrator.currentConversationID == "root-conversation")
        #expect(orchestrator.makeChildBudget != nil)
    }

    @Test func productionOrchestratorWithoutPolicyRuntimeRejectsRawChildBeforeProviderWork() async {
        let base = FactoryCountingExecutor()
        let provider = FactoryScriptedProvider(responses: ["child done"])
        let orchestrator = SecureAgentLoopFactory.makeOrchestrator(
            provider: provider,
            toolExecutor: base,
            approvalDelegate: ApproveAllDelegate()
        )

        let reports = await orchestrator.orchestrate(tasks: [
            SubAgentTask(
                id: "raw-child",
                title: "raw child",
                instructions: "run without a policy runtime"
            )
        ], strategy: .sequential)

        #expect(base.executionCount == 0)
        guard case .failed(let error) = reports.first?.result else {
            Issue.record("raw child should fail closed")
            return
        }
        #expect(error == "POLICY_RUNTIME_REQUIRED")
    }

    @Test func productionOrchestratorWithPolicyRuntimeRequiredRejectsRawChildBeforeProviderWork() async {
        let controller = TurnController()
        let parentTurn = await controller.beginTurn()
        defer {
            Task { await parentTurn.finish() }
        }
        let base = FactoryCountingExecutor()
        let provider = FactoryScriptedProvider(responses: ["child done"])
        let orchestrator = AgentOrchestrator(
            provider: provider,
            toolExecutor: base,
            approvalGate: ApprovalGate(delegate: ApproveAllDelegate()),
            turnController: controller,
            currentConversationID: "factory-conversation",
            taskStore: AgentTaskStore(),
            parentID: "factory-parent",
            parentBinding: ParentContextSnapshotV1(
                providerID: provider.name,
                modelID: provider.model.id,
                configurationFingerprint: "factory-fingerprint",
                conversationID: "factory-conversation"
            ),
            parentRuntimeIdentity: ParentRuntimeIdentity(
                sessionID: "factory-session",
                conversationID: "factory-conversation",
                turnID: "turn-handle:\(parentTurn.turnID)",
                taskID: "factory-parent",
                actorID: "app"
            ),
            parentTurnHandle: parentTurn,
            runtimeMode: .production,
            capabilityPolicy: AgentCapabilityPolicy(
                allowedCapabilities: [.tools],
                allowedToolNames: [],
                allowedMCPToolNames: []
            ),
            parentCapabilities: provider.capabilities,
            requiresPolicyRuntime: true
        )

        let reports = await orchestrator.orchestrate(tasks: [
            SubAgentTask(
                id: "raw-production-child",
                title: "raw production child",
                instructions: "must fail before provider or executor work"
            )
        ], strategy: .sequential)

        #expect(provider.sendCount == 0)
        #expect(base.executionCount == 0)
        guard case .failed(let error) = reports.first?.result else {
            Issue.record("production raw child should fail closed")
            return
        }
        #expect(error == "POLICY_RUNTIME_REQUIRED")
    }

    @Test func productionOrchestratorPreservesAlreadyPolicyBoundChildExecutor() async throws {
        let base = FactoryCountingExecutor()
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let goal = GoalEnvelope(
            scopeID: "turn:orchestrator",
            allowedCapabilities: ["file_read"],
            fileRoots: ["/tmp/orchestrator-policy"],
            budget: 1,
            deadline: now.addingTimeInterval(60),
            concurrencyLimit: 1,
            createdAt: now.addingTimeInterval(-1)
        )
        let lease = AutonomyLease(
            goalID: goal.goalID,
            scopeID: goal.scopeID,
            issuedAt: now.addingTimeInterval(-1),
            expiresAt: now.addingTimeInterval(60)
        )
        let bound = PolicyRuntimeBinding(
            goal: goal,
            lease: lease,
            clock: { now }
        ).wrap(base)
        let provider = FactoryScriptedProvider(responses: [
            factoryToolCallEnvelope(
                name: "file_read",
                input: ["path": "/tmp/orchestrator-policy/a.txt"]
            ),
            "child done"
        ])
        let root = try minisCoreToolContractRoot("secure-orchestrator-policy-bound")
        defer { try? FileManager.default.removeItem(at: root) }
        let orchestrator = SecureAgentLoopFactory.makeOrchestrator(
            provider: provider,
            toolExecutor: bound,
            approvalDelegate: ApproveAllDelegate(),
            toolExecutionFactLedger: try minisCoreToolContractLedger(at: root),
            capabilityPolicy: AgentCapabilityPolicy(
                allowedCapabilities: [.tools],
                allowedToolNames: ["file_read"]
            ),
            parentCapabilities: [.tools],
            currentConversationID: "secure-orchestrator-policy-bound"
        )

        let reports = await orchestrator.orchestrate(tasks: [
            SubAgentTask(
                id: "bound-child",
                title: "bound child",
                instructions: "run with a policy-bound executor"
            )
        ], strategy: .sequential)

        #expect(base.executionCount == 1)
        #expect(reports.count == 1)
        #expect(reports[0].result == .succeeded(output: "child done"))
    }

    @Test func legacyLoopIsRejectedBySecureEntryPoint() {
        let loop = AgentLoop()
        #expect(throws: SecureAgentLoopError.approvalGateRequired) {
            try loop.requireApprovalGate()
        }
    }

    @Test func delegateFactoryInstallsFailClosedGate() throws {
        let loop = SecureAgentLoopFactory.make(approvalDelegate: ApproveAllDelegate())
        try loop.requireApprovalGate()
        #expect(loop.approvalGate?.delegate != nil)
    }

    @Test func productionFactoryWithoutPolicyRuntimeRejectsRawExecutorBeforeProviderWork() async throws {
        let base = FactoryCountingExecutor()
        let loop = SecureAgentLoopFactory.make(approvalDelegate: ApproveAllDelegate())
        let provider = FactoryScriptedProvider(responses: [
            factoryToolCallEnvelope(name: "file_read", input: [:])
        ])

        await #expect(throws: SecureAgentLoopError.policyRuntimeRequired) {
            _ = try await loop.run(
                messages: [],
                systemPrompt: nil,
                provider: provider,
                toolExecutor: base,
                tools: [
                    AgentToolDefinition(
                        name: "file_read",
                        description: "",
                        parameters: [:],
                        required: []
                    )
                ]
            )
        }

        #expect(base.executionCount == 0)
    }

    @Test func productionFactoryBindsPolicyRuntimeBeforeEveryToolCall() async throws {
        let base = FactoryCountingExecutor()
        let root = try minisCoreToolContractRoot("secure-policy-every-call")
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = minisCoreToolContractIdentity("secure-policy-every-call")
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let goal = GoalEnvelope(
            scopeID: "turn:factory",
            allowedCapabilities: ["file_read"],
            fileRoots: ["/tmp/factory-policy"],
            budget: 1,
            deadline: now.addingTimeInterval(60),
            concurrencyLimit: 1,
            createdAt: now.addingTimeInterval(-1)
        )
        let lease = AutonomyLease(
            goalID: goal.goalID,
            scopeID: goal.scopeID,
            issuedAt: now.addingTimeInterval(-1),
            expiresAt: now.addingTimeInterval(60)
        )
        let loop = SecureAgentLoopFactory.make(
            approvalDelegate: ApproveAllDelegate(),
            policyRuntime: PolicyRuntimeBinding(
                goal: goal,
                lease: lease,
                clock: { now }
            ),
            toolExecutionFactLedger: try minisCoreToolContractLedger(at: root)
        )
        let provider = FactoryScriptedProvider(responses: [
            factoryToolCallEnvelope(name: "shell_execute", input: [:]),
            "done"
        ])

        _ = try await loop.run(
            messages: [],
            systemPrompt: nil,
            provider: provider,
            toolExecutor: base,
            tools: [
                AgentToolDefinition(
                    name: "shell_execute",
                    description: "",
                    parameters: [:],
                    required: []
                )
            ],
            executionIdentity: identity
        )

        #expect(base.executionCount == 0)
    }

    @Test func productionFactoryAllowsOnlyPolicyBoundToolAndPreservesSingleExecution() async throws {
        let base = FactoryCountingExecutor()
        let root = try minisCoreToolContractRoot("secure-policy-single-execution")
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = minisCoreToolContractIdentity("secure-policy-single-execution")
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let goal = GoalEnvelope(
            scopeID: "turn:factory",
            allowedCapabilities: ["file_read"],
            fileRoots: ["/tmp/factory-policy"],
            budget: 1,
            deadline: now.addingTimeInterval(60),
            concurrencyLimit: 1,
            createdAt: now.addingTimeInterval(-1)
        )
        let lease = AutonomyLease(
            goalID: goal.goalID,
            scopeID: goal.scopeID,
            issuedAt: now.addingTimeInterval(-1),
            expiresAt: now.addingTimeInterval(60)
        )
        let loop = SecureAgentLoopFactory.make(
            approvalDelegate: ApproveAllDelegate(),
            policyRuntime: PolicyRuntimeBinding(
                goal: goal,
                lease: lease,
                clock: { now }
            ),
            toolExecutionFactLedger: try minisCoreToolContractLedger(at: root)
        )
        let provider = FactoryScriptedProvider(responses: [
            factoryToolCallEnvelope(
                name: "file_read",
                input: ["path": "/tmp/factory-policy/a.txt"]
            ),
            "done"
        ])

        _ = try await loop.run(
            messages: [],
            systemPrompt: nil,
            provider: provider,
            toolExecutor: base,
            tools: [
                AgentToolDefinition(
                    name: "file_read",
                    description: "",
                    parameters: [
                        "path": AgentToolParam(type: .string, description: "")
                    ],
                    required: ["path"]
                )
            ],
            executionIdentity: identity
        )

        #expect(base.executionCount == 1)
    }

    @Test func productionFactoryApprovalDenialStillFailsClosedBeforePolicyBase() async throws {
        let base = FactoryCountingExecutor()
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let goal = GoalEnvelope(
            scopeID: "turn:factory",
            allowedCapabilities: ["shell_execute"],
            budget: 1,
            deadline: now.addingTimeInterval(60),
            concurrencyLimit: 1,
            createdAt: now.addingTimeInterval(-1)
        )
        let lease = AutonomyLease(
            goalID: goal.goalID,
            scopeID: goal.scopeID,
            issuedAt: now.addingTimeInterval(-1),
            expiresAt: now.addingTimeInterval(60)
        )
        let loop = SecureAgentLoopFactory.make(
            approvalDelegate: DenyDelegate(),
            policyRuntime: PolicyRuntimeBinding(goal: goal, lease: lease, clock: { now })
        )
        let provider = FactoryScriptedProvider(responses: [
            factoryToolCallEnvelope(name: "shell_execute", input: ["command": "echo blocked"]),
            "done"
        ])

        _ = try await loop.run(
            messages: [],
            systemPrompt: nil,
            provider: provider,
            toolExecutor: base,
            tools: [
                AgentToolDefinition(name: "shell_execute", description: "", parameters: [:], required: [])
            ]
        )

        #expect(base.executionCount == 0)
    }

    @Test func productionFactoryBindsTurnScopeAndRejectsMismatchedRequest() async throws {
        let base = FactoryCountingExecutor()
        let root = try minisCoreToolContractRoot("secure-policy-turn-scope")
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = minisCoreToolContractIdentity("secure-policy-turn-scope")
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let goal = GoalEnvelope(
            scopeID: "turn:factory",
            allowedCapabilities: ["file_read"],
            fileRoots: ["/tmp/factory-policy"],
            budget: 1,
            deadline: now.addingTimeInterval(60),
            concurrencyLimit: 1,
            createdAt: now.addingTimeInterval(-1)
        )
        let lease = AutonomyLease(
            goalID: goal.goalID,
            scopeID: goal.scopeID,
            issuedAt: now.addingTimeInterval(-1),
            expiresAt: now.addingTimeInterval(60)
        )
        let loop = SecureAgentLoopFactory.make(
            approvalDelegate: ApproveAllDelegate(),
            policyRuntime: PolicyRuntimeBinding(
                goal: goal,
                lease: lease,
                requestBuilder: { name, input in
                    PolicyRequest(
                        capabilityID: name,
                        scopeID: "turn:other",
                        filePath: input["path"] as? String,
                        estimatedCost: 1
                    )
                },
                clock: { now }
            ),
            toolExecutionFactLedger: try minisCoreToolContractLedger(at: root)
        )
        let provider = FactoryScriptedProvider(responses: [
            factoryToolCallEnvelope(
                name: "file_read",
                input: ["path": "/tmp/factory-policy/a.txt"]
            ),
            "done"
        ])

        _ = try await loop.run(
            messages: [],
            systemPrompt: nil,
            provider: provider,
            toolExecutor: base,
            tools: [
                AgentToolDefinition(
                    name: "file_read",
                    description: "",
                    parameters: ["path": AgentToolParam(type: .string, description: "")],
                    required: ["path"]
                )
            ],
            executionIdentity: identity
        )

        #expect(base.executionCount == 0)
    }

    @Test func productionFactoryCancellationAfterApprovalDoesNotReachBase() async throws {
        let base = FactoryCountingExecutor()
        let controller = TurnController()
        let root = try minisCoreToolContractRoot("secure-factory-cancel-after-approval")
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = minisCoreToolContractIdentity("secure-factory-cancel-after-approval")
        let approvalProbe = FactoryApprovalRequestProbe()
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let goal = GoalEnvelope(
            scopeID: "turn:factory",
            allowedCapabilities: ["shell_execute"],
            budget: 1,
            deadline: now.addingTimeInterval(60),
            concurrencyLimit: 1,
            createdAt: now.addingTimeInterval(-1)
        )
        let lease = AutonomyLease(
            goalID: goal.goalID,
            scopeID: goal.scopeID,
            issuedAt: now.addingTimeInterval(-1),
            expiresAt: now.addingTimeInterval(60)
        )
        let loop = SecureAgentLoopFactory.make(
            approvalDelegate: InterruptThenApproveDelegate(controller: controller, probe: approvalProbe),
            policyRuntime: PolicyRuntimeBinding(goal: goal, lease: lease, clock: { now }),
            toolExecutionFactLedger: try minisCoreToolContractLedger(at: root),
            turnController: controller
        )
        let provider = FactoryScriptedProvider(responses: [
            factoryToolCallEnvelope(name: "shell_execute", input: ["command": "echo blocked"])
        ])

        await #expect(throws: InterruptedError.self) {
            _ = try await loop.run(
                messages: [],
                systemPrompt: nil,
                provider: provider,
                toolExecutor: base,
                tools: [
                    AgentToolDefinition(name: "shell_execute", description: "", parameters: [:], required: [])
                ],
                currentConversationID: identity.turn.sessionID,
                parentIdentitySeed: ParentRuntimeIdentitySeed(
                    sessionID: identity.turn.sessionID,
                    conversationID: identity.turn.sessionID,
                    taskID: "task:secure-factory-cancel-after-approval",
                    actorID: "test"
                ),
                executionIdentity: identity
            )
        }

        let requests = await approvalProbe.requests
        #expect(requests.count == 1)
        #expect(requests.first?.binding != nil)
        #expect(base.executionCount == 0)
        #expect(await controller.isRunning == false)
    }
}

private struct ApproveAllDelegate: ApprovalDelegate {
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        .approve
    }
}

private struct DenyDelegate: ApprovalDelegate {
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        .deny
    }
}

private struct InterruptThenApproveDelegate: ApprovalDelegate {
    let controller: TurnController
    let probe: FactoryApprovalRequestProbe

    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        await probe.record(request)
        await controller.interrupt()
        return ApprovalDecision(
            approved: true,
            confirmed: true,
            requestID: request.requestID,
            bindingDigest: request.identityDigest
        )
    }
}

private actor FactoryApprovalRequestProbe {
    private(set) var requests: [ApprovalRequest] = []

    func record(_ request: ApprovalRequest) {
        requests.append(request)
    }
}

private final class FactoryCountingExecutor: ToolExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var executionCount: Int {
        lock.withLock { count }
    }

    func execute(name: String, input: [String: Any]) async throws -> String {
        lock.withLock { count += 1 }
        return "ok"
    }
}

private final class FactoryScriptedProvider: LLMProvider, @unchecked Sendable {
    let name = "FactoryScripted"
    var model = LLMModel(id: "factory", displayName: "Factory", provider: "test")
    let capabilities: Set<ProviderCapability> = [.tools]
    private var responses: [String]
    private(set) var sendCount = 0

    init(responses: [String]) {
        self.responses = responses
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        sendCount += 1
        let next = responses.isEmpty ? "" : responses.removeFirst()
        return LLMResponse(text: next, stopReason: nil, usage: nil)
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

private func factoryToolCallEnvelope(name: String, input: [String: Any]) -> String {
    let object: [String: Any] = [
        "tool_calls": [[
            "id": "factory-call",
            "name": name,
            "input": input
        ]]
    ]
    let data = try! JSONSerialization.data(withJSONObject: object)
    return String(decoding: data, as: UTF8.self)
}
