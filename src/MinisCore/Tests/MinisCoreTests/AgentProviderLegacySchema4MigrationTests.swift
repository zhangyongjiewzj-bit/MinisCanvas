import CryptoKit
import Foundation
import Testing
@testable import MinisCore

// These fixture bytes came from the old production API in a synthetic root.
// The test never links or reads the old AgentProvider implementation.
@Suite("AgentProviderLegacySchema4MigrationTests", .serialized)
struct AgentProviderLegacySchema4MigrationTests {
    private func source(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/LegacySchema4/\(name).v4.json")
    }

    private func journal(_ name: String) throws -> (root: URL, url: URL, original: Data) {
        let isolation = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = isolation.rootDirectory.appendingPathComponent("legacy-schema4-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try Data(contentsOf: source(name))
        let url = root.appendingPathComponent("facts.json")
        try data.write(to: url)
        return (root, url, data)
    }

    // Regression A was a real corruptLedger RED at baseline df5b8a8.
    // Its compatibility assertion is unchanged after the approved reader fix.
    @Test("Empty legacy schema 4 without the later write-tracking field remains loadable")
    func emptyLegacyMissingUnstartedFieldIsLoadable() throws {
        try requireEmptyLegacyLedger("empty_missing_unstarted")
    }

    // Control B differs only by the explicit empty write-tracking map.
    @Test("Empty legacy schema 4 with explicit empty write tracking is loadable")
    func emptyLegacyExplicitUnstartedFieldIsLoadable() throws {
        try requireEmptyLegacyLedger("empty_explicit_unstarted")
    }

    @Test("Missing legacy write tracking preserves real synthetic facts, queued identity and order")
    func missingUnstartedFieldPreservesFactsAndOrder() throws {
        let (root, url, original) = try journal("completed_plus_queued_missing_unstarted")
        defer { try? FileManager.default.removeItem(at: root) }
        let document = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        let oldOrder = try #require(document["order"] as? [String])
        // Decode only public record types from the synthetic source fixture.
        // The public ledger, not this test, implements schema migration.
        let originalFacts = try JSONDecoder().decode([String: ToolExecutionFact].self,
            from: JSONSerialization.data(withJSONObject: try #require(document["facts"])))
        let originalPending = try JSONDecoder().decode([String: ToolExecutionReceipt].self,
            from: JSONSerialization.data(withJSONObject: try #require(document["pending"])))
        let expectedFacts = oldOrder.compactMap { originalFacts[$0] }
        let expectedPending = oldOrder.compactMap { originalPending[$0] }
        let expectedOrder = try oldOrder.map { oldKey in
            try #require(originalFacts[oldKey]?.compositeKey ?? originalPending[oldKey]?.compositeKey).rawValue
        }
        let ledger = try ToolExecutionFactLedger(persistenceURL: url)
        #expect(ledger.facts.count == originalFacts.count)
        #expect(ledger.pendingReceipts.count == originalPending.count)
        #expect(ledger.facts == expectedFacts)
        #expect(ledger.pendingReceipts == expectedPending)
        #expect(ledger.recoveredPendingReceipts == expectedPending)
        let migrated = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(migrated["schemaVersion"] as? Int == 6)
        #expect(migrated["order"] as? [String] == expectedOrder)
    }

    @Test("Explicit null legacy write tracking stays corrupt and preserves original bytes")
    func explicitNullUnstartedFieldRemainsCorrupt() throws {
        let (root, url, original) = try journal("empty_explicit_unstarted")
        defer { try? FileManager.default.removeItem(at: root) }
        var document = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        document["unstartedFileWrites"] = NSNull()
        let bytes = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        try bytes.write(to: url)
        #expect(throws: ToolExecutionFactLedgerError.corruptLedger) {
            _ = try ToolExecutionFactLedger(persistenceURL: url)
        }
        #expect(try Data(contentsOf: url) == bytes)
    }

    private func requireEmptyLegacyLedger(_ fixtureName: String) throws {
        let (root, url, _) = try journal(fixtureName)
        defer { try? FileManager.default.removeItem(at: root) }
        // The real public API owns decode, validation and migration. This test
        // does not copy its decoder or instantiate any production ledger URL.
        let ledger = try ToolExecutionFactLedger(persistenceURL: url)
        #expect(ledger.facts.isEmpty)
        #expect(ledger.pendingReceipts.isEmpty)
        #expect(ledger.recoveredPendingReceipts.isEmpty)
    }

    private func identity(_ message: String) -> AgentExecutionIdentity {
        AgentExecutionIdentity(
            turn: AgentTurnIdentity(sessionID: "task2588-synthetic-session", turnID: 7,
                                    messageID: message),
            operationID: "task2588-synthetic-operation", attempt: 1)
    }

    @Test("Old settled facts and queued receipts survive rekey and writer takeover")
    func completedAndQueued() throws {
        let (root, url, _) = try journal("completed_plus_queued")
        defer { try? FileManager.default.removeItem(at: root) }
        let migrated = try ToolExecutionFactLedger(persistenceURL: url)
        let fact = try #require(migrated.facts.first)
        let pending = try #require(migrated.recoveredPendingReceipts.first)
        #expect(migrated.facts.count == 1 && migrated.pendingReceipts == [pending])
        #expect(fact.receiptID == "15692F71-4F42-4A9D-9856-D804A5484EFA")
        #expect(fact.status == .succeeded)
        #expect(migrated.fact(compositeKey: try #require(fact.compositeKey),
                              receiptID: fact.receiptID) == fact)
        #expect(pending.receiptID == "BEE778F2-816F-41FA-88AA-CAD85B803149")
        #expect(throws: ToolExecutionFactLedgerError.externalOutcomeUnverified) {
            try migrated.reconcilePending()
        }
        #expect(throws: ToolExecutionFactLedgerError.duplicateToolCallID("completed-search")) {
            _ = try migrated.mint(toolCallID: "completed-search", toolName: "web_search",
                attemptID: "task2588-attempt", attemptNumber: 1,
                executionIdentity: identity("completed-message"))
        }
        #expect(throws: ToolExecutionFactLedgerError.duplicateToolCallID("queued-search")) {
            _ = try migrated.mint(toolCallID: "queued-search", toolName: "web_search",
                attemptID: "task2588-attempt", attemptNumber: 1,
                executionIdentity: identity("queued-message"))
        }
        let settlement = try migrated.settle(pending, status: .failed)
        let settled = try #require(settlement)
        #expect(settled.receiptID == pending.receiptID && settled.status == .failed)
        let reopened = try ToolExecutionFactLedger(persistenceURL: url)
        #expect(reopened.pendingReceipts.isEmpty && reopened.facts.count == 2)
        #expect(reopened.fact(compositeKey: try #require(settled.compositeKey),
                              receiptID: settled.receiptID) == settled)
        #expect(throws: ToolExecutionFactLedgerError.staleWriter) {
            _ = try migrated.mint(toolCallID: "after-takeover", toolName: "web_search",
                attemptID: "task2588-attempt", attemptNumber: 1,
                executionIdentity: identity("new-message"))
        }
    }

    @Test("Old dispatched file write stays unknown without receipt completion")
    func incompleteFileWrite() throws {
        let (root, url, original) = try journal("file_write_dispatched")
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("same-bytes-from-other-writer.txt")
        let otherWriterContent = Data("matching bytes from an unrelated writer\n".utf8)
        try otherWriterContent.write(to: target)
        let digest = SHA256.hash(data: otherWriterContent).map { String(format: "%02x", $0) }.joined()
        // Derive one input from the old fixture to prove that matching bytes
        // alone cannot turn an incomplete old receipt into a success fact.
        var document = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var writes = try #require(document["pendingFileWrites"] as? [String: [String: Any]])
        let key = try #require(writes.keys.first)
        var write = try #require(writes[key])
        write["targetPath"] = target.path
        write["expectedSHA256"] = digest
        writes[key] = write
        document["pendingFileWrites"] = writes
        try JSONSerialization.data(withJSONObject: document).write(to: url)
        let migrated = try ToolExecutionFactLedger(persistenceURL: url)
        let receipt = try #require(migrated.recoveredPendingReceipts.first)
        let evidence = try #require(migrated.pendingFileWriteEvidence(for: receipt))
        #expect(evidence.receiptID == receipt.receiptID)
        #expect(evidence.expectedSHA256 == digest)
        #expect(evidence.completedSHA256 == nil)
        let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        #expect(executor.queryRecoveredFileWrite(receipt, ledger: migrated) == .unknown)
        #expect(migrated.facts.isEmpty && migrated.pendingReceipts == [receipt])
        #expect(!migrated.fileWriteWasNeverDispatched(receipt))
    }

    @Test("Old entered-only file write remains visibly unstarted")
    func enteredFileWrite() throws {
        let (root, url, _) = try journal("file_write_entered")
        defer { try? FileManager.default.removeItem(at: root) }
        let migrated = try ToolExecutionFactLedger(persistenceURL: url)
        let receipt = try #require(migrated.recoveredPendingReceipts.first)
        #expect(migrated.fileWriteWasNeverDispatched(receipt))
        let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        #expect(executor.queryRecoveredFileWrite(receipt, ledger: migrated) == .notExecuted)
        #expect(migrated.pendingReceipts == [receipt] && migrated.facts.isEmpty)
    }

    @Test("Old completed pending file write reconciles only with its own content")
    func completedPendingFileWrite() throws {
        let (root, url, original) = try journal("file_write_completed_pending")
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("synthetic-written.txt")
        let exactContent = Data("task2588 synthetic file bytes\n".utf8)
        try exactContent.write(to: target)
        let canonicalTarget = try canonicalOwnedFixtureURL2588(target)
        // Only relocate the synthetic target into the formal isolated root;
        // the receipt, canonical identity, and completion digest stay intact.
        var document = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var writes = try #require(document["pendingFileWrites"] as? [String: [String: Any]])
        let key = try #require(writes.keys.first)
        var write = try #require(writes[key])
        write["targetPath"] = canonicalTarget.path
        writes[key] = write
        document["pendingFileWrites"] = writes
        try JSONSerialization.data(withJSONObject: document).write(to: url)

        let migrated = try ToolExecutionFactLedger(persistenceURL: url)
        let receipt = try #require(migrated.recoveredPendingReceipts.first { $0.toolName == "file_write" })
        let evidence = try #require(migrated.pendingFileWriteEvidence(for: receipt))
        #expect(evidence.completedSHA256 == evidence.expectedSHA256)
        let executor = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        guard case .succeeded(let fact) = executor.queryRecoveredFileWrite(receipt, ledger: migrated) else {
            Issue.record("old completed receipt was not attributed to its own exact bytes")
            return
        }
        #expect(fact.receiptID == receipt.receiptID && fact.status == .succeeded)
        let reopened = try ToolExecutionFactLedger(persistenceURL: url)
        #expect(reopened.fact(compositeKey: try #require(fact.compositeKey),
                              receiptID: fact.receiptID) == fact)
        #expect(reopened.pendingReceipts.allSatisfy { $0.receiptID != receipt.receiptID })
    }

    @Test("Old settled file-write fact remains an exact fact after migration")
    func settledFileWrite() throws {
        let (root, url, _) = try journal("file_write_settled")
        defer { try? FileManager.default.removeItem(at: root) }
        let migrated = try ToolExecutionFactLedger(persistenceURL: url)
        let firstDisk = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(firstDisk["schemaVersion"] as? Int == 6)
        #expect(firstDisk["fence"] as? Int == 10)
        let fileFact = try #require(migrated.facts.first { $0.toolName == "file_write" })
        #expect(fileFact.receiptID == "6804A4A2-D36F-4CDD-802F-640731CEA6CA")
        #expect(fileFact.status == .succeeded && fileFact.outputSummary != nil)
        #expect(migrated.fact(compositeKey: try #require(fileFact.compositeKey),
                              receiptID: fileFact.receiptID) == fileFact)
        #expect(migrated.pendingReceipts.count == 1)
        _ = try ToolExecutionFactLedger(persistenceURL: url)
        let secondDisk = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(secondDisk["fence"] as? Int == 11)
        #expect(firstDisk["writerID"] as? String != secondDisk["writerID"] as? String)
    }

    @Test("Invalid old version or identity leaves exact original bytes untouched")
    func invalidOldStatePreservesBytes() throws {
        let (root, url, original) = try journal("completed_plus_queued")
        defer { try? FileManager.default.removeItem(at: root) }
        let base = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var invalid: [[String: Any]] = []
        var unknownVersion = base
        unknownVersion["schemaVersion"] = 400
        invalid.append(unknownVersion)
        var mislabeledVersion = base
        mislabeledVersion["schemaVersion"] = 6
        invalid.append(mislabeledVersion)
        var missingOrder = base
        missingOrder["order"] = ["missing-key"]
        invalid.append(missingOrder)
        var conflicting = base
        conflicting["pending"] = base["facts"]
        invalid.append(conflicting)
        var badIdentity = base
        var facts = try #require(base["facts"] as? [String: [String: Any]])
        let key = try #require(facts.keys.first)
        var fact = try #require(facts[key])
        fact["toolCallID"] = "different-call"
        facts[key] = fact
        badIdentity["facts"] = facts
        invalid.append(badIdentity)
        var hiddenField = base
        var hiddenFacts = try #require(base["facts"] as? [String: [String: Any]])
        var hiddenFact = try #require(hiddenFacts[key])
        hiddenFact["unrecognizedAuthority"] = "must-not-drop"
        hiddenFacts[key] = hiddenFact
        hiddenField["facts"] = hiddenFacts
        invalid.append(hiddenField)
        for candidate in invalid {
            let bytes = try JSONSerialization.data(withJSONObject: candidate, options: [.sortedKeys])
            try bytes.write(to: url)
            #expect(throws: ToolExecutionFactLedgerError.corruptLedger) {
                _ = try ToolExecutionFactLedger(persistenceURL: url)
            }
            #expect(try Data(contentsOf: url) == bytes)
        }
        let truncated = Data(#"{"schemaVersion":4,"pending":{unchecked"#.utf8)
        try truncated.write(to: url)
        #expect(throws: ToolExecutionFactLedgerError.corruptLedger) {
            _ = try ToolExecutionFactLedger(persistenceURL: url)
        }
        #expect(try Data(contentsOf: url) == truncated)
    }
}

