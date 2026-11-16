import Foundation
import Dispatch
import Testing
import MinisCore
@testable import MinisCanvasApp

// Hold only the synthetic tracker executor at the production terminal read's
// actor hop. No timer race, network, or alternate budget implementation.
private final class BudgetReadGate2036: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func waitUntilEntered() -> Bool {
        entered.wait(timeout: .now() + 5) == .success
    }
}
extension BudgetTracker {
    fileprivate func holdSnapshotQueue2036(_ gate: BudgetReadGate2036) {
        gate.entered.signal()
        _ = gate.release.wait(timeout: .now() + 10)
    }
}

@Suite("D-CHAT-16 terminal budget snapshot generation")
@MainActor
struct BudgetSnapshotGeneration2036Tests {
    private func chat() -> ChatStore {
        let chat = ChatStore()
        chat.applyNewSession(title: "synthetic budget generation")
        // 本套件按 10 万上限断言警告/超限：显式钉 10 万（默认值已改为 100 万）。
        var settings = AgentSettings.default
        settings.maxTokensPerSession = 100_000
        chat.configureBudget(from: settings)
        return chat
    }
    private func settle(_ tracker: BudgetTracker, input: Int) async throws {
        let lease = try await tracker.beginRequest()
        _ = await tracker.completeRequest(lease, usage: LLMUsage(inputTokens: input, outputTokens: 0))
    }
    private func hold(_ tracker: BudgetTracker, gate: BudgetReadGate2036) async throws -> Task<Void, Never> {
        let blocker = Task.detached { await tracker.holdSnapshotQueue2036(gate) }
        let entered = await Task.detached { gate.waitUntilEntered() }.value
        try #require(entered, "tracker queue must be held before the production read starts")
        return blocker
    }

    @Test func currentTrackerCommitsOneRequestAndNearThenExhaustedStates() async throws {
        let chat = chat()
        let tracker = chat.budgetTracker
        let lease = try await tracker.beginRequest()
        let usage = LLMUsage(inputTokens: 70_000, outputTokens: 10_000)
        _ = await tracker.completeRequest(lease, usage: usage)
        _ = await tracker.completeRequest(lease, usage: usage)
        await chat.syncBudgetStatus(for: chat.activeSessionID)
        #expect(chat.budgetRequestCount == 1 && chat.budgetUsedTokens == 80_000)
        #expect(chat.budgetIsWarning && !chat.budgetIsOverLimit)
        #expect(chat.requestBudget.tokensRemaining == 20_000)
        try await settle(tracker, input: 20_000)
        await chat.syncBudgetStatus(for: chat.activeSessionID)
        #expect(chat.budgetRequestCount == 2 && chat.budgetUsedTokens == 100_000)
        #expect(!chat.budgetIsWarning && chat.budgetIsOverLimit)
        #expect(chat.requestBudget.tokensRemaining == 0)
    }

    @Test func delayedSnapshotCannotOverwriteReconfiguredBudget() async throws {
        let chat = chat()
        let oldTracker = chat.budgetTracker
        try await settle(oldTracker, input: 90_000)
        let gate = BudgetReadGate2036()
        let blocker = try await hold(oldTracker, gate: gate)
        defer { gate.release.signal() }
        var readStarted = false
        let read = Task { @MainActor in
            readStarted = true
            await chat.syncBudgetStatus(for: chat.activeSessionID)
        }
        while !readStarted { await Task.yield() }
        var settings = AgentSettings.default
        settings.autoCompactThreshold = 0.3
        settings.maxTokensPerSession = 100_000
        chat.configureBudget(from: settings)
        let currentTracker = chat.budgetTracker
        #expect(currentTracker !== oldTracker)
        gate.release.signal()
        await blocker.value
        await read.value
        #expect(chat.budgetRequestCount == 0 && chat.budgetUsedTokens == 0)
        #expect(!chat.budgetIsWarning && !chat.budgetIsOverLimit)
        #expect(chat.warningFraction == 0.3)
        #expect(await currentTracker.budget.usedRequests == chat.budgetRequestCount)
    }

    @Test func delayedSnapshotCannotOverwriteNewSession() async throws {
        let chat = chat()
        let oldSession = chat.activeSessionID
        let oldTracker = chat.budgetTracker
        try await settle(oldTracker, input: 100_000)
        let gate = BudgetReadGate2036()
        let blocker = try await hold(oldTracker, gate: gate)
        defer { gate.release.signal() }
        var readStarted = false
        let read = Task { @MainActor in
            readStarted = true
            await chat.syncBudgetStatus(for: oldSession)
        }
        while !readStarted { await Task.yield() }
        chat.applyNewSession(title: "synthetic replacement session")
        #expect(chat.activeSessionID != oldSession)
        gate.release.signal()
        await blocker.value
        await read.value
        #expect(chat.budgetRequestCount == 0 && chat.budgetUsedTokens == 0)
        #expect(!chat.budgetIsWarning && !chat.budgetIsOverLimit)
        #expect(await chat.budgetTracker.budget.usedRequests == chat.budgetRequestCount)
    }

    @Test func failedReservationKeepsCurrentDisplayAvailableAndUncharged() async throws {
        let chat = chat()
        let tracker = chat.budgetTracker
        let failed = try await tracker.beginRequest()
        await tracker.failRequest(failed)
        await chat.syncBudgetStatus(for: chat.activeSessionID)
        #expect(chat.budgetRequestCount == 0 && chat.budgetUsedTokens == 0)
        #expect(!chat.budgetIsWarning && !chat.budgetIsOverLimit)
        #expect(await tracker.pendingRequestCount == 0)
    }
}
