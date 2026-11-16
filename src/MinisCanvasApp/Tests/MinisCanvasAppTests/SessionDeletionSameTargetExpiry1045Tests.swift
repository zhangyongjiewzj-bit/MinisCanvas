import Foundation
import MinisCore
import Testing
@testable import MinisCanvasApp

@Suite("D-SESSION-17 real Manager expiry then same-target fresh preview 1045", .serialized)
@MainActor
struct SessionDeletionSameTargetExpiry1045Tests {
    @Test("original 300-second confirmation expires naturally; repeated old requests have no effect and a fresh same-target preview moves exactly one file")
    func naturalManagerExpiryRequiresFreshSameTargetPreview() async throws {
        let resolved = try FormalTestIsolationPaths.resolveCurrentProcess()
        let paths = try #require(resolved)
        let root = paths.rootDirectory.appendingPathComponent("session17-expiry1045-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // Retain this lane's synthetic files and all metadata for the real expiry proof.
        let store = SessionStore(directory: root.appendingPathComponent("sessions"))
        let chat = ChatStore()
        try #require(chat.attachPersistence(store))
        let manager = try #require(chat.sessionManager)
        #expect(manager.store === store)
        let target = try #require(chat.activeSessionID)
        chat.appendUser("owned expiry target1045")
        let foreign = chat.applyNewSession(title: "owned foreign1045")
        chat.appendUser("owned unchanged foreign1045")
        try #require(target != foreign)
        try #require(chat.sessions.count == 2)
        let targetFile = store.sessionsDirectory.appendingPathComponent(target.uuidString + ".json")
        let foreignFile = store.sessionsDirectory.appendingPathComponent(foreign.uuidString + ".json")
        let targetBefore = try Data(contentsOf: targetFile)
        let foreignBefore = try Data(contentsOf: foreignFile)
        let activeBefore = chat.sessions.map(\.id)
        let archivedBefore = chat.archivedSessions.map(\.id)
        let activeIDBefore = chat.activeSessionID
        let monotonicStart = ContinuousClock.now
        let started = Date()
        let preview = try chat.previewCurrentDeletion(id: target)
        let produced = Date()
        #expect(!preview.archived)
        #expect(preview.intent.targetID == target.uuidString)
        #expect(preview.intent.scopeID == "session:\(target.uuidString):active")
        #expect(preview.intent.reversible && preview.intent.affectedCount == 1)
        let expires = try #require(preview.intent.expiresAt)
        // The actual canonical Manager producer owns the original 300s TTL.
        // Neither the envelope nor a production clock/TTL is replaced here.
        #expect(expires.timeIntervalSince(started) >= 300)
        #expect(expires.timeIntervalSince(produced) <= 300)
        let old = preview.intent.withFirstConfirmation("已核对这份预览")
            .withSecondConfirmation("移入回收站")
        #expect(old.operationID == preview.intent.operationID)
        #expect(old.expiresAt == expires)
        #expect(old.revision == preview.intent.revision)
        #expect(old.fingerprint == preview.intent.fingerprint)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let oldPayload = try encoder.encode(old)
        try oldPayload.write(to: root.appendingPathComponent("old-confirmed-intent.json"), options: .atomic)
        let trash = store.sessionsDirectory.appendingPathComponent("_trash", isDirectory: true)
        let oldTrash = trash.appendingPathComponent(old.operationID.uuidString + ".json")
        #expect(!FileManager.default.fileExists(atPath: trash.path))
        print("SESSION1045_WAIT operation=\(old.operationID) target=\(old.targetID) revision=\(old.revision) expiresAt=\(expires.timeIntervalSince1970) originalTTL=300")
        while Date() <= expires {
            try await Task.sleep(for: .seconds(1))
        }
        let expiredAt = Date()
        #expect(expiredAt > expires)
        // ContinuousClock can quantize a nominal 300-second sleep a few hundred microseconds short; expiry itself is proven above.
        #expect(ContinuousClock.now - monotonicStart >= .seconds(299))
        #expect(try encoder.encode(old) == oldPayload)
        for attempt in 1...2 {
            #expect(throws: DeletionGateError.expired) {
                try chat.deleteSession(id: target, intent: old)
            }
            #expect(try Data(contentsOf: targetFile) == targetBefore)
            #expect(try Data(contentsOf: foreignFile) == foreignBefore)
            #expect(!FileManager.default.fileExists(atPath: oldTrash.path))
            #expect(!FileManager.default.fileExists(atPath: trash.path))
            #expect(chat.sessions.map(\.id) == activeBefore)
            #expect(chat.archivedSessions.map(\.id) == archivedBefore)
            #expect(chat.activeSessionID == activeIDBefore)
            print("SESSION1045_OLD attempt=\(attempt) expired=1 effect=0 bytesUnchanged=1 operation=\(old.operationID)")
        }
        let freshPreview = try chat.previewCurrentDeletion(id: target)
        let fresh = freshPreview.intent.withFirstConfirmation("已核对这份预览")
            .withSecondConfirmation("移入回收站")
        #expect(!freshPreview.archived)
        #expect(fresh.operationID != old.operationID)
        #expect(fresh.targetID == old.targetID)
        #expect(fresh.scopeID == old.scopeID)
        #expect(fresh.revision == old.revision)
        #expect(fresh.fingerprint == old.fingerprint)
        #expect(fresh.expiresAt != old.expiresAt)
        #expect(try #require(fresh.expiresAt) > Date())
        #expect(fresh.firstConfirmation == old.firstConfirmation)
        #expect(fresh.secondConfirmation == old.secondConfirmation)
        let freshPayload = try encoder.encode(fresh)
        try freshPayload.write(to: root.appendingPathComponent("fresh-confirmed-intent.json"), options: .atomic)
        #expect(throws: DeletionGateError.invalidIntent) {
            try chat.deleteSession(id: foreign, intent: fresh)
        }
        try DeletionGate.checkLifecycle(fresh)
        #expect(try Data(contentsOf: targetFile) == targetBefore)
        #expect(try Data(contentsOf: foreignFile) == foreignBefore)
        #expect(chat.sessions.map(\.id) == activeBefore)
        #expect(!FileManager.default.fileExists(atPath: trash.path))
        let receipt = try chat.deleteSession(id: target, intent: fresh)
        #expect(receipt.operationID == fresh.operationID)
        #expect(receipt.targetID == target.uuidString)
        #expect(receipt.scopeID == fresh.scopeID)
        #expect(receipt.outcome == "deleted" && receipt.affectedCount == 1)
        let freshTrash = trash.appendingPathComponent(fresh.operationID.uuidString + ".json")
        #expect(!FileManager.default.fileExists(atPath: targetFile.path))
        #expect(try Data(contentsOf: freshTrash) == targetBefore)
        #expect(try Data(contentsOf: foreignFile) == foreignBefore)
        #expect(!FileManager.default.fileExists(atPath: oldTrash.path))
        // a595b5a / I-20261025T0841: native trash contains payload plus its receipt.
        let freshReceiptFile = trash.appendingPathComponent(".trash-receipt-" + fresh.operationID.uuidString + ".json")
        let expectedTrashNames: Set<String> = [freshTrash.lastPathComponent, freshReceiptFile.lastPathComponent]
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: trash.path)) == expectedTrashNames)
        let receiptBytes = try Data(contentsOf: freshReceiptFile)
        let persistedEntry = try JSONDecoder().decode(SessionDeletionService.TrashEntry.self, from: receiptBytes)
        #expect(persistedEntry.receipt.operationID == fresh.operationID)
        #expect(persistedEntry.receipt.targetID == target.uuidString)
        #expect(persistedEntry.receipt.scopeID == fresh.scopeID)
        #expect(persistedEntry.receipt.outcome == "deleted" && persistedEntry.receipt.affectedCount == 1)
        #expect(persistedEntry.payloadDigest == DeletionGate.fingerprint(targetBefore))
        let entries = try SessionDeletionService(manager: manager).trashEntries()
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.receipt.operationID == fresh.operationID)
        #expect(entry.receipt.targetID == target.uuidString)
        #expect(entry.receipt.scopeID == fresh.scopeID)
        #expect(entry.payloadDigest == persistedEntry.payloadDigest)
        #expect(chat.sessions.map(\.id) == activeBefore.filter { $0 != target })
        #expect(chat.archivedSessions.map(\.id) == archivedBefore)
        for _ in 1...2 {
            #expect(throws: DeletionGateError.alreadyConsumed) {
                try chat.deleteSession(id: target, intent: fresh)
            }
            #expect(try Data(contentsOf: freshTrash) == targetBefore)
            #expect(try Data(contentsOf: foreignFile) == foreignBefore)
            #expect(Set(try FileManager.default.contentsOfDirectory(atPath: trash.path)) == expectedTrashNames)
            #expect(try Data(contentsOf: freshReceiptFile) == receiptBytes)
        }
        let reopened = SessionStore(directory: store.directory)
        #expect(reopened.loadSession(id: target.uuidString) == nil)
        #expect(reopened.loadSession(id: foreign.uuidString) != nil)
        #expect(try encoder.encode(old) == oldPayload)
        #expect(try encoder.encode(fresh) == freshPayload)
        try encoder.encode(receipt).write(to: root.appendingPathComponent("fresh-receipt.json"), options: .atomic)
        let summary: [String: Any] = ["target": target.uuidString, "foreign": foreign.uuidString,
            "oldOperationID": old.operationID.uuidString, "freshOperationID": fresh.operationID.uuidString,
            "oldRevision": old.revision, "freshRevision": fresh.revision,
            "oldPayloadSHA256": DeletionGate.fingerprint(oldPayload),
            "freshPayloadSHA256": DeletionGate.fingerprint(freshPayload),
            "targetBeforeSHA256": DeletionGate.fingerprint(targetBefore),
            "trashAfterSHA256": DeletionGate.fingerprint(try Data(contentsOf: freshTrash)),
            "foreignBeforeSHA256": DeletionGate.fingerprint(foreignBefore),
            "foreignAfterSHA256": DeletionGate.fingerprint(try Data(contentsOf: foreignFile)),
            "expiresAt": expires.timeIntervalSince1970, "attemptedExpiredAt": expiredAt.timeIntervalSince1970,
            "originalTTL": 300, "oldAttempts": 2, "oldEffects": 0, "foreignEffects": 0,
            "freshEffects": 1, "consumedRetries": 2, "newStoreReopen": true, "OSRestart": false]
        try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys, .prettyPrinted])
            .write(to: root.appendingPathComponent("actual-summary.json"), options: .atomic)
        print("SESSION1045_FINAL oldRepeatedEffect=0 foreignEffect=0 freshEffect=1 consumedRetryEffect=0 sameTarget=1 bytesExact=1 defaultTTL=300 root=\(root.path)")
    }
}