// Formal test roots may use a data-volume spelling that Foundation does not
// preserve in canonical policy URLs or enumerated child URL components.
// Normalize only this already-created owned fixture object; never a production
// allow-root or runner environment. Refuse any physical identity change.
private func canonicalOwnedFixtureURL2588(_ raw: URL) throws -> URL {
    let canonical = raw.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    let before = try FileManager.default.attributesOfItem(atPath: raw.path)
    let after = try FileManager.default.attributesOfItem(atPath: canonical.path)
    for key in [FileAttributeKey.systemNumber, .systemFileNumber, .ownerAccountID] {
        guard let original = before[key] as? NSNumber,
              let resolved = after[key] as? NSNumber,
              original == resolved else {
            throw NSError(domain: "MinisCanvas.OwnedFixtureCanonicalIdentity", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Fixture canonicalization changed device, inode or owner"])
        }
    }
    let metadata: [String: Any] = [
        "event": "CORE424_OWNED_FIXTURE_CANONICAL_IDENTITY",
        "helper": "canonicalOwnedFixtureURL2588",
        "sampling_point": "after_identity_guard_before_return",
        "sampled_at_epoch": Date().timeIntervalSince1970,
        "original_path": raw.path,
        "stable_path": canonical.path,
        "before": ["device": before[.systemNumber]!,
                   "inode": before[.systemFileNumber]!,
                   "UID": before[.ownerAccountID]!],
        "after": ["device": after[.systemNumber]!,
                  "inode": after[.systemFileNumber]!,
                  "UID": after[.ownerAccountID]!]
    ]
    let encoded = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
    print("CORE424_FIXTURE_METADATA " + String(decoding: encoded, as: UTF8.self))
    return canonical
}
