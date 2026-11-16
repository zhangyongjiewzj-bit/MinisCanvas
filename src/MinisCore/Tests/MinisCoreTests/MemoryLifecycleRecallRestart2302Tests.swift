import Foundation
import Testing
@testable import MinisCore

struct MemoryLifecycleRecallRestart2302Tests {
    @Test func supersedeAndTombstoneKeepHistoryButChangeBothRecallConsumersAfterRestart() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory2302-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let scope = MemoryScope(sessionID: "owned-session", projectID: "owned-project")
        let originalText = "orbit2302 original preference"
        let revisedText = "orbit2302 revised preference"
        let independentText = "orbit2302 independent fact"
        let store = MemoryStore(directory: root)
        let original = try store.addFact(
            id: "orbit2302-r1", text: originalText,
            sourceSessionID: scope.sessionID, memoryScope: scope,
            sourceProposalID: "orbit2302-p1", sourceRef: "synthetic://turn-1",
            contentDigest: MemoryStore.contentDigest(for: originalText)
        )
        let revised = try store.appendRevision(
            to: original.id, id: "orbit2302-r2", text: revisedText,
            sourceSessionID: scope.sessionID, memoryScope: scope,
            sourceProposalID: "orbit2302-p2", sourceRef: "synthetic://turn-2",
            contentDigest: MemoryStore.contentDigest(for: revisedText)
        )
        let independent = try store.addFact(
            id: "orbit2302-other", text: independentText,
            sourceSessionID: scope.sessionID, memoryScope: scope,
            sourceProposalID: "orbit2302-p3", sourceRef: "synthetic://turn-3",
            contentDigest: MemoryStore.contentDigest(for: independentText)
        )

        let beforeRestart = MemoryStore(directory: root)
        let beforeDisplay = try MemorySearchDisplayConsumer(
            search: MemorySearch(store: beforeRestart)
        ).retrieve(keyword: "orbit2302", scope: .session(scope))
        #expect(Set(beforeDisplay.items.map(\.factID)) == [revised.id, independent.id])
        #expect(!beforeDisplay.items.contains { $0.factID == original.id })
        let beforePrompt = try MemoryInjector(store: beforeRestart).systemPrompt(
            base: "base", userMessage: "orbit2302", memoryScope: scope
        )
        #expect(beforePrompt.contains(revisedText))
        #expect(beforePrompt.contains(independentText))
        #expect(!beforePrompt.contains(originalText))

        _ = try beforeRestart.tombstoneFact(id: revised.id, reason: "synthetic forget")
        let afterRestart = MemoryStore(directory: root)
        let history = try afterRestart.facts()
        #expect(history.count == 3)
        #expect(history.first { $0.id == original.id }?.lifecycleState == .superseded)
        #expect(history.first { $0.id == original.id }?.sourceRef == "synthetic://turn-1")
        #expect(history.first { $0.id == revised.id }?.lifecycleState == .tombstoned)
        #expect(history.first { $0.id == revised.id }?.supersedesFactID == original.id)
        #expect(history.first { $0.id == revised.id }?.sourceProposalID == "orbit2302-p2")
        #expect(try afterRestart.lifecycleReceipts().map(\.action) == [.tombstone])

        let afterDisplay = try MemorySearchDisplayConsumer(
            search: MemorySearch(store: afterRestart)
        ).retrieve(keyword: "orbit2302", scope: .session(scope))
        #expect(afterDisplay.items.map(\.factID) == [independent.id])
        #expect(afterDisplay.items.first?.sourceRef == "synthetic://turn-3")
        let nextTurnPrompt = try MemoryInjector(store: afterRestart).systemPrompt(
            base: "base", userMessage: "orbit2302", memoryScope: scope
        )
        #expect(nextTurnPrompt.contains(independentText))
        #expect(!nextTurnPrompt.contains(revisedText))
        #expect(!nextTurnPrompt.contains(originalText))
        #expect(try afterRestart.activeFacts().map(\.id) == [independent.id])
    }
}
