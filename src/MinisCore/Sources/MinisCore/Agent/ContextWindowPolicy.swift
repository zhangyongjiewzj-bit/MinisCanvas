import Foundation

/// Window-occupancy rules shared by the loop (per request) and the App
/// (turn start). Pure value type, no I/O.
///
/// Occupancy and window must describe the same provider/model identity; the
/// caller is responsible for that check.
public enum ContextWindowPolicy {
    /// User decision (2130 / task book): only at or above 95% is a send refused.
    public static let hardBlockFraction: Double = 0.95

    public enum Decision: Sendable, Equatable {
        /// Below the trigger: send as is.
        case proceed
        /// At or above the trigger and this transcript has not been judged yet:
        /// try a compaction.
        case compact(fraction: Double)
        /// At or above the trigger, the transcript was already judged (compacted
        /// or refused) but still below the hard block: send.
        case proceedAfterRefusal(fraction: Double)
        /// At or above the hard block and no remaining reduction: do not send.
        case blocked(fraction: Double)
    }

    /// - Parameters:
    ///   - occupancyTokens: occupancy of the request as it would be delivered
    ///     (already net of any request-copy reduction).
    ///   - threshold: user compaction threshold; it never exceeds the hard block
    ///     as a trigger, so a threshold above 95% still compacts at 95%.
    ///   - compactionAlreadyJudgedForThisTranscript: a compaction was already
    ///     tried (succeeded or refused) and occupancy has not fallen below the
    ///     trigger since.
    public static func decide(
        occupancyTokens: Int,
        windowTokens: Int,
        threshold: Double,
        compactionAlreadyJudgedForThisTranscript: Bool
    ) -> Decision {
        let fraction = Double(occupancyTokens) / Double(windowTokens)
        guard fraction >= min(threshold, hardBlockFraction) else { return .proceed }
        if !compactionAlreadyJudgedForThisTranscript { return .compact(fraction: fraction) }
        return fraction >= hardBlockFraction
            ? .blocked(fraction: fraction)
            : .proceedAfterRefusal(fraction: fraction)
    }

    /// The last Provider-reported figures and which messages they cover.
    public struct Anchor: Sendable, Equatable {
        /// Number of messages in the request that was reported. The assistant
        /// reply that followed it (the next message, if present) is accounted
        /// by `reportedOutput`, not estimated again.
        public let sentMessageCount: Int
        /// `LLMUsage.totalInputTokens` of that request.
        public let reportedTotalInput: Int
        public let reportedOutput: Int
        public init(sentMessageCount: Int, reportedTotalInput: Int, reportedOutput: Int) {
            self.sentMessageCount = sentMessageCount
            self.reportedTotalInput = reportedTotalInput
            self.reportedOutput = reportedOutput
        }
    }

    /// Estimated input tokens of the next request.
    ///
    /// With a usable anchor: reported total input + reported output + the local
    /// estimate (characters / 4, same rule as `AgentContextTokenBudget`) of the
    /// messages added after the anchored reply. Without one, or when the
    /// transcript is shorter than the anchor (it was replaced), the pure local
    /// estimate. Local estimates under-count CJK text and ignore images, which
    /// is why the anchor is preferred. Returns nil only on integer overflow.
    public static func estimateInput(
        messages: [LLMMessage],
        systemPrompt: String,
        anchor: Anchor?
    ) -> Int? {
        guard let anchor, messages.count >= anchor.sentMessageCount else {
            return AgentContextTokenBudget.estimatedInputCost(messages, systemPrompt: systemPrompt)
        }
        let tail = messages.dropFirst(min(messages.count, anchor.sentMessageCount + 1))
        guard let tailCost = AgentContextTokenBudget.estimatedMessagesCost(Array(tail)) else { return nil }
        let (reported, overflow) = anchor.reportedTotalInput.addingReportingOverflow(anchor.reportedOutput)
        let (total, overflow2) = reported.addingReportingOverflow(tailCost)
        return overflow || overflow2 ? nil : total
    }
}

/// Window admission for one `AgentLoop`. nil on the loop = no admission, the
/// loop behaves exactly as before.
///
/// Built by the App from the same figures the occupancy chip uses; the loop
/// owns every decision made from it (user decision S2).
public struct ContextAdmissionConfig: Sendable {
    /// Tokens of the window this loop is admitted against. For a user-selected
    /// context length that is the smaller of it and the model window.
    public let windowTokens: Int
    /// Compaction trigger as a fraction of the window (e.g. 0.8).
    public let triggerFraction: Double
    /// Provider-reported occupancy known at turn start, if any.
    public let initialAnchor: ContextWindowPolicy.Anchor?
    /// Shared with the App's delivery projection; see `ContextReductionState`.
    public let reduction: ContextReductionState
    /// True when the current transcript version was already judged for
    /// compaction (compacted or refused). The loop then never starts a
    /// proactive compaction in this run; the reduction still activates at the
    /// trigger, so the 80%-95% band keeps shrinking old images/tool results.
    public let compactionAlreadyJudged: Bool
    /// History projection followed by media projection, WITHOUT the reduction
    /// stage. The loop estimates occupancy on this view (what would actually
    /// be delivered), not on its raw messages. Runs inside the loop's execution
    /// context, like the App's delivery projection. nil = messages are delivered as is.
    public let deliveryProjection: (@Sendable ([LLMMessage]) throws -> [LLMMessage])?

