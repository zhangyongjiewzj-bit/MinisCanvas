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
            return "基础地址格式不正确，请检查后重新填写。"
        case .unsupportedScheme(let scheme):
            _ = scheme
            return "基础地址的协议不受支持，请以 https:// 或 http:// 开头。"
        case .emptyHost:
            return "基础地址缺少主机名，请补全后重试。"
        case .embeddedCredentials:
            return "基础地址里不能包含用户名或密码，请把密钥填在 API Key 一栏。"
        case .credentialInQuery:
            return "基础地址的查询参数里不能带密钥，请把密钥填在 API Key 一栏。"
        case .credentialInFragment:
            return "基础地址的片段里不能带密钥，请把密钥填在 API Key 一栏。"
        case .controlCharacter:
            return "基础地址含有不可见的控制字符，请重新输入。"
        case .nonHTTPSHost:
            return "该基础地址不被接受，请改用 https:// 地址。"
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
        // 对齐 Claude Code：http 基础地址一律允许（本机、局域网中转站常见）；
        // 公网 http 会明文传输 Key，由设置表单提示风险，不在此处拒绝。

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

    /// 本机/局域网模型服务（Ollama、LM Studio 等）不校验 Key：API Key 留空时内部使用的占位值。
    public static let localPlaceholderAPIKey = "local-no-key"

    /// 基础地址指向本机或私网（任意协议）时，API Key 可以留空。
    public static func allowsBlankAPIKey(forBaseURL raw: String?) -> Bool {
        guard let raw else { return false }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty else { return false }
        return isLocalOrPrivateHost(host)
    }

    /// 基础地址是 http 且主机既不是本机也不是私网：Key 会在公网上明文传输，表单应提示风险。
    public static func isPlainHTTPToPublicHost(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "http",
              let host = components.host?.lowercased(), !host.isEmpty else { return false }
        return !isLocalOrPrivateHost(host)
    }

    /// localhost、127.0.0.0/8、::1、私网（10/8、172.16/12、192.168/16、169.254/16、fc00::/7、fe80::/10）
    /// 以及无点的内网主机名与 .local / .lan / .internal 后缀。
    public static func isLocalOrPrivateHost(_ rawHost: String) -> Bool {
        var host = rawHost.lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        if isLoopbackHost(host) { return true }
        if host.contains(":") {
            return host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80")
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        if octets.count == 4, let values = Optional(octets.compactMap { UInt8($0) }), values.count == 4 {
            switch (values[0], values[1]) {
            case (10, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            default: return false
            }
        }
        if !host.contains(".") { return true }
        return host.hasSuffix(".local") || host.hasSuffix(".lan") || host.hasSuffix(".internal")
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
