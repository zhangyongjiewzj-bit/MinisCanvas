import Foundation
import Testing
@testable import MinisCanvasApp

@Suite("Keyline K0 coverage contract")
struct KeylineIconCoverageTests {
    private static let baselineReceiptSHA256 =
        "63161369d2621b3922ff2648370a6c035b14908c37d7bd84198f85e73827edcd"

    private static let scopedSourceFiles = [
        "src/MinisCanvasApp/Sources/MinisCanvasApp/ChatSidebarView.swift",
        "src/MinisCanvasApp/Sources/MinisCanvasApp/CommandPaletteView.swift",
        "src/MinisCanvasApp/Sources/MinisCanvasApp/ContentView.swift",
        "src/MinisCanvasApp/Sources/MinisCanvasApp/ContextPanelView.swift",
        "src/MinisCanvasApp/Sources/MinisCanvasApp/GlobalComposerView.swift",
        "src/MinisCanvasApp/Sources/MinisCanvasApp/MCPManagerView.swift",
        "src/MinisCanvasApp/Sources/MinisCanvasApp/ModelConfigPanelView.swift",
        "src/MinisCanvasApp/Sources/MinisCanvasApp/PastedTextCapsuleView.swift",
        "src/MinisCanvasApp/Sources/MinisCanvasApp/SessionDocumentWorkspaceView.swift",
        "src/MinisCanvasApp/Sources/MinisCanvasApp/SettingsView.swift",
        "src/MinisCanvasApp/Sources/MinisCanvasApp/TaskCenterObservationView.swift",
        "src/MinisCanvasApp/Sources/MinisCanvasApp/ToolEventCard.swift",
        "src/MinisCanvasApp/Sources/MinisCanvasApp/U4PluginSkillPickerView.swift",
    ]

    private static let phase4Exclusions = [
        "Label(\"执行画布\", systemImage: \"play.fill\")",
        "Label(\"自动布局\", systemImage: \"square.grid.3x3.topleft.filled\")",
        "Label(\"重置状态\", systemImage: \"arrow.counterclockwise\")",
        "Label(template.name, systemImage: template.icon)",
        "Image(systemName: \"photo.on.rectangle.angled\")",
        "Image(systemName: \"plus\")",
    ]

    private static let sfAllowlistPatterns = [
        "command.icon", "command.isFavorite",
        "cloud.icon", "provider.icon", "\"wand.and.stars\"", "statusIcon",
        "pane.icon",
        "Image(systemName: icon)", "modelStatusIcon",
        "systemImage: actionIcon", "Image(systemName: stateIcon)", "tab.icon",
        "preview.kind.icon", "FileKind(url: node.url).icon", "node.isDirectory ?",
        "Image(systemName: cloud.icon)",
        "Image(systemName: \"scope\")",
        "Label(context.statusLabel, systemImage: \"circle.fill\")",
        "Label(title, systemImage: systemImage)",
        "presentation.systemImageName",
        "Label(\"打开子会话\", systemImage: \"arrow.turn.down.right\")",
        "Label(\"子会话\", systemImage: \"arrow.turn.down.right\")",
        // ROOT 2026-09-25 #79 ruling: SettingsView.swift:4104 skippedRow status hint only.
        "Image(systemName: \"circle.slash\")",
        // C0 2026-09-30 P3-ICON-01: no matching Keyline approval-hand asset.
        // These two Task Center consumers retain the exact waiting-approval glyph.
        "Label(\"查看待审批\", systemImage: \"hand.raised\")",
        "Label(\"待审批请求\", systemImage: \"hand.raised\")",
    ]

