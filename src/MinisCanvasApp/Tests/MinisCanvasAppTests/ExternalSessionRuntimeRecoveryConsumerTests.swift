import Foundation
import Darwin
import Testing
import MinisCore
@testable import MinisCanvasApp

private enum ExternalRuntimeProbeError: Error, Equatable, Sendable {
    case unavailable
}

private actor SyntheticCodexEventConnection: ExternalSessionCodexJSONRPCConnection {
    private let stream: AsyncStream<ExternalSessionCodexJSONRPCMessage>
    private let continuation: AsyncStream<ExternalSessionCodexJSONRPCMessage>.Continuation
    private var subscriberAttached = false
    private let pauseBeforeSubscription: Bool
    private var subscriptionGate: CheckedContinuation<Void, Never>?
    private var responses: [(CodexJSONRPCID, CodexJSONValue)] = []

    init(pauseBeforeSubscription: Bool = false) {
        let pair = AsyncStream.makeStream(of: ExternalSessionCodexJSONRPCMessage.self)
        stream = pair.stream
        continuation = pair.continuation
        self.pauseBeforeSubscription = pauseBeforeSubscription
    }

    func request(method: String, params: [String: CodexJSONValue]) async throws -> [String: CodexJSONValue] {
        throw ExternalSessionCodexJSONRPCError.notConnected
    }

    func notifications() async -> AsyncStream<ExternalSessionCodexJSONRPCMessage> {
        if pauseBeforeSubscription {
            await withCheckedContinuation { subscriptionGate = $0 }
        }
        subscriberAttached = true
        return stream
    }

    func releaseSubscription() {
        subscriptionGate?.resume()
        subscriptionGate = nil
    }

    func respond(to requestID: CodexJSONRPCID, result: CodexJSONValue) throws {
        responses.append((requestID, result))
    }

    func send(_ message: ExternalSessionCodexJSONRPCMessage) {
        continuation.yield(message)
    }

    func finish() { continuation.finish() }
    var attached: Bool { subscriberAttached }
    var awaitingSubscription: Bool { subscriptionGate != nil }
    var responseCount: Int { responses.count }
}

private final class ExternalEventTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = Date(timeIntervalSince1970: 200)
    func now() -> Date { lock.withLock { instant } }
    func advancePastGrant() { lock.withLock { instant = Date(timeIntervalSince1970: 301) } }
}

private final class ExternalEventCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ExternalSessionEventV1] = []
    private var subscribed = false
    func markSubscribed() { lock.withLock { subscribed = true } }
    var isSubscribed: Bool { lock.withLock { subscribed } }
    func append(_ event: ExternalSessionEventV1) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }
    var events: [ExternalSessionEventV1] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private func awaitExternalCondition(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return false
}

