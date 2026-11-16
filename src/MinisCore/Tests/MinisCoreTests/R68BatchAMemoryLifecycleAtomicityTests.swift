import Foundation
import Testing
@testable import MinisCore

@Suite("R68 Batch A memory lifecycle transaction recovery")
struct R68BatchAMemoryLifecycleAtomicityTests {
    @Test func rollbackRecoversAfterReceiptWriteBoundaryFailure() throws {
        try assertRecovery(action: .rollback)
    }

    @Test func tombstoneRecoversAfterReceiptWriteBoundaryFailure() throws {
        try assertRecovery(action: .tombstone)
    }

    @Test func corruptTransactionJournalFailsClosedWithoutChangingFacts() throws {
        let directory = try makeDirectory("corrupt-journal")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MemoryStore(directory: directory)
        _ = try store.addFact(id: "fact-1", text: "keep")
        let factsBefore = try Data(contentsOf: store.fileURL)
        try FileManager.default.createDirectory(
            at: store.lifecycleTransactionURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(
            to: store.lifecycleTransactionURL,
            options: .atomic
        )

        let restarted = MemoryStore(directory: directory)
        #expect(throws: MemoryStoreError.concurrentMutation) {
            try restarted.facts()
        }
        #expect(try Data(contentsOf: restarted.fileURL) == factsBefore)
        #expect(
            FileManager.default.fileExists(
                atPath: restarted.lifecycleTransactionURL.path
            )
        )
    }

    @Test func divergentStateDoesNotGetOverwrittenByRecovery() throws {
        let directory = try makeDirectory("divergent-state")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = MemoryLifecycleFaultBox()
        let writer = MemoryStore(
            directory: directory,
            lifecycleTransactionFaultInjector: { point in
                try fault.inject(at: point)
            }
        )
        _ = try writer.addFact(id: "fact-1", text: "original")

        #expect(throws: MemoryLifecycleInjectedError.afterFactsPersisted) {
            try writer.tombstoneFact(id: "fact-1", reason: "remove")
        }

        let divergent = [
            MemoryFact(id: "fact-2", text: "concurrent replacement")
        ]
        let divergentBytes = try JSONEncoder().encode(divergent)
        try divergentBytes.write(to: writer.fileURL, options: .atomic)

        let restarted = MemoryStore(directory: directory)
        #expect(throws: MemoryStoreError.concurrentMutation) {
            try restarted.facts()
        }
        #expect(try Data(contentsOf: restarted.fileURL) == divergentBytes)
        #expect(
            FileManager.default.fileExists(
                atPath: restarted.lifecycleTransactionURL.path
            )
        )
    }

    @Test func approvedRevisionRecoversFactsAndReplayTogether2979() throws {
        let directory = try makeDirectory("approved-revision2979")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = MemoryLifecycleFaultBox()
        let writer = MemoryStore(directory: directory, lifecycleTransactionFaultInjector: {
            try fault.inject(at: $0)
        })
        let scope = MemoryScope(sessionID: "session2979", projectID: "project2979")
        let original = try writer.addFact(id: "original2979", text: "before2979", memoryScope: scope)
        let revision = try writer.bl6MemoryRevision(within: scope)
        let key = "memory.fact.\(original.id)"
        let input = BL6SettingsApprovedInput(operation: .apply,
            changes: [key: .object(["text": .text("after2979"), "active": .toggle(true)])],
            expectedRevision: revision)
        let makeRecord: BL6MemoryReplayRecordFactory = { before, _, beforeFacts, afterFacts in
            #expect(before == original)
            let receipt = BL6SettingsReceipt(requestID: "request2979", operation: .apply,
                previousRevision: try MemoryStore.bl6MemoryRevision(facts: beforeFacts, within: scope),
                effectiveRevision: try MemoryStore.bl6MemoryRevision(facts: afterFacts, within: scope),
                changedKeys: [key], rollbackValues: [:])
            return BL6SettingsReplayRecord(requestID: receipt.requestID, payloadDigest: "synthetic-store2979",
                frozenInput: input, approvalBindingDigest: "synthetic-binding2979",
                profileID: directory.path, scope: "request", sessionID: scope.sessionID,
                policyRevision: "policy2979", grantEpoch: "epoch2979",
                approvalExpiresAt: Date().addingTimeInterval(60), operation: .apply,
                receipt: receipt, rollbackValues: [:])
        }
        #expect(throws: MemoryLifecycleInjectedError.afterFactsPersisted) {
            try writer.appendRevision(to: original.id, id: "successor2979", text: "after2979",
                sourceProposalID: "user-edit:original2979:r2", sourceRef: "settings://memory/original2979/revision-2",
                contentDigest: MemoryStore.contentDigest(for: "after2979"),
                makeSettingsReplayRecord: makeRecord)
        }
        #expect(FileManager.default.fileExists(atPath: writer.lifecycleTransactionURL.path))
        let reopened = MemoryStore(directory: directory)
        let replay = try #require(try reopened.bl6MemoryReplayRecord(for: "request2979", profileID: directory.path))
        #expect(replay.before == original && replay.after.id == "successor2979")
        #expect(try reopened.activeFacts().map(\.id) == ["successor2979"])
        let factBytes = try Data(contentsOf: reopened.fileURL)
        let receiptBytes = try Data(contentsOf: reopened.lifecycleReceiptURL)
        #expect(try reopened.replayBL6MemoryRecord(replay, profileID: directory.path) == replay.settings.receipt)
        #expect(try Data(contentsOf: reopened.fileURL) == factBytes)
        #expect(try Data(contentsOf: reopened.lifecycleReceiptURL) == receiptBytes)
        #expect(!FileManager.default.fileExists(atPath: reopened.lifecycleTransactionURL.path))
    }

    private func assertRecovery(action: MemoryFactLifecycleAction) throws {
        let directory = try makeDirectory(action.rawValue)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = MemoryLifecycleFaultBox()
        let writer = MemoryStore(
            directory: directory,
            lifecycleTransactionFaultInjector: { point in
                try fault.inject(at: point)
            }
        )
        _ = try writer.addFact(id: "fact-1", text: "transactional fact")

        #expect(throws: MemoryLifecycleInjectedError.afterFactsPersisted) {
            switch action {
            case .rollback:
                _ = try writer.rollbackFact(id: "fact-1", reason: "same reason")
            case .tombstone:
                _ = try writer.tombstoneFact(id: "fact-1", reason: "same reason")
            case .revision:
                throw MemoryStoreError.invalidLifecycleState
            }
        }
        #expect(
            FileManager.default.fileExists(
                atPath: writer.lifecycleTransactionURL.path
            )
        )
        let splitFacts = try JSONDecoder().decode(
            [MemoryFact].self,
            from: Data(contentsOf: writer.fileURL)
        )
        #expect(
            splitFacts.first?.lifecycleState
                == (action == .rollback ? .rolledBack : .tombstoned)
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: writer.lifecycleReceiptURL.path
            )
        )

        let restarted = MemoryStore(directory: directory)
        let recoveredReceipt = try #require(
            restarted.lifecycleReceipts().first
        )
        #expect(recoveredReceipt.action == action)
        #expect(recoveredReceipt.reason == "same reason")
        #expect(
            !FileManager.default.fileExists(
                atPath: restarted.lifecycleTransactionURL.path
            )
        )
        let factsAfterRecovery = try Data(contentsOf: restarted.fileURL)
        let receiptsAfterRecovery = try Data(
            contentsOf: restarted.lifecycleReceiptURL
        )

        let duplicate: MemoryFactLifecycleReceipt
        switch action {
        case .rollback:
            duplicate = try restarted.rollbackFact(
                id: "fact-1",
                reason: "same reason"
            )
        case .tombstone:
            duplicate = try restarted.tombstoneFact(
                id: "fact-1",
                reason: "same reason"
            )
        case .revision:
            throw MemoryStoreError.invalidLifecycleState
        }
        #expect(duplicate == recoveredReceipt)
        #expect(try Data(contentsOf: restarted.fileURL) == factsAfterRecovery)
        #expect(
            try Data(contentsOf: restarted.lifecycleReceiptURL)
                == receiptsAfterRecovery
        )
    }

    private func makeDirectory(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "R68-BatchA-MemoryLifecycle-\(name)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}

private final class MemoryLifecycleFaultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = true

    func inject(at point: MemoryLifecycleTransactionFaultPoint) throws {
        guard point == .afterFactsPersisted else { return }
        let shouldFail = lock.withLock {
            defer { pending = false }
            return pending
        }
        if shouldFail {
            throw MemoryLifecycleInjectedError.afterFactsPersisted
        }
    }
}

private enum MemoryLifecycleInjectedError: Error, Equatable {
    case afterFactsPersisted
}
