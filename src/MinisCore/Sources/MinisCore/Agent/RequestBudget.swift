import Foundation
import os

/// Per-session request budget for LLM calls.
///
/// Tracks how many requests and how many tokens a session has consumed against
/// configured caps, and reports the policy that should be triggered once a cap
/// is exceeded. Pure value type — no I/O, no global state.
///
/// Design notes (port of the budget discipline in OpenMinis
/// `AIChatViewModel+RequestBudget`):
/// - `maxRequestsPerSession` / `maxTokensPerSession` are both optional;
///   a `nil` cap is never exceeded.
/// - `record(requestTokens:)` is called once per LLM round-trip with the
///   usage reported by the provider (`LLMUsage.inputTokens + outputTokens`).
/// - The policy returned by `record` is `nil` while under budget; once a cap
///   is crossed it returns `overBudgetPolicy` every subsequent call so the
///   caller keeps nudging the user / loop.
public struct RequestBudget: Sendable, Equatable {

    /// What to do when the budget is exceeded.
    public enum Policy: String, Sendable, Equatable {
        /// Halt further LLM calls until the budget is reset/extended.
        case pause
        /// Keep going but surface a warning.
        case warn
        /// Trigger an automatic context compaction to free token headroom.
        case autoCompact
    }

    public let maxRequestsPerSession: Int?
    public fileprivate(set) var maxTokensPerSession: Int?
    /// Optional wall-clock deadline shared by every provider attempt in the
    /// session.  Consumers must never extend this deadline when routing or
    /// retrying a request.
    public let deadline: Date?
    /// Policy returned by `record` once any cap is exceeded.
    public var overBudgetPolicy: Policy

    /// Default token cap for a fresh session (E8 usage status bar) when no
    /// AppSettings value is available — 1,000,000 tokens (user decision 11/9;
    /// was 100,000).
    public static let defaultMaxTokensPerSession = 1_000_000

    /// Default usage fraction that triggers the warning color on the
    /// E8 status bar (mirrors `AgentSettings.default.autoCompactThreshold`).
    public static let defaultWarningFraction = 0.8

    public private(set) var usedRequests: Int = 0
    public private(set) var usedTokens: Int = 0

    /// Negative caps are invalid configuration, not an empty budget silently
    /// converted into a different policy.
    public var isConfigurationValid: Bool {
        (maxRequestsPerSession == nil || maxRequestsPerSession! >= 0)
            && (maxTokensPerSession == nil || maxTokensPerSession! >= 0)
    }

    public init(
        maxRequestsPerSession: Int? = nil,
        maxTokensPerSession: Int? = nil,
        // Production callers must fail closed. `.warn` remains available only
        // when the product explicitly selects it.
        overBudgetPolicy: Policy = .pause,
        deadline: Date? = nil
    ) {
        self.maxRequestsPerSession = maxRequestsPerSession
        self.maxTokensPerSession = maxTokensPerSession
        self.overBudgetPolicy = overBudgetPolicy
        self.deadline = deadline
    }

    // MARK: Recording

    /// Record one LLM call using `requestTokens` tokens.
    ///
    /// - Returns: `overBudgetPolicy` when this call pushed the budget past a
    ///   cap (or the budget was already over), otherwise `nil`.
    @discardableResult
    public mutating func record(requestTokens: Int) -> Policy? {
        usedRequests = usedRequests == Int.max ? Int.max : usedRequests + 1
        let tokens = max(0, requestTokens)
        usedTokens = Int.max - usedTokens < tokens ? Int.max : usedTokens + tokens
        return isExhausted ? overBudgetPolicy : nil
    }

    /// Add tokens spent outside this session's own requests (a settled child)
    /// without counting a request. Saturating, like `record`.
    @discardableResult
    public mutating func recordTokens(_ requestTokens: Int) -> Policy? {
        let tokens = max(0, requestTokens)
        usedTokens = Int.max - usedTokens < tokens ? Int.max : usedTokens + tokens
        return isExhausted ? overBudgetPolicy : nil
    }

    // MARK: Status

    /// True when any configured cap has been reached or exceeded.
    public var isExhausted: Bool {
        if let cap = maxRequestsPerSession, usedRequests >= cap { return true }
        if let cap = maxTokensPerSession, usedTokens >= cap { return true }
        return false
    }

