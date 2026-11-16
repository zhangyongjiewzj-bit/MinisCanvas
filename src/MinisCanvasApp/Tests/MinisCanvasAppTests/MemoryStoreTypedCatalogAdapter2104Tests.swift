import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

private final class Memory2104ScopeBox {
    var current = MemoryScope(sessionID: "session-A", projectID: "project-A")
}

@Suite("2104 MemoryStore typed catalog adapter", .serialized)
@MainActor
struct MemoryStoreTypedCatalogAdapter2104Tests {
    private func fixture(_ label: String, scope: Memory2104ScopeBox) throws -> (SettingsCenter, URL) {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.rootDirectory.appendingPathComponent("memory-adapter-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
        return (center, root)
    }

    private func edited(_ value: BL6SettingValue, text: String? = nil,
                        active: Bool? = nil) throws -> BL6SettingValue {
        guard case .object(var fields) = value else {
            throw MemoryStoreTypedCatalogAdapter.Failure.invalidValue("fixture")
        }
        if let text { fields["text"] = .text(text) }
        if let active { fields["active"] = .toggle(active) }
        return .object(fields)
    }

    @Test("scoped typed edit delegates to the revision writer and survives reopen")
    func editAndReopen() throws {
        let scope = Memory2104ScopeBox()
        let (center, root) = try fixture("edit", scope: scope)
        #expect(center.addMemoryFact("旧事实"))
        let old = try #require(center.memoryFacts.first)
        let id = MemoryStoreTypedCatalogAdapter.settingID(for: old)
        let snapshot = try MemoryStoreTypedCatalogAdapter.snapshot(from: center)
        let liveValue = try #require(snapshot[id])
        guard case .object(let fields) = liveValue,
              case .object(let scoped)? = fields["scope"],
              case .text(let sessionID)? = scoped["sessionID"],
              case .text(let projectID)? = scoped["projectID"],
              case .object(let source)? = fields["source"],
              case .text(let proposalID)? = source["sourceProposalID"],
              case .object(let typedOrigin)? = source["typedProvenance"] else {
            Issue.record("typed snapshot lost concrete scope or source")
            return
        }
        #expect(sessionID == "session-A")
        #expect(projectID == "project-A")
        #expect(!proposalID.isEmpty)
        #expect(typedOrigin.isEmpty) // User-origin fact has no external actor claim.

        let proposed = try edited(liveValue, text: "新事实")
        let preview = try MemoryStoreTypedCatalogAdapter.preview(
            settingID: id, value: proposed, in: center
        )
        #expect(center.memoryFacts.first?.text == "旧事实")
        let effect = try MemoryStoreTypedCatalogAdapter.apply(preview, in: center)
        #expect(effect.after.id != old.id)
        #expect(effect.after.revision == old.revision + 1)
        #expect(effect.after.supersedesFactID == old.id)
        #expect(effect.after.memoryScope == old.memoryScope)
        #expect(effect.after.sourceProposalID == "user-edit:\(old.id):r\(old.revision + 1)")
        #expect(effect.lifecycleReceipt == nil)

        let durable = try MemoryStore(directory: root).facts()
        #expect(durable.first(where: { $0.id == old.id })?.lifecycleState == .superseded)
        #expect(durable.first(where: { $0.id == effect.after.id }) == effect.after)
        let (reopened, _) = try fixtureAtExistingRoot(root, scope: scope)
        let reopenSnapshot = try MemoryStoreTypedCatalogAdapter.snapshot(from: reopened)
        #expect(reopenSnapshot[id] == nil)
        #expect(reopenSnapshot[MemoryStoreTypedCatalogAdapter.settingID(for: effect.after)] != nil)
    }

    @Test("disable commits a lifecycle tombstone and cannot revive on reopen")
    func tombstoneAndReopen() throws {
        let scope = Memory2104ScopeBox()
        let (center, root) = try fixture("disable", scope: scope)
        #expect(center.addMemoryFact("要停用的事实"))
        let original = try #require(center.memoryFacts.first)
        let id = MemoryStoreTypedCatalogAdapter.settingID(for: original)
        let live = try #require(MemoryStoreTypedCatalogAdapter.snapshot(from: center)[id])
        let preview = try MemoryStoreTypedCatalogAdapter.preview(
            settingID: id, value: edited(live, active: false), in: center
        )
        let effect = try MemoryStoreTypedCatalogAdapter.apply(preview, in: center)
        #expect(effect.after.id == original.id)
        #expect(effect.after.lifecycleState == .tombstoned)
        #expect(effect.lifecycleReceipt?.action == .tombstone)
        #expect(center.memoryFacts.isEmpty)
        let reopenedStore = MemoryStore(directory: root)
        #expect(try reopenedStore.facts().first?.lifecycleState == .tombstoned)
        #expect(try reopenedStore.lifecycleReceipts().contains(where: {
            $0.factID == original.id && $0.action == .tombstone
        }))
        let (reopened, _) = try fixtureAtExistingRoot(root, scope: scope)
        #expect(try MemoryStoreTypedCatalogAdapter.snapshot(from: reopened)[id] == nil)
        #expect(throws: MemoryStoreTypedCatalogAdapter.Failure.unknownSetting(id)) {
            try MemoryStoreTypedCatalogAdapter.preview(
                settingID: id, value: live, in: reopened
            )
        }
    }

    @Test("scope, provenance, and stale revision cannot be changed by a preview")
    func rejectsScopeSourceAndStalePreview() throws {
        let scope = Memory2104ScopeBox()
        let (center, root) = try fixture("negative", scope: scope)
        #expect(center.addMemoryFact("原始内容"))
        let fact = try #require(center.memoryFacts.first)
        let id = MemoryStoreTypedCatalogAdapter.settingID(for: fact)
        let live = try #require(MemoryStoreTypedCatalogAdapter.snapshot(from: center)[id])
        guard case .object(let originalFields) = live else {
            Issue.record("missing typed object")
            return
        }
        var fields = originalFields
        fields["source"] = .object(["sourceRef": .text("forged")])
        #expect(throws: MemoryStoreTypedCatalogAdapter.Failure.invalidValue(id)) {
            try MemoryStoreTypedCatalogAdapter.preview(
                settingID: id, value: .object(fields), in: center
            )
        }
        fields = originalFields
        fields["scope"] = .object(["sessionID": .text("session-B"), "projectID": .text("project-B")])
        #expect(throws: MemoryStoreTypedCatalogAdapter.Failure.invalidValue(id)) {
            try MemoryStoreTypedCatalogAdapter.preview(
                settingID: id, value: .object(fields), in: center
            )
        }
        let preview = try MemoryStoreTypedCatalogAdapter.preview(
            settingID: id, value: edited(live, text: "合法待提交"), in: center
        )
        scope.current = MemoryScope(sessionID: "session-B", projectID: "project-B")
        #expect(try MemoryStoreTypedCatalogAdapter.snapshot(from: center).isEmpty)
        #expect(throws: MemoryStoreTypedCatalogAdapter.Failure.unknownSetting(id)) {
            try MemoryStoreTypedCatalogAdapter.apply(preview, in: center)
        }
        scope.current = MemoryScope(sessionID: "session-A", projectID: "project-A")
        _ = try center.editMemoryFact(id: fact.id, newText: "另一个写方已改")
        #expect(throws: MemoryStoreTypedCatalogAdapter.Failure.unknownSetting(id)) {
            try MemoryStoreTypedCatalogAdapter.apply(preview, in: center)
        }
        let durable = try MemoryStore(directory: root).facts()
        #expect(durable.filter { $0.lifecycleState == .active }.map(\.text) == ["另一个写方已改"])
        #expect(durable.count == 2)
    }

    private func fixtureAtExistingRoot(
        _ root: URL, scope: Memory2104ScopeBox
    ) throws -> (SettingsCenter, URL) {
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
        return (center, root)
    }
}
