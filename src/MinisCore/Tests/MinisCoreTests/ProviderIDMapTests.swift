import Testing
import Foundation
@testable import MinisCore

// MARK: - providerID ↔ ProviderType 映射（I8 P1-2）

@Suite("ProviderIDMap")
struct ProviderIDMapTests {

    /// 画布目录中出现的全部 providerID 都能解析到 ProviderType。
    @Test func canvasProviderIDsResolve() {
        #expect(ProviderIDMap.providerType(fromID: "bailian") == .dashScope)
        #expect(ProviderIDMap.providerType(fromID: "openai") == .openAI)
        #expect(ProviderIDMap.providerType(fromID: "claude") == .anthropic)
        #expect(ProviderIDMap.providerType(fromID: "anthropic") == .anthropic)
        #expect(ProviderIDMap.providerType(fromID: "gimage2") == .gimage2)
        #expect(ProviderIDMap.providerType(fromID: "kling") == .kling)
        #expect(ProviderIDMap.providerType(fromID: "jimeng") == .jimeng)
        #expect(ProviderIDMap.providerType(fromID: "ollama") == .local)
        #expect(ProviderIDMap.providerType(fromID: "comfyui-local") == .local)
        #expect(ProviderIDMap.providerType(fromID: "stable-diffusion-local") == .local)
        #expect(ProviderIDMap.providerType(fromID: "wan-local") == .local)
        #expect(ProviderIDMap.providerType(fromID: "local") == .local)
        #expect(ProviderIDMap.providerType(fromID: "openrouter") == .openRouter)
        #expect(ProviderIDMap.providerType(fromID: "gemini") == .gemini)
        #expect(ProviderIDMap.providerType(fromID: "openai-responses") == .openAIResponses)
    }

    /// 未知 ID → nil（不回退到 unsupported 哨兵）。
    @Test func unknownIDReturnsNil() {
        #expect(ProviderIDMap.providerType(fromID: "no-such-provider") == nil)
        #expect(ProviderIDMap.providerType(fromID: "") == nil)
        #expect(ProviderIDMap.providerType(fromID: "unsupported") == nil)
        #expect(ProviderIDMap.providerType(fromID: "DEEPSEEK_API_KEY_OLD") == nil)
        #expect(ProviderIDMap.canonicalProviderID(fromID: "deepseek-api-key") == nil)
    }

    /// Credential aliases from both package generations resolve to one stable
    /// provider identity, so persisted model/readiness records do not fork.
    @Test func deepSeekCredentialAliasesShareCanonicalIdentity() {
        let aliases = ["DEEPSEEK_API_KEY", "HERMES_CUSTOM_DEEPSEEK_API_KEY"]
        for alias in aliases {
            #expect(ProviderIDMap.providerType(fromID: alias) == .deepSeek)
            #expect(ProviderIDMap.canonicalProviderID(fromID: alias) == "deepseek")
        }
        #expect(Set(aliases.compactMap { ProviderIDMap.canonicalProviderID(fromID: $0) }).count == 1)
        #expect(ProviderIDMap.canonicalProviderID(fromID: "deepseek") == "deepseek")
    }

    /// 直接传 ProviderType rawValue（"openAI" / "dashScope"）也能解析（回退路径）。
    @Test func rawValueFallbackResolves() {
        #expect(ProviderIDMap.providerType(fromID: "openAI") == .openAI)
        #expect(ProviderIDMap.providerType(fromID: "dashScope") == .dashScope)
        #expect(ProviderIDMap.providerType(fromID: "anthropic") == .anthropic)
    }

    /// 反向：每个 ProviderType → 画布 ID；unsupported → nil。
    @Test func reverseMapping() {
        #expect(ProviderIDMap.providerID(from: .dashScope) == "bailian")
        #expect(ProviderIDMap.providerID(from: .openAI) == "openai")
        #expect(ProviderIDMap.providerID(from: .anthropic) == "claude")
        #expect(ProviderIDMap.providerID(from: .gimage2) == "gimage2")
        #expect(ProviderIDMap.providerID(from: .kling) == "kling")
        #expect(ProviderIDMap.providerID(from: .jimeng) == "jimeng")
        #expect(ProviderIDMap.providerID(from: .local) == "local")
        #expect(ProviderIDMap.providerID(from: .openRouter) == "openrouter")
        #expect(ProviderIDMap.providerID(from: .gemini) == "gemini")
        #expect(ProviderIDMap.providerID(from: .openAIResponses) == "openai-responses")
        #expect(ProviderIDMap.providerID(from: .unsupported) == nil)
    }

    /// 注册表完备性：ProviderFactory 每个注册的 ProviderType 都有画布 ID，
    /// 且往返一致（type → id → type）。
    @Test func everyRegisteredProviderRoundTrips() {
        let registered = ProviderFactory.shared.registeredTypes
        #expect(!registered.isEmpty)
        #expect(ProviderIDMap.validateRegistrationCoverage().isEmpty)

        for type in registered {
            guard let id = ProviderIDMap.providerID(from: type) else {
                Issue.record("注册的 ProviderType \(type.rawValue) 缺少画布 ID")
                continue
            }
            #expect(ProviderIDMap.providerType(fromID: id) == type,
                    "\(type.rawValue) → \(id) → 应为 \(type.rawValue)")
        }
    }

    /// 注册表驱动的 ID 列表：包含全部已注册 provider 的画布 ID。
    @Test func registeredProviderIDsCoverFactory() {
        let ids = Set(ProviderIDMap.registeredProviderIDs)
        for type in ProviderFactory.shared.registeredTypes {
            if let id = ProviderIDMap.providerID(from: type) {
                #expect(ids.contains(id), "注册表列表缺少 \(type.rawValue) 的 ID \(id)")
            }
        }
        // 画布常用目录 ID 必须出现（bailian/openai/gimage2/kling/jimeng 已注册）
        #expect(ids.contains("bailian"))
        #expect(ids.contains("openai"))
        #expect(ids.contains("gimage2"))
        #expect(ids.contains("kling"))
        #expect(ids.contains("jimeng"))
    }
}
