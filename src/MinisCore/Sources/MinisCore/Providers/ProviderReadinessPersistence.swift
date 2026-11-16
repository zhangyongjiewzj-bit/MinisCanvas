import CryptoKit
import Darwin
import Foundation

/// The durable status of a provider/model directory entry.
///
/// `discovered` is intentionally separate from `passed`: a catalog response
/// only tells us that an ID exists, not that a request can use it.
public enum ProviderReadinessPersistenceStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case discovered
    case passed
    case unverified
    case unavailable
}

/// Recovery outcome of the durable readiness snapshot.
public enum ProviderReadinessStoreRecoveryState: Equatable, Sendable {
    case missing
    case loaded(recordCount: Int)
    case recoveredPartial(validRecordCount: Int, droppedRecordCount: Int)
    /// The primary snapshot was truncated or from an unknown schema, so the
    /// last journaled commit is retained only as non-actionable pending data.
    case recoveredCommittedSnapshot(recordCount: Int)
    /// Primary and journal are individually valid but belong to different
    /// transactions. Neither side is selected by timestamp.
    case transactionIdentityMismatch
    /// The pair is valid but has no durable marker proving that both sides
    /// completed the same commit.
    case incompleteTransaction
    case quarantinedCorrupt

    public var isUsable: Bool {
        switch self {
        case .missing, .loaded, .recoveredPartial:
            true
        case .recoveredCommittedSnapshot, .transactionIdentityMismatch,
             .incompleteTransaction, .quarantinedCorrupt:
            false
        }
    }
}

/// Outcome of a reconnect observation at the durable readiness boundary.
///
/// A reconnect is allowed to replace an observation at the same timestamp
/// (the new transport attempt is the freshest evidence for that lifecycle),
/// but a late observation from an older check is ignored.  Invalid records and
/// persistence failures fail closed so a reconnect cannot manufacture a ready
/// provider from incomplete state.
public enum ProviderReadinessReconnectOutcome: String, Codable, Hashable, Sendable {
    case persisted
    case ignoredStale
    case rejectedInvalid
    case persistenceFailed
}

private struct ProviderReadinessPersistenceCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

/// Secret-free, Codable readiness facts for one provider/model pair.
///
/// This record deliberately has no URL, credential, raw response, or raw
/// error field. Identifiers and evidence are normalized and redacted before
/// they can reach durable storage.
public struct ProviderReadinessPersistenceRecord: Codable, Hashable, Sendable {
    public static let legacyConfigurationGeneration = "legacy"

    /// Runtime-only provenance used to detect untrusted aliases before the
    /// canonical provider identity erases their original spelling. It is
    /// deliberately omitted from CodingKeys and from value equality/hash.
    private struct ProjectionSourceIdentity: Hashable, Sendable {
        let providerID: String

        static func == (_: Self, _: Self) -> Bool { true }
        func hash(into _: inout Hasher) {}
    }

    private enum CodingKeys: String, CodingKey {
        case providerID
        case modelID
        case configurationGeneration
        case status
        case readinessState
        case checkedAt
        case errorCategory
        case latency
        case evidenceID
        case isApplied
        case discoveryReceiptID
        case discoveredAt
        case applyReceiptID
        case appliedAt
        case configurationFingerprint
        case expiresAt
    }

    fileprivate static let allowedCodingKeys: Set<String> = [
        "providerID", "modelID", "configurationGeneration", "status",
        "readinessState", "checkedAt", "errorCategory", "latency",
        "evidenceID", "isApplied", "discoveryReceiptID", "discoveredAt",
        "applyReceiptID", "appliedAt", "configurationFingerprint", "expiresAt"
    ]

    public let providerID: String
    public let modelID: String
    /// Secret-free provider configuration generation. It fences a persisted
    /// readiness result against a later credential/configuration identity.
    public let configurationGeneration: String
    public let status: ProviderReadinessPersistenceStatus
    public let readinessState: ProviderReadinessState
    public let checkedAt: Date
    public let errorCategory: ProviderReadinessFailureCategory?
    /// Round-trip latency in milliseconds.
    public let latency: Int?
    public let evidenceID: String?
    /// Discovered models remain false until the user explicitly applies them.
    public let isApplied: Bool
    public let discoveryReceiptID: String
    public let discoveredAt: Date
    public let applyReceiptID: String?
    public let appliedAt: Date?
    /// Opaque provider configuration identity; never a credential or URL.
    public let configurationFingerprint: String?
    /// Freshness boundary for cache consumers. Missing/invalid expiry is not
    /// treated as indefinitely fresh.
    public let expiresAt: Date?
    private var projectionSourceIdentity = ProjectionSourceIdentity(providerID: "")

    var projectionSourceProviderID: String {
        projectionSourceIdentity.providerID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let dynamicContainer = try decoder.container(
            keyedBy: ProviderReadinessPersistenceCodingKey.self
        )
        let allKeys = Set(dynamicContainer.allKeys.map(\.stringValue))
        guard allKeys.isSubset(of: Self.allowedCodingKeys) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unexpected persisted readiness record key"
            ))
        }
        let decodedGeneration = try container.decodeIfPresent(
            String.self,
            forKey: .configurationGeneration
        )
        let normalizedGeneration = decodedGeneration?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let decodedGeneration {
            guard let normalizedGeneration,
                  !normalizedGeneration.isEmpty,
                  decodedGeneration == normalizedGeneration else {
                throw DecodingError.dataCorruptedError(
                    forKey: .configurationGeneration,
                    in: container,
                    debugDescription: "configuration generation must be canonical"
                )
            }
        }
        // Records written before the generation fence did not carry a
        // configuration identity.  The regular initializer intentionally
        // synthesizes missing lineage receipts for new records, but doing
        // that while decoding an old snapshot would turn stale `isApplied`
        // state into a configured picker row.  Keep the record visible for
        // recovery, while making it explicitly unverified and pending until
        // a fresh generation is probed and explicitly applied.
        let isLegacySnapshotRecord = decodedGeneration == nil
        let decodedIsApplied = isLegacySnapshotRecord
            ? false
            : try container.decode(Bool.self, forKey: .isApplied)
        let rawApplyReceiptID = try container.decodeIfPresent(
            String.self,
            forKey: .applyReceiptID
        )
        let decodedDiscoveredAt = try container.decodeIfPresent(
            Date.self,
            forKey: .discoveredAt
        )
        let decodedAppliedAt = try container.decodeIfPresent(
            Date.self,
            forKey: .appliedAt
        )
        // Apply authority is a durable pair.  A snapshot that only says
        // `isApplied=true` is incomplete evidence; allowing the regular
        // initializer to synthesize a receipt/date here would make a
        // truncated or hand-edited snapshot actionable after reload.
        let applyTimelineIsValid: Bool
        if let decodedDiscoveredAt, let decodedAppliedAt {
            applyTimelineIsValid = decodedDiscoveredAt
                .timeIntervalSinceReferenceDate.isFinite
                && decodedAppliedAt.timeIntervalSinceReferenceDate.isFinite
                && decodedAppliedAt >= decodedDiscoveredAt
        } else {
            applyTimelineIsValid = false
        }
        let canRestoreApplied = decodedIsApplied
            && rawApplyReceiptID?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty == false
            && applyTimelineIsValid
        let rawProviderID = try container.decode(String.self, forKey: .providerID)
        let rawModelID = try container.decode(String.self, forKey: .modelID)
        guard rawProviderID == rawProviderID.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), rawModelID == rawModelID.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "provider and model identities must be canonical"
            ))
        }
        let rawDiscoveryReceiptID = try container.decodeIfPresent(
            String.self,
            forKey: .discoveryReceiptID
        )
        if let rawDiscoveryReceiptID {
            let normalized = rawDiscoveryReceiptID
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, rawDiscoveryReceiptID == normalized else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "discovery receipt must be canonical"
                ))
            }
        }
        if let rawApplyReceiptID {
            let normalized = rawApplyReceiptID
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, rawApplyReceiptID == normalized else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "apply receipt must be canonical"
                ))
            }
        }
        let rawConfigurationFingerprint = try container.decodeIfPresent(
            String.self,
            forKey: .configurationFingerprint
        )
        if let rawConfigurationFingerprint {
            guard rawConfigurationFingerprint == rawConfigurationFingerprint
                .trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "configuration fingerprint must be canonical"
                ))
            }
        }
        self.init(
            providerID: rawProviderID,
            modelID: rawModelID,
            configurationGeneration: normalizedGeneration
                ?? Self.legacyConfigurationGeneration,
            status: isLegacySnapshotRecord
                ? .unverified
                : try container.decode(
                    ProviderReadinessPersistenceStatus.self,
                    forKey: .status
                ),
            readinessState: isLegacySnapshotRecord
                ? .unverified
                : try container.decode(
                    ProviderReadinessState.self,
                    forKey: .readinessState
                ),
            checkedAt: try container.decode(Date.self, forKey: .checkedAt),
            errorCategory: isLegacySnapshotRecord
                ? .transport
                : try container.decodeIfPresent(
                    ProviderReadinessFailureCategory.self,
                    forKey: .errorCategory
                ),
            latency: try container.decodeIfPresent(Int.self, forKey: .latency),
            evidenceID: isLegacySnapshotRecord
                ? nil
                : try container.decodeIfPresent(String.self, forKey: .evidenceID),
            isApplied: canRestoreApplied,
            discoveryReceiptID: rawDiscoveryReceiptID,
            discoveredAt: decodedDiscoveredAt,
            applyReceiptID: canRestoreApplied ? rawApplyReceiptID : nil,
            appliedAt: canRestoreApplied ? decodedAppliedAt : nil,
            configurationFingerprint: rawConfigurationFingerprint,
            expiresAt: try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        )
    }

    public init(
        providerID: String,
        modelID: String,
        configurationGeneration: String = Self.legacyConfigurationGeneration,
        status: ProviderReadinessPersistenceStatus,
        readinessState: ProviderReadinessState,
        checkedAt: Date,
        errorCategory: ProviderReadinessFailureCategory? = nil,
        latency: Int? = nil,
        evidenceID: String? = nil,
        isApplied: Bool,
        discoveryReceiptID: String? = nil,
        discoveredAt: Date? = nil,
        applyReceiptID: String? = nil,
        appliedAt: Date? = nil,
        configurationFingerprint: String? = nil,
        expiresAt: Date? = nil
    ) {
        let redactedProviderID = ProviderReadinessPersistenceRedactor.redact(providerID)
        self.projectionSourceIdentity = ProjectionSourceIdentity(
            providerID: redactedProviderID
        )
        self.providerID = ProviderReadinessRevision.canonicalProviderID(redactedProviderID)
        self.modelID = ProviderReadinessPersistenceRedactor.redact(modelID)
        let normalizedGeneration = configurationGeneration
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.configurationGeneration = normalizedGeneration.isEmpty
            ? Self.legacyConfigurationGeneration
            : normalizedGeneration
        self.status = status
        self.readinessState = readinessState
        self.checkedAt = checkedAt
        self.errorCategory = errorCategory
        self.latency = latency.map { max(0, $0) }
        self.evidenceID = ProviderReadinessPersistenceRedactor.redactOptional(evidenceID)
        self.isApplied = isApplied
        let fallbackLineage = ProviderReadinessLineage.derived(
            providerID: self.providerID,
            modelID: self.modelID,
            checkedAt: checkedAt
        )
        let normalizedDiscoveryReceiptID = ProviderReadinessPersistenceRedactor
            .redactOptional(discoveryReceiptID)
        self.discoveryReceiptID = normalizedDiscoveryReceiptID
            ?? fallbackLineage.discoveryReceiptID
        self.discoveredAt = discoveredAt ?? checkedAt
        self.applyReceiptID = isApplied
            ? ProviderReadinessPersistenceRedactor.redactOptional(applyReceiptID)
                ?? "provider-readiness-apply:\(self.discoveryReceiptID)"
            : nil
        self.appliedAt = isApplied
            ? appliedAt ?? checkedAt
            : nil
        self.configurationFingerprint = ProviderReadinessPersistenceRedactor
            .redactOptional(configurationFingerprint)
        self.expiresAt = expiresAt
    }

    /// Returns this record only when its complete cache identity and expiry
    /// are current. Missing, malformed, expired, or drifted facts become
    /// explicit unverified state instead of reusing green.
    public func validatedForCache(
        configurationFingerprint expectedFingerprint: String,
        now: Date,
        configurationGeneration expectedGeneration: String = Self.legacyConfigurationGeneration
    ) -> Self {
        let expected = ProviderReadinessPersistenceRedactor.redact(expectedFingerprint)
        let normalizedGeneration = expectedGeneration
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let isFresh = !expected.isEmpty
            && configurationFingerprint == expected
            && !normalizedGeneration.isEmpty
            && configurationGeneration == normalizedGeneration
            && checkedAt.timeIntervalSinceReferenceDate.isFinite
            && now.timeIntervalSinceReferenceDate.isFinite
            && expiresAt?.timeIntervalSinceReferenceDate.isFinite == true
            && (expiresAt ?? .distantPast) > now
            && status == .passed
            && readinessState != .unverified
        return isFresh ? self : downgradedToUnverified()
    }

    /// Preserves identity/lineage while making invalidation explicit to
    /// picker consumers. Stale evidence is never left green.
    public func downgradedToUnverified() -> Self {
        preservingProjectionSourceIdentity(Self(
            providerID: providerID,
            modelID: modelID,
            configurationGeneration: configurationGeneration,
            status: .unverified,
            readinessState: .unverified,
            checkedAt: checkedAt,
            errorCategory: .transport,
            latency: latency,
            evidenceID: nil,
            isApplied: isApplied,
            discoveryReceiptID: discoveryReceiptID,
            discoveredAt: discoveredAt,
            applyReceiptID: applyReceiptID,
            appliedAt: appliedAt,
            configurationFingerprint: configurationFingerprint,
            expiresAt: expiresAt
        ))
    }

    /// Removes selection authority when the current provider configuration is
    /// disabled, absent, or has not completed a fresh readiness check.
    ///
    /// A stale Apply receipt is not configuration truth: retaining it would
    /// let a previously green snapshot look configured after a provider was
    /// disabled or removed. Keep the row for recovery, but clear every fact
    /// that can make the picker actionable.
    public func downgradedToPending() -> Self {
        preservingProjectionSourceIdentity(Self(
            providerID: providerID,
            modelID: modelID,
            configurationGeneration: configurationGeneration,
            status: .unverified,
            readinessState: .unverified,
            checkedAt: checkedAt,
            errorCategory: .transport,
            latency: latency,
            evidenceID: nil,
            isApplied: false,
            discoveryReceiptID: discoveryReceiptID,
            discoveredAt: discoveredAt,
            applyReceiptID: nil,
            appliedAt: nil,
            configurationFingerprint: configurationFingerprint,
            expiresAt: expiresAt
        ))
    }

    /// Applies the runtime enabled/configured/ready boundary to a durable
    /// fact. The boundary is intentionally explicit because persistence does
    /// not own provider configuration and cannot infer whether an identity is
    /// still present (including built-in providers).
    public func gatedForSelection(
        isEnabled: Bool,
        isConfigured: Bool,
        isReady: Bool
    ) -> Self {
        guard isEnabled && isConfigured && isReady else {
            return downgradedToPending()
        }
        return self
    }

    public init(
        readiness: ProviderReadiness,
        status: ProviderReadinessPersistenceStatus,
        latency: Int? = nil,
        isApplied: Bool,
        configurationGeneration: String = Self.legacyConfigurationGeneration
    ) {
        self.init(
            providerID: readiness.providerID,
            modelID: readiness.modelID,
            configurationGeneration: configurationGeneration,
            status: status,
            readinessState: readiness.state,
            checkedAt: readiness.checkedAt,
            errorCategory: readiness.errorCategory,
            latency: latency ?? readiness.latency,
            evidenceID: readiness.evidenceID,
            isApplied: isApplied,
            discoveryReceiptID: readiness.lineage.discoveryReceiptID,
            discoveredAt: readiness.lineage.discoveredAt,
            applyReceiptID: readiness.lineage.applyReceiptID,
            appliedAt: readiness.lineage.appliedAt
        )
    }

    fileprivate func applying(_ isApplied: Bool, at appliedAt: Date = Date()) -> Self {
        let nextLineage = lineage.applying(at: appliedAt)
        return preservingProjectionSourceIdentity(Self(
            providerID: providerID,
            modelID: modelID,
            configurationGeneration: configurationGeneration,
            status: status,
            readinessState: readinessState,
            checkedAt: checkedAt,
            errorCategory: errorCategory,
            latency: latency,
            evidenceID: evidenceID,
            isApplied: isApplied || self.isApplied,
            discoveryReceiptID: nextLineage.discoveryReceiptID,
            discoveredAt: nextLineage.discoveredAt,
            applyReceiptID: nextLineage.applyReceiptID,
            appliedAt: nextLineage.appliedAt,
            configurationFingerprint: configurationFingerprint,
            expiresAt: expiresAt
        ))
    }

    fileprivate func preservingLineage(from current: Self) -> Self {
        preservingProjectionSourceIdentity(Self(
            providerID: providerID,
            modelID: modelID,
            configurationGeneration: configurationGeneration,
            status: status,
            readinessState: readinessState,
            checkedAt: checkedAt,
            errorCategory: errorCategory,
            latency: latency,
            evidenceID: evidenceID,
            isApplied: true,
            discoveryReceiptID: current.discoveryReceiptID,
            discoveredAt: current.discoveredAt,
            applyReceiptID: current.applyReceiptID,
            appliedAt: current.appliedAt,
            configurationFingerprint: configurationFingerprint,
            expiresAt: expiresAt
        ))
    }

    private func preservingProjectionSourceIdentity(_ record: Self) -> Self {
        var record = record
        record.projectionSourceIdentity = projectionSourceIdentity
        return record
    }

    public var lineage: ProviderReadinessLineage {
        ProviderReadinessLineage(
            discoveryReceiptID: discoveryReceiptID,
            discoveredAt: discoveredAt,
            applyReceiptID: applyReceiptID,
            appliedAt: appliedAt
        )
    }

    fileprivate var key: ProviderReadinessPersistenceKey {
        ProviderReadinessPersistenceKey(
            providerID: providerID,
            modelID: modelID,
            configurationGeneration: configurationGeneration
        )
    }

    fileprivate var isValid: Bool {
        !providerID.isEmpty
            && !modelID.isEmpty
            && !configurationGeneration.isEmpty
            && checkedAt.timeIntervalSinceReferenceDate.isFinite
            && discoveredAt.timeIntervalSinceReferenceDate.isFinite
            && appliedAt?.timeIntervalSinceReferenceDate.isFinite != false
            && expiresAt?.timeIntervalSinceReferenceDate.isFinite != false
            && (!isApplied || (
                applyReceiptID?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty == false
                && appliedAt.map { $0 >= discoveredAt } == true
            ))
    }
}

