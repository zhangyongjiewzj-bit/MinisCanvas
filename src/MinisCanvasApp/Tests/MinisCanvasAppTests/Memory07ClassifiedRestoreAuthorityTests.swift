import Foundation
import Testing
@testable import MinisCore

struct Memory07ClassifiedRestoreAuthorityTests {
    @Test("D-MEMORY-07 restore retains visibility/lifetime and rechecks Personal authority before replay")
    func classifiedRestoreRetainsMetadataAndRejectsUnauthorizedReplay() throws {
        let paths = try #require(try FormalTestIsolationPaths.resolveCurrentProcess())
        let directory = paths.rootDirectory.appendingPathComponent("memory07-restore-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scope = MemoryScope(sessionID: "synthetic-session", projectID: "synthetic-project")
        let ownerCandidate = MemoryTrustedPrincipal.validated(userID: "synthetic-owner", by: { $0 == "synthetic-owner" })
        let owner = try #require(ownerCandidate)
        let otherCandidate = MemoryTrustedPrincipal.validated(userID: "synthetic-other", by: { $0 == "synthetic-other" })
        let other = try #require(otherCandidate)
        let store = MemoryStore(directory: directory)
        let consumer = MemoryProposalConsumer(store: store)
        let facts = [
            MemoryFact(text: "synthetic personal", memoryScope: scope, ownerUserID: owner.userID, visibility: .personal),
            MemoryFact(text: "synthetic project", memoryScope: scope, visibility: .project),
            MemoryFact(text: "synthetic temporary", memoryScope: scope, visibility: .temporary,
                       temporaryLifetimeID: "session:" + scope.sessionID)
        ]
        #expect(throws: MemoryVisibilityError.personalPrincipalUnavailable) {
            try consumer.restoreFacts(facts, within: scope, reason: "synthetic import")
        }
        #expect(try store.activeFacts().isEmpty)
        let result = try consumer.restoreFacts(facts, within: scope, reason: "synthetic import", trustedPrincipal: owner)
        #expect(result.added == 3)
        let reopened = MemoryStore(directory: directory)
        #expect(Set(try reopened.activeFacts().map(\.visibility)) == Set([.personal, .project, .temporary]))
        #expect(try reopened.activeFacts().first { $0.visibility == .temporary }?.temporaryLifetimeID == "session:" + scope.sessionID)
        let before = try Data(contentsOf: store.fileURL)
        let reloadedConsumer = MemoryProposalConsumer(store: reopened)
        #expect(throws: MemoryVisibilityError.personalPrincipalUnavailable) {
            try reloadedConsumer.restoreFacts(facts, within: scope, reason: "synthetic replay", trustedPrincipal: other)
        }
        #expect(throws: MemoryVisibilityError.personalPrincipalUnavailable) {
            try reloadedConsumer.restoreFacts(facts, within: scope, reason: "synthetic replay")
        }
        let replay = try reloadedConsumer.restoreFacts(facts, within: scope, reason: "synthetic replay", trustedPrincipal: owner)
        #expect(replay.receipt == result.receipt)
        #expect(try Data(contentsOf: store.fileURL) == before)
        #expect(try reloadedConsumer.restoreReceipts().count == 1)
    }
}
