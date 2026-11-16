import Foundation

/// The immutable identity shared by the agent execution context and every
/// production context manifest it produces or consumes.
///
/// Scope components are deliberately kept as caller-owned opaque IDs.  The
/// binding is valid only when all components are present and the canonical
/// representation is unchanged; a partial or drifted scope must therefore
/// fail closed at the production seam.
public struct AgentExecutionScopeIdentity: Hashable, Sendable, Equatable, Codable {
    public let sessionID: String
    public let workspaceID: String
    public let memoryScopeID: String
    public let skillsScopeID: String
    public let permissionsScopeID: String
    public let taskID: String
    public let budgetScopeID: String

    public init(
        sessionID: String,
        workspaceID: String,
        memoryScopeID: String,
        skillsScopeID: String,
        permissionsScopeID: String,
        taskID: String,
        budgetScopeID: String
    ) {
        self.sessionID = sessionID
        self.workspaceID = workspaceID
        self.memoryScopeID = memoryScopeID
        self.skillsScopeID = skillsScopeID
        self.permissionsScopeID = permissionsScopeID
        self.taskID = taskID
        self.budgetScopeID = budgetScopeID
    }

    /// Stable, non-secret projection used to compare a context with its
    /// manifest consumer. It is intentionally not a process-random hash.
    public var canonicalRepresentation: String {
        [
            sessionID,
            workspaceID,
            memoryScopeID,
            skillsScopeID,
            permissionsScopeID,
            taskID,
            budgetScopeID,
        ].map(Self.escape).joined(separator: "|")
    }

    public var fingerprint: String {
        "scope:" + canonicalRepresentation
    }

    public var isValid: Bool {
        [
            sessionID,
            workspaceID,
            memoryScopeID,
            skillsScopeID,
            permissionsScopeID,
            taskID,
            budgetScopeID,
        ].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public func matches(_ other: AgentExecutionScopeIdentity) -> Bool {
        isValid && other.isValid && self == other
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
    }
}

/// Compatibility aliases keep the scope vocabulary discoverable at both the
/// agent and generic execution layers while retaining one canonical type.
public typealias ExecutionScopeIdentity = AgentExecutionScopeIdentity
public typealias AgentScopeIdentity = AgentExecutionScopeIdentity

public enum AgentContextScopeError: Error, Equatable, Sendable {
    case missingScopeIdentity
    case invalidScopeIdentity
    case scopeDrift
}

public extension AgentExecutionScopeIdentity {
    static func require(_ identity: AgentExecutionScopeIdentity?) throws -> AgentExecutionScopeIdentity {
        guard let identity else { throw AgentContextScopeError.missingScopeIdentity }
        guard identity.isValid else { throw AgentContextScopeError.invalidScopeIdentity }
        return identity
    }
}

public extension ChildRuntimeIdentity {
    /// Verified runtime identities are the only identities accepted by the
    /// child receipt lane.
    var isValid: Bool {
        let fields = [
            parentSessionID, parentConversationID, parentTurnID, parentTaskID,
            childSessionID, childTaskID, scopeID, memoryScopeID,
            workingDirectory, evidenceRoot,
        ]
        return fields.allSatisfy {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } && generationID != nil
    }
}

private struct RecordedToolExecution: @unchecked Sendable {
    let name: String
    let input: [String: Any]
    let output: String
}

public enum AgentToolExecutionAttemptID {
    public static func canonical(
        executionIdentity: AgentExecutionIdentity?,
        composerSnapshot: ComposerSubmissionSnapshot?,
        childBoundary: AgentChildBoundary?
    ) -> String? {
        guard let executionIdentity,
              executionIdentity.isValid,
              executionIdentity.attempt > 0 else {
            return nil
        }
        if let attemptID = composerSnapshot?.attemptID
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !attemptID.isEmpty {
            return attemptID
        }
        if let generationID = childBoundary?.identity.generationID,
           !generationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return generationID
        }
        return "\(executionIdentity.operationID):attempt:\(executionIdentity.attempt)"
    }
}

