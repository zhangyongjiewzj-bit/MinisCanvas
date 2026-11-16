import Foundation

/// Provider-scoped model identity used by model selection and persistence.
///
/// This intentionally keeps the provider namespace in the value. A bare
/// model alias must never be resolved against another provider.
public struct ProviderModelSelectionReference: Codable, Equatable, Hashable, Sendable {
    public let providerID: String
    public let modelID: String

    public init(providerID: String, modelID: String) {
        self.providerID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isValid: Bool {
        !providerID.isEmpty && !modelID.isEmpty
    }
}

/// Typed health for a discovered model. Unknown and degraded are deliberately
/// distinct from unsupported: the former can recover after a refresh, while
/// the latter must not be presented as selectable for the requested capability.
public enum ProviderModelSelectionHealth: String, Codable, Hashable, Sendable {
    case unknown
    case supported
    case unsupported
    case degraded

    public var displayName: String {
        switch self {
        case .unknown: return "未知"
        case .supported: return "可用"
        case .unsupported: return "不支持"
        case .degraded: return "降级"
        }
    }

    public var recoveryAction: ProviderModelSelectionRecoveryAction {
        switch self {
        case .unknown: return .refreshCatalog
        case .supported: return .none
        case .unsupported: return .chooseSupportedModel
        case .degraded: return .retryReadiness
        }
    }
}

/// Explicit, user-understandable next action for a non-selectable decision.
public enum ProviderModelSelectionRecoveryAction: String, Codable, Hashable, Sendable {
    case none
    case refreshCatalog
    case chooseSupportedModel
    case retryReadiness
    case configureProvider
    case rebindCredential
    case resolveAlias

    public var displayName: String? {
        switch self {
        case .none: return nil
        case .refreshCatalog: return "刷新模型目录"
        case .chooseSupportedModel: return "选择支持的模型"
        case .retryReadiness: return "重试就绪检查"
        case .configureProvider: return "配置供应商"
        case .rebindCredential: return "重新绑定凭据"
        case .resolveAlias: return "解决模型别名冲突"
        }
    }
}

/// Fail-closed availability for one model-picker candidate.
public enum ProviderModelSelectionAvailability: String, Codable, Hashable, Sendable {
    case available
    case unknown
    case unsupported
    case degraded
    case blocked
    case notConfigured
    case unverified
    case staleCredential
    case missing
    case ambiguous
}

public enum ProviderModelSelectionReason: String, Codable, Hashable, Sendable {
    case readinessPassed
    case modelHealthUnknown
    case modelUnsupported
    case modelDegraded
    case readinessBlocked
    case providerNotConfigured
    case readinessUnverified
    case credentialVersionNotCurrent
    case catalogEntryMissing
    case aliasAmbiguous
}

/// A catalog model plus the readiness observation that authorizes selection.
public struct ProviderModelSelectionCandidate: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let providerID: String
    public let modelID: String
    public let aliases: [String]
    public let isConfigured: Bool
    public let status: ProviderReadinessPersistenceStatus
    public let readinessState: ProviderReadinessState
    /// Opaque digest/version only; never put a raw credential here.
    public let credentialVersion: String?
    public let health: ProviderModelSelectionHealth

    public var id: String {
        "\(providerID)/\(modelID)"
    }

    /// Health alone is not authorization to send.  This small projection is
    /// useful to UI consumers while the catalog decision additionally checks
    /// configuration, readiness and current credential version.
    public var hasSupportedHealth: Bool {
        health == .supported
    }

    public init(
        providerID: String,
        modelID: String,
        aliases: [String] = [],
        isConfigured: Bool,
        status: ProviderReadinessPersistenceStatus,
        readinessState: ProviderReadinessState,
        credentialVersion: String? = nil,
        health: ProviderModelSelectionHealth = .supported
    ) {
        let normalizedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.providerID = normalizedProviderID
        self.modelID = normalizedModelID
        self.aliases = Self.normalizedAliases(aliases, excluding: normalizedModelID)
        self.isConfigured = isConfigured
        self.status = status
        self.readinessState = readinessState
        let normalizedVersion = credentialVersion?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.credentialVersion = normalizedVersion?.isEmpty == true ? nil : normalizedVersion
        self.health = health
    }