@Suite("External Codex event delivery and approval recovery")
struct ExternalCodexEventRecoveryConsumerTests {
    @Test func notificationDeltaApprovalResolutionAndReconnectCheckpoint() async throws {
        let sourceID = ExternalSessionSourceID(rawValue: "synthetic-codex")
        let profileID = ExternalSessionProfileID(rawValue: "synthetic-profile")
        let threadID = ExternalSessionThreadID(rawValue: "synthetic-thread")
        let turnID = ExternalSessionTurnID(rawValue: "synthetic-turn")
        let source = ExternalSessionSourceV1(
            sourceID: sourceID, kind: .codex, adapterVersion: "synthetic/1",
            profileID: profileID, hostID: "isolated", capabilities: [.status, .stream, .approval],
            authState: .authorized
        )
        let root = try externalRuntimePersistenceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtimeURL = root.appendingPathComponent("runtime.json")
        let adapter = ExternalSessionAppAdapter(
            implementation: ExternalRuntimeProbe(source: source, failStatus: false),
            clock: { Date(timeIntervalSince1970: 200) }, runtimePersistenceURL: runtimeURL
        )
        let statusGrant = ExternalSessionReadGrantV1(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "status"),
            sourceID: sourceID, profileID: profileID, target: .source(sourceID),
            scopes: [.status], issuedAt: Date(timeIntervalSince1970: 100),
            expiresAt: Date(timeIntervalSince1970: 300), revocationEpoch: 0
        )
        let eventGrant = ExternalSessionReadGrantV1(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "events"),
            sourceID: sourceID, profileID: profileID, target: .thread(threadID),
            scopes: [.events], issuedAt: Date(timeIntervalSince1970: 100),
            expiresAt: Date(timeIntervalSince1970: 300), revocationEpoch: 0
        )
        let deniedControl = ExternalSessionControlGrantV1(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "denied"),
            sourceID: sourceID, profileID: profileID, target: .thread(threadID),
            operations: [], issuedAt: Date(timeIntervalSince1970: 100),
            expiresAt: Date(timeIntervalSince1970: 300), revocationEpoch: 0
        )
        let approvalGrant = ExternalSessionControlGrantV1(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "approval"),
            sourceID: sourceID, profileID: profileID, target: .thread(threadID),
            operations: [.approve], issuedAt: Date(timeIntervalSince1970: 100),
            expiresAt: Date(timeIntervalSince1970: 300), revocationEpoch: 0
        )
        let connected = try await adapter.connect(readGrant: statusGrant)
        let ownerID = try #require(connected.ownerID)
        let connection = SyntheticCodexEventConnection()
        let capture = ExternalEventCapture()
        let worker = Task {
            try await adapter.streamCodexNotifications(
                from: connection, threadID: threadID, correlationID: "synthetic-correlation",
                attemptID: "synthetic-attempt", ownerID: ownerID, readGrant: eventGrant,
                onEvent: { capture.append($0) }, onSubscribed: { capture.markSubscribed() }
            )
        }
        #expect(await awaitExternalCondition { capture.isSubscribed })
        #expect(await connection.attached)
        await connection.send(ExternalSessionCodexJSONRPCMessage(
            method: "turn/started", requestID: nil,
            params: ["threadId": .string(threadID.rawValue),
                     "turn": .object(["id": .string(turnID.rawValue)])]
        ))
        await connection.send(ExternalSessionCodexJSONRPCMessage(
            method: "item/agentMessage/delta", requestID: nil,
            params: ["threadId": .string(threadID.rawValue), "turnId": .string(turnID.rawValue),
                     "itemId": .string("assistant-1"), "delta": .string("api_key=")]
        ))
        await connection.send(ExternalSessionCodexJSONRPCMessage(
            method: "item/agentMessage/delta", requestID: nil,
            params: ["threadId": .string(threadID.rawValue), "turnId": .string(turnID.rawValue),
                     "itemId": .string("assistant-1"), "delta": .string("owned_sample_783")]
        ))
        #expect(await awaitExternalCondition { capture.events.filter { $0.payload.kind == "item/agentMessage/delta" }.count == 2 })
        #expect(!capture.events.contains(where: { $0.kind == .itemDelta }))
        await connection.send(ExternalSessionCodexJSONRPCMessage(
            method: "item/completed", requestID: nil,
            params: ["threadId": .string(threadID.rawValue), "turnId": .string(turnID.rawValue),
                     "item": .object(["id": .string("assistant-1"), "type": .string("agentMessage"),
                                      "text": .string("api_key=owned_sample_783")])]
        ))
        #expect(await awaitExternalCondition { capture.events.contains(where: { $0.kind == .itemDelta }) })
        await connection.send(ExternalSessionCodexJSONRPCMessage(
            method: "item/commandExecution/requestApproval", requestID: .integer(77),
            params: ["threadId": .string(threadID.rawValue), "turnId": .string(turnID.rawValue),
                     "itemId": .string("command-1")]
        ))
        #expect(await awaitExternalCondition { adapter.runtimeSnapshot.pendingApproval?.requestID == "i:77" })
        #expect(adapter.runtimeSnapshot.state == .waitingApproval)
        await #expect(throws: ExternalSessionAppAdapterError.operationNotGranted(.approve)) {
            try await adapter.respondToCodexApproval(on: connection, decision: .approve, controlGrant: deniedControl)
        }
        #expect(await connection.responseCount == 0)
        let wrongConnection = SyntheticCodexEventConnection()
        await #expect(throws: ExternalSessionAppAdapterError.runtimeUnavailable) {
            try await adapter.respondToCodexApproval(on: wrongConnection, decision: .approve, controlGrant: approvalGrant)
        }
        #expect(await wrongConnection.responseCount == 0)
        try await adapter.respondToCodexApproval(on: connection, decision: .approve, controlGrant: approvalGrant)
        #expect(await connection.responseCount == 1)
        #expect(adapter.runtimeSnapshot.pendingApproval?.responseAttempted == true)
        await connection.send(ExternalSessionCodexJSONRPCMessage(
            method: "serverRequest/resolved", requestID: nil,
            params: ["threadId": .string(threadID.rawValue), "requestId": .integer(77)]
        ))
        #expect(await awaitExternalCondition { adapter.runtimeSnapshot.requiresSideEffectReconciliation })
        await connection.send(ExternalSessionCodexJSONRPCMessage(
            method: "turn/completed", requestID: nil,
            params: ["threadId": .string(threadID.rawValue),
                     "turn": .object(["id": .string(turnID.rawValue), "status": .string("completed")])]
        ))
        #expect(await awaitExternalCondition { adapter.runtimeSnapshot.state == .connected && !adapter.runtimeSnapshot.requiresSideEffectReconciliation })
        await connection.finish()
        try await worker.value

        let events = capture.events
        #expect(events.contains(where: { $0.kind == .itemDelta }))
        #expect(events.contains(where: { $0.payload.kind.contains("SECRET_REDACTED") }))
        #expect(events.contains(where: { $0.kind == .approvalRequired }))
        #expect(events.contains(where: { $0.kind == .turnCompleted }))
        #expect(!events.map(\.payload.summary).joined().contains("owned_sample_783"))
        let committedBytes = try Data(contentsOf: runtimeURL)
        #expect(!String(decoding: committedBytes, as: UTF8.self).contains("owned_sample_783"))
        let checkpoint = try #require(adapter.runtimeSnapshot.eventCheckpoint)
        #expect(checkpoint.identity.attemptID == "synthetic-attempt")

        let recovered = try await adapter.reconnect(readGrant: statusGrant)
        let recoveredOwner = try #require(recovered.ownerID)
        #expect(adapter.beginExternalAttempt(
            correlationID: "synthetic-correlation", attemptID: "synthetic-attempt", ownerID: recoveredOwner
        ))
        let nextEvent = ExternalSessionEventV1(
            eventID: ExternalSessionEventID(rawValue: "after-reconnect"), sourceID: sourceID,
            threadID: threadID, turnID: turnID, sequence: checkpoint.sequence + 1,
            sourceCursor: ExternalSessionCursorV1(rawValue: "local-after-reconnect"),
            occurredAt: Date(timeIntervalSince1970: 201), required: false, kind: .progress,
            payload: ExternalSessionRedactedPayloadV1(kind: "progress", summary: "safe"),
            sourceRef: "synthetic"
        )
        #expect(try await adapter.consumeExternalEvent(
            nextEvent, correlationID: "synthetic-correlation", attemptID: "synthetic-attempt",
            ownerID: recoveredOwner, connectionGeneration: connected.generation,
            readGrant: eventGrant
        ) == .rejectedLateResult)
        #expect(try await adapter.consumeExternalEvent(
            nextEvent, correlationID: "synthetic-correlation", attemptID: "synthetic-attempt",
            ownerID: recoveredOwner, connectionGeneration: recovered.generation,
            readGrant: eventGrant
        ) == .accepted)
        #expect(try await adapter.consumeExternalEvent(
            nextEvent, correlationID: "synthetic-correlation", attemptID: "synthetic-attempt",
            ownerID: recoveredOwner, connectionGeneration: recovered.generation,
            readGrant: eventGrant
        ) == .rejectedLateResult)
        let reopened = ExternalSessionAppAdapter(
            implementation: ExternalRuntimeProbe(source: source, failStatus: false),
            clock: { Date(timeIntervalSince1970: 200) }, runtimePersistenceURL: runtimeURL
        )
        #expect(reopened.runtimeSnapshot.eventCheckpoint?.sequence == nextEvent.sequence)
        #expect(reopened.runtimeSnapshot.ownerID == nil)

        // The next attempt may reuse the server's request ID. An old
        // connection with the same public ID must never answer its approval.
        #expect(adapter.stopExternalAttempt(
            correlationID: "synthetic-correlation", attemptID: "synthetic-attempt", ownerID: recoveredOwner
        ))
        let replacement = SyntheticCodexEventConnection()
        let replacementCapture = ExternalEventCapture()
        let replacementWorker = Task {
            try await adapter.streamCodexNotifications(
                from: replacement, threadID: threadID, correlationID: "synthetic-correlation-2",
                attemptID: "synthetic-attempt-2", ownerID: recoveredOwner, readGrant: eventGrant,
                onEvent: { replacementCapture.append($0) },
                onSubscribed: { replacementCapture.markSubscribed() }
            )
        }
        #expect(await awaitExternalCondition { replacementCapture.isSubscribed })
        await replacement.send(ExternalSessionCodexJSONRPCMessage(
            method: "item/commandExecution/requestApproval", requestID: .integer(77),
            params: ["threadId": .string(threadID.rawValue), "turnId": .string(turnID.rawValue),
                     "itemId": .string("command-2")]
        ))
        #expect(await awaitExternalCondition {
            adapter.runtimeSnapshot.pendingApproval?.identity.attemptID == "synthetic-attempt-2"
        })
        await #expect(throws: ExternalSessionAppAdapterError.runtimeUnavailable) {
            try await adapter.respondToCodexApproval(on: connection, decision: .approve, controlGrant: approvalGrant)
        }
        #expect(await connection.responseCount == 1)
        #expect(await replacement.responseCount == 0)
        try await adapter.respondToCodexApproval(on: replacement, decision: .approve, controlGrant: approvalGrant)
        #expect(await replacement.responseCount == 1)
        await replacement.finish()
        try await replacementWorker.value
        #expect(adapter.runtimeSnapshot.state == .recoveryRequired)
    }

    @Test func unsolicitedApprovalResolutionStaysUnknownAcrossTerminalAndReopen() async throws {
        let sourceID = ExternalSessionSourceID(rawValue: "synthetic-codex-external-decision")
        let profileID = ExternalSessionProfileID(rawValue: "synthetic-profile")
        let threadID = ExternalSessionThreadID(rawValue: "synthetic-thread")
        let turnID = ExternalSessionTurnID(rawValue: "synthetic-turn")
        let source = ExternalSessionSourceV1(
            sourceID: sourceID, kind: .codex, adapterVersion: "synthetic/1",
            profileID: profileID, hostID: "isolated", capabilities: [.status, .stream, .approval],
            authState: .authorized
        )
        let root = try externalRuntimePersistenceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtimeURL = root.appendingPathComponent("runtime.json")
        let adapter = ExternalSessionAppAdapter(
            implementation: ExternalRuntimeProbe(source: source, failStatus: false),
            clock: { Date(timeIntervalSince1970: 200) }, runtimePersistenceURL: runtimeURL
        )
        let statusGrant = ExternalSessionReadGrantV1(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "status"),
            sourceID: sourceID, profileID: profileID, target: .source(sourceID),
            scopes: [.status], issuedAt: Date(timeIntervalSince1970: 100),
            expiresAt: Date(timeIntervalSince1970: 300), revocationEpoch: 0
        )
        let eventGrant = ExternalSessionReadGrantV1(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "events"),
            sourceID: sourceID, profileID: profileID, target: .thread(threadID),
            scopes: [.events], issuedAt: Date(timeIntervalSince1970: 100),
            expiresAt: Date(timeIntervalSince1970: 300), revocationEpoch: 0
        )
        let connected = try await adapter.connect(readGrant: statusGrant)
        let ownerID = try #require(connected.ownerID)
        let connection = SyntheticCodexEventConnection()
        let capture = ExternalEventCapture()
        let worker = Task {
            try await adapter.streamCodexNotifications(
                from: connection, threadID: threadID, correlationID: "external-decision",
                attemptID: "attempt-1", ownerID: ownerID, readGrant: eventGrant,
                onEvent: { capture.append($0) }, onSubscribed: { capture.markSubscribed() }
            )
        }
        #expect(await awaitExternalCondition { capture.isSubscribed })
        await connection.send(ExternalSessionCodexJSONRPCMessage(
            method: "item/commandExecution/requestApproval", requestID: .integer(91),
            params: ["threadId": .string(threadID.rawValue), "turnId": .string(turnID.rawValue),
                     "itemId": .string("command-1")]
        ))
        #expect(await awaitExternalCondition { adapter.runtimeSnapshot.state == .waitingApproval })
        #expect(adapter.runtimeSnapshot.pendingApproval?.responseAttempted != true)
        await connection.send(ExternalSessionCodexJSONRPCMessage(
            method: "serverRequest/resolved", requestID: nil,
            params: ["threadId": .string(threadID.rawValue), "requestId": .integer(92)]
        ))
        #expect(await awaitExternalCondition {
            capture.events.contains(where: { $0.sourceRef == "i:92" })
        })
        #expect(adapter.runtimeSnapshot.state == .waitingApproval)
        #expect(adapter.runtimeSnapshot.pendingApproval?.requestID == "i:91")
        await connection.send(ExternalSessionCodexJSONRPCMessage(
            method: "serverRequest/resolved", requestID: nil,
            params: ["threadId": .string(threadID.rawValue), "requestId": .integer(91)]
        ))
        #expect(await awaitExternalCondition { adapter.runtimeSnapshot.state == .recoveryRequired })
        #expect(await awaitExternalCondition {
            capture.events.contains(where: { $0.sourceRef == "i:91" && $0.payload.kind == "serverRequest/resolved" })
        })
        #expect(adapter.runtimeSnapshot.requiresSideEffectReconciliation)
        #expect(adapter.runtimeSnapshot.ownerID == nil)
        #expect(adapter.runtimeSnapshot.pendingApproval?.requestID == "i:91")
        #expect(await connection.responseCount == 0)
        let acceptedCount = capture.events.count
        await connection.send(ExternalSessionCodexJSONRPCMessage(
            method: "turn/completed", requestID: nil,
            params: ["threadId": .string(threadID.rawValue),
                     "turn": .object(["id": .string(turnID.rawValue), "status": .string("completed")])]
        ))
        await connection.finish()
        try await worker.value
        #expect(capture.events.count == acceptedCount)
        #expect(adapter.runtimeSnapshot.state == .recoveryRequired)
        #expect(adapter.runtimeSnapshot.requiresSideEffectReconciliation)
        let reopened = ExternalSessionAppAdapter(
            implementation: ExternalRuntimeProbe(source: source, failStatus: false),
            clock: { Date(timeIntervalSince1970: 200) }, runtimePersistenceURL: runtimeURL
        )
        #expect(reopened.runtimeSnapshot.state == .recoveryRequired)
        #expect(reopened.runtimeSnapshot.requiresSideEffectReconciliation)
        #expect(reopened.runtimeSnapshot.pendingApproval?.requestID == "i:91")
        #expect(reopened.runtimeSnapshot.pendingApproval?.responseAttempted != true)
    }

    @Test func rejectsInvalidEventGrantBeforeSubscriptionAndBoundsAllPendingItems() async throws {
        let sourceID = ExternalSessionSourceID(rawValue: "synthetic-codex-budget")
        let profileID = ExternalSessionProfileID(rawValue: "synthetic-profile-budget")
        let threadID = ExternalSessionThreadID(rawValue: "synthetic-thread-budget")
        let source = ExternalSessionSourceV1(
            sourceID: sourceID, kind: .codex, adapterVersion: "synthetic/1",
            profileID: profileID, hostID: "isolated", capabilities: [.status, .stream],
            authState: .authorized
        )
        let root = try externalRuntimePersistenceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtimeURL = root.appendingPathComponent("runtime.json")
        let adapter = ExternalSessionAppAdapter(
            implementation: ExternalRuntimeProbe(source: source, failStatus: false),
            clock: { Date(timeIntervalSince1970: 200) }, runtimePersistenceURL: runtimeURL
        )
        let statusGrant = ExternalSessionReadGrantV1(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "budget-status"),
            sourceID: sourceID, profileID: profileID, target: .source(sourceID),
            scopes: [.status], issuedAt: Date(timeIntervalSince1970: 100),
            expiresAt: Date(timeIntervalSince1970: 300), revocationEpoch: 0
        )
        let connected = try await adapter.connect(readGrant: statusGrant)
        let ownerID = try #require(connected.ownerID)
        let missingEvents = ExternalSessionReadGrantV1(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "missing-events"),
            sourceID: sourceID, profileID: profileID, target: .thread(threadID),
            scopes: [.status], issuedAt: Date(timeIntervalSince1970: 100),
            expiresAt: Date(timeIntervalSince1970: 300), revocationEpoch: 0
        )
        let expiredEvents = ExternalSessionReadGrantV1(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "expired-events"),
            sourceID: sourceID, profileID: profileID, target: .thread(threadID),
            scopes: [.events], issuedAt: Date(timeIntervalSince1970: 100),
            expiresAt: Date(timeIntervalSince1970: 200), revocationEpoch: 0
        )
        let foreignEvents = ExternalSessionReadGrantV1(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "foreign-events"),
            sourceID: ExternalSessionSourceID(rawValue: "foreign-source"), profileID: profileID,
            target: .thread(threadID), scopes: [.events],
            issuedAt: Date(timeIntervalSince1970: 100),
            expiresAt: Date(timeIntervalSince1970: 300), revocationEpoch: 0
        )
        for (grant, expected) in [
            (missingEvents, ExternalSessionAppAdapterError.scopeNotGranted),
            (expiredEvents, .grantExpired),
            (foreignEvents, .sourceMismatch)
        ] {
            let rejectedConnection = SyntheticCodexEventConnection()
            await #expect(throws: expected) {
                try await adapter.streamCodexNotifications(
                    from: rejectedConnection, threadID: threadID,
                    correlationID: "rejected-correlation", attemptID: "rejected-attempt",
                    ownerID: ownerID, readGrant: grant, onEvent: { _ in }
                )
            }
            #expect(await rejectedConnection.attached == false)
            #expect(adapter.runtimeSnapshot.state == .connected)
        }

        let eventGrant = ExternalSessionReadGrantV1(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "budget-events"),
            sourceID: sourceID, profileID: profileID, target: .thread(threadID),
            scopes: [.events], issuedAt: Date(timeIntervalSince1970: 100),
            expiresAt: Date(timeIntervalSince1970: 300), revocationEpoch: 0
        )
        let delayedClock = ExternalEventTestClock()
        let delayedAdapter = ExternalSessionAppAdapter(
            implementation: ExternalRuntimeProbe(source: source, failStatus: false),
            clock: { delayedClock.now() },
            runtimePersistenceURL: root.appendingPathComponent("delayed-runtime.json")
        )
        let delayedSnapshot = try await delayedAdapter.connect(readGrant: statusGrant)
        let delayedOwner = try #require(delayedSnapshot.ownerID)
        let delayedConnection = SyntheticCodexEventConnection(pauseBeforeSubscription: true)
        let delayedCapture = ExternalEventCapture()
        let delayedWorker = Task {
            try await delayedAdapter.streamCodexNotifications(
                from: delayedConnection, threadID: threadID,
                correlationID: "delayed-correlation", attemptID: "delayed-attempt",
                ownerID: delayedOwner, readGrant: eventGrant,
                onEvent: { delayedCapture.append($0) },
                onSubscribed: { delayedCapture.markSubscribed() }
            )
        }
        #expect(await awaitExternalCondition { await delayedConnection.awaitingSubscription })
        delayedClock.advancePastGrant()
        await delayedConnection.releaseSubscription()
        await #expect(throws: ExternalSessionAppAdapterError.grantExpired) {
            try await delayedWorker.value
        }
        #expect(await delayedConnection.attached)
        #expect(delayedCapture.isSubscribed == false)
        #expect(delayedCapture.events.isEmpty)
        #expect(delayedAdapter.runtimeSnapshot.state == .recoveryRequired)

        let connection = SyntheticCodexEventConnection()
        let capture = ExternalEventCapture()
        let worker = Task {
            try await adapter.streamCodexNotifications(
                from: connection, threadID: threadID,
                correlationID: "budget-correlation", attemptID: "budget-attempt",
                ownerID: ownerID, readGrant: eventGrant,
                onEvent: { capture.append($0) }, onSubscribed: { capture.markSubscribed() }
            )
        }
        #expect(await awaitExternalCondition { capture.isSubscribed })
        let boundedDelta = String(repeating: "budget-marker-799", count: 4_500)
        for itemID in ["first-item", "second-item"] {
            await connection.send(ExternalSessionCodexJSONRPCMessage(
                method: "item/agentMessage/delta", requestID: nil,
                params: ["threadId": .string(threadID.rawValue), "itemId": .string(itemID),
                         "delta": .string(boundedDelta)]
            ))
        }
        await connection.send(ExternalSessionCodexJSONRPCMessage(
            method: "item/commandExecution/requestApproval", requestID: .integer(79),
            params: ["threadId": .string(threadID.rawValue), "itemId": .string("command-after-overflow")]
        ))
        try await worker.value
        #expect(adapter.runtimeSnapshot.state == .recoveryRequired)
        #expect(adapter.runtimeSnapshot.requiresSideEffectReconciliation)
        #expect(adapter.runtimeSnapshot.failureMessage?.contains("预算") == true)
        #expect(adapter.runtimeSnapshot.pendingApproval == nil)
        #expect(!capture.events.contains(where: { $0.kind == .approvalRequired || $0.kind == .itemDelta }))
        #expect(!String(decoding: try Data(contentsOf: runtimeURL), as: UTF8.self).contains("budget-marker-799"))
    }
}

