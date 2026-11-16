import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CanvasCore
import MinisCore

/// Retains the actual parent-window responder while Task Center owns focus.
/// A weak reference avoids keeping an old window or removed editor alive.
@MainActor
final class TaskCenterOpenerFocus {
    enum Restoration: Equatable {
        case toolbar, responder, none
    }

    private weak var window: NSWindow?
    private weak var responder: NSResponder?
    private weak var logicalOwner: NSControl?
    private var capturedFieldEditor = false
    private var toolbarOpener = false

    /// Returns the observed logical-owner match count for a captured field editor.
    @discardableResult
    func capture(toolbarOpener: Bool, window: NSWindow? = NSApp.keyWindow ?? NSApp.mainWindow) -> Int? {
        self.window = window
        responder = window?.firstResponder
        self.toolbarOpener = toolbarOpener
        logicalOwner = nil
        capturedFieldEditor = false
        guard !toolbarOpener, let window,
              let fieldEditor = responder as? NSText, fieldEditor.isFieldEditor else { return nil }
        capturedFieldEditor = true
        var matches: [NSControl] = []
        var pending: [NSView] = window.contentView.map { [$0] } ?? []
        while let view = pending.popLast() {
            if let control = view as? NSControl,
               control.window === window, control.currentEditor() === fieldEditor {
                matches.append(control)
            }
            pending.append(contentsOf: view.subviews)
        }
        if matches.count == 1 { logicalOwner = matches[0] }
        return matches.count
    }

    /// Distinguishes toolbar focus from a restored keyboard responder.
    @discardableResult
    func restore() -> Restoration {
        defer {
            window = nil
            responder = nil
            logicalOwner = nil
            capturedFieldEditor = false
            toolbarOpener = false
        }
        // The toolbar entry is restored by this ContentView's own FocusState.
        // It must not depend on a global key/main window existing at capture time.
        if toolbarOpener { return .toolbar }
        guard let window, window.isVisible, window.attachedSheet == nil else { return .none }
        if capturedFieldEditor {
            guard let logicalOwner, logicalOwner.window === window else {
                if let responder { _ = window.makeFirstResponder(responder) }
                return .none
            }
            guard window.makeFirstResponder(logicalOwner),
                  let fieldEditor = logicalOwner.currentEditor(),
                  fieldEditor.isFieldEditor, fieldEditor.window === window,
                  window.firstResponder === fieldEditor else { return .none }
            return .responder
        }
        guard let responder else { return .none }
        return window.makeFirstResponder(responder) ? .responder : .none
    }
}

/// The active execution task is the only safe parent for child facts without
/// session-creation provenance. Never assign every unknown-source task to the
/// currently visible chat.
enum ChatInspectorTaskScope {
    /// Shared capture used by ContentView and production-consumer tests. The
    /// inspector still receives values and owns no mutable store or observer.
    @MainActor
    static func capture(bridge: BridgeStore, viewerSessionID sessionID: String?,
                        currentTaskID: String?) -> (taskSnapshots: [AgentTaskSnapshot], receiptRows: [TaskCenterReceiptRow]) {
        _ = bridge.chat.toolLifecyclePresentationRevision
        let taskObservation = bridge.taskCenterObservation
        let taskSnapshots = taskObservation.taskSnapshots.filter {
            ChatInspectorTaskScope.includes(
                sourceSessionID: $0.sourceSessionID,
                taskID: $0.taskID,
                parentID: $0.parentID,
                viewerSessionID: sessionID,
                currentTaskID: currentTaskID
            )
        }
        let allReceiptRows = bridge.taskCenterControlConsumer.receiptRows(
            now: Date(),
            includeArchived: false
        )
        let sessionReceiptRows = allReceiptRows.filter {
            ChatInspectorTaskScope.includes(
                sourceSessionID: $0.sourceSessionID,
                taskID: $0.taskID,
                parentID: $0.parentID,
                viewerSessionID: sessionID,
                currentTaskID: currentTaskID
            ) || (currentTaskID == nil && sessionID != nil
                && $0.childNavigation?.locator != nil
                && $0.childNavigation?.parentSessionID == sessionID)
        }
        return (taskSnapshots, sessionReceiptRows)
    }

    static func includes(
        sourceSessionID: String?,
        taskID: String,
        parentID: String,
        viewerSessionID: String?,
        currentTaskID: String?
    ) -> Bool {
        guard let viewerSessionID else { return false }
        if sourceSessionID == viewerSessionID { return true }
        guard sourceSessionID == nil, let currentTaskID else { return false }
        return taskID == currentTaskID || parentID == currentTaskID
    }
}

/// Read-only construction metadata for the exact ordinary chat turn. Task
/// receipts are not produced by ordinary chat and are not an identity source.
enum ChatInspectorContextConsumer {
    static func capture(
        store: ContextManifestStore, sessionID: String?, turnID: Int?,
        executionIdentity: AgentExecutionIdentity? = nil, explicitRunID: String? = nil
    ) -> ChatInspectorContextSummary? {
        guard let sessionID, !sessionID.isEmpty, let turnID, turnID >= 0 else { return nil }
        if let executionIdentity {
            guard executionIdentity.isValid,
                  executionIdentity.turn.sessionID == sessionID,
                  executionIdentity.turn.turnID == turnID else { return nil }
        }
        let runID: String
        if let explicitRunID {
            guard !explicitRunID.isEmpty else { return nil }
            runID = explicitRunID
        } else if let executionIdentity {
            guard let generated = try? AgentLoopChatEngine.generatedContextManifestRunID(for: executionIdentity) else { return nil }
            runID = generated
        } else {
            runID = "chat:\(sessionID):\(turnID)"
        }
        guard let manifest = store.manifest(runID: runID),
              let receipt = store.receipt(runID: runID),
              receipt.runID == runID,
              manifest.snapshot.sessionID == sessionID,
              manifest.snapshot.conversationID == sessionID,
              manifest.snapshot.snapshotID == manifest.snapshot.canonicalSnapshotID() else { return nil }
        if let scope = manifest.scopeIdentity {
            do { try store.validate(manifest: manifest, for: scope) }
            catch { return nil }
        }
        return ChatInspectorContextSummary(runID: runID, turnID: turnID,
                                           snapshot: manifest.snapshot,
                                           entries: manifest.entries, receipt: receipt)
    }
}

// MARK: - 主窗口内容：Codex 风格三栏（会话侧栏 / 聊天↔画布主区 / 上下文面板）+ 顶部工具栏 + 底部状态行

/// 主窗口布局模式：并排（三栏）/ 画布独占 / 聊天独占
/// （CommandPalette 仍引用这三个 case；E14 下 .split = 完整三栏）
enum LayoutMode: String, CaseIterable, Identifiable {
    case split = "并排"
    case canvas = "画布"
    case chat = "聊天"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .split: return "rectangle.split.2x1"
        case .canvas: return "square.grid.2x2"
        case .chat: return "bubble.left.and.bubble.right"
        }
    }
}

/// 中间主区视图：聊天 / 画布（工具栏分段切换 + ⌘1/⌘2）
/// 2026-08-06 用户定案：工作板块整体移除（文档工作并入对话，对话右侧文件选择已覆盖）
enum MainPane: String, CaseIterable, Identifiable {
    case chat = "聊天"
    case canvas = "画布"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .canvas: return "square.grid.2x2"
        }
    }
}

/// A stored Canvas choice is a display preference, never authority to create
/// the optional runtime. Phase 3 renders Chat from the first body evaluation.
enum CanvasViewAdmission {
    static func layout(_ requested: LayoutMode, canvasAvailable: Bool) -> LayoutMode {
        guard !canvasAvailable, requested == .canvas else { return requested }
        return .chat
    }

    static func pane(_ requested: MainPane, canvasAvailable: Bool) -> MainPane {
        canvasAvailable ? requested : .chat
    }

    static func panes(canvasAvailable: Bool) -> [MainPane] {
        canvasAvailable ? MainPane.allCases : [.chat]
    }
}

/// D-APP-06（口径裁定 20260925：分段切换应当记入导航历史；依据=返回按钮帮助
/// 文字“切换主视图历史”，⌘1/⌘2 与点击是同一用户意图）：纯栈迁移函数，可单测。
/// 背景：分段 Picker 的 selection 绑定由 SwiftUI 先直写 mainPane、后触发
/// onChange 回流；此刻 ContentView.pushPane 的 `guard pane != mainPane`
/// 恒拦 ⇒ 不入栈、返回按钮恒禁用。本函数执行与 pushPane 相同的“截断+追加”
/// 迁移，但防重入改用回流的旧值/新值判定：
/// - 仅当索引有效且栈与旧值同写（stack[index] == oldPane）且 oldPane != newPane
///   时入栈；
/// - ⌘1/⌘2 路径已由 pushPane 先行入栈，回流时栈顶 == newPane ≠ oldPane ⇒ nil，
///   不重复入栈（不回归）；
/// - goBack/goForward/持久化恢复回流时栈顶 == newPane ⇒ nil。
enum MainPaneNavHistory {
    static func applyingSelection(
        stack: [MainPane],
        index: Int,
        oldPane: MainPane,
        newPane: MainPane
    ) -> (stack: [MainPane], index: Int)? {
        guard oldPane != newPane,
              index >= 0,
              index < stack.count,
              stack[index] == oldPane
        else { return nil }
        let pushed = Array(stack[...index]) + [newPane]
        return (pushed, pushed.count - 1)
    }
}

/// U1 布局策略（纯函数，可单测）：画布视图 = 「主内容 + 左侧伴随对话栏」，
/// 底部全局对话条隐藏（输入移入伴随栏）；F11-ui：聊天视图输入框移入中间分栏
/// （与消息区同容器同宽）。
/// B17（2026-08-06 重新梳理）：文档视图不再使用伴随对话栏——文档工作区是
/// 「打开文件 / 多 Tab / 编辑预览」场景，塞对话栏导致四栏嵌套挤压（会话侧栏
/// 240 + 伴随栏 310 + 文档 420 + 右栏 240 = 1210 > 窗口 960，输入框被挤没、
/// 分隔条拉不动）。文档模式输入统一走底部全局通栏（showsGlobalComposer）。
enum LayoutPolicy {
    /// 是否使用左侧伴随对话栏（画布独占 / 三栏主区切到画布）→ 隐藏底部全局对话条。
    /// B17：documents 不再包含（文档模式用底部通栏输入）。
    static func usesCompanionChat(layoutMode: LayoutMode, mainPane: MainPane) -> Bool {
        layoutMode == .canvas
            || (layoutMode == .split && mainPane == .canvas)
    }

    /// 是否显示底部全局对话条。聊天模式输入框已移入中间分栏；画布模式输入在伴随栏内。
    /// 2026-08-06：工作板块整体移除后已无底部通栏场景 → 恒 false（底部块已删）。
    static func showsGlobalComposer(layoutMode: LayoutMode, mainPane: MainPane) -> Bool {
        false
    }
}

/// P3-UI-01/P3-UI-03：主聊天表面只调整外圈留白，不改变 ChatStore、消息
/// 投影或 Composer 状态。它与 AdaptiveLayoutPolicy 使用同一组 600–1600pt
/// 宽度类，保证空状态、消息区和输入区在窄窗仍共享一条可读的 Keyline。
struct ChatSurfaceLayoutMetrics: Equatable, Sendable {
    let widthClass: AdaptiveWidthClass
    /// Shared outer Keyline for transcript and Composer; never apply this to
    /// only one of the two surfaces or their leading edges drift.
    let surfaceGutter: CGFloat
    let minimumContentWidth: CGFloat

    static func forWidth(_ width: CGFloat) -> Self {
        let globalMinimum = CGFloat(AdaptiveLayoutPolicy.minimumSupportedWidth)
        // This is the width allocated to the chat pane, after persistent
        // sidebars. An unmeasured pane retains the existing initial contract.
        let allocatedWidth = width.isFinite && width > 0 ? width : globalMinimum
        let boundedWidth = max(allocatedWidth, globalMinimum)
        let minimumContentWidth = min(allocatedWidth, globalMinimum)
        let widthClass = AdaptiveLayoutPolicy.widthClass(for: Double(boundedWidth))
        switch widthClass {
        case .compact:
            return Self(
                widthClass: widthClass,
                surfaceGutter: 0,
                minimumContentWidth: minimumContentWidth
            )
        case .medium:
            return Self(
                widthClass: widthClass,
                surfaceGutter: 4,
                minimumContentWidth: minimumContentWidth
            )
        case .regular:
            return Self(
                widthClass: widthClass,
                surfaceGutter: 8,
                minimumContentWidth: minimumContentWidth
            )
        case .wide:
            return Self(
                widthClass: widthClass,
                surfaceGutter: 12,
                minimumContentWidth: minimumContentWidth
            )
        }
    }
}

private struct ChatComposerHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// AJ-23：侧栏宽度记忆模型（纯逻辑，可单测）。
/// 折叠前记住用户请求宽度，展开时恢复；窗口可用空间只在布局策略中夹取
/// effective width，不覆盖用户记忆，避免 resize 后永久丢失偏好。
struct SidebarWidthMemory {
    static let minWidth: Double = 56
    static let defaultWidth: Double = 240

    /// 当前应该使用的宽度（折叠中为 0，展开为记忆宽度）
    var width: Double
    /// 折叠前记住的宽度（展开时恢复）
    var rememberedWidth: Double

    init(width: Double = SidebarWidthMemory.defaultWidth,
         rememberedWidth: Double? = nil) {
        let w = Self.normalized(width)
        self.width = w
        // 记忆宽度缺省时跟随当前宽度（构造只传 width 时二者一致，避免
        // 「宽度 300 记忆 240」的不一致态；显式传 rememberedWidth 则夹取后采用）
        self.rememberedWidth = Self.normalized(rememberedWidth ?? w)
    }

