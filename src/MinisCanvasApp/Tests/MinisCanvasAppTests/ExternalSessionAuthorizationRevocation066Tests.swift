import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private final class RevocationSpyProbe: ExistingAgentSessionAdapter, @unchecked Sendable {
    let source: ExternalSessionSourceV1
    private let lock = NSLock()
    private var recordedCalls: [String] = []

    init(source: ExternalSessionSourceV1) {
        self.source = source
    }

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCalls
    }

    func record(_ call: String) {
        lock.lock()
        recordedCalls.append(call)
        lock.unlock()
    }

    func listThreads(
        query: ExternalSessionThreadQueryV1,
        readGrant: ExternalSessionReadGrantV1
    ) async throws -> ExternalSessionThreadPageV1 {
        record("list:\(query.sourceID.rawValue)")
        return ExternalSessionThreadPageV1(
            sourceID: source.sourceID,
            threads: [],
            observedCursor: query.cursor
        )
    }

    func read(
        request: ExternalSessionReadRequestV1,
        readGrant: ExternalSessionReadGrantV1
    ) async throws -> ExternalSessionReadPageV1 {
        record("read:\(request.threadID.rawValue)")
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
        record("status:\(target.threadID?.rawValue ?? "source")")
        return ExternalSessionStatusV1(
            sourceID: source.sourceID,
            threadID: target.threadID,
            turnID: target.turnID,
            threadStatus: .active,
            observedCursor: .beginning
        )
    }

    func control(
        request: ExternalSessionControlRequestV1,
        controlGrant: ExternalSessionControlGrantV1
    ) async throws -> ExternalSessionControlReceiptV1 {
        record("control:\(request.operation.rawValue)")
        return ExternalSessionControlReceiptV1(
            sourceID: source.sourceID,
            threadID: request.threadID,
            turnID: request.turnID,
            operation: request.operation,
            outcome: .accepted,
            sourceCursor: request.expectedCursor
        )
    }
}

private final class RevocationSuspendingProbe: ExistingAgentSessionAdapter, @unchecked Sendable {
    let source: ExternalSessionSourceV1
    private let lock = NSLock()
    private var readEnteredCount = 0
    private var controlEnteredCount = 0
    private var readReleased = false
    private var controlReleased = false
    private var readEnteredWaiter: CheckedContinuation<Void, Never>?
    private var readReleaseWaiter: CheckedContinuation<Void, Never>?
    private var controlEnteredWaiter: CheckedContinuation<Void, Never>?
    private var controlReleaseWaiter: CheckedContinuation<Void, Never>?

    init(source: ExternalSessionSourceV1) {
        self.source = source
    }

    var readEntered: Int {
        lock.lock()
        defer { lock.unlock() }
        return readEnteredCount
    }

    var controlEntered: Int {
        lock.lock()
        defer { lock.unlock() }
        return controlEnteredCount
    }

