import Foundation
import Darwin

/// A connection target, never an authorization source. Constructed after the
/// existing controller has authorized the exact URL; resolving it grants nothing.
struct WebFetchEndpoint: Equatable, Sendable {
    let url: URL
    let host: String
    let connectionHost: String
    let port: Int

    init(_ url: URL) throws {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), scheme == "https",
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              let rawHost = parts.host,
              let host = BrowserNavigationPolicy.normalizedHost(rawHost),
              !host.contains(":"), !host.contains("["), !host.contains("]"),
              host.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 }),
              !host.split(separator: ".").isEmpty else {
            throw ToolExecutorError.invalidParameter("url")
        }
        let port = parts.port ?? (scheme == "https" ? 443 : 80)
        guard (1...65535).contains(port) else { throw ToolExecutorError.invalidParameter("url") }
        self.url = url
        self.host = host
        self.connectionHost = rawHost
        self.port = port
    }

    var displayAuthority: String { "\(host):\(port)" }
}

/// Numeric address returned by the resolver. No hostnames can enter curl's
/// connection override, so the actual connection cannot perform a second DNS
/// lookup for the authorized origin. Original URL still supplies TLS SNI/name.
struct WebFetchNumericAddress: Equatable, Sendable {
    let value: String
    let isPublic: Bool
    private let comparisonKey: [UInt8]

    init(_ value: String) throws {
        guard !value.isEmpty, value.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
                || $0 == 46 || $0 == 58
        }) else { throw ToolExecutorError.invalidParameter("resolvedAddress") }
        var v4 = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            let bytes = withUnsafeBytes(of: v4) { Array($0) }
            let a = bytes[0], b = bytes[1]
            self.value = value
            self.comparisonKey = [4] + bytes
            // Includes non-routable, multicast and reserved ranges. Dynamic
            // website consent must never turn into a local-network capability.
            isPublic = !(a == 0 || a == 10 || a == 127 || a >= 224
                || (a == 100 && (64...127).contains(b))
                || (a == 169 && b == 254) || (a == 172 && (16...31).contains(b))
                || (a == 192 && (b == 0 || b == 168)) || (a == 198 && (b == 18 || b == 19))
                || (a == 198 && b == 51 && bytes[2] == 100)
                || (a == 203 && b == 0 && bytes[2] == 113))
            return
        }
        var v6 = in6_addr()
        guard value.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 else {
            throw ToolExecutorError.invalidParameter("resolvedAddress")
        }
        let bytes = withUnsafeBytes(of: v6) { Array($0) }
        self.value = value
        self.comparisonKey = [6] + bytes
        // Public IPv6 unicast only. This also excludes mapped IPv4, local,
        // link-local, loopback and multicast forms instead of reclassifying them.
        let transition6to4 = bytes[0] == 0x20 && bytes[1] == 0x02
        let teredo = bytes[0...3].elementsEqual([0x20, 0x01, 0x00, 0x00])
        let documentation = bytes[0...3].elementsEqual([0x20, 0x01, 0x0d, 0xb8])
        let orchid = bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0
            && ((bytes[3] & 0xf0) == 0x10 || (bytes[3] & 0xf0) == 0x20)
        isPublic = (bytes[0] & 0xe0) == 0x20
            && !transition6to4 && !teredo && !documentation && !orchid
    }

    func representsSameAddress(as other: WebFetchNumericAddress) -> Bool {
        comparisonKey == other.comparisonKey
    }

    var curlAddress: String { value.contains(":") ? "[\(value)]" : value }
}

/// Route metadata is supplied by the trusted App profile. Absence of a known
/// route is not proof of direct routing; no environment/system-proxy inference.
public enum WebFetchPinnedRoute: Equatable, Sendable {
    case directConfirmed
    case proxyRequiresExistingRoute
    case unknown

    func requireConfirmedDirect() throws {
        switch self {
        case .directConfirmed: return
        case .proxyRequiresExistingRoute: throw WebFetchPinnedError.unsupportedRoute
        case .unknown: throw WebFetchPinnedError.unconfirmedRoute
        }
    }
}

/// Called afresh for each exact hop URL, immediately before its connection.
public typealias WebFetchPinnedRouteProvider = @Sendable (URL) -> WebFetchPinnedRoute

/// Display projection only; this does not authorize the URL or resolve DNS.
public enum WebFetchApprovalDisplay {
    public static func authority(for url: URL) throws -> String {
        let host = try WebFetchToolContract.normalizedURLHost(["url": url.absoluteString])
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil else { throw ToolExecutorError.invalidParameter("url") }
        let port = parts.port ?? (parts.scheme?.lowercased() == "https" ? 443 : 80)
        guard (1...65535).contains(port) else { throw ToolExecutorError.invalidParameter("url") }
        let displayHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "\(displayHost):\(port)"
    }
}

/// Pure argument construction. This value does not run a process, resolve DNS,
/// authorize a host or read any environment/configuration/credential file.
struct WebFetchPinnedCurlInvocation: Sendable {
    let executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    let arguments: [String]
    let pinnedAddress: WebFetchNumericAddress
    let environment: [String: String] = ["LANG": "C", "LC_ALL": "C"]

    init(endpoint: WebFetchEndpoint, address: WebFetchNumericAddress,
         route: WebFetchPinnedRoute) throws {
        guard route == .directConfirmed else { throw WebFetchPinnedError.unsupportedRoute }
        guard address.isPublic && endpoint.host != "localhost"
            && !endpoint.host.hasSuffix(".localhost") && !endpoint.host.hasSuffix(".local") else {
            throw WebFetchPinnedError.nonPublicDestination
        }
        pinnedAddress = address
        arguments = ["-q", "--silent", "--show-error", "--globoff",
            "--proto", "=https", "--max-redirs", "0", "--request", "GET", "--max-time", "30",
            "--max-filesize", String(WebFetchTransport.maximumBytes),
            "--proxy", "", "--noproxy", "*",
            "--connect-to", "\(endpoint.connectionHost):\(endpoint.port):\(address.curlAddress):\(endpoint.port)",
            "--write-out", WebFetchPinnedBackend.remoteIPWriteOut,
            "--header", "Accept: text/html, application/xhtml+xml, text/plain",
            "--url", endpoint.url.absoluteString]
    }
}

enum WebFetchPinnedError: Error, Equatable {
    case unsupportedRoute
    case unconfirmedRoute
    case nonPublicDestination
    case connectionFailed
}

extension WebFetchPinnedError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unsupportedRoute:
            return "已停止抓取：检测到代理配置或需要经过代理，无法在这条路径固定公网 IP。\(Self.systemRouteGuidance)"
        case .unconfirmedRoute:
            return "已停止抓取：无法确认直连路径，不能安全固定公网 IP。请检查系统网络配置。\(Self.systemRouteGuidance)"
        case .nonPublicDestination:
            return "域名解析到非公网地址，已阻止连接。请核对目标网站和网络配置后重试。"
        case .connectionFailed:
            return "连接失败或无法确认目标连接，已停止抓取。请检查网络和目标网站后重试。"
        }
    }

    private static let systemRouteGuidance =
        "若要使用系统网络路径，请在\(BrowserNavigationPolicy.allowedWebsitesSettingsPath)的“\(BrowserNavigationPolicy.allowedWebsitesSettingLabel)”中加入已核实的起始域名及所需跳转域名，保存后在新回合重试。这条路径不固定 IP，仍受系统网络配置限制。只加入跳转域名不会改变临时抓取的直连要求。"
}
