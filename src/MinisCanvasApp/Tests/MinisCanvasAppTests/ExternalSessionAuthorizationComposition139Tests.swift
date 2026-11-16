import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// Stateless, always-succeeding transport stand-in.
///
/// It is deliberately a `struct` with no mutable state: every method returns a
/// well-formed value instead of throwing, so any error observed by a test can
/// only have come from the app-side gate, never from the implementation. That
/// makes "denied before transport I/O" provable without counters, locks or an
/// `@unchecked Sendable` escape hatch.
private struct Composition139Probe: ExistingAgentSessionAdapter {
    let source: ExternalSessionSourceV1

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
        ExternalSessionControlReceiptV1(
            sourceID: source.sourceID,
            threadID: request.threadID,
            turnID: request.turnID,
            operation: request.operation,
            outcome: .accepted,
            sourceCursor: request.expectedCursor
        )
    }
}

/// Lane 139: the external-session authorization ledger must be owned by the
/// production composition root and injected non-nil, so revocation reaches the
/// app gate instead of being skipped by a `nil` default.
///
/// All rows exercise the real production boundary
/// (`ProductionOrchestrationDefaults.makeExternalSessionAuthorization`, the
/// exact call `MinisCanvasAppMain.init` performs), not a test-local assembly.
@Suite("External-session authorization composition root")
@MainActor
struct ExternalSessionAuthorizationComposition139Tests {
    /// `Date` is `Sendable` and its initializer is nonisolated, so the constant
    /// is declared `nonisolated` (the codebase's existing convention, e.g.
    /// `ChatStore`/`CanvasStore`) instead of inheriting the suite's `@MainActor`
    /// isolation. That is what lets the `@Sendable` `clock:` closures below read
    /// it; the value passed to every adapter is unchanged.
    private nonisolated static let now = Date(timeIntervalSince1970: 200)
    private static let issuedAt = Date(timeIntervalSince1970: 100)
    private static let lifetime: TimeInterval = 400

    private var sourceID: ExternalSessionSourceID { ExternalSessionSourceID(rawValue: "codex-local") }
    private var otherSourceID: ExternalSessionSourceID { ExternalSessionSourceID(rawValue: "claude-local") }
    private var profileID: ExternalSessionProfileID { ExternalSessionProfileID(rawValue: "profile-a") }
    private var otherProfileID: ExternalSessionProfileID { ExternalSessionProfileID(rawValue: "profile-b") }
    private var threadID: ExternalSessionThreadID { ExternalSessionThreadID(rawValue: "thread-a") }

    private func makeSource(
        sourceID: ExternalSessionSourceID? = nil,
        profileID: ExternalSessionProfileID? = nil,
        capabilities: Set<ExternalSessionCapabilityV1> = [.readMessages, .status, .resume, .interrupt]
    ) -> ExternalSessionSourceV1 {
        ExternalSessionSourceV1(
            sourceID: sourceID ?? self.sourceID,
            kind: .codex,
            adapterVersion: "test",
            profileID: profileID ?? self.profileID,
            hostID: "local",
            capabilities: capabilities,
            authState: .authorized
        )
    }

    /// The production composition seam used by the app root.
    private func makeComposition(
        consumer: TaskCenterControlConsumer? = nil
    ) -> ExternalSessionAuthorizationComposition {
        ProductionOrchestrationDefaults.makeExternalSessionAuthorization(runtimeConsumer: consumer)
    }

    private func readRequest() -> ExternalSessionReadRequestV1 {
        ExternalSessionReadRequestV1(sourceID: sourceID, threadID: threadID, limit: 10)
    }

    private func controlRequest(
        _ operation: ExternalSessionControlOperationV1 = .resume,
        key: String = "op-1"
    ) -> ExternalSessionControlRequestV1 {
        ExternalSessionControlRequestV1(
            sourceID: sourceID,
            threadID: threadID,
            operation: operation,
            expectedCursor: .beginning,
            idempotencyKey: key
        )
    }

