import Foundation

// MARK: - 本地后端探测（A2-v03）
//
// 镜像 MinisCore `LocalBackends` 的契约（探测端点/语义一致），供 CanvasApp 模型面板独立使用。
// 背景：CanvasApp 暂未依赖 MinisCore（M2b 云端后端在飞，MinisCore 当前不可编译），
// 故在 App 内自建轻量探测；M2b 合拢后可切换到 `LocalBackends.shared`（API 签名相同：
// `detect()` 返回 [kind: Bool]、`ollamaModels()` 返回真实模型名）。

/// 本地模型后端类型：Ollama（LLM）、ComfyUI（生图工作流）、SD WebUI（生图）、Wan（生视频，常托管于 ComfyUI）。
enum LocalBackendKind: String, CaseIterable, Hashable, Sendable {
    case ollama
    case comfyui
    case sdWebUI
    case wan

    /// 该后端的默认本地地址（与 MinisCore LocalBackendKind.defaultBaseURL 一致）。
    var defaultBaseURL: String {
        switch self {
        case .ollama: return "http://localhost:11434"
        case .comfyui: return "http://localhost:8188"
        case .sdWebUI: return "http://localhost:7860"
        case .wan: return "http://localhost:8188" // Wan 通常跑在 ComfyUI 上
        }
    }

    var displayName: String {
        switch self {
        case .ollama: return "Ollama"
        case .comfyui: return "ComfyUI"
        case .sdWebUI: return "SD WebUI"
        case .wan: return "Wan"
        }
    }

    /// 在线探测路径（与 MinisCore LocalBackends.probePath 一致）。
    var probePath: String {
        switch self {
        case .ollama: return "/api/tags"
        case .comfyui, .wan: return "/system_stats"
        case .sdWebUI: return "/sdapi/v1/options"
        }
    }
}

/// 轻量本地后端探测器：短超时（2s）并行探测 + Ollama 模型列表。
struct LocalBackendProbe: Sendable {
    static let shared = LocalBackendProbe()

    /// 探测超时（秒），默认 2 秒（与 MinisCore LocalBackends.probeTimeout 一致）。
    var probeTimeout: TimeInterval = 2.0

    /// 短超时探测会话（2 秒）。
    private static let probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 2
        return URLSession(configuration: config)
    }()

    /// 并行探测所有本地后端，返回 kind -> 是否在线。
    func detect() async -> [LocalBackendKind: Bool] {
        await withTaskGroup(of: (LocalBackendKind, Bool).self) { group in
            for kind in LocalBackendKind.allCases {
                group.addTask { (kind, await self.isOnline(kind)) }
            }
            var result: [LocalBackendKind: Bool] = [:]
            for await (kind, online) in group {
                result[kind] = online
            }
            return result
        }
    }

    /// 探测单个后端是否在线（GET 探测路径，2xx 视为在线）。
    func isOnline(_ kind: LocalBackendKind) async -> Bool {
        guard let url = URL(string: kind.defaultBaseURL + kind.probePath) else { return false }
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

    /// 获取 Ollama 模型列表（GET /api/tags → models[].name），失败返回空数组。
    func ollamaModels() async -> [String] {
        guard let url = URL(string: LocalBackendKind.ollama.defaultBaseURL + "/api/tags") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = probeTimeout
        do {
            let (data, response) = try await Self.probeSession.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return [] }
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
            let models = json["models"] as? [[String: Any]] ?? []
            return models.compactMap { $0["name"] as? String }
        } catch {
            return []
        }
    }
}
