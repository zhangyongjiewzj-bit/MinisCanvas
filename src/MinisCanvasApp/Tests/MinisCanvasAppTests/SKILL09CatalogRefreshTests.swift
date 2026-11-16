import Darwin
import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private func sk09TempDir(_ label: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SK9-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func writeSK09Skill(at directory: URL, content: String) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try content.write(
        to: directory.appendingPathComponent("SKILL.md"),
        atomically: true,
        encoding: .utf8
    )
}

@Suite("SKILL-09 catalog refresh binding")
struct SKILL09CatalogRefreshTests {
    @MainActor
    @Test func incompletePickerBatchIsNotCachedAndSameScopeCanRetry() throws {
        let root = try sk09TempDir("incomplete-picker")
        defer {
            SkillCatalogCache.invalidateDefaultCatalog()
            try? FileManager.default.removeItem(at: root)
        }
        let store = SkillStore(skillsRoot: root)
        let imported = try store.importSkillThroughLifecycle(
            content: "---\nname: Retry Picker\nversion: 1.0.0\n---\nSynthetic body",
            source: .file, reason: "picker retry fixture",
            approval: SkillApproval(approverID: "skill09-test")
        )
        let lock = store.skillDirectoryURL(for: imported.skill.id).appendingPathComponent(".skill-import.lock")
        let writer = open(lock.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        try #require(writer >= 0)
        defer { close(writer) }
        try #require(flock(writer, LOCK_EX | LOCK_NB) == 0)
        SkillCatalogCache.invalidateDefaultCatalog()

        let incomplete = SkillCatalogCache.loadCatalogCachedWithDiagnostics(appStore: store, servers: [])
        #expect(incomplete.diagnostics.batchIncomplete)
        #expect(incomplete.catalog.isEmpty)
        // Directly check cache state so approved-candidate cache miss logic
        // cannot make this regression pass with an incomplete cache entry.
        #expect(SkillCatalogCache.cachedDefaultStatus == nil)

        try #require(flock(writer, LOCK_UN) == 0)
        let retried = SkillCatalogCache.loadCatalogCachedWithDiagnostics(appStore: store, servers: [])
        #expect(!retried.diagnostics.batchIncomplete)
        #expect(retried.catalog.map(\.id) == ["skill:\(imported.skill.id)"])
        #expect(retried.generation > incomplete.generation)
    }

    @MainActor
    @Test func sameRootReopenDoesNotReuseAnEmptyPrewarmOverAnApprovedSkill() throws {
        let appRoot = try sk09TempDir("reopen-app")
        let otherRoot = try sk09TempDir("other-app")
        // Keep these owned roots for the run owner's same-epoch fixture inventory.
        defer { SkillCatalogCache.invalidateDefaultCatalog() }
        let store = SkillStore(skillsRoot: appRoot)
        let empty = SkillCatalogCache.loadCatalogCachedWithDiagnostics(
            appStore: store, servers: []
        )
        #expect(empty.catalog.isEmpty)

        let pending = try store.importSkillThroughLifecycle(
            content: "---\nname: Reopen Owned\nversion: 1.0.0\n---\nowned body",
            source: .file,
            reason: "owned pending fixture"
        )
        #expect(pending.receipt.state == .proposed)
        let stillPending = SkillCatalogCache.loadCatalogCachedWithDiagnostics(
            appStore: SkillStore(skillsRoot: appRoot), servers: []
        )
        #expect(stillPending.catalog.isEmpty)
        #expect(stillPending.generation == empty.generation,
                "A pending proposal must not force a picker rescan or become selectable")

        let quarantined = try store.importSkillThroughLifecycle(
            content: "---\nname: Untrusted Owned\nversion: 1.0.0\n---\nowned body",
            source: .url("https://example.invalid/owned-skill.md"),
            reason: "owned quarantine fixture"
        )
        #expect(quarantined.receipt.state == .quarantined)
        let stillQuarantined = SkillCatalogCache.loadCatalogCachedWithDiagnostics(
            appStore: SkillStore(skillsRoot: appRoot), servers: []
        )
        #expect(stillQuarantined.catalog.isEmpty)
        #expect(stillQuarantined.generation == empty.generation)

        let active = try store.approveAndActivateSkill(
            pending.skill.id,
            approval: SkillApproval(approverID: "skill09-explicit-owned-review", scope: nil),
            reason: "explicit owned approval"
        )
        #expect(active.state == .active)
        let reopenedStore = SkillStore(skillsRoot: appRoot)
        let recovered = SkillCatalogCache.loadCatalogCachedWithDiagnostics(
            appStore: reopenedStore, servers: []
        )
        #expect(recovered.generation > stillQuarantined.generation,
                "The ordinary cached loader must rescan a stale empty startup projection")
        #expect(recovered.catalog.map(\.id) == ["skill:\(pending.skill.id)"])
        let cachedAgain = SkillCatalogCache.loadCatalogCachedWithDiagnostics(
            appStore: reopenedStore, servers: []
        )
        #expect(cachedAgain.generation == recovered.generation,
                "A current nonempty projection remains a cache hit")

        let settings = SkillsStore(
            appStore: reopenedStore,
            stateFileURL: appRoot.appendingPathComponent("skills-enabled.json")
        )
        try settings.setEnabled("app:\(pending.skill.id)", enabled: false).get()
        let disabled = SkillCatalogCache.loadCatalogCachedWithDiagnostics(
            appStore: SkillStore(skillsRoot: appRoot),
            servers: [],
            enabledStates: SkillsStateStore.load(from: appRoot.appendingPathComponent("skills-enabled.json"))
        )
        #expect(disabled.catalog.isEmpty)
        // Keep the Settings override OFF while the canonical Core receipt is ON:
        // this distinguishes the override guard from Core's own disabled flag.
        reopenedStore.setEnabled(pending.skill.id, enabled: true)
        #expect(SkillStore(skillsRoot: appRoot).allSkills().contains {
            $0.id == pending.skill.id && $0.isEnabled
        })
        let disabledAgain = SkillCatalogCache.loadCatalogCachedWithDiagnostics(
            appStore: SkillStore(skillsRoot: appRoot),
            servers: [],
            enabledStates: SkillsStateStore.load(from: appRoot.appendingPathComponent("skills-enabled.json"))
        )
        #expect(disabledAgain.catalog.isEmpty)
        #expect(disabledAgain.generation == disabled.generation,
                "A Settings OFF override must keep an empty cache hit without another scan")

        let other = SkillCatalogCache.loadCatalogCachedWithDiagnostics(
            appStore: SkillStore(skillsRoot: otherRoot), servers: []
        )
        #expect(other.catalog.isEmpty)
        #expect(other.scopeKey != recovered.scopeKey)
    }

    @Test func pickerCacheReplacesReportWhenRootScopeChanges() throws {
        let firstRoot = try sk09TempDir("first")
        let secondRoot = try sk09TempDir("second")
        let appRoot = try sk09TempDir("app")
        defer {
            try? FileManager.default.removeItem(at: firstRoot)
            try? FileManager.default.removeItem(at: secondRoot)
            try? FileManager.default.removeItem(at: appRoot)
            SkillCatalogCache.invalidateDefaultCatalog()
        }
        let firstStore = SkillStore(skillsRoot: firstRoot)
        let firstBad = try firstStore.importSkill(content: "---\nname: Bad\nversion: 1.0.0\n---\nbody", source: .file)
        let firstGood = try firstStore.importSkillThroughLifecycle(
            content: "---\nname: Good\nversion: 1.0.0\n---\nbody", source: .file,
            reason: "SKILL-09 explicit canonical first-root fixture",
            approval: SkillApproval(approverID: "skill09-test"))
        try #require(firstGood.receipt.state == .active && firstGood.receipt.approvedBy == "skill09-test")
        try #require(firstStore.lifecycleReceipt(for: firstGood.skill.id)?.contentHash == firstGood.receipt.contentHash)
        try #require(firstStore.lifecycleReceipt(for: firstBad.id)?.state == .active)
        try #require(Set(firstStore.allSkills().map(\.id)) == Set([firstBad.id, firstGood.skill.id]))
        try writeSK09Skill(
            at: firstRoot.appendingPathComponent("bad"),
            content: "---\nname: Bad\nNAME: Duplicate\nversion: 1.0.0\n---\nSECRET_FIRST"
        )
        let store = SkillStore(skillsRoot: appRoot)
        // Cache scope now follows canonical App roots. Both positive rows
        // have explicit lifecycle approval; only the first root is damaged.
        let imported = try store.importSkillThroughLifecycle(
            content: "---\nname: Good\nversion: 1.0.0\n---\nbody",
            source: .file,
            reason: "SKILL-09 canonical refresh fixture",
            approval: SkillApproval(approverID: "skill09-test")
        )
        #expect(imported.receipt.state == .active)
        #expect(imported.receipt.approvedBy == "skill09-test")
        let reopened = SkillStore(skillsRoot: appRoot)
        #expect(reopened.lifecycleReceipt(for: imported.skill.id)?.state == .active)
        #expect(reopened.lifecycleReceipt(for: imported.skill.id)?.contentHash == imported.receipt.contentHash)
        let frozenStore = reopened.makeSnapshotStore()
        let firstSnapshot = firstStore.makeSnapshotStore()
        try #require(firstSnapshot.skillsRoot == firstRoot)
        try #require(Set(firstSnapshot.allSkills().map(\.id)) == Set([firstBad.id, firstGood.skill.id]))
        try #require(firstSnapshot.lifecycleReceipt(for: firstGood.skill.id)?.state == .active)
        try #require(firstSnapshot.lifecycleReceipt(for: firstGood.skill.id)?.contentHash == firstGood.receipt.contentHash)
        let first = SkillCatalogCache.loadCatalogCachedWithDiagnostics(
            appStore: firstSnapshot,
            servers: []
        )
        let second = SkillCatalogCache.loadCatalogCachedWithDiagnostics(
            appStore: frozenStore,
            servers: []
        )

        #expect(first.diagnostics.rejectedCount == 1)
        #expect(first.status == .degraded)
        #expect(first.catalog.map(\.name) == ["Good"])
        #expect(second.diagnostics.rejectedCount == 0)
        #expect(second.status == .ready)
        #expect(second.catalog.map(\.name) == ["Good"])
        let admitted = try #require(second.catalog.first)
        #expect(admitted.id == "skill:\(imported.skill.id)")
        #expect(admitted.source == .app)
        #expect(admitted.version == imported.skill.version)
        #expect(admitted.content == "body")
        #expect(second.generation > first.generation)
        #expect(second.scopeKey != first.scopeKey)
        #expect(!second.stableSummary.contains(firstRoot.path))
        #expect(!second.stableSummary.contains("SECRET_FIRST"))
    }

    @Test func refreshAlwaysAdvancesGenerationAndSummaryIsStable() throws {
        let root = try sk09TempDir("stable")
        let appRoot = try sk09TempDir("app")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: appRoot)
            SkillCatalogCache.invalidateDefaultCatalog()
        }
        let store = SkillStore(skillsRoot: appRoot)
        _ = try store.importSkill(content: "---\nname: Bad\nversion: 1.0.0\n---\nbody", source: .file)
        try writeSK09Skill(
            at: appRoot.appendingPathComponent("bad"),
            content: "---\nname: Bad\nNAME: Duplicate\nversion: 1.0.0\n---\nSECRET_STABLE"
        )
        let first = SkillCatalogCache.loadCatalogCachedWithDiagnostics(
            appStore: store,
            servers: []
        )
        let refreshed = SkillCatalogCache.refreshCatalogWithDiagnostics(
            appStore: store,
            servers: []
        )

        #expect(refreshed.generation > first.generation)
        #expect(refreshed.status == .degraded)
        #expect(refreshed.stableSummary == first.stableSummary)
        #expect(refreshed.stableSummary.contains("拒绝 1 项"))
        #expect(!refreshed.stableSummary.contains(root.path))
        #expect(!refreshed.stableSummary.contains("SECRET_STABLE"))
    }

    @Test func staleSettingsResultIsRejectedByGenerationAndScope() {
        var gate = SkillCatalogRefreshGate()
        let first = gate.begin(scopeKey: "scope-first")
        let second = gate.begin(scopeKey: "scope-second")

        #expect(!gate.accepts(first))
        #expect(gate.accepts(second))
        #expect(second.generation > first.generation)
    }
}
