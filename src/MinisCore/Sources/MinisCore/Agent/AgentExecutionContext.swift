import Foundation

/// Immutable child-runtime facts captured at the dispatch boundary.
///
/// A child loop must consume this value rather than re-reading mutable parent
/// state.  The optional identity is retained so legacy callers can construct
/// a field-only snapshot, but secure production consumers require the snapshot
/// to match the concrete `AgentChildBoundary` before provider work begins.
public struct AgentChildRuntimeSnapshot: Sendable, Equatable, Codable {
    public let capabilitySnapshot: Set<ProviderCapability>
    public let scopeID: String
    public let cancelGeneration: Int
    public let generationID: String
    public let identity: ChildRuntimeIdentity?

    public init(
        capabilitySnapshot: Set<ProviderCapability>,
        scopeID: String,
        cancelGeneration: Int,
        generationID: String,
        identity: ChildRuntimeIdentity? = nil
    ) {
        self.capabilitySnapshot = capabilitySnapshot
        self.scopeID = scopeID
        self.cancelGeneration = cancelGeneration
        self.generationID = generationID
        self.identity = identity
    }

    public init(identity: ChildRuntimeIdentity) {
        self.init(
            capabilitySnapshot: identity.grantedCapabilities,
            scopeID: identity.scopeID,
            cancelGeneration: identity.cancelGeneration,
            generationID: identity.generationID ?? "",
            identity: identity
        )
    }

    /// Aliases keep the snapshot vocabulary explicit at call sites while
    /// preserving one canonical stored capability set.
    public var grantedCapabilities: Set<ProviderCapability> { capabilitySnapshot }
    public var isValid: Bool {
        guard !scopeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !generationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              cancelGeneration > 0 else {
            return false
        }
        guard let identity else { return true }
        return identity.isValid
            && identity.grantedCapabilities == capabilitySnapshot
            && identity.scopeID == scopeID
            && identity.cancelGeneration == cancelGeneration
            && identity.generationID == generationID
    }

    /// Match the immutable dispatch facts against the boundary that will own
    /// the child loop. Any mismatch is a generation/scope/capability fence.
    public func matches(_ boundary: AgentChildBoundary) -> Bool {
        guard isValid,
              boundary.identity.grantedCapabilities == capabilitySnapshot,
              boundary.identity.scopeID == scopeID,
              boundary.identity.cancelGeneration == cancelGeneration,
              boundary.identity.generationID == generationID else {
            return false
        }
        guard let identity else { return true }
        return identity == boundary.identity
    }
}

/// Descriptive aliases for consumers that use the capability-oriented name.
public typealias ChildRuntimeCapabilitySnapshot = AgentChildRuntimeSnapshot
public typealias AgentChildExecutionSnapshot = AgentChildRuntimeSnapshot

/// The already-admitted parent, child boundary and durable transcript locator
/// carried by one production child loop. This is not a new capability grant.
public struct AgentChildToolRuntimeBinding: Sendable {
    public let parent: ParentRuntimeIdentity
    public let boundary: AgentChildBoundary
    public let locator: ChildTranscriptLocator

    public init(parent: ParentRuntimeIdentity, boundary: AgentChildBoundary,
                locator: ChildTranscriptLocator) {
        self.parent = parent
        self.boundary = boundary
        self.locator = locator
    }

