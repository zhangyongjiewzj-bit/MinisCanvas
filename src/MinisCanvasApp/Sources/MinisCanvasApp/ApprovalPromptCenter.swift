import SwiftUI
import AppKit
import MinisCore

// MARK: - 工具审批 UI 接线（E6）
//
// ApprovalPromptCenter：@MainActor 审批中心。ApprovalDelegate 桥接到
// SwiftUI 弹窗（工具名 / 脱敏输入摘要 / 风险级别 + 允许/拒绝），用
// CheckedContinuation 把「用户点击」转成 async 返回值，供 AgentLoop 的
// ApprovalGate 消费。只在工具执行时触发：低风险工具（autoApprove）不弹窗。

/// A process-local display value minted only by the live approval center.
/// It conveys no authority and is never journaled or used to execute a tool.
struct ApprovalReviewPresentation: Sendable {
    fileprivate let fact: ApprovalLifecycleFact
    static let explanation = "不可逆操作等待第二次确认，尚未授权执行"

    func matchesCurrentExecution(_ identity: AgentExecutionIdentity?) -> Bool {
        guard let identity else { return false }
        return identity == fact.executionIdentity
    }

    func matches(_ event: MinisCore.ConversationEvent) -> Bool {
        event.kind == .approval && event.status == .waiting && event.approvalDecision == .requested
            && event.receiptID == fact.requestID && event.approvalIdentityDigest == fact.identityDigest
            && event.approvalCompositeKey == fact.compositeKey && event.toolName == fact.toolName
            && event.identity.sessionID == fact.compositeKey.sessionID
            && event.identity.turnID == String(fact.compositeKey.turnID)
            && event.identity.attempt == fact.compositeKey.attemptNumber
            && event.identity.taskID == fact.taskID && event.identity.scopeID == fact.scopeID
    }
}

/// 审批弹窗中心（App 级单例装配点，BridgeStore 持有）。
///
/// `present` 由 ApprovalDelegate 调用（AgentLoop 后台 Task → 跳 MainActor），
/// 挂起直到 UI 通过 `resolve` 给出裁决；`pendingRequest` 非 nil 时
/// ContentView 展示审批弹窗。
@MainActor
@Observable
final class ApprovalPromptCenter {
    struct Diagnostic: Sendable, Equatable {
        enum Code: String, Sendable, Equatable {
            case missingConfirmation
            case cancelled
            case expired
            case duplicateResolution
            case overlappingRequest
            case requestMismatch
        }

        let code: Code
        let requestID: String?
        let detail: String
    }

    /// 当前待审批的请求（nil = 无弹窗）
    private(set) var pendingRequest: ApprovalRequest?
    private(set) var pendingGitStatusProjectName: String?
    @ObservationIgnored var gitStatusProjectNameProvider: ((String, String) -> String?)?
    let approvalQueue = ApprovalQueue()
    /// Read-only lifecycle metadata; no summary, tool input or decision authority.
    var onPendingRequestChanged: (@MainActor (String?, String?) -> Void)?
    /// L3 requests remain pending until the user completes the second step.
    private(set) var awaitingConfirmation = false
    /// Last fail-closed event, retained for UI/log inspection and tests.
    private(set) var lastDiagnostic: Diagnostic?
    /// 挂起的 continuation（resolve 时恢复）
    private var continuation: CheckedContinuation<ApprovalDecision, Never>?
    private var expirationTask: Task<Void, Never>?
    /// 只用于显示“X 分钟后自动拒绝”；超时逻辑仍只由 `expirationTask` 决定，不参与持久化。
    private(set) var pendingExpirationDisplayDeadline: Date?
    /// Identifies this waiter, independently of reusable public request/call IDs.
    private var pendingPresentationID: UUID?
    /// Read-only waiter metadata for notification deduplication, never UI identity or authority.
    var pendingRequestLifecycleID: UUID? { pendingPresentationID }
    /// A UI lifetime is separate from the immutable continuation/expiry nonce.
    private var renderedPresentationID: UUID?

    struct TaskCenterPresentationReturn: Equatable {
        fileprivate let waiterID: UUID
        fileprivate let renderedID: UUID
        let navigation: TaskCenterApprovalNavigation
    }
    private var suspendedTaskPresentation: TaskCenterPresentationReturn?
    private(set) var taskCenterResumeIntent: TaskCenterPresentationReturn?
    var isPresentationSuspended: Bool { suspendedTaskPresentation != nil }
    var isPromptPresented: Bool { pendingRequest != nil && !isPresentationSuspended }

    /// Frozen by the existing typed presentation producer, never UI selection.
    private var pendingExecutionIdentity: AgentExecutionIdentity?
    private var pendingPresentationFact: ApprovalLifecycleFact?

    private func matchingPendingPresentation(for request: ApprovalRequest) -> ApprovalLifecycleFact? {
        guard continuation != nil, pendingPresentationID != nil, request == pendingRequest,
              let fact = pendingPresentationFact, pendingExecutionIdentity == fact.executionIdentity,
              request.requestID == fact.requestID, request.identityDigest == fact.identityDigest,
              request.toolName == fact.toolName, request.callID == fact.compositeKey.toolCallID,
              request.sessionID == fact.compositeKey.sessionID, request.turnID == fact.compositeKey.turnID,
              request.attemptID == fact.compositeKey.attemptID,
              request.taskID == fact.taskID, request.approvalScope == fact.scopeID,
              request.runID == nil || request.runID == fact.compositeKey.operationID,
              request.messageID == (request.runID == nil ? fact.compositeKey.messageID : fact.compositeKey.operationID),
              request.expiresAt == nil || request.expiresAt! > Date() else { return nil }
        return fact
    }

    var liveReviewPresentation: ApprovalReviewPresentation? {
        guard awaitingConfirmation, let request = pendingRequest, request.requiresSecondConfirmation,
              let fact = matchingPendingPresentation(for: request) else { return nil }
        return ApprovalReviewPresentation(fact: fact)
    }

    /// Composer already binds the card to its actual execution via the typed
    /// presentation. Its tool requests intentionally lack a legacy binding.
    func matchesPresentedComposerRequest(
        _ request: ApprovalRequest, executionIdentity: AgentExecutionIdentity
    ) -> Bool {
        request.binding == nil && request.runID == nil && request.requiresApproval
            && matchingPendingPresentation(for: request)?.executionIdentity == executionIdentity
    }

    /// Presentation preference (inline strip vs dialog). The object starts in dialog mode;
    /// the assembly layer restores the saved setting (whose default is the inline strip),
    /// and user changes are persisted through `onPresentationPreferenceChanged`.
    var inlineApprovalEnabled = false {
        didSet {
            if oldValue != inlineApprovalEnabled {
                renderedPresentationID = UUID()
                if pendingRequest != nil { presentedAt = Date() }
                notifyPresentationPreferenceChanged()
            }
        }
    }
    /// 用户在界面上改了呈现方式或超时后调用（由装配层接到设置落盘）；装配层回填已存值时不触发。
    var onPresentationPreferenceChanged: ((Bool, TimeInterval) -> Void)?
    private var applyingPersistedPresentation = false
    private func notifyPresentationPreferenceChanged() {
        guard !applyingPersistedPresentation else { return }
        onPresentationPreferenceChanged?(inlineApprovalEnabled, expirationInterval)
    }
    /// 把设置里已保存的审批呈现方式装回来（行内提示条 / 弹窗，超时秒数）。
    func applyPersistedPresentation(inline: Bool, expiration: TimeInterval) {
        applyingPersistedPresentation = true
        defer { applyingPersistedPresentation = false }
        if inlineApprovalEnabled != inline { inlineApprovalEnabled = inline }
        let safe = expiration.isFinite ? max(0, expiration) : 0
        if expirationInterval != safe { expirationInterval = safe }
    }
    var inlineHostAvailable = false {
        didSet {
            if oldValue != inlineHostAvailable {
                renderedPresentationID = UUID()
                if pendingRequest != nil { presentedAt = Date() }
            }
        }
    }
    private(set) var dialogFallbackRequested = false
    var usesInlinePresentation: Bool {
        inlineApprovalEnabled && inlineHostAvailable && !dialogFallbackRequested && isPromptPresented
    }
    /// Applies to newly presented requests; changing it never renews a waiter.
    private(set) var pendingExecutionOrigin: ApprovalExecutionOrigin = .interactive

    var expirationInterval: TimeInterval {
        didSet {
            if oldValue != expirationInterval { notifyPresentationPreferenceChanged() }
        }
    }
    var rememberSameKindInSession = false
    /// User's "allow from now on" choice for the pending prompt only. It is
    /// cleared for every presentation and applied only to an explicit approval
    /// whose request carries an available offer.
    var persistAllowSelected = false
    /// 用户在卡片上写的"拒绝并说明"，只随拒绝结果交给模型，每次展示清空。
    var denialNote = ""
    /// Durable rules shown in Settings. Owned by the Composer grant store;
    /// installed by the production root, nil in isolated fixtures.
    var persistentRules: PersistentApprovalRuleStore?
    var skillRuleFactsProvider: (@MainActor () -> ComposerPolicyFactSource?)? = nil
    /// 规则管理面板用的当前会话信息（授权根、工作目录、会话 ID）；由根视图安装，隔离测试里为 nil。
    var permissionRulesContextProvider: (@MainActor () -> PermissionRulesPanelContext)? = nil
    private(set) var awaitingSkillRiskConfirmation = false
    private var skillRiskConfirmedPresentationID: UUID?

    var pendingSkillActionTitle: String? {
        pendingRequest.flatMap { SkillRiskPresentation.actionTitle($0.toolName) }
    }

    func selectPersistentAllow(_ selected: Bool) {
        persistAllowSelected = selected
        if !selected { skillRiskConfirmedPresentationID = nil }
        awaitingSkillRiskConfirmation = selected && pendingSkillActionTitle != nil
            && skillRiskConfirmedPresentationID != renderedPresentationID
    }

    struct SkillRiskActions {
        let confirm: @MainActor () -> Void
        let cancel: @MainActor () -> Void
    }

    func skillRiskActionsForPresentedRequest() -> SkillRiskActions {
        let waiter = pendingPresentationID
        let rendered = renderedPresentationID
        let request = pendingRequest?.id
        return SkillRiskActions(confirm: { [weak self] in
            guard let self, self.awaitingSkillRiskConfirmation,
                  self.acceptsRenderedAction(waiter, renderedID: rendered, requestID: request) else { return }
            self.skillRiskConfirmedPresentationID = rendered
            self.awaitingSkillRiskConfirmation = false
        }, cancel: { [weak self] in
            guard let self,
                  self.acceptsRenderedAction(waiter, renderedID: rendered, requestID: request) else { return }
            self.selectPersistentAllow(false)
        })
    }

    struct PermissionDirectoryRow: Identifiable {
        let id: UUID
        let path: String
        let scope: String
    }
    var permissionDirectories: (() -> [PermissionDirectoryRow])?
    var requestPermissionDirectory: ((_ project: Bool) throws -> Void)?
    var revokePermissionDirectory: ((UUID) throws -> Void)?
    var permissionDirectoryCreationAvailable: (() -> Bool)?
    struct PermissionProjectRow: Identifiable {
        let id: String
        let name: String
        let path: String
    }
    struct ProjectInstructionTrustRow: Identifiable {
        let projectID: String
        let path: String
        let hash: String
        /// true 表示这是"不加载（记住）"的记录，不是信任。
        var refused = false
        var id: String { projectID + (refused ? ":refused:" : ":") + path }
    }
    var projectInstructionTrustRows: (() -> [ProjectInstructionTrustRow])?
    var revokeProjectInstructionTrust: ((String) throws -> Void)?
    var permissionProjects: (() -> [PermissionProjectRow])?
    var revokePermissionProject: ((String) throws -> Void)?

