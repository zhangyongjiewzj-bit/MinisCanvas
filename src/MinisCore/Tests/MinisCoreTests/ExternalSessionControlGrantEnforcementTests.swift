import Foundation
import Testing
@testable import MinisCore

/// Real-behavior authorization matrix for `ExternalSessionControlLedgerAdapter`
/// (P3-EXT-02 control side, lane DEV-237).
///
/// Every row drives the production enforcement path end to end: a real
/// `ExternalSessionAuthorizationLedgerV1` mints grants (or deliberately does
/// not), the adapter runs its copied-from-head checks, and a recording
/// transport proves whether transport I/O was reached. No row is answered by a
/// static fixture: the transport stand-in never throws, so any error observed
/// can only have come from the enforcement layer, and `receivedRequests`
/// shows exactly which calls crossed the gate — the same proof style as the
/// head's `Composition139Probe`
/// (`src/MinisCanvasApp/Tests/MinisCanvasAppTests/ExternalSessionAuthorizationComposition139Tests.swift:6-12`).
///
/// Canonical anchor: `docs/plans/三期合拢后-全量优化开发Canonical需求总表-20260827.md:352`
/// ("没有 app-server resume/fork/steer/interrupt/approval/recovery 产品闭环",
/// "读取权与控制权分离"; capability available only "经用户单独授权后").
///
/// Encoding notes for two matrix cells, per head semantics (no invented
/// meanings):
/// - "未签发" (not issued) rejects through the ledger's positive-issuance
///   requirement for the exact `(sourceID, profileID)` pair
///   (`ExternalSessionAuthorizationLedger.swift:21-26`, `:74-87`).
/// - "read grant 冒充 control grant" is rejected at the ledger issuance
///   boundary: a control grant cannot even be minted from a read grant's
///   authorization ID (`ExternalSessionAuthorizationLedger.swift:172-179`,
///   `replayedAuthorizationID`), the two grant value types are separate
///   (`ExternalSessionContract.swift:332-370` vs `:390-428`) so a read grant
///   cannot be passed where a control grant is required, and the control
///   adapter refuses to serve any read capability
///   (`ExternalSessionControlLedgerAdapter.listThreads/read/status`).
private actor AcceptedControlTransport: ExternalSessionControlTransportV1 {
    private(set) var receivedRequests: [ExternalSessionControlRequestV1] = []

    func send(
        request: ExternalSessionControlRequestV1,
        controlGrant: ExternalSessionControlGrantV1
    ) async throws -> ExternalSessionControlReceiptV1 {
        receivedRequests.append(request)
        return ExternalSessionControlReceiptV1(
            sourceID: request.sourceID,
            threadID: request.threadID,
            turnID: request.turnID,
            operation: request.operation,
            outcome: .accepted,
            sourceCursor: request.expectedCursor
        )
    }
}

@Suite("External-session control grant enforcement")
struct ExternalSessionControlGrantEnforcementTests {
    // Fixed clock: issuedAt=100, lifetime=200 (expiry=300), now=200.
    private static let issuedAt = Date(timeIntervalSince1970: 100)
    private static let now = Date(timeIntervalSince1970: 200)
    private static let afterExpiry = Date(timeIntervalSince1970: 305)
    private static let beforeIssue = Date(timeIntervalSince1970: 50)
    private static let lifetime: TimeInterval = 200

    private var sourceID: ExternalSessionSourceID { ExternalSessionSourceID(rawValue: "codex-local") }
    private var otherSourceID: ExternalSessionSourceID { ExternalSessionSourceID(rawValue: "claude-local") }
    private var profileID: ExternalSessionProfileID { ExternalSessionProfileID(rawValue: "profile-a") }
    private var otherProfileID: ExternalSessionProfileID { ExternalSessionProfileID(rawValue: "profile-b") }
    private var threadID: ExternalSessionThreadID { ExternalSessionThreadID(rawValue: "thread-1") }
    private var otherThreadID: ExternalSessionThreadID { ExternalSessionThreadID(rawValue: "thread-2") }

