import Foundation

// MARK: - 生图调用注入点（协议下沉 CanvasCore，实现留在各 App 层）

/// 生图执行结果：真实图片路径/URL，或无 key 降级产出的任务单（提示词全文 + markdown 导出）。
///
/// 任务单模式（M1f）：用户没有生图 API key 时，画布不抛错、不阻塞——
/// 节点输出完整提示词任务单，用户复制到网页版手动生成后「导入结果」回填。
public enum ImageGenerationOutcome: Sendable, Equatable {
    /// 真实生成成功：本地文件路径（base64 落盘）或远程 URL
    case image(path: String)
    /// 无 key 降级：任务单（提示词全文 + markdown 导出文本）
    case jobTicket(prompt: String, markdown: String)
}

/// 生图调用注入点：CanvasCore 只做编排，不实现真实生图。
/// 真实实现（走 MinisCore `Gimage2Provider`，M1g）由上层注入——
/// CanvasApp / MinisCanvasApp 各自提供实现，互不依赖。
///
/// U2（图生图）：协议含两个要求——
/// - 3 参版：既有文生图签名（必选要求）。存量 App 层实现（CanvasApp `ImageGenInvoker` /
///   MinisCanvasApp `MinisCanvasImageInvoker`）无需任何改动即可继续满足协议；
/// - 4 参版：文生图 + 图生图统一入口，`image` 为 img2img 参考图（nil = 纯文生图）。
///   扩展提供默认实现（桥接 3 参版、忽略 image），支持 img2img 的新实现直接覆写 4 参版，
///   把 prompt + image 一起传给底层 provider。
public protocol ImageGenerating: Sendable {
    /// 执行一次文生图调用（既有要求，保持向后兼容）。
    /// - Parameters:
    ///   - node: 生图节点（标题/后端配置参与任务单构建）
    ///   - prompt: 完整提示词（来自上游输入）
    ///   - backend: 节点级模型配置（nil 时由调用方提供默认配置）
    /// - Returns: `.image(path:)` 真实生成 / `.jobTicket(prompt:markdown:)` 无 key 降级
    func generate(
        node: CanvasNode,
        prompt: String,
        backend: NodeBackendConfig?
    ) async throws -> ImageGenerationOutcome

    /// 执行一次生图调用（U2：文生图 + 图生图统一入口）。
    /// - Parameters:
    ///   - node: 生图节点（标题/后端配置参与任务单构建）
    ///   - prompt: 完整提示词（来自上游输入）
    ///   - image: 图生图参考图（本地路径/URL，来自上游 `image` 输入端口；nil = 纯文生图）。
    ///     非 nil 时走 img2img 语义：prompt + image 一起参与生成
    ///   - backend: 节点级模型配置（nil 时由调用方提供默认配置）
    /// - Returns: `.image(path:)` 真实生成 / `.jobTicket(prompt:markdown:)` 无 key 降级
    func generate(
        node: CanvasNode,
        prompt: String,
        image: String?,
        backend: NodeBackendConfig?
    ) async throws -> ImageGenerationOutcome
}

extension ImageGenerating {
    /// 默认实现：桥接既有文生图签名（忽略 image 参考图，保持纯文生图语义）。
    /// 只实现 3 参版的存量 invoker 升级协议后无需改动即可编译运行（U2 向后兼容）；
    /// 支持 img2img 的实现请覆写本方法。
    public func generate(
        node: CanvasNode,
        prompt: String,
        image: String?,
        backend: NodeBackendConfig?
    ) async throws -> ImageGenerationOutcome {
        try await generate(node: node, prompt: prompt, backend: backend)
    }
}
