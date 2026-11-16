import Foundation
import Testing
@testable import MinisCanvasApp
@testable import MinisCore

/// C8（L4b）：设置侧的保存与输入解析。“窗口进回合”那条用例（`customProviderModel` 接线）归 C-L3 联调，不在此文件。
@Suite("C8 自定义模型窗口：输入解析与保存")
@MainActor
struct CustomModelWindow_C8_Tests {
    @Test func windowTextParsing() {
        #expect(ProviderModelContextWindowInput.parse("") == .empty)
        #expect(ProviderModelContextWindowInput.parse("   ") == .empty)
        #expect(ProviderModelContextWindowInput.parse("32000") == .valid(32_000))
        #expect(ProviderModelContextWindowInput.parse(" 32000 ") == .valid(32_000))
        #expect(ProviderModelContextWindowInput.parse("0") == .invalid)
        #expect(ProviderModelContextWindowInput.parse("-5") == .invalid)
        #expect(ProviderModelContextWindowInput.parse("12k") == .invalid)
        #expect(ProviderModelContextWindowInput.parse("1.5") == .invalid)
        #expect(ProviderModelContextWindowInput.parse("99999999999999999999") == .invalid)
    }

    @Test func settingsCenterSaveCarriesWindowsToTheProviderRecord() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("c8-center-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
            logManager: LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 20),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite("c8-center-\(UUID().uuidString)")),
            providerReadinessTransport: FailClosedProviderReadinessTransport()
        )
        #expect(center.saveProvider(
            name: "C8_CENTER", apiKey: "synthetic-nonsecret", baseURL: "https://example.invalid/v1",
            modelNames: ["small-local"], protocolType: .openaiCompatible,
            modelContextWindows: ["small-local": 32_000]))
        let record = center.providerRecords.first { $0.name == "C8_CENTER" }
        #expect(record?.modelContextWindows == ["small-local": 32_000])
    }
}
