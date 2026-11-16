import Foundation
import Testing
@testable import MinisCore

/// N3 validation: aligned-with-Claude-Code expectations for MCP tools under a
/// session-scope allow. Synthetic fixtures only; real ComposerAuthorizationController
/// and ComposerApprovalGrantStore, nothing mocked on the tested path.
@Suite("N3 MCP session-scope consent survives within session")
struct N3McpSessionConsentTests {
    private let toolA = "mcp_fixture_alpha"
    private let toolB = "mcp_fixture_beta"
    private let args: [String: Any] = ["query": "synthetic"]

    private func snapshot(task: String, turn: Int, epoch: String) -> ComposerSubmissionSnapshot {
        ComposerSubmissionSnapshot(
            mode: .manual, approvalScope: .session, effort: .standard,
            sessionID: "session-n3", turnID: turn, taskID: task,
            attemptID: "attempt-\(task)", messageID: "message-\(task)",
            workspaceID: "workspace-n3", createdAt: Date(),
            policyRevision: "policy-n3", grantEpoch: epoch, autonomyCeiling: .l3)
    }

    /// `tools` is the full MCP set visible to that turn (known = granted = bindings keys),
    /// mirroring ChatAgentEngine.turnComposerPolicyFacts which unions bindings.keys.
    private func facts(
        tools: [String], epoch: String, lease: String, bindingVersion: String = ""
    ) -> ComposerPolicyFactSource {
        let names = Set(tools)
        var bindings: [String: String] = [:]
        for tool in tools { bindings[tool] = "binding-\(tool)\(bindingVersion)" }
        return ComposerPolicyFactSource(
            knownCapabilities: names, grantedCapabilities: names,
            capabilityGrantBindings: bindings, allowedWriteRoots: [],
            workspaceID: "workspace-n3", revision: "policy-n3",
            grantEpoch: epoch, leaseID: lease,
            expiresAt: Date().addingTimeInterval(600), autonomyCeiling: .l3)
    }

    private func controller(
        task: String, turn: Int, epoch: String, lease: String, tools: [String],
        grants: ComposerApprovalGrantStore, bindingVersion: String = ""
    ) -> ComposerAuthorizationController {
        ComposerAuthorizationController(
            snapshot: snapshot(task: task, turn: turn, epoch: epoch),
            facts: facts(tools: tools, epoch: epoch, lease: lease, bindingVersion: bindingVersion),
            grants: grants)
    }

    private func input() throws -> ComposerToolInput { try ComposerToolInput(args) }

    private func isPrompt(_ d: ComposerAuthorizationDecision) -> Bool {
        if case .requestApproval = d { return true }
        return false
    }

    @Test("Q(a) same session, same turn: second call to the MCP tool asks again")
    func sameTurnSecondCallAsksAgain() async throws {
        let grants = ComposerApprovalGrantStore()
        let c = controller(task: "t1", turn: 1, epoch: "e1", lease: "l1", tools: [toolA], grants: grants)
        #expect(isPrompt(try await c.authorize(capability: toolA, input: try input())))
        try await c.recordApproval(capability: toolA, input: try input())
        #expect(try await c.authorize(capability: toolA, input: try input()) == .requestApproval(requiresSecondConfirmation: false))
    }

    @Test("Q(a) same session, next turn with unchanged MCP set: the same tool asks again")
    func nextTurnSameToolSetAsksAgain() async throws {
        let grants = ComposerApprovalGrantStore()
        let first = controller(task: "t1", turn: 1, epoch: "e1", lease: "l1", tools: [toolA], grants: grants)
        try await first.recordApproval(capability: toolA, input: try input())
        let next = controller(task: "t2", turn: 2, epoch: "e2", lease: "l2", tools: [toolA], grants: grants)
        #expect(try await next.authorize(capability: toolA, input: try input()) == .requestApproval(requiresSecondConfirmation: false))
    }

    @Test("Q(b) both tools ask after a new MCP tool is discovered")
    func bothToolsAskAfterDiscovery() async throws {
        let grants = ComposerApprovalGrantStore()
        let first = controller(task: "t1", turn: 1, epoch: "e1", lease: "l1", tools: [toolA], grants: grants)
        #expect(isPrompt(try await first.authorize(capability: toolA, input: try input())))
        try await first.recordApproval(capability: toolA, input: try input())
        // Next turn the registry also exposes toolB: knownCapabilities and the
        // binding map grow, toolA's own binding is unchanged.
        let next = controller(task: "t2", turn: 2, epoch: "e2", lease: "l2",
                              tools: [toolA, toolB], grants: grants)
        #expect(try await next.authorize(capability: toolA, input: try input()) == .requestApproval(requiresSecondConfirmation: false))
        // The newly discovered tool also needs approval for this call.
        #expect(isPrompt(try await next.authorize(capability: toolB, input: try input())))
    }

    @Test("Q(b) safety kept: same-name tool whose own binding changed asks again")
    func changedBindingOfSameNamedToolStillPrompts() async throws {
        let grants = ComposerApprovalGrantStore()
        let first = controller(task: "t1", turn: 1, epoch: "e1", lease: "l1", tools: [toolA], grants: grants)
        try await first.recordApproval(capability: toolA, input: try input())
        // Same tool name, but its schema/server binding differs in the next turn.
        let next = controller(task: "t2", turn: 2, epoch: "e2", lease: "l2",
                              tools: [toolA], grants: grants, bindingVersion: "-changed")
        #expect(isPrompt(try await next.authorize(capability: toolA, input: try input())))
    }
}
