import Foundation

// MARK: - Side-effect classification (D-BROWSER-07 single source of truth)

/// Canonical classification of browser tool actions into read operations and
/// side effects.  Read operations (navigate/back/read/screenshot) stay
/// serviceable by the default read-only session; every side effect listed by
/// `P3-BROWSER-01 / BROWSER-07` — click, type, download, upload, and any
/// future mutating action — must pass an explicit Policy/Approval decision
/// before it may touch the page.
///
/// Unknown action names fail closed into the side-effect set: adding a new
/// browser capability without classifying it cannot silently become a
/// read-path action.
public enum BrowserSideEffectPolicy {
    /// Tool names the browser capability answers to.
    public static let browserToolNames: Set<String> = ["browser", "browser_use"]

    /// Actions that mutate page state or move data out of the page context.
    /// Download and upload also require the existing file read/write policy,
    /// exact file identity and a fresh action-specific human approval.
    public static let sideEffectActions: Set<String> = [
        "click", "type", "download", "upload",
    ]

    /// Actions explicitly proven read-only. Anything not listed here and not
    /// a known read action is treated as a side effect.
    public static let readActions: Set<String> = [
        "navigate", "back", "read", "screenshot",
    ]

    /// Whether one action requires an explicit Policy/Approval decision.
    public static func requiresApproval(action: String) -> Bool {
        !readActions.contains(action)
    }

    /// Whether a concrete tool call (tool name + raw input) is a browser side
    /// effect.  Non-browser tools and inputs without a classifiable `action`
    /// string return false so this stays safe to call from the generic
    /// approval-risk classifier.
    public static func inputRequiresApproval(tool: String, input: [String: Any]) -> Bool {
        guard browserToolNames.contains(tool.lowercased()) else { return false }
        guard let action = input["action"] as? String else { return false }
        return requiresApproval(action: action)
    }
}

// MARK: - Approval-bound one-shot write grant

/// Execution identity comes from the AgentLoop or Composer wrapper, never
/// from browser tool input. Task-local propagation keeps the existing tool
/// executor decorators and timeout child task on the same approved call.
public struct BrowserSideEffectExecutionIdentity: Equatable, Sendable {
    public let callID: String
    public let inputDigest: String

    public init(callID: String, inputDigest: String) {
        self.callID = callID
        self.inputDigest = inputDigest
    }

    public var isValid: Bool { !callID.isEmpty && !inputDigest.isEmpty }
}

public enum BrowserSideEffectCallContext {
    @TaskLocal public static var current: BrowserSideEffectExecutionIdentity?
    @TaskLocal static var executionObservation: BrowserAutomaticExecutionCapture?
}

/// One-shot capability produced from an approved `ApprovalReceipt` or a
/// confirmed Composer bypass policy decision and bound to one browser scope
/// and action. It is deliberately weaker than
/// `BrowserWriteAuthorization`: it never persists, authorizes exactly one
/// matching action, expires on a short wall-clock window, and is destroyed
/// when the owning session closes.
public struct BrowserSideEffectGrant: Equatable, Sendable {
    /// Approval request identity this grant was minted from. Replays of the
    /// same receipt cannot issue a second grant.
    public let grantID: String
    /// Scope bound at approval time; a grant for another scope is inert.
    public let scopeID: String
    public let action: String
    public let inputDigest: String
    public let issuedAt: Date
    public let expiresAt: Date

    public init(
        grantID: String,
        scopeID: String,
        action: String,
        inputDigest: String,
        issuedAt: Date,
        expiresAt: Date
    ) {
        self.grantID = grantID
        self.scopeID = scopeID
        self.action = action
        self.inputDigest = inputDigest
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }

    public func matches(action: String, scopeID: String, identity: BrowserSideEffectExecutionIdentity) -> Bool {
        self.action == action && self.scopeID == scopeID
            && grantID == identity.callID && inputDigest == identity.inputDigest
    }

    public func isValid(at now: Date) -> Bool {
        !grantID.isEmpty && !scopeID.isEmpty && issuedAt <= now && now < expiresAt
    }
}

/// Ledger of pending one-shot browser write grants, owned by one
/// `BrowserSession` (main-actor isolated together with its session).
///
/// The production approval gate may redeem a human approval receipt here;
/// a confirmed Composer bypass decision may also issue one call-bound grant.
/// Either way the executing action consumes it exactly once.
public final class BrowserSideEffectGrantLedger: @unchecked Sendable {
    /// Wall-clock protection window between an approved receipt and the
    /// execution it authorizes when the receipt itself carries no expiry.
    public static let defaultGrantLifetime: TimeInterval = 60

    private let lock = NSLock()
    private var pending: [BrowserSideEffectGrant] = []
    private var redeemedReceiptIDs: Set<String> = []
    private var invalidated = false

