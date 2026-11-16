import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-SETB output mode has one canonical source", .serialized)
@MainActor
struct SETBOutputModeCanonicalConsumer1947Tests {
    private func makeCenter(_ root: URL) -> SettingsCenter {
        SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env")),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
            logManager: LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 10)
        )
    }

    private func makeRoot() throws -> URL {
        let parent = ProcessInfo.processInfo.environment["MINISCANVAS_TEST_DIRECTORY"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let root = parent.appendingPathComponent("setb-1947-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("a committed Settings page edit reaches the active Chat consumer")
    func canonicalEditAdvancesRuntimeWithoutShadowSettings() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let center = makeCenter(root)
        let chat = ChatStore()
        center.bindChatOutputMode(to: chat)

        let before = center.settingsAppliedStateProjection.settingsRevision
        center.chatOutputMode = .concise

        #expect(center.lastPersistenceError == nil)
        #expect(SettingsStore(directory: root.appendingPathComponent("settings"))
            .settings.general.chatOutputMode == .concise)
        #expect(center.settingsAppliedStateProjection.settingsRevision != before)
        #expect(chat.outputMode == .concise)
        #expect(ChatStore.systemPrompt(for: chat.outputMode).contains("只输出最终结果"))

        chat.setOutputMode(.detailed)
        #expect(center.chatOutputMode == .detailed)
        #expect(SettingsStore(directory: root.appendingPathComponent("settings"))
            .settings.general.chatOutputMode == .detailed)
        #expect(chat.outputMode == .detailed)
    }

    @Test("a rejected Chat picker edit cannot become a shadow runtime setting")
    func failedPickerWriteLeavesCanonicalAndRuntimeAtOldValue() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let center = makeCenter(root)
        let chat = ChatStore()
        center.bindChatOutputMode(to: chat)
        let before = center.settingsAppliedStateProjection.settingsRevision
        try FileManager.default.removeItem(at: center.settingsStore.fileURL)
        try FileManager.default.createDirectory(
            at: center.settingsStore.fileURL, withIntermediateDirectories: true
        )

        chat.setOutputMode(.concise)

        #expect(center.lastPersistenceError == .writeFailed)
        #expect(center.chatOutputMode == .normal)
        #expect(center.settingsStore.settings.general.chatOutputMode == .normal)
        #expect(center.settingsAppliedStateProjection.settingsRevision == before)
        #expect(chat.outputMode == .normal)
        #expect(!ChatStore.systemPrompt(for: chat.outputMode).contains("只输出最终结果"))
    }
}