    /// Reuse the concrete boundary and canonical current-attempt backlinks.
    /// The enclosing executor still owns policy, roots and project grants.
    public func verifiedParentSessionID(
        for tool: String, context: AgentExecutionContextSnapshot
    ) async -> String? {
        let child = boundary.identity
        guard parent.isValid, child.isValid,
              (try? child.requireVerifiedGeneration()) != nil,
              context.childRuntimeSnapshot?.matches(boundary) == true,
              let parentHandle = boundary.parentTurnHandle,
              parentHandle.turnID == child.cancelGeneration,
              parent.turnID == "turn-handle:\(parentHandle.turnID)",
              parent.sessionID == child.parentSessionID,
              parent.conversationID == child.parentConversationID,
              parent.taskID == child.parentTaskID,
              let childController = boundary.childTurnController,
              let runtimeController = context.turnController,
              childController === runtimeController,
              context.currentConversationID == child.childSessionID,
              context.parentBinding == child.providerSnapshot,
              context.toolExecutionFactLedger?.hasDurableAuthority == true,
              boundary.allowsTool(tool),
              locator.childSessionID == child.childSessionID,
              locator.parentSessionID == parent.sessionID,
              locator.taskID == child.childTaskID,
              // Retry retains the original Task Center row while the new
              // child executes under a distinct, real Composer parent turn.
              // The durable per-run binding must prove both identities.
              (locator.parentID == parent.taskID && locator.runtimeParentID == nil
                  || context.taskStore?.retryRunRuntimeBinding(runID: locator.runID)
                    .map { $0.originalParentID == locator.parentID
                        && locator.runtimeParentID == parent.taskID
                        && $0.parent == parent && $0.child == child } == true),
              // Execution ID and cancellation generation ID are distinct.
              // Re-derive through the existing identity producer, preserving
              // every frozen capability source and comparing the whole value.
              let canonicalChild = try? ChildRuntimeIdentity.derive(parent: parent,
                  childSessionID: locator.childSessionID, childTaskID: locator.taskID,
                  scopeID: child.scopeID,
                  requestedCapabilities: child.capabilityIntersection.requestedCapabilities,
                  parentCapabilities: child.capabilityIntersection.parentCapabilities,
                  policyCapabilities: child.capabilityIntersection.policyCapabilities,
                  providerSnapshot: child.providerSnapshot, memoryScopeID: child.memoryScopeID,
                  workingDirectory: child.workingDirectory, cancelGeneration: parentHandle.turnID,
                  evidenceRoot: child.evidenceRoot, parentTurnHandle: parentHandle,
                  childExecutionID: locator.childExecutionID,
                  catalogCapabilities: child.capabilityIntersection.catalogCapabilities,
                  requestsOrchestration: child.capabilityIntersection.requestsOrchestration),
              child.matchesCanonicalExecution(canonicalChild),
              let store = context.taskStore,
              let task = store.taskSnapshot(runID: locator.runID),
              // A new boundary is consumed only when it matches the task
              // store's enqueue-verified parent/Goal facts. Old records have
              // no root authority and keep their original exact comparison.
              ((store.retryRunRuntimeBinding(runID: locator.runID)?.child
                ?? task.childRuntimeIdentity).map {
                  $0 == child && child.rootParentIdentity == parent
              } ?? (canonicalChild == child)),
              (store.retryRunRuntimeBinding(runID: locator.runID) != nil
                  || (task.providerID == child.providerSnapshot.providerID
                      && task.modelID == child.providerSnapshot.modelID
                      && task.configurationFingerprint
                          == child.providerSnapshot.configurationFingerprint)),
              store.childTranscriptLocator(taskID: locator.taskID, parentID: locator.parentID,
                  runID: locator.runID, attemptID: locator.attemptID,
                  childExecutionID: locator.childExecutionID,
                  parentContextSnapshotID: locator.parentContextSnapshotID) == locator,
              let control = store.controlSnapshot(taskID: locator.taskID, parentID: locator.parentID),
              control.runID == locator.runID, control.state == .active,
              (try? store.withWritableChildTranscript(locator) { true }) == true,
              await parentHandle.isActive(), !(await parentHandle.isCancelled()),
              (try? await boundary.check()) != nil else { return nil }
        return parent.sessionID
    }
}

/// Read-only native grant provenance for generated file presentation.
public struct TaskFileArtifactProjectGrant: Sendable, Equatable {
    public let projectID: String
    public let workingDirectory: String
}

