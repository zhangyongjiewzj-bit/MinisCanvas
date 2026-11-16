import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("N16 canonical App skill maintenance", .serialized)
@MainActor
struct N16SkillMaintenanceTests {
    private func document(_ name: String = "n16-owned", version: String = "1.0.0", body: String = "old approved constraint") -> String {
        "---\nname: \(name)\ndescription: N16 owned skill\nversion: \(version)\n---\n\(body)"
    }

    private func root() throws -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent("n16-owned-\(UUID())")
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }

    private func settings(_ root: URL, store: SkillStore) -> SkillsStore {
        SkillsStore( appStore: store,
                    stateFileURL: root.appendingPathComponent("enabled.json"))
    }

    private func selected(_ root: URL, content: String) throws -> URL {
        let source = root.appendingPathComponent("selected-\(UUID())")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try content.write(to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return source
    }

    private func confirmed(_ intent: OperationIntent) -> OperationIntent {
        intent.withFirstConfirmation("reviewed exact target").withSecondConfirmation("move to recoverable trash")
    }

    @Test func productionStartupDoesNotReplaceApprovedSkills() async throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "N16Startup",
            processEnvironment: [:], processArguments: ["MinisCanvasAppTests.xctest"], canvasRuntimeState: .disabled)
        defer { try? FileManager.default.removeItem(at: profile.rootDirectory) }
        let external = profile.hermesSkillsDirectory.appendingPathComponent("creative/manju-core")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try document("manju-core", body: "external bytes must never be imported")
            .write(to: external.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let store = SkillStore(skillsRoot: profile.rootDirectory.appendingPathComponent("owned-skills"))
        let prior = try store.importSkillThroughLifecycle(content: document("manju-core"),
            source: .file, reason: "owned startup fixture",
            approval: SkillApproval(approverID: "n16-owned-reviewer")).receipt
        let bridge = BridgeStore(preferencesDefaults: profile.makeUserDefaults(), logManager: profile.makeLogManager(),
            workflowStore: WorkflowStore(storeDirectory: profile.rootDirectory.appendingPathComponent("workflows")),
            sessionBadgeStore: SessionBadgeStore(directory: profile.rootDirectory.appendingPathComponent("badges")),
            sessionDocumentStore: SessionDocumentStore(directory: profile.sessionDirectory), canvasRuntimeState: .disabled,
            agentTaskStore: try AgentTaskStore(persistenceURL: profile.rootDirectory.appendingPathComponent("tasks.json")),
            contextManifestStore: try ContextManifestStore(persistenceURL: profile.rootDirectory.appendingPathComponent("manifests.json")))
        await bridge.attachProductionServices(fileAccessAllowedRoot: profile.rootDirectory, fileAccessDeniedRoots: [],
            sessionDirectory: profile.sessionDirectory,
            mcpManager: MCPServerManager(fileURL: profile.mcpConfigurationURL, keychain: profile.makeKeychainStore()),
            skillStore: store, canvasRuntimeState: .disabled, externalRunners: [:], externalNetworkAllowed: false).value
        let deadline = Date().addingTimeInterval(3)
        while bridge.skillDeploymentStatus == .pending && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(bridge.skillDeploymentStatus == .ready(imported: []))
        #expect(store.allSkills().count == 1)
        #expect(store.lifecycleReceipt(for: "manju-core") == prior)
        #expect(store.rawContent("manju-core") == document("manju-core"))
    }

    @Test func updateUsesSameIDAndRestartReviewThenRollbackRestoresOldBytes() throws {
        let owned = try root()
        defer { try? FileManager.default.removeItem(at: owned) }
        let canonical = SkillStore(skillsRoot: owned.appendingPathComponent("skills"))
        let old = document()
        _ = try canonical.importSkill(content: old)
        let first = settings(owned, store: canonical)
        _ = try first.setEnabled("app:n16-owned", enabled: false).get()
        let replacement = document(version: "2.0.0", body: "new proposed constraint")
        let source = try selected(owned, content: replacement)
        let draft = try first.proposeLocalSkill(from: source, replacing: "app:n16-owned").get()
        #expect(draft.skillID == "n16-owned")
        #expect(canonical.allSkills().count == 1)
        #expect(canonical.lifecycleReceipt(for: draft.skillID)?.state == .proposed)
        #expect(canonical.allSkills().first?.isEnabled == false)
        let reopenedStore = SkillStore(skillsRoot: canonical.skillsRoot)
        let reopened = settings(owned, store: reopenedStore)
        let recovered = try #require(reopened.pendingLocalSkillReview(for: "app:n16-owned"))
        _ = try reopened.approveLocalSkill(recovered).get()
        #expect(reopened.isEnabled("app:n16-owned") == false)
        #expect(reopenedStore.allSkills().first?.isEnabled == false)
        #expect(reopenedStore.rawContent("n16-owned") == replacement)
        #expect(reopened.canRollback("app:n16-owned"))
        _ = try reopened.rollback("app:n16-owned").get()
        #expect(reopenedStore.rawContent("n16-owned") == old)
        #expect(reopenedStore.allSkills().count == 1)
    }

    @Test func updateRejectsDifferentIDWithoutChangingOriginal() throws {
        let owned = try root()
        defer { try? FileManager.default.removeItem(at: owned) }
        let canonical = SkillStore(skillsRoot: owned.appendingPathComponent("skills"))
        _ = try canonical.importSkill(content: document())
        let consumer = settings(owned, store: canonical)
        let source = try selected(owned, content: document("different-id"))
        #expect(consumer.proposeLocalSkill(from: source, replacing: "app:n16-owned") == .failure(.updateIdentityMismatch))
        #expect(canonical.rawContent("n16-owned") == document())
        #expect(canonical.allSkills().map(\.id) == ["n16-owned"])
    }

    @Test func pendingUpdateCannotReplaceTheVersionBeingReviewed() throws {
        let owned = try root()
        defer { try? FileManager.default.removeItem(at: owned) }
        let canonical = SkillStore(skillsRoot: owned.appendingPathComponent("skills"))
        _ = try canonical.importSkill(content: document())
        let consumer = settings(owned, store: canonical)
        let firstContent = document(version: "2.0.0", body: "review this exact candidate")
        let first = try selected(owned, content: firstContent)
        let draft = try consumer.proposeLocalSkill(from: first, replacing: "app:n16-owned").get()
        let second = try selected(owned, content: document(version: "3.0.0", body: "unreviewed overwrite"))
        #expect(consumer.proposeLocalSkill(from: second, replacing: "app:n16-owned") == .failure(.updateReviewPending))
        #expect(canonical.rawContent("n16-owned") == firstContent)
        _ = try consumer.approveLocalSkill(draft).get()
        _ = try consumer.rollback("app:n16-owned").get()
        #expect(canonical.rawContent("n16-owned") == document())
    }

    @Test func deletionRequiresConfirmationAndRestoresAfterRestartWithAttachments() throws {
        let owned = try root()
        defer { try? FileManager.default.removeItem(at: owned) }
        let canonical = SkillStore(skillsRoot: owned.appendingPathComponent("skills"))
        _ = try canonical.importSkill(content: document())
        let attached = canonical.skillDirectoryURL(for: "n16-owned").appendingPathComponent("owned-reference.txt")
        try Data("reference bytes".utf8).write(to: attached)
        let consumer = settings(owned, store: canonical)
        let preview = try consumer.previewSkillDeletion("app:n16-owned")
        #expect(throws: DeletionGateError.firstConfirmationRequired) { try consumer.deleteSkill(preview) }
        let receipt = try consumer.deleteSkill(confirmed(preview))
        #expect(!FileManager.default.fileExists(atPath: attached.path))
        let reopenedStore = SkillStore(skillsRoot: canonical.skillsRoot)
        let reopened = settings(owned, store: reopenedStore)
        let recovery = try #require(reopened.deletedSkillReceipts.first)
        #expect(recovery.operationID == receipt.operationID)
        try reopened.restoreDeletedSkill(recovery)
        #expect(reopenedStore.rawContent("n16-owned") == document())
        #expect(try Data(contentsOf: attached) == Data("reference bytes".utf8))
        #expect(reopened.deletedSkillReceipts.isEmpty)
    }

    @Test func recoveryPreservesExistingDestination() throws {
        let owned = try root()
        defer { try? FileManager.default.removeItem(at: owned) }
        let canonical = SkillStore(skillsRoot: owned.appendingPathComponent("skills"))
        _ = try canonical.importSkill(content: document())
        let consumer = settings(owned, store: canonical)
        _ = try consumer.deleteSkill(confirmed(consumer.previewSkillDeletion("app:n16-owned")))
        let recovery = try #require(consumer.deletedSkillReceipts.first)
        _ = try canonical.importSkill(content: document(version: "3.0.0", body: "keep installed bytes"))
        #expect(throws: SkillDeletionError.restoreTargetExists("n16-owned")) { try consumer.restoreDeletedSkill(recovery) }
        #expect(canonical.rawContent("n16-owned")?.contains("keep installed bytes") == true)

    }
}
