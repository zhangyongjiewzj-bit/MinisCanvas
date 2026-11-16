import SwiftUI
import MinisCore

// MARK: - W5-COMPOSER-CMD-POLICY-WIRE-059
//
// Composer 斜杠命令策略钩子的生产接线层。
//
// 事实（本文件创建前的候选 head 5da32bdfe）：
//   · ChatStore 声明 `onComposerCommandPolicy`，但生产组合根从未赋值；
//   · 未接线时除 compact 外全部斜杠命令默认 .pending，且没有任何批准/拒绝
//     UI 消费 `pendingComposerCommand` ⇒ 用户提交命令后永远没有下一步。
//
// 本层是唯一被授权在 059 写集内闭合该缺口的实现：
//   1. `ComposerCommandAdjudicationCenter` 在组合根被接入
//      `ChatStore.onComposerCommandPolicy`，对每次命令请求做真实策略评估：
//      - 事实源失效（revoked / lease 过期 / leaseID 空 / workspace 或
//        revision/epoch 与提交快照不一致）→ 一律 .reject（fail-closed）；
//      - 调度器 lane（snapshot.taskID 前缀 "scheduler-effect:"，effectID 由
//        SchedulerTaskStore 命名空间生成）：compact 在任务确认时已经用户批准，
//        非 compact 一律 .reject，绝不把调度路径挂成无人消费的 pending；
//      - 具备执行入口且需要批准的命令（compact / model 等）→ .pending，
//        并挂载可见的待裁决卡（批准 / 拒绝 / 超时终态）；缺执行入口时
//        直接拒绝，不制造无法执行的待批准卡；
//      - 展示类命令（help / status / tasks）→ .execute（ChatStore 规范消费，
//        不进 transcript），同时投影可见结果文本，绝不静默吞掉。
//   2. 批准不放宽任何确认语义：compact 的一次性令牌只允许紧随其后的规范
//      重放（composer 文本入口 → submitComposer → routeComposerSlashCommand
//      的 `.execute` 分支），由 ChatStore 自己清除 pending 并执行唯一入口
//      `compactContext()`；model / settings.* 的批准只移交 Settings 唯一规范
//      配置入口（isSettingsPresented 同一状态），不旁路另造模型选择状态。
//   3. 超时自动按拒绝收敛；新命令会取代（supersede）未答复的旧裁决，
//      未答复命令永远不会被静默保留为可执行。
//
// 明确不在本层解决（越界即不接纳，见回执 WRITE_SET_ESCALATION_REQUESTED）：
//   · ChatStore 的 `.pending/.reject` 决策与 `.execute`-非 compact 分支不清除
//     `pendingComposerCommand`（ChatStore.swift:3160-3186，lane 052 独占），
//     裁决终态由本层持有；组合根之外无写权限。
//   · `pendingComposerCommand` 从磁盘 envelope 恢复（ChatStore.swift:4630-4631）
//     后本层不自动重放执行 —— 批准只在用户点击时一次性有效。

/// The execution dependency known to the Composer adjudication consumer.
/// This is not an availability, permission, or Provider health verdict: the
/// Bridge must combine it with current facts, and submission still evaluates
/// the policy lease and approval for the exact request.
enum ComposerCommandReadinessContract: Equatable, Sendable {
    case unregistered
    case missingExecutor(reason: String)
    case displayOnly
    case localClipboard
    case localDesktopAction
    case canonicalSettingsHandoff
    /// Records a proposed envelope only; fact approval stays with MemoryProposalConsumer.
    case scopedMemoryProposal
    /// Chooses an already applied readiness-backed model; never probes or sends.
    case canonicalModelSelection
    /// Consumes one frozen action on an already presented, bound tool request.
    case presentedToolApproval
    case scopedAdditionalDirectory
    /// The ordinary /compact path resolves a Provider only when non-system
    /// history exceeds `keepRecent`; short history returns before that step.
    case compactConditionalProvider(keepRecent: Int)
    /// A future registered execution route is not ready merely because it is
    /// in a registry or one of the adjudication sets.
    case unverifiedExecutionRoute
}

extension Notification.Name {
    /// ChatStore 在手动压缩出结果（成功/未压缩/失败/取消）后发出，userInfo["message"] 为结果短句。
    static let composerManualCompactionFinished = Notification.Name("composerManualCompactionFinished")
}

private final class CompactionObserverBox: @unchecked Sendable {
    var token: NSObjectProtocol?
}

/// Composer 斜杠命令裁决中心（App 级，组合根持有并接线）。
@MainActor
@Observable
final class ComposerCommandAdjudicationCenter {

    // MARK: - 终态模型

    enum TerminalOutcome: Equatable, Sendable {
        /// 用户批准；compact 已被规范重放消费，memory.propose 已记录待审提案。
        case approvedExecuted
        /// 用户批准，执行移交 Settings 唯一规范入口（model / settings.*）。
        case handedToCanonicalSettings
        /// 用户显式拒绝。
        case deniedByUser
        /// 超时未答复，按拒绝收敛。
        case expiredUnanswered
        /// 未答复期间被更新一条命令取代。
        case supersededByNewCommand
        /// 策略事实失效等被策略层直接拒绝（携带原因）。
        case rejectedByPolicy(String)
        /// The registered command has no approved production executor. This
        /// is an immediate availability rejection, not a user policy choice.
        case unavailableExecutor(String)
    }

    /// 等待用户裁决的命令（仅需要批准的命令会进入该状态）。
    struct PendingAdjudication: Identifiable, Equatable {
        let id: UUID                 // PendingCommandRequest.id
        let commandID: String
        let args: [String: String]
        let sessionID: String
        let policySummary: String
        let requestedAt: Date
        let expiresAt: Date
    }

    /// 已收敛的裁决终态（回执投影的数据源之一）。
    struct Resolution: Identifiable, Equatable {
        let id: UUID
        let commandID: String
        let sessionID: String
        let outcome: TerminalOutcome
        let resolvedAt: Date
    }

    /// 卡片可见的结果/回执投影；用户点「知道了」后清除。
    struct AcknowledgedProjection: Identifiable, Equatable {
        let id: UUID
        let commandID: String
        let text: String
        let emittedAt: Date
    }

    // MARK: - 可见状态

    private(set) var pendingAdjudication: PendingAdjudication?
    private(set) var lastResolution: Resolution?
    private(set) var projection: AcknowledgedProjection?

    /// Reuses donor 6cc206552/9d2cd1125 without mutating the installed source.
    /// A second registration here would erase current availability/overrides.
    @ObservationIgnored private(set) var commandRegistry: CommandRegistry = .shared
    @ObservationIgnored private var installedCommandRegistry: CommandRegistry?
    @ObservationIgnored private var commandRegistryUsed = false

