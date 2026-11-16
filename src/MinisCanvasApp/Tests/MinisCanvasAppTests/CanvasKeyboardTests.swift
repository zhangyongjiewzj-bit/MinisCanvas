import Testing
import Foundation
import CanvasCore
@testable import MinisCanvasApp

// MARK: - AJ-64/65 画布键盘焦点守卫纯逻辑单测
//
// 覆盖 CanvasKeyboardCatcher.shouldHandle 判定（纯函数，无 NSEvent 依赖）：
// ① 文本输入框焦点（isTextEditing）→ Delete/⌘C/⌘V 一律放行（不误删节点 / 复制粘贴走系统文本编辑）
// ② 无选中节点（hasSelection == false）→ Delete/⌘D/⌘C 放行（不吞事件、无效）
// ③ 有选中节点 → ⌘C 复制 / Delete/⌘D 删除 / ⌘V 粘贴
// ④ 修饰键细化：⌥/⌃/⇧ 组合 Delete（删词/删行）放行；非「纯 ⌘」组合不劫持

@Suite("AJ-64/65 画布键盘焦点守卫")
@MainActor
struct CanvasKeyboardTests {

    private typealias Action = CanvasKeyboardCatcher.CanvasKeyAction
    private typealias Mods = CanvasKeyboardCatcher.CanvasKeyModifiers

    private let deleteKeyCode: UInt16 = 51      // 裸 Delete/Backspace
    private let fnDeleteKeyCode: UInt16 = 117   // fn-Delete
    private let escKeyCode: UInt16 = 53         // Esc
    private let cKeyCode: UInt16 = 8
    private let vKeyCode: UInt16 = 9
    private let dKeyCode: UInt16 = 2
    private let zKeyCode: UInt16 = 6
    private let aKeyCode: UInt16 = 0

    // MARK: - ① 文本输入框焦点守卫（AJ-64：不误删节点；AJ-65：⌘C/⌘V 走文本编辑）

