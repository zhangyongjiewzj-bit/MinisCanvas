import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-COMMAND-03 /help command argument")
@MainActor
struct P3AcceptanceM05HelpArgumentTests {
    @Test func specificHelpUsesCanonicalRegistryMetadataWithoutExecutingTarget() {
        let registry = CommandRegistry.shared
        registry.registerComposerCommands()
        let parsed = CommandParser().parse("/help boundary.set", registry: registry)
        #expect(parsed.args["command_id"] == "boundary.set")
        guard case .success(let request) = registry.validatedComposerPendingRequest(for: parsed) else {
            Issue.record("/help command_id was not routed")
            return
        }
        let (snapshot, facts) = context()
        let center = ComposerCommandAdjudicationCenter()

        #expect(center.evaluate(request: request, snapshot: snapshot, facts: facts) == .execute)
        let text = center.projection?.text ?? ""
        let metadata = CommandRegistry.composerMetadata(for: "boundary.set")
        #expect(text.contains("/boundary.set"))
        #expect(text.contains(metadata?.zhSummary ?? "missing Chinese summary"))
        #expect(text.contains(metadata?.enSummary ?? "missing English summary"))
        #expect(text.contains(metadata?.parameterSummary ?? "missing parameter summary"))
        #expect(text.contains("当前阻断：暂不可用，请在设置→智能体调整自主权上限。"))
        #expect(!text.contains("/canvas.run"))
        #expect(center.pendingAdjudication == nil)
    }

    @Test func unknownSpecificHelpIsVisibleAndNeverCreatesTargetPending() {
        let registry = CommandRegistry.shared
        registry.registerComposerCommands()
        let parsed = CommandParser().parse("/help no.such.command", registry: registry)
        guard case .success(let request) = registry.validatedComposerPendingRequest(for: parsed) else {
            Issue.record("/help unknown command argument was not routed as help")
            return
        }
        let (snapshot, facts) = context()
        let center = ComposerCommandAdjudicationCenter()

        #expect(center.evaluate(request: request, snapshot: snapshot, facts: facts) == .execute)
        #expect(center.projection?.text.contains("未知 Composer 命令：no.such.command") == true)
        #expect(center.pendingAdjudication == nil)
    }

    private func context() -> (ComposerSubmissionSnapshot, ComposerPolicyFactSource) {
        let workspaceID = "m05-help-argument"
        let revision = "m05-help-policy"
        let epoch = "m05-help-epoch"
        let now = Date()
        return (
            ComposerSubmissionSnapshot(
                mode: .manual,
                approvalScope: .request,
                effort: .standard,
                sessionID: "m05-help-session",
                turnID: 1,
                taskID: "chat:m05-help-session:1:attempt",
                workspaceID: workspaceID,
                createdAt: now,
                policyRevision: revision,
                grantEpoch: epoch
            ),
            ComposerPolicyFactSource(
                knownCapabilities: [],
                grantedCapabilities: [],
                allowedWriteRoots: [],
                workspaceID: workspaceID,
                revision: revision,
                grantEpoch: epoch,
                leaseID: "m05-help-lease",
                expiresAt: now.addingTimeInterval(600),
                revoked: false
            )
        )
    }
}
