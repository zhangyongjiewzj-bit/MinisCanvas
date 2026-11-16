import Foundation
import Testing
@testable import MinisCore

private actor LateTurnApprovalDelegate: ApprovalDelegate {
    private var requestWaiter: CheckedContinuation<Void, Never>?
    private var decisionWaiter: CheckedContinuation<Void, Never>?
    private var didRequest = false
    private(set) var requestCount = 0

    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        didRequest = true
        requestCount += 1
        requestWaiter?.resume()
        requestWaiter = nil
        await withCheckedContinuation { decisionWaiter = $0 }
        return ApprovalDecision(
            approved: true,
            confirmed: true,
            requestID: request.requestID,
            bindingDigest: request.identityDigest
        )
    }

    func waitForRequest() async {
        if didRequest { return }
        await withCheckedContinuation { requestWaiter = $0 }
    }

    func approve() {
        decisionWaiter?.resume()
        decisionWaiter = nil
    }
}

private actor LateTurnReceiptProbe {
    private(set) var count = 0
    private(set) var sessionID: String?
    private(set) var turnID: Int?
    func record(_ receipt: ApprovalReceipt) {
        count += 1
        sessionID = receipt.sessionID
        turnID = receipt.turnID
    }
}

private actor LateTurnEffectProbe {
    private(set) var count = 0
    func execute() { count += 1 }
}

private final class LateTurnApprovalFactProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ApprovalLifecycleFact] = []

    func record(_ fact: ApprovalLifecycleFact) {
        lock.withLock { stored.append(fact) }
    }

    var facts: [ApprovalLifecycleFact] {
        lock.withLock { stored }
    }
}

private struct TerminalApprovalDelegate: ApprovalDelegate {
    let status: ApprovalDecisionStatus

    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        ApprovalDecision(
            approved: false,
            reason: "synthetic refusal",
            status: status,
            requestID: request.requestID,
            bindingDigest: request.identityDigest
        )
    }
}

@Suite("D-TOOL-10 approval cannot outlive its exact turn")
struct P3AcceptanceM07LateTurnRevocationTests {
    @Test func originalDelegateTerminalStatusIsNotFlattenedToDenial() async throws {
        let cases: [(ApprovalDecisionStatus, ApprovalLifecycleStage)] = [
            (.denied, .authorityDenied),
            (.expired, .authorityExpired),
            (.cancelled, .authorityCancelled),
            (.revoked, .authorityRevoked)
        ]
        for (status, expectedStage) in cases {
            let suffix = UUID().uuidString
            let identity = AgentExecutionIdentity(
                turn: AgentTurnIdentity(sessionID: "session:\(suffix)", turnID: 1, messageID: "message:\(suffix)"),
                operationID: "operation:\(suffix)",
                attempt: 1
            )
            let callID = "call:\(suffix)"
            let attemptID = "attempt:\(suffix)"
            let input: [String: Any] = ["path": "/synthetic/no-write", "content": "sample"]
            let digest = try #require(ApprovalAuthorizationContext.payloadDigest(for: input))
            let authorization = ApprovalAuthorizationContext(
                actorID: "test", sessionID: identity.turn.sessionID,
                turnID: identity.turn.turnID, taskID: "task:\(suffix)",
                runID: identity.operationID, attemptID: attemptID,
                effectID: callID, scope: "request", payloadDigest: digest,
                expiresAt: Date().addingTimeInterval(120),
                policyRevision: "revision", grantEpoch: "epoch", toolName: "file_write"
            )
            let facts = LateTurnApprovalFactProbe()
            let presentation = ApprovalPresentationContext(
                compositeKey: ToolExecutionCompositeKey(
                    sessionID: identity.turn.sessionID, turnID: identity.turn.turnID,
                    messageID: identity.turn.messageID, operationID: identity.operationID,
                    attemptID: attemptID, attemptNumber: 1, toolCallID: callID
                ),
                executionIdentity: identity, toolName: "file_write",
                eventSink: { facts.record($0) }
            )
            let gate = ApprovalGate(delegate: TerminalApprovalDelegate(status: status))
            do {
                _ = try await ApprovalPresentationContext.$current.withValue(presentation) {
                    try await gate.gate(tool: "file_write", input: input, context: authorization)
                }
                Issue.record("refused synthetic request unexpectedly approved")
            } catch let error as ApprovalError {
                switch status {
                case .denied: #expect(error == .denied(reason: "synthetic refusal"))
                case .expired: #expect(error == .expired(requestID: callID))
                case .cancelled: #expect(error == .cancelled(requestID: callID))
                case .revoked: #expect(error == .revoked(requestID: callID))
                case .approved: Issue.record("approved is not a refusal fixture")
                }
            } catch {
                Issue.record("unexpected approval error: \(error)")
            }
            #expect(facts.facts.map(\.stage) == [expectedStage])
            #expect(facts.facts.first?.requestID == callID)
        }
    }