    private static func normalized(_ width: Double) -> Double {
        guard width.isFinite else { return defaultWidth }
        return max(minWidth, width)
    }

    var isCollapsed: Bool { width == 0 }

    /// 折叠：记住当前宽度并置 0
    mutating func collapse() {
        rememberedWidth = width
        width = 0
    }

    /// 展开：恢复到记忆宽度
    mutating func expand() {
        width = rememberedWidth
    }

    /// 拖拽调整：只保证最小可用宽度；最大值由当前 layout policy 动态决定。
    mutating func resize(to newWidth: Double) {
        width = Self.normalized(newWidth)
        rememberedWidth = width
    }

    mutating func resize(to newWidth: Double, within visibleRange: ClosedRange<Double>) {
        guard newWidth.isFinite else { return }
        resize(to: newWidth.clamped(to: visibleRange))
    }

    /// 重新载入持久化宽度（若未折叠则应用）
    mutating func loadPersisted(_ persisted: Double) {
        let clamped = Self.normalized(persisted)
        if !isCollapsed {
            width = clamped
        }
        rememberedWidth = clamped
    }

    /// AJ-69：统一折叠状态机入口（全界面隐藏/折叠按钮共用）。
    mutating func toggle() {
        if isCollapsed {
            expand()
        } else {
            collapse()
        }
    }
}

/// 右侧上下文栏横向拖拽状态。右栏位于 trailing 侧，手柄向左移动时宽度增加。
struct ContextPanelWidthDragState: Equatable {
    static let settingsKey = "minisCanvas.contextPanelWidth"
    private(set) var width: Double
    private(set) var dragStartWidth: Double?

    init(width: Double = 300) {
        self.width = SidebarWidthMemory(width: width).width
        self.dragStartWidth = nil
    }

    init(defaults: UserDefaults) {
        self.init(width: (defaults.object(forKey: Self.settingsKey) as? NSNumber)?.doubleValue ?? 300)
    }

    /// Shared by ContentView's real handle and headless preference consumers.
    /// The trailing panel grows when the pointer moves to the left.
    mutating func applyPersistedTranslation(
        _ translation: Double,
        visibleWidth: Double? = nil,
        visibleRange: ClosedRange<Double>? = nil,
        defaults: UserDefaults
    ) {
        guard translation.isFinite else { return }
        if dragStartWidth == nil {
            beginDrag(visibleWidth: visibleWidth)
        }
        apply(-translation)
        if let visibleRange {
            width = width.clamped(to: visibleRange)
        }
        defaults.set(width, forKey: Self.settingsKey)
    }

    /// AX/keyboard adjustment uses the same width and preference as pointer drag.
    /// End any in-flight pointer origin so its next translation cannot undo this step.
    mutating func adjustPersisted(by delta: Double, defaults: UserDefaults) {
        guard delta.isFinite else { return }
        endDrag()
        var memory = SidebarWidthMemory(width: width)
        memory.resize(to: width + delta)
        width = memory.width
        defaults.set(width, forKey: Self.settingsKey)
    }

    mutating func beginDrag(visibleWidth: Double? = nil) {
        if dragStartWidth == nil {
            dragStartWidth = visibleWidth.flatMap { $0.isFinite ? $0 : nil } ?? width
        }
    }

    mutating func apply(_ delta: Double) {
        guard let start = dragStartWidth else { return }
        var memory = SidebarWidthMemory(width: start)
        memory.resize(to: start + delta)
        width = memory.width
    }

    mutating func endDrag() {
        dragStartWidth = nil
    }
}

extension Comparable {
    /// 夹取到闭区间 [range.lowerBound, range.upperBound]
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// D-OUTPUT-02: the action history is global, while this inspector shows one session.
/// Only the identity captured in the original tool task can assign a file change
/// to that session. Old or unbound records stay outside every session panel.
enum ChatInspectorFileChangeConsumer {
    static func changes(
        from records: [ActionRecord],
        viewerSessionID: String?,
        limit: Int
    ) -> [AgentFileChangeRecord] {
        guard let viewerSessionID, !viewerSessionID.isEmpty else { return [] }
        let matched = records
            .filter { $0.sourceSessionID == viewerSessionID }
            .compactMap(\.fileChange)
        return Array(matched.suffix(max(0, limit)))
    }
}

struct PendingAttachmentPreviewRequest: Equatable {
    let attachmentID: UUID
    let requestID: UUID
}

enum PendingAttachmentPreviewLifecycle {
    static func selectionAfterRemoval(
        _ selection: ChatAttachmentPreviewSelection?,
        removedRequest: PendingAttachmentPreviewRequest
    ) -> ChatAttachmentPreviewSelection? {
        selection?.requestID == removedRequest.requestID ? nil : selection
    }
}

enum AssetPanelContent: Equatable {
    case canvasMedia
    case chatFiles
}

struct ContentView: View {
    /// Same entry decision used by the toolbar and presented asset content.
    static func assetPanelContent(canvasAvailable: Bool, isCanvasActive: Bool) -> AssetPanelContent? {
        canvasAvailable && isCanvasActive ? .canvasMedia : .chatFiles
    }

    @Bindable var bridge: BridgeStore
    /// Canonical Settings owner for transcript redaction. The view must not
    /// instantiate a second EnvVarStore while projecting chat content.
    var transcriptEnvStore: EnvVarStore? = nil
    /// AJ-61：设置中心 sheet 触发闭包（App 层持有同一 sheet state，工具栏齿轮 / ⌘, / 深链统一）。
    var openSettings: () -> Void = {}
    @Environment(\.themeTokens) private var theme
    @Environment(SettingsCenter.self) private var settingsCenter: SettingsCenter?
    @Environment(\.typographyTokens) private var typography

    @State private var showEnvironmentNotice = false
    @State private var showModelShellEnvironmentFailure = false
    /// 左栏会话侧栏是否折叠为 0 宽完全隐藏（⌘⇧C 或侧栏内按钮切换；F5-ui：不再留 56px 图标栏）
    @State private var sessionSidebarCollapsed = false
    /// AJ-23：侧栏宽度记忆——折叠前记住当前宽度，展开恢复原宽度；拖拽调整并持久化。
    /// P3-P1-03：该键的读取/验证/持久化统一走 SessionSidebarWidthContract 唯一网关，
    /// 前端不再持有私有 @AppStorage 键绑定（合同矩阵见 SessionSidebarWidthContract.swift）。
    @State private var sidebarWidthSetting: SessionSidebarWidthSetting
    /// 生效值只读投影：既有消费点保持此名；写入必须走 `sidebarWidthSetting.write`。
    private var storedSidebarWidth: Double { sidebarWidthSetting.storedWidth }
    /// A7-A：用户显式折叠意图持久化；自动窄窗折叠不写入此值。
    @AppStorage("minisCanvas.sessionSidebarCollapsed") private var storedSessionSidebarCollapsed: Bool = false
    /// AJ-23：展开时实际使用的宽度（折叠时保留记忆值，不被置 0 覆盖）
    @State private var sidebarWidth: Double = SidebarWidthMemory.defaultWidth
    /// AJ-23：折叠前记住的宽度（展开时恢复）
    @State private var rememberedSidebarWidth: Double = SidebarWidthMemory.defaultWidth
    /// AJ-23：拖拽起点宽度（用于增量计算）
    @State private var dragStartWidth: Double = 0
    /// B13：拖拽手柄 NSCursor push/pop 配对保护（拖拽中滑出手柄区 onHover pop + onEnded pop 双 pop 会栈下溢崩溃）
    @State private var sidebarCursorPushed = false
    /// AJ-60：伴随对话栏（画布/文档视图左侧）折叠状态（栏内按钮隐藏，主区左上浮动按钮恢复）
    @State private var companionCollapsed = false
    /// AJ-60：伴随栏宽度记忆——复用 SidebarWidthMemory 夹取逻辑 + 独立 @AppStorage key，重启/进出会话后恢复
    @AppStorage("minisCanvas.companionWidth") private var storedCompanionWidth: Double = 310
    /// AJ-60：伴随栏展开时实际使用的宽度（折叠时保留记忆值，不被置 0 覆盖）
    @State private var companionWidth: Double = 310
    /// AJ-60：伴随栏折叠前记住的宽度（展开时恢复）
    @State private var rememberedCompanionWidth: Double = 310
    /// AJ-60：伴随栏拖拽起点宽度（用于增量计算）
    @State private var companionDragStartWidth: Double = 0
    /// B13：伴随栏拖拽手柄 NSCursor push/pop 配对保护
    @State private var companionCursorPushed = false
    /// 右栏上下文面板是否展示（⌥⌘→ / 工具栏按钮 / 面板内 ✕ 折叠、展开）
    @State private var showContextPanel = true
    /// AJ-69：右栏上下文面板宽度记忆——复用 SidebarWidthMemory 夹取逻辑 + 独立 @AppStorage key，
    /// 与主侧栏/伴随栏同一套折叠状态机（折叠=记忆宽度置 0，展开=恢复记忆宽度并夹取 [min,max]）
    @AppStorage("minisCanvas.contextPanelWidth") private var storedContextPanelWidth: Double = 300
    /// A7-A：右栏用户显式折叠意图持久化；自动窄窗折叠不写入此值。
    @AppStorage("minisCanvas.contextPanelCollapsed") private var storedContextPanelCollapsed: Bool = false
    /// 右栏展开时实际使用的宽度（折叠时保留记忆值，不被置 0 覆盖）
    @State private var contextPanelWidth: Double = 300
    /// 右栏折叠前记住的宽度（展开时恢复）
    @State private var rememberedContextPanelWidth: Double = 300
    @State private var contextPanelDragState = ContextPanelWidthDragState(width: 300)
    @State private var contextPanelCursorPushed = false
    /// 当前聊天附件的右侧应用内预览目标，随来源会话失效。
    @State private var attachmentPreviewSelection: ChatAttachmentPreviewSelection?
    /// Only identifies a preview opened from the unsent draft. Its requestID
    /// prevents removal from closing a newer sent-file or Agent preview.
    @State private var pendingAttachmentPreview: PendingAttachmentPreviewRequest?
    @State private var attachmentPreviewError: String?
    /// Ordinary Chat asset visibility is independent of the context panel.
    @State private var chatAssetPanelPresented = false
    /// 任务中心只读投影面板。
    @State private var taskCenterPresented = false
    @State private var taskCenterDocked = false
    @State private var contextShowsTasks = false
    @State private var availableTaskCenterWidth: CGFloat = 0
    // Keep the modal slot occupied until onDismiss, rather than scheduling a
    // second sheet after an arbitrary Task.yield or fixed delay.
    @State private var taskCenterPresentationActive = false
    @State private var pendingApprovalTaskCenterID: String?
    @State private var taskCenterOpenerFocus = TaskCenterOpenerFocus()
    @FocusState private var taskCenterEntryFocused: Bool
    @AccessibilityFocusState private var taskCenterEntryAccessibilityFocused: Bool
    @State private var taskCenterInitialSelectionID: String?
    /// Sheet-local child route; the parent ChatStore session is never switched.
    @State private var taskCenterChildNavigation: TaskCenterChildSessionNavigation?
    /// Older canonical tool summaries load only on request, keyed by viewer session.
    @State private var toolEventPageState = ChatInspectorToolEventPageState()
    /// 中间主区当前视图（聊天 / 画布）
    @State private var mainPane: MainPane = .chat
    /// A7-A：主视图选择跨 view 重建恢复，只保存稳定的 enum raw value。
    @AppStorage("minisCanvas.mainPane") private var storedMainPaneRawValue: String = MainPane.chat.rawValue
    /// A7-A：自适应布局 reducer 状态；自动折叠与用户显式折叠分离。
    @State private var adaptiveLayoutState = AdaptiveLayoutState()
    /// The compact drawers stop above the live Composer, including its
    /// typography- and draft-dependent height.
    @State private var chatComposerHeight = ChatLayoutMetrics.composerMinimumHeight
    /// Codex 风格导航历史（返回/前进切换主视图）
    @State private var navStack: [MainPane] = [.chat]
    @State private var navIndex = 0

    @MainActor
    init(
        bridge: BridgeStore,
        transcriptEnvStore: EnvVarStore? = nil,
        openSettings: @escaping () -> Void = {}
    ) {
        self.bridge = bridge
        self.transcriptEnvStore = transcriptEnvStore
        self.openSettings = openSettings
        let defaults = bridge.preferencesDefaults
        _sidebarWidthSetting = State(
            initialValue: bridge.sidebarWidthSetting
        )
        _storedCompanionWidth = AppStorage(
            wrappedValue: 310,
            "minisCanvas.companionWidth",
            store: defaults
        )
        _storedContextPanelWidth = AppStorage(
            wrappedValue: 300,
            "minisCanvas.contextPanelWidth",
            store: defaults
        )
        _storedSessionSidebarCollapsed = AppStorage(
            wrappedValue: false,
            "minisCanvas.sessionSidebarCollapsed",
            store: defaults
        )
        _storedContextPanelCollapsed = AppStorage(
            wrappedValue: false,
            "minisCanvas.contextPanelCollapsed",
            store: defaults
        )
        _storedMainPaneRawValue = AppStorage(
            wrappedValue: MainPane.chat.rawValue,
            "minisCanvas.mainPane",
            store: defaults
        )
    }

    private var canvasAvailable: Bool { bridge.canvasIfAvailable != nil }

    private var visibleLayoutMode: LayoutMode {
        CanvasViewAdmission.layout(bridge.layoutMode, canvasAvailable: canvasAvailable)
    }

    private var visibleMainPane: MainPane {
        CanvasViewAdmission.pane(mainPane, canvasAvailable: canvasAvailable)
    }

