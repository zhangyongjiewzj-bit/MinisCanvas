import Foundation

/// Pure, scope-bound navigation policy shared by the agent browser and the
/// embedded BrowserTab consumer.  The policy is deliberately domain based:
/// callers must provide the domains already authorized by their existing
/// policy/approval boundary.  An empty set therefore remains fail-closed.
public struct BrowserNavigationPolicy: Codable, Equatable, Sendable {
    public static let allowedWebsitesSettingLabel = "允许访问的网站"
    public static let allowedWebsitesSettingsPath = "设置 → 智能体运行 → 运行安全上限"

    static var allowedWebsitesSettingsGuidance: String {
        "若信任目标域名，可在\(allowedWebsitesSettingsPath)的“\(allowedWebsitesSettingLabel)”中添加，点击“保存运行上限”后在新回合重试。"
    }

    /// An existing refusal code selects fixed guidance without changing the
    /// structured response or carrying a destination from the page.
    public static func settingsGuidance(forBrowserRefusalReason reason: String?) -> String? {
        guard let reason else { return nil }
        switch reason {
        case "navigation_denied:" + Denial.domainNotAuthorized.rawValue,
             "navigation_denied:" + Denial.crossOriginNotAuthorized.rawValue:
            return allowedWebsitesSettingsGuidance
        default:
            return nil
        }
    }

    public enum Source: String, Codable, Equatable, Sendable {
        case initial
        case action
        case response
        case redirect
        case backForward
        case reload
        case newWindow
    }

    /// Stable, non-secret denial codes suitable for a tool result or UI.
    public enum Denial: String, Codable, Equatable, Sendable {
        case invalidScope = "invalid_scope"
        case staleGeneration = "stale_generation"
        case missingURL = "missing_url"
        case unsupportedScheme = "unsupported_scheme"
        case missingHost = "missing_host"
        case invalidURL = "invalid_url"
        case credentialsInURL = "credentials_in_url"
        case domainNotAuthorized = "domain_not_authorized"
        case crossOriginNotAuthorized = "cross_origin_not_authorized"
        case insecureRedirect = "insecure_redirect"
        case newWindowNotAllowed = "new_window_not_allowed"
        case downloadNotAuthorized = "download_not_authorized"
        case formSubmissionNotAuthorized = "form_submission_not_authorized"
        case requestMethodNotAuthorized = "request_method_not_authorized"
        case resourceUnavailable = "resource_unavailable"

        public var message: String {
            switch self {
            case .invalidScope:
                return "浏览器作用域授权无效"
            case .staleGeneration:
                return "浏览器资源已更新，旧导航授权已失效"
            case .missingURL:
                return "导航请求缺少网址"
            case .unsupportedScheme:
                return "仅允许 http/https 网址"
            case .missingHost:
                return "网址缺少主机名"
            case .invalidURL:
                return "网址格式无效"
            case .credentialsInURL:
                return "网址不能携带登录凭据"
            case .domainNotAuthorized:
                return "目标域名没有现有浏览器授权"
            case .crossOriginNotAuthorized:
                return "跨域导航没有现有浏览器授权"
            case .insecureRedirect:
                return "不允许从 HTTPS 降级到 HTTP"
            case .newWindowNotAllowed:
                return "浏览器会话不允许打开新窗口"
            case .downloadNotAuthorized:
                return "浏览器下载没有现有审批"
            case .formSubmissionNotAuthorized:
                return "表单提交没有现有审批"
            case .requestMethodNotAuthorized:
                return "浏览器请求方法没有现有审批"
            case .resourceUnavailable:
                return "浏览器资源当前不可用"
            }
        }
    }

    public enum Decision: Codable, Equatable, Sendable {
        case allow
        case deny(Denial)

        public var isAllowed: Bool {
            if case .allow = self { return true }
            return false
        }

        public var denial: Denial? {
            guard case .deny(let denial) = self else { return nil }
            return denial
        }

        public var refusalReason: String? {
            denial?.rawValue
        }
    }

    /// Configured domains include subdomains. Hosts chosen in the address bar
    /// use exact matching and do not widen the configured domain ceiling.
    public private(set) var allowedHosts: Set<String>
    private var exactAddressHosts: Set<String>?
    public let allowsSameOrigin: Bool
    /// `about:blank` and `loadHTMLString` remain available for local previews;
    /// this flag never permits file/data/javascript/miniscanvas URLs.
    public let allowsLocalContent: Bool

    public init(
        allowedHosts: Set<String> = [],
        allowsSameOrigin: Bool = true,
        allowsLocalContent: Bool = true
    ) {
        self.allowedHosts = Set(allowedHosts.compactMap(Self.normalizedHost))
        self.allowsSameOrigin = allowsSameOrigin
        self.allowsLocalContent = allowsLocalContent
    }

    public init(
        allowedHosts: [String],
        allowsSameOrigin: Bool = true,
        allowsLocalContent: Bool = true
    ) {
        self.init(
            allowedHosts: Set(allowedHosts),
            allowsSameOrigin: allowsSameOrigin,
            allowsLocalContent: allowsLocalContent
        )
    }

    public init(
        allowedDomains: Set<String>,
        allowsSameOrigin: Bool = true,
        allowsLocalContent: Bool = true
    ) {
        self.init(
            allowedHosts: allowedDomains,
            allowsSameOrigin: allowsSameOrigin,
            allowsLocalContent: allowsLocalContent
        )
    }

