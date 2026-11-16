import Foundation
import Testing
@testable import MinisCore

@Suite("Unknown shell calls consume fresh approval receipts")
struct MandatoryShellApprovalScopeTests {
    @Test func composerConsentAndHookAllowCannotReplaceUnknownCommandHumanApproval() async throws {
        let now = Date()
        let snapshot = ComposerSubmissionSnapshot(mode: .auto, approvalScope: .session, effort: .standard,
            sessionID: "synthetic-session", turnID: 1, taskID: "synthetic-task", messageID: "synthetic-message",
            workspaceID: "synthetic-project", createdAt: now, policyRevision: "v1", autonomyCeiling: .l3)
        let facts = ComposerPolicyFactSource(knownCapabilities: ["shell_execute"], grantedCapabilities: ["shell_execute"],
            allowedWriteRoots: ["/synthetic/project"], workspaceID: "synthetic-project", revision: "v1",
            leaseID: "synthetic-lease", expiresAt: now.addingTimeInterval(600), autonomyCeiling: .l3)
        let controller = ComposerAuthorizationController(snapshot: snapshot, facts: facts)
        let input: [String: Any] = ["command": "synthetic_unregistered_tool --flag", "cwd": "/synthetic/project"]
        try await controller.recordApproval(capability: "shell_execute", input: ComposerToolInput(input))
        let delegate = ShellDelegate()
        let executor = ComposerPolicyEnforcedToolExecutor(base: ReceiptProbe(), controller: controller,
            approvalGate: ApprovalGate(delegate: delegate), hookHandler: { invocation in
                ComposerHookResult(verdict: .allow, invocationIdentityDigest: invocation.identityDigest)
            })
        for callID in ["unknown-one", "unknown-two"] {
            #expect(try await executor.execute(callID: callID, name: "shell_execute", input: input) == "approved")
        }
        #expect(await delegate.requests.count == 2)
        #expect(await delegate.requests.allSatisfy { $0.requiresApproval && $0.persistentAllowOffer == nil })
    }

