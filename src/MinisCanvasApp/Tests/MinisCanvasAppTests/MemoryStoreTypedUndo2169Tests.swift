import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

private final class Memory2169Scope {
    var current = MemoryScope(sessionID: "session-A", projectID: "project-A")
}

@Suite("2169 Memory owner edit undo", .serialized)
@MainActor
struct MemoryStoreTypedUndo2169Tests {
    private func center(at root: URL, scope: Memory2169Scope) throws -> SettingsCenter {
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: root),
            envStore: EnvVarStore(directory: root),
            memoryStore: MemoryStore(directory: root),
            sessionStore: SessionStore(directory: root),
            logManager: LogManager(directory: root, ringCapacity: 50),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json")),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills", isDirectory: true))
        )
        center.memoryScopeProvider = { scope.current }
        _ = try center.provisionBuiltInMemoryCandidateSubmissions()
        return center
    }

    private func fixture(_ label: String) throws -> (SettingsCenter, URL, Memory2169Scope) {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.rootDirectory.appendingPathComponent("memory-undo-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let scope = Memory2169Scope()
        return (try center(at: root, scope: scope), root, scope)
    }

    private func proposed(_ value: BL6SettingValue, text: String? = nil,
                          active: Bool? = nil) throws -> BL6SettingValue {
        guard case .object(var fields) = value else {
            throw MemoryStoreTypedCatalogAdapter.Failure.invalidValue("fixture")
        }
        if let text { fields["text"] = .text(text) }
        if let active { fields["active"] = .toggle(active) }
        return .object(fields)
    }

    @Test("owner edit undo restores the exact predecessor after a fresh Store reopen")
    func editUndoAndReopen() throws {
        let (center, root, scope) = try fixture("reopen")
        #expect(center.addMemoryFact("旧事实"))
        let original = try #require(center.memoryFacts.first)
        let id = MemoryStoreTypedCatalogAdapter.settingID(for: original)
        let value = try #require(MemoryStoreTypedCatalogAdapter.snapshot(from: center)[id])
        let edit = try MemoryStoreTypedCatalogAdapter.preview(
            settingID: id, value: proposed(value, text: "新事实"), in: center
        )
        let effect = try MemoryStoreTypedCatalogAdapter.apply(edit, in: center)

        let reopened = try self.center(at: root, scope: scope)
        let undo = try MemoryStoreTypedCatalogAdapter.previewUndo(effect, in: reopened)
        let receipt = try MemoryStoreTypedCatalogAdapter.undo(undo, in: reopened)
        #expect(receipt.action == .rollback)
        #expect(receipt.factID == effect.after.id)

        let freshStore = MemoryStore(directory: root)
        let facts = try freshStore.facts()
        #expect(facts.first(where: { $0.id == original.id }) == original)
        #expect(facts.first(where: { $0.id == effect.after.id })?.lifecycleState == .rolledBack)
        #expect(try freshStore.lifecycleReceipts().contains(receipt))
        let next = try self.center(at: root, scope: scope)
        #expect(try MemoryStoreTypedCatalogAdapter.snapshot(from: next)[id] == value)
        #expect(throws: MemoryStoreTypedCatalogAdapter.Failure.stalePreview) {
            try MemoryStoreTypedCatalogAdapter.undo(undo, in: next)
        }
    }

    @Test("scope change and a later revision reject the old undo without touching durable facts")
    func staleAndForeignScope() throws {
        let (center, root, scope) = try fixture("stale")
        #expect(center.addMemoryFact("原文"))
        let original = try #require(center.memoryFacts.first)
        let id = MemoryStoreTypedCatalogAdapter.settingID(for: original)
        let value = try #require(MemoryStoreTypedCatalogAdapter.snapshot(from: center)[id])
        let edit = try MemoryStoreTypedCatalogAdapter.preview(
            settingID: id, value: proposed(value, text: "第一次编辑"), in: center
        )
        let effect = try MemoryStoreTypedCatalogAdapter.apply(edit, in: center)
        let undo = try MemoryStoreTypedCatalogAdapter.previewUndo(effect, in: center)
        scope.current = MemoryScope(sessionID: "session-B", projectID: "project-B")
        #expect(throws: MemoryStoreTypedCatalogAdapter.Failure.invalidScope) {
            try MemoryStoreTypedCatalogAdapter.undo(undo, in: center)
        }
        scope.current = MemoryScope(sessionID: "session-A", projectID: "project-A")
        _ = try center.editMemoryFact(id: effect.after.id, newText: "第二次编辑")
        #expect(throws: MemoryStoreTypedCatalogAdapter.Failure.stalePreview) {
            try MemoryStoreTypedCatalogAdapter.undo(undo, in: center)
        }
        let active = try MemoryStore(directory: root).activeFacts()
        #expect(active.map(\.text) == ["第二次编辑"])
    }

    @Test("a tombstone has no ordinary undo and remains tombstoned after reopen")
    func tombstoneCannotUndo() throws {
        let (center, root, scope) = try fixture("tombstone")
        #expect(center.addMemoryFact("停用事实"))
        let original = try #require(center.memoryFacts.first)
        let id = MemoryStoreTypedCatalogAdapter.settingID(for: original)
        let value = try #require(MemoryStoreTypedCatalogAdapter.snapshot(from: center)[id])
        let disable = try MemoryStoreTypedCatalogAdapter.preview(
            settingID: id, value: proposed(value, active: false), in: center
        )
        let effect = try MemoryStoreTypedCatalogAdapter.apply(disable, in: center)
        let reopened = try self.center(at: root, scope: scope)
        #expect(throws: MemoryStoreTypedCatalogAdapter.Failure.undoUnsupported) {
            try MemoryStoreTypedCatalogAdapter.previewUndo(effect, in: reopened)
        }
        #expect(try MemoryStore(directory: root).facts().first?.lifecycleState == .tombstoned)
    }

    @Test("the Store rejects changed predecessor bytes under its transaction lock")
    func lockedPredecessorComparison() throws {
        let (center, root, _) = try fixture("locked")
        #expect(center.addMemoryFact("最初事实"))
        let original = try #require(center.memoryFacts.first)
        let id = MemoryStoreTypedCatalogAdapter.settingID(for: original)
        let value = try #require(MemoryStoreTypedCatalogAdapter.snapshot(from: center)[id])
        let edit = try MemoryStoreTypedCatalogAdapter.preview(
            settingID: id, value: proposed(value, text: "后来事实"), in: center
        )
        let effect = try MemoryStoreTypedCatalogAdapter.apply(edit, in: center)
        let realPredecessor = try #require(MemoryStore(directory: root).facts().first(where: {
            $0.id == original.id
        }))
        let changedPredecessor = MemoryFact(
            id: realPredecessor.id,
            text: "另一个版本的原文",
            sourceSessionID: realPredecessor.sourceSessionID,
            createdAt: realPredecessor.createdAt,
            category: realPredecessor.category,
            memoryScope: realPredecessor.memoryScope,
            ownerUserID: realPredecessor.ownerUserID,
            visibility: realPredecessor.visibility,
            temporaryLifetimeID: realPredecessor.temporaryLifetimeID,
            sourceProposalID: realPredecessor.sourceProposalID,
            sourceRef: realPredecessor.sourceRef,
            contentDigest: realPredecessor.contentDigest,
            writeProvenance: realPredecessor.writeProvenance,
            revision: realPredecessor.revision,
            supersedesFactID: realPredecessor.supersedesFactID,
            lifecycleState: realPredecessor.lifecycleState,
            activatedAt: realPredecessor.activatedAt
        )
        let store = MemoryStore(directory: root)
        #expect(throws: MemoryStoreError.concurrentMutation) {
            try store.rollbackRevision(
                expectedSuccessor: effect.after,
                expectedPredecessor: changedPredecessor,
                reason: "受控编辑撤销"
            )
        }
        #expect(try store.activeFacts().map(\.id) == [effect.after.id])
        #expect(try store.lifecycleReceipts().isEmpty)
    }
}
