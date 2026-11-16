import Foundation
import Testing
@testable import MinisCanvasApp
@testable import MinisCore

/// C7（L4b）：显式上下文长度超过所选模型窗口时，在唯一构造入口钳制并带出一行提示，
/// 不再得到 `.invalid`（回合以 invalidContextSettings 中止）。Core 初始化器“超窗返回 nil”的合同不动
/// （`ComposerEffortProductionConsumerTests` 钉着它）。
@Suite("C7 显式上下文长度超窗钳制")
@MainActor
struct ContextLengthClamp_C7_Tests {
    private func makeCenter() -> (SettingsCenter, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("c7-clamp-\(UUID().uuidString)")
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
            logManager: LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 20),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite("c7-clamp-\(UUID().uuidString)")),
            providerReadinessTransport: FailClosedProviderReadinessTransport()
        )
        return (center, root)
    }

    private func model(window: Int) -> LLMModel {
        LLMModel(id: "synthetic-c7-model", displayName: "Synthetic C7", provider: "synthetic-c7",
                 contextWindow: window, maxOutputTokens: 1_000)
    }

    @Test func explicitLengthAboveWindowClampsInsteadOfInvalid() throws {
        let (center, root) = makeCenter()
        defer { try? FileManager.default.removeItem(at: root) }
        try #require(SettingsCenter.active === center)
        #expect(center.setContextLengthTokens(200_000))

        let inputs = SettingsCenter.captureContextTurnSettingsInputs(
            sessionID: "c7-session", model: model(window: 128_000))
        guard case .accepted(let snapshot) = inputs.resolution else {
            Issue.record("超窗显式长度应被钳制接受，而不是 \(inputs.resolution)")
            return
        }
        #expect(snapshot.contextLengthTokens == 128_000)
        #expect(snapshot.isContextLengthUserSelected)
        let notice = try #require(inputs.clampNotice)
        #expect(notice.requestedTokens == 200_000 && notice.windowTokens == 128_000)
        #expect(notice.displayLine.contains("200000") && notice.displayLine.contains("128000"))
    }

    @Test func clampNoticeKeyIsStablePerPair() throws {
        let (center, root) = makeCenter()
        defer { try? FileManager.default.removeItem(at: root) }
        try #require(SettingsCenter.active === center)
        #expect(center.setContextLengthTokens(200_000))
        let first = SettingsCenter.captureContextTurnSettingsInputs(
            sessionID: "c7-session", model: model(window: 128_000)).clampNotice
        let second = SettingsCenter.captureContextTurnSettingsInputs(
            sessionID: "c7-session", model: model(window: 128_000)).clampNotice
        #expect(first?.dedupeKey != nil && first?.dedupeKey == second?.dedupeKey)
        let otherWindow = SettingsCenter.captureContextTurnSettingsInputs(
            sessionID: "c7-session", model: model(window: 64_000)).clampNotice
        #expect(otherWindow?.dedupeKey != first?.dedupeKey)
    }

    @Test func lengthWithinWindowIsUntouched() throws {
        let (center, root) = makeCenter()
        defer { try? FileManager.default.removeItem(at: root) }
        try #require(SettingsCenter.active === center)
        #expect(center.setContextLengthTokens(100_000))
        let inputs = SettingsCenter.captureContextTurnSettingsInputs(
            sessionID: "c7-session", model: model(window: 128_000))
        guard case .accepted(let snapshot) = inputs.resolution else {
            Issue.record("窗口内长度应直接接受")
            return
        }
        #expect(snapshot.contextLengthTokens == 100_000)
        #expect(inputs.clampNotice == nil)
    }
}
