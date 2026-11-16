import Foundation

// MARK: - 同步桥接（DAGScheduler 的 NodeExecutionContext 是同步协议）

/// 线程安全的结果盒：存放 async 执行器的一次执行结果
private final class SyncResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<[String: AnyHashable], Error>?

    func set(_ result: Result<[String: AnyHashable], Error>) {
        lock.lock(); defer { lock.unlock() }
        stored = result
    }

    func get() throws -> [String: AnyHashable] {
        lock.lock(); defer { lock.unlock() }
        guard let stored else {
            throw NodeExecutorsError.llmInvocationFailed("同步桥接未返回结果")
        }
        return try stored.get()
    }
}

/// 非 Sendable 输入值（AnyHashable）的安全包装，供 @Sendable Task 闭包捕获
private final class InputBox: @unchecked Sendable {
    let value: [String: AnyHashable]?
    init(_ value: [String: AnyHashable]?) { self.value = value }
}

/// 阻塞式 async → sync 桥接：把异步执行器调用转成同步返回。
///
/// 仅供 DAGScheduler 同步协议路径使用（协议 `execute` 为同步签名，无法绕过）。
/// ⚠️ 会阻塞调用线程：若在主线程调用，主线程会等待生图/LLM 完成。
/// 用 `Task.detached` 启动异步工作（不继承调用方 actor 隔离）——
/// 即使调用方是 @MainActor（如集成 App 的 CanvasStore），也不会因主线程
/// 阻塞等待而产生死锁（I5 P0-3）。应用层应尽量在后台 Task 中调用调度。
private func syncAwaitExecute(
    _ operation: @escaping @Sendable () async throws -> [String: AnyHashable]
) throws -> [String: AnyHashable] {
    let semaphore = DispatchSemaphore(value: 0)
    let box = SyncResultBox()
    Task.detached {
        do {
            let value = try await operation()
            box.set(.success(value))
        } catch {
            box.set(.failure(error))
        }
        semaphore.signal()
    }
    semaphore.wait()
    return try box.get()
}

// MARK: - 生视频调用注入点（P2-2 P0-3：与生图 ImageGenerating 对称）

/// 生视频执行结果：真实视频路径/URL，或无后端时降级产出的任务单（提示词全文 + markdown 导出）。
///
/// 任务单模式（与生图同哲学）：用户没有可灵/即梦 API key 时，画布不抛错、不阻塞——
/// 节点输出视频 9 槽任务单，用户复制到网页版手动生成后「导入结果」回填。
public enum VideoGenerationOutcome: Sendable, Equatable {
    /// 真实生成成功：视频 URL 或本地文件路径
    case video(path: String)
    /// 真实生成成功并已写入 durable ArtifactStore；artifactID 是稳定跨重启引用。
    case videoWithArtifact(path: String, artifactID: String)
    /// 无 key / 无 invoker 降级：任务单（提示词全文 + markdown 导出文本）
    case jobTicket(prompt: String, markdown: String)
}

/// 生视频调用注入点：CanvasCore 只做编排，不实现真实生视频。
/// 真实实现（走 MinisCore `CloudVideoGenerator`：可灵 Kling / 即梦 Jimeng，submit+poll）由上层注入。
public protocol VideoGenerating: Sendable {
    /// 执行一次生视频调用。
    /// - Parameters:
    ///   - node: 生视频节点（标题/后端配置参与任务单构建）
    ///   - prompt: 完整提示词（来自上游视频提示词节点）
    ///   - firstFrame: 首帧参考图（I2V 用；来自上游 image 输入端口，可为 nil）
    ///   - backend: 节点级模型配置（nil 时由调用方提供默认配置）
    /// - Returns: `.video(path:)` 真实生成 / `.jobTicket(prompt:markdown:)` 无 key 降级
    func generate(
        node: CanvasNode,
        prompt: String,
        firstFrame: String?,
        backend: NodeBackendConfig?
    ) async throws -> VideoGenerationOutcome

    /// Envelope-aware production bridge. Existing invokers retain the legacy
    /// behavior through the default implementation.
    func generate(
        node: CanvasNode,
        prompt: String,
        firstFrame: String?,
        backend: NodeBackendConfig?,
        executionEnvelope: DAGExecutionEnvelope?
    ) async throws -> VideoGenerationOutcome
}

