import Foundation

/// Deterministic DNS answer set supplied to a credentialed redirect guard.
///
/// A snapshot is intentionally inert: it never performs name resolution. A
/// caller can capture answers at request admission and inject them into the
/// guard, allowing redirect decisions and tests to use the same fixed input.
public struct ProviderAddressResolutionSnapshot: Equatable, Sendable {
    public let addressesByHost: [String: [String]]
    public let approvedPrivateAddresses: Set<String>

    public init(
        addressesByHost: [String: [String]],
        approvedPrivateAddresses: Set<String> = []
    ) {
        var normalizedHosts: [String: [String]] = [:]
        for (host, addresses) in addressesByHost {
            let key = Self.normalizeHost(host)
            let values = addresses.compactMap(Self.normalizeAddress)
            normalizedHosts[key] = Array(Set(values)).sorted()
        }
        self.addressesByHost = normalizedHosts
        self.approvedPrivateAddresses = Set(approvedPrivateAddresses.compactMap(Self.normalizeAddress))
    }

    public func addresses(for host: String) -> [String]? {
        addressesByHost[Self.normalizeHost(host)]
    }

    private static func normalizeHost(_ raw: String) -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        return host
    }

    private static func normalizeAddress(_ raw: String) -> String? {
        let address = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !address.isEmpty else { return nil }
        let octets = address.split(separator: ".", omittingEmptySubsequences: false)
        if octets.count == 4,
           octets.allSatisfy({ UInt16($0) != nil && UInt16($0)! <= 255 }) {
            return octets.map(String.init).joined(separator: ".")
        }
        guard let words = Self.parseIPv6(address) else { return nil }
        return words.map { String($0, radix: 16) }.joined(separator: ":")
    }

    private static func parseIPv6(_ raw: String) -> [UInt16]? {
        guard !raw.isEmpty, !raw.contains("%") else { return nil }
        var value = raw
        if let lastColon = value.lastIndex(of: ":"), value[value.index(after: lastColon)...].contains(".") {
            let ipv4Text = String(value[value.index(after: lastColon)...])
            let octets = ipv4Text.split(separator: ".", omittingEmptySubsequences: false)
            guard octets.count == 4,
                  let a = UInt16(octets[0]), let b = UInt16(octets[1]),
                  let c = UInt16(octets[2]), let d = UInt16(octets[3]),
                  [a, b, c, d].allSatisfy({ $0 <= 255 }) else { return nil }
            value = String(value[..<lastColon]) + ":" + String((a << 8) | b) + ":" + String((c << 8) | d)
        }

        if value.contains("::") {
            let parts = value.components(separatedBy: "::")
            guard parts.count == 2 else { return nil }
            let left = parseIPv6Groups(parts[0])
            let right = parseIPv6Groups(parts[1])
            guard left.count + right.count < 8 else { return nil }
            return left + Array(repeating: 0, count: 8 - left.count - right.count) + right
        }
        let groups = parseIPv6Groups(value)
        return groups.count == 8 ? groups : nil
    }

    private static func parseIPv6Groups(_ raw: String) -> [UInt16] {
        guard !raw.isEmpty else { return [] }
        let pieces = raw.split(separator: ":", omittingEmptySubsequences: false)
        let parsed: [UInt16] = pieces.compactMap { piece -> UInt16? in
            guard !piece.isEmpty, piece.count <= 4 else { return nil }
            return UInt16(piece, radix: 16)
        }
        return parsed.count == pieces.count ? parsed : []
    }
}

/// Redirect-specific credential and chain policy for credentialed providers.
///
/// `URLSession` supplies the next request to its task delegate. This policy
/// validates that destination through `ProviderEndpointPolicy`, keeps
/// credential headers on the same origin, and strips them before a
/// cross-origin redirect. A caller tracks the visited canonical URLs so a
/// loop is rejected before another request is admitted.
public enum ProviderRedirectPolicy {
    public static let maximumRedirectHops = 5

    private static let credentialHeaderNames: Set<String> = [
        "authorization",
        "proxy-authorization",
        "cookie",
        "cookie2",
        "set-cookie",
        "api-key",
        "api_key",
        "apikey",
        "x-api-key",
        "x_api_key",
        "x-goog-api-key",
        "x-auth-token",
        "auth-token",
        "ocp-apim-subscription-key",
        "subscription-key"
    ]

