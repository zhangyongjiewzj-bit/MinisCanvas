import Foundation

// MARK: - Injected byte transport seam

/// Byte-level request/response seam for a Codex app-server style RPC.
///
/// The seam is deliberately expressed as raw `Data` in and `Data` out with a
/// caller-supplied request identifier so this file contains no socket, pipe or
/// file-descriptor code at all. A production implementation (owned by the
/// composition root, not by this layer) would own the actual connection; test
/// implementations inject deterministic fixtures. `cancel(requestID:)` must be
/// safe to call for an identifier that already completed or never started.
public protocol ExternalSessionAppServerByteTransport: Sendable {
    /// Sends one encoded request payload and awaits the correlated response bytes.
    func send(payload: Data, requestID: String) async throws -> Data

    /// Propagates cancellation/abandonment of a previously started request.
    func cancel(requestID: String) async
}

// MARK: - Protocol version namespace

/// Version namespace for the app-server wire envelope. This is separate from
/// `ExternalSessionContractV1.schemaVersion`: the contract describes MinisCore
/// domain values, while the protocol version pins the wire envelope shape the
/// transport will decode. Both currently start at 1.
public enum ExternalSessionCodexAppServerProtocolV1 {
    public static let wireProtocolVersion = 1
}

// MARK: - Errors

/// Every failure mode of the transport layer. All cases fail closed: the
/// transport either returns a validated receipt or throws, never a partial or
/// defaulted value.
public enum ExternalSessionAppServerTransportError: Error, Equatable, Sendable {
    /// Operation outside the resume/fork/steer/interrupt scope of this transport.
    case unsupportedOperation(String)
    /// Incoming `ExternalSessionControlRequestV1` carried a non-current contract schema.
    case contractSchemaVersionMismatch(expected: Int, found: Int)
    /// Wire envelope declared a protocol version other than the expected one.
    /// Checked before the payload is interpreted.
    case protocolVersionMismatch(expected: Int, found: Int)
    /// Caller pinned `expectedSequence` and the server echoed a different (or missing) value.
    case sequenceMismatch(expected: UInt64, found: UInt64?)
    /// Response did not echo the request identity it is supposed to belong to.
    case identityMismatch(field: String)
    /// Request is not encodable for its operation under the minimal wire semantics.
    case invalidRequest(reason: String)
    /// Response bytes are not a well-formed envelope, carry both or neither
    /// success and error, or contain an unrecognized outcome token.
    case malformedResponse(reason: String)
    /// Server returned a structured failure; surfaced verbatim without fallback.
    case relayed(appCode: String, message: String)
    /// Correlated response did not arrive within the configured timeout.
    case timedOut
    /// The surrounding task was cancelled while a request was in flight.
    case cancelled
}

// MARK: - Wire payloads (internal: codec is exercised through the public API)

struct ExternalSessionAppServerWireRequestV1: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let requestID: String
    let method: String
    let sourceID: String
    let threadID: String
    let turnID: String?
    let idempotencyKey: String
    let expectedCursor: String
    let expectedSequence: UInt64?
    let boundedInput: String?
}

struct ExternalSessionAppServerWireEnvelopeV1: Codable, Equatable, Sendable {
    struct Success: Codable, Equatable, Sendable {
        let outcome: String
        let operationID: String?
        let sourceCursor: String
        let sequence: UInt64?
        let idempotencyKey: String
        let sourceID: String
        let threadID: String
        let detail: String?
    }

    struct Failure: Codable, Equatable, Sendable {
        let appCode: String
        let message: String
    }

    let protocolVersion: Int
    let requestID: String
    let success: Success?
    let error: Failure?
}

// MARK: - Transport adapter

/// Transport adapter and request/response/error codec for the four external
/// session control actions (resume, fork, steer, interrupt) behind an injected
/// byte seam.
///
/// Boundaries of this layer, all deliberate:
/// - It does not consult or mutate any authorization ledger; grant
///   enforcement belongs to `ExternalSessionControlLedgerAdapter` (DEV-237)
///   and must run before a request reaches this type.
/// - It performs no I/O itself: every byte crosses the injected
///   `ExternalSessionAppServerByteTransport`.
/// - It never fabricates a receipt on timeout, cancellation or a mismatched
///   response; those paths throw so an upstream owner can decide recovery.
/// - Version and sequence checks are strict equality; a mismatch is thrown,
///   not downgraded, and unknown tokens are `malformedResponse`, not defaults.
public struct ExternalSessionCodexAppServerTransport: Sendable {
    private let byteTransport: any ExternalSessionAppServerByteTransport
    private let expectedProtocolVersion: Int
    private let timeoutNanoseconds: UInt64
    private let requestIDFactory: @Sendable () -> String

