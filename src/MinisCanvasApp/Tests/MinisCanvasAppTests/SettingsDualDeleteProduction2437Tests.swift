import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private struct Storage2437NoNetwork: SettingsProviderReadinessTransport {
    func send(_ request: ProviderReadinessTransportRequest) async throws -> ProviderReadinessTransportResponse {
        throw URLError(.notConnectedToInternet)
    }
}

/// The two Settings destructive entries must preserve each other's domain and
/// every neighbouring synthetic profile across cancellation and confirmation.
@Suite("D-STORAGE-05 Settings dual-domain deletion consumer")
@MainActor
struct SettingsDualDeleteProduction2437Tests {
    private let now = Date(timeIntervalSince1970: 1_600_000_000)

    private func center(at root: URL) -> SettingsCenter {
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        return SettingsCenter(
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
            providerReadinessTransport: Storage2437NoNetwork(),
            providerReadinessStore: ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        )
    }

    private func files(at root: URL) throws -> [String: Data] {
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [:] }
        var result: [String: Data] = [:]
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let candidate = url.resolvingSymlinksInPath().standardizedFileURL
            #expect(candidate.path.hasPrefix(canonical.path + "/"))
            result[String(candidate.path.dropFirst(canonical.path.count + 1))] = try Data(contentsOf: url)
        }
        return result
    }

    private func writeManifest(_ files: [String: Data], to url: URL) throws {
        let manifest = files.mapValues { ["size": String($0.count), "sha256": DeletionGate.fingerprint($0)] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }

    private func confirmed(_ intent: OperationIntent) -> OperationIntent {
        intent.withFirstConfirmation("已核对合成数据范围")
            .withSecondConfirmation(SettingsDeletionPresentation(intent: intent).secondPhrase)
    }

    @Test("cancel and wrong confirmation write nothing; exact confirmation changes only the selected sessions then memory")
    func twoSessionsTwoFactsAndNeighbouringProfile() throws {
        let paths = try FormalTestIsolationPaths.resolveCurrentProcess()
        let formal = try #require(paths)
        let run = formal.rootDirectory.appendingPathComponent("storage2437-\(UUID().uuidString)")
        let ownedRoot = run.appendingPathComponent("owned")
        let neighbourRoot = run.appendingPathComponent("neighbour")
        let evidence = run.appendingPathComponent("manifests")
        try FileManager.default.createDirectory(at: ownedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: neighbourRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let owned = center(at: ownedRoot)
        let neighbour = center(at: neighbourRoot)

        let sessionA = try owned.sessionStore.createSession(title: "synthetic A")
        let sessionB = try owned.sessionStore.createSession(title: "synthetic B")
        try owned.sessionStore.saveMessage(LLMMessage(role: .user, content: "owned A body"), sessionID: sessionA.id)
        try owned.sessionStore.saveMessage(LLMMessage(role: .user, content: "owned B body"), sessionID: sessionB.id)
        try owned.memoryStore.addFact("owned synthetic fact A")
        try owned.memoryStore.addFact("owned synthetic fact B")
        let neighbourSession = try neighbour.sessionStore.createSession(title: "neighbour")
        try neighbour.memoryStore.addFact("neighbour fact")
        owned.reloadStorage()
        neighbour.reloadStorage()

        let before = try files(at: ownedRoot)
        let neighbourBefore = try files(at: neighbourRoot)
        try writeManifest(before, to: evidence.appendingPathComponent("owned.before.json"))
        try writeManifest(neighbourBefore, to: evidence.appendingPathComponent("neighbour.before.json"))
        #expect(owned.sessionStore.listSessions().count == 2)
        #expect(try owned.memoryStore.facts().count == 2)

        let cancelled = try owned.previewAllSessions(now: now)
        let memoryPreview = try owned.previewMemoryClear(now: now)
        #expect(cancelled.affectedCount == 2 && cancelled.reversible)
        #expect(memoryPreview.affectedCount == 2 && !memoryPreview.reversible)
        #expect(SettingsDeletionPresentation(intent: cancelled).secondPhrase == "I CONFIRM MOVE TO TRASH")
        #expect(SettingsDeletionPresentation(intent: memoryPreview).secondPhrase == "永久删除")
        #expect(try files(at: ownedRoot) == before)
        try DeletionGate.cancel(cancelled)
        #expect(throws: DeletionGateError.cancelled) {
            try owned.deleteAllSessions(intent: confirmed(cancelled), now: now)
        }
        #expect(throws: DeletionGateError.irreversibleRequiresPhrase) {
            try owned.clearAllMemory(intent: memoryPreview
                .withFirstConfirmation("已核对合成数据范围")
                .withSecondConfirmation("WRONG PHRASE"), now: now)
        }
        #expect(try files(at: ownedRoot) == before)
        #expect(try files(at: neighbourRoot) == neighbourBefore)
        try writeManifest(try files(at: ownedRoot), to: evidence.appendingPathComponent("owned.rejected.json"))

        let sessions = try owned.previewAllSessions(now: now)
        let sessionReceipt = try owned.deleteAllSessions(intent: confirmed(sessions), now: now)
        #expect(sessionReceipt.affectedCount == 2)
        #expect(owned.sessionStore.loadSession(id: sessionA.id) == nil)
        #expect(owned.sessionStore.loadSession(id: sessionB.id) == nil)
        #expect(try owned.memoryStore.facts().count == 2)
        let afterSessions = try files(at: ownedRoot)
        #expect(afterSessions.filter { $0.key.hasPrefix("memory/") } == before.filter { $0.key.hasPrefix("memory/") })
        #expect(try files(at: neighbourRoot) == neighbourBefore)
        let trash = owned.sessionStore.sessionsDirectory.appendingPathComponent("_trash")
        let trashFiles = try FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)
        let recoveries = try owned.sessionDeletionRecoveryReceipts(from: sessionReceipt)
        #expect(recoveries.count == 2)
        #expect(Set(recoveries.map(\.targetID)) == Set([sessionA.id, sessionB.id]))
        let payloads = trashFiles.filter {
            $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil
        }
        #expect(payloads.count == 2)
        #expect(Set(payloads.map(\.lastPathComponent)) == Set(recoveries.map { $0.operationID.uuidString + ".json" }))
        let expectedJSONNames = Set(recoveries.flatMap {
            let id = $0.operationID.uuidString
            return [id + ".json", ".trash-receipt-" + id + ".json"]
        })
        #expect(Set(trashFiles.filter { $0.pathExtension == "json" }.map(\.lastPathComponent)) == expectedJSONNames)
        for recovery in recoveries {
            let originalBytes = try #require(before["sessions/sessions/\(recovery.targetID).json"])
            #expect(try Data(contentsOf: trash.appendingPathComponent(recovery.operationID.uuidString + ".json")) == originalBytes)
        }
        try writeManifest(afterSessions, to: evidence.appendingPathComponent("owned.after-sessions.json"))

        let memory = try owned.previewMemoryClear(now: now)
        let memoryReceipt = try owned.clearAllMemory(intent: confirmed(memory), now: now)
        #expect(memoryReceipt.affectedCount == 2)
        #expect(try owned.memoryStore.facts().isEmpty)
        #expect(owned.memoryFacts.isEmpty)
        let afterMemory = try files(at: ownedRoot)
        #expect(afterMemory.filter { $0.key.hasPrefix("sessions/") } == afterSessions.filter { $0.key.hasPrefix("sessions/") })
        #expect(try files(at: neighbourRoot) == neighbourBefore)
        #expect(neighbour.sessionStore.loadSession(id: neighbourSession.id) != nil)
        #expect(try neighbour.memoryStore.facts().count == 1)
        try writeManifest(afterMemory, to: evidence.appendingPathComponent("owned.after-memory.json"))
        try writeManifest(try files(at: neighbourRoot), to: evidence.appendingPathComponent("neighbour.after.json"))
    }

    @Test("confirmed clear-all preserves its success contract when a parent is newer than its durable child")
    func parentNewerThanForkedChildClearsAllThroughConfirmedBatch() throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let run = formal.rootDirectory.appendingPathComponent("storage2437-lineage-\(UUID().uuidString)")
        let ownedRoot = run.appendingPathComponent("owned")
        let neighbourRoot = run.appendingPathComponent("neighbour")
        try FileManager.default.createDirectory(at: ownedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: neighbourRoot, withIntermediateDirectories: true)
        let owned = center(at: ownedRoot)
        let neighbour = center(at: neighbourRoot)
        var parent = try owned.sessionStore.createSession(id: "synthetic-parent", title: "synthetic parent")
        var child = try owned.sessionStore.forkSession(from: parent.id, id: "synthetic-child", title: "synthetic child")
        child.updatedAt = now.addingTimeInterval(-2)
        try owned.sessionStore.updateSession(child)
        parent.updatedAt = now.addingTimeInterval(-1)
        try owned.sessionStore.updateSession(parent)
        let loadedParent = try #require(owned.sessionStore.loadSession(id: parent.id))
        let loadedChild = try #require(owned.sessionStore.loadSession(id: child.id))
        #expect(loadedChild.parentSessionID == loadedParent.id)
        #expect(loadedChild.rootSessionID == loadedParent.rootSessionID)
        #expect(loadedChild.forkedFromSessionID == loadedParent.id)
        #expect(owned.sessionStore.listSessions().map(\.id) == [parent.id, child.id])
        try owned.memoryStore.addFact("synthetic memory outside session deletion")
        _ = try neighbour.sessionStore.createSession(title: "synthetic neighbour retained")
        owned.reloadStorage()
        let before = try files(at: ownedRoot)
        let neighbourBefore = try files(at: neighbourRoot)
        let directory = owned.sessionStore.sessionsDirectory
        let sessionBytes = try Dictionary(uniqueKeysWithValues: [parent, child].map {
            ($0.id, try Data(contentsOf: directory.appendingPathComponent("\($0.id).json")))
        })
        let preview = try owned.previewAllSessions(now: now)
        #expect(preview.affectedCount == 2 && preview.reversible)
        #expect(SettingsDeletionPresentation(intent: preview).secondPhrase == "I CONFIRM MOVE TO TRASH")
        #expect(try files(at: ownedRoot) == before)
        let receipt: DeletionReceipt
        do {
            receipt = try owned.deleteAllSessions(intent: confirmed(preview), now: now)
        } catch {
            if case let SessionManagerError.sessionNotFound(id) = error {
                let parentExists = FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(parent.id).json").path)
                let childExists = FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(child.id).json").path)
                let restored = [parent.id, child.id].allSatisfy { id in
                    (try? Data(contentsOf: directory.appendingPathComponent("\(id).json"))) == sessionBytes[id]
                }
                print("STORAGE05_LINEAGE_TYPED_FAILURE id=\(id) parentExists=\(parentExists) childExists=\(childExists) restoredOriginalBytes=\(restored)")
            }
            throw error
        }
        #expect(receipt.affectedCount == 2)
        #expect(owned.sessionStore.listSessions().isEmpty)
        let recoveries = try owned.sessionDeletionRecoveryReceipts(from: receipt)
        #expect(Set(recoveries.map(\.targetID)) == Set([parent.id, child.id]))
        let trash = directory.appendingPathComponent("_trash")
        for recovery in recoveries {
            #expect(try Data(contentsOf: trash.appendingPathComponent("\(recovery.operationID.uuidString).json")) == sessionBytes[recovery.targetID])
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(recovery.targetID).json").path))
        }
        let after = try files(at: ownedRoot)
        #expect(after.filter { $0.key.hasPrefix("memory/") } == before.filter { $0.key.hasPrefix("memory/") })
        #expect(try owned.memoryStore.facts().count == 1)
        #expect(try files(at: neighbourRoot) == neighbourBefore)
    }

    @Test("confirmed batches delete deep descendants first and restore original bytes parent-first", arguments: [3, 8])
    func deepLineageBatchKeepsStableUnrelatedOrderAndReversibleReceipts(depth: Int) throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let run = formal.rootDirectory.appendingPathComponent("storage2437-deep-\(UUID().uuidString)")
        let ownedRoot = run.appendingPathComponent("owned")
        let neighbourRoot = run.appendingPathComponent("neighbour")
        try FileManager.default.createDirectory(at: ownedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: neighbourRoot, withIntermediateDirectories: true)
        let owned = center(at: ownedRoot)
        let neighbour = center(at: neighbourRoot)
        var chain = [try owned.sessionStore.createSession(id: "synthetic-deep-0", title: "synthetic deep root")]
        for index in 1..<depth {
            chain.append(try owned.sessionStore.forkSession(
                from: chain[index - 1].id, id: "synthetic-deep-\(index)", title: "synthetic deep child"))
        }
        for (index, original) in chain.enumerated() {
            var current = try #require(owned.sessionStore.loadSession(id: original.id))
            current.updatedAt = now.addingTimeInterval(-Double(index))
            try owned.sessionStore.updateSession(current)
        }
        var unrelated = try owned.sessionStore.createSession(id: "synthetic-unrelated", title: "synthetic unrelated")
        unrelated.updatedAt = now.addingTimeInterval(1)
        try owned.sessionStore.updateSession(unrelated)
        let originalIDs = [unrelated.id] + chain.map(\.id)
        #expect(owned.sessionStore.listSessions().map(\.id) == originalIDs)
        try owned.memoryStore.addFact("synthetic deep batch memory retained")
        let memoryBefore = try owned.memoryStore.facts()
        _ = try neighbour.sessionStore.createSession(title: "synthetic deep neighbour retained")
        let neighbourBefore = try files(at: neighbourRoot)
        let directory = owned.sessionStore.sessionsDirectory
        let sessionBytes = try Dictionary(uniqueKeysWithValues: originalIDs.map {
            ($0, try Data(contentsOf: directory.appendingPathComponent("\($0).json")))
        })
        let before = try files(at: ownedRoot)
        let preview = try owned.previewAllSessions(now: now)
        #expect(preview.affectedCount == depth + 1)
        #expect(preview.reversible)
        #expect(SettingsDeletionPresentation(intent: preview).secondPhrase == "I CONFIRM MOVE TO TRASH")
        #expect(try files(at: ownedRoot) == before)
        let receipt = try owned.deleteAllSessions(intent: confirmed(preview), now: now)
        #expect(receipt.affectedCount == depth + 1)
        #expect(owned.sessionStore.listSessions().isEmpty)
        let recoveries = try owned.sessionDeletionRecoveryReceipts(from: receipt)
        #expect(recoveries.map(\.targetID) == [unrelated.id] + chain.reversed().map(\.id))
        let trash = directory.appendingPathComponent("_trash")
        for recovery in recoveries {
            #expect(try Data(contentsOf: trash.appendingPathComponent("\(recovery.operationID.uuidString).json")) == sessionBytes[recovery.targetID])
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(recovery.targetID).json").path))
        }
        #expect(try owned.memoryStore.facts() == memoryBefore)
        #expect(try files(at: neighbourRoot) == neighbourBefore)
        // Reverse of child-first deletion is the canonical parent-first restore.
        for recovery in recoveries.reversed() {
            try owned.restoreSessionDeletion(receipt: recovery)
        }
        #expect(Set(owned.sessionStore.listSessions().map(\.id)) == Set(originalIDs))
        for id in originalIDs {
            #expect(try Data(contentsOf: directory.appendingPathComponent("\(id).json")) == sessionBytes[id])
            #expect(owned.sessionStore.loadSession(id: id) != nil)
        }
        #expect(try owned.memoryStore.facts() == memoryBefore)
        #expect(try files(at: neighbourRoot) == neighbourBefore)
    }

    @Test("retention refuses an old parent without deleting its unselected fresh child", arguments: [false, true])
    func retentionBatchRejectsParentOfUnselectedFreshChildWithoutMutation(archivedChild: Bool) throws {
        let formal = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let run = formal.rootDirectory.appendingPathComponent("storage2437-retention-lineage-\(UUID().uuidString)")
        let ownedRoot = run.appendingPathComponent("owned")
        let neighbourRoot = run.appendingPathComponent("neighbour")
        try FileManager.default.createDirectory(at: ownedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: neighbourRoot, withIntermediateDirectories: true)
        let owned = center(at: ownedRoot)
        let neighbour = center(at: neighbourRoot)
        owned.sessionRetentionDays = 30
        var parent = try owned.sessionStore.createSession(id: "synthetic-old-parent", title: "synthetic old parent")
        var child = try owned.sessionStore.forkSession(
            from: parent.id, id: "synthetic-fresh-child", title: "synthetic fresh child")
        child.updatedAt = now.addingTimeInterval(-86_400)
        try owned.sessionStore.updateSession(child)
        parent.updatedAt = now.addingTimeInterval(-31 * 86_400)
        try owned.sessionStore.updateSession(parent)
        #expect(owned.sessionStore.loadSession(id: child.id)?.parentSessionID == parent.id)
        let manager = SessionManager(store: owned.sessionStore,
            badgeStore: SessionBadgeStore(directory: ownedRoot.appendingPathComponent("badges")))
        if archivedChild {
            try manager.archive(sessionID: child.id)
        }
        #expect(Set(owned.sessionStore.listSessions().map(\.id)) == Set(archivedChild ? [parent.id] : [parent.id, child.id]))
        #expect(manager.archivedSessions().map(\.id) == (archivedChild ? [child.id] : []))
        #expect(manager.loadSessionIncludingArchived(id: child.id)?.parentSessionID == parent.id)
        try owned.memoryStore.addFact("synthetic retention memory retained")
        _ = try neighbour.sessionStore.createSession(title: "synthetic retention neighbour retained")
        owned.reloadStorage()
        let before = try files(at: ownedRoot)
        let neighbourBefore = try files(at: neighbourRoot)
        let memoryBefore = try owned.memoryStore.facts()
        let preview = try owned.previewSessionsOlderThanRetention(now: now)
        #expect(preview.affectedCount == 1)
        #expect(preview.reversible)
        #expect(SettingsDeletionPresentation(intent: preview).secondPhrase == "I CONFIRM MOVE TO TRASH")
        #expect(try files(at: ownedRoot) == before)
        #expect(throws: SettingsDeletionError.operationFailed("未选中的子会话仍依赖本批会话")) {
            _ = try owned.deleteSessionsOlderThanRetention(intent: confirmed(preview), now: now)
        }
        #expect(try files(at: ownedRoot) == before)
        #expect(try owned.memoryStore.facts() == memoryBefore)
        #expect(try files(at: neighbourRoot) == neighbourBefore)
        #expect(owned.sessionStore.loadSession(id: parent.id) != nil)
        #expect(manager.loadSessionIncludingArchived(id: child.id) != nil)
        #expect(manager.archivedSessions().map(\.id) == (archivedChild ? [child.id] : []))
        #expect(try owned.previewSessionsOlderThanRetention(now: now).affectedCount == 1)
    }
}