    private enum CodingKeys: String, CodingKey {
        case providerID, modelID, aliases, isConfigured, status, readinessState, credentialVersion, health
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            providerID: try container.decode(String.self, forKey: .providerID),
            modelID: try container.decode(String.self, forKey: .modelID),
            aliases: try container.decodeIfPresent([String].self, forKey: .aliases) ?? [],
            isConfigured: try container.decode(Bool.self, forKey: .isConfigured),
            status: try container.decode(ProviderReadinessPersistenceStatus.self, forKey: .status),
            readinessState: try container.decode(ProviderReadinessState.self, forKey: .readinessState),
            credentialVersion: try container.decodeIfPresent(String.self, forKey: .credentialVersion),
            health: try container.decodeIfPresent(ProviderModelSelectionHealth.self, forKey: .health) ?? .supported
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(providerID, forKey: .providerID)
        try container.encode(modelID, forKey: .modelID)
        try container.encode(aliases, forKey: .aliases)
        try container.encode(isConfigured, forKey: .isConfigured)
        try container.encode(status, forKey: .status)
        try container.encode(readinessState, forKey: .readinessState)
        try container.encodeIfPresent(credentialVersion, forKey: .credentialVersion)
        try container.encode(health, forKey: .health)
    }

    private static func normalizedAliases(
        _ aliases: [String],
        excluding modelID: String
    ) -> [String] {
        var seen = Set<String>()
        return aliases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter {
                !$0.isEmpty && $0 != modelID && seen.insert($0).inserted
            }
    }
}

/// Auditable decision for a requested/default/persisted model reference.
public struct ProviderModelSelectionDecision: Codable, Equatable, Hashable, Sendable {
    public let requested: ProviderModelSelectionReference
    public let candidate: ProviderModelSelectionCandidate?
    public let resolvedReference: ProviderModelSelectionReference?
    public let availability: ProviderModelSelectionAvailability
    public let reason: ProviderModelSelectionReason

    public var isSelectable: Bool {
        availability == .available
    }

    /// Every non-available state is intentionally fail-closed.  Consumers
    /// may still render its recovery action without treating it as a send
    /// authorization.
    public var isFailClosed: Bool {
        !isSelectable
    }

    public var statusLabel: String {
        switch availability {
        case .available: return "可用"
        case .unknown: return "未知"
        case .unsupported: return "不支持"
        case .degraded: return "降级"
        case .blocked: return "已阻止"
        case .notConfigured: return "未配置"
        case .unverified: return "未验证"
        case .staleCredential: return "凭据已过期"
        case .missing: return "未找到"
        case .ambiguous: return "存在冲突"
        }
    }

    public var recoveryAction: ProviderModelSelectionRecoveryAction {
        if let candidate, candidate.health != .supported {
            return candidate.health.recoveryAction
        }
        switch availability {
        case .available: return .none
        case .unknown, .missing: return .refreshCatalog
        case .unsupported: return .chooseSupportedModel
        case .degraded, .blocked, .unverified: return .retryReadiness
        case .notConfigured: return .configureProvider
        case .staleCredential: return .rebindCredential
        case .ambiguous: return .resolveAlias
        }
    }

    public var recoveryActionLabel: String? {
        recoveryAction.displayName
    }
}

/// Catalog-aware model selection health.
///
/// The catalog preserves default and persisted references independently of
/// current discovery. Thus an old model alias is retained when it is absent
/// today, while an alias that resolves to a current candidate is explainable.
/// When a provider has a current credential version, only a matching
/// readiness observation can become selectable; an older observation cannot
/// silently authorize the successor credential.
public struct ProviderModelSelectionCatalog: Codable, Equatable, Hashable, Sendable {
    public let candidates: [ProviderModelSelectionCandidate]
    public let defaultSelection: ProviderModelSelectionReference?
    public let persistedSelection: ProviderModelSelectionReference?
    public let activeCredentialVersions: [String: String]

