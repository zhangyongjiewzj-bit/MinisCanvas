import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-COMMAND-03 /help registry projection")
@MainActor
struct P3AcceptanceM05HelpRegistryTests {
    @Test func helpProjectsEveryCurrentlyRegisteredComposerCommand() {
        let registry = CommandRegistry.shared
        registry.registerComposerCommands()
        let commands = registry.allCommands().filter {
            CommandRegistry.composerCommandIDs.contains($0.id)
        }
        #expect(!commands.isEmpty)

        let workspaceID = "m05-help-registry"
        let revision = "m05-help-policy"
        let epoch = "m05-help-epoch"
        let now = Date()
        let facts = ComposerPolicyFactSource(
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
        let snapshot = ComposerSubmissionSnapshot(
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
        )
        let center = ComposerCommandAdjudicationCenter()
        let request = PendingCommandRequest(
            id: UUID(), commandID: "help", requiresPolicyApproval: false
        )

        #expect(center.evaluate(request: request, snapshot: snapshot, facts: facts) == .execute)
        let projection = center.projection?.text ?? ""
        for command in commands {
            #expect(projection.contains("/\(command.id) · \(command.title)"))
        }
        #expect(!projection.contains("尚无专属结果视图"))
    }
}
