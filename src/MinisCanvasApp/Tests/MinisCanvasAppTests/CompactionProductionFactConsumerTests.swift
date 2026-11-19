import Foundation
import Testing
@testable import MinisCore
@testable import MinisCanvasApp

private final class FactContextProvider: LLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    let name = "fact-context"
    var runtimeConfigurationMaterial: String? = "owned-fact-context3208"
    var model = LLMModel(id: "fact-context", displayName: "Fact context", provider: "test")
    var capabilities: Set<ProviderCapability> { [.tools] }
    private(set) var requests: [[LLMMessage]] = []
    private(set) var receivedRequestPayloads2932: [Data] = []
    var proposeWritePath: String?
    var proposeAdditionalWritePath: String?
    private var proposedWriteCount = 0
    private(set) var summaryRequests: [[LLMMessage]] = []
    private(set) var dialogueRequests: [[LLMMessage]] = []
    private(set) var offeredToolNames: [[String]] = []
    private(set) var streamCallCount = 0
    var dialogueUsage: LLMUsage?
    var beforeDialogueResponse: (@Sendable () async throws -> Void)?
    /// 摘要请求返回之前执行（模拟摘要期间任务换了状态）。
    var beforeSummaryResponse: (@Sendable () async throws -> Void)?
    private func captureProviderArguments2932(
        messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition]?,
        maxTokens: Int, temperature: Double?
    ) throws {
        let actualTools: Any
        if let tools {
            actualTools = tools.map { definition -> [String: Any] in
                ["openAIFunction": definition.openAIFunctionDict,
                 "propertyOrdering": definition.propertyOrdering.map { $0 as Any } ?? NSNull()]
            }
        } else {
            actualTools = NSNull()
        }
        let values: [String: Any] = [
            "messages": try JSONSerialization.jsonObject(with: JSONEncoder().encode(messages)),
            "systemPrompt": systemPrompt.map { $0 as Any } ?? NSNull(),
            "tools": actualTools, "maxTokens": maxTokens,
            "temperature": temperature.map { $0 as Any } ?? NSNull(),
            "providerName": name, "modelID": model.id
        ]
        receivedRequestPayloads2932.append(try JSONSerialization.data(
            withJSONObject: values, options: [.prettyPrinted, .sortedKeys]))
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        try captureProviderArguments2932(messages: messages, systemPrompt: systemPrompt,
            tools: nil, maxTokens: maxTokens, temperature: temperature)
        requests.append(messages)
        summaryRequests.append(messages)
        try await beforeSummaryResponse?()
        return try response()
    }

    private func response(usage: LLMUsage? = nil) throws -> LLMResponse {
        if let path = proposeWritePath {
            proposeWritePath = proposeAdditionalWritePath
            proposeAdditionalWritePath = nil
            proposedWriteCount += 1
            let arguments: [String: Any] = ["path": path, "content": "must be refused"]
            let data = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
            let raw = String(decoding: data, as: UTF8.self)
            return LLMResponse(text: "fresh write attempt", stopReason: "tool_calls", usage: nil,
                toolCalls: [LLMToolCall(id: proposedWriteCount == 1 ? "new-write" : "new-write-\(proposedWriteCount)", name: "file_write",
                    rawArguments: raw, arguments: arguments)])
        }
        return LLMResponse(text: "The assistant compared the distinct options and recorded the tradeoffs.",
            stopReason: "stop", usage: usage)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?,
                     tools: [AgentToolDefinition], maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        try captureProviderArguments2932(messages: messages, systemPrompt: systemPrompt,
            tools: tools, maxTokens: maxTokens, temperature: temperature)
        offeredToolNames.append(tools.map(\.name))
        requests.append(messages)
        dialogueRequests.append(messages)
        try await beforeDialogueResponse?()
        return try response(usage: dialogueUsage)
    }

    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        streamCallCount += 1
        return AsyncThrowingStream { $0.finish() }
    }
}

private final class FactContextExecutor: ToolExecutor, @unchecked Sendable {
    private(set) var count = 0
    var effectMarkerURL: URL?
    var submittedLedgerURL: URL?
    private struct SubmittedState: Decodable { let pending: [String: ToolExecutionReceipt] }
    private(set) var observedReceipts: [ToolExecutionReceipt] = []
    private enum ObservationError: Error { case missingSubmittedReceipt }
    func execute(name: String, input: [String: Any]) async throws -> String {
        if let effectMarkerURL {
            guard let receipt = ToolExecutionReceiptContext.current,
                  let submittedLedgerURL,
                  try JSONDecoder().decode(SubmittedState.self, from: Data(contentsOf: submittedLedgerURL))
                    .pending.values.contains(receipt) else {
                throw ObservationError.missingSubmittedReceipt
            }
            observedReceipts.append(receipt)
            try Data("synthetic effect \(count + 1)".utf8).write(to: effectMarkerURL, options: .atomic)
        }
        count += 1
        return effectMarkerURL == nil ? "unexpected execution" : "synthetic effect completed"
    }
}

@Suite("Compaction production store facts", .serialized)
@MainActor
struct CompactionProductionFactConsumerTests {
    private struct Fixture {
        let root: URL
        let id: UUID
        let sessions: SessionStore
        let tasks: AgentTaskStore
        let ledger: ToolExecutionFactLedger
        let engine: AgentLoopChatEngine
        let executor: FactContextExecutor
        let skills: SkillStore
        // Keep the canonical same-root settings owner alive for direct engines.
        // Otherwise another suite's active owner can correctly reject this root.
        let settingsCenter: SettingsCenter
        let history: [ChatMessageUI]
    }

