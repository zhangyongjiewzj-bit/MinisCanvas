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
    static let explanation = "高风险操作等待第二次确认，尚未授权执行"

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

    /// Presentation preferences are process-local and default to the R3 dialog.
    var inlineApprovalEnabled = false {
        didSet {
            if oldValue != inlineApprovalEnabled {
                renderedPresentationID = UUID()
                if pendingRequest != nil { presentedAt = Date() }
            }
        }
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

    var expirationInterval: TimeInterval
    var rememberSameKindInSession = false
    /// User's "allow from now on" choice for the pending prompt only. It is
    /// cleared for every presentation and applied only to an explicit approval
    /// whose request carries an available offer.
    var persistAllowSelected = false
    /// Durable rules shown in Settings. Owned by the Composer grant store;
    /// installed by the production root, nil in isolated fixtures.
    var persistentRules: PersistentApprovalRuleStore?
    var skillRuleFactsProvider: (@MainActor () -> ComposerPolicyFactSource?)? = nil
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
        var id: String { projectID + ":" + path }
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
    /// in the first 0.5 seconds. A high-risk prompt always defaults to refusal.
    func handleReturn() {
        guard let presentedAt, Date().timeIntervalSince(presentedAt) >= 0.5 else { return }
        if pendingRequest?.riskLevel == .high { actionsForPresentedRequest().deny() }
        else { actionsForPresentedRequest().approve() }
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

    init(expirationInterval: TimeInterval = 300) {
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
            let detail = "审批请求已过期"
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
                self.resolve(approved: false, reason: Self.userDenialReason, confirmed: false,
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
        finishPendingAsFailure(code: .expired, detail: "审批请求已过期")
    }

    private func cancelPresentation(_ presentationID: UUID) {
        guard pendingPresentationID == presentationID else { return }
        finishPendingAsFailure(code: .cancelled, detail: "审批调用任务已取消")
    }

    private func scheduleExpiration(for request: ApprovalRequest, presentationID: UUID) {
        expirationTask?.cancel()
        if pendingExecutionOrigin.isUnattended {
            expirationTask = nil
            return
        }
        let configured = expirationInterval.isFinite && expirationInterval > 0
            ? min(expirationInterval, 3600) : 300
        let requestLifetime = request.expiresAt.map { $0.timeIntervalSinceNow }
        let delay = min(configured, requestLifetime ?? configured)
        guard delay > 0 else {
            expirePending()
            return
        }
        let nanoseconds = UInt64(delay * 1_000_000_000)
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
        var isUserDenial: Bool { status == .denied && reason == ApprovalPromptCenter.userDenialReason }
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
    @Environment(\.themeTokens) private var theme
    @Environment(\.typographyTokens) private var typography
    @FocusState private var focusedAction: ApprovalAction?
    @FocusState private var lifetimeIsFocused: Bool
    private enum ApprovalAction: Hashable { case deny, allow }
    @State private var showsRequestDetails = false

    private var request: ApprovalRequest? { center.pendingRequest }
    private var durationOwnsKeyboard: Bool { lifetimeIsFocused || adjacentDurationIsFocused }

    private func approvalShortcut(_ action: ShortcutAction) -> ShortcutBinding {
        if durationOwnsKeyboard { return ShortcutBinding(key: "", modifiers: ShortcutModifiers.none) }
        return shortcutStore?.binding(for: action) ?? action.defaultBinding
    }

    var body: some View {
        let actions = center.actionsForPresentedRequest()
        let isExternalSend = request?.toolName == "external_session_send"
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
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
                    Text(summary.directory).font(typography?.caption ?? .caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(summary.directory)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("approval.summary.directory")
                    if let details = summary.searchDetails {
                        Text(verbatim: details).font(typography?.body ?? .body)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .help(details)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("approval.summary.search-details")
                    }
                }
                if let request, request.toolName == "orchestrate", request.riskLevel == .high {
                    Text(verbatim: ApprovalRequestDetailsText.bound(request.inputSummary))
                        .font(typography?.body ?? .body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("approval.summary.orchestration-warning")
                } else if let request, request.toolName == "shell_execute" {
                    Text(verbatim: ApprovalRequestDetailsText.bound(request.inputSummary))
                        .font(typography?.monospaced ?? .system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let request, request.toolName.hasPrefix("mcp_") {
                    Text(verbatim: ApprovalRequestDetailsText.bound(request.toolName))
                        .font(typography?.body ?? .body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(summary.reason).font(typography?.body ?? .body)
                    .lineLimit(1)
                    .accessibilityIdentifier("approval.summary.reason")
                Text(summary.scope).font(typography?.caption ?? .caption)
                    .lineLimit(1)
                    .accessibilityIdentifier("approval.summary.scope")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("approval.summary")

            if let request {
                if request.isHookAsk {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Hook 要求你确认")
                            .font(typography?.caption ?? .caption)
                            .foregroundStyle(.orange)
                        Text(request.hookAskReason.flatMap { $0.isEmpty ? nil : $0 } ?? "Hook 没有给出原因")
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
                            .foregroundStyle(.red)
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
                Toggle("本对话内都允许", isOn: $center.rememberSameKindInSession)
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
                        Text(offer.capability == "browser"
                             ? "仅对此站点和动作类别生效；页面内容可能诱导误操作。可在 设置 › 智能体运行 › 工具审批 中逐条撤销。"
                             : "仅对当前项目生效；之后命中同类操作不再询问，但仍会生成调用回执。可在 设置 › 权限 › 持久审批规则 中撤销。")
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
                ApprovalIdentityDetailsView(request: request, pasteboard: identityPasteboard)
                if !isExternalSend || request.source != nil || request.sourceTaskTitle != nil {
                    DisclosureGroup("请求详情（已脱敏）", isExpanded: $showsRequestDetails) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("工具：" + request.toolName)
                            if request.source != nil || request.sourceTaskTitle != nil {
                                Text("来自子任务" + (request.sourceTaskTitle.map {
                                    "：" + String(ContentSecretRedactor.redact($0).prefix(120))
                                } ?? ""))
                                .accessibilityIdentifier("approval-child-task-source")
                            }
                            if !isExternalSend {
                                Text("输入（已脱敏）")
                                ScrollView {
                                    Text(ApprovalRequestDetailsText.bound(request.inputSummary))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                }
                                .frame(maxHeight: 180)
                                .font(typography?.monospaced ?? .system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background((theme?.aj38.borderSubtle.swiftUIColor ?? Color.secondary).opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                        .font(typography?.caption ?? .caption)
                    }
                    .accessibilityIdentifier("approval.request-details")
                }
            }

                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 480)
            HStack {
                if let onViewTaskCenter {
                    Button("在任务中心查看", action: onViewTaskCenter)
                        .help("暂挂此审批提示，在任务中心查看同一待审批任务；不会批准或拒绝")
                        .accessibilityIdentifier("approval.view-task-center")
                }
                Spacer()
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
        .onAppear { focusedAction = request?.terminalPolicyDisposition == .denied || riskLevel == .high ? .deny : .allow }
        .onChange(of: request?.id) { _, _ in focusedAction = request?.terminalPolicyDisposition == .denied || riskLevel == .high ? .deny : .allow }
        .onChange(of: request?.id) { _, _ in showsRequestDetails = false }
        .onKeyPress(keys: [.return], phases: .down) { keyPress in
            if durationOwnsKeyboard {
                return keyPress.modifiers.contains(.command) ? .handled : .ignored
            }
            if keyPress.modifiers.contains(.command) {
                actions.approve()
            } else {
                center.handleReturn()
            }
            return .handled
        }
        .onKeyPress(.escape) {
            guard !durationOwnsKeyboard else { return .ignored }
            actions.dismiss()
            return .handled
        }
        .onDisappear {
            // 系统关闭且尚未裁决时取消；Esc 已走同一 dismiss 路径，pending 清空后不重复处理。
            if center.pendingRequest != nil {
                actions.dismiss()
            }
        }
    }

    private var approvalButtonTitle: String {
        if center.awaitingConfirmation, request?.browserRiskWarning != nil { return "仅允许本次" }
        return center.awaitingConfirmation ? "确认执行" : "允许"
    }

    private var riskLevel: ApprovalRiskLevel { request?.riskLevel ?? .medium }
    private var summary: ApprovalSummaryPresentation { ApprovalSummaryPresentation(request: request) }

    private func persistentAllowTitle(for offer: ApprovalPersistentAllowOffer) -> String {
        if let project = center.pendingGitStatusProjectName {
            return "以后都允许只读 git status 命令族（项目：\(project)）"
        }
        return Self.persistentAllowTitle(offer)
    }

    static func persistentAllowTitle(_ offer: ApprovalPersistentAllowOffer) -> String {
        if let action = SkillRiskPresentation.actionTitle(offer.capability) {
            return "以后都允许" + action + "（本项目、当前应用配置）"
        }
        if offer.capability == "browser" { return "以后都允许：\(offer.summary)" }
        if offer.capability == "web_fetch" { return "以后都允许读取此网站：\(offer.summary)（本项目）" }
        return offer.capability == "shell_execute"
            ? "以后都允许此类命令：\(offer.summary)…（本项目）"
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
struct ApprovalSummaryPresentation {
    let action: String
    let target: String
    let searchDetails: String?
    let directory: String
    let reason: String
    let scope: String
    init(request: ApprovalRequest?) {
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
        case "external_session_send": action = "发送到外部会话"
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
        // 第七版旅程：模型常常删完才说“永久删除”。弹卡说明只出现在非绕过档（绕过档删除不弹卡、进废纸篓），
        // 所以卡上直接写明后果，不依赖模型预告。
        case "file_delete": reason = "将永久删除目标文件，不进废纸篓（开启文件检查点时可从恢复入口找回），请核对目标。"
        case "shell_execute": reason = "命令可能更改工作区或系统状态。"
        default: reason = "请核对目标和影响后批准本次操作。"
        }
        switch request?.approvalScope {
        case "request": scope = "范围：仅这一次"
        case "session": scope = "范围：当前会话"
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

struct ApprovalIdentityDetailsView: View {
    let request: ApprovalRequest
    var pasteboard: any PasteboardWriting = NSPasteboard.general
    @State private var expanded = false
    @Environment(\.typographyTokens) private var typography
    private var presentation: ApprovalIdentityPresentation { ApprovalIdentityPresentation(request: request) }
    var body: some View {
        HStack(alignment: .top) {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(presentation.rows) { row in
                    Text(row.text)
                        .font(typography?.monospaced ?? .system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityHidden(true)
                }
            } label: {
                Text("技术详情与审计标识（9 项）")
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
                Button("技术详情与审计标识（9 项）") {
                    expanded.toggle()
                }
                .accessibilityValue(expanded ? "已展开" : "已折叠")
                .accessibilityIdentifier("approval.identity.toggle")
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
        Toggle("行内工具审批", isOn: $center.inlineApprovalEnabled)
        ApprovalDurationField(
            title: "后续审批等待", value: $center.expirationInterval,
            identifier: "settings.approval.expiration-interval"
        )
    }
}

/// Settings list of durable "allow from now on" rules: view, delete one, clear all.
struct PersistentApprovalRulesSettingsView: View {
    let store: PersistentApprovalRuleStore
    @State private var rules: [PersistentApprovalRule] = []
    @State private var diagnostics: [String] = []
    @State private var confirmingClearAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("已允许的规则")
                .font(.headline)
            if rules.isEmpty {
                Text("暂无规则。在审批卡中选择“以后都允许”后会出现在这里。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("approval.rules.empty")
            }
            ForEach(rules) { rule in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.title(rule))
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Text("项目：\(rule.projectRoots.joined(separator: "、"))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button("撤销") {
                        _ = store.remove(id: rule.id)
                        reload()
                    }
                    .accessibilityLabel("撤销规则 \(Self.title(rule))")
                    .accessibilityIdentifier("approval.rules.delete")
                }
            }
            if !rules.isEmpty {
                Button("全部清除", role: .destructive) { confirmingClearAll = true }
                    .accessibilityIdentifier("approval.rules.clear-all")
            }
            ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { reload() }
        .confirmationDialog("清除全部已允许的规则？", isPresented: $confirmingClearAll) {
            Button("全部清除", role: .destructive) {
                _ = store.removeAll()
                reload()
            }
        } message: {
            Text("之后这些操作会重新逐次询问。")
        }
    }

    private func reload() {
        rules = store.allRules()
        diagnostics = store.diagnostics()
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
        case .webHost: return "网站 \(rule.pattern)（本项目）"
        case .projectDirectory:
            return (rule.capability == "file_edit" ? "编辑 " : "写入 ") + rule.pattern
        }
    }
}

/// The owning chat surface opts in explicitly. If unavailable or requested by
/// the user, the existing dialog remains the presentation fallback.
struct InlineApprovalPromptView: View {
    @Bindable var center: ApprovalPromptCenter
    @FocusState private var expirationIsFocused: Bool

    var body: some View {
        InlineInteractionCard(title: "") {
            ApprovalPromptView(center: center, adjacentDurationIsFocused: expirationIsFocused)
            Button("在弹窗中审批") { center.fallBackToDialog() }
            ApprovalDurationField(
                title: "后续审批等待", value: $center.expirationInterval,
                identifier: "approval.inline.expiration-interval", focus: $expirationIsFocused
            )
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
