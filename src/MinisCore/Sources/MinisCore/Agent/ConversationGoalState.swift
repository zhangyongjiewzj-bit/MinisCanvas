import Foundation
import OSLog

/// Persistable facts for one user-requested conversation goal.
public struct ConversationGoalState: Codable, Hashable, Sendable {
    private static let log = Logger(subsystem: "com.miniscanvas.core", category: "ConversationGoalState")

    private struct RestoredBlocker: Decodable {
        let value: ConversationGoalBlocker?

        init(from decoder: Decoder) throws {
            value = try? ConversationGoalBlocker(from: decoder)
        }
    }

    public enum Status: String, Codable, Sendable {
        case active, awaitingReview, blocked, paused, stopped, completed
    }

    public enum BudgetDimension: String, Codable, Sendable {
        case turns, tokens, duration
    }

    public struct Budget: Codable, Hashable, Sendable {
        public let turnLimit: Int
        public let tokenLimit: Int?
        public let durationLimitSeconds: Double?
        public fileprivate(set) var usedTurns = 0
        public fileprivate(set) var usedTokens = 0
        public fileprivate(set) var usedDurationSeconds: Double = 0

        public init?(turnLimit: Int = 30, tokenLimit: Int? = nil, durationLimitSeconds: Double? = nil) {
            self.turnLimit = turnLimit
            self.tokenLimit = tokenLimit
            self.durationLimitSeconds = durationLimitSeconds
            guard isValid else { return nil }
        }

        fileprivate static let defaults = Budget()!

        fileprivate var isValid: Bool {
            turnLimit > 0 && (tokenLimit ?? 1) > 0
                && (durationLimitSeconds ?? 1).isFinite && (durationLimitSeconds ?? 1) > 0
                && usedTurns >= 0 && usedTokens >= 0 && usedDurationSeconds.isFinite && usedDurationSeconds >= 0
        }

        fileprivate var exhaustedDimension: BudgetDimension? {
            if usedTurns >= turnLimit { return .turns }
            if let tokenLimit, usedTokens >= tokenLimit { return .tokens }
            if let durationLimitSeconds, usedDurationSeconds >= durationLimitSeconds { return .duration }
            return nil
        }
    }

    public enum TurnOutcome: Equatable, Sendable {
        case completed, retryableNetwork, retryableRateLimit, nonRetryable
    }

    public let sessionID: UUID
    public let id: UUID
    public let objective: String
    public private(set) var status: Status = .active
    public private(set) var evidence: [String] = []
    public private(set) var blockedReason: String?
    public struct ReviewRecord: Codable, Hashable, Sendable {
        public enum Outcome: String, Codable, Sendable {
            case passed, rejected, invalidResponse, unavailable, cancelled, timedOut
        }

        public let outcome: Outcome
        public let provider: String?
        public let modelID: String?
        public let reason: String?
        public let turnsAtReview: Int?

        public init(outcome: Outcome, provider: String? = nil, modelID: String? = nil, reason: String? = nil, turnsAtReview: Int? = nil) {
            self.outcome = outcome
            self.provider = Self.safeIdentifier(provider)
            self.modelID = Self.safeIdentifier(modelID)
            self.turnsAtReview = turnsAtReview.flatMap { $0 >= 0 ? $0 : nil }
            self.reason = outcome == .rejected ? Self.safeReason(reason) : nil
        }

        public init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            self.init(outcome: try fields.decode(Outcome.self, forKey: .outcome),
                      provider: try fields.decodeIfPresent(String.self, forKey: .provider),
                      modelID: try fields.decodeIfPresent(String.self, forKey: .modelID),
                      reason: try? fields.decodeIfPresent(String.self, forKey: .reason),
                      turnsAtReview: try? fields.decodeIfPresent(Int.self, forKey: .turnsAtReview))
        }

        private static func safeReason(_ value: String?) -> String? {
            guard let value else { return nil }
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !text.unicodeScalars.contains(where: {
                [.control, .format, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory)
            }) else { return nil }
            return ProductRedactionPolicy.redact(text, maxLength: 300)
        }

