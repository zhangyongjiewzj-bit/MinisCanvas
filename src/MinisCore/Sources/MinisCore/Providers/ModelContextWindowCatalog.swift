import Foundation

/// 内置模型上下文窗口目录（C6）。`LLMModel.contextWindowTokens` 的唯一来源：
/// 显式 `contextWindow` > 本目录 > 128,000。生产构造点只传 id/displayName/provider，
/// 所以窗口必须在这里按 id 解析。
///
/// 出处：
/// - gpt-4.1 系 = 1,047,576：用户/审计 D-04 指定，官方出处未核实。
/// - Claude 1M 模型与 Haiku 4.5 = 200k：platform.claude.com/docs/en/build-with-claude/context-windows
///   “Context window sizes by model”（2026-11-09 读取）。该页未列出的 Claude ID 属 200k 家族。
/// - 其余数值沿用 LLMTypes 原启发式，官方出处未核实。
/// - qwen-long / glm / kimi / deepseek 为常见长上下文模型的近似值，目录无命中时界面会标注“估计值”。
public enum ModelContextWindowCatalog {
    private static let exact: [String: Int] = [
        "claude-fable-5": 1_000_000,
        "claude-opus-5": 1_000_000,
        "claude-opus-5-5": 1_000_000,
        "claude-opus-4-8": 1_000_000,
        "claude-opus-4-6": 1_000_000,
        "claude-sonnet-5": 1_000_000,
        "claude-sonnet-5-5": 1_000_000,
        "claude-sonnet-4-6": 1_000_000,
        "claude-haiku-4-5": 200_000,
        "gpt-4.1": 1_047_576,
    ]

    /// (前缀, 窗口, 版本点是否仍属本家族)。按顺序匹配；前缀后必须是结尾或 “-”（或 “.”，当其为真）。
    private static let families: [(prefix: String, window: Int, dotContinues: Bool)] = [
        ("gpt-3.5", 16_000, true),
        ("gpt-4.1", 1_047_576, false),
        ("gpt-4o", 128_000, false),
        ("gpt-4-turbo", 128_000, false),
        ("gpt-5", 400_000, true),
        ("gpt-4", 8_000, false),
        ("o3", 200_000, false),
        ("o4", 200_000, false),
        ("codex", 200_000, false),
        // 常见国产长上下文模型（数值为各家公开资料的近似值，出处未逐项核实；
        // 不准时用户可在“编辑模型”里手动填写窗口）。更具体的前缀放在前面。
        ("qwen-long", 10_000_000, false),
        ("glm-4-long", 1_000_000, false),
        ("glm-4.6", 200_000, false),
        ("glm", 128_000, false),
        ("kimi", 256_000, false),
        ("deepseek", 128_000, false),
    ]

    /// 精确项或家族规则命中时返回窗口；没有任何命中返回 nil（调用方用 128,000 兜底）。
    public static func window(forModelID id: String) -> Int? {
        let name = normalised(id)
        if let value = exact[name] { return value }
        if name.hasPrefix("claude") { return 200_000 }
        if name.hasPrefix("gemini") { return name.hasPrefix("gemini-1.0") ? 32_000 : 1_000_000 }
        return families.first { family in
            guard name.hasPrefix(family.prefix) else { return false }
            guard let next = name.dropFirst(family.prefix.count).first else { return true }
            return next == "-" || (family.dotContinues && next == ".")
        }?.window
    }

    /// 该模型实际用的是 128,000 兜底：没有显式窗口（`contextWindow` 缺失或非正）且目录无命中。
    /// 与 `LLMModel.contextWindowTokens` 的解析顺序一致；家族规则命中不算兜底。
    public static func usesFallbackWindow(explicitWindow: Int?, modelID: String) -> Bool {
        if let explicitWindow, explicitWindow > 0 { return false }
        return window(forModelID: modelID) == nil
    }

    private static func normalised(_ id: String) -> String {
        let lower = id.lowercased()
        guard let slash = lower.lastIndex(of: "/") else { return lower }
        return String(lower[lower.index(after: slash)...])
    }
}
