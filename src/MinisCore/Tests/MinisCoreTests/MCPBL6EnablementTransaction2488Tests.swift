import Foundation
import Testing
@testable import MinisCore

@Suite("2488 approved MCP enablement replays without reviving grants")
struct MCPBL6EnablementTransaction2488Tests {
    private func fixture() throws -> (manager: MCPServerManager, root: URL, profileID: String) {
        let formal = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = formal.rootDirectory.appendingPathComponent("mcp-enabled-bl6-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let manager = MCPServerManager(
            fileURL: root.appendingPathComponent("mcps.json"),
            keychain: KeychainStore(backing: InMemoryKeychainBacking()),
            authorizationFileURL: root.appendingPathComponent("mcp-authorizations.json")
        )
        try manager.addServer(MCPServer(
            id: "synthetic", name: "Synthetic", type: .http,
            enabled: true, url: "https://mcp.invalid"
        ))
        _ = try manager.authorizeServer(id: "synthetic")
        return (manager, root, root.path)
    }

    private func reopen(_ manager: MCPServerManager) -> MCPServerManager {
        MCPServerManager(
            fileURL: manager.fileURL,
            keychain: KeychainStore(backing: InMemoryKeychainBacking()),
            authorizationFileURL: manager.authorizationFileURL
        )
    }

    private func record(
        manager: MCPServerManager, profileID: String, requestID: String,
        operation: BL6SettingsOperation = .apply, enabled: Bool = false,
        undoReceiptID: String? = nil
    ) throws -> BL6SettingsReplayRecord {
        let key = "mcp." + "synthetic".utf8.map { String(format: "%02x", $0) }.joined() + ".enabled"
        let revision = try #require(manager.bl6NameRevision())
        let input = BL6SettingsApprovedInput(
            operation: operation,
            changes: operation == .apply ? [key: .toggle(enabled)] : [:],
            expectedRevision: revision, undoReceiptID: undoReceiptID
        )
        let ready = try manager.prepareBL6EnablementReplay(input, profileID: profileID).get()
        let receipt = BL6SettingsReceipt(
            requestID: requestID, operation: operation,
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
            operation: operation, receipt: receipt,
            rollbackValues: ready.rollbackValues
        )
    }

    @Test("approved disable and undo survive reopen without restoring the old grant")
    func committedDisableAndUndoStayBoundToOneCanonicalServer() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let disable = try record(manager: f.manager, profileID: f.profileID, requestID: "disable")
        #expect(f.manager.commitBL6EnablementReplay(disable, profileID: f.profileID)
            == .success(disable.receipt))
        let disabled = reopen(f.manager)
        #expect(disabled.server(id: "synthetic")?.enabled == false)
        #expect(disabled.authorization(serverID: "synthetic") == nil)
        #expect(disabled.commitBL6EnablementReplay(disable, profileID: f.profileID)
            == .success(disable.receipt))
        #expect(disabled.commitBL6EnablementReplay(disable, profileID: "other-root")
            == .failure(.conflict))
        let undo = try record(
            manager: disabled, profileID: f.profileID, requestID: "undo",
            operation: .rollback, undoReceiptID: disable.receipt.receiptID
        )
        #expect(disabled.commitBL6EnablementReplay(undo, profileID: f.profileID)
            == .success(undo.receipt))
        let enabled = reopen(disabled)
        #expect(enabled.server(id: "synthetic")?.enabled == true)
        #expect(enabled.authorization(serverID: "synthetic") == nil)
        let replay = try enabled.bl6EnablementReplayRecord(for: undo.requestID, profileID: f.profileID).get()
        #expect(replay == undo)
    }

    @Test("descriptor drift invalidates a prepared enablement write before any grant retirement")
    func descriptorDriftRejectsPreparedWrite() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let prepared = try record(manager: f.manager, profileID: f.profileID, requestID: "drift")
        let changed = MCPServer(
            id: "synthetic", name: "Synthetic", type: .http,
            enabled: true, url: "https://changed.invalid"
        )
        try f.manager.updateServer(changed)
        #expect(f.manager.commitBL6EnablementReplay(prepared, profileID: f.profileID)
            == .failure(.conflict))
        #expect(f.manager.server(id: "synthetic") == changed)
        let replay = try f.manager.bl6EnablementReplayRecord(
            for: prepared.requestID, profileID: f.profileID
        ).get()
        #expect(replay == nil)
    }

    @Test("a preflight-blocked canonical write leaves the old state without a receipt")
    func blockedConfigurationWriteLeavesOldExactState() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let prepared = try record(manager: f.manager, profileID: f.profileID, requestID: "blocked")
        let escrow = f.root.appendingPathComponent("config.escrow")
        try FileManager.default.moveItem(at: f.manager.fileURL, to: escrow)
        try FileManager.default.createDirectory(at: f.manager.fileURL, withIntermediateDirectories: false)
        #expect(f.manager.commitBL6EnablementReplay(prepared, profileID: f.profileID)
            == .failure(.persistence(.writeFailed)))
        #expect(f.manager.authorization(serverID: "synthetic") != nil)
        try FileManager.default.removeItem(at: f.manager.fileURL)
        try FileManager.default.moveItem(at: escrow, to: f.manager.fileURL)
        let original = reopen(f.manager)
        #expect(original.server(id: "synthetic")?.enabled == true)
        #expect(original.authorization(serverID: "synthetic") != nil)
    }
}