    /// AJ-57：读快捷键 Store 的绑定（动态绑定，改设置即生效）。
    private func shortcut(_ action: ShortcutAction) -> ShortcutBinding {
        bridge.shortcutStore.binding(for: action)
    }

    // MARK: AJ-23 侧栏宽度记忆 / 恢复 / 拖拽持久化

    /// 当前侧栏实际宽度（折叠=0，展开=记忆宽度）。读取时惰性从持久化载入一次。
    private var effectiveSidebarWidth: Double {
        sessionSidebarCollapsed ? 0 : max(SidebarWidthMemory.minWidth, sidebarWidth)
    }

    /// 折叠：记住当前宽度 → 置 0 → 持久化
    /// B5：宽度异常（≤0，如折叠态拖拽残留）时兜底到默认宽度，避免记住 56 窄列导致「恢复后很窄」
    private func collapseSidebar() {
        let w = sidebarWidth > 0 ? sidebarWidth : SidebarWidthMemory.defaultWidth
        sidebarWidth = SidebarWidthMemory(width: w).width
        rememberedSidebarWidth = sidebarWidth
        sessionSidebarCollapsed = true
        storedSessionSidebarCollapsed = true
        adaptiveLayoutState = AdaptiveLayoutReducer.reduce(
            adaptiveLayoutState,
            .userSetSessionSidebarCollapsed(true)
        )
        sidebarWidthSetting.write(sidebarWidth)
    }

    /// 展开：恢复到记忆宽度；窗口可用空间由 AdaptiveLayoutPolicy 临时夹取。
    private func expandSidebar() {
        sidebarWidth = max(rememberedSidebarWidth, SidebarWidthMemory.minWidth)
        sessionSidebarCollapsed = false
        storedSessionSidebarCollapsed = false
        adaptiveLayoutState = AdaptiveLayoutReducer.reduce(
            adaptiveLayoutState,
            .userSetSessionSidebarCollapsed(false)
        )
        if adaptiveLayoutState.widthClass == .compact {
            adaptiveLayoutState = AdaptiveLayoutReducer.reduce(
                adaptiveLayoutState,
                .compactOverlayOpened(.sessionSidebar)
            )
            syncAdaptiveLayoutProjection()
        }
    }

    /// 切换折叠/展开（工具栏按钮 / ⌘⇧C / 侧栏内按钮共用）
    private func toggleSidebar() {
        if sessionSidebarCollapsed {
            expandSidebar()
        } else {
            collapseSidebar()
        }
    }

    /// 拖拽调整宽度：增量应用并夹取 [min, max]，同步持久化
    private func applySidebarDrag(
        _ translation: Double,
        visibleRange: ClosedRange<Double>
    ) {
        var memory = SidebarWidthMemory(width: dragStartWidth)
        memory.resize(to: dragStartWidth + translation, within: visibleRange)
        sidebarWidth = memory.width
        sidebarWidthSetting.write(memory.width)
    }

    // MARK: AJ-60 伴随对话栏宽度记忆 / 隐藏 / 拖拽持久化（复用 SidebarWidthMemory 逻辑 + 独立 @AppStorage key）

    /// 当前伴随栏请求宽度（折叠=0，展开=记忆宽度）。窗口可用空间由
    /// DeterministicSplitView 临时夹取，不覆盖 remembered width。
    private var effectiveCompanionWidth: Double {
        companionCollapsed ? 0 : max(SidebarWidthMemory.minWidth, companionWidth)
    }

    /// 隐藏伴随栏：记住当前宽度 → 置 0 → 持久化（展开时恢复记忆宽度）
    /// B5：宽度异常（≤0）时兜底到默认宽度，避免恢复成窄列
    private func collapseCompanion() {
        let w = companionWidth > 0 ? companionWidth : 310
        companionWidth = SidebarWidthMemory(width: w).width
        rememberedCompanionWidth = companionWidth
        companionCollapsed = true
        storedCompanionWidth = companionWidth
    }

    /// 恢复伴随栏：恢复到记忆宽度；实际 pane 宽度由 split geometry 临时夹取。
    private func expandCompanion() {
        companionWidth = max(rememberedCompanionWidth, SidebarWidthMemory.minWidth)
        companionCollapsed = false
    }

    /// 切换隐藏/恢复（栏内隐藏按钮 / 主区左上浮动恢复按钮共用）
    private func toggleCompanion() {
        if companionCollapsed {
            expandCompanion()
        } else {
            collapseCompanion()
        }
    }

    // MARK: AJ-69 右栏上下文面板折叠状态机（与主侧栏/伴随栏同一套逻辑：记忆宽度 + [min,max] 夹取 + 持久化）

    /// 右栏请求宽度（折叠=0，展开=记忆宽度）。实际 pane 宽度由 policy/split 临时夹取。
    private var effectiveContextPanelWidth: Double {
        showContextPanel ? max(SidebarWidthMemory.minWidth, contextPanelWidth) : 0
    }

    private func applyContextPanelDrag(
        _ translation: Double,
        visibleWidth: Double,
        visibleRange: ClosedRange<Double>
    ) {
        contextPanelDragState.applyPersistedTranslation(
            translation,
            visibleWidth: visibleWidth,
            visibleRange: visibleRange,
            defaults: bridge.preferencesDefaults
        )
        contextPanelWidth = contextPanelDragState.width
        rememberedContextPanelWidth = contextPanelWidth
        storedContextPanelWidth = contextPanelWidth
    }

    private func adjustContextPanelWidth(by delta: Double) {
        contextPanelDragState.adjustPersisted(by: delta, defaults: bridge.preferencesDefaults)
        contextPanelWidth = contextPanelDragState.width
        rememberedContextPanelWidth = contextPanelWidth
        storedContextPanelWidth = contextPanelWidth
    }

    private func endContextPanelDrag() {
        contextPanelDragState.endDrag()
        if contextPanelCursorPushed {
            NSCursor.pop()
            contextPanelCursorPushed = false
        }
    }

    /// 折叠右栏：记住当前宽度 → 置 0 → 持久化（展开时恢复记忆宽度）
    /// B5：宽度异常（≤0）时兜底到默认宽度，避免恢复成窄列
    private func collapseContextPanel() {
        let w = contextPanelWidth > 0 ? contextPanelWidth : 300
        contextPanelWidth = SidebarWidthMemory(width: w).width
        rememberedContextPanelWidth = contextPanelWidth
        showContextPanel = false
        storedContextPanelCollapsed = true
        adaptiveLayoutState = AdaptiveLayoutReducer.reduce(
            adaptiveLayoutState,
            .userSetContextPanelCollapsed(true)
        )
        storedContextPanelWidth = contextPanelWidth
    }

    /// 展开右栏：恢复到记忆宽度；实际 pane 宽度由 policy 临时夹取。
    private func expandContextPanel() {
        let w = rememberedContextPanelWidth > 0 ? rememberedContextPanelWidth : 300
        contextPanelWidth = max(SidebarWidthMemory.minWidth, w)
        showContextPanel = true
        storedContextPanelCollapsed = false
        adaptiveLayoutState = AdaptiveLayoutReducer.reduce(
            adaptiveLayoutState,
            .userSetContextPanelCollapsed(false)
        )
        if adaptiveLayoutState.widthClass == .compact {
            adaptiveLayoutState = AdaptiveLayoutReducer.reduce(
                adaptiveLayoutState,
                .compactOverlayOpened(.contextPanel)
            )
            syncAdaptiveLayoutProjection()
        }
    }

    /// 切换右栏折叠/展开（工具栏按钮 / ⌥⌘→ 快捷键 / 面板内 ✕ 共用）
    private func toggleContextPanel() {
        if showContextPanel {
            collapseContextPanel()
        } else {
            expandContextPanel()
        }
    }

    /// A7-A：只同步 reducer 的展示投影，不通过自动折叠路径写回用户宽度。
    private func syncAdaptiveLayoutProjection() {
        sessionSidebarCollapsed = adaptiveLayoutState.sessionSidebarCollapsed
        showContextPanel = adaptiveLayoutState.contextPanelVisible
    }

    /// 拖拽调整伴随栏宽度：增量应用并夹取 [min, max]，同步持久化
    private func applyCompanionDrag(_ translation: Double) {
        var memory = SidebarWidthMemory(width: companionDragStartWidth)
        memory.resize(to: companionDragStartWidth + translation)
        companionWidth = memory.width
        storedCompanionWidth = memory.width
    }

    /// AX/keyboard equivalent for the pointer-only width drag handle.
    private func adjustCompanionWidth(by delta: Double) {
        var memory = SidebarWidthMemory(width: effectiveCompanionWidth)
        memory.resize(to: effectiveCompanionWidth + delta)
        companionWidth = memory.width
        rememberedCompanionWidth = memory.width
        storedCompanionWidth = memory.width
    }

    /// AJ-60：伴随对话栏窗格（画布独占 / 三栏画布 / 三栏文档共用）。
    /// 宽度由记忆状态驱动：折叠时 0 宽完全隐藏（视图树稳定，同主侧栏 F5-ui 策略），
    /// 展开时 idealWidth = 记忆宽度，拖拽手柄叠在右缘（分隔条位置）。
    private var companionChatPane: some View {
        CompanionChatView(
            chat: bridge.chat,
            bridge: bridge,
            transcriptEnvStore: transcriptEnvStore,
            collapsed: companionCollapsed,
            onToggleCollapse: { toggleCompanion() },
            onOpenAttachment: openAttachmentInContextPanel
        )
        .frame(
            // AJ-69：折叠时 0 宽（DeterministicSplitView 对 w < 1 不渲染）——
            // 旧值 1 是 HSplitView 时代的残留（NSSplitView 要求最小宽 > 0），
            // 在 w=1 的边界上会渲染出 1px 残留条，与「折叠=0 宽完全隐藏」契约冲突
            minWidth: companionCollapsed ? 0 : SidebarWidthMemory.minWidth,
            idealWidth: companionCollapsed ? 0 : effectiveCompanionWidth,
            maxWidth: companionCollapsed ? 0 : .infinity
        )
        .clipped()
        .layoutPriority(1)
        // AJ-60：伴随栏右侧拖拽手柄（调整宽度，夹取 [min,max] 并持久化）
        .overlay(alignment: .trailing) {
            if !companionCollapsed {
                companionWidthDragHandle
            }
        }
    }

