import Foundation
import Testing
@testable import MinisCore

@Suite("2488 MCP enablement never revives an earlier grant")
struct MCPEnablementRevocation2488Tests {
    private func fixture() throws -> (manager: MCPServerManager, root: URL, file: URL, authorization: URL) {
        let formal = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = formal.rootDirectory.appendingPathComponent("mcp2488-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let file = root.appendingPathComponent("mcps.json")
        let authorization = root.appendingPathComponent("mcp-authorizations.json")
        let manager = MCPServerManager(
            fileURL: file,
            keychain: KeychainStore(backing: InMemoryKeychainBacking()),
            authorizationFileURL: authorization
        )
        try manager.addServer(MCPServer(
            id: "owned-2488", name: "Owned", type: .http,
            enabled: true, url: "https://mcp.invalid"
        ))
        _ = try manager.authorizeServer(id: "owned-2488")
        #expect(manager.authorization(serverID: "owned-2488") != nil)
        return (manager, root, file, authorization)
    }

    private func reopen(file: URL, authorization: URL) -> MCPServerManager {
        MCPServerManager(
            fileURL: file,
            keychain: KeychainStore(backing: InMemoryKeychainBacking()),
            authorizationFileURL: authorization
        )
    }

    @Test("disable, reopen and re-enable require a new explicit server grant")
    func disableAndReenableCannotResurrectGrant() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let oldGrantDocument = try Data(contentsOf: f.authorization)
        _ = try f.manager.enableServer(id: "owned-2488", enabled: false)
        let disabled = reopen(file: f.file, authorization: f.authorization)
        #expect(disabled.server(id: "owned-2488")?.enabled == false)
        #expect(disabled.authorization(serverID: "owned-2488") == nil)

        // A stale pre-disable companion document is a synthetic version of a
        // legacy partial write. A disabled server must not import its grant.
        try oldGrantDocument.write(to: f.authorization, options: .atomic)
        let stale = reopen(file: f.file, authorization: f.authorization)
        #expect(stale.authorization(serverID: "owned-2488") == nil)
        _ = try stale.enableServer(id: "owned-2488", enabled: true)
        let enabled = reopen(file: f.file, authorization: f.authorization)
        #expect(enabled.server(id: "owned-2488")?.enabled == true)
        #expect(enabled.authorization(serverID: "owned-2488") == nil)
        _ = try enabled.authorizeServer(id: "owned-2488")
        #expect(enabled.authorization(serverID: "owned-2488") != nil)
        // Repeating the same state is not a new transition.
        _ = try enabled.enableServer(id: "owned-2488", enabled: true)
        #expect(enabled.authorization(serverID: "owned-2488") != nil)
    }

    @Test("failed authorization write cannot publish a new enabled bit or live grant")
    func failedFirstWriteLeavesConfigUnpublished() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let beforeConfig = try Data(contentsOf: f.file)
        let escrow = f.root.appendingPathComponent("old-authorizations.escrow")
        try FileManager.default.moveItem(at: f.authorization, to: escrow)
        try FileManager.default.createDirectory(at: f.authorization, withIntermediateDirectories: false)
        var failed = false
        do {
            _ = try f.manager.enableServer(id: "owned-2488", enabled: false)
        } catch {
            failed = true
        }
        #expect(failed)
        let afterConfig = try Data(contentsOf: f.file)
        #expect(afterConfig == beforeConfig)
        #expect(f.manager.authorization(serverID: "owned-2488") == nil)
        #expect(f.manager.bl6NameRevision() == nil)
        try FileManager.default.removeItem(at: f.authorization)
        try FileManager.default.moveItem(at: escrow, to: f.authorization)
        let unchanged = reopen(file: f.file, authorization: f.authorization)
        #expect(unchanged.server(id: "owned-2488")?.enabled == true)
    }

    @Test("failed configuration write leaves the prior server state but retires its grant")
    func failedSecondWriteCannotLeaveAnExecutableOldGrant() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let escrow = f.root.appendingPathComponent("old-config.escrow")
        try FileManager.default.moveItem(at: f.file, to: escrow)
        try FileManager.default.createDirectory(at: f.file, withIntermediateDirectories: false)
        var failed = false
        do {
            _ = try f.manager.enableServer(id: "owned-2488", enabled: false)
        } catch {
            failed = true
        }
        #expect(failed)
        #expect(f.manager.authorization(serverID: "owned-2488") == nil)
        #expect(f.manager.bl6NameRevision() == nil)
        try FileManager.default.removeItem(at: f.file)
        try FileManager.default.moveItem(at: escrow, to: f.file)
        let reopened = reopen(file: f.file, authorization: f.authorization)
        #expect(reopened.server(id: "owned-2488")?.enabled == true)
        #expect(reopened.authorization(serverID: "owned-2488") == nil)
        let server = try #require(reopened.server(id: "owned-2488"))
        #expect(reopened.isServerAuthorized(server) == false)
    }
    @Test("revoke-only fence rejects a broader grant without touching either document")
    func revokeOnlyFenceCannotExpandAuthorization() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let lease = try MCPPersistentWriteFence.acquire(configURL: f.file, authorizationURL: f.authorization)
        defer { lease.release() }
        let baseline = try lease.token(maxBytes: 1_048_576)
        let original = try Data(contentsOf: f.authorization)
        let config = try Data(contentsOf: f.file)
        let escrow = f.root.appendingPathComponent("old-config.escrow")
        try FileManager.default.moveItem(at: f.file, to: escrow)
        try FileManager.default.createDirectory(at: f.file, withIntermediateDirectories: false)
        var document = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var grants = try #require(document["authorizations"] as? [[String: Any]])
        try #require(grants.count == 1)
        grants[0]["authorizedToolNames"] = ["newly-granted-tool"]
        document["authorizations"] = grants
        let broader = try JSONSerialization.data(withJSONObject: document)
        var writerCalled = false
        #expect(throws: MCPPersistentWriteFence.Lease.RevocationError.authorizationExpansion) {
            try lease.replaceAuthorizationsRevokingOnly(
                broader, matching: baseline.authorization, maxBytes: 1_048_576
            ) { _, _, _ in writerCalled = true }
        }
        #expect(!writerCalled)
        #expect(try Data(contentsOf: f.authorization) == original)
        #expect(try Data(contentsOf: escrow) == config)
        var directory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: f.file.path, isDirectory: &directory) && directory.boolValue)
    }

}
