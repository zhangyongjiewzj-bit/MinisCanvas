import Foundation
import Testing
@testable import MinisCore

/// W-a policy contracts for external_session_read / external_session_send.
/// Written before the implementation was compiled: status = RED/未运行.
@Suite("External session tool approval policy")
struct ExternalSessionToolPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let read = ExternalSessionToolNames.read
    private let send = ExternalSessionToolNames.send
    private let sendInputA = try! ComposerToolInput(["source": "codex", "session": "11111111-1111-1111-1111-111111111111", "message": "first"])
    private let sendInputB = try! ComposerToolInput(["source": "claude_code", "session": "22222222-2222-2222-2222-222222222222", "message": "second"])
    private let readInput = try! ComposerToolInput(["source": "codex"])

    private func controller(mode: ComposerTaskMode, scope: ComposerApprovalScope = .request) -> ComposerAuthorizationController {
        let snapshot = ComposerSubmissionSnapshot(
            mode: mode, approvalScope: scope, effort: .standard, sessionID: "session-1", turnID: 7,
            taskID: "task-1", messageID: "message-1", workspaceID: "workspace-1", createdAt: now,
            policyRevision: "facts-1", grantEpoch: "epoch-0",
            bypassModeConfirmed: mode == .bypassPermission, autonomyCeiling: .l3)
        let granted: Set<String> = [read, send]
        let facts = ComposerPolicyFactSource(
            knownCapabilities: granted, grantedCapabilities: granted, allowedWriteRoots: ["/tmp/workspace"],
            workspaceID: "workspace-1", revision: "facts-1", grantEpoch: "epoch-0", leaseID: "lease-1",
            expiresAt: now.addingTimeInterval(600), autonomyCeiling: .l3)
        return ComposerAuthorizationController(snapshot: snapshot, facts: facts, now: { now })
    }

    private let human = ComposerAuthorizationDecision.requestApproval(requiresSecondConfirmation: false)

    @Test("send asks unless bypass is confirmed; read never asks")
    func sendRequiresHumanApprovalUnlessBypassIsConfirmed() async throws {
        for mode in [ComposerTaskMode.manual, .autoEdit, .auto, .bypassPermission] {
            let c = controller(mode: mode)
            #expect(try await c.authorize(capability: send, input: sendInputA) == (mode == .bypassPermission ? .execute : human))
            #expect(try await c.authorize(capability: read, input: readInput) == .execute)
        }
    }

    @Test("external send follows mode independently of approval scope")
    func sendDecisionDoesNotReuseScopedConsent() async throws {
        for scope in [ComposerApprovalScope.request, .turn, .session, .workspace] {
            for mode in [ComposerTaskMode.manual, .bypassPermission] {
                let c = controller(mode: mode, scope: scope)
                try await c.recordApproval(capability: send, input: sendInputA)
                #expect(try await c.authorize(capability: send, input: sendInputA) == (mode == .bypassPermission ? .execute : human))
                #expect(try await c.authorize(capability: send, input: sendInputB) == (mode == .bypassPermission ? .execute : human))
            }
        }
    }

    @Test("plan mode dry-runs send but still allows read")
    func planModeDryRunsSendButAllowsRead() async throws {
        let c = controller(mode: .plan)
        #expect(try await c.authorize(capability: send, input: sendInputA) == .dryRun)
        #expect(try await c.authorize(capability: read, input: readInput) == .execute)
    }

    @Test("send offers no persistent allow rule")
    func noPersistentAllowOfferForSend() async throws {
        let c = controller(mode: .manual)
        #expect(await c.persistentAllowOffer(capability: send, input: sendInputA) == nil)
        #expect(!PersistentApprovalRuleMatcher.supportedCapabilities.contains(send))
    }

    @Test("gate tables: read auto/low, send always-ask/high, also under the auto-approve policy")
    func gateTables() {
        #expect(ApprovalGate.defaultPolicies[read] == .autoApprove)
        #expect(ApprovalGate.riskByTool[read] == .low)
        #expect(ApprovalGate.defaultPolicies[send] == .alwaysAsk)
        #expect(ApprovalGate.riskByTool[send] == .high)
        #expect(ApprovalGate.policyOverrides(for: .autoApprove)[send] == .alwaysAsk)
        #expect(ApprovalGate.policyOverrides(for: .autoApprove)[read] == .autoApprove)
    }

    @Test("both tools are registered names of the builtin executor and known to the Composer")
    func bothToolsAreRegistered() {
        let names = BuiltinToolExecutor.defaultRegisteredToolNames()
        #expect(names.contains(read) && names.contains(send))
    }

    @Test("external_ prefix is covered by the external-agents safety switch")
    func externalPrefixNames() {
        #expect(read.hasPrefix("external_") && send.hasPrefix("external_"))
    }

    // DEPENDS ON W-b (AgentOrchestrator.swift:2908 forbidden set): until then the child
    // inheritance/explicit-request tests cannot be RED/GREEN in this lane. Name reserved:
    // childAgentsNeverInheritEitherTool (inherit path) / childAgentsCannotRequestEitherTool (explicit path).
}
