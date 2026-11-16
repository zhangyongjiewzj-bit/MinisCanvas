import Foundation
import Testing
@testable import MinisCore

@Suite("2233 MCP name settings canonical Store transaction")
struct MCPBL6NameTransaction2233Tests {
    private func fixture() throws -> (MCPServerManager, URL, String) {
        let formal = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = formal.rootDirectory.appendingPathComponent("mcp2233-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let file = root.appendingPathComponent("mcps.json")
        let manager = MCPServerManager(
            fileURL: file,
            keychain: KeychainStore(backing: InMemoryKeychainBacking())
        )
        try manager.addServer(MCPServer(
            id: "synthetic", name: "Before", type: .http,
            enabled: false, url: "https://mcp.invalid"
        ))
        return (manager, root, root.path)
    }

    private func record(
        manager: MCPServerManager, profileID: String, requestID: String,
        newName: String = "After"
    ) throws -> BL6SettingsReplayRecord {
        let key = "mcp." + "synthetic".utf8.map { String(format: "%02x", $0) }.joined() + ".name"
        let revision = try #require(manager.bl6NameRevision())
        let input = BL6SettingsApprovedInput(
            operation: .apply, changes: [key: .text(newName)],
            expectedRevision: revision
        )
        let ready = try manager.prepareBL6NameReplay(input, profileID: profileID).get()
        let receipt = BL6SettingsReceipt(
            requestID: requestID, operation: .apply,
            previousRevision: ready.previousRevision,
            effectiveRevision: ready.effectiveRevision,
            changedKeys: ready.changedKeys, rollbackValues: [:]
        )
        return BL6SettingsReplayRecord(
            requestID: requestID, payloadDigest: "synthetic-bound-digest",
            frozenInput: input, approvalBindingDigest: "synthetic-exact-call",
            profileID: profileID, scope: "session", sessionID: "synthetic-session",
            policyRevision: "synthetic-policy", grantEpoch: "synthetic-grant",
            approvalExpiresAt: Date().addingTimeInterval(60),
            operation: .apply, receipt: receipt,
            rollbackValues: ready.rollbackValues
        )
    }

    @Test("descriptor drift rejects a prepared name without changing config or grant")
    func descriptorDriftRejectsPreparedWrite() throws {
        let (manager, root, profileID) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let proposal = try record(manager: manager, profileID: profileID, requestID: "mcp2233-drift")
        let changed = MCPServer(
            id: "synthetic", name: "Before", type: .http,
            enabled: false, url: "https://changed.invalid"
        )
        try manager.updateServer(changed)
        #expect(manager.commitBL6NameReplay(proposal, profileID: profileID) == .failure(.staleRevision))
        #expect(manager.server(id: "synthetic") == changed)
        #expect(try manager.bl6NameReplayRecord(
            for: proposal.requestID, profileID: profileID
        ).get() == nil)
    }

    @Test("revoking an MCP server grant invalidates a prepared name receipt")
    func grantRevocationRejectsPreparedWrite() throws {
        let (manager, root, profileID) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try manager.authorizeServer(id: "synthetic")
        let proposal = try record(manager: manager, profileID: profileID, requestID: "mcp2233-revoked")
        _ = try manager.revokeServer(id: "synthetic")
        #expect(manager.authorization(serverID: "synthetic") == nil)
        #expect(manager.commitBL6NameReplay(proposal, profileID: profileID) == .failure(.staleRevision))
        #expect(manager.server(id: "synthetic")?.name == "Before")
        #expect(try manager.bl6NameReplayRecord(
            for: proposal.requestID, profileID: profileID
        ).get() == nil)
    }

    @Test("blocked canonical write publishes neither name nor replay receipt")
    func writeFailurePublishesNoReceipt() throws {
        let (manager, root, profileID) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let proposal = try record(manager: manager, profileID: profileID, requestID: "mcp2233-fault")
        try FileManager.default.removeItem(at: manager.fileURL)
        try FileManager.default.createDirectory(at: manager.fileURL, withIntermediateDirectories: false)
        #expect(manager.commitBL6NameReplay(proposal, profileID: profileID)
            == .failure(.persistence(.writeFailed)))
        #expect(manager.server(id: "synthetic")?.name == "Before")
        #expect(try manager.bl6NameReplayRecord(
            for: proposal.requestID, profileID: profileID
        ).get() == nil)
        let reopened = MCPServerManager(
            fileURL: manager.fileURL,
            keychain: KeychainStore(backing: InMemoryKeychainBacking())
        )
        #expect(reopened.bl6NameRevision() == nil)
    }
}