    public init(
        byteTransport: any ExternalSessionAppServerByteTransport,
        expectedProtocolVersion: Int = ExternalSessionCodexAppServerProtocolV1.wireProtocolVersion,
        timeoutNanoseconds: UInt64,
        requestIDFactory: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        precondition(timeoutNanoseconds > 0, "transport timeout must be positive")
        self.byteTransport = byteTransport
        self.expectedProtocolVersion = expectedProtocolVersion
        self.timeoutNanoseconds = timeoutNanoseconds
        self.requestIDFactory = requestIDFactory
    }

    // MARK: Public control surface

    /// Encodes, sends and validates one control request for one of the four
    /// supported session actions.
    public func control(_ request: ExternalSessionControlRequestV1) async throws -> ExternalSessionControlReceiptV1 {
        let requestID = requestIDFactory()
        let payload = try Self.encode(request, requestID: requestID, expectedProtocolVersion: expectedProtocolVersion)
        let responseBytes = try await sendWithCancellationAndTimeout(payload: payload, requestID: requestID)
        let receipt = try Self.decode(responseBytes, for: request, requestID: requestID, expectedProtocolVersion: expectedProtocolVersion)
        return receipt
    }

    public func resume(_ request: ExternalSessionControlRequestV1) async throws -> ExternalSessionControlReceiptV1 {
        try Self.requireOperation(request, .resume)
        return try await control(request)
    }

    public func fork(_ request: ExternalSessionControlRequestV1) async throws -> ExternalSessionControlReceiptV1 {
        try Self.requireOperation(request, .fork)
        return try await control(request)
    }

    public func steer(_ request: ExternalSessionControlRequestV1) async throws -> ExternalSessionControlReceiptV1 {
        try Self.requireOperation(request, .steer)
        return try await control(request)
    }

    public func interrupt(_ request: ExternalSessionControlRequestV1) async throws -> ExternalSessionControlReceiptV1 {
        try Self.requireOperation(request, .interrupt)
        return try await control(request)
    }

    // MARK: Operation guard

    static func requireOperation(
        _ request: ExternalSessionControlRequestV1,
        _ expected: ExternalSessionControlOperationV1
    ) throws {
        guard request.operation == expected else {
            throw ExternalSessionAppServerTransportError.unsupportedOperation(
                "per-action entry point \(expected.rawValue) received operation \(request.operation.rawValue)"
            )
        }
    }

    // MARK: Encoding

    static func method(for operation: ExternalSessionControlOperationV1) throws -> String {
        switch operation {
        case .resume: return "session.resume"
        case .fork: return "session.fork"
        case .steer: return "session.steer"
        case .interrupt: return "session.interrupt"
        case .approve, .reject, .provideInput:
            throw ExternalSessionAppServerTransportError.unsupportedOperation(operation.rawValue)
        }
    }

    static func encode(
        _ request: ExternalSessionControlRequestV1,
        requestID: String,
        expectedProtocolVersion: Int
    ) throws -> Data {
        guard request.schemaVersion == ExternalSessionContractV1.schemaVersion else {
            throw ExternalSessionAppServerTransportError.contractSchemaVersionMismatch(
                expected: ExternalSessionContractV1.schemaVersion,
                found: request.schemaVersion
            )
        }
        let method = try method(for: request.operation)

        switch request.operation {
        case .steer:
            guard let input = request.boundedInput, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ExternalSessionAppServerTransportError.invalidRequest(reason: "steer requires non-empty boundedInput")
            }
        default:
            guard request.boundedInput == nil else {
                throw ExternalSessionAppServerTransportError.invalidRequest(
                    reason: "boundedInput is only defined for steer, not \(request.operation.rawValue)"
                )
            }
        }