private actor ToolExecutionRecorder {
    private var entries: [RecordedToolExecution] = []

    func append(_ entry: RecordedToolExecution) {
        entries.append(entry)
    }

    func snapshot() -> [RecordedToolExecution] {
        entries
    }
}

private struct RecordingToolExecutor: ToolCatalogValidatingExecutor, PolicyRuntimeBoundToolExecutor, SessionReadCapabilityAwareToolExecutor, @unchecked Sendable {
    let base: any ToolExecutor
    let recorder: ToolExecutionRecorder

    var policyRuntimeBound: Bool {
        (base as? any PolicyRuntimeBoundToolExecutor)?.policyRuntimeBound ?? false
    }

    func validateToolCatalog(_ tools: [AgentToolDefinition]) throws {
        try (base as? any ToolCatalogValidatingExecutor)?.validateToolCatalog(tools)
    }

    func execute(name: String, input: [String: Any]) async throws -> String {
        do {
            let output = try await base.execute(name: name, input: input)
            await recorder.append(RecordedToolExecution(
                name: name,
                input: input,
                output: output
            ))
            return output
        } catch {
            await recorder.append(RecordedToolExecution(
                name: name,
                input: input,
                output: error.localizedDescription
            ))
            throw error
        }
    }

    func executeSessionRead(
        input: [String: Any],
        authorization: CrossSessionReadAuthorization,
        context: SessionReadExecutionContext,
        now: Date
    ) async throws -> String {
        guard let aware = base as? any SessionReadCapabilityAwareToolExecutor else {
            throw CrossSessionReadAuthorizationError.capabilityRequired
        }
        do {
            let output = try await aware.executeSessionRead(
                input: input,
                authorization: authorization,
                context: context,
                now: now
            )
            await recorder.append(RecordedToolExecution(
                name: SessionReadTool.toolName,
                input: input,
                output: output
            ))
            return output
        } catch {
            await recorder.append(RecordedToolExecution(
                name: SessionReadTool.toolName,
                input: input,
                output: error.localizedDescription
            ))
            throw error
        }
    }
}

// MARK: - Child lifecycle boundary

public enum AgentChildLifecycleError: LocalizedError, Equatable, Sendable {
    case invalidIdentity
    case capabilityDenied(Set<ProviderCapability>)
    case unknownCapability(String)
    case emptyToolIntersection
    case cancelled
    case deadlineExceeded
    case staleReceipt

    public var errorDescription: String? {
        switch self {
        case .invalidIdentity:
            return "Child identity is not verified"
        case .capabilityDenied(let capabilities):
            return "Child capabilities denied: \(capabilities.map(\.rawValue).sorted().joined(separator: ","))"
        case .unknownCapability(let capability):
            return "Unknown child capability '\(capability)'"
        case .emptyToolIntersection:
            return "Child tool capability intersection is empty"
        case .cancelled:
            return "Child execution was cancelled"
        case .deadlineExceeded:
            return "Child execution deadline exceeded"
        case .staleReceipt:
            return "Child receipt is stale or already settled"
        }
    }

    public static func resolveCapabilities(
        _ rawCapabilities: Set<String>
    ) throws -> Set<ProviderCapability> {
        var resolved = Set<ProviderCapability>()
        for raw in rawCapabilities {
            guard let capability = ProviderCapability(rawValue: raw) else {
                throw AgentChildLifecycleError.unknownCapability(raw)
            }
            resolved.insert(capability)
        }
        return resolved
    }
}

public enum AgentChildReceiptOutcome: String, Sendable, Equatable, Codable {
    case running
    case succeeded
    case failed
    case cancelled
    case timedOut
}