    /// True after the shared wall-clock deadline has elapsed.
    public var isExpired: Bool {
        guard let deadline else { return false }
        return Date() >= deadline
    }

    /// Shared fail-closed terminal reason, when this budget cannot admit a
    /// new request.  Consumers can carry this typed value across fallback
    /// routes without parsing an error string.
    public var terminalReason: ToolTerminalReason? {
        guard isConfigurationValid else { return .requestBudgetInvalid }
        if isExpired { return .requestBudgetExpired }
        if isExhausted { return .requestBudgetExhausted }
        return nil
    }

    /// Remaining wall-clock time for a provider attempt, if bounded.
    public var remainingTime: TimeInterval? {
        deadline.map { max(0, $0.timeIntervalSinceNow) }
    }

    /// Requests left before the cap, or nil when no request cap is configured.
    public var requestsRemaining: Int? {
        maxRequestsPerSession.map { max(0, $0 - usedRequests) }
    }

    /// Tokens left before the cap, or nil when no token cap is configured.
    public var tokensRemaining: Int? {
        maxTokensPerSession.map { max(0, $0 - usedTokens) }
    }

    /// 0...1 fraction of the binding cap consumed. 1.0 when exhausted.
    /// Returns 0 when no cap is configured.
    public var usageFraction: Double {
        if let cap = maxTokensPerSession, cap > 0 {
            return min(1.0, Double(usedTokens) / Double(cap))
        }
        if let cap = maxRequestsPerSession, cap > 0 {
            return min(1.0, Double(usedRequests) / Double(cap))
        }
        return 0
    }

    // MARK: Reset

    /// Zero the counters (new session / renewed quota).
    public mutating func reset() {
        usedRequests = 0
        usedTokens = 0
    }
}

// MARK: - Budget Tracker (F19 P1-4)

/// Errors raised before a provider request starts.
public enum BudgetTrackerError: Error, LocalizedError, Equatable, Sendable {
    case exhausted
    case invalidConfiguration
    case deadlineExceeded

    public var errorDescription: String? {
        "The request budget blocks a new provider request"
    }

    /// Canonical terminal reason for the shared tool-limit contract.
    public var terminalReason: ToolTerminalReason {
        switch self {
        case .exhausted: return .requestBudgetExhausted
        case .invalidConfiguration: return .requestBudgetInvalid
        case .deadlineExceeded: return .requestBudgetExpired
        }
    }
}

/// An in-memory reservation for one provider attempt.
///
/// A lease is settled only after a successful provider response. A failed
/// attempt releases the lease without incrementing either request or token
/// usage, which keeps retry failures uncharged.
public struct BudgetRequestLease: Sendable, Equatable {
    fileprivate let id: UUID
    fileprivate let generation: UUID

    fileprivate init(id: UUID, generation: UUID) {
        self.id = id
        self.generation = generation
    }
}

