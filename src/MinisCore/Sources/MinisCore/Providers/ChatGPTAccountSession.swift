import Foundation
import CryptoKit
import Security

// "Sign in with ChatGPT" (open-source token sharing). Public spec:
// https://developers.openai.com/siwc/token-sharing-open-source
// Written from the public documentation only; no third-party code is copied.

/// Safe public errors: never interpolate endpoint responses, callbacks or credentials.
public enum ChatGPTAccountError: String, Error, LocalizedError, Sendable, Equatable, CaseIterable {
    case notSignedIn, sessionExpired, cancelled, loginTimedOut, stateMismatch, invalidCallback, accessDenied
    case registrationIncomplete, clientMismatch, accountMismatch, tokenExchangeFailed, invalidIDToken
    case planUsageNotEnabled, credentialUnavailable, requestFailed, listenerUnavailable, stale
    case invalidClient, browserUnavailable

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: return "尚未登录 ChatGPT 账号。请到“设置 → 环境变量/模型供应商”点击“Continue with ChatGPT”登录。"
        case .sessionExpired: return "ChatGPT 登录已过期或被撤销。请在设置里重新登录。"
        case .cancelled: return "已取消 ChatGPT 登录。"
        case .loginTimedOut: return "ChatGPT 登录超时：15 分钟内没有完成浏览器授权。请重新点“Continue with ChatGPT”。"
        case .stateMismatch, .invalidCallback: return "ChatGPT 登录回调校验失败，请重新登录。"
        case .accessDenied: return "你在浏览器里拒绝了授权。需要时可重新点击登录。"
        case .registrationIncomplete: return "ChatGPT 没有返回应用登记信息，登录未完成。请重新登录。"
        case .clientMismatch: return "ChatGPT 返回的应用登记与本机记录不一致，已拒绝。请选“使用其他账号登录”重新登记。"
        case .accountMismatch: return "所选 ChatGPT 账号与本机已登记的账号不一致，已拒绝。要换账号请选“使用其他账号登录”。"
        case .tokenExchangeFailed: return "ChatGPT 登录换取令牌失败，请重新登录。"
        case .invalidIDToken: return "无法验证 ChatGPT 返回的身份信息，已拒绝本次登录。"
        case .planUsageNotEnabled: return "该账号没有授权在本应用使用 ChatGPT 套餐额度。请重新登录并同意授权，或到 ChatGPT 设置中检查。"
        case .credentialUnavailable: return "无法安全读取或保存 ChatGPT 登录凭据。"
        case .requestFailed: return "连接 ChatGPT 登录服务失败，请检查网络后重试。"
        case .listenerUnavailable: return "无法在本机开启登录回调端口，请稍后重试。"
        case .stale: return "登录状态已变化，请重试。"
        case .invalidClient: return "ChatGPT 登录配置不被接受，请重新登录或更新应用。"
        case .browserUnavailable: return "无法打开系统浏览器，请检查默认浏览器设置。"
        }
    }
}

public enum ChatGPTAccountEndpoints {
    public static let authorize = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    public static let token = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    public static let openIDConfiguration = URL(string: "https://auth.openai.com/.well-known/openid-configuration")!
    public static let issuer = "https://auth.openai.com"
    public static let resource = "https://api.openai.com/v1"
    public static let responsesHost = "api.openai.com"
    public static let models = URL(string: "https://api.openai.com/v1/models")!
    public static let callbackPath = "/auth/callback"
    public static let dynamicClientID = "dynamic_agent_client"
    public static let agentName = "MinisCanvas"
    public static let directScope = "chatgpt.tokens.use.direct"
    public static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    public static let usageSettingsURL = URL(string: "https://chatgpt.com/settings/usage")!

    /// The account token may only be sent to the official API host over https on the default port.
    public static func isOfficialAPIURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == responsesHost && (url.port == nil || url.port == 443)
    }
}

public struct ChatGPTAccountInfo: Equatable, Sendable {
    public let email: String?
    public var label: String { email ?? "ChatGPT 账号" }
}

public enum ChatGPTAccountStatus: Equatable, Sendable {
    case signedOut
    case signedIn(ChatGPTAccountInfo)
    case needsRelogin(ChatGPTAccountInfo?)
}