    public init(
        allowedDomains: [String],
        allowsSameOrigin: Bool = true,
        allowsLocalContent: Bool = true
    ) {
        self.init(
            allowedHosts: allowedDomains,
            allowsSameOrigin: allowsSameOrigin,
            allowsLocalContent: allowsLocalContent
        )
    }

    /// Normalize a host without turning an arbitrary string into an allowlist
    /// entry.  Invalid/empty values are dropped so a malformed policy remains
    /// fail-closed instead of accidentally matching every URL.
    public static func normalizedHost(_ rawHost: String) -> String? {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }
        guard !host.isEmpty,
              !host.contains("/"),
              !host.contains("@"),
              !host.contains("*"),
              !host.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7f })
        else { return nil }
        return host
    }

    /// Shared URL syntax boundary for BrowserTool and BrowserTab.  This is a
    /// structural check only; domain authorization is evaluated separately by
    /// `decision(for:source:...)`.
    public static func isValidWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              normalizedHost(host) != nil,
              url.user == nil,
              url.password == nil,
              !url.absoluteString.contains("\0")
        else { return false }
        return true
    }

    /// Add one host already selected by an explicit caller action (for
    /// example, a user submitting the App address bar).  It does not grant
    /// arbitrary future hosts or alter scope/generation identity.
    @discardableResult
    public mutating func authorize(_ url: URL) -> Bool {
        guard Self.isValidWebURL(url), let host = Self.normalizedHost(url.host ?? "") else {
            return false
        }
        if allowedHosts.insert(host).inserted {
            exactAddressHosts = (exactAddressHosts ?? []).union([host])
        }
        return true
    }

    /// Evaluate a navigation with explicit scope and resource-generation
    /// fencing.  The short overload below is intended for pure policy fixtures;
    /// production BrowserSession calls this fenced form.
    public func decision(
        for url: URL?,
        source: Source,
        scopeID: String,
        expectedScopeID: String,
        generation: UInt64,
        expectedGeneration: UInt64,
        currentURL: URL? = nil
    ) -> Decision {
        let scope = scopeID.trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedScope = expectedScopeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !scope.isEmpty, scope == expectedScope else {
            return .deny(.invalidScope)
        }
        guard generation > 0, generation == expectedGeneration else {
            return .deny(.staleGeneration)
        }
        guard source != .newWindow else {
            return .deny(.newWindowNotAllowed)
        }
        guard let url else { return .deny(.missingURL) }

        if allowsLocalContent, Self.isAboutBlank(url) {
            return .allow
        }
        guard let scheme = url.scheme?.lowercased() else {
            return .deny(.unsupportedScheme)
        }
        guard scheme == "http" || scheme == "https" else {
            return .deny(.unsupportedScheme)
        }
        guard url.host != nil else { return .deny(.missingHost) }
        guard url.user == nil, url.password == nil else {
            return .deny(.credentialsInURL)
        }
        guard Self.isValidWebURL(url),
              let host = Self.normalizedHost(url.host ?? "") else {
            return .deny(.invalidURL)
        }

        if let currentURL,
           Self.isHTTPSDowngrade(from: currentURL, to: url),
           source != .initial {
            return .deny(.insecureRedirect)
        }
        if hostMatchesAllowedDomain(host) {
            return .allow
        }
        // An initial `navigate` is itself the authorization boundary. Same
        // origin is only a follow-up/redirect relaxation after that boundary
        // has admitted the initial host.
        if source != .initial,
           allowsSameOrigin,
           let currentURL,
           Self.sameOrigin(url, currentURL) {
            return .allow
        }
        return currentURL == nil
            ? .deny(.domainNotAuthorized)
            : .deny(.crossOriginNotAuthorized)
    }

    /// Pure fixture convenience.  Production callers should use the fenced
    /// overload so old scope/resource decisions can never be replayed.
    public func decision(
        for url: URL?,
        source: Source,
        currentURL: URL? = nil
    ) -> Decision {
        decision(
            for: url,
            source: source,
            scopeID: "policy-fixture",
            expectedScopeID: "policy-fixture",
            generation: 1,
            expectedGeneration: 1,
            currentURL: currentURL
        )
    }

    private func hostMatchesAllowedDomain(_ host: String) -> Bool {
        allowedHosts.contains { allowed in
            host == allowed || (exactAddressHosts?.contains(allowed) != true && host.hasSuffix("." + allowed))
        }
    }

    private static func isAboutBlank(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "about"
            && url.host == nil
            && url.path.lowercased() == "blank"
            && url.query == nil
            && url.fragment == nil
    }

    public static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard isValidWebURL(lhs), isValidWebURL(rhs),
              lhs.scheme?.lowercased() == rhs.scheme?.lowercased(),
              normalizedHost(lhs.host ?? "") == normalizedHost(rhs.host ?? "")
        else { return false }
        return effectivePort(for: lhs) == effectivePort(for: rhs)
    }

    private static func effectivePort(for url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    private static func isHTTPSDowngrade(from currentURL: URL, to targetURL: URL) -> Bool {
        currentURL.scheme?.lowercased() == "https"
            && targetURL.scheme?.lowercased() == "http"
            && normalizedHost(currentURL.host ?? "") == normalizedHost(targetURL.host ?? "")
    }
}
