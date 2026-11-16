import Foundation
import Testing

@testable import MinisCore

// P3-HOOK-01: fixed `deny > ask > allow` precedence, same-input replay
// consistency, and fail-closed behavior for the pure decision reducer.

private let allAllow = HookDecisionInput(
    policy: PolicyLayerSignal(verdict: .allow),
    approval: ApprovalLayerSignal(verdict: .allow),
    stop: StopLayerSignal(continueRequested: true),
    timeout: TimeoutLayerSignal(expired: false),
    hook: HookLayerSignal(verdict: .allow, handlerInvocationID: "h1", handlerResultID: "h1")
)

private func signalHook(verdict: HookLayerVerdict, invocation: String = "h1", result: String = "h1") -> HookLayerSignal {
    HookLayerSignal(verdict: verdict, handlerInvocationID: invocation, handlerResultID: result)
}

@Suite("HookDecisionReducer deterministic merge", .serialized)
struct HookDecisionReducerTests {

    @Test("untrusted project hooks do not run and a changed trusted hash revokes execution")
    func projectHookTrustTracksTheActualContentHash() async throws {
        let root = try minisCoreToolContractRoot("group6-hook-trust")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        let config = project.appendingPathComponent(HookConfigStore.projectRelativePath)
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        func write(_ command: String) throws {
            let file = HookConfigurationFile(hooks: [HookDefinition(id: "project", event: .preToolUse, command: command)])
            try JSONEncoder().encode(file).write(to: config)
        }
        try write("printf first")
        let store = HookConfigStore(directory: root.appendingPathComponent("state"))
        let runner = Group6CountingHookRunner()
        let runtime = HookRuntime(store: store, runner: runner, environment: { [:] })
        _ = await runtime.beginTurn(sessionID: "session", prompt: "synthetic", projectRoot: project)
        let call = ComposerHookInvocation(callID: "call", capability: "file_read",
            input: try ComposerToolInput(["path": project.appendingPathComponent("file.txt").path]),
            identityDigest: "identity", sessionID: "session")
        let untrusted = try await runtime.preToolUse(call)
        #expect(untrusted.hasDecision && untrusted.verdict == .deny)
        #expect(untrusted.invocationIdentityDigest == call.identityDigest)
        #expect(await runner.calls == 0)
        let original = try #require(store.projectSnapshot(projectRoot: project).contentHash)
        try store.trustProjectHooks(projectRoot: project, expectedHash: original)
        let trusted = try await runtime.preToolUse(call)
        #expect(trusted.hasDecision)
        #expect(await runner.calls == 1)
        try write("printf changed")
        #expect(store.projectSnapshot(projectRoot: project).contentHash != original)
        let changed = try await runtime.preToolUse(call)
        #expect(changed.hasDecision && changed.verdict == .deny)
        #expect(changed.invocationIdentityDigest == call.identityDigest)
        #expect(await runner.calls == 1)
        let userFile = root.appendingPathComponent("state").appendingPathComponent(HookConfigStore.userFileName)
        withExtendedLifetime(store) {
            #expect(SensitiveFilePolicy.protectedStateShellViolation(command: "printf x > '\(userFile.path)'") != nil)
        }
    }

