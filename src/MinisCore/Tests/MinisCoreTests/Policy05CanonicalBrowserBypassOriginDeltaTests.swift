import Foundation
import Testing
import WebKit
@testable import MinisCore

/// New-contract delta. Existing D-POLICY-02/05 test assertions remain untouched.
/// These exercise the real BrowserTool/session consumer without network access.
private actor BrowserBypassUnexpectedPrompt: ApprovalDelegate {
    private(set) var count = 0

    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        count += 1
        return ApprovalDecision(approved: false)
    }
}

@MainActor
struct Policy05CanonicalBrowserBypassOriginDeltaTests {
    private func scope(_ session: String = "session-1") -> BrowserSessionScope {
        BrowserSessionScope(
            surface: .agentBrowser, profile: "production",
            session: session, workspace: "workspace-1"
        )
    }

    private func controller(confirmed: Bool) -> ComposerAuthorizationController {
        let now = Date()
        let snapshot = ComposerSubmissionSnapshot(
            mode: .bypassPermission, approvalScope: .session,
            effort: .standard, sessionID: "session-1", turnID: 1,
            taskID: "policy05-test", attemptID: "attempt-1",
            messageID: "message-1", workspaceID: "workspace-1",
            createdAt: now, policyRevision: "revision-1",
            grantEpoch: "epoch-1", bypassModeConfirmed: confirmed,
            autonomyCeiling: .l3
        )
        let names: Set<String> = ["browser", BL6SettingsToolApproval.toolName]
        let facts = ComposerPolicyFactSource(
            knownCapabilities: names, grantedCapabilities: names,
            allowedWriteRoots: [], workspaceID: "workspace-1",
            revision: "revision-1", grantEpoch: "epoch-1",
            leaseID: "lease-1", expiresAt: now.addingTimeInterval(600),
            autonomyCeiling: .l3
        )
        return ComposerAuthorizationController(snapshot: snapshot, facts: facts)
    }

    private var click: [String: Any] { ["action": "click", "selector": "#go"] }

    @Test("public call context cannot create a browser write grant")
    func publicContextAndDefaultOffFailClosed() async throws {
        let tool = BrowserTool(scope: scope())
        defer { tool.session.close() }
        let input = try ComposerToolInput(click)
        let identity = BrowserSideEffectExecutionIdentity(callID: "call-1", inputDigest: input.digest)
        let raw = try await BrowserSideEffectCallContext.$current.withValue(identity) {
            try await tool.execute(name: "browser", input: ["action": "click", "selector": "#go"])
        }
        #expect(raw.contains("write_authorization_required"))
        #expect(tool.session.sideEffectGrants.pendingGrantCount == 0)
        let unconfirmed = controller(confirmed: false)
        await #expect(throws: ComposerAuthorizationError.bypassConfirmationRequired) {
            try await unconfirmed.authorize(capability: "browser", input: input)
        }
    }

    @Test("confirmed bypass reaches the actual browser write consumer")
    func confirmedBypassChangesSyntheticDOM() async throws {
        let host = "one.invalid"
        let tool = BrowserTool(scope: scope(), writeActionsEnabled: true,
                               navigationPolicy: BrowserNavigationPolicy(allowedDomains: [host]))
        defer { tool.session.close() }
        try await tool.session.loadHTMLString("""
        <button id="go" onclick="document.querySelector('#state').textContent='changed'">Go</button>
        <p id="state">original</p>
        """, baseURL: URL(string: "https://one.invalid/synthetic")!)
        #expect(try await tool.session.textContent(selector: "#state") == "original")
        let input = try ComposerToolInput(click)
        let delegate = BrowserBypassUnexpectedPrompt()
        let executor = ComposerPolicyEnforcedToolExecutor(
            base: tool, controller: controller(confirmed: true), approvalGate: ApprovalGate(delegate: delegate)
        )
        do {
            let raw = try await executor.execute(callID: "native-browser-bypass", name: "browser", input: input)
            #expect(!raw.contains("write_authorization_required"))
        } catch {
            Issue.record("Confirmed bypass did not reach the browser consumer: \(error)")
        }
        #expect(await delegate.count == 0)
        #expect(try await tool.session.textContent(selector: "#state") == "changed")
        #expect(tool.session.sideEffectGrants.pendingGrantCount == 0)
    }

    @Test("canonical confirmed bypass binds each browser write")
    func confirmedBypassCreatesBrowserOrigin() async throws {
        let source = controller(confirmed: true)
        for callID in ["first", "second"] {
            let input = try ComposerToolInput(click)
            let decision = try await source.authorize(capability: "browser", input: input)
            #expect(decision == .execute)
            #expect(try await source.browserBypassOrigin(callID: callID, capability: "browser", input: input) != nil)
        }
    }

    @Test("click and type remain refused without a trusted call origin")
    func browserActionsCannotExecuteWithoutTrustedCallOrigin() async throws {
        let tool = BrowserTool(scope: scope(), writeActionsEnabled: true)
        defer { tool.session.close() }
        let source = controller(confirmed: true)
        let actions: [[String: Any]] = [click, ["action": "type", "selector": "#q", "text": "abc"]]
        for (index, action) in actions.enumerated() {
            let input = try ComposerToolInput(action)
            #expect(try await source.authorize(capability: "browser", input: input)
                == .execute)
            #expect(try await source.browserBypassOrigin(callID: "call-\(index)", capability: "browser", input: input) != nil)
            let raw = try await tool.execute(name: "browser", input: action)
            #expect(raw.contains("write_authorization_required"))
            #expect(tool.session.sideEffectGrants.pendingGrantCount == 0)
        }
    }

    @Test("confirmed bypass authorizes settings without reuse of scoped consent")
    func settingsMutationNeverReusesBypassScopeGrant() async throws {
        let source = controller(confirmed: true)
        let input = try ComposerToolInput(["operation": "set", "key": "approvalPolicy"])
        let first = try await source.authorize(
            capability: BL6SettingsToolApproval.toolName, input: input
        )
        #expect(first == .execute)
        try await source.recordApproval(
            capability: BL6SettingsToolApproval.toolName, input: input
        )
        let second = try await source.authorize(
            capability: BL6SettingsToolApproval.toolName, input: input
        )
        #expect(second == .execute)
    }
}
