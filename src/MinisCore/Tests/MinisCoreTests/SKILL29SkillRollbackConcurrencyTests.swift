import Darwin
import Foundation
import Testing
@testable import MinisCore

@Suite("SKILL-29 skill rollback concurrency fences")
struct SKILL29SkillRollbackConcurrencyTests {
    private let firstContent = "---\nname: Rollback\nversion: 1.0.0\n---\nfirst body\n"
    private let secondContent = "---\nname: Rollback\nversion: 2.0.0\n---\nsecond body\n"

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SKILL29-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func holdImportLock(at directory: URL) throws -> Int32 {
        let lockURL = directory.appendingPathComponent(".skill-import.lock")
        let descriptor = Darwin.open(
            lockURL.path,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw SkillError.importFailed(reason: "test lock could not be opened")
        }
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            _ = Darwin.close(descriptor)
            throw SkillError.importFailed(reason: "test lock could not be held")
        }
        return descriptor
    }

    private func releaseImportLock(_ descriptor: Int32) {
        _ = flock(descriptor, LOCK_UN)
        _ = Darwin.close(descriptor)
    }

    @Test func inFlightRollbackIsRejectedWithoutChangingTheCommittedPair() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SkillStore(skillsRoot: root)
        _ = try store.importSkill(content: firstContent)
        _ = try store.importSkill(content: secondContent)

        let directory = root.appendingPathComponent("rollback", isDirectory: true)
        let skillFile = directory.appendingPathComponent("SKILL.md")
        let manifestFile = directory.appendingPathComponent("manifest.json")
        let receiptsFile = root.appendingPathComponent("lifecycle-receipts.json")
        let beforeSkill = try Data(contentsOf: skillFile)
        let beforeManifest = try Data(contentsOf: manifestFile)
        let beforeReceipts = try Data(contentsOf: receiptsFile)
        let lock = try holdImportLock(at: directory)
        defer { releaseImportLock(lock) }

        #expect(throws: SkillError.self) {
            _ = try store.rollbackSkill("rollback", reason: "concurrent rollback probe")
        }
        #expect(try Data(contentsOf: skillFile) == beforeSkill)
        #expect(try Data(contentsOf: manifestFile) == beforeManifest)
        #expect(try Data(contentsOf: receiptsFile) == beforeReceipts)
        #expect(store.skills.first(where: { $0.id == "rollback" })?.body == "second body")
    }
}