    @Test func legacyLoopProjectsTheRealGateReceiptAroundItsSingleExecutorEffect() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-shell-receipt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let delegate = ShellDelegate()
        let ledger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts.json"))
        let identity = minisCoreToolContractIdentity("legacy-unknown")
        // The real gate requires an active turn, finite deadline and verified
        // parent identity; this supplies the previously absent fixture authority.
        let loop = AgentLoop(maxIterations: 2, approvalGate: ApprovalGate(delegate: delegate),
            turnController: TurnController(), timeout: 30, toolExecutionFactLedger: ledger)
        let provider = MockLLMProvider(responses: [
            #"{"tool_calls":[{"id":"legacy-unknown","name":"shell_execute","input":{"command":"synthetic_unregistered_tool"}}]}"#,
            "done"
        ])
        let result = try await loop.run(messages: [LLMMessage(role: .user, content: "synthetic")], systemPrompt: nil,
            provider: provider, toolExecutor: ReceiptProbe(), tools: minisCoreToolContractCatalog(["shell_execute"]),
            currentConversationID: identity.turn.sessionID,
            parentIdentitySeed: ParentRuntimeIdentitySeed(sessionID: identity.turn.sessionID,
                conversationID: identity.turn.sessionID, taskID: "legacy-unknown", actorID: "synthetic-test"),
            executionIdentity: identity)
        #expect(result.messages.last?.content == "done")
        #expect(await delegate.requests.count == 1)
        #expect(ledger.facts.map(\.status) == [.succeeded])
        #expect(result.toolCallsExecuted == 1)
        let fact = try #require(ledger.facts.first)
        #expect(fact.toolCallID == "legacy-unknown")
        #expect(fact.executionIdentity == identity)
        #expect(fact.attemptID == "\(identity.operationID):attempt:\(identity.attempt)")
        let request = try #require(await delegate.requests.first)
        #expect(request.sessionID == identity.turn.sessionID)
        #expect(request.turnID == identity.turn.turnID)
        #expect(request.attemptID == fact.attemptID)
        #expect(request.callID == fact.toolCallID)
    }

    @Test(arguments: ["handle", "deadline"])
    func legacyLoopWithoutRuntimeAuthorityDoesNotAskOrExecute(missing: String) async throws {
        let root = try minisCoreToolContractRoot("legacy-shell-missing-\(missing)")
        defer { try? FileManager.default.removeItem(at: root) }
        let delegate = ShellDelegate()
        let ledger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts.json"))
        let identity = minisCoreToolContractIdentity("legacy-missing-\(missing)")
        let hasHandle = missing != "handle"
        let loop = AgentLoop(maxIterations: 2, approvalGate: ApprovalGate(delegate: delegate),
            turnController: hasHandle ? TurnController() : nil,
            timeout: missing == "deadline" ? nil : 30, toolExecutionFactLedger: ledger)
        let provider = MockLLMProvider(responses: [
            #"{"tool_calls":[{"id":"legacy-refused","name":"shell_execute","input":{"command":"synthetic_unregistered_tool"}}]}"#,
            "done"
        ])
        let result = try await loop.run(messages: [LLMMessage(role: .user, content: "synthetic")], systemPrompt: nil,
            provider: provider, toolExecutor: ReceiptProbe(), tools: minisCoreToolContractCatalog(["shell_execute"]),
            currentConversationID: identity.turn.sessionID,
            parentIdentitySeed: hasHandle ? ParentRuntimeIdentitySeed(sessionID: identity.turn.sessionID,
                conversationID: identity.turn.sessionID, taskID: "legacy-refused", actorID: "synthetic-test") : nil,
            executionIdentity: identity)
        #expect(result.messages.last?.content == "done")
        #expect(await delegate.requests.isEmpty)
        #expect(result.toolCallsExecuted == 0)
        #expect(ledger.pendingReceipts.isEmpty)
        #expect(ledger.facts.isEmpty)
    }

    @Test func globalParentBackgroundUsesRealLoopApprovalAndOwnedOutputStop() async throws {
        _ = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = try minisCoreToolContractRoot("global-background").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        let session = "global-background-" + UUID().uuidString
        let human = ShellDelegate()
        let started = try await backgroundLoop(root: root, owner: owner, human: human, session: session,
            callID: "start", name: "shell_execute", input: [
                "command": "printf 'GLOBAL_BACKGROUND_MARKER\\n'; sleep 20", "cwd": root.path,
                "run_in_background": true, "timeout": 30])
        let start = try backgroundResult(started, callID: "start")
        #expect(!start.isError)
        let object = try #require(JSONSerialization.jsonObject(with: Data(start.content.utf8)) as? [String: Any])
        let id = try #require(object["task_id"] as? String)
        #expect(object["background"] as? Bool == true && object["status"] as? String == "running")
        defer { _ = owner.backgroundShells.stop(id: id, reason: .user, sessionID: session) }
        for _ in 0..<100 {
            if owner.backgroundShells.readOutput(id: id, sessionID: session, offset: 0)?.stdout.contains("GLOBAL_BACKGROUND_MARKER") == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let read = try await backgroundLoop(root: root, owner: owner, human: human, session: session,
            callID: "read", name: "shell_output", input: ["task_id": id, "offset": 0])
        let readResult = try backgroundResult(read, callID: "read")
        #expect(!readResult.isError && readResult.content.contains("GLOBAL_BACKGROUND_MARKER"))
        let stop = try await backgroundLoop(root: root, owner: owner, human: human, session: session,
            callID: "stop", name: "shell_stop", input: ["task_id": id])
        let stopResult = try backgroundResult(stop, callID: "stop")
        #expect(!stopResult.isError)
        #expect(owner.backgroundShells.snapshot(id: id, sessionID: session)?.state == .stopped)
        let retry = try await backgroundLoop(root: root, owner: owner, human: human, session: session,
            callID: "parent-retry", name: "shell_execute", input: [
                "command": "printf 'GLOBAL_BACKGROUND_MARKER\\n'; sleep 20", "cwd": root.path,
                "run_in_background": true, "timeout": 30])
        let retryResult = try backgroundResult(retry, callID: "parent-retry")
        #expect(!retryResult.isError)
        let retryObject = try #require(JSONSerialization.jsonObject(with: Data(retryResult.content.utf8)) as? [String: Any])
        let retryID = try #require(retryObject["task_id"] as? String)
        #expect(retryID != id)
        defer { _ = owner.backgroundShells.stop(id: retryID, reason: .user, sessionID: session) }
        let retryStop = try await backgroundLoop(root: root, owner: owner, human: human, session: session,
            callID: "parent-retry-stop", name: "shell_stop", input: ["task_id": retryID])
        #expect(try !backgroundResult(retryStop, callID: "parent-retry-stop").isError)
        #expect(owner.backgroundShells.snapshot(id: retryID, sessionID: session)?.state == .stopped)
        #expect(await human.requests.count == 5)
        #expect(await human.requests.filter { $0.toolName == "shell_execute" }.count == 2)
        let launchRequests = await human.requests.filter { $0.toolName == "shell_execute" }
        #expect(Set(launchRequests.map(\.requestID)).count == 2)
        #expect(launchRequests.first?.inputDigest == launchRequests.last?.inputDigest)
        #expect(await human.requests.allSatisfy { $0.sessionID == session && $0.requiresApproval })
        #expect(started.toolExecutionFacts.first?.status == .succeeded)
    }

    @Test func ordinaryProjectChatCanStartAnOwnedBackgroundCommand() async throws {
        _ = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = try minisCoreToolContractRoot("ordinary-project-background").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        let session = "ordinary-project-background-" + UUID().uuidString
        defer {
            for snapshot in owner.backgroundShells.snapshots(sessionID: session) {
                _ = owner.backgroundShells.stop(id: snapshot.id, reason: .user, sessionID: session)
            }
        }
        let human = ShellDelegate()
        let result = try await backgroundLoop(root: root, owner: owner, human: human, session: session,
            callID: "ordinary-project-start", name: "shell_execute", input: [
                "command": "printf 'PROJECT_BACKGROUND_MARKER\\n'; sleep 20", "cwd": root.path,
                "run_in_background": true, "timeout": 30], scope: "ordinary-project")
        let start = try backgroundResult(result, callID: "ordinary-project-start")
        try #require(!start.isError, "有真实绑定目录的顶层普通项目会话应能启动后台命令")
        let object = try #require(JSONSerialization.jsonObject(with: Data(start.content.utf8)) as? [String: Any])
        let id = try #require(object["task_id"] as? String)
        #expect(object["background"] as? Bool == true)
        #expect(owner.backgroundShells.snapshot(id: id, sessionID: session) != nil)
        #expect(owner.backgroundShells.snapshot(id: id, sessionID: "another-session") == nil)
        #expect(await human.requests.count == 1)
        #expect(result.toolExecutionFacts.first?.status == .succeeded)
    }

    @Test(arguments: ["project", "scheduled", "legacy-project", "unknown", "outside-cwd", "approval-denied", "disabled"])
    func backgroundOriginNeverWidensOtherProductionBoundaries(scenario: String) async throws {
        let root = try minisCoreToolContractRoot("background-denied").resolvingSymlinksInPath()
        let outside = try minisCoreToolContractRoot("background-outside").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let names = scenario == "disabled" ? Set<String>() : BuiltinToolExecutor.defaultRegisteredToolNames()
        let owner = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [], registeredToolNames: names)
        let human = ShellDelegate(approved: scenario != "approval-denied")
        let session = "background-denied-" + UUID().uuidString
        let input: [String: Any] = ["command": "printf 'UNEXPECTED_EFFECT' > denied-marker.txt",
            "cwd": scenario == "outside-cwd" ? outside.path : root.path,
            "run_in_background": true, "timeout": 30]
        if scenario == "disabled" {
            await #expect(throws: ToolExecutorError.self) {
                _ = try await backgroundLoop(root: root, owner: owner, human: human, session: session,
                    callID: scenario, name: "shell_execute", input: input)
            }
        } else {
            let result = try await backgroundLoop(root: root, owner: owner, human: human, session: session,
                callID: scenario, name: "shell_execute", input: input, scope: scenario)
            #expect(try backgroundResult(result, callID: scenario).isError)
        }
        #expect(owner.backgroundShells.snapshots(sessionID: session).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("denied-marker.txt").path))
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("denied-marker.txt").path))
        if scenario == "approval-denied" { #expect(await human.requests.count == 1) }
    }

    private func backgroundLoop(root: URL, owner: BuiltinToolExecutor, human: ShellDelegate,
        session: String, callID: String, name: String, input: [String: Any], scope: String = "global") async throws -> AgentLoopResult {
        let ledger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts-" + callID + ".json"))
        var loop = AgentLoop(maxIterations: 2,
            approvalGate: ApprovalGate(policyByTool: [name: .alwaysAsk], delegate: human),
            turnController: TurnController(), timeout: 30, toolExecutionFactLedger: ledger)
        if scope == "unknown" {
            loop.childWorkspaceScope = ChildToolWorkspaceScope(readRoots: [root.path], writeRoots: [root.path],
                workingDirectory: root.path, deniedRoots: [], parentAuthorityCheck: nil)
        } else {
            try loop.captureToolWorkspace(directory: root, owner: owner,
                projectScoped: scope == "project" || scope == "ordinary-project" || scope == "legacy-project",
                projectTask: scope == "ordinary-project" ? false : (["project", "scheduled"].contains(scope) ? true : nil))
            #expect(loop.childWorkspaceScope?.backgroundOrigin ==
                (["project", "scheduled", "legacy-project"].contains(scope) ? .restricted : .globalParent))
        }
        let envelope: [String: Any] = ["tool_calls": [["id": callID, "name": name, "input": input]]]
        let provider = MockLLMProvider(responses: [String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self), "done"])
        let identity = minisCoreToolContractIdentity("background-" + callID, sessionID: session)
        return try await loop.run(messages: [.init(role: .user, content: "owned background test")],
            systemPrompt: nil, provider: provider, toolExecutor: owner, tools: minisCoreToolContractCatalog([name]),
            currentConversationID: session,
            parentIdentitySeed: ParentRuntimeIdentitySeed(sessionID: session, conversationID: session,
                taskID: "background-" + callID, actorID: "synthetic-test"), executionIdentity: identity)
    }

    private func backgroundResult(_ result: AgentLoopResult, callID: String) throws -> (content: String, isError: Bool) {
        for message in result.messages {
            for part in message.toAgentContentParts() {
                if case .toolResult(let id, _, let content, let isError, _, _, _, _) = part, id == callID {
                    return (content, isError)
                }
            }
        }
        Issue.record("actual loop did not deliver the original tool result")
        throw CocoaError(.coderInvalidValue)
    }

    private struct ReceiptProbe: ToolExecutor {
        func execute(name: String, input: [String: Any]) async throws -> String {
            guard ApprovedShellCallScope.permits(input: input) else { throw ToolExecutorError.approvalRequired(name) }
            return "approved"
        }
    }

    private actor ShellDelegate: ApprovalDelegate {
        let approved: Bool
        init(approved: Bool = true) { self.approved = approved }
        private(set) var requests: [ApprovalRequest] = []
        func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
            requests.append(request)
            return ApprovalDecision(approved: approved, confirmed: true,
                requestID: request.requestID, bindingDigest: request.identityDigest)
        }
    }
}

