import Foundation
import Testing
@testable import MinisCore

// Depends on C-L1: LLMUsage.totalInputTokens.
struct ChildUsageChargesParentC5Tests {
    private func locator(_ run: String) -> ChildTranscriptLocator {
        ChildTranscriptLocator(
            childSessionID: "child-\(run)", parentSessionID: "parent", taskID: "task-\(run)",
            parentID: "parent-task", runID: run, attemptID: "attempt-\(run)",
            childExecutionID: "exec-\(run)", parentContextSnapshotID: nil)
    }

    private let usage = ChildResultTokenUsage(inputTokens: 2_000, outputTokens: 3_000, reportedCallCount: 2, totalInputTokens: 12_000)

    @Test func settledChildTokensUseTotalInputAndDoNotCountARequest() async {
        let parent = BudgetTracker(RequestBudget(maxTokensPerSession: 100_000, overBudgetPolicy: .pause))
        let generation = await parent.childUsageGeneration
        await parent.recordSettledChildUsage(usage, locator: locator("r1"), sourceGeneration: generation)
        let budget = await parent.budget
        #expect(budget.usedTokens == 15_000)
        #expect(budget.usedRequests == 0)
    }

    @Test func aChildWithoutTotalInputFallsBackToInputTokens() async {
        let parent = BudgetTracker(RequestBudget(maxTokensPerSession: 100_000))
        let old = ChildResultTokenUsage(inputTokens: 2_000, outputTokens: 3_000, reportedCallCount: 1)
        await parent.recordSettledChildUsage(old, locator: locator("r1"), sourceGeneration: await parent.childUsageGeneration)
        #expect(await parent.budget.usedTokens == 5_000)
    }

    @Test func replayedSettlementDoesNotChargeTwice() async {
        let parent = BudgetTracker(RequestBudget(maxTokensPerSession: 100_000))
        let generation = await parent.childUsageGeneration
        await parent.recordSettledChildUsage(usage, locator: locator("r1"), sourceGeneration: generation)
        await parent.recordSettledChildUsage(usage, locator: locator("r1"), sourceGeneration: generation)
        #expect(await parent.budget.usedTokens == 15_000)
    }

    @Test func aChildFinishingAfterTheParentAccountWasResetIsNotCharged() async {
        let parent = BudgetTracker(RequestBudget(maxTokensPerSession: 100_000))
        let generation = await parent.childUsageGeneration
        await parent.reset()
        await parent.recordSettledChildUsage(usage, locator: locator("r1"), sourceGeneration: generation)
        #expect(await parent.budget.usedTokens == 0)
    }

    @Test func aResetClearsTheIdempotencyMemoryOfTheOldAccount() async {
        let parent = BudgetTracker(RequestBudget(maxTokensPerSession: 100_000))
        await parent.recordSettledChildUsage(usage, locator: locator("r1"), sourceGeneration: await parent.childUsageGeneration)
        await parent.reset()
        await parent.recordSettledChildUsage(usage, locator: locator("r1"), sourceGeneration: await parent.childUsageGeneration)
        #expect(await parent.budget.usedTokens == 15_000)
    }

    @Test func budgetChargesTotalInputNotFreshOnly() async throws {
        let tracker = BudgetTracker(RequestBudget(maxTokensPerSession: 1_000_000, overBudgetPolicy: .pause))
        let lease = try await tracker.beginRequest()
        // Anthropic-shaped: 2k fresh, 80k cache read -> total input 82k.
        let reported = LLMUsage(
            inputTokens: 2_000, outputTokens: 500, cacheReadInputTokens: 80_000, cacheHitInputTokens: 82_000)
        await tracker.completeRequest(lease, usage: reported)
        #expect(await tracker.budget.usedTokens == 82_500)
    }

    @Test func defaultCumulativeCapIsOneMillion() {
        #expect(RequestBudget.defaultMaxTokensPerSession == 1_000_000)
    }
}
