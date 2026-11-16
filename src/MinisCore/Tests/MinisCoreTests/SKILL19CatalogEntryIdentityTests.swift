import Foundation
import Testing
@testable import MinisCore

@Suite("SKILL-19 catalog entry identity fence")
struct SKILL19CatalogEntryIdentityTests {
    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SKILL19-\(label)-\(UUID().uuidString)", isDirectory: true)
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

    @Test func renamedSkillDirectoryCannotReuseTheOldEntryIdentity() throws {
        let root = try temporaryRoot("directory")
        defer { try? FileManager.default.removeItem(at: root) }
        let skillDirectory = root.appendingPathComponent("stable", isDirectory: true)
        try writeSkill("---\nname: Stable\nversion: 1.0.0\n---\nold\n", at: skillDirectory)
        let rootIdentity = try #require(SkillFilesystemBoundary.approvedRootIdentity(root))
        let directoryIdentity = try #require(
            SkillFilesystemBoundary.trustedDirectoryIdentity(skillDirectory, within: root)
        )
        let fileIdentity = try #require(
            SkillFilesystemBoundary.trustedRegularFileIdentity(
                skillDirectory.appendingPathComponent("SKILL.md"),
                within: root
            )
        )

        let displaced = root.appendingPathComponent("stable-displaced", isDirectory: true)
        try FileManager.default.moveItem(at: skillDirectory, to: displaced)
        defer { try? FileManager.default.removeItem(at: displaced) }
        try writeSkill("---\nname: Replacement\nversion: 1.0.0\n---\nnew\n", at: skillDirectory)

        #expect(SkillCatalogFileSnapshot.read(
            skillDirectory: skillDirectory,
            within: root,
            expectedRootIdentity: rootIdentity,
            expectedSkillDirectoryIdentity: directoryIdentity,
            expectedSkillFileIdentity: fileIdentity
        ) == nil)
    }

    @Test func replacedSkillFileCannotReuseTheOldFileIdentity() throws {
        let root = try temporaryRoot("file")
        defer { try? FileManager.default.removeItem(at: root) }
        let skillDirectory = root.appendingPathComponent("stable", isDirectory: true)
        let skillFile = skillDirectory.appendingPathComponent("SKILL.md")
        try writeSkill("---\nname: Stable\nversion: 1.0.0\n---\nold\n", at: skillDirectory)
        let rootIdentity = try #require(SkillFilesystemBoundary.approvedRootIdentity(root))
        let directoryIdentity = try #require(
            SkillFilesystemBoundary.trustedDirectoryIdentity(skillDirectory, within: root)
        )
        let fileIdentity = try #require(
            SkillFilesystemBoundary.trustedRegularFileIdentity(skillFile, within: root)
        )

        try "---\nname: Replacement\nversion: 1.0.0\n---\nnew\n".write(
            to: skillFile,
            atomically: true,
            encoding: .utf8
        )

        #expect(SkillCatalogFileSnapshot.read(
            skillDirectory: skillDirectory,
            within: root,
            expectedRootIdentity: rootIdentity,
            expectedSkillDirectoryIdentity: directoryIdentity,
            expectedSkillFileIdentity: fileIdentity
        ) == nil)
    }
}