/// Scoped approval ("this turn / session / workspace") must not turn one human
/// approval of a `.confirmation` shell command into approval of every other
/// shell command. The grant key carries no command, so the production seam has
/// to keep `.confirmation` commands on a fresh receipt just as it already does
/// for `.unknown` ones.
@Suite("Confirmation shell calls are not covered by a scoped approval of another command")
struct ConfirmationShellApprovalScopeTests {
    private static let approvedCommand = "pwd && ls -la"
    private static let laterWriteCommand = "echo G22 > shell-out/hello.txt"

    private static func controller(
        mode: ComposerTaskMode, scope: ComposerApprovalScope, grants: ComposerApprovalGrantStore,
        taskID: String = "confirmation-task-1", turnID: Int = 1, epoch: String = "confirmation-epoch-1",
        lease: String = "confirmation-lease-1"
    ) -> ComposerAuthorizationController {
        let now = Date()
        let snapshot = ComposerSubmissionSnapshot(mode: mode, approvalScope: scope, effort: .standard,
            sessionID: "confirmation-session", turnID: turnID, taskID: taskID, messageID: "confirmation-message-\(taskID)",
            workspaceID: "confirmation-workspace", createdAt: now, policyRevision: "confirmation-v1",
            grantEpoch: epoch, autonomyCeiling: .l3)
        let facts = ComposerPolicyFactSource(knownCapabilities: ["shell_execute"], grantedCapabilities: ["shell_execute"],
            allowedWriteRoots: ["/synthetic/project"], workspaceID: "confirmation-workspace",
            revision: "confirmation-v1", grantEpoch: epoch, leaseID: lease,
            expiresAt: now.addingTimeInterval(600), autonomyCeiling: .l3)
        return ComposerAuthorizationController(snapshot: snapshot, facts: facts, grants: grants)
    }