    public init() {}

    public var pendingGrantCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pending.count
    }

    /// Issue a one-shot grant bound to one approved receipt identity.
    /// - Returns `false` when the receipt was already redeemed, the identity
    ///   is empty, or the ledger was destroyed by `close()`.
    @discardableResult
    public func issue(from receipt: ApprovalReceipt, scopeID: String, action: String, now: Date = Date()) -> Bool {
        guard let inputDigest = receipt.inputDigest else { return false }
        return issue(
            grantID: receipt.requestID,
            scopeID: scopeID,
            action: action,
            inputDigest: inputDigest,
            issuedAt: now,
            expiresAt: Self.expiry(of: receipt, now: now)
        )
    }

    /// Core issuance used by the receipt hop and by deterministic tests.
    @discardableResult
    public func issue(
        grantID: String,
        scopeID: String,
        action: String,
        inputDigest: String,
        issuedAt: Date,
        expiresAt: Date
    ) -> Bool {
        let grant = BrowserSideEffectGrant(
            grantID: grantID, scopeID: scopeID, action: action,
            inputDigest: inputDigest,
            issuedAt: issuedAt, expiresAt: expiresAt
        )
        guard issuedAt < expiresAt else { return false }
        lock.lock(); defer { lock.unlock() }
        guard !invalidated, !grantID.isEmpty, !scopeID.isEmpty, !inputDigest.isEmpty else { return false }
        guard !redeemedReceiptIDs.contains(grantID) else { return false }
        redeemedReceiptIDs.insert(grantID)
        pending.append(grant)
        return true
    }

    /// Non-destructive check for a still-valid matching grant.  The consuming
    /// action still calls `consume`; this only lets callers produce a
    /// structured refusal before execution without burning the grant.
    public func hasValidGrant(
        action: String,
        scopeID: String,
        identity: BrowserSideEffectExecutionIdentity?,
        now: Date = Date()
    ) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !invalidated, let identity, identity.isValid else { return false }
        return pending.contains {
            $0.isValid(at: now) && $0.matches(action: action, scopeID: scopeID, identity: identity)
        }
    }

    /// Consume the oldest still-valid grant matching action+scope. The grant
    /// is removed before the action runs, so a failure of the action cannot
    /// be retried with the same approval, and a late second call cannot
    /// replay it.
    public func consume(
        action: String,
        scopeID: String,
        identity: BrowserSideEffectExecutionIdentity?,
        now: Date = Date()
    ) -> BrowserSideEffectGrant? {
        lock.lock(); defer { lock.unlock() }
        guard !invalidated, let identity, identity.isValid else { return nil }
        guard let index = pending.firstIndex(where: {
            $0.isValid(at: now) && $0.matches(action: action, scopeID: scopeID, identity: identity)
        }) else { return nil }
        return pending.remove(at: index)
    }

    /// Drop all unspent grants without affecting replay bookkeeping: a grant
    /// whose receipt was redeemed can never be re-issued even after this.
    public func revokeAllPending() {
        lock.lock(); defer { lock.unlock() }
        pending.removeAll()
    }

    /// Destroy the ledger for its owning session lifetime. After `close()`
    /// no redemption or consumption is possible, ever.
    public func invalidate() {
        lock.lock(); defer { lock.unlock() }
        pending.removeAll()
        invalidated = true
    }

    private static func expiry(of receipt: ApprovalReceipt, now: Date) -> Date {
        if let expiresAt = receipt.expiresAt {
            return min(expiresAt, now.addingTimeInterval(defaultGrantLifetime))
        }
        return now.addingTimeInterval(defaultGrantLifetime)
    }
}


/// Content-free observation bound to one real tool reservation and its consumed
/// browser grant. It is not authorization and never reads the tool result JSON.
struct BrowserAutomaticExecutionEvidence: Sendable {
    let receipt: ToolExecutionReceipt
    let identity: BrowserSideEffectExecutionIdentity
    let grant: BrowserSideEffectGrant
    let category: BrowserInteractionCategory
    let ruleID: UUID

    fileprivate init(receipt: ToolExecutionReceipt, identity: BrowserSideEffectExecutionIdentity,
                     grant: BrowserSideEffectGrant, category: BrowserInteractionCategory, ruleID: UUID) {
        self.receipt = receipt; self.identity = identity; self.grant = grant
        self.category = category; self.ruleID = ruleID
    }

    func category(matching expectedReceipt: ToolExecutionReceipt?, digest: String?,
                  action: String, scopeID: String) -> BrowserInteractionCategory? {
        guard expectedReceipt == receipt, digest == identity.inputDigest,
              receipt.toolCallID == identity.callID,
              receipt.compositeKey?.toolCallID == identity.callID,
              grant.matches(action: action, scopeID: scopeID, identity: identity),
              (category == .input && action == "type") || (category == .click && action == "click") else { return nil }
        return category
    }
}

final class BrowserAutomaticExecutionCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let receipt: ToolExecutionReceipt
    private let ledger: ToolExecutionFactLedger
    private let identity: BrowserSideEffectExecutionIdentity
    private var consumedGrant: BrowserSideEffectGrant?
    private var evidence: BrowserAutomaticExecutionEvidence?
    private var closed = false

    init?(receipt: ToolExecutionReceipt, ledger: ToolExecutionFactLedger,
          identity: BrowserSideEffectExecutionIdentity) {
        guard identity.isValid, ledger.hasDurableAuthority, ledger.pendingReceipts.contains(receipt),
              receipt.toolCallID == identity.callID, receipt.compositeKey?.toolCallID == identity.callID,
              receipt.compositeKey?.isValid == true, receipt.executionIdentity?.isValid == true,
              BrowserSideEffectPolicy.browserToolNames.contains(receipt.toolName.lowercased()) else { return nil }
        self.receipt = receipt; self.ledger = ledger; self.identity = identity
    }

    private func nativeScopeMatches() -> Bool {
        ToolExecutionReceiptContext.current == receipt && ToolExecutionReceiptContext.ledger === ledger
            && ledger.pendingReceipts.contains(receipt) && BrowserSideEffectCallContext.current == identity
    }

    func recordConsumedGrant(_ grant: BrowserSideEffectGrant) {
        guard nativeScopeMatches(), ["click", "type"].contains(grant.action),
              grant.matches(action: grant.action, scopeID: grant.scopeID, identity: identity) else { return }
        lock.withLock { if !closed && consumedGrant == nil { consumedGrant = grant } }
    }

    func recordSuccessfulRuleUse(category: BrowserInteractionCategory, ruleID: UUID,
                                 action: String, scopeID: String) {
        guard nativeScopeMatches(),
              (category == .input && action == "type") || (category == .click && action == "click") else { return }
        lock.withLock {
            guard !closed, evidence == nil, let grant = consumedGrant,
                  grant.matches(action: action, scopeID: scopeID, identity: identity) else { return }
            evidence = BrowserAutomaticExecutionEvidence(receipt: receipt, identity: identity,
                grant: grant, category: category, ruleID: ruleID)
        }
    }

    func takeAndFreeze() -> BrowserAutomaticExecutionEvidence? {
        lock.withLock {
            closed = true
            defer { evidence = nil; consumedGrant = nil }
            return evidence
        }
    }

    func discard() { _ = takeAndFreeze() }
}

// MARK: - Receipt → grant redemption (D-BROWSER-07 approval hop)

/// Maps an approved browser `ApprovalReceipt` onto the concrete session scope
/// so that an approved action can execute while a non-approved one cannot.
///
/// The redemption is defensive at every step:
/// - only `browser`/`browser_use` receipts are considered;
/// - only `status == .approved` receipts, never denied/expired/revoked/cancelled;
/// - only receipts whose redacted summary names a side-effect action;
/// - the grant is bound to the receiving session's own scope id, so a receipt
///   approved for one browser session can never unlock another.
public enum BrowserApprovalReceiptRedeemer {
    /// Extract the side-effect action an approved receipt authorized, or nil
    /// when the receipt is not a browser side-effect approval.
    ///
    /// `ApprovalGate.makeInputSummary` sorts keys alphabetically and never
    /// redacts `action`, so a browser call always begins with
    /// `"action: <value>"` (followed by `,` or the end of the digest).
    public static func authorizedSideEffectAction(of receipt: ApprovalReceipt) -> String? {
        guard receipt.status == .approved else { return nil }
        guard BrowserSideEffectPolicy.browserToolNames.contains(receipt.toolName.lowercased()) else { return nil }
        let prefix = "action: "
        let summary = receipt.inputSummary
        guard summary.hasPrefix(prefix) else { return nil }
        let tail = summary.dropFirst(prefix.count)
        let action = String(tail.prefix { $0 != "," && $0 != " " && $0 != "…" })
        // Transfer execution additionally requires exact file identity, an
        // action-specific human review and the existing file policy.
        guard ["click", "type", "download", "upload"].contains(action) else {
            return nil
        }
        return action
    }

    /// Redeem `receipt` into the ledger as a one-shot grant for `scopeID`.
    /// - Returns `true` when a grant was issued.
    @discardableResult
    public static func redeem(
        _ receipt: ApprovalReceipt,
        into ledger: BrowserSideEffectGrantLedger,
        scopeID: String,
        now: Date = Date()
    ) -> Bool {
        guard let action = authorizedSideEffectAction(of: receipt) else { return false }
        return ledger.issue(from: receipt, scopeID: scopeID, action: action, now: now)
    }
}
