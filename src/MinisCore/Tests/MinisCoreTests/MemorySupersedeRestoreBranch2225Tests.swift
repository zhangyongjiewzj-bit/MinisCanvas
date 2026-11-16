import Foundation
import Testing
@testable import MinisCore

struct MemorySupersedeRestoreBranch2225Tests {
    @Test func restoredSiblingCannotCreateTwoCurrentRevisions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-2225-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let scope = MemoryScope(sessionID: "owned-session", projectID: "owned-project")
        let store = MemoryStore(directory: root)
        let original = try store.addFact(
            id: "root-fact", text: "shared query original",
            sourceSessionID: scope.sessionID, memoryScope: scope
        )
        let currentText = "shared query canonical"
        let current = try store.appendRevision(
            to: original.id, id: "current-fact", text: currentText,
            sourceSessionID: scope.sessionID, memoryScope: scope,
            sourceProposalID: "approved-revision", sourceRef: "synthetic://revision",
            contentDigest: MemoryStore.contentDigest(for: currentText)
        )
        let consumer = MemoryProposalConsumer(store: store)
        let lateText = "shared query late revision"
        #expect(throws: MemoryStoreError.invalidRevision) {
            _ = try store.appendRevision(
                to: original.id, id: "late-current-fact", text: lateText,
                sourceSessionID: scope.sessionID, memoryScope: scope,
                sourceProposalID: "late-revision", sourceRef: "synthetic://late",
                contentDigest: MemoryStore.contentDigest(for: lateText)
            )
        }
        let independent = MemoryFact(
            id: "independent-fact", text: "an unrelated approved fact",
            sourceSessionID: scope.sessionID, memoryScope: scope
        )
        _ = try consumer.restoreFacts(
            [independent], within: scope, mode: .merge,
            reason: "synthetic unrelated fact"
        )
        let before = try Data(contentsOf: store.fileURL)
        let priorReceipts = try consumer.restoreReceipts()
        #expect(try store.facts().first(where: { $0.id == original.id })?.lifecycleState == .superseded)
        #expect(Set(try store.activeFacts().map(\.id)) == [current.id, independent.id])
        #expect(try store.searchFacts(keyword: "shared query").map(\.id) == [current.id])

        let sibling = MemoryFact(
            id: "second-current-fact", text: "shared query conflicting",
            sourceSessionID: scope.sessionID, memoryScope: scope,
            revision: 2, supersedesFactID: original.id, lifecycleState: .active
        )
        let foreign = MemoryFact(
            id: "foreign-current-fact", text: "shared query foreign",
            sourceSessionID: "foreign-session",
            memoryScope: MemoryScope(sessionID: "foreign-session", projectID: scope.projectID),
            revision: 2, supersedesFactID: original.id, lifecycleState: .active
        )
        #expect(throws: MemoryProposalConsumerError.scopeMismatch) {
            _ = try consumer.restoreFacts(
                [foreign], within: scope, mode: .merge,
                reason: "synthetic foreign scope"
            )
        }
        #expect(throws: MemoryProposalConsumerError.restoreConflict) {
            _ = try consumer.restoreFacts(
                [sibling], within: scope, mode: .merge,
                reason: "synthetic competing revision"
            )
        }

        let reopened = MemoryStore(directory: root)
        #expect(try Data(contentsOf: store.fileURL) == before)
        #expect(try consumer.restoreReceipts() == priorReceipts)
        #expect(try reopened.searchFacts(keyword: "shared query").map(\.id) == [current.id])
        #expect(Set(try reopened.activeFacts().map(\.id)) == [current.id, independent.id])
        #expect(try reopened.facts().first(where: { $0.id == original.id })?.lifecycleState == .superseded)
    }
}