private struct ExternalRuntimeProbe: ExistingAgentSessionAdapter, Sendable {
    let source: ExternalSessionSourceV1
    let failStatus: Bool

    func listThreads(
        query: ExternalSessionThreadQueryV1,
        readGrant: ExternalSessionReadGrantV1
    ) async throws -> ExternalSessionThreadPageV1 {
        ExternalSessionThreadPageV1(sourceID: source.sourceID, threads: [], observedCursor: query.cursor)
    }

    func read(
        request: ExternalSessionReadRequestV1,
        readGrant: ExternalSessionReadGrantV1
    ) async throws -> ExternalSessionReadPageV1 {
        ExternalSessionReadPageV1(
            sourceID: source.sourceID,
            threadID: request.threadID,
            turns: [],
            events: [],
            observedCursor: request.cursor
        )
    }

    func status(
        target: ExternalSessionStatusTargetV1,
        readGrant: ExternalSessionReadGrantV1
    ) async throws -> ExternalSessionStatusV1 {
        if failStatus { throw ExternalRuntimeProbeError.unavailable }
        return ExternalSessionStatusV1(
            sourceID: source.sourceID,
            threadID: target.threadID,
            turnID: target.turnID,
            threadStatus: .active,
            observedCursor: .beginning,
            latestSequence: 0
        )
    }

