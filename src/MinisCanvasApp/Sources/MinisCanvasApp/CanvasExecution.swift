import Foundation
import CanvasCore
import MinisCore

/// One-shot write-back capability bound to one frozen execution identity.
/// The scope box remains the authority that validates and consumes it.
final class CanvasExecutionScopeLease: @unchecked Sendable {
    let identity: CanvasExecutionIdentity
    fileprivate let generation: UInt64
    fileprivate let token: UUID
    private weak var owner: CanvasExecutionScopeBox?

    fileprivate init(
        owner: CanvasExecutionScopeBox,
        identity: CanvasExecutionIdentity,
        generation: UInt64,
        token: UUID
    ) {
        self.owner = owner
        self.identity = identity
        self.generation = generation
        self.token = token
    }

    func consume<T>(
        _ body: (CanvasExecutionIdentity) -> T
    ) -> T? {
        owner?.withExecutionLease(self, body)
    }
}

/// Immutable run scope published by CanvasStore before the DAG starts.
final class CanvasExecutionScopeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var issuedLeaseTokens: Set<UUID> = []
    private var scope: (
        canvasID: UUID,
        runID: UUID,
        graphRevision: Int,
        graphFingerprint: String,
        executionEnvelope: DAGExecutionEnvelope?,
        generation: UInt64
    )?

    func begin(
        canvasID: UUID,
        runID: UUID,
        graphRevision: Int,
        graphFingerprint: String? = nil,
        executionEnvelope: DAGExecutionEnvelope? = nil
    ) {
        let resolvedFingerprint = graphFingerprint ?? executionEnvelope?.graphFingerprint ?? ""
        let resolvedEnvelope = executionEnvelope ?? {
            let trimmedFingerprint = resolvedFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedFingerprint.isEmpty else { return nil }
            return DAGExecutionEnvelope(
                canvasID: canvasID,
                runID: runID,
                graphRevision: graphRevision,
                graphFingerprint: trimmedFingerprint
            )
        }()
        lock.lock()
        generation &+= 1
        issuedLeaseTokens.removeAll()
        scope = (
            canvasID,
            runID,
            graphRevision,
            resolvedFingerprint,
            resolvedEnvelope,
            generation
        )
        lock.unlock()
    }

    func end() {
        lock.lock()
        generation &+= 1
        issuedLeaseTokens.removeAll()
        scope = nil
        lock.unlock()
    }

    func executionEnvelope() -> DAGExecutionEnvelope? {
        lock.lock()
        defer { lock.unlock() }
        return scope?.executionEnvelope
    }

    func identity(for node: CanvasNode) -> CanvasExecutionIdentity? {
        lock.lock()
        defer { lock.unlock() }
        guard let scope else { return nil }
        return CanvasExecutionIdentity(
            canvasID: scope.canvasID,
            runID: scope.runID,
            graphRevision: scope.graphRevision,
            nodeID: node.id,
            nodeRevision: scope.graphRevision
        )
    }

    func executionLease(for node: CanvasNode) -> CanvasExecutionScopeLease? {
        lock.lock()
        defer { lock.unlock() }
        guard let scope else { return nil }
        let identity = CanvasExecutionIdentity(
            canvasID: scope.canvasID,
            runID: scope.runID,
            graphRevision: scope.graphRevision,
            nodeID: node.id,
            nodeRevision: scope.graphRevision
        )
        let token = UUID()
        issuedLeaseTokens.insert(token)
        return CanvasExecutionScopeLease(
            owner: self,
            identity: identity,
            generation: scope.generation,
            token: token
        )
    }

    func withExecutionLease<T>(
        _ lease: CanvasExecutionScopeLease,
        _ body: (CanvasExecutionIdentity) -> T
    ) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard let scope,
              scope.generation == lease.generation,
              scope.canvasID == lease.identity.canvasID,
              scope.runID == lease.identity.runID,
              scope.graphRevision == lease.identity.graphRevision,
              scope.generation == generation,
              issuedLeaseTokens.remove(lease.token) != nil else {
            return nil
        }
        return body(lease.identity)
    }

    func workerProjection(
        for node: CanvasNode,
        provider: ProviderSnapshot
    ) -> CanvasWorkerProjection? {
        lock.lock()
        guard let scope,
              !scope.graphFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lock.unlock()
            return nil
        }
        let identity = CanvasExecutionIdentity(
            canvasID: scope.canvasID,
            runID: scope.runID,
            graphRevision: scope.graphRevision,
            nodeID: node.id,
            nodeRevision: scope.graphRevision
        )
        let graphRevision = scope.graphRevision
        let graphFingerprint = scope.graphFingerprint
        lock.unlock()

        return try? CanvasWorkerProjection(
            identity: identity,
            provider: provider,
            graphRevision: graphRevision,
            graphFingerprint: graphFingerprint
        )
    }
}

