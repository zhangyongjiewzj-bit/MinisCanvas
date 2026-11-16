import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Goal18 P17 command settings production consumers")
@MainActor
struct Goal18P17SettingsConsumerTests {
    /// Require the existing formal boundary before constructing any consumer.
    /// Every default dependency therefore stays in the validated test profile.
    private func makeFixture() throws -> (RuntimeIsolationProfile, URL) {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        try #require(profile.mode == .isolatedTest && profile.isDisposableRootIntact)
        let root = profile.temporaryDirectory.appendingPathComponent(
            "goal18-p17-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        return (profile, root)
    }

    @Test("Bridge cold default and hot reapply keep command and other-tool budgets distinct")
    func bridgeColdAndHotSettingsReachProductionExecutor() async throws {
        let (profile, root) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = try #require(profile.userDefaultsSuiteName) + ".p17." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let bridge = BridgeStore(
            preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            sessionDocumentStore: SessionDocumentStore(directory: sessions),
            canvasRuntimeState: .disabled,
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            canvasFeatureLane: .phase3NonCanvas)
        await bridge.attachProductionServices(
            fileAccessAllowedRoot: root, fileAccessDeniedRoots: [],
            sessionDirectory: sessions, externalNetworkAllowed: false).value
        let executor = try #require(bridge.productionBuiltinToolExecutor)
        let coldEngine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let coldReceipt = try #require(bridge.lastAgentSettingsReapplyReceipt)
        #expect(executor.defaultShellTimeout == 120)
        #expect(coldEngine.toolTimeoutSeconds == 300)
        #expect(coldReceipt.shellCommandTimeoutSeconds == 120)
        #expect(coldReceipt.toolTimeoutSeconds == 300)

        bridge.refreshProductionAgentSettings(AgentSettings(
            toolTimeoutSeconds: 90, shellCommandTimeoutSeconds: 45,
            concurrentToolLimit: 1, fallbackEnabled: false))
        let hotEngine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let hotReceipt = try #require(bridge.lastAgentSettingsReapplyReceipt)
        #expect(bridge.productionBuiltinToolExecutor === executor)
        #expect(executor.defaultShellTimeout == 45)
        #expect(hotEngine.toolTimeoutSeconds == 90)
        #expect(hotReceipt.source == .runtimeRefresh)
        #expect(hotReceipt.generation == coldReceipt.generation + 1)
        #expect(hotReceipt.shellCommandTimeoutSeconds == 45)
        #expect(hotReceipt.toolTimeoutSeconds == 90)
    }

    @Test("Settings persistence reaches both visible-terminal approval request forms")
    func settingsCenterReachesVisibleTerminalBudget() throws {
        let (_, root) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("settings", isDirectory: true)
        let store = SettingsStore(directory: directory)
        let settings = SettingsCenter(settingsStore: store)
        let snapshot = TerminalContextSnapshot(sessionID: "p17-session", turnID: "p17-turn",
            taskID: "p17-task", projectID: "p17-project", workdir: root.path)
        let cold = TerminalContextPanelAdapter(snapshot: snapshot, settings: settings)
        #expect(settings.shellCommandTimeoutSeconds == 120)
        #expect(cold.makeRequest(command: "echo p17", cwd: root.path, approved: false).timeout == .seconds(120))
        #expect(TerminalContextPanelAdapter(snapshot: snapshot)
            .makeRequest(command: "echo p17", cwd: root.path, approved: false).timeout == .seconds(120))

        settings.toolTimeoutSeconds = 90
        settings.shellCommandTimeoutSeconds = 45
        #expect(settings.lastPersistenceError == nil)
        let reloaded = SettingsStore(directory: directory)
        #expect(reloaded.settings.agent.toolTimeoutSeconds == 90)
        #expect(reloaded.settings.agent.shellCommandTimeoutSeconds == 45)
        let adapter = TerminalContextPanelAdapter(snapshot: snapshot, settings: settings)
        let pending = adapter.makeRequest(command: "echo p17", cwd: root.path, approved: false)
        let approved = adapter.makeRequest(command: "echo p17", cwd: root.path, approved: true)
        #expect(pending.timeout == .seconds(45))
        #expect(approved.timeout == .seconds(45))
        #expect(pending.approval == nil && approved.approval != nil)
        #expect(pending.context == approved.context)
        #expect(pending.command == approved.command)
        #expect(settings.toolTimeoutSeconds == 90)
    }
    @Test("S05 terminal history retains its newest bounded Unicode output with a visible notice")
    func terminalHistoryIsBoundedAcrossAppends() {
        let store = TerminalStore()
        let prefix = String(repeating: "旧", count: TerminalStore.maximumOutputCharacters - 2)
        store.append(prefix)
        #expect(!store.output.hasPrefix(TerminalStore.truncatedOutputNotice))
        store.append(String(repeating: "新🙂", count: 20))
        #expect(store.output.count <= TerminalStore.maximumOutputCharacters)
        #expect(store.output.hasPrefix(TerminalStore.truncatedOutputNotice))
        #expect(store.output.hasSuffix(String(repeating: "新🙂", count: 20) + "\n"))
        store.append("latest-tail")
        #expect(store.output.count <= TerminalStore.maximumOutputCharacters)
        #expect(store.output.components(separatedBy: TerminalStore.truncatedOutputNotice).count == 2)
        #expect(store.output.hasSuffix("latest-tail\n"))
    }

    @Test("S14 an unbound terminal explains its missing directory without entering approval or execution")
    func terminalWithoutWorkingDirectoryDoesNotExecute() {
        let store = TerminalStore()
        #expect(!store.hasWorkingDirectory)
        store.input = "pwd"
        store.submit()
        #expect(store.output.contains(TerminalStore.missingWorkingDirectoryMessage))
        #expect(store.output.contains("未绑定项目 $ pwd"))
        #expect(!store.isRunning && store.pendingConfirmation == nil)
        #expect(store.lastPwdReceipt == nil && store.pwdReceiptJSON == nil)
        store.input = "rm synthetic-file"
        store.submit()
        #expect(store.pendingConfirmation == nil && !store.isRunning)
    }

}
