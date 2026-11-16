import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - 波4 右栏 tab 容器化
//
// 覆盖：右栏 ContextPanelView 改为 tab 容器
// ① ContextTab 枚举：节点/聊天 · 文件 · 本回合改动 · 终端 · 浏览器 五 tab，全部可枚举
// ② 每 tab 的标题/图标稳定（tab 条 UI 复用）
// ③ 占位 tab 视图可实例化（文件/终端/浏览器），不破坏既有节点/聊天内容
// ④ 各 tab 内容视图在 SwiftUI 中可构建（无崩溃状态）

@Suite("波4 右栏 tab 容器")
struct ContextTabContainerTests {

    // MARK: ① ContextTab 枚举完整

    @Test("ContextTab 精确覆盖节点/聊天、文件、本回合改动、终端、浏览器五个 tab")
    func allCasesCoverExpectedTabs() {
        let titles = ContextTab.allCases.map(\.title)
        #expect(titles.contains("节点/聊天"))
        #expect(titles.contains("文件"))
        #expect(titles.contains("终端"))
        #expect(titles.contains("浏览器"))
        #expect(titles.contains("本回合改动"))
        #expect(ContextTab.allCases.count == 5)
        #expect(Set(ContextTab.allCases) == Set<ContextTab>([
            .node, .files, .changes, .terminal, .browser
        ]))
    }

    // MARK: ② 每个 tab 有稳定标题 + 图标

    @Test("每个 tab 都有非空标题，本回合改动使用明确的 Keyline 图标")
    func everyTabHasTitleAndIcon() {
        for tab in ContextTab.allCases {
            #expect(!tab.title.isEmpty)
            if tab == .changes {
                // N-08 adds this tab under the approved no-new-SF contract.
                // The production tab button consumes its Catalog icon first.
                #expect(tab.catalogIcon == .document)
                #expect(tab.icon.isEmpty)
            } else {
                #expect(!tab.icon.isEmpty)
            }
        }
    }

    @Test("tab id 唯一且等于 rawValue")
    func tabIdentifiersAreUnique() {
        let ids = ContextTab.allCases.map(\.id)
        #expect(Set(ids).count == ids.count)
        for tab in ContextTab.allCases {
            #expect(tab.id == tab.rawValue)
        }
    }

    // MARK: ③ 占位 tab 视图可实例化

    @Test("文件/终端/浏览器占位视图可构建")
    @MainActor
    func placeholderTabsBuild() {
        let file = FileTreeTabView()
        let terminal = TerminalTabView()
        let browser = BrowserTabView()
        // 真实断言（替代原 #expect(true) 弱断言）：
        // ① body 求值 = 实际构建 SwiftUI 视图树，若占位视图内部崩溃（如
        //    Environment 默认值缺失、@State 初始化崩）测试即失败；
        // ② 默认构造入参行为断言：无参 init 必须保持空上下文入口
        //    （attachmentSelection/contextSnapshot/settings 为 nil）。
        // 110B 测试卫生整改：原第 63–65 行 `type(of: x) == X.self` 为静态可判定
        // 恒真（结构体动态类型恒等于声明类型），等价于 #expect(true)，
        // 已替换为可失败的真实行为断言。
        _ = file.body
        _ = terminal.body
        _ = browser.body
        #expect(file.attachmentSelection == nil)
        #expect(terminal.contextSnapshot == nil)
        #expect(terminal.settings == nil)
    }

    @Test("聊天附件预览请求构建右侧文件面板")
    @MainActor
    func attachmentPreviewRequestBuildsRightPanel() throws {
        let chat = ChatStore()
        let canvas = CanvasStore()
        let url = URL(fileURLWithPath: "/tmp/design.pdf")
        let sessionID = try #require(chat.activeSessionID)
        let selection = ChatAttachmentPreviewSelection(sessionID: sessionID, url: url)
        let panel = ContextPanelView(
            chat: chat,
            canvas: canvas,
            nodeContext: nil,
            onCollapse: {},
            attachmentPreviewSelection: selection
        )

        _ = panel.body
        #expect(panel.attachmentPreviewSelection?.url == url)
        #expect(panel.attachmentPreviewSelection?.sessionID == chat.activeSessionID)
    }
}
