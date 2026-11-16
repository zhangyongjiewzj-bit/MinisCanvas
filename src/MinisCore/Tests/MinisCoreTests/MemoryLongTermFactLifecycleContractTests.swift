import Foundation
import Testing
@testable import MinisCore

/// D-MEMORY-05 / F04 MinisCore memory-domain contract.
///
/// Requirement authority:
///   issues/三期初期合拢-App逐项功能验收清单-20260826.md:304
///   `MEMORY-05` 可以新增、编辑和删除长期记忆。
/// Defect authority: F04 「记忆非空创建被当空输入拒绝」 (P1), whose L06 evidence
/// shows a non-empty text field answered with an empty-input rejection.
///
/// Scope discipline: this file only pins the **MinisCore** side of the contract,
/// i.e. what the memory settings surface may rely on. It deliberately does not
/// reimplement the settings-UI wiring (owned by the blocked settings lane) and it
/// does not re-pin `MemoryStore` byte stability, which sibling lane 017 already
/// asserts in `SessionDeletionScopeIsolationTests` (memory facts must survive a
/// session deletion).
///
/// Every case uses the production write path
/// (`MemoryProposalConsumer.submit` + `approve`/`approveRevision`), never
/// `MemoryStore.addFact`, because the settings surface writes through the
/// consumer and the consumer is the only admitted writer of facts.
struct MemoryLongTermFactLifecycleContractTests {

    /// Unique temp directory per case; tests run in parallel, paths never shared.
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MinisCore-MemoryLifecycleContract-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func scope(session: String = "session-f04", project: String = "project-f04") -> MemoryScope {
        MemoryScope(sessionID: session, projectID: project)
    }

    /// All new candidates must identify an explicitly authorized producer.
    private static let fixtureSourceID = "memory-lifecycle-contract-tests"

    private func makeConsumer(store: MemoryStore) throws -> MemoryProposalConsumer {
        let consumer = MemoryProposalConsumer(store: store)
        _ = try consumer.grantCandidateSubmission(
            sourceID: Self.fixtureSourceID,
            reason: "lifecycle contract test fixture explicit grant"
        )
        return consumer
    }

    /// The verbatim non-empty payload from the F04 field evidence.
    private static let fieldFixture = "合成记忆 TEST-52C-02：测试盒子的颜色是蓝色。"

    // MARK: - Create

    /// F04 core guarantee: a non-empty payload can never be rejected as empty by
    /// the memory domain, and the smallest possible non-empty payload still wins.
    @Test func nonEmptyContentIsCreatedThroughProductionWritePath() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        let consumer = try makeConsumer(store: store)
        let current = scope()