public struct ChatGPTAccountModel: Equatable, Sendable {
    public let slug: String
    public let displayName: String
}

/// Persisted across sign-out: the issued client and the host identity.
struct ChatGPTAccountRegistration: Codable, Equatable, Sendable {
    var clientID: String?
    var hostID: String
    var subject: String?
    var email: String?
    var needsRelogin: Bool
}

/// Cleared on sign-out. Never logged, never put into an error.
struct ChatGPTAccountTokens: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var idToken: String?
    var expiresAt: Date
    var scopes: [String]
    var savedAt: Date
}

// MARK: - Authorization request and callback

public enum ChatGPTAccountAuthorization {
    public struct Callback: Equatable, Sendable {
        public let code: String
        public let clientID: String?
        public let scopes: [String]
    }

    /// All values are RFC 3986 percent-encoded (including `+` in e-mail hints).
    public static func makeURL(
        clientID: String, redirectURI: String, state: String, nonce: String, codeChallenge: String,
        hostID: String, agentName: String?, idTokenHint: String?, loginHint: String?
    ) -> URL? {
        var fields: [String: String] = [
            "response_type": "code", "client_id": clientID, "redirect_uri": redirectURI,
            "scope": ChatGPTAccountEndpoints.scopes, "resource": ChatGPTAccountEndpoints.resource,
            "state": state, "nonce": nonce, "code_challenge": codeChallenge,
            "code_challenge_method": "S256", "ext_agent_host_id": hostID
        ]
        if let agentName { fields["agent_name_hint"] = agentName }
        if let idTokenHint { fields["id_token_hint"] = idTokenHint }
        if let loginHint { fields["login_hint"] = loginHint }
        guard var components = URLComponents(url: ChatGPTAccountEndpoints.authorize, resolvingAgainstBaseURL: false) else { return nil }
        components.percentEncodedQuery = MCPOAuthCoordinator.form(fields)
        return components.url
    }

    public static func parseCallback(_ url: URL, expectedState: String) throws -> Callback {
        guard url.path == ChatGPTAccountEndpoints.callbackPath, url.fragment == nil,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ChatGPTAccountError.invalidCallback
        }
        func only(_ name: String) throws -> String? {
            let values = (parts.queryItems ?? []).filter { $0.name == name }
            guard values.count <= 1 else { throw ChatGPTAccountError.invalidCallback }
            return values.first?.value
        }
        guard try only("state") == expectedState else { throw ChatGPTAccountError.stateMismatch }
        if let error = try only("error") {
            throw error == "access_denied" ? ChatGPTAccountError.accessDenied : ChatGPTAccountError.invalidCallback
        }
        guard let code = try only("code"), !code.isEmpty else { throw ChatGPTAccountError.invalidCallback }
        let scopes = (try only("scope") ?? "").split(separator: " ").map(String.init)
        return Callback(code: code, clientID: try only("client_id"), scopes: scopes)
    }
}

// MARK: - ID token (JWT) validation

struct ChatGPTIDTokenClaims: Equatable, Sendable {
    let subject: String
    let email: String?
}

enum ChatGPTIDToken {
    struct JWK: Decodable {
        let kty: String
        let kid: String?
        let n: String?, e: String?, x: String?, y: String?
    }

    static func base64URLDecode(_ text: String) -> Data? {
        var value = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while value.count % 4 != 0 { value.append("=") }
        return Data(base64Encoded: value)
    }