/// Restored canvas state used exclusively to validate persisted startup work.
/// It never publishes an active execution scope and always returns the
/// identity that was durably recorded with the task.
final class CanvasRecoveryScopeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var canvasID: UUID?
    private var graph: NodeGraph?

    func replace(canvasID: UUID, graph: NodeGraph) {
        lock.lock()
        self.canvasID = canvasID
        self.graph = graph
        lock.unlock()
    }

    func identity(for context: MediaTaskContext) -> CanvasExecutionIdentity? {
        let identity = context.identity
        guard identity.isValid,
              context.providerSnapshot.isValid,
              context.providerSnapshot.capabilities.contains(.video) else {
            return nil
        }

        lock.lock()
        let isCurrentCanvas = canvasID == identity.canvasID
        let graph = isCurrentCanvas ? graph : nil
        lock.unlock()

        guard let graph,
              identity.nodeRevision == identity.graphRevision,
              let node = graph.node(id: identity.nodeID),
              let backend = node.backendConfig else {
            return nil
        }
        if let envelope = context.executionEnvelope {
            guard envelope.isValid,
                  envelope.identity(
                      for: identity.nodeID,
                      nodeRevision: identity.nodeRevision
                  ) == identity,
                  envelope.graphFingerprint == graph.fingerprint else {
                return nil
            }
        } else {
            guard graph.structuralRevision == identity.graphRevision else {
                return nil
            }
        }
        let providerID = backend.providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuredModelID = backend.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !providerID.isEmpty, !configuredModelID.isEmpty else {
            return nil
        }
        let modelID = configuredModelID
        guard providerID == context.providerSnapshot.providerID,
              modelID == context.providerSnapshot.modelID,
              MinisCanvasVideoInvoker.configurationFingerprint(
                providerID: providerID,
                modelID: modelID
              ) == context.providerSnapshot.configurationFingerprint else {
            return nil
        }
        return identity
    }

    func workerProjection(for context: MediaTaskContext) -> CanvasWorkerProjection? {
        guard let identity = identity(for: context) else { return nil }

        lock.lock()
        let graphFingerprint = canvasID == identity.canvasID ? graph?.fingerprint : nil
        lock.unlock()

        guard let graphFingerprint else { return nil }
        return try? CanvasWorkerProjection(
            identity: identity,
            provider: context.providerSnapshot,
            graphRevision: identity.graphRevision,
            graphFingerprint: graphFingerprint
        )
    }
}

// MARK: - 画布真实执行注入实现（I6 P0-1：MinisCanvasApp 侧）

/// 画布 LLM 节点的真实调用实现：按节点 providerID 路由到 MinisCore Provider。
///
/// 预留：节点×LLM 已前台下线（AJ-74），接口保留待后续恢复。
///（llm 节点已从画布新建入口移除、无模型配置 UI；旧图 llm 节点执行仍走本实现，不崩。）
///
/// - `bailian` / `dashScope` → `DashScopeProvider`（阿里云百炼 OpenAI 兼容模式）
/// - `openai` → `OpenAICompatibleProvider`
/// - 其余 providerID 或未配置 key → 优雅降级占位输出（不抛错、不联网，
///   节点标记成功，画布不阻塞——与生图节点无 key 降级任务单同一哲学）
/// - providerID/modelID 为空 → 直接拒绝，不从聊天或全局默认模型兜底
///
/// 真实 LLM 调用走 MinisCore 抽象（复用聊天 Agent 同一条 Provider 链），
/// 不重复实现 URLSession 直连（I5 P1-2：消除平行 LLM 实现）。
struct MinisCanvasLLMInvoker: LLMInvoker {

    /// Stable, non-sensitive failure text consumed by the Canvas app-full
    /// contract. Keep the model field name visible so an empty model cannot be
    /// mistaken for provider/key failure or silently replaced by a default.
    private static let missingModelIDMessage =
        "画布 LLM 节点未配置 modelID，请先配置该节点模型"

    func invoke(prompt: String, backend: NodeBackendConfig) async throws -> String {
        let providerID = backend.providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !providerID.isEmpty else {
            throw LLMError.providerError(
                message: "画布 LLM 节点未配置 providerID，请先配置该节点模型"
            )
        }
        let modelID = backend.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else {
            throw LLMError.providerError(message: Self.missingModelIDMessage)
        }
        let normalizedBackend = NodeBackendConfig(
            providerType: backend.providerType,
            providerID: providerID,
            modelID: modelID,
            params: backend.params
        )
        let model = LLMModel(
            id: modelID,
            displayName: modelID,
            provider: "DashScope"
        )

        let provider: any LLMProvider
        switch providerID {
        case "bailian", "dashScope":
            provider = DashScopeProvider(apiKey: nil, model: model)
        case "openai":
            provider = OpenAICompatibleProvider(
                apiKey: EnvCredentials.value(for: "OPENAI_API_KEY") ?? "",
                model: model,
                customBaseURL: nil,
                appendV1Suffix: true
            )
        default:
            // 未接入的 providerID → 占位输出（不抛错，画布不阻塞）
            return placeholderText(prompt: prompt, backend: normalizedBackend, reason: "provider 未接入")
        }

        guard configured(provider) else {
            // 无 key → 占位输出（与生图无 key 降级同一哲学）
            return placeholderText(prompt: prompt, backend: normalizedBackend, reason: "未配置 API key")
        }

        let maxTokens = normalizedBackend.params["maxTokens"].flatMap(Int.init) ?? 2000
        let temperature = normalizedBackend.params["temperature"].flatMap(Double.init)
        let response = try await provider.sendMessage(
            messages: [LLMMessage(role: .user, content: prompt)],
            systemPrompt: nil,
            maxTokens: maxTokens,
            temperature: temperature
        )
        return response.text
    }