    /// Makes a redirect decision without network I/O.
    ///
    /// `visitedCanonicalURLs` should contain the source URL and all prior
    /// destinations. The returned request is unchanged for same-origin
    /// redirects; for cross-origin redirects credential-bearing headers are
    /// removed and cookie handling is disabled. `nil` is an explicit
    /// fail-closed rejection for an unsafe destination, loop, or hop limit.
    public static func redirectedRequest(
        from source: URL,
        to request: URLRequest,
        hopCount: Int,
        visitedCanonicalURLs: Set<String> = [],
        resolutionSnapshot: ProviderAddressResolutionSnapshot? = nil,
        resolvedAddressHistory: [String: [String]] = [:],
        requireResolution: Bool = true
    ) -> URLRequest? {
        guard hopCount > 0, hopCount <= maximumRedirectHops,
              let destination = request.url,
              let sourceIdentity = try? ProviderEndpointPolicy.canonicalize(source.absoluteString),
              let destinationIdentity = try? ProviderEndpointPolicy.canonicalize(destination.absoluteString),
              !visitedCanonicalURLs.contains(destinationIdentity.identity),
              let sourceAddresses = resolvedAddresses(
                  for: sourceIdentity,
                  using: resolutionSnapshot,
                  requireResolution: requireResolution
              ),
              let destinationAddresses = resolvedAddresses(
                  for: destinationIdentity,
                  using: resolutionSnapshot,
                  requireResolution: requireResolution
              ),
              addressesMatchHistory(
                  sourceAddresses,
                  for: sourceIdentity.host,
                  history: resolvedAddressHistory
              ),
              addressesMatchHistory(
                  destinationAddresses,
                  for: destinationIdentity.host,
                  history: resolvedAddressHistory
              ) else {
            return nil
        }

        // A credentialed HTTPS request never follows a downgrade, even to a
        // loopback destination. HTTP redirects are valid only when the
        // original request was already an explicit loopback HTTP request;
        // ProviderEndpointPolicy enforces that property for both endpoints.
        if sourceIdentity.scheme == "https" && destinationIdentity.scheme == "http" {
            return nil
        }

        var redirected = request
        if origin(of: sourceIdentity) != origin(of: destinationIdentity) {
            for field in (redirected.allHTTPHeaderFields ?? [:]).keys {
                if isCredentialHeader(field) {
                    redirected.setValue(nil, forHTTPHeaderField: field)
                }
            }
            // Prevent URLSession's cookie storage from adding a cross-origin
            // Cookie after the explicit header is removed.
            redirected.httpShouldHandleCookies = false
        }
        return redirected
    }

    private static func origin(of identity: ProviderEndpointIdentity) -> String {
        "\(identity.scheme)://\(identity.host):\(identity.port.map(String.init) ?? defaultPort(for: identity.scheme))"
    }

    private static func defaultPort(for scheme: String) -> String {
        scheme == "http" ? "80" : "443"
    }

    private static func isCredentialHeader(_ rawName: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if credentialHeaderNames.contains(name) { return true }
        let compact = name.replacingOccurrences(of: "_", with: "-")
        return compact.contains("api-key") || compact.contains("auth-token")
    }

    /// Returns canonical resolved addresses for one endpoint using an
    /// injected snapshot. Literal IP hosts can be checked without a snapshot;
    /// hostnames require one when `requireResolution` is true.
    public static func resolvedAddresses(
        for url: URL,
        using snapshot: ProviderAddressResolutionSnapshot?,
        requireResolution: Bool = true
    ) -> [String]? {
        guard let identity = try? ProviderEndpointPolicy.canonicalize(url.absoluteString) else { return nil }
        return resolvedAddresses(for: identity, using: snapshot, requireResolution: requireResolution)
    }

    private static func resolvedAddresses(
        for identity: ProviderEndpointIdentity,
        using snapshot: ProviderAddressResolutionSnapshot?,
        requireResolution: Bool
    ) -> [String]? {
        let host = identity.host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let literal = normalizedAddress(host) {
            return safeAddresses([literal], approvedPrivateAddresses: snapshot?.approvedPrivateAddresses ?? [])
        }
        guard let snapshot, let addresses = snapshot.addresses(for: host) else {
            return requireResolution ? nil : []
        }
        return safeAddresses(addresses, approvedPrivateAddresses: snapshot.approvedPrivateAddresses)
    }

    private static func addressesMatchHistory(
        _ addresses: [String],
        for host: String,
        history: [String: [String]]
    ) -> Bool {
        let key = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        guard let previous = history[key] else { return true }
        return previous.sorted() == addresses.sorted()
    }

