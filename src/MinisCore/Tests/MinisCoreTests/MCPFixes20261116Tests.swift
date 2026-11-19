import Foundation
import Testing
@testable import MinisCore

/// 11/16 MCP 修复：工具表跳过、path 不当文件路径、授权保留与批量、失败提示分类。
@Suite("MCP fixes 2026-11-16")
struct MCPFixes20261116Tests {
    private func bound(_ name: String, properties: [String: MCPJSONValue]? = nil) -> MCPBoundTool {
        let schema: MCPJSONValue? = properties.map { .object(["type": .string("object"), "properties": .object($0)]) }
        return MCPBoundTool(fullName: "mcp_s_\(name)", serverID: "s", tool: MCPTool(name: name, inputSchema: schema))
    }

    // MARK: 1 工具表

    private func boundRaw(_ name: String, schema: MCPJSONValue?) -> MCPBoundTool {
        MCPBoundTool(fullName: "mcp_s_\(name)", serverID: "s", tool: MCPTool(name: name, inputSchema: schema))
    }

    @Test("array and object parameters are supported with their item schemas")
    func arrayAndObjectParametersAreSupported() throws {
        let arrayTool = bound("evaluate_script", properties: [
            "args": .object(["type": .string("array"), "items": .object(["type": .string("string")])])
        ])
        let objectTool = bound("fill_form", properties: [
            "elements": .object(["type": .string("array"), "items": .object([
                "type": .string("object"),
                "properties": .object(["uid": .object(["type": .string("string")]),
                                       "value": .object(["type": .string("string")])]),
                "required": .array([.string("uid"), .string("ghost")])
            ])])
        ])
        let result = try AgentToolCatalog.makeMCPToolDefinitionsReportingSkipped([arrayTool, objectTool])
        #expect(result.skippedToolNames.isEmpty)
        let args = try #require(result.definitions.first?.parameters["args"])
        #expect(args.type == .array)
        let wire = args.wireSchema
        #expect(wire["type"] as? String == "array")
        #expect((wire["items"] as? [String: Any])?["type"] as? String == "string")
        let element = try #require((result.definitions[1].parameters["elements"]?.wireSchema["items"]) as? [String: Any])
        // required 里不存在的名字被忽略。
        #expect(element["required"] as? [String] == ["uid"])
    }

    @Test("only a tool whose top-level schema is unusable is skipped; sloppy schemas are tolerated")
    func unusableToolSkippedOthersTolerated() throws {
        let sloppy = boundRaw("sloppy", schema: .object([
            // 顶层 type 缺失；属性值为 true；description 为 null；整数枚举；重复枚举；number 小数。
            "properties": .object([
                "any": .bool(true),
                "level": .object(["enum": .array([.number(1), .number(2), .number(2)]), "description": .null]),
                "ratio": .object(["type": .string("number")])
            ]),
            "required": .array([.string("level"), .string("missing"), .string("level")])
        ]))
        let broken = boundRaw("broken", schema: .object(["type": .string("string")]))
        let result = try AgentToolCatalog.makeMCPToolDefinitionsReportingSkipped([broken, sloppy])
        #expect(result.skippedToolNames == ["mcp_s_broken"])
        let definition = try #require(result.definitions.first)
        #expect(definition.required == ["level"])
        #expect(definition.parameters["ratio"]?.type == .number)
        let level = try #require(definition.parameters["level"])
        #expect(level.type == .integer)
        #expect((level.wireSchema["enum"] as? [Any])?.count == 2)
        #expect(definition.parameters["any"]?.wireSchema["type"] == nil)
        // 兼容入口：不抛错，只返回可用工具。
        let legacy = try AgentToolCatalog.makeMCPToolDefinitions([broken, sloppy])
        #expect(legacy.map(\.name) == ["mcp_s_sloppy"])
    }

    @Test("makeTools keeps other MCP tools and reports skipped names through the observer")
    func makeToolsKeepsSupportedMCPTools() async throws {
        struct Bridge: MCPToolBridge {
            let tools: [MCPBoundTool]
            func mcpBoundTools() async throws -> [MCPBoundTool] { tools }
            func callMCPTool(fullName: String, arguments: [String: Any]?) async throws -> String { "" }
        }
        final class Box: @unchecked Sendable {
            let lock = NSLock(); var names: [String] = []; var states: [AgentToolCatalogDiscoveryState] = []
        }
        let box = Box()
        let tools = try await AgentToolCatalog.makeTools(
            includingMCPFrom: Bridge(tools: [
                boundRaw("bad", schema: .object(["type": .string("string")])),
                bound("ok", properties: ["q": .object(["type": .string("string")])])
            ]),
            orchestration: nil,
            onDiscoveryState: { state in box.lock.withLock { box.states.append(state) } },
            onSkippedMCPTools: { names in box.lock.withLock { box.names = names } })
        #expect(tools.contains { $0.name == "mcp_s_ok" })
        #expect(!tools.contains { $0.name == "mcp_s_bad" })
        #expect(box.names == ["mcp_s_bad"])
        #expect(box.states.last == .succeeded(toolCount: 1))
    }

    // MARK: 2 path