    /// 检查 provider 是否已配置 key（DashScope 按 env 解析链；OpenAI 读 OPENAI_API_KEY）。
    private func configured(_ provider: any LLMProvider) -> Bool {
        if let dashScope = provider as? DashScopeProvider {
            return dashScope.resolvedAPIKey != nil
        }
        return EnvCredentials.value(for: "OPENAI_API_KEY") != nil
    }

    /// 无 key / provider 未接入的引导输出（P2-3 W-3）：明确中文引导——去哪配置、
    /// 查哪个环境变量，附输入摘要便于复制；不抛错、不阻塞画布（与生图无 key
    /// 降级任务单同一哲学）。前缀对齐 `LLMNodeGuidance`（BLOCKED 闸口据此跳过）。
    private func placeholderText(prompt: String, backend: NodeBackendConfig, reason: String) -> String {
        let isNoKey = reason == "未配置 API key"
        let prefix = isNoKey ? LLMNodeGuidance.noKeyPrefix : LLMNodeGuidance.providerUnavailablePrefix
        let lines = prompt.split(separator: "\n")
        let summaryLines = lines.suffix(3).map { $0.count > 60 ? "\($0.prefix(60))…" : String($0) }
        let summary = summaryLines.isEmpty ? "（无输入）" : summaryLines.joined(separator: "\n")
        let modelTag = backend.modelID.isEmpty ? "默认模型" : backend.modelID
        let guide = isNoKey
            ? "未配置 API Key：请在设置中配置，或检查环境变量（DASHSCOPE_API_KEY / OPENAI_API_KEY）后重启应用"
            : "Provider 未接入：请检查环境变量与 Provider 配置后重启应用"
        return """
        \(prefix) \(guide)

        节点：\(backend.providerID) / \(modelTag)

        ── 本次请求输入摘要（配置后自动真实执行）──
        \(summary)
        """
    }
}

/// 画布生图节点的真实调用实现：调 MinisCore `Gimage2Provider`（CloudImageGenerator）。
///
/// - 有 key → 真实生图：b64 落盘到临时目录或返回远程 URL → `.image(path:)`
/// - 无 key / 空提示词 → 降级任务单：完整槽位提示词 + markdown 导出（不阻塞画布）
struct MinisCanvasImageInvoker: ImageGenerating {

    /// 3 参文生图签名（协议默认桥接；等价 4 参版 image = nil）。
    func generate(
        node: CanvasNode,
        prompt: String,
        backend: NodeBackendConfig?
    ) async throws -> ImageGenerationOutcome {
        try await generate(node: node, prompt: prompt, image: nil, backend: backend)
    }

    /// 4 参版（U-2/AJ-11 覆写）：文生图 + 图生图统一入口。
    /// `image` 为 img2img 参考图（本地路径/URL，来自上游 `image` 输入端口），
    /// 经 `CloudImageRequest.imageURL` 透传给 Gimage2Provider；nil = 纯文生图。
    func generate(
        node: CanvasNode,
        prompt: String,
        image: String?,
        backend: NodeBackendConfig?
    ) async throws -> ImageGenerationOutcome {
        let baseURL = EnvCredentials.value(for: "HERMES_CUSTOM_IMAGE2_BASE_URL")
            .map(Self.normalizeBaseURL)
        let provider = Gimage2Provider(baseURL: baseURL)
        let promptText = prompt.trimmingCharacters(in: .whitespacesAndNewlines)

        // 无 key 或空提示词 → 降级任务单（结构完整可复制，不阻塞画布）
        guard provider.isConfigured, !promptText.isEmpty else {
            return .jobTicket(
                prompt: promptText,
                markdown: Self.fallbackTicketMarkdown(node: node, prompt: promptText)
            )
        }

        let request = Self.makeImageRequest(
            prompt: promptText,
            referenceImage: image,
            backend: backend
        )
        let result = try await provider.generateImage(request)
        guard let item = result.images.first, item.hasContent else {
            throw CloudBackendError.decodeFailed(
                providerID: "gimage2", detail: "服务返回为空"
            )
        }
        if let b64 = item.base64Data, !b64.isEmpty {
            return .image(path: try Self.saveBase64(b64, providerID: result.providerID))
        }
        if let url = item.url, !url.isEmpty {
            return .image(path: url)
        }
        throw CloudBackendError.decodeFailed(
            providerID: "gimage2", detail: "返回内容无有效图片数据"
        )
    }