    @discardableResult
    func installCommandRegistry(_ registry: CommandRegistry) -> Bool {
        if let installedCommandRegistry { return installedCommandRegistry === registry }
        guard !commandRegistryUsed, pendingAdjudication == nil else { return false }
        commandRegistry = registry
        installedCommandRegistry = registry
        return true
    }

    // MARK: - 组合根注入的接线点（nil = 未接线，一律 fail-closed）

    /// 规范重放入口：把批准后的 slash 文本经 composer 提交入口重新路由。
    var replaySubmittedCommand: ((String) -> Void)?
    /// 重放前置条件：composer 输入框为空且无待发附件，避免覆盖用户草稿。
    var canReplayIntoComposer: (() -> Bool)?
    /// Settings 唯一规范配置入口（与工具栏齿轮 / ⌘, / 深链同一 state）。
    var openCanonicalSettings: (() -> Void)?
    struct MemoryProposalApprovalContext {
        let request: PendingCommandRequest
        let snapshot: ComposerSubmissionSnapshot
        let facts: ComposerPolicyFactSource
        let scope: MemoryScope
    }
    /// Exact current scope at initial submission, never derived from model text.
    var memoryProposalScopeProvider: (() -> MemoryScope?)?
    /// Existing canonical consumer for an authorized proposal submission.
    var submitApprovedMemoryProposal: ((MemoryProposalApprovalContext) throws -> MemoryProposalEnvelope)?
    @ObservationIgnored private var memoryProposalApprovalContext: MemoryProposalApprovalContext?

    struct ProviderSelectionApprovalContext {
        let request: PendingCommandRequest
        let snapshot: ComposerSubmissionSnapshot
        let facts: ComposerPolicyFactSource
        let receipt: ChatModelPickerApplyReceipt
    }
    var prepareProviderSelection: ((PendingCommandRequest, ComposerSubmissionSnapshot, ComposerPolicyFactSource) throws -> ProviderSelectionApprovalContext)?
    var applyApprovedProviderSelection: ((ProviderSelectionApprovalContext) throws -> ChatModelPickerApplyReceipt)?
    @ObservationIgnored private var providerSelectionApprovalContext: ProviderSelectionApprovalContext?

    struct PresentedToolApprovalContext {
        let request: PendingCommandRequest
        let snapshot: ComposerSubmissionSnapshot
        let facts: ComposerPolicyFactSource
        let target: ApprovalRequest
        let confirmsSecondStep: Bool
        let actions: ApprovalPromptCenter.PresentationActions
    }
    enum PresentedToolApprovalResult {
        case awaitingSecondConfirmation
        case submittedToOriginalGate
    }
    /// The command center never presents/replaces the target tool waiter.
    var preparePresentedToolApproval: ((PendingCommandRequest, ComposerSubmissionSnapshot, ComposerPolicyFactSource) throws -> PresentedToolApprovalContext)?
    var applyPresentedToolApproval: ((PresentedToolApprovalContext) throws -> PresentedToolApprovalResult)?
    @ObservationIgnored private var presentedToolApprovalContext: PresentedToolApprovalContext?

    struct WorkflowApprovalContext {
        let request: PendingCommandRequest
        let snapshot: ComposerSubmissionSnapshot
        let facts: ComposerPolicyFactSource
        let commandText: String
        let parsed: WorkflowChatRequest
        let template: WorkflowTemplate
    }
    /// The App root binds these to its existing WorkflowChatController.
    var prepareWorkflow: ((PendingCommandRequest, ComposerSubmissionSnapshot, ComposerPolicyFactSource) throws -> WorkflowApprovalContext)?
    var applyApprovedWorkflow: ((WorkflowApprovalContext) throws -> Void)?
    @ObservationIgnored private var workflowApprovalContext: WorkflowApprovalContext?

    /// A directory request is frozen before the approval card is shown. The
    /// App root alone verifies identity and publishes next-task root snapshots.
    struct AdditionalDirectoryApprovalContext {
        let request: PendingCommandRequest
        let snapshot: ComposerSubmissionSnapshot
        let facts: ComposerPolicyFactSource
        let physicalDirectory: URL
        let directoryIdentity: String
        let projectID: String
        let workingDirectory: String
        let attachmentGeneration: UInt64
        var directoryRevision: String = ""
        var nativeManagement = false
        var sessionDirectoryWasImplicit = false
    }
    struct AdditionalDirectoryReceipt {
        let requestID: UUID
        let sessionID: String
        let path: String
    }
    var prepareAdditionalDirectory: ((PendingCommandRequest, ComposerSubmissionSnapshot, ComposerPolicyFactSource) throws -> AdditionalDirectoryApprovalContext)?
    var applyApprovedAdditionalDirectory: ((AdditionalDirectoryApprovalContext) throws -> AdditionalDirectoryReceipt)?
    @ObservationIgnored private var additionalDirectoryApprovalContext: AdditionalDirectoryApprovalContext?

    /// /status 结果文本（组合根注入会话忙闲等运行时事实）。
    var statusProjection: ((ComposerSubmissionSnapshot) -> String)?
    /// Bound by the composition root to existing desktop consumers. Evaluation
    /// invokes this only after current lease/policy and availability checks.
    var desktopCommandAction: ((PendingCommandRequest, ComposerSubmissionSnapshot) throws -> String)?
    static let desktopCommandIDs: Set<String> = [
        "model", "permissions", "memory", "mcp", "context", "clear", "rewind",
        "doctor", "usage", "export", "rename", "resume", "plan", "skills", "shortcuts",
        // N2: same entries as the Stop button, failed-row Retry and approval-card Deny.
        "stop", "retry", "reject",
    ]
    var copyReply: ((Int, ComposerSubmissionSnapshot) -> String)?
    /// /tasks 结果文本（组合根注入调度任务计数等）。
    var tasksProjection: (() -> String)?
    /// /boundary reads the committed safety snapshot through the composition
    /// root. Nil means no current fact source; it must never be guessed from a
    /// command's registration or requested permission.
    var boundaryProjection: ((ComposerSubmissionSnapshot) -> String?)?
    /// /provider reads the applied, secret-free Provider/Model snapshot. A
    /// selectable catalog row is not proof of an applied Provider.
    var providerProjection: ((ComposerSubmissionSnapshot) -> String?)?
    /// Only observed blockers from the same production menu fact source.
    /// Absence is not permission or proof of execution readiness.
    var commandAvailabilityReason: ((String) -> String?)?
    /// A terminal transition of a genuinely pending request. The resolution
    /// carries the original request UUID so the composition root can ask
    /// ChatStore to clear only that matching durable pending request. An
    /// immediate submission rejection does not emit this callback.
    var onPendingTerminalResolution: ((Resolution) -> Void)?
    /// 审计日志（组合根接 LogManager）。
    var eventLogger: ((String) -> Void)?