/// Runtime values inherited by an opt-in orchestration tool invocation.
///
/// The context is task-local so concurrent top-level turns never share a provider,
/// cancellation controller, conversation identity, or budget accidentally.
/// 主对话回合的截止时钟：每轮拿到模型回复后由 AgentLoop 续期一次，
/// 审批绑定有效期与审批层的超时信号按“这一轮的工具阶段”计时，不再从回合开头算起。
/// 以前固定为“回合开始 + 单次请求上限（15 分钟）”，长任务跑满 15 分钟后每个工具一启动就被判超时、
/// 需要审批的动作也随之过期（用户 11/21 会话 BE8372C4）。
public final class TurnDeadlineClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date?
    public init(_ initial: Date?) { value = initial }
    public var current: Date? { lock.withLock { value } }
    public func renew(_ deadline: Date?) { lock.withLock { value = deadline } }
    /// 剩余不到半个时间窗才续到完整时间窗。审批绑定的身份指纹含有效期，频繁续期会让同一调用在相邻
    /// 两轮得到不同指纹、绕开“同一审批只出一张回执”的防重放；只在快到期时续，正常节奏下指纹不变。
    public func renewIfHalfSpent(window: TimeInterval, now: Date = Date()) {
        lock.withLock {
            guard let current = value, current.timeIntervalSince(now) < window / 2 else { return }
            value = now.addingTimeInterval(window)
        }
    }
}

public struct AgentExecutionContextSnapshot: @unchecked Sendable {
    public let provider: any LLMProvider
    public let approvalGate: ApprovalGate?
    public let turnController: TurnController?
    public let currentConversationID: String?
    public let makeChildBudget: (@Sendable () -> BudgetTracker?)?
    private let fixedDeadline: Date?
    /// 有续期时钟时取时钟的当前值，否则是构造时给定的固定截止。
    public let deadlineClock: TurnDeadlineClock?
    public var deadline: Date? { deadlineClock?.current ?? fixedDeadline }
    public let taskStore: AgentTaskStore?
    /// The active loop's existing durable authority; child loops never create a second writer.
    public let toolExecutionFactLedger: ToolExecutionFactLedger?
    public let parentBinding: ParentContextSnapshotV1?
    /// The exact Core-created handle for this active parent turn.
    public let parentTurnHandle: TurnController.TurnHandle?
    /// Complete parent identity derived by Core from `parentTurnHandle` and the
    /// composition-root seed. It is nil when no seed was supplied.
    public let parentRuntimeIdentity: ParentRuntimeIdentity?
    /// Immutable child capability/scope/cancellation facts, when this context
    /// is being used to construct a child loop.
    public let childRuntimeSnapshot: AgentChildRuntimeSnapshot?
    public let childToolRuntimeBinding: AgentChildToolRuntimeBinding?
    /// Native grant provenance only; child identity remains in the existing binding.
    public let taskArtifactProject: TaskFileArtifactProjectGrant?
    public let composerSnapshot: ComposerSubmissionSnapshot?
    public let composerPolicyFacts: ComposerPolicyFactSource?
    /// The real outer Composer for this frozen turn. A nested command must
    /// mint its own durable receipt through this existing authority; the raw
    /// Builtin/Recording chain is deliberately not substituted here.
    public let nestedShellExecutor: (any NestedShellToolExecutor)?
    public let offeredToolNames: Set<String>?
    public let childMutationsEnabled: Bool
    public let trustedProjectInstructions: TrustedProjectInstructionSnapshot?
    public let parentAuthorityCheck: (@Sendable () async -> Bool)?
    /// The composition root's exact execution identity for this parent turn,
    /// when it supplied one. O-04 uses it only as a lookup key for a retained
    /// background owner; it is not a capability.
    public let executionIdentity: AgentExecutionIdentity?

