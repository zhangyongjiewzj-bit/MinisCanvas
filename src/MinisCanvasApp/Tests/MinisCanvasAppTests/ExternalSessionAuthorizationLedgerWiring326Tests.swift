import Foundation
import SwiftUI
import Testing
import MinisCore
@testable import MinisCanvasApp

/// Stateless always-succeeding transport stand-in (same convention as the
/// lane-139 probe): any error a row observes can only come from the app-side
/// composition gate, never from the implementation.
private struct Ledger326Probe: ExistingAgentSessionAdapter {
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

/// 077-A 差额面⑤（DEV-326）：组合根 snapshot 透传与「用户签发入口 →
/// isAuthorizationActive」链路。展示层状态推导（readGrantStatus）钉为
/// 纯显示口径。执法/epoch 合同测试（Revocation066Tests 等）不改、不重叠。
@Suite("External-session authorization ledger presentation wiring")
@MainActor
struct ExternalSessionAuthorizationLedgerWiring326Tests {
    private nonisolated static let issuedAt = Date(timeIntervalSince1970: 100)
    private nonisolated static let lifetime: TimeInterval = 400

    private var sourceID: ExternalSessionSourceID { ExternalSessionSourceID(rawValue: "codex-local") }
    private var unknownSourceID: ExternalSessionSourceID { ExternalSessionSourceID(rawValue: "not-registered") }
    private var profileID: ExternalSessionProfileID { ExternalSessionProfileID(rawValue: "profile-a") }
    private var threadID: ExternalSessionThreadID { ExternalSessionThreadID(rawValue: "thread-a") }

    private func makeComposition() -> ExternalSessionAuthorizationComposition {
        ProductionOrchestrationDefaults.makeExternalSessionAuthorization(runtimeConsumer: nil)
    }

    private func makeProbe() -> Ledger326Probe {
        Ledger326Probe(
            source: ExternalSessionSourceV1(
                sourceID: sourceID,
                kind: .codex,
                adapterVersion: "test",
                profileID: profileID,
                hostID: "local",
                capabilities: [.readMessages, .status],
                authState: .authorized
            )
        )
    }

    @Test func environmentDefaultIsNilSoUnwiredSurfacesRenderNoIssuer() {
        #expect(EnvironmentValues().externalSessionAuthorizationComposition == nil)
    }

    @Test func supervisedProfileComesFromTheRegisteredAdapter() {
        let composition = makeComposition()
        #expect(composition.supervisedProfileID(for: sourceID) == nil)
        _ = composition.makeAdapter(implementation: makeProbe())
        #expect(composition.supervisedProfileID(for: sourceID) == profileID)
        #expect(composition.supervisedProfileID(for: unknownSourceID) == nil)
    }

    @Test func compositionSnapshotIsAPurePassthroughOfTheLedgerSnapshot() async throws {
        let composition = makeComposition()
        #expect(await composition.authorizationSnapshot() == .empty)
        _ = composition.makeAdapter(implementation: makeProbe())
        _ = try await composition.issueReadGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "read-1"),
            sourceID: sourceID,
            profileID: profileID,
            target: .thread(threadID),
            scopes: [.messages],
            issuedAt: Self.issuedAt,
            lifetime: Self.lifetime
        )
        let viaComposition = await composition.authorizationSnapshot()
        let viaLedger = await composition.ledger.authorizationSnapshot()
        #expect(viaComposition == viaLedger)
        #expect(viaComposition.authorizedPairs == [
            .init(sourceID: sourceID, profileID: profileID, revocationEpoch: 0)
        ])
        #expect(viaComposition.readGrants.count == 1)
    }

    @Test func userMintedReadGrantActivatesIsAuthorizationActiveEndToEnd() async throws {
        let composition = makeComposition()
        _ = composition.makeAdapter(implementation: makeProbe())

        // Mirrors what the Task Center ledger card submits after the
        // confirmation step: UUID authorization ID, adapter-owned profile,
        // user-chosen target and scopes, bounded lifetime. `issuedAt` is
        // pinned here (the card leaves it to the `Date()` default) only so
        // the expiry assertion below is deterministic.
        let grant = try await composition.issueReadGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: UUID().uuidString),
            sourceID: sourceID,
            profileID: profileID,
            target: .thread(threadID),
            scopes: [.metadata, .messages],
            issuedAt: Self.issuedAt,
            lifetime: Self.lifetime
        )
        #expect(grant.scopes == [.metadata, .messages])
        #expect(grant.expiresAt == Self.issuedAt.addingTimeInterval(Self.lifetime))
        #expect(
            await composition.ledger.isAuthorizationActive(
                sourceID: grant.sourceID,
                profileID: grant.profileID,
                revocationEpoch: grant.revocationEpoch
            )
        )

        let snapshot = await composition.authorizationSnapshot()
        #expect(snapshot.readGrants == [grant])
        #expect(
            ExternalSessionAuthorizationLedgerView.readGrantStatus(
                grant,
                in: snapshot,
                now: Self.issuedAt
            ) == .active
        )
    }

    @Test func unsupervisedSourceIsRefusedAndRecordsNothing() async {
        let composition = makeComposition()
        await #expect(throws: ExternalSessionAppAdapterError.sourceMismatch) {
            try await composition.issueReadGrant(
                authorizationID: ExternalSessionAuthorizationID(rawValue: "read-x"),
                sourceID: unknownSourceID,
                profileID: profileID,
                target: .source(unknownSourceID),
                scopes: [.messages],
                issuedAt: Self.issuedAt,
                lifetime: Self.lifetime
            )
        }
        #expect(await composition.authorizationSnapshot() == .empty)
        #expect(
            !(await composition.ledger.isAuthorizationActive(
                sourceID: unknownSourceID,
                profileID: profileID,
                revocationEpoch: 0
            ))
        )
    }

    @Test func displayStatusDerivationCoversActiveRevokedExpiredAndUnlisted() {
        let grant = ExternalSessionReadGrantV1(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "read-1"),
            sourceID: sourceID,
            profileID: profileID,
            target: .thread(threadID),
            scopes: [.messages],
            issuedAt: Self.issuedAt,
            expiresAt: Self.issuedAt.addingTimeInterval(Self.lifetime),
            revocationEpoch: 0
        )
        func snapshot(pairEpoch: UInt64?) -> ExternalSessionAuthorizationSnapshotV1 {
            ExternalSessionAuthorizationSnapshotV1(
                authorizedPairs: pairEpoch.map {
                    [.init(sourceID: sourceID, profileID: profileID, revocationEpoch: $0)]
                } ?? [],
                readGrants: [grant],
                controlGrants: []
            )
        }
        #expect(
            ExternalSessionAuthorizationLedgerView.readGrantStatus(
                grant, in: snapshot(pairEpoch: 0), now: Self.issuedAt
            ) == .active
        )
        #expect(
            ExternalSessionAuthorizationLedgerView.readGrantStatus(
                grant, in: snapshot(pairEpoch: 0),
                now: Self.issuedAt.addingTimeInterval(Self.lifetime)
            ) == .expired
        )
        #expect(
            ExternalSessionAuthorizationLedgerView.readGrantStatus(
                grant, in: snapshot(pairEpoch: 1), now: Self.issuedAt
            ) == .revoked
        )
        // Never-issued pair: display agrees with the ledger's fail-closed rule.
        #expect(
            ExternalSessionAuthorizationLedgerView.readGrantStatus(
                grant, in: snapshot(pairEpoch: nil), now: Self.issuedAt
            ) == .revoked
        )
    }
}
