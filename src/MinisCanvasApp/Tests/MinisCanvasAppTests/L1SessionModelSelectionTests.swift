import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - L1 对话级模型独立切换（会话级覆盖 / 全局默认回落）

@Suite("对话级模型独立切换（L1）")
@MainActor
struct L1SessionModelSelectionTests {

    /// 会话模型覆盖是 ChatThread 的持久化字段；手写 Codable 漏字段时，
    /// 内存切换看似正常，但重启/磁盘重载后会丢失 Luna 供应商和模型。
    @Test func chatThreadCodableRoundTripKeepsProviderAndModelOverride() throws {
        let original = ChatThread(
            title: "Luna 会话",
            messages: [ChatMessageUI(role: .user, content: "hello")],
            modelID: "gpt-5.6-luna",
            providerTypeRaw: "custom.LUNA"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("gpt-5.6-luna"))
        #expect(json.contains("custom.LUNA"))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(ChatThread.self, from: data)
        #expect(restored.modelID == "gpt-5.6-luna")
        #expect(restored.providerTypeRaw == "custom.LUNA")
    }

    /// 会话 A/B 分别使用 Hermes/Luna 和 DeepSeek 时，切回 A 必须恢复自定义
    /// Provider，而不是显示旧的 DeepSeek 或最终发到错误 Provider。
    @Test func customLunaAndDeepSeekStayBoundToTheirSessions() throws {
        let luna = EnvVarEntry(
            name: "LUNA",
            value: "sk-test-luna",
            isSecret: true,
            baseURL: "https://luna.example.test/v1",
            modelNames: ["gpt-5.6-luna"],
            protocolType: .openaiCompatible
        )
        let chat = ChatStore()
        chat.providerRecordsSource = { [luna] }

        chat.setCustomProvider(luna)
        chat.applyPickedModel(modelID: "gpt-5.6-luna")
        let lunaSessionID = try #require(chat.activeSessionID)
        let lunaProvider = try chat.activeProvider()
        #expect(lunaProvider.name == "LUNA")
        #expect(lunaProvider.model.id == "gpt-5.6-luna")

        chat.newSession()
        chat.setProvider(.deepSeek)
        chat.applyPickedModel(modelID: "deepseek-chat")
        let deepSeekSessionID = try #require(chat.activeSessionID)
        let deepSeekProvider = try chat.activeProvider()
        #expect(deepSeekProvider.name == ProviderType.deepSeek.displayName)
        #expect(deepSeekProvider.model.id == "deepseek-chat")

        chat.switchSession(id: lunaSessionID)
        #expect(chat.activeSessionID == lunaSessionID)
        #expect(chat.selectedCustomProvider?.name == "LUNA")
        #expect(chat.selectedProviderType == nil)
        #expect(chat.selectedModelID == "gpt-5.6-luna")
        let restoredLunaProvider = try chat.activeProvider()
        #expect(restoredLunaProvider.name == "LUNA")
        #expect(restoredLunaProvider.model.id == "gpt-5.6-luna")

        chat.switchSession(id: deepSeekSessionID)
        #expect(chat.selectedCustomProvider == nil)
        #expect(chat.selectedProviderType == .deepSeek)
        #expect(chat.selectedModelID == "deepseek-chat")
        let restoredDeepSeekProvider = try chat.activeProvider()
        #expect(restoredDeepSeekProvider.name == ProviderType.deepSeek.displayName)
        #expect(restoredDeepSeekProvider.model.id == "deepseek-chat")
    }

    /// 已删除/改名的自定义 Provider 不能静默保留失效覆盖；切回该会话时应
    /// 清除失效字段并回落全局默认，避免界面显示一个无法发送的 Luna。
    @Test func missingCustomProviderClearsStaleSessionOverride() throws {
        let luna = EnvVarEntry(
            name: "LUNA",
            value: "sk-test-luna",
            baseURL: "https://luna.example.test/v1",
            modelNames: ["gpt-5.6-luna"]
        )
        var records = [luna]
        let chat = ChatStore()
        chat.providerRecordsSource = { records }
        chat.setCustomProvider(luna)
        let lunaSessionID = try #require(chat.activeSessionID)
        chat.newSession()
        let otherSessionID = try #require(chat.activeSessionID)

        records = []
        chat.switchSession(id: lunaSessionID)

        #expect(chat.activeSessionID == lunaSessionID)
        #expect(chat.selectedCustomProvider == nil)
        #expect(chat.selectedProviderType == nil)
        #expect(chat.selectedModelID == nil)
        #expect(chat.sessions.first(where: { $0.id == lunaSessionID })?.providerTypeRaw == nil)
        #expect(chat.sessions.first(where: { $0.id == lunaSessionID })?.modelID == nil)
        chat.switchSession(id: otherSessionID)
    }

