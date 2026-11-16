import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private final class SchedulerRuntime2294Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private let release = DispatchSemaphore(value: 0)
    var hasEntered: Bool { lock.withLock { entered } }
    func finish() { release.signal() }
    func prepare() -> SpeechToolAvailabilitySnapshot {
        lock.withLock { entered = true }
        _ = release.wait(timeout: .now() + .seconds(20))
        // A pure unavailable value only pauses the existing async snapshot
        // worker. No OS voice/device/permission query or speech action occurs.
        return SpeechToolAvailabilitySnapshot(probe: SpeechCapabilityBoundary.Probe(),
            sources: .init(), identity: .init(turnID: "scheduler2294", capturedAt: Date()))
    }
}

private final class SchedulerRuntime2294Provider: LLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    let name = "scheduler2294-local"
    var model = LLMModel(id: "scheduler2294", displayName: "Scheduler2294", provider: "scheduler2294-local")
    let capabilities: Set<ProviderCapability> = [.tools]
    var runtimeConfigurationMaterial: String? = "scheduler2294-local-owned"
    let file: URL
    private let lock = NSLock()
    private var histories: [[LLMMessage]] = []
    private var names: [[String]] = []
    init(file: URL) { self.file = file }
    var requestCount: Int { lock.withLock { histories.count } }
    var received: [[LLMMessage]] { lock.withLock { histories } }
    var firstTools: [String] { lock.withLock { names.first ?? [] } }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt, tools: [],
            maxTokens: maxTokens, temperature: temperature)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        let count = lock.withLock { histories.append(messages); names.append(tools.map(\.name)); return histories.count }
        if count == 1 {
            let args: [String: Any] = ["path": file.path]
            let data = try JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])
            return LLMResponse(text: "", stopReason: "tool_calls", usage: nil, toolCalls: [
                LLMToolCall(id: "scheduler2294-owned-read", name: "file_read",
                    rawArguments: String(decoding: data, as: UTF8.self), arguments: args)
            ])
        }
        return LLMResponse(text: "owned scheduler read complete", stopReason: "stop", usage: nil)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private final class SchedulerRuntime2294Executor: ToolExecutor, @unchecked Sendable {
    let builtin: BuiltinToolExecutor
    private let lock = NSLock()
    private var calls = 0
    private var last: String?
    init(root: URL) { builtin = BuiltinToolExecutor(allowedRoot: root, deniedRoots: []) }
    var executionCount: Int { lock.withLock { calls } }
    var output: String? { lock.withLock { last } }
    func execute(name: String, input: [String: Any]) async throws -> String {
        lock.withLock { calls += 1 }
        let result = try await builtin.execute(name: name, input: input)
        lock.withLock { last = result }
        return result
    }
}

private actor SchedulerRuntime2294Approval: ApprovalDelegate {
    private(set) var requests: [ApprovalRequest] = []
    var count: Int { requests.count }
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        requests.append(request)
        return ApprovalDecision(approved: false, confirmed: false,
            requestID: request.requestID, bindingDigest: request.identityDigest)
    }
}