    /// 可测时钟（默认系统时间；测试注入固定时刻）。
    var clock: () -> Date = { Date() }
    /// 待裁决自动拒绝时限。
    var adjudicationTimeout: TimeInterval = 120
    /// 批准令牌（一次性重放授权）时限。
    var approvalTokenLifetime: TimeInterval = 30

    // MARK: - 内部状态

    /// 一次性批准令牌：只授权「批准 → 紧随其后的同一规范命令重放」。
    private struct ApprovalToken: Equatable {
        let commandID: String
        let args: [String: String]
        let sessionID: String
        let issuedAt: Date
    }

    private var approvalToken: ApprovalToken?
    private var expirationTask: Task<Void, Never>?

    /// 需要移交 Settings 规范入口的批准命令（不自动配置、不旁路执行）。
    static let canonicalSettingsCommandIDs: Set<String> = ["settings.open", "settings.reset"]
    /// 具备真实直接执行入口、可用一次性令牌重放的命令。
    static let replayExecutedCommandIDs: Set<String> = ["compact"]
    /// 展示类（无副作用）命令的规范 ID。
    static let displayOnlyCommandIDs: Set<String> = [
        "help", "commands", "status", "tasks", "usage", "boundary", "provider",
    ]

    /// The actual adjudication consumer owns only these execution paths.
    /// Registration and a Policy/Approval bit do not imply that approval can
    /// execute a command. The Composer menu may project this concrete blocker
    /// while keeping the command discoverable.
    private static let boundarySettingsReason = "暂不可用，请在设置→智能体调整自主权上限。"

    static func missingExecutorReason(for commandID: String) -> String? {
        let id = CommandDefinition.canonicalID(commandID)
        guard CommandRegistry.composerCommandIDs.contains(id) else { return nil }
        if id == "boundary.set" { return boundarySettingsReason }
        if desktopCommandIDs.contains(id) || id == "copy" || displayOnlyCommandIDs.contains(id)
            || replayExecutedCommandIDs.contains(id)
            || canonicalSettingsCommandIDs.contains(id)
            || id == "memory.propose" || id == "provider.use" || id == "approve"
            || id == "workflow" || id == "add-dir" {
            return nil
        }
        return "当前没有已接线的生产执行入口"
    }

    /// Project only the execution dependency this consumer can prove. The
    /// unsupported-command result reuses `missingExecutorReason`, so the menu
    /// and submit-time rejection cannot drift into separate executor maps.
    /// In particular, the conditional /compact route does not say a Provider
    /// is configured or reachable, and Settings/display routes acquire no
    /// invented Provider or capability prerequisite here.
    static func readinessContract(for commandID: String) -> ComposerCommandReadinessContract {
        let id = CommandDefinition.canonicalID(commandID)
        guard CommandRegistry.composerCommandIDs.contains(id) else { return .unregistered }
        if let reason = missingExecutorReason(for: id) {
            return .missingExecutor(reason: reason)
        }
        if Self.desktopCommandIDs.contains(id) { return .localDesktopAction }
        if id == "copy" { return .localClipboard }
        if displayOnlyCommandIDs.contains(id) { return .displayOnly }
        if canonicalSettingsCommandIDs.contains(id) { return .canonicalSettingsHandoff }
        if id == "memory.propose" { return .scopedMemoryProposal }
        if id == "provider.use" { return .canonicalModelSelection }
        if id == "approve" { return .presentedToolApproval }
        if id == "add-dir" { return .scopedAdditionalDirectory }
        if id == "compact", replayExecutedCommandIDs.contains(id) {
            // Matches ChatStore.compactContext(keepRecent: 3), whose early
            // history guard precedes activeProvider(). This is an extraction
            // boundary, not a new compaction or permission policy.
            return .compactConditionalProvider(keepRecent: 3)
        }
        return .unverifiedExecutionRoute
    }

    init() {}

    // MARK: - 策略评估（ChatStore.onComposerCommandPolicy 生产实现）

