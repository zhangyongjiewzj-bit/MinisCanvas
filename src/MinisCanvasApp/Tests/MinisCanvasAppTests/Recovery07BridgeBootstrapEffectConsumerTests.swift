import CryptoKit
import Foundation
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

/// Fixed local responses, with the existing readiness/configuration contract.
/// This provider has no transport and never reads a credential.
private final class Recovery2011Provider: LLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    let name = "recovery2011-local"
    var model = LLMModel(id: "recovery2011-model", displayName: "Synthetic recovery", provider: "recovery2011-local")
    let capabilities: Set<ProviderCapability> = [.tools]
    var runtimeConfigurationMaterial: String? = "recovery2011-fixed-local"
    private let lock = NSLock()
    private var replies: [String]
    private var captured: [[LLMMessage]] = []
    init(readPath: String) throws {
        replies = [String(decoding: try JSONSerialization.data(withJSONObject: [
            "tool_calls": [["id": "recovery2011-fresh-read", "name": "file_read",
                "input": ["path": readPath]]]
        ]), as: UTF8.self), "fresh request completed"]
    }
    var requests: [[LLMMessage]] { lock.withLock { captured } }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        let reply = lock.withLock {
            captured.append(messages)
            return replies.isEmpty ? "unexpected extra request" : replies.removeFirst()
        }
        return LLMResponse(text: reply, stopReason: "stop", usage: nil)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt,
            maxTokens: maxTokens, temperature: temperature)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        Issue.record("non-streaming recovery fixture used streaming")
        return AsyncThrowingStream { $0.finish() }
    }
}

private actor Recovery2011Approval: ApprovalDelegate {
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        ApprovalDecision(approved: true, confirmed: true,
            requestID: request.requestID, bindingDigest: request.identityDigest)
    }
}

private enum Recovery2011EffectProducer {
    nonisolated static func write(root: URL, target: URL, content: String,
                                  receipt: ToolExecutionReceipt, ledger: ToolExecutionFactLedger) async throws {
        // Keep the non-Sendable built-in local to its execution context; the
        // MainActor App fixture receives only the durable receipt and bytes.
        let builtin = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        _ = try await executeToolWithTimeout(name: "file_write", timeout: nil,
            receipt: receipt, ledger: ledger) {
            try await builtin.execute(name: "file_write", input: [
                "path": target.path, "content": content, "append": true
            ])
        }
    }
}

