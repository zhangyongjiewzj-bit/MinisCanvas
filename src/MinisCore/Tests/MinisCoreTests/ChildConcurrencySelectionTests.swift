import Foundation
import Testing
@testable import MinisCore

@Suite("Child concurrency selection")
struct ChildConcurrencySelectionTests {
    @Test("selected, recommended and effective values remain distinct")
    func valuesRemainDistinctAndRecommendationIsAdvisory() throws {
        let selection = try ChildConcurrencySelection(
            userSelected: 16,
            recommended: 8,
            effective: 4,
            enabledSessionCount: 3
        )

        #expect(selection.userSelected == 16)
        #expect(selection.recommended == 8)
        #expect(selection.effective == 4)
        #expect(selection.globalRequestedCapacity == 48)
    }

    @Test("selection has a hard ceiling and effective runtime cannot exceed it")
    func selectionBoundsAreFailClosed() {
        #expect(throws: ChildConcurrencySelection.ValidationError.userSelectedOutOfRange(0)) {
            try ChildConcurrencySelection(
                userSelected: 0,
                recommended: 1,
                effective: 1
            )
        }
        #expect(throws: ChildConcurrencySelection.ValidationError.userSelectedOutOfRange(41)) {
            try ChildConcurrencySelection(
                userSelected: 41,
                recommended: 40,
                effective: 40
            )
        }
        #expect(throws: ChildConcurrencySelection.ValidationError.effectiveExceedsSelection) {
            try ChildConcurrencySelection(
                userSelected: 8,
                recommended: 4,
                effective: 9
            )
        }
        #expect(ChildConcurrencySelection.hardMaximum == 40)
    }

    @Test("orchestrator consumes effective runtime under the hard child ceiling")
    func orchestratorUsesEffectiveRuntime() throws {
        let selection = try ChildConcurrencySelection(
            userSelected: 40,
            recommended: 12,
            effective: 8
        )
        let orchestrator = AgentOrchestrator(
            childConcurrencySelection: selection
        )

        #expect(orchestrator.childConcurrencySelection == selection)
        #expect(orchestrator.defaultMaxConcurrent == 8)
        #expect(AgentOrchestrator.hardMaxConcurrentChildren == 40)
    }

    // MARK: - D-CHILDB「并列展示selected/recommended/effective/actual/queued与原因」

    /// A selection whose concurrency authority has reported both runtime values.
    private static func reportedSelection(
        userSelected: Int = 16,
        recommended: Int = 8,
        effective: Int = 4,
        enabledSessionCount: Int = 3,
        actualRunning: Int,
        queued: Int,
        degradedCeiling: Int? = nil,
        newLaunchesStopped: Bool = false
    ) throws -> ChildConcurrencySelection {
        try ChildConcurrencySelection(
            userSelected: userSelected,
            recommended: recommended,
            effective: effective,
            enabledSessionCount: enabledSessionCount,
            runtime: ChildConcurrencySelection.RuntimeReport(
                actualRunning: actualRunning,
                queued: queued,
                degradedCeiling: degradedCeiling,
                newLaunchesStopped: newLaunchesStopped
            )
        )
    }

    @Test("all five quantities are carried by one value object in canonical order")
    func fiveQuantitiesProjectTogether() throws {
        let selection = try Self.reportedSelection(
            userSelected: 16,
            recommended: 8,
            effective: 4,
            actualRunning: 3,
            queued: 5
        )
        let rows = selection.sideBySideProjection

        // The consumer must be able to render five side-by-side stages from ONE
        // object: nothing is dropped and the order is the requirement's order.
        #expect(rows.count == 5)
        #expect(rows.map(\.stage) == ChildConcurrencySelection.Stage.allCases)
        #expect(rows.map(\.stage) == [.selected, .recommended, .effective, .actual, .queued])
        #expect(rows[0].value == 16)
        #expect(rows[1].value == 8)
        #expect(rows[2].value == 4)
        #expect(rows[3].value == 3)
        #expect(rows[4].value == 5)

        // The three ceilings keep their previous meaning: the projection never
        // substitutes one quantity for another.
        #expect(selection.userSelected == 16)
        #expect(selection.recommended == 8)
        #expect(selection.effective == 4)
        #expect(selection.runtime?.actualRunning == 3)
        #expect(selection.runtime?.queued == 5)
    }

    @Test("an unreported runtime half projects as absent, never as zero")
    func unreportedRuntimeIsNotFabricated() throws {
        let selection = try ChildConcurrencySelection(
            userSelected: 16,
            recommended: 8,
            effective: 4
        )
        let rows = selection.sideBySideProjection

        // Still five stages, so the surface shows the gap instead of a missing row.
        #expect(rows.count == 5)
        #expect(rows[0].value == 16)
        #expect(rows[1].value == 8)
        #expect(rows[2].value == 4)
        #expect(rows[3].stage == .actual)
        #expect(rows[3].value == nil)
        #expect(rows[4].stage == .queued)
        #expect(rows[4].value == nil)
        // An absent stage must not read as "0 running / 0 queued".
        #expect(rows[3].value != 0)
        #expect(rows[4].value != 0)
        #expect(rows[3].displayText.contains("未上报"))
        #expect(selection.sideBySideSummary.contains("未上报"))
    }

    @Test("each diverging stage carries its own reason and the reference stage none")
    func deviationReasonsAreAttachedPerStage() throws {
        let selection = try Self.reportedSelection(
            userSelected: 16,
            recommended: 8,
            effective: 4,
            actualRunning: 3,
            queued: 2
        )
        let rows = selection.sideBySideProjection
        let byStage = Dictionary(uniqueKeysWithValues: rows.map { ($0.stage, $0) })

        // selected is the reference point: no reason can attach to it.
        #expect(byStage[.selected]?.deviations.isEmpty == true)
        #expect(byStage[.recommended]?.deviations == [.recommendedBelowSelected])
        #expect(byStage[.effective]?.deviations == [.effectiveBelowRecommended])
        #expect(byStage[.actual]?.deviations == [.actualBelowEffective])
        #expect(byStage[.queued]?.deviations == [.queuedRequestsWaiting])

        // Every reported reason states something and belongs to its own stage.
        for row in rows {
            for deviation in row.deviations {
                #expect(deviation.stage == row.stage)
                #expect(!deviation.explanation.isEmpty)
            }
        }
        // The reason is rendered together with the value it explains.
        #expect(byStage[.actual]?.displayText.contains("实际运行 3") == true)
        #expect(byStage[.actual]?.displayText.contains(ChildConcurrencySelection.Deviation.actualBelowEffective.explanation) == true)
    }

    @Test("a stage that does not diverge carries no reason")
    func concordantStagesCarryNoReason() throws {
        let selection = try Self.reportedSelection(
            userSelected: 8,
            recommended: 8,
            effective: 8,
            actualRunning: 8,
            queued: 0
        )
        #expect(selection.sideBySideProjection.allSatisfy { $0.deviations.isEmpty })
    }

    @Test("governor states reported by the authority become reasons on the actual stage")
    func governorStatesSurfaceAsReasons() throws {
        let selection = try Self.reportedSelection(
            userSelected: 8,
            recommended: 8,
            effective: 4,
            actualRunning: 4,
            queued: 0,
            degradedCeiling: 2,
            newLaunchesStopped: true
        )
        let rows = selection.sideBySideProjection
        let byStage = Dictionary(uniqueKeysWithValues: rows.map { ($0.stage, $0) })

        // actual == effective: the divergence reasons here come from the reported
        // governor states, not from an arithmetic comparison.
        #expect(byStage[.actual]?.value == 4)
        #expect(byStage[.actual]?.deviations == [.governorDegradedCeiling, .governorStoppedNewLaunches])
        #expect(byStage[.actual]?.deviations.contains(.actualBelowEffective) == false)
        // effective 4 < recommended 8 still explains itself.
        #expect(byStage[.effective]?.deviations == [.effectiveBelowRecommended])
        // A stopped-new-launch / degraded governor with an empty queue adds nothing
        // to the queued stage.
        #expect(byStage[.queued]?.deviations.isEmpty == true)
    }

    @Test("an aggregate actual above the per-session ceiling is projected, not clamped")
    func globalAggregateAboveCeilingIsReported() throws {
        // 3 enabled sessions: 9 running children is legitimate even though the
        // per-session effective ceiling is 4. The value object must state the
        // divergence instead of rejecting or clamping it.
        let selection = try Self.reportedSelection(
            userSelected: 40,
            recommended: 40,
            effective: 4,
            enabledSessionCount: 3,
            actualRunning: 9,
            queued: 12
        )
        let rows = selection.sideBySideProjection
        let byStage = Dictionary(uniqueKeysWithValues: rows.map { ($0.stage, $0) })

        #expect(byStage[.actual]?.value == 9)
        #expect(byStage[.actual]?.deviations == [.actualAboveEffective])
        #expect(byStage[.queued]?.value == 12)
        #expect(byStage[.queued]?.deviations == [.queuedRequestsWaiting])
        #expect(selection.globalRequestedCapacity == 120)
    }

    @Test("runtime half is validated fail-closed")
    func runtimeReportBoundsAreFailClosed() {
        #expect(throws: ChildConcurrencySelection.ValidationError.actualRunningOutOfRange(-1)) {
            try ChildConcurrencySelection.RuntimeReport(actualRunning: -1, queued: 0)
        }
        #expect(throws: ChildConcurrencySelection.ValidationError.queuedRequestsOutOfRange(-3)) {
            try ChildConcurrencySelection.RuntimeReport(actualRunning: 0, queued: -3)
        }
        #expect(throws: ChildConcurrencySelection.ValidationError.degradedCeilingOutOfRange(-1)) {
            try ChildConcurrencySelection.RuntimeReport(
                actualRunning: 1,
                queued: 1,
                degradedCeiling: -1
            )
        }
        // Zero is a real measurement, not an out-of-range value.
        #expect(throws: Never.self) {
            _ = try ChildConcurrencySelection.RuntimeReport(actualRunning: 0, queued: 0)
        }
    }

    @Test("attaching a runtime report never rewrites the user's selection")
    func withRuntimeLeavesUserValuesUntouched() throws {
        let original = try ChildConcurrencySelection(
            userSelected: 40,
            recommended: 8,
            effective: 4,
            enabledSessionCount: 4
        )
        let report = try ChildConcurrencySelection.RuntimeReport(actualRunning: 11, queued: 7)
        let updated = try original.withRuntime(report)

        #expect(original.runtime == nil)
        #expect(updated.userSelected == original.userSelected)
        #expect(updated.recommended == original.recommended)
        #expect(updated.effective == original.effective)
        #expect(updated.enabledSessionCount == original.enabledSessionCount)
        #expect(updated.runtime == report)
        #expect(updated.globalRequestedCapacity == 160)
        // Clearing the runtime half returns to "not reported", not to zero.
        #expect(try original.withRuntime(nil).runtime == nil)
        #expect(try original.withRuntime(nil).sideBySideProjection[3].value == nil)
    }

    @Test("a selection encoded before the runtime half existed still decodes")
    func codableStaysBackwardCompatible() throws {
        let legacyJSON = Data(
            """
            {"userSelected":16,"recommended":8,"effective":4,"enabledSessionCount":3}
            """.utf8
        )
        let decoded = try JSONDecoder().decode(ChildConcurrencySelection.self, from: legacyJSON)
        #expect(decoded.userSelected == 16)
        #expect(decoded.runtime == nil)
        #expect(decoded.sideBySideProjection.count == 5)
        #expect(decoded.sideBySideProjection[3].value == nil)

        let reported = try Self.reportedSelection(
            actualRunning: 6,
            queued: 2,
            degradedCeiling: 3,
            newLaunchesStopped: true
        )
        let roundTripped = try JSONDecoder().decode(
            ChildConcurrencySelection.self,
            from: JSONEncoder().encode(reported)
        )
        #expect(roundTripped == reported)
        #expect(roundTripped.runtime?.actualRunning == 6)
        #expect(roundTripped.runtime?.queued == 2)
        #expect(roundTripped.runtime?.degradedCeiling == 3)
        #expect(roundTripped.runtime?.newLaunchesStopped == true)
        // Decoding still yields the same reasons as the object that was encoded.
        #expect(roundTripped.sideBySideProjection == reported.sideBySideProjection)
    }

    @Test("the joint summary states all five stages with their reasons on one line")
    func sideBySideSummaryCarriesFiveStages() throws {
        let selection = try Self.reportedSelection(
            userSelected: 16,
            recommended: 8,
            effective: 4,
            actualRunning: 3,
            queued: 2
        )
        let summary = selection.sideBySideSummary
        for title in ChildConcurrencySelection.Stage.allCases.map(\.title) {
            #expect(summary.contains(title))
        }
        // The rendered components are in the requirement's order, and each one
        // carries its own value: the five quantities really are shown side by side.
        let components = summary.split(separator: " · ").map(String.init)
        #expect(components.count == 5)
        let stages = ChildConcurrencySelection.Stage.allCases
        for (index, component) in components.enumerated() {
            #expect(component.hasPrefix(stages[index].title))
        }
        #expect(components[0] == "用户选择 16")
        #expect(components[3].hasPrefix("实际运行 3（"))
        #expect(components[4].hasPrefix("排队请求 2（"))
        #expect(selection.sideBySideProjection.map(\.displayText).joined(separator: " · ") == summary)
    }
}
