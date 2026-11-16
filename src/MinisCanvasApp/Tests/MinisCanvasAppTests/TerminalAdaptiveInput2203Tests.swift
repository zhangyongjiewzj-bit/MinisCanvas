import AppKit
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("APP14 terminal input uses shared panel allocation")
@MainActor
struct TerminalAdaptiveInput2203Tests {
    @Test(arguments: Array(TypographySettings.uiBaseFontSizeRange))
    func narrowPanelKeepsInputAndActionsReachableAtSupportedTypography(base: Int) {
        let token = TypographyTokenSet.forBaseFontSize(base)
        let inputFont = NSFont.monospacedSystemFont(ofSize: token.monospaced, weight: .regular)
        let actionFont = NSFont.systemFont(ofSize: token.caption)
        let inputWidth = ceil(("输入命令（Enter 执行）…" as NSString).size(withAttributes: [.font: inputFont]).width) + 12
        let copyWidth = ceil(("复制 pwd 回执" as NSString).size(withAttributes: [.font: actionFont]).width) + 12
        // Same order as the production row with a pwd receipt and running
        // command: caret, input, copy, stop, progress, submit.
        let items = [10, inputWidth, copyWidth, 16, 16, 18].map {
            CGSize(width: $0, height: 24)
        }
        let row = TerminalTabView.inputRowLayout
        let narrowWidth: CGFloat = 248 - 20 // global right minimum, minus the production padding
        let narrow = row.allocationPlan(availableWidth: narrowWidth, itemSizes: items)
        let wide = row.allocationPlan(availableWidth: 1_560, itemSizes: items)

        #expect(narrow.frames.count == items.count)
        #expect(Set(narrow.frames.map(\.minY)).count > 1)
        #expect(wide.frames.allSatisfy { $0.minY == 0 })
        for plan in [narrow, wide] {
            for frame in plan.frames {
                #expect(frame.minX >= 0 && frame.maxX <= plan.size.width)
                #expect(frame.minY >= 0 && frame.maxY <= plan.size.height)
            }
            for i in plan.frames.indices {
                for j in plan.frames.indices where j > i {
                    #expect(!plan.frames[i].intersects(plan.frames[j]))
                }
            }
        }
        #expect(narrow.frames.last?.width == 18)
        #expect(narrow.frames.last?.maxY == narrow.size.height)
    }
}
