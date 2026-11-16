import Foundation

public struct ProviderRoutePolicy: Sendable, Equatable {
    public let costWeight: Double
    public let latencyWeight: Double
    public let qualityWeight: Double

    public init(costWeight: Double = 1, latencyWeight: Double = 1, qualityWeight: Double = 1) {
        self.costWeight = max(0, costWeight)
        self.latencyWeight = max(0, latencyWeight)
        self.qualityWeight = max(0, qualityWeight)
    }
}

public struct ProviderRouteRequest: Sendable, Equatable {
    public let requiredCapabilities: Set<ProviderCapability>
    public let allowedProviderIDs: Set<String>?
    public let policy: ProviderRoutePolicy

    public init(requiredCapabilities: Set<ProviderCapability>, allowedProviderIDs: Set<String>? = nil, policy: ProviderRoutePolicy = .init()) {
        self.requiredCapabilities = requiredCapabilities
        self.allowedProviderIDs = allowedProviderIDs
        self.policy = policy
    }

    /// Builds a request from the external capability manifest before any
    /// provider candidate is considered. The manifest is exact and typed;
    /// names, descriptions, and other metadata never grant a capability.
    public init(rawRequiredCapabilities: Set<String>, allowedProviderIDs: Set<String>? = nil, policy: ProviderRoutePolicy = .init()) throws {
        self.init(
            requiredCapabilities: try CapabilityRouter.resolveCapabilities(rawRequiredCapabilities),
            allowedProviderIDs: allowedProviderIDs,
            policy: policy
        )
    }
}

/// Secret-free reason a route candidate is currently unavailable.
public enum ProviderRouteUnavailableReason: String, Codable, Sendable, Equatable, Hashable {
    case keychainMissing
}

/// Availability supplied by the provider/runtime seam for one candidate.
/// Unavailable candidates are skipped locally; they do not poison the rest of
/// the routing set or change the readiness state of other providers.
public enum ProviderRouteCandidateAvailability: Sendable, Equatable, Hashable {
    case available
    case unavailable(reason: ProviderRouteUnavailableReason)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    public var auditReason: String {
        switch self {
        case .available:
            return "available"
        case .unavailable(let reason):
            return reason.rawValue
        }
    }
}

public struct ProviderRouteCandidate: Sendable, Equatable {
    public let id: String
    public let providerName: String
    public let modelID: String
    public let capabilities: Set<ProviderCapability>
    public let costMicros: Double
    public let latencyMilliseconds: Double
    public let qualityScore: Double
    public let availability: ProviderRouteCandidateAvailability

    public init(
        id: String,
        providerName: String,
        modelID: String,
        capabilities: Set<ProviderCapability>,
        costMicros: Double = 0,
        latencyMilliseconds: Double = 0,
        qualityScore: Double = 0,
        availability: ProviderRouteCandidateAvailability = .available
    ) {
        self.id = id
        self.providerName = providerName
        self.modelID = modelID
        self.capabilities = capabilities
        self.costMicros = max(0, costMicros)
        self.latencyMilliseconds = max(0, latencyMilliseconds)
        self.qualityScore = max(0, qualityScore)
        self.availability = availability
    }
}

public struct ProviderRouteSnapshot: Sendable, Equatable {
    public let providerID: String
    public let providerName: String
    public let modelID: String
    public let requiredCapabilities: Set<ProviderCapability>
    public let availableCapabilities: Set<ProviderCapability>
    public let configurationFingerprint: String?
    public let selectionScore: Double

    public init(candidate: ProviderRouteCandidate, requiredCapabilities: Set<ProviderCapability>, configurationFingerprint: String? = nil, selectionScore: Double = 0) {
        providerID = candidate.id
        providerName = candidate.providerName
        modelID = candidate.modelID
        self.requiredCapabilities = requiredCapabilities
        availableCapabilities = candidate.capabilities
        self.configurationFingerprint = configurationFingerprint
        self.selectionScore = selectionScore
    }
}

public enum CapabilityRoutingError: Error, Equatable, Sendable {
    case noMatchingProvider
    case unknownCapability(String)
}

public struct ProviderRouteReceipt: Sendable, Equatable {
    public let receiptID: String
    public let request: ProviderRouteRequest
    public let route: ProviderRouteSnapshot
    public let selectionReason: String