    public init(
        provider: any LLMProvider,
        approvalGate: ApprovalGate?,
        turnController: TurnController?,
        currentConversationID: String?,
        makeChildBudget: (@Sendable () -> BudgetTracker?)?,
        deadline: Date?,
        taskStore: AgentTaskStore? = nil,
        toolExecutionFactLedger: ToolExecutionFactLedger? = nil,
        parentBinding: ParentContextSnapshotV1? = nil,
        parentTurnHandle: TurnController.TurnHandle? = nil,
        parentRuntimeIdentity: ParentRuntimeIdentity? = nil,
        childRuntimeSnapshot: AgentChildRuntimeSnapshot? = nil,
        childToolRuntimeBinding: AgentChildToolRuntimeBinding? = nil,
        taskArtifactProject: TaskFileArtifactProjectGrant? = nil,
        composerSnapshot: ComposerSubmissionSnapshot? = nil,
        composerPolicyFacts: ComposerPolicyFactSource? = nil,
        nestedShellExecutor: (any NestedShellToolExecutor)? = nil,
        offeredToolNames: Set<String>? = nil,
        childMutationsEnabled: Bool = true,
        trustedProjectInstructions: TrustedProjectInstructionSnapshot? = TrustedProjectInstructionContext.current,
        parentAuthorityCheck: (@Sendable () async -> Bool)? = nil,
        executionIdentity: AgentExecutionIdentity? = nil,
        deadlineClock: TurnDeadlineClock? = nil
    ) {
        self.provider = provider
        self.approvalGate = approvalGate
        self.turnController = turnController
        self.currentConversationID = currentConversationID
        self.makeChildBudget = makeChildBudget
        self.fixedDeadline = deadline
        self.deadlineClock = deadlineClock
        self.taskStore = taskStore
        self.toolExecutionFactLedger = toolExecutionFactLedger
        self.parentBinding = parentBinding
        self.parentTurnHandle = parentTurnHandle
        self.parentRuntimeIdentity = parentRuntimeIdentity
        self.childRuntimeSnapshot = childRuntimeSnapshot
        self.childToolRuntimeBinding = childToolRuntimeBinding
        self.taskArtifactProject = taskArtifactProject
        self.composerSnapshot = composerSnapshot
        self.composerPolicyFacts = composerPolicyFacts
        self.nestedShellExecutor = nestedShellExecutor
        self.offeredToolNames = offeredToolNames
        self.childMutationsEnabled = childMutationsEnabled
        self.trustedProjectInstructions = trustedProjectInstructions
        self.parentAuthorityCheck = parentAuthorityCheck
        self.executionIdentity = executionIdentity
    }

    /// True only when the exact handle and the complete identity are present
    /// and the identity's turn field was derived from that handle.
    public var hasVerifiedParentRuntime: Bool {
        guard let parentTurnHandle, let parentRuntimeIdentity else { return false }
        return parentRuntimeIdentity.isValid
            && parentRuntimeIdentity.turnID == "turn-handle:\(parentTurnHandle.turnID)"
    }

    /// A child context is verified only when its immutable cancellation
    /// generation is tied to the exact Core-created parent turn handle.
    public var hasVerifiedChildRuntime: Bool {
        guard let childRuntimeSnapshot,
              let parentTurnHandle,
              childRuntimeSnapshot.isValid else {
            return false
        }
        return childRuntimeSnapshot.cancelGeneration == parentTurnHandle.turnID
    }
}

public enum AgentExecutionContext {
    @TaskLocal public static var current: AgentExecutionContextSnapshot?
}

/// A small reference used only to close the production composition cycle safely:
/// orchestration is created before the policy/recording wrappers, while child tool
/// execution is bound after those wrappers exist.
public final class ToolExecutorReference: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: any ToolExecutor

    /// Each dispatch retains one Sendable executor snapshot. The lock only
    /// protects publication of the reference; no executor work runs under it.
    public var value: any ToolExecutor {
        get { lock.withLock { storedValue } }
        set {
            let previous = lock.withLock {
                let previous = storedValue
                storedValue = newValue
                return previous
            }
            // Release a replaced executor after unlocking, too: its teardown
            // may call back into the composition that owns this reference.
            withExtendedLifetime(previous) {}
        }
    }

    public init(_ value: any ToolExecutor) {
        storedValue = value
    }
}

/// Already-intersected child workspace, consumed by the existing Builtin owner.
/// This task-local narrows a dispatch; it is not a new authorization grant.
struct ChildToolWorkspaceScope: Sendable {
    /// Only the trusted top-level capture distinguishes a global parent's
    /// admitted file roots from child/project scopes. Unknown producers stay
    /// restricted; this classification grants no file or shell authority.
    enum BackgroundOrigin: Equatable, Sendable {
        case restricted
        case globalParent
    }

