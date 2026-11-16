import Foundation
import Testing
import CanvasCore
import MinisCore
@testable import MinisCanvasApp

@Suite("P1 Composer Canvas mutation approval boundary")
@MainActor
struct P1CanvasMutationApprovalBoundaryTests {
    @Test("approved mutation carries canvas identity and revision in its receipt")
    func approvedMutationProducesIdentityBoundReceipt() async throws {
        let target = CanvasMutationSpy()
        let facts = makeFacts()
        let coordinator = makeCoordinator(
            target: target,
            facts: facts,
            approval: .allow
        )

        let receipt = try await coordinator.execute(.addNode(type: "text", position: nil))

        #expect(target.addNodeCalls == 1)
        #expect(receipt.canvasID == target.currentCanvasID)
        #expect(receipt.baseRevision == 0)
        #expect(receipt.resultRevision == 1)
        #expect(receipt.approvalReceipt != nil)
    }

    @Test("approval denial reaches zero underlying mutation calls")
    func deniedMutationDoesNotCallTarget() async throws {
        let target = CanvasMutationSpy()
        let coordinator = makeCoordinator(
            target: target,
            facts: makeFacts(),
            approval: .deny
        )

        await #expect(throws: ComposerAuthorizationError.approvalDenied("Denied by user")) {
            _ = try await coordinator.execute(.resetStatuses)
        }