        private static func safeIdentifier(_ value: String?) -> String? {
            guard let value, !value.isEmpty, value.utf8.count <= 128,
                  value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                      || (97...122).contains($0) || [45, 46, 95].contains($0) }) else { return nil }
            return value
        }
    }

    public private(set) var lastReview: ReviewRecord?

    public var reviewNeedsAttention: Bool {
        guard status == .active, let review = lastReview, review.turnsAtReview == budget.usedTurns else { return false }
        switch review.outcome {
        case .invalidResponse, .unavailable, .timedOut, .cancelled: return true
        case .rejected: return !autoContinueEnabled
        case .passed: return false
        }
    }
    public private(set) var reviewID: UUID?
    public private(set) var budget: Budget = .defaults
    public enum TurnPauseReason: String, Codable, Sendable {
        /// `emptyTurn`: an automatic continuation turn finished without any tool call.
        /// `approvalDenied`: the user denied or revoked an approval in a continuation turn.
        case cancelled, unsettledFailure, emptyTurn, approvalDenied
    }

    public private(set) var turnPauseReason: TurnPauseReason?
    public private(set) var budgetPauseReason: BudgetDimension?
    public private(set) var isPausedForSessionTokenLimit: Bool?
    public private(set) var budgetWasReset = false

    public var budgetRecoveryReason: String? {
        budgetWasReset ? "预算记录异常，已重置" : nil
    }
    public private(set) var consecutiveRetryableFailures = 0
    public private(set) var blockers: [ConversationGoalBlocker] = []
    public private(set) var allRemainingWorkBlocked = false
    /// Whether a normally completed goal turn may start the next turn by itself.
    /// On by default; records written before this field existed decode as on.
    public private(set) var autoContinueEnabled = true
    private var reminder: ConversationGoalReminder?

    /// The only goal state from which an automatic continuation may be started.
    public var allowsAutoContinuation: Bool {
        status == .active && autoContinueEnabled && budget.exhaustedDimension == nil
    }

    public var hasUnacknowledgedBlockerReminder: Bool {
        reminderDueAt != nil && reminder?.isAwaitingAcknowledgment == true
    }

    public var reminderDueAt: Date? {
        guard !blockers.isEmpty, status != .stopped, status != .completed else { return nil }
        return reminder?.dueAt
    }

    public init?(sessionID: UUID, id: UUID = UUID(), objective: String) {
        let text = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        self.sessionID = sessionID
        self.id = id
        self.objective = text
    }

    public static func reopen(_ data: Data, for sessionID: UUID) throws -> Self {
        let goal = try JSONDecoder().decode(Self.self, from: data)
        guard goal.sessionID == sessionID else { throw RestoreError.foreignSession }
        return goal
    }

    public enum RestoreError: Error {
        case foreignSession
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try fields.decode(UUID.self, forKey: .sessionID)
        id = try fields.decode(UUID.self, forKey: .id)
        objective = try fields.decode(String.self, forKey: .objective)
        status = try fields.decode(Status.self, forKey: .status)
        evidence = try fields.decode([String].self, forKey: .evidence)
        blockedReason = try fields.decodeIfPresent(String.self, forKey: .blockedReason)
        reviewID = try fields.decodeIfPresent(UUID.self, forKey: .reviewID)
        lastReview = try fields.decodeIfPresent(ReviewRecord.self, forKey: .lastReview)
        budgetWasReset = (try? fields.decode(Bool.self, forKey: .budgetWasReset)) ?? false
        if fields.contains(.budget) {
            if let saved = try? fields.decode(Budget.self, forKey: .budget), saved.isValid {
                budget = saved
            } else {
                budgetWasReset = true
                Self.log.warning("Invalid persisted goal budget reset")
            }
        }
        if let savedReason = try? fields.decode(BudgetDimension.self, forKey: .budgetPauseReason),
           status == .paused, savedReason == budget.exhaustedDimension {
            budgetPauseReason = savedReason
        }
        if status == .paused, (try? fields.decode(Bool.self, forKey: .isPausedForSessionTokenLimit)) == true {
            isPausedForSessionTokenLimit = true
        }
        if status == .paused {
            turnPauseReason = try? fields.decode(TurnPauseReason.self, forKey: .turnPauseReason)
        }
        let failures = (try? fields.decode(Int.self, forKey: .consecutiveRetryableFailures)) ?? 0
        consecutiveRetryableFailures = min(max(failures, 0), 3)
        if fields.contains(.blockers) {
            let saved = try? fields.decode([RestoredBlocker].self, forKey: .blockers)
            blockers = saved?.compactMap(\.value) ?? []
            if saved?.count != blockers.count {
                Self.log.warning("Invalid persisted goal blocker records ignored")
            }
        }
        allRemainingWorkBlocked = status == .blocked && !blockers.isEmpty
            && ((try? fields.decode(Bool.self, forKey: .allRemainingWorkBlocked)) ?? false)
        autoContinueEnabled = (try? fields.decode(Bool.self, forKey: .autoContinueEnabled)) ?? true
        if !blockers.isEmpty, status != .stopped, status != .completed {
            reminder = try? fields.decode(ConversationGoalReminder.self, forKey: .reminder)
        }
        let validEvidence = evidence.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let validStatus = switch status {
        case .active, .paused, .stopped: evidence.isEmpty && blockedReason == nil && reviewID == nil
        case .blocked: evidence.isEmpty && reviewID == nil
            && blockedReason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        case .awaitingReview: !evidence.isEmpty && blockedReason == nil && reviewID != nil
        case .completed: !evidence.isEmpty && blockedReason == nil && reviewID == nil
        }
        guard !objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, validEvidence, validStatus else {
            throw DecodingError.dataCorruptedError(forKey: .status, in: fields,
                                                   debugDescription: "Invalid persisted goal state")
        }
        if budgetWasReset, status == .active { status = .paused }
    }

    public mutating func pause() -> Bool {
        guard status == .active || status == .awaitingReview else { return false }
        evidence = []
        reviewID = nil
        status = .paused
        return true
    }

    mutating func pauseForInterruptedTurn(_ reason: TurnPauseReason) -> Bool {
        guard status == .active || status == .awaitingReview || status == .blocked else { return false }
        if status == .blocked {
            blockedReason = nil
            allRemainingWorkBlocked = false
            status = .active
        }
        guard pause() else { return false }
        if let exhausted = budget.exhaustedDimension {
            budgetPauseReason = exhausted
        } else {
            turnPauseReason = reason
        }
        return true
    }

    mutating func pauseForSessionTokenLimit() -> Bool {
        guard status == .active, pause() else { return false }
        isPausedForSessionTokenLimit = true
        return true
    }

    /// Turns automatic continuation on or off without changing the goal status.
    @discardableResult
    public mutating func setAutoContinue(_ enabled: Bool) -> Bool {
        guard status != .stopped, status != .completed, autoContinueEnabled != enabled else { return false }
        autoContinueEnabled = enabled
        return true
    }

    public mutating func resume() -> Bool {
        guard (status == .paused || status == .blocked), budget.exhaustedDimension == nil else { return false }
        consecutiveRetryableFailures = 0
        budgetPauseReason = nil
        isPausedForSessionTokenLimit = nil
        turnPauseReason = nil
        budgetWasReset = false
        blockedReason = nil
        allRemainingWorkBlocked = false
        status = .active
        return true
    }

    public mutating func stop() -> Bool {
        guard status != .stopped, status != .completed else { return false }
        evidence = []
        blockedReason = nil
        allRemainingWorkBlocked = false
        budgetPauseReason = nil
        isPausedForSessionTokenLimit = nil
        turnPauseReason = nil
        reviewID = nil
        reminder = nil
        status = .stopped
        return true
    }

    @discardableResult
    public mutating func reportCompletion(evidence: [String]) -> UUID? {
        let facts = evidence.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard status == .active, !facts.isEmpty, facts.allSatisfy({ !$0.isEmpty }) else { return nil }
        let reviewID = UUID()
        self.reviewID = reviewID
        self.evidence = facts
        status = .awaitingReview
        return reviewID
    }

    @discardableResult
    public mutating func recordReview(id: UUID, accepted: Bool) -> Bool {
        recordReview(id: id, result: .init(outcome: accepted ? .passed : .rejected))
    }

    public mutating func recordReview(id: UUID, result: ReviewRecord, usage: LLMUsage? = nil) -> Bool {
        guard status == .awaitingReview, reviewID == id else { return false }
        reviewID = nil
        lastReview = .init(outcome: result.outcome, provider: result.provider, modelID: result.modelID,
                           reason: result.reason, turnsAtReview: budget.usedTurns)
        if let usage, usage.totalInputTokens >= 0, usage.outputTokens >= 0 {
            budget.usedTokens = Self.sumClamped(
                budget.usedTokens, Self.sumClamped(usage.totalInputTokens, usage.outputTokens)
            )
        }
        if result.outcome == .passed {
            status = .completed
            reminder = nil
            consecutiveRetryableFailures = 0
        } else {
            status = budgetWasReset ? .paused : .active
            evidence = []
            consecutiveRetryableFailures = min(consecutiveRetryableFailures + 1, 3)
            pauseIfBudgetExhausted()
        }
        return true
    }

    /// Changes ceilings while retaining all measured usage.
    mutating func setBudgetLimits(turns: Int, tokens: Int?, durationSeconds: Double?) -> Bool {
        guard status == .paused || status == .active || status == .blocked,
              var revised = Budget(turnLimit: turns, tokenLimit: tokens, durationLimitSeconds: durationSeconds)
        else { return false }
        revised.usedTurns = budget.usedTurns
        revised.usedTokens = budget.usedTokens
        revised.usedDurationSeconds = budget.usedDurationSeconds
        budget = revised
        if status == .paused { budgetPauseReason = budget.exhaustedDimension }
        pauseIfBudgetExhausted()
        return true
    }

    mutating func recordInterruptedTurn(
        durationSeconds: Double, reportedTokens: Int?, outcome: TurnOutcome
    ) -> Bool {
        guard outcome != .completed else { return false }
        if status == .awaitingReview {
            evidence = []
            reviewID = nil
            status = .active
        }
        guard recordTurn(durationSeconds: durationSeconds, reportedTokens: reportedTokens, outcome: outcome)
        else { return false }
        if status != .paused { _ = pauseForInterruptedTurn(.unsettledFailure) }
        return true
    }

    mutating func recordTurn(durationSeconds: Double, reportedTokens: Int?, outcome: TurnOutcome) -> Bool {
        guard status == .active || (status == .awaitingReview && outcome == .completed),
              durationSeconds.isFinite, durationSeconds >= 0, (reportedTokens ?? 0) >= 0 else { return false }
        budget.usedTurns = Self.sumClamped(budget.usedTurns, 1)
        if let reportedTokens {
            budget.usedTokens = Self.sumClamped(budget.usedTokens, reportedTokens)
        }
        budget.usedDurationSeconds = min(budget.usedDurationSeconds + durationSeconds, .greatestFiniteMagnitude)

        switch outcome {
        case .completed:
            consecutiveRetryableFailures = 0
        case .retryableNetwork, .retryableRateLimit:
            consecutiveRetryableFailures = min(consecutiveRetryableFailures + 1, 3)
            if consecutiveRetryableFailures == 3 {
                let reason = outcome == .retryableNetwork ? "连续三次回合失败，最近一次为网络错误" : "连续三次回合失败，最近一次为限流"
                _ = reportBlocked(reason: reason)
            }
        case .nonRetryable:
            consecutiveRetryableFailures = 0
            _ = reportBlocked(reason: "目标回合遇到不可重试错误")
        }
        pauseIfBudgetExhausted()
        return true
    }

    private static func sumClamped(_ current: Int, _ additional: Int) -> Int {
        let (sum, overflow) = current.addingReportingOverflow(additional)
        return overflow ? .max : sum
    }

    private mutating func pauseIfBudgetExhausted() {
        guard status == .active, let reason = budget.exhaustedDimension else { return }
        status = .paused
        budgetPauseReason = reason
    }

    @discardableResult
    public mutating func recordBlocker(_ blocker: ConversationGoalBlocker, now: Date = Date()) -> Bool {
        guard status == .active else { return false }
        if !blockers.contains(blocker) {
            blockers.append(blocker)
            reminder = ConversationGoalReminder(startingAt: now, immediate: true)
        }
        return true
    }

    /// 用户确认已处理待办：清空待办与提醒，不改目标状态。
    @discardableResult
    public mutating func clearBlockers() -> Bool {
        guard !blockers.isEmpty, status != .stopped, status != .completed else { return false }
        blockers = []
        reminder = nil
        allRemainingWorkBlocked = false
        return true
    }

    @discardableResult
    public mutating func resetBlockerReminder(now: Date) -> Bool {
        guard !blockers.isEmpty, status != .stopped, status != .completed else { return false }
        reminder = ConversationGoalReminder(startingAt: now)
        return true
    }

    @discardableResult
    public mutating func consumeBlockerReminder(now: Date) -> Bool {
        guard reminderDueAt != nil, let next = reminder?.consuming(at: now) else { return false }
        reminder = next
        return true
    }

    @discardableResult
    public mutating func reportBlocked(reason: String, allRemainingWorkBlocked: Bool = false) -> Bool {
        let text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard status == .active, !text.isEmpty, !allRemainingWorkBlocked || !blockers.isEmpty else { return false }
        self.allRemainingWorkBlocked = allRemainingWorkBlocked
        blockedReason = text
        status = .blocked
        return true
    }
}


public extension ComposerTaskMode {
    /// Goal tools, goal measurement and automatic continuation are available in
    /// every mode that may execute tools; plan-only turns never drive a goal.
    var supportsConversationGoal: Bool { self != .plan }
}