    public init(
        candidates: [ProviderModelSelectionCandidate],
        defaultSelection: ProviderModelSelectionReference? = nil,
        persistedSelection: ProviderModelSelectionReference? = nil,
        activeCredentialVersions: [String: String] = [:]
    ) {
        self.candidates = candidates.filter { $0.providerID.isEmpty == false && $0.modelID.isEmpty == false }
        self.defaultSelection = defaultSelection?.isValid == true ? defaultSelection : nil
        self.persistedSelection = persistedSelection?.isValid == true ? persistedSelection : nil
        self.activeCredentialVersions = activeCredentialVersions.reduce(into: [:]) { result, pair in
            let provider = ProviderReadinessRevision.canonicalProviderID(pair.key)
            let version = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !provider.isEmpty && !version.isEmpty {
                result[provider] = version
            }
        }
    }

    /// The original references are deliberately retained even if discovery
    /// cannot currently resolve them. Callers must not clear persisted state
    /// merely because the current catalog is incomplete.
    public var retainedDefaultSelection: ProviderModelSelectionReference? {
        defaultSelection
    }

    public var retainedPersistedSelection: ProviderModelSelectionReference? {
        persistedSelection
    }

    public var defaultDecision: ProviderModelSelectionDecision? {
        defaultSelection.map(decision(for:))
    }

    public var persistedDecision: ProviderModelSelectionDecision? {
        persistedSelection.map(decision(for:))
    }

    public func decision(
        for reference: ProviderModelSelectionReference
    ) -> ProviderModelSelectionDecision {
        guard reference.isValid else {
            return decision(
                reference: reference,
                candidate: nil,
                availability: .missing,
                reason: .catalogEntryMissing
            )
        }

        let referenceProviderID = ProviderReadinessRevision.canonicalProviderID(
            reference.providerID
        )
        let referenceModelID = ProviderReadinessRevision.canonicalModelID(
            reference.modelID
        )
        let exact = candidates.filter {
            ProviderReadinessRevision.canonicalProviderID($0.providerID)
                == referenceProviderID
                && ProviderReadinessRevision.canonicalModelID($0.modelID)
                    == referenceModelID
        }
        let matches: [ProviderModelSelectionCandidate]
        if !exact.isEmpty {
            matches = exact
        } else {
            matches = candidates.filter {
                ProviderReadinessRevision.canonicalProviderID($0.providerID)
                    == referenceProviderID
                    && $0.aliases.contains {
                        ProviderReadinessRevision.canonicalModelID($0)
                            == referenceModelID
                    }
            }
        }

        guard !matches.isEmpty else {
            return decision(
                reference: reference,
                candidate: nil,
                availability: .missing,
                reason: .catalogEntryMissing
            )
        }

        let currentMatches: [ProviderModelSelectionCandidate]
        if let activeVersion = activeCredentialVersions[referenceProviderID] {
            currentMatches = matches.filter { $0.credentialVersion == activeVersion }
            guard currentMatches.count == 1 else {
                return decision(
                    reference: reference,
                    candidate: currentMatches.count == 1 ? currentMatches[0] : nil,
                    availability: currentMatches.isEmpty ? .staleCredential : .ambiguous,
                    reason: currentMatches.isEmpty
                        ? .credentialVersionNotCurrent
                        : .aliasAmbiguous
                )
            }
        } else {
            currentMatches = matches
            guard currentMatches.count == 1 else {
                return decision(
                    reference: reference,
                    candidate: nil,
                    availability: .ambiguous,
                    reason: .aliasAmbiguous
                )
            }
        }

        let candidate = currentMatches[0]
        switch candidate.health {
        case .unknown:
            return decision(
                reference: reference,
                candidate: candidate,
                availability: .unknown,
                reason: .modelHealthUnknown
            )
        case .unsupported:
            return decision(
                reference: reference,
                candidate: candidate,
                availability: .unsupported,
                reason: .modelUnsupported
            )
        case .degraded:
            return decision(
                reference: reference,
                candidate: candidate,
                availability: .degraded,
                reason: .modelDegraded
            )
        case .supported:
            break
        }
        guard candidate.isConfigured else {
            return decision(
                reference: reference,
                candidate: candidate,
                availability: .notConfigured,
                reason: .providerNotConfigured
            )
        }
        guard candidate.status == .passed else {
            let isBlocked = candidate.status == .unavailable
                || candidate.readinessState == .blocked
            return decision(
                reference: reference,
                candidate: candidate,
                availability: isBlocked ? .blocked : .unverified,
                reason: isBlocked
                    ? .readinessBlocked
                    : .readinessUnverified
            )
        }
        guard candidate.readinessState != .blocked,
              candidate.readinessState != .unverified else {
            return decision(
                reference: reference,
                candidate: candidate,
                availability: candidate.readinessState == .blocked ? .blocked : .unverified,
                reason: candidate.readinessState == .blocked
                    ? .readinessBlocked
                    : .readinessUnverified
            )
        }

        return decision(
            reference: reference,
            candidate: candidate,
            availability: .available,
            reason: .readinessPassed
        )
    }