/// Thread-safe shared holder around a `RequestBudget` (F19 P1-4).
///
/// `RequestBudget` is a value type, but enforcement needs one budget instance
/// shared between the recording side (`AgentLoop.run` records every provider
/// round-trip) and the UI/session layer that displays usage and may
/// reset/extend the quota. `BudgetTracker` is that shared reference:
///
///     let tracker = BudgetTracker(RequestBudget(
///         maxTokensPerSession: 100_000, overBudgetPolicy: .pause))
///     let loop = AgentLoop(requestBudget: tracker)
///     // ... the loop records usage and HALTS on .pause, compacts on
///     // .autoCompact — see AgentLoop.run (F19 P1-4 enforcement).
///
/// The UI layer can keep reading `tracker.budget` for status display; the
/// counters are no longer "soft" — the loop acts on the returned policy.
public actor BudgetTracker {

    private struct TokenLimitTarget: Sendable {
        let revision: UUID
        let limit: Int?
    }
    private nonisolated let tokenLimitTarget = OSAllocatedUnfairLock<TokenLimitTarget?>(initialState: nil)
    private var appliedTokenLimitRevision: UUID?
    private var currentBudget: RequestBudget
    /// Every existing admission, settlement and snapshot reads the latest staged
    /// token cap inside this actor; counters and lease generation stay untouched.
    public private(set) var budget: RequestBudget {
        get {
            if let target = tokenLimitTarget.withLock({ $0 }), target.revision != appliedTokenLimitRevision {
                currentBudget.maxTokensPerSession = target.limit
                appliedTokenLimitRevision = target.revision
            }
            return currentBudget
        }
        set { currentBudget = newValue }
    }
    private var pendingRequests: Set<UUID> = []
    /// Settled children already charged to this account (by transcript
    /// locator); cleared with the account on `reset`/`replace`.
    private var accountedChildren: Set<ChildTranscriptLocator> = []
    /// A reset/replace invalidates leases from the previous session. An old
    /// Provider response may still arrive, but it must not charge the new
    /// session or consume its request slot.
    private var generation = UUID()

    public init(_ budget: RequestBudget) {
        self.currentBudget = budget
    }

    /// Record one LLM round-trip. Returns the policy to enforce when this
    /// call crossed (or the budget was already past) a cap; nil while under
    /// budget. See `RequestBudget.record(requestTokens:)`.
    @discardableResult
    public func record(requestTokens: Int) -> RequestBudget.Policy? {
        budget.record(requestTokens: requestTokens)
    }

    /// Reserve a provider attempt before calling the provider.
    ///
    /// For a `.pause` budget, request-cap reservations close the race between
    /// two concurrent turns: only the number of requests still available may
    /// enter the provider. Token caps are checked against committed usage;
    /// their exact charge is unknown until the provider returns usage.
    public func beginRequest() throws -> BudgetRequestLease {
        try beginRequest(enforceExhaustion: false)
    }

    /// Reserve a provider attempt, optionally applying the strict terminal
    /// boundary used by fallback/retry consumers.  The reservation is shared
    /// across all routes; no consumer may reset or extend it.
    public func beginRequest(enforceExhaustion: Bool) throws -> BudgetRequestLease {
        guard budget.isConfigurationValid else {
            throw BudgetTrackerError.invalidConfiguration
        }
        if budget.isExpired {
            throw BudgetTrackerError.deadlineExceeded
        }
        if enforceExhaustion || budget.overBudgetPolicy == .pause {
            if budget.isExhausted {
                throw BudgetTrackerError.exhausted
            }
            if let cap = budget.maxRequestsPerSession,
               budget.usedRequests + pendingRequests.count >= cap {
                throw BudgetTrackerError.exhausted
            }
        }

        let lease = BudgetRequestLease(id: UUID(), generation: generation)
        pendingRequests.insert(lease.id)
        return lease
    }

    /// Check the shared terminal boundary without reserving a slot.  The
    /// router uses this before resolving a fallback provider so an exhausted
    /// or expired request cannot even start the next provider.
    public func checkCanBeginRequest() throws {
        guard budget.isConfigurationValid else {
            throw BudgetTrackerError.invalidConfiguration
        }
        if budget.isExpired { throw BudgetTrackerError.deadlineExceeded }
        if budget.isExhausted { throw BudgetTrackerError.exhausted }
        if let cap = budget.maxRequestsPerSession,
           budget.usedRequests + pendingRequests.count >= cap {
            throw BudgetTrackerError.exhausted
        }
    }

    /// Settle a successful provider attempt and charge its reported usage.
    /// A successful response with no usage still counts as one request and
    /// charges zero tokens; tools are never passed to this method.
    @discardableResult
    public func completeRequest(
        _ lease: BudgetRequestLease,
        usage: LLMUsage?
    ) -> RequestBudget.Policy? {
        completeRequest(lease, usage: usage, consumeResponseAtRequestCap: false)
    }

    func completeRequest(
        _ lease: BudgetRequestLease,
        usage: LLMUsage?,
        consumeResponseAtRequestCap: Bool
    ) -> RequestBudget.Policy? {
        settleRequest(lease, usage: usage, consumeResponseAtRequestCap: consumeResponseAtRequestCap).policy
    }

    /// Reports whether the original lease actually charged its account.
    public func completeRequestAndConfirmCharge(_ lease: BudgetRequestLease, usage: LLMUsage?) -> Bool {
        settleRequest(lease, usage: usage, consumeResponseAtRequestCap: false).charged
    }

    private func settleRequest(
        _ lease: BudgetRequestLease, usage: LLMUsage?, consumeResponseAtRequestCap: Bool
    ) -> (charged: Bool, policy: RequestBudget.Policy?) {
        guard lease.generation == generation,
              pendingRequests.remove(lease.id) != nil else { return (false, nil) }
        // A response that arrives after cancellation or the shared deadline
        // is late and must not become billable or unlock another route.
        guard !Task.isCancelled, !budget.isExpired else {
            return (false, .pause)
        }
        let tokens = (usage?.totalInputTokens ?? 0) + (usage?.outputTokens ?? 0)
        let requestsBefore = budget.usedRequests
        let policy = budget.record(requestTokens: tokens)
        // Only an admitted response that just reached the request cap may
        // continue. The charged request still exhausts the next admission.
        if consumeResponseAtRequestCap, policy == .pause,
           let cap = budget.maxRequestsPerSession,
           requestsBefore < cap, budget.usedRequests == cap,
           budget.tokensRemaining != 0 {
            return (true, nil)
        }
        return (true, policy)
    }

    /// Identity of the current account. A child captures it when it starts and
    /// presents it when charging, so a child that outlives a reset/replace
    /// does not charge the new account.
    public var childUsageGeneration: UUID { generation }

    /// Charge a settled child's provider-reported tokens to this account:
    /// total input + output, no request counted. Idempotent per locator;
    /// ignored when `sourceGeneration` is no longer current.
    @discardableResult
    public func recordSettledChildUsage(
        _ usage: ChildResultTokenUsage,
        locator: ChildTranscriptLocator,
        sourceGeneration: UUID
    ) -> RequestBudget.Policy? {
        guard sourceGeneration == generation, usage.isWellFormed,
              accountedChildren.insert(locator).inserted else { return nil }
        let (tokens, overflow) = usage.effectiveInputTokens.addingReportingOverflow(usage.outputTokens)
        return budget.recordTokens(overflow ? Int.max : tokens)
    }

    /// Release a failed/cancelled provider attempt without charging it.
    public func failRequest(_ lease: BudgetRequestLease) {
        pendingRequests.remove(lease.id)
    }

    /// Number of provider attempts currently in flight. Exposed for
    /// diagnostics/tests; it is not part of persisted session state.
    public var pendingRequestCount: Int { pendingRequests.count }

    /// True when any configured cap has been reached or exceeded.
    public var isExhausted: Bool { budget.isExhausted }

    /// True when new LLM requests must be refused outright: the budget is
    /// exhausted and the policy is `.pause`. `AgentLoop.run` checks this
    /// *before* the first provider call of a turn, so a paused budget never
    /// burns another request.
    public var shouldBlockNewRequests: Bool {
        budget.isExhausted && budget.overBudgetPolicy == .pause
    }

    /// Current bounded terminal reason, if this tracker is already closed to
    /// new provider requests.  A warning/compaction policy may remain live,
    /// but an invalid or expired budget is always terminal.
    public var terminalReason: ToolTerminalReason? {
        budget.terminalReason
    }

    /// Synchronous settings handoff. The slot holds only a typed latest target;
    /// actual quota mutation still belongs to the actor's existing budget reads.
    public nonisolated func stageTokenLimit(_ limit: Int?) throws {
        guard limit.map({ $0 >= 0 }) ?? true else { throw BudgetTrackerError.invalidConfiguration }
        let target = TokenLimitTarget(revision: UUID(), limit: limit)
        tokenLimitTarget.withLock { $0 = target }
    }

    /// Direct actor caller convenience; UI workers only read the resulting snapshot.
    @discardableResult
    public func setTokenLimit(_ limit: Int?) throws -> RequestBudget {
        try stageTokenLimit(limit)
        return budget
    }

    /// Zero the counters (new session / renewed quota).
    public func reset() {
        pendingRequests.removeAll()
        accountedChildren.removeAll()
        generation = UUID()
        budget.reset()
    }

    /// Replace the configuration and counters for a new session or settings
    /// snapshot. In-flight leases from the previous configuration are invalid.
    public func replace(with newBudget: RequestBudget) {
        // An explicit replacement supersedes targets already staged for its old
        // configuration. A target staged after this read remains a newer update.
        appliedTokenLimitRevision = tokenLimitTarget.withLock { $0?.revision }
        pendingRequests.removeAll()
        accountedChildren.removeAll()
        generation = UUID()
        budget = newBudget
    }
}
