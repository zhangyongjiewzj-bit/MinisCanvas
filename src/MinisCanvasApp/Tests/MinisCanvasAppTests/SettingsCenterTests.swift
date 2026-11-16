import XCTest
import Foundation
import MinisCore
@testable import MinisCanvasApp

/// Synthetic fixture transport: file-access tests must never issue readiness I/O.
private struct M03FileAccessNoNetworkTransport: SettingsProviderReadinessTransport {
    func send(
        _ request: ProviderReadinessTransportRequest
    ) async throws -> ProviderReadinessTransportResponse {
        throw URLError(.notConnectedToInternet)
    }
}

// MARK: - D5 设置中心数据接线测试
//
// 全部用临时目录注入，不触碰 Application Support 真实数据。

@MainActor
final class SettingsCenterTests: XCTestCase {

    private func confirmed(_ intent: OperationIntent) -> OperationIntent {
        intent
            .withFirstConfirmation("我已核对这份精确预览")
            .withSecondConfirmation("永久删除")
    }

    private func assertTrashEntry(
        in directory: URL, receipt: DeletionReceipt, title: String, payload: Data,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let url = directory.appendingPathComponent(".trash-receipt-\(receipt.operationID.uuidString).json")
        let entry = try JSONDecoder().decode(SessionDeletionService.TrashEntry.self, from: Data(contentsOf: url))
        XCTAssertEqual(entry.receipt, receipt, file: file, line: line)
        XCTAssertEqual(entry.title, title, file: file, line: line)
        XCTAssertEqual(entry.payloadDigest, DeletionGate.fingerprint(payload), file: file, line: line)
    }

    private func makeCenter() -> (SettingsCenter, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("D5Tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: dir),
            envStore: EnvVarStore(directory: dir),
            memoryStore: MemoryStore(directory: dir),
            sessionStore: SessionStore(directory: dir),
            logManager: LogManager(directory: dir, ringCapacity: 50)
        )
        return (center, dir)
    }

    private func makeWriteFailingCenter() -> (SettingsCenter, URL) {
        let (center, dir) = makeCenter()
        let settingsURL = dir.appendingPathComponent(SettingsStore.fileName)
        try? FileManager.default.removeItem(at: settingsURL)
        try? FileManager.default.createDirectory(at: settingsURL, withIntermediateDirectories: true)
        return (center, dir)
    }

    // MARK: - 常规（D1 AppSettings 绑定 + 持久化）

    func testSettingsDirectoryProjectsInjectedStoreDirectory() {
        let (center, dir) = makeCenter()

        XCTAssertEqual(center.settingsDirectory.standardizedFileURL, dir.standardizedFileURL)
        XCTAssertEqual(
            center.settingsStore.fileURL.standardizedFileURL,
            dir.appendingPathComponent(SettingsStore.fileName).standardizedFileURL
        )
    }

    func testProviderCredentialProjectsInjectedEnvStore() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("D5ProviderCredential-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: dir),
            envStore: EnvVarStore(directory: dir, keychain: keychain),
            memoryStore: MemoryStore(directory: dir),
            sessionStore: SessionStore(directory: dir),
            logManager: LogManager(directory: dir, ringCapacity: 50)
        )

