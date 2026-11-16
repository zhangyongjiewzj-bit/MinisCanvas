import Foundation
import Testing
@testable import MinisCore

@Suite("R2-W18 cancellation and attempt identity")
struct R2W18CancellationIdentityTests {
    @Test("production settlement uses the canonical attempt and one terminal event")
    func productionSettlementUsesCanonicalAttemptIdentity() async throws {
        let store = AgentTaskStore()
        let provider = R2W18ImmediateSuccessProvider()
        let controller = TurnController()
        let parentTurn = await controller.beginTurn()

        let orchestrator = makeProductionOrchestrator(
            provider: provider,
            store: store,
            parentTurn: parentTurn
        )
        let reports = await orchestrator.orchestrate(
            tasks: [
                SubAgentTask(
                    id: "r2-w18-production-success",
                    title: "production success",
                    instructions: "complete"
                )
            ],
            strategy: .sequential
        )
        await parentTurn.finish()

        let receipt = try #require(store.allReceipts().first)
        let canonicalAttemptID = try #require(
            store.canonicalAttemptID(runID: receipt.runID)
        )
        let events = store.events(runID: receipt.runID)
        let terminalEvents = events.filter { event in
            event.kind == .completed
                || event.kind == .failed
                || event.kind == .cancelled
        }

        #expect(reports.first?.result.isSuccess == true)
        #expect(receipt.outcome == .succeeded)
        #expect(receipt.attemptID == canonicalAttemptID)
        #expect(events.map(\.kind) == [.started, .progress, .completed])
        #expect(terminalEvents.count == 1)
        #expect(terminalEvents.first?.kind == .completed)
    }

    @Test("production cancel wins against a late provider success")
    func productionCancelVsLateProviderSuccessHasOneTerminal() async throws {
        let store = AgentTaskStore()
        let gate = R2W18LateSuccessGate()
        let provider = R2W18LateSuccessProvider(gate: gate)
        let controller = TurnController()
        let parentTurn = await controller.beginTurn()
        let orchestrator = makeProductionOrchestrator(
            provider: provider,
            store: store,
            parentTurn: parentTurn
        )
        let operation = Task {
            await orchestrator.orchestrate(
                tasks: [
                    SubAgentTask(
                        id: "r2-w18-production-cancel",
                        title: "production cancellation",
                        instructions: "wait for cancellation"
                    )
                ],
                strategy: .sequential
            )
        }

        #expect(await gate.waitUntilStarted())
        await parentTurn.interrupt()
        #expect(await gate.waitUntilChildCancellation())
        await gate.releaseLateSuccess()

        let reports = await operation.value
        let receipt = try #require(store.allReceipts().first)
        let receiptBeforeLateWriteback = receipt
        let eventsBeforeLateWriteback = store.events(runID: receipt.runID)
        let canonicalAttemptID = try #require(
            store.canonicalAttemptID(runID: receipt.runID)
        )

        #expect(reports.count == 1)
        #expect(reports.first?.result == .failed(error: "任务已取消"))
        #expect(receipt.outcome == .cancelled)
        #expect(receipt.attemptID == canonicalAttemptID)
        #expect(eventsBeforeLateWriteback.map(\.kind) == [
            .started,
            .progress,
            .cancelled,
        ])
        #expect(eventsBeforeLateWriteback.filter { event in
            event.kind == .completed
                || event.kind == .failed
                || event.kind == .cancelled
        }.count == 1)

        let lateReceipt = try store.finish(
            runID: receipt.runID,
            eventKind: .completed,
            detail: "late-success",
            outcome: .succeeded
        )
        let eventsAfterLateWriteback = store.events(runID: receipt.runID)
        let terminalEvents = eventsAfterLateWriteback.filter { event in
            event.kind == .completed
                || event.kind == .failed
                || event.kind == .cancelled
        }

        #expect(lateReceipt == receiptBeforeLateWriteback)
        #expect(store.allReceipts() == [receiptBeforeLateWriteback])
        #expect(eventsAfterLateWriteback.map(\.kind) == [
            .started,
            .progress,
            .cancelled,
        ])
        #expect(terminalEvents.count == 1)
        #expect(terminalEvents.first?.kind == .cancelled)

        await parentTurn.finish()
    }

    @Test("cancel and success writeback form one terminal decision")
    func cancelVsSuccessWritebackIsAtomic() async throws {
        let supervisor = ChildSupervisor(
            childID: "r2-w18-child",
            attemptID: "r2-w18-run:attempt:1"
        )
        let started = try await supervisor.start()

        let decisions = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            group.addTask {
                (try? await supervisor.cancelIfRunning(attemptID: started.attemptID)) == true
            }
            group.addTask {
                (try? await supervisor.settleSuccess(
                    attemptID: started.attemptID,
                    sequence: 1
                )) == true
            }

            var results: [Bool] = []
            for await result in group {
                results.append(result)
            }
            return results
        }

        #expect(decisions.filter { $0 }.count == 1)
        let snapshot = try #require(await supervisor.snapshot())
        if decisions.contains(true) {
            if snapshot.status == .succeeded {
                #expect(snapshot.sequence == 1)
            } else {
                #expect(snapshot.status == .cancelled)
                #expect(snapshot.sequence == 0)
            }
        }
    }

    @Test("ChildSupervisor uses the task store canonical attempt identity")
    func supervisorAndTaskStoreShareCanonicalAttemptID() async throws {
        let store = AgentTaskStore()
        _ = try store.enqueue(
            taskID: "r2-w18-task",
            parentID: "r2-w18-parent",
            providerID: nil,
            modelID: nil
        )
        let run = try store.startRun(
            taskID: "r2-w18-task",
            parentID: "r2-w18-parent",
            runID: "r2-w18-run"
        )
        let canonicalAttemptID = try #require(store.canonicalAttemptID(runID: run.runID))
        let supervisor = ChildSupervisor(
            childID: "r2-w18-task",
            attemptID: canonicalAttemptID
        )
        let started = try await supervisor.start()

        #expect(started.attemptID == canonicalAttemptID)
        #expect(started.attemptID == store.attempts(runID: run.runID).first?.attemptID)
    }

    @Test("late and duplicate terminal signals leave an auditable marker")
    func lateAndDuplicateTerminalSignalsAreMarkedWithoutChangingReceipt() throws {
        let store = AgentTaskStore()
        _ = try store.enqueue(
            taskID: "r2-w18-terminal",
            parentID: "r2-w18-parent",
            providerID: nil,
            modelID: nil
        )
        _ = try store.startRun(
            taskID: "r2-w18-terminal",
            parentID: "r2-w18-parent",
            runID: "r2-w18-run"
        )

        let first = try store.finish(
            runID: "r2-w18-run",
            eventKind: .cancelled,
            detail: "cancelled",
            outcome: .cancelled
        )
        let duplicate = try store.finish(
            runID: "r2-w18-run",
            eventKind: .completed,
            detail: "late-success",
            outcome: .succeeded
        )
        #expect(duplicate == first)
        #expect(throws: AgentTaskStoreError.runClosed) {
            _ = try store.appendEvent(
                runID: "r2-w18-run",
                kind: .completed,
                detail: "late-success"
            )
        }
        #expect(store.allReceipts() == [first])
        #expect(store.events(runID: "r2-w18-run").map(\.kind) == [
            .cancelled
        ])
    }
}

