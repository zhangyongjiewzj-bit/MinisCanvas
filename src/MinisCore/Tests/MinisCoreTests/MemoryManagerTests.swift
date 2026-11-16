import Foundation
import Testing
@testable import MinisCore

/// Unique temp directory per test (tests run in parallel; never share paths).
private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MinisCore-MemoryManagerTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - MemoryManager

struct MemoryManagerTests {

    // MARK: Overview

    @Test func overviewReportsCountBytesAndCategories() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        try store.addFact("用户喜欢晴天", sourceSessionID: "s1", category: .userPref)
        try store.addFact("记住 API key 不要硬编码", sourceSessionID: "s2", category: .security)
        try store.addFact("普通事实一条", sourceSessionID: "s3") // default .fact

        let manager = MemoryManager(store: store)
        let overview = try manager.overview()

        #expect(overview.factCount == 3)
        #expect(overview.categoryCounts[.userPref] == 1)
        #expect(overview.categoryCounts[.security] == 1)
        #expect(overview.categoryCounts[.fact] == 1)
        #expect(overview.categoryCounts[.lesson] == nil)
        #expect(overview.textBytes > 0)
        #expect(overview.storageBytes > 0)
        #expect(overview.recentFacts.count == 3)
        #expect(overview.recentFacts.first?.text == "普通事实一条") // newest first
    }

    @Test func overviewEmptyStore() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let manager = MemoryManager(store: MemoryStore(directory: dir))
        let overview = try manager.overview()
        #expect(overview.factCount == 0)
        #expect(overview.recentFacts.isEmpty)
        #expect(overview.storageBytes == 0)
        #expect(overview.categoryCounts.isEmpty)
    }

    // MARK: Prune

    @Test func pruneKeepsNewestFacts() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        for i in 0..<5 {
            try store.addFact("事实 \(i)", sourceSessionID: "s")
        }

        let manager = MemoryManager(store: store)
        let removed = try manager.prune(maxFacts: 2)

        #expect(removed.count == 3)
        let remaining = try store.facts()
        #expect(remaining.count == 2)
        #expect(remaining.map(\.text) == ["事实 4", "事实 3"]) // newest kept
        #expect(!remaining.contains(where: { $0.text == "事实 0" }))
    }

    @Test func pruneWithNoOverageIsNoOp() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        try store.addFact("唯一事实")

        let manager = MemoryManager(store: store)
        #expect(try manager.prune(maxFacts: 10).isEmpty)
        #expect(try store.facts().count == 1)
    }

    @Test func pruneKeepNewestFalseKeepsOldest() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        for i in 0..<4 {
            try store.addFact("事实 \(i)", sourceSessionID: "s")
        }

        let manager = MemoryManager(store: store)
        let removed = try manager.prune(maxFacts: 2, keepNewest: false)

        #expect(removed.count == 2)
        #expect(try store.facts().map(\.text) == ["事实 1", "事实 0"]) // oldest kept
    }

    // MARK: Export / Import

    @Test func exportImportRoundTripsAcrossStores() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = MemoryStore(directory: dir.appendingPathComponent("src"))
        let scope = MemoryScope(sessionID: "s-1", projectID: "project-1")
        let f1 = try source.addFact(
            "用户喜欢晴天",
            sourceSessionID: "s1",
            category: .userPref,
            memoryScope: scope
        )
        let f2 = try source.addFact(
            "密码要存钥匙串",
            sourceSessionID: "s2",
            category: .security,
            memoryScope: scope
        )

        let manager = MemoryManager(store: source)
        let data = try manager.export()

        let target = MemoryStore(directory: dir.appendingPathComponent("dst"))
        let targetManager = MemoryManager(store: target)
        let imported = try targetManager.importJSON(data, within: scope)

        #expect(imported == 2)
        let facts = try target.facts()
        #expect(facts.count == 2)
        // id / createdAt / category / sourceSessionID all preserved.
        #expect(facts.contains(f1))
        #expect(facts.contains(f2))
    }

    @Test func importJSONDedupesById() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        let scope = MemoryScope(sessionID: "s-1", projectID: "project-1")
        let fact = try store.addFact(
            "已有的记忆",
            sourceSessionID: "s1",
            category: .lesson,
            memoryScope: scope
        )

        let manager = MemoryManager(store: store)
        let data = try manager.export()

        // Re-importing the same payload must not duplicate.
        #expect(try manager.importJSON(data, within: scope) == 0)
        #expect(try store.facts().count == 1)

        // Merging a payload with one new + one duplicate only adds the new one.
        let payload = try JSONEncoder().encode([fact, MemoryFact(text: "新记忆", sourceSessionID: "s2")])
        #expect(try manager.importJSON(payload, within: scope) == 1)
        #expect(try store.facts().count == 2)
    }

    @Test func importJSONSkipsEmptyTextFacts() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        let manager = MemoryManager(store: store)
        let payload = try JSONEncoder().encode([MemoryFact(text: "   "), MemoryFact(text: "有效记忆")])
        let scope = MemoryScope(sessionID: "s-1", projectID: "project-1")
        #expect(throws: MemoryProposalConsumerError.invalidText) {
            try manager.importJSON(payload, within: scope)
        }
        #expect(try store.facts().isEmpty)
    }

    @Test func importJSONRejectsCorruptFactsWithoutOverwriting() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        try FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original = Data("{\"corrupt\":true}".utf8)
        try original.write(to: store.fileURL)

        let manager = MemoryManager(store: store)
        let payload = try JSONEncoder().encode([MemoryFact(text: "不得覆盖")])
        let scope = MemoryScope(sessionID: "s-1", projectID: "project-1")
        #expect(throws: (any Error).self) {
            try manager.importJSON(payload, within: scope)
        }
        #expect(try Data(contentsOf: store.fileURL) == original)
    }
}