    /// AJ-60：伴随栏右侧拖拽手柄（窄条，横向拖拽调整宽度）。
    /// 起点 = 当前展开宽度，增量 = translation.width，经 SidebarWidthMemory 夹取 [min, max] 并持久化。
    private var companionWidthDragHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .frame(width: AdaptiveDividerNativeContract.handleWidth)
            .onHover { inside in
                if inside && !companionCursorPushed {
                    NSCursor.resizeLeftRight.push()
                    companionCursorPushed = true
                } else if !inside && companionCursorPushed {
                    NSCursor.pop()
                    companionCursorPushed = false
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if companionDragStartWidth == 0 {
                            companionDragStartWidth = effectiveCompanionWidth
                        }
                        applyCompanionDrag(value.translation.width)
                    }
                    .onEnded { _ in
                        companionDragStartWidth = 0
                        if companionCursorPushed {
                            NSCursor.pop()
                            companionCursorPushed = false
                        }
                    }
            )
            .help("拖拽调整伴随栏宽度")
            .accessibilityIdentifier("companion.width")
            .accessibilityLabel("调整伴随栏宽度")
            .accessibilityValue("宽度 \(Int(effectiveCompanionWidth)) 点")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    adjustCompanionWidth(by: 24)
                case .decrement:
                    adjustCompanionWidth(by: -24)
                @unknown default:
                    break
                }
            }
    }

    /// AJ-60：伴随栏折叠后主区左上浮动恢复入口（24x24 小按钮 + 浅色圆角背景，同 F13-ui 主侧栏样式）。
    /// 由伴随栏所在 HSplitView 的 overlay(alignment: .topLeading) 渲染；点击恢复记忆宽度。
    private var companionRestoreFloatingButton: some View {
        Button {
            expandCompanion()
        } label: {
            MinisIconView(.messages, size: 14)
                .foregroundPalette(theme?.aj38.accent.swiftUIColor ?? Color.accentColor)
                .font(.system(size: 12))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(theme?.aj38.backgroundSecondary.swiftUIColor ?? Color(nsColor: .controlBackgroundColor))
                        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                )
        }
        .buttonStyle(.plain)
        .padding(.leading, 8)
        .padding(.top, 8)
        .help("展开伴随对话栏")
        .transition(.opacity)
    }

    var body: some View {
        GeometryReader { geometry in
            let availableWidth = max(
                Double(geometry.size.width),
                AdaptiveLayoutPolicy.minimumSupportedWidth
            )
            let decision = AdaptiveLayoutPolicy.decision(
                for: availableWidth,
                preferredLeftWidth: effectiveSidebarWidth,
                preferredRightWidth: effectiveContextPanelWidth
            )

            VStack(spacing: 0) {
                toolbar(decision: decision)
                Divider()
                mainArea(decision: decision)
                    .onPreferenceChange(ChatComposerHeightPreferenceKey.self) { height in
                        if height > 0 { chatComposerHeight = height }
                    }
                    // F13-ui：侧栏折叠（0 宽完全隐藏）后，主区左上浮动恢复按钮——
                    // 聊天/画布两种 mainPane 通用；叠在 mainArea 外层，工具栏不受遮挡。
                    .overlay(alignment: .topLeading) {
                        // overlay 宽度类由工具栏按钮重新打开抽屉，不重复渲染浮动恢复按钮。
                        if sessionSidebarCollapsed,
                           visibleLayoutMode == .split,
                           decision.leftPanel != .overlay {
                            sidebarRestoreFloatingButton
                        }
                    }
                Divider()
                // U1：画布视图 = 主内容 + 左侧伴随对话栏（输入在伴随栏内），底部全局条隐藏；
                // F11-ui：聊天视图输入框移入中间分栏（与消息区同容器同宽）。
                statusBar
            }
            .onAppear { availableTaskCenterWidth = geometry.size.width }
            .onChange(of: geometry.size.width) { _, width in
                availableTaskCenterWidth = width
                if taskCenterDocked && width < 1100 {
                    taskCenterDocked = false
                    taskCenterPresented = true
                }
            }
            .onChange(of: storedSidebarWidth) { _, committed in
                // Typed settings edit and manual drag share the same gateway.
                // Only a committed width updates the live layout projection.
                sidebarWidth = SidebarWidthMemory(width: committed).width
                rememberedSidebarWidth = sidebarWidth
            }
            .onAppear {
                // 先完成三组持久化宽度载入，再允许 reducer 施加窗口宽度策略；
                // 自动折叠只改变展示投影，不覆盖用户保存的宽度。
                sidebarWidth = SidebarWidthMemory(width: storedSidebarWidth).width
                rememberedSidebarWidth = sidebarWidth
                companionWidth = SidebarWidthMemory(width: storedCompanionWidth).width
                rememberedCompanionWidth = companionWidth
                contextPanelWidth = SidebarWidthMemory(width: storedContextPanelWidth).width
                rememberedContextPanelWidth = contextPanelWidth
                contextPanelDragState = ContextPanelWidthDragState(defaults: bridge.preferencesDefaults)

                guard !adaptiveLayoutState.persistenceLoaded else { return }

                // A7-A：恢复用户显式布局意图后，再让 reducer 计算当前宽度类的
                // 自动投影；无效 raw value 安全回落到聊天，不污染导航历史。
                if !canvasAvailable && bridge.layoutMode == .canvas {
                    bridge.layoutMode = .chat
                }
                let restoredPane = CanvasViewAdmission.pane(
                    MainPane(rawValue: storedMainPaneRawValue) ?? .chat,
                    canvasAvailable: canvasAvailable
                )
                mainPane = restoredPane
                navStack = [restoredPane]
                navIndex = 0
                if storedSessionSidebarCollapsed {
                    adaptiveLayoutState = AdaptiveLayoutReducer.reduce(
                        adaptiveLayoutState,
                        .userSetSessionSidebarCollapsed(true)
                    )
                }
                if storedContextPanelCollapsed {
                    adaptiveLayoutState = AdaptiveLayoutReducer.reduce(
                        adaptiveLayoutState,
                        .userSetContextPanelCollapsed(true)
                    )
                }

                adaptiveLayoutState = AdaptiveLayoutReducer.reduce(
                    adaptiveLayoutState,
                    .persistenceLoaded
                )
                adaptiveLayoutState = AdaptiveLayoutReducer.reduce(
                    adaptiveLayoutState,
                    .widthClassChanged(decision.widthClass)
                )
                syncAdaptiveLayoutProjection()
            }
            .onChange(of: decision.widthClass) { _, newWidthClass in
                guard adaptiveLayoutState.persistenceLoaded else { return }
                adaptiveLayoutState = AdaptiveLayoutReducer.reduce(
                    adaptiveLayoutState,
                    .widthClassChanged(newWidthClass)
                )
                syncAdaptiveLayoutProjection()
            }
            .onChange(of: bridge.chat.activeSessionID) { _, activeSessionID in
                attachmentPreviewSelection = attachmentPreviewSelection?.visible(in: activeSessionID)
                pendingAttachmentPreview = nil
                attachmentPreviewError = nil
            }
            .onChange(of: bridge.chat.pendingAttachments.map(\.id)) { _, pendingIDs in
                guard let pendingAttachmentPreview,
                      !pendingIDs.contains(pendingAttachmentPreview.attachmentID) else { return }
                attachmentPreviewSelection = PendingAttachmentPreviewLifecycle.selectionAfterRemoval(
                    attachmentPreviewSelection,
                    removedRequest: pendingAttachmentPreview
                )
                self.pendingAttachmentPreview = nil
            }
        }
        .font(typography?.body ?? .body)
        .frame(minWidth: AdaptiveLayoutPolicy.minimumSupportedWidth, minHeight: 620)
        // 半透明浮动右键菜单层（用户定案：背景透明度 50%、文字不透明）
        .overlay { FloatingMenuOverlay() }
        .overlay(alignment: .top) {
            if showEnvironmentNotice || showModelShellEnvironmentFailure {
                HStack(alignment: .top) {
                    Text(showModelShellEnvironmentFailure ? ModelShellEnvironment.failureMessage : SubprocessEnvironmentNotice.message)
                    Button("知道了") {
                        if showModelShellEnvironmentFailure { showModelShellEnvironmentFailure = false }
                        else { showEnvironmentNotice = false }
                    }
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding()
                .accessibilityElement(children: .contain)
            }
        }
        .onAppear {
            if SubprocessEnvironmentNotice.takePending() { showEnvironmentNotice = true }
            if ModelShellEnvironment.takePendingFailureNotice() { showModelShellEnvironmentFailure = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: SubprocessEnvironmentNotice.notification)) { _ in
            if SubprocessEnvironmentNotice.takePending() { showEnvironmentNotice = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelShellEnvironment.failureNotification)) { _ in
            if ModelShellEnvironment.takePendingFailureNotice() { showModelShellEnvironmentFailure = true }
        }
        .confirmationDialog("停止当前生成并压缩上下文？", isPresented: Binding(
            get: { bridge.chat.requiresCompactionConfirmation },
            set: { if !$0 { bridge.chat.cancelCompactionConfirmation() } }
        )) {
            Button("停止生成并压缩", role: .destructive) { _ = bridge.chat.confirmCompaction() }
            Button("取消", role: .cancel) { bridge.chat.cancelCompactionConfirmation() }
        } message: {
            Text("确认前会继续当前生成；确认后将停止当前生成并压缩上下文。")
        }
        .alert("无法在右侧面板预览附件", isPresented: Binding(
            get: { attachmentPreviewError != nil },
            set: { if !$0 { attachmentPreviewError = nil } }
        )) {
            Button("确定", role: .cancel) { attachmentPreviewError = nil }
        } message: {
            Text(attachmentPreviewError ?? "附件没有可用的文件来源。")
        }
        // 2026-08-06：HSplitView 结构/pane 宽度动画全部移除——AppKit 桥接上动画驱动
        // NSSplitView subview 宽度（约束动画）中途打断/结束未重排 = 折叠恢复后「一指宽」错乱，
        // 0 宽折叠 + 动画 = 布局异常崩溃（14:18-14:20 三次 .ips 实证）。改为瞬时切换，
        // HSplitView 直接重排到记忆宽度（AJ-23/AJ-60 宽度记忆在折叠前已存，展开即还原）。
        // 浮动恢复按钮淡入依赖的 transition(.opacity) 保留（无父动画时直接出现，功能优先）。
        .onReceive(NotificationCenter.default.publisher(for: .minisCanvasToggleSessionSidebar)) { _ in
            // AJ-69：仅 split 布局存在会话侧栏，避免 canvas/chat 布局下 ⌘⇧C/侧栏内按钮
            // 翻转一个不存在侧栏的折叠标志（标志与界面脱节）
            if bridge.layoutMode == .split {
                bridge.runCommand(id: "ui.sidebar.toggle")
            }
        }
        // 2026-08-06：minisCanvasSwitchToChat 通知（文档工作区返回聊天）随工作板块移除
        // C3-1：命令面板唤起；压缩快捷键也经现有注册命令执行。
        .background {
            ZStack {
                if let command = AppCommandMenuBuilder.command(
                    id: AppCommandCatalog.commandPaletteID, registry: bridge.commandRegistry,
                    display: bridge.paletteDisplay
                ) {
                    Button("") { bridge.runCommand(id: command.id) }
                        .shortcutKey(shortcut(.commandPalette))
                        .disabled(!command.isEnabled)
                }
                Button("") { bridge.runCommand(id: "ui.chat.compact") }
                    .shortcutKey(shortcut(.compactContext))
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .sheet(isPresented: $bridge.isCommandPalettePresented) {
            CommandPaletteView(bridge: bridge)
        }
        // E6 工具审批弹窗：AgentLoop 请求审批时呈现（工具名/脱敏输入/风险级别 + 允许/拒绝）
        .sheet(isPresented: approvalBinding, onDismiss: {
            if let stableID = pendingApprovalTaskCenterID,
               bridge.approvalCenter.isPresentationSuspended {
                pendingApprovalTaskCenterID = nil
                taskCenterInitialSelectionID = stableID
                presentTaskCenter()
            } else {
                pendingApprovalTaskCenterID = nil
            }
        }) {
            ApprovalPromptView(
                center: bridge.approvalCenter, shortcutStore: bridge.shortcutStore,
                onViewTaskCenter: taskCenterApprovalDestination == nil
                    ? nil : { viewPendingApprovalInTaskCenter() }
            )
        }
        // E15 节点内容编辑器：双击画布节点弹出（TextEditor + 粘贴 + 文件导入 + setContent 写回）
        .sheet(isPresented: contentEditorBinding) {
            if let canvas = bridge.canvasIfAvailable,
               let boundary = bridge.canvasBoundaryIfAvailable {
                NodeContentEditorView(nodeID: boundary.contentEditorNodeID ?? UUID(), store: canvas)
            }
        }
        // The ordinary Chat file/artifact sheet needs no Canvas capability.
        .sheet(isPresented: assetPanelBinding) {
            if Self.assetPanelContent(canvasAvailable: canvasAvailable, isCanvasActive: isCanvasActive) == .chatFiles {
                ChatArtifactPanelView(snapshot: chatInspectorSnapshot, preferencesDefaults: bridge.preferencesDefaults)
                    .environment(\.agentFileOutputAction, { change, intent in
                        let outcome = performFileOutputAction(change, intent)
                        if case .preview = intent, outcome == .completed {
                            chatAssetPanelPresented = false
                        }
                        return outcome
                    })
            } else if let canvas = bridge.canvasIfAvailable {
                AssetPanelView(store: canvas, preferencesDefaults: bridge.preferencesDefaults)
            }
        }
        .sheet(isPresented: $taskCenterPresented, onDismiss: {
            finishTaskCenterPresentation()
        }) {
            TaskCenterObservationView(
                bridge: bridge,
                initialChildNavigation: taskCenterChildNavigation,
                initialTaskStableID: taskCenterInitialSelectionID
            )
            // A modal Task Center owns the sheet host while it is open. New
            // requests still use the original approval card and waiter here.
            .sheet(isPresented: taskCenterApprovalBinding) {
                ApprovalPromptView(
                    center: bridge.approvalCenter, shortcutStore: bridge.shortcutStore
                )
            }
        }
        .onChange(of: bridge.approvalCenter.taskCenterResumeIntent) { _, intent in
            guard intent != nil else { return }
            if taskCenterDocked { closeDockedTaskCenter() }
            else if taskCenterPresentationActive { taskCenterPresented = false }
            else { finishTaskCenterApprovalReturn() }
        }
        .onChange(of: bridge.taskCenterOpenIntent) { _, intent in
            if let intent {
                taskCenterInitialSelectionID = intent.initialTaskStableID
                presentTaskCenter(toolbarOpener: intent.toolbarOpener)
            }
        }
        .onChange(of: bridge.taskCenterNextCommandCount) { previous, currentCount in
            consumeNextTaskCommands(from: previous, to: currentCount)
        }
        .onChange(of: bridge.sidebarToggleCommandCount) { previous, currentCount in
            guard bridge.layoutMode == .split else { return }
            for _ in 0..<(currentCount &- previous) { toggleSidebar() }
        }
        .onChange(of: bridge.contextOpenCommandCount) { previous, currentCount in
            guard previous != currentCount else { return }
            if bridge.layoutMode != .split { bridge.layoutMode = .split }
            expandContextPanel()
        }
        .onChange(of: bridge.contextToggleCommandCount) { previous, currentCount in
            guard bridge.layoutMode == .split else { return }
            for _ in 0..<(currentCount &- previous) { toggleContextPanel() }
        }
        .onChange(of: bridge.chatThreeColumnCommandCount) { previous, currentCount in
            guard currentCount != previous,
                  bridge.layoutMode == .split,
                  bridge.canvasFeatureLane == .phase3NonCanvas else { return }
            if sessionSidebarCollapsed { expandSidebar() }
            if !showContextPanel { expandContextPanel() }
        }
    }

    private var taskCenterOpenCommand: PaletteCommand? {
        AppCommandMenuBuilder.command(
            id: "ui.taskcenter.open", registry: bridge.commandRegistry,
            display: bridge.paletteDisplay
        )
    }

    private var taskCenterNextCommand: PaletteCommand? {
        AppCommandMenuBuilder.command(
            id: "ui.taskcenter.next", registry: bridge.commandRegistry,
            display: bridge.paletteDisplay
        )
    }

    private var sidebarToggleCommand: PaletteCommand? {
        AppCommandMenuBuilder.command(
            id: "ui.sidebar.toggle", registry: bridge.commandRegistry,
            display: bridge.paletteDisplay
        )
    }

    private var contextToggleCommand: PaletteCommand? {
        AppCommandMenuBuilder.command(
            id: "ui.context.toggle", registry: bridge.commandRegistry,
            display: bridge.paletteDisplay
        )
    }

    private func consumeNextTaskCommands(from previous: UInt64, to currentCount: UInt64) {
        // The presented sheet consumes its own presses. While closed, retain
        // every press even if SwiftUI coalesces several updates into one.
        guard !taskCenterPresentationActive, currentCount > previous else { return }
        let current = bridge.taskCenterControlConsumer.homeReceiptSections(
            TaskCenterReceiptFilter()
        ).current
        for _ in previous..<currentCount {
            taskCenterInitialSelectionID = TaskCenterNextTaskSelection.nextID(
                in: current, after: taskCenterInitialSelectionID
            )
        }
        presentTaskCenter()
    }

    private func presentTaskCenter(toolbarOpener: Bool = false) {
        if taskCenterDocked {
            contextShowsTasks = true
            adaptiveLayoutState = AdaptiveLayoutReducer.reduce(
                adaptiveLayoutState, .userSetContextPanelCollapsed(false))
            syncAdaptiveLayoutProjection()
            return
        }
        guard !taskCenterPresentationActive else { return }
        // Keep an already visible approval card in its current host. Explicit
        // "view in Task Center" navigation has suspended it before reaching here.
        guard availableTaskCenterWidth >= 1100 || !bridge.approvalCenter.isPromptPresented else { return }
        taskCenterOpenerFocus.capture(toolbarOpener: toolbarOpener)
        taskCenterEntryFocused = false
        taskCenterEntryAccessibilityFocused = false
        taskCenterPresentationActive = true
        if availableTaskCenterWidth >= 1100 {
            taskCenterDocked = true
            contextShowsTasks = true
            contextPanelWidth = max(contextPanelWidth, 320)
            if bridge.layoutMode != .split { bridge.layoutMode = .split }
            adaptiveLayoutState = AdaptiveLayoutReducer.reduce(
                adaptiveLayoutState, .userSetContextPanelCollapsed(false))
            syncAdaptiveLayoutProjection()
        } else {
            taskCenterPresented = true
        }
    }

    private func closeDockedTaskCenter() {
        taskCenterDocked = false
        contextShowsTasks = false
        finishTaskCenterPresentation()
    }

    private func finishTaskCenterPresentation() {
        finishTaskCenterApprovalReturn()
        taskCenterPresentationActive = false
        taskCenterChildNavigation = nil
        taskCenterInitialSelectionID = nil
        if taskCenterOpenerFocus.restore() == .toolbar {
            taskCenterEntryFocused = true
            taskCenterEntryAccessibilityFocused = true
        }
    }

    /// 内容编辑器展示绑定（由 canvas 边界的 contentEditorNodeID 驱动，关闭时回写 nil）
    private var contentEditorBinding: Binding<Bool> {
        Binding(
            get: { bridge.canvasBoundaryIfAvailable?.hasContentEditor ?? false },
            set: { if !$0 { bridge.canvasBoundaryIfAvailable?.closeContentEditor() } }
        )
    }

    /// Presentation only; Canvas media visibility still belongs to its boundary.
    private var assetPanelBinding: Binding<Bool> {
        Binding(
            get: {
                if Self.assetPanelContent(canvasAvailable: canvasAvailable, isCanvasActive: isCanvasActive) == .chatFiles {
                    return chatAssetPanelPresented
                }
                return bridge.canvasBoundaryIfAvailable?.isAssetPanelPresented ?? false
            },
            set: {
                if Self.assetPanelContent(canvasAvailable: canvasAvailable, isCanvasActive: isCanvasActive) == .chatFiles {
                    chatAssetPanelPresented = $0
                } else if !$0 {
                    bridge.canvasBoundaryIfAvailable?.setAssetPanelPresented(false)
                }
            }
        )
    }

    private var taskCenterApprovalDestination: (stableID: String, navigation: TaskCenterApprovalNavigation)? {
        for row in bridge.taskCenterControlConsumer.receiptRows() {
            if let navigation = bridge.taskCenterControlConsumer.approvalNavigation(
                for: row, pendingRequest: bridge.approvalCenter.pendingRequest
            ) {
                return (row.stableID, navigation)
            }
        }
        return nil
    }

    private func viewPendingApprovalInTaskCenter() {
        guard let destination = taskCenterApprovalDestination else { return }
        let actions = bridge.approvalCenter.actionsForPresentedRequest()
        guard actions.viewTaskCenter(destination.navigation, bridge.taskCenterControlConsumer) else { return }
        pendingApprovalTaskCenterID = destination.stableID
    }

    private func finishTaskCenterApprovalReturn() {
        let center = bridge.approvalCenter
        guard let intent = center.taskCenterResumeIntent else { return }
        guard bridge.taskCenterControlConsumer.pendingApproval(
            navigation: intent.navigation, pendingRequest: center.pendingRequest
        ) != nil else {
            center.cancelTaskCenterResume(intent)
            return
        }
        _ = center.resumeFromTaskCenter(intent, consumer: bridge.taskCenterControlConsumer)
    }

    private var taskCenterModalPresentationActive: Bool {
        taskCenterPresentationActive && !taskCenterDocked
    }

    private var taskCenterApprovalBinding: Binding<Bool> {
        let actions = bridge.approvalCenter.actionsForPresentedRequest()
        return Binding(
            get: { bridge.approvalCenter.isPromptPresented && taskCenterModalPresentationActive
                && !bridge.p03CleanupAppController.isPanelPresented },
            set: { if !$0 { actions.dismiss() } }
        )
    }

    /// Only explicit validated Task Center navigation suspends presentation.
    /// Ordinary sheet close/Esc continues to reject through the rendered action.
    private var approvalBinding: Binding<Bool> {
        let actions = bridge.approvalCenter.actionsForPresentedRequest()
        return Binding(
            get: { bridge.approvalCenter.isPromptPresented
                && !bridge.approvalCenter.usesInlinePresentation && !taskCenterModalPresentationActive
                && !bridge.p03CleanupAppController.isPanelPresented },
            set: { if !$0 && !bridge.approvalCenter.usesInlinePresentation { actions.dismiss() } }
        )
    }

    // MARK: 导航历史（返回/前进）

    private func pushPane(_ pane: MainPane) {
        guard pane != .canvas || canvasAvailable else { mainPane = .chat; return }
        guard pane != mainPane else { return }
        navStack = Array(navStack[...navIndex]) + [pane]
        navIndex = navStack.count - 1
        mainPane = pane
        storedMainPaneRawValue = pane.rawValue
    }

    private func goBack() {
        guard navIndex > 0 else { return }
        navIndex -= 1
        mainPane = CanvasViewAdmission.pane(navStack[navIndex], canvasAvailable: canvasAvailable)
        storedMainPaneRawValue = mainPane.rawValue
    }

    private func goForward() {
        guard navIndex < navStack.count - 1 else { return }
        navIndex += 1
        mainPane = CanvasViewAdmission.pane(navStack[navIndex], canvasAvailable: canvasAvailable)
        storedMainPaneRawValue = mainPane.rawValue
    }

    // MARK: 主区域（Codex 三栏：左会话侧栏 / 中主区 / 右上下文面板）

    @ViewBuilder
    private func mainArea(decision: AdaptiveLayoutDecision) -> some View {
        switch visibleLayoutMode {
        case .canvas:
            // U1 画布独占：主内容 + 左侧伴随对话栏（Codex 风格，替代底部全局对话条）
            // AJ-60：宽度拖拽调整（复用 SidebarWidthMemory 夹取）+ minisCanvas.companionWidth 持久化 + 隐藏/恢复
            // 2026-08-06：HSplitView 全部替换为 DeterministicSplitView——NSSplitView autolayout 桥接
            // 在全屏/resize 时约束循环崩溃（14:40/14:48 .ips 实证），显式 frame 布局根治。
            DeterministicSplitView(sidebarWidth: companionCollapsed ? 0 : effectiveCompanionWidth) {
                companionChatPane
            } main: {
                if let canvas = bridge.canvasIfAvailable {
                    MultiCanvasTabBar(bridge: bridge, store: canvas)
                } else {
                    chatPaneWithComposer
                }
            }
            // AJ-60：伴随栏折叠后，主区左上浮动恢复入口
            .overlay(alignment: .topLeading) {
                if companionCollapsed {
                    companionRestoreFloatingButton
                }
            }
        case .chat:
            // 聊天独占（F11-ui：输入框与消息区同容器同宽，见 chatPaneWithComposer）
            chatPaneWithComposer
        case .split:
            let leftIsOverlay = decision.leftPanel == .overlay
            let rightIsOverlay = decision.rightPanel == .overlay
            let persistentLeftWidth = (leftIsOverlay || sessionSidebarCollapsed) ? 0 : decision.leftWidth
            let persistentRightWidth = (rightIsOverlay || !showContextPanel) ? 0 : decision.rightWidth
            let composerClearance = visibleMainPane == .chat
                ? max(chatComposerHeight, ChatLayoutMetrics.composerMinimumHeight) : 0

            // A7-A：regular/wide 维持三栏；medium 先把右栏改为 overlay；compact 两栏均为 overlay。
            // 仍使用纯 SwiftUI 确定性分栏，避免重新引入 NSSplitView resize 崩溃。
            DeterministicSplitView(
                sidebarWidth: persistentLeftWidth,
                mainMinWidth: decision.mainMinimumWidth + persistentRightWidth
            ) {
                sessionSidebarPanel(
                    showsResizeHandle: !leftIsOverlay,
                    visibleWidth: decision.leftWidth,
                    maximumWidth: decision.leftMaximumWidth
                )
            } main: {
                DeterministicSplitView(
                    sidebarWidth: persistentRightWidth,
                    mainMinWidth: decision.mainMinimumWidth,
                    trailing: true
                ) {
                    contextPanel(
                        showsResizeHandle: !rightIsOverlay,
                        visibleWidth: decision.rightWidth,
                        maximumWidth: decision.rightMaximumWidth
                    )
                } main: {
                    Group {
                        switch visibleMainPane {
                        case .chat:
                            // F11-ui：输入框移入中间分栏（与消息区同容器同宽）
                            chatPaneWithComposer
                        case .canvas:
                            // U1：画布为主内容，对话放左侧伴随栏（替代底部全局对话条）
                            // AJ-60：宽度拖拽调整 + 记忆 + 隐藏/恢复（同画布独占，见 companionChatPane）
                            // AJ-69：此处 320 是三栏+伴随布局的主内容最小宽，不是任何面板硬上限；
                            // DeterministicSplitView 仍按当前窗口动态决定伴随栏 effective width，
                            // 并保留 remembered request 供窗口恢复。
                            DeterministicSplitView(
                                sidebarWidth: companionCollapsed ? 0 : effectiveCompanionWidth,
                                mainMinWidth: 320
                            ) {
                                companionChatPane
                            } main: {
                                if let canvas = bridge.canvasIfAvailable {
                                    MultiCanvasTabBar(bridge: bridge, store: canvas)
                                } else {
                                    chatPaneWithComposer
                                }
                            }
                            // AJ-60：伴随栏折叠后，中间主区左上浮动恢复入口
                            .overlay(alignment: .topLeading) {
                                if companionCollapsed {
                                    companionRestoreFloatingButton
                                }
                            }
                        }
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                if leftIsOverlay && !sessionSidebarCollapsed {
                    sessionSidebarPanel(
                        showsResizeHandle: false,
                        visibleWidth: decision.leftWidth,
                        maximumWidth: decision.leftMaximumWidth
                    )
                        .frame(width: decision.leftWidth)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .shadow(color: .black.opacity(0.18), radius: 16, x: 4)
                        .padding(.bottom, composerClearance)
                        .zIndex(3)
                }
            }
            .overlay(alignment: .topTrailing) {
                if rightIsOverlay && showContextPanel {
                    contextPanel(
                        showsResizeHandle: false,
                        visibleWidth: decision.rightWidth,
                        maximumWidth: decision.rightMaximumWidth
                    )
                        .frame(width: decision.rightWidth)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .shadow(color: .black.opacity(0.18), radius: 16, x: -4)
                        .padding(.bottom, composerClearance)
                        .zIndex(4)
                }
            }
        }
    }

    private func sessionSidebarPanel(
        showsResizeHandle: Bool,
        visibleWidth: Double,
        maximumWidth: Double
    ) -> some View {
        SessionSidebarView(
            chat: bridge.chat,
            collapsed: sessionSidebarCollapsed,
            sessionBadgeStore: bridge.sessionBadgeStore
        )
            .clipped()
            .overlay(alignment: .trailing) {
                if showsResizeHandle && !sessionSidebarCollapsed {
                    sidebarWidthDragHandle(visibleWidth: visibleWidth, maximumWidth: maximumWidth)
                }
            }
    }

    private func contextPanel(
        showsResizeHandle: Bool,
        visibleWidth: Double,
        maximumWidth: Double
    ) -> some View {
        // Chat receives only a value projection. Canvas enters this shared
        // panel solely when the current pane is the Canvas branch.
        let canvasForPanel: CanvasStore? = isCanvasActive ? bridge.canvasIfAvailable : nil
        let inspectorSnapshot = chatInspectorSnapshot
        return VStack(spacing: 0) {
            if taskCenterDocked {
                HStack {
                    Picker("右侧栏", selection: $contextShowsTasks) {
                        Text("上下文").tag(false)
                        Text("任务中心").tag(true)
                    }
                    .pickerStyle(.segmented)
                    Button("弹窗打开") {
                        taskCenterDocked = false
                        contextShowsTasks = false
                        taskCenterPresented = true
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("task-center-undock")
                }
                .padding(8)
                Divider()
            }
            if taskCenterDocked && contextShowsTasks {
                TaskCenterObservationView(
                    bridge: bridge,
                    initialChildNavigation: taskCenterChildNavigation,
                    initialTaskStableID: taskCenterInitialSelectionID,
                    isSidebar: true,
                    onClose: closeDockedTaskCenter
                )
            } else {
                ContextPanelView(
            chat: bridge.chat,
            canvas: canvasForPanel,
            nodeContext: isCanvasActive ? bridge.selectedNodeContext : nil,
            chatSnapshot: inspectorSnapshot,
            onCollapse: { bridge.runCommand(id: "ui.context.toggle") },
            onCompact: {
                guard let sessionID = bridge.chat.activeSessionID,
                      inspectorSnapshot.sessionID == sessionID.uuidString,
                      let command = AppCommandMenuBuilder.command(
                        id: "ui.chat.compact", registry: bridge.commandRegistry,
                        display: bridge.paletteDisplay
                      ), command.isEnabled else { return }
                bridge.runCommand(id: command.id)
            },
            budgetResetBlockedReason: bridge.approvalCenter.pendingRequest == nil
                ? bridge.chat.sessionBudgetResetBlockedReason : "有任务待审批，请处理后重置。",
            onConfirmBudgetReset: { target in
                Task { @MainActor in
                    await bridge.chat.resetConfirmedSessionBudget(target) {
                        bridge.approvalCenter.pendingRequest != nil
                    }
                }
            },
            onReadCompactionSummary: { identity in
                guard bridge.chat.activeSessionID?.uuidString == identity.sessionID,
                      let store = bridge.chat.sessionManager?.store else { return nil }
                return SessionCompactProjection.readSummary(
                    identity, store: store,
                    redactor: bridge.productionTranscriptRedactor ?? ChatTranscriptRedactor(secretValues: [])
                )
            },
            onOpenChildSession: { navigation in
                guard let activeSessionID = bridge.chat.activeSessionID,
                      navigation.parentSessionID == activeSessionID.uuidString,
                      let currentTaskID = bridge.chat.executionSnapshot(
                          forSessionID: activeSessionID
                      )?.taskID,
                      navigation.locator?.parentID == currentTaskID,
                      bridge.taskCenterControlConsumer.childTranscript(
                          navigation: navigation
                      ) != nil else {
                    return
                }
                taskCenterChildNavigation = navigation
                presentTaskCenter()
            },
            onLoadOlderToolEvents: {
                // Reject a button retained from A after B becomes the active session.
                _ = toolEventPageState.loadOlderIfCurrent(
                    viewerSessionID: inspectorSnapshot.sessionID,
                    activeSessionID: bridge.chat.activeSessionID?.uuidString,
                    canonicalEvents: bridge.chat.conversationEventProjection.events,
                    pageSize: ChatInspectorSnapshot.maxToolRows
                )
            },
            onFileOutputAction: performFileOutputAction,
            childFileCheckpointSummaries: { sessionID, childTaskID, path in
                bridge.childFileCheckpointSummaries(sessionID: sessionID, childTaskID: childTaskID, path: path)
            },
            onRequestRestoreChildFileCheckpoint: { checkpointID, sessionID, childTaskID, path in
                await bridge.requestRestoreChildFileCheckpoint(checkpointID, sessionID: sessionID,
                    childTaskID: childTaskID, path: path)
            },
            attachmentPreviewSelection: attachmentPreviewSelection?.visible(in: bridge.chat.activeSessionID)
        )
            }
        }
        .frame(minWidth: SidebarWidthMemory.minWidth, idealWidth: effectiveContextPanelWidth, maxWidth: .infinity)
        .overlay(alignment: .leading) {
            if showsResizeHandle {
                contextPanelWidthDragHandle(visibleWidth: visibleWidth, maximumWidth: maximumWidth)
            }
        }
    }

    /// Inspector and asset presentation share the original action consumer.
    /// The current session, durable record and filesystem are checked at click time.
    private func performFileOutputAction(_ change: AgentFileChangeRecord, _ intent: AgentFileOutputIntent) -> AgentFileOutputOutcome {
        AgentFileOutputActionConsumer.performInApp(
            change: change,
            viewerSessionID: bridge.chat.activeSessionID?.uuidString,
            records: bridge.actionHistory.records,
            workspaceRoot: bridge.productionFileChangeLedger?.workspaceRoot,
            intent: intent,
            preview: { url in
                guard let sessionID = bridge.chat.activeSessionID,
                      let root = bridge.productionFileChangeLedger?.workspaceRoot else {
                    return false
                }
                attachmentPreviewSelection = ChatAttachmentPreviewSelection(
                    sessionID: sessionID,
                    url: url,
                    agentWorkspaceRoot: URL(fileURLWithPath: root, isDirectory: true)
                )
                showContextPanel = true
                adaptiveLayoutState = AdaptiveLayoutReducer.reduce(
                    adaptiveLayoutState,
                    .userSetContextPanelCollapsed(false)
                )
                adaptiveLayoutState = AdaptiveLayoutReducer.reduce(
                    adaptiveLayoutState,
                    .compactOverlayOpened(.contextPanel)
                )
                syncAdaptiveLayoutProjection()
                if bridge.layoutMode != .split { bridge.layoutMode = .split }
                return true
            }
        )
    }

    /// F13-ui：侧栏折叠后主区左上浮动恢复入口（24x24 小按钮 + 浅色圆角背景，边距 8pt）。
    /// 仅 sessionSidebarCollapsed == true 时由 mainArea overlay 渲染；点击展开侧栏。
    /// 淡入动画由 body 的 .animation(value: sessionSidebarCollapsed) + .transition(.opacity) 驱动。
    private var sidebarRestoreFloatingButton: some View {
        Button {
            expandSidebar()
        } label: {
            MinisIconView(.sidebarLeft, size: 12)
                .foregroundPalette(theme?.aj38.accent.swiftUIColor ?? Color.accentColor)
                .font(.system(size: 12))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(theme?.aj38.backgroundSecondary.swiftUIColor ?? Color(nsColor: .controlBackgroundColor))
                        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                )
        }
        .buttonStyle(.plain)
        .padding(.leading, 8)
        .padding(.top, 8)
        .help("展开会话侧栏（⌘⇧C）")
        .accessibilityLabel("展开会话侧栏")
        .accessibilityHint("恢复左侧会话列表；也可使用 ⌘⇧C")
        .transition(.opacity)
    }

    /// AJ-23：侧栏右侧拖拽手柄（窄条，横向拖拽调整宽度）。
    /// 起点 = 当前展开宽度，增量 = translation.width，夹取 [min, max] 并持久化。
    private func sidebarWidthDragHandle(visibleWidth: Double, maximumWidth: Double) -> some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .frame(width: 6)
            .onHover { inside in
                if inside && !sidebarCursorPushed {
                    NSCursor.resizeLeftRight.push()
                    sidebarCursorPushed = true
                } else if !inside && sidebarCursorPushed {
                    NSCursor.pop()
                    sidebarCursorPushed = false
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStartWidth == 0 {
                            // The saved request may be wider than the pane after a window shrink.
                            // Anchor a new gesture to the visible divider, without rewriting the
                            // saved request until the user actually drags it.
                            dragStartWidth = visibleWidth
                        }
                        applySidebarDrag(
                            value.translation.width,
                            visibleRange: AdaptiveLayoutPolicy.persistentLeftMinimumWidth...maximumWidth
                        )
                    }
                    .onEnded { _ in
                        dragStartWidth = 0
                        if sidebarCursorPushed {
                            NSCursor.pop()
                            sidebarCursorPushed = false
                        }
                    }
            )
            .help("拖拽调整侧栏宽度")
            .accessibilityLabel("调整会话侧栏宽度")
            .accessibilityHint("向左或向右拖动以调整侧栏宽度")
            .accessibilityIdentifier("chat.sidebar.resize-handle")
    }

    /// 右侧上下文栏左缘手柄。右栏在 trailing 侧，因此向左拖动会增加宽度。
    private func contextPanelWidthDragHandle(visibleWidth: Double, maximumWidth: Double) -> some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .frame(width: AdaptiveDividerNativeContract.handleWidth)
            .onHover { inside in
                if inside && !contextPanelCursorPushed {
                    NSCursor.resizeLeftRight.push()
                    contextPanelCursorPushed = true
                } else if !inside && contextPanelCursorPushed {
                    NSCursor.pop()
                    contextPanelCursorPushed = false
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        applyContextPanelDrag(
                            value.translation.width,
                            visibleWidth: visibleWidth,
                            visibleRange: AdaptiveLayoutPolicy.persistentRightMinimumWidth...maximumWidth
                        )
                    }
                    .onEnded { _ in
                        endContextPanelDrag()
                    }
            )
            .onDisappear {
                endContextPanelDrag()
            }
            .help("拖拽调整右侧面板宽度")
            .accessibilityLabel("调整右侧面板宽度")
            .accessibilityHint("向左或向右拖动以调整上下文面板宽度")
            .accessibilityValue(String(format: "%.0f 点", contextPanelWidth))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    adjustContextPanelWidth(by: 32)
                case .decrement:
                    adjustContextPanelWidth(by: -32)
                @unknown default:
                    break
                }
            }
    }

    /// F11-ui：聊天主区 = 消息区 + 输入框同容器（单个 VStack，共享外圈 Keyline）。
    /// 两者左右边缘严格一致：侧栏展开/折叠、上下文面板开关、画布切换均自适应等宽。
    @MainActor
    internal func chatSurfaceInstrumentationView() -> AnyView {
        AnyView(chatPaneWithComposer)
    }

    private var chatPaneWithComposer: some View {
        GeometryReader { geometry in
            let metrics = ChatSurfaceLayoutMetrics.forWidth(geometry.size.width)
            VStack(spacing: 0) {
                ChatMainView(
                    chat: bridge.chat,
                    documentStore: bridge.sessionDocuments,
                    transcriptEnvStore: transcriptEnvStore,
                    onOpenAttachment: openAttachmentInContextPanel
                )
                .padding(.horizontal, metrics.surfaceGutter)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(ChatLayoutMetrics.messageListLayoutPriority)
                .onAppear { bridge.approvalCenter.inlineHostAvailable = true }
                .onDisappear { bridge.approvalCenter.inlineHostAvailable = false }
                if bridge.approvalCenter.usesInlinePresentation && !taskCenterModalPresentationActive
                    && !bridge.p03CleanupAppController.isPanelPresented {
                    InlineApprovalPromptView(center: bridge.approvalCenter)
                }
                ChatChildTaskSummaryView(onOpen: { navigation in
                    guard let sessionID = bridge.chat.activeSessionID,
                          navigation.parentSessionID == sessionID.uuidString,
                          navigation.locator?.parentID == bridge.chat.executionSnapshot(forSessionID: sessionID)?.taskID,
                          bridge.taskCenterControlConsumer.childTranscript(navigation: navigation) != nil else { return }
                    taskCenterChildNavigation = navigation
                    presentTaskCenter()
                }, onStop: { row in
                    // A stale card cannot stop a newer run of the same task.
                    guard row.sourceSessionID == bridge.chat.activeSessionID?.uuidString,
                          let fact = bridge.taskCenterGoalProjection(now: .now).tasks.first(where: {
                        $0.taskID == row.taskID && $0.parentID == row.parentID
                    }), let runID = row.runID,
                       runID == bridge.taskCenterControlRunID(taskID: row.taskID, parentID: row.parentID),
                       let attemptID = row.attemptID,
                       attemptID == bridge.agentTaskStore.canonicalAttemptID(runID: runID) else {
                        throw TaskCenterControlConsumerError.unavailable
                    }
                    _ = try bridge.executeTaskCenterControl(TaskCenterControlRequest(
                        taskID: row.taskID, parentID: row.parentID, revision: fact.revision,
                        scopeID: fact.scopeID ?? "", actorID: "chat-child-card",
                        idempotencyKey: "chat-child-card:\(UUID().uuidString)",
                        action: fact.status == .queued ? .cancel : .stop, runID: row.runID
                    ))
                }) {
                    let sessionID = bridge.chat.activeSessionID
                    let parentTaskID = sessionID.flatMap {
                        bridge.chat.executionSnapshot(forSessionID: $0)?.taskID
                    }
                    let rows = bridge.taskCenterControlConsumer.receiptRowsReusingVersion(
                        includeArchived: false
                    ).filter {
                        ChatInspectorTaskScope.includes(
                            sourceSessionID: $0.sourceSessionID,
                            taskID: $0.taskID, parentID: $0.parentID,
                            viewerSessionID: sessionID?.uuidString,
                            currentTaskID: parentTaskID
                        ) || (parentTaskID == nil && sessionID != nil
                            && $0.childNavigation?.locator != nil
                            && $0.childNavigation?.parentSessionID == sessionID?.uuidString)
                    }
                    return TaskSummaryChildProjection(
                        currentTaskID: parentTaskID, receiptRows: rows,
                        viewerSessionID: sessionID?.uuidString
                    )
                }
                .padding(.horizontal, metrics.surfaceGutter)
                GlobalComposerView(
                    bridge: bridge,
                    chat: bridge.chat,
                    onPreviewAttachment: openPendingAttachmentInContextPanel,
                    mainPane: .chat
                )
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: ChatLayoutMetrics.composerMinimumHeight)
                    // Keep transcript and Composer on the same Keyline; the
                    // gutter is the only width-class adjustment, so controls
                    // never steal space from the message stream at 600pt.
                    .padding(.horizontal, metrics.surfaceGutter)
                    .layoutPriority(ChatLayoutMetrics.composerLayoutPriority)
                    .accessibilityIdentifier("chat.composer")
                    .background {
                        GeometryReader { composerGeometry in
                            Color.clear.preference(
                                key: ChatComposerHeightPreferenceKey.self,
                                value: composerGeometry.size.height
                            )
                        }
                    }
            }
            .frame(
                minWidth: metrics.minimumContentWidth,
                maxWidth: .infinity,
                maxHeight: .infinity
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chat.surface")
        }
    }

    private func openAttachmentInContextPanel(_ attachment: ChatAttachment) {
        guard let sessionID = bridge.chat.activeSessionID else {
            attachmentPreviewError = "当前没有可用会话。"
            return
        }
        let sourceState = ChatAttachmentOpenTarget.sourceState(for: attachment)
        guard sourceState.isOpenable else {
            attachmentPreviewError = sourceState.statusText + "。请重新选择文件后重试。"
            return
        }
        do {
            attachmentPreviewSelection = ChatAttachmentPreviewSelection(
                sessionID: sessionID,
                attachment: attachment,
                url: try ChatAttachmentOpenTarget().resolve(attachment)
            )
            showContextPanel = true
            adaptiveLayoutState = AdaptiveLayoutReducer.reduce(
                adaptiveLayoutState,
                .userSetContextPanelCollapsed(false)
            )
            adaptiveLayoutState = AdaptiveLayoutReducer.reduce(
                adaptiveLayoutState,
                .compactOverlayOpened(.contextPanel)
            )
            syncAdaptiveLayoutProjection()
            if bridge.layoutMode != .split {
                if bridge.layoutMode == .canvas && canvasAvailable {
                    mainPane = .canvas
                }
                bridge.layoutMode = .split
            }
        } catch {
            attachmentPreviewError = error.localizedDescription
        }
    }

    private func openPendingAttachmentInContextPanel(
        _ attachment: ChatAttachment,
        sourceSessionID: UUID
    ) {
        guard GlobalComposer.isCurrentPendingAttachment(
            attachment,
            expectedSessionID: sourceSessionID,
            activeSessionID: bridge.chat.activeSessionID,
            pendingAttachments: bridge.chat.pendingAttachments
        ) else { return }
        let previousRequestID = attachmentPreviewSelection?.requestID
        openAttachmentInContextPanel(attachment)
        if let requestID = attachmentPreviewSelection?.requestID,
           requestID != previousRequestID {
            pendingAttachmentPreview = PendingAttachmentPreviewRequest(
                attachmentID: attachment.id,
                requestID: requestID
            )
        }
    }

    /// 当前主区是否为画布：画布独占布局（layoutMode == .canvas，mainPane 无关）或
    /// 三栏分栏主区切到画布（layoutMode == .split && mainPane == .canvas）。
    /// 与 GlobalComposerView.isCanvasActive（GlobalComposerView.swift:73-75）同源谓词，
    /// 工具栏画布专属控件（画布菜单/模板菜单）据此显隐——不可用 mainPane == .canvas，
    /// 布局切换（AppCommandPalette）只改 layoutMode 不动 mainPane，会导致画布独占下
    /// 菜单消失、聊天独占下残留（P1#4 修复）。
    private var isCanvasActive: Bool {
        canvasAvailable && (visibleLayoutMode == .canvas
            || (visibleLayoutMode == .split && visibleMainPane == .canvas))
    }

    // MARK: 顶部窄工具栏（Codex：导航 + 标题 + 视图切换 + 右侧 Provider 状态/设置）

    private func toolbar(decision: AdaptiveLayoutDecision) -> some View {
        HStack(spacing: 8) {
            if canvasAvailable {
                // 主导航：返回 / 前进
                Button {
                    goBack()
                } label: {
                    MinisIconView(.caretLeft, size: 12)
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(navIndex > 0 ? Color.primary : Color.secondary.opacity(0.4))
                .disabled(navIndex == 0)
                .help("返回（切换主视图历史）")
                .accessibilityLabel("返回")
                .accessibilityHint("切换到上一个主视图")

                Button {
                    goForward()
                } label: {
                    MinisIconView(.caretRight, size: 12)
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(navIndex < navStack.count - 1 ? Color.primary : Color.secondary.opacity(0.4))
                .disabled(navIndex >= navStack.count - 1)
                .help("前进")
                .accessibilityLabel("前进")
                .accessibilityHint("切换到下一个主视图")

                Divider().frame(height: 16)
            }

            Group {
                if canvasAvailable {
                    // 主视图切换（聊天 / 画布，⌘1 / ⌘2）
                    Picker("主视图", selection: $mainPane) {
                        ForEach(CanvasViewAdmission.panes(canvasAvailable: canvasAvailable)) { pane in
                            Label(pane.rawValue, systemImage: pane.icon).tag(pane)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .onChange(of: mainPane) { oldPane, newPane in
                guard canvasAvailable || newPane == .chat else {
                    mainPane = .chat
                    return
                }
                // D-APP-06：分段点击由 selection 先写 mainPane、后回流本 onChange，
                // 此刻带 guard 的 pushPane 恒拦 ⇒ 不入栈、返回按钮恒禁用。
                // 改用旧值/新值绕开 pushPane 做同型“截断+追加”入栈；
                // ⌘1/⌘2、goBack/goForward、恢复路径的回流均被同写条件拒绝 ⇒ 不重复入栈。
                if let pushed = MainPaneNavHistory.applyingSelection(
                    stack: navStack,
                    index: navIndex,
                    oldPane: oldPane,
                    newPane: newPane
                ) {
                    navStack = pushed.stack
                    navIndex = pushed.index
                    storedMainPaneRawValue = newPane.rawValue
                }
            }
            .help(canvasAvailable ? "主区视图：聊天（⌘1）/ 画布（⌘2）" : "主区视图：聊天")
            // ⌘1 / ⌘2 快捷键（AJ-57：绑定读 ShortcutStore；隐藏按钮兜底，分段控件本身不支持按键绑定）
            .background {
                Button("") { pushPane(.chat) }
                    .shortcutKey(shortcut(.mainPaneChat))
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
                if canvasAvailable {
                    Button("") { pushPane(.canvas) }
                        .shortcutKey(shortcut(.mainPaneCanvas))
                        .frame(width: 0, height: 0)
                        .opacity(0)
                        .accessibilityHidden(true)
                }
            }

            // F8-ui：画布操作与工作流模板菜单仅在画布可见时显示（聊天/文档下隐藏，防误触）。
            // gating 用 isCanvasActive（画布独占 / 三栏切到画布），而非 mainPane == .canvas：
            // 布局切换（AppCommandPalette）只改 layoutMode 不动 mainPane，画布独占下
            // mainPane 仍为 .chat，用旧谓词会导致画布菜单+模板菜单消失（P1#4 修复）。
            // 注意：⌘P 挂在「一键流水线」按钮上，非画布模式下随按钮隐藏而失效（可接受）。
            if isCanvasActive, let canvasBoundary = bridge.canvasBoundaryIfAvailable {
                // 画布操作（节点快捷添加 / 执行 / 布局 / 重置）收进菜单，保持工具栏窄
                Menu {
                    Section("添加节点") {
                        // Phase B 瘦身：只列 7 类生成类节点（文本创作类保留定义，不进新建入口）
                        ForEach(NodeTypeRegistry.creatableSpecs) { spec in
                            Button("\(spec.title)（\(spec.type)）") {
                                bridge.dispatchCanvasMutation(.addNode(type: spec.type, position: nil))
                            }
                        }
                    }
                    Divider()
                    Button {
                        bridge.dispatchCanvasMutation(.runGraph(nodeIDs: nil))
                    } label: {
                        Label("执行画布", systemImage: "play.fill")
                    }
                    .disabled(canvasBoundary.isGraphRunning || !canvasBoundary.hasGraphContent)
                    Button {
                        bridge.dispatchCanvasMutation(.autoLayout)
                    } label: {
                        Label("自动布局", systemImage: "square.grid.3x3.topleft.filled")
                    }
                    .disabled(!canvasBoundary.hasGraphContent)
                    Button {
                        bridge.dispatchCanvasMutation(.resetStatuses)
                    } label: {
                        Label("重置状态", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(!canvasBoundary.hasGraphContent)
                } label: {
                    toolbarLabel(
                        "画布",
                        systemImage: "square.grid.2x2",
                        showsTitle: decision.showsSecondaryToolbarLabels
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("画布操作：添加节点 / 执行 / 布局 / 重置")

                // P2：分镜表工作台开关（设计文档 §5.1 入口2：工具栏常驻按钮；
                // 空画布显示空态引导，画布可见时显示——随 isCanvasActive gating）
                Button {
                    canvasBoundary.toggleStoryboardWorkbench()
                } label: {
                    toolbarLabel(
                        "分镜表",
                        systemImage: "rectangle.split.3x1",
                        showsTitle: decision.showsSecondaryToolbarLabels
                    )
                }
                .buttonStyle(.borderless)
                .fixedSize()
                .help("分镜表工作台（按镜头组织整部剧）")

                // AJ-37 工作流模板库：预设节点组合 → 应用当前画布（静态骨架，不自动执行）
                Menu {
                    ForEach(WorkflowTemplateStore.presets) { template in
                        Button {
                            bridge.applyTemplate(template)
                        } label: {
                            Label(template.name, systemImage: template.icon)
                        }
                        .help(template.description)
                    }
                } label: {
                    toolbarLabel(
                        "模板",
                        systemImage: "square.stack.3d.up",
                        showsTitle: decision.showsSecondaryToolbarLabels
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("工作流模板：应用预设节点组合到当前画布（静态骨架，不自动执行）")
            }
            // 一键漫剧流水线按钮已下线（AJ-37 用户裁决：漫剧全流程模板不进模板库，
            // 一键入口废弃；改为上方「工作流模板」菜单逐模板应用）。BridgeStore.createManjuPipeline
            // 保留供过往指令/深链兼容，但不再暴露工具栏按钮。

            Spacer()

            // UI00：顶部只显示当前 Provider 状态；模型选择唯一保留在 Composer。
            if decision.showsSecondaryToolbarLabels {
                Text(bridge.chat.providerLabel)
                    .font(typography?.topBar ?? .system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help("当前服务商：\(bridge.chat.providerLabel)")
                    .accessibilityLabel("当前服务商")
                    .accessibilityValue(bridge.chat.providerLabel)
                    .accessibilityIdentifier("provider.status.readonly")

                Divider().frame(height: 16)
            }

            // AJ-69：会话侧栏 / 右栏上下文面板只存在于 split 三栏布局；
            // canvas/chat 布局下不渲染折叠按钮——否则按钮在「折叠一个不存在的栏」，
            // 图标/提示与界面脱节（快捷键随之只在 split 布局生效，符合预期）
            if bridge.layoutMode == .split {
                Button {
                    bridge.runCommand(id: "ui.sidebar.toggle")
                } label: {
                    // F13-ui：折叠态换更醒目图标（sidebar.left 面板收拢形态，与展开态
                    // sidebar.leading 形成可感知差异）+ accentColor 高亮保持；
                    // help 文案按状态区分，用户能明确知道下一步动作
                    MinisIconView(.sidebarLeft, state: sessionSidebarCollapsed ? .active : .normal, size: 12)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(sessionSidebarCollapsed ? (theme?.aj38.accent.swiftUIColor ?? Color.accentColor) : Color.secondary)
                .shortcutKey(shortcut(.toggleSessionSidebar))
                .help(sessionSidebarCollapsed ? "\(shortcut(.toggleSessionSidebar).displayString) 展开会话侧栏" : "\(shortcut(.toggleSessionSidebar).displayString) 折叠会话侧栏")
                .accessibilityLabel(sessionSidebarCollapsed ? "展开会话侧栏" : "折叠会话侧栏")
                .accessibilityHint("使用 \(shortcut(.toggleSessionSidebar).displayString) 切换")
                .accessibilityIdentifier("toolbar.sidebar.session.toggle")
                .disabled(sidebarToggleCommand?.isEnabled != true)

                Button {
                    bridge.runCommand(id: "ui.context.toggle")
                } label: {
                    // AJ-69：折叠态换更醒目图标（sidebar.right 面板收拢形态，与展开态
                    // sidebar.trailing 形成可感知差异——旧代码两个状态用同一图标，
                    // 折叠后用户看不出右栏已隐藏）+ accentColor 高亮保持
                    MinisIconView(.sidebarRight, state: showContextPanel ? .normal : .active, size: 12)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(showContextPanel ? (theme?.aj38.accent.swiftUIColor ?? Color.accentColor) : Color.secondary)
                .shortcutKey(shortcut(.toggleContextPanel))
                .help(showContextPanel
                      ? "\(shortcut(.toggleContextPanel).displayString) 折叠上下文面板"
                      : "\(shortcut(.toggleContextPanel).displayString) 展开上下文面板")
                .accessibilityLabel(showContextPanel ? "折叠上下文面板" : "展开上下文面板")
                .accessibilityHint("使用 \(shortcut(.toggleContextPanel).displayString) 切换")
                .accessibilityIdentifier("toolbar.sidebar.context.toggle")
                .disabled(contextToggleCommand?.isEnabled != true)
            }

            if let content = Self.assetPanelContent(canvasAvailable: canvasAvailable, isCanvasActive: isCanvasActive) {
                Button {
                    if content == .chatFiles {
                        chatAssetPanelPresented.toggle()
                    } else {
                        bridge.canvasBoundaryIfAvailable?.toggleAssetPanel()
                    }
                } label: {
                    if content == .chatFiles {
                        MinisIconView(.file, size: 12)
                    } else {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 12))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(assetPanelBinding.wrappedValue ? (theme?.aj38.accent.swiftUIColor ?? Color.accentColor) : Color.secondary)
                .help(content == .chatFiles
                      ? "资产预览区（当前会话文件变更与已证实产物）"
                      : "资产预览区（画布生成 / 导入素材）")
                .accessibilityLabel("资产预览区")
                .accessibilityValue(assetPanelBinding.wrappedValue ? "资产预览已打开" : "资产预览已关闭")
                .accessibilityHint("打开或关闭集中资产预览")
                .accessibilityIdentifier(content == .chatFiles ? "open-chat-assets" : "open-canvas-assets")
            }

            Button {
                bridge.runCommand(id: "ui.taskcenter.open", args: ["opener": "toolbar"])
            } label: {
                MinisIconView(.task, size: 12)
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(taskCenterOpenCommand?.disabledReason ?? taskCenterOpenCommand?.title ?? "打开任务中心")
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(taskCenterOpenCommand?.title ?? "打开任务中心")
            .accessibilityValue(taskCenterPresentationActive ? "任务中心已打开" : "任务中心未打开")
            .accessibilityHint("显示任务中心")
            .accessibilityAction {
                bridge.runCommand(id: "ui.taskcenter.open", args: ["opener": "toolbar"])
            }
            .accessibilityIdentifier("open-task-center")
            .focusable()
            .focused($taskCenterEntryFocused)
            .accessibilityFocused($taskCenterEntryAccessibilityFocused)
            .disabled(taskCenterOpenCommand?.isEnabled != true)

            Button("") {
                bridge.runCommand(id: "ui.taskcenter.next")
            }
            .shortcutKey(shortcut(.nextTask))
            .disabled(taskCenterPresentationActive || taskCenterNextCommand?.isEnabled != true)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)

            Divider().frame(height: 16)

            // D5 设置中心（齿轮按钮，与 Cmd+, 等效）
            Button {
                openSettings()
            } label: {
                MinisIconView(.settings, size: 12)
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("打开设置中心（Cmd+,）")
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("打开设置中心")
            .accessibilityHint("打开设置；也可使用 ⌘,")
            .accessibilityAction(.default, openSettings)
            .accessibilityIdentifier("open-settings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
    }

    @ViewBuilder
    private func toolbarLabel(
        _ title: String,
        systemImage: String,
        showsTitle: Bool
    ) -> some View {
        if showsTitle {
            Label(title, systemImage: systemImage)
        } else {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
        }
    }

    // MARK: E21 全局对话条（三栏底部通栏，所有主区视图共用）

    private var globalComposer: some View {
        GlobalComposerView(
            bridge: bridge,
            chat: bridge.chat,
            onPreviewAttachment: openPendingAttachmentInContextPanel,
            mainPane: visibleMainPane
        )
    }

    /// Captures the current chat facts before they enter the read-only inspector.
    /// No Canvas value participates in this projection.
    private var chatInspectorSnapshot: ChatInspectorSnapshot {
        let chat = bridge.chat
        // Undo changes only the projection; the transcript revision stays the same.
        _ = chat.compactionUndoFeedback
        let activeSessionID = chat.activeSessionID
        let sessionID = activeSessionID?.uuidString
        let currentTaskID = activeSessionID.flatMap { session in
            chat.executionSnapshot(forSessionID: session)?.taskID
        }
        let taskProjection = ChatInspectorTaskScope.capture(bridge: bridge,
            viewerSessionID: sessionID, currentTaskID: currentTaskID)
        let taskSnapshots = taskProjection.taskSnapshots
        let sessionReceiptRows = taskProjection.receiptRows
        let contextExecution = activeSessionID.flatMap { chat.executionSnapshot(forSessionID: $0) }
        let contextSummary = ChatInspectorContextConsumer.capture(
            store: bridge.contextManifestStore, sessionID: sessionID,
            turnID: contextExecution?.turnID, executionIdentity: contextExecution?.executionIdentity
        )
        let sourceRunIDs: [String] = {
            guard let currentTaskID else { return [] }
            return Array(
                Set(
                    sessionReceiptRows
                        .filter { $0.taskID == currentTaskID }
                        .compactMap(\.runID)
                )
            ).sorted()
        }()
        let sourceItems: [ChatInspectorSourceItem] = Array(
            Set(
                sourceRunIDs.filter { $0 != contextSummary?.runID }.flatMap { (runID: String) -> [ChatInspectorSourceItem] in
                    guard let manifest = bridge.contextManifestStore.manifest(runID: runID) else {
                        return []
                    }
                    return manifest.entries.map { ChatInspectorSourceItem(entry: $0) }
                } + (contextSummary?.entries.map { ChatInspectorSourceItem(entry: $0) } ?? [])
            )
        ).sorted { (lhs: ChatInspectorSourceItem, rhs: ChatInspectorSourceItem) -> Bool in
            if lhs.identifier != rhs.identifier { return lhs.identifier < rhs.identifier }
            return lhs.provenance < rhs.provenance
        }
        let sessionEvents: [MinisCore.ConversationEvent] = {
            guard let sessionID else { return [] }
            return chat.conversationEventProjection.events.filter {
                $0.identity.sessionID == sessionID
            }
        }()
        // D-OUTPUT-01：工具/子智能体生命周期事件以 canonical 事件本体下传，
        // 由 ChatInspectorView 的 ToolEventCard 折叠卡呈现摘要+脱敏详情+终态。
        let allToolEvents = sessionEvents.filter { $0.kind == .tool }
        let allActivityEvents = sessionEvents.map {
            ChatInspectorSnapshot.ActivityRow(
                display: MinisCore.ConversationEventProjection.display(for: $0),
                occurredAt: $0.occurredAt,
                actionLabel: $0.kind == .tool ? ToolEventCard.safeToolActionLabel($0.toolName) : nil
            )
        }
        let toolPage = toolEventPageState.page(
            sessionID: sessionID,
            events: allToolEvents,
            pageSize: ChatInspectorSnapshot.maxToolRows
        )
        let activityEvents = Array(allActivityEvents.suffix(ChatInspectorSnapshot.maxActivityRows))
        // D-OUTPUT-02：按工具原任务捕获的会话身份投影逐文件 Diff。
        // 旧记录或没有可信父回合的记录为 unknown，不归到当前打开的会话。
        let fileChanges = ChatInspectorFileChangeConsumer.changes(
            from: bridge.actionHistory.records,
            viewerSessionID: sessionID,
            limit: ChatInspectorSnapshot.maxFileChangeRows
        )
        let fileArtifacts = AgentOutputLedgerCardAdapter.fileArtifacts(
            sessionID: sessionID,
            ledger: bridge.productionFileChangeLedger,
            facts: (chat.agentEngine as? AgentLoopChatEngine)?.toolExecutionFactLedger.facts ?? [],
            limit: ChatInspectorSnapshot.maxFileChangeRows
        )

        return ChatInspectorSnapshot(
            sessionID: sessionID,
            providerLabel: chat.providerLabel,
            modelLabel: chat.selectedModelID ?? "默认",
            engineLabel: chat.agentEngine.isAvailable ? "在线" : "回退 LLM 直连",
            messageCount: chat.messages.count,
            activeSessionCount: chat.sessionList.count,
            archivedSessionCount: chat.archivedList.count,
            tokenUsageLabel: ChatStore.tokenUsageLabel(
                used: chat.budgetUsedTokens,
                cap: chat.budgetCapTokens
            ),
            budgetIsWarning: chat.budgetIsWarning,
            budgetIsOverLimit: chat.budgetIsOverLimit,
            currentTaskID: currentTaskID,
            taskSnapshots: taskSnapshots,
            receiptRows: sessionReceiptRows,
            sourceItems: sourceItems,
            contextSummary: contextSummary,
            toolEvents: toolPage.events,
            omittedToolEventCount: toolPage.omittedCount,
            activityEvents: activityEvents,
            omittedActivityEventCount: max(0, allActivityEvents.count - activityEvents.count),
            fileChanges: fileChanges,
            turnFileChanges: bridge.productionTranscriptRedactor.map { redactor in
                TurnFileChangesProjection.capture(sessionID: sessionID,
                    ledger: bridge.productionFileChangeLedger,
                    facts: (chat.agentEngine as? AgentLoopChatEngine)?.toolExecutionFactLedger.facts ?? [],
                    redact: redactor.redactVisibleConversationBody)
            } ?? [],
            fileArtifacts: fileArtifacts,
            artifactPersistenceUnavailable: bridge.productionFileChangeLedger?.artifactPersistenceUnavailable ?? false,
            persistence: SessionCompactProjection(
                sessionID: sessionID,
                store: chat.sessionManager?.store
            )
        )
    }

    // MARK: 底部状态行（Codex：token C:xxx 样式 + 模型名）

    @ViewBuilder
    private var statusBar: some View {
        if isCanvasActive, let boundary = bridge.canvasBoundaryIfAvailable {
            canvasStatusBar(boundary: boundary)
        } else {
            chatStatusBar
        }
    }

    private func canvasStatusBar(boundary: ChatCanvasRuntimeBoundary) -> some View {
        HStack(spacing: 12) {
            Group {
                if let msg = boundary.statusMessage {
                    Text(msg)
                        .lineLimit(1)
                } else {
                    Text("节点 \(boundary.graphNodeCount) · 连线 \(boundary.graphEdgeCount)")
                        .foregroundStyle(.secondary)
                }
            }
            .font(typography?.status ?? .system(size: 11))
            Spacer()
            TokenUsageBar(chat: bridge.chat, compact: true, barWidth: 80)
            providerStatus
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(theme?.aj38.backgroundSecondary.swiftUIColor ?? Color(nsColor: .underPageBackgroundColor).opacity(0.5))
    }

    private var chatStatusBar: some View {
        ChatStatusBar(chat: bridge.chat) {
            providerStatus
        }
    }

    @ViewBuilder
    private var providerStatus: some View {
        let chat = bridge.chat
        if chat.isMockMode {
            // Observe the Settings publications even when the catalog is empty.
            let _ = settingsCenter?.providerRecords
            let _ = settingsCenter?.providerReadinessReports
            let _ = settingsCenter?.providerModelReadinessStates
            let hasReadyModel = chat.hasReadyChatModel
            Button {
                bridge.deepLinkHandler.handle(.openSettings(id: hasReadyModel ? "常规" : ProviderConnectionRoute.id))
            } label: {
                Label {
                    ViewThatFits(in: .horizontal) {
                        Text(hasReadyModel ? "演示模式 · 选择默认模型" : "演示模式 · 连接模型")
                            .fixedSize(horizontal: true, vertical: false)
                        Text(hasReadyModel ? "选择模型" : "连接模型")
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .accessibilityLabel(hasReadyModel ? "演示模式 · 选择默认模型" : "演示模式 · 连接模型")
                } icon: {
                    MinisIconView(.warning, size: 14)
                }
            }
            .buttonStyle(.plain)
            .font((typography?.status ?? .system(size: 11)).weight(.semibold))
            .foregroundStyle(theme?.statusWarning ?? .orange)
            .help(hasReadyModel
                  ? "当前为本地演示。前往设置的常规页面选择默认模型。"
                  : "当前为本地演示；打开连接模型表单，保存后检查。")
            .accessibilityIdentifier("provider.connect-model")
        } else {
            Text(chat.providerLabel)
                .font(typography?.status ?? .system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }
}

// MARK: - M4 多画布 tab bar（参照 ComfyUI 多工作流标签）

/// 画布独占 / 三栏画布模式下的顶部多画布 tab 条：横向列出所有画布（当前高亮），
/// 右侧 + 新建；点 tab 切换；右键菜单重命名/删除（删除经 .alert 确认）。
/// 内部包一层 `CanvasView`（画布主体），tab 条叠在画布顶部。
struct MultiCanvasTabBar: View {
    let bridge: BridgeStore
    let store: CanvasStore
    @Environment(\.themeTokens) private var theme
    @Environment(\.typographyTokens) private var typography

    /// 重命名弹窗状态：待重命名画布 + 输入文本
    @State private var renamingTarget: CanvasDocument?
    @State private var renameText = ""
    /// 删除确认弹窗状态：待删除画布
    @State private var deleteTarget: CanvasDocument?

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            CanvasView(
                store: store,
                mutationCoordinator: bridge.canvasMutationCoordinator
            )
        }
        .alert("重命名画布", isPresented: renameBinding) {
            TextField("画布名称", text: $renameText)
            Button("取消", role: .cancel) { renamingTarget = nil }
            Button("确定") {
                if let target = renamingTarget {
                    store.renameCanvas(id: target.id, to: renameText)
                }
                renamingTarget = nil
            }
        } message: {
            Text("输入新的画布名称")
        }
        .alert("删除画布", isPresented: deleteBinding) {
            Button("取消", role: .cancel) { deleteTarget = nil }
            Button("删除", role: .destructive) {
                if let target = deleteTarget {
                    bridge.dispatchCanvasMutation(.deleteCanvas(id: target.id))
                }
                deleteTarget = nil
            }
        } message: {
            Text(deleteTarget.map { "确定删除画布「\($0.name)」？此操作将移除该画布及其草稿。" } ?? "")
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renamingTarget != nil }, set: { if !$0 { renamingTarget = nil } })
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }

    /// 顶部横向 tab 行：所有画布 tab + 右侧 + 新建按钮
    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(store.canvasDocuments) { doc in
                    tabItem(doc)
                }
                Button {
                    store.createCanvas()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("新建画布")
                .accessibilityLabel("新建画布")
                .accessibilityHint("创建一个新的画布标签")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .background(.bar)
    }

    /// 单个画布 tab：当前高亮 + 点击切换 + 右键菜单（重命名/删除）
    private func tabItem(_ doc: CanvasDocument) -> some View {
        let isCurrent = doc.id == store.currentCanvasID
        return Button {
            store.switchCanvas(to: doc.id)
        } label: {
            Text(doc.name)
                .font((typography?.sidebarItem ?? .system(size: 11)).weight(isCurrent ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isCurrent ? (theme?.aj38.accent.swiftUIColor ?? Color.accentColor).opacity(0.15) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isCurrent ? (theme?.aj38.accent.swiftUIColor ?? Color.accentColor).opacity(0.5) : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(isCurrent ? (theme?.aj38.accent.swiftUIColor ?? Color.accentColor) : Color.primary)
        // 半透明浮动右键菜单（用户定案：背景透明度 50%、文字不透明）
        .background(RightClickCatcher { windowPoint, _ in
            FloatingMenuHost.shared.present([
                FloatingMenuItem(kind: .button(title: "重命名", icon: "pencil", role: nil, help: nil) {
                    renameText = doc.name
                    renamingTarget = doc
                }),
                FloatingMenuItem(kind: .button(title: "删除", icon: "trash", role: .destructive, help: nil) {
                    deleteTarget = doc
                }),
            ], at: windowPoint)
        })
    }
}
