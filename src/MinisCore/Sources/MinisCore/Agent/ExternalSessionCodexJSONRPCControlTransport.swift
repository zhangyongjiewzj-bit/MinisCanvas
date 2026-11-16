import Foundation

/// Official app-server control mapping for CLI 0.151.0 stable JSON-RPC.
/// The older `ExternalSessionCodexAppServerTransport` remains a separate
/// customWireV1 codec and is never presented as official compatibility.
public actor ExternalSessionCodexJSONRPCControlTransport: ExternalSessionControlTransportV1 {
    private let connection: any ExternalSessionCodexJSONRPCConnection
    private let sourceID: ExternalSessionSourceID
    private var consumedKeys: Set<String> = []

    public init(connection: any ExternalSessionCodexJSONRPCConnection, sourceID: ExternalSessionSourceID) {
        self.connection = connection
        self.sourceID = sourceID
    }

    public func send(request: ExternalSessionControlRequestV1,
                     controlGrant: ExternalSessionControlGrantV1) async throws -> ExternalSessionControlReceiptV1 {
        guard request.schemaVersion == ExternalSessionContractV1.schemaVersion,
              controlGrant.schemaVersion == ExternalSessionContractV1.schemaVersion,
              request.sourceID == sourceID, controlGrant.sourceID == sourceID,
              controlGrant.target == .thread(request.threadID),
              controlGrant.operations.contains(request.operation),
              controlGrant.parentConversationID == request.parentConversationID,
              controlGrant.parentTurnID == request.parentTurnID else {
            throw ExternalSessionAppServerTransportError.invalidRequest(reason: "control identity or grant mismatch")
        }
        // The official protocol carries no idempotency key, sequence or
        // conditional cursor. A non-nil sequence cannot be verified, so reject.
        guard request.expectedSequence == nil else {
            throw ExternalSessionAppServerTransportError.invalidRequest(reason: "official app-server has no conditional sequence")
        }
        guard !request.idempotencyKey.isEmpty, !consumedKeys.contains(request.idempotencyKey) else {
            throw ExternalSessionAppServerTransportError.invalidRequest(reason: "missing or already consumed idempotency key")
        }
        let method: String
        var params: [String: CodexJSONValue] = ["threadId": .string(request.threadID.rawValue)]
        switch request.operation {
        case .resume:
            guard request.turnID == nil, request.boundedInput == nil else {
                throw ExternalSessionAppServerTransportError.invalidRequest(reason: "resume takes no turn or input")
            }
            method = "thread/resume"
        case .fork:
            guard request.boundedInput == nil else {
                throw ExternalSessionAppServerTransportError.invalidRequest(reason: "fork takes no input")
            }
            if let turnID = request.turnID { params["lastTurnId"] = .string(turnID.rawValue) }
            method = "thread/fork"
        case .steer:
            guard let turnID = request.turnID,
                  let input = request.boundedInput,
                  !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ExternalSessionAppServerTransportError.invalidRequest(reason: "steer needs expected turn and text")
            }
            params["expectedTurnId"] = .string(turnID.rawValue)
            params["input"] = .array([.object(["type": .string("text"), "text": .string(input)])])
            method = "turn/steer"
        case .interrupt:
            guard let turnID = request.turnID, request.boundedInput == nil else {
                throw ExternalSessionAppServerTransportError.invalidRequest(reason: "interrupt needs turn and no input")
            }
            params["turnId"] = .string(turnID.rawValue)
            method = "turn/interrupt"
        case .approve, .reject, .provideInput:
            throw ExternalSessionAppServerTransportError.unsupportedOperation(request.operation.rawValue)
        }
        // Reserve before I/O. After timeout/disconnect an effect may already
        // have happened, and replaying the key would risk a duplicate fork or
        // steer. Reconciliation must be a separate read, not a blind retry.
        try Task.checkCancellation()
        consumedKeys.insert(request.idempotencyKey)
        let result = try await connection.request(method: method, params: params)
        let detail: String
        let outcome: ExternalSessionControlOutcomeV1
        var childThreadID: ExternalSessionThreadID?
        switch request.operation {
        case .resume:
            guard result["thread"]?.objectValue?["id"]?.stringValue == request.threadID.rawValue else {
                throw ExternalSessionAppServerTransportError.identityMismatch(field: "thread.id")
            }
            outcome = .accepted
            detail = "Codex thread/resume response confirms the source thread; cursor unchanged pending read reconciliation"
        case .fork:
            guard let thread = result["thread"]?.objectValue,
                  let childID = thread["id"]?.stringValue,
                  !childID.isEmpty, childID != request.threadID.rawValue,
                  thread["forkedFromId"]?.stringValue == request.threadID.rawValue else {
                throw ExternalSessionAppServerTransportError.identityMismatch(field: "fork thread identity")
            }
            outcome = .completed
            childThreadID = ExternalSessionThreadID(rawValue: childID)
            detail = "forkedThreadID=\(childID); source thread and pre-action cursor retained"
        case .steer:
            guard result["turnId"]?.stringValue == request.turnID?.rawValue else {
                throw ExternalSessionAppServerTransportError.identityMismatch(field: "turnId")
            }
            outcome = .accepted
            detail = "Codex turn/steer accepted the expected turn; completion awaits turn notifications"
        case .interrupt:
            guard result.isEmpty else {
                throw ExternalSessionAppServerTransportError.malformedResponse(reason: "turn/interrupt expected empty result")
            }
            outcome = .accepted
            detail = "Codex acknowledged interrupt request; stopped state awaits turn/completed"
        case .approve, .reject, .provideInput:
            throw ExternalSessionAppServerTransportError.unsupportedOperation(request.operation.rawValue)
        }
        return ExternalSessionControlReceiptV1(
            sourceID: request.sourceID,
            threadID: request.threadID,
            turnID: request.turnID,
            operation: request.operation,
            outcome: outcome,
            childThreadID: childThreadID,
            sourceCursor: request.expectedCursor,
            detail: detail
        )
    }
}