extension VideoGenerating {
    public func generate(
        node: CanvasNode,
        prompt: String,
        firstFrame: String?,
        backend: NodeBackendConfig?,
        executionEnvelope: DAGExecutionEnvelope?
    ) async throws -> VideoGenerationOutcome {
        try await generate(
            node: node,
            prompt: prompt,
            firstFrame: firstFrame,
            backend: backend
        )
    }
}

// MARK: - 图执行上下文（真实执行链路，协议下沉 CanvasCore）

/// 画布「执行」按钮的真实执行上下文：实现 `NodeExecutionContext` 协议。
/// - resolveInputs：按边从上游节点输出收集端口对应值
/// - execute：按节点类型路由到 NodeExecutors 中的执行器（text/llm/image/video/manju 各类）
/// - LLM / 生图 / Blender 全部经协议注入（`LLMInvoker` / `ImageGenerating` /
///   `BlenderRenderInvoker`），CanvasCore 只做编排，真实实现由各 App 层提供
/// - 记录每个节点的最近一次执行错误（供 UI 失败提示）
///
/// A3 增强：
/// - `executeAsync`：真异步执行路径（直接 await，不经过同步桥、不阻塞任何线程）；
///   生图节点调 `ImageGenerating`（本身 async），主线程在等待期间可自由响应
/// - 失败路径接 NodeDiagnostics + AgentRepairBridge：节点失败时收集脱敏诊断上下文，
///   若有 repairProvider 则获取修复建议，写入 `repairSuggestions`（不自动应用，供用户查看）。
/// - 线程安全：跨 Task 访问的可变状态（lastErrors / repairSuggestions / lastGraph）
///   用 NSLock 保护（类标记 @unchecked Sendable）。
public final class GraphExecutionContext:
    NodeExecutionContext,
    DAGExecutionEnvelopeNodeExecutionContext,
    @unchecked Sendable {
    /// 执行器注册表（携带注入的 LLMInvoker / BlenderRenderInvoker）
    private let executors: NodeExecutors
    /// 生图节点真实调用器（协议注入）：调 MinisCore Gimage2Provider 生图；无 key 时降级任务单
    public let imageInvoker: any ImageGenerating
    /// 生视频节点真实调用器（协议注入，P2-2 P0-3）：调 MinisCore CloudVideoGenerator
    /// （可灵 Kling / 即梦 Jimeng，submit+poll）；nil = 未注入，videoGen 节点降级 9 槽任务单
    public let videoInvoker: (any VideoGenerating)?
    /// Agent 修复提供方（nil = 未配置修复桥，失败仅记录错误与诊断）
    public var repairProvider: (any AgentRepairProvider)? {
        get { withStateLock { _repairProvider } }
        set { withStateLock { _repairProvider = newValue } }
    }
    /// 手动导入的结果（M1f 任务单模式：「导入结果」按钮回填的文件路径）。
    /// nodeID → 输出端口名 → 值；resolveInputs 时优先于调度器缓存，保证下游节点
    /// （如生视频的 image 首帧输入）能读到导入的文件路径。
    /// 容器读写与复合下标更新均在 stateLock 内；resolveInputs 每次只取一个快照。
    /// 这不将 AnyHashable 内部任意引用对象变成 Sendable，调用方仍须发布不可变值。
    public var importedOutputs: [UUID: [String: AnyHashable]] {
        get { withStateLock { _importedOutputs } }
        set { withStateLock { _importedOutputs = newValue } }
        _modify {
            stateLock.lock()
            defer { stateLock.unlock() }
            yield &_importedOutputs
        }
    }

    // MARK: 线程安全状态

    private let stateLock = NSLock()
    private var _importedOutputs: [UUID: [String: AnyHashable]] = [:]
    private var _repairProvider: (any AgentRepairProvider)?
    private var _lastErrors: [UUID: String] = [:]
    private var _repairSuggestions: [UUID: RepairSuggestion] = [:]
    /// 最近一次 resolveInputs 的图（失败诊断时计算上游输出端口；非调度路径为 nil）
    private var _lastGraph: NodeGraph?

    /// 同步加锁执行闭包。NSLock.lock/unlock 在 async 上下文中被标记 unavailable，
    /// 故经此同步辅助函数中转（等价 NSLocking.withLock，兼容 macOS 14 部署目标）。
    private func withStateLock<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }

    /// 节点最近一次执行错误（成功执行后清空；UI 据此显示失败原因）
    public var lastErrors: [UUID: String] {
        withStateLock { _lastErrors }
    }

    /// 节点失败时由 Agent 修复桥产出的修复建议（nodeID → 建议；成功执行后清空）。
    /// 只记录、不自动应用——供 UI 展示给用户决定是否采纳（A3）。
    public var repairSuggestions: [UUID: RepairSuggestion] {
        withStateLock { _repairSuggestions }
    }

    public init(
        executors: NodeExecutors,
        imageInvoker: any ImageGenerating,
        videoInvoker: (any VideoGenerating)? = nil,
        repairProvider: (any AgentRepairProvider)? = nil
    ) {
        self.executors = executors
        self.imageInvoker = imageInvoker
        self.videoInvoker = videoInvoker
        self._repairProvider = repairProvider
    }

    /// 按边解析输入：上游输出端口名 → 本节点输入端口名。
    ///
    /// U2 执行链修复：上游输出按端口名取值，文本族端口（text/prompt）额外做别名回退——
    /// LLM/文本/提示词节点执行器（LLMNodeExecutor / TextNodeExecutor）实际写出的输出键是
    /// `text`，而部分模板把提示词节点的输出端口命名为 `prompt`（ManjuPipelineTemplate 的
    /// imagePrompt/videoPrompt），按端口名严格取值会取空 → 下游生成节点 prompt 永远为空。
    /// 别名回退保证上游 LLM/文本节点输出不因端口名/键名漂移而丢失（见 `portValue`）。
    public func resolveInputs(
        for node: CanvasNode,
        in graph: NodeGraph,
        outputs: @escaping (UUID) -> [String: AnyHashable]?
    ) throws -> [String: AnyHashable]? {
        let importedSnapshot = withStateLock {
            _lastGraph = graph
            return _importedOutputs
        }
        var result: [String: AnyHashable] = [:]
        for edge in graph.incomingEdges(to: node.id) {
            guard
                let toPort = node.inputs.first(where: { $0.id == edge.toPort }),
                let fromNode = graph.node(id: edge.fromNode),
                let fromPort = fromNode.outputs.first(where: { $0.id == edge.fromPort })
            else { continue }
            // 优先取手动导入的结果（导入结果回填），其次取调度器缓存的上游输出
            let value: AnyHashable?
            if let imported = importedSnapshot[edge.fromNode],
               let v = Self.portValue(in: imported, portName: fromPort.name) {
                value = v
            } else {
                value = outputs(edge.fromNode).flatMap { Self.portValue(in: $0, portName: fromPort.name) }
            }
            guard let value else { continue }
            result[toPort.name] = value
        }
        // P0-2 数据链打通：源节点（无输入边）回退读节点自身内容 params["content"]
        // （E15 双击编辑器 / E16 聊天指令写入键），作为该节点输入传给执行器——
        // 双击粘贴的小说/剧情/提示词真实进入 buildPrompt，不再从源头丢失。
        if result.isEmpty && graph.incomingEdges(to: node.id).isEmpty {
            if let content = node.backendConfig?.params["content"],
               !content.isEmpty {
                result["text"] = content
            }
        }
        return result.isEmpty ? nil : result
    }

    /// U2 执行链修复：按端口名在上游输出字典中取值，文本族输入端口带别名回退。
    ///
    /// 端口名严格命中优先；未命中且端口名不是媒体/结构化端口（`mediaPortNames`）时，
    /// 依次回退上游文本族输出键 `text` → `prompt`（LLM/文本执行器实际写出的键）。
    /// 根因：模板把中间节点输出端口命名为语义名（imagePrompt/videoPrompt 的 `prompt`、
    /// storyboard→提示词的 `storyboard` 输入），而执行器写出的输出键固定是 `text`——
    /// 严格按键取值会取空，上游 LLM/文本节点输出在链路上丢失，下游生图 prompt 恒为空。
    /// image/video/frames/blocking/assets 等媒体/结构化端口仍严格按端口名取值，
    /// 不做跨端口语义污染（文本不得流入首帧/成片输入）。
    static func portValue(in outputs: [String: AnyHashable], portName: String) -> AnyHashable? {
        if let value = outputs[portName] { return value }
        guard !mediaPortNames.contains(portName) else { return nil }
        for alias in ["text", "prompt"] {
            if let value = outputs[alias] { return value }
        }
        return nil
    }

    /// 媒体/结构化端口名：取值严格按端口名，不做文本族别名回退。
    /// image（首帧/参考图/成片）、video（成片）、frames（帧序列）、
    /// blocking（Blender 白模 PNG 列表）、assets（资产锁定注入）。
    static let mediaPortNames: Set<String> = ["image", "video", "frames", "blocking", "assets"]

    /// 同步协议实现：桥接到真异步路径（DAGScheduler.run 同步调度时使用）。
    /// ⚠️ 同步桥会阻塞调用线程——调用方应在后台 Task 中跑调度，避免主线程卡顿（A3）。
    /// 桥接用 `Task.detached` 启动，不继承 MainActor 隔离（I5 P0-3 防死锁）。
    public func execute(node: CanvasNode, inputs: [String: AnyHashable]?) throws -> [String: AnyHashable] {
        try execute(node: node, inputs: inputs, executionEnvelope: nil)
    }

    public func execute(
        node: CanvasNode,
        inputs: [String: AnyHashable]?,
        executionEnvelope: DAGExecutionEnvelope
    ) throws -> [String: AnyHashable] {
        try execute(node: node, inputs: inputs, executionEnvelope: Optional(executionEnvelope))
    }

    private func execute(
        node: CanvasNode,
        inputs: [String: AnyHashable]?,
        executionEnvelope: DAGExecutionEnvelope?
    ) throws -> [String: AnyHashable] {
        let inputBox = InputBox(inputs)
        return try syncAwaitExecute {
            try await self.executeAsync(
                node: node,
                inputs: inputBox.value,
                executionEnvelope: executionEnvelope
            )
        }
    }

    /// 真异步执行入口（A3）：直接 await，不阻塞调用线程。
    ///
    /// 生图节点（image / imageGen）走 `ImageGenerating` 真实链路（本身 async），
    /// 其余类型路由到 NodeExecutors 注册表。失败时收集诊断 + 调 Agent 修复桥，
    /// 建议写入 `repairSuggestions[node.id]`（不自动应用）。
    public func executeAsync(
        node: CanvasNode,
        inputs: [String: AnyHashable]?,
        executionEnvelope: DAGExecutionEnvelope? = nil
    ) async throws -> [String: AnyHashable] {
        let backend = node.backendConfig
        do {
            let output: [String: AnyHashable]
            if node.type == "image" || node.type == ManjuNodeType.imageGen.rawValue {
                output = try await Self.executeImage(
                    node: node, inputs: inputs, backend: backend, invoker: imageInvoker
                )
            } else if node.type == "video" || node.type == ManjuNodeType.videoGen.rawValue {
                output = try await Self.executeVideo(
                    node: node,
                    inputs: inputs,
                    backend: backend,
                    invoker: videoInvoker,
                    executionEnvelope: executionEnvelope
                )
            } else {
                guard let executor = executors.executor(for: node.type) else {
                    throw NodeExecutorsError.unknownNodeType(node.type)
                }
                output = try await executor.execute(node: node, inputs: inputs, backend: backend)
            }
            recordSuccess(nodeID: node.id)
            return output
        } catch {
            await recordFailure(node: node, error: error, inputs: inputs)
            throw error
        }
    }

    /// U2 执行链修复：从输入字典解析提示词文本。
    /// 先读 `prompt` 键（生成节点输入端口规范名），再回退 `text` 键（上游 LLM/文本/提示词
    /// 节点输出端口规范名——LLMNodeExecutor 实际写出的键）。旧图数据或手工连线可能把
    /// 上游 text 输出直接接到生成节点同名 text 输入端口；两个键名都兼容，保证上游
    /// LLM/文本节点的输出不因端口名/键名漂移而丢失（与 BlenderNodeExecutor 兼容
    /// text 端口取脚本同一策略）。
    static func resolvePromptText(from inputs: [String: AnyHashable]?) -> String {
        for key in ["prompt", "text"] {
            guard let raw = inputs?[key] else { continue }
            let text = String(describing: raw)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return ""
    }

    /// U2：解析上游 `image` 输入端口的参考图（本地路径/URL，含「导入结果」回填的路径）。
    /// 空字符串视为未传入（返回 nil）。
    static func resolveReferenceImage(from inputs: [String: AnyHashable]?) -> String? {
        guard let raw = inputs?["image"] else { return nil }
        let text = String(describing: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// B2：解析上游多路 `video` 输入端口（video/video1/…/video9，V2V 参考视频）。
    /// 空值跳过；保序去重。供 executeVideo 注入后端配置（键 `referenceVideos`，JSON 数组）
    /// 与任务单（无 key 降级时列出参考视频清单，用户手动上传）。
    static func resolveReferenceVideos(from inputs: [String: AnyHashable]?) -> [String] {
        let keys = ["video"] + (1..<10).map { "video\($0)" }
        var seen = Set<String>()
        return keys.compactMap { key -> String? in
            guard let raw = inputs?[key] else { return nil }
            let text = String(describing: raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, seen.insert(text).inserted else { return nil }
            return text
        }
    }

    /// AJ-18：解析上游 `duration` 输入端口的镜头时长（如 "5s"/"10s"）。
    /// 空字符串视为未传入（返回 nil）。时长输入端口覆盖节点默认时长配置（backend.params["duration"]）。
    static func resolveDuration(from inputs: [String: AnyHashable]?) -> String? {
        guard let raw = inputs?["duration"] else { return nil }
        let text = String(describing: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// AJ-18：把 duration 输入端口值合并进 backend 配置（覆盖节点默认时长）。
    /// 返回新的 backend（含 duration 参数），供生视频 invoker 与任务单构建读取。
    /// backend 为 nil 时构造一个仅含 duration 的最小配置。
    static func mergedBackend(backend: NodeBackendConfig?, duration: String?) -> NodeBackendConfig? {
        guard let duration, !duration.isEmpty else { return backend }
        var merged = backend ?? NodeBackendConfig()
        merged.params["duration"] = duration
        return merged
    }

    /// 生图节点真实执行（U2：文生图 + 图生图）：
    /// prompt 从上游输入取（兼容 prompt/text 键名，见 `resolvePromptText`）→
    /// `ImageGenerating`（Gimage2Provider）生成；上游传入 image 输入端口时走 img2img
    /// 语义，prompt + image 一起传给 invoker。
    /// - 有 key：输出 `["image": 路径/URL, "provider": "gimage2", "status": "succeeded",
    ///   "mode": "txt2img"/"img2img"]`
    /// - 无 key 降级：输出 JobTicket 提示词（`"jobTicket"` markdown + `"image"`/`"prompt"` 全文），
    ///   `status = "job_ticket"`，节点标记成功，不阻塞画布（任务单语义保持不变，U2）
    private static func executeImage(
        node: CanvasNode,
        inputs: [String: AnyHashable]?,
        backend: NodeBackendConfig?,
        invoker: any ImageGenerating
    ) async throws -> [String: AnyHashable] {
        let prompt = resolvePromptText(from: inputs)
        let referenceImage = resolveReferenceImage(from: inputs)
        switch try await invoker.generate(node: node, prompt: prompt, image: referenceImage, backend: backend) {
        case .image(let path):
            return [
                "image": path,
                "provider": "gimage2",
                "status": "succeeded",
                "mode": referenceImage == nil ? "txt2img" : "img2img",
            ]
        case .jobTicket(let prompt, let markdown):
            return [
                "image": prompt,
                "prompt": prompt,
                "jobTicket": markdown,
                "provider": "gimage2",
                "status": "job_ticket",
            ]
        }
    }

    /// 生视频节点真实执行（P2-2 P0-3）：prompt 从上游输入取、首帧取 image 输入端口。
    /// - 有 videoInvoker（Kling/Jimeng）且已配置：`CloudVideoGenerator` submit+poll 真实生成，
    ///   输出 `["video": 路径/URL, "provider": ..., "status": "succeeded"]`
    /// - 无 invoker / 无 key / 未接入 provider：降级视频 9 槽任务单（`"jobTicket"` markdown +
    ///   `"video"`/`"prompt"` 全文），`status = "job_ticket"`，节点标记成功，不阻塞画布——
    ///   与生图节点无 key 降级同一哲学；QC 下游据此标「待生成后复检」。
    private static func executeVideo(
        node: CanvasNode,
        inputs: [String: AnyHashable]?,
        backend: NodeBackendConfig?,
        invoker: (any VideoGenerating)?,
        executionEnvelope: DAGExecutionEnvelope? = nil
    ) async throws -> [String: AnyHashable] {
        let prompt = resolvePromptText(from: inputs)
        // 首帧透传受生成模式（backend.params["mode"]）控制：
        //   i2v 图生视频（默认）/ r2v 首尾帧 → 透传 image 输入端口为首帧；
        //   t2v 文生视频 → 忽略 image 输入（即使上游接了参考图也不当首帧），
        //   由 provider 走纯文生视频端点（可灵 text-to-video / 即梦无首帧变体）。
        var firstFrame = resolveReferenceImage(from: inputs)
        // B2：多路参考视频输入（video/video1/…/video9，V2V）→ JSON 注入 backend.params
        // （invoker 读取键 `referenceVideos`；无 key 降级任务单列出清单供手动上传）
        let referenceVideos = resolveReferenceVideos(from: inputs)
        // AJ-18：duration 输入端口覆盖节点默认时长配置，供 invoker 请求与任务单构建读取
        let duration = resolveDuration(from: inputs)
        var effectiveBackend = mergedBackend(backend: backend, duration: duration)
        if effectiveBackend?.params["mode"] == "t2v" {
            firstFrame = nil
        }
        if !referenceVideos.isEmpty {
            var merged = effectiveBackend ?? NodeBackendConfig()
            if let data = try? JSONSerialization.data(withJSONObject: referenceVideos),
               let json = String(data: data, encoding: .utf8) {
                merged.params["referenceVideos"] = json
            }
            effectiveBackend = merged
        }
        guard let invoker else {
            // 未注入 videoInvoker → 降级 9 槽任务单（video 端口承载任务单全文，QC 可识别）
            // duration 输入端口：合并进节点 backend 供任务单构建读取（覆盖默认时长）
            var nodeWithBackend = node
            if let effectiveBackend {
                nodeWithBackend.backendConfig = effectiveBackend
            }
            var markdown = Self.fallbackVideoTicketMarkdown(node: nodeWithBackend, prompt: prompt)
            if !referenceVideos.isEmpty {
                markdown += "\n\n## 参考视频清单（B2 V2V，共 \(referenceVideos.count) 条）\n"
                    + referenceVideos.joined(separator: "\n")
            }
            return [
                "video": markdown,
                "prompt": prompt,
                "jobTicket": markdown,
                "provider": "none",
                "status": "job_ticket",
            ]
        }
        switch try await invoker.generate(
            node: node,
            prompt: prompt,
            firstFrame: firstFrame,
            backend: effectiveBackend,
            executionEnvelope: executionEnvelope
        ) {
        case .video(let path):
            return ["video": path, "provider": "video", "status": "succeeded"]
        case .videoWithArtifact(let path, let artifactID):
            return [
                "video": path,
                "artifactID": artifactID,
                "provider": "video",
                "status": "succeeded"
            ]
        case .jobTicket(let prompt, let markdown):
            return [
                "video": markdown,
                "prompt": prompt,
                "jobTicket": markdown,
                "provider": "video",
                "status": "job_ticket",
            ]
        }
    }

    /// 无 videoInvoker 降级：构建视频 9 槽任务单 markdown。
    /// 槽位模板读 `ManjuPromptTemplates` 视频模板（MODE/REFERENCE MAP/STYLE LOCK/SHOT/ACTION/
    /// COLOR/SOUND/FORBID/QC，铁律7）；上游已含槽位标记时原样采用，否则按模板拼装（缺槽标
    /// 「（待填）」，结构完整可复制）；额外导出 MODE 与 ACTION 时段总和=镜头时长校验提示（铁律11）。
    /// public：MinisCanvasVideoInvoker 无 key 降级时复用同一份任务单（P2-2-fix 收尾）。
    public static func fallbackVideoTicketMarkdown(node: CanvasNode, prompt: String) -> String {
        let template = ManjuPromptTemplates.template(for: .videoPrompt)
            ?? ManjuTemplate(
                nodeType: .videoGen,
                slots: ManjuPromptTemplates.videoSlots,
                systemPrompt: ManjuPromptTemplates.videoGenSystemPrompt
            )
        let hasSlots = !ManjuTicketParser.parseSlots(prompt, template: template).isEmpty
        let fullPrompt = hasSlots ? prompt : ManjuTicketParser.buildPrompt(from: template, params: [:])
        let sections = ManjuTicketParser.parseSlots(fullPrompt, template: template)
        let forbid = sections.first { $0.name == "FORBID" }?.content ?? "（无）"
        let mode = ManjuTicketParser.mode(from: fullPrompt) ?? "I2V（未声明，默认）"
        let actionText = sections.first { $0.name == "ACTION" }?.content ?? ""
        let durationNote = ManjuTicketParser.actionDurationNote(
            actionText: actionText,
            shotDurationSeconds: ManjuTicketParser.shotDurationSeconds(
                from: node.backendConfig?.params["duration"]
            )
        )

        var lines: [String] = []
        lines.append("# 生成任务单 · \(node.title)")
        lines.append("")
        lines.append("## 9 槽结构（铁律7：缺字段 = BLOCKED，不输出最终提示词）")
        lines.append("")
        lines.append("MODE / REFERENCE MAP / STYLE LOCK / SHOT / ACTION / COLOR / SOUND / FORBID / QC")
        lines.append("")
        lines.append("## 生成模式（MODE）")
        lines.append("")
        lines.append(mode)
        lines.append("")
        lines.append("## ACTION 时段校验（铁律11：所有时间段之和必须精确等于镜头时长）")
        lines.append("")
        lines.append(durationNote)
        lines.append("")
        lines.append("## 完整提示词（\(template.slots.count) 槽，复制到网页版逐槽粘贴）")
        lines.append("")
        lines.append("```text")
        lines.append(fullPrompt)
        lines.append("```")
        lines.append("")
        lines.append("## FORBID 段（铁律4：只写具体禁止物，不写形容词）")
        lines.append("")
        lines.append(forbid)
        lines.append("")
        lines.append("## 使用说明（任务单模式）")
        lines.append("")
        lines.append("1. 将「完整提示词」复制到生视频网页版（可灵 / 即梦），按槽位顺序逐槽粘贴。")
        lines.append("2. 参考图按锁定清单上传，每张图只承担一个职责（铁律2）。")
        lines.append("3. 生成完成后，把结果文件拖回画布对应节点，点击「导入结果」回填。")
        return lines.joined(separator: "\n")
    }

    // MARK: - 失败诊断 + Agent 修复桥（D4 / A3 接线）

    /// 节点失败处理：记录错误 → 收集脱敏诊断 → 若有 repairProvider 则取修复建议。
    /// 建议仅记录（`repairSuggestions`），不自动应用，供用户查看。
    private func recordFailure(
        node: CanvasNode,
        error: any Error,
        inputs: [String: AnyHashable]?
    ) async {
        let upstream = upstreamOutputKeys(of: node.id)
        // 收集诊断上下文（脱敏：敏感输入被剔除、长文本截断）
        let diagnostic = NodeDiagnostics.collectDiagnostic(
            from: node, error: error, inputs: inputs, upstreamOutputKeys: upstream
        )
        let provider = withStateLock {
            _lastErrors[node.id] = error.localizedDescription
            _repairSuggestions[node.id] = nil
            return _repairProvider
        }
        guard let provider else { return }
        // 获取修复建议（provider 内部错误吞掉，失败不影响节点失败状态回传）
        let suggestion = try? await AgentRepairBridge.diagnoseAndRepair(
            context: diagnostic, provider: provider
        )
        if let suggestion {
            withStateLock { _repairSuggestions[node.id] = suggestion }
        }
    }

    /// 节点成功执行：清空该节点的错误与修复建议
    private func recordSuccess(nodeID: UUID) {
        withStateLock {
            _lastErrors[nodeID] = nil
            _repairSuggestions[nodeID] = nil
        }
    }

    /// 失败节点上游已产出输出的端口 key 列表（供 LLM 判断数据依赖；非调度路径为空）
    private func upstreamOutputKeys(of nodeID: UUID) -> [String] {
        let graph = withStateLock { _lastGraph }
        guard let graph else { return [] }
        return graph.predecessors(of: nodeID).flatMap { $0.outputs.map(\.name) }
    }
}
