import Foundation

/// Issuance, revocation and enforcement for `ExternalSessionContractV1` grants.
///
/// The contract carries a `revocationEpoch` on every read/control grant, but a
/// grant is a plain value: without a single authority for the current epoch,
/// revoking a user's external-session authorization would change nothing and
/// an already-issued grant could keep reading another session's transcript
/// after revocation. This actor is that authority:
///
/// - `issueReadGrant` / `issueControlGrant` stamp the current epoch so the
///   composition root never hand-assembles grant values, and register the
///   `(sourceID, profileID)` pair as one this ledger has authorized.
/// - `revoke` advances the epoch for one `(sourceID, profileID)` pair. Every
///   previously issued grant for that pair then fails the strict-equality
///   check in `isAuthorizationActive`, at admission and again after any await.
/// - Epochs are compared with exact equality, so a forged future epoch is
///   rejected the same way a stale one is.
/// - Revocation is scoped: it never affects a different source or profile,
///   which keeps cross-session/cross-profile isolation intact.
/// - Activity is also scoped: a pair this ledger never issued a grant for is
///   never active, even at epoch zero. Without a positive issuance record,
///   a mismatched (sourceID, profileID) combination built from components
///   of other authorizations would fail *open* through the epoch-zero
///   default, letting one pair's authorization be honored against another
///   source/profile combination.
///
/// Instances are owned by the composition root. There is no process-wide
/// shared instance, and nothing here persists credentials or session content.
public actor ExternalSessionAuthorizationLedgerV1 {
    public enum LedgerError: Error, Equatable, Sendable {
        case invalidAuthorizationID(String)
        case replayedAuthorizationID(String)
        case emptyScopes
        case emptyOperations
        case nonPositiveLifetime(TimeInterval)
    }

    private struct SourceProfileKey: Hashable {
        let sourceID: String
        let profileID: String
    }

    /// Bounded replay-prevention memory, matching the pruning convention of
    /// the process-local cross-session read ledger.
    private static let maximumTrackedAuthorizations = 4_096

    private var epochByKey: [SourceProfileKey: UInt64] = [:]
    /// Pairs with at least one successful issuance through this ledger. Only
    /// registered pairs can ever be reported active; un-issued pairs stay
    /// closed regardless of their epoch.
    private var authorizedPairs: Set<SourceProfileKey> = []
    private var issuedAuthorizationIDs: Set<String> = []
    private var issuanceOrder: [String] = []

    /// Successful read/control mints, keyed by authorization ID, kept only so
    /// `authorizationSnapshot()` can enumerate what was issued (077-A ledger
    /// display). Values are the same contract structs returned to the caller:
    /// stable identities, scope enums and dates — never credentials or
    /// session content. Pruned together with `issuedAuthorizationIDs` at the
    /// same tracked-authorization bound, so this stays memory-bounded.
    private var readGrantRecords: [String: ExternalSessionReadGrantV1] = [:]
    private var controlGrantRecords: [String: ExternalSessionControlGrantV1] = [:]

    public init() {}

    private static func pairKey(
        sourceID: ExternalSessionSourceID,
        profileID: ExternalSessionProfileID
    ) -> SourceProfileKey {
        SourceProfileKey(sourceID: sourceID.rawValue, profileID: profileID.rawValue)
    }

    /// Current revocation epoch for one source/profile pair. Un-revoked pairs
    /// start at zero, which is also the epoch stamped on freshly issued grants.
    public func revocationEpoch(
        sourceID: ExternalSessionSourceID,
        profileID: ExternalSessionProfileID
    ) -> UInt64 {
        epochByKey[Self.pairKey(sourceID: sourceID, profileID: profileID), default: 0]
    }

    /// Pair-scoped activity check: a grant is active only while its stamped
    /// epoch equals the current epoch for that exact source/profile pair AND
    /// that exact pair was authorized by an issuance through this ledger.
    /// A never-issued combination (e.g. one source with another profile) is
    /// never active, so revoking one pair can neither disable nor activate
    /// any other pair.
    public func isAuthorizationActive(
        sourceID: ExternalSessionSourceID,
        profileID: ExternalSessionProfileID,
        revocationEpoch epoch: UInt64
    ) -> Bool {
        let key = Self.pairKey(sourceID: sourceID, profileID: profileID)
        return authorizedPairs.contains(key) && epoch == (epochByKey[key] ?? 0)
    }

    /// Invalidates every previously issued grant for one source/profile pair
    /// and returns the new epoch. Other pairs are untouched (fail-closed for
    /// the revoked pair only; never a cross-profile side effect).
    @discardableResult
    public func revoke(
        sourceID: ExternalSessionSourceID,
        profileID: ExternalSessionProfileID
    ) -> UInt64 {
        let key = Self.pairKey(sourceID: sourceID, profileID: profileID)
        let next = (epochByKey[key] ?? 0) &+ 1
        epochByKey[key] = next
        return next
    }

    public func issueReadGrant(
        authorizationID: ExternalSessionAuthorizationID,
        sourceID: ExternalSessionSourceID,
        profileID: ExternalSessionProfileID,
        target: ExternalSessionReadTargetV1,
        scopes: Set<ExternalSessionReadScopeV1>,
        issuedAt: Date = Date(),
        lifetime: TimeInterval,
        parentConversationID: String? = nil,
        parentTurnID: String? = nil
    ) throws -> ExternalSessionReadGrantV1 {
        try reserveAuthorizationID(authorizationID)
        guard !scopes.isEmpty else { throw LedgerError.emptyScopes }
        guard lifetime > 0, lifetime.isFinite else {
            throw LedgerError.nonPositiveLifetime(lifetime)
        }
        registerAuthorizedPair(sourceID: sourceID, profileID: profileID)
        let grant = ExternalSessionReadGrantV1(
            authorizationID: authorizationID,
            sourceID: sourceID,
            profileID: profileID,
            target: target,
            scopes: scopes,
            issuedAt: issuedAt,
            expiresAt: issuedAt.addingTimeInterval(lifetime),
            revocationEpoch: revocationEpoch(sourceID: sourceID, profileID: profileID),
            parentConversationID: parentConversationID,
            parentTurnID: parentTurnID
        )
        readGrantRecords[authorizationID.rawValue] = grant
        return grant
    }

    public func issueControlGrant(
        authorizationID: ExternalSessionAuthorizationID,
        sourceID: ExternalSessionSourceID,
        profileID: ExternalSessionProfileID,
        target: ExternalSessionControlTargetV1,
        operations: Set<ExternalSessionControlOperationV1>,
        issuedAt: Date = Date(),
        lifetime: TimeInterval,
        parentConversationID: String? = nil,
        parentTurnID: String? = nil
    ) throws -> ExternalSessionControlGrantV1 {
        try reserveAuthorizationID(authorizationID)
        guard !operations.isEmpty else { throw LedgerError.emptyOperations }
        guard lifetime > 0, lifetime.isFinite else {
            throw LedgerError.nonPositiveLifetime(lifetime)
        }
        registerAuthorizedPair(sourceID: sourceID, profileID: profileID)
        let grant = ExternalSessionControlGrantV1(
            authorizationID: authorizationID,
            sourceID: sourceID,
            profileID: profileID,
            target: target,
            operations: operations,
            issuedAt: issuedAt,
            expiresAt: issuedAt.addingTimeInterval(lifetime),
            revocationEpoch: revocationEpoch(sourceID: sourceID, profileID: profileID),
            parentConversationID: parentConversationID,
            parentTurnID: parentTurnID
        )
        controlGrantRecords[authorizationID.rawValue] = grant
        return grant
    }

    /// Read-only enumeration of this ledger's current authorization state for
    /// the 077-A ledger display surface: authorized `(sourceID, profileID)`
    /// pairs with their current epochs, and every grant this ledger minted
    /// (target, scopes/operations, issued/expiry timestamps, stamped epoch).
    ///
    /// This is pure enumeration. It decides nothing: `isAuthorizationActive`
    /// stays the single activity authority, a pair listed here is still
    /// inactive after its epoch moved on, and calling this function changes
    /// no state. Records only ever enter through the successful issuance
    /// paths in `issueReadGrant` / `issueControlGrant`, so a refused mint
    /// (empty scopes, replayed ID, invalid lifetime) never shows up here.
    public func authorizationSnapshot() -> ExternalSessionAuthorizationSnapshotV1 {
        let pairEntries = authorizedPairs
            .sorted {
                if $0.sourceID != $1.sourceID { return $0.sourceID < $1.sourceID }
                return $0.profileID < $1.profileID
            }
            .map { key in
                ExternalSessionAuthorizationSnapshotV1.AuthorizedPairEntry(
                    sourceID: ExternalSessionSourceID(rawValue: key.sourceID),
                    profileID: ExternalSessionProfileID(rawValue: key.profileID),
                    revocationEpoch: epochByKey[key] ?? 0
                )
            }
        let readEntries = readGrantRecords.values.sorted {
            if $0.issuedAt != $1.issuedAt { return $0.issuedAt < $1.issuedAt }
            return $0.authorizationID.rawValue < $1.authorizationID.rawValue
        }
        let controlEntries = controlGrantRecords.values.sorted {
            if $0.issuedAt != $1.issuedAt { return $0.issuedAt < $1.issuedAt }
            return $0.authorizationID.rawValue < $1.authorizationID.rawValue
        }
        return ExternalSessionAuthorizationSnapshotV1(
            authorizedPairs: pairEntries,
            readGrants: readEntries,
            controlGrants: controlEntries
        )
    }

    private func registerAuthorizedPair(
        sourceID: ExternalSessionSourceID,
        profileID: ExternalSessionProfileID
    ) {
        authorizedPairs.insert(Self.pairKey(sourceID: sourceID, profileID: profileID))
    }

    private func reserveAuthorizationID(_ authorizationID: ExternalSessionAuthorizationID) throws {
        let rawValue = authorizationID.rawValue
        guard !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LedgerError.invalidAuthorizationID(rawValue)
        }
        guard issuedAuthorizationIDs.insert(rawValue).inserted else {
            throw LedgerError.replayedAuthorizationID(rawValue)
        }
        issuanceOrder.append(rawValue)
        if issuanceOrder.count > Self.maximumTrackedAuthorizations,
           let retired = issuanceOrder.first {
            issuanceOrder.removeFirst()
            issuedAuthorizationIDs.remove(retired)
            readGrantRecords.removeValue(forKey: retired)
            controlGrantRecords.removeValue(forKey: retired)
        }
    }
}