        XCTAssertTrue(center.setEnvVar(name: "D5_PROFILE_API_KEY", value: "profile-secret", isSecret: true))
        XCTAssertEqual(center.providerCredential(named: "d5_profile_api_key"), "profile-secret")
    }

    private func makeTheme2535Center() throws -> (SettingsCenter, URL) {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "theme2535-reopen", canvasRuntimeState: .disabled)
        let root = profile.rootDirectory
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let suite = "theme2535-reopen-" + root.lastPathComponent
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: root),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain,
                privacyStore: EnvVarPrivacyStore(defaults: defaults)),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            memoryFileStore: MemoryFileStore(directory: root.appendingPathComponent("memory-files")),
            sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            logManager: LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 10),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcp.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite(suite)),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock,
            providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("readiness")))
        return (center, root)
    }

    func testAppearanceUpdatePersistsAcrossReload() throws {
        let (center, dir) = try makeTheme2535Center()
        center.appearance = .dark
        center.defaultProviderID = "openai"
        center.defaultModelID = "gpt-4o-mini"
        center.language = "en"

        XCTAssertEqual(center.settingsStore.settings.general.appearance, .system)
        XCTAssertEqual(center.settingsStore.settings.general.defaultProviderID, "openai")
        XCTAssertEqual(center.settingsStore.settings.general.defaultModelID, "gpt-4o-mini")
        XCTAssertEqual(center.settingsStore.settings.general.language, "en")

        XCTAssertEqual(center.themePreset, .system)

        // 旧dark输入迁移为System；重新从磁盘加载仍为同一真值。
        let reloaded = SettingsStore(directory: dir)
        XCTAssertEqual(reloaded.settings.general.appearance, .system)
        XCTAssertEqual(reloaded.settings.general.themePreset, .system)
        XCTAssertEqual(reloaded.settings.general.defaultProviderID, "openai")
        XCTAssertEqual(reloaded.settings.general.defaultModelID, "gpt-4o-mini")
        XCTAssertEqual(reloaded.settings.general.language, "en")

        center.themePreset = .light
        let lightReload = SettingsStore(directory: dir)
        XCTAssertEqual(lightReload.settings.general.themePreset, .light)
        XCTAssertEqual(lightReload.settings.general.appearance, .light)
        XCTAssertEqual(lightReload.settings.general.defaultProviderID, "openai")
    }

    // MARK: - Agent

    func testAgentSettingsBinding() {
        let (center, _) = makeCenter()
        center.maxLoopIterations = 25
        center.toolTimeoutSeconds = 120
        center.concurrentToolLimit = 8
        center.autoCompactThreshold = 0.9
        center.fallbackEnabled = false

        let s = center.settingsStore.settings.agent
        XCTAssertEqual(s.maxLoopIterations, 25)
        XCTAssertEqual(s.toolTimeoutSeconds, 120)
        XCTAssertEqual(s.concurrentToolLimit, 8)
        XCTAssertEqual(s.autoCompactThreshold, 0.9, accuracy: 0.001)
        XCTAssertFalse(s.fallbackEnabled)
    }

    func testContextAndHistoryNumericBoundsPersistAndRejectInvalidEdits() {
        let (center, dir) = makeCenter()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertTrue(center.setContextLengthTokens(1))
        XCTAssertTrue(center.setHistoryTurnLimit(1))
        XCTAssertEqual(center.contextLengthTokens, 1)
        XCTAssertEqual(center.historyTurnLimit, 1)
        XCTAssertFalse(center.setContextLengthTokens(-1))
        XCTAssertFalse(center.setHistoryTurnLimit(-1))
        XCTAssertEqual(center.contextLengthTokens, 1)
        XCTAssertEqual(center.historyTurnLimit, 1)

        let reopened = SettingsStore(directory: dir)
        XCTAssertEqual(reopened.settings.agent.contextLengthTokens, 1)
        XCTAssertEqual(reopened.settings.agent.historyTurnLimit, 1)

        XCTAssertTrue(center.setContextLengthTokens(0))
        XCTAssertTrue(center.setHistoryTurnLimit(0))
        XCTAssertEqual(center.contextLengthTokens, 0)
        XCTAssertEqual(center.historyTurnLimit, 0)
        let reopenedAtZero = SettingsStore(directory: dir)
        XCTAssertNil(reopenedAtZero.settings.agent.contextLengthTokens)
        XCTAssertNil(reopenedAtZero.settings.agent.historyTurnLimit)
    }

    func testPolicyRuntimeDefaultsAreProjectedReadOnlyFromAgentSettings() {
        let expected = ProductionPolicyDefaults(
            budget: 777,
            deadlineHorizon: 125,
            autonomyLevel: .l2,
            networkDomains: ["api.example.com"]
        )
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("D5PolicyProjection-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var initial = AppSettings.defaults
        initial.agent.policyRuntimeDefaults = expected
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: dir, initial: initial),
            envStore: EnvVarStore(directory: dir),
            memoryStore: MemoryStore(directory: dir),
            sessionStore: SessionStore(directory: dir),
            logManager: LogManager(directory: dir, ringCapacity: 50)
        )
        XCTAssertEqual(center.policyRuntimeDefaults, expected)
    }

    // MARK: - 隐私（级别 ↔ LogManager 联动）

    func testPrivacyLogLevelSyncsToLogManager() {
        let (center, _) = makeCenter()
        center.privacyLogLevel = .error
        XCTAssertEqual(center.logManager.minimumLevel, .error)
        XCTAssertEqual(center.settingsStore.settings.privacy.logLevel, .error)

        // 反向：日志页 live 级别写回设置
        center.liveLogLevel = .debug
        XCTAssertEqual(center.logManager.minimumLevel, .debug)
        XCTAssertEqual(center.settingsStore.settings.privacy.logLevel, .debug)
        XCTAssertEqual(center.liveLogLevel, .debug)
    }

    func testPrivacyToggles() {
        let (center, _) = makeCenter()
        center.redactEnvValues = false
        center.collectAnalytics = true
        XCTAssertFalse(center.settingsStore.settings.privacy.redactEnvValues)
        XCTAssertTrue(center.settingsStore.settings.privacy.collectAnalytics)
    }

    // MARK: - 环境变量（C1a EnvVarStore）

    func testEnvVarCRUD() {
        let (center, _) = makeCenter()
        XCTAssertTrue(center.setEnvVar(name: "d5_test_key", value: "secret-value", isSecret: true))
        XCTAssertEqual(center.envEntries.count, 1)
        XCTAssertEqual(center.envEntries.first?.name, "D5_TEST_KEY")
        XCTAssertTrue(center.envEntries.first?.isSecret == true)

        // 更新（不改变 secret 标记）
        XCTAssertTrue(center.setEnvVar(name: "D5_TEST_KEY", value: "new-value"))
        XCTAssertEqual(center.envStore.getEnvVar(name: "d5_test_key"), "new-value")

        // 非法名称拒绝
        XCTAssertFalse(center.setEnvVar(name: "1BAD NAME!", value: "x"))

        let deletion = try! center.previewEnvVarDeletion(name: "d5_test_key")
        _ = try! center.deleteEnvVar(name: "d5_test_key", intent: confirmed(deletion))
        XCTAssertTrue(center.envEntries.isEmpty)
    }

    func testImportFromProcessEnvironment() {
        let (center, _) = makeCenter()
        setenv("D5_UNIQUE_IMPORT_VAR", "hello", 1)
        defer { unsetenv("D5_UNIQUE_IMPORT_VAR") }

        let imported = center.importFromProcessEnvironment()
        XCTAssertGreaterThanOrEqual(imported, 1)
        XCTAssertEqual(center.envStore.getEnvVar(name: "D5_UNIQUE_IMPORT_VAR"), "hello")
    }

    // MARK: - 日志（C1c LogManager clear + 级别过滤）

    func testLogManagerClearAndLevelFilter() {
        let (center, _) = makeCenter()
        center.liveLogLevel = .info
        center.logManager.debug("should be filtered", category: "Test")
        center.logManager.info("visible info", category: "Test")
        center.logManager.error("visible error", category: "Test")

        center.reloadLogs()
        XCTAssertEqual(center.logEntries.count, 2)
        XCTAssertFalse(center.logEntries.contains { $0.message == "should be filtered" })

        let deletion = try! center.previewLogClear()
        _ = try! center.clearLogs(intent: confirmed(deletion))
        center.reloadLogs()
        XCTAssertTrue(center.logEntries.isEmpty)
    }

    // MARK: - 存储（C2b MemoryStore / SessionStore 清理）

    func testDeleteSessionUsesDeletionServiceTrash() throws {
        let (center, _) = makeCenter()
        let session = try center.sessionStore.createSession(title: "single")

        let payload = try Data(contentsOf: center.sessionStore.sessionsDirectory.appendingPathComponent("\(session.id).json"))
        let deletion = try center.previewSessionDeletion(id: session.id)
        let receipt = try center.deleteSession(id: session.id, intent: confirmed(deletion))

        XCTAssertNil(center.sessionStore.loadSession(id: session.id))
        let trashDirectory = center.sessionStore.sessionsDirectory.appendingPathComponent("_trash", isDirectory: true)
        XCTAssertEqual(receipt.targetID, session.id)
        XCTAssertEqual(receipt.scopeID, "session:\(session.id):active")
        let payloadName = "\(receipt.operationID.uuidString).json"
        let receiptName = ".trash-receipt-\(receipt.operationID.uuidString).json"
        let names = try Set(FileManager.default.contentsOfDirectory(at: trashDirectory, includingPropertiesForKeys: nil).map(\.lastPathComponent))
        XCTAssertEqual(names, Set([payloadName, receiptName]))
        XCTAssertEqual(try Data(contentsOf: trashDirectory.appendingPathComponent(payloadName)), payload)
        try assertTrashEntry(in: trashDirectory, receipt: receipt, title: session.title, payload: payload)
    }

    func testDeleteSessionsOlderThanRetention() throws {
        let (center, dir) = makeCenter()
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let store = center.sessionStore

        // 旧会话（90 天前更新）
        var old = try store.createSession(title: "old")
        old.updatedAt = Date().addingTimeInterval(-90 * 86_400)
        try store.updateSession(old)
        // 新会话（刚刚）
        let recent = try store.createSession(title: "new")
        let oldURL = store.sessionsDirectory.appendingPathComponent("\(old.id).json")
        let recentURL = store.sessionsDirectory.appendingPathComponent("\(recent.id).json")
        let oldBytes = try Data(contentsOf: oldURL)
        let recentBytes = try Data(contentsOf: recentURL)

        center.sessionRetentionDays = 30
        center.reloadStorage()
        XCTAssertEqual(center.sessions.count, 2)

        let deletion = try center.previewSessionsOlderThanRetention()
        let receipt = try center.deleteSessionsOlderThanRetention(intent: confirmed(deletion))
        XCTAssertEqual(receipt.affectedCount, 1)
        XCTAssertEqual(center.sessions.count, 1)
        XCTAssertEqual(center.sessions.first?.title, "new")
        let trashDirectory = store.sessionsDirectory.appendingPathComponent("_trash", isDirectory: true)
        let children = try center.sessionDeletionRecoveryReceipts(from: receipt)
        XCTAssertEqual(children.map(\.targetID), [old.id])
        XCTAssertEqual(children.map(\.scopeID), ["session:\(old.id):active"])
        let child = try XCTUnwrap(children.first)
        let trashURL = trashDirectory.appendingPathComponent("\(child.operationID.uuidString).json")
        XCTAssertEqual(try Data(contentsOf: trashURL), oldBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertEqual(try Data(contentsOf: recentURL), recentBytes)
        let names = try Set(FileManager.default.contentsOfDirectory(
            at: trashDirectory, includingPropertiesForKeys: nil
        ).map(\.lastPathComponent))
        XCTAssertEqual(names, Set([trashURL.lastPathComponent,
            ".trash-receipt-\(child.operationID.uuidString).json",
            ".batch-\(receipt.operationID.uuidString).receipt"]))
        try assertTrashEntry(in: trashDirectory, receipt: child, title: old.title, payload: oldBytes)
    }

    func testRetentionPreviewExecuteRejectsChangedActiveSet() throws {
        let (center, _) = makeCenter()
        let store = center.sessionStore
        var stale = try store.createSession(title: "stale")
        stale.updatedAt = Date().addingTimeInterval(-90 * 86_400)
        try store.updateSession(stale)

        center.sessionRetentionDays = 30
        center.reloadStorage()
        let now = Date()
        let intent = try center.previewSessionsOlderThanRetention(now: now, ttl: 300)
        XCTAssertEqual(intent.affectedCount, 1)

        stale.title = "stale-changed"
        try store.updateSession(stale)
        XCTAssertThrowsError(
            try center.deleteSessionsOlderThanRetention(
                intent: confirmed(intent),
                now: now.addingTimeInterval(1)
            )
        ) { error in
            XCTAssertEqual(error as? DeletionGateError, .targetChanged)
        }
        XCTAssertNotNil(store.loadSession(id: stale.id))
    }

    func testRetentionOnlyDeletesStaleActiveAndProtectsFreshAndArchived() throws {
        let (center, _) = makeCenter()
        let store = center.sessionStore

        var staleActive = try store.createSession(title: "stale-active")
        staleActive.updatedAt = Date().addingTimeInterval(-90 * 86_400)
        try store.updateSession(staleActive)

        var nearCutoff = try store.createSession(title: "near-cutoff")
        nearCutoff.updatedAt = Date().addingTimeInterval(-29 * 86_400)
        try store.updateSession(nearCutoff)
        let newActive = try store.createSession(title: "new-active")

        var staleArchived = try store.createSession(title: "stale-archived")
        staleArchived.updatedAt = Date().addingTimeInterval(-90 * 86_400)
        try store.updateSession(staleArchived)
        let manager = SessionManager(store: store)
        try manager.archive(sessionID: staleArchived.id)

        center.sessionRetentionDays = 30
        center.reloadStorage()
        let now = Date()
        let intent = try center.previewSessionsOlderThanRetention(now: now, ttl: 300)
        XCTAssertEqual(intent.affectedCount, 1)
        let receipt = try center.deleteSessionsOlderThanRetention(
            intent: confirmed(intent),
            now: now.addingTimeInterval(1)
        )

        XCTAssertEqual(receipt.affectedCount, 1)
        XCTAssertNil(store.loadSession(id: staleActive.id))
        XCTAssertNotNil(store.loadSession(id: nearCutoff.id))
        XCTAssertNotNil(store.loadSession(id: newActive.id))
        XCTAssertNotNil(manager.loadSessionIncludingArchived(id: staleArchived.id))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: manager.archiveDirectory
                .appendingPathComponent("\(staleArchived.id).json")
                .path
        ))
        XCTAssertEqual(center.sessions.count, 2)
    }

    func testDeleteAllSessionsUsesDeletionServiceTrash() throws {
        let (center, dir) = makeCenter()
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let first = try center.sessionStore.createSession(title: "first")
        let second = try center.sessionStore.createSession(title: "second")
        let sessionsDirectory = center.sessionStore.sessionsDirectory
        let before = try Dictionary(uniqueKeysWithValues: [first, second].map { session in
            (session.id, try Data(contentsOf: sessionsDirectory.appendingPathComponent("\(session.id).json")))
        })
        center.reloadStorage()

        let deletion = try center.previewAllSessions()
        let receipt = try center.deleteAllSessions(intent: confirmed(deletion))
        XCTAssertEqual(receipt.affectedCount, 2)
        XCTAssertTrue(center.sessions.isEmpty)
        let trashDirectory = center.sessionStore.sessionsDirectory.appendingPathComponent("_trash", isDirectory: true)
        let children = try center.sessionDeletionRecoveryReceipts(from: receipt)
        XCTAssertEqual(Set(children.map(\.targetID)), Set([first.id, second.id]))
        XCTAssertEqual(Set(children.map(\.scopeID)), Set(["session:\(first.id):active", "session:\(second.id):active"]))
        for child in children {
            let trashURL = trashDirectory.appendingPathComponent("\(child.operationID.uuidString).json")
            let originalBytes = try XCTUnwrap(before[child.targetID])
            XCTAssertEqual(try Data(contentsOf: trashURL), originalBytes)
            let title = child.targetID == first.id ? first.title : second.title
            try assertTrashEntry(in: trashDirectory, receipt: child, title: title, payload: originalBytes)
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: sessionsDirectory.appendingPathComponent("\(child.targetID).json").path
            ))
        }
        let expectedNames = Set(children.flatMap {
            ["\($0.operationID.uuidString).json", ".trash-receipt-\($0.operationID.uuidString).json"]
        }).union([".batch-\(receipt.operationID.uuidString).receipt"])
        let names = try Set(FileManager.default.contentsOfDirectory(
            at: trashDirectory, includingPropertiesForKeys: nil
        ).map(\.lastPathComponent))
        XCTAssertEqual(names, expectedNames)
        XCTAssertNil(center.sessionStore.loadSession(id: first.id))
        XCTAssertNil(center.sessionStore.loadSession(id: second.id))
    }

    func testMemoryClear() throws {
        let (center, _) = makeCenter()
        try center.memoryStore.addFact("fact one")
        try center.memoryStore.addFact("fact two")
        center.reloadStorage()
        XCTAssertEqual(center.memoryFacts.count, 2)

        let deletion = try center.previewMemoryClear()
        let receipt = try center.clearAllMemory(intent: confirmed(deletion))
        XCTAssertEqual(receipt.affectedCount, 2)
        XCTAssertTrue(center.memoryFacts.isEmpty)
    }

    // MARK: - 恢复默认

    func testResetToDefaults() {
        let (center, _) = makeCenter()
        center.appearance = .dark
        center.maxLoopIterations = 99
        center.resetToDefaults()

        XCTAssertEqual(center.settingsStore.settings.general.appearance, .system)
        XCTAssertEqual(center.settingsStore.settings.agent.maxLoopIterations, AppSettings.defaults.agent.maxLoopIterations)
        XCTAssertNotEqual(center.settingsStore.settings.agent.maxLoopIterations, 99)
    }

    // MARK: - Phase B persistence transaction seam

    func testPersistenceFailurePreservesMirrorAndSuppressesApprovalCallback() {
        let (center, _) = makeWriteFailingCenter()
        var callbackCount = 0
        center.onApprovalPolicyChanged = { _ in callbackCount += 1 }

        center.approvalPolicy = .deny

        XCTAssertEqual(center.approvalPolicy, .alwaysAsk)
        XCTAssertEqual(center.settingsStore.settings.agent.approvalPolicy, .alwaysAsk)
        XCTAssertEqual(center.lastPersistenceError, .writeFailed)
        XCTAssertEqual(callbackCount, 0)
    }

    func testPersistenceSuccessClearsErrorAndPublishesApprovalCallback() {
        let (center, dir) = makeWriteFailingCenter()
        var callbackCount = 0
        center.onApprovalPolicyChanged = { _ in callbackCount += 1 }

        center.approvalPolicy = .deny
        XCTAssertEqual(center.lastPersistenceError, .writeFailed)

        let settingsURL = dir.appendingPathComponent(SettingsStore.fileName)
        try? FileManager.default.removeItem(at: settingsURL)
        center.approvalPolicy = .riskOnlyAsk

        XCTAssertEqual(center.approvalPolicy, .riskOnlyAsk)
        XCTAssertEqual(center.settingsStore.settings.agent.approvalPolicy, .riskOnlyAsk)
        XCTAssertNil(center.lastPersistenceError)
        XCTAssertEqual(callbackCount, 1)
    }

    func testResetPersistenceFailurePreservesMirrorRuntimeAndCallbacks() {
        let (center, dir) = makeCenter()
        center.approvalPolicy = .deny
        center.setSafeMode(true)
        var safetyCallbackCount = 0
        var composerCallbackCount = 0
        center.onSafetyRuntimeSnapshotChanged = { _ in safetyCallbackCount += 1 }
        center.onComposerPolicyChanged = { _ in composerCallbackCount += 1 }

        let settingsURL = dir.appendingPathComponent(SettingsStore.fileName)
        try? FileManager.default.removeItem(at: settingsURL)
        try? FileManager.default.createDirectory(at: settingsURL, withIntermediateDirectories: true)
        center.resetToDefaults()

        XCTAssertEqual(center.approvalPolicy, .deny)
        XCTAssertTrue(center.safeModeEnabled)
        XCTAssertEqual(center.lastPersistenceError, .writeFailed)
        XCTAssertEqual(safetyCallbackCount, 0)
        XCTAssertEqual(composerCallbackCount, 0)
    }
    // D-SETA / D-SETB: global reset must reach the same effective consumers
    // as individual successful setters. Callback checks are boundary evidence;
    // the logger below is the actual production admission consumer.
    private func makeResetConsumerFixture853() throws -> SettingsCenter {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "set853", canvasRuntimeState: .disabled
        )
        let root = profile.rootDirectory
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        return SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            memoryFileStore: MemoryFileStore(directory: root.appendingPathComponent("memory-files")),
            sessionStore: SessionStore(directory: profile.sessionDirectory),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            logManager: LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 20),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite("set853-\(UUID().uuidString)")),
            providerReadinessTransport: M03FileAccessNoNetworkTransport(),
            providerReadinessDeployment: .mock,
            providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        )
    }

    private func seedResetConsumers853(_ center: SettingsCenter) {
        center.privacyLogLevel = .debug
        center.childConcurrencyUserSelected = 8
        center.childConcurrencyEnabledSessionCount = 3
        center.childConcurrencyRiskAcknowledged = true
        center.approvalPolicy = .riskOnlyAsk
        center.personaEnabled = true
        var policy = center.policyRuntimeDefaults
        policy.budget = 777
        XCTAssertTrue(center.updatePolicyRuntimeDefaults(policy))
        XCTAssertNil(center.lastPersistenceError)
    }

    func testGlobalReset853PublishesDurableDefaultsAndRealLogAdmission() throws {
        let center = try makeResetConsumerFixture853()
        seedResetConsumers853(center)
        let defaults = AppSettings.defaults
        let url = center.settingsStore.fileURL
        center.logManager.debug("853-before-reset", category: "SettingsReset")
        XCTAssertTrue(center.logManager.recentLogs().contains { $0.message == "853-before-reset" })
        var delivered: [String] = []
        func record(_ name: String) {
            // Reopen inside each delivery: no callback may race ahead of disk.
            XCTAssertEqual(SettingsStore(directory: center.settingsDirectory).settings, defaults)
            XCTAssertEqual(center.settingsMirror, defaults)
            delivered.append(name)
        }
        center.onChildConcurrencySelectionChanged = {
            XCTAssertEqual($0, center.childConcurrencySelection)
            XCTAssertEqual($0.userSelected, defaults.agent.childConcurrencyUserSelected)
            XCTAssertEqual($0.enabledSessionCount, defaults.agent.childConcurrencyEnabledSessionCount)
            XCTAssertFalse(center.childConcurrencyRiskAcknowledged)
            record("child")
        }
        center.onApprovalPolicyChanged = { XCTAssertEqual($0, defaults.agent.approvalPolicy); record("approval") }
        center.onPolicyRuntimeDefaultsChanged = { XCTAssertEqual($0, defaults.agent.policyRuntimeDefaults); record("policy") }
        center.onPersonaSettingsChanged = {
            XCTAssertEqual($0, defaults.agent.persona)
            XCTAssertEqual($1, defaults.agent.personaEnabled)
            record("persona")
        }
        center.onFileAccessSettingsChanged = { record("fileAccess") }
        center.onSafetyRuntimeSnapshotChanged = { _ in record("safety") }
        center.onComposerPolicyChanged = { XCTAssertEqual($0, defaults.agent.composerPolicy); record("composer") }
        center.onTerminalPolicyChanged = { _ in record("terminal") }
        center.resetToDefaults()
        XCTAssertNil(center.lastPersistenceError)
        XCTAssertEqual(center.settingsStore.settings, defaults)
        XCTAssertEqual(center.settingsMirror, defaults)
        XCTAssertEqual(SettingsStore(directory: center.settingsDirectory).settings, defaults)
        XCTAssertFalse(try Data(contentsOf: url).isEmpty)
        XCTAssertEqual(delivered.sorted(), ["approval", "child", "composer", "fileAccess", "persona", "policy", "safety", "terminal"])
        XCTAssertEqual(center.privacyLogLevel, defaults.privacy.logLevel)
        XCTAssertEqual(center.liveLogLevel, defaults.privacy.logLevel)
        XCTAssertEqual(center.logManager.minimumLevel, LogLevel(defaults.privacy.logLevel))
        center.logManager.debug("853-debug-after-reset", category: "SettingsReset")
        center.logManager.info("853-info-after-reset", category: "SettingsReset")
        XCTAssertFalse(center.logManager.recentLogs().contains { $0.message == "853-debug-after-reset" })
        XCTAssertTrue(center.logManager.recentLogs().contains { $0.message == "853-info-after-reset" })
    }

    func testGlobalReset853FailedPersistencePreservesEveryRuntimeDeliveryAndLogAdmission() throws {
        let center = try makeResetConsumerFixture853()
        seedResetConsumers853(center)
        let original = center.settingsMirror
        let selection = center.childConcurrencySelection
        let safety = center.safetyRuntimeSnapshot
        let directory = center.settingsDirectory
        let url = center.settingsStore.fileURL
        let bytes = try Data(contentsOf: url)
        var deliveries = 0
        center.onChildConcurrencySelectionChanged = { _ in deliveries += 1 }
        center.onApprovalPolicyChanged = { _ in deliveries += 1 }
        center.onPolicyRuntimeDefaultsChanged = { _ in deliveries += 1 }
        center.onPersonaSettingsChanged = { _, _ in deliveries += 1 }
        center.onFileAccessSettingsChanged = { deliveries += 1 }
        center.onSafetyRuntimeSnapshotChanged = { _ in deliveries += 1 }
        center.onComposerPolicyChanged = { _ in deliveries += 1 }
        center.onTerminalPolicyChanged = { _ in deliveries += 1 }
        // Retain the owned file; block replacement rather than delete it.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        center.resetToDefaults()
        XCTAssertNotNil(center.lastPersistenceError)
        XCTAssertEqual(center.lastPersistenceError, center.settingsStore.lastPersistenceError)
        XCTAssertEqual(center.settingsMirror, original)
        XCTAssertEqual(center.settingsStore.settings, original)
        XCTAssertEqual(SettingsStore(directory: directory).settings, original)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(center.childConcurrencySelection, selection)
        XCTAssertTrue(center.childConcurrencyRiskAcknowledged)
        XCTAssertEqual(center.safetyRuntimeSnapshot, safety)
        XCTAssertEqual(deliveries, 0)
        XCTAssertEqual(center.liveLogLevel, .debug)
        XCTAssertEqual(center.logManager.minimumLevel, .debug)
        center.logManager.debug("853-debug-after-rejected-reset", category: "SettingsReset")
        XCTAssertTrue(center.logManager.recentLogs().contains { $0.message == "853-debug-after-rejected-reset" })
    }

    // MARK: - D-PRIVACY-01/02 durable producer boundary

    /// Every SettingsCenter dependency has a synthetic root or in-memory backing.
    /// In particular, this helper does not use makeCenter()'s omitted defaults.
    private func makeIsolatedFileAccessCenter() throws -> (center: SettingsCenter, root: URL, suiteName: String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("M03-FileAccess-\(UUID().uuidString)", isDirectory: true)
        let directories = ["settings", "env", "memory", "memory-files", "sessions",
                           "logs", "mcp", "skills", "readiness"]
        for name in directories {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        let suiteName = "M03-FileAccess-\(UUID().uuidString)"
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            memoryFileStore: MemoryFileStore(directory: root.appendingPathComponent("memory-files")),
            sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
            logManager: LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 20),
            mcpManager: MCPServerManager(
                fileURL: root.appendingPathComponent("mcp/mcps.json"),
                keychain: keychain
            ),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite(suiteName)),
            providerReadinessTransport: M03FileAccessNoNetworkTransport(),
            providerReadinessStore: ProviderReadinessStore(
                directory: root.appendingPathComponent("readiness")
            )
        )
        return (center, root, suiteName)
    }

    private func releaseIsolatedFileAccessFixture(root: URL, suiteName: String) {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    func testFileAccessSuccessPublishesExactlyOnceAfterDurableWrite() throws {
        let fixture = try makeIsolatedFileAccessCenter()
        defer { releaseIsolatedFileAccessFixture(root: fixture.root, suiteName: fixture.suiteName) }
        let allowed = fixture.root.appendingPathComponent("allowed", isDirectory: true)
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        let settingsDirectory = fixture.center.settingsDirectory
        var durableValuesAtCallback: [String?] = []
        fixture.center.onFileAccessSettingsChanged = {
            durableValuesAtCallback.append(
                SettingsStore(directory: settingsDirectory).settings.privacy.allowedRootPath
            )
        }

        XCTAssertTrue(fixture.center.setFileAccessAllowedRoot(allowed.path))
        XCTAssertEqual(durableValuesAtCallback.count, 1)
        XCTAssertEqual(durableValuesAtCallback.first ?? nil, allowed.path)
        XCTAssertEqual(fixture.center.fileAccessAllowedRoot, allowed.path)
        XCTAssertEqual(fixture.center.settings.privacy.allowedRootPath, allowed.path)
        XCTAssertNil(fixture.center.lastPersistenceError)
    }

    func testFileAccessWriteFailurePreservesMirrorAndSuppressesCallback() throws {
        let fixture = try makeIsolatedFileAccessCenter()
        defer { releaseIsolatedFileAccessFixture(root: fixture.root, suiteName: fixture.suiteName) }
        let original = fixture.root.appendingPathComponent("original", isDirectory: true)
        let rejected = fixture.root.appendingPathComponent("rejected", isDirectory: true)
        XCTAssertTrue(fixture.center.setFileAccessAllowedRoot(original.path))
        let settingsURL = fixture.center.settingsStore.fileURL
        try FileManager.default.removeItem(at: settingsURL)
        try FileManager.default.createDirectory(at: settingsURL, withIntermediateDirectories: true)
        var callbackCount = 0
        fixture.center.onFileAccessSettingsChanged = { callbackCount += 1 }

        XCTAssertFalse(fixture.center.setFileAccessAllowedRoot(rejected.path))
        fixture.center.fileAccessDeniedRoots = [rejected.path]
        XCTAssertEqual(fixture.center.fileAccessAllowedRoot, original.path)
        XCTAssertEqual(fixture.center.settings.privacy.allowedRootPath, original.path)
        XCTAssertEqual(fixture.center.fileAccessDeniedRoots, [])
        XCTAssertEqual(fixture.center.settings.privacy.deniedRootPaths, [])
        XCTAssertEqual(fixture.center.lastPersistenceError, .writeFailed)
        XCTAssertEqual(callbackCount, 0)
    }

    func testRuntimeDeniedRootsRetainDefaultsAlongsideUserDeniedChild() throws {
        let fixture = try makeIsolatedFileAccessCenter()
        defer { releaseIsolatedFileAccessFixture(root: fixture.root, suiteName: fixture.suiteName) }
        let deniedChild = fixture.root.appendingPathComponent("allowed/blocked", isDirectory: true)
        XCTAssertTrue(fixture.center.addFileAccessDeniedRoot(deniedChild.path))
        let defaults = Set(BuiltinToolExecutor.defaultDeniedRoots().map(\.path))
        let runtime = Set(fixture.center.runtimeDeniedRoots)

        XCTAssertTrue(defaults.isSubset(of: runtime))
        XCTAssertTrue(runtime.contains(deniedChild.path))
        XCTAssertEqual(
            Set(fixture.center.terminalPolicy(scopeID: "synthetic", workdir: fixture.root.path).deniedRoots),
            runtime
        )
    }

    func testResetFileAccessRootsCommitsOneSnapshotAndPublishesOnce() throws {
        let fixture = try makeIsolatedFileAccessCenter()
        defer { releaseIsolatedFileAccessFixture(root: fixture.root, suiteName: fixture.suiteName) }
        let allowed = fixture.root.appendingPathComponent("allowed", isDirectory: true)
        let denied = allowed.appendingPathComponent("blocked", isDirectory: true)
        let mounted = fixture.root.appendingPathComponent("mounted", isDirectory: true)
        XCTAssertTrue(fixture.center.setFileAccessAllowedRoot(allowed.path))
        XCTAssertTrue(fixture.center.addFileAccessDeniedRoot(denied.path))
        XCTAssertTrue(fixture.center.mountFolder(mounted.path))
        let settingsDirectory = fixture.center.settingsDirectory
        var durableAtCallback: [(allowed: String?, denied: [String], mounted: [String])] = []
        fixture.center.onFileAccessSettingsChanged = {
            let privacy = SettingsStore(directory: settingsDirectory).settings.privacy
            durableAtCallback.append((privacy.allowedRootPath, privacy.deniedRootPaths,
                                      privacy.mountedFolderPaths))
        }

        fixture.center.resetFileAccessRoots()

        XCTAssertEqual(durableAtCallback.count, 1)
        XCTAssertNil(durableAtCallback.first?.allowed)
        XCTAssertEqual(durableAtCallback.first?.denied, [])
        XCTAssertEqual(durableAtCallback.first?.mounted, [mounted.path])
        XCTAssertNil(fixture.center.fileAccessAllowedRoot)
        XCTAssertEqual(fixture.center.fileAccessDeniedRoots, [])
        XCTAssertEqual(fixture.center.mountedFolderPaths, [mounted.path])
    }
}
