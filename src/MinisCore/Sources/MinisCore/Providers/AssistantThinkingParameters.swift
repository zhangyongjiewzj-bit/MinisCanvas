import Foundation

/// Request-only mapping, verified against official documentation on 2026-10-22.
/// Deliberately exact IDs: an arbitrary custom model name is not capability evidence.
/// Sources and staged call-chain limitations are in CHILD_MODEL_BINDING_变更说明.md.
enum ThinkingParameterApplication: Sendable, Equatable {
    case written
    case notRequested
    case ignored(String)
}

/// Per-child request-body facts only; no payload, credentials or persistence.
final class ThinkingParameterApplicationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [ThinkingParameterApplication] = []
    func record(_ result: ThinkingParameterApplication) { lock.withLock { results.append(result) } }
    var presentation: String {
        let snapshot = lock.withLock { results }
        let reasons = snapshot.compactMap { if case .ignored(let reason) = $0 { return reason }; return nil }
        if !reasons.isEmpty {
            let reason = Array(Set(reasons)).sorted().joined(separator: "；")
            return snapshot.contains(.written) ? "部分请求档位未生效（\(reason)）" : "档位未生效（\(reason)）"
        }
        return snapshot.contains(.written) ? "档位参数已写入请求体" : "档位未生效（provider未提供请求体档位回执）"
    }
}

enum AssistantThinkingParameters {
    @TaskLocal static var reportApplication: (@Sendable (ThinkingParameterApplication) -> Void)?
    enum Wire { case openAIChat, openAIResponses, anthropic }

    @discardableResult
    static func apply(_ level: ThinkingLevel?, modelID: String, wire: Wire,
                      body: inout [String: Any],
                      report applicationReport: (@Sendable (ThinkingParameterApplication) -> Void)? = nil) -> ThinkingParameterApplication {
        func report(_ result: ThinkingParameterApplication) -> ThinkingParameterApplication {
            (applicationReport ?? reportApplication)?(result)
            return result
        }
        guard let level else { return .notRequested }
        switch wire {
        case .openAIChat, .openAIResponses:
            let deepSeekIDs: Set<String> = ["deepseek-flash", "deepseek-v4-flash",
                "deepseek-v4-flash-vision-exp", "deepseek-v4-pro"]
            if deepSeekIDs.contains(modelID) {
                let effort: String
                switch level {
                case .off:
                    // Do not infer a Responses off value from the Chat toggle;
                    // leave this optional setting pending verification.
                    if wire == .openAIChat {
                        body["thinking"] = ["type": "disabled"]
                        return report(.written)
                    }
                    return report(.ignored("DeepSeek Responses关闭档位未确认"))
                case .low: effort = "low"
                case .medium, .high, .xhigh: effort = "high"
                case .max, .ultra: effort = "max"
                }
                if wire == .openAIResponses {
                    body["reasoning"] = ["effort": effort]
                } else {
                    body["thinking"] = ["type": "enabled"]
                    body["reasoning_effort"] = effort
                }
                body.removeValue(forKey: "temperature")
                return report(.written)
            }
            let supportsNone: Bool
            let maximum: ThinkingLevel
            switch modelID {
            case "gpt-5.2", "gpt-5.2-2025-12-11", "gpt-5.5", "gpt-5.5-2026-04-23":
                supportsNone = true; maximum = .xhigh
            case "gpt-6.1-sol":
                supportsNone = false; maximum = .max
                if wire == .openAIChat, (body["tools"] as? [[String: Any]])?.isEmpty == false {
                    return report(.ignored("gpt-6.1-sol Chat带工具不支持该思考参数组合"))
                }
            default: return report(.ignored("模型ID未声明思考参数映射"))
            }
            if level == .off, !supportsNone {
                return report(.ignored("该模型不支持关闭思考"))
            }
            let effort = level == .off ? "none" : min(level, maximum).rawValue
            if wire == .openAIResponses { body["reasoning"] = ["effort": effort] }
            else { body["reasoning_effort"] = effort }
            // Reasoning-enabled OpenAI requests cannot use custom temperature.
            if level != .off { body.removeValue(forKey: "temperature") }
            return report(.written)
        case .anthropic:
            let adaptive: Set<String> = ["claude-opus-4-6", "claude-sonnet-4-6",
                "claude-opus-4-7", "claude-opus-4-8", "claude-opus-5", "claude-opus-5-5",
                "claude-sonnet-5", "claude-sonnet-5-5", "claude-haiku-5-5"]
            let manual: Set<String> = ["claude-opus-4-5", "claude-opus-4-5-20251101",
                "claude-sonnet-4-5",
                "claude-haiku-4-5"]
            guard adaptive.contains(modelID) || manual.contains(modelID) else {
                return report(.ignored("模型ID未声明思考参数映射"))
            }
            if level == .off {
                if modelID == "claude-opus-5-5" {
                    return report(.ignored("该模型不支持关闭思考"))
                }
                body["thinking"] = ["type": modelID == "claude-sonnet-5-5" ? "between_tools" : "disabled"]
                return report(.written)
            }
            if adaptive.contains(modelID) {
                body.removeValue(forKey: "temperature")
                let maximum: ThinkingLevel = .max
                let effort = (level == .xhigh && (modelID == "claude-sonnet-4-6" || modelID == "claude-opus-4-6"))
                    ? "high" : min(level, maximum).rawValue
                body["thinking"] = ["type": "adaptive"]
                body["output_config"] = ["effort": effort]
            } else {
                // Manual budgets are app policy, not named Anthropic effort levels.
                let requestedBudget: Int = switch level {
                case .off: 0
                case .low: 1_024
                case .medium: 2_048
                case .high: 4_096
                case .xhigh: 8_192
                case .max, .ultra: 16_384
                }
                let budget = min(requestedBudget, (body["max_tokens"] as? Int ?? 0) - 1)
                guard budget >= 1_024 else {
                    return report(.ignored("输出上限放不下最小手动思考预算"))
                }
                body.removeValue(forKey: "temperature")
                body["thinking"] = ["type": "enabled", "budget_tokens": budget]
            }
            return report(.written)
        }
    }
}
