import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-SETA/D-SETB output mode reset reaches the active consumer", .serialized)
@MainActor
struct SETBOutputModeResetConsumer2602Tests {
    private func makeCenter(_ root: URL) throws -> SettingsCenter {
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let defaults = try #require(UserDefaults(suiteName: "setb-reset-2602-\(root.lastPathComponent)"))
        return SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env"),
                                  keychain: keychain,
                                  privacyStore: EnvVarPrivacyStore(defaults: defaults)),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            memoryFileStore: MemoryFileStore(directory: root.appendingPathComponent("memory-files")),
            sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            logManager: LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 10),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcp.json"),
                                         keychain: keychain),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite("setb-reset-2602-\(root.lastPathComponent)"))
        )
    }

    @Test("committed reset immediately updates the running ChatStore")
    func committedResetUpdatesCanonicalAndEffectiveMode() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("setb-reset-2602-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let center = try makeCenter(root)
        center.chatOutputMode = .concise
        let chat = ChatStore()
        center.bindChatOutputMode(to: chat)
        #expect(chat.outputMode == .concise)

        center.resetToDefaults()

        #expect(center.lastPersistenceError == nil)
        #expect(center.chatOutputMode == .normal)
        #expect(try makeCenter(root).chatOutputMode == .normal)
        #expect(chat.outputMode == .normal)
        #expect(!ChatStore.systemPrompt(for: chat.outputMode).contains("只输出最终结果"))
    }

    @Test("rejected reset preserves both canonical and effective mode")
    func failedResetCannotPublishDefaultMode() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("setb-reset-fail-2602-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let center = try makeCenter(root)
        center.chatOutputMode = .concise
        let chat = ChatStore()
        center.bindChatOutputMode(to: chat)
        let before = center.settingsAppliedStateProjection.settingsRevision
        try FileManager.default.removeItem(at: center.settingsStore.fileURL)
        try FileManager.default.createDirectory(at: center.settingsStore.fileURL,
                                                withIntermediateDirectories: true)

        center.resetToDefaults()

        #expect(center.lastPersistenceError == .writeFailed)
        #expect(center.chatOutputMode == .concise)
        #expect(center.settingsAppliedStateProjection.settingsRevision == before)
        #expect(chat.outputMode == .concise)
    }
}
