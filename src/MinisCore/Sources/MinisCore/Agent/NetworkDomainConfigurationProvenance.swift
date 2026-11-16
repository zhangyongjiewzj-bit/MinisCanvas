import Foundation

/// Provenance of the configuration ceiling, never a call approval or a grant.
/// Only the App's authoritative settings producer may attest local settings;
/// a Goal's merged domains or a bare injected defaults value remain unknown.
/// Runtime-only: no persisted authority can be decoded through this value.
public struct NetworkDomainConfigurationProvenance: Equatable, Sendable {
    public enum Origin: Equatable, Sendable {
        case unknown
        /// The current local AgentSettings configuration, including a backup
        /// explicitly imported into that settings authority. This does not
        /// assert that the user manually typed every individual domain.
        case actualLocalSettingsConfiguredCeiling
    }

    public let origin: Origin
    public let configuredDomains: Set<String>

    public static let unknown = Self(origin: .unknown, configuredDomains: [])

    /// Composition metadata only. Consumers must also compare the exact
    /// domains with their captured defaults and enforce current call denies.
    public static func actualLocalSettingsConfiguredCeiling(domains: Set<String>) -> Self {
        Self(origin: .actualLocalSettingsConfiguredCeiling, configuredDomains: domains)
    }

    private init(origin: Origin, configuredDomains: Set<String>) {
        self.origin = origin
        self.configuredDomains = configuredDomains
    }
}