// MARK: - MemorySearch

/// Insert a fact preserving its `createdAt` (addFact always stamps `Date()`);
/// routes through `MemoryManager.importJSON`'s merge-and-write.
private func insertFact(_ store: MemoryStore, _ fact: MemoryFact) throws {
    let payload = try JSONEncoder().encode([fact])
    try MemoryManager(store: store).importJSON(
        payload,
        within: MemoryScope(sessionID: "search-session", projectID: "project-1")
    )
}

struct MemorySearchTests {

    @Test func searchFiltersByCategory() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        try store.addFact("用户偏好晴天的天气", sourceSessionID: "s1", category: .userPref)
        try store.addFact("安全提醒：不要明文存密码", sourceSessionID: "s2", category: .security)
        try store.addFact("经验：先写测试再写实现", sourceSessionID: "s3", category: .lesson)

        let search = MemorySearch(store: store)
        #expect(try search.search(categories: [.security]).map(\.text) == ["安全提醒：不要明文存密码"])
        #expect(try search.search(categories: [.userPref, .lesson]).count == 2)
        #expect(try search.search(categories: [.fact]).isEmpty)
    }

    @Test func searchCombinesCategoryKeywordAndTimeRange() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        let now = Date()
        let old = now.addingTimeInterval(-3_600) // 1 hour ago
        let older = now.addingTimeInterval(-86_400) // 1 day ago

        let recentPref = try store.addFact("用户喜欢咖啡", sourceSessionID: "s1", category: .userPref)
        // Same category + keyword but created an hour ago.
        let oldPref = MemoryFact(text: "用户喜欢咖啡", sourceSessionID: "s2", createdAt: old, category: .userPref)
        try insertFact(store, oldPref)
        try insertFact(store, MemoryFact(text: "用户喜欢茶", sourceSessionID: "s3", createdAt: older, category: .userPref))
        try store.addFact("安全：咖啡因限量", sourceSessionID: "s4", category: .security)

        let search = MemorySearch(store: store)

        // Category + keyword.
        let byCategoryAndKeyword = try search.search(categories: [.userPref], keyword: "咖啡")
        #expect(byCategoryAndKeyword.count == 2)

        // Category + keyword + time range (last 30 minutes) → only the newest.
        let from = now.addingTimeInterval(-1_800)
        let recent = try search.search(categories: [.userPref], keyword: "咖啡", from: from)
        #expect(recent.map(\.id) == [recentPref.id])

        // Time range excluding the newest (to: 30 min ago) → the 1-hour-old
        // coffee fact remains, the fresh one is filtered out.
        let noOlder = try search.search(categories: [.userPref], keyword: "咖啡", to: now.addingTimeInterval(-1_800))
        #expect(noOlder.map(\.id) == [oldPref.id])

        // No filters → everything, newest first (the security fact was added
        // last and carries the newest timestamp).
        #expect(try search.search().count == 4)
        #expect(try search.search().first?.text == "安全：咖啡因限量")
    }

    @Test func searchSingleCategoryConvenience() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        try store.addFact("教训：备份很重要", sourceSessionID: "s1", category: .lesson)
        try store.addFact("事实：今天是周一", sourceSessionID: "s2", category: .fact)

        let search = MemorySearch(store: store)
        #expect(try search.search(category: .lesson).count == 1)
        #expect(try search.search(category: .lesson, keyword: "备份").count == 1)
        #expect(try search.search(category: .lesson, keyword: "周一").isEmpty)
    }

    @Test func displayProjectionShowsSourceTimeAndRecallExplanation() throws {
        let dir = try makeTempDir()
        print("H5A1055 ownedFixture=\(dir.path)")

        let target = MemoryScope(sessionID: "display-session", projectID: "display-project")
        let other = MemoryScope(sessionID: "other-session", projectID: "other-project")
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let store = MemoryStore(directory: dir)
        _ = try store.addFact(
            id: "display-target",
            text: "Swift works with 晴天",
            createdAt: timestamp,
            memoryScope: target,
            sourceProposalID: "display-proposal",
            sourceRef: "chat://display-session/turn-1",
            contentDigest: MemoryStore.contentDigest(for: "Swift works with 晴天")
        )
        _ = try store.addFact(
            id: "display-other",
            text: "Swift works with 晴天",
            createdAt: timestamp,
            memoryScope: other,
            sourceProposalID: "other-proposal",
            sourceRef: "chat://other-session/turn-1",
            contentDigest: MemoryStore.contentDigest(for: "Swift works with 晴天")
        )

        let consumer = MemorySearchDisplayConsumer(search: MemorySearch(store: store))
        let sessionResult = try consumer.retrieve(
            keyword: "Swift, 晴天",
            scope: .session(target)
        )
        let item = try #require(sessionResult.items.first)
        #expect(sessionResult.items.map(\.factID) == ["display-target"])
        #expect(item.text == "Swift works with 晴天")
        #expect(item.createdAt == timestamp)
        #expect(item.createdAtLabel == "2023-11-14T22:13:20Z")
        #expect(item.sourceDescription == "chat://display-session/turn-1")
        #expect(item.sourceRef == "chat://display-session/turn-1")
        #expect(item.provenanceRedacted == false)
        #expect(item.recallExplanation.contains("命中 2 个检索词"))
        #expect(item.recallExplanation.contains("swift、晴天"))
        #expect(sessionResult.explanation.contains("稳定排序"))
        #expect(!sessionResult.explanation.contains("Persistent memory"))

        // The real display join must refuse an old hit paired with a newer
        // revision or a different content digest, even if the fact ID matches.
        let hit = try #require(MemorySearch(store: store).searchHits(
            keyword: "Swift, 晴天", scope: .session(target)
        ).first)
        let wrongRevision = MemoryFact(
            id: hit.factID,
            text: "Swift works with 晴天",
            createdAt: timestamp,
            memoryScope: target,
            sourceProposalID: "display-proposal",
            sourceRef: "chat://display-session/turn-1",
            contentDigest: hit.sourceDigest,
            revision: hit.revision + 1
        )
        #expect(throws: MemorySearchDisplayError.inconsistentFact(hit.factID)) {
            try MemorySearchDisplayConsumer.displayItems(hits: [hit], activeFacts: [wrongRevision])
        }
        let wrongDigest = MemoryFact(
            id: hit.factID,
            text: "changed text",
            createdAt: timestamp,
            memoryScope: target,
            sourceProposalID: "display-proposal",
            sourceRef: "chat://display-session/turn-1",
            contentDigest: MemoryStore.contentDigest(for: "changed text"),
            revision: hit.revision
        )
        #expect(throws: MemorySearchDisplayError.inconsistentFact(hit.factID)) {
            try MemorySearchDisplayConsumer.displayItems(hits: [hit], activeFacts: [wrongDigest])
        }

        let projectResult = try consumer.retrieve(
            keyword: "Swift, 晴天",
            scope: .project(projectID: target.projectID)
        )
        let projectItem = try #require(projectResult.items.first)
        #expect(projectItem.sourceDescription == "当前作用域（来源详情已隐藏）")
        #expect(projectItem.sourceRef == nil)
        #expect(projectItem.provenanceRedacted)

        let reopened = MemorySearchDisplayConsumer(
            search: MemorySearch(store: MemoryStore(directory: dir))
        )
        #expect(
            try reopened.retrieve(keyword: "Swift, 晴天", scope: .session(target))
                == sessionResult
        )

        let denied = try consumer.retrieve(
            keyword: "Swift",
            scope: .session(MemoryScope(sessionID: " ", projectID: target.projectID))
        )
        #expect(denied.isEmpty)
        #expect(denied.explanation.contains("检索已拒绝"))
    }

    @Test func searchHitsProjectStableProvenanceAndActiveOnlyAfterRestart() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let scope = MemoryScope(sessionID: "search-session", projectID: "project-1")
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let firstText = "用户喜欢晴天"
        let secondText = "用户喜欢晴天和跑步"
        let store = MemoryStore(directory: dir)
        _ = try store.addFact(
            id: "fact-a",
            text: firstText,
            createdAt: timestamp,
            memoryScope: scope,
            sourceProposalID: "proposal-a",
            sourceRef: "chat://search/turn-1",
            contentDigest: MemoryStore.contentDigest(for: firstText)
        )
        _ = try store.addFact(
            id: "fact-b",
            text: secondText,
            createdAt: timestamp,
            memoryScope: scope,
            sourceProposalID: "proposal-b",
            sourceRef: "chat://search/turn-2",
            contentDigest: MemoryStore.contentDigest(for: secondText)
        )

        let firstSearch = MemorySearch(store: store)
        let firstHits = try firstSearch.searchHits(keyword: "晴天")
        #expect(firstHits.map(\.factID) == ["fact-a", "fact-b"])
        #expect(firstHits.map(\.revision) == [1, 1])
        #expect(firstHits.map(\.score) == [1, 1])
        #expect(firstHits.map(\.retrievalMethod).allSatisfy {
            $0 == MemorySearch.lexicalRetrievalMethod
        })
        #expect(firstHits.first?.sourceProposalID == "proposal-a")
        #expect(firstHits.first?.sourceRef == "chat://search/turn-1")
        #expect(firstHits.first?.sourceDigest == MemoryStore.contentDigest(for: firstText))

        let reopened = MemoryStore(directory: dir)
        let reopenedHits = try MemorySearch(store: reopened).searchHits(keyword: "晴天")
        #expect(reopenedHits == firstHits)
    }

    @Test func mixedLanguageSearchUsesStableScoreAndTieBreakWithoutScopeLeakage() throws {
        let dir = try makeTempDir()
        print("H5B1017 ownedFixture=\(dir.path)")

        let scope = MemoryScope(sessionID: "stable-session", projectID: "project-1")
        let otherScope = MemoryScope(sessionID: "other-session", projectID: "project-2")
        let timestamp = Date(timeIntervalSince1970: 1_700_000_456)
        let store = MemoryStore(directory: dir)
        for id in ["fact-z", "fact-a"] {
            _ = try store.addFact(
                id: id,
                text: "晴天 Swift memory",
                createdAt: timestamp,
                memoryScope: scope,
                sourceProposalID: "proposal-\(id)",
                sourceRef: "chat://stable/\(id)",
                contentDigest: MemoryStore.contentDigest(for: "晴天 Swift memory")
            )
        }
        _ = try store.addFact(
            id: "fact-b",
            text: "晴天 only",
            createdAt: timestamp,
            memoryScope: scope,
            sourceProposalID: "proposal-fact-b",
            sourceRef: "chat://stable/fact-b",
            contentDigest: MemoryStore.contentDigest(for: "晴天 only")
        )
        _ = try store.addFact(
            id: "other-fact",
            text: "晴天 Swift memory",
            createdAt: timestamp.addingTimeInterval(100),
            memoryScope: otherScope,
            sourceProposalID: "proposal-other",
            sourceRef: "chat://other/fact",
            contentDigest: MemoryStore.contentDigest(for: "晴天 Swift memory")
        )

        let search = MemorySearch(store: store)
        let hits = try search.searchHits(keyword: "晴天, SWIFT", scope: .session(scope))
        #expect(hits.map(\.factID) == ["fact-a", "fact-z", "fact-b"])
        #expect(hits.map(\.score) == [2, 2, 1])
        #expect(hits.first?.matchedTerms == ["晴天", "swift"])
        #expect(hits.contains { $0.factID == "other-fact" } == false)

        let reopenedHits = try MemorySearch(store: MemoryStore(directory: dir))
            .searchHits(keyword: "晴天, SWIFT", scope: .session(scope))
        #expect(reopenedHits == hits)
        #expect(try search.searchHits(keyword: ", ;", scope: .session(scope)).isEmpty)
        #expect(try search.searchHits(keyword: "晴天", scope: .session(scope)).map(\.score) == [1, 1, 1])
    }

    @Test func searchHitsHideSupersededRollbackAndTombstoneFactsAfterRestart() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let scope = MemoryScope(sessionID: "lifecycle-search", projectID: "project-1")
        let firstText = "回滚前的晴天记忆"
        let secondText = "更新后的晴天记忆"
        let store = MemoryStore(directory: dir)
        let first = try store.addFact(
            id: "search-r1",
            text: firstText,
            createdAt: Date(timeIntervalSince1970: 1_700_000_001),
            memoryScope: scope,
            sourceProposalID: "search-proposal-r1",
            sourceRef: "chat://lifecycle/turn-1",
            contentDigest: MemoryStore.contentDigest(for: firstText)
        )
        let second = try store.appendRevision(
            to: first.id,
            id: "search-r2",
            text: secondText,
            memoryScope: scope,
            sourceProposalID: "search-proposal-r2",
            sourceRef: "chat://lifecycle/turn-2",
            contentDigest: MemoryStore.contentDigest(for: secondText),
            createdAt: Date(timeIntervalSince1970: 1_700_000_002)
        )

        #expect(try MemorySearch(store: store).searchHits(keyword: "晴天").map(\.factID) == [second.id])
        _ = try store.rollbackFact(id: second.id, reason: "撤销 revision")
        let afterRollback = MemoryStore(directory: dir)
        let rollbackHits = try MemorySearch(store: afterRollback).searchHits(keyword: "晴天")
        #expect(rollbackHits.map(\.factID) == [first.id])
        #expect(rollbackHits.first?.sourceDigest == first.contentDigest)

        _ = try afterRollback.tombstoneFact(id: first.id, reason: "删除记忆")
        let afterTombstone = MemoryStore(directory: dir)
        #expect(try MemorySearch(store: afterTombstone).searchHits(keyword: "晴天").isEmpty)
    }

    @Test func scopedSearchHasZeroCrossProjectLeakageAndRedactsProvenance() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = MemoryScope(sessionID: "target-session", projectID: "target-project")
        let other = MemoryScope(sessionID: "other-session", projectID: "other-project")
        let userID = "user-1"
        let targetText = "项目目标的晴天记忆"
        let otherText = "其他项目的晴天记忆"
        let userText = "用户偏好的晴天记忆"
        let store = MemoryStore(directory: dir)
        _ = try store.addFact(
            id: "target-fact",
            text: targetText,
            memoryScope: target,
            sourceProposalID: "target-proposal",
            sourceRef: "chat://target-session/turn-1",
            contentDigest: MemoryStore.contentDigest(for: targetText)
        )
        _ = try store.addFact(
            id: "other-fact",
            text: otherText,
            memoryScope: other,
            sourceProposalID: "other-proposal",
            sourceRef: "chat://other-session/turn-1",
            contentDigest: MemoryStore.contentDigest(for: otherText)
        )
        _ = try store.addFact(
            id: "user-fact",
            text: userText,
            memoryScope: other,
            ownerUserID: userID,
            sourceProposalID: "user-proposal",
            sourceRef: "chat://other-session/turn-2",
            contentDigest: MemoryStore.contentDigest(for: userText)
        )
        try store.addFact("legacy global 晴天记忆")

        let search = MemorySearch(store: store)
        let projectHits = try search.searchHits(
            keyword: "晴天",
            scope: .project(projectID: target.projectID)
        )
        #expect(projectHits.map(\.factID) == ["target-fact"])
        #expect(projectHits.first?.sourceDigest == MemoryStore.contentDigest(for: targetText))
        #expect(projectHits.first?.sourceProposalID == nil)
        #expect(projectHits.first?.sourceRef == nil)
        #expect(projectHits.first?.provenanceRedacted == true)
        #expect(projectHits.first?.redactionSummary.contains("redacted") == true)
        let serializedProjectHits = try JSONEncoder().encode(projectHits)
        let restoredProjectHits = try JSONDecoder().decode(
            [MemorySearchHit].self,
            from: serializedProjectHits
        )
        #expect(restoredProjectHits == projectHits)

        var unsupportedVersionObject = try #require(
            JSONSerialization.jsonObject(with: serializedProjectHits) as? [[String: Any]]
        )
        unsupportedVersionObject[0]["schemaVersion"] = 99
        let unsupportedVersionData = try JSONSerialization.data(
            withJSONObject: unsupportedVersionObject
        )
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(
                [MemorySearchHit].self,
                from: unsupportedVersionData
            )
        }

        let sessionHits = try search.searchHits(
            keyword: "晴天",
            scope: .session(target)
        )
        #expect(sessionHits.map(\.factID) == ["target-fact"])
        #expect(sessionHits.first?.sourceProposalID == "target-proposal")
        #expect(sessionHits.first?.sourceRef == "chat://target-session/turn-1")
        #expect(sessionHits.first?.provenanceRedacted == false)

        let userHits = try search.searchHits(
            keyword: "晴天",
            scope: .user(userID: userID)
        )
        #expect(userHits.map(\.factID) == ["user-fact"])
        #expect(userHits.first?.sourceProposalID == nil)
        #expect(userHits.first?.sourceRef == nil)
        #expect(userHits.first?.provenanceRedacted == true)

        #expect(
            try search.search(
                keyword: "晴天",
                scope: .project(projectID: "missing-project")
            ).isEmpty
        )
        #expect(
            try search.searchHits(
                keyword: "晴天",
                scope: .session(MemoryScope(sessionID: "", projectID: target.projectID))
            ).isEmpty
        )
    }

    @Test func legacyPayloadWithoutCategoryDecodesAsFact() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Hand-written old-format JSON: no `category` key.
        let store = MemoryStore(directory: dir)
        try FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let legacy = """
        [{"id":"legacy-1","text":"旧格式记忆","sourceSessionID":"s1","createdAt":1000}]
        """
        try Data(legacy.utf8).write(to: store.fileURL, options: .atomic)

        let facts = try store.facts()
        #expect(facts.count == 1)
        #expect(facts[0].id == "legacy-1")
        #expect(facts[0].category == .fact) // backward-compatible default
    }
}


