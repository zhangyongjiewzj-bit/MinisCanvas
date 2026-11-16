import Foundation
import Testing
@testable import MinisCore

// NOTE: Run on the CLT-only toolchain with the documented flags (see
// threads/B1-fix.log):
//   swift test -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks \
//              -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks

/// Unique temp directory per test (tests run in parallel; never share paths).
private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MinisCore-MemoryStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private enum MemoryStoreRecoveryTestError: Error {
    case injected
}

struct MemoryStoreTests {

    // MARK: - Add / list

    @Test func addFactAndListNewestFirst() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        let first = try store.addFact("用户喜欢晴天", sourceSessionID: "s1")
        let second = try store.addFact("用户的项目叫 MinisCanvas", sourceSessionID: "s2")

        let facts = try store.facts()
        #expect(facts.count == 2)
        #expect(facts.first?.id == second.id) // newest first
        #expect(facts.last?.id == first.id)
        #expect(facts.first?.sourceSessionID == "s2")
    }

    @Test func addEmptyFactThrows() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        #expect(throws: MemoryStoreError.emptyFact) {
            try store.addFact("   \n ")
        }
        #expect(try store.facts().isEmpty)
    }

    // MARK: - Persistence

    @Test func factsPersistAcrossStoreInstances() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let writer = MemoryStore(directory: dir)
        let f1 = try writer.addFact("第一条记忆", sourceSessionID: "s1")
        let f2 = try writer.addFact("第二条记忆", sourceSessionID: "s1")

        // Fresh store instance reads from disk — proves real persistence.
        let reader = MemoryStore(directory: dir)
        let facts = try reader.facts()
        #expect(facts == [f2, f1])

        // File lives at <root>/memory/facts.json
        #expect(FileManager.default.fileExists(atPath: writer.fileURL.path))
        #expect(writer.fileURL.lastPathComponent == "facts.json")
    }

    @Test func scopedFactPersistsConcreteMemoryScope() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let scope = MemoryScope(sessionID: "session-1", projectID: "project-1")
        let writer = MemoryStore(directory: dir)
        let fact = try writer.addFact(
            "项目记忆",
            sourceSessionID: scope.sessionID,
            memoryScope: scope
        )

        let reader = MemoryStore(directory: dir)
        #expect(fact.memoryScope == scope)
        #expect(try reader.facts().first?.memoryScope == scope)
    }

    @Test func versionedRevisionSupersedesPreviousAndDefaultSearchReturnsActiveOnly() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let scope = MemoryScope(sessionID: "session-1", projectID: "project-1")
        let firstText = "用户喜欢晴天"
        let first = try MemoryStore(directory: dir).addFact(
            id: "memory-r1",
            text: firstText,
            sourceSessionID: scope.sessionID,
            memoryScope: scope,
            sourceProposalID: "proposal-r1",
            sourceRef: "chat://session-1/turn-1",
            contentDigest: MemoryStore.contentDigest(for: firstText)
        )
        let store = MemoryStore(directory: dir)
        let secondText = "用户喜欢晴天和跑步"
        let second = try store.appendRevision(
            to: first.id,
            text: secondText,
            sourceSessionID: scope.sessionID,
            memoryScope: scope,
            sourceProposalID: "proposal-r2",
            sourceRef: "chat://session-1/turn-2",
            contentDigest: MemoryStore.contentDigest(for: secondText)
        )

        #expect(second.revision == 2)
        #expect(second.supersedesFactID == first.id)
        #expect(second.lifecycleState == .active)
        #expect(try store.facts().count == 2)
        #expect(try store.activeFacts().map(\.id) == [second.id])
        #expect(try store.searchFacts(keyword: "晴天").map(\.id) == [second.id])
        #expect(try store.facts().first(where: { $0.id == first.id })?.lifecycleState == .superseded)
    }

    @Test func legacyFactPayloadDecodesAsActiveRevisionOneWithoutProvenance() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        try FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let legacy = """
        [{"id":"legacy-1","text":"旧格式记忆","sourceSessionID":"legacy","createdAt":0,"category":"fact"}]
        """
        try Data(legacy.utf8).write(to: store.fileURL)

        let fact = try #require(store.facts().first)
        #expect(fact.revision == 1)
        #expect(fact.lifecycleState == .active)
        #expect(fact.sourceProposalID == nil)
        #expect(fact.sourceRef == nil)
        #expect(fact.contentDigest == nil)
        #expect(fact.visibility == nil)
        #expect(fact.temporaryLifetimeID == nil)
        #expect(try store.activeFacts().map(\.id) == ["legacy-1"])
    }

    @Test func classifiedFactsPersistMetadataAndPersonalNeedsVerifiedPrincipal() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let scope = MemoryScope(sessionID: "session-a", projectID: "project-a")
        let store = MemoryStore(directory: dir)
        #expect(MemoryTrustedPrincipal.validated(userID: "local-user", by: { _ in true }) == nil)
        #expect(throws: MemoryVisibilityError.personalPrincipalUnavailable) {
            try store.addFact(
                "晴天 personal", memoryScope: scope, ownerUserID: "user-a",
                visibility: .personal
            )
        }
        let validatedPrincipal = MemoryTrustedPrincipal.validated(
            userID: "user-a", by: { $0 == "user-a" }
        )
        let principal = try #require(validatedPrincipal)
        let personal = try store.addFact(
            "晴天 personal", memoryScope: scope, ownerUserID: "user-a",
            visibility: .personal, trustedPrincipal: principal
        )
        let project = try store.addFact(
            "晴天 project", memoryScope: scope, visibility: .project
        )
        let temporary = try store.addFact(
            "晴天 temporary", memoryScope: scope, visibility: .temporary,
            temporaryLifetimeID: "lifetime-a"
        )
        let reloaded = try MemoryStore(directory: dir).facts()
        #expect(reloaded.first(where: { $0.id == personal.id })?.visibility == .personal)
        #expect(reloaded.first(where: { $0.id == personal.id })?.ownerUserID == "user-a")
        #expect(reloaded.first(where: { $0.id == project.id })?.visibility == .project)
        #expect(reloaded.first(where: { $0.id == temporary.id })?.temporaryLifetimeID == "lifetime-a")
        // Old broad selectors cannot reclassify new facts as legacy reads.
        #expect(try store.activeFacts(within: .project(projectID: scope.projectID)).isEmpty)
    }

    @Test func classifiedRevisionAndRestorePreserveBoundaries() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let scope = MemoryScope(sessionID: "session-a", projectID: "project-a")
        let store = MemoryStore(directory: dir)
        let validatedPrincipal = MemoryTrustedPrincipal.validated(
            userID: "user-a", by: { $0 == "user-a" }
        )
        let principal = try #require(validatedPrincipal)
        let first = try store.addFact(
            "晴天 personal", memoryScope: scope, ownerUserID: "user-a",
            visibility: .personal, trustedPrincipal: principal
        )
        let editedText = "晴天 personal 已编辑"
        #expect(throws: MemoryVisibilityError.personalPrincipalUnavailable) {
            try store.appendRevision(
                to: first.id, text: editedText, sourceProposalID: "proposal-2",
                sourceRef: "synthetic://turn-2",
                contentDigest: MemoryStore.contentDigest(for: editedText)
            )
        }
        let revised = try store.appendRevision(
            to: first.id, text: editedText, trustedPrincipal: principal,
            sourceProposalID: "proposal-2", sourceRef: "synthetic://turn-2",
            contentDigest: MemoryStore.contentDigest(for: editedText)
        )
        #expect(revised.visibility == .personal)
        #expect(revised.ownerUserID == first.ownerUserID)
        #expect(throws: MemoryVisibilityError.personalPrincipalUnavailable) {
            try store.restoreFacts([revised], within: scope, mode: .merge)
        }
        #expect(throws: MemoryVisibilityError.replaceUnavailable) {
            try store.restoreFacts([], within: scope, mode: .replace)
        }
        #expect(try store.activeFacts().map(\.id) == [revised.id])
    }

    @Test func temporaryRequiresExplicitLifetimeAndNeverInventsOne() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let scope = MemoryScope(sessionID: "session-a", projectID: "project-a")
        let store = MemoryStore(directory: dir)
        #expect(throws: MemoryVisibilityError.invalidMetadata) {
            try store.addFact("晴天 temporary", memoryScope: scope, visibility: .temporary)
        }
        #expect(throws: MemoryVisibilityError.invalidMetadata) {
            try store.addFact(
                "晴天 project", memoryScope: scope, visibility: .project,
                temporaryLifetimeID: "lifetime-a"
            )
        }
        #expect(try store.facts().isEmpty)
    }

    @Test func appendRevisionRejectsStaleGenerationAndCanonicalizesPredecessorID() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        let firstText = "原始事实"
        let first = try store.addFact(
            id: "memory-r1",
            text: firstText,
            sourceProposalID: "proposal-r1",
            sourceRef: "chat://turn-1",
            contentDigest: MemoryStore.contentDigest(for: firstText)
        )

        #expect(throws: MemoryStoreError.concurrentMutation) {
            try store.appendRevision(
                to: "  \(first.id)  ",
                text: "不应写入",
                sourceProposalID: "proposal-stale",
                sourceRef: "chat://turn-stale",
                contentDigest: MemoryStore.contentDigest(for: "不应写入"),
                expectedRevision: first.revision + 1,
                expectedFingerprint: "stale-preview"
            )
        }

        #expect(try store.facts() == [first])
    }

    @Test func rollbackAndTombstonePersistLifecycleReceiptsAndHideFactsFromSearch() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        let firstText = "回滚前的记忆"
        let first = try store.addFact(
            id: "memory-r1",
            text: firstText,
            sourceProposalID: "proposal-r1",
            sourceRef: "chat://turn-1",
            contentDigest: MemoryStore.contentDigest(for: firstText)
        )
        let secondText = "更新后的记忆"
        let second = try store.appendRevision(
            to: first.id,
            text: secondText,
            sourceProposalID: "proposal-r2",
            sourceRef: "chat://turn-2",
            contentDigest: MemoryStore.contentDigest(for: secondText)
        )

        let rollback = try store.rollbackFact(id: second.id, reason: "用户撤销更新")
        #expect(rollback.action == .rollback)
        #expect(try store.activeFacts().map(\.id) == [first.id])
        #expect(try store.facts().first(where: { $0.id == second.id })?.lifecycleState == .rolledBack)

        let tombstone = try store.tombstoneFact(id: first.id, reason: "用户删除记忆")
        #expect(tombstone.action == .tombstone)
        #expect(try store.activeFacts().isEmpty)
        #expect(try store.searchFacts(keyword: "记忆").isEmpty)
        #expect(try store.lifecycleReceipts().map(\.action) == [.rollback, .tombstone])
    }

    @Test func lifecycleReceiptWithUnknownFactFailsClosedAfterRestart() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        let fact = try store.addFact("必须绑定 receipt")
        _ = try store.tombstoneFact(id: fact.id, reason: "删除")

        var object = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: store.lifecycleReceiptURL)
            ) as? [[String: Any]]
        )
        object[0]["factID"] = "missing-fact"
        try JSONSerialization.data(withJSONObject: object).write(
            to: store.lifecycleReceiptURL,
            options: .atomic
        )

        let reopened = MemoryStore(directory: dir)
        #expect(throws: MemoryStoreError.unknownFact) {
            _ = try reopened.lifecycleReceipts()
        }
    }

    @Test func restartRecoveryPublishesTransactionProvenanceStatus() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let seed = MemoryStore(directory: dir)
        let fact = try seed.addFact("重启恢复应留下可审计状态")
        let interrupted = MemoryStore(
            directory: dir,
            lifecycleTransactionFaultInjector: { point in
                if point == .afterFactsPersisted {
                    throw MemoryStoreRecoveryTestError.injected
                }
            }
        )
        #expect(throws: MemoryStoreRecoveryTestError.injected) {
            try interrupted.tombstoneFact(id: fact.id, reason: "注入事务中断")
        }

        let restarted = MemoryStore(directory: dir)
        #expect(restarted.recoveryStatus == .clean)
        #expect(try restarted.facts().count == 1)
        guard case let .recovered(transactionID) = restarted.recoveryStatus else {
            Issue.record("restart recovery did not expose a recovered transaction")
            return
        }
        #expect(!transactionID.isEmpty)
        #expect(try restarted.activeFacts().isEmpty)
        #expect(try restarted.lifecycleReceipts().count == 1)
        #expect(
            FileManager.default.fileExists(atPath: restarted.lifecycleTransactionURL.path)
                == false
        )
    }

    @Test func malformedRestartTransactionPublishesBlockedStatus() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        try FileManager.default.createDirectory(
            at: store.lifecycleTransactionURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-a-lifecycle-transaction".utf8).write(
            to: store.lifecycleTransactionURL,
            options: .atomic
        )

        let restarted = MemoryStore(directory: dir)
        #expect(throws: MemoryStoreError.concurrentMutation) {
            _ = try restarted.facts()
        }
        #expect(restarted.recoveryStatus == .blocked)
        #expect(
            FileManager.default.fileExists(atPath: restarted.lifecycleTransactionURL.path)
                == true
        )
    }

    @Test func unreadableFactsFileBlocksWriteInsteadOfTreatingItAsEmpty() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        try FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original = Data("{\"not\":\"facts\"}".utf8)
        try original.write(to: store.fileURL)

        #expect(throws: DecodingError.self) {
            _ = try store.addFact("不应覆盖损坏文件")
        }
        #expect(try Data(contentsOf: store.fileURL) == original)
    }

    @Test func semanticallyCorruptFactsBlockStrictReadsAndExport() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        let duplicateFacts = [
            MemoryFact(id: "duplicate", text: "第一份"),
            MemoryFact(id: "duplicate", text: "第二份"),
        ]
        try FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(duplicateFacts).write(to: store.fileURL)
        let original = try Data(contentsOf: store.fileURL)

        #expect(throws: MemoryStoreError.conflictingFactID) {
            _ = try store.loadFacts()
        }
        #expect(throws: MemoryStoreError.conflictingFactID) {
            _ = try MemoryManager(store: store).export()
        }
        #expect(try Data(contentsOf: store.fileURL) == original)
    }

    @Test func deletionRollbackRestoresAnExactSnapshotThroughTheStoreBoundary() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        let fact = try store.addFact("待删除事实", sourceSessionID: "legacy")
        let rollback = try store.removeFactForRollback(id: fact.id)

        #expect(try store.facts().isEmpty)
        try store.rollback(rollback)
        #expect(try store.facts() == [fact])
    }

    @Test func deletionRollbackRejectsConcurrentMutationWithoutOverwriting() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        let deleted = try store.addFact("删除前快照")
        let rollback = try store.removeFactForRollback(id: deleted.id)
        _ = try store.addFact("并发新增")

        #expect(throws: MemoryStoreError.concurrentMutation) {
            try store.rollback(rollback)
        }

        #expect(try store.facts().map(\.text) == ["并发新增"])
        #expect(try store.facts().contains { $0.id == deleted.id } == false)
    }

    @Test func deletionRejectsStaleExpectedSnapshotBeforeMutation() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        let fact = try store.addFact("预览后已变化")

        #expect(throws: MemoryStoreError.concurrentMutation) {
            try store.removeFactForRollback(
                id: fact.id,
                expectedRevision: Int(clamping: Int64(fact.createdAt.timeIntervalSince1970.rounded(.down))),
                expectedFingerprint: "stale-preview"
            )
        }

        #expect(try store.facts() == [fact])
    }

    @Test func clearRollbackRestoresAllFactsAsOneAtomicSnapshot() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        let first = try store.addFact("第一条")
        let second = try store.addFact("第二条")
        let rollback = try store.removeAllFactsForRollback()

        #expect(rollback.affectedCount == 2)
        #expect(try store.facts().isEmpty)
        try store.rollback(rollback)
        #expect(try Set(store.facts()) == Set([first, second]))
    }

    @Test func factsReadDoesNotTurnCorruptFileIntoEmptyMemory() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        try FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{\"corrupt\":true}".utf8).write(to: store.fileURL)

        #expect(throws: DecodingError.self) {
            _ = try store.facts()
        }
    }

    @Test func damagedMemoryDirectoryDoesNotReadAsEmptyOrOverwriteExistingBytes() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        let damagedDirectory = store.fileURL.deletingLastPathComponent()
        let original = Data("memory directory is not a directory".utf8)
        try original.write(to: damagedDirectory, options: .atomic)

        // A broken parent path is persistence corruption, not a fresh empty
        // store. Reads and writes must fail closed without replacing it.
        #expect(throws: MemoryStoreError.concurrentMutation) {
            _ = try store.facts()
        }
        #expect(throws: MemoryStoreError.concurrentMutation) {
            _ = try store.addFact("不得覆盖损坏存储")
        }
        #expect(try Data(contentsOf: damagedDirectory) == original)
    }

    // MARK: - Search

    @Test func searchFactsMatchesKeywordCaseInsensitive() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        try store.addFact("User prefers Swift programming")
        try store.addFact("用户喜欢晴天")

        #expect(try store.searchFacts(keyword: "swift").count == 1)
        #expect(try store.searchFacts(keyword: "SWIFT").count == 1)
        #expect(try store.searchFacts(keyword: "晴天").count == 1)
        #expect(try store.searchFacts(keyword: "python").isEmpty)
    }

    @Test func searchFactsEmptyKeywordReturnsEmpty() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        try store.addFact("任意内容")
        #expect(try store.searchFacts(keyword: "").isEmpty)
        #expect(try store.searchFacts(keyword: "   ").isEmpty)
        #expect(try store.searchFacts(keywords: []).isEmpty)
    }

    @Test func searchFactsMultiKeywordRanksByHits() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        try store.addFact("用户喜欢晴天和跑步", sourceSessionID: "s1")
        try store.addFact("用户喜欢晴天", sourceSessionID: "s2")

        let hits = try store.searchFacts(keywords: ["晴天", "跑步"])
        #expect(hits.count == 2)
        #expect(hits.first?.text == "用户喜欢晴天和跑步") // 2 hits beats 1 hit
    }

    // MARK: - Remove

    @Test func removeFactDeletesIt() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        let keep = try store.addFact("要保留的")
        let drop = try store.addFact("要删除的")

        try store.removeFact(id: "  \(drop.id)  ")
        let facts = try store.facts()
        #expect(facts.map(\.id) == [keep.id])

        try store.removeFact(id: "missing") // no-op, no throw
        #expect(try store.facts().map(\.id) == [keep.id])
    }
}

