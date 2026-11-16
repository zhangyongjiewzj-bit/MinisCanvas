import Foundation

/// Stable, secret-free status vocabulary shared by readiness consumers.
/// Unknown wire values remain fail-closed and can never become selectable.
public enum ProviderReadinessProjectionState: String, Codable, Hashable, Sendable {
    case mock
    case local
    case live
    case beta
    case blocked
    case unverified
    case unknown

    public init(rawValueOrUnknown rawValue: String) {
        self = Self(rawValue: rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .unknown
    }

    public init(readinessState: ProviderReadinessState, status: ProviderReadinessPersistenceStatus) {
        guard readinessState != .blocked else {
            self = .blocked
            return
        }
        guard status == .passed else {
            self = status == .unavailable ? .blocked : .unverified
            return
        }
        self = Self(rawValue: readinessState.rawValue) ?? .unknown
    }

    public var isSelectableState: Bool {
        switch self {
        case .mock, .local, .live, .beta: return true
        case .blocked, .unverified, .unknown: return false
        }
    }
}

public enum ProviderReadinessProjectionReason: String, Codable, Hashable, Sendable {
    case mockEvidence
    case localEvidence
    case liveEvidence
    case betaEvidence
    case blocked
    case unverified
    case unknown

    public init(state: ProviderReadinessProjectionState) {
        switch state {
        case .mock: self = .mockEvidence
        case .local: self = .localEvidence
        case .live: self = .liveEvidence
        case .beta: self = .betaEvidence
        case .blocked: self = .blocked
        case .unverified: self = .unverified
        case .unknown: self = .unknown
        }
    }
}

/// The three facts required before a provider/model row can authorize chat.
///
/// This is deliberately computed from a completed durable snapshot. An
/// in-flight transport attempt has no projection and therefore cannot mint
/// a selectable row; restart/reopen callers must build a new projection from
/// the durable store.
public struct ProviderReadinessSelectionTruth: Codable, Hashable, Sendable {
    public let isEnabled: Bool
    public let isConfigured: Bool
    public let isReady: Bool
    public let isInFlight: Bool

    public init(
        isEnabled: Bool,
        isConfigured: Bool,
        isReady: Bool,
        isInFlight: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.isConfigured = isConfigured
        self.isReady = isReady
        self.isInFlight = isInFlight
    }

    public var isActionable: Bool {
        isEnabled && isConfigured && isReady && !isInFlight
    }
}

/// Stable chat-only identity for a provider/model choice.
///
/// Canvas provider/model configuration is intentionally not represented here.
public struct ChatModelPickerItem: Identifiable, Codable, Hashable, Sendable {
    public var id: String { "\(providerID)/\(modelID)" }
    public let providerID: String
    public let modelID: String
    public let status: ProviderReadinessPersistenceStatus
    public let readinessState: ProviderReadinessState
    public let projectionState: ProviderReadinessProjectionState
    public let projectionReason: ProviderReadinessProjectionReason
    public let checkedAt: Date
    public let errorCategory: ProviderReadinessFailureCategory?
    public let latency: Int?
    public let evidenceID: String?
    public let isApplied: Bool
    public let applyReceiptID: String?
    public let appliedAt: Date?

    /// An unavailable or blocked model remains visible so the settings
    /// surface can explain the failure and offer a retry/rebind action.
    /// It is never made selectable by this presentation state.
    public var isBlocked: Bool {
        projectionState == .blocked || projectionState == .unknown
    }

    /// Non-selectable entries are actionable at the settings boundary: they
    /// can be checked again, explicitly applied, or have their credential
    /// rebound. This is presentation metadata, not permission to send.
    public var isActionable: Bool {
        !isSelectable
    }

    /// Enabled is a readiness fact, not a UI toggle: only a passed snapshot
    /// in a known selectable state can be enabled for the picker.
    public var isEnabled: Bool {
        status == .passed
            && projectionState.isSelectableState
            && errorCategory == nil
    }

    /// Configuration is represented by the explicit Apply receipt. A model
    /// discovered by `/models`, or an old snapshot missing the receipt, is
    /// visible for recovery but is never treated as configured.
    public var isConfigured: Bool {
        isApplied && applyReceiptID != nil && appliedAt != nil
    }

    public var selectionTruth: ProviderReadinessSelectionTruth {
        ProviderReadinessSelectionTruth(
            isEnabled: isEnabled,
            isConfigured: isConfigured,
            isReady: hasTraceableEvidence,
            isInFlight: false
        )
    }

    public var isSelectable: Bool {
        selectionTruth.isActionable
    }

