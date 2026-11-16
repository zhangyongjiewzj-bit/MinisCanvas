import Foundation
import Testing
@testable import MinisCore

private final class WP3CountingExecutor: ToolExecutor, @unchecked Sendable {
    private(set) var executionCount = 0

    func execute(name: String, input: [String: Any]) async throws -> String {
        executionCount += 1
        return "executed:\(name)"
    }
}

private struct WP3ApprovalDelegate: ApprovalDelegate {
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        .approve
    }
}

@Suite("WP-3 capability boundary")
struct WP3CapabilityBoundaryTests {
    private let now = Date(timeIntervalSinceReferenceDate: 900_000_000)

    private func facts(
        known: Set<String> = ["canvas_mutation"],
        granted: Set<String> = ["canvas_mutation"],
        workspaceID: String = "wp3-workspace",
        revision: String = "wp3-revision",
        grantEpoch: String = "wp3-epoch",
        leaseID: String = "wp3-lease",
        expiresAt: Date? = nil,
        revoked: Bool = false
    ) -> ComposerPolicyFactSource {
        ComposerPolicyFactSource(
            knownCapabilities: known,
            grantedCapabilities: granted,
            allowedWriteRoots: ["/tmp/wp3"],
            workspaceID: workspaceID,
            revision: revision,
            grantEpoch: grantEpoch,
            leaseID: leaseID,
            expiresAt: expiresAt ?? now.addingTimeInterval(600),
            revoked: revoked,
            autonomyCeiling: .l3
        )
    }

    private func snapshot(
        capability: String = "canvas_mutation",
        workspaceID: String = "wp3-workspace",
        revision: String = "wp3-revision",
        grantEpoch: String = "wp3-epoch"
    ) throws -> (ComposerSubmissionSnapshot, [String: Any]) {
        let input: [String: Any] = ["command": capability]
        let frozen = try ComposerToolInput(input)
        return (
            ComposerSubmissionSnapshot(
                mode: .auto,
                approvalScope: .request,
                effort: .standard,
                sessionID: "wp3-session",
                turnID: 1,
                taskID: "wp3-task",
                attemptID: "wp3-attempt",
                messageID: "wp3-message",
                inputDigest: frozen.digest,
                workspaceID: workspaceID,
                createdAt: now,
                policyRevision: revision,
                grantEpoch: grantEpoch,
                autonomyCeiling: .l3
            ),
            input
        )
    }

    @Test
    func unknownCapabilityIsRejectedBeforeBottomExecutor() async throws {
        let probe = WP3CountingExecutor()
        let snapshot = try snapshot(capability: "unknown_capability").0
        let executor = ComposerPolicyEnforcedToolExecutor(
            base: probe,
            controller: ComposerAuthorizationController(
                snapshot: snapshot,
                facts: facts(),
                now: { self.now }
            )
        )

        await #expect(throws: ComposerAuthorizationError.self) {
            _ = try await executor.execute(
                name: "unknown_capability",
                input: ["command": "unknown_capability"]
            )
        }
        #expect(probe.executionCount == 0)
    }

    @Test
    func missingGrantIsRejectedBeforeBottomExecutor() async throws {
        let probe = WP3CountingExecutor()
        let (snapshot, input) = try snapshot()
        let executor = ComposerPolicyEnforcedToolExecutor(
            base: probe,
            controller: ComposerAuthorizationController(
                snapshot: snapshot,
                facts: facts(granted: []),
                now: { self.now }
            )
        )

        await #expect(throws: ComposerAuthorizationError.missingCapabilityGrant("canvas_mutation")) {
            _ = try await executor.execute(name: "canvas_mutation", input: input)
        }
        #expect(probe.executionCount == 0)
    }

    @Test
    func wrongScopeExpiredAndRevokedAuthorizationNeverReachBottomExecutor() async throws {
        let scenarios: [(String, ComposerPolicyFactSource, ComposerSubmissionSnapshot)] = [
            (
                "wrong-scope",
                facts(workspaceID: "other-workspace"),
                try snapshot(workspaceID: "wp3-workspace").0
            ),
            (
                "expired",
                facts(expiresAt: now.addingTimeInterval(-1)),
                try snapshot().0
            ),
            (
                "revoked",
                facts(revoked: true),
                try snapshot().0
            ),
        ]

        for (name, policyFacts, policySnapshot) in scenarios {
            let probe = WP3CountingExecutor()
            let executor = ComposerPolicyEnforcedToolExecutor(
                base: probe,
                controller: ComposerAuthorizationController(
                    snapshot: policySnapshot,
                    facts: policyFacts,
                    now: { self.now }
                )
            )

            do {
                _ = try await executor.execute(
                    name: "canvas_mutation",
                    input: ["command": name]
                )
                Issue.record("\(name) authorization should fail closed")
            } catch {
                // Expected: identity or lifecycle rejection before base.
            }
            #expect(probe.executionCount == 0)
        }
    }

    @Test
    func approvalRevokedBeforeWritebackCannotReachBottomExecutor() async throws {
        let probe = WP3CountingExecutor()
        let (snapshot, input) = try snapshot()
        let controller = ComposerAuthorizationController(
            snapshot: snapshot,
            facts: facts(),
            now: { self.now }
        )
        await controller.revoke()
        let executor = ComposerPolicyEnforcedToolExecutor(
            base: probe,
            controller: controller,
            approvalGate: ApprovalGate(delegate: WP3ApprovalDelegate())
        )

        await #expect(throws: ComposerAuthorizationError.authorizationRevoked) {
            _ = try await executor.execute(name: "canvas_mutation", input: input)
        }
        #expect(probe.executionCount == 0)
    }
}