    @Test("user hooks require reviewed content and live consent does not reload a changed trust file")
    func userHookChangesRequireTheSettingsTrustActionAgain() async throws {
        let root = try minisCoreToolContractRoot("group6-user-hook-trust")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("state")
        let store = HookConfigStore(directory: directory)
        try store.addUserHook(HookDefinition(id: "user", event: .preToolUse, command: "printf first"))
        let runner = Group6CountingHookRunner()
        let runtime = HookRuntime(store: store, runner: runner, environment: { [:] })
        let call = ComposerHookInvocation(callID: "call", capability: "file_read",
            input: try ComposerToolInput(["path": root.appendingPathComponent("file.txt").path]),
            identityDigest: "identity", sessionID: "session")
        let denied = try await runtime.preToolUse(call)
        #expect(denied.hasDecision && denied.verdict == .deny)
        #expect(denied.invocationIdentityDigest == call.identityDigest)
        #expect(await runner.calls == 0)
        let reviewed = try #require(store.userHooksSnapshot().contentHash)
        try store.trustUserHooks(expectedHash: reviewed)
        #expect((try await runtime.preToolUse(call)).hasDecision)
        #expect(await runner.calls == 1)
        let config = HookConfigurationFile(hooks: [HookDefinition(id: "user", event: .preToolUse, command: "printf changed")])
        let userFile = directory.appendingPathComponent(HookConfigStore.userFileName)
        try JSONEncoder().encode(config).write(to: userFile)
        let changedHash = try #require(store.userHooksSnapshot().contentHash)
        let forged: [String: Any] = ["projects": [userFile.path: ["sha256": changedHash, "trustedAt": Date().timeIntervalSinceReferenceDate]]]
        try JSONSerialization.data(withJSONObject: forged).write(to: directory.appendingPathComponent(HookConfigStore.trustFileName))
        let changed = try await runtime.preToolUse(call)
        #expect(changed.hasDecision && changed.verdict == .deny)
        #expect(changed.invocationIdentityDigest == call.identityDigest)
        #expect(await runner.calls == 1)
        try store.trustUserHooks(expectedHash: changedHash)
        #expect((try await runtime.preToolUse(call)).hasDecision)
        #expect(await runner.calls == 2)
        withExtendedLifetime(store) {
            #expect(SensitiveFilePolicy.protectedStateShellViolation(command: "printf x > '\(userFile.path)'") != nil)
        }
    }