@Suite("D-SCHEDE required AgentLoop runtime consumer", .serialized)
@MainActor
struct SchedulerRequiredRuntime2294Tests {
    @Test("old occurrence owns the captured turn across selection drift and authority loss",
          arguments: ["selectionOnly", "revoked", "policyExpired", "leaseExpired", "selectionAlwaysAskDenied",
                      "bypassAtTrigger", "bypassConfirmationDrift"])
    func pinnedOccurrenceUsesActualRequiredAgentLoopRuntime(change: String) async throws {
        let f = try ScheduledTargetFixture(command: "read old owned scheduler source")
        defer { f.cleanup() }
        let file = f.root.appendingPathComponent("owned.txt")
        try "SCHED2294_OWNED_READ_BODY".write(to: file, atomically: true, encoding: .utf8)
        let provider = SchedulerRuntime2294Provider(file: file)
        let executor = SchedulerRuntime2294Executor(root: f.root)
        let approval = SchedulerRuntime2294Approval()
        let ledger = try ToolExecutionFactLedger(persistenceURL: f.root.appendingPathComponent("tool-facts.json"))
        let facts = ComposerPolicyFactSource(knownCapabilities: ["file_read"], grantedCapabilities: ["file_read"],
            allowedWriteRoots: [f.root.path], workspaceID: f.chat.composerWorkspaceID,
            revision: "scheduler2294-policy", grantEpoch: "scheduler2294-epoch", leaseID: "scheduler2294-lease",
            expiresAt: f.date.addingTimeInterval(120), autonomyCeiling: .l3)
        f.chat.configureComposerPolicy(facts)
        f.chat.composerPolicySelection = ComposerPolicySelection(mode: .auto,
            approvalScope: .request, effort: .high, bypassModeConfirmed: false)
        var original = try #require(f.ledger.task(id: f.taskID))
        original.authorizationPolicyRevision = facts.revision
        #expect(f.ledger.update(original, expectedVersion: original.version) == nil)
        var preview = try #require(f.ledger.preview(taskID: f.taskID, now: f.date))
        let anchor = try #require(f.chat.schedulerSourceAnchorDigest(
            sessionID: f.targetID, projectID: f.projectID, ordinal: 1))
        preview.observedSourceAnchorDigest = anchor
        preview.observedPolicyRevision = facts.revision
        #expect(f.ledger.confirmPreview(preview, actorID: "explicit-old-read-user", scopeID: f.projectID,
            policyRevision: facts.revision, now: f.date, sourceAnchorConfirmed: true,
            currentSourceAnchorDigest: anchor, currentPolicyRevision: facts.revision))
        let oldTask = try #require(f.ledger.task(id: f.taskID))
        let queued = try #require(f.ledger.reserveOccurrence(taskID: f.taskID, at: f.date))
        let newProject = "scheduler2294-new-project"
        let newID = f.chat.applyNewSession(title: "new scheduler target", projectID: newProject)
        try f.persistence.saveMessage(LLMMessage(role: .user, content: "different target source"), sessionID: newID.uuidString)
        let canonical = try #require(f.persistence.loadSession(id: newID.uuidString))
        #expect(f.chat.adoptScheduledCanonicalSession(canonical))
        #expect(f.chat.applySwitchSession(id: f.activeID))
        f.chat.draftText = "untouched active draft"
        var edited = oldTask
        edited.command = "new scheduler request"
        edited.targetSessionID = newID
        edited.targetProjectID = newProject
        #expect(f.ledger.update(edited, expectedVersion: oldTask.version) == nil)
        var newPreview = try #require(f.ledger.preview(taskID: f.taskID, now: f.date))
        let newAnchor = try #require(f.chat.schedulerSourceAnchorDigest(sessionID: newID, projectID: newProject, ordinal: 1))
        newPreview.observedSourceAnchorDigest = newAnchor
        newPreview.observedPolicyRevision = facts.revision
        #expect(f.ledger.confirmPreview(newPreview, actorID: "explicit-new-target-user", scopeID: newProject,
            policyRevision: facts.revision, now: f.date, sourceAnchorConfirmed: true,
            currentSourceAnchorDigest: newAnchor, currentPolicyRevision: facts.revision))
        let reopened = SchedulerTaskStore(defaults: f.defaults,
            occurrenceLedgerURL: f.root.appendingPathComponent("occurrences.json"))
        #expect(reopened.persistenceError == nil)
        #expect(reopened.isOccurrenceAuthorized(queued, now: f.date))
        let goal = GoalEnvelope(scopeID: f.projectID, allowedCapabilities: ["file_read"],
            fileRoots: [f.root.path], budget: 100, deadline: f.date.addingTimeInterval(3600),
            concurrencyLimit: 1, autonomyLevel: .l3, creatorID: "Scheduler2294", createdAt: f.date)
        let lease = AutonomyLease(goalID: goal.goalID, scopeID: goal.scopeID,
            issuedAt: f.date, expiresAt: goal.deadline)
        // The autonomous read positive uses the canonical low-risk policy.
        // A separate same-chain negative retains global alwaysAsk and the
        // denying delegate: changing Composer selection cannot bypass it.
        let readPolicy: ApprovalPolicy = change == "selectionOnly" ? .autoApprove : .alwaysAsk
        f.chat.agentEngine = AgentLoopChatEngine(toolExecutor: PolicyRuntimeBinding(goal: goal, lease: lease).wrap(executor),
            requestBudget: f.chat.budgetTracker,
            approvalGate: ApprovalGate(policyByTool: ["file_read": readPolicy], delegate: approval),
            toolExecutionFactLedger: ledger, composerPolicyFacts: facts)
        f.chat.streamingProviderOverride = provider
        f.chat.compactionProviderOverride = provider
        let gate = SchedulerRuntime2294Gate()
        defer { gate.finish() }
        let skills = SkillStore(skillsRoot: f.root.appendingPathComponent("skills"))
        var capturedTurn: AgentTurnIdentity?
        f.chat.turnRuntimeSnapshotFactory = { turn, _ in
            capturedTurn = turn
            return ChatTurnRuntimeSnapshot(turn: turn, skillInjector: SkillInjector(store: skills).snapshotForTurn(),
                mcpBridge: nil, speechToolAvailabilityPreparation: { gate.prepare() })
        }
        let runtime = f.makeRuntime(reopened)
        defer { runtime.stop() }
        if change == "bypassAtTrigger" || change == "bypassConfirmationDrift" {
            f.chat.restoreComposerPolicy(.default)
        }
        if change == "bypassAtTrigger" {
            f.chat.composerPolicySelection = ComposerPolicySelection(mode: .bypassPermission,
                approvalScope: .workspace, effort: .high, bypassModeConfirmed: true)
        }
        runtime.pollNow(at: f.date)
        for _ in 0..<300 {
            if gate.hasEntered { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(gate.hasEntered)
        let turn = try #require(capturedTurn)
        #expect(turn.sessionID == f.targetID.uuidString)
        #expect(reopened.occurrence(id: queued.id)?.executionTurnID == turn.turnID)
        // Leave the temporary bypass active in the trigger arm. In the drift
        // arm, confirm it only after the occurrence has captured its turn.
        if change == "bypassConfirmationDrift" {
            f.chat.composerPolicySelection = ComposerPolicySelection(mode: .bypassPermission,
                approvalScope: .workspace, effort: .low, bypassModeConfirmed: true)
        } else if change != "bypassAtTrigger" {
            f.chat.composerPolicySelection = ComposerPolicySelection(mode: .manual,
                approvalScope: .workspace, effort: .low, bypassModeConfirmed: false)
        }
        if change == "revoked" { #expect(reopened.revokeAuthorization(f.taskID)) }
        else if change == "policyExpired" { f.date = f.date.addingTimeInterval(121) }
        else if change == "leaseExpired" { f.date = f.date.addingTimeInterval(301) }
        gate.finish()
        for _ in 0..<500 {
            if reopened.occurrence(id: queued.id)?.state.isTerminal == true { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let accepted = change == "selectionOnly"
        let temporaryBypass = change == "bypassAtTrigger" || change == "bypassConfirmationDrift"
        let globalApprovalDenied = change == "selectionAlwaysAskDenied" || temporaryBypass
        #expect(provider.requestCount == (accepted || globalApprovalDenied ? 2 : 0))
        if temporaryBypass {
            let requests = await approval.requests
            #expect(requests.map(\.composerMode) == [ComposerTaskMode.manual.rawValue])
            #expect(requests.map(\.approvalScope) == [ComposerApprovalScope.request.rawValue])
        }
        #expect(executor.executionCount == (accepted ? 1 : 0))
        #expect(await approval.count == (globalApprovalDenied ? 1 : 0))
        #expect(ledger.facts.count == (accepted ? 1 : 0))
        let done = try #require(reopened.occurrence(id: queued.id))
        if accepted {
            #expect(done.state == .succeeded)
            #expect(provider.received.first?.last(where: { $0.role == .user })?.content == oldTask.command)
            #expect(provider.firstTools.contains("file_read"))
            #expect(!provider.firstTools.contains("speech"))
            #expect(executor.output?.contains("SCHED2294_OWNED_READ_BODY") == true)
            #expect(ledger.facts.first?.executionIdentity?.turn.sessionID == f.targetID.uuidString)
            #expect(done.submissionReceipt?.request.taskVersion == oldTask.version)
            #expect(done.submissionReceipt?.request.targetProjectID == f.projectID)
            #expect(done.sourceAnchorDigest == anchor)
            #expect(f.chat.scheduledTargetDelivery(for: done)?.occurrenceID == queued.id)
        } else if globalApprovalDenied {
            // The provider may finish after receiving the denied tool result;
            // this is not evidence of a tool effect or a minted tool fact.
            #expect(done.state == .succeeded)
            #expect(executor.output == nil)
            #expect(provider.received.first?.last(where: { $0.role == .user })?.content == oldTask.command)
            #expect(provider.firstTools.contains("file_read"))
            #expect(!provider.firstTools.contains("speech"))
            #expect(done.submissionReceipt?.request.taskVersion == oldTask.version)
            #expect(done.submissionReceipt?.request.targetSessionID == f.targetID)
            #expect(done.submissionReceipt?.request.targetProjectID == f.projectID)
            #expect(done.sourceAnchorDigest == anchor)
            #expect(f.chat.scheduledTargetDelivery(for: done)?.occurrenceID == queued.id)
        } else {
            #expect(done.state != .succeeded)
            #expect(f.persistence.loadSession(id: f.targetID.uuidString)?.messages == f.original)
        }
        #expect(f.persistence.loadSession(id: newID.uuidString)?.messages == canonical.messages)
        #expect(f.chat.activeSessionID == f.activeID)
        #expect(f.chat.draftText == "untouched active draft")
    }
}
