import Foundation
import Testing
@testable import MinisCore

struct SkillStoreDeletionSafetyTests {
    private let now = Date(timeIntervalSince1970: 4_000)

    private func makeStore() throws -> (SkillStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillStoreDeletionSafety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (SkillStore(skillsRoot: root), root)
    }

    private func content(name: String, body: String = "Body") -> String {
        """
        ---
        name: \(name)
        description: Deletion safety test skill.
        version: 1.0.0
        ---

        \(body)
        """
    }

    private func confirmed(_ intent: OperationIntent) -> OperationIntent {
        intent.withFirstConfirmation("I reviewed this exact skill")
            .withSecondConfirmation("永久删除")
    }

    @Test func legacyRemoveSkillFailsClosedAndConfirmedRemovalIsOneShot() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try store.importSkill(content: content(name: "one"))
        store.removeSkill("one")
        #expect(store.allSkills().map(\.id) == ["one"])
        let intent = try store.previewDeletion(skillID: "one", now: now, ttl: 60)
        let receipt = try store.removeSkill("one", intent: confirmed(intent), now: now)
        #expect(receipt.targetID == "one")
        #expect(store.allSkills().isEmpty)
        #expect(throws: DeletionGateError.alreadyConsumed) {
            try store.removeSkill("one", intent: confirmed(intent), now: now)
        }
    }

    @Test func removeAllUsesOneConfirmedIntentAndRejectsChangedSet() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try store.importSkill(content: content(name: "one"))
        _ = try store.importSkill(content: content(name: "two"))
        let intent = try store.previewRemoveAll(now: now, ttl: 60)
        _ = try store.importSkill(content: content(name: "one", body: "Changed"))
        #expect(throws: DeletionGateError.targetChanged) {
            try store.removeAll(intent: confirmed(intent), now: now)
        }
        #expect(store.allSkills().count == 2)
    }
}
