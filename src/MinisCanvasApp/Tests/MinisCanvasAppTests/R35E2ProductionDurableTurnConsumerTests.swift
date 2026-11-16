import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

private final class R35E2FailingProvider: LLMProvider, @unchecked Sendable {
    let name = "R35E2"
    var model = LLMModel(
        id: "r35-e2-failing-model",
        displayName: "R35 E2 failing provider",
        provider: "R35E2"
    )
    let capabilities: Set<ProviderCapability> = [.streaming, .tools]
    private(set) var calls = 0

    private func fail() throws -> Never {
        calls += 1
        throw LLMError.providerError(message: "r35-e2 provider unavailable")
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        try fail()
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        try fail()
    }

    func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        try fail()
    }
}

private final class R35E2CountingToolExecutor: ToolExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var calls: Int { lock.withLock { count } }

    func execute(name: String, input: [String: Any]) async throws -> String {
        lock.withLock { count += 1 }
        return "synthetic tool result"
    }
}

/// Holds a real production stream after its durable active record is written.
/// The test releases the synthetic response after the reopened engine has
/// attempted the same identity; no transport or tool execution is involved.
private final class R35E2SuspendedProvider: LLMProvider, @unchecked Sendable {
    let name = "R35E2 suspended"
    var model = LLMModel(
        id: "r35-e2-failing-model",
        displayName: "R35 E2 failing provider",
        provider: "R35E2"
    )
    let capabilities: Set<ProviderCapability> = [.tools]
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<LLMResponse, Never>] = []
    private var released = false
    private var count = 0
    var calls: Int { lock.withLock { count } }

    func release() {
        let pending = lock.withLock { () -> [CheckedContinuation<LLMResponse, Never>] in
            released = true
            let current = waiters
            waiters.removeAll()
            return current
        }
        for waiter in pending { waiter.resume(returning: Self.response) }
    }

    private func awaitRelease() async -> LLMResponse {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Bool in
                count += 1
                if released { return true }
                waiters.append(continuation)
                return false
            }
            if ready { continuation.resume(returning: Self.response) }
        }
    }

    private static var response: LLMResponse {
        LLMResponse(text: "synthetic first-turn response", stopReason: "end_turn", usage: nil)
    }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        await awaitRelease()
    }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        await awaitRelease()
    }

    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish(throwing: CancellationError()) }
    }
}

@Suite("R35 E2 production durable turn consumer")
@MainActor
struct R35E2ProductionDurableTurnConsumerTests {
    @Test("snapshot recovery reasons remain fixed and payload-free")
    func snapshotRecoveryReasonProjection() throws {
        let reasons: [AgentTurnContextSnapshotRecoveryReason] = [
            .recordNonLossless, .stateNonLossless, .legacyFormulaUnsafeShape,
            .legacySizeLimit, .legacyBindingShape, .legacySessionBinding,
            .legacyFingerprintShape, .legacySnapshotBindingCollision,
            .legacyFormulaMismatch, .currentCanonicalMismatch
        ]
        for reason in reasons {
            let failure = ProductionContextRecoveryFailure.store(
                .invalidSnapshotRecovery(reason)
            )
            #expect(failure.category == "invalidSnapshot.\(reason.rawValue)")
            let notice = try #require(failure.errorDescription)
            #expect(notice.contains(failure.category))
            #expect(!notice.contains("/"))
            #expect(!notice.contains("synthetic-secret"))
        }
    }

    @Test("corrupt durable tool facts keep the app engine alive without minting a new fact")
    func corruptToolLedgerBlocksTurnAndPreservesOriginalBytes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("r35-e2-corrupt-tool-ledger-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ledgerURL = directory.appendingPathComponent("tool-execution-facts-v4.json")
        let original = Data("synthetic-old-ledger".utf8)
        try original.write(to: ledgerURL)
        let contextURL = directory.appendingPathComponent("agent-turn-context-v1.json")
        let tool = R35E2CountingToolExecutor()

        let engine = AgentLoopChatEngine(
            toolExecutor: tool, contextWritebackStorePersistenceURL: contextURL
        )
        try await assertUnavailableEngine(
            engine, expected: .toolLedger(.corruptLedger),
            persistenceURL: ledgerURL, tool: tool
        )
        #expect(try Data(contentsOf: ledgerURL) == original)
        #expect(!FileManager.default.fileExists(atPath: contextURL.path))
    }

