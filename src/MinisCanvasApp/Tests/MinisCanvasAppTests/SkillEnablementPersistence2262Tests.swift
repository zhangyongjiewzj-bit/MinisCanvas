import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

@Suite("SKILL enablement persistence and live projection")
@MainActor
struct SkillEnablementPersistence2262Tests {
    @Test("failed settings save plus invalidated lifecycle cannot leave a stale enabled projection")
    func rejectedCompensationProjectsDurableDisablement() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-enable-2262-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let appRoot = root.appendingPathComponent("skills", isDirectory: true)
        let appStore = SkillStore(skillsRoot: appRoot)
        let content = """
        ---
        name: enabled-check
        description: synthetic lifecycle check
        version: 1.0.0
        ---
        Original synthetic body.
        """
        let imported = try appStore.importSkillThroughLifecycle(
            content: content,
            source: .bundled,
            reason: "synthetic approval",
            approval: SkillApproval(approverID: "synthetic-reviewer")
        )
        let skillID = imported.skill.id
        let settingsID = "app:\(skillID)"
        let skillFile = appStore.skillDirectoryURL(for: skillID)
            .appendingPathComponent("SKILL.md")
        let stateFile = root.appendingPathComponent("skills-enabled.json")
        var sourceChanged = false
        var notifications = 0
        let store = SkillsStore(
            appStore: appStore,
            stateFileURL: stateFile,
            enablementStateSaver: { _, _ in
                let changed = content + "\nSynthetic source drift.\n"
                do {
                    try changed.write(to: skillFile, atomically: true, encoding: .utf8)
                    sourceChanged = true
                } catch {
                    sourceChanged = false
                }
                return .failure(.writeFailed)
            }
        )
        store.onEnablementChanged = { notifications += 1 }
        #expect(store.isEnabled(settingsID))

        let result = store.setEnabled(settingsID, enabled: false)
        #expect(sourceChanged)
        switch result {
        case .success:
            Issue.record("failed compensation must not report success")
        case .failure(let error):
            #expect(error == .runtimeRollbackFailed(.rejected))
        }
        #expect(store.lastErrorMessage == "技能状态未能安全回滚，请重启应用后重试。")
        #expect(appStore.allSkills().first { $0.id == skillID }?.isEnabled == false)
        #expect(store.isEnabled(settingsID) == false)
        #expect(store.entries.first { $0.id == settingsID } == nil)
        #expect(notifications == 1)
        #expect(!FileManager.default.fileExists(atPath: stateFile.path))

        let reopenedCore = SkillStore(skillsRoot: appRoot)
        let reopened = SkillsStore(
            appStore: reopenedCore,
            stateFileURL: stateFile
        )
        #expect(reopened.isEnabled(settingsID) == false)
        #expect(reopenedCore.allSkills().first { $0.id == skillID }?.isEnabled == false)
    }
}
