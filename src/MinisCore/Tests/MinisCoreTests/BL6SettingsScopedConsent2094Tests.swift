import Foundation
import Testing
@testable import MinisCore

private actor Settings2094Delegate: ApprovalDelegate {
    private(set) var requests: [ApprovalRequest] = []

    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        requests.append(request)
        return ApprovalDecision(
            approved: true, confirmed: true,
            requestID: request.requestID, bindingDigest: request.identityDigest
        )
    }
}

private struct Settings2094Effect: ToolExecutor {
    func execute(name: String, input: [String: Any]) async throws -> String {
        guard name == BL6SettingsToolApproval.toolName,
              let call = BL6SettingsToolApproval.current,
              let facts = BL6SettingsToolApproval.currentAuthorizationFacts else {
            throw ComposerAuthorizationError.authorizationBindingMismatch
        }
        return try await call.consume(expected: facts).binding.effectID
    }
}

@Suite("D-SETC request consent binds exact settings calls")
struct BL6SettingsScopedConsent2094Tests {
    private let toolNames = [
        BL6SettingsToolApproval.catalogToolName,
        BL6SettingsToolApproval.toolName
    ]

    private func snapshot(
        scope: ComposerApprovalScope, task: String = "task-1",
        session: String = "session-1", workspace: String = "workspace-1",
        turn: Int = 1, revision: String = "policy-1", epoch: String = "epoch-1"
    ) -> ComposerSubmissionSnapshot {
        ComposerSubmissionSnapshot(
            mode: .manual, approvalScope: scope, effort: .standard,
            sessionID: session, turnID: turn, taskID: task,
            attemptID: "attempt-\(task)", messageID: "message-\(task)",
            workspaceID: workspace, createdAt: Date(),
            policyRevision: revision, grantEpoch: epoch, autonomyCeiling: .l3
        )
    }

    private func facts(
        workspace: String = "workspace-1", revision: String = "policy-1",
        epoch: String = "epoch-1", lease: String = "lease-1",
        roots: [String] = [], expiresAt: Date = Date().addingTimeInterval(600)
    ) -> ComposerPolicyFactSource {
        let names = Set(toolNames)
        return ComposerPolicyFactSource(
            knownCapabilities: names, grantedCapabilities: names,
            allowedWriteRoots: roots, workspaceID: workspace,
            revision: revision, grantEpoch: epoch, leaseID: lease,
            expiresAt: expiresAt, autonomyCeiling: .l3
        )
    }

    private func input(_ tool: String) -> [String: Any] {
        tool == BL6SettingsToolApproval.catalogToolName ? [:] : [
            "operation": "apply", "expectedRevision": "settings-1",
            "changes": ["general.language": "en"]
        ]
    }

    private func executor(
        snapshot: ComposerSubmissionSnapshot, facts: ComposerPolicyFactSource,
        grants: ComposerApprovalGrantStore, delegate: Settings2094Delegate
    ) -> ComposerPolicyEnforcedToolExecutor {
        ComposerPolicyEnforcedToolExecutor(
            base: Settings2094Effect(),
            controller: ComposerAuthorizationController(
                snapshot: snapshot, facts: facts, grants: grants
            ),
            approvalGate: ApprovalGate(delegate: delegate)
        )
    }

    @Test("each settings call asks even with a saved broader scope")
    func fourScopesBindNewCallsWithoutRepeatedHumanPrompt() async throws {
        for name in toolNames {
            for scope in ComposerApprovalScope.allCases {
                let delegate = Settings2094Delegate()
                let grants = ComposerApprovalGrantStore()
                let first = executor(
                    snapshot: snapshot(scope: scope), facts: facts(),
                    grants: grants, delegate: delegate
                )
                _ = try await first.authorizeExecution(
                    callID: "\(name)-first", name: name, input: input(name)
                )
                _ = try await first.authorizeExecution(
                    callID: "\(name)-same-turn", name: name, input: input(name)
                )
                #expect(await delegate.requests.count == 2)

                let next = executor(
                    snapshot: snapshot(
                        scope: scope, task: "task-2", turn: 2, epoch: "epoch-2"
                    ),
                    facts: facts(epoch: "epoch-2", lease: "lease-2"),
                    grants: grants, delegate: delegate
                )
                _ = try await next.authorizeExecution(
                    callID: "\(name)-next-task", name: name, input: input(name)
                )
                let requests = await delegate.requests
                #expect(requests.map(\.callID) == ["\(name)-first", "\(name)-same-turn", "\(name)-next-task"])
                #expect(Set(requests.map(\.requestID)).count == 3)
                #expect(requests.allSatisfy { $0.identityDigest != nil })
                #expect(Set(requests.compactMap(\.identityDigest)).count == 3)
            }
        }
    }