    @Test func lateApprovalAfterRevokeOrReplacementCannotEmitReceiptOrEffect() async throws {
        for replaceTurn in [false, true] {
            let controller = TurnController()
            let handle = await controller.beginTurn()
            let sessionID = "session:\(UUID().uuidString)"
            let seed = ParentRuntimeIdentitySeed(
                sessionID: sessionID,
                conversationID: sessionID,
                taskID: "task:\(UUID().uuidString)",
                actorID: "test"
            )
            let identity = AgentExecutionIdentity(
                turn: AgentTurnIdentity(
                    sessionID: sessionID,
                    turnID: handle.turnID,
                    messageID: "message:\(UUID().uuidString)",
                ),
                operationID: "operation:\(UUID().uuidString)",
                attempt: 1
            )
            let callID = "call:\(UUID().uuidString)"
            let delegate = LateTurnApprovalDelegate()
            let receipts = LateTurnReceiptProbe()
            let effects = LateTurnEffectProbe()
            let authority = LateTurnApprovalFactProbe()
            let gate = ApprovalGate(
                delegate: delegate,
                onApprovalReceipt: { receipt in await receipts.record(receipt) }
            )
            let runtime = AgentExecutionContextSnapshot(
                provider: ToolApprovalMockLLMProvider(responses: []),
                approvalGate: gate,
                turnController: controller,
                currentConversationID: sessionID,
                makeChildBudget: nil,
                deadline: Date().addingTimeInterval(120),
                parentTurnHandle: handle,
                parentRuntimeIdentity: try seed.makeIdentity(using: handle)
            )
            let presentation = ApprovalPresentationContext(
                compositeKey: ToolExecutionCompositeKey(
                    sessionID: sessionID,
                    turnID: handle.turnID,
                    messageID: identity.turn.messageID,
                    operationID: identity.operationID,
                    attemptID: "\(identity.operationID):attempt:1",
                    attemptNumber: 1,
                    toolCallID: callID
                ),
                executionIdentity: identity,
                toolName: "file_write",
                eventSink: { authority.record($0) }
            )
            let approval = Task {
                try await ApprovalPresentationContext.$current.withValue(presentation) {
                    try await AgentExecutionContext.$current.withValue(runtime) {
                        _ = try await gate.gateAgentCall(
                            tool: "file_write",
                            input: ["path": "/synthetic/no-write", "content": "sample"],
                            callID: callID,
                            executionIdentity: identity,
                            attemptID: "\(identity.operationID):attempt:1",
                            attemptNumber: 1
                        )
                        await effects.execute() // synthetic direct consumer; never writes a file
                    }
                }
            }

            await delegate.waitForRequest()
            if replaceTurn {
                await handle.finish()
                let replacement = await controller.beginTurn()
                #expect(replacement.turnID != handle.turnID)
                #expect(await replacement.isActive())
                await delegate.approve()
                await #expect(throws: ApprovalError.cancelled(requestID: callID)) {
                    try await approval.value
                }
                await replacement.finish()
            } else {
                await handle.revoke()
                await delegate.approve()
                await #expect(throws: ApprovalError.cancelled(requestID: callID)) {
                    try await approval.value
                }
                await handle.finish()
            }
            #expect(await delegate.requestCount == 1)
            #expect(await receipts.count == 0)
            #expect(await effects.count == 0)
            #expect(authority.facts.map(\.stage) == [.authorityCancelled])
            #expect(authority.facts.first?.compositeKey.toolCallID == callID)
        }
    }

    @Test func childApprovalRechecksOriginalParentAndChildBeforeReceipt() async throws {
        enum Outcome: CaseIterable {
            case parentRevoked
            case childRevoked
            case approved
        }

        for outcome in Outcome.allCases {
            let parentController = TurnController()
            let parentHandle = await parentController.beginTurn()
            let childController = TurnController()
            let childHandle = await childController.beginTurn()
            let suffix = UUID().uuidString
            let parentSessionID = "parent:\(suffix)"
            let parentConversationID = "conversation:\(suffix)"
            let childSessionID = "child:\(suffix)"
            let childTaskID = "child-task:\(suffix)"
            let parentIdentity = ParentRuntimeIdentity(
                sessionID: parentSessionID,
                conversationID: parentConversationID,
                turnID: "turn-handle:\(parentHandle.turnID)",
                taskID: "parent-task:\(suffix)",
                actorID: "test"
            )
            let childIdentity = try ChildRuntimeIdentity.derive(
                parent: parentIdentity,
                childSessionID: childSessionID,
                childTaskID: childTaskID,
                scopeID: "scope:\(suffix)",
                requestedCapabilities: [.tools],
                parentCapabilities: [.tools],
                policyCapabilities: [.tools],
                providerSnapshot: ParentContextSnapshotV1(
                    providerID: "synthetic-provider",
                    modelID: "synthetic-model",
                    configurationFingerprint: "synthetic-fingerprint",
                    conversationID: parentConversationID
                ),
                memoryScopeID: "memory:\(suffix)",
                workingDirectory: "/synthetic/no-write",
                cancelGeneration: parentHandle.turnID,
                evidenceRoot: "evidence:\(suffix)",
                parentTurnHandle: parentHandle,
                childExecutionID: "execution:\(suffix)"
            )
            let generationID = try #require(childIdentity.generationID)
            let delegate = LateTurnApprovalDelegate()
            let receipts = LateTurnReceiptProbe()
            let effects = LateTurnEffectProbe()
            let authority = LateTurnApprovalFactProbe()
            let gate = ApprovalGate(
                delegate: delegate,
                onApprovalReceipt: { receipt in await receipts.record(receipt) }
            )
            let boundary = try AgentChildBoundary(
                identity: childIdentity,
                parentCapabilities: [.tools],
                requestedCapabilities: [.tools],
                policy: AgentCapabilityPolicy(
                    allowedCapabilities: [.tools],
                    allowedToolNames: ["file_write"]
                ),
                parentTools: [AgentToolDefinition(
                    name: "file_write", description: "synthetic", parameters: [:], required: []
                )],
                budget: BudgetTracker(RequestBudget(maxRequestsPerSession: 2)),
                deadline: Date().addingTimeInterval(120),
                parentTurnHandle: parentHandle,
                childTurnController: childController,
                approvalGate: gate
            )
            let runtime = AgentExecutionContextSnapshot(
                provider: ToolApprovalMockLLMProvider(responses: []),
                approvalGate: gate,
                turnController: childController,
                currentConversationID: childSessionID,
                makeChildBudget: nil,
                deadline: Date().addingTimeInterval(120),
                parentTurnHandle: parentHandle,
                parentRuntimeIdentity: parentIdentity,
                childRuntimeSnapshot: AgentChildRuntimeSnapshot(identity: childIdentity)
            )
            let executionIdentity = AgentExecutionIdentity(
                turn: AgentTurnIdentity(
                    sessionID: childSessionID,
                    turnID: parentHandle.turnID,
                    messageID: childTaskID
                ),
                operationID: generationID,
                attempt: 1
            )
            let callID = "child-call:\(suffix)"
            let presentation = ApprovalPresentationContext(
                compositeKey: ToolExecutionCompositeKey(
                    sessionID: childSessionID,
                    turnID: parentHandle.turnID,
                    messageID: executionIdentity.turn.messageID,
                    operationID: executionIdentity.operationID,
                    attemptID: generationID,
                    attemptNumber: 1,
                    toolCallID: callID
                ),
                executionIdentity: executionIdentity,
                toolName: "file_write",
                eventSink: { authority.record($0) }
            )
            let approval = Task {
                try await ApprovalPresentationContext.$current.withValue(presentation) {
                    try await AgentExecutionContext.$current.withValue(runtime) {
                        let decision = try await gate.gateAgentCall(
                            tool: "file_write",
                            input: ["path": "/synthetic/no-write", "content": "sample"],
                            callID: callID,
                            executionIdentity: executionIdentity,
                            attemptID: generationID,
                            attemptNumber: 1,
                            childBoundary: boundary
                        )
                        await effects.execute() // synthetic direct consumer; never writes a file
                        return decision
                    }
                }
            }

            await delegate.waitForRequest()
            switch outcome {
            case .parentRevoked:
                await parentHandle.revoke()
            case .childRevoked:
                await childHandle.revoke()
            case .approved:
                break
            }
            await delegate.approve()
            if outcome == .approved {
                let decision = try await approval.value
                #expect(decision.approved)
                #expect(await receipts.count == 1)
                #expect(await receipts.sessionID == childSessionID)
                #expect(await receipts.turnID == parentHandle.turnID)
                #expect(await effects.count == 1)
                #expect(authority.facts.map(\.stage) == [.authorityApproved])
            } else {
                await #expect(throws: ApprovalError.cancelled(requestID: callID)) {
                    try await approval.value
                }
                #expect(await receipts.count == 0)
                #expect(await effects.count == 0)
                #expect(authority.facts.map(\.stage) == [.authorityCancelled])
            }
            #expect(await delegate.requestCount == 1)
            #expect(authority.facts.first?.compositeKey.toolCallID == callID)
            await childHandle.finish()
            await parentHandle.finish()
        }
    }
}
