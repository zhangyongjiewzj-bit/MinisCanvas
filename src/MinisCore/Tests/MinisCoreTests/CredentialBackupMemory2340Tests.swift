import Foundation
import Testing
@testable import MinisCore

@Suite("D-CREDI pre-custody memory backup consumer")
struct CredentialBackupMemory2340Tests {
    private func fixture() throws -> (URL, SyncManager, MemoryScope) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CredentialBackup2340-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let session = try sessions.createSession(id: UUID().uuidString, title: "ordinary project")
        let scope = MemoryScope(sessionID: session.id, projectID: "synthetic2340")
        let manager = SyncManager(sessionStore: sessions,
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memories")),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            deviceName: "Synthetic2340")
        return (root, manager, scope)
    }

    @Test func earlierCredentialAssignmentIsRedactedInMemorySnapshot() throws {
        let (_, manager, scope) = try fixture()
        let secret = "SYNTHETIC2340-" + UUID().uuidString
        let text = "ordinary preference is sunny; api_key=" + secret
        let source = try manager.memoryStore.addFact(text, sourceSessionID: scope.sessionID,
            category: .userPref, memoryScope: scope)
        // Upstream historical data is intentionally raw; no secret registry is
        // supplied. The export consumer must apply the existing format policy.
        #expect(source.text.contains(secret))
        manager.markDirty(.memories)
        let data = try manager.exportSnapshot(scopes: [.memories])
        #expect(!String(decoding: data, as: UTF8.self).contains(secret))
        let envelope = try JSONDecoder().decode(SyncSnapshotEnvelope.self, from: data)
        let exported = try #require(envelope.memories?.first)
        #expect(exported.text == ContentSecretRedactor.redact(text))
        #expect(exported.id == source.id)
        #expect(exported.createdAt == source.createdAt)
        #expect(exported.sourceSessionID == source.sourceSessionID)
        #expect(exported.memoryScope == source.memoryScope)
        #expect(exported.category == source.category)
        #expect(envelope.manifest.scopes == ["memories"])
        #expect(manager.dirtyScopes.isEmpty)
        #expect(try manager.memoryStore.loadFacts() == [source])
    }

    @Test func actualFileExportCannotContainEarlierCredentialAssignment() throws {
        let (root, manager, scope) = try fixture()
        let secret = "SYNTHETIC2340-FILE-" + UUID().uuidString
        let source = try manager.memoryStore.addFact("keep ordinary text; token=" + secret,
            sourceSessionID: scope.sessionID, memoryScope: scope)
        let destination = root.appendingPathComponent("owned-synthetic.minissync")
        try manager.exportSnapshotFile(scopes: [.memories], to: destination)
        let data = try Data(contentsOf: destination)
        #expect(!String(decoding: data, as: UTF8.self).contains(secret))
        let envelope = try JSONDecoder().decode(SyncSnapshotEnvelope.self, from: data)
        #expect(envelope.memories?.first?.text == ContentSecretRedactor.redact(source.text))
        #expect(try manager.memoryStore.loadFacts() == [source])
    }

    @Test func ordinaryMemoryBackupRetainsFactsAndRoundTrip() throws {
        let (_, manager, scope) = try fixture()
        let source = try manager.memoryStore.addFact("ordinary preference is sunny",
            sourceSessionID: scope.sessionID, category: .userPref, memoryScope: scope)
        let data = try manager.exportSnapshot(scopes: [.memories])
        let envelope = try JSONDecoder().decode(SyncSnapshotEnvelope.self, from: data)
        #expect(envelope.memories == [source])
        let (_, destination, _) = try fixture()
        let result = try destination.importSnapshot(data, restoring: [.memories], memoryScope: scope)
        #expect(result.allSucceeded)
        #expect(try destination.memoryStore.loadFacts() == [source])
    }

    private func approvedFact(_ manager: SyncManager, scope: MemoryScope,
                              text: String) throws -> MemoryFact {
        let consumer = manager.memoryProposalConsumer
        let sourceID = "synthetic2340-" + UUID().uuidString
        _ = try consumer.grantCandidateSubmission(sourceID: sourceID,
            reason: "explicit synthetic candidate source grant")
        let submitted = try consumer.submit(proposalID: UUID().uuidString,
            text: text, within: scope, sourceRef: "chat://" + scope.sessionID + "/synthetic-turn",
            sourceID: sourceID)
        _ = try consumer.approve(proposalID: submitted.proposal.proposalID,
            within: scope, reason: "explicit synthetic user approval")
        return try #require(manager.memoryStore.loadFacts().first)
    }

    @Test func credentialBoundMemoryFailsExportWithoutForgingProvenanceOrWritingFile() throws {
        let (root, manager, scope) = try fixture()
        // 第六版起，新的记忆候选一旦像凭据就在提交时被拒（提示词方案 v2）。
        let text = "ordinary note; api_key=SYNTHETIC2340-BOUND-" + UUID().uuidString
        let (_, other, otherScope) = try fixture()
        #expect(throws: MemoryProposalConsumerError.credentialLikeContent) {
            _ = try approvedFact(other, scope: otherScope, text: text)
        }
        #expect(try other.memoryStore.loadFacts().isEmpty)
        // 第六版之前已经批准入库的旧条目（没有提议日志的导入形态）仍带哈希绑定，导出须拒绝。
        let source = try manager.memoryStore.addFact(text, sourceSessionID: scope.sessionID,
            memoryScope: scope, sourceProposalID: "legacy-approved-" + UUID().uuidString,
            sourceRef: "chat://" + scope.sessionID + "/legacy-turn",
            contentDigest: MemoryStore.contentDigest(for: text))
        try #require(source.sourceProposalID != nil && source.contentDigest != nil)
        let original = try manager.memoryStore.loadFacts()
        let destination = root.appendingPathComponent("retained-owned-destination.minissync")
        let retained = Data("ordinary preexisting synthetic destination".utf8)
        try retained.write(to: destination)
        manager.markDirty(.memories)
        #expect(throws: SyncSnapshotExportError.credentialBoundMemory) {
            try manager.exportSnapshot(scopes: [.memories])
        }
        #expect(throws: SyncSnapshotExportError.credentialBoundMemory) {
            try manager.exportSnapshotFile(scopes: [.memories], to: destination)
        }
        #expect(try Data(contentsOf: destination) == retained)
        #expect(manager.dirtyScopes == [.memories])
        #expect(try manager.memoryStore.loadFacts() == original)
        #expect(source.contentDigest == MemoryStore.contentDigest(for: source.text))
    }

    @Test func ordinaryApprovedFactRetainsItsActualSourceAndDigest() throws {
        let (_, manager, scope) = try fixture()
        let source = try approvedFact(manager, scope: scope, text: "ordinary approved preference is sunny")
        try #require(source.sourceProposalID != nil && source.contentDigest != nil)
        let data = try manager.exportSnapshot(scopes: [.memories])
        let envelope = try JSONDecoder().decode(SyncSnapshotEnvelope.self, from: data)
        #expect(envelope.memories == [source])
        #expect(try manager.memoryStore.loadFacts() == [source])
    }

}
