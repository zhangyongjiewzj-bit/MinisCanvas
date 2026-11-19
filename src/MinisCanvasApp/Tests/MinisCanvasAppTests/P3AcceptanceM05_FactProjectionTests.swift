import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-COMMAND-05 readonly fact projection")
@MainActor
struct P3AcceptanceM05FactProjectionTests {
    @Test func boundaryAndProviderShowOnlyInjectedCurrentFactsOrExplicitUnknown() {
        let workspaceID = "m05-facts"
        let revision = "m05-facts-revision"
        let epoch = "m05-facts-epoch"
        let facts = ComposerPolicyFactSource(
            knownCapabilities: [],
            grantedCapabilities: [],
            allowedWriteRoots: [],
            workspaceID: workspaceID,
            revision: revision,
            grantEpoch: epoch,
            leaseID: "m05-facts-lease",
            expiresAt: Date().addingTimeInterval(600),
            revoked: false
        )
        let snapshot = ComposerSubmissionSnapshot(
            mode: .manual,
            approvalScope: .request,
            effort: .standard,
            sessionID: "m05-facts-session",
            turnID: 1,
            taskID: "chat:m05-facts-session:1:attempt",
            workspaceID: workspaceID,
            createdAt: Date(),
            policyRevision: revision,
            grantEpoch: epoch
        )
        let center = ComposerCommandAdjudicationCenter()

        let boundary = PendingCommandRequest(
            id: UUID(), commandID: "boundary", requiresPolicyApproval: false
        )
        #expect(center.evaluate(request: boundary, snapshot: snapshot, facts: facts) == .execute)
        #expect(center.projection?.text == "暂时读不到当前的安全边界设置；本命令没有改动任何设置。")
        center.boundaryProjection = { _ in "已提交安全边界修订：test-revision" }
        #expect(center.evaluate(request: boundary, snapshot: snapshot, facts: facts) == .execute)
        #expect(center.projection?.text == "已提交安全边界修订：test-revision")

        let provider = PendingCommandRequest(
            id: UUID(), commandID: "provider", requiresPolicyApproval: false
        )
        #expect(center.evaluate(request: provider, snapshot: snapshot, facts: facts) == .execute)
        #expect(center.projection?.text == "还没有选定可用的模型；本命令没有改动任何设置。")
        center.providerProjection = { _ in "已应用 Provider/Model：test-provider/test-model" }
        #expect(center.evaluate(request: provider, snapshot: snapshot, facts: facts) == .execute)
        #expect(center.projection?.text == "已应用 Provider/Model：test-provider/test-model")
    }
}