    /// Verifies signature (RS256/ES256 against the published JWKS), iss, aud, exp and nonce.
    /// `nonce` is nil for refresh responses, which carry no nonce.
    static func validate(_ token: String, keys: [JWK], clientID: String, nonce: String?, now: Date) throws -> ChatGPTIDTokenClaims {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard segments.count == 3,
              let headerData = base64URLDecode(segments[0]), let payloadData = base64URLDecode(segments[1]),
              let signature = base64URLDecode(segments[2]),
              let header = (try? JSONSerialization.jsonObject(with: headerData)) as? [String: Any],
              let claims = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any],
              let algorithm = header["alg"] as? String else { throw ChatGPTAccountError.invalidIDToken }
        let signed = Data((segments[0] + "." + segments[1]).utf8)
        let kid = header["kid"] as? String
        let candidates = keys.filter { kid == nil || $0.kid == kid }
        guard candidates.contains(where: { verify(signature, over: signed, algorithm: algorithm, key: $0) }) else {
            throw ChatGPTAccountError.invalidIDToken
        }
        guard claims["iss"] as? String == ChatGPTAccountEndpoints.issuer else { throw ChatGPTAccountError.invalidIDToken }
        let audiences = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard audiences.contains(clientID) else { throw ChatGPTAccountError.invalidIDToken }
        guard let exp = (claims["exp"] as? NSNumber)?.doubleValue,
              Date(timeIntervalSince1970: exp) > now.addingTimeInterval(-60) else { throw ChatGPTAccountError.invalidIDToken }
        if let nonce, claims["nonce"] as? String != nonce { throw ChatGPTAccountError.invalidIDToken }
        guard let subject = claims["sub"] as? String, !subject.isEmpty else { throw ChatGPTAccountError.invalidIDToken }
        return ChatGPTIDTokenClaims(subject: subject, email: claims["email"] as? String)
    }

    private static func verify(_ signature: Data, over signed: Data, algorithm: String, key: JWK) -> Bool {
        switch (algorithm, key.kty) {
        case ("ES256", "EC"):
            guard let x = key.x.flatMap(base64URLDecode), let y = key.y.flatMap(base64URLDecode),
                  x.count == 32, y.count == 32,
                  let publicKey = try? P256.Signing.PublicKey(x963Representation: Data([0x04]) + x + y),
                  let ecdsa = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else { return false }
            return publicKey.isValidSignature(ecdsa, for: signed)
        case ("RS256", "RSA"):
            guard let n = key.n.flatMap(base64URLDecode), let e = key.e.flatMap(base64URLDecode) else { return false }
            let der = derSequence(derInteger([UInt8](n)) + derInteger([UInt8](e)))
            let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
            guard let secKey = SecKeyCreateWithData(Data(der) as CFData, attributes as CFDictionary, nil) else { return false }
            return SecKeyVerifySignature(secKey, .rsaSignatureMessagePKCS1v15SHA256, signed as CFData, signature as CFData, nil)
        default:
            return false
        }
    }

    private static func derLength(_ count: Int) -> [UInt8] {
        if count < 128 { return [UInt8(count)] }
        if count < 256 { return [0x81, UInt8(count)] }
        return [0x82, UInt8(count >> 8), UInt8(count & 0xff)]
    }
    private static func derInteger(_ bytes: [UInt8]) -> [UInt8] {
        var value = Array(bytes.drop { $0 == 0 })
        if value.isEmpty { value = [0] }
        if value[0] >= 0x80 { value.insert(0, at: 0) }
        return [0x02] + derLength(value.count) + value
    }
    private static func derSequence(_ content: [UInt8]) -> [UInt8] { [0x30] + derLength(content.count) + content }
}

// MARK: - Session registry

/// The App installs one session (built on the app's own Keychain) at launch.
public enum ChatGPTAccountSessions {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var installed: ChatGPTAccountSession?
    public static func install(_ session: ChatGPTAccountSession) { lock.withLock { installed = session } }
    public static var shared: ChatGPTAccountSession? { lock.withLock { installed } }
}

// MARK: - Session

