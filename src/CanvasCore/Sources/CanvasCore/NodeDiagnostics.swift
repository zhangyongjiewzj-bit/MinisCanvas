import Foundation

// MARK: - 节点失败诊断上下文（D4 节点↔Agent 联动桥）

/// 节点失败诊断上下文：从执行失败现场收集，供 Agent 修复桥使用。
///
/// 输入值一律转成**脱敏文本描述**（见 `NodeDiagnostics`）：敏感字段（API key 类）
/// 不进入上下文，长文本截断，避免把密钥或超长内容透传给外部 LLM。
/// 注：与加法建议中的 `inputs: [String: Any]` 相比，这里用 `[String: String]`
/// 描述文本——既满足脱敏要求，又保证 `Sendable` 可跨 actor 传递。
public struct NodeDiagnosticContext: Sendable, Equatable {
    /// 失败节点 ID
    public let nodeID: UUID
    /// 失败节点类型（如 "llm" / "imageGen" / "blenderPreview"）
    public let nodeType: String
    /// 失败节点标题（画布上用户可见的名称）
    public let nodeTitle: String
    /// 失败错误描述（`error.localizedDescription` 或 `String(describing:)`）
    public let errorDescription: String
    /// 脱敏后的节点输入（端口名 → 文本描述）；敏感字段已被剔除
    public let inputs: [String: String]
    /// 上游输出端口 key（按字典序排序，供 LLM 判断数据依赖）
    public let upstreamOutputKeys: [String]

    public init(
        nodeID: UUID,
        nodeType: String,
        nodeTitle: String,
        errorDescription: String,
        inputs: [String: String],
        upstreamOutputKeys: [String]
    ) {
        self.nodeID = nodeID
        self.nodeType = nodeType
        self.nodeTitle = nodeTitle
        self.errorDescription = errorDescription
        self.inputs = inputs
        self.upstreamOutputKeys = upstreamOutputKeys
    }
}

// MARK: - 诊断上下文收集器

/// 诊断上下文收集器：纯静态函数，无状态，可在执行失败现场直接调用。
public enum NodeDiagnostics {

    /// 单个输入值的最大描述长度（超长截断，避免撑爆 LLM 上下文）
    public static let maxValueDescriptionLength = 800

    /// 敏感字段子串（大小写不敏感）：键名命中任一子串即从诊断中剔除。
    /// 覆盖常见 API key / 密钥 / 口令命名习惯。
    public static let sensitiveKeySubstrings: [String] = [
        "apikey", "api_key", "secret", "token",
        "password", "passwd", "credential", "authorization", "auth",
    ]

    /// 判断输入端口名是否为敏感字段（大小写不敏感子串匹配）。
    public static func isSensitiveKey(_ key: String) -> Bool {
        let lower = key.lowercased()
        return sensitiveKeySubstrings.contains { lower.contains($0) }
    }

    /// 把输入值转为脱敏文本描述：String 原样返回，其他类型用 `String(describing:)`；
    /// 超长统一截断并标注原始长度。
    public static func describeValue(_ value: Any) -> String {
        let text: String
        if let str = value as? String {
            text = str
        } else {
            text = String(describing: value)
        }
        guard text.count > maxValueDescriptionLength else { return text }
        let prefix = text.prefix(maxValueDescriptionLength)
        return "\(prefix)…（已截断，原始 \(text.count) 字符）"
    }

    /// 从执行失败现场收集诊断上下文（节点 + 错误 + 输入 + 上游输出端口）。
    /// - Parameters:
    ///   - node: 失败节点
    ///   - error: 执行抛出的错误
    ///   - inputs: `resolveInputs` 解析出的输入（端口名 → 值）；敏感字段会被剔除
    ///   - upstreamOutputKeys: 上游节点已产出输出的端口 key 列表（用于判断数据依赖）
    public static func collectDiagnostic(
        from node: CanvasNode,
        error: any Error,
        inputs: [String: AnyHashable]?,
        upstreamOutputKeys: [String] = []
    ) -> NodeDiagnosticContext {
        collectDiagnostic(
            nodeID: node.id,
            nodeType: node.type,
            nodeTitle: node.title,
            error: error,
            inputs: inputs,
            upstreamOutputKeys: upstreamOutputKeys
        )
    }

    /// 底层收集实现：接受显式节点信息（便于脱离 `CanvasNode` 现场复用）。
    public static func collectDiagnostic(
        nodeID: UUID,
        nodeType: String,
        nodeTitle: String,
        error: any Error,
        inputs: [String: AnyHashable]?,
        upstreamOutputKeys: [String] = []
    ) -> NodeDiagnosticContext {
        let errorDescription = (error as? LocalizedError)?.errorDescription
            ?? String(describing: error)

        var sanitized: [String: String] = [:]
        for (key, value) in inputs ?? [:] where !isSensitiveKey(key) {
            sanitized[key] = describeValue(value)
        }

        return NodeDiagnosticContext(
            nodeID: nodeID,
            nodeType: nodeType,
            nodeTitle: nodeTitle,
            errorDescription: errorDescription,
            inputs: sanitized,
            upstreamOutputKeys: upstreamOutputKeys.sorted()
        )
    }
}
