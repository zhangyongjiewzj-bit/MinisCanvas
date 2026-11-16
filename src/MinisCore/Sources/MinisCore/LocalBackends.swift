import Foundation

// MARK: - Backend Kind

/// 本地模型后端的类型：Ollama（LLM）、ComfyUI（生图/生视频工作流）、
/// SD WebUI（生图）、Wan（生视频，通常托管于 ComfyUI）。
public enum LocalBackendKind: String, Codable, Sendable, CaseIterable, Hashable {
    case ollama
    case comfyui
    case sdWebUI
    case wan

    /// 该后端的默认本地地址。
    public var defaultBaseURL: String {
        switch self {
        case .ollama: return "http://localhost:11434"
        case .comfyui: return "http://localhost:8188"
        case .sdWebUI: return "http://localhost:7860"
        case .wan: return "http://localhost:8188" // Wan 通常跑在 ComfyUI 上
        }
    }

    public var displayName: String {
        switch self {
        case .ollama: return "Ollama"
        case .comfyui: return "ComfyUI"
        case .sdWebUI: return "SD WebUI"
        case .wan: return "Wan"
        }
    }
}

// MARK: - Config

/// 单个本地后端的配置（漫剧节点选择本地模型时使用）。
public struct LocalBackendConfig: Codable, Sendable, Hashable {
    public var kind: LocalBackendKind
    public var baseURL: String
    public var enabled: Bool

    public init(kind: LocalBackendKind, baseURL: String, enabled: Bool = true) {
        self.kind = kind
        self.baseURL = baseURL
        self.enabled = enabled
    }
}

// MARK: - Errors

public enum LocalBackendsError: Error, LocalizedError, Equatable, Sendable {
    case invalidURL(String)
    case notOnline(LocalBackendKind)
    case decodeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let s): return "Invalid local backend URL: \(s)"
        case .notOnline(let k): return "\(k.displayName) backend is not online"
        case .decodeFailed(let s): return "Failed to decode local backend response: \(s)"
        }
    }
}

// MARK: - LocalBackends

/// 本地后端（Ollama / ComfyUI / SD WebUI / Wan）的探测与模型列表入口。
/// 纯 Foundation + URLSession，不依赖 SwiftUI。
///
/// 用法：
/// ```
/// let status = await LocalBackends.shared.detect()   // [.ollama: true, ...]
/// let models = try await LocalBackends.shared.ollamaModels()
/// ```
public final class LocalBackends: @unchecked Sendable {
    public static let shared = LocalBackends()

    /// 默认配置（全部启用）。
    public static let defaultConfigs: [LocalBackendKind: LocalBackendConfig] = [
        .ollama: LocalBackendConfig(kind: .ollama, baseURL: LocalBackendKind.ollama.defaultBaseURL),
        .comfyui: LocalBackendConfig(kind: .comfyui, baseURL: LocalBackendKind.comfyui.defaultBaseURL),
        .sdWebUI: LocalBackendConfig(kind: .sdWebUI, baseURL: LocalBackendKind.sdWebUI.defaultBaseURL),
        .wan: LocalBackendConfig(kind: .wan, baseURL: LocalBackendKind.wan.defaultBaseURL),
    ]

    /// 探测超时（秒），默认 2 秒。
    public var probeTimeout: TimeInterval {
        get { lock.withLock { probeTimeoutStorage } }
        set { lock.withLock { probeTimeoutStorage = newValue } }
    }

    private var probeTimeoutStorage: TimeInterval = 2.0

    private let lock = NSLock()
    private var configs: [LocalBackendKind: LocalBackendConfig]

    public init(configs: [LocalBackendKind: LocalBackendConfig]? = nil) {
        self.configs = configs ?? Self.defaultConfigs
        // 集成 ProviderFactory：注册（替换）local 类型的 builder（幂等）。
        LocalBackendFactory.register()
    }

    // MARK: - Config access

    public func config(for kind: LocalBackendKind) -> LocalBackendConfig? {
        lock.lock(); defer { lock.unlock() }
        return configs[kind]
    }

    public func setConfig(_ config: LocalBackendConfig) {
        lock.lock()
        configs[config.kind] = config
        lock.unlock()
    }

    public func setEnabled(_ enabled: Bool, for kind: LocalBackendKind) {
        lock.lock()
        if var c = configs[kind] { c.enabled = enabled; configs[kind] = c }
        lock.unlock()
    }

