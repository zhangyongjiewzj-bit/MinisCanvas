import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private struct Retention2123NoNetwork: SettingsProviderReadinessTransport {
    func send(_ request: ProviderReadinessTransportRequest) async throws -> ProviderReadinessTransportResponse {
        throw URLError(.notConnectedToInternet)
    }
}

@Suite("D-STORAGE04 retention and actual trash consumers")
@MainActor
struct RetentionTrashConsumer2123Tests {
    private let now = Date(timeIntervalSince1970: 1_600_000_000)

    private func fixture(existingRoot: URL? = nil) throws -> (SettingsCenter, URL) {
        let root = existingRoot ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("retention2123-\(UUID().uuidString)", isDirectory: true)
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            memoryFileStore: MemoryFileStore(directory: root.appendingPathComponent("memory-files")),
            sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            logManager: LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 20),
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcp/mcps.json"), keychain: keychain),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite(root.lastPathComponent)),
            providerReadinessTransport: Retention2123NoNetwork(),
            providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("readiness")))
        center.sessionRetentionDays = 30
        return (center, root)
    }

    private func files(_ root: URL) throws -> [String: Data] {
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let enumerator = try #require(FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        var result: [String: Data] = [:]
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                let canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL
                #expect(canonicalURL.path.hasPrefix(canonicalRoot.path + "/"))
                result[String(canonicalURL.path.dropFirst(canonicalRoot.path.count + 1))] = try Data(contentsOf: url)
            }
        }
        return result
    }

    private func session(_ center: SettingsCenter, title: String, ageOffset: TimeInterval) throws -> MinisCore.ChatSession {
        var session = try center.sessionStore.createSession(title: title)
        try center.sessionStore.saveMessage(LLMMessage(role: .user, content: "synthetic payload \(title)"), sessionID: session.id)
        session = try #require(center.sessionStore.loadSession(id: session.id))
        session.updatedAt = now.addingTimeInterval(-30 * 86_400 + ageOffset)
        try center.sessionStore.updateSession(session)
        return session
    }

    private func confirmed(_ intent: OperationIntent) -> OperationIntent {
        intent.withFirstConfirmation("已核对合成会话精确预览")
            .withSecondConfirmation("确认将本批会话移入回收站")
    }

    @Test("retention confirmation preserves exact and newer cutoff bytes and moves only stale payload to owned trash")
    func retentionBoundaryAndActualBatchTrash() throws {
        let (center, root) = try fixture()
        let stale = try session(center, title: "stale", ageOffset: -1)
        let exact = try session(center, title: "exact", ageOffset: 0)
        let newer = try session(center, title: "newer", ageOffset: 1)
        try center.memoryStore.addFact("unrelated synthetic memory")
        let before = try files(root)
        let sessionPrefix = String(center.sessionStore.sessionsDirectory.resolvingSymlinksInPath().standardizedFileURL.path
            .dropFirst(root.resolvingSymlinksInPath().standardizedFileURL.path.count + 1))
        let stalePayload = try #require(before["\(sessionPrefix)/\(stale.id).json"],
            Comment(rawValue: "synthetic prefix=\(sessionPrefix), owned filenames=\(before.keys.sorted())"))
        let preview = try center.previewSessionsOlderThanRetention(now: now)
        #expect(preview.affectedCount == 1 && preview.reversible)
        #expect(try files(root) == before)
        #expect(throws: DeletionGateError.firstConfirmationRequired) {
            _ = try center.deleteSessionsOlderThanRetention(intent: preview, now: now)
        }
        #expect(try files(root) == before)
        var deletedIDs: [String] = []
        center.onConfirmedSessionDeletion = { deletedIDs = $0 }
        let receipt = try center.deleteSessionsOlderThanRetention(intent: confirmed(preview), now: now)
        #expect(receipt.operationID == preview.operationID && receipt.scopeID == preview.scopeID)
        #expect(receipt.affectedCount == 1 && receipt.outcome == "deleted")
        #expect(deletedIDs == [stale.id])
        #expect(center.sessionStore.loadSession(id: stale.id) == nil)
        #expect(center.sessionStore.loadSession(id: exact.id) == exact)
        #expect(center.sessionStore.loadSession(id: newer.id) == newer)
        let after = try files(root)
        for id in [exact.id, newer.id] {
            let original = try #require(before["\(sessionPrefix)/\(id).json"])
            #expect(after["\(sessionPrefix)/\(id).json"] == original)
        }
        #expect(!before.filter { $0.key.hasPrefix("memory/") }.isEmpty)
        #expect(after.filter { $0.key.hasPrefix("memory/") } == before.filter { $0.key.hasPrefix("memory/") })
        let trashJSON = after.filter { $0.key.hasPrefix("\(sessionPrefix)/_trash/") && $0.key.hasSuffix(".json") }
        // The native receipt index is a second JSON file, not a second session.
        let trash = trashJSON.filter {
            UUID(uuidString: URL(fileURLWithPath: $0.key).deletingPathExtension().lastPathComponent) != nil
        }
        #expect(trashJSON.count == 2)
        #expect(trash.count == 1)
        // This aggregate is not a per-session restore capability. Keep the
        // actual scope guard; do not manufacture child receipts from filenames.
        let service = SessionDeletionService(manager: SessionManager(store: center.sessionStore,
            badgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges"))))
        #expect(throws: Error.self) { try service.restore(receipt) }
        #expect(try files(root) == after)
        // The real aggregate must retain the real child capability so a
        // reopened consumer can recover without inventing a receipt.
        let recoveryURL = center.sessionStore.sessionsDirectory.appendingPathComponent("_trash")
            .appendingPathComponent(".batch-\(receipt.operationID.uuidString).receipt")
        let recoveryData = try Data(contentsOf: recoveryURL)
        let encoded = try #require(JSONSerialization.jsonObject(with: recoveryData) as? [String: Any])
        let childHandles = try #require(encoded["childReceipts"] as? [[String: Any]])
        #expect(childHandles.count == 1)
        #expect(childHandles.first?["targetID"] as? String == stale.id)
        #expect(childHandles.first?["scopeID"] as? String == "session:\(stale.id):active")
        let reopenedReceipt = try JSONDecoder().decode(DeletionReceipt.self, from: JSONEncoder().encode(receipt))
        let (reopened, _) = try fixture(existingRoot: root)
        let originalChildren = try reopened.sessionDeletionRecoveryReceipts(from: reopenedReceipt)
        let childReceipt = try #require(originalChildren.first)
        #expect(originalChildren.count == 1)
        #expect(trash["\(sessionPrefix)/_trash/\(childReceipt.operationID.uuidString).json"] == stalePayload)
        let indexData = try #require(trashJSON["\(sessionPrefix)/_trash/.trash-receipt-\(childReceipt.operationID.uuidString).json"])
        let index = try JSONDecoder().decode(SessionDeletionService.TrashEntry.self, from: indexData)
        #expect(index.receipt == childReceipt)
        #expect(index.title == stale.title)
        let beforeRestore = try files(root)
        var changedAggregate = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any])
        changedAggregate["scopeID"] = "sessions:foreign"
        let foreign = try JSONDecoder().decode(DeletionReceipt.self,
            from: JSONSerialization.data(withJSONObject: changedAggregate))
        #expect(throws: SessionDeletionError.restoreFailed("无效的会话批次恢复回执")) {
            _ = try reopened.sessionDeletionRecoveryReceipts(from: foreign)
        }
        #expect(try files(root) == beforeRestore)
        try reopened.restoreSessionDeletion(receipt: childReceipt)
        #expect(reopened.sessionStore.loadSession(id: stale.id) == stale)
        #expect(try Data(contentsOf: reopened.sessionStore.sessionsDirectory
            .appendingPathComponent("\(stale.id).json")) == stalePayload)
        for id in [exact.id, newer.id] {
            #expect(reopened.sessionStore.loadSession(id: id)?.id == id)
            #expect(try Data(contentsOf: reopened.sessionStore.sessionsDirectory
                .appendingPathComponent("\(id).json")) == before["\(sessionPrefix)/\(id).json"])
        }
        let restoredFiles = try files(root)
        #expect(throws: Error.self) { try reopened.restoreSessionDeletion(receipt: childReceipt) }
        #expect(try files(root) == restoredFiles)
    }

    @Test("empty retention batch never moves fresh sessions or creates trash")
    func emptyRetentionPreservesOwnedDomain() throws {
        let (center, root) = try fixture()
        let fresh = try session(center, title: "fresh", ageOffset: 1)
        center.autoDeleteOldSessions = true
        let before = try files(root)
        #expect(try center.previewAutoCleanupIntentIfEnabled(now: now) == nil)
        let preview = try center.previewSessionsOlderThanRetention(now: now)
        #expect(preview.affectedCount == 0)
        let receipt = try center.deleteSessionsOlderThanRetention(intent: confirmed(preview), now: now)
        #expect(receipt.operationID == preview.operationID && receipt.affectedCount == 0)
        #expect(try files(root) == before)
        #expect(center.sessionStore.loadSession(id: fresh.id) == fresh)
    }

    @Test("real single-session Settings receipt restores exact trash bytes in its original owned domain")
    func actualSingleSessionReceiptRestoresBytes() throws {
        let (center, root) = try fixture()
        let target = try session(center, title: "recoverable", ageOffset: -1)
        let path = center.sessionStore.sessionsDirectory.appendingPathComponent("\(target.id).json")
        let original = try Data(contentsOf: path)
        let preview = try center.previewSessionDeletion(id: target.id)
        let receipt = try center.deleteSession(id: target.id, intent: confirmed(preview))
        #expect(receipt.targetID == target.id && receipt.scopeID == "session:\(target.id):active")
        #expect(center.sessionStore.loadSession(id: target.id) == nil)
        try center.restoreSessionDeletion(receipt: receipt)
        #expect(try Data(contentsOf: path) == original)
        #expect(center.sessionStore.loadSession(id: target.id) == target)
        let after = try files(root)
        #expect(throws: Error.self) { try center.restoreSessionDeletion(receipt: receipt) }
        #expect(try files(root) == after)
    }
}