    /// A syntactically valid, un-expired grant for a pair no ledger ever issued.
    private func unissuedReadGrant(
        sourceID: ExternalSessionSourceID? = nil,
        profileID: ExternalSessionProfileID? = nil,
        epoch: UInt64 = 0
    ) -> ExternalSessionReadGrantV1 {
        ExternalSessionReadGrantV1(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "unissued-\(UUID().uuidString)"),
            sourceID: sourceID ?? self.sourceID,
            profileID: profileID ?? self.profileID,
            target: .thread(threadID),
            scopes: [.messages],
            issuedAt: Self.issuedAt,
            expiresAt: Self.issuedAt.addingTimeInterval(Self.lifetime),
            revocationEpoch: epoch
        )
    }

    private func supervisedComposition(
        consumer: TaskCenterControlConsumer? = nil
    ) -> (ExternalSessionAuthorizationComposition, ExternalSessionAppAdapter) {
        let composition = makeComposition(consumer: consumer)
        let adapter = composition.makeAdapter(
            implementation: Composition139Probe(source: makeSource()),
            clock: { Self.now }
        )
        return (composition, adapter)
    }

    // MARK: - Ownership and non-nil injection

    @Test func appCompositionSuppliesOneLedgerAndInjectsThatSameInstance() async throws {
        let (composition, adapter) = supervisedComposition()
        let declaredLedger: ExternalSessionAuthorizationLedgerV1? = composition.ledger
        let ledger = try #require(declaredLedger)
        // Revoking through the owner's own ledger instance must change the
        // adapter's decision, which is only possible if that exact instance —
        // not a fresh private one — was injected.
        let grant = try await composition.issueReadGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "read-shared"),
            sourceID: sourceID,
            profileID: profileID,
            target: .thread(threadID),
            scopes: [.messages],
            issuedAt: Self.issuedAt,
            lifetime: Self.lifetime
        )
        let firstPage = try await adapter.read(request: readRequest(), readGrant: grant)
        #expect(firstPage.threadID == threadID)

        // Revocation driven straight from the owner's ledger instance, not from
        // a ledger the adapter could have built privately.
        _ = await ledger.revoke(sourceID: sourceID, profileID: profileID)
        let stillActive = await ledger.isAuthorizationActive(
            sourceID: sourceID,
            profileID: profileID,
            revocationEpoch: grant.revocationEpoch
        )
        #expect(!stillActive)

        await #expect(throws: ExternalSessionAppAdapterError.grantRevoked) {
            _ = try await adapter.read(request: readRequest(), readGrant: grant)
        }
        // Only one source is supervised and it is the adapter this owner built.
        let supervised = composition.supervisedSourceIDs
        #expect(supervised == [sourceID])
        // One ledger per owner, and never a process-wide shared instance.
        let sibling = makeComposition()
        #expect(sibling.ledger !== ledger)
    }

    @Test func ledgerIssuedGrantIsStampedWithTheLiveEpoch() async throws {
        let (composition, _) = supervisedComposition()
        let grant = try await composition.issueReadGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "read-epoch"),
            sourceID: sourceID,
            profileID: profileID,
            target: .thread(threadID),
            scopes: [.messages],
            issuedAt: Self.issuedAt,
            lifetime: Self.lifetime
        )
        let liveEpoch = await composition.revocationEpoch(sourceID: sourceID, profileID: profileID)
        #expect(grant.revocationEpoch == liveEpoch)
    }

    // MARK: - Revocation reaches the next decision

    @Test func revokingTheSourceProfilePairFlipsTheNextReadDecision() async throws {
        let (composition, adapter) = supervisedComposition()
        let grant = try await composition.issueReadGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "read-revoked"),
            sourceID: sourceID,
            profileID: profileID,
            target: .thread(threadID),
            scopes: [.messages],
            issuedAt: Self.issuedAt,
            lifetime: Self.lifetime
        )
        let page = try await adapter.read(request: readRequest(), readGrant: grant)
        #expect(page.threadID == threadID)

        let nextEpoch = await composition.revoke(sourceID: sourceID, profileID: profileID)
        #expect(nextEpoch == 1)

        await #expect(throws: ExternalSessionAppAdapterError.grantRevoked) {
            _ = try await adapter.read(request: readRequest(), readGrant: grant)
        }
    }

    @Test func revokingAlsoRefusesControlAdmissionAndStaysScopedToThePair() async throws {
        let consumer = TaskCenterControlConsumer(store: AgentTaskStore())
        let composition = makeComposition(consumer: consumer)
        let adapter = composition.makeAdapter(
            implementation: Composition139Probe(source: makeSource()),
            clock: { Self.now }
        )
        // A second, different pair supervised by the same ledger/adapter owner.
        let otherAdapter = composition.makeAdapter(
            implementation: Composition139Probe(
                source: makeSource(sourceID: otherSourceID, profileID: otherProfileID)
            ),
            clock: { Self.now }
        )
        let controlGrant = try await composition.issueControlGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "control-revoked"),
            sourceID: sourceID,
            profileID: profileID,
            target: .thread(threadID),
            operations: [.resume],
            issuedAt: Self.issuedAt,
            lifetime: Self.lifetime
        )
        let otherReadGrant = try await composition.issueReadGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "other-read"),
            sourceID: otherSourceID,
            profileID: otherProfileID,
            target: .thread(threadID),
            scopes: [.messages],
            issuedAt: Self.issuedAt,
            lifetime: Self.lifetime
        )
        // The production gate now requires a status-backed runtime owner
        // before control. Establish that owner through the real connect path
        // using this test's owned synthetic source, never by seeding state.
        let statusGrant = try await composition.issueReadGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "status-before-control"),
            sourceID: sourceID,
            profileID: profileID,
            target: .source(sourceID),
            scopes: [.status],
            issuedAt: Self.issuedAt,
            lifetime: Self.lifetime
        )
        let connected = try await adapter.connect(readGrant: statusGrant)
        #expect(connected.state == .connected)
        #expect(connected.ownerID != nil)
        let receipt = try await adapter.control(request: controlRequest(), controlGrant: controlGrant)
        #expect(receipt.operation == ExternalSessionControlOperationV1.resume)

        await composition.revoke(sourceID: sourceID, profileID: profileID)
        #expect(adapter.runtimeSnapshot.state == .disconnected)

        // Revocation permanently retires this adapter generation. A fresh
        // status grant may connect a replacement, but cannot revive either
        // the old adapter or its old control grant.
        let freshStatusGrant = try await composition.issueReadGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "status-after-revoke"),
            sourceID: sourceID,
            profileID: profileID,
            target: .source(sourceID),
            scopes: [.status],
            issuedAt: Self.issuedAt,
            lifetime: Self.lifetime
        )
        await #expect(throws: ExternalSessionAppAdapterError.runtimeUnavailable) {
            _ = try await adapter.reconnect(readGrant: freshStatusGrant)
        }
        let replacementAdapter = composition.makeAdapter(
            implementation: Composition139Probe(source: makeSource()),
            clock: { Self.now }
        )
        let reconnected = try await replacementAdapter.connect(readGrant: freshStatusGrant)
        #expect(reconnected.state == .connected)
        #expect(reconnected.ownerID != nil)
        #expect(reconnected.ownerID != connected.ownerID)

        await #expect(throws: ExternalSessionAppAdapterError.grantRevoked) {
            _ = try await replacementAdapter.control(
                request: controlRequest(key: "op-2"),
                controlGrant: controlGrant
            )
        }
        // Revocation is pair-scoped: the untouched pair still works.
        let otherPage = try await otherAdapter.read(
            request: ExternalSessionReadRequestV1(sourceID: otherSourceID, threadID: threadID, limit: 10),
            readGrant: otherReadGrant
        )
        #expect(otherPage.sourceID == otherSourceID)
    }

    // MARK: - Fail-closed on a missing grant (RED by construction at head)

    @Test func productionAdapterDeniesAGrantTheLedgerNeverIssued() async throws {
        let (composition, adapter) = supervisedComposition()
        // The acceptance element is explicit: the wired path carries a ledger.
        // It is non-optional by type on this path, and this pins that fact at
        // the boundary instead of trusting the declaration.
        let wiredLedger: ExternalSessionAuthorizationLedgerV1? = composition.ledger
        #expect(wiredLedger != nil)
        await #expect(throws: ExternalSessionAppAdapterError.grantRevoked) {
            _ = try await adapter.read(request: readRequest(), readGrant: unissuedReadGrant())
        }
        // A pair assembled from this source and a foreign profile is closed too,
        // by the identity check that runs before the epoch check. Cross-pair
        // combinations are never an escape hatch into an authorized pair.
        await #expect(throws: ExternalSessionAppAdapterError.profileMismatch) {
            _ = try await adapter.read(
                request: readRequest(),
                readGrant: unissuedReadGrant(profileID: otherProfileID)
            )
        }
    }

    /// Characterization pin for the defect this lane closes.
    ///
    /// On the accepted head the only app-side construction of the gate is the
    /// defaulted initializer, whose
    /// `authorizationLedger: ExternalSessionAuthorizationLedgerV1? = nil` makes
    /// `enforceAuthorizationActive` return before consulting any epoch. The
    /// identical assertion sequence that fails closed through the composition
    /// therefore *returns the transcript page* through this legacy path: the
    /// missing-ledger default is fail-OPEN, not fail-closed. This test records
    /// that direction on purpose; it must go red the moment the legacy default
    /// is removed, which is the intended migration signal.
    @Test func legacyNilLedgerConstructionIsFailOpenAndMustNotBeUsedByProduction() async throws {
        let legacy = ExternalSessionAppAdapter(
            implementation: Composition139Probe(source: makeSource()),
            clock: { Self.now }
        )
        let page = try await legacy.read(request: readRequest(), readGrant: unissuedReadGrant())
        #expect(page.threadID == threadID, "legacy nil-ledger path is fail-open by design of this pin")

        let wired = ExternalSessionAppAdapter.production(
            implementation: Composition139Probe(source: makeSource()),
            clock: { Self.now },
            authorizationLedger: ExternalSessionAuthorizationLedgerV1()
        )
        await #expect(throws: ExternalSessionAppAdapterError.grantRevoked) {
            _ = try await wired.read(request: readRequest(), readGrant: unissuedReadGrant())
        }
    }

    // MARK: - No new capability surface

    @Test func composingTheLedgerAlonePublishesNoExternalSessionSurface() async throws {
        let consumer = TaskCenterControlConsumer(store: AgentTaskStore())
        let composition = makeComposition(consumer: consumer)
        // The app root registers the ledger owner only. No source is attached,
        // so Task Center's projection stays nil exactly as before this lane.
        #expect(consumer.externalSessionRuntime == nil)
        #expect(composition.supervisedSourceIDs.isEmpty)
        // Binding becomes observable only once an adapter actually exists,
        // which requires a transport implementation the app does not have.
        _ = composition.makeAdapter(
            implementation: Composition139Probe(source: makeSource()),
            clock: { Self.now }
        )
        let projection = try #require(consumer.externalSessionRuntime)
        #expect(projection.snapshot.state == ExternalSessionRuntimeState.disconnected)
        #expect(projection.snapshot.ownerID == nil)
    }

    @Test func grantIssuanceRefusesASourceThisOwnerDoesNotSupervise() async throws {
        let composition = makeComposition()
        await #expect(throws: ExternalSessionAppAdapterError.sourceMismatch) {
            _ = try await composition.issueReadGrant(
                authorizationID: ExternalSessionAuthorizationID(rawValue: "read-unbound"),
                sourceID: sourceID,
                profileID: profileID,
                target: .thread(threadID),
                scopes: [.messages],
                issuedAt: Self.issuedAt,
                lifetime: Self.lifetime
            )
        }
        await #expect(throws: ExternalSessionAppAdapterError.sourceMismatch) {
            _ = try await composition.issueControlGrant(
                authorizationID: ExternalSessionAuthorizationID(rawValue: "control-unbound"),
                sourceID: sourceID,
                profileID: profileID,
                target: .thread(threadID),
                operations: [.resume],
                issuedAt: Self.issuedAt,
                lifetime: Self.lifetime
            )
        }
    }

    @Test func wiringDoesNotLoosenTheScopeCapabilitySplit() async throws {
        let (composition, adapter) = supervisedComposition()
        let grant = try await composition.issueReadGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "read-scope"),
            sourceID: sourceID,
            profileID: profileID,
            target: .thread(threadID),
            scopes: [.status],
            issuedAt: Self.issuedAt,
            lifetime: Self.lifetime
        )
        // Scope split is unchanged by the wiring: a status-only scope cannot
        // serve a message read.
        await #expect(throws: ExternalSessionAppAdapterError.scopeNotGranted) {
            _ = try await adapter.read(request: readRequest(), readGrant: grant)
        }
    }

    @Test func productionEntryReconnectContinuesCheckpointAttemptAndRejectsLateGeneration1741() async throws {
        let composition = makeComposition()
        let adapter = composition.makeAdapter(
            implementation: Composition139Probe(source: makeSource(
                capabilities: [.status, .stream]
            )),
            clock: { Self.now }
        )
        let statusGrant = try await composition.issueReadGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "reconnect-status"),
            sourceID: sourceID,
            profileID: profileID,
            target: .source(sourceID),
            scopes: [.status],
            issuedAt: Self.issuedAt,
            lifetime: Self.lifetime
        )
        let eventsGrant = try await composition.issueReadGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "reconnect-events"),
            sourceID: sourceID,
            profileID: profileID,
            target: .thread(threadID),
            scopes: [.events],
            issuedAt: Self.issuedAt,
            lifetime: Self.lifetime
        )
        let first = try await adapter.connect(readGrant: statusGrant)
        let firstOwner = try #require(first.ownerID)
        let correlationID = "external-codex-\(sourceID.rawValue)"
        let attemptID = "composition-clean-attempt"
        #expect(adapter.beginExternalAttempt(
            correlationID: correlationID, attemptID: attemptID, ownerID: firstOwner
        ))

        func event(
            _ id: String, sequence: UInt64, kind: ExternalSessionEventKindV1
        ) -> ExternalSessionEventV1 {
            ExternalSessionEventV1(
                eventID: ExternalSessionEventID(rawValue: id), sourceID: sourceID,
                threadID: threadID, turnID: ExternalSessionTurnID(rawValue: "turn-1"),
                sequence: sequence, sourceCursor: ExternalSessionCursorV1(rawValue: "cursor-\(sequence)"),
                occurredAt: Self.now, required: false, kind: kind,
                payload: ExternalSessionRedactedPayloadV1(kind: kind.rawValue, summary: "safe"),
                sourceRef: "synthetic"
            )
        }

        let progress = event("clean-progress", sequence: 1, kind: .progress)
        #expect(try await adapter.consumeExternalEvent(
            progress, correlationID: correlationID, attemptID: attemptID,
            ownerID: firstOwner, connectionGeneration: first.generation,
            readGrant: eventsGrant
        ) == .accepted)
        let completed = event("clean-completed", sequence: 2, kind: .turnCompleted)
        #expect(try await adapter.consumeExternalEvent(
            completed, correlationID: correlationID, attemptID: attemptID,
            ownerID: firstOwner, connectionGeneration: first.generation,
            readGrant: eventsGrant
        ) == .accepted)
        #expect(adapter.runtimeSnapshot.eventCheckpoint?.identity.attemptID == attemptID)

        // The stream ended after a terminal event, so this is a clean
        // disconnect and its checkpoint identity is eligible for continuation.
        adapter.disconnect()
        let reconnected = try await adapter.reconnect(readGrant: statusGrant)
        let secondOwner = try #require(reconnected.ownerID)
        #expect(reconnected.generation > first.generation)
        #expect(adapter.beginExternalAttempt(
            correlationID: correlationID, attemptID: attemptID, ownerID: secondOwner
        ))

        let resumed = event("clean-resumed", sequence: 3, kind: .progress)
        #expect(try await adapter.consumeExternalEvent(
            resumed, correlationID: correlationID, attemptID: attemptID,
            ownerID: secondOwner, connectionGeneration: first.generation,
            readGrant: eventsGrant
        ) == .rejectedLateResult)
        #expect(try await adapter.consumeExternalEvent(
            resumed, correlationID: correlationID, attemptID: attemptID,
            ownerID: secondOwner, connectionGeneration: reconnected.generation,
            readGrant: eventsGrant
        ) == .accepted)
    }
}