    /// Mock fixtures and local probes are useful evidence, but are not live
    /// provider verification.
    public var isLiveVerified: Bool {
        status == .passed
            && projectionState == .live
            && hasTraceableEvidence
    }

    /// Live selection requires an evidence ID shape produced by a known
    /// readiness receipt path. Local/mock fixtures intentionally keep their
    /// looser evidence semantics and are never reported as live.
    public var hasTraceableEvidence: Bool {
        guard let evidenceID,
              !evidenceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        guard projectionState == .live else { return true }

        let schemes: [(prefix: String, digestLength: Int)] = [
            ("live-settings:", 64),
            ("http-readiness:", 32)
        ]
        return schemes.contains { prefix, digestLength in
            guard evidenceID.hasPrefix(prefix) else { return false }
            let digest = evidenceID.dropFirst(prefix.count)
            guard digest.count == digestLength else { return false }
            return digest.unicodeScalars.allSatisfy { scalar in
                (48...57).contains(scalar.value)
                    || (97...102).contains(scalar.value)
            }
        }
    }

    public var applyReceipt: ChatModelPickerApplyReceipt? {
        guard isSelectable,
              let evidenceID,
              let applyReceiptID,
              let appliedAt else {
            return nil
        }
        return ChatModelPickerApplyReceipt(
            providerID: providerID,
            modelID: modelID,
            evidenceID: evidenceID,
            applyReceiptID: applyReceiptID,
            appliedAt: appliedAt,
            isApplied: isApplied
        )
    }

    fileprivate init(record: ProviderReadinessPersistenceRecord) {
        providerID = record.providerID
        modelID = record.modelID
        status = record.status
        readinessState = record.readinessState
        projectionState = ProviderReadinessProjectionState(
            readinessState: record.readinessState,
            status: record.status
        )
        projectionReason = ProviderReadinessProjectionReason(state: projectionState)
        checkedAt = record.checkedAt
        errorCategory = record.errorCategory
        latency = record.latency
        evidenceID = record.evidenceID
        isApplied = record.isApplied
        applyReceiptID = record.applyReceiptID
        appliedAt = record.appliedAt
    }
}

/// A secret-free live handoff from the settings Apply action to chat.
///
/// The receipt carries the readiness evidence that authorized the choice; it
/// does not contain credentials, URLs, or a transport response.
public struct ChatModelPickerApplyReceipt: Codable, Hashable, Sendable, Identifiable {
    private enum CodingKeys: String, CodingKey {
        case providerID
        case modelID
        case evidenceID
        case applyReceiptID
        case appliedAt
        case isApplied
    }

    public var id: String {
        applyReceiptID
    }
    public let providerID: String
    public let modelID: String
    public let evidenceID: String
    public let applyReceiptID: String
    public let appliedAt: Date
    public let isApplied: Bool

    public init(
        providerID: String,
        modelID: String,
        evidenceID: String,
        applyReceiptID: String? = nil,
        appliedAt: Date = Date(),
        isApplied: Bool = true
    ) {
        self.providerID = providerID
        self.modelID = modelID
        self.evidenceID = evidenceID
        self.applyReceiptID = applyReceiptID
            ?? "provider-readiness-apply:\(providerID):\(modelID):\(evidenceID)"
        self.appliedAt = appliedAt
        self.isApplied = isApplied
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            providerID: try container.decode(String.self, forKey: .providerID),
            modelID: try container.decode(String.self, forKey: .modelID),
            evidenceID: try container.decode(String.self, forKey: .evidenceID),
            applyReceiptID: try container.decodeIfPresent(
                String.self,
                forKey: .applyReceiptID
            ),
            appliedAt: try container.decode(Date.self, forKey: .appliedAt),
            isApplied: try container.decode(Bool.self, forKey: .isApplied)
        )
    }
}

/// Projection consumed by a chat model picker.
///
/// `items` contains only user-applied models. `pending` retains discovered
/// entries so a settings consumer can present an explicit apply action without
/// making them selectable in chat.
public struct ChatModelPickerProjection: Codable, Hashable, Sendable {
    public let items: [ChatModelPickerItem]
    public let pending: [ChatModelPickerItem]

