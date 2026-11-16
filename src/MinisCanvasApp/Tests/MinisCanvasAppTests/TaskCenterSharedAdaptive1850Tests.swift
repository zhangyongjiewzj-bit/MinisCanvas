import AppKit
import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

@Suite("APP14 Task Center five-stage shared layout consumer")
@MainActor
struct TaskCenterSharedAdaptive1850Tests {
    private func selection(_ state: Int) throws -> ChildConcurrencySelection {
        switch state {
        case 0: return .default
        case 1:
            return try ChildConcurrencySelection(
                userSelected: 8, recommended: 4, effective: 4,
                runtime: .init(actualRunning: 3, queued: 2)
            )
        default:
            return try ChildConcurrencySelection(
                userSelected: 8, recommended: 8, effective: 8,
                runtime: .init(actualRunning: 6, queued: 0,
                               degradedCeiling: 4, newLaunchesStopped: true)
            )
        }
    }

    private func sizes(_ selection: ChildConcurrencySelection, base: Int) -> [CGSize] {
        // Actual production content and typography, without creating a window.
        let labels = ["子 Agent 并发"]
            + TaskCenterObservationView.childConcurrencyRowTexts(selection: selection)
        let font = NSFont.systemFont(ofSize: TypographyTokenSet.forBaseFontSize(base).caption)
        return labels.enumerated().map { index, text in
            let size = (text as NSString).size(withAttributes: [.font: font])
            return CGSize(width: ceil(size.width) + (index == 0 ? 18 : 0),
                          height: ceil(size.height))
        }
    }

    private func expectContained(_ plan: AdaptiveControlRowPlan, width: CGFloat) {
        #expect(plan.frames.count == 7)
        for frame in plan.frames {
            #expect(frame.minX >= 0 && frame.maxX <= width)
            #expect(frame.minY >= 0 && frame.maxY <= plan.size.height)
        }
        for i in plan.frames.indices {
            for j in plan.frames.indices where j > i {
                #expect(!plan.frames[i].intersects(plan.frames[j]))
            }
        }
    }

    @Test(arguments: [0, 1, 2])
    func productionFiveStagesWrapAndRecoverWithoutDroppingReasons(state: Int) throws {
        let value = try selection(state)
        let layout = TaskCenterObservationView.childConcurrencyRowLayout
        let items = sizes(value, base: TypographySettings.uiBaseFontSizeRange.upperBound)
        let allocation: CGFloat = 520 - 40 // Actual Task Center minimum and padding.
        let oldSingleRowMinimum = items.reduce(0) { $0 + $1.width }
            + layout.spacing * CGFloat(items.count - 1)
        #expect(oldSingleRowMinimum > allocation)
        let before = TaskCenterObservationView.childConcurrencyRowTexts(selection: value)
        let axBefore = TaskCenterObservationView.childConcurrencyAccessibilityLabel(selection: value)
        let narrow = layout.allocationPlan(availableWidth: allocation, itemSizes: items)
        let wide = layout.allocationPlan(availableWidth: 1_560, itemSizes: items)
        #expect(Set(narrow.frames.map(\.minY)).count > 1)
        #expect(wide.frames.allSatisfy { $0.minY == 0 })
        #expect(wide.frames.map(\.size) == items)
        #expect(layout.allocationPlan(availableWidth: allocation, itemSizes: items) == narrow)
        expectContained(narrow, width: allocation)
        expectContained(wide, width: 1_560)
        #expect(TaskCenterObservationView.childConcurrencyRowTexts(selection: value) == before)
        #expect(TaskCenterObservationView.childConcurrencyAccessibilityLabel(selection: value) == axBefore)
    }

    @Test(arguments: Array(TypographySettings.uiBaseFontSizeRange))
    func supportedTypographyUsesTheSameProductionAllocationBoundary(base: Int) throws {
        let layout = TaskCenterObservationView.childConcurrencyRowLayout
        for state in [0, 1, 2] {
            let items = sizes(try selection(state), base: base)
            for width: CGFloat in [480, 560, 760, 960, 1_240, 1_560] {
                let plan = layout.allocationPlan(availableWidth: width, itemSizes: items)
                expectContained(plan, width: width)
                #expect(plan.frames.allSatisfy { $0.height > 0 })
                #expect(plan.frames.map(\.width) == items.map { min($0.width, width) })
            }
        }
    }
}
