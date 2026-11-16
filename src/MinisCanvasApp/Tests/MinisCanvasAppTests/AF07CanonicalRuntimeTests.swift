import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("AF-07 canonical runtime")
@MainActor
struct AF07CanonicalRuntimeTests {
    @Test("settings MCP and Skill stores are the production canonical instances")
    func productionCompositionUsesSettingsStores() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("af07-canonical-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let settingsStore = SettingsStore(directory: root.appendingPathComponent("settings"))
        let envStore = EnvVarStore(directory: root.appendingPathComponent("env"))
        let sessionStore = SessionStore(directory: root.appendingPathComponent("sessions"))
        let memoryStore = MemoryStore(directory: root.appendingPathComponent("memory"))
        let mcpManager = MCPServerManager(
            fileURL: root.appendingPathComponent("mcps.json")
        )
        let skillStore = SkillStore(
            skillsRoot: root.appendingPathComponent("skills")
        )
        let settings = SettingsCenter(
            settingsStore: settingsStore,
            envStore: envStore,
            memoryStore: memoryStore,
            sessionStore: sessionStore,
            mcpManager: mcpManager,
            skillStore: skillStore
        )
        let bridge = BridgeStore()

        bridge.attachProductionServices(
            sessionDirectory: sessionStore.directory,
            mcpManager: settings.mcpManager,
            skillStore: settings.skillStore
        )

        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let scopedBridge = try #require(engine.mcpBridge as? TurnScopedMCPToolBridge)
        let registry = try #require(scopedBridge.base as? MCPToolRegistry)
        let runtimeSkills = try #require(engine.chatRuntimeDependencies?.skillStore)
        #expect(registry.manager === settings.mcpManager)
        #expect(runtimeSkills === settings.skillStore)
    }

    @Test("skill injection returns receipts with omission reasons under budget")
    func skillInjectionProducesAuditableReceipts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("af07-skill-receipt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SkillStore(skillsRoot: root)
        _ = try store.importSkill(content: """
        ---
        name: receipt-skill
        description: receipt keyword alpha
        ---

        \(String(repeating: "x", count: 600))
        """)
        _ = try store.importSkill(content: """
        ---
        name: omitted-skill
        description: receipt keyword
        ---

        \(String(repeating: "y", count: 600))
        """)

        let injector = SkillInjector(
            store: store,
            maxInjectedCharacters: 800
        )
        let result = injector.buildInjection(for: "receipt keyword alpha")

        #expect(result.fragment != nil)
        #expect(result.receipts.count == 2)
        #expect(result.receipts.contains { $0.skillID == "receipt-skill" && $0.omittedReason == nil })
        #expect(result.receipts.contains { $0.skillID == "omitted-skill" && $0.omittedReason != nil })
        #expect(result.receipts.allSatisfy { $0.contentHash.isEmpty == false })
        let receiptIDs = result.receipts.map(\.receiptID)
        #expect(Set(receiptIDs).count == receiptIDs.count)
    }

    @Test("MCP settings changes affect new turns but not a captured turn snapshot")
    func mcpTurnSnapshotIsImmutable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("af07-mcp-snapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let manager = MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"))
        let server = MCPServer(
            id: "snapshot-server",
            name: "Snapshot Server",
            type: .http,
            enabled: true,
            url: "http://127.0.0.1:1"
        )
        try manager.addServer(server)
        try manager.authorizeServer(id: server.id)
        try manager.authorizeTool(serverID: server.id, toolName: "greet")

        let registry = MCPToolRegistry(manager: manager)
        let turnRegistry = try #require((try registry.snapshotForTurn()) as? MCPToolRegistry)
        try manager.enableServer(id: server.id, enabled: false)

        #expect(manager.server(id: server.id)?.enabled == false)
        #expect(turnRegistry.manager.server(id: server.id)?.enabled == true)
        #expect(turnRegistry.manager.isToolAuthorized(serverID: server.id, toolName: "greet"))
    }
}
