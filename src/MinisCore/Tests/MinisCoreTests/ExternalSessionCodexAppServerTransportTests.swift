import Foundation
import Testing

@testable import MinisCore

/// Fake byte seam only: records payloads and cancellation notices, never touches
/// a socket, pipe or file descriptor.
private actor RecordingByteTransport: ExternalSessionAppServerByteTransport {
    enum Behavior: Sendable {
        case respond(Data)
        case hang
    }

    private(set) var payloads: [Data] = []
    private(set) var cancelledRequestIDs: [String] = []
    private var behavior: Behavior = .hang

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func send(payload: Data, requestID: String) async throws -> Data {
        payloads.append(payload)
        switch behavior {
        case .respond(let data):
            return data
        case .hang:
            try await Task.sleep(nanoseconds: 600_000_000_000)
            return Data()
        }
    }

    func cancel(requestID: String) async {
        cancelledRequestIDs.append(requestID)
    }
}

@Suite("External-session Codex app-server transport codec")
struct ExternalSessionCodexAppServerTransportTests {
    private let sourceID = ExternalSessionSourceID(rawValue: "codex-app-server-a")
    private let threadID = ExternalSessionThreadID(rawValue: "thread-42")
    private let turnID = ExternalSessionTurnID(rawValue: "turn-7")
    private let cursor = ExternalSessionCursorV1(rawValue: "cursor-9")
    private let idempotencyKey = "idem-1"
    private let fixedRequestID = "req-fixed"

    // MARK: Helpers

    private func makeRequest(
        operation: ExternalSessionControlOperationV1,
        expectedSequence: UInt64? = nil,
        boundedInput: String? = nil,
        withTurn: Bool = true
    ) -> ExternalSessionControlRequestV1 {
        ExternalSessionControlRequestV1(
            sourceID: sourceID,
            threadID: threadID,
            turnID: withTurn ? turnID : nil,
            operation: operation,
            expectedCursor: cursor,
            expectedSequence: expectedSequence,
            idempotencyKey: idempotencyKey,
            boundedInput: boundedInput
        )
    }

    private func makeTransport(
        _ behavior: RecordingByteTransport.Behavior,
        timeoutNanoseconds: UInt64 = 2_000_000_000
    ) -> (ExternalSessionCodexAppServerTransport, RecordingByteTransport) {
        let seam = RecordingByteTransport(behavior: behavior)
        let transport = ExternalSessionCodexAppServerTransport(
            byteTransport: seam,
            timeoutNanoseconds: timeoutNanoseconds,
            requestIDFactory: { self.fixedRequestID }
        )
        return (transport, seam)
    }

    private func successJSON(
        outcome: String = "accepted",
        protocolVersion: Int = ExternalSessionCodexAppServerProtocolV1.wireProtocolVersion,
        requestID: String? = nil,
        sequence: UInt64? = nil,
        echoedSource: String? = nil,
        echoedThread: String? = nil,
        echoedKey: String? = nil
    ) throws -> Data {
        let envelope = ExternalSessionAppServerWireEnvelopeV1(
            protocolVersion: protocolVersion,
            requestID: requestID ?? fixedRequestID,
            success: .init(
                outcome: outcome,
                operationID: "op-1",
                sourceCursor: "cursor-10",
                sequence: sequence,
                idempotencyKey: echoedKey ?? idempotencyKey,
                sourceID: echoedSource ?? sourceID.rawValue,
                threadID: echoedThread ?? threadID.rawValue,
                detail: "server detail"
            ),
            error: nil
        )
        return try JSONEncoder().encode(envelope)
    }

    private func failureJSON(appCode: String, message: String) throws -> Data {
        let envelope = ExternalSessionAppServerWireEnvelopeV1(
            protocolVersion: ExternalSessionCodexAppServerProtocolV1.wireProtocolVersion,
            requestID: fixedRequestID,
            success: nil,
            error: .init(appCode: appCode, message: message)
        )
        return try JSONEncoder().encode(envelope)
    }

    private func decodeSentRequest(_ data: Data) throws -> ExternalSessionAppServerWireRequestV1 {
        try JSONDecoder().decode(ExternalSessionAppServerWireRequestV1.self, from: data)
    }

