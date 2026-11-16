import Testing
@testable import MinisCanvasApp

@Suite("SKILL-14 catalog refresh cancellation")
struct SKILL14CatalogRefreshCancellationTests {
    @Test func cancellationRejectsOnlyTheCurrentRefreshToken() {
        var gate = SkillCatalogRefreshGate()
        let current = gate.begin(scopeKey: "scope-current")

        let cancelledCurrent = gate.cancel(current)
        #expect(cancelledCurrent)
        #expect(!gate.accepts(current))

        let next = gate.begin(scopeKey: "scope-next")
        let cancelledCurrentAfterNext = gate.cancel(current)
        #expect(!cancelledCurrentAfterNext)
        #expect(gate.accepts(next))
    }

    @Test func newerRefreshWinsOverCancelledOlderToken() {
        var gate = SkillCatalogRefreshGate()
        let old = gate.begin(scopeKey: "scope-old")
        let newer = gate.begin(scopeKey: "scope-new")

        let cancelledOldAfterNew = gate.cancel(old)
        #expect(!cancelledOldAfterNew)
        #expect(gate.accepts(newer))
    }
}
