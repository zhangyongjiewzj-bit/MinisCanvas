import Foundation
import Testing
import CryptoKit
@testable import MinisCore

/// Synthetic AS+MCP service only. URLProtocol prevents all external network and uses memory credentials.
@Suite struct MCPOAuthBehaviorTests {
    @Test func challengeLoginPKCEAndBearerRetry() async throws {
        let fixture = OAuthFixture()
        let transport = MCPHTTPTransport(url: fixture.url, headers: [:], session: fixture.session,
            oauth: fixture.oauth, oauthServer: fixture.server)
        let request = MCPJSONRPCRequest(id: .int(1), method: "initialize")
        do { _ = try await transport.send(request); Issue.record("First request must require login") }
        catch let error as MCPOAuthError { #expect(error == .loginRequired) }
        try await fixture.login()
        #expect(await fixture.oauth.state(for: fixture.server) == .signedIn)
        let result = try await transport.send(request)
        #expect(result.id == request.id)
        #expect(fixture.service.snapshot().authorizedRequests == 1)
        #expect(fixture.service.snapshot().registrationRequests == 1)
        let recorded = fixture.service.snapshot()
        let authorization = try #require(recorded.authorizations.last)
        #expect(authorization["code_challenge_method"] == "S256")
        #expect(authorization["resource"] == fixture.service.origin + "/mcp")
        #expect(authorization["scope"] == "synthetic.read")
        #expect(authorization["response_type"] == "code")
        let exchange = try #require(recorded.requests.first { $0.fields["grant_type"] == "authorization_code" })
        let verifier = try #require(exchange.fields["code_verifier"])
        #expect(MCPOAuthCoordinator.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) == authorization["code_challenge"])
        #expect(exchange.fields["resource"] == fixture.service.origin + "/mcp")
        #expect(exchange.fields["code"] == "synthetic-code")
    }

    @Test func expiredCredentialRefreshesBeforeRequestAndRotates() async throws {
        let fixture = OAuthFixture()
        try await fixture.challenge()
        try await fixture.login()
        fixture.clock.advance(2)
        #expect(await fixture.oauth.state(for: fixture.server) == .expired)
        let transport = MCPHTTPTransport(url: fixture.url, headers: [:], session: fixture.session,
            oauth: fixture.oauth, oauthServer: fixture.server)
        let response = try await transport.send(MCPJSONRPCRequest(id: .int(1), method: "initialize"))
        #expect(response.id == .int(1))
        #expect(fixture.service.snapshot().authorizedRequests == 1)
        #expect(try await fixture.oauth.accessToken(server: fixture.server) == "synthetic-access-rotated")
        #expect(fixture.service.snapshot().refreshRequests == 1)
        let refresh = try #require(fixture.service.snapshot().requests.first { $0.fields["grant_type"] == "refresh_token" })
        #expect(refresh.fields["refresh_token"] == "synthetic-refresh")
        #expect(refresh.fields["resource"] == fixture.service.origin + "/mcp")
        #expect(await fixture.oauth.state(for: fixture.server) == .signedIn)
    }

    @Test func refreshFailureShowsExpiredAndDoesNotLoop() async throws {
        let fixture = OAuthFixture()
        try await fixture.challenge()
        try await fixture.login()
        fixture.clock.advance(2)
        fixture.service.failRefresh()
        do { _ = try await fixture.oauth.accessToken(server: fixture.server); Issue.record("Refresh must fail") }
        catch is MCPOAuthError { }
        #expect(await fixture.oauth.state(for: fixture.server) == .expired)
        do { _ = try await fixture.oauth.accessToken(server: fixture.server); Issue.record("Re-login is required") }
        catch let error as MCPOAuthError { #expect(error == .expired) }
        #expect(fixture.service.snapshot().refreshRequests == 1)
    }

    @Test func logoutDuringBrowserCannotResurrectCredentials() async throws {
        let fixture = OAuthFixture()
        try await fixture.challenge()
        do {
            try await fixture.oauth.login(server: fixture.server) { url, _ in
                try await fixture.oauth.logout(server: fixture.server)
                let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value
                var callback = URLComponents(url: MCPOAuthCoordinator.redirectURI, resolvingAgainstBaseURL: false)!
                callback.queryItems = [.init(name: "state", value: state), .init(name: "code", value: "synthetic-code")]
                return callback.url!
            }
            Issue.record("Logout must invalidate pending authorization")
        } catch let error as MCPOAuthError { #expect(error == .stale) }
        #expect(fixture.service.snapshot().tokenRequests == 0)
        #expect(try await fixture.oauth.accessToken(server: fixture.server) == nil)
    }

    @Test func wrongStateNeverReachesTokenEndpoint() async throws {
        let fixture = OAuthFixture()
        try await fixture.challenge()
        do { try await fixture.login(wrongState: true); Issue.record("Mismatched state must reject") }
        catch let error as MCPOAuthError { #expect(error == .stateMismatch) }
        #expect(fixture.service.snapshot().tokenRequests == 0)
        #expect(await fixture.oauth.state(for: fixture.server) == .needsLogin)
    }

    @Test func manualClientAndLogoutClearStoredTokens() async throws {
        let fixture = OAuthFixture()
        try await fixture.challenge()
        fixture.service.disableRegistration()
        do { try await fixture.login(); Issue.record("Missing DCR requires manual clientID") }
        catch let error as MCPOAuthError { #expect(error == .manualClientIDRequired) }
        try await fixture.login(manualClientID: "synthetic-manual-client")
        #expect(fixture.service.snapshot().registrationRequests == 0)
        try await fixture.oauth.logout(server: fixture.server)
        #expect(try await fixture.oauth.accessToken(server: fixture.server) == nil)
        #expect(await fixture.oauth.state(for: fixture.server) == .needsLogin)
    }

    @Test func fixedHeadersAndStdioAreNotOAuthEligible() async throws {
        let fixture = OAuthFixture()
        var server = fixture.server
        server.headers = ["Authorization": "Bearer fixed-synthetic"]
        #expect(!MCPOAuthCoordinator.isEligible(server))
        let transport = MCPHTTPTransport(url: fixture.url, headers: server.headers, session: fixture.session,
            oauth: fixture.oauth, oauthServer: server)
        _ = try await transport.send(MCPJSONRPCRequest(id: .int(1), method: "initialize"))
        #expect(fixture.service.snapshot().authorizedRequests == 1)
        #expect(fixture.service.snapshot().requests.last?.authorization == "Bearer fixed-synthetic")
        #expect(await fixture.oauth.state(for: server) == .needsLogin)
        server.type = .stdio; server.headers = [:]
        #expect(!MCPOAuthCoordinator.isEligible(server))
    }

    @Test func transientRefreshFailureAllowsNextRequestToRetry() async throws {
        let fixture = OAuthFixture()
        try await fixture.challenge(); try await fixture.login()
        fixture.clock.advance(2); fixture.service.failNextRefreshNetworkRequest()
        do { _ = try await fixture.oauth.accessToken(server: fixture.server); Issue.record("Synthetic network failure must surface") }
        catch let error as MCPOAuthError { #expect(error == .requestFailed) }
        #expect(try await fixture.oauth.accessToken(server: fixture.server) == "synthetic-access-rotated")
        #expect(fixture.service.snapshot().refreshRequests == 2)
    }

    @Test func protectedResourceMismatchIsRejected() async throws {
        let fixture = OAuthFixture(config: .init(resourceMismatch: true))
        try await fixture.challenge()
        do { try await fixture.login(); Issue.record("PRM resource mismatch must reject") }
        catch let error as MCPOAuthError { #expect(error == .invalidMetadata) }
        #expect(fixture.service.snapshot().authorizations.isEmpty)
        #expect(fixture.service.snapshot().tokenRequests == 0)
    }

    @Test func issuerMetadataMismatchIsRejected() async throws {
        let fixture = OAuthFixture(config: .init(issuerMismatch: true))
        try await fixture.challenge()
        do { try await fixture.login(); Issue.record("Issuer mismatch must reject") }
        catch let error as MCPOAuthError { #expect(error == .invalidMetadata) }
        #expect(fixture.service.snapshot().authorizations.isEmpty)
        #expect(fixture.service.snapshot().tokenRequests == 0)
    }

    @Test func nonLoopbackHTTPAuthorizationEndpointIsRejected() async throws {
        let fixture = OAuthFixture(config: .init(insecureToken: true))
        try await fixture.challenge()
        do { try await fixture.login(); Issue.record("Non-loopback HTTP token endpoint must reject") }
        catch let error as MCPOAuthError { #expect(error == .insecureEndpoint) }
        #expect(fixture.service.snapshot().authorizations.isEmpty)
        #expect(fixture.service.snapshot().tokenRequests == 0)
    }

    @Test func unavailableFirstAuthorizationServerFallsThrough() async throws {
        let fixture = OAuthFixture(config: .init(firstASUnavailable: true))
        try await fixture.challenge(); try await fixture.login()
        #expect(fixture.service.snapshot().requests.contains { $0.path.contains("unavailable") })
        #expect(await fixture.oauth.state(for: fixture.server) == .signedIn)
    }

    @Test func advertisedIssuerResponseRequiresIssuerParameter() async throws {
        let fixture = OAuthFixture(config: .init(requiresIssuer: true))
        try await fixture.challenge()
        do { try await fixture.login(includeIssuer: false); Issue.record("Advertised iss must be present") }
        catch let error as MCPOAuthError { #expect(error == .invalidCallback) }
        #expect(fixture.service.snapshot().tokenRequests == 0)
        try await fixture.login()
        #expect(await fixture.oauth.state(for: fixture.server) == .signedIn)
    }

    @Test func configurationChangeDeletesOldDescriptorCredential() async throws {
        let fixture = OAuthFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("N17-owned-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = MCPServerManager(fileURL: directory.appendingPathComponent("mcps.json"), keychain: fixture.keychain)
        try manager.addServer(fixture.server)
        try await fixture.challenge(); try await fixture.login()
        var changed = fixture.server; changed.url = fixture.service.origin + "/different-mcp"
        try manager.updateServer(changed)
        #expect(try await fixture.oauth.accessToken(server: fixture.server) == nil)
    }

    @Test func confirmedServerDeletionDeletesCredential() async throws {
        let fixture = OAuthFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("N17-owned-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = MCPServerManager(fileURL: directory.appendingPathComponent("mcps.json"), keychain: fixture.keychain)
        try manager.addServer(fixture.server)
        try await fixture.challenge(); try await fixture.login()
        let intent = try manager.deletionIntent(id: fixture.server.id)
            .withFirstConfirmation("I reviewed this exact MCP server")
            .withSecondConfirmation("I confirm moving this MCP server to trash")
        _ = try manager.deleteServer(intent)
        #expect(try await fixture.oauth.accessToken(server: fixture.server) == nil)
    }

}

private final class OAuthClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1000)
    func now() -> Date { lock.withLock { date } }
    func advance(_ interval: TimeInterval) { lock.withLock { date.addTimeInterval(interval) } }
}

private final class OAuthFixture: @unchecked Sendable {
    let url: URL
    let server: MCPServer
    let oauth: MCPOAuthCoordinator
    let service: OAuthSyntheticService
    let session: URLSession
    let keychain: KeychainStore
    let clock = OAuthClock()
    init(config: OAuthSyntheticService.Configuration = .init()) {
        let host = UUID().uuidString.lowercased() + ".invalid"
        url = URL(string: "https://" + host + "/mcp")!
        server = MCPServer(id: host, name: "Synthetic N17", type: .http, url: url.absoluteString)
        service = OAuthSyntheticService(origin: "https://" + host, config: config)
        OAuthSyntheticProtocol.routes.insert(service, host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OAuthSyntheticProtocol.self]
        session = URLSession(configuration: configuration)
        keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let clock = self.clock
        oauth = MCPOAuthCoordinator(keychain: keychain, session: session, now: { clock.now() })
    }
    deinit {
        session.invalidateAndCancel()
        OAuthSyntheticProtocol.routes.remove(host: url.host!)
    }
    func challenge() async throws {
        try await oauth.receiveUnauthorized(server: server,
            header: "Bearer resource_metadata=\"" + service.origin + "/prm\", scope=\"synthetic.read\"")
    }
    func login(wrongState: Bool = false, manualClientID: String? = nil, includeIssuer: Bool = true) async throws {
        let service = self.service
        try await oauth.login(server: server, manualClientID: manualClientID) { url, _ in
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let values = Dictionary(query.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
            service.recordAuthorization(values)
            var callback = URLComponents(url: MCPOAuthCoordinator.redirectURI, resolvingAgainstBaseURL: false)!
            callback.queryItems = [.init(name: "state", value: wrongState ? "wrong" : values["state"]),
                                   .init(name: "code", value: "synthetic-code")]
            if includeIssuer { callback.queryItems?.append(.init(name: "iss", value: service.origin)) }
            return callback.url!
        }
    }
}

private final class OAuthSyntheticService: @unchecked Sendable {
    struct Configuration: Sendable {
        var resourceMismatch = false
        var issuerMismatch = false
        var insecureToken = false
        var firstASUnavailable = false
        var requiresIssuer = false
    }
    struct RecordedRequest: Sendable {
        let path: String
        let authorization: String?
        let fields: [String: String]
    }
    struct Counts {
        var registrationRequests = 0
        var tokenRequests = 0
        var refreshRequests = 0
        var authorizedRequests = 0
        var requests: [RecordedRequest] = []
        var authorizations: [[String: String]] = []
    }
    let origin: String
    private let config: Configuration
    private let lock = NSLock()
    private var counts = Counts()
    private var registrationAvailable = true
    private var refreshFails = false
    private var nextRefreshNetworkFailure = false
    init(origin: String, config: Configuration) { self.origin = origin; self.config = config }
    func snapshot() -> Counts { lock.withLock { counts } }
    func disableRegistration() { lock.withLock { registrationAvailable = false } }
    func failRefresh() { lock.withLock { refreshFails = true } }
    func failNextRefreshNetworkRequest() { lock.withLock { nextRefreshNetworkFailure = true } }
    func recordAuthorization(_ values: [String: String]) { lock.withLock { counts.authorizations.append(values) } }
    func reply(_ request: URLRequest) throws -> (Int, [String: String], Data) {
        // Read only the synthetic request body, before locking recorded state. No assertions here.
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }; body.append(contentsOf: bytes.prefix(count))
            }
        }
        let query = URLComponents(string: "https://synthetic.invalid/?" + String(decoding: body, as: UTF8.self))?.queryItems ?? []
        let fields = Dictionary(query.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        return try lock.withLock {
            counts.requests.append(.init(path: request.url?.path ?? "", authorization: request.value(forHTTPHeaderField: "Authorization"), fields: fields))
            var result: [String: Any] = [:]
            switch request.url?.path {
            case "/prm":
                result = ["resource": origin + (config.resourceMismatch ? "/wrong-resource" : "/mcp"),
                          "authorization_servers": config.firstASUnavailable ? [origin + "/unavailable", origin] : [origin]]
            case "/.well-known/oauth-authorization-server":
                result = ["issuer": origin + (config.issuerMismatch ? "/wrong-issuer" : ""), "authorization_endpoint": origin + "/authorize",
                    "token_endpoint": config.insecureToken ? "http://remote-not-loopback.invalid/token" : origin + "/token",
                    "registration_endpoint": origin + "/register", "authorization_response_iss_parameter_supported": config.requiresIssuer,
                    "code_challenge_methods_supported": ["S256"], "token_endpoint_auth_methods_supported": ["none"]]
                if !registrationAvailable { result.removeValue(forKey: "registration_endpoint") }
            case "/register":
                counts.registrationRequests += 1
                result = ["client_id": "synthetic-dynamic-client", "token_endpoint_auth_method": "none"]
            case "/token":
                counts.tokenRequests += 1
                if fields["grant_type"] == "refresh_token" {
                    counts.refreshRequests += 1
                    if nextRefreshNetworkFailure { nextRefreshNetworkFailure = false; throw URLError(.networkConnectionLost) }
                    if refreshFails { return (400, ["Content-Type": "application/json"], Data("{}".utf8)) }
                    result = ["access_token": "synthetic-access-rotated", "refresh_token": "synthetic-refresh-rotated",
                              "token_type": "Bearer", "expires_in": 3600]
                } else {
                    result = ["access_token": "synthetic-access", "refresh_token": "synthetic-refresh",
                              "token_type": "Bearer", "expires_in": 1]
                }
            case "/mcp":
                guard ["Bearer synthetic-access", "Bearer synthetic-access-rotated", "Bearer fixed-synthetic"].contains(request.value(forHTTPHeaderField: "Authorization") ?? "") else {
                    return (401, ["WWW-Authenticate": "Bearer resource_metadata=\"" + origin + "/prm\", scope=\"synthetic.read\""], Data())
                }
                counts.authorizedRequests += 1
                result = ["jsonrpc": "2.0", "id": 1, "result": [:]]
            default: return (404, [:], Data())
            }
            return (200, ["Content-Type": "application/json"], (try? JSONSerialization.data(withJSONObject: result)) ?? Data())
        }
    }
}

private final class OAuthSyntheticProtocol: URLProtocol, @unchecked Sendable {
    final class Routes: @unchecked Sendable {
        private let lock = NSLock()
        private var services: [String: OAuthSyntheticService] = [:]
        func insert(_ service: OAuthSyntheticService, host: String) { lock.withLock { services[host] = service } }
        func remove(host: String) { lock.withLock { _ = services.removeValue(forKey: host) } }
        func get(_ host: String) -> OAuthSyntheticService? { lock.withLock { services[host] } }
    }
    static let routes = Routes()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let service = Self.routes.get(url.host ?? "") else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost)); return
        }
        let reply: (Int, [String: String], Data)
        do { reply = try service.reply(request) }
        catch { client?.urlProtocol(self, didFailWithError: error); return }
        let (status, headers, data) = reply
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
