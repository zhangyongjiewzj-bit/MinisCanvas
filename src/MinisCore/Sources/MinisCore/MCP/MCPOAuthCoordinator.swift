import Foundation
import CryptoKit
import Security

/// Safe public errors: never interpolate endpoint responses, callbacks or credentials.
public enum MCPOAuthError: String, Error, LocalizedError, Sendable {
    case loginRequired, expired, manualClientIDRequired, invalidMetadata, insecureEndpoint
    case invalidCallback, stateMismatch, credentialUnavailable, requestFailed, requestRejected, cancelled, stale
    public var errorDescription: String? {
        switch self {
        case .loginRequired: return "MCP 需要登录，请在服务器管理页登录。"
        case .expired, .requestRejected: return "MCP 登录过期，请重新登录。"
        case .manualClientIDRequired: return "服务器未提供可用的动态注册，请填写已注册的 client_id。"
        case .invalidMetadata: return "MCP 授权元数据无效或不支持 S256 公共客户端。"
        case .insecureEndpoint: return "MCP 授权端点需要 HTTPS。"
        case .invalidCallback, .stateMismatch: return "MCP 登录回调校验失败。"
        case .credentialUnavailable: return "无法安全读取或保存 MCP 登录凭据。"
        case .cancelled: return "已取消 MCP 登录。"
        case .stale: return "MCP 配置或登录状态已变化，请重试。"
        case .requestFailed: return "MCP 授权请求失败，请重新登录。"
        }
    }
}

public enum MCPOAuthState: String, Sendable {
    case needsLogin = "需要登录", signedIn = "已登录", expired = "登录过期"
}

/// One record, stored atomically in the manager's existing KeychainStore only.
struct MCPOAuthCredential: Codable, Sendable {
    let resource: String
    let issuer: String
    let tokenEndpoint: URL
    let clientID: String
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
}

struct MCPOAuthChallenge: Sendable {
    let metadataURL: URL?
    let scope: String?

