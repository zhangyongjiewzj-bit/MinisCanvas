import Foundation
import os
import Testing
import MinisCore
@testable import MinisCanvasApp

private struct M02ApprovalRecoveryProvider: LLMProvider, Sendable {
    let name = "SyntheticApprovalRecovery"
    var model = LLMModel(
        id: "synthetic-approval-recovery", displayName: "Synthetic Approval Recovery",
        provider: "SyntheticApprovalRecovery"
    )
    var capabilities: Set<ProviderCapability> { [.streaming] }

    nonisolated(nonsending) func sendMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> LLMResponse {
        LLMResponse(text: "B 已响应", stopReason: "end_turn", usage: nil)
    }

    nonisolated(nonsending) func streamMessage(
        messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.started)
            continuation.yield(.text("B 已响应"))
            continuation.yield(.finished(stopReason: "end_turn"))
            continuation.finish()
        }
    }
}

private enum M02ApprovalRecoveryFixtureError: Error { case unexpectedLegacyEntry }

@MainActor
private final class M02HeldApprovalStreamEngine: ChatAgentEngine {
    nonisolated var isAvailable: Bool { true }
    private(set) var continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation?

    nonisolated(nonsending) func streamReply(
        provider: any LLMProvider, history: [ChatMessageUI],
        systemPrompt: String, maxTokens: Int
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        throw M02ApprovalRecoveryFixtureError.unexpectedLegacyEntry
    }

    func streamReply(
        provider: any LLMProvider, history: [ChatMessageUI],
        systemPrompt: String, maxTokens: Int, conversationID: String?,
        authorizedSessionReadSessionID: String?,
        authorizedSessionReadScope: SessionReadScope?, turnID: Int?,
        composerSnapshot: ComposerSubmissionSnapshot,
        executionIdentity: AgentExecutionIdentity
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        let pair = AsyncThrowingStream<AgentStreamEvent, Error>.makeStream()
        continuation = pair.continuation
        return pair.stream
    }

    nonisolated func interrupt() {}

    nonisolated(nonsending) func compactContext(
        provider: any LLMProvider, history: [ChatMessageUI],
        systemPrompt: String, keepRecent: Int
    ) async -> CompactionResult {
        CompactionResult(messages: [], summary: nil, compactedCount: 0)
    }
}

@Suite("D-TOOL-16/17 recovered approval barrier isolates only old waiting rows")
@MainActor
struct P3AcceptanceM02_ApprovalRecoveryBarrierTests {
    private func isolatedChat(_ label: String) -> (chat: ChatStore, root: URL, suite: String) {
        let suite = "M02-approval-recovery-\(label)-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        let defaults = UserDefaults(suiteName: suite)!
        let chat = ChatStore(
            preferencesDefaults: defaults,
            logManager: LogManager(directory: root.appendingPathComponent("logs", isDirectory: true))
        )
        chat.streamingProviderOverride = M02ApprovalRecoveryProvider()
        return (chat, root, suite)
    }

    private func cleanup(_ fixture: (chat: ChatStore, root: URL, suite: String)) {
        fixture.chat.stopAllStreamingForSafety()
        UserDefaults(suiteName: fixture.suite)?.removePersistentDomain(forName: fixture.suite)
        try? FileManager.default.removeItem(at: fixture.root)
    }

    private func request(sessionID: String = "session-A", secondStep: Bool = false, execution: AgentExecutionIdentity? = nil) -> ApprovalRequest {
        ApprovalRequest(
            id: "call-A", requestID: "approval-A", callID: "call-A",
            toolName: "file_read", inputSummary: "synthetic input",
            riskLevel: .high, requiresApproval: true, requiresSecondConfirmation: secondStep,
            sessionID: sessionID, turnID: execution?.turn.turnID ?? 1, taskID: "task-A",
            attemptID: "attempt-A", approvalScope: "scope-A",
            composerMode: "manual", messageID: execution?.turn.messageID ?? "message-A",
            identityDigest: "digest-A", expiresAt: Date().addingTimeInterval(120)
        )
    }

