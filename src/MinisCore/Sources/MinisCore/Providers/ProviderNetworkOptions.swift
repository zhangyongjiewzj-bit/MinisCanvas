import Foundation

/// 服务商的一条自定义请求头。值要么是字面文本（只适合非密钥内容，如组织标识），
/// 要么是环境变量名（`valueIsEnvVar == true`），运行时才取值，配置文件里不存密钥。
public struct ProviderCustomHeader: Codable, Hashable, Sendable {
    public var name: String
    public var value: String
    public var valueIsEnvVar: Bool

    public init(name: String, value: String, valueIsEnvVar: Bool = false) {
        self.name = name
        self.value = value
        self.valueIsEnvVar = valueIsEnvVar
    }
}

/// 服务商请求走的代理：跟随系统 / 不用代理 / 指定 HTTP(S) 代理地址。
public struct ProviderProxySetting: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, Sendable {
        case system, direct, custom
    }

    public var mode: Mode
    /// 仅 `.custom` 使用，形如 `http://127.0.0.1:7890`；不允许带用户名密码。
    public var url: String?

    public init(mode: Mode = .system, url: String? = nil) {
        self.mode = mode
        self.url = url
    }

    public static let system = ProviderProxySetting()
}

/// 供应商级网络选项：自定义请求头 + 代理。全部可选，旧配置缺省即默认值。
public struct ProviderNetworkOptions: Codable, Hashable, Sendable {
    public var headers: [ProviderCustomHeader]
    public var proxy: ProviderProxySetting

    public init(headers: [ProviderCustomHeader] = [], proxy: ProviderProxySetting = .system) {
        self.headers = headers
        self.proxy = proxy
    }

    public static let `default` = ProviderNetworkOptions()

    public var isDefault: Bool { self == .default }
}

extension ProviderConfig {
    /// 把供应商记录上保存的自定义请求头与代理带到运行时配置。
    public mutating func applyNetworkOptions(from record: EnvVarEntry) {
        networkOptions = record.networkOptions ?? .default
    }
}

public enum ProviderNetworkOptionsPolicy {
    /// 认证与协议头：自定义请求头永远不能设置这些（比较时不区分大小写）。
    public static let reservedHeaderNames: Set<String> = [
        "authorization", "proxy-authorization", "x-api-key", "api-key",
        "anthropic-version", "anthropic-beta", "content-type", "content-length",
        "accept", "host", "connection", "transfer-encoding", "te", "upgrade",
    ]

    public enum HeaderIssue: Equatable, Sendable {
        case invalidName
        case reservedName
        case emptyValue
        case invalidValue
    }

    /// 单条请求头的静态问题（不读环境变量）；nil 表示可用。
    public static func issue(for header: ProviderCustomHeader) -> HeaderIssue? {
        let name = header.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 64,
              name.utf8.allSatisfy({ isTokenByte($0) }) else { return .invalidName }
        if reservedHeaderNames.contains(name.lowercased()) { return .reservedName }
        let value = header.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return .emptyValue }
        if header.valueIsEnvVar {
            return EnvCredentials.canonicalName(value) == nil ? .invalidValue : nil
        }
        if value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { return .invalidValue }
        return nil
    }

    /// 解析成可直接写进请求的键值；有问题的条目、取不到值的环境变量条目不发送。
    public static func resolvedHeaders(
        _ headers: [ProviderCustomHeader],
        environmentValue: (String) -> String? = { EnvCredentials.value(for: $0) }
    ) -> [String: String] {
        var result: [String: String] = [:]
        var seen: Set<String> = []
        for header in headers where issue(for: header) == nil {
            let name = header.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard seen.insert(name.lowercased()).inserted else { continue }
            let raw = header.value.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = header.valueIsEnvVar ? environmentValue(raw) : raw
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
                  !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { continue }
            result[name] = value
        }
        return result
    }

    public enum ProxyFailure: Error, Equatable, Sendable {
        case invalidURL
    }

    /// 代理设置 → URLSession 的 `connectionProxyDictionary`。
    /// nil = 跟随系统；`[:]` = 明确不用代理；自定义地址不合法时抛错（不静默退回直连或系统代理）。
    /// 键用字面字符串（与 CFNetwork 的 HTTPEnable/HTTPProxy/HTTPPort 及 HTTPS* 同值），避免平台符号可用性差异。
    public static func proxyDictionary(for proxy: ProviderProxySetting) throws -> [AnyHashable: Any]? {
        switch proxy.mode {
        case .system:
            return nil
        case .direct:
            return [:]
        case .custom:
            guard let text = proxy.url?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                  let components = URLComponents(string: text),
                  let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let host = components.host, !host.isEmpty,
                  components.user == nil, components.password == nil,
                  components.path.isEmpty || components.path == "/" else {
                throw ProxyFailure.invalidURL
            }
            let port = components.port ?? (scheme == "https" ? 443 : 80)
            guard (1...65535).contains(port) else { throw ProxyFailure.invalidURL }
            return [
                "HTTPEnable": 1, "HTTPProxy": host, "HTTPPort": port,
                "HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": port,
            ]
        }
    }

    /// 跟随系统时返回 nil（由各 Provider 用自己的默认会话）；否则返回带代理的会话。
    /// 重定向守卫与超时与各 Provider 默认会话一致。
    public static func makeSession(for proxy: ProviderProxySetting) throws -> URLSession? {
        guard let dictionary = try proxyDictionary(for: proxy) else { return nil }
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 600
        configuration.connectionProxyDictionary = dictionary
        return URLSession(configuration: configuration, delegate: ProviderRedirectGuard.shared, delegateQueue: nil)
    }

    private static func isTokenByte(_ b: UInt8) -> Bool {
        (48...57).contains(b) || (65...90).contains(b) || (97...122).contains(b) || b == 45
    }
}
