import Foundation
import Testing
@testable import MinisCore

@Suite("Tool lifecycle consumer")
struct ToolLifecycleConsumerTests {
    @Test("durable projection reload preserves canonical identity and sequence")
    func durableProjectionReloads() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let consumer = try ToolLifecycleConsumer(persistenceURL: url)
        let first = makeFact(
            toolCallID: "call-one",
            receiptID: "receipt-one",
            status: .succeeded
        )
        #expect(consumer.isDurable)
        #expect(await consumer.ingestToolExecutionFact(
            first,
            eventID: "call-one",
            eventName: "file_read",
            taskID: "task-one",
            expectedAttemptID: "attempt-one",
            scopeID: "scope-one",
            occurredAt: Date(timeIntervalSince1970: 1)
        ))

        let reloaded = try ToolLifecycleConsumer(persistenceURL: url)
        #expect(reloaded.events.count == 1)
        #expect(reloaded.events.first?.id == "receipt-one")
        #expect(reloaded.events.first?.toolCallID == "call-one")
        #expect(reloaded.events.first?.receiptID == "receipt-one")
        #expect(reloaded.events.first?.sequence == 1)

        let second = makeFact(
            toolCallID: "call-two",
            receiptID: "receipt-two",
            status: .failed
        )
        #expect(await reloaded.ingestToolExecutionFact(
            second,
            eventID: "call-two",
            eventName: "file_read",
            taskID: "task-one",
            expectedAttemptID: "attempt-one",
            scopeID: "scope-one",
            occurredAt: Date(timeIntervalSince1970: 2)
        ))
        #expect(reloaded.events.map(\.sequence) == [1, 2])
    }

    @Test("schema one snapshot compaction and truncated journal tail recover")
    func schemaOneCompactionAndTruncatedJournalRecover() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let journalURL = url.deletingPathExtension().appendingPathExtension("journal")
        let consumer = try ToolLifecycleConsumer(
            persistenceURL: url,
            compactionInterval: 2
        )

        for index in 1...2 {
            #expect(await consumer.ingestToolExecutionFact(
                makeFact(
                    toolCallID: "compact-call-\(index)",
                    receiptID: "compact-receipt-\(index)",
                    status: .succeeded
                ),
                eventID: "compact-call-\(index)",
                eventName: "file_read",
                taskID: "task-one",
                expectedAttemptID: "attempt-one",
                scopeID: "scope-one"
            ))
        }
        let snapshot = try Data(contentsOf: url)
        let snapshotObject = try #require(
            JSONSerialization.jsonObject(with: snapshot) as? [String: Any]
        )
        #expect(snapshotObject["schemaVersion"] as? Int == 1)
        #expect((snapshotObject["events"] as? [Any])?.count == 2)
        #expect((try? Data(contentsOf: journalURL))?.isEmpty == true)

        let third = makeFact(
            toolCallID: "compact-call-3",
            receiptID: "compact-receipt-3",
            status: .succeeded
        )
        #expect(await consumer.ingestToolExecutionFact(
            third,
            eventID: "compact-call-3",
            eventName: "file_read",
            taskID: "task-one",
            expectedAttemptID: "attempt-one",
            scopeID: "scope-one"
        ))
        let partial = Data("{\"schemaVersion\":1,\"event\":".utf8)
        if FileManager.default.fileExists(atPath: journalURL.path) {
            let handle = try FileHandle(forWritingTo: journalURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: partial)
        } else {
            try partial.write(to: journalURL, options: [.atomic])
        }

        let reloaded = try ToolLifecycleConsumer(
            persistenceURL: url,
            compactionInterval: 2
        )
        #expect(reloaded.events.count == 3)
        #expect(reloaded.events.last?.receiptID == "compact-receipt-3")
    }

    @Test("recovered truncated tail permits durable append and another read-only reopen")
    func truncatedTailRecoveryCanAppendAndReopen() async throws {
        let url = temporaryURL()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("journal"))
        }
        let journalURL = url.deletingPathExtension().appendingPathExtension("journal")
        let consumer = try ToolLifecycleConsumer(persistenceURL: url, compactionInterval: 100)
        let first = makeFact(toolCallID: "tail-call-one", receiptID: "tail-receipt-one", status: .succeeded)
        #expect(await consumer.ingestToolExecutionFact(
            first, eventID: "tail-call-one", eventName: "file_read", taskID: "task-one",
            expectedAttemptID: "attempt-one", scopeID: "scope-one"
        ))
        let trustedPrefix = try Data(contentsOf: journalURL)
        let handle = try FileHandle(forWritingTo: journalURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"schemaVersion\":1,\"event\":".utf8))
        try handle.close()

        let reopened = try ToolLifecycleConsumer(persistenceURL: url, compactionInterval: 100)
        #expect(reopened.events == consumer.events)
        #expect(try Data(contentsOf: journalURL) == trustedPrefix)
        let second = makeFact(toolCallID: "tail-call-two", receiptID: "tail-receipt-two", status: .succeeded)
        #expect(await reopened.ingestToolExecutionFact(
            second, eventID: "tail-call-two", eventName: "file_read", taskID: "task-one",
            expectedAttemptID: "attempt-one", scopeID: "scope-one"
        ))
        let durable = try Data(contentsOf: journalURL)
        let again = try ToolLifecycleConsumer(persistenceURL: url, compactionInterval: 100)
        #expect(again.events.map(\.sequence) == [1, 2])
        #expect(again.events.map(\.receiptID) == ["tail-receipt-one", "tail-receipt-two"])
        #expect(again.events == reopened.events)
        #expect(try Data(contentsOf: journalURL) == durable)
    }

    @Test(arguments: ["middle-json", "future-schema", "unknown-kind", "invalid-projection"])
    func rejectedPrefixWithTornTailPreservesOriginalEvidence(_ corruption: String) async throws {
        let url = temporaryURL()
        let journalURL = url.deletingPathExtension().appendingPathExtension("journal")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: journalURL)
        }
        let consumer = try ToolLifecycleConsumer(persistenceURL: url, compactionInterval: 100)
        let fact = makeFact(toolCallID: "rejected-tail", receiptID: "rejected-receipt", status: .succeeded)
        #expect(await consumer.ingestToolExecutionFact(
            fact, eventID: "rejected-tail", eventName: "file_read", taskID: "task-one",
            expectedAttemptID: "attempt-one", scopeID: "scope-one"
        ))
        var record = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [String: Any])
        var event = try #require(record["event"] as? [String: Any])
        switch corruption {
        case "future-schema": record["schemaVersion"] = 99
        case "unknown-kind": event["kind"] = "unrecognized-required-event"
        case "invalid-projection": event["id"] = ""
        case "middle-json": break
        default: Issue.record("Unknown corruption fixture"); return
        }
        record["event"] = event
        var corrupted = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        corrupted.append(0x0A)
        if corruption == "middle-json" { corrupted.append(Data("not-json\n".utf8)) }
        corrupted.append(Data("{\"schemaVersion\":".utf8))
        try corrupted.write(to: journalURL)

        #expect(throws: ToolLifecycleConsumerError.corruptPersistence) {
            _ = try ToolLifecycleConsumer(persistenceURL: url, compactionInterval: 100)
        }
        #expect(try Data(contentsOf: journalURL) == corrupted)
    }

    @Test(arguments: ["gap", "duplicate", "reversed", "zero", "negative", "huge", "snapshot-gap"])
    func rawJournalSequenceCorruptionRejectsBeforeTailRepair(_ corruption: String) async throws {
        let url = temporaryURL()
        let journalURL = url.deletingPathExtension().appendingPathExtension("journal")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: journalURL)
        }
        let consumer = try ToolLifecycleConsumer(
            persistenceURL: url, compactionInterval: corruption == "snapshot-gap" ? 3 : 100
        )
        for index in 1...5 {
            let fact = makeFact(toolCallID: "sequence-call-\(index)", receiptID: "sequence-receipt-\(index)", status: .succeeded)
            #expect(await consumer.ingestToolExecutionFact(
                fact, eventID: fact.toolCallID, eventName: "file_read", taskID: "task-one",
                expectedAttemptID: "attempt-one", scopeID: "scope-one"
            ))
        }
        let snapshotBefore = try? Data(contentsOf: url)
        let lines = try Data(contentsOf: journalURL).split(separator: 0x0A)
        var records = try lines.map { try #require(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]) }
        func changeSequence(at index: Int, to sequence: Int64) throws {
            var event = try #require(records[index]["event"] as? [String: Any])
            event["sequence"] = sequence
            records[index]["event"] = event
        }
        switch corruption {
        case "gap": try changeSequence(at: 1, to: 3)
        case "duplicate": try changeSequence(at: 1, to: 1)
        case "reversed": records.swapAt(1, 2)
        case "zero": try changeSequence(at: 0, to: 0)
        case "negative": try changeSequence(at: 0, to: -1)
        case "huge": try changeSequence(at: 0, to: Int64.max)
        case "snapshot-gap":
            try changeSequence(at: 0, to: 5)
            try changeSequence(at: 1, to: 6)
        default: Issue.record("Unknown sequence corruption fixture"); return
        }
        var corrupted = Data()
        for record in records {
            corrupted.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
            corrupted.append(0x0A)
        }
        corrupted.append(Data("{\"schemaVersion\":1,\"event\":".utf8))
        try corrupted.write(to: journalURL)

        #expect(throws: ToolLifecycleConsumerError.corruptPersistence) {
            _ = try ToolLifecycleConsumer(persistenceURL: url, compactionInterval: 100)
        }
        #expect(try Data(contentsOf: journalURL) == corrupted)
        #expect((try? Data(contentsOf: url)) == snapshotBefore)
    }

    @Test(arguments: [false, true])
    func foldedSnapshotAndRetainedPrefixPermitContinuousSuffix(_ retainedPrefix: Bool) async throws {
        let url = temporaryURL()
        let journalURL = url.deletingPathExtension().appendingPathExtension("journal")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: journalURL)
        }
        let consumer = try ToolLifecycleConsumer(persistenceURL: url, compactionInterval: 3)
        let first = makeFact(toolCallID: "folded-one", receiptID: "folded-receipt-one", status: .succeeded)
        for phase in [ToolExecutionPhase.queued, .running] {
            #expect(await consumer.ingestToolExecutionPhase(
                ToolExecutionPhaseFact(compositeKey: try #require(first.compositeKey), executionIdentity: try #require(first.executionIdentity),
                    toolName: first.toolName, phase: phase, occurredAt: Date(timeIntervalSince1970: 1)),
                eventID: first.toolCallID, eventName: "file_read", taskID: "task-one",
                expectedAttemptID: "attempt-one", scopeID: "scope-one"
            ))
        }
        var prefix = try Data(contentsOf: journalURL)
        #expect(await consumer.ingestToolExecutionFact(
            first, eventID: first.toolCallID, eventName: "file_read", taskID: "task-one",
            expectedAttemptID: "attempt-one", scopeID: "scope-one"
        ))
        #expect(consumer.events.map(\.sequence) == [3])
        let snapshotBytes = try Data(contentsOf: url)
        let snapshot = try #require(JSONSerialization.jsonObject(with: snapshotBytes) as? [String: Any])
        let snapshotEvents = try #require(snapshot["events"] as? [[String: Any]])
        prefix.append(try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "event": try #require(snapshotEvents.first)], options: [.sortedKeys]))
        prefix.append(0x0A)
        let second = makeFact(toolCallID: "folded-two", receiptID: "folded-receipt-two", status: .succeeded)
        #expect(await consumer.ingestToolExecutionPhase(
            ToolExecutionPhaseFact(compositeKey: try #require(second.compositeKey), executionIdentity: try #require(second.executionIdentity),
                toolName: second.toolName, phase: .queued, occurredAt: Date(timeIntervalSince1970: 2)),
            eventID: second.toolCallID, eventName: "file_read", taskID: "task-one",
            expectedAttemptID: "attempt-one", scopeID: "scope-one"
        ))
        #expect(await consumer.ingestToolExecutionFact(
            second, eventID: second.toolCallID, eventName: "file_read", taskID: "task-one",
            expectedAttemptID: "attempt-one", scopeID: "scope-one"
        ))
        #expect(consumer.events.map(\.sequence) == [3, 5])
        if retainedPrefix {
            prefix.append(try Data(contentsOf: journalURL))
            try prefix.write(to: journalURL)
        }
        let journalBefore = try Data(contentsOf: journalURL)
        let reopened = try ToolLifecycleConsumer(persistenceURL: url, compactionInterval: 100)
        #expect(reopened.events == consumer.events)
        #expect(try Data(contentsOf: journalURL) == journalBefore)
        #expect(try Data(contentsOf: url) == snapshotBytes)
        let third = makeFact(toolCallID: "folded-three", receiptID: "folded-receipt-three", status: .succeeded)
        #expect(await reopened.ingestToolExecutionFact(
            third, eventID: third.toolCallID, eventName: "file_read", taskID: "task-one",
            expectedAttemptID: "attempt-one", scopeID: "scope-one"
        ))
        #expect(reopened.events.map(\.sequence) == [3, 5, 6])
        #expect(try ToolLifecycleConsumer(persistenceURL: url).events == reopened.events)
    }

    @Test(arguments: ["future-schema", "unknown-kind", "invalid-projection", "optional-metadata"])
    func checkpointCoveredPrefixStillHonorsClosedRecordContract(_ fixture: String) async throws {
        let url = temporaryURL()
        let journalURL = url.deletingPathExtension().appendingPathExtension("journal")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: journalURL)
        }
        let consumer = try ToolLifecycleConsumer(persistenceURL: url, compactionInterval: 2)
        let fact = makeFact(toolCallID: "covered-call", receiptID: "covered-receipt", status: .succeeded)
        #expect(await consumer.ingestToolExecutionPhase(
            ToolExecutionPhaseFact(compositeKey: try #require(fact.compositeKey),
                executionIdentity: try #require(fact.executionIdentity), toolName: fact.toolName,
                phase: .queued, occurredAt: Date(timeIntervalSince1970: 1)),
            eventID: fact.toolCallID, eventName: "file_read", taskID: "task-one",
            expectedAttemptID: "attempt-one", scopeID: "scope-one"
        ))
        var record = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [String: Any])
        #expect(await consumer.ingestToolExecutionFact(
            fact, eventID: fact.toolCallID, eventName: "file_read", taskID: "task-one",
            expectedAttemptID: "attempt-one", scopeID: "scope-one"
        ))
        let snapshotBefore = try Data(contentsOf: url)
        #expect(consumer.events.map(\.sequence) == [2])
        var event = try #require(record["event"] as? [String: Any])
        switch fixture {
        case "future-schema": record["schemaVersion"] = 99
        case "unknown-kind": event["kind"] = "unrecognized-required-event"
        case "invalid-projection": event["id"] = ""
        case "optional-metadata": record["futureDisplayMetric"] = ["samples": 1]
        default: Issue.record("Unknown covered-prefix fixture"); return
        }
        record["event"] = event
        var trustedPrefix = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        trustedPrefix.append(0x0A)
        var torn = trustedPrefix
        torn.append(Data("{\"schemaVersion\":1,\"event\":".utf8))
        try torn.write(to: journalURL)
        if fixture == "optional-metadata" {
            let reopened = try ToolLifecycleConsumer(persistenceURL: url)
            #expect(reopened.events == consumer.events)
            #expect(try Data(contentsOf: journalURL) == trustedPrefix)
        } else {
            #expect(throws: ToolLifecycleConsumerError.corruptPersistence) {
                _ = try ToolLifecycleConsumer(persistenceURL: url)
            }
            #expect(try Data(contentsOf: journalURL) == torn)
        }
        #expect(try Data(contentsOf: url) == snapshotBefore)
    }

    @Test(arguments: ["torn-tail", "invalid-middle"])
    func productionUnicodeJournalRecoversOnlyUnfinishedByteTail(_ boundary: String) async throws {
        let url = temporaryURL()
        let journalURL = url.deletingPathExtension().appendingPathExtension("journal")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: journalURL)
        }
        let consumer = try ToolLifecycleConsumer(persistenceURL: url, compactionInterval: 100)
        let first = makeFact(toolCallID: "unicode-one", receiptID: "unicode-receipt-one", status: .succeeded)
        #expect(await consumer.ingestToolExecutionFact(
            first, eventID: first.toolCallID, eventName: "file_read", taskID: "task-one",
            expectedAttemptID: "attempt-one", scopeID: "scope-one"
        ))
        let trustedPrefix = try Data(contentsOf: journalURL)
        let trustedEvents = consumer.events
        let second = makeFact(toolCallID: "unicode-two", receiptID: "unicode-receipt-two", status: .succeeded)
        #expect(await consumer.ingestToolExecutionFact(
            second, eventID: second.toolCallID, eventName: "file_read", taskID: "task-one",
            expectedAttemptID: "attempt-one", scopeID: "scope-one"
        ))
        let produced = try Data(contentsOf: journalURL)
        let finalRecord = Data(produced.dropFirst(trustedPrefix.count))
        let unicodeStart = try #require(finalRecord.firstIndex { $0 >= 0xE0 && $0 <= 0xEF })
        var damaged = trustedPrefix
        if boundary == "invalid-middle" {
            damaged.append(contentsOf: [0xFF, 0x0A])
        }
        damaged.append(finalRecord.prefix(unicodeStart + 1))
        #expect(String(data: damaged, encoding: .utf8) == nil)
        #expect(damaged.last != 0x0A)
        try damaged.write(to: journalURL)

        if boundary == "invalid-middle" {
            #expect(throws: ToolLifecycleConsumerError.corruptPersistence) {
                _ = try ToolLifecycleConsumer(persistenceURL: url)
            }
            #expect(try Data(contentsOf: journalURL) == damaged)
            return
        }
        let reopened = try ToolLifecycleConsumer(persistenceURL: url, compactionInterval: 100)
        #expect(reopened.events == trustedEvents)
        #expect(try Data(contentsOf: journalURL) == trustedPrefix)
        let third = makeFact(toolCallID: "unicode-three", receiptID: "unicode-receipt-three", status: .succeeded)
        #expect(await reopened.ingestToolExecutionFact(
            third, eventID: third.toolCallID, eventName: "file_read", taskID: "task-one",
            expectedAttemptID: "attempt-one", scopeID: "scope-one"
        ))
        #expect(reopened.events.map(\.sequence) == [1, 2])
        #expect(reopened.events.map(\.receiptID) == ["unicode-receipt-one", "unicode-receipt-three"])
        let durable = try Data(contentsOf: journalURL)
        #expect(try ToolLifecycleConsumer(persistenceURL: url).events == reopened.events)
        #expect(try Data(contentsOf: journalURL) == durable)
    }

    @Test("future snapshot schema fails closed")
    func futureSnapshotSchemaFailsClosed() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"schemaVersion":99,"events":[]}"#.utf8)
            .write(to: url, options: [.atomic])

        #expect(throws: ToolLifecycleConsumerError.corruptPersistence) {
            _ = try ToolLifecycleConsumer(persistenceURL: url)
        }
    }

    @Test("journal recovery bounds input and refuses symlinked files")
    func journalRecoveryBoundsAndNoFollowsLinks() throws {
        let oversizedURL = temporaryURL()
        let oversizedJournalURL = oversizedURL
            .deletingPathExtension()
            .appendingPathExtension("journal")
        defer { try? FileManager.default.removeItem(at: oversizedURL) }
        defer { try? FileManager.default.removeItem(at: oversizedJournalURL) }
        try Data(repeating: 0x20, count: CompactionCheckpoint.maxPersistedBytes + 1)
            .write(to: oversizedJournalURL, options: [.atomic])

        #expect(throws: ToolLifecycleConsumerError.corruptPersistence) {
            _ = try ToolLifecycleConsumer(persistenceURL: oversizedURL)
        }

        let symlinkURL = temporaryURL()
        let symlinkJournalURL = symlinkURL
            .deletingPathExtension()
            .appendingPathExtension("journal")
        let targetURL = symlinkJournalURL
            .deletingLastPathComponent()
            .appendingPathComponent("journal-target")
        defer { try? FileManager.default.removeItem(at: symlinkURL) }
        defer { try? FileManager.default.removeItem(at: symlinkJournalURL) }
        defer { try? FileManager.default.removeItem(at: targetURL) }
        try Data("not-a-journal\n".utf8).write(to: targetURL, options: [.atomic])
        try FileManager.default.createSymbolicLink(
            at: symlinkJournalURL,
            withDestinationURL: targetURL
        )

        #expect(throws: ToolLifecycleConsumerError.corruptPersistence) {
            _ = try ToolLifecycleConsumer(persistenceURL: symlinkURL)
        }
    }

    @Test("snapshot recovery bounds stable files and rejects replacement or corruption")
    func snapshotRecoveryBoundsAndRejectsUnsafeInputs() throws {
        let oversizedURL = temporaryURL()
        defer { try? FileManager.default.removeItem(at: oversizedURL) }
        let oversizedData = Data(
            repeating: 0x20,
            count: CompactionCheckpoint.maxPersistedBytes + 1
        )
        try oversizedData.write(to: oversizedURL, options: [.atomic])
        #expect(throws: ToolLifecycleConsumerError.corruptPersistence) {
            _ = try ToolLifecycleConsumer(persistenceURL: oversizedURL)
        }
        #expect(try Data(contentsOf: oversizedURL) == oversizedData)

        let symlinkURL = temporaryURL()
        let symlinkTargetURL = symlinkURL
            .deletingLastPathComponent()
            .appendingPathComponent("snapshot-target")
        defer { try? FileManager.default.removeItem(at: symlinkURL) }
        defer { try? FileManager.default.removeItem(at: symlinkTargetURL) }
        try Data(#"{"schemaVersion":1,"events":[]}"#.utf8)
            .write(to: symlinkTargetURL, options: [.atomic])
        try FileManager.default.createSymbolicLink(
            at: symlinkURL,
            withDestinationURL: symlinkTargetURL
        )
        #expect(throws: ToolLifecycleConsumerError.corruptPersistence) {
            _ = try ToolLifecycleConsumer(persistenceURL: symlinkURL)
        }
        #expect(FileManager.default.fileExists(atPath: symlinkURL.path))
        #expect(try Data(contentsOf: symlinkTargetURL) == Data(#"{"schemaVersion":1,"events":[]}"#.utf8))

        let replacedURL = temporaryURL()
        defer { try? FileManager.default.removeItem(at: replacedURL) }
        try Data(#"{"schemaVersion":1,"events":[]}"#.utf8)
            .write(to: replacedURL, options: [.atomic])
        let replacementData = Data("replacement-with-corrupt-schema".utf8)
        try replacementData
            .write(to: replacedURL, options: [.atomic])
        #expect(throws: ToolLifecycleConsumerError.corruptPersistence) {
            _ = try ToolLifecycleConsumer(persistenceURL: replacedURL)
        }
        #expect(try Data(contentsOf: replacedURL) == replacementData)
    }

    @Test("writer snapshot and journal replay preserve terminal duplicate fence")
    func writerSnapshotJournalReplayAndDuplicateTerminal() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let consumer = try ToolLifecycleConsumer(
            persistenceURL: url,
            compactionInterval: 2
        )
        for index in 1...3 {
            #expect(await consumer.ingestToolExecutionFact(
                makeFact(
                    toolCallID: "replay-call-\(index)",
                    receiptID: "replay-receipt-\(index)",
                    status: index == 3 ? .failed : .succeeded
                ),
                eventID: "replay-call-\(index)",
                eventName: "file_read",
                taskID: "task-one",
                expectedAttemptID: "attempt-one",
                scopeID: "scope-one"
            ))
        }

        let snapshotBytes = try Data(contentsOf: url).count
        #expect(snapshotBytes <= CompactionCheckpoint.maxPersistedBytes)
        let reloaded = try ToolLifecycleConsumer(
            persistenceURL: url,
            compactionInterval: 2
        )
        #expect(reloaded.events.map(\.sequence) == [1, 2, 3])
        #expect(reloaded.events.last?.status == .failed)
        let beforeRejects = reloaded.persistenceMetrics
        let journalURL = url.deletingPathExtension().appendingPathExtension("journal")
        let snapshotBeforeReject = try Data(contentsOf: url)
        let journalBeforeReject = try Data(contentsOf: journalURL)
        #expect(!(await reloaded.ingestToolExecutionFact(
            makeFact(
                toolCallID: "replay-call-3",
                receiptID: "replay-receipt-3",
                status: .failed
            ),
            eventID: "replay-call-3",
            eventName: "file_read",
            taskID: "task-one",
            expectedAttemptID: "attempt-one",
            scopeID: "scope-one"
        )))
        #expect(reloaded.persistenceMetrics == beforeRejects)
        #expect(try Data(contentsOf: url) == snapshotBeforeReject)
        #expect(try Data(contentsOf: journalURL) == journalBeforeReject)
    }

    @Test("invalid, duplicate, late, and stale facts fail closed")
    func canonicalFencesRejectInvalidFacts() async {
        let consumer = ToolLifecycleConsumer()
        let succeeded = makeFact(
            toolCallID: "call-one",
            receiptID: "receipt-one",
            status: .succeeded
        )
        #expect(await consumer.ingestToolExecutionFact(
            succeeded,
            eventID: "call-one",
            eventName: "file_read",
            taskID: "task-one",
            expectedAttemptID: "attempt-one",
            scopeID: "scope-one",
            occurredAt: Date(timeIntervalSince1970: 1)
        ))

        #expect(!(await consumer.ingestToolExecutionFact(
            succeeded,
            eventID: "call-one",
            eventName: "file_read",
            taskID: "task-one",
            expectedAttemptID: "attempt-one",
            scopeID: "scope-one",
            occurredAt: Date(timeIntervalSince1970: 2)
        )))

        let late = makeFact(
            toolCallID: "call-one",
            receiptID: "receipt-late",
            status: .failed
        )
        #expect(!(await consumer.ingestToolExecutionFact(
            late,
            eventID: "call-one",
            eventName: "file_read",
            taskID: "task-one",
            expectedAttemptID: "attempt-one",
            scopeID: "scope-one",
            occurredAt: Date(timeIntervalSince1970: 3)
        )))

        let newerAttempt = makeFact(
            toolCallID: "call-two",
            receiptID: "receipt-two",
            attemptID: "attempt-two",
            attemptNumber: 2,
            status: .succeeded
        )
        #expect(await consumer.ingestToolExecutionFact(
            newerAttempt,
            eventID: "call-two",
            eventName: "file_read",
            taskID: "task-one",
            expectedAttemptID: "attempt-two",
            scopeID: "scope-one",
            occurredAt: Date(timeIntervalSince1970: 4)
        ))

        let stale = makeFact(
            toolCallID: "call-three",
            receiptID: "receipt-three",
            status: .failed
        )
        #expect(!(await consumer.ingestToolExecutionFact(
            stale,
            eventID: "call-three",
            eventName: "file_read",
            taskID: "task-one",
            expectedAttemptID: "attempt-one",
            scopeID: "scope-one",
            occurredAt: Date(timeIntervalSince1970: 5)
        )))

        let invalid = makeFact(
            toolCallID: "call-invalid",
            receiptID: "receipt-invalid",
            status: .succeeded
        )
        #expect(!(await consumer.ingestToolExecutionFact(
            invalid,
            eventID: "wrong-event-id",
            eventName: "file_read",
            taskID: "task-one",
            expectedAttemptID: "attempt-one",
            scopeID: "scope-one"
        )))
        #expect(consumer.events.map(\.sequence) == [1, 2])
    }

    @Test("bounded durable append stays within the 100 and 1000 event gate")
    func boundedDurableAppendPerformance() async throws {
        for count in [100, 1_000] {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let journalURL = url.deletingPathExtension().appendingPathExtension("journal")
            let consumer = try ToolLifecycleConsumer(persistenceURL: url)
            var durations: [UInt64] = []

            for index in 1...count {
                let start = DispatchTime.now().uptimeNanoseconds
                #expect(await consumer.ingestToolExecutionFact(
                    makeFact(
                        toolCallID: "perf-call-\(count)-\(index)",
                        receiptID: "perf-receipt-\(count)-\(index)",
                        status: .succeeded
                    ),
                    eventID: "perf-call-\(count)-\(index)",
                    eventName: "file_read",
                    taskID: "task-one",
                    expectedAttemptID: "attempt-one",
                    scopeID: "scope-one"
                ))
                durations.append(DispatchTime.now().uptimeNanoseconds - start)
            }

            let sorted = durations.sorted()
            let p95Rank = max(1, Int(ceil(Double(count) * 0.95)))
            let p95Milliseconds = Double(sorted[p95Rank - 1]) / 1_000_000
            let snapshotBytes = Int64((try? Data(contentsOf: url).count) ?? 0)
            let journalBytes = Int64((try? Data(contentsOf: journalURL).count) ?? 0)
            let durableBytes = max(1, snapshotBytes + journalBytes)
            let metrics = consumer.persistenceMetrics
            let writeAmplification = Double(metrics.totalBytes) / Double(durableBytes)

            #expect(metrics.journalAppendCount == count)
            #expect(metrics.snapshotWriteCount <= 1)
            #expect(p95Milliseconds <= 16.7)
            #expect(writeAmplification <= 2.0)
            #expect(consumer.events.count == count)

            let beforeRejects = metrics
            let duplicate = makeFact(
                toolCallID: "perf-call-\(count)-1",
                receiptID: "perf-receipt-\(count)-1",
                status: .succeeded
            )
            #expect(!(await consumer.ingestToolExecutionFact(
                duplicate,
                eventID: duplicate.toolCallID,
                eventName: "file_read",
                taskID: "task-one",
                expectedAttemptID: "attempt-one",
                scopeID: "scope-one"
            )))
            let late = makeFact(
                toolCallID: duplicate.toolCallID,
                receiptID: "perf-late-\(count)-1",
                status: .failed
            )
            #expect(!(await consumer.ingestToolExecutionFact(
                late,
                eventID: late.toolCallID,
                eventName: "file_read",
                taskID: "task-one",
                expectedAttemptID: "attempt-one",
                scopeID: "scope-one"
            )))
            #expect(consumer.persistenceMetrics == beforeRejects)
            print(
                "TOOL_LIFECYCLE_PERF count=\(count) p50_ms=\(String(format: "%.3f", Double(sorted[max(0, Int(ceil(Double(count) * 0.50))) - 1]) / 1_000_000)) p95_ms=\(String(format: "%.3f", p95Milliseconds)) total_writes=\(metrics.totalWriteCount) total_bytes=\(metrics.totalBytes) durable_bytes=\(durableBytes) amplification=\(String(format: "%.3f", writeAmplification)) reject_writes=0"
            )
        }
    }

    @Test("100 concurrent ingests serialize sequence, journal, and compaction")
    func concurrentIngest100IsLosslessAndReloadable() async throws {
        try await assertConcurrentIngestIsLossless(count: 100)
    }

    @Test("1000 concurrent ingests serialize sequence, journal, and compaction")
    func concurrentIngest1000IsLosslessAndReloadable() async throws {
        try await assertConcurrentIngestIsLossless(count: 1_000)
    }

    @Test("journal append failure rolls back projection and metrics")
    func journalAppendFailureRollsBackState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tool-lifecycle-blocked-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("events.json")
        let journalURL = url.deletingPathExtension().appendingPathExtension("journal")
        let consumer = try ToolLifecycleConsumer(persistenceURL: url)
        // Recovery must see a valid missing-store state. Inject the filesystem
        // failure afterward so this case reaches the journal append boundary.
        try Data("not-a-directory".utf8).write(to: root, options: [.atomic])
        let fact = makeFact(
            toolCallID: "rollback-call",
            receiptID: "rollback-receipt",
            status: .succeeded
        )

        #expect(!(await consumer.ingestToolExecutionFact(
            fact,
            eventID: fact.toolCallID,
            eventName: "file_read",
            taskID: "task-one",
            expectedAttemptID: "attempt-one",
            scopeID: "scope-one"
        )))
        #expect(consumer.events.isEmpty)
        #expect(consumer.persistenceMetrics == ToolLifecyclePersistenceMetrics(
            journalAppendCount: 0,
            journalAppendBytes: 0,
            snapshotWriteCount: 0,
            snapshotWriteBytes: 0
        ))
        #expect(!FileManager.default.fileExists(atPath: journalURL.path))
    }

    private func assertConcurrentIngestIsLossless(count: Int) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tool-lifecycle-concurrent-\(count)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("events.json")
        let journalURL = url.deletingPathExtension().appendingPathExtension("journal")
        let compactionInterval = 64
        let consumer = try ToolLifecycleConsumer(
            persistenceURL: url,
            compactionInterval: compactionInterval
        )
        let inputs = (1...count).map { index in
            let callID = "concurrent-call-\(count)-\(index)"
            return (
                fact: makeFact(
                    toolCallID: callID,
                    receiptID: "concurrent-receipt-\(count)-\(index)",
                    status: .succeeded
                ),
                eventID: callID,
                occurredAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        let accepted = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for input in inputs {
                group.addTask {
                    await consumer.ingestToolExecutionFact(
                        input.fact,
                        eventID: input.eventID,
                        eventName: "file_read",
                        taskID: "task-one",
                        expectedAttemptID: "attempt-one",
                        scopeID: "scope-one",
                        occurredAt: input.occurredAt
                    )
                }
            }
            var accepted = 0
            for await result in group where result {
                accepted += 1
            }
            return accepted
        }

        #expect(accepted == count)
        let events = consumer.events
        #expect(events.count == count)
        #expect(Set(events.map(\.id)).count == count)
        #expect(events.map(\.sequence) == (1...count).map(Int64.init))

        let expectedSnapshotCount = count / compactionInterval
        let expectedJournalCount = count % compactionInterval
        let metrics = consumer.persistenceMetrics
        #expect(metrics.journalAppendCount == count)
        #expect(metrics.snapshotWriteCount == expectedSnapshotCount)

        let snapshotData = try Data(contentsOf: url)
        let snapshotObject = try #require(
            JSONSerialization.jsonObject(with: snapshotData) as? [String: Any]
        )
        #expect(
            (snapshotObject["events"] as? [Any])?.count
                == count - expectedJournalCount
        )

        let journalData = try Data(contentsOf: journalURL)
        let journalText = try #require(String(data: journalData, encoding: .utf8))
        #expect(journalText.isEmpty || journalText.hasSuffix("\n"))
        let journalLines = journalText.split(separator: "\n")
        #expect(journalLines.count == expectedJournalCount)
        for line in journalLines {
            let object = try #require(
                JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            )
            #expect(object["schemaVersion"] as? Int == 1)
            #expect(object["event"] as? [String: Any] != nil)
        }

        let reloaded = try ToolLifecycleConsumer(
            persistenceURL: url,
            compactionInterval: compactionInterval
        )
        #expect(reloaded.events.count == count)
        #expect(reloaded.events.map(\.sequence) == (1...count).map(Int64.init))
        #expect(Set(reloaded.events.compactMap(\.receiptID)).count == count)

        let beforeRejects = consumer.persistenceMetrics
        let snapshotBytesBefore = try Data(contentsOf: url).count
        let journalBytesBefore = try Data(contentsOf: journalURL).count
        let duplicate = inputs[0].fact
        #expect(!(await consumer.ingestToolExecutionFact(
            duplicate,
            eventID: duplicate.toolCallID,
            eventName: "file_read",
            taskID: "task-one",
            expectedAttemptID: "attempt-one",
            scopeID: "scope-one"
        )))
        let late = makeFact(
            toolCallID: duplicate.toolCallID,
            receiptID: "late-receipt-\(count)",
            status: .failed
        )
        #expect(!(await consumer.ingestToolExecutionFact(
            late,
            eventID: late.toolCallID,
            eventName: "file_read",
            taskID: "task-one",
            expectedAttemptID: "attempt-one",
            scopeID: "scope-one"
        )))
        #expect(consumer.events.count == count)
        #expect(consumer.persistenceMetrics == beforeRejects)
        let snapshotBytesAfter = try Data(contentsOf: url).count
        let journalBytesAfter = try Data(contentsOf: journalURL).count
        #expect(snapshotBytesAfter == snapshotBytesBefore)
        #expect(journalBytesAfter == journalBytesBefore)
    }

    private func makeFact(
        toolCallID: String,
        receiptID: String,
        attemptID: String = "attempt-one",
        attemptNumber: Int = 1,
        status: ToolExecutionStatus
    ) -> ToolExecutionFact {
        let turn = AgentTurnIdentity(
            sessionID: "session-one",
            turnID: 4,
            messageID: "message-one"
        )
        let executionIdentity = AgentExecutionIdentity(
            turn: turn,
            operationID: "operation-one",
            attempt: attemptNumber
        )
        let compositeKey = ToolExecutionCompositeKey(
            sessionID: turn.sessionID,
            turnID: turn.turnID,
            messageID: turn.messageID,
            operationID: executionIdentity.operationID,
            attemptID: attemptID,
            attemptNumber: attemptNumber,
            toolCallID: toolCallID
        )
        return ToolExecutionFact(
            toolCallID: toolCallID,
            receiptID: receiptID,
            toolName: "file_read",
            status: status,
            attemptID: attemptID,
            attemptNumber: attemptNumber,
            executionIdentity: executionIdentity,
            compositeKey: compositeKey
        )
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tool-lifecycle-\(UUID().uuidString).json")
    }
}
