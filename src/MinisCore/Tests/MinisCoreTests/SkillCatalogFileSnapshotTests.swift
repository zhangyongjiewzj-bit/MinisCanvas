import Darwin
import Foundation
import Testing
@testable import MinisCore

@Suite("SKILL-06 descriptor-anchored catalog reads")
struct SkillCatalogFileSnapshotTests {
    private func temporaryDirectory() throws -> URL {
        let base = try FormalTestIsolationPaths.resolveCurrentProcess()?.rootDirectory
            ?? FileManager.default.temporaryDirectory
        let directory = base
            .appendingPathComponent("SK6-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func readsBoundedUTF8ContentAndOptionalManifestAsOneSnapshot() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let skillDirectory = root.appendingPathComponent("demo", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        let content = "---\nname: Demo\nversion: 1.0.0\n---\n正文"
        try content.write(
            to: skillDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        let manifest = SkillSourceManifest(
            skillID: "demo",
            source: .file,
            skillVersion: "1.0.0",
            content: content
        )
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: skillDirectory.appendingPathComponent("manifest.json"), options: .atomic)

        let snapshot = try #require(SkillCatalogFileSnapshot.read(
            skillDirectory: skillDirectory,
            within: root,
            maxSkillBytes: 1024,
            maxManifestBytes: 1024
        ))
        #expect(snapshot.content == content)
        #expect(snapshot.manifestData == manifestData)
        #expect(snapshot.contentByteCount == content.utf8.count)
        #expect(snapshot.manifestByteCount == manifestData.count)
    }

    @Test func missingManifestUsesSidecarFreeSnapshot() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let skillDirectory = root.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try Data("# legacy".utf8).write(to: skillDirectory.appendingPathComponent("SKILL.md"))

        let snapshot = try #require(SkillCatalogFileSnapshot.read(
            skillDirectory: skillDirectory,
            within: root,
            maxSkillBytes: 1024,
            maxManifestBytes: 1024
        ))
        #expect(snapshot.manifestData == nil)
        #expect(snapshot.manifestByteCount == 0)
    }

    @Test func invalidEncodingAndOversizedFilesFailClosed() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let skillDirectory = root.appendingPathComponent("invalid", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try Data([0xC3, 0x28]).write(to: skillDirectory.appendingPathComponent("SKILL.md"))
        #expect(SkillCatalogFileSnapshot.read(
            skillDirectory: skillDirectory,
            within: root,
            maxSkillBytes: 1024,
            maxManifestBytes: 1024
        ) == nil)

        let valid = Data("valid".utf8)
        try valid.write(to: skillDirectory.appendingPathComponent("SKILL.md"), options: .atomic)
        try Data(repeating: 0x7B, count: 32).write(
            to: skillDirectory.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        #expect(SkillCatalogFileSnapshot.read(
            skillDirectory: skillDirectory,
            within: root,
            maxSkillBytes: 1024,
            maxManifestBytes: 16
        ) == nil)
    }

    @Test func symlinkedSkillFileIsRejectedBeforeDescriptorRead() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        let outsideFile = outside.appendingPathComponent("SKILL.md")
        try Data("outside".utf8).write(to: outsideFile)
        let skillDirectory = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: skillDirectory.appendingPathComponent("SKILL.md"),
            withDestinationURL: outsideFile
        )

        #expect(SkillCatalogFileSnapshot.read(
            skillDirectory: skillDirectory,
            within: root,
            maxSkillBytes: 1024,
            maxManifestBytes: 1024
        ) == nil)
    }
}
