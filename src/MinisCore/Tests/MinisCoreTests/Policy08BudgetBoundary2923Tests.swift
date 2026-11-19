import Foundation
import Testing
@testable import MinisCore

/// Deliberately never completes: only the production iteration budget may stop it.
private final class Policy08BoundaryProvider2923: LLMProvider, @unchecked Sendable {
    var model = LLMModel(id: "policy08-boundary", displayName: "Owned boundary", provider: "controlled")
    var name: String { model.provider }
    var capabilities: Set<ProviderCapability> { [] }
    private(set) var tokenLimits: [Int] = []
    private(set) var histories: [[LLMMessage]] = []
    let path: String

    init(path: String) { self.path = path }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        tokenLimits.append(maxTokens)
        histories.append(messages)
        let arguments: [String: Any] = ["tool_title": "Read owned budget sample", "path": path]
        let raw = try JSONSerialization.data(withJSONObject: arguments)
        return LLMResponse(
            text: "read", stopReason: "tool_calls", usage: nil,
            toolCalls: [LLMToolCall(
                id: "boundary-call-\(tokenLimits.count)", name: "file_read",
                rawArguments: String(decoding: raw, as: UTF8.self), arguments: arguments
            )]
        )
    }

    func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
        maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt,
                              maxTokens: maxTokens, temperature: temperature)
    }

    func streamMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// Counts entry into the actual local executor, after Composer authorization.
private final class Policy08BoundaryTransport2923: BuiltinOwnerBoundToolExecutor, @unchecked Sendable {
    let currentBuiltinOwner: BuiltinToolExecutor?
    private let lock = NSLock()
    private var dispatched = 0
    var count: Int { lock.withLock { dispatched } }

    init(root: URL) { currentBuiltinOwner = BuiltinToolExecutor(allowedRoot: root) }

    func execute(name: String, input: [String: Any]) async throws -> String {
        let owner = try #require(currentBuiltinOwner)
        return try await executeBoundToBuiltinOwner(owner, name: name, input: input)
    }

    func executeBoundToBuiltinOwner(
        _ owner: BuiltinToolExecutor, name: String, input: [String: Any]
    ) async throws -> String {
        guard owner === currentBuiltinOwner else { throw ToolExecutorError.resourceScopeInvalid }
        lock.withLock { dispatched += 1 }
        return try await owner.execute(name: name, input: input)
    }
}

private final class Policy08BoundaryObservation2923: @unchecked Sendable {
    private let lock = NSLock()
    private var refused: [(String, ToolNonExecutionReason)] = []
    private var admitted: [LLMMessage] = []
    func record(callID: String, reason: ToolNonExecutionReason) {
        lock.withLock { refused.append((callID, reason)) }
    }
    func record(message: LLMMessage) { lock.withLock { admitted.append(message) } }
    var refusals: [(String, ToolNonExecutionReason)] { lock.withLock { refused } }
    var feedback: [LLMMessage] { lock.withLock { admitted.filter { $0.role == .tool } } }
}