    @TaskLocal static var current: ChildToolWorkspaceScope?
    let readRoots: [String]
    let writeRoots: [String]
    let workingDirectory: String
    let deniedRoots: [String]
    let parentAuthorityCheck: (@Sendable () async -> Bool)?
    /// 用户 2026-10-22 决定：父会话是已确认的绕过、且「子任务写入」开关
    /// （`childMutationsEnabled`）打开时由编排器置 true，表示子任务的文件读写删跟随父会话，
    /// 不再受本 scope 的读写根/父目录限制。默认 false = 行为不变。
    /// 这个字段本身不授权任何东西：消费处还要求当前处于由已确认绕过快照打开的
    /// `BypassOpenScope`（只有 `ComposerPolicyEnforcedToolExecutor` 能打开），两者缺一不可。
    var filesOpen: Bool = false
    /// Nil is legacy/unknown provenance: all deniedRoots remain hard denies.
    var explicitDeniedRoots: [String]? = nil
    var backgroundOrigin: BackgroundOrigin = .restricted
}

/// Exact physical-file lease held by the outer recording executor. The builtin
/// owner may reuse this lease only for the same key; all other paths still
/// acquire their own shared serialiser lease. This is synchronization, never
/// authorization, and is not a directory or workspace mutex.
public final class ToolFileMutationLease: @unchecked Sendable {
    @TaskLocal public static var current: ToolFileMutationLease?
    public let key: String
    public let token: UUID
    private let lock = NSLock()
    private var storedReceipt: ToolExecutionReceipt?
    private let presentationKey: ToolExecutionCompositeKey?
    private let presentationIdentity: AgentExecutionIdentity?
    private let presentationToolName: String?
    private var attached: Bool
    private var authorizationBorrowed = false
    private var recordingBorrowed = false
    private var builtinBorrowed = false
    private var builtinInFlight = false
    private var builtinExitWaiters: [CheckedContinuation<Void, Never>] = []
    private var active = true

    public var receipt: ToolExecutionReceipt? {
        lock.lock(); defer { lock.unlock() }
        return storedReceipt
    }

    public init(key: String, token: UUID, receipt: ToolExecutionReceipt) {
        self.key = key; self.token = token; self.storedReceipt = receipt
        self.presentationKey = nil; self.presentationIdentity = nil; self.presentationToolName = nil
        self.attached = true
    }

    public init(key: String, token: UUID, approvalContext: ApprovalPresentationContext) {
        self.key = key; self.token = token; self.storedReceipt = nil
        self.presentationKey = approvalContext.compositeKey
        self.presentationIdentity = approvalContext.executionIdentity
        self.presentationToolName = approvalContext.toolName
        self.attached = false
    }

    init(key: String, token: UUID) {
        self.key = key; self.token = token; self.storedReceipt = nil
        self.presentationKey = nil; self.presentationIdentity = nil; self.presentationToolName = nil
        self.attached = false
    }

    private func matchesCallLocked(_ receipt: ToolExecutionReceipt) -> Bool {
        if let storedReceipt { return storedReceipt == receipt }
        return presentationKey != nil && receipt.compositeKey == presentationKey
            && receipt.executionIdentity == presentationIdentity && receipt.toolName == presentationToolName
    }

