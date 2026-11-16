import Foundation
import Testing
@testable import MinisCore

@Suite("Agent turn durability")
struct AgentTurnContextStoreTests {
    private func snapshot(
        sessionID: String = "session-a",
        providerID: String = "provider-a",
        modelID: String = "model-a"
    ) -> ConversationContextSnapshotV1 {
        ConversationContextSnapshotV1(
            sessionID: sessionID,
            providerID: providerID,
            modelID: modelID,
            configurationFingerprint: "configuration-a",
            skillIdentifiers: ["browser"],
            conversationID: sessionID
        )
    }

    private func identity(
        turnID: Int = 1,
        messageID: String = "message-a",
        operationID: String = "operation-a",
        attempt: Int = 0
    ) -> AgentExecutionIdentity {
        AgentExecutionIdentity(
            turn: AgentTurnIdentity(
                sessionID: "session-a",
                turnID: turnID,
                messageID: messageID
            ),
            operationID: operationID,
            attempt: attempt
        )
    }

    private func handoff(
        identity: AgentExecutionIdentity,
        snapshot: ConversationContextSnapshotV1
    ) throws -> ContextOrchestrator.AgentLoopInput {
        try #require(
            ContextOrchestrator().prepareAgentLoopInput(
                .init(snapshot: snapshot, entries: []),
                budget: 0,
                executionIdentity: identity
            ).input
        )
    }

    private func persistenceURL() -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniscore-turn-store-\(UUID().uuidString)", isDirectory: true)
        return (directory, directory.appendingPathComponent("turns.json"))
    }

    @Test func duplicateIdentityIsRejectedAfterStoreRestart() throws {
        let (directory, url) = persistenceURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let turn = identity()
        let context = snapshot()

        let first = try AgentTurnContextStore(persistenceURL: url)
        #expect(try first.begin(identity: turn, snapshot: context))

        let restarted = try AgentTurnContextStore(persistenceURL: url)
        #expect(try restarted.begin(identity: turn, snapshot: context) == false)
        #expect(restarted.record(for: turn)?.status == .active)
    }

    @Test func staleStoreCannotOverwriteDurableTurnIdentity() throws {
        let (directory, url) = persistenceURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let turn = identity(turnID: 4, messageID: "message-stale", operationID: "operation-stale")
        let context = snapshot()
        let first = try AgentTurnContextStore(persistenceURL: url)
        let stale = try AgentTurnContextStore(persistenceURL: url)

        #expect(try first.begin(identity: turn, snapshot: context))
        #expect(throws: AgentTurnContextStoreError.persistenceFailed) {
            _ = try stale.begin(identity: turn, snapshot: context)
        }
        let recovered = try AgentTurnContextStore(persistenceURL: url)
        #expect(recovered.record(for: turn)?.status == .active)
    }

    @Test func identitySessionMustMatchSnapshotSessionBeforePersistence() throws {
        let (directory, url) = persistenceURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mismatched = AgentExecutionIdentity(
            turn: AgentTurnIdentity(
                sessionID: "session-b",
                turnID: 5,
                messageID: "message-mismatch"
            ),
            operationID: "operation-mismatch"
        )
        let store = try AgentTurnContextStore(persistenceURL: url)

        #expect(throws: AgentTurnContextStoreError.invalidIdentity) {
            _ = try store.begin(identity: mismatched, snapshot: snapshot(sessionID: "session-a"))
        }
        #expect(store.record(for: mismatched) == nil)
    }

    @Test func cancellationIsADurableTombstoneAndRejectsLateWriteback() throws {
        let (directory, url) = persistenceURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let turn = identity(turnID: 2, messageID: "message-cancel", operationID: "operation-cancel")
        let context = snapshot()
        let input = try handoff(identity: turn, snapshot: context)

        let store = try AgentTurnContextStore(persistenceURL: url)
        let gate = ContextOrchestrator.AgentLoopWritebackGate(store: store)
        #expect(gate.begin(input))
        gate.cancel(input)
        #expect(store.record(for: turn)?.status == .cancelled)

        let restarted = try AgentTurnContextStore(persistenceURL: url)
        let restartedGate = ContextOrchestrator.AgentLoopWritebackGate(store: restarted)
        #expect(restartedGate.begin(input) == false)
        #expect(
            restartedGate.validate(
                .init(snapshot: context, executionIdentity: turn),
                for: input,
                currentSnapshot: context
            ) == .rejected(.inactiveExecution)
        )
    }

    @Test func successfulWritebackIsConsumedBeforeRestartCanAdmitIt() throws {
        let (directory, url) = persistenceURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let turn = identity(turnID: 3, messageID: "message-complete", operationID: "operation-complete")
        let context = snapshot()
        let input = try handoff(identity: turn, snapshot: context)

        let store = try AgentTurnContextStore(persistenceURL: url)
        let gate = ContextOrchestrator.AgentLoopWritebackGate(store: store)
        #expect(gate.begin(input))
        #expect(
            gate.validate(
                .init(snapshot: context, executionIdentity: turn),
                for: input,
                currentSnapshot: context
            ) == .accepted
        )
        #expect(store.record(for: turn)?.status == .writingBack)
        #expect(try store.complete(identity: turn, snapshot: context))
        #expect(store.record(for: turn)?.status == .completed)

        let restarted = try AgentTurnContextStore(persistenceURL: url)
        let restartedGate = ContextOrchestrator.AgentLoopWritebackGate(store: restarted)
        #expect(restartedGate.begin(input) == false)
        #expect(
            restartedGate.validate(
                .init(snapshot: context, executionIdentity: turn),
                for: input,
                currentSnapshot: context
            ) == .rejected(.inactiveExecution)
        )
    }

    @Test func writebackDoesNotBecomeCompletedBeforeTranscriptCommit() throws {
        let (directory, url) = persistenceURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let turn = identity(turnID: 8, messageID: "message-order", operationID: "operation-order")
        let context = snapshot()
        let store = try AgentTurnContextStore(persistenceURL: url)

        #expect(try store.begin(identity: turn, snapshot: context))
        #expect(try store.complete(identity: turn, snapshot: context) == false)
        #expect(store.record(for: turn)?.status == .active)
        #expect(try store.admitWriteback(
            identity: turn,
            snapshot: context,
            currentSnapshot: context
        ))
        #expect(store.record(for: turn)?.status == .writingBack)

        #expect(try store.complete(identity: turn, snapshot: context))
        #expect(store.record(for: turn)?.status == .completed)
        #expect(try AgentTurnContextStore(persistenceURL: url).record(for: turn)?.status == .completed)
    }

    @Test func lateCancellationCannotOverrideAdmittedWriteback() throws {
        let (directory, url) = persistenceURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let turn = identity(turnID: 11, messageID: "message-late-cancel", operationID: "operation-late-cancel")
        let context = snapshot()
        let store = try AgentTurnContextStore(persistenceURL: url)

        #expect(try store.begin(identity: turn, snapshot: context))
        #expect(try store.admitWriteback(
            identity: turn,
            snapshot: context,
            currentSnapshot: context
        ))
        #expect(store.record(for: turn)?.status == .writingBack)

        // Cancellation arriving after writeback admission must not discard
        // the one callback that already owns the durable writeback slot.
        #expect(try store.cancel(identity: turn, snapshot: context) == false)
        #expect(store.record(for: turn)?.status == .writingBack)
        #expect(try store.complete(identity: turn, snapshot: context))

        let restarted = try AgentTurnContextStore(persistenceURL: url)
        #expect(restarted.record(for: turn)?.status == .completed)
        #expect(try restarted.admitWriteback(
            identity: turn,
            snapshot: context,
            currentSnapshot: context
        ) == false)
    }

    @Test func streamSequenceIsDurableAndRejectsDuplicateOrLateDeltas() throws {
        let (directory, url) = persistenceURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let turn = identity(turnID: 12, messageID: "message-stream", operationID: "operation-stream")
        let context = snapshot()
        let first = try AgentTurnContextStore(persistenceURL: url)
        #expect(try first.begin(identity: turn, snapshot: context, generation: 1))
        #expect(try first.acceptStreamSequence(
            identity: turn,
            snapshot: context,
            sequence: 1,
            generation: 1
        ))
        #expect(first.record(for: turn)?.streamSequence == 1)
        #expect(try first.acceptStreamSequence(
            identity: turn,
            snapshot: context,
            sequence: 1,
            generation: 1
        ) == false)
        #expect(try first.acceptStreamSequence(
            identity: turn,
            snapshot: context,
            sequence: 2,
            generation: 1
        ))

        let restarted = try AgentTurnContextStore(persistenceURL: url)
        #expect(restarted.record(for: turn)?.streamSequence == 2)
        #expect(try restarted.acceptStreamSequence(
            identity: turn,
            snapshot: context,
            sequence: 1,
            generation: 1
        ) == false)
        #expect(try restarted.acceptStreamSequence(
            identity: turn,
            snapshot: context,
            sequence: 3,
            generation: 0
        ) == false)
        #expect(try restarted.cancel(identity: turn, snapshot: context, generation: 1))
        #expect(try restarted.acceptStreamSequence(
            identity: turn,
            snapshot: context,
            sequence: 4,
            generation: 1
        ) == false)
    }

    @Test func reopenedRecoveryResetsSequenceAndRetiresOldGeneration() throws {
        let (directory, url) = persistenceURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let turn = identity(turnID: 13, messageID: "message-stream-recovery", operationID: "operation-stream-recovery")
        let context = snapshot()
        let store = try AgentTurnContextStore(persistenceURL: url)
        #expect(try store.begin(identity: turn, snapshot: context, generation: 1))
        #expect(try store.acceptStreamSequence(identity: turn, snapshot: context, sequence: 7, generation: 1))
        #expect(try store.recoverInterrupted(identity: turn, snapshot: context, generation: 1))
        #expect(try store.reopenAfterRecovery(identity: turn, snapshot: context, generation: 2))
        #expect(store.record(for: turn)?.streamSequence == 0)
        #expect(try store.acceptStreamSequence(identity: turn, snapshot: context, sequence: 1, generation: 1) == false)
        #expect(try store.acceptStreamSequence(identity: turn, snapshot: context, sequence: 1, generation: 2))
        #expect(store.record(for: turn)?.streamSequence == 1)
    }

    @Test func failedAndNeedsUserReviewWritebackStatesSurviveRestart() throws {
        let (directory, url) = persistenceURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let failedTurn = identity(turnID: 9, messageID: "message-failed", operationID: "operation-failed")
        let reviewTurn = identity(turnID: 10, messageID: "message-review", operationID: "operation-review")
        let context = snapshot()
        let store = try AgentTurnContextStore(persistenceURL: url)

        #expect(try store.begin(identity: failedTurn, snapshot: context))
        #expect(try store.fail(identity: failedTurn, snapshot: context))
        #expect(try store.begin(identity: reviewTurn, snapshot: context))
        #expect(try store.markNeedsUserReview(identity: reviewTurn, snapshot: context))

        let restarted = try AgentTurnContextStore(persistenceURL: url)
        #expect(restarted.record(for: failedTurn)?.status == .failed)
        #expect(restarted.record(for: reviewTurn)?.status == .needsUserReview)
    }

    @Test func immutableExecutionIdentityRoundTripsWithoutRegeneration() throws {
        let turn = identity(
            turnID: 7,
            messageID: "assistant-placeholder",
            operationID: "chat:session-a:7",
            attempt: 2
        )
        let data = try JSONEncoder().encode(turn)
        let decoded = try JSONDecoder().decode(AgentExecutionIdentity.self, from: data)

        #expect(decoded == turn)
        #expect(decoded.turn.sessionID == "session-a")
        #expect(decoded.turn.turnID == 7)
        #expect(decoded.turn.messageID == "assistant-placeholder")
        #expect(decoded.operationID == "chat:session-a:7")
        #expect(decoded.attempt == 2)
    }

    @Test func forgedNegativeAttemptIsRejectedAfterDecoding() throws {
        let data = Data(
            """
            {"turn":{"sessionID":"session-a","turnID":7,"messageID":"message-a"},"operationID":"operation-a","attempt":-1}
            """.utf8
        )
        let decoded = try JSONDecoder().decode(AgentExecutionIdentity.self, from: data)

        #expect(decoded.isValid == false)
    }

    @Test("published old snapshot remains an inert tombstone across a new save and restart")
    func oldProductionSnapshotIsRetainedButCannotResume() throws {
        let (directory, url) = persistenceURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = "00000000-0000-4000-8000-000000000001"
        let oldID = "context:\(session):mock:model-synthetic:chat:v1:mock:model-synthetic:1024:browser:\(session)"
        let oldSnapshot = ConversationContextSnapshotV1(
            snapshotID: oldID,
            sessionID: session,
            providerID: "mock",
            modelID: "model-synthetic",
            configurationFingerprint: "chat:v1:mock:model-synthetic:1024",
            skillIdentifiers: ["browser"],
            conversationID: session
        )
        let oldIdentity = AgentExecutionIdentity(
            turn: AgentTurnIdentity(sessionID: session, turnID: 1, messageID: "message-old"),
            operationID: "operation-old"
        )
        let oldRecord = AgentTurnContextRecord(
            identity: oldIdentity, snapshot: oldSnapshot, status: .active
        )
        let oldJSON = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(oldRecord)) as? [String: Any]
        )
        let completedIdentity = AgentExecutionIdentity(
            turn: AgentTurnIdentity(sessionID: session, turnID: 0, messageID: "message-done"),
            operationID: "operation-done"
        )
        let completedRecord = AgentTurnContextRecord(
            identity: completedIdentity, snapshot: oldSnapshot, status: .completed,
            terminalTruth: AgentTerminalTruth(
                identity: completedIdentity, generation: 0, outcome: .succeeded
            )
        )
        let completedJSON = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(completedRecord)) as? [String: Any]
        )
        let envelope: [String: Any] = [
            "schemaVersion": 1, "records": [oldJSON, completedJSON]
        ]
        let original = try JSONSerialization.data(withJSONObject: envelope)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try original.write(to: url)

        let store = try AgentTurnContextStore(persistenceURL: url)
        #expect(try Data(contentsOf: url) == original)
        #expect(store.record(for: oldIdentity) == nil)
        #expect(store.record(for: completedIdentity) == nil)
        #expect(throws: AgentTurnContextStoreError.invalidSnapshot) {
            _ = try store.admitWriteback(
                identity: oldIdentity, snapshot: oldSnapshot, currentSnapshot: oldSnapshot
            )
        }
        #expect(throws: AgentTurnContextStoreError.invalidSnapshot) {
            _ = try store.recoverInterrupted(identity: oldIdentity, snapshot: oldSnapshot)
        }

        let newSnapshot = ConversationContextSnapshotV1(
            sessionID: session,
            providerID: "mock",
            modelID: "model-synthetic",
            configurationFingerprint: "chat:v1:mock:model-synthetic:1024",
            skillIdentifiers: ["browser"],
            conversationID: session
        )
        #expect(throws: AgentTurnContextStoreError.conflictingIdentity) {
            _ = try store.begin(identity: oldIdentity, snapshot: newSnapshot)
        }
        let freshIdentity = AgentExecutionIdentity(
            turn: AgentTurnIdentity(sessionID: session, turnID: 2, messageID: "message-new"),
            operationID: "operation-new"
        )
        #expect(try store.begin(identity: freshIdentity, snapshot: newSnapshot))
        let saved = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let records = try #require(saved["records"] as? [[String: Any]])
        #expect(records.count == 3)
        #expect(records.contains { NSDictionary(dictionary: $0).isEqual(to: oldJSON) })
        #expect(records.contains { NSDictionary(dictionary: $0).isEqual(to: completedJSON) })
        let restarted = try AgentTurnContextStore(persistenceURL: url)
        #expect(restarted.record(for: oldIdentity) == nil)
        #expect(restarted.record(for: completedIdentity) == nil)
        #expect(restarted.record(for: freshIdentity)?.status == .active)
    }

    @Test("old records with unknown fields are not silently re-encoded")
    func oldUnknownFieldRemainsARecoveryFailure() throws {
        let (directory, url) = persistenceURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = "00000000-0000-4000-8000-000000000001"
        let snapshot = ConversationContextSnapshotV1(
            snapshotID: "context:\(session):mock:model-synthetic:chat:v1:mock:model-synthetic:1024:browser:\(session)",
            sessionID: session, providerID: "mock", modelID: "model-synthetic",
            configurationFingerprint: "chat:v1:mock:model-synthetic:1024",
            skillIdentifiers: ["browser"], conversationID: session
        )
        let record = AgentTurnContextRecord(
            identity: AgentExecutionIdentity(
                turn: AgentTurnIdentity(sessionID: session, turnID: 1, messageID: "message-old"),
                operationID: "operation-old"
            ),
            snapshot: snapshot, status: .active
        )
        var raw = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any]
        )
        let cleanRaw = raw
        raw["futureField"] = "retain-me"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "records": [raw]
        ])
        try original.write(to: url)
        #expect(throws: AgentTurnContextStoreError.invalidSnapshotRecovery(.recordNonLossless)) {
            _ = try AgentTurnContextStore(persistenceURL: url)
        }
        #expect(try Data(contentsOf: url) == original)

        let unknownEnvelope = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "records": [cleanRaw], "futureField": "retain-top-level"
        ])
        try unknownEnvelope.write(to: url)
        #expect(throws: AgentTurnContextStoreError.invalidSnapshotRecovery(.stateNonLossless)) {
            _ = try AgentTurnContextStore(persistenceURL: url)
        }
        #expect(try Data(contentsOf: url) == unknownEnvelope)

        var unrecognizedRecord = cleanRaw
        var unrecognizedSnapshot = try #require(
            unrecognizedRecord["snapshot"] as? [String: Any]
        )
        unrecognizedSnapshot["snapshotID"] = "context:tampered"
        unrecognizedRecord["snapshot"] = unrecognizedSnapshot
        let unrecognizedEnvelope = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "records": [unrecognizedRecord]
        ])
        try unrecognizedEnvelope.write(to: url)
        #expect(throws: AgentTurnContextStoreError.invalidSnapshotRecovery(.legacyFormulaMismatch)) {
            _ = try AgentTurnContextStore(persistenceURL: url)
        }
        #expect(try Data(contentsOf: url) == unrecognizedEnvelope)

        unrecognizedSnapshot["modelID"] = "model,ambiguous"
        unrecognizedSnapshot["configurationFingerprint"] = "chat:v1:mock:model,ambiguous:1024"
        unrecognizedSnapshot["snapshotID"] =
            "context:\(session):mock:model,ambiguous:chat:v1:mock:model,ambiguous:1024:browser:\(session)"
        unrecognizedRecord["snapshot"] = unrecognizedSnapshot
        let unsafeEnvelope = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "records": [unrecognizedRecord]
        ])
        try unsafeEnvelope.write(to: url)
        let inertUnsafe = try AgentTurnContextStore(persistenceURL: url)
        #expect(inertUnsafe.record(for: record.identity) == nil)
        #expect(try Data(contentsOf: url) == unsafeEnvelope)

        unrecognizedSnapshot["snapshotID"] = "context:v2:tampered"
        unrecognizedRecord["snapshot"] = unrecognizedSnapshot
        let currentMismatch = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "records": [unrecognizedRecord]
        ])
        try currentMismatch.write(to: url)
        #expect(throws: AgentTurnContextStoreError.invalidSnapshotRecovery(.currentCanonicalMismatch)) {
            _ = try AgentTurnContextStore(persistenceURL: url)
        }
        #expect(try Data(contentsOf: url) == currentMismatch)
    }

    @Test("ambiguous historical binding remains inert while a fresh framed turn can persist")
    func ambiguousHistoricalBindingCannotResumeOrAliasASecondBinding() throws {
        let (directory, url) = persistenceURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = "00000000-0000-4000-8000-000000000001"
        let fingerprint = "chat:v2:1024:context-settings:v1:" + String(repeating: "a", count: 64)
        let oldID = "context:\(session):Local API:qwen:7b:\(fingerprint):browser:\(session)"
        let old = ConversationContextSnapshotV1(
            snapshotID: oldID, sessionID: session, providerID: "Local API", modelID: "qwen:7b",
            configurationFingerprint: fingerprint, skillIdentifiers: ["browser"],
            conversationID: session
        )
        let oldIdentity = AgentExecutionIdentity(
            turn: AgentTurnIdentity(sessionID: session, turnID: 1, messageID: "old-message"),
            operationID: "old-operation"
        )
        let oldRecord = AgentTurnContextRecord(identity: oldIdentity, snapshot: old, status: .active)
        let rawOld = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(oldRecord)) as? [String: Any]
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "records": [rawOld]
        ])
        try original.write(to: url)

        let store = try AgentTurnContextStore(persistenceURL: url)
        #expect(try Data(contentsOf: url) == original)
        #expect(store.record(for: oldIdentity) == nil)
        #expect(throws: AgentTurnContextStoreError.invalidSnapshot) {
            _ = try store.recoverInterrupted(identity: oldIdentity, snapshot: old)
        }
        #expect(throws: AgentTurnContextStoreError.invalidSnapshot) {
            _ = try store.admitWriteback(identity: oldIdentity, snapshot: old, currentSnapshot: old)
        }
        let fresh = ConversationContextSnapshotV1(
            sessionID: session, providerID: "Local", modelID: "qwen:7b",
            configurationFingerprint: fingerprint, skillIdentifiers: ["browser"],
            conversationID: session
        )
        #expect(fresh.snapshotID.hasPrefix("context:v2:"))
        let freshIdentity = AgentExecutionIdentity(
            turn: AgentTurnIdentity(sessionID: session, turnID: 2, messageID: "fresh-message"),
            operationID: "fresh-operation"
        )
        #expect(try store.begin(identity: freshIdentity, snapshot: fresh))
        let saved = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let savedRecords = try #require(saved["records"] as? [[String: Any]])
        #expect(savedRecords.contains { NSDictionary(dictionary: $0).isEqual(to: rawOld) })
        let restarted = try AgentTurnContextStore(persistenceURL: url)
        #expect(restarted.record(for: oldIdentity) == nil)
        #expect(restarted.record(for: freshIdentity)?.status == .active)

        // The old delimiter formula also maps Local API:qwen / 7b to the same ID.
        // Keeping both bindings under that ID would make historical identity
        // interpretation ambiguous, even though neither may execute.
        let alias = ConversationContextSnapshotV1(
            snapshotID: oldID, sessionID: session, providerID: "Local API:qwen", modelID: "7b",
            configurationFingerprint: fingerprint, skillIdentifiers: ["browser"],
            conversationID: session
        )
        let aliasIdentity = AgentExecutionIdentity(
            turn: AgentTurnIdentity(sessionID: session, turnID: 3, messageID: "alias-message"),
            operationID: "alias-operation"
        )
        let aliasRecord = AgentTurnContextRecord(identity: aliasIdentity, snapshot: alias, status: .active)
        let rawAlias = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(aliasRecord)) as? [String: Any]
        )
        let collision = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "records": [rawOld, rawAlias]
        ])
        try collision.write(to: url)
        #expect(throws: AgentTurnContextStoreError.invalidSnapshotRecovery(.legacySnapshotBindingCollision)) {
            _ = try AgentTurnContextStore(persistenceURL: url)
        }
        #expect(try Data(contentsOf: url) == collision)

        let duplicateIdentity = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "records": [rawOld, rawOld]
        ])
        try duplicateIdentity.write(to: url)
        #expect(throws: AgentTurnContextStoreError.corruptStore) {
            _ = try AgentTurnContextStore(persistenceURL: url)
        }
        #expect(try Data(contentsOf: url) == duplicateIdentity)
    }

    @Test("historical retention still rejects unbounded or control-bearing fields")
    func historicalRetentionKeepsFieldAndSessionBounds() throws {
        let (directory, url) = persistenceURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = "00000000-0000-4000-8000-000000000001"
        let identity = AgentExecutionIdentity(
            turn: AgentTurnIdentity(sessionID: session, turnID: 1, messageID: "old-message"),
            operationID: "old-operation"
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let rejectedProviders: [(String, AgentTurnContextSnapshotRecoveryReason)] = [
            (String(repeating: "p", count: 257), .legacySizeLimit),
            ("Local\u{0001}API", .legacyBindingShape)
        ]
        for (providerID, expectedReason) in rejectedProviders {
            let fingerprint = "chat:v1:\(providerID):model:1024"
            let oldID = "context:\(session):\(providerID):model:\(fingerprint):browser:\(session)"
            let old = ConversationContextSnapshotV1(
                snapshotID: oldID, sessionID: session, providerID: providerID, modelID: "model",
                configurationFingerprint: fingerprint, skillIdentifiers: ["browser"],
                conversationID: session
            )
            let record = AgentTurnContextRecord(identity: identity, snapshot: old, status: .active)
            let rawRecord = try #require(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any]
            )
            let envelope = try JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1, "records": [rawRecord]
            ])
            try envelope.write(to: url)
            #expect(throws: AgentTurnContextStoreError.invalidSnapshotRecovery(expectedReason)) {
                _ = try AgentTurnContextStore(persistenceURL: url)
            }
            #expect(try Data(contentsOf: url) == envelope)
        }
    }

    @Test("historical rejection stages distinguish session linkage from fingerprint grammar")
    func historicalRetentionReportsFixedStagesWithoutPayload() throws {
        let (directory, url) = persistenceURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let canonicalSession = "AAAAAAAA-0000-4000-8000-000000000001"
        let cases: [(String, String, AgentTurnContextSnapshotRecoveryReason)] = [
            (canonicalSession.lowercased(), "chat:v1:mock:model:1024", .legacySessionBinding),
            (canonicalSession, "chat:v1:mock:model:0", .legacyFingerprintShape)
        ]
        for (session, fingerprint, expectedReason) in cases {
            let oldID = "context:\(session):mock:model:\(fingerprint):browser:\(session)"
            let old = ConversationContextSnapshotV1(
                snapshotID: oldID, sessionID: session, providerID: "mock", modelID: "model",
                configurationFingerprint: fingerprint, skillIdentifiers: ["browser"],
                conversationID: session
            )
            let identity = AgentExecutionIdentity(
                turn: AgentTurnIdentity(sessionID: session, turnID: 1, messageID: "old-message"),
                operationID: "old-operation"
            )
            let record = AgentTurnContextRecord(identity: identity, snapshot: old, status: .active)
            let rawRecord = try #require(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any]
            )
            let envelope = try JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1, "records": [rawRecord]
            ])
            try envelope.write(to: url)
            #expect(throws: AgentTurnContextStoreError.invalidSnapshotRecovery(expectedReason)) {
                _ = try AgentTurnContextStore(persistenceURL: url)
            }
            #expect(try Data(contentsOf: url) == envelope)
        }
        for reason in [
            AgentTurnContextSnapshotRecoveryReason.legacySizeLimit,
            .legacyBindingShape, .legacySessionBinding,
            .legacyFingerprintShape, .legacySnapshotBindingCollision
        ] {
            #expect(!reason.rawValue.contains("mock"))
            #expect(!reason.rawValue.contains(canonicalSession))
        }
    }
}
