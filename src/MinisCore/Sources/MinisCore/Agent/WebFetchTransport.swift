import Foundation

public enum WebFetchError: Error, Equatable, Sendable {
    case policyDenied(BrowserNavigationPolicy.Denial)
    case invalidResponse
    case unexpectedRedirect
    case redirectLimit
    case redirectLoop
    case missingRedirectLocation
    case httpStatus(Int)
    case responseTooLarge
    case unsupportedContentType
    case unsupportedEncoding
}

extension WebFetchError: LocalizedError {
    /// 模型收到的失败原因：每种情况都说清楚发生了什么、下一步怎么办，状态码不丢。
    public var errorDescription: String? {
        switch self {
        case .policyDenied(let denial):
            if denial == .domainNotAuthorized || denial == .crossOriginNotAuthorized {
                return "网页抓取的目标域名不在允许列表内。\(BrowserNavigationPolicy.allowedWebsitesSettingsGuidance)"
            }
            return "网页抓取被拒绝：\(denial.message)。"
        case .invalidResponse:
            return "网页抓取失败：服务器返回的响应无法识别。"
        case .unexpectedRedirect:
            return "网页抓取失败：服务器响应的地址与请求的地址不一致，已放弃。"
        case .redirectLimit:
            return "网页抓取失败：重定向超过 \(WebFetchTransport.maximumRedirects) 次，已放弃。"
        case .redirectLoop:
            return "网页抓取失败：重定向形成了循环，已放弃。"
        case .missingRedirectLocation:
            return "网页抓取失败：服务器要求重定向，但没有给出目标地址。"
        case .httpStatus(let status):
            switch status {
            case 404, 410:
                return "网页抓取失败：服务器返回 HTTP \(status)，页面不存在。请核对链接是否正确。"
            case 401, 403:
                return "网页抓取失败：服务器返回 HTTP \(status)，需要登录或没有访问权限。可改用浏览器工具，或请用户提供页面内容。"
            case 429:
                return "网页抓取失败：服务器返回 HTTP 429，请求过于频繁。请稍后再试。"
            case 500...599:
                return "网页抓取失败：服务器返回 HTTP \(status)，对方服务器出错。可稍后重试。"
            default:
                return "网页抓取失败：服务器返回 HTTP \(status)。"
            }
        case .responseTooLarge:
            return "网页抓取失败：页面超过 \(WebFetchTransport.maximumBytes / 1024 / 1024) MB 上限。请改用浏览器工具查看，或换一个更小的页面。"
        case .unsupportedContentType:
            return "网页抓取失败：这个地址返回的不是网页或纯文本（例如 PDF、图片、压缩包）。需要时请改用浏览器工具，或请用户下载后提供文件路径。"
        case .unsupportedEncoding:
            return "网页抓取失败：页面文字编码无法识别。"
        }
    }
}

/// A single HTTP hop. Production transport never follows redirects itself.
struct WebFetchHop: Sendable {
    let response: HTTPURLResponse
    let body: Data
}

/// Read-only, cookie-free fetch for an already-approved tool invocation.
/// `allowedDomains` MUST come from the caller's trusted policy snapshot, never
/// from model arguments or by adding the requested host to an allowlist.
public struct WebFetchTransport: Sendable {
    public static let maximumBytes = 2 * 1024 * 1024
    public static let maximumRedirects = 5
    let pinnedConfiguration: WebFetchPinnedConfiguration?
    private let policy: BrowserNavigationPolicy
    private let load: @Sendable (URL) async throws -> WebFetchHop

    public init(allowedDomains: Set<String>, pinnedConfiguration: WebFetchPinnedConfiguration? = nil) {
        self.init(allowedDomains: allowedDomains, load: Self.loadHop, pinnedConfiguration: pinnedConfiguration)
    }

    /// Synthetic tests inject single-hop responses without performing I/O.
    init(allowedDomains: Set<String>, load: @escaping @Sendable (URL) async throws -> WebFetchHop,
         pinnedConfiguration: WebFetchPinnedConfiguration? = nil) {
        self.pinnedConfiguration = pinnedConfiguration
        self.policy = BrowserNavigationPolicy(allowedDomains: allowedDomains,
                                              allowsSameOrigin: false, allowsLocalContent: false)
        self.load = load
    }

