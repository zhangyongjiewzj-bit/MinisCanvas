import Foundation
import Testing
@testable import MinisCore

/// 077-A 差额面⑤（DEV-326）：`authorizationSnapshot()` 是纯枚举——它把台账
/// 已签发事实（(source, profile) 对、当前 epoch、mint 成功的 grant 本体）
/// 如实列出，同时不改变任何 fail-closed 活动性语义。执法/epoch 合同测试
/// （ExternalSessionAuthorizationLedgerTests / Revocation066Tests 等）保持
/// 原样不改，本文件只补 snapshot 侧缺口。
@Suite("External-session authorization ledger snapshot enumeration")
struct ExternalSessionAuthorizationLedgerSnapshot326Tests {
    private let sourceID = ExternalSessionSourceID(rawValue: "codex-local")
    private let otherSourceID = ExternalSessionSourceID(rawValue: "claude-local")
    private let profileID = ExternalSessionProfileID(rawValue: "profile-a")
    private let threadID = ExternalSessionThreadID(rawValue: "thread-1")

    @Test func freshLedgerSnapshotsEmpty() async {
        let ledger = ExternalSessionAuthorizationLedgerV1()
        let snapshot = await ledger.authorizationSnapshot()
        #expect(snapshot == .empty)
        #expect(snapshot.authorizedPairs.isEmpty)
        #expect(snapshot.readGrants.isEmpty)
        #expect(snapshot.controlGrants.isEmpty)
    }