@Suite("D-POLICY-08 production iteration boundaries and unchanged permissions")
struct Policy08BudgetBoundary2923Tests {
    @Test func allThreeEffortsReachTheirBudgetWithTheSamePermissionDecisions() async throws {
        // This is an owned non-UI Core journey, not a live Provider or field UI claim.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Policy08Boundary2923-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let denied = outside.appendingPathComponent("denied.txt")
        try "outside-must-not-be-read".write(to: denied, atomically: true, encoding: .utf8)
        // A separate allowed directory makes the outside file exist, avoiding
        // file-not-found as a weaker substitute for a policy refusal.
        let permittedRoot = root.appendingPathComponent("permitted", isDirectory: true)
        try FileManager.default.createDirectory(at: permittedRoot, withIntermediateDirectories: true)
        let permitted = permittedRoot.appendingPathComponent("allowed.txt")
        try "owned-budget-sample".write(to: permitted, atomically: true, encoding: .utf8)
        let now = Date()
        func facts(granted: Bool) -> ComposerPolicyFactSource {
            ComposerPolicyFactSource(
                knownCapabilities: ["file_read"], grantedCapabilities: granted ? ["file_read"] : [],
                allowedWriteRoots: [permittedRoot.path], workspaceID: "boundary-workspace",
                revision: "boundary-policy", grantEpoch: "boundary-grant", leaseID: "boundary-lease",
                expiresAt: now.addingTimeInterval(300), autonomyCeiling: .l3
            )
        }
        let grantedFacts = facts(granted: true)
        let ungrantedFacts = facts(granted: false)
        let efforts: [(ComposerEffort, Int, Int)] = [(.low, 5, 2048), (.standard, 10, 4096), (.high, 15, 6144)]
        var rows: [[String: Any]] = []
        for (effort, iterations, tokens) in efforts {
            for scenario in ["allowed", "noGrant", "outside"] {
                let session = "boundary-\(effort.rawValue)-\(scenario)"
                let snapshot = ComposerSubmissionSnapshot(
                    mode: .auto, approvalScope: .request, effort: effort,
                    sessionID: session, turnID: 1, taskID: "boundary-task",
                    attemptID: "boundary-attempt", messageID: "boundary-message",
                    workspaceID: "boundary-workspace", createdAt: now,
                    policyRevision: "boundary-policy", grantEpoch: "boundary-grant", autonomyCeiling: .l3
                )
                let policyFacts = scenario == "noGrant" ? ungrantedFacts : grantedFacts
                let controller = ComposerAuthorizationController(snapshot: snapshot, facts: policyFacts)
                let transport = Policy08BoundaryTransport2923(root: permittedRoot)
                let executor = ComposerPolicyEnforcedToolExecutor(base: transport, controller: controller)
                let provider = Policy08BoundaryProvider2923(path: scenario == "outside" ? denied.path : permitted.path)
                let identity = minisCoreToolContractIdentity(session, sessionID: session, messageID: snapshot.messageID)
                let ledgerURL = root.appendingPathComponent("\(effort.rawValue)-\(scenario)-facts.json")
                let ledger = try ToolExecutionFactLedger(persistenceURL: ledgerURL)
                let observation = Policy08BoundaryObservation2923()
                var loop = AgentLoop(maxIterations: 10, loopDetector: nil, toolExecutionFactLedger: ledger)
                loop.onToolNonExecution = { observation.record(callID: $0, reason: $1) }
                let outcome = await loop.runOutcome(
                    messages: [LLMMessage(role: .user, content: "read owned sample repeatedly")],
                    systemPrompt: nil, provider: provider, toolExecutor: executor,
                    tools: AgentToolCatalog.makeTools(), maxTokens: 4096,
                    currentConversationID: session, composerSnapshot: snapshot, executionIdentity: identity,
                    onMessage: { _, message in observation.record(message: message) }
                )
                #expect(outcome.result == nil)
                #expect(outcome.failure?.agentError == .maxIterationsExceeded(iterations))
                #expect(provider.tokenLimits == Array(repeating: tokens, count: iterations))
                #expect(provider.histories.count == iterations)
                #expect(observation.feedback.count == iterations)
                // Every preceding tool feedback entered the next real Provider request.
                for (index, history) in provider.histories.enumerated() {
                    #expect(history.filter { $0.role == .tool }.count == index)
                }
                let reopened = try ToolExecutionFactLedger(persistenceURL: ledgerURL)
                #expect(reopened.pendingReceipts.isEmpty)
                #expect(reopened.facts == outcome.toolExecutionFacts)
                if scenario == "allowed" {
                    #expect(transport.count == iterations)
                    #expect(reopened.facts.count == iterations)
                    #expect(reopened.facts.allSatisfy {
                        $0.status == .succeeded && !$0.receiptID.isEmpty && $0.executionIdentity == identity
                    })
                    #expect(reopened.facts.map(\.toolCallID) == (1...iterations).map { "boundary-call-\($0)" })
                    #expect(observation.refusals.isEmpty)
                    #expect(observation.feedback.allSatisfy { $0.content.contains("owned-budget-sample") })
                } else {
                    #expect(transport.count == 0)
                    #expect(reopened.facts.isEmpty)
                    #expect(observation.refusals.count == iterations)
                    #expect(observation.refusals.map(\.0) == (1...iterations).map { "boundary-call-\($0)" })
                    // U-17：拦截带固定原因分类，随场景对应授权错误。
                    let expectedCategory: ToolBlockCategory = scenario == "noGrant" ? .notGranted : .needsApproval
                    #expect(observation.refusals.allSatisfy { $0.1 == .blockedByPolicy(expectedCategory) })
                    let refusal = scenario == "noGrant"
                        ? ComposerAuthorizationError.missingCapabilityGrant("file_read")
                        : ComposerAuthorizationError.approvalRequired("file_read")
                    #expect(observation.feedback.allSatisfy { $0.content.contains(refusal.localizedDescription) })
                    #expect(provider.histories.flatMap { $0 }.allSatisfy {
                        !$0.content.contains("outside-must-not-be-read")
                    })
                }
                // The same immutable permission source is retained for every effort.
                let capturedSnapshot = await controller.snapshot
                #expect(capturedSnapshot == snapshot)
                rows.append([
                    "effort": effort.rawValue, "scenario": scenario, "iterations": provider.histories.count,
                    "providerMaxTokens": provider.tokenLimits, "terminal": "maxIterationsExceeded(\(iterations))",
                    "transportCalls": transport.count, "durableReceipts": reopened.facts.count,
                    "blockedBeforeExecution": observation.refusals.count,
                    "feedback": observation.feedback.map(\.content), "ledger": ledgerURL.path
                ])
                print("POLICY08_BOUNDARY \(effort.rawValue) \(scenario) iterations=\(provider.histories.count) maxTokens=\(provider.tokenLimits) transport=\(transport.count) receipts=\(reopened.facts.count)")
            }
        }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        let observations = root.appendingPathComponent("three-effort-observations.json")
        try data.write(to: observations, options: .atomic)
        print("POLICY08_OBSERVATIONS \(observations.path)")
    }
}