    struct TemporaryPermissionRow: Identifiable {
        let id: UUID
        let tool: String
        let path: String
        let expiresAt: Date
    }
    func temporaryPermissionRows(sessionID: String) -> [TemporaryPermissionRow] {
        sessionPermissions.filter { $0.sessionID == sessionID && $0.expiresAt > Date() }.map {
            TemporaryPermissionRow(id: $0.id, tool: $0.tool, path: $0.path, expiresAt: $0.expiresAt)
        }
    }
    func revokeTemporaryPermission(_ id: UUID, sessionID: String) {
        sessionPermissions.removeAll { $0.id == id && $0.sessionID == sessionID }
    }

    var browserInteractionRules: BrowserInteractionRuleStore?
    var sessionPermissionLifetime: TimeInterval = 300
    private var presentedAt: Date?
    private struct SessionPermission {
        var id = UUID()
        let sessionID: String
        let policyRevision: String
        let grantEpoch: String
        let tool: String
        let path: String
        let preview: ApprovalFilePreview
        let expiresAt: Date
    }
    private var sessionPermissions: [SessionPermission] = []

    func fallBackToDialog() {
        dialogFallbackRequested = true
        if pendingRequest != nil { presentedAt = Date() }
        // Old inline callbacks must not settle the replacement dialog when
        // SwiftUI removes the old card during the presentation transition.
        renderedPresentationID = UUID()
    }
    func revokeSessionPermissions() { sessionPermissions.removeAll() }
    func endSession(_ sessionID: String) {
        sessionPermissions.removeAll { $0.sessionID == sessionID }
        persistentRules?.clearSessionRules(sessionID: sessionID)
        rememberSameKindInSession = false
        persistAllowSelected = false
    }

    private func reusablePermission(for request: ApprovalRequest) -> SessionPermission? {
        guard inlineApprovalEnabled, !ApprovalExecutionOriginContext.current.isUnattended,
              request.composerMode == nil,
              let sessionID = request.sessionID,
              let policyRevision = request.policyRevision, !policyRevision.isEmpty,
              let grantEpoch = request.grantEpoch, !grantEpoch.isEmpty,
              ["file_write", "file_edit"].contains(request.toolName),
              let preview = request.filePreview, preview.available, !preview.isSensitive,
              let path = preview.version?.canonicalPath,
              !SensitiveFilePolicy.isProtectedGitWritePath(path) else { return nil }
        sessionPermissions.removeAll { $0.expiresAt <= Date() }
        return sessionPermissions.first {
            $0.sessionID == sessionID && $0.tool == request.toolName && $0.path == path
                && $0.policyRevision == policyRevision && $0.grantEpoch == grantEpoch
                && $0.preview == preview && (try? $0.preview.validateCurrent()) != nil
        }
    }

    private func rememberPermission(for request: ApprovalRequest) {
        guard inlineApprovalEnabled, !pendingExecutionOrigin.isUnattended, request.composerMode == nil,
              rememberSameKindInSession, sessionPermissionLifetime.isFinite,
              sessionPermissionLifetime > 0,
              let sessionID = request.sessionID,
              let policyRevision = request.policyRevision, !policyRevision.isEmpty,
              let grantEpoch = request.grantEpoch, !grantEpoch.isEmpty,
              ["file_write", "file_edit"].contains(request.toolName),
              let preview = request.filePreview, preview.available, !preview.isSensitive,
              let path = preview.version?.canonicalPath,
              !SensitiveFilePolicy.isProtectedGitWritePath(path),
              (try? preview.validateCurrent()) != nil else { return }
        sessionPermissions.removeAll { $0.sessionID == sessionID && $0.tool == request.toolName && $0.path == path }
        sessionPermissions.append(SessionPermission(sessionID: sessionID, policyRevision: policyRevision, grantEpoch: grantEpoch, tool: request.toolName,
            path: path, preview: preview, expiresAt: Date().addingTimeInterval(min(sessionPermissionLifetime, 3600))))
        if sessionPermissions.count > 64 { sessionPermissions.removeFirst(sessionPermissions.count - 64) }
    }

    /// Return handling is separate from the approval shortcut and cannot fire
    /// in the first 0.5 seconds. 回车 = 批准（默认按钮，用户 2026-11-17 决定）；
    /// 不可逆操作的二次确认卡、终端策略已拒绝的卡、等待风险确认的卡不适用：回车按拒绝处理，必须显式点击才能批准。
    func handleReturn(focusOnDeny: Bool = false) {
        guard let presentedAt, Date().timeIntervalSince(presentedAt) >= 0.5 else { return }
        if keyboardApprovalBlocked || focusOnDeny {
            actionsForPresentedRequest().deny()
        } else {
            actionsForPresentedRequest().approve()
        }
    }

    /// 回车键在审批卡里的结果（纯函数，便于表格测试）。
    enum ReturnKeyOutcome: Equatable {
        /// 交还给系统（例如等待时长输入框里的回车）。
        case ignored
        /// 吞掉按键，不批准也不拒绝。
        case consumed
        /// 拒绝理由框里的回车：立即带理由拒绝，不受 0.5 秒保护限制。
        case denyWithReason
        /// 没有按钮焦点（或焦点在“允许”上）的普通回车：普通卡批准、必须点击的卡拒绝，由 `handleReturn()` 决定。
        case plainReturn
        /// 焦点在“拒绝”按钮上：回车 = 拒绝。
        case denyFocused
        /// 焦点在“拒绝并说明…”上：回车 = 打开理由框（不批准也不拒绝）。
        case openDenialNote
        /// 焦点在“在任务中心查看”上：回车 = 执行该按钮（暂挂审批提示，不批准也不拒绝）。
        case viewTaskCenter
        /// ⌘回车：普通卡批准，必须点击的卡不做任何事。
        case commandReturn
    }

    /// 审批卡里当前拿着键盘焦点的按钮。
    enum ReturnFocus: Hashable { case deny, allow, denyWithNote, viewTaskCenter }

    /// 规则（用户 2026-11-17 定，对齐 Claude Code：回车选中高亮项）：回车作用于有焦点的按钮——
    /// “拒绝”= 拒绝，“拒绝并说明…”= 打开理由框，“在任务中心查看”= 执行该按钮；
    /// 没有按钮焦点时才按卡片默认：普通卡批准，必须点击的卡一律拒绝、⌘回车不批准；
    /// 拒绝理由框聚焦时回车 = 带理由拒绝。
    nonisolated static func returnKeyOutcome(
        isCommand: Bool, durationOwnsKeyboard: Bool, denialNoteFocused: Bool, focus: ReturnFocus? = nil
    ) -> ReturnKeyOutcome {
        if durationOwnsKeyboard { return isCommand ? .consumed : .ignored }
        if denialNoteFocused { return .denyWithReason }
        if isCommand { return .commandReturn }
        switch focus {
        case .deny: return .denyFocused
        case .denyWithNote: return .openDenialNote
        case .viewTaskCenter: return .viewTaskCenter
        case .allow, nil: return .plainReturn
        }
    }

    /// 审批卡回车键的完整接线：按键结果到动作。返回 false 表示交还给系统。
    func handleReturnKey(
        isCommand: Bool, durationOwnsKeyboard: Bool, denialNoteFocused: Bool, focus: ReturnFocus?,
        openDenialNote: () -> Void, viewTaskCenter: (() -> Void)?
    ) -> Bool {
        switch Self.returnKeyOutcome(
            isCommand: isCommand, durationOwnsKeyboard: durationOwnsKeyboard,
            denialNoteFocused: denialNoteFocused, focus: focus
        ) {
        case .ignored: return false
        case .consumed: return true
        // 正在写拒绝理由：回车 = 带理由拒绝，绝不批准。
        case .denyWithReason: actionsForPresentedRequest().deny()
        case .denyFocused: handleReturn(focusOnDeny: true)
        case .openDenialNote: openDenialNote()
        case .viewTaskCenter: viewTaskCenter?()
        case .plainReturn: handleReturn()
        case .commandReturn: handleCommandReturn()
        }
        return true
    }

    /// 必须用鼠标点"允许"的情形：敏感文件、项目外写入、不可逆操作二次确认、终端策略已拒绝、
    /// 浏览器风险提示，以及正在等待确认的阶段。这些情形下任何键盘快捷方式（回车、⌘回车、⌘Y）都不批准。
    var keyboardApprovalBlocked: Bool {
        let needsExplicitClick = pendingRequest.map {
            $0.requiresSecondConfirmation || $0.terminalPolicyDisposition == .denied
                || $0.browserRiskWarning != nil || $0.requiresExplicitClick
        } ?? true
        return needsExplicitClick || awaitingConfirmation || awaitingSkillRiskConfirmation
    }

    /// ⌘回车：普通卡片批准；必须点击的卡片不做任何事（不批准、也不拒绝）。
    func handleCommandReturn() {
        guard let presentedAt, Date().timeIntervalSince(presentedAt) >= 0.5 else { return }
        guard !keyboardApprovalBlocked else { return }
        actionsForPresentedRequest().approve()
    }
    /// Bound approvals are consumed once at the UI boundary as well as at
    /// `ApprovalGate`, preventing a prompt result from being replayed by a
    /// second presentation of the same immutable identity.
    private var consumedIdentityDigests: Set<String> = []
    private func consumptionKey(for request: ApprovalRequest) -> String? {
        request.identityDigest.map { digest in
            guard let version = request.filePreview?.version else { return digest }
            return digest + ":file:" + version.versionDigest
        }
    }

    /// The reason carried only by the card's own Deny action.
    nonisolated static let userDenialReason = "用户拒绝"

    /// 审批超时（含请求自带截止时间）按拒绝处理时写给模型和转录的原因。
    nonisolated static let timeoutDenialReason = "超时未处理，已拒绝"

    /// 直接构造时默认 0（一直等）；产品默认 300 秒由设置装回（`applyPersistedPresentation`），
    /// 设置里可改，0 = 一直等。无人值守审批不走这个计时。
    init(expirationInterval: TimeInterval = 0) {
        self.expirationInterval = expirationInterval
    }