    /// nil when the window is not positive or the trigger is not in (0, 1].
    public init?(
        windowTokens: Int,
        triggerFraction: Double,
        initialAnchor: ContextWindowPolicy.Anchor? = nil,
        reduction: ContextReductionState = ContextReductionState(),
        compactionAlreadyJudged: Bool = false,
        deliveryProjection: (@Sendable ([LLMMessage]) throws -> [LLMMessage])? = nil
    ) {
        guard windowTokens > 0, triggerFraction > 0, triggerFraction <= 1 else { return nil }
        self.windowTokens = windowTokens
        self.triggerFraction = triggerFraction
        self.initialAnchor = initialAnchor
        self.reduction = reduction
        self.compactionAlreadyJudged = compactionAlreadyJudged
        self.deliveryProjection = deliveryProjection
    }
}

/// Mutable per-run state of the admission, owned by one `AgentLoop` run.
struct ContextAdmissionRun {
    let config: ContextAdmissionConfig
    var anchor: ContextWindowPolicy.Anchor?
    /// Savings of the reduced view at the time the anchor was taken: the anchor
    /// already excludes them.
    var anchorSavings = 0
    var compactionJudged = false
    var compactionsPerformed = 0
    var overflowRecoveriesInRun = 0
    var overflowRecoveriesInIteration = 0

    static let maximumCompactionsPerRun = 2
    static let maximumOverflowRecoveriesPerRun = 2
    static let maximumOverflowRecoveriesPerIteration = 1

    init(config: ContextAdmissionConfig) {
        self.config = config
        self.anchor = config.initialAnchor
        self.compactionJudged = config.compactionAlreadyJudged
    }

    /// Messages as the Provider would receive them before the reduction stage.
    func projected(_ messages: [LLMMessage]) throws -> [LLMMessage] {
        try config.deliveryProjection?(messages) ?? messages
    }

    /// Messages as the Provider would receive them, reduction included.
    func requestView(_ messages: [LLMMessage]) throws -> [LLMMessage] {
        config.reduction.apply(try projected(messages))
    }

    /// Tokens the reduced view saves relative to `messages` (local estimate).
    func savings(of messages: [LLMMessage]) -> Int {
        let outcome = config.reduction.reducedView(of: messages)
        guard outcome.changedAnything,
              let before = AgentContextTokenBudget.estimatedMessagesCost(messages),
              let after = AgentContextTokenBudget.estimatedMessagesCost(outcome.messages) else { return 0 }
        return max(0, before - after)
    }

    /// Occupancy of the request the loop would deliver now, activating the
    /// reduction once the unreduced occupancy reaches the trigger.
    mutating func decide(messages: [LLMMessage], systemPrompt: String) throws -> ContextWindowPolicy.Decision {
        let view = try projected(messages)
        // An anchor counts positions in the loop's own messages and only adds
        // what follows them; without a usable anchor the projected view is estimated.
        let anchored = anchor.flatMap { messages.count >= $0.sentMessageCount ? $0 : nil }
        let base = ContextWindowPolicy.estimateInput(
            messages: anchored == nil ? view : messages, systemPrompt: systemPrompt, anchor: anchored) ?? Int.max
        let trigger = min(config.triggerFraction, ContextWindowPolicy.hardBlockFraction)
        var occupancy = base
        if config.reduction.isActive || Double(base) / Double(config.windowTokens) >= trigger {
            config.reduction.activate()
            occupancy = base - max(0, savings(of: view) - anchorSavings)
        }
        let decision = ContextWindowPolicy.decide(
            occupancyTokens: occupancy, windowTokens: config.windowTokens,
            threshold: config.triggerFraction,
            compactionAlreadyJudgedForThisTranscript: compactionJudged)
        if case .proceed = decision, !config.compactionAlreadyJudged { compactionJudged = false }
        return decision
    }

    /// The transcript was replaced (compaction): earlier figures are void.
    mutating func transcriptReplaced() {
        anchor = nil
        anchorSavings = 0
    }

    /// Record the figures of a request that was just answered.
    mutating func recordResponse(sentMessages: [LLMMessage], usage: LLMUsage?) throws {
        guard let usage else {
            transcriptReplaced()
            return
        }
        anchor = ContextWindowPolicy.Anchor(
            sentMessageCount: sentMessages.count,
            reportedTotalInput: usage.totalInputTokens,
            reportedOutput: usage.outputTokens)
        anchorSavings = config.reduction.isActive ? savings(of: try projected(sentMessages)) : 0
    }
}
