import Foundation
import CanvasCore

/// 画布 LLM 节点的真实调用实现（M2d）。
///
/// 实现 CanvasCore 的 `LLMInvoker` 注入点，直连 OpenAI 兼容 Chat Completions
/// 端点（百炼 compatible-mode / Ollama / OpenAI），stream=false 单次对话。
/// 采用 URLSession 直连而非 MinisCore ProviderFactory：两套 Provider 并行维护的
/// 架构权衡见 I5 P1-2（I7 只做注入接线，不动 Provider 抽象）。
/// 注：本文件头注释「CanvasApp 仅依赖 CanvasCore」已过期（I5 P2-3）——
/// CanvasApp 依赖 MinisCore（ImageGenInvoker / CanvasBlenderInvoker 使用）。
public struct CanvasLLMInvoker: LLMInvoker {
    public init() {}

    // MARK: - 错误

    public enum InvokerError: Error, LocalizedError, Equatable, Sendable {
        /// providerID 未接入
        case unsupportedProvider(String)
        /// 缺少 API key（未设置对应环境变量）
        case missingAPIKey(String)
        /// HTTP 非 2xx 或网络错误（statusCode == -1 表示网络层失败）
        case httpError(statusCode: Int, body: String)
        /// choices 为空或 content 缺失
        case emptyResponse
        /// 响应不是可解析的 JSON
        case malformedResponse(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedProvider(let id):
                return "未接入的 provider: \(id)"
            case .missingAPIKey(let label):
                return "缺少 API key：\(label)（请设置对应环境变量）"
            case .httpError(let code, let body):
                if code == -1 { return "LLM 网络错误：\(body)" }
                return "LLM HTTP \(code): \(String(body.prefix(300)))"
            case .emptyResponse:
                return "LLM 返回空内容（choices 为空或无 content）"
            case .malformedResponse(let detail):
                return "LLM 响应解析失败：\(detail)"
            }
        }
    }

    // MARK: - 端点路由

    private struct Endpoint {
        let baseURL: String
        let apiKey: String?
    }

    private func endpoint(for backend: NodeBackendConfig) throws -> Endpoint {
        switch backend.providerID {
        case "bailian":
            // key 优先级（M2l）：HERMES_CUSTOM_QWEN38_API_KEY（已购模型）优先，
            // BAILIAN_TOKEN_PLAN_API_KEY（未购模型，403）兜底
            let key = env("HERMES_CUSTOM_QWEN38_API_KEY") ?? env("BAILIAN_TOKEN_PLAN_API_KEY")
            guard let key, !key.isEmpty else {
                throw InvokerError.missingAPIKey("HERMES_CUSTOM_QWEN38_API_KEY 或 BAILIAN_TOKEN_PLAN_API_KEY")
            }
            return Endpoint(
                baseURL: "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1",
                apiKey: key
            )
        case "ollama":
            // 本地 Ollama OpenAI 兼容端点，无需鉴权
            return Endpoint(baseURL: "http://localhost:11434/v1", apiKey: nil)
        case "openai":
            guard let key = env("OPENAI_API_KEY"), !key.isEmpty else {
                throw InvokerError.missingAPIKey("OPENAI_API_KEY")
            }
            return Endpoint(baseURL: "https://api.openai.com/v1", apiKey: key)
        default:
            throw InvokerError.unsupportedProvider(backend.providerID)
        }
    }

    private func env(_ name: String) -> String? {
        ProcessInfo.processInfo.environment[name]
    }

    /// 未配置 modelID 时的兜底默认模型（仅兜底，不覆盖显式配置）。
    private func defaultModel(for providerID: String) -> String {
        switch providerID {
        case "bailian": return "qwen3.8-max-preview"
        case "ollama": return "qwen2.5"
        case "openai": return "gpt-4o-mini"
        default: return ""
        }
    }

    // MARK: - LLMInvoker

    public func invoke(prompt: String, backend: NodeBackendConfig) async throws -> String {
        let endpoint = try endpoint(for: backend)
        let model = backend.modelID.isEmpty ? defaultModel(for: backend.providerID) : backend.modelID

        let url = URL(string: endpoint.baseURL + "/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = endpoint.apiKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        // 超时可配置（M2l）：backend.params["timeout"]（秒），默认 300s。
        // 百炼 qwen3.8-max-preview 长文本生成 2~3 分钟/节点，120s 固定超时必挂。
        let timeoutSeconds = backend.params["timeout"].flatMap(Double.init) ?? 300
        request.timeoutInterval = timeoutSeconds

        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "stream": false,
        ]
        // 参数透传：temperature / maxTokens / timeout（来自 backend.params）
        if let raw = backend.params["temperature"], let temperature = Double(raw) {
            body["temperature"] = temperature
        }
        if let raw = backend.params["maxTokens"], let maxTokens = Int(raw) {
            body["max_tokens"] = maxTokens
        } else {
            // 默认 2000（M2l）：长文本节点够用，避免生成过长拖慢/超时
            body["max_tokens"] = 2000
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw InvokerError.httpError(statusCode: -1, body: error.localizedDescription)
        }

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw InvokerError.httpError(statusCode: statusCode, body: bodyText)
        }

        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw InvokerError.malformedResponse("响应不是 JSON 对象")
        }
        guard let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            throw InvokerError.emptyResponse
        }

        if let text = message["content"] as? String, !text.isEmpty {
            return text
        }
        // 兼容 content 为数组（多模态返回）时拼接 text 块
        if let parts = message["content"] as? [[String: Any]] {
            let text = parts.compactMap { $0["text"] as? String }.joined()
            if !text.isEmpty { return text }
        }
        throw InvokerError.emptyResponse
    }
}

// MARK: - 无 key 降级包装（I7 P0-2）

/// 画布 LLM 注入点包装：真实 `CanvasLLMInvoker`（M2l）优先，缺 key / provider 未接入时
/// 自动降级 `PlaceholderLLMInvoker`（占位输出），保证画布无环境变量也能跑通执行链路。
/// - 有 key（`HERMES_CUSTOM_QWEN38_API_KEY` / `BAILIAN_TOKEN_PLAN_API_KEY` / `OPENAI_API_KEY`）
///   或 provider = ollama（本地免鉴权）→ 走真实 LLM 调用（默认 300s 超时，可配）
/// - 缺 key / 未接入 provider → 降级占位文本（节点标记成功，不阻塞画布）
public struct FallbackLLMInvoker: LLMInvoker {
    private let primary = CanvasLLMInvoker()
    private let fallback = PlaceholderLLMInvoker()

    public init() {}

    public func invoke(prompt: String, backend: NodeBackendConfig) async throws -> String {
        do {
            return try await primary.invoke(prompt: prompt, backend: backend)
        } catch CanvasLLMInvoker.InvokerError.missingAPIKey,
                CanvasLLMInvoker.InvokerError.unsupportedProvider {
            return try await fallback.invoke(prompt: prompt, backend: backend)
        }
    }
}