    public init(receiptID: String, request: ProviderRouteRequest, route: ProviderRouteSnapshot, selectionReason: String) {
        self.receiptID = receiptID
        self.request = request
        self.route = route
        self.selectionReason = selectionReason
    }
}

/// Explicit routing policy supplied by the caller, including its failure behavior.
public struct ProviderRoutePolicyInput: Sendable, Equatable {
    public enum Fallback: Sendable, Equatable {
        case fail
        case binding(
            providerID: String,
            providerName: String,
            modelID: String,
            configurationFingerprint: String,
            reason: String
        )
    }

    public let request: ProviderRouteRequest
    public let fallback: Fallback

    public init(request: ProviderRouteRequest, fallback: Fallback = .fail) {
        self.request = request
        self.fallback = fallback
    }
}

public enum ProviderRouteResolutionOutcome: Sendable, Equatable {
    case selected
    case fallback
    case failure(CapabilityRoutingError)
}

/// A deterministic routing result. Failures are data here so callers can persist an audit receipt.
public struct ProviderRouteResolutionReceipt: Sendable, Equatable {
    public let receiptID: String
    public let policyInput: ProviderRoutePolicyInput
    public let outcome: ProviderRouteResolutionOutcome
    public let route: ProviderRouteSnapshot?
    public let selectionReason: String

    public init(
        receiptID: String,
        policyInput: ProviderRoutePolicyInput,
        outcome: ProviderRouteResolutionOutcome,
        route: ProviderRouteSnapshot?,
        selectionReason: String
    ) {
        self.receiptID = receiptID
        self.policyInput = policyInput
        self.outcome = outcome
        self.route = route
        self.selectionReason = selectionReason
    }
}

/// A stable, execution-free observation of a routing resolution receipt.
/// Unknown externally observed outcome values are always represented as failure.
public enum ProviderRouteResolutionObservationOutcome: String, Sendable, Equatable {
    case selected
    case fallback
    case failure
}

public struct ProviderRouteResolutionObservation: Sendable, Equatable {
    public let receiptID: String
    public let outcome: ProviderRouteResolutionObservationOutcome
    public let route: ProviderRouteSnapshot?
    public let selectionReason: String

    public init(receipt: ProviderRouteResolutionReceipt) {
        receiptID = receipt.receiptID
        selectionReason = receipt.selectionReason

        switch receipt.outcome {
        case .selected:
            outcome = .selected
            route = receipt.route
        case .fallback:
            outcome = .fallback
            route = receipt.route
        case .failure:
            outcome = .failure
            route = nil
        }
    }

    public init(
        receiptID: String,
        observedOutcome: String,
        route: ProviderRouteSnapshot?,
        selectionReason: String
    ) {
        self.receiptID = receiptID

        guard let outcome = ProviderRouteResolutionObservationOutcome(rawValue: observedOutcome) else {
            self.outcome = .failure
            self.route = nil
            self.selectionReason = "routing observation failed closed; unknown outcome=\(observedOutcome)"
            return
        }

        self.outcome = outcome
        self.route = outcome == .failure ? nil : route
        self.selectionReason = selectionReason
    }
}

/// Deterministic capability-first routing. It never infers capability from names.
public enum CapabilityRouter {
    /// A bounded identifier is safe to retain in a denial receipt without
    /// allowing an untrusted capability name to become an unbounded log/data
    /// payload. Whitespace is normalized, but the value is never interpreted
    /// as authorization.
    public static let maxCapabilityIdentifierLength = 128

