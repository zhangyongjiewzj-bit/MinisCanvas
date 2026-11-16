import Foundation
import Testing
@testable import MinisCore

private actor GitSummaryApprovalDelegate: ApprovalDelegate {
    var requests: [ApprovalRequest] = []
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        requests.append(request)
        return ApprovalDecision(approved: false, confirmed: false,
            requestID: request.requestID, bindingDigest: request.identityDigest)
    }
}

@Suite("Git write approval display summary")
struct GitWriteApprovalSummaryConsumerTests {
    @Test func readonlySummaryReachesPromptWithoutChangingBoundInput() async throws {
        let now = Date()
        let input = try ComposerToolInput(["command": "git commit -m synthetic", "cwd": "/synthetic/project"])
        let snapshot = ComposerSubmissionSnapshot(mode: .manual, approvalScope: .session, effort: .standard,
            sessionID: "synthetic-session", turnID: 1, taskID: "synthetic-task", messageID: "synthetic-message",
            workspaceID: "synthetic-project", createdAt: now, policyRevision: "v1", autonomyCeiling: .l3)
        let facts = ComposerPolicyFactSource(knownCapabilities: ["shell_execute"], grantedCapabilities: ["shell_execute"],
            allowedWriteRoots: ["/synthetic/project"], workspaceID: "synthetic-project", revision: "v1",
            leaseID: "synthetic-lease", expiresAt: now.addingTimeInterval(600), autonomyCeiling: .l3)
        let delegate = GitSummaryApprovalDelegate()
        let executor = ComposerPolicyEnforcedToolExecutor(base: NoopToolExecutor(),
            controller: ComposerAuthorizationController(snapshot: snapshot, facts: facts),
            approvalGate: ApprovalGate(delegate: delegate))
        await GitWriteApprovalSummaryContext.$current.withValue({ captured, _ in
            #expect(captured.digest == input.digest)
            return "1 file changed, 2 insertions(+)"
        }) {
            await #expect(throws: ComposerAuthorizationError.approvalDenied(nil)) {
                _ = try await executor.requestApproval(callID: "synthetic-git", name: "shell_execute",
                    input: input, requiresSecondConfirmation: false)
            }
        }
        let request = try #require(await delegate.requests.first)
        #expect(request.inputDigest == input.digest)
        #expect(request.inputSummary.contains("1 file changed, 2 insertions(+)"))
        #expect(request.callID == "synthetic-git")
    }
}