    @Test("mcp_ tools never feed input path into the local file-path policy")
    func mcpPathIsNotLocalFilePath() {
        for builder in [PolicyEnforcedToolExecutor.productionRequestBuilder,
                        PolicyEnforcedToolExecutor.defaultRequestBuilder] {
            #expect(builder("mcp_fs_read_file", ["path": "/etc/hosts"]).filePath == nil)
            #expect(builder("file_read", ["path": "/etc/hosts"]).filePath == "/etc/hosts")
        }
    }

    // MARK: 3/4 授权

    private func makeManager() throws -> MCPServerManager {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcpfix1116-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manager = MCPServerManager(fileURL: dir.appendingPathComponent("mcps.json"))
        try manager.addServer(MCPServer(id: "fx", name: "Fx", type: .stdio, command: "fixture-never-spawned"))
        return manager
    }

    @Test("batch authorize and revoke use one persisted mutation each")
    func batchAuthorizeAndRevoke() throws {
        let manager = try makeManager()
        try manager.authorizeServer(id: "fx")
        let r0 = manager.snapshot().revision
        try manager.authorizeTools(serverID: "fx", toolNames: ["a", "b", "c"])
        #expect(manager.snapshot().revision == r0 + 1)
        #expect(manager.authorization(serverID: "fx")?.authorizedToolNames == ["a", "b", "c"])
        try manager.revokeTools(serverID: "fx", toolNames: ["a", "b", "c"])
        #expect(manager.snapshot().revision == r0 + 2)
        #expect(manager.authorization(serverID: "fx")?.authorizedToolNames.isEmpty == true)
        // 批量授权复用单个授权的前置校验：未授权的服务器仍被拒。
        try manager.revokeServer(id: "fx")
        #expect(throws: MCPClientError.self) {
            try manager.authorizeTools(serverID: "fx", toolNames: ["a"])
        }
    }

    @Test("revoking the server keeps the tool list and re-authorizing restores it")
    func revokeServerKeepsToolList() throws {
        let manager = try makeManager()
        try manager.authorizeServer(id: "fx")
        try manager.authorizeTools(serverID: "fx", toolNames: ["a", "b"])
        let previous = try manager.revokeServer(id: "fx")
        #expect(previous?.serverAuthorized == true)
        let kept = manager.authorization(serverID: "fx")
        #expect(kept?.serverAuthorized == false)
        #expect(kept?.authorizedToolNames == ["a", "b"])
        // 保留的名单在服务器未授权时不可执行。
        #expect(!manager.isToolAuthorized(serverID: "fx", toolName: "a"))
        #expect(!manager.isServerAuthorized(try #require(manager.server(id: "fx"))))
        // 再次撤销不应再抬高 revision。
        let rev = manager.snapshot().revision
        try manager.revokeServer(id: "fx")
        #expect(manager.snapshot().revision == rev)
        try manager.authorizeServer(id: "fx")
        #expect(manager.authorization(serverID: "fx")?.authorizedToolNames == ["a", "b"])
        #expect(manager.isToolAuthorized(serverID: "fx", toolName: "a"))
        // 持久化后重载仍保留。
        try manager.revokeServer(id: "fx")
        let reloaded = MCPServerManager(fileURL: manager.fileURL)
        #expect(reloaded.authorization(serverID: "fx")?.authorizedToolNames == ["a", "b"])
        #expect(reloaded.authorization(serverID: "fx")?.serverAuthorized == false)
    }

    @Test("revoking an unknown server stays a no-op")
    func revokeUnknownServer() throws {
        let manager = try makeManager()
        #expect(try manager.revokeServer(id: "missing") == nil)
    }

    // MARK: 6 失败提示

    @Test("reconnect failures are classified")
    func reconnectMessages() {
        #expect(MCPFailureMessage.reconnect(MCPOAuthError.loginRequired).contains("登录"))
        #expect(MCPFailureMessage.reconnect(MCPOAuthError.expired).contains("过期"))
        #expect(MCPFailureMessage.reconnect(MCPClientError.timeout("x")).contains("超时"))
        #expect(MCPFailureMessage.reconnect(MCPClientError.spawnFailed("x")).contains("进程启动失败"))
        #expect(MCPFailureMessage.reconnect(MCPDiscoveryError.unauthorized("s")).contains("授权"))
        #expect(MCPFailureMessage.reconnect(MCPDiscoveryError.serverDisabled("s")).contains("停用"))
        #expect(!MCPFailureMessage.reconnect(MCPClientError.spawnFailed("secret-token")).contains("secret-token"))
    }

    @Test("save failures distinguish a changed config from a failed write")
    func saveMessages() {
        #expect(MCPFailureMessage.save(nil).contains("刷新"))
        #expect(MCPFailureMessage.save(MCPPersistenceConflict.staleSnapshot).contains("刷新"))
        #expect(MCPFailureMessage.save(MCPPersistenceConflict.documentUnavailable(path: "p", code: 28))
            .contains("磁盘空间或权限"))
        #expect(MCPFailureMessage.save(CocoaError(.fileWriteOutOfSpace)).contains("磁盘空间或权限"))
    }
}