    /// 展示审批请求并等待用户裁决（ApprovalDelegate 入口）。
    func present(_ request: ApprovalRequest) async -> ApprovalDecision {
        // 防御：上一个请求尚未裁决（顺序循环中不应发生）→ 直接拒绝，避免悬挂。
        guard pendingRequest == nil else {
            record(
                .overlappingRequest,
                requestID: request.id,
                detail: "已有审批请求在处理中"
            )
            return failClosed("已有审批请求在处理中")
        }
        if let expiresAt = request.expiresAt, expiresAt <= Date() {
            let detail = Self.timeoutDenialReason
            record(.expired, requestID: request.id, detail: detail)
            return failClosed(detail, status: .expired, request: request)
        }
        if let identityDigest = consumptionKey(for: request),
           consumedIdentityDigests.contains(identityDigest) {
            let detail = "审批身份已被消费，请重新发起"
            record(.duplicateResolution, requestID: request.id, detail: detail)
            return failClosed(detail, request: request)
        }
        if Task.isCancelled {
            return failClosed("审批调用任务已取消", status: .cancelled, request: request)
        }
        // A hook "ask" is its own question to the user: a remembered same-kind
        // permission (made for the product prompt) must not answer it silently.
        if !request.isHookAsk, reusablePermission(for: request) != nil {
            if let identityDigest = consumptionKey(for: request) { consumedIdentityDigests.insert(identityDigest) }
            return ApprovalDecision(approved: true, reason: "用户已允许本会话内同类操作（限时）",
                confirmed: true, requestID: request.requestID, bindingDigest: request.identityDigest,
                filePreview: request.filePreview)
        }
        let presentationID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                // Cancellation can arrive before this actor installs the waiter.
                guard !Task.isCancelled else {
                    let detail = "审批调用任务已取消"
                    record(.cancelled, requestID: request.id, detail: detail)
                    cont.resume(returning: failClosed(detail, status: .cancelled, request: request))
                    return
                }
                lastDiagnostic = nil
                continuation = cont
                pendingPresentationID = presentationID
                renderedPresentationID = UUID()
                pendingGitStatusProjectName = verifiedGitStatusProjectName(for: request)
                pendingRequest = request
                pendingExecutionOrigin = ApprovalExecutionOriginContext.current
                presentedAt = Date()
                dialogFallbackRequested = false
                rememberSameKindInSession = false
                persistAllowSelected = false
                denialNote = ""
                awaitingSkillRiskConfirmation = false
                skillRiskConfirmedPresentationID = nil
                pendingExecutionIdentity = nil
                pendingPresentationFact = nil
                // Register the waiter before any synchronous observer/expiry
                // can finish it. These observation facts carry no authority.
                if let context = ApprovalPresentationContext.current,
                   let fact = context.makeFact(for: request, stage: .presented) {
                    pendingExecutionIdentity = context.executionIdentity
                    pendingPresentationFact = fact
                    context.eventSink(fact)
                }
                // A synchronous observer may already have finished this waiter.
                guard pendingPresentationID == presentationID else { return }
                onPendingRequestChanged?(request.requestID, request.sessionID)
                guard pendingPresentationID == presentationID else { return }
                if Task.isCancelled {
                    cancelPresentation(presentationID)
                } else {
                    scheduleExpiration(for: request, presentationID: presentationID)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPresentation(presentationID)
            }
        }
    }

    struct PresentationActions {
        let approve: @MainActor () -> Void
        let deny: @MainActor () -> Void
        let dismiss: @MainActor () -> Void
        let viewTaskCenter: @MainActor (TaskCenterApprovalNavigation, TaskCenterControlConsumer) -> Bool
    }

    /// Bind the action to the card and confirmation step the user saw. Public
    /// request IDs can be reused; the existing waiter nonce distinguishes the
    /// replacement without adding another authorization authority.
    func actionsForPresentedRequest() -> PresentationActions {
        let presentationID = pendingPresentationID
        let renderedID = renderedPresentationID
        let requestID = pendingRequest?.id
        let confirmsSecondStep = awaitingConfirmation
        return PresentationActions(
            approve: { [weak self] in
                guard let self,
                      self.acceptsRenderedAction(presentationID, renderedID: renderedID, requestID: requestID) else { return }
                guard let request = self.pendingRequest, request.terminalPolicyDisposition != .denied else { return }
                if request.binding == nil, request.runID == nil, let execution = self.pendingExecutionIdentity {
                    guard self.matchesPresentedComposerRequest(request, executionIdentity: execution),
                          self.awaitingConfirmation == confirmsSecondStep else { return }
                }
                // Button keyboard shortcuts share this action. Protect both
                // stages from the same rapid repeated approval input.
                guard let presentedAt = self.presentedAt,
                      Date().timeIntervalSince(presentedAt) >= 0.5 else { return }
                if confirmsSecondStep { self.confirmPending() }
                else { self.approvePending() }
            },
            deny: { [weak self] in
                guard let self,
                      self.acceptsRenderedAction(presentationID, renderedID: renderedID, requestID: requestID) else { return }
                let note = String(self.denialNote.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
                let reason = note.isEmpty ? Self.userDenialReason : Self.userDenialReason + "：" + note
                self.resolve(approved: false, reason: reason, confirmed: false,
                             requestID: requestID)
            },
            dismiss: { [weak self] in
                guard let self,
                      self.acceptsRenderedAction(presentationID, renderedID: renderedID, requestID: requestID) else { return }
                self.dismissPending()
            },
            viewTaskCenter: { [weak self] navigation, consumer in
                guard let self,
                      self.acceptsRenderedAction(presentationID, renderedID: renderedID, requestID: requestID),
                      let presentationID, let renderedID,
                      self.matchesPendingTaskNavigation(navigation),
                      consumer.pendingApproval(navigation: navigation, pendingRequest: self.pendingRequest) != nil else { return false }
                self.suspendedTaskPresentation = TaskCenterPresentationReturn(
                    waiterID: presentationID, renderedID: renderedID, navigation: navigation
                )
                return true
            }
        )
    }

    private func acceptsRenderedAction(
        _ presentationID: UUID?, renderedID: UUID?, requestID: String?
    ) -> Bool {
        // Explicit navigation owns this old card's disappearance only. Expiry,
        // cancellation and direct dismissPending still settle the same waiter.
        guard !isPresentationSuspended else { return false }
        if pendingPresentationID == presentationID,
           renderedPresentationID != renderedID { return false }
        guard let presentationID, pendingPresentationID == presentationID,
              pendingRequest != nil, continuation != nil else {
            if pendingRequest != nil {
                record(.requestMismatch, requestID: requestID, detail: "审批卡已失效，请使用当前请求")
            }
            return false
        }
        return true
    }

    private func matchesPendingTaskNavigation(_ navigation: TaskCenterApprovalNavigation) -> Bool {
        guard let request = pendingRequest, continuation != nil,
              request.requiresApproval, request.requestID == navigation.requestID,
              request.expiresAt.map({ $0 > Date() }) ?? true else { return false }
        if let binding = request.binding {
            guard binding.isValid, binding.expiresAt > Date(),
                  binding.taskID == navigation.taskID,
                  binding.sessionID == navigation.sessionID,
                  binding.identityDigest == navigation.identityDigest else { return false }
        } else {
            // Composer has no legacy effect binding. Match this card's exact
            // child identity; every suspend/resume action also revalidates the
            // live canonical mapping through consumer.pendingApproval below.
            guard case .childTask(let taskID, let parentID)? = request.source,
                  taskID == navigation.taskID, parentID == navigation.parentID,
                  let mode = request.composerMode, ComposerTaskMode(rawValue: mode) != nil,
                  request.taskID == navigation.taskID,
                  request.sessionID == navigation.sessionID,
                  request.identityDigest == navigation.identityDigest else { return false }
        }
        // Canonical task run/attempt and approval effect run/attempt differ.
        // TaskCenterControlConsumer validates their persisted mapping at the
        // navigation producer and again at every suspend/resume action.
        return true
    }

    func canResumeTaskCenterPresentation(_ navigation: TaskCenterApprovalNavigation) -> Bool {
        guard let suspended = suspendedTaskPresentation,
              pendingPresentationID == suspended.waiterID,
              renderedPresentationID == suspended.renderedID,
              suspended.navigation == navigation else { return false }
        return matchesPendingTaskNavigation(navigation)
    }

    /// Navigation only: never resolve, grant, restart expiry or replace request.
    @discardableResult
    func requestTaskCenterResume(
        _ navigation: TaskCenterApprovalNavigation, consumer: TaskCenterControlConsumer
    ) -> Bool {
        guard canResumeTaskCenterPresentation(navigation),
              consumer.pendingApproval(navigation: navigation, pendingRequest: pendingRequest) != nil,
              let suspendedTaskPresentation else { return false }
        taskCenterResumeIntent = suspendedTaskPresentation
        return true
    }

    @discardableResult
    func resumeFromTaskCenter(
        _ intent: TaskCenterPresentationReturn, consumer: TaskCenterControlConsumer
    ) -> Bool {
        guard taskCenterResumeIntent == intent,
              canResumeTaskCenterPresentation(intent.navigation),
              consumer.pendingApproval(navigation: intent.navigation, pendingRequest: pendingRequest) != nil else { return false }
        suspendedTaskPresentation = nil
        taskCenterResumeIntent = nil
        renderedPresentationID = UUID()
        return true
    }

    func cancelTaskCenterResume(_ intent: TaskCenterPresentationReturn) {
        if taskCenterResumeIntent == intent { taskCenterResumeIntent = nil }
    }

    /// First approval step. L3 requests stop here until `confirmPending`.
    func approvePending(reason: String = "用户允许") {
        guard let request = pendingRequest, continuation != nil else {
            record(.duplicateResolution, requestID: nil, detail: "没有可审批的请求")
            return
        }
        if request.requiresSecondConfirmation {
            guard !awaitingConfirmation else { return }
            awaitingConfirmation = true
            presentedAt = Date()
        } else {
            resolve(
                approved: true,
                reason: reason,
                confirmed: true,
                requestID: request.id
            )
        }
    }

    /// Explicit second UI step for L3 requests.
    func confirmPending(reason: String = "用户确认执行") {
        guard awaitingConfirmation, let request = pendingRequest else {
            record(.duplicateResolution, requestID: pendingRequest?.id, detail: "没有等待二次确认的请求")
            return
        }
        resolve(
            approved: true,
            reason: reason,
            confirmed: true,
            requestID: request.id
        )
    }

    /// Dedicated risk action; generic approve/confirm never sets this bit.
    func confirmBrowserRiskPending() {
        guard awaitingConfirmation, let request = pendingRequest,
              request.browserRiskWarning != nil,
              persistAllowSelected || request.composerMode == ComposerTaskMode.bypassPermission.rawValue else { return }
        resolve(approved: true, reason: "我了解风险，仍然允许", confirmed: true,
                requestID: request.id, browserRiskConfirmed: true)
    }

    /// 用户点击允许 / 拒绝（UI 按钮）→ 恢复挂起的 continuation。
    /// `confirmed` is intentionally optional for compatibility with older
    /// callers, but a missing value is always rejected instead of inferred.
    func resolve(
        approved: Bool,
        reason: String? = nil,
        confirmed: Bool? = nil,
        requestID: String? = nil,
        browserRiskConfirmed: Bool = false
    ) {
        guard let request = pendingRequest, let cont = continuation else {
            record(.duplicateResolution, requestID: requestID, detail: "重复或迟到的审批裁决")
            return
        }
        guard requestID == nil || requestID == request.id else {
            record(.requestMismatch, requestID: requestID, detail: "审批裁决不属于当前请求")
            return
        }
        guard let confirmed else {
            let detail = "缺少独立 confirmed 信号，审批已拒绝"
            finish(
                cont,
                decision: failClosed(detail, request: request),
                diagnostic: Diagnostic(code: .missingConfirmation, requestID: request.id, detail: detail)
            )
            return
        }
        if approved && confirmed && persistAllowSelected,
           SkillRiskPresentation.actionTitle(request.toolName) != nil,
           skillRiskConfirmedPresentationID != renderedPresentationID {
            awaitingSkillRiskConfirmation = true
            return
        }
        if approved && confirmed { rememberPermission(for: request) }
        let previewIsCurrent = request.filePreview.map { (try? $0.validateCurrent()) != nil } ?? true
        if approved, previewIsCurrent, let identityDigest = consumptionKey(for: request),
           !consumedIdentityDigests.insert(identityDigest).inserted {
            let detail = "审批身份已被消费，请重新发起"
            finish(
                cont,
                decision: failClosed(detail, request: request),
                diagnostic: Diagnostic(code: .duplicateResolution, requestID: request.id, detail: detail)
            )
            return
        }
        finish(
            cont,
            decision: ApprovalDecision(
                approved: approved,
                reason: reason,
                confirmed: confirmed,
                requestID: request.requestID,
                bindingDigest: request.identityDigest,
                filePreview: request.filePreview,
                persistAllow: approved && confirmed && persistAllowSelected
                    && request.persistentAllowOffer?.isAvailable == true,
                skillRiskConfirmed: approved && confirmed && persistAllowSelected
                    && pendingSkillActionTitle != nil
                    && skillRiskConfirmedPresentationID == renderedPresentationID,
                browserRiskConfirmed: approved && confirmed && browserRiskConfirmed
                    && request.browserRiskWarning != nil,
                allowInSession: approved && confirmed && rememberSameKindInSession
                    && request.sessionScopeEligible && !pendingExecutionOrigin.isUnattended
            ),
            diagnostic: nil
        )
    }

    /// 弹窗被关闭（未点按钮）→ 取消本次审批，恢复等待者。
    func dismissPending() {
        finishPendingAsFailure(code: .cancelled, detail: "审批弹窗被关闭")
    }

    /// Application termination rejects the current waiter with a distinct reason.
    func rejectForApplicationExit() {
        approvalQueue.cancelPendingForApplicationExit()
        finishPendingAsFailure(code: .cancelled, detail: "应用退出")
    }

    /// F3 停止闭环：生成停止时把挂起审批按拒绝处理（恢复 continuation）。
    /// 由 ChatStore.stopStreaming 经 BridgeStore 装配的 onStreamingStopped 调用 ——
    /// 防「用户停止后弹窗仍挂起，再点允许工具照样执行」。无挂起请求时为无操作。
    func stopGeneration() {
        finishPendingAsFailure(code: .cancelled, detail: "生成已停止")
    }

    /// A regular stop owns one immutable turn/attempt. A child's waiter keeps
    /// its own identity; the existing owning-task cancellation handler settles
    /// it when its verified parent is cancelled, without guessing a parent
    /// from a visible session or widening this stop to another waiter.
    func stopGeneration(for executionIdentity: AgentExecutionIdentity) {
        // Composer requests also have a nil legacy binding. Only the typed
        // presentation context identifies an owning turn; nil cannot grant a
        // scoped stop authority over whichever prompt happens to be visible.
        guard pendingRequest != nil,
              pendingExecutionIdentity == executionIdentity else { return }
        stopGeneration()
    }

    /// Testable/manual expiry hook. Automatic expiry uses the same path.
    func expirePending() {
        finishPendingAsFailure(code: .expired, detail: Self.timeoutDenialReason)
    }

    private func cancelPresentation(_ presentationID: UUID) {
        guard pendingPresentationID == presentationID else { return }
        finishPendingAsFailure(code: .cancelled, detail: "审批调用任务已取消")
    }

    private func scheduleExpiration(for request: ApprovalRequest, presentationID: UUID) {
        expirationTask?.cancel()
        pendingExpirationDisplayDeadline = nil
        if pendingExecutionOrigin.isUnattended {
            expirationTask = nil
            return
        }
        let requestLifetime = request.expiresAt.map { $0.timeIntervalSinceNow }
        let configured: TimeInterval
        if expirationInterval.isFinite && expirationInterval > 0 {
            configured = min(expirationInterval, 3600)
        } else {
            // 默认不自动拒绝；只有请求自带的硬截止时间仍然生效。
            guard let requestLifetime, requestLifetime.isFinite, requestLifetime < 86_400 * 365 else { return }
            configured = requestLifetime
        }
        let delay = min(configured, requestLifetime ?? configured)
        guard delay > 0 else {
            expirePending()
            return
        }
        let nanoseconds = UInt64(delay * 1_000_000_000)
        pendingExpirationDisplayDeadline = Date().addingTimeInterval(delay)
        expirationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            guard self.pendingPresentationID == presentationID else { return }
            self.expirePending()
        }
    }

    private func finishPendingAsFailure(code: Diagnostic.Code, detail: String) {
        guard let request = pendingRequest, let cont = continuation else {
            record(code, requestID: pendingRequest?.id, detail: detail)
            return
        }
        finish(
            cont,
            decision: failClosed(
                detail,
                status: code == .expired ? .expired : .cancelled,
                request: request
            ),
            diagnostic: Diagnostic(code: code, requestID: request.id, detail: detail)
        )
    }

    /// The display name comes from the same frozen facts that made the
    /// offer, plus the current native grant for this request's source session.
    private func verifiedGitStatusProjectName(for request: ApprovalRequest) -> String? {
        guard request.toolName == "shell_execute", request.source == nil,
              let offer = request.persistentAllowOffer, offer.isAvailable,
              offer.capability == request.toolName, offer.summary == "git status",
              let runtime = AgentExecutionContext.current, runtime.childToolRuntimeBinding == nil,
              let snapshot = runtime.composerSnapshot, let facts = runtime.composerPolicyFacts,
              let sessionID = request.sessionID, sessionID == runtime.currentConversationID,
              sessionID == snapshot.sessionID, request.taskID == snapshot.taskID,
              request.turnID == snapshot.turnID, request.attemptID == snapshot.attemptID,
              request.messageID == snapshot.messageID,
              request.approvalScope == snapshot.approvalScope.rawValue,
              request.policyRevision == snapshot.policyRevision, request.grantEpoch == snapshot.grantEpoch,
              facts.workspaceID == snapshot.workspaceID, facts.revision == snapshot.policyRevision,
              facts.grantEpoch == snapshot.grantEpoch, !facts.revoked, facts.expiresAt > Date(),
              ApprovalPresentationContext.current?.makeFact(for: request, stage: .presented) != nil,
              facts.allowedWriteRoots.count == 1,
              let scope = PersistentApprovalRuleMatcher.projectScope(roots: facts.allowedWriteRoots),
              scope.key == offer.projectKey,
              scope.roots.count == 1, let root = scope.roots.first else { return nil }
        return gitStatusProjectNameProvider?(sessionID, root)
    }

    private func finish(
        _ cont: CheckedContinuation<ApprovalDecision, Never>,
        decision: ApprovalDecision,
        diagnostic: Diagnostic?
    ) {
        expirationTask?.cancel()
        expirationTask = nil
        pendingExpirationDisplayDeadline = nil
        continuation = nil
        pendingPresentationID = nil
        renderedPresentationID = nil
        suspendedTaskPresentation = nil
        taskCenterResumeIntent = nil
        pendingExecutionIdentity = nil
        pendingPresentationFact = nil
        pendingGitStatusProjectName = nil
        pendingRequest = nil
        pendingExecutionOrigin = .interactive
        presentedAt = nil
        awaitingConfirmation = false
        persistAllowSelected = false
        denialNote = ""
        awaitingSkillRiskConfirmation = false
        skillRiskConfirmedPresentationID = nil
        if let diagnostic {
            lastDiagnostic = diagnostic
        }
        onPendingRequestChanged?(nil, nil)
        cont.resume(returning: decision)
    }

    private func failClosed(
        _ detail: String,
        status: ApprovalDecisionStatus = .denied,
        request: ApprovalRequest? = nil
    ) -> ApprovalDecision {
        ApprovalDecision(
            approved: false,
            reason: detail,
            confirmed: false,
            status: status,
            requestID: request?.requestID,
            bindingDigest: request?.identityDigest
        )
    }

    private func record(_ code: Diagnostic.Code, requestID: String?, detail: String) {
        lastDiagnostic = Diagnostic(code: code, requestID: requestID, detail: detail)
    }
}

