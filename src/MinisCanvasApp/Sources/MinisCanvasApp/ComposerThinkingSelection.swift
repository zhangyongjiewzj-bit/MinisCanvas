import MinisCore

/// A requested level, not a claim that the selected provider accepts it.
/// Wire support remains owned by the provider; this projection uses only the
/// public catalog's declared bound and never copies a model mapping table.
enum ComposerThinkingSelection {
    /// 选项从请求映射表推导：只列映射表会写入请求体的档位；
    /// 没有映射的模型只给“模型默认”，不再列选了也无效的 7 档。
    static func options(modelID: String?) -> [ThinkingLevel?] {
        guard let modelID else { return [nil] }
        return [nil] + ThinkingLevelCatalog.requestableLevels(for: modelID).filter { level in
            guard let maximum = ThinkingLevelCatalog.declaredMaxLevel(for: modelID) else { return true }
            return level <= maximum
        }.map(Optional.some)
    }

    static func capturedLevel(_ requested: ThinkingLevel?, modelID: String?) -> ThinkingLevel? {
        guard let requested, let modelID,
              let maximum = ThinkingLevelCatalog.declaredMaxLevel(for: modelID) else { return requested }
        return min(requested, maximum)
    }

    /// 档位的中文名（输入框菜单、设置页、帮助文案共用）。
    static func label(_ level: ThinkingLevel) -> String {
        switch level {
        case .off: "关闭"
        case .low: "低"
        case .medium: "中"
        case .high: "高"
        case .xhigh: "更高"
        case .max: "最高"
        case .ultra: "极高"
        }
    }

    static func title(_ level: ThinkingLevel?) -> String {
        guard let level else { return "思考：模型默认" }
        return "思考：\(label(level))"
    }

    static func help(modelID: String?) -> String {
        let common = "选择本回合请求的思考强度；模型默认不发送档位参数。实际生效取决于模型与接口，未支持的请求可能被忽略。工作量和工具权限独立。"
        guard let modelID,
              let maximum = ThinkingLevelCatalog.declaredMaxLevel(for: modelID) else {
            return common + " 当前模型未声明目录上限。"
        }
        return common + " 当前目录上限：\(label(maximum))；切换模型时超过上限的请求按此上限捕获。"
    }
}