    func waitUntilReadEntered() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if readEnteredCount > 0 {
                lock.unlock()
                continuation.resume()
            } else {
                readEnteredWaiter = continuation
                lock.unlock()
            }
        }
    }

    func releaseRead() {
        lock.lock()
        readReleased = true
        let waiter = readReleaseWaiter
        readReleaseWaiter = nil
        lock.unlock()
        waiter?.resume()
    }

    func waitUntilControlEntered() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if controlEnteredCount > 0 {
                lock.unlock()
                continuation.resume()
            } else {
                controlEnteredWaiter = continuation
                lock.unlock()
            }
        }
    }

    func releaseControl() {
        lock.lock()
        controlReleased = true
        let waiter = controlReleaseWaiter
        controlReleaseWaiter = nil
        lock.unlock()
        waiter?.resume()
    }

    func listThreads(
        query: ExternalSessionThreadQueryV1,
        readGrant: ExternalSessionReadGrantV1
    ) async throws -> ExternalSessionThreadPageV1 {
        ExternalSessionThreadPageV1(
            sourceID: source.sourceID,
            threads: [],
            observedCursor: query.cursor
        )
    }

    func read(
        request: ExternalSessionReadRequestV1,
        readGrant: ExternalSessionReadGrantV1
    ) async throws -> ExternalSessionReadPageV1 {
        await gate(
            enter: {
                self.lock.lock()
                self.readEnteredCount += 1
                let waiter = self.readEnteredWaiter
                self.readEnteredWaiter = nil
                let alreadyReleased = self.readReleased
                self.lock.unlock()
                waiter?.resume()
                return alreadyReleased
            },
            releaseWaiter: { waiter in
                self.lock.lock()
                if self.readReleased {
                    self.lock.unlock()
                    waiter.resume()
                } else {
                    self.readReleaseWaiter = waiter
                    self.lock.unlock()
                }
            }
        )
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
        ExternalSessionStatusV1(
            sourceID: source.sourceID,
            threadID: target.threadID,
            turnID: target.turnID,
            threadStatus: .active,
            observedCursor: .beginning
        )
    }

    func control(
        request: ExternalSessionControlRequestV1,
        controlGrant: ExternalSessionControlGrantV1
    ) async throws -> ExternalSessionControlReceiptV1 {
        await gate(
            enter: {
                self.lock.lock()
                self.controlEnteredCount += 1
                let waiter = self.controlEnteredWaiter
                self.controlEnteredWaiter = nil
                let alreadyReleased = self.controlReleased
                self.lock.unlock()
                waiter?.resume()
                return alreadyReleased
            },
            releaseWaiter: { waiter in
                self.lock.lock()
                if self.controlReleased {
                    self.lock.unlock()
                    waiter.resume()
                } else {
                    self.controlReleaseWaiter = waiter
                    self.lock.unlock()
                }
            }
        )
        return ExternalSessionControlReceiptV1(
            sourceID: source.sourceID,
            threadID: request.threadID,
            turnID: request.turnID,
            operation: request.operation,
            outcome: .accepted,
            sourceCursor: request.expectedCursor
        )
    }

    private func gate(
        enter: () -> Bool,
        releaseWaiter: (CheckedContinuation<Void, Never>) -> Void
    ) async {
        if enter() { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            releaseWaiter(continuation)
        }
    }
}

@Suite("External-session authorization revocation consumer")
struct ExternalSessionAuthorizationRevocation066Tests {
    private var sourceID: ExternalSessionSourceID {
        ExternalSessionSourceID(rawValue: "codex-local")
    }

    private var profileID: ExternalSessionProfileID {
        ExternalSessionProfileID(rawValue: "profile-a")
    }

    private var threadID: ExternalSessionThreadID {
        ExternalSessionThreadID(rawValue: "thread-a")
    }

    private func makeSource(
        capabilities: Set<ExternalSessionCapabilityV1>
    ) -> ExternalSessionSourceV1 {
        ExternalSessionSourceV1(
            sourceID: sourceID,
            kind: .codex,
            adapterVersion: "test",
            profileID: profileID,
            hostID: "local",
            capabilities: capabilities,
            authState: .authorized
        )
    }

    private func makeLedger() -> ExternalSessionAuthorizationLedgerV1 {
        ExternalSessionAuthorizationLedgerV1()
    }

