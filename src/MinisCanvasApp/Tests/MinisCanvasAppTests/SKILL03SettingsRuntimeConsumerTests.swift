import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("SKILL-03 settings to request consumer")
@MainActor
struct SKILL03SettingsRuntimeConsumerTests {
    @Test("a settings toggle updates the next runtime snapshot and preserves an inflight snapshot")
    func settingsToggleRefreshesNextRequestWithoutMutatingInflight() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill03-runtime-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let appStore = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let imported = try appStore.importSkillThroughLifecycle(
            content: """
            ---
            name: skill03-runtime
            description: skill03 runtime toggle
            version: 1
            ---
            immutable request body
            """,
            source: .file,
            reason: "SKILL-03 focused runtime consumer",
            approval: SkillApproval(approverID: "skill03-test")
        )
        let settings = SkillsStore(
            appStore: appStore,
            stateFileURL: root.appendingPathComponent("skills-enabled.json")
        )
        let bridge = BridgeStore()
        bridge.attachProductionServices(
            sessionDirectory: root.appendingPathComponent("sessions"),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json")),
            skillStore: appStore,
            externalNetworkAllowed: false
        )
        let factory = try #require(bridge.chat.turnRuntimeSnapshotFactory)
        let firstCapture = factory(
            AgentTurnIdentity(sessionID: "skill03-session", turnID: 1, messageID: "skill03-first"),
            MockProvider.shared
        )

        let first = try #require(await firstCapture.preparedForExecution())
        let firstInjector = try #require(first.skillInjector)

        let disabledResult = settings.setEnabled("app:\(imported.skill.id)", enabled: false)
        guard case .success = disabledResult else {
            Issue.record("SKILL-03 disable did not commit")
            return
        }
        let disabledCapture = factory(
            AgentTurnIdentity(sessionID: "skill03-session", turnID: 2, messageID: "skill03-second"),
            MockProvider.shared
        )
        let disabledNext = try #require(await disabledCapture.preparedForExecution())
        let disabledInjector = try #require(disabledNext.skillInjector)
        #expect(firstInjector.buildInjection(for: "skill03-runtime")
            .fragment?.contains("immutable request body") == true)
        #expect(disabledInjector.buildInjection(for: "skill03-runtime").fragment == nil)

        let enabledResult = settings.setEnabled("app:\(imported.skill.id)", enabled: true)
        guard case .success = enabledResult else {
            Issue.record("SKILL-03 enable did not commit")
            return
        }
        let enabledCapture = factory(
            AgentTurnIdentity(sessionID: "skill03-session", turnID: 3, messageID: "skill03-third"),
            MockProvider.shared
        )
        let enabledNext = try #require(await enabledCapture.preparedForExecution())
        let enabledInjector = try #require(enabledNext.skillInjector)
        #expect(enabledInjector.buildInjection(for: "skill03-runtime")
            .fragment?.contains("immutable request body") == true)
    }
}
