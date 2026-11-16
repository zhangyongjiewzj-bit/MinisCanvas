import Foundation
import AppKit
import CoreFoundation
import Observation
import AVFoundation
import CoreAudio
import CanvasCore
import MinisCore

// The gate is captured by value with each turn. This wrapper forwards the
// exact request to the original delegate and carries only a resource marker.
private struct ProductionBrowserGenerationApprovalDelegate: ChildDeletionReviewPreparationDemand {
    let generationID: UUID
    let base: any ApprovalDelegate
    let browserSession: BrowserSession
    let browserRules: BrowserInteractionRuleStore
    var requiresDeletionPreparation: Bool {
        (base as? any ChildDeletionReviewPreparationDemand)?.requiresDeletionPreparation ?? false
    }

    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        await BrowserInteractionApproval.decide(request, session: browserSession,
                                                rules: browserRules, delegate: base)
    }
}

// A shared BuiltinToolExecutor can outlive the turn that captured it. Its
// browser slot is rebound on chat changes, so dispatch must compare the
// immutable turn conversation with the browser resource's trusted owner.
private struct ProductionSessionBoundBrowserExecutor: ToolExecutor {
    let conversationID: String
    let generationID: UUID
    let tool: BrowserTool

    func execute(name: String, input: [String: Any]) async throws -> String {
        guard let context = AgentExecutionContext.current,
              context.currentConversationID == conversationID,
              let bound = context.approvalGate?.delegate
                as? ProductionBrowserGenerationApprovalDelegate,
              bound.generationID == generationID else {
            throw ToolExecutorError.resourceScopeInvalid
        }
        return try await tool.execute(name: name, input: input)
    }
}

// MARK: - Chat and Canvas composition
//
// Production Chat submissions always follow the Provider path. Canvas actions
// enter through explicit Canvas UI/API boundaries, and Canvas events remain
// local to Canvas-owned UI state.

/// Structured session commands accepted by the App action boundary.
/// The request carries intent only; BridgeStore creates the runtime identity.
struct SessionActionRequest: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case new(
            title: String,
            projectID: String?,
            projectName: String?,
            workingDirectory: String?,
            groupID: UUID?
        )
        case rename(sessionID: String, title: String)
        case `switch`(sessionID: String)
        case fork(sessionID: String)
    }

    let kind: Kind
    /// Captured when the UI action is created. A queued action must not be
    /// rebound to whatever session happens to be active when it is consumed.
    let source: ParentRuntimeIdentity?

    private init(kind: Kind, source: ParentRuntimeIdentity?) {
        self.kind = kind
        self.source = source
    }

    static func new(
        title: String,
        projectID: String? = nil,
        projectName: String? = nil,
        workingDirectory: String? = nil,
        groupID: UUID? = nil,
        source: ParentRuntimeIdentity? = nil
    ) -> Self {
        Self(kind: .new(
            title: title,
            projectID: projectID,
            projectName: projectName,
            workingDirectory: workingDirectory,
            groupID: groupID
        ), source: source)
    }

    static func rename(
        sessionID: String,
        title: String,
        source: ParentRuntimeIdentity? = nil
    ) -> Self {
        Self(kind: .rename(sessionID: sessionID, title: title), source: source)
    }

    static func `switch`(
        sessionID: String,
        source: ParentRuntimeIdentity? = nil
    ) -> Self {
        Self(kind: .switch(sessionID: sessionID), source: source)
    }

    static func fork(
        sessionID: String,
        source: ParentRuntimeIdentity? = nil
    ) -> Self {
        Self(kind: .fork(sessionID: sessionID), source: source)
    }
}

/// Immutable result of one structured session action. The task/run snapshots
/// are copied from AgentTaskStore after terminal settlement.
struct SessionActionSnapshot: Sendable, Equatable {
    let source: ParentRuntimeIdentity
    let resultSessionID: String
    let task: AgentTaskSnapshot
    let runID: String
}

struct SessionActionObservation: Sendable, Equatable {
    let action: SessionAction
    let source: ParentRuntimeIdentity
    let taskID: String
    let runID: String
    let snapshot: SessionActionSnapshot
    let receipt: SessionActionReceipt
}

/// 画布指令解析结果
enum CanvasCommand {
    case addNode(keyword: String)
    case connect(from: String, to: String)
    case run
    case layout
    case reset
    case deleteNode(keyword: String)
    case listNodes
    case help
    // E16 对话驱动节点内容调整
    case setNodeContent(keyword: String, content: String)
    case adjustNodeContent(keyword: String, instruction: String)
    case summarizeNode(keyword: String)
    case importNovel(content: String)
    // P2-1 一键漫剧流水线（工具栏 / DeepLink / 对话指令共用）
    case createPipeline
    // C3-3 崩溃恢复 + 操作历史（会话自动保存 / Agent 可撤销）
    case recoverCanvasDraft
    case discardCanvasDraft
    case toolHistory
    case undoToolAction
}

/// 轻量中文指令解析器（无前缀命令：只要句子命中动词即触发）
enum CommandParser {
    static func parse(_ raw: String) -> CanvasCommand? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // 帮助（精确匹配，避免「帮助我」等普通对话被误判为 help 命令）
        if text == "帮助" || text == "帮助文档" || text == "help" || text == "？" { return .help }

        // P2-1：一键漫剧流水线（须在「运行/执行」前缀检查之前，避免「执行漫剧流水线」等被误吞）
        if ["一键流水线", "生成流水线", "漫剧流程", "漫剧流水线", "建漫剧流水线"]
            .contains(where: text.contains) {
            return .createPipeline
        }

        // 建节点：建节点 llm / 添加节点 图像生成 / 新建 text 节点
        if text.hasPrefix("建节点") || text.hasPrefix("添加节点") || text.hasPrefix("新建节点")
            || text.contains("建个节点") || text.contains("加个节点") {
            let keyword = strip(text, prefixes: ["建节点", "添加节点", "新建节点", "建个节点", "加个节点"])
                .replacingOccurrences(of: "节点", with: "")
                .trimmingCharacters(in: .whitespaces)
            return keyword.isEmpty ? nil : .addNode(keyword: keyword)
        }

        // 连线：连线 文本输入 -> LLM 推理 / 把 A 连到 B
        if text.hasPrefix("连线") || text.hasPrefix("连接节点") {
            let body = strip(text, prefixes: ["连线", "连接节点"])
            if let (a, b) = splitPair(body) { return .connect(from: a, to: b) }
            return nil
        }
        if let (a, b) = splitConnected(text) { return .connect(from: a, to: b) }

        // 删除节点
        if text.hasPrefix("删除节点") || text.hasPrefix("移除节点") || text.hasPrefix("删节点") {
            let keyword = strip(text, prefixes: ["删除节点", "移除节点", "删节点"])
                .trimmingCharacters(in: .whitespaces)
            return keyword.isEmpty ? nil : .deleteNode(keyword: keyword)
        }

        // 执行（精确匹配完整命令词，避免「运行我的脚本」「执行这个功能」等普通对话被误判为 run）
        if ["执行", "运行", "跑一下", "跑画布", "执行画布", "运行画布", "执行画布", "运行", "开始执行", "开始运行"]
            .contains(text) {
            return .run
        }

        // 布局
        if ["布局", "自动布局", "排版"].contains(text) { return .layout }

        // 重置
        if ["重置", "重置状态", "清空状态"].contains(text) { return .reset }

        // 列表
        if ["列表", "节点列表", "列出节点", "有哪些节点"].contains(text) { return .listNodes }

        // E16：设置/修改节点内容（改 X 的内容：Y / 设置 X：Y / 把 X 的内容改成：Y）
        if let parsed = Self.parseSetNodeContent(text) {
            return .setNodeContent(keyword: parsed.keyword, content: parsed.content)
        }
        // E16：Agent 调整节点内容（调整 X：指令）
        if let parsed = Self.parseAdjustNode(text) {
            return .adjustNodeContent(keyword: parsed.keyword, instruction: parsed.instruction)
        }
        // E16：Agent 总结节点（总结 X）
        if let keyword = Self.parseSummarizeNode(text) {
            return .summarizeNode(keyword: keyword)
        }
        // E16：导入小说（导入小说 <路径或粘贴> / 小说内容：<文本>）
        if let content = Self.parseImportNovel(text) {
            return .importNovel(content: content)
        }

        // C3-3：崩溃恢复（检测到上次未保存画布草稿后的提示指令）
        if text == "恢复画布" || text == "恢复草稿" || text == "恢复上次画布" {
            return .recoverCanvasDraft
        }
        if text == "丢弃草稿" || text == "放弃草稿" || text == "丢弃画布草稿" {
            return .discardCanvasDraft
        }
        // C3-3：Agent 工具调用历史栈（记录 + 展示；撤销执行留接口）
        if text == "工具历史" || text == "工具调用历史" || text == "操作历史" {
            return .toolHistory
        }
        if text == "撤销" || text == "撤销上一步" || text == "撤销工具" {
            return .undoToolAction
        }