    public init(records: [ProviderReadinessPersistenceRecord]) {
        var newestByKey: [String: ProviderReadinessPersistenceRecord] = [:]
        var identityByKey: [String: String] = [:]
        var driftedIdentityKeys: Set<String> = []
        for record in records {
            let key = Self.key(
                providerID: record.providerID,
                modelID: record.modelID
            )
            let identity = Self.identityKey(record)
            if let currentIdentity = identityByKey[key], currentIdentity != identity {
                driftedIdentityKeys.insert(key)
            } else {
                identityByKey[key] = identity
            }
            // Use the same revision rule as the readiness registry and
            // persistence consumer: equal timestamps are accepted as the
            // latest retry, while older observations remain fenced.
            if let current = newestByKey[key] {
                guard ProviderReadinessRevision.accepts(
                    candidateAt: record.checkedAt,
                    replacing: current.checkedAt
                ) else {
                    continue
                }
            }
            newestByKey[key] = record
        }

        let projected = newestByKey.values
            .map { record in
                let rowKey = Self.key(
                    providerID: record.providerID,
                    modelID: record.modelID
                )
                let safeRecord = driftedIdentityKeys.contains(rowKey)
                    || !Self.hasValidFreshness(record)
                    ? record.downgradedToUnverified()
                    : record
                return ChatModelPickerItem(record: safeRecord)
            }
            .sorted {
                if $0.providerID == $1.providerID {
                    return $0.modelID < $1.modelID
                }
                return $0.providerID < $1.providerID
            }
        items = projected.filter(\.isApplied)
        pending = projected.filter { !$0.isApplied }
    }

    /// Applied and pending entries that need a settings-side action. This
    /// deliberately keeps the result provider/model scoped; one provider's
    /// unavailable record cannot turn another provider's readiness red.
    public var actionableItems: [ChatModelPickerItem] {
        (items + pending).filter(\.isActionable)
    }

    /// Blocked entries remain available for an explanatory UI state and a
    /// credential rebind/recheck affordance.
    public var blockedItems: [ChatModelPickerItem] {
        (items + pending).filter(\.isBlocked)
    }

    public func item(providerID: String, modelID: String) -> ChatModelPickerItem? {
        let requestedKey = Self.key(providerID: providerID, modelID: modelID)
        return (items + pending).first {
            Self.key(providerID: $0.providerID, modelID: $0.modelID) == requestedKey
        }
    }

    public func receipt(providerID: String, modelID: String) -> ChatModelPickerApplyReceipt? {
        let requestedKey = Self.key(providerID: providerID, modelID: modelID)
        return items.first {
            Self.key(providerID: $0.providerID, modelID: $0.modelID) == requestedKey
        }?.applyReceipt
    }

    /// Provider identities come from both saved names and runtime IDs. They
    /// are case-insensitive at the Apply/rebind boundary; model IDs remain
    /// case-sensitive so similarly named models are never merged.
    private static func key(providerID: String, modelID: String) -> String {
        "\(ProviderReadinessRevision.canonicalProviderID(providerID))/\(ProviderReadinessRevision.canonicalModelID(modelID))"
    }

    private static func identityKey(
        _ record: ProviderReadinessPersistenceRecord
    ) -> String {
        [
            record.projectionSourceProviderID,
            record.modelID,
            record.configurationGeneration,
            record.configurationFingerprint ?? "",
        ].joined(separator: "\u{1F}")
    }

    private static func hasValidFreshness(
        _ record: ProviderReadinessPersistenceRecord
    ) -> Bool {
        guard record.checkedAt.timeIntervalSinceReferenceDate.isFinite else {
            return false
        }
        guard let expiresAt = record.expiresAt else { return true }
        return expiresAt.timeIntervalSinceReferenceDate.isFinite
            && expiresAt >= record.checkedAt
    }

    private static func stableRecordOrder(
        _ lhs: ProviderReadinessPersistenceRecord,
        _ rhs: ProviderReadinessPersistenceRecord
    ) -> Bool {
        if lhs.checkedAt != rhs.checkedAt {
            return lhs.checkedAt < rhs.checkedAt
        }
        return tieBreakKey(lhs) < tieBreakKey(rhs)
    }

    private static func tieBreakKey(
        _ record: ProviderReadinessPersistenceRecord
    ) -> String {
        [
            ProviderReadinessRevision.canonicalProviderID(record.providerID),
            ProviderReadinessRevision.canonicalModelID(record.modelID),
            record.providerID,
            record.modelID,
            record.configurationGeneration,
            record.discoveryReceiptID,
            record.evidenceID ?? "",
            record.status.rawValue,
            record.readinessState.rawValue,
            record.errorCategory?.rawValue ?? "",
            String(record.latency ?? -1),
            String(record.isApplied),
            record.applyReceiptID ?? "",
            record.appliedAt.map { String($0.timeIntervalSinceReferenceDate) } ?? "",
            String(record.discoveredAt.timeIntervalSinceReferenceDate),
            record.configurationFingerprint ?? "",
            record.expiresAt.map { String($0.timeIntervalSinceReferenceDate) } ?? ""
        ].joined(separator: "\u{1F}")
    }
}
