import Darwin
import Foundation
import Testing
@testable import MinisCore

@Suite("SKILL-24 skill import persistence admission")
struct SKILL24SkillImportPersistenceTests {
    private let originalContent = "---\nname: Durable\nversion: 1.0.0\n---\nold body\n"
    private let updatedContent = "---\nname: Durable\nversion: 1.0.0\n---\nnew body\n"

    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SKILL24-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func skillFile(in root: URL) -> URL {
        root.appendingPathComponent("durable/SKILL.md")
    }

    @Test func symlinkedTargetDirectoryIsRejectedWithoutOutsideWrite() throws {
        let root = try temporaryRoot("directory-symlink")
        let outside = try temporaryRoot("outside")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("durable", isDirectory: true),
            withDestinationURL: outside
        )
        let store = SkillStore(skillsRoot: root)

        #expect(throws: SkillError.self) {
            _ = try store.importSkill(content: originalContent)
        }
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("SKILL.md").path))
    }

    @Test func hardlinkedExistingSkillFileIsRejectedWithoutReplacement() throws {
        let root = try temporaryRoot("hardlink")
        let mirror = root.appendingPathComponent("mirror.md")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillStore(skillsRoot: root)
        _ = try store.importSkill(content: originalContent)
        try FileManager.default.linkItem(at: skillFile(in: root), to: mirror)

        #expect(throws: SkillError.self) {
            _ = try store.importSkill(content: updatedContent)
        }
        #expect(try String(contentsOf: skillFile(in: root), encoding: .utf8) == originalContent)
        #expect(try String(contentsOf: mirror, encoding: .utf8) == originalContent)
    }

    @Test func symlinkedExistingSkillFileIsRejectedWithoutOutsideWrite() throws {
        let root = try temporaryRoot("file-symlink")
        let outside = try temporaryRoot("file-outside")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let store = SkillStore(skillsRoot: root)
        _ = try store.importSkill(content: originalContent)
        let outsideFile = outside.appendingPathComponent("SKILL.md")
        try "outside content".write(to: outsideFile, atomically: true, encoding: .utf8)
        let target = skillFile(in: root)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outsideFile)

        #expect(throws: SkillError.self) {
            _ = try store.importSkill(content: updatedContent)
        }
        #expect(try String(contentsOf: outsideFile, encoding: .utf8) == "outside content")
    }

    @Test func insecureExistingDirectoryIsRejectedWithoutReplacement() throws {
        let root = try temporaryRoot("directory-mode")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillStore(skillsRoot: root)
        _ = try store.importSkill(content: originalContent)
        let directory = root.appendingPathComponent("durable", isDirectory: true)
        #expect(Darwin.chmod(directory.path, mode_t(0o777)) == 0)

        #expect(throws: SkillError.self) {
            _ = try store.importSkill(content: updatedContent)
        }
        #expect(try String(contentsOf: skillFile(in: root), encoding: .utf8) == originalContent)
    }

    @Test func lifecycleFailureRestoresExistingPairAndLeavesNoTemporaryFiles() throws {
        let root = try temporaryRoot("rollback")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillStore(skillsRoot: root)
        _ = try store.importSkill(content: originalContent)
        let receipts = root.appendingPathComponent("lifecycle-receipts.json")
        try FileManager.default.removeItem(at: receipts)
        try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)

        #expect(throws: SkillError.self) {
            _ = try store.importSkillThroughLifecycle(
                content: updatedContent,
                source: .file,
                reason: "forced receipt failure"
            )
        }
        #expect(try String(contentsOf: skillFile(in: root), encoding: .utf8) == originalContent)
        #expect(store.rawContent("durable") == originalContent)
        let entries = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("durable", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        #expect(entries.allSatisfy { !$0.lastPathComponent.hasSuffix(".tmp") })
    }
}
