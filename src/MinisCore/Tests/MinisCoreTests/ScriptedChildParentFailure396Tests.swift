import Foundation
import Testing
@testable import MinisCore

/// Records the complete protocol request while retaining the existing scripted
/// producer. This is local test observation, not another provider runtime.
private final class Child396RequestCapture: LLMProvider, ProviderRuntimeConfigurationIdentity {
    struct Request {
        let messages: [LLMMessage]
        let systemPrompt: String?
        let tools: [AgentToolDefinition]
        let maxTokens: Int
        let temperature: Double?
    }

    let base: MockLLMProvider
    private(set) var requests: [Request] = []
    var name: String { base.name }
    var model: LLMModel {
        get { base.model }
        set { base.model = newValue }
    }
    var capabilities: Set<ProviderCapability> { base.capabilities }
    var runtimeConfigurationMaterial: String? {
        get { base.runtimeConfigurationMaterial }
        set { base.runtimeConfigurationMaterial = newValue }
    }

    init(base: MockLLMProvider) { self.base = base }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt,
                              tools: [], maxTokens: maxTokens, temperature: temperature)
    }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?,
                     tools: [AgentToolDefinition], maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        requests.append(Request(messages: messages, systemPrompt: systemPrompt,
                                tools: tools, maxTokens: maxTokens, temperature: temperature))
        return try await base.sendMessage(messages: messages, systemPrompt: systemPrompt,
                                          tools: tools, maxTokens: maxTokens, temperature: temperature)
    }

    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        Issue.record("this deterministic consumer must use the captured sendMessage request")
        throw Child396FixtureError.unexpectedStreaming
    }
}

private enum Child396FixtureError: Error {
    case childFailed
    case missingProductionParent
    case missingEnvelope
    case unexpectedStreaming
}

/// One real throw produces the actual failed child report and canonical receipt;
/// no fabricated report or 'success' stub substitutes for failure settlement.
private actor Child396Runner: ExternalAgentRunner {
    let name = "child396-script"
    let isAvailable = true
    let failFirst: Bool
    private var invokedIDs: [String] = []

    init(failFirst: Bool) { self.failFirst = failFirst }

    func run(task: SubAgentTask) async throws -> String {
        invokedIDs.append(task.id)
        if failFirst && task.id == "child396-first" {
            throw Child396FixtureError.childFailed
        }
        return "completed-\(task.id)"
    }

    func invocations() -> [String] { invokedIDs }
}

private actor Child396Approval: ApprovalDelegate {
    private var captured: [ApprovalRequest] = []
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        captured.append(request)
        return ApprovalDecision(approved: true, confirmed: true,
                                requestID: request.requestID, bindingDigest: request.identityDigest)
    }
    func requests() -> [ApprovalRequest] { captured }
}

/// Uses the exact Core-created parent identity/handle, just as the production
/// composition seam does; forwards to the existing production executor. The
/// donor969c replay stays at the real store boundary before one parent result.
private final class Child396ProductionExecutor: ToolExecutor, @unchecked Sendable {
    let store: AgentTaskStore
    let runner: Child396Runner
    let governor: ChildConcurrencyGovernor
    private let replayLock = NSLock()
    private var replayCount = 0

    init(store: AgentTaskStore, runner: Child396Runner, governor: ChildConcurrencyGovernor) {
        self.store = store
        self.runner = runner
        self.governor = governor
    }

    func execute(name: String, input: [String: Any]) async throws -> String {
        guard let context = AgentExecutionContext.current,
              let parentIdentity = context.parentRuntimeIdentity,
              let handle = context.parentTurnHandle,
              let binding = context.parentBinding else {
            throw Child396FixtureError.missingProductionParent
        }
        let orchestrator = AgentOrchestrator(
            externalRunners: [runner.name: runner],
            taskStore: store,
            parentID: parentIdentity.taskID,
            parentBinding: binding,
            parentRuntimeIdentity: parentIdentity,
            parentTurnHandle: handle,
            runtimeMode: .production,
            capabilityPolicy: AgentCapabilityPolicy(
                allowedCapabilities: context.provider.capabilities,
                allowedToolNames: [],
                allowedMCPToolNames: []
            ),
            parentCapabilities: context.provider.capabilities,
            childGovernor: governor
        )
        let output = try await OrchestrationToolExecutor(orchestrator: orchestrator)
            .execute(name: name, input: input)
        guard let envelope = store.allReceipts()
            .first(where: { $0.childResultEnvelope?.taskID == "child396-first" })?.childResultEnvelope else {
            throw Child396FixtureError.missingEnvelope
        }
        _ = try store.settleChildResult(envelope)
        _ = try store.settleChildResult(envelope)
        recordReplays(2)
        return output
    }