@Suite("O08 live cumulative token cap and existing leases")
struct LiveTokenBudgetLeaseTests {
    @Test func changingOnlyTokenCapKeepsCommittedAndInFlightUsageAndOtherLimits() async throws {
        let deadline = Date().addingTimeInterval(120)
        let tracker = BudgetTracker(RequestBudget(maxRequestsPerSession: 3, maxTokensPerSession: 100,
            overBudgetPolicy: .pause, deadline: deadline))
        let first = try await tracker.beginRequest()
        _ = await tracker.completeRequest(first, usage: LLMUsage(inputTokens: 20, outputTokens: 2))
        let inFlight = try await tracker.beginRequest()
        let tightened = try await tracker.setTokenLimit(10)
        #expect(tightened.usedTokens == 22 && tightened.usedRequests == 1)
        #expect(tightened.deadline == deadline && tightened.maxRequestsPerSession == 3)
        await #expect(throws: BudgetTrackerError.exhausted) { try await tracker.beginRequest() }
        _ = await tracker.completeRequest(inFlight, usage: LLMUsage(inputTokens: 3, outputTokens: 1))
        let unbounded = try await tracker.setTokenLimit(nil)
        #expect(unbounded.maxTokensPerSession == nil)
        #expect(unbounded.usedTokens == 26 && unbounded.usedRequests == 2)
        #expect(unbounded.deadline == deadline && unbounded.overBudgetPolicy == .pause)
        let third = try await tracker.beginRequest()
        _ = await tracker.completeRequest(third, usage: LLMUsage(inputTokens: 1000, outputTokens: 1))
        await #expect(throws: BudgetTrackerError.exhausted) { try await tracker.beginRequest() }
        #expect(await tracker.budget.usedTokens == 1027)
        // The old lease was consumed exactly once, not invalidated or recharged.
        _ = await tracker.completeRequest(inFlight, usage: LLMUsage(inputTokens: 9000, outputTokens: 1))
        #expect(await tracker.budget.usedTokens == 1027)
    }

    @Test func synchronousLatestTargetWinsNextAdmissionWithoutAUIWorker() async throws {
        let tracker = BudgetTracker(RequestBudget(maxRequestsPerSession: 3, maxTokensPerSession: 100))
        let first = try await tracker.beginRequest()
        _ = await tracker.completeRequest(first, usage: LLMUsage(inputTokens: 20, outputTokens: 1))
        try tracker.stageTokenLimit(10)
        // No actor setter or UI task runs between stage and the actual lease gate.
        await #expect(throws: BudgetTrackerError.exhausted) { try await tracker.beginRequest() }
        try tracker.stageTokenLimit(nil)
        let admitted = try await tracker.beginRequest()
        _ = await tracker.completeRequest(admitted, usage: LLMUsage(inputTokens: 1, outputTokens: 1))
        #expect(await tracker.budget.maxTokensPerSession == nil)
        #expect(await tracker.budget.usedTokens == 23)
        let expired = BudgetTracker(RequestBudget(maxTokensPerSession: 1, deadline: Date().addingTimeInterval(-1)))
        try expired.stageTokenLimit(nil)
        await #expect(throws: BudgetTrackerError.deadlineExceeded) { try await expired.beginRequest() }
    }

    @Test func invalidNewTokenCapDoesNotMutateTheLiveQuota() async throws {
        let tracker = BudgetTracker(RequestBudget(maxTokensPerSession: 100))
        await #expect(throws: BudgetTrackerError.invalidConfiguration) { try await tracker.setTokenLimit(-1) }
        #expect(await tracker.budget.maxTokensPerSession == 100)
    }
}