    // MARK: - 辅助

    /// 组装生图请求：节点参数面板的 size / 负向提示词 / 模型 / 参考图（img2img）真正进入 Provider 请求。
    /// - prompt: 完整提示词（来自上游输入）
    /// - referenceImage: 图生图参考图（本地路径/URL，nil = 纯文生图）
    /// - backend: 节点级模型配置（params["size"] 尺寸、params["negativePrompt"] 负向提示词；
    ///   modelID 模型覆盖）
    static func makeImageRequest(
        prompt: String,
        referenceImage: String?,
        backend: NodeBackendConfig?
    ) -> CloudImageRequest {
        CloudImageRequest(
            prompt: prompt,
            negativePrompt: normalizedOptionalText(backend?.params["negativePrompt"]),
            size: backend?.params["size"],
            count: 1,
            modelOverride: Self.resolveModelOverride(backend: backend),
            imageURL: Self.normalizedReferenceImage(referenceImage)
        )
    }

    /// 归一化可选文本参数：空白字符串视为未设置（返回 nil）。
    static func normalizedOptionalText(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 归一化参考图参数：空白字符串视为未传入（返回 nil）。
    static func normalizedReferenceImage(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 生图模型兜底：gimage2.env 的 `GIMAGE2_MODEL_G2`（默认 `gpt-image-2`）。
    /// 节点未配模型或仍是 Provider 默认占位模型（`gpt-image-2-official`）时使用。
    private static func resolveModelOverride(backend: NodeBackendConfig?) -> String? {
        if let model = backend?.modelID, !model.isEmpty, model != Gimage2Provider.defaultModel {
            return model
        }
        return EnvCredentials.value(for: "GIMAGE2_MODEL_G2") ?? "gpt-image-2"
    }

    /// 归一化 base URL：剥掉尾部 `/v1`（MinisCore URLBuilding.joinURL 拼接 `/v1` 不去重）。
    private static func normalizeBaseURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if s.hasSuffix("/v1") { s = String(s.dropLast(3)) }
        return s
    }

    /// b64 → 临时目录落盘（/tmp/miniscanvas_generated/<provider>-<uuid>.png）
    private static func saveBase64(_ b64: String, providerID: String) throws -> String {
        guard let data = Data(base64Encoded: b64) else {
            throw CloudBackendError.decodeFailed(providerID: providerID, detail: "base64 解码失败")
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniscanvas_generated", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(providerID)-\(UUID().uuidString.prefix(8)).png")
        try data.write(to: url)
        return url.path
    }

    /// 无 key 降级：构建任务单 markdown（图片 8 槽模板 + FORBID 段 + 使用说明）。
    /// 提示词取上游完整槽位文本；缺失时用模板拼装兜底（缺槽标「（待填）」）。
    private static func fallbackTicketMarkdown(node: CanvasNode, prompt: String) -> String {
        let template = ManjuPromptTemplates.template(for: .imageGen)
            ?? ManjuTemplate(
                nodeType: .imageGen,
                slots: ManjuPromptTemplates.imageSlots,
                systemPrompt: ManjuPromptTemplates.imageSystemPrompt
            )
        let hasSlots = !ManjuTicketParser.parseSlots(prompt, template: template).isEmpty
        let fullPrompt = hasSlots ? prompt : ManjuTicketParser.buildPrompt(from: template, params: [:])
        let forbid = ManjuTicketParser.slotContent("FORBID", in: fullPrompt, template: template) ?? "（无）"

        var lines: [String] = []
        lines.append("# 生成任务单 · \(node.title)")
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
        lines.append("1. 将「完整提示词」复制到生图网页版，按槽位顺序逐槽粘贴。")
        lines.append("2. 生成完成后，把结果文件拖回画布对应节点，点击「导入结果」回填。")
        return lines.joined(separator: "\n")
    }
}

/// 画布生视频节点的真实调用实现（P2-2 P0-3）：调 MinisCore `CloudVideoGenerator`
/// （可灵 Kling / 即梦 Jimeng，submit+poll，5s 轮询 / 300s 超时）。
/// - 有 key → 真实生成：`generateVideo` 返回视频 URL → `.video(path:)`
/// - 空/未知 providerID → 明确报错「未配置视频后端」（F10 P0-04：不再静默路由 Kling）
/// - 无 key / 空提示词 → 降级任务单（9 槽 markdown，复用 CanvasCore 的
///   `GraphExecutionContext.fallbackVideoTicketMarkdown`，不阻塞画布——与生图同一哲学）
struct MinisCanvasVideoInvoker: VideoGenerating {
    /// F21b（P0-2）：taskID 持久化存储（生产 = <AppSupport>/MinisCore/videoTasks.json；
    /// 测试注入临时目录 store 隔离）
    let taskStore: VideoTaskStore
    /// Provider 工厂允许测试使用本地 replay，同时保持生产路由的 fail-closed 语义。
    let providerFactory: @Sendable (String) throws -> any CloudVideoGenerator
    let assetDirectory: URL
    let assetDownloader: any VideoAssetDownloader
    let executorRegistry: VideoTaskExecutorRegistry
    let assetStore: CanvasAssetStore?
    let artifactStore: ArtifactStore
    private let scopeProvider: (@Sendable (CanvasNode) -> CanvasExecutionIdentity?)?
    private let executionLeaseProvider: (
        @Sendable (CanvasNode) -> CanvasExecutionScopeLease?
    )?
    private let workerProjectionProvider: (
        @Sendable (CanvasNode, ProviderSnapshot) -> CanvasWorkerProjection?
    )?
    private let recoveryIdentityProvider: (@Sendable (MediaTaskContext) -> CanvasExecutionIdentity?)?
    private let recoveryWorkerProjectionProvider: (
        @Sendable (MediaTaskContext) -> CanvasWorkerProjection?
    )?