// MARK: - ApprovalDelegate 桥接

/// 把 ApprovalPromptCenter 桥接成 ApprovalDelegate（Sendable）。
/// Center 是 @MainActor 类，无法直接满足 Sendable 协议要求；
/// 经 @unchecked 盒子传递，跨线程访问由 MainActor 隔离保证。
struct ApprovalPromptDelegate: ApprovalDelegate {
    let centerBox: ApprovalPromptCenterBox

    init(center: ApprovalPromptCenter) {
        self.centerBox = ApprovalPromptCenterBox(center: center)
    }

    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        await centerBox.center.approvalQueue.present(request, in: centerBox.center)
    }
}

/// Decision statuses the approval delegate returned, by request ID. The
/// gate maps several different failures to one lifecycle stage; this lets
/// the goal follow-up tell a really expired card or a user denial apart.
/// Observation only: it never grants, denies or changes any decision.
final class ApprovalDecisionStatusLedger: @unchecked Sendable {
    struct Observation: Sendable, Equatable {
        let status: ApprovalDecisionStatus
        let reason: String?
        /// Only the card's own Deny action is the user refusing; fail-closed
        /// denials (another card open, consumed identity, ...) are not.
        var isUserDenial: Bool {
            status == .denied && (reason == ApprovalPromptCenter.userDenialReason
                || reason?.hasPrefix(ApprovalPromptCenter.userDenialReason + "：") == true)
        }
    }

    private let lock = NSLock()
    private var observations: [String: Observation] = [:]

    func record(_ decision: ApprovalDecision, requestID: String) {
        lock.lock(); defer { lock.unlock() }
        if observations.count >= 256 { observations.removeAll() }
        observations[requestID] = Observation(status: decision.status, reason: decision.reason)
    }

    func take(requestID: String) -> Observation? {
        lock.lock(); defer { lock.unlock() }
        return observations.removeValue(forKey: requestID)
    }
}

/// Pass-through delegate: returns the wrapped delegate's decision unchanged
/// and records its status before the gate emits the lifecycle fact.
struct ApprovalDecisionStatusObservingDelegate: ApprovalDelegate {
    let base: any ApprovalDelegate
    let ledger: ApprovalDecisionStatusLedger

    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        let decision = await base.requestApproval(request)
        ledger.record(decision, requestID: request.requestID)
        return decision
    }
}

/// @unchecked Sendable 盒子（与 ToolExecutorBox/LLMProviderBox 同款约定）。
struct ApprovalPromptCenterBox: @unchecked Sendable {
    let center: ApprovalPromptCenter
}

// MARK: - 审批弹窗（SwiftUI）

/// 审批弹窗内容：工具名 / 脱敏输入摘要 / 风险级别徽标 + 允许/拒绝。
/// inputSummary 已由 ApprovalGate.makeInputSummary 脱敏（secret/大 payload 掩码、截断 80 字符）。
struct ApprovalPromptView: View {
    /// 2026-11-15 第七版：技能改动里新增的、提到工具、目录、写入范围、权限、审批、绕过、网络或命令的行。
    /// 只用于提醒，不改变审批结果；技能本身不授予任何权限。
    nonisolated static func skillScopeExpansionLines(_ unifiedDiff: String) -> [String]? {
        let markers = ["工具", "目录", "写入", "权限", "审批", "绕过", "网络", "命令", "范围", "授权",
                       "tool", "directory", "write", "permission", "approval", "bypass", "network", "shell", "allowed"]
        let lines = unifiedDiff.split(separator: "\n", omittingEmptySubsequences: true).compactMap { raw -> String? in
            guard raw.hasPrefix("+"), !raw.hasPrefix("+++") else { return nil }
            let text = raw.dropFirst().trimmingCharacters(in: .whitespaces)
            let lowered = text.lowercased()
            return markers.contains(where: { lowered.contains($0) }) && !text.isEmpty ? String(text.prefix(200)) : nil
        }
        return lines.isEmpty ? nil : Array(lines.prefix(12))
    }

