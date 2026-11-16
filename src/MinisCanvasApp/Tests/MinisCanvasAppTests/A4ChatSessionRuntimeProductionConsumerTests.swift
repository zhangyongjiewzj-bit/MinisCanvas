import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private enum RuntimeConsumerOutcome: Sendable {
    case success
    case twoToolsThenSuccess
    case failure
    case toolThenFailure
    case toolThenCancellation
    case toolThenInterrupted
    case toolThenTimeout
    case toolThenMaxIterations
    case cancellation
    case interrupted
    case lateFailureAfterCancellation
}

private struct RuntimeConsumerFailure: Error, LocalizedError, Sendable {
    var errorDescription: String? { "runtime consumer provider failure" }
}

private enum RuntimeConsumerToolOutcome: Sendable {
    case success
    case failure
    case cancellation
}

private enum RuntimeConsumerBarrierError: Error {
    case producerCompletedBeforeEntry
}

private enum RuntimeConsumerBrowserFixture {
    static func successfulRead() throws -> String {
        let response = BrowserToolResponse(
            outcome: "read",
            action: "read",
            scopeID: "a4-consumer-scope",
            untrustedPageContent: "tool-ok"
        )
        return String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
    }
}

private final class RuntimeConsumerBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var released = false
    private var enteredWaiter: CheckedContinuation<Void, Error>?
    private var entryFailure: Error?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func markEntered() {
        lock.lock()
        entered = true
        let waiter = enteredWaiter
        enteredWaiter = nil
        lock.unlock()
        waiter?.resume()
    }

    func failEntry(_ error: Error) {
        lock.lock()
        guard !entered, entryFailure == nil else {
            lock.unlock()
            return
        }
        entryFailure = error
        let waiter = enteredWaiter
        enteredWaiter = nil
        lock.unlock()
        waiter?.resume(throwing: error)
    }

    func waitUntilEntered() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if let entryFailure {
                lock.unlock()
                continuation.resume(throwing: entryFailure)
            } else if entered {
                lock.unlock()
                continuation.resume()
            } else {
                enteredWaiter = continuation
                lock.unlock()
            }
        }
    }

    func waitForRelease() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if released {
                lock.unlock()
                continuation.resume()
            } else {
                releaseWaiter = continuation
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        released = true
        let waiter = releaseWaiter
        releaseWaiter = nil
        lock.unlock()
        waiter?.resume()
    }
}

private final class RuntimeConsumerLifecycleProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func record(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    var snapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

private struct RuntimeConsumerToolExecutor: ToolExecutor {
    let outcome: RuntimeConsumerToolOutcome

    init(outcome: RuntimeConsumerToolOutcome = .success) {
        self.outcome = outcome
    }

    func execute(name: String, input: [String: Any]) async throws -> String {
        switch outcome {
        case .success:
            return try RuntimeConsumerBrowserFixture.successfulRead()
        case .failure:
            throw RuntimeConsumerFailure()
        case .cancellation:
            throw CancellationError()
        }
    }
}

private struct RuntimeConsumerBlockingToolExecutor: ToolExecutor {
    let barrier: RuntimeConsumerBarrier

    func execute(name: String, input: [String: Any]) async throws -> String {
        barrier.markEntered()
        await barrier.waitForRelease()
        return try RuntimeConsumerBrowserFixture.successfulRead()
    }
}

private final class RuntimeConsumerProvider: LLMProvider, @unchecked Sendable {
    let name = "runtime-consumer-provider"
    var model = LLMModel(
        id: "runtime-consumer-model",
        displayName: "Runtime Consumer Model",
        provider: "runtime-consumer-provider"
    )
    var capabilities: Set<ProviderCapability> { [] }
    let outcome: RuntimeConsumerOutcome
    let barrier: RuntimeConsumerBarrier?
    private(set) var sendCount = 0
    private var responseIndex = 0

    init(
        outcome: RuntimeConsumerOutcome,
        barrier: RuntimeConsumerBarrier? = nil
    ) {
        self.outcome = outcome
        self.barrier = barrier
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        sendCount += 1
        switch outcome {
        case .success:
            return LLMResponse(text: "consumer-ok", stopReason: "stop", usage: nil)
        case .twoToolsThenSuccess:
            if responseIndex == 0 {
                responseIndex += 1
                let first = LLMToolCall(
                    id: "call-a4-one",
                    name: BrowserTool.toolName,
                    rawArguments: "{\"action\":\"read\",\"query\":\"one\"}",
                    arguments: ["action": "read", "query": "one"]
                )
                let second = LLMToolCall(
                    id: "call-a4-two",
                    name: BrowserTool.toolName,
                    rawArguments: "{\"action\":\"read\",\"query\":\"two\"}",
                    arguments: ["action": "read", "query": "two"]
                )
                return LLMResponse(
                    text: "two tools",
                    stopReason: "tool_calls",
                    usage: nil,
                    toolCalls: [first, second]
                )
            }
            return LLMResponse(text: "consumer-ok", stopReason: "stop", usage: nil)
        case .failure:
            throw RuntimeConsumerFailure()
        case .toolThenFailure:
            if responseIndex == 0 {
                responseIndex += 1
                let call = LLMToolCall(
                    id: "call-a4-duplicate",
                    name: BrowserTool.toolName,
                    rawArguments: "{\"action\":\"read\",\"query\":\"two-stage\"}",
                    arguments: ["action": "read", "query": "two-stage"]
                )
                return LLMResponse(
                    text: "tool request",
                    stopReason: "tool_calls",
                    usage: nil,
                    toolCalls: [call, call]
                )
            }
            throw RuntimeConsumerFailure()
        case .toolThenCancellation:
            if responseIndex == 0 {
                responseIndex += 1
                return Self.toolResponse(id: "call-a4-cancel")
            }
            throw CancellationError()
        case .toolThenInterrupted:
            if responseIndex == 0 {
                responseIndex += 1
                return Self.toolResponse(id: "call-a4-interrupt")
            }
            throw InterruptedError()
        case .toolThenTimeout:
            if responseIndex == 0 {
                responseIndex += 1
                return Self.toolResponse(id: "call-a4-timeout")
            }
            throw AgentLoopError.timedOut(1)
        case .toolThenMaxIterations:
            return Self.toolResponse(id: "call-a4-max")
        case .cancellation:
            throw CancellationError()
        case .interrupted:
            throw InterruptedError()
        case .lateFailureAfterCancellation:
            if let barrier {
                barrier.markEntered()
                await barrier.waitForRelease()
            }
            throw RuntimeConsumerFailure()
        }
    }

    private static func toolResponse(id: String) -> LLMResponse {
        let call = LLMToolCall(
            id: id,
            name: BrowserTool.toolName,
            rawArguments: "{\"action\":\"read\",\"query\":\"\(id)\"}",
            arguments: ["action": "read", "query": id]
        )
        return LLMResponse(
            text: "tool request",
            stopReason: "tool_calls",
            usage: nil,
            toolCalls: [call]
        )
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        try await sendMessage(
            messages: messages,
            systemPrompt: systemPrompt,
            maxTokens: maxTokens,
            temperature: temperature
        )
    }

    func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@Suite("A4 ChatSessionRuntime production consumer")
@MainActor
struct A4ChatSessionRuntimeProductionConsumerTests {
    private struct Fixture {
        let contextSettingsOwner: SettingsCenter
        let root: URL
        let provider: RuntimeConsumerProvider
        let engine: AgentLoopChatEngine
        let composerSnapshot: ComposerSubmissionSnapshot
        let executionIdentity: AgentExecutionIdentity
        let runtimeSnapshot: ChatTurnRuntimeSnapshot
        let sessionID: String
        let turnID: Int
    }

    private struct RetryLedgerFixture {
        let root: URL
        let runtime: ChatSessionRuntime
        let request: ChatTurnRequest
    }

    private func contextSettingsOwner(root: URL, sessionStore: SessionStore) -> SettingsCenter {
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        return SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("context-settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("context-env"), keychain: keychain),
            memoryStore: MemoryStore(directory: root),
            memoryFileStore: MemoryFileStore(directory: root.appendingPathComponent("context-memory-files")),
            sessionStore: sessionStore,
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("context-badges")),
            logManager: LogManager(directory: root.appendingPathComponent("context-logs"), ringCapacity: 20),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("context-mcps.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite(root.lastPathComponent)),
            providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("context-readiness"))
        )
    }

    private func makeFixture(
        outcome: RuntimeConsumerOutcome,
        barrier: RuntimeConsumerBarrier? = nil,
        onRetryLifecycleEvent: (@Sendable (AgentLoopRetryLifecycleEvent) -> Void)? = nil,
        maxIterations: Int = 10,
        resultExecutionIdentityOverride: AgentExecutionIdentity? = nil,
        toolOutcome: RuntimeConsumerToolOutcome = .success,
        toolExecutor: (any ToolExecutor)? = nil,
        onToolExecutionFactForwarded: (@Sendable (ToolExecutionFact) -> Void)? = nil,
        canonicalHistory: [ChatMessageUI] = []
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("A4-runtime-consumer-\(UUID().uuidString)", isDirectory: true)
        let sessionID = "a4-consumer-session"
        let turnID = 1
        let sessionStore = SessionStore(directory: root)
        _ = try sessionStore.createSession(id: sessionID, projectID: "a4-consumer-project")
        // Production consumers resume the durable transcript rather than the
        // caller's UI history. Seed direct-engine fixtures with the same
        // canonical user message that ChatStore persists before submission.
        for message in canonicalHistory {
            try sessionStore.saveMessage(message.asLLMMessage(), sessionID: sessionID)
        }
        let memoryStore = MemoryStore(directory: root)
        let skillStore = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let soulStore = SoulStore(directory: root)
        let provider = RuntimeConsumerProvider(outcome: outcome, barrier: barrier)
        let snapshot = try ProviderRuntimeSnapshot(
            providerID: provider.model.provider,
            modelID: provider.model.id,
            readinessEvidenceID: "live-settings:" + String(repeating: "a", count: 64),
            applyReceiptID: "provider-readiness-apply:a4-consumer"
        )
        let route = try ProviderRuntimeRoute(snapshot: snapshot, primary: provider)
        let turn = AgentTurnIdentity(
            sessionID: sessionID,
            turnID: turnID,
            messageID: "a4-consumer-message"
        )
        let settingsOwner = contextSettingsOwner(root: root, sessionStore: sessionStore)
        let settingsCapture = ChatContextSettingsCapture(
            sessionStore: settingsOwner.sessionStore, sessionID: sessionID, model: provider.model
        )
        let runtimeSnapshot = ChatTurnRuntimeSnapshot(
            turn: turn,
            skillInjector: SkillInjector(store: skillStore).snapshotForTurn(),
            mcpBridge: nil,
            providerRuntimeRoute: route,
            requiresProviderRuntimeRoute: true,
            contextSettingsCapture: settingsCapture
        )
        let composerSnapshot = ComposerSubmissionSnapshot(
            mode: .auto,
            approvalScope: .request,
            effort: .standard,
            sessionID: sessionID,
            turnID: turnID,
            taskID: "a4-consumer-task",
            attemptID: "a4-consumer-attempt",
            messageID: turn.messageID,
            inputDigest: "a4-consumer-input",
            workspaceID: "a4-consumer-workspace",
            createdAt: Date(),
            policyRevision: "a4-consumer-policy",
            grantEpoch: "a4-consumer-grant",
            autonomyCeiling: .l3
        )
        let engine = AgentLoopChatEngine(
            toolExecutor: toolExecutor ?? RuntimeConsumerToolExecutor(outcome: toolOutcome),
            maxIterations: maxIterations,
            chatRuntimeDependencies: .init(
                sessionStore: sessionStore,
                memoryStore: memoryStore,
                skillStore: skillStore,
                soulStore: soulStore
            ),
            contextWritebackStorePersistenceURL: root.appendingPathComponent("context.json"),
            resultExecutionIdentityOverride: resultExecutionIdentityOverride,
            onToolExecutionFactForwarded: onToolExecutionFactForwarded,
            composerPolicyFacts: ComposerPolicyFactSource(
                knownCapabilities: [BrowserTool.toolName],
                grantedCapabilities: [BrowserTool.toolName],
                allowedWriteRoots: [],
                workspaceID: "a4-consumer-workspace",
                revision: "a4-consumer-policy",
                grantEpoch: "a4-consumer-grant",
                leaseID: "a4-consumer-lease",
                expiresAt: .distantFuture,
                autonomyCeiling: .l3
            ),
            onRetryLifecycleEvent: onRetryLifecycleEvent
        )
        return Fixture(
            contextSettingsOwner: settingsOwner,
            root: root,
            provider: provider,
            engine: engine,
            composerSnapshot: composerSnapshot,
            executionIdentity: AgentExecutionIdentity(
                turn: turn,
                operationID: "a4-consumer-operation",
                attempt: 1
            ),
            runtimeSnapshot: runtimeSnapshot,
            sessionID: sessionID,
            turnID: turnID
        )
    }

    private func makeRetryLedgerFixture(
        attempt: Int = 1
    ) async throws -> RetryLedgerFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("A4-retry-ledger-\(UUID().uuidString)", isDirectory: true)
        let sessionID = "a4-retry-ledger-session"
        let sessionStore = SessionStore(directory: root)
        _ = try sessionStore.createSession(id: sessionID, projectID: "a4-retry-ledger-project")
        let runtime = ChatSessionRuntime(
            sessionStore: sessionStore,
            memoryStore: MemoryStore(directory: root),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            soulStore: SoulStore(directory: root),
            provider: RuntimeConsumerProvider(outcome: .failure),
            toolExecutor: RuntimeConsumerToolExecutor()
        )
        let context = try await runtime.makeContext(
            sessionID: sessionID,
            conversationID: "a4-retry-ledger-conversation"
        )
        let executionIdentity = AgentExecutionIdentity(
            turn: AgentTurnIdentity(
                sessionID: sessionID,
                turnID: 1,
                messageID: "a4-retry-ledger-message"
            ),
            operationID: "a4-retry-ledger-operation",
            attempt: attempt
        )
        let request = ChatTurnRequest(
            text: "retry ledger",
            context: context,
            turnID: "a4-retry-ledger-turn",
            taskID: "a4-retry-ledger-task",
            attempt: attempt,
            policySnapshotID: "a4-retry-ledger-policy",
            grantSnapshotID: "a4-retry-ledger-grant",
            executionIdentity: executionIdentity
        )
        return RetryLedgerFixture(root: root, runtime: runtime, request: request)
    }

    @Test("production failure preserves unique accumulated toolCall IDs")
    func productionFailurePreservesUniqueToolCallIDs() async throws {
        let probe = RuntimeConsumerLifecycleProbe()
        let fixture = try makeFixture(
            outcome: .toolThenFailure,
            onRetryLifecycleEvent: { event in
                probe.record(event.rawValue)
            },
            onToolExecutionFactForwarded: { _ in
                probe.record("factForwarded")
            },
            canonicalHistory: [ChatMessageUI(role: .user, content: "two stage")]
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let stream = try await fixture.engine.streamReply(
            provider: fixture.provider,
            history: [ChatMessageUI(role: .user, content: "two stage")],
            systemPrompt: "test",
            maxTokens: 128,
            conversationID: fixture.sessionID,
            authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil,
            turnID: fixture.turnID,
            composerSnapshot: fixture.composerSnapshot,
            executionIdentity: fixture.executionIdentity,
            turnRuntimeSnapshot: fixture.runtimeSnapshot
        )

        let captured = await consumeCapturingFailure(stream)
        guard let error = captured.error else {
            Issue.record("expected two-stage failure")
            return
        }
        if let error = error as? ChatSessionRuntimeError {
            guard case .turnFailed(let envelope) = error else {
                Issue.record("unexpected runtime error: \(error)")
                return
            }
            #expect(fixture.provider.sendCount == 2)
            #expect(envelope.toolCallIDs == ["call-a4-duplicate"])
            let emitted = emittedFacts(from: captured.events)
            #expect(emitted.count == 1)
            #expect(emitted == fixture.engine.toolExecutionFactLedger.facts)
            #expect(emitted.first?.toolCallID == "call-a4-duplicate")
            #expect(emitted.first?.status == .succeeded)
            #expect(probe.snapshot == ["factForwarded", "failureRecorded", "failureFinished"])
        } else {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("runtime fence rejects a late failure after cancellation")
    func runtimeFenceRejectsLateFailureAfterCancellation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("A4-runtime-fence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionStore = SessionStore(directory: root)
        let sessionID = "a4-fence-session"
        _ = try sessionStore.createSession(id: sessionID, projectID: "a4-fence-project")
        let runtime = ChatSessionRuntime(
            sessionStore: sessionStore,
            memoryStore: MemoryStore(directory: root),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            soulStore: SoulStore(directory: root),
            provider: RuntimeConsumerProvider(outcome: .failure),
            toolExecutor: RuntimeConsumerToolExecutor()
        )
        let context = try await runtime.makeContext(
            sessionID: sessionID,
            conversationID: "a4-fence-conversation"
        )
        let request = ChatTurnRequest(
            text: "late failure",
            context: context,
            turnID: "a4-fence-turn",
            taskID: "a4-fence-task",
            attempt: 4,
            policySnapshotID: "a4-fence-policy",
            grantSnapshotID: "a4-fence-grant"
        )
        #expect(try await runtime.beginRetryTurn(request))
        #expect(await runtime.cancelRetryTurn(request))
        await #expect(throws: ChatSessionRuntimeError.retryTurnNotActive) {
            _ = try await runtime.recordRetryFailure(
                request: request,
                failureMessage: "late"
            )
        }
        #expect(await runtime.latestRetryEnvelope == nil)
    }

    @Test("finish callback retires the turn before a late failure callback")
    func finishCallbackRetiresTurnBeforeLateFailure() async throws {
        let fixture = try await makeRetryLedgerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(try await fixture.runtime.beginRetryTurn(fixture.request))
        #expect(await fixture.runtime.finishRetryTurn(fixture.request))
        await #expect(throws: ChatSessionRuntimeError.retryTurnNotActive) {
            _ = try await fixture.runtime.recordRetryFailure(
                request: fixture.request,
                failureMessage: "late after finish"
            )
        }
        #expect(await fixture.runtime.latestRetryEnvelope == nil)
        #expect(
            await fixture.runtime.retryTurnState(for: fixture.request) == .finished
        )
    }

    @Test("older attempt cannot record into the active retry turn")
    func olderAttemptCannotRecordIntoActiveRetryTurn() async throws {
        let fixture = try await makeRetryLedgerFixture(attempt: 2)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let olderRequest = ChatTurnRequest(
            text: fixture.request.text,
            context: fixture.request.context,
            sessionID: fixture.request.sessionID,
            turnID: fixture.request.turnID,
            taskID: fixture.request.taskID,
            attempt: 1,
            policySnapshotID: fixture.request.policySnapshotID,
            grantSnapshotID: fixture.request.grantSnapshotID
        )

        #expect(try await fixture.runtime.beginRetryTurn(fixture.request))
        await #expect(throws: ChatSessionRuntimeError.retryTurnNotActive) {
            _ = try await fixture.runtime.recordRetryFailure(
                request: olderRequest,
                failureMessage: "older attempt"
            )
        }
        #expect(await fixture.runtime.latestRetryEnvelope == nil)
        let envelope = try await fixture.runtime.recordRetryFailure(
            request: fixture.request,
            failureMessage: "active attempt"
        )
        #expect(envelope.attempt == 2)
        #expect(await fixture.runtime.latestRetryEnvelope == envelope)
    }

    @Test("exact duplicate failure callback preserves the first envelope")
    func exactDuplicateFailurePreservesFirstEnvelope() async throws {
        let fixture = try await makeRetryLedgerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(try await fixture.runtime.beginRetryTurn(fixture.request))
        let first = try await fixture.runtime.recordRetryFailure(
            request: fixture.request,
            failureMessage: "first failure"
        )
        await #expect(throws: ChatSessionRuntimeError.retryTurnNotActive) {
            _ = try await fixture.runtime.recordRetryFailure(
                request: fixture.request,
                failureMessage: "duplicate failure"
            )
        }
        #expect(await fixture.runtime.latestRetryEnvelope == first)
        #expect(
            await fixture.runtime.retryTurnState(for: fixture.request) == .finished
        )
    }

    @Test("duplicate begin is rejected without mutating the active turn")
    func duplicateBeginIsRejectedWithoutMutation() async throws {
        let fixture = try await makeRetryLedgerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(try await fixture.runtime.beginRetryTurn(fixture.request))
        #expect(try await fixture.runtime.beginRetryTurn(fixture.request) == false)
        #expect(
            await fixture.runtime.retryTurnState(for: fixture.request) == .active
        )
        #expect(await fixture.runtime.latestRetryEnvelope == nil)
    }

    @Test("duplicate finish is rejected without mutating the finished turn")
    func duplicateFinishIsRejectedWithoutMutation() async throws {
        let fixture = try await makeRetryLedgerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(try await fixture.runtime.beginRetryTurn(fixture.request))
        #expect(await fixture.runtime.finishRetryTurn(fixture.request))
        #expect(await fixture.runtime.finishRetryTurn(fixture.request) == false)
        #expect(await fixture.runtime.cancelRetryTurn(fixture.request) == false)
        #expect(
            await fixture.runtime.retryTurnState(for: fixture.request) == .finished
        )
        #expect(await fixture.runtime.latestRetryEnvelope == nil)
    }

    @Test("duplicate cancel is rejected without mutating the cancelled turn")
    func duplicateCancelIsRejectedWithoutMutation() async throws {
        let fixture = try await makeRetryLedgerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(try await fixture.runtime.beginRetryTurn(fixture.request))
        #expect(await fixture.runtime.cancelRetryTurn(fixture.request))
        #expect(await fixture.runtime.cancelRetryTurn(fixture.request) == false)
        #expect(await fixture.runtime.finishRetryTurn(fixture.request) == false)
        #expect(
            await fixture.runtime.retryTurnState(for: fixture.request) == .cancelled
        )
        #expect(await fixture.runtime.latestRetryEnvelope == nil)
    }

    @Test("cancel race retires the turn before the late failure callback")
    func cancelRaceRetiresTurnBeforeLateFailure() async throws {
        let fixture = try await makeRetryLedgerFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(try await fixture.runtime.beginRetryTurn(fixture.request))
        #expect(await fixture.runtime.cancelRetryTurn(fixture.request))
        await #expect(throws: ChatSessionRuntimeError.retryTurnNotActive) {
            _ = try await fixture.runtime.recordRetryFailure(
                request: fixture.request,
                failureMessage: "late after cancel"
            )
        }
        #expect(await fixture.runtime.latestRetryEnvelope == nil)
        #expect(
            await fixture.runtime.retryTurnState(for: fixture.request) == .cancelled
        )
    }

    @Test("attempt zero fails closed before production retry admission")
    func attemptZeroFailsClosedBeforeProductionRetryAdmission() async throws {
        let fixture = try makeFixture(outcome: .failure)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let invalidIdentity = AgentExecutionIdentity(
            turn: fixture.executionIdentity.turn,
            operationID: "a4-attempt-zero",
            attempt: 0
        )

        await #expect(throws: AgentLoopChatEngine.ContextManifestConsumptionError.invalidExecutionIdentity) {
            _ = try await fixture.engine.streamReply(
                provider: fixture.provider,
                history: [ChatMessageUI(role: .user, content: "attempt zero")],
                systemPrompt: "test",
                maxTokens: 128,
                conversationID: fixture.sessionID,
                authorizedSessionReadSessionID: nil,
                authorizedSessionReadScope: nil,
                turnID: fixture.turnID,
                composerSnapshot: fixture.composerSnapshot,
                executionIdentity: invalidIdentity,
                turnRuntimeSnapshot: fixture.runtimeSnapshot
            )
        }
        #expect(fixture.provider.sendCount == 0)
    }

    @Test("retryEnvelope rejects attempt zero without mutating runtime state")
    func retryEnvelopeAttemptZeroFailsClosed() async throws {
        let fixture = try await makeRetryLedgerFixture(attempt: 0)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let invalidEnvelope = ChatRetryEnvelope(
            envelopeID: "attempt-zero-envelope",
            inputText: fixture.request.text,
            sessionID: fixture.request.context.sessionID,
            conversationID: fixture.request.context.conversationID,
            turnID: fixture.request.turnID ?? "",
            taskID: fixture.request.taskID ?? "",
            attempt: 0,
            providerID: fixture.request.context.providerID,
            modelID: fixture.request.context.modelID,
            configurationFingerprint: fixture.request.context.snapshot.configurationFingerprint,
            policySnapshotID: fixture.request.policySnapshotID ?? "",
            grantSnapshotID: fixture.request.grantSnapshotID ?? "",
            failureMessage: "invalid attempt"
        )

        let replayed = await fixture.runtime.retryEnvelope(invalidEnvelope)

        #expect(replayed == invalidEnvelope)
        #expect(replayed.rejection == .invalidAttempt)
        #expect(await fixture.runtime.latestRetryEnvelope == nil)
        #expect(
            await fixture.runtime.retryTurnState(for: fixture.request) == .unknown
        )
    }

    private func consume(
        _ stream: AsyncThrowingStream<AgentStreamEvent, Error>,
        onEvent: (@Sendable (AgentStreamEvent) -> Void)? = nil
    ) async throws -> [AgentStreamEvent] {
        var events: [AgentStreamEvent] = []
        for try await event in stream {
            onEvent?(event)
            events.append(event)
        }
        try Task.checkCancellation()
        return events
    }

    private func consumeCapturingFailure(
        _ stream: AsyncThrowingStream<AgentStreamEvent, Error>,
        onEvent: (@Sendable (AgentStreamEvent) -> Void)? = nil
    ) async -> (events: [AgentStreamEvent], error: Error?) {
        var events: [AgentStreamEvent] = []
        do {
            for try await event in stream {
                onEvent?(event)
                events.append(event)
            }
            return (events, nil)
        } catch {
            return (events, error)
        }
    }

    private func emittedFacts(from events: [AgentStreamEvent]) -> [ToolExecutionFact] {
        events.compactMap { event in
            guard case .toolCallComplete(_, _, _, let metadata) = event else {
                return nil
            }
            return metadata?.toolExecutionFact
        }
    }

    @Test("production composition binds ChatSessionRuntime before ContextOrchestrator")
    func runtimeIsBoundAtTheProductionConsumer() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appRoot = root.appendingPathComponent("MinisCanvasApp/Sources/MinisCanvasApp")
        let engine = try String(
            contentsOf: appRoot.appendingPathComponent("ChatAgentEngine.swift"),
            encoding: .utf8
        )
        let bridge = try String(
            contentsOf: appRoot.appendingPathComponent("BridgeStore.swift"),
            encoding: .utf8
        )

        #expect(engine.contains("ChatSessionRuntime"))
        #expect(engine.contains("runtime.makeContext"))
        #expect(bridge.contains("chatRuntimeDependencies"))
        #expect(bridge.contains("ChatSessionRuntimeDependencies"))
    }

    @Test("production consumer owns frozen send and retry envelope lifecycle")
    func runtimeProductionSendAndRetryEnvelopeAreConsumed() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let engine = try String(
            contentsOf: root.appendingPathComponent(
                "MinisCanvasApp/Sources/MinisCanvasApp/ChatAgentEngine.swift"
            ),
            encoding: .utf8
        )

        #expect(engine.contains("runtime.sendProduction"))
        #expect(engine.contains("runtime.recordRetryFailure"))
        #expect(engine.contains("runtime.retryEnvelope"))
        #expect(engine.contains("runtime.latestRetryEnvelope"))
    }

    @Test("production preflight does not add a Provider call")
    func productionPreflightDoesNotCallProvider() async throws {
        let fixture = try makeFixture(outcome: .success)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let stream = try await fixture.engine.streamReply(
            provider: fixture.provider,
            history: [ChatMessageUI(role: .user, content: "preflight")],
            systemPrompt: "test",
            maxTokens: 128,
            conversationID: fixture.sessionID,
            authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil,
            turnID: fixture.turnID,
            composerSnapshot: fixture.composerSnapshot,
            executionIdentity: fixture.executionIdentity,
            turnRuntimeSnapshot: fixture.runtimeSnapshot
        )
        _ = try await consume(stream)
        #expect(fixture.provider.sendCount == 1)
    }

    @Test("production success forwards distinct durable facts exactly once")
    func productionSuccessForwardsDistinctDurableFacts() async throws {
        let fixture = try makeFixture(outcome: .twoToolsThenSuccess)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let stream = try await fixture.engine.streamReply(
            provider: fixture.provider,
            history: [ChatMessageUI(role: .user, content: "two tools")],
            systemPrompt: "test",
            maxTokens: 128,
            conversationID: fixture.sessionID,
            authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil,
            turnID: fixture.turnID,
            composerSnapshot: fixture.composerSnapshot,
            executionIdentity: fixture.executionIdentity,
            turnRuntimeSnapshot: fixture.runtimeSnapshot
        )
        let events = try await consume(stream)
        let emitted = emittedFacts(from: events)
        let persisted = fixture.engine.toolExecutionFactLedger.facts
        let toolEventCount = events.reduce(into: 0) { count, event in
            if case .toolCallComplete = event {
                count += 1
            }
        }

        #expect(fixture.engine.toolExecutionFactLedger.hasDurableAuthority)
        #expect(fixture.provider.sendCount == 2)
        #expect(toolEventCount == 2)
        #expect(emitted.count == 2)
        #expect(emitted.map(\.toolCallID) == ["call-a4-one", "call-a4-two"])
        #expect(emitted.map(\.status) == [.succeeded, .succeeded])
        #expect(emitted == persisted)
        #expect(Set(emitted.map(\.receiptID)).count == 2)
    }

    @Test("tool failure forwards a failed durable fact")
    func toolFailureForwardsFailedFact() async throws {
        let fixture = try makeFixture(
            outcome: .twoToolsThenSuccess,
            toolOutcome: .failure
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let stream = try await fixture.engine.streamReply(
            provider: fixture.provider,
            history: [ChatMessageUI(role: .user, content: "tool failure")],
            systemPrompt: "test",
            maxTokens: 128,
            conversationID: fixture.sessionID,
            authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil,
            turnID: fixture.turnID,
            composerSnapshot: fixture.composerSnapshot,
            executionIdentity: fixture.executionIdentity,
            turnRuntimeSnapshot: fixture.runtimeSnapshot
        )
        let events = try await consume(stream)
        let emitted = emittedFacts(from: events)

        #expect(emitted.count == 2)
        #expect(emitted == fixture.engine.toolExecutionFactLedger.facts)
        #expect(emitted.map(\.status) == [.failed, .failed])
    }

    @Test("successful stream settles retry before continuation termination")
    func successfulStreamSettlesRetryBeforeContinuationTermination() async throws {
        let probe = RuntimeConsumerLifecycleProbe()
        let fixture = try makeFixture(
            outcome: .twoToolsThenSuccess,
            onRetryLifecycleEvent: { event in
                probe.record(event.rawValue)
            },
            onToolExecutionFactForwarded: { fact in
                probe.record("factForwarded:\(fact.toolCallID)")
            }
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let stream = try await fixture.engine.streamReply(
            provider: fixture.provider,
            history: [ChatMessageUI(role: .user, content: "success order")],
            systemPrompt: "test",
            maxTokens: 128,
            conversationID: fixture.sessionID,
            authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil,
            turnID: fixture.turnID,
            composerSnapshot: fixture.composerSnapshot,
            executionIdentity: fixture.executionIdentity,
            turnRuntimeSnapshot: fixture.runtimeSnapshot
        )
        let consumer = Task { () -> [AgentStreamEvent] in
            let events = try await consume(stream)
            probe.record("stream-finished")
            return events
        }
        let events = try await consumer.value

        if case .done(stopReason: .endTurn) = events.last {
            // The successful stream reached its terminal event.
        } else {
            Issue.record("successful stream did not end with endTurn")
        }
        #expect(
            probe.snapshot == [
                "factForwarded:call-a4-one",
                "factForwarded:call-a4-two",
                "finished",
                "stream-finished",
            ]
        )
    }

    @Test("production failure emits the frozen retry envelope")
    func productionFailureEmitsFrozenRetryEnvelope() async throws {
        let fixture = try makeFixture(outcome: .failure)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let stream = try await fixture.engine.streamReply(
            provider: fixture.provider,
            history: [ChatMessageUI(role: .user, content: "failure")],
            systemPrompt: "test",
            maxTokens: 128,
            conversationID: fixture.sessionID,
            authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil,
            turnID: fixture.turnID,
            composerSnapshot: fixture.composerSnapshot,
            executionIdentity: fixture.executionIdentity,
            turnRuntimeSnapshot: fixture.runtimeSnapshot
        )

        do {
            _ = try await consume(stream)
            Issue.record("expected frozen retry envelope failure")
        } catch let error as ChatSessionRuntimeError {
            guard case .turnFailed(let envelope) = error else {
                Issue.record("unexpected runtime error: \(error)")
                return
            }
            #expect(fixture.provider.sendCount == 1)
            #expect(envelope.sessionID == fixture.sessionID)
            #expect(envelope.turnID == String(fixture.turnID))
            #expect(envelope.taskID == fixture.composerSnapshot.taskID)
            #expect(envelope.attempt == fixture.executionIdentity.attempt)
            #expect(envelope.policySnapshotID == fixture.composerSnapshot.policyRevision)
            #expect(envelope.grantSnapshotID == fixture.composerSnapshot.grantEpoch)
        }
    }

    @Test("production CancellationError does not emit a retry envelope")
    func productionCancellationDoesNotCreateRetryEnvelope() async throws {
        let fixture = try makeFixture(outcome: .cancellation)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let stream = try await fixture.engine.streamReply(
            provider: fixture.provider,
            history: [ChatMessageUI(role: .user, content: "cancel")],
            systemPrompt: "test",
            maxTokens: 128,
            conversationID: fixture.sessionID,
            authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil,
            turnID: fixture.turnID,
            composerSnapshot: fixture.composerSnapshot,
            executionIdentity: fixture.executionIdentity,
            turnRuntimeSnapshot: fixture.runtimeSnapshot
        )

        await #expect(throws: CancellationError.self) {
            _ = try await consume(stream)
        }
        #expect(fixture.provider.sendCount == 1)
    }

    @Test("provider cancellation forwards already-settled facts")
    func providerCancellationForwardsFacts() async throws {
        let probe = RuntimeConsumerLifecycleProbe()
        let fixture = try makeFixture(
            outcome: .toolThenCancellation,
            onRetryLifecycleEvent: { event in
                probe.record(event.rawValue)
            },
            onToolExecutionFactForwarded: { _ in
                probe.record("factForwarded")
            }
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let stream = try await fixture.engine.streamReply(
            provider: fixture.provider,
            history: [ChatMessageUI(role: .user, content: "tool then cancel")],
            systemPrompt: "test",
            maxTokens: 128,
            conversationID: fixture.sessionID,
            authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil,
            turnID: fixture.turnID,
            composerSnapshot: fixture.composerSnapshot,
            executionIdentity: fixture.executionIdentity,
            turnRuntimeSnapshot: fixture.runtimeSnapshot
        )
        let captured = await consumeCapturingFailure(stream)
        #expect(captured.error is CancellationError)
        #expect(emittedFacts(from: captured.events) == fixture.engine.toolExecutionFactLedger.facts)
        #expect(fixture.engine.toolExecutionFactLedger.facts.map(\.status) == [.succeeded])
        #expect(probe.snapshot == ["factForwarded", "cancelled"])
    }

    @Test("tool cancellation forwards a cancelled durable fact")
    func toolCancellationForwardsCancelledFact() async throws {
        let probe = RuntimeConsumerLifecycleProbe()
        let fixture = try makeFixture(
            outcome: .toolThenCancellation,
            onRetryLifecycleEvent: { event in
                probe.record(event.rawValue)
            },
            toolOutcome: .cancellation,
            onToolExecutionFactForwarded: { _ in
                probe.record("factForwarded")
            }
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let stream = try await fixture.engine.streamReply(
            provider: fixture.provider,
            history: [ChatMessageUI(role: .user, content: "tool cancellation")],
            systemPrompt: "test",
            maxTokens: 128,
            conversationID: fixture.sessionID,
            authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil,
            turnID: fixture.turnID,
            composerSnapshot: fixture.composerSnapshot,
            executionIdentity: fixture.executionIdentity,
            turnRuntimeSnapshot: fixture.runtimeSnapshot
        )
        let captured = await consumeCapturingFailure(stream)

        #expect(captured.error is CancellationError)
        #expect(emittedFacts(from: captured.events) == fixture.engine.toolExecutionFactLedger.facts)
        #expect(fixture.engine.toolExecutionFactLedger.facts.map(\.status) == [.cancelled])
        #expect(probe.snapshot == ["factForwarded", "cancelled"])
    }

    @Test("production InterruptedError does not emit a retry envelope")
    func productionInterruptedDoesNotCreateRetryEnvelope() async throws {
        let fixture = try makeFixture(outcome: .interrupted)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let stream = try await fixture.engine.streamReply(
            provider: fixture.provider,
            history: [ChatMessageUI(role: .user, content: "cancel")],
            systemPrompt: "test",
            maxTokens: 128,
            conversationID: fixture.sessionID,
            authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil,
            turnID: fixture.turnID,
            composerSnapshot: fixture.composerSnapshot,
            executionIdentity: fixture.executionIdentity,
            turnRuntimeSnapshot: fixture.runtimeSnapshot
        )

        await #expect(throws: InterruptedError.self) {
            _ = try await consume(stream)
        }
        #expect(fixture.provider.sendCount == 1)
    }

    @Test("provider interruption forwards already-settled facts")
    func providerInterruptionForwardsFacts() async throws {
        let fixture = try makeFixture(outcome: .toolThenInterrupted)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let stream = try await fixture.engine.streamReply(
            provider: fixture.provider,
            history: [ChatMessageUI(role: .user, content: "tool then interrupt")],
            systemPrompt: "test",
            maxTokens: 128,
            conversationID: fixture.sessionID,
            authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil,
            turnID: fixture.turnID,
            composerSnapshot: fixture.composerSnapshot,
            executionIdentity: fixture.executionIdentity,
            turnRuntimeSnapshot: fixture.runtimeSnapshot
        )
        let captured = await consumeCapturingFailure(stream)
        #expect(captured.error is InterruptedError)
        #expect(emittedFacts(from: captured.events) == fixture.engine.toolExecutionFactLedger.facts)
        #expect(fixture.engine.toolExecutionFactLedger.facts.map(\.status) == [.succeeded])
    }

    @Test("timeout forwards already-settled facts before retry failure")
    func timeoutForwardsFacts() async throws {
        let fixture = try makeFixture(
            outcome: .toolThenTimeout,
            canonicalHistory: [ChatMessageUI(role: .user, content: "tool then timeout")]
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let stream = try await fixture.engine.streamReply(
            provider: fixture.provider,
            history: [ChatMessageUI(role: .user, content: "tool then timeout")],
            systemPrompt: "test",
            maxTokens: 128,
            conversationID: fixture.sessionID,
            authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil,
            turnID: fixture.turnID,
            composerSnapshot: fixture.composerSnapshot,
            executionIdentity: fixture.executionIdentity,
            turnRuntimeSnapshot: fixture.runtimeSnapshot
        )
        let captured = await consumeCapturingFailure(stream)
        #expect(captured.error is ChatSessionRuntimeError)
        #expect(emittedFacts(from: captured.events) == fixture.engine.toolExecutionFactLedger.facts)
        #expect(fixture.engine.toolExecutionFactLedger.facts.map(\.status) == [.succeeded])
    }

    @Test("max iteration forwards already-settled facts")
    func maxIterationForwardsFacts() async throws {
        let fixture = try makeFixture(
            outcome: .toolThenMaxIterations,
            maxIterations: 1,
            canonicalHistory: [ChatMessageUI(role: .user, content: "max iterations")]
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let stream = try await fixture.engine.streamReply(
            provider: fixture.provider,
            history: [ChatMessageUI(role: .user, content: "max iterations")],
            systemPrompt: "test",
            maxTokens: 128,
            conversationID: fixture.sessionID,
            authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil,
            turnID: fixture.turnID,
            composerSnapshot: fixture.composerSnapshot,
            executionIdentity: fixture.executionIdentity,
            turnRuntimeSnapshot: fixture.runtimeSnapshot
        )
        let captured = await consumeCapturingFailure(stream)
        #expect(captured.error is ChatSessionRuntimeError)
        #expect(emittedFacts(from: captured.events) == fixture.engine.toolExecutionFactLedger.facts)
        #expect(fixture.engine.toolExecutionFactLedger.facts.map(\.status) == [.succeeded])
    }

    @Test("settlement persistence failure emits no fake fact")
    func settlementPersistenceFailureEmitsNoFakeFact() async throws {
        let barrier = RuntimeConsumerBarrier()
        defer { barrier.release() }
        let fixture = try makeFixture(
            outcome: .toolThenMaxIterations,
            toolExecutor: RuntimeConsumerBlockingToolExecutor(barrier: barrier)
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let consumer = Task {
            do {
                let stream = try await fixture.engine.streamReply(
                    provider: fixture.provider,
                    history: [ChatMessageUI(role: .user, content: "persistence fault")],
                    systemPrompt: "test",
                    maxTokens: 128,
                    conversationID: fixture.sessionID,
                    authorizedSessionReadSessionID: nil,
                    authorizedSessionReadScope: nil,
                    turnID: fixture.turnID,
                    composerSnapshot: fixture.composerSnapshot,
                    executionIdentity: fixture.executionIdentity,
                    turnRuntimeSnapshot: fixture.runtimeSnapshot
                )
                let captured = await consumeCapturingFailure(stream)
                barrier.failEntry(captured.error ?? RuntimeConsumerBarrierError.producerCompletedBeforeEntry)
                return captured
            } catch {
                barrier.failEntry(error)
                return (events: [AgentStreamEvent](), error: error)
            }
        }
        try await barrier.waitUntilEntered()
        #expect(fixture.engine.toolExecutionFactLedger.pendingReceipts.count == 1)
        let ledgerURL = fixture.root.appendingPathComponent("tool-execution-facts-v4.json")
        try FileManager.default.removeItem(at: ledgerURL)
        try FileManager.default.createDirectory(at: ledgerURL, withIntermediateDirectories: false)
        barrier.release()
        let captured = await consumer.value

        #expect(captured.error is ChatSessionRuntimeError)
        #expect(emittedFacts(from: captured.events).isEmpty)
        #expect(fixture.engine.toolExecutionFactLedger.facts.isEmpty)
        #expect(fixture.engine.toolExecutionFactLedger.pendingReceipts.count == 1)
    }

    @Test("identity mismatch emits zero facts")
    func identityMismatchEmitsZeroFacts() async throws {
        let fixture = try makeFixture(outcome: .twoToolsThenSuccess)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let mismatchedIdentity = AgentExecutionIdentity(
            turn: AgentTurnIdentity(
                sessionID: fixture.sessionID,
                turnID: fixture.turnID + 1,
                messageID: "mismatched-message"
            ),
            operationID: "mismatched-operation",
            attempt: 1
        )

        await #expect(throws: ChatTurnRuntimeSnapshotError.identityMismatch) {
            _ = try await fixture.engine.streamReply(
                provider: fixture.provider,
                history: [ChatMessageUI(role: .user, content: "identity mismatch")],
                systemPrompt: "test",
                maxTokens: 128,
                conversationID: fixture.sessionID,
                authorizedSessionReadSessionID: nil,
                authorizedSessionReadScope: nil,
                turnID: fixture.turnID,
                composerSnapshot: fixture.composerSnapshot,
                executionIdentity: mismatchedIdentity,
                turnRuntimeSnapshot: fixture.runtimeSnapshot
            )
        }
        #expect(fixture.provider.sendCount == 0)
        #expect(fixture.engine.toolExecutionFactLedger.facts.isEmpty)
    }

    @Test("post-execution identity mismatch emits zero facts")
    func postExecutionIdentityMismatchEmitsZeroFacts() async throws {
        let resultIdentity = AgentExecutionIdentity(
            turn: AgentTurnIdentity(
                sessionID: "a4-consumer-session",
                turnID: 1,
                messageID: "a4-consumer-message"
            ),
            operationID: "post-execution-mismatch",
            attempt: 1
        )
        let fixture = try makeFixture(
            outcome: .twoToolsThenSuccess,
            resultExecutionIdentityOverride: resultIdentity
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let stream = try await fixture.engine.streamReply(
            provider: fixture.provider,
            history: [ChatMessageUI(role: .user, content: "post mismatch")],
            systemPrompt: "test",
            maxTokens: 128,
            conversationID: fixture.sessionID,
            authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil,
            turnID: fixture.turnID,
            composerSnapshot: fixture.composerSnapshot,
            executionIdentity: fixture.executionIdentity,
            turnRuntimeSnapshot: fixture.runtimeSnapshot
        )
        let captured = await consumeCapturingFailure(stream)

        #expect(captured.error is ChatSessionRuntimeError)
        #expect(emittedFacts(from: captured.events).isEmpty)
        #expect(fixture.engine.toolExecutionFactLedger.facts.count == 2)
        #expect(
            fixture.engine.toolExecutionFactLedger.facts.allSatisfy {
                $0.executionIdentity == resultIdentity
            }
        )
    }

    @Test("late Provider failure after consumer cancellation is not retry-enveloped")
    func lateProviderFailureAfterCancellationDoesNotCreateRetryEnvelope() async throws {
        let barrier = RuntimeConsumerBarrier()
        defer { barrier.release() }
        let fixture = try makeFixture(
            outcome: .lateFailureAfterCancellation,
            barrier: barrier
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let stream = try await fixture.engine.streamReply(
            provider: fixture.provider,
            history: [ChatMessageUI(role: .user, content: "late cancel")],
            systemPrompt: "test",
            maxTokens: 128,
            conversationID: fixture.sessionID,
            authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil,
            turnID: fixture.turnID,
            composerSnapshot: fixture.composerSnapshot,
            executionIdentity: fixture.executionIdentity,
            turnRuntimeSnapshot: fixture.runtimeSnapshot
        )
        let consumer = Task {
            do {
                _ = try await consume(stream)
                barrier.failEntry(RuntimeConsumerBarrierError.producerCompletedBeforeEntry)
                return Optional<Error>.none
            } catch {
                barrier.failEntry(error)
                return Optional(error)
            }
        }
        try await barrier.waitUntilEntered()
        consumer.cancel()
        barrier.release()
        let error = await consumer.value

        #expect(fixture.provider.sendCount == 1)
        #expect((error as? CancellationError) != nil)
        #expect((error as? ChatSessionRuntimeError) == nil)
    }

    @Test("scoped runtime context reaches the durable ContextOrchestrator manifest")
    func scopedRuntimeContextFeedsManifest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("a4-runtime-consumer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "a4-production-session"
        let projectID = "a4-production-project"
        let sessionStore = SessionStore(directory: root)
        _ = try sessionStore.createSession(
            id: sessionID,
            projectID: projectID,
            projectName: "A4",
            workingDirectory: root.path
        )
        let memoryStore = MemoryStore(directory: root)
        let skillStore = SkillStore(skillsRoot: root.appendingPathComponent("skills"))
        let soulStore = SoulStore(directory: root)
        let scope = MemoryScope(sessionID: sessionID, projectID: projectID)
        let imported = try skillStore.importSkillThroughLifecycle(
            content: """
            ---
            name: A4 runtime skill
            description: scoped runtime test
            version: 1
            ---
            A4 runtime skill body.
            """,
            reason: "A4 production consumer test",
            scope: scope,
            approval: SkillApproval(approverID: "a4-test", scope: scope)
        )
        let manifestStore = try ContextManifestStore(
            persistenceURL: root.appendingPathComponent("manifests.json")
        )
        let engine = AgentLoopChatEngine(
            contextManifestStore: manifestStore,
            chatRuntimeDependencies: .init(
                sessionStore: sessionStore,
                memoryStore: memoryStore,
                skillStore: skillStore,
                soulStore: soulStore
            ),
            composerPolicyFacts: ComposerPolicyFactSource(
                knownCapabilities: [],
                grantedCapabilities: [],
                allowedWriteRoots: [],
                workspaceID: "a4-production-workspace",
                revision: "a4-production-revision",
                grantEpoch: "a4-production-epoch",
                leaseID: "a4-production-lease",
                expiresAt: Date().addingTimeInterval(60),
                autonomyCeiling: .l3
            )
        )
        let turn = AgentTurnIdentity(
            sessionID: sessionID,
            turnID: 1,
            messageID: "a4-assistant-1"
        )
        let composerSnapshot = ComposerSubmissionSnapshot(
            mode: .auto,
            approvalScope: .request,
            effort: .standard,
            sessionID: turn.sessionID,
            turnID: turn.turnID,
            taskID: "a4-task-1",
            attemptID: "a4-attempt-1",
            messageID: turn.messageID,
            inputDigest: "a4-input",
            workspaceID: "a4-production-workspace",
            createdAt: Date(),
            policyRevision: "a4-production-revision",
            grantEpoch: "a4-production-epoch",
            autonomyCeiling: .l3
        )
        let executionIdentity = AgentExecutionIdentity(
            turn: turn,
            operationID: "a4-operation-1"
        )
        let settingsOwner = contextSettingsOwner(root: root, sessionStore: sessionStore)
        defer { withExtendedLifetime(settingsOwner) {} }
        let settingsCapture = ChatContextSettingsCapture(
            sessionStore: settingsOwner.sessionStore, sessionID: sessionID, model: MockProvider.shared.model
        )
        let runtimeSnapshot = ChatTurnRuntimeSnapshot(
            turn: turn,
            skillInjector: SkillInjector(store: skillStore).snapshotForTurn(),
            mcpBridge: nil,
            contextSettingsCapture: settingsCapture
        )
        let stream = try await engine.streamReply(
            provider: MockProvider.shared,
            history: [ChatMessageUI(role: .user, content: "运行 A4")],
            systemPrompt: "test",
            maxTokens: 256,
            conversationID: sessionID,
            authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil,
            turnID: turn.turnID,
            composerSnapshot: composerSnapshot,
            executionIdentity: executionIdentity,
            turnRuntimeSnapshot: runtimeSnapshot
        )
        for try await _ in stream {}

        let manifest = try #require(manifestStore.manifest(runID: try AgentLoopChatEngine.generatedContextManifestRunID(for: executionIdentity)))
        #expect(manifest.snapshot.sessionID == sessionID)
        #expect(manifest.snapshot.skillIdentifiers == [imported.skill.id])
    }

    @Test("real Engine forwards a settled first tool before the next running phase")
    func inlineSettlementPrecedesNextDispatch() async throws {
        let fixture = try makeFixture(outcome: .twoToolsThenSuccess)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let stream = try await fixture.engine.streamReply(
            provider: fixture.provider,
            history: [ChatMessageUI(role: .user, content: "causal order")],
            systemPrompt: "test", maxTokens: 128, conversationID: fixture.sessionID,
            authorizedSessionReadSessionID: nil, authorizedSessionReadScope: nil,
            turnID: fixture.turnID, composerSnapshot: fixture.composerSnapshot,
            executionIdentity: fixture.executionIdentity, turnRuntimeSnapshot: fixture.runtimeSnapshot)
        let events = try await consume(stream)
        let firstCompletion = try #require(events.firstIndex {
            if case .toolCallComplete(let id, _, _, let metadata) = $0 {
                return id == "call-a4-one" && metadata?.toolExecutionFact != nil
            }
            return false
        })
        let nextDispatch = try #require(events.firstIndex {
            if case .toolExecutionPhase(let phase) = $0 {
                return phase.compositeKey.toolCallID == "call-a4-two" && phase.phase == .running
            }
            return false
        })
        #expect(firstCompletion < nextDispatch)
        #expect(emittedFacts(from: events).map(\.toolCallID) == ["call-a4-one", "call-a4-two"])
        #expect(emittedFacts(from: events) == fixture.engine.toolExecutionFactLedger.facts)
    }

    @Test("production settlement subscription preserves parallel completion order and fallback once")
    func inlineParallelSettlementAndHistoricalFallback() async throws {
        let fixture = try makeFixture(outcome: .success)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let ledger = fixture.engine.toolExecutionFactLedger
        let accumulator = TurnToolCallAccumulator()
        defer { accumulator.closeSettlementObservations() }
        let identity = AgentExecutionIdentity(turn: AgentTurnIdentity(
            sessionID: "inline-parallel", turnID: 1, messageID: "message"),
            operationID: "operation", attempt: 1)
        let first = try ledger.mint(toolCallID: "first", toolName: "file_read",
            attemptID: "attempt", attemptNumber: 1, executionIdentity: identity)
        let second = try ledger.mint(toolCallID: "second", toolName: "file_read",
            attemptID: "attempt", attemptNumber: 1, executionIdentity: identity)
        let pair = AsyncThrowingStream<AgentStreamEvent, Error>.makeStream()
        let receive: @Sendable (ToolExecutionFact) -> Void = { fact in
            pair.continuation.yield(.toolCallComplete(id: fact.toolCallID,
                name: fact.toolName, args: [:], metadata: ToolCallMetadata(toolExecutionFact: fact)))
        }
        for receipt in [first, second] {
            let phase = ToolExecutionPhaseFact(compositeKey: try #require(receipt.compositeKey),
                executionIdentity: identity, toolName: receipt.toolName,
                phase: .running, occurredAt: Date())
            accumulator.observeSettlement(for: phase, ledger: ledger, receive: receive)
            // A repeated live phase cannot subscribe or emit twice.
            accumulator.observeSettlement(for: phase, ledger: ledger, receive: receive)
        }
        let releaseFirst = RuntimeConsumerBarrier()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await releaseFirst.waitForRelease()
                _ = try ledger.settle(first, status: .succeeded)
            }
            group.addTask {
                _ = try ledger.settle(second, status: .succeeded)
                releaseFirst.release()
            }
            try await group.waitForAll()
        }
        // The exact Engine fallback admission cannot repeat the observed facts.
        for fact in ledger.facts where accumulator.claimForwarding(fact) { receive(fact) }
        // No running subscription existed for this historical/late fact: preserve fallback.
        let late = try ledger.mint(toolCallID: "late", toolName: "file_read",
            attemptID: "attempt", attemptNumber: 1, executionIdentity: identity)
        let settledLateFact = try ledger.settle(late, status: .succeeded)
        let lateFact = try #require(settledLateFact)
        accumulator.observeSettlement(for: ToolExecutionPhaseFact(
            compositeKey: try #require(late.compositeKey), executionIdentity: identity,
            toolName: late.toolName, phase: .running, occurredAt: Date()), ledger: ledger, receive: receive)
        #expect(accumulator.claimForwarding(lateFact))
        receive(lateFact)
        #expect(!accumulator.claimForwarding(lateFact))
        pair.continuation.finish()
        let events = try await consume(pair.stream)
        #expect(emittedFacts(from: events).map(\.toolCallID) == ["second", "first", "late"])
        #expect(ledger.pendingReceipts.isEmpty)
    }

    @Test("closing a turn unregisters projection without cancelling durable settlement")
    func inlineSettlementObservationClosesWithoutChangingExecution() throws {
        let fixture = try makeFixture(outcome: .success)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let ledger = fixture.engine.toolExecutionFactLedger
        let accumulator = TurnToolCallAccumulator()
        let probe = RuntimeConsumerLifecycleProbe()
        let identity = AgentExecutionIdentity(turn: AgentTurnIdentity(
            sessionID: "inline-close", turnID: 1, messageID: "message"),
            operationID: "operation", attempt: 1)
        let receipt = try ledger.mint(toolCallID: "read", toolName: "file_read",
            attemptID: "attempt", attemptNumber: 1, executionIdentity: identity)
        accumulator.observeSettlement(for: ToolExecutionPhaseFact(
            compositeKey: try #require(receipt.compositeKey), executionIdentity: identity,
            toolName: receipt.toolName, phase: .running, occurredAt: Date()), ledger: ledger) { fact in
            probe.record(fact.receiptID)
        }
        accumulator.closeSettlementObservations()
        accumulator.closeSettlementObservations()
        let settledFact = try ledger.settle(receipt, status: .succeeded)
        let fact = try #require(settledFact)
        #expect(probe.snapshot.isEmpty)
        #expect(ledger.fact(compositeKey: try #require(receipt.compositeKey), receiptID: receipt.receiptID) == fact)
    }
}