    init(header: String) throws {
        // Commas inside quoted realms are not challenge boundaries.
        var segments: [String] = [], current = "", quoted = false, escaped = false
        for character in header {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" && quoted { current.append(character); escaped = true; continue }
            if character == "\"" { quoted.toggle() }
            if character == "," && !quoted { segments.append(current); current = "" }
            else { current.append(character) }
        }
        guard !quoted else { throw MCPOAuthError.invalidMetadata }
        segments.append(current)
        let trimmed = segments.map { $0.trimmingCharacters(in: .whitespaces) }
        guard let index = trimmed.firstIndex(where: {
            $0.caseInsensitiveCompare("Bearer") == .orderedSame || $0.lowercased().hasPrefix("bearer ")
        }) else { throw MCPOAuthError.loginRequired }
        var fields = [String(trimmed[index].dropFirst(6)).trimmingCharacters(in: .whitespaces)]
        for segment in trimmed.dropFirst(index + 1) {
            guard segment.range(of: #"^[A-Za-z_][A-Za-z0-9_]*\s*="#, options: .regularExpression) != nil else { break }
            fields.append(segment)
        }
        let parameters = fields.joined(separator: ",")
        let regex = try NSRegularExpression(pattern: #"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:"((?:\\.|[^"\\])*)"|([^,\s]+))"#)
        var values: [String: String] = [:]
        for match in regex.matches(in: parameters, range: NSRange(parameters.startIndex..., in: parameters)) {
            guard let nameRange = Range(match.range(at: 1), in: parameters) else { continue }
            let valueRange = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 3)
            guard let range = Range(valueRange, in: parameters) else { continue }
            let name = parameters[nameRange].lowercased()
            guard values[name] == nil else { throw MCPOAuthError.invalidMetadata }
            values[name] = String(parameters[range]).replacingOccurrences(of: #"\""#, with: "\"")
        }
        if let metadata = values["resource_metadata"] {
            guard let url = URL(string: metadata) else { throw MCPOAuthError.invalidMetadata }
            metadataURL = url
        } else { metadataURL = nil }
        scope = values["scope"]
    }
}

/// Sync manager CRUD and actor completions share one short lock around generation + Keychain mutation.
/// This is an in-memory write fence, not a credential store.
private final class MCPOAuthCredentialFence: @unchecked Sendable {
    private let lock = NSLock()
    private var generations: [String: UUID] = [:]
    func epoch(_ key: String) -> UUID {
        lock.withLock {
            if let current = generations[key] { return current }
            let current = UUID(); generations[key] = current; return current
        }
    }
    func begin(_ key: String) -> UUID {
        lock.withLock { let next = UUID(); generations[key] = next; return next }
    }
    func save(_ value: String, key: String, generation: UUID, keychain: KeychainStore) throws {
        try lock.withLock {
            guard generations[key] == generation else { throw MCPOAuthError.stale }
            guard keychain.set(value, forKey: key) else { throw MCPOAuthError.credentialUnavailable }
        }
    }
    func retire(_ key: String, keychain: KeychainStore) throws {
        try lock.withLock {
            generations[key] = UUID()
            guard keychain.delete(key) else { throw MCPOAuthError.credentialUnavailable }
        }
    }
}

/// Only HTTP OAuth participates. Existing fixed auth and stdio never read OAuth credentials.
public actor MCPOAuthCoordinator {
    public static let stateChanged = Notification.Name("MinisCanvas.MCPOAuthStateChanged")
    public static let redirectURI = URL(string: "com.miniscanvas.mcp.oauth:/callback")!
    public typealias Browser = @Sendable (URL, String) async throws -> URL
    private let keychain: KeychainStore
    private let session: URLSession
    private let now: @Sendable () -> Date
    private var challenges: [String: MCPOAuthChallenge] = [:]
    private let credentialFence = MCPOAuthCredentialFence()
    private var expiredKeys: Set<String> = []
    private var failedRefreshKeys: Set<String> = []
    private var refreshes: [String: Task<MCPOAuthCredential, Error>] = [:]

    public init(keychain: KeychainStore, session: URLSession? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.keychain = keychain
        self.session = session ?? URLSession(configuration: .ephemeral, delegate: MCPNoRedirectDelegate(), delegateQueue: nil)
        self.now = now
    }

    public nonisolated static func isEligible(_ server: MCPServer) -> Bool {
        server.type == .http && !server.headers.contains {
            !$0.value.isEmpty && MCPServerSecretPolicy.isSecretKey($0.key)
        }
    }

    private nonisolated func key(_ server: MCPServer) -> String {
        let identity = server.id + ":" + server.descriptorFingerprint
        return "mcp.oauth.v1." + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func epoch(_ key: String) -> UUID { credentialFence.epoch(key) }

    /// Called synchronously only after a server configuration mutation commits.
    /// Invalidates late actor writes atomically with deleting the old descriptor record.
    public nonisolated func retireCredential(server: MCPServer) throws {
        try credentialFence.retire(key(server), keychain: keychain)
    }
    private func changed(_ server: MCPServer) {
        NotificationCenter.default.post(name: Self.stateChanged, object: nil, userInfo: ["serverID": server.id])
    }
    private func read(_ server: MCPServer) throws -> MCPOAuthCredential? {
        switch keychain.readResult(forKey: key(server)) {
        case .missing: return nil
        case .denied, .failed: throw MCPOAuthError.credentialUnavailable
        case .found(let value):
            guard let data = value.data(using: .utf8),
                  let record = try? JSONDecoder().decode(MCPOAuthCredential.self, from: data),
                  record.resource == (try Self.resource(server).absoluteString) else {
                throw MCPOAuthError.credentialUnavailable
            }
            return record
        }
    }
    private func save(_ record: MCPOAuthCredential, server: MCPServer, generation: UUID) throws {
        guard epoch(key(server)) == generation else { throw MCPOAuthError.stale }
        let data = try JSONEncoder().encode(record)
        guard let value = String(data: data, encoding: .utf8) else { throw MCPOAuthError.credentialUnavailable }
        try credentialFence.save(value, key: key(server), generation: generation, keychain: keychain)
        expiredKeys.remove(key(server)); failedRefreshKeys.remove(key(server)); changed(server)
    }
    public func isKnownRequired(for server: MCPServer) -> Bool {
        if challenges[key(server)] != nil { return true }
        do { return try read(server) != nil }
        catch { return true }
    }
    public func state(for server: MCPServer) -> MCPOAuthState {
        if expiredKeys.contains(key(server)) { return .expired }
        do {
            guard let record = try read(server) else { return .needsLogin }
            return record.expiresAt.map { $0 <= now() } == true ? .expired : .signedIn
        } catch { return .expired }
    }
    public func hasChallenge(server: MCPServer) -> Bool { challenges[key(server)] != nil }

    public func receiveUnauthorized(server: MCPServer, header: String) throws {
        challenges[key(server)] = try MCPOAuthChallenge(header: header)
        if try read(server) != nil { expiredKeys.insert(key(server)) }
        changed(server)
    }
    public func logout(server: MCPServer) throws {
        let identity = key(server)
        try retireCredential(server: server)
        refreshes.removeValue(forKey: identity)?.cancel()
        expiredKeys.remove(identity); failedRefreshKeys.remove(identity)
        changed(server)
    }

    /// Called before every request, and at most once again for a rejected bearer.
    public func accessToken(server: MCPServer, forceRefresh: Bool = false) async throws -> String? {
        let identity = key(server), generation = epoch(key(server))
        guard let record = try read(server) else { return nil }
        guard epoch(identity) == generation else { throw MCPOAuthError.stale }
        guard !failedRefreshKeys.contains(key(server)) else { throw MCPOAuthError.expired }
        if !forceRefresh && !expiredKeys.contains(key(server)) && (record.expiresAt.map { $0 > now() } ?? true) {
            return record.accessToken
        }
        if let pending = refreshes[identity] {
            let updated = try await pending.value
            guard epoch(identity) == generation else { throw MCPOAuthError.stale }
            return updated.accessToken
        }
        guard let refresh = record.refreshToken else {
            expiredKeys.insert(identity); changed(server); throw MCPOAuthError.expired
        }
        let task = Task { try await self.exchange(endpoint: record.tokenEndpoint, fields: [
            "grant_type": "refresh_token", "refresh_token": refresh,
            "client_id": record.clientID, "resource": record.resource
        ], resource: record.resource, issuer: record.issuer, clientID: record.clientID, previousRefresh: refresh) }
        refreshes[identity] = task
        do {
            let updated = try await task.value
            guard epoch(identity) == generation else { throw MCPOAuthError.stale }
            try save(updated, server: server, generation: generation)
            refreshes[identity] = nil
            return updated.accessToken
        } catch {
            if epoch(identity) == generation {
                refreshes[identity] = nil; expiredKeys.insert(identity)
                if error as? MCPOAuthError == .requestRejected { failedRefreshKeys.insert(identity) }
                changed(server)
            }
            if error is CancellationError { throw MCPOAuthError.cancelled }
            if let safe = error as? MCPOAuthError { throw safe }
            throw MCPOAuthError.expired
        }
    }

    public func login(server: MCPServer, manualClientID: String? = nil, browser: Browser) async throws {
        guard Self.isEligible(server), let challenge = challenges[key(server)] else { throw MCPOAuthError.loginRequired }
        let identity = key(server)
        // A new attempt invalidates any in-flight login/refresh completion.
        let generation = credentialFence.begin(identity)
        refreshes.removeValue(forKey: identity)?.cancel()
        let resource = try Self.resource(server)
        let prm = try await protectedMetadata(resource: resource, challenge: challenge)
        guard let issuers = prm["authorization_servers"] as? [String], !issuers.isEmpty,
              let protectedResource = prm["resource"] as? String,
              protectedResource == resource.absoluteString else { throw MCPOAuthError.invalidMetadata }
        let (issuer, metadata) = try await selectAuthorizationServer(issuers)
        guard let authorization = (metadata["authorization_endpoint"] as? String).flatMap(URL.init(string:)),
              let token = (metadata["token_endpoint"] as? String).flatMap(URL.init(string:)) else { throw MCPOAuthError.invalidMetadata }
        let clientID: String
        if let manual = manualClientID?.trimmingCharacters(in: .whitespacesAndNewlines), !manual.isEmpty {
            clientID = manual
        } else {
            guard let endpoint = (metadata["registration_endpoint"] as? String).flatMap(URL.init(string:)) else {
                throw MCPOAuthError.manualClientIDRequired
            }
            var request = URLRequest(url: endpoint); request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "client_name": "MinisCanvas", "redirect_uris": [Self.redirectURI.absoluteString],
                "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"],
                "token_endpoint_auth_method": "none"
            ])
            do {
                let registration = try await json(request)
                guard let id = registration["client_id"] as? String, !id.isEmpty,
                      (registration["token_endpoint_auth_method"] as? String ?? "none") == "none" else {
                    throw MCPOAuthError.manualClientIDRequired
                }
                clientID = id
            } catch { throw MCPOAuthError.manualClientIDRequired }
        }
        let verifier = try Self.randomURLSafe(), state = try Self.randomURLSafe()
        let challengeValue = Self.pkceChallenge(verifier: verifier)
        let scopes = challenge.scope ?? (prm["scopes_supported"] as? [String])?.joined(separator: " ")
        var components = URLComponents(url: authorization, resolvingAgainstBaseURL: false)
        // Do not preserve server-provided authorization query fields which could duplicate OAuth parameters.
        components?.queryItems = [
            .init(name: "response_type", value: "code"), .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: Self.redirectURI.absoluteString), .init(name: "state", value: state),
            .init(name: "code_challenge", value: challengeValue), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "resource", value: resource.absoluteString)
        ] + (scopes.map { [URLQueryItem(name: "scope", value: $0)] } ?? [])
        guard let authorizationURL = components?.url else { throw MCPOAuthError.invalidMetadata }
        guard epoch(identity) == generation else { throw MCPOAuthError.stale }
        let callback: URL
        do { callback = try await browser(authorizationURL, Self.redirectURI.scheme!) }
        catch { throw MCPOAuthError.cancelled }
        guard epoch(identity) == generation else { throw MCPOAuthError.stale }
        let code = try Self.authorizationCode(callback: callback, expectedState: state, issuer: issuer,
            requiresIssuer: metadata["authorization_response_iss_parameter_supported"] as? Bool == true)
        let record = try await exchange(endpoint: token, fields: [
            "grant_type": "authorization_code", "code": code, "code_verifier": verifier,
            "client_id": clientID, "redirect_uri": Self.redirectURI.absoluteString,
            "resource": resource.absoluteString
        ], resource: resource.absoluteString, issuer: issuer, clientID: clientID, previousRefresh: nil)
        try Task.checkCancellation()
        try save(record, server: server, generation: generation)
    }

    static func authorizationCode(callback: URL, expectedState: String, issuer: String, requiresIssuer: Bool = false) throws -> String {
        guard callback.scheme == redirectURI.scheme, callback.host == redirectURI.host,
              callback.path == redirectURI.path, callback.fragment == nil,
              callback.user == nil, callback.password == nil, callback.port == nil,
              let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false) else { throw MCPOAuthError.invalidCallback }
        func only(_ name: String) throws -> String? {
            let values = (parts.queryItems ?? []).filter { $0.name == name }
            guard values.count <= 1 else { throw MCPOAuthError.invalidCallback }
            return values.first?.value
        }
        guard try only("state") == expectedState else { throw MCPOAuthError.stateMismatch }
        guard try only("error") == nil, let code = try only("code"), !code.isEmpty else { throw MCPOAuthError.invalidCallback }
        let returnedIssuer = try only("iss")
        if requiresIssuer && returnedIssuer == nil { throw MCPOAuthError.invalidCallback }
        if let returnedIssuer, returnedIssuer != issuer { throw MCPOAuthError.invalidCallback }
        return code
    }

    private func selectAuthorizationServer(_ issuers: [String]) async throws -> (String, [String: Any]) {
        var failure: MCPOAuthError = .invalidMetadata
        for issuer in issuers {
            try Task.checkCancellation()
            do {
                guard let url = URL(string: issuer) else { throw MCPOAuthError.invalidMetadata }
                let metadata = try await authorizationMetadata(issuer: url)
                guard metadata["issuer"] as? String == issuer,
                      (metadata["code_challenge_methods_supported"] as? [String])?.contains("S256") == true,
                      let authorization = (metadata["authorization_endpoint"] as? String).flatMap(URL.init(string:)),
                      let token = (metadata["token_endpoint"] as? String).flatMap(URL.init(string:)) else { throw MCPOAuthError.invalidMetadata }
                try Self.validateEndpoint(authorization); try Self.validateEndpoint(token)
                if let methods = metadata["token_endpoint_auth_methods_supported"] as? [String], !methods.contains("none") {
                    throw MCPOAuthError.invalidMetadata
                }
                return (issuer, metadata)
            } catch is CancellationError { throw MCPOAuthError.cancelled }
            catch let error as MCPOAuthError {
                if error == .cancelled { throw error }
                failure = error
            } catch { failure = .invalidMetadata }
        }
        throw failure
    }

    private func protectedMetadata(resource: URL, challenge: MCPOAuthChallenge) async throws -> [String: Any] {
        if let advertised = challenge.metadataURL { return try await json(URLRequest(url: advertised)) }
        let candidates = try Self.discoveryURLs(origin: resource, component: "oauth-protected-resource", includeRoot: true)
        return try await firstMetadata(candidates)
    }
    private func authorizationMetadata(issuer: URL) async throws -> [String: Any] {
        try Self.validateEndpoint(issuer)
        let oauth = try Self.discoveryURLs(origin: issuer, component: "oauth-authorization-server", includeRoot: false)
        let oidc = try Self.discoveryURLs(origin: issuer, component: "openid-configuration", includeRoot: false)
        var appended = URLComponents(url: issuer, resolvingAgainstBaseURL: false)
        appended?.path = issuer.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
            ? "/.well-known/openid-configuration" : issuer.path + "/.well-known/openid-configuration"
        let candidates = oauth + oidc + [appended?.url].compactMap { $0 }
        var unique: [URL] = []
        for candidate in candidates where !unique.contains(candidate) { unique.append(candidate) }
        return try await firstMetadata(unique)
    }
    private func firstMetadata(_ urls: [URL]) async throws -> [String: Any] {
        for url in urls {
            try Task.checkCancellation()
            do { return try await json(URLRequest(url: url)) }
            catch is CancellationError { throw MCPOAuthError.cancelled }
            catch { continue }
        }
        throw MCPOAuthError.invalidMetadata
    }
    static func discoveryURLs(origin: URL, component: String, includeRoot: Bool) throws -> [URL] {
        try validateEndpoint(origin)
        guard var parts = URLComponents(url: origin, resolvingAgainstBaseURL: false) else { throw MCPOAuthError.invalidMetadata }
        parts.query = nil; parts.fragment = nil
        let suffix = origin.path == "/" ? "" : origin.path
        parts.path = "/.well-known/" + component + suffix
        guard let specific = parts.url else { throw MCPOAuthError.invalidMetadata }
        parts.path = "/.well-known/" + component
        return includeRoot && parts.url != specific ? [specific] + [parts.url].compactMap { $0 } : [specific]
    }
    static func resource(_ server: MCPServer) throws -> URL {
        guard let raw = server.url, var parts = URLComponents(string: raw) else { throw MCPOAuthError.invalidMetadata }
        parts.scheme = parts.scheme?.lowercased(); parts.host = parts.host?.lowercased()
        guard parts.query == nil, parts.fragment == nil, let url = parts.url else { throw MCPOAuthError.invalidMetadata }
        try validateEndpoint(url)
        return url
    }
    static func validateEndpoint(_ url: URL) throws {
        let local = ["127.0.0.1", "localhost", "[::1]", "::1"].contains(url.host?.lowercased() ?? "")
        guard (url.scheme == "https" || (url.scheme == "http" && local)), url.host != nil,
              url.user == nil, url.password == nil, url.fragment == nil else { throw MCPOAuthError.insecureEndpoint }
    }
    private func json(_ input: URLRequest) async throws -> [String: Any] {
        guard let url = input.url else { throw MCPOAuthError.invalidMetadata }
        try Self.validateEndpoint(url)
        var request = input; request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw MCPOAuthError.requestFailed }
            if (400..<500).contains(http.statusCode) { throw MCPOAuthError.requestRejected }
            guard (200..<300).contains(http.statusCode), data.count <= 1_048_576,
                  let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MCPOAuthError.requestFailed }
            return result
        } catch is CancellationError { throw MCPOAuthError.cancelled }
        catch let safe as MCPOAuthError { throw safe }
        catch { throw MCPOAuthError.requestFailed }
    }
    private func exchange(endpoint: URL, fields: [String: String], resource: String, issuer: String,
                          clientID: String, previousRefresh: String?) async throws -> MCPOAuthCredential {
        var request = URLRequest(url: endpoint); request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.form(fields).utf8)
        let response = try await json(request)
        if response["error"] as? String == "invalid_grant" { throw MCPOAuthError.requestRejected }
        guard let access = response["access_token"] as? String, !access.isEmpty,
              (response["token_type"] as? String)?.lowercased() == "bearer",
              access.utf8.allSatisfy({ (0x21...0x7E).contains($0) }) else { throw MCPOAuthError.requestFailed }
        let seconds = response["expires_in"] as? Double
        if response["expires_in"] != nil && seconds == nil { throw MCPOAuthError.requestFailed }
        if let seconds, !seconds.isFinite || seconds <= 0 { throw MCPOAuthError.requestFailed }
        if let refresh = response["refresh_token"] as? String, refresh.isEmpty { throw MCPOAuthError.requestFailed }
        return MCPOAuthCredential(resource: resource, issuer: issuer, tokenEndpoint: endpoint, clientID: clientID,
            accessToken: access, refreshToken: response["refresh_token"] as? String ?? previousRefresh,
            expiresAt: seconds.map { now().addingTimeInterval($0) })
    }
    static func form(_ values: [String: String]) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return values.sorted { $0.key < $1.key }.map {
            ($0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "=" + ($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&")
    }
    /// PKCE S256 challenge, shared with the ChatGPT account sign-in.
    static func pkceChallenge(verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func randomURLSafe() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw MCPOAuthError.requestFailed }
        return base64URL(Data(bytes))
    }
}

/// Shared by streamable HTTP and legacy SSE. Never forwards credentials on redirects.
struct MCPOAuthHTTPAuthorization: Sendable {
    let server: MCPServer
    let coordinator: MCPOAuthCoordinator
    func prepare(_ request: URLRequest) async throws -> URLRequest {
        var result = request
        if let token = try await coordinator.accessToken(server: server) {
            result.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        return result
    }
    func recordUnauthorized(_ response: URLResponse) async throws -> Bool {
        guard let http = response as? HTTPURLResponse, http.statusCode == 401 else { return false }
        guard let header = http.value(forHTTPHeaderField: "WWW-Authenticate") else { throw MCPOAuthError.loginRequired }
        try await coordinator.receiveUnauthorized(server: server, header: header)
        return true
    }
    func rejected(_ response: HTTPURLResponse, request: URLRequest) async throws {
        _ = try await recordUnauthorized(response)
        guard request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true,
              try await coordinator.accessToken(server: server, forceRefresh: true) != nil else { throw MCPOAuthError.loginRequired }
    }
}