public struct AgentChildReceipt: Sendable, Equatable, Codable {
    public let identity: ChildRuntimeIdentity
    public let attemptID: String
    public let outcome: AgentChildReceiptOutcome
    public let sequence: Int
    public let detail: String?

    public init(
        identity: ChildRuntimeIdentity,
        attemptID: String,
        outcome: AgentChildReceiptOutcome,
        sequence: Int,
        detail: String? = nil
    ) {
        self.identity = identity
        self.attemptID = attemptID
        self.outcome = outcome
        self.sequence = sequence
        self.detail = detail
    }
}

/// One terminal decision per child attempt. A recovered attempt must use a
/// fresh attempt ID; a late result from the retired attempt is rejected.
public actor AgentChildReceiptLedger {
    private var current: AgentChildReceipt?
    private var retiredAttempts: Set<String> = []

    public init() {}

    public func begin(identity: ChildRuntimeIdentity, attemptID: String) -> Bool {
        guard let canonicalAttemptID = Self.canonicalAttemptID(attemptID),
              identity.isValid,
              current == nil,
              !retiredAttempts.contains(Self.retiredKey(
                  identity: identity,
                  attemptID: canonicalAttemptID
              )) else {
            return false
        }
        current = AgentChildReceipt(
            identity: identity,
            attemptID: canonicalAttemptID,
            outcome: .running,
            sequence: 0
        )
        return true
    }

    @discardableResult
    public func settle(
        identity: ChildRuntimeIdentity,
        attemptID: String,
        outcome: AgentChildReceiptOutcome,
        detail: String? = nil,
        sequence: Int? = nil
    ) -> Bool {
        guard let canonicalAttemptID = Self.canonicalAttemptID(attemptID),
              let current,
              current.identity == identity,
              current.attemptID == canonicalAttemptID,
              current.outcome == .running else {
            return false
        }
        let nextSequence = sequence ?? (current.sequence + 1)
        guard nextSequence > current.sequence else { return false }
        self.current = AgentChildReceipt(
            identity: identity,
            attemptID: canonicalAttemptID,
            outcome: outcome,
            sequence: nextSequence,
            detail: detail
        )
        if outcome != .running {
            retiredAttempts.insert(Self.retiredKey(
                identity: identity,
                attemptID: canonicalAttemptID
            ))
        }
        return true
    }

    @discardableResult
    public func cancel(
        identity: ChildRuntimeIdentity,
        attemptID: String,
        detail: String = "cancelled"
    ) -> Bool {
        settle(
            identity: identity,
            attemptID: attemptID,
            outcome: .cancelled,
            detail: detail
        )
    }

    /// Reopen the lane only for a new attempt. The old identity remains
    /// tombstoned, so a delayed provider/tool completion cannot write back.
    public func recover(
        from identity: ChildRuntimeIdentity,
        nextAttemptID: String
    ) -> Bool {
        guard let canonicalNextAttemptID = Self.canonicalAttemptID(nextAttemptID),
              let current,
              current.identity == identity,
              current.outcome == .cancelled || current.outcome == .failed
                || current.outcome == .timedOut,
              canonicalNextAttemptID != current.attemptID,
              !retiredAttempts.contains(Self.retiredKey(
                  identity: identity,
                  attemptID: canonicalNextAttemptID
              )) else {
            return false
        }
        retiredAttempts.insert(Self.retiredKey(
            identity: identity,
            attemptID: current.attemptID
        ))
        self.current = nil
        return true
    }

    public func snapshot() -> AgentChildReceipt? {
        current
    }

    public func isRunning(
        identity: ChildRuntimeIdentity,
        attemptID: String
    ) -> Bool {
        guard let canonicalAttemptID = Self.canonicalAttemptID(attemptID),
              let current else { return false }
        return current.identity == identity
            && current.attemptID == canonicalAttemptID
            && current.outcome == .running
    }

    private static func canonicalAttemptID(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func retiredKey(
        identity: ChildRuntimeIdentity,
        attemptID: String
    ) -> String {
        let identityKey = identity.compositeIdentityKey
        return "\(identityKey.utf8.count)#\(identityKey)\(attemptID.utf8.count)#\(attemptID)"
    }
}

private struct AgentChildApprovalDelegate: ChildDeletionReviewPreparationDemand {
    let base: (any ApprovalDelegate)?
    var requiresDeletionPreparation: Bool {
        (base as? any ChildDeletionReviewPreparationDemand)?.requiresDeletionPreparation ?? false
    }

    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        guard let base else {
            return .deny
        }
        return await base.requestApproval(request)
    }
}

