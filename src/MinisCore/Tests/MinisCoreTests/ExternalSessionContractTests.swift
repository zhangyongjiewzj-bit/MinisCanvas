import Foundation
import Testing
@testable import MinisCore

@Suite("Existing external-session adapter contract")
struct ExternalSessionContractTests {
    private let sourceID = ExternalSessionSourceID(rawValue: "profile-a/codex")
    private let profileID = ExternalSessionProfileID(rawValue: "profile-a")
    private let threadID = ExternalSessionThreadID(rawValue: "thread-1")
    private let turnID = ExternalSessionTurnID(rawValue: "turn-1")

    @Test("source, thread, turn and event preserve versioned stable identity")
    func sourceThreadTurnEventRoundTripsVersion1() throws {
        let source = ExternalSessionSourceV1(
            sourceID: sourceID,
            kind: .codex,
            adapterVersion: "codex-adapter/1",
            profileID: profileID,
            hostID: "host-a",
            capabilities: [.readMetadata, .readMessages, .status, .stream],
            authState: .authorized
        )
        let thread = ExternalSessionThreadV1(
            sourceID: sourceID,
            threadID: threadID,
            projectID: ExternalSessionProjectID(rawValue: "project-1"),
            title: "bounded title",
            status: .active,
            updatedAt: Date(timeIntervalSince1970: 100),
            sourceCursor: ExternalSessionCursorV1(rawValue: "c-1"),
            readable: true
        )
        let turn = ExternalSessionTurnV1(
            sourceID: sourceID,
            threadID: threadID,
            turnID: turnID,
            status: .running,
            startedAt: Date(timeIntervalSince1970: 101),
            sourceCursor: ExternalSessionCursorV1(rawValue: "c-2")
        )
        let event = ExternalSessionEventV1(
            eventID: ExternalSessionEventID(rawValue: "event-1"),
            sourceID: sourceID,
            threadID: threadID,
            turnID: turnID,
            sequence: 1,
            sourceCursor: ExternalSessionCursorV1(rawValue: "c-3"),
            occurredAt: Date(timeIntervalSince1970: 102),
            required: true,
            kind: .progress,
            payload: ExternalSessionRedactedPayloadV1(kind: "progress", summary: "bounded"),
            sourceRef: "source-ref-digest"
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        #expect(try decoder.decode(ExternalSessionSourceV1.self, from: encoder.encode(source)) == source)
        #expect(try decoder.decode(ExternalSessionThreadV1.self, from: encoder.encode(thread)) == thread)
        #expect(try decoder.decode(ExternalSessionTurnV1.self, from: encoder.encode(turn)) == turn)
        #expect(try decoder.decode(ExternalSessionEventV1.self, from: encoder.encode(event)) == event)
        #expect(source.schemaVersion == ExternalSessionContractV1.schemaVersion)
        #expect(event.sequence == 1)
    }

    @Test("read and control grants remain separate capabilities")
    func readAndControlGrantsRemainDistinct() throws {
        let issued = Date(timeIntervalSince1970: 200)
        let read = ExternalSessionReadGrantV1(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "read-auth"),
            sourceID: sourceID,
            profileID: profileID,
            target: .thread(threadID),
            scopes: [.metadata, .messages, .status, .events],
            issuedAt: issued,
            expiresAt: issued.addingTimeInterval(60),
            revocationEpoch: 7
        )
        let control = ExternalSessionControlGrantV1(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "control-auth"),
            sourceID: sourceID,
            profileID: profileID,
            target: .thread(threadID),
            operations: [.resume, .fork, .steer, .interrupt],
            issuedAt: issued,
            expiresAt: issued.addingTimeInterval(30),
            revocationEpoch: 7
        )

