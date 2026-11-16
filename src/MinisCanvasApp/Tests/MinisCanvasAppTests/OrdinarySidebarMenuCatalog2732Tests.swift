import Testing
import SwiftUI
@testable import MinisCanvasApp

@Suite("ordinary sidebar menu producer to catalog row 2732")
@MainActor
struct OrdinarySidebarMenuCatalog2732Tests {
    @Test("custom group producer supplies edit/delete assets and invokes only its selected action")
    func customGroupProducerReachesCatalogRows() throws {
        var effects: [String] = []
        let items = SessionSidebarView.customGroupMenuItems(
            rename: { effects.append("rename") }, delete: { effects.append("deleteGroup") })
        try #require(items.count == 2)
        let panel = FloatingMenuPanel(items: items) { effects.append("dismiss") }
        let rename = try #require(panel.buttonRow(for: items[0]))
        let delete = try #require(panel.buttonRow(for: items[1]))
        #expect(rename.title == "重命名组…")
        #expect(rename.role == nil)
        #expect(rename.iconPresentation == .catalog(.edit))
        #expect(delete.title == "删除组")
        #expect(delete.role == .destructive)
        #expect(delete.iconPresentation == .catalog(.delete))
        #expect(delete.catalogIconState == .danger)
        for row in [rename, delete] {
            guard case .catalog(let icon) = row.iconPresentation else {
                Issue.record("Actual group producer lost its approved icon at the production row")
                return
            }
            #expect(MinisIconView.renderSource(for: icon) == .keyline)
        }
        #expect(effects.isEmpty)
        rename.action()
        #expect(effects == ["rename", "dismiss"])
        delete.action()
        #expect(effects == ["rename", "dismiss", "deleteGroup", "dismiss"])
    }

    @Test("archived producer retains restore SF and sends deletion to its original admission action")
    func archivedProducerKeepsRestoreAndDeletionBoundaries() throws {
        var effects: [String] = []
        let items = SessionSidebarView.archivedSessionMenuItems(
            restore: { effects.append("restore") },
            delete: { effects.append("archivedDeletionAdmission") })
        try #require(items.count == 2)
        let panel = FloatingMenuPanel(items: items) { effects.append("dismiss") }
        let restore = try #require(panel.buttonRow(for: items[0]))
        let delete = try #require(panel.buttonRow(for: items[1]))
        #expect(restore.title == "恢复")
        #expect(restore.iconPresentation == .catalog(.retry))
        #expect(restore.catalogIcon == .retry)
        #expect(restore.role == nil)
        #expect(delete.title == "删除")
        #expect(delete.iconPresentation == .catalog(.delete))
        #expect(delete.role == .destructive)
        #expect(delete.catalogIconState == .danger)
        guard case .catalog(let icon) = delete.iconPresentation else {
            Issue.record("Archived delete producer did not reach the production catalog branch")
            return
        }
        #expect(MinisIconView.renderSource(for: icon) == .keyline)
        #expect(effects.isEmpty)
        delete.action()
        #expect(effects == ["archivedDeletionAdmission", "dismiss"])
        restore.action()
        #expect(effects == ["archivedDeletionAdmission", "dismiss", "restore", "dismiss"])
    }
}
