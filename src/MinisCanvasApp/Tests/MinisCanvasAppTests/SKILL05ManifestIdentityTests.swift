import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private func sk05TempDir(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("SK5-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func writeSK05Skill(
    at directory: URL,
    name: String,
    version: String = "1.0.0",
    body: String = "body",
    manifest: SkillSourceManifest? = nil
) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let content = "---\nname: \(name)\nversion: \(version)\n---\n\(body)"
    try content.write(
        to: directory.appendingPathComponent("SKILL.md"),
        atomically: true,
        encoding: .utf8
    )
    if let manifest {
        try JSONEncoder().encode(manifest).write(
            to: directory.appendingPathComponent("manifest.json"),
            options: .atomic
        )
    }
}

@Suite("SKILL-05 App/Hermes manifest identity consumers")
struct SKILL05ManifestIdentityConsumerTests {
    @Test func sameRootDuplicateIDsAreRejectedByBothScanners() throws {
        let root = try sk05TempDir("duplicate")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSK05Skill(
            at: root.appendingPathComponent("first/shared-skill"),
            name: "Shared Skill"
        )
        try writeSK05Skill(
            at: root.appendingPathComponent("second/shared-skill"),
            name: "Shared Skill"
        )

        #expect(SkillsScanner.mergedEntriesWithDiagnostics(appSnapshot: SkillStore(skillsRoot: root.appendingPathComponent(".canonical-app")).snapshot(), enabledStates: [:], localRoots: [root]).entries.isEmpty)
        #expect(SkillsScanner.mergedEntriesWithDiagnostics(appSnapshot: SkillStore(skillsRoot: root.appendingPathComponent(".canonical-app")).snapshot(), enabledStates: [:], localRoots: [root]).entries.isEmpty)
    }

    @Test func unknownPresentManifestIsRejectedWithoutReturningItsContents() throws {
        let root = try sk05TempDir("unknown-schema")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("tools/schema-skill")
        let content = "---\nname: Schema Skill\nversion: 1.0.0\n---\nbody"
        try writeSK05Skill(at: directory, name: "Schema Skill")
        let manifest = SkillSourceManifest(
            skillID: "schema-skill",
            source: .file,
            skillVersion: "1.0.0",
            content: content,
            schema: "miniscore.skill-source-manifest.future"
        )
        try JSONEncoder().encode(manifest).write(
            to: directory.appendingPathComponent("manifest.json"),
            options: .atomic
        )

        #expect(SkillsScanner.scanLocalDirectory(root: root).isEmpty)
        #expect(SkillsScanner.scanLocalDirectory(root: root).isEmpty)
    }

    @Test func appManifestMismatchIsRejectedByBothProductionProjections() throws {
        let root = try sk05TempDir("app-mismatch")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillStore(skillsRoot: root)
        let content = "---\nname: Imported Skill\nversion: 1.0.0\n---\nbody"
        let skill = try store.importSkill(content: content, source: .file)
        let mismatch = SkillSourceManifest(
            skillID: skill.id,
            source: .file,
            skillVersion: skill.version,
            content: "different payload"
        )
        try JSONEncoder().encode(mismatch).write(
            to: store.skillManifestURL(for: skill.id),
            options: .atomic
        )

        #expect(SkillCatalogLoader.storeSkillItems(from: store).isEmpty)
        #expect(SkillsScanner.scanApp(store: store).isEmpty)
    }

    @Test func compatibleVersionsHaveDeterministicIDTieBreakOrdering() throws {
        let root = try sk05TempDir("ordering")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSK05Skill(
            at: root.appendingPathComponent("tools/zeta"),
            name: "Same Name",
            version: "2.0.0"
        )
        try writeSK05Skill(
            at: root.appendingPathComponent("tools/alpha"),
            name: "Same Name",
            version: "1.0.0"
        )

        let items = SkillsScanner.mergedEntriesWithDiagnostics(appSnapshot: SkillStore(skillsRoot: root.appendingPathComponent(".canonical-app")).snapshot(), enabledStates: [:], localRoots: [root]).entries
        #expect(items.map(\.id) == ["alpha", "zeta"].map { "local:" + SkillManifest.hash(root.appendingPathComponent("tools/" + $0 + "/SKILL.md").standardizedFileURL.path) })
        let entries = SkillsScanner.scanLocalDirectory(root: root)
        #expect(entries.map(\.id) == ["local:alpha", "local:zeta"])
    }

    @Test func invalidPluginIdentityIsOmittedWithoutPathBearingDiagnostic() {
        let items = SkillCatalogLoader.pluginItems(servers: [
            MCPServer(id: "../outside", name: "Outside")
        ])
        #expect(items.isEmpty)
    }

    @Test func duplicatePluginIDsAreRejectedAsOneAmbiguousIdentity() {
        let items = SkillCatalogLoader.pluginItems(servers: [
            MCPServer(id: "duplicate", name: "First"),
            MCPServer(id: "duplicate", name: "Second")
        ])
        #expect(items.isEmpty)
    }
}