    @Test("same-session consent does not cross session, policy, workspace, roots or expiry")
    func changedAuthorityCannotReuseScopedConsent() async throws {
        for name in toolNames {
            let delegate = Settings2094Delegate()
            let grants = ComposerApprovalGrantStore()
            let first = executor(
                snapshot: snapshot(scope: .session), facts: facts(),
                grants: grants, delegate: delegate
            )
            _ = try await first.authorizeExecution(
                callID: "\(name)-seed", name: name, input: input(name)
            )
            let mismatches: [(ComposerSubmissionSnapshot, ComposerPolicyFactSource)] = [
                (snapshot(scope: .session, task: "other-session", session: "session-2",
                          epoch: "epoch-2"), facts(epoch: "epoch-2", lease: "lease-2")),
                (snapshot(scope: .session, task: "other-workspace", workspace: "workspace-2",
                          epoch: "epoch-2"),
                 facts(workspace: "workspace-2", epoch: "epoch-2", lease: "lease-2")),
                (snapshot(scope: .session, task: "other-policy", revision: "policy-2",
                          epoch: "epoch-2"),
                 facts(revision: "policy-2", epoch: "epoch-2", lease: "lease-2")),
                (snapshot(scope: .session, task: "other-roots", epoch: "epoch-2"),
                 facts(epoch: "epoch-2", lease: "lease-2", roots: ["/tmp/isolated"])),
                (snapshot(scope: .workspace, task: "other-scope", epoch: "epoch-2"),
                 facts(epoch: "epoch-2", lease: "lease-2")),
            ]
            for (index, mismatch) in mismatches.enumerated() {
                let deniedReuse = executor(
                    snapshot: mismatch.0, facts: mismatch.1,
                    grants: grants, delegate: delegate
                )
                _ = try await deniedReuse.authorizeExecution(
                    callID: "\(name)-mismatch-\(index)", name: name, input: input(name)
                )
                #expect(await delegate.requests.count == index + 2)
            }
            let expired = executor(
                snapshot: snapshot(scope: .session, task: "expired", epoch: "epoch-3"),
                facts: facts(epoch: "epoch-3", lease: "lease-3",
                             expiresAt: Date().addingTimeInterval(-1)),
                grants: grants, delegate: delegate
            )
            await #expect(throws: ComposerAuthorizationError.factsExpired) {
                try await expired.authorizeExecution(
                    callID: "\(name)-expired", name: name, input: input(name)
                )
            }
            #expect(await delegate.requests.count == mismatches.count + 1)
        }
    }

    @Test("a fresh mutation approval mints its own effect binding")
    func mutationRebindsExactCall() async throws {
        let delegate = Settings2094Delegate()
        let grants = ComposerApprovalGrantStore()
        let name = BL6SettingsToolApproval.toolName
        let first = executor(
            snapshot: snapshot(scope: .workspace), facts: facts(),
            grants: grants, delegate: delegate
        )
        let initial = try await first.authorizeExecution(
            callID: "write-first", name: name, input: input(name)
        )
        #expect(try await first.execute(
            preauthorization: initial, callID: "write-first", name: name, input: input(name)
        ) == "write-first")
        let next = executor(
            snapshot: snapshot(scope: .workspace, task: "task-2", session: "session-2",
                               turn: 2, epoch: "epoch-2"),
            facts: facts(epoch: "epoch-2", lease: "lease-2"),
            grants: grants, delegate: delegate
        )
        let approved = try await next.authorizeExecution(
            callID: "write-second", name: name, input: input(name)
        )
        #expect(try await next.execute(
            preauthorization: approved, callID: "write-second", name: name, input: input(name)
        ) == "write-second")
        let requests = await delegate.requests
        #expect(requests.map(\.callID) == ["write-first", "write-second"])
        #expect(Set(requests.map(\.requestID)).count == 2)
        #expect(Set(requests.compactMap(\.identityDigest)).count == 2)
    }
}