    @Bindable var center: ApprovalPromptCenter
    var shortcutStore: ShortcutStore? = nil
    var onViewTaskCenter: (() -> Void)? = nil
    var identityPasteboard: any PasteboardWriting = NSPasteboard.general
    var adjacentDurationIsFocused = false
    /// 请求所属会话不是当前会话时返回该会话标题（根视图传入）；用于在卡片首行标出来源，不参与授权。
    var originSessionTitle: ((ApprovalRequest) -> String?)? = nil
    /// 弹窗被系统关闭时按"关闭"处理；行内卡片消失（例如点了"在弹窗中审批"、切换会话）时不能处理，
    /// 审批要留给随后出现的弹窗或重新出现的卡片（旅程测试 11/17：点"在弹窗中审批"后审批被当作关闭）。
    var dismissesOnDisappear = true
    @Environment(\.themeTokens) private var theme
    @Environment(\.typographyTokens) private var typography
    @FocusState private var focusedAction: ApprovalAction?
    @FocusState private var lifetimeIsFocused: Bool
    private typealias ApprovalAction = ApprovalPromptCenter.ReturnFocus
    @State private var showsDenialNote = false
    @FocusState private var denialNoteIsFocused: Bool

    private var request: ApprovalRequest? { center.pendingRequest }
    private var durationOwnsKeyboard: Bool { lifetimeIsFocused || adjacentDurationIsFocused }

    private func approvalShortcut(_ action: ShortcutAction) -> ShortcutBinding {
        if durationOwnsKeyboard || denialNoteIsFocused { return ShortcutBinding(key: "", modifiers: ShortcutModifiers.none) }
        // 必须点击批准的卡片：批准快捷键（默认 ⌘Y）不生效。
        if action == .approveRequest, center.keyboardApprovalBlocked {
            return ShortcutBinding(key: "", modifiers: ShortcutModifiers.none)
        }
        return shortcutStore?.binding(for: action) ?? action.defaultBinding
    }

    /// “拒绝并说明…”按钮和它获得焦点时的回车共用：打开理由框并把焦点交给它。
    private func openDenialNote() {
        showsDenialNote = true
        denialNoteIsFocused = true
    }

