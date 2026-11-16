import Foundation
import Testing
@testable import MinisCore

// P3-H5 fixed bilingual (Chinese + English) local retrieval evaluation.
//
// Canonical 总表:313 `INTERFACE_OR_TEST_ONLY`: the lexical/CJK/provenance
// retrieval code already exists (MemorySearch.swift), but a fixed
// Chinese/English evaluation set with expected hits, ranking-stability
// replay, scope-leakage negative cases, and visible explanations was
// missing at blessed head. This file is a pure-local fixture evaluation:
// no network access, no external model calls, deterministic timestamps.

/// Unique temp directory per test (tests run in parallel; never share paths).
private func makeEvaluationTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MinisCore-H5RetrievalEval-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// One row of the fixed evaluation query set: a query plus the exact,
/// ordered fact ids it must return from `MemorySearch.searchHits`.
private struct FixedQueryCase {
    let query: String
    let language: String
    let expectedFactIDs: [String]
}

private struct H5EvalFixture {
    let directory: URL
    let store: MemoryStore
    let scopeA: MemoryScope
    let scopeB: MemoryScope
    let userID: String

    func cleanedUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Builds the fixed corpus once per test. Every fact carries a frozen
/// timestamp so the expected order below is deterministic: `searchHits`
/// sorts by matched-term count, then newest-first with revision and
/// fact-id tie-breakers (MemorySearch.swift newestFirst).
private func makeH5Fixture(insertionOrder: [Int]? = nil) throws -> H5EvalFixture {
    let dir = try makeEvaluationTempDir()
    let store = MemoryStore(directory: dir)
    let scopeA = MemoryScope(sessionID: "h5-session-a", projectID: "h5-project-a")
    let scopeB = MemoryScope(sessionID: "h5-session-b", projectID: "h5-project-b")
    let userID = "h5-user-1"
    let epoch = 1_700_000_000.0
    var insertions: [() throws -> Void] = []

    func minutes(_ m: Int) -> Date { Date(timeIntervalSince1970: epoch + Double(m * 60)) }

    func insertProvenanced(
        id: String,
        text: String,
        category: MemoryCategory,
        createdAt: Date,
        scope: MemoryScope?,
        ownerUserID: String? = nil
    ) throws {
        insertions.append {
            _ = try store.addFact(
                id: id,
                text: text,
                sourceSessionID: scope?.sessionID ?? "",
                category: category,
                createdAt: createdAt,
                memoryScope: scope,
                ownerUserID: ownerUserID,
                sourceProposalID: "proposal-\(id)",
                sourceRef: "chat://h5-eval/\(id)",
                contentDigest: MemoryStore.contentDigest(for: text)
            )
        }
    }

    // Paired at the same timestamp on purpose: with equal createdAt and
    // equal revision the contract falls back to ascending fact id.
    try insertProvenanced(
        id: "h5-t1", text: "Test trail log 测试轨迹一",
        category: .lesson, createdAt: minutes(10), scope: scopeA
    )
    try insertProvenanced(
        id: "h5-t2", text: "Automated test suite snapshot",
        category: .lesson, createdAt: minutes(10), scope: scopeA
    )
    try insertProvenanced(
        id: "h5-a1", text: "用户喜欢晴天散步",
        category: .userPref, createdAt: minutes(9), scope: scopeA
    )
    try insertProvenanced(
        id: "h5-a2", text: "User prefers sunny walks",
        category: .userPref, createdAt: minutes(8), scope: scopeA
    )
    try insertProvenanced(
        id: "h5-a3", text: "经验：先写测试再发布",
        category: .lesson, createdAt: minutes(7), scope: scopeA
    )
    try insertProvenanced(
        id: "h5-a4", text: "Lesson: test before release",
        category: .lesson, createdAt: minutes(6), scope: scopeA
    )
    try insertProvenanced(
        id: "h5-a5", text: "安全：不要明文存密码",
        category: .security, createdAt: minutes(5), scope: scopeA
    )
    try insertProvenanced(
        id: "h5-b1", text: "其他项目的晴天记录",
        category: .fact, createdAt: minutes(4), scope: scopeB
    )
    try insertProvenanced(
        id: "h5-b2", text: "Other project sunny notes",
        category: .fact, createdAt: minutes(3), scope: scopeB
    )
    try insertProvenanced(
        id: "h5-u1", text: "用户偏好：晴天出行清单",
        category: .userPref, createdAt: minutes(2), scope: scopeB, ownerUserID: userID
    )
    // Legacy global fact: no scope, no provenance triplet.
    insertions.append {
        _ = try store.addFact(
            id: "h5-g1",
            text: "legacy global sunny note",
            category: .fact,
            createdAt: minutes(1)
        )
    }
    // Default order is unchanged for all original evaluation cases. New cases
    // permute actual addFact writes; no sorted expected input is preloaded.
    let order = insertionOrder ?? Array(insertions.indices)
    try #require(order.count == insertions.count && Set(order) == Set(insertions.indices))
    for index in order { try insertions[index]() }

    return H5EvalFixture(
        directory: dir, store: store, scopeA: scopeA, scopeB: scopeB, userID: userID
    )
}

/// The fixed Chinese + English query set with expected hit membership and
/// ranking for the corpus above (unscoped product retrieval view).
private let fixedBilingualQueryCases: [FixedQueryCase] = [
    FixedQueryCase(query: "晴天", language: "zh", expectedFactIDs: ["h5-a1", "h5-b1", "h5-u1"]),
    FixedQueryCase(query: "晴", language: "zh", expectedFactIDs: ["h5-a1", "h5-b1", "h5-u1"]),
    FixedQueryCase(query: "测试", language: "zh", expectedFactIDs: ["h5-t1", "h5-a3"]),
    FixedQueryCase(query: "项目", language: "zh", expectedFactIDs: ["h5-b1"]),
    FixedQueryCase(query: "密码", language: "zh", expectedFactIDs: ["h5-a5"]),
    FixedQueryCase(query: "sunny", language: "en", expectedFactIDs: ["h5-a2", "h5-b2", "h5-g1"]),
    FixedQueryCase(query: "SUNNY", language: "en-case", expectedFactIDs: ["h5-a2", "h5-b2", "h5-g1"]),
    FixedQueryCase(query: "test", language: "en", expectedFactIDs: ["h5-t1", "h5-t2", "h5-a4"]),
    FixedQueryCase(query: "Test", language: "en-case", expectedFactIDs: ["h5-t1", "h5-t2", "h5-a4"]),
    FixedQueryCase(query: "walk", language: "en", expectedFactIDs: ["h5-a2"]),
]

struct LocalRetrievalEvaluationH5Tests {

