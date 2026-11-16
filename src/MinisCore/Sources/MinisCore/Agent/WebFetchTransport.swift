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
    public var errorDescription: String? {
        guard case .policyDenied(let denial) = self,
              denial == .domainNotAuthorized || denial == .crossOriginNotAuthorized else { return nil }
        return "网页抓取的目标域名不在允许列表内。\(BrowserNavigationPolicy.allowedWebsitesSettingsGuidance)"
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
        request.setValue("text/html, application/xhtml+xml, text/plain", forHTTPHeaderField: "Accept")
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