    // MARK: Encoding: four session actions

    @Test("resume, fork, steer and interrupt encode to distinct wire methods")
    func fourActionsEncodeDistinctMethods() async throws {
        let expected: [(ExternalSessionControlOperationV1, String)] = [
            (.resume, "session.resume"),
            (.fork, "session.fork"),
            (.steer, "session.steer"),
            (.interrupt, "session.interrupt"),
        ]
        for (operation, method) in expected {
            let json = try successJSON()
            let (transport, seam) = makeTransport(.respond(json))
            let request = makeRequest(
                operation: operation,
                boundedInput: operation == .steer ? "new direction" : nil
            )
            _ = try await transport.control(request)
            let payloads = await seam.payloads
            #expect(payloads.count == 1)
            let wire = try decodeSentRequest(payloads[0])
            #expect(wire.method == method)
            #expect(wire.requestID == fixedRequestID)
            #expect(wire.protocolVersion == ExternalSessionCodexAppServerProtocolV1.wireProtocolVersion)
            #expect(wire.sourceID == sourceID.rawValue)
            #expect(wire.threadID == threadID.rawValue)
            #expect(wire.turnID == turnID.rawValue)
            #expect(wire.idempotencyKey == idempotencyKey)
            #expect(wire.expectedCursor == cursor.rawValue)
        }
    }

    @Test("steer carries bounded input and optional fields survive encoding")
    func steerCarriesBoundedInputAndOmitsAbsentOptionals() async throws {
        let json = try successJSON(sequence: 5)
        let (transport, seam) = makeTransport(.respond(json))
        _ = try await transport.steer(makeRequest(operation: .steer, expectedSequence: 5, boundedInput: "hold course"))
        let payloads = await seam.payloads
        let wire = try decodeSentRequest(payloads[0])
        #expect(wire.boundedInput == "hold course")
        #expect(wire.expectedSequence == 5)

        let (transport2, seam2) = makeTransport(.respond(try successJSON()))
        _ = try await transport2.resume(makeRequest(operation: .resume, withTurn: false))
        let wire2 = try decodeSentRequest(await seam2.payloads[0])
        #expect(wire2.turnID == nil)
        #expect(wire2.boundedInput == nil)
        #expect(wire2.expectedSequence == nil)
    }

    // MARK: Successful projection

    @Test("success envelope projects a full control receipt")
    func successProjectsReceipt() async throws {
        let json = try successJSON(outcome: "completed")
        let (transport, _) = makeTransport(.respond(json))
        let receipt = try await transport.control(makeRequest(operation: .fork))
        #expect(receipt.schemaVersion == ExternalSessionContractV1.schemaVersion)
        #expect(receipt.sourceID == sourceID)
        #expect(receipt.threadID == threadID)
        #expect(receipt.turnID == turnID)
        #expect(receipt.operation == .fork)
        #expect(receipt.outcome == .completed)
        #expect(receipt.operationID == ExternalSessionOperationID(rawValue: "op-1"))
        #expect(receipt.sourceCursor == ExternalSessionCursorV1(rawValue: "cursor-10"))
        #expect(receipt.detail == "server detail")
    }

    // MARK: Error envelope