/// Converts a readiness report into records without persisting raw transport
/// details or credentials.
public extension ProviderReadinessPersistenceRecord {
    static func records(
        from report: ProviderReadinessCheckReport,
        latency: Int? = nil,
        appliedModelIDs: Set<String> = [],
        configurationGeneration: String? = nil,
        isEnabled: Bool = true,
        isConfigured: Bool = true,
        isReady: Bool = true
    ) -> [Self] {
        let canRestoreSelection = isEnabled && isConfigured && isReady
        let discoveredRecords = report.discoveredModels.map { model in
            let result = report.modelResults[model.id]
            let status: ProviderReadinessPersistenceStatus
            switch result?.status {
            case .passed:
                status = .passed
            case .failed:
                status = .unavailable
            case nil:
                status = .discovered
            }

            let failureCategory = result?.failureCategory
            let evidenceID = status == .passed ? report.readiness.evidenceID : nil
            let record = Self(
                providerID: report.readiness.providerID,
                modelID: model.id,
                configurationGeneration: configurationGeneration
                    ?? report.configurationGeneration,
                status: status,
                readinessState: report.readiness.state,
                checkedAt: report.readiness.checkedAt,
                errorCategory: failureCategory,
                latency: latency,
                evidenceID: evidenceID,
                isApplied: canRestoreSelection && appliedModelIDs.contains(model.id),
                discoveryReceiptID: report.readiness.lineage.discoveryReceiptID,
                discoveredAt: report.readiness.lineage.discoveredAt,
                applyReceiptID: report.readiness.lineage.applyReceiptID,
                appliedAt: report.readiness.lineage.appliedAt,
                configurationFingerprint: report.configurationFingerprint,
                expiresAt: report.expiresAt
            )
            return canRestoreSelection ? record : record.downgradedToPending()
        }

        guard !discoveredRecords.isEmpty else {
            let status: ProviderReadinessPersistenceStatus
            switch report.readiness.state {
            case .blocked:
                status = .unavailable
            case .unverified:
                status = .unverified
            case .mock, .local, .live, .beta:
                status = .passed
            }
            let failureCategory = report.stageResults.last(where: {
                $0.status == .failed
            })?.failureCategory
            let record = Self(
                    providerID: report.readiness.providerID,
                    modelID: report.readiness.modelID,
                    configurationGeneration: configurationGeneration
                        ?? report.configurationGeneration,
                    status: status,
                    readinessState: report.readiness.state,
                    checkedAt: report.readiness.checkedAt,
                    errorCategory: failureCategory,
                    latency: latency,
                    evidenceID: status == .passed
                        ? report.readiness.evidenceID
                        : nil,
                    isApplied: canRestoreSelection
                        && appliedModelIDs.contains(report.readiness.modelID),
                    discoveryReceiptID: report.readiness.lineage.discoveryReceiptID,
                    discoveredAt: report.readiness.lineage.discoveredAt,
                    applyReceiptID: report.readiness.lineage.applyReceiptID,
                    appliedAt: report.readiness.lineage.appliedAt,
                    configurationFingerprint: report.configurationFingerprint,
                    expiresAt: report.expiresAt
                )
            return [canRestoreSelection ? record : record.downgradedToPending()]
        }
        return discoveredRecords
    }
}

/// A small file-backed readiness fact store.
///
/// Writes are atomic and keyed by provider/model. A late result cannot replace
/// a newer result, and an existing applied model cannot be silently un-applied
/// by a refresh.
public final class ProviderReadinessStore: @unchecked Sendable {
    public static let fileName = "provider-readiness.json"
    /// Journal containing the latest complete snapshot. It is a recovery
    /// source only; records restored from it remain pending until a fresh
    /// readiness probe and explicit apply establish current authority.
    public static let journalFileName = "provider-readiness.json.journal"
    /// Durable commit receipt written only after primary and journal agree.
    public static let commitMarkerFileName = "provider-readiness.json.commit"
    public static let schemaVersion = 1
    private static let maxSnapshotBytes = 4 * 1024 * 1024
    /// Bound the complete three-artifact commit, not only each individual
    /// file.  Two copies of one snapshot plus its marker must fit before any
    /// replacement starts, so a partial oversized transaction cannot publish.
    private static let maxTransactionBytes = 4 * 1024 * 1024
    private static let maxSnapshotRecords = 4_096
    private static let maxPersistedJSONDepth = 32
    private static let maxPersistedObjectKeys = 32
    private static let maxPersistedStringBytes = 64 * 1024
    private static let providerScopeVersion = 1
    /// The v1 projection has no prior on-disk projection to migrate from.
    /// Persist the receipt explicitly so a future reader cannot infer a
    /// migration from an untrusted version number or silently rewrite bytes.
    private static let providerScopeMigrationReceipt = "provider-scope-v1-native"
    private static let providerScopeMigrationID = "00000000-0000-4000-8000-000000000001"
    private static let providerScopeMigrationEpoch: UInt64 = 1
    /// A cleanup receipt makes history pruning an explicit durable event.
    /// v1 retains its sole native entry, so this tombstone records that no
    /// unproven cleanup or resurrection may be inferred on reload.
    private static let providerScopeMigrationCleanupTombstone = "provider-scope-v1-history-retained"
    /// A future epoch may only compact history when it carries the exact
    /// predecessor root. v1 has no predecessor, so any non-nil root is
    /// evidence of an unverified rollover and must remain non-actionable.
    private static let providerScopeMigrationPreviousRoot: String? = nil
    private static let maxProviderScopeMigrationHistory = 8
    // Coordinate writers from separate store instances.  The instance lock
    // protects one store, but cannot prevent a stale second instance from
    // replacing a newer snapshot.
    private static let fileCoordinationLock = NSLock()

    private struct ProviderScopeMigrationHistoryEntry: Codable, Equatable {
        let migrationID: String
        let fromVersion: Int
        let toVersion: Int
        let previousVersionDigest: String?

        private enum CodingKeys: String, CodingKey {
            case migrationID
            case fromVersion
            case toVersion
            case previousVersionDigest
        }