        return nil
    }

    // MARK: E16 对话驱动节点内容调整 — 指令解析

    /// `改 X 的内容：Y` / `设置 X 的内容：Y` / `把 X 的内容改成：Y` / `设置 X：Y`
    private static func parseSetNodeContent(_ text: String) -> (keyword: String, content: String)? {
        // 把 X 的内容改成：Y / 改为：Y
        if text.hasPrefix("把 ") {
            let body = String(text.dropFirst("把 ".count))
            for marker in ["的内容改成：", "的内容改为：", "的内容改成:", "的内容改为:"] {
                if let range = body.range(of: marker) {
                    let kw = String(body[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let content = String(body[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !kw.isEmpty && !content.isEmpty { return (kw, content) }
                }
            }
        }
        // 改 X 的内容：Y / 设置 X 的内容：Y
        for prefix in ["改 ", "设置 ", "设置", "改"] where text.hasPrefix(prefix) {
            let body = String(text.dropFirst(prefix.count))
            for marker in ["的内容：", "的内容:"] {
                if let range = body.range(of: marker) {
                    let kw = String(body[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let content = String(body[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !kw.isEmpty && !content.isEmpty { return (kw, content) }
                }
            }
        }
        // 设置 X：Y（无「的内容」标记）
        if text.hasPrefix("设置 ") {
            let body = String(text.dropFirst("设置 ".count))
            if let (kw, content) = splitAtColon(body), !kw.isEmpty, !content.isEmpty {
                return (kw, content)
            }
        }
        return nil
    }

    /// `调整 X：指令`
    private static func parseAdjustNode(_ text: String) -> (keyword: String, instruction: String)? {
        guard text.hasPrefix("调整 ") else { return nil }
        let body = String(text.dropFirst("调整 ".count))
        guard let (kw, inst) = splitAtColon(body), !kw.isEmpty, !inst.isEmpty else { return nil }
        return (kw, inst)
    }

    /// `总结 X` / `总结：X`
    private static func parseSummarizeNode(_ text: String) -> String? {
        if text.hasPrefix("总结 ") {
            let kw = String(text.dropFirst("总结 ".count)).trimmingCharacters(in: .whitespaces)
            return kw.isEmpty ? nil : kw
        }
        for prefix in ["总结：", "总结:"] where text.hasPrefix(prefix) {
            let kw = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            return kw.isEmpty ? nil : kw
        }
        return nil
    }

    /// `导入小说 <路径或粘贴>` / `小说内容：<文本>` → 原始载荷（路径或文本）
    private static func parseImportNovel(_ text: String) -> String? {
        if text.hasPrefix("导入小说") {
            let body = String(text.dropFirst("导入小说".count)).trimmingCharacters(in: .whitespaces)
            return body.isEmpty ? nil : body
        }
        for prefix in ["小说内容：", "小说内容:"] where text.hasPrefix(prefix) {
            let body = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            return body.isEmpty ? nil : body
        }
        return nil
    }

    /// 按第一个冒号拆分（支持全角 `：` 与半角 `:`）
    private static func splitAtColon(_ body: String) -> (String, String)? {
        for sep in ["：", ":"] {
            if let range = body.range(of: sep) {
                let a = String(body[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let b = String(body[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !a.isEmpty && !b.isEmpty { return (a, b) }
            }
        }
        return nil
    }

    /// 去掉前缀（按最长前缀优先）
    private static func strip(_ text: String, prefixes: [String]) -> String {
        var result = text
        for p in prefixes.sorted(by: { $0.count > $1.count }) where result.hasPrefix(p) {
            result.removeFirst(p.count)
            break
        }
        return result
    }

    /// 按分隔符拆 "A -> B"（支持 -> / → / 到 / 连到）
    private static func splitPair(_ body: String) -> (String, String)? {
        let separators = ["->", "→", "──>", "连到", " 到 "]
        for sep in separators {
            if let range = body.range(of: sep) {
                let a = String(body[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let b = String(body[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !a.isEmpty && !b.isEmpty { return (a, b) }
            }
        }
        return nil
    }

    /// 自然句式："把 A 连到 B" / "把 A 连接到 B"
    private static func splitConnected(_ text: String) -> (String, String)? {
        guard text.hasPrefix("把") else { return nil }
        let body = String(text.dropFirst())
        return splitPair(body)
    }
}

// MARK: - 桥接状态

/// Weak bridge from the App settings owner into the Core browser tool. The
/// source is only read on the main actor and never becomes a second settings
/// store; a missing owner falls back to BrowserSettings' fail-safe defaults.
@MainActor
private final class ProductionBrowserSettingsSource: @unchecked Sendable {
    private weak var center: SettingsCenter?
    private var fallback: BrowserSettings

    init(center: SettingsCenter?, fallback: BrowserSettings) {
        self.center = center
        self.fallback = fallback
    }

    func snapshot() -> BrowserSettings {
        center?.effectiveBrowserSettings ?? fallback
    }

    func update(_ settings: BrowserSettings) {
        fallback = settings
    }
}

/// 聊天区展示的「当前选中节点」上下文（画布 → 聊天）
struct NodeContextInfo: Equatable {
    let title: String
    let type: String
    let statusLabel: String
    let modelID: String?
    let inputCount: Int
    let outputCount: Int

    var modelLabel: String {
        guard let modelID, !modelID.isEmpty else { return "默认（未配置）" }
        return modelID
    }
}

// MARK: - Chat-facing Canvas runtime boundary (P3-ISO-01)

/// 聊天壳（`ContentView`）触达 Canvas runtime 的唯一具名边界。
///
/// 基线（blessed 头 `e7ab196637d382741e963ff127f253a08a02df40` 自测，
/// 计量口径 `git grep -o -E "bridge\.canvas\.[a-zA-Z]+" ContentView.swift`）：
/// 聊天视图体内有 19 处对 `CanvasStore` 成员的直连解引用。本边界把可在白名单
/// 内收窄的部分全部收进来，收拢后视图体内直连为 0；剩余的 `bridge.canvas`
/// 出现点只有「整只 store 交给 Canvas 自有视图」的对象 handoff，已在
/// `CanvasChatIsolationBoundaryTests` 内逐条枚举并如实记为 serial 残留。
///
/// 本类型刻意不做成第二套隔离机制，三件既有权威原样保留：
/// - `RuntimeIsolationProfile` 仍然独占 feature lane / runtime state 判定；
/// - `ChatCanvasBoundaryContract` 仍然独占 Canvas 变更的审批语义；
/// - `BridgeStore.dispatchCanvasMutation(_:)` 仍然是唯一的 Canvas 变更入口。
/// 这里只前置「只读投影」与三个不改图数据的 Canvas 本地 UI 命令。
@MainActor
struct ChatCanvasRuntimeBoundary {
    private let canvas: CanvasStore

    init(canvas: CanvasStore) {
        self.canvas = canvas
    }

    // MARK: E15 节点内容编辑器

    var contentEditorNodeID: UUID? { canvas.contentEditorNodeID }
    var hasContentEditor: Bool { canvas.contentEditorNodeID != nil }
    func closeContentEditor() { canvas.closeContentEditor() }

    // MARK: M6 资产预览区

    var isAssetPanelPresented: Bool { canvas.assetPanelPresented }
    var assetItemCount: Int { canvas.assetItems.count }
    var hasAssets: Bool { !canvas.assetItems.isEmpty }
    func setAssetPanelPresented(_ presented: Bool) {
        canvas.assetPanelPresented = presented
    }
    func toggleAssetPanel() { canvas.toggleAssetPanel() }

    // MARK: 图投影（只读，不写回）

    var isGraphRunning: Bool { canvas.isRunning }
    var hasGraphContent: Bool { !canvas.graph.nodes.isEmpty }
    var graphNodeCount: Int { canvas.graph.nodes.count }
    var graphEdgeCount: Int { canvas.graph.edges.count }

    // MARK: 状态条与分镜表入口

    var statusMessage: String? { canvas.statusMessage }
    func toggleStoryboardWorkbench() { canvas.showStoryboardWorkbench.toggle() }
}

/// Direct TTS observations supplied by a native read-only producer or a
/// synthetic test provider. Nil means no observation was made.
struct SpeechToolDirectObservations: Sendable {
    let voiceAvailable: Bool?
    let audioOutputDevicePresent: Bool?

    init(voiceAvailable: Bool? = nil, audioOutputDevicePresent: Bool? = nil) {
        self.voiceAvailable = voiceAvailable
        self.audioOutputDevicePresent = audioOutputDevicePresent
    }
}

/// Read-only command dependency observation. Neither an unknown route nor the
/// absence of a known blocker grants permission or proves network health.
enum ComposerCommandReadinessObservation: Equatable, Sendable {
    case knownBlocked(reason: String)
    case unknown
    case noKnownBlocker

    var knownBlockerReason: String? {
        guard case .knownBlocked(let reason) = self else { return nil }
        return reason
    }
}

@MainActor
@Observable
final class BridgeStore {
    @ObservationIgnored private let canvasStorage: CanvasStore?
    /// A Phase 3 Chat composition has no Canvas object or Canvas store factory.
    var canvasIfAvailable: CanvasStore? {
        canvasFeatureLane == .phase4OptIn ? canvasStorage : nil
    }
    /// Existing Phase 4 Canvas-only consumers retain their nonoptional API.
    /// Phase 3 consumers must use `canvasIfAvailable` and never enter this path.
    var canvas: CanvasStore {
        guard let canvas = canvasIfAvailable else {
            preconditionFailure("Canvas is absent from the Phase 3 Chat composition")
        }
        return canvas
    }
    let chat: ChatStore
    /// The same concrete producer assembly used by ordinary orchestrate.
    /// A fresh user-event admission supplies the current context and Goal;
    /// this factory alone does not authorize or start a retry.
    @ObservationIgnored private var productionChildModelSettings: AgentSettings = .default
    @ObservationIgnored private var taskCenterRetryOrchestratorFactory:
        (@Sendable (AgentExecutionContextSnapshot, GoalEnvelope) async throws -> AgentOrchestrator)?
    @ObservationIgnored private var taskCenterRetryAssemblyGeneration = UUID()
    /// Both composer surfaces observe one speech-input lifecycle. The driver is
    /// injectable so its permission and late-result paths can be exercised
    /// without opening a microphone or showing a system prompt.
    private(set) var composerSpeechPhase: ComposerSpeechPhase = .idle
    @ObservationIgnored private var composerSpeechDriverOverride: (any ComposerSpeechInputDriver)? = nil
    @ObservationIgnored private var composerSpeechActiveDriver: (any ComposerSpeechInputDriver)? = nil
    @ObservationIgnored private var composerSpeechContext: ComposerSpeechContext? = nil
    @ObservationIgnored private var composerSpeechGeneration: UUID? = nil
    @ObservationIgnored private var composerSpeechObservedSessionID: UUID? = nil
    @ObservationIgnored private var composerSpeechSessionTransitionEpoch: UInt64 = 0
    /// Canvas is an optional capability of the composition, never a
    /// prerequisite for production Chat startup.
    private var configuredCanvasRuntimeState: RuntimeIsolationProfile.CanvasRuntimeState
    private(set) var canvasRuntimeState: RuntimeIsolationProfile.CanvasRuntimeState
    /// Explicit Phase 4 seam. The Phase 3 packaged App passes
    /// `.phase3NonCanvas`; that lane cannot publish Canvas capabilities or
    /// attach Canvas events to Chat.
    private(set) var canvasFeatureLane: RuntimeIsolationProfile.CanvasFeatureLane
    private(set) var productionChatComposition: RuntimeIsolationProfile.ChatCompositionContract
    /// C 线：文档是当前会话上下文的一部分，不是独立 workspace 状态。
    /// 存储目录与会话持久化同源，具体 Tab 通过 sessionID 分区。
    let sessionDocuments: SessionDocumentStore
    /// The App root's canonical SessionStore is also SettingsCenter's writer.
    /// Omitted by standalone Bridge fixtures, which retain their own attach path.
    @ObservationIgnored private let injectedSessionStore: SessionStore?
    /// 当前选中节点的上下文（聊天侧栏顶部展示；点画布空白清除）
    var selectedNodeContext: NodeContextInfo?
    /// 主窗口布局模式（ContentView 绑定；命令面板可切换）
    var layoutMode: LayoutMode = .split {
        didSet { splitLayoutCommandAvailability.update(isSplit: layoutMode == .split) }
    }
    @ObservationIgnored let splitLayoutCommandAvailability = SplitLayoutCommandAvailability()
    /// 命令面板是否展示（Cmd+K 触发）
    var isCommandPalettePresented = false
    /// A menu/palette row with required arguments opens the existing query
    /// editor. The draft is consumed once when that editor appears.
    private var commandPaletteDraft: String?

    /// E6 工具审批中心：AgentLoop 工具调用 → 弹窗审批（ContentView 呈现）。
    let approvalCenter = ApprovalPromptCenter()
    private var activeChildExecutionIDs: Set<String> = []
    var hasActiveChildExecutions: Bool { !activeChildExecutionIDs.isEmpty }
    private func recordChildExecutionActivity(_ id: String, running: Bool) {
        if running { activeChildExecutionIDs.insert(id) }
        else { activeChildExecutionIDs.remove(id) }
    }
    let browserInteractionRules = BrowserInteractionRuleStore()
    /// Direct Canvas commands share the Composer facts/grant store with
    /// Agent turns. The base is installed only by the production root.
    private var composerCanvasPolicyBase: (any ToolExecutor)?
    private var composerApprovalGate: ApprovalGate?
    @ObservationIgnored
    private var productionApprovalDelegate: (any ApprovalDelegate)?
    private(set) var approvalReceipts: [ApprovalReceipt] = []
    private(set) var composerApprovalReceipts: [ComposerApprovalReceipt] = []
    @ObservationIgnored private let canvasMutationCoordinatorStorage: CanvasMutationCoordinator?
    var canvasMutationCoordinator: CanvasMutationCoordinator {
        guard let coordinator = canvasMutationCoordinatorStorage else {
            preconditionFailure("Canvas mutation is absent from the Phase 3 Chat composition")
        }
        return coordinator
    }
    private var nextCanvasMutationTurnID = 0
    /// Observable only for focused negative-path evidence. It increments at
    /// the final Canvas command seam, after Composer and Policy gates pass.
    private(set) var composerCanvasDispatchCount = 0
    private let allowsLegacyCanvasCommandExecutionForTests: Bool
    /// Completion hook for the latest direct Canvas command task. It is
    /// observable for deterministic boundary tests; production behavior still
    /// remains fire-and-forget at the ChatStore seam.
    @ObservationIgnored
    private(set) var lastCanvasMutationTask: Task<Void, Never>?
    /// P3-SAFE/P3-REC: one immutable safety snapshot for all optional runtime
    /// admission. The epoch rejects results captured before a safety change.
    private(set) var safetyRuntimeSnapshot: SafetyRuntimeSnapshot = .defaults
    private var safetyRuntimeEpoch: UInt64 = 0
    private(set) var safetyRuntimeCancellationRequests = 0
    private(set) var safetyRuntimeCheckpointRequests = 0
    private(set) var lastSafetyRuntimeTransitionReceipt = SafetyRuntimeTransitionReceipt(
        generation: 0
    )

    var canvasMutationReceipts: [CanvasMutationReceipt] {
        canvasMutationCoordinatorStorage?.receipts ?? []
    }

    /// 聊天侧触达 Canvas runtime 的唯一具名边界（P3-ISO-01）。
    /// `canvas` 属性签名保持不变：命令面板与 App 根等白名单外消费者仍按原样使用，
    /// 本边界只为聊天壳新增一个读取面，不删改任何既有公开面。
    var canvasBoundary: ChatCanvasRuntimeBoundary {
        ChatCanvasRuntimeBoundary(canvas: canvas)
    }

    var canvasBoundaryIfAvailable: ChatCanvasRuntimeBoundary? {
        canvasIfAvailable.map(ChatCanvasRuntimeBoundary.init(canvas:))
    }

    // MARK: - P3-SAFE/P3-SET/P3-REC runtime boundary

    /// Replace the live snapshot from SettingsCenter. No external service or
    /// network is consulted, so this remains usable while optional modules are
    /// unavailable or offline.
    @discardableResult
    func updateSafetyRuntimeSnapshot(
        _ snapshot: SafetyRuntimeSnapshot
    ) -> SafetyRuntimeTransitionReceipt {
        guard snapshot != safetyRuntimeSnapshot else {
            return lastSafetyRuntimeTransitionReceipt
        }
        let wasLocked = safetyRuntimeSnapshot.isOptionalModuleLockActive
        safetyRuntimeSnapshot = snapshot
        safetyRuntimeEpoch &+= 1
        if !isSafetyFeatureEnabled(.externalAgents)
            || !isSafetyFeatureEnabled(.childOrchestration) {
            orchestrationEnabled = false
            productionExternalRunners = [:]
        }
        var cancelledOptionalWorkIDs: [String] = []
        var retainedCheckpointIDs: [String] = []
        if snapshot.isOptionalModuleLockActive && !wasLocked {
            let transition = requestSafetyRuntimeCancellationAndCheckpoint()
            cancelledOptionalWorkIDs = transition.cancelledOptionalWorkIDs
            retainedCheckpointIDs = transition.retainedCheckpointIDs
        }
        let receipt = SafetyRuntimeTransitionReceipt(
            generation: safetyRuntimeEpoch,
            cancelledOptionalWorkIDs: cancelledOptionalWorkIDs,
            retainedCheckpointIDs: retainedCheckpointIDs
        )
        lastSafetyRuntimeTransitionReceipt = receipt
        updateEffectiveCanvasRuntimeState()
        // P3-CHILD-40: propagate the single app safety state to the ONE shared
        // child governor — engaging the app Kill Switch makes the governor refuse
        // new launches (fail-closed), lifting it resumes fair dispatch. Reads the
        // just-committed snapshot, so this is the same source of truth as the UI.
        reconcileChildGovernorKillSwitch()
        return receipt
    }

    /// Re-evaluate the effective Canvas capability without rebuilding Chat.
    /// A safety lock can only remove Canvas capabilities; it never removes the
    /// independent Chat consumer.
    private func updateEffectiveCanvasRuntimeState() {
        let effectiveState = canvasFeatureLane == .phase3NonCanvas
            ? .disabled
            : (isSafetyFeatureEnabled(.canvas)
                ? configuredCanvasRuntimeState
                : .disabled)
        guard effectiveState != canvasRuntimeState else { return }
        canvasRuntimeState = effectiveState
        productionChatComposition = .make(canvasState: effectiveState)

        // Existing immutable turns retain their own facts. New submissions
        // receive a rotated fact source with the effective Canvas surface.
        let currentFacts = chat.composerPolicyFacts
        guard !currentFacts.revision.isEmpty,
              currentFacts.revision != "unconfigured" else { return }
        let canvasCapabilities = productionChatComposition.canvasCapabilities
        let refreshedFacts = ComposerPolicyFactSource(
            knownCapabilities: currentFacts.knownCapabilities
                .subtracting(["canvas_read", "canvas_mutation"])
                .union(canvasCapabilities),
            grantedCapabilities: currentFacts.grantedCapabilities
                .subtracting(["canvas_read", "canvas_mutation"])
                .union(canvasCapabilities),
            allowedWriteRoots: currentFacts.allowedWriteRoots,
            workspaceID: currentFacts.workspaceID,
            revision: "\(currentFacts.revision):canvas-\(effectiveState.rawValue)",
            grantEpoch: "\(currentFacts.grantEpoch):canvas-\(effectiveState.rawValue)",
            leaseID: currentFacts.leaseID,
            expiresAt: currentFacts.expiresAt,
            revoked: currentFacts.revoked,
            autonomyCeiling: currentFacts.autonomyCeiling
        )
        chat.configureComposerPolicy(refreshedFacts)
        if var engine = chat.agentEngine as? AgentLoopChatEngine {
            engine.updateComposerPolicy(refreshedFacts)
            chat.agentEngine = engine
        }
    }

    func isSafetyFeatureEnabled(_ feature: SafetyControlFeature) -> Bool {
        safetyRuntimeSnapshot.isEnabled(feature)
    }

    var safetyRuntimeGeneration: UInt64 {
        safetyRuntimeEpoch
    }

    /// Display-only Composer facts. These read the same applied safety state
    /// and chat model receipt used by the production composition; neither
    /// projection grants a capability or probes a provider.
    func composerBoundaryProjection(for submission: ComposerSubmissionSnapshot) -> String? {
        guard chat.activeSessionID?.uuidString == submission.sessionID else { return nil }
        return Self.composerBoundaryText(safetyRuntimeSnapshot)
    }

    func composerProviderProjection(for submission: ComposerSubmissionSnapshot) -> String? {
        guard chat.activeSessionID?.uuidString == submission.sessionID,
              let providerID = chat.selectedReadinessProviderID,
              let modelID = chat.selectedModelID,
              let receipt = chat.chatModelPickerReceipt(
                providerID: providerID,
                modelID: modelID
              ),
              receipt.isApplied else { return nil }
        return Self.composerProviderText(
            receipt: receipt,
            launchStatus: chat.providerLaunchSnapshot.status(for: providerID)
        )
    }

    /// Combines the adjudicator's actual route with this turn's existing Chat
    /// facts. Only a concrete blocker is suitable for a disabled menu reason;
    /// unknown and no-known-blocker are never execution approvals.
    func composerCommandReadinessObservation(
        for commandID: String
    ) -> ComposerCommandReadinessObservation {
        switch ComposerCommandAdjudicationCenter.readinessContract(for: commandID) {
        case .unregistered:
            return .knownBlocked(reason: "命令未注册")
        case .missingExecutor(let reason):
            return .knownBlocked(reason: reason)
        case .scopedMemoryProposal:
            return chat.activeMemoryScope?.isValid == true
                ? .noKnownBlocker : .knownBlocked(reason: "当前会话没有有效项目记忆范围")
        case .scopedAdditionalDirectory:
            guard let id = chat.activeSessionID,
                  let session = chat.sessions.first(where: { $0.id == id }),
                  session.projectID?.isEmpty == false, session.workingDirectory != nil,
                  productionBuiltinToolExecutor != nil, productionAttachmentRefresh != nil,
                  !productionAttachmentAdmissionSuspended else {
                return .knownBlocked(reason: "当前会话没有已装配的项目目录授权")
            }
            return .noKnownBlocker
        case .presentedToolApproval:
            let facts = chat.composerPolicyFacts
            guard let target = approvalCenter.pendingRequest, target.binding?.isValid == true,
                  target.sessionID == chat.activeSessionID?.uuidString,
                  target.policyRevision == facts.revision, target.grantEpoch == facts.grantEpoch,
                  let expiry = target.expiresAt, expiry > Date() else {
                return .knownBlocked(reason: "当前会话没有同策略身份的有效工具审批请求")
            }
            return .noKnownBlocker
        case .displayOnly, .localClipboard, .localDesktopAction, .canonicalSettingsHandoff, .canonicalModelSelection:
            return .noKnownBlocker
        case .unverifiedExecutionRoute:
            return .unknown
        case .compactConditionalProvider(let keepRecent):
            // ChatStore.compactContext returns before activeProvider() when the
            // non-system history is short. Do not even call the settings
            // source in that case, or add a fictitious Provider prerequisite.
            let historyCount = chat.messages.filter { $0.role != .system }.count
            guard historyCount > keepRecent else { return .noKnownBlocker }
            // The existing explicit compaction override is resolved before
            // activeProvider(), so ordinary settings/provider facts are not
            // prerequisites for that route either.
            if chat.compactionProviderOverride != nil { return .noKnownBlocker }

            let settingsAvailable = chat.effectiveSettingsSnapshotSource.map { $0() != nil }
            let mockMode = chat.isMockMode
            let providerID = mockMode ? nil : chat.selectedReadinessProviderID
            let modelSelectionValid: Bool?
            if chat.providerReadinessStore != nil, !mockMode {
                if let providerID, let modelID = chat.selectedModelID {
                    modelSelectionValid = chat.canSelectChatModel(
                        providerID: providerID, modelID: modelID
                    ) && chat.chatModelPickerReceipt(
                        providerID: providerID, modelID: modelID
                    ) != nil
                } else {
                    modelSelectionValid = false
                }
            } else {
                modelSelectionValid = nil
            }
            return Self.longHistoryCompactObservation(
                settingsAvailable: settingsAvailable,
                mockMode: mockMode,
                modelSelectionValid: modelSelectionValid,
                launchStatus: providerID.flatMap { chat.providerLaunchSnapshot.status(for: $0) }
            )
        }
    }

    /// Synthetic fact seam; this classifier never constructs or contacts a
    /// Provider. A healthy construction is not evidence of request success.
    static func longHistoryCompactObservation(
        settingsAvailable: Bool?,
        mockMode: Bool,
        modelSelectionValid: Bool?,
        launchStatus: ProviderLaunchStatus?
    ) -> ComposerCommandReadinessObservation {
        if settingsAvailable == false {
            return .knownBlocked(reason: "设置事务状态未知，当前不能压缩上下文")
        }
        if mockMode { return .noKnownBlocker }
        if modelSelectionValid == false {
            return .knownBlocked(reason: "当前模型未在目录中完成可用选择")
        }
        switch launchStatus?.state {
        case .some(.degraded(.credentialUnavailable)):
            return .knownBlocked(reason: "当前 Provider 凭据不可用")
        case .some(.degraded(.keychainUnavailable)):
            return .knownBlocked(reason: "当前 Provider 钥匙串不可用")
        case .some(.degraded(.initializationFailed)):
            return .knownBlocked(reason: "当前 Provider 构造失败")
        case .some(.ready):
            return .noKnownBlocker
        case nil:
            return .unknown
        }
    }

    static func composerBoundaryText(_ state: SafetyRuntimeSnapshot) -> String {
        let safeMode = state.safeModeEnabled ? "开" : "关"
        let killSwitch = state.killSwitchEnabled ? "开" : "关"
        let optionalLock = state.isOptionalModuleLockActive ? "已锁定" : "未全局锁定"
        return "安全总开关：Safe Mode \(safeMode)，Kill Switch \(killSwitch)；可选能力\(optionalLock)。具体工具权限仍按各自门禁判定。"
    }

    static func composerProviderText(
        receipt: ChatModelPickerApplyReceipt,
        launchStatus: ProviderLaunchStatus?
    ) -> String {
        let provider = safeComposerIdentifier(receipt.providerID)
        let model = safeComposerIdentifier(receipt.modelID)
        let health: String
        switch launchStatus?.state {
        case .some(.ready): health = "构造成功；不代表本次请求已连通"
        case .some(.degraded(.credentialUnavailable)): health = "凭据不可用"
        case .some(.degraded(.keychainUnavailable)): health = "钥匙串不可用"
        case .some(.degraded(.initializationFailed)): health = "构造失败"
        case nil: health = "构造状态未观测"
        }
        return "已应用 Provider/Model：\(provider) / \(model)；Provider \(health)。"
    }

    private static func safeComposerIdentifier(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_.:/")
        )
        guard !value.isEmpty,
              value.count <= 80,
              !value.hasPrefix("/"),
              !value.contains("//"),
              value.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              ContentSecretRedactor.redact(value) == value else {
            return "标识已隐藏"
        }
        return value
    }

    private func safetyRuntimeToken(
        for feature: SafetyControlFeature
    ) throws -> UInt64 {
        guard isSafetyFeatureEnabled(feature) else {
            throw SafetyRuntimeAdmissionError.featureDisabled(feature)
        }
        return safetyRuntimeEpoch
    }

    private func validateSafetyRuntimeToken(
        _ epoch: UInt64,
        for feature: SafetyControlFeature
    ) throws {
        guard safetyRuntimeEpoch == epoch,
              isSafetyFeatureEnabled(feature) else {
            lastSafetyRuntimeTransitionReceipt = SafetyRuntimeTransitionReceipt(
                generation: safetyRuntimeEpoch,
                cancelledOptionalWorkIDs: lastSafetyRuntimeTransitionReceipt.cancelledOptionalWorkIDs,
                retainedCheckpointIDs: lastSafetyRuntimeTransitionReceipt.retainedCheckpointIDs,
                lateCallbackRejected: true
            )
            throw SafetyRuntimeAdmissionError.staleRuntime(feature)
        }
    }

    private func requestSafetyRuntimeCancellationAndCheckpoint() -> (
        cancelledOptionalWorkIDs: [String],
        retainedCheckpointIDs: [String]
    ) {
        safetyRuntimeCancellationRequests += 1
        safetyRuntimeCheckpointRequests += 1
        var cancelledOptionalWorkIDs: [String] = []
        if lastCanvasMutationTask != nil {
            cancelledOptionalWorkIDs.append("canvas.mutation")
        }
        lastCanvasMutationTask?.cancel()
        if lastAgentAdjustTask != nil {
            cancelledOptionalWorkIDs.append("canvas.agent-adjust")
        }
        lastAgentAdjustTask?.cancel()
        if chat.hasStreamingTasksForSafety {
            chat.stopAllStreamingForSafety()
            cancelledOptionalWorkIDs.append("chat.streaming")
        }
        // Preserve the existing draft/checkpoint path without performing any
        // new module discovery or high-frequency UI work.
        canvasIfAvailable?.noteGraphChanged()
        // Capture the existing shared governor's durable policy/queue facts.
        // Its admission transaction persists before returning a permit; this
        // safety transition retains the same snapshot for the recovery surface.
        if let governor = orchestrationChildGovernor {
            lastChildGovernorCheckpointTask = Task { @MainActor [weak self] in
                let snapshot = await governor.checkpoint()
                self?.lastChildGovernorCheckpoint = snapshot
            }
        }
        let retainedCheckpointIDs = cancelledOptionalWorkIDs.isEmpty
            ? []
            : ["canvas-draft-generation-\(safetyRuntimeEpoch)"]
        return (cancelledOptionalWorkIDs, retainedCheckpointIDs)
    }

    /// Safety, file policy and child settings all rebind through the same
    /// configuration queue. SafeMode/disabled orchestration also stop captured
    /// old engines from obtaining a fresh permit on the retained actor.
    private func reconcileChildGovernorKillSwitch() {
        productionAttachmentRefresh?()
    }

    /// Observe the exact governor shared by both production orchestration
    /// sites. Rebind cancels the old stream and fences any already-delivered
    /// event by generation and actor identity; an absent governor leaves the
    /// runtime stages unreported rather than inventing zero children.
    private func bindChildGovernorRuntimeReport(_ governor: ChildConcurrencyGovernor?) {
        childGovernorReportGeneration &+= 1
        childGovernorReportTask?.cancel()
        childGovernorReportTask = nil
        guard let governor else { return }
        let generation = childGovernorReportGeneration
        childGovernorReportTask = Task { @MainActor [weak self] in
            let updates = await governor.checkpointUpdates()
            for await checkpoint in updates {
                guard let self, !Task.isCancelled,
                      self.childGovernorReportGeneration == generation,
                      self.orchestrationChildGovernor === governor else { break }
                // Do not combine a pending policy's checkpoint with the
                // previously published selection. The accepted bind subscribes
                // anew and receives the actor's complete current checkpoint.
                self.lastChildGovernorCheckpoint = checkpoint
                guard !self.productionAttachmentAdmissionSuspended else { continue }
                guard let report = try? ChildConcurrencySelection.RuntimeReport(
                    actualRunning: checkpoint.globalActive - checkpoint.localWaitingRequests,
                    queued: checkpoint.queuedSessions.count + checkpoint.localWaitingRequests,
                    degradedCeiling: checkpoint.degradedCeiling,
                    newLaunchesStopped: checkpoint.killSwitchEngaged),
                      let projected = try? self.childConcurrencySelection.withRuntime(report) else {
                    self.childConcurrencySelection = try! self.childConcurrencySelection.withRuntime(nil)
                    continue
                }
                self.childConcurrencySelection = projected
            }
        }
    }

    /// Apply the live user policy to every production approval entry point.
    /// Composer facts rotate as well, so snapshots and grants issued under the
    /// previous policy cannot authorize a later call.
    private var legacyAutomaticApprovalCompatibilityActive = false
    private var productionConversationSettingsAvailable = false

    func updateApprovalPolicy(_ policy: ApprovalPolicy, legacyAutomaticCompatibility: Bool = false) {
        legacyAutomaticApprovalCompatibilityActive = legacyAutomaticCompatibility && policy == .riskOnlyAsk
        guard productionApprovalDelegate != nil else { return }

        approvalCenter.revokeSessionPermissions()
        let gate = makeProductionApprovalGate(policy: policy)
        composerApprovalGate = gate

        let currentFacts = chat.composerPolicyFacts
        guard !currentFacts.revision.isEmpty else {
            canvasMutationCoordinatorStorage?.updateComposerPolicy(
                facts: currentFacts,
                grants: chat.composerGrantStore,
                approvalGate: gate
            )
            if var engine = chat.agentEngine as? AgentLoopChatEngine {
                engine.loop.approvalGate = gate
                chat.agentEngine = engine
            }
            return
        }

        let revision = "\(currentFacts.revision):settings-\(UUID().uuidString)"
        let grantEpoch = "\(currentFacts.grantEpoch):settings-\(UUID().uuidString)"
        let refreshedFacts = ComposerPolicyFactSource(
            knownCapabilities: currentFacts.knownCapabilities,
            grantedCapabilities: currentFacts.grantedCapabilities,
            allowedWriteRoots: currentFacts.allowedWriteRoots,
            workspaceID: currentFacts.workspaceID,
            revision: revision,
            grantEpoch: grantEpoch,
            leaseID: currentFacts.leaseID,
            expiresAt: currentFacts.expiresAt,
            revoked: currentFacts.revoked,
            autonomyCeiling: currentFacts.autonomyCeiling
        )
        chat.configureComposerPolicy(refreshedFacts)
        canvasMutationCoordinatorStorage?.updateComposerPolicy(
            facts: refreshedFacts,
            grants: chat.composerGrantStore,
            approvalGate: gate
        )
        Task { await chat.composerGrantStore.revokeAll() }

        if var engine = chat.agentEngine as? AgentLoopChatEngine {
            engine.loop.approvalGate = gate
            engine.updateComposerPolicy(refreshedFacts)
            chat.agentEngine = engine
        }
    }

    private func makeProductionApprovalGate(policy: ApprovalPolicy) -> ApprovalGate {
        // A gate held by an in-flight turn must remain tied to the browser
        // resource that existed when the turn began. Re-attachment closes that
        // session; its late approval must never unlock the replacement.
        var gate = ApprovalGate(
            policy: policy,
            delegate: productionBrowserBoundDelegate(),
            onApprovalReceipt: productionApprovalReceiptSink(boundTo: productionBrowserTool?.session)
        )
        gate.terminalPolicySnapshot = productionBuiltinToolExecutor?.terminalPolicySnapshot
            ?? SettingsCenter.active?.terminalPolicySnapshot ?? .default
        if let mcpManager = SettingsCenter.active?.mcpManager {
            gate.mcpServerDisplayName = { mcpManager.server(id: $0)?.name }
        }
        gate.sessionTitles = chat.sessionTitleDirectory
        // These capabilities are owned by the App Composer/Agent boundary,
        // not by MinisCore's generic built-in tool table. Keep their policy
        // aligned with the same user-facing setting.
        let mutationPolicy: ApprovalPolicy = policy == .riskOnlyAsk
            ? .alwaysAsk
            : (policy == .never ? .deny : policy)
        gate.setPolicy(mutationPolicy, for: "canvas_mutation")
        gate.setPolicy(mutationPolicy, for: OrchestrationToolExecutor.toolName)
        if productionProjectSessionHandler != nil {
            for name in ProjectSessionToolContract.toolNames {
                let toolPolicy: ApprovalPolicy
                switch policy {
                case .deny, .never: toolPolicy = .deny
                case .alwaysAsk: toolPolicy = .alwaysAsk
                case .riskOnlyAsk:
                    toolPolicy = name == ProjectSessionToolContract.sessionCreate ? .alwaysAsk : .autoApprove
                case .autoApprove: toolPolicy = .autoApprove
                }
                if name == ProjectSessionToolContract.sessionCreate {
                    gate.setGloballyDerivedSessionCreatePolicy(toolPolicy)
                } else {
                    gate.setPolicy(toolPolicy, for: name)
                }
            }
        }
        if productionConversationSettingsAvailable {
            let settingPolicy: ApprovalPolicy = [.deny, .never].contains(policy) ? .deny : .alwaysAsk
            gate.setPolicy(settingPolicy, for: BL6SettingsToolApproval.catalogToolName)
            gate.setPolicy(settingPolicy, for: BL6SettingsToolApproval.toolName)
        }
        return gate
    }

    /// Explicit Agent-First orchestration feature state; default remains disabled.
    private(set) var orchestrationEnabled = false
    /// Provider/browser network is an explicit runtime-profile capability, not
    /// an ambient process capability. Disposable profiles set this false.
    private(set) var productionExternalNetworkAllowed = true
    private(set) var productionControlledFieldLoopbackAllowed = false
    var mm01FieldLane: DeepSeekMM01FieldLane?

    private func admitsProviderNetworkRoute(_ provider: any LLMProvider) -> Bool {
        if let mm01 = provider as? MM01FieldProvider {
            return mm01FieldLane?.admits(mm01) == true
        }
        if let provider = provider as? OpenAICompatibleProvider,
           DeepSeekEnvironmentPackageFieldBootstrap.admitsJourneyProvider(
               configured: chat.isolatedDeepSeekJourneyConfigured,
               providerName: provider.name, baseURL: provider.customBaseURL) { return true }
        if productionExternalNetworkAllowed { return true }
        if (provider as? MockProvider) === MockProvider.shared { return true }
        guard productionControlledFieldLoopbackAllowed,
              let controlled = provider as? OpenAICompatibleProvider,
              controlled.controlledFieldLoopbackOnly,
              let base = controlled.customBaseURL,
              let url = URL(string: base) else { return false }
        return ControlledFieldLoopbackPolicy.accepts(url)
    }
    /// Focused scheduling seam for the real fallback route worker.
    @ObservationIgnored var providerRuntimeFallbackPauseForTests: (@Sendable () async -> Void)?
    /// Synthetic filesystem gate for the real turn-directory admission path.
    @ObservationIgnored var contextDirectoryCanonicalizerForTests: (@Sendable (URL) -> URL)?
    /// P3-CHILD-40: read-only production projection of the canonical
    /// SettingsCenter selection passed during composition.
    private(set) var childConcurrencySelection = ChildConcurrencySelection.default
    @ObservationIgnored
    private var childGovernorReportTask: Task<Void, Never>?
    @ObservationIgnored
    private var childGovernorReportGeneration: UInt64 = 0
    @ObservationIgnored
    private var retainedProductionChildGovernor: ChildConcurrencyGovernor?
    @ObservationIgnored
    private(set) var childGovernorControlRevision: ChildConcurrencyGovernor.ControlRevision?
    @ObservationIgnored
    private var productionAttachmentGeneration: UInt64 = 0
    @ObservationIgnored
    private var productionAttachmentInProgress = false
    @ObservationIgnored
    private var productionAttachmentAdmissionSuspended = false
    @ObservationIgnored
    private var productionAttachmentSettingsSource: (() -> BL6EffectiveSettingsSnapshot?)?
    @ObservationIgnored
    private var productionAttachmentTask: Task<Void, Never>?
    @ObservationIgnored
    private var pendingProductionAttachment: ProductionAttachmentRequest?
    @ObservationIgnored
    private var productionAttachmentRefresh: (@MainActor () -> Void)?
    #if DEBUG
    /// Tests can observe a completed actor transaction before publication.
    /// Release builds have neither this observer nor its invocation.
    @ObservationIgnored
    var onProductionAttachmentPreparedForTesting: (@MainActor () -> Void)?
    #endif

    private struct ProductionAttachmentRequest {
        let generation: UInt64
        let sessionDirectory: URL
        let selection: ChildConcurrencySelection
        let enableOrchestration: Bool
        let safetyEpoch: UInt64
        let sessionID: UUID?
        let composerRevision: String
        let commit: @MainActor (ChildConcurrencyGovernor) -> Void
    }
    /// External runner registry owned by the production composition root.
    private(set) var productionExternalRunners: [String: any ExternalAgentRunner] = [:]
    var productionExternalRunnerNames: Set<String> { Set(productionExternalRunners.keys) }
    var productionExternalRunnerAvailability: [String: Bool] {
        productionExternalRunners.mapValues(\.isAvailable)
    }
    /// Identity seam for production wiring tests; not a second state source.
    private(set) var orchestrationTaskStore: AgentTaskStore?
    /// P3-CHILD-40 identity seam: the single cross-session child governor read
    /// back off the live static production orchestrator, so both orchestration
    /// sites (static executor + runtime-built orchestrators) account against
    /// one global ceiling. Nil until an orchestration-enabled attachment.
    private(set) var orchestrationChildGovernor: ChildConcurrencyGovernor?
    /// P3-CHILD-40: the ONE shared governor's Kill Switch is driven ONLY from
    /// the app's single safety-state owner (SettingsCenter → this store's
    /// `updateSafetyRuntimeSnapshot`), never a second source of truth. This
    /// observable handle exposes the last engage/lift reconciliation so boundary
    /// tests can await actor convergence deterministically (mirrors the existing
    /// `lastCanvasMutationTask` test seam); production never depends on it.
    @ObservationIgnored
    private(set) var lastChildGovernorSafetyTask: Task<Void, Never>?
    /// Last observation of the production governor; its durable journal is
    /// scoped to the same session directory and carries no launch authority.
    @ObservationIgnored
    private(set) var lastChildGovernorCheckpoint: ChildConcurrencyCheckpoint?
    @ObservationIgnored
    private(set) var lastChildGovernorCheckpointTask: Task<Void, Never>?
    @ObservationIgnored
    private var childGovernorCheckpointJournal: ChildGovernorCheckpointJournal2957?
    private(set) var childGovernorCheckpointRecoveryUnavailable = false
    /// Reopened queue facts remain pending for a fresh legal parent turn.
    var pendingChildLaunchRecovery: [ChildLaunchCheckpointRequest] {
        lastChildGovernorCheckpoint?.recoveredQueuedRequests ?? []
    }
    var unconfirmedChildLaunchRecovery: [ChildLaunchCheckpointRequest] {
        lastChildGovernorCheckpoint?.unconfirmedRequests ?? []
    }
    /// In-memory Agent-First task/run/event/receipt ledger; persistence/UI projection remain later gates.
    /// Canonical Agent-First task/run/event/receipt store shared by Bridge, Chat, Loop and Orchestrator.
    private(set) var agentTaskStore: AgentTaskStore
    /// Nil when the App grant/journal authority cannot be recovered.
    private(set) var productionProjectSessionHandler: ProjectSessionAppHandler?
    private let projectWorkspaceBindings = ProjectSessionWorkspaceBindings()
    /// App production consumer for Goal/Task Center controls. It stays fail-closed
    /// until attachProductionServices installs the active production Goal/Lease.
    let taskCenterControlConsumer: TaskCenterControlConsumer
    /// Durable A4 context-manifest journal owned by the same App composition root.
    /// It is deliberately separate from the task ledger file while sharing its
    /// parent directory for restart recovery and lifecycle scoping.
    let contextManifestStore: ContextManifestStore
    /// The App composition root supplies the same profile-scoped badge store
    /// to persistence and the visible session sidebar.
    let sessionBadgeStore: SessionBadgeStore
    /// A5 memory command consumer shares the durable memory store with the
    /// application settings path. The command registry never writes facts
    /// directly; it submits and approves through this consumer.
    private let commandMemoryStore: MemoryStore
    private let commandEnvStore: EnvVarStore?
    private let commandMemoryProposalConsumer: MemoryProposalConsumer
    /// The original App assembly fixes its MCP writer once. Standalone Bridge
    /// fixtures may remain unpinned; public MCP managers retain their APIs.
    private let canonicalMCPManager: MCPServerManager?
    /// Caller-readable admission of the MCP writer, separate from asynchronous
    /// attachment completion. A rejected owner never enters the attach queue.
    private(set) var productionMCPWriterAdmission: ProductionMCPWriterAdmission = .unpinned
    var providerRuntimeObservationPersistenceURL: URL?
    private(set) var providerRuntimeObservations: [ProviderRuntimeRouteObservation] = []
    private(set) var providerRuntimeObservationPersistenceError: String?
    private(set) var providerRuntimeObservationQuarantineURL: URL?
    private(set) var toolLifecycleRecoveryFailureURL: URL?
    private enum ProviderRuntimeObservationJournalLoad: Sendable {
        case missing
        case stored([ProviderRuntimeRouteObservation])
        case failed(String)
    }
    @ObservationIgnored private var loadedProviderRuntimeObservationDirectory: URL?
    @ObservationIgnored private var preparedProviderRuntimeObservationJournal:
        (directory: URL, load: ProviderRuntimeObservationJournalLoad)?
    @ObservationIgnored
    var readProviderRuntimeObservationJournalForTesting: (@Sendable (URL) throws -> Data)?

    /// RECOVERY-08: the one published recovery-notice surface. Isolation of
    /// corrupt/incompatible durable data already happens here and in the
    /// canonical task ledger, but two domains were silent: (a) a quarantined
    /// provider-runtime observation journal moved to a `*.corrupt-<uuid>.json`
    /// sidecar, and (b) the agent-task ledger's orphaned-temporary-file /
    /// persistence diagnostic. This is a read-only projection of facts already
    /// owned elsewhere (`providerRuntimeObservationQuarantineURL`,
    /// `agentTaskStore.persistenceDiagnostics()`); it stores nothing, so it
    /// adds no second state source. The App root renders these notices as a
    /// non-blocking banner; launch never fails because of them.
    var recoveryNotices: [String] {
        var notices: [String] = []
        if let engine = chat.agentEngine as? AgentLoopChatEngine,
           let failure = engine.contextRecoveryFailure,
           let message = failure.errorDescription {
            notices.append(message)
        }
        if let quarantine = providerRuntimeObservationQuarantineURL {
            notices.append(
                "Provider 运行时观察日志已损坏，原始字节已整体移动到 \(quarantine.path)，"
                    + "本次启动继续使用新的日志。"
            )
        }
        if let failedURL = toolLifecycleRecoveryFailureURL {
            notices.append(
                "工具生命周期记录无法恢复；原文件保留在 \(failedURL.path)，"
                    + "新回合已阻断。"
            )
        }
        if let diagnostic = agentTaskStore.persistenceDiagnostics() {
            notices.append(
                "任务账本恢复提示（\(diagnostic.operation): \(diagnostic.reason)）："
                    + diagnostic.message
            )
        }
        if childGovernorCheckpointRecoveryUnavailable {
            notices.append("子任务排队记录无法恢复，新任务启动已阻断；请先核对恢复记录。")
        }
        if !pendingChildLaunchRecovery.isEmpty {
            notices.append("已恢复 \(pendingChildLaunchRecovery.count) 个排队任务，等待在新回合确认并继续。")
        }
        if !unconfirmedChildLaunchRecovery.isEmpty {
            notices.append("此前启动的 \(unconfirmedChildLaunchRecovery.count) 个子任务结果待核对，未重新启动。")
        }
        return notices
    }

    /// Durable App consumer for route outcomes. The route emits from its
    /// provider task, so the sink hops back to this MainActor-owned journal.
    func recordProviderRuntimeObservation(_ observation: ProviderRuntimeRouteObservation) {
        providerRuntimeObservations.append(observation)
        if providerRuntimeObservations.count > 64 {
            providerRuntimeObservations.removeFirst(
                providerRuntimeObservations.count - 64
            )
        }
        guard let url = providerRuntimeObservationPersistenceURL else { return }
        do {
            let data = try JSONEncoder().encode(providerRuntimeObservations)
            try data.write(to: url, options: .atomic)
        } catch {
            providerRuntimeObservationPersistenceError = String(describing: error)
        }
    }

    private func persistProviderRuntimeObservations() throws {
        guard let url = providerRuntimeObservationPersistenceURL else { return }
        let data = try JSONEncoder().encode(providerRuntimeObservations)
        try data.write(to: url, options: .atomic)
    }

    private func quarantineCorruptProviderRuntimeObservationJournal(
        at url: URL
    ) -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let quarantine = url.deletingLastPathComponent().appendingPathComponent(
            "provider-runtime-observations-v1.corrupt-\(UUID().uuidString).json"
        )
        do {
            try FileManager.default.moveItem(at: url, to: quarantine)
            providerRuntimeObservationQuarantineURL = quarantine
            return quarantine
        } catch {
            providerRuntimeObservationPersistenceError = String(describing: error)
            return nil
        }
    }

    /// Read-only task-center projection sourced from the canonical AgentTaskStore.
    /// UI consumers must not mutate lifecycle state through this value.
    var taskCenterObservation: TaskCenterObservationSnapshot {
        TaskCenterObservationSnapshot(taskStore: agentTaskStore)
    }

    /// Number of queued child/task records in the canonical task ledger.
    var childConcurrencyQueuedCount: Int {
        taskCenterObservation.counts.queued
    }

    /// Goal/Lease projection uses the same consumer binding as production controls.
    /// Without production wiring it intentionally falls back to unbound read-only facts.
    func taskCenterGoalProjection(now: Date = Date()) -> GoalTaskCenterProjection {
        taskCenterControlConsumer.project(now: now)
    }

    @discardableResult
    func executeTaskCenterControl(
        _ request: TaskCenterControlRequest,
        now: Date = Date()
    ) throws -> TaskCenterControlReceipt {
        try taskCenterControlConsumer.execute(request, now: now)
    }

    /// Only the existing Composer wrapper may invoke this typed dispatch.
    /// It retains the real join result, never a displayed completion value.
    private final class TaskCenterRetryDispatchExecutor: ToolExecutor, @unchecked Sendable {
        typealias Result = (receipt: TaskCenterControlReceipt, report: SubAgentReport)
        private let operation: @Sendable () async throws -> Result
        private let inputDigest: String
        private let lock = NSLock()
        private var completed: Result?
        init(inputDigest: String, operation: @escaping @Sendable () async throws -> Result) {
            self.inputDigest = inputDigest
            self.operation = operation
        }
        var result: Result? { lock.withLock { completed } }
        func execute(name: String, input: [String: Any]) async throws -> String {
            guard name == OrchestrationToolExecutor.toolName,
                  try ComposerToolInput(input).digest == inputDigest else {
                throw ComposerAuthorizationError.authorizationBindingMismatch
            }
            let result = try await operation()
            lock.withLock { completed = result }
            return result.report.summaryLine
        }
    }

    /// A retry click is admitted as a new ordinary user event before the
    /// existing Task Center control can create a run. Durable source data and
    /// current runtime authority remain separate throughout dispatch.
    @discardableResult
    func executeTaskCenterRetryFromUserEvent(
        _ request: TaskCenterControlRequest,
        now: Date = Date()
    ) async throws -> TaskCenterControlReceipt {
        guard request.action == .retry else {
            throw TaskCenterControlConsumerError.unavailable
        }
        if let prior = try taskCenterControlConsumer.previousControlReceipt(for: request) {
            return prior
        }
        guard let originalRunID = request.runID,
              let task = agentTaskStore.snapshot(taskID: request.taskID,
                                                 parentID: request.parentID),
              let source = task.sourceSessionID.flatMap(UUID.init(uuidString:)),
              chat.activeSessionID == source,
              let factory = taskCenterRetryOrchestratorFactory,
              let originalRequest = agentTaskStore.settledFailedChildLaunchIntent(
                  taskID: request.taskID, originalParentID: request.parentID,
                  runID: originalRunID
              ),
              let originalFact = taskCenterControlConsumer.project(now: now).fact(
                  taskID: request.taskID, parentID: request.parentID
              ),
              originalFact.revision == request.revision,
              originalFact.scopeID == request.scopeID,
              originalFact.leaseState == .active,
              agentTaskStore.controlSnapshot(taskID: request.taskID,
                  parentID: request.parentID)?.runID == originalRunID else {
            throw TaskCenterControlConsumerError.retryRequestUnavailable
        }
        let generation = taskCenterRetryAssemblyGeneration
        let admission = try await chat.admitTaskCenterRetryUserEvent(
            sourceSessionID: source, logicalTaskID: request.taskID
        )
        do {
            guard !Task.isCancelled,
                  taskCenterRetryAssemblyGeneration == generation,
                  chat.activeSessionID == source,
                  admission.sourceSessionID == source,
                  admission.logicalTaskID == request.taskID,
                  let freshPolicy = taskCenterControlConsumer.topLevelTaskGoalLease(
                      taskID: admission.composerSnapshot.taskID
                  ),
                  freshPolicy.lease.expiresAt > Date(),
                  let currentFact = taskCenterControlConsumer.project().fact(
                      taskID: request.taskID, parentID: request.parentID
                  ),
                  currentFact.revision == request.revision,
                  currentFact.scopeID == request.scopeID,
                  currentFact.leaseState == .active,
                  agentTaskStore.controlSnapshot(taskID: request.taskID,
                      parentID: request.parentID)?.runID == originalRunID else {
                throw TaskCenterControlConsumerError.unavailable
            }
            let producer = try await factory(admission.context, freshPolicy.goal)
            guard let retry = await producer.makeFreshChildRetryExecution(
                taskID: request.taskID, originalParentID: request.parentID,
                originalRunID: originalRunID
            ), taskCenterRetryAssemblyGeneration == generation,
               chat.activeSessionID == source, !Task.isCancelled else {
                throw TaskCenterControlConsumerError.retryRequestUnavailable
            }
            let currentFacts = chat.composerPolicyFacts
            // Bind consent to the durable original request as well as the
            // logical target. No instructions are reconstructed from output.
            let originalPayload = try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(originalRequest.task)
            )
            let input = try ComposerToolInput([
                "task_id": request.taskID, "original_parent_id": request.parentID,
                "original_run_id": originalRunID, "retry_request_id": request.idempotencyKey,
                "original_request": originalPayload
            ])
            let dispatch = TaskCenterRetryDispatchExecutor(inputDigest: input.digest) { [weak self] in
                guard let self else { throw TaskCenterControlConsumerError.unavailable }
                return try await self.dispatchAuthorizedTaskCenterRetry(
                    request, retry: retry, source: source,
                    generation: generation, expectedFacts: currentFacts,
                    expectedOriginalRequest: originalRequest.task
                )
            }
            let policy = ComposerPolicyEnforcedToolExecutor(
                base: dispatch,
                controller: ComposerAuthorizationController(
                    snapshot: admission.composerSnapshot, facts: currentFacts,
                    grants: chat.composerGrantStore
                ),
                approvalGate: admission.context.approvalGate,
                onApprovalReceipt: { [weak self] receipt in
                    Task { @MainActor [weak self] in
                        self?.composerApprovalReceipts.append(receipt)
                    }
                }
            )
            let resultText = try await AgentExecutionContext.$current.withValue(admission.context) {
                try await policy.execute(callID: request.idempotencyKey,
                    name: OrchestrationToolExecutor.toolName, input: input)
            }
            guard let completed = dispatch.result else {
                // Plan is the original Composer dry-run decision. It must not
                // manufacture a control receipt, new run or completed child.
                _ = await chat.finishTaskCenterRetryAdmission(
                    admission, assistantText: resultText, succeeded: false
                )
                throw TaskCenterControlConsumerError.retryDidNotDispatch
            }
            guard let parent = admission.context.parentRuntimeIdentity,
                  let settled = agentTaskStore.receipt(runID: completed.receipt.resultingRunID ?? "")
            else { throw TaskCenterControlConsumerError.unavailable }
            let parentOutcome: AgentParentTurnTerminalFact.Outcome
            switch settled.outcome {
            case .succeeded: parentOutcome = .succeeded
            case .failed: parentOutcome = .failed
            case .cancelled: parentOutcome = .cancelled
            }
            guard try agentTaskStore.recordParentTurnTerminal(
                parent: parent, execution: admission.executionIdentity, outcome: parentOutcome
            ) != nil else { throw TaskCenterControlConsumerError.unavailable }
            let succeeded = settled.outcome == .succeeded
            _ = await chat.finishTaskCenterRetryAdmission(
                admission, assistantText: completed.report.summaryLine, succeeded: succeeded
            )
            return completed.receipt
        } catch {
            // If an owned attempt exists but has no settled receipt, the
            // Store's parent join records that child as needsUserReview. An
            // UNKNOWN physical effect never becomes a fabricated success.
            if let parent = admission.context.parentRuntimeIdentity,
               let runID = agentTaskStore.controlSnapshot(taskID: request.taskID,
                   parentID: request.parentID)?.runID,
               agentTaskStore.retryRunRuntimeBinding(runID: runID)?.parent == parent {
                let cancelled = await admission.context.parentTurnHandle?.isCancelled() ?? false
                do {
                    _ = try agentTaskStore.recordParentTurnTerminal(
                        parent: parent, execution: admission.executionIdentity,
                        outcome: cancelled ? .cancelled : .failed
                    )
                } catch {
                    _ = await chat.finishTaskCenterRetryAdmission(
                        admission, assistantText: "任务终态无法持久化，请查看任务回执并复核。", succeeded: false
                    )
                    throw error
                }
            }
            _ = await chat.finishTaskCenterRetryAdmission(
                admission, assistantText: "重试未完成：当前请求或执行授权无法验证。", succeeded: false
            )
            throw error
        }
    }

    private func dispatchAuthorizedTaskCenterRetry(
        _ request: TaskCenterControlRequest, retry: ChildTaskRetryExecution,
        source: UUID, generation: UUID, expectedFacts: ComposerPolicyFactSource,
        expectedOriginalRequest: SubAgentTask
    ) async throws -> TaskCenterRetryDispatchExecutor.Result {
        // Revalidate mutable App policy after the actual approval callback,
        // before the canonical control mutation or any child dispatch.
        guard !Task.isCancelled, chat.activeSessionID == source,
              taskCenterRetryAssemblyGeneration == generation,
              chat.composerPolicyFacts == expectedFacts,
              let originalRunID = request.runID,
              agentTaskStore.settledFailedChildLaunchIntent(taskID: request.taskID,
                  originalParentID: request.parentID, runID: originalRunID)?.task == expectedOriginalRequest else {
            throw ComposerAuthorizationError.authorizationBindingMismatch
        }
        taskCenterControlConsumer.makeChildRetryRegistration()(retry)
        let receipt = try taskCenterControlConsumer.execute(request)
        guard let runID = receipt.resultingRunID,
              let report = await taskCenterControlConsumer.joinRetryExecution(runID: runID)
        else { throw TaskCenterControlConsumerError.unavailable }
        return (receipt, report)
    }

    func joinTaskCenterRetryExecution(runID: String) async -> SubAgentReport? {
        await taskCenterControlConsumer.joinRetryExecution(runID: runID)
    }

    func taskCenterControlRunID(taskID: String, parentID: String) -> String? {
        agentTaskStore.controlSnapshot(taskID: taskID, parentID: parentID)?.runID
    }

    /// Production session action consumer. All App-facing session mutations
    /// enter here when the BridgeStore is attached to ChatStore.
    private var latestSessionActionSourceBySessionID: [String: ParentRuntimeIdentity] = [:]
    /// An App-owned origin for creating the first session after a confirmed
    /// clear. It is deliberately not a UUID or the ID of a deleted session.
    private static let emptySessionNewOriginID = "app:empty-session-new"

    private func captureSessionActionSource() -> ParentRuntimeIdentity? {
        let sourceID: String
        if let sessionID = chat.activeSessionID, chat.hasSession(sessionID) {
            sourceID = sessionID.uuidString
        } else if chat.activeSessionID == nil, chat.sessions.isEmpty {
            sourceID = Self.emptySessionNewOriginID
        } else {
            return nil
        }
        let source = ParentRuntimeIdentity(
            sessionID: sourceID,
            conversationID: sourceID,
            turnID: UUID().uuidString,
            taskID: "session-parent:\(UUID().uuidString)",
            actorID: "app"
        )
        latestSessionActionSourceBySessionID[source.sessionID] = source
        return source
    }

    @discardableResult
    func performSessionAction(
        _ request: SessionActionRequest
    ) throws -> SessionActionObservation {
        let currentSourceID: String
        if let sourceSessionID = chat.activeSessionID, chat.hasSession(sourceSessionID) {
            currentSourceID = sourceSessionID.uuidString
        } else if chat.activeSessionID == nil, chat.sessions.isEmpty,
                  case .new = request.kind {
            currentSourceID = Self.emptySessionNewOriginID
        } else {
            throw SessionActionError.invalidSource
        }
        let source: ParentRuntimeIdentity
        if let capturedSource = request.source {
            guard capturedSource.sessionID == currentSourceID,
                  latestSessionActionSourceBySessionID[capturedSource.sessionID] == capturedSource else {
                throw SessionActionError.sourceTurnMismatch
            }
            source = capturedSource
        } else {
            // Compatibility for direct test/deep-link callers that invoke the
            // Bridge synchronously. UI-originated ChatStore requests always
            // carry a captured source before entering this method.
            guard let legacySource = captureSessionActionSource() else {
                throw SessionActionError.invalidSource
            }
            source = legacySource
        }
        let action: SessionAction
        switch request.kind {
        case let .new(title, projectID, _, workingDirectory, _):
            action = .new(
                title: title,
                projectID: projectID,
                workingDirectory: workingDirectory,
                switchAfterCreate: true,
                source: source
            )
        case let .rename(sessionID, title):
            guard let target = UUID(uuidString: sessionID), chat.hasSession(target) else {
                throw SessionActionError.invalidTarget
            }
            action = .rename(sessionID: sessionID, title: title, source: source)
        case let .switch(sessionID):
            guard let target = UUID(uuidString: sessionID), chat.hasSession(target) else {
                throw SessionActionError.invalidTarget
            }
            action = .switch(sessionID: sessionID, source: source)
        case let .fork(sessionID):
            guard let target = UUID(uuidString: sessionID), chat.hasSession(target) else {
                throw SessionActionError.invalidTarget
            }
            action = .fork(sessionID: sessionID, source: source)
        }
        try action.validate(against: source)

        let taskID = "session-action:\(UUID().uuidString)"
        let runID = "session-action-run:\(UUID().uuidString)"
        let parentID = source.sessionID
        var didEnqueue = false
        var didStartRun = false
        let mutationState = chat.captureSessionActionState()

        do {
            _ = try agentTaskStore.enqueue(
                taskID: taskID,
                parentID: parentID,
                providerID: nil,
                modelID: nil,
                configurationFingerprint: "session-action-v1",
                parentContextSnapshotID: source.turnID
            )
            didEnqueue = true
            _ = try agentTaskStore.startRun(taskID: taskID, parentID: parentID, runID: runID)
            didStartRun = true
            _ = try agentTaskStore.appendEvent(runID: runID, kind: .started, detail: "session-action")

            let resultSessionID: UUID
            switch request.kind {
            case let .new(title, projectID, projectName, workingDirectory, groupID):
                resultSessionID = chat.applyNewSession(
                    title: title,
                    projectID: projectID,
                    projectName: projectName,
                    workingDirectory: workingDirectory,
                    groupID: groupID
                )
            case let .rename(sessionID, title):
                guard let target = UUID(uuidString: sessionID),
                      chat.applyRenameSession(id: target, title: title) else {
                    throw SessionActionError.executionFailed
                }
                resultSessionID = target
            case let .switch(sessionID):
                guard let target = UUID(uuidString: sessionID),
                      chat.applySwitchSession(id: target) else {
                    throw SessionActionError.executionFailed
                }
                resultSessionID = target
            case let .fork(sessionID):
                guard let target = UUID(uuidString: sessionID),
                      let forked = chat.applyDuplicateSession(id: target) else {
                    throw SessionActionError.executionFailed
                }
                resultSessionID = forked
            }

            let didSwitch = chat.activeSessionID == resultSessionID
            let receipt = try action.validateAndReceipt(
                createdSessionID: resultSessionID.uuidString,
                switched: didSwitch
            )
            // An in-flight permission/result belongs to its original composer
            // context even if a later action returns to that same session.
            cancelComposerSpeechInputIfContextChanged()
            // P3-OUTPUT-01（DEV-297）：会话身份经统一生产入口变化且回执成立
            // 后，把台账会话隔离键刷新为当前活跃会话（与装配时同源同形：
            // uuidString；无活跃会话→空串=生产者不登记语义）。
            productionBuiltinToolExecutor?.fileChangeSessionID =
                chat.activeSessionID?.uuidString ?? ""
            reconcileProductionBrowserSession()
            _ = try agentTaskStore.finish(runID: runID, outcome: .succeeded)
            let taskSnapshot = agentTaskStore.snapshot(taskID: taskID, parentID: parentID)
                ?? AgentTaskSnapshot(
                    taskID: taskID,
                    parentID: parentID,
                    parentContextSnapshotID: source.turnID,
                    providerID: nil,
                    modelID: nil,
                    configurationFingerprint: "session-action-v1",
                    routeReceiptID: nil,
                    status: .succeeded
                )
            let snapshot = SessionActionSnapshot(
                source: source,
                resultSessionID: resultSessionID.uuidString,
                task: taskSnapshot,
                runID: runID
            )
            return SessionActionObservation(
                action: action,
                source: source,
                taskID: taskID,
                runID: runID,
                snapshot: snapshot,
                receipt: receipt
            )
        } catch {
            chat.restoreSessionActionState(mutationState)
            if didStartRun {
                _ = try? agentTaskStore.abortRunInitialization(
                    runID: runID,
                    reason: "session-action-failed"
                )
            } else if didEnqueue {
                try? agentTaskStore.abortQueued(
                    taskID: taskID,
                    parentID: parentID,
                    reason: "session-action-failed"
                )
            }
            throw error
        }
    }

    /// Production read-only slash adapter. A fresh adapter captures one immutable
    /// observation per command, while the store remains the sole lifecycle truth.
    var taskCenterSlashCommandAdapter: TaskCenterSlashCommandAdapter {
        if let settingsCatalogSchedulerStore,
           settingsCatalogSchedulerStore.persistenceError == nil {
            return TaskCenterSlashCommandAdapter(
                observation: taskCenterControlConsumer.userTaskObservation(),
                schedulerObservation: SchedulerSlashObservation.capture(from: settingsCatalogSchedulerStore)
            )
        }
        return TaskCenterSlashCommandAdapter(
            observation: taskCenterControlConsumer.userTaskObservation()
        )
    }

    /// Executes a task-center slash read through the production composition root.
    /// The method has no mutation, transcript, or provider execution path.
    func executeTaskCenterSlashCommand(_ input: String) -> String {
        taskCenterSlashCommandAdapter.execute(input)
    }

    /// Versioned production ledger scope. The App composition root is the only caller
    /// that selects this durable URL; tests may inject an isolated URL.
    static var defaultAgentTaskStorePersistenceURL: URL {
        SessionStore.defaultDirectory.appendingPathComponent("agent-tasks-v1.json")
    }

    /// C3-3 Agent 工具调用历史栈：每次实际执行的工具调用记录 ActionRecord
    ///（工具名/参数摘要/时间/结果摘要）；UI 展示 + 撤销入口（undoHandler 留接口）。
    let actionHistory = ActionHistoryStore()

    /// C3-3 崩溃恢复：启动时检测到上次未保存画布草稿时置位（聊天提示恢复）。
    /// 「恢复画布」→ restoreCanvas + 清草稿；「丢弃草稿」→ discardCanvasDraft。
    var pendingCanvasRecovery: CanvasDraft?

    /// E10 工作流接入聊天：`/workflow <模板名>` / `运行工作流 <模板名>` 触发
    /// WorkflowRunner 执行，进度/结果/断点续跑提示写入聊天流。
    let workflowChat: WorkflowChatController

    /// E9 深链/快捷动作执行器：DeepLinkRouter 的 handler 与命令面板 quickaction
    /// 共用此路径（newSession/createPipeline/openSettings/runWorkflow/sendPrompt）。
    let deepLinkHandler: DeepLinkHandler

    /// C3-1 全局命令面板：注册制唯一命令源（面板 / 菜单共用，
    /// 见 AppCommandCatalog——预置命令 + App UI 命令同一注册表）。
    /// catalog 惰性装配（需要 self 完整初始化），registry/display 转发自 catalog。
    var commandRegistry: CommandRegistry { catalog.registry }
    /// The registered commands publish only UI intent. The visible sheet owns
    /// presentation and selection; no task mutation occurs here.
    var taskCenterOpenIntent: TaskCenterOpenIntent?
    var taskCenterNextCommandCount: UInt64 = 0
    var sidebarToggleCommandCount: UInt64 = 0
    var contextToggleCommandCount: UInt64 = 0
    var contextOpenCommandCount: UInt64 = 0
    /// Explicit Chat three-column menu intent, including when layoutMode is already split.
    var chatThreeColumnCommandCount: UInt64 = 0
    /// C3-1 命令展示元数据表（图标 / 快捷键徽标），与 commandRegistry 同一 catalog 构建。
    /// AJ-57：对「可配置快捷键」对应的命令，覆盖徽标为 ShortcutStore 当前绑定（用户改后即同步）。
    var paletteDisplay: [String: PaletteDisplayInfo] {
        var display = catalog.display
        for (commandID, action) in AppCommandCatalog.shortcutCommandMap {
            if let info = display[commandID] {
                display[commandID] = PaletteDisplayInfo(
                    icon: info.icon,
                    shortcut: shortcutStore.binding(for: action).displayString
                )
            }
        }
        return display
    }
    /// Approved slash submission records only the existing proposed envelope.
    /// Recheck the captured authority and scope immediately before durable write.
    func submitApprovedComposerMemoryProposal(
        _ context: ComposerCommandAdjudicationCenter.MemoryProposalApprovalContext
    ) throws -> MemoryProposalEnvelope {
        let snapshot = context.snapshot
        let facts = chat.composerPolicyFacts
        guard context.request.commandID == "memory.propose",
              context.request.requiresPolicyApproval,
              chat.pendingComposerCommand == context.request,
              facts == context.facts, !facts.revoked, facts.expiresAt > Date(),
              !facts.leaseID.isEmpty,
              snapshot.workspaceID == chat.composerWorkspaceID,
              snapshot.workspaceID == facts.workspaceID,
              snapshot.policyRevision == facts.revision,
              snapshot.grantEpoch == facts.grantEpoch,
              snapshot.sessionID == chat.activeSessionID?.uuidString,
              context.scope == chat.activeMemoryScope else {
            throw CommandExecutionError.disabled(commandID: "memory.propose",
                reason: "原提交策略、会话或项目范围已改变")
        }
        guard let text = context.request.args["text"],
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CommandExecutionError.missingArgument(commandID: "memory.propose", argument: "text")
        }
        return try commandMemoryProposalConsumer.submit(
            proposalID: context.request.id.uuidString, text: text, within: context.scope,
            sourceRef: "composer://command/\(context.request.id.uuidString)",
            sourceID: "composer-command")
    }

    private(set) var webFetchUsesPinnedApproval = false
    private(set) var webFetchUnavailableReason: String? = "网页读取服务尚未装配"
    var webFetchAvailabilityDescription: String {
        if let webFetchUnavailableReason { return "网页读取不可用：" + webFetchUnavailableReason + "。" }
        if webFetchUsesPinnedApproval {
            return "网页读取已装配；新 HTTPS 网站需审批，可仅在当前项目记住；逐跳路由与公网地址检查仍适用。"
        }
        return "网页读取已装配；仅限已配置网站，具体调用仍受审批与网络权限检查。"
    }

    /// The App root supplies its already selected runtime profile as a typed
    /// factory. No model or environment variable can choose this directory.
    var webFetchNetworkConfigurationProvider: (@MainActor (ProductionPolicyDefaults) -> NetworkDomainConfigurationProvenance)?
    var webFetchPinnedRouteProvider: WebFetchPinnedRouteProvider?

    let p03CleanupAppController = P03CleanupAppController()

    var childWorktreeRootProvider: (() throws -> (root: GitChildWorktreeRoot, isDisposable: Bool))?

    nonisolated static func matchesChildWorktreePath(
        _ lhs: String, _ rhs: String, isDisposable: Bool
    ) -> Bool {
        if lhs == rhs { return true }
        guard isDisposable else { return false }
        for prefix in ["/var/", "/tmp/"] {
            let privatePrefix = "/private" + prefix
            let (short, long) = lhs.hasPrefix(prefix) ? (lhs, rhs) : (rhs, lhs)
            guard short.hasPrefix(prefix), long.hasPrefix(privatePrefix),
                  short.utf8.dropFirst(prefix.utf8.count)
                      .elementsEqual(long.utf8.dropFirst(privatePrefix.utf8.count)),
                  let left = try? DarwinSystemPathResolver.resolve(URL(fileURLWithPath: lhs)),
                  let right = try? DarwinSystemPathResolver.resolve(URL(fileURLWithPath: rhs)),
                  !left.isEmpty, left.utf8.elementsEqual(right.utf8) else { continue }
            return true
        }
        return false
    }

    nonisolated static func admitsProspectiveChildWorktreePath(
        _ path: String, deniedRoots: [URL], isDisposable: Bool
    ) -> Bool {
        guard let prospective = PolicyRuntimePathBoundary.canonicalPath(path),
              matchesChildWorktreePath(prospective, URL(fileURLWithPath: path).standardizedFileURL.path,
                                       isDisposable: isDisposable),
              !deniedRoots.contains(where: { denied in
                  PolicyRuntimePathBoundary.canonicalPath(denied.path).map {
                      PolicyRuntimePathBoundary.foldedCandidate(prospective, isWithin: $0)
                  } ?? true
              }), !SensitiveFilePolicy.isCredentialPath(prospective),
              !SensitiveFilePolicy.isProtectedStatePath(prospective) else { return false }
        return true
    }

    static func worktreeGitCommandResult(_ raw: String) throws -> GitWorkflowService.CommandResult {
        guard let data = raw.data(using: .utf8),
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = value["exit_code"] as? Int, let exitCode = Int32(exactly: code),
              let stdout = value["stdout"] as? String, let stderr = value["stderr"] as? String,
              value["stdout_artifact"] == nil, value["stderr_artifact"] == nil else {
            throw ToolExecutorError.invalidParameter("git_command_result")
        }
        return .init(exitCode: exitCode, stdout: stdout, stderr: stderr)
    }

    /// The residual-cleanup read-only check is started from the task-center UI,
    /// outside any model turn, so there is no task-local execution context.
    /// Rebuild it from the parent's allocation-time context (same verified
    /// parent identity and session) so the Project executor resolves the
    /// original parent session instead of failing with sourceUnavailable.
    /// Only the turn deadline is dropped: it belongs to the finished turn, and
    /// this call is bounded by the live lease check and the user's fresh
    /// per-call approval, neither of which is bypassed.
    nonisolated static func cleanupExecutionContext(
        from parent: AgentExecutionContextSnapshot, parentSessionID: String
    ) throws -> AgentExecutionContextSnapshot {
        guard parent.hasVerifiedParentRuntime, parent.childRuntimeSnapshot == nil,
              parent.childToolRuntimeBinding == nil,
              parent.parentRuntimeIdentity?.sessionID == parentSessionID,
              parent.currentConversationID == parentSessionID else {
            throw GitChildWorktreeCleanupService.CleanupError.rejected("父会话运行身份已变化，未执行只读检查")
        }
        return AgentExecutionContextSnapshot(
            provider: parent.provider, approvalGate: parent.approvalGate,
            turnController: parent.turnController,
            currentConversationID: parent.currentConversationID,
            makeChildBudget: parent.makeChildBudget, deadline: nil,
            taskStore: parent.taskStore, toolExecutionFactLedger: parent.toolExecutionFactLedger,
            parentBinding: parent.parentBinding, parentTurnHandle: parent.parentTurnHandle,
            parentRuntimeIdentity: parent.parentRuntimeIdentity,
            childRuntimeSnapshot: nil, childToolRuntimeBinding: nil,
            taskArtifactProject: parent.taskArtifactProject,
            composerSnapshot: parent.composerSnapshot, composerPolicyFacts: parent.composerPolicyFacts,
            nestedShellExecutor: parent.nestedShellExecutor,
            offeredToolNames: parent.offeredToolNames,
            childMutationsEnabled: parent.childMutationsEnabled,
            trustedProjectInstructions: parent.trustedProjectInstructions,
            parentAuthorityCheck: parent.parentAuthorityCheck,
            executionIdentity: parent.executionIdentity)
    }

    nonisolated static func makeCleanupReadOnlyExecutor(
        allocation: GitChildWorktreeAllocation, parentDirectory: String,
        parentComposer: ComposerPolicyEnforcedToolExecutor?,
        parentContext: AgentExecutionContextSnapshot, parentSessionID: String,
        assertParent: @escaping @Sendable () async throws -> Void
    ) -> GitChildWorktreeCleanupService.ReadOnlyExecutor {
        { readSet in
            try await assertParent()
            let expected = try GitChildWorktreeCleanupService.readSet(for: allocation)
            // Only the Core's exact eight-item producer can enter
            // this new explicit App call. No caller-selected path,
            // ref, command fragment or derived permission is used.
            guard readSet == expected, ToolExecutionReceiptContext.current == nil,
                  let parentComposer else {
                throw GitChildWorktreeCleanupService.CleanupError.rejected("只读检查与原隔离资源不匹配")
            }
            let executionContext = try Self.cleanupExecutionContext(
                from: parentContext, parentSessionID: parentSessionID)
            let input = try ComposerToolInput(["command": readSet.command, "cwd": parentDirectory])
            let display: GitWriteApprovalSummaryContext.Provider = { shown, _ in
                guard shown == input else {
                    throw ComposerAuthorizationError.authorizationBindingMismatch
                }
                // App renders this appended summary in full. The
                // normal shortened command summary is not authority.
                return readSet.approvalChecklist
            }
            let raw = try await AgentExecutionContext.$current.withValue(executionContext) {
                try await GitWriteApprovalSummaryContext.$current.withValue(display) {
                    try await NestedShellExecutionScope.$requiresFreshApproval.withValue(true) {
                        try await parentComposer.execute(callID: UUID().uuidString,
                            name: "shell_execute", input: input.toolExecutionDictionary)
                    }
                }
            }
            try await assertParent()
            return try await Self.cleanupReadSetResult(raw)
        }
    }

    static func cleanupReadSetResult(_ raw: String) throws -> GitChildWorktreeCleanupReadSetResult {
        guard let data = raw.data(using: .utf8),
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let complete = value["output_complete"] as? NSNumber,
              CFGetTypeID(complete) == CFBooleanGetTypeID(), complete.boolValue,
              let code = value["exit_code"] as? Int, let exitCode = Int32(exactly: code),
              let stdout = value["stdout"] as? String, let stderr = value["stderr"] as? String,
              value["stdout_artifact"] == nil, value["stderr_artifact"] == nil,
              value["timed_out"] as? Bool != true, value["truncated"] as? Bool != true,
              value["stdout_truncated"] as? Bool != true, value["stderr_truncated"] as? Bool != true else {
            throw GitChildWorktreeCleanupService.CleanupError.rejected(
                "只读检查输出未明确完整、超时、截断或仅有预览，未移动目录")
        }
        return GitChildWorktreeCleanupReadSetResult(exitCode: exitCode,
            stdout: stdout, stderr: stderr, outputComplete: true)
    }

    /// Runtime session root configuration, populated only by the exact
    /// Composer approval consumer. It is not a second grant/token store and
    /// is never read by an already admitted turn.
    private var nativeDirectoryApprovalID: UUID?

    static func additionalDirectoryIdentity(_ url: URL) throws -> String {
        guard url.isFileURL, url.standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL else {
            throw ToolExecutorError.pathViolation(url.path)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else {
            throw ToolExecutorError.pathViolation(url.path)
        }
        return "\(device.stringValue):\(inode.stringValue)"
    }

    func prepareComposerAdditionalDirectory(
        request: PendingCommandRequest, snapshot: ComposerSubmissionSnapshot,
        facts: ComposerPolicyFactSource
    ) throws -> ComposerCommandAdjudicationCenter.AdditionalDirectoryApprovalContext {
        guard request.commandID == "add-dir", request.requiresPolicyApproval,
              let raw = request.args["path"], raw.hasPrefix("/"),
              let sessionID = chat.activeSessionID, sessionID.uuidString == snapshot.sessionID,
              let session = chat.sessions.first(where: { $0.id == sessionID }),
              !chat.isActiveSessionGenerating, !chat.hasStreamingWorkForApplicationExit,
              !productionAttachmentAdmissionSuspended,
              productionAttachmentRefresh != nil,
              let owner = productionBuiltinToolExecutor,
              let directoryHandler = productionProjectSessionHandler, directoryHandler.acceptsDirectoryManagement,
              let directoryEngine = chat.agentEngine as? AgentLoopChatEngine,
              (directoryEngine.composedExecutor as? any BuiltinOwnerBoundToolExecutor)?.currentBuiltinOwner === owner,
              chat.composerPolicyFacts == facts, !facts.revoked, facts.expiresAt > Date(),
              !facts.leaseID.isEmpty, snapshot.workspaceID == chat.composerWorkspaceID,
              snapshot.workspaceID == facts.workspaceID, snapshot.policyRevision == facts.revision,
              snapshot.grantEpoch == facts.grantEpoch else {
            throw CommandExecutionError.disabled(commandID: "add-dir", reason: "当前会话、项目或任务授权不可用")
        }
        let projectID = session.projectID ?? "session:\(sessionID.uuidString)"
        if request.args["scope"] == "project" {
            guard directoryHandler.grants.hasProject(projectID) else { throw ProjectSessionAppError.grantUnavailable }
            _ = try directoryHandler.grants.resolve(id: projectID)
        }
        let cwd = try owner.validatedApprovedSessionDirectory(session.workingDirectory ?? owner.allowedRoot.path)
        guard PolicyRuntimePathBoundary.isWithinRoots(path: cwd.path, roots: facts.allowedWriteRoots) else {
            throw CommandExecutionError.disabled(commandID: "add-dir", reason: "当前项目不在本任务授权范围内")
        }
        let directory = try owner.validatedApprovedSessionDirectory(raw)
        return .init(request: request, snapshot: snapshot, facts: facts,
            physicalDirectory: directory, directoryIdentity: try Self.additionalDirectoryIdentity(directory),
            projectID: projectID, workingDirectory: cwd.path,
            attachmentGeneration: productionAttachmentGeneration,
            directoryRevision: directoryHandler.directoryRevision(sessionID: sessionID.uuidString, projectID: projectID),
            sessionDirectoryWasImplicit: session.workingDirectory == nil)
    }

    static func additionalDirectoryContextMatches(
        _ context: ComposerCommandAdjudicationCenter.AdditionalDirectoryApprovalContext,
        pendingRequest: PendingCommandRequest?, activeSessionID: UUID?, projectID: String?,
        workingDirectory: String?, facts: ComposerPolicyFactSource,
        attachmentGeneration: UInt64, now: Date
    ) -> Bool {
        pendingRequest == context.request
            && activeSessionID?.uuidString == context.snapshot.sessionID
            && (projectID ?? "session:\(context.snapshot.sessionID)") == context.projectID
            && (context.sessionDirectoryWasImplicit ? workingDirectory == nil : workingDirectory == context.workingDirectory)
            && facts == context.facts && !facts.revoked && facts.expiresAt > now
            && !facts.leaseID.isEmpty && facts.workspaceID == context.snapshot.workspaceID
            && facts.revision == context.snapshot.policyRevision
            && facts.grantEpoch == context.snapshot.grantEpoch
            && attachmentGeneration == context.attachmentGeneration
    }

    func applyApprovedComposerAdditionalDirectory(
        _ context: ComposerCommandAdjudicationCenter.AdditionalDirectoryApprovalContext
    ) throws -> ComposerCommandAdjudicationCenter.AdditionalDirectoryReceipt {
        guard let sessionID = chat.activeSessionID,
              let session = chat.sessions.first(where: { $0.id == sessionID }),
              Self.additionalDirectoryContextMatches(context,
                  pendingRequest: context.nativeManagement && nativeDirectoryApprovalID == context.request.id
                    ? context.request : chat.pendingComposerCommand, activeSessionID: sessionID,
                  projectID: session.projectID, workingDirectory: session.workingDirectory,
                  facts: chat.composerPolicyFacts, attachmentGeneration: productionAttachmentGeneration,
                  now: Date()) else {
            throw CommandExecutionError.disabled(commandID: "add-dir", reason: "原请求、会话或项目已改变")
        }
        let checked = try prepareComposerAdditionalDirectory(request: context.request,
            snapshot: context.snapshot, facts: context.facts)
        guard checked.physicalDirectory == context.physicalDirectory,
              checked.directoryIdentity == context.directoryIdentity else {
            throw CommandExecutionError.disabled(commandID: "add-dir", reason: "目录身份已改变，请重新提交")
        }
        guard let handler = productionProjectSessionHandler, handler.acceptsDirectoryManagement,
              handler.directoryRevision(sessionID: sessionID.uuidString, projectID: context.projectID)
                == context.directoryRevision else { throw ProjectSessionAppError.grantChanged }
        try handler.approveAdditionalDirectory(context.physicalDirectory, identity: context.directoryIdentity,
            sessionID: sessionID.uuidString, projectID: context.projectID, workingDirectory: context.workingDirectory,
            persistForProject: context.request.args["scope"] == "project")
        return .init(requestID: context.request.id, sessionID: sessionID.uuidString,
            path: context.physicalDirectory.path)
    }

    private func bindPermissionManagement() {
        approvalCenter.permissionDirectoryCreationAvailable = { [weak self] in
            guard let self else { return false }
            return !self.chat.isActiveSessionGenerating && !self.chat.hasStreamingWorkForApplicationExit
                && self.productionProjectSessionHandler?.acceptsDirectoryManagement == true
        }
        approvalCenter.permissionDirectories = { [weak self] in
            guard let self, let id = self.chat.activeSessionID,
                  let session = self.chat.sessions.first(where: { $0.id == id }),
                  let handler = self.productionProjectSessionHandler else { return [] }
            return handler.grants.directoryGrants().filter {
                !$0.revoked && $0.projectID == (session.projectID ?? "session:\(id.uuidString)")
                    && ($0.sessionID == nil || $0.sessionID == id.uuidString)
            }.map { .init(id: $0.id, path: $0.path, scope: $0.sessionID == nil ? "本项目" : "本会话") }
        }
        approvalCenter.projectInstructionTrustRows = { [weak self] in
            self?.productionProjectSessionHandler?.grants.instructionTrustRows().map {
                ApprovalPromptCenter.ProjectInstructionTrustRow(projectID: $0.projectID, path: $0.path, hash: $0.hash)
            } ?? []
        }
        approvalCenter.revokeProjectInstructionTrust = { [weak self] projectID in
            guard let handler = self?.productionProjectSessionHandler else { throw ProjectSessionAppError.grantUnavailable }
            try handler.grants.revokeInstructionTrust(projectID: projectID)
        }
        approvalCenter.permissionProjects = { [weak self] in
            guard let handler = self?.productionProjectSessionHandler else { return [] }
            return handler.grants.list().map { .init(id: $0.projectID, name: $0.displayName,
                path: (try? handler.grants.directory(for: $0).path) ?? "") }
        }
        approvalCenter.revokePermissionProject = { [weak self] id in
            guard let self, let handler = self.productionProjectSessionHandler,
                  handler.acceptsDirectoryManagement else { throw ProjectSessionAppError.grantUnavailable }
            try handler.revokeProject(id: id)
        }
        approvalCenter.revokePermissionDirectory = { [weak self] id in
            guard let self, let handler = self.productionProjectSessionHandler,
                  handler.acceptsDirectoryManagement,
                  self.approvalCenter.permissionDirectories?().contains(where: { $0.id == id }) == true else {
                throw ProjectSessionAppError.grantUnavailable
            }
            try handler.grants.revokeDirectory(id)
        }
        approvalCenter.requestPermissionDirectory = { [weak self] project in
            guard let self, self.approvalCenter.permissionDirectoryCreationAvailable?() == true else {
                throw ProjectSessionAppError.grantUnavailable
            }
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
            panel.message = "选择可访问目录；仍受现有可访问根、拒绝目录与审批策略限制。"
            guard panel.runModal() == .OK, let directory = panel.url,
                  let sessionID = self.chat.activeSessionID else { return }
            let facts = self.chat.composerPolicyFacts
            let request = PendingCommandRequest(id: UUID(), commandID: "add-dir",
                args: ["path": directory.path, "scope": project ? "project" : "session"], requiresPolicyApproval: true)
            let snapshot = ComposerSubmissionSnapshot(mode: .manual, approvalScope: .request,
                effort: .standard, sessionID: sessionID.uuidString, turnID: 0,
                taskID: "directory:\(request.id)", messageID: request.id.uuidString,
                workspaceID: facts.workspaceID, createdAt: Date(), policyRevision: facts.revision, grantEpoch: facts.grantEpoch)
            var context = try self.prepareComposerAdditionalDirectory(request: request, snapshot: snapshot, facts: facts)
            context.nativeManagement = true
            self.nativeDirectoryApprovalID = request.id
            defer { self.nativeDirectoryApprovalID = nil }
            let alert = NSAlert()
            alert.messageText = project ? "授权本项目访问此目录？" : "授权本会话访问此目录？"
            alert.informativeText = ContentSecretRedactor.redact(context.physicalDirectory.path)
                + (project ? "\n项目授权保存后可在后续会话使用。" : "\n会话目录不写入项目授权，结束会话后失效。")
                + "\n不会跳过工具审批或安全策略；移除后后续工具调用失效，已开始的操作无法撤回。"
            alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "授权目录")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
            _ = try self.applyApprovedComposerAdditionalDirectory(context)
        }
    }

    static func additionalDirectoryOwner(base: BuiltinToolExecutor, approved: [URL]) throws -> BuiltinToolExecutor {
        // Preserve the entire old execution path when /add-dir was never
        // approved. Existing mounts are not newly requested directories.
        approved.isEmpty ? base : try base.copyingAddingAdditionalAllowedRoots(approved)
    }

    /// Each new task gets its own concrete Builtin, Goal/lease, engine and
    /// child ceiling from this same physical directory snapshot. Old turns
    /// retain their former executor and facts.
    private func additionalDirectoriesForCurrentSession(owner: BuiltinToolExecutor) throws -> [URL] {
        try additionalDirectories(for: chat.activeSessionID, owner: owner)
    }

    private func additionalDirectories(for sessionID: UUID?, owner: BuiltinToolExecutor) throws -> [URL] {
        guard let sessionID,
              let session = chat.sessions.first(where: { $0.id == sessionID }) else { return [] }
        guard let handler = productionProjectSessionHandler else { return [] }
        let projectID = session.projectID ?? "session:\(sessionID.uuidString)"
        let cwd = session.workingDirectory ?? owner.allowedRoot.resolvingSymlinksInPath().path
        return try handler.approvedAdditionalDirectories(sessionID: sessionID.uuidString,
            projectID: projectID, workingDirectory: cwd).map {
                try owner.validatedApprovedSessionDirectory($0.path)
            }
    }

    func childFileCheckpointSummaries(sessionID: UUID, childTaskID: String,
        path: String) -> [FileCheckpointStore.Summary] {
        guard chat.activeSessionID == sessionID, !childTaskID.isEmpty,
              let store = chat.fileCheckpointStore else { return [] }
        return ((try? store.summaries(sessionID: sessionID.uuidString, childTaskID: childTaskID)) ?? [])
            .filter { $0.path == path }
    }

    /// One visible snapshot, one bound human approval, one shared mutation
    /// lease. Grouping in the Inspector never authorizes a batch restore.
    func requestRestoreChildFileCheckpoint(_ checkpointID: UUID, sessionID: UUID,
        childTaskID: String, path: String) async -> String {
        let denied = "未恢复：会话、文件或授权已改变，请重新检查。"
        guard chat.activeSessionID == sessionID, !chat.isActiveSessionGenerating,
              !chat.hasStreamingWorkForApplicationExit, !productionAttachmentAdmissionSuspended,
              let store = chat.fileCheckpointStore,
              let baseOwner = productionBuiltinToolExecutor,
              var gate = (chat.agentEngine as? AgentLoopChatEngine)?.loop.approvalGate,
              ![ApprovalPolicy.deny, .never].contains(gate.policy(for: "file_write")),
              let summary = childFileCheckpointSummaries(sessionID: sessionID,
                  childTaskID: childTaskID, path: path).first(where: { $0.id == checkpointID }) else { return denied }
        let facts = chat.composerPolicyFacts
        let generation = productionAttachmentGeneration
        let safetyEpoch = safetyRuntimeEpoch
        guard !facts.revoked, facts.expiresAt > Date(), !facts.leaseID.isEmpty,
              facts.workspaceID == chat.composerWorkspaceID,
              facts.knownCapabilities.contains("file_write"), facts.grantedCapabilities.contains("file_write"),
              PolicyRuntimePathBoundary.isWithinRoots(path: path, roots: facts.allowedWriteRoots) else { return denied }
        do {
            let approved = try additionalDirectoriesForCurrentSession(owner: baseOwner)
            let owner = try Self.additionalDirectoryOwner(base: baseOwner, approved: approved)
            let sessionCwd = chat.sessions.first(where: { $0.id == sessionID })?.workingDirectory
                ?? owner.effectiveWorkingDirectory.path
            let physical = try owner.validatedFileArtifactTarget(path, workingDirectory: sessionCwd)
            guard physical.path == path else { return denied }
            let version = try ApprovalFileVersion.capture(path: path)
            let input: [String: Any] = ["checkpoint_id": checkpointID.uuidString,
                "child_task_id": childTaskID, "path": path, "version": version.versionDigest,
                "operation": "恢复此文件的选中检查点；不恢复对话"]
            guard let digest = ApprovalAuthorizationContext.payloadDigest(for: input) else { return denied }
            let requestID = UUID().uuidString
            let expires = min(facts.expiresAt, Date().addingTimeInterval(120))
            let context = ApprovalAuthorizationContext(actorID: "inspector-checkpoint-recovery",
                sessionID: sessionID.uuidString, turnID: 1, taskID: childTaskID,
                runID: requestID, attemptID: requestID, effectID: checkpointID.uuidString,
                scope: "request", payloadDigest: digest, expiresAt: expires,
                policyRevision: facts.revision, grantEpoch: facts.grantEpoch,
                toolName: "file_checkpoint_restore")
            // Retain the original gate's delegate, receipt sink and replay fence.
            // This non-model operation always asks, even in an autonomous mode.
            gate.policyByTool["file_checkpoint_restore"] = .alwaysAsk
            _ = try await gate.gate(tool: "file_checkpoint_restore", input: input, context: context)
            try Task.checkCancellation()
            let restored: Bool = try await ToolFileMutationScope.withLock(path: physical) { [weak self] in
                let authorized = await MainActor.run {
                    guard let self else { return false }
                    return self.chat.activeSessionID == sessionID
                        && self.chat.fileCheckpointStore === store
                        && self.productionBuiltinToolExecutor === baseOwner
                        && self.productionAttachmentGeneration == generation
                        && self.safetyRuntimeEpoch == safetyEpoch
                        && !self.productionAttachmentAdmissionSuspended
                        && !self.chat.isActiveSessionGenerating
                        && self.chat.composerPolicyFacts == facts
                        && !facts.revoked && facts.expiresAt > Date() && expires > Date()
                        && self.childFileCheckpointSummaries(sessionID: sessionID,
                            childTaskID: childTaskID, path: path).contains {
                                $0.id == checkpointID && $0.producerSessionID == summary.producerSessionID
                            }
                }
                guard authorized else { throw FileCheckpointStore.Failure.changed }
                try version.validateCurrent()
                // Store rechecks producer/verified parent ownership, path,
                // retention and exact expected-after hash under its own lock.
                return try await AdmittedFileWorkspaceRoots.withValidatedOwner(owner: owner,
                    workingDirectory: sessionCwd) {
                    _ = try store.restore(checkpointID, sessionID: sessionID.uuidString, expectedPath: path)
                    return true
                }
            }
            return restored ? "已恢复选中文件检查点；未恢复对话。" : denied
        } catch let error as FileCheckpointStore.Failure {
            return error.localizedDescription
        } catch {
            return "未恢复：审批未通过，或文件版本、路径与授权已改变。"
        }
    }

    /// Freeze only an existing, selectable model receipt. This does not apply,
    /// probe, construct a Provider, or change any settings/approval authority.
    func prepareComposerProviderSelection(
        request: PendingCommandRequest, snapshot: ComposerSubmissionSnapshot,
        facts: ComposerPolicyFactSource
    ) throws -> ComposerCommandAdjudicationCenter.ProviderSelectionApprovalContext {
        guard request.commandID == "provider.use", request.requiresPolicyApproval,
              let input = request.args["provider_model"] else {
            throw CommandExecutionError.missingArgument(commandID: "provider.use", argument: "provider_model")
        }
        let parts = input.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
              chat.canSelectChatModel(providerID: String(parts[0]), modelID: String(parts[1])),
              let receipt = chat.chatModelPickerReceipt(providerID: String(parts[0]), modelID: String(parts[1])) else {
            throw CommandExecutionError.disabled(commandID: "provider.use", reason: "目标必须是当前可选择的 provider/model")
        }
        return .init(request: request, snapshot: snapshot, facts: facts, receipt: receipt)
    }

    /// Explicit approval selects through the same persistence consumer as the
    /// model picker, after revalidating the original request and frozen target.
    func applyApprovedComposerProviderSelection(
        _ context: ComposerCommandAdjudicationCenter.ProviderSelectionApprovalContext
    ) throws -> ChatModelPickerApplyReceipt {
        let snapshot = context.snapshot
        let facts = chat.composerPolicyFacts
        guard context.request.commandID == "provider.use", context.request.requiresPolicyApproval,
              chat.pendingComposerCommand == context.request,
              facts == context.facts, !facts.revoked, facts.expiresAt > Date(), !facts.leaseID.isEmpty,
              snapshot.workspaceID == chat.composerWorkspaceID, snapshot.workspaceID == facts.workspaceID,
              snapshot.policyRevision == facts.revision, snapshot.grantEpoch == facts.grantEpoch,
              snapshot.sessionID == chat.activeSessionID?.uuidString,
              chat.canSelectChatModel(providerID: context.receipt.providerID, modelID: context.receipt.modelID),
              chat.chatModelPickerReceipt(providerID: context.receipt.providerID, modelID: context.receipt.modelID) == context.receipt else {
            throw CommandExecutionError.disabled(commandID: "provider.use", reason: "原提交策略、会话或目标已改变")
        }
        guard chat.applyChatModel(providerID: context.receipt.providerID, modelID: context.receipt.modelID),
              chat.lastChatModelApplyReceipt == context.receipt else {
            throw CommandExecutionError.disabled(commandID: "provider.use", reason: "目标选择未由规范入口应用")
        }
        return context.receipt
    }

    private func matchesToolApprovalTarget(
        _ target: ApprovalRequest, command: PendingCommandRequest, snapshot: ComposerSubmissionSnapshot
    ) -> Bool {
        if target.binding?.isValid == true {
            return target.expiresAt.map { $0 > Date() } == true
        }
        guard let execution = chat.nativeWaitingToolApprovalExecution(requestID: command.id),
              target.taskID == snapshot.taskID, target.attemptID == snapshot.attemptID,
              target.messageID == snapshot.messageID else { return false }
        return approvalCenter.matchesPresentedComposerRequest(target, executionIdentity: execution)
    }

    /// Freeze the existing tool waiter, not a new approval presentation. The
    /// rendered action retains the center's private presentation/step identity.
    func prepareComposerPresentedToolApproval(
        request: PendingCommandRequest, snapshot: ComposerSubmissionSnapshot,
        facts: ComposerPolicyFactSource
    ) throws -> ComposerCommandAdjudicationCenter.PresentedToolApprovalContext {
        guard request.commandID == "approve", request.requiresPolicyApproval,
              let target = approvalCenter.pendingRequest, target.requiresApproval,
              target.sessionID == snapshot.sessionID,
              target.policyRevision == facts.revision, target.grantEpoch == facts.grantEpoch,
              matchesToolApprovalTarget(target, command: request, snapshot: snapshot) else {
            throw CommandExecutionError.disabled(commandID: "approve",
                reason: "当前会话没有同策略身份的有效工具审批请求")
        }
        return .init(request: request, snapshot: snapshot, facts: facts, target: target,
            confirmsSecondStep: approvalCenter.awaitingConfirmation,
            actions: approvalCenter.actionsForPresentedRequest())
    }

    /// A command consent consumes exactly the captured rendered action. It
    /// neither synthesizes a decision nor merges the tool's two L3 steps.
    func applyComposerPresentedToolApproval(
        _ context: ComposerCommandAdjudicationCenter.PresentedToolApprovalContext
    ) throws -> ComposerCommandAdjudicationCenter.PresentedToolApprovalResult {
        let snapshot = context.snapshot
        guard let facts = chat.factsForPresentedToolApproval(requestID: context.request.id),
              context.request.commandID == "approve", context.request.requiresPolicyApproval,
              chat.pendingComposerCommand == context.request,
              facts == context.facts, !facts.revoked, facts.expiresAt > Date(), !facts.leaseID.isEmpty,
              snapshot.workspaceID == chat.composerWorkspaceID, snapshot.workspaceID == facts.workspaceID,
              snapshot.policyRevision == facts.revision, snapshot.grantEpoch == facts.grantEpoch,
              snapshot.sessionID == chat.activeSessionID?.uuidString,
              approvalCenter.pendingRequest == context.target,
              approvalCenter.awaitingConfirmation == context.confirmsSecondStep,
              matchesToolApprovalTarget(context.target, command: context.request, snapshot: snapshot) else {
            throw CommandExecutionError.disabled(commandID: "approve",
                reason: "原提交策略、会话或工具审批目标已改变")
        }
        context.actions.approve()
        if !context.confirmsSecondStep, context.target.requiresSecondConfirmation,
           approvalCenter.pendingRequest == context.target, approvalCenter.awaitingConfirmation {
            return .awaitingSecondConfirmation
        }
        // An identical public request can belong to a replacement waiter.
        // Its private nonce rejects the old action; never report that no-op as consent.
        guard approvalCenter.pendingRequest == nil, approvalCenter.lastDiagnostic == nil else {
            throw CommandExecutionError.disabled(commandID: "approve",
                reason: "原工具审批卡已失效")
        }
        return .submittedToOriginalGate
    }

    /// C3-1 收藏命令存储（UserDefaults 持久化，面板 ⭐ 置顶）。
    let favoriteCommands: FavoriteCommandsStore
    /// Canonical preference domain shared by every app-level UI consumer.
    let preferencesDefaults: UserDefaults
    /// The draggable sidebar and typed settings tool share this live gateway.
    let sidebarWidthSetting: SessionSidebarWidthSetting
    /// AJ-57 快捷键设置：可配置按键绑定（UserDefaults 持久化 + 动态绑定）。
    /// 注入式共享实例（App 装配时为同一实例，SettingsView 与 ContentView 共用，避免内存不同步）。
    let shortcutStore: ShortcutStore
    /// The App root owns these stores; settings catalog reads never construct
    /// another profile's mutable control plane.
    private let settingsCatalogSkillsStore: SkillsStore?
    private let settingsCatalogSchedulerStore: SchedulerTaskStore?
    /// C3-1 唯一命令源装配（@ObservationIgnored lazy：装配依赖 self 完整初始化，
    /// 且 Observation 宏不展开 lazy；首次访问时构建一次）。
    @ObservationIgnored private lazy var catalog = AppCommandCatalog.assembled(
        bridge: self,
        dependencies: CommandDependencies(
            env: commandEnvStore,
            log: chat.logManager,
            // The palette/menu must use the same profile-owned sessions as
            // the sidebar. Explicit nil fails closed instead of reading the
            // ambient SessionStore.defaultDirectory.
            sessions: chat.sessionStore ?? injectedSessionStore,
            memory: commandMemoryStore,
            memoryProposalConsumer: commandMemoryProposalConsumer,
            memoryScopeProvider: { @MainActor [weak self] in
                self?.chat.activeMemoryScope
            },
            workflows: workflowChat.workflowStore
        )
    )

    deinit { childGovernorReportTask?.cancel() }

    enum ProductionAssemblyError: Error, Equatable {
        case conflictingMemoryWriter
        case conflictingMCPWriter
    }

    enum ProductionMCPWriterAdmission: Equatable {
        case unpinned
        case admitted
        case rejected(ProductionAssemblyError)
    }

    /// An explicitly injected proposal consumer may write MemoryStore. The
    /// durable production constructor rejects a different injected owner.
    static func hasSingleInjectedMemoryWriter(
        memoryStore: MemoryStore?, memoryProposalConsumer: MemoryProposalConsumer?
    ) -> Bool {
        guard let memoryStore, let memoryProposalConsumer else { return true }
        return memoryProposalConsumer.store === memoryStore
    }

    init(
        shortcutStore: ShortcutStore? = nil,
        preferencesDefaults: UserDefaults? = nil,
        settingsCatalogSkillsStore: SkillsStore? = nil,
        settingsCatalogSchedulerStore: SchedulerTaskStore? = nil,
        logManager: LogManager? = nil,
        workflowStore: WorkflowStore = .shared,
        sessionBadgeStore: SessionBadgeStore = .shared,
        sessionDocumentStore: SessionDocumentStore? = nil,
        sessionStore: SessionStore? = nil,
        canvas: CanvasStore? = nil,
        canvasFactory: @MainActor (UserDefaults) -> CanvasStore = {
            CanvasStore(preferencesDefaults: $0)
        },
        canvasRuntimeState: RuntimeIsolationProfile.CanvasRuntimeState = .enabled,
        agentTaskStore: AgentTaskStore = AgentTaskStore(),
        contextManifestStore: ContextManifestStore = ContextManifestStore(),
        memoryStore: MemoryStore? = nil,
        memoryProposalConsumer: MemoryProposalConsumer? = nil,
        commandEnvStore: EnvVarStore? = nil,
        canonicalMCPManager: MCPServerManager? = nil,
        allowsLegacyCanvasCommandExecutionForTests: Bool = false,
        canvasMutationCoordinator: CanvasMutationCoordinator? = nil,
        canvasMutationCoordinatorFactory: @MainActor (CanvasStore) -> CanvasMutationCoordinator = {
            CanvasMutationCoordinator(target: $0)
        },
        providerReadinessStore: ProviderReadinessStore? = nil,
        taskCenterBindingPersistenceURL: URL? = nil,
        canvasFeatureLane: RuntimeIsolationProfile.CanvasFeatureLane = .phase4OptIn,
        speechToolDirectObservationProvider:
            (@Sendable (String) -> SpeechToolDirectObservations)? = nil,
        composerSpeechDriver: (any ComposerSpeechInputDriver)? = nil
    ) {
        self.workflowChat = WorkflowChatController(workflowStore: workflowStore)
        self.deepLinkHandler = DeepLinkHandler(workflowStore: workflowStore)
        self.sessionBadgeStore = sessionBadgeStore
        // Default arguments are evaluated before this body. Resolve the
        // native test profile first, then construct the logger, preferences,
        // and shortcut store inside its verified namespace.
        let needsDefaultProfile = shortcutStore == nil || preferencesDefaults == nil
            || logManager == nil
        let defaultProfile = needsDefaultProfile
            ? RuntimeIsolationProfile.formalTestProfileForDefaultConsumer() : nil
        if needsDefaultProfile, defaultProfile == nil,
           RuntimeIsolationProfile.isRunningInTestProcess() {
            preconditionFailure("Formal test profile required for BridgeStore defaults")
        }
        let preferencesDefaults = preferencesDefaults
            ?? defaultProfile?.makeUserDefaults() ?? .standard
        let logManager = logManager
            ?? defaultProfile?.makeLogManager() ?? .shared
        let shortcutStore = shortcutStore
            ?? ShortcutStore(defaults: preferencesDefaults)
        self.speechToolDirectObservationProvider = speechToolDirectObservationProvider
            ?? { Self.readPlatformSpeechObservations(for: $0) }
        self.composerSpeechDriverOverride = composerSpeechDriver
        let resolvedSessionDocuments = sessionDocumentStore ?? SessionDocumentStore(
            directory: SessionStore.defaultDirectory
        )
        self.sessionDocuments = resolvedSessionDocuments
        self.injectedSessionStore = sessionStore
        self.canonicalMCPManager = canonicalMCPManager
        // The App injects RuntimeIsolationProfile.sessionDirectory into its
        // document store. Production and field profiles both place MinisCore
        // beside that session directory under their own Application Support.
        let responsesAttemptCheckpointDirectory = resolvedSessionDocuments.directory
            .deletingLastPathComponent()
            .appendingPathComponent("MinisCore", isDirectory: true)
            .appendingPathComponent("responses-attempts", isDirectory: true)
        self.preferencesDefaults = preferencesDefaults
        self.sidebarWidthSetting = SessionSidebarWidthSetting(defaults: preferencesDefaults)
        self.favoriteCommands = FavoriteCommandsStore(defaults: preferencesDefaults)
        self.shortcutStore = shortcutStore
        self.settingsCatalogSkillsStore = settingsCatalogSkillsStore
        self.settingsCatalogSchedulerStore = settingsCatalogSchedulerStore
        // Do not evaluate either Canvas factory in the packaged Phase 3 lane.
        // CanvasStore's default dependencies otherwise load durable media data
        // before a disabled feature state can be applied.
        let resolvedCanvas: CanvasStore? = canvasFeatureLane == .phase4OptIn
            ? (canvas ?? canvasFactory(preferencesDefaults)) : nil
        self.canvasStorage = resolvedCanvas
        self.configuredCanvasRuntimeState = canvasRuntimeState
        self.canvasFeatureLane = canvasFeatureLane
        let initialCanvasState = canvasFeatureLane == .phase3NonCanvas
            ? .disabled
            : canvasRuntimeState
        self.canvasRuntimeState = initialCanvasState
        self.productionChatComposition = .make(canvasState: initialCanvasState)
        let chat = ChatStore(
            providerReadinessStore: providerReadinessStore,
            preferencesDefaults: preferencesDefaults,
            logManager: logManager,
            responsesAttemptCheckpointDirectory: responsesAttemptCheckpointDirectory
        )
        self.chat = chat
        let resolvedCanvasMutationCoordinator = resolvedCanvas.map {
            canvasMutationCoordinator ?? canvasMutationCoordinatorFactory($0)
        }
        if canvasMutationCoordinator == nil && allowsLegacyCanvasCommandExecutionForTests,
           let resolvedCanvasMutationCoordinator {
            // Existing test fixtures keep the legacy command parser enabled, but
            // their Canvas writes still require the coordinator's Composer gate.
            let testFacts = ComposerPolicyFactSource(
                knownCapabilities: ["canvas_mutation"],
                grantedCapabilities: ["canvas_mutation"],
                allowedWriteRoots: [],
                workspaceID: "bridge-legacy-command-test",
                revision: "bridge-legacy-command-test-revision",
                grantEpoch: "bridge-legacy-command-test-epoch",
                leaseID: "bridge-legacy-command-test-lease",
                expiresAt: Date().addingTimeInterval(60),
                autonomyCeiling: .l3
            )
            resolvedCanvasMutationCoordinator.configure(
                facts: testFacts,
                grants: ComposerApprovalGrantStore(),
                approvalGate: nil,
                snapshotFactory: { request, input in
                    ComposerSubmissionSnapshot(
                        mode: .auto,
                        approvalScope: .request,
                        effort: .standard,
                        sessionID: "bridge-legacy-command-test-session",
                        turnID: 0,
                        taskID: "bridge-legacy-command-test:\(request.id.uuidString)",
                        attemptID: request.id.uuidString,
                        messageID: request.id.uuidString,
                        inputDigest: input.digest,
                        workspaceID: testFacts.workspaceID,
                        createdAt: Date(),
                        policyRevision: testFacts.revision,
                        grantEpoch: testFacts.grantEpoch,
                        autonomyCeiling: testFacts.autonomyCeiling
                    )
                },
                originSessionIDProvider: {
                    "bridge-legacy-command-test-session"
                }
            )
        }
        self.canvasMutationCoordinatorStorage = resolvedCanvasMutationCoordinator
        self.agentTaskStore = agentTaskStore
        self.taskCenterControlConsumer = TaskCenterControlConsumer(
            store: agentTaskStore,
            bindingPersistenceURL: taskCenterBindingPersistenceURL,
            requiresLiveRetryExecution: true
        )
        self.contextManifestStore = contextManifestStore
        let commandMemoryStore = memoryStore
            ?? memoryProposalConsumer?.store
            ?? MemoryStore(directory: SessionStore.defaultDirectory)
        self.commandMemoryStore = commandMemoryStore
        self.commandEnvStore = commandEnvStore
        self.commandMemoryProposalConsumer = memoryProposalConsumer
            ?? MemoryProposalConsumer(store: commandMemoryStore)
        self.allowsLegacyCanvasCommandExecutionForTests =
            allowsLegacyCanvasCommandExecutionForTests
        if canvasMutationCoordinator == nil && !allowsLegacyCanvasCommandExecutionForTests,
           let resolvedCanvasMutationCoordinator {
            resolvedCanvasMutationCoordinator.bindOriginSessionIDProvider { [weak chat] in
                chat?.activeSessionID?.uuidString
            }
        }
        chat.attachSessionActionHandler(
            { [weak self] request in
            guard let self else { throw SessionActionError.executionFailed }
            return try self.performSessionAction(request)
            },
            sourceFactory: { [weak self] in
                self?.captureSessionActionSource()
            }
        )
        // Capture every synchronous session transition, including one that
        // happens after a click but before its MainActor Task starts. The
        // callback is reinstalled after attachPersistence replaces it.
        composerSpeechObservedSessionID = chat.activeSessionID
        let sessionsChangedBeforePersistence = chat.onSessionsChanged
        let observeSessionSelection: () -> Void = { [weak self] in
            self?.observeComposerSpeechSessionTransition()
        }
        chat.onSessionSelectionChanged = observeSessionSelection
        chat.onSessionsChanged = {
            sessionsChangedBeforePersistence?()
            observeSessionSelection()
        }
        chat.prepareGoalReviewPrimary = { [weak self] sessionID in
            guard let self else { throw CancellationError() }
            return try await self.prepareConversationGoalReviewPrimary(sessionID: sessionID)
        }
        deepLinkHandler.attach(bridge: self)
        chat.onOpenSettingsPage = { [weak self] pageID in
            self?.deepLinkHandler.handle(.openSettings(id: pageID))
        }
        // Phase 4 may explicitly opt into Canvas-local event projection. The
        // Phase 3 packaged lane leaves the callback unset: no Canvas event can
        // become a Chat consumer or Chat write.
        if canvasFeatureLane == .phase4OptIn, let resolvedCanvas {
            resolvedCanvas.onEvent = { [weak self] event in
                self?.handleCanvasEvent(event)
            }
        }
        if canvasFeatureLane == .phase4OptIn && allowsLegacyCanvasCommandExecutionForTests {
            chat.onSendCommand = { [weak self] text, snapshot in
                self?.handleChatCommand(text, snapshot: snapshot) ?? false
            }
        }
    }

    /// The stop callback is shared by the production attachment and isolated
    /// caller fixtures without constructing browser or credential services.
    static func bindApprovalStopLifecycle(chat: ChatStore, approvalCenter: ApprovalPromptCenter) {
        chat.onSessionPermissionContextChanged = { [weak approvalCenter] in
            approvalCenter?.revokeSessionPermissions()
        }
        chat.onStreamingStopped = { [weak approvalCenter] in
            approvalCenter?.stopGeneration()
        }
        chat.onTurnStreamingStopped = { [weak approvalCenter] identity in
            approvalCenter?.stopGeneration(for: identity)
        }
    }

    /// Production composition root: fail closed when the durable ledger cannot be recovered.
    /// The thrown error contains only the typed store error; no payload, path, or secret is projected.
    convenience init(
        taskStorePersistenceURL: URL,
        shortcutStore: ShortcutStore? = nil,
        preferencesDefaults: UserDefaults? = nil,
        settingsCatalogSkillsStore: SkillsStore? = nil,
        settingsCatalogSchedulerStore: SchedulerTaskStore? = nil,
        logManager: LogManager? = nil,
        workflowStore: WorkflowStore = .shared,
        sessionBadgeStore: SessionBadgeStore = .shared,
        canvasRuntimeState: RuntimeIsolationProfile.CanvasRuntimeState = .enabled,
        sessionDocumentStore: SessionDocumentStore? = nil,
        sessionStore: SessionStore? = nil,
        memoryStore: MemoryStore? = nil,
        memoryProposalConsumer: MemoryProposalConsumer? = nil,
        commandEnvStore: EnvVarStore? = nil,
        canonicalMCPManager: MCPServerManager? = nil,
        providerReadinessStore: ProviderReadinessStore? = nil,
        canvasFeatureLane: RuntimeIsolationProfile.CanvasFeatureLane = .phase4OptIn
    ) throws {
        guard Self.hasSingleInjectedMemoryWriter(
            memoryStore: memoryStore, memoryProposalConsumer: memoryProposalConsumer
        ) else {
            throw ProductionAssemblyError.conflictingMemoryWriter
        }
        try self.init(
            shortcutStore: shortcutStore,
            preferencesDefaults: preferencesDefaults,
            settingsCatalogSkillsStore: settingsCatalogSkillsStore,
            settingsCatalogSchedulerStore: settingsCatalogSchedulerStore,
            logManager: logManager,
            workflowStore: workflowStore,
            sessionBadgeStore: sessionBadgeStore,
            sessionDocumentStore: sessionDocumentStore,
            sessionStore: sessionStore,
            canvasRuntimeState: canvasRuntimeState,
            agentTaskStore: Self.makePersistentAgentTaskStore(at: taskStorePersistenceURL),
            contextManifestStore: Self.makePersistentContextManifestStore(
                at: Self.contextManifestPersistenceURL(for: taskStorePersistenceURL)
            ),
            memoryStore: memoryStore,
            memoryProposalConsumer: memoryProposalConsumer,
            commandEnvStore: commandEnvStore,
            canonicalMCPManager: canonicalMCPManager,
            providerReadinessStore: providerReadinessStore,
            taskCenterBindingPersistenceURL: Self.taskCenterBindingPersistenceURL(for: taskStorePersistenceURL),
            canvasFeatureLane: canvasFeatureLane
        )
    }

    private static func makePersistentAgentTaskStore(at persistenceURL: URL) throws -> AgentTaskStore {
        try FileManager.default.createDirectory(
            at: persistenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return try AgentTaskStore(persistenceURL: persistenceURL)
    }

    private static func contextManifestPersistenceURL(for taskLedgerURL: URL) -> URL {
        taskLedgerURL
            .deletingLastPathComponent()
            .appendingPathComponent("context-manifests-v1.json")
    }

    private static func taskCenterBindingPersistenceURL(for taskLedgerURL: URL) -> URL {
        taskLedgerURL
            .deletingLastPathComponent()
            .appendingPathComponent("task-center-goal-lease-v1.json")
    }

    private static func makePersistentContextManifestStore(at persistenceURL: URL) throws -> ContextManifestStore {
        try FileManager.default.createDirectory(
            at: persistenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return try ContextManifestStore(persistenceURL: persistenceURL)
    }

    /// Strict production child boundary. Child tasks receive only the capabilities
    /// and read-only tool surface explicitly granted here, then intersect that
    /// policy with the runtime parent provider capabilities.
    // Detached bootstrap has no concrete execution owner; real turns use
    // inheritedChildCapabilityPolicy with their immutable offered tools.
    private static let unboundChildCapabilityPolicy = AgentCapabilityPolicy(
        allowedCapabilities: [.streaming, .tools],
        allowedToolNames: ["file_read"]
    )

    /// The actual parent turn, not model task data, supplies the offered set.
    nonisolated static func inheritedChildCapabilityPolicy(
        offeredToolNames: Set<String>, builtinOwner: BuiltinToolExecutor?
    ) -> AgentCapabilityPolicy {
        let ordinary = offeredToolNames.filter { !$0.hasPrefix("mcp_") }
            .intersection(builtinOwner?.registeredToolNames ?? [])
        let mcp: Set<String> = builtinOwner?.mcpBridge == nil ? []
            : offeredToolNames.filter { $0.hasPrefix("mcp_") }
        return AgentCapabilityPolicy(allowedCapabilities: [.streaming, .tools],
            allowedToolNames: ordinary, allowedMCPToolNames: mcp)
    }

    /// The built-in Mock is intrinsically ready: it has no external endpoint
    /// or credential to discover/apply. These stable, secret-free identifiers
    /// let the ordinary production route satisfy the same provenance validator
    /// as configured Providers without weakening that validator.
    private static let builtInMockReadinessEvidenceID = "builtin-mock:readiness:v1"
    private static let builtInMockApplyReceiptID =
        "provider-readiness-apply:builtin-mock:readiness:v1"

    /// Pure directory plus a lazy selected-provider constructor. Constructing
    /// this value does not resolve credentials or construct transports.
    private func prepareChildModelRuntime(parent: ParentContextSnapshotV1? = nil) -> ChildModelRuntimeBinding {
        let settings = productionChildModelSettings
        let models = chat.childModelMetadata(settings: settings, parent: parent)
        let items = chat.chatModelPickerItems
        return ChildModelRuntimeBinding(policy: .init(settings: settings, readyModels: models), parentBinding: parent, construct: { [weak self] id in
            guard let self, let item = items.first(where: { $0.id == id }) else {
                throw ChildModelBindingError.notReady(id)
            }
            let provider = try await self.chat.prepareSelectedChildProvider(stableID: id, expectedItem: item)
            let admitted = await MainActor.run { self.admitsProviderNetworkRoute(provider.value) }
            guard admitted else { throw ChildModelBindingError.notReady(id) }
            return provider
        })
    }

    /// Prepare only the session's currently selected primary for independent goal review.
    /// Existing provider preparation revalidates selection after constructing the provider.
    func prepareConversationGoalReviewPrimary(
        sessionID: UUID
    ) async throws -> (snapshot: ProviderRuntimeSnapshot, primary: any LLMProvider) {
        guard chat.activeSessionID == sessionID else { throw CancellationError() }
        guard let selection = try chat.freezeWorkflowProviderSelection() else {
            throw ProviderRuntimeSnapshotError.missingPrimaryProvenance
        }
        let primary = try await chat.prepareWorkflowProvider(from: selection)
        try Task.checkCancellation()
        guard chat.activeSessionID == sessionID else { throw CancellationError() }
        guard let builder = makeProviderRuntimeRouteBuilder(primaryOnly: true),
              let route = try builder(AgentLoopChatEngine.ProviderRuntimeRouteBox(primary)).value
                as? ProviderRuntimeRoute else {
            throw ProviderRuntimeSnapshotError.missingPrimaryProvenance
        }
        return (route.snapshot, primary)
    }

    /// Build one turn-bound ProviderRuntimeRoute from the same ChatStore
    /// picker/apply projection used by activeProvider(). Provider instances
    /// are constructed only at the turn boundary and never serialized.
    private func makeProviderRuntimeRouteBuilder(
        observationIdentity: AgentExecutionIdentity? = nil,
        primaryOnly: Bool = false
    ) -> AgentLoopChatEngine.ProviderRuntimeRouteBuilder? {
        let chat = self.chat
        return { @MainActor [weak self] primaryBox in
            guard let self else {
                throw ProviderRuntimeSnapshotError.missingPrimaryProvenance
            }
            let primary = primaryBox.value
            let primaryID = primary.name
            // Bind readiness to the frozen primary, never the current UI selection.
            let primaryReadinessID = primaryID
            let primaryReceipt = chat.chatModelPickerReceipt(
                providerID: primaryReadinessID,
                modelID: primary.model.id
            )
            let isBuiltInMock = (primary as? MockProvider) === MockProvider.shared
            guard self.admitsProviderNetworkRoute(primary) else {
                throw ProviderRuntimeSnapshotError.missingPrimaryProvenance
            }
            // P3-P1-03(a)：开关从实时存储读取（refreshProductionAgentSettings
            // 写入），不再冻结构造期参数；候选列表本就是逐轮活读取。
            let fallbackEnabled = !primaryOnly && self.productionFallbackEnabled
                && self.productionExternalNetworkAllowed
            let primaryReadinessEvidenceID = isBuiltInMock
                ? Self.builtInMockReadinessEvidenceID
                : primaryReceipt?.evidenceID
            let primaryApplyReceiptID = isBuiltInMock
                ? Self.builtInMockApplyReceiptID
                : primaryReceipt?.applyReceiptID
            let primaryCapabilities = primary.capabilities
            let primaryConfigurationFingerprint: String? = {
                guard let identity = primary as? any ProviderRuntimeConfigurationIdentity,
                      let material = identity.runtimeConfigurationMaterial else {
                    return nil
                }
                return ProviderRuntimeSnapshot.configurationFingerprint(
                    providerID: primaryID,
                    modelID: primary.model.id,
                    capabilities: primaryCapabilities,
                    configurationMaterial: material
                )
            }()
            var fallbackIDs: [String] = []
            var fallbackProviders: [any LLMProvider] = []
            var fallbackProvenance: [ProviderRuntimeFallback] = []

            for candidate in fallbackEnabled
                ? chat.providerRuntimeFallbackCandidates(excludingProviderID: primaryID)
                : [] {
                let providerID = candidate.providerID
                let provider: any LLMProvider
                switch candidate.option {
                case .builtIn(let type):
                    do {
                        var config = ProviderConfig(
                            label: type.displayName,
                            providerType: type,
                            runtimeProviderID: type.runtimeProviderID
                        )
                        config.attemptCheckpointDirectory =
                            chat.responsesAttemptCheckpointDirectory
                        if type == .local {
                            config.customBaseURL = "http://127.0.0.1:11434"
                        }
                        var builtInProvider = try ProviderFactory.shared.makeProvider(
                            for: config,
                            requireCredentials: false
                        )
                        builtInProvider.model = ChatStore.BuiltinReadinessBinding
                            .record(for: type, in: chat.providerRecordsSource?() ?? [])
                            .map {
                                ChatStore.customProviderModel(
                                    record: $0, modelID: candidate.model.id,
                                    displayName: candidate.model.displayName,
                                    provider: type.runtimeProviderID)
                            } ?? LLMModel(
                                id: candidate.model.id,
                                displayName: candidate.model.displayName,
                                provider: type.runtimeProviderID
                            )
                        provider = builtInProvider
                    } catch {
                        continue
                    }
                case .custom(let record):
                    do {
                        provider = try chat.makeCustomProvider(
                            record: record,
                            modelID: ChatStore.canonicalModelID(candidate.model.id)
                        )
                    } catch {
                        continue
                    }
                }

                guard !fallbackIDs.contains(where: {
                    $0.caseInsensitiveCompare(providerID) == .orderedSame
                }) else {
                    continue
                }
                fallbackIDs.append(providerID)
                fallbackProviders.append(provider)
                let configurationFingerprint: String? = {
                    guard let identity = provider as? any ProviderRuntimeConfigurationIdentity,
                          let material = identity.runtimeConfigurationMaterial else {
                        return nil
                    }
                    return ProviderRuntimeSnapshot.configurationFingerprint(
                        providerID: providerID,
                        modelID: candidate.model.id,
                        capabilities: provider.capabilities,
                        configurationMaterial: material
                    )
                }()
                fallbackProvenance.append(
                    ProviderRuntimeFallback(
                        providerID: providerID,
                        modelID: candidate.model.id,
                        readinessEvidenceID: candidate.receipt.evidenceID,
                        applyReceiptID: candidate.receipt.applyReceiptID,
                        capabilities: provider.capabilities,
                        configurationFingerprint: configurationFingerprint
                    )
                )
            }

            let snapshot = try ProviderRuntimeSnapshot(
                providerID: primaryID,
                modelID: primary.model.id,
                readinessEvidenceID: primaryReadinessEvidenceID,
                applyReceiptID: primaryApplyReceiptID,
                fallbackProviderIDs: fallbackIDs,
                fallbackProvenance: fallbackProvenance,
                capabilities: primaryCapabilities,
                configurationFingerprint: primaryConfigurationFingerprint
            )
            if primaryOnly {
                return AgentLoopChatEngine.ProviderRuntimeRouteBox(
                    try ProviderRuntimeRoute(snapshot: snapshot, primary: primary)
                )
            }
            return AgentLoopChatEngine.ProviderRuntimeRouteBox(
                try ProviderRuntimeRoute(
                    snapshot: snapshot,
                    primary: primary,
                    fallbacks: fallbackProviders,
                    observationSink: { [weak self] observation in
                        await MainActor.run {
                            self?.recordProviderRuntimeObservation(observation)
                            if let observationIdentity {
                                _ = self?.chat.ingestProviderRuntimeObservation(
                                    observation,
                                    executionIdentity: observationIdentity
                                )
                            }
                        }
                    }
                )
            )
        }
    }

    /// Freeze the same picker/apply projection as the synchronous route, then
    /// construct its Providers on a worker. A factory may initialize a
    /// transport or read the Responses attempt checkpoint, so no fallback
    /// factory runs in the turn's UI frame.
    private func prepareProviderRuntimeRoute(
        primary: any LLMProvider,
        observationIdentity: AgentExecutionIdentity?,
        fallbackCandidates: [ChatStore.ProviderRuntimeFallbackCandidate]
    ) -> Task<Result<ProviderRuntimeRoute, ProviderRuntimeSnapshotError>, Never> {
        let primaryBox = LLMProviderBox(value: primary)
        let primaryID = primary.name
        let primaryModel = primary.model
        let primaryCapabilities = primary.capabilities
        // The primary is already turn-bound when async fallback preparation starts.
        let primaryReadinessID = primaryID
        let primaryReceipt = chat.chatModelPickerReceipt(
            providerID: primaryReadinessID, modelID: primaryModel.id
        )
        let isBuiltInMock = (primary as? MockProvider) === MockProvider.shared
        let admitted = admitsProviderNetworkRoute(primary)
        let fallbackEnabled = productionFallbackEnabled && productionExternalNetworkAllowed
        let pauseForTests = providerRuntimeFallbackPauseForTests
        let primaryReadinessEvidenceID = isBuiltInMock
            ? Self.builtInMockReadinessEvidenceID : primaryReceipt?.evidenceID
        let primaryApplyReceiptID = isBuiltInMock
            ? Self.builtInMockApplyReceiptID : primaryReceipt?.applyReceiptID
        let primaryConfigurationFingerprint: String? = {
            guard let identity = primary as? any ProviderRuntimeConfigurationIdentity,
                  let material = identity.runtimeConfigurationMaterial else { return nil }
            return ProviderRuntimeSnapshot.configurationFingerprint(
                providerID: primaryID, modelID: primaryModel.id,
                capabilities: primaryCapabilities, configurationMaterial: material
            )
        }()
        struct Candidate: Sendable {
            let providerID: String
            let modelID: String
            let receipt: ChatModelPickerApplyReceipt
            let construction: ChatStore.FrozenProviderConstruction
        }
        struct PreparedRoute: Sendable {
            let snapshot: ProviderRuntimeSnapshot
            let fallbacks: [LLMProviderBox]
        }
        let candidates: [Candidate] = (fallbackEnabled
            ? fallbackCandidates : []
        ).compactMap { candidate in
            let construction: ChatStore.FrozenProviderConstruction
            switch candidate.option {
            case .builtIn(let type):
                var config = ProviderConfig(
                    label: type.displayName, providerType: type,
                    runtimeProviderID: type.runtimeProviderID
                )
                if type == .local { config.customBaseURL = "http://127.0.0.1:11434" }
                construction = ChatStore.FrozenProviderConstruction(
                    config: config,
                    model: LLMModel(id: candidate.model.id,
                                    displayName: candidate.model.displayName,
                                    provider: type.runtimeProviderID),
                    requiresCredential: false
                )
            case .custom(let record):
                guard let captured = try? chat.frozenCustomProviderConstruction(
                    record: record, modelID: ChatStore.canonicalModelID(candidate.model.id)
                ) else { return nil }
                construction = captured
            }
            return Candidate(providerID: candidate.providerID,
                             modelID: candidate.model.id, receipt: candidate.receipt,
                             construction: construction)
        }
        let worker = Task.detached(priority: .userInitiated) {
            () -> Result<PreparedRoute, ProviderRuntimeSnapshotError> in
            if let pauseForTests { await pauseForTests() }
            guard admitted, !Task.isCancelled else {
                return .failure(.missingPrimaryProvenance)
            }
            var fallbackIDs: [String] = []
            var fallbackProviders: [any LLMProvider] = []
            var fallbackProvenance: [ProviderRuntimeFallback] = []
            for candidate in candidates {
                guard !Task.isCancelled else { return .failure(.missingPrimaryProvenance) }
                guard let provider = try? candidate.construction.makeProvider() else { continue }
                guard !fallbackIDs.contains(where: {
                    $0.caseInsensitiveCompare(candidate.providerID) == .orderedSame
                }) else { continue }
                fallbackIDs.append(candidate.providerID)
                fallbackProviders.append(provider)
                let fingerprint: String? = {
                    guard let identity = provider as? any ProviderRuntimeConfigurationIdentity,
                          let material = identity.runtimeConfigurationMaterial else { return nil }
                    return ProviderRuntimeSnapshot.configurationFingerprint(
                        providerID: candidate.providerID, modelID: candidate.modelID,
                        capabilities: provider.capabilities, configurationMaterial: material
                    )
                }()
                fallbackProvenance.append(ProviderRuntimeFallback(
                    providerID: candidate.providerID, modelID: candidate.modelID,
                    readinessEvidenceID: candidate.receipt.evidenceID,
                    applyReceiptID: candidate.receipt.applyReceiptID,
                    capabilities: provider.capabilities,
                    configurationFingerprint: fingerprint
                ))
            }
            do {
                let snapshot = try ProviderRuntimeSnapshot(
                    providerID: primaryID, modelID: primaryModel.id,
                    readinessEvidenceID: primaryReadinessEvidenceID,
                    applyReceiptID: primaryApplyReceiptID,
                    fallbackProviderIDs: fallbackIDs,
                    fallbackProvenance: fallbackProvenance,
                    capabilities: primaryCapabilities,
                    configurationFingerprint: primaryConfigurationFingerprint
                )
                return .success(PreparedRoute(
                    snapshot: snapshot,
                    fallbacks: fallbackProviders.map { LLMProviderBox(value: $0) }
                ))
            } catch let error as ProviderRuntimeSnapshotError {
                return .failure(error)
            } catch {
                return .failure(.missingPrimaryProvenance)
            }
        }
        return Task { @MainActor [weak self] in
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled else { return .failure(.missingPrimaryProvenance) }
            switch result {
            case .failure(let error):
                return .failure(error)
            case .success(let prepared):
                guard !Task.isCancelled else { return .failure(.missingPrimaryProvenance) }
                do {
                    return .success(try ProviderRuntimeRoute(
                        snapshot: prepared.snapshot, primary: primaryBox.value,
                        fallbacks: prepared.fallbacks.map(\.value),
                        observationSink: { [weak self] observation in
                            await MainActor.run {
                                self?.recordProviderRuntimeObservation(observation)
                                if let observationIdentity {
                                    _ = self?.chat.ingestProviderRuntimeObservation(
                                        observation, executionIdentity: observationIdentity
                                    )
                                }
                            }
                        }
                    ))
                } catch let error as ProviderRuntimeSnapshotError {
                    return .failure(error)
                } catch {
                    return .failure(.missingPrimaryProvenance)
                }
            }
        }
    }

    private func makeProviderRuntimeRoute(
        primary: any LLMProvider,
        observationIdentity: AgentExecutionIdentity? = nil
    ) throws -> ProviderRuntimeRoute {
        guard admitsProviderNetworkRoute(primary) else {
            throw ProviderRuntimeSnapshotError.missingPrimaryProvenance
        }
        // P3-P1-03(a)：不再接收构建期冻结的 enabled；builder 闭包逐轮读取
        // productionFallbackEnabled。
        guard let builder = makeProviderRuntimeRouteBuilder(
            observationIdentity: observationIdentity
        ) else {
            throw ProviderRuntimeSnapshotError.missingPrimaryProvenance
        }
        let value = try builder(AgentLoopChatEngine.ProviderRuntimeRouteBox(primary)).value
        guard let route = value as? ProviderRuntimeRoute else {
            throw ProviderRuntimeSnapshotError.missingPrimaryProvenance
        }
        return route
    }

    /// Startup recovery stays on the production Canvas invoker and only
    /// resumes persisted remote task IDs; it never reconstructs a submission.
    func recoverPendingCanvasMediaTasks() async -> [VideoTaskRecord] {
        guard let canvas = canvasIfAvailable,
              let invoker = canvas.context.videoInvoker as? MinisCanvasVideoInvoker else {
            return []
        }
        return (try? await invoker.recoverPendingTasks()) ?? []
    }

    // MARK: 生产环境装配（I4：Agent / 会话持久化 / Skill 注入）

    /// B1c SkillInjector（匹配用户输入 → 注入匹配 Skill 的系统提示片段）。
    private(set) var skillInjector: SkillInjector?
    private(set) var skillDeploymentStatus: SkillStoreReadiness.DeploymentStatus = .pending
    @ObservationIgnored private var productionSkillDeployment:
        (store: SkillStore, deployment: SkillStoreReadiness.Deployment)?

    /// Speech recognition runtime configured from the existing app language.
    /// Invalid or missing production language remains fail-closed (`nil`).
    private(set) var speechRecognizer: SpeechRecognizer?
    /// The language observation is made from the same configured value used
    /// to construct the speech consumers. No configured value means unknown.
    @ObservationIgnored
    private var speechLocaleResolvedForAvailability: Bool?
    @ObservationIgnored
    private var speechRuntimeLanguageForAvailability: String?
    /// The default producer queries the local voice and default output device
    /// without speaking or requesting permission. Tests inject synthetic facts.
    @ObservationIgnored
    private let speechToolDirectObservationProvider:
        @Sendable (String) -> SpeechToolDirectObservations

    /// One immutable capture for the caller-owned turn. The production
    /// provider may return nil on a CoreAudio query error, so a resolved locale
    /// alone cannot mark TTS supported. ChatStore's existing turn factory
    /// starts this once and shares the frozen result with its consumers. The
    /// native voice and output-device queries must not run on the UI actor.
    func prepareSpeechToolAvailability(
        for turn: AgentTurnIdentity
    ) -> @Sendable () -> SpeechToolAvailabilitySnapshot {
        let language = speechRuntimeLanguageForAvailability
        let locale = speechLocaleResolvedForAvailability
        let observation = speechToolDirectObservationProvider
        let turnID = "chat:\(turn.sessionID):\(turn.turnID):\(turn.messageID)"
        return {
            let direct = language.map(observation) ?? SpeechToolDirectObservations()
            let probe = SpeechCapabilityBoundary.Probe(
                speechLocaleResolved: locale,
                ttsVoiceAvailable: direct.voiceAvailable,
                audioOutputDevicePresent: direct.audioOutputDevicePresent
            )
            let sources = SpeechToolAvailabilitySnapshot.ProbeSources(
                speechLocaleResolved: locale == nil ? .unobserved : .settingsLanguage,
                ttsVoiceAvailable: direct.voiceAvailable == nil ? .unobserved : .systemVoice,
                audioOutputDevicePresent: direct.audioOutputDevicePresent == nil
                    ? .unobserved : .audioOutputDevice
            )
            return SpeechToolAvailabilitySnapshot(
                probe: probe, sources: sources,
                identity: .init(turnID: turnID, capturedAt: Date())
            )
        }
    }

    /// This runs only when a production turn captures availability. An API
    /// failure is unknown; a successful query with no matching voice or
    /// output device is a measured false.
    nonisolated private static func readPlatformSpeechObservations(
        for runtimeLanguage: String
    ) -> SpeechToolDirectObservations {
        let voice = AVSpeechSynthesisVoice(language: runtimeLanguage)
        let voiceAvailable = voice.map {
            Locale.identifier(.icu, from: $0.language)
                == Locale.identifier(.icu, from: runtimeLanguage)
        } ?? false

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        let outputPresent: Bool? = status == 0
            && size == UInt32(MemoryLayout<AudioObjectID>.size)
            ? deviceID != AudioObjectID(kAudioObjectUnknown)
            : nil
        return SpeechToolDirectObservations(
            voiceAvailable: voiceAvailable,
            audioOutputDevicePresent: outputPresent
        )
    }

    @ObservationIgnored private var composerSpeechGeneralLanguage: String? = nil

    private func composerSpeechDriver(
        forRecording: Bool = false
    ) -> any ComposerSpeechInputDriver {
        if let composerSpeechDriverOverride { return composerSpeechDriverOverride }
        if forRecording {
            // Core's result handler may finish after stop/cancel. A fresh
            // recognizer per click prevents an old callback from changing the
            // recognizedText read by a later session's recording.
            let isolated = composerSpeechGeneralLanguage.flatMap {
                try? SpeechRecognizer(generalLanguage: $0)
            }
            return LiveComposerSpeechInputDriver(recognizer: isolated)
        }
        return LiveComposerSpeechInputDriver(recognizer: speechRecognizer)
    }

    private func currentComposerSpeechContext() -> ComposerSpeechContext? {
        guard let sessionID = chat.activeSessionID,
              let session = chat.sessions.first(where: { $0.id == sessionID }) else {
            return nil
        }
        return ComposerSpeechContext(
            sessionID: sessionID,
            projectID: session.projectID,
            sessionTransitionEpoch: composerSpeechSessionTransitionEpoch
        )
    }

    private func observeComposerSpeechSessionTransition() {
        let currentSessionID = chat.activeSessionID
        if currentSessionID != composerSpeechObservedSessionID {
            stopProductionSpeechOutput()
            composerSpeechObservedSessionID = currentSessionID
            composerSpeechSessionTransitionEpoch &+= 1
        }
        cancelComposerSpeechInputIfContextChanged()
    }

    /// App lifecycle cancellation stops the already assembled output owner;
    /// it never executes a model tool or grants speech availability.
    func stopProductionSpeechOutput() {
        (productionBuiltinToolExecutor?.speech as? SpeechTool)?.synthesizer.stop()
    }

    var composerSpeechClickContext: ComposerSpeechContext? {
        currentComposerSpeechContext()
    }

    var composerSpeechClickGeneration: UUID? { composerSpeechGeneration }

    /// The Core boundary supplies all unsupported reasons. An undecided
    /// authorization is offered only as an explicit-click request path, and
    /// only after a device/engine probe rules out a pointless prompt.
    private func composerSpeechAvailability(
        for driver: any ComposerSpeechInputDriver
    ) -> ComposerSpeechAvailability {
        guard currentComposerSpeechContext() != nil else { return .noSession }
        let configured = driver.configured
        let recognizerAvailable = driver.recognizerAvailable
        let hasAudioInput = driver.hasAudioInput
        let speechPermission = driver.speechPermission
        let microphonePermission = driver.microphonePermission
        func boundary(speechAuthorized: Bool, microphoneAuthorized: Bool)
            -> SpeechCapabilityBoundary.Status {
            SpeechCapabilityBoundary.evaluate(
                SpeechCapabilityBoundary.Probe(
                    speechLocaleResolved: configured,
                    sttRecognizerPresent: configured,
                    sttEngineAvailable: recognizerAvailable,
                    speechRecognitionAuthorized: speechAuthorized,
                    microphoneAuthorized: microphoneAuthorized,
                    audioInputDevicePresent: hasAudioInput
                )
            ).speechRecognition
        }
        // A denied authorization must remain a blocked state even if the
        // other authorization is still undecided.
        let denied = boundary(
            speechAuthorized: speechPermission != .denied,
            microphoneAuthorized: microphonePermission != .denied
        )
        if let reason = denied.unsupportedReason,
           reason == .speechRecognitionNotAuthorized
            || reason == .microphoneNotAuthorized {
            return .unsupported(reason)
        }
        if speechPermission == .unknown || microphonePermission == .unknown {
            let hardware = boundary(speechAuthorized: true, microphoneAuthorized: true)
            if let reason = hardware.unsupportedReason {
                return .unsupported(reason)
            }
            return .permissionStatusUnknown
        }
        let status = boundary(
            speechAuthorized: speechPermission == .granted,
            microphoneAuthorized: microphonePermission == .granted
        )
        guard let reason = status.unsupportedReason else { return .ready }
        if (reason == .speechRecognitionNotAuthorized
                && speechPermission == .requestable)
            || (reason == .microphoneNotAuthorized
                && microphonePermission == .requestable) {
            let hardware = boundary(speechAuthorized: true, microphoneAuthorized: true)
            if let hardwareReason = hardware.unsupportedReason {
                return .unsupported(hardwareReason)
            }
            return .permissionRequired
        }
        return .unsupported(reason)
    }

    var composerSpeechAvailability: ComposerSpeechAvailability {
        composerSpeechAvailability(for: composerSpeechDriver())
    }

    private func composerSpeechOwns(
        _ generation: UUID,
        context: ComposerSpeechContext
    ) -> Bool {
        composerSpeechGeneration == generation
            && composerSpeechContext == context
            && currentComposerSpeechContext() == context
    }

    private func failComposerSpeechInput(_ reason: String) {
        composerSpeechActiveDriver?.cancel()
        composerSpeechActiveDriver = nil
        composerSpeechContext = nil
        composerSpeechGeneration = nil
        composerSpeechPhase = .failed(reason)
    }

    /// Invoked only from an explicit composer button action. Repeated starts
    /// never issue a second permission request or open a second audio stream.
    @discardableResult
    func startComposerSpeechInput(
        expectedContext: ComposerSpeechContext? = nil
    ) async -> Bool {
        switch composerSpeechPhase {
        case .idle, .failed: break
        case .requestingPermission, .recording, .finishing: return false
        }
        guard let context = currentComposerSpeechContext() else {
            composerSpeechPhase = .failed(ComposerSpeechAvailability.noSession.explanation)
            return false
        }
        if let expectedContext, expectedContext != context { return false }
        let driver = composerSpeechDriver(forRecording: true)
        let availability = composerSpeechAvailability(for: driver)
        guard availability.canStartFromClick else {
            composerSpeechPhase = .failed(availability.explanation)
            return false
        }
        let generation = UUID()
        composerSpeechGeneration = generation
        composerSpeechContext = context
        composerSpeechActiveDriver = driver
        if availability == .permissionRequired {
            composerSpeechPhase = .requestingPermission
            let granted = await driver.requestAuthorization()
            guard composerSpeechOwns(generation, context: context) else {
                if composerSpeechGeneration == generation { cancelComposerSpeechInput() }
                return false
            }
            guard granted else {
                let reason = composerSpeechAvailability(for: driver).explanation
                failComposerSpeechInput(reason)
                return false
            }
        }
        guard composerSpeechOwns(generation, context: context) else {
            if composerSpeechGeneration == generation { cancelComposerSpeechInput() }
            return false
        }
        let refreshed = composerSpeechAvailability(for: driver)
        guard refreshed == .ready else {
            failComposerSpeechInput(refreshed.explanation)
            return false
        }
        do {
            try driver.start()
            composerSpeechPhase = .recording
            return true
        } catch {
            failComposerSpeechInput(error.localizedDescription)
            return false
        }
    }

    /// A delayed stop result may append only to the exact still-active source
    /// session/project. ChatStore's existing draft setter keeps persistence and
    /// credential capture intact; this path never submits the composer.
    @discardableResult
    func stopComposerSpeechInput(expectedGeneration: UUID? = nil) async -> Bool {
        guard composerSpeechPhase == .recording,
              let driver = composerSpeechActiveDriver,
              let context = composerSpeechContext,
              let generation = composerSpeechGeneration else { return false }
        if let expectedGeneration, expectedGeneration != generation { return false }
        composerSpeechPhase = .finishing
        let result = await driver.stop()
        guard composerSpeechOwns(generation, context: context),
              composerSpeechPhase == .finishing else {
            if composerSpeechGeneration == generation { cancelComposerSpeechInput() }
            return false
        }
        composerSpeechActiveDriver = nil
        composerSpeechContext = nil
        composerSpeechGeneration = nil
        composerSpeechPhase = .idle
        let transcript = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            composerSpeechPhase = .failed("未识别到语音，请重试")
            return false
        }
        let existing = chat.draftText
        let separator = existing.isEmpty || existing.last?.isWhitespace == true ? "" : " "
        chat.draftText = existing + separator + transcript
        return true
    }

    func cancelComposerSpeechInput() {
        let driver = composerSpeechActiveDriver
        composerSpeechActiveDriver = nil
        composerSpeechContext = nil
        composerSpeechGeneration = nil
        composerSpeechPhase = .idle
        driver?.cancel()
    }

    func cancelComposerSpeechInputIfContextChanged() {
        guard let composerSpeechContext,
              currentComposerSpeechContext() != composerSpeechContext else { return }
        cancelComposerSpeechInput()
    }

    /// Browser production consumer. It owns the scope-isolated session and
    /// consumes the canonical SettingsCenter browser snapshot at attachment.
    private(set) var productionBrowserTool: BrowserTool?
    @ObservationIgnored
    private var productionBrowserSettingsSource: ProductionBrowserSettingsSource?
    @ObservationIgnored
    private var productionBrowserNavigationPolicy: BrowserNavigationPolicy?
    @ObservationIgnored
    private var productionBrowserGenerationID: UUID?
    /// P3-P1-03(a)：已装配生产运行时的实时句柄。shell 超时的真实作用点
    /// （defaultShellTimeout 为 var）经此句柄就地刷新，不重建 executor。
    /// 仅 attachProductionServices 写入；nil = 生产尚未装配。
    @ObservationIgnored
    private(set) var productionBuiltinToolExecutor: BuiltinToolExecutor?
    /// Weak references do not extend an idle generation's lifetime. An old
    /// in-flight operation retains its concrete executor until physical drain.
    @MainActor
    private final class ProductionBuiltinOwnerReference {
        weak var value: BuiltinToolExecutor?
        init(_ value: BuiltinToolExecutor) { self.value = value }
    }
    private var productionBuiltinOwnerReferences: [ProductionBuiltinOwnerReference] = []

    /// Capture current and still-live retired owners before cancellation can
    /// release an old engine. Reinstallation must not hide a physical tail.
    func prepareProductionToolsForApplicationExit() -> Task<Void, Never>? {
        productionBuiltinOwnerReferences.removeAll { $0.value == nil }
        let owners = productionBuiltinOwnerReferences.compactMap(\.value)
        guard chat.hasStreamingWorkForApplicationExit ||
                owners.contains(where: { $0.hasPendingOwnedToolOperations }) else { return nil }
        let streams = chat.cancelStreamingForApplicationExit()
        return Task { [weak self] in
            // Each owner keeps its existing TERM/grace/KILL/reap implementation.
            // Drain generations concurrently under the existing Cocoa 3s bound.
            await withTaskGroup(of: Void.self) { group in
                for owner in owners {
                    group.addTask { await owner.cancelOwnedToolsForApplicationExit() }
                }
            }
            for stream in streams { await stream.value }
            guard let self else { return }
            self.productionBuiltinOwnerReferences.removeAll {
                guard let owner = $0.value else { return true }
                return owner !== self.productionBuiltinToolExecutor &&
                    !owner.hasPendingOwnedToolOperations
            }
        }
    }
    /// Freeze the successful physical binding so a symlink alias cannot
    /// retarget both sides of a later directory comparison together.
    @ObservationIgnored
    private var productionSessionDirectoryIdentity: URL?
    /// This Bridge alone binds the lifecycle authority it created to the
    /// already admitted storage root. Rebuilding policy wrappers must not open
    /// a second persistence baseline while a frozen turn still owns this one.
    @ObservationIgnored
    private var productionContextLifecycleBinding: (
        directoryIdentity: URL,
        gate: ContextOrchestrator.AgentLoopWritebackGate
    )?
    /// P3-OUTPUT-01（DEV-297 接线）：组合根注入的逐文件变更台账生产实例。
    /// 与 `productionBuiltinToolExecutor.fileChangeLedger` 同一对象；nil =
    /// 生产尚未装配。App 侧消费端（244B 投影线）经 FileChangeLedger 既有
    /// 只读查询 API（record/diffPayload/records/diffReference）按会话键取
    /// 逐文件条目与 diffID；本线不新增语义、不改 MinisCore API。
    @ObservationIgnored
    private(set) var productionFileChangeLedger: FileChangeLedger?
    private var productionTranscriptSecretStore: EnvVarStore?
    var productionTranscriptRedactor: ChatTranscriptRedactor? {
        productionTranscriptSecretStore.map { ChatTranscriptRedactor(store: $0) }
    }
    /// 已提交的 fallback 开关。逐轮 provider 路由工厂与 turn 快照工厂读取本值
    /// （而非构造期捕获的快照），装配后切换的设置自下一轮生效。
    @ObservationIgnored
    private(set) var productionFallbackEnabled: Bool = false
    /// P3-P1-03(a)：运行中重施设置的事件回执。沿用 P3-SAFE
    /// SafetyRuntimeTransitionReceipt 的既有先例（可观察、代号单调递增、
    /// 永不重置），保证每次提交驱动的生效都是可追溯事件，不存在静默重建
    /// 路径。磁盘级持久化属持久化格式变更，超出本需求行当前裁决。
    struct AgentSettingsReapplyReceipt: Equatable {
        enum Source: String, Equatable {
            /// 启动时的首次生产组合。
            case initialAttach
            /// 运行时经既有组合缝（文件访问边界/P3-CHILD-40 重绑）重建组合根。
            case compositionReattach
            /// 就地数值/开关刷新缝，不重建任何组件身份。
            case runtimeRefresh
        }
        let generation: UInt64
        let source: Source
        let maxLoopIterations: Int
        let toolTimeoutSeconds: Int
        let shellCommandTimeoutSeconds: Int
        let concurrentToolLimit: Int
        let fallbackEnabled: Bool
        let issuedAt: Date
    }
    @ObservationIgnored
    private(set) var lastAgentSettingsReapplyReceipt: AgentSettingsReapplyReceipt?
    @ObservationIgnored
    private var agentSettingsReapplyGeneration: UInt64 = 0

    /// 单一回执提交点：所有把 agent 快照施加到生产运行时的路径都必须经过它，
    /// 首装配记 initialAttach，之后的任何组合重建记 compositionReattach。
    private func commitAgentSettingsReapplyReceipt(
        source: AgentSettingsReapplyReceipt.Source,
        settings: AgentSettings
    ) {
        agentSettingsReapplyGeneration &+= 1
        lastAgentSettingsReapplyReceipt = AgentSettingsReapplyReceipt(
            generation: agentSettingsReapplyGeneration,
            source: source,
            maxLoopIterations: settings.maxLoopIterations,
            toolTimeoutSeconds: settings.toolTimeoutSeconds,
            shellCommandTimeoutSeconds: settings.shellCommandTimeoutSeconds,
            concurrentToolLimit: settings.concurrentToolLimit,
            fallbackEnabled: settings.fallbackEnabled,
            issuedAt: Date()
        )
    }

    /// Goal18 CHILD-DELETE-AUTO: the configuration held by the live production
    /// approval delegate (nil until production services are attached). Read-only;
    /// it exists so the composition result can be verified, not to change it.
    var productionChildDeletionReviewConfiguration: ChildDeletionReviewConfiguration? {
        (productionApprovalDelegate as? ChildDeletionApprovalDelegate)?.reviewConfiguration
    }

    private func productionBrowserBoundDelegate() -> (any ApprovalDelegate)? {
        guard let delegate = productionApprovalDelegate else { return nil }
        guard let generationID = productionBrowserGenerationID,
              let browserSession = productionBrowserTool?.session else { return delegate }
        return ProductionBrowserGenerationApprovalDelegate(
            generationID: generationID, base: delegate,
            browserSession: browserSession, browserRules: browserInteractionRules
        )
    }

    private func productionApprovalReceiptSink(
        boundTo approvedBrowserSession: BrowserSession?
    ) -> @Sendable (ApprovalReceipt) async throws -> Void {
        { [weak self, approvedBrowserSession] receipt in
            let accepted = await MainActor.run { () -> Bool in
                guard let self else { return false }
                guard BrowserSideEffectPolicy.browserToolNames.contains(receipt.toolName.lowercased()) else {
                    self.approvalReceipts.append(receipt)
                    return true
                }
                let prefix = "action: "
                guard receipt.inputSummary.hasPrefix(prefix) else { return false }
                let action = String(receipt.inputSummary.dropFirst(prefix.count)
                    .prefix { $0 != "," && $0 != " " && $0 != "…" })
                if BrowserSideEffectPolicy.readActions.contains(action) {
                    self.approvalReceipts.append(receipt)
                    return true
                }
                // Transfers use the same call/digest/scope-bound one-shot
                // grant as click/type. Their prepared interaction still checks
                // the original resource, selector, exact file identity and
                // same-origin target before any bytes move; this receipt hop
                // must not reject them before those execution gates run.
                guard ["click", "type", "download", "upload"].contains(action),
                      BrowserApprovalReceiptRedeemer.authorizedSideEffectAction(of: receipt) == action,
                      let approvedBrowserSession,
                      self.productionBrowserTool?.session === approvedBrowserSession,
                      approvedBrowserSession.resourceState != .closed,
                      self.productionBrowserTool?.authorizeFromApprovalReceipt(receipt) == true else {
                    return false
                }
                self.approvalReceipts.append(receipt)
                return true
            }
            guard accepted else {
                throw ApprovalError.denied(reason: "Approved browser receipt could not reach its original session")
            }
        }
    }

    /// ChatStore captures its engine by value per turn. Replace only the
    /// future-turn gate, preserving old pending approvals on their old gate.
    private func rebindProductionBrowserApprovalGate() {
        guard var engine = chat.agentEngine as? AgentLoopChatEngine,
              var gate = engine.loop.approvalGate else { return }
        gate.onApprovalReceipt = productionApprovalReceiptSink(
            boundTo: productionBrowserTool?.session
        )
        gate.delegate = productionBrowserBoundDelegate()
        engine.loop.approvalGate = gate
        chat.agentEngine = engine
    }

    /// Only the canonical chat owner may choose the Agent browser tuple. A
    /// missing active conversation cannot inherit a prior session's WebView or
    /// side-effect grant, and a model-supplied URL/input never chooses scope.
    private func trustedProductionBrowserScope() -> BrowserSessionScope? {
        guard let sessionID = chat.activeSessionID,
              chat.hasSession(sessionID) else { return nil }
        let workspaceID = chat.composerWorkspaceID
        guard !workspaceID.isEmpty else { return nil }
        let scope = BrowserSessionScope(
            surface: .agentBrowser,
            profile: "production",
            session: sessionID.uuidString,
            workspace: workspaceID
        )
        return scope.isolationKey == nil ? nil : scope
    }

    /// A chat mutation can fire for every message; only a changed trusted
    /// tuple replaces the browser. A production re-attach intentionally forces
    /// a fresh resource even for the same tuple, preserving the old generation
    /// and one-shot grant invalidation contract.
    private func reconcileProductionBrowserSession(forceReplacement: Bool = false) {
        guard let builtin = productionBuiltinToolExecutor else { return }
        let scope = trustedProductionBrowserScope()
        if !forceReplacement, let current = productionBrowserTool,
           current.session.scope == scope,
           current.session.resourceState != .closed { return }

        // Close before replacement so an in-flight old lease cannot publish
        // into the new resource or carry an unspent write grant across it.
        if let previous = productionBrowserTool?.session,
           previous.resourceState != .closed { previous.close() }
        productionBrowserTool = nil
        builtin.browser = nil
        productionBrowserGenerationID = nil
        guard let scope,
              let isolationKey = scope.isolationKey,
              let settingsSource = productionBrowserSettingsSource,
              let navigationPolicy = productionBrowserNavigationPolicy else {
            rebindProductionBrowserApprovalGate()
            return
        }
        let tool = BrowserTool(
            scope: scope,
            settings: settingsSource.snapshot(),
            writeActionsEnabled: productionChildModelSettings.browserWriteEnabled,
            navigationPolicy: navigationPolicy,
            settingsProvider: { @MainActor [settingsSource] in
                settingsSource.snapshot()
            }
        )
        productionBrowserTool = tool
        let generationID = UUID()
        productionBrowserGenerationID = generationID
        builtin.browser = ProductionSessionBoundBrowserExecutor(
            conversationID: isolationKey.session,
            generationID: generationID,
            tool: tool
        )
        rebindProductionBrowserApprovalGate()
    }

    /// Apply a newly committed browser settings snapshot to the already
    /// attached production resource. This keeps the BrowserTool session as the
    /// sole lifecycle owner while allowing settings changes to affect the next
    /// operation and its idle watchdog immediately.
    func refreshProductionBrowserSettings(_ settings: BrowserSettings? = nil) {
        if let settings {
            productionBrowserSettingsSource?.update(settings)
        }
        guard let productionBrowserTool else { return }
        productionBrowserTool.apply(
            settings: settings
                ?? productionBrowserSettingsSource?.snapshot()
                ?? .default
        )
    }

    /// P3-P1-03(a)：把运行时提交的 AppSettings.agent 快照重新施加到已装配的
    /// 生产运行时，无需重启或重新组合：
    /// · 迭代上限 / 并发门控 / 诊断记录值 → 引擎结构体写回（下一轮生效）；
    /// · 工具超时真实作用点 → BuiltinToolExecutor.defaultShellTimeout 直写；
    /// · fallback 开关 → productionFallbackEnabled，逐轮路由工厂即时读取。
    /// 进行中的轮次保持其冻结快照；生产未装配时刷新开关与句柄（如有），并留下
    /// 单调回执 —— 运行中生效路径一律可见，不静默。
    func refreshProductionAgentSettings(_ settings: AgentSettings) {
        chat.setTokenBudgetLimit(settings.maxTokensPerSession, unlimited: settings.tokenBudgetUnlimited)
        let browserWritePolicyChanged = productionChildModelSettings.browserWriteEnabled != settings.browserWriteEnabled
        productionChildModelSettings = settings
        if browserWritePolicyChanged { reconcileProductionBrowserSession(forceReplacement: true) }
        productionFallbackEnabled = settings.fallbackEnabled
        productionBuiltinToolExecutor?.defaultShellTimeout = settings.shellCommandTimeoutSeconds
        if var engine = chat.agentEngine as? AgentLoopChatEngine {
            engine.reapplyRuntimeAgentSettings(settings)
            chat.agentEngine = engine.withChildMutationsEnabled(settings.childMutationsEnabled)
        }
        commitAgentSettingsReapplyReceipt(source: .runtimeRefresh, settings: settings)
    }

    nonisolated static func canonicalSessionDirectoryIdentity(_ directory: URL) -> URL? {
        guard directory.isFileURL,
              var components = URLComponents(url: directory, resolvingAgainstBaseURL: true)
        else { return nil }
        let resolved = directory.resolvingSymlinksInPath().standardizedFileURL
        // Normalize only the existing allowlisted Darwin aliases. Other
        // canonical paths retain the original directory admission semantics.
        let stablePath = DarwinSystemPathResolver.resolveOutcome(resolved).path ?? resolved.path
        guard let canonical = URLComponents(
                url: URL(fileURLWithPath: stablePath, isDirectory: true),
                resolvingAgainstBaseURL: true
              ) else { return nil }
        // Keep the original scheme/authority and other URL components while
        // retaining the existing physical path resolution and normalizing its
        // directory hint. Rebuilding a file URL from a path loses authority.
        components.percentEncodedPath = canonical.percentEncodedPath
        if !components.percentEncodedPath.hasSuffix("/") {
            components.percentEncodedPath += "/"
        }
        return components.url
    }

    /// App 启动时调用：装配 B1b AgentLoop 引擎、B1d SessionStore 会话持久化、
    /// B1c SkillInjector 注入、E8 会话 token 预算。测试环境不调用（保持内存态，避免磁盘污染）。
    /// - Parameter agentSettings: AppSettings.agent 组快照（E8 预算上限/警告阈值；默认值即内置默认）。
    /// - Parameter fileAccessAllowedRoot: AJ-28 可选的授权根目录覆盖；nil = 默认（会话项目目录）。
    /// - Parameter fileAccessDeniedRoots: 用户、Hook 或调用方显式拒绝根；不得从混合默认根集合反推。
    /// - Parameter fileAccessDefaultPrivateDataRoots: 可信 App 单独证明的默认私有根；仅精确 owned-output receipt 可例外读取。
    ///   nil 保留 Builtin 的兼容默认语义；显式 deniedRoots（包括 []）不隐式增加默认私有根。
    /// - Parameter fileAccessMountedRoots: AJ-45 挂载的外部文件夹（额外白名单）；默认空。
    /// - Parameter localAgentSessionHome: 非 nil = 允许 external_session_* 读取该 home 下的本机 Codex / Claude Code 会话目录（不进入文件工具白名单）。
    /// - Parameter policyDefaults: S6 生产 PolicyRuntime 保守默认（budget/时限/自主权/域名）；
    ///   nil 或缺省 = ProductionPolicyDefaults.default（有界、有限、低自主、空域名）。
    ///   显式传入的默认值原样生效，用于需要放宽/收紧封套的显式配置路径。
    @discardableResult
    func attachProductionServices(
        agentSettings: AgentSettings = .default,
        browserSettings: BrowserSettings? = nil,
        speechGeneralLanguage: String? = nil,
        fileAccessAllowedRoot: URL? = nil,
        fileAccessDeniedRoots: [URL]? = nil,
        fileAccessDefaultPrivateDataRoots: [URL]? = nil,
        fileAccessMountedRoots: [URL] = [],
        localAgentSessionHome: URL? = nil,
        sessionDirectory: URL = SessionStore.defaultDirectory,
        mcpManager: MCPServerManager? = nil,
        skillStore: SkillStore? = nil,
        mcpBridgeOverride: (any MCPToolBridge)? = nil,
        approvalDelegateOverride: (any ApprovalDelegate)? = nil,
        projectSessionApproval: (@MainActor (ProjectSessionCreateRequest, String) -> Bool)? = nil,
        childDeletionReviewConfiguration: ChildDeletionReviewConfiguration = .init(),
        policyDefaults: ProductionPolicyDefaults = .default,
        enableOrchestration: Bool = false,
        childConcurrencySelection: ChildConcurrencySelection = .default,
        canvasRuntimeState: RuntimeIsolationProfile.CanvasRuntimeState? = nil,
        externalRunners: [String: any ExternalAgentRunner] = AgentOrchestrator.makeDefaultRunners(),
        externalNetworkAllowed: Bool = true,
        controlledFieldLoopbackAllowed: Bool = false,
        sessionReadSecretStore: EnvVarStore? = nil,
        preserveChildGovernorOnSafetyLift: Bool = false
    ) -> Task<Void, Never> {
        // Validate before changing generation, refresh callbacks, admission,
        // queued work, or constructing a replacement registry. Pointer identity
        // distinguishes a second writer even when its file URL is identical.
        let admittedMCPManager: MCPServerManager?
        if let canonicalMCPManager {
            if let mcpManager, mcpManager !== canonicalMCPManager {
                productionMCPWriterAdmission = .rejected(.conflictingMCPWriter)
                return Task { }
            }
            admittedMCPManager = canonicalMCPManager
            productionMCPWriterAdmission = .admitted
        } else {
            admittedMCPManager = mcpManager
            productionMCPWriterAdmission = .unpinned
        }
        guard isProductionSessionDirectoryCurrent(sessionDirectory) else {
            productionProjectSessionHandler?.disableProductionBinding()
            productionProjectSessionHandler = nil
            chat.projectSessionHandler = nil
            chat.logManager.error("PROJECT_SESSION_DIRECTORY_NOT_CURRENT", category: "ProjectSession")
            return Task { }
        }
        productionAttachmentGeneration &+= 1
        let generation = productionAttachmentGeneration
        let canonicalSelection = try! childConcurrencySelection.withRuntime(nil)
        let commit: @MainActor (ChildConcurrencyGovernor) -> Void = { [weak self] governor in
            self?.commitProductionServices(
                agentSettings: agentSettings,
                browserSettings: browserSettings,
                speechGeneralLanguage: speechGeneralLanguage,
                fileAccessAllowedRoot: fileAccessAllowedRoot,
                fileAccessDeniedRoots: fileAccessDeniedRoots,
                fileAccessDefaultPrivateDataRoots: fileAccessDefaultPrivateDataRoots,
                fileAccessMountedRoots: fileAccessMountedRoots,
                localAgentSessionHome: localAgentSessionHome,
                sessionDirectory: sessionDirectory,
                mcpManager: admittedMCPManager,
                skillStore: skillStore,
                mcpBridgeOverride: mcpBridgeOverride,
                approvalDelegateOverride: approvalDelegateOverride,
                projectSessionApproval: projectSessionApproval,
                childDeletionReviewConfiguration: childDeletionReviewConfiguration,
                policyDefaults: policyDefaults,
                enableOrchestration: enableOrchestration,
                childConcurrencySelection: childConcurrencySelection,
                canvasRuntimeState: canvasRuntimeState,
                externalRunners: externalRunners,
                externalNetworkAllowed: externalNetworkAllowed,
                controlledFieldLoopbackAllowed: controlledFieldLoopbackAllowed,
                sessionReadSecretStore: sessionReadSecretStore,
                preserveChildGovernorOnSafetyLift: preserveChildGovernorOnSafetyLift,
                preparedChildGovernor: governor
            )
        }
        productionAttachmentRefresh = { [weak self] in
            _ = self?.attachProductionServices(
                agentSettings: agentSettings,
                browserSettings: browserSettings,
                speechGeneralLanguage: speechGeneralLanguage,
                fileAccessAllowedRoot: fileAccessAllowedRoot,
                fileAccessDeniedRoots: fileAccessDeniedRoots,
                fileAccessDefaultPrivateDataRoots: fileAccessDefaultPrivateDataRoots,
                fileAccessMountedRoots: fileAccessMountedRoots,
                localAgentSessionHome: localAgentSessionHome,
                sessionDirectory: sessionDirectory,
                mcpManager: admittedMCPManager,
                skillStore: skillStore,
                mcpBridgeOverride: mcpBridgeOverride,
                approvalDelegateOverride: approvalDelegateOverride,
                projectSessionApproval: projectSessionApproval,
                childDeletionReviewConfiguration: childDeletionReviewConfiguration,
                policyDefaults: policyDefaults,
                enableOrchestration: enableOrchestration,
                childConcurrencySelection: childConcurrencySelection,
                canvasRuntimeState: canvasRuntimeState,
                externalRunners: externalRunners,
                externalNetworkAllowed: externalNetworkAllowed,
                controlledFieldLoopbackAllowed: controlledFieldLoopbackAllowed,
                sessionReadSecretStore: sessionReadSecretStore,
                preserveChildGovernorOnSafetyLift: preserveChildGovernorOnSafetyLift
            )
        }
        // An empty first journal preserves the synchronous first bind. A
        // persisted journal must be read off the App actor before publishing
        // any production wrapper that could append a newer observation.
        if retainedProductionChildGovernor == nil {
            let revision = ChildConcurrencyGovernor.ControlRevision()
            let governor: ChildConcurrencyGovernor
            do {
                let journal = try ChildGovernorCheckpointJournal2957(directory: sessionDirectory)
                childGovernorCheckpointJournal = journal
                childGovernorCheckpointRecoveryUnavailable = false
                let write: @Sendable (ChildConcurrencyCheckpoint) throws -> Void = {
                    try journal.write($0)
                }
                if let recovered = journal.recoveredCheckpoint {
                    let checkpoint = try ChildGovernorCheckpointJournal2957.reconciledForReopen(
                        recovered, records: agentTaskStore.childLaunchIntents())
                    governor = .restored(from: checkpoint, policy: .derived(from: canonicalSelection),
                        managedControlRevision: revision,
                        stopNewLaunches: !effectiveProductionOrchestration(enableOrchestration),
                        checkpointPersistence: write)
                } else {
                    governor = ChildConcurrencyGovernor(policy: .derived(from: canonicalSelection),
                        managedControlRevision: revision,
                        stopNewLaunches: !effectiveProductionOrchestration(enableOrchestration),
                        checkpointPersistence: write)
                }
            } catch {
                // A corrupt/unavailable journal must not be replaced by an
                // empty snapshot, nor authorize a fresh physical invocation.
                childGovernorCheckpointRecoveryUnavailable = true
                governor = ChildConcurrencyGovernor(policy: .derived(from: canonicalSelection),
                    managedControlRevision: revision,
                    stopNewLaunches: !effectiveProductionOrchestration(enableOrchestration),
                    checkpointPersistence: { _ in
                        throw ChildGovernorCheckpointJournal2957.Failure.unavailable
                    })
            }
            retainedProductionChildGovernor = governor
            childGovernorControlRevision = revision
            let journal = sessionDirectory.appendingPathComponent(
                "provider-runtime-observations-v1.json"
            )
            if !FileManager.default.fileExists(atPath: journal.path) {
                commit(governor)
                return Task { }
            }
        }
        pendingProductionAttachment = ProductionAttachmentRequest(
            generation: generation, sessionDirectory: sessionDirectory,
            selection: canonicalSelection, enableOrchestration: enableOrchestration,
            safetyEpoch: safetyRuntimeEpoch, sessionID: chat.activeSessionID,
            composerRevision: chat.composerPolicyFacts.revision, commit: commit)
        // Existing submissions already retain their frozen settings/runtime.
        // New submissions must not capture the previous wrappers while the
        // retained actor's configuration and full assembly are being committed.
        // Preserve even an absent source exactly, once for the whole queue.
        if !productionAttachmentAdmissionSuspended {
            productionAttachmentSettingsSource = chat.effectiveSettingsSnapshotSource
            productionAttachmentAdmissionSuspended = true
            self.childConcurrencySelection = try! self.childConcurrencySelection.withRuntime(nil)
            chat.effectiveSettingsSnapshotSource = { nil }
        }
        if productionAttachmentInProgress, let task = productionAttachmentTask {
            return task
        }
        productionAttachmentInProgress = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.commitPendingProductionAttachments()
        }
        productionAttachmentTask = task
        lastChildGovernorSafetyTask = task
        return task
    }

    private func effectiveProductionOrchestration(_ requested: Bool) -> Bool {
        requested && isSafetyFeatureEnabled(.externalAgents)
            && isSafetyFeatureEnabled(.childOrchestration)
    }

    private func isProductionSessionDirectoryCurrent(_ directory: URL) -> Bool {
        let attached = chat.sessionStore?.directory
        guard let canonical = Self.canonicalSessionDirectoryIdentity(directory),
              (injectedSessionStore == nil || injectedSessionStore.flatMap {
                  Self.canonicalSessionDirectoryIdentity($0.directory)
              } == canonical),
              (injectedSessionStore == nil || chat.sessionStore == nil
               || chat.sessionStore === injectedSessionStore),
              (attached == nil || attached.flatMap {
                  Self.canonicalSessionDirectoryIdentity($0)
              } == canonical),
              (productionSessionDirectoryIdentity == nil
               || productionSessionDirectoryIdentity == canonical) else { return false }
        return true
    }

    /// Settings and Chat consume one App-owned store. Once Settings commits a
    /// confirmed deletion, retire the same session from Chat's in-memory view
    /// before another ordinary change can run the full transcript upsert.
    @discardableResult
    func bindConfirmedSessionDeletionProjection(to settings: SettingsCenter) -> Bool {
        guard let owner = injectedSessionStore, settings.sessionStore === owner else {
            return false
        }
        settings.onConfirmedSessionDeletion = { [weak self] ids in
            guard let self, self.chat.sessionStore === owner else { return }
            self.chat.reconcileConfirmedExternalSessionDeletion(ids)
        }
        settings.sessionDeletionBlocker = { [weak self] id in
            self?.chat.backgroundDeletionBlockReason(sessionID: id)
        }
        return true
    }

    /// The composition root may finish its settings binding after awaiting a
    /// synchronous first attach while a callback has already queued a rebind.
    /// Keep that real binding behind the existing unavailable-settings gate.
    func bindProductionEffectiveSettingsSource(_ source: (() -> BL6EffectiveSettingsSnapshot?)?) {
        if productionAttachmentAdmissionSuspended {
            productionAttachmentSettingsSource = source
        } else {
            chat.effectiveSettingsSnapshotSource = source
        }
    }

    private func commitPendingProductionAttachments() async {
        var latestPublishedRequest: ProductionAttachmentRequest?
        defer {
            productionAttachmentInProgress = false
            // A stale, refused or cancelled transaction cannot reopen an old
            // permission window. Only the latest complete assembly releases
            // the existing settings gate, with no await during restoration.
            if let published = latestPublishedRequest,
               !Task.isCancelled,
               pendingProductionAttachment == nil,
               published.generation == productionAttachmentGeneration,
               isProductionSessionDirectoryCurrent(published.sessionDirectory) {
                chat.effectiveSettingsSnapshotSource = productionAttachmentSettingsSource
                productionAttachmentSettingsSource = nil
                productionAttachmentAdmissionSuspended = false
            }
        }
        while let request = pendingProductionAttachment {
            guard !Task.isCancelled else { return }
            pendingProductionAttachment = nil
            guard request.generation == productionAttachmentGeneration,
                  isProductionSessionDirectoryCurrent(request.sessionDirectory),
                  let governor = retainedProductionChildGovernor,
                  let expected = childGovernorControlRevision else { continue }
            let canonicalDirectory = Self.canonicalSessionDirectoryIdentity(
                request.sessionDirectory
            )
            var journalLoad: ProviderRuntimeObservationJournalLoad?
            if canonicalDirectory != loadedProviderRuntimeObservationDirectory {
                let url = request.sessionDirectory.appendingPathComponent(
                    "provider-runtime-observations-v1.json"
                )
                let reader: @Sendable (URL) throws -> Data = readProviderRuntimeObservationJournalForTesting
                    ?? { try Data(contentsOf: $0) }
                journalLoad = await Task.detached(priority: .userInitiated) {
                    () -> ProviderRuntimeObservationJournalLoad in
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        return .missing
                    }
                    do {
                        let data = try reader(url)
                        return .stored(try JSONDecoder().decode(
                            [ProviderRuntimeRouteObservation].self, from: data
                        ))
                    } catch {
                        return .failed(String(describing: error))
                    }
                }.value
                guard !Task.isCancelled,
                      request.generation == productionAttachmentGeneration,
                      isProductionSessionDirectoryCurrent(request.sessionDirectory) else {
                    continue
                }
            }
            let revision = await governor.reconfigure(
                policy: .derived(from: request.selection), replacing: expected,
                stopNewLaunches: !effectiveProductionOrchestration(request.enableOrchestration))
            // A completed actor transaction cannot be rolled back by cancelling
            // its caller. Retain the actual controller even for an obsolete bind.
            guard let revision else { continue }
            childGovernorControlRevision = revision
            #if DEBUG
            onProductionAttachmentPreparedForTesting?()
            #endif
            guard !Task.isCancelled else { return }
            guard request.generation == productionAttachmentGeneration else { continue }
            guard isProductionSessionDirectoryCurrent(request.sessionDirectory) else {
                _ = await governor.engageKillSwitch(controlRevision: revision)
                continue
            }
            guard request.safetyEpoch == safetyRuntimeEpoch,
                  request.sessionID == chat.activeSessionID,
                  request.composerRevision == chat.composerPolicyFacts.revision else {
                productionAttachmentRefresh?()
                continue
            }
            // No await from this validated point through the existing complete
            // assembly: persistence, wrappers and the engine publish together.
            if let canonicalDirectory, let journalLoad {
                preparedProviderRuntimeObservationJournal =
                    (directory: canonicalDirectory, load: journalLoad)
            }
            request.commit(governor)
            preparedProviderRuntimeObservationJournal = nil
            latestPublishedRequest = request
        }
    }

    /// Stateless composition shared by synchronous assembly and child isolation.
    /// The typed child factory is passed in, so no stored closure captures a
    /// not-yet-initialized local policy factory or a mutable reference box.
    private func makePolicyWrappedExecutor(
        goal: GoalEnvelope, lease: AutonomyLease, owner: BuiltinToolExecutor,
        orchestrationExecutor: OrchestrationToolExecutor?,
        projectSessionHandler: ProjectSessionAppHandler?,
        conversationSettingsCenter: SettingsCenter?,
        canonicalSessionDirectory: URL,
        registeredBuiltinOwnerID: ObjectIdentifier,
        sessionReadSecretStore: EnvVarStore?,
        makeBoundChildOrchestrator: @escaping @Sendable (
            AgentExecutionContextSnapshot, GoalEnvelope, BuiltinToolExecutor,
            ToolExecutorReference, AutonomyLease?, [String], [ProjectSessionGrantRegistry.DirectoryGrant]
        ) async throws -> AgentOrchestrator,
        sourceSessionID: String? = nil,
        originalRootCeiling: [String] = [],
        inheritedDirectorySnapshot: [ProjectSessionGrantRegistry.DirectoryGrant]? = nil
    ) -> any ToolExecutor {
        let directorySnapshot = inheritedDirectorySnapshot
            ?? projectSessionHandler?.captureDirectoryGrants(sessionID: sourceSessionID,
                owner: owner, originalRootCeiling: originalRootCeiling) ?? []
        let taskExecutorReference = ToolExecutorReference(owner)
        let composedBase: any ToolExecutor = if let orchestrationExecutor {
            OrchestrationCompositeToolExecutor(
                base: owner,
                orchestration: orchestrationExecutor,
                makeRuntimeOrchestrator: { context in
                    try await makeBoundChildOrchestrator(context, goal, owner, taskExecutorReference, lease,
                        originalRootCeiling, directorySnapshot)
                }
            )
        } else {
            owner
        }
        let projectComposedBase: any ToolExecutor = if let projectSessionHandler {
            ProjectSessionCompositeToolExecutor(base: composedBase, builtin: owner,
                handler: projectSessionHandler, workspaceBindings: self.projectWorkspaceBindings,
                directorySnapshot: directorySnapshot,
                directoryOriginalRoots: originalRootCeiling)
        } else {
            composedBase
        }
        let settingsComposedBase: any ToolExecutor = if let conversationSettingsCenter {
            ConversationSettingsToolExecutor(
                base: projectComposedBase,
                center: conversationSettingsCenter,
                chat: self.chat,
                shortcutStore: self.shortcutStore.usesPreferencesDomain(self.preferencesDefaults)
                    ? self.shortcutStore : nil,
                skillsStore: self.settingsCatalogSkillsStore,
                schedulerStore: self.settingsCatalogSchedulerStore,
                preferencesDefaults: self.preferencesDefaults,
                sidebarWidthSetting: self.sidebarWidthSetting,
                sessionDirectory: canonicalSessionDirectory
            )
        } else {
            projectComposedBase
        }
        let safetyGatedBase = SafetyRuntimeToolGate(
            base: settingsComposedBase,
            compositionOwner: registeredBuiltinOwnerID,
            snapshotProvider: { [weak self] in
                guard let self else {
                    return (.failClosedDefaults, 0, nil)
                }
                return await MainActor.run {
                    (self.safetyRuntimeSnapshot, self.safetyRuntimeEpoch,
                     self.productionBuiltinToolExecutor.map { ObjectIdentifier($0) })
                }
            }
        )
        // P3-G1（MC0-P1-01）：PolicyRuntime 进入生产 executor seam。builtin 之上
        // 包一层 PolicyEnforcedToolExecutor —— 每次工具调用先过 validatePolicy
        // （capability/lease/scope/budget/deadline/fileRoot），非法调用在到达
        // BuiltinToolExecutor 之前被拒绝（底层执行 = 0）。capabilityResolver 复用
        // builtin 的 live 注册表，运行期发现的 MCP 工具仍可经审批后放行。
        // S6：封套默认值改为 ProductionPolicyDefaults.default（budget 10_000、
        // 4h 有限时限、autonomy .l1、空域名 fail-closed），替换此前的宽松写死
        // （1M / .distantFuture / .l3 / 空域名）。显式传入 policyDefaults 的
        // 调用路径原样生效。
        let policyExecutor = PolicyEnforcedToolExecutor(
            base: safetyGatedBase,
            goal: goal,
            // lease 生命周期与 goal 对齐（同为有限）：签发于 goal 创建、过期于 goal 时限。
            lease: lease,
            capabilityResolver: (settingsComposedBase as? any PolicyCapabilityResolving) ?? owner,
            requestBuilder: PolicyEnforcedToolExecutor.productionRequestBuilder
        )
        // P3 内容级脱敏：ActionRecord 参数/结果摘要与工具错误文本不仅做格式级
        // 内嵌脱敏（Bearer/API-key/cookie/userinfo），还把已配置的 env secret 值
        // （含 Keychain 托管）注入 RecordingToolExecutor 一并打码（与转录面同源）。
        let recordingExecutor = RecordingToolExecutor(
            base: policyExecutor,
            onRecorded: { [weak self] record in
                Task { @MainActor [weak self] in
                    self?.actionHistory.record(record)
                }
            },
            knownSecretValues: ChatTranscriptRedactor(store: sessionReadSecretStore ?? F6EnvStoreSource.shared).secretValues,
            fileChangePrecheckAdmission: { name in
                try await safetyGatedBase.validateFileChangePrecheckAdmission(name: name)
            }
        )
        taskExecutorReference.value = recordingExecutor
        return recordingExecutor
    }

    private func commitProductionServices(
        agentSettings: AgentSettings = .default,
        browserSettings: BrowserSettings? = nil,
        speechGeneralLanguage: String? = nil,
        fileAccessAllowedRoot: URL? = nil,
        fileAccessDeniedRoots: [URL]? = nil,
        fileAccessDefaultPrivateDataRoots: [URL]? = nil,
        fileAccessMountedRoots: [URL] = [],
        localAgentSessionHome: URL? = nil,
        sessionDirectory: URL = SessionStore.defaultDirectory,
        mcpManager: MCPServerManager? = nil,
        skillStore: SkillStore? = nil,
        mcpBridgeOverride: (any MCPToolBridge)? = nil,
        approvalDelegateOverride: (any ApprovalDelegate)? = nil,
        projectSessionApproval: (@MainActor (ProjectSessionCreateRequest, String) -> Bool)? = nil,
        childDeletionReviewConfiguration: ChildDeletionReviewConfiguration = .init(),
        policyDefaults: ProductionPolicyDefaults = .default,
        enableOrchestration: Bool = false,
        childConcurrencySelection: ChildConcurrencySelection = .default,
        canvasRuntimeState: RuntimeIsolationProfile.CanvasRuntimeState? = nil,
        externalRunners: [String: any ExternalAgentRunner] = AgentOrchestrator.makeDefaultRunners(),
        externalNetworkAllowed: Bool = true,
        controlledFieldLoopbackAllowed: Bool = false,
        sessionReadSecretStore: EnvVarStore? = nil,
        preserveChildGovernorOnSafetyLift: Bool = false,
        preparedChildGovernor: ChildConcurrencyGovernor
    ) {
        // Reject a different data root or non-file scheme before directory I/O.
        // Missing/existing directory hints are the same canonical directory;
        // the first successful binding still fences a changed symlink target.
        let attachedDirectory = chat.sessionStore?.directory
        guard let canonicalSessionDirectory = Self.canonicalSessionDirectoryIdentity(sessionDirectory),
              (attachedDirectory == nil || attachedDirectory.flatMap {
                  Self.canonicalSessionDirectoryIdentity($0)
              } == canonicalSessionDirectory),
              (productionSessionDirectoryIdentity == nil
               || productionSessionDirectoryIdentity == canonicalSessionDirectory) else {
            productionProjectSessionHandler?.disableProductionBinding()
            productionProjectSessionHandler = nil
            chat.projectSessionHandler = nil
            chat.logManager.error("PROJECT_SESSION_DIRECTORY_NOT_CURRENT", category: "ProjectSession")
            return
        }
        // Rebuild execution wrappers only after the resource configuration
        // transaction. Captured old turns retain their permits on that actor,
        // while current permissions/context are rebuilt for this binding.
        taskCenterControlConsumer.resetChildRetryBindings()
        taskCenterRetryOrchestratorFactory = nil
        taskCenterRetryAssemblyGeneration = UUID()
        taskCenterControlConsumer.bindFileArtifacts(ledger: nil, facts: nil)
        // Rebinding services cannot leave an old recognizer recording or let
        // its eventual result write into the newly attached conversation.
        cancelComposerSpeechInput()
        stopProductionSpeechOutput()
        composerSpeechGeneralLanguage = speechGeneralLanguage
        productionExternalNetworkAllowed = externalNetworkAllowed
        productionControlledFieldLoopbackAllowed = controlledFieldLoopbackAllowed
            && !externalNetworkAllowed
        chat.controlledFieldLoopbackAllowed = productionControlledFieldLoopbackAllowed
        if let canvasRuntimeState {
            configuredCanvasRuntimeState = canvasRuntimeState
            let effectiveCanvasState = canvasFeatureLane == .phase3NonCanvas
                ? .disabled
                : canvasRuntimeState
            self.canvasRuntimeState = effectiveCanvasState
            productionChatComposition = .make(canvasState: effectiveCanvasState)
        }
        updateEffectiveCanvasRuntimeState()
        bindChildGovernorRuntimeReport(nil)
        let canonicalChildSelection = try! childConcurrencySelection.withRuntime(nil)
        self.childConcurrencySelection = canonicalChildSelection
        let effectiveEnableOrchestration = effectiveProductionOrchestration(enableOrchestration)
        providerRuntimeObservationPersistenceURL = sessionDirectory
            .appendingPathComponent("provider-runtime-observations-v1.json")
        do {
            try FileManager.default.createDirectory(
                at: sessionDirectory,
                withIntermediateDirectories: true
            )
            let toolLifecycleURL = sessionDirectory.appendingPathComponent(
                "tool-lifecycle-events-v1.json"
            )
            do {
                try chat.attachToolLifecyclePersistence(toolLifecycleURL)
                toolLifecycleRecoveryFailureURL = nil
            } catch {
                // The canonical consumer leaves rejected bytes untouched.
                // Keep the App open for inspection, but never admit a new turn
                // through ChatStore's preexisting in-memory fixture consumer.
                toolLifecycleRecoveryFailureURL = toolLifecycleURL
                chat.blockTurnsForToolLifecycleRecoveryFailure()
            }
            if loadedProviderRuntimeObservationDirectory != canonicalSessionDirectory {
                // The only persisted-journal path arrives from the detached
                // loader. A fresh first bind has no journal and no stale data.
                let load = preparedProviderRuntimeObservationJournal?.directory
                    == canonicalSessionDirectory
                    ? preparedProviderRuntimeObservationJournal?.load : .missing
                switch load {
                case .stored(let stored):
                    let pending = providerRuntimeObservations
                    providerRuntimeObservations = Array((stored + pending).suffix(64))
                    providerRuntimeObservationPersistenceError = nil
                    if !pending.isEmpty {
                        do {
                            try persistProviderRuntimeObservations()
                        } catch {
                            // A failed append must not quarantine a valid old journal.
                            providerRuntimeObservationPersistenceError = String(describing: error)
                        }
                    }
                case .failed(let description):
                    providerRuntimeObservationPersistenceError = description
                    if let url = providerRuntimeObservationPersistenceURL {
                        _ = quarantineCorruptProviderRuntimeObservationJournal(at: url)
                    }
                    providerRuntimeObservations = []
                    do {
                        try persistProviderRuntimeObservations()
                    } catch {
                        providerRuntimeObservationPersistenceError = String(describing: error)
                    }
                case .missing, .none:
                    providerRuntimeObservationPersistenceError = nil
                }
                loadedProviderRuntimeObservationDirectory = canonicalSessionDirectory
            }
        } catch {
            providerRuntimeObservationPersistenceError = String(describing: error)
            if let url = providerRuntimeObservationPersistenceURL {
                _ = quarantineCorruptProviderRuntimeObservationJournal(at: url)
            }
            providerRuntimeObservations = []
            do {
                try persistProviderRuntimeObservations()
            } catch {
                providerRuntimeObservationPersistenceError = String(describing: error)
            }
        }
        orchestrationEnabled = effectiveEnableOrchestration
        productionExternalRunners = effectiveEnableOrchestration ? externalRunners : [:]
        // E8：会话 token 预算按 AppSettings.agent 组配置（上限 + 警告阈值）
        chat.configureBudget(from: agentSettings, preservingSessionBudget: true)

        // 1) Agent 引擎（B1b + E6 + E8 + C3-3 + F6 P1-5）：AgentLoopChatEngine 装配审批委托 —
        //    高/中风险工具（file_write/shell_execute 等）执行前弹 UI 审批；
        //    E8 用量回调：每轮 LLM 调用后把 usage 记入会话预算（回 MainActor 更新状态行）；
        //    C3-3 工具调用历史：RecordingToolExecutor 包住真实执行器，每次实际执行的
        //    工具调用（shell/文件/搜索）记录 ActionRecord 入 actionHistory 历史栈。
        //    F6（P1-5）：Agent 四项设置真正注入引擎 —
        //      · maxLoopIterations → AgentLoop.maxIterations（此前恒 10）；
        //      · shellCommandTimeoutSeconds → BuiltinToolExecutor.defaultShellTimeout（命令专属120/600）；
        //      · concurrentToolLimit > 1 → ConcurrentToolLimitingExecutor 门控包装；
        //      · fallbackEnabled → 引擎开关 + makeFallbackRouter 构建器待命。
        // AJ-2：UI 持久化与 Agent 跨会话读取必须共享同一个 SessionStore，
        // 避免工具读取到另一份缓存/锁下的会话目录。
        let sessionStore: SessionStore
        let didAttachChatPersistence: Bool
        if let attached = chat.sessionStore {
            sessionStore = attached
            didAttachChatPersistence = true
        } else {
            // In the App, SettingsCenter and this Chat consumer must share the
            // root's exact store. Standalone Bridge fixtures keep the existing
            // directory-based fallback when no owner was injected.
            let selected = injectedSessionStore ?? SessionStore(directory: sessionDirectory)
            sessionStore = selected
            didAttachChatPersistence = chat.attachPersistence(
                selected, badgeStore: sessionBadgeStore
            )
        }
        if didAttachChatPersistence, productionSessionDirectoryIdentity == nil {
            productionSessionDirectoryIdentity = canonicalSessionDirectory
        }
        // Child transcripts must use the very same store that backs ChatStore.
        // A failed persistence attachment keeps the Task Center result-only.
        let sharedChildSessionStore: SessionStore? = if didAttachChatPersistence,
            let attached = chat.sessionStore, attached === sessionStore {
            attached
        } else {
            nil
        }
        taskCenterControlConsumer.bindChildTranscriptSessionStore(sharedChildSessionStore)
        let sessionManager = chat.sessionManager ?? SessionManager(store: sessionStore)
        let productionSkillStore = skillStore ?? SkillStore()
        let maintenanceSettings = SkillsStore(appStore: productionSkillStore,
            stateFileURL: productionSkillStore.skillsRoot.deletingLastPathComponent()
                .appendingPathComponent("skills-enabled.json"), loadImmediately: false)
        let skillMaintenance = SkillMaintenanceTool(store: productionSkillStore, deletion: { intent in
            try await MainActor.run {
                try Task.checkCancellation()
                return try maintenanceSettings.deleteSkill(intent)
            }
        }, onChange: {
            await MainActor.run { SkillCatalogCache.invalidateDefaultCatalog() }
        }, knownSecrets: {
            sessionReadSecretStore.map { ChatTranscriptRedactor(store: $0).secretValues } ?? []
        })
        let productionSoulStore = SoulStore(directory: sessionDirectory)
        // MCP 生产接线：设置中心与 Agent 共用同一份 mcps.json；registry
        // 负责动态发现/cache，BuiltinToolExecutor 负责 live 白名单校验。
        let turnScopedMCPBridge = TurnScopedMCPToolBridge(
            base: mcpBridgeOverride ?? MCPToolRegistry(
                manager: mcpManager ?? MCPServerManager(fileURL: MCPServerManager.defaultFileURL())
            )
        )
        let mcpRegistry: any MCPToolBridge = turnScopedMCPBridge
        let selectedWorkingDirectory = chat.activeSessionID.flatMap { id in
            chat.sessions.first(where: { $0.id == id })?.workingDirectory
        }
        let allowedRootURL = SessionFileRootPolicy.root(
            explicit: fileAccessAllowedRoot, workingDirectory: selectedWorkingDirectory,
            sessionDirectory: sessionDirectory, sessionID: chat.activeSessionID)
        let terminalPolicySnapshot = SettingsCenter.active?.terminalPolicySnapshot
            ?? TerminalPolicySnapshot(settings: agentSettings.terminalPolicy)
        // The App passes its SettingsCenter store. An absent source keeps the
        // legacy format-only read; no ambient credential lookup is introduced.
        webFetchUnavailableReason = WebFetchToolContract.unavailableReason(
            networkAllowed: externalNetworkAllowed, networkDomains: policyDefaults.networkDomains)
        let pinnedConfiguration = webFetchPinnedRouteProvider.map { route in
            WebFetchPinnedConfiguration(
                provenance: webFetchNetworkConfigurationProvider?(policyDefaults) ?? .unknown,
                configuredDomains: policyDefaults.networkDomains,
                externalNetworkAllowed: externalNetworkAllowed, routeProvider: route)
        }
        webFetchUsesPinnedApproval = pinnedConfiguration?.isAdmitted == true
        if webFetchUsesPinnedApproval {
            webFetchUnavailableReason = nil
        }
        let configuredWebFetch = webFetchUnavailableReason == nil
            ? WebFetchTransport(allowedDomains: policyDefaults.networkDomains,
                pinnedConfiguration: pinnedConfiguration) : nil
        let builtinExecutor = BuiltinToolExecutor(
            allowedRoot: allowedRootURL,
            defaultShellTimeout: agentSettings.shellCommandTimeoutSeconds,
            deniedRoots: fileAccessDeniedRoots,
            appPrivateDeniedRoots: fileAccessDefaultPrivateDataRoots,
            additionalAllowedRoots: fileAccessMountedRoots,
            localAgentSessionHome: localAgentSessionHome,
            allowsLocalAgentSessionRead: localAgentSessionHome != nil,
            mcpBridge: mcpRegistry,
            sessionManager: sessionManager,
            skillMaintenance: skillMaintenance,
            terminalPolicySnapshot: terminalPolicySnapshot,
            sessionReadKnownSecretsProvider: {
                sessionReadSecretStore.map { ChatTranscriptRedactor(store: $0).secretValues } ?? []
            },
            sessionDerivedRoot: fileAccessAllowedRoot == nil,
            webFetch: configuredWebFetch
        )
        if builtinExecutor.webFetchAvailable { builtinExecutor.registerToolNames([WebFetchToolContract.toolName]) }
        let projectSessionHandler: ProjectSessionAppHandler?
        if didAttachChatPersistence {
            if let existing = productionProjectSessionHandler {
                existing.rebindFileAccess(builtinExecutor)
                projectSessionHandler = existing
            } else {
                do {
                    projectSessionHandler = try ProjectSessionAppHandler(
                        chat: chat, sessionStore: sessionStore, taskStore: agentTaskStore,
                        workspaceBindings: projectWorkspaceBindings,
                        directory: sessionDirectory, fileAccessExecutor: builtinExecutor,
                        approval: projectSessionApproval)
                } catch {
                    projectSessionHandler = nil
                    chat.logManager.error("PROJECT_SESSION_HANDLER_INITIALIZATION_FAILED",
                        category: "ProjectSession")
                }
            }
        } else {
            projectSessionHandler = nil
            chat.logManager.info("PROJECT_SESSION_PERSISTENCE_NOT_ATTACHED", category: "ProjectSession")
        }
        if let previous = productionProjectSessionHandler, let projectSessionHandler {
            projectSessionHandler.grants.inheritSessionDirectories(from: previous.grants)
        }
        productionProjectSessionHandler = projectSessionHandler
        bindPermissionManagement()
        builtinExecutor.taskArtifactProjectResolver = { [weak projectSessionHandler] directory in
            projectSessionHandler?.taskArtifactProjectID(workingDirectory: directory)
        }
        // The settings tool is opt-in only when the existing SettingsCenter
        // belongs to this exact production session root. A different profile
        // must never provide a catalog or accept an approved effect.
        let conversationSettingsCenter = SettingsCenter.active.flatMap { center in
            Self.canonicalSessionDirectoryIdentity(center.sessionStore.directory)
                == canonicalSessionDirectory ? center : nil
        }
        let conversationSettingsToolNames: Set<String> = conversationSettingsCenter == nil
            ? [] : [BL6SettingsToolApproval.catalogToolName, BL6SettingsToolApproval.toolName]
        // The settings owner remains canonical. The executor receives a value
        // snapshot for each later request; edits never rewrite an in-flight
        // shell call already using its local snapshot.
        SettingsCenter.active?.onTerminalPolicyChanged = { [weak builtinExecutor] snapshot in
            builtinExecutor?.terminalPolicySnapshot = snapshot
        }
        // P3-P1-03(a)：登记实时句柄，让运行时提交的 agent 数值/开关经
        // refreshProductionAgentSettings 就地生效（defaultShellTimeout 为 var）。
        productionBuiltinOwnerReferences.removeAll { $0.value == nil }
        productionBuiltinOwnerReferences.append(ProductionBuiltinOwnerReference(builtinExecutor))
        productionBuiltinToolExecutor = builtinExecutor
        // P3-OUTPUT-01（DEV-297 接线）：应用层生产消费者——在既有 executor
        // 组合段把 DEV-286 落头的 FileChangeLedger 注入 builtin 执行器的两
        // 个既有 var（fileChangeLedger / fileChangeSessionID），使生产工具
        // 写路径产生逐文件变更台账（含 diffID）。台账工作区根与文件工具
        // allowedRoot 同源；会话隔离键取装配时分的活跃聊天会话 uuidString，
        // 无会话时保持空串（生产者语义：空=未接线、不登记、不猜身份）。其后
        // 会话身份变化经 performSessionAction（App 侧会话突变的统一生产入
        // 口）就地刷新。不改 MinisCore API、不加新语义、不动审批/隔离边界。
        let initialWriteRoots = (fileAccessAllowedRoot != nil || selectedWorkingDirectory != nil
            ? [allowedRootURL] : []) + fileAccessMountedRoots
        let admittedWriteRoots: @Sendable () -> [URL] = {
            AdmittedFileWorkspaceRoots.currentWriteRoots(fallback: initialWriteRoots)
        }
        builtinExecutor.fileCheckpointsEnabled = agentSettings.fileCheckpointsEnabled
        chat.fileCheckpointStore = nil
        if agentSettings.fileCheckpointsEnabled {
            if let checkpoints = try? FileCheckpointStore(
                directory: sessionDirectory.appendingPathComponent("file-checkpoints", isDirectory: true),
                allowedRoots: initialWriteRoots,
                deniedRoots: builtinExecutor.deniedRoots,
                allowedRootsProvider: admittedWriteRoots) {
                try? checkpoints.prune()
                builtinExecutor.fileCheckpointStore = checkpoints
                chat.fileCheckpointStore = checkpoints
            }
            // Enabled + missing store fails closed in the three file tools.
        }
        // Mutations and native grants use the physical path. Keep this same
        // root under /var -> /private/var aliases; no root is added.
        let fileChangeLedger = FileChangeLedger(workspaceRoot:
            allowedRootURL.resolvingSymlinksInPath().standardizedFileURL.path,
            rootsProvider: admittedWriteRoots)
        do {
            try fileChangeLedger.attachPersistence(directory: sessionDirectory
                .appendingPathComponent("file-artifact-metadata-v1", isDirectory: true),
                resolveDirectory: { directory in
                    URL(fileURLWithPath: try DarwinSystemPathResolver.resolve(directory), isDirectory: true)
                })
        } catch {
            // Preserve rejected bytes and the ordinary tool/fact authority.
            // This ledger cannot publish a recovered artifact from uncertain metadata.
            chat.logManager.error("产物引用记录无法恢复，未从工具文字重建引用。", category: "Persistence")
        }
        builtinExecutor.fileChangeLedger = fileChangeLedger
        builtinExecutor.fileChangeSessionID = chat.activeSessionID?.uuidString ?? ""
        productionFileChangeLedger = fileChangeLedger
        productionChildModelSettings = agentSettings
        productionTranscriptSecretStore = sessionReadSecretStore ?? F6EnvStoreSource.shared
        productionFallbackEnabled = agentSettings.fallbackEnabled
        // 首次组合记 initialAttach；同一进程内再次进入本缝（P3-CHILD-40 重绑、
        // 文件访问边界重建）都是运行时重建，记 compositionReattach，绝不静默。
        commitAgentSettingsReapplyReceipt(
            source: lastAgentSettingsReapplyReceipt == nil
                ? .initialAttach
                : .compositionReattach,
            settings: agentSettings
        )
        // 问题④修复：装配浏览器工具 executor —— BrowserTool 为独立 executor
        // （不进 BuiltinToolExecutor 的 switch，ToolExecutor.swift:191 按工具名分发到
        // `browser`/`browser_use`），此前未装配 → browser == nil →
        // toolNotConfigured「工具已声明但执行器未配置」，UI 浏览器工具不可用。
        // @MainActor 上下文内创建（BrowserTool.init(settings:) 是
        // @MainActor convenience init）。SettingsCenter.active is the one
        // canonical settings owner; tests without an app settings owner use
        // the safe BrowserSettings default.
        let effectiveBrowserSettings = browserSettings
            ?? SettingsCenter.active?.effectiveBrowserSettings
            ?? .default
        let browserSettingsSource = ProductionBrowserSettingsSource(
            center: browserSettings == nil ? SettingsCenter.active : nil,
            fallback: effectiveBrowserSettings
        )
        productionBrowserSettingsSource = browserSettingsSource
        // Preserve the exact GoalEnvelope network allowlist; absence remains
        // fail-closed. The tuple itself comes only from ChatStore identity.
        productionBrowserNavigationPolicy = BrowserNavigationPolicy(
            allowedDomains: policyDefaults.networkDomains
        )
        reconcileProductionBrowserSession(forceReplacement: true)
        // Speech stop/speak dispatch uses the same production builtin seam;
        // headless callers can exercise action=stop without touching audio.
        // Existing test/headless callers that omit the language keep the
        // compatibility initializer; the production composition root passes
        // SettingsCenter.language explicitly and therefore fails closed.
        // P3-SPEECH-01 wiring: the previous `try?` swallowed the throwing
        // initializer's error into a silent `nil`. A throwing speech
        // initializer fails for exactly one device-free reason at composition
        // — the language→locale mapping — so the seam now fails closed through
        // the single `SpeechCapabilityBoundary` and records that explicit,
        // presentable reason as a degradation receipt instead of disabling the
        // entry silently. A missing language keeps the headless path unchanged.
        let speechLogger = AppLogger(category: "Speech")
        let runtimeSpeechLanguage = speechGeneralLanguage.flatMap {
            try? SpeechLocaleResolver.runtimeLanguage(for: $0)
        }
        speechRuntimeLanguageForAvailability = runtimeSpeechLanguage
        speechLocaleResolvedForAvailability = speechGeneralLanguage.map { _ in
            runtimeSpeechLanguage != nil
        }
        let unresolvedLocaleReason = SpeechCapabilityBoundary.evaluate(
            SpeechCapabilityBoundary.Probe(speechLocaleResolved: false)
        ).textToSpeech.unsupportedReason ?? .speechLocaleUnresolved
        speechRecognizer = { () -> SpeechRecognizer? in
            guard let speechGeneralLanguage else { return nil }
            do {
                return try SpeechRecognizer(generalLanguage: speechGeneralLanguage)
            } catch {
                speechLogger.warning(
                    "Speech recognizer composition failed closed (\(unresolvedLocaleReason.rawValue)): \(error)"
                )
                return nil
            }
        }()
        builtinExecutor.speech = { () -> (any ToolExecutor)? in
            guard let speechGeneralLanguage else { return SpeechTool() }
            do {
                return try SpeechTool(generalLanguage: speechGeneralLanguage)
            } catch {
                speechLogger.warning(
                    "Speech tool composition failed closed (\(unresolvedLocaleReason.rawValue)): \(error)"
                )
                return nil
            }
        }()
        let projectToolNames = projectSessionHandler == nil
            ? Set<String>() : ProjectSessionToolContract.toolNames
        let policyCreatedAt = Date()
        let policyGoal = GoalEnvelope(
            scopeID: "production:agent",
            allowedCapabilities: builtinExecutor.registeredToolNames
                .union(productionChatComposition.canvasCapabilities)
                .union(effectiveEnableOrchestration ? [OrchestrationToolExecutor.toolName, OrchestrationToolExecutor.resultToolName] : [])
                .union(projectToolNames)
                .union(conversationSettingsToolNames),
            // 与 BuiltinToolExecutor 的 allowedRoot + additionalAllowedRoots 对齐，
            // 避免 policy 层误伤挂载目录（AJ-45）下的合法文件访问。
            fileRoots: (fileAccessAllowedRoot != nil || selectedWorkingDirectory != nil ? [allowedRootURL.path] : [])
                + builtinExecutor.additionalAllowedRoots.map(\.path),
            networkDomains: policyDefaults.networkDomains,
            budget: policyDefaults.budget,
            deadline: policyDefaults.deadline(from: policyCreatedAt),
            concurrencyLimit: max(1, agentSettings.concurrentToolLimit),
            autonomyLevel: policyDefaults.autonomyLevel,
            creatorID: "bridge:attachProductionServices",
            createdAt: policyCreatedAt
        )
        let policyLease = AutonomyLease(
            goalID: policyGoal.goalID,
            scopeID: policyGoal.scopeID,
            issuedAt: policyCreatedAt,
            expiresAt: policyGoal.deadline
        )
        taskCenterControlConsumer.installProductionGoal(
            goal: policyGoal,
            lease: policyLease
        )
        let childCapabilityPolicy = Self.unboundChildCapabilityPolicy
        // Both orchestration sites use the already configured retained actor.
        // A changed canonical selection updates policy through its controller
        // transaction; it cannot start a second, empty resource account.
        let childGovernor: ChildConcurrencyGovernor? = effectiveEnableOrchestration
            ? preparedChildGovernor : nil
        let resultConsumer = taskCenterControlConsumer
        let childUsageChat = chat
        let orchestrationExecutor: OrchestrationToolExecutor? = effectiveEnableOrchestration
            ? OrchestrationToolExecutor(orchestrator: AgentOrchestrator(
                defaultMaxConcurrent: canonicalChildSelection.effective,
                childConcurrencySelection: canonicalChildSelection,
                externalRunners: productionExternalRunners,
                taskStore: agentTaskStore,
                sessionStore: sharedChildSessionStore,
                capabilityPolicy: childCapabilityPolicy,
                parentCapabilities: [],
                requiresPolicyRuntime: true,
                childGovernor: childGovernor
            ), resultFactsSource: { [weak resultConsumer] envelope, parentID in
                resultConsumer?.childResultPresentationFacts(envelope: envelope, parentID: parentID)
            })
            : nil
        orchestrationTaskStore = orchestrationExecutor?.orchestrator.taskStore
        orchestrationChildGovernor = orchestrationExecutor?.orchestrator.childGovernor
        bindChildGovernorRuntimeReport(orchestrationChildGovernor)
        // Managed construction/reconfiguration has already applied the exact
        // effective stop state before any assembly side effects.
        let externalRunnerRegistry = productionExternalRunners
        let registeredBuiltinOwnerID = ObjectIdentifier(builtinExecutor)
        let registerChildRetry = taskCenterControlConsumer.makeChildRetryRegistration()
        let builtinReference = ToolExecutorReference(builtinExecutor)
        let childModelSource: @MainActor @Sendable (ParentContextSnapshotV1?) -> ChildModelRuntimeBinding? = { [weak self] parent in
            self?.prepareChildModelRuntime(parent: parent)
        }
        let childActivityObserver: @Sendable (String, Bool) async -> Void = { [weak self] id, running in
            await MainActor.run { self?.recordChildExecutionActivity(id, running: running) }
        }
        let childProjectionChanged: @Sendable () async -> Void = { [weak self] in
            await MainActor.run { self?.chat.invalidateTaskCenterPresentation() }
        }
        @Sendable func makeBoundChildOrchestrator(
            _ context: AgentExecutionContextSnapshot, _ goal: GoalEnvelope,
            _ taskOwner: BuiltinToolExecutor, _ executorReference: ToolExecutorReference,
            _ inheritedLease: AutonomyLease?, _ inheritedOriginalRoots: [String],
            _ inheritedDirectorySnapshot: [ProjectSessionGrantRegistry.DirectoryGrant]
        ) async throws -> AgentOrchestrator {
            guard let childModels = await childModelSource(context.parentBinding) else {
                throw ChildModelBindingError.parentUnavailable
            }
            let resolveChildProvider: (@Sendable (SubAgentTask, any LLMProvider) throws -> any LLMProvider)?
            let prepareChildProvider: (@Sendable (SubAgentTask, any LLMProvider) async throws -> Void)?
            if childModels.policy.allowsOverrides {
                resolveChildProvider = { @Sendable task, inherited in
                    try childModels.resolve(task, inherited: inherited)
                }
                prepareChildProvider = { @Sendable task, inherited in
                    try await childModels.prepare(task, inherited: inherited)
                }
            } else {
                resolveChildProvider = nil
                prepareChildProvider = nil
            }
            // Use the owner of the actual forwarding chain. A replacement
            // cannot inherit the registered owner's immutable file ceiling.
            let currentExecutor = executorReference.value
            let currentOwner = (currentExecutor as? any BuiltinOwnerBoundToolExecutor)?.currentBuiltinOwner
            let boundOwner = currentOwner.flatMap { $0 === taskOwner ? $0 : nil }
            // Inherit only tools actually offered on this trusted parent turn.
            // Concrete Builtin dispatch still validates registration and PolicyRuntime.
            let inheritedPolicy = Self.inheritedChildCapabilityPolicy(
                offeredToolNames: context.offeredToolNames ?? [], builtinOwner: boundOwner)
            let childApprovalGate = context.approvalGate?.restoringOrdinaryChildPolicy()
            var orchestrator = AgentOrchestrator(
                defaultMaxConcurrent: canonicalChildSelection.effective,
                childConcurrencySelection: canonicalChildSelection,
                provider: context.provider,
                toolExecutor: currentExecutor,
                externalRunners: externalRunnerRegistry,
                approvalGate: childApprovalGate,
                turnController: context.turnController,
                makeChildBudget: context.makeChildBudget,
                boundParentRequestBudget: context.makeChildBudget?(),
                childTimeout: context.deadline.map { max(0, $0.timeIntervalSinceNow) },
                deadline: context.deadline,
                currentConversationID: context.currentConversationID,
                resolveChildProvider: resolveChildProvider,
                prepareChildProvider: prepareChildProvider,
                taskStore: context.taskStore,
                sessionStore: sharedChildSessionStore,
                toolExecutionFactLedger: context.toolExecutionFactLedger,
                parentID: context.currentConversationID,
                parentBinding: context.parentBinding,
                parentRuntimeIdentity: context.parentRuntimeIdentity,
                parentGoal: goal,
                parentTurnHandle: context.parentTurnHandle,
                runtimeMode: .production,
                capabilityPolicy: inheritedPolicy,
                parentCapabilities: context.provider.capabilities,
                parentFileAccessCeiling: ChildParentFileAccessCeiling(executor: taskOwner),
                parentWorkingDirectory: context.composerPolicyFacts.flatMap {
                    $0.allowedWriteRoots.count == 1 ? $0.allowedWriteRoots.first : nil
                } ?? boundOwner?.effectiveWorkingDirectory.path,
                childMutationsEnabled: context.childMutationsEnabled,
                childExecutionActivityObserver: childActivityObserver,
                childTaskProjectionChanged: childProjectionChanged,
                prepareChildIsolation: { task in
                    guard let snapshot = context.composerSnapshot, let facts = context.composerPolicyFacts,
                          let parent = context.parentBinding, let inheritedLease,
                          let executionID = task.executionID,
                          let uuidText = executionID.split(separator: ":").last,
                          let uuid = UUID(uuidString: String(uuidText)),
                          task.parentContextSnapshotID == parent.snapshotID,
                          let originalGate = childApprovalGate,
                          let nestedShell = context.nestedShellExecutor,
                          ![ApprovalPolicy.deny, .never].contains(originalGate.policy(for: "shell_execute")),
                          goal.deadline > Date(), inheritedLease.expiresAt > Date(), !inheritedLease.revoked else {
                        throw ToolExecutorError.toolNotConfigured("child_worktree_isolation")
                    }
                    let parentDirectory = taskOwner.effectiveWorkingDirectory.path
                    guard PolicyRuntimePathBoundary.isWithinRoots(path: parentDirectory, roots: goal.fileRoots) else {
                        throw ToolExecutorError.pathViolation(parentDirectory)
                    }
                    let assertCurrentParent: @Sendable () async throws -> Void = { [weak self] in
                        try Task.checkCancellation()
                        guard await context.parentAuthorityCheck?() != false else { throw CancellationError() }
                        try await MainActor.run {
                            guard let self, self.chat.activeSessionID?.uuidString == snapshot.sessionID,
                                  self.chat.composerPolicyFacts == facts,
                                  self.productionBuiltinToolExecutor.map({ ObjectIdentifier($0) }) == registeredBuiltinOwnerID,
                                  !self.productionAttachmentAdmissionSuspended,
                                  !facts.revoked, facts.expiresAt > Date(),
                                  inheritedLease.expiresAt > Date(), goal.deadline > Date() else {
                                throw ToolExecutorError.invalidParameter("child_isolation_parent_changed")
                            }
                        }
                    }
                    try await assertCurrentParent()
                    let (managedRoot, isDisposable) = try await MainActor.run { [weak self] in
                        guard let provider = self?.childWorktreeRootProvider else {
                            throw ToolExecutorError.toolNotConfigured("child_worktree_profile")
                        }
                        return try provider()
                    }
                    let identity = GitChildWorktreeIdentity(taskID: task.id, executionID: uuid,
                        parentSessionID: snapshot.sessionID, parentContextSnapshotID: parent.snapshotID)
                    let plan = try GitChildWorktreeService.prepare(approvedProjectDirectory: parentDirectory,
                        identity: identity, managedRoot: managedRoot)
                    // Check prospective physical containment before any Git
                    // effect; the ordinary new-root validator repeats it after
                    // the checkout actually exists. No private-floor exception.
                    guard Self.admitsProspectiveChildWorktreePath(
                        plan.path, deniedRoots: taskOwner.deniedRoots, isDisposable: isDisposable
                    ) else {
                        throw ToolExecutorError.pathViolation(plan.path)
                    }
                    @Sendable func authorization(_ input: [String: Any], tool: String, id: String) throws -> ApprovalAuthorizationContext {
                        guard let digest = ApprovalAuthorizationContext.payloadDigest(for: input) else {
                            throw ToolExecutorError.invalidParameter("child_isolation_approval")
                        }
                        return ApprovalAuthorizationContext(actorID: "app-child-worktree",
                            sessionID: snapshot.sessionID, turnID: snapshot.turnID, taskID: task.id,
                            runID: executionID, attemptID: id, effectID: id, scope: "request",
                            payloadDigest: digest, expiresAt: min(facts.expiresAt, inheritedLease.expiresAt),
                            policyRevision: facts.revision, grantEpoch: facts.grantEpoch, toolName: tool)
                    }
                    var allocationGate = originalGate
                    allocationGate.policyByTool["child_worktree_allocate"] = .alwaysAsk
                    let allocationInput: [String: Any] = ["repository": parentDirectory,
                        "path": plan.path, "branch": "minis/child-" + uuid.uuidString.lowercased(),
                        "task_id": task.id, "execution_id": executionID]
                    _ = try await allocationGate.gate(tool: "child_worktree_allocate", input: allocationInput,
                        context: authorization(allocationInput, tool: "child_worktree_allocate", id: UUID().uuidString))
                    try await assertCurrentParent()
                    let executeApproved: GitWorkflowService.CommandExecutor = { command, cwd in
                        try await assertCurrentParent()
                        // Keep the approved parent cwd during checkout creation
                        // and inspection. -C is trusted output of Git's service,
                        // not a model-selected directory or shell fragment.
                        let quoted = "'" + cwd.replacingOccurrences(of: "'", with: "'\\''") + "'"
                        let isParentDirectory = Self.matchesChildWorktreePath(
                            cwd, parentDirectory, isDisposable: isDisposable
                        )
                        let actualCommand = isParentDirectory ? command : "git -C " + quoted + " " + String(command.dropFirst(4))
                        guard isParentDirectory || (cwd == plan.path && command == "git rev-parse --show-toplevel") else {
                            throw ToolExecutorError.invalidParameter("child_isolation_git_command")
                        }
                        let input: [String: Any] = ["command": actualCommand, "cwd": parentDirectory]
                        let callID = UUID().uuidString
                        // This is the actual outer Composer captured by the
                        // live AgentLoop. It owns independent call approval,
                        // durable receipt mint/settle and the original chain.
                        let raw = try await nestedShell.executeNestedShell(callID: callID, input: input)
                        return try await Self.worktreeGitCommandResult(raw)
                    }
                    let allocation = try await GitChildWorktreeService.create(approvedProjectDirectory: parentDirectory,
                        identity: identity, managedRoot: managedRoot, executeApproved: executeApproved)
                    try await assertCurrentParent()
                    let directory = try taskOwner.validatedApprovedSessionDirectory(allocation.workingDirectory)
                    _ = try await Self.additionalDirectoryIdentity(directory)
                    let isolatedOwner = try taskOwner.copyingAddingAdditionalAllowedRoots([directory])
                    let isolatedGoal = GoalEnvelope(goalID: goal.goalID, scopeID: goal.scopeID,
                        allowedCapabilities: goal.allowedCapabilities, fileRoots: [directory.path],
                        networkDomains: goal.networkDomains, budget: goal.budget, deadline: goal.deadline,
                        concurrencyLimit: goal.concurrencyLimit, autonomyLevel: goal.autonomyLevel,
                        creatorID: goal.creatorID, createdAt: goal.createdAt)
                    let isolatedFacts = ComposerPolicyFactSource(knownCapabilities: facts.knownCapabilities,
                        grantedCapabilities: facts.grantedCapabilities, capabilityGrantBindings: facts.capabilityGrantBindings,
                        allowedWriteRoots: [directory.path], workspaceID: facts.workspaceID,
                        revision: facts.revision, grantEpoch: facts.grantEpoch, leaseID: facts.leaseID,
                        expiresAt: facts.expiresAt, revoked: facts.revoked, autonomyCeiling: facts.autonomyCeiling)
                    let isolatedExecutor = await MainActor.run {
                        let sourceID = context.childToolRuntimeBinding?.parent.sessionID ?? context.parentRuntimeIdentity?.sessionID
                        return self.makePolicyWrappedExecutor(
                            goal: isolatedGoal, lease: inheritedLease, owner: isolatedOwner,
                            orchestrationExecutor: orchestrationExecutor,
                            projectSessionHandler: projectSessionHandler,
                            conversationSettingsCenter: conversationSettingsCenter,
                            canonicalSessionDirectory: canonicalSessionDirectory,
                            registeredBuiltinOwnerID: registeredBuiltinOwnerID,
                            sessionReadSecretStore: sessionReadSecretStore,
                            makeBoundChildOrchestrator: makeBoundChildOrchestrator,
                            sourceSessionID: sourceID,
                            originalRootCeiling: inheritedOriginalRoots,
                            inheritedDirectorySnapshot: inheritedDirectorySnapshot)
                    }
                    // Retain the actual original policy lease and outer
                    // Composer, not a replacement controller or raw-path grant.
                    let parentPolicy = (currentExecutor as? RecordingToolExecutor)?.base as? PolicyEnforcedToolExecutor
                    let parentComposer = context.nestedShellExecutor as? ComposerPolicyEnforcedToolExecutor
                    let assertCleanupParent: @Sendable () async throws -> Void = { [weak self] in
                        try Task.checkCancellation()
                        guard let parentPolicy, let liveLease = parentPolicy.currentLease,
                              liveLease.leaseID == inheritedLease.leaseID,
                              liveLease.goalID == goal.goalID, liveLease.scopeID == goal.scopeID,
                              !liveLease.revoked, liveLease.expiresAt > Date(), goal.deadline > Date() else {
                            throw ToolExecutorError.invalidParameter("child_cleanup_parent_lease_changed")
                        }
                        try await MainActor.run {
                            guard let self else { throw CancellationError() }
                            let currentFacts = self.chat.composerPolicyFacts
                            guard self.chat.activeSessionID?.uuidString == snapshot.sessionID,
                                  currentFacts.workspaceID == facts.workspaceID,
                                  currentFacts.revision == facts.revision,
                                  currentFacts.grantEpoch == facts.grantEpoch,
                                  currentFacts.allowedWriteRoots == facts.allowedWriteRoots,
                                  currentFacts.grantedCapabilities.contains("shell_execute"),
                                  !currentFacts.revoked, currentFacts.expiresAt > Date(),
                                  self.productionBuiltinToolExecutor.map({ ObjectIdentifier($0) }) == registeredBuiltinOwnerID,
                                  !self.productionAttachmentAdmissionSuspended else {
                                throw ToolExecutorError.invalidParameter("child_cleanup_parent_authority_changed")
                            }
                        }
                    }
                    let scope = try ChildWorktreeExecutionScope(allocation: allocation, task: task,
                        owner: isolatedOwner, executor: isolatedExecutor, goal: isolatedGoal,
                        lease: inheritedLease, facts: isolatedFacts,
                        cleanupParentAuthority: assertCleanupParent)
                    let readOnly = Self.makeCleanupReadOnlyExecutor(
                        allocation: allocation, parentDirectory: parentDirectory,
                        parentComposer: parentComposer, parentContext: context,
                        parentSessionID: snapshot.sessionID, assertParent: assertCleanupParent)
                    let cleanupController = try await MainActor.run { [weak self] in
                        guard let self else { throw CancellationError() }
                        return self.p03CleanupAppController
                    }
                    try await cleanupController.register(P03CleanupAppResource(
                        source: scope, managedRoot: managedRoot, readOnly: readOnly))
                    return scope
                },
                parentComposerSnapshot: context.composerSnapshot,
                parentComposerFacts: context.composerPolicyFacts,
                parentAuthorityCheck: context.parentAuthorityCheck,
                concreteBuiltinToolExecutorOwner: boundOwner,
                requiresPolicyRuntime: true,
                childGovernor: childGovernor
            ).withChildRetryRegistration(registerChildRetry)
            orchestrator.childModelPolicy = childModels.policy
            orchestrator.childTokenUsageSource = { [weak childUsageChat] locator in
                guard let usage = await MainActor.run(body: { childUsageChat?.usageStore }) else { return nil }
                return await usage.childTokenUsage(for: locator)
            }
            return orchestrator
        }
        let makePolicyWrappedExecutor: @MainActor @Sendable (
            GoalEnvelope, AutonomyLease, BuiltinToolExecutor, UUID?, [String]
        ) -> any ToolExecutor = { goal, lease, owner, sourceSessionID, originalRoots in
            self.makePolicyWrappedExecutor(
                goal: goal, lease: lease, owner: owner,
                orchestrationExecutor: orchestrationExecutor,
                projectSessionHandler: projectSessionHandler,
                conversationSettingsCenter: conversationSettingsCenter,
                canonicalSessionDirectory: canonicalSessionDirectory,
                registeredBuiltinOwnerID: registeredBuiltinOwnerID,
                sessionReadSecretStore: sessionReadSecretStore,
                makeBoundChildOrchestrator: makeBoundChildOrchestrator,
                sourceSessionID: sourceSessionID?.uuidString, originalRootCeiling: originalRoots)
        }
        if orchestrationExecutor == nil {
            taskCenterRetryOrchestratorFactory = nil
        } else {
            let retryFactory: @Sendable (AgentExecutionContextSnapshot, GoalEnvelope) async throws -> AgentOrchestrator = { context, goal in
                try await makeBoundChildOrchestrator(context, goal, builtinExecutor, builtinReference, nil, [], [])
            }
            taskCenterRetryOrchestratorFactory = retryFactory
        }
        let recordingExecutor = makePolicyWrappedExecutor(
            policyGoal, policyLease, builtinExecutor, nil, []
        )
        builtinReference.value = recordingExecutor
        let manualApprovalDelegate = ApprovalDecisionStatusObservingDelegate(
            base: approvalDelegateOverride ?? ApprovalPromptDelegate(center: approvalCenter),
            ledger: chat.approvalDecisionLedger)
        let deletionClassifier = ReadinessBoundIndependentDeletionClassifier { @MainActor [weak self] expected in
            guard let self,
                  let frozen = try self.chat.frozenSelectedProviderConstruction(),
                  frozen.providerID.caseInsensitiveCompare(expected.providerID) == .orderedSame,
                  self.productionExternalNetworkAllowed
                    || DeepSeekEnvironmentPackageFieldBootstrap.admitsJourneyProvider(
                        configured: self.chat.isolatedDeepSeekJourneyConfigured,
                        providerName: frozen.providerID,
                        baseURL: frozen.construction.config.effectiveCustomBaseURL) else {
                throw ReadinessBoundIndependentDeletionClassifier.Failure.unavailable
            }
            // Construct a new provider from the existing admitted selection.
            // Never lend the parent provider, conversation history, or tools.
            return frozen.construction
        }
        let approvalDelegate = ChildDeletionApprovalDelegate(manualDelegate: manualApprovalDelegate,
            reviewer: ChildDeletionReviewer(configuration: childDeletionReviewConfiguration,
                classifier: deletionClassifier, recordSink: ChildDeletionReviewer.durableCheckpointRecordSink))
        productionApprovalDelegate = approvalDelegate
        // Durable "allow from now on" rules live beside the other MinisCore
        // state of the active profile; a corrupt file loads as no rules.
        let persistentRules = chat.composerGrantStore.persistentRules
        if !persistentRules.isAttached {
            persistentRules.attach(fileURL: sessionDocuments.directory
                .deletingLastPathComponent()
                .appendingPathComponent("MinisCore", isDirectory: true)
                .appendingPathComponent("persistent-approval-rules-v1.json"))
        }
        approvalCenter.persistentRules = persistentRules
        approvalCenter.skillRuleFactsProvider = { [weak chat = chat] in chat?.composerPolicyFacts }
        browserInteractionRules.attach(fileURL: sessionDocuments.directory
            .deletingLastPathComponent()
            .appendingPathComponent("MinisCore", isDirectory: true)
            .appendingPathComponent("browser-interaction-rules-v1.json"))
        approvalCenter.browserInteractionRules = browserInteractionRules
        productionConversationSettingsAvailable = conversationSettingsCenter != nil
        legacyAutomaticApprovalCompatibilityActive = agentSettings.legacyAutomaticApprovalCompatibilityActive
            && agentSettings.approvalPolicy == .riskOnlyAsk
        let productionApprovalGate = makeProductionApprovalGate(policy: agentSettings.approvalPolicy)
        let composerCanvasCapabilities = canvasFeatureLane == .phase4OptIn
            ? productionChatComposition.canvasCapabilities
            : []
        let composerCapabilities = builtinExecutor.registeredToolNames
            .union([AskUserQuestionTool.toolName])
            .union(composerCanvasCapabilities)
            .union(effectiveEnableOrchestration ? [OrchestrationToolExecutor.toolName, OrchestrationToolExecutor.resultToolName] : [])
            .union(projectToolNames)
            .union(conversationSettingsToolNames)
        let composerFacts = ComposerPolicyFactSource(
            knownCapabilities: composerCapabilities,
            grantedCapabilities: composerCapabilities,
            allowedWriteRoots: policyGoal.fileRoots,
            workspaceID: chat.composerWorkspaceID,
            revision: "composer:\(policyGoal.goalID.uuidString)",
            grantEpoch: "composer-epoch:\(policyGoal.goalID.uuidString)",
            leaseID: "composer-lease:\(policyGoal.goalID.uuidString)",
            expiresAt: policyGoal.deadline,
            autonomyCeiling: policyGoal.autonomyLevel
        )
        chat.configureComposerPolicy(composerFacts, productionRebind: (
            approval: agentSettings.approvalPolicy, toolPolicies: productionApprovalGate.policyByTool,
            terminalPolicy: productionApprovalGate.terminalPolicySnapshot, defaults: policyDefaults,
            deniedRoots: builtinExecutor.deniedRoots, externalNetworkAllowed: productionExternalNetworkAllowed,
            controlledFieldLoopbackAllowed: productionControlledFieldLoopbackAllowed,
            safetyGeneration: safetyRuntimeGeneration
        ))
        if canvasFeatureLane == .phase4OptIn,
           let canvasMutationCoordinator = canvasMutationCoordinatorStorage {
            let canvasApprovalGate = productionApprovalGate
            composerApprovalGate = canvasApprovalGate
            canvasMutationCoordinator.configure(
                facts: composerFacts,
                grants: chat.composerGrantStore,
                approvalGate: canvasApprovalGate,
                snapshotFactory: { [weak self] request, input in
                    self?.makeCanvasMutationSnapshot(request: request, input: input)
                        ?? ComposerSubmissionSnapshot(
                            mode: .manual,
                            approvalScope: .request,
                            effort: .standard,
                            sessionID: "canvas-session",
                            turnID: 0,
                            taskID: "canvas:\(request.id.uuidString)",
                            attemptID: request.id.uuidString,
                            messageID: request.id.uuidString,
                            inputDigest: input.digest,
                            workspaceID: "unconfigured",
                            createdAt: Date(),
                            policyRevision: "",
                            grantEpoch: ""
                        )
                }
            )
            composerCanvasPolicyBase = PolicyEnforcedToolExecutor(
                base: ComposerCanvasCommandExecutor(bridge: self),
                goal: policyGoal,
                lease: AutonomyLease(
                    goalID: policyGoal.goalID,
                    scopeID: policyGoal.scopeID,
                    issuedAt: policyCreatedAt,
                    expiresAt: policyGoal.deadline
                ),
                requestBuilder: PolicyEnforcedToolExecutor.productionRequestBuilder
            )
        } else {
            composerApprovalGate = nil
            composerCanvasPolicyBase = nil
        }
        // Bind the final wrapper so child agents inherit policy, approval,
        // recording, and cancellation instead of reaching raw builtin tools.
        let retainedContextGate = productionContextLifecycleBinding.flatMap { binding in
            binding.directoryIdentity == canonicalSessionDirectory ? binding.gate : nil
        }
        let orchestrationDefinitionSource: (@Sendable () async throws -> AgentToolDefinition)?
        if orchestrationExecutor != nil {
            orchestrationDefinitionSource = { @Sendable in
                guard let models = await childModelSource(nil) else {
                    return OrchestrationToolExecutor.makeDefinition()
                }
                return OrchestrationToolExecutor.makeDefinition(childModelPolicy: models.policy)
            }
        } else {
            orchestrationDefinitionSource = nil
        }
        let engine = AgentLoopChatEngine(
            toolExecutor: recordingExecutor,
            maxIterations: agentSettings.maxLoopIterations,
            requestBudget: chat.budgetTracker,
            concurrentToolLimit: agentSettings.concurrentToolLimit,
            toolTimeoutSeconds: agentSettings.toolTimeoutSeconds,
            fallbackEnabled: agentSettings.fallbackEnabled,
            providerRuntimeRouteBuilder: makeProviderRuntimeRouteBuilder(),
            mcpBridge: mcpRegistry,
            orchestrationDefinition: orchestrationExecutor.map { _ in OrchestrationToolExecutor.makeDefinition() },
            orchestrationDefinitionSource: orchestrationDefinitionSource,
            browserWriteActionsVisibleSource: { [weak self] in
                await MainActor.run {
                    self?.productionBrowserTool?.writeActionsVisible ?? false
                }
            },
            projectSessionDefinitions: projectSessionHandler == nil
                ? nil : ProjectSessionToolContract.definitions,
            conversationSettingsAvailable: conversationSettingsCenter != nil,
            userQuestions: chat.userQuestions,
            approvalGate: productionApprovalGate,
            taskStore: agentTaskStore,
            contextManifestStore: contextManifestStore,
            chatRuntimeDependencies: AgentLoopChatEngine.ChatSessionRuntimeDependencies(
                sessionStore: sessionStore,
                memoryStore: commandMemoryStore,
                skillStore: productionSkillStore,
                skillMaintenance: skillMaintenance,
                liveSkillBypassConfirmed: { [weak chat] in
                    await MainActor.run {
                        guard let chat else { return false }
                        let selection = chat.composerPolicySelection
                        return selection.mode == .bypassPermission && selection.bypassModeConfirmed
                            && !chat.composerBypassDisabled
                    }
                },
                soulStore: productionSoulStore
            ),
            contextWritebackGate: retainedContextGate,
            contextWritebackStorePersistenceURL: sessionDirectory
                .appendingPathComponent("agent-turn-context-v1.json"),
            composerPolicyFacts: composerFacts,
            composerGrantStore: chat.composerGrantStore,
            onComposerApprovalReceipt: { [weak self] receipt in
                Task { @MainActor [weak self] in
                    self?.composerApprovalReceipts.append(receipt)
                }
            }
        ).withChildMutationsEnabled(agentSettings.childMutationsEnabled)
            .withOwnedOutputReadResolver { [owner = ToolExecutorBox(value: builtinExecutor)] path in
                guard let builtin = owner.value as? BuiltinToolExecutor else { return nil }
                return try builtin.resolveOwnedOutputArtifactRead(path: path)
            }
            .withGitWriteSummaryProvider { [owner = ToolExecutorBox(value: builtinExecutor)] input, snapshot in
                guard let builtin = owner.value as? BuiltinToolExecutor else {
                    throw ToolExecutorError.toolNotConfigured("shell_execute")
                }
                return try await builtin.prepareGitWriteSummary(input.toolExecutionDictionary, policySnapshot: snapshot)
            }
        if productionContextLifecycleBinding == nil,
           didAttachChatPersistence,
           productionSessionDirectoryIdentity == canonicalSessionDirectory,
           engine.contextRecoveryFailure == nil,
           engine.contextWritebackGate.lifecycleStore != nil {
            productionContextLifecycleBinding = (canonicalSessionDirectory, engine.contextWritebackGate)
        }
        // F3 停止闭环：停止按钮 → ChatStore.stopStreaming → 挂起审批按拒绝处理
        // （恢复 continuation），防「停止后再点允许」工具照样执行。
        Self.bindApprovalStopLifecycle(chat: chat, approvalCenter: approvalCenter)
        chat.attachAgentTaskStore(agentTaskStore)
        chat.agentEngine = engine
        Task { @MainActor [weak self, weak builtinExecutor] in
            guard let self, let builtinExecutor,
                  self.productionBuiltinToolExecutor === builtinExecutor else { return }
            await self.chat.reconcileRecoveredFileWrites(
                using: builtinExecutor,
                ledger: engine.toolExecutionFactLedger
            )
        }
        let taskPolicyCompositionGeneration = productionAttachmentGeneration
        chat.prepareTopLevelTaskPolicy = { [weak self] taskID, createdAt, projectTargetID, projectTask in
            guard let self,
                  self.productionAttachmentGeneration == taskPolicyCompositionGeneration,
                  !self.productionAttachmentAdmissionSuspended,
                  self.isProductionSessionDirectoryCurrent(sessionDirectory),
                  let currentEngine = self.chat.agentEngine as? AgentLoopChatEngine,
                  !self.chat.composerPolicyFacts.revoked,
                  self.chat.composerPolicyFacts.revision != "unconfigured",
                  self.chat.composerPolicyFacts.workspaceID == self.chat.composerWorkspaceID
            else { return false }
            let currentFacts = self.chat.composerPolicyFacts
            let taskSessionID = projectTargetID ?? self.chat.activeSessionID
            let projectDirectory: URL?
            let taskScopeID: String
            let trustedProjectRoot: String?
            if let projectTargetID {
                guard let binding = self.projectWorkspaceBindings.lookup(sessionID: projectTargetID.uuidString).binding,
                      binding.targetSessionID == projectTargetID.uuidString, binding.taskID == taskID,
                      projectSessionHandler?.isWorkspaceAuthorized(binding) == true else { return false }
                // The live native grant and canonical target/task/run binding
                // are authority. A working-directory string alone is not.
                projectDirectory = URL(fileURLWithPath: binding.workingDirectory, isDirectory: true)
                taskScopeID = binding.projectID
                if let projectDirectory, case .resolved(let path) = DarwinSystemPathResolver.resolveOutcome(projectDirectory) {
                    trustedProjectRoot = path
                } else {
                    trustedProjectRoot = nil
                }
            } else {
                projectDirectory = taskSessionID.flatMap { id in
                    self.chat.sessions.first(where: { $0.id == id })?.workingDirectory
                }.map { URL(fileURLWithPath: $0, isDirectory: true) }
                taskScopeID = policyGoal.scopeID
                trustedProjectRoot = taskSessionID.flatMap { id in
                    guard let projectID = self.chat.sessions.first(where: { $0.id == id })?.projectID else { return nil }
                    return self.chat.trustedProjectRootProvider?(
                        MemoryScope(sessionID: id.uuidString, projectID: projectID)
                    )?.path
                }
            }
            let selectedDirectory = SessionFileRootPolicy.root(
                explicit: projectDirectory == nil ? fileAccessAllowedRoot : nil,
                workingDirectory: projectDirectory?.path,
                sessionDirectory: sessionDirectory, sessionID: taskSessionID)
            // The configured root is a safety ceiling, not a project default.
            // Canonicalize and validate before minting the task Goal/lease.
            let directory = selectedDirectory.resolvingSymlinksInPath().standardizedFileURL
            let taskOwner: BuiltinToolExecutor
            do {
                let approved = try self.additionalDirectories(for: taskSessionID, owner: builtinExecutor)
                taskOwner = try Self.additionalDirectoryOwner(base: builtinExecutor, approved: approved)
            } catch {
                self.chat.reportTaskPolicyPreparationFailure("额外目录授权已变化：\(error.localizedDescription)。请重新批准目录后再发送。")
                return false
            }
            self.productionBuiltinOwnerReferences.removeAll { $0.value == nil }
            if !self.productionBuiltinOwnerReferences.contains(where: { $0.value === taskOwner }) {
                self.productionBuiltinOwnerReferences.append(ProductionBuiltinOwnerReference(taskOwner))
            }
            let scopedEngine: AgentLoopChatEngine
            if !projectTask, projectDirectory == nil, fileAccessAllowedRoot == nil {
                scopedEngine = currentEngine.clearingToolWorkspace(terminalPolicySnapshot: builtinExecutor.terminalPolicySnapshot)
            } else {
                do {
                    scopedEngine = try currentEngine.capturingToolWorkspace(
                        directory: directory, owner: taskOwner, projectScoped: projectDirectory != nil,
                        projectTask: projectTask)
                } catch {
                    self.chat.reportTaskPolicyPreparationFailure("任务目录授权不可用：\(error.localizedDescription)。请检查当前项目与目录。")
                    return false
                }
            }
            let selectedRoots = projectDirectory == nil
                ? (fileAccessAllowedRoot == nil ? [] : [allowedRootURL.path]) : [directory.path]
            let taskFileRoots = (selectedRoots + taskOwner.additionalAllowedRoots.map {
                $0.resolvingSymlinksInPath().standardizedFileURL.path
            }).reduce(into: [String]()) { roots, path in
                if !roots.contains(path) { roots.append(path) }
            }
            let goal = GoalEnvelope(
                scopeID: taskScopeID,
                allowedCapabilities: policyGoal.allowedCapabilities,
                fileRoots: taskFileRoots,
                networkDomains: policyGoal.networkDomains,
                budget: policyGoal.budget,
                deadline: policyDefaults.deadline(from: createdAt),
                concurrencyLimit: policyGoal.concurrencyLimit,
                autonomyLevel: policyGoal.autonomyLevel,
                creatorID: "bridge:topLevelTask",
                createdAt: createdAt
            )
            let lease = AutonomyLease(
                goalID: goal.goalID, scopeID: goal.scopeID,
                issuedAt: createdAt, expiresAt: goal.deadline
            )
            guard self.taskCenterControlConsumer.installTopLevelTaskGoal(
                taskID: taskID, goal: goal, lease: lease
            ) else { return false }
            let facts = ComposerPolicyFactSource(
                knownCapabilities: currentFacts.knownCapabilities,
                grantedCapabilities: currentFacts.grantedCapabilities,
                capabilityGrantBindings: currentFacts.capabilityGrantBindings,
                allowedWriteRoots: goal.fileRoots,
                workspaceID: currentFacts.workspaceID,
                // The settings revision is stable across tasks, so an
                // authorized scheduled occurrence still matches its durable
                // policy fence. The grant epoch and lease are task-unique.
                revision: currentFacts.revision,
                grantEpoch: "composer-epoch:\(goal.goalID.uuidString)",
                leaseID: "composer-lease:\(goal.goalID.uuidString)",
                expiresAt: goal.deadline,
                autonomyCeiling: goal.autonomyLevel,
                trustedProjectRoot: trustedProjectRoot
            )
            let executor = makePolicyWrappedExecutor(goal, lease, taskOwner, taskSessionID,
                selectedRoots + builtinExecutor.additionalAllowedRoots.map { $0.resolvingSymlinksInPath().path })
            var taskEngine = scopedEngine
            if projectTask, self.legacyAutomaticApprovalCompatibilityActive {
                taskEngine.loop.approvalGate = taskEngine.loop.approvalGate?.applyingLegacyUnattendedAutoApproval()
            }
            let preparedEngine = taskEngine.withTopLevelTaskPolicy(executor: executor, facts: facts)
                .withOwnedOutputReadResolver { [owner = ToolExecutorBox(value: taskOwner)] path in
                    guard let builtin = owner.value as? BuiltinToolExecutor else { return nil }
                    return try builtin.resolveOwnedOutputArtifactRead(path: path)
                }
                .withGitWriteSummaryProvider { [owner = ToolExecutorBox(value: taskOwner)] input, snapshot in
                    guard let builtin = owner.value as? BuiltinToolExecutor else {
                        throw ToolExecutorError.toolNotConfigured("shell_execute")
                    }
                    return try await builtin.prepareGitWriteSummary(input.toolExecutionDictionary, policySnapshot: snapshot)
                }
            if projectTask {
                self.chat.stagePreparedTopLevelTaskEngine(preparedEngine, taskID: taskID)
            } else {
                self.chat.agentEngine = preparedEngine
                self.chat.configureComposerPolicy(facts)
            }
            return true
        }

        taskCenterControlConsumer.bindFileArtifacts(
            ledger: fileChangeLedger, facts: engine.toolExecutionFactLedger,
            targetValidator: builtinExecutor.fileArtifactTargetValidator(),
            projectValidator: { [weak projectSessionHandler] projectID, directory in
                projectSessionHandler?.isTaskFileProjectAuthorized(projectID: projectID, workingDirectory: directory) == true
            }
        )

        // 2) 会话持久化（B1d）：JSON 文件落在 Application Support/MinisCanvas
        chat.projectSessionHandler = projectSessionHandler
        chat.trustedProjectRootProvider = { [weak chat = self.chat, weak projectSessionHandler] scope in
            guard scope.isValid, let chat,
                  let thread = chat.sessions.first(where: {
                      $0.id.uuidString == scope.sessionID && $0.projectID == scope.projectID
                  }),
                  let directory = thread.workingDirectory,
                  projectSessionHandler?.isTaskFileProjectAuthorized(projectID: scope.projectID, workingDirectory: directory) == true
            else { return nil }
            // Authorization above is still checked against the live grant.
            // Only Darwin's existing system-alias allowlist changes spelling;
            // Core's descriptor walk continues to reject every other symlink.
            guard case .resolved(let physicalPath) = DarwinSystemPathResolver.resolveOutcome(
                URL(fileURLWithPath: directory, isDirectory: true)) else { return nil }
            return URL(fileURLWithPath: physicalPath, isDirectory: true)
        }
        approvalCenter.gitStatusProjectNameProvider = { [weak self] sessionID, ruleRoot in
            guard let self, let thread = chat.sessions.first(where: { $0.id.uuidString == sessionID }),
                  let projectID = thread.projectID,
                  let directory = chat.trustedProjectRootProvider?(
                    MemoryScope(sessionID: sessionID, projectID: projectID)
                  ),
                  let scope = PersistentApprovalRuleMatcher.projectScope(roots: [directory.path]),
                  scope.roots == [ruleRoot] else { return nil }
            let name = directory.lastPathComponent
            guard !name.contains("/"), !name.contains("\\"),
                  !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            else { return nil }
            let safeName = String((productionTranscriptRedactor?.redact(name)
                ?? ProductRedactionPolicy.redact(name, maxLength: 80)).prefix(80))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return safeName.isEmpty ? nil : safeName
        }
        chat.projectInstructionApproval = { [weak projectSessionHandler] scope, snapshot, allowPrompt, isCurrent, modalPhase in
            projectSessionHandler?.admitProjectInstructions(snapshot, scope: scope,
                allowPrompt: allowPrompt, isCurrent: isCurrent, modalPhase: modalPhase) == true
        }
        projectSessionHandler?.reconcileRecoveredReservations()
        // P3-OUTPUT-01（DEV-305 接线，裁 DEV-304 GAP 方案 1）：删除/归档等
        // 会话集合旁路突变（ChatStore :2019/:2758 等触发点）不经
        // performSessionAction 统一刷新缝（:1029-1030），使生产执行器的
        // 台账会话键滞留已删除/归档的旧会话。attachPersistence 每次把
        // onSessionsChanged 重绑为 persistSessions（ChatStore :5235），故包装
        // 置于其调用之后：先执行原闭包，再与 :1029-1030 同源同形表达式刷新
        // （幂等无副作用的读取赋值；无活跃会话→空串=未接线、不登记语义）。
        // 不改 ChatStore 语义、不动删除/归档路径本身、不改 MinisCore API。
        let sessionsChangedPersistence = chat.onSessionsChanged
        let refreshSessionConsumers: () -> Void = { [weak self] in
            guard let self else { return }
            self.productionProjectSessionHandler?.grants.retainDirectorySessions(
                Set(self.chat.sessions.map { $0.id.uuidString }))
            self.observeComposerSpeechSessionTransition()
            self.productionBuiltinToolExecutor?.fileChangeSessionID =
                self.chat.activeSessionID?.uuidString ?? ""
            self.reconcileProductionBrowserSession()
        }
        chat.onSessionSelectionChanged = refreshSessionConsumers
        chat.onSessionsChanged = {
            sessionsChangedPersistence?()
            refreshSessionConsumers()
        }
        // attachPersistence may have replaced the welcome session without
        // publishing onSessionsChanged. Reconcile that transition once before
        // exposing a new speech click context.
        observeComposerSpeechSessionTransition()
        // P3-OUTPUT-01（DEV-311 接线，闭合 OUTPUT01-SESSKEY-REPROBE §2b 的
        // 启动磁盘对账窗口）：:1774 写键发生在 chat.attachPersistence 之前，
        // 键值=装配前当期活跃会话；磁盘快照非空时 attachPersistence（调用点
        // :2099，ChatStore :5204-5228）稍后才丢弃未触碰的 init 欢迎壳并把
        // activeSessionID 置换为 restored.first?.id，而 onSessionsChanged 的
        // 绑定动作本身不触发任何钩子（ChatStore :5235）、包装层在其后才安装
        // ⇒ 修复前从装配完成到首个会话突变事件，键滞留=已被丢弃的壳 UUID
        // （非空、≠活跃会话，ToolExecutor :773 空串 guard 放行，首回合
        // file_write 记到不存在会话的键下）。此处补一次与 :1029-1030 及包装层
        // 同源同形的初始刷新——语义等价于执行包装闭包中的键刷新段（纯读取
        // 赋值、幂等无副作用；无活跃会话→空串=未接线、不登记语义）：不重跑
        // persistSessions、不触发钩子、不侵入 ChatStore.attachPersistence /
        // RECOVERY-10 持久化对账语义域、不改删除/归档路径与 MinisCore API。
        productionBuiltinToolExecutor?.fileChangeSessionID =
            chat.activeSessionID?.uuidString ?? ""
        // Disk reconciliation may replace the initial welcome session without
        // publishing onSessionsChanged; bind the real restored tuple now.
        reconcileProductionBrowserSession()

        // 2.5) C3-3 会话自动保存：Chat 与 Canvas 必须拥有独立的持久化边界。
        //      Chat 保留旧根以兼容既有输入草稿；Canvas 使用独立根，因此各自的
        //      schema、锁、内存 cache、事务 ledger 与 rollback 不会互相污染。
        //      Canvas 根迁移由后续兼容迁移门单独处理，不能把两个域重新接回一个 store。
        let chatDrafts = DraftStore(directory: sessionDirectory)
        let canvasDrafts = DraftStore(
            directory: sessionDirectory.appendingPathComponent("canvas", isDirectory: true)
        )
        if let canvas = canvasIfAvailable {
            canvas.attachDraftStore(canvasDrafts)
        }
        chat.attachDraftStore(chatDrafts)

        // 2.6) C3-3 崩溃恢复提示：启动时检测到上次未保存画布草稿 → 聊天流提示恢复
        //      （输入「恢复画布」恢复 /「丢弃草稿」放弃）。
        if canvasIfAvailable != nil {
            presentCrashRecoveryPromptIfNeeded()
        }

        // Prepare only the canonical App store. Startup never imports external skills.
        let store = productionSkillStore
        let deployment: SkillStoreReadiness.Deployment
        if let existing = productionSkillDeployment, existing.store === store {
            deployment = existing.deployment
        } else {
            deployment = SkillStoreReadiness.Deployment(store: store)
            productionSkillDeployment = (store, deployment)
            skillInjector = nil
            skillDeploymentStatus = .pending
        }
        let deploymentSessionID = chat.activeSessionID
        Task { @MainActor [weak self] in
            let prepared = await deployment.task.value
            guard let self, self.productionSkillDeployment?.deployment === deployment else { return }
            self.skillInjector = prepared.injector
            if self.skillDeploymentStatus != prepared.status,
               case .failed = prepared.status {
                self.chat.appendAssistant("❌ 技能部署失败，已阻止使用不完整技能配置的 Agent 回合。请检查技能来源后重新装配。",
                                          toSession: deploymentSessionID)
            }
            self.skillDeploymentStatus = prepared.status
        }
        chat.skillInjector = { [weak self] text in
            self?.skillInjector?.buildInjectionFragment(for: text)
        }
        chat.skillInjectionWithReceipt = { [weak self] text in
            self?.skillInjector?.buildInjection(for: text)
                ?? SkillInjectionResult(fragment: nil, receipts: [])
        }
        chat.providerRuntimeRouteFactory = { [weak self] provider in
            guard let self else { return nil }
            guard self.admitsProviderNetworkRoute(provider) else {
                return nil
            }
            return try? self.makeProviderRuntimeRoute(
                primary: provider
            )
        }
        chat.turnRuntimeSnapshotFactory = { [weak self] turn, provider in
            guard let self else {
                // The ChatStore can outlive its composition root; fail closed
                // instead of retaining BridgeStore through this callback.
                return ChatTurnRuntimeSnapshot(
                    turn: turn,
                    skillInjector: nil,
                    mcpBridge: nil,
                    providerRuntimeRouteError: .missingPrimaryProvenance,
                    providerLaunchSnapshot: .empty,
                    requiresProviderRuntimeRoute: true
                )
            }
            let route: ProviderRuntimeRoute?
            let routeError: ProviderRuntimeSnapshotError?
            let observationIdentity = self.chat.activeExecutionIdentity(
                for: UUID(uuidString: turn.sessionID)
            )
            let fallbackCandidates = self.productionFallbackEnabled
                && self.productionExternalNetworkAllowed
                ? self.chat.providerRuntimeFallbackCandidates(
                    excludingProviderID: provider.name
                ) : []
            let routePreparation: Task<Result<ProviderRuntimeRoute, ProviderRuntimeSnapshotError>, Never>?
            if !fallbackCandidates.isEmpty {
                route = nil
                routeError = nil
                routePreparation = self.prepareProviderRuntimeRoute(
                    primary: provider, observationIdentity: observationIdentity,
                    fallbackCandidates: fallbackCandidates
                )
            } else {
                routePreparation = nil
                do {
                guard self.admitsProviderNetworkRoute(provider) else {
                    throw ProviderRuntimeSnapshotError.missingPrimaryProvenance
                }
                route = try self.makeProviderRuntimeRoute(
                    primary: provider,
                    observationIdentity: observationIdentity
                )
                routeError = nil
                } catch let error as ProviderRuntimeSnapshotError {
                    route = nil
                    routeError = error
                } catch {
                    route = nil
                    routeError = .missingPrimaryProvenance
                }
            }
            let skillsEnabled = self.isSafetyFeatureEnabled(.userSkills)
            let skillSafetyEpoch = self.safetyRuntimeGeneration
            let mcpEnabled = self.isSafetyFeatureEnabled(.mcp)
            let mcpBridgePreparation = mcpEnabled
                ? turnScopedMCPBridge.captureTurnSnapshotPreparation() : nil
            let skillPreparation = skillsEnabled ? deployment.preparationForTurn() : nil
            let speechToolAvailabilityPreparation = self.prepareSpeechToolAvailability(for: turn)
            let directoryCanonicalizerForTests = self.contextDirectoryCanonicalizerForTests
            return ChatTurnRuntimeSnapshot(
                turn: turn,
                thinkingLevel: ComposerThinkingSelection.capturedLevel(self.chat.composerThinkingLevel,
                    modelID: provider.model.id),
                skillInjector: nil,
                deferredSkillPreparation: skillPreparation,
                skillsDisabled: !skillsEnabled,
                skillAuthorityCheck: { [weak self] in
                    guard let self, self.safetyRuntimeGeneration == skillSafetyEpoch,
                          self.productionSkillDeployment?.deployment === deployment,
                          self.isSafetyFeatureEnabled(.userSkills) == skillsEnabled else { return false }
                    return skillPreparation?.matchesCurrentStore(store) ?? true
                },
                // A custom bridge without an immutable snapshot is denied for
                // this turn instead of leaking the live bridge into execution.
                mcpBridge: mcpEnabled && mcpBridgePreparation == nil
                    ? try? turnScopedMCPBridge.snapshotForTurn()
                    : nil,
                mcpBridgePreparation: mcpBridgePreparation,
                providerRuntimeRoute: route,
                providerRuntimeRouteError: routeError,
                providerRuntimeRoutePreparation: routePreparation,
                providerLaunchSnapshot: self.chat.providerLaunchSnapshot,
                requiresProviderRuntimeRoute: true,
                speechToolAvailabilityPreparation: speechToolAvailabilityPreparation,
                contextSettingsCapture: ChatContextSettingsCapture.deferredForProduction(
                    sessionStore: sessionStore, sessionID: turn.sessionID, model: provider.model,
                    expectedCanonicalDirectory: canonicalSessionDirectory,
                    canonicalizeDirectory: { directory in
                        // Preserve BridgeStore's existing canonical identity,
                        // including its directory hint and Darwin alias rules.
                        let probed = directoryCanonicalizerForTests?(directory) ?? directory
                        return Self.canonicalSessionDirectoryIdentity(probed)
                    }
                )
            )
        }
    }

    func dispatchCanvasMutation(_ operation: CanvasMutationOperation) {
        guard canvasMutationCoordinatorStorage != nil,
              isSafetyFeatureEnabled(.canvas) else {
            return
        }
        lastCanvasMutationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await executeCanvasMutation(operation)
            } catch is SafetyRuntimeAdmissionError {
                return
            } catch {
                return
            }
        }
    }

    func executeCanvasMutation(
        _ operation: CanvasMutationOperation,
        originSessionID: String? = nil
    ) async throws -> CanvasMutationReceipt {
        guard let canvasMutationCoordinator = canvasMutationCoordinatorStorage else {
            throw SafetyRuntimeAdmissionError.featureDisabled(.canvas)
        }
        let epoch = try safetyRuntimeToken(for: .canvas)
        try Task.checkCancellation()
        let receipt = try await canvasMutationCoordinator.execute(
            operation,
            originSessionID: originSessionID
        )
        try validateSafetyRuntimeToken(epoch, for: .canvas)
        return receipt
    }

    private func makeCanvasMutationSnapshot(
        request: CanvasMutationRequest,
        input: ComposerToolInput
    ) -> ComposerSubmissionSnapshot {
        let selection = chat.composerPolicySelection
        let sessionID = chat.activeSessionID?.uuidString ?? "canvas-session"
        let turnID = nextCanvasMutationTurnID
        nextCanvasMutationTurnID += 1
        return ComposerSubmissionSnapshot(
            mode: selection.mode,
            approvalScope: selection.approvalScope,
            effort: selection.effort,
            sessionID: sessionID,
            turnID: turnID,
            taskID: "canvas:\(request.id.uuidString)",
            attemptID: request.id.uuidString,
            messageID: request.id.uuidString,
            inputDigest: input.digest,
            workspaceID: chat.composerWorkspaceID,
            createdAt: Date(),
            policyRevision: chat.composerPolicyFacts.revision,
            grantEpoch: chat.composerPolicyFacts.grantEpoch,
            bypassModeConfirmed: selection.bypassModeConfirmed,
            autonomyCeiling: chat.composerPolicyFacts.autonomyCeiling
        )
    }

    // MARK: C3-1 命令执行（面板 / 菜单共用入口）

    /// A row click carries no arguments. Let the registered descriptor decide
    /// whether to edit first; the submitted query still goes through the
    /// existing parser and runCommand policy/confirmation path.
    func activateCommandRow(id: String) {
        if let command = commandRegistry.command(id: id),
           command.argumentSpecs.contains(where: { $0.required }) {
            commandPaletteDraft = "/\(command.id) "
            isCommandPalettePresented = true
            return
        }
        runCommand(id: id)
    }

    func takeCommandPaletteDraft() -> String? {
        defer { commandPaletteDraft = nil }
        return commandPaletteDraft
    }

    /// 执行注册命令：结果文本写入聊天流（空文本跳过，UI 命令不刷屏）；面板自动关闭。
    /// 需要确认的命令（如 settings.reset）→ 聊天提示，不执行。
    ///
    /// F22④（Q8-r4 P1-3）：`args` 完整透传给注册表执行器——命令面板里输入的
    /// 带参命令（如 `/env.set FOO=bar`）不再因参数丢失触发 missingArgument 后被
    /// catch 静默吞掉；执行错误（缺参/无效参数/未知命令/需确认）一律写聊天流提示，
    /// 面板保持打开供用户补齐参数重试。
    @ObservationIgnored private var ownedCommandTaskSequence: UInt64 = 0
    @ObservationIgnored private var ownedCommandTasks: [UInt64: Task<Void, Never>] = [:]
    @ObservationIgnored private var completedCommandTaskSequences: [UInt64] = []
    @ObservationIgnored private var ownedCommandHistoryFloor: UInt64 = 0

    /// A marker and exact retained task snapshot for isolated UI consumers.
    /// It grants no command authority and never treats an empty snapshot as completion.
    var commandTaskRegistrationSequence: UInt64 { ownedCommandTaskSequence }
    var hasUnfinishedOwnedCommandTasks: Bool {
        ownedCommandTasks.keys.contains { !completedCommandTaskSequences.contains($0) }
    }

    func commandTaskSnapshot(after sequence: UInt64) -> [Task<Void, Never>]? {
        guard sequence >= ownedCommandHistoryFloor, sequence <= ownedCommandTaskSequence else { return nil }
        return ownedCommandTasks.keys.filter { $0 > sequence }.sorted().compactMap { ownedCommandTasks[$0] }
    }

    private func retireOwnedCommandTask(_ sequence: UInt64) {
        completedCommandTaskSequences.append(sequence)
        // Keep a bounded terminal history so a command that completed before a
        // consumer sampled it is still joined through its actual Task.value.
        // Active tasks are retained regardless of their age or count.
        while completedCommandTaskSequences.count > 32 {
            let retired = completedCommandTaskSequences.removeFirst()
            ownedCommandTasks.removeValue(forKey: retired)
            ownedCommandHistoryFloor = max(ownedCommandHistoryFloor, retired)
        }
    }

    @TaskLocal static var compactInvocationSessionID: UUID?

    func runCommand(
        id: String, args: [String: String] = [:],
        completion: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        if !isSafetyCommandEnabled(id) {
            completion?(false)
            return
        }
        // The palette and menu register the same Composer slash IDs. Those
        // rows must create the canonical pending request/receipt, not invoke
        // their metadata-only executor and append its failure as chat text.
        if let command = commandRegistry.command(id: id),
           CommandRegistry.composerCommandIDs.contains(command.id) {
            guard chat.registeredComposerCommandRegistry === commandRegistry else { return }
            if chat.submitRegisteredComposerCommand(id: command.id, args: args),
               chat.composerCommandValidationFailure == nil {
                isCommandPalettePresented = false
            }
            return
        }
        let sourceSessionID = chat.activeSessionID
        let isCompactCommand = commandRegistry.command(id: id)?.id == "ui.chat.compact"
        if isCompactCommand && sourceSessionID == nil {
            completion?(false)
            return
        }
        ownedCommandTaskSequence &+= 1
        let commandSequence = ownedCommandTaskSequence
        let commandTask = Task { @MainActor in
            defer { retireOwnedCommandTask(commandSequence) }
            do {
                let result: CommandResult
                if isCompactCommand {
                    result = try await Self.$compactInvocationSessionID.withValue(sourceSessionID) {
                        try await commandRegistry.execute(id: id, args: args)
                    }
                } else {
                    result = try await commandRegistry.execute(id: id, args: args)
                }
                completion?(result.ok)
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    chat.appendAssistant(text, toSession: sourceSessionID)
                    chat.touchSession(sourceSessionID)
                }
                // Opening the palette is itself a registered command. Its
                // presentation must survive the ordinary command-row dismissal.
                if id.lowercased() != AppCommandCatalog.commandPaletteID {
                    isCommandPalettePresented = false
                }
            } catch let error as CommandExecutionError {
                // F22④：错误显性化——缺参/无效参数/未知命令/需确认都给出提示，不再静默失败
                completion?(false)
                chat.appendAssistant("⚠️ \(error.errorDescription)", toSession: sourceSessionID)
                chat.touchSession(sourceSessionID)
            } catch {
                completion?(false)
                chat.appendAssistant("⚠️ 命令执行失败：\(error.localizedDescription)", toSession: sourceSessionID)
                chat.touchSession(sourceSessionID)
            }
        }
        ownedCommandTasks[commandSequence] = commandTask
    }

    private func isSafetyCommandEnabled(_ id: String) -> Bool {
        if id == "ui.pipeline" || id == "ui.layout.canvas"
            || id.hasPrefix("ui.canvas.") || id.hasPrefix("ui.add-node.") {
            return canvasIfAvailable != nil && isSafetyFeatureEnabled(.canvas)
        }
        if id.contains("orchestrate") || id.contains("external") {
            return isSafetyFeatureEnabled(.externalAgents)
                && isSafetyFeatureEnabled(.childOrchestration)
        }
        return true
    }

    // MARK: 聊天 → 画布

    /// Snapshot-aware Canvas entry. The command is accepted by ChatStore
    /// immediately, but mutation is deferred until the Composer gate returns.
    private func handleChatCommand(
        _ text: String,
        snapshot: ComposerSubmissionSnapshot
    ) -> Bool {
        guard let capability = Self.composerCapability(for: text) else {
            return false
        }
        guard isSafetyFeatureEnabled(.canvas) else {
            chat.appendAssistant("⚠️ 画布功能当前已关闭，未执行画布操作。")
            return true
        }
        guard let base = composerCanvasPolicyBase,
              let approvalGate = composerApprovalGate,
              composerPolicyIsConfigured else {
            guard allowsLegacyCanvasCommandExecutionForTests else {
                return false
            }
            self.lastCanvasMutationTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    _ = try await self.handleChatCommandLegacy(
                        text,
                        originSessionID: allowsLegacyCanvasCommandExecutionForTests
                            ? nil
                            : snapshot.sessionID
                    )
                    await self.awaitLegacyCanvasCommandCompletion(for: text)
                } catch {
                    self.chat.appendAssistant("❌ 画布操作失败：\(error.localizedDescription)")
                }
            }
            return true
        }
        guard snapshot.inputDigest != nil else {
            return false
        }
        let controller = ComposerAuthorizationController(
            snapshot: snapshot,
            facts: chat.composerPolicyFacts,
            grants: chat.composerGrantStore
        )
        let executor = ComposerPolicyEnforcedToolExecutor(
            base: base,
            controller: controller,
            approvalGate: approvalGate,
            onApprovalReceipt: { [weak self] receipt in
                Task { @MainActor [weak self] in
                    self?.composerApprovalReceipts.append(receipt)
                }
            }
        )
        let sourceSessionID = UUID(uuidString: snapshot.sessionID)
        self.lastCanvasMutationTask = Task { @MainActor [weak self] in
            do {
                let output = try await executor.execute(
                    callID: "canvas:\(snapshot.messageID)",
                    name: capability,
                    input: [
                        "command": text,
                        "originSessionID": snapshot.sessionID,
                    ]
                )
                if output.contains("\"status\":\"dry-run\"") {
                    self?.chat.appendAssistant("计划预览：\(text)（未执行任何画布变更）", toSession: sourceSessionID)
                    self?.chat.touchSession(sourceSessionID)
                }
            } catch is SafetyRuntimeAdmissionError {
                return
            } catch {
                self?.chat.appendAssistant("⚠️ Composer 已拒绝画布操作：\(error.localizedDescription)", toSession: sourceSessionID)
                self?.chat.touchSession(sourceSessionID)
            }
        }
        return true
    }

    /// Legacy test commands can launch nested asynchronous work (Agent,
    /// workflow, or import). Keep the test-only completion hook at the outer
    /// command boundary so tests observe the same coordinator result without
    /// weakening the production Composer path.
    private func awaitLegacyCanvasCommandCompletion(for text: String) async {
        if WorkflowChatController.isWorkflowTrigger(text) {
            while workflowChat.isRunning {
                await Task.yield()
            }
        }

        guard let command = CommandParser.parse(text) else { return }
        switch command {
        case .adjustNodeContent, .summarizeNode:
            await lastAgentAdjustTask?.value
        default:
            break
        }
    }

    private var composerPolicyIsConfigured: Bool {
        composerPolicyFactsRevisionIsConfigured
    }

    private var composerPolicyFactsRevisionIsConfigured: Bool {
        !chat.composerPolicyFacts.revision.isEmpty
            && chat.composerPolicyFacts.revision != "unconfigured"
    }

    private static func composerCapability(for text: String) -> String? {
        if WorkflowChatController.isWorkflowTrigger(text)
            || TaskCenterSlashCommandAdapter.handles(text) {
            return "canvas_mutation"
        }
        guard let command = CommandParser.parse(text) else { return nil }
        switch command {
        case .listNodes, .help:
            return "canvas_read"
        default:
            return "canvas_mutation"
        }
    }

    fileprivate func executeComposerCanvasCommand(
        _ text: String,
        originSessionID: String? = nil
    ) async throws -> String {
        let epoch = try safetyRuntimeToken(for: .canvas)
        composerCanvasDispatchCount += 1
        guard try await handleChatCommandLegacy(
            text,
            originSessionID: originSessionID
        ) else {
            throw ComposerAuthorizationError.invalidInput
        }
        try validateSafetyRuntimeToken(epoch, for: .canvas)
        return "canvas-command-applied"
    }

    /// 返回 true = 已按画布指令处理（不再走 LLM）
    fileprivate func handleChatCommandLegacy(
        _ text: String,
        originSessionID: String? = nil
    ) async throws -> Bool {
        guard isSafetyFeatureEnabled(.canvas) else {
            throw SafetyRuntimeAdmissionError.featureDisabled(.canvas)
        }
        // E10：工作流触发词优先（`/workflow xxx` / `运行工作流 xxx`）→ 聊天内执行
        // （须在 CommandParser 之前：`运行工作流…` 前缀会被画布 `运行` 指令误吞）
        if WorkflowChatController.isWorkflowTrigger(text) {
            workflowChat.run(text: text, chat: chat)
            return true
        }
        if TaskCenterSlashCommandAdapter.handles(text) {
            chat.appendAssistant(executeTaskCenterSlashCommand(text))
            return true
        }
        guard let command = CommandParser.parse(text) else { return false }
        switch command {
        case .addNode(let keyword):
            if let spec = NodeTypeRegistry.spec(matching: keyword) {
                if NodeTypeRegistry.creatableTypes.contains(spec.type) {
                    _ = try await canvasMutationCoordinator.execute(
                        .addNode(type: spec.type, position: nil),
                        originSessionID: originSessionID
                    )
                    let title = canvas.graph.nodes.last?.title ?? spec.title
                    chat.appendAssistant("✅ 已创建节点「\(title)」（\(spec.summary)）。可以继续说：`连线 \(title) -> …` 或 `执行`。")
                } else {
                    // Phase B：文本创作类保留类型定义兼容旧图，但不再允许从新建入口创建
                    chat.appendAssistant("❓ 节点类型「\(spec.title)」属文本创作类，画布新建入口已下线（可继续用「一键流水线」生成全流程骨架）。")
                }
            } else {
                let types = NodeTypeRegistry.creatableSpecs.map { $0.type }.joined(separator: " / ")
                chat.appendAssistant("❓ 未识别节点类型「\(keyword)」。可用类型：\(types)")
            }
            return true

        case .connect(let from, let to):
            guard let fromNode = canvas.node(matchingTitle: from) else {
                chat.appendAssistant("❓ 找不到名称包含「\(from)」的节点。用 `节点列表` 查看现有节点。")
                return true
            }
            guard let toNode = canvas.node(matchingTitle: to), toNode.id != fromNode.id else {
                chat.appendAssistant("❓ 找不到名称包含「\(to)」的目标节点。")
                return true
            }
            if (try? await canvasMutationCoordinator.execute(
                .connect(fromID: fromNode.id, toID: toNode.id),
                originSessionID: originSessionID
            )) != nil {
                chat.appendAssistant("✅ 已连接：\(fromNode.title) → \(toNode.title)")
            } else {
                chat.appendAssistant("⚠️ 这两个节点已连接（或缺少可用端口）。")
            }
            return true

        case .run:
            chat.appendAssistant("▶️ 开始执行画布 DAG…")
            _ = try await canvasMutationCoordinator.execute(
                .runGraph(nodeIDs: nil),
                originSessionID: originSessionID
            )
            return true

        case .layout:
            _ = try await canvasMutationCoordinator.execute(
                .autoLayout,
                originSessionID: originSessionID
            )
            chat.appendAssistant("✅ 已自动布局。")
            return true

        case .reset:
            _ = try await canvasMutationCoordinator.execute(
                .resetStatuses,
                originSessionID: originSessionID
            )
            chat.appendAssistant("✅ 已重置所有节点状态为待执行。")
            return true

        case .deleteNode(let keyword):
            if let node = canvas.node(matchingTitle: keyword) {
                _ = try await canvasMutationCoordinator.execute(
                    .removeNode(id: node.id),
                    originSessionID: originSessionID
                )
                chat.appendAssistant("✅ 已删除节点「\(node.title)」。")
            } else {
                chat.appendAssistant("❓ 找不到名称包含「\(keyword)」的节点。")
            }
            return true

        case .listNodes:
            if canvas.graph.nodes.isEmpty {
                chat.appendAssistant("画布为空。试试 `建节点 text`。")
            } else {
                let lines = canvas.graph.nodes.map { "· \($0.title)（\($0.type)，\($0.status.label)）" }
                chat.appendAssistant("当前画布节点：\n" + lines.joined(separator: "\n"))
            }
            return true

        case .help:
            chat.appendAssistant(Self.helpText)
            return true

        // MARK: E16 对话驱动节点内容调整

        case .setNodeContent(let keyword, let content):
            if let node = canvas.node(matchingTitle: keyword) {
                _ = try await canvasMutationCoordinator.execute(
                    .updateNodeContent(content: content, id: node.id),
                    originSessionID: originSessionID
                )
                chat.appendAssistant("✅ 已更新节点「\(node.title)」：\(Self.preview(content))")
            } else {
                chat.appendAssistant("❓ 找不到名称包含「\(keyword)」的节点。用 `节点列表` 查看现有节点。")
            }
            return true

        case .adjustNodeContent(let keyword, let instruction):
            guard let node = canvas.node(matchingTitle: keyword) else {
                chat.appendAssistant("❓ 找不到名称包含「\(keyword)」的节点。用 `节点列表` 查看现有节点。")
                return true
            }
            chat.appendAssistant("🤖 正在让 Agent 调整「\(node.title)」：\(instruction)…")
            runNodeAgentAdjust(
                nodeID: node.id,
                instruction: instruction,
                originSessionID: originSessionID
            )
            return true

        case .summarizeNode(let keyword):
            guard let node = canvas.node(matchingTitle: keyword) else {
                chat.appendAssistant("❓ 找不到名称包含「\(keyword)」的节点。用 `节点列表` 查看现有节点。")
                return true
            }
            chat.appendAssistant("🤖 正在总结「\(node.title)」…")
            runNodeAgentAdjust(
                nodeID: node.id,
                instruction: nil,
                originSessionID: originSessionID
            )
            return true

        case .importNovel(let payload):
            await handleImportNovel(payload, originSessionID: originSessionID)
            return true

        case .createPipeline:
            try await createManjuPipelineAuthorized(originSessionID: originSessionID)
            return true

        // MARK: C3-3 崩溃恢复 + Agent 操作历史

        case .recoverCanvasDraft:
            handleRecoverCanvasDraft()
            return true

        case .discardCanvasDraft:
            handleDiscardCanvasDraft()
            return true

        case .toolHistory:
            showToolHistory()
            return true

        case .undoToolAction:
            undoLatestToolAction()
            return true
        }
    }

    // MARK: P2-1 一键漫剧流水线（工具栏按钮 / 对话指令 / DeepLink 共用入口）

    /// 一键生成漫剧流水线（12 节点全流程，含资产引用 + 审核闸口 + 资产锁定注入），写聊天回执。
    /// ContentView 工具栏「一键流水线」按钮（⌘P）、对话指令（一键流水线/生成流水线/漫剧流程）、
    /// DeepLinkHandler `.createPipeline` 全部走这里，保证三入口行为一致。
    /// Phase B 语义：只生成节点骨架，不自动执行全部（执行需用户显式 `执行`）。
    func createManjuPipeline() {
        guard canvasIfAvailable != nil, isSafetyFeatureEnabled(.canvas) else {
            return
        }
        guard allowsLegacyCanvasCommandExecutionForTests else {
            lastCanvasMutationTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.createManjuPipelineAuthorized(originSessionID: nil)
                } catch is SafetyRuntimeAdmissionError {
                    return
                } catch {
                    self.chat.appendAssistant("❌ 画布操作失败：\(error.localizedDescription)")
                }
            }
            return
        }
        createManjuPipelineForLegacyTests()
    }

    private func createManjuPipelineAuthorized(
        originSessionID: String?
    ) async throws {
        _ = try await executeCanvasMutation(
            .createPipeline,
            originSessionID: originSessionID
        )
        let pipeline = ManjuPipelineTemplate.makeManjuPipeline(assets: .demo)
        appendPipelineReceipt(pipeline)
    }

    private func createManjuPipelineForLegacyTests() {
        let pipeline = canvas.createManjuPipeline()
        appendPipelineReceipt(pipeline)
    }

    private func appendPipelineReceipt(_ pipeline: NodeGraph) {
        let chain = Self.pipelineChainSummary(pipeline)
        let extra = pipeline.nodes.filter {
            $0.type == ManjuNodeType.assetRef.rawValue || $0.type == ManjuNodeType.blenderPreview.rawValue
        }.map(\.title)
        chat.appendAssistant(
            "✅ 已生成漫剧流水线（\(pipeline.nodes.count) 节点 · \(pipeline.edges.count) 连线）：\(chain)"
            + (extra.isEmpty ? "" : "（另含 \(extra.joined(separator: " / "))）")
            + "。可双击「小说导入」粘贴小说，输入 `执行` 开始全流程。"
        )
    }

    // MARK: AJ-37 工作流模板库（工具栏「模板」菜单 / 对话指令共用入口）

    /// 把预设模板应用到当前画布 + 写聊天回执。
    /// 语义：静态骨架，只建节点与连线，不自动执行（执行需用户显式「执行」）。
    func applyTemplate(_ template: CanvasTemplate) {
        guard canvasIfAvailable != nil, isSafetyFeatureEnabled(.canvas) else {
            return
        }
        guard allowsLegacyCanvasCommandExecutionForTests else {
            lastCanvasMutationTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.applyTemplateAuthorized(template)
                } catch is SafetyRuntimeAdmissionError {
                    return
                } catch {
                    self.chat.appendAssistant("❌ 画布操作失败：\(error.localizedDescription)")
                }
            }
            return
        }
        applyTemplateForLegacyTests(template)
    }

    private func applyTemplateAuthorized(_ template: CanvasTemplate) async throws {
        let nodeCountBefore = canvas.graph.nodes.count
        let edgeCountBefore = canvas.graph.edges.count
        _ = try await executeCanvasMutation(.applyTemplate(template: template))
        appendTemplateReceipt(
            template,
            nodeCount: canvas.graph.nodes.count - nodeCountBefore,
            edgeCount: canvas.graph.edges.count - edgeCountBefore
        )
    }

    private func applyTemplateForLegacyTests(_ template: CanvasTemplate) {
        let graph = canvas.applyTemplate(template)
        appendTemplateReceipt(
            template,
            nodeCount: graph.nodes.count,
            edgeCount: graph.edges.count
        )
    }

    private func appendTemplateReceipt(
        _ template: CanvasTemplate,
        nodeCount: Int,
        edgeCount: Int
    ) {
        chat.appendAssistant(
            "📐 已应用模板「\(template.name)」（\(nodeCount) 节点 · \(edgeCount) 连线）："
            + "\(template.description)。填写节点内容后输入 `执行` 开始。"
        )
    }

    // MARK: C3-3 崩溃恢复提示 + Agent 操作历史（撤销留接口）

    /// App 启动时检测上次未保存画布草稿 → 聊天流提示（「恢复画布」/「丢弃草稿」指令）。
    /// 由 attachProductionServices 调用（崩溃恢复：App 异常退出后重开找回画布）。
    private func presentCrashRecoveryPromptIfNeeded() {
        guard canvasIfAvailable != nil else { return }
        guard let draft = canvas.recoverableCanvasDraft() else { return }
        pendingCanvasRecovery = draft
        chat.appendCanvasNotice(
            "⚠️ 检测到上次未保存的画布草稿（\(draft.nodes.count) 节点 · \(draft.edges.count) 连线，"
            + "\(Self.recoveryTimeLabel(draft.savedAt))）。输入「恢复画布」恢复，或「丢弃草稿」放弃。"
        )
    }

    /// 恢复画布草稿（「恢复画布」指令）：重建节点图并清理旧草稿（后续变更重新防抖落盘）
    func handleRecoverCanvasDraft() {
        guard canvasIfAvailable != nil, isSafetyFeatureEnabled(.canvas) else {
            return
        }
        guard let draft = pendingCanvasRecovery ?? canvas.recoverableCanvasDraft() else {
            chat.appendAssistant("ℹ️ 没有可恢复的画布草稿。")
            return
        }
        let originSessionID = chat.activeSessionID
        lastCanvasMutationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await canvasMutationCoordinator.execute(
                    .restoreCanvas(draft: draft),
                    originSessionID: originSessionID?.uuidString
                )
                canvas.discardCanvasDraft()
                // 消费旧草稿后立即重新挂载当前完整状态，避免恢复成功但本次退出再次丢失
                // 资产引用、任务索引、视口、选择和预览状态。
                canvas.noteGraphChanged()
                pendingCanvasRecovery = nil
                chat.appendAssistant(
                    "✅ 已恢复上次画布草稿（\(draft.nodes.count) 节点 · \(draft.edges.count) 连线）。",
                    toSession: originSessionID
                )
                chat.touchSession(originSessionID)
            } catch is SafetyRuntimeAdmissionError {
                return
            } catch {
                chat.appendAssistant("❌ 草稿恢复已拒绝：\(error.localizedDescription)", toSession: originSessionID)
                chat.touchSession(originSessionID)
            }
        }
    }

    /// 丢弃画布草稿（「丢弃草稿」指令）
    func handleDiscardCanvasDraft() {
        guard canvasIfAvailable != nil else { return }
        canvas.discardCanvasDraft()
        pendingCanvasRecovery = nil
        chat.appendAssistant("🗑️ 已丢弃上次未保存的画布草稿。")
    }

    /// 展示 Agent 工具调用历史到聊天流（记录 + 展示；ActionHistoryView 可另行挂侧栏）
    func showToolHistory() {
        let records = actionHistory.records
        guard !records.isEmpty else {
            chat.appendAssistant("ℹ️ 暂无工具调用记录。Agent 的工具调用（shell/文件/搜索）会自动入历史栈。")
            return
        }
        let lines = records.enumerated().map { index, record in
            let time = record.timestamp.formatted(date: .omitted, time: .shortened)
            let flag = record.succeeded ? "" : " ⚠️失败"
            return "\(index + 1). [\(time)] `\(record.toolName)` \(record.argsSummary) → \(record.resultSummary)\(flag)"
        }
        chat.appendAssistant("🧰 工具调用历史（\(records.count) 条）：\n" + lines.joined(separator: "\n"))
    }

    /// 撤销最近一次 Agent 工具调用（聊天「撤销」指令 / ⌘Z 等价入口）。
    /// 撤销执行留接口：ActionHistoryStore.undoHandler 未装配时仅提示记录模式。
    @discardableResult
    func undoLatestToolAction() -> Bool {
        if actionHistory.undoLatest() {
            chat.appendCanvasNotice("↩️ 已撤销最近一次工具调用。")
            return true
        }
        chat.appendCanvasNotice("ℹ️ 操作历史为空或撤销接口未装配——当前为记录模式（可输入「工具历史」查看）。")
        return false
    }

    /// 草稿保存时间 → 人类可读（恢复提示用）
    static func recoveryTimeLabel(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// 流水线主链摘要：按 ManjuNodeType 语义顺序输出主链节点标题
    /// （辅助节点如 资产引用 / Blender 预演 不计入主链）。
    static func pipelineChainSummary(_ graph: NodeGraph) -> String {
        let mainOrder: [ManjuNodeType] = [
            .novelImport, .plotOutline, .script, .storyboard,
            .imagePrompt, .videoPrompt, .imageGen, .videoGen, .qcCheck,
        ]
        let titles = mainOrder.compactMap { type in
            graph.nodes.first { $0.type == type.rawValue }?.title
        }
        return titles.joined(separator: " → ")
    }

    // MARK: E16 对话驱动节点内容调整 — 执行

    /// 最近一次 Agent 节点调整/总结任务（测试可 await 等待完成）。
    private(set) var lastAgentAdjustTask: Task<Void, Never>?

    /// Agent 调整（instruction 非 nil）或总结（nil）：读节点内容 → 拼 prompt →
    /// AgentLoop 调当前选中模型 → 新内容写回节点 → 聊天回执。
    ///
    /// F22（③ F3 残留回执）：入口捕获发起会话 ID，Task 内回执写回该会话 ——
    /// Agent 跑得慢，用户中途切会话，旧回执原来会串进新活跃会话（复用 F3 原语
    /// appendAssistant(_:toSession:)，与 DeepLinkHandler.runWorkflow 同款修法）。
    private func runNodeAgentAdjust(
        nodeID: UUID,
        instruction: String?,
        originSessionID requestOriginSessionID: String?
    ) {
        guard canvasIfAvailable != nil, isSafetyFeatureEnabled(.canvas) else {
            return
        }
        let title = canvas.graph.node(id: nodeID)?.title ?? "节点"
        let safetyEpoch = safetyRuntimeEpoch
        let frozenMutationRequest = canvasMutationCoordinator.makeRequest(
            .updateNodeContent(content: "", id: nodeID),
            originSessionID: requestOriginSessionID
        )
        // F22（③）：发起时刻的会话 —— Task 回执按此写回，不追活跃会话
        let originSessionID = chat.activeSessionID
        lastAgentAdjustTask = Task { [weak self] in
            guard let self else { return }
            do {
                nonisolated(unsafe) let provider = try self.chat.lightweightTaskProvider()
                let current = self.canvas.nodeContent(id: nodeID) ?? ""
                let isSummarize = instruction == nil
                let systemPrompt = isSummarize
                    ? "你是 MinisCanvas 画布助手。请总结用户给出的节点内容，直接输出精炼后的完整总结（保留关键信息），不要输出 JSON 或工具调用。"
                    : "你是 MinisCanvas 画布助手。请根据用户要求调整节点内容，直接输出调整后的完整内容文本，不要输出 JSON 或工具调用。"
                let userText = isSummarize
                    ? "请总结以下节点内容：\n\n\(Self.capped(current))"
                    : "用户要求调整：\(instruction ?? "")\n\n当前内容：\n\(Self.capped(current))\n\n请输出调整后的完整内容。"
                let newContent = try await AgentLoopChatEngine.oneShotAgentReply(
                    provider: provider,
                    systemPrompt: systemPrompt,
                    userText: userText,
                    maxTokens: 2048,
                    onRecorded: { [weak chat] tokens in
                        Task { @MainActor in chat?.recordTokens(tokens) }
                    }
                )
                let trimmed = newContent.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    self.chat.appendAssistant("❌ Agent 返回空内容，未更新节点「\(title)」。", toSession: originSessionID)
                    self.chat.touchSession(originSessionID)
                    return
                }
                try self.validateSafetyRuntimeToken(safetyEpoch, for: .canvas)
                let lateResultRequest = CanvasMutationRequest(
                    id: frozenMutationRequest.id,
                    canvasID: frozenMutationRequest.canvasID,
                    baseRevision: frozenMutationRequest.baseRevision,
                    baseFingerprint: frozenMutationRequest.baseFingerprint,
                    originSessionID: frozenMutationRequest.originSessionID,
                    operation: .updateNodeContent(content: trimmed, id: nodeID)
                )
                _ = try await self.canvasMutationCoordinator.execute(lateResultRequest)
                self.chat.appendAssistant("✅ 已更新节点「\(title)」：\(Self.preview(trimmed))", toSession: originSessionID)
                self.chat.touchSession(originSessionID)
            } catch is SafetyRuntimeAdmissionError {
                return
            } catch {
                self.chat.appendAssistant("❌ Agent 处理节点「\(title)」失败：\(error.localizedDescription)", toSession: originSessionID)
                self.chat.touchSession(originSessionID)
            }
        }
    }

    /// 导入小说：载荷为存在的文件路径（/ 或 ~ 开头）则读文件，否则视为粘贴文本；
    /// 目标为小说节点（标题含「小说」或类型 novelImport），无则自动新建。
    private func handleImportNovel(
        _ payload: String,
        originSessionID: String?
    ) async {
        // 卡顿专项（P0）：大文件（.txt/.md 小说可达数 MB）同步 Data(contentsOf:)
        // 在主线程执行会整帧阻塞 UI。先把读取放后台 Task.detached，读完后回主线程
        // 写节点 + 回执，保持 API 与测试语义不变。
        let content = await Task.detached(priority: .userInitiated) {
            let content = BridgeStore.readFileIfPath(payload) ?? payload
            return content
        }.value
        await finishImportNovel(content, originSessionID: originSessionID)
    }

    @MainActor
    private func finishImportNovel(
        _ content: String,
        originSessionID: String?
    ) async {
        let sourceSessionID = originSessionID.flatMap(UUID.init(uuidString:))
        if let node = canvas.novelNode() {
            do {
                _ = try await canvasMutationCoordinator.execute(
                    .updateNodeContent(content: content, id: node.id),
                    originSessionID: originSessionID
                )
                chat.appendAssistant("✅ 已导入小说到「\(node.title)」（\(content.count) 字）：\(Self.preview(content))", toSession: sourceSessionID)
                chat.touchSession(sourceSessionID)
            } catch {
                chat.appendAssistant("❌ 导入失败：\(error.localizedDescription)", toSession: sourceSessionID)
                chat.touchSession(sourceSessionID)
            }
        } else {
            do {
                _ = try await canvasMutationCoordinator.execute(
                    .addNodeWithContent(
                        type: ManjuNodeType.novelImport.rawValue,
                        content: content,
                        position: nil
                    ),
                    originSessionID: originSessionID
                )
                chat.appendAssistant("✅ 已新建「小说导入」节点并写入（\(content.count) 字）：\(Self.preview(content))", toSession: sourceSessionID)
                chat.touchSession(sourceSessionID)
            } catch {
                chat.appendAssistant("❌ 导入失败：无法创建小说节点。", toSession: sourceSessionID)
                chat.touchSession(sourceSessionID)
            }
        }
    }

    /// 若 raw 是 / 或 ~ 开头的文件路径且存在，读取 UTF-8 文本；否则返回 nil（视为粘贴文本）
    /// 本函数仅做磁盘 I/O，不碰任何 UI 状态，可安全地在任意现场（Task.detached）调用。
    nonisolated static func readFileIfPath(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~") else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded),
              let data = try? Data(contentsOf: URL(fileURLWithPath: expanded)),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    /// 单行预览：去换行 + 截断到 max 字
    static func preview(_ text: String, max: Int = 50) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > max ? String(flat.prefix(max)) + "…" : flat
    }

    /// Agent prompt 用：截断到 max 字（默认 600）
    static func capped(_ text: String, max: Int = 600) -> String {
        text.count > max ? String(text.prefix(max)) + "\n…（内容过长已截断）" : text
    }

    static let helpText = """
    画布指令一览：
    · 建节点 <类型>　— 类型：text / imageGen / videoGen / blenderPreview / qcCheck / assetRef（或中文标题）
    · 连线 A -> B　— 把节点 A 的输出连到节点 B 的输入
    · 执行　— 运行整个 DAG 管线
    · 布局　— 自动分层布局
    · 重置　— 节点状态复位
    · 删除节点 <名称>
    · 节点列表
    · 设置 <节点>：<内容>　— 直接写入节点内容
    · 调整 <节点>：<指令>　— Agent 读节点内容后按指令改写（如「调整 剧情：更紧凑」）
    · 总结 <节点>　— Agent 总结节点内容并写回
    · 导入小说 <路径或粘贴> / 小说内容：<文本>　— 写入小说导入节点
    """

    // MARK: E18 文档工作区互通（文档 ↔ 画布 ↔ 聊天）
    // 2026-08-06 用户定案：工作板块整体移除——文档工作并入对话（对话右侧文件选择已覆盖），
    // 文档互通的 documents 属性与 sendDocumentTo* / openCanvasNodeAsDocument 已随工作区删除。

    // MARK: Canvas-local event projection

    private func handleCanvasEvent(_ event: CanvasEvent) {
        switch event {
        case .nodeSelected(let title, let type, let status, let modelID, let inputCount, let outputCount):
            selectedNodeContext = NodeContextInfo(
                title: title, type: type, statusLabel: status.label,
                modelID: modelID, inputCount: inputCount, outputCount: outputCount
            )
        case .selectionCleared:
            selectedNodeContext = nil
        default:
            break
        }

        guard allowsLegacyCanvasCommandExecutionForTests else { return }
        switch event {
        case .nodeAdded(let title, let type):
            chat.appendCanvasNotice("🟢 画布新增节点「\(title)」（\(type)）")
        case .nodeRemoved(let title):
            chat.appendCanvasNotice("🗑️ 画布删除节点「\(title)」")
        case .edgeAdded(let fromTitle, let toTitle):
            chat.appendCanvasNotice("🔗 画布连线：\(fromTitle) → \(toTitle)")
        case .runStarted:
            chat.appendCanvasNotice("▶️ 画布开始执行…")
        case .runFinished(let summary):
            chat.appendCanvasNotice("🏁 画布执行结束：\(summary)")
        case .nodeStatusChanged(let title, let status):
            chat.appendCanvasNotice("· \(title)：\(status.label)")
        case .layoutDone:
            chat.appendCanvasNotice("📐 画布自动布局完成")
        case .nodeSelected(let title, let type, _, let modelID, _, _):
            chat.appendCanvasNotice(
                "🎯 已选中节点「\(title)」（\(type)），模型：\(modelID ?? "默认")。可输入 `连线 …` 继续编排。"
            )
        case .selectionCleared:
            break
        }
    }
}

