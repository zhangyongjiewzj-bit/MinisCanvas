import Testing
@testable import MinisCanvasApp

@Suite("SKILL-15 catalog refresh retry reset")
struct SKILL15CatalogRefreshRetryResetTests {
    @Test func cancelledRefreshRestartsRetryAllowanceForSameScope() {
        var budget = SkillCatalogRefreshRetryBudget()

        _ = budget.bind(scopeKey: "scope-stable")
        _ = budget.record(status: .degraded)
        #expect(budget.record(status: .degraded) == .exhausted)

        budget.resetAfterCancellation()

        #expect(budget.degradedAttempts == 0)
        #expect(budget.record(status: .degraded) == .retryAvailable)
    }
}