        init(
            migrationID: String,
            fromVersion: Int,
            toVersion: Int,
            previousVersionDigest: String?
        ) {
            self.migrationID = migrationID
            self.fromVersion = fromVersion
            self.toVersion = toVersion
            self.previousVersionDigest = previousVersionDigest
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let dynamicContainer = try decoder.container(
                keyedBy: ProviderReadinessPersistenceCodingKey.self
            )
            guard Set(dynamicContainer.allKeys.map(\.stringValue)) == [
                "migrationID", "fromVersion", "toVersion", "previousVersionDigest"
            ] else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unexpected provider scope migration history key"
                ))
            }
            migrationID = try container.decode(String.self, forKey: .migrationID)
            fromVersion = try container.decode(Int.self, forKey: .fromVersion)
            toVersion = try container.decode(Int.self, forKey: .toVersion)
            previousVersionDigest = try container.decodeIfPresent(
                String.self,
                forKey: .previousVersionDigest
            )
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(migrationID, forKey: .migrationID)
            try container.encode(fromVersion, forKey: .fromVersion)
            try container.encode(toVersion, forKey: .toVersion)
            try container.encode(previousVersionDigest, forKey: .previousVersionDigest)
        }
    }

    private struct ProviderScopeMigrationCheckpointPayload: Encodable {
        let epoch: UInt64
        let cleanupTombstone: String
        let previousRoot: String?
        let history: [ProviderScopeMigrationHistoryEntry]
    }

    private struct Snapshot: Codable {
        let schemaVersion: Int
        let transactionID: String?
        let commitGeneration: UInt64?
        let previousDigest: String?
        let providerScope: String?
        let providerScopeVersion: Int?
        let providerScopeMigrationReceipt: String?
        let providerScopePreviousVersionDigest: String?
        let providerScopeMigrationHistory: [ProviderScopeMigrationHistoryEntry]?
        let providerScopeMigrationCheckpoint: String?
        let providerScopeMigrationEpoch: UInt64?
        let providerScopeMigrationCleanupTombstone: String?
        let providerScopeMigrationPreviousRoot: String?
        let payloadDigest: String?
        let records: [ProviderReadinessPersistenceRecord]

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case transactionID
            case commitGeneration
            case previousDigest
            case providerScope
            case providerScopeVersion
            case providerScopeMigrationReceipt
            case providerScopePreviousVersionDigest
            case providerScopeMigrationHistory
            case providerScopeMigrationCheckpoint
            case providerScopeMigrationEpoch
            case providerScopeMigrationCleanupTombstone
            case providerScopeMigrationPreviousRoot
            case payloadDigest
            case records
        }

        init(
            schemaVersion: Int,
            transactionID: String?,
            commitGeneration: UInt64?,
            previousDigest: String?,
            providerScope: String?,
            providerScopeVersion: Int?,
            providerScopeMigrationReceipt: String?,
            providerScopePreviousVersionDigest: String?,
            providerScopeMigrationHistory: [ProviderScopeMigrationHistoryEntry]?,
            providerScopeMigrationCheckpoint: String?,
            providerScopeMigrationEpoch: UInt64?,
            providerScopeMigrationCleanupTombstone: String?,
            providerScopeMigrationPreviousRoot: String?,
            payloadDigest: String?,
            records: [ProviderReadinessPersistenceRecord]
        ) {
            self.schemaVersion = schemaVersion
            self.transactionID = transactionID
            self.commitGeneration = commitGeneration
            self.previousDigest = previousDigest
            self.providerScope = providerScope
            self.providerScopeVersion = providerScopeVersion
            self.providerScopeMigrationReceipt = providerScopeMigrationReceipt
            self.providerScopePreviousVersionDigest = providerScopePreviousVersionDigest
            self.providerScopeMigrationHistory = providerScopeMigrationHistory
            self.providerScopeMigrationCheckpoint = providerScopeMigrationCheckpoint
            self.providerScopeMigrationEpoch = providerScopeMigrationEpoch
            self.providerScopeMigrationCleanupTombstone = providerScopeMigrationCleanupTombstone
            self.providerScopeMigrationPreviousRoot = providerScopeMigrationPreviousRoot
            self.payloadDigest = payloadDigest
            self.records = records
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let dynamicContainer = try decoder.container(
                keyedBy: ProviderReadinessPersistenceCodingKey.self
            )
            let keys = Set(dynamicContainer.allKeys.map(\.stringValue))
            guard keys == ["schemaVersion", "records"]
                    || keys == ["schemaVersion", "transactionID", "records"]
                    || keys == ["schemaVersion", "transactionID", "commitGeneration", "records"]
                    || keys == ["schemaVersion", "transactionID", "commitGeneration", "payloadDigest", "records"]
                    || keys == ["schemaVersion", "transactionID", "commitGeneration", "previousDigest", "payloadDigest", "records"]
                    || keys == ["schemaVersion", "transactionID", "commitGeneration", "previousDigest", "providerScope", "providerScopeVersion", "providerScopeMigrationReceipt", "providerScopePreviousVersionDigest", "providerScopeMigrationHistory", "providerScopeMigrationCheckpoint", "providerScopeMigrationEpoch", "providerScopeMigrationCleanupTombstone", "payloadDigest", "records"]
                    || keys == ["schemaVersion", "transactionID", "commitGeneration", "previousDigest", "providerScope", "providerScopeVersion", "providerScopeMigrationReceipt", "providerScopePreviousVersionDigest", "providerScopeMigrationHistory", "providerScopeMigrationCheckpoint", "providerScopeMigrationEpoch", "providerScopeMigrationCleanupTombstone", "providerScopeMigrationPreviousRoot", "payloadDigest", "records"] else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unexpected persisted readiness snapshot key"
                ))
            }
            schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            let rawTransactionID = try container.decodeIfPresent(
                String.self,
                forKey: .transactionID
            )
            let decodedTransactionID: String?
            if let rawTransactionID {
                let normalizedTransactionID = rawTransactionID
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedTransactionID.isEmpty,
                      rawTransactionID == normalizedTransactionID else {
                    throw DecodingError.dataCorrupted(.init(
                        codingPath: decoder.codingPath,
                        debugDescription: "transaction identity must be canonical"
                    ))
                }
                decodedTransactionID = normalizedTransactionID
            } else {
                decodedTransactionID = nil
            }
            transactionID = decodedTransactionID
            commitGeneration = try container.decodeIfPresent(
                UInt64.self,
                forKey: .commitGeneration
            )
            let hasTransactionID = keys.contains("transactionID")
            let hasCommitGeneration = keys.contains("commitGeneration")
            guard hasTransactionID == hasCommitGeneration,
                  !hasCommitGeneration || decodedTransactionID != nil else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "transaction identity and generation must be paired"
                ))
            }
            previousDigest = try container.decodeIfPresent(
                String.self,
                forKey: .previousDigest
            )
            providerScope = try container.decodeIfPresent(
                String.self,
                forKey: .providerScope
            )
            providerScopeVersion = try container.decodeIfPresent(
                Int.self,
                forKey: .providerScopeVersion
            )
            providerScopeMigrationReceipt = try container.decodeIfPresent(
                String.self,
                forKey: .providerScopeMigrationReceipt
            )
            providerScopePreviousVersionDigest = try container.decodeIfPresent(
                String.self,
                forKey: .providerScopePreviousVersionDigest
            )
            providerScopeMigrationHistory = try container.decodeIfPresent(
                [ProviderScopeMigrationHistoryEntry].self,
                forKey: .providerScopeMigrationHistory
            )
            providerScopeMigrationCheckpoint = try container.decodeIfPresent(
                String.self,
                forKey: .providerScopeMigrationCheckpoint
            )
            providerScopeMigrationEpoch = try container.decodeIfPresent(
                UInt64.self,
                forKey: .providerScopeMigrationEpoch
            )
            providerScopeMigrationCleanupTombstone = try container.decodeIfPresent(
                String.self,
                forKey: .providerScopeMigrationCleanupTombstone
            )
            providerScopeMigrationPreviousRoot = try container.decodeIfPresent(
                String.self,
                forKey: .providerScopeMigrationPreviousRoot
            )
            payloadDigest = try container.decodeIfPresent(
                String.self,
                forKey: .payloadDigest
            )
            records = try container.decode(
                [ProviderReadinessPersistenceRecord].self,
                forKey: .records
            )
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(schemaVersion, forKey: .schemaVersion)
            try container.encode(transactionID, forKey: .transactionID)
            try container.encode(commitGeneration, forKey: .commitGeneration)
            try container.encode(previousDigest, forKey: .previousDigest)
            try container.encode(providerScope, forKey: .providerScope)
            try container.encode(providerScopeVersion, forKey: .providerScopeVersion)
            try container.encode(providerScopeMigrationReceipt, forKey: .providerScopeMigrationReceipt)
            try container.encode(providerScopePreviousVersionDigest, forKey: .providerScopePreviousVersionDigest)
            try container.encode(providerScopeMigrationHistory, forKey: .providerScopeMigrationHistory)
            try container.encode(providerScopeMigrationCheckpoint, forKey: .providerScopeMigrationCheckpoint)
            try container.encode(providerScopeMigrationEpoch, forKey: .providerScopeMigrationEpoch)
            try container.encode(providerScopeMigrationCleanupTombstone, forKey: .providerScopeMigrationCleanupTombstone)
            try container.encode(providerScopeMigrationPreviousRoot, forKey: .providerScopeMigrationPreviousRoot)
            try container.encode(payloadDigest, forKey: .payloadDigest)
            try container.encode(records, forKey: .records)
        }
    }

    private struct SnapshotDigestPayload: Encodable {
        let schemaVersion: Int
        let transactionID: String
        let commitGeneration: UInt64
        let previousDigest: String?
        let providerScope: String?
        let providerScopeVersion: Int
        let providerScopeMigrationReceipt: String?
        let providerScopePreviousVersionDigest: String?
        let providerScopeMigrationHistory: [ProviderScopeMigrationHistoryEntry]?
        let providerScopeMigrationCheckpoint: String?
        let providerScopeMigrationEpoch: UInt64?
        let providerScopeMigrationCleanupTombstone: String?
        let providerScopeMigrationPreviousRoot: String?
        let records: [ProviderReadinessPersistenceRecord]
    }

    /// The marker is the durable state machine for a three-artifact commit.
    /// `prepared` proves only that a writer reserved a transaction; it never
    /// authorizes a snapshot.  Only `committed` may fence the primary and
    /// journal into a selectable load.
    private enum CommitMarkerState: String, Codable {
        case prepared
        case committed
    }

    private struct CommitMarker: Codable {
        let schemaVersion: Int
        let transactionID: String
        let commitGeneration: UInt64?
        let previousDigest: String?
        let providerScope: String?
        let providerScopeVersion: Int?
        let providerScopeMigrationReceipt: String?
        let providerScopePreviousVersionDigest: String?
        let providerScopeMigrationHistory: [ProviderScopeMigrationHistoryEntry]?
        let providerScopeMigrationCheckpoint: String?
        let providerScopeMigrationEpoch: UInt64?
        let providerScopeMigrationCleanupTombstone: String?
        let providerScopeMigrationPreviousRoot: String?
        let payloadDigest: String?
        let state: CommitMarkerState

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case transactionID
            case commitGeneration
            case previousDigest
            case providerScope
            case providerScopeVersion
            case providerScopeMigrationReceipt
            case providerScopePreviousVersionDigest
            case providerScopeMigrationHistory
            case providerScopeMigrationCheckpoint
            case providerScopeMigrationEpoch
            case providerScopeMigrationCleanupTombstone
            case providerScopeMigrationPreviousRoot
            case payloadDigest
            case state
        }

        init(
            schemaVersion: Int,
            transactionID: String,
            commitGeneration: UInt64?,
            previousDigest: String?,
            providerScope: String?,
            providerScopeVersion: Int?,
            providerScopeMigrationReceipt: String?,
            providerScopePreviousVersionDigest: String?,
            providerScopeMigrationHistory: [ProviderScopeMigrationHistoryEntry]?,
            providerScopeMigrationCheckpoint: String?,
            providerScopeMigrationEpoch: UInt64?,
            providerScopeMigrationCleanupTombstone: String?,
            providerScopeMigrationPreviousRoot: String? = nil,
            payloadDigest: String?,
            state: CommitMarkerState
        ) {
            self.schemaVersion = schemaVersion
            self.transactionID = transactionID
            self.commitGeneration = commitGeneration
            self.previousDigest = previousDigest
            self.providerScope = providerScope
            self.providerScopeVersion = providerScopeVersion
            self.providerScopeMigrationReceipt = providerScopeMigrationReceipt
            self.providerScopePreviousVersionDigest = providerScopePreviousVersionDigest
            self.providerScopeMigrationHistory = providerScopeMigrationHistory
            self.providerScopeMigrationCheckpoint = providerScopeMigrationCheckpoint
            self.providerScopeMigrationEpoch = providerScopeMigrationEpoch
            self.providerScopeMigrationCleanupTombstone = providerScopeMigrationCleanupTombstone
            self.providerScopeMigrationPreviousRoot = providerScopeMigrationPreviousRoot
            self.payloadDigest = payloadDigest
            self.state = state
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let dynamicContainer = try decoder.container(
                keyedBy: ProviderReadinessPersistenceCodingKey.self
            )
            let keys = Set(dynamicContainer.allKeys.map(\.stringValue))
            guard keys == ["schemaVersion", "transactionID", "state"]
                    || keys == ["schemaVersion", "transactionID", "commitGeneration", "state"]
                    || keys == ["schemaVersion", "transactionID", "commitGeneration", "payloadDigest", "state"]
                    || keys == ["schemaVersion", "transactionID", "commitGeneration", "previousDigest", "payloadDigest", "state"]
                    || keys == ["schemaVersion", "transactionID", "commitGeneration", "previousDigest", "providerScope", "providerScopeVersion", "providerScopeMigrationReceipt", "providerScopePreviousVersionDigest", "providerScopeMigrationHistory", "providerScopeMigrationCheckpoint", "providerScopeMigrationEpoch", "providerScopeMigrationCleanupTombstone", "payloadDigest", "state"]
                    || keys == ["schemaVersion", "transactionID", "commitGeneration", "previousDigest", "providerScope", "providerScopeVersion", "providerScopeMigrationReceipt", "providerScopePreviousVersionDigest", "providerScopeMigrationHistory", "providerScopeMigrationCheckpoint", "providerScopeMigrationEpoch", "providerScopeMigrationCleanupTombstone", "providerScopeMigrationPreviousRoot", "payloadDigest", "state"] else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unexpected persisted readiness marker key"
                ))
            }
            schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            let rawTransactionID = try container.decode(String.self, forKey: .transactionID)
            let normalizedTransactionID = rawTransactionID
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedTransactionID.isEmpty,
                  rawTransactionID == normalizedTransactionID else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "transaction identity must be canonical"
                ))
            }
            transactionID = normalizedTransactionID
            commitGeneration = try container.decodeIfPresent(
                UInt64.self,
                forKey: .commitGeneration
            )
            previousDigest = try container.decodeIfPresent(
                String.self,
                forKey: .previousDigest
            )
            providerScope = try container.decodeIfPresent(
                String.self,
                forKey: .providerScope
            )
            providerScopeVersion = try container.decodeIfPresent(
                Int.self,
                forKey: .providerScopeVersion
            )
            providerScopeMigrationReceipt = try container.decodeIfPresent(
                String.self,
                forKey: .providerScopeMigrationReceipt
            )
            providerScopePreviousVersionDigest = try container.decodeIfPresent(
                String.self,
                forKey: .providerScopePreviousVersionDigest
            )
            providerScopeMigrationHistory = try container.decodeIfPresent(
                [ProviderScopeMigrationHistoryEntry].self,
                forKey: .providerScopeMigrationHistory
            )
            providerScopeMigrationCheckpoint = try container.decodeIfPresent(
                String.self,
                forKey: .providerScopeMigrationCheckpoint
            )
            providerScopeMigrationEpoch = try container.decodeIfPresent(
                UInt64.self,
                forKey: .providerScopeMigrationEpoch
            )
            providerScopeMigrationCleanupTombstone = try container.decodeIfPresent(
                String.self,
                forKey: .providerScopeMigrationCleanupTombstone
            )
            providerScopeMigrationPreviousRoot = try container.decodeIfPresent(
                String.self,
                forKey: .providerScopeMigrationPreviousRoot
            )
            payloadDigest = try container.decodeIfPresent(
                String.self,
                forKey: .payloadDigest
            )
            state = try container.decode(CommitMarkerState.self, forKey: .state)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(schemaVersion, forKey: .schemaVersion)
            try container.encode(transactionID, forKey: .transactionID)
            try container.encode(commitGeneration, forKey: .commitGeneration)
            try container.encode(previousDigest, forKey: .previousDigest)
            try container.encode(providerScope, forKey: .providerScope)
            try container.encode(providerScopeVersion, forKey: .providerScopeVersion)
            try container.encode(providerScopeMigrationReceipt, forKey: .providerScopeMigrationReceipt)
            try container.encode(providerScopePreviousVersionDigest, forKey: .providerScopePreviousVersionDigest)
            try container.encode(providerScopeMigrationHistory, forKey: .providerScopeMigrationHistory)
            try container.encode(providerScopeMigrationCheckpoint, forKey: .providerScopeMigrationCheckpoint)
            try container.encode(providerScopeMigrationEpoch, forKey: .providerScopeMigrationEpoch)
            try container.encode(providerScopeMigrationCleanupTombstone, forKey: .providerScopeMigrationCleanupTombstone)
            try container.encode(providerScopeMigrationPreviousRoot, forKey: .providerScopeMigrationPreviousRoot)
            try container.encode(payloadDigest, forKey: .payloadDigest)
            try container.encode(state, forKey: .state)
        }
    }

    private enum LockIdentityInvalidStage: String {
        case lockFileOpen
        case lockFileDescriptorIdentity
        case lockFileSafeRegularFile
        case lockParentIdentityAfterAcquisition
        case primaryPresence
        case primaryData
        case primaryFileIdentity
        case primaryCommitGeneration
        case primaryTransactionID
        case primaryPreviousDigest
        case primaryProviderScope
        case primaryProviderScopeVersion
        case primaryMigrationReceipt
        case primaryPreviousVersionDigest
        case primaryMigrationHistory
        case primaryMigrationCheckpoint
        case primaryMigrationEpoch
        case primaryMigrationCleanupTombstone
        case primaryMigrationPreviousRoot
        case journalPresence
        case markerPresence
        case journalCommitGeneration
        case journalTransactionID
        case journalPreviousDigest
        case journalProviderScope
        case journalProviderScopeVersion
        case journalMigrationReceipt
        case journalPreviousVersionDigest
        case journalMigrationHistory
        case journalMigrationCheckpoint
        case journalMigrationEpoch
        case journalMigrationCleanupTombstone
        case journalMigrationPreviousRoot
        case markerCommitGeneration
        case markerTransactionID
        case markerPreviousDigest
        case markerProviderScope
        case markerProviderScopeVersion
        case markerMigrationReceipt
        case markerPreviousVersionDigest
        case markerMigrationHistory
        case markerMigrationCheckpoint
        case markerMigrationEpoch
        case markerMigrationCleanupTombstone
        case markerMigrationPreviousRoot
        case primaryPathIdentity
        case journalPathIdentity
        case markerPathIdentity
        case verifiedPrimaryRead
        case verifiedJournalRead
        case verifiedMarkerRead
        case verifiedPrimaryData
        case verifiedJournalData
        case verifiedMarkerData
        case verifiedAggregateSize
        case verifiedPrimaryDecode
        case verifiedJournalDecode
        case verifiedMarkerDecode
        case verifiedCommit
    }

    private enum PersistenceFileError: Error {
        case lockUnavailable
        case lockIdentityInvalid(stage: LockIdentityInvalidStage)
        case filesystemBoundary(stage: PersistenceFilesystemStage)
        case invalidJSON
    }

    private enum PersistenceFilesystemStage: String {
        case parentDirectoryIdentity
        case targetIdentity
        case temporaryOpen
        case temporaryWrite
        case temporarySyncIdentity
        case targetRename
        case committedDirectoryIdentity
    }

    private enum SnapshotDecodeStage: String {
        case oversized
        case canonicalFieldOrLineage
        case schemaOrRecordCount
        case commitGeneration
        case payloadDigest
        case accepted
    }

    static func persistenceDiagnosticStage(for error: Error) -> String {
        guard let persistenceError = error as? PersistenceFileError else {
            return "unknown"
        }
        switch persistenceError {
        case .lockUnavailable:
            return "lockUnavailable"
        case .lockIdentityInvalid(let stage):
            return "lockIdentityInvalid.\(stage.rawValue)"
        case .filesystemBoundary(let stage):
            return "filesystemBoundary.\(stage.rawValue)"
        case .invalidJSON:
            return "invalidJSON"
        }
    }

    static func snapshotDecodeDiagnosticStage(_ data: Data) -> String {
        var stage = SnapshotDecodeStage.oversized
        _ = decodeVerifiedSnapshot(data) { stage = $0 }
        return stage.rawValue
    }

    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let linkCount: UInt64
        let owner: UInt64
        let mode: UInt32

        init(_ metadata: stat) {
            device = UInt64(metadata.st_dev)
            inode = UInt64(metadata.st_ino)
            linkCount = UInt64(metadata.st_nlink)
            owner = UInt64(metadata.st_uid)
            mode = UInt32(metadata.st_mode)
        }

        var isSafeRegularFile: Bool {
            (mode & UInt32(S_IFMT)) == UInt32(S_IFREG)
                && linkCount == 1
                && owner == UInt64(geteuid())
                && (mode & 0o022) == 0
        }

        func matchesDirectoryObject(_ other: FileIdentity) -> Bool {
            (mode & UInt32(S_IFMT)) == UInt32(S_IFDIR)
                && (other.mode & UInt32(S_IFMT)) == UInt32(S_IFDIR)
                && device == other.device
                && inode == other.inode
                && owner == other.owner
                && mode == other.mode
        }
    }

    private let fileURL: URL
    private let journalURL: URL
    private let commitMarkerURL: URL
    private let lock = NSLock()
    private let onPersistError: ((Error) -> Void)?
    /// Optional configuration revision bound by the process that owns this
    /// store. When present, reloads cannot accept a result from another
    /// generation, even if that result has a later wall-clock timestamp.
    private let expectedConfigurationGeneration: String?
    private var storedRecords: [ProviderReadinessPersistenceKey: ProviderReadinessPersistenceRecord]
    // Raw bytes observed at load/last successful persist.  A write is
    // rejected when another instance has changed the snapshot in the
    // meantime, preserving fail-closed behavior instead of silently losing
    // that instance's records.
    private var baselineData: Data?
    private var baselineFileIdentity: FileIdentity?
    private var baselineJournalFileIdentity: FileIdentity?
    private var baselineCommitMarkerIdentity: FileIdentity?
    private var lastObservedCommitGeneration: UInt64?
    private var lastObservedCommitTransactionID: String?
    private var lastObservedCommitPreviousDigest: String?
    private var lastObservedCommitLineageConflict = false
    private var lastObservedCommitDigest: String?
    private var lastObservedCommitProviderScope: String?
    private var lastObservedCommitProviderScopeVersion: Int?
    private var lastObservedCommitProviderScopeMigrationReceipt: String?
    private var lastObservedCommitProviderScopePreviousVersionDigest: String?
    private var lastObservedCommitProviderScopeMigrationHistory: [ProviderScopeMigrationHistoryEntry]?
    private var lastObservedCommitProviderScopeMigrationCheckpoint: String?
    private var lastObservedCommitProviderScopeMigrationEpoch: UInt64?
    private var lastObservedCommitProviderScopeMigrationCleanupTombstone: String?
    private var lastObservedCommitProviderScopeMigrationPreviousRoot: String?
    public private(set) var recoveryState: ProviderReadinessStoreRecoveryState = .missing

    public init(
        directory: URL,
        onPersistError: ((Error) -> Void)? = nil,
        configurationGeneration: String? = nil
    ) {
        self.fileURL = directory.appendingPathComponent(Self.fileName)
        self.journalURL = directory.appendingPathComponent(Self.journalFileName)
        self.commitMarkerURL = directory.appendingPathComponent(Self.commitMarkerFileName)
        self.onPersistError = onPersistError
        self.expectedConfigurationGeneration = configurationGeneration
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        self.storedRecords = [:]
        self.baselineData = nil
        self.baselineFileIdentity = nil
        self.baselineJournalFileIdentity = nil
        self.baselineCommitMarkerIdentity = nil
        self.lastObservedCommitGeneration = nil
        self.lastObservedCommitTransactionID = nil
        self.lastObservedCommitPreviousDigest = nil
        self.lastObservedCommitLineageConflict = false
        self.lastObservedCommitDigest = nil
        self.lastObservedCommitProviderScope = nil
        self.lastObservedCommitProviderScopeVersion = nil
        self.lastObservedCommitProviderScopeMigrationReceipt = nil
        self.lastObservedCommitProviderScopePreviousVersionDigest = nil
        self.lastObservedCommitProviderScopeMigrationHistory = nil
        self.lastObservedCommitProviderScopeMigrationCheckpoint = nil
        self.lastObservedCommitProviderScopeMigrationEpoch = nil
        self.lastObservedCommitProviderScopeMigrationCleanupTombstone = nil
        self.lastObservedCommitProviderScopeMigrationPreviousRoot = nil

        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        load()
    }

    public var records: [ProviderReadinessPersistenceRecord] {
        lock.lock()
        defer { lock.unlock() }
        return recordsBoundToExpectedGeneration()
    }

    /// Projects durable rows through the current runtime selection boundary.
    /// Persistence may outlive a provider configuration, so a disabled or
    /// missing provider must explicitly downgrade old rows before they reach
    /// the picker.
    public func recordsForSelection(
        providerID: String? = nil,
        isEnabled: Bool,
        isConfigured: Bool,
        isReady: Bool
    ) -> [ProviderReadinessPersistenceRecord] {
        lock.lock()
        defer { lock.unlock() }
        let normalizedProviderID = providerID.map {
            ProviderReadinessPersistenceRedactor.redact($0)
        }
        return recordsBoundToExpectedGeneration().map {
            if let normalizedProviderID,
               $0.providerID.caseInsensitiveCompare(normalizedProviderID)
                    != .orderedSame {
                return $0
            }
            return $0.gatedForSelection(
                isEnabled: isEnabled,
                isConfigured: isConfigured,
                isReady: isReady
            )
        }
    }

    /// Projects every durable row from the provider catalog's explicit
    /// enabled/configured/ready sets. A provider absent from
    /// `configuredProviderIDs` is treated as removed, which prevents an old
    /// snapshot from becoming actionable merely because its label survived.
    public func recordsForSelection(
        configuredProviderIDs: Set<String>,
        enabledProviderIDs: Set<String>,
        readyProviderIDs: Set<String>
    ) -> [ProviderReadinessPersistenceRecord] {
        lock.lock()
        defer { lock.unlock() }
        let configured = Self.normalizedProviderIDs(configuredProviderIDs)
        let enabled = Self.normalizedProviderIDs(enabledProviderIDs)
        let ready = Self.normalizedProviderIDs(readyProviderIDs)
        return recordsBoundToExpectedGeneration().map { record in
            let providerID = ProviderReadinessRevision.canonicalProviderID(
                record.providerID
            )
            return record.gatedForSelection(
                isEnabled: enabled.contains(providerID),
                isConfigured: configured.contains(providerID),
                isReady: ready.contains(providerID)
            )
        }
    }

    /// Reads one provider/model fact only when its configuration identity and
    /// expiry are current. Drift or staleness returns an explicit unverified
    /// record so consumers cannot silently reuse a prior green observation.
    public func record(
        providerID: String,
        modelID: String,
        configurationFingerprint: String,
        now: Date,
        configurationGeneration: String = ProviderReadinessPersistenceRecord
            .legacyConfigurationGeneration,
        isEnabled: Bool = true,
        isConfigured: Bool = true,
        isReady: Bool = true
    ) -> ProviderReadinessPersistenceRecord? {
        let key = ProviderReadinessPersistenceKey(
            providerID: ProviderReadinessPersistenceRedactor.redact(providerID),
            modelID: ProviderReadinessPersistenceRedactor.redact(modelID),
            configurationGeneration: configurationGeneration
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
        lock.lock()
        defer { lock.unlock() }
        if let record = storedRecords[key] {
            let validated = record.validatedForCache(
                configurationFingerprint: configurationFingerprint,
                now: now,
                configurationGeneration: configurationGeneration
            )
            return validated.gatedForSelection(
                isEnabled: isEnabled,
                isConfigured: isConfigured,
                isReady: isReady
            )
        }

        // A lookup for a newer configuration generation must not silently
        // erase the provider/model row when only an older generation is
        // durable.  Return that drifted fact explicitly unverified so picker
        // and settings consumers can keep a pending recovery row while
        // refusing enabled/configured/ready actionability.
        let driftedRecord = storedRecords.values
            .filter {
                $0.providerID == key.providerID
                    && $0.modelID == key.modelID
            }
            .max {
                if $0.checkedAt != $1.checkedAt {
                    return $0.checkedAt < $1.checkedAt
                }
                return $0.configurationGeneration < $1.configurationGeneration
            }
        return driftedRecord?.downgradedToUnverified().gatedForSelection(
            isEnabled: isEnabled,
            isConfigured: isConfigured,
            isReady: isReady
        )
    }

    public func upsert(_ record: ProviderReadinessPersistenceRecord) {
        _ = upsert([record])
    }

    /// Admits a result only when it belongs to the configuration revision and
    /// runtime selection state that initiated the check. A late result from a
    /// prior generation, or one completing after the provider was disabled or
    /// unconfigured, is rejected without modifying the durable snapshot.
    @discardableResult
    public func upsert(
        _ records: [ProviderReadinessPersistenceRecord],
        configurationGeneration expectedGeneration: String,
        isEnabled: Bool,
        isConfigured: Bool,
        isReady: Bool
    ) -> Bool {
        let normalizedGeneration = expectedGeneration
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedGeneration.isEmpty,
              isEnabled,
              isConfigured,
              isReady,
              records.allSatisfy({
                  $0.configurationGeneration == normalizedGeneration
              }) else {
            return false
        }
        return upsert(records)
    }

    /// Atomically persists a group of observations from one readiness check.
    ///
    /// The previous snapshot is restored when the atomic file replacement
    /// fails. This prevents a reconnect/report with several models from
    /// leaving a mixed generation on disk.
    @discardableResult
    public func upsert(_ records: [ProviderReadinessPersistenceRecord]) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard recordsMatchExpectedGeneration(records) else {
            return false
        }
        guard Self.conflictingBatchKeys(records).isEmpty else {
            return false
        }
        guard records.allSatisfy(\.isValid) else {
            return false
        }

        let previous = storedRecords
        var changed = false
        for record in records {
            guard record.isValid else {
                continue
            }
            if let current = storedRecords[record.key] {
                if Self.isReplayedHealthReceipt(record, after: current) {
                    continue
                }
                if current.checkedAt > record.checkedAt {
                    continue
                }
            }

            let next: ProviderReadinessPersistenceRecord
            if let current = storedRecords[record.key], current.isApplied {
                next = record.preservingLineage(from: current)
            } else {
                next = record
            }
            if storedRecords[next.key] != next {
                storedRecords[next.key] = next
                changed = true
            }
        }
        guard changed else { return true }
        guard persistLocked() else {
            restorePendingSnapshotAfterPersistenceFailure(previous)
            return false
        }
        return true
    }

    /// Persists one reconnect generation and reports whether it was accepted.
    ///
    /// Unlike ordinary batch upsert, this method exposes the stale/invalid
    /// distinction needed by a reconnect UI. Equal timestamps are accepted so
    /// a retry that completes within the same clock tick can replace a failed
    /// result and retain its measured latency.
    @discardableResult
    public func reconnect(
        _ record: ProviderReadinessPersistenceRecord
    ) -> ProviderReadinessReconnectOutcome {
        reconnect([record]).first ?? .rejectedInvalid
    }

    /// Reconnects all model outcomes from one report as one durable snapshot.
    /// Invalid or stale siblings are reported individually so the caller can
    /// keep the UI terminal state tied to the exact accepted evidence.
    public func reconnect(
        _ records: [ProviderReadinessPersistenceRecord]
    ) -> [ProviderReadinessReconnectOutcome] {
        lock.lock()
        defer { lock.unlock() }

        guard recordsMatchExpectedGeneration(records) else {
            return records.map { _ in .rejectedInvalid }
        }
        guard Self.conflictingBatchKeys(records).isEmpty else {
            return records.map { _ in .rejectedInvalid }
        }

        let previous = storedRecords
        var outcomes: [ProviderReadinessReconnectOutcome] = []
        var changed = false
        for record in records {
            guard record.isValid else {
                outcomes.append(.rejectedInvalid)
                continue
            }
            if let current = storedRecords[record.key] {
                if Self.isReplayedHealthReceipt(record, after: current) {
                    outcomes.append(.ignoredStale)
                    continue
                }
                if current.checkedAt > record.checkedAt {
                    outcomes.append(.ignoredStale)
                    continue
                }
            }

            let next: ProviderReadinessPersistenceRecord
            if let current = storedRecords[record.key], current.isApplied {
                next = record.preservingLineage(from: current)
            } else {
                next = record
            }
            if storedRecords[next.key] != next {
                storedRecords[next.key] = next
                changed = true
            }
            outcomes.append(.persisted)
        }

        guard changed else { return outcomes }
        guard persistLocked() else {
            restorePendingSnapshotAfterPersistenceFailure(previous)
            return outcomes.map { outcome in
                outcome == .persisted ? .persistenceFailed : outcome
            }
        }
        return outcomes
    }

    /// Strict reconnect admission for a health/readiness attempt. Results
    /// arriving after a configuration or enabled-state revision are reported
    /// as rejected instead of being allowed to mint a new durable row.
    public func reconnect(
        _ records: [ProviderReadinessPersistenceRecord],
        configurationGeneration expectedGeneration: String,
        isEnabled: Bool,
        isConfigured: Bool,
        isReady: Bool
    ) -> [ProviderReadinessReconnectOutcome] {
        let normalizedGeneration = expectedGeneration
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedGeneration.isEmpty,
              isEnabled,
              isConfigured,
              isReady,
              records.allSatisfy({
                  $0.configurationGeneration == normalizedGeneration
              }) else {
            return records.map { _ in .rejectedInvalid }
        }
        return reconnect(records)
    }

    public func applyDiscoveredModels(
        providerID: String,
        modelIDs: [String],
        appliedAt: Date = Date()
    ) -> [ProviderReadinessPersistenceRecord] {
        lock.lock()
        defer { lock.unlock() }

        let requested = Set(modelIDs.map(ProviderReadinessPersistenceRedactor.redact))
        let previous = storedRecords
        var changed = false
        var appliedRecords: [ProviderReadinessPersistenceRecord] = []
        for (key, record) in storedRecords
        where key.providerID.caseInsensitiveCompare(
            ProviderReadinessPersistenceRedactor.redact(providerID)
        ) == .orderedSame
            && requested.contains(key.modelID)
            && (expectedConfigurationGeneration == nil
                || key.configurationGeneration == expectedConfigurationGeneration)
            && (record.status == .discovered || record.status == .passed)
            && !record.isApplied {
            let applied = record.applying(true, at: appliedAt)
            storedRecords[key] = applied
            appliedRecords.append(applied)
            changed = true
        }
        if changed {
            guard persistLocked() else {
                restorePendingSnapshotAfterPersistenceFailure(previous)
                return []
            }
        }
        return appliedRecords.sorted {
            if $0.providerID == $1.providerID {
                return $0.modelID < $1.modelID
            }
            return $0.providerID < $1.providerID
        }
    }

    /// Drops the readiness lineage for exactly one provider/model pair after
    /// its credential has been replaced by a successor.
    ///
    /// A credential replacement must not inherit a prior failure (or an old
    /// Apply receipt), and the next probe must be able to write a fresh
    /// observation even when its timestamp is not newer than the old one.
    /// Provider identity matching follows explicit Apply semantics and is
    /// case-insensitive; model identity remains exact. No other provider or
    /// model record is touched.
    @discardableResult
    public func rebindCredentialSuccessor(
        providerID: String,
        modelID: String
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let normalizedProviderID = ProviderReadinessPersistenceRedactor.redact(providerID)
        let normalizedModelID = ProviderReadinessPersistenceRedactor.redact(modelID)
        let keys = storedRecords.keys.filter {
            $0.providerID.caseInsensitiveCompare(normalizedProviderID) == .orderedSame
                && $0.modelID == normalizedModelID
        }
        guard !keys.isEmpty else { return false }
        let previous = storedRecords
        for key in keys {
            storedRecords.removeValue(forKey: key)
        }
        guard persistLocked() else {
            restorePendingSnapshotAfterPersistenceFailure(previous)
            return false
        }
        return true
    }

    /// Rebind a provider identity after credential replacement.  Every model
    /// observation under the old credential is removed together, while the
    /// next readiness check must explicitly repopulate the new identity.
    @discardableResult
    public func rebindCredentialSuccessor(providerID: String) -> Int {
        lock.lock()
        defer { lock.unlock() }

        let normalizedProviderID = ProviderReadinessPersistenceRedactor.redact(providerID)
        let keys = storedRecords.keys.filter {
            $0.providerID.caseInsensitiveCompare(normalizedProviderID) == .orderedSame
        }
        guard !keys.isEmpty else { return 0 }
        let previous = storedRecords
        for key in keys {
            storedRecords.removeValue(forKey: key)
        }
        guard persistLocked() else {
            restorePendingSnapshotAfterPersistenceFailure(previous)
            return 0
        }
        return keys.count
    }

    @discardableResult
    public func removeProvider(providerID: String) -> Int {
        lock.lock()
        defer { lock.unlock() }

        let normalizedProviderID = ProviderReadinessPersistenceRedactor.redact(providerID)
        let keys = storedRecords.keys.filter {
            $0.providerID.caseInsensitiveCompare(normalizedProviderID) == .orderedSame
        }
        guard !keys.isEmpty else { return 0 }
        let previous = storedRecords
        for key in keys {
            storedRecords.removeValue(forKey: key)
        }
        guard persistLocked() else {
            restorePendingSnapshotAfterPersistenceFailure(previous)
            return 0
        }
        return keys.count
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            baselineData = nil
            baselineFileIdentity = nil
            recoveryState = .missing
            if recoverFromJournal() {
                return
            }
            // A journal or marker without a primary is an interrupted
            // transaction, not an empty store. Keep the distinction typed so
            // picker consumers cannot treat the directory as freshly usable.
            if FileManager.default.fileExists(atPath: journalURL.path)
                || FileManager.default.fileExists(atPath: commitMarkerURL.path) {
                recoveryState = .incompleteTransaction
            }
            return
        }

        guard let primaryRead = Self.readSafeFile(
            at: fileURL,
            maxBytes: Self.maxSnapshotBytes
        ) else {
            baselineData = nil
            baselineFileIdentity = nil
            if recoverFromJournal() {
                return
            }
            recoveryState = .quarantinedCorrupt
            return
        }
        let identity = primaryRead.identity
        let rawData = primaryRead.data
        baselineData = rawData
        baselineFileIdentity = identity
        guard let snapshot = Self.decodeVerifiedSnapshot(rawData) else {
            if recoverFromJournal() {
                return
            }
            recoveryState = recoverPartialSnapshot(from: fileURL)
            if recoveryState == .quarantinedCorrupt {
                quarantineCorruptSnapshot()
            }
            return
        }
        guard Self.pathIdentity(at: fileURL.path) == identity else {
            recoveryState = .quarantinedCorrupt
            return
        }
        let journalRead = Self.readSafeFile(
            at: journalURL,
            maxBytes: Self.maxSnapshotBytes
        )
        baselineJournalFileIdentity = journalRead?.identity
            ?? Self.pathIdentity(at: journalURL.path)
        let markerRead = Self.readSafeFile(
            at: commitMarkerURL,
            maxBytes: Self.maxPersistedStringBytes
        )
        guard Self.aggregateArtifactSizeIsValid(
            [
                rawData.count,
                journalRead?.data.count ?? 0,
                markerRead?.data.count ?? 0,
            ]
        ) else {
            recoveryState = .incompleteTransaction
            return
        }
        baselineCommitMarkerIdentity = markerRead?.identity
            ?? Self.pathIdentity(at: commitMarkerURL.path)
        let journalExists = FileManager.default.fileExists(atPath: journalURL.path)
        let journalSnapshot = journalRead.flatMap { Self.decodeVerifiedSnapshot($0.data) }
        let markerExists = FileManager.default.fileExists(atPath: commitMarkerURL.path)
        let marker = markerRead.flatMap { Self.decodeCommitMarker($0.data) }
        guard journalRead == nil
                || Self.pathIdentity(at: journalURL.path) == journalRead?.identity,
              markerRead == nil
                || Self.pathIdentity(at: commitMarkerURL.path) == markerRead?.identity else {
            recoveryState = .quarantinedCorrupt
            return
        }
        observeCommitLineage(
            primary: snapshot,
            journal: journalSnapshot,
            marker: marker
        )
        if let failure = Self.commitValidationFailure(
            primary: snapshot,
            journal: journalSnapshot,
            journalExists: journalExists,
            marker: marker,
            markerExists: markerExists
        ) {
            if let candidate = Self.boundedCommittedRecoveryCandidate(
                primary: snapshot,
                journal: journalSnapshot,
                marker: marker
            ) ?? Self.preparedSuccessorRecoveryCandidate(
                primary: snapshot,
                journal: journalSnapshot,
                marker: marker
            ) {
                storedRecords = candidate.records.reduce(
                    into: [ProviderReadinessPersistenceKey: ProviderReadinessPersistenceRecord]()
                ) { result, record in
                    guard record.isValid else { return }
                    if let current = result[record.key] {
                        result[record.key] = Self.mergeRestoredRecord(
                            current,
                            with: record
                        )
                    } else {
                        result[record.key] = record
                    }
                }.mapValues { $0.downgradedToPending() }
                recoveryState = .recoveredCommittedSnapshot(
                    recordCount: storedRecords.count
                )
                return
            }
            storedRecords = [:]
            recoveryState = failure
            return
        }
        var droppedRecordCount = 0
        storedRecords = snapshot.records.reduce(into: [:]) { result, record in
            guard record.isValid else {
                droppedRecordCount += 1
                return
            }
            if let current = result[record.key] {
                result[record.key] = Self.mergeRestoredRecord(
                    current,
                    with: record
                )
            } else {
                result[record.key] = record
            }
        }
        if droppedRecordCount > 0 {
            recoveryState = .recoveredPartial(
                validRecordCount: storedRecords.count,
                droppedRecordCount: droppedRecordCount
            )
            if !persistLocked(preservingRecoveryState: true) {
                // A valid sibling remains diagnostic evidence, but a failed
                // repair cannot grant it selection authority in memory.
                storedRecords = storedRecords.mapValues { $0.downgradedToPending() }
            }
        } else {
            recoveryState = .loaded(recordCount: storedRecords.count)
        }
    }

    private func recoverFromJournal() -> Bool {
        let journalRead = Self.readSafeFile(
            at: journalURL,
            maxBytes: Self.maxSnapshotBytes
        )
        baselineJournalFileIdentity = journalRead?.identity
            ?? Self.pathIdentity(at: journalURL.path)
        baselineCommitMarkerIdentity = Self.pathIdentity(at: commitMarkerURL.path)
        guard let snapshot = journalRead.flatMap({ Self.decodeVerifiedSnapshot($0.data) }) else {
            return false
        }
        let markerExists = FileManager.default.fileExists(atPath: commitMarkerURL.path)
        let markerRead = Self.readSafeFile(
            at: commitMarkerURL,
            maxBytes: Self.maxPersistedStringBytes
        )
        guard Self.aggregateArtifactSizeIsValid(
            [
                journalRead?.data.count ?? 0,
                markerRead?.data.count ?? 0,
            ]
        ) else {
            return false
        }
        baselineCommitMarkerIdentity = markerRead?.identity
            ?? Self.pathIdentity(at: commitMarkerURL.path)
        let marker = markerRead.flatMap { Self.decodeCommitMarker($0.data) }
        guard Self.pathIdentity(at: journalURL.path) == journalRead?.identity,
              markerRead == nil
                || Self.pathIdentity(at: commitMarkerURL.path) == markerRead?.identity else {
            return false
        }
        guard Self.journalCommitIsComplete(
            snapshot,
            marker: marker,
            markerExists: markerExists
        ) else {
            return false
        }
        lastObservedCommitGeneration = snapshot.commitGeneration
        lastObservedCommitTransactionID = snapshot.transactionID
        lastObservedCommitPreviousDigest = snapshot.previousDigest
        lastObservedCommitLineageConflict = false
        lastObservedCommitDigest = snapshot.payloadDigest
        lastObservedCommitProviderScope = snapshot.providerScope
        lastObservedCommitProviderScopeVersion = snapshot.providerScopeVersion
        lastObservedCommitProviderScopeMigrationReceipt = snapshot.providerScopeMigrationReceipt
        lastObservedCommitProviderScopePreviousVersionDigest = snapshot.providerScopePreviousVersionDigest
        lastObservedCommitProviderScopeMigrationHistory = snapshot.providerScopeMigrationHistory
        lastObservedCommitProviderScopeMigrationCheckpoint = snapshot.providerScopeMigrationCheckpoint
        lastObservedCommitProviderScopeMigrationEpoch = snapshot.providerScopeMigrationEpoch
        lastObservedCommitProviderScopeMigrationCleanupTombstone = snapshot.providerScopeMigrationCleanupTombstone
        lastObservedCommitProviderScopeMigrationPreviousRoot = snapshot.providerScopeMigrationPreviousRoot
        let merged = snapshot.records.reduce(
            into: [ProviderReadinessPersistenceKey: ProviderReadinessPersistenceRecord]()
        ) { result, record in
            if let current = result[record.key] {
                result[record.key] = Self.mergeRestoredRecord(
                    current,
                    with: record
                )
            } else {
                result[record.key] = record
            }
        }
        storedRecords = merged.mapValues { $0.downgradedToPending() }
        recoveryState = .recoveredCommittedSnapshot(
            recordCount: storedRecords.count
        )
        return true
    }

    private func recordsMatchExpectedGeneration(
        _ records: [ProviderReadinessPersistenceRecord]
    ) -> Bool {
        guard let expectedConfigurationGeneration else { return true }
        return records.allSatisfy {
            $0.configurationGeneration == expectedConfigurationGeneration
        }
    }

    private func recordsBoundToExpectedGeneration()
        -> [ProviderReadinessPersistenceRecord]
    {
        guard let expectedConfigurationGeneration else {
            return sortedRecords()
        }
        return sortedRecords().map { record in
            record.configurationGeneration == expectedConfigurationGeneration
                ? record
                : record.downgradedToPending()
        }
    }

    /// JSON can remain structurally valid while one record is not.  Recover
    /// valid sibling records individually and drop only the invalid entries.
    private func recoverPartialSnapshot(
        from url: URL
    ) -> ProviderReadinessStoreRecoveryState {
        guard let data = Self.readSafeFile(
            at: url,
            maxBytes: Self.maxSnapshotBytes
        )?.data,
              data.count <= Self.maxSnapshotBytes,
              (try? Self.validatePersistedJSON(data)) != nil,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let schemaVersion = dictionary["schemaVersion"] as? Int,
              schemaVersion == Self.schemaVersion,
              let rawRecords = dictionary["records"] as? [Any],
              rawRecords.count <= Self.maxSnapshotRecords else {
            return .quarantinedCorrupt
        }
        // A transactional snapshot whose digest cannot be verified is not
        // eligible for record-by-record repair: doing so could publish a
        // mixed payload while silently discarding the transaction evidence.
        // Only pre-transaction snapshots may use partial recovery.
        guard dictionary["transactionID"] == nil,
              dictionary["commitGeneration"] == nil,
              dictionary["payloadDigest"] == nil else {
            return .quarantinedCorrupt
        }

        var validRecords: [ProviderReadinessPersistenceRecord] = []
        var droppedCount = 0
        for rawRecord in rawRecords {
            guard JSONSerialization.isValidJSONObject(rawRecord),
                  let recordData = try? JSONSerialization.data(
                      withJSONObject: rawRecord
                  ),
                  let record = try? JSONDecoder().decode(
                      ProviderReadinessPersistenceRecord.self,
                      from: recordData
                  ) else {
                droppedCount += 1
                continue
            }
            guard record.isValid else {
                droppedCount += 1
                continue
            }
            validRecords.append(record)
        }

        guard droppedCount > 0 else {
            return .quarantinedCorrupt
        }
        storedRecords = validRecords.reduce(into: [:]) { result, record in
            if let current = result[record.key] {
                result[record.key] = Self.mergeRestoredRecord(
                    current,
                    with: record
                )
            } else {
                result[record.key] = record
            }
        }
        recoveryState = .recoveredPartial(
            validRecordCount: storedRecords.count,
            droppedRecordCount: droppedCount
        )
        if !persistLocked(preservingRecoveryState: true) {
            // A valid sibling is useful evidence, but it is not selection
            // authority when the repaired snapshot could not be committed.
            // Keep the row for diagnostics while fencing any in-memory green
            // state from picker consumers.
            storedRecords = storedRecords.mapValues { $0.downgradedToPending() }
        }
        return recoveryState
    }

    private static func decodeVerifiedSnapshot(
        _ data: Data,
        diagnostic: ((SnapshotDecodeStage) -> Void)? = nil
    ) -> Snapshot? {
        guard data.count <= Self.maxSnapshotBytes else {
            diagnostic?(.oversized)
            return nil
        }
        guard (try? Self.validatePersistedJSON(data)) != nil,
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            diagnostic?(.canonicalFieldOrLineage)
            return nil
        }
        guard snapshot.schemaVersion == Self.schemaVersion,
              snapshot.records.count <= Self.maxSnapshotRecords else {
            diagnostic?(.schemaOrRecordCount)
            return nil
        }
        guard Self.isValidCommitGeneration(snapshot.commitGeneration) else {
            diagnostic?(.commitGeneration)
            return nil
        }
        guard Self.snapshotPayloadDigestMatches(snapshot) else {
            diagnostic?(.payloadDigest)
            return nil
        }
        diagnostic?(.accepted)
        return snapshot
    }

    private static func decodeCommitMarker(_ data: Data) -> CommitMarker? {
        guard data.count <= maxPersistedStringBytes,
              String(data: data, encoding: .utf8) != nil else {
            return nil
        }
        var validator = JSONDuplicateKeyValidator(
            bytes: Array(data),
            maxDepth: Self.maxPersistedJSONDepth,
            maxObjectKeys: Self.maxPersistedObjectKeys,
            maxStringBytes: Self.maxPersistedStringBytes,
            canonicalIntegerKeys: [
                "commitGeneration",
                "providerScopeVersion",
                "fromVersion",
                "toVersion",
                "providerScopeMigrationEpoch",
            ]
        )
        guard (try? validator.validate()) != nil,
              let marker = try? JSONDecoder().decode(CommitMarker.self, from: data),
              marker.schemaVersion == Self.schemaVersion,
              Self.isValidCommitGeneration(marker.commitGeneration),
              Self.markerDigestShapeIsValid(marker) else {
            return nil
        }
        return marker
    }

    private static func snapshotPayloadDigestMatches(_ snapshot: Snapshot) -> Bool {
        guard let transactionID = snapshot.transactionID,
              let commitGeneration = snapshot.commitGeneration else {
            return snapshot.previousDigest == nil
                && snapshot.providerScope == nil
                && snapshot.payloadDigest == nil
        }
        guard snapshot.providerScopeVersion == Self.providerScopeVersion,
              currentMigrationSealIsValid(
                  receipt: snapshot.providerScopeMigrationReceipt,
                  previousVersionDigest: snapshot.providerScopePreviousVersionDigest,
                  history: snapshot.providerScopeMigrationHistory,
                  checkpoint: snapshot.providerScopeMigrationCheckpoint,
                  epoch: snapshot.providerScopeMigrationEpoch,
                  cleanupTombstone: snapshot.providerScopeMigrationCleanupTombstone,
                  previousRoot: snapshot.providerScopeMigrationPreviousRoot
              ),
              isCanonicalTransactionID(transactionID),
              let providerScope = snapshot.providerScope,
              isCanonicalProviderScope(providerScope),
              recordsAreCanonical(snapshot.records),
              providerScope == providerScopeDigest(
                  for: snapshot.records,
                  migrationReceipt: snapshot.providerScopeMigrationReceipt,
                  previousVersionDigest: snapshot.providerScopePreviousVersionDigest,
                  migrationCheckpoint: snapshot.providerScopeMigrationCheckpoint,
                  migrationEpoch: snapshot.providerScopeMigrationEpoch,
                  cleanupTombstone: snapshot.providerScopeMigrationCleanupTombstone,
                  previousRoot: snapshot.providerScopeMigrationPreviousRoot
              ) else {
            return false
        }
        guard isValidCommitLineage(
            generation: commitGeneration,
            previousDigest: snapshot.previousDigest
        ) else {
            return false
        }
        guard let declaredDigest = snapshot.payloadDigest,
              let calculatedDigest = payloadDigest(
                  schemaVersion: snapshot.schemaVersion,
                  transactionID: transactionID,
                  commitGeneration: commitGeneration,
                  previousDigest: snapshot.previousDigest,
                  providerScope: providerScope,
                  providerScopeVersion: snapshot.providerScopeVersion,
                  providerScopeMigrationReceipt: snapshot.providerScopeMigrationReceipt,
                  providerScopePreviousVersionDigest: snapshot.providerScopePreviousVersionDigest,
                  providerScopeMigrationHistory: snapshot.providerScopeMigrationHistory,
                  providerScopeMigrationCheckpoint: snapshot.providerScopeMigrationCheckpoint,
                  providerScopeMigrationEpoch: snapshot.providerScopeMigrationEpoch,
                  providerScopeMigrationCleanupTombstone: snapshot.providerScopeMigrationCleanupTombstone,
                  providerScopeMigrationPreviousRoot: snapshot.providerScopeMigrationPreviousRoot,
                  records: snapshot.records
              ) else {
            return false
        }
        return isCanonicalDigest(declaredDigest) && declaredDigest == calculatedDigest
    }

    private static func markerDigestShapeIsValid(_ marker: CommitMarker) -> Bool {
        guard marker.commitGeneration != nil else {
            return marker.previousDigest == nil
                && marker.providerScope == nil
                && marker.payloadDigest == nil
        }
        guard let generation = marker.commitGeneration,
              isValidCommitLineage(
                  generation: generation,
                  previousDigest: marker.previousDigest
              ) else {
            return false
        }
        return marker.providerScopeVersion == Self.providerScopeVersion
            && currentMigrationSealIsValid(
                receipt: marker.providerScopeMigrationReceipt,
                previousVersionDigest: marker.providerScopePreviousVersionDigest,
                history: marker.providerScopeMigrationHistory,
                checkpoint: marker.providerScopeMigrationCheckpoint,
                epoch: marker.providerScopeMigrationEpoch,
                cleanupTombstone: marker.providerScopeMigrationCleanupTombstone,
                previousRoot: marker.providerScopeMigrationPreviousRoot
            )
            && isCanonicalTransactionID(marker.transactionID)
            && marker.providerScope != nil
            && isCanonicalProviderScope(marker.providerScope)
            && marker.payloadDigest != nil
            && isCanonicalDigest(marker.previousDigest)
            && isCanonicalDigest(marker.payloadDigest)
    }

    private static func isValidCommitLineage(
        generation: UInt64,
        previousDigest: String?
    ) -> Bool {
        guard generation > 0 else { return false }
        if generation == 1 {
            return previousDigest == nil
        }
        return previousDigest != nil
    }

    private static func isCanonicalDigest(_ digest: String?) -> Bool {
        guard let digest else { return true }
        guard digest.utf8.count == 64 else { return false }
        return digest.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57)
                || (byte >= 97 && byte <= 102)
        }
    }

    private static func isCanonicalTransactionID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
    }

    private static func isCanonicalProviderScope(_ scope: String?) -> Bool {
        guard let scope else { return true }
        return isCanonicalDigest(scope)
    }

    private static var nativeProviderScopeMigrationHistory: [ProviderScopeMigrationHistoryEntry] {
        [ProviderScopeMigrationHistoryEntry(
            migrationID: Self.providerScopeMigrationID,
            fromVersion: 0,
            toVersion: Self.providerScopeVersion,
            previousVersionDigest: nil
        )]
    }

    private static func migrationHistoryShapeIsValid(
        _ history: [ProviderScopeMigrationHistoryEntry]?
    ) -> Bool {
        guard let history,
              !history.isEmpty,
              history.count <= Self.maxProviderScopeMigrationHistory else {
            return false
        }
        var expectedFromVersion = 0
        var migrationIDs: Set<String> = []
        for entry in history {
            guard isCanonicalTransactionID(entry.migrationID),
                  entry.migrationID == entry.migrationID.lowercased(),
                  entry.fromVersion == expectedFromVersion,
                  entry.toVersion > entry.fromVersion,
                  entry.toVersion <= Self.providerScopeVersion,
                  isCanonicalDigest(entry.previousVersionDigest),
                  entry.fromVersion > 0 || entry.previousVersionDigest == nil,
                  migrationIDs.insert(entry.migrationID).inserted else {
                return false
            }
            expectedFromVersion = entry.toVersion
        }
        return expectedFromVersion == Self.providerScopeVersion
    }

    private static func migrationCheckpoint(
        history: [ProviderScopeMigrationHistoryEntry],
        epoch: UInt64,
        cleanupTombstone: String,
        previousRoot: String?
    ) -> String? {
        guard epoch > 0,
              previousRoot == nil || isCanonicalDigest(previousRoot),
              migrationHistoryShapeIsValid(history) else {
            return nil
        }
        let payload = ProviderScopeMigrationCheckpointPayload(
            epoch: epoch,
            cleanupTombstone: cleanupTombstone,
            previousRoot: previousRoot,
            history: history
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else { return nil }
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func currentMigrationSealIsValid(
        receipt: String?,
        previousVersionDigest: String?,
        history: [ProviderScopeMigrationHistoryEntry]?,
        checkpoint: String?,
        epoch: UInt64?,
        cleanupTombstone: String?,
        previousRoot: String?
    ) -> Bool {
        guard receipt == Self.providerScopeMigrationReceipt,
              previousVersionDigest == nil,
              history == Self.nativeProviderScopeMigrationHistory,
              epoch == Self.providerScopeMigrationEpoch,
              cleanupTombstone == Self.providerScopeMigrationCleanupTombstone,
              previousRoot == Self.providerScopeMigrationPreviousRoot,
              let checkpoint,
              isCanonicalDigest(checkpoint),
              checkpoint == Self.migrationCheckpoint(
                  history: Self.nativeProviderScopeMigrationHistory,
                  epoch: Self.providerScopeMigrationEpoch,
                  cleanupTombstone: Self.providerScopeMigrationCleanupTombstone,
                  previousRoot: Self.providerScopeMigrationPreviousRoot
              ) else {
            return false
        }
        return true
    }

    private static func recordsAreCanonical(
        _ records: [ProviderReadinessPersistenceRecord]
    ) -> Bool {
        records == records.sorted {
            if $0.providerID == $1.providerID {
                if $0.modelID == $1.modelID {
                    return $0.configurationGeneration < $1.configurationGeneration
                }
                return $0.modelID < $1.modelID
            }
            return $0.providerID < $1.providerID
        }
    }

    private static func aggregateArtifactSizeIsValid(
        _ sizes: [Int]
    ) -> Bool {
        var total = 0
        for size in sizes {
            guard size >= 0,
                  size <= Self.maxTransactionBytes - total else {
                return false
            }
            total += size
        }
        return true
    }

    private static func providerScopeDigest(
        for records: [ProviderReadinessPersistenceRecord],
        migrationReceipt: String? = ProviderReadinessStore.providerScopeMigrationReceipt,
        previousVersionDigest: String? = nil,
        migrationCheckpoint: String? = nil,
        migrationEpoch: UInt64? = ProviderReadinessStore.providerScopeMigrationEpoch,
        cleanupTombstone: String? = nil,
        previousRoot: String? = ProviderReadinessStore.providerScopeMigrationPreviousRoot
    ) -> String {
        let identities = records
            .map { record in
                let providerID = ProviderReadinessRevision.canonicalProviderID(
                    record.providerID
                )
                let fingerprint = record.configurationFingerprint ?? ""
                // Length-prefix both fields so a delimiter-like character in
                // an opaque fingerprint cannot create an identity collision.
                return "\(providerID.utf8.count):\(providerID)"
                    + "\(fingerprint.utf8.count):\(fingerprint)"
            }
            .sorted()
            .joined(separator: "\u{1F}")
        let receipt = migrationReceipt ?? ""
        let previousDigest = previousVersionDigest ?? ""
        let checkpoint = migrationCheckpoint ?? ""
        let epoch = migrationEpoch.map(String.init) ?? ""
        let tombstone = cleanupTombstone ?? ""
        let rootProjection = previousRoot.map {
            "\($0.utf8.count):\($0)\u{1E}"
        } ?? ""
        let projection = "version:\(Self.providerScopeVersion)\u{1E}"
            + "\(receipt.utf8.count):\(receipt)"
            + "\(previousDigest.utf8.count):\(previousDigest)\u{1E}"
            + "\(epoch.utf8.count):\(epoch)"
            + "\(checkpoint.utf8.count):\(checkpoint)\u{1E}"
            + "\(tombstone.utf8.count):\(tombstone)\u{1E}"
            + rootProjection
            + identities
        return SHA256.hash(data: Data(projection.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func payloadDigest(
        schemaVersion: Int,
        transactionID: String,
        commitGeneration: UInt64,
        previousDigest: String?,
        providerScope: String?,
        providerScopeVersion: Int?,
        providerScopeMigrationReceipt: String?,
        providerScopePreviousVersionDigest: String?,
        providerScopeMigrationHistory: [ProviderScopeMigrationHistoryEntry]?,
        providerScopeMigrationCheckpoint: String?,
        providerScopeMigrationEpoch: UInt64?,
        providerScopeMigrationCleanupTombstone: String?,
        providerScopeMigrationPreviousRoot: String?,
        records: [ProviderReadinessPersistenceRecord]
    ) -> String? {
        let payload = SnapshotDigestPayload(
            schemaVersion: schemaVersion,
            transactionID: transactionID,
            commitGeneration: commitGeneration,
            previousDigest: previousDigest,
            providerScope: providerScope,
            providerScopeVersion: providerScopeVersion ?? Self.providerScopeVersion,
            providerScopeMigrationReceipt: providerScopeMigrationReceipt,
            providerScopePreviousVersionDigest: providerScopePreviousVersionDigest,
            providerScopeMigrationHistory: providerScopeMigrationHistory,
            providerScopeMigrationCheckpoint: providerScopeMigrationCheckpoint,
            providerScopeMigrationEpoch: providerScopeMigrationEpoch,
            providerScopeMigrationCleanupTombstone: providerScopeMigrationCleanupTombstone,
            providerScopeMigrationPreviousRoot: providerScopeMigrationPreviousRoot,
            records: records
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else { return nil }
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func isValidCommitGeneration(_ generation: UInt64?) -> Bool {
        guard let generation else { return true }
        return generation > 0
    }

    static func agreedHighestGenerationValue<Value: Equatable>(
        _ observations: [(generation: UInt64?, value: Value?)]
    ) -> Value? {
        guard let highest = observations.compactMap({ $0.generation }).max() else {
            return nil
        }
        let highestGenerationValues = observations.compactMap { observation in
            observation.generation == highest ? observation.value : nil
        }
        return highestGenerationValues.first.flatMap { expected in
            highestGenerationValues.allSatisfy { $0 == expected } ? expected : nil
        }
    }

    /// Keep the highest observed revision for the next write, but only retain
    /// a predecessor digest when the bounded artifact candidates agree on a
    /// single digest. A fork at the same generation must not mint a successor
    /// by choosing one candidate arbitrarily.
    private func observeCommitLineage(
        primary: Snapshot,
        journal: Snapshot?,
        marker: CommitMarker?
    ) {
        let observations = [
            (primary.commitGeneration, primary.transactionID, primary.previousDigest, primary.payloadDigest, primary.providerScope, primary.providerScopeVersion, primary.providerScopeMigrationReceipt, primary.providerScopePreviousVersionDigest, primary.providerScopeMigrationHistory, primary.providerScopeMigrationCheckpoint, primary.providerScopeMigrationEpoch, primary.providerScopeMigrationCleanupTombstone, primary.providerScopeMigrationPreviousRoot),
            (journal?.commitGeneration, journal?.transactionID, journal?.previousDigest, journal?.payloadDigest, journal?.providerScope, journal?.providerScopeVersion, journal?.providerScopeMigrationReceipt, journal?.providerScopePreviousVersionDigest, journal?.providerScopeMigrationHistory, journal?.providerScopeMigrationCheckpoint, journal?.providerScopeMigrationEpoch, journal?.providerScopeMigrationCleanupTombstone, journal?.providerScopeMigrationPreviousRoot),
            (marker?.commitGeneration, marker?.transactionID, marker?.previousDigest, marker?.payloadDigest, marker?.providerScope, marker?.providerScopeVersion, marker?.providerScopeMigrationReceipt, marker?.providerScopePreviousVersionDigest, marker?.providerScopeMigrationHistory, marker?.providerScopeMigrationCheckpoint, marker?.providerScopeMigrationEpoch, marker?.providerScopeMigrationCleanupTombstone, marker?.providerScopeMigrationPreviousRoot),
        ]
        lastObservedCommitGeneration = observations
            .compactMap { $0.0 }
            .max()
        guard let highest = lastObservedCommitGeneration else {
            lastObservedCommitTransactionID = nil
            lastObservedCommitPreviousDigest = nil
            lastObservedCommitLineageConflict = false
            lastObservedCommitDigest = nil
            lastObservedCommitProviderScope = nil
            lastObservedCommitProviderScopeVersion = nil
            lastObservedCommitProviderScopeMigrationReceipt = nil
            lastObservedCommitProviderScopePreviousVersionDigest = nil
            lastObservedCommitProviderScopeMigrationHistory = nil
            lastObservedCommitProviderScopeMigrationCheckpoint = nil
            lastObservedCommitProviderScopeMigrationEpoch = nil
            lastObservedCommitProviderScopeMigrationCleanupTombstone = nil
            lastObservedCommitProviderScopeMigrationPreviousRoot = nil
            return
        }
        let transactionIDs = Set(
            observations.compactMap { observation in
                observation.0 == highest ? observation.1 : nil
            }
        )
        lastObservedCommitTransactionID = transactionIDs.count == 1
            ? transactionIDs.first
            : nil
        let previousDigests = Set(
            observations.compactMap { observation in
                observation.0 == highest
                    ? (observation.2 ?? "<none>")
                    : nil
            }
        )
        lastObservedCommitLineageConflict = previousDigests.count > 1
        if previousDigests.count == 1, let previousDigest = previousDigests.first {
            lastObservedCommitPreviousDigest = previousDigest == "<none>"
                ? nil
                : previousDigest
        } else {
            // A nil and non-nil predecessor, or two different predecessors,
            // is a lineage fork. Retain no CAS predecessor so a later write
            // cannot advance an unresolved artifact set.
            lastObservedCommitPreviousDigest = nil
        }
        let digests = Set(
            observations.compactMap { observation in
                observation.0 == highest ? observation.3 : nil
            }
        )
        lastObservedCommitDigest = digests.count == 1 ? digests.first : nil
        let scopes = Set(
            observations.compactMap { observation in
                observation.0 == highest ? observation.4 : nil
            }
        )
        lastObservedCommitProviderScope = scopes.count == 1 ? scopes.first : nil
        let scopeVersions = Set(
            observations.compactMap { observation in
                observation.0 == highest ? observation.5 : nil
            }
        )
        lastObservedCommitProviderScopeVersion = scopeVersions.count == 1
            ? scopeVersions.first
            : nil
        let migrationReceipts = Set(
            observations.compactMap { observation in
                observation.0 == highest ? observation.6 : nil
            }
        )
        lastObservedCommitProviderScopeMigrationReceipt = migrationReceipts.count == 1
            ? migrationReceipts.first
            : nil
        let previousVersionDigests = Set(
            observations.compactMap { observation in
                observation.0 == highest ? observation.7 : nil
            }
        )
        lastObservedCommitProviderScopePreviousVersionDigest = previousVersionDigests.count == 1
            ? previousVersionDigests.first
            : nil
        lastObservedCommitProviderScopeMigrationHistory = Self.agreedHighestGenerationValue(
            observations.map { observation in
                (generation: observation.0, value: observation.8)
            }
        )
        let migrationCheckpoints = Set(
            observations.compactMap { observation in
                observation.0 == highest ? observation.9 : nil
            }
        )
        lastObservedCommitProviderScopeMigrationCheckpoint = migrationCheckpoints.count == 1
            ? migrationCheckpoints.first
            : nil
        let migrationEpochs = Set(
            observations.compactMap { observation in
                observation.0 == highest ? observation.10 : nil
            }
        )
        lastObservedCommitProviderScopeMigrationEpoch = migrationEpochs.count == 1
            ? migrationEpochs.first
            : nil
        let cleanupTombstones = Set(
            observations.compactMap { observation in
                observation.0 == highest ? observation.11 : nil
            }
        )
        lastObservedCommitProviderScopeMigrationCleanupTombstone = cleanupTombstones.count == 1
            ? cleanupTombstones.first
            : nil
        let previousRoots = Set(
            observations.compactMap { observation in
                observation.0 == highest ? observation.12 : nil
            }
        )
        lastObservedCommitProviderScopeMigrationPreviousRoot = previousRoots.count == 1
            ? previousRoots.first
            : nil
    }

    /// Recovery is intentionally bounded to the two on-disk snapshot
    /// candidates. If a committed marker identifies one candidate and that
    /// candidate names the other as its immediate digest predecessor, retain
    /// the successor as pending evidence. Any fork, replay, or stale
    /// predecessor remains empty and fail-closed; no artifact is rewritten.
    private static func boundedCommittedRecoveryCandidate(
        primary: Snapshot,
        journal: Snapshot?,
        marker: CommitMarker?
    ) -> Snapshot? {
        guard let journal,
              let marker,
              marker.state == .committed,
              let markerGeneration = marker.commitGeneration,
              let markerDigest = marker.payloadDigest else {
            return nil
        }
        let candidates = [primary, journal]
        guard candidates.count == 2 else { return nil }
        guard let candidateIndex = candidates.firstIndex(where: {
            $0.transactionID == marker.transactionID
                && $0.commitGeneration == markerGeneration
                && $0.payloadDigest == markerDigest
                && $0.previousDigest == marker.previousDigest
                && $0.providerScope == marker.providerScope
                && $0.providerScopeVersion == marker.providerScopeVersion
                && $0.providerScopeMigrationReceipt == marker.providerScopeMigrationReceipt
                && $0.providerScopePreviousVersionDigest == marker.providerScopePreviousVersionDigest
                && $0.providerScopeMigrationHistory == marker.providerScopeMigrationHistory
                && $0.providerScopeMigrationCheckpoint == marker.providerScopeMigrationCheckpoint
                && $0.providerScopeMigrationEpoch == marker.providerScopeMigrationEpoch
                && $0.providerScopeMigrationCleanupTombstone == marker.providerScopeMigrationCleanupTombstone
                && $0.providerScopeMigrationPreviousRoot == marker.providerScopeMigrationPreviousRoot
        }) else {
            return nil
        }
        let predecessor = candidates[1 - candidateIndex]
        guard let candidateGeneration = candidates[candidateIndex].commitGeneration,
              let predecessorGeneration = predecessor.commitGeneration,
              predecessorGeneration < UInt64.max,
              candidateGeneration == predecessorGeneration + 1,
              let predecessorDigest = predecessor.payloadDigest,
              candidates[candidateIndex].previousDigest == predecessorDigest,
              migrationEpochHandoffIsValid(
                  successor: candidates[candidateIndex],
                  predecessor: predecessor
              ) else {
            return nil
        }
        return candidates[candidateIndex]
    }

    /// A prepared marker can be the first durable artifact of a successor
    /// transaction. If the primary and journal still agree on the previous
    /// committed pair, retain that pair as pending evidence instead of
    /// discarding it merely because the successor never committed.
    private static func preparedSuccessorRecoveryCandidate(
        primary: Snapshot,
        journal: Snapshot?,
        marker: CommitMarker?
    ) -> Snapshot? {
        guard let journal,
              let marker,
              marker.state == .prepared,
              let primaryTransactionID = primary.transactionID,
              let journalTransactionID = journal.transactionID,
              let primaryGeneration = primary.commitGeneration,
              let journalGeneration = journal.commitGeneration,
              let markerGeneration = marker.commitGeneration,
              primaryGeneration < UInt64.max,
              journalTransactionID == primaryTransactionID,
              journalGeneration == primaryGeneration,
              journal.previousDigest == primary.previousDigest,
              journal.payloadDigest == primary.payloadDigest,
              marker.transactionID != primaryTransactionID,
              markerGeneration == primaryGeneration + 1,
              marker.previousDigest == primary.payloadDigest,
              primary.payloadDigest != nil,
              Self.snapshotPayloadDigestMatches(primary),
              Self.snapshotPayloadDigestMatches(journal) else {
            return nil
        }
        return primary
    }

    /// A compacted migration history may cross exactly one epoch boundary,
    /// but only when the successor carries the predecessor checkpoint as its
    /// root. Same-epoch recovery must retain the same root; timestamps and
    /// tombstone labels are never sufficient to authorize a handoff.
    private static func migrationEpochHandoffIsValid(
        successor: Snapshot,
        predecessor: Snapshot
    ) -> Bool {
        guard let successorEpoch = successor.providerScopeMigrationEpoch,
              let predecessorEpoch = predecessor.providerScopeMigrationEpoch else {
            return false
        }
        if successorEpoch == predecessorEpoch {
            return successor.providerScopeMigrationPreviousRoot
                == predecessor.providerScopeMigrationPreviousRoot
        }
        guard predecessorEpoch < UInt64.max,
              successorEpoch == predecessorEpoch + 1,
              let successorRoot = successor.providerScopeMigrationPreviousRoot,
              isCanonicalDigest(successorRoot),
              successorRoot == predecessor.providerScopeMigrationCheckpoint else {
            return false
        }
        return true
    }

    private static func commitValidationFailure(
        primary: Snapshot,
        journal: Snapshot?,
        journalExists: Bool,
        marker: CommitMarker?,
        markerExists: Bool
    ) -> ProviderReadinessStoreRecoveryState? {
        guard let primaryTransactionID = primary.transactionID else {
            return !journalExists && !markerExists
                ? nil
                : .incompleteTransaction
        }
        guard let journal,
              let journalTransactionID = journal.transactionID,
              let primaryGeneration = primary.commitGeneration,
              let journalGeneration = journal.commitGeneration,
              let marker,
              let markerGeneration = marker.commitGeneration else {
            return .incompleteTransaction
        }
        guard Self.isValidCommitGeneration(primaryGeneration),
              Self.isValidCommitGeneration(journalGeneration),
              Self.isValidCommitGeneration(markerGeneration) else {
            return .incompleteTransaction
        }
        guard journalTransactionID == primaryTransactionID,
              marker.transactionID == primaryTransactionID,
              journalGeneration == primaryGeneration,
              markerGeneration == primaryGeneration else {
            return .transactionIdentityMismatch
        }
        guard primary.previousDigest == journal.previousDigest,
              primary.previousDigest == marker.previousDigest,
              primary.providerScope == journal.providerScope,
              primary.providerScope == marker.providerScope,
              primary.providerScopeVersion == journal.providerScopeVersion,
              primary.providerScopeVersion == marker.providerScopeVersion,
              primary.providerScopeMigrationReceipt == journal.providerScopeMigrationReceipt,
              primary.providerScopeMigrationReceipt == marker.providerScopeMigrationReceipt,
              primary.providerScopePreviousVersionDigest == journal.providerScopePreviousVersionDigest,
              primary.providerScopePreviousVersionDigest == marker.providerScopePreviousVersionDigest,
              primary.providerScopeMigrationHistory == journal.providerScopeMigrationHistory,
              primary.providerScopeMigrationHistory == marker.providerScopeMigrationHistory,
              primary.providerScopeMigrationCheckpoint == journal.providerScopeMigrationCheckpoint,
              primary.providerScopeMigrationCheckpoint == marker.providerScopeMigrationCheckpoint,
              primary.providerScopeMigrationEpoch == journal.providerScopeMigrationEpoch,
              primary.providerScopeMigrationEpoch == marker.providerScopeMigrationEpoch,
              primary.providerScopeMigrationCleanupTombstone == journal.providerScopeMigrationCleanupTombstone,
              primary.providerScopeMigrationCleanupTombstone == marker.providerScopeMigrationCleanupTombstone,
              primary.providerScopeMigrationPreviousRoot == journal.providerScopeMigrationPreviousRoot,
              primary.providerScopeMigrationPreviousRoot == marker.providerScopeMigrationPreviousRoot else {
            return .transactionIdentityMismatch
        }
        guard marker.state == .committed else {
            return .incompleteTransaction
        }
        guard let primaryDigest = primary.payloadDigest,
              let journalDigest = journal.payloadDigest,
              let markerDigest = marker.payloadDigest,
              primaryDigest == journalDigest,
              markerDigest == primaryDigest else {
            return .incompleteTransaction
        }
        return nil
    }

    private static func journalCommitIsComplete(
        _ journal: Snapshot,
        marker: CommitMarker?,
        markerExists: Bool
    ) -> Bool {
        guard let journalTransactionID = journal.transactionID,
              let journalGeneration = journal.commitGeneration,
              let marker,
              let markerGeneration = marker.commitGeneration else {
            return !markerExists && journal.transactionID == nil
        }
        guard Self.isValidCommitGeneration(journalGeneration),
              Self.isValidCommitGeneration(markerGeneration) else {
            return false
        }
        return marker.state == .committed
            && marker.transactionID == journalTransactionID
            && markerGeneration == journalGeneration
            && marker.previousDigest == journal.previousDigest
            && marker.providerScope == journal.providerScope
            && marker.providerScopeVersion == journal.providerScopeVersion
            && marker.providerScopeMigrationReceipt == journal.providerScopeMigrationReceipt
            && marker.providerScopePreviousVersionDigest == journal.providerScopePreviousVersionDigest
            && marker.providerScopeMigrationHistory == journal.providerScopeMigrationHistory
            && marker.providerScopeMigrationCheckpoint == journal.providerScopeMigrationCheckpoint
            && marker.providerScopeMigrationEpoch == journal.providerScopeMigrationEpoch
            && marker.providerScopeMigrationCleanupTombstone == journal.providerScopeMigrationCleanupTombstone
            && marker.providerScopeMigrationPreviousRoot == journal.providerScopeMigrationPreviousRoot
            && marker.payloadDigest == journal.payloadDigest
            && marker.payloadDigest != nil
    }

    private func nextCommitGeneration() throws -> UInt64 {
        guard let lastObservedCommitGeneration else { return 1 }
        guard lastObservedCommitGeneration < UInt64.max else {
            throw PersistenceFileError.invalidJSON
        }
        return lastObservedCommitGeneration + 1
    }

    private static func validatePersistedJSON(_ data: Data) throws {
        guard String(data: data, encoding: .utf8) != nil else {
            throw PersistenceFileError.invalidJSON
        }
        var validator = JSONDuplicateKeyValidator(
            bytes: Array(data),
            maxDepth: Self.maxPersistedJSONDepth,
            maxObjectKeys: Self.maxPersistedObjectKeys,
            maxStringBytes: Self.maxPersistedStringBytes,
            canonicalIntegerKeys: [
                "commitGeneration",
                "providerScopeVersion",
                "fromVersion",
                "toVersion",
                "providerScopeMigrationEpoch",
            ]
        )
        try validator.validate()
        guard let object = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              (Set(object.keys) == ["schemaVersion", "records"]
                || Set(object.keys) == ["schemaVersion", "transactionID", "records"]
                || Set(object.keys) == ["schemaVersion", "transactionID", "commitGeneration", "records"]
                || Set(object.keys) == ["schemaVersion", "transactionID", "commitGeneration", "payloadDigest", "records"]
                || Set(object.keys) == ["schemaVersion", "transactionID", "commitGeneration", "previousDigest", "payloadDigest", "records"]
                || Set(object.keys) == ["schemaVersion", "transactionID", "commitGeneration", "previousDigest", "providerScope", "providerScopeVersion", "providerScopeMigrationReceipt", "providerScopePreviousVersionDigest", "providerScopeMigrationHistory", "providerScopeMigrationCheckpoint", "providerScopeMigrationEpoch", "providerScopeMigrationCleanupTombstone", "payloadDigest", "records"]
                || Set(object.keys) == ["schemaVersion", "transactionID", "commitGeneration", "previousDigest", "providerScope", "providerScopeVersion", "providerScopeMigrationReceipt", "providerScopePreviousVersionDigest", "providerScopeMigrationHistory", "providerScopeMigrationCheckpoint", "providerScopeMigrationEpoch", "providerScopeMigrationCleanupTombstone", "providerScopeMigrationPreviousRoot", "payloadDigest", "records"]),
              let rawRecords = object["records"] as? [Any],
              rawRecords.allSatisfy({ rawRecord in
                  guard let record = rawRecord as? [String: Any] else {
                      return false
                  }
                  return Set(record.keys).isSubset(
                      of: ProviderReadinessPersistenceRecord.allowedCodingKeys
                  )
              }) else {
            throw PersistenceFileError.invalidJSON
        }
    }

    private static func conflictingBatchKeys(
        _ records: [ProviderReadinessPersistenceRecord]
    ) -> Set<ProviderReadinessPersistenceKey> {
        var firstByKey: [ProviderReadinessPersistenceKey: ProviderReadinessPersistenceRecord] = [:]
        var conflicts: Set<ProviderReadinessPersistenceKey> = []
        for record in records where record.isValid {
            if let first = firstByKey[record.key],
               first.checkedAt == record.checkedAt,
               first != record {
                conflicts.insert(record.key)
                continue
            }
            guard let first = firstByKey[record.key],
                  first.checkedAt >= record.checkedAt else {
                firstByKey[record.key] = record
                continue
            }
        }
        return conflicts
    }

    private static func isReplayedHealthReceipt(
        _ candidate: ProviderReadinessPersistenceRecord,
        after current: ProviderReadinessPersistenceRecord
    ) -> Bool {
        guard candidate.checkedAt > current.checkedAt,
              let candidateEvidenceID = candidate.evidenceID,
              let currentEvidenceID = current.evidenceID else {
            return false
        }
        return candidateEvidenceID == currentEvidenceID
    }

    private static func normalizedProviderIDs(
        _ providerIDs: Set<String>
    ) -> Set<String> {
        Set(providerIDs.map(ProviderReadinessRevision.canonicalProviderID))
    }

    private static func mergeRestoredRecord(
        _ current: ProviderReadinessPersistenceRecord,
        with candidate: ProviderReadinessPersistenceRecord
    ) -> ProviderReadinessPersistenceRecord {
        // A single provider/model/configuration generation may not carry two
        // different discovery or Apply receipts. Timestamps are not enough
        // to establish receipt authority after reload: choosing the newer
        // row could replay an old result and mint a selectable snapshot.
        if current.discoveryReceiptID != candidate.discoveryReceiptID
            || current.applyReceiptID != candidate.applyReceiptID {
            let selected = tieBreakKey(current) <= tieBreakKey(candidate)
                ? current
                : candidate
            return selected.downgradedToPending()
        }
        if current.checkedAt > candidate.checkedAt { return current }
        if candidate.checkedAt > current.checkedAt { return candidate }
        guard current != candidate else { return current }
        let selected = tieBreakKey(current) <= tieBreakKey(candidate)
            ? current
            : candidate
        return selected.downgradedToPending()
    }

    private static func tieBreakKey(
        _ record: ProviderReadinessPersistenceRecord
    ) -> String {
        [
            record.providerID,
            record.modelID,
            record.configurationGeneration,
            record.status.rawValue,
            record.readinessState.rawValue,
            String(record.checkedAt.timeIntervalSinceReferenceDate),
            record.errorCategory?.rawValue ?? "",
            String(record.latency ?? -1),
            record.evidenceID ?? "",
            String(record.isApplied),
            record.discoveryReceiptID,
            String(record.discoveredAt.timeIntervalSinceReferenceDate),
            record.applyReceiptID ?? "",
            record.appliedAt.map { String($0.timeIntervalSinceReferenceDate) } ?? "",
            record.configurationFingerprint ?? "",
            record.expiresAt.map { String($0.timeIntervalSinceReferenceDate) } ?? "",
        ].joined(separator: "\u{1F}")
    }

    private static func readSafeFile(
        at url: URL,
        maxBytes: Int
    ) -> (data: Data, identity: FileIdentity)? {
        let parentURL = url.deletingLastPathComponent()
        guard let parentPathIdentity = pathIdentity(at: parentURL.path) else {
            return nil
        }
        let parentDescriptor = open(
            parentURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW
        )
        guard parentDescriptor >= 0,
              let parentIdentity = descriptorIdentity(parentDescriptor),
              parentPathIdentity == parentIdentity else {
            if parentDescriptor >= 0 { close(parentDescriptor) }
            return nil
        }
        defer { close(parentDescriptor) }

        let descriptor = openat(
            parentDescriptor,
            url.lastPathComponent,
            O_RDONLY | O_NOFOLLOW
        )
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        guard let initialIdentity = descriptorIdentity(descriptor),
              initialIdentity.isSafeRegularFile else {
            return nil
        }
        var data = Data()
        data.reserveCapacity(min(maxBytes, 64 * 1024))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            guard count >= 0 else { return nil }
            guard count > 0 else { break }
            guard data.count <= maxBytes - count else { return nil }
            data.append(contentsOf: buffer[0..<count])
        }

        guard descriptorIdentity(descriptor) == initialIdentity,
              pathIdentity(at: url.path) == initialIdentity,
              pathIdentity(at: parentURL.path) == parentIdentity else {
            return nil
        }
        return (data, initialIdentity)
    }

    private func quarantineCorruptSnapshot() {
        guard let baselineFileIdentity,
              baselineFileIdentity.isSafeRegularFile,
              Self.pathIdentity(at: fileURL.path) == baselineFileIdentity else {
            return
        }
        let quarantineURL = fileURL.deletingLastPathComponent().appendingPathComponent(
            "\(fileURL.lastPathComponent).corrupt-\(UUID().uuidString)"
        )
        do {
            try FileManager.default.moveItem(at: fileURL, to: quarantineURL)
            baselineData = nil
            self.baselineFileIdentity = nil
        } catch {
            // Keep the observed baseline when quarantine itself fails; a
            // later write must still fail closed against the unchanged file.
        }
    }

    private func sortedRecords() -> [ProviderReadinessPersistenceRecord] {
        storedRecords.values.sorted {
            if $0.providerID == $1.providerID {
                if $0.modelID == $1.modelID {
                    return $0.configurationGeneration < $1.configurationGeneration
                }
                return $0.modelID < $1.modelID
            }
            return $0.providerID < $1.providerID
        }
    }

    /// A failed CAS or atomic replacement leaves the previous committed bytes
    /// on disk, but that snapshot may have been actionable only in this stale
    /// process. Retain its identity as pending evidence so a failed writer
    /// cannot continue exposing a green picker row after losing the commit.
    private func restorePendingSnapshotAfterPersistenceFailure(
        _ previous: [ProviderReadinessPersistenceKey: ProviderReadinessPersistenceRecord]
    ) {
        storedRecords = previous.mapValues { $0.downgradedToPending() }
    }

    private static func pathIdentity(at path: String) -> FileIdentity? {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else { return nil }
        return FileIdentity(metadata)
    }

    private static func descriptorIdentity(_ descriptor: Int32) -> FileIdentity? {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { return nil }
        return FileIdentity(metadata)
    }

    private func writeSnapshotAtomically(
        _ data: Data,
        to targetURL: URL,
        expectedIdentity: FileIdentity?,
        maxBytes: Int
    ) throws -> FileIdentity {
        guard data.count <= maxBytes else {
            throw PersistenceFileError.invalidJSON
        }
        let parentURL = targetURL.deletingLastPathComponent()
        let parentPathIdentity = Self.pathIdentity(at: parentURL.path)
        let parentDescriptor = open(
            parentURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW
        )
        guard parentDescriptor >= 0,
              let parentIdentity = Self.descriptorIdentity(parentDescriptor),
              parentPathIdentity == parentIdentity else {
            if parentDescriptor >= 0 { close(parentDescriptor) }
            throw PersistenceFileError.filesystemBoundary(stage: .parentDirectoryIdentity)
        }
        defer { close(parentDescriptor) }

        let targetName = targetURL.lastPathComponent
        let currentTarget = Self.fileIdentity(
            at: parentDescriptor,
            name: targetName
        )
        guard currentTarget == expectedIdentity,
              currentTarget == nil || currentTarget?.isSafeRegularFile == true else {
            throw PersistenceFileError.filesystemBoundary(stage: .targetIdentity)
        }

        let temporaryName = ".\(targetName).tmp-\(UUID().uuidString)"
        let temporaryDescriptor = openat(
            parentDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard temporaryDescriptor >= 0 else {
            throw PersistenceFileError.filesystemBoundary(stage: .temporaryOpen)
        }
        var didReplace = false
        defer {
            close(temporaryDescriptor)
            if !didReplace {
                _ = unlinkat(parentDescriptor, temporaryName, 0)
            }
        }

        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(
                    temporaryDescriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                guard written > 0 else {
                    throw PersistenceFileError.filesystemBoundary(stage: .temporaryWrite)
                }
                offset += written
            }
        }
        guard fsync(temporaryDescriptor) == 0,
              let temporaryIdentity = Self.fileIdentity(
                  at: parentDescriptor,
                  name: temporaryName
              ),
              temporaryIdentity.isSafeRegularFile else {
            throw PersistenceFileError.filesystemBoundary(stage: .temporarySyncIdentity)
        }
        guard renameat(
            parentDescriptor,
            temporaryName,
            parentDescriptor,
            targetName
        ) == 0 else {
            throw PersistenceFileError.filesystemBoundary(stage: .targetRename)
        }
        didReplace = true
        guard fsync(parentDescriptor) == 0,
              let currentParentIdentity = Self.pathIdentity(at: parentURL.path),
              currentParentIdentity.matchesDirectoryObject(parentIdentity),
              let replacementIdentity = Self.fileIdentity(
                  at: parentDescriptor,
                  name: targetName
              ),
              replacementIdentity.isSafeRegularFile else {
            throw PersistenceFileError.filesystemBoundary(stage: .committedDirectoryIdentity)
        }
        return replacementIdentity
    }

    private static func fileIdentity(
        at parentDescriptor: Int32,
        name: String
    ) -> FileIdentity? {
        var metadata = stat()
        guard fstatat(
            parentDescriptor,
            name,
            &metadata,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            return nil
        }
        return FileIdentity(metadata)
    }

    /// Serialize writers across processes as well as across store instances.
    /// The lock is deliberately a separate descriptor: replacing the JSON
    /// file must not invalidate a lock held by another process.  O_NOFOLLOW
    /// and the descriptor checks keep an unexpected lock target fail-closed.
    private func withExclusiveFileLock<Result>(
        _ body: () throws -> Result
    ) throws -> Result {
        let parentURL = fileURL.deletingLastPathComponent()
        guard let parentPathIdentity = Self.pathIdentity(at: parentURL.path) else {
            throw PersistenceFileError.lockUnavailable
        }
        let parentDescriptor = open(
            parentURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW
        )
        guard parentDescriptor >= 0,
              let parentIdentity = Self.descriptorIdentity(parentDescriptor),
              parentPathIdentity == parentIdentity else {
            if parentDescriptor >= 0 { close(parentDescriptor) }
            throw PersistenceFileError.lockUnavailable
        }
        defer { close(parentDescriptor) }

        let lockName = fileURL.lastPathComponent + ".lock"
        let descriptor = openat(
            parentDescriptor,
            lockName,
            O_CREAT | O_RDWR | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw PersistenceFileError.lockIdentityInvalid(stage: .lockFileOpen)
        }
        defer { close(descriptor) }

        guard let lockIdentity = Self.descriptorIdentity(descriptor) else {
            throw PersistenceFileError.lockIdentityInvalid(stage: .lockFileDescriptorIdentity)
        }
        guard lockIdentity.isSafeRegularFile else {
            throw PersistenceFileError.lockIdentityInvalid(stage: .lockFileSafeRegularFile)
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw PersistenceFileError.lockUnavailable
        }
        defer { _ = flock(descriptor, LOCK_UN) }

        guard let currentParentIdentity = Self.pathIdentity(at: parentURL.path),
              currentParentIdentity.matchesDirectoryObject(parentIdentity) else {
            throw PersistenceFileError.lockIdentityInvalid(
                stage: .lockParentIdentityAfterAcquisition
            )
        }
        return try body()
    }

    @discardableResult
    private func persistLocked(preservingRecoveryState: Bool = false) -> Bool {
        Self.fileCoordinationLock.lock()
        defer { Self.fileCoordinationLock.unlock() }

        do {
            try withExclusiveFileLock {
                let diskFileExists = FileManager.default.fileExists(atPath: fileURL.path)
                if case .incompleteTransaction = recoveryState,
                   !diskFileExists {
                    throw PersistenceFileError.invalidJSON
                }
                guard !lastObservedCommitLineageConflict else {
                    throw PersistenceFileError.invalidJSON
                }
                let diskRead = Self.readSafeFile(
                    at: fileURL,
                    maxBytes: Self.maxSnapshotBytes
                )
                guard diskRead != nil || !diskFileExists else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .primaryPresence)
                }
                guard diskRead?.data == baselineData else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .primaryData)
                }
                guard diskRead?.identity == baselineFileIdentity else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .primaryFileIdentity)
                }
                let diskSnapshot = diskRead.flatMap { Self.decodeVerifiedSnapshot($0.data) }
                guard diskSnapshot?.commitGeneration == lastObservedCommitGeneration else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .primaryCommitGeneration)
                }
                guard diskSnapshot?.transactionID == lastObservedCommitTransactionID else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .primaryTransactionID)
                }
                guard diskSnapshot?.previousDigest == lastObservedCommitPreviousDigest else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .primaryPreviousDigest)
                }
                guard diskSnapshot?.providerScope == lastObservedCommitProviderScope else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .primaryProviderScope)
                }
                guard diskSnapshot?.providerScopeVersion == lastObservedCommitProviderScopeVersion else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .primaryProviderScopeVersion)
                }
                guard diskSnapshot?.providerScopeMigrationReceipt == lastObservedCommitProviderScopeMigrationReceipt else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .primaryMigrationReceipt)
                }
                guard diskSnapshot?.providerScopePreviousVersionDigest == lastObservedCommitProviderScopePreviousVersionDigest else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .primaryPreviousVersionDigest)
                }
                guard diskSnapshot?.providerScopeMigrationHistory == lastObservedCommitProviderScopeMigrationHistory else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .primaryMigrationHistory)
                }
                guard diskSnapshot?.providerScopeMigrationCheckpoint == lastObservedCommitProviderScopeMigrationCheckpoint else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .primaryMigrationCheckpoint)
                }
                guard diskSnapshot?.providerScopeMigrationEpoch == lastObservedCommitProviderScopeMigrationEpoch else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .primaryMigrationEpoch)
                }
                guard diskSnapshot?.providerScopeMigrationCleanupTombstone == lastObservedCommitProviderScopeMigrationCleanupTombstone else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .primaryMigrationCleanupTombstone)
                }
                guard diskSnapshot?.providerScopeMigrationPreviousRoot == lastObservedCommitProviderScopeMigrationPreviousRoot else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .primaryMigrationPreviousRoot)
                }
                let journalFileExists = FileManager.default.fileExists(atPath: journalURL.path)
                let markerFileExists = FileManager.default.fileExists(atPath: commitMarkerURL.path)
                let diskJournalRead = Self.readSafeFile(
                    at: journalURL,
                    maxBytes: Self.maxSnapshotBytes
                )
                let diskMarkerRead = Self.readSafeFile(
                    at: commitMarkerURL,
                    maxBytes: Self.maxPersistedStringBytes
                )
                let diskJournal = diskJournalRead.flatMap { Self.decodeVerifiedSnapshot($0.data) }
                let diskMarker = diskMarkerRead.flatMap { Self.decodeCommitMarker($0.data) }
                guard diskJournalRead != nil || !journalFileExists else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .journalPresence)
                }
                guard diskMarkerRead != nil || !markerFileExists else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .markerPresence)
                }
                guard diskJournal?.commitGeneration == lastObservedCommitGeneration else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .journalCommitGeneration)
                }
                guard diskJournal?.transactionID == lastObservedCommitTransactionID else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .journalTransactionID)
                }
                guard diskJournal?.previousDigest == lastObservedCommitPreviousDigest else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .journalPreviousDigest)
                }
                guard diskJournal?.providerScope == lastObservedCommitProviderScope else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .journalProviderScope)
                }
                guard diskJournal?.providerScopeVersion == lastObservedCommitProviderScopeVersion else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .journalProviderScopeVersion)
                }
                guard diskJournal?.providerScopeMigrationReceipt == lastObservedCommitProviderScopeMigrationReceipt else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .journalMigrationReceipt)
                }
                guard diskJournal?.providerScopePreviousVersionDigest == lastObservedCommitProviderScopePreviousVersionDigest else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .journalPreviousVersionDigest)
                }
                guard diskJournal?.providerScopeMigrationHistory == lastObservedCommitProviderScopeMigrationHistory else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .journalMigrationHistory)
                }
                guard diskJournal?.providerScopeMigrationCheckpoint == lastObservedCommitProviderScopeMigrationCheckpoint else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .journalMigrationCheckpoint)
                }
                guard diskJournal?.providerScopeMigrationEpoch == lastObservedCommitProviderScopeMigrationEpoch else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .journalMigrationEpoch)
                }
                guard diskJournal?.providerScopeMigrationCleanupTombstone == lastObservedCommitProviderScopeMigrationCleanupTombstone else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .journalMigrationCleanupTombstone)
                }
                guard diskJournal?.providerScopeMigrationPreviousRoot == lastObservedCommitProviderScopeMigrationPreviousRoot else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .journalMigrationPreviousRoot)
                }
                guard diskMarker?.commitGeneration == lastObservedCommitGeneration else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .markerCommitGeneration)
                }
                guard diskMarker?.transactionID == lastObservedCommitTransactionID else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .markerTransactionID)
                }
                guard diskMarker?.previousDigest == lastObservedCommitPreviousDigest else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .markerPreviousDigest)
                }
                guard diskMarker?.providerScope == lastObservedCommitProviderScope else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .markerProviderScope)
                }
                guard diskMarker?.providerScopeVersion == lastObservedCommitProviderScopeVersion else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .markerProviderScopeVersion)
                }
                guard diskMarker?.providerScopeMigrationReceipt == lastObservedCommitProviderScopeMigrationReceipt else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .markerMigrationReceipt)
                }
                guard diskMarker?.providerScopePreviousVersionDigest == lastObservedCommitProviderScopePreviousVersionDigest else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .markerPreviousVersionDigest)
                }
                guard diskMarker?.providerScopeMigrationHistory == lastObservedCommitProviderScopeMigrationHistory else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .markerMigrationHistory)
                }
                guard diskMarker?.providerScopeMigrationCheckpoint == lastObservedCommitProviderScopeMigrationCheckpoint else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .markerMigrationCheckpoint)
                }
                guard diskMarker?.providerScopeMigrationEpoch == lastObservedCommitProviderScopeMigrationEpoch else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .markerMigrationEpoch)
                }
                guard diskMarker?.providerScopeMigrationCleanupTombstone == lastObservedCommitProviderScopeMigrationCleanupTombstone else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .markerMigrationCleanupTombstone)
                }
                guard diskMarker?.providerScopeMigrationPreviousRoot == lastObservedCommitProviderScopeMigrationPreviousRoot else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .markerMigrationPreviousRoot)
                }
                guard Self.pathIdentity(at: fileURL.path) == baselineFileIdentity else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .primaryPathIdentity)
                }
                guard Self.pathIdentity(at: journalURL.path) == baselineJournalFileIdentity else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .journalPathIdentity)
                }
                guard Self.pathIdentity(at: commitMarkerURL.path) == baselineCommitMarkerIdentity else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .markerPathIdentity)
                }

                let transactionID = UUID().uuidString
                guard transactionID != lastObservedCommitTransactionID else {
                    throw PersistenceFileError.invalidJSON
                }
                let commitGeneration = try nextCommitGeneration()
                let previousDigest: String?
                if lastObservedCommitGeneration != nil {
                    guard let observedDigest = lastObservedCommitDigest else {
                        throw PersistenceFileError.invalidJSON
                    }
                    previousDigest = observedDigest
                } else {
                    previousDigest = nil
                }
                let migrationHistory = Self.nativeProviderScopeMigrationHistory
                guard let migrationCheckpoint = Self.migrationCheckpoint(
                    history: migrationHistory,
                    epoch: Self.providerScopeMigrationEpoch,
                    cleanupTombstone: Self.providerScopeMigrationCleanupTombstone,
                    previousRoot: Self.providerScopeMigrationPreviousRoot
                ) else {
                    throw PersistenceFileError.invalidJSON
                }
                let providerScope = Self.providerScopeDigest(
                    for: sortedRecords(),
                    migrationReceipt: Self.providerScopeMigrationReceipt,
                    previousVersionDigest: nil,
                    migrationCheckpoint: migrationCheckpoint,
                    migrationEpoch: Self.providerScopeMigrationEpoch,
                    cleanupTombstone: Self.providerScopeMigrationCleanupTombstone,
                    previousRoot: Self.providerScopeMigrationPreviousRoot
                )
                let digest = Self.payloadDigest(
                    schemaVersion: Self.schemaVersion,
                    transactionID: transactionID,
                    commitGeneration: commitGeneration,
                    previousDigest: previousDigest,
                    providerScope: providerScope,
                    providerScopeVersion: Self.providerScopeVersion,
                    providerScopeMigrationReceipt: Self.providerScopeMigrationReceipt,
                    providerScopePreviousVersionDigest: nil,
                    providerScopeMigrationHistory: migrationHistory,
                    providerScopeMigrationCheckpoint: migrationCheckpoint,
                    providerScopeMigrationEpoch: Self.providerScopeMigrationEpoch,
                    providerScopeMigrationCleanupTombstone: Self.providerScopeMigrationCleanupTombstone,
                    providerScopeMigrationPreviousRoot: Self.providerScopeMigrationPreviousRoot,
                    records: sortedRecords()
                )
                guard let digest else {
                    throw PersistenceFileError.invalidJSON
                }
                let snapshot = Snapshot(
                    schemaVersion: Self.schemaVersion,
                    transactionID: transactionID,
                    commitGeneration: commitGeneration,
                    previousDigest: previousDigest,
                    providerScope: providerScope,
                    providerScopeVersion: Self.providerScopeVersion,
                    providerScopeMigrationReceipt: Self.providerScopeMigrationReceipt,
                    providerScopePreviousVersionDigest: nil,
                    providerScopeMigrationHistory: migrationHistory,
                    providerScopeMigrationCheckpoint: migrationCheckpoint,
                    providerScopeMigrationEpoch: Self.providerScopeMigrationEpoch,
                    providerScopeMigrationCleanupTombstone: Self.providerScopeMigrationCleanupTombstone,
                    providerScopeMigrationPreviousRoot: Self.providerScopeMigrationPreviousRoot,
                    payloadDigest: digest,
                    records: sortedRecords()
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let encodedData = try encoder.encode(snapshot)
                // Reserve the transaction before replacing either snapshot.
                // A crash after this point leaves an explicit `prepared`
                // marker, so startup cannot mistake a half-written pair for
                // a committed provider snapshot.
                let preparedMarkerData = try encoder.encode(CommitMarker(
                    schemaVersion: Self.schemaVersion,
                    transactionID: transactionID,
                    commitGeneration: commitGeneration,
                    previousDigest: previousDigest,
                    providerScope: providerScope,
                    providerScopeVersion: Self.providerScopeVersion,
                    providerScopeMigrationReceipt: Self.providerScopeMigrationReceipt,
                    providerScopePreviousVersionDigest: nil,
                    providerScopeMigrationHistory: migrationHistory,
                    providerScopeMigrationCheckpoint: migrationCheckpoint,
                    providerScopeMigrationEpoch: Self.providerScopeMigrationEpoch,
                    providerScopeMigrationCleanupTombstone: Self.providerScopeMigrationCleanupTombstone,
                    providerScopeMigrationPreviousRoot: Self.providerScopeMigrationPreviousRoot,
                    payloadDigest: digest,
                    state: .prepared
                ))
                let markerData = try encoder.encode(CommitMarker(
                    schemaVersion: Self.schemaVersion,
                    transactionID: transactionID,
                    commitGeneration: commitGeneration,
                    previousDigest: previousDigest,
                    providerScope: providerScope,
                    providerScopeVersion: Self.providerScopeVersion,
                    providerScopeMigrationReceipt: Self.providerScopeMigrationReceipt,
                    providerScopePreviousVersionDigest: nil,
                    providerScopeMigrationHistory: migrationHistory,
                    providerScopeMigrationCheckpoint: migrationCheckpoint,
                    providerScopeMigrationEpoch: Self.providerScopeMigrationEpoch,
                    providerScopeMigrationCleanupTombstone: Self.providerScopeMigrationCleanupTombstone,
                    payloadDigest: digest,
                    state: .committed
                ))
                guard Self.aggregateArtifactSizeIsValid(
                    [encodedData.count, encodedData.count, markerData.count]
                ) else {
                    throw PersistenceFileError.invalidJSON
                }
                baselineCommitMarkerIdentity = try writeSnapshotAtomically(
                    preparedMarkerData,
                    to: commitMarkerURL,
                    expectedIdentity: baselineCommitMarkerIdentity,
                    maxBytes: Self.maxPersistedStringBytes
                )
                // Keep the journal at the same revision as the primary. If
                // either replacement is interrupted, the prepared marker
                // fences both artifacts and recovery remains non-actionable.
                baselineJournalFileIdentity = try writeSnapshotAtomically(
                    encodedData,
                    to: journalURL,
                    expectedIdentity: baselineJournalFileIdentity,
                    maxBytes: Self.maxSnapshotBytes
                )
                baselineFileIdentity = try writeSnapshotAtomically(
                    encodedData,
                    to: fileURL,
                    expectedIdentity: baselineFileIdentity,
                    maxBytes: Self.maxSnapshotBytes
                )
                baselineCommitMarkerIdentity = try writeSnapshotAtomically(
                    markerData,
                    to: commitMarkerURL,
                    expectedIdentity: baselineCommitMarkerIdentity,
                    maxBytes: Self.maxPersistedStringBytes
                )
                let verifiedPrimaryRead = Self.readSafeFile(
                    at: fileURL,
                    maxBytes: Self.maxSnapshotBytes
                )
                let verifiedJournalRead = Self.readSafeFile(
                    at: journalURL,
                    maxBytes: Self.maxSnapshotBytes
                )
                let verifiedMarkerRead = Self.readSafeFile(
                    at: commitMarkerURL,
                    maxBytes: Self.maxPersistedStringBytes
                )
                guard let verifiedPrimaryRead else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .verifiedPrimaryRead)
                }
                guard let verifiedJournalRead else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .verifiedJournalRead)
                }
                guard let verifiedMarkerRead else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .verifiedMarkerRead)
                }
                guard verifiedPrimaryRead.data == encodedData else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .verifiedPrimaryData)
                }
                guard verifiedJournalRead.data == encodedData else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .verifiedJournalData)
                }
                guard verifiedMarkerRead.data == markerData else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .verifiedMarkerData)
                }
                guard Self.aggregateArtifactSizeIsValid(
                    [
                        verifiedPrimaryRead.data.count,
                        verifiedJournalRead.data.count,
                        verifiedMarkerRead.data.count,
                    ]
                ) else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .verifiedAggregateSize)
                }
                guard let verifiedPrimary = Self.decodeVerifiedSnapshot(
                    verifiedPrimaryRead.data
                ) else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .verifiedPrimaryDecode)
                }
                guard let verifiedJournal = Self.decodeVerifiedSnapshot(
                    verifiedJournalRead.data
                ) else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .verifiedJournalDecode)
                }
                guard let verifiedMarker = Self.decodeCommitMarker(
                    verifiedMarkerRead.data
                ) else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .verifiedMarkerDecode)
                }
                guard Self.commitValidationFailure(
                    primary: verifiedPrimary,
                    journal: verifiedJournal,
                    journalExists: true,
                    marker: verifiedMarker,
                    markerExists: true
                ) == nil else {
                    throw PersistenceFileError.lockIdentityInvalid(stage: .verifiedCommit)
                }
                baselineFileIdentity = verifiedPrimaryRead.identity
                baselineJournalFileIdentity = verifiedJournalRead.identity
                baselineCommitMarkerIdentity = verifiedMarkerRead.identity
                baselineData = verifiedPrimaryRead.data
                lastObservedCommitGeneration = commitGeneration
                lastObservedCommitTransactionID = transactionID
                lastObservedCommitPreviousDigest = previousDigest
                lastObservedCommitLineageConflict = false
                lastObservedCommitDigest = digest
                lastObservedCommitProviderScope = providerScope
                lastObservedCommitProviderScopeVersion = Self.providerScopeVersion
                lastObservedCommitProviderScopeMigrationReceipt = Self.providerScopeMigrationReceipt
                lastObservedCommitProviderScopePreviousVersionDigest = nil
                lastObservedCommitProviderScopeMigrationHistory = migrationHistory
                lastObservedCommitProviderScopeMigrationCheckpoint = migrationCheckpoint
                lastObservedCommitProviderScopeMigrationEpoch = Self.providerScopeMigrationEpoch
                lastObservedCommitProviderScopeMigrationCleanupTombstone = Self.providerScopeMigrationCleanupTombstone
                lastObservedCommitProviderScopeMigrationPreviousRoot = Self.providerScopeMigrationPreviousRoot
                if !preservingRecoveryState {
                    recoveryState = .loaded(recordCount: storedRecords.count)
                }
            }
            return true
        } catch {
            onPersistError?(error)
            return false
        }
    }
}