    private func context(
        sessionID: String = "session-A", execution supplied: AgentExecutionIdentity? = nil, sink: @escaping @Sendable (ApprovalLifecycleFact) -> Void
    ) -> ApprovalPresentationContext {
        let turn = AgentTurnIdentity(sessionID: sessionID, turnID: 1, messageID: "message-A")
        let execution = supplied ?? AgentExecutionIdentity(turn: turn, operationID: "operation-A", attempt: 1)
        let key = ToolExecutionCompositeKey(
            sessionID: sessionID, turnID: execution.turn.turnID, messageID: execution.turn.messageID,
            operationID: execution.operationID, attemptID: "attempt-A",
            attemptNumber: execution.attempt, toolCallID: "call-A"
        )
        return ApprovalPresentationContext(
            compositeKey: key, executionIdentity: execution,
            toolName: "file_read", eventSink: sink
        )
    }

    private func fact() throws -> ApprovalLifecycleFact {
        try #require(context(sink: { _ in }).makeFact(for: request(), stage: .presented))
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<150 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }

    @Test("real second confirmation derives review only for its canonical waiting session")
    func liveSecondStepProjectsWithoutChangingTheJournalContract() async throws {
        let fixture = isolatedChat("live-review")
        defer { cleanup(fixture) }
        let chat = fixture.chat
        let sessionID = chat.applyNewSession(title: "review source")
        try chat.attachToolLifecyclePersistence(fixture.root.appendingPathComponent("events.json"))
        let consumer = try await chat.awaitApprovalRecovery()
        let engine = M02HeldApprovalStreamEngine()
        chat.agentEngine = engine
        chat.draftText = "hold the real execution while approval is pending"
        chat.sendDraft()
        #expect(await waitUntil { engine.continuation != nil && chat.executionSnapshot(forSessionID: sessionID)?.executionIdentity != nil })
        let execution = try #require(chat.executionSnapshot(forSessionID: sessionID)?.executionIdentity)
        let recorder = OSAllocatedUnfairLock(initialState: [ApprovalLifecycleFact]())
        let center = ApprovalPromptCenter()
        let requested = request(sessionID: sessionID.uuidString, secondStep: true, execution: execution)
        let scoped = context(sessionID: sessionID.uuidString, execution: execution) { fact in recorder.withLock { $0.append(fact) } }
        let pending = Task { await ApprovalPresentationContext.$current.withValue(scoped) { await center.present(requested) } }
        #expect(await waitUntil { center.pendingRequest != nil })
        let presented = try #require(recorder.withLock { $0.first })
        #expect(await chat.ingestApprovalLifecycleFact(presented, expectedExecutionIdentity: presented.executionIdentity,
            expectedAttemptID: presented.compositeKey.attemptID, expectedConsumer: consumer))
        #expect(chat.sessionRuntimeStatus(for: sessionID, approvalCenter: center) == .waitingApproval)
        #expect(chat.sessionRuntimeReviewReason(for: sessionID, approvalCenter: center) == nil)
        center.approvePending()
        #expect(center.awaitingConfirmation)
        #expect(chat.sessionRuntimeStatus(for: sessionID, approvalCenter: center) == .needsReview)
        #expect(chat.sessionRuntimeReviewReason(for: sessionID, approvalCenter: center) == ApprovalReviewPresentation.explanation)
        #expect(chat.sessionRuntimeStatus(for: UUID(), approvalCenter: center) == nil)
        #expect(chat.sessionRuntimeStatus(for: sessionID, approvalCenter: ApprovalPromptCenter()) == .waitingApproval)
        // The old live card must not upgrade another attempt/operation of the
        // same session and turn, nor an execution without a canonical identity.
        let replacements: [AgentExecutionIdentity?] = [
            AgentExecutionIdentity(turn: execution.turn, operationID: execution.operationID, attempt: execution.attempt + 1),
            AgentExecutionIdentity(turn: execution.turn, operationID: "another-operation", attempt: execution.attempt),
            nil
        ]
        for replacement in replacements {
            let current = ChatStore.ExecutionSnapshot(sessionID: sessionID, turnID: execution.turn.turnID,
                state: .running, executionIdentity: replacement)
            #expect(SessionRuntimeStatus.project(sessionID: sessionID, execution: current,
                events: consumer.readOnlyProjection.events, liveReview: center.liveReviewPresentation) != .needsReview)
            #expect(SessionRuntimeStatus.reviewExplanation(sessionID: sessionID, execution: current,
                events: consumer.readOnlyProjection.events, terminalOutcome: nil, liveReview: center.liveReviewPresentation) == nil)
        }
        #expect(consumer.readOnlyProjection.approvalHistory.allSatisfy { $0.status == .waiting })
        #expect(recorder.withLock { $0.count } == 1)
        center.confirmPending()
        let decision = await pending.value
        #expect(decision.approved && decision.confirmed)
        #expect(center.liveReviewPresentation == nil)
        #expect(chat.sessionRuntimeStatus(for: sessionID, approvalCenter: center) == .waitingApproval)
        let settled = try #require(scoped.makeFact(for: requested, stage: .authorityApproved))
        #expect(await chat.ingestApprovalLifecycleFact(settled, expectedExecutionIdentity: settled.executionIdentity,
            expectedAttemptID: settled.compositeKey.attemptID, expectedConsumer: consumer))
        #expect(chat.sessionRuntimeStatus(for: sessionID, approvalCenter: center) == .running)
        #expect(chat.sessionRuntimeReviewReason(for: sessionID, approvalCenter: center) == nil)
    }

    @Test("review remains an existing waiting record on disk and cold recovery interrupts its exact identity")
    func coldReviewUsesTheOriginalWaitingSchema() async throws {
        let fixture = isolatedChat("cold-review")
        defer { cleanup(fixture) }
        let chat = fixture.chat
        let sessionID = chat.applyNewSession(title: "review source")
        let path = fixture.root.appendingPathComponent("events.json")
        try chat.attachToolLifecyclePersistence(path)
        let consumer = try await chat.awaitApprovalRecovery()
        let recorder = OSAllocatedUnfairLock(initialState: [ApprovalLifecycleFact]())
        let center = ApprovalPromptCenter()
        let requested = request(sessionID: sessionID.uuidString, secondStep: true)
        let scoped = context(sessionID: sessionID.uuidString) { fact in recorder.withLock { $0.append(fact) } }
        let pending = Task { await ApprovalPresentationContext.$current.withValue(scoped) { await center.present(requested) } }
        #expect(await waitUntil { center.pendingRequest != nil })
        let presented = try #require(recorder.withLock { $0.first })
        #expect(await consumer.ingestApprovalLifecycleFact(presented))
        center.approvePending()
        #expect(center.liveReviewPresentation != nil)
        let cold = try ToolLifecycleConsumer(persistenceURL: path)
        #expect(cold.readOnlyProjection.approvalHistory.first?.status == .waiting)
        #expect(SessionRuntimeStatus.project(sessionID: sessionID, execution: nil,
            events: cold.readOnlyProjection.events, liveReview: ApprovalPromptCenter().liveReviewPresentation) == .waitingApproval)
        #expect(await cold.invalidateRecoveredApprovalWaiting() == 1)
        let restored = try ToolLifecycleConsumer(persistenceURL: path)
        let stopped = try #require(restored.readOnlyProjection.approvalHistory.first)
        #expect(stopped.status == .stopped && stopped.approvalDecision == .interrupted)
        #expect(stopped.approvalCompositeKey == presented.compositeKey)
        #expect(stopped.approvalIdentityDigest == presented.identityDigest)
        #expect(SessionRuntimeStatus.project(sessionID: sessionID, execution: nil, events: restored.readOnlyProjection.events) == .interrupted)
        center.stopGeneration()
        _ = await pending.value
        #expect(center.liveReviewPresentation == nil)
    }

    enum ReviewEnd: CaseIterable, Sendable { case dismiss, stop, expiry, cancellation }

    @Test(arguments: ReviewEnd.allCases)
    func everyExistingWaiterEndClearsLiveReview(_ ending: ReviewEnd) async throws {
        let center = ApprovalPromptCenter()
        let scoped = context(sink: { _ in })
        let pending = Task { await ApprovalPresentationContext.$current.withValue(scoped) { await center.present(request(secondStep: true)) } }
        #expect(await waitUntil { center.pendingRequest != nil })
        center.approvePending()
        #expect(center.liveReviewPresentation != nil)
        let staleActions = center.actionsForPresentedRequest()
        switch ending {
        case .dismiss: center.dismissPending()
        case .stop: center.stopGeneration()
        case .expiry: center.expirePending()
        case .cancellation: pending.cancel()
        }
        _ = await pending.value
        #expect(center.liveReviewPresentation == nil)
        staleActions.approve()
        #expect(center.liveReviewPresentation == nil)
    }

    @Test("a live approval in session A does not block an unrelated B turn")
    func liveWaitingDoesNotBlockOtherSession() async throws {
        let fixture = isolatedChat("live")
        defer { cleanup(fixture) }
        let chat = fixture.chat
        try chat.attachToolLifecyclePersistence(fixture.root.appendingPathComponent("events.json"))
        let consumer = try await chat.awaitApprovalRecovery()
        let facts = OSAllocatedUnfairLock(initialState: [ApprovalLifecycleFact]())
        let center = ApprovalPromptCenter()
        let pending = Task {
            await ApprovalPresentationContext.$current.withValue(context { fact in
                facts.withLock { $0.append(fact) }
            }) {
                await center.present(request())
            }
        }
        let pendingVisible = await waitUntil { center.pendingRequest != nil }
        #expect(pendingVisible)
        let presented = try #require(facts.withLock { $0.first })
        let recorded = await chat.ingestApprovalLifecycleFact(
            presented, expectedExecutionIdentity: presented.executionIdentity,
            expectedAttemptID: presented.compositeKey.attemptID,
            expectedConsumer: consumer
        )
        #expect(recorded)
        #expect(consumer.readOnlyProjection.approvalHistory.contains { $0.status == .waiting })

        // This actually starts B's ordinary stream while A's UI remains pending.
        _ = chat.applyNewSession(title: "B")
        chat.agentEngine = ComposerSnapshotMockChatEngine()
        chat.draftText = "B 的合成消息"
        chat.sendDraft()
        let bResponded = await waitUntil {
            chat.messages.contains { $0.role == .assistant && $0.content.contains("B 已响应") }
        }
        #expect(bResponded)
        #expect(center.pendingRequest != nil)
        center.dismissPending()
        _ = await pending.value
    }

    @Test("a recovered waiting row whose interruption cannot persist blocks visibly")
    func failedRecoveryBlocksNewTurnWithVisibleError() async throws {
        let fixture = isolatedChat("failed")
        defer { cleanup(fixture) }
        let chat = fixture.chat
        let snapshot = fixture.root.appendingPathComponent("events.json")
        let seed = try ToolLifecycleConsumer(persistenceURL: snapshot, compactionInterval: 1)
        let seedRecorded = await seed.ingestApprovalLifecycleFact(try fact())
        #expect(seedRecorded)
        let journal = snapshot.deletingPathExtension().appendingPathExtension("journal")
        try FileManager.default.removeItem(at: journal)

        // attach is synchronous on MainActor: the registered recovery Task
        // cannot run before this synthetic directory occupies its journal path.
        try chat.attachToolLifecyclePersistence(snapshot)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: false)
        do {
            _ = try await chat.awaitApprovalRecovery()
            Issue.record("unpersisted recovery must not open a new turn")
        } catch {
            #expect(error.localizedDescription.contains("历史审批尚未安全清算"))
        }
        chat.agentEngine = ComposerSnapshotMockChatEngine()
        chat.draftText = "不得送出的 B 消息"
        chat.sendDraft()
        let visibleFailure = await waitUntil {
            chat.messages.contains {
                $0.role == .assistant && $0.content.contains("历史审批尚未安全清算")
            }
        }
        #expect(visibleFailure)
        #expect(!chat.messages.contains {
            $0.role == .assistant && $0.content.contains("B 已响应")
        })
    }

    @Test("replacing the durable consumer fails the old stream closed")
    func consumerReplacementClosesOldStream() async throws {
        let fixture = isolatedChat("replace")
        defer { cleanup(fixture) }
        let chat = fixture.chat
        try chat.attachToolLifecyclePersistence(fixture.root.appendingPathComponent("first.json"))
        _ = try await chat.awaitApprovalRecovery()
        let engine = M02HeldApprovalStreamEngine()
        chat.agentEngine = engine
        chat.draftText = "旧流"
        chat.sendDraft()
        let streamOpened = await waitUntil { engine.continuation != nil }
        #expect(streamOpened)

        try chat.attachToolLifecyclePersistence(fixture.root.appendingPathComponent("second.json"))
        engine.continuation?.yield(.textDelta("旧 consumer 的迟到内容"))
        engine.continuation?.finish()
        let oldTurnFailed = await waitUntil {
            chat.messages.contains {
                $0.role == .assistant && $0.content.contains("审批记录已切换")
            }
        }
        #expect(oldTurnFailed)
        #expect(!chat.messages.contains {
            $0.role == .assistant && $0.content.contains("旧 consumer 的迟到内容")
        })
    }
}