    init(
        taskStore: VideoTaskStore = .shared,
        assetDirectory: URL? = nil,
        assetDownloader: any VideoAssetDownloader = URLSessionVideoAssetDownloader(),
        providerFactory: @escaping @Sendable (String) throws -> any CloudVideoGenerator = {
            try Self.resolveVideoProvider($0)
        },
        assetStore: CanvasAssetStore? = nil,
        artifactStore: ArtifactStore? = nil,
        scopeProvider: (@Sendable (CanvasNode) -> CanvasExecutionIdentity?)? = nil,
        executionLeaseProvider: (
            @Sendable (CanvasNode) -> CanvasExecutionScopeLease?
        )? = nil,
        workerProjectionProvider: (
            @Sendable (CanvasNode, ProviderSnapshot) -> CanvasWorkerProjection?
        )? = nil,
        recoveryIdentityProvider: (@Sendable (MediaTaskContext) -> CanvasExecutionIdentity?)? = nil,
        recoveryWorkerProjectionProvider: (
            @Sendable (MediaTaskContext) -> CanvasWorkerProjection?
        )? = nil
    ) {
        self.taskStore = taskStore
        let resolvedAssetDirectory = (assetDirectory ?? taskStore.directory
            .appendingPathComponent("videoAssets", isDirectory: true)).standardizedFileURL
        self.assetDirectory = resolvedAssetDirectory
        self.assetDownloader = assetDownloader
        self.providerFactory = providerFactory
        self.assetStore = assetStore
        self.artifactStore = artifactStore ?? ArtifactStore(
            directory: resolvedAssetDirectory.appendingPathComponent("artifacts", isDirectory: true),
            allowedMediaRoot: resolvedAssetDirectory
        )
        self.scopeProvider = scopeProvider
        self.executionLeaseProvider = executionLeaseProvider
        self.workerProjectionProvider = workerProjectionProvider
        self.recoveryIdentityProvider = recoveryIdentityProvider
        self.recoveryWorkerProjectionProvider = recoveryWorkerProjectionProvider
        self.executorRegistry = VideoTaskExecutorRegistry(
            store: taskStore,
            assetDownloader: assetDownloader,
            assetDirectory: self.assetDirectory
        )
    }

    func generate(
        node: CanvasNode,
        prompt: String,
        firstFrame: String?,
        backend: NodeBackendConfig?
    ) async throws -> VideoGenerationOutcome {
        try await generate(
            node: node,
            prompt: prompt,
            firstFrame: firstFrame,
            backend: backend,
            executionEnvelope: nil
        )
    }

