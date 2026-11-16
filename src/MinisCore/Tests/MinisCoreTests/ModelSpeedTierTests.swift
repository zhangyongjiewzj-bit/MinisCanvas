import Foundation
import Testing
@testable import MinisCore

// MARK: - E19 模型速度档位（极快/快/均衡/质量）

@Suite("模型速度档位（E19）")
struct ModelSpeedTierTests {

    /// 每档默认模型必须存在、有 provider、且能被目录中某 ProviderType 解析。
    @Test(arguments: ModelSpeedTier.allCases)
    func defaultModelForEachTierExistsAndResolvable(_ tier: ModelSpeedTier) {
        let model = tier.defaultModel
        #expect(model != nil, "档位「\(tier.displayName)」必须有默认模型")
        guard let model else {
            Issue.record("defaultModelForEachTierExistsAndResolvable: tier \(tier.displayName) has no defaultModel, remaining assertions never ran")
            return
        }
        #expect(LLMModel.allModels.contains { $0.id == model.id })
        #expect(!model.provider.isEmpty)

        // provider 可解析：至少一个 ProviderType 的 builtInModels 包含该模型
        let resolvable = ProviderType.allCases.contains {
            $0.builtInModels.contains { $0.id == model.id }
        }
        #expect(resolvable, "默认模型 \(model.id) 的 provider 必须可解析")
    }

    /// 每档位下必须有可选模型（映射表非空）。
    @Test(arguments: ModelSpeedTier.allCases)
    func eachTierHasSelectableModels(_ tier: ModelSpeedTier) {
        #expect(!tier.models().isEmpty, "档位「\(tier.displayName)」下应有可选模型")
    }

    /// 已知模型 → 档位映射（按模型实际速度）。
    @Test func knownModelTierMapping() {
        #expect(ModelSpeedTier.tier(forModelID: "deepseek-chat") == .fast)
        #expect(ModelSpeedTier.tier(forModelID: "qwen-turbo-latest") == .ultraFast)
        #expect(ModelSpeedTier.tier(forModelID: "qwen3.8-max-preview") == .balanced)
        #expect(ModelSpeedTier.tier(forModelID: "deepseek-reasoner") == .quality)
        #expect(ModelSpeedTier.tier(forModelID: "qwen3.7-max") == .quality)
        #expect(ModelSpeedTier.tier(forModelID: "qwen-plus-latest") == .fast)
        #expect(ModelSpeedTier.tier(forModelID: "不存在的模型") == nil)
    }

    /// 档位默认模型 ID 与模型目录一致（defaultModel 能命中 allModels）。
    @Test(arguments: ModelSpeedTier.allCases)
    func defaultModelIDResolvesInCatalog(_ tier: ModelSpeedTier) {
        let model = tier.defaultModel
        #expect(model?.id == tier.defaultModelID)
        #expect(LLMModel.allModels.contains { $0.id == tier.defaultModelID })
    }

    /// 档位文案（displayName / icon）齐全。
    @Test func tierPresentation() {
        #expect(ModelSpeedTier.ultraFast.displayName == "极快")
        #expect(ModelSpeedTier.fast.displayName == "快")
        #expect(ModelSpeedTier.balanced.displayName == "均衡")
        #expect(ModelSpeedTier.quality.displayName == "质量")
        #expect(ModelSpeedTier.allCases.map(\.icon).count == 4)
    }

    // MARK: - 持久化

    /// AppSettings 往返：modelSpeedTier 落盘 / 读回。
    @Test func speedTierPersistsInAppSettings() throws {
        var settings = AppSettings.defaults
        settings.general.modelSpeedTier = .quality
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.general.modelSpeedTier == .quality)
        #expect(decoded.general.modelSpeedTier != .balanced)
    }

    /// 旧 JSON（无 modelSpeedTier 字段）宽容解码 → 默认 .balanced。
    @Test func missingSpeedTierFallsBackToBalanced() throws {
        let json = #"{"settingsVersion":2,"general":{"appearance":"dark","language":"zh-Hans"}}"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(decoded.general.modelSpeedTier == .balanced)
        #expect(decoded.settingsVersion == 2)
    }

    /// v2 JSON 经 SettingsMigration 迁移到当前 schema，档位取宽容解码默认
    /// `.balanced`；UX-01 的新增字段由迁移补齐。
    @Test func migrationKeepsV2AndBackfillsSpeedTierByTolerantDecode() throws {
        let json = #"{"settingsVersion":2,"general":{"appearance":"dark","language":"zh-Hans"}}"#
        let result = try SettingsMigration.migrate(data: Data(json.utf8))
        #expect(result.settings.settingsVersion == AppSettings.currentVersion)
        #expect(result.migrated)
        #expect(result.settings.general.modelSpeedTier == .balanced)
    }
}