fileprivate struct ProviderReadinessPersistenceKey: Hashable, Sendable {
    let providerID: String
    let modelID: String
    let configurationGeneration: String

    init(
        providerID: String,
        modelID: String,
        configurationGeneration: String
    ) {
        self.providerID = ProviderReadinessRevision.canonicalProviderID(providerID)
        self.modelID = ProviderReadinessRevision.canonicalModelID(modelID)
        self.configurationGeneration = configurationGeneration
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum ProviderReadinessPersistenceRedactor {
    static func redact(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        result = replace(
            pattern: #"(?i)(Bearer\s+)[A-Za-z0-9_.-]{8,}"#,
            in: result,
            template: "$1[REDACTED]"
        )
        result = replace(
            pattern: #"\bsk-[A-Za-z0-9_-]{8,}"#,
            in: result,
            template: "[REDACTED]"
        )
        result = replace(
            pattern: #"(?i)\b(api[-_]?key|access[-_]?token|secret|password)\s*[:=]\s*[^\s,;]+"#,
            in: result,
            template: "[REDACTED]"
        )
        return result
    }

    static func redactOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let redacted = redact(value)
        return redacted.isEmpty ? nil : redacted
    }

    private static func replace(
        pattern: String,
        in value: String,
        template: String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return value
        }
        let range = NSRange(value.startIndex..., in: value)
        return regex.stringByReplacingMatches(
            in: value,
            range: range,
            withTemplate: template
        )
    }
}