    @Test(arguments: [ComposerApprovalScope.turn, .session, .workspace], [ComposerTaskMode.manual, .auto])
    func approvedConfirmationCommandDoesNotCoverALaterConfirmationWrite(
        scope: ComposerApprovalScope, mode: ComposerTaskMode
    ) async throws {
        let policy = TerminalPolicySnapshot.default
        try #require(policy.classify(command: Self.approvedCommand) == .confirmation)
        try #require(policy.classify(command: Self.laterWriteCommand) == .confirmation)
        let probe = ConfirmationScopeProbe()
        let delegate = ConfirmationScopeDelegate(probe: probe)
        let executor = ComposerPolicyEnforcedToolExecutor(base: probe,
            controller: Self.controller(mode: mode, scope: scope, grants: ComposerApprovalGrantStore()),
            approvalGate: ApprovalGate(delegate: delegate))

        _ = try await executor.execute(callID: "confirmation-first", name: "shell_execute",
            input: ["command": Self.approvedCommand])
        #expect(await delegate.requests.count == 1)
        #expect(probe.executed == [Self.approvedCommand])

        _ = try await executor.execute(callID: "confirmation-second", name: "shell_execute",
            input: ["command": Self.laterWriteCommand])
        // A fresh approval request must exist for the second command, and the
        // base executor must not have run it before that request was answered.
        #expect(await delegate.requests.count == 2)
        #expect(await delegate.executedCountAtRequest == [0, 1])
        #expect(await delegate.requests.map(\.callID) == ["confirmation-first", "confirmation-second"])
        #expect(probe.executed == [Self.approvedCommand, Self.laterWriteCommand])
    }

