import Foundation
import Testing
@testable import MinisCore

/// 11/16 第二轮 MCP 修复：工具返回内容与 isError、工具全名、JSON 导入、超时与整数参数。
@Suite("MCP fixes 2026-11-16 round 2")
struct MCPFixes20261116W2Tests {
    private struct CannedTransport: MCPTransport {
        let callResult: MCPJSONValue

        func start() async throws {}
        func notify(_ notification: MCPJSONRPCNotification) throws {}
        func stop() {}
        func send(_ request: MCPJSONRPCRequest) async throws -> MCPJSONRPCResponse {
            switch request.method {
            case "initialize":
                return MCPJSONRPCResponse(id: request.id, result: .object([
                    "protocolVersion": .string("2025-11-25"), "capabilities": .object([:])
                ]))
            case "tools/call":
                return MCPJSONRPCResponse(id: request.id, result: callResult)
            default:
                return MCPJSONRPCResponse(id: request.id, error: MCPJSONRPCError(code: -32601, message: "no"))
            }
        }
    }

    private func call(_ result: MCPJSONValue) async throws -> String {
        let client = MCPClient(server: MCPServer(id: "s", name: "S", type: .http, url: "https://example.invalid"),
                               transport: CannedTransport(callResult: result))
        return try await client.callTool(name: "t", arguments: nil)
    }

    // MARK: 工具返回内容

    @Test("image, audio and resource content become readable notes instead of being dropped")
    func nonTextContentIsDescribed() async throws {
        let text = try await call(.object(["content": .array([
            .object(["type": .string("text"), "text": .string("done")]),
            .object(["type": .string("image"), "mimeType": .string("image/png"),
                     "data": .string(String(repeating: "A", count: 4096))]),
            .object(["type": .string("resource"), "resource": .object([
                "uri": .string("file:///a.txt"), "text": .string("file body")])])
        ])]))
        #expect(text.contains("done"))
        #expect(text.contains("1 张图片（image/png，3 KB）"))
        #expect(text.contains("file:///a.txt"))
        #expect(text.contains("file body"))
    }

    @Test("isError results are thrown as tool errors carrying the tool's own message")
    func isErrorIsAnError() async throws {
        await #expect(throws: MCPToolReportedError(message: "bad input: x")) {
            _ = try await call(.object([
                "content": .array([.object(["type": .string("text"), "text": .string("bad input: x")])]),
                "isError": .bool(true)
            ]))
        }
    }

    // MARK: 工具全名

    @Test("full tool names are ASCII, at most 64 characters, and stay unique")
    func fullNamesAreWireSafe() {
        let pattern = #"^[a-zA-Z0-9_-]{1,64}$"#
        let long = String(repeating: "x", count: 80)
        let names = [
            MCPBoundTool.makeFullName(serverID: "github", toolName: "create_issue"),
            MCPBoundTool.makeFullName(serverID: "服务", toolName: "搜索"),
            MCPBoundTool.makeFullName(serverID: "服务", toolName: "查询"),
            MCPBoundTool.makeFullName(serverID: "s", toolName: long + "a"),
            MCPBoundTool.makeFullName(serverID: "s", toolName: long + "b")
        ]
        for name in names { #expect(name.range(of: pattern, options: .regularExpression) != nil, "\(name)") }
        #expect(Set(names).count == names.count)
        #expect(names[0] == "mcp_github_create_issue")
    }

    // MARK: 整数参数

    @Test("integer arguments from JSON stay numbers, not booleans")
    func integerArgumentsAreNotBooleans() throws {
        let parsed = try #require(JSONSerialization.jsonObject(with: Data(#"{"a":1,"b":0,"c":true,"d":1.5}"#.utf8)) as? [String: Any])
        #expect(MCPJSONValue.fromAny(parsed["a"]!) == .number(1))
        #expect(MCPJSONValue.fromAny(parsed["b"]!) == .number(0))
        #expect(MCPJSONValue.fromAny(parsed["c"]!) == .bool(true))
        #expect(MCPJSONValue.fromAny(parsed["d"]!) == .number(1.5))
    }

    // MARK: JSON 导入

    @Test("Claude Desktop style JSON previews stdio and http servers and flags existing ids")
    func importPreview() {
        let json = """
        {"mcpServers": {
          "github": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"], "env": {"GITHUB_TOKEN": "a,b=c"}},
          "remote": {"type": "http", "url": "https://mcp.example.com/mcp", "headers": {"Authorization": "Bearer x"}},
          "taken": {"command": "foo"}
        }}
        """
        let preview = MCPServerJSONImport.preview(json, existingIDs: ["taken"])
        #expect(preview.parseError == nil)
        #expect(preview.entries.count == 3)
        let servers = preview.importableServers
        #expect(servers.map(\.id) == ["github", "remote"])
        #expect(servers[0].env["GITHUB_TOKEN"] == "a,b=c")
        #expect(servers[0].args == ["-y", "@modelcontextprotocol/server-github"])
        #expect(servers[1].type == .http && servers[1].headers["Authorization"] == "Bearer x")
        let taken = preview.entries.first { $0.sourceName == "taken" }
        #expect(taken?.server == nil && taken?.note?.contains("已存在") == true)
        // 摘要不含密钥值。
        #expect(!preview.entries.map(\.summary).joined().contains("a,b=c"))
    }

    @Test("a single server object and a bare fragment are both accepted")
    func importSingleObject() {
        let single = MCPServerJSONImport.preview(#"{"command": "npx", "args": ["-y", "@scope/server-fs"]}"#, existingIDs: [])
        #expect(single.importableServers.map(\.id) == ["server-fs"])
        let fragment = MCPServerJSONImport.preview(#""fs": {"command": "node", "args": ["a.js"]}"#, existingIDs: [])
        #expect(fragment.importableServers.map(\.id) == ["fs"])
        #expect(MCPServerJSONImport.preview("not json", existingIDs: []).parseError != nil)
    }

    // MARK: 超时

    @Test("tool call timeout defaults to ten minutes without changing the descriptor fingerprint")
    func callTimeoutDefault() {
        var server = MCPServer(id: "s", name: "S", command: "/bin/true")
        let fingerprint = server.descriptorFingerprint
        #expect(server.effectiveCallTimeoutSeconds == 600)
        server.callTimeoutSeconds = 1800
        #expect(server.effectiveCallTimeoutSeconds == 1800)
        #expect(server.descriptorFingerprint == fingerprint)
    }
}
