import Foundation

// MARK: - 节点执行器框架（M2c）

/// 节点执行器错误
public enum NodeExecutorsError: Error, Equatable, Sendable, LocalizedError {
    /// 节点类型没有注册对应执行器
    case unknownNodeType(String)
    /// LLM 节点未注入 LLMInvoker（真实调用由外部注入，本层只做编排）
    case missingLLMInvoker(String)
    /// LLM 节点没有完整的节点级模型配置
    case invalidLLMBackend(String)
    /// LLM 调用失败（底层错误透传描述）
    case llmInvocationFailed(String)
    /// Blender 节点未注入 BlenderRenderInvoker（真实调用由外部注入）
    case missingBlenderInvoker(String)
    /// Blender 节点缺少渲染脚本（无 script 输入且无模板兜底）
    case missingBlenderScript(String)
    /// Blender 渲染调用失败（BlenderBridge 错误透传描述）
    case blenderInvocationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unknownNodeType(let type):
            return "未知节点类型，未注册执行器：\(type)"
        case .missingLLMInvoker(let type):
            return "LLM 节点 \(type) 未注入 LLMInvoker，无法执行（请由 GraphExecutionContext / UI 注入）"
        case .invalidLLMBackend(let reason):
            return "LLM 节点模型配置无效：\(reason)"
        case .llmInvocationFailed(let reason):
            return "LLM 调用失败：\(reason)"
        case .missingBlenderInvoker(let type):
            return "Blender 节点 \(type) 未注入 BlenderRenderInvoker，无法执行（请由 GraphExecutionContext / UI 注入）"
        case .missingBlenderScript(let type):
            return "Blender 节点 \(type) 缺少渲染脚本：请提供 script 输入（Python 脚本内容或路径）"
        case .blenderInvocationFailed(let reason):
            return "Blender 渲染失败：\(reason)"
        }
    }
}

/// LLM 调用注入点：本层不实现真实 LLM 调用，只做编排。
/// 真实实现（走 MinisCore ProviderFactory / M2b 云端后端）由上层注入。
public protocol LLMInvoker: Sendable {
    /// 执行一次 LLM 调用。
    /// - Parameters:
    ///   - prompt: 完整提示词（系统提示词 + 节点输入拼接，见 `LLMNodeExecutor.buildPrompt`）
    ///   - backend: 节点级模型配置（nil 时由调用方提供默认配置）
    /// - Returns: 模型输出文本
    func invoke(prompt: String, backend: NodeBackendConfig) async throws -> String
}

/// Blender 渲染调用注入点：本层不实现真实 Blender 调用，只做编排。
/// 真实实现（走 MinisCore BlenderBridge，M3b）由上层注入。
public protocol BlenderRenderInvoker: Sendable {
    /// 执行一次 Blender 白模渲染。
    /// - Parameters:
    ///   - script: Python 脚本内容（创建白模/相机/灯光并渲染 PNG 到 outputDir）
    ///   - outputDir: 渲染输出目录（不存在会自动创建）
    ///   - frameRange: 可选帧范围，透传给 BlenderBridge
    /// - Returns: 生成的 PNG 绝对路径列表
    func render(
        script: String,
        outputDir: String,
        frameRange: (Int, Int)?
    ) async throws -> [String]
}

/// 节点执行器：画布「执行」按钮真正干活的层。
/// 按 `CanvasNode.type` 路由（见 `NodeExecutors.executor(for:)`），由 DAGScheduler 的
/// `NodeExecutionContext` 实现（GraphExecutionContext）在 `execute` 时调用。
public protocol NodeExecutor: Sendable {
    /// 执行节点实际逻辑。
    /// - Parameters:
    ///   - node: 待执行节点
    ///   - inputs: resolveInputs 解析出的输入（端口名 → 值），无输入时为 nil
    ///   - backend: 节点级完整模型配置；LLM 节点不可使用全局默认模型兜底
    /// - Returns: 节点输出字典（端口名 → 值），写入 DAGScheduler 结果缓存
    func execute(
        node: CanvasNode,
        inputs: [String: AnyHashable]?,
        backend: NodeBackendConfig?
    ) async throws -> [String: AnyHashable]
}