    func evaluate(
        request: PendingCommandRequest,
        snapshot: ComposerSubmissionSnapshot,
        facts currentFacts: ComposerPolicyFactSource
    ) -> ComposerCommandPolicyDecision {
        commandRegistryUsed = true
        let now = clock()
        let facts = request.commandID == "approve" && ChatStore.keyboardComposerCommandRequestID == request.id
            ? ChatStore.nativeWaitingToolApprovalFacts ?? currentFacts : currentFacts

        // 1) fail-closed：事实源无效或快照与事实不匹配一律拒绝，
        //    并撤销任何未答复裁决与令牌（策略已变，旧批准不得幸存）。
        guard !facts.revoked,
              facts.expiresAt > now,
              !facts.leaseID.isEmpty,
              !snapshot.workspaceID.isEmpty,
              snapshot.workspaceID == facts.workspaceID,
              snapshot.policyRevision == facts.revision,
              snapshot.grantEpoch == facts.grantEpoch
        else {
            let reason: String
            if facts.revoked { reason = "策略租约已吊销" }
            else if facts.expiresAt <= now { reason = "策略租约已过期" }
            else if facts.leaseID.isEmpty { reason = "策略租约缺少身份" }
            else { reason = "提交快照与策略事实不匹配" }
            supersedeUnanswered(now: now)
            approvalToken = nil
            lastResolution = Resolution(
                id: request.id,
                commandID: request.commandID,
                sessionID: snapshot.sessionID,
                outcome: .rejectedByPolicy(reason),
                resolvedAt: now
            )
            projection = AcknowledgedProjection(
                id: request.id,
                commandID: request.commandID,
                text: "命令 /\(request.commandID) 被策略拒绝：\(reason)。未执行任何副作用。",
                emittedAt: now
            )
            log("Composer 命令 /\(request.commandID) fail-closed 拒绝：\(reason)")
            return .reject
        }

        // A registered approval-required command with no production executor
        // cannot become an approvable card. Today this derives exactly the
        // six D-COMMAND-06 gaps from the canonical registry/adjudication facts;
        // it also fails closed if another unsupported command is registered.
        // ChatStore owns the synchronous `.reject` receipt/pending transition.
        var preparedProviderSelection: ProviderSelectionApprovalContext?
        var providerSelectionReason: String?
        if request.commandID == "provider.use" {
            if let prepare = prepareProviderSelection, applyApprovedProviderSelection != nil {
                do { preparedProviderSelection = try prepare(request, snapshot, facts) }
                catch { providerSelectionReason = (error as? CommandExecutionError)?.errorDescription ?? String(describing: error) }
            } else { providerSelectionReason = "当前没有已接线的生产执行入口" }
        }
        var preparedToolApproval: PresentedToolApprovalContext?
        var toolApprovalReason: String?
        if request.commandID == "approve" {
            if let prepare = preparePresentedToolApproval, applyPresentedToolApproval != nil {
                do { preparedToolApproval = try prepare(request, snapshot, facts) }
                catch { toolApprovalReason = (error as? CommandExecutionError)?.errorDescription
                    ?? "原工具审批目标不可用" }
            } else { toolApprovalReason = "当前没有已接线的生产执行入口" }
        }
        var preparedWorkflow: WorkflowApprovalContext?
        var workflowReason: String?
        if request.commandID == "workflow" {
            if let prepare = prepareWorkflow, applyApprovedWorkflow != nil {
                do { preparedWorkflow = try prepare(request, snapshot, facts) }
                catch { workflowReason = (error as? CommandExecutionError)?.errorDescription
                    ?? "工作流目标不可用" }
            } else { workflowReason = "当前没有已接线的生产执行入口" }
        }
        var preparedAdditionalDirectory: AdditionalDirectoryApprovalContext?
        var additionalDirectoryReason: String?
        if request.commandID == "add-dir" {
            if let prepare = prepareAdditionalDirectory, applyApprovedAdditionalDirectory != nil {
                do { preparedAdditionalDirectory = try prepare(request, snapshot, facts) }
                catch { additionalDirectoryReason = (error as? CommandExecutionError)?.errorDescription
                    ?? "目录身份或当前项目授权不可用" }
            } else { additionalDirectoryReason = "当前没有已接线的生产执行入口" }
        }
        let missingReason = (Self.desktopCommandIDs.contains(request.commandID) && desktopCommandAction == nil
            ? "桌面命令入口未接线" : nil)
            ?? additionalDirectoryReason ?? workflowReason ?? toolApprovalReason ?? providerSelectionReason
            ?? Self.missingExecutorReason(for: request.commandID)
            ?? (request.commandID == "memory.propose" && submitApprovedMemoryProposal == nil
                ? "当前没有已接线的生产执行入口" : nil)
            ?? (request.commandID == "memory.propose" && memoryProposalScopeProvider?()?.isValid != true
                ? "当前会话没有有效项目记忆范围" : nil)
        if request.requiresPolicyApproval || Self.desktopCommandIDs.contains(request.commandID),
           let reason = missingReason {
            if !Self.displayOnlyCommandIDs.contains(request.commandID) {
                supersedeUnanswered(now: now)
                approvalToken = nil
            }
            lastResolution = Resolution(
                id: request.id,
                commandID: request.commandID,
                sessionID: snapshot.sessionID,
                outcome: .unavailableExecutor(reason),
                resolvedAt: now
            )
            projection = AcknowledgedProjection(
                id: request.id,
                commandID: request.commandID,
                text: request.commandID == "boundary.set" ? reason
                    : "命令 /\(request.commandID) 无法执行：\(reason)。未执行任何副作用。",
                emittedAt: now
            )
            log("Composer 命令 /\(request.commandID) 无生产执行入口，提交时直接拒绝")
            return .reject
        }

        // 2) 调度器 lane：snapshot.taskID 属于 "scheduler-effect:" 命名空间
        //    （SchedulerTaskStore.effectID）。调度 compact 已在任务确认时经
        //    用户批准并绑定 policyRevision，这里只做事实校验后放行；
        //    绝不为其挂载交互裁决（submitScheduledRequest 把非 .execute
        //    一律按 policyUnavailable 处理，挂 pending 等于永久死锁）。
        if snapshot.taskID.hasPrefix("scheduler-effect:") {
            guard request.commandID == "compact" else {
                log("调度命令 /\(request.commandID) 无生产执行器，fail-closed 拒绝")
                return .reject
            }
            return .execute
        }

        // 3) 一次性批准令牌命中：消费令牌并放行规范执行路径。
        if let token = approvalToken,
           token.commandID == request.commandID,
           token.args == request.args,
           token.sessionID == snapshot.sessionID,
           now.timeIntervalSince(token.issuedAt) <= approvalTokenLifetime {
            approvalToken = nil
            // 重放请求携带新 request ID；同命令的未答复裁决即本次批准对象。
            if pendingAdjudication?.commandID == request.commandID {
                pendingAdjudication = nil
            }
            expirationTask?.cancel()
            expirationTask = nil
            lastResolution = Resolution(
                id: request.id,
                commandID: request.commandID,
                sessionID: snapshot.sessionID,
                outcome: .approvedExecuted,
                resolvedAt: now
            )
            projection = AcknowledgedProjection(
                id: request.id,
                commandID: request.commandID,
                text: "命令 /\(request.commandID) 已批准，正通过规范 Composer 路径执行。",
                emittedAt: now
            )
            if request.commandID == "compact" {
                let projectionID = request.id
                let box = CompactionObserverBox()
                box.token = NotificationCenter.default.addObserver(
                    forName: .composerManualCompactionFinished, object: nil, queue: nil
                ) { [weak self, box] note in
                    let outcome = note.userInfo?["message"] as? String
                    MainActor.assumeIsolated {
                        if let token = box.token { NotificationCenter.default.removeObserver(token) }
                        box.token = nil
                        guard let self, let outcome, self.projection?.id == projectionID else { return }
                        self.projection = AcknowledgedProjection(
                            id: projectionID, commandID: "compact",
                            text: "/compact 已完成：\(outcome)", emittedAt: Date())
                    }
                }
            }
            log("Composer 命令 /\(request.commandID) 一次性批准令牌已消费（.execute）")
            return .execute
        }

        // Native submission authorizes only this exact registered request under
        // the current, confirmed L3 bypass. The normal handlers still own effects.
        let hasNativeAuthorization = request.requiresPolicyApproval
            && ChatStore.keyboardComposerCommandRequestID == request.id
            && snapshot.mode == .bypassPermission && snapshot.bypassModeConfirmed
            && facts.autonomyCeiling == .l3 && snapshot.autonomyCeiling == facts.autonomyCeiling

        // 4) Commands with prepared effects share the execution handler with
        // the approval-card path. Only requests awaiting an answer are published.
        if request.requiresPolicyApproval {
            supersedeUnanswered(now: now)
            approvalToken = nil
            if hasNativeAuthorization, request.commandID == "compact" {
                return .execute
            }
            let submitted = PendingAdjudication(
                id: request.id,
                commandID: request.commandID,
                args: request.args,
                sessionID: snapshot.sessionID,
                policySummary: ComposerPolicyPresentation.snapshotSummary(snapshot)
                    + (preparedToolApproval.map { context in
                        let step = context.confirmsSecondStep ? "独立第二次确认" : "首次允许"
                        let target = ContentSecretRedactor.redact(
                            "\(context.target.toolName)：\(context.target.inputSummary)")
                        return "\n原工具审批 · \(step) · \(String(target.prefix(256)))"
                    } ?? ""),
                requestedAt: now,
                expiresAt: now.addingTimeInterval(adjudicationTimeout)
            )
            if request.commandID == "memory.propose", let scope = memoryProposalScopeProvider?() {
                memoryProposalApprovalContext = MemoryProposalApprovalContext(
                    request: request, snapshot: snapshot, facts: facts, scope: scope)
            }
            providerSelectionApprovalContext = preparedProviderSelection
            presentedToolApprovalContext = preparedToolApproval
            workflowApprovalContext = preparedWorkflow
            additionalDirectoryApprovalContext = preparedAdditionalDirectory
            if hasNativeAuthorization, let executed = executePreparedCommand(submitted, now: now) {
                return executed ? .execute : .reject
            }
            pendingAdjudication = submitted
            scheduleExpiration(for: request.id)
            log("Composer 命令 /\(request.commandID) 进入待批准（超时 \(Int(adjudicationTimeout))s 自动拒绝）")
            return .pending
        }

        if Self.desktopCommandIDs.contains(request.commandID), let action = desktopCommandAction {
            do {
                let text = try action(request, snapshot)
                setProjection(id: request.id, commandID: request.commandID, text: text, now: now)
                return .execute
            } catch {
                let reason = (error as? CommandExecutionError)?.errorDescription ?? "桌面命令执行失败，请重试。"
                setProjection(id: request.id, commandID: request.commandID, text: reason, now: now)
                return .reject
            }
        }

        // 5) 展示类命令：ChatStore 规范消费（.execute，不进 transcript、
        //    不进 Provider），本层投影可见结果，绝不静默吞掉。
        let projectionText = request.commandID == "copy"
            ? copyReplyResult(for: request, snapshot: snapshot)
            : displayText(for: request, snapshot: snapshot, now: now)
        projection = AcknowledgedProjection(
            id: request.id,
            commandID: request.commandID,
            text: projectionText,
            emittedAt: now
        )
        log("Composer 展示命令 /\(request.commandID) 已消费并投影结果")
        return .execute
    }