/// Immutable scope passed to one child run. The budget and receipt ledger are
/// intentionally supplied per child and are never implicitly shared with the
/// parent.
public struct AgentChildBoundary: Sendable {
    public let identity: ChildRuntimeIdentity
    public let grantedCapabilities: Set<ProviderCapability>
    public let tools: [AgentToolDefinition]
    public let budget: BudgetTracker
    public let deadline: Date?
    public let parentTurnHandle: TurnController.TurnHandle?
    public let childTurnController: TurnController?
    public let approvalGate: ApprovalGate
    public let receiptLedger: AgentChildReceiptLedger

    public init(
        identity: ChildRuntimeIdentity,
        parentCapabilities: Set<ProviderCapability>,
        requestedCapabilities: Set<ProviderCapability>,
        policy: AgentCapabilityPolicy,
        parentTools: [AgentToolDefinition],
        budget: BudgetTracker,
        deadline: Date? = nil,
        parentTurnHandle: TurnController.TurnHandle? = nil,
        childTurnController: TurnController? = nil,
        approvalGate: ApprovalGate? = nil,
        receiptLedger: AgentChildReceiptLedger = AgentChildReceiptLedger()
    ) throws {
        guard identity.isValid else {
            throw AgentChildLifecycleError.invalidIdentity
        }
        do {
            try identity.requireVerifiedGeneration()
        } catch {
            throw AgentChildLifecycleError.invalidIdentity
        }
        let intersection = AgentCapabilityIntersection.resolve(
            parentCapabilities: parentCapabilities,
            requestedCapabilities: requestedCapabilities,
            policyCapabilities: policy.allowedCapabilities
        )
        guard intersection.isAllowed else {
            throw AgentChildLifecycleError.capabilityDenied(intersection.missingCapabilities)
        }
        guard identity.grantedCapabilities == intersection.grantedCapabilities else {
            throw AgentChildLifecycleError.capabilityDenied(requestedCapabilities)
        }

        let childTools = intersection.grantedCapabilities.contains(.tools)
            ? parentTools.filter { policy.allowsTool($0.name) }
            : []
        if intersection.grantedCapabilities.contains(.tools) && childTools.isEmpty {
            throw AgentChildLifecycleError.emptyToolIntersection
        }
        self.identity = identity
        self.grantedCapabilities = intersection.grantedCapabilities
        self.tools = childTools
        self.budget = budget
        self.deadline = deadline
        self.parentTurnHandle = parentTurnHandle
        self.childTurnController = childTurnController
        self.approvalGate = ApprovalGate(
            policyByTool: (approvalGate ?? ApprovalGate()).policyByTool,
            delegate: AgentChildApprovalDelegate(
                base: (approvalGate ?? ApprovalGate()).delegate
            )
        )
        self.receiptLedger = receiptLedger
    }

    public func allowsTool(_ name: String) -> Bool {
        tools.contains { $0.name == name }
    }

    public func isCancelled() async -> Bool {
        if Task.isCancelled { return true }
        if let parentTurnHandle, await parentTurnHandle.isCancelled() { return true }
        if let childTurnController, await childTurnController.isCancelled() { return true }
        return false
    }

