import Darwin
import Foundation
import Testing
@testable import MinisCore

@Suite("SKILL-23 local skill import admission")
struct SKILL23SkillImportAdmissionTests {
    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SKILL23-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private let skillContent = "---\nname: Imported\nversion: 1.0.0\n---\nbody\n"

    @Test func fifoSourceIsRejectedBeforeOpen() throws {
        let root = try temporaryRoot("fifo")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("SKILL.md")
        #expect(Darwin.mkfifo(source.path, mode_t(0o600)) == 0)
        let store = SkillStore(skillsRoot: root.appendingPathComponent("store", isDirectory: true))

        #expect(throws: SkillError.self) {
            _ = try store.importSkill(from: source, source: .url("https://example.invalid/skill"))
        }
    }

    @Test func oversizedSourceIsRejectedBeforeAllocation() throws {
        let root = try temporaryRoot("oversized")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("SKILL.md")
        try Data(repeating: 0x61, count: SkillStore.maxSkillContentBytes + 1).write(to: source)
        let store = SkillStore(skillsRoot: root.appendingPathComponent("store", isDirectory: true))

        #expect(throws: SkillError.contentTooLarge) {
            _ = try store.importSkill(from: source)
        }
    }

    @Test func invalidUTF8SourceIsRejected() throws {
        let root = try temporaryRoot("invalid-utf8")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("SKILL.md")
        try Data([0x23, 0x20, 0xFF]).write(to: source)
        let store = SkillStore(skillsRoot: root.appendingPathComponent("store", isDirectory: true))

        #expect(throws: SkillError.importFailed(reason: "skill source is not a stable UTF-8 file")) {
            _ = try store.importSkill(from: source)
        }
    }

    @Test func validUTF8SourceRemainsImportable() throws {
        let root = try temporaryRoot("valid")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("SKILL.md")
        try skillContent.write(to: source, atomically: true, encoding: .utf8)
        let store = SkillStore(skillsRoot: root.appendingPathComponent("store", isDirectory: true))

        let imported = try store.importSkill(from: source, source: .file)
        #expect(imported.map(\.id) == ["imported"])
    }
}
