import Foundation
import Testing
@testable import MinisCore

/// V424-K15: legacy/current DeepSeek environment names must converge to one
/// provider record while user-selected and newly discovered model IDs survive.
@Suite("ProviderConfig DeepSeek aliases")
struct ProviderConfigDeepSeekAliasTests {
    private func decodeConfig(providerType: String, apiKeyEnvVar: String? = nil) throws -> ProviderConfig {
        var fields = [
            "\"id\":\"fixture-\(providerType)\"",
            "\"label\":\"DeepSeek\"",
            "\"providerType\":\"\(providerType)\"",
            "\"credentialType\":\"apiKey\"",
            "\"isEnabled\":true",
            "\"createdAt\":0",
            "\"appendV1Suffix\":true",
        ]
        if let apiKeyEnvVar {
            fields.append("\"apiKeyEnvVar\":\"\(apiKeyEnvVar)\"")
        }
        let json = "{" + fields.joined(separator: ",") + "}"
        return try JSONDecoder().decode(ProviderConfig.self, from: Data(json.utf8))
    }

    @Test func legacyAndCurrentAliasesDecodeToDeepSeek() throws {
        let legacy = try decodeConfig(providerType: "HERMES_CUSTOM_DEEPSEEK_API_KEY")
        let current = try decodeConfig(providerType: "DEEPSEEK_API_KEY")

        #expect(legacy.providerType == .deepSeek)
        #expect(current.providerType == .deepSeek)
        #expect(legacy.apiKeyEnvVar == "HERMES_CUSTOM_DEEPSEEK_API_KEY")
        #expect(current.apiKeyEnvVar == "DEEPSEEK_API_KEY")
        #expect(legacy.canonicalProviderRecordKey == current.canonicalProviderRecordKey)
        #expect(ProviderConfig.canonicalProviderType(from: "DEEPSEEK_API_KEY") == .deepSeek)
        #expect(ProviderConfig.canonicalProviderType(from: "unknown-provider") == .unsupported)
    }

    @Test func aliasRecordsMergeWithoutDroppingReadinessOrCredentialSource() throws {
        var legacy = try decodeConfig(providerType: "HERMES_CUSTOM_DEEPSEEK_API_KEY")
        legacy.isEnabled = false
        let current = ProviderConfig(
            id: "fixture-current",
            label: "DeepSeek V4",
            providerType: .deepSeek,
            isEnabled: true,
            apiKeyEnvVar: "DEEPSEEK_API_KEY",
            apiKey: "fixture-runtime-key"
        )

        let merged = ProviderConfig.mergeCanonical([legacy, current])
        #expect(merged.count == 1)
        #expect(merged[0].providerType == .deepSeek)
        #expect(merged[0].isEnabled)
        #expect(merged[0].apiKey == "fixture-runtime-key")
        // Hermes is resolved first by DeepSeekProvider, so merging retains the
        // legacy source instead of pointing an old install at an absent key.
        #expect(merged[0].apiKeyEnvVar == "HERMES_CUSTOM_DEEPSEEK_API_KEY")
        #expect(ProviderConfig.canonicalEnvironmentVariable(merged[0].apiKeyEnvVar) == "DEEPSEEK_API_KEY")
    }

    @Test func selectedV4AndUnknownModelsRemainCodable() throws {
        let selected = ModelEntry(
            uuid: "fixture-v4",
            providerInstanceId: "deepseek",
            model: .deepSeekV4Flash,
            isCustom: true
        )
        let unknown = ModelEntry(
            uuid: "fixture-unknown",
            providerInstanceId: "deepseek",
            model: LLMModel(
                id: "deepseek-v4-future-preview",
                displayName: "DeepSeek future preview",
                provider: "DeepSeek"
            ),
            isCustom: true
        )

        let decoded = try [selected, unknown].flatMap { entry -> [ModelEntry] in
            let data = try JSONEncoder().encode(entry)
            return [try JSONDecoder().decode(ModelEntry.self, from: data)]
        }
        #expect(decoded.map(\.model.id) == ["deepseek-v4-flash", "deepseek-v4-future-preview"])
        #expect(Set(decoded.map(\.model.id)).count == 2)
        let allEntriesAreUserModified = decoded.allSatisfy { entry in
            entry.isUserModified
        }
        #expect(allEntriesAreUserModified)
    }
}
