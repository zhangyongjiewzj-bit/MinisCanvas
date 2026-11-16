import Foundation
import Testing
@testable import MinisCore

@Suite("SKILL-18 catalog root identity fence")
struct SKILL18CatalogRootIdentityTests {
    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SKILL18-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeSkill(at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "---\nname: stable\nversion: 1.0.0\n---\nbody\n".write(
            to: directory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    @Test func ordinaryRootReplacementDoesNotReuseCapturedScope() throws {
        let parent = try temporaryRoot("parent")
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("skills", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let identity = try #require(SkillFilesystemBoundary.approvedRootIdentity(root))

        let displaced = parent.appendingPathComponent("displaced", isDirectory: true)
        try FileManager.default.moveItem(at: root, to: displaced)
        defer { try? FileManager.default.removeItem(at: displaced) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        #expect(!SkillFilesystemBoundary.isApprovedRoot(root, matching: identity))
    }

    @Test func descriptorSnapshotRejectsReplacementAgainstOriginalScope() throws {
        let parent = try temporaryRoot("snapshot")
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("skills", isDirectory: true)
        let originalSkill = root.appendingPathComponent("original", isDirectory: true)
        try writeSkill(at: originalSkill)
        let identity = try #require(SkillFilesystemBoundary.approvedRootIdentity(root))

        let displaced = parent.appendingPathComponent("displaced", isDirectory: true)
        try FileManager.default.moveItem(at: root, to: displaced)
        defer { try? FileManager.default.removeItem(at: displaced) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let replacementSkill = root.appendingPathComponent("replacement", isDirectory: true)
        try writeSkill(at: replacementSkill)

        #expect(SkillCatalogFileSnapshot.read(
            skillDirectory: replacementSkill,
            within: root,
            expectedRootIdentity: identity
        ) == nil)
    }
}
