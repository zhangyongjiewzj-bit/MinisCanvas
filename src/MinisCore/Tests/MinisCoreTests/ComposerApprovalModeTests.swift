import Foundation
import CryptoKit
import Testing
@testable import MinisCore

@Suite("Composer policy and approval contracts")
struct ComposerApprovalModeTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("session checklist is low risk and needs no human approval")
    func sessionTodoWriteUsesExistingLowRiskApprovalPath() async throws {
        let input: [String: Any] = ["progress": ["todos": [
            ["content": "读取文件", "status": "in_progress"]
        ]]]
        let gate = ApprovalGate()
        #expect(gate.policy(for: SessionTodoProgress.toolName) == .autoApprove)
        #expect(gate.riskLevel(for: SessionTodoProgress.toolName) == .low)
        #expect(!gate.shouldAsk(tool: SessionTodoProgress.toolName, input: input))
        let controller = ComposerAuthorizationController(snapshot: snapshot(mode: .manual),
            facts: facts(granted: [SessionTodoProgress.toolName]), now: { now })
        #expect(try await controller.authorize(capability: SessionTodoProgress.toolName,
            input: ComposerToolInput(input)) == .execute)

        let alwaysAsk = ApprovalGate(policy: .alwaysAsk)
        #expect(!alwaysAsk.shouldAsk(tool: SessionTodoProgress.toolName, input: input))
        #expect(Set(ApprovalGate.defaultPolicies.keys.filter {
            alwaysAsk.policy(for: $0) != .alwaysAsk
        }) == [SessionTodoProgress.toolName, ExternalSessionToolNames.read,
               // 第七版：向用户提问本身就是等用户；读技能只读取哈希。两者在每次询问下也免卡。
               AskUserQuestionTool.toolName, SkillMaintenanceTool.readName,
               // 用户 2026-11-16 决定：授权目录内只读文件工具与压缩上下文不弹卡（对齐 Claude Code）。
               "file_read", "file_grep", "file_glob", ContextCompactTool.toolName])
        let executor = ComposerPolicyEnforcedToolExecutor(base: CountingToolExecutor(),
            controller: controller, approvalGate: alwaysAsk)
        let decision = try await executor.authorizationDecision(callID: "todo-always-ask",
            capability: SessionTodoProgress.toolName, input: ComposerToolInput(input))
        #expect(decision.decision == .execute)
    }

    @Test("hook allow preserves mandatory human decisions and cannot override lower denies")
    func hookAllowPreservesEveryMandatoryPromptCategory() async throws {
        let cases: [(String, ComposerToolInput)] = [
            ("file_delete", try ComposerToolInput(["path": "/tmp/workspace/file.txt"])),
            ("browser", try ComposerToolInput(["action": "click", "selector": "#submit"])),
            (BL6SettingsToolApproval.toolName, try ComposerToolInput(["operation": "apply"])),
            (BL6SettingsToolApproval.catalogToolName, try ComposerToolInput(["operation": "list"])),
            ("file_write", try ComposerToolInput(["path": "/tmp/workspace/file.txt", "file_path": "/tmp/workspace/.env"])),
            ("shell_execute", try ComposerToolInput(["command": "printf synthetic"]))
        ]
        for (index, sample) in cases.enumerated() {
            let executor = ComposerPolicyEnforcedToolExecutor(base: CountingToolExecutor(),
                controller: ComposerAuthorizationController(snapshot: snapshot(mode: .manual),
                    facts: facts(granted: [sample.0]), now: { now }), approvalGate: ApprovalGate(),
                hookHandler: { invocation in ComposerHookResult(verdict: .allow,
                    invocationIdentityDigest: invocation.identityDigest) })
            let actual = try await executor.authorizationDecision(callID: "mandatory-\(index)",
                capability: sample.0, input: sample.1)
            if case .requestApproval = actual.decision { } else { Issue.record("mandatory category must ask: \(sample.0)") }
        }
        let base = CountingToolExecutor()
        let denied = ComposerPolicyEnforcedToolExecutor(base: base,
            controller: ComposerAuthorizationController(snapshot: snapshot(mode: .manual),
                facts: facts(), now: { now }), approvalGate: ApprovalGate(policy: .deny),
            hookHandler: { invocation in ComposerHookResult(verdict: .allow, invocationIdentityDigest: invocation.identityDigest) })
        await #expect(throws: (any Error).self) {
            _ = try await denied.execute(callID: "deny", name: "file_write", input: ["path": "/tmp/workspace/file.txt"])
        }
        let floor = ComposerPolicyEnforcedToolExecutor(base: base,
            controller: ComposerAuthorizationController(snapshot: snapshot(mode: .bypassPermission),
                facts: facts(), now: { now }), approvalGate: ApprovalGate(),
            hookHandler: { invocation in ComposerHookResult(verdict: .allow, invocationIdentityDigest: invocation.identityDigest) })
        await #expect(throws: (any Error).self) {
            _ = try await floor.execute(callID: "floor", name: "file_write", input: ["path": "/System/Library/group6-never.txt"])
        }
        #expect(base.executionCount == 0)
    }

    @Test("PreToolUse deny prevents both the approval prompt and the tool effect")
    func preToolDenyComesBeforeTheHumanPrompt() async throws {
        let delegate = RecordingApprovalDelegate(decision: .approve)
        let base = CountingToolExecutor()
        let controller = ComposerAuthorizationController(snapshot: snapshot(mode: .manual),
            facts: facts(), now: { now })
        let executor = ComposerPolicyEnforcedToolExecutor(base: base, controller: controller,
            approvalGate: ApprovalGate(delegate: delegate), hookHandler: { invocation in
                ComposerHookResult(verdict: .deny, invocationIdentityDigest: invocation.identityDigest,
                    reason: "本次工具被 Hook 阻止")
            })
        await #expect(throws: ComposerAuthorizationError.hookRejected("本次工具被 Hook 阻止")) {
            _ = try await executor.execute(callID: "pre-deny", name: "file_write",
                input: ["path": "/tmp/workspace/never-written.txt", "content": "synthetic"])
        }
        #expect(await delegate.requests.isEmpty)
        #expect(base.executionCount == 0)
    }

    @Test("file_delete asks again outside confirmed bypass; bypass uses the one-time acknowledgement")
    func fileDeleteNeverUsesRememberedGrant() async throws {
        let input = try ComposerToolInput(["path": "/tmp/workspace/synthetic.txt"])
        for mode in [ComposerTaskMode.manual, .autoEdit, .auto, .bypassPermission] {
            let controller = ComposerAuthorizationController(
                snapshot: snapshot(mode: mode, scope: .session),
                facts: facts(granted: ["file_delete", "file_write", "file_edit"]),
                now: { now }
            )
            let expected: ComposerAuthorizationDecision = mode == .bypassPermission
                ? .execute : .requestApproval(requiresSecondConfirmation: false)
            #expect(try await controller.authorize(capability: "file_delete", input: input) == expected)
            try await controller.recordApproval(capability: "file_delete", input: input)
            #expect(try await controller.authorize(capability: "file_delete", input: input) == expected)
            if mode == .autoEdit {
                #expect(try await controller.authorize(capability: "file_write", input: input) == .execute)
                #expect(try await controller.authorize(capability: "file_edit", input: input) == .execute)
            }
        }
        #expect(ApprovalGate.defaultPolicies["file_write"] == .alwaysAsk)
        #expect(ApprovalGate.defaultPolicies["file_edit"] == .alwaysAsk)
    }

    @Test("reasoning summary has four typed modes and fails closed for unsupported providers")
    func reasoningSummaryModesAreProviderGated() throws {
        #expect(Set(BL6ReasoningSummaryMode.allCases.map(\.rawValue)) == [
            "automatic", "concise", "detailed", "off"
        ])

        let unsupported = BL6ReasoningSummarySnapshot(
            mode: .detailed,
            providerID: "provider",
            modelID: "model",
            providerSupportsSafeSummary: false,
            safeSummary: "不得伪造的内容"
        )
        #expect(unsupported.availability == .unavailable)
        #expect(unsupported.safeSummary == nil)
        #expect(!unsupported.isVisible)
        #expect(unsupported.statusText == "当前模型不提供推理摘要")

        let hidden = BL6ReasoningSummarySnapshot(
            mode: .off,
            providerID: "provider",
            modelID: "model",
            providerSupportsSafeSummary: true,
            safeSummary: "也不得显示"
        )
        #expect(hidden.availability == .hidden)
        #expect(hidden.safeSummary == nil)
    }

    @Test("supported summaries are bounded and scrubbed before the frozen turn snapshot")
    func supportedReasoningSummaryIsSafeMetadata() throws {
        let summary = BL6ReasoningSummarySnapshot(
            mode: .concise,
            providerID: "provider",
            modelID: "model",
            providerSupportsSafeSummary: true,
            safeSummary: "阶段完成\napi_key=secret-value /Users/alice/private.txt https://example.invalid/x",
            capturedForTurnID: "turn-7"
        )
        #expect(summary.availability == .available)
        #expect(summary.isVisible)
        #expect(summary.capturedForTurnID == "turn-7")
        #expect(summary.safeSummary?.contains("secret-value") == false)
        #expect(summary.safeSummary?.contains("/Users/alice/private.txt") == false)
        #expect(summary.safeSummary?.contains("https://example.invalid/x") == false)

        let values = BL6SettingsCatalog.production.completeValues(overriding: [
            "agent.composer-policy": .object(["reasoningSummaryMode": .text("detailed")])
        ])
        let settings = try BL6SettingsCatalog.production.effectiveSnapshot(
            revision: "facts-1",
            values: values
        )
        let frozen = BL6InFlightSettingsSnapshot(
            snapshot: settings,
            capturedForTurnID: "turn-7",
            reasoningSummary: summary
        )
        #expect(settings.reasoningSummaryMode == .detailed)
        #expect(frozen.reasoningSummary == summary)
        #expect(frozen.capturedForTurnID == "turn-7")
    }

    private func snapshot(
        mode: ComposerTaskMode,
        scope: ComposerApprovalScope = .request,
        taskID: String = "task-1",
        policyRevision: String = "facts-1",
        grantEpoch: String = "epoch-0",
        messageID: String = "message-1",
        sessionID: String = "session-1",
        workspaceID: String = "workspace-1",
        turnID: Int = 7,
        bypassModeConfirmed: Bool? = nil
    ) -> ComposerSubmissionSnapshot {
        ComposerSubmissionSnapshot(
            mode: mode,
            approvalScope: scope,
            effort: .standard,
            sessionID: sessionID,
            turnID: turnID,
            taskID: taskID,
            messageID: messageID,
            workspaceID: workspaceID,
            createdAt: now,
            policyRevision: policyRevision,
            grantEpoch: grantEpoch,
            bypassModeConfirmed: bypassModeConfirmed ?? (mode == .bypassPermission), autonomyCeiling: .l3
        )
    }

    private func facts(
        granted: Set<String> = ["file_read", "file_write", "file_edit", "shell_execute"],
        roots: [String] = ["/tmp/workspace"],
        revision: String = "facts-1",
        grantEpoch: String = "epoch-0",
        leaseID: String = "lease-1"
    ) -> ComposerPolicyFactSource {
        ComposerPolicyFactSource(
            knownCapabilities: granted,
            grantedCapabilities: granted,
            allowedWriteRoots: roots,
            workspaceID: "workspace-1",
            revision: revision,
            grantEpoch: grantEpoch,
            leaseID: leaseID,
            expiresAt: now.addingTimeInterval(600), autonomyCeiling: .l3
        )
    }

    @Test("Composer authority fact follows the original bound decision and live policy")
    func composerAuthorityFactUsesFrozenCallAfterDelegate() async throws {
        enum Outcome: CaseIterable, Equatable { case approved, delegateRevoked, policyRevoked, abandoned }
        for outcome in Outcome.allCases {
            let suffix = UUID().uuidString
            let stamp = Date()
            let callID = "call:\(suffix)"
            let submission = ComposerSubmissionSnapshot(
                mode: .manual, approvalScope: .request, effort: .standard,
                sessionID: "session:\(suffix)", turnID: 1, taskID: "task:\(suffix)",
                attemptID: "attempt:\(suffix)", messageID: "message:\(suffix)",
                workspaceID: "workspace:\(suffix)", createdAt: stamp,
                policyRevision: "revision", grantEpoch: "epoch", autonomyCeiling: .l3
            )
            let policyFacts = ComposerPolicyFactSource(
                knownCapabilities: ["file_write"], grantedCapabilities: ["file_write"],
                allowedWriteRoots: ["/tmp/workspace"], workspaceID: submission.workspaceID,
                revision: submission.policyRevision, grantEpoch: submission.grantEpoch,
                leaseID: "lease:\(suffix)", expiresAt: stamp.addingTimeInterval(120),
                autonomyCeiling: .l3
            )
            let controller = ComposerAuthorizationController(snapshot: submission, facts: policyFacts)
            let delegate = AuthorityBlockingDelegate()
            let base = CountingToolExecutor()
            let observed = AuthorityFactBox()
            let identity = AgentExecutionIdentity(
                turn: AgentTurnIdentity(
                    sessionID: submission.sessionID, turnID: submission.turnID,
                    messageID: submission.messageID
                ),
                operationID: "operation:\(suffix)", attempt: 1
            )
            let presentation = ApprovalPresentationContext(
                compositeKey: ToolExecutionCompositeKey(
                    sessionID: submission.sessionID, turnID: submission.turnID,
                    messageID: submission.messageID, operationID: identity.operationID,
                    attemptID: submission.attemptID, attemptNumber: 1, toolCallID: callID
                ),
                executionIdentity: identity, toolName: "file_write",
                eventSink: { observed.record($0) }
            )
            let executor = ComposerPolicyEnforcedToolExecutor(
                base: base, controller: controller, approvalGate: ApprovalGate(delegate: delegate)
            )
            let task = Task {
                try await ApprovalPresentationContext.$current.withValue(presentation) {
                    try await executor.authorizeExecution(
                        callID: callID, name: "file_write",
                        input: ["path": "/tmp/workspace/synthetic-\(suffix).txt", "content": "sample"]
                    )
                }
            }
            await delegate.waitForRequest()
            if outcome == .policyRevoked { await controller.revoke() }
            await delegate.resolve(outcome == .delegateRevoked ? .revoked : .approved)
            if outcome == .approved {
                let authorization = try await task.value
                // M01's original TaskLocal scope covers authorize, not this
                // later effect call. The pending value must retain the exact
                // observed request identity without granting authority.
                let output = try await executor.execute(
                    preauthorization: authorization, callID: callID,
                    name: "file_write",
                    input: ["path": "/tmp/workspace/synthetic-\(suffix).txt", "content": "sample"]
                )
                #expect(output == "executed")
                #expect(base.executionCount == 1)
                #expect(observed.facts.map(\.stage) == [.authorityApproved])
            } else if outcome == .abandoned {
                let authorization = try await task.value
                await authorization.observeUnexecutedCancellation()
                await authorization.observeUnexecutedCancellation()
                #expect(base.executionCount == 0)
                #expect(observed.facts.map(\.stage) == [.authorityCancelled])
            } else {
                await #expect(throws: (any Error).self) { _ = try await task.value }
                #expect(base.executionCount == 0)
                #expect(observed.facts.map(\.stage) == [.authorityRevoked])
            }
            #expect(observed.facts.first?.compositeKey.toolCallID == callID)
        }
    }

    @Test("snapshot captures immutable mode, scope, effort, session, turn and task")
    func snapshotCarriesSendBoundary() {
        let value = snapshot(mode: .auto, scope: .session)

        #expect(value.mode == .auto)
        #expect(value.approvalScope == .session)
        #expect(value.effort == .standard)
        #expect(value.sessionID == "session-1")
        #expect(value.turnID == 7)
        #expect(value.taskID == "task-1")
        #expect(value.workspaceID == "workspace-1")
        #expect(value.policyRevision == "facts-1")
    }

    @Test("empty legacy policy identity fails closed before the base")
    func emptyLegacyRevisionIsRejected() async throws {
        let probe = CountingToolExecutor()
        let executor = ComposerPolicyEnforcedToolExecutor(
            base: probe,
            controller: ComposerAuthorizationController(
                snapshot: snapshot(mode: .auto, policyRevision: ""),
                facts: facts(),
                now: { now }
            )
        )

        await #expect(throws: ComposerAuthorizationError.policyRevisionMismatch) {
            try await executor.execute(
                name: "file_read",
                input: ["path": "/tmp/workspace/file.txt"]
            )
        }
        #expect(probe.executionCount == 0)
    }

    @Test("tool input is a frozen Sendable value tree, not a mutable Any graph")
    func inputSnapshotFreezesAtTheBoundary() throws {
        var source: [String: Any] = [
            "path": "/tmp/workspace/file.txt",
            "nested": ["label": "before"]
        ]
        let frozen = try ComposerToolInput(source)
        source["path"] = "/tmp/outside/file.txt"

        guard case .string(let path) = frozen.values["path"] else {
            Issue.record("expected frozen path string")
            return
        }
        #expect(path == "/tmp/workspace/file.txt")
        let expectedDigest = try ComposerToolInput([
            "path": "/tmp/workspace/file.txt",
            "nested": ["label": "before"]
        ]).digest
        #expect(frozen.digest == expectedDigest)

        final class MutableReference {}
        #expect(throws: ComposerAuthorizationError.invalidInput) {
            _ = try ComposerToolInput(["reference": MutableReference()])
        }
        #expect(throws: ComposerAuthorizationError.invalidInput) {
            _ = try ComposerToolInput(["overflow": UInt64.max])
        }
    }

    @Test("all five modes and four scopes preserve one frozen snapshot")
    func fiveByFourModeScopeMatrix() async throws {
        for mode in ComposerTaskMode.allCases {
            for scope in ComposerApprovalScope.allCases {
                let delegate = RecordingApprovalDelegate(decision: .approve)
                let original = snapshot(
                    mode: mode,
                    scope: scope,
                    taskID: "\(mode.rawValue)-\(scope.rawValue)"
                )
                let controller = ComposerAuthorizationController(
                    snapshot: original,
                    facts: facts(),
                    grants: ComposerApprovalGrantStore(),
                    now: { now }
                )
                let probe = CountingToolExecutor()
                let executor = ComposerPolicyEnforcedToolExecutor(
                    base: probe,
                    controller: controller,
                    approvalGate: ApprovalGate(policy: .autoApprove, delegate: delegate)
                )

                let output = try await executor.execute(
                    callID: "call-\(mode.rawValue)-\(scope.rawValue)",
                    name: "file_write",
                    input: try ComposerToolInput([
                        "path": "/tmp/workspace/\(mode.rawValue)-\(scope.rawValue).txt",
                        "content": "matrix"
                    ])
                )

                let after = await controller.snapshot
                #expect(after == original)
                if mode == .plan {
                    #expect(output.contains("dry-run"))
                    #expect(probe.executionCount == 0)
                    #expect(await delegate.requests.count == 0)
                } else {
                    #expect(output == "executed")
                    #expect(probe.executionCount == 1)
                    let expectedApprovalCount = mode == .manual ? 1 : 0
                    #expect(await delegate.requests.count == expectedApprovalCount)
                }
            }
        }
    }

    @Test("approval grants stay inside request, turn, session and workspace scope")
    func grantScopesDoNotLeakAcrossIdentities() async throws {
        let delegate = RecordingApprovalDelegate(decision: .approve)
        let gate = ApprovalGate(delegate: delegate)
        let grants = ComposerApprovalGrantStore()

        let requestController = ComposerAuthorizationController(
            snapshot: snapshot(mode: .manual, scope: .request),
            facts: facts(),
            grants: grants,
            now: { now }
        )
        let requestProbe = CountingToolExecutor()
        let requestExecutor = ComposerPolicyEnforcedToolExecutor(
            base: requestProbe,
            controller: requestController,
            approvalGate: gate
        )
        _ = try await requestExecutor.execute(
            callID: "scope-request-1",
            name: "file_write",
            input: ["path": "/tmp/workspace/request-1.txt"]
        )
        _ = try await requestExecutor.execute(
            callID: "scope-request-2",
            name: "file_write",
            input: ["path": "/tmp/workspace/request-2.txt"]
        )
        #expect(await delegate.requests.count == 2)

        let turnController = ComposerAuthorizationController(
            snapshot: snapshot(mode: .manual, scope: .turn, turnID: 9),
            facts: facts(),
            grants: grants,
            now: { now }
        )
        let turnExecutor = ComposerPolicyEnforcedToolExecutor(
            base: CountingToolExecutor(),
            controller: turnController,
            approvalGate: gate
        )
        _ = try await turnExecutor.execute(
            callID: "scope-turn-1",
            name: "file_write",
            input: ["path": "/tmp/workspace/turn-1.txt"]
        )
        let nextTurnController = ComposerAuthorizationController(
            snapshot: snapshot(mode: .manual, scope: .turn, turnID: 10),
            facts: facts(),
            grants: grants,
            now: { now }
        )
        _ = try await ComposerPolicyEnforcedToolExecutor(
            base: CountingToolExecutor(),
            controller: nextTurnController,
            approvalGate: gate
        ).execute(
            callID: "scope-turn-2",
            name: "file_write",
            input: ["path": "/tmp/workspace/turn-2.txt"]
        )
        #expect(await delegate.requests.count == 4)

        let sessionController = ComposerAuthorizationController(
            snapshot: snapshot(mode: .manual, scope: .session, sessionID: "session-A"),
            facts: facts(),
            grants: grants,
            now: { now }
        )
        _ = try await ComposerPolicyEnforcedToolExecutor(
            base: CountingToolExecutor(),
            controller: sessionController,
            approvalGate: gate
        ).execute(
            callID: "scope-session-a",
            name: "file_write",
            input: ["path": "/tmp/workspace/session-a.txt"]
        )
        let otherSessionController = ComposerAuthorizationController(
            snapshot: snapshot(mode: .manual, scope: .session, sessionID: "session-B"),
            facts: facts(),
            grants: grants,
            now: { now }
        )
        _ = try await ComposerPolicyEnforcedToolExecutor(
            base: CountingToolExecutor(),
            controller: otherSessionController,
            approvalGate: gate
        ).execute(
            callID: "scope-session-b",
            name: "file_write",
            input: ["path": "/tmp/workspace/session-b.txt"]
        )
        #expect(await delegate.requests.count == 6)

        let workspaceOne = ComposerAuthorizationController(
            snapshot: snapshot(mode: .manual, scope: .workspace, workspaceID: "workspace-1"),
            facts: facts(),
            grants: grants,
            now: { now }
        )
        _ = try await ComposerPolicyEnforcedToolExecutor(
            base: CountingToolExecutor(),
            controller: workspaceOne,
            approvalGate: gate
        ).execute(
            callID: "scope-workspace-1",
            name: "file_write",
            input: ["path": "/tmp/workspace/workspace-1.txt"]
        )
        _ = ComposerAuthorizationController(
            snapshot: snapshot(mode: .manual, scope: .workspace, workspaceID: "workspace-2"),
            facts: facts(),
            grants: grants,
            now: { now }
        )
        let workspaceTwoFacts = ComposerPolicyFactSource(
            knownCapabilities: ["file_write"],
            grantedCapabilities: ["file_write"],
            allowedWriteRoots: ["/tmp/workspace"],
            workspaceID: "workspace-2",
            revision: "facts-1",
            leaseID: "lease-workspace-2",
            expiresAt: now.addingTimeInterval(600), autonomyCeiling: .l3
        )
        _ = try await ComposerPolicyEnforcedToolExecutor(
            base: CountingToolExecutor(),
            controller: ComposerAuthorizationController(
                snapshot: snapshot(mode: .manual, scope: .workspace, workspaceID: "workspace-2"),
                facts: workspaceTwoFacts,
                grants: grants,
                now: { now }
            ),
            approvalGate: gate
        ).execute(
            callID: "scope-workspace-2",
            name: "file_write",
            input: ["path": "/tmp/workspace/workspace-2.txt"]
        )
        #expect(await delegate.requests.count == 8)
    }

    @Test("approval grants do not survive a lease replacement")
    func grantDoesNotCrossLeaseIdentity() async throws {
        let delegate = RecordingApprovalDelegate(decision: .approve)
        let gate = ApprovalGate(delegate: delegate)
        let grants = ComposerApprovalGrantStore()
        let original = snapshot(mode: .manual, scope: .session, sessionID: "lease-session")

        let firstProbe = CountingToolExecutor()
        let firstController = ComposerAuthorizationController(
            snapshot: original,
            facts: facts(leaseID: "lease-original"),
            grants: grants,
            now: { now }
        )
        _ = try await ComposerPolicyEnforcedToolExecutor(
            base: firstProbe,
            controller: firstController,
            approvalGate: gate
        ).execute(
            callID: "call-original",
            name: "file_write",
            input: ["path": "/tmp/workspace/original.txt"]
        )

        let replacementProbe = CountingToolExecutor()
        let replacementController = ComposerAuthorizationController(
            snapshot: original,
            facts: facts(leaseID: "lease-replacement"),
            grants: grants,
            now: { now }
        )
        _ = try await ComposerPolicyEnforcedToolExecutor(
            base: replacementProbe,
            controller: replacementController,
            approvalGate: gate
        ).execute(
            callID: "call-replacement",
            name: "file_write",
            input: ["path": "/tmp/workspace/replacement.txt"]
        )

        #expect(await delegate.requests.count == 2)
        #expect(firstProbe.executionCount == 1)
        #expect(replacementProbe.executionCount == 1)
    }

    @Test("scoped consent needs a new task lease and unchanged risk, authority and lifetime")
    func scopedConsentKeepsFreshLeaseAndAuthorityBoundary() async throws {
        let grants = ComposerApprovalGrantStore()
        let capabilities: Set<String> = ["file_read", "file_write", "file_edit", "shell_execute"]
        func policyFacts(
            epoch: String, lease: String, roots: [String] = ["/tmp/workspace"],
            expiresAt: Date
        ) -> ComposerPolicyFactSource {
            ComposerPolicyFactSource(
                knownCapabilities: capabilities, grantedCapabilities: capabilities,
                allowedWriteRoots: roots, workspaceID: "workspace-1", revision: "facts-1",
                grantEpoch: epoch, leaseID: lease, expiresAt: expiresAt, autonomyCeiling: .l3
            )
        }
        let original = ComposerAuthorizationController(
            snapshot: snapshot(mode: .manual, scope: .workspace,
                               taskID: "task-approved", grantEpoch: "epoch-approved"),
            facts: policyFacts(epoch: "epoch-approved", lease: "lease-approved",
                               expiresAt: now.addingTimeInterval(600)),
            grants: grants, now: { now }
        )
        let ordinary = try ComposerToolInput(["path": "/tmp/workspace/ordinary.txt"])
        try await original.recordApproval(capability: "file_write", input: ordinary)

        let sameTaskNewLease = ComposerAuthorizationController(
            snapshot: snapshot(mode: .manual, scope: .workspace,
                               taskID: "task-approved", grantEpoch: "epoch-next"),
            facts: policyFacts(epoch: "epoch-next", lease: "lease-next",
                               expiresAt: now.addingTimeInterval(1200)),
            grants: grants, now: { now }
        )
        #expect(try await sameTaskNewLease.authorize(capability: "file_write", input: ordinary)
                == .requestApproval(requiresSecondConfirmation: false))

        let fresh = ComposerAuthorizationController(
            snapshot: snapshot(mode: .manual, scope: .workspace,
                               taskID: "task-next", grantEpoch: "epoch-next"),
            facts: policyFacts(epoch: "epoch-next", lease: "lease-next",
                               expiresAt: now.addingTimeInterval(1200)),
            grants: grants, now: { now }
        )
        #expect(try await fresh.authorize(capability: "file_write", input: ordinary) == .execute)
        let sensitive = try ComposerToolInput(["path": "/tmp/workspace/.env"])
        #expect(try await fresh.authorize(capability: "file_write", input: sensitive)
                == .requestApproval(requiresSecondConfirmation: false))

        let widenedAuthority = ComposerAuthorizationController(
            snapshot: snapshot(mode: .manual, scope: .workspace,
                               taskID: "task-next", grantEpoch: "epoch-next"),
            facts: policyFacts(epoch: "epoch-next", lease: "lease-next",
                               roots: ["/tmp/workspace", "/tmp/other"],
                               expiresAt: now.addingTimeInterval(1200)),
            grants: grants, now: { now }
        )
        #expect(try await widenedAuthority.authorize(capability: "file_write", input: ordinary)
                == .requestApproval(requiresSecondConfirmation: false))

        let afterOriginalExpiry = ComposerAuthorizationController(
            snapshot: snapshot(mode: .manual, scope: .workspace,
                               taskID: "task-later", grantEpoch: "epoch-later"),
            facts: policyFacts(epoch: "epoch-later", lease: "lease-later",
                               expiresAt: now.addingTimeInterval(1200)),
            grants: grants, now: { now.addingTimeInterval(601) }
        )
        #expect(try await afterOriginalExpiry.authorize(capability: "file_write", input: ordinary)
                == .requestApproval(requiresSecondConfirmation: false))
        await grants.revokeAll()
        #expect(try await fresh.authorize(capability: "file_write", input: ordinary)
                == .requestApproval(requiresSecondConfirmation: false))
    }

    @Test("legacy workspace scope does not reuse manual web fetch approval")
    func workspaceWebFetchConsentIsPerRequestAcrossLeases() async throws {
        let capability = WebFetchToolContract.toolName
        let domains: Set<String> = ["first.example", "second.example"]
        let transport = WebFetchTransport(allowedDomains: domains, load: { url in
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/plain; charset=utf-8"])!
            return WebFetchHop(response: response, body: Data("synthetic web content".utf8))
        })
        let owner = BuiltinToolExecutor(allowedRoot: FileManager.default.temporaryDirectory,
            webFetch: transport)
        owner.registerToolNames([capability])
        let delegate = RecordingApprovalDelegate(decision: .approve)
        let gate = ApprovalGate(delegate: delegate)
        let grants = ComposerApprovalGrantStore()

        func executor(task: String, epoch: String, lease: String) -> ComposerPolicyEnforcedToolExecutor {
            let controller = ComposerAuthorizationController(
                snapshot: snapshot(mode: .manual, scope: .workspace, taskID: task, grantEpoch: epoch),
                facts: facts(granted: [capability], grantEpoch: epoch, leaseID: lease),
                grants: grants, now: { now }
            )
            return ComposerPolicyEnforcedToolExecutor(base: owner, controller: controller, approvalGate: gate)
        }

        let original = executor(task: "approved-task", epoch: "approved-epoch", lease: "approved-lease")
        let fresh = executor(task: "fresh-task", epoch: "fresh-epoch", lease: "fresh-lease")
        let approvedURL = try ComposerToolInput(["url": "https://first.example/approved"])
        let sameHost = try ComposerToolInput(["url": "https://FIRST.example/another"])
        let otherHost = try ComposerToolInput(["url": "https://second.example/page"])
        let approval = ComposerAuthorizationDecision.requestApproval(requiresSecondConfirmation: false)

        let output = try await original.execute(callID: "approve-first", name: capability, input: approvedURL)
        try #require(output.contains("synthetic web content"))
        try #require(await delegate.requests.count == 1)
        #expect(try await original.authorizationDecision(callID: "same-lease-same-host",
            capability: capability, input: sameHost).decision == approval)
        #expect(try await fresh.authorizationDecision(callID: "new-lease-same-host",
            capability: capability, input: sameHost).decision == approval)
        #expect(try await original.authorizationDecision(callID: "same-lease-other-host",
            capability: capability, input: otherHost).decision == approval)
        #expect(try await fresh.authorizationDecision(callID: "new-lease-other-host",
            capability: capability, input: otherHost).decision == approval)
    }

    @Test("unknown capability, missing grant and out-of-bound write never call the base")
    func policyRejectsBeforeExecutor() async throws {
        let probe = CountingToolExecutor()
        let controller = ComposerAuthorizationController(
            snapshot: snapshot(mode: .bypassPermission),
            facts: facts(granted: ["file_read"]),
            now: { now }
        )
        let executor = ComposerPolicyEnforcedToolExecutor(
            base: probe,
            controller: controller
        )

        await #expect(throws: ComposerAuthorizationError.self) {
            try await executor.execute(name: "unknown_capability", input: [:])
        }
        await #expect(throws: ComposerAuthorizationError.self) {
            try await executor.execute(
                name: "file_write",
                input: ["path": "/tmp/workspace/file.txt"]
            )
        }

        // 合同变更（用户 2026-10-22 决定）：绕过模式不再受授权根限制，任意路径可写；
        // 因此"授权根外写入被策略挡在执行器之前"这条断言改在 .auto 模式上验证（该模式仍受授权根约束）。
        let boundedController = ComposerAuthorizationController(
            snapshot: snapshot(mode: .auto),
            facts: facts(),
            now: { now }
        )
        let boundedExecutor = ComposerPolicyEnforcedToolExecutor(
            base: probe,
            controller: boundedController
        )
        await #expect(throws: ComposerAuthorizationError.self) {
            try await boundedExecutor.execute(
                name: "file_write",
                input: ["path": "/tmp/outside/file.txt"]
            )
        }
        #expect(probe.executionCount == 0)
    }

    @Test("plan mode returns dry-run for side effects without touching the executor")
    func planIsDryRun() async throws {
        let probe = CountingToolExecutor()
        let controller = ComposerAuthorizationController(
            snapshot: snapshot(mode: .plan),
            facts: facts(),
            now: { now }
        )
        let executor = ComposerPolicyEnforcedToolExecutor(
            base: probe,
            controller: controller
        )

        let output = try await executor.execute(
            name: "file_write",
            input: ["path": "/tmp/workspace/file.txt"]
        )

        #expect(output.contains("dry-run"))
        #expect(probe.executionCount == 0)
    }

    @Test("an approved archive cannot cover a second session's archive")
    func foreignArchiveCannotReuseAConversationSettingsGrant() async throws {
        let tool = BL6SettingsToolApproval.toolName
        let submission = ComposerSubmissionSnapshot(
            mode: .manual, approvalScope: .session, effort: .standard,
            sessionID: "archive-caller", turnID: 7, taskID: "archive-task",
            attemptID: "archive-attempt", messageID: "archive-message",
            workspaceID: "workspace-1", createdAt: now, policyRevision: "facts-1",
            autonomyCeiling: .l3
        )
        let controller = ComposerAuthorizationController(
            snapshot: submission, facts: facts(granted: [tool]), now: { now }
        )
        let delegate = RecordingApprovalDelegate(decision: .approve)
        let executor = ComposerPolicyEnforcedToolExecutor(
            base: CountingToolExecutor(), controller: controller,
            approvalGate: ApprovalGate(delegate: delegate)
        )
        for (index, target) in [UUID(), UUID()].enumerated() {
            let key = "session.\(target.uuidString).archived"
            let typed = BL6SettingsApprovedInput(
                operation: .apply, changes: [key: .toggle(true)],
                expectedRevision: "revision-\(index)"
            )
            let encoded = try JSONEncoder().encode(typed)
            let input = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            let decoded = try JSONDecoder().decode(BL6SettingsApprovedInput.self, from: encoded)
            try decoded.validateForApprovedEffect()
            try #require(decoded == typed)
            _ = try await executor.authorizeExecution(
                callID: "archive-\(index)", name: tool, input: input
            )
            if index == 0 { try #require(await delegate.requests.count == 1) }
        }
        let requests = await delegate.requests
        #expect(requests.count == 2)
    }

    @Test(arguments: ["bypass-after-web", "bypass-without-external-input", "manual",
                      "failed-read", "prior-turn", "other-session", "mixed-case-browser"])
    func skillUpdateApprovalFollowsSettledExternalReadInCurrentAttempt(scenario: String) async throws {
        let mode: ComposerTaskMode = scenario == "manual" ? .manual : .bypassPermission
        let submission = snapshot(mode: mode)
        let tool = "skill_update"
        let controller = ComposerAuthorizationController(
            snapshot: submission, facts: facts(granted: [tool, WebFetchToolContract.toolName]),
            now: { now }, liveSkillBypassConfirmed: { mode == .bypassPermission }
        )
        let executor = ComposerPolicyEnforcedToolExecutor(
            base: CountingToolExecutor(), controller: controller,
            approvalGate: ApprovalGate(policy: .alwaysAsk)
        )
        let identity = AgentExecutionIdentity(
            turn: AgentTurnIdentity(sessionID: submission.sessionID, turnID: submission.turnID,
                messageID: submission.messageID),
            operationID: "skill-review-owned-operation", attempt: 1
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = try ToolExecutionFactLedger(persistenceURL: directory.appendingPathComponent("facts.json"))
        let attemptID = try #require(AgentToolExecutionAttemptID.canonical(
            executionIdentity: identity, composerSnapshot: submission, childBoundary: nil))
        if ["bypass-after-web", "failed-read", "prior-turn", "other-session", "mixed-case-browser"].contains(scenario) {
            let readIdentity = AgentExecutionIdentity(
                turn: AgentTurnIdentity(sessionID: scenario == "other-session" ? "foreign-session" : submission.sessionID,
                                        turnID: scenario == "prior-turn" ? submission.turnID - 1 : submission.turnID,
                                        messageID: submission.messageID),
                operationID: identity.operationID, attempt: identity.attempt)
            let read = try ledger.mint(toolCallID: "owned-read",
                toolName: scenario == "mixed-case-browser" ? "Browser_Use" : WebFetchToolContract.toolName,
                attemptID: attemptID, attemptNumber: readIdentity.attempt, executionIdentity: readIdentity)
            let status: ToolExecutionStatus = scenario == "failed-read" ? .failed : .succeeded
            _ = try ledger.settle(read, status: status)
            try #require(ledger.facts.contains { $0.toolCallID == read.toolCallID && $0.status == status })
        }
        let edit = try ledger.mint(toolCallID: "owned-edit", toolName: tool,
            attemptID: attemptID, attemptNumber: identity.attempt, executionIdentity: identity)
        let input = try ComposerToolInput([
            "skillID": "synthetic-skill", "content": "Synthetic instruction",
            "expectedContentHash": String(repeating: "a", count: 64)
        ])
        let decision = try await ToolExecutionReceiptContext.$ledger.withValue(ledger) {
            try await ToolExecutionReceiptContext.$current.withValue(edit) {
                try await executor.authorizationDecision(callID: edit.toolCallID, capability: tool, input: input).decision
            }
        }
        switch scenario {
        case "bypass-after-web", "mixed-case-browser", "bypass-without-external-input", "failed-read", "prior-turn", "other-session":
            // 2026-11-15 用户决定：绕过就是绕过，读过外部内容后改技能也直接执行。
            #expect(decision == .execute)
        default:
            #expect(decision == .requestApproval(requiresSecondConfirmation: false))
        }
        _ = try ledger.settle(edit, status: .cancelled)
    }

    @Test func skillUpdateAfterMountedOutsideProjectReadCannotReusePersistentRule() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project", isDirectory: true)
        let mounted = root.appendingPathComponent("mounted", isDirectory: true)
        for directory in [project, mounted] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        let readTarget = mounted.appendingPathComponent("sample.txt")
        try Data("Owned synthetic input".utf8).write(to: readTarget)
        let roots = [project.resolvingSymlinksInPath().path, mounted.resolvingSymlinksInPath().path]
        try #require(PolicyRuntimePathBoundary.isWithinRoots(path: readTarget.path, roots: roots))
        try #require(!PolicyRuntimePathBoundary.isWithinRoots(path: readTarget.path, roots: [roots[0]]))

        let tool = "skill_update"
        let submission = snapshot(mode: .bypassPermission)
        let authority = ComposerPolicyFactSource(knownCapabilities: [tool, "file_read"],
            grantedCapabilities: [tool, "file_read"], allowedWriteRoots: roots,
            workspaceID: submission.workspaceID, revision: submission.policyRevision,
            grantEpoch: submission.grantEpoch, leaseID: "owned-lease",
            expiresAt: now.addingTimeInterval(600), autonomyCeiling: .l3, trustedProjectRoot: roots[0])
        let rules = PersistentApprovalRuleStore(fileURL: root.appendingPathComponent("rules.json"))
        let rule = try #require(rules.makeSkillBypassRule(capability: tool, facts: authority))
        try #require(rules.add(rule))
        let controller = ComposerAuthorizationController(snapshot: submission, facts: authority,
            grants: ComposerApprovalGrantStore(persistentRules: rules), now: { now }, liveSkillBypassConfirmed: { true })
        let executor = ComposerPolicyEnforcedToolExecutor(base: CountingToolExecutor(), controller: controller,
            approvalGate: ApprovalGate(policy: .alwaysAsk))
        let identity = AgentExecutionIdentity(
            turn: AgentTurnIdentity(sessionID: submission.sessionID, turnID: submission.turnID,
                                    messageID: submission.messageID),
            operationID: "owned-mounted-read", attempt: 1)
        let ledger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts.json"))
        let attemptID = try #require(AgentToolExecutionAttemptID.canonical(
            executionIdentity: identity, composerSnapshot: submission, childBoundary: nil))
        let editInput = try ComposerToolInput(["skillID": "synthetic-skill", "content": "Synthetic",
            "expectedContentHash": String(repeating: "a", count: 64)])
        let baseline = try await executor.authorizationDecision(callID: "baseline", capability: tool, input: editInput)
        try #require(baseline.rule == rule)
        let read = try ledger.mint(toolCallID: "read", toolName: "file_read",
            attemptID: attemptID, attemptNumber: identity.attempt, executionIdentity: identity)
        let edit = try ledger.mint(toolCallID: "edit", toolName: tool,
            attemptID: attemptID, attemptNumber: identity.attempt, executionIdentity: identity)
        try await ToolExecutionReceiptContext.$ledger.withValue(ledger) {
            let readInput = try ComposerToolInput(["path": readTarget.path])
            let readDecision = try await ToolExecutionReceiptContext.$current.withValue(read) {
                try await executor.authorizationDecision(callID: read.toolCallID, capability: read.toolName, input: readInput)
            }
            try #require(readDecision.decision == .execute)
            _ = try ledger.settle(read, status: .succeeded)
            let decision = try await ToolExecutionReceiptContext.$current.withValue(edit) {
                try await executor.authorizationDecision(callID: edit.toolCallID, capability: tool, input: editInput)
            }
            // 2026-11-15 用户决定：绕过档不再为外部读取额外弹卡；直接执行，是否沿用持久规则不再影响结果。
            #expect(decision.decision == .execute)
        }
        _ = try ledger.settle(edit, status: .cancelled)
    }

    @Test("confirmed bypass prompts only for irreversible deletion",
          arguments: ["skill_delete", "browser", "protected-git-write", "conversation_settings",
                      "mcp-interaction", "hook-ask", "external_session_send", "permanent-delete"])
    func confirmedBypassHonorsPermanentDeleteApprovalOnly(scenario: String) async throws {
        let capability: String
        let input: [String: Any]
        switch scenario {
        case "skill_delete":
            capability = scenario
            input = ["skillID": "synthetic-skill", "expectedContentHash": String(repeating: "a", count: 64)]
        case "browser":
            capability = scenario
            input = ["action": "click", "selector": "#synthetic"]
        case "protected-git-write":
            capability = "file_write"
            input = ["path": "/synthetic/project/.git/config", "content": "synthetic"]
        case "conversation_settings":
            capability = BL6SettingsToolApproval.toolName
            input = ["operation": "apply", "changes": ["hooks.entries.remove": "synthetic-hook"]]
        case "mcp-interaction", "hook-ask":
            capability = "file_read"
            input = ["path": "/tmp/workspace/synthetic.txt"]
        case "external_session_send":
            capability = ExternalSessionToolNames.send
            input = ["source": "codex", "session": UUID().uuidString, "message": "synthetic"]
        default:
            capability = "shell_execute"
            input = ["command": "rm -- /tmp/workspace/nonexistent-synthetic.txt"]
        }
        let frozen = try ComposerToolInput(input)
        let unconfirmed = ComposerAuthorizationController(
            snapshot: snapshot(mode: .bypassPermission, bypassModeConfirmed: false),
            facts: facts(granted: [capability], roots: ["/tmp/workspace", "/synthetic/project"]),
            now: { now }
        )
        await #expect(throws: ComposerAuthorizationError.bypassConfirmationRequired) {
            _ = try await unconfirmed.authorize(capability: capability, input: frozen)
        }
        for mode in [ComposerTaskMode.manual, .autoEdit, .auto, .bypassPermission] {
            let controller = ComposerAuthorizationController(
                snapshot: snapshot(mode: mode),
                facts: facts(granted: [capability], roots: ["/tmp/workspace", "/synthetic/project"]),
                now: { now }, liveSkillBypassConfirmed: { mode == .bypassPermission }
            )
            if scenario == "protected-git-write" {
                try await controller.revalidate(capability: capability, input: frozen)
                try #require(await controller.requiresProtectedGitWriteApproval(capability: capability, input: frozen))
            }
            let decision: ComposerAuthorizationDecision
            if scenario == "mcp-interaction" {
                decision = try await controller.authorizeResolvingRule(
                    capability: capability, input: frozen, mandatoryHuman: true
                ).decision
            } else {
                let executor = ComposerPolicyEnforcedToolExecutor(
                    base: CountingToolExecutor(), controller: controller,
                    approvalGate: ApprovalGate(policy: .alwaysAsk), hookHandler: { invocation in
                        return ComposerHookResult(
                            verdict: scenario == "hook-ask" ? .ask : .allow,
                            invocationIdentityDigest: invocation.identityDigest,
                            hasDecision: scenario == "hook-ask"
                        )
                    }
                )
                decision = try await executor.authorizationDecision(
                    callID: "bypass-\(scenario)", capability: capability, input: frozen
                ).decision
            }
            if mode == .bypassPermission && scenario != "permanent-delete" {
                #expect(decision == .execute, "confirmed bypass should execute \(scenario)")
            } else if case .requestApproval = decision {
                // The non-bypass approval contract remains available.
            } else {
                Issue.record("\(mode) must request approval for \(scenario), got \(decision)")
            }
        }
    }

    @Test("legacy unattended policy restores ordinary strategy on a child copy")
    func unattendedCompatibilityDoesNotInheritIntoChildGate() {
        let delegate = RecordingApprovalDelegate(decision: .approve)
        var ordinary = ApprovalGate(policy: .alwaysAsk, delegate: delegate, onApprovalReceipt: { _ in })
        ordinary.setPolicy(.deny, for: "web_search")
        ordinary.setPolicy(.alwaysAsk, for: "file_edit")
        ordinary.setGloballyDerivedSessionCreatePolicy(.alwaysAsk)
        let prepared = ordinary.applyingLegacyUnattendedAutoApproval().applyingLegacyUnattendedAutoApproval()
        #expect(prepared.policy(for: "file_write") == .autoApprove)
        #expect(prepared.policy(for: "browser") == .alwaysAsk)
        #expect(prepared.policy(for: "session_create") == .autoApprove)
        #expect(prepared.policy(for: "web_search") == .deny)
        #expect(prepared.policy(for: "file_edit") == .alwaysAsk)
        var explicitlyTightened = ordinary
        explicitlyTightened.setPolicy(.alwaysAsk, for: "session_create")
        #expect(explicitlyTightened.applyingLegacyUnattendedAutoApproval().policy(for: "session_create") == .alwaysAsk)
        explicitlyTightened = ordinary
        explicitlyTightened.policyByTool["session_create"] = .alwaysAsk
        let dictionaryCompatibility = explicitlyTightened.applyingLegacyUnattendedAutoApproval()
        #expect(dictionaryCompatibility.policy(for: "session_create") == .alwaysAsk)
        #expect(dictionaryCompatibility.policy(for: "file_write") == .alwaysAsk)
        let child = prepared.restoringOrdinaryChildPolicy()
        #expect(child.policyByTool == ordinary.policyByTool)
        #expect(child.onApprovalReceipt != nil)
        #expect(child.applyingLegacyUnattendedAutoApproval().policy(for: "session_create") == .autoApprove)
        #expect((child.delegate as? RecordingApprovalDelegate) === delegate)
        let input = ["path": "/tmp/workspace/synthetic.txt", "content": "synthetic"]
        #expect(!child.shouldAsk(tool: "file_write", input: input, deferringGlobalFilePromptToComposer: true))
        #expect(child.shouldAsk(tool: "file_edit", input: input, deferringGlobalFilePromptToComposer: true))
        #expect(prepared.policy(for: "file_write") == .autoApprove)
        #expect(prepared.policy(for: "browser") == .alwaysAsk)
        #expect(prepared.policy(for: "session_create") == .autoApprove)
    }

    @Test("revoked unattended compatibility cannot change files",
          arguments: ["file_write", "file_edit"])
    func revokedUnattendedCompatibilityCannotWrite(tool: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("owned.txt")
        try "before".write(to: file, atomically: true, encoding: .utf8)
        let gate = ApprovalGate(policy: .riskOnlyAsk).applyingLegacyUnattendedAutoApproval()
        try #require(gate.liftedUnattendedFileApproval(for: tool))
        let executor = ComposerPolicyEnforcedToolExecutor(
            base: BuiltinToolExecutor(allowedRoot: root, deniedRoots: []),
            controller: ComposerAuthorizationController(snapshot: snapshot(mode: .autoEdit),
                facts: facts(granted: [tool], roots: [root.path]), now: { now }),
            approvalGate: gate
        )
        let input = try ComposerToolInput(["path": file.path, "content": "after",
                                           "old_string": "before", "new_string": "after"])
        let revoked = AgentExecutionContextSnapshot(provider: MockLLMProvider(responses: []),
            approvalGate: gate, turnController: nil, currentConversationID: nil,
            makeChildBudget: nil, deadline: nil, parentAuthorityCheck: { false })
        await AgentExecutionContext.$current.withValue(revoked) {
            await #expect(throws: ComposerAuthorizationError.authorizationRevoked) {
                _ = try await executor.execute(callID: "revoked-compatibility", name: tool, input: input)
            }
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "before")
        let active = AgentExecutionContextSnapshot(provider: MockLLMProvider(responses: []),
            approvalGate: gate, turnController: nil, currentConversationID: nil,
            makeChildBudget: nil, deadline: nil, parentAuthorityCheck: { true })
        try await AgentExecutionContext.$current.withValue(active) {
            _ = try await executor.execute(callID: "active-compatibility", name: tool, input: input)
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "after")
    }

    @Test("confirmed bypass preserves credential, system, app-data, and keychain hard refusals",
          arguments: ["rm -- ~/.ssh/id_rsa", "rm -- /System/Library/synthetic",
                      "rm -- ~/Library/Application\\ Support/MinisCore/synthetic",
                      "security find-generic-password -s synthetic"])
    func confirmedBypassHardFloorsRejectBeforeApproval(command: String) async throws {
        let controller = ComposerAuthorizationController(
            snapshot: snapshot(mode: .bypassPermission), facts: facts(), now: { now }
        )
        let input = try ComposerToolInput(["command": command])
        do {
            _ = try await controller.authorize(capability: "shell_execute", input: input)
            Issue.record("Expected a hard refusal before approval")
        } catch let error as ComposerAuthorizationError {
            guard case .approvalDenied = error else {
                Issue.record("Expected approvalDenied, got \(error)")
                return
            }
        }
    }

    @Test("confirmed bypass preserves an explicit hook denial")
    func confirmedBypassDoesNotOverrideHookDeny() async throws {
        let controller = ComposerAuthorizationController(
            snapshot: snapshot(mode: .bypassPermission), facts: facts(), now: { now }
        )
        let executor = ComposerPolicyEnforcedToolExecutor(
            base: CountingToolExecutor(), controller: controller,
            approvalGate: ApprovalGate(), hookHandler: { invocation in
                ComposerHookResult(
                    verdict: .deny, invocationIdentityDigest: invocation.identityDigest,
                    reason: "synthetic hook denied the call"
                )
            }
        )
        let input = try ComposerToolInput(["path": "/tmp/workspace/synthetic.txt"])
        await #expect(throws: ComposerAuthorizationError.hookRejected("synthetic hook denied the call")) {
            _ = try await executor.authorizationDecision(
                callID: "bypass-hook-denied", capability: "file_read", input: input
            )
        }
    }

    @Test("confirmed bypass uses no per-call prompt or second confirmation")
    func confirmedBypassHasNoPerCallSecondConfirmation() async throws {
        let delegate = RecordingApprovalDelegate(decision: ApprovalDecision(approved: true, confirmed: false))
        let gate = ApprovalGate(delegate: delegate)
        let controller = ComposerAuthorizationController(
            snapshot: snapshot(mode: .bypassPermission),
            facts: facts(),
            now: { now }
        )
        let probe = CountingToolExecutor()
        let executor = ComposerPolicyEnforcedToolExecutor(
            base: probe,
            controller: controller,
            approvalGate: gate
        )

        let output = try await executor.execute(
            name: "file_write",
            input: ["path": "/tmp/workspace/file.txt"]
        )
        #expect(output == "executed")
        #expect(await delegate.requests.count == 0)
        #expect(probe.executionCount == 1)
    }

    @Test("BL6 settings asks once per call while other high-risk tools retain the second step")
    func bl6SettingsSingleApprovalPreservesOtherHighRiskSecondStep() async throws {
        let tool = BL6SettingsToolApproval.toolName
        let settingsInput: [String: Any] = ["operation": "apply"]
        let settingsDigest = try #require(ApprovalAuthorizationContext.payloadDigest(for: settingsInput))
        let delegate = RecordingApprovalDelegate(
            decision: ApprovalDecision(approved: true, confirmed: false))
        let gate = ApprovalGate(delegate: delegate)
        func context(_ effectID: String, toolName: String, digest: String) -> ApprovalAuthorizationContext {
            ApprovalAuthorizationContext(
                actorID: "policy05-fixture-actor", sessionID: "policy05-fixture-session",
                turnID: 1, taskID: "policy05-fixture-task", runID: "policy05-fixture-run",
                attemptID: "policy05-fixture-attempt", effectID: effectID,
                scope: "policy05-fixture-scope", payloadDigest: digest,
                expiresAt: Date().addingTimeInterval(60), policyRevision: "policy05-fixture-policy",
                grantEpoch: "policy05-fixture-epoch", toolName: toolName
            )
        }
        #expect(gate.policy(for: tool) == .alwaysAsk)
        let rawSettings = gate.makeRequest(id: "settings-raw", tool: tool, input: settingsInput)
        #expect(rawSettings.riskLevel == .high)
        #expect(rawSettings.requiresApproval && !rawSettings.requiresSecondConfirmation)
        let firstContext = context("settings-effect-1", toolName: tool, digest: settingsDigest)
        let boundSettings = gate.makeBoundRequest(id: firstContext.effectID, tool: tool,
            input: settingsInput, context: firstContext)
        #expect(boundSettings.requiresApproval && !boundSettings.requiresSecondConfirmation)
        _ = try await gate.approveBL6SettingsCall(input: settingsInput, context: firstContext)
        let secondContext = context("settings-effect-2", toolName: tool, digest: settingsDigest)
        _ = try await gate.approveBL6SettingsCall(input: settingsInput, context: secondContext)
        let settingsRequests = await delegate.requests
        #expect(settingsRequests.count == 2)
        #expect(settingsRequests.map(\.requestID) ==
            [firstContext.effectID, secondContext.effectID])
        #expect(settingsRequests.allSatisfy { $0.toolName == tool && $0.requiresApproval &&
            !$0.requiresSecondConfirmation && $0.inputDigest != nil && $0.identityDigest != nil })

        let ordinaryHighTool = "file_write"
        let ordinaryInput: [String: Any] = ["path": "/tmp/policy05-synthetic.txt"]
        let ordinaryDigest = try #require(ApprovalAuthorizationContext.payloadDigest(for: ordinaryInput))
        let ordinaryContext = context("ordinary-high-effect", toolName: ordinaryHighTool,
            digest: ordinaryDigest)
        let ordinaryRequest = gate.makeBoundRequest(id: ordinaryContext.effectID,
            tool: ordinaryHighTool, input: ordinaryInput, context: ordinaryContext)
        #expect(ordinaryRequest.riskLevel == .high)
        #expect(ordinaryRequest.requiresApproval && ordinaryRequest.requiresSecondConfirmation)
        await #expect(throws: ApprovalError.self) {
            _ = try await gate.gate(tool: ordinaryHighTool, input: ordinaryInput,
                context: ordinaryContext, delegate: delegate)
        }
        let allRequests = await delegate.requests
        #expect(allRequests.count == 3)
        #expect(allRequests.last?.requiresSecondConfirmation == true)
    }

    @Test("bypass permission requires the Composer acknowledgement before approval")
    func bypassRequiresComposerAcknowledgement() async throws {
        let delegate = RecordingApprovalDelegate(decision: .approve)
        let controller = ComposerAuthorizationController(
            snapshot: snapshot(
                mode: .bypassPermission,
                bypassModeConfirmed: false
            ),
            facts: facts(),
            now: { now }
        )
        let probe = CountingToolExecutor()
        let executor = ComposerPolicyEnforcedToolExecutor(
            base: probe,
            controller: controller,
            approvalGate: ApprovalGate(delegate: delegate)
        )

        await #expect(throws: ComposerAuthorizationError.bypassConfirmationRequired) {
            try await executor.execute(
                name: "file_write",
                input: ["path": "/tmp/workspace/file.txt"]
            )
        }
        #expect(await delegate.requests.count == 0)
        #expect(probe.executionCount == 0)
    }

    @Test("expired and revoked facts fail closed even when the mode bypasses permission")
    func staleFactsAreRejected() async throws {
        let expired = ComposerPolicyFactSource(
            knownCapabilities: ["file_write"],
            grantedCapabilities: ["file_write"],
            allowedWriteRoots: ["/tmp/workspace"],
            workspaceID: "workspace-1",
            revision: "facts-expired",
            leaseID: "lease-expired",
            expiresAt: now.addingTimeInterval(-1), autonomyCeiling: .l3
        )
        let controller = ComposerAuthorizationController(
            snapshot: snapshot(mode: .bypassPermission, policyRevision: "facts-expired"),
            facts: expired,
            now: { now }
        )
        let probe = CountingToolExecutor()
        let executor = ComposerPolicyEnforcedToolExecutor(
            base: probe,
            controller: controller
        )

        await #expect(throws: ComposerAuthorizationError.self) {
            try await executor.execute(
                name: "file_write",
                input: ["path": "/tmp/workspace/file.txt"]
            )
        }
        #expect(probe.executionCount == 0)
    }

    @Test("AgentLoop validates composer authorization before the provider call")
    func expiredComposerFactsBlockProviderBeforeExecution() async throws {
        let expired = ComposerPolicyFactSource(
            knownCapabilities: ["file_read"],
            grantedCapabilities: ["file_read"],
            allowedWriteRoots: ["/tmp/workspace"],
            workspaceID: "workspace-1",
            revision: "facts-expired",
            leaseID: "lease-expired",
            expiresAt: now.addingTimeInterval(-1), autonomyCeiling: .l3
        )
        let submission = snapshot(mode: .auto, policyRevision: "facts-expired")
        let provider = MockLLMProvider(responses: ["done"])
        let executor = ComposerPolicyEnforcedToolExecutor(
            base: CountingToolExecutor(),
            controller: ComposerAuthorizationController(
                snapshot: submission,
                facts: expired,
                now: { now }
            )
        )

        await #expect(throws: ComposerAuthorizationError.factsExpired) {
            _ = try await AgentLoop(maxIterations: 2).run(
                messages: [LLMMessage(role: .user, content: "expired")],
                systemPrompt: nil,
                provider: provider,
                toolExecutor: executor,
                tools: [],
                composerSnapshot: submission
            )
        }
        #expect(provider.receivedHistory.isEmpty)
    }

    @Test("AgentLoop rejects a policy executor bound to another Composer snapshot")
    func composerSnapshotCannotDriftBetweenLoopAndExecutor() async throws {
        let executorSnapshot = snapshot(mode: .auto, taskID: "executor-task")
        let submittedSnapshot = snapshot(mode: .auto, taskID: "submitted-task")
        let provider = MockLLMProvider(responses: ["done"])
        let executor = ComposerPolicyEnforcedToolExecutor(
            base: CountingToolExecutor(),
            controller: ComposerAuthorizationController(
                snapshot: executorSnapshot,
                facts: facts(),
                now: { now }
            )
        )

        await #expect(throws: AgentLoopError.composerSnapshotMismatch) {
            _ = try await AgentLoop(maxIterations: 2).run(
                messages: [LLMMessage(role: .user, content: "drift")],
                systemPrompt: nil,
                provider: provider,
                toolExecutor: executor,
                tools: [],
                composerSnapshot: submittedSnapshot
            )
        }
        #expect(provider.receivedHistory.isEmpty)
    }

    @Test("scope mismatch and revoked facts fail closed")
    func scopeAndRevocationAreEnforced() async throws {
        let mismatchedSnapshot = ComposerSubmissionSnapshot(
            mode: .auto,
            approvalScope: .workspace,
            effort: .standard,
            sessionID: "session-1",
            turnID: 7,
            taskID: "task-1",
            workspaceID: "workspace-2",
            createdAt: now,
            policyRevision: "facts-1", autonomyCeiling: .l3
        )
        let mismatchProbe = CountingToolExecutor()
        let mismatchExecutor = ComposerPolicyEnforcedToolExecutor(
            base: mismatchProbe,
            controller: ComposerAuthorizationController(
                snapshot: mismatchedSnapshot,
                facts: facts(),
                now: { now }
            )
        )
        await #expect(throws: ComposerAuthorizationError.self) {
            try await mismatchExecutor.execute(
                name: "file_read",
                input: ["path": "/tmp/workspace/file.txt"]
            )
        }
        #expect(mismatchProbe.executionCount == 0)

        let revokedFacts = ComposerPolicyFactSource(
            knownCapabilities: ["file_read"],
            grantedCapabilities: ["file_read"],
            allowedWriteRoots: ["/tmp/workspace"],
            workspaceID: "workspace-1",
            revision: "facts-revoked",
            leaseID: "lease-revoked",
            expiresAt: now.addingTimeInterval(600),
            revoked: true, autonomyCeiling: .l3
        )
        let revokedProbe = CountingToolExecutor()
        let revokedExecutor = ComposerPolicyEnforcedToolExecutor(
            base: revokedProbe,
            controller: ComposerAuthorizationController(
                snapshot: snapshot(mode: .auto, policyRevision: "facts-revoked"),
                facts: revokedFacts,
                now: { now }
            )
        )
        await #expect(throws: ComposerAuthorizationError.self) {
            try await revokedExecutor.execute(
                name: "file_read",
                input: ["path": "/tmp/workspace/file.txt"]
            )
        }
        #expect(revokedProbe.executionCount == 0)
    }

    @Test("AgentLoop binds the model call id into the approval request and receipt")
    func agentLoopBindsCallIdentity() async throws {
        let delegate = RecordingApprovalDelegate(decision: .approve)
        let receipts = ReceiptBox()
        let probe = CountingToolExecutor()
        let snapshot = snapshot(mode: .manual, scope: .request)
        let executor = ComposerPolicyEnforcedToolExecutor(
            base: probe,
            controller: ComposerAuthorizationController(
                snapshot: snapshot,
                facts: facts(),
                now: { now }
            ),
            approvalGate: ApprovalGate(delegate: delegate),
            onApprovalReceipt: { receipts.store($0) }
        )
        let root = try minisCoreToolContractRoot("composer-call-identity")
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = minisCoreToolContractIdentity(
            "composer-call-identity",
            sessionID: snapshot.sessionID,
            turnID: snapshot.turnID,
            messageID: snapshot.messageID
        )
        let loop = AgentLoop(
            maxIterations: 2,
            approvalGate: ApprovalGate(delegate: delegate),
            toolExecutionFactLedger: try minisCoreToolContractLedger(at: root)
        )
        let result = try await loop.run(
            messages: [LLMMessage(role: .user, content: "identity")],
            systemPrompt: nil,
            provider: MockLLMProvider(responses: [
                realToolCallEnvelope(
                    id: "call-identity-1",
                    name: "file_write",
                    input: ["path": "/tmp/workspace/file.txt", "content": "x"]
                ),
                "done"
            ]),
            toolExecutor: executor,
            tools: [
                AgentToolDefinition(
                    name: "file_write",
                    description: "Composer contract tool",
                    parameters: [:],
                    required: []
                )
            ],
            executionIdentity: identity
        )

        #expect(result.messages.last?.content == "done")
        #expect(probe.executionCount == 1)
        let request = try #require(await delegate.requests.first)
        #expect(request.id == "call-identity-1")
        #expect(request.requestID == "call-identity-1")
        #expect(request.callID == "call-identity-1")
        #expect(request.messageID == snapshot.messageID)
        #expect(request.policyRevision == "facts-1")
        #expect(request.grantEpoch == "epoch-0")
        #expect(request.identityDigest?.count == 64)
        let expectedInputDigest = try ComposerToolInput([
            "path": "/tmp/workspace/file.txt",
            "content": "x"
        ]).digest
        #expect(request.inputDigest == expectedInputDigest)
        let receipt = try #require(receipts.load())
        #expect(receipt.requestID == "call-identity-1")
        #expect(receipt.callID == "call-identity-1")
        #expect(receipt.messageID == snapshot.messageID)
        #expect(receipt.policyRevision == "facts-1")
        #expect(receipt.grantEpoch == "epoch-0")
        #expect(receipt.inputDigest == request.inputDigest)
        #expect(receipt.identityDigest == request.identityDigest)
        #expect(receipt.receiptDigest.count == 64)
        #expect(receipt.digest == receipt.receiptDigest)
    }

    @Test("approval receipt records the authorization boundary")
    func approvalReceiptCapturesRiskAndLeaseLifecycle() async throws {
        let receipts = ReceiptBox()
        let executor = ComposerPolicyEnforcedToolExecutor(
            base: CountingToolExecutor(),
            controller: ComposerAuthorizationController(
                snapshot: snapshot(mode: .manual),
                facts: facts(),
                now: { now }
            ),
            approvalGate: ApprovalGate(
                delegate: RecordingApprovalDelegate(decision: .approve)
            ),
            onApprovalReceipt: { receipts.store($0) }
        )

        _ = try await executor.execute(
            callID: "call-receipt-boundary",
            name: "file_write",
            input: [
                "path": "/tmp/workspace/receipt.txt",
                "content": "authorization boundary"
            ]
        )

        let receipt = try #require(receipts.load())
        let data = try JSONEncoder().encode(receipt)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["approvalScope"] as? String == ComposerApprovalScope.request.rawValue)
        #expect(object["riskLevel"] as? String == ApprovalRiskLevel.high.rawValue)
        #expect((object["leaseID"] as? String)?.isEmpty == false)
        #expect(object["leaseExpiresAt"] != nil)
        #expect(object["leaseRevoked"] as? Bool == false)
        #expect((object["identityDigest"] as? String)?.count == 64)
    }

    @Test("missing lease identity fails closed before capability execution")
    func missingLeaseIdentityIsRejected() async throws {
        let probe = CountingToolExecutor()
        let executor = ComposerPolicyEnforcedToolExecutor(
            base: probe,
            controller: ComposerAuthorizationController(
                snapshot: snapshot(mode: .auto),
                facts: facts(leaseID: ""),
                now: { now }
            )
        )

        await #expect(throws: ComposerAuthorizationError.leaseIdentityMissing) {
            try await executor.execute(
                name: "file_read",
                input: ["path": "/tmp/workspace/file.txt"]
            )
        }
        #expect(probe.executionCount == 0)
    }

    @Test("real AgentLoop rejects a symlink escape before the base")
    func symlinkEscapeNeverReachesBase() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("composer-root-\(UUID().uuidString)", isDirectory: true)
        let outside = fileManager.temporaryDirectory
            .appendingPathComponent("composer-outside-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: root)
            try? fileManager.removeItem(at: outside)
        }
        let link = root.appendingPathComponent("escape", isDirectory: true)
        try fileManager.createSymbolicLink(
            at: link,
            withDestinationURL: outside
        )

        let probe = CountingToolExecutor()
        let executor = ComposerPolicyEnforcedToolExecutor(
            base: probe,
            controller: ComposerAuthorizationController(
                snapshot: snapshot(mode: .auto, policyRevision: "symlink"),
                facts: facts(
                    granted: ["file_write"],
                    roots: [root.path],
                    revision: "symlink"
                ),
                now: { now }
            )
        )
        let loop = AgentLoop(maxIterations: 2)
        let result = try await loop.run(
            messages: [LLMMessage(role: .user, content: "symlink")],
            systemPrompt: nil,
            provider: MockLLMProvider(responses: [
                realToolCallEnvelope(
                    id: "call-symlink",
                    name: "file_write",
                    input: [
                        "path": link.appendingPathComponent("escaped.txt").path,
                        "content": "blocked"
                    ]
                ),
                "done"
            ]),
            toolExecutor: executor,
            tools: [
                AgentToolDefinition(
                    name: "file_write",
                    description: "Composer contract tool",
                    parameters: [:],
                    required: []
                )
            ]
        )

        #expect(result.messages.last?.content == "done")
        #expect(probe.executionCount == 0)
    }

    @Test("approval grants honor request, turn, session and workspace scope")
    func approvalScopesAreBound() async throws {
        let delegate = RecordingApprovalDelegate(decision: .approve)
        let gate = ApprovalGate(delegate: delegate)
        let grants = ComposerApprovalGrantStore()

        let turnController = ComposerAuthorizationController(
            snapshot: snapshot(mode: .manual, scope: .turn),
            facts: facts(),
            grants: grants,
            now: { now }
        )
        let probe = CountingToolExecutor()
        let executor = ComposerPolicyEnforcedToolExecutor(
            base: probe,
            controller: turnController,
            approvalGate: gate
        )
        _ = try await executor.execute(
            name: "file_write",
            input: ["path": "/tmp/workspace/file.txt"]
        )
        _ = try await executor.execute(
            name: "file_write",
            input: ["path": "/tmp/workspace/other.txt"]
        )
        #expect(await delegate.requests.count == 1)
        #expect(probe.executionCount == 2)
    }

    @Test("grant epoch changes cannot reuse an older workspace grant")
    func grantEpochInvalidatesWorkspaceGrant() async throws {
        let delegate = RecordingApprovalDelegate(decision: .approve)
        let gate = ApprovalGate(delegate: delegate)
        let grants = ComposerApprovalGrantStore()
        let firstController = ComposerAuthorizationController(
            snapshot: snapshot(
                mode: .manual,
                scope: .workspace,
                grantEpoch: "epoch-0"
            ),
            facts: facts(grantEpoch: "epoch-0"),
            grants: grants,
            now: { now }
        )
        let firstProbe = CountingToolExecutor()
        let firstExecutor = ComposerPolicyEnforcedToolExecutor(
            base: firstProbe,
            controller: firstController,
            approvalGate: gate
        )
        _ = try await firstExecutor.execute(
            name: "file_write",
            input: ["path": "/tmp/workspace/file.txt", "content": "first"]
        )

        let secondController = ComposerAuthorizationController(
            snapshot: snapshot(
                mode: .manual,
                scope: .workspace,
                grantEpoch: "epoch-1"
            ),
            facts: facts(grantEpoch: "epoch-1"),
            grants: grants,
            now: { now }
        )
        let secondProbe = CountingToolExecutor()
        let secondExecutor = ComposerPolicyEnforcedToolExecutor(
            base: secondProbe,
            controller: secondController,
            approvalGate: gate
        )
        _ = try await secondExecutor.execute(
            name: "file_write",
            input: ["path": "/tmp/workspace/file.txt", "content": "second"]
        )

        #expect(await delegate.requests.count == 2)
        #expect(firstProbe.executionCount == 1)
        #expect(secondProbe.executionCount == 1)
    }

    @Test("real AgentLoop path keeps the base at zero for every fail-closed case")
    func realAgentLoopRejectsBeforeBaseExecution() async throws {
        struct Scenario {
            let name: String
            let capability: String
            let input: [String: Any]
            let snapshot: ComposerSubmissionSnapshot
            let facts: ComposerPolicyFactSource
            let dryRun: Bool
        }

        let fileWriteInput: [String: Any] = [
            "path": "/tmp/workspace/file.txt",
            "content": "test"
        ]
        let scenarios = [
            Scenario(
                name: "unknown",
                capability: "unknown_capability",
                input: [:],
                snapshot: snapshot(mode: .auto),
                facts: facts(granted: ["file_read"]),
                dryRun: false
            ),
            Scenario(
                name: "missing grant",
                capability: "file_write",
                input: fileWriteInput,
                snapshot: snapshot(mode: .auto),
                facts: facts(granted: [], roots: ["/tmp/workspace"]),
                dryRun: false
            ),
            Scenario(
                name: "wrong scope",
                capability: "file_read",
                input: ["path": "/tmp/workspace/file.txt"],
                snapshot: snapshot(mode: .auto, scope: .workspace, workspaceID: "workspace-2"),
                facts: facts(granted: ["file_read"]),
                dryRun: false
            ),
            Scenario(
                name: "expired",
                capability: "file_write",
                input: fileWriteInput,
                snapshot: snapshot(mode: .auto, policyRevision: "expired"),
                facts: ComposerPolicyFactSource(
                    knownCapabilities: ["file_write"],
                    grantedCapabilities: ["file_write"],
                    allowedWriteRoots: ["/tmp/workspace"],
                    workspaceID: "workspace-1",
                    revision: "expired",
                    leaseID: "lease-expired",
                    expiresAt: now.addingTimeInterval(-1), autonomyCeiling: .l3
                ),
                dryRun: false
            ),
            Scenario(
                name: "revoked",
                capability: "file_write",
                input: fileWriteInput,
                snapshot: snapshot(mode: .auto, policyRevision: "revoked"),
                facts: ComposerPolicyFactSource(
                    knownCapabilities: ["file_write"],
                    grantedCapabilities: ["file_write"],
                    allowedWriteRoots: ["/tmp/workspace"],
                    workspaceID: "workspace-1",
                    revision: "revoked",
                    leaseID: "lease-revoked",
                    expiresAt: now.addingTimeInterval(600),
                    revoked: true, autonomyCeiling: .l3
                ),
                dryRun: false
            ),
            Scenario(
                name: "out of root",
                capability: "file_write",
                input: ["path": "/tmp/outside/file.txt", "content": "test"],
                snapshot: snapshot(mode: .auto),
                facts: facts(granted: ["file_write"]),
                dryRun: false
            ),
            Scenario(
                name: "plan dry-run",
                capability: "file_write",
                input: fileWriteInput,
                snapshot: snapshot(mode: .plan),
                facts: facts(granted: ["file_write"]),
                dryRun: true
            ),
        ]
        let preflightErrors: [String: ComposerAuthorizationError] = [
            "wrong scope": .scopeMismatch,
            "expired": .factsExpired,
            "revoked": .authorizationRevoked
        ]

        for scenario in scenarios {
            let root = try minisCoreToolContractRoot(
                "composer-\(scenario.name.replacingOccurrences(of: " ", with: "-"))"
            )
            defer { try? FileManager.default.removeItem(at: root) }
            let identity = minisCoreToolContractIdentity(
                "composer-\(scenario.name)",
                sessionID: scenario.snapshot.sessionID,
                turnID: scenario.snapshot.turnID,
                messageID: scenario.snapshot.messageID
            )
            let probe = CountingToolExecutor()
            let controller = ComposerAuthorizationController(
                snapshot: scenario.snapshot,
                facts: scenario.facts,
                now: { now }
            )
            let executor = ComposerPolicyEnforcedToolExecutor(
                base: probe,
                controller: controller
            )
            let provider = MockLLMProvider(responses: [
                realToolCallEnvelope(
                    id: "call-\(scenario.name)",
                    name: scenario.capability,
                    input: scenario.input
                ),
                "done"
            ])
            let definition = AgentToolDefinition(
                name: scenario.capability,
                description: "Composer contract tool",
                parameters: [:],
                required: []
            )
            let loop = AgentLoop(
                maxIterations: 2,
                approvalGate: ApprovalGate(delegate: ComposerTestApprovalDelegate()),
                toolExecutionFactLedger: try minisCoreToolContractLedger(at: root)
            )

            let result: AgentLoopResult
            do {
                result = try await loop.run(
                    messages: [LLMMessage(role: .user, content: scenario.name)],
                    systemPrompt: nil,
                    provider: provider,
                    toolExecutor: executor,
                    tools: [definition],
                    composerSnapshot: scenario.snapshot,
                    executionIdentity: identity
                )
            } catch let error as ComposerAuthorizationError {
                guard let expected = preflightErrors[scenario.name] else { throw error }
                #expect(error == expected)
                #expect(probe.executionCount == 0)
                continue
            }

            #expect(preflightErrors[scenario.name] == nil)
            #expect(result.messages.last?.content == "done")
            #expect(probe.executionCount == 0)
            if scenario.dryRun {
                #expect(result.messages.contains { $0.content.contains("dry-run") })
            }
        }
    }

    @Test("approval is rechecked after cancellation or revocation")
    func lateApprovalCannotReachBase() async throws {
        let delegate = BlockingApprovalDelegate()
        let receipts = ReceiptBox()
        let controller = ComposerAuthorizationController(
            snapshot: snapshot(mode: .manual, scope: .request),
            facts: facts(),
            now: { now }
        )
        let probe = CountingToolExecutor()
        let executor = ComposerPolicyEnforcedToolExecutor(
            base: probe,
            controller: controller,
            approvalGate: ApprovalGate(delegate: delegate),
            onApprovalReceipt: { receipts.store($0) }
        )

        let task = Task {
            try await executor.execute(
                callID: "late-file-write",
                name: "file_write",
                input: ["path": "/tmp/workspace/file.txt", "content": "late"]
            )
        }
        await delegate.waitUntilRequested()
        await controller.revoke()
        await delegate.resolve(.approve)

        await #expect(throws: ComposerAuthorizationError.authorizationRevoked) {
            _ = try await task.value
        }
        #expect(probe.executionCount == 0)
        #expect(receipts.load() == nil)
    }

    @Test("a lookalike executor cannot opt out of the outer approval gate")
    func lookalikeExecutorCannotBypassApproval() async throws {
        let probe = CountingToolExecutor()
        let loop = AgentLoop(maxIterations: 2)
        let result = try await loop.run(
            messages: [LLMMessage(role: .user, content: "lookalike")],
            systemPrompt: nil,
            provider: MockLLMProvider(responses: [
                realToolCallEnvelope(
                    id: "call-lookalike",
                    name: "shell_execute",
                    input: ["command": "touch /tmp/should-not-run"]
                ),
                "done"
            ]),
            toolExecutor: LookalikeExecutor(probe: probe),
            tools: [
                AgentToolDefinition(
                    name: "shell_execute",
                    description: "lookalike",
                    parameters: [:],
                    required: []
                )
            ]
        )

        #expect(result.messages.last?.content == "done")
        #expect(probe.executionCount == 0)
    }

    private final class CountingToolExecutor: ToolExecutor, @unchecked Sendable {
        private(set) var executionCount = 0

        func execute(name: String, input: [String: Any]) async throws -> String {
            executionCount += 1
            return "executed"
        }
    }

    private final class LookalikeExecutor: ToolExecutor, @unchecked Sendable {
        let probe: CountingToolExecutor

        init(probe: CountingToolExecutor) {
            self.probe = probe
        }

        func execute(name: String, input: [String: Any]) async throws -> String {
            try await probe.execute(name: name, input: input)
        }
    }

    private struct ComposerTestApprovalDelegate: ApprovalDelegate {
        func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
            .approve
        }
    }

    private struct BrowserBoundApprovalDelegate: ApprovalDelegate {
        func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
            ApprovalDecision(
                approved: true,
                confirmed: true,
                requestID: request.requestID,
                bindingDigest: request.identityDigest
            )
        }
    }

    private actor BrowserDeliveryLatch {
        private var reached = false
        private var resume: CheckedContinuation<Void, Never>?

        func suspendDelivery() async {
            reached = true
            await withCheckedContinuation { resume = $0 }
        }

        func waitUntilReached() async {
            while !reached { await Task.yield() }
        }

        func release() {
            resume?.resume()
            resume = nil
        }
    }

    private final class BrowserGrantProbe: ToolExecutor, @unchecked Sendable {
        let ledger: BrowserSideEffectGrantLedger
        private let lock = NSLock()
        private var count = 0

        init(ledger: BrowserSideEffectGrantLedger) { self.ledger = ledger }

        var executionCount: Int { lock.withLock { count } }

        func execute(name: String, input: [String: Any]) async throws -> String {
            let digest = try ComposerToolInput(input).digest
            let identity = BrowserSideEffectCallContext.current
            lock.withLock { count += 1 }
            guard identity?.inputDigest == digest,
                  ledger.consume(action: "click", scopeID: "browser-scope", identity: identity) != nil else {
                return "denied"
            }
            return "executed"
        }
    }

    @Test("Composer 等待浏览器回执兑换完成后才进入实际执行器")
    func browserReceiptDeliveryCompletesBeforeBaseExecution() async throws {
        let ledger = BrowserSideEffectGrantLedger()
        let latch = BrowserDeliveryLatch()
        let probe = BrowserGrantProbe(ledger: ledger)
        let delegate = BrowserBoundApprovalDelegate()
        let gate = ApprovalGate(
            delegate: delegate,
            onApprovalReceipt: { receipt in
                await latch.suspendDelivery()
                guard BrowserApprovalReceiptRedeemer.redeem(
                    receipt, into: ledger, scopeID: "browser-scope"
                ) else {
                    throw ApprovalError.denied(reason: "receipt redemption failed")
                }
            }
        )
        let executor = ComposerPolicyEnforcedToolExecutor(
            base: probe,
            controller: ComposerAuthorizationController(
                snapshot: snapshot(mode: .manual),
                facts: facts(granted: ["browser"]),
                now: { now }
            ),
            approvalGate: gate
        )
        let task = Task {
            try await executor.execute(
                callID: "browser-call-1",
                name: "browser",
                input: ["action": "click", "selector": "#submit"]
            )
        }
        await latch.waitUntilReached()
        #expect(probe.executionCount == 0)
        await latch.release()
        #expect(try await task.value == "executed")
        #expect(probe.executionCount == 1)
        #expect(ledger.pendingGrantCount == 0)
        await #expect(throws: (any Error).self) {
            _ = try await executor.execute(
                callID: "browser-call-1",
                name: "browser",
                input: ["action": "click", "selector": "#submit"]
            )
        }
        #expect(probe.executionCount == 1)
    }

    @Test("浏览器审批拒绝或取消时不会兑换授权或进入执行器")
    func deniedOrCancelledBrowserCallHasNoGrant() async throws {
        let ledger = BrowserSideEffectGrantLedger()
        let probe = BrowserGrantProbe(ledger: ledger)
        let denied = ComposerPolicyEnforcedToolExecutor(
            base: probe,
            controller: ComposerAuthorizationController(
                snapshot: snapshot(mode: .manual, taskID: "browser-denied"),
                facts: facts(granted: ["browser"]),
                now: { now }
            ),
            approvalGate: ApprovalGate(
                delegate: RecordingApprovalDelegate(decision: .deny),
                onApprovalReceipt: { receipt in
                    _ = BrowserApprovalReceiptRedeemer.redeem(
                        receipt, into: ledger, scopeID: "browser-scope"
                    )
                }
            )
        )
        await #expect(throws: (any Error).self) {
            _ = try await denied.execute(
                callID: "browser-denied",
                name: "browser",
                input: ["action": "click", "selector": "#submit"]
            )
        }
        #expect(probe.executionCount == 0)
        #expect(ledger.pendingGrantCount == 0)

        let pendingDelegate = BlockingApprovalDelegate()
        let cancelled = ComposerPolicyEnforcedToolExecutor(
            base: probe,
            controller: ComposerAuthorizationController(
                snapshot: snapshot(mode: .manual, taskID: "browser-cancelled"),
                facts: facts(granted: ["browser"]),
                now: { now }
            ),
            approvalGate: ApprovalGate(
                delegate: pendingDelegate,
                onApprovalReceipt: { receipt in
                    _ = BrowserApprovalReceiptRedeemer.redeem(
                        receipt, into: ledger, scopeID: "browser-scope"
                    )
                }
            )
        )
        let task = Task {
            try await cancelled.execute(
                callID: "browser-cancelled",
                name: "browser",
                input: ["action": "click", "selector": "#submit"]
            )
        }
        await pendingDelegate.waitUntilRequested()
        task.cancel()
        await pendingDelegate.resolve(.approve)
        await #expect(throws: (any Error).self) { _ = try await task.value }
        #expect(probe.executionCount == 0)
        #expect(ledger.pendingGrantCount == 0)
    }

    private actor RecordingApprovalDelegate: ApprovalDelegate {
        let decision: ApprovalDecision
        private(set) var requests: [ApprovalRequest] = []

        init(decision: ApprovalDecision) {
            self.decision = decision
        }

        func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
            requests.append(request)
            return ApprovalDecision(
                approved: decision.approved,
                reason: decision.reason,
                confirmed: decision.confirmed,
                status: decision.status,
                requestID: request.requestID,
                bindingDigest: request.identityDigest
            )
        }
    }

    private actor AuthorityBlockingDelegate: ApprovalDelegate {
        private var request: ApprovalRequest?
        private var answer: CheckedContinuation<ApprovalDecision, Never>?
        private var requestWaiter: CheckedContinuation<Void, Never>?

        func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
            await withCheckedContinuation { continuation in
                self.request = request
                answer = continuation
                requestWaiter?.resume()
                requestWaiter = nil
            }
        }

        func waitForRequest() async {
            if request != nil { return }
            await withCheckedContinuation { requestWaiter = $0 }
        }

        func resolve(_ status: ApprovalDecisionStatus) {
            guard let request else { return }
            answer?.resume(returning: ApprovalDecision(
                approved: status == .approved, confirmed: true, status: status,
                requestID: request.requestID, bindingDigest: request.identityDigest
            ))
            answer = nil
        }
    }

    private final class AuthorityFactBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [ApprovalLifecycleFact] = []

        func record(_ fact: ApprovalLifecycleFact) {
            lock.withLock { stored.append(fact) }
        }

        var facts: [ApprovalLifecycleFact] {
            lock.withLock { stored }
        }
    }

    private actor BlockingApprovalDelegate: ApprovalDelegate {
        private var continuation: CheckedContinuation<ApprovalDecision, Never>?
        private var request: ApprovalRequest?
        private var requested = false

        func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
            self.request = request
            requested = true
            return await withCheckedContinuation { continuation = $0 }
        }

        func waitUntilRequested() async {
            while !requested {
                await Task.yield()
            }
        }

        func resolve(_ decision: ApprovalDecision) {
            guard let request else { return }
            continuation?.resume(returning: ApprovalDecision(
                approved: decision.approved,
                reason: decision.reason,
                confirmed: decision.confirmed,
                status: decision.status,
                requestID: request.requestID,
                bindingDigest: request.identityDigest
            ))
            continuation = nil
            self.request = nil
        }
    }

    private final class ReceiptBox: @unchecked Sendable {
        private let lock = NSLock()
        private var receipt: ComposerApprovalReceipt?

        func store(_ receipt: ComposerApprovalReceipt) {
            lock.withLock { self.receipt = receipt }
        }

        func load() -> ComposerApprovalReceipt? {
            lock.withLock { receipt }
        }
    }

    /// 绕过模式下 file_delete 改为移入废纸篓（用户 2026-10-22 决定）。测试用临时目录里的
    /// 假废纸篓代替真实 ~/.Trash，保持测试封闭。
    private func fakeTrashMover(in root: URL) throws -> @Sendable (URL) throws -> URL? {
        let trash = root.appendingPathComponent("fake-trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        return { url in
            let destination = trash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
    }

    private func realToolCallEnvelope(
        id: String,
        name: String,
        input: [String: Any]
    ) -> String {
        let object: [String: Any] = [
            "tool_calls": [["id": id, "name": name, "input": input]]
        ]
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)!
    }

    @Test("confirmed bypass performs actual write and delete without repeated human approval while hard gates remain")
    func confirmedBypassWriteDeleteWithoutPromptsAndHardDenialsStayEffective() async throws {
        let root = try minisCoreToolContractRoot("policy05-confirmed-physical-effect")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("owned.txt")
        let content = "policy05-owned-synthetic-bytes\n"
        let submitted = snapshot(mode: .bypassPermission, scope: .workspace)
        let controller = ComposerAuthorizationController(
            snapshot: submitted,
            facts: facts(granted: ["file_write", "file_delete"], roots: [root.path]),
            now: { now }
        )
        let changes = FileChangeLedger(workspaceRoot: root.path)
        let builtin = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        builtin.fileChangeLedger = changes
        builtin.fileChangeSessionID = submitted.sessionID
        let goal = GoalEnvelope(
            scopeID: "policy05:owned", allowedCapabilities: ["file_write", "file_delete"],
            fileRoots: [root.path], budget: 10, deadline: now.addingTimeInterval(600),
            concurrencyLimit: 1, autonomyLevel: .l3, creatorID: "Policy05ConfirmedDelta",
            createdAt: now
        )
        let lease = AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID,
            issuedAt: now, expiresAt: goal.deadline)
        let runtime = PolicyRuntimeBinding(goal: goal, lease: lease, clock: { now })
        let delegate = RecordingApprovalDelegate(decision: .approve)
        let receipts = ReceiptBox()
        let gate = ApprovalGate(policyByTool: ["file_write": .alwaysAsk, "file_delete": .alwaysAsk],
                                delegate: delegate)
        let wrapped = ComposerPolicyEnforcedToolExecutor(
            base: runtime.wrap(builtin), controller: controller, approvalGate: gate,
            onApprovalReceipt: { receipts.store($0) }
        )
        let factURL = root.appendingPathComponent("effect-facts.json")
        let durable = try ToolExecutionFactLedger(persistenceURL: factURL)
        let provider = MockLLMProvider(responses: [
            realToolCallEnvelope(id: "policy05-write", name: "file_write",
                input: ["path": file.path, "content": content]),
            realToolCallEnvelope(id: "policy05-delete", name: "file_delete",
                input: ["path": file.path]),
            "done"
        ])
        let loop = AgentLoop(maxIterations: 4, approvalGate: gate,
            policyRuntime: runtime, requiresPolicyRuntime: true,
            toolExecutionFactLedger: durable)
        let result = try await BypassTrashSeam.$mover.withValue(try fakeTrashMover(in: root)) {
            try await loop.run(
            messages: [LLMMessage(role: .user, content: "write then delete the owned synthetic file")],
            systemPrompt: nil, provider: provider, toolExecutor: wrapped,
            tools: minisCoreToolContractCatalog(["file_write", "file_delete"]),
            composerSnapshot: submitted,
            executionIdentity: minisCoreToolContractIdentity("policy05-confirmed",
                sessionID: submitted.sessionID, turnID: submitted.turnID,
                messageID: submitted.messageID)
        )
        }
        #expect(result.messages.last?.content == "done")
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(await delegate.requests.isEmpty)
        #expect(receipts.load() == nil)
        let records = changes.records(sessionID: submitted.sessionID)
        #expect(records.map(\.kind.rawValue) == ["created", "deleted"])
        let deleted = try #require(records.last)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(deleted)) as? [String: Any])
        let digest = SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(encoded["deletedContentSHA256"] as? String == digest)
        #expect(durable.pendingReceipts.isEmpty)
        #expect(durable.facts.map(\.toolCallID) == ["policy05-write", "policy05-delete"])
        #expect(durable.facts.allSatisfy { $0.status == .succeeded })
        let reopened = try ToolExecutionFactLedger(persistenceURL: factURL)
        #expect(reopened.facts == durable.facts && reopened.pendingReceipts.isEmpty)

        // Each refusal is exercised on the original Composer wrapper and the
        // same physical executor. No denied probe may recreate the deleted file.
        let blocked = ComposerPolicyEnforcedToolExecutor(base: runtime.wrap(builtin),
            controller: controller,
            approvalGate: ApprovalGate(policyByTool: ["file_write": .deny], delegate: delegate))
        await #expect(throws: ComposerAuthorizationError.approvalDenied("Capability is blocked by approval policy")) {
            _ = try await blocked.execute(callID: "policy05-deny", name: "file_write",
                input: ["path": file.path, "content": "blocked"])
        }
        let never = ComposerPolicyEnforcedToolExecutor(base: runtime.wrap(builtin),
            controller: controller,
            approvalGate: ApprovalGate(policyByTool: ["file_write": .never], delegate: delegate))
        await #expect(throws: ComposerAuthorizationError.approvalDenied("Capability is blocked by approval policy")) {
            _ = try await never.execute(callID: "policy05-never", name: "file_write",
                input: ["path": file.path, "content": "blocked"])
        }
        // 用户 2026-10-22 决定：已确认的绕过不再受项目授权根限制（旧断言为根外写入被
        // pathOutsideAllowedRoots 拒绝）。同一路径在非绕过模式下仍被拒绝。
        let foreign = root.deletingLastPathComponent().appendingPathComponent("foreign-\(UUID().uuidString)")
        let foreignInput = try ComposerToolInput(["path": foreign.path, "content": "x"])
        #expect(try await controller.authorize(capability: "file_write", input: foreignInput) == .execute)
        let autoController = ComposerAuthorizationController(
            snapshot: snapshot(mode: .auto, scope: .workspace),
            facts: facts(granted: ["file_write", "file_delete"], roots: [root.path]),
            now: { now }
        )
        await #expect(throws: ComposerAuthorizationError.pathOutsideAllowedRoots(foreign.path)) {
            _ = try await autoController.authorize(capability: "file_write", input: foreignInput)
        }
        let noCapability = ComposerPolicyEnforcedToolExecutor(base: runtime.wrap(builtin),
            controller: ComposerAuthorizationController(snapshot: submitted,
                facts: ComposerPolicyFactSource(
                    knownCapabilities: ["file_write", "file_delete"],
                    grantedCapabilities: ["file_delete"], allowedWriteRoots: [root.path],
                    workspaceID: submitted.workspaceID, revision: submitted.policyRevision,
                    grantEpoch: submitted.grantEpoch, leaseID: "lease-missing-capability",
                    expiresAt: now.addingTimeInterval(600), autonomyCeiling: .l3
                ), now: { now }),
            approvalGate: gate)
        await #expect(throws: ComposerAuthorizationError.missingCapabilityGrant("file_write")) {
            _ = try await noCapability.execute(callID: "policy05-missing-capability", name: "file_write",
                input: ["path": file.path, "content": "blocked"])
        }
        let notConfirmed = ComposerPolicyEnforcedToolExecutor(base: runtime.wrap(builtin),
            controller: ComposerAuthorizationController(
                snapshot: snapshot(mode: .bypassPermission, scope: .workspace,
                    bypassModeConfirmed: false),
                facts: facts(granted: ["file_write", "file_delete"], roots: [root.path]),
                now: { now }), approvalGate: gate)
        await #expect(throws: ComposerAuthorizationError.bypassConfirmationRequired) {
            _ = try await notConfirmed.execute(callID: "policy05-not-confirmed", name: "file_write",
                input: ["path": file.path, "content": "blocked"])
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(changes.count == 2 && durable.facts.count == 2)
        #expect(await delegate.requests.isEmpty)
    }

    @Test("all five current Composer modes bind real write/delete effects and approval counts")
    func fiveModesRealBuiltinWriteDeleteAndLedgerUnder1818() async throws {
        for mode in ComposerTaskMode.allCases {
            let root = try minisCoreToolContractRoot("policy02-current-\(mode.rawValue)")
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("owned-\(mode.rawValue).txt")
            let content = "policy02-synthetic-\(mode.rawValue)\n"
            let submitted = snapshot(mode: mode, scope: .workspace,
                taskID: "policy02-current-\(mode.rawValue)")
            let controller = ComposerAuthorizationController(
                snapshot: submitted,
                facts: facts(granted: ["file_write", "file_delete"], roots: [root.path]),
                now: { now }
            )
            let changes = FileChangeLedger(workspaceRoot: root.path)
            let builtin = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
            builtin.fileChangeLedger = changes
            builtin.fileChangeSessionID = submitted.sessionID
            let goal = GoalEnvelope(
                scopeID: "policy02:\(mode.rawValue)",
                allowedCapabilities: ["file_write", "file_delete"],
                fileRoots: [root.path], budget: 10, deadline: now.addingTimeInterval(600),
                concurrencyLimit: 1, autonomyLevel: .l3,
                creatorID: "Policy02CurrentModesDelta", createdAt: now
            )
            let lease = AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID,
                issuedAt: now, expiresAt: goal.deadline)
            let runtime = PolicyRuntimeBinding(goal: goal, lease: lease, clock: { now })
            let delegate = RecordingApprovalDelegate(decision: .approve)
            let gate = ApprovalGate(policy: .autoApprove, delegate: delegate)
            let executor = ComposerPolicyEnforcedToolExecutor(
                base: runtime.wrap(builtin), controller: controller, approvalGate: gate
            )
            let factURL = root.appendingPathComponent("tool-facts.json")
            let durable = try ToolExecutionFactLedger(persistenceURL: factURL)
            let provider = MockLLMProvider(responses: [
                realToolCallEnvelope(id: "policy02-\(mode.rawValue)-write", name: "file_write",
                    input: ["path": file.path, "content": content]),
                realToolCallEnvelope(id: "policy02-\(mode.rawValue)-delete", name: "file_delete",
                    input: ["path": file.path]),
                "done"
            ])
            let loop = AgentLoop(maxIterations: 4, approvalGate: gate,
                policyRuntime: runtime, requiresPolicyRuntime: true,
                toolExecutionFactLedger: durable)
            let result = try await BypassTrashSeam.$mover.withValue(try fakeTrashMover(in: root)) {
            try await loop.run(
                messages: [LLMMessage(role: .user, content: "owned synthetic write and delete")],
                systemPrompt: nil, provider: provider, toolExecutor: executor,
                tools: minisCoreToolContractCatalog(["file_write", "file_delete"]),
                composerSnapshot: submitted,
                executionIdentity: minisCoreToolContractIdentity(
                    "policy02-current-\(mode.rawValue)", sessionID: submitted.sessionID,
                    turnID: submitted.turnID, messageID: submitted.messageID)
            )
        }
            #expect(result.messages.last?.content == "done")
            #expect(!FileManager.default.fileExists(atPath: file.path))
            let expectedPrompts: Int
            switch mode {
            case .manual: expectedPrompts = 2
            case .autoEdit, .auto: expectedPrompts = 1 // physical delete only
            case .plan, .bypassPermission: expectedPrompts = 0
            }
            let requests = await delegate.requests
            #expect(requests.count == expectedPrompts)
            #expect(Set(requests.map(\.callID)).count == expectedPrompts)
            #expect(requests.allSatisfy { $0.requiresApproval &&
                $0.requestID == $0.callID && $0.identityDigest != nil })
            if mode != .plan && mode != .bypassPermission {
                #expect(requests.last?.toolName == "file_delete")
                #expect(requests.last?.requiresSecondConfirmation == true)
            }
            let records = changes.records(sessionID: submitted.sessionID)
            if mode == .plan {
                #expect(records.isEmpty && changes.count == 0)
                #expect(result.messages.contains { $0.content.contains("dry-run") })
            } else {
                #expect(records.map(\.kind.rawValue) == ["created", "deleted"])
                let deleted = try #require(records.last)
                let encoded = try #require(JSONSerialization.jsonObject(
                    with: JSONEncoder().encode(deleted)) as? [String: Any])
                let digest = SHA256.hash(data: Data(content.utf8))
                    .map { String(format: "%02x", $0) }.joined()
                #expect(encoded["deletedContentSHA256"] as? String == digest)
            }
            #expect(durable.pendingReceipts.isEmpty)
            let expectedExecutedCallIDs: [String] = mode == .plan ? [] : [
                "policy02-\(mode.rawValue)-write", "policy02-\(mode.rawValue)-delete"
            ]
            #expect(durable.facts.map(\.toolCallID) == expectedExecutedCallIDs)
            let reopened = try ToolExecutionFactLedger(persistenceURL: factURL)
            #expect(reopened.facts == durable.facts && reopened.pendingReceipts.isEmpty)
        }
    }
}
