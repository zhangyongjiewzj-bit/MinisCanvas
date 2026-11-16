import Testing
@testable import MinisCanvasApp

@Suite("D-PERF-01/05 input correlation IDs")
@MainActor
struct ComposerInputLatencyCollectorTests {
    @Test("A synchronous key dispatch pairs with commits and then clears")
    func physicalKeyScope() {
        let first = ComposerInputLatencyCollector()
        let second = ComposerInputLatencyCollector()
        let key = first.beginPhysicalKey()
        let one = first.nextCommit()
        let two = first.nextCommit()
        #expect(one.physicalKeyID == key.id)
        #expect(two.physicalKeyID == key.id)
        #expect(one.eventID != two.eventID)
        #expect(second.nextCommit().physicalKeyID == nil)
        first.endPhysicalKey(key)
        #expect(first.nextCommit().physicalKeyID == nil)
    }

    @Test("Nested dispatch restores the outer key ID")
    func nestedKeyScope() {
        let collector = ComposerInputLatencyCollector()
        let outer = collector.beginPhysicalKey()
        let inner = collector.beginPhysicalKey()
        #expect(collector.nextCommit().physicalKeyID == inner.id)
        collector.endPhysicalKey(inner)
        #expect(collector.nextCommit().physicalKeyID == outer.id)
        collector.endPhysicalKey(outer)
        #expect(collector.nextCommit().physicalKeyID == nil)
    }
}