    // Frozen existing exceptions after removing the bypass warning SF Symbol.
    // Exact path + SF identifier/dynamic expression + multiplicity; removals are welcome.
    private static let existingSFCallLimits: [String: Int] = [
        "src/MinisCanvasApp/Sources/MinisCanvasApp/ApprovalPromptCenter.swift | riskIcon": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/AssetPanelView.swift | \"arrow.left.and.right\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/AssetPanelView.swift | \"arrow.up.forward.app\"": 2,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/AssetPanelView.swift | \"checkmark.circle.fill\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/AssetPanelView.swift | \"chevron.left\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/AssetPanelView.swift | \"exclamationmark.triangle\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/AssetPanelView.swift | \"photo\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/AssetPanelView.swift | \"photo.badge.plus\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/AssetPanelView.swift | \"photo.on.rectangle.angled\"": 2,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/AssetPanelView.swift | \"play.circle.fill\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/AssetPanelView.swift | \"plus.circle\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/AssetPanelView.swift | \"plus.rectangle.on.rectangle\"": 2,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/AssetPanelView.swift | \"rectangle.split.2x1\"": 2,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/AssetPanelView.swift | \"video.badge.plus\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/AssetPanelView.swift | \"xmark\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/AssetPanelView.swift | item.kind==\"video\"?\"play.circle\":\"photo\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/CanvasView.swift | \"arrow.up.and.down\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/CanvasView.swift | \"arrow.up.left.and.arrow.down.right\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/CanvasView.swift | \"magnifyingglass\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/CanvasView.swift | \"map\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/CanvasView.swift | \"pencil\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/CanvasView.swift | \"photo.badge.plus\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/CanvasView.swift | \"photo.on.rectangle.angled\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/CanvasView.swift | \"play.circle.fill\"": 2,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/CanvasView.swift | \"play.fill\"": 2,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/CanvasView.swift | \"rectangle.inset.filled.and.person.standing\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/CanvasView.swift | \"square.grid.2x2\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/CanvasView.swift | \"stop.fill\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/CanvasView.swift | \"video.badge.plus\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/CanvasView.swift | group.isCollapsed?\"arrowtriangle.right.fill\":\"arrowtriangle.down.fill\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/ChatEmptyStateView.swift | content.isTerminal?\"exclamationmark.triangle\":\"arrow.triangle.2.circlepath\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/ChatSidebarView.swift | \"circle.fill\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/ChatSidebarView.swift | \"pencil\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/ChatSidebarView.swift | \"scope\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/ChatSidebarView.swift | presentation.systemImageName": 2,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/CommandPaletteView.swift | command.icon": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/CommandPaletteView.swift | command.isFavorite?\"star.fill\":\"star\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/ComposerCommandAdjudication059.swift | \"exclamationmark.shield\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/ContentView.swift | \"arrow.counterclockwise\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/ContentView.swift | \"photo.on.rectangle.angled\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/ContentView.swift | \"play.fill\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/ContentView.swift | \"plus\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/ContentView.swift | \"rectangle.split.3x1\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/ContentView.swift | \"square.grid.2x2\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/ContentView.swift | \"square.grid.3x3.topleft.filled\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/ContentView.swift | \"square.stack.3d.up\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/ContentView.swift | String": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/ContentView.swift | pane.icon": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/ContentView.swift | systemImage": 2,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/ContentView.swift | template.icon": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/ContextPanelView.swift | icon": 2,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/ContextPanelView.swift | node.isDirectory?\"folder\":FileKind(url:node.url).icon": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/ContextPanelView.swift | preview.kind.icon": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/ContextPanelView.swift | tab.icon": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/DesignSystem/MinisIconView.swift | String": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/DesignSystem/MinisIconView.swift | icon.fallbackSystemName": 4,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/DiagnosticExportView.swift | \"stethoscope\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/FloatingMenu.swift | icon": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/GlobalComposerView.swift | att.iconName": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/Inspector/InspectorSection.swift | icon": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/MarkdownView.swift | \"doc.on.doc\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/MarkdownView.swift | systemImage": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/MiniMapView.swift | \"xmark\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/MinisCanvasApp.swift | \"exclamationmark.triangle\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/MinisCanvasApp.swift | command.icon": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/ModelConfigPanelView.swift | cloud.icon": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/ModelConfigPanelView.swift | provider.icon": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/ModelMenuButton.swift | \"checkmark\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/ModelMenuButton.swift | icon": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/NodeChatPanelView.swift | \"arrow.up.circle.fill\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/NodeChatPanelView.swift | \"bubble.left.and.bubble.right.fill\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/NodeChatPanelView.swift | \"cpu\"": 2,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/NodeChatPanelView.swift | \"exclamationmark.triangle.fill\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/NodeChatPanelView.swift | \"power.circle.fill\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/NodeChatPanelView.swift | \"trash\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/NodeChatPanelView.swift | NodeCapability.forNodeType(node.type)==.image?\"photo\":\"video\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/NodeContentEditorView.swift | \"doc.badge.plus\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/NodeContentEditorView.swift | \"doc.on.clipboard\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/NodeContentEditorView.swift | \"exclamationmark.triangle.fill\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/NodeContentEditorView.swift | \"trash\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/NodeContentEditorView.swift | direction==\"输入\"?\"arrow.down\":\"arrow.up\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/NodeContentEditorView.swift | icon": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/NodeContentEditorView.swift | spec?.iconName??\"pencil.circle.fill\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/NodeInspectorView.swift | \"character.cursor.ibeam\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/NodeInspectorView.swift | \"gearshape\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/NodeInspectorView.swift | \"magnifyingglass.circle.fill\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/NodeInspectorView.swift | \"photo.badge.magnifyingglass\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/NodeInspectorView.swift | \"photo.fill\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/NodeInspectorView.swift | \"slider.horizontal.3\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/NodeInspectorView.swift | \"text.quote\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/NodeInspectorView.swift | \"video.fill\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/NodeInspectorView.swift | \"xmark.circle.fill\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/NodeSearchPanelView.swift | \"magnifyingglass\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/NodeSearchPanelView.swift | spec.iconName": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/NodeTextInspectorView.swift | \"arrow.up.left.and.arrow.down.right\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/NodeTextInspectorView.swift | \"square.grid.2x2\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/NodeTextInspectorView.swift | \"text.quote\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/NodeTextInspectorView.swift | \"wand.and.stars\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/NodeTextInspectorView.swift | \"xmark\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/SchedulerControlSettingsView.swift | \"calendar.badge.clock\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/SchedulerControlSettingsView.swift | \"clock\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/SessionDrafts.swift | record.succeeded?\"wrench.and.screwdriver\":\"exclamationmark.triangle\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/SettingsView.swift | \"books.vertical\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/SettingsView.swift | \"brain\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/SettingsView.swift | \"circle.slash\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/SettingsView.swift | \"doc.text\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/SettingsView.swift | \"terminal\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/SettingsView.swift | actionIcon": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/SettingsView.swift | stateIcon": 2,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/StoryboardDetailView.swift | \"play.rectangle\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/StoryboardWorkbenchView.swift | \"arrow.triangle.branch\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/StoryboardWorkbenchView.swift | \"doc.plaintext\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/StoryboardWorkbenchView.swift | \"film\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/StoryboardWorkbenchView.swift | \"plus\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/StoryboardWorkbenchView.swift | \"rectangle.split.3x1\"": 3,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/StoryboardWorkbenchView.swift | \"square.and.arrow.up\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/StoryboardWorkbenchView.swift | \"text.quote\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/StoryboardWorkbenchView.swift | \"xmark\"": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/TaskCenterObservationView.swift | \"arrow.turn.down.right\"": 2,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/TaskCenterObservationView.swift | \"hand.raised\"": 2,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/TaskCenterObservationView.swift | action.systemImage": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/TaskCenterObservationView.swift | name": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/TaskCenterObservationView.swift | statusIcon": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/TaskCenterObservationView.swift | systemImage": 2,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/ToolEventCard.swift | iconName(for:event)": 1,
        "src/MinisCanvasApp/Sources/MinisCanvasApp/U4PluginSkillPickerView.swift | \"wand.and.stars\"": 1,
    ]

