import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-COMMAND-04 mapped search consumes current shortcut bindings")
@MainActor
struct ShortcutMappedPaletteSearchCurrentConsumerTests {
    private func bridge(defaults: UserDefaults, shortcuts: ShortcutStore) -> BridgeStore {
        BridgeStore(shortcutStore: shortcuts, preferencesDefaults: defaults,
                    canvasFeatureLane: .phase3NonCanvas)
    }

    private func searchRow(_ id: String, in bridge: BridgeStore,
                           defaults: UserDefaults) throws -> PaletteCommand {
        let model = CommandPaletteModel(
            registry: bridge.commandRegistry, display: bridge.paletteDisplay,
            favorites: FavoriteCommandsStore(defaults: defaults)
        )
        model.updateQuery(id)
        model.refresh()
        let row = try #require(model.sections.flatMap(\.commands).first { $0.id == id })
        let menu = try #require(AppCommandMenuBuilder.command(
            id: id, registry: bridge.commandRegistry, display: bridge.paletteDisplay
        ))
        #expect(row.shortcut == menu.shortcut)
        #expect(row.isEnabled == menu.isEnabled)
        #expect(row.disabledReason == menu.disabledReason)
        return row
    }

    @Test func shortcutLabelsUseTheirActualRegisteredNamedEntryAndKeepApprovalContextBound() throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "SETTINGS29-named-entry")
        let defaults = profile.makeUserDefaults()
        defer {
            if let suite = profile.userDefaultsSuiteName { defaults.removePersistentDomain(forName: suite) }
            try? profile.cleanupDisposableRoots()
        }
        let live = bridge(defaults: defaults, shortcuts: ShortcutStore(defaults: defaults))
        let registry = live.commandRegistry
        let entries: [(ShortcutAction, String)] = [
            (.commandPalette, "ui.command.palette"), (.newSession, "session.new"),
            (.openSettings, "settings.open"), (.stopGeneration, "ui.chat.stop"),
            (.compactContext, "ui.chat.compact"), (.nextTask, "ui.taskcenter.next"),
            (.toggleSessionSidebar, "ui.sidebar.toggle"), (.toggleContextPanel, "ui.context.toggle")
        ]
        for (action, id) in entries {
            let command = try #require(registry.command(id: id))
            #expect(command.id == id)
            #expect(AppCommandCatalog.shortcutAction(forCommandID: id) == action)
            let menu = try searchRow(id, in: live, defaults: defaults)
            let slash = try #require(ComposerSlashCommandMenu.entries(matching: "/" + id,
                registry: registry).first { $0.id == id })
            #expect(slash.routedCommand?.id == command.id)
            let labels = AppCommandCatalog.shortcutSettingsLabels(for: action)
            #expect(labels.slash == "slash：/" + id)
            #expect(labels.palette == "命令面板：" + command.title)
            #expect(menu.shortcut == live.shortcutStore.binding(for: action).displayString)
        }
        for (action, id) in [(ShortcutAction.approveRequest, "ui.agent.approve"),
                             (.rejectRequest, "ui.agent.reject")] {
            let menu = try searchRow(id, in: live, defaults: defaults)
            #expect(!menu.isEnabled && menu.disabledReason == "请在当前工具审批弹窗操作")
            let slash = try #require(ComposerSlashCommandMenu.entries(matching: "/" + id,
                registry: registry).first { $0.id == id })
            #expect(slash.state == .blocked(reason: "请在当前工具审批弹窗操作"))
            #expect(AppCommandCatalog.shortcutSettingsLabels(for: action).slash
                == "slash：仅审批上下文，不能从 slash 执行")
        }
        let contextual: [(ShortcutAction, String, String)] = [
            (.mainPaneChat, "slash：无（主区聊天导航，不等同布局命令）",
             "命令面板：无（“布局：聊天独占”是不同动作）"),
            (.sendMessage, "slash：无（发送当前输入框内容）",
             "命令面板：无（需当前输入框内容与发送条件）"),
            (.focusComposer, "slash：无（聚焦当前输入框）",
             "命令面板：无（当前输入框焦点操作）"),
            (.composerMode, "slash：无（打开当前 Composer 权限模式菜单）",
             "命令面板：无（打开模式菜单，不等同 /plan）"),
            (.openShortcutReference, "slash：/shortcuts",
             "命令面板：快捷键；设置菜单：查看快捷键…"),
            (.escape, "slash：无（取消或关闭当前弹窗、输入上下文）",
             "命令面板：无（仅操作当前已挂载的取消/关闭入口）")
        ]
        let bindingsBeforeLabels = ShortcutAction.allCases.map { live.shortcutStore.binding(for: $0) }
        for (action, slashText, paletteText) in contextual {
            let labels = AppCommandCatalog.shortcutSettingsLabels(for: action)
            #expect(labels.slash == slashText)
            #expect(labels.palette == paletteText)
            #expect(!AppCommandCatalog.shortcutCommandMap.values.contains(action))
        }
        #expect(ShortcutAction.allCases.map { live.shortcutStore.binding(for: $0) } == bindingsBeforeLabels)
        // These are real registered entries, but none is the shortcut's UI
        // action. A similar title must not manufacture an executable mapping.
        #expect(registry.command(id: "ui.layout.chat")?.title == "布局：聊天独占")
        #expect(AppCommandCatalog.shortcutAction(forCommandID: "ui.layout.chat") == nil)
        #expect(registry.command(id: "plan")?.id == "plan")
        #expect(AppCommandCatalog.shortcutAction(forCommandID: "plan") == nil)
        let shortcutsCommand = try #require(registry.command(id: "shortcuts"))
        #expect(shortcutsCommand.title == "快捷键")
        #expect(shortcutsCommand.aliases == ["快捷键", "快捷键设置", "shortcuts"])
        #expect(AppCommandCatalog.shortcutAction(forCommandID: "shortcuts") == nil)
        let currentMenuState = ComposerSlashSessionState(unavailableReasonsByCommandID:
            GlobalComposer.commandReadinessReasons(registry: registry, bridge: live))
        let shortcutsSlash = try #require(ComposerSlashCommandMenu.entries(matching: "/shortcuts",
            registry: registry, sessionState: currentMenuState).first { $0.id == "shortcuts" })
        #expect(shortcutsSlash.state == .available)
        #expect(registry.command(id: "compact")?.id == "compact")
        #expect(registry.command(id: "ui.chat.compact")?.id == "ui.chat.compact")
        #expect(live.commandRegistry === registry)
        #expect(live.chat.pendingComposerCommand == nil && !live.chat.isActiveSessionStreaming)
        #expect(live.sidebarToggleCommandCount == 0 && live.contextToggleCommandCount == 0)
        #expect(live.taskCenterNextCommandCount == 0)
    }

    @Test func mappedSearchAndMenuUseReboundClearedAndReopenedStoreWithoutExecutingActions() throws {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(label: "COMMAND04-mapped-search")
        let defaults = profile.makeUserDefaults()
        let shortcuts = ShortcutStore(defaults: defaults)
        let live = bridge(defaults: defaults, shortcuts: shortcuts)
        // N06 adds a direct shortcut-reference menu action; the mapped command subset below stays separate.
        #expect(ShortcutAction.allCases.count == 22)
        #expect(Set(ShortcutAction.allCases.map(\.id)) == Set([
            "commandPalette", "mainPaneChat", "mainPaneCanvas", "toggleSessionSidebar",
            "toggleContextPanel", "sendMessage", "stopGeneration", "createPipeline",
            "openSettings", "openShortcutReference", "newSession", "compactContext",
            "runCanvas", "cancelCanvas", "toggleMiniMap", "focusComposer", "composerMode",
            "nextTask", "approveRequest", "rejectRequest", "escape", "inputHistorySearch"
        ]))
        #expect(AppCommandCatalog.shortcutCommandMap.count == 12)
        let omitted: Set<String> = ["ui.pipeline", "ui.canvas.run"]
        let active = AppCommandCatalog.shortcutCommandMap.keys.sorted().filter { !omitted.contains($0) }
        #expect(active.count == 10)
        for id in omitted {
            #expect(live.commandRegistry.command(id: id) == nil)
            #expect(live.paletteDisplay[id] == nil)
            #expect(live.commandRegistry.search(id).allSatisfy { $0.id != id })
        }
        #expect(live.canvasIfAvailable == nil)
        let sessionBefore = live.chat.activeSessionID
        let sidebarBefore = live.sidebarToggleCommandCount
        let contextBefore = live.contextToggleCommandCount
        let nextTaskBefore = live.taskCenterNextCommandCount
        let keys = Array("abcdefghij")
        for (index, id) in active.enumerated() {
            let action = try #require(AppCommandCatalog.shortcutAction(forCommandID: id))
            let original = try searchRow(id, in: live, defaults: defaults)
            #expect(original.shortcut == shortcuts.binding(for: action).displayString)
            let changed = ShortcutBinding(key: String(keys[index]), modifiers:
                ShortcutModifiers(command: true, control: true, option: true, shift: true))
            #expect(shortcuts.setBinding(changed, for: action) == nil)
            let projected = try searchRow(id, in: live, defaults: defaults)
            #expect(projected.shortcut == changed.displayString)
            #expect(projected.isEnabled == original.isEnabled)
            #expect(projected.disabledReason == original.disabledReason)
            let reopenedStore = ShortcutStore(defaults: defaults)
            let reopened = bridge(defaults: defaults, shortcuts: reopenedStore)
            #expect(reopenedStore.binding(for: action) == changed)
            #expect(try searchRow(id, in: reopened, defaults: defaults).shortcut == changed.displayString)
            let empty = ShortcutBinding(key: "", modifiers: .none)
            let requiresApprovalBinding = action == .approveRequest || action == .rejectRequest
            let expectedClearConflict: ShortcutConflict? = requiresApprovalBinding ? .approvalSafety : nil
            let expectedAfterClear = requiresApprovalBinding ? changed : empty
            #expect(shortcuts.setBinding(empty, for: action) == expectedClearConflict)
            #expect(try searchRow(id, in: live, defaults: defaults).shortcut == expectedAfterClear.displayString)
            let clearedStore = ShortcutStore(defaults: defaults)
            #expect(clearedStore.binding(for: action) == expectedAfterClear)
            #expect(try searchRow(id, in: bridge(defaults: defaults, shortcuts: clearedStore),
                                  defaults: defaults).shortcut == expectedAfterClear.displayString)
            #expect(shortcuts.reset(for: action) == nil)
            #expect(try searchRow(id, in: live, defaults: defaults).shortcut == action.defaultBinding.displayString)
        }
        for id in ["ui.agent.approve", "ui.agent.reject"] {
            let row = try searchRow(id, in: live, defaults: defaults)
            #expect(!row.isEnabled)
            #expect(row.disabledReason == "请在当前工具审批弹窗操作")
        }
        let absent = CommandPaletteModel(registry: live.commandRegistry, display: live.paletteDisplay,
                                         favorites: FavoriteCommandsStore(defaults: defaults))
        absent.updateQuery("owned-command04-no-such-command")
        absent.refresh()
        #expect(absent.sections.flatMap(\.commands).isEmpty)
        #expect(live.chat.activeSessionID == sessionBefore)
        #expect(live.sidebarToggleCommandCount == sidebarBefore)
        #expect(live.contextToggleCommandCount == contextBefore)
        #expect(live.taskCenterNextCommandCount == nextTaskBefore)
        #expect(live.canvasMutationReceipts.isEmpty)
    }
}
