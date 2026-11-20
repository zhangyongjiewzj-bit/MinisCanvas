import Foundation
import Testing
@testable import MinisCore

private final class LockedResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?

    func store(_ value: Value) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func load() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class TakeoverBarrier: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    func pause() {
        entered.signal()
        release.wait()
    }
}

private final class V2FactProvider: LLMProvider, @unchecked Sendable {
    let name = "V2FactProvider"
    var model = LLMModel(id: "v2-fact", displayName: "V2 Fact", provider: "Test")
    var capabilities: Set<ProviderCapability> { [.tools] }
    var responses: [LLMResponse]
    let exhaustedError: Error?

    init(_ responses: [LLMResponse], exhaustedError: Error? = nil) {
        self.responses = responses
        self.exhaustedError = exhaustedError
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        if responses.isEmpty, let exhaustedError {
            throw exhaustedError
        }
        return responses.isEmpty
            ? LLMResponse(text: "done", stopReason: nil, usage: nil)
            : responses.removeFirst()
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

private final class V2FactExecutor: ToolExecutor, @unchecked Sendable {
    enum Mode {
        case success
        case cancelled
        case failed
        case timedOut
        case childDeadline
    }

    let mode: Mode
    let output: String
    private(set) var callCount = 0

    init(_ mode: Mode = .success, output: String = "ok") {
        self.mode = mode
        self.output = output
    }

    func execute(name: String, input: [String: Any]) async throws -> String {
        callCount += 1
        switch mode {
        case .success:
            return output
        case .cancelled:
            throw CancellationError()
        case .failed:
            throw ToolExecutorError.fileNotFound("synthetic-missing")
        case .timedOut:
            throw ToolExecutorError.toolTimeout("v2-timeout")
        case .childDeadline:
            throw AgentChildLifecycleError.deadlineExceeded
        }
    }
}

// Real harmless file effect; only the network response is synthetic. The
// ledger bytes are observed before the effect without taking writer authority.
private final class Event591EffectThenFaultExecutor: ToolExecutor, @unchecked Sendable {
    private struct DiskState: Decodable {
        let pending: [String: ToolExecutionReceipt]
        let facts: [String: ToolExecutionFact]
    }
    enum ObservationError: Error { case missingDurableReceipt }
    let ledgerURL: URL
    let savedDirectory: URL
    let effectURL: URL
    private(set) var callCount = 0
    private(set) var persistedReceipt: ToolExecutionReceipt?

    init(ledgerURL: URL) {
        self.ledgerURL = ledgerURL
        let directory = ledgerURL.deletingLastPathComponent()
        savedDirectory = directory.appendingPathExtension("saved-pending")
        effectURL = directory.appendingPathExtension("effect")
    }

    func execute(name: String, input: [String: Any]) async throws -> String {
        let state = try JSONDecoder().decode(DiskState.self, from: Data(contentsOf: ledgerURL))
        guard let current = ToolExecutionReceiptContext.current,
              state.pending.count == 1, state.facts.isEmpty,
              state.pending.values.first == current else {
            throw ObservationError.missingDurableReceipt
        }
        persistedReceipt = current
        try Data("one harmless effect".utf8).write(to: effectURL, options: .atomic)
        callCount += 1
        // Preserve the actual submitted bytes for restart, then fail only the
        // settlement write path after the external effect has completed.
        let directory = ledgerURL.deletingLastPathComponent()
        try FileManager.default.moveItem(at: directory, to: savedDirectory)
        try Data("synthetic persistence fault".utf8).write(to: directory)
        return "one harmless effect completed"
    }

    func restoreSubmittedBytes() throws {
        let directory = ledgerURL.deletingLastPathComponent()
        try FileManager.default.moveItem(at: directory, to: directory.appendingPathExtension("fault-marker"))
        try FileManager.default.moveItem(at: savedDirectory, to: directory)
    }
}

private final class NonExecutionObservationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var observed = 0
    func record() { lock.withLock { observed += 1 } }
    var count: Int { lock.withLock { observed } }
}

private func v2Envelope(id: String) -> String {
    v3Envelope(calls: [[
        "id": id,
        "name": "web_search",
        "input": ["query": "x"],
    ]])
}

private func v3Envelope(calls: [[String: Any]]) -> String {
    let object: [String: Any] = ["tool_calls": calls]
    return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
}

private func v2Tool() -> AgentToolDefinition {
    AgentToolDefinition(name: "web_search", description: "", parameters: [:], required: [])
}

// web_search 默认要问（11/19）；本文件的测试与审批无关，显式设为自动通过。
private func v2AutoApproveGate() -> ApprovalGate {
    ApprovalGate(policyByTool: ["web_search": .autoApprove])
}

private func v2Identity(attempt: Int) -> AgentExecutionIdentity {
    AgentExecutionIdentity(
        turn: AgentTurnIdentity(sessionID: "v2-session", turnID: 1, messageID: "v2-message"),
        operationID: "v2-operation",
        attempt: attempt
    )
}

private func v4Identity(
    sessionID: String,
    turnID: Int,
    messageID: String,
    operationID: String,
    attempt: Int
) -> AgentExecutionIdentity {
    AgentExecutionIdentity(
        turn: AgentTurnIdentity(
            sessionID: sessionID,
            turnID: turnID,
            messageID: messageID
        ),
        operationID: operationID,
        attempt: attempt
    )
}

private func v2LedgerURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ToolExecutionFactV2-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("facts.json")
}

private func v6ComposerSnapshot() -> ComposerSubmissionSnapshot {
    ComposerSubmissionSnapshot(
        mode: .manual,
        approvalScope: .request,
        effort: .standard,
        sessionID: "composer-session",
        turnID: 1,
        taskID: "composer-task",
        attemptID: "composer-attempt",
        messageID: "composer-message",
        workspaceID: "composer-workspace",
        createdAt: Date(timeIntervalSince1970: 1_000),
        policyRevision: "policy-1",
        grantEpoch: "epoch-1"
    )
}

@Suite("ToolExecutionFactV2Tests", .serialized)
struct ToolExecutionFactV2Tests {

    private struct V2ProviderFailure: Error, Equatable {}