    @Test("焦点在文本输入框 + Delete → 放行，不删节点")
    func deleteWhileTextEditingIsPassedThrough() {
        #expect(CanvasKeyboardCatcher.shouldHandle(
            keyCode: deleteKeyCode, charactersIgnoringModifiers: nil,
            modifiers: Mods(), hasSelection: true, isTextEditing: true) == nil)
    }

    @Test("焦点在文本输入框 + fn-Delete → 放行")
    func fnDeleteWhileTextEditingIsPassedThrough() {
        #expect(CanvasKeyboardCatcher.shouldHandle(
            keyCode: fnDeleteKeyCode, charactersIgnoringModifiers: nil,
            modifiers: Mods(), hasSelection: true, isTextEditing: true) == nil)
    }

    @Test("焦点在文本输入框 + ⌘C → 放行（复制文本而非节点）")
    func copyWhileTextEditingIsPassedThrough() {
        #expect(CanvasKeyboardCatcher.shouldHandle(
            keyCode: cKeyCode, charactersIgnoringModifiers: "c",
            modifiers: Mods(command: true), hasSelection: true, isTextEditing: true) == nil)
    }

    @Test("焦点在文本输入框 + ⌘V → 放行（粘贴文本而非节点）")
    func pasteWhileTextEditingIsPassedThrough() {
        #expect(CanvasKeyboardCatcher.shouldHandle(
            keyCode: vKeyCode, charactersIgnoringModifiers: "v",
            modifiers: Mods(command: true), hasSelection: true, isTextEditing: true) == nil)
    }

    // MARK: - ② 无选中节点守卫（AJ-64：Delete 无效且不吞事件）

    @Test("无选中 + Delete → 放行，不触发删除")
    func deleteWithoutSelectionIsPassedThrough() {
        #expect(CanvasKeyboardCatcher.shouldHandle(
            keyCode: deleteKeyCode, charactersIgnoringModifiers: nil,
            modifiers: Mods(), hasSelection: false, isTextEditing: false) == nil)
    }

    @Test("无选中 + ⌘C → 放行，不复制")
    func copyWithoutSelectionIsPassedThrough() {
        #expect(CanvasKeyboardCatcher.shouldHandle(
            keyCode: cKeyCode, charactersIgnoringModifiers: "c",
            modifiers: Mods(command: true), hasSelection: false, isTextEditing: false) == nil)
    }

    @Test("无选中 + ⌘D → 放行，不删除")
    func commandDWithoutSelectionIsPassedThrough() {
        #expect(CanvasKeyboardCatcher.shouldHandle(
            keyCode: dKeyCode, charactersIgnoringModifiers: "d",
            modifiers: Mods(command: true), hasSelection: false, isTextEditing: false) == nil)
    }

    // MARK: - ③ 有选中节点 → 画布接管

    @Test("有选中 + ⌘C → 复制节点")
    func copyWithSelectionCopiesNode() {
        #expect(CanvasKeyboardCatcher.shouldHandle(
            keyCode: cKeyCode, charactersIgnoringModifiers: "c",
            modifiers: Mods(command: true), hasSelection: true, isTextEditing: false) == .copy)
    }

    @Test("有选中 + Delete → 删除节点")
    func deleteWithSelectionDeletesNode() {
        #expect(CanvasKeyboardCatcher.shouldHandle(
            keyCode: deleteKeyCode, charactersIgnoringModifiers: nil,
            modifiers: Mods(), hasSelection: true, isTextEditing: false) == .delete)
    }

    @Test("有选中 + fn-Delete → 删除节点")
    func fnDeleteWithSelectionDeletesNode() {
        #expect(CanvasKeyboardCatcher.shouldHandle(
            keyCode: fnDeleteKeyCode, charactersIgnoringModifiers: nil,
            modifiers: Mods(), hasSelection: true, isTextEditing: false) == .delete)
    }

    @Test("有选中 + ⌘D → 删除节点")
    func commandDWithSelectionDeletesNode() {
        #expect(CanvasKeyboardCatcher.shouldHandle(
            keyCode: dKeyCode, charactersIgnoringModifiers: "d",
            modifiers: Mods(command: true), hasSelection: true, isTextEditing: false) == .delete)
    }

    @Test("有选中 + ⌘Delete → 删除节点")
    func commandDeleteWithSelectionDeletesNode() {
        #expect(CanvasKeyboardCatcher.shouldHandle(
            keyCode: deleteKeyCode, charactersIgnoringModifiers: nil,
            modifiers: Mods(command: true), hasSelection: true, isTextEditing: false) == .delete)
    }

    @Test("⌘V 粘贴不依赖选中（画布无选中也应可粘贴节点）")
    func pasteDoesNotRequireSelection() {
        #expect(CanvasKeyboardCatcher.shouldHandle(
            keyCode: vKeyCode, charactersIgnoringModifiers: "v",
            modifiers: Mods(command: true), hasSelection: false, isTextEditing: false) == .paste)
        #expect(CanvasKeyboardCatcher.shouldHandle(
            keyCode: vKeyCode, charactersIgnoringModifiers: "v",
            modifiers: Mods(command: true), hasSelection: true, isTextEditing: false) == .paste)
    }

    // MARK: - ④ 修饰键细化（⌥/⌃/⇧ 组合放行，非「纯 ⌘」不劫持）

    @Test("⌥+Delete（删词）→ 放行，不劫持")
    func optionDeleteIsPassedThrough() {
        #expect(CanvasKeyboardCatcher.shouldHandle(
            keyCode: deleteKeyCode, charactersIgnoringModifiers: nil,
            modifiers: Mods(option: true), hasSelection: true, isTextEditing: false) == nil)
    }

    @Test("⌃+Delete（删行）→ 放行")
    func controlDeleteIsPassedThrough() {
        #expect(CanvasKeyboardCatcher.shouldHandle(
            keyCode: deleteKeyCode, charactersIgnoringModifiers: nil,
            modifiers: Mods(control: true), hasSelection: true, isTextEditing: false) == nil)
    }

    @Test("⇧+Delete（扩展选择删除）→ 放行")
    func shiftDeleteIsPassedThrough() {
        #expect(CanvasKeyboardCatcher.shouldHandle(
            keyCode: deleteKeyCode, charactersIgnoringModifiers: nil,
            modifiers: Mods(shift: true), hasSelection: true, isTextEditing: false) == nil)
    }

    @Test("⌘⇧C（非纯 ⌘）→ 放行")
    func commandShiftCIsPassedThrough() {
        #expect(CanvasKeyboardCatcher.shouldHandle(
            keyCode: cKeyCode, charactersIgnoringModifiers: "c",
            modifiers: Mods(command: true, shift: true), hasSelection: true, isTextEditing: false) == nil)
    }

    @Test("无修饰 Esc → 取消选择；⌘Esc → 放行")
    func escapeHandling() {
        #expect(CanvasKeyboardCatcher.shouldHandle(
            keyCode: escKeyCode, charactersIgnoringModifiers: nil,
            modifiers: Mods(), hasSelection: true, isTextEditing: false) == .escape)
        #expect(CanvasKeyboardCatcher.shouldHandle(
            keyCode: escKeyCode, charactersIgnoringModifiers: nil,
            modifiers: Mods(command: true), hasSelection: true, isTextEditing: false) == nil)
    }

    @Test("⌘Z 撤销 / ⌘A 全选（不依赖选中）")
    func undoAndSelectAllDoNotRequireSelection() {
        #expect(CanvasKeyboardCatcher.shouldHandle(
            keyCode: zKeyCode, charactersIgnoringModifiers: "z",
            modifiers: Mods(command: true), hasSelection: false, isTextEditing: false) == .undo)
        #expect(CanvasKeyboardCatcher.shouldHandle(
            keyCode: aKeyCode, charactersIgnoringModifiers: "a",
            modifiers: Mods(command: true), hasSelection: false, isTextEditing: false) == .selectAll)
    }

    @Test("未知 ⌘ 字符 → 放行")
    func unknownCommandKeyIsPassedThrough() {
        #expect(CanvasKeyboardCatcher.shouldHandle(
            keyCode: 3, charactersIgnoringModifiers: "f",
            modifiers: Mods(command: true), hasSelection: true, isTextEditing: false) == nil)
    }

    // MARK: - 基础判定

    @Test("isDeleteKeyCode 仅判定 51/117")
    func deleteKeyCodeDetection() {
        #expect(CanvasKeyboardCatcher.isDeleteKeyCode(51))
        #expect(CanvasKeyboardCatcher.isDeleteKeyCode(117))
        #expect(!CanvasKeyboardCatcher.isDeleteKeyCode(53))
        #expect(!CanvasKeyboardCatcher.isDeleteKeyCode(8))
    }

    @Test("CanvasKeyModifiers 纯 ⌘ / 空修饰判定")
    func pureCommandModifierDetection() {
        #expect(Mods(command: true).isPureCommand)
        #expect(!Mods(command: true, shift: true).isPureCommand)
        #expect(!Mods(command: true, option: true).isPureCommand)
        #expect(Mods().isEmpty)
        #expect(!Mods(command: true).isEmpty)
    }

    // MARK: - 键盘诊断辅助 isCanvasHotKey（RELEASED 记录判定）

    @Test("isCanvasHotKey：Delete / fn-Delete / Esc 命中")
    func canvasHotKeyDeleteAndEscape() {
        #expect(CanvasKeyboardCatcher.isCanvasHotKey(
            keyCode: deleteKeyCode, characters: nil, modifiers: Mods()))
        #expect(CanvasKeyboardCatcher.isCanvasHotKey(
            keyCode: fnDeleteKeyCode, characters: nil, modifiers: Mods()))
        #expect(CanvasKeyboardCatcher.isCanvasHotKey(
            keyCode: escKeyCode, characters: nil, modifiers: Mods()))
    }

    @Test("isCanvasHotKey：⌘C/⌘V/⌘D/⌘Z/⌘A 命中（带修饰）")
    func canvasHotKeyCommandChars() {
        #expect(CanvasKeyboardCatcher.isCanvasHotKey(
            keyCode: cKeyCode, characters: "c", modifiers: Mods(command: true)))
        #expect(CanvasKeyboardCatcher.isCanvasHotKey(
            keyCode: vKeyCode, characters: "V", modifiers: Mods(command: true)))
        #expect(CanvasKeyboardCatcher.isCanvasHotKey(
            keyCode: zKeyCode, characters: "z", modifiers: Mods(command: true)))
        #expect(CanvasKeyboardCatcher.isCanvasHotKey(
            keyCode: aKeyCode, characters: "a", modifiers: Mods(command: true)))
    }

    @Test("isCanvasHotKey：普通字符键 / 无修饰 ⌘C 不命中")
    func canvasHotKeyMisses() {
        #expect(!CanvasKeyboardCatcher.isCanvasHotKey(
            keyCode: cKeyCode, characters: "c", modifiers: Mods()))
        #expect(!CanvasKeyboardCatcher.isCanvasHotKey(
            keyCode: 0, characters: "x", modifiers: Mods(command: true)))
    }
}

