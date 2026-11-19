import Foundation
import Testing

@testable import MinisCore

/// 第二轮修复（扩展与协作）：外部技能按名读取、.mcp.json 更新与变量、子智能体 tools 列表、
/// 外部会话读取工具调用、会话附件。
@Suite("扩展与协作第二轮修复")
struct ExtensionsCollabR2FixesTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExtensionsCollabR2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test("已确认的外部技能可按名读取，未确认的读不到")
    func externalSkillReadByName() throws {
        let tmp = try makeRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let home = tmp.appendingPathComponent("home")
        try write("---\nname: pdf-helper\ndescription: 处理 PDF\n---\n先检查页数",
                  to: home.appendingPathComponent(".claude/skills/pdf-helper/SKILL.md"))
        let catalog = ExternalSkillCatalog(
            confirmationsURL: tmp.appendingPathComponent("confirm.json"), homeDirectory: home)
        #expect(catalog.readConfirmed(name: "pdf-helper", projectRoot: nil) == nil)
        try catalog.confirm(try #require(catalog.scan(projectRoot: nil).first), projectRoot: nil)
        let text = try #require(catalog.readConfirmed(name: "PDF-Helper", projectRoot: nil))
        #expect(text.contains("先检查页数") && text.contains("external"))
    }

    @Test(".mcp.json：来自同一文件的同名服务器按更新导入，${变量} 只展开白名单")
    func projectMCPUpdateAndVariables() throws {
        let json = #"{"mcpServers":{"db":{"command":"${CLAUDE_PROJECT_DIR}/bin/db","args":["--key","${API_KEY}","--mode","${MODE:-fast}"]}}}"#
        let updated = MCPServerJSONImport.preview(
            json, existingIDs: ["db"], updatableIDs: ["db"], projectRoot: "/tmp/proj")
        let entry = try #require(updated.entries.first)
        let server = try #require(entry.server)
        #expect(server.command == "/tmp/proj/bin/db")
        #expect(server.args == ["--key", "${API_KEY}", "--mode", "fast"])
        #expect(server.workingDirectory == "/tmp/proj")
        #expect(entry.note?.contains("API_KEY") == true && entry.note?.contains("更新已有服务器") == true)
        // 用户自己添加的同名服务器（不在可更新集合里）仍然跳过。
        let skipped = MCPServerJSONImport.preview(json, existingIDs: ["db"], projectRoot: "/tmp/proj")
        #expect(skipped.entries.first?.server == nil)
    }

    @Test("子智能体：tools 写成 YAML 列表能解析；tools 键留空时继承全部工具")
    func subagentToolsYAMLList() throws {
        let tmp = try makeRoot()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let agents = tmp.appendingPathComponent(".claude/agents")
        try write("---\nname: reader\ndescription: 只读\nmodel: sonnet\ntools:\n  - Read\n  - Grep\n  - Bash(git status:*)\n---\n你只读文件",
                  to: agents.appendingPathComponent("reader.md"))
        try write("---\nname: empty\ndescription: x\ntools:\n---\n角色",
                  to: agents.appendingPathComponent("empty.md"))
        let defs = CustomSubagentLoader.load(projectRoot: nil, homeDirectory: tmp)
        let reader = try #require(defs.first { $0.name == "reader" })
        #expect(reader.toolNames == ["file_read", "file_grep"])
        #expect(reader.unmappedTools == ["Bash(git status:*)"])
        #expect(reader.model == "sonnet")
        let empty = try #require(defs.first { $0.name == "empty" })
        #expect(empty.toolNames == nil)
    }

    @Test("读外部会话可带工具调用与结果摘要")
    func externalSessionToolItems() {
        let sessionID = UUID().uuidString
        let call: [String: Any] = [
            "type": "assistant", "sessionId": sessionID,
            "message": ["role": "assistant", "content": [
                ["type": "tool_use", "name": "Bash", "input": ["command": "ls"]]]],
        ]
        let result: [String: Any] = [
            "type": "user", "sessionId": sessionID,
            "message": ["role": "user", "content": [
                ["type": "tool_result", "content": "a.txt"]]],
        ]
        let map = ExternalSessionFormatMap.claudeCode
        let calls = map.toolItems(from: call, fileSessionID: sessionID)
        #expect(calls.first?.role == "tool_call" && calls.first?.text.contains("Bash") == true)
        #expect(map.toolItems(from: result, fileSessionID: sessionID).first?.text == "a.txt")
        #expect(map.message(from: call, fileSessionID: sessionID) == nil)
    }

    @Test("外部会话发送带文件：只把路径写进消息；超过 3 个文件被拒")
    func externalSendAttachments() throws {
        let request = ExternalSessionSendTool.Request(
            source: "codex", session: UUID().uuidString, message: "看这个", timeoutSeconds: 10)
        let message = ExternalSessionSendTool.composedMessage(request, attachmentPaths: ["/tmp/a.txt"])
        #expect(message.hasPrefix("看这个") && message.contains("- /tmp/a.txt"))
        #expect(throws: (any Error).self) {
            try SessionAttachmentFiles.requestedPaths(["files": ["/a", "/b", "/c", "/d"]])
        }
    }
}