    @Test func liveFailureFeedbackIsSingleShotTransientAndKeepsTheOldObserverAPI() async throws {
        let url = try v2LedgerURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ledger = try ToolExecutionFactLedger(persistenceURL: url)
        let receipt = try ledger.mint(toolCallID: "native-read", toolName: "file_read",
            attemptID: "attempt-1", attemptNumber: 1, executionIdentity: v2Identity(attempt: 1))
        let key = try #require(receipt.compositeKey)
        let oldStream = AsyncStream<ToolExecutionFact>.makeStream()
        let liveStream = AsyncStream<(ToolExecutionFact, ToolExecutionLiveFailureFeedback?)>.makeStream()
        let oldObservation = ledger.observeSettlement(compositeKey: key, receiptID: receipt.receiptID) { fact in
            #expect(ledger.facts.contains(fact))
            oldStream.continuation.yield(fact)
        }
        let liveObservation = ledger.observeSettlement(compositeKey: key, receiptID: receipt.receiptID) { fact, feedback in
            #expect(ledger.facts.contains(fact))
            liveStream.continuation.yield((fact, feedback))
        }
        defer { oldObservation?.cancel(); liveObservation?.cancel() }
        let settled = try ledger.settle(receipt, status: .failed, elapsedMilliseconds: 7,
            liveFailureReason: .builtinFileReadPermissionDenied)
        let fact = try #require(settled)
        #expect(try ledger.settle(receipt, status: .failed, elapsedMilliseconds: 8,
            liveFailureReason: .builtinFileReadPermissionDenied) == nil)
        oldStream.continuation.finish(); liveStream.continuation.finish()
        var oldFacts: [ToolExecutionFact] = []
        for await value in oldStream.stream { oldFacts.append(value) }
        var liveFacts: [(ToolExecutionFact, ToolExecutionLiveFailureFeedback?)] = []
        for await value in liveStream.stream { liveFacts.append(value) }
        #expect(oldFacts == [fact] && liveFacts.count == 1)
        let feedback = try #require(liveFacts.first?.1)
        #expect(feedback.compositeKey == key && feedback.receiptID == receipt.receiptID)
        #expect(feedback.executionIdentity == receipt.executionIdentity)
        #expect(feedback.reason == .builtinFileReadPermissionDenied)
        let replay = AsyncStream<(ToolExecutionFact, ToolExecutionLiveFailureFeedback?)>.makeStream()
        let historical = ledger.observeSettlement(compositeKey: key, receiptID: receipt.receiptID) { value, detail in
            replay.continuation.yield((value, detail))
        }
        #expect(historical == nil)
        replay.continuation.finish()
        var historicalFacts: [(ToolExecutionFact, ToolExecutionLiveFailureFeedback?)] = []
        for await value in replay.stream { historicalFacts.append(value) }
        #expect(historicalFacts.count == 1 && historicalFacts.first?.0 == fact)
        #expect(historicalFacts.first?.1 == nil)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 6)
        let facts = try #require(object["facts"] as? [String: [String: Any]])
        let raw = try #require(facts[key.rawValue])
        // Exact fields of the pre-existing failed fact; live feedback never gains a durable key.
        #expect(Set(raw.keys) == ["toolCallID", "receiptID", "toolName", "status", "attemptID",
            "attemptNumber", "executionIdentity", "compositeKey", "elapsedMilliseconds"])
        let reopened = try ToolExecutionFactLedger(persistenceURL: url)
        #expect(reopened.facts == [fact])
        #expect(reopened.facts.first?.executionIdentity == receipt.executionIdentity)
    }

    @Test func durableLedgerReloadRetainsReceiptAndRejectsDuplicateLateSettlement() throws {
        let url = try v2LedgerURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = try ToolExecutionFactLedger(persistenceURL: url)
        let receipt = try first.mint(
            toolCallID: "reload-call",
            toolName: "web_search",
            attemptID: "attempt-1",
            attemptNumber: 1,
            executionIdentity: v2Identity(attempt: 1)
        )
        let settledFact = try first.settle(receipt, status: .succeeded)
        let fact = try #require(settledFact)

        let reloaded = try ToolExecutionFactLedger(persistenceURL: url)
        #expect(reloaded.hasDurableAuthority)
        #expect(reloaded.facts == [fact])
        #expect(throws: ToolExecutionFactLedgerError.duplicateToolCallID("reload-call")) {
            _ = try reloaded.mint(
                toolCallID: "reload-call",
                toolName: "web_search",
                attemptID: "attempt-1",
                attemptNumber: 1,
                executionIdentity: v2Identity(attempt: 1)
            )
        }
        #expect(try reloaded.settle(receipt, status: .failed) == nil)
    }

    @Test func directAttemptZeroFailsClosedBeforeExecutorAndDoesNotMint() async throws {
        let url = try v2LedgerURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ledger = try ToolExecutionFactLedger(persistenceURL: url)
        let executor = V2FactExecutor()
        let provider = V2FactProvider([
            LLMResponse(text: v2Envelope(id: "attempt-zero"), stopReason: nil, usage: nil),
        ])

        await #expect(throws: AgentLoopError.invalidToolExecutionAttempt) {
            _ = try await AgentLoop(
                maxIterations: 1,
                approvalGate: v2AutoApproveGate(),
                toolExecutionFactLedger: ledger
            ).run(
                messages: [],
                systemPrompt: nil,
                provider: provider,
                toolExecutor: executor,
                tools: [v2Tool()],
                executionIdentity: v2Identity(attempt: 0)
            )
        }
        #expect(executor.callCount == 0)
        #expect(ledger.facts.isEmpty)
        #expect(ledger.pendingReceipts.isEmpty)
    }

    @Test func failedDurableMintBlocksRealExecutorBeforeExternalEffect() async throws {
        let url = try v2LedgerURL()
        let directory = url.deletingLastPathComponent()
        let ledger = try ToolExecutionFactLedger(persistenceURL: url)
        let executor = V2FactExecutor()
        try FileManager.default.removeItem(at: directory)
        try Data("blocking-file".utf8).write(to: directory)
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(atPath: url.path + ".lock")
        }

        await #expect(throws: AgentLoopError.toolExecutionFactsUnavailable) {
            _ = try await AgentLoop(
                maxIterations: 1,
                approvalGate: v2AutoApproveGate(),
                toolExecutionFactLedger: ledger
            ).run(
                messages: [],
                systemPrompt: nil,
                provider: V2FactProvider([
                    LLMResponse(text: v2Envelope(id: "mint-fault"), stopReason: nil, usage: nil),
                ]),
                toolExecutor: executor,
                tools: [v2Tool()],
                executionIdentity: v2Identity(attempt: 1)
            )
        }
        #expect(executor.callCount == 0)
        #expect(ledger.pendingReceipts.isEmpty)
        #expect(ledger.facts.isEmpty)
    }

    @Test func realEffectThenSettlementFaultReloadsUnknownWithoutRedispatch() async throws {
        let url = try v2LedgerURL()
        let first = try ToolExecutionFactLedger(persistenceURL: url)
        let executor = Event591EffectThenFaultExecutor(ledgerURL: url)
        let nonExecution = NonExecutionObservationProbe()
        let identity = v2Identity(attempt: 1)
        let envelope = v2Envelope(id: "event591-effect")
        do {
            var loop = AgentLoop(maxIterations: 2, approvalGate: v2AutoApproveGate(), toolExecutionFactLedger: first)
            loop.onToolNonExecution = { _, _ in nonExecution.record() }
            _ = try await loop.run(
                messages: [], systemPrompt: nil,
                provider: V2FactProvider([LLMResponse(text: envelope, stopReason: nil, usage: nil)]),
                toolExecutor: executor, tools: [v2Tool()], executionIdentity: identity
            )
            Issue.record("settlement fault must stop the production loop")
        } catch let error as AgentLoopError {
            guard case .toolExecutionFactSettlementFailed = error else { throw error }
        }
        let receipt = try #require(executor.persistedReceipt)
        #expect(executor.callCount == 1)
        #expect(try Data(contentsOf: executor.effectURL) == Data("one harmless effect".utf8))
        #expect(first.pendingReceipts == [receipt])
        #expect(first.facts.isEmpty)
        #expect(nonExecution.count == 0)
        try executor.restoreSubmittedBytes()
        let recovered = try ToolExecutionFactLedger(persistenceURL: url)
        #expect(recovered.recoveredPendingReceipts == [receipt])
        #expect(recovered.pendingReceipts == [receipt])
        #expect(recovered.facts.isEmpty)
        let unknown = ConversationEventProjection().projectingRecoveredPendingTools(
            recovered.recoveredPendingReceipts, activeExecutions: [],
            occurredAt: Date(timeIntervalSince1970: 591)
        )
        #expect(unknown.toolLifecycleEvents.count == 1)
        #expect(unknown.toolLifecycleEvents.first?.status == .needsReview)
        #expect(unknown.toolLifecycleEvents.first?.toolCompositeKey == receipt.compositeKey)
        _ = try await AgentLoop(maxIterations: 2, approvalGate: v2AutoApproveGate(), toolExecutionFactLedger: recovered).run(
            messages: [], systemPrompt: nil,
            provider: V2FactProvider([LLMResponse(text: envelope, stopReason: nil, usage: nil)]),
            toolExecutor: executor, tools: [v2Tool()], executionIdentity: identity
        )
        #expect(executor.callCount == 1)
        #expect(recovered.pendingReceipts == [receipt])
        #expect(recovered.facts.isEmpty)
        #expect(throws: ToolExecutionFactLedgerError.externalOutcomeUnverified) {
            try recovered.reconcilePending()
        }
        #expect(recovered.pendingReceipts == [receipt] && recovered.facts.isEmpty)
        let reopened = try ToolExecutionFactLedger(persistenceURL: url)
        #expect(reopened.pendingReceipts == [receipt] && reopened.facts.isEmpty)
        #expect(throws: ToolExecutionFactLedgerError.externalOutcomeUnverified) {
            try reopened.reconcilePending()
        }
        #expect(executor.callCount == 1)
        // Own UUID fixture artifacts intentionally retained as fault evidence.
    }

    @Test func composerAttemptIDCannotRescueZeroExecutionAttempt() async throws {
        let url = try v2LedgerURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ledger = try ToolExecutionFactLedger(persistenceURL: url)
        let executor = V2FactExecutor()
        let composerSnapshot = v6ComposerSnapshot()
        let provider = V2FactProvider([
            LLMResponse(text: v2Envelope(id: "composer-zero"), stopReason: nil, usage: nil),
        ])
        await #expect(throws: AgentLoopError.invalidToolExecutionAttempt) {
            _ = try await AgentLoop(
                maxIterations: 1,
                approvalGate: v2AutoApproveGate(),
                toolExecutionFactLedger: ledger
            ).run(
                messages: [],
                systemPrompt: nil,
                provider: provider,
                toolExecutor: executor,
                tools: [v2Tool()],
                composerSnapshot: composerSnapshot,
                executionIdentity: v4Identity(
                    sessionID: composerSnapshot.sessionID,
                    turnID: composerSnapshot.turnID,
                    messageID: composerSnapshot.messageID,
                    operationID: "v2-operation",
                    attempt: 0
                )
            )
        }
        #expect(executor.callCount == 0)
        #expect(ledger.facts.isEmpty)
        #expect(ledger.pendingReceipts.isEmpty)
    }

    @Test func approvalFailureHappensBeforeReceiptMint() async throws {
        let url = try v2LedgerURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ledger = try ToolExecutionFactLedger(persistenceURL: url)
        let executor = V2FactExecutor()
        let gate = ApprovalGate(
            policyByTool: ["web_search": .alwaysAsk],
            delegate: V2DenyDelegate()
        )
        let provider = V2FactProvider([
            LLMResponse(text: v2Envelope(id: "approval-call"), stopReason: nil, usage: nil),
            LLMResponse(text: "done", stopReason: nil, usage: nil),
        ])

        let outcome = await AgentLoop(
            maxIterations: 1,
            approvalGate: gate,
            toolExecutionFactLedger: ledger
        ).runOutcome(
            messages: [],
            systemPrompt: nil,
            provider: provider,
            toolExecutor: executor,
            tools: [v2Tool()],
            executionIdentity: v2Identity(attempt: 1)
        )
        #expect(outcome.result == nil)
        #expect(outcome.failure?.agentError == .maxIterationsExceeded(1))
        #expect(outcome.toolExecutionFacts.isEmpty)
        #expect(ledger.pendingReceipts.isEmpty)
        #expect(executor.callCount == 0)
    }

    @Test func cancellationThrowLeavesConsumableCancelledFact() async throws {
        let url = try v2LedgerURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ledger = try ToolExecutionFactLedger(persistenceURL: url)
        let provider = V2FactProvider([
            LLMResponse(text: v2Envelope(id: "cancel-call"), stopReason: nil, usage: nil),
        ])

        await #expect(throws: CancellationError.self) {
            _ = try await AgentLoop(
                maxIterations: 1,
                approvalGate: v2AutoApproveGate(),
                toolExecutionFactLedger: ledger
            ).run(
                messages: [],
                systemPrompt: nil,
                provider: provider,
                toolExecutor: V2FactExecutor(.cancelled),
                tools: [v2Tool()],
                executionIdentity: v2Identity(attempt: 1)
            )
        }
        #expect(ledger.facts.first?.status == .cancelled)
        #expect(ledger.facts.first?.failureCategory == nil)
        #expect(ledger.facts.first?.receiptID.isEmpty == false)
    }

    @Test func timeoutThrowLeavesConsumableFailedFact() async throws {
        let url = try v2LedgerURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ledger = try ToolExecutionFactLedger(persistenceURL: url)
        let provider = V2FactProvider([
            LLMResponse(text: v2Envelope(id: "timeout-call"), stopReason: nil, usage: nil),
        ])

        await #expect(throws: ToolExecutorError.self) {
            _ = try await AgentLoop(
                maxIterations: 1,
                approvalGate: v2AutoApproveGate(),
                toolExecutionFactLedger: ledger
            ).run(
                messages: [],
                systemPrompt: nil,
                provider: provider,
                toolExecutor: V2FactExecutor(.timedOut),
                tools: [v2Tool()],
                executionIdentity: v2Identity(attempt: 1)
            )
        }
        #expect(ledger.facts.first?.status == .failed)
        #expect(ledger.facts.first?.failureCategory == .timeout)
        #expect(ledger.facts.first?.toolCallID == "timeout-call")
    }

    @Test func childDeadlineLeavesTypedTimeoutFact() async throws {
        let url = try v2LedgerURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ledger = try ToolExecutionFactLedger(persistenceURL: url)
        let provider = V2FactProvider([
            LLMResponse(text: v2Envelope(id: "child-deadline"), stopReason: nil, usage: nil),
        ])

        await #expect(throws: AgentLoopError.timedOut(0)) {
            _ = try await AgentLoop(
                maxIterations: 1,
                approvalGate: v2AutoApproveGate(),
                toolExecutionFactLedger: ledger
            ).run(
                messages: [],
                systemPrompt: nil,
                provider: provider,
                toolExecutor: V2FactExecutor(.childDeadline),
                tools: [v2Tool()],
                executionIdentity: v2Identity(attempt: 1)
            )
        }
        #expect(ledger.facts.first?.status == .failed)
        #expect(ledger.facts.first?.failureCategory == .timeout)
        #expect(ledger.facts.first?.toolCallID == "child-deadline")
    }

    @Test func ordinaryToolFailureDoesNotClaimTimeout() async throws {
        let url = try v2LedgerURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ledger = try ToolExecutionFactLedger(persistenceURL: url)
        let outcome = await AgentLoop(
            maxIterations: 1,
            approvalGate: v2AutoApproveGate(),
            toolExecutionFactLedger: ledger
        ).runOutcome(
            messages: [],
            systemPrompt: nil,
            provider: V2FactProvider([
                LLMResponse(text: v2Envelope(id: "ordinary-failure"), stopReason: nil, usage: nil),
            ]),
            toolExecutor: V2FactExecutor(.failed),
            tools: [v2Tool()],
            executionIdentity: v2Identity(attempt: 1)
        )
        #expect(outcome.toolExecutionFacts.first?.status == .failed)
        #expect(outcome.toolExecutionFacts.first?.failureCategory == nil)
        #expect(ledger.facts.first?.failureCategory == nil)
    }

    @Test func runOutcomeCarriesFactsAcrossMaxIterationFailure() async throws {
        let url = try v2LedgerURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ledger = try ToolExecutionFactLedger(persistenceURL: url)
        let provider = V2FactProvider([
            LLMResponse(text: v2Envelope(id: "max-call"), stopReason: nil, usage: nil),
        ])

        let outcome = await AgentLoop(
            maxIterations: 1,
            approvalGate: v2AutoApproveGate(),
            toolExecutionFactLedger: ledger
        ).runOutcome(
            messages: [],
            systemPrompt: nil,
            provider: provider,
            toolExecutor: V2FactExecutor(),
            tools: [v2Tool()],
            executionIdentity: v2Identity(attempt: 1)
        )
        #expect(outcome.result == nil)
        #expect(outcome.failure?.agentError == .maxIterationsExceeded(1))
        #expect(outcome.toolExecutionFacts.first?.toolCallID == "max-call")
        #expect(outcome.toolExecutionFacts.first?.status == .succeeded)
    }

    @Test func runOutcomeCarriesFactsAcrossProviderFailure() async throws {
        let url = try v2LedgerURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ledger = try ToolExecutionFactLedger(persistenceURL: url)
        let provider = V2FactProvider(
            [LLMResponse(text: v2Envelope(id: "provider-failure-call"), stopReason: nil, usage: nil)],
            exhaustedError: V2ProviderFailure()
        )

        let outcome = await AgentLoop(
            maxIterations: 2,
            approvalGate: v2AutoApproveGate(),
            toolExecutionFactLedger: ledger
        ).runOutcome(
            messages: [],
            systemPrompt: nil,
            provider: provider,
            toolExecutor: V2FactExecutor(),
            tools: [v2Tool()],
            executionIdentity: v2Identity(attempt: 1)
        )
        #expect(outcome.result == nil)
        #expect(outcome.failure?.agentError == nil)
        #expect(outcome.toolExecutionFacts.first?.toolCallID == "provider-failure-call")
    }

    @Test func twoRealToolCallsMintDistinctReceiptsAndFacts() async throws {
        let url = try v2LedgerURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ledger = try ToolExecutionFactLedger(persistenceURL: url)
        let provider = V2FactProvider([
            LLMResponse(
                text: v3Envelope(calls: [
                    ["id": "call-a", "name": "web_search", "input": ["query": "a"]],
                    ["id": "call-b", "name": "web_search", "input": ["query": "b"]],
                ]),
                stopReason: nil,
                usage: nil
            ),
            LLMResponse(text: "done", stopReason: nil, usage: nil),
        ])

        let result = try await AgentLoop(
            maxIterations: 2,
            approvalGate: v2AutoApproveGate(),
            toolExecutionFactLedger: ledger
        ).run(
            messages: [],
            systemPrompt: nil,
            provider: provider,
            toolExecutor: V2FactExecutor(),
            tools: [v2Tool()],
            executionIdentity: v2Identity(attempt: 1)
        )
        #expect(result.toolExecutionFacts.map(\.toolCallID) == ["call-a", "call-b"])
        #expect(Set(result.toolExecutionFacts.map(\.receiptID)).count == 2)
        #expect(ledger.facts == result.toolExecutionFacts)
    }

    /// 失败的调用也带卡片详情：展开就能看到发给模型的同一条报错（用户 11/20 会话 893B52D5）。
    @Test func failedToolFactCarriesTheErrorInItsCardDetail() async throws {
        let url = try v2LedgerURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ledger = try ToolExecutionFactLedger(persistenceURL: url)
        let provider = V2FactProvider([
            LLMResponse(text: v2Envelope(id: "failed-call"), stopReason: nil, usage: nil),
            LLMResponse(text: "done", stopReason: nil, usage: nil),
        ])
        let result = try await AgentLoop(maxIterations: 2, approvalGate: v2AutoApproveGate(), toolExecutionFactLedger: ledger).run(
            messages: [],
            systemPrompt: nil,
            provider: provider,
            toolExecutor: V2FactExecutor(.failed),
            tools: [v2Tool()],
            executionIdentity: v2Identity(attempt: 1)
        )
        let fact = try #require(result.toolExecutionFacts.first)
        #expect(fact.status == .failed)
        let detail = try #require(fact.outputSummary?.detail)
        #expect(detail.output?.contains("synthetic-missing") == true)
        #expect(try ToolExecutionFactLedger(persistenceURL: url).facts.first?.outputSummary == fact.outputSummary)
    }

    /// 有执行事实账本时（与正式环境一致），真正执行过且记为失败的调用连续 8 次就停下回合。
    @Test func executedFailuresOfOneToolStopTheTurnAtTheLimit() async throws {
        let url = try v2LedgerURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ledger = try ToolExecutionFactLedger(persistenceURL: url)
        let limit = RepeatedToolFailureCounter.limit
        let provider = V2FactProvider((1...(limit + 3)).map {
            LLMResponse(text: v2Envelope(id: "repeat-\($0)"), stopReason: nil, usage: nil)
        })
        let executor = V2FactExecutor(.failed)
        let outcome = await AgentLoop(maxIterations: AgentLoop.unlimitedIterations, approvalGate: v2AutoApproveGate(),
                                      loopDetector: nil, toolExecutionFactLedger: ledger).runOutcome(
            messages: [], systemPrompt: nil, provider: provider, toolExecutor: executor,
            tools: [v2Tool()], executionIdentity: v2Identity(attempt: 1))
        #expect(outcome.failure?.agentError == .repeatedToolFailure(tool: v2Tool().name, count: limit))
        #expect(executor.callCount == limit)
        #expect(outcome.toolExecutionFacts.count == limit)
        #expect(outcome.toolExecutionFacts.allSatisfy { $0.status == .failed })
    }

    @Test func actualToolOutputBecomesContentFreeDurableEventSummary() async throws {
        let url = try v2LedgerURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ledger = try ToolExecutionFactLedger(persistenceURL: url)
        let canary = "synthetic-private-value-DO-NOT-DISPLAY"
        let output = String(repeating: "row\n", count: 2_000) + canary
        let provider = V2FactProvider([
            LLMResponse(text: v2Envelope(id: "output-call"), stopReason: nil, usage: nil),
            LLMResponse(text: "done", stopReason: nil, usage: nil),
        ])
        let result = try await AgentLoop(maxIterations: 2, approvalGate: v2AutoApproveGate(), toolExecutionFactLedger: ledger).run(
            messages: [],
            systemPrompt: nil,
            provider: provider,
            toolExecutor: V2FactExecutor(output: output),
            tools: [v2Tool()],
            executionIdentity: v2Identity(attempt: 1)
        )
        let fact = try #require(result.toolExecutionFacts.first)
        // 对齐 Claude Code：事实里带可展开的输出详情，统计不变，详情有行数上限。
        guard case .withDetail(let base, let detail)? = fact.outputSummary else {
            Issue.record("expected output summary with detail")
            return
        }
        #expect(base == .text(bytes: output.utf8.count, lines: 2_001))
        #expect((detail.output ?? "").split(separator: "\n", omittingEmptySubsequences: false).count
            <= ToolOutputSummary.maxDetailLines)
        #expect(detail.omittedLines > 0)
        #expect(!(detail.output ?? "").contains(canary), "超出行数上限的尾部不进入详情")
        #expect(try ToolExecutionFactLedger(persistenceURL: url).facts.first?.outputSummary == fact.outputSummary)

        let eventURL = url.deletingLastPathComponent().appendingPathComponent("events.json")
        let consumer = try ToolLifecycleConsumer(persistenceURL: eventURL)
        #expect(await consumer.ingestToolExecutionFact(
            fact,
            eventID: fact.toolCallID,
            eventName: fact.toolName,
            taskID: "v2-task",
            expectedAttemptID: fact.attemptID,
            scopeID: "v2-scope"
        ))
        let event = try #require(consumer.events.first)
        #expect(event.summary.contains("仅显示统计，结果正文未在此展示"))
        #expect(event.summary.contains("返回 \(output.utf8.count) 字节、2001 行"))
        #expect(!event.summary.contains(canary))
        let visible = ConversationEventProjection.display(for: event)
        #expect(visible.summary.contains("仅显示统计，结果正文未在此展示"))
        #expect(!visible.summary.contains(canary))

        var legacyObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(fact)) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "outputSummary")
        let legacy = try JSONDecoder().decode(
            ToolExecutionFact.self,
            from: JSONSerialization.data(withJSONObject: legacyObject)
        )
        #expect(legacy.outputSummary == nil)
    }

    @Test func shellSummaryMeasuresReturnedStreamsWithoutKeepingTheirText() {
        let output = #"{"exit_code":7,"stdout":"first\nsecond\n","stderr":"synthetic-private-value"}"#
        let summary = ToolOutputSummary.capture(toolName: "shell_execute", output: output)
        #expect(summary == .shell(
            exitCode: 7,
            stdoutBytes: "first\nsecond\n".utf8.count,
            stdoutLines: 2,
            stderrBytes: "synthetic-private-value".utf8.count,
            stderrLines: 1
        ))
        #expect(summary.displaySuffix?.contains("退出码 7") == true)
        #expect(summary.displaySuffix?.contains("仅显示统计，结果正文未在此展示") == true)
        #expect(summary.displaySuffix?.contains("synthetic-private-value") == false)
    }

    @Test func fixedBuiltinWriteAndEditResultsYieldSafeContentSignals() async throws {
        let url = try v2LedgerURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let root = url.deletingLastPathComponent().resolvingSymlinksInPath()
        let canary = "synthetic-private-output-value"
        let file = root.appendingPathComponent("\(canary).txt")
        let executor = BuiltinToolExecutor(allowedRoot: root)
        executor.fileChangeLedger = FileChangeLedger(workspaceRoot: root.path)
        executor.fileChangeSessionID = "safe-content-session"
        let writeContent = "alpha\nbeta"
        let writeOutput = try await executor.execute(
            name: "file_write",
            input: ["path": file.path, "content": writeContent]
        )
        let writeSummary = ToolOutputSummary.capture(toolName: "file_write", output: writeOutput)
        #expect(writeSummary == .textWithSignals(
            bytes: writeOutput.utf8.count,
            lines: 1,
            signals: [.reportedFileWrite(bytes: writeContent.utf8.count)]
        ))
        let editOutput = try await executor.execute(
            name: "file_edit",
            input: ["path": file.path, "old_string": "alpha", "new_string": "gamma"]
        )
        let editSummary = ToolOutputSummary.capture(toolName: "file_edit", output: editOutput)
        #expect(editSummary == .textWithSignals(
            bytes: editOutput.utf8.count,
            lines: 1,
            signals: [.reportedFileEdit(replacements: 1, bytes: "gamma".utf8.count)]
        ))
        let readOutput = try await executor.execute(name: "file_read", input: ["path": file.path])
        let readSummary = ToolOutputSummary.capture(toolName: "file_read", output: readOutput)
        #expect(readSummary == .text(bytes: readOutput.utf8.count, lines: 2))

        let ledger = try ToolExecutionFactLedger(persistenceURL: url)
        let consumer = ToolLifecycleConsumer()
        for (name, summary) in [("file_write", writeSummary), ("file_edit", editSummary), ("file_read", readSummary)] {
            let receipt = try ledger.mint(
                toolCallID: "\(name)-call",
                toolName: name,
                attemptID: "content-attempt",
                attemptNumber: 1,
                executionIdentity: v2Identity(attempt: 1)
            )
            let fact = try #require(try ledger.settle(
                receipt,
                status: .succeeded,
                outputSummary: summary
            ))
            #expect(await consumer.ingestToolExecutionFact(
                fact,
                eventID: fact.toolCallID,
                eventName: fact.toolName,
                taskID: "content-task",
                expectedAttemptID: fact.attemptID,
                scopeID: "content-scope"
            ))
            #expect(!String(decoding: try JSONEncoder().encode(fact), as: UTF8.self).contains(canary))
        }
        let events = consumer.toolLifecycleEvents
        #expect(events.count == 3)
        #expect(events[0].summary.contains("工具报告写入 \(writeContent.utf8.count) 字节"))
        #expect(events[1].summary.contains("工具报告替换 1 处、写入 5 字节"))
        #expect(events[2].summary.contains("仅显示统计，结果正文未在此展示"))
        #expect(!events[0].summary.contains("仅显示统计"))
        #expect(!events[1].summary.contains("仅显示统计"))
        #expect(!events[2].summary.contains("gamma"))
        #expect(ConversationEventProjection.display(for: events[2]).summary.contains("仅显示统计"))
        #expect(events.allSatisfy { !$0.summary.contains(canary) })
        #expect(ToolOutputSummary.capture(toolName: "other_tool", output: writeOutput)
            == .text(bytes: writeOutput.utf8.count, lines: 1))
    }

    @Test func builtinEditLedgerWarningStaysMetricsOnly() async throws {
        let url = try v2LedgerURL()
        let root = url.deletingLastPathComponent().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let canary = "synthetic-private-warning-value"
        let file = root.appendingPathComponent("\(canary).txt")
        try Data("alpha beta".utf8).write(to: file)
        let executor = BuiltinToolExecutor(allowedRoot: root)
        let output = try await executor.execute(
            name: "file_edit",
            input: ["path": file.path, "old_string": "alpha", "new_string": "gamma"]
        )
        #expect(output == "Edited \(file.path): replaced 1 occurrence(s) (5 bytes written). 文件已写入，但文件变更台账不可用。")
        #expect(try String(contentsOf: file, encoding: .utf8) == "gamma beta")
        let summary = ToolOutputSummary.capture(toolName: "file_edit", output: output)
        #expect(summary == .text(bytes: output.utf8.count, lines: 1))
        #expect(summary.displaySuffix?.contains("仅显示统计，结果正文未在此展示") == true)
        #expect(summary.displaySuffix?.contains(canary) == false)
        #expect(summary.displaySuffix?.contains("gamma") == false)
    }

    @Test func shellDiagnosticsAreClosedSignalsAndUnknownTextStaysMetricsOnly() throws {
        let canary = "synthetic-private-output-value"
        let stdout = "error: \(canary)\nwarning: \(canary)\n✘ Test synthetic failed\n"
        let output = String(decoding: try JSONSerialization.data(withJSONObject: [
            "exit_code": 1, "stdout": stdout, "stderr": ""
        ]), as: UTF8.self)
        let summary = ToolOutputSummary.capture(toolName: "shell_execute", output: output)
        #expect(summary == .shellWithSignals(
            exitCode: 1,
            stdoutBytes: stdout.utf8.count,
            stdoutLines: 3,
            stderrBytes: 0,
            stderrLines: 0,
            signals: [.diagnosticErrors(lines: 1), .diagnosticWarnings(lines: 1), .failedTests(lines: 1)]
        ))
        #expect(summary.displaySuffix?.contains("失败测试 1 行") == true)
        #expect(summary.displaySuffix?.contains("仅显示统计") == false)
        #expect(summary.displaySuffix?.contains(canary) == false)

        let unknown = String(decoding: try JSONSerialization.data(withJSONObject: [
            "exit_code": 0, "stdout": canary, "stderr": ""
        ]), as: UTF8.self)
        let unknownSummary = ToolOutputSummary.capture(toolName: "shell_execute", output: unknown)
        #expect(unknownSummary
            == .shell(exitCode: 0, stdoutBytes: canary.utf8.count, stdoutLines: 1, stderrBytes: 0, stderrLines: 0))
        #expect(unknownSummary.displaySuffix?.contains("仅显示统计，结果正文未在此展示") == true)
        #expect(ToolOutputSummary.capture(toolName: "mcp_synthetic", output: canary)
            .displaySuffix?.contains("仅显示统计，结果正文未在此展示") == true)
    }

    @Test func originalOutputMetricCasesKeepTheirDurableEncoding() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let text = ToolOutputSummary.text(bytes: 7, lines: 1)
        let shell = ToolOutputSummary.shell(
            exitCode: 0, stdoutBytes: 7, stdoutLines: 1, stderrBytes: 0, stderrLines: 0
        )
        let textFixture = #"{"text":{"bytes":7,"lines":1}}"#
        let shellFixture = #"{"shell":{"exitCode":0,"stderrBytes":0,"stderrLines":0,"stdoutBytes":7,"stdoutLines":1}}"#
        #expect(String(decoding: try encoder.encode(text), as: UTF8.self) == textFixture)
        #expect(String(decoding: try encoder.encode(shell), as: UTF8.self) == shellFixture)
        #expect(try JSONDecoder().decode(ToolOutputSummary.self, from: Data(textFixture.utf8)) == text)
        #expect(try JSONDecoder().decode(ToolOutputSummary.self, from: Data(shellFixture.utf8)) == shell)
        #expect(ToolOutputSummary.textWithSignals(bytes: 7, lines: 1, signals: [])
            .displaySuffix?.contains("仅显示统计，结果正文未在此展示") == true)
    }

    @Test func authorizedSessionPageProjectsOnlySafeCountsIntoCanonicalToolEvent() async throws {
        let ledgerURL = try v2LedgerURL()
        let root = ledgerURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let manager = SessionManager(
            store: SessionStore(directory: sessionRoot),
            badgeStore: SessionBadgeStore(directory: sessionRoot)
        )
        let targetID = "synthetic-private-target"
        let canary = "synthetic-private-page-content"
        try manager.store.updateSession(ChatSession(
            id: targetID,
            title: "synthetic-private-title",
            messages: [
                LLMMessage(role: .user, content: canary),
                LLMMessage(role: .assistant, content: "first answer"),
                LLMMessage(role: .user, content: "next page")
            ]
        ))
        let now = Date()
        let authorization = CrossSessionReadAuthorization.issue(
            currentConversationID: "v2-session",
            authorizedSessionID: targetID,
            turnID: 1,
            issuedAt: now,
            lifetime: 60,
            scope: .messages
        )
        let output = try SessionReadTool.read(
            input: ["session_id": targetID, "scope": "messages", "offset": 0, "limit": 2],
            manager: manager,
            authorization: authorization,
            context: SessionReadExecutionContext(currentConversationID: "v2-session", turnID: 1),
            now: now
        )
        #expect(output.contains(canary))
        let summary = ToolOutputSummary.capture(toolName: SessionReadTool.toolName, output: output)
        #expect(summary == .textWithSignals(
            bytes: output.utf8.count,
            lines: 1,
            signals: [.sessionReadPage(messages: 2, total: 3, hasMore: true)]
        ))
        let finalAuthorization = CrossSessionReadAuthorization.issue(
            currentConversationID: "v2-session",
            authorizedSessionID: targetID,
            turnID: 1,
            issuedAt: now,
            lifetime: 60,
            scope: .messages
        )
        let finalOutput = try SessionReadTool.read(
            input: ["session_id": targetID, "scope": "messages", "offset": 2, "limit": 2],
            manager: manager,
            authorization: finalAuthorization,
            context: SessionReadExecutionContext(currentConversationID: "v2-session", turnID: 1),
            now: now
        )
        #expect(ToolOutputSummary.capture(toolName: SessionReadTool.toolName, output: finalOutput)
            == .textWithSignals(
                bytes: finalOutput.utf8.count,
                lines: 1,
                signals: [.sessionReadPage(messages: 1, total: 3, hasMore: false)]
            ))
        let ledger = try ToolExecutionFactLedger(persistenceURL: ledgerURL)
        let receipt = try ledger.mint(
            toolCallID: "session-page-call",
            toolName: SessionReadTool.toolName,
            attemptID: "session-page-attempt",
            attemptNumber: 1,
            executionIdentity: v2Identity(attempt: 1)
        )
        let fact = try #require(try ledger.settle(receipt, status: .succeeded, outputSummary: summary))
        let consumer = ToolLifecycleConsumer()
        #expect(await consumer.ingestToolExecutionFact(
            fact,
            eventID: fact.toolCallID,
            eventName: fact.toolName,
            taskID: "session-page-task",
            expectedAttemptID: fact.attemptID,
            scopeID: "session-page-scope"
        ))
        let event = try #require(consumer.toolLifecycleEvents.first)
        let display = ConversationEventProjection.display(for: event)
        #expect(display.summary.contains("已读取会话消息 2 条，共 3 条；仍有后续页"))
        #expect(!display.summary.contains("仅显示统计"))
        for value in [display.summary, event.summary,
                      String(decoding: try JSONEncoder().encode(fact), as: UTF8.self)] {
            #expect(!value.contains(canary))
            #expect(!value.contains(targetID))
        }

        #expect(ToolOutputSummary.capture(toolName: "mcp_unrelated", output: output)
            == .text(bytes: output.utf8.count, lines: 1))
        var forged = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        forged["tool"] = "mcp_unrelated"
        let forgedOutput = String(decoding: try JSONSerialization.data(withJSONObject: forged), as: UTF8.self)
        #expect(ToolOutputSummary.capture(toolName: SessionReadTool.toolName, output: forgedOutput)
            == .text(bytes: forgedOutput.utf8.count, lines: 1))
    }

    @Test func runOutcomeCarriesCancellationFacts() async throws {
        let url = try v2LedgerURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ledger = try ToolExecutionFactLedger(persistenceURL: url)
        let outcome = await AgentLoop(
            maxIterations: 1,
            approvalGate: v2AutoApproveGate(),
            toolExecutionFactLedger: ledger
        ).runOutcome(
            messages: [],
            systemPrompt: nil,
            provider: V2FactProvider([
                LLMResponse(text: v2Envelope(id: "outcome-cancel"), stopReason: nil, usage: nil),
            ]),
            toolExecutor: V2FactExecutor(.cancelled),
            tools: [v2Tool()],
            executionIdentity: v2Identity(attempt: 1)
        )
        #expect(outcome.result == nil)
        #expect(outcome.failure?.agentError == nil)
        #expect(outcome.toolExecutionFacts.first?.status == .cancelled)
    }

    @Test func runOutcomeCarriesTimeoutFacts() async throws {
        let url = try v2LedgerURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ledger = try ToolExecutionFactLedger(persistenceURL: url)
        let outcome = await AgentLoop(
            maxIterations: 1,
            approvalGate: v2AutoApproveGate(),
            toolExecutionFactLedger: ledger
        ).runOutcome(
            messages: [],
            systemPrompt: nil,
            provider: V2FactProvider([
                LLMResponse(text: v2Envelope(id: "outcome-timeout"), stopReason: nil, usage: nil),
            ]),
            toolExecutor: V2FactExecutor(.timedOut),
            tools: [v2Tool()],
            executionIdentity: v2Identity(attempt: 1)
        )
        #expect(outcome.result == nil)
        #expect(outcome.failure?.agentError == nil)
        #expect(outcome.toolExecutionFacts.first?.status == .failed)
        #expect(outcome.toolExecutionFacts.first?.failureCategory == .timeout)
    }

    @Test func sameToolCallIDAcrossAttemptsAndSessionsMintsIndependentFacts() throws {
        let url = try v2LedgerURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ledger = try ToolExecutionFactLedger(persistenceURL: url)
        let first = try ledger.mint(
            toolCallID: "reused-call",
            toolName: "web_search",
            attemptID: "attempt-a",
            attemptNumber: 1,
            executionIdentity: v4Identity(
                sessionID: "session-a",
                turnID: 1,
                messageID: "message-a",
                operationID: "operation-a",
                attempt: 1
            )
        )
        let second = try ledger.mint(
            toolCallID: "reused-call",
            toolName: "web_search",
            attemptID: "attempt-b",
            attemptNumber: 2,
            executionIdentity: v4Identity(
                sessionID: "session-b",
                turnID: 2,
                messageID: "message-b",
                operationID: "operation-b",
                attempt: 2
            )
        )
        #expect(first.receiptID != second.receiptID)
        _ = try ledger.settle(first, status: .failed)
        _ = try ledger.settle(second, status: .succeeded)
        #expect(ledger.facts.count == 2)
        #expect(Set(ledger.facts.compactMap { $0.compositeKey?.rawValue }).count == 2)
    }

    @Test func sameCompositeDuplicateFailsAndOldReceiptCannotSettleNewAttempt() throws {
        let url = try v2LedgerURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ledger = try ToolExecutionFactLedger(persistenceURL: url)
        let identity = v4Identity(
            sessionID: "session-same",
            turnID: 1,
            messageID: "message-same",
            operationID: "operation-same",
            attempt: 1
        )
        let old = try ledger.mint(
            toolCallID: "same-call",
            toolName: "web_search",
            attemptID: "attempt-same",
            attemptNumber: 1,
            executionIdentity: identity
        )
        #expect(throws: ToolExecutionFactLedgerError.duplicateToolCallID("same-call")) {
            _ = try ledger.mint(
                toolCallID: "same-call",
                toolName: "web_search",
                attemptID: "attempt-same",
                attemptNumber: 1,
                executionIdentity: identity
            )
        }
        _ = try ledger.settle(old, status: .failed)
        let newer = try ledger.mint(
            toolCallID: "same-call",
            toolName: "web_search",
            attemptID: "attempt-new",
            attemptNumber: 2,
            executionIdentity: v4Identity(
                sessionID: "session-same",
                turnID: 1,
                messageID: "message-same",
                operationID: "operation-same",
                attempt: 2
            )
        )
        #expect(try ledger.settle(old, status: .succeeded) == nil)
        #expect(ledger.pendingReceipts == [newer])
    }

    @Test func missingCanonicalIdentityFailsClosed() throws {
        let url = try v2LedgerURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ledger = try ToolExecutionFactLedger(persistenceURL: url)
        #expect(throws: ToolExecutionFactLedgerError.invalidCanonicalIdentity) {
            _ = try ledger.mint(
                toolCallID: "missing-identity",
                toolName: "web_search",
                attemptID: "attempt-1",
                attemptNumber: 1,
                executionIdentity: nil
            )
        }
        #expect(ledger.facts.isEmpty)
        #expect(ledger.pendingReceipts.isEmpty)
    }

    @Test func oldUnscopedLedgerStateFailsClosedOnReload() throws {
        let url = try v2LedgerURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let oldState = #"{"schemaVersion":2,"pending":{},"facts":{},"order":[]}"#
        try Data(oldState.utf8).write(to: url)
        #expect(throws: ToolExecutionFactLedgerError.corruptLedger) {
            _ = try ToolExecutionFactLedger(persistenceURL: url)
        }
    }

    @Test func opaqueCompositeFieldsUseCollisionFreeCanonicalEncoding() throws {
        let url = try v2LedgerURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ledger = try ToolExecutionFactLedger(persistenceURL: url)
        let first = try ledger.mint(
            toolCallID: "call|opaque",
            toolName: "web_search",
            attemptID: "attempt|one",
            attemptNumber: 1,
            executionIdentity: v4Identity(
                sessionID: "session|a",
                turnID: 7,
                messageID: " message|一 ",
                operationID: "operation|a",
                attempt: 1
            )
        )
        let second = try ledger.mint(
            toolCallID: "call|opaque",
            toolName: "web_search",
            attemptID: "attempt|two",
            attemptNumber: 1,
            executionIdentity: v4Identity(
                sessionID: "session|a",
                turnID: 7,
                messageID: " message|一 ",
                operationID: "operation|a",
                attempt: 1
            )
        )
        #expect(first.compositeKey?.rawValue != second.compositeKey?.rawValue)
        #expect(first.receiptID != second.receiptID)
    }

    @Test func emptyCanonicalIdentityFieldFailsClosed() throws {
        let url = try v2LedgerURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ledger = try ToolExecutionFactLedger(persistenceURL: url)
        #expect(throws: ToolExecutionFactLedgerError.invalidCanonicalIdentity) {
            _ = try ledger.mint(
                toolCallID: "empty-session",
                toolName: "web_search",
                attemptID: "attempt-1",
                attemptNumber: 1,
                executionIdentity: v4Identity(
                    sessionID: "",
                    turnID: 1,
                    messageID: "message",
                    operationID: "operation",
                    attempt: 1
                )
            )
        }
    }

    @Test func pendingReceiptReloadNeedsExternalOutcome() throws {
        let url = try v2LedgerURL()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + ".lock")
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        let first = try ToolExecutionFactLedger(persistenceURL: url)
        _ = try first.mint(
            toolCallID: "pending-crash",
            toolName: "web_search",
            attemptID: "attempt-pending",
            attemptNumber: 1,
            executionIdentity: v4Identity(
                sessionID: "session-pending",
                turnID: 1,
                messageID: "message-pending",
                operationID: "operation-pending",
                attempt: 1
            )
        )
        let reloaded = try ToolExecutionFactLedger(persistenceURL: url)
        #expect(throws: ToolExecutionFactLedgerError.externalOutcomeUnverified) {
            try reloaded.reconcilePending()
        }
        #expect(reloaded.pendingReceipts.count == 1 && reloaded.facts.isEmpty)
        let reopened = try ToolExecutionFactLedger(persistenceURL: url)
        #expect(reopened.pendingReceipts == reloaded.pendingReceipts && reopened.facts.isEmpty)
        #expect(throws: ToolExecutionFactLedgerError.duplicateToolCallID("pending-crash")) {
            try reopened.mint(toolCallID: "pending-crash", toolName: "web_search",
                attemptID: "attempt-pending", attemptNumber: 1,
                executionIdentity: v4Identity(sessionID: "session-pending", turnID: 1,
                    messageID: "message-pending", operationID: "operation-pending", attempt: 1))
        }
    }

    @Test func staleWriterCannotMintAfterAnotherLedgerFencesFile() throws {
        let url = try v2LedgerURL()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + ".lock")
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        let stale = try ToolExecutionFactLedger(persistenceURL: url)
        let current = try ToolExecutionFactLedger(persistenceURL: url)
        #expect(throws: ToolExecutionFactLedgerError.staleWriter) {
            _ = try stale.mint(
                toolCallID: "stale-call",
                toolName: "web_search",
                attemptID: "attempt-stale",
                attemptNumber: 1,
                executionIdentity: v4Identity(
                    sessionID: "session-stale",
                    turnID: 1,
                    messageID: "message-stale",
                    operationID: "operation-stale",
                    attempt: 1
                )
            )
        }
        _ = try current.mint(
            toolCallID: "current-call",
            toolName: "web_search",
            attemptID: "attempt-current",
            attemptNumber: 1,
            executionIdentity: v4Identity(
                sessionID: "session-current",
                turnID: 1,
                messageID: "message-current",
                operationID: "operation-current",
                attempt: 1
            )
        )
    }

    @Test func exactExecutionIdentityFilteringExcludesHistoricalAttemptFacts() throws {
        let url = try v2LedgerURL()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + ".lock")
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        let ledger = try ToolExecutionFactLedger(persistenceURL: url)
        let firstIdentity = v4Identity(
            sessionID: "history-session",
            turnID: 1,
            messageID: "message-a",
            operationID: "operation-a",
            attempt: 1
        )
        let secondIdentity = v4Identity(
            sessionID: "history-session",
            turnID: 1,
            messageID: "message-b",
            operationID: "operation-b",
            attempt: 2
        )
        let first = try ledger.mint(
            toolCallID: "history-call",
            toolName: "web_search",
            attemptID: "attempt-a",
            attemptNumber: 1,
            executionIdentity: firstIdentity
        )
        let second = try ledger.mint(
            toolCallID: "history-call",
            toolName: "web_search",
            attemptID: "attempt-b",
            attemptNumber: 2,
            executionIdentity: secondIdentity
        )
        _ = try ledger.settle(first, status: .failed)
        _ = try ledger.settle(second, status: .succeeded)
        #expect(ledger.facts(executionIdentity: firstIdentity, attemptID: "attempt-a", attemptNumber: 1).count == 1)
        #expect(ledger.facts(executionIdentity: secondIdentity, attemptID: "attempt-b", attemptNumber: 2).count == 1)
        #expect(ledger.facts(executionIdentity: firstIdentity, attemptID: "attempt-b", attemptNumber: 2).isEmpty)
    }

    @Test func persistenceFaultOnSettlementIsExplicitAndLeavesNoFakeFact() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToolExecutionFactV6Fault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("facts.json")
        let ledger = try ToolExecutionFactLedger(persistenceURL: url)
        let receipt = try ledger.mint(
            toolCallID: "fault-call",
            toolName: "web_search",
            attemptID: "attempt-fault",
            attemptNumber: 1,
            executionIdentity: v4Identity(
                sessionID: "session-fault",
                turnID: 1,
                messageID: "message-fault",
                operationID: "operation-fault",
                attempt: 1
            )
        )
        try FileManager.default.removeItem(at: root)
        try Data("blocking-file".utf8).write(to: root)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(atPath: url.path + ".lock")
        }
        #expect(throws: ToolExecutionFactLedgerError.persistenceFailed) {
            _ = try ledger.settle(receipt, status: .succeeded)
        }
        #expect(ledger.facts.isEmpty)
        #expect(ledger.pendingReceipts.count == 1)
    }

    @Test func concurrentTakeoverPreservesDurableFactsAndFencesExactlyOneStaleWriter() throws {
        let url = try v2LedgerURL()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + ".lock")
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        let seed = try ToolExecutionFactLedger(persistenceURL: url)
        let seedReceipt = try seed.mint(
            toolCallID: "seed-call",
            toolName: "web_search",
            attemptID: "seed-attempt",
            attemptNumber: 1,
            executionIdentity: v4Identity(
                sessionID: "seed-session",
                turnID: 1,
                messageID: "seed-message",
                operationID: "seed-operation",
                attempt: 1
            )
        )
        _ = try seed.settle(seedReceipt, status: .succeeded)

        let ledgerResults = (0..<2).map { _ in LockedResult<ToolExecutionFactLedger>() }
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            guard let ledger = try? ToolExecutionFactLedger(persistenceURL: url) else {
                return
            }
            ledgerResults[index].store(ledger)
        }
        let ledgers = ledgerResults.compactMap { $0.load() }
        #expect(ledgers.count == 2)

        var successes = 0
        var staleFailures = 0
        for (index, ledger) in ledgers.enumerated() {
            do {
                _ = try ledger.mint(
                    toolCallID: "takeover-\(index)",
                    toolName: "web_search",
                    attemptID: "takeover-attempt-\(index)",
                    attemptNumber: 1,
                    executionIdentity: v4Identity(
                        sessionID: "takeover-session-\(index)",
                        turnID: 1,
                        messageID: "takeover-message-\(index)",
                        operationID: "takeover-operation-\(index)",
                        attempt: 1
                    )
                )
                successes += 1
            } catch ToolExecutionFactLedgerError.staleWriter {
                staleFailures += 1
            }
        }
        #expect(successes == 1)
        #expect(staleFailures == 1)

        let reloaded = try ToolExecutionFactLedger(persistenceURL: url)
        #expect(reloaded.facts.count == 1)
        #expect(reloaded.facts.first?.toolCallID == "seed-call")
        #expect(reloaded.pendingReceipts.count == 1)
    }

    @Test func takeoverDecodePauseHoldsFileLockAndFencesOldWriterAfterRelease() throws {
        let url = try v2LedgerURL()
        let barrier = TakeoverBarrier()
        let oldWriterEnteredBeforeLock = DispatchSemaphore(value: 0)
        let takeoverFinished = DispatchSemaphore(value: 0)
        let oldWriterFinished = DispatchSemaphore(value: 0)
        let takeoverResult = LockedResult<Result<ToolExecutionFactLedger, Error>>()
        let oldWriterResult = LockedResult<Result<ToolExecutionReceipt, Error>>()
        defer {
            ToolExecutionFactLedger.setTakeoverTestHook(for: url, nil)
            ToolExecutionFactLedger.setMintBeforeLockTestHook(for: url, nil)
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + ".lock")
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }

        let oldWriter = try ToolExecutionFactLedger(persistenceURL: url)
        let factReceipt = try oldWriter.mint(
            toolCallID: "takeover-fact",
            toolName: "web_search",
            attemptID: "takeover-fact-attempt",
            attemptNumber: 1,
            executionIdentity: v4Identity(
                sessionID: "takeover-session",
                turnID: 1,
                messageID: "takeover-message",
                operationID: "takeover-operation",
                attempt: 1
            )
        )
        _ = try oldWriter.settle(factReceipt, status: .succeeded)
        _ = try oldWriter.mint(
            toolCallID: "takeover-pending",
            toolName: "web_search",
            attemptID: "takeover-pending-attempt",
            attemptNumber: 1,
            executionIdentity: v4Identity(
                sessionID: "takeover-session",
                turnID: 1,
                messageID: "takeover-message",
                operationID: "takeover-operation",
                attempt: 1
            )
        )

        ToolExecutionFactLedger.setTakeoverTestHook(for: url) {
            barrier.pause()
        }
        ToolExecutionFactLedger.setMintBeforeLockTestHook(for: url) {
            oldWriterEnteredBeforeLock.signal()
        }
        Task.detached {
            do {
                takeoverResult.store(.success(try ToolExecutionFactLedger(persistenceURL: url)))
            } catch {
                takeoverResult.store(.failure(error))
            }
            takeoverFinished.signal()
        }
        #expect(barrier.entered.wait(timeout: .now() + 1) == .success)

        Task.detached {
            do {
                oldWriterResult.store(.success(try oldWriter.mint(
                    toolCallID: "old-writer-call",
                    toolName: "web_search",
                    attemptID: "old-writer-attempt",
                    attemptNumber: 1,
                    executionIdentity: v4Identity(
                        sessionID: "old-writer-session",
                        turnID: 1,
                        messageID: "old-writer-message",
                        operationID: "old-writer-operation",
                        attempt: 1
                    )
                )))
            } catch {
                oldWriterResult.store(.failure(error))
            }
            oldWriterFinished.signal()
        }
        #expect(oldWriterEnteredBeforeLock.wait(timeout: .now() + 1) == .success)
        #expect(oldWriterFinished.wait(timeout: .now() + 0.1) == .timedOut)

        barrier.release.signal()
        #expect(takeoverFinished.wait(timeout: .now() + 1) == .success)
        #expect(oldWriterFinished.wait(timeout: .now() + 1) == .success)
        guard case .failure(let oldWriterError)? = oldWriterResult.load() else {
            Issue.record("old writer must be fenced after takeover")
            return
        }
        #expect((oldWriterError as? ToolExecutionFactLedgerError) == .staleWriter)

        ToolExecutionFactLedger.setTakeoverTestHook(for: url, nil)
        ToolExecutionFactLedger.setMintBeforeLockTestHook(for: url, nil)
        let reloaded = try ToolExecutionFactLedger(persistenceURL: url)
        #expect(reloaded.facts.map(\.toolCallID) == ["takeover-fact"])
        #expect(reloaded.pendingReceipts.map(\.toolCallID) == ["takeover-pending"])
    }
}

private struct V2DenyDelegate: ApprovalDelegate {
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        .deny
    }
}
