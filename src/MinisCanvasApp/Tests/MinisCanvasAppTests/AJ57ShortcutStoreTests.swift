import Testing
import Foundation
import SwiftUI
import MinisCore
@testable import MinisCanvasApp

// MARK: - AJ-57 快捷键设置测试
//
// 覆盖：① 默认值表（= 现有硬编码快捷键）② UserDefaults 持久化（writer/reader 新实例）
// ③ 冲突检测（动作冲突 / 系统保留）④ reset / resetAll ⑤ 展示字符串与 KeyEquivalent
// ⑥ keyName 规范化 ⑦ 命令面板徽标动态同步（BridgeStore.paletteDisplay）。

@Suite("AJ-57 快捷键设置")
@MainActor
struct AJ57ShortcutStoreTests {

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "AJ-57-\(UUID().uuidString)")!
    }

    private func makeStore(_ defaults: UserDefaults) -> ShortcutStore {
        ShortcutStore(defaults: defaults)
    }

    @Test func frozenCanvasDefaultsReleaseCommandPAndR() {
        let store = makeStore(makeDefaults())
        #expect(store.conflict(for: .newSession, to: ShortcutBinding(key: "p", modifiers: ShortcutModifiers.command)) == nil)
        #expect(store.conflict(for: .newSession, to: ShortcutBinding(key: "r", modifiers: ShortcutModifiers.command)) == nil)
    }

    // MARK: ① 默认值表

    @Test func defaultBindingsMatchExistingShortcuts() {
        let store = makeStore(makeDefaults())
        #expect(ShortcutAction.allCases.count == 22)
        #expect(Set(ShortcutAction.allCases.map(\.id)) == Set([
            "commandPalette", "mainPaneChat", "mainPaneCanvas", "toggleSessionSidebar",
            "toggleContextPanel", "sendMessage", "stopGeneration", "createPipeline",
            "openSettings", "openShortcutReference", "newSession", "compactContext", "runCanvas", "cancelCanvas",
            "toggleMiniMap", "focusComposer", "composerMode", "nextTask", "approveRequest", "rejectRequest",
            "escape", "inputHistorySearch"
        ]))
        // 现有硬编码快捷键应保留为默认值
        #expect(store.binding(for: .commandPalette) == ShortcutBinding(key: "k", modifiers: ShortcutModifiers.command))
        #expect(store.binding(for: .mainPaneChat) == ShortcutBinding(key: "1", modifiers: ShortcutModifiers.command))
        #expect(store.binding(for: .mainPaneCanvas) == ShortcutBinding(key: "2", modifiers: ShortcutModifiers.command))
        // 2026-08-06：mainPaneDocuments（⌘3 主区：工作）随工作板块移除
        #expect(store.binding(for: .createPipeline).isEmpty)
        #expect(store.binding(for: .toggleSessionSidebar) == ShortcutBinding(key: "c", modifiers: ShortcutModifiers.commandShift))
        #expect(store.binding(for: .toggleContextPanel) == ShortcutBinding(key: "rightArrow", modifiers: ShortcutModifiers.optionCommand))
        #expect(store.binding(for: .sendMessage) == ShortcutBinding(key: "return", modifiers: ShortcutModifiers.command))
        #expect(store.binding(for: .stopGeneration) == ShortcutBinding(key: ".", modifiers: ShortcutModifiers.command))
        #expect(store.binding(for: .openSettings) == ShortcutBinding(key: ",", modifiers: ShortcutModifiers.command))
        // N06 default is independently pinned; it is not derived from defaultBinding.
        #expect(store.binding(for: .openShortcutReference) == ShortcutBinding(key: "/", modifiers: ShortcutModifiers.command))
        #expect(store.binding(for: .newSession) == ShortcutBinding(key: "n", modifiers: ShortcutModifiers.command))
        #expect(store.binding(for: .runCanvas).isEmpty)
        #expect(store.binding(for: .cancelCanvas) == ShortcutBinding(key: ".", modifiers: ShortcutModifiers.commandShift))
        #expect(store.binding(for: .toggleMiniMap).isEmpty)
        #expect(store.binding(for: .focusComposer) == ShortcutBinding(key: "l", modifiers: ShortcutModifiers.command))
        #expect(store.binding(for: .nextTask) == ShortcutBinding(key: "j", modifiers: ShortcutModifiers.command))
        #expect(store.binding(for: .approveRequest) == ShortcutBinding(key: "y", modifiers: ShortcutModifiers.command))
        #expect(store.binding(for: .rejectRequest) == ShortcutBinding(key: "y", modifiers: ShortcutModifiers.commandShift))
        #expect(store.binding(for: .escape).isEmpty)
    }

    @Test func registeredCommandConsumersUseTheSharedActions() {
        #expect(AppCommandCatalog.shortcutAction(forCommandID: "ui.canvas.run") == .runCanvas)
        #expect(AppCommandCatalog.shortcutAction(forCommandID: "ui.agent.approve") == .approveRequest)
        #expect(AppCommandCatalog.shortcutAction(forCommandID: "ui.agent.reject") == .rejectRequest)
    }

    // MARK: ② UserDefaults 持久化

    @Test func setBindingPersistsAcrossInstances() {
        let defaults = makeDefaults()
        let writer = makeStore(defaults)
        let newBinding = ShortcutBinding(key: "g", modifiers: ShortcutModifiers.command)
        let conflict = writer.setBinding(newBinding, for: .createPipeline)
        #expect(conflict == nil)
        #expect(writer.binding(for: .createPipeline) == newBinding)

        // 新实例（同一 UserDefaults suite）读到同一份绑定 → 真持久化
        let reader = makeStore(defaults)
        #expect(reader.binding(for: .createPipeline) == newBinding)
        // 未覆盖的动作仍回落默认值
        #expect(reader.binding(for: .commandPalette) == ShortcutAction.commandPalette.defaultBinding)
    }

    @Test func resetAndResetAllRestoreDefaults() {
        let defaults = makeDefaults()
        let store = makeStore(defaults)
        store.setBinding(ShortcutBinding(key: "g", modifiers: ShortcutModifiers.command), for: .createPipeline)
        store.setBinding(ShortcutBinding(key: "t", modifiers: ShortcutModifiers.command), for: .newSession)
        #expect(store.binding(for: .createPipeline) != ShortcutAction.createPipeline.defaultBinding)

        store.reset(for: .createPipeline)
        #expect(store.binding(for: .createPipeline) == ShortcutAction.createPipeline.defaultBinding)
        #expect(store.binding(for: .newSession) != ShortcutAction.newSession.defaultBinding)

        store.resetAll()
        for action in ShortcutAction.allCases {
            #expect(store.binding(for: action) == action.defaultBinding)
        }
    }

    // MARK: ③ 冲突检测

    @Test func conflictWhenTwoActionsShareBinding() {
        let store = makeStore(makeDefaults())
        // 把「新建会话」改成 ⌘1（与「主区：聊天」默认撞键）
        let conflict = store.setBinding(ShortcutBinding(key: "1", modifiers: ShortcutModifiers.command), for: .newSession)
        #expect(conflict == .action(.mainPaneChat))
        #expect(store.binding(for: .newSession) == ShortcutAction.newSession.defaultBinding, "冲突时不写入，保持原绑定")
    }

    @Test func commandReturnHasOneOwnerAndDuplicateBindingNeverPersists() throws {
        let suite = "AJ-57-command-return-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = makeStore(defaults)
        let commandReturn = ShortcutBinding(key: "return", modifiers: ShortcutModifiers.command)
        #expect(store.binding(for: .sendMessage) == commandReturn)
        #expect(ShortcutAction.allCases.filter { store.binding(for: $0) == commandReturn } == [.sendMessage])
        #expect(store.conflict(for: .sendMessage, to: commandReturn) == nil)
        let original = store.binding(for: .newSession)
        #expect(store.conflict(for: .newSession, to: commandReturn) == .action(.sendMessage))
        #expect(store.setBinding(commandReturn, for: .newSession) == .action(.sendMessage))
        #expect(store.binding(for: .newSession) == original)
        #expect(makeStore(defaults).binding(for: .newSession) == original)
        #expect(makeStore(defaults).binding(for: .sendMessage) == commandReturn)
        let available = ShortcutBinding(key: "g", modifiers: ShortcutModifiers.command)
        #expect(store.setBinding(available, for: .newSession) == nil)
        #expect(makeStore(defaults).binding(for: .newSession) == available)
        #expect(store.setBinding(commandReturn, for: .newSession) == .action(.sendMessage))
        #expect(makeStore(defaults).binding(for: .newSession) == available)
        #expect(store.binding(for: .sendMessage) == commandReturn)
    }

    @Test func conflictWithSystemReservedShortcut() {
        let store = makeStore(makeDefaults())
        // ⌘Space = Spotlight 系统保留
        let conflict = store.setBinding(ShortcutBinding(key: "space", modifiers: ShortcutModifiers.command), for: .createPipeline)
        #expect(conflict == .system)
        #expect(store.binding(for: .createPipeline) == ShortcutAction.createPipeline.defaultBinding)
    }

    @Test func noConflictForUniqueBinding() {
        let store = makeStore(makeDefaults())
        let conflict = store.setBinding(ShortcutBinding(key: "g", modifiers: ShortcutModifiers.command), for: .createPipeline)
        #expect(conflict == nil)
    }

    @Test func emptyBindingAllowedAsDisable() {
        let store = makeStore(makeDefaults())
        let empty = ShortcutBinding(key: "", modifiers: ShortcutModifiers.none)
        #expect(empty.isEmpty)
        // 禁用（空绑定）不触发冲突
        let conflict = store.setBinding(empty, for: .createPipeline)
        #expect(conflict == nil)
        #expect(store.binding(for: .createPipeline) == empty)
    }

    // MARK: ④ 展示字符串 / KeyEquivalent

    @Test func displayStringFormatsModifiers() {
        #expect(ShortcutBinding(key: "p", modifiers: ShortcutModifiers.command).displayString == "⌘P")
        #expect(ShortcutBinding(key: "c", modifiers: ShortcutModifiers.commandShift).displayString == "⇧⌘C")
        #expect(ShortcutBinding(key: "rightArrow", modifiers: ShortcutModifiers.optionCommand).displayString == "⌥⌘→")
        #expect(ShortcutBinding(key: "return", modifiers: ShortcutModifiers.command).displayString == "⌘⏎")
        #expect(ShortcutBinding(key: "space", modifiers: ShortcutModifiers.control).displayString == "⌃空格")
        #expect(ShortcutBinding(key: "", modifiers: ShortcutModifiers.none).displayString == "无")
    }

    @Test func keyEquivalentMapsSpecialKeys() {
        #expect(ShortcutBinding(key: "p", modifiers: ShortcutModifiers.command).keyEquivalent == KeyEquivalent("p"))
        #expect(ShortcutBinding(key: "return", modifiers: ShortcutModifiers.command).keyEquivalent == .return)
        #expect(ShortcutBinding(key: "rightArrow", modifiers: ShortcutModifiers.optionCommand).keyEquivalent == .rightArrow)
        #expect(ShortcutBinding(key: "space", modifiers: ShortcutModifiers.control).keyEquivalent == KeyEquivalent(" "))
    }

    @Test func modifierFlagsMapToEventModifiers() {
        let mods = ShortcutModifiers(command: true, shift: true)
        var expected: EventModifiers = [.command, .shift]
        #expect(mods.eventModifiers == expected)
        expected = [.command]
        #expect(ShortcutModifiers.command.eventModifiers == expected)
    }

    // MARK: ⑤ keyName 规范化

    @Test func keyNameMapsKeyCodes() {
        #expect(ShortcutBinding.keyName(fromKeyCode: 49, charactersIgnoringModifiers: " ") == "space")
        #expect(ShortcutBinding.keyName(fromKeyCode: 36, charactersIgnoringModifiers: "\r") == "return")
        #expect(ShortcutBinding.keyName(fromKeyCode: 124, charactersIgnoringModifiers: nil) == "rightArrow")
        #expect(ShortcutBinding.keyName(fromKeyCode: 53, charactersIgnoringModifiers: "\u{1B}") == "escape")
        #expect(ShortcutBinding.keyName(fromKeyCode: 0, charactersIgnoringModifiers: "A") == "a")
        #expect(ShortcutBinding.keyName(fromKeyCode: 0, charactersIgnoringModifiers: nil) == "?")
    }

    // MARK: ⑥ 命令面板徽标动态同步

    @Test func paletteDisplayReflectsCustomShortcut() {
        let defaults = makeDefaults()
        let writer = makeStore(defaults)
        let pipelineBinding = ShortcutBinding(key: "p", modifiers: ShortcutModifiers.command)
        let canvasBinding = ShortcutBinding(key: "r", modifiers: ShortcutModifiers.command)
        // P10 releases fresh-profile defaults; explicit saved user choices still win.
        #expect(writer.setBinding(pipelineBinding, for: .createPipeline) == nil)
        #expect(writer.setBinding(canvasBinding, for: .runCanvas) == nil)
        let store = makeStore(defaults)
        #expect(store.binding(for: .createPipeline) == pipelineBinding)
        #expect(store.binding(for: .runCanvas) == canvasBinding)
        let bridge = BridgeStore(shortcutStore: store)

        // 已保存的用户选择：ui.pipeline 徽标 = ⌘P
        let defaultBadge = bridge.paletteDisplay["ui.pipeline"]?.shortcut
        #expect(defaultBadge == "⌘P")

        // 用户将已存的 ⌘P 改为 ⌘G，徽标应同步
        store.setBinding(ShortcutBinding(key: "g", modifiers: ShortcutModifiers.command), for: .createPipeline)
        let updatedBadge = bridge.paletteDisplay["ui.pipeline"]?.shortcut
        #expect(updatedBadge == "⌘G")
        // 已注册的画布命令也从同一 ShortcutStore 读取徽标。
        #expect(bridge.paletteDisplay["ui.canvas.run"]?.shortcut == "⌘R")
    }

    @Test func displayInfoCarriesShortcutBadgesForMappedCommands() {
        let store = makeStore(makeDefaults())
        // Seed an explicit user choice for the deferred command; active defaults remain unchanged.
        #expect(store.setBinding(ShortcutBinding(key: "p", modifiers: ShortcutModifiers.command), for: .createPipeline) == nil)
        let bridge = BridgeStore(shortcutStore: store)
        // 映射徽标采用活跃命令默认值或明确保存的用户选择
        #expect(bridge.paletteDisplay["session.new"]?.shortcut == "⌘N")
        #expect(bridge.paletteDisplay["settings.open"]?.shortcut == "⌘,")
        #expect(bridge.paletteDisplay["ui.pipeline"]?.shortcut == "⌘P")
    }
}
