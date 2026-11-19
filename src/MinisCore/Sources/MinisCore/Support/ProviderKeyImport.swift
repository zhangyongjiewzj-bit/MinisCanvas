import Foundation

/// 一条可导入的供应商 Key 候选。只含 API Key 与 Base URL，不含任何 OAuth 令牌。
/// `apiKey` 是密钥：界面只显示 `maskedKey`，写入走钥匙串，不进日志。
public struct ImportedProviderCredential: Equatable, Sendable, Identifiable {
    public let id: String
    /// 来源说明，如“环境变量 OPENAI_API_KEY”。
    public let sourceLabel: String
    /// 建议的凭据名（与内置预设同名时直接绑定该预设）。
    public let credentialName: String
    public let displayName: String
    public let baseURL: String?
    public let protocolType: ProviderWireProtocol
    /// 预设里的模型名；没有预设或预设不写死模型时为空，导入后用“获取模型列表”选择。
    public let modelNames: [String]
    public let apiKey: String

    public var maskedKey: String { ProviderKeyImport.maskedKey(apiKey) }

    public init(
        id: String,
        sourceLabel: String,
        credentialName: String,
        displayName: String,
        baseURL: String?,
        protocolType: ProviderWireProtocol,
        modelNames: [String],
        apiKey: String
    ) {
        self.id = id
        self.sourceLabel = sourceLabel
        self.credentialName = credentialName
        self.displayName = displayName
        self.baseURL = baseURL
        self.protocolType = protocolType
        self.modelNames = modelNames
        self.apiKey = apiKey
    }
}

/// 从环境变量，或用户用文件选择框指定的 Claude Code `settings.json` / Codex `auth.json`
/// 提取 API Key 和 Base URL。只读取这两类字段；OAuth 令牌（如 Codex auth.json 的 tokens）一律忽略。
public enum ProviderKeyImport {

    /// 环境变量名 → (预设, Base URL 变量名们)。
    private static let environmentTable: [(key: String, preset: ProviderPreset, baseURLKeys: [String])] = [
        ("ANTHROPIC_API_KEY", .anthropic, ["ANTHROPIC_BASE_URL"]),
        ("OPENAI_API_KEY", .openAI, ["OPENAI_BASE_URL", "OPENAI_API_BASE"]),
        ("DEEPSEEK_API_KEY", .deepSeek, []),
        ("OPENROUTER_API_KEY", .openRouter, []),
        ("GEMINI_API_KEY", .gemini, []),
        ("GOOGLE_API_KEY", .gemini, []),
        ("MOONSHOT_API_KEY", .kimi, []),
        ("ZHIPU_API_KEY", .zhipu, []),
        ("SILICONFLOW_API_KEY", .siliconFlow, []),
        ("DASHSCOPE_API_KEY", .dashScope, [])
    ]

    /// 掩码显示：保留前 3 位和后 4 位；太短的整体隐藏。
    public static func maskedKey(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 12 else { return String(repeating: "•", count: max(trimmed.count, 4)) }
        return String(trimmed.prefix(3)) + "••••" + String(trimmed.suffix(4))
    }

    /// 导入时会读取的全部环境变量名（Key 与 Base URL），用来只取这些变量，不碰其余环境。
    public static let environmentVariableNames: Set<String> = Set(
        environmentTable.flatMap { [$0.key] + $0.baseURLKeys })

    /// 合并 App 进程环境与登录 shell 快照：只保留已知变量名；同名时以登录 shell 的值为准。
    public static func mergedEnvironment(
        process: [String: String], loginShell: [String: String]
    ) -> [String: String] {
        var merged = process.filter { environmentVariableNames.contains($0.key) }
        for (name, value) in loginShell where environmentVariableNames.contains(name) { merged[name] = value }
        return merged
    }

    /// 识别常见环境变量（传入进程环境；空值和占位值忽略）。
    public static func fromEnvironment(_ environment: [String: String]) -> [ImportedProviderCredential] {
        var result: [ImportedProviderCredential] = []
        var seenKeys = Set<String>()
        for entry in environmentTable {
            guard let key = cleanKey(environment[entry.key]), seenKeys.insert(key).inserted else { continue }
            let baseURL = entry.baseURLKeys.lazy.compactMap { cleanURL(environment[$0]) }.first
            result.append(make(
                id: "env:" + entry.key,
                source: "环境变量 \(entry.key)",
                preset: entry.preset,
                baseURL: baseURL,
                apiKey: key
            ))
        }
        return result
    }