        #expect(read.schemaVersion == 1)
        #expect(control.schemaVersion == 1)
        #expect(read.authorizationID != control.authorizationID)
        #expect(read.scopes.contains(.messages))
        #expect(control.operations.contains(.interrupt))
        let readData = try JSONEncoder().encode(read)
        let controlData = try JSONEncoder().encode(control)
        #expect(try JSONDecoder().decode(ExternalSessionReadGrantV1.self, from: readData) == read)
        #expect(try JSONDecoder().decode(ExternalSessionControlGrantV1.self, from: controlData) == control)
    }

    @Test("opaque cursor and unknown control outcome survive round trip")
    func cursorAndUnknownOutcomeRoundTrip() throws {
        let receipt = ExternalSessionControlReceiptV1(
            sourceID: sourceID,
            threadID: threadID,
            turnID: turnID,
            operation: .resume,
            outcome: .unknownRequiresRecovery,
            operationID: ExternalSessionOperationID(rawValue: "remote-op-1"),
            sourceCursor: ExternalSessionCursorV1(rawValue: "cursor-after-submit"),
            detail: "needs user review"
        )
        let data = try JSONEncoder().encode(receipt)
        let decoded = try JSONDecoder().decode(ExternalSessionControlReceiptV1.self, from: data)
        #expect(decoded == receipt)
        #expect(decoded.outcome == .unknownRequiresRecovery)
        #expect(decoded.sourceCursor.rawValue == "cursor-after-submit")
    }

    @Test("control request carries exact target, expected cursor and idempotency")
    func controlRequestCarriesStableIdentityAndIdempotency() throws {
        let request = ExternalSessionControlRequestV1(
            sourceID: sourceID,
            threadID: threadID,
            turnID: turnID,
            operation: .steer,
            expectedCursor: ExternalSessionCursorV1(rawValue: "cursor-4"),
            expectedSequence: 4,
            idempotencyKey: "profile-a/thread-1/turn-1/steer/4",
            boundedInput: "continue with the next bounded step"
        )
        let decoded = try JSONDecoder().decode(
            ExternalSessionControlRequestV1.self,
            from: JSONEncoder().encode(request)
        )
        #expect(decoded == request)
        #expect(decoded.sourceID == sourceID)
        #expect(decoded.threadID == threadID)
        #expect(decoded.turnID == turnID)
        #expect(decoded.idempotencyKey.contains("thread-1"))
    }

    @Test("event envelope preserves required kind, sequence and bounded source reference")
    func eventEnvelopeCarriesContiguousSequenceAndRedactedSourceRef() throws {
        let first = ExternalSessionEventV1(
            eventID: ExternalSessionEventID(rawValue: "event-1"),
            sourceID: sourceID,
            threadID: threadID,
            turnID: turnID,
            sequence: 1,
            sourceCursor: ExternalSessionCursorV1(rawValue: "cursor-1"),
            occurredAt: Date(timeIntervalSince1970: 300),
            required: true,
            kind: .turnStarted,
            payload: ExternalSessionRedactedPayloadV1(kind: "turn", summary: "started"),
            sourceRef: "digest:event-1"
        )
        let second = ExternalSessionEventV1(
            eventID: ExternalSessionEventID(rawValue: "event-2"),
            sourceID: sourceID,
            threadID: threadID,
            turnID: turnID,
            sequence: 2,
            sourceCursor: ExternalSessionCursorV1(rawValue: "cursor-2"),
            occurredAt: Date(timeIntervalSince1970: 301),
            required: true,
            kind: .turnCompleted,
            payload: ExternalSessionRedactedPayloadV1(kind: "turn", summary: "completed"),
            sourceRef: "digest:event-2"
        )
        let events = [first, second]
        #expect(events.map(\.sequence) == [1, 2])
        #expect(events.allSatisfy { $0.required })
        #expect(events.allSatisfy { !$0.sourceRef.contains("Bearer") })
        #expect(try JSONDecoder().decode(
            [ExternalSessionEventV1].self,
            from: JSONEncoder().encode(events)
        ) == events)
    }

    @Test("reconnect fence deduplicates by correlation, attempt and event")
    func reconnectFenceRejectsDuplicateAndStaleAttempt() {
        let fence = ExternalAgentReconnectFence()
        let firstIdentity = ExternalAgentInvocationIdentity(
            correlationID: "correlation-1",
            attemptID: "attempt-1"
        )
        let secondIdentity = ExternalAgentInvocationIdentity(
            correlationID: "correlation-1",
            attemptID: "attempt-2"
        )
        let event = ExternalAgentTerminalEventV1(
            identity: firstIdentity,
            eventID: "terminal-1",
            sourceID: sourceID,
            threadID: threadID,
            sequence: 1,
            sourceCursor: .beginning,
            occurredAt: Date(timeIntervalSince1970: 400),
            connectionGeneration: 1,
            outcome: .succeeded,
            summary: "Bearer secret /private/raw/output"
        )

        #expect(fence.reconnect(identity: firstIdentity))
        #expect(fence.accept(event) == .accepted)
        #expect(fence.accept(event) == .rejectedDuplicate)
        #expect(fence.reconnect(identity: secondIdentity))
        #expect(fence.accept(event) == .rejectedStaleAttempt)
        #expect(event.redactedSummary == "[REDACTED] [REDACTED] [REDACTED_PATH]")
    }

    @Test("stopped external attempt rejects a late terminal event")
    func reconnectFenceRejectsCompletionAfterStop() {
        let fence = ExternalAgentReconnectFence()
        let identity = ExternalAgentInvocationIdentity(
            correlationID: "correlation-stop",
            attemptID: "attempt-stop"
        )
        let event = ExternalAgentTerminalEventV1(
            identity: identity,
            eventID: "terminal-stop",
            sourceID: sourceID,
            threadID: threadID,
            sequence: 1,
            sourceCursor: .beginning,
            occurredAt: Date(timeIntervalSince1970: 401),
            connectionGeneration: 2,
            outcome: .cancelled,
            summary: "cancelled"
        )

        #expect(fence.reconnect(identity: identity))
        #expect(fence.stop(identity: identity))
        #expect(fence.accept(event) == .rejectedStopped)
    }
}
