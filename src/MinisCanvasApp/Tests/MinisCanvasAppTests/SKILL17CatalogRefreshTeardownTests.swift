import Testing
@testable import MinisCanvasApp

@Suite("SKILL-17 catalog refresh teardown")
struct SKILL17CatalogRefreshTeardownTests {
    @Test func teardownInvalidationAdvancesGenerationForTheSameScope() {
        var gate = SkillCatalogRefreshGate()
        let active = gate.begin(scopeKey: "scope-stable")

        gate.invalidate(scopeKey: "scope-stable")

        #expect(gate.scopeKey == "scope-stable")
        #expect(gate.generation > active.generation)
        #expect(!gate.accepts(active))
    }
}
