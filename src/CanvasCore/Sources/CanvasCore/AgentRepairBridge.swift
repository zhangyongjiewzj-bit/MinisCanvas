import Foundation

// MARK: - 修复建议

/// Agent 修复建议：节点失败后由 Agent 给出的可执行修复方案。
public struct RepairSuggestion: Sendable, Equatable, Codable {
    /// 建议的修复内容（自然语言描述或可直接执行的修改说明）
    public var suggestedFix: String
    /// 置信度 0...1；0 表示无法解析/无把握（fallback 场景）
    public var confidence: Double
    /// 建议更新的节点参数（端口名/参数名 → 新值）；nil = 无参数改动
    public var updatedParams: [String: String]?
    /// 修复理由/解释
    public var explanation: String

    public init(
        suggestedFix: String,
        confidence: Double,
        updatedParams: [String: String]? = nil,
        explanation: String = ""
    ) {
        self.suggestedFix = suggestedFix
        self.confidence = confidence
        self.updatedParams = updatedParams
        self.explanation = explanation
    }

    /// 宽松解码：LLM 输出可能缺字段，缺省用安全默认值，避免整条建议作废。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        suggestedFix = try c.decode(String.self, forKey: .suggestedFix)
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
        updatedParams = try c.decodeIfPresent([String: String].self, forKey: .updatedParams)
        explanation = try c.decodeIfPresent(String.self, forKey: .explanation) ?? ""
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(suggestedFix, forKey: .suggestedFix)
        try c.encode(confidence, forKey: .confidence)
        try c.encodeIfPresent(updatedParams, forKey: .updatedParams)
        try c.encode(explanation, forKey: .explanation)
    }

    private enum CodingKeys: String, CodingKey {
        case suggestedFix
        case confidence
        case updatedParams
        case explanation
    }
}

// MARK: - 修复提供方协议

/// Agent 修复提供方：输入失败诊断上下文，输出修复建议。
/// 真实实现（LLM）见 `AgentRepairProviderLLM`；测试可注入 mock。
public protocol AgentRepairProvider: Sendable {
    /// 依据诊断上下文产出修复建议。
    /// - Parameter diagnostic: 节点失败诊断上下文（已脱敏）
    func repair(diagnostic: NodeDiagnosticContext) async throws -> RepairSuggestion
}

// MARK: - 默认 LLM 实现

/// 默认修复提供方：把诊断上下文拼进 system prompt，调注入的 `LLMInvoker`
/// （复用 NodeExecutors 的 LLM 注入点，真实调用由上层提供）出修复建议。
///
/// LLM 输出约定为 JSON（`RepairSuggestion` 结构）；解析失败时退回
/// `confidence = 0` 的原样文本建议（fallback，不丢信息）。
public struct AgentRepairProviderLLM: AgentRepairProvider, Sendable {

    /// 注入的 LLM 调用器（复用 NodeExecutors.LLMInvoker）
    public let llmInvoker: any LLMInvoker
    /// 修复桥使用的模型配置（默认空配置，由上层全局默认兜底）
    public let backend: NodeBackendConfig

    public init(
        llmInvoker: any LLMInvoker,
        backend: NodeBackendConfig = NodeBackendConfig()
    ) {
        self.llmInvoker = llmInvoker
        self.backend = backend
    }

    public func repair(diagnostic: NodeDiagnosticContext) async throws -> RepairSuggestion {
        let prompt = Self.buildSystemPrompt(diagnostic: diagnostic)
        let text = try await llmInvoker.invoke(prompt: prompt, backend: backend)
        if let parsed = Self.parseSuggestion(from: text) {
            return parsed
        }
        // fallback：无法解析 JSON 时原样保留 LLM 输出，置信度 0
        return RepairSuggestion(
            suggestedFix: text,
            confidence: 0,
            updatedParams: nil,
            explanation: "LLM 未返回可解析的 JSON，原样保留输出"
        )
    }

