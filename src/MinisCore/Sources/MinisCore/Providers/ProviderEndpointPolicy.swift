import Foundation

/// The stable, non-secret identity of a provider endpoint.
public struct ProviderEndpointIdentity: Codable, Equatable, Hashable, Sendable {
    public let canonicalURL: URL
    public let scheme: String
    public let host: String
    public let port: Int?
    public let path: String

    public var identity: String { canonicalURL.absoluteString }

    public init(canonicalURL: URL, scheme: String, host: String, port: Int?, path: String) {
        self.canonicalURL = canonicalURL
        self.scheme = scheme
        self.host = host
        self.port = port
        self.path = path
    }
}

/// Safe failures for user-controlled provider endpoint input.
///
/// The errors intentionally carry no URL, query, fragment, or credential
/// material. Callers can show the localized reason without echoing input.
public enum ProviderEndpointPolicyError: Error, Equatable, Sendable, LocalizedError {
    case invalidURL
    case unsupportedScheme(String?)
    case emptyHost
    case embeddedCredentials
    case credentialInQuery
    case credentialInFragment
    case controlCharacter
    case nonHTTPSHost

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "not a valid provider endpoint"
        case .unsupportedScheme(let scheme):
            let shown = scheme ?? "<missing>"
            return "unsupported scheme '\(shown)'; only https (or explicit loopback http) is allowed"
        case .emptyHost:
            return "provider endpoint is missing a host"
        case .embeddedCredentials:
            return "provider endpoint must not embed userinfo credentials"
        case .credentialInQuery:
            return "provider endpoint query must not contain credential-like fields"
        case .credentialInFragment:
            return "provider endpoint fragment must not contain credential-like fields"
        case .controlCharacter:
            return "provider endpoint must not contain control characters"
        case .nonHTTPSHost:
            return "http provider endpoints are allowed only for explicit loopback hosts"
        }
    }
}

/// Canonical validation shared by custom provider URLs and redirect targets.
public enum ProviderEndpointPolicy {
    private static let sensitiveTokens: Set<String> = [
        "token", "key", "apikey", "api_key",
        "accesskey", "access_key", "accesstoken", "access_token",
        "secret", "password", "credential", "credentials",
        "authorization", "auth", "bearer", "privatekey", "private_key"
    ]

    /// Validates and canonicalizes a user-controlled endpoint without
    /// contacting it or reading credentials.
    public static func canonicalize(_ raw: String) throws -> ProviderEndpointIdentity {
        guard !containsControlCharacters(raw) else {
            throw ProviderEndpointPolicyError.controlCharacter
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProviderEndpointPolicyError.invalidURL
        }
        guard var components = URLComponents(string: trimmed) else {
            throw ProviderEndpointPolicyError.invalidURL
        }

        let scheme = components.scheme?.lowercased()
        guard let scheme, !scheme.isEmpty, scheme == "https" || scheme == "http" else {
            throw ProviderEndpointPolicyError.unsupportedScheme(scheme)
        }
        guard let host = components.host, !host.isEmpty else {
            throw ProviderEndpointPolicyError.emptyHost
        }
        guard components.user == nil, components.password == nil else {
            throw ProviderEndpointPolicyError.embeddedCredentials
        }

        if containsControlCharacters(host) || containsControlCharacters(host.removingPercentEncoding) {
            throw ProviderEndpointPolicyError.controlCharacter
        }
        if containsControlCharacters(components.percentEncodedPath.removingPercentEncoding ?? components.percentEncodedPath) {
            throw ProviderEndpointPolicyError.controlCharacter
        }
        if containsCredentialMarker(components.percentEncodedQuery) {
            throw ProviderEndpointPolicyError.credentialInQuery
        }
        if containsControlCharacters(components.percentEncodedQuery?.removingPercentEncoding ?? components.percentEncodedQuery) {
            throw ProviderEndpointPolicyError.controlCharacter
        }
        if containsCredentialMarker(components.percentEncodedFragment) {
            throw ProviderEndpointPolicyError.credentialInFragment
        }
        if containsControlCharacters(components.percentEncodedFragment?.removingPercentEncoding ?? components.percentEncodedFragment) {
            throw ProviderEndpointPolicyError.controlCharacter
        }

        let lowerHost = host.lowercased()
        if scheme == "http" && !isLoopbackHost(lowerHost) {
            throw ProviderEndpointPolicyError.nonHTTPSHost
        }

        components.scheme = scheme
        components.host = lowerHost
        if (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80) {
            components.port = nil
        }

        let originalPath = components.percentEncodedPath
        let normalizedPath: String
        if originalPath.isEmpty {
            normalizedPath = "/"
        } else {
            var path = originalPath
            while path.count > 1 && path.hasSuffix("/") {
                path.removeLast()
            }
            normalizedPath = path
        }
        components.percentEncodedPath = normalizedPath

        guard let canonicalURL = components.url else {
            throw ProviderEndpointPolicyError.invalidURL
        }
        return ProviderEndpointIdentity(
            canonicalURL: canonicalURL,
            scheme: scheme,
            host: lowerHost,
            port: components.port,
            path: normalizedPath
        )
    }

    /// Returns false for any destination that cannot pass the same endpoint
    /// policy as a custom provider URL.
    public static func isSafeDestination(_ url: URL) -> Bool {
        (try? canonicalize(url.absoluteString)) != nil
    }

    private static func containsCredentialMarker(_ raw: String?) -> Bool {
        guard let raw, !raw.isEmpty else { return false }
        let decoded = raw.removingPercentEncoding ?? raw
        let lowercased = decoded.lowercased()
        let tokens = lowercased.split { character in
            !character.isLetter && !character.isNumber && character != "_"
        }
        return tokens.contains { token in
            sensitiveTokens.contains(String(token))
        }
    }

    private static func containsControlCharacters(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func isLoopbackHost(_ rawHost: String) -> Bool {
        var host = rawHost
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        let lower = host.lowercased()
        if lower == "localhost" { return true }
        if lower == "::1" || lower == "0:0:0:0:0:0:0:1" { return true }
        let octets = host.split(separator: ".")
        guard octets.count == 4, octets[0] == "127" else { return false }
        return octets.dropFirst().allSatisfy { UInt8($0) != nil }
    }
}