        for payload in [Self.fieldFixture, "蓝", "a"] {
            _ = try consumer.submit(
                text: payload,
                within: current,
                sourceID: Self.fixtureSourceID
            )
            _ = try consumer.approve(
                proposalID: try #require(
                    consumer.envelopes().last?.proposal.proposalID
                ),
                within: current,
                reason: "用户明确批准"
            )
        }

        // Order is intentionally not asserted: three facts created in the same
        // instant are tie-broken by a UUID fact id. Content is what must survive.
        let active = try store.activeFacts()
        #expect(Set(active.map(\.text)) == [Self.fieldFixture, "蓝", "a"])
        // The full-width colon, latin, digits and CJK must survive byte-for-byte.
        #expect(active.contains { $0.text == Self.fieldFixture })
        #expect(try store.facts().count == 3)
    }

    /// The empty-input rejection exists, is its own error, and writes nothing, so
    /// an "empty" message can only ever be produced by genuinely blank content.
    @Test func blankContentFailsClosedWithItsOwnDistinctErrorAndNoWrite() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        let consumer = try makeConsumer(store: store)
        let current = scope()

        for blank in ["", "   ", "\n\t ", "\u{00a0}\u{3000}"] {
            #expect(throws: MemoryProposalConsumerError.invalidText) {
                _ = try consumer.submit(
                    text: blank,
                    within: current,
                    sourceID: Self.fixtureSourceID
                )
            }
        }
        #expect(try store.facts().isEmpty)
        #expect(try consumer.envelopes().isEmpty)

        // A scope problem is reported as a scope problem, never as blank content.
        // This is the discrimination F04 lost when one message covered both cases.
        #expect(throws: MemoryProposalConsumerError.invalidMemoryScope) {
            _ = try consumer.submit(
                text: Self.fieldFixture,
                within: MemoryScope(sessionID: "  ", projectID: "project-f04"),
                sourceID: Self.fixtureSourceID
            )
        }
        #expect(try store.facts().isEmpty)
    }

    // MARK: - Edit

    /// Editing appends a revision: exactly one fact stays visible, the superseded
    /// record remains in the audit read only.
    ///
    /// This is the read-model contract the settings list must bind to: `facts()`
    /// intentionally keeps superseded rows, so a list bound to `facts()` shows a
    /// stale duplicate after every edit. Pinning it here so the blocked settings
    /// lane can consume the contract instead of rediscovering it.
    @Test func editingSupersedesExactlyOneActiveFact() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        let consumer = try makeConsumer(store: store)
        let current = scope()

        _ = try consumer.submit(
            text: Self.fieldFixture,
            within: current,
            sourceID: Self.fixtureSourceID
        )
        let createdID = try #require(consumer.envelopes().last?.proposal.proposalID)
        _ = try consumer.approve(
            proposalID: createdID,
            within: current,
            reason: "用户明确批准"
        )
        let original = try #require(try store.activeFacts().first)

        _ = try consumer.submit(
            proposalID: "proposal-edit",
            text: "测试盒子的颜色是绿色。",
            within: current,
            sourceID: Self.fixtureSourceID
        )
        _ = try consumer.approveRevision(
            proposalID: "proposal-edit",
            supersedingFactID: original.id,
            within: current,
            reason: "用户编辑记忆"
        )

        let active = try store.activeFacts()
        #expect(active.count == 1)
        #expect(active.first?.text == "测试盒子的颜色是绿色。")
        #expect(active.first?.revision == 2)
        #expect(active.first?.supersedesFactID == original.id)

        // Audit read keeps both; the visible projection keeps only the new one.
        let audit = try store.facts()
        #expect(audit.count == 2)
        #expect(audit.filter { $0.lifecycleState == .superseded }.map(\.id) == [original.id])

        // Retrieval answers with the current text only.
        #expect(try MemorySearch(store: store).search(keyword: "盒子").map(\.id)
                    == [try #require(active.first).id])
        #expect(try MemorySearch(store: store).search(keyword: "蓝色").isEmpty)
    }

    // MARK: - Delete

    /// Deleting removes the record from both the audit read and the visible
    /// projection, and a stale second delete stays a no-op instead of throwing.
    @Test func deletionRemovesFactFromEveryMemoryProjection() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = MemoryStore(directory: dir)
        let consumer = try makeConsumer(store: store)
        let current = scope()

        _ = try consumer.submit(
            text: Self.fieldFixture,
            within: current,
            sourceID: Self.fixtureSourceID
        )
        let proposalID = try #require(consumer.envelopes().last?.proposal.proposalID)
        _ = try consumer.approve(proposalID: proposalID, within: current, reason: "用户明确批准")
        let created = try #require(try store.activeFacts().first)

        // The settings delete journey previews first and re-supplies what it saw.
        // A preview that no longer matches must refuse to mutate anything.
        #expect(throws: MemoryStoreError.concurrentMutation) {
            _ = try store.removeFactForRollback(
                id: created.id,
                expectedRevision: created.revision + 1,
                expectedFingerprint: "stale-preview-fingerprint"
            )
        }
        #expect(try store.facts().map(\.id) == [created.id])

        try store.removeFact(id: created.id)
        #expect(try store.facts().isEmpty)
        #expect(try store.activeFacts().isEmpty)
        #expect(try MemorySearch(store: store).search(keyword: "盒子").isEmpty)

        try store.removeFact(id: created.id)
        #expect(try store.facts().isEmpty)
    }

    // MARK: - Restart

    /// The whole create → edit → delete journey is durable: a fresh store
    /// instance over the same directory reproduces the same projections, which is
    /// what the settings tab reloads after the App restarts.
    @Test func lifecycleProjectionsSurviveAFreshStoreInstance() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let current = scope()
        let survivorID: String
        let removedID: String

        do {
            let store = MemoryStore(directory: dir)
            let consumer = try makeConsumer(store: store)

            _ = try consumer.submit(
                text: Self.fieldFixture,
                within: current,
                sourceID: Self.fixtureSourceID
            )
            let firstID = try #require(consumer.envelopes().last?.proposal.proposalID)
            _ = try consumer.approve(proposalID: firstID, within: current, reason: "用户明确批准")
            removedID = try #require(try store.activeFacts().first).id

            _ = try consumer.submit(
                proposalID: "proposal-restart-edit",
                text: "重启后仍然有效的记忆。",
                within: current,
                sourceID: Self.fixtureSourceID
            )
            _ = try consumer.approveRevision(
                proposalID: "proposal-restart-edit",
                supersedingFactID: removedID,
                within: current,
                reason: "用户编辑记忆"
            )
            survivorID = try #require(try store.activeFacts().first).id
        }

        let reopened = MemoryStore(directory: dir)
        #expect(try reopened.activeFacts().map(\.id) == [survivorID])
        #expect(try reopened.facts().map(\.id).sorted() == [removedID, survivorID].sorted())

        try reopened.removeFact(id: survivorID)
        let reopenedAgain = MemoryStore(directory: dir)
        #expect(try reopenedAgain.activeFacts().isEmpty)
        #expect(try reopenedAgain.facts().allSatisfy { $0.id == removedID })
    }
}
