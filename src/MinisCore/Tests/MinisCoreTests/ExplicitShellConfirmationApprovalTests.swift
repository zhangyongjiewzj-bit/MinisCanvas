import Foundation
import Testing
@testable import MinisCore

@Suite("User-entered shell confirmation stays fresh outside confirmed bypass")
struct ExplicitShellConfirmationApprovalTests {
    private let input: [String: Any] = ["command": "git status"]

    private func explicitSnapshot() -> TerminalPolicySnapshot {
        let defaults = TerminalPolicySettings.default
        let removed = defaults.editingConfirmationCommands(defaults.confirmationCommands.filter { $0 != "git" })
        return TerminalPolicySnapshot(settings: removed.editingConfirmationCommands(defaults.confirmationCommands))
    }

    private func gate(delegate: (any ApprovalDelegate)? = nil) -> ApprovalGate {
        var gate = ApprovalGate(delegate: delegate)
        gate.terminalPolicySnapshot = explicitSnapshot()
        return gate
    }

    private func controller(mode: ComposerTaskMode = .auto, confirmed: Bool = false) -> ComposerAuthorizationController {
        let now = Date()
        let snapshot = ComposerSubmissionSnapshot(mode: mode, approvalScope: .session, effort: .standard,
            sessionID: "explicit-session", turnID: 1, taskID: "explicit-task", messageID: "explicit-message",
            workspaceID: "explicit-workspace", createdAt: now, policyRevision: "explicit-v1",
            grantEpoch: "explicit-epoch", bypassModeConfirmed: confirmed, autonomyCeiling: .l3)
        let facts = ComposerPolicyFactSource(knownCapabilities: ["shell_execute"], grantedCapabilities: ["shell_execute"],
            allowedWriteRoots: ["/synthetic/project"], workspaceID: "explicit-workspace", revision: "explicit-v1",
            grantEpoch: "explicit-epoch", leaseID: "explicit-lease", expiresAt: now.addingTimeInterval(600),
            autonomyCeiling: .l3)
        return ComposerAuthorizationController(snapshot: snapshot, facts: facts, now: { now })
    }