    private func issuedReadGrant(
        on ledger: ExternalSessionAuthorizationLedgerV1
    ) async throws -> ExternalSessionReadGrantV1 {
        try await ledger.issueReadGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "read-\(UUID().uuidString)"),
            sourceID: sourceID,
            profileID: profileID,
            target: .thread(threadID),
            scopes: [.messages],
            issuedAt: Date(timeIntervalSince1970: 100),
            lifetime: 400
        )
    }

    @Test func ledgerIssuedGrantsForwardWhileTheEpochIsActive() async throws {
        let probe = RevocationSpyProbe(source: makeSource(capabilities: [.readMessages, .resume]))
        let ledger = makeLedger()
        let adapter = ExternalSessionAppAdapter(
            implementation: probe,
            clock: { Date(timeIntervalSince1970: 200) },
            authorizationLedger: ledger
        )
        let readGrant = try await ledger.issueReadGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "read-active"),
            sourceID: sourceID,
            profileID: profileID,
            target: .thread(threadID),
            scopes: [.messages],
            issuedAt: Date(timeIntervalSince1970: 100),
            lifetime: 400
        )
        let controlGrant = try await ledger.issueControlGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "control-active"),
            sourceID: sourceID,
            profileID: profileID,
            target: .thread(threadID),
            operations: [.resume],
            issuedAt: Date(timeIntervalSince1970: 100),
            lifetime: 400
        )
        let page = try await adapter.read(
            request: ExternalSessionReadRequestV1(sourceID: sourceID, threadID: threadID, limit: 10),
            readGrant: readGrant
        )
        #expect(page.threadID == threadID)
        let receipt = try await adapter.control(
            request: ExternalSessionControlRequestV1(
                sourceID: sourceID,
                threadID: threadID,
                operation: .resume,
                expectedCursor: .beginning,
                idempotencyKey: "resume-1"
            ),
            controlGrant: controlGrant
        )
        #expect(receipt.operation == ExternalSessionControlOperationV1.resume)
        #expect(probe.calls == ["read:thread-a", "control:resume"])
    }

    @Test func revokedGrantsFailAtAdmissionWithoutAnyTransportCall() async throws {
        let probe = RevocationSpyProbe(source: makeSource(capabilities: [.readMessages, .interrupt]))
        let ledger = makeLedger()
        let adapter = ExternalSessionAppAdapter(
            implementation: probe,
            clock: { Date(timeIntervalSince1970: 200) },
            authorizationLedger: ledger
        )
        let readGrant = try await issuedReadGrant(on: ledger)
        _ = try await adapter.read(
            request: ExternalSessionReadRequestV1(sourceID: sourceID, threadID: threadID, limit: 10),
            readGrant: readGrant
        )
        #expect(probe.calls == ["read:thread-a"])

        await ledger.revoke(sourceID: sourceID, profileID: profileID)

        await #expect(throws: ExternalSessionAppAdapterError.grantRevoked) {
            _ = try await adapter.read(
                request: ExternalSessionReadRequestV1(
                    sourceID: sourceID,
                    threadID: threadID,
                    limit: 10
                ),
                readGrant: readGrant
            )
        }
        await #expect(throws: ExternalSessionAppAdapterError.grantRevoked) {
            _ = try await adapter.control(
                request: ExternalSessionControlRequestV1(
                    sourceID: sourceID,
                    threadID: threadID,
                    operation: .interrupt,
                    expectedCursor: .beginning,
                    idempotencyKey: "interrupt-1"
                ),
                controlGrant: ExternalSessionControlGrantV1(
                    authorizationID: ExternalSessionAuthorizationID(rawValue: "stale-control"),
                    sourceID: sourceID,
                    profileID: profileID,
                    target: .thread(threadID),
                    operations: [.interrupt],
                    issuedAt: Date(timeIntervalSince1970: 100),
                    expiresAt: Date(timeIntervalSince1970: 500),
                    revocationEpoch: 0
                )
            )
        }
        // The revocation itself must not have reached the transport.
        #expect(probe.calls == ["read:thread-a"])

        // The explicit cancel path surfaces the revocation and parks the
        // runtime in its honest failed state instead of faking a cancel.
        await #expect(throws: ExternalSessionAppAdapterError.grantRevoked) {
            _ = try await adapter.cancel(
                sourceID: sourceID,
                threadID: threadID,
                expectedCursor: .beginning,
                idempotencyKey: "cancel-1",
                controlGrant: ExternalSessionControlGrantV1(
                    authorizationID: ExternalSessionAuthorizationID(rawValue: "stale-cancel"),
                    sourceID: sourceID,
                    profileID: profileID,
                    target: .thread(threadID),
                    operations: [.interrupt],
                    issuedAt: Date(timeIntervalSince1970: 100),
                    expiresAt: Date(timeIntervalSince1970: 500),
                    revocationEpoch: 0
                )
            )
        }
        #expect(adapter.runtimeSnapshot.state == ExternalSessionRuntimeState.failed)
        #expect(probe.calls == ["read:thread-a"])
    }

    @Test func revocationDuringSuspendedReadDropsTheFetchedPage() async throws {
        let probe = RevocationSuspendingProbe(source: makeSource(capabilities: [.readMessages]))
        let ledger = makeLedger()
        let adapter = ExternalSessionAppAdapter(
            implementation: probe,
            clock: { Date(timeIntervalSince1970: 200) },
            authorizationLedger: ledger
        )
        let grant = try await issuedReadGrant(on: ledger)
        let pending = Task {
            try await adapter.read(
                request: ExternalSessionReadRequestV1(
                    sourceID: sourceID,
                    threadID: threadID,
                    limit: 10
                ),
                readGrant: grant
            )
        }
        await probe.waitUntilReadEntered()
        // Revocation lands while the provider is still responding.
        await ledger.revoke(sourceID: sourceID, profileID: profileID)
        probe.releaseRead()

        await #expect(throws: ExternalSessionAppAdapterError.grantRevoked) {
            _ = try await pending.value
        }
        // Honest non-terminal fact: the transport really produced a page once;
        // only its publication is fenced.
        #expect(probe.readEntered == 1)

        // Recovery: a grant issued after revocation reads again normally.
        let freshGrant = try await issuedReadGrant(on: ledger)
        #expect(freshGrant.revocationEpoch == 1)
        let page = try await adapter.read(
            request: ExternalSessionReadRequestV1(sourceID: sourceID, threadID: threadID, limit: 10),
            readGrant: freshGrant
        )
        #expect(page.threadID == threadID)
    }

    @Test func controlReceiptIsStillDeliveredWhenRevocationLandsMidFlight() async throws {
        // A control side effect that already executed at the external session
        // must not be hidden by a later revocation; only admission is fenced.
        let probe = RevocationSuspendingProbe(
            source: makeSource(capabilities: [.resume])
        )
        let ledger = makeLedger()
        let adapter = ExternalSessionAppAdapter(
            implementation: probe,
            clock: { Date(timeIntervalSince1970: 200) },
            authorizationLedger: ledger
        )
        let controlGrant = try await ledger.issueControlGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "control-midflight"),
            sourceID: sourceID,
            profileID: profileID,
            target: .thread(threadID),
            operations: [.resume],
            issuedAt: Date(timeIntervalSince1970: 100),
            lifetime: 400
        )
        let pending = Task {
            try await adapter.control(
                request: ExternalSessionControlRequestV1(
                    sourceID: sourceID,
                    threadID: threadID,
                    operation: .resume,
                    expectedCursor: .beginning,
                    idempotencyKey: "resume-midflight"
                ),
                controlGrant: controlGrant
            )
        }
        await probe.waitUntilControlEntered()
        await ledger.revoke(sourceID: sourceID, profileID: profileID)
        probe.releaseControl()

        let receipt = try await pending.value
        #expect(receipt.outcome == ExternalSessionControlOutcomeV1.accepted)
        #expect(probe.controlEntered == 1)
    }

    @Test func adapterWithoutLedgerKeepsThePreviousBoundaryBehavior() async throws {
        // No ledger injected: epoch remains advisory, exactly like before the
        // revocation capability existed, so existing consumers are unaffected.
        let probe = RevocationSpyProbe(source: makeSource(capabilities: [.readMessages]))
        let adapter = ExternalSessionAppAdapter(
            implementation: probe,
            clock: { Date(timeIntervalSince1970: 200) }
        )
        let grant = ExternalSessionReadGrantV1(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "legacy-read"),
            sourceID: sourceID,
            profileID: profileID,
            target: .thread(threadID),
            scopes: [.messages],
            issuedAt: Date(timeIntervalSince1970: 100),
            expiresAt: Date(timeIntervalSince1970: 500),
            revocationEpoch: 0
        )
        let page = try await adapter.read(
            request: ExternalSessionReadRequestV1(sourceID: sourceID, threadID: threadID, limit: 10),
            readGrant: grant
        )
        #expect(page.threadID == threadID)
        #expect(probe.calls == ["read:thread-a"])
    }
}
