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

    @Test("折叠映射与策略宽度类逐档一致：compact/medium 折叠，regular/wide 内联")
    func collapseFollowsFrozenPolicyClasses() {
        for width in [CGFloat(0), 599, 600, 799] {
            #expect(
                GlobalComposerWidthPolicy.collapsesPolicyControls(usableWidth: width),
                "compact 宽度应折叠 width=\(width)"
            )
        }
        for width in [CGFloat(800), 1_000, 1_099] {
            #expect(
                GlobalComposerWidthPolicy.collapsesPolicyControls(usableWidth: width),
                "medium 宽度应折叠 width=\(width)"
            )
        }
        for width in [CGFloat(1_100), 1_280, 1_399] {
            #expect(
                !GlobalComposerWidthPolicy.collapsesPolicyControls(usableWidth: width),
                "regular 宽度应保持内联 width=\(width)"
            )
        }
        for width in [CGFloat(1_400), 1_600] {
            #expect(
                !GlobalComposerWidthPolicy.collapsesPolicyControls(usableWidth: width),
                "wide 宽度应保持内联 width=\(width)"
            )
        }
    }

    @Test("折叠裁决与 AdaptiveLayoutPolicy 宽度类永不漂移（连续扫宽）")
    func collapseNeverDriftsFromSinglePolicySource() {
        var width = CGFloat(0)
        while width <= 2_000 {
            let expected: Bool
            switch AdaptiveLayoutPolicy.widthClass(for: Double(width)) {
            case .compact, .medium: expected = true
            case .regular, .wide: expected = false
            }
            #expect(
                GlobalComposerWidthPolicy.collapsesPolicyControls(usableWidth: width) == expected,
                "width=\(width) 折叠裁决偏离策略宽度类"
            )
            width += 5
        }
    }

    @Test("容器只经策略源取宽度类，不引入平行数值断点")
    func containerRoutesWidthThroughPolicyOnly() throws {
        let source = try globalComposerSource()
        // 单一策略源入口 + 共享 token 的几何换算（扣除两侧内边距），不是新断点。
        #expect(source.contains("AdaptiveLayoutPolicy.widthClass(for:"))
        #expect(source.contains("2 * ComposerLayoutMetrics.outerPadding"))
        // 生产容器内不得出现任何对宽度的直接数值比较（平行断点）。
        #expect(!source.contains("width <"))
        #expect(!source.contains("width >"))
        #expect(!source.contains("Width <"))
        #expect(!source.contains("Width >"))
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
        #expect(source.contains(".accessibilityLabel(\"Composer 策略控件（已折叠）\")"))
    }

    @Test("首帧测量前保持内联，控件不闪失")
    func unmeasuredWidthKeepsInlinePresentation() throws {
        let source = try globalComposerSource()
        #expect(source.contains("guard let composerUsableWidth else { return false }"))
        #expect(source.contains("@State private var composerUsableWidth: CGFloat?"))
    }
}