    private static func safeAddresses(
        _ addresses: [String],
        approvedPrivateAddresses: Set<String>
    ) -> [String]? {
        let normalized = Array(Set(addresses.compactMap(normalizedAddress))).sorted()
        guard !normalized.isEmpty else { return nil }
        for address in normalized {
            switch classify(address) {
            case .public, .loopback:
                continue
            case .privateNetwork:
                guard approvedPrivateAddresses.contains(address) else { return nil }
            case .linkLocal, .multicast, .unspecified, .invalid:
                return nil
            }
        }
        return normalized
    }

    private enum AddressClass {
        case `public`
        case loopback
        case privateNetwork
        case linkLocal
        case multicast
        case unspecified
        case invalid
    }

    private static func normalizedAddress(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let octets = value.split(separator: ".", omittingEmptySubsequences: false)
        let values = octets.compactMap { UInt16($0) }
        if octets.count == 4,
           values.count == 4,
           values.allSatisfy({ $0 <= 255 }) {
            return values.map(String.init).joined(separator: ".")
        }
        guard let words = parseIPv6(value) else { return nil }
        return words.map { String($0, radix: 16) }.joined(separator: ":")
    }

    private static func parseIPv6(_ raw: String) -> [UInt16]? {
        guard !raw.isEmpty, !raw.contains("%") else { return nil }
        var value = raw
        if let lastColon = value.lastIndex(of: ":"), value[value.index(after: lastColon)...].contains(".") {
            let ipv4Text = String(value[value.index(after: lastColon)...])
            let octets = ipv4Text.split(separator: ".", omittingEmptySubsequences: false)
            guard octets.count == 4,
                  let a = UInt16(octets[0]), let b = UInt16(octets[1]),
                  let c = UInt16(octets[2]), let d = UInt16(octets[3]),
                  [a, b, c, d].allSatisfy({ $0 <= 255 }) else { return nil }
            value = String(value[..<lastColon]) + ":" + String((a << 8) | b) + ":" + String((c << 8) | d)
        }
        if value.contains("::") {
            let parts = value.components(separatedBy: "::")
            guard parts.count == 2 else { return nil }
            let left = parseIPv6Groups(parts[0])
            let right = parseIPv6Groups(parts[1])
            guard left.count + right.count < 8 else { return nil }
            return left + Array(repeating: 0, count: 8 - left.count - right.count) + right
        }
        let groups = parseIPv6Groups(value)
        return groups.count == 8 ? groups : nil
    }

    private static func parseIPv6Groups(_ raw: String) -> [UInt16] {
        guard !raw.isEmpty else { return [] }
        let pieces = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.allSatisfy({ !$0.isEmpty && $0.count <= 4 }) else { return [] }
        let parsed: [UInt16] = pieces.compactMap { UInt16($0, radix: 16) }
        return parsed.count == pieces.count ? parsed : []
    }

    private static func classify(_ address: String) -> AddressClass {
        let octets = address.split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt16($0) }
        if octets.count == 4 {
            let a = octets[0], b = octets[1]
            if a == 0 { return .unspecified }
            if a == 127 { return .loopback }
            if a == 169 && b == 254 { return .linkLocal }
            if a >= 224 && a <= 239 { return .multicast }
            if a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) {
                return .privateNetwork
            }
            if a == 100 && (64...127).contains(b) { return .privateNetwork }
            if a == 192 && b == 0 { return .privateNetwork }
            if a == 198 && (18...19).contains(b) { return .privateNetwork }
            return .public
        }
        guard let words = parseIPv6(address), words.count == 8 else { return .invalid }
        if words.allSatisfy({ $0 == 0 }) { return .unspecified }
        if words.dropLast().allSatisfy({ $0 == 0 }) && words[7] == 1 { return .loopback }
        if (words[0] & 0xffc0) == 0xfe80 { return .linkLocal }
        if (words[0] & 0xff00) == 0xff00 { return .multicast }
        if (words[0] & 0xfe00) == 0xfc00 || (words[0] & 0xffc0) == 0xfec0 {
            return .privateNetwork
        }
        if words[0...4].allSatisfy({ $0 == 0 }) && words[5] == 0xffff {
            let high = words[6], low = words[7]
            let mapped = [high >> 8, high & 255, low >> 8, low & 255].map(String.init).joined(separator: ".")
            return classify(mapped)
        }
        return .public
    }
}