    @Test("unavailable tool-fact root blocks startup turns without replacing the root")
    func unavailableToolLedgerRootBlocksTurnWithoutReplacement() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("r35-e2-unavailable-tool-ledger-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blockedRoot = directory.appendingPathComponent("ordinary-file")
        let original = Data("synthetic-parent".utf8)
        try original.write(to: blockedRoot)
        let contextURL = blockedRoot.appendingPathComponent("agent-turn-context-v1.json")
        let tool = R35E2CountingToolExecutor()

        let engine = AgentLoopChatEngine(
            toolExecutor: tool, contextWritebackStorePersistenceURL: contextURL
        )
        try await assertUnavailableEngine(
            engine, expected: .toolLedger(.persistenceFailed),
            persistenceURL: blockedRoot, tool: tool
        )
        #expect(try Data(contentsOf: blockedRoot) == original)
        #expect(!FileManager.default.fileExists(atPath: contextURL.path))
    }

    @Test("corrupt durable turn journal keeps the engine alive and blocks all turn effects")
    func corruptJournalFailsClosedWithoutReplacingOriginalBytes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("r35-e2-corrupt-startup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let persistenceURL = directory.appendingPathComponent("agent-turn-context-v1.json")
        let original = Data("synthetic-invalid-json".utf8)
        try original.write(to: persistenceURL)

        let engine = AgentLoopChatEngine(contextWritebackStorePersistenceURL: persistenceURL)
        try await assertUnavailableEngine(
            engine, expected: .store(.corruptStore),
            persistenceURL: persistenceURL
        )
        #expect(try Data(contentsOf: persistenceURL) == original)
    }

    @Test("unwritable durable turn journal keeps the engine alive and blocks all turn effects")
    func unavailableJournalFailsClosedWithoutCreatingAnotherStore() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("r35-e2-unwritable-startup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blockedParent = directory.appendingPathComponent("ordinary-file")
        try Data("synthetic-parent".utf8).write(to: blockedParent)
        let persistenceURL = blockedParent.appendingPathComponent("agent-turn-context-v1.json")

        // Keep the separate tool-fact authority healthy so this fixture
        // isolates the context store's directory failure at construction.
        let factLedger = try ToolExecutionFactLedger(
            persistenceURL: directory.appendingPathComponent("tool-execution-facts-v4.json")
        )
        let engine = AgentLoopChatEngine(
            contextWritebackStorePersistenceURL: persistenceURL,
            toolExecutionFactLedger: factLedger
        )
        try await assertUnavailableEngine(
            engine, expected: .store(.persistenceFailed),
            persistenceURL: persistenceURL
        )
        #expect(try Data(contentsOf: blockedParent) == Data("synthetic-parent".utf8))
        #expect(!FileManager.default.fileExists(atPath: persistenceURL.path))
    }

    private func assertUnavailableEngine(
        _ engine: AgentLoopChatEngine,
        expected: ProductionContextRecoveryFailure,
        persistenceURL: URL,
        tool: R35E2CountingToolExecutor? = nil
    ) async throws {
        #expect(engine.contextRecoveryFailure == expected)
        #expect(engine.contextWritebackGate.lifecycleStore == nil)
        let notice = try #require(expected.errorDescription)
        #expect(notice.contains(expected.category))
        #expect(!notice.contains(persistenceURL.path))

        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("r35-e2-banner-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let defaults = try #require(UserDefaults(suiteName: "r35-e2-banner-\(UUID().uuidString)"))
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults),
            preferencesDefaults: defaults,
            logManager: LogManager(directory: fixtureRoot.appendingPathComponent("logs"), ringCapacity: 20),
            sessionDocumentStore: SessionDocumentStore(directory: fixtureRoot.appendingPathComponent("documents")),
            memoryStore: MemoryStore(directory: fixtureRoot.appendingPathComponent("memory")),
            canvasFeatureLane: .phase3NonCanvas
        )
        bridge.chat.agentEngine = engine
        #expect(bridge.recoveryNotices.contains(notice))

