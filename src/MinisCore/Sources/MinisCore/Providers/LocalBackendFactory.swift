import Foundation

/// ProviderFactory 的 local 集成：把 LocalBackendConfig 接进注册制工厂。
///
/// 注册（或替换）`.local` 类型的 builder，使
/// `ProviderFactory.shared.makeProvider(for: config)` 在 config.providerType == .local 时
/// 返回一个指向本地后端（默认 Ollama）的 OpenAICompatibleProvider（包一层 LocalOpenAIProvider）。
///
/// 幂等：重复调用只是替换 builder。由 `LocalBackends.shared` 初始化时自动调用，
/// 也可在任何时候手动调用。
public enum LocalBackendFactory {
    public static func register() {
        ProviderFactory.shared.register(.local) { config in
            // 1. 显式 customBaseURL 优先；否则回退到 LocalBackends 的 Ollama OpenAI 兼容地址。
            let base: String
            if let custom = config.effectiveCustomBaseURL {
                base = custom
            } else {
                base = LocalBackends.shared.openAICompatibleBaseURL(for: .ollama)
                    ?? LocalBackends.shared.config(for: .ollama)?.baseURL
                    ?? "http://127.0.0.1:11434"
            }

            // 2. 本地后端通常无需鉴权；Ollama 的 /v1 路径由 appendV1Suffix 控制。
            let provider = OpenAICompatibleProvider(
                apiKey: config.effectiveAPIKey() ?? "",
                model: LLMModel(id: "local-model", displayName: "Local Model", provider: "Local"),
                customBaseURL: base,
                appendV1Suffix: config.appendV1Suffix
            )
            let baseURL = URL(string: base) ?? URL(string: "http://127.0.0.1:11434")!
            return LocalOpenAIProvider(wrapping: provider, baseURL: baseURL)
        }
    }
}