        let wire = ExternalSessionAppServerWireRequestV1(
            protocolVersion: expectedProtocolVersion,
            requestID: requestID,
            method: method,
            sourceID: request.sourceID.rawValue,
            threadID: request.threadID.rawValue,
            turnID: request.turnID?.rawValue,
            idempotencyKey: request.idempotencyKey,
            expectedCursor: request.expectedCursor.rawValue,
            expectedSequence: request.expectedSequence,
            boundedInput: request.boundedInput
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(wire)
        } catch {
            throw ExternalSessionAppServerTransportError.malformedResponse(reason: "request encoding failed: \(type(of: error))")
        }
    }

    // MARK: Decoding

    static func decode(
        _ data: Data,
        for request: ExternalSessionControlRequestV1,
        requestID: String,
        expectedProtocolVersion: Int
    ) throws -> ExternalSessionControlReceiptV1 {
        let decoder = JSONDecoder()
        let envelope: ExternalSessionAppServerWireEnvelopeV1
        do {
            envelope = try decoder.decode(ExternalSessionAppServerWireEnvelopeV1.self, from: data)
        } catch {
            throw ExternalSessionAppServerTransportError.malformedResponse(
                reason: "envelope decoding failed: \(type(of: error))"
            )
        }

        // Version check first: never interpret a payload from another protocol generation.
        guard envelope.protocolVersion == expectedProtocolVersion else {
            throw ExternalSessionAppServerTransportError.protocolVersionMismatch(
                expected: expectedProtocolVersion,
                found: envelope.protocolVersion
            )
        }
        guard envelope.requestID == requestID else {
            throw ExternalSessionAppServerTransportError.identityMismatch(field: "requestID")
        }

        switch (envelope.success, envelope.error) {
        case (_?, let failure?):
            _ = failure
            throw ExternalSessionAppServerTransportError.malformedResponse(reason: "envelope carries both success and error")
        case (nil, nil):
            throw ExternalSessionAppServerTransportError.malformedResponse(reason: "envelope carries neither success nor error")
        case (nil, let failure?):
            throw ExternalSessionAppServerTransportError.relayed(
                appCode: failure.appCode,
                message: failure.message
            )
        case (let success?, nil):
            return try project(success, for: request)
        }
    }

    private static func project(
        _ success: ExternalSessionAppServerWireEnvelopeV1.Success,
        for request: ExternalSessionControlRequestV1
    ) throws -> ExternalSessionControlReceiptV1 {
        let outcome: ExternalSessionControlOutcomeV1
        switch success.outcome {
        case "accepted": outcome = .accepted
        case "completed": outcome = .completed
        case "rejected": outcome = .rejected
        case "unsupported": outcome = .unsupported
        default:
            // No silent fallback: an unrecognized token is a protocol violation,
            // not an invitation to default to `unknownRequiresRecovery`.
            throw ExternalSessionAppServerTransportError.malformedResponse(
                reason: "unrecognized outcome token \(success.outcome.debugDescription)"
            )
        }

        guard success.sourceID == request.sourceID.rawValue else {
            throw ExternalSessionAppServerTransportError.identityMismatch(field: "sourceID")
        }
        guard success.threadID == request.threadID.rawValue else {
            throw ExternalSessionAppServerTransportError.identityMismatch(field: "threadID")
        }
        guard success.idempotencyKey == request.idempotencyKey else {
            throw ExternalSessionAppServerTransportError.identityMismatch(field: "idempotencyKey")
        }

        if let expected = request.expectedSequence {
            guard success.sequence == expected else {
                throw ExternalSessionAppServerTransportError.sequenceMismatch(expected: expected, found: success.sequence)
            }
        }

        return ExternalSessionControlReceiptV1(
            schemaVersion: ExternalSessionContractV1.schemaVersion,
            sourceID: request.sourceID,
            threadID: request.threadID,
            turnID: request.turnID,
            operation: request.operation,
            outcome: outcome,
            operationID: success.operationID.map(ExternalSessionOperationID.init(rawValue:)),
            sourceCursor: ExternalSessionCursorV1(rawValue: success.sourceCursor),
            detail: success.detail
        )
    }

    // MARK: Send with timeout and cancellation propagation

    private func sendWithCancellationAndTimeout(payload: Data, requestID: String) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask { [byteTransport] in
                    try await byteTransport.send(payload: payload, requestID: requestID)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    throw ExternalSessionAppServerTransportError.timedOut
                }
                do {
                    guard let first = try await group.next() else {
                        throw ExternalSessionAppServerTransportError.malformedResponse(reason: "transport produced no result")
                    }
                    group.cancelAll()
                    return first
                } catch {
                    group.cancelAll()
                    await byteTransport.cancel(requestID: requestID)
                    if error is CancellationError {
                        throw ExternalSessionAppServerTransportError.cancelled
                    }
                    throw error
                }
            }
        } onCancel: { [byteTransport] in
            // Cancel may arrive while no child is suspended yet; the seam contract
            // requires cancel(requestID:) to be idempotent for unknown identifiers.
            Task {
                await byteTransport.cancel(requestID: requestID)
            }
        }
    }
}
