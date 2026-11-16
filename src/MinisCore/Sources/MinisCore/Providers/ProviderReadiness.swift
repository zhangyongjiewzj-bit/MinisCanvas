import Foundation

public enum ProviderReadinessState: String, Codable, Hashable, Sendable {
    case mock
    case local
    case live
    case beta
    case blocked
    case unverified
}

public enum ProviderDeployment: String, Codable, Hashable, Sendable {
    case mock
    case local
    case remote
    case beta
}

public enum ProviderProbeStatus: String, Codable, Hashable, Sendable {
    case notRun
    case unavailable
    case reachable
}

/// Revision ordering shared by readiness producers and picker projections.
/// Equal timestamps are accepted as the latest revision; only an older
/// observation is stale. This keeps reconnect retries and projections aligned.
public enum ProviderReadinessRevision {
    public static func canonicalProviderID(_ providerID: String) -> String {
        providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func canonicalModelID(_ modelID: String) -> String {
        modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func accepts(
        candidateAt: Date,
        replacing currentAt: Date?
    ) -> Bool {
        guard candidateAt.timeIntervalSinceReferenceDate.isFinite else { return false }
        guard let currentAt else { return true }
        guard currentAt.timeIntervalSinceReferenceDate.isFinite else { return true }
        return candidateAt >= currentAt
    }
}

/// Secret-free immutable references connecting a readiness observation to the
/// discovery that introduced it and the explicit Apply action that consumed
/// it. Refreshes may create a new observation, but they must never rewrite
/// these receipt references on an already-applied record.
public struct ProviderReadinessLineage: Codable, Hashable, Sendable {
    public let discoveryReceiptID: String
    public let discoveredAt: Date
    public let applyReceiptID: String?
    public let appliedAt: Date?

    public init(
        discoveryReceiptID: String,
        discoveredAt: Date,
        applyReceiptID: String? = nil,
        appliedAt: Date? = nil
    ) {
        self.discoveryReceiptID = discoveryReceiptID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.discoveredAt = discoveredAt
        self.applyReceiptID = applyReceiptID.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.nilIfEmpty
        self.appliedAt = appliedAt
    }

    public static func derived(
        providerID: String,
        modelID: String,
        checkedAt: Date
    ) -> Self {
        let canonical = [
            providerID.trimmingCharacters(in: .whitespacesAndNewlines),
            modelID.trimmingCharacters(in: .whitespacesAndNewlines),
            String(checkedAt.timeIntervalSince1970)
        ].joined(separator: "|")
        return Self(
            discoveryReceiptID: "provider-readiness-discovery:\(canonical)",
            discoveredAt: checkedAt
        )
    }

    public func applying(
        at appliedAt: Date
    ) -> Self {
        guard applyReceiptID == nil else { return self }
        return Self(
            discoveryReceiptID: discoveryReceiptID,
            discoveredAt: discoveredAt,
            applyReceiptID: "provider-readiness-apply:\(discoveryReceiptID)",
            appliedAt: appliedAt
        )
    }
}

public enum ProviderCredentialStatus: Codable, Hashable, Sendable {
    case notRequired
    case available(source: String)
    case missing(source: String?)

    var source: String? {
        switch self {
        case .notRequired:
            return nil
        case .available(let source):
            return source
        case .missing(let source):
            return source
        }
    }
}

public struct ProviderReadiness: Codable, Hashable, Sendable {
    public let providerID: String
    public let modelID: String
    public let state: ProviderReadinessState
    public let capabilities: Set<ProviderCapability>
    public let credentialSource: String?
    public let checkedAt: Date
    public let evidenceID: String?
    public let errorCategory: ProviderReadinessFailureCategory?
    public let latency: Int?
    public let lineage: ProviderReadinessLineage

    /// A completed, secret-free observation that is safe to hand to a
    /// selection projection. Credential/configuration truth is intentionally
    /// represented by the caller's explicit Apply receipt, not inferred from
    /// a transport response.
    public var isReadyForSelection: Bool {
        let hasIdentity = !providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasEvidence = evidenceID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        return hasIdentity
            && hasEvidence
            && errorCategory == nil
            && state != .blocked
            && state != .unverified
    }

    public static func evaluate(
        providerID: String,
        modelID: String,
        deployment: ProviderDeployment,
        probe: ProviderProbeStatus,
        credential: ProviderCredentialStatus,
        capabilities: Set<ProviderCapability>,
        checkedAt: Date,
        evidenceID: String?,
        errorCategory: ProviderReadinessFailureCategory? = nil,
        latency: Int? = nil,
        lineage: ProviderReadinessLineage? = nil
    ) -> ProviderReadiness {
        let derivedLineage = ProviderReadinessLineage.derived(
            providerID: providerID,
            modelID: modelID,
            checkedAt: checkedAt
        )
        let normalizedLineage = normalizedLineage(
            supplied: lineage,
            derived: derivedLineage
        )
        let normalizedLatency = latency.map { max(0, $0) }
        let hasIdentity = !providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasFiniteTimestamps = checkedAt.timeIntervalSinceReferenceDate.isFinite
            && normalizedLineage.discoveredAt.timeIntervalSinceReferenceDate.isFinite
            && normalizedLineage.appliedAt?.timeIntervalSinceReferenceDate.isFinite != false
        guard hasIdentity && hasFiniteTimestamps else {
            return ProviderReadiness(
                providerID: providerID,
                modelID: modelID,
                state: .unverified,
                capabilities: [],
                credentialSource: credential.source,
                checkedAt: checkedAt,
                evidenceID: nil,
                errorCategory: .invalidConfiguration,
                latency: normalizedLatency,
                lineage: normalizedLineage
            )
        }
        if case .missing = credential {
            return ProviderReadiness(
                providerID: providerID,
                modelID: modelID,
                state: .blocked,
                capabilities: [],
                credentialSource: credential.source,
                checkedAt: checkedAt,
                evidenceID: nil,
                errorCategory: errorCategory ?? .missingCredential,
                latency: normalizedLatency,
                lineage: normalizedLineage
            )
        }

        let normalizedEvidenceID = evidenceID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard probe != .unavailable else {
            return ProviderReadiness(
                providerID: providerID,
                modelID: modelID,
                state: .blocked,
                capabilities: [],
                credentialSource: credential.source,
                checkedAt: checkedAt,
                evidenceID: nil,
                errorCategory: errorCategory ?? .unavailable,
                latency: normalizedLatency,
                lineage: normalizedLineage
            )
        }
        guard probe == .reachable,
              errorCategory == nil,
              let normalizedEvidenceID,
              !normalizedEvidenceID.isEmpty else {
            return ProviderReadiness(
                providerID: providerID,
                modelID: modelID,
                state: .unverified,
                capabilities: [],
                credentialSource: credential.source,
                checkedAt: checkedAt,
                evidenceID: nil,
                errorCategory: errorCategory ?? .transport,
                latency: normalizedLatency,
                lineage: normalizedLineage
            )
        }

        let state: ProviderReadinessState
        switch deployment {
        case .mock:
            state = .mock
        case .local:
            state = .local
        case .remote:
            state = .live
        case .beta:
            state = .beta
        }

        return ProviderReadiness(
            providerID: providerID,
            modelID: modelID,
            state: state,
            capabilities: capabilities,
            credentialSource: credential.source,
            checkedAt: checkedAt,
            evidenceID: normalizedEvidenceID,
            errorCategory: nil,
            latency: normalizedLatency,
            lineage: normalizedLineage
        )
    }

    private static func normalizedLineage(
        supplied: ProviderReadinessLineage?,
        derived: ProviderReadinessLineage
    ) -> ProviderReadinessLineage {
        guard let supplied else { return derived }

        // Opaque fixture receipts remain valid, but receipts emitted by the
        // built-in derivation path must stay bound to this provider/model.
        guard supplied.discoveryReceiptID.hasPrefix(
            "provider-readiness-discovery:"
        ) else {
            return supplied
        }
        guard supplied.discoveryReceiptID == derived.discoveryReceiptID else {
            return derived
        }
        return supplied
    }
}

public protocol ProviderReadinessProbe: Sendable {
    func probe() async -> ProviderReadiness
}

private extension Optional where Wrapped == String {
    var nilIfEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}

public actor ProviderReadinessRegistry {
    private struct Key: Hashable {
        let providerID: String
        let modelID: String

        init(providerID: String, modelID: String) {
            self.providerID = ProviderReadinessRevision.canonicalProviderID(providerID)
            self.modelID = ProviderReadinessRevision.canonicalModelID(modelID)
        }
    }

    private var records: [Key: ProviderReadiness] = [:]

    public init() {}

    @discardableResult
    public func refresh(using probe: any ProviderReadinessProbe) async -> ProviderReadiness {
        let candidate = await probe.probe()
        let key = Key(providerID: candidate.providerID, modelID: candidate.modelID)

        if let current = records[key], !ProviderReadinessRevision.accepts(
            candidateAt: candidate.checkedAt,
            replacing: current.checkedAt
        ) {
            return current
        }

        records[key] = candidate
        return candidate
    }

    public func readiness(providerID: String, modelID: String) -> ProviderReadiness? {
        records[Key(providerID: providerID, modelID: modelID)]
    }

    /// Restart/reopen invalidation is explicit: no pre-restart observation is
    /// allowed to remain queryable in the new lifecycle. Callers must probe
    /// again before constructing a selectable projection.
    @discardableResult
    public func invalidateForRestart() -> Int {
        let invalidatedCount = records.count
        records.removeAll(keepingCapacity: true)
        return invalidatedCount
    }

    public func liveE2EReadiness(providerID: String, modelID: String) -> ProviderReadiness? {
        guard let readiness = readiness(providerID: providerID, modelID: modelID),
              readiness.state == .live,
              let evidenceID = readiness.evidenceID,
              !evidenceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return readiness
    }
}

extension ProviderReadinessStore {
    /// Restart/re-entry invalidation clears every durable provider snapshot so
    /// the next production consumer pass must persist fresh readiness facts.
    @discardableResult
    public func invalidateForRestart() -> Int {
        let providerIDs = Set(records.map(\.providerID))
        return providerIDs.reduce(into: 0) { count, providerID in
            count += rebindCredentialSuccessor(providerID: providerID)
        }
    }
}

/// Production bridge from a completed readiness check to the durable model
/// discovery consumer.  It keeps the sequence explicit: check first, persist
/// every discovered/model outcome, then allow an explicit Apply or successor
/// rebind.  No transport payload or credential value enters this boundary.
public actor ProviderReadinessProductionConsumer {
    private let store: ProviderReadinessStore

    public init(store: ProviderReadinessStore) {
        self.store = store
    }

    /// Re-entry boundary for the real durable consumer. No pre-restart fact
    /// remains selectable until a later consume/reconnect call repopulates it.
    @discardableResult
    public func invalidateForRestart() -> Int {
        store.invalidateForRestart()
    }

    @discardableResult
    public func consume(
        _ report: ProviderReadinessCheckReport,
        latency: Int? = nil,
        appliedModelIDs: Set<String> = []
    ) -> [ProviderReadinessPersistenceRecord] {
        let records = ProviderReadinessPersistenceRecord.records(
            from: report,
            latency: latency,
            appliedModelIDs: appliedModelIDs
        )
        _ = store.upsert(records)
        return records
    }

    /// Persist a fresh transport attempt after a reconnect/retry.
    ///
    /// The store accepts equal-timestamp retries, rejects late older results,
    /// and keeps the measured latency on the accepted record. Returning one
    /// outcome per model keeps partial acceptance explicit to Settings and
    /// the downstream model picker.
    public func reconnect(
        _ report: ProviderReadinessCheckReport,
        latency: Int? = nil,
        appliedModelIDs: Set<String> = []
    ) -> [ProviderReadinessReconnectOutcome] {
        let records = ProviderReadinessPersistenceRecord.records(
            from: report,
            latency: latency,
            appliedModelIDs: appliedModelIDs
        )
        return store.reconnect(records)
    }

    @discardableResult
    public func applyDiscoveredModels(
        providerID: String,
        modelIDs: [String],
        appliedAt: Date = Date()
    ) -> [ProviderReadinessPersistenceRecord] {
        store.applyDiscoveredModels(
            providerID: providerID,
            modelIDs: modelIDs,
            appliedAt: appliedAt
        )
    }

    @discardableResult
    public func rebindCredentialSuccessor(
        providerID: String,
        modelID: String
    ) -> Bool {
        store.rebindCredentialSuccessor(providerID: providerID, modelID: modelID)
    }

    @discardableResult
    public func rebindCredentialSuccessor(providerID: String) -> Int {
        store.rebindCredentialSuccessor(providerID: providerID)
    }

    public func currentRecords() -> [ProviderReadinessPersistenceRecord] {
        store.records
    }
}