public actor ChatGPTAccountSession {
    /// Stored as the provider record's "key"; the provider swaps it for the live access token.
    public static let credentialPlaceholder = "chatgpt-account-session"
    public static let providerName = "CHATGPT_ACCOUNT"
    public static let stateChanged = Notification.Name("MinisCanvas.ChatGPTAccountStateChanged")

    private static let registrationKey = "chatgpt.account.registration.v1"
    private static let tokensKey = "chatgpt.account.tokens.v1"
    /// Refresh this long before the access token expires.
    static let refreshSkew: TimeInterval = 300
    private static let terminalRefreshCodes: Set<String> = [
        "invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
        "refresh_token_invalidated", "refresh_token_reused"
    ]

    private struct Discovery: Sendable {
        let jwksURI: URL
        let revocationEndpoint: URL?
    }
    private enum RefreshFailure: Error { case terminal, invalidClient, transient }

    private let keychain: KeychainStore
    private let session: URLSession
    private let now: @Sendable () -> Date
    private var generation: UInt64 = 0
    private var refreshTask: Task<ChatGPTAccountTokens, Error>?
    private var accessTokenRejected = false
    /// Rotated tokens that could not be written to the Keychain yet. They stay usable in
    /// memory (the old refresh token is already dead server-side) and the write is retried.
    private var pendingRotated: ChatGPTAccountTokens?
    private var pendingSaveFailures = 0
    private var discovery: Discovery?
    private var activeListener: LoopbackOAuthListener?

    public init(keychain: KeychainStore, session: URLSession? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.keychain = keychain
        self.session = session ?? URLSession(configuration: .ephemeral, delegate: MCPNoRedirectDelegate(), delegateQueue: nil)
        self.now = now
    }

    // MARK: Status

    public func status() -> ChatGPTAccountStatus {
        let registration = (try? readRegistration()) ?? nil
        let info = registration.map { ChatGPTAccountInfo(email: $0.email) }
        if pendingRotated != nil || ((try? readTokens()) ?? nil) != nil, registration?.needsRelogin != true {
            return .signedIn(info ?? ChatGPTAccountInfo(email: nil))
        }
        if registration?.needsRelogin == true { return .needsRelogin(info) }
        return .signedOut
    }

    /// Marks the current access token as rejected by the server so the next call refreshes it.
    public func noteRejectedAccessToken() { accessTokenRejected = true }

    // MARK: Access token

    /// Called before every request. Refreshes ahead of expiry; refreshes are single-flight
    /// and the rotated refresh token is stored before any waiter gets the new access token.
    public func accessToken() async throws -> String {
        guard let tokens = try currentTokens() else {
            throw ((try? readRegistration()) ?? nil)?.needsRelogin == true
                ? ChatGPTAccountError.sessionExpired : ChatGPTAccountError.notSignedIn
        }
        if !accessTokenRejected, tokens.expiresAt.timeIntervalSince(now()) > Self.refreshSkew {
            return tokens.accessToken
        }
        return try await refresh(tokens).accessToken
    }

    /// In-memory rotated tokens first (retrying the Keychain write each time); after three
    /// failed retries the user is told the credentials cannot be saved.
    private func currentTokens() throws -> ChatGPTAccountTokens? {
        guard let pending = pendingRotated else { return try readTokens() }
        if (try? saveTokens(pending)) != nil {
            pendingRotated = nil
            pendingSaveFailures = 0
        } else {
            pendingSaveFailures += 1
            if pendingSaveFailures >= 3 { throw ChatGPTAccountError.credentialUnavailable }
        }
        return pending
    }

    /// A refresh response may carry a new id_token: keep it only when its signature, issuer,
    /// audience, expiry and subject check out; otherwise keep the previous one.
    private func verifiedIDToken(_ updated: ChatGPTAccountTokens, previous: ChatGPTAccountTokens, clientID: String) async -> ChatGPTAccountTokens {
        guard let newToken = updated.idToken, newToken != previous.idToken else { return updated }
        var result = updated
        result.idToken = previous.idToken
        guard let keys = try? await jwks(),
              let claims = try? ChatGPTIDToken.validate(newToken, keys: keys, clientID: clientID, nonce: nil, now: now()) else { return result }
        if let subject = ((try? readRegistration()) ?? nil)?.subject, subject != claims.subject { return result }
        result.idToken = newToken
        return result
    }

    private func refresh(_ tokens: ChatGPTAccountTokens) async throws -> ChatGPTAccountTokens {
        if let pending = refreshTask { return try await pending.value }
        guard let clientID = try readRegistration()?.clientID else { throw ChatGPTAccountError.notSignedIn }
        let started = generation
        let session = self.session, clock = self.now
        let task = Task {
            let refreshed = try await Self.requestRefresh(session: session, now: clock, tokens: tokens, clientID: clientID)
            return await self.verifiedIDToken(refreshed, previous: tokens, clientID: clientID)
        }
        refreshTask = task
        do {
            let updated = try await task.value
            refreshTask = nil
            guard generation == started else { throw ChatGPTAccountError.stale }
            // The server already rotated the refresh token: never drop it. If the Keychain
            // write fails, keep it in memory and retry on the next access.
            do {
                try saveTokens(updated)
                pendingRotated = nil
            } catch {
                pendingRotated = updated
                pendingSaveFailures = 0
            }
            accessTokenRejected = false
            changed()
            return updated
        } catch {
            refreshTask = nil
            guard generation == started else { throw ChatGPTAccountError.stale }
            if error is CancellationError { throw ChatGPTAccountError.cancelled }
            switch error as? RefreshFailure {
            case .terminal?:
                // Another instance may already have rotated the stored token: only clear what
                // we actually used (compare-and-delete); otherwise continue with the stored one.
                let stored: ChatGPTAccountTokens?
                do { stored = try readTokens() } catch { throw ChatGPTAccountError.credentialUnavailable }
                if pendingRotated?.refreshToken != tokens.refreshToken, let stored, stored.refreshToken != tokens.refreshToken {
                    if !accessTokenRejected, stored.expiresAt.timeIntervalSince(now()) > Self.refreshSkew { return stored }
                    return try await refresh(stored)
                }
                // Unusable refresh token: clear tokens and ask for a new sign-in.
                pendingRotated = nil
                _ = keychain.delete(Self.tokensKey)
                if var registration = try? readRegistration() {
                    registration.needsRelogin = true
                    try? saveRegistration(registration)
                }
                changed()
                throw ChatGPTAccountError.sessionExpired
            case .invalidClient?:
                throw ChatGPTAccountError.invalidClient
            default:
                // Network or server trouble: keep credentials and let the caller retry.
                throw (error as? ChatGPTAccountError) ?? ChatGPTAccountError.requestFailed
            }
        }
    }

    private static func requestRefresh(
        session: URLSession, now: @Sendable () -> Date, tokens: ChatGPTAccountTokens, clientID: String
    ) async throws -> ChatGPTAccountTokens {
        var request = URLRequest(url: ChatGPTAccountEndpoints.token)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(MCPOAuthCoordinator.form([
            "grant_type": "refresh_token", "client_id": clientID,
            "refresh_token": tokens.refreshToken, "resource": ChatGPTAccountEndpoints.resource
        ]).utf8)
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw RefreshFailure.transient }
        guard let http = response as? HTTPURLResponse else { throw RefreshFailure.transient }
        if (200..<300).contains(http.statusCode) {
            guard let updated = parseTokenResponse(data, previous: tokens, now: now()) else { throw RefreshFailure.transient }
            return updated
        }
        let code = oauthErrorCode(data)
        if code == "invalid_client" { throw RefreshFailure.invalidClient }
        if let code, terminalRefreshCodes.contains(code) { throw RefreshFailure.terminal }
        throw RefreshFailure.transient
    }

    // MARK: Sign in

    /// Browser sign-in with PKCE and a 127.0.0.1 loopback callback. `openBrowser` returns
    /// false when the system browser could not be opened.
    public func login(
        replaceRegistration: Bool = false,
        openBrowser: @escaping @Sendable (URL) async -> Bool
    ) async throws -> ChatGPTAccountInfo {
        generation &+= 1
        let started = generation
        refreshTask?.cancel(); refreshTask = nil
        activeListener?.cancel()

        let existing = try readRegistration()
        let hostID = existing?.hostID ?? Self.newHostID()
        let reused = replaceRegistration ? nil : existing
        var registration = ChatGPTAccountRegistration(
            clientID: reused?.clientID, hostID: hostID, subject: reused?.subject,
            email: reused?.email, needsRelogin: reused?.needsRelogin ?? false)
        // The host id must exist before the first sign-in. When switching account the old
        // registration and tokens stay untouched until the new sign-in has fully succeeded.
        if existing == nil || !replaceRegistration { try saveRegistration(registration) }

        let verifier = try Self.randomToken()
        let state = try Self.randomToken()
        let nonce = try Self.randomToken()
        let listener = LoopbackOAuthListener(callbackPath: ChatGPTAccountEndpoints.callbackPath, expectedState: state)
        activeListener = listener
        defer { listener.cancel(); activeListener = nil }
        let port = try await listener.start()
        let redirectURI = "http://127.0.0.1:\(port)\(ChatGPTAccountEndpoints.callbackPath)"

        let idTokenHint = reused?.clientID == nil ? nil : ((try? readTokens()) ?? nil)?.idToken
        guard let authorizationURL = ChatGPTAccountAuthorization.makeURL(
            clientID: reused?.clientID ?? ChatGPTAccountEndpoints.dynamicClientID,
            redirectURI: redirectURI, state: state, nonce: nonce,
            codeChallenge: MCPOAuthCoordinator.pkceChallenge(verifier: verifier),
            hostID: hostID,
            agentName: reused?.clientID == nil ? ChatGPTAccountEndpoints.agentName : nil,
            idTokenHint: idTokenHint,
            loginHint: reused?.clientID == nil ? nil : reused?.email
        ) else { throw ChatGPTAccountError.requestFailed }
        guard await openBrowser(authorizationURL) else { throw ChatGPTAccountError.browserUnavailable }

        // 用户在浏览器里登录（含验证码、两步验证）可能超过 5 分钟（旅程测试 11/17 超时后回调被拒）：放宽到 15 分钟。
        let callbackURL = try await listener.waitForCallback(timeout: 900)
        guard generation == started else { throw ChatGPTAccountError.stale }
        let callback = try ChatGPTAccountAuthorization.parseCallback(callbackURL, expectedState: state)

        let clientID: String
        if let saved = reused?.clientID {
            if let returned = callback.clientID, returned != saved { throw ChatGPTAccountError.clientMismatch }
            clientID = saved
        } else {
            guard let returned = callback.clientID, !returned.isEmpty else { throw ChatGPTAccountError.registrationIncomplete }
            clientID = returned
        }

        let exchanged = try await Self.exchangeCode(
            session: session, now: now(), code: callback.code, verifier: verifier,
            redirectURI: redirectURI, clientID: clientID, fallbackScopes: callback.scopes)
        // A token that was issued but is rejected locally must not stay valid on the server.
        let claims: ChatGPTIDTokenClaims
        do {
            guard generation == started else { throw ChatGPTAccountError.stale }
            guard exchanged.scopes.contains(ChatGPTAccountEndpoints.directScope) else { throw ChatGPTAccountError.planUsageNotEnabled }
            guard let idToken = exchanged.idToken else { throw ChatGPTAccountError.invalidIDToken }
            let keys = try await jwks()
            claims = try ChatGPTIDToken.validate(idToken, keys: keys, clientID: clientID, nonce: nonce, now: now())
            if let subject = reused?.subject, subject != claims.subject { throw ChatGPTAccountError.accountMismatch }
            guard generation == started else { throw ChatGPTAccountError.stale }
        } catch {
            revokeInBackground(refreshToken: exchanged.refreshToken, clientID: clientID)
            throw error
        }

        // Switching account: remember the old authorization so it can be revoked after the swap.
        let previousAuthorization: (refreshToken: String, clientID: String)? = {
            guard replaceRegistration, let oldClient = existing?.clientID,
                  let old = pendingRotated ?? ((try? readTokens()) ?? nil) else { return nil }
            return (old.refreshToken, oldClient)
        }()

        registration.clientID = clientID
        registration.subject = claims.subject
        registration.email = claims.email
        registration.needsRelogin = false
        try saveTokens(exchanged)
        try saveRegistration(registration)
        pendingRotated = nil
        accessTokenRejected = false
        changed()
        if let previousAuthorization, previousAuthorization.refreshToken != exchanged.refreshToken {
            revokeInBackground(refreshToken: previousAuthorization.refreshToken, clientID: previousAuthorization.clientID)
        }
        return ChatGPTAccountInfo(email: claims.email)
    }

    /// Best-effort revocation that never delays or fails the caller.
    private func revokeInBackground(refreshToken: String, clientID: String) {
        Task { _ = await self.revoke(refreshToken: refreshToken, clientID: clientID) }
    }

    /// Cancels a sign-in that is waiting for the browser.
    public func cancelLogin() { activeListener?.cancel() }

    private static func exchangeCode(
        session: URLSession, now: Date, code: String, verifier: String, redirectURI: String,
        clientID: String, fallbackScopes: [String]
    ) async throws -> ChatGPTAccountTokens {
        var request = URLRequest(url: ChatGPTAccountEndpoints.token)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(MCPOAuthCoordinator.form([
            "grant_type": "authorization_code", "client_id": clientID, "code": code,
            "code_verifier": verifier, "redirect_uri": redirectURI, "resource": ChatGPTAccountEndpoints.resource
        ]).utf8)
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw ChatGPTAccountError.cancelled }
        catch { throw ChatGPTAccountError.requestFailed }
        guard let http = response as? HTTPURLResponse else { throw ChatGPTAccountError.requestFailed }
        guard (200..<300).contains(http.statusCode) else {
            throw (400..<500).contains(http.statusCode) ? ChatGPTAccountError.tokenExchangeFailed : ChatGPTAccountError.requestFailed
        }
        let seed = ChatGPTAccountTokens(accessToken: "", refreshToken: "", idToken: nil, expiresAt: now,
                                        scopes: fallbackScopes, savedAt: now)
        guard let tokens = parseTokenResponse(data, previous: seed, now: now), !tokens.refreshToken.isEmpty else {
            throw ChatGPTAccountError.tokenExchangeFailed
        }
        return tokens
    }

    // MARK: Sign out

    /// Stops requests, revokes the refresh token and clears local tokens. Returns whether the
    /// remote revocation was confirmed; the registration (client + host id) is kept.
    @discardableResult
    public func logout() async -> Bool {
        generation &+= 1
        refreshTask?.cancel(); refreshTask = nil
        activeListener?.cancel()
        var revoked = true
        if let tokens = pendingRotated ?? ((try? readTokens()) ?? nil), let clientID = ((try? readRegistration()) ?? nil)?.clientID {
            revoked = await revoke(refreshToken: tokens.refreshToken, clientID: clientID)
        }
        pendingRotated = nil
        _ = keychain.delete(Self.tokensKey)
        if var registration = (try? readRegistration()) ?? nil {
            registration.needsRelogin = false
            try? saveRegistration(registration)
        }
        accessTokenRejected = false
        changed()
        return revoked
    }

    private func revoke(refreshToken: String, clientID: String) async -> Bool {
        guard let endpoint = try? await openIDConfiguration().revocationEndpoint else { return false }
        for attempt in 0..<3 {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(MCPOAuthCoordinator.form([
                "token": refreshToken, "token_type_hint": "refresh_token", "client_id": clientID
            ]).utf8)
            if let (_, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse {
                if http.statusCode == 200 { return true }
                if (400..<500).contains(http.statusCode) { return false }
            }
            if attempt < 2 { try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000) }
        }
        return false
    }

    // MARK: Models

    /// Account-specific model list: `GET /v1/models`, entries with visibility "list".
    public func availableModels() async throws -> [ChatGPTAccountModel] {
        var request = URLRequest(url: ChatGPTAccountEndpoints.models)
        request.timeoutInterval = 30
        let token = try await accessToken()
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw ChatGPTAccountError.cancelled }
        catch { throw ChatGPTAccountError.requestFailed }
        guard let http = response as? HTTPURLResponse else { throw ChatGPTAccountError.requestFailed }
        if http.statusCode == 401 { accessTokenRejected = true }
        guard (200..<300).contains(http.statusCode), let models = ChatGPTAccountCatalog.decode(data), !models.isEmpty else {
            throw ChatGPTAccountError.requestFailed
        }
        return models
    }

    // MARK: Discovery and JWKS

    private func openIDConfiguration() async throws -> Discovery {
        if let discovery { return discovery }
        var request = URLRequest(url: ChatGPTAccountEndpoints.openIDConfiguration)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let jwks = (object["jwks_uri"] as? String).flatMap(URL.init(string:)), jwks.scheme == "https" else {
            throw ChatGPTAccountError.requestFailed
        }
        let revocation = (object["revocation_endpoint"] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
        let value = Discovery(jwksURI: jwks, revocationEndpoint: revocation)
        discovery = value
        return value
    }

    private func jwks() async throws -> [ChatGPTIDToken.JWK] {
        var request = URLRequest(url: try await openIDConfiguration().jwksURI)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawKeys = object["keys"] as? [[String: Any]] else { throw ChatGPTAccountError.invalidIDToken }
        let keys = rawKeys.compactMap { raw in
            (try? JSONSerialization.data(withJSONObject: raw)).flatMap { try? JSONDecoder().decode(ChatGPTIDToken.JWK.self, from: $0) }
        }
        guard !keys.isEmpty else { throw ChatGPTAccountError.invalidIDToken }
        return keys
    }

    // MARK: Persistence

    private func changed() {
        NotificationCenter.default.post(name: Self.stateChanged, object: nil)
    }

    private func readRegistration() throws -> ChatGPTAccountRegistration? {
        try read(ChatGPTAccountRegistration.self, key: Self.registrationKey)
    }
    private func readTokens() throws -> ChatGPTAccountTokens? {
        try read(ChatGPTAccountTokens.self, key: Self.tokensKey)
    }
    private func read<T: Decodable>(_ type: T.Type, key: String) throws -> T? {
        switch keychain.readResult(forKey: key) {
        case .missing: return nil
        case .denied, .failed: throw ChatGPTAccountError.credentialUnavailable
        case .found(let value):
            guard let data = value.data(using: .utf8), let record = try? JSONDecoder().decode(T.self, from: data) else {
                throw ChatGPTAccountError.credentialUnavailable
            }
            return record
        }
    }
    private func saveRegistration(_ value: ChatGPTAccountRegistration) throws { try save(value, key: Self.registrationKey) }
    private func saveTokens(_ value: ChatGPTAccountTokens) throws { try save(value, key: Self.tokensKey) }
    private func save<T: Encodable>(_ value: T, key: String) throws {
        guard let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8),
              keychain.set(text, forKey: key) else { throw ChatGPTAccountError.credentialUnavailable }
    }

    // MARK: Helpers

    private static func randomToken() throws -> String {
        do { return try MCPOAuthCoordinator.randomURLSafe() }
        catch { throw ChatGPTAccountError.requestFailed }
    }

    private static func newHostID() -> String { "urn:uuid:" + UUID().uuidString.lowercased() }

    /// Token endpoint success body. `previous` supplies values the response may omit.
    static func parseTokenResponse(_ data: Data, previous: ChatGPTAccountTokens, now: Date) -> ChatGPTAccountTokens? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let access = object["access_token"] as? String, !access.isEmpty else { return nil }
        let lifetime = (object["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        guard lifetime.isFinite, lifetime > 0 else { return nil }
        let refresh = (object["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? previous.refreshToken
        let scopes = (object["scope"] as? String).map { $0.split(separator: " ").map(String.init) } ?? previous.scopes
        return ChatGPTAccountTokens(
            accessToken: access, refreshToken: refresh,
            idToken: (object["id_token"] as? String) ?? previous.idToken,
            expiresAt: now.addingTimeInterval(lifetime), scopes: scopes, savedAt: now)
    }

    /// `{"error":"x"}`, `{"error":{"code":"x"}}` or `{"code":"x"}`.
    static func oauthErrorCode(_ data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let text = object["error"] as? String { return text }
        if let nested = object["error"] as? [String: Any], let code = nested["code"] as? String { return code }
        return object["code"] as? String
    }
}

// MARK: - Model catalog

public enum ChatGPTAccountCatalog {
    /// `{"models":[{"slug","display_name","visibility"}]}`; only visibility "list", server order kept.
    public static func decode(_ data: Data) -> [ChatGPTAccountModel]? {
        guard data.count <= 4 * 1_048_576,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let models = object["models"] as? [[String: Any]] else { return nil }
        var seen = Set<String>()
        var result: [ChatGPTAccountModel] = []
        for model in models where model["visibility"] as? String == "list" {
            guard let slug = (model["slug"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !slug.isEmpty, seen.insert(slug).inserted else { continue }
            result.append(ChatGPTAccountModel(slug: slug, displayName: (model["display_name"] as? String) ?? slug))
        }
        return result
    }
}
