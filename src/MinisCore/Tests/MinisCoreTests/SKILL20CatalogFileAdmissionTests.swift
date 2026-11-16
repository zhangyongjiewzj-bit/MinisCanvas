import Darwin
import Foundation
import Testing
@testable import MinisCore

@Suite("SKILL-20 catalog file admission")
struct SKILL20CatalogFileAdmissionTests {
    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SKILL20-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeSkill(at root: URL) throws -> URL {
        let directory = root.appendingPathComponent("safe", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "---\nname: Safe\nversion: 1.0.0\n---\nbody\n".write(
            to: directory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        return directory
    }

    @Test func fifoSkillFileIsRejectedBeforeDescriptorOpen() throws {
        let root = try temporaryRoot("fifo-skill")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("safe", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let skillFile = directory.appendingPathComponent("SKILL.md")
        #expect(Darwin.mkfifo(skillFile.path, mode_t(0o600)) == 0)

        #expect(SkillCatalogFileSnapshot.read(
            skillDirectory: directory,
            within: root,
            maxSkillBytes: 1024,
            maxManifestBytes: 1024
        ) == nil)
    }

    @Test func oversizedSkillFileIsRejectedBeforeAllocation() throws {
        let root = try temporaryRoot("oversized-skill")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try makeSkill(at: root)
        try Data(repeating: 0x61, count: 1025)
            .write(to: directory.appendingPathComponent("SKILL.md"))

        #expect(SkillCatalogFileSnapshot.read(
            skillDirectory: directory,
            within: root,
            maxSkillBytes: 1024,
            maxManifestBytes: 1024
        ) == nil)
    }

    @Test func invalidUTF8ManifestIsRejectedAtSnapshotBoundary() throws {
        let root = try temporaryRoot("invalid-manifest")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try makeSkill(at: root)
        try Data([0xC3, 0x28]).write(to: directory.appendingPathComponent("manifest.json"))

        #expect(SkillCatalogFileSnapshot.read(
            skillDirectory: directory,
            within: root,
            maxSkillBytes: 1024,
            maxManifestBytes: 1024
        ) == nil)
    }
}
