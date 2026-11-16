import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Global composer command readiness consumer")
@MainActor
struct P3AcceptanceM08_CommandReadinessConsumerTests {
    @Test("actual adjudication executor blockers reach the slash menu")
    func executorBlockersReachSlashRows() {
        let registry = CommandRegistry()
        registry.registerComposerCommands()
        let bridge = makeBridge()
        let reasons = GlobalComposer.commandReadinessReasons(
            registry: registry, bridge: bridge
        )

        #expect(reasons["canvas.run"] == ComposerCommandAdjudicationCenter
            .missingExecutorReason(for: "canvas.run"))
        #expect(reasons["help"] == nil)
        #expect(reasons["settings.open"] == nil)

        let state = ComposerSlashSessionState(
            unavailableReasonsByCommandID: reasons
        )
        let rows = ComposerSlashCommandMenu.entries(
            matching: "/canvas.run", registry: registry, sessionState: state
        )
        #expect(rows.map(\.id) == ["canvas.run"])
        #expect(rows.first?.state.reason == reasons["canvas.run"])
        #expect(rows.first?.shouldSendOnAccept == false)
    }

    @Test("observed compact blocker reaches the same menu map without disabling display routes")
    func observedCompactBlockerReachesSlashRows() {
        let registry = CommandRegistry()
        registry.registerComposerCommands()
        let bridge = makeBridge()
        bridge.chat.messages = (0..<4).map {
            ChatMessageUI(role: .user, content: "message \($0)")
        }
        bridge.chat.effectiveSettingsSnapshotSource = { nil }

        let reasons = GlobalComposer.commandReadinessReasons(
            registry: registry, bridge: bridge
        )
        #expect(reasons["compact"] == "设置事务状态未知，当前不能压缩上下文")
        #expect(reasons["help"] == nil)
        #expect(reasons["settings.open"] == nil)

        let state = ComposerSlashSessionState(
            unavailableReasonsByCommandID: reasons
        )
        let rows = ComposerSlashCommandMenu.entries(
            matching: "/compact", registry: registry, sessionState: state
        )
        #expect(rows.map(\.id) == ["compact"])
        #expect(rows.first?.state.reason == reasons["compact"])
        #expect(rows.first?.shouldSendOnAccept == false)
    }

    @Test("short history is not blanket-blocked by absent settings or provider facts")
    func shortHistoryKeepsCompactUnblocked() {
        let registry = CommandRegistry()
        registry.registerComposerCommands()
        let bridge = makeBridge()
        bridge.chat.messages = [ChatMessageUI(role: .user, content: "one")]
        var settingsReads = 0
        bridge.chat.effectiveSettingsSnapshotSource = {
            settingsReads += 1
            return nil
        }

        let reasons = GlobalComposer.commandReadinessReasons(
            registry: registry, bridge: bridge
        )
        #expect(reasons["compact"] == nil)
        #expect(reasons["help"] == nil)
        #expect(reasons["settings.open"] == nil)
        #expect(settingsReads == 0)
    }

    private func makeBridge() -> BridgeStore {
        let identity = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("m08-command-readiness-\(identity)", isDirectory: true)
        let defaults = UserDefaults(suiteName: "m08.command-readiness.\(identity)")!
        return BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults),
            preferencesDefaults: defaults,
            logManager: LogManager(directory: directory.appendingPathComponent("logs"), ringCapacity: 20),
            sessionDocumentStore: SessionDocumentStore(directory: directory),
            memoryStore: MemoryStore(directory: directory),
            canvasFeatureLane: .phase3NonCanvas
        )
    }
}