    // MARK: - 用户裁决动作（卡片按钮入口）

    /// 该命令是否有可用的批准执行入口。
    func supportsApproval(commandID: String) -> Bool {
        Self.replayExecutedCommandIDs.contains(commandID)
            || Self.canonicalSettingsCommandIDs.contains(commandID)
            || (commandID == "memory.propose" && submitApprovedMemoryProposal != nil)
            || (commandID == "provider.use" && prepareProviderSelection != nil && applyApprovedProviderSelection != nil)
            || (commandID == "approve" && preparePresentedToolApproval != nil && applyPresentedToolApproval != nil)
            || (commandID == "workflow" && prepareWorkflow != nil && applyApprovedWorkflow != nil)
            || (commandID == "add-dir" && prepareAdditionalDirectory != nil && applyApprovedAdditionalDirectory != nil)
    }

    /// 批准当前待裁决命令。返回 false 表示不可批准（保持待裁决/超时收敛）。
    @discardableResult
    func approveCurrentAdjudication() -> Bool {
        let now = clock()
        guard let pending = pendingAdjudication else { return false }
        guard pending.expiresAt > now else {
            expireCurrentAdjudication()
            return false
        }
        guard supportsApproval(commandID: pending.commandID) else {
            setProjection(
                id: pending.id,
                commandID: pending.commandID,
                text: "命令 /\(pending.commandID) 没有已接线的生产执行入口，不能批准；请拒绝或等待超时自动拒绝。",
                now: now
            )
            return false
        }
        if let executed = executePreparedCommand(pending, now: now) {
            return executed
        }
        if pending.commandID == "compact" {
            guard canReplayIntoComposer?() ?? false else {
                setProjection(
                    id: pending.id,
                    commandID: pending.commandID,
                    text: "输入框当前有未发送内容或附件；清空后可再次批准，避免覆盖草稿。命令仍待批准，超时将自动拒绝。",
                    now: now
                )
                return false
            }
            guard let replay = replaySubmittedCommand else {
                setProjection(
                    id: pending.id,
                    commandID: pending.commandID,
                    text: "Composer 规范重放入口未接线，命令未获批准（fail-closed）。",
                    now: now
                )
                return false
            }
            approvalToken = ApprovalToken(
                commandID: pending.commandID,
                args: pending.args,
                sessionID: pending.sessionID,
                issuedAt: now
            )
            // 同步重放：evaluate 消费令牌后 ChatStore 在 .execute 分支清除
            // pendingComposerCommand 并调用唯一入口 compactContext()。
            replay(Self.canonicalSlashText(commandID: pending.commandID, args: pending.args))
            return true
        }
        // model / settings.*：批准 = 移交 Settings 唯一规范配置入口。
        guard openCanonicalSettings != nil else {
            setProjection(
                id: pending.id,
                commandID: pending.commandID,
                text: "设置中心规范入口未接线，命令 /\(pending.commandID) 未获批准（fail-closed）。",
                now: now
            )
            return false
        }
        approvalToken = nil
        finishAdjudication(pending, outcome: .handedToCanonicalSettings, now: now)
        setProjection(
            id: pending.id,
            commandID: pending.commandID,
            text: "命令 /\(pending.commandID) 已批准；配置变更已移交设置中心（唯一规范入口），不会自动修改任何配置。",
            now: now
        )
        openCanonicalSettings?()
        return true
    }

