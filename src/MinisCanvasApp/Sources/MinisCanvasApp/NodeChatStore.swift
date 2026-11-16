import Foundation
import Observation
import CanvasCore
import MinisCore

// MARK: - U2-r 节点级模型对话（与 agent 聊天完全隔离）
//
// 预留：节点×LLM 已前台下线（AJ-74），接口保留待后续恢复。
//（NodeChat 面板入口已在前台禁用/隐藏，本文件全部逻辑不删；恢复时移除 NodeChatPanelView
//  的下线占位分支即可，NodeChatStore / MinisCanvasNodeChatClient / provider 路由原样可用。）
//
// 需求：点哪个节点 → 右侧上下文面板切到该节点模型的独立对话窗口。
// 隔离方式：
//   - 独立 store（NodeChatStore），历史按 nodeID 分区：nodeChats[nodeID]，
//     与 ChatStore（agent 对话）互不读写。
//   - 独立消息模型 NodeChatMessage（user/assistant），不复用 ChatMessageUI。
//   - 发送走该节点 backendConfig 的 provider/model（复用 MinisCanvasLLMInvoker
//     同一条 MinisCore Provider 链：DashScope / OpenAI 兼容 / DeepSeek）。

/// 节点级模型对话消息（独立于 agent 的 ChatMessageUI）
struct NodeChatMessage: Identifiable, Equatable, Sendable {
    enum Role: String, Sendable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    var content: String
    let timestamp: Date

    init(id: UUID = UUID(), role: Role, content: String, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}

/// 节点对话配置状态：决定输入框是否可用 + 内联提示文案。
enum NodeChatConfigStatus: Equatable, Sendable {
    static let noModelHint = "该节点未配置模型，请先点击节点设置模型"

    /// 可发送（已配置 LLM provider + key）
    case ready
    /// 未配置模型：backendConfig 为 nil 或 providerID 为空
    case noModel
    /// 已选模型但未配置 API key
    case noKey
    /// 所选 provider 不可用于 LLM 对话（如 kling/gimage2 或未接入的 providerID）
    case unsupported

    var isReady: Bool { self == .ready }

    /// 内联提示文案（输入框禁用时展示）
    var hint: String {
        switch self {
        case .ready:
            return ""
        case .noModel:
            return Self.noModelHint
        case .noKey:
            return "该节点模型未配置 API Key：请在设置中配置，或检查环境变量（DASHSCOPE_API_KEY / OPENAI_API_KEY / DEEPSEEK_API_KEY）后重启应用"
        case .unsupported:
            return "该节点模型不可用于对话（仅生图/生视频等，或 Provider 未接入）"
        }
    }
}

/// 节点对话 LLM 客户端抽象（可注入 mock 测试）。
/// MainActor 隔离：节点对话只在主线程驱动（NodeChatStore 亦为 @MainActor），
/// 网络 await 不阻塞主线程；避免跨隔离区 conformance 与锁竞争。
@MainActor
protocol NodeChatLLMClient: Sendable {
    /// 发送多轮对话历史，返回模型回复文本。
    /// 未配置模型 / provider 未接入 / 无 key 时抛 LLMError（friendlyMessage 供 UI 展示）。
    func send(messages: [NodeChatMessage], backend: NodeBackendConfig?) async throws -> String

    /// 配置状态（输入框禁用 + 提示用）
    func configurationStatus(backend: NodeBackendConfig?) -> NodeChatConfigStatus
}

/// 真实实现：按节点 backendConfig.providerID 路由到 MinisCore Provider
/// （与 MinisCanvasLLMInvoker 同一路由哲学：bailian/dashScope → DashScope、
/// openai → OpenAI 兼容、deepseek → DeepSeek；其余未接入）。
/// 预留：节点×LLM 已前台下线（AJ-74），MinisCanvasNodeChatClient 保留待后续恢复。
@MainActor
struct MinisCanvasNodeChatClient: NodeChatLLMClient {

    func send(messages: [NodeChatMessage], backend: NodeBackendConfig?) async throws -> String {
        // 未配置模型 → 引导用户先设置模型（LLMError friendlyMessage 路径）
        guard let backend = Self.normalizedBackend(backend) else {
            throw LLMError.providerError(message: NodeChatConfigStatus.noModelHint)
        }
        let model = Self.llmModel(for: backend)
        // Swift 6：非 Sendable 的 `any LLMProvider` 在 @MainActor 隔离域内构造后要跨隔离域
        // 送入非隔离 async sendMessage —— `nonisolated(unsafe)` 跳过区域隔离检查。
        // 安全性由具体实现类均 @unchecked Sendable（DashScopeProvider/OpenAICompatibleProvider/
        // DeepSeekProvider）保证；若未来注册非 Sendable 实现需重审（swift6-strict-concurrency §1）。
        nonisolated(unsafe) let provider = try Self.provider(providerID: backend.providerID, model: model)

        // 无 key → 抛 invalidAPIKey（friendlyMessage：请检查 API Key 配置）
        if let dash = provider as? DashScopeProvider, dash.resolvedAPIKey == nil {
            throw LLMError.invalidAPIKey()
        }
        if let deep = provider as? DeepSeekProvider, deep.resolvedAPIKey == nil {
            throw LLMError.invalidAPIKey()
        }
        if backend.providerID == "openai", EnvCredentials.value(for: "OPENAI_API_KEY") == nil {
            throw LLMError.invalidAPIKey()
        }

        let llmMessages = messages.map {
            LLMMessage(role: $0.role == .user ? .user : .assistant, content: $0.content)
        }
        let maxTokens = backend.params["maxTokens"].flatMap(Int.init) ?? 2000
        let temperature = backend.params["temperature"].flatMap(Double.init)
        let response = try await provider.sendMessage(
            messages: llmMessages,
            systemPrompt: nil,
            maxTokens: maxTokens,
            temperature: temperature
        )
        return response.text
    }

