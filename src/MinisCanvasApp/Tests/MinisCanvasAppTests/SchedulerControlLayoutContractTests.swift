import Foundation
import Testing
@testable import MinisCanvasApp

/// Field defect (C84 supplementary window): at the minimum settings width the
/// scheduler page squeezed its detail pane to ~40pt, so the placeholder wrapped
/// one glyph per line and the delete confirmation button shrank to 11pt.
/// Contract pinned here: inside the narrowest supported settings content area
/// the task list may shrink and the detail pane keeps a usable minimum width.
/// The live AX width of `scheduler.delete.confirm` is checked on the package.
@Suite("Scheduler settings two-column layout contract")
struct SchedulerControlLayoutContractTests {
    private static let narrowestContentWidth: CGFloat =
        SettingsLayoutPolicy.minimumSupportedWidth - SettingsLayoutPolicy.compactSidebarWidth - 1

    @Test("both columns fit the narrowest settings content area with the divider")
    func columnsFitNarrowestContentArea() {
        let layout = SchedulerControlSettingsView.ColumnLayout.self
        #expect(layout.taskListMinWidth + layout.dividerWidth + layout.detailMinWidth <= Self.narrowestContentWidth)
    }

    @Test("detail pane keeps room for the delete confirmation and placeholder")
    func detailPaneHasUsableMinimumWidth() {
        let layout = SchedulerControlSettingsView.ColumnLayout.self
        #expect(layout.detailMinWidth >= 220)
        #expect(layout.taskListMinWidth >= 160)
        #expect(layout.taskListIdealWidth >= layout.taskListMinWidth)
    }
}
