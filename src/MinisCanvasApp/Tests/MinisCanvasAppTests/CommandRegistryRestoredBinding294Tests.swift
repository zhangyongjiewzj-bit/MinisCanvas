import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-COMMAND-02 restored binding without execution")
@MainActor
struct CommandRegistryRestoredBinding294Tests {
    private func chat(root: URL, suffix: String) -> ChatStore {
        ChatStore(
            preferencesDefaults: UserDefaults(suiteName: "registry294.\(root.lastPathComponent).\(suffix)")!,
            logManager: LogManager(directory: root.appendingPathComponent("logs-\(suffix)"))
        )
    }

    @Test(arguments: ["pending", "reject", "execute"])
    func restoredReceiptBindsWithoutReplayAndRemainsImmutable(disposition: String) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("registry-restored294-\(UUID().uuidString)", isDirectory: true)
        let store = SessionStore(directory: root)
        let now = Date()
        try store.updateSession(ChatSession(
            id: UUID().uuidString, title: "synthetic restored registry",
            createdAt: now, updatedAt: now, messages: []
        ))
        let first = chat(root: root, suffix: "first")
        #expect(first.attachPersistence(store))
        first.onComposerCommandPolicy = { _, _ in
            switch disposition {
            case "pending": return .pending
            case "reject": return .reject
            default: return .execute
            }
        }
        // N05 made /model a low-risk settings handoff. Exercise the same
        // immutable pending receipt with an actually approval-gated command.
        first.draftText = "/provider.use provider_model=synthetic-model"
        first.submitComposer()
        let receipt = try #require(first.lastComposerCommandReceipt)
        let pending = first.pendingComposerCommand
        if disposition == "pending" { #expect(pending?.requiresPolicyApproval == true) }
        let before = first.messages
        #expect(!first.installComposerCommandRegistry(CommandRegistry()))

        let restored = chat(root: root, suffix: "restored")
        #expect(restored.attachPersistence(store))
        #expect(restored.lastComposerCommandReceipt == receipt)
        #expect(restored.pendingComposerCommand == pending)
        let registry = CommandRegistry()
        registry.registerComposerCommands()
        let center = ComposerCommandAdjudicationCenter()
        var evaluated = 0
        restored.onComposerCommandPolicy = { _, _ in evaluated += 1; return .execute }
        #expect(ProductionCommandRegistryWiring.bind(registry: registry, chat: restored, center: center))
        #expect(ProductionCommandRegistryWiring.bind(registry: registry, chat: restored, center: center))
        #expect(restored.registeredComposerCommandRegistry === registry)
        #expect(center.commandRegistry === registry)
        #expect(evaluated == 0)
        #expect(center.projection == nil)
        #expect(center.pendingAdjudication == nil)
        #expect(restored.pendingComposerCommand == pending)
        #expect(restored.lastComposerCommandReceipt == receipt)
        #expect(restored.messages == before)
        #expect(!restored.installComposerCommandRegistry(CommandRegistry()))
        #expect(!center.installCommandRegistry(CommandRegistry()))
        #expect(restored.lastComposerCommandReceipt == receipt)
    }

    @Test func centerRejectsFirstInstallationAfterAnEvaluation() {
        let center = ComposerCommandAdjudicationCenter()
        let now = Date()
        let facts = ComposerPolicyFactSource(
            knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: "registry294", revision: "registry294", grantEpoch: "registry294",
            leaseID: "registry294", expiresAt: now.addingTimeInterval(600), revoked: false
        )
        let snapshot = ComposerSubmissionSnapshot(
            mode: .manual, approvalScope: .request, effort: .standard,
            sessionID: "registry294", turnID: 1, taskID: "chat:registry294:1",
            workspaceID: "registry294", createdAt: now,
            policyRevision: facts.revision, grantEpoch: facts.grantEpoch
        )
        _ = center.evaluate(
            request: PendingCommandRequest(id: UUID(), commandID: "status", requiresPolicyApproval: false),
            snapshot: snapshot, facts: facts
        )
        #expect(!center.installCommandRegistry(CommandRegistry()))
    }
    @Test(arguments: ["help", "status"])
    func readProjectionDoesNotApproveOrExecuteRestoredPending(commandID: String) {
        let registry = CommandRegistry()
        registry.registerComposerCommands()
        let center = ComposerCommandAdjudicationCenter()
        #expect(center.installCommandRegistry(registry))
        let old = PendingCommandRequest(
            id: UUID(), commandID: "model", args: ["model": "synthetic-model"],
            requiresPolicyApproval: true
        )
        var replayed = 0
        var settingsOpened = 0
        var terminals = 0
        center.replaySubmittedCommand = { _ in replayed += 1 }
        center.openCanonicalSettings = { settingsOpened += 1 }
        center.onPendingTerminalResolution = { _ in terminals += 1 }
        center.adoptRestoredPending(old, sessionID: "registry294")
        let now = Date()
        let facts = ComposerPolicyFactSource(
            knownCapabilities: [], grantedCapabilities: [], allowedWriteRoots: [],
            workspaceID: "registry294", revision: "registry294", grantEpoch: "registry294",
            leaseID: "registry294", expiresAt: now.addingTimeInterval(600), revoked: false
        )
        let snapshot = ComposerSubmissionSnapshot(
            mode: .manual, approvalScope: .request, effort: .standard,
            sessionID: "registry294", turnID: 1, taskID: "chat:registry294:1",
            workspaceID: "registry294", createdAt: now,
            policyRevision: facts.revision, grantEpoch: facts.grantEpoch
        )
        let read = PendingCommandRequest(id: UUID(), commandID: commandID, requiresPolicyApproval: false)
        #expect(center.evaluate(request: read, snapshot: snapshot, facts: facts) == .execute)
        #expect(center.projection?.id == read.id)
        #expect(center.pendingAdjudication?.id == old.id)
        #expect(center.lastResolution == nil)
        #expect(replayed == 0)
        #expect(settingsOpened == 0)
        #expect(terminals == 0)
        // This proves the adjudicator's read-only boundary only. ChatStore's
        // preexisting new-command overwrite of durable pending is tracked
        // separately; installation itself must never resolve/replay it.
    }

}
