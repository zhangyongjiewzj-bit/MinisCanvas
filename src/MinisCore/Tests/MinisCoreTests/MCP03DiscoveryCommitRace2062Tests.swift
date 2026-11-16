import Foundation
import Testing
@testable import MinisCore

@Suite("MCP03 late discovery cannot borrow a re-enabled server generation")
struct MCP03DiscoveryCommitRace2062Tests {
    @Test func reenabledServerRequiresFreshToolsListBeforeNextCatalogOrInvocation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp03-commit-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"))
        let server = MCPServer(id: "race2062", name: "Race", type: .http, url: "http://127.0.0.1:1")
        try manager.addServer(server)
        try manager.authorizeServer(id: server.id)
        try manager.authorizeTool(serverID: server.id, toolName: "old")
        let transport = MCP2062Transport()
        let factory: @Sendable (MCPServer) -> MCPClient = {
            MCPClient(server: $0, transport: transport)
        }
        let fullName = MCPBoundTool.makeFullName(serverID: server.id, toolName: "old")

        // The callback runs after the final async tools/list and its old
        // generation check, immediately before the manager's commit lock.
        // The new explicit grant is real, but it cannot authenticate bytes
        // discovered in the retired transport/configuration generation.
        var staleRejected = false
        do {
            _ = try await manager.discoverTools(
                serverID: server.id, clientFactory: factory,
                beforeCommit: {
                    _ = try manager.enableServer(id: server.id, enabled: false)
                    _ = try manager.enableServer(id: server.id, enabled: true)
                    _ = try manager.authorizeServer(id: server.id)
                    _ = try manager.authorizeTool(serverID: server.id, toolName: "old")
                }
            )
        } catch MCPDiscoveryError.stale(let serverID) {
            staleRejected = serverID == server.id
        }
        #expect(staleRejected)
        #expect(manager.discoverySnapshot(serverID: server.id) == nil)

        let registry = MCPToolRegistry(manager: manager, clientFactory: factory)
        defer { registry.disconnectAll() }
        let nextTurn = try registry.snapshotForTurn()
        let definitions = try await AgentToolCatalog.makeTools(includingMCPFrom: nextTurn)
        #expect(!definitions.contains { $0.name == fullName })
        await #expect(throws: MCPClientError.toolNotFound(fullName)) {
            _ = try await nextTurn.callMCPTool(fullName: fullName, arguments: nil)
        }
        #expect(transport.calls == 0)

        // A new successful list under the new generation restores the
        // explicitly granted tool; the failure does not silently revoke it.
        try await registry.refreshTools()
        let refreshed = try registry.snapshotForTurn()
        let allowed = try await AgentToolCatalog.makeTools(includingMCPFrom: refreshed)
        #expect(allowed.contains { $0.name == fullName })
    }
}

private final class MCP2062Transport: MCPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }

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
                "tools": .array([.object([
                    "name": .string("old"),
                    "inputSchema": .object(["type": .string("object")])
                ])])
            ]))
        case "tools/call":
            lock.withLock { _calls += 1 }
            return MCPJSONRPCResponse(id: request.id, result: .object([
                "content": .array([.object(["type": .string("text"), "text": .string("unexpected")])])
            ]))
        default:
            return MCPJSONRPCResponse(id: request.id,
                                      error: MCPJSONRPCError(code: -32601, message: "unknown"))
        }
    }
}

/// Granting one tool of an already discovered server is a grant mutation, not a
/// change of the remote schema. The accepted tools/list result must stay
/// available to the settings page, the live registry and the next session.
@Suite("MCP authorizeTool keeps the accepted discovery snapshot")
struct MCPAuthorizeToolKeepsDiscoverySnapshotTests {
    private struct Fixture {
        let root: URL
        let manager: MCPServerManager
        let transport: MCPAuthorizeSnapshotTransport
        let factory: @Sendable (MCPServer) -> MCPClient
        let server: MCPServer
        var alphaName: String { MCPBoundTool.makeFullName(serverID: server.id, toolName: "alpha") }
        var betaName: String { MCPBoundTool.makeFullName(serverID: server.id, toolName: "beta") }
    }