    /// 组装修复提示词：节点类型 + 标题 + 错误 + 脱敏输入 + 上游端口，要求 LLM 输出 JSON。
    public static func buildSystemPrompt(diagnostic: NodeDiagnosticContext) -> String {
        var lines = [
            "你是漫剧画布上的节点修复 Agent。根据失败节点的诊断信息，给出可执行的修复建议。",
            "",
            "节点类型: \(diagnostic.nodeType)",
            "节点标题: \(diagnostic.nodeTitle)",
            "错误: \(diagnostic.errorDescription)",
            "",
        ]
        let sortedInputs = diagnostic.inputs.sorted { $0.key < $1.key }
        if sortedInputs.isEmpty {
            lines.append("节点输入（脱敏）: （无）")
        } else {
            lines.append("节点输入（脱敏）:")
            for (name, value) in sortedInputs {
                lines.append("  \(name): \(value)")
            }
        }
        if diagnostic.upstreamOutputKeys.isEmpty {
            lines.append("上游输出端口: （无）")
        } else {
            lines.append("上游输出端口: \(diagnostic.upstreamOutputKeys.joined(separator: ", "))")
        }
        lines.append("")
        lines.append("只输出一个 JSON 对象，不要输出其他内容，格式如下：")
        lines.append(#"{"suggestedFix": "修复内容", "confidence": 0.8, "updatedParams": {"端口名": "新值"}, "explanation": "修复理由"}"#)
        return lines.joined(separator: "\n")
    }

    /// 从 LLM 输出解析 `RepairSuggestion`：容忍 ```json 代码围栏与前后杂讯，
    /// 取第一个 `{` 到最后一个 `}` 之间的内容解码；失败返回 nil。
    public static func parseSuggestion(from text: String) -> RepairSuggestion? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end else { return nil }
        let json = String(text[start...end])
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RepairSuggestion.self, from: data)
    }
}

// MARK: - 联动桥（接线）

/// 节点↔Agent 联动桥：独立 API，供上层（GraphExecutionContext / UI）在节点
/// 失败路径调用。**不改 NodeExecutors 内部逻辑**——执行器是值类型 struct，
/// 无法持有 weak 引用，因此以「失败现场收集 + 注入 provider」的独立 API 形态提供。
///
/// 上层接线示例（DAGScheduler 失败路径之外，由调用方自行编排）：
/// ```swift
/// // 节点失败时（如 GraphExecutionContext 捕获到 executor 抛错）：
/// if let suggestion = await AgentRepairBridge.diagnoseAndRepair(
///     node: node, error: error, inputs: inputs,
///     provider: repairProvider   // nil = 未配置桥，安全返回 nil
/// ) {
///     // 记录建议 / 回填画布（updatedParams 等）
/// }
/// ```
public enum AgentRepairBridge {

    /// 顶层独立 API：从失败现场收集诊断上下文 → 交给 provider 出修复建议。
    /// - Throws: 收集不抛错；provider 内部错误（如 LLM 调用失败）原样透传
    public static func diagnoseAndRepair(
        node: CanvasNode,
        error: any Error,
        inputs: [String: AnyHashable]?,
        upstreamOutputKeys: [String] = [],
        provider: any AgentRepairProvider
    ) async throws -> RepairSuggestion {
        let diagnostic = NodeDiagnostics.collectDiagnostic(
            from: node, error: error, inputs: inputs, upstreamOutputKeys: upstreamOutputKeys
        )
        return try await provider.repair(diagnostic: diagnostic)
    }

    /// 已收集上下文版本的顶层 API（spec 形态：`diagnoseAndRepair(context:provider:)`）。
    public static func diagnoseAndRepair(
        context: NodeDiagnosticContext,
        provider: any AgentRepairProvider
    ) async throws -> RepairSuggestion {
        try await provider.repair(diagnostic: context)
    }

    /// 安全变体：`provider` 为 nil（未配置修复桥）时直接返回 nil，不崩不抛；
    /// 内部错误（LLM 调用失败等）也吞掉，适合上层 fire-and-forget 记录建议。
    public static func diagnoseAndRepairIfAvailable(
        node: CanvasNode,
        error: any Error,
        inputs: [String: AnyHashable]?,
        upstreamOutputKeys: [String] = [],
        provider: (any AgentRepairProvider)?
    ) async -> RepairSuggestion? {
        guard let provider else { return nil }
        return try? await diagnoseAndRepair(
            node: node, error: error, inputs: inputs,
            upstreamOutputKeys: upstreamOutputKeys, provider: provider
        )
    }
}
