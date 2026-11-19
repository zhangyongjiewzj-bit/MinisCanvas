import Foundation
import Testing

@testable import MinisCore

@Suite("钩子与 Claude Code 通用")
struct HookClaudeCompatTests {
    @Test("工具名换成 Claude Code 名，MCP 工具用双下划线，路径字段同时给 file_path")
    func payloadUsesClaudeNames() {
        #expect(HookPayload.claudeToolName("shell_execute") == "Bash")
        #expect(HookPayload.claudeToolName("file_edit") == "Edit")
        #expect(HookPayload.claudeToolName("mcp_github_create_issue") == "mcp__github__create_issue")
        #expect(HookPayload.claudeToolName("todo_write") == "todo_write")
        var object: [String: Any] = [:]
        HookPayload.addToolNames(&object, appName: "file_read")
        #expect(object["tool_name"] as? String == "Read")
        #expect(object["app_tool_name"] as? String == "file_read")
        let input = ComposerToolInput(values: ["path": .string("/tmp/a.txt")])
        #expect(HookPayload.toolInput(input)["file_path"] as? String == "/tmp/a.txt")
        let hook = HookDefinition(event: .preToolUse, matcher: "mcp__github__.*", command: "true")
        #expect(hook.matches(toolName: "mcp_github_create_issue"))
    }

    @Test("纯文本 stdout 作为附加上下文；Stop 钩子 block 表示要求继续")
    func plainTextContextAndStopBlock() {
        let plain = HookOutputParser.parse(stdout: Data("今天是周三".utf8), event: .userPromptSubmit)
        #expect(plain == .parsed(HookParsedOutput(verdict: nil, reason: nil, additionalContext: "今天是周三")))
        let broken = HookOutputParser.parse(stdout: Data("{坏的".utf8), event: .userPromptSubmit)
        #expect(broken == .invalid("stdout 不是 JSON 对象"))
        let stop = HookOutputParser.parse(
            stdout: Data(#"{"decision":"block","reason":"还没跑测试"}"#.utf8), event: .stop)
        #expect(stop == .parsed(HookParsedOutput(verdict: .deny, reason: "还没跑测试", additionalContext: nil)))
    }

    @Test("钩子的 PATH 用登录 shell 的搜索路径，其余环境保持隔离")
    func hookPathUsesSearchPath() throws {
        let path = try #require(try HookRuntime.defaultEnvironment()["PATH"])
        #expect(path.contains("/usr/bin"))
        #expect(path.contains("/opt/homebrew/bin"))
    }
}