    /// Equal-score/timestamp/revision IDs must be sorted by the production
    /// comparator even when the actual persisted insertion order disagrees.
    @Test(arguments: [
        [10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0],
        [6, 1, 9, 4, 10, 0, 8, 3, 7, 2, 5]
    ])
    func reversedAndShuffledWritesPreserveCompleteFixedHits974(insertionOrder: [Int]) throws {
        let original = try makeH5Fixture()
        let permuted = try makeH5Fixture(insertionOrder: insertionOrder)
        let search = MemorySearch(store: permuted.store)
        let facts = try permuted.store.facts()
        let originalInsertionIDs = ["h5-t1", "h5-t2", "h5-a1", "h5-a2", "h5-a3", "h5-a4", "h5-a5", "h5-b1", "h5-b2", "h5-u1", "h5-g1"]
        let persisted = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: permuted.store.fileURL)) as? [[String: Any]])
        let persistedIDs = try persisted.map { try #require($0["id"] as? String) }
        #expect(persistedIDs == insertionOrder.map { originalInsertionIDs[$0] })
        let t1Index = try #require(persistedIDs.firstIndex(of: "h5-t1"))
        let t2Index = try #require(persistedIDs.firstIndex(of: "h5-t2"))
        #expect(t2Index < t1Index) // Raw persisted order is opposite to ranked IDs.
        #expect(try facts == original.store.facts())
        #expect(try MemoryManager(store: permuted.store).overview(recentLimit: 20).recentFacts == facts)
        #expect(try permuted.store.searchFacts(keywords: ["test"]).map(\.id) == ["h5-t1", "h5-t2", "h5-a4"])
        let t1 = try #require(facts.first { $0.id == "h5-t1" })
        let t2 = try #require(facts.first { $0.id == "h5-t2" })
        #expect(t1.createdAt == t2.createdAt)
        #expect(t1.revision == t2.revision)
        for evalCase in fixedBilingualQueryCases {
            let expected = try MemorySearch(store: original.store).searchHits(keyword: evalCase.query)
            let hits = try search.searchHits(keyword: evalCase.query)
            #expect(!expected.isEmpty)
            #expect(expected.map(\.factID) == evalCase.expectedFactIDs)
            #expect(hits.map(\.factID) == evalCase.expectedFactIDs)
            #expect(hits == expected) // Every MemorySearchHit field, not only IDs.
            if evalCase.query.lowercased() == "test" {
                #expect(hits.prefix(2).map(\.factID) == ["h5-t1", "h5-t2"])
                let first = try #require(hits.first)
                let second = try #require(hits.dropFirst().first)
                #expect(first.score == second.score)
                #expect(first.revision == second.revision)
            }
            for _ in 0..<2 {
                let reopened = MemoryStore(directory: permuted.directory)
                #expect(try MemorySearch(store: reopened).searchHits(keyword: evalCase.query) == expected)
            }
        }
    }

    /// A zero-result denial alone could pass an always-empty implementation.
    /// The same fixed corpus must return its lawful exact/project/user set.
    @Test(arguments: fixedBilingualQueryCases.indices)
    func sameCorpusAuthorizedScopeAndZeroLeakageArePaired974(caseIndex: Int) throws {
        let evalCase = fixedBilingualQueryCases[caseIndex]
        let fixture = try makeH5Fixture()
        let search = MemorySearch(store: fixture.store)
        let aIDs: Set<String> = ["h5-t1", "h5-t2", "h5-a1", "h5-a2", "h5-a3", "h5-a4", "h5-a5"]
        let bIDs: Set<String> = ["h5-b1", "h5-b2", "h5-u1"]
        let expectedA = evalCase.expectedFactIDs.filter { aIDs.contains($0) }
        let expectedB = evalCase.expectedFactIDs.filter { bIDs.contains($0) }
        let expectedUser = evalCase.expectedFactIDs.filter { $0 == "h5-u1" }
        // Each query has at least one lawful scoped match in this same corpus.
        #expect(!expectedA.isEmpty || !expectedB.isEmpty)
        let projectA = try search.searchHits(keyword: evalCase.query, scope: .project(projectID: fixture.scopeA.projectID))
        let projectB = try search.searchHits(keyword: evalCase.query, scope: .project(projectID: fixture.scopeB.projectID))
        let sessionA = try search.searchHits(keyword: evalCase.query, scope: .session(fixture.scopeA))
        let sessionB = try search.searchHits(keyword: evalCase.query, scope: .session(fixture.scopeB))
        let user = try search.searchHits(keyword: evalCase.query, scope: .user(userID: fixture.userID))
        #expect(projectA.map(\.factID) == expectedA)
        #expect(projectB.map(\.factID) == expectedB)
        #expect(sessionA.map(\.factID) == expectedA)
        #expect(sessionB.map(\.factID) == expectedB)
        #expect(user.map(\.factID) == expectedUser)
        // Source session shared with the wrong project must not broaden scope.
        let mismatched = MemoryScope(sessionID: fixture.scopeA.sessionID, projectID: fixture.scopeB.projectID)
        #expect(try search.searchHits(keyword: evalCase.query, scope: .session(mismatched)).isEmpty)
        #expect(try search.searchHits(keyword: evalCase.query, scope: .project(projectID: "h5-project-missing")).isEmpty)
        #expect(try search.searchHits(keyword: evalCase.query, scope: .user(userID: "h5-user-missing")).isEmpty)
        let reopened = MemorySearch(store: MemoryStore(directory: fixture.directory))
        #expect(try reopened.searchHits(keyword: evalCase.query, scope: .project(projectID: fixture.scopeA.projectID)) == projectA)
        #expect(try reopened.searchHits(keyword: evalCase.query, scope: .project(projectID: fixture.scopeB.projectID)) == projectB)
        #expect(try reopened.searchHits(keyword: evalCase.query, scope: .session(fixture.scopeA)) == sessionA)
        #expect(try reopened.searchHits(keyword: evalCase.query, scope: .session(fixture.scopeB)) == sessionB)
        #expect(try reopened.searchHits(keyword: evalCase.query, scope: .user(userID: fixture.userID)) == user)
        for hit in projectA + projectB + user {
            #expect(hit.provenanceRedacted)
            #expect(hit.sourceProposalID == nil && hit.sourceRef == nil)
        }
        for hit in sessionA + sessionB {
            #expect(!hit.provenanceRedacted)
            #expect(hit.sourceProposalID == "proposal-\(hit.factID)")
            #expect(hit.sourceRef == "chat://h5-eval/\(hit.factID)")
        }
    }

    /// Fixed bilingual evaluation set: exact hit membership and ranking.
    @Test(arguments: fixedBilingualQueryCases.indices)
    func fixedBilingualQuerySetExpectedHitsAndRanking(caseIndex: Int) throws {
        let evalCase = fixedBilingualQueryCases[caseIndex]
        let fixture = try makeH5Fixture()
        defer { fixture.cleanedUp() }

        let hits = try MemorySearch(store: fixture.store).searchHits(keyword: evalCase.query)
        #expect(
            hits.map(\.factID) == evalCase.expectedFactIDs,
            "fixed \(evalCase.language) query \(evalCase.query) must return the exact ranked set"
        )
    }

    /// Ranking stability = 100%: replaying every fixed query on the same
    /// instance and on freshly reopened store instances returns byte-equal
    /// hit sequences (MemorySearchHit is Equatable).
    @Test(arguments: fixedBilingualQueryCases.indices)
    func rankingStabilityReplayIsHundredPercent(caseIndex: Int) throws {
        let evalCase = fixedBilingualQueryCases[caseIndex]
        let fixture = try makeH5Fixture()
        defer { fixture.cleanedUp() }

        let firstSearch = MemorySearch(store: fixture.store)
        let baseline = try firstSearch.searchHits(keyword: evalCase.query)
        #expect(baseline.map(\.factID) == evalCase.expectedFactIDs)

        // Same-input replays on the live instance.
        for _ in 0..<3 {
            let replay = try firstSearch.searchHits(keyword: evalCase.query)
            #expect(replay == baseline, "same-input replay diverged for \(evalCase.query)")
        }

        // Fresh store instances over the same persisted fixture.
        for _ in 0..<2 {
            let reopened = MemoryStore(directory: fixture.directory)
            let replay = try MemorySearch(store: reopened).searchHits(keyword: evalCase.query)
            #expect(replay == baseline, "reopened-instance replay diverged for \(evalCase.query)")
        }
    }

    /// Scope leakage = 0: for every fixed bilingual query, scoped reads
    /// never surface a fact owned by another project, another session, or
    /// a legacy global record.
    @Test(arguments: fixedBilingualQueryCases.indices)
    func scopedReadsHaveZeroLeakageForEveryFixedQuery(caseIndex: Int) throws {
        let evalCase = fixedBilingualQueryCases[caseIndex]
        let fixture = try makeH5Fixture()
        defer { fixture.cleanedUp() }

        let search = MemorySearch(store: fixture.store)
        let scopeAOnlyIDs: Set = ["h5-t1", "h5-t2", "h5-a1", "h5-a2", "h5-a3", "h5-a4", "h5-a5"]
        let foreignIDs: Set = ["h5-b1", "h5-b2", "h5-u1", "h5-g1"]

        let projectHits = try search.searchHits(
            keyword: evalCase.query, scope: .project(projectID: fixture.scopeA.projectID)
        )
        #expect(Set(projectHits.map(\.factID)).isSubset(of: scopeAOnlyIDs))
        #expect(Set(projectHits.map(\.factID)).isDisjoint(with: foreignIDs))

        let sessionHits = try search.searchHits(
            keyword: evalCase.query, scope: .session(fixture.scopeA)
        )
        #expect(sessionHits.map(\.factID) == projectHits.map(\.factID))
        #expect(Set(sessionHits.map(\.factID)).isDisjoint(with: foreignIDs))

        let userHits = try search.searchHits(
            keyword: evalCase.query, scope: .user(userID: fixture.userID)
        )
        #expect(Set(userHits.map(\.factID)).isDisjoint(with: scopeAOnlyIDs))
        #expect(Set(userHits.map(\.factID)).isSubset(of: ["h5-u1"]))

        // Unknown project and invalid session scope fail closed to empty.
        #expect(try search.searchHits(
            keyword: evalCase.query, scope: .project(projectID: "h5-project-missing")
        ).isEmpty)
        #expect(try search.searchHits(
            keyword: evalCase.query,
            scope: .session(MemoryScope(sessionID: "", projectID: fixture.scopeA.projectID))
        ).isEmpty)
    }

    /// Visible explanations: every fixed-query hit carries the retrieval
    /// method label, a score equal to its matched-term list, the
    /// lowercased needle as a visible term, and a source digest matching
    /// the stored fact. Redaction invariants hold per scope: full
    /// provenance for unscoped and exact-session reads, redacted
    /// proposal/ref identity for project and user reads.
    @Test(arguments: fixedBilingualQueryCases.indices)
    func fixedQueryHitsExposeStableExplanations(caseIndex: Int) throws {
        let evalCase = fixedBilingualQueryCases[caseIndex]
        let fixture = try makeH5Fixture()
        defer { fixture.cleanedUp() }

        let search = MemorySearch(store: fixture.store)
        let hits = try search.searchHits(keyword: evalCase.query)
        let facts = try fixture.store.facts()
        let expectedNeedle = evalCase.query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        for hit in hits {
            #expect(hit.retrievalMethod == MemorySearch.lexicalRetrievalMethod)
            #expect(hit.score == hit.matchedTerms.count)
            #expect(hit.score >= 1)
            #expect(hit.matchedTerms.contains(expectedNeedle))
            if let fact = facts.first(where: { $0.id == hit.factID }) {
                #expect(hit.sourceDigest == fact.contentDigest)
                #expect(hit.revision == fact.revision)
            } else {
                Issue.record("hit references unknown fact \(hit.factID)")
            }
        }

        // Unscoped reads keep full provenance (except the legacy fact,
        // which simply has none stored).
        for hit in hits where !hit.provenanceRedacted {
            #expect(hit.redactionSummary == "none")
        }
        if let a1Hit = hits.first(where: { $0.factID == "h5-a1" }) {
            #expect(a1Hit.sourceProposalID == "proposal-h5-a1")
            #expect(a1Hit.sourceRef == "chat://h5-eval/h5-a1")
            #expect(a1Hit.sourceDigest == MemoryStore.contentDigest(for: "用户喜欢晴天散步"))
        }

        // Project-scoped reads redact proposal identity visibly.
        let projectHits = try search.searchHits(
            keyword: evalCase.query, scope: .project(projectID: fixture.scopeA.projectID)
        )
        for hit in projectHits {
            #expect(hit.provenanceRedacted)
            #expect(hit.sourceProposalID == nil)
            #expect(hit.sourceRef == nil)
            #expect(!hit.redactionSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }

        // Exact-session reads keep full provenance.
        let sessionHits = try search.searchHits(
            keyword: evalCase.query, scope: .session(fixture.scopeA)
        )
        for hit in sessionHits {
            #expect(!hit.provenanceRedacted)
            #expect(hit.redactionSummary == "none")
        }
    }

    /// The plain fact-level `search` projection stays consistent with the
    /// explanation projection for representative bilingual queries.
    @Test func factLevelSearchAgreesWithHitProjectionForBilingualQueries() throws {
        let fixture = try makeH5Fixture()
        defer { fixture.cleanedUp() }

        let search = MemorySearch(store: fixture.store)
        for query in ["晴天", "sunny", "test"] {
            let factIDs = try search.search(keyword: query).map(\.id)
            let hitIDs = try search.searchHits(keyword: query).map(\.factID)
            #expect(factIDs == hitIDs, "search/searchHits diverged for \(query)")
        }
    }
}