    func generate(
        node: CanvasNode,
        prompt: String,
        firstFrame: String?,
        backend: NodeBackendConfig?,
        executionEnvelope: DAGExecutionEnvelope?
    ) async throws -> VideoGenerationOutcome {
        let promptText = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let backendID = (backend?.providerID ?? "").trimmingCharacters(in: .whitespaces)
        let modelID = (backend?.modelID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        // A production-scoped Canvas task must carry both halves of its
        // node-local model binding. Never synthesize a model from providerID.
        if assetStore != nil {
            guard !backendID.isEmpty, !modelID.isEmpty else {
                throw VideoTaskExecutionError.contextMismatch(
                    "Canvas provider/model configuration is incomplete"
                )
            }
        }

        // Once the production stores are wired, an absent scope is a hard
        // boundary failure. Falling back to the legacy executor here would
        // submit a provider task that can never be safely projected back.
        let scopedIdentity: CanvasExecutionIdentity?
        if assetStore != nil, let scopeProvider {
            guard let identity = scopeProvider(node) else {
                throw VideoTaskExecutionError.contextMismatch(
                    "Canvas execution scope is no longer current"
                )
            }
            scopedIdentity = identity
        } else {
            scopedIdentity = nil
        }

        // F10 P0-04：后端路由用显式表——空/未知 providerID 报明确错误，
        // 不再静默落到 Kling（用户选 Jimeng/Wan/未知后端仍请求 Kling 是静默错误）。
        let provider = try providerFactory(backendID)

        // 无 key / 空提示词 → 降级任务单（结构完整可复制，不阻塞画布）
        guard provider.isConfigured, !promptText.isEmpty else {
            return .jobTicket(
                prompt: promptText,
                markdown: GraphExecutionContext.fallbackVideoTicketMarkdown(node: node, prompt: promptText)
            )
        }

        let request = Self.makeVideoRequest(
            prompt: promptText, firstFrame: firstFrame, backend: backend, providerID: provider.providerID
        )

        let fingerprint = Self.promptFingerprint(promptText)
        let executor = await executorRegistry.executor(
            providerID: provider.providerID,
            provider: provider
        )
        let record: VideoTaskRecord
        if let assetStore, let scopeProvider, let identity = scopedIdentity {
            guard let executionEnvelope,
                  executionEnvelope.isValid,
                  executionEnvelope.identity(
                      for: node.id,
                      nodeRevision: identity.nodeRevision
                  ) == identity else {
                throw VideoTaskExecutionError.contextMismatch(
                    "Canvas DAG execution envelope is missing or no longer current"
                )
            }
            let snapshot = ProviderSnapshot(
                providerID: provider.providerID,
                modelID: modelID,
                capabilities: [.video],
                configurationFingerprint: Self.configurationFingerprint(
                    providerID: provider.providerID,
                    modelID: modelID
                )
            )
            let context = MediaTaskContext(
                envelope: executionEnvelope,
                nodeID: node.id,
                nodeRevision: identity.nodeRevision,
                providerSnapshot: snapshot,
                promptFingerprint: fingerprint
            )
            guard let workerProjection = workerProjectionProvider?(node, snapshot),
                  case .accepted = CanvasWorkerSeam.accept(workerProjection) else {
                throw VideoTaskExecutionError.contextMismatch(
                    "Canvas worker projection is missing or invalid"
                )
            }
            let scopedExecutionLeaseProvider: (@Sendable () -> CanvasExecutionScopeLease?)?
            if let executionLeaseProvider {
                scopedExecutionLeaseProvider = {
                    executionLeaseProvider(node)
                }
            } else {
                scopedExecutionLeaseProvider = nil
            }
            let coordinator = CanvasTaskCoordinator(
                media: MediaTaskCoordinator(executor: executor),
                assetStore: assetStore,
                artifactStore: artifactStore,
                assetPersistenceDirectory: taskStore.directory,
                requiresExecutionEnvelope: true,
                currentIdentityProvider: { scopeProvider(node) },
                executionLeaseProvider: scopedExecutionLeaseProvider,
                currentWorkerProjectionProvider: {
                    workerProjectionProvider?(node, snapshot)
                }
            )
            let result = try await coordinator.runVideo(
                context: context,
                promptFingerprint: fingerprint,
                request: request,
                currentIdentity: scopeProvider(node) ?? identity,
                workerProjection: workerProjection
            )
            guard case .accepted = result.writeback else {
                throw VideoTaskExecutionError.contextMismatch(
                    "Canvas scoped media writeback was rejected"
                )
            }
            record = result.record
            if let artifactID = result.artifactID,
               let assetPath = record.assetPath, !assetPath.isEmpty {
                return .videoWithArtifact(path: assetPath, artifactID: artifactID)
            }
        } else {
            record = try await executor.start(
                VideoTaskExecutionRequest(
                    nodeID: node.id,
                    providerID: provider.providerID,
                    promptFingerprint: fingerprint,
                    request: request
                )
            )
        }
        if let assetPath = record.assetPath, !assetPath.isEmpty {
            return .video(path: assetPath)
        }
        // 兼容旧版已完成记录：升级后首次读取时仍可使用远端 URL。
        if let videoURL = record.videoURL, !videoURL.isEmpty {
            return .video(path: videoURL)
        }
        throw VideoTaskExecutionError.missingVideoURL(record.id)
    }

    /// 会话内任务控制入口：取消必须落到生成时使用的同一 Provider 执行器，
    /// 这样 submit/poll 竞态不会只改 UI 状态而遗留后台操作。
    @discardableResult
    func cancelTask(idempotencyKey: String) async -> Bool {
        guard let record = taskStore.allRecords().first(where: {
            $0.idempotencyKey == idempotencyKey && $0.status.isActive
        }) else {
            return false
        }
        guard let provider = try? providerFactory(record.providerID) else {
            // Provider 不可用时仍完成本地停止，避免旧配置把用户操作变成 no-op。
            return taskStore.markCanceled(id: record.id)
        }
        let executor = await executorRegistry.executor(
            providerID: record.providerID,
            provider: provider
        )
        return await executor.cancel(idempotencyKey: idempotencyKey)
    }

    /// Cancel all active scoped video tasks for one Canvas run. This is the
    /// production bridge used by CanvasStore's Stop action.
    @discardableResult
    func cancelTasks(runID: UUID) async -> Bool {
        await executorRegistry.cancelTasks(runID: runID)
    }

    /// 启动恢复入口：按持久化 providerID 路由，只轮询已有 remote taskID，绝不重新 submit。
    func recoverPendingTasks() async throws -> [VideoTaskRecord] {
        var recovered: [VideoTaskRecord] = []
        for record in taskStore.recoverableTasks() {
            do {
                if let assetStore {
                    guard let recoveryIdentityProvider else {
                        continue
                    }
                    // Validate every persisted scope before creating a
                    // coordinator. A stale or switch-detached task must not
                    // reach MediaTaskCoordinator.recover, which could mark it
                    // failed before the canvas identity rejection is known.
                    let metadataStore = MediaTaskMetadataStore(directory: taskStore.directory)
                    guard !record.taskID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          let context = try metadataStore.context(recordID: record.id),
                          context.identity.isValid,
                          context.providerSnapshot.isValid,
                          context.providerSnapshot.capabilities.contains(.video),
                          context.executionEnvelope != nil,
                          record.nodeID == context.identity.nodeID,
                          record.providerID == context.providerSnapshot.providerID,
                          record.idempotencyKey == context.idempotencyKey,
                          let currentIdentity = recoveryIdentityProvider(context),
                          currentIdentity == context.identity,
                          let workerProjection = recoveryWorkerProjectionProvider?(context),
                          workerProjection.identity == context.identity,
                          workerProjection.provider == context.providerSnapshot,
                          case .accepted = CanvasWorkerSeam.accept(workerProjection) else {
                        continue
                    }
                    let provider = try providerFactory(record.providerID)
                    let executor = await executorRegistry.executor(
                        providerID: record.providerID,
                        provider: provider
                    )
                    let coordinator = CanvasTaskCoordinator(
                        media: MediaTaskCoordinator(executor: executor),
                        assetStore: assetStore,
                        artifactStore: artifactStore,
                        assetPersistenceDirectory: taskStore.directory,
                        requiresExecutionEnvelope: true,
                        currentIdentityProvider: { recoveryIdentityProvider(context) },
                        currentWorkerProjectionProvider: {
                            recoveryWorkerProjectionProvider?(context)
                        }
                    )
                    if let result = try await coordinator.recoverVideo(
                        id: record.id,
                        context: context,
                        currentIdentity: currentIdentity,
                        workerProjection: workerProjection
                    ) {
                        recovered.append(result.record)
                    }
                } else {
                    let provider = try providerFactory(record.providerID)
                    let executor = await executorRegistry.executor(
                        providerID: record.providerID,
                        provider: provider
                    )
                    if let result = try await executor.recover(id: record.id) {
                        recovered.append(result)
                    }
                }
            } catch {
                // Scoped startup rejection is intentionally absent from the
                // recovered projection. Keep the durable remote task active so
                // a later launch restoring the exact canvas can recover it.
                if assetStore == nil, let current = taskStore.record(id: record.id) {
                    recovered.append(current)
                }
            }
        }
        return recovered
    }

    /// F21b：提示词指纹（同节点同提示词 = 同一生成意图；防重键）。
    /// FNV-1a 64 位（纯 Swift、跨进程确定性 —— 重启后续查仍能命中同一任务；
    /// 不用 Hasher：其随机种子每次启动不同，指纹跨进程不稳定）。
    /// 只存指纹不存提示词原文（日志安全）。
    static func promptFingerprint(_ prompt: String) -> String {
        let normalized = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in normalized.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }

    static func configurationFingerprint(providerID: String, modelID: String) -> String {
        promptFingerprint("provider=\(providerID)\nmodel=\(modelID)")
    }

    // MARK: - F10 P0-04：显式路由表（禁止静默兜底）

    /// providerID → 生视频 Provider。仅 kling / jimeng 已接入；
    /// 空 = 未配置、其余 = 不支持，均抛 `CanvasVideoRoutingError`（友好中文提示），
    /// 由 GraphExecutionContext 记录为节点失败原因展示给用户。
    static func resolveVideoProvider(_ backendID: String) throws -> any CloudVideoGenerator {
        switch backendID {
        case "kling":
            return KlingProvider()
        case "jimeng", "jimengProvider":
            return JimengProvider()
        case "":
            throw CanvasVideoRoutingError.unconfigured
        default:
            throw CanvasVideoRoutingError.unsupported(backendID)
        }
    }

    // MARK: - F10 P0-05：节点 params → CloudVideoRequest 透传

    /// 组装生视频请求：节点参数面板的 duration/resolution/aspect_ratio/mode/audio
    /// 真正进入 Provider 请求。
    /// - duration：UI 选择器存 "5s"/"10s"，归一化为纯秒数 "5"/"10"
    ///   （Kling `Int("5s")` 解析失败会回落默认时长；Jimeng 的 frames 依赖纯数字）
    /// - resolution：经 extraParams 传给 Kling（settings.resolution 从 extraParams 读，
    ///   CloudVideoRequest 无 resolution 字段——修复前该参数根本没进请求）；
    ///   Jimeng API 无 resolution 字段（画幅由 aspect_ratio 决定），不传避免未知字段
    /// - aspectRatio：接受 `aspectRatio` / `aspect_ratio` 两种键名，Jimeng 映射到 body.aspect_ratio
    /// - audio：经 extraParams 传给 Kling（settings.audio：on 带声音 / off 后期配音），
    ///   Jimeng body 无 audio 字段，不传避免未知字段
    /// - mode：生成模式（i2v/t2v/r2v）经 extraParams 透传 Kling（语义标记；帧路由由
    ///   executeVideo 按 mode 决定是否带首帧）；Jimeng 无对应字段，不传
    /// - last_frame_url：首尾帧尾帧（params["last_frame_url"] / params["lastFrame"]），
    ///   经 extraParams 传给 Kling（contents 的 last_frame）；Jimeng 无对应字段，不传
    static func makeVideoRequest(
        prompt: String,
        firstFrame: String?,
        backend: NodeBackendConfig?,
        providerID: String
    ) -> CloudVideoRequest {
        var extraParams: [String: String] = [:]
        if providerID == "kling" {
            if let resolution = backend?.params["resolution"], !resolution.isEmpty {
                extraParams["resolution"] = resolution
            }
            if let audio = backend?.params["audio"], !audio.isEmpty {
                extraParams["audio"] = audio
            }
            if let mode = backend?.params["mode"], !mode.isEmpty {
                extraParams["mode"] = mode
            }
            if let lastFrame = backend?.params["last_frame_url"] ?? backend?.params["lastFrame"],
               !lastFrame.isEmpty {
                extraParams["last_frame_url"] = lastFrame
            }
        }
        return CloudVideoRequest(
            prompt: prompt,
            imageURL: firstFrame,
            aspectRatio: resolvedAspectRatio(backend),
            duration: normalizedDuration(backend?.params["duration"]),
            modelOverride: resolveModelOverride(backend: backend),
            extraParams: extraParams
        )
    }

    /// duration 归一化："5s"/"10s"/" 10 " → "5"/"10"；非法值返回 nil（Provider 用默认）。
    static func normalizedDuration(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if value.lowercased().hasSuffix("s") { value = String(value.dropLast()) }
        guard let seconds = Double(value), seconds > 0 else { return nil }
        return seconds == Double(Int(seconds)) ? String(Int(seconds)) : String(seconds)
    }

    /// 宽高比：兼容 `aspectRatio` 与 `aspect_ratio` 两种键名。
    static func resolvedAspectRatio(_ backend: NodeBackendConfig?) -> String? {
        let raw = backend?.params["aspectRatio"] ?? backend?.params["aspect_ratio"]
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return raw
    }

    /// 生视频模型兜底：节点未配模型时返回 nil（Provider 用默认：可灵 kling-v1 / 即梦 jimeng_ti2v_v30_pro）。
    private static func resolveModelOverride(backend: NodeBackendConfig?) -> String? {
        guard let model = backend?.modelID, !model.isEmpty else { return nil }
        return model
    }
}

/// F10 P0-04：生视频后端路由错误（替代静默默认 Kling）。
/// errorDescription 为面向用户的友好中文提示，节点失败原因（lastErrors）直接展示。
enum CanvasVideoRoutingError: Error, LocalizedError, Equatable {
    /// providerID 为空：节点未选择视频后端
    case unconfigured
    /// providerID 未知/未实现（如 wan-local 或未接入的后端）
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .unconfigured:
            return "未配置视频后端：请打开节点模型设置面板，为视频生成节点选择后端（可灵 Kling / 即梦 Jimeng）后重新执行"
        case .unsupported(let providerID):
            return "未配置视频后端：不支持的生视频后端「\(providerID)」（当前已接入：可灵 kling / 即梦 jimeng），请在节点模型设置面板重新选择"
        }
    }
}

/// 画布 Blender 白模渲染的真实调用实现：直连 MinisCore `BlenderBridge`。
/// `blender -b -P <script>` 后台渲染，返回生成的 PNG 路径列表。
struct MinisCanvasBlenderInvoker: BlenderRenderInvoker {
    func render(
        script: String,
        outputDir: String,
        frameRange: (Int, Int)?
    ) async throws -> [String] {
        try await BlenderBridge.renderWhitemodel(
            script: script,
            outputDir: outputDir,
            frameRange: frameRange
        )
    }
}
