import Foundation

// MARK: - Hook Decision Reducer (P3-HOOK-01)

// Deterministic merge of the Policy / Approval / Stop / Timeout / Hook layers.
//
// Canonical 总表 P3-HOOK-01 (行 284): "Policy、Approval、Stop、Timeout 和 Hook
// 结果确定性合并 … 固定 `deny > ask > allow`；`continue=false` sticky；
// handler invocation/result 同 identity；后层不可重新放开 deny".
//
// This file provides the single pure-function, replayable decision reducer.
// The tool executor supplies frozen, real call signals; nothing here mutates
// shared state, performs I/O, or depends on time or task ordering.

/// Outcome of the merged decision. Raw-order is NOT the precedence; the
/// reducer applies the fixed `deny > ask > allow` precedence internally.
public enum HookDecisionOutcome: String, Codable, Sendable, Equatable {
    case deny
    case ask
    case allow
}

/// Single deterministic reason for the produced outcome.
public enum HookDecisionReason: String, Codable, Sendable, Equatable {
    /// A required layer input was absent — fail closed.
    case missingLayerInputFailClosed
    case policyDeny
    case approvalDeny
    /// Stop layer reported `continue=false`; sticky, later layers cannot re-open.
    case stopContinueFalse
    /// Timeout layer reported the deadline as expired.
    case timeoutExpired
    /// Hook handler invocation and result identities do not match.
    case hookHandlerIdentityMismatch
    case hookDeny
    case policyAsk
    case approvalAsk
    case hookAsk
    /// Every layer input was present and concurred on `allow`.
    case allLayersConcur
}

/// Per-layer verdict accepted by the reducer.
public enum HookLayerVerdict: String, Codable, Sendable, Equatable {
    case deny
    case ask
    case allow
}

/// Policy layer input signal.
public struct PolicyLayerSignal: Codable, Sendable, Equatable {
    public let verdict: HookLayerVerdict

    public init(verdict: HookLayerVerdict) {
        self.verdict = verdict
    }
}

/// Approval layer input signal (projection of an ApprovalGate result).
public struct ApprovalLayerSignal: Codable, Sendable, Equatable {
    public let verdict: HookLayerVerdict

    public init(verdict: HookLayerVerdict) {
        self.verdict = verdict
    }
}

/// Stop layer input signal. `continueRequested == false` is sticky: no
/// allow from any other layer can re-open it inside this reducer.
public struct StopLayerSignal: Codable, Sendable, Equatable {
    public let continueRequested: Bool

    public init(continueRequested: Bool) {
        self.continueRequested = continueRequested
    }
}

/// Timeout layer input signal.
public struct TimeoutLayerSignal: Codable, Sendable, Equatable {
    public let expired: Bool

    public init(expired: Bool) {
        self.expired = expired
    }
}

/// Hook layer input signal. The handler result is only honored when the
/// invocation identity and the result identity are the same identity.
public struct HookLayerSignal: Codable, Sendable, Equatable {
    public let verdict: HookLayerVerdict
    public let handlerInvocationID: String?
    public let handlerResultID: String?

    /// An ordinary call with no registered handler has a real, neutral layer.
    /// No invocation or result identity is fabricated for that case.
    public static let noHandler = HookLayerSignal(
        verdict: .allow,
        handlerInvocationID: nil,
        handlerResultID: nil
    )

    public init(
        verdict: HookLayerVerdict,
        handlerInvocationID: String,
        handlerResultID: String
    ) {
        self.verdict = verdict
        self.handlerInvocationID = handlerInvocationID
        self.handlerResultID = handlerResultID
    }

    private init(
        verdict: HookLayerVerdict,
        handlerInvocationID: String?,
        handlerResultID: String?
    ) {
        self.verdict = verdict
        self.handlerInvocationID = handlerInvocationID
        self.handlerResultID = handlerResultID
    }
}

/// Full input snapshot for one replayable decision. All five layers are
/// required; a missing layer fails closed to `deny`.
public struct HookDecisionInput: Codable, Sendable, Equatable {
    public let policy: PolicyLayerSignal?
    public let approval: ApprovalLayerSignal?
    public let stop: StopLayerSignal?
    public let timeout: TimeoutLayerSignal?
    public let hook: HookLayerSignal?