/// 执行器注册表与路由：按 `CanvasNode.type` 字符串返回对应执行器。
///
/// 路由表（16 类）：
/// - `text` → `TextNodeExecutor`（返回 inputs 或固定文本）
/// - `llm` + manju 6 类 LLM 节点（novelImport/plotOutline/script/storyboard/
///   imagePrompt/videoPrompt）→ `LLMNodeExecutor`（经注入的 LLMInvoker 编排）
/// - `qcCheck` → `QCNodeExecutor`（确定性本地判定：结构闸口 + 审美闸口 S1-S5 + 三刻度盘，
///   不依赖 LLM，输出 report + status=PASS/FAIL + 三刻度盘值）
/// - `image`/`video` + manju 2 类生成节点（imageGen/videoGen）→ `MediaPlaceholderExecutor`
///   （占位，真实 API 由 M2b 云端后端/本地后端接入）
/// - `blenderPreview` → `BlenderNodeExecutor`（经注入的 BlenderRenderInvoker 调 BlenderBridge 白模渲染）
/// - `assetRef` → `AssetLockExecutor`（资产锁定接线：输出 ManjuAssetInjection 注入的资产锁定摘要 + 参考图清单）
/// - `reviewGate` → `ReviewGateExecutor`（审核闸口：空文本 PENDING / 含 BLOCKED·（待填）REJECT /
///   其余 PASS 放行原文，确定性本地判定）
///
/// 与 DAGScheduler 集成（GraphExecutionContext，注释约定）：
/// ```swift
/// final class GraphExecutionContext: NodeExecutionContext, @unchecked Sendable {
///     let executors: NodeExecutors          // 持有 NodeExecutors + LLMInvoker
///     let invoker: (any LLMInvoker)?
///
///     func execute(node: CanvasNode, inputs: [String: AnyHashable]?) throws -> [String: AnyHashable] {
///         guard let executor = executors.executor(for: node.type) else {
///             throw NodeExecutorsError.unknownNodeType(node.type)
///         }
///         // DAGScheduler.execute 为同步协议，需桥接 async（如 withCheckedThrowingContinuation / semaphore）
///         return try syncAwait {
///             try await executor.execute(node: node, inputs: inputs, backend: node.backendConfig)
///         }
///     }
/// }
/// ```
public struct NodeExecutors: Sendable {

    /// 注入的 LLM 调用器（nil = 未注入，LLM 节点执行时抛 `.missingLLMInvoker`）
    public let llmInvoker: (any LLMInvoker)?
    /// 注入的 Blender 渲染调用器（nil = 未注入，blenderPreview 节点执行时抛 `.missingBlenderInvoker`）
    public let blenderInvoker: (any BlenderRenderInvoker)?
    /// Canonical media fact source for assetRef execution.
    public let mediaAssetResolver: (any MediaAssetResolving)?

    public init(
        llmInvoker: (any LLMInvoker)? = nil,
        blenderInvoker: (any BlenderRenderInvoker)? = nil,
        mediaAssetResolver: (any MediaAssetResolving)? = nil
    ) {
        self.llmInvoker = llmInvoker
        self.blenderInvoker = blenderInvoker
        self.mediaAssetResolver = mediaAssetResolver
    }

    /// 按节点类型路由（实例方法，携带注入的 LLMInvoker）。
    /// 未注册的类型返回 nil，调用方应抛 `.unknownNodeType`。
    public func executor(for nodeType: String) -> (any NodeExecutor)? {
        switch nodeType {
        case "text":
            return TextNodeExecutor()

        case "llm",
             ManjuNodeType.novelImport.rawValue,
             ManjuNodeType.plotOutline.rawValue,
             ManjuNodeType.script.rawValue,
             ManjuNodeType.storyboard.rawValue,
             ManjuNodeType.imagePrompt.rawValue,
             ManjuNodeType.videoPrompt.rawValue:
            return LLMNodeExecutor(llmInvoker: llmInvoker)

        case ManjuNodeType.qcCheck.rawValue:
            return QCNodeExecutor(llmInvoker: llmInvoker)

        case "image",
             "video",
             ManjuNodeType.imageGen.rawValue,
             ManjuNodeType.videoGen.rawValue:
            return MediaPlaceholderExecutor()

        case ManjuNodeType.blenderPreview.rawValue:
            return BlenderNodeExecutor(blenderInvoker: blenderInvoker)

        case ManjuNodeType.assetRef.rawValue:
            return AssetLockExecutor(mediaAssetResolver: mediaAssetResolver)

        case ManjuNodeType.reviewGate.rawValue:
            return ReviewGateExecutor()

        default:
            return nil
        }
    }

