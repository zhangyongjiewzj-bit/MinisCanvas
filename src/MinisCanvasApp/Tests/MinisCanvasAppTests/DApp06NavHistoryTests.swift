import Foundation
import Testing

@testable import MinisCanvasApp

/// D-APP-06（树变更批次，执行单 §5.2）：点击分段选择器应当记入导航历史。
/// 口径依据：返回按钮帮助文字“切换主视图历史”（ContentView.swift 工具栏）；
/// ⌘1/⌘2 与点击是同一用户意图。
/// 本套测试覆盖：① 纯栈迁移（分段切换后栈深度+1、索引>0 即返回按钮可点前提、
/// 前进历史截断）；② ⌘1/⌘2 回流不重复入栈（不回归）；③ goBack/goForward/
/// 恢复回流不污染；④ census §4 影响面字面对照（pushPane 保真、快捷按钮字面、
/// 返回按钮禁用条件、持久化写入）。
@Suite("D-APP-06 分段切换入导航历史")
struct DApp06NavHistoryTests {
    private func contentSource() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MinisCanvasAppTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // MinisCanvasApp
            .deletingLastPathComponent() // src
            .deletingLastPathComponent() // repository
        return try String(
            contentsOf: repositoryRoot
                .appendingPathComponent(
                    "src/MinisCanvasApp/Sources/MinisCanvasApp/ContentView.swift"
                ),
            encoding: .utf8
        )
    }

    // MARK: ① 纯栈迁移：分段切换后栈深度 +1、返回按钮可点前提

    @Test("同步态分段切换：栈深度+1 且新索引>0（返回按钮 disabled(navIndex==0) 不再成立）")
    func segmentedSwitchPushesOnce() {
        let result = MainPaneNavHistory.applyingSelection(
            stack: [.chat],
            index: 0,
            oldPane: .chat,
            newPane: .canvas
        )
        #expect(result != nil)
        if let result {
            #expect(result.stack == [.chat, .canvas])
            #expect(result.index == 1)
            // 深度 1 → 2（+1）；index>0 是返回按钮可点的唯一判据（ContentView
            // 的 .disabled(navIndex == 0) 字面由契约测试④钉住）。
            #expect(result.stack.count == 2)
            #expect(result.index > 0)
        }
    }

    @Test("连续分段切换 A→B→A：逐步入栈，不合并、不吞点击")
    func repeatedSegmentedSwitchesAccumulate() {
        var stack: [MainPane] = [.chat]
        var index = 0
        var out = MainPaneNavHistory.applyingSelection(
            stack: stack, index: index, oldPane: .chat, newPane: .canvas
        )
        #expect(out != nil)
        if let out { (stack, index) = out }
        out = MainPaneNavHistory.applyingSelection(
            stack: stack, index: index, oldPane: .canvas, newPane: .chat
        )
        #expect(out != nil)
        if let out { (stack, index) = out }
        #expect(stack == [.chat, .canvas, .chat])
        #expect(index == 2)
    }

    @Test("中段切换：截断前进历史（与 pushPane 的 Array(stack[...index]) 同型语义，census D2 前进按钮影响面）")
    func switchFromMiddleTruncatesForwardHistory() {
        let result = MainPaneNavHistory.applyingSelection(
            stack: [.chat, .canvas, .chat],
            index: 0,
            oldPane: .chat,
            newPane: .canvas
        )
        #expect(result != nil)
        if let result {
            #expect(result.stack == [.chat, .canvas])
            #expect(result.index == 1)
        }
    }

    // MARK: ② ⌘1/⌘2 路径不回归：pushPane 先入栈，回流再入被同写条件拒绝

    @Test("⌘1/⌘2 已由 pushPane 入栈后，onChange 回流不重复入栈")
    func shortcutPathDoesNotDoublePush() {
        // 复刻 pushPane(:731-737) 语义：guard 放行 → 截断+追加 → mainPane=newPane。
        // 此刻栈顶已是 newPane；随后 SwiftUI 触发 onChange(old=.chat, new=.canvas)。
        let afterPushPane: [MainPane] = [.chat, .canvas]
        let result = MainPaneNavHistory.applyingSelection(
            stack: afterPushPane,
            index: 1,
            oldPane: .chat,
            newPane: .canvas
        )
        #expect(result == nil)
    }

    @Test("oldPane == newPane 或索引非法（空栈/越界/负值）一律拒绝，不崩不误入栈")
    func invalidInputsRejected() {
        #expect(MainPaneNavHistory.applyingSelection(
            stack: [.chat], index: 0, oldPane: .chat, newPane: .chat
        ) == nil)
        #expect(MainPaneNavHistory.applyingSelection(
            stack: [], index: 0, oldPane: .chat, newPane: .canvas
        ) == nil)
        #expect(MainPaneNavHistory.applyingSelection(
            stack: [.chat], index: 5, oldPane: .chat, newPane: .canvas
        ) == nil)
        #expect(MainPaneNavHistory.applyingSelection(
            stack: [.chat], index: -1, oldPane: .chat, newPane: .canvas
        ) == nil)
    }

    // MARK: ③ goBack/goForward/恢复/不同步态回流不污染

    @Test("goBack 回流（栈顶==新值≠旧值）不再入栈")
    func goBackReentryIgnored() {
        // goBack：navIndex 2→1，mainPane = stack[1] = .canvas；
        // onChange(old=.chat 原栈顶, new=.canvas)。
        let result = MainPaneNavHistory.applyingSelection(
            stack: [.chat, .canvas, .chat],
            index: 1,
            oldPane: .chat,
            newPane: .canvas
        )
        #expect(result == nil)
    }

    @Test("goForward 回流（栈顶==新值≠旧值）不再入栈")
    func goForwardReentryIgnored() {
        // goForward：navIndex 1→2，mainPane = stack[2] = .chat；
        // onChange(old=.canvas 原栈顶, new=.chat)。
        let result = MainPaneNavHistory.applyingSelection(
            stack: [.chat, .canvas, .chat],
            index: 2,
            oldPane: .canvas,
            newPane: .chat
        )
        #expect(result == nil)
    }

    @Test("持久化恢复后回流（单元素栈、栈顶==新值≠旧值）不入栈（census :619-621 影响面）")
    func restoreReentryIgnored() {
        let result = MainPaneNavHistory.applyingSelection(
            stack: [.canvas],
            index: 0,
            oldPane: .chat,
            newPane: .canvas
        )
        #expect(result == nil)
    }

    @Test("不同步态切换（栈顶≠旧值）拒绝入栈，不把发散历史强行并入（census D1 :1022 直写场景的保守面）")
    func desynchronizedStateRejected() {
        let result = MainPaneNavHistory.applyingSelection(
            stack: [.chat],
            index: 0,
            oldPane: .canvas,
            newPane: .chat
        )
        #expect(result == nil)
    }

    // MARK: ④ census §4 影响面字面对照

    @Test("分段路径已绕开带 guard 的 pushPane：onChange 用旧值+新值经 MainPaneNavHistory 入栈并持久化")
    func onChangeNowPushesViaHistoryFunction() throws {
        let content = try contentSource()
        #expect(
            content.contains(".onChange(of: mainPane) { oldPane, newPane in"),
            "onChange 应使用双参数旧值/新值形态（D-APP-06 修复入口）"
        )
        #expect(
            content.contains("MainPaneNavHistory.applyingSelection("),
            "onChange 应调用 MainPaneNavHistory.applyingSelection 入栈"
        )
        #expect(
            content.contains("""
                    storedMainPaneRawValue = newPane.rawValue
            """),
            "入栈分支应同步持久化新值（与 pushPane :736 的 pane.rawValue 写入同型）"
        )
    }

    @Test("pushPane 本体保真：guard 与截断+追加字面不变（census D3 契约不误伤）")
    func pushPaneLiteralPreserved() throws {
        let content = try contentSource()
        #expect(content.contains("guard pane != mainPane else { return }"))
        #expect(content.contains("navStack = Array(navStack[...navIndex]) + [pane]"))
        #expect(content.contains("storedMainPaneRawValue = pane.rawValue"))
        // A7AChatLayoutConsumerTests:91 钉住的恢复路径字面不受影响。
        #expect(content.contains("navStack = [restoredPane]"))
    }

    @Test("⌘1/⌘2 隐藏按钮字面不变（GUIAccessibilityContractTests:88-89 不冲突）")
    func shortcutButtonLiteralsPreserved() throws {
        let content = try contentSource()
        #expect(content.contains("Button(\"\") { pushPane(.chat) }"))
        #expect(content.contains("Button(\"\") { pushPane(.canvas) }"))
    }

    @Test("返回按钮仍由 navIndex 判禁用、帮助文字口径原文仍在（裁定依据）")
    func backButtonContractPreserved() throws {
        let content = try contentSource()
        #expect(content.contains(".disabled(navIndex == 0)"))
        #expect(content.contains("返回（切换主视图历史）"))
    }
}