    /// Runs the same frozen executor and produces the same terminal projection
    /// for native authorization and explicit approval of a pending card.
    private func executePreparedCommand(_ pending: PendingAdjudication, now: Date) -> Bool? {
        if pending.commandID == "approve" {
            guard let context = presentedToolApprovalContext,
                  context.request.id == pending.id, let apply = applyPresentedToolApproval else {
                finishAdjudication(pending, outcome: .rejectedByPolicy("原工具审批目标不可用"), now: now)
                setProjection(id: pending.id, commandID: pending.commandID,
                    text: "工具审批未执行：原目标快照不可用；请重新提交。", now: now)
                return false
            }
            do {
                let result = try apply(context)
                finishAdjudication(pending, outcome: .approvedExecuted, now: now)
                let text: String
                switch result {
                case .awaitingSecondConfirmation:
                    text = "原工具请求已完成首次允许，仍需独立第二次确认；尚未允许工具执行。"
                case .submittedToOriginalGate:
                    text = "裁决已交回原工具审批 Gate；工具执行仍须通过原身份与策略检查。"
                }
                setProjection(id: pending.id, commandID: pending.commandID, text: text, now: now)
                return true
            } catch {
                let reason = (error as? CommandExecutionError)?.errorDescription ?? "原工具审批目标不可用"
                finishAdjudication(pending, outcome: .rejectedByPolicy(reason), now: now)
                setProjection(id: pending.id, commandID: pending.commandID,
                    text: "工具审批未执行：\(reason)。", now: now)
                return false
            }
        }
        if pending.commandID == "add-dir" {
            guard let context = additionalDirectoryApprovalContext,
                  context.request.id == pending.id, let apply = applyApprovedAdditionalDirectory else {
                finishAdjudication(pending, outcome: .rejectedByPolicy("原目录授权快照不可用"), now: now)
                setProjection(id: pending.id, commandID: pending.commandID,
                    text: "目录未添加：原目录授权快照不可用，请重新提交。", now: now)
                return false
            }
            do {
                let receipt = try apply(context)
                guard receipt.requestID == pending.id, receipt.sessionID == pending.sessionID,
                      receipt.path == context.physicalDirectory.path else {
                    throw CommandExecutionError.disabled(commandID: "add-dir", reason: "目录提交回执身份不匹配")
                }
                finishAdjudication(pending, outcome: .approvedExecuted, now: now)
                setProjection(id: pending.id, commandID: pending.commandID,
                    text: "已批准\(context.request.args["scope"] == "project" ? "本项目" : "本会话")目录：\(ContentSecretRedactor.redact(receipt.path))。自下一任务生效。", now: now)
                return true
            } catch {
                let reason = (error as? CommandExecutionError)?.errorDescription ?? "目录身份或当前项目授权已改变"
                finishAdjudication(pending, outcome: .rejectedByPolicy(reason), now: now)
                setProjection(id: pending.id, commandID: pending.commandID,
                    text: "目录未添加：\(reason)。", now: now)
                return false
            }
        }
        if pending.commandID == "provider.use" {
            guard let context = providerSelectionApprovalContext,
                  context.request.id == pending.id, let apply = applyApprovedProviderSelection else {
                finishAdjudication(pending, outcome: .rejectedByPolicy("原提交策略与目标快照不可用"), now: now)
                setProjection(id: pending.id, commandID: pending.commandID,
                    text: "提供商选择未执行：原提交策略与目标快照不可用；请重新提交。", now: now)
                return false
            }
            do {
                let receipt = try apply(context)
                finishAdjudication(pending, outcome: .approvedExecuted, now: now)
                setProjection(id: pending.id, commandID: pending.commandID,
                    text: "当前会话已选择 \(receipt.providerID)/\(receipt.modelID)。未发送模型请求。", now: now)
                return true
            } catch {
                let reason = (error as? CommandExecutionError)?.errorDescription ?? String(describing: error)
                finishAdjudication(pending, outcome: .rejectedByPolicy(reason), now: now)
                setProjection(id: pending.id, commandID: pending.commandID,
                    text: "提供商选择未执行：\(reason)。", now: now)
                return false
            }
        }
        if pending.commandID == "memory.propose" {
            guard let context = memoryProposalApprovalContext,
                  context.request.id == pending.id,
                  let submit = submitApprovedMemoryProposal else {
                finishAdjudication(pending, outcome: .rejectedByPolicy("原提交策略与范围快照不可用"), now: now)
                setProjection(id: pending.id, commandID: pending.commandID,
                    text: "记忆提案未执行：原提交策略与范围快照不可用；请重新提交。", now: now)
                return false
            }
            do {
                let envelope = try submit(context)
                finishAdjudication(pending, outcome: .approvedExecuted, now: now)
                setProjection(id: pending.id, commandID: pending.commandID,
                    text: "记忆提案已提交：\(envelope.proposal.proposalID)。状态为待审提案，尚未批准或写入记忆事实。", now: now)
                return true
            } catch {
                let reason = (error as? CommandExecutionError)?.errorDescription ?? String(describing: error)
                finishAdjudication(pending, outcome: .rejectedByPolicy(reason), now: now)
                setProjection(id: pending.id, commandID: pending.commandID,
                    text: "记忆提案未执行：\(reason)。", now: now)
                return false
            }
        }
        if pending.commandID == "workflow" {
            guard let context = workflowApprovalContext,
                  context.request.id == pending.id,
                  let apply = applyApprovedWorkflow else {
                finishAdjudication(pending, outcome: .rejectedByPolicy("原工作流目标不可用"), now: now)
                setProjection(id: pending.id, commandID: pending.commandID,
                    text: "工作流未启动：原提交与目标快照不可用。", now: now)
                return false
            }
            do {
                try apply(context)
                finishAdjudication(pending, outcome: .approvedExecuted, now: now)
                setProjection(id: pending.id, commandID: pending.commandID,
                    text: "工作流「\(context.template.name)」已提交到当前会话运行器；结果以工作流消息为准。", now: now)
                return true
            } catch {
                let reason = (error as? CommandExecutionError)?.errorDescription ?? "原提交策略或工作流目标不可用"
                finishAdjudication(pending, outcome: .rejectedByPolicy(reason), now: now)
                setProjection(id: pending.id, commandID: pending.commandID,
                    text: "工作流未启动：\(reason)。", now: now)
                return false
            }
        }
        return nil
    }

    /// 拒绝当前待裁决命令。
    func denyCurrentAdjudication() {
        let now = clock()
        guard let pending = pendingAdjudication else { return }
        approvalToken = nil
        finishAdjudication(pending, outcome: .deniedByUser, now: now)
        setProjection(
            id: pending.id,
            commandID: pending.commandID,
            text: "命令 /\(pending.commandID) 已被拒绝，未执行任何副作用。",
            now: now
        )
    }

    /// 超时收敛（测试/手动触发与自动定时器共用同一路径）。
    func expireCurrentAdjudication() {
        let now = clock()
        guard let pending = pendingAdjudication else { return }
        approvalToken = nil
        finishAdjudication(pending, outcome: .expiredUnanswered, now: now)
        setProjection(
            id: pending.id,
            commandID: pending.commandID,
            text: "命令 /\(pending.commandID) 超时未裁决，已按拒绝处理，未执行任何副作用。",
            now: now
        )
        log("Composer 命令 /\(pending.commandID) 超时自动拒绝")
    }