    public func fetch(_ initialURL: URL) async throws -> String {
        if let permit = WebFetchPinnedCallContext.current {
            guard pinnedConfiguration?.isAdmitted == true,
                  initialURL == permit.binding.endpoint.url else {
                throw ComposerAuthorizationError.authorizationBindingMismatch
            }
            return try await fetchPinned(initialURL, permit: permit)
        }
        var current = initialURL
        var previous: URL?
        var visited = Set<URL>()
        var redirects = 0
        while true {
            try Task.checkCancellation()
            let decision = policy.decision(for: current, source: previous == nil ? .initial : .redirect,
                scopeID: "web-fetch", expectedScopeID: "web-fetch", generation: 1,
                expectedGeneration: 1, currentURL: previous)
            if let denial = decision.denial { throw WebFetchError.policyDenied(denial) }
            guard visited.insert(current).inserted else { throw WebFetchError.redirectLoop }
            let hop = try await load(current)
            try Task.checkCancellation()
            // Even an injected adapter may not silently follow a redirect.
            guard hop.response.url == current else { throw WebFetchError.unexpectedRedirect }
            guard hop.body.count <= Self.maximumBytes else { throw WebFetchError.responseTooLarge }
            let status = hop.response.statusCode
            if [301, 302, 303, 307, 308].contains(status) {
                guard redirects < Self.maximumRedirects else { throw WebFetchError.redirectLimit }
                guard let location = hop.response.value(forHTTPHeaderField: "Location"),
                      let next = URL(string: location, relativeTo: current)?.absoluteURL else {
                    throw WebFetchError.missingRedirectLocation
                }
                previous = current
                current = next
                redirects += 1
                continue
            }
            guard (200..<300).contains(status) else { throw WebFetchError.httpStatus(status) }
            return try WebFetchRenderer.text(from: hop.body, mimeType: hop.response.mimeType,
                                            characterEncoding: hop.response.textEncodingName)
        }
    }

    private func fetchPinned(_ initialURL: URL, permit: WebFetchPinnedCallPermit) async throws -> String {
        var current = initialURL
        var redirects = 0
        var visited = Set<URL>()
        while true {
            try Task.checkCancellation()
            _ = try WebFetchEndpoint(current)
            guard visited.insert(current).inserted else { throw WebFetchError.redirectLoop }
            let hop = try await permit.load(current)
            try Task.checkCancellation()
            guard hop.response.url == current else { throw WebFetchError.unexpectedRedirect }
            guard hop.body.count <= Self.maximumBytes else { throw WebFetchError.responseTooLarge }
            if [301, 302, 303, 307, 308].contains(hop.response.statusCode) {
                guard redirects < Self.maximumRedirects else { throw WebFetchError.redirectLimit }
                guard let location = hop.response.value(forHTTPHeaderField: "Location"),
                      let next = URL(string: location, relativeTo: current)?.absoluteURL else {
                    throw WebFetchError.missingRedirectLocation
                }
                current = next
                redirects += 1
                continue
            }
            guard (200..<300).contains(hop.response.statusCode) else {
                throw WebFetchError.httpStatus(hop.response.statusCode)
            }
            return try WebFetchRenderer.text(from: hop.body, mimeType: hop.response.mimeType,
                characterEncoding: hop.response.textEncodingName)
        }
    }

    private static func loadHop(_ url: URL) async throws -> WebFetchHop {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue("text/html, application/xhtml+xml, text/plain, application/json, application/xml, application/rss+xml, application/atom+xml, text/markdown, text/csv;q=0.9, */*;q=0.5", forHTTPHeaderField: "Accept")
        let (bytes, rawResponse) = try await session.bytes(for: request, delegate: WebFetchNoRedirect())
        guard let response = rawResponse as? HTTPURLResponse else { throw WebFetchError.invalidResponse }
        if response.expectedContentLength > Int64(maximumBytes) { throw WebFetchError.responseTooLarge }
        // Redirect bodies are not needed. Returning now also avoids consuming
        // arbitrarily large bodies before the next destination is authorized.
        if [301, 302, 303, 307, 308].contains(response.statusCode) {
            return WebFetchHop(response: response, body: Data())
        }
        var body = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard body.count < maximumBytes else { throw WebFetchError.responseTooLarge }
            body.append(byte)
        }
        return WebFetchHop(response: response, body: body)
    }
}

private final class WebFetchNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