// MARK: - AJ-63 文本节点内联编辑（store 层：beginInlineContentEdit 触发路径）
// 08-06 交互定案：单击节点 = 纯选中，不再自动进入内联编辑；内联编辑只从
// contentPanelTray 文本面板点击 / 双击内容编辑面板 / 右键菜单进入。
// 本组测试守护 store 层 API 本身（面板点击路径仍走 beginInlineContentEdit），
// 并新增 singleClickSelectDoesNotBeginInlineEdit 守护「单击不触发编辑」契约。

@Suite("AJ-63 文本节点内联编辑")
@MainActor
struct CanvasInlineEditStoreTests {

    @Test("文本节点 beginInlineContentEdit 进入编辑态并选中")
    func beginInlineContentEditForTextNode() {
        let store = CanvasStore()
        let node = try! #require(store.addNode(ofType: "text"))
        store.beginInlineContentEdit(nodeID: node.id)
        #expect(store.editingContentNodeID == node.id)
        #expect(store.selectedNodeIDs.contains(node.id))
    }

    @Test("非文本节点 beginInlineContentEdit 无效")
    func beginInlineContentEditIgnoresNonTextNode() {
        let store = CanvasStore()
        let node = try! #require(store.addNode(ofType: "llm"))
        store.beginInlineContentEdit(nodeID: node.id)
        #expect(store.editingContentNodeID == nil)
    }

    @Test("endInlineContentEdit 退出编辑态")
    func endInlineContentEditClearsState() {
        let store = CanvasStore()
        let node = try! #require(store.addNode(ofType: "text"))
        store.beginInlineContentEdit(nodeID: node.id)
        store.endInlineContentEdit()
        #expect(store.editingContentNodeID == nil)
    }

    // MARK: - 08-06 交互定案：单击 = 纯选中（视图层单击路径只调 selectNode，
    // 不再调 beginInlineContentEdit/pickImageFile/pickMediaFile——store 层契约守护）

    @Test("单击选中文本节点不进入内联编辑（单击=纯选中）")
    func singleClickSelectDoesNotBeginInlineEdit() {
        let store = CanvasStore()
        let node = try! #require(store.addNode(ofType: "text"))
        // 视图单击路径 = store.selectNode(id:)（纯选中）
        store.selectNode(id: node.id)
        #expect(store.selectedNodeIDs.contains(node.id), "单击=纯选中")
        #expect(store.editingContentNodeID == nil,
                "编辑只从内容面板点击/双击/右键进入，单击不弹内联编辑")
    }
}
