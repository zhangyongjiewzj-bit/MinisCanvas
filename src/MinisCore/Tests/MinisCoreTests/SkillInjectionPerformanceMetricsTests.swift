import Foundation
import Testing
@testable import MinisCore

private final class FixedMonotonicClock: SkillInjectionMonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64]

    init(_ values: [UInt64]) {
        self.values = values
    }

    func nowNanoseconds() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return values.isEmpty ? 0 : values.removeFirst()
    }
}

struct SkillInjectionPerformanceMetricsTests {
    @Test func ordinarySkillTurnSnapshotsUseBoundedDefaultInjection() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let injector = SkillInjector(store: SkillStore(skillsRoot: directory)).snapshotForTurn()
        #expect(injector.maxInjectedSkills == 3)
        #expect(injector.maxInjectedCharacters == 8_000)
        let disabled = injector.captureTurnPreparation(skillsEnabled: false)
        #expect(disabled.maxInjectedSkills == 0)
    }

    @Test func fixedCapacityUsesMonotonicDurationsAndErrorClasses() {
        let clock = FixedMonotonicClock([10, 25, 30, 48, 50, 75])
        let metrics = SkillInjectionPerformanceMetrics(capacity: 2, clock: clock)

        let first = metrics.beginBuild()
        metrics.complete(first, eligibleCandidateCount: 1, errorClass: .none)
        let second = metrics.beginBuild()
        metrics.complete(second, eligibleCandidateCount: 1, errorClass: .partiallyRejected)
        let third = metrics.beginBuild()
        metrics.complete(third, eligibleCandidateCount: 0, errorClass: .allCandidatesRejected)

        let snapshot = metrics.snapshot()
        #expect(snapshot.capacity == 2)
        #expect(snapshot.eligibleBuildCount == 2)
        #expect(snapshot.eligibleCandidateCount == 2)
        #expect(snapshot.completedBuildCount == 3)
        #expect(snapshot.completedDurationNanoseconds == 58)
        #expect(snapshot.errorCounts[SkillInjectionBuildErrorClass.partiallyRejected.rawValue] == 1)
        #expect(snapshot.errorCounts[SkillInjectionBuildErrorClass.allCandidatesRejected.rawValue] == 1)
        #expect(snapshot.samples.map(\.durationNanoseconds) == [18, 25])
        #expect(snapshot.samples.map(\.eligibleCandidateCount) == [1, 0])
    }

    @Test func resetClearsCountersAndBoundedSamples() {
        let clock = FixedMonotonicClock([100, 101])
        let metrics = SkillInjectionPerformanceMetrics(capacity: 1, clock: clock)
        let token = metrics.beginBuild()
        metrics.complete(token, eligibleCandidateCount: 2, errorClass: .budgetDisabled)

        metrics.reset()
        let snapshot = metrics.snapshot()
        #expect(snapshot.eligibleBuildCount == 0)
        #expect(snapshot.completedBuildCount == 0)
        #expect(snapshot.completedDurationNanoseconds == 0)
        #expect(snapshot.errorCounts.isEmpty)
        #expect(snapshot.samples.isEmpty)
    }

    @Test func injectorRecordsEligibleCompletedBuildWithoutPayloadMetrics() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillInjectionMetrics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SkillStore(skillsRoot: root)
        _ = try store.importSkill(content: """
        ---
        name: metrics-skill
        description: metrics keyword
        ---

        Metrics body is not retained by the metrics collector.
        """)
        let clock = FixedMonotonicClock([200, 245])
        let metrics = SkillInjectionPerformanceMetrics(capacity: 4, clock: clock)
        let injector = SkillInjector(store: store, performanceMetrics: metrics)

        let result = injector.buildInjection(for: "metrics keyword")
        #expect(result.fragment != nil)

        let snapshot = metrics.snapshot()
        #expect(snapshot.eligibleBuildCount == 1)
        #expect(snapshot.completedBuildCount == 1)
        #expect(snapshot.samples.count == 1)
        #expect(snapshot.samples[0].durationNanoseconds == 45)
        #expect(snapshot.samples[0].eligibleCandidateCount == 1)
        #expect(snapshot.samples[0].errorClass == .none)
    }
}