    public init(
        policy: PolicyLayerSignal?,
        approval: ApprovalLayerSignal?,
        stop: StopLayerSignal?,
        timeout: TimeoutLayerSignal?,
        hook: HookLayerSignal?
    ) {
        self.policy = policy
        self.approval = approval
        self.stop = stop
        self.timeout = timeout
        self.hook = hook
    }

    /// True when any required layer input is absent.
    public var hasMissingLayer: Bool {
        policy == nil || approval == nil || stop == nil || timeout == nil || hook == nil
    }
}

/// Deterministic merged decision produced by the reducer.
public struct HookDecision: Codable, Sendable, Equatable {
    public let outcome: HookDecisionOutcome
    public let reason: HookDecisionReason

    /// A deny produced here is terminal for this input snapshot: replaying
    /// the same input always reproduces the same deny, and no layer allow
    /// can lift it.
    public let isTerminalDeny: Bool

    init(outcome: HookDecisionOutcome, reason: HookDecisionReason) {
        self.outcome = outcome
        self.reason = reason
        self.isTerminalDeny = outcome == .deny
    }
}

/// Single pure-function reducer merging Policy / Approval / Stop / Timeout /
/// Hook outcomes into one replayable decision under the fixed
/// `deny > ask > allow` precedence.
public enum HookDecisionReducer {
    /// Merge the layered inputs into exactly one decision.
    ///
    /// Evaluation contract (canonical P3-HOOK-01):
    /// 1. Missing layer input → `deny` (fail closed).
    /// 2. Fixed precedence: a deny from ANY layer wins over ask/allow from
    ///    every other layer — later layers can never re-open a deny.
    /// 3. `stop.continueRequested == false` is a sticky deny.
    /// 4. `timeout.expired == true` is a deny.
    /// 5. A hook whose invocation identity != result identity is a deny
    ///    (`hookHandlerIdentityMismatch`); its verdict is not honored.
    /// 6. With no deny present, an ask from ANY layer wins over allow.
    /// 7. Otherwise all layers concurred → allow.
    ///
    /// Layer scan order for reason selection is fixed
    /// (policy → approval → stop → timeout → hook), so replays are stable.
    public static func decide(_ input: HookDecisionInput) -> HookDecision {
        // 1. Fail closed on any missing layer.
        if input.hasMissingLayer {
            return HookDecision(outcome: .deny, reason: .missingLayerInputFailClosed)
        }

        // Inputs are known non-nil beyond this point; force-unwrapping is
        // confined to this function and driven only by the check above.
        let policy = input.policy!
        let approval = input.approval!
        let stop = input.stop!
        let timeout = input.timeout!
        let hook = input.hook!

        // 2.-5. Deny sweep in fixed layer order (deny > ask > allow).
        if policy.verdict == .deny {
            return HookDecision(outcome: .deny, reason: .policyDeny)
        }
        if approval.verdict == .deny {
            return HookDecision(outcome: .deny, reason: .approvalDeny)
        }
        if !stop.continueRequested {
            return HookDecision(outcome: .deny, reason: .stopContinueFalse)
        }
        if timeout.expired {
            return HookDecision(outcome: .deny, reason: .timeoutExpired)
        }
        if hook.handlerInvocationID != hook.handlerResultID
            || hook.handlerInvocationID == "" {
            return HookDecision(outcome: .deny, reason: .hookHandlerIdentityMismatch)
        }
        if hook.verdict == .deny {
            return HookDecision(outcome: .deny, reason: .hookDeny)
        }

        // 6. Ask sweep in the same fixed layer order.
        if policy.verdict == .ask {
            return HookDecision(outcome: .ask, reason: .policyAsk)
        }
        if approval.verdict == .ask {
            return HookDecision(outcome: .ask, reason: .approvalAsk)
        }
        if hook.verdict == .ask {
            return HookDecision(outcome: .ask, reason: .hookAsk)
        }

        // 7. Every layer present and allowing.
        return HookDecision(outcome: .allow, reason: .allLayersConcur)
    }
}