    private func recordReplays(_ count: Int) {
        replayLock.lock()
        defer { replayLock.unlock() }
        replayCount = count
    }

    func replays() -> Int {
        replayLock.lock()
        defer { replayLock.unlock() }
        return replayCount
    }
}

@Suite("396 scripted child failure reaches the parent request")
struct ScriptedChildParentFailure396Tests {
    @Test("actual failed child stays failed in parent fact and next request; all-success control",
          arguments: [true, false])
    func actualChildTerminalFeedsParentFactAndRequest(failFirst: Bool) async throws {
        let root = try minisCoreToolContractRoot("child396-\(failFirst)")
        let ledger = try minisCoreToolContractLedger(at: root)
        let store = AgentTaskStore()
        let runner = Child396Runner(failFirst: failFirst)
        let governor = ChildConcurrencyGovernor(policy: .init(globalHardCeiling: 2))
        let executor = Child396ProductionExecutor(store: store, runner: runner, governor: governor)
        let approval = Child396Approval()
        let controller = TurnController()
        let input: [String: Any] = [
            "input_version": 1,
            "tasks": ["child396-first", "child396-second"].map {
                ["id": $0, "title": $0, "instructions": "complete \($0)",
                 "agent": "external:child396-script"]
            },
            "strategy": "sequential",
        ]
        let callID = "child396-orchestrate-call"
        let call = try JSONSerialization.data(withJSONObject: ["tool_calls": [[
            "id": callID, "name": OrchestrationToolExecutor.toolName, "input": input,
        ]]])
        let provider = Child396RequestCapture(base: MockLLMProvider(responses: [
            String(decoding: call, as: UTF8.self), "parent observed child results",
        ]))
        let identity = minisCoreToolContractIdentity("child396-parent-\(failFirst)")
        let loop = AgentLoop(maxIterations: 3, approvalGate: ApprovalGate(delegate: approval),
                             turnController: controller, loopDetector: nil, timeout: 30,
                             taskStore: store, toolExecutionFactLedger: ledger)
        let systemPrompt = "396 parent instruction: retain every child terminal truth."
        let result = try await loop.run(
            messages: [LLMMessage(role: .user, content: "delegate two synthetic children")],
            systemPrompt: systemPrompt, provider: provider, toolExecutor: executor,
            tools: [OrchestrationToolExecutor.makeDefinition()], maxTokens: 321, temperature: 0.2,
            currentConversationID: identity.turn.sessionID,
            parentIdentitySeed: ParentRuntimeIdentitySeed(
                sessionID: identity.turn.sessionID, conversationID: identity.turn.sessionID,
                taskID: "child396-parent", actorID: "child396-synthetic"
            ), executionIdentity: identity
        )

        #expect(await runner.invocations() == ["child396-first", "child396-second"])
        #expect(executor.replays() == 2)
        let receipts = store.allReceipts()
        #expect(receipts.count == 2)
        let first = try #require(receipts.first(where: { $0.childResultEnvelope?.taskID == "child396-first" }))
        let second = try #require(receipts.first(where: { $0.childResultEnvelope?.taskID == "child396-second" }))
        let firstEnvelope = try #require(first.childResultEnvelope)
        #expect(firstEnvelope.taskID == "child396-first")
        #expect(firstEnvelope.parentContextSnapshotID == second.parentContextSnapshotID)
        let firstTask = try #require(store.snapshot(taskID: "child396-first", parentID: "child396-parent"))
        let parentIdentity = try #require(firstTask.parentRuntimeIdentity)
        let parentTerminal = try #require(store.parentTurnTerminalFact(parent: parentIdentity, execution: identity))
        #expect(parentTerminal.outcome == (failFirst ? .failed : .succeeded))
        #expect(firstTask.status == (failFirst ? .failed : .succeeded))
        #expect(firstTask.parentContextSnapshotID == firstEnvelope.parentContextSnapshotID)
        #expect(!firstEnvelope.attemptID.isEmpty)
        #expect(!firstEnvelope.childExecutionID.isEmpty)
        if failFirst {
            let childFailure = Child396FixtureError.childFailed.localizedDescription
            #expect(firstEnvelope.outcome == .failed(reason: childFailure))
            #expect(firstEnvelope.error == childFailure)
            #expect(firstEnvelope.output == nil)
            #expect(first.outcome == .failed(reason: "execution-failed"))
            guard case .failed = first.outcome else {
                Issue.record("the throwing child must own a failed terminal receipt")
                return
            }
            #expect(store.events(runID: first.runID).map(\.kind) == [.started, .progress, .failed])
        } else {
            #expect(firstEnvelope.outcome == .succeeded)
            #expect(first.outcome == .succeeded)
            #expect(store.events(runID: first.runID).map(\.kind) == [.started, .progress, .completed])
        }
        #expect(second.outcome == .succeeded)
        #expect(store.events(runID: second.runID).map(\.kind) == [.started, .progress, .completed])

        // Parent orchestration terminal truth is separate from the model's final
        // prose. A successful sibling must not erase the failed first child.
        let parentFact = try #require(result.toolExecutionFacts.first)
        #expect(result.toolExecutionFacts.count == 1)
        #expect(parentFact.toolName == OrchestrationToolExecutor.toolName)
        #expect(parentFact.toolCallID == callID)
        #expect(parentFact.status == (failFirst ? .failed : .succeeded))
        #expect(ledger.facts.count == 1)
        #expect(ledger.pendingReceipts.isEmpty)
        #expect(await controller.isRunning == false)
        let prompts = await approval.requests()
        #expect(prompts.count == 1)
        #expect(prompts.first?.binding != nil)

        let requests = provider.requests
        #expect(requests.count == 2)
        let firstRequest = try #require(requests.first)
        let nextRequest = try #require(requests.dropFirst().first)
        #expect(firstRequest.messages.first?.content == "delegate two synthetic children")
        #expect(firstRequest.systemPrompt?.contains(systemPrompt) == true)
        #expect(nextRequest.systemPrompt == firstRequest.systemPrompt)
        #expect(requests.allSatisfy { $0.maxTokens == 321 && $0.temperature == 0.2 })
        let firstSchema = try JSONSerialization.data(
            withJSONObject: firstRequest.tools.map(\.openAIFunctionDict), options: [.sortedKeys])
        let nextSchema = try JSONSerialization.data(
            withJSONObject: nextRequest.tools.map(\.openAIFunctionDict), options: [.sortedKeys])
        #expect(firstSchema == nextSchema)
        #expect(firstRequest.tools.map(\.name) == [OrchestrationToolExecutor.toolName])

        for messages in [result.messages, nextRequest.messages] {
            let childResults = messages.flatMap { $0.toAgentContentParts() }
                .compactMap { part -> (id: String, content: String, isError: Bool)? in
                    guard case .toolResult(let id, _, let content, let isError, _, _, _, _) = part else {
                        return nil
                    }
                    return (id, content, isError)
                }
            #expect(childResults.count == 1)
            let childResult = try #require(childResults.first)
            #expect(childResult.id == callID)
            #expect(childResult.isError == failFirst)
            let response = try #require(JSONSerialization.jsonObject(with: Data(childResult.content.utf8)) as? [String: Any])
            #expect(response["version"] as? Int == 1)
            let rows = try #require(response["results"] as? [[String: Any]])
            #expect(rows.count == 2)
            #expect(rows.compactMap { $0["task_id"] as? String } == ["child396-first", "child396-second"])
            #expect(rows.compactMap { $0["status"] as? String } == [failFirst ? "failed" : "succeeded", "succeeded"])
            let expectedFirst = failFirst ? Child396FixtureError.childFailed.localizedDescription : "completed-child396-first"
            #expect(rows.compactMap { $0["summary"] as? String } == [
                ProductRedactionPolicy.redact(expectedFirst, maxLength: 600), "completed-child396-second"])
            for (row, receipt) in zip(rows, [first, second]) {
                let duration = try #require(row["duration_seconds"] as? Double)
                #expect(duration.isFinite && duration >= 0)
                let reference = try #require(row["output_ref"] as? [String: String])
                let envelope = try #require(receipt.childResultEnvelope)
                #expect(reference == ["task_id": envelope.taskID, "parent_id": "child396-parent",
                    "run_id": receipt.runID, "attempt_id": envelope.attemptID])
            }
            #expect(!failFirst || !childResult.content.contains("completed-child396-first"))
        }
    }
}
