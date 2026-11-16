import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private func sk10TempDir(_ label: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SK10-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func writeSK10Skill(at directory: URL, content: String) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try content.write(
        to: directory.appendingPathComponent("SKILL.md"),
        atomically: true,
        encoding: .utf8
    )
}

@Suite("SKILL-10 catalog refresh status")
struct SKILL10CatalogRefreshStatusTests {
    @Test func cacheStatusIsNilAfterInvalidationInsteadOfFakingSuccess() throws {
        let root = try sk10TempDir("status")
        let appRoot = try sk10TempDir("app")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: appRoot)
            SkillCatalogCache.invalidateDefaultCatalog()
        }
        let store = SkillStore(skillsRoot: appRoot)
        _ = SkillCatalogCache.loadCatalogCachedWithDiagnostics(
            appStore: store,
            servers: []
        )
        #expect(SkillCatalogCache.cachedDefaultStatus == .ready)
        SkillCatalogCache.invalidateDefaultCatalog()
        #expect(SkillCatalogCache.cachedDefaultStatus == nil)
    }

    @Test @MainActor func settingsStorePublishesDegradedStatusWithoutPath() throws {
        let hermesRoot = try sk10TempDir("settings-status")
        let appRoot = try sk10TempDir("app")
        defer {
            try? FileManager.default.removeItem(at: hermesRoot)
            try? FileManager.default.removeItem(at: appRoot)
        }
        try writeSK10Skill(
            at: hermesRoot.appendingPathComponent("bad"),
            content: "---\nname: Bad\nNAME: Duplicate\nversion: 1.0.0\n---\nSECRET_SETTINGS"
        )
        let store = SkillsStore(
            appStore: SkillStore(skillsRoot: appRoot),
            stateFileURL: appRoot.appendingPathComponent("skills-enabled.json")
        )
        _ = store.addSkillDirectory(hermesRoot)
        store.reload()

        #expect(store.catalogRefreshStatus == .degraded)
        #expect(store.catalogStatusSummary == "技能目录：部分项目被拒绝")
        #expect(!store.catalogStatusSummary.contains(hermesRoot.path))
        #expect(!store.catalogDiagnosticSummary.contains("SECRET_SETTINGS"))
    }
}
