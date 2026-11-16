import Foundation
import Testing
@testable import MinisCore

@Suite("SKILL lifecycle enablement commit result")
struct SkillEnablementCommit2262Tests {
    @Test("lifecycle receipt write failure returns rejection and preserves prior state")
    func blockedReceiptWriteDoesNotClaimCommit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-core-enable-2262-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let imported = try store.importSkillThroughLifecycle(
            content: """
            ---
            name: enabled-check
            description: synthetic lifecycle check
            version: 1.0.0
            ---
            Original synthetic body.
            """,
            source: .bundled,
            reason: "synthetic approval",
            approval: SkillApproval(approverID: "synthetic-reviewer")
        )
        let id = imported.skill.id
        let receiptFile = store.lifecycleReceiptsFileURL
        let preserved = root.appendingPathComponent("preserved-lifecycle.json")
        let original = try Data(contentsOf: receiptFile)
        try FileManager.default.moveItem(at: receiptFile, to: preserved)
        try FileManager.default.createDirectory(at: receiptFile, withIntermediateDirectories: false)
        var blocked = true
        defer {
            if blocked {
                try? FileManager.default.removeItem(at: receiptFile)
                try? FileManager.default.moveItem(at: preserved, to: receiptFile)
            }
        }

        #expect(store.setEnabled(id, enabled: false) == false)
        #expect(store.allSkills().first { $0.id == id }?.isEnabled == true)
        try FileManager.default.removeItem(at: receiptFile)
        try FileManager.default.moveItem(at: preserved, to: receiptFile)
        blocked = false
        let restored = try Data(contentsOf: receiptFile)
        #expect(restored == original)
        let reopened = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        #expect(reopened.allSkills().first { $0.id == id }?.isEnabled == true)
    }
}