    /// Server authorized, no tool authorized yet, one real discovery already done.
    private func discoveredFixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-authorize-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let manager = MCPServerManager(fileURL: root.appendingPathComponent("mcps.json"),
                                       keychain: KeychainStore(backing: InMemoryKeychainBacking()))
        let server = MCPServer(id: "authz-snap", name: "AuthzSnap", type: .http, url: "http://127.0.0.1:1")
        try manager.addServer(server)
        try manager.authorizeServer(id: server.id)
        let transport = MCPAuthorizeSnapshotTransport()
        let factory: @Sendable (MCPServer) -> MCPClient = { MCPClient(server: $0, transport: transport) }
        _ = try await manager.discoverTools(serverID: server.id, clientFactory: factory)
        return Fixture(root: root, manager: manager, transport: transport, factory: factory, server: server)
    }

    @Test func authorizingOneToolKeepsTheDiscoveredToolSet() async throws {
        let fixture = try await discoveredFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = fixture.manager
        let before = try #require(manager.discoverySnapshot(serverID: fixture.server.id))
        #expect(before.tools.map(\.name) == ["alpha", "beta"])
        #expect(fixture.transport.listCalls == 1)

        try manager.authorizeTool(serverID: fixture.server.id, toolName: "alpha")

        let after = manager.discoverySnapshot(serverID: fixture.server.id)
        #expect(after != nil)
        #expect(after?.tools == before.tools)
        #expect(manager.cachedTools(serverID: fixture.server.id).map(\.name) == ["alpha", "beta"])
        #expect(manager.isToolAuthorized(serverID: fixture.server.id, toolName: "alpha"))
        #expect(!manager.isToolAuthorized(serverID: fixture.server.id, toolName: "beta"))
        #expect(fixture.transport.listCalls == 1)
    }

    @Test func liveRegistryServesTheNewlyAuthorizedToolWithoutANewToolsList() async throws {
        let fixture = try await discoveredFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let registry = MCPToolRegistry(manager: fixture.manager, clientFactory: fixture.factory)
        defer { registry.disconnectAll() }
        let listsBefore = fixture.transport.listCalls

        try fixture.manager.authorizeTool(serverID: fixture.server.id, toolName: "alpha")
        let bound = try await registry.mcpBoundTools()

        #expect(bound.map(\.fullName) == [fixture.alphaName])
        #expect(fixture.transport.listCalls == listsBefore)
    }

    @Test func nextSessionSnapshotContainsTheNewlyAuthorizedToolWithoutRediscovery() async throws {
        let fixture = try await discoveredFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let registry = MCPToolRegistry(manager: fixture.manager, clientFactory: fixture.factory)
        defer { registry.disconnectAll() }

        try fixture.manager.authorizeTool(serverID: fixture.server.id, toolName: "alpha")
        let nextSession = try registry.snapshotForTurn()
        let bound = try await nextSession.mcpBoundTools()
        let definitions = try await AgentToolCatalog.makeTools(includingMCPFrom: nextSession)

        #expect(bound.map(\.fullName) == [fixture.alphaName])
        #expect(definitions.contains { $0.name == fixture.alphaName })
        #expect(!definitions.contains { $0.name == fixture.betaName })
        #expect(fixture.transport.listCalls == 1)
    }

    /// Settings ticks tools one after another. Granting the second must not
    /// drop the first because the snapshot was invalidated in between (an
    /// invalid snapshot makes authorizeTool bind the empty digest, which
    /// resets the grant to the single new tool).
    @Test func authorizingTwoToolsInARowKeepsBothGrants() async throws {
        let fixture = try await discoveredFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try fixture.manager.authorizeTool(serverID: fixture.server.id, toolName: "alpha")
        try fixture.manager.authorizeTool(serverID: fixture.server.id, toolName: "beta")

        #expect(fixture.manager.authorization(serverID: fixture.server.id)?.authorizedToolNames == Set(["alpha", "beta"]))
        #expect(fixture.manager.isToolAuthorized(serverID: fixture.server.id, toolName: "alpha"))
        #expect(fixture.manager.isToolAuthorized(serverID: fixture.server.id, toolName: "beta"))
        #expect(fixture.transport.listCalls == 1)
    }

    @Test func revokingOneOfTwoGrantedToolsLeavesTheOtherBound() async throws {
        let fixture = try await discoveredFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let registry = MCPToolRegistry(manager: fixture.manager, clientFactory: fixture.factory)
        defer { registry.disconnectAll() }
        try fixture.manager.authorizeTool(serverID: fixture.server.id, toolName: "alpha")
        try fixture.manager.authorizeTool(serverID: fixture.server.id, toolName: "beta")
        try fixture.manager.revokeTool(serverID: fixture.server.id, toolName: "beta")

        let bound = try await registry.mcpBoundTools()

        #expect(fixture.manager.authorization(serverID: fixture.server.id)?.authorizedToolNames == Set(["alpha"]))
        #expect(bound.map(\.fullName) == [fixture.alphaName])
    }

    /// A failed refresh observed the publication that existed when it started.
    /// A grant change in between re-stamps that same publication to a new
    /// revision (new `id`/`revision`, same `publicationID`). It must still be the
    /// publication the failure may retire; the grant change must not let a dead
    /// transport's catalog escape retirement and stay advertised.
    @Test func failedRefreshStillRetiresThePublicationRestampedByAGrantChange() async throws {
        let fixture = try await discoveredFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = fixture.manager
        let old = try #require(manager.discoverySnapshot(serverID: fixture.server.id))

        try manager.authorizeTool(serverID: fixture.server.id, toolName: "alpha")

        let restamped = try #require(manager.discoverySnapshot(serverID: fixture.server.id))
        #expect(restamped.id != old.id)
        #expect(restamped.publicationID == old.publicationID)
        #expect(restamped.tools == old.tools)

        #expect(try manager.retireDiscoveryAfterFailedRefresh(serverID: fixture.server.id, expected: old) == true)
        #expect(manager.discoverySnapshot(serverID: fixture.server.id) == nil)
        #expect(manager.cachedTools(serverID: fixture.server.id).isEmpty)
    }

    // MARK: Guard rails (expected GREEN before and after the fix)

    /// Without any grant change the exact observed publication is retired.
    @Test func failedRefreshRetiresTheUnchangedObservedPublication() async throws {
        let fixture = try await discoveredFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let old = try #require(fixture.manager.discoverySnapshot(serverID: fixture.server.id))

        #expect(try fixture.manager.retireDiscoveryAfterFailedRefresh(serverID: fixture.server.id, expected: old) == true)
        #expect(fixture.manager.discoverySnapshot(serverID: fixture.server.id) == nil)
    }

    /// A genuinely newer publication (new `publicationID`) survives an obsolete
    /// failure, even when a grant change had re-stamped the older one first.
    @Test func newerDiscoveryIsNotRetiredByAnObsoleteFailure() async throws {
        let fixture = try await discoveredFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = fixture.manager
        let old = try #require(manager.discoverySnapshot(serverID: fixture.server.id))
        try manager.authorizeTool(serverID: fixture.server.id, toolName: "alpha")

        _ = try await manager.discoverTools(serverID: fixture.server.id, clientFactory: fixture.factory)
        let fresh = try #require(manager.discoverySnapshot(serverID: fixture.server.id))
        #expect(fresh.publicationID != old.publicationID)

        #expect(try manager.retireDiscoveryAfterFailedRefresh(serverID: fixture.server.id, expected: old) == false)
        #expect(manager.discoverySnapshot(serverID: fixture.server.id) == fresh)
    }


    /// A revoked tool is no longer bound.
    @Test func revokedToolIsNoLongerBound() async throws {
        let fixture = try await discoveredFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let registry = MCPToolRegistry(manager: fixture.manager, clientFactory: fixture.factory)
        defer { registry.disconnectAll() }
        try fixture.manager.authorizeTool(serverID: fixture.server.id, toolName: "alpha")
        try fixture.manager.revokeTool(serverID: fixture.server.id, toolName: "alpha")

        let bound = try await registry.mcpBoundTools()

        #expect(bound.isEmpty)
        #expect(!fixture.manager.isToolAuthorized(serverID: fixture.server.id, toolName: "alpha"))
    }

    /// A changed server descriptor must still retire the accepted snapshot.
    @Test func changedServerDescriptorStillInvalidatesTheSnapshot() async throws {
        let fixture = try await discoveredFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect(fixture.manager.discoverySnapshot(serverID: fixture.server.id) != nil)

        try fixture.manager.addServer(MCPServer(id: fixture.server.id, name: fixture.server.name,
                                                type: .http, url: "http://127.0.0.1:2"))

        #expect(fixture.manager.discoverySnapshot(serverID: fixture.server.id) == nil)
        #expect(fixture.manager.cachedTools(serverID: fixture.server.id).isEmpty)
    }

    /// A changed remote tool schema must still revoke tool grants on the next
    /// real discovery (A -> B must not inherit A's grant).
    @Test func changedRemoteSchemaStillRevokesAnExistingToolGrant() async throws {
        let fixture = try await discoveredFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.manager.authorizeTool(serverID: fixture.server.id, toolName: "alpha")

        fixture.transport.changeSchema()
        _ = try await fixture.manager.discoverTools(serverID: fixture.server.id, clientFactory: fixture.factory)

        #expect(!fixture.manager.isToolAuthorized(serverID: fixture.server.id, toolName: "alpha"))
        #expect(fixture.manager.authorization(serverID: fixture.server.id)?.authorizedToolNames.isEmpty == true)
    }

    /// Control for the harness: an explicit rediscovery of an unchanged schema
    /// keeps the grant, so the RED cases above are about the snapshot, not the grant.
    @Test func unchangedRemoteSchemaRediscoveryKeepsAnExistingToolGrant() async throws {
        let fixture = try await discoveredFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.manager.authorizeTool(serverID: fixture.server.id, toolName: "alpha")

        _ = try await fixture.manager.discoverTools(serverID: fixture.server.id, clientFactory: fixture.factory)

        #expect(fixture.manager.isToolAuthorized(serverID: fixture.server.id, toolName: "alpha"))
        #expect(fixture.manager.discoverySnapshot(serverID: fixture.server.id)?.tools.map(\.name) == ["alpha", "beta"])
    }
}

private final class MCPAuthorizeSnapshotTransport: MCPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var lists = 0
    private var schemaVersion = 0
    var listCalls: Int { lock.withLock { lists } }
    func changeSchema() { lock.withLock { schemaVersion += 1 } }

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
            let version = lock.withLock { () -> Int in lists += 1; return schemaVersion }
            return MCPJSONRPCResponse(id: request.id, result: .object([
                "tools": .array(["alpha", "beta"].map { name in
                    .object([
                        "name": .string(name),
                        "description": .string("\(name) schema v\(version)"),
                        "inputSchema": .object(["type": .string("object"), "title": .string("\(name)-v\(version)")])
                    ])
                })
            ]))
        default:
            return MCPJSONRPCResponse(id: request.id,
                                      error: MCPJSONRPCError(code: -32601, message: "unknown"))
        }
    }
}
