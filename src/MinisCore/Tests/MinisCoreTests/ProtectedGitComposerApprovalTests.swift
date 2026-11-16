import Foundation
import Testing
@testable import MinisCore

@Suite("Repository control writes follow the confirmed Composer mode")
struct ProtectedGitComposerApprovalTests {
    @Test func protectedGitWriteAsksUnlessBypassIsConfirmed() async throws {
        let now = Date()
        let input = try ComposerToolInput(["path": "/synthetic/project/.git/config", "content": "synthetic"])
        for mode in [ComposerTaskMode.manual, .auto, .bypassPermission] {
            let snapshot = ComposerSubmissionSnapshot(mode: mode, approvalScope: .session, effort: .standard,
                sessionID: "synthetic-session", turnID: 1, taskID: "synthetic-task", messageID: "synthetic-message",
                workspaceID: "synthetic-project", createdAt: now, policyRevision: "v1",
                bypassModeConfirmed: mode == .bypassPermission, autonomyCeiling: .l3)
            let facts = ComposerPolicyFactSource(knownCapabilities: ["file_write"], grantedCapabilities: ["file_write"],
                allowedWriteRoots: ["/synthetic/project"], workspaceID: "synthetic-project", revision: "v1",
                leaseID: "synthetic-lease", expiresAt: now.addingTimeInterval(600), autonomyCeiling: .l3)
            let controller = ComposerAuthorizationController(snapshot: snapshot, facts: facts)
            try await controller.recordApproval(capability: "file_write", input: input)
            let executor = ComposerPolicyEnforcedToolExecutor(
                base: BuiltinToolExecutor(allowedRoot: URL(fileURLWithPath: "/synthetic/project"), deniedRoots: []),
                controller: controller, approvalGate: ApprovalGate(),
                hookHandler: { invocation in ComposerHookResult(verdict: .allow,
                    invocationIdentityDigest: invocation.identityDigest) })
            let decision = try await executor.authorizationDecision(callID: "protected-\(mode.rawValue)",
                capability: "file_write", input: input)
            #expect(decision.decision == (mode == .bypassPermission ? .execute : .requestApproval(requiresSecondConfirmation: false)))
        }
    }
}