    public func allConfigs() -> [LocalBackendKind: LocalBackendConfig] {
        lock.lock(); defer { lock.unlock() }
        return configs
    }

    // MARK: - Detection

    /// 并行探测所有已启用后端，返回 kind -> 是否在线。
    public func detect() async -> [LocalBackendKind: Bool] {
        let targets = allConfigs().values.filter { $0.enabled }
        return await withTaskGroup(of: (LocalBackendKind, Bool).self) { group in
            for config in targets {
                group.addTask { (config.kind, await self.probe(config)) }
            }
            var result: [LocalBackendKind: Bool] = [:]
            for await (kind, online) in group {
                result[kind] = online
            }
            return result
        }
    }

    /// 探测单个后端是否在线。
    public func isOnline(_ kind: LocalBackendKind) async -> Bool {
        guard let config = config(for: kind), config.enabled else { return false }
        return await probe(config)
    }

    private func probe(_ config: LocalBackendConfig) async -> Bool {
        let path = Self.probePath(for: config.kind)
        guard let url = URL(string: trimmedBase(config.baseURL) + path) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = probeTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, response) = try await Self.probeSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }

    private static func probePath(for kind: LocalBackendKind) -> String {
        switch kind {
        case .ollama: return "/api/tags"
        case .comfyui, .wan: return "/system_stats"
        case .sdWebUI: return "/sdapi/v1/options"
        }
    }

    // MARK: - Model lists

    /// 获取 Ollama 模型列表（GET /api/tags → models[].name）。
    public func ollamaModels() async throws -> [String] {
        guard let config = config(for: .ollama), config.enabled else {
            throw LocalBackendsError.notOnline(.ollama)
        }
        guard let url = URL(string: trimmedBase(config.baseURL) + "/api/tags") else {
            throw LocalBackendsError.invalidURL(config.baseURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = probeTimeout
        let (data, response) = try await Self.probeSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LocalBackendsError.notOnline(.ollama)
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw LocalBackendsError.decodeFailed(config.baseURL)
        }
        let models = json["models"] as? [[String: Any]] ?? []
        return models.compactMap { $0["name"] as? String }
    }

    /// 按后端类型取模型列表：Ollama 返回本地模型；
    /// ComfyUI / SD WebUI / Wan 的生图生视频模型由工作流/检查点提供，暂不在此列出。
    public func models(for kind: LocalBackendKind) async throws -> [String] {
        switch kind {
        case .ollama: return try await ollamaModels()
        case .comfyui, .sdWebUI, .wan: return []
        }
    }

    // MARK: - OpenAI-compatible base URL

    /// 生成指向该本地后端的 OpenAI 兼容 baseURL。
    /// - .ollama / .wan：原生 /v1（Ollama 原生提供 /v1/chat/completions）。
    /// - .comfyui：/v1（需安装 OpenAI 兼容节点，如 ComfyUI-OpenAI-Redux 等社区节点）。
    /// - .sdWebUI：无 OpenAI 兼容聊天端点，返回 nil。
    public func openAICompatibleBaseURL(for kind: LocalBackendKind) -> String? {
        guard let config = config(for: kind), config.enabled else { return nil }
        switch kind {
        case .ollama, .comfyui, .wan:
            return trimmedBase(config.baseURL) + "/v1"
        case .sdWebUI:
            return nil
        }
    }

    /// 为该后端生成一个指向本地 /v1 端点的 LLMProvider（LocalOpenAIProvider）。
    /// 模型 id 可通过 `ollamaModels()` 获取后设置。
    public func makeLLMProvider(for kind: LocalBackendKind, modelID: String? = nil) throws -> any LLMProvider {
        guard let base = openAICompatibleBaseURL(for: kind) else {
            throw LocalBackendsError.notOnline(kind)
        }
        let model = LLMModel(
            id: modelID ?? "local-model",
            displayName: modelID ?? "Local Model",
            provider: kind.displayName
        )
        let inner = OpenAICompatibleProvider(
            apiKey: "",
            model: model,
            customBaseURL: base,
            appendV1Suffix: false // base 已含 /v1
        )
        let baseURL = URL(string: base) ?? URL(string: "http://127.0.0.1:11434")!
        return LocalOpenAIProvider(wrapping: inner, baseURL: baseURL)
    }

    // MARK: - Helpers

    private func trimmedBase(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// 短超时探测会话（2 秒）。
    private static let probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 2
        return URLSession(configuration: config)
    }()
}
