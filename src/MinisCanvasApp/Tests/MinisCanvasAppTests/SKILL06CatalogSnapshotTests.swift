import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private func sk06TempDir(_ label: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SK6-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func writeSK06Skill(at directory: URL, name: String = "Snapshot Skill") throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try "---\nname: \(name)\nversion: 1.0.0\n---\nbody".write(
        to: directory.appendingPathComponent("SKILL.md"),
        atomically: true,
        encoding: .utf8
    )
}

@Suite("SKILL-06 discovery snapshot callers")
struct SKILL06CatalogSnapshotTests {
    @Test func hermesCallersRejectInvalidUTF8FromTheBoundedSnapshot() throws {
        let root = try sk06TempDir("hermes-invalid-utf8")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("tools/invalid")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([0xC3, 0x28]).write(to: directory.appendingPathComponent("SKILL.md"))

        #expect(SkillsScanner.mergedEntriesWithDiagnostics(appSnapshot: SkillStore(skillsRoot: root.appendingPathComponent(".canonical-app")).snapshot(), enabledStates: [:], localRoots: [root]).entries.isEmpty)
        #expect(SkillsScanner.scanLocalDirectory(root: root).isEmpty)
    }

    @Test func appCallersRejectChangedEncodingAfterStoreMetadataWasLoaded() throws {
        let root = try sk06TempDir("app-invalid-utf8")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillStore(skillsRoot: root)
        let skill = try store.importSkill(
            content: "---\nname: Snapshot App\nversion: 1.0.0\n---\nbody",
            source: .file
        )
        try Data([0xC3, 0x28]).write(
            to: store.skillDirectoryURL(for: skill.id).appendingPathComponent("SKILL.md"),
            options: .atomic
        )

        #expect(SkillCatalogLoader.storeSkillItems(from: store).isEmpty)
        #expect(SkillsScanner.scanApp(store: store).isEmpty)
    }

    @Test func validSnapshotKeepsBothProductionCallersOnSameBytes() throws {
        let root = try sk06TempDir("valid")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSK06Skill(at: root.appendingPathComponent("tools/snapshot"))

        let picker = SkillsScanner.mergedEntriesWithDiagnostics(appSnapshot: SkillStore(skillsRoot: root.appendingPathComponent(".canonical-app")).snapshot(), enabledStates: [:], localRoots: [root]).entries
        let settings = SkillsScanner.scanLocalDirectory(root: root)
        #expect(picker.count == 1)
        #expect(settings.count == 1)
        #expect(picker[0].version == settings[0].version)
        #expect(picker[0].name == settings[0].name)
    }
}