    @Test func inputClassificationPreservesFiniteGitRiskAndDenials() throws {
        let ordinary = ApprovalGate()
        #expect(ApprovalGate.defaultPolicies["shell_execute"] == .autoApprove)
        #expect(ApprovalGate.riskByTool["shell_execute"] == .high)
        #expect(ApprovalGate.inputRiskLevel(tool: "shell_execute", input: input) == .low)
        #expect(!ordinary.shouldAsk(tool: "shell_execute", input: input))
        #expect(gate().shouldAsk(tool: "shell_execute", input: input))
        #expect(gate().requiresExplicitShellConfirmation(tool: "shell_execute", input: ["command": "nice -n 2 git status"]))
        #expect(ApprovalGate.inputRiskLevel(tool: "shell_execute", input: ["command": "echo one; echo two"]) == .high)
        #expect(ordinary.shouldAsk(tool: "shell_execute", input: ["command": "echo one; echo two"]))
        var denied = explicitSnapshot().settings
        denied.userDeniedCommands = ["git"]
        let snapshot = TerminalPolicySnapshot(settings: denied)
        #expect(snapshot.explicitConfirmationCommands.isEmpty)
        #expect(throws: ToolExecutorError.self) {
            _ = try BuiltinToolExecutor.validateShellPolicy(command: "git status", snapshot: snapshot)
        }
        #expect(throws: ToolExecutorError.self) {
            _ = try BuiltinToolExecutor.validateShellPolicy(command: "halt ls", snapshot: explicitSnapshot())
        }
    }

    @Test func ordinaryAutoStillExecutesFiniteReadOnlyGitButAsksForCompoundInput() async throws {
        let probe = ExplicitShellProbe()
        let executor = ComposerPolicyEnforcedToolExecutor(base: probe, controller: controller(), approvalGate: ApprovalGate())
        #expect(try await executor.execute(callID: "ordinary-git", name: "shell_execute", input: input) == "synthetic-effect")
        #expect(probe.executions == 1)
        // 自动档：只读命令免问，每个子命令都要过效果检查；含非只读子命令的复合输入仍要问。
        let compound = try await executor.authorizationDecision(callID: "ordinary-compound", capability: "shell_execute",
            input: ComposerToolInput(["command": "echo one; curl https://example.com"]))
        #expect(compound.decision == .requestApproval(requiresSecondConfirmation: false))
        #expect(probe.executions == 1)
    }

    @Test func autoModeCannotReuseGrantPersistentRuleOrHookAllow() async throws {
        guard let isolation = try FormalTestIsolationPaths.resolveCurrentProcess() else {
            throw FormalTestIsolationPaths.IsolationError.missingContract
        }
        let owned = isolation.rootDirectory.appendingPathComponent("explicit-history-" + UUID().uuidString)
        // Retain only this run's synthetic fixture for the evidence owner's cleanup.
        for prior in ["none", "scoped", "persistent", "hook", "all"] {
            let directory = owned.appendingPathComponent(prior)
            let project = directory.appendingPathComponent("project")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let rules = PersistentApprovalRuleStore(fileURL: directory.appendingPathComponent("rules.json"),
                homeDirectory: "/nonexistent-home-for-explicit-confirmation-tests")
            let template = controller()
            let submission = await template.snapshot
            let originalFacts = await template.facts
            let facts = ComposerPolicyFactSource(knownCapabilities: ["shell_execute"], grantedCapabilities: ["shell_execute"],
                allowedWriteRoots: [project.path], workspaceID: submission.workspaceID,
                revision: originalFacts.revision, grantEpoch: originalFacts.grantEpoch,
                leaseID: originalFacts.leaseID, expiresAt: originalFacts.expiresAt, autonomyCeiling: .l3)
            let frozen = try ComposerToolInput(input)
            let controller = ComposerAuthorizationController(snapshot: submission, facts: facts,
                grants: ComposerApprovalGrantStore(persistentRules: rules))
            if prior == "persistent" || prior == "all" {
                // Seed genuine historical user data before attaching the explicit gate.
                let seed = ComposerAuthorizationController(snapshot: submission, facts: facts,
                    grants: ComposerApprovalGrantStore(persistentRules: rules))
                #expect(rules.isAttached)
                let saved = try #require(await seed.persistAllowRule(capability: "shell_execute", input: frozen))
                #expect(saved.pattern == "git status")
                let matched = try #require(rules.match(capability: "shell_execute", input: input, facts: facts))
                #expect(matched.id == saved.id)
                // 普通（非显式确认）情形下，这条历史规则在自动档里能免去弹卡；git status 本身属只读命令，
                // 自动档（用户 2026-11-16 决定）已先按只读放行，所以结果里不再带规则 ID。
                let ordinary = ComposerPolicyEnforcedToolExecutor(base: ExplicitShellProbe(), controller: seed,
                    approvalGate: ApprovalGate(policyByTool: ["shell_execute": .alwaysAsk]),
                    hookHandler: { invocation in ComposerHookResult(verdict: .allow,
                        invocationIdentityDigest: invocation.identityDigest, hasDecision: false) })
                let allowed = try await ordinary.authorizationDecision(callID: "historical-" + prior,
                    capability: "shell_execute", input: frozen)
                #expect(allowed.decision == .execute)
            }
            if prior == "scoped" || prior == "all" {
                try await controller.recordApproval(capability: "shell_execute", input: frozen)
            }
            let executor = ComposerPolicyEnforcedToolExecutor(base: ExplicitShellProbe(), controller: controller,
                approvalGate: gate(), hookHandler: { invocation in
                    ComposerHookResult(verdict: .allow, invocationIdentityDigest: invocation.identityDigest,
                        hasDecision: prior == "hook" || prior == "all")
                })
            let result = try await executor.authorizationDecision(callID: "explicit-" + prior,
                capability: "shell_execute", input: frozen)
            #expect(result.decision == .requestApproval(requiresSecondConfirmation: false))
            #expect(result.rule == nil)
        }
    }

    @Test func missingOrDenyingDelegateCannotReachEffectEvenWithHookAllow() async throws {
        let probe = ExplicitShellProbe()
        let missing = ComposerPolicyEnforcedToolExecutor(base: probe, controller: controller(), approvalGate: gate(),
            hookHandler: { invocation in ComposerHookResult(verdict: .allow, invocationIdentityDigest: invocation.identityDigest) })
        await #expect(throws: (any Error).self) {
            _ = try await missing.execute(callID: "explicit-missing", name: "shell_execute", input: input)
        }
        let delegate = ExplicitShellDelegate(approved: false)
        let denied = ComposerPolicyEnforcedToolExecutor(base: probe, controller: controller(), approvalGate: gate(delegate: delegate))
        await #expect(throws: (any Error).self) {
            _ = try await denied.execute(callID: "explicit-declined", name: "shell_execute", input: input)
        }
        var blockedGate = gate()
        blockedGate.policyByTool["shell_execute"] = .deny
        let blocked = ComposerPolicyEnforcedToolExecutor(base: probe, controller: controller(), approvalGate: blockedGate)
        await #expect(throws: (any Error).self) {
            _ = try await blocked.execute(callID: "explicit-policy-deny", name: "shell_execute", input: input)
        }
        #expect(probe.executions == 0)
        #expect(await delegate.requests.count == 1)
    }

    @Test func approvedCallExecutesOnceButNextCallStillAsks() async throws {
        let probe = ExplicitShellProbe()
        let delegate = ExplicitShellDelegate(approved: true)
        let executor = ComposerPolicyEnforcedToolExecutor(base: probe, controller: controller(), approvalGate: gate(delegate: delegate))
        let authorization = try await executor.authorizeExecution(callID: "explicit-one", name: "shell_execute", input: input)
        #expect(probe.executions == 0)
        #expect(await delegate.requests.count == 1)
        #expect(try await executor.execute(preauthorization: authorization, callID: "explicit-one",
            name: "shell_execute", input: input) == "synthetic-effect")
        #expect(probe.executions == 1)
        #expect(await delegate.requests.count == 1)
        await #expect(throws: (any Error).self) {
            _ = try await executor.execute(preauthorization: authorization, callID: "explicit-one",
                name: "shell_execute", input: input)
        }
        #expect(probe.executions == 1)
        #expect(try await executor.execute(callID: "explicit-two", name: "shell_execute", input: input) == "synthetic-effect")
        #expect(probe.executions == 2)
        let requests = await delegate.requests
        #expect(requests.count == 2)
        #expect(Set(requests.map(\.callID)).count == 2)
        #expect(requests.allSatisfy { $0.requiresApproval })
    }

    @Test func confirmedBypassKeepsExistingNoPromptPathAndUnconfirmedIsRejected() async throws {
        let probe = ExplicitShellProbe()
        let delegate = ExplicitShellDelegate(approved: false)
        let bypass = ComposerPolicyEnforcedToolExecutor(base: probe,
            controller: controller(mode: .bypassPermission, confirmed: true), approvalGate: gate(delegate: delegate))
        #expect(try await bypass.execute(callID: "explicit-bypass", name: "shell_execute", input: input) == "synthetic-effect")
        #expect(probe.executions == 1)
        #expect(await delegate.requests.isEmpty)
        let unconfirmed = ComposerPolicyEnforcedToolExecutor(base: probe,
            controller: controller(mode: .bypassPermission), approvalGate: gate(delegate: delegate))
        await #expect(throws: ComposerAuthorizationError.bypassConfirmationRequired) {
            _ = try await unconfirmed.execute(callID: "explicit-unconfirmed", name: "shell_execute", input: input)
        }
        #expect(probe.executions == 1)
    }
}

private final class ExplicitShellProbe: ToolExecutor, @unchecked Sendable {
    private(set) var executions = 0
    func execute(name: String, input: [String: Any]) async throws -> String {
        executions += 1
        return "synthetic-effect"
    }
}

private actor ExplicitShellDelegate: ApprovalDelegate {
    let approved: Bool
    private(set) var requests: [ApprovalRequest] = []
    init(approved: Bool) { self.approved = approved }
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        requests.append(request)
        return ApprovalDecision(approved: approved, reason: "synthetic-decision", confirmed: approved,
            requestID: request.requestID, bindingDigest: request.identityDigest)
    }
}
