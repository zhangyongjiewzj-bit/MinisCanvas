import Foundation

/// Capability policy owned by the parent dispatch boundary.
///
/// An absent policy keeps the library's legacy orchestration behavior for
/// compatibility. When present, every capability and tool name is explicit;
/// empty sets deny rather than imply "all".
public struct AgentCapabilityPolicy: Sendable, Equatable {
    public let allowedCapabilities: Set<ProviderCapability>
    public let allowedToolNames: Set<String>
    public let allowedMCPToolNames: Set<String>

    public init(
        allowedCapabilities: Set<ProviderCapability>,
        allowedToolNames: Set<String> = [],
        allowedMCPToolNames: Set<String> = []
    ) {
        self.allowedCapabilities = allowedCapabilities
        self.allowedToolNames = allowedToolNames
        self.allowedMCPToolNames = allowedMCPToolNames
    }

    public static let denyAll = AgentCapabilityPolicy(allowedCapabilities: [])

    public func allows(_ capability: ProviderCapability) -> Bool {
        allowedCapabilities.contains(capability)
    }

    public func allowsTool(_ name: String) -> Bool {
        if name.hasPrefix("mcp_") {
            return allowedMCPToolNames.contains(name)
        }
        return allowedToolNames.contains(name)
    }
}

/// Pure contract for the capability grant at one child boundary.
public struct AgentCapabilityIntersection: Sendable, Equatable, Codable {
    public let parentCapabilities: Set<ProviderCapability>
    public let requestedCapabilities: Set<ProviderCapability>
    public let policyCapabilities: Set<ProviderCapability>
    /// The provider capability catalog captured at the child boundary.
    /// Callers may pass a narrower catalog than the enum's complete set;
    /// capabilities absent from it are never granted.
    public let catalogCapabilities: Set<ProviderCapability>
    public let grantedCapabilities: Set<ProviderCapability>
    public let missingCapabilities: Set<ProviderCapability>
    /// Raw capability names that were not recognized by the current catalog.
    /// Keeping these separate makes unknown input fail closed without
    /// pretending it is a known `ProviderCapability`.
    public let unknownCapabilities: Set<String>
    /// Recursive orchestration is never a child capability, even when the
    /// other three sets would otherwise intersect.
    public let requestsOrchestration: Bool

    public init(
        parentCapabilities: Set<ProviderCapability>,
        requestedCapabilities: Set<ProviderCapability>,
        policyCapabilities: Set<ProviderCapability>,
        catalogCapabilities: Set<ProviderCapability> = Set(ProviderCapability.allCases),
        requestsOrchestration: Bool = false,
        unknownCapabilities: Set<String> = []
    ) {
        self.parentCapabilities = parentCapabilities
        self.requestedCapabilities = requestedCapabilities
        self.policyCapabilities = policyCapabilities
        self.catalogCapabilities = catalogCapabilities
        self.requestsOrchestration = requestsOrchestration
        self.unknownCapabilities = unknownCapabilities
        let granted = parentCapabilities
            .intersection(requestedCapabilities)
            .intersection(catalogCapabilities)
            .intersection(policyCapabilities)
        self.grantedCapabilities = granted
        self.missingCapabilities = requestedCapabilities.subtracting(granted)
    }

    private enum CodingKeys: String, CodingKey {
        case parentCapabilities
        case requestedCapabilities
        case policyCapabilities
        case catalogCapabilities
        case grantedCapabilities
        case missingCapabilities
        case unknownCapabilities
        case requestsOrchestration
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let parentCapabilities = try container.decode(
            Set<ProviderCapability>.self,
            forKey: .parentCapabilities
        )
        let requestedCapabilities = try container.decode(
            Set<ProviderCapability>.self,
            forKey: .requestedCapabilities
        )
        let policyCapabilities = try container.decode(
            Set<ProviderCapability>.self,
            forKey: .policyCapabilities
        )
        let catalogCapabilities = try container.decode(
            Set<ProviderCapability>.self,
            forKey: .catalogCapabilities
        )
        let storedGrantedCapabilities = try container.decode(
            Set<ProviderCapability>.self,
            forKey: .grantedCapabilities
        )
        let storedMissingCapabilities = try container.decode(
            Set<ProviderCapability>.self,
            forKey: .missingCapabilities
        )
        let unknownCapabilities = try container.decode(
            Set<String>.self,
            forKey: .unknownCapabilities
        )
        let requestsOrchestration = try container.decode(
            Bool.self,
            forKey: .requestsOrchestration
        )

        let resolved = Self(
            parentCapabilities: parentCapabilities,
            requestedCapabilities: requestedCapabilities,
            policyCapabilities: policyCapabilities,
            catalogCapabilities: catalogCapabilities,
            requestsOrchestration: requestsOrchestration,
            unknownCapabilities: unknownCapabilities
        )
        guard resolved.grantedCapabilities == storedGrantedCapabilities else {
            throw DecodingError.dataCorruptedError(
                forKey: .grantedCapabilities,
                in: container,
                debugDescription: "Persisted capability grant does not match its immutable intersection"
            )
        }
        guard resolved.missingCapabilities == storedMissingCapabilities else {
            throw DecodingError.dataCorruptedError(
                forKey: .missingCapabilities,
                in: container,
                debugDescription: "Persisted missing capabilities do not match the resolved intersection"
            )
        }
        self = resolved
    }

    public var isAllowed: Bool {
        !requestsOrchestration
            && unknownCapabilities.isEmpty
            && (requestedCapabilities.isEmpty || missingCapabilities.isEmpty)
    }

    public static func resolve(
        parentCapabilities: Set<ProviderCapability>,
        requestedCapabilities: Set<ProviderCapability>,
        policyCapabilities: Set<ProviderCapability>,
        catalogCapabilities: Set<ProviderCapability> = Set(ProviderCapability.allCases),
        requestsOrchestration: Bool = false
    ) -> AgentCapabilityIntersection {
        AgentCapabilityIntersection(
            parentCapabilities: parentCapabilities,
            requestedCapabilities: requestedCapabilities,
            policyCapabilities: policyCapabilities,
            catalogCapabilities: catalogCapabilities,
            requestsOrchestration: requestsOrchestration
        )
    }

    /// Resolve an untrusted/raw capability request without allowing unknown
    /// names to enter the typed grant. This is the boundary used by callers
    /// that receive capability names from a wire or task payload.
    public static func resolve(
        parentCapabilities: Set<ProviderCapability>,
        requestedCapabilityNames: Set<String>,
        policyCapabilities: Set<ProviderCapability>,
        catalogCapabilities: Set<ProviderCapability> = Set(ProviderCapability.allCases),
        requestsOrchestration: Bool = false
    ) -> AgentCapabilityIntersection {
        let requested = Set(requestedCapabilityNames.compactMap(ProviderCapability.init(rawValue:)))
        let knownNames = Set(requested.map(\.rawValue))
        return AgentCapabilityIntersection(
            parentCapabilities: parentCapabilities,
            requestedCapabilities: requested,
            policyCapabilities: policyCapabilities,
            catalogCapabilities: catalogCapabilities,
            requestsOrchestration: requestsOrchestration,
            unknownCapabilities: requestedCapabilityNames.subtracting(knownNames)
        )
    }
}