    public func check() async throws {
        if await isCancelled() {
            throw AgentChildLifecycleError.cancelled
        }
        if let deadline, Date() >= deadline {
            throw AgentChildLifecycleError.deadlineExceeded
        }
    }

    public func remainingTimeout(now: Date = Date()) -> TimeInterval? {
        guard let deadline else { return nil }
        return max(0, deadline.timeIntervalSince(now))
    }
}

/// Convenience wrapper around `AgentLoop` that owns the message history.
///
///     var context = AgentContext(
///         toolExecutor: BuiltinToolExecutor(allowedRoot: projectDir),
///         provider: provider,
///         systemPrompt: "You are a macOS coding agent."
///     )
///     let history = try await context.run(userMessage: "List the files")
///
/// Each `run(userMessage:)` appends the user message, drives the tool loop to
/// completion, and updates `messages` with the full resulting history.
public struct AgentContext {
    struct PendingSteer: Sendable {
        let instruction: SteerInstruction
        var skippedRuns: Int
    }

    /// Full conversation history (user/assistant/tool_result messages).
    public var messages: [LLMMessage]
    public var toolExecutor: any ToolExecutor
    public var provider: any LLMProvider
    /// Optional immutable production route. When present, the route is the
    /// provider used for every model call in this context.
    public var providerRuntimeRoute: ProviderRuntimeRoute?
    public var systemPrompt: String?
    /// Tool schemas offered to the model. Defaults to `AgentToolCatalog.makeTools()`.
    public var tools: [AgentToolDefinition]
    public var maxTokens: Int
    public var temperature: Double?
    /// Maximum LLM round-trips per `run` call. Defaults to 10.
    public var maxIterations: Int
    public var approvalGate: ApprovalGate?
    public var turnController: TurnController?
    public var requestBudget: BudgetTracker?
    public var compactor: Compactor?
    /// Maximum duration of one provider request. Nil means provider-defined.
    public var timeout: TimeInterval?
    public var currentConversationID: String?
    /// Composition-root identity facts; AgentLoop binds these to its real turn handle.
    public var parentIdentitySeed: ParentRuntimeIdentitySeed?
    public var authorizedSessionReadSessionID: String?
    /// Exact parent handle used to propagate cancellation into a derived child.
    public var parentTurnHandle: TurnController.TurnHandle?
    /// A child context always carries its own catalog, budget and receipt lane.
    public var childBoundary: AgentChildBoundary?
    /// Durable authority for terminal tool execution facts.
    public var toolExecutionFactLedger: ToolExecutionFactLedger?
    /// Canonical identity frozen by the composition root for this run.
    public var executionIdentity: AgentExecutionIdentity?
    /// Immutable Composer attempt identity used by the same ledger lane as
    /// AgentLoop's canonical attempt selection.
    public var composerSnapshot: ComposerSubmissionSnapshot?
    /// Unified production scope shared with ContextManifestStore.
    public let executionScopeIdentity: AgentExecutionScopeIdentity?
    /// Short-form projection for consumers that refer to the active scope as
    /// simply `scopeIdentity`; both accessors expose the same immutable value.
    public var scopeIdentity: AgentExecutionScopeIdentity? {
        executionScopeIdentity
    }
    /// Partial history captured when a provider/tool turn fails.
    public private(set) var lastPartialMessages: [LLMMessage] = []
    var pendingSteers: [PendingSteer] = []