private final class F05OverviewResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedOverview: MemoryOverview?
    private var storedError: Error?
    func set(overview: MemoryOverview) { lock.lock(); storedOverview = overview; lock.unlock() }
    func set(error: Error) { lock.lock(); storedError = error; lock.unlock() }
    var overview: MemoryOverview? { lock.lock(); defer { lock.unlock() }; return storedOverview }
    var error: Error? { lock.lock(); defer { lock.unlock() }; return storedError }
}

private struct F05OverviewRaceFacts: Sendable {
    let entered: Bool
    let importBlocked: Bool
    let readCompleted: Bool
    let importCompleted: Bool
    let noErrors: Bool
    let overview: MemoryOverview?
    let beforeBytes: Int
    let manager: MemoryManager
    let targetRoot: URL
}

extension MemoryManagerTests {
    @Test func f05OverviewRetainsOneAdmissionAcrossFactsAndFileMetadata() async throws {
        let root = try await runBlockingTestWork { try makeTempDir().resolvingSymlinksInPath() }
        defer { try? FileManager.default.removeItem(at: root) }
        let facts = try await runBlockingTestWork {
            let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
            let targetRoot = root.appendingPathComponent("target", isDirectory: true)
            func sync(_ directory: URL) -> SyncManager {
                SyncManager(sessionStore: SessionStore(directory: directory), memoryStore: MemoryStore(directory: directory),
                            skillStore: SkillStore(skillsRoot: directory.appendingPathComponent("skills", isDirectory: true)),
                            settingsStore: SettingsStore(directory: directory))
            }
            let source = sync(sourceRoot); let target = sync(targetRoot)
            let scope = MemoryScope(sessionID: "read-session", projectID: "read-project")
            _ = try source.memoryStore.addFact(String(repeating: "new", count: 200), sourceSessionID: scope.sessionID, memoryScope: scope)
            _ = try target.memoryStore.addFact("old", sourceSessionID: scope.sessionID, memoryScope: scope)
            let beforeBytes = try Data(contentsOf: target.memoryStore.fileURL).count
            let manager = MemoryManager(store: target.memoryStore)
            let readEntered = DispatchSemaphore(value: 0); let finishRead = DispatchSemaphore(value: 0)
            let readDone = DispatchSemaphore(value: 0); let importDone = DispatchSemaphore(value: 0)
            let readResult = F05OverviewResultBox(); let importResult = F05OverviewResultBox()
            manager.overviewReadObserver = {
                readEntered.signal()
                _ = finishRead.wait(timeout: .now() + 5)
            }
            let data = try source.exportSnapshot(scopes: [.memories])
            let importer = try SyncAtomicImport(manager: target)
            let preview = try importer.preview(data, selecting: [.memories], memoryScope: scope)
            DispatchQueue.global().async {
                do { readResult.set(overview: try manager.overview()) }
                catch { readResult.set(error: error) }
                readDone.signal()
            }
            let entered = readEntered.wait(timeout: .now() + 2) == .success
            DispatchQueue.global().async {
                do { _ = try importer.confirm(preview, snapshot: data, confirmation: .init(preview: preview)) }
                catch { importResult.set(error: error) }
                importDone.signal()
            }
            let importBlocked = importDone.wait(timeout: .now() + 0.1) == .timedOut
            finishRead.signal()
            let readCompleted = readDone.wait(timeout: .now() + 5) == .success
            let importCompleted = importDone.wait(timeout: .now() + 5) == .success
            let noErrors = readResult.error == nil && importResult.error == nil
            let overview = readResult.overview
            return F05OverviewRaceFacts(entered: entered, importBlocked: importBlocked,
                readCompleted: readCompleted, importCompleted: importCompleted, noErrors: noErrors,
                overview: overview, beforeBytes: beforeBytes, manager: manager, targetRoot: targetRoot)
        }
        #expect(facts.entered)
        #expect(facts.importBlocked)
        #expect(facts.readCompleted)
        #expect(facts.importCompleted)
        #expect(facts.noErrors)
        let overview = try #require(facts.overview)
        #expect(overview.recentFacts.map(\.text) == ["old"])
        #expect(overview.storageBytes == facts.beforeBytes)
        #expect(throws: PersistenceTransactionError.reopenRequired) { try facts.manager.overview() }
        #expect(throws: PersistenceTransactionError.reopenRequired) { try MemoryManager(store: MemoryStore(directory: facts.targetRoot)).overview() }
    }

    @Test func markdownExportIsReadableAndImportRemainsScoped() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let scope = MemoryScope(sessionID: "markdown-session", projectID: "markdown-project")
        let source = MemoryStore(directory: dir.appendingPathComponent("source"))
        _ = try source.addFact(
            id: "markdown-fact",
            text: "Markdown 可读记忆",
            sourceSessionID: scope.sessionID,
            category: .lesson,
            memoryScope: scope
        )
        let sourceManager = MemoryManager(store: source)
        let markdown = try sourceManager.exportMarkdownString()
        #expect(markdown.contains("## 经验教训"))
        #expect(markdown.contains("Markdown 可读记忆"))

        let target = MemoryStore(directory: dir.appendingPathComponent("target"))
        let targetManager = MemoryManager(store: target)
        #expect(try targetManager.importMarkdown(markdown, within: scope) == 1)
        #expect(try target.facts().first?.memoryScope == scope)
        #expect(try targetManager.importMarkdown(markdown, within: scope) == 0)
    }
}