// MARK: - MemoryInjector

struct MemoryInjectorTests {
    // Reanchors donor3201 at the current strict store boundary. No store
    // read/export is made permissive; only optional prompt recall degrades.
    @Test(arguments: ["corrupt-json", "facts-directory", "damaged-parent"])
    func localReadFailureKeepsAllPromptOverloadsAtBase(failure: String) throws {
        let dir = try makeTempDir()
        let memory = dir.appendingPathComponent("memory", isDirectory: true)
        let facts = memory.appendingPathComponent("facts.json")
        let badBytes = Data("not-json-586".utf8)
        if failure == "damaged-parent" {
            try badBytes.write(to: memory)
        } else {
            try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
            if failure == "facts-directory" {
                try FileManager.default.createDirectory(at: facts, withIntermediateDirectories: true)
            } else {
                try badBytes.write(to: facts)
            }
        }
        let store = MemoryStore(directory: dir)
        let injector = MemoryInjector(store: store)
        let scope = MemoryScope(sessionID: "session-586", projectID: "project-586")
        let base = "base 586 完整系统正文"
        #expect(throws: (any Error).self) { try store.loadFacts() }
        #expect(try injector.systemPrompt(base: base, userMessage: "晴天 Swift") == base)
        #expect(try injector.systemPrompt(base: base, userMessage: "晴天 Swift", sessionID: scope.sessionID) == base)
        #expect(try injector.systemPrompt(base: base, userMessage: "晴天 Swift", memoryScope: scope) == base)
        #expect(try injector.systemPrompt(base: base, userMessage: "晴天 Swift", scope: .session(scope)) == base)
        #expect(throws: (any Error).self) { try store.loadFacts() }
        if failure == "facts-directory" {
            let attributes = try FileManager.default.attributesOfItem(atPath: facts.path)
            #expect(attributes[.type] as? FileAttributeType == .typeDirectory)
            #expect(try FileManager.default.contentsOfDirectory(atPath: facts.path).isEmpty)
        } else {
            #expect(try Data(contentsOf: failure == "damaged-parent" ? memory : facts) == badBytes)
        }
    }

