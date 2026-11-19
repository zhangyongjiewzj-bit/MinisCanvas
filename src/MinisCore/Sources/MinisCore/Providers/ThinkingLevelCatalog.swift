/// Declared reasoning limits for model IDs with a verified catalog bound.
/// An undeclared ID returns `nil`; callers apply their own fallback.
public enum ThinkingLevelCatalog {
    public static func declaredMaxLevel(for modelID: String) -> ThinkingLevel? {
        modelID.lowercased().hasPrefix("claude-opus-4") ? .max : nil
    }

    /// 档位选项直接从请求映射表推导：只有映射表真正会写入请求体的档位才可选。
    /// 映射表没有声明的模型返回空数组（界面只显示“模型默认”），避免列出选了也无效的档位。
    public static func requestableLevels(for modelID: String) -> [ThinkingLevel] {
        let id = modelID.lowercased()
        return ThinkingLevel.allCases.filter { level in
            [AssistantThinkingParameters.Wire.openAIChat, .openAIResponses, .anthropic].contains { wire in
                var body: [String: Any] = ["max_tokens": 32_768, "temperature": 1.0]
                let result = AssistantThinkingParameters.apply(level, modelID: id, wire: wire, body: &body, report: { _ in })
                if case .written = result { return true }
                return false
            }
        }
    }
}