    /// 便捷静态路由（无注入的 LLMInvoker）。
    /// LLM 节点返回的 `LLMNodeExecutor.llmInvoker` 为 nil，执行时抛 `.missingLLMInvoker`；
    /// 正式执行请用 `NodeExecutors(llmInvoker:)` 实例方法路由。
    public static func executor(for nodeType: String) -> (any NodeExecutor)? {
        NodeExecutors().executor(for: nodeType)
    }
}

// MARK: - 具体执行器

/// text 节点：返回 inputs（原样透传）；无输入时返回固定文本。
public struct TextNodeExecutor: NodeExecutor, Sendable {

    public init() {}

    public func execute(
        node: CanvasNode,
        inputs: [String: AnyHashable]?,
        backend: NodeBackendConfig?
    ) async throws -> [String: AnyHashable] {
        if let inputs, !inputs.isEmpty {
            return inputs
        }
        // P0-2 数据链：无输入时回退读节点自身内容 params["content"]（E15/E16 写入键），
        // 双击粘贴的小说/剧情/提示词真实作为输出传给下游，不再输出固定标题。
        if let content = node.backendConfig?.params["content"], !content.isEmpty {
            return ["text": content]
        }
        // 无输入且无内容：返回固定文本（优先节点标题，避免空输出）
        let fixed = node.title.isEmpty ? "文本节点输出" : node.title
        return ["text": fixed]
    }
}

/// LLM 节点引导输出约定（P2-3 W-3）：无 key / provider 未接入时，节点输出以
/// 对应前缀开头的中文引导（"未配置 API Key：请在设置中配置，或检查环境变量"），
/// 而不是无意义的占位文本。App 层占位实现（MinisCanvasLLMInvoker）引用此前缀；
/// `LLMNodeExecutor` 的结构闸口（BLOCKED，铁律7）据此跳过引导文本——引导不是
/// LLM 产物，参与槽位校验会误伤并掩盖 key 配置引导。
public enum LLMNodeGuidance {
    /// 未配置 API Key 引导前缀
    public static let noKeyPrefix = "【未配置 API Key】"
    /// Provider 未接入引导前缀
    public static let providerUnavailablePrefix = "【未接入 Provider】"

    /// 文本是否为占位引导输出（无 key / 未接入 provider）
    public static func isGuidance(_ text: String) -> Bool {
        text.hasPrefix(noKeyPrefix) || text.hasPrefix(providerUnavailablePrefix)
    }
}

/// LLM 类节点执行器（llm + manju 7 类）：本层只做编排，不实现真实 LLM 调用。
/// prompt = `ManjuPromptTemplates.template(for:)` 的 systemPrompt + 节点 inputs 拼接，
/// 经注入的 `LLMInvoker` 调用，结果写入 `text` 输出端口。
///
/// P2-3 W-6（铁律7 产出点闸口）：imagePrompt / videoPrompt 节点输出前跑
/// `ManjuQCEvaluator` 结构闸口——8/9 槽不完整或未检测到槽位结构标记 → 输出
/// 【BLOCKED】+ 缺哪些槽，`status = "blocked"`，不输出最终提示词（缺字段 = BLOCKED）。
/// 占位引导输出（LLMNodeGuidance）不参与闸口。
public struct LLMNodeExecutor: NodeExecutor, Sendable {

    /// 注入的 LLM 调用器；nil 时 execute 抛 `.missingLLMInvoker`
    public let llmInvoker: (any LLMInvoker)?