    func control(
        request: ExternalSessionControlRequestV1,
        controlGrant: ExternalSessionControlGrantV1
    ) async throws -> ExternalSessionControlReceiptV1 {
        ExternalSessionControlReceiptV1(
            sourceID: source.sourceID,
            threadID: request.threadID,
            turnID: request.turnID,
            operation: request.operation,
            outcome: .completed,
            sourceCursor: request.expectedCursor
        )
    }
}

private actor ExternalUnknownIdentityProbe: ExistingAgentSessionAdapter {
    let source: ExternalSessionSourceV1
    private var statusCalls = 0
    private var controlCalls = 0
    private var pauseNextStatus = false
    private var pausedStatusEntered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var pauseNextControl = false
    private var pausedControlEntered = false
    private var controlEnteredWaiter: CheckedContinuation<Void, Never>?
    private var controlReleaseWaiter: CheckedContinuation<Void, Never>?

    init(source: ExternalSessionSourceV1) { self.source = source }

    func listThreads(query: ExternalSessionThreadQueryV1, readGrant: ExternalSessionReadGrantV1) async throws -> ExternalSessionThreadPageV1 {
        ExternalSessionThreadPageV1(sourceID: source.sourceID, threads: [], observedCursor: query.cursor)
    }

    func read(request: ExternalSessionReadRequestV1, readGrant: ExternalSessionReadGrantV1) async throws -> ExternalSessionReadPageV1 {
        ExternalSessionReadPageV1(sourceID: source.sourceID, threadID: request.threadID,
                                  turns: [], events: [], observedCursor: request.cursor)
    }

    func status(target: ExternalSessionStatusTargetV1, readGrant: ExternalSessionReadGrantV1) async throws -> ExternalSessionStatusV1 {
        statusCalls += 1
        if pauseNextStatus {
            pauseNextStatus = false
            pausedStatusEntered = true
            enteredWaiter?.resume()
            enteredWaiter = nil
            await withCheckedContinuation { releaseWaiter = $0 }
        }
        return ExternalSessionStatusV1(
            sourceID: source.sourceID, threadID: target.threadID, turnID: target.turnID,
            threadStatus: .active, turnStatus: target.turnID == nil ? nil : .succeeded,
            observedCursor: ExternalSessionCursorV1(rawValue: "synthetic-terminal")
        )
    }

    func control(request: ExternalSessionControlRequestV1, controlGrant: ExternalSessionControlGrantV1) async throws -> ExternalSessionControlReceiptV1 {
        controlCalls += 1
        if pauseNextControl {
            pauseNextControl = false
            pausedControlEntered = true
            controlEnteredWaiter?.resume()
            controlEnteredWaiter = nil
            await withCheckedContinuation { controlReleaseWaiter = $0 }
        }
        return ExternalSessionControlReceiptV1(
            sourceID: source.sourceID, threadID: request.threadID, turnID: request.turnID,
            operation: request.operation, outcome: .unknownRequiresRecovery,
            sourceCursor: request.expectedCursor
        )
    }

    func counts() -> (status: Int, control: Int) { (statusCalls, controlCalls) }

    func pauseNextStatusCall() { pauseNextStatus = true }

    func waitForPausedStatus() async {
        if pausedStatusEntered { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }

    func releasePausedStatus() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func pauseNextControlCall() { pauseNextControl = true }

    func waitForPausedControl() async {
        if pausedControlEntered { return }
        await withCheckedContinuation { controlEnteredWaiter = $0 }
    }

    func releasePausedControl() {
        controlReleaseWaiter?.resume()
        controlReleaseWaiter = nil
    }
}

private final class ExternalRuntimeTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(to value: Date) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}

private final class ExternalRuntimeSuspendingProbe: ExistingAgentSessionAdapter, @unchecked Sendable {
    let source: ExternalSessionSourceV1
    private let lock = NSLock()
    private var entered = false
    private var released = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    init(source: ExternalSessionSourceV1) {
        self.source = source
    }

    func waitUntilEntered() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if entered {
                lock.unlock()
                continuation.resume()
            } else {
                enteredWaiter = continuation
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        released = true
        let continuation = releaseWaiter
        releaseWaiter = nil
        lock.unlock()
        continuation?.resume()
    }

    func listThreads(
        query: ExternalSessionThreadQueryV1,
        readGrant: ExternalSessionReadGrantV1
    ) async throws -> ExternalSessionThreadPageV1 {
        await waitForRelease()
        return ExternalSessionThreadPageV1(sourceID: source.sourceID, threads: [], observedCursor: query.cursor)
    }

    func read(
        request: ExternalSessionReadRequestV1,
        readGrant: ExternalSessionReadGrantV1
    ) async throws -> ExternalSessionReadPageV1 {
        await waitForRelease()
        return ExternalSessionReadPageV1(
            sourceID: source.sourceID,
            threadID: request.threadID,
            turns: [],
            events: [],
            observedCursor: request.cursor
        )
    }

    func status(
        target: ExternalSessionStatusTargetV1,
        readGrant: ExternalSessionReadGrantV1
    ) async throws -> ExternalSessionStatusV1 {
        await waitForRelease()
        return ExternalSessionStatusV1(
            sourceID: source.sourceID,
            threadID: target.threadID,
            turnID: target.turnID,
            threadStatus: .active,
            observedCursor: .beginning,
            latestSequence: 0
        )
    }

    func control(
        request: ExternalSessionControlRequestV1,
        controlGrant: ExternalSessionControlGrantV1
    ) async throws -> ExternalSessionControlReceiptV1 {
        ExternalSessionControlReceiptV1(
            sourceID: source.sourceID,
            threadID: request.threadID,
            turnID: request.turnID,
            operation: request.operation,
            outcome: .completed,
            sourceCursor: request.expectedCursor
        )
    }

    private func waitForRelease() async {
        let (enteredContinuation, alreadyReleased) = lock.withLock {
            entered = true
            let waiter = enteredWaiter
            enteredWaiter = nil
            return (waiter, released)
        }
        enteredContinuation?.resume()
        if alreadyReleased { return }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if released {
                lock.unlock()
                continuation.resume()
            } else {
                releaseWaiter = continuation
                lock.unlock()
            }
        }
    }
}

private func externalRuntimePersistenceSource() -> ExternalSessionSourceV1 {
    ExternalSessionSourceV1(
        sourceID: ExternalSessionSourceID(rawValue: "codex-local"),
        kind: .codex,
        adapterVersion: "test",
        profileID: ExternalSessionProfileID(rawValue: "profile-a"),
        hostID: "local",
        capabilities: [.status],
        authState: .authorized
    )
}

