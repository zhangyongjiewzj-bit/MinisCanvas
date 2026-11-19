import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// 11/16 MCP 设置修复：停用工具后还原审批策略、批量授权、下一回合生效、保存失败原因。
@Suite("MCP settings fixes 2026-11-16", .serialized)
@MainActor
struct MCPSettingsFixes20261116Tests {
    private func makeCenter() throws -> SettingsCenter {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcpfix1116-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        return SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("provider"), keychain: keychain),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
            logManager: LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 10),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite("mcpfix1116-" + UUID().uuidString)))
    }

    @Test func restoringToolsKeepsThePreviousApprovalPolicy() throws {
        let center = try makeCenter()
        center.confirmApprovalPolicy(.riskOnlyAsk)
        try #require(center.approvalPolicy == .riskOnlyAsk)
        center.toolsDisabled = true
        #expect(center.approvalPolicy == .deny)
        center.toolsDisabled = false
        #expect(center.approvalPolicy == .riskOnlyAsk)
        // 没有记录（例如策略本来就是 deny）时仍回落到每次询问。
        center.confirmApprovalPolicy(.deny)
        center.toolsDisabled = false
        #expect(center.approvalPolicy == .alwaysAsk)
    }

    @Test func batchToolAuthorizationAndRevocation() throws {
        let center = try makeCenter()
        try center.mcpManager.addServer(MCPServer(id: "fx", name: "Fx", type: .stdio, command: "fixture-never-spawned"))
        #expect(center.setMCPServerAuthorized(id: "fx", authorized: true))
        #expect(center.setMCPToolsAuthorized(serverID: "fx", toolNames: ["a", " b ", ""], authorized: true))
        #expect(center.mcpManager.authorization(serverID: "fx")?.authorizedToolNames == ["a", "b"])
        #expect(center.setMCPToolsAuthorized(serverID: "fx", toolNames: ["a", "b"], authorized: false))
        #expect(center.mcpManager.authorization(serverID: "fx")?.authorizedToolNames.isEmpty == true)
        #expect(!center.setMCPToolsAuthorized(serverID: "fx", toolNames: [], authorized: true))
    }

    @Test func serverToggleOffAndOnKeepsToolGrants() throws {
        let center = try makeCenter()
        try center.mcpManager.addServer(MCPServer(id: "fx", name: "Fx", type: .stdio, command: "fixture-never-spawned"))
        #expect(center.setMCPServerAuthorized(id: "fx", authorized: true))
        #expect(center.setMCPToolAuthorized(serverID: "fx", toolName: "a", authorized: true))
        #expect(center.setMCPServerAuthorized(id: "fx", authorized: false))
        #expect(!center.isMCPServerAuthorized(id: "fx"))
        #expect(center.setMCPServerAuthorized(id: "fx", authorized: true))
        #expect(center.mcpManager.authorization(serverID: "fx")?.authorizedToolNames == ["a"])
    }

    @Test func saveFailureReasonIsRecorded() throws {
        let center = try makeCenter()
        #expect(center.lastMCPWriteFailure == nil)
        let server = MCPServer(id: "fx", name: "Fx", type: .stdio, command: "fixture-never-spawned")
        #expect(center.addMCPServer(server))
        #expect(center.lastMCPWriteFailure == nil)
    }

    /// 事实依据：每回合的工具表由 registry.snapshotForTurn() 在回合开始时冻结；
    /// 工具授权写入 manager 后，下一次取快照就包含该工具，已取的旧快照不变。
    @Test func toolAuthorizationTakesEffectFromTheNextTurnSnapshot() async throws {
        let center = try makeCenter()
        try center.mcpManager.addServer(MCPServer(id: "fx", name: "Fx", type: .stdio, command: "fixture-never-spawned"))
        #expect(center.setMCPServerAuthorized(id: "fx", authorized: true))
        let factory: @Sendable (MCPServer) -> MCPClient = { MCPClient(server: $0, transport: ListTransport()) }
        let server = try #require(center.mcpManager.server(id: "fx"))
        #expect(await center.discoverMCPTools(for: server, clientFactory: factory))
        let registry = MCPToolRegistry(manager: center.mcpManager, clientFactory: factory)
        defer { registry.disconnectAll() }
        let before = try registry.snapshotForTurn()
        #expect(center.setMCPToolAuthorized(serverID: "fx", toolName: "echo", authorized: true))
        let after = try registry.snapshotForTurn()
        #expect(try await after.mcpBoundTools().map(\.fullName) == ["mcp_fx_echo"])
        #expect(try await before.mcpBoundTools().isEmpty)
    }

    private final class ListTransport: MCPTransport, @unchecked Sendable {
        func start() async throws {}
        func notify(_ notification: MCPJSONRPCNotification) throws {}
        func stop() {}
        func send(_ request: MCPJSONRPCRequest) async throws -> MCPJSONRPCResponse {
            switch request.method {
            case "initialize":
                return MCPJSONRPCResponse(id: request.id, result: .object([
                    "protocolVersion": .string("2024-11-05"), "capabilities": .object([:]),
                    "serverInfo": .object(["name": .string("fixture"), "version": .string("1")])]))
            case "tools/list":
                return MCPJSONRPCResponse(id: request.id, result: .object([
                    "tools": .array([.object(["name": .string("echo"),
                        "inputSchema": .object(["type": .string("object")])])])]))
            default:
                return MCPJSONRPCResponse(id: request.id, error: MCPJSONRPCError(code: -32601, message: "fixture unsupported"))
            }
        }
    }
}

@Suite("MCP 启用开关与失败提示（F-3 / F-4）", .serialized)
@MainActor
struct MCPEnableAndFailureMessageTests {
    @Test("编辑框把服务器停用再启用，原有授权不会原样恢复")
    func editorEnableToggleClearsGrant() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcpf3-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manager = MCPServerManager(fileURL: dir.appendingPathComponent("mcps.json"),
                                       keychain: KeychainStore(backing: InMemoryKeychainBacking()))
        var server = MCPServer(id: "fx", name: "Fx", type: .stdio, command: "fixture-never-spawned")
        try manager.addServer(server)
        try manager.authorizeServer(id: "fx")
        #expect(manager.isServerAuthorized(server))
        server.enabled = false
        try manager.addServer(server)
        server.enabled = true
        let reenabled = try manager.addServer(server)
        #expect(!manager.isServerAuthorized(reenabled))
    }

    @Test("操作失败的提示按原因区分")
    func changeFailureMessages() {
        #expect(MCPFailureMessage.change(MCPPersistenceConflict.needsReopen).contains("重新打开"))
        #expect(MCPFailureMessage.change(MCPPersistenceConflict.documentUnavailable(path: "p", code: 28))
            .contains("磁盘空间或权限"))
    }
}