private func makeProductionOrchestrator(
    provider: any LLMProvider,
    store: AgentTaskStore,
    parentTurn: TurnController.TurnHandle
) -> AgentOrchestrator {
    AgentOrchestrator(
        provider: provider,
        toolExecutor: R2W18NoopToolExecutor(),
        currentConversationID: "r2-w18-conversation",
        taskStore: store,
        parentID: "r2-w18-parent",
        parentBinding: ParentContextSnapshotV1(
            providerID: provider.name,
            modelID: provider.model.id,
            configurationFingerprint: "r2-w18-fingerprint",
            conversationID: "r2-w18-conversation"
        ),
        parentRuntimeIdentity: ParentRuntimeIdentity(
            sessionID: "r2-w18-session",
            conversationID: "r2-w18-conversation",
            turnID: "turn-handle:\(parentTurn.turnID)",
            taskID: "r2-w18-parent",
            actorID: "r2-w18-test"
        ),
        parentTurnHandle: parentTurn,
        runtimeMode: .production,
        capabilityPolicy: AgentCapabilityPolicy(
            allowedCapabilities: [.streaming],
            allowedToolNames: [],
            allowedMCPToolNames: []
        ),
        parentCapabilities: provider.capabilities
    )
}

private struct R2W18NoopToolExecutor: ToolExecutor {
    func execute(name: String, input: [String: Any]) async throws -> String {
        "ok"
    }
}

private final class R2W18ImmediateSuccessProvider: LLMProvider, @unchecked Sendable {
    let name = "r2-w18-immediate"
    var model = LLMModel(
        id: "r2-w18-immediate-model",
        displayName: "R2-W18 immediate",
        provider: "r2-w18"
    )
    let capabilities: Set<ProviderCapability> = [.streaming]

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        LLMResponse(text: "complete", stopReason: "stop", usage: nil)
    }

    func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

private actor R2W18LateSuccessGate {
    private var started = false
    private var childCancellationObserved = false
    private var released = false

    func markStarted() {
        started = true
    }

    func markChildCancellation() {
        childCancellationObserved = true
    }

    func waitUntilStarted() async -> Bool {
        for _ in 0..<5_000 {
            if started { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return started
    }

    func waitUntilChildCancellation() async -> Bool {
        for _ in 0..<5_000 {
            if childCancellationObserved { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return childCancellationObserved
    }

    func waitForRelease() async {
        while !released {
            await Task.yield()
        }
    }

    func releaseLateSuccess() {
        released = true
    }
}

private final class R2W18LateSuccessProvider: LLMProvider, @unchecked Sendable {
    let name = "r2-w18-late"
    var model = LLMModel(
        id: "r2-w18-late-model",
        displayName: "R2-W18 late",
        provider: "r2-w18"
    )
    let capabilities: Set<ProviderCapability> = [.streaming]
    private let gate: R2W18LateSuccessGate

    init(gate: R2W18LateSuccessGate) {
        self.gate = gate
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        await gate.markStarted()
        return await withTaskCancellationHandler(operation: {
            await gate.waitForRelease()
            return LLMResponse(text: "late success", stopReason: "stop", usage: nil)
        }, onCancel: {
            Task {
                await gate.markChildCancellation()
            }
        })
    }

    func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}
