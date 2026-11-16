import MinisCore

/// A requested level, not a claim that the selected provider accepts it.
/// Wire support remains owned by the provider; this projection uses only the
/// public catalog's declared bound and never copies a model mapping table.
enum ComposerThinkingSelection {
    static func options(modelID: String?) -> [ThinkingLevel?] {
        [nil] + ThinkingLevel.allCases.filter { level in
            guard let modelID,
                  let maximum = ThinkingLevelCatalog.declaredMaxLevel(for: modelID) else { return true }
            return level <= maximum
        }.map(Optional.some)
    }

    static func capturedLevel(_ requested: ThinkingLevel?, modelID: String?) -> ThinkingLevel? {
        guard let requested, let modelID,
              let maximum = ThinkingLevelCatalog.declaredMaxLevel(for: modelID) else { return requested }
        return min(requested, maximum)
    }

    static func title(_ level: ThinkingLevel?) -> String {
        guard let level else { return "思考：模型默认" }
        let label: String = switch level {
        case .off: "关闭"
        case .low: "低"
        case .medium: "中"
        case .high: "高"
        case .xhigh: "更高"
        case .max: "最高"
        case .ultra: "极高"
        }
        return "思考：\(label)"
    }

    static func help(modelID: String?) -> String {
        let common = "选择本回合请求的思考强度；模型默认不发送档位参数。实际生效取决于模型与接口，未支持的请求可能被忽略。工作量和工具权限独立。"
        guard let modelID,
              let maximum = ThinkingLevelCatalog.declaredMaxLevel(for: modelID) else {
            return common + " 当前模型未声明目录上限。"
        }
        return common + " 当前目录上限：\(maximum.displayName)；切换模型时超过上限的请求按此上限捕获。"
    }
}