    public init(llmInvoker: (any LLMInvoker)? = nil) {
        self.llmInvoker = llmInvoker
    }

    public func execute(
        node: CanvasNode,
        inputs: [String: AnyHashable]?,
        backend: NodeBackendConfig?
    ) async throws -> [String: AnyHashable] {
        guard let invoker = llmInvoker else {
            throw NodeExecutorsError.missingLLMInvoker(node.type)
        }
        guard let backend else {
            throw NodeExecutorsError.invalidLLMBackend(
                "\(node.type) 未配置节点级 providerID/modelID"
            )
        }
        let providerID = backend.providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !providerID.isEmpty else {
            throw NodeExecutorsError.invalidLLMBackend(
                "\(node.type) 缺少 providerID"
            )
        }
        let modelID = backend.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else {
            throw NodeExecutorsError.invalidLLMBackend(
                "\(node.type) 缺少 modelID"
            )
        }
        let config = NodeBackendConfig(
            providerType: backend.providerType,
            providerID: providerID,
            modelID: modelID,
            params: backend.params
        )
        let prompt = Self.buildPrompt(node: node, inputs: inputs)
        let text: String
        do {
            text = try await invoker.invoke(prompt: prompt, backend: config)
        } catch {
            throw NodeExecutorsError.llmInvocationFailed(String(describing: error))
        }
        // 提示词节点结构闸口（铁律7）：缺字段 = BLOCKED，不输出最终提示词
        if Self.isPromptTemplateNode(node.type), !LLMNodeGuidance.isGuidance(text) {
            let qc = ManjuQCEvaluator.evaluate(prompt: text)
            let structurallyBlocked = !qc.missingSlots.isEmpty || qc.templateKind == .unknown
            if structurallyBlocked {
                return Self.blockedOutput(qc: qc)
            }
        }
        return ["text": text, "status": "succeeded"]
    }

    /// 是否提示词模板节点（图片 8 槽 / 视频 9 槽，走结构闸口）
    static func isPromptTemplateNode(_ type: String) -> Bool {
        type == ManjuNodeType.imagePrompt.rawValue || type == ManjuNodeType.videoPrompt.rawValue
    }

    /// 构造 BLOCKED 输出：明确原因 + 缺哪些槽（铁律7），status = "blocked" 供上层标红。
    static func blockedOutput(qc: ManjuQCResult) -> [String: AnyHashable] {
        let reason: String
        if qc.templateKind == .unknown {
            reason = "未检测到 8/9 槽结构标记（铁律7：提示词必须走对应阶段槽位模板）"
        } else {
            reason = "缺字段：" + qc.missingSlots.joined(separator: "、")
        }
        let missingLines = qc.missingSlots.isEmpty
            ? "（请按模板输出 [TYPE]/[QC] 等槽位标记）"
            : qc.missingSlots.map { "- \($0)" }.joined(separator: "\n")
        let blockedText = """
        【BLOCKED】提示词结构闸口未通过（铁律7：缺字段 = BLOCKED，不输出最终提示词）

        \(reason)

        请调整节点内容补齐以下槽位后重新执行：
        \(missingLines)
        """
        return [
            "text": blockedText,
            "status": "blocked",
            "blocked": "1",
            "missing_slots": qc.missingSlots.joined(separator: "、"),
        ]
    }

    /// 组装提示词：ManjuPromptTemplates 系统提示词 + 排序后的节点输入（`端口名: 值`）。
    /// 未知 manju 类型（如通用 "llm"）退回通用系统提示词。
    public static func buildPrompt(
        node: CanvasNode,
        inputs: [String: AnyHashable]?
    ) -> String {
        let systemPrompt: String
        if let manjuType = ManjuNodeType(rawValue: node.type),
           let template = ManjuPromptTemplates.template(for: manjuType) {
            systemPrompt = template.systemPrompt
        } else {
            systemPrompt = Self.genericSystemPrompt
        }

        var parts = [systemPrompt]
        var sortedInputs = (inputs ?? [:]).sorted { $0.key < $1.key }
        // P0-2 数据链兜底：无上游输入时读节点自身内容 params["content"]（E15/E16 写入键），
        // 保证直接调 buildPrompt（未走 resolveInputs）时双击粘贴的内容也进入提示词。
        if sortedInputs.isEmpty,
           let content = node.backendConfig?.params["content"],
           !content.isEmpty {
            sortedInputs = [("text", AnyHashable(content))]
        }
        for (name, value) in sortedInputs {
            parts.append("\(name): \(String(describing: value))")
        }
        return parts.joined(separator: "\n\n")
    }