/// Runtime-side gate for tool calls. It captures the same settings snapshot
/// before and after the optional operation so a late result cannot be accepted
/// after Safe Mode/Kill Switch changes.
private final class SafetyRuntimeToolGate:
    ToolCatalogValidatingExecutor,
    SessionReadCapabilityAwareToolExecutor,
    BuiltinOwnerBoundToolExecutor,
    @unchecked Sendable
{
    private let base: any ToolExecutor
    private let compositionOwner: ObjectIdentifier
    private let snapshotProvider: @Sendable () async -> (SafetyRuntimeSnapshot, UInt64, ObjectIdentifier?)

    init(
        base: any ToolExecutor,
        compositionOwner: ObjectIdentifier,
        snapshotProvider: @escaping @Sendable () async -> (SafetyRuntimeSnapshot, UInt64, ObjectIdentifier?)
    ) {
        self.base = base
        self.compositionOwner = compositionOwner
        self.snapshotProvider = snapshotProvider
    }

    func execute(name: String, input: [String: Any]) async throws -> String {
        try await execute(name: name, input: input, boundOwner: nil)
    }

    func validateToolCatalog(_ tools: [AgentToolDefinition]) throws {
        try (base as? any ToolCatalogValidatingExecutor)?.validateToolCatalog(tools)
    }

    var currentBuiltinOwner: BuiltinToolExecutor? {
        (base as? any BuiltinOwnerBoundToolExecutor)?.currentBuiltinOwner
    }

    func executeBoundToBuiltinOwner(
        _ owner: BuiltinToolExecutor, name: String, input: [String: Any]
    ) async throws -> String {
        guard currentBuiltinOwner === owner else { throw ToolExecutorError.resourceScopeInvalid }
        return try await execute(name: name, input: input, boundOwner: owner)
    }

    /// Optional old-content capture is an operation on this composition too.
    /// It uses the execution gate's existing snapshot predicate, not a second
    /// authority table or a grant that could survive a production rebind.
    func validateFileChangePrecheckAdmission(name: String) async throws {
        _ = try await admittedSnapshot(for: name)
    }

    private func admittedSnapshot(for name: String) async throws -> (SafetyRuntimeSnapshot, UInt64) {
        let (before, epoch, owner) = await snapshotProvider()
        let feature = Self.feature(for: name)
        guard before.isEnabled(feature) else {
            throw SafetyRuntimeAdmissionError.featureDisabled(feature)
        }
        // A detached executable chain cannot start new work after a real reattach.
        // Safety snapshot changes alone do not invalidate a still-current chain.
        guard owner == compositionOwner else {
            throw SafetyRuntimeAdmissionError.staleRuntime(feature)
        }
        try Task.checkCancellation()
        return (before, epoch)
    }

    private func execute(
        name: String, input: [String: Any], boundOwner: BuiltinToolExecutor?
    ) async throws -> String {
        let (_, epoch) = try await admittedSnapshot(for: name)
        if name == ProjectSessionToolContract.sessionCreate {
            guard await AgentExecutionContext.current?.parentAuthorityCheck?() != false else {
                throw CancellationError()
            }
            try Task.checkCancellation()
        }
        let feature = Self.feature(for: name)
        let output: String
        if let boundOwner {
            output = try await executeThroughBoundBuiltinOwner(
                base, owner: boundOwner, name: name, input: input
            )
        } else {
            output = try await base.execute(name: name, input: input)
        }
        let (after, afterEpoch, afterOwner) = await snapshotProvider()
        guard afterEpoch == epoch, after.isEnabled(feature),
              afterOwner == compositionOwner else {
            throw SafetyRuntimeAdmissionError.staleRuntime(feature)
        }
        return output
    }

    /// Preserve the typed cross-session authorization seam while applying the
    /// same Safe Mode/Kill Switch admission contract as ordinary tools.
    /// Never fall back to `execute(name:input:)`: that legacy entry point does
    /// not carry the turn-bound authorization or execution context.
    func executeSessionRead(
        input: [String: Any],
        authorization: CrossSessionReadAuthorization,
        context: SessionReadExecutionContext,
        now: Date
    ) async throws -> String {
        let (before, epoch, owner) = await snapshotProvider()
        let feature: SafetyControlFeature = .chat
        guard before.isEnabled(feature) else {
            throw SafetyRuntimeAdmissionError.featureDisabled(feature)
        }
        guard owner == compositionOwner else {
            throw SafetyRuntimeAdmissionError.staleRuntime(feature)
        }
        try Task.checkCancellation()
        guard let aware = base as? any SessionReadCapabilityAwareToolExecutor else {
            throw CrossSessionReadAuthorizationError.capabilityRequired
        }
        let output = try await aware.executeSessionRead(
            input: input,
            authorization: authorization,
            context: context,
            now: now
        )
        let (after, afterEpoch, afterOwner) = await snapshotProvider()
        guard afterEpoch == epoch, after.isEnabled(feature),
              afterOwner == compositionOwner else {
            throw SafetyRuntimeAdmissionError.staleRuntime(feature)
        }
        return output
    }

    private static func feature(for name: String) -> SafetyControlFeature {
        switch name {
        case OrchestrationToolExecutor.toolName:
            return .childOrchestration
        // P3-P1-05: "web_search" is de-listed here — it is an un-implemented
        // capability and must not appear among safety-permitted tools. Any
        // call still reaches BuiltinToolExecutor, which fails closed
        // (unknownTool at the default whitelist gate, toolNotConfigured if a
        // consumer registered the name explicitly), so no side effect exists
        // to gate.
        case BrowserTool.toolName, BrowserTool.legacyToolName,
             "shell_execute", "file_write", "file_edit", "file_delete":
            return .browserTerminalSideEffects
        default:
            if name.hasPrefix("mcp_") { return .mcp }
            if name.hasPrefix("canvas_") { return .canvas }
            if name.hasPrefix("external_")
                || name.contains("codex")
                || name.contains("claude")
                || name.contains("hermes") {
                return .externalAgents
            }
            return .chat
        }
    }
}

/// The real bottom of the direct Canvas path. It is intentionally only a
/// narrow command adapter; Composer and PolicyRuntime wrappers sit above it.
fileprivate final class ComposerCanvasCommandExecutor: ToolExecutor, @unchecked Sendable {
    private weak var bridge: BridgeStore?

    init(bridge: BridgeStore) {
        self.bridge = bridge
    }

    func execute(name: String, input: [String: Any]) async throws -> String {
        guard name == "canvas_read" || name == "canvas_mutation",
              let command = input["command"] as? String,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ComposerAuthorizationError.invalidInput
        }
        guard let bridge else {
            throw ComposerAuthorizationError.authorizationRevoked
        }
        return try await bridge.executeComposerCanvasCommand(
            command,
            originSessionID: input["originSessionID"] as? String
        )
    }
}
