import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

/// Renderer half of P3-CHILD-40 / detail row D-CHILDB
/// 「并列展示selected/recommended/effective/actual/queued与原因」.
///
/// Lane 178 (QODER-DEV-W13-CHILDB-PROJECTION-178) sealed the carrier
/// (`ChildConcurrencySelection.sideBySideProjection` / `sideBySideSummary`) and
/// its own receipt declares the out-of-set renderer delta verbatim: replace the
/// four hard-coded chips in `TaskCenterObservationView.childConcurrencySummary`
/// with the five-stage projection and take the accessibility label from
/// `sideBySideSummary`. These tests pin exactly that residual at the surface
/// helpers the body consumes. They assert nothing about which authority feeds
/// actual/queued — that question stays escalated to C0 in lane 178 spec_block
/// (the reporter half belongs to BridgeStore, owned by another lane's queue).
@Suite("Task Center child-concurrency renderer (D-CHILDB five-stage row)")
@MainActor
struct TaskCenterChildConcurrencyRendererTests {

    /// The row renders ALL FIVE stages in the clause's canonical order even
    /// before any RuntimeReport exists; unreported stages show 未上报 instead
    /// of a fabricated zero and instead of being dropped (pre-change the row
    /// had no 实际运行 stage at all and fed the task-ledger 排队 count here).
    @Test("five stages render side by side; unreported runtime half stays 未上报")
    func fiveStagesProjectSideBySideWithHonestUnreportedHalf() {
        let rows = TaskCenterObservationView.childConcurrencyRowTexts(
            selection: .default
        )
        #expect(rows == [
            "用户选择 4",
            "系统建议 4",
            "有效上限 4",
            "实际运行 未上报",
            "排队请求 未上报",
            "硬上限 40",
        ])
    }

    /// Once the reporter feeds a snapshot (BridgeStore is out of this lane's
    /// write set; the renderer must work from the value object alone), the row
    /// shows actual/queued with the per-stage reasons the carrier computed —
    /// including the non-rewrite statement at the recommended stage.
    @Test("reported snapshot renders actual/queued with per-stage reasons")
    func reportedSnapshotRendersValuesAndReasons() throws {
        let selection = try ChildConcurrencySelection(
            userSelected: 8,
            recommended: 4,
            effective: 4,
            runtime: ChildConcurrencySelection.RuntimeReport(
                actualRunning: 3,
                queued: 2
            )
        )
        let rows = TaskCenterObservationView.childConcurrencyRowTexts(
            selection: selection
        )
        #expect(rows == [
            "用户选择 8",
            "系统建议 4（系统建议低于用户选择，用户所选值未被改写）",
            "有效上限 4",
            "实际运行 3（实际运行低于有效上限）",
            "排队请求 2（存在等待槽位的排队请求）",
            "硬上限 40",
        ])
    }

    /// Governor states the reporter observed surface as reasons on the actual
    /// stage (queued/degraded per-child ceiling display). A concordant stage
    /// (queued 0 with no waiting request) carries no parenthesised reason.
    @Test("degraded ceiling and stop-new-launch render as actual-stage reasons")
    func governorStatesRenderAsActualStageReasons() throws {
        let selection = try ChildConcurrencySelection(
            userSelected: 8,
            recommended: 8,
            effective: 8,
            runtime: ChildConcurrencySelection.RuntimeReport(
                actualRunning: 6,
                queued: 0,
                degradedCeiling: 4,
                newLaunchesStopped: true
            )
        )
        let rows = TaskCenterObservationView.childConcurrencyRowTexts(
            selection: selection
        )
        #expect(rows[0] == "用户选择 8")
        #expect(rows[1] == "系统建议 8")
        #expect(rows[2] == "有效上限 8")
        #expect(rows[3] == "实际运行 6（实际运行低于有效上限；并发治理器已降低实际并发上限；Kill Switch 生效，仅停止新启动）")
        #expect(rows[4] == "排队请求 0")
        #expect(rows[5] == "硬上限 40")
    }

    /// The combined-AX label is derived from the same single source as the
    /// chips (`sideBySideSummary`), so visual and accessibility surfaces can
    /// never show different numbers. Regression guard: the old label listed
    /// only four quantities and never mentioned 实际运行; the residual adds it.
    @Test("accessibility label mirrors sideBySideSummary and names all five stages")
    func accessibilityLabelMirrorsSingleSourceSummary() throws {
        let defaultLabel = TaskCenterObservationView
            .childConcurrencyAccessibilityLabel(selection: .default)
        #expect(
            defaultLabel
                == "子 Agent 并发，\(ChildConcurrencySelection.default.sideBySideSummary)，硬上限 40"
        )
        #expect(defaultLabel.contains("实际运行 未上报"))
        #expect(defaultLabel.contains("排队请求 未上报"))
        #expect(!defaultLabel.contains("排队 0"))

        let reported = try ChildConcurrencySelection(
            userSelected: 16,
            recommended: 8,
            effective: 8,
            runtime: ChildConcurrencySelection.RuntimeReport(
                actualRunning: 12,
                queued: 5
            )
        )
        let reportedLabel = TaskCenterObservationView
            .childConcurrencyAccessibilityLabel(selection: reported)
        #expect(
            reportedLabel
                == "子 Agent 并发，\(reported.sideBySideSummary)，硬上限 40"
        )
        #expect(reportedLabel.contains("实际运行 12（实际运行高于有效上限）"))
        #expect(reportedLabel.contains("排队请求 5（存在等待槽位的排队请求）"))
    }
}