    /// The real field path: workspace/session consent outlives the task, so the
    /// later write arrives under a new task, grant epoch and lease.
    @Test(arguments: [ComposerApprovalScope.session, .workspace])
    func approvedConfirmationCommandDoesNotCoverALaterTaskWrite(scope: ComposerApprovalScope) async throws {
        let grants = ComposerApprovalGrantStore()
        let probe = ConfirmationScopeProbe()
        let delegate = ConfirmationScopeDelegate(probe: probe)
        let gate = ApprovalGate(delegate: delegate)
        let first = ComposerPolicyEnforcedToolExecutor(base: probe,
            controller: Self.controller(mode: .manual, scope: scope, grants: grants), approvalGate: gate)
        let later = ComposerPolicyEnforcedToolExecutor(base: probe,
            controller: Self.controller(mode: .manual, scope: scope, grants: grants, taskID: "confirmation-task-2",
                turnID: 2, epoch: "confirmation-epoch-2", lease: "confirmation-lease-2"), approvalGate: gate)

        _ = try await first.execute(callID: "task1-confirmation", name: "shell_execute",
            input: ["command": Self.approvedCommand])
        #expect(await delegate.requests.count == 1)
        _ = try await later.execute(callID: "task2-confirmation-write", name: "shell_execute",
            input: ["command": Self.laterWriteCommand])
        #expect(await delegate.requests.count == 2)
        #expect(await delegate.executedCountAtRequest == [0, 1])
        #expect(probe.executed == [Self.approvedCommand, Self.laterWriteCommand])
    }

