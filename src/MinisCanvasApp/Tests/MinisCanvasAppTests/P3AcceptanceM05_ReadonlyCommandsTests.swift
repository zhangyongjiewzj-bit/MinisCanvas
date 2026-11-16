import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-COMMAND-05 readonly Composer commands")
@MainActor
struct P3AcceptanceM05ReadonlyCommandsTests {
    @Test func readonlyCommandsConsumeWithoutCanvasWriteGrantOrTranscriptMutation() {
        let defaults = UserDefaults(suiteName: "m05-readonly-\(UUID().uuidString)")!
        let chat = ChatStore(preferencesDefaults: defaults)
        let center = ComposerCommandAdjudicationCenter()
        chat.configureComposerPolicy(ComposerPolicyFactSource(
            knownCapabilities: [],
            grantedCapabilities: [],
            allowedWriteRoots: [],
            workspaceID: chat.composerWorkspaceID,
            revision: "m05-readonly-policy",
            grantEpoch: "m05-readonly-epoch",
            leaseID: "m05-readonly-lease",
            expiresAt: Date().addingTimeInterval(600),
            revoked: false
        ))
        chat.onComposerCommandPolicy = { request, submission in
            center.evaluate(request: request, snapshot: submission, facts: chat.composerPolicyFacts)
        }
        let transcriptBefore = chat.messages

        for id in ["status", "tasks", "boundary", "provider"] {
            chat.draftText = "/\(id)"
            chat.submitComposer()

            #expect(chat.lastComposerCommandReceipt?.commandID == id)
            #expect(chat.lastComposerCommandReceipt?.disposition == .execute)
            #expect(chat.pendingComposerCommand == nil)
            #expect(chat.messages == transcriptBefore)
            #expect(center.projection?.commandID == id)
        }
    }
}