    /// 通用 LLM 节点系统提示词（未命中 manju 模板时使用）
    public static let genericSystemPrompt = """
    你是漫剧画布上的通用 LLM 节点。职责：按上游输入完成文本处理。
    遵守 manju-core 铁律：只输出任务要求的内容，不输出与任务无关的描述；输出前自检。
    """
}

/// image/video/imageGen/videoGen 占位执行器：返回 inputs 原样 + `status` 标记。
/// 真实生成 API 由 M2b 云端后端 / 本地后端（ComfyUI/SD/Wan/可灵/即梦）接入。
public struct MediaPlaceholderExecutor: NodeExecutor, Sendable {

    public init() {}

    public func execute(
        node: CanvasNode,
        inputs: [String: AnyHashable]?,
        backend: NodeBackendConfig?
    ) async throws -> [String: AnyHashable] {
        var output = inputs ?? [:]
        output["status"] = "placeholder"
        return output
    }
}

/// blenderPreview 节点执行器（M3b）：真实调用注入的 BlenderRenderInvoker 做白模渲染。
/// - script 输入：Python 脚本内容或本地路径（存在则读文件）；缺失时兜底
///   ManjuPromptTemplates.blenderPreview 模板的 systemPrompt
/// - outputDir 输入：渲染输出目录；缺失时用系统临时目录下 miniscanvas_blender_output
/// - 输出：["images": PNG 路径列表] + status
public struct BlenderNodeExecutor: NodeExecutor, Sendable {

    /// 注入的 Blender 渲染调用器；nil 时 execute 抛 `.missingBlenderInvoker`
    public let blenderInvoker: (any BlenderRenderInvoker)?

    public init(blenderInvoker: (any BlenderRenderInvoker)? = nil) {
        self.blenderInvoker = blenderInvoker
    }

    public func execute(
        node: CanvasNode,
        inputs: [String: AnyHashable]?,
        backend: NodeBackendConfig?
    ) async throws -> [String: AnyHashable] {
        guard let invoker = blenderInvoker else {
            throw NodeExecutorsError.missingBlenderInvoker(node.type)
        }
        let script = try Self.resolveScript(node: node, inputs: inputs)
        let outputDir = Self.resolveOutputDir(inputs: inputs)
        let frameRange = Self.resolveFrameRange(inputs: inputs)

        let pngs: [String]
        do {
            pngs = try await invoker.render(
                script: script, outputDir: outputDir, frameRange: frameRange
            )
        } catch {
            throw NodeExecutorsError.blenderInvocationFailed(String(describing: error))
        }
        return ["images": pngs, "status": "succeeded"]
    }

    /// 解析渲染脚本：优先 inputs 的 script（内容或路径），其次 ManjuPromptTemplates 的
    /// blenderPreview 模板 systemPrompt；都缺失抛 `.missingBlenderScript`。
    /// 兼容画布注册表把脚本端口命名为 text 的情况（NodeTypeRegistry.blenderPreview 的输入端口是 text）。
    static func resolveScript(node: CanvasNode, inputs: [String: AnyHashable]?) throws -> String {
        let raw = inputs?["script"] ?? inputs?["text"]
        if let raw {
            let text = String(describing: raw)
            if !text.isEmpty {
                // 是本地文件路径 → 读取内容；否则视为脚本内容
                if FileManager.default.fileExists(atPath: text),
                   let content = try? String(contentsOfFile: text, encoding: .utf8) {
                    return content
                }
                return text
            }
        }
        if let template = ManjuPromptTemplates.template(for: .blenderPreview) {
            return template.systemPrompt
        }
        throw NodeExecutorsError.missingBlenderScript(node.type)
    }