        let snapshot = ConversationContextSnapshotV1(
            sessionID: "synthetic-session", providerID: "synthetic-provider",
            modelID: "synthetic-model", configurationFingerprint: "synthetic-config",
            skillIdentifiers: [], conversationID: "synthetic-session"
        )
        let identity = AgentExecutionIdentity(
            turn: .init(sessionID: "synthetic-session", turnID: 1, messageID: "synthetic-message"),
            operationID: "synthetic-operation", attempt: 1
        )
        let prepared = ContextOrchestrator().prepareAgentLoopInput(
            .init(snapshot: snapshot, entries: []), budget: 0,
            executionIdentity: identity
        )
        let input = try #require(prepared.input)
        #expect(engine.contextWritebackGate.begin(input) == false)
        if case .toolLedger = expected {
            #expect(!engine.toolExecutionFactLedger.hasDurableAuthority)
            #expect(throws: ToolExecutionFactLedgerError.durableAuthorityRequired) {
                _ = try engine.toolExecutionFactLedger.mint(
                    toolCallID: "synthetic-tool", toolName: "synthetic-tool",
                    attemptID: "synthetic-attempt", attemptNumber: 1,
                    executionIdentity: identity
                )
            }
            #expect(engine.toolExecutionFactLedger.facts.isEmpty)
            #expect(engine.toolExecutionFactLedger.pendingReceipts.isEmpty)
        }

        let provider = R35E2FailingProvider()
        do {
            _ = try await engine.streamReply(
                provider: provider,
                history: [ChatMessageUI(role: .user, content: "synthetic user text")],
                systemPrompt: "synthetic system text",
                maxTokens: 64,
                conversationID: "synthetic-session",
                authorizedSessionReadSessionID: nil,
                authorizedSessionReadScope: nil,
                turnID: 1
            )
            Issue.record("durable recovery failure must reject the turn")
        } catch let failure as ProductionContextRecoveryFailure {
            #expect(failure == expected)
        } catch {
            Issue.record("unexpected recovery error category: \(type(of: error))")
        }
        #expect(provider.calls == 0)

        // A caller without a manifest or conversation ID must not enter the
        // offline branch of this production engine after durable recovery fails.
        do {
            _ = try await engine.streamReply(
                provider: provider,
                history: [ChatMessageUI(role: .user, content: "synthetic no-context text")],
                systemPrompt: "synthetic system text",
                maxTokens: 64
            )
            Issue.record("missing context must not bypass the failed production gate")
        } catch let failure as ProductionContextRecoveryFailure {
            #expect(failure == expected)
        } catch {
            Issue.record("unexpected no-context error category: \(type(of: error))")
        }
        #expect(provider.calls == 0)

        let compacted = try await engine.compactContext(
            provider: provider,
            history: (0..<4).map { ChatMessageUI(role: .user, content: "synthetic \($0)") },
            systemPrompt: "synthetic system text",
            keepRecent: 1
        )
        #expect(compacted.compactedCount == 0)
        #expect(compacted.refusalReason == .unverifiableInformationLoss)
        #expect(provider.calls == 0)
        if let tool {
            #expect(tool.calls == 0)
        }
    }

    @Test("production stream caller persists terminal success")
    func productionStreamCallerPersistsSuccess() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("r35-e2-stream-success-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let persistenceURL = directory.appendingPathComponent("agent-turn-context-v1.json")
        let conversationID = "r35-e2-stream-success"
        let engine = AgentLoopChatEngine(
            contextWritebackStorePersistenceURL: persistenceURL
        )
        #expect(engine.contextRecoveryFailure == nil)
        #expect(engine.toolExecutionFactLedger.hasDurableAuthority)
        let stream = try await engine.streamReply(
            provider: MockProvider.shared,
            history: [ChatMessageUI(role: .user, content: "hello")],
            systemPrompt: "test",
            maxTokens: 256,
            conversationID: conversationID,
            authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil,
            turnID: 1
        )
        for try await _ in stream { }

        let identity = AgentExecutionIdentity(
            turn: .init(
                sessionID: conversationID,
                turnID: 1,
                messageID: "assistant:\(conversationID):1"
            ),
            operationID: "chat:\(conversationID):1",
            attempt: 1
        )
        let record = try #require(
            engine.contextWritebackGate.lifecycleStore?.record(for: identity)
        )
        #expect(record.status == .completed)
        #expect(record.terminalTruth?.outcome == .succeeded)
    }

    @Test("production Composer plan caller persists dry-run terminal truth")
    func productionComposerPlanCallerPersistsDryRun() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("r35-e2-stream-plan-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let persistenceURL = directory.appendingPathComponent("agent-turn-context-v1.json")
        let conversationID = "r35-e2-stream-plan"
        let turn = AgentTurnIdentity(
            sessionID: conversationID,
            turnID: 1,
            messageID: "assistant:\(conversationID):1"
        )
        let identity = AgentExecutionIdentity(
            turn: turn,
            operationID: "chat:\(conversationID):1",
            attempt: 1
        )
        let snapshot = ComposerSubmissionSnapshot(
            mode: .plan,
            approvalScope: .request,
            effort: .standard,
            sessionID: conversationID,
            turnID: 1,
            taskID: "task:\(conversationID):1",
            attemptID: "attempt:\(conversationID):1",
            messageID: turn.messageID,
            workspaceID: "r35-e2-plan-workspace",
            createdAt: Date(),
            policyRevision: "r35-e2-plan-policy",
            grantEpoch: "r35-e2-plan-epoch",
            autonomyCeiling: .l0
        )
        let facts = ComposerPolicyFactSource(
            knownCapabilities: [],
            grantedCapabilities: [],
            allowedWriteRoots: [],
            workspaceID: snapshot.workspaceID,
            revision: snapshot.policyRevision,
            grantEpoch: snapshot.grantEpoch,
            leaseID: "r35-e2-plan-lease",
            expiresAt: Date().addingTimeInterval(60),
            autonomyCeiling: snapshot.autonomyCeiling
        )
        let engine = AgentLoopChatEngine(
            contextWritebackStorePersistenceURL: persistenceURL,
            composerPolicyFacts: facts,
            onComposerApprovalReceipt: { _ in }
        )
        let stream = try await engine.streamReply(
            provider: MockProvider.shared,
            history: [ChatMessageUI(role: .user, content: "plan this")],
            systemPrompt: "test",
            maxTokens: 256,
            conversationID: conversationID,
            authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil,
            turnID: 1,
            composerSnapshot: snapshot,
            executionIdentity: identity
        )
        for try await _ in stream { }

        let record = try #require(engine.contextWritebackGate.lifecycleStore?.record(for: identity))
        #expect(record.status == .dryRun)
        #expect(record.terminalTruth?.outcome == .dryRun)
        #expect(record.terminalTruth?.reason == "composer-plan")
        let restarted = try AgentTurnContextStore(persistenceURL: persistenceURL)
        #expect(restarted.record(for: identity)?.terminalTruth?.outcome == .dryRun)
    }

    @Test("production policy refusal persists identity and rejects late success")
    func productionPolicyRefusalPersistsAcrossRestart() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("r35-e2-policy-refusal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let persistenceURL = directory.appendingPathComponent("agent-turn-context-v1.json")
        let conversationID = "r35-e2-policy-refusal"
        let provider = R35E2FailingProvider()
        let budget = BudgetTracker(RequestBudget(
            maxRequestsPerSession: 0,
            overBudgetPolicy: .pause
        ))
        let engine = AgentLoopChatEngine(
            toolExecutor: BuiltinToolExecutor(allowedRoot: directory),
            requestBudget: budget,
            contextWritebackStorePersistenceURL: persistenceURL
        )

        let stream = try await engine.streamReply(
            provider: provider,
            history: [ChatMessageUI(role: .user, content: "blocked")],
            systemPrompt: "test",
            maxTokens: 256,
            conversationID: conversationID,
            authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil,
            turnID: 1
        )
        await #expect(throws: AgentLoopError.budgetExhausted) {
            for try await _ in stream { }
        }
        #expect(provider.calls == 0)

        let identity = AgentExecutionIdentity(
            turn: .init(
                sessionID: conversationID,
                turnID: 1,
                messageID: "assistant:\(conversationID):1"
            ),
            operationID: "chat:\(conversationID):1",
            attempt: 1
        )
        let record = try #require(
            engine.contextWritebackGate.lifecycleStore?.record(for: identity)
        )
        let truth = try #require(record.terminalTruth)
        #expect(record.status == .policyRefused)
        #expect(record.generation == 0)
        #expect(record.identity == identity)
        #expect(truth.identity == identity)
        #expect(truth.generation == record.generation)
        #expect(truth.outcome == .policyRefused)
        #expect(truth.reason == AgentLoopError.budgetExhausted.errorDescription)

        let restarted = try AgentTurnContextStore(persistenceURL: persistenceURL)
        let restartedRecord = try #require(restarted.record(for: identity))
        #expect(restartedRecord == record)
        let lateConsumer = AgentStreamLifecycleConsumer(
            store: restarted,
            identity: identity,
            snapshot: restartedRecord.snapshot
        )
        #expect(lateConsumer.currentGeneration == record.generation)
        #expect(lateConsumer.currentPhase == .rejected)
        #expect(lateConsumer.terminalTruth == truth)
        #expect(try lateConsumer.begin() == false)
        #expect(try lateConsumer.admitDelta(sequence: 1) == false)
        #expect(try lateConsumer.finishAfterWriteback() == false)
    }

    @Test("production provider failure persists identity and rejects late success")
    func productionProviderFailurePersistsAcrossRestart() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("r35-e2-provider-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let persistenceURL = directory.appendingPathComponent("agent-turn-context-v1.json")
        let conversationID = "r35-e2-provider-failure"
        let provider = R35E2FailingProvider()
        let engine = AgentLoopChatEngine(
            toolExecutor: BuiltinToolExecutor(allowedRoot: directory),
            contextWritebackStorePersistenceURL: persistenceURL
        )

        let stream = try await engine.streamReply(
            provider: provider,
            history: [ChatMessageUI(role: .user, content: "fail")],
            systemPrompt: "test",
            maxTokens: 256,
            conversationID: conversationID,
            authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil,
            turnID: 1
        )
        var observedError: Error?
        do {
            for try await _ in stream { }
        } catch {
            observedError = error
        }
        #expect(observedError is LLMError)
        #expect(provider.calls == 1)

        let identity = AgentExecutionIdentity(
            turn: .init(
                sessionID: conversationID,
                turnID: 1,
                messageID: "assistant:\(conversationID):1"
            ),
            operationID: "chat:\(conversationID):1",
            attempt: 1
        )
        let record = try #require(
            engine.contextWritebackGate.lifecycleStore?.record(for: identity)
        )
        let truth = try #require(record.terminalTruth)
        #expect(record.status == .failed)
        #expect(record.generation == 0)
        #expect(record.identity == identity)
        #expect(truth.identity == identity)
        #expect(truth.generation == record.generation)
        #expect(truth.outcome == .executionFailed)
        #expect(truth.reason == "Provider error")

        let restarted = try AgentTurnContextStore(persistenceURL: persistenceURL)
        let restartedRecord = try #require(restarted.record(for: identity))
        #expect(restartedRecord == record)
        let lateConsumer = AgentStreamLifecycleConsumer(
            store: restarted,
            identity: identity,
            snapshot: restartedRecord.snapshot
        )
        #expect(lateConsumer.currentGeneration == record.generation)
        #expect(lateConsumer.currentPhase == .failed)
        #expect(lateConsumer.terminalTruth == truth)
        #expect(try lateConsumer.begin() == false)
        #expect(try lateConsumer.admitDelta(sequence: 1) == false)
        #expect(try lateConsumer.finishAfterWriteback() == false)
    }

    @Test("fresh production engine must reject a turn admitted by its predecessor")
    func freshProductionEngineRejectsPreviouslyAdmittedTurn() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("r35-e2-turn-consumer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let persistenceURL = directory.appendingPathComponent("agent-turn-context-v1.json")
        let suffix = UUID().uuidString
        let snapshot = ConversationContextSnapshotV1(
            sessionID: "r35-e2-session-\(suffix)",
            providerID: "r35-e2-provider-\(suffix)",
            modelID: "r35-e2-model-\(suffix)",
            configurationFingerprint: "r35-e2-config-\(suffix)",
            skillIdentifiers: [],
            conversationID: "r35-e2-conversation-\(suffix)"
        )
        let identity = AgentExecutionIdentity(
            turn: .init(sessionID: snapshot.sessionID, turnID: 1, messageID: "r35-e2-message"),
            operationID: "r35-e2-operation-\(suffix)",
            attempt: 1
        )
        let prepared = ContextOrchestrator().prepareAgentLoopInput(
            .init(snapshot: snapshot, entries: []),
            budget: 0,
            executionIdentity: identity
        )
        let input = try #require(prepared.input)

        let firstEngine = AgentLoopChatEngine(
            contextWritebackStorePersistenceURL: persistenceURL,
            onComposerApprovalReceipt: { _ in }
        )
        #expect(firstEngine.contextWritebackGate.begin(input))
        #expect(FileManager.default.fileExists(atPath: persistenceURL.path))
        let sharedStore = try #require(firstEngine.contextWritebackGate.lifecycleStore)
        let productionConsumer = AgentStreamLifecycleConsumer(
            store: sharedStore,
            identity: identity,
            snapshot: snapshot
        )
        #expect(productionConsumer.currentPhase == .active)
        #expect(try productionConsumer.admitDelta(sequence: 1))
        #expect(try productionConsumer.cancel())
        #expect(sharedStore.record(for: identity)?.terminalTruth?.outcome == .cancelled)

        let restartedEngine = AgentLoopChatEngine(
            contextWritebackStorePersistenceURL: persistenceURL,
            onComposerApprovalReceipt: { _ in }
        )
        #expect(restartedEngine.contextWritebackGate.begin(input) == false)
        #expect(
            restartedEngine.contextWritebackGate.lifecycleStore?.record(for: identity)?.terminalTruth?.outcome
                == .cancelled
        )
        firstEngine.contextWritebackGate.finish(input)
    }

    @Test("unfinished production stream survives reopen without resubmitting its original attempt")
    func freshProductionEngineRejectsUnfinishedTurnBeforeProviderOrToolEffect() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("r35-e2-unfinished-turn-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let persistenceURL = directory.appendingPathComponent("agent-turn-context-v1.json")
        let conversationID = "r35-e2-unfinished-\(UUID().uuidString)"
        let firstProvider = R35E2SuspendedProvider()
        defer { firstProvider.release() }
        let firstTool = R35E2CountingToolExecutor()
        let firstEngine = AgentLoopChatEngine(
            toolExecutor: firstTool, executionTimeout: nil,
            contextWritebackStorePersistenceURL: persistenceURL
        )
        let history = [ChatMessageUI(role: .user, content: "synthetic unfinished turn")]
        let firstStream = try await firstEngine.streamReply(
            provider: firstProvider, history: history, systemPrompt: "synthetic system text",
            maxTokens: 256, conversationID: conversationID,
            authorizedSessionReadSessionID: nil, authorizedSessionReadScope: nil, turnID: 1
        )
        let identity = AgentExecutionIdentity(
            turn: .init(sessionID: conversationID, turnID: 1,
                        messageID: "assistant:\(conversationID):1"),
            operationID: "chat:\(conversationID):1", attempt: 1
        )
        let firstRecord = try #require(firstEngine.contextWritebackGate.lifecycleStore?.record(for: identity))
        #expect(firstRecord.status == .active && firstRecord.terminalTruth == nil)
        let originalBytes = try Data(contentsOf: persistenceURL)

        let restartedTool = R35E2CountingToolExecutor()
        let restartedProvider = R35E2FailingProvider()
        let restartedEngine = AgentLoopChatEngine(
            toolExecutor: restartedTool, executionTimeout: nil,
            contextWritebackStorePersistenceURL: persistenceURL
        )
        await #expect(throws: AgentLoopChatEngine.ContextManifestConsumptionError.executionIdentityRejected) {
            _ = try await restartedEngine.streamReply(
                provider: restartedProvider, history: history, systemPrompt: "synthetic system text",
                maxTokens: 256, conversationID: conversationID,
                authorizedSessionReadSessionID: nil, authorizedSessionReadScope: nil, turnID: 1
            )
        }
        #expect(restartedProvider.calls == 0 && restartedTool.calls == 0)
        #expect(restartedEngine.toolExecutionFactLedger.facts.isEmpty)
        #expect(try Data(contentsOf: persistenceURL) == originalBytes)
        #expect(restartedEngine.contextWritebackGate.lifecycleStore?.record(for: identity) == firstRecord)

        firstProvider.release()
        for try await _ in firstStream { }
        #expect(firstProvider.calls == 1)
        #expect(firstTool.calls == 0)
        #expect(firstEngine.contextWritebackGate.lifecycleStore?.record(for: identity)?.status == .completed)
    }

    @Test("offline initializer keeps isolated in-memory gates")
    func offlineInitializerRemainsInMemory() throws {
        let snapshot = ConversationContextSnapshotV1(
            sessionID: "r35-e2-offline-session",
            providerID: "r35-e2-offline-provider",
            modelID: "r35-e2-offline-model",
            configurationFingerprint: "r35-e2-offline-config",
            skillIdentifiers: [],
            conversationID: "r35-e2-offline-conversation"
        )
        let identity = AgentExecutionIdentity(
            turn: .init(sessionID: snapshot.sessionID, turnID: 1, messageID: "r35-e2-offline-message"),
            operationID: "r35-e2-offline-operation",
            attempt: 1
        )
        let prepared = ContextOrchestrator().prepareAgentLoopInput(
            .init(snapshot: snapshot, entries: []),
            budget: 0,
            executionIdentity: identity
        )
        let input = try #require(prepared.input)

        let firstEngine = AgentLoopChatEngine()
        let secondEngine = AgentLoopChatEngine()
        #expect(firstEngine.contextWritebackGate.begin(input))
        #expect(secondEngine.contextWritebackGate.begin(input))
        firstEngine.contextWritebackGate.finish(input)
        secondEngine.contextWritebackGate.finish(input)
    }

    @Test("production path follows the existing session storage root")
    func productionPathUsesSessionStoreRoot() {
        #expect(
            AgentLoopChatEngine.productionContextWritebackPersistenceURL
                == SessionStore.defaultDirectory
                    .appendingPathComponent("agent-turn-context-v1.json")
        )
    }

    @Test("explicit gate injection remains available to offline tests")
    func explicitGateInjectionRemainsAvailable() {
        let gate = ContextOrchestrator.AgentLoopWritebackGate()
        let engine = AgentLoopChatEngine(contextWritebackGate: gate)

        #expect(engine.contextWritebackGate === gate)
    }
}