    @Test("error envelope relays app code and message without producing a receipt")
    func errorEnvelopeIsRelayed() async throws {
        let json = try failureJSON(appCode: "thread_locked", message: "turn still running")
        let (transport, _) = makeTransport(.respond(json))
        await #expect(throws: ExternalSessionAppServerTransportError.relayed(
            appCode: "thread_locked",
            message: "turn still running"
        )) {
            _ = try await transport.interrupt(makeRequest(operation: .interrupt))
        }
    }

    // MARK: Version and sequence fail-closed

    @Test("non-current contract schema is rejected before any transport call")
    func staleContractSchemaFailsClosed() async throws {
        let (transport, seam) = makeTransport(.respond(try successJSON()))
        let stale = ExternalSessionControlRequestV1(
            schemaVersion: ExternalSessionContractV1.schemaVersion + 1,
            sourceID: sourceID,
            threadID: threadID,
            operation: .resume,
            expectedCursor: cursor,
            idempotencyKey: idempotencyKey
        )
        await #expect(throws: ExternalSessionAppServerTransportError.contractSchemaVersionMismatch(
            expected: ExternalSessionContractV1.schemaVersion,
            found: ExternalSessionContractV1.schemaVersion + 1
        )) {
            _ = try await transport.control(stale)
        }
        #expect(await seam.payloads.isEmpty)
    }

    @Test("wire protocol version mismatch fails closed before payload interpretation")
    func wireProtocolVersionMismatchFailsClosed() async throws {
        let json = try successJSON(
            outcome: "not-a-real-outcome-token",
            protocolVersion: ExternalSessionCodexAppServerProtocolV1.wireProtocolVersion + 1
        )
        let (transport, _) = makeTransport(.respond(json))
        await #expect(throws: ExternalSessionAppServerTransportError.protocolVersionMismatch(
            expected: ExternalSessionCodexAppServerProtocolV1.wireProtocolVersion,
            found: ExternalSessionCodexAppServerProtocolV1.wireProtocolVersion + 1
        )) {
            _ = try await transport.control(makeRequest(operation: .resume))
        }
    }

    @Test("expected sequence must be echoed exactly or the response fails closed")
    func sequenceMismatchFailsClosed() async throws {
        let wrongSeq = try successJSON(sequence: 6)
        let (transport, _) = makeTransport(.respond(wrongSeq))
        await #expect(throws: ExternalSessionAppServerTransportError.sequenceMismatch(expected: 5, found: 6)) {
            _ = try await transport.control(makeRequest(operation: .steer, expectedSequence: 5, boundedInput: "x"))
        }

        let missingSeq = try successJSON(sequence: nil)
        let (transport2, _) = makeTransport(.respond(missingSeq))
        await #expect(throws: ExternalSessionAppServerTransportError.sequenceMismatch(expected: 5, found: nil)) {
            _ = try await transport2.control(makeRequest(operation: .resume, expectedSequence: 5))
        }
    }

    @Test("response identity fields must echo the request or decoding fails closed")
    func identityMismatchFailsClosed() async throws {
        let cases: [(Data, String)] = [
            (try successJSON(requestID: "other-req"), "requestID"),
            (try successJSON(echoedSource: "someone-else"), "sourceID"),
            (try successJSON(echoedThread: "other-thread"), "threadID"),
            (try successJSON(echoedKey: "other-key"), "idempotencyKey"),
        ]
        for (json, field) in cases {
            let (transport, _) = makeTransport(.respond(json))
            await #expect(throws: ExternalSessionAppServerTransportError.identityMismatch(field: field)) {
                _ = try await transport.control(makeRequest(operation: .resume))
            }
        }
    }

    // MARK: Malformed envelopes

    @Test("envelope shape violations are malformed responses, never defaults")
    func malformedEnvelopesFailClosed() async throws {
        let both = Data(
            """
            {
              "protocolVersion": 1,
              "requestID": "req-fixed",
              "success": {"outcome":"accepted","operationID":null,"sourceCursor":"c","sequence":null,
                          "idempotencyKey":"idem-1","sourceID":"codex-app-server-a","threadID":"thread-42","detail":null},
              "error": {"appCode":"weird","message":"also weird"}
            }
            """.utf8
        )
        let (transportBoth, _) = makeTransport(.respond(both))
        await #expect(throws: ExternalSessionAppServerTransportError.malformedResponse(
            reason: "envelope carries both success and error"
        )) {
            _ = try await transportBoth.control(makeRequest(operation: .resume))
        }

        let neither = Data(
            """
            {"protocolVersion":1,"requestID":"req-fixed","success":null,"error":null}
            """.utf8
        )
        let (transportNeither, _) = makeTransport(.respond(neither))
        await #expect(throws: ExternalSessionAppServerTransportError.malformedResponse(
            reason: "envelope carries neither success nor error"
        )) {
            _ = try await transportNeither.control(makeRequest(operation: .resume))
        }

        let unknownOutcome = try successJSON(outcome: "done")
        let (transportUnknown, _) = makeTransport(.respond(unknownOutcome))
        await #expect(throws: ExternalSessionAppServerTransportError.malformedResponse(
            reason: "unrecognized outcome token \"done\""
        )) {
            _ = try await transportUnknown.control(makeRequest(operation: .resume))
        }

        let garbage = Data("this is not json".utf8)
        let (transportGarbage, _) = makeTransport(.respond(garbage))
        await #expect(throws: (any Error).self) {
            _ = try await transportGarbage.control(makeRequest(operation: .resume))
        }
    }

    // MARK: Scope guards, no transport call

    @Test("operations outside resume/fork/steer/interrupt are rejected pre-transport")
    func outOfScopeOperationsRejected() async throws {
        for operation in [
            ExternalSessionControlOperationV1.approve,
            .reject,
            .provideInput,
        ] {
            let (transport, seam) = makeTransport(.respond(Data()))
            await #expect(throws: ExternalSessionAppServerTransportError.unsupportedOperation(operation.rawValue)) {
                _ = try await transport.control(makeRequest(operation: operation))
            }
            #expect(await seam.payloads.isEmpty)
        }
    }

    @Test("steer without bounded input fails closed and never reaches the seam")
    func steerWithoutInputFailsClosed() async throws {
        let (transportEmpty, seamEmpty) = makeTransport(.respond(Data()))
        await #expect(throws: ExternalSessionAppServerTransportError.invalidRequest(
            reason: "steer requires non-empty boundedInput"
        )) {
            _ = try await transportEmpty.control(makeRequest(operation: .steer, boundedInput: "   \n "))
        }
        #expect(await seamEmpty.payloads.isEmpty)

        let (transportNil, seamNil) = makeTransport(.respond(Data()))
        await #expect(throws: ExternalSessionAppServerTransportError.invalidRequest(
            reason: "steer requires non-empty boundedInput"
        )) {
            _ = try await transportNil.control(makeRequest(operation: .steer))
        }
        #expect(await seamNil.payloads.isEmpty)
    }

    @Test("bounded input on operations other than steer fails closed")
    func strayBoundedInputFailsClosed() async throws {
        let (transport, seam) = makeTransport(.respond(Data()))
        await #expect(throws: ExternalSessionAppServerTransportError.invalidRequest(
            reason: "boundedInput is only defined for steer, not resume"
        )) {
            _ = try await transport.control(makeRequest(operation: .resume, boundedInput: "not allowed"))
        }
        #expect(await seam.payloads.isEmpty)
    }

    @Test("per-action entry points reject a request carrying another operation")
    func convenienceGuardsRejectMismatchedOperation() async throws {
        let (transport, seam) = makeTransport(.respond(Data()))
        await #expect(throws: (any Error).self) {
            _ = try await transport.resume(makeRequest(operation: .fork))
        }
        await #expect(throws: (any Error).self) {
            _ = try await transport.interrupt(makeRequest(operation: .steer, boundedInput: "x"))
        }
        #expect(await seam.payloads.isEmpty)
    }

    // MARK: Timeout and cancellation propagation

    @Test("timeout throws and the in-flight request is cancelled on the seam")
    func timeoutCancelsSeamRequest() async throws {
        let (transport, seam) = makeTransport(.hang, timeoutNanoseconds: 30_000_000)
        await #expect(throws: ExternalSessionAppServerTransportError.timedOut) {
            _ = try await transport.control(makeRequest(operation: .resume))
        }
        #expect(await seam.cancelledRequestIDs == [fixedRequestID])
    }

    @Test("cancelling the surrounding task surfaces as cancelled and notifies the seam")
    func taskCancellationPropagates() async throws {
        let (transport, seam) = makeTransport(.hang, timeoutNanoseconds: 5_000_000_000)
        let request = makeRequest(operation: .steer, boundedInput: "x")
        let work = Task { try await transport.control(request) }
        try await Task.sleep(nanoseconds: 50_000_000)
        work.cancel()
        await #expect(throws: ExternalSessionAppServerTransportError.cancelled) {
            _ = try await work.value
        }
        let ids = await seam.cancelledRequestIDs
        #expect(ids.contains(fixedRequestID))
    }
}