    private func decision(
        reference: ProviderModelSelectionReference,
        candidate: ProviderModelSelectionCandidate?,
        availability: ProviderModelSelectionAvailability,
        reason: ProviderModelSelectionReason
    ) -> ProviderModelSelectionDecision {
        ProviderModelSelectionDecision(
            requested: reference,
            candidate: candidate,
            resolvedReference: candidate.map {
                ProviderModelSelectionReference(
                    providerID: $0.providerID,
                    modelID: $0.modelID
                )
            },
            availability: availability,
            reason: reason
        )
    }

    public func containsProvider(_ providerID: String) -> Bool {
        let normalized = ProviderReadinessRevision.canonicalProviderID(providerID)
        return candidates.contains {
            ProviderReadinessRevision.canonicalProviderID($0.providerID) == normalized
        }
            || defaultSelection.map({
                ProviderReadinessRevision.canonicalProviderID($0.providerID) == normalized
            }) == true
            || persistedSelection.map({
                ProviderReadinessRevision.canonicalProviderID($0.providerID) == normalized
            }) == true
            || activeCredentialVersions[normalized] != nil
    }

    /// Rebinds a provider identity without carrying forward stale readiness or
    /// credential authorization. The successor must pass a fresh readiness
    /// observation before it becomes selectable.
    public func rebound(providerID: String, to successorProviderID: String) -> ProviderModelSelectionCatalog {
        let old = ProviderReadinessRevision.canonicalProviderID(providerID)
        let successor = ProviderReadinessRevision.canonicalProviderID(successorProviderID)
        guard !old.isEmpty, !successor.isEmpty, old != successor else { return self }
        func rebind(_ reference: ProviderModelSelectionReference?) -> ProviderModelSelectionReference? {
            guard let reference else { return nil }
            guard ProviderReadinessRevision.canonicalProviderID(reference.providerID) == old else {
                return reference
            }
            return ProviderModelSelectionReference(providerID: successor, modelID: reference.modelID)
        }
        let reboundCandidates = candidates.map { candidate in
            guard ProviderReadinessRevision.canonicalProviderID(candidate.providerID) == old else {
                return candidate
            }
            return ProviderModelSelectionCandidate(
                providerID: successor,
                modelID: candidate.modelID,
                aliases: candidate.aliases,
                isConfigured: false,
                status: .unverified,
                readinessState: .unverified,
                credentialVersion: nil,
                health: .unknown
            )
        }
        var versions = activeCredentialVersions
        versions.removeValue(forKey: old)
        return ProviderModelSelectionCatalog(
            candidates: reboundCandidates,
            defaultSelection: rebind(defaultSelection),
            persistedSelection: rebind(persistedSelection),
            activeCredentialVersions: versions
        )
    }
}