    public func matchesCall(_ receipt: ToolExecutionReceipt) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return active && matchesCallLocked(receipt)
    }

    /// Read-only resource identity check for pre-Gate checkpoint preparation.
    /// It is never a permission decision or a fabricated execution receipt.
    public func matchesApprovalContext(_ context: ApprovalPresentationContext) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard active else { return false }
        if let presentationKey {
            return presentationKey == context.compositeKey
                && presentationIdentity == context.executionIdentity
                && presentationToolName == context.toolName
        }
        guard let storedReceipt else { return false }
        return storedReceipt.compositeKey == context.compositeKey
            && storedReceipt.executionIdentity == context.executionIdentity
            && storedReceipt.toolName == context.toolName
    }

    public func hasSameCallKey(_ receipt: ToolExecutionReceipt) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let key = storedReceipt?.compositeKey ?? presentationKey { return key == receipt.compositeKey }
        // Legacy negative/error contexts may carry no composite key. Treat
        // a receipt-ID swap for the same existing call fields as a conflict,
        // never as a reason to re-enter our own physical lock.
        guard let storedReceipt, storedReceipt.compositeKey == nil, receipt.compositeKey == nil else { return false }
        return storedReceipt.toolCallID == receipt.toolCallID
            && storedReceipt.attemptID == receipt.attemptID
            && storedReceipt.attemptNumber == receipt.attemptNumber
            && storedReceipt.executionIdentity == receipt.executionIdentity
    }

    private func attachLocked(_ receipt: ToolExecutionReceipt) -> Bool {
        guard active, !attached, storedReceipt == nil, matchesCallLocked(receipt) else { return false }
        storedReceipt = receipt
        attached = true
        return true
    }

    /// Binding an already minted receipt does not mint or consume permission.
    public func attachReceipt(_ receipt: ToolExecutionReceipt) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return attachLocked(receipt)
    }

    public func claimAuthorizationUse(key: String, receipt: ToolExecutionReceipt) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard active, !authorizationBorrowed, self.key == key, matchesCallLocked(receipt) else { return false }
        if !attached, !attachLocked(receipt) { return false }
        authorizationBorrowed = true
        return true
    }

    public func claimRecordingUse(key: String, receipt: ToolExecutionReceipt) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard active, !recordingBorrowed, self.key == key, matchesCallLocked(receipt) else { return false }
        if !attached, !attachLocked(receipt) { return false }
        recordingBorrowed = true
        return true
    }

    public func claimBuiltinUse(key: String, receipt: ToolExecutionReceipt?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard active, !builtinBorrowed, self.key == key, attached,
              let receipt, storedReceipt == receipt else { return false }
        builtinBorrowed = true
        builtinInFlight = true
        return true
    }

    public func finishBuiltinUse() {
        lock.lock()
        guard builtinInFlight else { lock.unlock(); return }
        builtinInFlight = false
        let waiters = builtinExitWaiters
        builtinExitWaiters.removeAll()
        lock.unlock()
        for waiter in waiters { waiter.resume() }
    }

    public func waitForBuiltinExit() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if builtinInFlight {
                builtinExitWaiters.append(continuation)
                lock.unlock()
            } else {
                lock.unlock()
                continuation.resume()
            }
        }
    }

    public func invalidate() {
        lock.lock(); defer { lock.unlock() }
        active = false
    }
}

/// Descriptive ownership frozen by the admitted child loop. It conveys no
/// authority: checkpoint/ledger callers still verify session, roots and receipts.
struct ChildFileChangeOwnership: Sendable {
    @TaskLocal static var current: ChildFileChangeOwnership?
    let childTaskID: String
    let childSessionID: String
    let parentSessionID: String

    static func taskID(sessionID: String, parentSessionID: String? = nil) -> String? {
        guard let owner = current, owner.childSessionID == sessionID,
              !owner.childTaskID.isEmpty,
              parentSessionID == nil || parentSessionID == owner.parentSessionID else { return nil }
        return owner.childTaskID
    }
}

/// Private output-log location captured by the App's real session owner.
/// This carries no filesystem permission for model tools.
public struct ToolOutputArtifactSessionScope: Sendable {
    @TaskLocal public static var current: ToolOutputArtifactSessionScope?
    public let sessionStorageRoot: URL
    public let sessionID: UUID
    public init(sessionStorageRoot: URL, sessionID: UUID) {
        self.sessionStorageRoot = sessionStorageRoot
        self.sessionID = sessionID
    }
}

/// Trusted production read-only Git preview bound to the same builtin owner.
/// The callback returns display text only; it never edits approval input.
public enum GitWriteApprovalSummaryContext {
    public typealias Provider = @Sendable (ComposerToolInput, TerminalPolicySnapshot) async throws -> String?
    @TaskLocal public static var current: Provider?
}

/// Read-only resolver captured from the exact production builtin owner. Missing
/// provenance does not waive a root. No model input can install this resolver.
public enum OwnedOutputArtifactReadContext {
    public typealias Resolver = @Sendable (String) throws -> URL?
    @TaskLocal public static var current: Resolver?
    public static func resolve(path: String) throws -> URL? {
        guard let resolver = current else { return nil }
        return try resolver(path)
    }
}