        #expect(target.totalMutationCalls == 0)
    }

    @Test("unknown capability is fail-closed before the target")
    func unknownCapabilityDoesNotCallTarget() async throws {
        let target = CanvasMutationSpy()
        let coordinator = makeCoordinator(
            target: target,
            facts: ComposerPolicyFactSource(
                knownCapabilities: [],
                grantedCapabilities: [],
                allowedWriteRoots: [],
                workspaceID: "workspace",
                revision: "revision",
                grantEpoch: "epoch",
                leaseID: "canvas-unknown-capability-lease",
                expiresAt: Date().addingTimeInterval(60),
                autonomyCeiling: .l1
            ),
            approval: .allow
        )

        await #expect(throws: ComposerAuthorizationError.unknownCapability("canvas_mutation")) {
            _ = try await coordinator.execute(.autoLayout)
        }

        #expect(target.totalMutationCalls == 0)
    }

    @Test("expired policy facts and stale canvas revision both stop before mutation")
    func expiredOrStaleRequestDoesNotCallTarget() async throws {
        let target = CanvasMutationSpy()
        let expired = makeCoordinator(
            target: target,
            facts: ComposerPolicyFactSource(
                knownCapabilities: ["canvas_mutation"],
                grantedCapabilities: ["canvas_mutation"],
                allowedWriteRoots: [],
                workspaceID: "workspace",
                revision: "revision",
                grantEpoch: "epoch",
                leaseID: "canvas-expired-lease",
                expiresAt: Date(timeIntervalSince1970: 0),
                autonomyCeiling: .l1
            ),
            approval: .allow
        )

        await #expect(throws: ComposerAuthorizationError.factsExpired) {
            _ = try await expired.execute(.resetStatuses)
        }
        #expect(target.totalMutationCalls == 0)

        let targetWithDrift = CanvasMutationSpy()
        let coordinator = makeCoordinator(
            target: targetWithDrift,
            facts: makeFacts(),
            approval: .allow
        )
        let request = coordinator.makeRequest(.resetStatuses)
        targetWithDrift.graph.revision = 4

        await #expect(throws: CanvasMutationError.staleRevision(expected: 0, actual: 4)) {
            _ = try await coordinator.execute(request)
        }
        #expect(targetWithDrift.totalMutationCalls == 0)
    }

    @Test("canvas identity drift is rejected before the target")
    func canvasIdentityDriftDoesNotCallTarget() async throws {
        let target = CanvasMutationSpy()
        let coordinator = makeCoordinator(
            target: target,
            facts: makeFacts(),
            approval: .allow
        )
        let request = coordinator.makeRequest(.resetStatuses)
        let expected = target.currentCanvasID
        target.currentCanvasID = UUID()

        await #expect(throws: CanvasMutationError.staleCanvas(
            expected: expected,
            actual: target.currentCanvasID
        )) {
            _ = try await coordinator.execute(request)
        }
        #expect(target.totalMutationCalls == 0)
    }

    @Test("cross-session mutation is rejected before the target")
    func crossSessionMutationDoesNotCallTarget() async throws {
        let target = CanvasMutationSpy()
        let coordinator = makeCoordinator(
            target: target,
            facts: makeFacts(),
            snapshotSessionID: "session-b"
        )
        let request = CanvasMutationRequest(
            canvasID: target.currentCanvasID,
            baseRevision: target.graph.revision,
            baseFingerprint: target.graph.fingerprint,
            originSessionID: "session-a",
            operation: .resetStatuses
        )

        await #expect(throws: ChatCanvasBoundaryError.sessionMismatch(
            origin: "session-a",
            active: "session-b"
        )) {
            _ = try await coordinator.execute(request)
        }
        #expect(target.totalMutationCalls == 0)
    }

    @Test("missing origin session is rejected before the target")
    func missingOriginSessionDoesNotCallTarget() async throws {
        let target = CanvasMutationSpy()
        let coordinator = makeCoordinator(
            target: target,
            facts: makeFacts()
        )
        let request = CanvasMutationRequest(
            canvasID: target.currentCanvasID,
            baseRevision: target.graph.revision,
            baseFingerprint: target.graph.fingerprint,
            operation: .resetStatuses
        )

        await #expect(throws: ChatCanvasBoundaryError.originSessionMissing) {
            _ = try await coordinator.execute(request)
        }
        #expect(target.totalMutationCalls == 0)
    }

    @Test("revoked authorization reaches zero underlying mutation calls")
    func revokedAuthorizationDoesNotCallTarget() async throws {
        let target = CanvasMutationSpy()
        let coordinator = makeCoordinator(
            target: target,
            facts: ComposerPolicyFactSource(
                knownCapabilities: ["canvas_mutation"],
                grantedCapabilities: ["canvas_mutation"],
                allowedWriteRoots: [],
                workspaceID: "workspace",
                revision: "revision",
                grantEpoch: "epoch",
                leaseID: "canvas-revoked-lease",
                expiresAt: Date().addingTimeInterval(60),
                revoked: true,
                autonomyCeiling: .l1
            )
        )

        await #expect(throws: ComposerAuthorizationError.authorizationRevoked) {
            _ = try await coordinator.execute(.resetStatuses)
        }
        #expect(target.totalMutationCalls == 0)
    }

    @Test("late request after a session switch reaches zero underlying mutation calls")
    func lateSessionRequestDoesNotCallTarget() async throws {
        let target = CanvasMutationSpy()
        let coordinator = makeCoordinator(
            target: target,
            facts: makeFacts(),
            snapshotSessionID: "session-new"
        )
        let request = CanvasMutationRequest(
            canvasID: target.currentCanvasID,
            baseRevision: target.graph.revision,
            baseFingerprint: target.graph.fingerprint,
            originSessionID: "session-old",
            operation: .resetStatuses
        )

        await #expect(throws: ChatCanvasBoundaryError.sessionMismatch(
            origin: "session-old",
            active: "session-new"
        )) {
            _ = try await coordinator.execute(request)
        }
        #expect(target.totalMutationCalls == 0)
        #expect(coordinator.receipts.isEmpty)
    }

    @Test("approval receipt is identity-bound and persisted with the mutation receipt")
    func approvalReceiptIsIdentityBound() async throws {
        let target = CanvasMutationSpy()
        let coordinator = makeCoordinator(
            target: target,
            facts: makeFacts(),
            approval: .allow
        )

        let receipt = try await coordinator.execute(.addNode(type: "text", position: nil))
        let approval = try #require(receipt.approvalReceipt)

        #expect(approval.callID == receipt.requestID.uuidString)
        #expect(approval.sessionID == "session")
        #expect(approval.policyRevision == "revision")
        #expect(approval.grantEpoch == "epoch")
        #expect(!approval.digest.isEmpty)
        #expect(coordinator.receipts == [receipt])
    }

    private func makeFacts() -> ComposerPolicyFactSource {
        ComposerPolicyFactSource(
            knownCapabilities: ["canvas_mutation"],
            grantedCapabilities: ["canvas_mutation"],
            allowedWriteRoots: [],
            workspaceID: "workspace",
            revision: "revision",
            grantEpoch: "epoch",
            leaseID: "canvas-boundary-lease",
            expiresAt: Date().addingTimeInterval(60),
            autonomyCeiling: .l1
        )
    }

    private func makeCoordinator(
        target: CanvasMutationSpy,
        facts: ComposerPolicyFactSource,
        approval: ApprovalChoice = .allow,
        snapshotSessionID: String = "session"
    ) -> CanvasMutationCoordinator {
        CanvasMutationCoordinator(
            target: target,
            facts: facts,
            grants: ComposerApprovalGrantStore(),
            approvalGate: ApprovalGate(delegate: approval),
            snapshotFactory: { request, input in
                ComposerSubmissionSnapshot(
                    mode: .manual,
                    approvalScope: .request,
                    effort: .standard,
                    sessionID: snapshotSessionID,
                    turnID: 1,
                    taskID: "task:\(request.id.uuidString)",
                    attemptID: "attempt",
                    messageID: request.id.uuidString,
                    inputDigest: input.digest,
                    workspaceID: facts.workspaceID,
                    createdAt: Date(),
                    policyRevision: facts.revision,
                    grantEpoch: facts.grantEpoch,
                    autonomyCeiling: facts.autonomyCeiling
                )
            },
            originSessionIDProvider: {
                snapshotSessionID
            }
        )
    }
}

private enum ApprovalChoice: ApprovalDelegate {
    case allow
    case deny

    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        switch self {
        case .allow:
            return ApprovalDecision(
                approved: true,
                confirmed: true,
                requestID: request.requestID,
                bindingDigest: request.identityDigest
            )
        case .deny:
            return .deny
        }
    }
}

@MainActor
private final class CanvasMutationSpy: CanvasMutationTarget {
    var currentCanvasID = UUID()
    var graph = NodeGraph()
    var addNodeCalls = 0
    var totalMutationCalls = 0

    @discardableResult
    func addNode(ofType _: String, at _: Point?) -> CanvasNode? {
        addNodeCalls += 1
        totalMutationCalls += 1
        graph.revision += 1
        return nil
    }

    func runGraph(from _: Set<UUID>?) {
        totalMutationCalls += 1
    }

    func autoLayout() {
        totalMutationCalls += 1
    }

    func resetStatuses() {
        totalMutationCalls += 1
    }

    @discardableResult
    func deleteCanvas(id _: UUID) -> Bool {
        totalMutationCalls += 1
        return true
    }

    func removeNode(id _: UUID) {
        totalMutationCalls += 1
    }
}