    func configurationStatus(backend: NodeBackendConfig?) -> NodeChatConfigStatus {
        guard let backend = Self.normalizedBackend(backend) else { return .noModel }
        switch backend.providerID {
        case "bailian", "dashScope":
            return DashScopeProvider.resolveAPIKey(injected: nil) == nil ? .noKey : .ready
        case "openai":
            return EnvCredentials.value(for: "OPENAI_API_KEY") == nil ? .noKey : .ready
        case "deepseek":
            return DeepSeekProvider.resolveAPIKey(injected: nil) == nil ? .noKey : .ready
        default:
            return .unsupported
        }
    }

    // MARK: - 辅助

    /// 按节点 backendConfig 构造 LLMModel；不从聊天或全局默认模型兜底。
    private static func llmModel(for backend: NodeBackendConfig) -> LLMModel {
        LLMModel(
            id: backend.modelID,
            displayName: backend.modelID,
            provider: "DashScope"
        )
    }

    /// 空白 provider/model 均视为未配置；有效配置统一去除首尾空白后传给 Provider。
    private static func normalizedBackend(_ backend: NodeBackendConfig?) -> NodeBackendConfig? {
        guard let backend else { return nil }
        let providerID = backend.providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID = backend.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !providerID.isEmpty, !modelID.isEmpty else { return nil }
        var normalized = backend
        normalized.providerID = providerID
        normalized.modelID = modelID
        return normalized
    }

    /// providerID → MinisCore LLMProvider（未接入的 providerID 抛 providerError）
    private static func provider(providerID: String, model: LLMModel) throws -> any LLMProvider {
        switch providerID {
        case "bailian", "dashScope":
            return DashScopeProvider(apiKey: nil, model: model)
        case "openai":
            return OpenAICompatibleProvider(
                apiKey: EnvCredentials.value(for: "OPENAI_API_KEY") ?? "",
                model: model,
                customBaseURL: nil,
                appendV1Suffix: true
            )
        case "deepseek":
            return DeepSeekProvider(apiKey: nil, model: model)
        default:
            throw LLMError.providerError(message: "Provider 未接入：\(providerID)，请检查 Provider 配置后重启应用")
        }
    }
}

// MARK: - 节点对话状态

/// 节点级模型对话状态：nodeID → 独立历史 / 输入草稿 / 发送中标志。
/// 与 agent 的 ChatStore 完全隔离（不同 store、不同历史、不同消息模型）。
@MainActor
@Observable
final class NodeChatStore {
    /// 节点 id → 该节点独立对话历史
    var nodeChats: [UUID: [NodeChatMessage]] = [:]
    /// 节点 id → 该节点输入框草稿（切换节点不丢草稿）
    var nodeChatInput: [UUID: String] = [:]
    /// 正在等待回复的节点（并发发送防护 + UI 禁用）
    private(set) var sendingNodeIDs: Set<UUID> = []

    private let client: NodeChatLLMClient

    init(client: NodeChatLLMClient = MinisCanvasNodeChatClient()) {
        self.client = client
    }

    // MARK: 查询

    func messages(for nodeID: UUID) -> [NodeChatMessage] {
        nodeChats[nodeID] ?? []
    }

    func input(for nodeID: UUID) -> String {
        nodeChatInput[nodeID] ?? ""
    }

    func isSending(nodeID: UUID) -> Bool {
        sendingNodeIDs.contains(nodeID)
    }

    /// 节点对话配置状态（输入框禁用 + 内联提示）
    func configurationStatus(nodeID: UUID, backend: NodeBackendConfig?) -> NodeChatConfigStatus {
        client.configurationStatus(backend: backend)
    }

    // MARK: 操作

    func setInput(_ text: String, for nodeID: UUID) {
        nodeChatInput[nodeID] = text
    }

    /// 清空该节点对话历史（输入草稿保留）
    func clearHistory(nodeID: UUID) {
        nodeChats[nodeID] = []
    }

    /// 删除节点时清理其历史
    func removeHistory(nodeID: UUID) {
        nodeChats[nodeID] = nil
        nodeChatInput[nodeID] = nil
        sendingNodeIDs.remove(nodeID)
    }

    /// 发送一条消息到该节点模型：用户消息入历史 → 调该节点 backendConfig 的
    /// provider/model → 回复 append 到同一节点历史。失败时 append 错误消息
    /// （LLMError friendlyMessage），不抛错、不阻塞 UI。
    func sendNodeChat(nodeID: UUID, message: String, backend: NodeBackendConfig?) async {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending(nodeID: nodeID) else { return }
        nodeChatInput[nodeID] = ""
        nodeChats[nodeID, default: []].append(NodeChatMessage(role: .user, content: text))
        sendingNodeIDs.insert(nodeID)
        defer { sendingNodeIDs.remove(nodeID) }

        do {
            let reply = try await client.send(messages: nodeChats[nodeID] ?? [], backend: backend)
            nodeChats[nodeID, default: []].append(NodeChatMessage(role: .assistant, content: reply))
        } catch {
            let message = Self.friendlyErrorMessage(error)
            nodeChats[nodeID, default: []].append(NodeChatMessage(role: .assistant, content: message))
        }
    }

    /// LLMError → friendlyMessage（中文环境）；其他错误兜底 localizedDescription。
    static func friendlyErrorMessage(_ error: Error) -> String {
        if let llm = error as? MinisCore.LLMError {
            if case .providerError(let message) = llm,
               message == NodeChatConfigStatus.noModelHint {
                return NodeChatConfigStatus.noModelHint
            }
            return llm.friendlyMessage(locale: .current)
        }
        return error.localizedDescription
    }
}