    /// The terminal classification allows these commands to run after each
    /// manual approval. A legacy scope cannot reuse the first approval.
    @Test(arguments: [ComposerApprovalScope.turn, .session, .workspace])
    func approvedAllowedCommandAsksAgainWithinTheTask(scope: ComposerApprovalScope) async throws {
        let policy = TerminalPolicySnapshot.default
        try #require(policy.classify(command: "ls") == .allowed)
        try #require(policy.classify(command: "pwd") == .allowed)
        let probe = ConfirmationScopeProbe()
        let delegate = ConfirmationScopeDelegate(probe: probe)
        let executor = ComposerPolicyEnforcedToolExecutor(base: probe,
            controller: Self.controller(mode: .manual, scope: scope, grants: ComposerApprovalGrantStore()),
            approvalGate: ApprovalGate(delegate: delegate))
        _ = try await executor.execute(callID: "allowed-first", name: "shell_execute", input: ["command": "ls"])
        _ = try await executor.execute(callID: "allowed-second", name: "shell_execute", input: ["command": "pwd"])
        #expect(await delegate.requests.count == 2)
        #expect(probe.executed == ["ls", "pwd"])
    }

    @Test(arguments: [ComposerApprovalScope.session, .workspace])
    func approvedAllowedCommandAsksAgainAcrossTasks(scope: ComposerApprovalScope) async throws {
        let grants = ComposerApprovalGrantStore()
        let probe = ConfirmationScopeProbe()
        let delegate = ConfirmationScopeDelegate(probe: probe)
        let gate = ApprovalGate(delegate: delegate)
        let first = ComposerPolicyEnforcedToolExecutor(base: probe,
            controller: Self.controller(mode: .manual, scope: scope, grants: grants), approvalGate: gate)
        let later = ComposerPolicyEnforcedToolExecutor(base: probe,
            controller: Self.controller(mode: .manual, scope: scope, grants: grants, taskID: "confirmation-task-2",
                turnID: 2, epoch: "confirmation-epoch-2", lease: "confirmation-lease-2"), approvalGate: gate)
        _ = try await first.execute(callID: "allowed-task1", name: "shell_execute", input: ["command": "ls"])
        _ = try await later.execute(callID: "allowed-task2", name: "shell_execute", input: ["command": "pwd"])
        #expect(await delegate.requests.count == 2)
        #expect(probe.executed == ["ls", "pwd"])
    }
}

private final class ConfirmationScopeProbe: ToolExecutor, @unchecked Sendable {
    private(set) var executed: [String] = []
    func execute(name: String, input: [String: Any]) async throws -> String {
        executed.append(input["command"] as? String ?? "")
        return "synthetic-effect"
    }
}

private actor ConfirmationScopeDelegate: ApprovalDelegate {
    private let probe: ConfirmationScopeProbe
    private(set) var requests: [ApprovalRequest] = []
    private(set) var executedCountAtRequest: [Int] = []
    init(probe: ConfirmationScopeProbe) { self.probe = probe }
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        requests.append(request)
        executedCountAtRequest.append(probe.executed.count)
        return ApprovalDecision(approved: true, confirmed: true,
            requestID: request.requestID, bindingDigest: request.identityDigest)
    }
}
