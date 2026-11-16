import Foundation
import Testing
@testable import MinisCore

@Suite("SKILL-04 本地技能根目录边界")
struct SkillFilesystemBoundaryTests {
    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SKILL04-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func rejectsTraversalSymlinkChainsAndControlNames() throws {
        #expect(!SkillFilesystemBoundary.isSafePathComponent("../escape"))
        #expect(!SkillFilesystemBoundary.isSafePathComponent("skill\u{7F}"))
        #expect(!SkillFilesystemBoundary.isSafePathComponent("skill\u{80}"))
        #expect(!SkillFilesystemBoundary.isSafeDisplayName("remote\u{9F}name"))

        let root = try temporaryRoot("paths")
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("SKILL04-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }

        let escaped = root.appendingPathComponent("escaped", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: escaped, withDestinationURL: outside)
        #expect(SkillFilesystemBoundary.isApprovedRoot(root))
        #expect(!SkillFilesystemBoundary.isTrustedDirectory(escaped, within: root))
        #expect(!SkillFilesystemBoundary.isTrustedDirectory(
            root.appendingPathComponent("../\(outside.lastPathComponent)"),
            within: root
        ))
    }

    @Test func rejectsNonRegularAndOversizedManifestFiles() throws {
        let root = try temporaryRoot("manifest")
        defer { try? FileManager.default.removeItem(at: root) }
        let skillDirectory = root.appendingPathComponent("safe-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try "---\nname: safe-skill\n---\nbody\n".write(
            to: skillDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        let manifest = skillDirectory.appendingPathComponent("manifest.json")
        try Data(repeating: 0x7B, count: SkillFilesystemBoundary.maxManifestBytes + 1)
            .write(to: manifest)
        #expect(!SkillFilesystemBoundary.isTrustedSkillDirectory(skillDirectory, within: root))

        try FileManager.default.removeItem(at: manifest)
        let directoryNamedSkillMD = skillDirectory.appendingPathComponent("SKILL.md")
        try FileManager.default.removeItem(at: directoryNamedSkillMD)
        try FileManager.default.createDirectory(at: directoryNamedSkillMD, withIntermediateDirectories: true)
        #expect(!SkillFilesystemBoundary.isTrustedRegularFile(
            directoryNamedSkillMD,
            within: root,
            maximumBytes: 1_024
        ))
    }

    @Test func sameRootURLReflectsFileToDirectoryTransition() throws {
        let fixture = try temporaryRoot("root-type-transition")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("skills")
        try Data("owned blocker".utf8).write(to: root)
        #expect(try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == false)
        #expect(!SkillFilesystemBoundary.isApprovedRoot(root))
        try FileManager.default.moveItem(at: root,
            to: fixture.appendingPathComponent("preserved-blocker"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        #expect(SkillFilesystemBoundary.isApprovedRoot(root))
        #expect(SkillFilesystemBoundary.approvedRootIdentity(root) != nil)
    }

    @Test func sameEntryURLsReflectCurrentTypeAndSize() throws {
        let root = try temporaryRoot("entry-type-transition")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("entry")
        try Data("owned blocker".utf8).write(to: directory)
        #expect(try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == false)
        #expect(!SkillFilesystemBoundary.isTrustedDirectory(directory, within: root))
        try FileManager.default.moveItem(at: directory,
            to: root.appendingPathComponent("preserved-blocker"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        #expect(SkillFilesystemBoundary.isTrustedDirectory(directory, within: root))
        let file = directory.appendingPathComponent("SKILL.md")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        #expect(try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == false)
        #expect(!SkillFilesystemBoundary.isTrustedRegularFile(file, within: root))
        try FileManager.default.moveItem(at: file,
            to: directory.appendingPathComponent("preserved-directory"))
        try Data(repeating: 0x41, count: 3).write(to: file)
        #expect(SkillFilesystemBoundary.isTrustedRegularFile(file, within: root, maximumBytes: 8))
        let sizedFile = directory.appendingPathComponent("sized.md")
        try Data(repeating: 0x41, count: 3).write(to: sizedFile)
        #expect(try sizedFile.resourceValues(forKeys: [.fileSizeKey]).fileSize == 3)
        try Data(repeating: 0x41, count: 16).write(to: sizedFile, options: .atomic)
        #expect(!SkillFilesystemBoundary.isTrustedRegularFile(sizedFile, within: root, maximumBytes: 8))
    }

    @Test func refreshedMetadataStillRejectsLinksAndReplacedDirectoryIdentity() throws {
        let root = try temporaryRoot("fresh-negative-boundaries")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("entry")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let identity = try #require(SkillFilesystemBoundary.trustedDirectoryIdentity(directory, within: root))
        #expect(try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false)
        let preserved = root.appendingPathComponent("preserved-entry")
        try FileManager.default.moveItem(at: directory, to: preserved)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        #expect(!SkillFilesystemBoundary.isTrustedDirectory(directory, within: root, matching: identity))
        try FileManager.default.moveItem(at: directory,
            to: root.appendingPathComponent("preserved-replacement"))
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: preserved)
        #expect(!SkillFilesystemBoundary.isTrustedDirectory(directory, within: root))
        #expect(!SkillFilesystemBoundary.isApprovedRoot(directory))
    }

}
