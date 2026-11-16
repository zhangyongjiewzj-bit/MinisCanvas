import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// Reuses donor18baf's same-run prompt conflict assertion, but first proves a
/// valid normal production request. Canonical event/receipt producers share
/// that turn identity; a second engine avoids merely testing replay rejection.
@Suite("D-CTX4 durable context receipt boundary", .serialized)
@MainActor
struct P3AcceptanceM03_ContextDurableReceiptBoundaryTests {
    enum Drift: Sendable, CaseIterable { case prompt, budget }

    @Test("same-turn model projection cannot replace canonical facts", arguments: Drift.allCases)
    func changedPromptCannotOverwriteRecordedRun(_ drift: Drift) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctx705-durable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let journalURL = root.appendingPathComponent("context-manifests.json")
        let store = try ContextManifestStore(persistenceURL: journalURL)
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let sessionID = "ctx705-owned-session"
        _ = try sessions.createSession(id: sessionID)
        try sessions.saveMessage(.init(role: .user, content: "canonical owned request"), sessionID: sessionID)
        let skills = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let tasksURL = root.appendingPathComponent("tasks.json")
        let effectsURL = root.appendingPathComponent("effects.json")
        let tasks = try AgentTaskStore(persistenceURL: tasksURL)
        let effects = try ToolExecutionFactLedger(persistenceURL: effectsURL)
        let turn = AgentTurnIdentity(sessionID: sessionID, turnID: 7, messageID: "ctx705-assistant")
        let identity = AgentExecutionIdentity(turn: turn, operationID: "ctx705-operation", attempt: 1)
        let source = ParentRuntimeIdentity(sessionID: sessionID, conversationID: sessionID,
            turnID: "7", taskID: "ctx705-task", actorID: "ctx705-owner")
        let facts = ComposerPolicyFactSource(knownCapabilities: [], grantedCapabilities: [],
            allowedWriteRoots: [], workspaceID: "ctx705-workspace", revision: "ctx705-policy",
            grantEpoch: "ctx705-grant", leaseID: "ctx705-lease", expiresAt: .distantFuture, autonomyCeiling: .l3)
        let composer = ComposerSubmissionSnapshot(mode: .auto, approvalScope: .request,
            effort: .standard, sessionID: sessionID, turnID: turn.turnID,
            taskID: "ctx705-task", attemptID: "ctx705-attempt", messageID: turn.messageID,
            inputDigest: "ctx705-digest", workspaceID: facts.workspaceID, createdAt: Date(),
            policyRevision: facts.revision, grantEpoch: facts.grantEpoch, autonomyCeiling: .l3)
        let runtime = ChatTurnRuntimeSnapshot(turn: turn,
            skillInjector: SkillInjector(store: skills).snapshotForTurn(), mcpBridge: nil)
        let dependencies = AgentLoopChatEngine.ChatSessionRuntimeDependencies(
            sessionStore: sessions, memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            skillStore: skills, soulStore: SoulStore(directory: root.appendingPathComponent("soul")))
        let recorder = M03ContextRequestRecorder(holdFirst: true)
        let provider = M03ContextRecordingProvider(recorder: recorder)
        let executor = Context705NoEffectExecutor()
        let engine = AgentLoopChatEngine(toolExecutor: executor, taskStore: tasks,
            contextManifestStore: store, chatRuntimeDependencies: dependencies,
            toolExecutionFactLedger: effects, composerPolicyFacts: facts)
        let originalPrompt = "original owned prompt"
        let stream = try await engine.streamReply(provider: provider,
            history: [.init(role: .user, content: "canonical owned request")],
            systemPrompt: originalPrompt, maxTokens: 512, conversationID: sessionID,
            authorizedSessionReadSessionID: nil, authorizedSessionReadScope: nil,
            turnID: turn.turnID, composerSnapshot: composer, executionIdentity: identity,
            turnRuntimeSnapshot: runtime)
        for _ in 0..<200 {
            if await recorder.recorded().count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        // The admitted provider is still suspended: canonical event and
        // receipt producers now settle facts while a same-turn model
        // projection competes for the already durable manifest.
        _ = try AgentTaskCreationConsumer(store: tasks, knownProjectIDs: ["ctx705-project"],
            authorizedScopeIDs: ["ctx705-scope"]).consume(AgentTaskCreationRequest(
                taskID: "ctx705-event", parentID: source.taskID, source: source,
                title: "Canonical owned event", projectID: "ctx705-project",
                scopeID: "ctx705-scope", idempotencyKey: "ctx705-event-key"))
        _ = try tasks.startRun(taskID: "ctx705-event", parentID: source.taskID, runID: "ctx705-durable-run")
        _ = try tasks.appendEvent(runID: "ctx705-durable-run", kind: .progress, detail: "canonical same-turn progress")
        _ = try tasks.finish(runID: "ctx705-durable-run", outcome: .succeeded)
        let canonicalEvents = tasks.events(runID: "ctx705-durable-run")
        let canonicalTaskReceipt = try #require(tasks.receipt(runID: "ctx705-durable-run"))
        #expect(!canonicalEvents.isEmpty)
        let effect = try effects.mint(toolCallID: "ctx705-read", toolName: "file_read",
            attemptID: "ctx705-effect-attempt", attemptNumber: 1, executionIdentity: identity)
        _ = try effects.settle(effect, status: .succeeded)

        #expect(await recorder.recorded().count == 1)
        let runID = try AgentLoopChatEngine.generatedContextManifestRunID(for: identity)
        let manifest = try #require(store.manifest(runID: runID))
        let receipt = try #require(store.receipt(runID: runID))
        let canonical = try #require(sessions.loadSession(id: sessionID))
        let originalEffects = effects.facts
        #expect(originalEffects.count == 1 && originalEffects.first?.status == .succeeded)
        let journalBytes = try Data(contentsOf: journalURL)
        let taskBytes = try Data(contentsOf: tasksURL)
        let effectBytes = try Data(contentsOf: effectsURL)
        let changedPrompt = drift == .prompt ? "different owned model projection" : originalPrompt
        let result = ContextOrchestrator().makeManifest(.init(snapshot: manifest.snapshot,
            contextItems: [ContextItem(identifier: "system-prompt", content: changedPrompt,
                tokenCost: max(1, changedPrompt.count / 4), level: .l0,
                scope: "conversation", provenance: "chat.system", required: true)]),
            budget: receipt.requestedBudget + (drift == .budget ? 1 : 0))
        let competingEngine = AgentLoopChatEngine(toolExecutor: executor, taskStore: tasks,
            contextManifestStore: store, chatRuntimeDependencies: dependencies,
            contextManifestInput: .init(snapshot: manifest.snapshot, result: result, runID: runID),
            toolExecutionFactLedger: effects, composerPolicyFacts: facts)
        await #expect(throws: AgentLoopChatEngine.ContextManifestConsumptionError.persistenceFailed) {
            _ = try await competingEngine.streamReply(provider: provider,
                history: [.init(role: .user, content: "a changed projection cannot rewrite history")],
                systemPrompt: changedPrompt, maxTokens: 512, conversationID: sessionID,
                authorizedSessionReadSessionID: nil, authorizedSessionReadScope: nil,
                turnID: turn.turnID, composerSnapshot: composer, executionIdentity: identity,
                turnRuntimeSnapshot: runtime)
        }
        #expect(await recorder.recorded().count == 1)
        #expect(executor.calls == 0)
        await recorder.releaseFirst()
        for try await _ in stream {}
        #expect(try Data(contentsOf: journalURL) == journalBytes)
        #expect(try Data(contentsOf: tasksURL) == taskBytes)
        #expect(try Data(contentsOf: effectsURL) == effectBytes)
        #expect(sessions.loadSession(id: sessionID) == canonical)
        let restarted = try ContextManifestStore(persistenceURL: journalURL)
        #expect(restarted.manifest(runID: runID) == manifest)
        #expect(restarted.receipt(runID: runID) == receipt)
        let reloadedEffects = try ToolExecutionFactLedger(persistenceURL: effectsURL)
        #expect(reloadedEffects.facts == originalEffects)
        let reloadedTasks = try AgentTaskStore(persistenceURL: tasksURL)
        #expect(reloadedTasks.events(runID: "ctx705-durable-run") == canonicalEvents)
        #expect(reloadedTasks.receipt(runID: "ctx705-durable-run") == canonicalTaskReceipt)
        #expect(reloadedTasks.snapshot(taskID: "ctx705-event") == tasks.snapshot(taskID: "ctx705-event"))
        print("CTX705_DURABLE drift=\(drift) actualProviderCalls=1 extraProvider=0 effects=0 sameTurn=7 bytesUnchanged=true reloadUnchanged=true")
    }
}

private final class Context705NoEffectExecutor: ToolExecutor, @unchecked Sendable {
    private(set) var calls = 0
    nonisolated(nonsending) func execute(name: String, input: [String: Any]) async throws -> String {
        calls += 1
        return "unexpected owned effect"
    }
}
