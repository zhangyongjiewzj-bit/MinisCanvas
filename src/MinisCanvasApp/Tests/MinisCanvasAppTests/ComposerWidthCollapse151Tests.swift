import Foundation
import SwiftUI
import Testing
@testable import MinisCanvasApp

/// P3-UI-03「Composer 按宽度折叠」（lane 151）合同测试。
///
/// 验证三件事：
/// 1. 折叠裁决只消费 `AdaptiveLayoutPolicy` 的宽度类（单一策略源），
///    容器内不出现第二套数值断点；
/// 2. 折叠是溢出再挂载（`ComposerPolicyControls(chat: chat)` 两个分支都实例化），
///    不是删除控件；稳定 AX 标识符全部保留，仅新增紧凑态 locator；
/// 3. 首帧测量完成前保持内联，策略控件不会在任一时刻闪失。
///
/// 本文件只覆盖纯裁决函数与生产消费者合同；真实宽度下的视觉折叠、
/// 弹层可达性与旅程验收属于打包 App 上的 L06 独审，不在本 lane 声明。
@Suite("P3-UI-03 composer width collapse 151")
struct ComposerWidthCollapse151Tests {
    private func globalComposerSource(named name: String = "GlobalComposerView.swift") throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "src/MinisCanvasApp/Sources/MinisCanvasApp/\(name)"
            ),
            encoding: .utf8
        )
    }

    @Test("G-01：折叠按面板自身可用宽度，阈值 660 随字号缩放（面板级，不再套窗口宽度类）")
    func collapseFollowsPanelLevelThreshold() {
        #expect(GlobalComposerWidthPolicy.inlineMinimumUsableWidth == 660)
        // 默认字号下控件行实测约 622pt：600 宽面板放不下，必须折叠。
        for width in [CGFloat(0), 300, 584, 659] {
            #expect(
                GlobalComposerWidthPolicy.collapsesPolicyControls(usableWidth: width),
                "窄面板应折叠 width=\(width)"
            )
        }
        // 旧口径下 600–1099 一律折叠；面板级口径下够宽就保持内联。
        for width in [CGFloat(660), 774, 1_000, 1_280, 1_600] {
            #expect(
                !GlobalComposerWidthPolicy.collapsesPolicyControls(usableWidth: width),
                "够宽的面板应保持内联 width=\(width)"
            )
        }
        // 字号放大时控件行变宽，阈值同比放大；缩小字号不降低阈值。
        #expect(GlobalComposerWidthPolicy.collapsesPolicyControls(usableWidth: 774, contentScale: 1.5))
        #expect(!GlobalComposerWidthPolicy.collapsesPolicyControls(usableWidth: 1_000, contentScale: 1.5))
        #expect(GlobalComposerWidthPolicy.collapsesPolicyControls(usableWidth: 659, contentScale: 0.8))
    }

    @Test("容器取面板实测宽度扣内边距后交给面板级裁决，不再引用窗口宽度类")
    func containerRoutesPanelWidthToPanelPolicy() throws {
        let source = try globalComposerSource()
        #expect(source.contains("2 * ComposerLayoutMetrics.outerPadding"))
        #expect(!source.contains("AdaptiveLayoutPolicy.widthClass(for:"))
        // 数值比较只允许出现在面板级裁决这一处。
        #expect(source.components(separatedBy: "usableWidth < inlineMinimumUsableWidth").count - 1 == 1)
        #expect(!source.contains("width <"))
        #expect(!source.contains("width >"))
        #expect(!source.contains("Width >"))
    }

    @Test("选中色与插入点：对话正文与输入框都接统一陶土橙")
    func nativeTextViewsUseAccentSelection() throws {
        let theme = try globalComposerSource(named: "Theme.swift")
        #expect(theme.contains("textView.selectedTextAttributes = [.backgroundColor: selectionBackground]"))
        #expect(theme.contains("textView.insertionPointColor = accent"))
        let composer = try globalComposerSource(named: "ScrollableComposerTextView.swift")
        #expect(composer.contains("ThemeNativeTextColors.apply(to: textView)"))
        let transcript = try globalComposerSource(named: "ReadOnlyAttributedText.swift")
        #expect(transcript.contains("ThemeNativeTextColors.apply(to: textView)"))
    }

    @Test("折叠分支再挂载共享策略控件而不是删除；两个呈现分支都实例化")
    func collapsedBranchRehostsSharedPolicyControls() throws {
        let source = try globalComposerSource()
        let mount = "ComposerPolicyControls(chat: chat, modeShortcutBinding: bridge.shortcutStore.binding(for: .composerMode))"
        let mountCount = source.components(separatedBy: mount).count - 1
        #expect(mountCount == 2)
        // 折叠态的 ComposerPolicyControls 挂在溢出 popover 内（呈现位置改变，控件保留）。
        let collapseStart = try #require(
            source.range(of: "if collapsesPolicyControls {")
        ).lowerBound
        let inlineStart = try #require(
            source.range(of: "} else {", range: collapseStart..<source.endIndex)
        ).lowerBound
        let overflowBranch = source[collapseStart..<inlineStart]
        #expect(overflowBranch.contains(".popover(isPresented: $showPolicyOverflowPopover"))
        #expect(overflowBranch.contains(mount))
    }

    @Test("稳定 AX 标识符全部保留，紧凑态只新增 locator")
    func stableIdentifiersPreservedAndCompactLocatorAdded() throws {
        let source = try globalComposerSource()
        for locator in [
            ".accessibilityIdentifier(\"composer.policy\")",
            ".accessibilityIdentifier(\"composer.primary-row.global\")",
            ".accessibilityIdentifier(\"composer.model\")",
            ".accessibilityIdentifier(\"composer.attachments\")",
            ".accessibilityIdentifier(\"composer.plugins\")",
            ".accessibilityIdentifier(\"composer.credential.secure-entry\")",
            ".accessibilityIdentifier(\"composer.send\")",
            ".accessibilityIdentifier(\"composer.stop\")",
            ".accessibilityIdentifier(\"composer.global\")",
        ] {
            #expect(source.contains(locator), "既有稳定 locator 被改动: \(locator)")
        }
        // The input identity moved to the real native owner (9836d244);
        // keep the same public identifier and verify both forwarding hops.
        #expect(source.contains("inputAccessibilityIdentifier: \"composer.global.input\""))
        let native = try globalComposerSource(named: "ScrollableComposerTextView.swift")
        #expect(native.contains("inputAccessibilityIdentifier: inputAccessibilityIdentifier"))
        #expect(native.contains("scrollView.setAccessibilityIdentifier(inputAccessibilityIdentifier)"))
        // 新增：折叠触发器的紧凑态标识符与可读标签（additive，不替换 composer.policy）。
        #expect(source.contains(".accessibilityIdentifier(\"composer.policy.overflow\")"))
        #expect(source.contains(".accessibilityLabel(\"输入设置（已收起）\")"))
    }

    @Test("首帧测量前保持内联，控件不闪失")
    func unmeasuredWidthKeepsInlinePresentation() throws {
        let source = try globalComposerSource()
        #expect(source.contains("guard let composerUsableWidth else { return false }"))
        #expect(source.contains("@State private var composerUsableWidth: CGFloat?"))
    }

    // MARK: 界面细节（五组）源码合同：回退对应改动即红

    @Test("G-10：输入框聚焦信号接到外框描边，不再写死 isFocused: false")
    func composerFocusReachesSurfaceStroke() throws {
        let source = try globalComposerSource()
        #expect(source.contains("isFocused: isInputFocused"))
        #expect(!source.contains("isFocused: false"))
        let native = try globalComposerSource(named: "ScrollableComposerTextView.swift")
        #expect(native.contains("override func resignFirstResponder() -> Bool"))
        #expect(native.contains("onFocusChange?(true)"))
        #expect(native.contains("onFocusChange?(false)"))
    }

    @Test("G-02：覆盖式侧栏支持点外部与 Esc 关闭")
    func overlayPanelsDismissOnOutsideTapAndEscape() throws {
        let source = try globalComposerSource(named: "ContentView.swift")
        #expect(source.contains(".onExitCommand"))
        #expect(source.contains("dismissOverlayPanels(leftIsOverlay:"))
    }

    @Test("G-09：会话侧栏提示的快捷键读用户当前绑定，不写死")
    func sidebarShortcutHintsReadLiveBindings() throws {
        let source = try globalComposerSource(named: "ChatSidebarView.swift")
        #expect(source.contains("shortcutHint(\"新建会话\", .newSession)"))
        #expect(source.contains("shortcutHint(\"折叠会话侧栏\", .toggleSessionSidebar)"))
        #expect(!source.contains("新建会话（⌘N）"))
        #expect(!source.contains("折叠会话侧栏（⌘⇧C）"))
    }

    @Test("G-05：右栏标签读屏名与可见文字一致")
    func contextTabAccessibilityLabelMatchesVisibleText() throws {
        let source = try globalComposerSource(named: "ContextPanelView.swift")
        #expect(source.contains(".accessibilityLabel(iconOnly ? tab.title : (tab == .node ? \"上下文\" : tab == .changes ? \"改动\" : tab.title))"))
    }

    @Test("A-4：权限规则文件异常时对话页有可见提示")
    func permissionRulesFailureHasVisibleNotice() throws {
        let source = try globalComposerSource(named: "ComposerQueuedMessagesView.swift")
        #expect(source.contains("composer.permission-rules-notice"))
        #expect(source.contains("hasPrefix(\"规则文件\")"))
    }
}