    /// 解析输出目录：inputs 的 outputDir；缺失时用系统临时目录下的 miniscanvas_blender_output。
    static func resolveOutputDir(inputs: [String: AnyHashable]?) -> String {
        if let raw = inputs?["outputDir"], let dir = raw as? String, !dir.isEmpty {
            return dir
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("miniscanvas_blender_output").path
    }

    /// 解析可选帧范围：inputs 的 frameStart/frameEnd（Int），任一缺失返回 nil。
    static func resolveFrameRange(inputs: [String: AnyHashable]?) -> (Int, Int)? {
        guard let start = inputs?["frameStart"] as? Int,
              let end = inputs?["frameEnd"] as? Int else { return nil }
        return (start, end)
    }
}

/// qcCheck 节点执行器（A5）：确定性本地 QC 判定，不依赖 LLM / Ollama。
/// 输入与 UI 端口契约（ManjuNodeType.qcCheckInputPorts = image/text/video）严格一致：
/// `video`（上游 videoGen 成片——模板主链 videoGen.video → qcCheck.video；P2-2 降级时承载
/// 任务单文本）、`text`/`prompt`（提示词/任务单文本，prompt 为文本族兼容别名）、
/// `image`/`image1…image9`（多路待审图，B2 动态槽）。
/// 经 `ManjuQCEvaluator` 做结构闸口（铁律7）+ 审美闸口 S1-S5 + 三刻度盘校验，
/// 输出 `report`（完整报告）、`status`（PASS/FAIL/待生成后复检）两个 UI 端口，
/// 以及只读审计详情键（qc_status/images_reviewed/dial_variance/dial_motion/dial_density/
/// reasons/missing_slots，见 ManjuNodeType.qcCheckAuditDetailKeys）——随 report 写回节点内容、
/// 状态色与聊天回执呈现，不设独立端口。
/// 注：`llmInvoker` 保留字段，后续接 LLM 深度审片时可追加（当前判定完全本地确定性）。
public struct QCNodeExecutor: NodeExecutor, Sendable {

    /// 注入的 LLM 调用器（当前未使用，为后续 LLM 深度审片保留）
    public let llmInvoker: (any LLMInvoker)?

    public init(llmInvoker: (any LLMInvoker)? = nil) {
        self.llmInvoker = llmInvoker
    }

    public func execute(
        node: CanvasNode,
        inputs: [String: AnyHashable]?,
        backend: NodeBackendConfig?
    ) async throws -> [String: AnyHashable] {
        // P2-2-fix：生图/生视频无 key 降级任务单识别。
        // 上游 image/video 节点降级时输出 jobTicket markdown（含「生成任务单」标记），
        // 该文本是提示词/占位产物而非最终成片——不做成片校验，输出状态「待生成后复检」，
        // 避免 QC 对任务单文本误判 FAIL（不阻塞画布，与降级任务单同一哲学）。
        if Self.isJobTicketInput(inputs) {
            return [
                "report": "输入为生成任务单（无 API key 降级模式）：不校验成片，待真实生成后复检。",
                "status": "待生成后复检",
                "qc_status": "待生成后复检",
                "job_ticket": "1",
            ]
        }

        // 输入：上游提示词文本（prompt/text）或产物（video/image）；取第一个非空。
        // B2 动态多输入：qcCheck 支持 image/image1/…/image9 多路输入，全部计入审图范围。
        let imageKeys = ["image"] + (1..<10).map { "image\($0)" }
        let reviewedImages = imageKeys.compactMap { key -> String? in
            guard let raw = inputs?[key].map({ String(describing: $0) }) else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let text = (["prompt", "text", "video"] + imageKeys).lazy
            .compactMap { inputs?[$0].map { String(describing: $0) } }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        let result = ManjuQCEvaluator.evaluate(prompt: text)

        var output: [String: AnyHashable] = [
            "report": result.report,
            "status": result.status.rawValue,
            "qc_status": result.status.rawValue,
        ]
        // B2：多路图片输入审计信息（下游可据 image_count 判断是否逐张复检）
        if reviewedImages.count > 1 {
            output["images_reviewed"] = reviewedImages.count
        }
        if let dials = result.dials {
            output["dial_variance"] = dials.variance
            output["dial_motion"] = dials.motion
            output["dial_density"] = dials.density
        }
        if !result.reasons.isEmpty {
            output["reasons"] = result.reasons.joined(separator: "\n")
        }
        if !result.missingSlots.isEmpty {
            output["missing_slots"] = result.missingSlots.joined(separator: "、")
        }
        return output
    }

    /// 判定输入是否为任务单（job_ticket 降级输出）：
    /// - 输入端口名为 jobTicket / job_ticket（直连任务单端口），或
    /// - 任一输入值文本含任务单标记「生成任务单」（生图/生视频降级 markdown 标题）
    private static func isJobTicketInput(_ inputs: [String: AnyHashable]?) -> Bool {
        guard let inputs else { return false }
        if inputs.keys.contains(where: { $0.lowercased() == "jobticket" || $0.lowercased() == "job_ticket" }) {
            return true
        }
        return inputs.values.contains { String(describing: $0).contains("生成任务单") }
    }
}

/// assetRef 节点执行器（A5）：资产锁定接线。
/// 资产锁定摘要由 ManjuPipelineTemplate 在创建流水线时注入节点
/// `backendConfig.params[ManjuAssetInjection.assetRefSummaryKey]`（ManjuAssets API）；
/// 执行时把锁定摘要 + 参考图清单输出到 `assets` 端口，供下游提示词节点引用
/// （铁律2：只写锁定清单，不重复描述；铁律6：已被资产锁定的信息不重复描述）。
public struct AssetLockExecutor: NodeExecutor, Sendable {
    private let mediaAssetResolver: (any MediaAssetResolving)?

