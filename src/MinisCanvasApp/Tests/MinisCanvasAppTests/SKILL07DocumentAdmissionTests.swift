import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private func sk07TempDir(_ label: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SK7-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func writeSK07Skill(at directory: URL, content: String) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try content.write(
        to: directory.appendingPathComponent("SKILL.md"),
        atomically: true,
        encoding: .utf8
    )
}

@Suite("SKILL-07 discovery error isolation")
struct SKILL07DocumentAdmissionTests {
    @Test func hermesMalformedSkillDoesNotBlockValidSiblingsAcrossBothCallers() throws {
        let root = try sk07TempDir("hermes")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSK07Skill(
            at: root.appendingPathComponent("bad"),
            content: "---\nname: Bad\nNAME: Duplicate\nversion: 1.0.0\n---\nbody"
        )
        try writeSK07Skill(
            at: root.appendingPathComponent("good"),
            content: "---\nname: Good\nversion: 1.0.0\n---\nbody"
        )

        #expect(SkillsScanner.mergedEntriesWithDiagnostics(appSnapshot: SkillStore(skillsRoot: root.appendingPathComponent(".canonical-app")).snapshot(), enabledStates: [:], localRoots: [root]).entries.map(\.name) == ["Good"])
        #expect(SkillsScanner.scanLocalDirectory(root: root).map(\.name) == ["Good"])
    }

    @Test func oversizedFrontmatterFieldDoesNotBlockValidHermesSibling() throws {
        let root = try sk07TempDir("field-limit")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSK07Skill(
            at: root.appendingPathComponent("bad"),
            content: "---\nname: Bad\ndescription: \(String(repeating: "x", count: SkillCatalogDocumentPolicy.maxFieldBytes + 1))\nversion: 1.0.0\n---\nbody"
        )
        try writeSK07Skill(
            at: root.appendingPathComponent("good"),
            content: "---\nname: Good\nversion: 1.0.0\n---\nbody"
        )

        #expect(SkillsScanner.mergedEntriesWithDiagnostics(appSnapshot: SkillStore(skillsRoot: root.appendingPathComponent(".canonical-app")).snapshot(), enabledStates: [:], localRoots: [root]).entries.count == 1)
        #expect(SkillsScanner.scanLocalDirectory(root: root).count == 1)
    }

    @Test func appMalformedSkillIsIsolatedFromValidStoreEntry() throws {
        let root = try sk07TempDir("app")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillStore(skillsRoot: root)
        _ = try store.importSkill(
            content: "---\nname: Good App\nversion: 1.0.0\n---\nbody",
            source: .file
        )
        let bad = try store.importSkill(
            content: "---\nname: Bad App\nversion: 1.0.0\n---\nbody",
            source: .file
        )
        try "---\nname: Bad App\nNAME: Duplicate\nversion: 1.0.0\n---\nbody".write(
            to: store.skillDirectoryURL(for: bad.id).appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        #expect(SkillCatalogLoader.storeSkillItems(from: store).map(\.name) == ["Good App"])
        #expect(SkillsScanner.scanApp(store: store).map(\.name) == ["Good App"])
    }
}
