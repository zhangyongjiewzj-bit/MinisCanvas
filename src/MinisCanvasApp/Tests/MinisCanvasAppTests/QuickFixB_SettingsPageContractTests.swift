import Foundation
import MinisCore
import Testing

@testable import MinisCanvasApp

/// 线 B（设置页）快档 RED：以源码结构契约锁定 M09 / 环境变量页 / 工具超时 / MCP 表单 / 自主权上限标注。
/// SettingsPage 等为 private 视图类型，无法直接断言，故读源码文本（与 A7ASettingsRawContractTests 同法）。
@Suite("QuickFixB 设置页契约")
struct QuickFixB_SettingsPageContractTests {
    private static func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MinisCanvasAppTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // MinisCanvasApp
            .deletingLastPathComponent() // src
            .deletingLastPathComponent() // repository
        return try String(
            contentsOf: root.appendingPathComponent("src/MinisCanvasApp/Sources/MinisCanvasApp/\(name)"),
            encoding: .utf8
        )
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    // MARK: 1. M09 两个 fileImporter 不能挂在同一视图上

    @Test("M09：同一视图类型内的多个 .fileImporter 必须分挂在 background/overlay 载体上")
    func fileImportersAreNotStackedOnSameView() throws {
        let text = try Self.source("SettingsView.swift")
        let parts = text.components(separatedBy: "\nstruct ")
            .flatMap { $0.components(separatedBy: "\nprivate struct ") }
            .flatMap { $0.components(separatedBy: "\nfileprivate struct ") }
        var offenders = 0
        for part in parts {
            let ns = part as NSString
            var locations: [Int] = []
            var search = NSRange(location: 0, length: ns.length)
            while true {
                let r = ns.range(of: ".fileImporter(", options: [], range: search)
                if r.location == NSNotFound { break }
                locations.append(r.location)
                search = NSRange(location: r.location + r.length, length: ns.length - r.location - r.length)
            }
            guard locations.count >= 2 else { continue }
            // 除其中一个外，其余都应紧跟在 .background / .overlay / Color.clear 载体之后。
            let wrapped = locations.filter { loc in
                let start = max(0, loc - 160)
                let before = ns.substring(with: NSRange(location: start, length: loc - start))
                return before.contains(".background") || before.contains(".overlay") || before.contains("Color.clear")
            }.count
            if wrapped < locations.count - 1 { offenders += 1 }
        }
        #expect(offenders == 0, "SettingsView.swift 中存在同一视图叠挂多个 .fileImporter（SwiftUI 只认最后一个）")
    }

    // MARK: 2. 环境变量页

    @Test("环境变量页显示标题为“模型”，路由 ID（rawValue）仍为“环境变量”")
    func environmentPageHasDisplayTitleButKeepsRouteID() throws {
        let text = try Self.source("SettingsView.swift")
        #expect(text.contains("case environment = \"环境变量\""))
        #expect(text.contains("var displayTitle"))
        #expect(text.contains("\"模型\""))
        #expect(text.contains("Text(page.displayTitle)"))
        #expect(text.contains("settingsPage(title: isSearchingSettings ? \"搜索设置\" : selectedPage.displayTitle"))
        #expect(!text.contains("Text(page.rawValue)"))
        #expect(!text.contains("settingsPage(title: selectedPage.rawValue"))
    }

    @Test("环境变量空态文案不得声称供 Shell 执行与 Provider 凭证解析使用")
    func environmentEmptyStateIsHonest() throws {
        let text = try Self.source("SettingsView.swift")
        #expect(!text.contains("供 Shell 执行与 Provider 凭证解析使用"))
        // 模型命令环境只来自登录 Shell 快照
        #expect(text.contains("登录 Shell"))
    }

    @Test("编辑已有环境变量时不丢弃保存结果，失败不提示“已更新”")
    func environmentEditUsesSaveResult() throws {
        let text = try Self.source("SettingsView.swift")
        #expect(!text.contains("_ = center.saveExplicitlyClassifiedEnvironmentVariable"))
    }

    // MARK: 3. 其它工具超时无读取者，移除

    @Test("Agent 页不再出现“其它工具超时”输入框")
    func toolTimeoutFieldRemoved() throws {
        let text = try Self.source("SettingsView.swift")
        #expect(!text.contains("settings.agent.tool-timeout"))
        #expect(!text.contains("其它工具超时"))
    }

    // MARK: 4. MCP 新增表单与删除确认