    public init(mediaAssetResolver: (any MediaAssetResolving)? = nil) {
        self.mediaAssetResolver = mediaAssetResolver
    }

    public func execute(
        node: CanvasNode,
        inputs: [String: AnyHashable]?,
        backend: NodeBackendConfig?
    ) async throws -> [String: AnyHashable] {
        var output = inputs ?? [:]

        // 资产锁定摘要（ManjuAssets 注入的 asset.summary）
        let summary = node.backendConfig?.params[ManjuAssetInjection.assetRefSummaryKey]
            ?? node.backendConfig?.params[ManjuAssetInjection.lockedFlagKey].map { _ in "" }
            ?? ""
        if !summary.isEmpty {
            output["assets"] = summary
            output["summary"] = summary
            // 参考图锁定清单（从摘要中的 参考图：/母图：/垫图： 行提取，铁律2）
            let refs = ManjuTicketParser.extractReferenceIDs(from: summary)
            if !refs.isEmpty {
                output["referenceImages"] = refs
            }
        } else {
            output["assets"] = "（未注入资产锁定摘要：请在资产库更新后重建流水线，ManjuAssetInjection.applyLockedAssets）"
        }

        // P0 资产层承载图：真实图片路径（定妆图/服装/场景母图，模板注入 asset.images JSON）
        // → 输出 imagePaths 供下游 img2img 节点作为参考图（U2 image 输入端口语义）。
        // 另并入「挂载图片」（B7 加载到画布/导入图片写入 result.kind=image + result.path），
        // 挂载媒体优先，去重保序——挂载图片同样可被下游 img2img 消费。
        let templateImages = ManjuPipelineTemplate.parseAssetImages(
            node.backendConfig?.params[ManjuPipelineTemplate.assetImagesKey]
        )
        var mountedImages: [String] = []
        if let mediaAssetID = node.mediaAssetID,
           let asset = await mediaAssetResolver?.asset(id: mediaAssetID),
           asset.kind == .image,
           asset.status != .deleted,
           let p = asset.localURL ?? asset.remoteURL,
           !p.isEmpty {
            mountedImages = [p]
        } else if node.assetKind == .image, let p = node.assetMediaPath, !p.isEmpty {
            mountedImages = [p]
        }
        let imagePaths = Self.deduplicated(mountedImages + templateImages)
        if !imagePaths.isEmpty {
            output["imagePaths"] = imagePaths
            // B7：image 输出端口取值（与 video 端口同语义：单端口连线取首条，
            // 供 img2img 参考图输入端口接线；imagePaths 保留全量）。
            output["image"] = imagePaths[0]
        }

        // B2 视频承载：真实视频路径（角色/服装/场景参考视频，模板注入 asset.videos JSON）
        // → 输出 videoPaths（全量，V2V 多参考视频）+ video（首条，经 assetRef.video
        // 输出端口取值，单端口连线语义：连到生视频节点的 video/video1/… 输入端口）。
        // 另并入「挂载视频」（B7 加载到画布/导入视频写入 result.kind=video + result.path），
        // 挂载视频优先——资产节点挂载的视频资产同样经 video 输出端口被下游 videoGen 消费。
        let templateVideos = ManjuPipelineTemplate.parseAssetVideos(
            node.backendConfig?.params[ManjuPipelineTemplate.assetVideosKey]
        )
        var mountedVideos: [String] = []
        if let mediaAssetID = node.mediaAssetID,
           let asset = await mediaAssetResolver?.asset(id: mediaAssetID),
           asset.kind == .video,
           asset.status != .deleted,
           let p = asset.localURL ?? asset.remoteURL,
           !p.isEmpty {
            mountedVideos = [p]
        } else if node.assetKind == .video, let p = node.assetMediaPath, !p.isEmpty {
            mountedVideos = [p]
        }
        let videoPaths = Self.deduplicated(mountedVideos + templateVideos)
        if !videoPaths.isEmpty {
            output["videoPaths"] = videoPaths
            output["video"] = videoPaths[0]
        }

        output["locked"] = "1"
        output["status"] = "succeeded"
        return output
    }