    private func fixture(withFacts: Bool = true, currentWriteGrant: Bool = false) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("compact-facts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID()
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let tasks = try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json"))
        let ledger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("effects.json"))
        var history = [ChatMessageUI(role: .user,
            content: "Goal: compare repair choices. Keep the original title. Earlier authorization was read-only.")]
        // Every paragraph has different content. Compression cannot rely on
        // duplicate-message grouping or trimming an arbitrary prefix.
        for index in 0..<18 {
            history.append(ChatMessageUI(role: .assistant, content: (0..<24).map { detail in
                "Option \(index), consideration \(detail): observed coefficient \(index * 31 + detail), cost \(index + detail + 2), dependency \(index * 7 - detail), and fallback route \(detail % 5) need distinct evaluation."
            }.joined(separator: " ")))
            history.append(ChatMessageUI(role: .user, content: "For option \(index), also compare dependency \(index + 4)."))
        }
        history.append(ChatMessageUI(role: .user, content: "Continue the comparison; do not write any files."))
        let thread = ChatThread(id: id, messages: history, transcriptRevision: UInt64(history.count))
        try sessions.updateSession(thread.asPersisted())
        if withFacts {
            let source = ParentRuntimeIdentity(sessionID: id.uuidString, conversationID: id.uuidString,
                turnID: "turn-handle:1", taskID: "parent", actorID: "actor")
            _ = try AgentTaskCreationConsumer(store: tasks, knownProjectIDs: ["project"],
                authorizedScopeIDs: ["scope"]).consume(AgentTaskCreationRequest(
                    taskID: "compare-open", parentID: "parent", source: source,
                    title: "Compare the remaining repair choice", projectID: "project",
                    scopeID: "scope", idempotencyKey: "create-open"))
            let identity = AgentExecutionIdentity(turn: .init(sessionID: id.uuidString,
                turnID: 1, messageID: "historical-tool-message"), operationID: "read-operation", attempt: 1)
            let receipt = try ledger.mint(toolCallID: "read-done", toolName: "file_read",
                attemptID: "read-attempt", attemptNumber: 1, executionIdentity: identity)
            _ = try ledger.settle(receipt, status: .succeeded)
        }
        let skills = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let defaults = try #require(UserDefaults(suiteName: "compact-owned2496-" + id.uuidString))
        let settingsCenter = settingsCenter442(root: root, sessions: sessions,
            skills: skills, defaults: defaults, usageID: id)
        #expect(SettingsCenter.active === settingsCenter)
        let executor = FactContextExecutor()
        let engine = AgentLoopChatEngine(toolExecutor: executor, taskStore: tasks,
            chatRuntimeDependencies: .init(sessionStore: sessions,
                memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
                skillStore: skills, soulStore: SoulStore(directory: root.appendingPathComponent("soul"))),
            contextWritebackStorePersistenceURL: root.appendingPathComponent("context.json"),
            toolExecutionFactLedger: ledger,
            composerPolicyFacts: ComposerPolicyFactSource(knownCapabilities: ["file_write"],
                grantedCapabilities: currentWriteGrant ? ["file_write"] : [],
                allowedWriteRoots: [root.path], workspaceID: "workspace",
                revision: "current-policy", grantEpoch: "current-epoch", leaseID: "current-lease",
                expiresAt: .distantFuture, autonomyCeiling: .l3))
        return Fixture(root: root, id: id, sessions: sessions, tasks: tasks, ledger: ledger,
            engine: engine, executor: executor, skills: skills,
            settingsCenter: settingsCenter, history: history)
    }

    private func result(_ f: Fixture, provider: FactContextProvider) async throws -> CompactionResult {
        let canonical = try #require(f.sessions.loadSession(id: f.id.uuidString))
        return try await f.engine.compactContext(provider: provider, history: f.history,
            systemPrompt: "test", keepRecent: 1, sourceSessionID: f.id.uuidString,
            sourceTranscriptRevision: canonical.transcriptRevision)
    }

    private func runAutomatic(_ f: Fixture, engine: AgentLoopChatEngine,
                              provider: FactContextProvider, turnID: Int = 70) async throws {
        defer { withExtendedLifetime(f.settingsCenter) {} }
        let canonical = try #require(f.sessions.loadSession(id: f.id.uuidString))
        let turn = AgentTurnIdentity(sessionID: canonical.id, turnID: turnID, messageID: "auto-assistant-\(turnID)")
        let composer = ComposerSubmissionSnapshot(mode: .plan, approvalScope: .request,
            effort: .standard, sessionID: turn.sessionID, turnID: turn.turnID,
            taskID: "auto", attemptID: "auto-attempt-\(turnID)", messageID: turn.messageID,
            inputDigest: "auto-input", workspaceID: "workspace", createdAt: Date(),
            policyRevision: "current-policy", grantEpoch: "current-epoch", autonomyCeiling: .l3)
        let stream = try await engine.streamReply(provider: provider,
            history: canonical.messages.map { $0.asChatMessageUI() }, systemPrompt: "test", maxTokens: 256,
            conversationID: canonical.id, authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil, turnID: turn.turnID, composerSnapshot: composer,
            executionIdentity: .init(turn: turn, operationID: "auto-operation-\(turnID)", attempt: 1),
            turnRuntimeSnapshot: .init(turn: turn,
                skillInjector: SkillInjector(store: f.skills).snapshotForTurn(), mcpBridge: nil))
        for try await _ in stream {}
    }

    private func automaticEngine(_ f: Fixture, policy: RequestBudget.Policy = .autoCompact)
        -> (AgentLoopChatEngine, BudgetTracker) {
        let budget = BudgetTracker(RequestBudget(maxRequestsPerSession: 1, overBudgetPolicy: policy))
        var engine = f.engine.withRequestBudget(budget)
        engine.loop.compactor = Compactor(keepRecentMessages: 1)
        return (engine, budget)
    }

    @Test func foreignSettingsOwnerRefusesAutomaticTurnBeforeProviderOrCheckpoint2496() async throws {
        let f = try fixture(currentWriteGrant: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let source = try #require(f.sessions.loadSession(id: f.id.uuidString))
        let oldFacts = f.ledger.facts
        let defaults = try #require(UserDefaults(suiteName: "compact-foreign2496-" + f.id.uuidString))
        let foreignSessions = SessionStore(directory: f.root.appendingPathComponent("foreign-sessions2496"))
        let foreign = settingsCenter442(root: f.root, sessions: foreignSessions,
            skills: f.skills, defaults: defaults, usageID: f.id)
        defer { withExtendedLifetime(foreign) {} }
        #expect(SettingsCenter.active === foreign)
        #expect(f.settingsCenter.sessionStore === f.sessions)
        let provider = FactContextProvider()
        let (engine, _) = automaticEngine(f)
        do {
            try await runAutomatic(f, engine: engine, provider: provider, turnID: 2496)
            Issue.record("A foreign SettingsCenter must not configure this actual AgentLoop turn")
        } catch AgentLoopChatEngine.ContextManifestConsumptionError.contextSettingsScopeMismatch {
            // Keep the production root guard: rejection occurs before the first
            // actual dialogue, summary, checkpoint or executor effect.
        }
        #expect(provider.requests.isEmpty)
        #expect(provider.dialogueRequests.isEmpty)
        #expect(provider.summaryRequests.isEmpty)
        #expect(f.executor.count == 0)
        #expect(f.ledger.facts == oldFacts)
        #expect(f.sessions.loadSession(id: source.id) == source)
        #expect(try f.sessions.loadLatestCompactionCheckpoint(sessionID: source.id) == nil)
    }

    @Test func budgetAutoCompactsNaturalCanonicalHistoryAndContinuesWithCurrentPlanFeedback() async throws {
        let f = try fixture(currentWriteGrant: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let source = try #require(f.sessions.loadSession(id: f.id.uuidString))
        let oldFacts = f.ledger.facts
        let provider = FactContextProvider()
        provider.proposeWritePath = f.root.appendingPathComponent("auto-must-not-exist.txt").path
        let (engine, tracker) = automaticEngine(f)
        try await runAutomatic(f, engine: engine, provider: provider)
        let checkpoint = try #require(try f.sessions.loadLatestCompactionCheckpoint(sessionID: source.id))
        #expect(checkpoint.schemaVersion == CompactionCheckpoint.lossySummarySchemaVersion)
        // 压缩后只带未完成的任务；账本里已成功的回执（read-done）不再进背景。
        #expect(checkpoint.retentionFacts?.count == 1)
        #expect(checkpoint.retentionFacts?.first?.kind == .unfinishedTask)
        #expect(checkpoint.retentionFacts?.contains { $0.source?.effect != nil } == false)
        #expect(checkpoint.sourceTranscriptRevision == source.transcriptRevision)
        #expect(checkpoint.retentionFacts?.allSatisfy { $0.source?.matchesTranscript(source.messages) == true } == true)
        #expect(provider.summaryRequests.count == 1)
        #expect(provider.dialogueRequests.count == 2)
        let continued = try #require(provider.dialogueRequests.last)
        #expect(continued.starts(with: checkpoint.replacementHistory))
        #expect(continued.filter { $0.toolCallID == "new-write" }.count == 1)
        #expect(continued.contains { $0.toolCallID == "new-write" && $0.content.contains("dry-run") })
        // Older turns are summarized by the model (lossy): the old text went to the
        // summary request whole, and the continued request carries only the summary.
        #expect(provider.summaryRequests.flatMap { $0 }.contains { $0.content.contains("Earlier authorization was read-only") })
        #expect(continued.contains { $0.content.contains("<context-summary>") })
        #expect(continued.contains { $0.content.contains("compare-open") })
        #expect(!continued.contains { $0.content.contains(oldFacts[0].receiptID) })
        #expect(Compactor.hasMaterialRequestReduction(from: source.messages, to: continued))
        #expect(await tracker.budget.usedRequests == provider.requests.count)
        #expect(await tracker.pendingRequestCount == 0)
        #expect(f.executor.count == 0)
        #expect(f.ledger.facts == oldFacts)
        #expect(!FileManager.default.fileExists(atPath: provider.proposeWritePath ?? f.root.appendingPathComponent("auto-must-not-exist.txt").path))
        let restarted = SessionStore(directory: f.root.appendingPathComponent("sessions"))
        #expect(restarted.loadSession(id: source.id)?.messages == source.messages)
        #expect(try ChatSessionBridge.resumeCanonicalMessages(sessionStore: restarted,
            sessionID: source.id, taskStore: f.tasks, effectLedger: f.ledger) == checkpoint.replacementHistory)
    }

    /// F-03：回合内压缩的摘要请求进行期间，本会话的任务换了状态（排队改成运行）。
    /// 提交后重读重建的背景和检查点里存的不同，这不算不一致：压缩照常成功，不隔离会话，回合继续。
    @Test func taskStateChangingDuringTheSummaryDoesNotFailTheInLoopCompactionOrIsolateTheSession() async throws {
        let f = try fixture(currentWriteGrant: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let source = try #require(f.sessions.loadSession(id: f.id.uuidString))
        let provider = FactContextProvider()
        provider.proposeWritePath = f.root.appendingPathComponent("auto-must-not-exist.txt").path
        let tasks = f.tasks
        provider.beforeSummaryResponse = {
            _ = try tasks.startRun(taskID: "compare-open", parentID: "parent", runID: "compare-run")
        }
        let (engine, _) = automaticEngine(f)
        try await runAutomatic(f, engine: engine, provider: provider)
        let checkpoint = try #require(try f.sessions.loadLatestCompactionCheckpoint(sessionID: source.id))
        #expect(checkpoint.schemaVersion == CompactionCheckpoint.lossySummarySchemaVersion)
        // 检查点里存的是摘要请求之前取的状态（排队）；之后重建的背景是运行中。
        #expect(checkpoint.retentionFacts?.contains { $0.text.contains("status=queued") } == true)
        let rebuilt = try ChatSessionBridge.resumeCanonicalMessages(sessionStore: f.sessions,
            sessionID: source.id, taskStore: f.tasks, effectLedger: f.ledger)
        #expect(rebuilt.contains { $0.content.contains("status=running") })
        #expect(ChatSessionBridge.resumedMatchesCheckpoint(rebuilt, checkpoint: checkpoint, live: []))
        #expect(provider.dialogueRequests.count == 2)
        // 会话没有被隔离：规范记录原样还在。
        #expect(f.sessions.loadSession(id: source.id)?.messages == source.messages)
    }

    @Test func resumedBackgroundComparisonIgnoresTheBackgroundButNotTheSummaryOrTail() {
        let summary = LLMMessage(role: .user, content: "<context-summary>\n摘要\n</context-summary>")
        let oldBackground = LLMMessage(role: .user, content: "<retained-store-facts>\nstatus=queued\n</retained-store-facts>")
        let newBackground = LLMMessage(role: .user, content: "<retained-store-facts>\nstatus=running\n</retained-store-facts>")
        let tail = [LLMMessage(role: .user, content: "问"), LLMMessage(role: .assistant, content: "答")]
        let live = [LLMMessage(role: .assistant, content: "实时")]
        let checkpoint = CompactionCheckpoint(
            schemaVersion: CompactionCheckpoint.lossySummarySchemaVersion, sessionID: "s",
            sourceTranscriptRevision: 1, resultTranscriptRevision: 2, compactedThroughMessageID: "m",
            compactedMessageRange: 0..<3, summaryMessage: summary,
            replacementHistory: [summary, oldBackground] + tail, projectionRecentCount: tail.count,
            contentDigest: "")
        #expect(ChatSessionBridge.resumedMatchesCheckpoint(
            [summary, newBackground] + tail + live, checkpoint: checkpoint, live: live))
        // 背景没有了（任务都结束了）也算一致。
        #expect(ChatSessionBridge.resumedMatchesCheckpoint([summary] + tail + live, checkpoint: checkpoint, live: live))
        // 摘要或尾部不同仍然不一致。
        let otherSummary = LLMMessage(role: .user, content: "<context-summary>\n别的\n</context-summary>")
        #expect(!ChatSessionBridge.resumedMatchesCheckpoint(
            [otherSummary, newBackground] + tail + live, checkpoint: checkpoint, live: live))
        #expect(!ChatSessionBridge.resumedMatchesCheckpoint(
            [summary, newBackground, tail[0], LLMMessage(role: .assistant, content: "改过")] + live,
            checkpoint: checkpoint, live: live))
        // 多出来的不是背景的消息不算。
        #expect(!ChatSessionBridge.resumedMatchesCheckpoint(
            [summary, LLMMessage(role: .user, content: "夹带")] + tail + live, checkpoint: checkpoint, live: live))
    }

    @Test func secondBudgetAutoRebuildsFromCanonicalAfterLongNewConversation() async throws {
        let f = try fixture(currentWriteGrant: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let firstProvider = FactContextProvider()
        let firstResult = try await result(f, provider: firstProvider)
        let original = try #require(f.sessions.loadSession(id: f.id.uuidString))
        let first = try #require(try ChatSessionBridge.saveCanonicalCompactionCheckpoint(
            sessionStore: f.sessions, sessionID: original.id, sourceMessages: original.messages,
            result: firstResult, taskStore: f.tasks, effectLedger: f.ledger))
        _ = try f.tasks.startRun(taskID: "compare-open", parentID: "parent", runID: "second-auto-run")
        let attempt = try #require(f.tasks.canonicalAttemptID(runID: "second-auto-run"))
        _ = try f.tasks.bindChildTranscript(.init(childSessionID: "second-auto-child",
            parentSessionID: original.id, taskID: "compare-open", parentID: "parent",
            runID: "second-auto-run", attemptID: attempt, childExecutionID: "second-auto-execution",
            parentContextSnapshotID: nil))
        _ = try f.tasks.finish(runID: "second-auto-run", outcome: .succeeded)
        for option in 20..<32 {
            try f.sessions.saveMessage(.init(role: .assistant, content: (0..<40).map {
                "New alternative \(option), coefficient \($0 * option), dependency \(option - $0), estimate \(option + $0)."
            }.joined(separator: " ")), sessionID: original.id)
        }
        try f.sessions.saveMessage(.init(role: .user, content: "Continue with these new alternatives."), sessionID: original.id)
        let source = try #require(f.sessions.loadSession(id: original.id))
        let previousModel = try ChatSessionBridge.resumeCanonicalMessages(sessionStore: f.sessions,
            sessionID: source.id, taskStore: f.tasks, effectLedger: f.ledger)
        let oldFacts = f.ledger.facts
        let provider = FactContextProvider()
        provider.proposeWritePath = f.root.appendingPathComponent("second-must-not-exist.txt").path
        let (engine, _) = automaticEngine(f)
        try await runAutomatic(f, engine: engine, provider: provider, turnID: 71)
        let second = try #require(try f.sessions.loadLatestCompactionCheckpoint(sessionID: source.id))
        #expect(second.checkpointID != first.checkpointID)
        #expect(second.sourceTranscriptRevision == source.transcriptRevision)
        #expect(provider.dialogueRequests.first == previousModel)
        #expect(provider.summaryRequests.count == 1)
        // 长02：第二次摘要基于上一份摘要，已覆盖的原始消息不再重复送入，新增内容照常送入。
        #expect(provider.summaryRequests.flatMap { $0 }.contains { $0.content.contains("【此前摘要") })
        #expect(provider.summaryRequests.flatMap { $0 }.contains { $0.content.contains("New alternative 20") })
        #expect(!provider.summaryRequests.flatMap { $0 }.contains { $0.content.contains("<context-summary>") })
        // 任务已成功结束、回执也都成功：第二次压缩不再带任何事实，背景消息随之消失。
        #expect(second.retentionFacts == [])
        #expect(!second.replacementHistory.contains { $0.content.contains("<retained-store-facts>") })
        let lastDialogue = try #require(provider.dialogueRequests.last)
        #expect(!lastDialogue.contains { $0.content.contains("status=queued") })
        #expect(Compactor.hasMaterialRequestReduction(from: previousModel, to: second.replacementHistory))
        #expect(f.sessions.loadSession(id: source.id)?.messages == source.messages)
        #expect(f.executor.count == 0)
        #expect(f.ledger.facts == oldFacts)
        #expect(try SessionStore(directory: f.root.appendingPathComponent("sessions"))
            .resumeMessages(sessionID: source.id) == second.replacementHistory)
    }

    @Test func secondBudgetAutoWithoutNewMaterialRefusesInsteadOfRecompactingOldProjection() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let result = try await result(f, provider: FactContextProvider())
        let original = try #require(f.sessions.loadSession(id: f.id.uuidString))
        let first = try #require(try ChatSessionBridge.saveCanonicalCompactionCheckpoint(
            sessionStore: f.sessions, sessionID: original.id, sourceMessages: original.messages,
            result: result, taskStore: f.tasks, effectLedger: f.ledger))
        let source = try #require(f.sessions.loadSession(id: original.id))
        let oldFacts = f.ledger.facts
        let provider = FactContextProvider()
        let (engine, _) = automaticEngine(f)
        // The budget trips on the final reply; a run that ends there no longer
        // spends a summary request, so nothing is recompacted or rewritten.
        try await runAutomatic(f, engine: engine, provider: provider, turnID: 72)
        #expect(provider.summaryRequests.isEmpty)
        #expect(try f.sessions.loadLatestCompactionCheckpoint(sessionID: source.id) == first)
        #expect(f.sessions.loadSession(id: source.id) == source)
        #expect(provider.dialogueRequests.count == 1)
        #expect(f.executor.count == 0)
        #expect(f.ledger.facts == oldFacts)
    }

    @Test func durableAutoCommitThenUIRejectionStopsLoopAndIsolatesStalePersistence() async throws {
        let f = try fixture(currentWriteGrant: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let chat = ChatStore()
        #expect(chat.attachPersistence(f.sessions))
        let bubble = ChatMessageUI(role: .assistant, content: "live partial", isStreaming: true)
        #expect(chat.setMessages(f.history + [bubble], forSession: f.id))
        let source = try #require(f.sessions.loadSession(id: f.id.uuidString))
        let uiRevision = try #require(chat.transcriptRevision(forSession: f.id))
        let oldFacts = f.ledger.facts
        var isolated = false
        let (base, _) = automaticEngine(f)
        let engine = base.withAutomaticCompactionBoundary(capture: { _ in
            .init(session: source, closedPrefixCount: source.messages.count - 1, uiRevision: uiRevision)
        }, adopt: { captured, checkpoint in
            // An actual current-UI generation mismatch rejects adoption, not
            // a mocked checkpoint acknowledgement. Keep the stale UI unwritten.
            let wrong = AgentLoopChatEngine.AutomaticCompactionSource(session: captured.session,
                closedPrefixCount: captured.closedPrefixCount, uiRevision: uiRevision + 1)
            return await chat.adoptAutomaticProjection(wrong, checkpoint: checkpoint, assistantMessageID: bubble.id)
        }, isolate: { _ in
            isolated = true
            chat.isolateAutomaticProjectionWriteback(sessionID: f.id)
        })
        let provider = FactContextProvider()
        provider.proposeWritePath = f.root.appendingPathComponent("rejected-must-not-exist.txt").path
        do {
            try await runAutomatic(f, engine: engine, provider: provider, turnID: 73)
            Issue.record("UI rejection after commit must terminate before a tool or next Provider")
        } catch {}
        let checkpoint = try #require(try f.sessions.loadLatestCompactionCheckpoint(sessionID: source.id))
        let committed = try #require(f.sessions.loadSession(id: source.id))
        #expect(isolated)
        #expect(committed.messages == source.messages)
        #expect(committed.transcriptRevision == checkpoint.resultTranscriptRevision)
        #expect(provider.dialogueRequests.count == 1)
        let firstDialogue = try #require(provider.dialogueRequests.first)
        #expect(!firstDialogue.contains { $0.content == bubble.content })
        #expect(f.executor.count == 0)
        #expect(f.ledger.facts == oldFacts)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("rejected-must-not-exist.txt").path))
        #expect(chat.setMessages(f.history, forSession: f.id))
        #expect(f.sessions.loadSession(id: source.id) == committed)
        #expect(try f.sessions.loadLatestCompactionCheckpoint(sessionID: source.id) == checkpoint)
        let restarted = SessionStore(directory: f.root.appendingPathComponent("sessions"))
        let resumed = try ChatSessionBridge.resumeCanonicalMessages(sessionStore: restarted,
            sessionID: source.id, taskStore: f.tasks, effectLedger: f.ledger)
        #expect(resumed == checkpoint.replacementHistory + [bubble.asLLMMessage()])
        #expect(resumed.filter { $0.content == bubble.content }.count == 1)
        // Re-entry uses the committed projection and the original .pause
        // budget, without trying to replay the blocked write.
        let restoredTasks = try AgentTaskStore(persistenceURL: f.root.appendingPathComponent("tasks.json"))
        let restoredLedger = try ToolExecutionFactLedger(persistenceURL: f.root.appendingPathComponent("effects.json"))
        let reopened = try await configuredAutomaticChat(f, policy: .pause, maxRequests: nil,
            sessionStore: restarted, taskStore: restoredTasks, effectLedger: restoredLedger)
        let retryProvider = FactContextProvider()
        reopened.streamingProviderOverride = retryProvider
        reopened.draftText = "A new permitted conversation request after reopening."
        reopened.sendDraft()
        for _ in 0..<300 {
            if !reopened.isStreaming && !retryProvider.dialogueRequests.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!reopened.isStreaming)
        #expect(retryProvider.dialogueRequests.count == 1)
        let retryDialogue = try #require(retryProvider.dialogueRequests.first)
        #expect(retryDialogue.starts(with: resumed))
        #expect(retryProvider.summaryRequests.isEmpty)
        let reopenedCanonical = try #require(restarted.loadSession(id: source.id))
        #expect(reopenedCanonical.messages.count == committed.messages.count + 2)
        #expect(reopenedCanonical.messages.last?.content.contains("distinct options") == true)
        #expect(try restarted.loadLatestCompactionCheckpoint(sessionID: source.id) == checkpoint)
        #expect(restoredLedger.facts == oldFacts)
        #expect(f.executor.count == 0)
    }

    @Test func automaticClosedPrefixAdoptionPreservesLiveUIAndFinalAnswerExactlyOnce() async throws {
        let f = try fixture(withFacts: false, currentWriteGrant: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let chat = ChatStore()
        #expect(chat.attachPersistence(f.sessions))
        let bubble = ChatMessageUI(role: .assistant, content: "mutable placeholder", isStreaming: true)
        #expect(chat.setMessages(f.history + [bubble], forSession: f.id))
        let source = try #require(f.sessions.loadSession(id: f.id.uuidString))
        let uiRevision = try #require(chat.transcriptRevision(forSession: f.id))
        let (base, _) = automaticEngine(f)
        var adopted = false
        let engine = base.withAutomaticCompactionBoundary(capture: { _ in
            .init(session: source, closedPrefixCount: source.messages.count - 1, uiRevision: uiRevision)
        }, adopt: { captured, checkpoint in
            adopted = await chat.adoptAutomaticProjection(captured, checkpoint: checkpoint, assistantMessageID: bubble.id)
            return adopted
        }, isolate: { _ in
            Issue.record("A matching live UI should adopt its independently verified checkpoint")
        })
        let provider = FactContextProvider()
        provider.proposeWritePath = f.root.appendingPathComponent("live-plan-must-not-exist.txt").path
        try await runAutomatic(f, engine: engine, provider: provider, turnID: 76)
        let checkpoint = try #require(try f.sessions.loadLatestCompactionCheckpoint(sessionID: source.id))
        #expect(adopted)
        #expect(checkpoint.retentionFacts == [])
        #expect(checkpoint.compactedMessageRange.upperBound + (checkpoint.projectionRecentCount ?? -1)
            == source.messages.count - 1)
        #expect(chat.messages(forSession: f.id) == f.history + [bubble])
        #expect(chat.transcriptRevision(forSession: f.id) == checkpoint.resultTranscriptRevision)
        #expect(provider.dialogueRequests.allSatisfy { !$0.contains { $0.content == bubble.content } })
        let continued = try #require(provider.dialogueRequests.last)
        #expect(continued.filter { $0.toolCalls.contains { $0.id == "new-write" } }.count == 1)
        #expect(continued.filter { $0.toolCallID == "new-write" }.count == 1)
        var final = bubble
        final.content = "final answer after live compaction"
        final.isStreaming = false
        #expect(chat.setMessages(f.history + [final], forSession: f.id))
        let restarted = SessionStore(directory: f.root.appendingPathComponent("sessions"))
        #expect(try ChatSessionBridge.resumeCanonicalMessages(sessionStore: restarted, sessionID: source.id)
            == checkpoint.replacementHistory + [final.asLLMMessage()])
        #expect(f.executor.count == 0)
        #expect(f.ledger.facts.isEmpty)
    }

    @Test func wrongCaptureSessionOrRevisionRefusesBeforeProviderOrEffects() async throws {
        for wrongSession in [true, false] {
            let f = try fixture()
            defer { try? FileManager.default.removeItem(at: f.root) }
            let source = try #require(f.sessions.loadSession(id: f.id.uuidString))
            let (base, _) = automaticEngine(f)
            var forged = source
            if wrongSession {
                forged = try f.sessions.createSession(id: UUID().uuidString)
            } else {
                forged.transcriptRevision += 1
            }
            let wrong = forged
            let engine = base.withAutomaticCompactionBoundary(capture: { _ in
                .init(session: wrong, closedPrefixCount: wrong.messages.count, uiRevision: nil)
            }, adopt: { _, _ in
                Issue.record("A foreign source cannot reach UI adoption")
                return true
            }, isolate: { _ in })
            let provider = FactContextProvider()
            do {
                try await runAutomatic(f, engine: engine, provider: provider, turnID: 77)
                Issue.record("A capture envelope cannot override actual canonical session/revision")
            } catch {}
            #expect(provider.requests.isEmpty)
            #expect(try f.sessions.loadLatestCompactionCheckpoint(sessionID: source.id) == nil)
            #expect(f.sessions.loadSession(id: source.id) == source)
            #expect(f.executor.count == 0)
        }
    }

    private func configuredAutomaticChat(_ f: Fixture, policy: RequestBudget.Policy = .autoCompact,
                                         maxRequests: Int? = 1, sessionStore: SessionStore? = nil,
                                         taskStore: AgentTaskStore? = nil,
                                         effectLedger: ToolExecutionFactLedger? = nil) async throws -> ChatStore {
        let chat = ChatStore()
        #expect(chat.attachPersistence(sessionStore ?? f.sessions))
        #expect(chat.applySwitchSession(id: f.id))
        let facts = ComposerPolicyFactSource(knownCapabilities: ["file_write"],
            grantedCapabilities: ["file_write"], allowedWriteRoots: [f.root.path],
            workspaceID: chat.composerWorkspaceID, revision: "current-policy", grantEpoch: "current-epoch",
            leaseID: "current-lease", expiresAt: .distantFuture, autonomyCeiling: .l3)
        chat.configureComposerPolicy(facts)
        chat.composerPolicySelection = .init(mode: .plan, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: false)
        let budget = RequestBudget(maxRequestsPerSession: maxRequests, overBudgetPolicy: policy)
        chat.requestBudget = budget
        await chat.budgetTracker.replace(with: budget)
        var engine = AgentLoopChatEngine(toolExecutor: f.executor, requestBudget: chat.budgetTracker,
            taskStore: taskStore ?? f.tasks, chatRuntimeDependencies: .init(sessionStore: sessionStore ?? f.sessions,
                memoryStore: MemoryStore(directory: f.root.appendingPathComponent("memory")),
                skillStore: f.skills, soulStore: SoulStore(directory: f.root.appendingPathComponent("soul"))),
            contextWritebackStorePersistenceURL: f.root.appendingPathComponent("context.json"),
            toolExecutionFactLedger: effectLedger ?? f.ledger, composerPolicyFacts: facts)
        engine.loop.compactor = Compactor(keepRecentMessages: 1)
        chat.agentEngine = engine
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            .init(turn: turn, skillInjector: SkillInjector(store: f.skills).snapshotForTurn(), mcpBridge: nil)
        }
        return chat
    }

    private func settingsCenter442(_ f: Fixture, defaults: UserDefaults) -> SettingsCenter {
        settingsCenter442(root: f.root, sessions: f.sessions, skills: f.skills,
            defaults: defaults, usageID: f.id)
    }

    private func settingsCenter442(root: URL, sessions: SessionStore,
                                   skills: SkillStore, defaults: UserDefaults,
                                   usageID: UUID) -> SettingsCenter {
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        return SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings442")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env442"),
                keychain: keychain, privacyStore: EnvVarPrivacyStore(defaults: defaults)),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            memoryFileStore: MemoryFileStore(directory: root.appendingPathComponent("memory")),
            sessionStore: sessions,
            logManager: LogManager(directory: root.appendingPathComponent("logs442")),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcp442.json"),
                keychain: keychain),
            skillStore: skills, usageStore: UsageStore(domain: .suite("memory442-" + usageID.uuidString)),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock,
            providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("readiness442"))
        )
    }

    private func waitForReply442(_ chat: ChatStore, provider: FactContextProvider, count: Int) async throws {
        for _ in 0..<300 {
            if !chat.isStreaming && provider.dialogueRequests.count == count { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "Memory442.realTurn", code: count,
            userInfo: [NSLocalizedDescriptionKey: "实际回合未完成；dialogue=\(provider.dialogueRequests.count), summary=\(provider.summaryRequests.count), streaming=\(chat.isStreaming)"])
    }

    @Test(arguments: [0.6, 0.61])
    func persistedThresholdAfterSettingsReopenControlsSameNextTurnBudget442(threshold: Double) async throws {
        let f = try fixture(currentWriteGrant: true)
        let suite = "memory442-" + f.id.uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: f.root)
        }
        let center = settingsCenter442(f, defaults: defaults)
        center.autoCompactThreshold = 0.9
        // 本用例断言 60_000/100_000 占比与阈值，不是默认值：显式钉 10 万（默认值已改为 100 万）。
        center.maxTokensPerSession = 100_000
        let chat = ChatStore(
            providerReadinessStore: center.providerReadinessStore,
            preferencesDefaults: defaults,
            logManager: center.logManager
        )
        defer { chat.stopAllStreamingForSafety() }
        let badgeStore = SessionBadgeStore(directory: f.root.appendingPathComponent("badges442"))
        #expect(chat.attachPersistence(f.sessions, badgeStore: badgeStore))
        let sessionManager = try #require(chat.sessionManager)
        #expect(sessionManager.badgeStore === badgeStore)
        #expect(sessionManager.store === f.sessions)
        #expect(sessionManager.store.directory.isFileURL)
        #expect(sessionManager.store.directory.pathComponents == f.root.appendingPathComponent("sessions").pathComponents)
        #expect(chat.applySwitchSession(id: f.id))
        let facts = ComposerPolicyFactSource(knownCapabilities: ["file_write"],
            grantedCapabilities: ["file_write"], allowedWriteRoots: [f.root.path],
            workspaceID: chat.composerWorkspaceID, revision: "memory442-policy",
            grantEpoch: "memory442-epoch", leaseID: "memory442-lease",
            expiresAt: .distantFuture, autonomyCeiling: .l3)
        chat.configureComposerPolicy(facts)
        chat.composerPolicySelection = .init(mode: .plan, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: false)
        chat.configureBudget(from: center.settingsStore.settings.agent)
        var engine = f.engine.withRequestBudget(chat.budgetTracker)
        engine.updateComposerPolicy(facts)
        chat.agentEngine = engine
        chat.turnRuntimeSnapshotFactory = { turn, _ in
            .init(turn: turn, skillInjector: SkillInjector(store: f.skills).snapshotForTurn(), mcpBridge: nil)
        }
        // Same canonical SettingsCenter owner used by the production app.
        chat.effectiveSettingsSnapshotSource = { center.bl6EffectiveSettingsSnapshot }
        let dialogue = FactContextProvider()
        // C1: the trigger is the window occupancy the previous request reported
        // (60_000 total input of a 100_000 window = 0.6), no longer the usage budget.
        dialogue.model = LLMModel(id: "fact-context", displayName: "Fact context",
            provider: "test", contextWindow: 100_000)
        #expect(dialogue.model.contextWindowTokens >= 60_000)
        dialogue.dialogueUsage = LLMUsage(inputTokens: 60_000, outputTokens: 0, cacheHitInputTokens: 60_000)
        let summary = FactContextProvider()
        chat.streamingProviderOverride = dialogue
        chat.compactionProviderOverride = summary
        chat.draftText = "Establish the real previous turn's fixed accounting usage."
        chat.sendDraft()
        try await waitForReply442(chat, provider: dialogue, count: 1)
        let budget = await chat.budgetTracker.budget
        #expect(budget.usedTokens == 60_000)
        #expect(budget.maxTokensPerSession == 100_000)
        #expect(budget.usageFraction == 0.6)
        #expect(chat.requestBudget.usedTokens == budget.usedTokens)
        #expect(summary.requests.isEmpty)
        #expect(try f.sessions.loadLatestCompactionCheckpoint(sessionID: f.id.uuidString) == nil)
        let before = try #require(f.sessions.loadSession(id: f.id.uuidString))
        let originalFacts = f.ledger.facts

        center.autoCompactThreshold = threshold
        let reopened = settingsCenter442(f, defaults: defaults)
        #expect(reopened.settingsStore !== center.settingsStore)
        #expect(reopened.autoCompactThreshold == threshold)
        let snapshot = try #require(reopened.bl6EffectiveSettingsSnapshot)
        #expect(snapshot.value(for: "agent.auto-compact-threshold") == .decimal(threshold))
        // Do not reset/configure the existing budget or fabricate a projection.
        // The stale assembly copy remains 0.9; the actual fresh owner supplies
        // the submission-frozen threshold for the same 60k next-turn boundary.
        #expect(chat.configuredAutoCompactThreshold == 0.9)
        chat.effectiveSettingsSnapshotSource = { reopened.bl6EffectiveSettingsSnapshot }
        dialogue.dialogueUsage = nil
        let nextText = "Continue the comparison with every constraint after reopening settings."
        chat.draftText = nextText
        chat.sendDraft()
        try await waitForReply442(chat, provider: dialogue, count: 2)
        let sent = try #require(dialogue.dialogueRequests.last)
        let canonical = try #require(f.sessions.loadSession(id: f.id.uuidString))
        #expect(Array(canonical.messages.prefix(before.messages.count)) == before.messages)
        #expect(canonical.messages.filter { $0.role == .user && $0.content == nextText }.count == 1)
        #expect(canonical.messages.count == before.messages.count + 2)
        #expect(chat.messages(forSession: f.id)?.filter { $0.role != .system }.map { $0.asLLMMessage() }
            == canonical.messages)
        #expect(f.ledger.facts == originalFacts)
        #expect(chat.composerPolicyFacts == facts)
        #expect(f.executor.count == 0)
        #expect(dialogue.streamCallCount == 0)
        if threshold == 0.6 {
            let checkpoint = try #require(try f.sessions.loadLatestCompactionCheckpoint(sessionID: f.id.uuidString))
            #expect(checkpoint.schemaVersion == CompactionCheckpoint.lossySummarySchemaVersion)
            #expect(checkpoint.sourceTranscriptRevision > before.transcriptRevision)
            #expect(checkpoint.retentionFacts?.count == 1)   // 只有未完成的任务，成功回执不带
            #expect(checkpoint.retentionFacts?.allSatisfy { $0.source?.matchesTranscript(
                Array(canonical.messages.dropLast())) == true } == true)
            #expect(summary.summaryRequests.count == 1)
            #expect(summary.dialogueRequests.isEmpty)
            #expect(Compactor.hasMaterialRequestReduction(from: Array(canonical.messages.dropLast()), to: sent))
            #expect(sent == checkpoint.replacementHistory)
            // Older user turns are summarized by the model (lossy), not kept verbatim.
            #expect(sent.contains { $0.content.contains("<context-summary>") })
        } else {
            #expect(try f.sessions.loadLatestCompactionCheckpoint(sessionID: f.id.uuidString) == nil)
            #expect(summary.requests.isEmpty)
            #expect(sent == before.messages + [LLMMessage(role: .user, content: nextText)])
        }
        // Keep all original 442 controls above, then exercise the installed
        // Bridge factory and concrete engine instead of its legacy fixture factory.
        try await installedBridgeThresholdNextTurn3208(threshold: threshold)
    }

    private func installedBridgeThresholdNextTurn3208(threshold: Double) async throws {
        let f = try fixture(currentWriteGrant: false)
        let defaults = try #require(UserDefaults(suiteName: "installed-threshold3208-" + f.id.uuidString))
        let center = settingsCenter442(f, defaults: defaults)
        center.autoCompactThreshold = 0.9
        // 本用例断言 60_000/100_000 占比与阈值，不是默认值：显式钉 10 万（默认值已改为 100 万）。
        center.maxTokensPerSession = 100_000
        #expect(center.settingsStore.settings.agent.autoCompactThreshold == 0.9)
        #expect(center.providerReadinessStore.upsert([ProviderReadinessPersistenceRecord(
            providerID: "fact-context", modelID: "fact-context", status: .passed, readinessState: .mock,
            checkedAt: Date(timeIntervalSince1970: 1_000), evidenceID: "owned-threshold3208",
            isApplied: true, discoveryReceiptID: "discovery3208", discoveredAt: Date(timeIntervalSince1970: 1_000),
            applyReceiptID: "provider-readiness-apply:3208", appliedAt: Date(timeIntervalSince1970: 1_001))]))
        let shortcuts = ShortcutStore(defaults: defaults)
        let badges = SessionBadgeStore(directory: f.root.appendingPathComponent("badges3208"))
        let bridge = BridgeStore(shortcutStore: shortcuts, preferencesDefaults: defaults,
            logManager: center.logManager,
            workflowStore: WorkflowStore(storeDirectory: f.root.appendingPathComponent("workflows3208")),
            sessionBadgeStore: badges, sessionDocumentStore: SessionDocumentStore(directory: f.sessions.directory),
            canvasRuntimeState: .disabled, agentTaskStore: f.tasks,
            contextManifestStore: try ContextManifestStore(persistenceURL: f.root.appendingPathComponent("manifest3208.json")),
            memoryStore: center.memoryStore, memoryProposalConsumer: center.memoryProposalConsumer,
            providerReadinessStore: center.providerReadinessStore,
            taskCenterBindingPersistenceURL: f.root.appendingPathComponent("task-center3208.json"),
            canvasFeatureLane: .phase3NonCanvas,
            speechToolDirectObservationProvider: { _ in SpeechToolDirectObservations() })
        let chat = bridge.chat
        defer { chat.stopAllStreamingForSafety(); withExtendedLifetime((bridge, center)) {} }
        #expect(chat.attachPersistence(f.sessions, badgeStore: badges))
        bridge.bindProductionEffectiveSettingsSource { center.bl6EffectiveSettingsSnapshot }
        await bridge.attachProductionServices(agentSettings: center.settings.agent,
            fileAccessAllowedRoot: f.root, fileAccessDeniedRoots: [], sessionDirectory: f.sessions.directory,
            mcpManager: center.mcpManager, skillStore: center.skillStore, canvasRuntimeState: .disabled,
            externalRunners: [:], externalNetworkAllowed: true, sessionReadSecretStore: center.envStore).value
        #expect(chat.turnRuntimeSnapshotFactory != nil)
        #expect(chat.prepareTopLevelTaskPolicy != nil)
        #expect(chat.agentEngine is AgentLoopChatEngine)
        #expect(chat.applySwitchSession(id: f.id))
        chat.composerPolicySelection = .init(mode: .plan, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: false)
        let dialogue = FactContextProvider()
        let summary = FactContextProvider()
        // Production route admission binds model ownership to Provider.name.
        // The legacy direct-engine fixture's provider ID "test" is not that identity.
        dialogue.model = LLMModel(id: "fact-context", displayName: "Fact context", provider: dialogue.name,
            contextWindow: 100_000)
        summary.model = LLMModel(id: "fact-context", displayName: "Fact context", provider: summary.name)
        #expect(dialogue.model.provider == dialogue.name)
        #expect(summary.model.provider == summary.name)
        // C1: 60_000 total input of the 100_000 window is the 0.6 occupancy the threshold sees.
        dialogue.dialogueUsage = LLMUsage(inputTokens: 60_000, outputTokens: 0, cacheHitInputTokens: 60_000)
        chat.streamingProviderOverride = dialogue
        chat.compactionProviderOverride = summary
        chat.draftText = "OWNED3208_PREVIOUS_USAGE"
        chat.submitComposer()
        let firstSubmission = try #require(chat.lastComposerSubmissionSnapshot)
        let firstTask = try #require(chat.turnTaskForTests(sessionID: f.id))
        await firstTask.value
        #expect(!chat.hasStreamingTasksForSafety)
        #expect(dialogue.dialogueRequests.count == 1)
        #expect(summary.requests.isEmpty)
        let budget = await chat.budgetTracker.budget
        #expect(budget.usedTokens == 60_000 && budget.maxTokensPerSession == 100_000)
        #expect(budget.usageFraction == 0.6)
        #expect(try f.sessions.loadLatestCompactionCheckpoint(sessionID: f.id.uuidString) == nil)
        let before = try #require(f.sessions.loadSession(id: f.id.uuidString))
        let firstEngine = try #require(chat.agentEngine as? AgentLoopChatEngine)
        let factsBefore = firstEngine.toolExecutionFactLedger.facts
        center.autoCompactThreshold = threshold
        let reopened = settingsCenter442(f, defaults: defaults)
        defer { withExtendedLifetime(reopened) {} }
        #expect(reopened.settingsStore !== center.settingsStore)
        #expect(reopened.settingsStore.settings.agent.autoCompactThreshold == threshold)
        #expect(reopened.bl6EffectiveSettingsSnapshot?.value(for: "agent.auto-compact-threshold") == .decimal(threshold))
        #expect(chat.configuredAutoCompactThreshold == 0.9)
        // Rebind the existing production owner only; never replace the installed
        // snapshot factory, policy preparation, or concrete AgentLoop engine.
        bridge.bindProductionEffectiveSettingsSource { reopened.bl6EffectiveSettingsSnapshot }
        let work = ThresholdInstalledWork3208()
        chat.automaticCompactionHighBudgetObserverForTests = { work.record($0) }
        dialogue.dialogueUsage = nil
        let text = "OWNED3208_NEXT_BOUNDARY"
        chat.draftText = text
        chat.submitComposer()
        let nextSubmission = try #require(chat.lastComposerSubmissionSnapshot)
        #expect(nextSubmission.taskID != firstSubmission.taskID)
        #expect(nextSubmission.messageID != firstSubmission.messageID)
        let nextTask = try #require(chat.turnTaskForTests(sessionID: f.id))
        await nextTask.value
        #expect(!chat.hasStreamingTasksForSafety)
        #expect(chat.agentEngine is AgentLoopChatEngine)
        #expect(dialogue.dialogueRequests.count == 2)
        let sent = try #require(dialogue.dialogueRequests.last)
        let canonical = try #require(f.sessions.loadSession(id: f.id.uuidString))
        #expect(canonical.messages.filter { $0.content == text }.count == 1)
        #expect(canonical.messages.count == before.messages.count + 2)
        #expect(chat.messages(forSession: f.id)?.filter { $0.role != .system }.map { $0.asLLMMessage() } == canonical.messages)
        #expect((chat.agentEngine as? AgentLoopChatEngine)?.toolExecutionFactLedger.facts == factsBefore)
        #expect(dialogue.streamCallCount == 0)
        #expect(work.mainThreadWork == 0)
        let checkpoint = try f.sessions.loadLatestCompactionCheckpoint(sessionID: f.id.uuidString)
        if threshold == 0.6 {
            let saved = try #require(checkpoint)
            #expect(work.reads > 0 && work.projections > 0)
            #expect(summary.summaryRequests.count == 1 && summary.dialogueRequests.isEmpty)
            #expect(saved.schemaVersion == CompactionCheckpoint.lossySummarySchemaVersion)
            #expect(Compactor.hasMaterialRequestReduction(from: before.messages + [LLMMessage(role: .user, content: text)], to: sent))
            #expect(sent == saved.replacementHistory)
            // Older user turns are summarized by the model (lossy), not kept verbatim.
            #expect(sent.contains { $0.content.contains("<context-summary>") })
        } else {
            #expect(work.reads == 0 && work.projections == 0)
            #expect(checkpoint == nil && summary.requests.isEmpty)
            #expect(sent == before.messages + [LLMMessage(role: .user, content: text)])
        }
        let sessionsReopened = SessionStore(directory: f.sessions.directory)
        #expect(sessionsReopened.loadSession(id: f.id.uuidString) == canonical)
        #expect(try sessionsReopened.loadLatestCompactionCheckpoint(sessionID: f.id.uuidString) == checkpoint)
        print("TASK3208 installedBridge threshold=\(threshold) usedTokens=\(budget.usedTokens) summaryRequests=\(summary.summaryRequests.count) dialogueRequests=\(dialogue.dialogueRequests.count) workerReads=\(work.reads)")
    }

    private final class ThresholdInstalledWork3208: @unchecked Sendable {
        private let lock = NSLock()
        private var readCount = 0
        private var projectionCount = 0
        private var mainCount = 0
        var reads: Int { lock.withLock { readCount } }
        var projections: Int { lock.withLock { projectionCount } }
        var mainThreadWork: Int { lock.withLock { mainCount } }
        func record(_ stage: AutomaticCompactionSourcePreprocessor.Stage) {
            lock.withLock {
                if stage == .canonicalRead { readCount += 1 }
                if stage == .projection { projectionCount += 1 }
                if Thread.isMainThread { mainCount += 1 }
            }
        }
    }

    @Test("405 right-panel shared ChatStore entry naturally compacts and feeds the next actual request")
    func rightPanelNaturalCompactionFeedsNextProductionRequest405() async throws {
        try await manualEntryFeedsNextProductionRequest405(requiresComposerApproval: false)
    }

    // 11/16 用户决定：用户 /compact 免卡，本测试改为非用户来源（恢复/直接评估）的 compact：
    // 仍挂审批卡，批准后喂给下一次真实请求，且审批只消费一次。
    @Test("405 approved Composer compact feeds the next actual request and consumes approval once")
    func approvedComposerCompactFeedsNextProductionRequestAndConsumesApproval405() async throws {
        try await manualEntryFeedsNextProductionRequest405(requiresComposerApproval: true)
    }

    // 11/16 用户决定：用户自己键入的 /compact 直接执行、无审批卡，同样喂给下一次真实请求。
    @Test("405 user-typed Composer compact runs without approval and feeds the next actual request")
    func userTypedComposerCompactFeedsNextProductionRequestWithoutApproval405() async throws {
        try await manualEntryFeedsNextProductionRequest405(requiresComposerApproval: true, userOwnCompact: true)
    }

    private func manualEntryFeedsNextProductionRequest405(
        requiresComposerApproval: Bool, userOwnCompact: Bool = false
    ) async throws {
        let f = try fixture(currentWriteGrant: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        // Retain the real production engine/stores. An unlimited pause policy
        // keeps the next send from silently substituting automatic compaction.
        let chat = try await configuredAutomaticChat(f, policy: .pause, maxRequests: nil)
        let source = try #require(f.sessions.loadSession(id: f.id.uuidString))
        let before = try #require(chat.messages(forSession: f.id)?.filter { $0.role != .system })
        let oldFacts = f.ledger.facts
        let summaryProvider = FactContextProvider()
        chat.compactionProviderOverride = summaryProvider
        let center: ComposerCommandAdjudicationCenter? = requiresComposerApproval
            ? ComposerCommandAdjudicationCenter() : nil

        if let center {
            // Same ChatStore <-> adjudication-center wiring as the existing059
            // production fixture. Never approve by returning .execute directly.
            chat.composerPolicySelection = .init(mode: .manual, approvalScope: .request,
                effort: .standard, bypassModeConfirmed: false)
            chat.onComposerCommandPolicy = { request, snapshot in
                if userOwnCompact {
                    return center.evaluate(request: request, snapshot: snapshot, facts: chat.composerPolicyFacts)
                }
                // 清空“用户提交”标记，模拟恢复自磁盘/非用户来源的 compact。
                return ChatStore.$userComposerCommandRequestID.withValue(nil) {
                    center.evaluate(request: request, snapshot: snapshot, facts: chat.composerPolicyFacts)
                }
            }
            center.canReplayIntoComposer = {
                chat.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && chat.pendingAttachments.isEmpty
            }
            center.replaySubmittedCommand = { text in
                chat.draftText = text
                chat.submitComposer()
            }
            chat.draftText = "/compact"
            chat.submitComposer()
            if userOwnCompact {
                #expect(chat.lastComposerCommandReceipt?.disposition == .execute)
                #expect(chat.pendingComposerCommand == nil)
                #expect(center.pendingAdjudication == nil)
            } else {
                #expect(chat.lastComposerCommandReceipt?.disposition == .pending)
                #expect(chat.pendingComposerCommand?.commandID == "compact")
                #expect(center.pendingAdjudication?.commandID == "compact")
                #expect(summaryProvider.requests.isEmpty)
                #expect(chat.messages(forSession: f.id)?.filter { $0.role != .system } == before)
                #expect(center.approveCurrentAdjudication())
                #expect(center.lastResolution?.outcome == .approvedExecuted)
                #expect(chat.lastComposerCommandReceipt?.disposition == .execute)
                #expect(chat.pendingComposerCommand == nil)
                #expect(center.pendingAdjudication == nil)
            }
        } else {
            // ContextPanelView.onCompact calls this exact default-argument
            // entry. This is an App-host action test, not a native button click.
            chat.compactContext()
        }
        for _ in 0..<300 {
            if try f.sessions.loadLatestCompactionCheckpoint(sessionID: source.id) != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let checkpoint = try #require(try f.sessions.loadLatestCompactionCheckpoint(sessionID: source.id))
        #expect(checkpoint.schemaVersion == CompactionCheckpoint.lossySummarySchemaVersion)
        #expect(checkpoint.sourceTranscriptRevision == source.transcriptRevision)
        #expect(checkpoint.projectionSpans == nil)
        #expect(checkpoint.retentionFacts?.count == 1)   // 只有未完成的任务，成功回执不带
        #expect(checkpoint.retentionFacts?.allSatisfy { $0.source?.matchesTranscript(source.messages) == true } == true)
        #expect(summaryProvider.summaryRequests.count == 1)
        #expect(summaryProvider.dialogueRequests.isEmpty)
        if let center {
            // M13: once the approved /compact has an outcome, the bottom-right
            // projection must no longer claim the command is still executing.
            var projected = center.projection?.text
            for _ in 0..<100 where projected?.contains("正通过规范路径执行") == true {
                try await Task.sleep(for: .milliseconds(20)); projected = center.projection?.text
            }
            #expect(projected?.contains("正通过规范路径执行") != true)
        }
        #expect(summaryProvider.streamCallCount == 0)
        #expect(!summaryProvider.requests.flatMap { $0 }.contains { $0.content == "/compact" })
        #expect(chat.messages(forSession: f.id)?.filter { $0.role != .system } == before)
        #expect(f.sessions.loadSession(id: source.id)?.messages == source.messages)
        #expect(f.ledger.facts == oldFacts)
        #expect(f.executor.count == 0)
        let modelView = try ChatSessionBridge.resumeCanonicalMessages(sessionStore: f.sessions,
            sessionID: source.id, taskStore: f.tasks, effectLedger: f.ledger)
        #expect(modelView == checkpoint.replacementHistory)
        #expect(Compactor.hasMaterialRequestReduction(from: source.messages, to: modelView))

        // The historical compact approval never authorizes this fresh tool
        // call. The current Plan selection must emit dry-run feedback only.
        chat.composerPolicySelection = .init(mode: .plan, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: false)
        let dialogueProvider = FactContextProvider()
        let writePath = f.root.appendingPathComponent("manual-entry-next-must-not-exist.txt")
        dialogueProvider.proposeWritePath = writePath.path
        chat.streamingProviderOverride = dialogueProvider
        let nextText = "Continue the same comparison after manual compaction; retain every constraint."
        chat.draftText = nextText
        chat.sendDraft()
        for _ in 0..<300 {
            if !chat.isStreaming && dialogueProvider.dialogueRequests.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!chat.isStreaming)
        #expect(dialogueProvider.dialogueRequests.count == 2)
        #expect(dialogueProvider.summaryRequests.isEmpty)
        #expect(dialogueProvider.streamCallCount == 0)
        #expect(dialogueProvider.offeredToolNames.allSatisfy { $0.contains("file_write") })
        let first = try #require(dialogueProvider.dialogueRequests.first)
        #expect(first == modelView + [LLMMessage(role: .user, content: nextText)])
        // Older user turns are summarized by the model (lossy), no longer kept verbatim.
        #expect(first.contains { $0.content.contains("<context-summary>") })
        #expect(!first.contains { $0.content == "/compact" })
        let continued = try #require(dialogueProvider.dialogueRequests.last)
        #expect(continued.starts(with: modelView))
        #expect(continued.filter { $0.toolCalls.contains { $0.id == "new-write" } }.count == 1)
        #expect(continued.filter { $0.toolCallID == "new-write" }.count == 1)
        #expect(continued.contains { $0.toolCallID == "new-write" && $0.content.contains("dry-run") })
        #expect(!continued.contains { $0.content.contains(oldFacts[0].receiptID) })
        #expect(f.executor.count == 0)
        #expect(f.ledger.facts == oldFacts)
        #expect(!FileManager.default.fileExists(atPath: writePath.path))
        let after = try #require(chat.messages(forSession: f.id)?.filter { $0.role != .system })
        #expect(Array(after.prefix(before.count)) == before)
        #expect(after.count == before.count + 2)
        #expect(after.last?.isStreaming == false)
        let canonical = try #require(f.sessions.loadSession(id: source.id))
        #expect(canonical.messages == after.map { $0.asLLMMessage() })
        #expect(Array(canonical.messages.prefix(source.messages.count)) == source.messages)
        #expect(canonical.messages.filter { $0.role == .user && $0.content == nextText }.count == 1)
        #expect(try f.sessions.loadLatestCompactionCheckpoint(sessionID: source.id) == checkpoint)
        let restarted = SessionStore(directory: f.root.appendingPathComponent("sessions"))
        let reopenedView = try ChatSessionBridge.resumeCanonicalMessages(sessionStore: restarted,
            sessionID: source.id, taskStore: f.tasks, effectLedger: f.ledger)
        #expect(reopenedView.starts(with: modelView))
        #expect(Array(reopenedView.suffix(2)) == Array(canonical.messages.suffix(2)))
        #expect(reopenedView.count == modelView.count + 2)

        // 第二次提交用来验证"批准只消费一次、再提交要重新审批"，只适用于非用户来源的 compact；
        // 11/16 起用户自己提交的 /compact 免卡，那条路径由默认参数的用例覆盖这段断言。
        if let center, !userOwnCompact {
            chat.draftText = "/compact"
            chat.submitComposer()
            #expect(chat.lastComposerCommandReceipt?.disposition == .pending)
            #expect(chat.pendingComposerCommand?.commandID == "compact")
            #expect(center.pendingAdjudication?.commandID == "compact")
            #expect(summaryProvider.summaryRequests.count == 1)
            #expect(dialogueProvider.dialogueRequests.count == 2)
            #expect(try f.sessions.loadLatestCompactionCheckpoint(sessionID: source.id) == checkpoint)
            center.denyCurrentAdjudication()
        }
    }

    @Test func ordinaryChatStoreSendProducesCanonicalAutoBoundaryAndFinishesWithoutPlaceholderDuplication() async throws {
        let f = try fixture(currentWriteGrant: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let chat = try await configuredAutomaticChat(f)
        let originalUI = try #require(chat.messages(forSession: f.id)?.filter { $0.role != .system })
        let provider = FactContextProvider()
        provider.proposeWritePath = f.root.appendingPathComponent("chat-auto-must-not-exist.txt").path
        chat.streamingProviderOverride = provider
        let oldFacts = f.ledger.facts
        chat.draftText = "Continue naturally under the current Plan policy."
        chat.sendDraft()
        for _ in 0..<300 {
            if !chat.isStreaming && !provider.dialogueRequests.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!chat.isStreaming)
        let checkpoint = try #require(try f.sessions.loadLatestCompactionCheckpoint(sessionID: f.id.uuidString))
        #expect(checkpoint.schemaVersion == CompactionCheckpoint.lossySummarySchemaVersion)
        #expect(provider.dialogueRequests.count == 2)
        #expect(provider.summaryRequests.count == 1)
        let continued = try #require(provider.dialogueRequests.last)
        #expect(continued.filter { $0.toolCallID == "new-write" }.count == 1)
        #expect(continued.contains { $0.toolCallID == "new-write" && $0.content.contains("dry-run") })
        let currentUI = try #require(chat.messages(forSession: f.id)?.filter { $0.role != .system })
        #expect(currentUI.count == f.history.count + 2)
        #expect(Array(currentUI.prefix(originalUI.count)) == originalUI)
        #expect(currentUI.last?.isStreaming == false)
        #expect(!continued.contains { $0.role == .assistant && $0.content.isEmpty })
        let canonical = try #require(f.sessions.loadSession(id: f.id.uuidString))
        #expect(canonical.messages == currentUI.map { $0.asLLMMessage() })
        let final = try #require(canonical.messages.last)
        let restarted = SessionStore(directory: f.root.appendingPathComponent("sessions"))
        let resumed = try ChatSessionBridge.resumeCanonicalMessages(sessionStore: restarted,
            sessionID: canonical.id, taskStore: f.tasks, effectLedger: f.ledger)
        #expect(resumed.last == final)
        #expect(resumed.filter { $0 == final }.count == 1)
        #expect(f.executor.count == 0)
        #expect(f.ledger.facts == oldFacts)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("chat-auto-must-not-exist.txt").path))
        #expect(await chat.budgetTracker.budget.usedRequests == provider.requests.count)
        // A second ordinary send keeps the same accounting epoch. New long
        // natural conversation makes a second projection materially smaller.
        var extended = currentUI
        for option in 50..<62 {
            extended.append(.init(role: .assistant, content: (0..<40).map {
                "Second ordinary option \(option), coefficient \(option * $0), dependency \(option - $0), new estimate \(option + $0)."
            }.joined(separator: " ")))
        }
        #expect(chat.setMessages(extended, forSession: f.id))
        let secondProvider = FactContextProvider()
        secondProvider.proposeWritePath = f.root.appendingPathComponent("chat-second-auto-must-not-exist.txt").path
        chat.streamingProviderOverride = secondProvider
        chat.draftText = "Continue with the new alternatives under the same Plan policy."
        chat.sendDraft()
        for _ in 0..<300 {
            if !chat.isStreaming && !secondProvider.dialogueRequests.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!chat.isStreaming)
        let secondCheckpoint = try #require(try f.sessions.loadLatestCompactionCheckpoint(sessionID: canonical.id))
        #expect(secondCheckpoint.checkpointID != checkpoint.checkpointID)
        #expect(secondProvider.dialogueRequests.count == 2)
        #expect(secondProvider.summaryRequests.count == 1)
        let summaryInput = secondProvider.summaryRequests.flatMap { $0 }
        #expect(summaryInput.contains { $0.content.contains("【此前摘要") })
        #expect(summaryInput.contains { $0.content.contains("Second ordinary option 50") })
        #expect(!summaryInput.contains { $0.content.contains("<context-summary>") })
        let secondUI = try #require(chat.messages(forSession: f.id)?.filter { $0.role != .system })
        #expect(secondUI.count == extended.count + 2)
        #expect(Array(secondUI.prefix(extended.count)) == extended)
        #expect(secondUI.last?.isStreaming == false)
        let secondCanonical = try #require(f.sessions.loadSession(id: canonical.id))
        #expect(secondCanonical.messages == secondUI.map { $0.asLLMMessage() })
        #expect(secondCheckpoint.retentionFacts?.allSatisfy { $0.source?.matchesTranscript(
            Array(secondCanonical.messages.dropLast())) == true } == true)
        let secondFinal = try #require(secondCanonical.messages.last)
        let secondResume = try ChatSessionBridge.resumeCanonicalMessages(
            sessionStore: SessionStore(directory: f.root.appendingPathComponent("sessions")),
            sessionID: canonical.id, taskStore: f.tasks, effectLedger: f.ledger)
        #expect(secondResume.last == secondFinal)
        #expect(secondResume.filter { $0 == secondFinal }.count == 1)
        #expect(f.ledger.facts == oldFacts)
        #expect(f.executor.count == 0)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("chat-second-auto-must-not-exist.txt").path))
        #expect(await chat.budgetTracker.budget.usedRequests == provider.requests.count + secondProvider.requests.count)

    }

    @Test func autoAfterFirstToolRoundPreservesUncommittedRuntimeSuffixExactlyOnce() async throws {
        let f = try fixture(currentWriteGrant: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let source = try #require(f.sessions.loadSession(id: f.id.uuidString))
        let oldFacts = f.ledger.facts
        let tracker = BudgetTracker(RequestBudget(maxRequestsPerSession: 2, overBudgetPolicy: .autoCompact))
        var engine = f.engine.withRequestBudget(tracker)
        engine.loop.compactor = Compactor(keepRecentMessages: 1)
        let provider = FactContextProvider()
        provider.proposeWritePath = f.root.appendingPathComponent("runtime-first.txt").path
        provider.proposeAdditionalWritePath = f.root.appendingPathComponent("runtime-second.txt").path
        try await runAutomatic(f, engine: engine, provider: provider, turnID: 78)
        let checkpoint = try #require(try f.sessions.loadLatestCompactionCheckpoint(sessionID: source.id))
        #expect(provider.dialogueRequests.count == 3)
        #expect(provider.summaryRequests.count == 1)
        let next = try #require(provider.dialogueRequests.last)
        #expect(next.starts(with: checkpoint.replacementHistory))
        for callID in ["new-write", "new-write-2"] {
            #expect(next.filter { $0.toolCalls.contains { $0.id == callID } }.count == 1)
            #expect(next.filter { $0.toolCallID == callID }.count == 1)
            #expect(next.contains { $0.toolCallID == callID && $0.content.contains("dry-run") })
        }
        #expect(checkpoint.retentionFacts?.allSatisfy { $0.source?.matchesTranscript(source.messages) == true } == true)
        #expect(f.sessions.loadSession(id: source.id)?.messages == source.messages)
        #expect(f.ledger.facts == oldFacts)
        #expect(f.executor.count == 0)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("runtime-first.txt").path))
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("runtime-second.txt").path))
        #expect(await tracker.budget.usedRequests == provider.requests.count)
    }

    @Test func shortOrdinaryAutoRefusesWithoutCheckpointOrEffect() async throws {
        let f = try fixture(withFacts: false, currentWriteGrant: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        var source = try #require(f.sessions.loadSession(id: f.id.uuidString))
        source.messages = [.init(role: .user, content: "Keep title."),
            .init(role: .assistant, content: "Okay."), .init(role: .user, content: "Next.")]
        source.transcriptRevision += 1
        try f.sessions.updateSession(source)
        let unchanged = try #require(f.sessions.loadSession(id: source.id))
        let (engine, _) = automaticEngine(f)
        let provider = FactContextProvider()
        provider.proposeWritePath = f.root.appendingPathComponent("short-must-not-exist.txt").path
        do {
            try await runAutomatic(f, engine: engine, provider: provider, turnID: 79)
            Issue.record("Short source cannot produce a material, source-anchored checkpoint")
        } catch {}
        #expect(try f.sessions.loadLatestCompactionCheckpoint(sessionID: source.id) == nil)
        #expect(f.sessions.loadSession(id: source.id) == unchanged)
        #expect(provider.dialogueRequests.count == 1)
        #expect(f.executor.count == 0)
        #expect(f.ledger.facts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("short-must-not-exist.txt").path))
    }

    @Test func stoppingManualGoalTurnPausesItsExactPersistedGoal() async throws {
        let f = try fixture(currentWriteGrant: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let chat = try await configuredAutomaticChat(f, policy: .pause, maxRequests: nil)
        chat.composerPolicySelection = .init(mode: .manual, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: false)
        let goal = try chat.startConversationGoal(sessionID: f.id, objective: "Stop an owned manual turn")
        let provider = FactContextProvider()
        provider.beforeDialogueResponse = { try await Task.sleep(for: .seconds(30)) }
        chat.streamingProviderOverride = provider
        chat.draftText = "An ordinary manual goal turn."
        chat.submitInteractiveComposer()
        for _ in 0..<300 {
            if !provider.dialogueRequests.isEmpty || !chat.isStreaming { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(provider.dialogueRequests.count == 1)
        try #require(chat.isStreaming)
        chat.stopStreaming()
        let reopened = SessionStore(directory: f.root.appendingPathComponent("sessions"))
        let persisted = try #require(reopened.loadSession(id: f.id.uuidString)?.goal)
        #expect(persisted.id == goal.id)
        #expect(persisted.status == .paused)
        #expect(persisted.turnPauseReason == .cancelled)
        #expect(persisted.budget.usedTurns == 0)
        #expect(f.executor.count == 0)
    }

    @Test func manualGoalPausesDurablyBeforeProviderAtSessionTokenLimit() async throws {
        let f = try fixture(currentWriteGrant: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let chat = try await configuredAutomaticChat(f, policy: .pause, maxRequests: nil)
        chat.composerPolicySelection = .init(mode: .manual, approvalScope: .request,
            effort: .standard, bypassModeConfirmed: false)
        let goal = try chat.startConversationGoal(sessionID: f.id, objective: "Check session quota")
        // This case is about the user's own turn; an idle new goal would
        // otherwise start its first automatic continuation at once.
        _ = try chat.setConversationGoalAutoContinue(sessionID: f.id, goalID: goal.id, enabled: false)
        var exhausted = RequestBudget(maxTokensPerSession: 10)
        exhausted.record(requestTokens: 10)
        await chat.budgetTracker.replace(with: exhausted)
        let provider = FactContextProvider()
        chat.streamingProviderOverride = provider
        chat.draftText = "Check the session quota before calling the provider."
        chat.submitInteractiveComposer()
        for _ in 0..<300 {
            if !chat.isStreaming { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!chat.isStreaming)
        #expect(provider.dialogueRequests.isEmpty)
        #expect(provider.summaryRequests.isEmpty)
        #expect(f.executor.count == 0)
        let persisted = try #require(f.sessions.loadSession(id: f.id.uuidString)?.goal)
        #expect(persisted.id == goal.id)
        #expect(persisted.status == .paused)
        #expect(persisted.isPausedForSessionTokenLimit == true)
        #expect(persisted.budget.usedTurns == 0)
        let resetTarget = try #require(chat.sessionBudgetResetTarget)
        await chat.resetConfirmedSessionBudget(resetTarget, hasPendingApproval: { false })
        #expect(f.sessions.loadSession(id: f.id.uuidString)?.goal?.status == .paused)
        let resumed = try chat.controlConversationGoal(sessionID: f.id, goalID: goal.id, action: .resume)
        #expect(resumed.status == .active)
        #expect(resumed.isPausedForSessionTokenLimit == nil)
    }

    @Test func actualChatStorePauseStopsBeforeAutoSummaryAndEffects() async throws {
        let f = try fixture(currentWriteGrant: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let chat = try await configuredAutomaticChat(f, policy: .pause)
        let provider = FactContextProvider()
        provider.proposeWritePath = f.root.appendingPathComponent("pause-chat-must-not-exist.txt").path
        let oldFacts = f.ledger.facts
        chat.streamingProviderOverride = provider
        chat.draftText = "Ordinary current request under the default pause policy."
        chat.sendDraft()
        for _ in 0..<300 {
            if !chat.isStreaming && !provider.dialogueRequests.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!chat.isStreaming)
        #expect(provider.dialogueRequests.count == 1)
        #expect(provider.summaryRequests.isEmpty)
        #expect(try f.sessions.loadLatestCompactionCheckpoint(sessionID: f.id.uuidString) == nil)
        #expect(await chat.budgetTracker.budget.usedRequests == 1)
        #expect(f.executor.count == 0)
        #expect(f.ledger.facts == oldFacts)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("pause-chat-must-not-exist.txt").path))
    }

    @Test func defaultPauseDoesNotInvokeCanonicalAutoOrSummary() async throws {
        let f = try fixture(currentWriteGrant: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let source = try #require(f.sessions.loadSession(id: f.id.uuidString))
        let provider = FactContextProvider()
        let (engine, tracker) = automaticEngine(f, policy: .pause)
        do {
            try await runAutomatic(f, engine: engine, provider: provider, turnID: 75)
            Issue.record("The unchanged .pause budget must stop this turn")
        } catch {}
        #expect(provider.dialogueRequests.count == 1)
        #expect(provider.summaryRequests.isEmpty)
        #expect(await tracker.budget.usedRequests == 1)
        #expect(try f.sessions.loadLatestCompactionCheckpoint(sessionID: source.id) == nil)
        #expect(f.sessions.loadSession(id: source.id) == source)
        #expect(f.executor.count == 0)
    }

    @Test func capturesStoresAndNextEngineRequestConsumesWithoutReplayingEffects() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let provider = FactContextProvider()
        let compacted = try await result(f, provider: provider)
        #expect(compacted.refusalReason == nil)
        #expect(compacted.retentionFacts?.count == 1)   // 只有未完成的任务，成功回执不带
        let canonical = try #require(f.sessions.loadSession(id: f.id.uuidString))
        _ = try ChatSessionBridge.saveCanonicalCompactionCheckpoint(sessionStore: f.sessions,
            sessionID: f.id.uuidString, sourceMessages: canonical.messages,
            expectedTranscriptRevision: canonical.transcriptRevision, result: compacted,
            taskStore: f.tasks, effectLedger: f.ledger)
        let factsBefore = f.ledger.facts
        let providerRequestsBefore = provider.requests.count
        let turn = AgentTurnIdentity(sessionID: f.id.uuidString, turnID: 20, messageID: "continue-assistant")
        let composer = ComposerSubmissionSnapshot(mode: .auto, approvalScope: .request,
            effort: .standard, sessionID: turn.sessionID, turnID: turn.turnID,
            taskID: "continue", attemptID: "continue-attempt", messageID: turn.messageID,
            inputDigest: "continue-input", workspaceID: "workspace", createdAt: Date(),
            policyRevision: "current-policy", grantEpoch: "current-epoch", autonomyCeiling: .l3)
        let stream = try await f.engine.streamReply(provider: provider, history: f.history,
            systemPrompt: "test", maxTokens: 256, conversationID: f.id.uuidString,
            authorizedSessionReadSessionID: nil, authorizedSessionReadScope: nil, turnID: turn.turnID,
            composerSnapshot: composer,
            executionIdentity: .init(turn: turn, operationID: "continue-operation", attempt: 1),
            turnRuntimeSnapshot: .init(turn: turn,
                skillInjector: SkillInjector(store: f.skills).snapshotForTurn(), mcpBridge: nil))
        for try await _ in stream {}
        #expect(provider.requests.count > providerRequestsBefore)
        let input = try #require(provider.requests.last)
        #expect(input.contains { $0.content.contains("compare-open") })
        #expect(!input.contains { $0.content.contains(factsBefore[0].receiptID) })
        // Lossy summary: the old turn text went to the summary request, not into the next input.
        #expect(provider.summaryRequests.flatMap { $0 }.contains { $0.content.contains("Earlier authorization was read-only") })
        #expect(input.last?.content == f.history.last?.content)
        #expect(Compactor.hasMaterialRequestReduction(from: canonical.messages, to: input))
        #expect(f.executor.count == 0)
        #expect(f.ledger.facts == factsBefore)
        #expect(f.sessions.loadSession(id: f.id.uuidString)?.messages == canonical.messages)
    }

    @Test func historicalAuthorizationDoesNotAllowFreshEffectUnderCurrentPlanPolicy() async throws {
        try await assertPlanWriteBoundary(currentWriteGrant: false)
    }

    @Test func currentLegalWriteGrantStillDryRunsUnderPlanPolicy() async throws {
        try await assertPlanWriteBoundary(currentWriteGrant: true)
    }

    private func assertPlanWriteBoundary(currentWriteGrant: Bool) async throws {
        let f = try fixture(currentWriteGrant: currentWriteGrant)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let provider = FactContextProvider()
        let compacted = try await result(f, provider: provider)
        let canonical = try #require(f.sessions.loadSession(id: f.id.uuidString))
        _ = try ChatSessionBridge.saveCanonicalCompactionCheckpoint(sessionStore: f.sessions,
            sessionID: canonical.id, sourceMessages: canonical.messages, result: compacted,
            taskStore: f.tasks, effectLedger: f.ledger)
        let oldFact = try #require(f.ledger.facts.first)
        let requestCount = provider.requests.count
        provider.proposeWritePath = f.root.appendingPathComponent("must-not-exist.txt").path
        let turn = AgentTurnIdentity(sessionID: canonical.id, turnID: 21, messageID: "plan-assistant")
        let composer = ComposerSubmissionSnapshot(mode: .plan, approvalScope: .request,
            effort: .standard, sessionID: turn.sessionID, turnID: turn.turnID,
            taskID: "plan", attemptID: "plan-attempt", messageID: turn.messageID,
            inputDigest: "plan-input", workspaceID: "workspace", createdAt: Date(),
            policyRevision: "current-policy", grantEpoch: "current-epoch", autonomyCeiling: .l3)
        let stream = try await f.engine.streamReply(provider: provider, history: f.history,
            systemPrompt: "test", maxTokens: 256, conversationID: canonical.id,
            authorizedSessionReadSessionID: nil, authorizedSessionReadScope: nil, turnID: turn.turnID,
            composerSnapshot: composer,
            executionIdentity: .init(turn: turn, operationID: "plan-operation", attempt: 1),
            turnRuntimeSnapshot: .init(turn: turn,
                skillInjector: SkillInjector(store: f.skills).snapshotForTurn(), mcpBridge: nil))
        for try await _ in stream {}
        #expect(provider.requests.count > requestCount)
        #expect(f.executor.count == 0)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("must-not-exist.txt").path))
        #expect(f.ledger.facts.filter { $0.receiptID == oldFact.receiptID } == [oldFact])
        #expect(f.ledger.facts == [oldFact])
        #expect(provider.streamCallCount == 0)
        #expect(provider.offeredToolNames.last?.contains("file_write") == true)
        let feedback = try #require(provider.requests.last?.first {
            $0.role == .tool && $0.toolCallID == "new-write"
        })
        let expectedFeedback = currentWriteGrant ? "dry-run" :
            ComposerAuthorizationError.missingCapabilityGrant("file_write").localizedDescription
        #expect(feedback.content.contains(expectedFeedback))
    }

    @Test func forgedReceiptWithRecomputedDigestIsRejectedByIndependentStores() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let canonical = try #require(f.sessions.loadSession(id: f.id.uuidString))
        let original = try #require(f.ledger.facts.first)
        let forged = ToolExecutionFact(toolCallID: original.toolCallID, receiptID: "nonexistent-effect",
            toolName: original.toolName, status: original.status, attemptID: original.attemptID,
            attemptNumber: original.attemptNumber, executionIdentity: original.executionIdentity,
            compositeKey: original.compositeKey)
        let source = CompactionFactSource(sessionID: canonical.id,
            transcriptRevision: canonical.transcriptRevision,
            transcriptDigest: try #require(CompactionCheckpoint.digestOfSourcePrefix(canonical.messages)),
            effect: forged)
        let fact = CompactionRetainedFact(kind: .effectIdentity, text: source.backgroundText, source: source)
        let forgedResult = try await Compactor(keepRecentMessages: 1).compact(messages: canonical.messages,
            summarizeUsing: FactContextProvider(), retentionFacts: [fact], safetyMode: .sourceAnchoredNatural)
        let checkpoint = try CompactionCheckpoint.makeProjection(sessionID: canonical.id,
            sourceTranscriptRevision: canonical.transcriptRevision, sourceMessages: canonical.messages,
            result: forgedResult)
        #expect(checkpoint.hasValidDigest)
        #expect(checkpoint.withDigest().hasValidDigest)
        #expect(throws: SessionStoreError.invalidCompactionCheckpoint(canonical.id)) {
            try ChatSessionBridge.saveCanonicalCompactionPrefix(sessionStore: f.sessions,
                expectedSession: canonical, closedPrefixCount: canonical.messages.count,
                result: forgedResult, taskStore: f.tasks, effectLedger: f.ledger)
        }
        #expect(throws: SessionStoreError.invalidCompactionCheckpoint(canonical.id)) {
            try ChatSessionBridge.saveCanonicalCompactionCheckpoint(sessionStore: f.sessions,
                sessionID: canonical.id, sourceMessages: canonical.messages, result: forgedResult,
                taskStore: f.tasks, effectLedger: f.ledger)
        }
        // Even if a caller bypasses the App bridge and writes a structurally
        // valid sidecar, the production next-input boundary verifies receipts.
        _ = try f.sessions.saveCompactionCheckpoint(checkpoint.withDigest())
        #expect(throws: SessionStoreError.invalidCompactionCheckpoint(canonical.id)) {
            try ChatSessionBridge.resumeCanonicalMessages(sessionStore: f.sessions,
                sessionID: canonical.id, taskStore: f.tasks, effectLedger: f.ledger)
        }
        #expect(f.executor.count == 0)
    }

    @Test func sourceFactRevisionAndSessionAreCheckedBeyondSelfComputedDigest() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let canonical = try #require(f.sessions.loadSession(id: f.id.uuidString))
        let effect = try #require(f.ledger.facts.first)
        let digest = try #require(CompactionCheckpoint.digestOfSourcePrefix(canonical.messages))
        let binding = CompactionFactSource(sessionID: canonical.id,
            transcriptRevision: canonical.transcriptRevision + 1, transcriptDigest: digest, effect: effect)
        let fact = CompactionRetainedFact(kind: binding.kind, text: binding.backgroundText, source: binding)
        let candidate = try await Compactor(keepRecentMessages: 1).compact(messages: canonical.messages,
            summarizeUsing: FactContextProvider(), retentionFacts: [fact], safetyMode: .sourceAnchoredNatural)
        #expect(candidate.refusalReason == nil)
        #expect(throws: CompactionCheckpointError.invalidResult) {
            try CompactionCheckpoint.makeProjection(sessionID: canonical.id,
                sourceTranscriptRevision: canonical.transcriptRevision,
                sourceMessages: canonical.messages, result: candidate)
        }
        #expect(throws: CompactionCheckpointError.invalidResult) {
            try CompactionCheckpoint.makeProjection(sessionID: "different-session",
                sourceTranscriptRevision: binding.transcriptRevision,
                sourceMessages: canonical.messages, result: candidate)
        }
        let valid = try await result(f, provider: FactContextProvider())
        // 摘要请求进行期间任务从排队变成运行（状态变了）：事实只要求任务还在、归属没变，
        // 提交仍然有效；下一轮恢复时背景按账本重建。
        _ = try f.tasks.startRun(taskID: "compare-open", parentID: "parent", runID: "changed-run")
        #expect(f.engine.validateCompactionFacts(valid.retentionFacts ?? []))
        // 被捕获的任务在账本里找不到（不是同一个任务库）才拒绝，且什么都不写。
        #expect(throws: SessionStoreError.invalidCompactionCheckpoint(canonical.id)) {
            try ChatSessionBridge.saveCanonicalCompactionCheckpoint(sessionStore: f.sessions,
                sessionID: canonical.id, sourceMessages: canonical.messages, result: valid,
                taskStore: AgentTaskStore(), effectLedger: f.ledger)
        }
        #expect(try f.sessions.loadLatestCompactionCheckpoint(sessionID: canonical.id) == nil)
        _ = try ChatSessionBridge.saveCanonicalCompactionCheckpoint(sessionStore: f.sessions,
            sessionID: canonical.id, sourceMessages: canonical.messages, result: valid,
            taskStore: f.tasks, effectLedger: f.ledger)
        #expect(try f.sessions.loadLatestCompactionCheckpoint(sessionID: canonical.id) != nil)
    }

    @Test func resumedTaskStateIsRebuiltAfterCanonicalTerminalTransition() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let compacted = try await result(f, provider: FactContextProvider())
        let canonical = try #require(f.sessions.loadSession(id: f.id.uuidString))
        _ = try ChatSessionBridge.saveCanonicalCompactionCheckpoint(sessionStore: f.sessions,
            sessionID: canonical.id, sourceMessages: canonical.messages, result: compacted,
            taskStore: f.tasks, effectLedger: f.ledger)
        _ = try f.tasks.startRun(taskID: "compare-open", parentID: "parent", runID: "compare-run")
        let attempt = try #require(f.tasks.canonicalAttemptID(runID: "compare-run"))
        _ = try f.tasks.bindChildTranscript(.init(childSessionID: "child-session",
            parentSessionID: canonical.id, taskID: "compare-open", parentID: "parent",
            runID: "compare-run", attemptID: attempt, childExecutionID: "child-execution",
            parentContextSnapshotID: nil))
        _ = try f.tasks.finish(runID: "compare-run", outcome: .succeeded)
        let restoredSessions = SessionStore(directory: f.root.appendingPathComponent("sessions"))
        let restoredTasks = try AgentTaskStore(persistenceURL: f.root.appendingPathComponent("tasks.json"))
        let restoredLedger = try ToolExecutionFactLedger(persistenceURL: f.root.appendingPathComponent("effects.json"))
        let model = try ChatSessionBridge.resumeCanonicalMessages(sessionStore: restoredSessions,
            sessionID: canonical.id, taskStore: restoredTasks, effectLedger: restoredLedger)
        // 任务已成功结束：既不再显示成未完成，也不留"已成功"记录；成功的回执同样不在背景里。
        #expect(!model.contains { $0.content.contains("status=queued") })
        #expect(!model.contains { $0.content.contains("status=succeeded") })
        #expect(!model.contains { $0.content.contains("read-done") })
        #expect(!model.contains { $0.content.contains("<retained-store-facts>") })
        #expect(model.contains { $0.content.contains("<context-summary>") })
        #expect(restoredLedger.facts.count == 1)
        #expect(restoredSessions.loadSession(id: canonical.id)?.messages == canonical.messages)
    }

    /// 旧版本留下的检查点里有已成功的回执：恢复时仍要把旧背景逐字比对通过（格式没变），
    /// 然后按当前口径重建背景——成功的回执不再出现，未完成的任务照旧。
    @Test func oldCheckpointRetainingSucceededReceiptStillResumesAndDropsItFromRebuiltBackground() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let canonical = try #require(f.sessions.loadSession(id: f.id.uuidString))
        let effect = try #require(f.ledger.facts.first)
        #expect(effect.status == .succeeded)
        let digest = try #require(CompactionCheckpoint.digestOfSourcePrefix(canonical.messages))
        let oldSource = CompactionFactSource(sessionID: canonical.id,
            transcriptRevision: canonical.transcriptRevision, transcriptDigest: digest, effect: effect)
        var oldFacts = CompactionFactCapture.capture(sessionID: canonical.id,
            revision: canonical.transcriptRevision, messages: canonical.messages,
            taskStore: f.tasks, effectLedger: nil)
        oldFacts.append(CompactionRetainedFact(kind: oldSource.kind, text: oldSource.backgroundText, source: oldSource))
        let old = try await LossySummaryCompaction.compact(messages: canonical.messages, keepRecent: 1,
            provider: FactContextProvider(), retentionFacts: oldFacts)
        #expect(old.refusalReason == nil)
        #expect(old.messages.contains { $0.content.contains(effect.receiptID) })
        _ = try #require(try ChatSessionBridge.saveCanonicalCompactionCheckpoint(sessionStore: f.sessions,
            sessionID: canonical.id, sourceMessages: canonical.messages, result: old,
            taskStore: f.tasks, effectLedger: f.ledger))
        let resumed = try ChatSessionBridge.resumeCanonicalMessages(sessionStore: f.sessions,
            sessionID: canonical.id, taskStore: f.tasks, effectLedger: f.ledger)
        #expect(!resumed.contains { $0.content.contains(effect.receiptID) })
        #expect(resumed.contains { $0.content.contains("compare-open") })
        #expect(resumed.count == old.messages.count)
        #expect(resumed.first == old.messages.first)
        #expect(resumed.last == old.messages.last)
    }

    @Test func wrongSessionOrRevisionCannotCertifyFactsAndEmptyFactsStillCompact() async throws {
        let f = try fixture(withFacts: false)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let provider = FactContextProvider()
        let compacted = try await result(f, provider: provider)
        #expect(compacted.refusalReason == nil)
        #expect(compacted.retentionFacts == [])
        let canonical = try #require(f.sessions.loadSession(id: f.id.uuidString))
        let wrong = try await f.engine.compactContext(provider: provider, history: f.history,
            systemPrompt: "test", keepRecent: 1, sourceSessionID: canonical.id,
            sourceTranscriptRevision: canonical.transcriptRevision + 1)
        #expect(wrong.refusalReason != nil)
        // Same content is not sufficient evidence for a different session.
        let wrongSession = try await f.engine.compactContext(provider: provider, history: f.history,
            systemPrompt: "test", keepRecent: 1, sourceSessionID: "missing-session",
            sourceTranscriptRevision: canonical.transcriptRevision)
        #expect(wrongSession.refusalReason != nil)
    }

    private func retainValue2932<Value: Encodable>(
        _ value: Value, root: URL, name: String
    ) throws {
        let directory = root.appendingPathComponent("runtime-values2932", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let artifact = directory.appendingPathComponent(name)
        try encoder.encode(value).write(to: artifact, options: .atomic)
        print("TASK2932_H1C_RUNTIME root=\(root.path) artifact=\(artifact.path)")
    }

    private func retainProviderArguments2932(
        _ provider: FactContextProvider, root: URL, phase: String
    ) throws {
        try retainValue2932(provider.receivedRequestPayloads2932.count,
            root: root, name: "\(phase)-actual-request-count.json")
        for (index, payload) in provider.receivedRequestPayloads2932.enumerated() {
            let artifact = root.appendingPathComponent("runtime-values2932")
                .appendingPathComponent("\(phase)-actual-request-\(index).json")
            try payload.write(to: artifact, options: .atomic)
            print("TASK2932_H1C_PROVIDER_ARGUMENTS root=\(root.path) artifact=\(artifact.path)")
        }
    }

    private struct ObservedEffectStage2932: Encodable {
        let ownedRoot: String
        let testRunID: String?
        let sessionID: String
        let stage: String
        let effectCount: Int
        let observedDispatchReceipts: [ToolExecutionReceipt]
        let facts: [ToolExecutionFact]
        let pendingReceipts: [ToolExecutionReceipt]
        let checkpoint: CompactionCheckpoint?
    }

    private func retainEffectStage2932(
        _ f: Fixture, stage: String, sessionID: String,
        ledger: ToolExecutionFactLedger, checkpoint: CompactionCheckpoint?
    ) throws {
        try retainValue2932(ObservedEffectStage2932(ownedRoot: f.root.path,
            testRunID: ProcessInfo.processInfo.environment["MINISCANVAS_TEST_RUN_ID"],
            sessionID: sessionID, stage: stage, effectCount: f.executor.count,
            observedDispatchReceipts: f.executor.observedReceipts, facts: ledger.facts,
            pendingReceipts: ledger.pendingReceipts, checkpoint: checkpoint),
            root: f.root, name: "\(stage)-observed-effect.json")
        if let marker = f.executor.effectMarkerURL {
            // Preserve the actual effect bytes; do not recreate them from count.
            try Data(contentsOf: marker).write(to: f.root.appendingPathComponent("runtime-values2932")
                .appendingPathComponent("\(stage)-marker.raw"), options: .atomic)
        }
    }

    // TASK1985: the completed fact must be produced by actual dispatch, not
    // ledger.mint/settle in the fixture, and replay must reach the same live
    // authorization boundary rather than being intercepted by plan dry-run.
    private func effectEngine1985(_ f: Fixture, sessions: SessionStore,
                                   tasks: AgentTaskStore, ledger: ToolExecutionFactLedger,
                                   grantsWrite: Bool = true) -> AgentLoopChatEngine {
        AgentLoopChatEngine(toolExecutor: f.executor, taskStore: tasks,
            chatRuntimeDependencies: .init(sessionStore: sessions,
                memoryStore: MemoryStore(directory: f.root.appendingPathComponent("memory")),
                skillStore: f.skills, soulStore: SoulStore(directory: f.root.appendingPathComponent("soul"))),
            contextWritebackStorePersistenceURL: f.root.appendingPathComponent("context.json"),
            toolExecutionFactLedger: ledger,
            composerPolicyFacts: ComposerPolicyFactSource(knownCapabilities: ["file_write"],
                grantedCapabilities: grantsWrite ? ["file_write"] : [],
                allowedWriteRoots: [f.root.path], workspaceID: "workspace",
                revision: "current-policy", grantEpoch: "current-epoch", leaseID: "current-lease",
                expiresAt: .distantFuture, autonomyCeiling: .l3))
    }

    private func runEffect1985(_ f: Fixture, engine: AgentLoopChatEngine,
                              sessions: SessionStore, provider: FactContextProvider,
                              turnID: Int) async throws {
        defer { withExtendedLifetime(f.settingsCenter) {} }
        let canonical = try #require(sessions.loadSession(id: f.id.uuidString))
        let turn = AgentTurnIdentity(sessionID: canonical.id, turnID: turnID,
            messageID: "effect-assistant-\(turnID)")
        let composer = ComposerSubmissionSnapshot(mode: .auto, approvalScope: .request,
            effort: .standard, sessionID: turn.sessionID, turnID: turn.turnID,
            taskID: "effect", attemptID: "effect-attempt-\(turnID)", messageID: turn.messageID,
            inputDigest: "effect-input-\(turnID)", workspaceID: "workspace", createdAt: Date(),
            policyRevision: "current-policy", grantEpoch: "current-epoch", autonomyCeiling: .l3)
        let stream = try await engine.streamReply(provider: provider,
            history: canonical.messages.map { $0.asChatMessageUI() }, systemPrompt: "test", maxTokens: 256,
            conversationID: canonical.id, authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil, turnID: turn.turnID, composerSnapshot: composer,
            executionIdentity: .init(turn: turn, operationID: "effect-operation-\(turnID)", attempt: 1),
            turnRuntimeSnapshot: .init(turn: turn,
                skillInjector: SkillInjector(store: f.skills).snapshotForTurn(), mcpBridge: nil))
        for try await _ in stream {}
    }

    @Test func dispatchedEffectSurvivesCanonicalCompactionAndRestartWithoutReceiptReplay() async throws {
        let f = try fixture(currentWriteGrant: true)
        // The original contract requires these owned runtime originals after
        // test exit. Keep this method's sessions/checkpoint/effect root intact.
        print("TASK2932_H1C_BEGIN case=dispatchedEffect1985 root=\(f.root.path) session=\(f.id.uuidString)")
        let marker = f.root.appendingPathComponent("actual-effect1985.txt")
        f.executor.effectMarkerURL = marker
        f.executor.submittedLedgerURL = f.root.appendingPathComponent("effects.json")
        try f.sessions.saveMessage(.init(role: .user,
            content: "Current request: write the owned synthetic marker exactly once."), sessionID: f.id.uuidString)
        let producer = FactContextProvider()
        producer.proposeWritePath = marker.path
        try await runEffect1985(f, engine: f.engine, sessions: f.sessions, provider: producer, turnID: 1985)
        #expect(f.executor.count == 1)
        #expect(try Data(contentsOf: marker) == Data("synthetic effect 1".utf8))
        let dispatched = try #require(f.ledger.facts.first { $0.toolCallID == "new-write" })
        #expect(dispatched.status == .succeeded)
        #expect(dispatched.executionIdentity?.turn.turnID == 1985)
        #expect(f.executor.observedReceipts.map(\.receiptID) == [dispatched.receiptID])
        #expect(f.ledger.pendingReceipts.isEmpty)

        let canonical = try #require(f.sessions.loadSession(id: f.id.uuidString))
        try retainValue2932(canonical, root: f.root, name: "canonical-source-session.json")
        try retainValue2932(producer.requests, root: f.root, name: "producer-provider-inputs.json")
        try retainProviderArguments2932(producer, root: f.root, phase: "producer")
        try retainEffectStage2932(f, stage: "dispatched", sessionID: canonical.id,
            ledger: f.ledger, checkpoint: nil)
        let compactionProvider2932 = FactContextProvider()
        let compacted = try await f.engine.compactContext(provider: compactionProvider2932,
            history: canonical.messages.map { $0.asChatMessageUI() }, systemPrompt: "test", keepRecent: 1,
            sourceSessionID: canonical.id, sourceTranscriptRevision: canonical.transcriptRevision)
        #expect(compacted.refusalReason == nil)
        // 已成功的写入回执不再放进压缩背景；"不重复执行"由账本的重复派发拒绝保证（见下面的 replay 断言）。
        #expect(compacted.retentionFacts?.contains { $0.source?.effect != nil } == false)
        #expect(compacted.retentionFacts?.contains { $0.source?.task?.taskID == "compare-open" } == true)
        let checkpoint = try #require(try ChatSessionBridge.saveCanonicalCompactionCheckpoint(
            sessionStore: f.sessions, sessionID: canonical.id, sourceMessages: canonical.messages,
            expectedTranscriptRevision: canonical.transcriptRevision, result: compacted,
            taskStore: f.tasks, effectLedger: f.ledger))
        try retainValue2932(compactionProvider2932.requests, root: f.root,
            name: "compaction-provider-inputs.json")
        try retainProviderArguments2932(compactionProvider2932, root: f.root, phase: "compaction")
        try retainValue2932(checkpoint, root: f.root, name: "returned-checkpoint.json")
        // Read the stored original, including its producer-owned digest. No
        // digest is recomputed or substituted by this evidence consumer.
        try Data(contentsOf: f.sessions.compactionCheckpointsDirectory
            .appendingPathComponent("\(checkpoint.checkpointID).json"))
            .write(to: f.root.appendingPathComponent("runtime-values2932")
                .appendingPathComponent("saved-checkpoint.raw.json"), options: .atomic)
        let originalFacts = f.ledger.facts
        let restarted = SessionStore(directory: f.root.appendingPathComponent("sessions"))
        let tasks = try AgentTaskStore(persistenceURL: f.root.appendingPathComponent("tasks.json"))
        let ledger = try ToolExecutionFactLedger(persistenceURL: f.root.appendingPathComponent("effects.json"))
        let reopenedCheckpoint2932 = try #require(try restarted.loadLatestCompactionCheckpoint(sessionID: canonical.id))
        #expect(reopenedCheckpoint2932 == checkpoint)
        try retainValue2932(reopenedCheckpoint2932, root: f.root, name: "reopened-checkpoint.json")
        let resumed = try ChatSessionBridge.resumeCanonicalMessages(sessionStore: restarted,
            sessionID: canonical.id, taskStore: tasks, effectLedger: ledger)
        // Older turns are summarized by the model (lossy): their text went whole to the summary request.
        let summarized2932 = compactionProvider2932.summaryRequests.flatMap { $0 }
        #expect(summarized2932.contains { $0.content.contains("Goal: compare repair choices") })
        #expect(summarized2932.contains { $0.content.contains("Keep the original title") })
        #expect(summarized2932.contains { $0.content.contains("Earlier authorization was read-only") })
        #expect(resumed.contains { $0.content.contains("<context-summary>") })
        #expect(resumed.contains { $0.content.contains("compare-open") })
        #expect(!resumed.contains { $0.content.contains(dispatched.receiptID) })
        #expect(resumed.last == canonical.messages.last)
        #expect(Compactor.hasMaterialRequestReduction(from: canonical.messages, to: resumed))
        try retainValue2932(resumed, root: f.root, name: "resumed-model-messages.json")
        try retainEffectStage2932(f, stage: "restarted", sessionID: canonical.id,
            ledger: ledger, checkpoint: reopenedCheckpoint2932)

        // The App's durable terminal-turn gate refuses this old completed
        // identity before Provider access. Keep that production boundary intact.
        let rejected = FactContextProvider()
        rejected.proposeWritePath = marker.path
        await #expect(throws: AgentLoopChatEngine.ContextManifestConsumptionError.executionIdentityRejected) {
            do {
                try await runEffect1985(f, engine: effectEngine1985(f, sessions: restarted, tasks: tasks,
                    ledger: ledger), sessions: restarted, provider: rejected, turnID: 1985)
            } catch {
                let actual = error as NSError
                try retainValue2932(["errorType": String(reflecting: type(of: error)),
                    "errorValue": String(reflecting: error), "description": error.localizedDescription,
                    "domain": actual.domain, "code": String(actual.code)],
                    root: f.root, name: "terminal-turn-refusal.json")
                try retainValue2932(rejected.dialogueRequests, root: f.root,
                    name: "rejected-turn-provider-inputs.json")
                try retainProviderArguments2932(rejected, root: f.root, phase: "terminal-turn-refused")
                try retainEffectStage2932(f, stage: "terminal-turn-refused", sessionID: canonical.id,
                    ledger: ledger, checkpoint: reopenedCheckpoint2932)
                throw error
            }
        }
        #expect(rejected.dialogueRequests.isEmpty)
        #expect(f.executor.count == 1)
        #expect(ledger.facts == originalFacts)

        // Exercise the existing Core consumer independently under the same
        // legitimate current Composer policy. This reaches the ledger boundary
        // without replacing or reopening the App's terminal-turn store.
        let identity = try #require(dispatched.executionIdentity)
        let composer = ComposerSubmissionSnapshot(mode: .auto, approvalScope: .request,
            effort: .standard, sessionID: identity.turn.sessionID, turnID: identity.turn.turnID,
            taskID: "effect", attemptID: dispatched.attemptID, messageID: identity.turn.messageID,
            inputDigest: "effect-input-1985", workspaceID: "workspace", createdAt: Date(),
            policyRevision: "current-policy", grantEpoch: "current-epoch", autonomyCeiling: .l3)
        let facts = ComposerPolicyFactSource(knownCapabilities: ["file_write"],
            grantedCapabilities: ["file_write"], allowedWriteRoots: [f.root.path], workspaceID: "workspace",
            revision: "current-policy", grantEpoch: "current-epoch", leaseID: "current-lease",
            expiresAt: .distantFuture, autonomyCeiling: .l3)
        let executor = ComposerPolicyEnforcedToolExecutor(base: f.executor,
            controller: ComposerAuthorizationController(snapshot: composer, facts: facts))
        let replay = FactContextProvider()
        replay.proposeWritePath = marker.path
        let replayResult = try await AgentLoop(maxIterations: 3, toolExecutionFactLedger: ledger).run(
            messages: resumed, systemPrompt: "test", provider: replay, toolExecutor: executor,
            tools: AgentToolCatalog.makeTools().filter { $0.name == "file_write" },
            currentConversationID: canonical.id,
            composerSnapshot: composer, executionIdentity: identity)
        try retainValue2932(replay.dialogueRequests, root: f.root, name: "replay-provider-inputs.json")
        try retainProviderArguments2932(replay, root: f.root, phase: "replay")
        try retainValue2932(replayResult.messages, root: f.root, name: "replay-result-messages.json")
        try retainValue2932(["iterationCount": replayResult.iterationCount,
            "toolCallsExecuted": replayResult.toolCallsExecuted],
            root: f.root, name: "replay-loop-result-counts.json")
        try retainEffectStage2932(f, stage: "replay-refused", sessionID: canonical.id,
            ledger: ledger, checkpoint: reopenedCheckpoint2932)
        #expect(replayResult.toolCallsExecuted == 0)
        #expect(replay.dialogueRequests.first == resumed)
        let feedback = try #require(replay.dialogueRequests.last?.first {
            $0.role == .tool && $0.toolCallID == "new-write"
        })
        try retainValue2932(feedback, root: f.root, name: "actual-duplicate-refusal-feedback.json")
        #expect(feedback.content.contains("duplicate or late tool call identity"))
        #expect(!feedback.content.contains("dry-run"))
        #expect(f.executor.count == 1)
        #expect(try Data(contentsOf: marker) == Data("synthetic effect 1".utf8))
        #expect(ledger.facts == originalFacts)
        #expect(ledger.pendingReceipts.isEmpty)
        #expect(restarted.loadSession(id: canonical.id)?.messages == canonical.messages)

        // A truly fresh request is a different identity. This positive control
        // prevents a global tool-call-id block from falsely passing the replay oracle.
        try restarted.saveMessage(.init(role: .user,
            content: "Fresh request: write the owned synthetic marker a second time."), sessionID: canonical.id)
        let fresh = FactContextProvider()
        fresh.proposeWritePath = marker.path
        try await runEffect1985(f, engine: effectEngine1985(f, sessions: restarted, tasks: tasks,
            ledger: ledger), sessions: restarted, provider: fresh, turnID: 1986)
        #expect(f.executor.count == 2)
        #expect(try Data(contentsOf: marker) == Data("synthetic effect 2".utf8))
        #expect(ledger.facts.contains(dispatched))
        let freshFact = try #require(ledger.facts.first {
            $0.toolCallID == "new-write" && $0.executionIdentity?.turn.turnID == 1986
        })
        #expect(freshFact.status == .succeeded)
        #expect(freshFact.receiptID != dispatched.receiptID)
        #expect(ledger.facts.count == originalFacts.count + 1)
        #expect(ledger.pendingReceipts.isEmpty)
        try retainValue2932(fresh.dialogueRequests, root: f.root, name: "fresh-provider-inputs.json")
        try retainProviderArguments2932(fresh, root: f.root, phase: "fresh")
        try retainEffectStage2932(f, stage: "fresh-dispatched", sessionID: canonical.id,
            ledger: ledger, checkpoint: reopenedCheckpoint2932)
    }

    @Test(arguments: [false, true])
    func reopenedActualRequestRefreshesUnfinishedTaskWithoutRestoringEffectAuthority2550(
        cancelledAfterCheckpoint: Bool
    ) async throws {
        // Start without the old mint-only historical receipt. The retained
        // effect below must originate in the actual AgentLoop dispatch path.
        let f = try fixture(withFacts: false, currentWriteGrant: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let taskID = "unfinished2550"
        let runID = "unfinished-run2550"
        let sourceIdentity = ParentRuntimeIdentity(sessionID: f.id.uuidString,
            conversationID: f.id.uuidString, turnID: "turn-handle:2550",
            taskID: "parent2550", actorID: "owned2550")
        _ = try AgentTaskCreationConsumer(store: f.tasks, knownProjectIDs: ["project"],
            authorizedScopeIDs: ["scope"]).consume(AgentTaskCreationRequest(
                taskID: taskID, parentID: "parent2550", source: sourceIdentity,
                title: "Compare the remaining repair choice", projectID: "project",
                scopeID: "scope", idempotencyKey: "create-unfinished2550"))
        _ = try f.tasks.startRun(taskID: taskID, parentID: "parent2550", runID: runID)
        _ = try f.tasks.appendEvent(runID: runID, kind: .started, detail: "owned synthetic incomplete task")
        let marker = f.root.appendingPathComponent("owned-effect2550.txt")
        f.executor.effectMarkerURL = marker
        f.executor.submittedLedgerURL = f.root.appendingPathComponent("effects.json")
        try f.sessions.saveMessage(.init(role: .user,
            content: "Current bounded authorization: write the owned marker exactly once, then continue the comparison."),
            sessionID: f.id.uuidString)
        let producer = FactContextProvider()
        producer.proposeWritePath = marker.path
        try await runEffect1985(f, engine: f.engine, sessions: f.sessions,
            provider: producer, turnID: 2550)
        let dispatched = try #require(f.ledger.facts.first)
        #expect(dispatched.status == .succeeded)
        #expect(dispatched.executionIdentity?.turn.turnID == 2550)
        #expect(f.executor.observedReceipts.map(\.receiptID) == [dispatched.receiptID])
        #expect(f.executor.count == 1)
        #expect(try Data(contentsOf: marker) == Data("synthetic effect 1".utf8))
        let canonical = try #require(f.sessions.loadSession(id: f.id.uuidString))
        let compactionProvider2550 = FactContextProvider()
        let compacted = try await f.engine.compactContext(provider: compactionProvider2550,
            history: canonical.messages.map { $0.asChatMessageUI() }, systemPrompt: "test", keepRecent: 1,
            sourceSessionID: canonical.id, sourceTranscriptRevision: canonical.transcriptRevision)
        #expect(compacted.refusalReason == nil)
        #expect(compacted.retentionFacts?.contains {
            $0.kind == .unfinishedTask && $0.source?.task?.taskID == taskID
                && $0.source?.task?.status == .running
        } == true)
        #expect(compacted.retentionFacts?.contains { $0.source?.effect != nil } == false)
        let checkpoint = try #require(try ChatSessionBridge.saveCanonicalCompactionCheckpoint(
            sessionStore: f.sessions, sessionID: canonical.id, sourceMessages: canonical.messages,
            expectedTranscriptRevision: canonical.transcriptRevision, result: compacted,
            taskStore: f.tasks, effectLedger: f.ledger))
        if cancelledAfterCheckpoint {
            // A known canonical cancellation, never an inferred success or an
            // unknown-side-effect recovery. The captured checkpoint stays immutable.
            _ = try f.tasks.finish(runID: runID, outcome: .cancelled)
        }
        let reopenedSessions = SessionStore(directory: f.root.appendingPathComponent("sessions"))
        let reopenedTasks = try AgentTaskStore(persistenceURL: f.root.appendingPathComponent("tasks.json"))
        let reopenedLedger = try ToolExecutionFactLedger(persistenceURL: f.root.appendingPathComponent("effects.json"))
        #expect(reopenedTasks.snapshot(taskID: taskID, parentID: "parent2550")?.status
            == (cancelledAfterCheckpoint ? .cancelled : .running))
        let originalFacts = reopenedLedger.facts
        #expect(originalFacts == [dispatched])
        try reopenedSessions.saveMessage(.init(role: .user,
            content: "Continue with the original goal and title; no further write is authorized. Do not repeat the completed effect."),
            sessionID: canonical.id)
        let next = FactContextProvider()
        next.proposeWritePath = marker.path
        try await runEffect1985(f, engine: effectEngine1985(f, sessions: reopenedSessions,
            tasks: reopenedTasks, ledger: reopenedLedger, grantsWrite: false),
            sessions: reopenedSessions, provider: next, turnID: 2551)
        let request = try #require(next.dialogueRequests.first)
        // Older turns are summarized by the model (lossy): their text went whole to the summary request.
        let summarized2550 = compactionProvider2550.summaryRequests.flatMap { $0 }
        #expect(summarized2550.contains { $0.content.contains("Goal: compare repair choices") })
        #expect(summarized2550.contains { $0.content.contains("Keep the original title") })
        #expect(summarized2550.contains { $0.content.contains("Earlier authorization was read-only") })
        #expect(request.contains { $0.content.contains("<context-summary>") })
        // 已成功的写入回执不再进背景；背景只剩仍未完成的任务，任务取消后连背景也不再出现。
        #expect(!request.contains { $0.content.contains(dispatched.receiptID) })
        #expect(!request.contains { $0.content.contains("status=cancelled") })
        if cancelledAfterCheckpoint {
            #expect(!request.contains { $0.content.contains("<retained-store-facts>") })
            #expect(!request.contains { $0.content.contains("status=running") })
        } else {
            let background = try #require(request.first { $0.content.contains("<retained-store-facts>") })
            #expect(background.content.contains(taskID))
            #expect(background.content.contains("status=running"))
            #expect(background.content.contains("No authorization, no tool invocation, no effect replay"))
        }
        let feedback = try #require(next.dialogueRequests.last?.first {
            $0.role == .tool && $0.toolCallID == "new-write"
        })
        #expect(feedback.content.contains(ComposerAuthorizationError.missingCapabilityGrant("file_write").localizedDescription))
        #expect(!feedback.content.contains("duplicate or late"))
        #expect(f.executor.count == 1)
        #expect(try Data(contentsOf: marker) == Data("synthetic effect 1".utf8))
        #expect(reopenedLedger.facts == originalFacts)
        #expect(reopenedLedger.pendingReceipts.isEmpty)
        #expect(try reopenedSessions.loadLatestCompactionCheckpoint(sessionID: canonical.id) == checkpoint)
        #expect(reopenedSessions.loadSession(id: canonical.id)?.messages.starts(with: canonical.messages) == true)
    }

    @Test func retainedCompletedReceiptCannotRestoreRemovedWriteGrantOnNextTurn() async throws {
        let f = try fixture(currentWriteGrant: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let marker = f.root.appendingPathComponent("removed-grant-effect1985.txt")
        f.executor.effectMarkerURL = marker
        f.executor.submittedLedgerURL = f.root.appendingPathComponent("effects.json")
        try f.sessions.saveMessage(.init(role: .user,
            content: "Current request: write the owned synthetic marker once before the grant is removed."),
            sessionID: f.id.uuidString)
        let producer = FactContextProvider()
        producer.proposeWritePath = marker.path
        try await runEffect1985(f, engine: f.engine, sessions: f.sessions, provider: producer, turnID: 1987)
        let dispatched = try #require(f.ledger.facts.first { $0.toolCallID == "new-write" })
        #expect(dispatched.status == .succeeded)
        #expect(f.executor.count == 1)
        let canonical = try #require(f.sessions.loadSession(id: f.id.uuidString))
        let compacted = try await f.engine.compactContext(provider: FactContextProvider(),
            history: canonical.messages.map { $0.asChatMessageUI() }, systemPrompt: "test", keepRecent: 1,
            sourceSessionID: canonical.id, sourceTranscriptRevision: canonical.transcriptRevision)
        _ = try #require(try ChatSessionBridge.saveCanonicalCompactionCheckpoint(
            sessionStore: f.sessions, sessionID: canonical.id, sourceMessages: canonical.messages,
            result: compacted, taskStore: f.tasks, effectLedger: f.ledger))
        let restarted = SessionStore(directory: f.root.appendingPathComponent("sessions"))
        let tasks = try AgentTaskStore(persistenceURL: f.root.appendingPathComponent("tasks.json"))
        let ledger = try ToolExecutionFactLedger(persistenceURL: f.root.appendingPathComponent("effects.json"))
        let originalFacts = ledger.facts
        try restarted.saveMessage(.init(role: .user,
            content: "Fresh request after permission removal: write the owned synthetic marker again."),
            sessionID: canonical.id)
        let provider = FactContextProvider()
        provider.proposeWritePath = marker.path
        try await runEffect1985(f, engine: effectEngine1985(f, sessions: restarted, tasks: tasks,
            ledger: ledger, grantsWrite: false), sessions: restarted, provider: provider, turnID: 1988)
        // 压缩后不再带已成功的回执；权限已移除时新写入仍被拒，且不是被当成重复派发。
        #expect(provider.dialogueRequests.first?.contains {
            $0.content.contains(dispatched.receiptID)
        } == false)
        let feedback = try #require(provider.dialogueRequests.last?.first {
            $0.role == .tool && $0.toolCallID == "new-write"
        })
        #expect(feedback.content.contains(ComposerAuthorizationError.missingCapabilityGrant("file_write").localizedDescription))
        #expect(!feedback.content.contains("duplicate or late"))
        #expect(f.executor.count == 1)
        #expect(try Data(contentsOf: marker) == Data("synthetic effect 1".utf8))
        #expect(ledger.facts == originalFacts)
        #expect(ledger.pendingReceipts.isEmpty)
    }

}
