import Testing
@testable import MinisCanvasApp

@Suite("SKILL-12 catalog refresh scope retry")
struct SKILL12CatalogRefreshScopeTests {
    @Test func changingScopeResetsExhaustedRetryBudget() {
        var budget = SkillCatalogRefreshRetryBudget()

        let boundOldScope = budget.bind(scopeKey: "scope-old")
        #expect(boundOldScope)
        _ = budget.record(status: .degraded)
        #expect(budget.record(status: .degraded) == .exhausted)
        #expect(budget.degradedAttempts == 2)

        let boundNewScope = budget.bind(scopeKey: "scope-new")
        #expect(boundNewScope)
        #expect(budget.degradedAttempts == 0)
        #expect(budget.record(status: .degraded) == .retryAvailable)
    }

    @Test func rebindingSameScopeDoesNotSilentlyResetFailures() {
        var budget = SkillCatalogRefreshRetryBudget()

        _ = budget.bind(scopeKey: "scope-stable")
        _ = budget.record(status: .degraded)
        let reboundStableScope = budget.bind(scopeKey: "scope-stable")
        #expect(!reboundStableScope)
        #expect(budget.degradedAttempts == 1)
    }
}
