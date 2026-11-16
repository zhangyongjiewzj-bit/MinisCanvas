import Foundation
import CanvasCore
import MinisCore

// MARK: - 生图真实调用（M1g）

/// 画布生图节点的真实调用实现（M1g），实现 CanvasCore 的 `ImageGenerating` 注入点。
///
/// 调 MinisCore 的 `Gimage2Provider`（`CloudImageGenerator` 协议）生成图片：
/// - 有 key（运行时读 `HERMES_CUSTOM_IMAGE2_API_KEY` / `IMAGE2_API_KEY` /
///   `GIMAGE2_API_KEY`，不写死）→ 真实生图：b64 落盘到临时目录或返回远程 URL，
///   输出路径/URL 写入节点 outputs
/// - 无 key → 降级任务单模式（M1f）：构建 JobTicket 提示词，节点输出任务单文本，
///   不阻塞画布执行（用户复制到网页版手动生成 → 导入结果回填）
/// - 生图失败 → 抛错误带「生图失败：检查 API key」提示
struct ImageGenInvoker: ImageGenerating {

    public enum InvokerError: Error, LocalizedError, Sendable {
        /// 未配置 API key（正常路径已被降级拦截，仅防御性保留）
        case missingAPIKey
        /// 生图失败（网络 / 服务端 / 解析）
        case generationFailed(String)

        public var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "生图失败：检查 API key（未配置 HERMES_CUSTOM_IMAGE2_API_KEY / GIMAGE2_API_KEY，已降级任务单模式）"
            case .generationFailed(let detail):
                return "生图失败：检查 API key 与网络后重试（\(detail)）"
            }
        }
    }

    /// 是否已配置生图 key（运行时读环境变量，不写死）。
    public static var isConfigured: Bool {
        Gimage2Provider.resolveAPIKey(injected: nil) != nil
    }

    /// 生图模型兜底：gimage2.env 的 `GIMAGE2_MODEL_G2`（默认 `gpt-image-2`，适配 5678ai 中转站）。
    /// 当节点未配模型或仍是 Provider 默认占位模型（`gpt-image-2-official`，中转站 403）时使用。
    private static func resolveModelOverride(backend: NodeBackendConfig?) -> String? {
        if let model = backend?.modelID, !model.isEmpty, model != Gimage2Provider.defaultModel {
            return model
        }
        return EnvCredentials.value(for: "GIMAGE2_MODEL_G2") ?? "gpt-image-2"
    }

    /// 归一化 base URL：剥掉尾部 `/v1`（MinisCore `URLBuilding.joinURL` 拼接 `/v1` 段时不
    /// 去重；gimage2.env 的 `GIMAGE2_BASE_URL` 常带 `/v1`，此处实现文档声明的「含 /v1 自动去重」）。
    static func normalizeBaseURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if s.hasSuffix("/v1") { s = String(s.dropLast(3)) }
        return s
    }

    /// 执行生图：prompt 取上游（图片提示词节点）输入，经 Gimage2Provider 生成。
    /// - Note: 真异步契约（A3）——本方法为 `async`，内部网络/落盘全部 await，
    ///   不占用调用线程；调用方在 `Task` 中调用即可保证主线程不阻塞。
    /// - Returns: `.image(path:)` 真实生成 / `.jobTicket(_:)` 无 key 降级
    public func generate(
        node: CanvasNode,
        prompt: String,
        backend: NodeBackendConfig?
    ) async throws -> ImageGenerationOutcome {
        let baseURL = EnvCredentials.value(for: "HERMES_CUSTOM_IMAGE2_BASE_URL")
            .map(Self.normalizeBaseURL)
        let provider = Gimage2Provider(baseURL: baseURL)
        let promptText = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        // 无 key 或空提示词 → 降级任务单（结构完整可复制，不阻塞画布）
        guard provider.isConfigured, !promptText.isEmpty else {
            let ticket = makeFallbackTicket(node: node, prompt: promptText)
            return .jobTicket(prompt: ticket.prompt, markdown: ticket.markdown)
        }

        let request = CloudImageRequest(
            prompt: promptText,
            size: backend?.params["size"],
            count: 1,
            modelOverride: Self.resolveModelOverride(backend: backend)
        )

        let result: CloudImageResult
        do {
            result = try await provider.generateImage(request)
        } catch {
            throw InvokerError.generationFailed(String(describing: error))
        }
        guard let item = result.images.first, item.hasContent else {
            throw InvokerError.generationFailed("服务返回为空")
        }
        if let b64 = item.base64Data, !b64.isEmpty {
            return .image(path: try Self.saveBase64(b64, providerID: result.providerID))
        }
        if let url = item.url, !url.isEmpty {
            return .image(path: url)
        }
        throw InvokerError.generationFailed("返回内容无有效图片数据")
    }

    /// 无 key 降级：构建 JobTicket（提示词优先取上游完整槽位文本，
    /// 参考图锁定清单从提示词文本提取，铁律2 只写锁定清单）。
    private func makeFallbackTicket(node: CanvasNode, prompt: String) -> JobTicket {
        let template = ManjuPromptTemplates.template(for: .imageGen)
            ?? ManjuTemplate(
                nodeType: .imageGen,
                slots: ManjuPromptTemplates.imageSlots,
                systemPrompt: ManjuPromptTemplates.imageSystemPrompt
            )
        return JobTicket.make(
            node: node,
            template: template,
            promptText: prompt.isEmpty ? nil : prompt,
            fallbackParams: [:],
            referenceImages: JobTicket.extractReferenceIDs(from: prompt)
        )
    }

    /// b64 → 临时目录落盘（/tmp/miniscanvas_generated/<provider>-<uuid>.png），返回文件路径。
    static func saveBase64(_ b64: String, providerID: String) throws -> String {
        guard let data = Data(base64Encoded: b64) else {
            throw InvokerError.generationFailed("base64 解码失败")
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniscanvas_generated", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(providerID)-\(UUID().uuidString.prefix(8)).png")
        try data.write(to: url)
        return url.path
    }
}