    @Test("trusted user hooks cannot execute scripts referenced through the live project variable")
    func userHookProjectVariableIsOutsideTheReviewedHash() async throws {
        let root = try minisCoreToolContractRoot("group6-user-hook-dynamic-project")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HookConfigStore(directory: root.appendingPathComponent("state"))
        try store.addUserHook(HookDefinition(id: "dynamic", event: .preToolUse,
            command: "sh \"$MINISCANVAS_PROJECT_DIR/.miniscanvas/hooks/check.sh\""))
        try store.trustUserHooks(expectedHash: #require(store.userHooksSnapshot().contentHash))
        #expect(store.userHooksSnapshot().outsideReferences["dynamic"] != nil)
        let runner = Group6CountingHookRunner()
        let runtime = HookRuntime(store: store, runner: runner, environment: { [:] })
        _ = await runtime.beginTurn(sessionID: "session", prompt: "synthetic", projectRoot: root.appendingPathComponent("project"))
        let call = ComposerHookInvocation(callID: "call", capability: "file_read",
            input: try ComposerToolInput(["path": root.appendingPathComponent("file.txt").path]),
            identityDigest: "identity", sessionID: "session")
        #expect(!(try await runtime.preToolUse(call)).hasDecision)
        #expect(await runner.calls == 0)
    }

    @Test("invalid hook input JSON is recorded and never sent to the runner",
          arguments: [Double.nan, Double.infinity, -Double.infinity])
    func invalidPayloadDoesNotBecomeAnEmptyJSONExecution(number: Double) async throws {
        let root = try minisCoreToolContractRoot("group6-hook-json-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HookConfigStore(directory: root.appendingPathComponent("state"))
        try store.addUserHook(HookDefinition(id: "invalid", event: .preToolUse, command: "synthetic"))
        try store.trustUserHooks(expectedHash: #require(store.userHooksSnapshot().contentHash))
        let runner = Group6CountingHookRunner()
        let runtime = HookRuntime(store: store, runner: runner, environment: { [:] })
        let invocation = ComposerHookInvocation(callID: "call", capability: "file_read",
            input: ComposerToolInput(values: ["nonfinite": .number(number)]),
            identityDigest: "identity", sessionID: "session")
        let denied = try await runtime.preToolUse(invocation)
        #expect(denied.hasDecision && denied.verdict == .deny)
        #expect(denied.invocationIdentityDigest == invocation.identityDigest)
        #expect(await runner.calls == 0)
        #expect(runtime.recentRuns().last?.status == .launchFailed)
        #expect(runtime.recentRuns().last?.summary.contains("JSON 编码失败") == true)
    }

    @Test("PreToolUse exit 2 carries stderr as a blocking reason without executing a real command")
    func runtimeExitTwoBlocksWithTheRedactedReason() async throws {
        let root = try minisCoreToolContractRoot("group6-hook-exit2")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HookConfigStore(directory: root.appendingPathComponent("hook-state"))
        try store.addUserHook(HookDefinition(id: "exit-two", event: .preToolUse, command: "synthetic-never-executed"))
        let reviewed = try #require(store.userHooksSnapshot().contentHash)
        try store.trustUserHooks(expectedHash: reviewed)
        let runtime = HookRuntime(store: store, runner: Group6ExitTwoHookRunner(), environment: { [:] })
        let invocation = ComposerHookInvocation(callID: "call", capability: "file_write",
            input: try ComposerToolInput(["path": root.appendingPathComponent("file.txt").path]),
            identityDigest: "frozen-call", sessionID: "session")
        let result = try await runtime.preToolUse(invocation)
        #expect(result.hasDecision && result.verdict == .deny)
        #expect(result.reason?.contains("blocked by synthetic hook") == true)
        #expect(result.invocationIdentityDigest == invocation.identityDigest)
    }

    // MARK: - deny > ask > allow precedence

    @Test("all layers allow yields allow with allLayersConcur")
    func allLayersAllowYieldsAllow() {
        let decision = HookDecisionReducer.decide(allAllow)
        #expect(decision.outcome == .allow)
        #expect(decision.reason == .allLayersConcur)
        #expect(!decision.isTerminalDeny)
    }

    @Test("ask beats allow regardless of which layer asks")
    func askBeatsAllow() {
        let policyAsk = HookDecisionReducer.decide(
            HookDecisionInput(
                policy: PolicyLayerSignal(verdict: .ask),
                approval: allAllow.approval,
                stop: allAllow.stop,
                timeout: allAllow.timeout,
                hook: allAllow.hook
            )
        )
        #expect(policyAsk.outcome == .ask)
        #expect(policyAsk.reason == .policyAsk)

        let approvalAsk = HookDecisionReducer.decide(
            HookDecisionInput(
                policy: allAllow.policy,
                approval: ApprovalLayerSignal(verdict: .ask),
                stop: allAllow.stop,
                timeout: allAllow.timeout,
                hook: allAllow.hook
            )
        )
        #expect(approvalAsk.outcome == .ask)
        #expect(approvalAsk.reason == .approvalAsk)

        let hookAsk = HookDecisionReducer.decide(
            HookDecisionInput(
                policy: allAllow.policy,
                approval: allAllow.approval,
                stop: allAllow.stop,
                timeout: allAllow.timeout,
                hook: signalHook(verdict: .ask)
            )
        )
        #expect(hookAsk.outcome == .ask)
        #expect(hookAsk.reason == .hookAsk)
    }

    @Test("deny beats ask and allow from every other layer")
    func denyBeatsAskAndAllow() {
        // Policy denies while approval asks and hook allows.
        let decision = HookDecisionReducer.decide(
            HookDecisionInput(
                policy: PolicyLayerSignal(verdict: .deny),
                approval: ApprovalLayerSignal(verdict: .ask),
                stop: allAllow.stop,
                timeout: allAllow.timeout,
                hook: signalHook(verdict: .allow)
            )
        )
        #expect(decision.outcome == .deny)
        #expect(decision.reason == .policyDeny)
        #expect(decision.isTerminalDeny)

        // Hook denies while every earlier layer allows.
        let hookDeny = HookDecisionReducer.decide(
            HookDecisionInput(
                policy: allAllow.policy,
                approval: allAllow.approval,
                stop: allAllow.stop,
                timeout: allAllow.timeout,
                hook: signalHook(verdict: .deny)
            )
        )
        #expect(hookDeny.outcome == .deny)
        #expect(hookDeny.reason == .hookDeny)
    }

    @Test("later layers cannot re-open an earlier deny")
    func laterLayersCannotReopenDeny() {
        // Approval denies; every layer after it (stop/timeout/hook) allows.
        let decision = HookDecisionReducer.decide(
            HookDecisionInput(
                policy: allAllow.policy,
                approval: ApprovalLayerSignal(verdict: .deny),
                stop: StopLayerSignal(continueRequested: true),
                timeout: TimeoutLayerSignal(expired: false),
                hook: signalHook(verdict: .allow)
            )
        )
        #expect(decision.outcome == .deny)
        #expect(decision.reason == .approvalDeny)
    }

    @Test("stop continue=false is a sticky deny even if all others allow")
    func stopContinueFalseIsSticky() {
        let decision = HookDecisionReducer.decide(
            HookDecisionInput(
                policy: allAllow.policy,
                approval: allAllow.approval,
                stop: StopLayerSignal(continueRequested: false),
                timeout: allAllow.timeout,
                hook: signalHook(verdict: .allow)
            )
        )
        #expect(decision.outcome == .deny)
        #expect(decision.reason == .stopContinueFalse)
        #expect(decision.isTerminalDeny)
    }

    @Test("timeout expired is a deny even if all others allow")
    func timeoutExpiredDenies() {
        let decision = HookDecisionReducer.decide(
            HookDecisionInput(
                policy: allAllow.policy,
                approval: allAllow.approval,
                stop: allAllow.stop,
                timeout: TimeoutLayerSignal(expired: true),
                hook: signalHook(verdict: .allow)
            )
        )
        #expect(decision.outcome == .deny)
        #expect(decision.reason == .timeoutExpired)
    }

    @Test("hook handler invocation/result identity mismatch denies")
    func hookIdentityMismatchDenies() {
        let decision = HookDecisionReducer.decide(
            HookDecisionInput(
                policy: allAllow.policy,
                approval: allAllow.approval,
                stop: allAllow.stop,
                timeout: allAllow.timeout,
                hook: signalHook(verdict: .allow, invocation: "call-9", result: "result-9")
            )
        )
        #expect(decision.outcome == .deny)
        #expect(decision.reason == .hookHandlerIdentityMismatch)
    }

    // MARK: - fail-closed on missing input

    @Test("each missing layer fails closed to deny")
    func missingLayerFailsClosed() {
        let cases: [HookDecisionInput] = [
            HookDecisionInput(policy: nil, approval: allAllow.approval, stop: allAllow.stop, timeout: allAllow.timeout, hook: allAllow.hook),
            HookDecisionInput(policy: allAllow.policy, approval: nil, stop: allAllow.stop, timeout: allAllow.timeout, hook: allAllow.hook),
            HookDecisionInput(policy: allAllow.policy, approval: allAllow.approval, stop: nil, timeout: allAllow.timeout, hook: allAllow.hook),
            HookDecisionInput(policy: allAllow.policy, approval: allAllow.approval, stop: allAllow.stop, timeout: nil, hook: allAllow.hook),
            HookDecisionInput(policy: allAllow.policy, approval: allAllow.approval, stop: allAllow.stop, timeout: allAllow.timeout, hook: nil),
            HookDecisionInput(policy: nil, approval: nil, stop: nil, timeout: nil, hook: nil),
        ]
        for input in cases {
            let decision = HookDecisionReducer.decide(input)
            #expect(decision.outcome == .deny)
            #expect(decision.reason == .missingLayerInputFailClosed)
        }
    }

    // MARK: - replay determinism

    @Test("the same input replays to the identical decision")
    func sameInputReplaysIdentical() {
        let inputs: [HookDecisionInput] = [
            allAllow,
            HookDecisionInput(
                policy: PolicyLayerSignal(verdict: .deny),
                approval: ApprovalLayerSignal(verdict: .ask),
                stop: StopLayerSignal(continueRequested: false),
                timeout: TimeoutLayerSignal(expired: true),
                hook: signalHook(verdict: .deny, invocation: "a", result: "b")
            ),
            HookDecisionInput(policy: nil, approval: nil, stop: nil, timeout: nil, hook: nil),
        ]
        for input in inputs {
            let first = HookDecisionReducer.decide(input)
            for _ in 0..<8 {
                #expect(HookDecisionReducer.decide(input) == first)
            }
            // Replaying through a value-equal snapshot is also stable.
            let roundTrip = try? JSONDecoder().decode(
                HookDecisionInput.self,
                from: JSONEncoder().encode(input)
            )
            if let roundTrip {
                #expect(HookDecisionReducer.decide(roundTrip) == first)
            }
        }
    }
}

private struct Group6ExitTwoHookRunner: HookCommandRunning {
    func run(_ request: HookCommandRequest) async -> HookCommandResult {
        HookCommandResult(exitCode: 2, stdout: Data(), stderr: Data("blocked by synthetic hook".utf8),
            timedOut: false, launchError: nil)
    }
}

private actor Group6CountingHookRunner: HookCommandRunning {
    private(set) var calls = 0
    func run(_ request: HookCommandRequest) async -> HookCommandResult {
        calls += 1
        return HookCommandResult(exitCode: 0,
            stdout: Data(#"{"hookSpecificOutput":{"permissionDecision":"allow"}}"#.utf8),
            stderr: Data(), timedOut: false, launchError: nil)
    }
}