    public init(
        messages: [LLMMessage] = [],
        toolExecutor: any ToolExecutor,
        provider: any LLMProvider,
        providerRuntimeRoute: ProviderRuntimeRoute? = nil,
        systemPrompt: String? = nil,
        tools: [AgentToolDefinition] = AgentToolCatalog.makeTools(),
        maxTokens: Int = 4096,
        temperature: Double? = nil,
        maxIterations: Int = 10,
        approvalGate: ApprovalGate? = nil,
        turnController: TurnController? = nil,
        requestBudget: BudgetTracker? = nil,
        compactor: Compactor? = nil,
        timeout: TimeInterval? = nil,
        currentConversationID: String? = nil,
        parentIdentitySeed: ParentRuntimeIdentitySeed? = nil,
        authorizedSessionReadSessionID: String? = nil,
        parentTurnHandle: TurnController.TurnHandle? = nil,
        childBoundary: AgentChildBoundary? = nil,
        toolExecutionFactLedger: ToolExecutionFactLedger? = nil,
        executionIdentity: AgentExecutionIdentity? = nil,
        composerSnapshot: ComposerSubmissionSnapshot? = nil,
        executionScopeIdentity: AgentExecutionScopeIdentity? = nil
    ) {
        self.messages = messages
        self.toolExecutor = toolExecutor
        self.provider = provider
        self.providerRuntimeRoute = providerRuntimeRoute
        self.systemPrompt = systemPrompt
        self.tools = tools
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.maxIterations = maxIterations
        self.approvalGate = approvalGate
        self.turnController = turnController
        self.requestBudget = requestBudget
        self.compactor = compactor
        self.timeout = timeout.map { max(0, $0) }
        self.currentConversationID = currentConversationID
        self.parentIdentitySeed = parentIdentitySeed
        self.authorizedSessionReadSessionID = authorizedSessionReadSessionID
        self.parentTurnHandle = parentTurnHandle
        self.childBoundary = childBoundary
        self.toolExecutionFactLedger = toolExecutionFactLedger
        self.executionIdentity = executionIdentity
        self.composerSnapshot = composerSnapshot
        self.executionScopeIdentity = executionScopeIdentity
    }

    /// Fail-closed consumer seam used before a context enters production
    /// orchestration. The expected identity must be the exact same binding
    /// consumed by ContextManifestStore.
    public func requireExecutionScope(
        _ expected: AgentExecutionScopeIdentity
    ) throws -> AgentExecutionScopeIdentity {
        guard expected.isValid else { throw AgentContextScopeError.invalidScopeIdentity }
        guard let executionScopeIdentity else {
            throw AgentContextScopeError.missingScopeIdentity
        }
        guard executionScopeIdentity.matches(expected),
              executionScopeIdentity.fingerprint == expected.fingerprint,
              executionIdentity?.turn.sessionID == nil
                  || executionIdentity?.turn.sessionID == executionScopeIdentity.sessionID else {
            throw AgentContextScopeError.scopeDrift
        }
        return executionScopeIdentity
    }

    /// Derive a child scope from this context. Tool names are filtered from
    /// the parent catalog and cannot be reintroduced by policy alone.
    public func deriveChild(
        identity: ChildRuntimeIdentity,
        requestedCapabilities: Set<ProviderCapability>,
        policy: AgentCapabilityPolicy,
        budget: BudgetTracker,
        deadline: Date? = nil,
        childTurnController: TurnController? = nil,
        approvalGate: ApprovalGate? = nil,
        maxIterations: Int? = nil,
        executionIdentity: AgentExecutionIdentity? = nil
    ) throws -> AgentContext {
        let parentCapabilities = childBoundary?.grantedCapabilities ?? provider.capabilities
        let boundary = try AgentChildBoundary(
            identity: identity,
            parentCapabilities: parentCapabilities,
            requestedCapabilities: requestedCapabilities,
            policy: policy,
            parentTools: tools,
            budget: budget,
            deadline: deadline,
            parentTurnHandle: parentTurnHandle,
            childTurnController: childTurnController,
            approvalGate: approvalGate ?? self.approvalGate
        )
        if self.toolExecutionFactLedger != nil {
            guard let executionIdentity,
                  executionIdentity.isValid,
                  executionIdentity.attempt > 0,
                  executionIdentity.turn.sessionID == identity.childSessionID,
                  identity.cancelGeneration > 0,
                  executionIdentity.turn.turnID == identity.cancelGeneration,
                  executionIdentity.turn.messageID == identity.childTaskID,
                  executionIdentity.operationID == identity.generationID else {
                throw AgentChildLifecycleError.invalidIdentity
            }
        }
        return AgentContext(
            messages: [],
            toolExecutor: toolExecutor,
            provider: provider,
            providerRuntimeRoute: providerRuntimeRoute,
            systemPrompt: systemPrompt,
            tools: boundary.tools,
            maxTokens: maxTokens,
            temperature: temperature,
            maxIterations: maxIterations ?? self.maxIterations,
            approvalGate: boundary.approvalGate,
            turnController: childTurnController,
            requestBudget: budget,
            compactor: compactor,
            timeout: minTimeout(timeout, boundary.remainingTimeout()),
            currentConversationID: identity.childSessionID,
            authorizedSessionReadSessionID: nil,
            parentTurnHandle: parentTurnHandle,
            childBoundary: boundary,
            toolExecutionFactLedger: self.toolExecutionFactLedger,
            executionIdentity: executionIdentity,
            composerSnapshot: self.composerSnapshot,
            executionScopeIdentity: self.executionScopeIdentity
        )
    }