    @Test("SF Symbol exceptions cannot grow anywhere in UI sources")
    func sfSymbolExceptionsDoNotGrow() throws {
        let root = repositoryRoot()
        let sources = root.appendingPathComponent("src/MinisCanvasApp/Sources")
        let files = try #require(FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: [.isRegularFileKey]
        ))
        var observed: [String: Int] = [:]
        for case let file as URL in files where file.pathExtension == "swift" {
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let path = String(file.path.dropFirst(root.path.count + 1))
            let source = try String(contentsOf: file, encoding: .utf8)
            for call in Self.directSFCalls(in: source, allNamedCalls: true) {
                observed["\(path) | \(call)", default: 0] += 1
            }
        }
        #expect(!observed.isEmpty, "UI source inventory must be readable and nonempty")
        for (call, count) in observed {
            #expect(count <= Self.existingSFCallLimits[call, default: 0], "new or duplicated SF Symbol exception: \(call)")
        }
    }

    @Test("K0 has a complete compile-time mapping")
    func mappingIsComplete() {
        let mapped = Set(MinisIcon.allCases.map(\.upstreamFilename))
        #expect(mapped.count == MinisIcon.allCases.count)
        #expect(MinisIcon.allCases.allSatisfy { $0.assetName == $0.rawValue })
    }

    @Test("duotone token contract is fixed")
    func duotoneTokensAreFixed() {
        #expect(MinisIconTokens.secondaryOpacity == 0.24)
        #expect(MinisIconTokens.activeSecondaryOpacity == 0.26)
        #expect(MinisIconTokens.disabledOpacity == 0.38)
        #expect(MinisIconTokens.defaultSize == 16)
        #expect(MinisIconTokens.smallSize == 12)
        #expect(MinisIconTokens.largeSize == 20)
    }

    @Test("task recovery warning keeps its status label with a semantic icon")
    func taskRecoveryWarningIsSemantic() throws {
        let task = try String(
            contentsOf: repositoryRoot().appendingPathComponent(
                "src/MinisCanvasApp/Sources/MinisCanvasApp/TaskCenterObservationView.swift"
            ),
            encoding: .utf8
        )
        #expect(task.contains("MinisIconView(.warning, size: 12)"))
        #expect(task.contains(".accessibilityLabel(recoveryTitle)"))
        #expect(!task.contains("Label(recoveryTitle, systemImage: \"exclamationmark.triangle\")"))
    }

    @Test("scope is exactly 13 unique readable UTF-8 consumer sources")
    func exactScopeAndBaselineReceipt() throws {
        #expect(Self.scopedSourceFiles.count == 13)
        #expect(Set(Self.scopedSourceFiles).count == 13)
        #expect(Self.baselineReceiptSHA256.count == 64)

        let root = repositoryRoot()
        for path in Self.scopedSourceFiles {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            #expect(!source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @Test("phase4 exclusions and final SF fallback allowlist are exact")
    func exclusionsAndFallbackAllowlist() throws {
        let source = try scopedSource()
        for fragment in Self.phase4Exclusions {
            #expect(source.contains(fragment), "missing phase4 exclusion: \(fragment)")
        }
        for pattern in Self.sfAllowlistPatterns {
            #expect(source.contains(pattern), "missing SF allowlist pattern: \(pattern)")
        }
        #expect(Self.phase4Exclusions.count == 6)
        #expect(Self.sfAllowlistPatterns.count == 25)
    }

    @Test("approval-hand fallback is confined to two reviewed Task Center consumers")
    func taskApprovalFallbackIsPreciselyScoped() throws {
        let task = try String(
            contentsOf: repositoryRoot().appendingPathComponent(
                "src/MinisCanvasApp/Sources/MinisCanvasApp/TaskCenterObservationView.swift"
            ),
            encoding: .utf8
        )
        let link = "Label(\"查看待审批\", systemImage: \"hand.raised\")"
        let heading = "Label(\"待审批请求\", systemImage: \"hand.raised\")"
        #expect(task.components(separatedBy: link).count == 2)
        #expect(task.components(separatedBy: heading).count == 2)

        let linkStart = try #require(task.range(of: "let approvalNavigation = childTranscriptConsumer.approvalNavigation("))
        let linkEnd = try #require(task.range(
            of: "if let succeededBacklink",
            range: linkStart.upperBound..<task.endIndex
        ))
        #expect(task[linkStart.lowerBound..<linkEnd.lowerBound].contains(link))

        let detailStart = try #require(task.range(of: "private struct TaskCenterApprovalDetailView: View"))
        let detailEnd = try #require(task.range(
            of: "TimelineView(.periodic",
            range: detailStart.upperBound..<task.endIndex
        ))
        #expect(task[detailStart.lowerBound..<detailEnd.lowerBound].contains(heading))
    }

    @Test("current source lines satisfy the exact 80/20 contract")
    func coverageArithmetic() throws {
        let source = try scopedSource()
        let keylineCalls = source.components(separatedBy: "MinisIconView(").count - 1
        // TASK3013 added the reviewed MCP caret; ARCH3 adds the privacy lock.
        // Goal18 G-1 adds four Keyline icons in the child-deletion auto-review settings section
        // (folderAdd x2, database, remove); no SF Symbol was added, so the ratio only improves.
        // Keyline A moves reviewed display consumers into existing catalog icons.
        // Counts are source inventory, not render or package evidence.
        // Goal20 preserves the new unattended-approval status with a Keyline pause.
        // SwiftTerm replaces the old terminal's warning, prompt caret, stop,
        // and send Keyline calls. The new PTY toolbar uses text buttons.
        // 1419 adds one existing Keyline target icon in the Goal bar.
        // 第三波：对话失败行的“重试”改用 Keyline retry，另有一处新增 Keyline 图标；
        // “检查 API Key”“压缩后重试”改为纯文字按钮，没有新增 SF Symbol。
        // 终端多标签（11/18）：标签栏“新建”“关闭”用 Keyline add/close，各 +1，没有新增 SF Symbol。
        // A7-A 对话操作行（11/18）：消息“复制”改图标按钮 MinisIconView(.copy)、“⋯”改 MinisIconView(.more)，各 +1；
        // 会话失败标记换用 .info（原地替换，不增减），没有新增 SF Symbol。
        // 历史审查补修（11/18）：重新生成按钮加 refresh、记忆读取失败用 warning、目标待办清除等界面
        // 新增 Keyline 图标共 +4，都是 MinisIconView，没有新增 SF Symbol。
        // 包上旅程发现下拉菜单按钮会把 copy/more 图标压成黑色剪影，这两处改回文字标签（-2）。
        // 目标详情折叠（11/19）：输入框上方目标栏加展开/收起箭头 caretDown/caretRight（+1），没有新增 SF Symbol。
        #expect(keylineCalls == 196)

        // Preserve the same 13-file scope and exclusions, but count complete
        // constructors: the old per-line scan silently missed multiline Label.
        let directLines = Self.directSFCalls(in: source)
        let excludedLines = directLines.filter { line in
            Self.phase4Exclusions.contains { line.contains($0) }
        }
        let nonExcludedLines = directLines.filter { line in
            !Self.phase4Exclusions.contains { line.contains($0) }
        }
        let allowlistedLines = nonExcludedLines.filter { line in
            Self.sfAllowlistPatterns.contains { line.contains($0) }
        }

        #expect(directLines.count == 32)
        #expect(excludedLines.count == 6)
        #expect(nonExcludedLines.count == 26)
        #expect(allowlistedLines.count == 26)
        for line in nonExcludedLines {
            #expect(
                Self.sfAllowlistPatterns.contains { line.contains($0) },
                "unreviewed SF call: \(line.trimmingCharacters(in: .whitespaces))"
            )
        }

        // Count unresolved SF calls in the ratio too; otherwise an
        // unallowlisted regression artificially improves Keyline coverage.
        let denominator = keylineCalls + nonExcludedLines.count
        // Same 13-file scope: prior icons plus reviewed Keyline A display changes.
        #expect(denominator == 222)
        #expect(Double(keylineCalls) / Double(denominator) >= 0.80)
        #expect(Double(nonExcludedLines.count) / Double(denominator) <= 0.20)
    }

    @Test("semantic icons use a fixed clipped canvas")
    func semanticIconsUseFixedCanvas() throws {
        let source = try String(
            contentsOf: repositoryRoot().appendingPathComponent(
                "src/MinisCanvasApp/Sources/MinisCanvasApp/DesignSystem/MinisIconView.swift"
            ),
            encoding: .utf8
        )
        #expect(source.contains(".fixedSize(horizontal: true, vertical: true)"))
        #expect(source.contains(".clipped()"))
    }

    @Test("multiline SF constructors cannot disappear from the denominator or allowlist audit")
    func multilineFallbackIsCounted() {
        let source = #"""
        Label(
            "future status",
            systemImage: "unreviewed.future.status"
        )
        // Label("comment", systemImage: "not-a-call")
        let text = "Image(systemName: not-a-call)"
        Image(systemName: "scope")
        """#
        let calls = Self.directSFCalls(in: source)
        #expect(calls.count == 2)
        #expect(calls[0].contains("unreviewed.future.status"))
        #expect(!Self.sfAllowlistPatterns.contains { calls[0].contains($0) })
        #expect(Self.sfAllowlistPatterns.contains { calls[1].contains($0) })
    }

    @Test("global SF guard includes custom wrappers, AppKit, whitespace and duplicate calls")
    func globalSFGuardRecognizesCallForms() {
        let source = #"""
        BubbleActionButton(title: "new", systemImage : "new.symbol")
        NSImage(systemSymbolName: "new.symbol", accessibilityDescription: nil)
        Image(
            systemName : "new.symbol"
        )
        Image(systemName: "scope")
        Image(systemName: "scope")
        // Image(systemName: "comment")
        let text = "Image(systemName: not-a-call)"
        """#
        let calls = Self.directSFCalls(in: source, allNamedCalls: true)
        #expect(calls.count == 5)
        #expect(calls.filter { $0 == "\"scope\"" }.count == 2)
        #expect(calls.filter { $0 == "\"new.symbol\"" }.count == 3)
        #expect(!calls.contains { $0.contains("comment") || $0.contains("not-a-call") })
    }

    /// Lexical constructor scan equivalent to the existing full inventory;
    /// comments/strings are masked, while UTF-16 offsets preserve source ranges.
    private static func directSFCalls(in source: String, allNamedCalls: Bool = false) -> [String] {
        let input = Array(source.utf16)
        var mask = input
        var i = 0, blockDepth = 0
        var inString = false
        while i < input.count {
            let c = input[i]
            let next: UInt16 = i + 1 < input.count ? input[i + 1] : 0
            if blockDepth > 0 {
                if c == 47 && next == 42 { mask[i] = 32; mask[i + 1] = 32; blockDepth += 1; i += 2 }
                else if c == 42 && next == 47 { mask[i] = 32; mask[i + 1] = 32; blockDepth -= 1; i += 2 }
                else { if c != 10 { mask[i] = 32 }; i += 1 }
            } else if inString {
                if c == 92 && i + 1 < input.count { mask[i] = 32; mask[i + 1] = 32; i += 2 }
                else { if c != 10 { mask[i] = 32 }; if c == 34 { inString = false }; i += 1 }
            } else if c == 47 && next == 47 {
                while i < input.count && input[i] != 10 { mask[i] = 32; i += 1 }
            } else if c == 47 && next == 42 {
                mask[i] = 32; mask[i + 1] = 32; blockDepth = 1; i += 2
            } else if c == 34 { mask[i] = 32; inString = true; i += 1 }
            else { i += 1 }
        }
        let masked = String(decoding: mask, as: UTF16.self)
        let pattern = try! NSRegularExpression(pattern: allNamedCalls
            ? #"\b[A-Za-z_][A-Za-z_0-9]*\s*\("#
            : #"\b(?:Image|Label|Button)\s*\("#)
        let original = source as NSString
        return pattern.matches(in: masked, range: NSRange(location: 0, length: mask.count)).compactMap { match in
            let opening = match.range.location + match.range.length - 1
            var end = opening + 1, depth = 1
            while end < mask.count && depth > 0 {
                if mask[end] == 40 { depth += 1 }
                if mask[end] == 41 { depth -= 1 }
                end += 1
            }
            guard depth == 0 else { return nil }
            var argumentMask = Array(mask[(opening + 1)..<(end - 1)])
            if allNamedCalls {
                var nestedDepth = 0
                for index in argumentMask.indices {
                    let value = argumentMask[index]
                    if value == 40 { nestedDepth += 1 }
                    if nestedDepth > 0 { argumentMask[index] = 32 }
                    if value == 41 { nestedDepth -= 1 }
                }
            }
            let args = String(decoding: argumentMask, as: UTF16.self)
            let hasSFArgument: Bool
            if allNamedCalls {
                hasSFArgument = args.range(
                    of: #"\b(?:systemName|systemImage|systemSymbolName)\s*:"#,
                    options: .regularExpression
                ) != nil
            } else {
                hasSFArgument = args.contains("systemName:") || args.contains("systemImage:")
            }
            guard hasSFArgument else { return nil }
            if allNamedCalls {
                let label = try! NSRegularExpression(pattern: #"\b(?:systemName|systemImage|systemSymbolName)\s*:"#)
                guard let match = label.firstMatch(in: args, range: NSRange(location: 0, length: argumentMask.count)) else { return nil }
                let start = match.range.location + match.range.length
                let stop = argumentMask[start...].firstIndex(of: 44) ?? argumentMask.count
                // The top-level mask ignores nested commas and argument ordering.
                // Whitespace is immaterial to the frozen SF name/dynamic expression.
                return original.substring(with: NSRange(location: opening + 1 + start, length: stop - start))
                    .components(separatedBy: .whitespacesAndNewlines).joined()
            }
            return original.substring(with: NSRange(location: match.range.location, length: end - match.range.location))
                .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    private func scopedSource() throws -> String {
        let root = repositoryRoot()
        return try Self.scopedSourceFiles
            .map { try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }
            .joined(separator: "\n")
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