    @Test func snapshotEnumeratesIssuedPairsAndGrantsInStableOrder() async throws {
        let ledger = ExternalSessionAuthorizationLedgerV1()
        let first = try await ledger.issueReadGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "read-1"),
            sourceID: sourceID,
            profileID: profileID,
            target: .thread(threadID),
            scopes: [.metadata, .messages],
            issuedAt: Date(timeIntervalSince1970: 100),
            lifetime: 200
        )
        let control = try await ledger.issueControlGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "control-1"),
            sourceID: sourceID,
            profileID: profileID,
            target: .thread(threadID),
            operations: [.steer],
            issuedAt: Date(timeIntervalSince1970: 100),
            lifetime: 200
        )

        var snapshot = await ledger.authorizationSnapshot()
        #expect(snapshot.authorizedPairs == [
            .init(sourceID: sourceID, profileID: profileID, revocationEpoch: 0)
        ])
        #expect(snapshot.readGrants == [first])
        #expect(snapshot.controlGrants == [control])
        #expect(snapshot.currentEpoch(sourceID: sourceID, profileID: profileID) == 0)
        #expect(snapshot.currentEpoch(sourceID: otherSourceID, profileID: profileID) == nil)

        // Second issuance on the same pair adds a grant row, never a pair row,
        // and ordering is stable by (issuedAt, authorizationID).
        _ = try await ledger.issueReadGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "read-0"),
            sourceID: sourceID,
            profileID: profileID,
            target: .source(sourceID),
            scopes: [.status],
            issuedAt: Date(timeIntervalSince1970: 100),
            lifetime: 50
        )
        snapshot = await ledger.authorizationSnapshot()
        #expect(snapshot.authorizedPairs.count == 1)
        #expect(
            snapshot.readGrants.map(\.authorizationID.rawValue) == ["read-0", "read-1"]
        )
    }

    @Test func snapshotEnumerationNeverChangesActivitySemantics() async throws {
        let ledger = ExternalSessionAuthorizationLedgerV1()
        let grant = try await ledger.issueReadGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "read-1"),
            sourceID: sourceID,
            profileID: profileID,
            target: .thread(threadID),
            scopes: [.messages],
            issuedAt: Date(timeIntervalSince1970: 100),
            lifetime: 200
        )

        let first = await ledger.authorizationSnapshot()
        let repeated = await ledger.authorizationSnapshot()
        #expect(first == repeated)

        // Enumerating twice moved no epoch and changed no activity verdict.
        #expect(await ledger.revocationEpoch(sourceID: sourceID, profileID: profileID) == 0)
        #expect(
            await ledger.isAuthorizationActive(
                sourceID: sourceID,
                profileID: profileID,
                revocationEpoch: grant.revocationEpoch
            )
        )
        // A never-issued pair stays inactive and unlisted after enumeration.
        #expect(
            !(await ledger.isAuthorizationActive(
                sourceID: otherSourceID,
                profileID: profileID,
                revocationEpoch: 0
            ))
        )
        #expect(repeated.currentEpoch(sourceID: otherSourceID, profileID: profileID) == nil)
    }

    @Test func refusedMintsRecordNothingInSnapshot() async throws {
        let ledger = ExternalSessionAuthorizationLedgerV1()

        await #expect(throws: ExternalSessionAuthorizationLedgerV1.LedgerError.emptyScopes) {
            try await ledger.issueReadGrant(
                authorizationID: ExternalSessionAuthorizationID(rawValue: "empty-scopes"),
                sourceID: sourceID,
                profileID: profileID,
                target: .thread(threadID),
                scopes: [],
                issuedAt: Date(timeIntervalSince1970: 100),
                lifetime: 200
            )
        }
        await #expect(throws: ExternalSessionAuthorizationLedgerV1.LedgerError.nonPositiveLifetime(0)) {
            try await ledger.issueReadGrant(
                authorizationID: ExternalSessionAuthorizationID(rawValue: "bad-lifetime"),
                sourceID: sourceID,
                profileID: profileID,
                target: .thread(threadID),
                scopes: [.messages],
                issuedAt: Date(timeIntervalSince1970: 100),
                lifetime: 0
            )
        }
        #expect(await ledger.authorizationSnapshot() == .empty)

        let grant = try await ledger.issueReadGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "read-1"),
            sourceID: sourceID,
            profileID: profileID,
            target: .thread(threadID),
            scopes: [.messages],
            issuedAt: Date(timeIntervalSince1970: 100),
            lifetime: 200
        )
        await #expect(
            throws: ExternalSessionAuthorizationLedgerV1.LedgerError.replayedAuthorizationID("read-1")
        ) {
            try await ledger.issueReadGrant(
                authorizationID: ExternalSessionAuthorizationID(rawValue: "read-1"),
                sourceID: sourceID,
                profileID: profileID,
                target: .source(sourceID),
                scopes: [.metadata],
                issuedAt: Date(timeIntervalSince1970: 120),
                lifetime: 200
            )
        }

        // Only the successful mint is listed, and it is listed unchanged:
        // the refused replay neither added a row nor rewrote the original.
        let snapshot = await ledger.authorizationSnapshot()
        #expect(snapshot.readGrants == [grant])
        #expect(snapshot.authorizedPairs.count == 1)
    }

    @Test func revokedPairStaysListedWithAdvancedEpochAndStaleGrantStamp() async throws {
        let ledger = ExternalSessionAuthorizationLedgerV1()
        let grant = try await ledger.issueReadGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "read-1"),
            sourceID: sourceID,
            profileID: profileID,
            target: .thread(threadID),
            scopes: [.messages],
            issuedAt: Date(timeIntervalSince1970: 100),
            lifetime: 200
        )
        let nextEpoch = await ledger.revoke(sourceID: sourceID, profileID: profileID)

        let snapshot = await ledger.authorizationSnapshot()
        #expect(snapshot.authorizedPairs == [
            .init(sourceID: sourceID, profileID: profileID, revocationEpoch: nextEpoch)
        ])
        // The historical grant keeps its stamped epoch; display derivation
        // (stamped != current) is what surfaces 「已撤销」, never enforcement.
        #expect(snapshot.readGrants == [grant])
        #expect(grant.revocationEpoch == 0)
        #expect(nextEpoch == 1)
        #expect(
            !(await ledger.isAuthorizationActive(
                sourceID: sourceID,
                profileID: profileID,
                revocationEpoch: grant.revocationEpoch
            ))
        )
    }
}