    /// Append `userMessage` and drive the agent loop until the model stops
    /// requesting tools. Returns the updated message history.
    @discardableResult
    public mutating func run(userMessage: String) async throws -> [LLMMessage] {
        let priorMessageCount = messages.count
        messages.append(LLMMessage(role: .user, content: userMessage))
        lastPartialMessages = Array(messages.dropFirst(priorMessageCount))
        let activeSteers = pendingSteers
            .filter { $0.skippedRuns == 0 }
            .map(\.instruction)
        pendingSteers = pendingSteers.map { pending in
            var updated = pending
            updated.skippedRuns = max(0, pending.skippedRuns - 1)
            return updated
        }
        var turnSystemPrompt = systemPrompt
        if !activeSteers.isEmpty {
            let block = activeSteers.map { "[转向指令] " + $0.text }.joined(separator: "\n\n")
            if let existing = turnSystemPrompt, !existing.isEmpty {
                turnSystemPrompt = existing + "\n\n" + block
            } else {
                turnSystemPrompt = block
            }
        }
        if let childBoundary {
            guard await childBoundary.receiptLedger.begin(
                identity: childBoundary.identity,
                attemptID: childBoundary.identity.generationID ?? childBoundary.identity.childTaskID
            ) else {
                throw AgentChildLifecycleError.staleReceipt
            }
        }
        let recorder = ToolExecutionRecorder()
        let effectiveToolExecutor: any ToolExecutor
        if let composerExecutor = toolExecutor as? ComposerPolicyEnforcedToolExecutor {
            let recordingBase = RecordingToolExecutor(
                base: composerExecutor.base,
                recorder: recorder
            )
            effectiveToolExecutor = ComposerPolicyEnforcedToolExecutor(
                base: recordingBase,
                controller: composerExecutor.controller,
                approvalGate: composerExecutor.approvalGate,
                onApprovalReceipt: composerExecutor.onApprovalReceipt,
                // Goal18 Hooks: rebuilding the executor must not drop its hooks.
                hookHandler: composerExecutor.hookHandler,
                postToolHandler: composerExecutor.postToolHandler
            )
        } else {
            effectiveToolExecutor = RecordingToolExecutor(
                base: toolExecutor,
                recorder: recorder
            )
        }
        do {
            let result = try await AgentLoop(
                maxIterations: maxIterations,
                approvalGate: approvalGate,
                turnController: turnController,
                requestBudget: requestBudget,
                compactor: compactor,
                timeout: timeout,
                childBoundary: childBoundary,
                toolExecutionFactLedger: toolExecutionFactLedger
            ).run(
                messages: messages,
                systemPrompt: turnSystemPrompt,
                provider: provider,
                providerRuntimeRoute: providerRuntimeRoute,
                toolExecutor: effectiveToolExecutor,
                tools: tools,
                maxTokens: maxTokens,
                temperature: temperature,
                currentConversationID: currentConversationID,
                authorizedSessionReadSessionID: authorizedSessionReadSessionID,
                parentIdentitySeed: parentIdentitySeed,
                composerSnapshot: composerSnapshot,
                executionIdentity: executionIdentity
            )
            messages = result.messages
            lastPartialMessages = result.messages
            if let childBoundary {
                _ = await childBoundary.receiptLedger.settle(
                    identity: childBoundary.identity,
                    attemptID: childBoundary.identity.generationID ?? childBoundary.identity.childTaskID,
                    outcome: .succeeded,
                    detail: "child-completed"
                )
            }
            return messages
        } catch {
            let facts = currentToolExecutionFacts()
            lastPartialMessages = makePartialMessages(
                base: Array(messages.dropFirst(priorMessageCount)),
                facts: facts,
                records: await recorder.snapshot()
            )
            if let childBoundary {
                let outcome: AgentChildReceiptOutcome
                if let lifecycleError = error as? AgentChildLifecycleError,
                   lifecycleError == .deadlineExceeded {
                    outcome = .timedOut
                } else if let loopError = error as? AgentLoopError,
                          case .timedOut = loopError {
                    outcome = .timedOut
                } else if error is InterruptedError || error is CancellationError {
                    outcome = .cancelled
                } else {
                    outcome = .failed
                }
                _ = await childBoundary.receiptLedger.settle(
                    identity: childBoundary.identity,
                    attemptID: childBoundary.identity.generationID ?? childBoundary.identity.childTaskID,
                    outcome: outcome,
                    detail: error.localizedDescription
                )
            }
            throw error
        }
    }