    private func makeSource(
        sourceID: ExternalSessionSourceID? = nil,
        profileID: ExternalSessionProfileID? = nil,
        capabilities: Set<ExternalSessionCapabilityV1> = [
            .readMetadata, .readMessages, .status,
            .resume, .fork, .steer, .interrupt, .approval
        ],
        authState: ExternalSessionAuthStateV1 = .authorized
    ) -> ExternalSessionSourceV1 {
        ExternalSessionSourceV1(
            sourceID: sourceID ?? self.sourceID,
            kind: .codex,
            adapterVersion: "test",
            profileID: profileID ?? self.profileID,
            hostID: "local",
            capabilities: capabilities,
            authState: authState
        )
    }

    private func makeAdapter(
        source: ExternalSessionSourceV1? = nil,
        ledger: ExternalSessionAuthorizationLedgerV1,
        now: Date = ExternalSessionControlGrantEnforcementTests.now,
        transport: AcceptedControlTransport
    ) -> ExternalSessionControlLedgerAdapter {
        ExternalSessionControlLedgerAdapter(
            source: source ?? makeSource(),
            ledger: ledger,
            clock: { now },
            transport: transport
        )
    }

    private func issueControlGrant(
        on ledger: ExternalSessionAuthorizationLedgerV1,
        id: String,
        sourceID: ExternalSessionSourceID? = nil,
        profileID: ExternalSessionProfileID? = nil,
        targetThread: ExternalSessionThreadID? = nil,
        operations: Set<ExternalSessionControlOperationV1>
    ) async throws -> ExternalSessionControlGrantV1 {
        try await ledger.issueControlGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: id),
            sourceID: sourceID ?? self.sourceID,
            profileID: profileID ?? self.profileID,
            target: .thread(targetThread ?? self.threadID),
            operations: operations,
            issuedAt: Self.issuedAt,
            lifetime: Self.lifetime
        )
    }

    private func handcraftedControlGrant(
        id: String = "handcrafted",
        sourceID: ExternalSessionSourceID? = nil,
        profileID: ExternalSessionProfileID? = nil,
        targetThread: ExternalSessionThreadID? = nil,
        operations: Set<ExternalSessionControlOperationV1> = [.resume],
        revocationEpoch: UInt64 = 0
    ) -> ExternalSessionControlGrantV1 {
        ExternalSessionControlGrantV1(
            authorizationID: ExternalSessionAuthorizationID(rawValue: id),
            sourceID: sourceID ?? self.sourceID,
            profileID: profileID ?? self.profileID,
            target: .thread(targetThread ?? self.threadID),
            operations: operations,
            issuedAt: Self.issuedAt,
            expiresAt: Self.issuedAt.addingTimeInterval(Self.lifetime),
            revocationEpoch: revocationEpoch
        )
    }

    private func makeRequest(
        operation: ExternalSessionControlOperationV1 = .resume,
        sourceID: ExternalSessionSourceID? = nil,
        thread: ExternalSessionThreadID? = nil,
        idempotencyKey: String = "idem-1"
    ) -> ExternalSessionControlRequestV1 {
        ExternalSessionControlRequestV1(
            sourceID: sourceID ?? self.sourceID,
            threadID: thread ?? self.threadID,
            operation: operation,
            expectedCursor: .beginning,
            idempotencyKey: idempotencyKey
        )
    }

    private typealias Failure = ExternalSessionControlLedgerAdapter.Failure

    // MARK: - Positive path: only a legitimately issued grant produces a receipt

    @Test func legitimatelyIssuedGrantProducesReceiptAndExactlyOneTransportCall() async throws {
        let ledger = ExternalSessionAuthorizationLedgerV1()
        let transport = AcceptedControlTransport()
        let adapter = makeAdapter(ledger: ledger, transport: transport)
        let grant = try await issueControlGrant(on: ledger, id: "ctrl-legit", operations: [.resume])
        let request = makeRequest()

        let receipt = try await adapter.control(request: request, controlGrant: grant)

        #expect(receipt.sourceID == sourceID)
        #expect(receipt.threadID == threadID)
        #expect(receipt.operation == .resume)
        #expect(receipt.outcome == .accepted)
        #expect(receipt.sourceCursor == .beginning)
        #expect(await transport.receivedRequests == [request])
    }

    @Test func preCancelledControlCannotCrossLedgerTransportBoundary() async throws {
        let ledger = ExternalSessionAuthorizationLedgerV1()
        let transport = AcceptedControlTransport()
        let adapter = makeAdapter(ledger: ledger, transport: transport)
        let grant = try await issueControlGrant(on: ledger, id: "ctrl-precancel", operations: [.resume])
        let request = makeRequest(idempotencyKey: "precancel")
        let wasRejected = await Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await adapter.control(request: request, controlGrant: grant)
                return false
            } catch {
                return true
            }
        }.value
        #expect(wasRejected)
        #expect(await transport.receivedRequests.isEmpty)
    }

    @Test func everyHeadTypedControlOperationIsServedUnderAMatchingIssuedGrant() async throws {
        // The typed subset defined at head: ExternalSessionContract.swift:374-382.
        // `recovery` has no operation/capability type at head and is therefore
        // not implemented or asserted here (no invented semantics).
        let ledger = ExternalSessionAuthorizationLedgerV1()
        let transport = AcceptedControlTransport()
        let adapter = makeAdapter(ledger: ledger, transport: transport)

        for operation in [
            ExternalSessionControlOperationV1.resume,
            .fork, .steer, .interrupt, .approve, .reject, .provideInput
        ] {
            let grant = try await issueControlGrant(
                on: ledger,
                id: "ctrl-op-\(operation.rawValue)",
                operations: [operation]
            )
            let receipt = try await adapter.control(
                request: makeRequest(operation: operation),
                controlGrant: grant
            )
            #expect(receipt.operation == operation)
            #expect(receipt.outcome == .accepted)
        }
        #expect(await transport.receivedRequests.count == 7)
    }

    // MARK: - 未签发 (never issued)

    @Test func grantForNeverIssuedPairIsRejectedBeforeTransport() async throws {
        let ledger = ExternalSessionAuthorizationLedgerV1()
        let transport = AcceptedControlTransport()
        let adapter = makeAdapter(ledger: ledger, transport: transport)
        // Well-formed fields, but no issuance through the ledger ever happened
        // for this pair: the positive-issuance record requirement
        // (ExternalSessionAuthorizationLedger.swift:21-26, :74-87) fails it closed.
        let grant = handcraftedControlGrant(id: "not-issued")

        await #expect(throws: Failure.grantRevoked) {
            _ = try await adapter.control(request: makeRequest(), controlGrant: grant)
        }
        #expect(await transport.receivedRequests.isEmpty)
    }

    @Test func controlGrantBuiltFromOtherAuthorizationsComponentsIsRejected() async throws {
        // The exact fail-open case documented at
        // ExternalSessionAuthorizationLedger.swift:21-26: pair (source-a, profile-a)
        // is issued; a grant recombining source-a with profile-b (epoch zero)
        // must not be honored.
        let ledger = ExternalSessionAuthorizationLedgerV1()
        let transport = AcceptedControlTransport()
        _ = try await issueControlGrant(on: ledger, id: "ctrl-pair-a", operations: [.resume])
        let adapter = makeAdapter(
            source: makeSource(profileID: otherProfileID),
            ledger: ledger,
            transport: transport
        )
        let recombined = handcraftedControlGrant(id: "ctrl-recombined", profileID: otherProfileID)

        await #expect(throws: Failure.grantRevoked) {
            _ = try await adapter.control(request: makeRequest(), controlGrant: recombined)
        }
        #expect(await transport.receivedRequests.isEmpty)
    }

    // MARK: - 过期 / 未生效 (expired / not yet valid)

    @Test func expiredGrantIsRejected() async throws {
        let ledger = ExternalSessionAuthorizationLedgerV1()
        let transport = AcceptedControlTransport()
        let adapter = makeAdapter(ledger: ledger, now: Self.afterExpiry, transport: transport)
        let grant = try await issueControlGrant(on: ledger, id: "ctrl-expired", operations: [.resume])

        await #expect(throws: Failure.grantExpired) {
            _ = try await adapter.control(request: makeRequest(), controlGrant: grant)
        }
        #expect(await transport.receivedRequests.isEmpty)
    }

    @Test func notYetValidGrantIsRejected() async throws {
        let ledger = ExternalSessionAuthorizationLedgerV1()
        let transport = AcceptedControlTransport()
        let adapter = makeAdapter(ledger: ledger, now: Self.beforeIssue, transport: transport)
        let grant = try await issueControlGrant(on: ledger, id: "ctrl-future", operations: [.resume])

        await #expect(throws: Failure.grantNotYetValid) {
            _ = try await adapter.control(request: makeRequest(), controlGrant: grant)
        }
        #expect(await transport.receivedRequests.isEmpty)
    }

    // MARK: - 撤销 epoch / 伪造 epoch (revoked / forged epoch)

    @Test func revokedEpochGrantIsRejected() async throws {
        let ledger = ExternalSessionAuthorizationLedgerV1()
        let transport = AcceptedControlTransport()
        let adapter = makeAdapter(ledger: ledger, transport: transport)
        let grant = try await issueControlGrant(on: ledger, id: "ctrl-revoked", operations: [.resume])
        let newEpoch = await ledger.revoke(sourceID: sourceID, profileID: profileID)
        #expect(newEpoch == 1)

        await #expect(throws: Failure.grantRevoked) {
            _ = try await adapter.control(request: makeRequest(), controlGrant: grant)
        }
        #expect(await transport.receivedRequests.isEmpty)

        // Reissuance after revocation stamps the new epoch and works again.
        let fresh = try await issueControlGrant(on: ledger, id: "ctrl-post-revoke", operations: [.resume])
        #expect(fresh.revocationEpoch == 1)
        _ = try await adapter.control(request: makeRequest(idempotencyKey: "idem-2"), controlGrant: fresh)
        #expect(await transport.receivedRequests.count == 1)
    }

    @Test func forgedFutureEpochGrantIsRejectedLikeAStaleOne() async throws {
        // Strict-equality epoch comparison (ExternalSessionAuthorizationLedger.swift:17-18).
        let ledger = ExternalSessionAuthorizationLedgerV1()
        let transport = AcceptedControlTransport()
        let adapter = makeAdapter(ledger: ledger, transport: transport)
        _ = try await issueControlGrant(on: ledger, id: "ctrl-anchor", operations: [.resume])
        let forged = handcraftedControlGrant(id: "ctrl-forged", revocationEpoch: 99)

        await #expect(throws: Failure.grantRevoked) {
            _ = try await adapter.control(request: makeRequest(), controlGrant: forged)
        }
        #expect(await transport.receivedRequests.isEmpty)
    }

    // MARK: - 跨 source (cross source) and revocation scoping

    @Test func grantIssuedForAnotherSourceIsRejectedByThisAdaptersSource() async throws {
        let ledger = ExternalSessionAuthorizationLedgerV1()
        let transport = AcceptedControlTransport()
        let adapter = makeAdapter(ledger: ledger, transport: transport)
        let foreignGrant = try await issueControlGrant(
            on: ledger,
            id: "ctrl-foreign-source",
            sourceID: otherSourceID,
            operations: [.resume]
        )

        await #expect(throws: Failure.sourceMismatch) {
            _ = try await adapter.control(request: makeRequest(), controlGrant: foreignGrant)
        }
        #expect(await transport.receivedRequests.isEmpty)
    }

    @Test func revocationOnOneSourcePairDoesNotDisableAnotherSource() async throws {
        // Revocation is scoped (ExternalSessionAuthorizationLedger.swift:19-20,
        // :89-101): killing (claude-local, profile-a) must leave
        // (codex-local, profile-a) usable.
        let ledger = ExternalSessionAuthorizationLedgerV1()
        let adapterTransport = AcceptedControlTransport()
        let adapter = makeAdapter(ledger: ledger, transport: adapterTransport)
        let grant = try await issueControlGrant(on: ledger, id: "ctrl-scoped", operations: [.steer])
        _ = try await issueControlGrant(
            on: ledger,
            id: "ctrl-other-source",
            sourceID: otherSourceID,
            operations: [.steer]
        )
        _ = await ledger.revoke(sourceID: otherSourceID, profileID: profileID)

        let receipt = try await adapter.control(
            request: makeRequest(operation: .steer),
            controlGrant: grant
        )
        #expect(receipt.outcome == .accepted)
        #expect(await adapterTransport.receivedRequests.count == 1)
    }

    // MARK: - read grant 冒充 control grant (read→control conversion)

    @Test func controlGrantCannotBeMintedFromAReadGrantsAuthorizationID() async throws {
        // The read authorization exists first; converting its ID into a
        // control grant is refused at the ledger (replay prevention,
        // ExternalSessionAuthorizationLedger.swift:172-179).
        let ledger = ExternalSessionAuthorizationLedgerV1()
        _ = try await ledger.issueReadGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "auth-shared"),
            sourceID: sourceID,
            profileID: profileID,
            target: .thread(threadID),
            scopes: [.messages],
            issuedAt: Self.issuedAt,
            lifetime: Self.lifetime
        )

        await #expect(throws: ExternalSessionAuthorizationLedgerV1.LedgerError
            .replayedAuthorizationID("auth-shared")) {
            _ = try await ledger.issueControlGrant(
                authorizationID: ExternalSessionAuthorizationID(rawValue: "auth-shared"),
                sourceID: sourceID,
                profileID: profileID,
                target: .thread(threadID),
                operations: [.resume],
                issuedAt: Self.issuedAt,
                lifetime: Self.lifetime
            )
        }

        // With the conversion refused, the read authorization's ID carries no
        // control power: presented as a hand-built control grant against a
        // pair the ledger never issued, the adapter's ledger admission fails
        // it closed. (Head semantics deliberately do not track grant *kind*
        // per authorization ID beyond issuance; see the doc comment above.)
        let foreignTransport = AcceptedControlTransport()
        let foreignAdapter = makeAdapter(
            source: makeSource(sourceID: otherSourceID),
            ledger: ledger,
            transport: foreignTransport
        )
        await #expect(throws: Failure.grantRevoked) {
            _ = try await foreignAdapter.control(
                request: makeRequest(sourceID: otherSourceID),
                controlGrant: handcraftedControlGrant(
                    id: "auth-shared",
                    sourceID: otherSourceID
                )
            )
        }
        #expect(await foreignTransport.receivedRequests.isEmpty)
    }

    @Test func controlAdapterRefusesReadMethodsEvenWithAFreshlyMintedReadGrant() async throws {
        // "读取权与控制权分离": the control path never serves read capability,
        // so a read grant can never be traded for data through this adapter.
        let ledger = ExternalSessionAuthorizationLedgerV1()
        let transport = AcceptedControlTransport()
        let adapter = makeAdapter(ledger: ledger, transport: transport)
        let readGrant = try await ledger.issueReadGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "read-valid"),
            sourceID: sourceID,
            profileID: profileID,
            target: .thread(threadID),
            scopes: [.metadata, .messages, .status],
            issuedAt: Self.issuedAt,
            lifetime: Self.lifetime
        )

        await #expect(throws: Failure.readNotServedByControlAdapter) {
            _ = try await adapter.listThreads(
                query: ExternalSessionThreadQueryV1(sourceID: sourceID, limit: 10),
                readGrant: readGrant
            )
        }
        await #expect(throws: Failure.readNotServedByControlAdapter) {
            _ = try await adapter.read(
                request: ExternalSessionReadRequestV1(sourceID: sourceID, threadID: threadID, limit: 10),
                readGrant: readGrant
            )
        }
        await #expect(throws: Failure.readNotServedByControlAdapter) {
            _ = try await adapter.status(
                target: ExternalSessionStatusTargetV1(sourceID: sourceID),
                readGrant: readGrant
            )
        }
        #expect(await transport.receivedRequests.isEmpty)
    }

    // MARK: - Field-level enforcement within an otherwise valid issued grant

    @Test func operationOutsideGrantedSetIsRejected() async throws {
        let ledger = ExternalSessionAuthorizationLedgerV1()
        let transport = AcceptedControlTransport()
        let adapter = makeAdapter(ledger: ledger, transport: transport)
        let grant = try await issueControlGrant(on: ledger, id: "ctrl-interrupt-only", operations: [.interrupt])

        await #expect(throws: Failure.operationNotGranted(.steer)) {
            _ = try await adapter.control(request: makeRequest(operation: .steer), controlGrant: grant)
        }
        #expect(await transport.receivedRequests.isEmpty)
    }

    @Test func requestForThreadOutsideGrantedTargetIsRejected() async throws {
        let ledger = ExternalSessionAuthorizationLedgerV1()
        let transport = AcceptedControlTransport()
        let adapter = makeAdapter(ledger: ledger, transport: transport)
        let grant = try await issueControlGrant(on: ledger, id: "ctrl-thread-1", operations: [.resume])

        await #expect(throws: Failure.targetMismatch) {
            _ = try await adapter.control(
                request: makeRequest(thread: otherThreadID),
                controlGrant: grant
            )
        }
        #expect(await transport.receivedRequests.isEmpty)
    }

    @Test func operationWithoutSourceCapabilityIsRejected() async throws {
        let ledger = ExternalSessionAuthorizationLedgerV1()
        let transport = AcceptedControlTransport()
        let adapter = makeAdapter(
            source: makeSource(capabilities: [.readMetadata, .readMessages, .status, .steer]),
            ledger: ledger,
            transport: transport
        )
        // The ledger stamps grants without judging the source capability set
        // (that is the adapter's check, per ExternalSessionAppAdapter.swift:1049-1053).
        let grant = try await issueControlGrant(on: ledger, id: "ctrl-fork-no-cap", operations: [.fork])

        await #expect(throws: Failure.capabilityUnavailable(.fork)) {
            _ = try await adapter.control(request: makeRequest(operation: .fork), controlGrant: grant)
        }
        #expect(await transport.receivedRequests.isEmpty)
    }

    @Test func blankIdempotencyKeyIsRejected() async throws {
        let ledger = ExternalSessionAuthorizationLedgerV1()
        let transport = AcceptedControlTransport()
        let adapter = makeAdapter(ledger: ledger, transport: transport)
        let grant = try await issueControlGrant(on: ledger, id: "ctrl-idem", operations: [.resume])

        await #expect(throws: Failure.invalidRequest) {
            _ = try await adapter.control(
                request: makeRequest(idempotencyKey: "   "),
                controlGrant: grant
            )
        }
        #expect(await transport.receivedRequests.isEmpty)
    }

    @Test func requestAddressedAtAnotherSourceIsRejected() async throws {
        let ledger = ExternalSessionAuthorizationLedgerV1()
        let transport = AcceptedControlTransport()
        let adapter = makeAdapter(ledger: ledger, transport: transport)
        let grant = try await issueControlGrant(on: ledger, id: "ctrl-req-source", operations: [.resume])

        await #expect(throws: Failure.sourceMismatch) {
            _ = try await adapter.control(
                request: makeRequest(sourceID: otherSourceID),
                controlGrant: grant
            )
        }
        #expect(await transport.receivedRequests.isEmpty)
    }

    @Test func unauthorizedSourceAuthStateIsRejected() async throws {
        let ledger = ExternalSessionAuthorizationLedgerV1()
        let transport = AcceptedControlTransport()
        let grant = try await issueControlGrant(
            on: ledger,
            id: "ctrl-auth-state",
            operations: [.resume]
        )
        let adapter = makeAdapter(
            source: makeSource(authState: .revoked),
            ledger: ledger,
            transport: transport
        )

        await #expect(throws: Failure.sourceUnavailable) {
            _ = try await adapter.control(request: makeRequest(), controlGrant: grant)
        }
        #expect(await transport.receivedRequests.isEmpty)
    }

    @Test func grantForAnotherProfileIsRejected() async throws {
        let ledger = ExternalSessionAuthorizationLedgerV1()
        let transport = AcceptedControlTransport()
        let adapter = makeAdapter(ledger: ledger, transport: transport)
        let grant = try await issueControlGrant(
            on: ledger,
            id: "ctrl-other-profile",
            profileID: otherProfileID,
            operations: [.resume]
        )

        await #expect(throws: Failure.profileMismatch) {
            _ = try await adapter.control(request: makeRequest(), controlGrant: grant)
        }
        #expect(await transport.receivedRequests.isEmpty)
    }

    // MARK: - Request construction

    @Test func makeControlRequestBindsAdapterOwnSourceAndPassesEnforcement() async throws {
        let ledger = ExternalSessionAuthorizationLedgerV1()
        let transport = AcceptedControlTransport()
        let adapter = makeAdapter(ledger: ledger, transport: transport)
        let grant = try await issueControlGrant(on: ledger, id: "ctrl-constructed", operations: [.interrupt])

        let request = adapter.makeControlRequest(
            threadID: threadID,
            operation: .interrupt,
            expectedCursor: .beginning,
            idempotencyKey: "idem-constructed"
        )
        #expect(request.sourceID == sourceID)
        #expect(request.schemaVersion == ExternalSessionContractV1.schemaVersion)
        #expect(request.operation == .interrupt)

        let receipt = try await adapter.control(request: request, controlGrant: grant)
        #expect(receipt.operation == .interrupt)
        #expect(await transport.receivedRequests == [request])
    }
}