    /// 会话 A 选模型 → 只影响会话 A；新会话 B 继承全局默认，不受 A 污染。
    @Test func sessionAChangeDoesNotAffectSessionB() {
        let chat = ChatStore()
        // 启动恢复路径：设全局默认（.fast 档 defaultModel = qwen-turbo-latest / dashScope）
        chat.restoreSpeedTier(.fast)
        #expect(chat.selectedModelID == "qwen-turbo-latest")
        #expect(chat.selectedProviderType == .dashScope)

        // 会话 A（init 首会话即活跃）：切到 reasoner —— 会话级覆盖
        chat.selectModel(.deepSeekReasoner)
        #expect(chat.selectedModelID == "deepseek-reasoner")
        let sessionA = chat.sessions[0]
        #expect(sessionA.modelID == "deepseek-reasoner")
        #expect(sessionA.providerTypeRaw == "deepSeek")

        // 新会话 B：无覆盖 → 回落到全局默认（不是 A 的 reasoner）
        chat.newSession()
        #expect(chat.selectedModelID == "qwen-turbo-latest")
        #expect(chat.selectedProviderType == .dashScope)
        let sessionB = chat.sessions[1]
        #expect(sessionB.modelID == nil)
        #expect(sessionB.providerTypeRaw == nil)

        // 切回会话 A：恢复其会话级模型
        chat.switchSession(id: sessionA.id)
        #expect(chat.selectedModelID == "deepseek-reasoner")
        #expect(chat.selectedProviderType == .deepSeek)
        // 会话 B 仍未受污染
        #expect(chat.sessions[1].modelID == nil)
    }

    /// 无覆盖会话不写会话级字段（会话字段保持 nil = 继承全局默认）。
    @Test func uncoveredSessionStaysNil() {
        let chat = ChatStore()
        chat.restoreSpeedTier(.fast)
        chat.newSession()
        let b = chat.sessions[1]
        #expect(b.modelID == nil)
        #expect(b.providerTypeRaw == nil)
        // 全局默认仍生效
        #expect(chat.selectedModelID == "qwen-turbo-latest")
    }

    /// 桥接往返：asPersisted → asThread 保留会话级模型字段（持久化闭环）。
    @Test func bridgeRoundTripKeepsSessionModel() {
        let chat = ChatStore()
        chat.selectModel(.qwen38MaxPreview)
        let persisted = chat.sessions[0].asPersisted()
        #expect(persisted.modelID == "qwen3.8-max-preview")
        #expect(persisted.providerTypeRaw == "dashScope")

        let restored = persisted.asThread()
        #expect(restored.modelID == "qwen3.8-max-preview")
        #expect(restored.providerTypeRaw == "dashScope")
    }

    /// 会话级切换只影响模型，不破坏档位联动（恢复会话后档位随模型重新匹配）。
    @Test func switchRestoresTierWithSessionModel() {
        let chat = ChatStore()
        chat.restoreSpeedTier(.fast) // deepseek-chat / fast
        #expect(chat.modelSpeedTier == .fast)

        chat.selectModel(.qwen38MaxPreview) // balanced
        #expect(chat.modelSpeedTier == .balanced)
        let sessionA = chat.sessions[0]

        chat.newSession() // 回落全局默认（qwen-turbo-latest / ultraFast 档）
        #expect(chat.modelSpeedTier == .ultraFast)

        chat.switchSession(id: sessionA.id) // 恢复 balanced
        #expect(chat.modelSpeedTier == .balanced)
        #expect(chat.selectedModelID == "qwen3.8-max-preview")
    }

    /// 生产启动时先 attachPersistence、后绑定 providerRecordsSource；这条顺序
    /// 必须仍能恢复磁盘中的自定义 Provider，而不能停留在全局 DashScope 默认。
    @Test func diskRestoreThenProviderSourceBindingRestoresLunaImmediately() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniscanvas-luna-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sessionID = UUID().uuidString
        let persisted = ChatSession(
            id: sessionID,
            title: "Luna 磁盘会话",
            modelID: "GPT-5.6-luna",
            providerTypeRaw: "custom.LUNA"
        )
        try SessionStore(directory: directory).updateSession(persisted)

        let luna = EnvVarEntry(
            name: "LUNA",
            value: "sk-test-luna",
            isSecret: true,
            baseURL: "https://luna.example.test/v1",
            modelNames: ["GPT-5.6-luna"],
            protocolType: .openaiCompatible
        )
        let chat = ChatStore()

        // Mirror the production order: persistence is attached before App root
        // injects SettingsCenter.providerRecords.
        chat.attachPersistence(SessionStore(directory: directory))
        chat.providerRecordsSource = { [luna] }

        #expect(chat.activeSessionID?.uuidString == sessionID)
        #expect(chat.selectedCustomProvider?.name == "LUNA")
        #expect(chat.selectedProviderType == nil)
        #expect(chat.selectedModelID == "gpt-5.6-luna")
        #expect(chat.sessions.first?.modelID == "gpt-5.6-luna")

        let provider = try chat.activeProvider()
        #expect(provider.name == "LUNA")
        #expect(provider.model.id == "gpt-5.6-luna")
    }
}
