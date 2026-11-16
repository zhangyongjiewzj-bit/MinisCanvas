import Foundation
import Testing
import CryptoKit
import Darwin
@testable import MinisCore

@Suite("F05 complete atomic import", .serialized)
struct SyncAtomicImportTests {
    private enum Injected: Error { case failure }
    private final class Box<T>: @unchecked Sendable {
        let lock = NSLock(); private var stored: T
        init(_ value: T) { stored = value }
        var value: T { get { lock.lock(); defer { lock.unlock() }; return stored } set { lock.lock(); stored = newValue; lock.unlock() } }
    }
    private struct Fixture {
        let root: URL
        let manager: SyncManager
        let scope = MemoryScope(sessionID: "f05-session", projectID: "f05-project")
        init(_ label: String, after: Bool = false) throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("F05-\(label)-\(UUID().uuidString)", isDirectory: true)
            let chat = root.appendingPathComponent("chat", isDirectory: true)
            let core = root.appendingPathComponent("core", isDirectory: true)
            manager = SyncManager(sessionStore: SessionStore(directory: chat), memoryStore: MemoryStore(directory: chat),
                                  skillStore: SkillStore(skillsRoot: core.appendingPathComponent("skills", isDirectory: true)),
                                  settingsStore: SettingsStore(directory: core))
            _ = try manager.sessionStore.createSession(id: "f05-session", title: after ? "after" : "before")
            if after { _ = try manager.sessionStore.createSession(id: "f05-added-session", title: "new after-only session") }
            guard chmod(chat.appendingPathComponent("sessions/f05-session.json").path, 0o640) == 0 else { throw Injected.failure }
            _ = try manager.memoryStore.addFact(after ? "after fact" : "before fact", sourceSessionID: scope.sessionID, memoryScope: scope)
            _ = try manager.skillStore.importSkill(content: "---\nname: Atomic Skill\ndescription: fixture\n---\n\(after ? "after" : "before") skill")
            _ = manager.settingsStore.update(\.storage.sessionRetentionDays, to: after ? 83 : 41)
            try Data("untouched task neighbor".utf8).write(to: chat.appendingPathComponent("task-neighbor.json"))
            try Data("unselected provider metadata".utf8).write(to: core.appendingPathComponent("provider-neighbor.json"))
            try MemoryFileStore(directory: chat).writeGlobal("unchanged global memory")
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func bytes() throws -> [String: Data] {
            try SyncAtomicImportTests.fileStates(under: root).mapValues(\.data)
        }
        func snapshot() throws -> Data { try manager.exportSnapshot() }
    }

