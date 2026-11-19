import Foundation
import Testing
@testable import MinisCanvasApp

/// 11/16：被跳过的 MCP 工具对用户可见提示的文案与"同会话同一组只提示一次"。
@Suite("Skipped MCP tools notice 2026-11-16")
struct SkippedMCPNotice20261116Tests {
    @Test("notice groups tools by server and lists their names")
    func noticeText() {
        let text = AgentLoopChatEngine.skippedMCPToolsNotice([
            (server: "chrome-devtools", tool: "evaluate_script"),
            (server: "chrome-devtools", tool: "fill_form")
        ])
        #expect(text == "⚠️ chrome-devtools 的 2 个工具（evaluate_script、fill_form）参数格式暂不支持，已跳过，其余工具可用。\n\n")
    }

    @Test("notice with several servers keeps first-seen order")
    func noticeMultipleServers() {
        let text = AgentLoopChatEngine.skippedMCPToolsNotice([
            (server: "b", tool: "t1"), (server: "a", tool: "t2"), (server: "b", tool: "t3")
        ])
        #expect(text == "⚠️ b 的 2 个工具（t1、t3）；a 的 1 个工具（t2）参数格式暂不支持，已跳过，其余工具可用。\n\n")
    }

    @Test("ledger claims the same group once per session regardless of order")
    func ledgerOncePerSessionAndGroup() {
        let ledger = SkippedMCPNoticeLedger()
        #expect(ledger.claim(sessionID: "s1", names: ["mcp_a_x", "mcp_a_y"]))
        #expect(!ledger.claim(sessionID: "s1", names: ["mcp_a_y", "mcp_a_x"]))
        #expect(ledger.claim(sessionID: "s2", names: ["mcp_a_x", "mcp_a_y"]))
        #expect(ledger.claim(sessionID: "s1", names: ["mcp_a_x"]))
    }
}