    /// 用户确认已看到结果/回执投影。
    func acknowledgeProjection() {
        guard pendingAdjudication == nil else { return }
        projection = nil
    }

    /// 消费恢复型 `ChatStore.pendingComposerCommand`（含重启后 envelope 恢复，
    /// ChatStore.swift:4631 路径）：恢复出的需要批准的命令必须同样进入可见
    /// 裁决（批准 / 拒绝 / 超时），不得停留在只有菜单装饰态、无人消费的死 pend。
    /// 旧版已持久化、但当前缺执行器的 pending 必须以原 request ID
    /// 收敛并通知 ChatStore 清除；新提交的同类请求不会先写入 pending。
    /// 幂等：同一 request ID 已在看板或终态中时为无操作。
    func adoptRestoredPending(
        _ request: PendingCommandRequest,
        sessionID: String,
        policySummary: String = "恢复自重启前提交的待批准命令（执行前仍需本回合策略核对）"
    ) {
        guard request.requiresPolicyApproval else { return }
        commandRegistryUsed = true
        let now = clock()
        guard pendingAdjudication?.id != request.id,
              lastResolution?.id != request.id else { return }
        supersedeUnanswered(now: now)
        approvalToken = nil
        let restored = PendingAdjudication(
            id: request.id,
            commandID: request.commandID,
            args: request.args,
            sessionID: sessionID,
            policySummary: policySummary,
            requestedAt: now,
            expiresAt: now.addingTimeInterval(adjudicationTimeout)
        )
        if let reason = Self.missingExecutorReason(for: request.commandID) {
            // This request was genuinely durable pending before the executor
            // contract tightened. Emit its exact UUID once so the App root can
            // clear only the matching ChatStore envelope without reapproval.
            finishAdjudication(restored, outcome: .unavailableExecutor(reason), now: now,
                notifyRestoredPending: true)
            setProjection(
                id: request.id,
                commandID: request.commandID,
                text: "命令 /\(request.commandID) 无法执行：\(reason)。原待批准请求已拒绝，未执行任何副作用。",
                now: now
            )
            log("Composer 命令 /\(request.commandID) 恢复自持久化 pending，但无生产执行入口；原请求已拒绝")
            return
        }
        pendingAdjudication = restored
        scheduleExpiration(for: request.id)
        log("Composer 命令 /\(request.commandID) 恢复自持久化 pending，已重新挂载裁决（超时 \(Int(adjudicationTimeout))s 自动拒绝）")
    }

    // MARK: - 内部

    private func finishAdjudication(
        _ pending: PendingAdjudication,
        outcome: TerminalOutcome,
        now: Date,
        notifyRestoredPending: Bool = false
    ) {
        let wasPending = pendingAdjudication?.id == pending.id
        expirationTask?.cancel()
        expirationTask = nil
        pendingAdjudication = nil
        memoryProposalApprovalContext = nil
        providerSelectionApprovalContext = nil
        presentedToolApprovalContext = nil
        workflowApprovalContext = nil
        additionalDirectoryApprovalContext = nil
        let resolution = Resolution(
            id: pending.id,
            commandID: pending.commandID,
            sessionID: pending.sessionID,
            outcome: outcome,
            resolvedAt: now
        )
        lastResolution = resolution
        if wasPending || notifyRestoredPending { onPendingTerminalResolution?(resolution) }
    }

    /// 未答复的旧裁决不得幸存于新命令/策略失效之后：按取代收敛。
    private func supersedeUnanswered(now: Date) {
        guard let stale = pendingAdjudication else { return }
        finishAdjudication(stale, outcome: .supersededByNewCommand, now: now)
    }

    private func setProjection(id: UUID, commandID: String, text: String, now: Date) {
        projection = AcknowledgedProjection(id: id, commandID: commandID, text: text, emittedAt: now)
    }

    private func copyReplyResult(for request: PendingCommandRequest, snapshot: ComposerSubmissionSnapshot) -> String {
        guard let n = Int(request.args["n"] ?? "1"), n > 0 else {
            return "请输入 /copy N，N 必须是正整数。"
        }
        return copyReply?(n, snapshot) ?? "复制入口未接线，未更改剪贴板。"
    }

    private func displayText(
        for request: PendingCommandRequest,
        snapshot: ComposerSubmissionSnapshot,
        now: Date
    ) -> String {
        switch request.commandID {
        case "help":
            let registry = commandRegistry
            let requestedID = request.args["command_id"]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !requestedID.isEmpty {
                guard let command = registry.command(id: requestedID),
                      CommandRegistry.composerCommandIDs.contains(command.id),
                      let metadata = CommandRegistry.composerMetadata(for: command.id)
                else {
                    return "未知 Composer 命令：\(requestedID)。输入 /help 查看当前注册表。"
                }
                var lines = [
                    "/\(command.id) · \(command.title) / \(metadata.enTitle)",
                    "\(metadata.zhSummary) / \(metadata.enSummary)",
                    "参数：\(metadata.parameterSummary)",
                    "风险：\(metadata.risk.displayLabel)",
                ]
                if metadata.requiresPolicyApproval {
                    lines.append("执行前需本回合策略与用户批准；查看帮助不执行命令。")
                }
                if let reason = currentBlockerReason(for: command) {
                    lines.append("当前阻断：\(reason)")
                }
                return lines.joined(separator: "\n")
            }
            let vocabulary = registry.allCommands()
                .filter { CommandRegistry.composerCommandIDs.contains($0.id) }
                .map(commandListRow)
                .joined(separator: "\n")
            return "Composer 命令一览（斜杠输入，需批准的命令会显示裁决卡）：\n\(vocabulary)"
        case "commands":
            let registered = commandRegistry.allCommands()
                .filter { CommandRegistry.composerCommandIDs.contains($0.id) }
            let requestedCategory = request.args["category"]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let category = CommandCategory.allCases.first {
                $0.rawValue.caseInsensitiveCompare(requestedCategory) == .orderedSame
                    || $0.displayName == requestedCategory
            }
            if !requestedCategory.isEmpty && category == nil {
                let registeredCategories = Set(registered.map { $0.category.rawValue })
                let choices = CommandCategory.allCases
                    .filter { registeredCategories.contains($0.rawValue) }
                    .map { "\($0.rawValue)（\($0.displayName)）" }
                    .joined(separator: "、")
                return "未知命令分类：\(requestedCategory)。可用分类：\(choices)。"
            }
            let displayed = category.map { selected in
                registered.filter { $0.category.rawValue == selected.rawValue }
            } ?? registered
            guard !displayed.isEmpty else {
                return "当前注册表在该分类下没有可列出的 Composer 命令。"
            }
            let rows = displayed.map(commandListRow).joined(separator: "\n")
            let heading = category.map { "\($0.displayName)命令" } ?? "Composer 命令"
            return "\(heading)（\(displayed.count) 条，来自当前注册表）：\n\(rows)"
        case "status":
            let runtime = statusProjection?(snapshot) ?? ""
            let base = ComposerPolicyPresentation.snapshotSummary(snapshot)
            return runtime.isEmpty ? base : "\(base)\n\(runtime)"
        case "tasks":
            return tasksProjection?() ?? "调度任务状态源未接线；本命令未执行任何副作用。"
        case "boundary":
            let value = boundaryProjection?(snapshot)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty
                ? "当前安全边界事实未知；本命令未执行任何副作用。"
                : value
        case "provider":
            let value = providerProjection?(snapshot)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty
                ? "当前 Provider/Model 已应用事实未知；本命令未执行任何副作用。"
                : value
        default:
            // 未来注册表新增的非批准命令：仍然可见地消费，不静默吞掉。
            return "命令 /\(request.commandID) 已被 Composer 策略层消费；尚无专属结果视图，未执行任何副作用。"
        }
    }