/// Deterministic, value-only view of one ledger's authorization state,
/// produced by `ExternalSessionAuthorizationLedgerV1.authorizationSnapshot()`.
///
/// The display layer derives per-grant status text from these entries (pair
/// epoch vs stamped epoch, expiry vs wall clock); that derivation is display
/// only and never feeds back into enforcement. Grants pruned from replay
/// tracking simply disappear from later snapshots — an accepted, bounded
/// display trade-off, not an authorization statement.
public struct ExternalSessionAuthorizationSnapshotV1: Equatable, Sendable {
    /// One `(source, profile)` pair this ledger has positively issued for,
    /// with its current revocation epoch. An epoch above the stamped epoch of
    /// a grant means every grant minted before the advance is inactive.
    public struct AuthorizedPairEntry: Equatable, Sendable {
        public let sourceID: ExternalSessionSourceID
        public let profileID: ExternalSessionProfileID
        public let revocationEpoch: UInt64

        public init(
            sourceID: ExternalSessionSourceID,
            profileID: ExternalSessionProfileID,
            revocationEpoch: UInt64
        ) {
            self.sourceID = sourceID
            self.profileID = profileID
            self.revocationEpoch = revocationEpoch
        }
    }

    public let authorizedPairs: [AuthorizedPairEntry]
    public let readGrants: [ExternalSessionReadGrantV1]
    public let controlGrants: [ExternalSessionControlGrantV1]

    public init(
        authorizedPairs: [AuthorizedPairEntry],
        readGrants: [ExternalSessionReadGrantV1],
        controlGrants: [ExternalSessionControlGrantV1]
    ) {
        self.authorizedPairs = authorizedPairs
        self.readGrants = readGrants
        self.controlGrants = controlGrants
    }

    /// Current epoch for one exact pair, or `nil` when this ledger never
    /// issued for it. Lookup helper for display derivation; it decides
    /// nothing and mirrors the ledger's pair-scoped activity rule.
    public func currentEpoch(
        sourceID: ExternalSessionSourceID,
        profileID: ExternalSessionProfileID
    ) -> UInt64? {
        authorizedPairs.first {
            $0.sourceID == sourceID && $0.profileID == profileID
        }?.revocationEpoch
    }

    public static let empty = ExternalSessionAuthorizationSnapshotV1(
        authorizedPairs: [],
        readGrants: [],
        controlGrants: []
    )
}
