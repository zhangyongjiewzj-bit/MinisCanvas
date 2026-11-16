import Testing
@testable import MinisCanvasApp

@Suite("SKILL-16 catalog refresh task ownership")
struct SKILL16CatalogRefreshTaskOwnershipTests {
    @Test func sameScopeForegroundRefreshSupersedesBackgroundToken() {
        var gate = SkillCatalogRefreshGate()
        let background = gate.begin(scopeKey: "scope-stable")
        let foreground = gate.begin(scopeKey: "scope-stable")

        #expect(!gate.accepts(background))
        #expect(gate.accepts(foreground))
    }

    @Test func invalidationSupersedesTheActiveTaskToken() {
        var gate = SkillCatalogRefreshGate()
        let active = gate.begin(scopeKey: "scope-stable")

        gate.invalidate(scopeKey: "scope-stable")

        #expect(!gate.accepts(active))
    }
}