    private func commandListRow(_ command: CommandDefinition) -> String {
        let title = "/\(command.id) · \(command.title)"
        guard let reason = currentBlockerReason(for: command) else { return title }
        return "\(title) · 当前阻断：\(reason)"
    }

    private func currentBlockerReason(for command: CommandDefinition) -> String? {
        if case .disabled(let reason) = command.currentAvailability {
            let value = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? "命令已禁用，原因未记录" : value
        }
        if let reason = Self.missingExecutorReason(for: command.id) { return reason }
        let value = commandAvailabilityReason?(command.id)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private func scheduleExpiration(for requestID: UUID) {
        expirationTask?.cancel()
        guard adjudicationTimeout.isFinite, adjudicationTimeout > 0 else {
            expireCurrentAdjudication()
            return
        }
        let nanoseconds = UInt64(adjudicationTimeout * 1_000_000_000)
        expirationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            guard self.pendingAdjudication?.id == requestID else { return }
            self.expireCurrentAdjudication()
        }
    }

    /// 重放文本重建：canonical slash 词法（`/id key=value ...`），
    /// 与 CommandParser 的内联 k=v 提取往返一致，保证重路由解析出同一请求形状。
    static func canonicalSlashText(commandID: String, args: [String: String]) -> String {
        if ["compact", "rename", "plan"].contains(commandID) {
            let key = commandID == "compact" ? "hint" : (commandID == "rename" ? "title" : "description")
            return "/" + commandID + (args[key].map { " " + $0 } ?? "")
        }
        let suffix = args.keys.sorted().compactMap { key in
            args[key].map { value in " \(key)=\(value)" }
        }.joined()
        return "/\(commandID)\(suffix)"
    }

    private func log(_ message: String) {
        eventLogger?(message)
    }
}

// MARK: - 裁决 / 回执卡（SwiftUI）

/// Composer 命令裁决卡：待批准命令 + 结果/回执投影。
/// 样式沿用 ApprovalPromptCenter 的既有 A7-A 融合表面（同层级标题、
/// caption 次级文本、等宽命令 ID），不引入任何新的字体/主题 token。
struct ComposerCommandAdjudicationCard: View {
    let chat: ChatStore
    @Bindable var center: ComposerCommandAdjudicationCenter
    @Environment(\.themeTokens) private var theme

    private var activeAdjudication: ComposerCommandAdjudicationCenter.PendingAdjudication? {
        guard let pending = center.pendingAdjudication,
              pending.sessionID == chat.activeSessionID?.uuidString else { return nil }
        return pending
    }

    private var receipt: ComposerCommandReceipt? {
        chat.lastComposerCommandReceipt
    }

    @ViewBuilder
    private var adjudicationSection: some View {
        if let pending = activeAdjudication {
            HStack(spacing: 8) {
                MinisIconView(.warning, size: 20, accessibilityLabel: "Composer 命令待批准")
                    .foregroundPalette(theme?.statusWarning ?? .orange)
                Text("Composer 命令待批准")
                    .font(.headline)
                Spacer()
                Text("/\(pending.commandID)")
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary))
            }

            if !pending.args.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("参数")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(pending.args.keys.sorted()
                        .map { "\($0)=\(pending.args[$0] ?? "")" }
                        .joined(separator: "  "))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("本回合策略")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(pending.policySummary)
                    .font(.callout)
                    .accessibilityLabel("本回合策略：\(pending.policySummary)")
            }

            Text("超时未裁决将自动拒绝（按 \(pending.expiresAt, format: .dateTime.hour().minute().second())）")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("拒绝") {
                    center.denyCurrentAdjudication()
                }
                .keyboardShortcut(.cancelAction)
                .escapeShortcut(denyPending: center.escapeDenialAction(
                    requestID: pending.id, sessionID: pending.sessionID, chat: chat
                ))
                .accessibilityLabel("拒绝命令")
                .accessibilityIdentifier("composer-command.deny")

                Button("批准") {
                    center.approveCurrentAdjudication()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(theme?.statusWarning ?? .orange)
                .disabled(!center.supportsApproval(commandID: pending.commandID))
                .help(center.supportsApproval(commandID: pending.commandID)
                     ? "批准后经既有确认/规范路径执行"
                     : "该命令没有已接线的生产执行入口，只能拒绝或等待超时")
                .accessibilityLabel("批准命令")
                .accessibilityIdentifier("composer-command.approve")
            }
        }
    }

    @ViewBuilder
    private var projectionSection: some View {
        if activeAdjudication == nil, let projection = center.projection {
            VStack(alignment: .leading, spacing: 6) {
                Text("命令结果")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(projection.text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack {
                    Spacer()
                    Button("知道了") {
                        center.acknowledgeProjection()
                    }
                    .accessibilityIdentifier("composer-command.acknowledge")
                }
            }
        }
    }

    var body: some View {
        if activeAdjudication != nil || center.projection != nil {
            VStack(alignment: .leading, spacing: 16) {
                adjudicationSection
                projectionSection
                if let receipt, activeAdjudication != nil {
                    // 审计回执行：ChatStore 持久化的最近一次命令处置。
                    Text("回执：/\(receipt.commandID) → \(receipt.disposition.rawValue) · \(receipt.turnID) 号回合")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("composer-command.receipt")
                }
            }
            .padding(20)
            .frame(width: 460)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.background)
                    .shadow(radius: 8)
            )
            .transition(.opacity)
        }
    }
}
