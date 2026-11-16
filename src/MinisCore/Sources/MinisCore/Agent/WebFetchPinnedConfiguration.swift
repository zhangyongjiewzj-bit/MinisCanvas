import Foundation

/// Trusted composition metadata, not a permission or persistent rule. The
/// exact defaults comparison prevents a mixed Goal set from becoming provenance.
public struct WebFetchPinnedConfiguration: Sendable {
    public let provenance: NetworkDomainConfigurationProvenance
    public let configuredDomains: Set<String>
    public let externalNetworkAllowed: Bool
    public let routeProvider: WebFetchPinnedRouteProvider
    let operations: WebFetchPinnedOperations

    public init(provenance: NetworkDomainConfigurationProvenance,
                configuredDomains: Set<String>, externalNetworkAllowed: Bool,
                routeProvider: @escaping WebFetchPinnedRouteProvider) {
        self.provenance = provenance
        self.configuredDomains = configuredDomains
        self.externalNetworkAllowed = externalNetworkAllowed
        self.routeProvider = routeProvider
        self.operations = .production
    }

    /// Internal synthetic transport seam; production always uses the fixed
    /// resolver and fixed-binary backend above, with no runtime fallback.
    init(provenance: NetworkDomainConfigurationProvenance, configuredDomains: Set<String>,
         externalNetworkAllowed: Bool, routeProvider: @escaping WebFetchPinnedRouteProvider,
         operations: WebFetchPinnedOperations) {
        self.provenance = provenance
        self.configuredDomains = configuredDomains
        self.externalNetworkAllowed = externalNetworkAllowed
        self.routeProvider = routeProvider
        self.operations = operations
    }

    func isWithinConfiguredCeiling(_ url: URL) -> Bool {
        BrowserNavigationPolicy(allowedDomains: configuredDomains, allowsSameOrigin: false,
            allowsLocalContent: false).decision(for: url, source: .initial,
                scopeID: "web-fetch", expectedScopeID: "web-fetch", generation: 1,
                expectedGeneration: 1, currentURL: nil).denial == nil
    }

    public var isAdmitted: Bool {
        externalNetworkAllowed
            && provenance.origin == .actualLocalSettingsConfiguredCeiling
            && provenance.configuredDomains == configuredDomains
    }
}

struct WebFetchPinnedOperations: Sendable {
    let resolve: @Sendable (WebFetchEndpoint) async throws -> [WebFetchNumericAddress]
    let load: @Sendable (WebFetchPinnedCurlInvocation, URL) async throws -> WebFetchHop
    static let production = Self(resolve: WebFetchPinnedResolver.resolve,
        load: { invocation, url in try await WebFetchPinnedBackend.load(invocation, url: url) })
}
