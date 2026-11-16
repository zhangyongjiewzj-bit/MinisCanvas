import Foundation
import Testing
@testable import MinisCore

/// D-BROWSER-07 (P3-BROWSER-01 / BROWSER-07): read operations stay read-only
/// by default and page side effects (click/type/download/upload/cross-domain)
/// enter an explicit Policy/Approval path — the gate, not just prompt text.
///
/// D-BROWSER-08 companion: an approval grant must not survive session close,
/// must stay bound to its scope, and must never authorize a different action.
@Suite(.serialized)
struct BrowserSideEffectPolicyTests {

    // MARK: - Action classification

    @Test func sideEffectActionsRequireApprovalAndReadActionsDoNot() {
        for action in ["click", "type", "download", "upload"] {
            #expect(BrowserSideEffectPolicy.requiresApproval(action: action), "\(action) must require approval")
        }
        for action in ["navigate", "back", "read", "screenshot"] {
            #expect(!BrowserSideEffectPolicy.requiresApproval(action: action), "\(action) stays read-only")
        }
        // Unknown/future actions fail closed into the side-effect set.
        #expect(BrowserSideEffectPolicy.requiresApproval(action: "submit_form"))
        #expect(BrowserSideEffectPolicy.requiresApproval(action: ""))
    }

    @Test func inputClassificationOnlyEscalatesBrowserTools() {
        #expect(BrowserSideEffectPolicy.inputRequiresApproval(
            tool: "browser", input: ["action": "click", "selector": "#x"]))
        #expect(BrowserSideEffectPolicy.inputRequiresApproval(
            tool: "browser_use", input: ["action": "type"]))
        #expect(!BrowserSideEffectPolicy.inputRequiresApproval(
            tool: "browser", input: ["action": "read"]))
        #expect(!BrowserSideEffectPolicy.inputRequiresApproval(
            tool: "browser", input: ["url": "https://example.com"]))
        #expect(!BrowserSideEffectPolicy.inputRequiresApproval(
            tool: "file_write", input: ["action": "click"]))
    }

    // MARK: - ApprovalGate hop (real gate, not prompt text)

    private actor RecordingDelegate: ApprovalDelegate {
        let approved: Bool
        private var requests: [ApprovalRequest] = []
        init(approved: Bool) { self.approved = approved }
        var seen: [ApprovalRequest] { requests }
        func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
            requests.append(request)
            return ApprovalDecision(
                approved: approved,
                reason: approved ? "user approved" : "user denied",
                confirmed: approved,
                requestID: request.requestID,
                bindingDigest: request.identityDigest)
        }
    }

    @Test func browserSideEffectEscalatesEvenWhenToolPolicyAutoApproves() async throws {
        let delegate = RecordingDelegate(approved: true)
        let gate = ApprovalGate(policyByTool: ["browser": .autoApprove], delegate: delegate)
        // The pre-existing baseline: read calls never ask.
        #expect(!gate.shouldAsk(tool: "browser", input: ["action": "read", "url": "https://example.com"]))
        #expect(gate.shouldAsk(tool: "browser", input: ["action": "click", "selector": "#submit"]))
        #expect(gate.shouldAsk(tool: "browser_use", input: ["action": "type", "selector": "#q", "text": "hi"]))

        // The gate path AgentLoop actually uses before dispatch: escalation
        // must reach the human prompt even under an auto-approve tool policy.
        let decision = try await gate.gate(
            tool: "browser",
            input: ["action": "click", "selector": "#submit"],
            delegate: delegate)
        #expect(decision.approved)
        let request = (await delegate.seen).first { $0.toolName == "browser" }
        #expect(request?.requiresApproval == true)
        #expect(request?.riskLevel == .high)
    }

    private final class ReceiptBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [ApprovalReceipt] = []
        func append(_ receipt: ApprovalReceipt) { lock.lock(); stored.append(receipt); lock.unlock() }
        var all: [ApprovalReceipt] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    @Test func deniedSideEffectNeverReachesExecutorAndNoGrantIssued() async {
        let delegate = RecordingDelegate(approved: false)
        let receipts = ReceiptBox()
        var gate = ApprovalGate(policyByTool: ["browser": .autoApprove], delegate: delegate)
        gate.onApprovalReceipt = { receipts.append($0) }
        await #expect(throws: ApprovalError.denied(reason: "user denied")) {
            _ = try await gate.gate(
                tool: "browser",
                input: ["action": "click", "selector": "#submit"],
                delegate: delegate)
        }
        // A denial does not mint an approval fact that could be redeemed.
        #expect(receipts.all.filter {
            BrowserApprovalReceiptRedeemer.authorizedSideEffectAction(of: $0) != nil
        }.isEmpty)
    }

    @Test func gateWithoutDelegateFailsClosedOnSideEffect() async throws {
        let gate = ApprovalGate(policyByTool: ["browser": .autoApprove], delegate: nil)
        await #expect(throws: (any Error).self) {
            _ = try await gate.gate(tool: "browser", input: ["action": "click", "selector": "#x"])
        }
        // Read path is unaffected.
        _ = try await gate.gate(tool: "browser", input: ["action": "read"])
    }

    // MARK: - Grant ledger

    private func identity(_ callID: String, digest: String = "digest-1") -> BrowserSideEffectExecutionIdentity {
        BrowserSideEffectExecutionIdentity(callID: callID, inputDigest: digest)
    }

    @Test func grantIsScopeBoundActionBoundAndSingleUse() throws {
        let ledger = BrowserSideEffectGrantLedger()
        let now = Date()
        #expect(ledger.issue(grantID: "g1", scopeID: "scope-a", action: "click", inputDigest: "digest-1",
                             issuedAt: now, expiresAt: now.addingTimeInterval(30)))
        // Wrong action and wrong scope cannot consume.
        #expect(ledger.consume(action: "type", scopeID: "scope-a", identity: identity("g1"), now: now) == nil)
        #expect(ledger.consume(action: "click", scopeID: "scope-b", identity: identity("g1"), now: now) == nil)
        #expect(ledger.consume(action: "click", scopeID: "scope-a", identity: identity("other"), now: now) == nil)
        #expect(ledger.consume(action: "click", scopeID: "scope-a", identity: identity("g1", digest: "changed"), now: now) == nil)
        // Correct consumption works exactly once.
        #expect(ledger.consume(action: "click", scopeID: "scope-a", identity: identity("g1"), now: now) != nil)
        #expect(ledger.consume(action: "click", scopeID: "scope-a", identity: identity("g1"), now: now) == nil)
    }

    @Test func expiredGrantCannotConsume() throws {
        let ledger = BrowserSideEffectGrantLedger()
        let now = Date()
        #expect(ledger.issue(grantID: "g2", scopeID: "s", action: "click", inputDigest: "digest-1",
                             issuedAt: now, expiresAt: now.addingTimeInterval(5)))
        #expect(ledger.consume(action: "click", scopeID: "s", identity: identity("g2"), now: now.addingTimeInterval(6)) == nil)
        // The expired grant is spent: a redemption attempt inside the old
        // window after expiry must still fail.
        #expect(ledger.pendingGrantCount == 1)
        #expect(ledger.consume(action: "click", scopeID: "s", identity: identity("g2"), now: now.addingTimeInterval(3600)) == nil)
    }

    @Test func sameReceiptIdentityCannotBeIssuedTwice() throws {
        let ledger = BrowserSideEffectGrantLedger()
        let now = Date()
        let expiry = now.addingTimeInterval(30)
        #expect(ledger.issue(grantID: "dup", scopeID: "s", action: "click", inputDigest: "digest-1", issuedAt: now, expiresAt: expiry))
        #expect(!ledger.issue(grantID: "dup", scopeID: "s", action: "click", inputDigest: "digest-1", issuedAt: now, expiresAt: expiry))
        // Even after consuming, the identity cannot be re-redeemed.
        #expect(ledger.consume(action: "click", scopeID: "s", identity: identity("dup"), now: now) != nil)
        #expect(!ledger.issue(grantID: "dup", scopeID: "s", action: "click", inputDigest: "digest-1", issuedAt: now, expiresAt: expiry))
    }

    @Test func revokeAndInvalidateDestroyUnspentGrants() throws {
        let ledger = BrowserSideEffectGrantLedger()
        let now = Date()
        #expect(ledger.issue(grantID: "r1", scopeID: "s", action: "click", inputDigest: "digest-1",
                             issuedAt: now, expiresAt: now.addingTimeInterval(30)))
        ledger.revokeAllPending()
        #expect(ledger.consume(action: "click", scopeID: "s", identity: identity("r1"), now: now) == nil)
        #expect(ledger.issue(grantID: "r2", scopeID: "s", action: "click", inputDigest: "digest-1",
                             issuedAt: now, expiresAt: now.addingTimeInterval(30)))
        ledger.invalidate()
        #expect(ledger.consume(action: "click", scopeID: "s", identity: identity("r2"), now: now) == nil)
        #expect(!ledger.issue(grantID: "r3", scopeID: "s", action: "click", inputDigest: "digest-1",
                              issuedAt: now, expiresAt: now.addingTimeInterval(30)))
    }

    // MARK: - Receipt → grant redemption

    private func browserReceipt(
        requestID: String = "req-1",
        tool: String = "browser",
        status: ApprovalDecisionStatus = .approved,
        summary: String = "action: click, selector: #submit",
        inputDigest: String? = nil
    ) -> ApprovalReceipt {
        ApprovalReceipt(
            requestID: requestID, toolName: tool, policy: .autoApprove,
            riskLevel: .high, inputSummary: summary, status: status,
            inputDigest: inputDigest
                ?? (try! ComposerToolInput(["action": "click", "selector": "#submit"]).digest))
    }

    @Test func redeemerAcceptsOnlyApprovedBrowserSideEffectReceipts() {
        #expect(BrowserApprovalReceiptRedeemer.authorizedSideEffectAction(
            of: browserReceipt()) == "click")
        #expect(BrowserApprovalReceiptRedeemer.authorizedSideEffectAction(
            of: browserReceipt(tool: "browser_use", summary: "action: type, selector: #q")) == "type")
        #expect(BrowserApprovalReceiptRedeemer.authorizedSideEffectAction(
            of: browserReceipt(status: .denied)) == nil)
        #expect(BrowserApprovalReceiptRedeemer.authorizedSideEffectAction(
            of: browserReceipt(status: .expired)) == nil)
        #expect(BrowserApprovalReceiptRedeemer.authorizedSideEffectAction(
            of: browserReceipt(tool: "shell_execute")) == nil)
        #expect(BrowserApprovalReceiptRedeemer.authorizedSideEffectAction(
            of: browserReceipt(summary: "action: read, selector: body")) == nil)
        #expect(BrowserApprovalReceiptRedeemer.authorizedSideEffectAction(
            of: browserReceipt(summary: "url: https://x, action: click")) == nil)
    }

    @Test func redeemBindsGrantToReceivingSessionScope() throws {
        let ledger = BrowserSideEffectGrantLedger()
        let now = Date()
        #expect(BrowserApprovalReceiptRedeemer.redeem(
            browserReceipt(), into: ledger, scopeID: "target-scope", now: now))
        // A receipt approved for the browser capability unlocks only this scope.
        #expect(ledger.consume(action: "click", scopeID: "other-scope", identity: identity("req-1", digest: browserReceipt().inputDigest!), now: now) == nil)
        #expect(ledger.consume(action: "click", scopeID: "target-scope", identity: identity("req-1", digest: browserReceipt().inputDigest!), now: now) != nil)
    }

    // MARK: - Tool/session integration (real BrowserSession, no network)

    @MainActor
    private func makeTool(scopeID: String) -> BrowserTool {
        // These fixtures exercise an explicitly enabled, human-receipt path;
        // default-off behavior is covered by BrowserWriteDefaultOffTests.
        BrowserTool(session: BrowserSession(scopeID: scopeID, userAgent: nil), writeActionsEnabled: true)
    }

    @MainActor
    @Test func unapprovedClickIsRefusedStructurallyAndProducesNoSideEffect() async throws {
        let tool = makeTool(scopeID: "unapproved-click-scope")
        defer { tool.session.close() }
        let result = try await tool.execute(name: "browser", input: [
            "action": "click", "selector": "#submit",
        ])
        let response = try JSONDecoder().decode(BrowserToolResponse.self, from: Data(result.utf8))
        #expect(response.outcome == "denied")
        #expect(response.refusalReason == "write_authorization_required")
        #expect(response.scopeID == "unapproved-click-scope")
        // The refusal is a read-only WebKit untouched path: no page exists.
        #expect(tool.session.webView.url == nil)
    }

    @MainActor
    @Test func approvedReceiptGrantLetsExactlyOneClickRunAndCannotReplay() async throws {
        let tool = makeTool(scopeID: "approved-click-scope")
        defer { tool.session.close() }
        // Empty HTML page with the target element so a granted click runs the
        // real JS path rather than being refused.
        try await tool.session.loadHTMLString(
            "<html><body><button id=\"submit\">go</button></body></html>")
        #expect(tool.session.isReadOnly)

        // Before approval: structured refusal, element untouched.
        let before = try await tool.execute(name: "browser", input: [
            "action": "click", "selector": "#submit",
        ])
        #expect(before.contains("denied"))

        let approvedIdentity = identity(
            "grant-1", digest: try ComposerToolInput(["action": "click", "selector": "#submit"]).digest
        )
        let issued = tool.authorizeFromApprovalReceipt(browserReceipt(requestID: "grant-1"))
        #expect(issued)
        let otherCall = try await BrowserSideEffectCallContext.$current.withValue(
            identity("other-call", digest: approvedIdentity.inputDigest)
        ) {
            try await tool.execute(name: "browser", input: ["action": "click", "selector": "#submit"])
        }
        #expect(otherCall.contains("write_authorization_required"))
        let alteredInput = try await BrowserSideEffectCallContext.$current.withValue(approvedIdentity) {
            try await tool.execute(name: "browser", input: ["action": "click", "selector": "#other"])
        }
        #expect(alteredInput.contains("write_authorization_required"))
        #expect(tool.session.sideEffectGrants.pendingGrantCount == 1)
        let after = try await BrowserSideEffectCallContext.$current.withValue(approvedIdentity) {
            try await tool.execute(name: "browser", input: ["action": "click", "selector": "#submit"])
        }
        // The granted click executed the JS interaction path, not a refusal.
        #expect(!after.contains("denied"))
        #expect(after.contains("\"clicked\":true") || after.contains("clicked"))

        // The one-shot grant is consumed; a second click is refused again.
        let replay = try await BrowserSideEffectCallContext.$current.withValue(approvedIdentity) {
            try await tool.execute(name: "browser", input: ["action": "click", "selector": "#submit"])
        }
        let replayResponse = try JSONDecoder().decode(BrowserToolResponse.self, from: Data(replay.utf8))
        #expect(replayResponse.outcome == "denied")
    }

    @MainActor
    @Test func typeGrantCannotUnlockClickAndViceVersa() async throws {
        let tool = makeTool(scopeID: "action-binding-scope")
        defer { tool.session.close() }
        let typeInput: [String: Any] = ["action": "type", "selector": "#q", "text": "x"]
        let typeDigest = try ComposerToolInput(typeInput).digest
        #expect(tool.authorizeFromApprovalReceipt(
            browserReceipt(
                requestID: "type-only",
                summary: "action: type, selector: #q, text: x",
                inputDigest: typeDigest
            )))
        let click = try await tool.execute(name: "browser", input: [
            "action": "click", "selector": "#q",
        ])
        let clickResponse = try JSONDecoder().decode(BrowserToolResponse.self, from: Data(click.utf8))
        #expect(clickResponse.outcome == "denied")
        // The type grant is untouched (not burned by the failed click check).
        let typeIdentity = identity(
            "type-only", digest: typeDigest
        )
        #expect(BrowserSideEffectCallContext.$current.withValue(typeIdentity) {
            tool.session.hasApprovedSideEffectGrant(for: "type")
        })
    }

    @MainActor
    @Test func closeDestroysPendingGrantsSoSwitchedOffSessionsCannotAct() async throws {
        let tool = makeTool(scopeID: "closed-grant-scope")
        #expect(tool.authorizeFromApprovalReceipt(browserReceipt(requestID: "grant-close")))
        tool.session.close()
        let click = try await tool.execute(name: "browser", input: [
            "action": "click", "selector": "#x",
        ])
        let response = try JSONDecoder().decode(BrowserToolResponse.self, from: Data(click.utf8))
        #expect(response.outcome == "denied")
        // A grant redeemed for the closed session's ledger can never be issued.
        #expect(!tool.authorizeFromApprovalReceipt(browserReceipt(requestID: "grant-after-close")))
    }

    @MainActor
    @Test func foreignReceiptRedemptionCannotUnlockThisScopeEndToEnd() async throws {
        // Session B redeems nothing for a receipt issued against session A's
        // grant flow: redemption is always bound to the receiving session, so
        // a grant never crosses scopes through storage or replay.
        let toolA = makeTool(scopeID: "scope-a")
        let toolB = makeTool(scopeID: "scope-b")
        defer { toolA.session.close(); toolB.session.close() }
        #expect(toolA.authorizeFromApprovalReceipt(browserReceipt(requestID: "only-a")))
        #expect(!toolB.session.hasApprovedSideEffectGrant(for: "click"))
        let bResult = try await toolB.execute(name: "browser", input: [
            "action": "click", "selector": "#x",
        ])
        let bResponse = try JSONDecoder().decode(BrowserToolResponse.self, from: Data(bResult.utf8))
        #expect(bResponse.outcome == "denied")
        #expect(bResponse.scopeID == "scope-b")
        // A's grant is intact for A only.
        let approvedIdentity = identity(
            "only-a", digest: try ComposerToolInput(["action": "click", "selector": "#submit"]).digest
        )
        #expect(BrowserSideEffectCallContext.$current.withValue(approvedIdentity) {
            toolA.session.hasApprovedSideEffectGrant(for: "click")
        })
    }
}