    @Test func systemAliasesAndFirstCreationKeepOneLayoutAndAdmissionIdentity() throws {
        let rootPath = PersistenceTransactionFence.stablePath(FileManager.default.temporaryDirectory)
            + "/F05-path-identity-\(UUID().uuidString)"
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let aliasPath = rootPath.hasPrefix("/private/var/") || rootPath.hasPrefix("/private/tmp/")
            ? String(rootPath.dropFirst("/private".count)) : rootPath
        let alias = URL(fileURLWithPath: aliasPath, isDirectory: false)
        func layout(_ base: URL) throws -> SyncAtomicImport.Layout {
            try .init(sessionDirectory: base, memoryDirectory: base, settingsDirectory: base,
                      skillsRoot: base.appendingPathComponent("skills", isDirectory: true))
        }
        let before = try layout(root)
        let aliasBefore = try layout(alias)
        #expect(before == aliasBefore)
        #expect(Set(before.domains) == Set(aliasBefore.domains))
        #expect(!FileManager.default.fileExists(atPath: rootPath))
        for name in ["sessions", "memory", "skills"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: true)
        }
        try Data("{}".utf8).write(to: root.appendingPathComponent("settings.json"))
        // Foundation standardizedFileURL intentionally returns /var or /tmp;
        // the trusted layout retains one /private-prefixed ownership identity.
        #expect(try layout(root.standardizedFileURL) == before)
        #expect(try layout(root) == before)
        #expect(try layout(alias) == before)
        #expect(try Set(layout(root).domains) == Set(before.domains))
        #expect(try Set(layout(alias).domains) == Set(before.domains))
        for domain in before.domains {
            #expect(domain.root.path.hasPrefix(rootPath + "/"))
            #expect(PersistenceTransactionFence.Domain(scope: domain.scope, root: URL(fileURLWithPath: domain.root.path, isDirectory: true)) == domain)
        }
        #expect(throws: SyncAtomicImportError.invalidLayout) {
            try SyncAtomicImport.Layout(sessionDirectory: root, memoryDirectory: alias.appendingPathComponent("sessions"),
                                        settingsDirectory: root, skillsRoot: root.appendingPathComponent("skills", isDirectory: true))
        }
        #expect(throws: SyncAtomicImportError.invalidLayout) {
            try SyncAtomicImport.Layout(sessionDirectory: alias.appendingPathComponent("skills"), memoryDirectory: root,
                                        settingsDirectory: root, skillsRoot: root.appendingPathComponent("skills", isDirectory: true))
        }
        #expect(throws: SyncAtomicImportError.invalidLayout) {
            try SyncAtomicImport.Layout(sessionDirectory: URL(string: "https://example.invalid/profile")!,
                                        memoryDirectory: root, settingsDirectory: root,
                                        skillsRoot: root.appendingPathComponent("skills", isDirectory: true))
        }
    }

    @Test func completeEnvelopeLimitIsInclusiveAndCountsEncodingExpansion() throws {
        let payload = Data("{\"before\":\"Ynl0ZXM=\",\"after\":\"Ynl0ZXM=\"}".utf8)
        let encoded = try SyncAtomicImport.encodeJournalEnvelope(payload)
        #expect(encoded.count > payload.count)
        #expect(try SyncAtomicImport.encodeJournalEnvelope(payload, maximumBytes: encoded.count) == encoded)
        #expect(throws: SyncAtomicImportError.inventoryLimit) {
            try SyncAtomicImport.encodeJournalEnvelope(payload, maximumBytes: encoded.count - 1)
        }
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: String])
        #expect(Data(base64Encoded: try #require(object["payload"])) == payload)
        #expect(object["hash"] == SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined())
    }

    @Test func oversizedPreparedEnvelopeWritesNothingAndLeavesAdmissionsUsable() throws {
        let source = try Fixture("capacity-source", after: true); defer { source.remove() }
        let target = try Fixture("capacity-target"); defer { target.remove() }
        let before = try target.bytes(); let data = try source.snapshot()
        let importer = try SyncAtomicImport(manager: target.manager, fault: nil, journalByteLimit: 1)
        let preview = try importer.preview(data, memoryScope: source.scope)
        #expect(throws: SyncAtomicImportError.inventoryLimit) {
            try importer.confirm(preview, snapshot: data, confirmation: .init(preview: preview))
        }
        #expect(try target.bytes() == before)
        #expect(!FileManager.default.fileExists(atPath: target.manager.settingsStore.directory.appendingPathComponent(".minis-sync-import-v1").path))
        #expect(!PersistenceTransactionFence.requiresReopen(target.manager.memoryStore.persistenceDomain))
        // A fresh confirmation through the real producer remains usable; the
        // capacity refusal must not strand a normal profile behind the fence.
        let ordinary = try SyncAtomicImport(manager: target.manager)
        let next = try ordinary.preview(data, memoryScope: source.scope)
        #expect(try ordinary.confirm(next, snapshot: data, confirmation: .init(preview: next)).committed)
    }

    @Test func stagedGrowthBeyondEnvelopeLimitRollsBackAndKeepsEveryJournalReadable() throws {
        let source = try Fixture("capacity-growth-source", after: true); defer { source.remove() }
        let target = try Fixture("capacity-growth-target"); defer { target.remove() }
        _ = try source.manager.memoryStore.addFact(String(repeating: "new memory ", count: 8_192),
                                                   sourceSessionID: source.scope.sessionID, memoryScope: source.scope)
        let data = try source.snapshot(); let before = try target.bytes()
        let measured = Box(0)
        let journalParent = target.manager.settingsStore.directory.appendingPathComponent(".minis-sync-import-v1")
        let measurement = try SyncAtomicImport(manager: target.manager, fault: { point, _ in
            if point == .stage {
                guard let files = FileManager.default.enumerator(at: journalParent, includingPropertiesForKeys: nil) else { throw Injected.failure }
                for case let url as URL in files {
                    if url.lastPathComponent == "journal.json" { measured.value = try Data(contentsOf: url).count }
                }
                throw Injected.failure
            }
        })
        let first = try measurement.preview(data, selecting: [.memories], memoryScope: source.scope)
        #expect(throws: (any Error).self) { try measurement.confirm(first, snapshot: data, confirmation: .init(preview: first)) }
        let initialSize = try #require(measured.value > 0 ? measured.value : nil)
        #expect(try target.bytes() == before)
        let limit = initialSize + 1_024
        let bounded = try SyncAtomicImport(manager: target.manager, fault: nil, journalByteLimit: limit)
        let next = try bounded.preview(data, selecting: [.memories], memoryScope: source.scope)
        #expect(throws: SyncAtomicImportError.inventoryLimit) { try bounded.confirm(next, snapshot: data, confirmation: .init(preview: next)) }
        #expect(try target.bytes() == before)
        #expect(!PersistenceTransactionFence.requiresReopen(target.manager.memoryStore.persistenceDomain))
        let journals = try #require(FileManager.default.enumerator(at: journalParent, includingPropertiesForKeys: nil))
        var count = 0
        for case let url as URL in journals where url.lastPathComponent == "journal.json" {
            let bytes = try Data(contentsOf: url); #expect(bytes.count <= limit)
            let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: String])
            let encodedPayload = try #require(object["payload"])
            let payload = try #require(Data(base64Encoded: encodedPayload))
            #expect(object["hash"] == SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined())
            count += 1
        }
        #expect(count == 2)
    }

    @Test func oversizedStartupJournalIsRejectedWithoutReadingOrReplacingIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("F05-oversized-journal-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = try SyncAtomicImport.Layout(sessionDirectory: root, memoryDirectory: root, settingsDirectory: root,
                                                 skillsRoot: root.appendingPathComponent("skills", isDirectory: true))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(layout)).map { String(format: "%02x", $0) }.joined()
        let journal = layout.settingsDirectory.appendingPathComponent(".minis-sync-import-v1/" + digest + "/" + UUID().uuidString + "/journal.json")
        try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        let marker = Data("oversized-sparse-journal".utf8)
        try marker.write(to: journal)
        let file = try FileHandle(forWritingTo: journal)
        try file.truncate(atOffset: UInt64(SyncAtomicImport.maximumJournalBytes) + 1); try file.close()
        let before = try FileManager.default.attributesOfItem(atPath: journal.path)
        #expect(throws: SyncAtomicImportError.unsafePath) { try SyncAtomicImport.recoverBeforeStores(layout: layout) }
        let after = try FileManager.default.attributesOfItem(atPath: journal.path)
        #expect((after[.size] as? NSNumber) == (before[.size] as? NSNumber))
        #expect((after[.systemFileNumber] as? NSNumber) == (before[.systemFileNumber] as? NSNumber))
        let reader = try FileHandle(forReadingFrom: journal); defer { try? reader.close() }
        #expect(try reader.read(upToCount: marker.count) == marker)
        #expect(!FileManager.default.fileExists(atPath: layout.settingsDirectory.appendingPathComponent("settings.json").path))
        #expect(!FileManager.default.fileExists(atPath: layout.skillsRoot.path))
    }

    @Test func previewAndCancelledConfirmationWriteNothingAndPreserveDirty() throws {
        let source = try Fixture("source", after: true); defer { source.remove() }
        let target = try Fixture("preview"); defer { target.remove() }
        let bytes = try target.bytes(); let data = try source.snapshot()
        target.manager.markDirty(.sessions)
        let importer = try SyncAtomicImport(manager: target.manager)
        let preview = try importer.preview(data, memoryScope: source.scope)
        #expect(preview.domains.map(\.scope) == SyncScope.allCases)
        // The source fixture adds one session; the other three domains each contain one item.
        #expect(preview.domains.count == 4)
        #expect(preview.domains.map(\.incomingCount) == [2, 1, 1, 1])
        #expect(preview.domains.map(\.overlappingCount) == [1, 1, 1, 1])
        #expect(try target.bytes() == bytes)
        #expect(target.manager.dirtyScopes == [.sessions])
        #expect(!FileManager.default.fileExists(atPath: target.manager.settingsStore.directory.appendingPathComponent(".minis-sync-import-v1").path))
        #expect(throws: PersistenceTransactionError.cancelled) {
            try importer.confirm(preview, snapshot: data, confirmation: .init(preview: preview), cancelled: { true })
        }
        #expect(try target.bytes() == bytes)
    }

    @Test func selectionUnknownScopeFutureVersionMissingPayloadAndProvenanceAreReadOnly() throws {
        let source = try Fixture("invalid-source", after: true); defer { source.remove() }
        let target = try Fixture("invalid-target"); defer { target.remove() }
        let before = try target.bytes(); let data = try source.snapshot()
        let importer = try SyncAtomicImport(manager: target.manager)
        #expect(throws: SyncAtomicImportError.missingMemoryScope) { try importer.preview(data) }
        #expect(throws: SyncAtomicImportError.foreignMemoryScope) { try importer.preview(data, memoryScope: .init(sessionID: "other", projectID: "foreign")) }
        #expect(throws: (any Error).self) { try importer.preview(data, selecting: [], memoryScope: source.scope) }
        for change in ["version", "scope", "payload", "path", "provenance"] {
            var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            var manifest = try #require(object["manifest"] as? [String: Any])
            if change == "version" { manifest["version"] = 999 }
            if change == "scope" { manifest["scopes"] = ["unknown"] }
            object["manifest"] = manifest
            if change == "payload" { object.removeValue(forKey: "settings") }
            if change == "path" {
                var sessions = try #require(object["sessions"] as? [[String: Any]])
                sessions[0]["id"] = "../escape"; object["sessions"] = sessions
            }
            if change == "provenance" {
                var memories = try #require(object["memories"] as? [[String: Any]])
                memories[0].removeValue(forKey: "memoryScope"); object["memories"] = memories
            }
            let invalid = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: (any Error).self) { try importer.preview(invalid, memoryScope: source.scope) }
            #expect(try target.bytes() == before)
        }
    }

    @Test func staleExpiredAndReplayedConfirmationDoNotPublish() throws {
        let source = try Fixture("stale-source", after: true); defer { source.remove() }
        let target = try Fixture("stale-target"); defer { target.remove() }
        let importer = try SyncAtomicImport(manager: target.manager); let data = try source.snapshot()
        let expired = try importer.preview(data, memoryScope: source.scope, now: .distantPast)
        #expect(throws: SyncAtomicImportError.expiredPreview) { try importer.confirm(expired, snapshot: data, confirmation: .init(preview: expired)) }
        let preview = try importer.preview(data, memoryScope: source.scope)
        _ = target.manager.settingsStore.update(\.storage.sessionRetentionDays, to: 42)
        let changed = try target.bytes()
        #expect(throws: SyncAtomicImportError.stalePreview) { try importer.confirm(preview, snapshot: data, confirmation: .init(preview: preview)) }
        #expect(try target.bytes() == changed)
        let secondImporter = try SyncAtomicImport(manager: target.manager)
        #expect(throws: SyncAtomicImportError.replayedConfirmation) { try secondImporter.confirm(preview, snapshot: data, confirmation: .init(preview: preview)) }
    }

    @Test func identicalBytesAtReplacedDestinationRootCannotConsumeFourDomainPreview() throws {
        let source = try Fixture("root-source", after: true); defer { source.remove() }
        let target = try Fixture("root-target"); defer { target.remove() }
        let importer = try SyncAtomicImport(manager: target.manager)
        let data = try source.snapshot()
        let preview = try importer.preview(data, selecting: Set(SyncScope.allCases), memoryScope: source.scope)
        #expect(preview.selected == Set(SyncScope.allCases))

        // Keep every file and mode identical while replacing the directory
        // objects behind the same admitted paths. A path-only inventory hash
        // cannot distinguish this from the reviewed destination.
        let replacement = target.root.deletingLastPathComponent()
            .appendingPathComponent("F05-replacement-\(UUID().uuidString)", isDirectory: true)
        let displaced = target.root.deletingLastPathComponent()
            .appendingPathComponent("F05-displaced-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: replacement)
            try? FileManager.default.removeItem(at: displaced)
        }
        guard chmod(target.root.path, 0o700) == 0 else { throw Injected.failure }
        try FileManager.default.copyItem(at: target.root, to: replacement)
        guard chmod(replacement.path, 0o700) == 0 else { throw Injected.failure }
        let before = try target.bytes()
        try FileManager.default.moveItem(at: target.root, to: displaced)
        try FileManager.default.moveItem(at: replacement, to: target.root)
        #expect(try target.bytes() == before)
        #expect(try Self.fileStates(under: displaced).mapValues(\.data) == before)

        #expect(throws: SyncAtomicImportError.stalePreview) {
            try importer.confirm(preview, snapshot: data, confirmation: .init(preview: preview))
        }
        #expect(try target.bytes() == before)
        #expect(try Self.fileStates(under: displaced).mapValues(\.data) == before)
        #expect(!PersistenceTransactionFence.requiresReopen(target.manager.memoryStore.persistenceDomain))
    }

    @Test func identicalBytesAtReplacedSkillsRootCannotConsumeFourDomainPreview() throws {
        let source = try Fixture("skill-root-source", after: true); defer { source.remove() }
        let target = try Fixture("skill-root-target"); defer { target.remove() }
        let importer = try SyncAtomicImport(manager: target.manager)
        let data = try source.snapshot()
        let preview = try importer.preview(data, selecting: Set(SyncScope.allCases), memoryScope: source.scope)
        let skills = target.manager.skillStore.skillsRoot
        let replacement = target.root.deletingLastPathComponent()
            .appendingPathComponent("F05-skills-replacement-\(UUID().uuidString)", isDirectory: true)
        let displaced = target.root.deletingLastPathComponent()
            .appendingPathComponent("F05-skills-displaced-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: replacement)
            try? FileManager.default.removeItem(at: displaced)
        }
        guard chmod(skills.path, 0o700) == 0 else { throw Injected.failure }
        try FileManager.default.copyItem(at: skills, to: replacement)
        guard chmod(replacement.path, 0o700) == 0 else { throw Injected.failure }
        let before = try target.bytes()
        let skillsBefore = try Self.fileStates(under: skills)
        try FileManager.default.moveItem(at: skills, to: displaced)
        try FileManager.default.moveItem(at: replacement, to: skills)
        #expect(try target.bytes() == before)
        #expect(try Self.fileStates(under: displaced) == skillsBefore)

        #expect(throws: SyncAtomicImportError.stalePreview) {
            try importer.confirm(preview, snapshot: data, confirmation: .init(preview: preview))
        }
        #expect(try target.bytes() == before)
        #expect(try Self.fileStates(under: displaced) == skillsBefore)
    }

    @Test func fullCommitHasBackupExactTargetsBeforeViewAndAllOldWritersRefused() throws {
        let source = try Fixture("commit-source", after: true); defer { source.remove() }
        let target = try Fixture("commit-target"); defer { target.remove() }
        let before = try target.bytes(); let data = try source.snapshot()
        let importer = try SyncAtomicImport(manager: target.manager)
        let preview = try importer.preview(data, memoryScope: source.scope)
        let receipt = try importer.confirm(preview, snapshot: data, confirmation: .init(preview: preview))
        #expect(receipt.committed && receipt.reopenRequired)
        #expect(receipt.fileCount > 0)
        #expect(FileManager.default.fileExists(atPath: receipt.backupURL.path))
        #expect(FileManager.default.fileExists(atPath: receipt.journalURL.path))
        let disk = try target.bytes()
        for key in ["/chat/task-neighbor.json", "/core/provider-neighbor.json", "/chat/memory/GLOBAL.md"] {
            let old = try #require(before[key]); let current = try #require(disk[key])
            #expect(current == old)
        }
        #expect(before["/chat/sessions/f05-added-session.json"] == nil)
        let added = try #require(disk["/chat/sessions/f05-added-session.json"])
        #expect(try JSONDecoder().decode(ChatSession.self, from: added).title == "new after-only session")
        let states = try Self.fileStates(under: target.root)
        let payload = try Self.journalPayload(receipt.journalURL)
        let entries = try #require(payload["entries"] as? [[String: Any]])
        let sessionEntry = try #require(entries.first { ($0["path"] as? String).map { $0.hasSuffix("/chat/sessions/f05-session.json") } == true })
        let afterImage = try #require(sessionEntry["after"] as? [String: Any])
        let afterMode = try #require(afterImage["mode"] as? NSNumber)
        let sessionState = try #require(states["/chat/sessions/f05-session.json"])
        #expect(sessionState.mode == afterMode.uint16Value)
        #expect(target.manager.sessionStore.loadSession(id: "f05-session")?.title == "before")
        #expect(target.manager.settingsStore.settings.storage.sessionRetentionDays == 41)
        #expect(target.manager.skillStore.rawContent("atomic-skill")?.contains("before skill") == true)
        #expect(throws: PersistenceTransactionError.reopenRequired) { try target.manager.memoryStore.facts() }
        #expect(throws: PersistenceTransactionError.reopenRequired) { try MemoryManager(store: target.manager.memoryStore).overview() }
        #expect(throws: PersistenceTransactionError.reopenRequired) { try target.manager.sessionStore.createSession(id: "late", title: "late") }
        #expect(throws: PersistenceTransactionError.reopenRequired) { try SessionManager(store: target.manager.sessionStore).archive(sessionID: "f05-session") }
        #expect(throws: PersistenceTransactionError.reopenRequired) { try MemoryFileStore(directory: target.manager.memoryStore.directory).writeGlobal("late") }
        #expect(throws: PersistenceTransactionError.reopenRequired) { try target.manager.memoryStore.addFact("late") }
        #expect(throws: PersistenceTransactionError.reopenRequired) { try target.manager.skillStore.importSkill(content: "late") }
        if case .success = target.manager.settingsStore.replace(with: .defaults) { Issue.record("old settings write escaped latch") }
        let freshSettings = SettingsStore(directory: target.manager.settingsStore.directory, initial: .defaults)
        #expect(freshSettings.settings.storage.sessionRetentionDays == 41)
        let freshSkills = SkillStore(skillsRoot: target.manager.skillStore.skillsRoot)
        #expect(freshSkills.rawContent("atomic-skill")?.contains("before skill") == true)
        freshSkills.setEnabled("atomic-skill", enabled: true)
        #expect(try target.bytes() == disk)
        #expect(throws: PersistenceTransactionError.bootstrapAfterStoreOpened) { try SyncAtomicImport.recoverBeforeStores(layout: importer.layout) }
        let persistedSession = try JSONDecoder().decode(ChatSession.self, from: #require(disk["/chat/sessions/f05-session.json"]))
        #expect(persistedSession.title == "after")
    }

    @Test func selectedDomainCannotPublishOtherDomainsOrSwapSharedRoot() throws {
        let source = try Fixture("selected-source", after: true); defer { source.remove() }
        let target = try Fixture("selected-target"); defer { target.remove() }
        let before = try target.bytes()
        let attrs = try FileManager.default.attributesOfItem(atPath: target.manager.sessionStore.directory.path)
        let importer = try SyncAtomicImport(manager: target.manager); let data = try source.snapshot()
        let preview = try importer.preview(data, selecting: [.settings])
        _ = try importer.confirm(preview, snapshot: data, confirmation: .init(preview: preview))
        let after = try target.bytes()
        let oldSettings = try #require(before["/core/settings.json"])
        let newSettings = try #require(after["/core/settings.json"])
        #expect(oldSettings != newSettings)
        #expect(Set(before.keys) == Set(after.keys))
        for path in before.keys where path != "/core/settings.json" {
            let old = try #require(before[path]); let current = try #require(after[path])
            #expect(old == current)
        }
        let newAttrs = try FileManager.default.attributesOfItem(atPath: target.manager.sessionStore.directory.path)
        let oldInode = try #require(attrs[.systemFileNumber] as? NSNumber)
        let newInode = try #require(newAttrs[.systemFileNumber] as? NSNumber)
        #expect(oldInode == newInode)
    }

    @Test(arguments: [SyncAtomicImport.FaultPoint.backup, .stage, .prepareJournal, .beforeFile, .afterFile, .fileFsync, .directoryFsync, .beforeCommitMarker])
    func failuresRestoreEveryDomainAndNeighbors(point: SyncAtomicImport.FaultPoint) throws {
        let source = try Fixture("fault-source", after: true); defer { source.remove() }
        let target = try Fixture("fault-target"); defer { target.remove() }
        let before = try target.bytes(); let beforeStates = try Self.fileStates(under: target.root); let fired = Box(false)
        let importer = try SyncAtomicImport(manager: target.manager, fault: { observed, _ in
            if observed == point && !fired.value { fired.value = true; throw Injected.failure }
        })
        let data = try source.snapshot(); let preview = try importer.preview(data, memoryScope: source.scope)
        #expect(throws: (any Error).self) { try importer.confirm(preview, snapshot: data, confirmation: .init(preview: preview)) }
        #expect(fired.value)
        #expect(try target.bytes() == before)
        #expect(try Self.fileStates(under: target.root) == beforeStates)
        _ = try target.manager.sessionStore.createSession(id: "after-rollback", title: "writer reopened")
    }

    @Test(arguments: SyncScope.allCases)
    func eachDomainBackupAndStageFailureLeavesWholeProfileBefore(scope: SyncScope) throws {
        for point in [SyncAtomicImport.FaultPoint.backup, .stage] {
            let source = try Fixture("domain-source", after: true); defer { source.remove() }
            let target = try Fixture("domain-target"); defer { target.remove() }
            let before = try target.bytes()
            let importer = try SyncAtomicImport(manager: target.manager, fault: { observed, path in
                if observed == point && path == scope.rawValue { throw Injected.failure }
            })
            let data = try source.snapshot(); let preview = try importer.preview(data, memoryScope: source.scope)
            #expect(throws: (any Error).self) { try importer.confirm(preview, snapshot: data, confirmation: .init(preview: preview)) }
            #expect(try target.bytes() == before)
        }
    }

    @Test(arguments: SyncScope.allCases)
    func eachDomainPostInstallFailureRollsBackAllFourDomains(scope: SyncScope) throws {
        let source = try Fixture("post-install-source", after: true); defer { source.remove() }
        let target = try Fixture("post-install-target"); defer { target.remove() }
        let before = try Self.fileStates(under: target.root)
        let chat = PersistenceTransactionFence.stablePath(target.manager.sessionStore.directory)
        let core = PersistenceTransactionFence.stablePath(target.manager.settingsStore.directory)
        let skills = PersistenceTransactionFence.stablePath(target.manager.skillStore.skillsRoot)
        let fired = Box(false)
        let affectedPath = Box("")
        let importer = try SyncAtomicImport(manager: target.manager, fault: { point, path in
            guard point == .afterFile, let path else { return }
            let matches: Bool
            switch scope {
            case .sessions: matches = path.hasPrefix(chat + "/sessions/")
            case .memories: matches = path.hasPrefix(chat + "/memory/")
            case .skills: matches = path.hasPrefix(skills + "/") || path == core + "/skills-enabled.json"
            case .settings: matches = path == core + "/settings.json"
            }
            if matches && !fired.value {
                fired.value = true
                affectedPath.value = path
                throw Injected.failure
            }
        })
        let data = try source.snapshot()
        let preview = try importer.preview(data, memoryScope: source.scope)
        #expect(throws: (any Error).self) {
            try importer.confirm(preview, snapshot: data, confirmation: .init(preview: preview))
        }
        #expect(fired.value && !affectedPath.value.isEmpty)
        guard fired.value else { return }
        #expect(try Self.fileStates(under: target.root) == before)
        _ = try target.manager.sessionStore.createSession(
            id: "after-\(scope.rawValue)-rollback", title: "writer reopened")
    }

    @Test func incompleteRollbackKeepsOldAndFreshStoreWritersFenced() throws {
        let source = try Fixture("recovery-source", after: true); defer { source.remove() }
        let target = try Fixture("recovery-target"); defer { target.remove() }
        let importer = try SyncAtomicImport(manager: target.manager, fault: { point, _ in
            if point == .afterFile || point == .rollbackFile { throw Injected.failure }
        })
        let data = try source.snapshot(); let preview = try importer.preview(data, memoryScope: source.scope)
        #expect(throws: SyncAtomicImportError.rollbackIncomplete) { try importer.confirm(preview, snapshot: data, confirmation: .init(preview: preview)) }
        #expect(throws: PersistenceTransactionError.recoveryRequired) { try target.manager.sessionStore.createSession(id: "late", title: "late") }
        #expect(throws: PersistenceTransactionError.recoveryRequired) { try MemoryManager(store: target.manager.memoryStore).overview() }
        let fresh = SettingsStore(directory: target.manager.settingsStore.directory)
        #expect(fresh.settings.storage.sessionRetentionDays == 41)
        if case .success = fresh.replace(with: .defaults) { Issue.record("fresh constructor bypassed recovery latch") }
        #expect(throws: PersistenceTransactionError.bootstrapAfterStoreOpened) { try SyncAtomicImport.recoverBeforeStores(layout: importer.layout) }
    }

    @Test func exclusiveDrainsOldNestedWorkRejectsUpgradeAndCancelsWithoutDeadlock() throws {
        let target = try Fixture("drain"); defer { target.remove() }
        let domain = target.manager.memoryStore.persistenceDomain
        let entered = DispatchSemaphore(value: 0); let release = DispatchSemaphore(value: 0); let completed = DispatchSemaphore(value: 0)
        let error = Box<Error?>(nil)
        DispatchQueue.global().async {
            do {
                try PersistenceTransactionFence.withWrite([domain]) {
                    entered.signal()
                    guard release.wait(timeout: .now() + 5) == .success else { throw Injected.failure }
                    _ = try target.manager.memoryStore.addFact("nested admitted write")
                }
            } catch let caught { error.value = caught }
            completed.signal()
        }
        #expect(entered.wait(timeout: .now() + 2) == .success)
        #expect(throws: PersistenceTransactionError.cancelled) { try PersistenceTransactionFence.exclusive([domain], deadline: Date().addingTimeInterval(2), cancelled: { true }) }
        release.signal(); #expect(completed.wait(timeout: .now() + 3) == .success); #expect(error.value == nil)
        _ = try PersistenceTransactionFence.withWrite([domain]) {
            #expect(throws: PersistenceTransactionError.illegalUpgrade) { try PersistenceTransactionFence.exclusive([domain], deadline: Date().addingTimeInterval(1)) }
        }
    }

    @Test func cancellationAfterDurableCommitRemainsCommitted() throws {
        let source = try Fixture("postcommit-source", after: true); defer { source.remove() }
        let target = try Fixture("postcommit-target"); defer { target.remove() }
        let cancelled = Box(false)
        let importer = try SyncAtomicImport(manager: target.manager, fault: { point, _ in if point == .afterCommitMarker { cancelled.value = true } })
        let data = try source.snapshot(); let preview = try importer.preview(data, memoryScope: source.scope)
        let result = try importer.confirm(preview, snapshot: data, confirmation: .init(preview: preview), cancelled: { cancelled.value })
        #expect(result.committed && result.reopenRequired && result.cancellationObservedAfterCommit)
        #expect(throws: PersistenceTransactionError.reopenRequired) { try target.manager.memoryStore.addFact("late") }
    }

    @Test func unsafeAliasesAndHardlinksPreserveBytes() throws {
        let source = try Fixture("unsafe-source", after: true); defer { source.remove() }
        let target = try Fixture("unsafe-target"); defer { target.remove() }
        let alias = target.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target.manager.sessionStore.directory)
        #expect(throws: SyncAtomicImportError.invalidLayout) {
            try SyncAtomicImport.Layout(sessionDirectory: alias, memoryDirectory: target.manager.memoryStore.directory,
                                        settingsDirectory: target.manager.settingsStore.directory, skillsRoot: target.manager.skillStore.skillsRoot)
        }
        try FileManager.default.removeItem(at: alias)
        let file = target.manager.memoryStore.fileURL
        let link = file.deletingLastPathComponent().appendingPathComponent("linked.json")
        try FileManager.default.linkItem(at: file, to: link)
        let importer = try SyncAtomicImport(manager: target.manager)
        #expect(throws: SyncAtomicImportError.unsafePath) { try importer.preview(source.snapshot(), memoryScope: source.scope) }
        try FileManager.default.removeItem(at: link)
        #expect(try target.manager.memoryStore.facts().count == 1)
    }

    @Test func unknownJournalFailsBeforeAnyStoreOpensAndPreservesEvidence() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("F05-corrupt-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = try SyncAtomicImport.Layout(sessionDirectory: root.appendingPathComponent("chat", isDirectory: true),
                                                 memoryDirectory: root.appendingPathComponent("chat", isDirectory: true),
                                                 settingsDirectory: root.appendingPathComponent("core", isDirectory: true),
                                                 skillsRoot: root.appendingPathComponent("core/skills", isDirectory: true))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(layout)).map { String(format: "%02x", $0) }.joined()
        let journal = layout.settingsDirectory.appendingPathComponent(".minis-sync-import-v1/" + digest + "/" + UUID().uuidString + "/journal.json")
        try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = Data("{unknown journal bytes".utf8); try corrupt.write(to: journal)
        #expect(throws: SyncAtomicImportError.invalidJournal) { try SyncAtomicImport.recoverBeforeStores(layout: layout) }
        #expect(try Data(contentsOf: journal) == corrupt)
        #expect(!FileManager.default.fileExists(atPath: layout.settingsDirectory.appendingPathComponent("settings.json").path))
        #expect(!FileManager.default.fileExists(atPath: layout.skillsRoot.path))
    }

    @Test func fixtureKeysUseStableComponentPrefixAndRequireExistingNeighbors() throws {
        let root = URL(fileURLWithPath: "/private/var/tmp/F05-projection", isDirectory: true)
        let file = URL(fileURLWithPath: "/var/tmp/F05-projection/core/settings.json")
        #expect(try Self.relativeKey(file, under: root) == "/core/settings.json")
        #expect(try Self.relativeKey(file.resolvingSymlinksInPath(), under: root.standardizedFileURL) == "/core/settings.json")
        #expect(throws: SyncAtomicImportError.unsafePath) {
            try Self.relativeKey(URL(fileURLWithPath: "/private/var/tmp/F05-projection-neighbor/core/settings.json"), under: root)
        }
        let target = try Fixture("projection"); defer { target.remove() }
        let bytes = try target.bytes()
        for key in ["/chat/sessions/f05-session.json", "/core/settings.json", "/chat/task-neighbor.json", "/core/provider-neighbor.json", "/chat/memory/GLOBAL.md"] {
            let value = try #require(bytes[key])
            #expect(!value.isEmpty)
        }
        #expect(try target.bytes() == Self.fileStates(under: target.root).mapValues(\.data))
    }

    private struct FileState: Codable, Equatable {
        let data: Data
        let mode: UInt16
    }

    private static func relativeKey(_ file: URL, under root: URL) throws -> String {
        let base = PersistenceTransactionFence.stablePath(root)
        let path = PersistenceTransactionFence.stablePath(file)
        guard path.hasPrefix(base + "/") else { throw SyncAtomicImportError.unsafePath }
        let key = String(path.dropFirst(base.count))
        try #require(key.hasPrefix("/") && !key.dropFirst().isEmpty)
        return key
    }

    private static func fileStates(under root: URL) throws -> [String: FileState] {
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var result: [String: FileState] = [:]
        for case let file as URL in enumerator {
            let key = try relativeKey(file, under: root)
            if key == "/core/.minis-sync-import-v1" || key.hasPrefix("/core/.minis-sync-import-v1/") {
                enumerator.skipDescendants(); continue
            }
            var info = stat()
            try #require(lstat(file.path, &info) == 0)
            try #require((info.st_mode & S_IFMT) != S_IFLNK, "fixture snapshots never follow symlinks")
            if (info.st_mode & S_IFMT) == S_IFREG {
                try #require(result[key] == nil, "fixture relative keys must be unique")
                result[key] = FileState(data: try Data(contentsOf: file), mode: UInt16(info.st_mode & 0o7777))
            }
        }
        return result
    }

    private static func journalPayload(_ url: URL) throws -> [String: Any] {
        let envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let encoded = try #require(envelope["payload"] as? String)
        let payload = try #require(Data(base64Encoded: encoded))
        return try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
    }

    private static func journalURL(in target: Fixture) throws -> URL {
        let root = target.manager.settingsStore.directory.appendingPathComponent(".minis-sync-import-v1")
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        let journals = enumerator.compactMap { $0 as? URL }.filter { $0.lastPathComponent == "journal.json" }
        try #require(journals.count == 1)
        return journals[0]
    }

    private struct RecoveryRequest: Codable {
        let nonce: String
        let parentPID: Int32
        let expectedModuleName: String
        let expectedNameComponents: [String]
        let root: URL
        let layout: SyncAtomicImport.Layout
        let journalURL: URL
        let journalHash: String
        let backupHash: String
        let phase: String
        let expected: [String: FileState]
        let title: String
        let rejection: String?
        let receiptURL: URL
    }
    private struct RecoveryProof: Codable {
        let nonce: String
        let parentPID: Int32
        let childPID: Int32
        let testID: String
        let testModuleName: String
        let testNameComponents: [String]
        let testSourceLocation: String
        let phase: String
        let outcome: String
        let checkedFiles: Int
        let recoveredBeforeStores: Bool
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// With no request this remains a standalone no-op; only the parent-bound
    /// ID, nonzero raw execution and nonce receipt prove a recovery child ran.
    @Test func bootstrapChild() throws {
        let env = ProcessInfo.processInfo.environment
        guard let encoded = env["F05_RECOVERY_REQUEST"] else { return }
        let requestData = try #require(Data(base64Encoded: encoded))
        let request = try JSONDecoder().decode(RecoveryRequest.self, from: requestData)
        let childID = try #require(Test.current?.id)
        try #require(childID.moduleName == request.expectedModuleName)
        try #require(childID.nameComponents == request.expectedNameComponents)
        let sourceLocation = String(describing: try #require(childID.sourceLocation))
        try #require(!sourceLocation.isEmpty)
        let currentID = childID.description
        try #require(getpid() != request.parentPID)
        try #require(Self.digest(Data(contentsOf: request.journalURL)) == request.journalHash)
        let backup = request.journalURL.deletingLastPathComponent().appendingPathComponent("backup.json")
        try #require(Self.digest(Data(contentsOf: backup)) == request.backupHash)
        let payload = try Self.journalPayload(request.journalURL)
        try #require(payload["phase"] as? String == request.phase)
        if let rejection = request.rejection {
            do {
                try SyncAtomicImport.recoverBeforeStores(layout: request.layout)
                Issue.record("tampered committed transaction was admitted")
                throw Injected.failure
            } catch let error as SyncAtomicImportError {
                #expect(error == (rejection == "invalidJournal" ? .invalidJournal : .stalePreview))
                try #require(error == (rejection == "invalidJournal" ? .invalidJournal : .stalePreview))
            }
            try #require(Self.fileStates(under: request.root) == request.expected)
            try #require(Self.digest(Data(contentsOf: request.journalURL)) == request.journalHash)
            try #require(Self.digest(Data(contentsOf: backup)) == request.backupHash)
            // Rejection is checked before constructing any Store, and keeps the
            // profile fenced for a later explicit recovery decision.
            for domain in request.layout.domains {
                #expect(throws: PersistenceTransactionError.recoveryRequired) {
                    try PersistenceTransactionFence.withWrite([domain]) { }
                }
            }
        } else {
            try SyncAtomicImport.recoverBeforeStores(layout: request.layout)
            try #require(Self.fileStates(under: request.root) == request.expected)
            let recovered = try Self.journalPayload(request.journalURL)
            try #require(recovered["phase"] as? String == (request.phase == "COMMITTED" ? "COMMITTED" : "ROLLED_BACK"))
            try #require(recovered["recoveryAcknowledged"] as? Bool == true)
            try #require(Self.digest(Data(contentsOf: backup)) == request.backupHash)
            let store = SessionStore(directory: request.layout.sessionDirectory)
            #expect(store.loadSession(id: "f05-session")?.title == request.title)
            let memory = MemoryStore(directory: request.layout.memoryDirectory)
            #expect(try !memory.facts().isEmpty)
            let skills = SkillStore(skillsRoot: request.layout.skillsRoot)
            #expect(skills.rawContent("atomic-skill")?.contains(request.title + " skill") == true)
            let settings = SettingsStore(directory: request.layout.settingsDirectory)
            #expect(settings.settings.storage.sessionRetentionDays == (request.title == "after" ? 83 : 41))
            _ = try store.createSession(id: "fresh-process-write", title: "recovered")
            try Data("PASS".utf8).write(to: request.layout.sessionDirectory.appendingPathComponent("fresh-process-recovery.receipt"))
        }
        let proof = RecoveryProof(nonce: request.nonce, parentPID: request.parentPID, childPID: getpid(), testID: currentID,
                                  testModuleName: childID.moduleName, testNameComponents: childID.nameComponents,
                                  testSourceLocation: sourceLocation,
                                  phase: request.phase, outcome: request.rejection == nil ? "PASS" : "REJECTED",
                                  checkedFiles: request.expected.count, recoveredBeforeStores: request.rejection == nil)
        let bytes = try JSONEncoder().encode(proof)
        try bytes.write(to: request.receiptURL)
        print("F05_RECOVERY_CHILD_PROOF " + bytes.base64EncodedString())
    }

    private func runRecoveryChild(target: Fixture, importer: SyncAtomicImport, phase: String,
                                  expected: [String: FileState], title: String, rejection: String? = nil) throws {
        let parentID = try #require(Test.current?.id)
        try #require(parentID.moduleName == "MinisCoreTests")
        try #require(parentID.nameComponents.count >= 2 && parentID.nameComponents.dropLast().last == "SyncAtomicImportTests")
        let expectedNameComponents = Array(parentID.nameComponents.dropLast()) + ["bootstrapChild()"]
        // A directed parent --filter does not prepare traits on unselected
        // sibling tests. Select the only bootstrapChild test by name, then
        // verify its actual complete ID and source location in the child proof.
        let filter = "bootstrapChild\\(\\)"
        let inherited = CommandLine.arguments
        let bundleFlags = inherited.indices.filter { inherited[$0] == "--test-bundle-path" }
        // On macOS SwiftPM loads an MH_BUNDLE through its existing helper. The
        // original child dropped this argument and could exit 0 with no tests.
        try #require(bundleFlags.count == 1)
        let bundleIndex = bundleFlags[0] + 1
        try #require(bundleIndex < inherited.count)
        try #require(inherited[0].hasPrefix("/") && inherited[bundleIndex].hasPrefix("/"))
        let helper = URL(fileURLWithPath: inherited[0]).standardizedFileURL
        try #require(helper.path.hasSuffix("/usr/libexec/swift/pm/swiftpm-testing-helper"))
        // The inherited argument names the MH_BUNDLE payload, not its .xctest directory.
        let payload = URL(fileURLWithPath: inherited[bundleIndex]).standardizedFileURL
        let macOSDirectory = payload.deletingLastPathComponent()
        let contentsDirectory = macOSDirectory.deletingLastPathComponent()
        let testBundle = contentsDirectory.deletingLastPathComponent()
        try #require(payload.lastPathComponent == "MinisCorePackageTests")
        try #require(macOSDirectory.lastPathComponent == "MacOS" && contentsDirectory.lastPathComponent == "Contents")
        try #require(testBundle.lastPathComponent == "MinisCorePackageTests.xctest")
        for directory in [testBundle, contentsDirectory, macOSDirectory] {
            var info = stat()
            try #require(lstat(directory.path, &info) == 0)
            try #require((info.st_mode & S_IFMT) == S_IFDIR)
        }
        for file in [helper, payload] {
            var info = stat()
            try #require(lstat(file.path, &info) == 0)
            try #require((info.st_mode & S_IFMT) == S_IFREG && info.st_size > 0)
            try #require(FileManager.default.isReadableFile(atPath: file.path))
        }
        try #require(FileManager.default.isExecutableFile(atPath: helper.path))
        let journal = try Self.journalURL(in: target)
        try #require(Self.journalPayload(journal)["phase"] as? String == phase)
        let evidence = FileManager.default.temporaryDirectory.appendingPathComponent("F05-child-evidence-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: evidence) }
        let receipt = evidence.appendingPathComponent("receipt.json")
        let request = RecoveryRequest(nonce: UUID().uuidString, parentPID: getpid(),
                                      expectedModuleName: parentID.moduleName, expectedNameComponents: expectedNameComponents,
                                      root: target.root,
                                      layout: importer.layout, journalURL: journal, journalHash: Self.digest(try Data(contentsOf: journal)),
                                      backupHash: Self.digest(try Data(contentsOf: journal.deletingLastPathComponent().appendingPathComponent("backup.json"))),
                                      phase: phase, expected: expected, title: title, rejection: rejection, receiptURL: receipt)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: inherited[0])
        process.arguments = ["--test-bundle-path", inherited[bundleIndex], "--testing-library", "swift-testing", "--filter", filter]
        var environment = ProcessInfo.processInfo.environment
        environment["F05_RECOVERY_REQUEST"] = try JSONEncoder().encode(request).base64EncodedString()
        process.environment = environment
        let log = evidence.appendingPathComponent("recovery-child.raw")
        try #require(FileManager.default.createFile(atPath: log.path, contents: nil))
        let handle = try FileHandle(forWritingTo: log)
        process.standardOutput = handle
        process.standardError = handle
        // Forward the complete child log into the original parent raw before
        // removing disposable evidence, including failed/zero-selection runs.
        defer {
            try? handle.synchronize(); try? handle.close()
            if let bytes = try? Data(contentsOf: log) {
                // One lossless record keeps nested child suite summaries from
                // contaminating the original parent's actual test counters.
                let record = "F05_RECOVERY_CHILD_RAW nonce=\(request.nonce) phase=\(phase) sha256=\(Self.digest(bytes)) base64=\(bytes.base64EncodedString())\n"
                // #346 option A (test-context bypass on the #344 diagnosis):
                // drain any pending stdio buffer, then emit this record through
                // a dedicated duplicated stdout file handle with an explicit
                // flush, so the runner's aggregated summary lines and the
                // child record no longer share the same stdout write window.
                // Record bytes keep the original prefix/fields/nonce semantics.
                fflush(stdout)
                let recordFD = dup(STDOUT_FILENO)
                if recordFD >= 0 {
                    let recordHandle = FileHandle(fileDescriptor: recordFD, closeOnDealloc: false)
                    recordHandle.write(Data(record.utf8))
                    try? recordHandle.synchronize()
                    try? recordHandle.close()
                } else {
                    FileHandle.standardOutput.write(Data(record.utf8))
                }
            } else { Issue.record("recovery child raw could not be retained") }
        }
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        let timedOut = done.wait(timeout: .now() + 15) != .success
        if timedOut {
            process.terminate(); _ = done.wait(timeout: .now() + 2)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            Issue.record("original test-binary recovery child timed out")
        } else { process.waitUntilExit() }
        #expect(!process.isRunning)
        #expect(process.terminationStatus == 0)
        try #require(!timedOut && !process.isRunning && process.terminationStatus == 0)
        try handle.synchronize()
        let raw = try String(contentsOf: log, encoding: .utf8)
        try #require(raw.contains("Test bootstrapChild() started."))
        try #require(raw.contains("Test bootstrapChild() passed after"))
        try #require(raw.range(of: #"Test run with 1 test in 1 suite passed after"#, options: .regularExpression) != nil)
        let proofData = try Data(contentsOf: receipt)
        let proof = try JSONDecoder().decode(RecoveryProof.self, from: proofData)
        try #require(proof.nonce == request.nonce && proof.parentPID == getpid() && proof.childPID == process.processIdentifier)
        try #require(proof.testModuleName == parentID.moduleName && proof.testNameComponents == expectedNameComponents)
        try #require(!proof.testID.isEmpty && !proof.testSourceLocation.isEmpty)
        try #require(proof.phase == phase && proof.checkedFiles == expected.count && proof.checkedFiles > 0)
        try #require(proof.outcome == (rejection == nil ? "PASS" : "REJECTED") && proof.recoveredBeforeStores == (rejection == nil))
        try #require(raw.contains("F05_RECOVERY_CHILD_PROOF " + proofData.base64EncodedString()))
        if rejection == nil {
            let legacyReceipt = target.manager.sessionStore.directory.appendingPathComponent("fresh-process-recovery.receipt")
            #expect(try Data(contentsOf: legacyReceipt) == Data("PASS".utf8))
        } else {
            #expect(try Self.fileStates(under: target.root) == expected)
            #expect(!FileManager.default.fileExists(atPath: target.manager.sessionStore.directory.appendingPathComponent("fresh-process-recovery.receipt").path))
        }
    }

    @Test func newProcessRecoversRealInterruptedJournalBeforeConstructors() throws {
        let source = try Fixture("child-source", after: true); defer { source.remove() }
        let target = try Fixture("child-target"); defer { target.remove() }
        let before = try Self.fileStates(under: target.root)
        let importer = try SyncAtomicImport(manager: target.manager, fault: { point, _ in
            if point == .afterFile || point == .rollbackFile { throw Injected.failure }
        })
        let data = try source.snapshot(); let preview = try importer.preview(data, memoryScope: source.scope)
        #expect(throws: SyncAtomicImportError.rollbackIncomplete) { try importer.confirm(preview, snapshot: data, confirmation: .init(preview: preview)) }
        try runRecoveryChild(target: target, importer: importer, phase: "COMMITTING", expected: before, title: "before")
    }

    @Test func newProcessRecoversPreparedJournalBeforeConstructors() throws {
        let source = try Fixture("prepared-child-source", after: true); defer { source.remove() }
        let target = try Fixture("prepared-child-target"); defer { target.remove() }
        let before = try Self.fileStates(under: target.root)
        let importer = try SyncAtomicImport(manager: target.manager, fault: { point, phase in
            if (point == .journalFsync && phase == "COMMITTING") || point == .rollbackFile { throw Injected.failure }
        })
        let data = try source.snapshot(); let preview = try importer.preview(data, memoryScope: source.scope)
        #expect(throws: SyncAtomicImportError.rollbackIncomplete) { try importer.confirm(preview, snapshot: data, confirmation: .init(preview: preview)) }
        #expect(try Self.fileStates(under: target.root) == before)
        try runRecoveryChild(target: target, importer: importer, phase: "PREPARED", expected: before, title: "before")
    }

    @Test func newProcessValidatesCommittedJournalBeforeConstructors() throws {
        let source = try Fixture("committed-child-source", after: true); defer { source.remove() }
        let target = try Fixture("committed-child-target"); defer { target.remove() }
        let importer = try SyncAtomicImport(manager: target.manager)
        let data = try source.snapshot(); let preview = try importer.preview(data, memoryScope: source.scope)
        let result = try importer.confirm(preview, snapshot: data, confirmation: .init(preview: preview))
        #expect(result.committed && result.reopenRequired)
        try runRecoveryChild(target: target, importer: importer, phase: "COMMITTED", expected: Self.fileStates(under: target.root), title: "after")
    }

    @Test(arguments: ["bytes", "mode", "absence", "journal"])
    func newProcessRejectsCommittedTamperingWithoutOpeningStores(kind: String) throws {
        let source = try Fixture("tamper-child-source", after: true); defer { source.remove() }
        let target = try Fixture("tamper-child-target"); defer { target.remove() }
        let importer = try SyncAtomicImport(manager: target.manager)
        let data = try source.snapshot(); let preview = try importer.preview(data, memoryScope: source.scope)
        let result = try importer.confirm(preview, snapshot: data, confirmation: .init(preview: preview))
        let session = target.manager.sessionStore.directory.appendingPathComponent("sessions/f05-session.json")
        if kind == "bytes" { var bytes = try Data(contentsOf: session); bytes.append(0x20); try bytes.write(to: session) }
        else if kind == "mode" { try #require(chmod(session.path, 0o400) == 0) }
        else if kind == "absence" { try FileManager.default.removeItem(at: session) }
        else {
            var envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: result.journalURL)) as? [String: Any])
            envelope["hash"] = String(repeating: "0", count: 64)
            try JSONSerialization.data(withJSONObject: envelope, options: .sortedKeys).write(to: result.journalURL)
        }
        try runRecoveryChild(target: target, importer: importer, phase: "COMMITTED", expected: Self.fileStates(under: target.root),
                             title: "after", rejection: kind == "journal" ? "invalidJournal" : "stalePreview")
    }

    @Test(arguments: ["PREPARED:1", "PREPARED:2", "COMMITTING:1", "COMMITTING:2", "COMMITTED:1", "ROLLED_BACK:1", "rollbackJournal:1"])
    func journalDurabilityFailuresPreserveBytesAndRequiredFence(boundary: String) throws {
        let source = try Fixture("journal-fault-source", after: true); defer { source.remove() }
        let target = try Fixture("journal-fault-target"); defer { target.remove() }
        let before = try Self.fileStates(under: target.root)
        let pieces = boundary.split(separator: ":"); let phase = String(pieces[0]); let occurrence = try #require(Int(pieces[1]))
        let calls = Box(0); let fired = Box(false)
        let rollbackBoundary = phase == "ROLLED_BACK" || phase == "rollbackJournal"
        let importer = try SyncAtomicImport(manager: target.manager, fault: { point, value in
            if rollbackBoundary && point == .afterFile { throw Injected.failure }
            if (phase == "rollbackJournal" && point == .rollbackJournal) || (point == .journalFsync && value == phase) {
                calls.value += 1
                if calls.value == occurrence { fired.value = true; throw Injected.failure }
            }
        })
        let data = try source.snapshot(); let preview = try importer.preview(data, memoryScope: source.scope)
        if rollbackBoundary {
            #expect(throws: SyncAtomicImportError.rollbackIncomplete) { try importer.confirm(preview, snapshot: data, confirmation: .init(preview: preview)) }
        } else {
            #expect(throws: Injected.self) { try importer.confirm(preview, snapshot: data, confirmation: .init(preview: preview)) }
        }
        #expect(fired.value)
        #expect(try Self.fileStates(under: target.root) == before)
        if rollbackBoundary {
            #expect(throws: PersistenceTransactionError.recoveryRequired) { try target.manager.sessionStore.createSession(id: "late", title: "blocked") }
            try runRecoveryChild(target: target, importer: importer, phase: "COMMITTING", expected: before, title: "before")
        } else {
            _ = try target.manager.sessionStore.createSession(id: "after-journal-fault", title: "writer reopened")
        }
    }
}