    /// 媒体路径去重保序（挂载媒体优先；模板全量与挂载路径重叠时保留首现）
    static func deduplicated(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }
}

/// reviewGate 节点执行器：审核闸口（待审黄/通过青/打回红；未通过下游不执行）。
/// 确定性本地判定，不依赖 LLM / Ollama：
/// - 输入 text（回退 prompt）为空或全空白 → `status = "PENDING"`（待审，不产出 pass）
/// - 文本含 "BLOCKED" 或 "（待填）" → `status = "REJECT"` + `reasons`（打回原因，可多条）
/// - 其余 → `status = "PASS"` 且输出 `pass = 原文`（放行给下游）
/// 输出键：`pass` / `status` / `reasons`（仅 REJECT 时输出）。
/// 与 ManjuNodeType.reviewGateOutputPorts（pass/status）一致；下游可据 status 决定是否继续执行。
public struct ReviewGateExecutor: NodeExecutor, Sendable {

    /// 打回标记：文本含 BLOCKED（上游结构闸口未通过产物）
    static let blockedMarker = "BLOCKED"
    /// 打回标记：文本含「（待填）」占位符（模板占位未填）
    static let pendingMarker = "（待填）"

    public init() {}

    public func execute(
        node: CanvasNode,
        inputs: [String: AnyHashable]?,
        backend: NodeBackendConfig?
    ) async throws -> [String: AnyHashable] {
        // 输入：审核文本（单份审核放行语义）；回退 prompt 端口。
        let raw = inputs?["text"] ?? inputs?["prompt"]
        let text = raw.map { String(describing: $0) } ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 空 / 全空白 → 待审（无内容可放行，下游不执行）
        if trimmed.isEmpty {
            return ["status": "PENDING"]
        }

        // 含打回标记 → REJECT + 原因清单
        var reasons: [String] = []
        if text.contains(Self.blockedMarker) {
            reasons.append("文本含 BLOCKED 标记（上游结构闸口未通过，需修复后重新执行）")
        }
        if text.contains(Self.pendingMarker) {
            reasons.append("文本含占位符「（待填）」，内容未填写完整")
        }
        if !reasons.isEmpty {
            return [
                "pass": text,
                "status": "REJECT",
                "reasons": reasons.joined(separator: "\n"),
            ]
        }

        // 其余 → PASS，放行原文给下游
        return ["pass": text, "status": "PASS"]
    }
}