    @Test func recallDoesNotSwallowInvalidPersistedScope() throws {
        let dir = try makeTempDir()
        let store = MemoryStore(directory: dir)
        let scope = MemoryScope(sessionID: "session-586", projectID: "project-586")
        _ = try store.addFact("晴天 Swift", memoryScope: scope)
        var raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [[String: Any]])
        raw[0]["memoryScope"] = ["sessionID": "", "projectID": scope.projectID]
        let bytes = try JSONSerialization.data(withJSONObject: raw, options: .sortedKeys)
        try bytes.write(to: store.fileURL)
        let injector = MemoryInjector(store: store)
        #expect(throws: MemoryStoreError.invalidMemoryScope) {
            try injector.systemPrompt(base: "base", userMessage: "Swift")
        }
        #expect(throws: MemoryStoreError.invalidMemoryScope) {
            try injector.systemPrompt(base: "base", userMessage: "Swift", sessionID: scope.sessionID)
        }
        #expect(throws: MemoryStoreError.invalidMemoryScope) {
            try injector.systemPrompt(base: "base", userMessage: "Swift", memoryScope: scope)
        }
        #expect(throws: MemoryStoreError.invalidMemoryScope) {
            try injector.systemPrompt(base: "base", userMessage: "Swift", scope: .session(scope))
        }
        #expect(try Data(contentsOf: store.fileURL) == bytes)
    }

    @Test func recallDoesNotSwallowPersistenceAdmissionRejection() throws {
        let dir = try makeTempDir()
        let domain = PersistenceTransactionFence.Domain.memories(dir)
        let exclusive = try PersistenceTransactionFence.exclusive([domain], deadline: Date().addingTimeInterval(1))
        exclusive.finish(committed: true, recoveryRequired: false, before: nil)
        let injector = MemoryInjector(store: MemoryStore(directory: dir))
        let scope = MemoryScope(sessionID: "blocked-586", projectID: "project-586")
        #expect(throws: PersistenceTransactionError.reopenRequired) {
            try injector.systemPrompt(base: "base", userMessage: "Swift")
        }
        #expect(throws: PersistenceTransactionError.reopenRequired) {
            try injector.systemPrompt(base: "base", userMessage: "Swift", sessionID: scope.sessionID)
        }
        #expect(throws: PersistenceTransactionError.reopenRequired) {
            try injector.systemPrompt(base: "base", userMessage: "Swift", memoryScope: scope)
        }
        #expect(throws: PersistenceTransactionError.reopenRequired) {
            try injector.systemPrompt(base: "base", userMessage: "Swift", scope: .session(scope))
        }
    }


    @Test func injectorAppendsRelevantMemoryToSystemPrompt() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        try store.addFact("用户喜欢晴天，讨厌下雨天", sourceSessionID: "s1")
        let injector = MemoryInjector(store: store)

        let prompt = try injector.systemPrompt(base: "你是 Minis 助手。", userMessage: "今天天气是晴天吗？")
        #expect(prompt.contains("你是 Minis 助手。"))
        #expect(prompt.contains("用户喜欢晴天，讨厌下雨天"))
        #expect(prompt.contains("background context"))
    }

    @Test func injectorReturnsBaseWhenNothingMatches() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        try store.addFact("用户的项目叫 MinisCanvas")
        let injector = MemoryInjector(store: store)

        let base = "你是 Minis 助手。"
        #expect(try injector.systemPrompt(base: base, userMessage: "帮我订个披萨") == base)
    }

    @Test func injectorCapsNumberOfInjectedFacts() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        for i in 0..<6 {
            try store.addFact("记忆条目 \(i) 与晴天相关")
        }
        let injector = MemoryInjector(store: store, maxFacts: 3)

        let prompt = try injector.systemPrompt(base: "base", userMessage: "晴天")
        let occurrences = prompt.components(separatedBy: "- 记忆条目").count - 1
        #expect(occurrences == 3)
    }

    @Test func injectorTruncatesLongFacts() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        try store.addFact(String(repeating: "很长的事实内容", count: 50))
        let injector = MemoryInjector(store: store, maxFactLength: 20)

        let prompt = try injector.systemPrompt(base: "base", userMessage: "事实")
        #expect(prompt.contains("…"))
        #expect(!prompt.contains("很长的事实内容".replacingOccurrences(of: "很长的事实内容", with: "")))
    }

    @Test func injectorExtractsLatinAndCJKKeywords() {
        let latin = MemoryInjector.keywords(from: "I love Swift programming")
        #expect(latin.contains("love"))
        #expect(latin.contains("swift"))
        #expect(latin.contains("programming"))
        #expect(!latin.contains("i")) // single-char tokens are dropped

        let cjk = MemoryInjector.keywords(from: "今天天气很好")
        #expect(cjk.contains("今天天气很好")) // whole run kept
        #expect(cjk.contains("天气"))         // 2-char bigram extracted
        #expect(cjk.contains("很好"))
        #expect(!cjk.contains("今天天气很好啊"))
    }

    // MARK: M1 会话过滤（session filtering）

    @Test func sessionPromptInjectsOnlyMatchingSessionFacts() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        try store.addFact("用户喜欢晴天，讨厌下雨天", sourceSessionID: "s1")
        try store.addFact("用户喜欢晴天散步", sourceSessionID: "s2")
        let injector = MemoryInjector(store: store)

        let prompt = try injector.systemPrompt(
            base: "你是 Minis 助手。", userMessage: "今天天气是晴天吗？", sessionID: "s1"
        )
        #expect(prompt.contains("你是 Minis 助手。"))
        #expect(prompt.contains("用户喜欢晴天，讨厌下雨天"), "同会话事实应注入")
        #expect(!prompt.contains("用户喜欢晴天散步"), "跨会话事实绝不注入")
        #expect(prompt.contains("background context"))
    }

    @Test func sessionPromptExcludesCrossSessionFactsEvenOnKeywordMatch() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        try store.addFact("用户喜欢晴天，讨厌下雨天", sourceSessionID: "s2")
        let injector = MemoryInjector(store: store)

        let base = "你是 Minis 助手。"
        // s1 会话没有任何自己的事实：即使 s2 的事实命中关键词，也不得注入。
        #expect(try injector.systemPrompt(base: base, userMessage: "今天天气是晴天吗？", sessionID: "s1") == base)
    }

    @Test func sessionPromptReturnsBaseForUnknownOrEmptySession() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        try store.addFact("用户喜欢晴天", sourceSessionID: "s1")
        let injector = MemoryInjector(store: store)
        let base = "你是 Minis 助手。"

        #expect(try injector.systemPrompt(base: base, userMessage: "晴天", sessionID: "s-unknown") == base)
        #expect(try injector.systemPrompt(base: base, userMessage: "晴天", sessionID: "") == base)
    }

    @Test func sessionRelevantFactsOnlyFromMatchingSession() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        let own = try store.addFact("用户喜欢晴天散步", sourceSessionID: "s1")
        try store.addFact("用户喜欢晴天和跑步", sourceSessionID: "s2")
        let injector = MemoryInjector(store: store)

        let facts = try injector.relevantFacts(for: "晴天", in: "s1")
        #expect(facts.map(\.id) == [own.id])
    }

    @Test func legacyInjectorOverloadsExcludeAllScopedFacts() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        let firstScope = MemoryScope(sessionID: "s1", projectID: "p1")
        let secondScope = MemoryScope(sessionID: "s1", projectID: "p2")
        let scopedFirst = try store.addFact(
            "Scoped English Swift memory",
            sourceSessionID: firstScope.sessionID,
            memoryScope: firstScope
        )
        _ = try store.addFact(
            "Scoped Chinese 晴天 memory",
            sourceSessionID: secondScope.sessionID,
            memoryScope: secondScope
        )
        let legacy = try store.addFact(
            "Legacy English Swift memory",
            sourceSessionID: "s1"
        )
        let injector = MemoryInjector(store: store)

        #expect(
            try injector.relevantFacts(for: "Swift").map(\.id) == [legacy.id]
        )
        #expect(
            try injector.relevantFacts(for: "晴天", in: "s1").isEmpty
        )
        #expect(
            try injector.relevantFacts(for: "Swift", in: "s1").map(\.id) == [legacy.id]
        )
        #expect(scopedFirst.id != legacy.id)
    }

    @Test func explicitScopesRecallSameCorpusRejectedByLegacyOverloads974() throws {
        let dir = try makeTempDir()
        let store = MemoryStore(directory: dir)
        let firstScope = MemoryScope(sessionID: "s1", projectID: "p1")
        let secondScope = MemoryScope(sessionID: "s1", projectID: "p2")
        let own = try store.addFact(
            "Scoped English Swift memory", sourceSessionID: firstScope.sessionID,
            memoryScope: firstScope)
        let foreign = try store.addFact(
            "Scoped Chinese 晴天 memory", sourceSessionID: secondScope.sessionID,
            memoryScope: secondScope)
        let legacy = try store.addFact("Legacy English Swift memory", sourceSessionID: "s1")
        let injector = MemoryInjector(store: store)
        #expect(try injector.relevantFacts(for: "Swift").map(\.id) == [legacy.id])
        #expect(try injector.relevantFacts(for: "晴天", in: "s1").isEmpty)
        #expect(try injector.relevantFacts(for: "Swift", in: firstScope).map(\.id) == [own.id])
        #expect(try injector.relevantFacts(for: "晴天", in: secondScope).map(\.id) == [foreign.id])
        #expect(try injector.relevantFacts(for: "Swift", in: .session(firstScope)).map(\.id) == [own.id])
        #expect(try injector.relevantFacts(for: "晴天", in: .project(projectID: secondScope.projectID)).map(\.id) == [foreign.id])
        #expect(try injector.relevantFacts(for: "晴天", in: firstScope).isEmpty)
        #expect(try injector.relevantFacts(for: "Swift", in: secondScope).isEmpty)
        let ownPrompt = try injector.systemPrompt(base: "base", userMessage: "Swift", memoryScope: firstScope)
        #expect(ownPrompt.contains(own.text))
        #expect(!ownPrompt.contains(legacy.text) && !ownPrompt.contains(foreign.text))
        let foreignPrompt = try injector.systemPrompt(base: "base", userMessage: "晴天", scope: .session(secondScope))
        #expect(foreignPrompt.contains(foreign.text))
        #expect(!foreignPrompt.contains(own.text) && !foreignPrompt.contains(legacy.text))
        #expect(try injector.systemPrompt(base: "base", userMessage: "晴天", sessionID: "s1") == "base")
        let reopened = MemoryInjector(store: MemoryStore(directory: dir))
        #expect(try reopened.relevantFacts(for: "Swift", in: firstScope) == [own])
        #expect(try reopened.relevantFacts(for: "晴天", in: secondScope) == [foreign])
        #expect(try reopened.relevantFacts(for: "Swift").map(\.id) == [legacy.id])
        #expect(try reopened.relevantFacts(for: "晴天", in: "s1").isEmpty)
    }

    @Test func scopedPromptRequiresExactSessionAndProjectScope() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ownScope = MemoryScope(sessionID: "s1", projectID: "p1")
        let otherProject = MemoryScope(sessionID: "s1", projectID: "p2")
        let store = MemoryStore(directory: dir)
        let own = try store.addFact(
            "用户喜欢晴天",
            sourceSessionID: ownScope.sessionID,
            memoryScope: ownScope
        )
        try store.addFact(
            "另一个项目也提到晴天",
            sourceSessionID: otherProject.sessionID,
            memoryScope: otherProject
        )
        try store.addFact("旧无 scope 晴天事实", sourceSessionID: "s1")

        let injector = MemoryInjector(store: store)
        let facts = try injector.relevantFacts(for: "晴天", in: ownScope)
        #expect(facts.map(\.id) == [own.id])

        let prompt = try injector.systemPrompt(
            base: "base",
            userMessage: "晴天",
            memoryScope: ownScope
        )
        #expect(prompt.contains("用户喜欢晴天"))
        #expect(!prompt.contains("另一个项目"))
        #expect(!prompt.contains("旧无 scope"))
    }
}