private func externalRuntimePersistenceRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("external-runtime-persistence-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

struct ExternalSessionRuntimeRecoveryConsumerTests {
    @Test func retiredAttemptCannotAdvanceCheckpointOrOutputAfterReplacementAndReopen() async throws {
        let sourceID = ExternalSessionSourceID(rawValue: "retired-source-1754")
        let profileID = ExternalSessionProfileID(rawValue: "retired-profile-1754")
        let threadID = ExternalSessionThreadID(rawValue: "retired-thread-1754")
        let source = ExternalSessionSourceV1(
            sourceID: sourceID, kind: .codex, adapterVersion: "synthetic/1754",
            profileID: profileID, hostID: "isolated", capabilities: [.status, .stream],
            authState: .authorized
        )
        let root = try externalRuntimePersistenceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtimeURL = root.appendingPathComponent("retired-runtime.json")
        let probe = ExternalRuntimeProbe(source: source, failStatus: false)
        let adapter = ExternalSessionAppAdapter(
            implementation: probe, clock: { Date(timeIntervalSince1970: 200) },
            runtimePersistenceURL: runtimeURL
        )
        let statusGrant = ExternalSessionReadGrantV1(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "retired-status-1754"),
            sourceID: sourceID, profileID: profileID, target: .source(sourceID),
            scopes: [.status], issuedAt: Date(timeIntervalSince1970: 100),
            expiresAt: Date(timeIntervalSince1970: 300), revocationEpoch: 0
        )
        let eventGrant = ExternalSessionReadGrantV1(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "retired-events-1754"),
            sourceID: sourceID, profileID: profileID, target: .thread(threadID),
            scopes: [.events], issuedAt: Date(timeIntervalSince1970: 100),
            expiresAt: Date(timeIntervalSince1970: 300), revocationEpoch: 0
        )
        let connected = try await adapter.connect(readGrant: statusGrant)
        let owner = try #require(connected.ownerID)
        func event(_ name: String, sequence: UInt64) -> ExternalSessionEventV1 {
            ExternalSessionEventV1(
                eventID: ExternalSessionEventID(rawValue: name), sourceID: sourceID,
                threadID: threadID, sequence: sequence,
                sourceCursor: ExternalSessionCursorV1(rawValue: "cursor-\(name)"),
                occurredAt: Date(timeIntervalSince1970: 201), required: false,
                kind: .progress,
                payload: ExternalSessionRedactedPayloadV1(kind: "progress", summary: "safe"),
                sourceRef: "synthetic"
            )
        }
        func backlink(_ attempt: String?, sequence: UInt64) -> ExternalSessionOutputBacklink {
            ExternalSessionOutputBacklink(
                sourceID: sourceID, threadID: threadID,
                correlationID: attempt == nil ? nil : "correlation-1754",
                attemptID: attempt, sequence: sequence,
                sourceCursor: ExternalSessionCursorV1(rawValue: "output-\(sequence)"),
                occurredAt: Date(timeIntervalSince1970: 202),
                connectionGeneration: connected.generation, summary: "bounded output"
            )
        }

        #expect(adapter.beginExternalAttempt(
            correlationID: "correlation-1754", attemptID: "A", ownerID: owner
        ))
        #expect(try await adapter.consumeExternalEvent(
            event("A-1", sequence: 1), correlationID: "correlation-1754",
            attemptID: "A", ownerID: owner, connectionGeneration: connected.generation,
            readGrant: eventGrant
        ) == .accepted)
        // Replacing a live attempt is allowed, but retires A before B can write.
        #expect(adapter.beginExternalAttempt(
            correlationID: "correlation-1754", attemptID: "B", ownerID: owner
        ))
        #expect(try await adapter.consumeExternalEvent(
            event("B-1", sequence: 1), correlationID: "correlation-1754",
            attemptID: "B", ownerID: owner, connectionGeneration: connected.generation,
            readGrant: eventGrant
        ) == .accepted)
        let checkpointB = try #require(adapter.runtimeSnapshot.eventCheckpoint)
        #expect(checkpointB.identity.attemptID == "B")
        #expect(adapter.acceptOutput(backlink("A", sequence: 100), ownerID: owner) == .rejectedLateResult)
        #expect(adapter.acceptOutput(backlink(nil, sequence: 101), ownerID: owner) == .rejectedLateResult)
        #expect(adapter.acceptOutput(backlink("B", sequence: 2), ownerID: owner) == .accepted)
        #expect(TaskCenterExternalSessionProjection(snapshot: adapter.runtimeSnapshot)
            .snapshot.lastOutputBacklink?.attemptID == "B")
        #expect(adapter.stopExternalAttempt(
            correlationID: "correlation-1754", attemptID: "B", ownerID: owner
        ))
        #expect(!adapter.beginExternalAttempt(
            correlationID: "correlation-1754", attemptID: "A", ownerID: owner
        ))
        #expect(!adapter.beginExternalAttempt(
            correlationID: "correlation-1754", attemptID: "B", ownerID: owner
        ))
        #expect(adapter.runtimeSnapshot.eventCheckpoint == checkpointB)

        let reopened = ExternalSessionAppAdapter(
            implementation: probe, clock: { Date(timeIntervalSince1970: 200) },
            runtimePersistenceURL: runtimeURL
        )
        let recovered = try await reopened.reconnect(readGrant: statusGrant)
        let recoveredOwner = try #require(recovered.ownerID)
        #expect(!reopened.beginExternalAttempt(
            correlationID: "correlation-1754", attemptID: "A", ownerID: recoveredOwner
        ))
        #expect(!reopened.beginExternalAttempt(
            correlationID: "correlation-1754", attemptID: "B", ownerID: recoveredOwner
        ))
        #expect(reopened.runtimeSnapshot.eventCheckpoint == checkpointB)
        #expect(reopened.beginExternalAttempt(
            correlationID: "correlation-1754", attemptID: "C", ownerID: recoveredOwner
        ))
        #expect(try await reopened.consumeExternalEvent(
            event("C-1", sequence: 1), correlationID: "correlation-1754",
            attemptID: "C", ownerID: recoveredOwner, connectionGeneration: recovered.generation,
            readGrant: eventGrant
        ) == .accepted)
        #expect(reopened.runtimeSnapshot.eventCheckpoint?.identity.attemptID == "C")
        #expect(!reopened.runtimeSnapshot.requiresSideEffectReconciliation)
    }

    @Test func activeCheckpointReopenCannotClaimSameAttemptReplayAfterUncleanExit() async throws {
        let sourceID = ExternalSessionSourceID(rawValue: "exth-active-source")
        let profileID = ExternalSessionProfileID(rawValue: "exth-active-profile")
        let threadID = ExternalSessionThreadID(rawValue: "exth-active-thread")
        let source = ExternalSessionSourceV1(
            sourceID: sourceID, kind: .codex, adapterVersion: "synthetic/exth",
            profileID: profileID, hostID: "isolated", capabilities: [.status, .stream],
            authState: .authorized
        )
        let root = try externalRuntimePersistenceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtimeURL = root.appendingPathComponent("active-runtime.json")
        let probe = ExternalRuntimeProbe(source: source, failStatus: false)
        let statusGrant = ExternalSessionReadGrantV1(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "exth-status"),
            sourceID: sourceID, profileID: profileID, target: .source(sourceID),
            scopes: [.status], issuedAt: Date(timeIntervalSince1970: 100),
            expiresAt: Date(timeIntervalSince1970: 300), revocationEpoch: 0
        )
        let eventGrant = ExternalSessionReadGrantV1(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "exth-events"),
            sourceID: sourceID, profileID: profileID, target: .thread(threadID),
            scopes: [.events], issuedAt: Date(timeIntervalSince1970: 100),
            expiresAt: Date(timeIntervalSince1970: 300), revocationEpoch: 0
        )
        let home = root.appendingPathComponent("synthetic-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let server = root.appendingPathComponent("synthetic-app-server.py")
        try Data(#"""
        #!/usr/bin/python3
        import json, sys
        for line in sys.stdin:
            request = json.loads(line)
            method = request.get('method')
            if method == 'initialize':
                print(json.dumps({'id':request['id'],'result':{'userAgent':'miniscanvas/0.151.0 (synthetic)','platformFamily':'unix','platformOs':'macos'}}), flush=True)
            elif method == 'initialized':
                print(json.dumps({'method':'turn/started','params':{'threadId':'exth-active-thread','turn':{'id':'turn-a'}}}), flush=True)
        """#.utf8).write(to: server)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: server.path)
        let connection = try ExternalSessionCodexStdioConnection(
            executableURL: server, environment: ["CODEX_HOME": home.path], workingDirectory: home
        )
        let adapter = ExternalSessionAppAdapter(
            implementation: probe, clock: { Date(timeIntervalSince1970: 200) },
            runtimePersistenceURL: runtimeURL
        )
        let connected = try await adapter.connect(readGrant: statusGrant)
        let owner = try #require(connected.ownerID)
        try await connection.connect()
        let worker = Task {
            try await adapter.streamCodexNotifications(
                from: connection, threadID: threadID,
                correlationID: "exth-correlation", attemptID: "A", ownerID: owner,
                readGrant: eventGrant, onEvent: { _ in }
            )
        }
        do {
            #expect(await awaitExternalCondition { adapter.runtimeSnapshot.eventCheckpoint != nil })
            let checkpoint = try #require(adapter.runtimeSnapshot.eventCheckpoint)
            #expect(checkpoint.identity.attemptID == "A")

            // Reconstruct from the actual runtime file while the synthetic
            // owned process and stream remain live. No graceful disconnect ran.
            let reopened = ExternalSessionAppAdapter(
                implementation: probe, clock: { Date(timeIntervalSince1970: 200) },
                runtimePersistenceURL: runtimeURL
            )
            #expect(reopened.runtimeSnapshot.state == .recoveryRequired)
            #expect(reopened.runtimeSnapshot.requiresSideEffectReconciliation)
            let handshake = try await reopened.reconnect(readGrant: statusGrant)
            let newOwner = try #require(handshake.ownerID)
            #expect(handshake.state == .recoveryRequired)
            #expect(handshake.requiresSideEffectReconciliation)
            #expect(!reopened.beginExternalAttempt(
                correlationID: "exth-correlation", attemptID: "A", ownerID: newOwner
            ))
            #expect(try await reopened.consumeExternalEvent(
                ExternalSessionEventV1(
                    eventID: ExternalSessionEventID(rawValue: "A-late"), sourceID: sourceID,
                    threadID: threadID, sequence: checkpoint.sequence + 1,
                    sourceCursor: ExternalSessionCursorV1(rawValue: "local-notification:2:2"),
                    occurredAt: Date(timeIntervalSince1970: 202), required: false,
                    kind: .progress,
                    payload: ExternalSessionRedactedPayloadV1(kind: "progress", summary: "late"),
                    sourceRef: "synthetic"
                ), correlationID: "exth-correlation", attemptID: "A",
                ownerID: newOwner, connectionGeneration: handshake.generation,
                readGrant: eventGrant
            ) == .rejectedDisconnected)
            #expect(reopened.runtimeSnapshot.eventCheckpoint == checkpoint)
            await connection.close()
            try await worker.value
        } catch {
            await connection.close()
            _ = try? await worker.value
            throw error
        }
    }

    @Test func unknownControlReconcileRejectsForeignTerminalAndKeepsForkUnknown() async throws {
        let sourceID = ExternalSessionSourceID(rawValue: "unknown-815")
        let profileID = ExternalSessionProfileID(rawValue: "profile-815")
        let threadID = ExternalSessionThreadID(rawValue: "thread-815")
        let turnID = ExternalSessionTurnID(rawValue: "turn-815")
        let source = ExternalSessionSourceV1(
            sourceID: sourceID, kind: .codex, adapterVersion: "synthetic/815",
            profileID: profileID, hostID: "isolated", capabilities: [.status, .fork],
            authState: .authorized
        )
        let root = try externalRuntimePersistenceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistenceURL = root.appendingPathComponent("unknown-runtime.json")
        let probe = ExternalUnknownIdentityProbe(source: source)
        let statusGrant = ExternalSessionReadGrantV1(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "status-815"),
            sourceID: sourceID, profileID: profileID, target: .source(sourceID),
            scopes: [.status], issuedAt: Date(timeIntervalSince1970: 100),
            expiresAt: Date(timeIntervalSince1970: 300), revocationEpoch: 4
        )
        let controlGrant = ExternalSessionControlGrantV1(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "fork-815"),
            sourceID: sourceID, profileID: profileID, target: .thread(threadID),
            operations: [.fork], issuedAt: Date(timeIntervalSince1970: 100),
            expiresAt: Date(timeIntervalSince1970: 300), revocationEpoch: 4
        )
        let adapter = ExternalSessionAppAdapter(
            implementation: probe, clock: { Date(timeIntervalSince1970: 200) },
            runtimePersistenceURL: persistenceURL
        )
        let originalConnection = try await adapter.connect(readGrant: statusGrant)
        let request = ExternalSessionControlRequestV1(
            sourceID: sourceID, threadID: threadID, turnID: turnID,
            operation: .fork, expectedCursor: .beginning, idempotencyKey: "fork-815"
        )
        let receipt = try await adapter.control(request: request, controlGrant: controlGrant)
        #expect(receipt.outcome == .unknownRequiresRecovery)
        #expect(adapter.runtimeSnapshot.requiresSideEffectReconciliation)
        #expect(await probe.counts().control == 1)
        let originalUnknown = try #require(adapter.runtimeSnapshot.unconfirmedControl)
        #expect(originalUnknown.sourceID == sourceID)
        #expect(originalUnknown.profileID == profileID)
        #expect(originalUnknown.threadID == threadID)
        #expect(originalUnknown.turnID == turnID)
        #expect(originalUnknown.operation == .fork)
        #expect(originalUnknown.controlRevocationEpoch == 4)
        #expect(originalUnknown.connectionGeneration == originalConnection.generation)
        #expect(originalUnknown.connectionOwnerID == originalConnection.ownerID)

        let reopened = ExternalSessionAppAdapter(
            implementation: probe, clock: { Date(timeIntervalSince1970: 200) },
            runtimePersistenceURL: persistenceURL
        )
        _ = try await reopened.reconnect(readGrant: statusGrant)
        #expect(reopened.runtimeSnapshot.unconfirmedControl == originalUnknown)
        let before = await probe.counts().status
        let staleEpochGrant = ExternalSessionReadGrantV1(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "stale-status-815"),
            sourceID: sourceID, profileID: profileID, target: .source(sourceID),
            scopes: [.status], issuedAt: Date(timeIntervalSince1970: 100),
            expiresAt: Date(timeIntervalSince1970: 300), revocationEpoch: 3
        )
        await #expect(throws: ExternalSessionAppAdapterError.grantRevoked) {
            _ = try await reopened.reconcileExternalSideEffect(
                threadID: threadID, turnID: turnID, readGrant: staleEpochGrant
            )
        }
        await #expect(throws: ExternalSessionAppAdapterError.targetMismatch) {
            _ = try await reopened.reconcileExternalSideEffect(
                threadID: ExternalSessionThreadID(rawValue: "foreign-thread"),
                turnID: turnID, readGrant: statusGrant
            )
        }
        await #expect(throws: ExternalSessionAppAdapterError.targetMismatch) {
            _ = try await reopened.reconcileExternalSideEffect(
                threadID: threadID, turnID: ExternalSessionTurnID(rawValue: "foreign-turn"),
                readGrant: statusGrant
            )
        }
        #expect(await probe.counts().status == before)
        #expect(reopened.runtimeSnapshot.requiresSideEffectReconciliation)
        await probe.pauseNextStatusCall()
        let staleObservation = Task {
            try await reopened.reconcileExternalSideEffect(
                threadID: threadID, turnID: turnID, readGrant: statusGrant
            )
        }
        await probe.waitForPausedStatus()
        let newConnection = try await reopened.reconnect(readGrant: statusGrant)
        #expect(newConnection.generation > originalConnection.generation)
        await probe.releasePausedStatus()
        await #expect(throws: ExternalSessionAppAdapterError.runtimeUnavailable) {
            _ = try await staleObservation.value
        }
        #expect(reopened.runtimeSnapshot.unconfirmedControl?.observedTurnStatus == nil)
        #expect(reopened.runtimeSnapshot.requiresSideEffectReconciliation)
        let observed = try await reopened.reconcileExternalSideEffect(
            threadID: threadID, turnID: turnID, readGrant: statusGrant
        )
        #expect(observed.turnStatus == .succeeded)
        #expect(reopened.runtimeSnapshot.requiresSideEffectReconciliation,
                "A generic source-turn terminal cannot prove that fork ran")
        #expect(reopened.runtimeSnapshot.unconfirmedControl?.observedTurnStatus == .succeeded)
        await #expect(throws: ExternalSessionAppAdapterError.sideEffectReconciliationRequired) {
            _ = try await reopened.control(request: request, controlGrant: controlGrant)
        }
        #expect(await probe.counts().control == 1)

        // Backward-compatible old runtime data may carry only the bool. It
        // has no trustworthy request target and must never auto-clear.
        let legacyURL = root.appendingPathComponent("legacy-unknown-runtime.json")
        let encoded = try Data(contentsOf: persistenceURL)
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "unconfirmedControl")
        try JSONSerialization.data(withJSONObject: legacy).write(to: legacyURL)
        let oldRecord = ExternalSessionAppAdapter(
            implementation: probe, clock: { Date(timeIntervalSince1970: 200) },
            runtimePersistenceURL: legacyURL
        )
        _ = try await oldRecord.reconnect(readGrant: statusGrant)
        let beforeLegacy = await probe.counts().status
        await #expect(throws: ExternalSessionAppAdapterError.sideEffectReconciliationRequired) {
            _ = try await oldRecord.reconcileExternalSideEffect(
                threadID: threadID, turnID: turnID, readGrant: statusGrant
            )
        }
        #expect(await probe.counts().status == beforeLegacy)
        #expect(oldRecord.runtimeSnapshot.requiresSideEffectReconciliation)

        // A late UNKNOWN response from the old transport must not revoke the
        // newly connected owner, nor allow a second control to run.
        let lateURL = root.appendingPathComponent("late-control-runtime.json")
        let lateAdapter = ExternalSessionAppAdapter(
            implementation: probe, clock: { Date(timeIntervalSince1970: 200) },
            runtimePersistenceURL: lateURL
        )
        _ = try await lateAdapter.connect(readGrant: statusGrant)
        await probe.pauseNextControlCall()
        let lateControl = Task {
            try await lateAdapter.control(request: request, controlGrant: controlGrant)
        }
        await probe.waitForPausedControl()
        let replacement = try await lateAdapter.reconnect(readGrant: statusGrant)
        #expect(lateAdapter.runtimeSnapshot.requiresSideEffectReconciliation)
        #expect(lateAdapter.runtimeSnapshot.state == .recoveryRequired)
        await probe.releasePausedControl()
        let lateReceipt = try await lateControl.value
        #expect(lateReceipt.outcome == .unknownRequiresRecovery)
        #expect(lateAdapter.runtimeSnapshot.ownerID == replacement.ownerID)
        #expect(lateAdapter.runtimeSnapshot.generation == replacement.generation)
        #expect(lateAdapter.runtimeSnapshot.unconfirmedControl?.connectionOwnerID != replacement.ownerID)
        #expect(lateAdapter.runtimeSnapshot.requiresSideEffectReconciliation)
    }

    @Test func readResultRemainsValidWhenGrantStaysValidAcrossAwait() async throws {
        let sourceID = ExternalSessionSourceID(rawValue: "codex-local")
        let profileID = ExternalSessionProfileID(rawValue: "profile-a")
        let threadID = ExternalSessionThreadID(rawValue: "thread-a")
        let source = ExternalSessionSourceV1(
            sourceID: sourceID,
            kind: .codex,
            adapterVersion: "test",
            profileID: profileID,
            hostID: "local",
            capabilities: [.readMessages],
            authState: .authorized
        )
        let clock = ExternalRuntimeTestClock(Date(timeIntervalSince1970: 200))
        let probe = ExternalRuntimeSuspendingProbe(source: source)
        let adapter = ExternalSessionAppAdapter(implementation: probe, clock: { clock.now })
        let grant = ExternalSessionReadGrantV1(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "read-1"),
            sourceID: sourceID,
            profileID: profileID,
            target: .thread(threadID),
            scopes: [.messages],
            issuedAt: Date(timeIntervalSince1970: 100),
            expiresAt: Date(timeIntervalSince1970: 500),
            revocationEpoch: 0
        )

        let pending = Task {
            try await adapter.read(
                request: ExternalSessionReadRequestV1(sourceID: sourceID, threadID: threadID, limit: 10),
                readGrant: grant
            )
        }
        await probe.waitUntilEntered()
        probe.release()

        let page = try await pending.value
        #expect(page.sourceID == sourceID)
        #expect(page.threadID == threadID)
    }

    @Test func readResultIsRejectedWhenGrantExpiresDuringAwait() async throws {
        let sourceID = ExternalSessionSourceID(rawValue: "codex-local")
        let profileID = ExternalSessionProfileID(rawValue: "profile-a")
        let threadID = ExternalSessionThreadID(rawValue: "thread-a")
        let source = ExternalSessionSourceV1(
            sourceID: sourceID,
            kind: .codex,
            adapterVersion: "test",
            profileID: profileID,
            hostID: "local",
            capabilities: [.readMessages],
            authState: .authorized
        )
        let clock = ExternalRuntimeTestClock(Date(timeIntervalSince1970: 200))
        let probe = ExternalRuntimeSuspendingProbe(source: source)
        let adapter = ExternalSessionAppAdapter(implementation: probe, clock: { clock.now })
        let grant = ExternalSessionReadGrantV1(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "read-expiring"),
            sourceID: sourceID,
            profileID: profileID,
            target: .thread(threadID),
            scopes: [.messages],
            issuedAt: Date(timeIntervalSince1970: 100),
            expiresAt: Date(timeIntervalSince1970: 300),
            revocationEpoch: 0
        )

        let pending = Task {
            try await adapter.read(
                request: ExternalSessionReadRequestV1(sourceID: sourceID, threadID: threadID, limit: 10),
                readGrant: grant
            )
        }
        await probe.waitUntilEntered()
        clock.advance(to: Date(timeIntervalSince1970: 301))
        probe.release()

        await #expect(throws: ExternalSessionAppAdapterError.grantExpired) {
            _ = try await pending.value
        }
    }

    @Test func readResultIsRejectedWhenTaskIsCancelledDuringAwait() async throws {
        let sourceID = ExternalSessionSourceID(rawValue: "codex-local")
        let profileID = ExternalSessionProfileID(rawValue: "profile-a")
        let threadID = ExternalSessionThreadID(rawValue: "thread-a")
        let source = ExternalSessionSourceV1(
            sourceID: sourceID,
            kind: .codex,
            adapterVersion: "test",
            profileID: profileID,
            hostID: "local",
            capabilities: [.readMessages],
            authState: .authorized
        )
        let probe = ExternalRuntimeSuspendingProbe(source: source)
        let adapter = ExternalSessionAppAdapter(
            implementation: probe,
            clock: { Date(timeIntervalSince1970: 200) }
        )
        let grant = ExternalSessionReadGrantV1(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "read-cancelled"),
            sourceID: sourceID,
            profileID: profileID,
            target: .thread(threadID),
            scopes: [.messages],
            issuedAt: Date(timeIntervalSince1970: 100),
            expiresAt: Date(timeIntervalSince1970: 500),
            revocationEpoch: 0
        )

        let pending = Task {
            try await adapter.read(
                request: ExternalSessionReadRequestV1(sourceID: sourceID, threadID: threadID, limit: 10),
                readGrant: grant
            )
        }
        await probe.waitUntilEntered()
        pending.cancel()
        probe.release()

        await #expect(throws: CancellationError.self) {
            _ = try await pending.value
        }
    }

    @Test func boundedRecoveryRejectsOversizedSymlinkAndNonRegularInputs() throws {
        let source = externalRuntimePersistenceSource()
        let root = try externalRuntimePersistenceRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let oversizedURL = root.appendingPathComponent("oversized.json")
        try Data(repeating: 0x7f, count: 64 * 1024 + 1).write(to: oversizedURL)
        let oversized = ExternalSessionAppAdapter(
            implementation: ExternalRuntimeProbe(source: source, failStatus: false),
            runtimePersistenceURL: oversizedURL
        )
        #expect(oversized.runtimeSnapshot.state == .recoveryRequired)
        #expect(oversized.runtimeSnapshot.ownerID == nil)
        #expect(try Data(contentsOf: oversizedURL).count == 64 * 1024 + 1)

        let targetURL = root.appendingPathComponent("replacement-target.json")
        try Data("target".utf8).write(to: targetURL)
        let symlinkURL = root.appendingPathComponent("replaced.json")
        try Data("original".utf8).write(to: symlinkURL)
        try FileManager.default.removeItem(at: symlinkURL)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: targetURL)
        let symlink = ExternalSessionAppAdapter(
            implementation: ExternalRuntimeProbe(source: source, failStatus: false),
            runtimePersistenceURL: symlinkURL
        )
        #expect(symlink.runtimeSnapshot.state == .recoveryRequired)
        #expect(symlink.runtimeSnapshot.ownerID == nil)

        let directoryURL = root.appendingPathComponent("directory.json", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)
        let directory = ExternalSessionAppAdapter(
            implementation: ExternalRuntimeProbe(source: source, failStatus: false),
            runtimePersistenceURL: directoryURL
        )
        #expect(directory.runtimeSnapshot.state == .recoveryRequired)
        #expect(directory.runtimeSnapshot.ownerID == nil)
    }

    @Test func boundedRecoveryRejectsFIFOAndHardLinkBeforeOpening() throws {
        let source = externalRuntimePersistenceSource()
        let root = try externalRuntimePersistenceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = root.appendingPathComponent("fifo.json")
        #expect(Darwin.mkfifo(fifo.path, 0o600) == 0)
        let target = root.appendingPathComponent("target.json")
        let bytes = Data("retained-input".utf8)
        try bytes.write(to: target)
        let hardLink = root.appendingPathComponent("hard-link.json")
        try FileManager.default.linkItem(at: target, to: hardLink)
        for url in [fifo, hardLink] {
            let adapter = ExternalSessionAppAdapter(
                implementation: ExternalRuntimeProbe(source: source, failStatus: false),
                runtimePersistenceURL: url
            )
            #expect(adapter.runtimeSnapshot.state == .recoveryRequired)
            #expect(adapter.runtimeSnapshot.ownerID == nil)
        }
        #expect(try Data(contentsOf: target) == bytes)
    }

    @Test func corruptRecoveryRecordIsRejectedWithoutReplacingInput() throws {
        let source = externalRuntimePersistenceSource()
        let root = try externalRuntimePersistenceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistenceURL = root.appendingPathComponent("corrupt.json")
        let original = Data([0xde, 0xad, 0xbe, 0xef])
        try original.write(to: persistenceURL)

        let adapter = ExternalSessionAppAdapter(
            implementation: ExternalRuntimeProbe(source: source, failStatus: false),
            runtimePersistenceURL: persistenceURL
        )

        #expect(adapter.runtimeSnapshot.state == .recoveryRequired)
        #expect(adapter.runtimeSnapshot.ownerID == nil)
        #expect(try Data(contentsOf: persistenceURL) == original)
    }

    @Test func actualWriterRejectsOverBudgetRecordAndReopenReadsLastCommittedBytes() async throws {
        let source = externalRuntimePersistenceSource()
        let threadID = ExternalSessionThreadID(rawValue: "thread-writer-budget")
        let root = try externalRuntimePersistenceRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistenceURL = root.appendingPathComponent("runtime.json")
        let adapter = ExternalSessionAppAdapter(
            implementation: ExternalRuntimeProbe(source: source, failStatus: false),
            clock: { Date(timeIntervalSince1970: 200) },
            runtimePersistenceURL: persistenceURL
        )
        let statusGrant = ExternalSessionReadGrantV1(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "budget-status-525"),
            sourceID: source.sourceID, profileID: source.profileID,
            target: .source(source.sourceID), scopes: [.status],
            issuedAt: Date(timeIntervalSince1970: 100),
            expiresAt: Date(timeIntervalSince1970: 300), revocationEpoch: 0
        )
        let connected = try await adapter.connect(readGrant: statusGrant)
        let owner = try #require(connected.ownerID)
        let generation = connected.generation
        var committedBytes: Data?
        var rejectedAt: Int?

        for index in 0..<4_096 {
            let identity = ExternalAgentInvocationIdentity(
                correlationID: "budget-correlation-\(index)",
                attemptID: "budget-attempt-\(index)"
            )
            let event = ExternalAgentTerminalEventV1(
                identity: identity,
                eventID: "budget-event-\(index)",
                sourceID: source.sourceID,
                threadID: threadID,
                sequence: UInt64(index + 1),
                sourceCursor: .beginning,
                occurredAt: Date(timeIntervalSince1970: Double(index + 1)),
                connectionGeneration: generation,
                outcome: .succeeded,
                summary: String(repeating: "committed", count: 64)
            )
            if !adapter.beginExternalAttempt(
                correlationID: identity.correlationID,
                attemptID: identity.attemptID,
                ownerID: owner
            ) {
                // The 64 KiB budget may reject the attempt identity before
                // terminal delivery. That fail-closed transition disconnects
                // this owner; a later terminal must remain disconnected, not
                // be relabeled as the persistence error from another stage.
                #expect(adapter.runtimeSnapshot.state == .recoveryRequired)
                #expect(adapter.runtimeSnapshot.failureMessage?.contains("持久化") == true)
                committedBytes = try Data(contentsOf: persistenceURL)
                #expect(adapter.consumeTerminalEvent(event, ownerID: owner) == .rejectedDisconnected)
                rejectedAt = index
                break
            }
            let acceptance = adapter.consumeTerminalEvent(event, ownerID: owner)
            if acceptance == .accepted {
                committedBytes = try Data(contentsOf: persistenceURL)
            } else {
                #expect(acceptance == .rejectedPersistenceFailure)
                rejectedAt = index
                break
            }
        }

        let bytesAfterRejectedWrite = try Data(contentsOf: persistenceURL)
        #expect(rejectedAt != nil)
        #expect(bytesAfterRejectedWrite.count <= 64 * 1024)
        #expect(committedBytes == bytesAfterRejectedWrite)

        let reopened = ExternalSessionAppAdapter(
            implementation: ExternalRuntimeProbe(source: source, failStatus: false),
            runtimePersistenceURL: persistenceURL
        )
        #expect(reopened.runtimeSnapshot.state == .recoveryRequired)
        #expect(reopened.runtimeSnapshot.ownerID == nil)
        #expect(reopened.runtimeSnapshot.failureMessage == "外部会话已重新打开，请先恢复连接")
        #expect(try Data(contentsOf: persistenceURL) == bytesAfterRejectedWrite)
    }

    @Test func reconnectRotatesOwnerAndRejectsLateOrDuplicateOutput() async throws {
        let sourceID = ExternalSessionSourceID(rawValue: "codex-local")
        let profileID = ExternalSessionProfileID(rawValue: "profile-a")
        let threadID = ExternalSessionThreadID(rawValue: "thread-a")
        let source = ExternalSessionSourceV1(
            sourceID: sourceID,
            kind: .codex,
            adapterVersion: "test",
            profileID: profileID,
            hostID: "local",
            capabilities: [.status],
            authState: .authorized
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("external-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let grant = ExternalSessionReadGrantV1(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "status-1"),
            sourceID: sourceID,
            profileID: profileID,
            target: .source(sourceID),
            scopes: [.status],
            issuedAt: Date(timeIntervalSince1970: 100),
            expiresAt: Date(timeIntervalSince1970: 500),
            revocationEpoch: 0
        )
        let adapter = ExternalSessionAppAdapter(
            implementation: ExternalRuntimeProbe(source: source, failStatus: false),
            clock: { Date(timeIntervalSince1970: 200) },
            runtimePersistenceURL: root.appendingPathComponent("runtime.json")
        )

        let before = adapter.runtimeSnapshot
        let connected = try await adapter.connect(readGrant: grant)
        #expect(connected.state == .connected)
        #expect(connected.generation > before.generation)
        #expect(connected.ownerID != before.ownerID)

        let oldBacklink = ExternalSessionOutputBacklink(
            sourceID: sourceID,
            threadID: threadID,
            sequence: 1,
            sourceCursor: .beginning,
            occurredAt: Date(timeIntervalSince1970: 201),
            connectionGeneration: before.generation,
            summary: "late"
        )
        #expect(adapter.acceptOutput(oldBacklink, ownerID: before.ownerID ?? "retired") == .rejectedLateResult)

        let currentOwner = try #require(connected.ownerID)
        let currentBacklink = ExternalSessionOutputBacklink(
            sourceID: sourceID,
            threadID: threadID,
            sequence: 1,
            sourceCursor: .beginning,
            occurredAt: Date(timeIntervalSince1970: 202),
            connectionGeneration: connected.generation,
            summary: String(repeating: "x", count: 2_000)
        )
        #expect(adapter.acceptOutput(currentBacklink, ownerID: currentOwner) == .accepted)
        #expect(adapter.acceptOutput(currentBacklink, ownerID: currentOwner) == .rejectedLateResult)
        #expect(adapter.runtimeSnapshot.lastOutputBacklink?.summary.count == ExternalSessionOutputBacklink.maximumSummaryCharacters)

        let reopened = ExternalSessionAppAdapter(
            implementation: ExternalRuntimeProbe(source: source, failStatus: false),
            clock: { Date(timeIntervalSince1970: 200) },
            runtimePersistenceURL: root.appendingPathComponent("runtime.json")
        )
        #expect(reopened.runtimeSnapshot.state == .recoveryRequired)
        #expect(reopened.runtimeSnapshot.ownerID == nil)
        #expect(reopened.acceptOutput(currentBacklink, ownerID: currentOwner) == .rejectedDisconnected)
    }

    @Test func failedReconnectAndTaskCenterProjectionExposeRecoveryAction() async throws {
        let sourceID = ExternalSessionSourceID(rawValue: "codex-local")
        let profileID = ExternalSessionProfileID(rawValue: "profile-a")
        let source = ExternalSessionSourceV1(
            sourceID: sourceID,
            kind: .codex,
            adapterVersion: "test",
            profileID: profileID,
            hostID: "local",
            capabilities: [.status],
            authState: .authorized
        )
        let grant = ExternalSessionReadGrantV1(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "status-2"),
            sourceID: sourceID,
            profileID: profileID,
            target: .source(sourceID),
            scopes: [.status],
            issuedAt: Date(timeIntervalSince1970: 100),
            expiresAt: Date(timeIntervalSince1970: 500),
            revocationEpoch: 0
        )
        let adapter = ExternalSessionAppAdapter(
            implementation: ExternalRuntimeProbe(source: source, failStatus: true),
            clock: { Date(timeIntervalSince1970: 200) }
        )

        await #expect(throws: ExternalRuntimeProbeError.unavailable) {
            _ = try await adapter.reconnect(readGrant: grant)
        }
        let snapshot = adapter.runtimeSnapshot
        #expect(snapshot.state == .failed)
        #expect(snapshot.recoveryActions.contains(.retry))
        #expect(snapshot.userMessage.contains("恢复失败"))

        let consumer = TaskCenterControlConsumer(store: AgentTaskStore())
        adapter.markOrphaned()
        consumer.bindExternalSessionRuntime(from: adapter)
        let projection = try #require(consumer.externalSessionRuntime)
        #expect(projection.accessibilityLabel.contains("恢复动作"))
        #expect(projection.snapshot.recoveryActions.contains(.reconnect))
    }
}
