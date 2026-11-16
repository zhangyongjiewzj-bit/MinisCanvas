import Foundation
import MinisCore

// MARK: - B3 文本节点「优化提示词」服务

/// 把画布文本节点草稿交给 LLM 润色为更专业、更可执行的提示词。
/// provider 工厂由 UI 层注入（`bridge.chat.activeProvider()`），测试注入 stub。
/// factory 显式隔离到 MainActor；optimize 在该 actor 上取 provider，
/// 再用既有 LLMProviderBox 传出这一实例，不假定 async 自动继承调用方 actor。
struct OptimizePromptService: @unchecked Sendable {

    /// 模型返回为空时的错误。
    enum ServiceError: LocalizedError {
        case emptyResult
        var errorDescription: String? { "模型返回为空，请重试。" }
    }

    let providerFactory: @MainActor @Sendable () throws -> any LLMProvider

    /// 优化文本。失败向上抛（网络/配额/provider 错误）。
    func optimize(_ text: String) async throws -> String {
        let providerBox = try await MainActor.run {
            LLMProviderBox(value: try providerFactory())
        }
        let provider = providerBox.value
        let response = try await provider.sendMessage(
            messages: [LLMMessage(role: .user, content: text)],
            systemPrompt: Self.systemPrompt,
            maxTokens: 1500,
            temperature: 0.4
        )
        let result = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw ServiceError.emptyResult }
        return result
    }

    /// 系统提示词：让模型做「提示词工程师」润色而非改写内容。
    static let systemPrompt = """
    你是一位资深的 AI 提示词工程师。用户会给你一段画布节点的文本内容（可能是剧情梗概、分镜描述、图像/视频生成提示词等）。
    请把它优化为更专业、更清晰、更可执行的提示词：
    1. 保留原始语义与关键信息，不虚构内容；
    2. 结构清晰：场景/人物/动作/镜头/风格分层；
    3. 用简洁具体的中文，避免空泛形容词；
    4. 直接输出优化结果，不要解释、不要问候。
    """
}