    var body: some View {
        let actions = center.actionsForPresentedRequest()
        let isExternalSend = request?.toolName == "external_session_send"
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                if let origin = summary.originNotice {
                    Text(origin).font(typography?.caption ?? .caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityIdentifier("approval.summary.origin")
                }
                HStack(spacing: 8) {
                    MinisIconView(riskIcon, size: 20, accessibilityLabel: riskLabel)
                        .foregroundPalette(riskColor)
                    Text(summary.action).font(typography?.headline ?? .headline)
                        .lineLimit(1)
                        .accessibilityIdentifier("approval.summary.action")
                    Spacer()
                    Text(riskLabel)
                        .font(typography?.caption ?? .caption)
                        .lineLimit(1)
                        .foregroundStyle(riskTextColor)
                }
                if isExternalSend, let request {
                    Text(verbatim: ContentSecretRedactor.redact(request.inputSummary))
                        .font(typography?.body ?? .body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("approval.summary.external-send")
                } else {
                    Text(summary.searchDetails ?? summary.target).font(typography?.body ?? .body)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(summary.searchDetails ?? summary.target)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("approval.summary.target")
                    // 首屏只显示缩写目录；完整路径在悬停提示和“详情”的请求输入里。
                    Text(Self.shortDirectory(summary.directory)).font(typography?.caption ?? .caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(summary.directory)
                        .textSelection(.enabled)
                        .accessibilityLabel(summary.directory)
                        .accessibilityIdentifier("approval.summary.directory")
                }
                if let request, request.toolName == "orchestrate", request.riskLevel == .high {
                    Text(verbatim: ApprovalRequestDetailsText.bound(request.inputSummary))
                        .font(typography?.body ?? .body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("approval.summary.orchestration-warning")
                } else if let request, request.toolName == "shell_execute" {
                    // 命令必须完整显示（上限 64KB，更长的命令在核心层已拒绝）：用户批准的就是看到的全部内容。
                    Text(verbatim: ApprovalRequestDetailsText.full(request.inputSummary))
                        .font(typography?.monospaced ?? .system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let request, request.toolName.hasPrefix("mcp_") {
                    let mcp = ApprovalMCPPresentation(toolName: request.toolName, inputSummary: request.inputSummary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: mcp.identityLine)
                            .font(typography?.body ?? .body)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("approval.summary.mcp-identity")
                        Text(verbatim: mcp.argumentsLine)
                            .font(typography?.caption ?? .caption)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("approval.summary.mcp-arguments")
                        Text(mcp.irreversibleNotice)
                            .font(typography?.caption ?? .caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("approval.summary.mcp-irreversible")
                    }
                }
                Text(summary.reason).font(typography?.body ?? .body)
                    .lineLimit(1)
                    .accessibilityIdentifier("approval.summary.reason")
                Text(summary.scope).font(typography?.caption ?? .caption)
                    .lineLimit(1)
                    .accessibilityIdentifier("approval.summary.scope")
                if let deadline = center.pendingExpirationDisplayDeadline {
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        Text(ApprovalCountdownText.text(deadline: deadline, now: context.date))
                            .font(typography?.caption ?? .caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("approval.summary.countdown")
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("approval.summary")

            if let request {
                if request.isHookAsk {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("钩子要求你确认")
                            .font(typography?.caption ?? .caption)
                            .foregroundStyle(theme?.statusWarningText ?? AppStatusColor.warning)
                        Text(request.hookAskReason.flatMap { $0.isEmpty ? nil : $0 } ?? "钩子没有给出原因")
                            .font(typography?.body ?? .body)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("approval.hook-ask-reason")
                }
                if request.toolName == "web_fetch", let authority = request.webFetchAuthority {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("网页目标（主机与端口）")
                            .font(typography?.caption ?? .caption)
                            .foregroundStyle(.secondary)
                        Text(authority)
                            .font(typography?.monospaced ?? .system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Text("临时批准只在确认直连时固定公网 IP。经代理无法固定 IP。无法确认直连路径时也会停止。设置中已允许的网站使用系统网络路径，不固定 IP。")
                            .font(typography?.caption ?? .caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("approval.web-fetch-routing")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("approval.web-fetch-authority")
                }
                if let diff = request.skillDiff {
                    ApprovalFilePreviewView(diff: diff)
                    if let expansion = Self.skillScopeExpansionLines(diff.unifiedDiff) {
                        Text("这次改动新增了可能放宽范围的内容，请确认是你要的：\n" + expansion.joined(separator: "\n"))
                            .font(typography?.caption ?? .caption)
                            .foregroundStyle(theme?.statusDangerText ?? AppStatusColor.danger)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("这次改动新增了可能放宽范围的内容：" + expansion.joined(separator: "；"))
                            .accessibilityIdentifier("approval.skill-scope-expansion")
                    }
                    if let intent = request.skillDeletionIntent {
                        Text("\(intent.targetName)：\(intent.impactSummary)\n恢复位置：.trash/\(intent.operationID.uuidString)")
                            .font(typography?.caption ?? .caption).textSelection(.enabled)
                    }
                } else if let preview = request.filePreview {
                    ApprovalFilePreviewView(preview: preview)
                }

            }

            if request?.sessionScopeEligible == true, !center.pendingExecutionOrigin.isUnattended {
                Toggle(request?.persistentAllowOffer.map { SessionTargetApprovalRules.isSessionTargetCapability($0.capability) } == true
                       ? "本对话内都允许（对此目标会话）" : "本对话内都允许",
                       isOn: $center.rememberSameKindInSession)
                    .accessibilityIdentifier("approval.scope-choice")
            }
            if let warning = request?.browserRiskWarning {
                Text(warning)
                    .font(typography?.body ?? .callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("approval.browser-risk-warning")
            }
            if request?.terminalPolicyDisposition != .denied,
               request?.isHookAsk != true, let offer = request?.persistentAllowOffer {
                VStack(alignment: .leading, spacing: 4) {
                    if offer.isAvailable {
                        Toggle(persistentAllowTitle(for: offer), isOn: Binding(
                            get: { center.persistAllowSelected },
                            set: { center.selectPersistentAllow($0) }))
                            .accessibilityIdentifier("approval.persist-allow")
                        Text(Self.persistentAllowShortNote(offer) ?? Self.persistentAllowNote(offer))
                            .font(typography?.caption ?? .caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let reason = offer.unavailableReason {
                        Text("不提供“以后都允许”：\(reason)")
                            .font(typography?.caption ?? .caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("approval.persist-allow-unavailable")
                    }
                }
            }
            if center.awaitingSkillRiskConfirmation, let action = center.pendingSkillActionTitle {
                let riskActions = center.skillRiskActionsForPresentedRequest()
                VStack(alignment: .leading, spacing: 8) {
                    Text("确认以后允许：" + action).font(typography?.headline ?? .headline)
                    Text(SkillRiskPresentation.warning)
                        .foregroundStyle(riskTextColor)
                    Text("项目：" + SkillRiskPresentation.offerProjectSummary(request?.persistentAllowOffer))
                        .font(typography?.caption ?? .caption)
                    Text("仅对当前项目和当前应用配置的“" + action + "”放行，其他动作仍询问。")
                        .font(typography?.caption ?? .caption)
                    HStack {
                        Button("取消放行，仅保留本次审批", action: riskActions.cancel)
                        Button("我了解风险，仍然允许", action: riskActions.confirm)
                            .accessibilityIdentifier("approval.skill-risk.confirm")
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("approval.skill-risk.warning")
            }
            if center.awaitingConfirmation {
                Text("此高风险操作需要再次确认")
                    .font((typography?.body ?? .callout).weight(.semibold))
                    .foregroundStyle(riskTextColor)
            }

            if let request {
                // 唯一的“详情”折叠：请求详情（已脱敏）与技术身份九项合并在一起。
                ApprovalIdentityDetailsView(request: request, pasteboard: identityPasteboard) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("工具：" + request.toolName)
                        if request.source != nil || request.sourceTaskTitle != nil {
                            Text("来自子任务" + (request.sourceTaskTitle.map {
                                "：" + String(ContentSecretRedactor.redact($0).prefix(120))
                            } ?? ""))
                            .accessibilityIdentifier("approval-child-task-source")
                        }
                        if !isExternalSend {
                            Text("输入（已脱敏，完整内容可滚动查看）")
                            ScrollView {
                                Text(request.toolName == "shell_execute"
                                     ? ApprovalRequestDetailsText.full(request.inputSummary)
                                     : ApprovalRequestDetailsText.bound(request.inputSummary))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(maxHeight: request.toolName == "shell_execute" ? 240 : 180)
                            .font(typography?.monospaced ?? .system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background((theme?.aj38.borderSubtle.swiftUIColor ?? Color.secondary).opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        if request.terminalPolicyDisposition != .denied, !request.isHookAsk,
                           let offer = request.persistentAllowOffer, offer.isAvailable,
                           Self.persistentAllowShortNote(offer) != nil {
                            Text(Self.persistentAllowNote(offer))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(typography?.caption ?? .caption)
                    .accessibilityIdentifier("approval.request-details")
                }
            }

                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 480)
            if request != nil, showsDenialNote || !center.denialNote.isEmpty {
                TextField("拒绝时可以告诉助手怎么改（可选）", text: $center.denialNote)
                    .textFieldStyle(.roundedBorder)
                    .font(typography?.caption ?? .caption)
                    .focused($denialNoteIsFocused)
                    .accessibilityIdentifier("approval.denial-note")
            }
            HStack {
                if let onViewTaskCenter {
                    Button("在任务中心查看", action: onViewTaskCenter)
                        .focusable()
                        .focused($focusedAction, equals: .viewTaskCenter)
                        .help("暂挂此审批提示，在任务中心查看同一待审批任务；不会批准或拒绝")
                        .accessibilityIdentifier("approval.view-task-center")
                }
                Spacer()
                if request != nil, !showsDenialNote, center.denialNote.isEmpty {
                    Button("拒绝并说明…") { openDenialNote() }
                    .buttonStyle(.link)
                    .focusable()
                    .focused($focusedAction, equals: .denyWithNote)
                    .help("拒绝时告诉助手怎么改")
                    .accessibilityIdentifier("approval.deny-with-note")
                }
                Button("拒绝") {
                    actions.deny()
                }
                .shortcutKey(approvalShortcut(.rejectRequest))
                .focusable()
                .focused($focusedAction, equals: .deny)
                .accessibilityLabel("拒绝")
                .accessibilityIdentifier("approval.deny")

                if request?.terminalPolicyDisposition == .denied {
                    Text("终端策略已拒绝，不能批准此命令")
                        .font(typography?.caption ?? .caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("approval.terminal-denied")
                } else {
                    if center.awaitingConfirmation, request?.browserRiskWarning != nil,
                       center.persistAllowSelected || request?.composerMode == ComposerTaskMode.bypassPermission.rawValue {
                        Button("我了解风险，仍然允许") { center.confirmBrowserRiskPending() }
                            .accessibilityLabel("我了解风险，仍然允许")
                            .accessibilityIdentifier("approval.browser-confirm-risk")
                    }
                    Button(approvalButtonTitle) {
                        actions.approve()
                    }
                    .shortcutKey(approvalShortcut(.approveRequest))
                    .focusable()
                    .focused($focusedAction, equals: .allow)
                    .buttonStyle(.bordered)
                    .tint(riskLevel == .high ? riskColor : .accentColor)
                    .foregroundStyle(riskLevel == .high ? riskTextColor : Color.accentColor)
                    .overlay {
                        if riskLevel == .high {
                            RoundedRectangle(cornerRadius: 6).stroke(riskColor, lineWidth: 1)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                    .accessibilityLabel(approvalButtonTitle)
                    .accessibilityIdentifier(
                        center.awaitingConfirmation ? "approval.confirm" : "approval.allow"
                    )
                }
            }
        }
        .padding(20)
        .frame(minWidth: 300, idealWidth: 460, maxWidth: 460)
        .onAppear { focusedAction = Self.defaultFocus(for: request) }
        .onChange(of: request?.id) { _, _ in focusedAction = Self.defaultFocus(for: request) }
        .onChange(of: request?.id) { _, _ in showsDenialNote = false }
        .onKeyPress(keys: [.return], phases: .down) { keyPress in
            // 回车作用于有焦点的按钮（对齐 Claude Code：回车选中高亮项），没有按钮焦点才按卡片默认。
            center.handleReturnKey(
                isCommand: keyPress.modifiers.contains(.command),
                durationOwnsKeyboard: durationOwnsKeyboard, denialNoteFocused: denialNoteIsFocused,
                focus: focusedAction, openDenialNote: openDenialNote, viewTaskCenter: onViewTaskCenter
            ) ? .handled : .ignored
        }
        .onKeyPress(.escape) {
            guard !durationOwnsKeyboard else { return .ignored }
            actions.dismiss()
            return .handled
        }
        .onDisappear {
            // 系统关闭且尚未裁决时取消；Esc 已走同一 dismiss 路径，pending 清空后不重复处理。
            if dismissesOnDisappear, center.pendingRequest != nil {
                actions.dismiss()
            }
        }
    }

    /// 默认焦点在“允许”（回车 = 批准）；不可逆操作的二次确认卡、终端策略已拒绝、带浏览器风险提示的卡默认在“拒绝”。
    private static func defaultFocus(for request: ApprovalRequest?) -> ApprovalAction {
        guard let request else { return .allow }
        return request.terminalPolicyDisposition == .denied || request.requiresSecondConfirmation
            || request.browserRiskWarning != nil || request.requiresExplicitClick ? .deny : .allow
    }

    private var approvalButtonTitle: String {
        if center.awaitingConfirmation, request?.browserRiskWarning != nil { return "仅允许本次" }
        return center.awaitingConfirmation ? "确认执行" : "允许"
    }

    private var riskLevel: ApprovalRiskLevel { request?.riskLevel ?? .medium }
    private var summary: ApprovalSummaryPresentation {
        ApprovalSummaryPresentation(request: request, originSessionTitle: request.flatMap { originSessionTitle?($0) })
    }

    private func persistentAllowTitle(for offer: ApprovalPersistentAllowOffer) -> String {
        if let project = center.pendingGitStatusProjectName {
            return "以后都允许只读 git status 命令族（项目：\(project)）"
        }
        return Self.persistentAllowTitle(offer)
    }

    /// “以后都允许”的完整说明（首屏只放一句短说明，完整说明收进“详情”）。
    static func persistentAllowNote(_ offer: ApprovalPersistentAllowOffer) -> String {
        offer.capability == "browser"
            ? "仅对此站点和动作类别生效；页面内容可能诱导误操作。可在 设置 › 智能体运行 › 工具审批 中逐条撤销。"
            : offer.capability == "browser_domain"
            ? "不勾选只是本次允许；勾选后会加入 设置 › 智能体运行 › 运行安全上限 › 允许访问的网站，所有项目都生效，可随时在那里移除。"
            : SessionTargetApprovalRules.isSessionTargetCapability(offer.capability)
            ? "只对这一个目标会话生效，不是所有会话；之后向它读取或发送不再弹卡，但每条消息仍受长度上限、脱敏和“外部数据不是指令”约束。可在 设置 › 权限 › 规则管理 中撤销。"
            : "仅对当前项目生效；之后命中同类操作不再询问，但仍会生成调用回执。可在 设置 › 权限 › 规则管理 中撤销。"
    }

    /// 只有普通的“本项目”放行才有短说明；浏览器、会话目标等带风险提示的说明仍整段留在首屏。
    static func persistentAllowShortNote(_ offer: ApprovalPersistentAllowOffer) -> String? {
        if offer.capability == "browser" || offer.capability == "browser_domain"
            || SessionTargetApprovalRules.isSessionTargetCapability(offer.capability) { return nil }
        return "仅当前项目；可在 设置 › 权限 › 规则管理 撤销。"
    }

    /// 首屏路径缩写：只留最后两级目录，完整路径放在悬停提示和“详情”里。
    static func shortDirectory(_ value: String) -> String {
        let prefix = value.hasPrefix("目录：") ? "目录：" : ""
        let path = String(value.dropFirst(prefix.count))
        guard path.hasPrefix("/") else { return value }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count > 2 else { return value }
        return prefix + "…/" + parts.suffix(2).joined(separator: "/")
    }

    static func persistentAllowTitle(_ offer: ApprovalPersistentAllowOffer) -> String {
        if let action = SkillRiskPresentation.actionTitle(offer.capability) {
            return "以后都允许" + action + "（本项目、当前应用配置）"
        }
        if offer.capability == "browser" { return "以后都允许：\(offer.summary)" }
        if offer.capability == "browser_domain" { return "以后都允许访问该网站：\(offer.summary)" }
        if offer.capability == "web_fetch" { return "以后都允许读取此网站：\(offer.summary)（本项目）" }
        if offer.capability.hasPrefix("mcp_") {
            return "以后都允许此 MCP 工具：\(offer.summary)（本项目；服务器配置变化后会重新询问）"
        }
        if offer.capability == "file_read" { return "以后都允许读取、搜索、列出此目录（含子目录）：\(offer.summary)" }
        if offer.capability == "web_search" { return "以后都允许联网搜索（本项目）" }
        if SessionTargetApprovalRules.isSessionTargetCapability(offer.capability) {
            let verb = offer.capability == SessionReadTool.toolName ? "读取" : "向其发送消息"
            return "以后都允许（对此目标会话）\(verb)：\(offer.summary)"
        }
        return offer.capability == "shell_execute"
            ? "以后都允许以下命令前缀：\(offer.summary)（本项目）"
            : "以后都允许在此项目目录内\(offer.capability == "file_edit" ? "编辑" : "写入")：\(offer.summary)"
    }

    @ViewBuilder
    private func approvalIdentityRow(_ label: String, _ value: String) -> some View {
        Text("\(label) \(value)")
            .font(.system(.caption2, design: .monospaced))
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    static func riskToken(for level: ApprovalRiskLevel, theme: ThemeTokenProvider) -> ThemeColor {
        switch level {
        case .low: return theme.tokens.statusSuccess
        case .medium: return theme.tokens.statusWarning
        case .high: return theme.tokens.statusDanger
        }
    }

    /// Risk copy is small text (4.5:1), including the existing 18% status
    /// badge fill. This calculation stays independent of approval decisions.
    static func riskTextToken(for level: ApprovalRiskLevel, theme: ThemeTokenProvider) -> ThemeColor {
        let status = riskToken(for: level, theme: theme)
        let tokens = theme.tokens
        let overlay = theme.aj38
        let surfaces = [tokens.background, tokens.sidebarBackground, tokens.surfaceRaised,
                        overlay.backgroundPrimary, overlay.backgroundSecondary,
                        ThemeTokenProvider.nativeSystemTokens(for: theme.mode).background]
        let badgeSurfaces = surfaces.map { surface in
            ThemeColor(r: status.r * 0.18 + surface.r * 0.82,
                       g: status.g * 0.18 + surface.g * 0.82,
                       b: status.b * 0.18 + surface.b * 0.82)
        }
        return tokens.readableStatusText(status, additionalBackgrounds: surfaces + badgeSurfaces)
    }

    private var riskTextColor: Color {
        guard let theme else { return riskColor }
        return Self.riskTextToken(for: riskLevel, theme: theme).swiftUIColor
    }

    private var riskColor: Color {
        if let theme { return Self.riskToken(for: riskLevel, theme: theme).swiftUIColor }
        switch riskLevel {
        case .low: return .green
        case .medium: return .orange
        case .high: return .red
        }
    }

    private var riskIcon: MinisIcon {
        switch riskLevel {
        case .low: return .success
        case .medium: return .warning
        case .high: return .warning
        }
    }

    private var riskLabel: String {
        switch riskLevel {
        case .low: return "低风险"
        case .medium: return "中风险"
        case .high: return "高风险"
        }
    }
}

/// Shared by the dialog and inline host. The collapsed control's value still
/// exposes every technical identity to VoiceOver without duplicating visible rows.
struct ApprovalIdentityPresentation {
    struct Row: Identifiable, Equatable {
        enum Field: String {
            case call, session, task, message, modeScope = "mode-scope", policy, lease
            case inputSHA = "input-sha256", identitySHA = "identity-sha256"
        }
        let field: Field
        let label: String
        let value: String
        var id: String { "approval.identity." + field.rawValue }
        var text: String { label + " " + value }
    }
    let rows: [Row]
    init(request: ApprovalRequest) {
        let modeScope = [request.composerMode, request.approvalScope].compactMap { $0 }.joined(separator: " / ")
        let values: [(Row.Field, String, String?)] = [
            (.call, "Call", request.callID), (.session, "Session", request.sessionID),
            (.task, "Task", request.taskID), (.message, "Message", request.messageID),
            (.modeScope, "模式 / 范围", modeScope.isEmpty ? nil : modeScope),
            (.policy, "Policy", request.policyRevision), (.lease, "Lease", request.grantEpoch),
            (.inputSHA, "Input SHA-256", request.inputDigest), (.identitySHA, "Identity SHA-256", request.identityDigest)
        ]
        rows = values.map { field, label, raw in
            let value = raw.flatMap { $0.isEmpty ? nil : $0 } ?? "missing"
            let safe = ProductRedactionPolicy.redact(value, maxLength: .max)
                .replacingOccurrences(of: "\r", with: "␍").replacingOccurrences(of: "\n", with: "␊")
                .replacingOccurrences(of: "\u{2028}", with: "␊").replacingOccurrences(of: "\u{2029}", with: "␊")
            return Row(field: field, label: label, value: safe)
        }
    }
    var copyText: String { rows.map(\.text).joined(separator: "\n") }
    var accessibilityValue: String { rows.map(\.text).joined(separator: "; ") }
}

/// Five bounded text rows plus the existing decision-button row form the summary.
/// File/diff previews and risk-consent controls keep their independent contracts.
/// “X 分钟后自动拒绝”的显示文案（纯函数，只读时间，不改超时逻辑）。
enum ApprovalCountdownText {
    static func text(deadline: Date, now: Date) -> String {
        let remaining = deadline.timeIntervalSince(now)
        if remaining <= 0 { return "即将自动拒绝" }
        if remaining < 60 { return "不到 1 分钟后自动拒绝" }
        return "约 \(Int((remaining / 60).rounded(.up))) 分钟后自动拒绝"
    }
}

/// MCP 工具审批卡的身份与参数摘要。服务器/工具名按 `mcp_<服务器>_<工具>` 拆分，
/// 服务器名含下划线时拆分可能不准，因此同时给出完整名称。
struct ApprovalMCPPresentation: Equatable {
    static let argumentLimit = 160
    let identityLine: String
    let argumentsLine: String
    let irreversibleNotice = "外部服务端的操作无法由本应用撤销。"

    init(toolName: String, inputSummary: String) {
        let full = ApprovalRequestDetailsText.bound(toolName)
        if let parsed = MCPBoundTool.parseFullName(toolName) {
            identityLine = "MCP 服务器：\(parsed.serverID)　工具：\(parsed.toolName)（完整名称 \(full)）"
        } else {
            identityLine = "MCP 工具：\(full)"
        }
        let redacted = ContentSecretRedactor.redact(inputSummary)
        let trimmed = redacted.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            argumentsLine = "参数：无"
        } else if trimmed.count > Self.argumentLimit {
            argumentsLine = "参数（已脱敏，仅显示前 \(Self.argumentLimit) 字）：" + String(trimmed.prefix(Self.argumentLimit)) + "…"
        } else {
            argumentsLine = "参数（已脱敏）：" + trimmed
        }
    }
}

struct ApprovalSummaryPresentation {
    let action: String
    let target: String
    let searchDetails: String?
    let directory: String
    let reason: String
    let scope: String
    /// 请求不属于当前打开的会话时的来源提示（"来自会话：《标题》"）；属于当前会话时为 nil。只显示，不参与授权。
    let originNotice: String?
    /// `originSessionTitle`：请求所属会话不是当前会话时由根视图传入该会话标题（空串表示没有标题）。
    init(request: ApprovalRequest?, originSessionTitle: String? = nil) {
        if let originSessionTitle {
            let title = ContentSecretRedactor.redact(originSessionTitle.trimmingCharacters(in: .whitespacesAndNewlines))
            originNotice = title.isEmpty ? "来自另一个会话" : "来自会话：《" + Self.middleBound(title) + "》"
        } else {
            originNotice = nil
        }
        let tool = request.map { ContentSecretRedactor.redact($0.toolName) }
        let isFileSearch = request?.toolName == "file_grep" || request?.toolName == "file_glob"
        searchDetails = isFileSearch && request?.filePreview?.isSensitive != true
            ? request.map { ApprovalRequestDetailsText.bound($0.inputSummary) }
            : nil
        switch request?.toolName {
        case "file_read": action = "读取文件"
        case "file_grep": action = "搜索文件内容"
        case "file_glob": action = "查找文件"
        case "file_write": action = "写入文件"
        case "file_edit": action = "编辑文件"
        case "file_delete": action = "删除文件"
        case "shell_execute": action = "执行命令"
        case "skill_create": action = "新建技能"
        case "skill_update": action = "修改技能"
        case "skill_delete": action = "删除技能"
        case "browser": action = "浏览器操作"
        case "web_fetch": action = "读取网页"
        case "web_search": action = "联网搜索"
        case "external_session_send": action = "发送到外部会话"
        case "session_send": action = "发送到本应用其它会话"
        case "session_read": action = "读取本应用其它会话"
        default: action = tool.map { "工具调用：" + $0 } ?? "工具调用审批"
        }
        if request?.filePreview?.isSensitive == true {
            target = "目标已隐藏"
            directory = "目录已隐藏"
        } else if let path = request?.filePreview?.version?.path ?? request?.displayTargetPath {
            let safe = ContentSecretRedactor.redact(path)
            let url = URL(fileURLWithPath: safe)
            target = Self.middleBound(url.lastPathComponent)
            directory = Self.middleBound(url.deletingLastPathComponent().path)
        } else if let shell = Self.shellParts(request) {
            // shell 卡：标题写模型给的说明（没有就写命令首行），下面写目录；完整命令在下方等宽块里。
            target = Self.middleBound(shell.title ?? shell.firstLine)
            directory = "目录：" + Self.middleBound(shell.directory)
        } else if let request, request.toolName == "orchestrate", !request.displayTaskTitles.isEmpty {
            // 只显示子任务标题（Core 已脱敏、截断）；任务正文仍只在折叠详情里。
            target = Self.orchestrateTargetText(request.displayTaskTitles)
            directory = "工具：orchestrate"
        } else {
            target = request?.skillDeletionIntent?.targetName
                ?? request?.webFetchAuthority.map { ContentSecretRedactor.redact($0) }
                ?? (isFileSearch ? nil : request.flatMap { Self.summaryTarget($0.inputSummary) })
                ?? tool.map { "工具：" + $0 }
                ?? "目标见请求详情"
            directory = tool.map { "工具：" + $0 } ?? "完整请求见下方折叠详情"
        }
        switch request?.toolName {
        case "file_write": reason = "可能覆盖目标文件的已有内容。"
        case "file_edit": reason = "将修改目标文件的内容。"
        // 第七版旅程：模型常常删完才说“永久删除”。弹卡说明只出现在非绕过档（绕过档删除不弹卡；
        // 绕过档且文件检查点关闭才移入废纸篓，检查点开启时与此处一样是永久删除、靠检查点找回），
        // 所以卡上直接写明后果，不依赖模型预告。
        case "file_delete": reason = "将永久删除目标文件，不进废纸篓。文件检查点开启时可从恢复入口找回；检查点关闭则无法找回。请核对目标。"
        case "shell_execute": reason = "命令可能更改工作区或系统状态。"
        case "orchestrate": reason = "将派出子智能体执行下列任务，请核对任务和授权范围（见下方详情）后批准。"
        default: reason = "请核对目标和影响后批准本次操作。"
        }
        switch request?.approvalScope {
        case "request": scope = "范围：仅这一次"
        case "session": scope = originSessionTitle == nil ? "范围：当前会话" : "范围：该会话"
        case "workspace": scope = "范围：当前工作区"
        case "turn": scope = "范围：本回合"
        default:
            if let raw = request?.approvalScope, !raw.isEmpty {
                scope = "范围：" + ProductRedactionPolicy.redact(raw)
            } else {
                scope = "范围：未提供"
            }
        }
    }
    /// shell 审批卡的预览文本固定为 `工作目录：…\n[说明：…\n]命令：\n…`（见 ApprovalFilePreview.capture），在这里拆出来。
    private static func shellParts(_ request: ApprovalRequest?) -> (title: String?, firstLine: String, directory: String)? {
        guard let request, request.toolName == "shell_execute",
              let text = request.filePreview?.text, text.hasPrefix("工作目录："),
              let commandMarker = text.range(of: "\n命令：\n") else { return nil }
        let header = String(text[..<commandMarker.lowerBound])
        let command = String(text[commandMarker.upperBound...])
        var directory = ""
        var title: String?
        for (index, line) in header.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if index == 0 { directory = String(line.dropFirst("工作目录：".count)) }
            else if line.hasPrefix("说明：") { title = String(line.dropFirst("说明：".count)) }
        }
        let first = command.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let hasMore = command.contains(where: \.isNewline)
        return (title.flatMap { $0.isEmpty ? nil : $0 }, first + (hasMore ? " …" : ""), directory)
    }

    /// 前 3 个子任务标题，超出写“等 N 个任务”。
    static func orchestrateTargetText(_ titles: [String]) -> String {
        let shown = titles.prefix(3).joined(separator: "、")
        return titles.count > 3 ? "子任务：\(shown) 等 \(titles.count) 个任务" : "子任务：\(shown)"
    }

    private static func summaryTarget(_ inputSummary: String) -> String? {
        // Core's flattened summary is display text. Only its leading field has
        // a trustworthy boundary, so never scan for embedded field-like text.
        for key in ["path", "url", "query"] where inputSummary.hasPrefix(key + ": ") {
            let value = String(inputSummary.dropFirst(key.count + 2))
            guard !value.isEmpty, !value.contains(", "), !value.contains(where: \.isNewline),
                  !value.hasPrefix("<"), !value.hasSuffix("…") else { return nil }
            return ContentSecretRedactor.redact(value)
        }
        return nil
    }

    private static func middleBound(_ value: String) -> String {
        guard value.count > 120 else { return value }
        return String(value.prefix(40)) + "…" + String(value.suffix(79))
    }
}

/// 审批卡唯一的“详情”折叠：技术身份九项 + 调用方传入的请求详情（已脱敏的输入、工具名、子任务来源、完整路径说明）。
struct ApprovalIdentityDetailsView<Extra: View>: View {
    let request: ApprovalRequest
    var pasteboard: any PasteboardWriting
    let extra: Extra
    @State private var expanded = false
    @Environment(\.typographyTokens) private var typography
    init(request: ApprovalRequest,
         pasteboard: any PasteboardWriting = NSPasteboard.general,
         @ViewBuilder extra: () -> Extra) {
        self.request = request
        self.pasteboard = pasteboard
        self.extra = extra()
    }
    private var presentation: ApprovalIdentityPresentation { ApprovalIdentityPresentation(request: request) }
    var body: some View {
        HStack(alignment: .top) {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 6) {
                    extra
                    ForEach(presentation.rows) { row in
                        Text(row.text)
                            .font(typography?.monospaced ?? .system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .accessibilityHidden(true)
                    }
                }
            } label: {
                Text("详情")
            }
            Button("复制全部") {
                copyTextToClipboard(presentation.copyText, pasteboard: pasteboard)
            }
            .accessibilityIdentifier("approval.identity.copy-all")
        }
        .font(typography?.caption ?? .caption)
        // A native DisclosureGroup owns a typed disclosure value and can
        // rebuild its AX node when expanded. Project stable public controls
        // from the same presentation and state instead of overriding that node.
        .accessibilityRepresentation {
            VStack(alignment: .leading) {
                Text(presentation.accessibilityValue)
                    .accessibilityLabel("技术身份")
                    .accessibilityValue(presentation.accessibilityValue)
                    .accessibilityIdentifier("approval.technical-identity")
                Button("详情") {
                    expanded.toggle()
                }
                .accessibilityValue(expanded ? "已展开" : "已折叠")
                .accessibilityIdentifier("approval.identity.toggle")
                extra
                // Keep all nine public fields readable in both visual states.
                // There is no independent identity ledger or disclosure state.
                ForEach(presentation.rows) { row in
                    Text(row.text).accessibilityLabel(row.label).accessibilityValue(row.text)
                        .accessibilityIdentifier(row.id)
                }
                Button("复制全部") {
                    copyTextToClipboard(presentation.copyText, pasteboard: pasteboard)
                }
                .accessibilityIdentifier("approval.identity.copy-all")
            }
            .accessibilityElement(children: .contain)
        }
        .onChange(of: request.id) { _, _ in expanded = false }
    }
}

private enum ApprovalRequestDetailsText {
    /// shell 命令：只脱敏、不截断（上限 72KB，核心层已拒绝超过 64KB 的命令，正常不会触发）。
    static func full(_ text: String) -> String {
        let safe = ContentSecretRedactor.redact(text)
        var data = Data(safe.utf8.prefix(72 * 1024))
        while String(data: data, encoding: .utf8) == nil && !data.isEmpty { data.removeLast() }
        let body = String(data: data, encoding: .utf8) ?? ""
        return body + (body == safe ? "" : "\n…[内容过长，已截断显示]")
    }

    static func bound(_ text: String) -> String {
        let safe = ContentSecretRedactor.redact(text)
        var data = Data(safe.utf8.prefix(4 * 1024))
        while String(data: data, encoding: .utf8) == nil && !data.isEmpty { data.removeLast() }
        let body = String(data: data, encoding: .utf8) ?? ""
        return body + (body == safe ? "" : "\n…[详情已截断；请查看内容预览]")
    }
}

struct ApprovalFilePreviewView: View {
    let text: String
    let expandedText: String?
    @State private var expanded = false
    @Environment(\.typographyTokens) private var typography
    init(preview: ApprovalFilePreview) { self.text = preview.text; self.expandedText = preview.expandedText }
    init(diff: FileChangeDiffPayload) { self.text = diff.unifiedDiff; self.expandedText = nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("变更预览（已脱敏）").font(typography?.caption ?? .caption).foregroundStyle(.secondary)
            ScrollView {
                Text(expanded ? (expandedText ?? text) : text)
                    .font(typography?.monospaced ?? .system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
            if expandedText != nil {
                Button(expanded ? "收起预览" : "展开预览") { expanded.toggle() }
                    .accessibilityIdentifier("approval.file-preview.expand")
            }
        }
        .accessibilityIdentifier("approval.file-preview")
        .onChange(of: text) { _, _ in expanded = false }
    }
}

/// Existing settings surfaces can embed this without creating another
/// permission authority. Durable rules live in `PersistentApprovalRuleStore`.
struct ApprovalPresentationSettingsView: View {
    @Bindable var center: ApprovalPromptCenter
    var body: some View {
        Toggle("审批提示条显示在输入框上方（关闭则用弹窗）", isOn: $center.inlineApprovalEnabled)
        Toggle("审批等待超时自动拒绝", isOn: Binding(
            get: { center.expirationInterval > 0 },
            set: { center.expirationInterval = $0 ? 300 : 0 }))
        if center.expirationInterval > 0 {
            ApprovalDurationField(
                title: "审批等待超时", value: $center.expirationInterval,
                identifier: "settings.approval.expiration-interval"
            )
        }
        Text("默认 300 秒没处理就自动拒绝，并写明“超时未处理，已拒绝”，审批卡上会显示剩余时间。关闭后审批卡会一直等你处理；无人值守的审批不受影响。")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// 规则管理面板（对齐 Claude Code 的 /permissions）：允许、拒绝、每次询问三类规则；
/// 手动新增、编辑、删除；显示范围、来源、创建时间和最近命中时间；导入 .claude/settings.json。
struct PersistentApprovalRulesSettingsView: View {
    @Environment(\.themeTokens) private var theme
    let store: PersistentApprovalRuleStore
    var approvalCenter: ApprovalPromptCenter?
    @State private var model: PermissionRulesPanelModel?
    @State private var confirmingClearAll = false

    init(store: PersistentApprovalRuleStore, approvalCenter: ApprovalPromptCenter? = nil) {
        self.store = store
        self.approvalCenter = approvalCenter
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let model {
                panel(model)
            }
        }
        .sheet(isPresented: Binding(get: { model?.isEditorPresented ?? false },
                                    set: { model?.isEditorPresented = $0 })) {
            if let model { PermissionRuleEditorSheet(model: model) }
        }
        .sheet(isPresented: Binding(get: { model?.isImportPresented ?? false },
                                    set: { model?.isImportPresented = $0 })) {
            if let model { PermissionRulesImportSheet(model: model) }
        }
        .confirmationDialog("清除全部持久规则？", isPresented: $confirmingClearAll) {
            Button("全部清除", role: .destructive) { model?.clearAll() }
        } message: {
            Text("允许、拒绝、每次询问规则都会清除（本会话规则不受影响）；之后这些操作按当前权限模式处理。")
        }
        .onAppear {
            if model == nil {
                let center = approvalCenter
                model = PermissionRulesPanelModel(store: store) {
                    center?.permissionRulesContextProvider?() ?? PermissionRulesPanelContext()
                }
            }
            model?.reload()
        }
    }

    @ViewBuilder
    private func panel(_ model: PermissionRulesPanelModel) -> some View {
        Text("规则管理（对话里输入 /permissions 可打开）")
            .font(.headline)
        Text("拒绝规则命中后直接拒绝，所有权限模式都生效；每次询问规则命中后一定弹卡（绕过权限除外）；允许规则命中后免问，但仍要通过敏感文件、构建配置、授权根等检查。")
            .font(.caption)
            .foregroundStyle(.secondary)
        HStack {
            Button("新增规则") { model.beginAdd() }
                .accessibilityIdentifier("approval.rules.add")
            Button("导入 Claude Code 设置") { model.prepareImport() }
                .accessibilityIdentifier("approval.rules.import")
            if !model.entries.isEmpty {
                Button("全部清除", role: .destructive) { confirmingClearAll = true }
                    .accessibilityIdentifier("approval.rules.clear-all")
            }
        }
        if let feedback = model.feedback, !model.isEditorPresented {
            Text(feedback).font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("approval.rules.feedback")
        }
        if model.entries.isEmpty {
            Text("暂无规则。在审批卡中选择“以后都允许”，或点上方“新增规则”。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("approval.rules.empty")
        }
        ForEach(model.entries) { entry in
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(PermissionRulesPanelModel.behaviorLabel(entry.rule.behavior))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(entry.rule.behavior == .deny ? (theme?.statusDangerText ?? AppStatusColor.danger)
                                : entry.rule.behavior == .ask ? (theme?.statusWarningText ?? AppStatusColor.warning)
                                : (theme?.statusSuccess ?? AppStatusColor.success))
                        Text(Self.title(entry.rule))
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Text("范围：\(PermissionRulesPanelModel.scopeLabel(entry.scope)) · 来源：\(PermissionRulesPanelModel.originLabel(entry.rule.origin)) · 创建：\(PermissionRulesPanelModel.timeText(entry.rule.createdAt)) · 最近命中：\(PermissionRulesPanelModel.timeText(entry.rule.lastMatchedAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if entry.scope == .project, !entry.rule.projectRoots.isEmpty {
                        Text("项目：\(entry.rule.projectRoots.joined(separator: "、"))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                Spacer()
                if PermissionRulesPanelModel.isEditable(entry.rule) {
                    Button("编辑") { model.beginEdit(entry) }
                        .accessibilityLabel("编辑规则 \(Self.title(entry.rule))")
                        .accessibilityIdentifier("approval.rules.edit")
                }
                Button("撤销") { model.remove(entry.rule.id) }
                    .accessibilityLabel("撤销规则 \(Self.title(entry.rule))")
                    .accessibilityIdentifier("approval.rules.delete")
            }
        }
        ForEach(Array(model.diagnostics.enumerated()), id: \.offset) { _, line in
            Text(line)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    static func title(_ rule: PersistentApprovalRule) -> String {
        if let action = SkillRiskPresentation.actionTitle(rule.capability) {
            let activation = rule.pattern == PersistentApprovalRuleMatcher.skillAlwaysPattern
                ? "以后允许" : rule.pattern == PersistentApprovalRuleMatcher.skillBypassPattern
                    ? "仅绕过权限时允许" : "旧规则，仍需风险确认"
            return action + " · " + activation
        }
        switch rule.kind {
        case .shellCommandPrefix: return "命令前缀 \(rule.pattern)"
        case .webHost: return "网站 \(rule.pattern)"
        case .mcpTool:
            return rule.behavior == .allow ? "MCP 工具 \(rule.capability)（当前服务器配置）" : "MCP 工具 \(rule.capability)"
        case .sessionTarget:
            return SessionTargetApprovalRules.ruleDescription(capability: rule.capability, pattern: rule.pattern)
                + "（仅此目标会话）"
        case .projectDirectory:
            if rule.capability == "web_search" { return "联网搜索" }
            let verb = rule.capability == "file_read" ? "读取、搜索 " : (rule.capability == "file_edit" ? "编辑 " : "写入 ")
            return verb + rule.pattern
        }
    }
}

/// The owning chat surface opts in explicitly. If unavailable or requested by
/// the user, the existing dialog remains the presentation fallback.
struct InlineApprovalPromptView: View {
    @Bindable var center: ApprovalPromptCenter
    var originSessionTitle: ((ApprovalRequest) -> String?)? = nil

    // 超时时长是设置项，只在设置页修改；审批卡上只显示剩余时间（11/19 旅途：默认改为 300 秒后
    // 每张卡都多出一个可编辑的"审批等待超时"输入框）。
    var body: some View {
        InlineInteractionCard(title: "") {
            ApprovalPromptView(center: center,
                               originSessionTitle: originSessionTitle, dismissesOnDisappear: false)
            Button("在弹窗中审批") { center.fallBackToDialog() }
        }
    }
}

private struct ApprovalDurationField: View {
    let title: String
    let value: Binding<TimeInterval>
    let identifier: String
    var focus: FocusState<Bool>.Binding? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title)（秒）")
            ValidatedNumericSettingField(
                title, value: value, in: 30...3600, step: 30,
                accessibilityIdentifier: identifier, unit: "秒", externalFocus: focus
            )
        }
    }
}

// MARK: - Preview

#Preview {
    @Previewable @State var center = ApprovalPromptCenter()
    VStack {
        Button("模拟触发审批") {
            Task {
                _ = await center.present(ApprovalRequest(
                    id: "call_1",
                    toolName: "shell_execute",
                    inputSummary: "command: curl -s https://example.com, timeout: 30",
                    riskLevel: .high,
                    requiresApproval: true
                ))
            }
        }
        .padding()
        ApprovalPromptView(center: center)
            .padding()
    }
}
