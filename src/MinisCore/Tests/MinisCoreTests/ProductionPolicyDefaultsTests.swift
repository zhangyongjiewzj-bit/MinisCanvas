import Foundation
import Testing
@testable import MinisCore

/// S6：生产 PolicyRuntime 默认值收紧 —— 保守默认 + 显式覆盖两路都验证。
///
/// 收紧目标：此前生产装配直接写死 budget 1_000_000（近似无限）、
/// deadline .distantFuture（永不过期）、autonomyLevel .l3（完整自主）、
/// networkDomains []（fail-closed）。默认值必须是有界、有限、低自主的；
/// 显式配置的默认值必须原样生效（不允许默认层吞掉显式配置）。
struct ProductionPolicyDefaultsTests {
    @Test func productionDefaultsAreConservative() {
        let d = ProductionPolicyDefaults.default
        #expect(d.budget > 0)
        #expect(d.budget < 1_000_000)          // 不再近似无限
        #expect(d.deadlineHorizon.isFinite)
        #expect(d.deadlineHorizon > 0)          // 有限时限（不再永不失效）
        #expect(d.deadlineHorizon < 24 * 60 * 60) // 会话长度量级，而非无限
        #expect(d.autonomyLevel < .l3)          // 不再完整自主
        #expect(d.networkDomains.isEmpty)       // fail-closed
    }

    @Test func explicitOverrideIsHonoredExactly() {
        let d = ProductionPolicyDefaults(
            budget: 123,
            deadlineHorizon: 60,
            autonomyLevel: .l3,
            networkDomains: ["example.com"]
        )
        #expect(d.budget == 123)
        #expect(d.deadlineHorizon == 60)
        #expect(d.autonomyLevel == .l3)
        #expect(d.networkDomains == ["example.com"])
    }

    @Test func deadlineFactoryYieldsFiniteBoundedDeadline() {
        let d = ProductionPolicyDefaults.default
        let created = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let deadline = d.deadline(from: created)
        #expect(deadline.timeIntervalSinceReferenceDate.isFinite)
        #expect(deadline > created)
        #expect(deadline == created.addingTimeInterval(d.deadlineHorizon))
        #expect(deadline != .distantFuture)
    }

    @Test func codableRoundTripPreservesPolicyBoundary() throws {
        let original = ProductionPolicyDefaults(
            budget: 321,
            deadlineHorizon: 90,
            autonomyLevel: .l2,
            networkDomains: ["api.example.com", "cdn.example.com"]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProductionPolicyDefaults.self, from: data)
        #expect(decoded == original)
    }
}
