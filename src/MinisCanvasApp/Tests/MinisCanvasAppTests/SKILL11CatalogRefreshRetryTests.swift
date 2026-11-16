import Testing
@testable import MinisCanvasApp

@Suite("SKILL-11 catalog refresh retry bound")
struct SKILL11CatalogRefreshRetryTests {
    @Test func degradedRefreshOffersOneRetryThenExhausts() {
        var budget = SkillCatalogRefreshRetryBudget()

        #expect(budget.record(status: .degraded) == .retryAvailable)
        #expect(budget.record(status: .degraded) == .exhausted)
        #expect(budget.record(status: .degraded) == .exhausted)
        #expect(budget.degradedAttempts == SkillCatalogRefreshRetryBudget.maxDegradedAttempts)
    }

    @Test func readyRefreshResetsDegradedRetryBudget() {
        var budget = SkillCatalogRefreshRetryBudget()
        _ = budget.record(status: .degraded)
        #expect(budget.record(status: .ready) == .notNeeded)
        #expect(budget.degradedAttempts == 0)
        #expect(SkillCatalogRefreshRetryState.retryAvailable.stableSummary == "技能目录：可重试一次")
        #expect(!SkillCatalogRefreshRetryState.exhausted.stableSummary.contains("path"))
    }
}
