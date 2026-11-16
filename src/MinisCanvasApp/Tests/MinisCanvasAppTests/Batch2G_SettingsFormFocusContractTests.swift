import Foundation
import Testing
@testable import MinisCanvasApp

/// Batch2G RED 2（M11）：设置窗口里的表单（MCP 新增服务器、Hooks 添加、定时任务新建）点击另一个
/// 输入框或按 Tab 都不能移焦，键入落在第一个框。
///
/// 根因判断（静态证据，未在真实包复现）：这三处表单的 TextField/SecureField 全部没有 `@FocusState` /
/// `.focused(...)` 绑定、也没有首字段焦点的显式落位；而真实包上焦点正常的同类表单
/// （SettingsView.swift:5886 EnvVarEditSheet、:6404 ProviderEditSheet、ValidatedNumericSettingField）都
/// 声明了 FocusState 并逐字段 `.focused`，其中 :6744 注释写明 macOS sheet 首次呈现时焦点会落回标题/被吞掉，
/// 需要 Task.yield 之后显式设焦点。这三处没有这套机制，AppKit 的 key view loop 在 SwiftUI sheet 内无法
/// 把点击/Tab 转成 SwiftUI 焦点迁移。待总控真实包验证；本测试锁住“每个输入框必须有 focused 绑定”。
@Suite("Batch2G settings form focus contract")
struct Batch2G_SettingsFormFocusContractTests {
    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("src/MinisCanvasApp/Sources/MinisCanvasApp/\(name)"),
            encoding: .utf8)
    }

    private func slice(_ text: String, from start: String, to end: String?) throws -> String {
        let lower = try #require(text.range(of: start)).lowerBound
        let tail = text[lower...]
        if let end, let upper = tail.dropFirst(start.count).range(of: end)?.lowerBound {
            return String(tail[..<upper])
        }
        return String(tail)
    }

    private func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    private func assertFocusBound(_ body: String, label: String) {
        let fields = count("TextField(", in: body) + count("SecureField(", in: body)
        #expect(fields > 0, "\(label) 应含输入框")
        #expect(body.contains("@FocusState"), "\(label) 必须声明 @FocusState")
        #expect(count(".focused(", in: body) >= fields,
                "\(label) 的 \(fields) 个输入框都必须有 .focused 绑定（实际 \(count(".focused(", in: body))）")
    }

    @Test("MCP 新增服务器表单每个输入框都有焦点绑定")
    func mcpServerEditSheetBindsFocus() throws {
        let text = try source("MCPManagerView.swift")
        let body = try slice(text, from: "private struct MCPServerEditSheet", to: "// MARK: - Preview")
        assertFocusBound(body, label: "MCPServerEditSheet")
    }

    @Test("Hooks 添加表单每个输入框都有焦点绑定")
    func hooksAddFormBindsFocus() throws {
        let text = try source("HooksSettingsSection.swift")
        let body = try slice(text, from: "struct HooksSettingsSection: View", to: nil)
        // 添加表单的三个输入框（匹配、命令、超时）都要绑定；FocusState 声明在 section 上。
        let form = try slice(body, from: "private var addForm", to: "private func projectRow")
        let fields = count("TextField(", in: form)
        #expect(fields == 3)
        #expect(body.contains("@FocusState"), "HooksSettingsSection 必须声明 @FocusState")
        #expect(count(".focused(", in: form) >= fields,
                "Hooks addForm 的 \(fields) 个输入框都必须有 .focused 绑定")
    }

    @Test("定时任务新建/编辑表单每个输入框都有焦点绑定")
    func schedulerEditorBindsFocus() throws {
        let text = try source("SchedulerControlSettingsView.swift")
        let body = try slice(text, from: "private struct SchedulerControlTaskEditor", to: nil)
        assertFocusBound(body, label: "SchedulerControlTaskEditor")
    }
}
