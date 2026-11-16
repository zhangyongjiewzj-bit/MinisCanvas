import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// 内置供应商（OpenAI 等）在设置里为模型填写的上下文窗口必须进入会话实际使用的模型：
/// 占用分母、压缩/拦截阈值读 `provider.model.contextWindow`，"按 128k 估计"标签读同一值。
/// 优先级与自定义供应商一致：显式填写 > 目录 > 128k 回退。合成夹具，不碰真实凭据。
@MainActor
struct BuiltinProviderModelWindow_Tests {
    private func select(windows: [String: Int]?) throws -> (chat: ChatStore, modelID: String, cleanup: () -> Void) {
        let directory = try B1ARCHOriginalFixtureSupport.makeRoot("builtin-window")
        let readinessStore = ProviderReadinessStore(directory: directory)
        let chat = ChatStore(providerReadinessStore: readinessStore)
        let providerID = ProviderType.openAI.rawValue
        let modelID = try #require(ProviderType.openAI.builtInModels.first?.id)
        let configured = EnvVarEntry(
            name: providerID.uppercased(), value: "fixture-key", isSecret: true,
            baseURL: "https://api.openai.com/v1", modelNames: [modelID],
            protocolType: .openaiCompatible, modelContextWindows: windows)
        chat.providerRecordsSource = { [configured] }
        chat.schedulerCredentialVersionSource = { _ in "fixture-revision-1" }
        let fingerprint = ChatStore.BuiltinReadinessBinding.fingerprint(
            record: configured, credentialRevision: "fixture-revision-1")
        let checkedAt = Date()
        readinessStore.upsert(ProviderReadinessPersistenceRecord(
            providerID: providerID, modelID: modelID, status: .passed, readinessState: .live,
            checkedAt: checkedAt, evidenceID: "live-settings:" + String(repeating: "a", count: 64),
            isApplied: false, configurationFingerprint: fingerprint))
        _ = readinessStore.applyDiscoveredModels(
            providerID: providerID, modelIDs: [modelID], appliedAt: checkedAt)
        #expect(chat.applyChatModel(providerID: providerID, modelID: modelID))
        return (chat, modelID, { B1ARCHOriginalFixtureSupport.cleanupRoot(directory) })
    }

    @Test func savedWindowReachesEveryBuiltinModelConstruction() throws {
        let fixture = try select(windows: nil)
        defer { fixture.cleanup() }
        // 记录在 `select` 里没有窗口时先取基线，再用 8_192 的记录重建。
        let baseline = try fixture.chat.activeProvider().model
        #expect(baseline.contextWindow == nil)

        let withWindow = try select(windows: [fixture.modelID: 8_192])
        defer { withWindow.cleanup() }
        let runtime = try withWindow.chat.activeProvider().model
        #expect(runtime.contextWindow == 8_192 && runtime.contextWindowTokens == 8_192)
        // 发送前冻结的构造（回合实际使用的模型）读同一值。
        let frozen = try #require(try withWindow.chat.frozenSelectedProviderConstruction())
        #expect(frozen.construction.model?.contextWindowTokens == 8_192)
        // 回合开始时"按 128k 估计"标签按该值判定：显式窗口 → 不估计。
        #expect(!ModelContextWindowCatalog.usesFallbackWindow(
            explicitWindow: runtime.contextWindow, modelID: runtime.id))
    }

    @Test func unsetWindowStillFollowsCatalogOrFallback() throws {
        let fixture = try select(windows: nil)
        defer { fixture.cleanup() }
        let runtime = try fixture.chat.activeProvider().model
        #expect(runtime.contextWindow == nil)
        #expect(runtime.contextWindowTokens
            == (ModelContextWindowCatalog.window(forModelID: runtime.id) ?? 128_000))
        let frozen = try #require(try fixture.chat.frozenSelectedProviderConstruction())
        #expect(frozen.construction.model?.contextWindow == nil)
        #expect(ModelContextWindowCatalog.usesFallbackWindow(
            explicitWindow: runtime.contextWindow, modelID: runtime.id)
            == (ModelContextWindowCatalog.window(forModelID: runtime.id) == nil))
    }

    /// 定时任务提交的内置供应商会话：冻结构造的模型同样读保存的窗口。
    @Test func scheduledFrozenConstructionCarriesSavedWindow() throws {
        let fixture = try select(windows: nil)
        defer { fixture.cleanup() }
        let withWindow = try select(windows: [fixture.modelID: 8_192])
        defer { withWindow.cleanup() }
        let target = MinisCore.ChatSession(
            title: "scheduled", modelID: withWindow.modelID,
            providerTypeRaw: ProviderType.openAI.rawValue)
        let frozen = try withWindow.chat.frozenScheduledProviderConstruction(for: target)
        #expect(frozen.model?.contextWindow == 8_192)
        #expect(frozen.model?.contextWindowTokens == 8_192)

        let unset = try fixture.chat.frozenScheduledProviderConstruction(for: target)
        #expect(unset.model?.contextWindow == nil)
    }
}
