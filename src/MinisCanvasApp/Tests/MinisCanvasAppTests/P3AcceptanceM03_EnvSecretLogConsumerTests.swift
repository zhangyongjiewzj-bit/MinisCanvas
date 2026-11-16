import Foundation
import AppKit
import Testing
import MinisCore
@testable import MinisCanvasApp

/// D-PRIVACY-07: the settings owner and the production log sink must agree on
/// configured secret values. This uses only synthetic stores and credentials.
@Suite("D-PRIVACY-07 configured environment secrets in logs")
@MainActor
struct P3AcceptanceM03_EnvSecretLogConsumerTests {
    @Test("a secret has a readonly credential reference and both log sinks remain redacted")
    func configuredSecretIsRedactedFromBothLogSinks() async throws {
        try #require(NSApplication.shared.isRunning)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("P3AcceptanceM03-EnvSecretLog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suiteName = "P3AcceptanceM03.EnvSecretLog.\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let log = LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 10)
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            memoryFileStore: MemoryFileStore(directory: root.appendingPathComponent("memory-files")),
            sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
            logManager: log,
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite(suiteName)),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock,
            providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        )
        let value = "violet-synthetic-marker-\(UUID().uuidString)"
        #expect(center.setEnvVar(name: "P3_TEST_CREDENTIAL", value: value, isSecret: true))
        #expect(center.envEntries.first?.isSecret == true)

        log.info("synthetic diagnostic: \(value)", category: "SyntheticSettings")
        #expect(!log.recentLogsText().contains(value))
        let logURL = try #require(log.logFileURL())
        #expect(!String(decoding: try Data(contentsOf: logURL), as: UTF8.self).contains(value))


        // The real settings row and its real edit sheet consume this same owner.
        let native = SettingsNativeInteractionConsumerTests()
        let host = native.makeSettingsWindow(center: center, initialPageID: "环境变量")
        defer {
            for sheet in host.window.sheets {
                host.window.endSheet(sheet, returnCode: .cancel)
                sheet.orderOut(nil)
            }
            native.closeSettingsWindow(host)
        }
        _ = try #require(NativeConsumerOwnedAX.find(in: host.window,
            identifier: "settings.environment.details.P3_TEST_CREDENTIAL"))
        // Readonly static text is the public disclosure surface. Do not read
        // Value, Description, Help or descendants of a secret input control.
        _ = try #require(NativeConsumerOwnedAX.findDisplayedText(in: host.window,
            exactText: "Keychain 引用：P3_TEST_CREDENTIAL（仅运行时解析）"))
        let edit = try #require(NativeConsumerOwnedAX.find(in: host.window,
            identifier: "settings.environment.edit.P3_TEST_CREDENTIAL"))
        try #require(NativeConsumerOwnedAX.press(edit))
        for _ in 0..<100 {
            if host.window.attachedSheet != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let sheet = try #require(host.window.attachedSheet)
        try #require(sheet.sheetParent === host.window)
        _ = try #require(NativeConsumerOwnedAX.findDisplayedText(in: host.window,
            exactText: "编辑环境变量"))
        // This is a list/reference and editor-title sub-consumer only. It
        // does not establish absence of secret text throughout the editor.
        #expect(!log.recentLogsText().contains(value))
        #expect(!String(decoding: try Data(contentsOf: logURL), as: UTF8.self).contains(value))
        #expect(center.envStore.getEnvVar(name: "P3_TEST_CREDENTIAL") == value)
    }
}
