import Testing
import SwiftUI
@testable import MinisCanvasApp

@Suite("ordinary floating menu catalog consumer 2719")
@MainActor
struct FloatingMenuCatalogConsumer2719Tests {
    @Test("rendered button factory propagates approved catalog IDs to real bundled layers",
          arguments: [MinisIcon.edit, .copy, .pin, .folderAdd, .folder, .link, .archive, .delete])
    func approvedButtonUsesCatalogLayers(icon: MinisIcon) throws {
        var effects: [String] = []
        let item = FloatingMenuItem(kind: .button(
            title: "合成普通菜单项", icon: icon.fallbackSystemName,
            role: icon == .delete ? .destructive : nil, help: "合成帮助") {
                effects.append("action")
            }, catalogIcon: icon)
        let panel = FloatingMenuPanel(items: [item]) { effects.append("dismiss") }
        let row = try #require(panel.buttonRow(for: item))
        // This is the exact row branch consumed by body, not an inverse SF-name map.
        guard case .catalog(let renderedIcon) = row.iconPresentation else {
            Issue.record("Production row lost its caller's typed catalog icon")
            return
        }
        #expect(renderedIcon == icon)
        #expect(MinisIconView.renderSource(for: renderedIcon) == .keyline)
        #expect(row.catalogIconState == (icon == .delete ? .danger : .normal))
        #expect(row.title == "合成普通菜单项")
        #expect(row.help == "合成帮助")
        #expect(effects.isEmpty)
        row.action()
        #expect(effects == ["action", "dismiss"])
    }

    @Test("unapproved and legacy SF callers retain their original branch without implicit mapping",
          arguments: ["plus.bubble", "pin.slash", "hand.raised", "pencil"])
    func legacyNamesRemainSystem(symbol: String) throws {
        let item = FloatingMenuItem(kind: .button(
            title: "合成旧菜单项", icon: symbol, role: nil, help: nil, action: {}))
        let panel = FloatingMenuPanel(items: [item], onPick: {})
        let row = try #require(panel.buttonRow(for: item))
        #expect(row.iconPresentation == .system(symbol))
        #expect(row.catalogIcon == nil)
        // Even a name with an existing semantic asset stays SF until its caller opts in.
        #expect(MinisIconView.renderSource(for: .edit) == .keyline)
    }

    @Test("iconless rows remain iconless and non-button items cannot invoke button actions")
    func emptyAndNonButtonRowsKeepTheirKinds() throws {
        let item = FloatingMenuItem(kind: .button(
            title: "不分组", icon: nil, role: nil, help: nil, action: {}))
        let panel = FloatingMenuPanel(items: [item], onPick: {})
        let row = try #require(panel.buttonRow(for: item))
        #expect(row.iconPresentation == .none)
        #expect(panel.buttonRow(for: .init(kind: .divider)) == nil)
        #expect(panel.buttonRow(for: .init(kind: .submenu(
            title: "组", icon: "folder", items: []), catalogIcon: .folder)) == nil)
    }
}
