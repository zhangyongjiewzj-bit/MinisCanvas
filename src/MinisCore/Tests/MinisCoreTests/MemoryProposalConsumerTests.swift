import Foundation
import Testing
@testable import MinisCore

struct MemoryProposalConsumerTests {
    private static let fixtureSourceID = "memory-proposal-consumer-tests"

    private func grantedConsumer(directory: URL) throws -> MemoryProposalConsumer {
        let consumer = MemoryProposalConsumer(store: MemoryStore(directory: directory))
        _ = try consumer.grantCandidateSubmission(
            sourceID: Self.fixtureSourceID,
            reason: "proposal consumer test explicit candidate submission grant"
        )
        return consumer
    }

    @Test func knownCredentialPatternCannotBecomePendingMemory() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = MemoryScope(sessionID: "credential-fixture", projectID: "owned-project")
        let consumer = try grantedConsumer(directory: directory)
        let synthetic = "export OPENAI_KEY=sk-proj-ABCDEFGHIJKLMNOPQRST"
        try #require(ContentSecretRedactor.redact(synthetic) != synthetic)
        #expect(throws: MemoryProposalConsumerError.self) {
            _ = try consumer.submit(proposalID: "synthetic-key",
                text: synthetic, within: scope, sourceID: Self.fixtureSourceID)
        }
        #expect(try consumer.envelopes().isEmpty)
        #expect(try consumer.store.facts().isEmpty)
        let ordinary = try consumer.submit(proposalID: "ordinary-fact",
            text: "Prefer short headings", within: scope, sourceID: Self.fixtureSourceID)
        #expect(ordinary.state == .proposed)
        #expect(try consumer.store.facts().isEmpty)
    }

    @Test func candidateSubmissionRequiresGrantAndRevocationBlocksPendingApproval() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let scope = MemoryScope(sessionID: "auth-session", projectID: "project-1")
        let consumer = MemoryProposalConsumer(store: MemoryStore(directory: directory))
        #expect(throws: MemoryProposalConsumerError.candidateSubmissionUnauthorized) {
            _ = try consumer.submit(
                proposalID: "ungranted",
                text: "不得提交",
                within: scope,
                sourceID: Self.fixtureSourceID
            )
        }
        #expect(try consumer.envelopes().isEmpty)
        #expect(try consumer.store.facts().isEmpty)

        _ = try consumer.grantCandidateSubmission(
            sourceID: Self.fixtureSourceID,
            reason: "explicit test grant"
        )
        _ = try consumer.submit(
            proposalID: "pending-before-revoke",
            text: "撤销前待批准",
            within: scope,
            sourceID: Self.fixtureSourceID
        )
        #expect(try consumer.store.facts().isEmpty)
        _ = try consumer.revokeCandidateSubmission(
            sourceID: Self.fixtureSourceID,
            reason: "explicit test revocation"
        )
        #expect(throws: MemoryProposalConsumerError.candidateSubmissionRevoked) {
            _ = try consumer.approve(
                proposalID: "pending-before-revoke",
                within: scope,
                reason: "must stay blocked"
            )
        }
        #expect(try consumer.store.facts().isEmpty)
    }

    @Test func proposalWritesScopedFactOnlyAfterExplicitApproval() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let scope = MemoryScope(sessionID: "session-1", projectID: "project-1")
        let consumer = try grantedConsumer(directory: directory)
        let submitted = try consumer.submit(
            proposalID: "proposal-001",
            text: "用户偏好简洁回答",
            within: scope,
            sourceID: Self.fixtureSourceID
        )

        #expect(submitted.state == .proposed)
        #expect(try consumer.store.facts().isEmpty)

        let approved = try consumer.approve(
            proposalID: "proposal-001",
            within: scope,
            reason: "用户明确批准"
        )

        #expect(approved.state == .approved)
        #expect(try consumer.store.facts().count == 1)
        #expect(try consumer.store.facts().first?.memoryScope == scope)
    }

    @Test func approvalPersistsProposalSourceAndContentDigestOnActiveFact() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let scope = MemoryScope(sessionID: "session-provenance", projectID: "project-1")
        let text = "需要保留来源的记忆"
        let sourceRef = "chat://session-provenance/turn-7"
        let digest = MemoryStore.contentDigest(for: text)
        let consumer = try grantedConsumer(directory: directory)
        let submitted = try consumer.submit(
            proposalID: "proposal-provenance",
            text: text,
            within: scope,
            sourceRef: sourceRef,
            contentDigest: digest,
            sourceID: Self.fixtureSourceID
        )

        #expect(submitted.sourceRef == sourceRef)
        #expect(submitted.contentDigest == digest)
        _ = try consumer.approve(
            proposalID: submitted.proposal.proposalID,
            within: scope,
            reason: "用户明确批准"
        )

        let fact = try #require(consumer.store.facts().first)
        #expect(fact.lifecycleState == .active)
        #expect(fact.revision == 1)
        #expect(fact.sourceProposalID == submitted.proposal.proposalID)
        #expect(fact.sourceRef == sourceRef)
        #expect(fact.contentDigest == digest)
    }

    @Test func legacyProposalEnvelopeWithoutBindingFailsClosed() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let scope = MemoryScope(sessionID: "legacy-proposal-session", projectID: "project-1")
        let proposal = MemoryProposalLifecycleReceipt(
            proposalID: "legacy-proposal",
            scope: .session,
            memoryScope: scope,
            subjectID: "legacy-proposal",
            action: .propose,
            state: .proposed,
            reason: "legacy",
            sequence: 1
        )
        let envelope = MemoryProposalEnvelope(
            proposal: proposal,
            text: "旧 proposal 格式"
        )
        var object = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(envelope)
            ) as? [String: Any]
        )
        object["version"] = 1
        object.removeValue(forKey: "sourceRef")
        object.removeValue(forKey: "contentDigest")
        object.removeValue(forKey: "sourceHash")
        object.removeValue(forKey: "generation")
        object.removeValue(forKey: "binding")

        let consumer = MemoryProposalConsumer(store: MemoryStore(directory: directory))
        try FileManager.default.createDirectory(
            at: consumer.receiptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: [object]).write(to: consumer.receiptURL)
        let receiptBytes = try Data(contentsOf: consumer.receiptURL)

        #expect(throws: MemoryProposalConsumerError.invalidBinding) {
            _ = try consumer.approve(
                proposalID: proposal.proposalID,
                within: scope,
                reason: "兼容旧格式"
            )
        }
        #expect(try consumer.store.facts().isEmpty)
        #expect(try Data(contentsOf: consumer.receiptURL) == receiptBytes)
    }

    @Test func proposalRejectsContentDigestMismatchBeforePersistence() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let scope = MemoryScope(sessionID: "digest-session", projectID: "project-1")
        let consumer = MemoryProposalConsumer(store: MemoryStore(directory: directory))
        #expect(throws: MemoryProposalConsumerError.invalidProvenance) {
            _ = try consumer.submit(
                proposalID: "digest-mismatch",
                text: "原始内容",
                within: scope,
                sourceRef: "chat://digest-session/turn-1",
                contentDigest: "not-the-text-digest"
            )
        }
        #expect(try consumer.envelopes().isEmpty)
        #expect(try consumer.store.facts().isEmpty)
    }

    @Test func revisionAndLifecycleUseProposalConsumerBoundaryAndActiveRetrieval() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let scope = MemoryScope(sessionID: "revision-session", projectID: "project-1")
        let consumer = try grantedConsumer(directory: directory)
        let firstText = "用户喜欢晴天"
        _ = try consumer.submit(
            proposalID: "proposal-r1",
            text: firstText,
            within: scope,
            sourceRef: "chat://revision-session/turn-1",
            sourceID: Self.fixtureSourceID
        )
        _ = try consumer.approve(
            proposalID: "proposal-r1",
            within: scope,
            reason: "首次批准"
        )
        let first = try #require(
            consumer.store.facts().first(where: { $0.sourceProposalID == "proposal-r1" })
        )

        let secondText = "用户喜欢晴天和跑步"
        _ = try consumer.submit(
            proposalID: "proposal-r2",
            text: secondText,
            within: scope,
            sourceRef: "chat://revision-session/turn-2",
            sourceID: Self.fixtureSourceID
        )
        _ = try consumer.approveRevision(
            proposalID: "proposal-r2",
            supersedingFactID: first.id,
            within: scope,
            reason: "用户更新记忆"
        )

        let second = try #require(
            consumer.store.facts().first(where: { $0.id == "proposal-r2" })
        )
        #expect(second.revision == 2)
        #expect(second.lifecycleState == .active)
        #expect(second.supersedesFactID == first.id)
        #expect(
            try consumer.proposalLineage(
                forFactID: second.id,
                within: scope
            )?.proposal.proposalID == "proposal-r2"
        )
        #expect(
            try MemorySearch(store: consumer.store).search(keyword: "晴天").map(\.id)
                == [second.id]
        )

        let factsBeforeRetry = try Data(contentsOf: consumer.store.fileURL)
        #expect(throws: MemoryProposalConsumerError.duplicateConsumption) {
            _ = try consumer.approveRevision(
                proposalID: "proposal-r2",
                supersedingFactID: first.id,
                within: scope,
                reason: "重复批准"
            )
        }
        #expect(try Data(contentsOf: consumer.store.fileURL) == factsBeforeRetry)

        _ = try consumer.rollbackFact(
            id: second.id,
            within: scope,
            reason: "用户撤销更新"
        )
        #expect(try consumer.store.activeFacts().map(\.id) == [first.id])

        _ = try consumer.tombstoneFact(
            id: first.id,
            within: scope,
            reason: "用户删除记忆"
        )
        #expect(try consumer.store.activeFacts().isEmpty)
        #expect(try MemorySearch(store: consumer.store).search(keyword: "晴天").isEmpty)
    }

    @Test func lifecycleConsumerRejectsCrossScopeMutationAndMissingLineage() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let scope = MemoryScope(sessionID: "scope-a", projectID: "project-1")
        let otherScope = MemoryScope(sessionID: "scope-b", projectID: "project-1")
        let consumer = try grantedConsumer(directory: directory)
        _ = try consumer.submit(
            proposalID: "proposal-scope",
            text: "必须绑定 scope",
            within: scope,
            sourceID: Self.fixtureSourceID
        )
        _ = try consumer.approve(
            proposalID: "proposal-scope",
            within: scope,
            reason: "批准"
        )
        let fact = try #require(consumer.store.facts().first)

        #expect(throws: MemoryProposalConsumerError.scopeMismatch) {
            _ = try consumer.tombstoneFact(
                id: fact.id,
                within: otherScope,
                reason: "越界"
            )
        }
        #expect(throws: MemoryProposalConsumerError.proposalConflict) {
            try FileManager.default.removeItem(at: consumer.receiptURL)
            _ = try consumer.proposalLineage(
                forFactID: fact.id,
                within: scope
            )
        }
    }

    @Test func revisionLifecycleKeepsLineageAndIsIdempotentAcrossStoreRestarts() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let scope = MemoryScope(sessionID: "restart-session", projectID: "project-1")
        let firstConsumer = try grantedConsumer(directory: directory)
        _ = try firstConsumer.submit(
            proposalID: "restart-r1",
            text: "重启前的记忆",
            within: scope,
            sourceRef: "chat://restart-session/turn-1",
            sourceID: Self.fixtureSourceID
        )
        _ = try firstConsumer.approve(
            proposalID: "restart-r1",
            within: scope,
            reason: "首次批准"
        )
        let firstFact = try #require(
            firstConsumer.store.facts().first(where: { $0.sourceProposalID == "restart-r1" })
        )
        _ = try firstConsumer.submit(
            proposalID: "restart-r2",
            text: "重启后的更新记忆",
            within: scope,
            sourceRef: "chat://restart-session/turn-2",
            sourceID: Self.fixtureSourceID
        )
        _ = try firstConsumer.approveRevision(
            proposalID: "restart-r2",
            supersedingFactID: firstFact.id,
            within: scope,
            reason: "追加 revision"
        )

        let reopened = MemoryProposalConsumer(store: MemoryStore(directory: directory))
        let secondFact = try #require(
            reopened.store.facts().first(where: { $0.id == "restart-r2" })
        )
        #expect(secondFact.lifecycleState == .active)
        #expect(
            try reopened.proposalLineage(
                forFactID: secondFact.id,
                within: scope
            )?.proposal.proposalID == "restart-r2"
        )

        let rollback = try reopened.rollbackFact(
            id: secondFact.id,
            within: scope,
            reason: "重启后撤销更新"
        )
        let afterRollbackRestart = MemoryProposalConsumer(
            store: MemoryStore(directory: directory)
        )
        let repeatedRollback = try afterRollbackRestart.rollbackFact(
            id: secondFact.id,
            within: scope,
            reason: "重启后撤销更新"
        )
        #expect(repeatedRollback == rollback)
        #expect(
            try afterRollbackRestart.store.activeFacts().map(\.id) == [firstFact.id]
        )
        #expect(try afterRollbackRestart.store.lifecycleReceipts().count == 1)

        let tombstone = try afterRollbackRestart.tombstoneFact(
            id: firstFact.id,
            within: scope,
            reason: "重启后删除记忆"
        )
        let afterTombstoneRestart = MemoryProposalConsumer(
            store: MemoryStore(directory: directory)
        )
        let repeatedTombstone = try afterTombstoneRestart.tombstoneFact(
            id: firstFact.id,
            within: scope,
            reason: "重启后删除记忆"
        )
        #expect(repeatedTombstone == tombstone)
        #expect(try afterTombstoneRestart.store.activeFacts().isEmpty)
        #expect(try afterTombstoneRestart.store.lifecycleReceipts().count == 2)
    }

    @Test func approvalRejectsChangedScopeWithoutWriting() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let original = MemoryScope(sessionID: "session-1", projectID: "project-1")
        let changed = MemoryScope(sessionID: "session-2", projectID: "project-1")
        let consumer = try grantedConsumer(directory: directory)
        _ = try consumer.submit(
            proposalID: "proposal-002",
            text: "不能跨会话写入",
            within: original,
            sourceID: Self.fixtureSourceID
        )
        let factsURL = consumer.store.fileURL
        let before = try? Data(contentsOf: factsURL)

        do {
            _ = try consumer.approve(
                proposalID: "proposal-002",
                within: changed,
                reason: "错误 scope"
            )
            Issue.record("scope mismatch must be rejected")
        } catch let error as MemoryProposalConsumerError {
            #expect(error == .scopeMismatch)
        }

        #expect(try consumer.store.facts().isEmpty)
        #expect((try? Data(contentsOf: factsURL)) == before)
    }

    @Test func duplicateApprovalDoesNotChangeFactBytes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let scope = MemoryScope(sessionID: "session-1", projectID: "project-1")
        let consumer = try grantedConsumer(directory: directory)
        _ = try consumer.submit(
            proposalID: "proposal-003",
            text: "幂等记忆",
            within: scope,
            sourceID: Self.fixtureSourceID
        )
        _ = try consumer.approve(
            proposalID: "proposal-003",
            within: scope,
            reason: "第一次批准"
        )
        let firstBytes = try Data(contentsOf: consumer.store.fileURL)

        #expect(throws: MemoryProposalConsumerError.duplicateConsumption) {
            _ = try consumer.approve(
                proposalID: "proposal-003",
                within: scope,
                reason: "重复批准"
            )
        }
        let secondBytes = try Data(contentsOf: consumer.store.fileURL)

        #expect(secondBytes == firstBytes)
        #expect(try consumer.store.facts().count == 1)
    }

    @Test func proposalAndApprovedStateRecoverAcrossConsumerRestart() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let scope = MemoryScope(sessionID: "session-restart", projectID: "project-1")
        let first = try grantedConsumer(directory: directory)
        _ = try first.submit(
            proposalID: "proposal-restart",
            text: "重启后仍需明确批准",
            within: scope,
            sourceID: Self.fixtureSourceID
        )

        let reopened = MemoryProposalConsumer(store: MemoryStore(directory: directory))
        #expect(try reopened.envelopes().first?.state == .proposed)
        #expect(try reopened.store.facts().isEmpty)

        _ = try reopened.approve(
            proposalID: "proposal-restart",
            within: scope,
            reason: "重启后用户明确批准"
        )
        #expect(try reopened.store.facts().count == 1)
        #expect(try reopened.envelopes().first?.state == .active)
    }

    @Test func approvalCanRetryAfterFactPersistenceFailure() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let scope = MemoryScope(sessionID: "session-retry", projectID: "project-1")
        let consumer = try grantedConsumer(directory: directory)
        _ = try consumer.submit(
            proposalID: "proposal-retry",
            text: "事实写盘失败后可恢复",
            within: scope,
            sourceID: Self.fixtureSourceID
        )

        try FileManager.default.createDirectory(
            at: consumer.store.fileURL,
            withIntermediateDirectories: true
        )
        #expect(throws: (any Error).self) {
            _ = try consumer.approve(
                proposalID: "proposal-retry",
                within: scope,
                reason: "首次批准"
            )
        }
        #expect(try consumer.envelopes().first?.state == .approved)
        #expect(throws: (any Error).self) {
            _ = try consumer.store.facts()
        }

        try FileManager.default.removeItem(at: consumer.store.fileURL)
        let restarted = MemoryProposalConsumer(store: MemoryStore(directory: directory))
        #expect(try restarted.recoverApprovedProposals() == 1)
        let recovered = try #require(try restarted.store.facts().first)
        #expect(try restarted.store.facts().count == 1)
        #expect(recovered.visibility == nil)
        #expect(recovered.memoryScope == scope)
        let sibling = MemoryScope(sessionID: "session-other", projectID: scope.projectID)
        let result = try MemoryInjector(store: restarted.store).injection(
            base: "", userMessage: recovered.text, context: MemoryInjectionContext(scope: sibling))
        #expect(result.injectedFactIDs.isEmpty)
        #expect(try restarted.envelopes().first?.state == .active)
    }

    @Test func manualProjectApprovalRecoversVisibilityAfterFactPersistenceFailure() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = MemoryScope(sessionID: "manual-origin", projectID: "manual-project")
        let text = "测试偏好：回答使用中文"
        let consumer = MemoryProposalConsumer(store: MemoryStore(directory: directory))
        _ = try consumer.grantCandidateSubmission(sourceID: "settings-center", reason: "owned test grant")

        try FileManager.default.createDirectory(
            at: consumer.store.fileURL, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) {
            _ = try consumer.addManualProjectFact(text: text, category: .userPref, within: scope)
        }
        let approved = try #require(try consumer.envelopes().first)
        #expect(approved.state == .approved)
        #expect(approved.approvalReceipt?.memoryScope == scope)
        #expect(throws: (any Error).self) { _ = try consumer.store.facts() }

        try FileManager.default.removeItem(at: consumer.store.fileURL)
        let restarted = MemoryProposalConsumer(store: MemoryStore(directory: directory))
        #expect(try restarted.store.facts().isEmpty)
        #expect(try restarted.recoverApprovedProposals() == 1)
        let facts = try restarted.store.facts()
        try #require(facts.count == 1)
        let fact = try #require(facts.first)
        #expect(fact.id == approved.proposal.subjectID)
        #expect(fact.visibility == .project)
        #expect(fact.memoryScope == scope)
        #expect(try restarted.envelopes().first?.state == .active)

        let injector = MemoryInjector(store: restarted.store)
        let sibling = MemoryScope(sessionID: "manual-sibling", projectID: scope.projectID)
        for allowed in [scope, sibling] {
            let result = try injector.injection(
                base: "", userMessage: text, context: MemoryInjectionContext(scope: allowed))
            #expect(result.injectedFactIDs == [fact.id])
        }
        let foreign = MemoryScope(sessionID: "manual-foreign", projectID: "other-project")
        let result = try injector.injection(
            base: "", userMessage: text, context: MemoryInjectionContext(scope: foreign))
        #expect(result.injectedFactIDs.isEmpty)
        #expect(!result.prompt.contains(text))
        _ = try restarted.recoverApprovedProposals()
        #expect(try restarted.store.facts() == facts)
    }

    @Test func startupReplayNeverRecreatesCommittedFactsAfterDeletionOrTombstone() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = MemoryScope(sessionID: "session-replay", projectID: "project-replay")
        let consumer = try grantedConsumer(directory: directory)

        let deleted = try consumer.submit(
            proposalID: "proposal-deleted", text: "synthetic deleted preference",
            within: scope, sourceID: Self.fixtureSourceID
        )
        _ = try consumer.approve(
            proposalID: deleted.proposal.proposalID, within: scope,
            reason: "synthetic approval"
        )
        _ = try consumer.store.removeFactForRollback(id: deleted.proposal.subjectID)

        let tombstoned = try consumer.submit(
            proposalID: "proposal-tombstoned", text: "synthetic tombstoned preference",
            within: scope, sourceID: Self.fixtureSourceID
        )
        _ = try consumer.approve(
            proposalID: tombstoned.proposal.proposalID, within: scope,
            reason: "synthetic approval"
        )
        _ = try consumer.tombstoneFact(
            id: tombstoned.proposal.subjectID, within: scope,
            reason: "synthetic tombstone"
        )

        let before = try consumer.store.facts()
        let beforeReceipts = try consumer.store.lifecycleReceipts()
        let restarted = MemoryProposalConsumer(store: MemoryStore(directory: directory))
        #expect(try restarted.recoverApprovedProposals() == 0)
        #expect(try restarted.store.facts() == before)
        #expect(try restarted.store.lifecycleReceipts() == beforeReceipts)
        #expect(try restarted.store.activeFacts().isEmpty)
        #expect(try restarted.envelopes().allSatisfy { $0.state == .active })
    }

    @Test func restoreImportIsIdempotentAndKeepsReceiptAcrossRestart() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let scope = MemoryScope(sessionID: "restore-session", projectID: "project-1")
        let fact = MemoryFact(
            id: "restore-1",
            text: "可重复恢复",
            sourceSessionID: "source-session",
            category: .lesson
        )
        let firstConsumer = MemoryProposalConsumer(store: MemoryStore(directory: directory))
        let first = try firstConsumer.restoreFacts(
            [fact],
            within: scope,
            mode: .merge,
            reason: "测试导入"
        )
        let bytesAfterFirst = try Data(contentsOf: firstConsumer.store.fileURL)

        let restarted = MemoryProposalConsumer(store: MemoryStore(directory: directory))
        let second = try restarted.restoreFacts(
            [fact],
            within: scope,
            mode: .merge,
            reason: "重复导入"
        )

        #expect(second == first)
        #expect(try Data(contentsOf: restarted.store.fileURL) == bytesAfterFirst)
        #expect(try restarted.restoreReceipts().count == 1)
        #expect(try restarted.store.facts().count == 1)
    }

    @Test func restoreRejectsConflictingDuplicateWithoutChangingFacts() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let scope = MemoryScope(sessionID: "restore-session", projectID: "project-1")
        let consumer = MemoryProposalConsumer(store: MemoryStore(directory: directory))
        _ = try consumer.restoreFacts(
            [MemoryFact(id: "same-id", text: "原始内容")],
            within: scope,
            reason: "首次导入"
        )
        let before = try Data(contentsOf: consumer.store.fileURL)

        #expect(throws: MemoryProposalConsumerError.restoreConflict) {
            _ = try consumer.restoreFacts(
                [MemoryFact(id: "same-id", text: "冲突内容")],
                within: scope,
                reason: "冲突导入"
            )
        }
        #expect(try Data(contentsOf: consumer.store.fileURL) == before)
        #expect(try consumer.store.facts().map(\.text) == ["原始内容"])
    }

    @Test func restoreAcrossStoreInstancesDoesNotLoseFactsOrReceipts() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let scope = MemoryScope(sessionID: "parallel-restore", projectID: "project-1")
        let consumers = [
            MemoryProposalConsumer(store: MemoryStore(directory: directory)),
            MemoryProposalConsumer(store: MemoryStore(directory: directory))
        ]
        let failures = ConcurrentRestoreFailures()
        let iterations = 96

        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            let fact = MemoryFact(
                id: "parallel-\(index)",
                text: "并发恢复 \(index)",
                sourceSessionID: scope.sessionID,
                createdAt: Date(timeIntervalSince1970: Double(index + 1))
            )
            do {
                _ = try consumers[index % consumers.count].restoreFacts(
                    [fact],
                    within: scope,
                    mode: .merge,
                    reason: "并发恢复合同"
                )
            } catch {
                failures.append(error)
            }
        }

        #expect(failures.isEmpty)
        let reopenedStore = MemoryStore(directory: directory)
        #expect(try reopenedStore.facts().count == iterations)
        let reopenedConsumer = MemoryProposalConsumer(store: reopenedStore)
        #expect(try reopenedConsumer.restoreReceipts().count == iterations)
    }

    @Test func directStoreInstancesDoNotLoseFacts() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let scope = MemoryScope(sessionID: "parallel-store", projectID: "project-1")
        let stores = [
            MemoryStore(directory: directory),
            MemoryStore(directory: directory)
        ]
        let failures = ConcurrentRestoreFailures()
        let iterations = 96

        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            do {
                _ = try stores[index % stores.count].addFact(
                    id: "store-\(index)",
                    text: "并发写入 \(index)",
                    sourceSessionID: scope.sessionID,
                    memoryScope: scope
                )
            } catch {
                failures.append(error)
            }
        }

        #expect(failures.isEmpty)
        #expect(try MemoryStore(directory: directory).facts().count == iterations)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryProposalConsumerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class ConcurrentRestoreFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [any Error] = []

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return values.isEmpty
    }

    func append(_ error: any Error) {
        lock.lock()
        values.append(error)
        lock.unlock()
    }
}