    @Test("MCP 命令框占位只示例可执行文件，参数框示例其余部分")
    func mcpCommandPlaceholderSplitsCommandAndArgs() throws {
        let text = try Self.source("MCPManagerView.swift")
        let command = try #require(Self.firstCapture(#"TextField\("([^"]*)", text: \$draft\.command\)"#, in: text))
        #expect(command.contains("npx"))
        #expect(!command.contains(" "), "命令框占位不应带参数：\(command)")
        let args = try #require(Self.firstCapture(#"TextField\("([^"]*)", text: \$draft\.argsText\)"#, in: text))
        #expect(args.contains("-y"))
        #expect(args.contains("@modelcontextprotocol/server-github"))
    }

    @Test("MCP stdio 表单提示 PATH 与绝对路径")
    func mcpFormHasPathHint() throws {
        let text = try Self.source("MCPManagerView.swift")
        #expect(text.contains("PATH"))
        #expect(text.contains("绝对路径"))
    }

    @Test("删除 MCP 服务器先确认再删")
    func mcpDeleteRequiresConfirmation() throws {
        let text = try Self.source("MCPManagerView.swift")
        #expect(text.contains(".confirmationDialog(") || text.contains(".alert("))
        // 删除按钮的 action 不得直接调用 removeMCPServer
        let ns = text as NSString
        let buttonRange = ns.range(of: "Button(role: .destructive) {")
        #expect(buttonRange.location != NSNotFound)
        let tail = ns.substring(from: buttonRange.location)
        let window = String(tail.prefix(200))
        #expect(!window.contains("center.removeMCPServer"), "删除按钮应只设置待确认状态，不能直接删除")
    }

    // MARK: 5. 自主权上限标注可用模式

    @Test("自主权上限选项标注每档可用模式")
    func autonomyLabelsMentionAvailableModes() throws {
        let text = try Self.source("SettingsView.swift")
        for (level, title) in [("l0", "仅计划"), ("l1", "手动审批"),
                               ("l2", "自动编辑"), ("l3", "绕过权限")] {
            #expect(text.contains("case .\(level): return \"\(title)\""))
        }
    }
    @Test("Settings search recognizes the reported approval and notification terms")
    func settingsSearchFindsReportedTerms() {
        let expectations: [(String, SettingsPage)] = [
            ("循环上限", .agent), ("允许访问的网站", .agent),
            ("任务完成通知", .general), ("已允许", .permissions), ("已允许", .agent),
            ("自动继续", .general), ("审批等待超时", .agent), ("联网搜索", .browser),
        ]
        for (query, page) in expectations {
            #expect(SettingsSearchResult.matches(query).contains { $0.page == page })
        }
    }

    /// 11/19 旅途：编辑服务商只改了最大输出，保存后名字从"DeepSeek"变成"自定义 OpenAI 兼容"。
    @Test("服务商编辑框预填的名字与列表标题同一规则，保存不会换名")
    func providerEditPrefillUsesListLabel() throws {
        let record = EnvVarEntry(
            name: "MINISCANVAS_JOURNEY_DEEPSEEK_API_KEY",
            value: "",
            isSecret: true,
            valueInKeychain: true,
            baseURL: "https://api.deepseek.com",
            modelNames: ["deepseek-flash"]
        )
        #expect(ProviderDisplayLabel.resolve(record: record) == "DeepSeek")
        #expect(record.providerDisplayName != "DeepSeek")
        let text = try Self.source("SettingsView.swift")
        #expect(text.contains("displayName = ProviderDisplayLabel.resolve(record: existing)"))
        #expect(!text.contains("displayName = existing.providerDisplayName"))
    }

    /// 11/19 旅途：审批超时默认 300 秒后，每张行内审批卡都多出一个可编辑的超时输入框。
    @Test("行内审批卡只显示剩余时间，不放超时时长输入框")
    func inlineApprovalCardHasNoTimeoutEditor() throws {
        let text = try Self.source("ApprovalPromptCenter.swift")
        let start = try #require(text.range(of: "struct InlineApprovalPromptView"))
        let end = try #require(text.range(of: "private struct ApprovalDurationField"))
        let inline = text[start.upperBound..<end.lowerBound]
        #expect(!inline.contains("ApprovalDurationField("))
        #expect(inline.contains("在弹窗中审批"))
        #expect(text.contains("分钟后自动拒绝"))
    }

}
