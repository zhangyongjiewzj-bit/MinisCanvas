import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("SKILL-04 技能目录生产扫描接线")
struct SKILL04SkillRootBoundaryTests {
    private let sample = """
    ---
    name: safe-skill
    description: safe local skill
    version: 1.0.0
    ---
    body
    """

    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SKILL04-App-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeSkill(_ content: String, at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try content.write(
            to: directory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    @Test func bothProductionScannersRejectUntrustedEntries() throws {
        let root = try temporaryRoot("scan")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSkill(sample, at: root.appendingPathComponent("safe-skill", isDirectory: true))

        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("SKILL04-App-outside-\(UUID().uuidString)", isDirectory: true)
        try writeSkill(sample, at: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked-skill", isDirectory: true),
            withDestinationURL: outside
        )

        let oversized = root.appendingPathComponent("oversized", isDirectory: true)
        try writeSkill(sample, at: oversized)
        try Data(repeating: 0x7B, count: SkillFilesystemBoundary.maxManifestBytes + 1)
            .write(to: oversized.appendingPathComponent("manifest.json"))

        let controlName = root.appendingPathComponent("control\u{7F}", isDirectory: true)
        try writeSkill(sample, at: controlName)
        let controlFrontmatter = root.appendingPathComponent("control-frontmatter", isDirectory: true)
        try writeSkill("---\nname: bad\u{80}name\ndescription: hidden\n---\nbody\n", at: controlFrontmatter)

        let loaderItems = SkillsScanner.mergedEntriesWithDiagnostics(appSnapshot: SkillStore(skillsRoot: root.appendingPathComponent(".canonical-app")).snapshot(), enabledStates: [:], localRoots: [root]).entries
        let scannerEntries = SkillsScanner.scanLocalDirectory(root: root)
        #expect(loaderItems.map(\.name) == ["safe-skill"])
        #expect(scannerEntries.map(\.name) == ["safe-skill"])
        #expect(loaderItems.allSatisfy { !$0.name.contains("control") })
        #expect(scannerEntries.allSatisfy { !$0.name.contains("control") })
    }

    @Test func aSymlinkedRootIsRejectedWithoutPathBearingOutput() throws {
        let realRoot = try temporaryRoot("real")
        defer { try? FileManager.default.removeItem(at: realRoot) }
        let linkRoot = realRoot.deletingLastPathComponent()
            .appendingPathComponent("SKILL04-App-link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkRoot, withDestinationURL: realRoot)
        defer { try? FileManager.default.removeItem(at: linkRoot) }

        #expect(SkillsScanner.mergedEntriesWithDiagnostics(appSnapshot: SkillStore(skillsRoot: linkRoot.appendingPathComponent(".canonical-app")).snapshot(), enabledStates: [:], localRoots: [linkRoot]).entries.isEmpty)
        #expect(SkillsScanner.scanLocalDirectory(root: linkRoot).isEmpty)
    }
}
