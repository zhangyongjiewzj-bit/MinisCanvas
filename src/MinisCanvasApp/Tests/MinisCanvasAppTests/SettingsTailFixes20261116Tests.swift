import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// 11/16 尾巴：备份导出失败走中文映射；“停用所有工具”前的审批策略跨重启保存。
@Suite("Settings tail fixes 2026-11-16", .serialized)
@MainActor
struct SettingsTailFixes20261116Tests {
    private func makeCenter(root: URL) -> SettingsCenter {
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        return SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("provider"), keychain: keychain),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
            logManager: LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 10),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite("tailfix1116-" + UUID().uuidString)))
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tailfix1116-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: 1 备份导出失败文案

    @Test func asyncExportFailureUsesChineseReasonNotSwiftError() async throws {
        let root = try makeRoot()
        let center = makeCenter(root: root)
        // 父路径是普通文件 → 写入必然失败。
        let blocker = root.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        let target = blocker.appendingPathComponent("out.minissync")
        let result = await center.exportBackupAsync(to: target, protection: .legacy)
        #expect(result.isError)
        #expect(result.message.hasPrefix("备份导出未完成："))
        #expect(!result.message.contains("备份导出失败"))
        #expect(!result.message.contains("Error"))
        #expect(!result.message.contains("NSCocoa"))
    }

    @Test func syncExportFailureUsesChineseReasonNotSwiftError() throws {
        let root = try makeRoot()
        let center = makeCenter(root: root)
        let blocker = root.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        let result = center.exportBackup(to: blocker.appendingPathComponent("out.minissync"))
        #expect(result.isError)
        #expect(result.message.hasPrefix("备份导出未完成："))
        #expect(!result.message.contains("NSCocoa"))
    }

    // MARK: 2 停用工具前的审批策略持久化

    @Test func rememberedPolicySurvivesRestart() throws {
        let root = try makeRoot()
        let first = makeCenter(root: root)
        first.confirmApprovalPolicy(.riskOnlyAsk)
        try #require(first.approvalPolicy == .riskOnlyAsk)
        first.toolsDisabled = true
        #expect(first.approvalPolicy == .deny)
        #expect(first.settingsMirror.agent.approvalPolicyBeforeToolsDisabled == .riskOnlyAsk)

        // 重启：同一目录重新建立设置中心，内存属性已不存在。
        let second = makeCenter(root: root)
        #expect(second.toolsDisabled)
        #expect(second.settingsMirror.agent.approvalPolicyBeforeToolsDisabled == .riskOnlyAsk)
        second.toolsDisabled = false
        #expect(second.approvalPolicy == .riskOnlyAsk)
        #expect(second.settingsMirror.agent.approvalPolicyBeforeToolsDisabled == nil)

        let third = makeCenter(root: root)
        #expect(third.approvalPolicy == .riskOnlyAsk)
        #expect(third.settingsMirror.agent.approvalPolicyBeforeToolsDisabled == nil)
    }

    @Test func restoreWithoutRecordFallsBackToAlwaysAsk() throws {
        let center = makeCenter(root: try makeRoot())
        center.confirmApprovalPolicy(.deny)
        center.toolsDisabled = false
        #expect(center.approvalPolicy == .alwaysAsk)
        #expect(center.settingsMirror.agent.approvalPolicyBeforeToolsDisabled == nil)
    }

    @Test func agentSettingsFieldIsOptionalAndOmittedWhenNil() throws {
        let encoder = JSONEncoder()
        let plain = try encoder.encode(AgentSettings.default)
        let plainText = try #require(String(data: plain, encoding: .utf8))
        #expect(!plainText.contains("approvalPolicyBeforeToolsDisabled"))

        // 旧 JSON（没有该键）解码为 nil。
        let decoded = try JSONDecoder().decode(AgentSettings.self, from: plain)
        #expect(decoded.approvalPolicyBeforeToolsDisabled == nil)
        let empty = try JSONDecoder().decode(AgentSettings.self, from: Data("{}".utf8))
        #expect(empty.approvalPolicyBeforeToolsDisabled == nil)

        var stored = AgentSettings.default
        stored.approvalPolicyBeforeToolsDisabled = .riskOnlyAsk
        let data = try encoder.encode(stored)
        #expect(try #require(String(data: data, encoding: .utf8)).contains("approvalPolicyBeforeToolsDisabled"))
        let roundTrip = try JSONDecoder().decode(AgentSettings.self, from: data)
        #expect(roundTrip.approvalPolicyBeforeToolsDisabled == .riskOnlyAsk)
        #expect(roundTrip == stored)
    }
}
