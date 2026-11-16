import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("SETC MCP canonical read-only catalog", .serialized)
@MainActor
struct MCPServerStoreTypedCatalogAdapter2181Tests {
    @Test func canonicalStoreProjectsAuthorizationWithoutGrantingCatalogWritesAcrossReopen() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("setc-mcp2181-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let center = makeCenter(root: root, keychain: keychain)
        let server = MCPServer(
            id: "server.a/β", name: "Synthetic server", type: .http,
            enabled: true, command: "fixture-command-secret", args: ["fixture-arg-secret"],
            env: ["TOKEN": "fixture-env-secret"], url: "https://fixture-url-secret.invalid",
            headers: ["Authorization": "fixture-header-secret"]
        )
        try center.mcpManager.addServer(server)
        #expect(center.setMCPServerAuthorized(id: server.id, authorized: true))
        let sessionDirectory = center.sessionStore.directory
        let first = try #require(MCPServerStoreTypedCatalogAdapter.snapshot(
            from: center, sessionDirectory: sessionDirectory
        ))
        let prefix = "mcp." + server.id.utf8.map { String(format: "%02x", $0) }.joined()
        #expect(first == ["\(prefix).name": .text("Synthetic server"),
                          "\(prefix).enabled": .toggle(true),
                          "\(prefix).authorized": .toggle(true),
                          "\(prefix).type": .text("http")])
        let encoded = String(data: try JSONEncoder().encode(first), encoding: .utf8) ?? ""
        for secret in ["fixture-command-secret", "fixture-arg-secret", "fixture-env-secret",
                       "fixture-url-secret", "fixture-header-secret", "Authorization", "TOKEN"] {
            #expect(!encoded.contains(secret))
        }

        try center.mcpManager.enableServer(id: server.id, enabled: false)
        let reopened = makeCenter(root: root, keychain: keychain)
        let after = try #require(MCPServerStoreTypedCatalogAdapter.snapshot(
            from: reopened, sessionDirectory: reopened.sessionStore.directory
        ))
        #expect(after["\(prefix).name"] == .text("Synthetic server"))
        #expect(after["\(prefix).enabled"] == .toggle(false))
        #expect(after["\(prefix).authorized"] == .toggle(false))
        #expect(after["\(prefix).type"] == .text("http"))
        #expect(MCPServerStoreTypedCatalogAdapter.snapshot(
            from: center, sessionDirectory: center.sessionStore.directory
        ) == nil)
        #expect(MCPServerStoreTypedCatalogAdapter.snapshot(
            from: reopened, sessionDirectory: root.appendingPathComponent("other-sessions")
        ) == nil)
    }

    @Test func admittedToolAuthorizationIsReadOnlyAndDisappearsWhenDiscoveryIsFenced() async throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.rootDirectory.appendingPathComponent("setc-tools2876-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let center = makeCenter(root: root, keychain: keychain)
        let server = MCPServer(
            id: "tools.server/β", name: "Synthetic", type: .http,
            url: "https://synthetic.invalid"
        )
        try center.mcpManager.addServer(server)
        #expect(center.setMCPServerAuthorized(id: server.id, authorized: true))
        let tools = try await center.mcpManager.discoverTools(serverID: server.id) { server in
            MCPClient(server: server, transport: CatalogToolAuthorization2876Transport())
        }
        #expect(tools.map(\.name) == ["read.name/β", "write"])
        let prefix = "mcp." + server.id.utf8.map { String(format: "%02x", $0) }.joined()
        let readKey = prefix + ".tools."
            + "read.name/β".utf8.map { String(format: "%02x", $0) }.joined() + ".authorized"
        let writeKey = prefix + ".tools."
            + "write".utf8.map { String(format: "%02x", $0) }.joined() + ".authorized"
        func snapshot() throws -> [String: BL6SettingValue] {
            try #require(MCPServerStoreTypedCatalogAdapter.snapshot(
                from: center, sessionDirectory: center.sessionStore.directory
            ))
        }
        let beforeConfig = try Data(contentsOf: center.mcpManager.fileURL)
        let beforeGrants = try Data(contentsOf: center.mcpManager.authorizationFileURL)
        let initial = try snapshot()
        #expect(initial[readKey] == .toggle(false))
        #expect(initial[writeKey] == .toggle(false))
        let encoded = String(decoding: try JSONEncoder().encode(initial), as: UTF8.self)
        #expect(!encoded.contains("fixture-schema-secret"))
        #expect(!encoded.contains("synthetic.invalid"))
        #expect(try Data(contentsOf: center.mcpManager.fileURL) == beforeConfig)
        #expect(try Data(contentsOf: center.mcpManager.authorizationFileURL) == beforeGrants)

        // A tool grant edit changes no discovery input, so the accepted discovery
        // snapshot stays valid and the catalog shows the new grant state at once
        // (earlier this asserted the entry disappeared until a new discovery,
        // which pinned the defect that any grant edit cleared the tool list).
        // This read must still never refresh discovery: a discovery would
        // publish a new snapshot, so an unchanged publicationID proves the read
        // (and the grant edit) did not run one.
        func publication() throws -> UUID {
            try #require(center.mcpManager.discoverySnapshot(serverID: server.id)?.publicationID)
        }
        let publicationBeforeGrant = try publication()
        #expect(center.setMCPToolAuthorized(serverID: server.id, toolName: "read.name/β", authorized: true))
        #expect(try snapshot()[readKey] == .toggle(true))
        #expect(try publication() == publicationBeforeGrant)
        _ = try await center.mcpManager.discoverTools(serverID: server.id) { server in
            MCPClient(server: server, transport: CatalogToolAuthorization2876Transport())
        }
        let granted = try snapshot()
        #expect(granted[readKey] == .toggle(true))
        #expect(granted[writeKey] == .toggle(false))
        let publicationBeforeRevoke = try publication()
        #expect(center.setMCPToolAuthorized(serverID: server.id, toolName: "read.name/β", authorized: false))
        #expect(try snapshot()[readKey] == .toggle(false))
        #expect(try publication() == publicationBeforeRevoke)
        _ = try await center.mcpManager.discoverTools(serverID: server.id) { server in
            MCPClient(server: server, transport: CatalogToolAuthorization2876Transport())
        }
        #expect(try snapshot()[readKey] == .toggle(false))
        #expect(center.setMCPServerAuthorized(id: server.id, authorized: false))
        let revoked = try snapshot()
        #expect(revoked["\(prefix).authorized"] == .toggle(false))
        #expect(revoked[readKey] == nil)
        #expect(revoked[writeKey] == nil)
    }

    @Test func transportTypeTracksCanonicalNativeEditWithoutProjectingTargetsOrGrantingTools() throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let root = formal.rootDirectory.appendingPathComponent("setc-type2876-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let center = makeCenter(root: root, keychain: keychain)
        let server = MCPServer(
            id: "type2876", name: "Synthetic", type: .stdio, enabled: false,
            command: "fixture-command-secret", args: ["fixture-args-secret"],
            env: ["TOKEN": "fixture-env-secret"]
        )
        try center.mcpManager.addServer(server)
        let prefix = "mcp." + server.id.utf8.map { String(format: "%02x", $0) }.joined()
        func projection(_ owner: SettingsCenter) throws -> [String: BL6SettingValue] {
            try #require(MCPServerStoreTypedCatalogAdapter.snapshot(
                from: owner, sessionDirectory: owner.sessionStore.directory
            ))
        }
        let before = try Data(contentsOf: center.mcpManager.fileURL)
        let first = try projection(center)
        #expect(first["\(prefix).type"] == .text("stdio"))
        #expect(first["\(prefix).authorized"] == .toggle(false))
        #expect(try Data(contentsOf: center.mcpManager.fileURL) == before)
        #expect(!first.keys.contains(where: { $0.contains(".tools.") }))
        var draft = MCPServerEditDraft(existing: server)
        draft.type = .http
        draft.url = "https://fixture-target-secret.invalid"
        #expect(draft.save(to: center))
        let reopened = makeCenter(root: root, keychain: keychain)
        let after = try projection(reopened)
        #expect(after["\(prefix).type"] == .text("http"))
        #expect(after["\(prefix).authorized"] == .toggle(false))
        #expect(!after.keys.contains(where: { $0.contains(".tools.") }))
        let encoded = String(decoding: try JSONEncoder().encode(after), as: UTF8.self)
        for secret in ["fixture-command-secret", "fixture-args-secret", "fixture-env-secret",
                       "fixture-target-secret", "TOKEN"] {
            #expect(!encoded.contains(secret))
        }
        #expect(MCPServerStoreTypedCatalogAdapter.snapshot(
            from: center, sessionDirectory: center.sessionStore.directory
        ) == nil)
    }

    private func makeCenter(root: URL, keychain: KeychainStore) -> SettingsCenter {
        SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("provider"), keychain: keychain),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
            logManager: LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 10),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite("setc-mcp2181-\(UUID().uuidString)"))
        )
    }
}

private final class CatalogToolAuthorization2876Transport: MCPTransport, @unchecked Sendable {
    func start() async throws {}
    func stop() {}
    func notify(_ notification: MCPJSONRPCNotification) throws {}

    func send(_ request: MCPJSONRPCRequest) async throws -> MCPJSONRPCResponse {
        switch request.method {
        case "initialize":
            return MCPJSONRPCResponse(id: request.id, result: .object([
                "protocolVersion": .string("2024-11-05"),
                "capabilities": .object([:]),
                "serverInfo": .object(["name": .string("synthetic"), "version": .string("1")])
            ]))
        case "tools/list":
            return MCPJSONRPCResponse(id: request.id, result: .object([
                "tools": .array(["read.name/β", "write"].map { name in
                    .object([
                        "name": .string(name),
                        "description": .string("fixture-schema-secret"),
                        "inputSchema": .object(["type": .string("object"), "properties": .object([:])])
                    ])
                })
            ]))
        default:
            return MCPJSONRPCResponse(id: request.id,
                error: MCPJSONRPCError(code: -32601, message: "method not found"))
        }
    }
}