@Suite("Recovery07 Bridge bootstrap effect consumer", .serialized)
@MainActor
struct Recovery07BridgeBootstrapEffectConsumerTests {
    @Test("startup reconciles only an attributed write, never dispatches restored tasks, and admits a fresh request")
    func attributedEffectReopenDoesNotResubmitUnfinishedTasks() async throws {
        let profile = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = profile.rootDirectory.appendingPathComponent("recovery2011-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let suite = "recovery2011-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sessionDirectory = root.appendingPathComponent("sessions")
        let taskURL = root.appendingPathComponent("tasks.json")
        let effectURL = sessionDirectory.appendingPathComponent("tool-execution-facts-v4.json")
        let sessions = SessionStore(directory: sessionDirectory)
        let thread = ChatThread(title: "owned unfinished recovery")
        try sessions.updateSession(thread.asPersisted())
        let firstTasks = try AgentTaskStore(persistenceURL: taskURL)
        let controller = TurnController()
        let turn = await controller.beginTurn()
        defer { Task { await turn.finish() } }
        let parent = try ParentRuntimeIdentitySeed(sessionID: thread.id.uuidString,
            conversationID: thread.id.uuidString, taskID: "recovery2011-parent", actorID: "owned-test")
            .makeIdentity(using: turn)
        _ = try firstTasks.enqueue(taskID: "running-child", parentID: parent.taskID,
            providerID: "synthetic", modelID: "synthetic", parentRuntimeIdentity: parent)
        _ = try firstTasks.startRun(taskID: "running-child", parentID: parent.taskID, runID: "old-run")
        _ = try firstTasks.enqueue(taskID: "queued-child", parentID: parent.taskID,
            providerID: "synthetic", modelID: "synthetic", parentRuntimeIdentity: parent)
        let attemptID = try #require(firstTasks.canonicalAttemptID(runID: "old-run"))
        let locator = ChildTranscriptLocator(childSessionID: "recovery2011-child",
            parentSessionID: thread.id.uuidString, taskID: "running-child", parentID: parent.taskID,
            runID: "old-run", attemptID: attemptID, childExecutionID: "old-child-execution",
            parentContextSnapshotID: nil)
        _ = try firstTasks.bindChildTranscript(locator)
        let turnNumber = try #require(Int(parent.turnID.split(separator: ":").last ?? ""))
        let identity = AgentExecutionIdentity(turn: .init(sessionID: locator.childSessionID,
            turnID: turnNumber, messageID: locator.taskID), operationID: locator.runID, attempt: 1)
        let firstEffects = try ToolExecutionFactLedger(persistenceURL: effectURL)
        let completed = try firstEffects.mint(toolCallID: "owned-completed-write", toolName: "file_write",
            attemptID: attemptID, attemptNumber: 1, executionIdentity: identity,
            parentRuntimeIdentity: parent, childTranscriptLocator: locator)
        let target = root.appendingPathComponent("owned.txt")
        let content = "one owned append\n"
        // Enter the real receipt-aware dispatch and built-in file writer. Do
        // not perform AgentLoop's later settle: the persisted effect is known
        // but the task and tool receipt are still unfinished at this boundary.
        try await Recovery2011EffectProducer.write(root: root, target: target, content: content,
            receipt: completed, ledger: firstEffects)
        let unknown = try firstEffects.mint(toolCallID: "unknown-write", toolName: "file_write",
            attemptID: attemptID, attemptNumber: 1, executionIdentity: identity,
            parentRuntimeIdentity: parent, childTranscriptLocator: locator)
        try firstEffects.prepareFileWrite(unknown)
        try firstEffects.beginFileWrite(unknown, targetPath: target.path,
            expectedSHA256: SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined(),
            beforeSHA256: nil)
        #expect(firstEffects.pendingReceipts.count == 2 && firstEffects.facts.isEmpty)
        let taskBytes = try Data(contentsOf: taskURL)
        let ownedBytes = try Data(contentsOf: target)

        // Fresh production stores and the same App composition entry used at
        // startup. This is a store/engine reopen, not an OS process relaunch.
        let readiness = ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        let provider = try Recovery2011Provider(readPath: target.path)
        let now = Date()
        let lineage = ProviderReadinessLineage.derived(providerID: provider.name,
            modelID: provider.model.id, checkedAt: now)
        try #require(readiness.upsert([ProviderReadinessPersistenceRecord(providerID: provider.name,
            modelID: provider.model.id, status: .passed, readinessState: .mock, checkedAt: now,
            evidenceID: "recovery2011-owned-local", isApplied: false,
            discoveryReceiptID: lineage.discoveryReceiptID, discoveredAt: lineage.discoveredAt)]))
        try #require(readiness.applyDiscoveredModels(providerID: provider.name,
            modelIDs: [provider.model.id], appliedAt: now.addingTimeInterval(1)).count == 1)
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let bridge = try BridgeStore(taskStorePersistenceURL: taskURL,
            shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("workflows")),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            sessionDocumentStore: SessionDocumentStore(directory: sessionDirectory),
            sessionStore: SessionStore(directory: sessionDirectory),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            providerReadinessStore: readiness, canvasFeatureLane: .phase3NonCanvas)
        bridge.chat.streamingProviderOverride = provider
        await bridge.attachProductionServices(fileAccessAllowedRoot: root, fileAccessDeniedRoots: [],
            sessionDirectory: sessionDirectory,
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            approvalDelegateOverride: Recovery2011Approval(), enableOrchestration: true, externalRunners: [:],
            sessionReadSecretStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain)
        ).value
        let recoveredEngine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        try #require(bridge.orchestrationEnabled)
        #expect(bridge.orchestrationTaskStore === bridge.agentTaskStore)
        #expect(recoveredEngine.orchestrationTaskStore === bridge.agentTaskStore)
        let ledger = recoveredEngine.toolExecutionFactLedger
        let deadline = ContinuousClock.now + .seconds(5)
        while ledger.facts.isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(ledger.facts.map(\.receiptID) == [completed.receiptID])
        #expect(ledger.facts.first?.parentRuntimeIdentity == parent)
        #expect(ledger.facts.first?.childTranscriptLocator == locator)
        #expect(ledger.pendingReceipts == [unknown], "matching bytes cannot settle an unrelated receipt")
        #expect(bridge.agentTaskStore.recoveryState(runID: "old-run") == .needsUserReview)
        #expect(bridge.taskCenterObservation.counts.running == 1)
        #expect(bridge.taskCenterObservation.counts.queued == 1)
        #expect(bridge.agentTaskStore.attempts(runID: "old-run").map(\.attemptID) == [attemptID])
        #expect(try Data(contentsOf: taskURL) == taskBytes)
        #expect(try Data(contentsOf: target) == ownedBytes)
        #expect(provider.requests.isEmpty && bridge.actionHistory.records.isEmpty)

        // A new Composer submission creates its current task/turn identity;
        // it must not be rejected merely because another task is unfinished.
        bridge.chat.composerPolicySelection = ComposerPolicySelection(mode: .manual,
            approvalScope: .request, effort: .standard, bypassModeConfirmed: false)
        bridge.chat.draftText = "Read the owned file in a new independent task."
        bridge.chat.submitComposer()
        let freshDeadline = ContinuousClock.now + .seconds(5)
        while (bridge.chat.isStreaming || provider.requests.count < 2 || bridge.actionHistory.records.isEmpty)
            && ContinuousClock.now < freshDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!bridge.chat.isStreaming)
        #expect(provider.requests.count == 2)
        #expect(bridge.actionHistory.records.map(\.toolName) == ["file_read"])
        let freshFact = try #require(ledger.facts.first { $0.toolName == "file_read" })
        #expect(freshFact.status == .succeeded)
        #expect(freshFact.executionIdentity != identity)
        #expect(ledger.pendingReceipts == [unknown])
        #expect(ledger.facts.filter { $0.toolName == "file_write" }.map(\.receiptID) == [completed.receiptID])
        #expect(bridge.agentTaskStore.recoveryState(runID: "old-run") == .needsUserReview)
        #expect(try Data(contentsOf: target) == ownedBytes)
    }
}
