import Foundation
import Testing
@testable import MinisCore

struct ToolOutputDetailTests {
    @Test func shellDetailKeepsFullCommandAndOutputBody() {
        let command = "swift build -c release --product MinisCanvasApp && echo " + String(repeating: "x", count: 200)
        let args = try! String(data: JSONSerialization.data(withJSONObject: ["command": command]), encoding: .utf8)!
        let output = #"{"exit_code":0,"stdout":"Build complete\nline2","stderr":""}"#
        let summary = ToolOutputSummary.captureWithDetail(toolName: "shell_execute", argumentsJSON: args, output: output)
        let detail = try! #require(summary.detail)
        #expect(detail.input == command)
        #expect(detail.output == "Build complete\nline2")
        #expect(summary.displaySuffix == ToolOutputSummary.capture(toolName: "shell_execute", output: output).displaySuffix)
    }

    @Test func detailOutputIsCappedByLinesAndRedacted() {
        let lines = (1...300).map { "line \($0)" } + ["Authorization: Bearer abcdefghijklmnop1234567890"]
        let summary = ToolOutputSummary.captureWithDetail(
            toolName: "file_read", argumentsJSON: #"{"path":"/Users/me/work/a.txt"}"#,
            output: lines.joined(separator: "\n"))
        let detail = try! #require(summary.detail)
        #expect(detail.input == "/Users/me/work/a.txt")
        #expect(detail.output?.split(separator: "\n").count == ToolOutputSummary.maxDetailLines)
        #expect(detail.omittedLines == 101)
        let leaky = lines.joined(separator: "\n")
        let secret = ToolOutputSummary.captureWithDetail(
            toolName: "file_read", argumentsJSON: "{}", output: String(leaky.suffix(80)))
        #expect(secret.detail?.output?.contains("abcdefghijklmnop1234567890") != true)
    }

    @Test func grepDetailShowsPatternAndScope() {
        let summary = ToolOutputSummary.captureWithDetail(
            toolName: "file_grep", argumentsJSON: #"{"pattern":"TODO","path":"/Users/me/work"}"#, output: "a.swift:3")
        #expect(summary.detail?.input == "TODO\n范围：/Users/me/work")
    }

    @Test func detailSummaryRoundTripsThroughCodable() throws {
        let summary = ToolOutputSummary.captureWithDetail(
            toolName: "shell_execute", argumentsJSON: #"{"command":"ls"}"#,
            output: #"{"exit_code":0,"stdout":"a","stderr":""}"#)
        let decoded = try JSONDecoder().decode(ToolOutputSummary.self, from: JSONEncoder().encode(summary))
        #expect(decoded == summary)
    }

    @Test func fullOutputPathComesFromShellArtifactAndMCPTextLine() {
        let shell = ToolOutputSummary.captureWithDetail(
            toolName: "shell_execute", argumentsJSON: #"{"command":"ls"}"#,
            output: #"{"exit_code":0,"stdout":"a","stderr":"","stdout_artifact":{"path":"/tmp/session/tool-output/o.txt"}}"#)
        #expect(shell.detail?.fullOutputPath == "/tmp/session/tool-output/o.txt")
        let mcp = ToolOutputSummary.captureWithDetail(
            toolName: "mcp__demo__search", argumentsJSON: "{}",
            output: "前面的内容\n[完整输出（已脱敏）共 9 字符，已保存到 /tmp/s/tool-output/m.txt；用 file_read 分段读取]\nfull_output_path: /tmp/s/tool-output/m.txt")
        #expect(mcp.detail?.fullOutputPath == "/tmp/s/tool-output/m.txt")
        let relative = ToolOutputSummary.captureWithDetail(
            toolName: "shell_execute", argumentsJSON: #"{"command":"ls"}"#,
            output: #"{"exit_code":0,"stdout":"a","stderr":"","full_output_path":"relative/o.txt"}"#)
        #expect(relative.detail?.fullOutputPath == nil)
    }
}
