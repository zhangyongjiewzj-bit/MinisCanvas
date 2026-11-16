import Foundation
import Testing
@testable import MinisCore

@Suite("External-session authorization ledger")
struct ExternalSessionAuthorizationLedgerTests {
    private let sourceID = ExternalSessionSourceID(rawValue: "codex-local")
    private let otherSourceID = ExternalSessionSourceID(rawValue: "claude-local")
    private let profileID = ExternalSessionProfileID(rawValue: "profile-a")
    private let otherProfileID = ExternalSessionProfileID(rawValue: "profile-b")
    private let threadID = ExternalSessionThreadID(rawValue: "thread-1")

    @Test func freshPairStartsAtZeroAndIssuedGrantsStampTheCurrentEpoch() async throws {
        let ledger = ExternalSessionAuthorizationLedgerV1()
        #expect(await ledger.revocationEpoch(sourceID: sourceID, profileID: profileID) == 0)

        let grant = try await ledger.issueReadGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "read-1"),
            sourceID: sourceID,
            profileID: profileID,
            target: .thread(threadID),
            scopes: [.messages],
            issuedAt: Date(timeIntervalSince1970: 100),
            lifetime: 200
        )
        #expect(grant.revocationEpoch == 0)
        #expect(grant.expiresAt == Date(timeIntervalSince1970: 300))
        #expect(grant.scopes == [.messages])
        #expect(
            await ledger.isAuthorizationActive(
                sourceID: sourceID,
                profileID: profileID,
                revocationEpoch: grant.revocationEpoch
            )
        )
    }

    @Test func revokeInvalidatesPreviouslyIssuedGrantsAndReissueRecovers() async throws {
        let ledger = ExternalSessionAuthorizationLedgerV1()
        let first = try await ledger.issueReadGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "read-1"),
            sourceID: sourceID,
            profileID: profileID,
            target: .thread(threadID),
            scopes: [.metadata],
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

        // Terminal: one revoke invalidates every prior grant for the pair.
        let newEpoch = await ledger.revoke(sourceID: sourceID, profileID: profileID)
        #expect(newEpoch == 1)
        #expect(
            !(await ledger.isAuthorizationActive(
                sourceID: sourceID,
                profileID: profileID,
                revocationEpoch: first.revocationEpoch
            ))
        )
        #expect(
            !(await ledger.isAuthorizationActive(
                sourceID: sourceID,
                profileID: profileID,
                revocationEpoch: control.revocationEpoch
            ))
        )

        // Non-terminal continuation: a grant issued after revocation is active.
        let second = try await ledger.issueReadGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "read-2"),
            sourceID: sourceID,
            profileID: profileID,
            target: .thread(threadID),
            scopes: [.metadata],
            issuedAt: Date(timeIntervalSince1970: 400),
            lifetime: 200
        )
        #expect(second.revocationEpoch == 1)
        #expect(
            await ledger.isAuthorizationActive(
                sourceID: sourceID,
                profileID: profileID,
                revocationEpoch: second.revocationEpoch
            )
        )
    }

    @Test func forgedFutureEpochIsRejectedLikeAStaleOne() async throws {
        let ledger = ExternalSessionAuthorizationLedgerV1()
        #expect(
            !(await ledger.isAuthorizationActive(
                sourceID: sourceID,
                profileID: profileID,
                revocationEpoch: 1
            ))
        )
        await ledger.revoke(sourceID: sourceID, profileID: profileID)
        #expect(
            !(await ledger.isAuthorizationActive(
                sourceID: sourceID,
                profileID: profileID,
                revocationEpoch: 99
            ))
        )
    }

    @Test func revocationIsScopedToOneSourceProfilePair() async throws {
        let ledger = ExternalSessionAuthorizationLedgerV1()
        let affected = try await ledger.issueReadGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "read-a"),
            sourceID: sourceID,
            profileID: profileID,
            target: .thread(threadID),
            scopes: [.messages],
            issuedAt: Date(timeIntervalSince1970: 100),
            lifetime: 200
        )
        let sameProfileOtherSource = try await ledger.issueReadGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "read-b"),
            sourceID: otherSourceID,
            profileID: profileID,
            target: .thread(threadID),
            scopes: [.messages],
            issuedAt: Date(timeIntervalSince1970: 100),
            lifetime: 200
        )
        let sameSourceOtherProfile = try await ledger.issueReadGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "read-c"),
            sourceID: sourceID,
            profileID: otherProfileID,
            target: .thread(threadID),
            scopes: [.messages],
            issuedAt: Date(timeIntervalSince1970: 100),
            lifetime: 200
        )
        await ledger.revoke(sourceID: sourceID, profileID: profileID)
        #expect(
            !(await ledger.isAuthorizationActive(
                sourceID: sourceID,
                profileID: profileID,
                revocationEpoch: affected.revocationEpoch
            ))
        )
        // One revoked user must not disable another source's or profile's
        // sessions, and must not activate a mismatched pair either.
        #expect(
            await ledger.isAuthorizationActive(
                sourceID: otherSourceID,
                profileID: profileID,
                revocationEpoch: sameProfileOtherSource.revocationEpoch
            )
        )
        #expect(
            await ledger.isAuthorizationActive(
                sourceID: sourceID,
                profileID: otherProfileID,
                revocationEpoch: sameSourceOtherProfile.revocationEpoch
            )
        )
        #expect(
            !(await ledger.isAuthorizationActive(
                sourceID: otherSourceID,
                profileID: otherProfileID,
                revocationEpoch: sameProfileOtherSource.revocationEpoch
            ))
        )
    }

    @Test func issuanceRejectsUnusableGrantsAndReplayedAuthorizationIDs() async {
        let ledger = ExternalSessionAuthorizationLedgerV1()
        await #expect(throws: ExternalSessionAuthorizationLedgerV1.LedgerError.emptyScopes) {
            _ = try await ledger.issueReadGrant(
                authorizationID: ExternalSessionAuthorizationID(rawValue: "read-1"),
                sourceID: sourceID,
                profileID: profileID,
                target: .thread(threadID),
                scopes: [],
                lifetime: 60
            )
        }
        await #expect(throws: ExternalSessionAuthorizationLedgerV1.LedgerError.emptyOperations) {
            _ = try await ledger.issueControlGrant(
                authorizationID: ExternalSessionAuthorizationID(rawValue: "control-1"),
                sourceID: sourceID,
                profileID: profileID,
                target: .thread(threadID),
                operations: [],
                lifetime: 60
            )
        }
        await #expect(
            throws: ExternalSessionAuthorizationLedgerV1.LedgerError.nonPositiveLifetime(0)
        ) {
            _ = try await ledger.issueReadGrant(
                authorizationID: ExternalSessionAuthorizationID(rawValue: "read-2"),
                sourceID: sourceID,
                profileID: profileID,
                target: .thread(threadID),
                scopes: [.metadata],
                lifetime: 0
            )
        }
        await #expect(
            throws: ExternalSessionAuthorizationLedgerV1.LedgerError.invalidAuthorizationID("   ")
        ) {
            _ = try await ledger.issueReadGrant(
                authorizationID: ExternalSessionAuthorizationID(rawValue: "   "),
                sourceID: sourceID,
                profileID: profileID,
                target: .thread(threadID),
                scopes: [.metadata],
                lifetime: 60
            )
        }
        _ = try? await ledger.issueReadGrant(
            authorizationID: ExternalSessionAuthorizationID(rawValue: "read-3"),
            sourceID: sourceID,
            profileID: profileID,
            target: .thread(threadID),
            scopes: [.metadata],
            lifetime: 60
        )
        await #expect(
            throws: ExternalSessionAuthorizationLedgerV1.LedgerError.replayedAuthorizationID("read-3")
        ) {
            _ = try await ledger.issueReadGrant(
                authorizationID: ExternalSessionAuthorizationID(rawValue: "read-3"),
                sourceID: sourceID,
                profileID: profileID,
                target: .thread(threadID),
                scopes: [.metadata],
                lifetime: 60
            )
        }
    }
}