    public static func boundedCapabilityIdentifier(_ raw: String) -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "<empty>" }
        return String(normalized.prefix(maxCapabilityIdentifierLength))
    }

    /// Resolves only the closed provider capability manifest. Unknown values
    /// fail before candidate/provider routing, and descriptions are ignored.
    public static func resolveCapabilities(_ rawCapabilities: Set<String>) throws -> Set<ProviderCapability> {
        var resolved = Set<ProviderCapability>()
        for raw in rawCapabilities {
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let capability = ProviderCapability(rawValue: normalized) else {
                throw CapabilityRoutingError.unknownCapability(boundedCapabilityIdentifier(normalized))
            }
            resolved.insert(capability)
        }
        return resolved
    }

    /// Routes only after resolving every external capability name.
    public static func route(
        rawRequiredCapabilities: Set<String>,
        candidates: [ProviderRouteCandidate],
        allowedProviderIDs: Set<String>? = nil,
        policy: ProviderRoutePolicy = .init(),
        configurationFingerprint: String? = nil
    ) throws -> ProviderRouteSnapshot {
        let request = try ProviderRouteRequest(
            rawRequiredCapabilities: rawRequiredCapabilities,
            allowedProviderIDs: allowedProviderIDs,
            policy: policy
        )
        return try route(request: request, candidates: candidates, configurationFingerprint: configurationFingerprint)
    }

    public static func route(request: ProviderRouteRequest, candidates: [ProviderRouteCandidate], configurationFingerprint: String? = nil) throws -> ProviderRouteSnapshot {
        let eligible = eligibleCandidates(request: request, candidates: candidates)
        guard let selected = eligible.max(by: { lhs, rhs in
            lhs.score == rhs.score ? lhs.index > rhs.index : lhs.score < rhs.score
        }) else { throw CapabilityRoutingError.noMatchingProvider }
        return ProviderRouteSnapshot(candidate: selected.candidate, requiredCapabilities: request.requiredCapabilities, configurationFingerprint: configurationFingerprint, selectionScore: selected.score)
    }

    private static func eligibleCandidates(
        request: ProviderRouteRequest,
        candidates: [ProviderRouteCandidate]
    ) -> [(index: Int, candidate: ProviderRouteCandidate, score: Double)] {
        candidates.enumerated().compactMap { index, candidate -> (index: Int, candidate: ProviderRouteCandidate, score: Double)? in
            let allowed = request.allowedProviderIDs.map { $0.contains(candidate.id) } ?? true
            guard allowed && candidate.capabilities.isSuperset(of: request.requiredCapabilities),
                  candidate.availability.isAvailable else { return nil }
            let score = request.policy.qualityWeight * candidate.qualityScore
                - request.policy.costWeight * candidate.costMicros
                - request.policy.latencyWeight * candidate.latencyMilliseconds
            return (index, candidate, score)
        }
    }

    private static func unavailableAuditReason(
        request: ProviderRouteRequest,
        candidates: [ProviderRouteCandidate]
    ) -> String? {
        let skipped = candidates.filter { candidate in
            let allowed = request.allowedProviderIDs.map { $0.contains(candidate.id) } ?? true
            return allowed
                && candidate.capabilities.isSuperset(of: request.requiredCapabilities)
                && !candidate.availability.isAvailable
        }
        guard !skipped.isEmpty else { return nil }
        return skipped.map {
            "\($0.id)=\($0.availability.auditReason)"
        }.joined(separator: ",")
    }

    public static func routeWithReceipt(request: ProviderRouteRequest, candidates: [ProviderRouteCandidate], receiptID: String, configurationFingerprint: String? = nil) throws -> ProviderRouteReceipt {
        let route = try route(request: request, candidates: candidates, configurationFingerprint: configurationFingerprint)
        let allowlistReason = request.allowedProviderIDs == nil ? "provider allowlist not constrained" : "provider allowlist satisfied"
        let unavailableReason = unavailableAuditReason(request: request, candidates: candidates)
            .map { "; skipped unavailable candidates: \($0)" } ?? ""
        return ProviderRouteReceipt(
            receiptID: receiptID,
            request: request,
            route: route,
            selectionReason: "required capabilities satisfied; \(allowlistReason); policy score=\(route.selectionScore); costWeight=\(request.policy.costWeight), latencyWeight=\(request.policy.latencyWeight), qualityWeight=\(request.policy.qualityWeight)\(unavailableReason)"
        )
    }

    /// Resolves the caller's explicit policy into an auditable selected, fallback, or failure receipt.
    public static func resolve(
        policyInput: ProviderRoutePolicyInput,
        candidates: [ProviderRouteCandidate],
        receiptID: String,
        configurationFingerprint: String? = nil
    ) -> ProviderRouteResolutionReceipt {
        do {
            let selected = try routeWithReceipt(
                request: policyInput.request,
                candidates: candidates,
                receiptID: receiptID,
                configurationFingerprint: configurationFingerprint
            )
            return ProviderRouteResolutionReceipt(
                receiptID: receiptID,
                policyInput: policyInput,
                outcome: .selected,
                route: selected.route,
                selectionReason: selected.selectionReason
            )
        } catch let error as CapabilityRoutingError {
            if case .unknownCapability(let capabilityID) = error {
                return ProviderRouteResolutionReceipt(
                    receiptID: receiptID,
                    policyInput: policyInput,
                    outcome: .failure(error),
                    route: nil,
                    selectionReason: "routing failed; unknown capability=\(capabilityID)"
                )
            }
            let unavailableReason = unavailableAuditReason(
                request: policyInput.request,
                candidates: candidates
            ).map { "; skipped unavailable candidates: \($0)" } ?? ""
            switch policyInput.fallback {
            case .fail:
                return ProviderRouteResolutionReceipt(
                    receiptID: receiptID,
                    policyInput: policyInput,
                    outcome: .failure(error),
                    route: nil,
                    selectionReason: "routing failed; no matching provider\(unavailableReason)"
                )
            case let .binding(providerID, providerName, modelID, fingerprint, reason):
                let candidate = ProviderRouteCandidate(
                    id: providerID,
                    providerName: providerName,
                    modelID: modelID,
                    capabilities: []
                )
                let route = ProviderRouteSnapshot(
                    candidate: candidate,
                    requiredCapabilities: [],
                    configurationFingerprint: fingerprint
                )
                return ProviderRouteResolutionReceipt(
                    receiptID: receiptID,
                    policyInput: policyInput,
                    outcome: .fallback,
                    route: route,
                    selectionReason: "fallback binding; \(reason)"
                )
            }
        } catch {
            return ProviderRouteResolutionReceipt(
                receiptID: receiptID,
                policyInput: policyInput,
                outcome: .failure(.noMatchingProvider),
                route: nil,
                selectionReason: "routing failed; no matching provider"
            )
        }
    }

    /// Routes a concrete provider binding only when its advertised capabilities
    /// cover the requested execution contract.
    public static func verifiedBindingReceipt(
        providerID: String,
        modelID: String,
        configurationFingerprint: String,
        requiredCapabilities: Set<ProviderCapability>,
        availableCapabilities: Set<ProviderCapability>
    ) throws -> ProviderRouteReceipt {
        let candidate = ProviderRouteCandidate(
            id: providerID,
            providerName: providerID,
            modelID: modelID,
            capabilities: availableCapabilities
        )
        let request = ProviderRouteRequest(requiredCapabilities: requiredCapabilities, allowedProviderIDs: [providerID])
        return try routeWithReceipt(
            request: request,
            candidates: [candidate],
            receiptID: "route:\(providerID):\(modelID):\(configurationFingerprint)",
            configurationFingerprint: configurationFingerprint
        )
    }

    /// Records a deterministic fallback binding while preserving the original policy input.
    /// No capability is inferred or advertised by this receipt.
    public static func fallbackBindingReceipt(
        providerID: String,
        modelID: String,
        configurationFingerprint: String,
        request: ProviderRouteRequest,
        reason: String
    ) -> ProviderRouteReceipt {
        let candidate = ProviderRouteCandidate(
            id: providerID,
            providerName: providerID,
            modelID: modelID,
            capabilities: []
        )
        let route = ProviderRouteSnapshot(
            candidate: candidate,
            requiredCapabilities: [],
            configurationFingerprint: configurationFingerprint
        )
        return ProviderRouteReceipt(
            receiptID: "route:\(providerID):\(modelID):\(configurationFingerprint)",
            request: request,
            route: route,
            selectionReason: "fallback binding; \(reason)"
        )
    }

    /// Records a frozen explicit/inherited provider-model binding at the routing seam.
    /// Capability intersection is empty here because capability selection belongs to A2;
    /// this receipt still makes the selected identity and configuration immutable/auditable.
    public static func frozenBindingReceipt(providerID: String, modelID: String, configurationFingerprint: String) -> ProviderRouteReceipt {
        let candidate = ProviderRouteCandidate(
            id: providerID,
            providerName: providerID,
            modelID: modelID,
            capabilities: []
        )
        let request = ProviderRouteRequest(requiredCapabilities: [], allowedProviderIDs: [providerID])
        let route = ProviderRouteSnapshot(
            candidate: candidate,
            requiredCapabilities: [],
            configurationFingerprint: configurationFingerprint
        )
        return ProviderRouteReceipt(
            receiptID: "route:\(providerID):\(modelID):\(configurationFingerprint)",
            request: request,
            route: route,
            selectionReason: "frozen provider/model binding; capability routing deferred to A2"
        )
    }
}
