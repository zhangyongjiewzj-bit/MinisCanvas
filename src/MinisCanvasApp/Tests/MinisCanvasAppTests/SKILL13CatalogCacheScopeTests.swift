import Testing
@testable import MinisCanvasApp

@Suite("SKILL-13 catalog cache scope gate")
struct SKILL13CatalogCacheScopeTests {
    @Test func changingScopeRejectsOlderInFlightRequest() {
        var gate = SkillCatalogCacheRequestGate()

        let oldRequest = gate.begin(scopeKey: "scope-old")
        #expect(gate.accepts(oldRequest))

        let newRequest = gate.begin(scopeKey: "scope-new")
        #expect(!gate.accepts(oldRequest))
        #expect(gate.accepts(newRequest))
    }

    @Test func explicitInvalidationRejectsInFlightRequest() {
        var gate = SkillCatalogCacheRequestGate()
        let request = gate.begin(scopeKey: "scope-stable")

        gate.invalidate()

        #expect(!gate.accepts(request))
    }
}
