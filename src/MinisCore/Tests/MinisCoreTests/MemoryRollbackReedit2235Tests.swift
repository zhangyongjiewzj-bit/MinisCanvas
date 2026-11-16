import Foundation
import Testing
@testable import MinisCore

struct MemoryRollbackReedit2235Tests {
    @Test func rolledBackRevisionAllowsNewBranchAndTombstoneStaysForgotten() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-2235-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let scope = MemoryScope(sessionID: "owned-session", projectID: "owned-project")
        let store = MemoryStore(directory: root)
        let first = try store.addFact(
            id: "fact-r1", text: "orbit2235 original",
            sourceSessionID: scope.sessionID, memoryScope: scope
        )
        let secondText = "orbit2235 withdrawn"
        let second = try store.appendRevision(
            to: first.id, id: "fact-r2", text: secondText,
            sourceSessionID: scope.sessionID, memoryScope: scope,
            sourceProposalID: "proposal-r2", sourceRef: "synthetic://r2",
            contentDigest: MemoryStore.contentDigest(for: secondText)
        )
        _ = try store.rollbackFact(id: second.id, reason: "synthetic rollback")
        #expect(try store.activeFacts().map(\.id) == [first.id])
        #expect(try store.facts().first(where: { $0.id == second.id })?.lifecycleState == .rolledBack)

        let thirdText = "orbit2235 final"
        let third = try store.appendRevision(
            to: first.id, id: "fact-r3", text: thirdText,
            sourceSessionID: scope.sessionID, memoryScope: scope,
            sourceProposalID: "proposal-r3", sourceRef: "synthetic://r3",
            contentDigest: MemoryStore.contentDigest(for: thirdText)
        )
        let reopened = MemoryStore(directory: root)
        #expect(try reopened.activeFacts().map(\.id) == [third.id])
        #expect(try reopened.facts().first(where: { $0.id == first.id })?.lifecycleState == .superseded)
        #expect(try reopened.facts().first(where: { $0.id == second.id })?.lifecycleState == .rolledBack)
        let beforeForget = try MemoryInjector(store: reopened).systemPrompt(
            base: "base", userMessage: "orbit2235", memoryScope: scope
        )
        #expect(beforeForget.contains(thirdText))
        #expect(!beforeForget.contains(secondText))

        _ = try reopened.tombstoneFact(id: third.id, reason: "synthetic forget")
        let afterForget = MemoryStore(directory: root)
        let beforeRestore = try Data(contentsOf: afterForget.fileURL)
        let receiptsBeforeRestore = try afterForget.lifecycleReceipts()
        let staleChild = MemoryFact(
            id: "fact-r4-forged", text: "orbit2235 forbidden resurrection",
            sourceSessionID: scope.sessionID, memoryScope: scope,
            revision: third.revision + 1, supersedesFactID: third.id,
            lifecycleState: .active
        )
        let restorer = MemoryProposalConsumer(store: afterForget)
        #expect(throws: MemoryProposalConsumerError.restoreConflict) {
            _ = try restorer.restoreFacts(
                [staleChild], within: scope, mode: .merge,
                reason: "synthetic stale child after forget"
            )
        }
        #expect(try Data(contentsOf: afterForget.fileURL) == beforeRestore)
        #expect(try afterForget.lifecycleReceipts() == receiptsBeforeRestore)
        #expect(try afterForget.activeFacts().isEmpty)
        #expect(try MemoryInjector(store: afterForget).systemPrompt(
            base: "base", userMessage: "orbit2235", memoryScope: scope
        ) == "base")
        #expect(try afterForget.facts().count == 3)
        #expect(try afterForget.lifecycleReceipts().map(\.action) == [.rollback, .tombstone])
    }
}
