import Foundation
import XCTest
import MinisCore
@testable import MinisCanvasApp

private struct Storage302NoNetworkTransport: SettingsProviderReadinessTransport {
    func send(_ request: ProviderReadinessTransportRequest) async throws -> ProviderReadinessTransportResponse {
        throw URLError(.notConnectedToInternet)
    }
}

/// Actual SettingsCenter consumers, with entirely synthetic store roots,
/// an in-memory Keychain and an isolated defaults suite. No App/UI launch.
@MainActor
final class StorageSafetyConsumer302Tests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_600_000_000)

    private func makeCenter() throws -> (SettingsCenter, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Storage302-\(UUID().uuidString)", isDirectory: true)
        for name in ["settings", "env", "memory", "memory-files", "sessions",
                     "logs", "mcp", "settings/skills", "readiness", "badges"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        return (SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("env"), keychain: keychain),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            memoryFileStore: MemoryFileStore(directory: root.appendingPathComponent("memory-files")),
            sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
            sessionBadgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges")),
            logManager: LogManager(directory: root.appendingPathComponent("logs"), ringCapacity: 20),
            mcpManager: MCPServerManager(
                fileURL: root.appendingPathComponent("mcp/mcps.json"), keychain: keychain
            ),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("settings/skills")),
            usageStore: UsageStore(domain: .suite(root.lastPathComponent)),
            providerReadinessTransport: Storage302NoNetworkTransport(),
            providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        ), root)
    }

    /// Includes file names as well as bytes, so a rejected operation cannot
    /// quietly create a trash entry, rewrite a transcript, or change facts.
    private func files(_ root: URL) throws -> [String: Data] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey]
        ))
        var result: [String: Data] = [:]
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[String(url.path.dropFirst(root.path.count + 1))] = try Data(contentsOf: url)
            }
        }
        return result
    }

    private func session(_ center: SettingsCenter, title: String, updatedAt: Date) throws -> ChatSession {
        var value = try center.sessionStore.createSession(title: title)
        value.updatedAt = updatedAt
        try center.sessionStore.updateSession(value)
        return value
    }

    private func confirmed(_ intent: OperationIntent, second: String = "永久删除") -> OperationIntent {
        intent.withFirstConfirmation("已核对这份合成预览").withSecondConfirmation(second)
    }

    func testInvalidPersistedWindowsNeverProduceRetentionTargetsOrWrites() throws {
        for days in [0, -1, Int.min, Int.max] {
            let (center, root) = try makeCenter()
            _ = try session(center, title: "old", updatedAt: now.addingTimeInterval(-90 * 86_400))
            center.sessionRetentionDays = days
            center.autoDeleteOldSessions = true
            XCTAssertEqual(
                SettingsStore(directory: root.appendingPathComponent("settings"))
                    .settings.storage.sessionRetentionDays, days
            )
            let before = try files(root)
            let expected: SessionManagerError = days < 1
                ? .invalidRetention(days) : .unresolvableRetentionWindow(days: days)
            XCTAssertThrowsError(try center.previewSessionsOlderThanRetention(now: now)) {
                XCTAssertEqual($0 as? SessionManagerError, expected)
            }
            XCTAssertThrowsError(try center.previewAutoCleanupIntentIfEnabled(now: now)) {
                XCTAssertEqual($0 as? SessionManagerError, expected)
            }
            XCTAssertEqual(center.pendingAutoCleanupCount, 0)
            XCTAssertEqual(try files(root), before)
            XCTAssertEqual(center.sessionStore.listSessions().count, 1)

            // The explicit off switch still means no automatic suggestion.
            center.autoDeleteOldSessions = false
            XCTAssertNil(try center.previewAutoCleanupIntentIfEnabled(now: now))
            // "All sessions" is an independent, explicitly confirmed action.
            XCTAssertEqual(try center.previewAllSessions(now: now).affectedCount, 1)
        }
    }

    func testInvalidWindowAfterValidPreviewRefusesExecutionWithoutWrites() throws {
        for days in [-1, Int.max] {
            let (center, root) = try makeCenter()
            let old = try session(center, title: "old", updatedAt: now.addingTimeInterval(-90 * 86_400))
            center.sessionRetentionDays = 30
            let preview = try center.previewSessionsOlderThanRetention(now: now)
            XCTAssertEqual(preview.affectedCount, 1)
            center.sessionRetentionDays = days
            let before = try files(root)
            XCTAssertThrowsError(try center.deleteSessionsOlderThanRetention(
                intent: confirmed(preview), now: now
            )) {
                let expected: SessionManagerError = days < 1
                    ? .invalidRetention(days) : .unresolvableRetentionWindow(days: days)
                XCTAssertEqual($0 as? SessionManagerError, expected)
            }
            XCTAssertEqual(try files(root), before)
            XCTAssertNotNil(center.sessionStore.loadSession(id: old.id))
        }
    }

    func testLegalWindowsUseSuppliedNowAndProtectExactCutoffFreshAndArchived() throws {
        // Keep historical legal large values: this is not a new 365-day cap.
        for days in [1, 30, 365, 36_500] {
            let (center, root) = try makeCenter()
            let cutoff = now.addingTimeInterval(-TimeInterval(days) * 86_400)
            let stale = try session(center, title: "stale", updatedAt: cutoff.addingTimeInterval(-1))
            let exact = try session(center, title: "exact", updatedAt: cutoff)
            let fresh = try session(center, title: "fresh", updatedAt: cutoff.addingTimeInterval(1))
            let archived = try session(center, title: "archived", updatedAt: cutoff.addingTimeInterval(-1))
            let manager = SessionManager(
                store: center.sessionStore,
                badgeStore: SessionBadgeStore(directory: root.appendingPathComponent("badges"))
            )
            try manager.archive(sessionID: archived.id)
            center.sessionRetentionDays = days
            center.autoDeleteOldSessions = true
            let before = try files(root)
            let preview = try XCTUnwrap(center.previewAutoCleanupIntentIfEnabled(now: now))
            XCTAssertEqual(preview.affectedCount, 1)
            XCTAssertTrue(preview.reversible)
            XCTAssertEqual(try files(root), before)
            let receipt = try center.deleteSessionsOlderThanRetention(intent: confirmed(preview), now: now)
            XCTAssertEqual(receipt.affectedCount, 1)
            XCTAssertNil(center.sessionStore.loadSession(id: stale.id))
            XCTAssertNotNil(center.sessionStore.loadSession(id: exact.id))
            XCTAssertNotNil(center.sessionStore.loadSession(id: fresh.id))
            XCTAssertNotNil(manager.loadSessionIncludingArchived(id: archived.id))
            XCTAssertEqual(center.sessions.count, 2)
        }
    }

    func testAutoCleanupUsesSuppliedNowEvenWhenWallClockWouldSelectEverything() throws {
        let (center, root) = try makeCenter()
        _ = try session(center, title: "fresh at supplied now", updatedAt: now)
        center.sessionRetentionDays = 30
        center.autoDeleteOldSessions = true
        let before = try files(root)
        XCTAssertNil(try center.previewAutoCleanupIntentIfEnabled(now: now))
        XCTAssertEqual(try files(root), before)
    }

    func testMemoryClearProducerRejectsMissingOrWrongConfirmationWithoutWrites() throws {
        let (center, root) = try makeCenter()
        try center.memoryStore.addFact("synthetic fact")
        center.reloadStorage()
        let preview = try center.previewMemoryClear(now: now)
        XCTAssertFalse(preview.reversible)
        let presentation = SettingsDeletionPresentation(intent: preview)
        XCTAssertEqual(presentation.warning, "本次操作不可恢复。")
        XCTAssertEqual(presentation.secondPhrase, "永久删除")
        XCTAssertTrue(preview.impactSummary.contains("成功后无法恢复"))
        XCTAssertEqual(preview.affectedCount, 1)
        XCTAssertNil(preview.firstConfirmation)
        XCTAssertNil(preview.secondConfirmation)
        let before = try files(root)
        for (intent, expected) in [
            (preview, DeletionGateError.firstConfirmationRequired),
            (preview.withFirstConfirmation("已核对"), .secondConfirmationRequired),
            (confirmed(preview, second: "I CONFIRM MOVE TO TRASH"), .irreversibleRequiresPhrase),
            (confirmed(preview, second: "ordinary nonempty confirmation"), .irreversibleRequiresPhrase)
        ] {
            XCTAssertThrowsError(try center.clearAllMemory(intent: intent, now: now)) {
                XCTAssertEqual($0 as? DeletionGateError, expected)
            }
            XCTAssertEqual(try files(root), before)
            XCTAssertEqual(center.memoryFacts.count, 1)
            XCTAssertEqual(try center.memoryStore.facts().count, 1)
        }
    }

    func testMemoryClearCannotBeDowngradedToAReversibleIntent() throws {
        let (center, root) = try makeCenter()
        try center.memoryStore.addFact("synthetic fact")
        let preview = try center.previewMemoryClear(now: now)
        let downgraded = DeletionGate.preview(
            targetID: preview.targetID, targetType: preview.targetType,
            targetName: preview.targetName, affectedCount: preview.affectedCount,
            impactSummary: preview.impactSummary, reversible: true,
            scopeID: preview.scopeID, revision: preview.revision,
            fingerprint: preview.fingerprint, now: now
        )
        let before = try files(root)
        XCTAssertThrowsError(try center.clearAllMemory(
            intent: confirmed(downgraded, second: "ordinary nonempty confirmation"), now: now
        )) {
            XCTAssertEqual($0 as? DeletionGateError, .targetChanged)
        }
        XCTAssertEqual(try files(root), before)
    }

    func testClearAllSessionsKeepsItsActualTrashRecoveryPresentation() throws {
        let (center, root) = try makeCenter()
        _ = try center.sessionStore.createSession(title: "synthetic session")
        let before = try files(root)
        let preview = try center.previewAllSessions(now: now)
        let presentation = SettingsDeletionPresentation(intent: preview)
        XCTAssertTrue(preview.reversible)
        XCTAssertEqual(presentation.warning, "本次操作会移入回收站，可恢复。")
        XCTAssertEqual(presentation.secondPhrase, "I CONFIRM MOVE TO TRASH")
        XCTAssertEqual(try files(root), before)
    }

    func testConfirmedMemoryClearUpdatesOnlyFixtureFactsAndBothProjections() throws {
        let (center, _) = try makeCenter()
        let (other, otherRoot) = try makeCenter()
        try center.memoryStore.addFact("synthetic first")
        try center.memoryStore.addFact("synthetic second")
        try other.memoryStore.addFact("other fixture retained")
        let session = try center.sessionStore.createSession(title: "unrelated session retained")
        center.reloadStorage()
        let otherBefore = try files(otherRoot)
        let sessionBefore = center.sessionStore.loadSession(id: session.id)
        let preview = try center.previewMemoryClear(now: now)
        let receipt = try center.clearAllMemory(intent: confirmed(preview), now: now)
        XCTAssertEqual(receipt.targetID, "memory.facts")
        XCTAssertEqual(receipt.scopeID, "memory:facts")
        XCTAssertEqual(receipt.outcome, "deleted")
        XCTAssertEqual(receipt.affectedCount, 2)
        XCTAssertTrue(try center.memoryStore.facts().isEmpty)
        XCTAssertTrue(center.memoryFacts.isEmpty)
        XCTAssertEqual(center.memoryFactTotalCount, 0)
        XCTAssertTrue(try MemoryStore(directory: center.memoryStore.directory).facts().isEmpty)
        XCTAssertEqual(center.sessionStore.loadSession(id: session.id), sessionBefore)
        XCTAssertEqual(try files(otherRoot), otherBefore)
    }

    private func batchPreview520(_ all: Bool, center: SettingsCenter, at date: Date) throws -> OperationIntent {
        if all { return try center.previewAllSessions(now: date) }
        return try center.previewSessionsOlderThanRetention(now: date)
    }

    private func executeBatch520(
        _ all: Bool, center: SettingsCenter, intent: OperationIntent, at date: Date
    ) throws -> DeletionReceipt {
        if all { return try center.deleteAllSessions(intent: intent, now: date) }
        return try center.deleteSessionsOlderThanRetention(intent: intent, now: date)
    }

    func testBatchPreviewRejectsChangedPayloadWithSameDisplayMetadata520() throws {
        for all in [false, true] {
            for mutation in ["text", "attachment", "state", "revision"] {
                let (center, root) = try makeCenter()
                let (other, otherRoot) = try makeCenter()
                try center.memoryStore.addFact("memory outside session batch")
                _ = try other.sessionStore.createSession(title: "other store session")
                try other.memoryStore.addFact("other store memory")
                center.sessionRetentionDays = 30
                var original = try session(
                    center, title: "same displayed title", updatedAt: now.addingTimeInterval(-90 * 86_400)
                )
                original.messages = [LLMMessage(
                    role: .user, content: "original synthetic text",
                    images: [.init(mimeType: "image/png", data: Data([1, 2, 3]))]
                )]
                try center.sessionStore.updateSession(original)
                let preview = try batchPreview520(all, center: center, at: now)
                XCTAssertEqual(preview.affectedCount, 1)
                var replacement = original
                switch mutation {
                case "text":
                    replacement.messages[0] = LLMMessage(
                        role: .user, content: "replacement synthetic text",
                        images: original.messages[0].images
                    )
                case "attachment":
                    replacement.messages[0].images = [.init(mimeType: "image/png", data: Data([4, 5, 6]))]
                case "state": replacement.pinned = true
                default: replacement.transcriptRevision += 1
                }
                try center.sessionStore.updateSession(replacement)
                let loaded = try XCTUnwrap(center.sessionStore.loadSession(id: original.id))
                XCTAssertEqual(loaded, replacement)
                XCTAssertNotEqual(loaded, original)
                XCTAssertEqual(loaded.id, original.id)
                XCTAssertEqual(loaded.updatedAt, original.updatedAt)
                XCTAssertEqual(loaded.title, original.title)
                let before = try files(root)
                let otherBefore = try files(otherRoot)
                XCTAssertThrowsError(try executeBatch520(
                    all, center: center,
                    intent: confirmed(preview, second: SettingsDeletionPresentation(intent: preview).secondPhrase),
                    at: now
                )) { XCTAssertEqual($0 as? DeletionGateError, .targetChanged) }
                XCTAssertEqual(try files(root), before, mutation)
                XCTAssertEqual(try files(otherRoot), otherBefore, mutation)
                XCTAssertEqual(center.sessionStore.loadSession(id: original.id), replacement)
                XCTAssertEqual(try center.memoryStore.facts().count, 1)
            }
        }
    }

    func testUnconfirmedExpiredAndCancelledBatchPreviewsPreserveOwnedDomains520() throws {
        for all in [false, true] {
            for rejection in ["unconfirmed", "first-only", "expired", "cancelled"] {
                let (center, root) = try makeCenter()
                let (other, otherRoot) = try makeCenter()
                center.sessionRetentionDays = 30
                _ = try session(center, title: "stale", updatedAt: now.addingTimeInterval(-90 * 86_400))
                _ = try session(center, title: "fresh", updatedAt: now)
                try center.memoryStore.addFact("unrelated memory")
                try other.memoryStore.addFact("other fixture memory")
                let preview = try batchPreview520(all, center: center, at: now)
                var intent = confirmed(preview, second: SettingsDeletionPresentation(intent: preview).secondPhrase)
                var executeAt = now
                let expected: DeletionGateError
                switch rejection {
                case "unconfirmed": intent = preview; expected = .firstConfirmationRequired
                case "first-only": intent = preview.withFirstConfirmation("reviewed"); expected = .secondConfirmationRequired
                case "expired": executeAt = try XCTUnwrap(preview.expiresAt); expected = .expired
                default: try DeletionGate.cancel(preview); expected = .cancelled
                }
                let before = try files(root)
                let otherBefore = try files(otherRoot)
                XCTAssertThrowsError(try executeBatch520(all, center: center, intent: intent, at: executeAt)) {
                    XCTAssertEqual($0 as? DeletionGateError, expected)
                }
                XCTAssertEqual(try files(root), before, rejection)
                XCTAssertEqual(try files(otherRoot), otherBefore, rejection)
                XCTAssertEqual(center.sessionStore.listSessions().count, 2)
                XCTAssertEqual(try center.memoryStore.facts().count, 1)
            }
        }
    }

    func testConfirmedExactPreviewOnlyMovesItsSelectedSessions520() throws {
        for all in [false, true] {
            let (center, root) = try makeCenter()
            let (other, otherRoot) = try makeCenter()
            center.sessionRetentionDays = 30
            let cutoff = now.addingTimeInterval(-30 * 86_400)
            let stale = try session(center, title: "stale", updatedAt: cutoff.addingTimeInterval(-1))
            let exact = try session(center, title: "exact cutoff", updatedAt: cutoff)
            let fresh = try session(center, title: "fresh", updatedAt: cutoff.addingTimeInterval(1))
            try center.memoryStore.addFact("unrelated memory survives")
            _ = try other.sessionStore.createSession(title: "other fixture survives")
            try other.memoryStore.addFact("other fixture memory survives")
            let preview = try batchPreview520(all, center: center, at: now)
            let freshPreview = try batchPreview520(all, center: center, at: now)
            XCTAssertEqual(preview.fingerprint, freshPreview.fingerprint)
            XCTAssertEqual(preview.affectedCount, all ? 3 : 1)
            let memoryBefore = try files(root.appendingPathComponent("memory"))
            let otherBefore = try files(otherRoot)
            let receipt = try executeBatch520(
                all, center: center,
                intent: confirmed(preview, second: SettingsDeletionPresentation(intent: preview).secondPhrase),
                at: now
            )
            XCTAssertEqual(receipt.operationID, preview.operationID)
            XCTAssertEqual(receipt.targetID, preview.targetID)
            XCTAssertEqual(receipt.scopeID, preview.scopeID)
            XCTAssertEqual(receipt.affectedCount, preview.affectedCount)
            XCTAssertNil(center.sessionStore.loadSession(id: stale.id))
            XCTAssertEqual(center.sessionStore.loadSession(id: exact.id), all ? nil : exact)
            XCTAssertEqual(center.sessionStore.loadSession(id: fresh.id), all ? nil : fresh)
            XCTAssertEqual(center.sessions.count, all ? 0 : 2)
            let trash = center.sessionStore.sessionsDirectory.appendingPathComponent("_trash")
            let trashContents = try FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)
            // Native deletion keeps one UUID payload and one receipt sidecar
            // per moved session; both are JSON, but only the payload is a session.
            let payloads = trashContents.filter {
                $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil
            }
            XCTAssertEqual(payloads.count, preview.affectedCount)
            let children = try center.sessionDeletionRecoveryReceipts(from: receipt)
            XCTAssertEqual(Set(children.map(\.targetID)), Set(all ? [stale.id, exact.id, fresh.id] : [stale.id]))
            let expectedJSONNames = Set(children.flatMap { child in
                let id = child.operationID.uuidString
                return [id + ".json", ".trash-receipt-" + id + ".json"]
            })
            XCTAssertEqual(Set(trashContents.filter { $0.pathExtension == "json" }.map(\.lastPathComponent)), expectedJSONNames)
            XCTAssertEqual(try files(root.appendingPathComponent("memory")), memoryBefore)
            XCTAssertEqual(try files(otherRoot), otherBefore)
            // The exact successful consumer must persist its badge retirement
            // under this fixture, never SessionBadgeStore.shared's default root.
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("badges/badges.json").path))
        }
    }

    func testMemoryClearExpiredOrChangedSameCountPreviewCannotWrite520() throws {
        for rejection in ["expired", "same-count-target-changed"] {
            let (center, root) = try makeCenter()
            let (other, otherRoot) = try makeCenter()
            _ = try center.sessionStore.createSession(title: "session outside memory clear")
            try center.memoryStore.addFact("original fixture fact")
            try other.memoryStore.addFact("other fixture fact")
            let preview = try center.previewMemoryClear(now: now)
            let expected: DeletionGateError
            let executeAt: Date
            if rejection == "expired" {
                expected = .expired
                executeAt = try XCTUnwrap(preview.expiresAt)
            } else {
                let fact = try XCTUnwrap(try center.memoryStore.facts().first)
                _ = try center.memoryStore.tombstoneFact(id: fact.id, reason: "synthetic fixture state change")
                XCTAssertEqual(try center.memoryStore.facts().count, preview.affectedCount)
                expected = .targetChanged
                executeAt = now
            }
            let before = try files(root)
            let otherBefore = try files(otherRoot)
            XCTAssertThrowsError(try center.clearAllMemory(intent: confirmed(preview), now: executeAt)) {
                XCTAssertEqual($0 as? DeletionGateError, expected)
            }
            XCTAssertEqual(try files(root), before, rejection)
            XCTAssertEqual(try files(otherRoot), otherBefore, rejection)
            XCTAssertEqual(center.sessionStore.listSessions().count, 1)
            XCTAssertEqual(try center.memoryStore.facts().count, 1)
        }
    }

    func testActualBackupDraftAndPreviewRejectInvalidInputsWithoutTargetWrites() throws {
        let (source, sourceRoot) = try makeCenter()
        let (target, targetRoot) = try makeCenter()
        let scope = MemoryScope(sessionID: "fixture-session", projectID: "fixture-project")
        _ = try source.sessionStore.createSession(id: "source-session", title: "source")
        try source.memoryStore.addFact("source fact", sourceSessionID: scope.sessionID, memoryScope: scope)
        _ = try target.sessionStore.createSession(id: "target-session", title: "must survive")
        try target.memoryStore.addFact("target fact")
        target.reloadStorage()
        target.syncManager.markDirty(.settings)
        let raw = try source.syncManager.exportSnapshot()
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let before = try files(targetRoot)
        let selected = Set(SyncScope.allCases)
        let validFile = sourceRoot.appendingPathComponent("valid.minissync")
        try raw.write(to: validFile)
        let validDraft = try target.readAtomicBackupDraft(from: validFile)
        // A valid control uses the identical production route and all four domains.
        let validPreview = try target.previewAtomicBackup(validDraft, selecting: selected, memoryScope: scope)
        XCTAssertEqual(validPreview.selected, selected)
        XCTAssertEqual(try files(targetRoot), before)

        for label in ["broken-json", "old-version", "future-version", "unknown-domain",
                      "missing-payload", "unsafe-session-identity", "foreign-memory-scope"] {
            var object = original
            var manifest = try XCTUnwrap(object["manifest"] as? [String: Any])
            switch label {
            case "old-version": manifest["version"] = 0
            case "future-version": manifest["version"] = SyncManifest.currentVersion + 1
            case "unknown-domain": manifest["scopes"] = ["sessions", "unknown"]
            case "missing-payload": object.removeValue(forKey: "sessions")
            case "unsafe-session-identity":
                var sessions = try XCTUnwrap(object["sessions"] as? [[String: Any]])
                sessions[0]["id"] = "../outside"
                object["sessions"] = sessions
            default: break
            }
            object["manifest"] = manifest
            let data: Data
            if label == "broken-json" {
                data = Data("{invalid-json".utf8)
            } else {
                data = try JSONSerialization.data(withJSONObject: object)
            }
            let file = sourceRoot.appendingPathComponent("\(label).minissync")
            try data.write(to: file)
            XCTAssertThrowsError(try {
                let draft = try target.readAtomicBackupDraft(from: file)
                let requestedScope = label == "foreign-memory-scope"
                    ? MemoryScope(sessionID: "other-session", projectID: "other-project") : scope
                _ = try target.previewAtomicBackup(draft, selecting: selected, memoryScope: requestedScope)
            }(), label)
            XCTAssertEqual(try files(targetRoot), before, label)
            XCTAssertEqual(target.syncManager.dirtyScopes, [.settings], label)
            XCTAssertFalse(target.atomicBackupInProgress, label)
            XCTAssertFalse(target.atomicBackupReopenRequired, label)
            XCTAssertFalse(target.atomicBackupRecoveryRequired, label)
        }
        // deviceName is display metadata, not a trust identity. This test
        // deliberately does not invent a policy that forbids cross-device restore.
    }
}