    private func currentToolExecutionFacts() -> [ToolExecutionFact] {
        guard let ledger = toolExecutionFactLedger,
              let executionIdentity,
              executionIdentity.isValid,
              executionIdentity.attempt > 0 else {
            return []
        }
        guard let attemptID = AgentToolExecutionAttemptID.canonical(
            executionIdentity: executionIdentity,
            composerSnapshot: composerSnapshot,
            childBoundary: childBoundary
        ) else {
            return []
        }
        return ledger.facts(
            executionIdentity: executionIdentity,
            attemptID: attemptID,
            attemptNumber: executionIdentity.attempt
        )
    }

    private func makePartialMessages(
        base: [LLMMessage],
        facts: [ToolExecutionFact],
        records: [RecordedToolExecution]
    ) -> [LLMMessage] {
        guard !facts.isEmpty else { return base }
        let calls = facts.enumerated().map { index, fact in
            let record = index < records.count ? records[index] : nil
            let rawArguments = record.flatMap {
                try? JSONSerialization.data(withJSONObject: $0.input)
            }.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return LLMToolCall(
                id: fact.toolCallID,
                name: record?.name ?? fact.toolName,
                rawArguments: rawArguments,
                arguments: record?.input ?? [:]
            )
        }
        var partial = base
        partial.append(LLMMessage(role: .assistant, content: "", toolCalls: calls))
        for (index, fact) in facts.enumerated() {
            let record = index < records.count ? records[index] : nil
            let content = record?.output
                ?? "Tool execution \(fact.status.rawValue): \(fact.toolName)"
            partial.append(LLMMessage(
                role: .tool,
                content: content,
                toolCallID: fact.toolCallID
            ))
        }
        return partial
    }

}

func minTimeout(_ lhs: TimeInterval?, _ rhs: TimeInterval?) -> TimeInterval? {
    switch (lhs, rhs) {
    case let (lhs?, rhs?): return min(lhs, rhs)
    case let (lhs?, nil): return lhs
    case let (nil, rhs?): return rhs
    case (nil, nil): return nil
    }
}
