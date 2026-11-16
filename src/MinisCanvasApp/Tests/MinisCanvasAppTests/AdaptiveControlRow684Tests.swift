import AppKit
import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

/// No window or App launch: real supported typography and real surface labels
/// feed the exact row planner used by SwiftUI's production Layout consumer.
@Suite("APP14/AX08 shared control row allocation")
@MainActor
struct AdaptiveControlRow684Tests {
    private func sizes(_ labels: [String], baseSize: Int, horizontalPadding: CGFloat = 0) -> [CGSize] {
        let caption = TypographyTokenSet.forBaseFontSize(baseSize).caption
        let font = NSFont.systemFont(ofSize: caption)
        return labels.map {
            let measured = ($0 as NSString).size(withAttributes: [.font: font])
            return CGSize(width: ceil(measured.width) + horizontalPadding, height: ceil(measured.height))
        }
    }

    private func expectContained(_ plan: AdaptiveControlRowPlan, in width: CGFloat) {
        for frame in plan.frames {
            #expect(frame.minX >= 0)
            #expect(frame.maxX <= width)
            #expect(frame.minY >= 0)
            #expect(frame.maxY <= plan.size.height)
        }
        for i in plan.frames.indices {
            for j in plan.frames.indices where j > i {
                #expect(!plan.frames[i].intersects(plan.frames[j]))
            }
        }
    }

    @Test("Supported largest caption already exceeds the real minimum right pane even before icons")
    func contextTabsRequireWrappingAtSupportedFont() {
        let rightPane = AdaptiveLayoutPolicy.decision(
            for: 1_100, preferredLeftWidth: 240, preferredRightWidth: 56
        ).rightWidth
        let allocation = CGFloat(rightPane) - 16 // tabBar's existing horizontal padding
        let items = sizes(ContextTab.allCases.map(\.title),
                          baseSize: TypographySettings.uiBaseFontSizeRange.upperBound,
                          horizontalPadding: 16) // each tab's existing padding; icons omitted
        let oldSingleRowMinimum = items.reduce(0) { $0 + $1.width } + 2 * CGFloat(items.count - 1)
        #expect(oldSingleRowMinimum > allocation)
        let plan = AdaptiveLayoutPolicy.controlRowPlan(availableWidth: allocation, itemSizes: items, spacing: 2)
        #expect(plan.frames.count == ContextTab.allCases.count)
        #expect(Set(plan.frames.map(\.minY)).count > 1)
        expectContained(plan, in: allocation)
    }

    @Test("Task filter's actual source identity stays reachable without truncating the action out of the sheet")
    func taskCenterFiltersRequireMoreThanOneRow() {
        let labels = ["状态：已取消", "来源：8a33a1af-357e-472b-bc7e-01fb0f7aa001", "显示已归档"]
        let items = sizes(labels, baseSize: TypographySettings.uiBaseFontSizeRange.upperBound)
        let allocation: CGFloat = 520 - 40 // existing Task Center minimum minus content padding
        #expect(items.reduce(0) { $0 + $1.width } + 20 > allocation)
        let plan = AdaptiveLayoutPolicy.controlRowPlan(availableWidth: allocation, itemSizes: items, spacing: 10)
        #expect(plan.frames.count == labels.count)
        #expect(plan.frames.last!.minY > 0)
        expectContained(plan, in: allocation)
    }

    @Test("Width/font matrix preserves every item, order and nonoverlapping hot area")
    func allSupportedFontSizesAndAllocatedWidthsKeepControls() {
        for base in TypographySettings.uiBaseFontSizeRange {
            let items = sizes(ContextTab.allCases.map(\.title), baseSize: base, horizontalPadding: 16)
            for width in [CGFloat(56), 220, 248, 300, 520, 600, 799, 800, 1_100, 1_400, 1_600] {
                let plan = AdaptiveLayoutPolicy.controlRowPlan(availableWidth: width, itemSizes: items, spacing: 8)
                #expect(plan.frames.count == items.count)
                #expect(plan.frames.allSatisfy { $0.height > 0 })
                #expect(plan.size.width == width)
                expectContained(plan, in: width)
                for i in 1..<plan.frames.count {
                    #expect(plan.frames[i].minY >= plan.frames[i - 1].minY)
                }
            }
        }
    }

    @Test("Shrinking then widening recomputes a single row without mutating content geometry")
    func widthRecoveryUsesOriginalSizes() {
        let items = sizes(["取消", "确认执行", "浏览器后退", "刷新页面", "前往网址"], baseSize: 20)
        let narrow = AdaptiveLayoutPolicy.controlRowPlan(availableWidth: 248, itemSizes: items, spacing: 6)
        let wide = AdaptiveLayoutPolicy.controlRowPlan(availableWidth: 1_600, itemSizes: items, spacing: 6)
        #expect(Set(narrow.frames.map(\.minY)).count > 1)
        #expect(wide.frames.allSatisfy { $0.minY == 0 })
        #expect(wide.frames.map(\.size) == items)
        #expect(AdaptiveLayoutPolicy.controlRowPlan(availableWidth: 248, itemSizes: items, spacing: 6) == narrow)
        expectContained(narrow, in: 248)
        expectContained(wide, in: 1_600)
    }

    @Test("Oversized intrinsic label reserves a bounded separate row instead of hiding later actions")
    func oversizedLabelLeavesFollowingActionsInsideAllocation() {
        let items = [CGSize(width: 2_000, height: 40), CGSize(width: 90, height: 24), CGSize(width: 120, height: 24)]
        let plan = AdaptiveLayoutPolicy.controlRowPlan(availableWidth: 248, itemSizes: items, spacing: 8)
        #expect(plan.frames[0].width == 248)
        #expect(plan.frames[1].minY == 48)
        #expect(plan.frames[2].minY == 48)
        #expect(plan.frames[2].width == 120)
        expectContained(plan, in: 248)
    }

    @Test("Unknown geometry and invalid child measurements stay finite without deleting controls")
    func invalidMeasurementIsBoundedAndEmptyRowsHaveNoHeight() {
        for width in [CGFloat.nan, .infinity, -.infinity, 0, -1] {
            let plan = AdaptiveLayoutPolicy.controlRowPlan(
                availableWidth: width,
                itemSizes: [CGSize(width: CGFloat.infinity, height: 24), CGSize(width: CGFloat.nan, height: CGFloat.infinity)],
                spacing: .nan
            )
            #expect(plan.size.width == CGFloat(AdaptiveLayoutPolicy.minimumSupportedWidth))
            #expect(plan.frames.count == 2)
            #expect(plan.frames.allSatisfy { $0.minX.isFinite && $0.minY.isFinite && $0.width.isFinite && $0.height.isFinite })
        }
        #expect(AdaptiveLayoutPolicy.controlRowPlan(availableWidth: 248, itemSizes: [], spacing: 8).size.height == 0)
    }
}