    /// Claude Code 的 `settings.json`：只读 `env` 里的 ANTHROPIC_API_KEY（以及网关场景的
    /// ANTHROPIC_AUTH_TOKEN）和 ANTHROPIC_BASE_URL。其余字段一律忽略。
    public static func fromClaudeCodeSettings(data: Data) -> [ImportedProviderCredential] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = object["env"] as? [String: Any] else { return [] }
        let strings = env.compactMapValues { $0 as? String }
        let baseURL = cleanURL(strings["ANTHROPIC_BASE_URL"])
        if let key = cleanKey(strings["ANTHROPIC_API_KEY"]) {
            return [make(id: "claude-code:ANTHROPIC_API_KEY", source: "Claude Code 配置 ANTHROPIC_API_KEY",
                         preset: .anthropic, baseURL: baseURL, apiKey: key)]
        }
        // 自建网关常用 ANTHROPIC_AUTH_TOKEN 放 Key；没有自定义地址时它可能是登录令牌，不导入。
        if baseURL != nil, let key = cleanKey(strings["ANTHROPIC_AUTH_TOKEN"]) {
            return [make(id: "claude-code:ANTHROPIC_AUTH_TOKEN", source: "Claude Code 配置 ANTHROPIC_AUTH_TOKEN（自定义网关）",
                         preset: .anthropic, baseURL: baseURL, apiKey: key)]
        }
        return []
    }

    /// Codex 的 `auth.json`：只读顶层 `OPENAI_API_KEY`。`tokens` 等 OAuth 内容不读取、不导入。
    /// Base URL 在 Codex 的 config.toml 里，这里不读，沿用 OpenAI 预设地址（导入后可在编辑表单改）。
    public static func fromCodexAuth(data: Data) -> [ImportedProviderCredential] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = cleanKey(object["OPENAI_API_KEY"] as? String) else { return [] }
        return [make(id: "codex:OPENAI_API_KEY", source: "Codex 配置 OPENAI_API_KEY",
                     preset: .openAI, baseURL: nil, apiKey: key)]
    }

    /// Codex 的 `config.toml`：只读顶层 `model_provider` 指向的 `[model_providers.<名字>]` 段里的
    /// `base_url`，其余字段一律不读。Codex 指向第三方网关时，用它让导入的 Key 发往正确的地址。
    public static func codexBaseURL(fromConfigTOML data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        func value(of line: String, key: String) -> String? {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0] == key else { return nil }
            let raw = parts[1].split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
            guard raw.count >= 2, let quote = raw.first, quote == "\"" || quote == "'", raw.last == quote else { return nil }
            return String(raw.dropFirst().dropLast())
        }
        var section = ""
        var providerName: String?
        var baseURLs: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                section = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                continue
            }
            if section.isEmpty, providerName == nil, let name = value(of: line, key: "model_provider") {
                providerName = name
            } else if section.hasPrefix("model_providers."), let url = value(of: line, key: "base_url") {
                let name = String(section.dropFirst("model_providers.".count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                baseURLs[name] = url
            }
        }
        guard let providerName, let url = baseURLs[providerName] else { return nil }
        return cleanURL(url)
    }

    /// auth.json 里的 `OPENAI_API_KEY` 只属于 OpenAI 官方地址；config.toml 指向其他地址时，
    /// 那个网关用的是它自己的 Key，官方 Key 不能绑到该地址上。
    public static func codexOpenAIKeyMayBind(toBaseURL baseURL: String) -> Bool {
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return false }
        return host == "api.openai.com"
    }

    private static func make(
        id: String, source: String, preset: ProviderPreset, baseURL: String?, apiKey: String
    ) -> ImportedProviderCredential {
        ImportedProviderCredential(
            id: id,
            sourceLabel: source,
            credentialName: preset.credentialName,
            displayName: preset.displayName,
            baseURL: baseURL ?? preset.baseURL,
            protocolType: preset.protocolType,
            modelNames: preset.modelNames,
            apiKey: apiKey
        )
    }

    /// 空值、过短和明显是占位的值不算 Key。
    private static func cleanKey(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), value.count >= 8 else { return nil }
        let lower = value.lowercased()
        let placeholders = ["your_api_key", "your-api-key", "<api_key>", "xxx", "changeme", "null", "none"]
        if placeholders.contains(where: { lower.contains($0) }) { return nil }
        return value
    }

    private static func cleanURL(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil else { return nil }
        return value
    }
}
