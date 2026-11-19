import Foundation
import WebKit
import AppKit

// MARK: - Scope and write authorization

/// Which browser surface owns a login/cookie boundary (BROWSER-05).
///
/// 用户浏览器 and Agent 浏览器 are two separate isolation dimensions: a cookie
/// the agent acquires must never surface in the user's own browser tab, and the
/// reverse must hold as well.
public enum BrowserSessionSurface: String, Codable, Equatable, Hashable, CaseIterable, Sendable {
    /// The browser tab a human operates.
    case userBrowser
    /// The headless browser the agent tool drives.
    case agentBrowser
}

/// Structured isolation identity for one 登录态/Cookie/缓存/页面存储 boundary.
///
/// The key carries the four dimensions BROWSER-05 demands:
/// 1. ``surface``   — 用户浏览器 vs Agent 浏览器,
/// 2. ``profile``   — the concrete browser instance inside that surface,
/// 3. ``session``   — 会话 (one conversation / agent run),
/// 4. ``workspace`` — 工作区 (one project or document).
///
/// Every component is whitespace-trimmed; a key with an empty component is
/// invalid and can never name a shared data store. ``canonicalID`` is a
/// lossless, collision-free string form: each component is length-prefixed, so
/// two different four-tuples can never serialize to the same text and the text
/// always decodes back into the same four-tuple.
public struct BrowserScopeIsolationKey: Codable, Equatable, Hashable, Sendable {
    /// Marker of the canonical id format. Bump only together with a new parser.
    static let idPrefix = "browser:v1:"
    /// Version recorded alongside a persisted structured scope.
    static let formatVersion = 1

    public let surface: BrowserSessionSurface
    public let profile: String
    public let session: String
    public let workspace: String

    public init(
        surface: BrowserSessionSurface,
        profile: String,
        session: String,
        workspace: String
    ) {
        self.surface = surface
        self.profile = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session.trimmingCharacters(in: .whitespacesAndNewlines)
        self.workspace = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isValid: Bool { !profile.isEmpty && !session.isEmpty && !workspace.isEmpty }

    /// The canonical string identity of this four-tuple.
    public var canonicalID: String {
        let components = [surface.rawValue, profile, session, workspace]
        return Self.idPrefix + components.map { "\($0.count):\($0)" }.joined(separator: "#")
    }

    /// Recover the four-tuple from a canonical id. Returns `nil` for anything
    /// that is not exactly the canonical format, so a caller-supplied legacy
    /// string is never mistaken for structured identity.
    public static func parse(canonicalID id: String) -> BrowserScopeIsolationKey? {
        guard id.hasPrefix(Self.idPrefix) else { return nil }
        let body = Array(id.dropFirst(Self.idPrefix.count))
        var components: [String] = []
        var index = 0
        while components.count < 4 {
            var lengthText = ""
            while index < body.count, body[index].isNumber {
                lengthText.append(body[index])
                index += 1
            }
            guard !lengthText.isEmpty, index < body.count, body[index] == ":" else { return nil }
            index += 1
            guard let length = Int(lengthText), length <= body.count - index else { return nil }
            components.append(String(body[index ..< index + length]))
            index += length
            if components.count < 4 {
                guard index < body.count, body[index] == "#" else { return nil }
                index += 1
            }
        }
        guard index == body.count,
              components.count == 4,
              let surface = BrowserSessionSurface(rawValue: components[0]) else { return nil }
        let key = BrowserScopeIsolationKey(
            surface: surface,
            profile: components[1],
            session: components[2],
            workspace: components[3]
        )
        return key.isValid ? key : nil
    }
}

/// Stable identity for one browser login/cookie boundary.
///
/// Two identity shapes coexist deliberately:
/// * ``init(id:)`` keeps every existing string-scoped caller compiling and
///   behaving exactly as before — isolation is by that one exact string.
/// * ``init(surface:profile:session:workspace:)`` adds the structured
///   four-dimension identity required by BROWSER-05.
///
/// A string-shaped identity is never promoted into a browser/session/workspace
/// scope, and the WebKit data-store registry keeps the two namespaces apart so a
/// legacy string can never alias a structured four-tuple.
public struct BrowserSessionScope: Codable, Equatable, Hashable, Sendable {
    /// The identity shape that actually decides isolation. Internal so the
    /// data-store registry and the tests can distinguish the namespaces.
    enum Shape: Equatable, Hashable, Sendable {
        /// A caller-supplied opaque string, or a persisted legacy record.
        case opaque(String)
        /// A verified structured four-dimension identity.
        case structured(BrowserScopeIsolationKey)
        /// A record that claimed structured identity but did not verify.
        /// Fails closed: no shared store, no authorization, nothing cached.
        case unverified(String)
    }

    /// String form of the identity. For a structured scope this is the
    /// canonical encoding of the whole four-tuple, so anything that carries
    /// `id` (navigation policy, leases, ``BrowserSessionIdentity``,
    /// ``BrowserWriteAuthorization``) is bound to the composite identity too.
    public let id: String

    /// Actual isolation identity behind ``id``.
    let shape: Shape

    /// Legacy / string-preserving initializer. Whitespace is trimmed exactly as
    /// before. A string that is a canonical four-tuple this module minted
    /// recovers its structured identity; every other string stays a standalone
    /// opaque scope and shares nothing beyond its exact text.
    public init(id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if let key = BrowserScopeIsolationKey.parse(canonicalID: trimmed) {
            self.id = key.canonicalID
            self.shape = .structured(key)
        } else {
            self.id = trimmed
            self.shape = .opaque(trimmed)
        }
    }

    /// Structured four-dimension initializer (BROWSER-05). An empty dimension
    /// yields an unverified scope, which fails closed everywhere.
    public init(
        surface: BrowserSessionSurface,
        profile: String,
        session: String,
        workspace: String
    ) {
        self.init(key: BrowserScopeIsolationKey(
            surface: surface,
            profile: profile,
            session: session,
            workspace: workspace
        ))
    }

    /// Wrap a verified ``BrowserScopeIsolationKey``.
    public init(key: BrowserScopeIsolationKey) {
        self.id = key.canonicalID
        self.shape = key.isValid ? .structured(key) : .unverified(key.canonicalID)
    }

    private init(unverifiedID id: String) {
        self.id = id
        self.shape = .unverified(id)
    }

    public var isValid: Bool {
        switch shape {
        case .opaque(let raw): return !raw.isEmpty
        case .structured(let key): return key.isValid
        case .unverified: return false
        }
    }

    /// The verified structured identity, when this scope carries one.
    public var isolationKey: BrowserScopeIsolationKey? {
        if case .structured(let key) = shape, key.isValid { return key }
        return nil
    }

    /// True when the scope only carries a caller-supplied string identity.
    public var isLegacyOpaque: Bool {
        if case .opaque = shape { return true }
        return false
    }

    /// True when a persisted record declared structure it could not prove.
    /// Such a scope keeps its own private store and authorizes nothing.
    public var isIsolationUnverified: Bool {
        if case .unverified = shape { return true }
        return false
    }

    /// Key actually used by the WebKit data-store registry. `nil` means the
    /// scope must not share a store with any other scope.
    var registryKey: BrowserScopeRegistryKey? {
        switch shape {
        case .structured(let key) where key.isValid: return .structured(key)
        case .opaque(let raw) where !raw.isEmpty: return .opaque(raw)
        case .opaque, .structured, .unverified: return nil
        }
    }

    /// A fresh scope is intentionally unique when a caller does not provide
    /// one. This prevents the default browser tool from sharing login state.
    public static func ephemeral() -> BrowserSessionScope {
        BrowserSessionScope(id: "ephemeral:\(UUID().uuidString)")
    }

    // MARK: Codable — legacy single-id records must keep decoding

    private enum CodingKeys: String, CodingKey {
        case id
        case version
        case surface
        case profile
        case session
        case workspace
        case isolationRejected
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch shape {
        case .opaque(let raw):
            // Byte-for-byte the pre-BROWSER-05 payload: older readers keep
            // working and nothing new is asserted about structure.
            try container.encode(raw, forKey: .id)
        case .structured(let key):
            try container.encode(key.canonicalID, forKey: .id)
            try container.encode(BrowserScopeIsolationKey.formatVersion, forKey: .version)
            try container.encode(key.surface.rawValue, forKey: .surface)
            try container.encode(key.profile, forKey: .profile)
            try container.encode(key.session, forKey: .session)
            try container.encode(key.workspace, forKey: .workspace)
        case .unverified(let raw):
            try container.encode(raw, forKey: .id)
            try container.encode(true, forKey: .isolationRejected)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawID = (try container.decodeIfPresent(String.self, forKey: .id) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if (try container.decodeIfPresent(Bool.self, forKey: .isolationRejected)) == true {
            self.init(unverifiedID: rawID)
            return
        }
        let version = try container.decodeIfPresent(Int.self, forKey: .version)
        let surfaceRaw = try container.decodeIfPresent(String.self, forKey: .surface)
        let profile = try container.decodeIfPresent(String.self, forKey: .profile)
        let session = try container.decodeIfPresent(String.self, forKey: .session)
        let workspace = try container.decodeIfPresent(String.self, forKey: .workspace)
        let declaredFlags = [
            version != nil,
            surfaceRaw != nil,
            profile != nil,
            session != nil,
            workspace != nil
        ]
        let declaredComponents = declaredFlags.filter { $0 }.count
        guard declaredComponents > 0 else {
            // Persisted legacy record: it decodes, keeps its exact id and
            // stays an opaque single-string scope. It is never widened.
            self.init(id: rawID)
            return
        }
        // A record claiming structure must supply every dimension and an id
        // that is exactly the canonical encoding of those dimensions. Anything
        // else is rejected closed rather than trusted partially.
        guard declaredComponents == 5,
              version == BrowserScopeIsolationKey.formatVersion,
              let surfaceRaw,
              let surface = BrowserSessionSurface(rawValue: surfaceRaw),
              let profile, let session, let workspace,
              rawID.hasPrefix(BrowserScopeIsolationKey.idPrefix) else {
            self.init(unverifiedID: rawID)
            return
        }
        let key = BrowserScopeIsolationKey(
            surface: surface,
            profile: profile,
            session: session,
            workspace: workspace
        )
        guard key.isValid, key.canonicalID == rawID else {
            self.init(unverifiedID: rawID)
            return
        }
        self.init(key: key)
    }
}

/// Namespace the WebKit data-store registry keys on. Wrapping the two identity
/// shapes in an enum guarantees a legacy string and a structured four-tuple can
/// never land in the same slot, even if their texts were made to look alike.
enum BrowserScopeRegistryKey: Hashable, Sendable {
    case structured(BrowserScopeIsolationKey)
    case opaque(String)
}

/// Explicit capability required by browser actions that mutate page state.
/// The grant is bound to the concrete browser/session/workspace identity and
/// cannot authorize a different session by accident.
public struct BrowserWriteAuthorization: Codable, Equatable, Hashable, Sendable {
    public let grantID: String
    public let scopeID: String

    public init(grantID: String, scopeID: String) {
        self.grantID = grantID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.scopeID = scopeID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Bind a grant to a concrete four-dimension identity (BROWSER-05). The
    /// bound string is the canonical encoding of the whole four-tuple, so the
    /// grant cannot address a different browser/session/workspace.
    public init(grantID: String, scope: BrowserSessionScope) {
        self.init(grantID: grantID, scopeID: scope.id)
    }

    public var isValid: Bool { !grantID.isEmpty && !scopeID.isEmpty }

    /// The scope identity this grant is bound to.
    public var boundScope: BrowserSessionScope { BrowserSessionScope(id: scopeID) }

    /// Whether this grant authorizes `scope`. Any difference in browser,
    /// profile, session or workspace fails closed, and so does a scope whose
    /// identity shape is legacy/unknown relative to the grant.
    public func authorizes(_ scope: BrowserSessionScope) -> Bool {
        let grantScope = boundScope
        guard isValid, grantScope.isValid, scope.isValid else { return false }
        guard grantScope.shape == scope.shape else { return false }
        return grantScope.id == scope.id
    }
}

/// Identity for the currently live WebKit resource.  Reclaiming or reopening
/// a tab rotates the generation, so an async result from an older WebView can
/// never be published into the current scope.  `scopeID` is the canonical
/// identity of the whole isolation key (BROWSER-05), so this value cannot be
/// replayed into a different browser, session or workspace either.
public struct BrowserSessionIdentity: Codable, Equatable, Hashable, Sendable {
    public let scopeID: String
    public let generation: UInt64

    public init(scopeID: String, generation: UInt64) {
        self.scopeID = scopeID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.generation = generation
    }

    public var isValid: Bool { !scopeID.isEmpty && generation > 0 }
}

/// Lifecycle of the resource backing one browser scope.
public enum BrowserSessionResourceState: String, Codable, Equatable, Sendable {
    /// A WebView is available and may service an operation.
    case live
    /// No operation is holding a lease and the idle timer is armed.
    case idleEligible
    /// The previous WebView was detached and released; scope data remains.
    case reclaimed
    /// A replacement WebView is being installed.
    case reopening
    /// The session was explicitly closed and cannot be reopened.
    case closed
}

/// One operation's lease on the current browser resource.  The lease is
/// intentionally opaque to callers; only the owning session can release it.
public struct BrowserSessionOperationLease: Hashable, Sendable {
    fileprivate let id: UUID
    public let scopeID: String
    public let generation: UInt64

    fileprivate init(id: UUID, scopeID: String, generation: UInt64) {
        self.id = id
        self.scopeID = scopeID
        self.generation = generation
    }
}

// MARK: - Errors

/// Errors thrown by `BrowserSession`.
///
/// (Ported from OpenMinis `Agent/BrowserUse/BrowserUseManager.swift` — the
/// B1e macOS headless WebView wrapper keeps only the navigation / JS / text /
/// screenshot primitives; tab pooling, cookies and the DOM-settle machinery
/// are out of scope for now.)
public enum BrowserError: Error, Equatable, LocalizedError {
    /// Navigation did not complete within the timeout.
    case navigationTimeout(URL)
    /// Navigation failed (DNS / TLS / offline / server error).
    case navigationFailed(String)
    /// `evaluateJavaScript` / `callAsyncJavaScript` threw.
    case javascriptFailed(String)
    /// Page snapshot failed.
    case screenshotFailed(String)
    /// Extracting text content failed.
    case textExtractionFailed(String)
    /// A back-navigation was requested while there is no back history.
    case cannotGoBack
    /// No page loaded yet (e.g. `executeJavaScript` before any navigation).
    case noPageLoaded
    /// Click/type requires an explicit grant bound to this browser scope.
    case writeAuthorizationRequired(String)
    /// An operation tried to use a session after it was explicitly closed.
    case resourceClosed
    /// An idle reclaim invalidated an in-flight operation.
    case resourceReclaimed
    /// The result belongs to an older WebView resource generation.
    case staleResult
    /// A navigation was rejected by the existing domain/scope policy before
    /// it was allowed to proceed.
    case navigationDenied(BrowserNavigationPolicy.Denial)

    public var errorDescription: String? {
        switch self {
        case .navigationTimeout(let url):
            return "Navigation timed out: \(url.absoluteString)"
        case .navigationFailed(let detail):
            return "Navigation failed: \(detail)"
        case .javascriptFailed(let detail):
            return "JavaScript execution failed: \(detail)"
        case .screenshotFailed(let detail):
            return "Screenshot failed: \(detail)"
        case .textExtractionFailed(let detail):
            return "Text extraction failed: \(detail)"
        case .cannotGoBack:
            return "Cannot go back: no back navigation history"
        case .noPageLoaded:
            return "No page loaded"
        case .writeAuthorizationRequired(let action):
            return "Browser action requires explicit write authorization: \(action)"
        case .resourceClosed:
            return "Browser session is closed"
        case .resourceReclaimed:
            return "Browser resource was reclaimed; retry to reopen it"
        case .staleResult:
            return "Browser result belongs to a stale resource generation"
        case .navigationDenied(let denial):
            if denial == .domainNotAuthorized || denial == .crossOriginNotAuthorized {
                return "\(denial.message)。如果信任目标网站，可在内置浏览器地址栏直接输入目标网址。Agent 的浏览器工具和网页抓取使用\(BrowserNavigationPolicy.allowedWebsitesSettingsPath)中的“\(BrowserNavigationPolicy.allowedWebsitesSettingLabel)”。"
            }
            return "Browser navigation denied: \(denial.message)"
        }
    }
}

// MARK: - Session

/// macOS `WKWebView` wrapper used by the agent's `browser` tool.
///
/// Everything here must run on the main actor — `WKWebView` is not
/// Sendable and WebKit requires main-thread access. Callers that are not
/// `@MainActor` (e.g. a `ToolExecutor` hop) must `await` the calls.
///
/// Scope (B1e + D-BROWSER-01): navigate / back / execute JS / click / type /
/// text extraction / viewport screenshot, plus one scope-isolated WebView
/// resource with bounded idle reclaim/reopen. The website data store is the
/// login/cookie boundary: idle reclaim never clears it and every reopened
/// resource re-binds the very same scoped store. Since BROWSER-05 that
/// boundary is keyed by the structured browser/profile/session/workspace
/// identity in ``BrowserSessionScope``, not by one opaque string. The
/// boundary's full lifecycle is now closed: a registry slot — and the
/// 登录态/Cookie/缓存/页面存储 it holds — survives while at least one live
/// session of that identity exists and is released deterministically when
/// the last live session of the identity is explicitly closed, so a later
/// session claiming the same identity starts from a fresh private store
/// instead of resurrecting the closed generation's state.
///
/// `@unchecked Sendable`: the class is `@MainActor`-isolated, so every mutable
/// property is only touched on the main actor — crossing actor boundaries with
/// a reference is therefore safe. The unchecked conformance lets the
/// nonisolated `BrowserTool.execute` entry point accept and forward the
/// session without Swift 6 region-isolation diagnostics.
@MainActor
public final class BrowserSession: NSObject, @unchecked Sendable {

    /// In-process data-store registry. The key is the full isolation identity
    /// (browser surface, browser profile, session, workspace) wrapped in a
    /// namespace, so two callers differing in ANY dimension can never receive
    /// the same store while an identical four-tuple always receives the same
    /// one. A string-shaped legacy scope keeps its own slot and is never
    /// widened into a structured scope. Invalid or unverified scopes are not
    /// cached at all and get a private store each time. The default scope is
    /// ephemeral and therefore receives a private store.
    ///
    /// Slot lifecycle (Cookie 语义, BROWSER-01/BROWSER-05): every session
    /// with a registry key holds exactly one live reference to its slot;
    /// ``dataStore(for:)`` may hand the same store to any number of live
    /// sessions, an idle reclaim never touches the registry, and closing the
    /// last live session of an identity drops the slot so the store (and its
    /// cookies/login state) is released instead of pinned for the whole
    /// process lifetime.
    private static var scopedDataStores: [BrowserScopeRegistryKey: WKWebsiteDataStore] = [:]

    /// Live-session count per registry slot. Mutated only on the main actor,
    /// in lockstep with session construction and `close()`.
    private static var liveSessionCounts: [BrowserScopeRegistryKey: Int] = [:]

    private static func dataStore(for scope: BrowserSessionScope) -> WKWebsiteDataStore {
        guard let registryKey = scope.registryKey else { return WKWebsiteDataStore.nonPersistent() }
        if let existing = scopedDataStores[registryKey] { return existing }
        let store = WKWebsiteDataStore.nonPersistent()
        scopedDataStores[registryKey] = store
        return store
    }

    private static func retainRegistrySlot(for key: BrowserScopeRegistryKey) {
        liveSessionCounts[key, default: 0] += 1
    }

    /// Release one live-session reference. When the last live session of an
    /// identity closes, the registry drops its only owned reference to the
    /// slot's `WKWebsiteDataStore`, so no future session can inherit or
    /// replay the closed generation's 登录态/Cookie/缓存/页面存储 through it.
    private static func releaseRegistrySlot(for key: BrowserScopeRegistryKey) {
        guard let count = liveSessionCounts[key] else { return }
        if count > 1 {
            liveSessionCounts[key] = count - 1
        } else {
            liveSessionCounts[key] = nil
            scopedDataStores[key] = nil
        }
    }

    // MARK: Public state

    /// The underlying WebKit view. Exposed read-only so host apps can embed it.
    /// Its identity changes only when the resource is reclaimed/reopened.
    public private(set) var webView: WKWebView

    /// Viewport used for headless operation (no host window). 1280x800 desktop.
    public static let defaultViewport = CGRect(x: 0, y: 0, width: 1280, height: 800)

    /// Cookie and login state boundary for this session.
    public let scope: BrowserSessionScope

    public var scopeID: String { scope.id }

    /// Optional explicit grant for page-mutating actions.
    public private(set) var writeAuthorization: BrowserWriteAuthorization?

    /// One-shot write grants from a human receipt or a confirmed Composer
    /// bypass policy decision (D-BROWSER-07). This ledger is the short-lived
    /// companion of `writeAuthorization`: a permitted side effect runs once,
    /// while the session otherwise stays read-only.
    public let sideEffectGrants = BrowserSideEffectGrantLedger()

    /// Browser tools are read-only unless the grant is bound to this exact
    /// composite scope identity. A grant minted for another browser, profile,
    /// session or workspace — or for an identity whose shape cannot be
    /// verified — unlocks nothing.
    public var isReadOnly: Bool {
        guard let writeAuthorization else { return true }
        return !writeAuthorization.authorizes(scope)
    }

    /// Non-destructive check used by the tool boundary before producing a
    /// structured refusal; execution still consumes the grant atomically.
    public func hasApprovedSideEffectGrant(for action: String, now: Date = Date()) -> Bool {
        sideEffectGrants.hasValidGrant(
            action: action,
            scopeID: scope.id,
            identity: BrowserSideEffectCallContext.current,
            now: now
        )
    }

    /// Consume one approved one-shot side-effect grant bound to this scope.
    /// A missing, expired, action-mismatched or foreign-scope grant returns
    /// `false` and never mutates page state.
    public func consumeApprovedSideEffectGrant(for action: String, now: Date = Date()) -> Bool {
        let grant = sideEffectGrants.consume(
            action: action,
            scopeID: scope.id,
            identity: BrowserSideEffectCallContext.current,
            now: now
        )
        if let grant { BrowserSideEffectCallContext.executionObservation?.recordConsumedGrant(grant) }
        return grant != nil
    }

    /// How long a single navigation may take before `navigate` throws.
    public var navigationTimeout: TimeInterval = 30

    /// Current lifecycle state of the WebView resource.
    public private(set) var resourceState: BrowserSessionResourceState = .live

    /// Monotonic resource generation used to reject late async results.
    public private(set) var resourceGeneration: UInt64 = 1

    public var transferFileAccess: BrowserTransferFileAccess?
    private var pendingTransfer: PendingBrowserTransfer?
    private struct PendingBrowserTransfer {
        let id: UUID
        var target: BrowserInteractionTarget?
        let fileAccess: BrowserTransferFileAccess
        var continuation: CheckedContinuation<String, Error>?
        var operationTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?
        var download: WKDownload?
        var stagingURL: URL?
    }

    public var requiresInteractionReview = false
    private var preparedInteractions: [String: BrowserPreparedInteraction] = [:]
    private var interactionNavigationWindow: (id: UUID, action: String, identity: BrowserSessionIdentity)?
    private var interactionActiveNavigation: WKNavigation?
    private var interactionResponseURL: URL?
    private var interactionWindowTimeout: Task<Void, Never>?

    private func endInteractionNavigationWindow() {
        let hadInteractionWindow = interactionNavigationWindow != nil
        interactionNavigationWindow = nil
        interactionActiveNavigation = nil
        interactionResponseURL = nil
        interactionNavigationPermit = nil
        interactionWindowTimeout?.cancel()
        interactionWindowTimeout = nil
        if hadInteractionWindow { markIdleEligible() }
    }

    private func beginInteractionNavigationWindow(action: String) {
        endInteractionNavigationWindow()
        recordActivity()
        let id = UUID()
        interactionNavigationWindow = (id, action, identity)
        interactionWindowTimeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard self?.interactionNavigationWindow?.id == id else { return }
            self?.endInteractionNavigationWindow()
        }
    }
    private var interactionNavigationPermit: (url: String, expiresAt: Date)?

    public func prepareInteraction(callID: String, target: BrowserInteractionTarget, inputDigest: String,
                                   notice: String?, rule: BrowserInteractionRule?, rules: BrowserInteractionRuleStore) {
        preparedInteractions[callID] = BrowserPreparedInteraction(target: target, inputDigest: inputDigest,
            notice: notice, automaticCategory: nil, ruleID: rule?.id, rules: rules)
    }


    // Only the rule-match branch supplies typed automatic-use evidence. The
    // public legacy notice API remains feedback-only and cannot set this field.
    func prepareAutomaticInteraction(callID: String, target: BrowserInteractionTarget,
                                     inputDigest: String, rule: BrowserInteractionRule,
                                     rules: BrowserInteractionRuleStore) {
        preparedInteractions[callID] = BrowserPreparedInteraction(target: target, inputDigest: inputDigest,
            notice: "已按你的放行自动执行：\(rule.category.title)", automaticCategory: rule.category,
            ruleID: rule.id, rules: rules)
    }

    private func recordAutomaticInteractionCompletion(_ review: BrowserPreparedInteraction?, action: String) {
        guard !Task.isCancelled, let review, let category = review.automaticCategory,
              let ruleID = review.ruleID, accepts(review.target.identity),
              review.target.input.action == action, review.target.input.category == category,
              let rule = review.rules.rules.first(where: { $0.id == ruleID }),
              rule.category == category,
              BrowserNavigationPolicy.sameOrigin(rule.origin, review.target.origin) else { return }
        BrowserSideEffectCallContext.executionObservation?.recordSuccessfulRuleUse(
            category: category, ruleID: ruleID, action: action, scopeID: scope.id)
    }

    private func takeInteractionReview(action: String, selector: String) async throws -> BrowserPreparedInteraction? {
        guard requiresInteractionReview else { return nil }
        guard let call = BrowserSideEffectCallContext.current,
              let prepared = preparedInteractions.removeValue(forKey: call.callID),
              prepared.inputDigest == call.inputDigest,
              prepared.target.input.action == action, prepared.target.input.selector == selector,
              prepared.ruleID.map({ prepared.rules.contains($0) }) ?? true else {
            throw BrowserInteractionError.missingApproval
        }
        let target = try await interactionTarget(prepared.target.input)
        guard target == prepared.target,
              prepared.ruleID.map({ prepared.rules.contains($0) }) ?? true else {
            throw BrowserInteractionError.changedTarget
        }
        return prepared
    }

    private func interactionEffectGuard(_ prepared: BrowserPreparedInteraction?) -> String {
        guard let target = prepared?.target else { return "" }
        let page = Self.interactionLiteral(target.pageURL)
        let fingerprint = Self.interactionLiteral(target.fingerprint)
        return """
        const form = el.form || el.closest('form');
        const link = el.closest('a[href]');
        const href = link ? new URL(link.href, location.href) : null;
        const fingerprint = JSON.stringify([el.tagName,(el.getAttribute('type') || '').toLowerCase(),el.id,el.getAttribute('name'),el.getAttribute('formaction'),form && form.method,form && form.action,href && href.href]);
        if (el.disabled || el.hidden || !el.getClientRects().length || location.href !== \(page) || fingerprint !== \(fingerprint)) return JSON.stringify({error:'Approved browser target changed'});
        """
    }

    public var identity: BrowserSessionIdentity {
        BrowserSessionIdentity(scopeID: scope.id, generation: resourceGeneration)
    }

    /// Number of operation leases currently protecting the resource.
    public private(set) var activeOperationCount = 0

    /// Configured idle timeout in minutes. Values are clamped to the same
    /// range as `BrowserSettings` so callers cannot disable the safety bound.
    public private(set) var idleTimeoutMinutes: Int

    /// Most recent URL known before an idle reclaim. Login/cookie state is
    /// retained by the scope data store; this value lets consumers restore the
    /// visible page after reopening.
    public private(set) var lastKnownURL: URL?

    /// Whether a user-visible surface currently owns the tab.
    public private(set) var isUserVisible = false

    /// Navigation authorization supplied by the production policy boundary or
    /// by an explicit user address-bar action. An empty allowlist is safe:
    /// external navigation remains denied until a caller supplies a domain.
    public private(set) var navigationPolicy: BrowserNavigationPolicy

    // MARK: Private state

    /// Resumed by `didFinish` / `didFail` — nil when no navigation is pending.
    private var pendingNavigation: CheckedContinuation<Void, Error>?
    private var pendingRequestID: UUID?
    /// Trusted URL captured before the current WebKit load. Redirect and
    /// response callbacks use this baseline instead of a mutable `webView.url`;
    /// an unsafe redirect therefore cannot make itself appear same-origin.
    private var pendingNavigationBaselineURL: URL?
    private var pendingNavigationSource: BrowserNavigationPolicy.Source?
    /// WebKit may represent an HTML string document as `about:srcdoc`. Bind
    /// that local identity only to the in-flight `loadHTMLString` request.
    private var pendingLocalHTMLDocumentRequest = false
    private var pendingLocalHTMLDocumentURL: URL?
    /// The real WebKit identity paired with the pending await. Internal read
    /// access also lets deterministic tests deliver genuine stale callbacks.
    private(set) var activeNavigation: WKNavigation?
    /// Watchdog that fails the pending navigation on timeout.
    private var navigationTimeoutTask: Task<Void, Never>?

    /// Resource idle watchdog. It runs only while no operation lease is held
    /// and the tab is not user-visible.
    private var idleReclaimTask: Task<Void, Never>?
    private var lastActivityAt = Date()
    private var operationLeases: Set<UUID> = []
    private var configuredFrame: CGRect
    private var configuredUserAgent: String?
    private var configuredViewport: (width: Int, height: Int)?
    /// The registry slot this session holds one live reference to, or `nil`
    /// for scopes that never enter the registry (ephemeral/unverified).
    /// Nilled exactly once by `close()` so the count can never be
    /// over-decremented by repeated closes.
    private var registryLifecycleKey: BrowserScopeRegistryKey?

    // MARK: Init

    public init(
        frame: CGRect = BrowserSession.defaultViewport,
        userAgent: String? = nil,
        scope: BrowserSessionScope = .ephemeral(),
        writeAuthorization: BrowserWriteAuthorization? = nil,
        idleTimeoutMinutes: Int = BrowserSettings.default.idleTabTimeoutMinutes,
        navigationPolicy: BrowserNavigationPolicy = BrowserNavigationPolicy()
    ) {
        let configuration = WKWebViewConfiguration()
        // Each session owns a private data store. In particular, the default
        // persistent store must never become an implicit cross-scope cookie
        // or login-state channel.
        // Claim the registry reference before binding the store so the slot
        // count always covers every session that can observe the registry.
        if let registryKey = scope.registryKey {
            Self.retainRegistrySlot(for: registryKey)
        }
        configuration.websiteDataStore = Self.dataStore(for: scope)
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: frame, configuration: configuration)
        webView.customUserAgent = userAgent
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        self.scope = scope
        self.writeAuthorization = writeAuthorization
        self.webView = webView
        self.idleTimeoutMinutes = BrowserSettings.clampIdleTimeout(idleTimeoutMinutes)
        self.navigationPolicy = navigationPolicy
        self.configuredFrame = frame
        self.configuredUserAgent = userAgent
        self.configuredViewport = nil
        self.registryLifecycleKey = scope.registryKey
        self.onResourceStateChange = nil
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    /// Convenience initializer for production callers carrying a scope id
    /// instead of constructing the value type themselves.
    public convenience init(
        scopeID: String,
        frame: CGRect = BrowserSession.defaultViewport,
        userAgent: String? = nil,
        writeAuthorization: BrowserWriteAuthorization? = nil,
        idleTimeoutMinutes: Int = BrowserSettings.default.idleTabTimeoutMinutes,
        navigationPolicy: BrowserNavigationPolicy = BrowserNavigationPolicy()
    ) {
        self.init(
            frame: frame,
            userAgent: userAgent,
            scope: BrowserSessionScope(id: scopeID),
            writeAuthorization: writeAuthorization,
            idleTimeoutMinutes: idleTimeoutMinutes,
            navigationPolicy: navigationPolicy
        )
    }

    // MARK: - Resource lifecycle

    /// Whether a result carrying `identity` may still be published.
    public func accepts(_ identity: BrowserSessionIdentity) -> Bool {
        identity.isValid
            && identity.scopeID == scope.id
            && identity.generation == resourceGeneration
            && resourceState == .live
    }

    /// Apply all browser settings at the one resource boundary. Reopened
    /// WebViews receive the same UA, viewport and idle policy automatically.
    public func apply(settings: BrowserSettings) {
        setUserAgent(settings.resolvedUserAgent())
        let viewport = settings.resolvedViewport()
        applyViewport(width: viewport.width, height: viewport.height)
        configureIdleTimeout(minutes: settings.idleTabTimeoutMinutes)
    }

    /// Update the timeout consumed by the live resource. If the tab is already
    /// idle-eligible, the watchdog is re-armed from the current activity mark.
    public func configureIdleTimeout(minutes: Int) {
        idleTimeoutMinutes = BrowserSettings.clampIdleTimeout(minutes)
        guard resourceState != .closed else { return }
        if resourceState == .idleEligible {
            armIdleReclaimTimer()
        }
    }

    /// Record a user or agent activity at an injectable instant. Activity
    /// invalidates a pending idle reclaim without changing the scope or data
    /// store.
    public func recordActivity(at date: Date = Date()) {
        guard resourceState != .closed else { return }
        // Activity callbacks can arrive late or out of order. Never let an
        // older timestamp move the idle deadline backwards and reclaim a
        // resource while a newer activity has already protected it.
        if date > lastActivityAt {
            lastActivityAt = date
        }
        if resourceState == .idleEligible {
            idleReclaimTask?.cancel()
            idleReclaimTask = nil
            resourceState = .live
            notifyResourceStateChange()
        }
    }

    /// Mark whether an embedded tab is currently visible to the user. Visible
    /// tabs are never reclaimed, even if no agent lease is held.
    public func setUserVisible(_ visible: Bool) {
        guard resourceState != .closed else { return }
        isUserVisible = visible
        recordActivity()
        if visible {
            idleReclaimTask?.cancel()
            idleReclaimTask = nil
            if resourceState == .idleEligible {
                resourceState = .live
                notifyResourceStateChange()
            }
        } else if operationLeases.isEmpty, pendingRequestID == nil {
            markIdleEligible()
        }
    }

    /// Acquire an operation lease. Reclaimed resources are synchronously
    /// reopened before the lease is returned; concurrent callers on the main
    /// actor therefore share exactly one replacement WebView.
    public func acquireOperationLease() throws -> BrowserSessionOperationLease {
        guard resourceState != .closed else { throw BrowserError.resourceClosed }
        if resourceState == .reclaimed {
            performReopenResource()
        }
        if resourceState == .reopening {
            // `reopenResource` completes synchronously on the main actor. This
            // branch is defensive for future asynchronous WebKit setup.
            guard resourceState == .live else { throw BrowserError.resourceReclaimed }
        }
        idleReclaimTask?.cancel()
        idleReclaimTask = nil
        resourceState = .live
        recordActivity()
        let lease = BrowserSessionOperationLease(
            id: UUID(),
            scopeID: scope.id,
            generation: resourceGeneration
        )
        operationLeases.insert(lease.id)
        activeOperationCount = operationLeases.count
        notifyResourceStateChange()
        return lease
    }

    /// Release only a lease minted by this session. A late release from an old
    /// generation cannot release a newer operation or arm a foreign scope.
    public func releaseOperationLease(_ lease: BrowserSessionOperationLease) {
        guard lease.scopeID == scope.id,
              lease.generation == resourceGeneration,
              operationLeases.remove(lease.id) != nil
        else { return }
        activeOperationCount = operationLeases.count
        recordActivity()
        if operationLeases.isEmpty, !isUserVisible, pendingRequestID == nil {
            markIdleEligible()
        }
        notifyResourceStateChange()
    }

    /// Deterministically consume an expired idle watchdog. The optional date
    /// is used by tests and does not alter production timer behavior.
    @discardableResult
    public func reclaimIfIdle(at date: Date = Date()) -> Bool {
        guard resourceState == .idleEligible,
              !isUserVisible,
              operationLeases.isEmpty,
              pendingRequestID == nil,
              date.timeIntervalSince(lastActivityAt) >= TimeInterval(idleTimeoutMinutes * 60)
        else { return false }
        reclaimResource()
        return true
    }

    /// Reopen a reclaimed resource. This method is idempotent for a live tab
    /// and refuses an explicitly closed session.
    @discardableResult
    public func reopenResource() -> Bool {
        guard resourceState != .closed else { return false }
        guard resourceState == .reclaimed else { return false }
        performReopenResource()
        return true
    }

    /// Explicitly close this session. It invalidates all outstanding leases
    /// and generations, destroys all unspent write grants, detaches the old
    /// WebView, releases this session's registry reference (dropping the
    /// scoped data store when this was the last live session of the
    /// identity), and never reopens it.
    public func close() {
        if let transferID = pendingTransfer?.id { finishTransfer(.failure(BrowserTransferError.cancelled), expectedID: transferID) }
        preparedInteractions.removeAll()
        endInteractionNavigationWindow()
        guard resourceState != .closed else { return }
        sideEffectGrants.invalidate()
        idleReclaimTask?.cancel()
        idleReclaimTask = nil
        settlePendingNavigation(error: BrowserError.resourceClosed)
        operationLeases.removeAll()
        activeOperationCount = 0
        isUserVisible = false
        detach(webView)
        // Keep the historical non-optional property source-compatible while
        // dropping the actual page-bearing WebView held by this session.
        webView = makeWebView(frame: .zero, userAgent: nil)
        detach(webView)
        resourceGeneration &+= 1
        resourceState = .closed
        notifyResourceStateChange()
        // Release the registry slot last: the blank placeholder above still
        // re-binds the scoped store while the count is held, and once this
        // session is gone the slot (and its cookie/login state) is retired
        // together with the last live reference to the identity.
        releaseOwnedRegistrySlot()
    }

    /// Give back this session's registry reference exactly once. Repeated
    /// closes, sessions that never entered the registry (ephemeral or
    /// unverified scopes), and abandoned placeholders all release at most
    /// one count, so the slot can never be over-decremented while another
    /// live session still owns the identity.
    private func releaseOwnedRegistrySlot() {
        guard let key = registryLifecycleKey else { return }
        registryLifecycleKey = nil
        Self.releaseRegistrySlot(for: key)
    }

    private func markIdleEligible() {
        guard resourceState == .live,
              !isUserVisible,
              operationLeases.isEmpty,
              pendingRequestID == nil,
              interactionNavigationWindow == nil
        else { return }
        resourceState = .idleEligible
        notifyResourceStateChange()
        armIdleReclaimTimer()
    }

    private func armIdleReclaimTimer() {
        idleReclaimTask?.cancel()
        let generation = resourceGeneration
        let timeout = UInt64(idleTimeoutMinutes) * 60 * 1_000_000_000
        idleReclaimTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeout)
            } catch {
                return
            }
            guard let self else { return }
            guard self.resourceGeneration == generation else { return }
            _ = self.reclaimIfIdle()
        }
    }

    private func reclaimResource() {
        guard resourceState == .idleEligible,
              operationLeases.isEmpty,
              !isUserVisible,
              pendingRequestID == nil
        else { return }
        lastKnownURL = webView.url ?? lastKnownURL
        idleReclaimTask?.cancel()
        idleReclaimTask = nil
        detach(webView)
        resourceGeneration &+= 1
        // Keep the historical non-optional `webView` API source-compatible.
        // The blank replacement has no loaded page/content process; the next
        // operation swaps it for a fully configured resource.
        webView = makeWebView(frame: .zero, userAgent: configuredUserAgent)
        resourceState = .reclaimed
        notifyResourceStateChange()
    }

    private func performReopenResource() {
        guard resourceState == .reclaimed else { return }
        resourceState = .reopening
        notifyResourceStateChange()
        detach(webView)
        resourceGeneration &+= 1
        webView = makeWebView(frame: configuredFrame, userAgent: configuredUserAgent)
        if let viewport = configuredViewport {
            installViewport(width: viewport.width, height: viewport.height)
        }
        resourceState = .live
        recordActivity()
        notifyResourceStateChange()
    }

    private func makeWebView(frame: CGRect, userAgent: String?) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = Self.dataStore(for: scope)
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: frame, configuration: configuration)
        view.customUserAgent = userAgent
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = true
        view.navigationDelegate = self
        view.uiDelegate = self
        return view
    }

    private func detach(_ view: WKWebView) {
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.removeFromSuperview()
    }

    private func notifyResourceStateChange() {
        onResourceStateChange?(resourceState, resourceGeneration)
    }

    /// Main-actor callback for embedded consumers that need to replace their
    /// NSView when WebKit identity changes.
    public var onResourceStateChange: (@MainActor (BrowserSessionResourceState, UInt64) -> Void)?

    // MARK: - UA / Viewport（AJ-49 浏览器设置接入）

    /// 更新 `WKWebView.customUserAgent`（UA 预设/自定义切换后调用）。
    public func setUserAgent(_ userAgent: String) {
        configuredUserAgent = userAgent.isEmpty ? nil : userAgent
        webView.customUserAgent = configuredUserAgent
    }

    /// Install or revoke an explicit write grant. A grant for another scope
    /// remains present for observability but does not unlock any action.
    public func setWriteAuthorization(_ authorization: BrowserWriteAuthorization?) {
        writeAuthorization = authorization
    }

    /// Replace the navigation policy from the caller's existing authorization
    /// snapshot. This is a value replacement on the session actor, so a
    /// later resource generation cannot retain an old mutable policy object.
    public func setNavigationPolicy(_ policy: BrowserNavigationPolicy) {
        navigationPolicy = policy
    }

    /// Authorize one URL selected by an explicit user action (the App address
    /// bar uses this seam). Agent callers receive domains from their existing
    /// PolicyRuntime/GoalEnvelope instead of calling this with model data.
    @discardableResult
    public func authorizeNavigation(to url: URL) -> Bool {
        guard resourceState != .closed else { return false }
        return navigationPolicy.authorize(url)
    }

    /// Expose the same fenced decision used by the delegate for deterministic
    /// consumers and diagnostics. It never mutates the policy or starts a
    /// request.
    public func navigationDecision(
        for url: URL?,
        source: BrowserNavigationPolicy.Source,
        currentURL: URL? = nil,
        identity: BrowserSessionIdentity? = nil
    ) -> BrowserNavigationPolicy.Decision {
        guard resourceState == .live else { return .deny(.resourceUnavailable) }
        let expectedIdentity = identity ?? self.identity
        return navigationPolicy.decision(
            for: url,
            source: source,
            scopeID: expectedIdentity.scopeID,
            expectedScopeID: scope.id,
            generation: expectedIdentity.generation,
            expectedGeneration: resourceGeneration,
            currentURL: currentURL ?? trustedNavigationBaselineURL()
        )
    }

    /// 按 `width`/`height` 应用自定义视口：
    /// - 调整 webView 的 frame 尺寸（非嵌入式/无宿主窗口时生效）；
    /// - 注入 viewport-meta 覆盖脚本，强制页面 CSS 布局宽度为 `width`，
    ///   并设置 `preferredContentMode`（移动 UA → `.mobile`，否则 `.desktop`）。
    ///
    /// 内嵌到 SwiftUI 时 frame 由容器驱动，但 viewport-meta 覆盖与
    /// preferredContentMode 仍会决定页面按移动/桌面布局。
    public func applyViewport(width: Int, height: Int) {
        let viewportWidth = max(1, width)
        let h = CGFloat(max(1, height))
        configuredViewport = (width: viewportWidth, height: Int(h))
        installViewport(width: viewportWidth, height: Int(h))
    }

    private func installViewport(width viewportWidth: Int, height: Int) {
        let w = CGFloat(viewportWidth)
        let h = CGFloat(max(1, height))
        webView.setFrameSize(NSSize(width: w, height: h))

        let script = """
        (function() {
            var metas = document.querySelectorAll('meta[name="viewport"]');
            for (var i = 0; i < metas.length; i++) {
                metas[i].setAttribute('content', 'width=\(viewportWidth)');
            }
            if (!metas.length) {
                var m = document.createElement('meta');
                m.name = 'viewport';
                m.content = 'width=\(viewportWidth)';
                document.head.appendChild(m);
            }
        })();
        """
        let userScript = WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        webView.configuration.userContentController.removeAllUserScripts()
        webView.configuration.userContentController.addUserScript(userScript)

        // 移动 UA（宽 < 1024 → 窄视口）用移动布局，否则桌面布局。
        let isMobile = w < 1024
        webView.configuration.defaultWebpagePreferences.preferredContentMode = isMobile ? .mobile : .desktop
    }

    // MARK: - Navigation

    /// Navigate to `url` and wait until the page finishes loading (or fails).
    public func navigate(to url: URL) async throws {
        // Explicit Agent navigation is a new operation, never an effect of a prior click/type.
        endInteractionNavigationWindow()
        try requireNavigation(
            to: url,
            source: .initial,
            currentURL: trustedNavigationBaselineURL()
        )
        let timeout = navigationTimeout
        try await performNavigation(targetURL: url, source: .initial) { [webView] in
            webView.load(URLRequest(url: url, timeoutInterval: timeout))
        }
    }

    /// Load raw HTML into the view (tests / local previews). Waits for load.
    public func loadHTMLString(_ html: String, baseURL: URL? = nil) async throws {
        if let baseURL {
            try requireNavigation(
                to: baseURL,
                source: .initial,
                currentURL: trustedNavigationBaselineURL()
            )
        } else {
            try ensureResourceLive()
        }
        try await performNavigation(
            targetURL: baseURL,
            source: .initial,
            allowsLocalHTMLDocument: baseURL == nil
        ) { [webView] in
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    /// Navigate one step back in history (waits for the load to finish).
    @discardableResult
    public func goBack() async throws -> String {
        try ensureResourceLive()
        guard webView.canGoBack else { throw BrowserError.cannotGoBack }
        guard let targetURL = webView.backForwardList.backItem?.url else {
            throw BrowserError.navigationDenied(.missingURL)
        }
        try requireNavigation(
            to: targetURL,
            source: .backForward,
            currentURL: trustedNavigationBaselineURL()
        )
        try await performNavigation(targetURL: targetURL, source: .backForward) { [webView] in
            webView.goBack()
        }
        return "Navigated back to \(webView.url?.absoluteString ?? "unknown URL")"
    }

    /// Stop only the currently owned navigation and settle its await once.
    public func cancelNavigation() {
        guard resourceState != .closed else { return }
        guard let requestID = pendingRequestID else {
            webView.stopLoading()
            return
        }
        cancelNavigation(requestID: requestID)
    }

    @discardableResult
    public func goForward() async throws -> String {
        try ensureResourceLive()
        guard webView.canGoForward else { throw BrowserError.navigationFailed("Cannot go forward") }
        guard let targetURL = webView.backForwardList.forwardItem?.url else {
            throw BrowserError.navigationDenied(.missingURL)
        }
        try requireNavigation(
            to: targetURL,
            source: .backForward,
            currentURL: trustedNavigationBaselineURL()
        )
        try await performNavigation(targetURL: targetURL, source: .backForward) { [webView] in
            webView.goForward()
        }
        return "Navigated forward to \(webView.url?.absoluteString ?? "unknown URL")"
    }

    public func reload() async throws {
        try ensureResourceLive()
        guard let targetURL = webView.url ?? lastKnownURL else {
            throw BrowserError.noPageLoaded
        }
        try requireNavigation(
            to: targetURL,
            source: .reload,
            currentURL: trustedNavigationBaselineURL()
        )
        try await performNavigation(targetURL: targetURL, source: .reload) { [webView] in
            webView.reload()
        }
    }

    private func performNavigation(
        targetURL: URL?,
        source: BrowserNavigationPolicy.Source,
        allowsLocalHTMLDocument: Bool = false,
        _ start: @escaping () -> WKNavigation?
    ) async throws {
        try ensureResourceLive()
        recordActivity()
        let requestID = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if let previous = pendingRequestID {
                    settleNavigation(requestID: previous,
                        error: BrowserError.navigationFailed("superseded by a newer navigation"),
                        stopLoading: true)
                }
                pendingRequestID = requestID
                pendingNavigation = continuation
                pendingNavigationBaselineURL = targetURL ?? trustedNavigationBaselineURL()
                pendingNavigationSource = source
                pendingLocalHTMLDocumentRequest = allowsLocalHTMLDocument
                pendingLocalHTMLDocumentURL = nil
                activeNavigation = start()
                // A policy delegate can synchronously cancel during `start`.
                // Do not let that callback leave a late navigation handle
                // attached after its continuation has already been settled.
                guard pendingRequestID == requestID else {
                    activeNavigation = nil
                    return
                }
                guard activeNavigation != nil else {
                    settleNavigation(requestID: requestID,
                        error: BrowserError.navigationFailed("WebKit did not create a navigation"),
                        stopLoading: true)
                    return
                }
                let timeout = navigationTimeout
                // Bind the error URL before either WebKit or our watchdog settles.
                // A provisional view may still expose nil or the previous page URL.
                let timeoutTargetURL = pendingNavigationBaselineURL
                    ?? webView.url ?? URL(string: "about:blank")!
                navigationTimeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    } catch { return }
                    guard let self, !Task.isCancelled else { return }
                    self.settleNavigation(requestID: requestID,
                        error: BrowserError.navigationTimeout(timeoutTargetURL),
                        stopLoading: true)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelNavigation(requestID: requestID)
            }
        }
    }

    private func cancelNavigation(requestID: UUID) {
        settleNavigation(requestID: requestID, error: CancellationError(), stopLoading: true)
    }

    private func settlePendingNavigation(error: Error) {
        guard let requestID = pendingRequestID else {
            pendingNavigation?.resume(throwing: error)
            pendingNavigation = nil
            activeNavigation = nil
            pendingNavigationBaselineURL = nil
            pendingNavigationSource = nil
            pendingLocalHTMLDocumentRequest = false
            pendingLocalHTMLDocumentURL = nil
            navigationTimeoutTask?.cancel()
            navigationTimeoutTask = nil
            return
        }
        settleNavigation(requestID: requestID, error: error, stopLoading: true)
    }

    private func requireNavigation(
        to url: URL,
        source: BrowserNavigationPolicy.Source,
        currentURL: URL?
    ) throws {
        guard resourceState != .closed else { throw BrowserError.resourceClosed }
        // Reject an unauthorized request before reopening an idle resource or
        // calling any WebKit load method. A permitted reclaimed request is
        // re-evaluated below after the generation rotates.
        let preflight = navigationPolicy.decision(
            for: url,
            source: source,
            scopeID: scope.id,
            expectedScopeID: scope.id,
            generation: resourceGeneration,
            expectedGeneration: resourceGeneration,
            currentURL: currentURL
        )
        if case .deny(let denial) = preflight {
            throw BrowserError.navigationDenied(denial)
        }
        try ensureResourceLive()
        let decision = navigationPolicy.decision(
            for: url,
            source: source,
            scopeID: scope.id,
            expectedScopeID: scope.id,
            generation: resourceGeneration,
            expectedGeneration: resourceGeneration,
            currentURL: trustedNavigationBaselineURL()
        )
        if case .deny(let denial) = decision {
            throw BrowserError.navigationDenied(denial)
        }
    }

    /// Capture only a URL that was accepted by the current policy. A mutable
    /// WebKit URL is intentionally not used while an untrusted redirect is in
    /// flight, because doing so would let the redirect become its own origin.
    private func trustedNavigationBaselineURL() -> URL? {
        pendingNavigationBaselineURL ?? lastKnownURL
    }

    private func ensureResourceLive() throws {
        guard resourceState != .closed else { throw BrowserError.resourceClosed }
        if resourceState == .idleEligible {
            recordActivity()
        }
        if resourceState == .reclaimed {
            performReopenResource()
        }
        guard resourceState == .live else { throw BrowserError.resourceReclaimed }
    }

    private func settleNavigation(requestID: UUID, error: Error?, stopLoading: Bool) {
        guard pendingRequestID == requestID, let continuation = pendingNavigation else { return }
        pendingRequestID = nil
        pendingNavigation = nil
        activeNavigation = nil
        pendingNavigationBaselineURL = nil
        pendingNavigationSource = nil
        pendingLocalHTMLDocumentRequest = false
        pendingLocalHTMLDocumentURL = nil
        navigationTimeoutTask?.cancel()
        navigationTimeoutTask = nil
        // Clear ownership before stopping WebKit: a synchronous or queued
        // cancellation delegate callback cannot complete another request.
        if stopLoading { webView.stopLoading() }
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
    }

    private func finishNavigation(from source: WKWebView, navigation: WKNavigation?, error: Error?) {
        guard source === webView, let navigation, let activeNavigation,
              navigation === activeNavigation,
              let requestID = pendingRequestID,
              pendingNavigation != nil else { return }
        // Normalize only after the original view/navigation/request ownership gate.
        // Native and owned-watchdog timeouts have the same public error contract.
        let settlementError: Error?
        if let error {
            let native = error as NSError
            if native.domain == NSURLErrorDomain && native.code == NSURLErrorTimedOut {
                settlementError = BrowserError.navigationTimeout(
                    pendingNavigationBaselineURL ?? source.url ?? URL(string: "about:blank")!
                )
            } else {
                settlementError = BrowserError.navigationFailed(error.localizedDescription)
            }
        } else {
            settlementError = nil
        }
        if error == nil {
            var decision = policyDecision(from: source, url: source.url, source: .response)
            if let terminalLocalDocumentDecision = Self.pendingLocalHTMLTerminalDocumentDecision(
                for: source.url,
                baseDecision: decision,
                terminalRequestID: requestID,
                activeRequestID: pendingRequestID,
                hasPendingContinuation: pendingNavigation != nil,
                sourceIsOwner: source === webView,
                navigationMatchesActive: navigation === activeNavigation,
                requestIsPending: pendingLocalHTMLDocumentRequest,
                allowsLocalContent: navigationPolicy.allowsLocalContent,
                pendingNavigationSource: pendingNavigationSource,
                resourceIsLive: resourceState == .live,
                boundIdentity: pendingLocalHTMLDocumentURL
            ) {
                decision = terminalLocalDocumentDecision
                pendingLocalHTMLDocumentURL = source.url
            }
            if case .deny(let denial) = decision {
                settleNavigation(
                    requestID: requestID,
                    error: BrowserError.navigationDenied(denial),
                    stopLoading: true
                )
                return
            }
        }
        lastKnownURL = source.url ?? lastKnownURL
        settleNavigation(requestID: requestID, error: settlementError, stopLoading: false)
    }

    // MARK: - Page info

    /// The currently loaded URL (nil before any navigation).
    /// A URL observed during a rejected redirect is not trusted until the
    /// response policy and terminal callback both accept it.
    public func currentURL() -> URL? { lastKnownURL ?? webView.url }

    /// The current page title (may be empty before load).
    public func pageTitle() -> String { webView.title ?? "" }

    // MARK: - JavaScript

    /// Execute `script` and return the result as text. Results are coerced:
    /// strings pass through, numbers are stringified, everything else is
    /// JSON-encoded (or `"null"` when the result is nil/undefined).
    public func executeJavaScript(_ script: String) async throws -> String {
        try ensureResourceLive()
        recordActivity()
        let expectedIdentity = identity
        let result: Any?
        do {
            result = try await webView.evaluateJavaScript(script)
        } catch {
            throw BrowserError.javascriptFailed(error.localizedDescription)
        }
        guard accepts(expectedIdentity) else { throw BrowserError.staleResult }
        return Self.stringify(result)
    }

    /// Browser-owned DOM fact extraction uses WebKit's isolated client world;
    /// page scripts cannot replace the standard prototype property getters.
    func isolatedInteractionFacts(_ script: String) async throws -> String {
        try ensureResourceLive()
        let expected = identity
        let result = try await webView.callAsyncJavaScript("return " + script, arguments: [:], in: nil, contentWorld: .defaultClient)
        guard accepts(expected) else { throw BrowserError.staleResult }
        return Self.stringify(result)
    }

    /// Run an async-JS body via `callAsyncJavaScript` (modern pages / promises).
    public func callAsyncJavaScript(_ body: String, arguments: [String: Any] = [:]) async throws -> String {
        try ensureResourceLive()
        recordActivity()
        let expectedIdentity = identity
        let result: Any?
        do {
            result = try await webView.callAsyncJavaScript(body, arguments: arguments, contentWorld: .page)
        } catch {
            throw BrowserError.javascriptFailed(error.localizedDescription)
        }
        guard accepts(expectedIdentity) else { throw BrowserError.staleResult }
        return Self.stringify(result)
    }

    /// Best-effort JSON/string coercion of a JS return value.
    private static func stringify(_ value: Any?) -> String {
        guard let value else { return "null" }
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        if let d = value as? Double { return String(d) }
        if let b = value as? Bool { return String(b) }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(describing: value)
    }

    // MARK: - Text extraction

    /// Extract the page's visible text. With a `selector`, only that element's
    /// text is returned (throwing when the element does not exist).
    public func textContent(selector: String? = nil) async throws -> String {
        let js: String
        if let selector {
            let q = Self.jsQuote(selector)
            js = """
            (function() {
                var el = document.querySelector('\(q)');
                if (!el) return JSON.stringify({ error: 'Element not found: \(q)' });
                return JSON.stringify({ text: (el.innerText || el.textContent || '').replace(/\\s+/g, ' ').trim() });
            })()
            """
        } else {
            js = """
            (function() {
                var body = document.body;
                if (!body) return JSON.stringify({ text: '' });
                return JSON.stringify({ text: body.innerText.replace(/\\s+/g, ' ').trim() });
            })()
            """
        }
        let raw = try await executeJavaScript(js)
        guard let data = raw.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BrowserError.textExtractionFailed("Unexpected JS result: \(raw.prefix(200))")
        }
        if let error = dict["error"] as? String {
            throw BrowserError.textExtractionFailed(error)
        }
        return dict["text"] as? String ?? ""
    }

    // MARK: - Interaction (click / type)

    /// Click the first element matching `selector` (synthesized mouse events).
    /// A read-only session may still perform this side effect exactly once
    /// when an approved one-shot grant for `click` exists (D-BROWSER-07).
    public func click(selector: String) async throws -> String {
        guard !isReadOnly || consumeApprovedSideEffectGrant(for: "click") else {
            throw BrowserError.writeAuthorizationRequired("click")
        }
        let review = try await takeInteractionReview(action: "click", selector: selector)
        if let review {
            beginInteractionNavigationWindow(action: "click")
            if let url = review.target.submissionURL {
                interactionNavigationPermit = (url, Date().addingTimeInterval(5))
            }
        }
        let q = Self.jsQuote(selector)
        let js = """
        (function() {
            var el = document.querySelector('\(q)');
            if (!el) return JSON.stringify({ error: 'Element not found' });
            \(interactionEffectGuard(review))
            el.scrollIntoView({ block: 'center', behavior: 'instant' });
            var opts = { bubbles: true, cancelable: true, view: window };
            el.dispatchEvent(new MouseEvent('mouseover', opts));
            el.dispatchEvent(new MouseEvent('mousedown', opts));
            el.dispatchEvent(new MouseEvent('mouseup', opts));
            el.click();
            return JSON.stringify({ clicked: true, tag: el.tagName, text: (el.innerText || '').substring(0, 100) });
        })()
        """
        let raw = try await executeJavaScript(js)
        guard let data = raw.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BrowserError.javascriptFailed("click: unexpected JS result: \(raw.prefix(200))")
        }
        if dict["error"] is String {
            throw BrowserError.javascriptFailed("click: target action failed")
        }
        recordAutomaticInteractionCompletion(review, action: "click")
        if let notice = review?.notice {
            var result = dict
            result["authorizationNotice"] = notice
            return String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
        }
        return raw
    }

    /// Focus the element at `selector` and set its value, simulating key input.
    /// Like `click`, a read-only session may perform this side effect exactly
    /// once when an approved one-shot grant for `type` exists.
    public func type(selector: String, text: String) async throws -> String {
        guard !isReadOnly || consumeApprovedSideEffectGrant(for: "type") else {
            throw BrowserError.writeAuthorizationRequired("type")
        }
        let review = try await takeInteractionReview(action: "type", selector: selector)
        if review != nil { beginInteractionNavigationWindow(action: "type") }
        let q = Self.jsQuote(selector)
        let t = Self.jsQuote(text)
        let js = """
        (function() {
            var el = document.querySelector('\(q)');
            if (!el) return JSON.stringify({ error: 'Element not found' });
            \(interactionEffectGuard(review))
            el.focus();
            if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') {
                var proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
                var setter = Object.getOwnPropertyDescriptor(proto, 'value');
                if (setter && setter.set) { setter.set.call(el, '\(t)'); } else { el.value = '\(t)'; }
            } else {
                el.innerText = '\(t)';
            }
            var chars = '\(t)';
            for (var i = 0; i < chars.length; i++) {
                el.dispatchEvent(new KeyboardEvent('keydown', { key: chars[i], bubbles: true }));
                el.dispatchEvent(new KeyboardEvent('keypress', { key: chars[i], bubbles: true }));
                el.dispatchEvent(new InputEvent('input', { data: chars[i], inputType: 'insertText', bubbles: true }));
                el.dispatchEvent(new KeyboardEvent('keyup', { key: chars[i], bubbles: true }));
            }
            el.dispatchEvent(new Event('change', { bubbles: true }));
            return JSON.stringify({ typed: true, length: chars.length });
        })()
        """
        let raw = try await executeJavaScript(js)
        guard let data = raw.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BrowserError.javascriptFailed("type: unexpected JS result: \(raw.prefix(200))")
        }
        if dict["error"] is String {
            throw BrowserError.javascriptFailed("type: target action failed")
        }
        recordAutomaticInteractionCompletion(review, action: "type")
        if let notice = review?.notice {
            var result = dict
            result["authorizationNotice"] = notice
            return String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
        }
        return raw
    }

    /// One exact file, one human browser approval and one existing file-policy
    /// check. Transfers deliberately never use persistent site/category rules.
    public func transfer(action: String, selector: String) async throws -> String {
        guard ["upload", "download"].contains(action), pendingTransfer == nil,
              requiresInteractionReview,
              let fileAccess = BrowserTransferFileAccessContext.current ?? transferFileAccess else {
            throw BrowserTransferError.unavailable
        }
        guard !isReadOnly || consumeApprovedSideEffectGrant(for: action) else {
            throw BrowserInteractionError.missingApproval
        }
        // Reserve synchronously before the first await. Review may suspend on
        // live actor policy or disk IO; another call must not replace this slot.
        let id = UUID()
        pendingTransfer = PendingBrowserTransfer(id: id, fileAccess: fileAccess)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard pendingTransfer?.id == id, !Task.isCancelled else {
                    if pendingTransfer?.id == id { pendingTransfer = nil }
                    continuation.resume(throwing: BrowserTransferError.cancelled); return
                }
                pendingTransfer?.continuation = continuation
                pendingTransfer?.operationTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        guard let review = try await self.takeInteractionReview(action: action, selector: selector),
                              review.target.transferFile != nil else { throw BrowserInteractionError.missingApproval }
                        try Task.checkCancellation()
                        guard self.pendingTransfer?.id == id else { throw BrowserTransferError.cancelled }
                        self.pendingTransfer?.target = review.target
                        let current = try await self.interactionTarget(review.target.input, fileAccess: fileAccess)
                        guard self.pendingTransfer?.id == id, current == review.target else { throw BrowserInteractionError.changedTarget }
                        if action == "download" {
                            guard let raw = review.target.submissionURL, let url = URL(string: raw),
                                  self.navigationDecision(for: url, source: .action).isAllowed else { throw BrowserTransferError.prohibitedTarget }
                            var request = URLRequest(url: url)
                            request.httpMethod = "GET"
                            self.webView.startDownload(using: request) { [weak self] download in
                                guard let self, self.pendingTransfer?.id == id else { download.cancel { _ in }; return }
                                self.pendingTransfer?.download = download
                                download.delegate = self
                            }
                        } else {
                            try await self.performNativeFormUpload(review.target, fileAccess: fileAccess, operationID: id)
                        }
                    } catch { self.finishTransfer(.failure(error), expectedID: id) }
                }
                pendingTransfer?.timeoutTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    self?.finishTransfer(.failure(BrowserTransferError.failed), expectedID: id)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishTransfer(.failure(BrowserTransferError.cancelled), expectedID: id) }
        }
    }

    private func performNativeFormUpload(_ target: BrowserInteractionTarget, fileAccess: @escaping BrowserTransferFileAccess,
                                         operationID: UUID) async throws {
        guard let file = target.transferFile, let field = target.uploadFieldName,
              let raw = target.submissionURL, let endpoint = URL(string: raw),
              BrowserNavigationPolicy.sameOrigin(endpoint, target.origin),
              navigationDecision(for: endpoint, source: .action).isAllowed else { throw BrowserTransferError.prohibitedTarget }
        let artifact = try await BrowserNativeFormUpload.prepare(file: file, fieldName: field)
        guard pendingTransfer?.id == operationID else {
            try await artifact.remove(); throw BrowserTransferError.cancelled
        }
        pendingTransfer?.stagingURL = artifact.url
        let result: Result<Int, Error>
        do {
            let latest = try await interactionTarget(target.input, fileAccess: fileAccess)
            guard pendingTransfer?.id == operationID, latest == target else { throw BrowserInteractionError.changedTarget }
            // The native transport never puts File objects in the page. It has
            // no page script/service-worker execution, cookies or credential store.
            result = .success(try await BrowserNativeFormUpload(endpoint: endpoint, origin: target.origin).send(artifact))
        } catch { result = .failure(error) }
        do { try await artifact.remove() }
        catch { finishTransfer(.failure(error), expectedID: operationID); return }
        guard pendingTransfer?.id == operationID else { return }
        pendingTransfer?.stagingURL = nil
        switch result {
        case .success(let status): finishTransfer(.success("Approved same-origin multipart POST completed with HTTP \(status); no file was exposed to page JavaScript."), expectedID: operationID)
        case .failure(let error): throw error
        }
    }

    private func finishTransfer(_ result: Result<String, Error>, expectedID: UUID) {
        guard let pending = pendingTransfer, pending.id == expectedID else { return }
        pendingTransfer = nil
        pending.timeoutTask?.cancel()
        if case .failure(let error) = result {
            pending.operationTask?.cancel()
            pending.download?.cancel { _ in }
            let cancelled = error is CancellationError || (error as? BrowserTransferError).map { if case .cancelled = $0 { true } else { false } } == true
            let code: String
            switch error {
            case BrowserInteractionError.missingApproval: code = "missing_approval"
            case BrowserInteractionError.changedTarget: code = "changed_target"
            case BrowserTransferError.changedFile: code = "changed_file"
            case BrowserTransferError.filePermissionRequired: code = "file_permission_required"
            default: code = cancelled ? "transfer_cancelled" : "transfer_failed"
            }
            let existing = error as? BrowserTransferFailure
            pending.continuation?.resume(throwing: BrowserTransferFailure(cancelled: cancelled || existing?.cancelled == true,
                partialOutputPath: pending.stagingURL?.path ?? existing?.partialOutputPath, code: existing?.code ?? code))
        } else { pending.continuation?.resume(with: result) }
    }

    // MARK: - Screenshot

    /// Capture the visible viewport and save it as JPEG under `directory`
    /// (defaults to the system temp dir). Returns the saved file path.
    ///
    /// Note: `takeSnapshot` renders the WebView's layer, so it requires the
    /// view to be attached to a window (or the AppKit server available).
    /// Headless CI without a GUI session may fail here — callers should treat
    /// screenshot as best-effort.
    public func screenshot(directory: URL = FileManager.default.temporaryDirectory) async throws -> String {
        try ensureResourceLive()
        recordActivity()
        let expectedIdentity = identity
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        let image: NSImage
        do {
            image = try await webView.takeSnapshot(configuration: configuration)
        } catch {
            throw BrowserError.screenshotFailed(error.localizedDescription)
        }
        guard accepts(expectedIdentity) else { throw BrowserError.staleResult }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw BrowserError.screenshotFailed("Could not encode snapshot as JPEG")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 清理超过 1 小时的旧截图临时文件（只动本功能命名的 browser_*.jpg）。
        if let stale = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let cutoff = Date().addingTimeInterval(-3600)
            for file in stale where file.lastPathComponent.hasPrefix("browser_") && file.pathExtension == "jpg" {
                if let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                   modified < cutoff {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
        let filename = "browser_\(Int(Date().timeIntervalSince1970 * 1000)).jpg"
        let fileURL = directory.appendingPathComponent(filename)
        do {
            try jpeg.write(to: fileURL)
        } catch {
            throw BrowserError.screenshotFailed(error.localizedDescription)
        }
        return fileURL.path
    }

    // MARK: - JS escaping

    /// Escape a string for safe embedding inside a single-quoted JS literal.
    private static func jsQuote(_ s: String) -> String {
        var result = ""
        for ch in s {
            switch ch {
            case "\\": result += "\\\\"
            case "'": result += "\\'"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default: result.append(ch)
            }
        }
        return result
    }
}

// MARK: - WKNavigationDelegate

extension BrowserSession: WKNavigationDelegate {
    /// Decide every main-frame/action request before WebKit is allowed to
    /// dispatch it. The handler is called exactly once on every branch.
    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        // A callback from an idle-reclaimed or replaced resource must not
        // settle the current generation's pending navigation.
        guard webView === self.webView else {
            decisionHandler(.cancel)
            return
        }
        let source: BrowserNavigationPolicy.Source
        if navigationAction.targetFrame == nil {
            source = .newWindow
        } else {
            switch navigationAction.navigationType {
            case .backForward:
                source = .backForward
            case .reload:
                source = .reload
            case .linkActivated, .formSubmitted, .formResubmitted, .other:
                source = .action
            @unknown default:
                source = .action
            }
        }
        let navigationDecision = policyDecision(
            from: webView,
            url: navigationAction.request.url,
            source: source
        )
        if interactionNavigationWindow?.action == "type", pendingNavigationSource == nil,
           let url = navigationAction.request.url,
           url.query != nil || url.fragment != nil || url.user != nil || url.password != nil {
            decisionHandler(.cancel)
            rejectPendingNavigation(.formSubmissionNotAuthorized)
            return
        }
        let permit = interactionNavigationPermit
        let requestedURL = navigationAction.request.url?.absoluteString
        let approvedForm = permit.map { $0.expiresAt > Date() && $0.url == requestedURL } == true
            && navigationAction.navigationType == .formSubmitted
            && navigationAction.request.httpMethod?.uppercased() == "POST"
            && !navigationAction.shouldPerformDownload
        interactionNavigationPermit = nil
        let decision = approvedForm && navigationDecision.isAllowed ? navigationDecision : Self.navigationActionDecision(
            navigationDecision: navigationDecision,
            navigationType: navigationAction.navigationType,
            httpMethod: navigationAction.request.httpMethod,
            actionRequestsDownload: navigationAction.shouldPerformDownload,
            allowsLocalBootstrapWithoutMethod: pendingLocalHTMLDocumentRequest
                && pendingNavigationSource == .initial
                && navigationAction.request.url.map(Self.isLocalHTMLDocumentURL) == true
        )
        if decision.isAllowed {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            rejectPendingNavigation(decision.denial)
        }
    }

    /// Response policy is a second guard for redirects. It evaluates the
    /// response against the pre-load trusted baseline, never against a URL
    /// already mutated by an untrusted redirect.
    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        guard webView === self.webView else {
            decisionHandler(.cancel)
            return
        }
        let navigationDecision = policyDecision(
            from: webView,
            url: navigationResponse.response.url,
            source: .response
        )
        let headers = (navigationResponse.response as? HTTPURLResponse)?.allHeaderFields ?? [:]
        let disposition = headers.first {
            ($0.key as? String)?.caseInsensitiveCompare("Content-Disposition") == .orderedSame
        }?.value as? String
        let decision = navigationDecision.isAllowed
            ? Self.downloadDecision(
                responseCanShowMIMEType: navigationResponse.canShowMIMEType,
                contentDisposition: disposition
            )
            : navigationDecision
        if decision.isAllowed {
            if pendingNavigation == nil, interactionActiveNavigation != nil,
               interactionNavigationWindow?.identity == identity, navigationResponse.isForMainFrame {
                interactionResponseURL = navigationResponse.response.url
            }
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            rejectPendingNavigation(decision.denial)
        }
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if webView === self.webView, pendingNavigation == nil,
           interactionNavigationWindow?.identity == identity, interactionActiveNavigation == nil {
            interactionActiveNavigation = navigation
        }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === self.webView {
            if let navigation, navigation === interactionActiveNavigation,
               interactionNavigationWindow?.identity == identity,
               interactionResponseURL == webView.url,
               policyDecision(from: webView, url: webView.url, source: .response).isAllowed {
                lastKnownURL = webView.url
            }
            if let navigation, navigation === interactionActiveNavigation { endInteractionNavigationWindow() }
        }
        finishNavigation(from: webView, navigation: navigation, error: nil)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if webView === self.webView, let navigation, navigation === interactionActiveNavigation {
            endInteractionNavigationWindow()
        }
        finishNavigation(from: webView, navigation: navigation, error: error)
    }

    /// Keep a redirect callback bound to the current WebKit navigation. The
    /// action/response policy handlers are the pre-request gates; this callback
    /// is a late defensive stop when WebKit reports a server redirect without
    /// exposing a separate action URL.
    public func webView(
        _ webView: WKWebView,
        didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!
    ) {
        guard webView === self.webView,
              let navigation,
              let activeNavigation,
              navigation === activeNavigation,
              let redirectedURL = webView.url else { return }
        let decision = policyDecision(
            from: webView,
            url: redirectedURL,
            source: .redirect
        )
        if case .deny(let denial) = decision {
            rejectPendingNavigation(denial)
        }
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if webView === self.webView, let navigation, navigation === interactionActiveNavigation {
            endInteractionNavigationWindow()
        }
        finishNavigation(from: webView, navigation: navigation, error: error)
    }

    /// No download capability is exposed by this scoped browser. If WebKit
    /// starts one despite the action/response policy gates, cancel it before
    /// assigning a destination or forwarding any data to another session.
    public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.cancel { _ in }
        guard webView === self.webView else { return }
        rejectPendingNavigation(.downloadNotAuthorized)
    }

    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.cancel { _ in }
        guard webView === self.webView else { return }
        rejectPendingNavigation(.downloadNotAuthorized)
    }

    /// Pure pre-download guard shared by the WebKit action and response
    /// callbacks. Inline displayable content remains a normal navigation;
    /// download attributes, attachment headers, and non-displayable MIME do
    /// not become an implicit filesystem write.
    nonisolated static func downloadDecision(
        actionRequestsDownload: Bool = false,
        responseCanShowMIMEType: Bool = true,
        contentDisposition: String? = nil
    ) -> BrowserNavigationPolicy.Decision {
        let disposition = contentDisposition?
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !actionRequestsDownload,
              responseCanShowMIMEType,
              disposition != "attachment" else {
            return .deny(.downloadNotAuthorized)
        }
        return .allow
    }

    /// A navigation URL can be authorized without authorizing a write to that
    /// URL. WebKit reports form submissions here, including submissions made
    /// by page script during an otherwise read-only navigation. Only GET and
    /// HEAD proceed through the existing URL/download policy; an unknown or
    /// mutating method fails closed before WebKit may continue the navigation.
    /// This delegate does not observe fetch/XHR or other subresource traffic.
    nonisolated static func navigationActionDecision(
        navigationDecision: BrowserNavigationPolicy.Decision,
        navigationType: WKNavigationType,
        httpMethod: String?,
        actionRequestsDownload: Bool,
        allowsLocalBootstrapWithoutMethod: Bool = false
    ) -> BrowserNavigationPolicy.Decision {
        guard navigationDecision.isAllowed else { return navigationDecision }
        let method = httpMethod?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        if method == nil {
            // WebKit leaves URLRequest.httpMethod unset for ordinary links and
            // browser-owned history/reload actions. Those navigation types are
            // implicit GETs; keep script/unknown navigation types fail-closed.
            switch navigationType {
            case .linkActivated, .backForward, .reload:
                return downloadDecision(actionRequestsDownload: actionRequestsDownload)
            default:
                break
            }
            if allowsLocalBootstrapWithoutMethod {
                return downloadDecision(actionRequestsDownload: actionRequestsDownload)
            }
        }
        guard method == "GET" || method == "HEAD" else {
            switch navigationType {
            case .formSubmitted, .formResubmitted:
                return .deny(.formSubmissionNotAuthorized)
            default:
                return .deny(.requestMethodNotAuthorized)
            }
        }
        return downloadDecision(actionRequestsDownload: actionRequestsDownload)
    }

    private func policyDecision(
        from source: WKWebView,
        url: URL?,
        source navigationSource: BrowserNavigationPolicy.Source
    ) -> BrowserNavigationPolicy.Decision {
        guard source === self.webView, resourceState == .live else {
            return .deny(.resourceUnavailable)
        }
        let decision = navigationPolicy.decision(
            for: url,
            source: navigationSource,
            scopeID: scope.id,
            expectedScopeID: scope.id,
            generation: resourceGeneration,
            expectedGeneration: resourceGeneration,
            currentURL: pendingNavigationBaselineURL ?? lastKnownURL
        )
        guard let localDocumentDecision = Self.pendingLocalHTMLDocumentDecision(
            for: url,
            baseDecision: decision,
            requestIsPending: pendingLocalHTMLDocumentRequest,
            allowsLocalContent: navigationPolicy.allowsLocalContent,
            pendingNavigationSource: pendingNavigationSource,
            callbackSource: navigationSource,
            boundIdentity: pendingLocalHTMLDocumentURL
        ) else {
            return decision
        }
        guard localDocumentDecision.isAllowed else { return localDocumentDecision }

        if pendingLocalHTMLDocumentURL == nil {
            pendingLocalHTMLDocumentURL = url
        }
        return .allow
    }

    /// Permit the two exact URL identities WebKit uses for nil-baseURL HTML
    /// documents only while their owning local HTML request is still pending.
    /// The pure decision helper is internal so policy tests can cover the
    /// boundary without starting WebKit.
    nonisolated static func pendingLocalHTMLDocumentDecision(
        for url: URL?,
        baseDecision: BrowserNavigationPolicy.Decision,
        requestIsPending: Bool,
        allowsLocalContent: Bool,
        pendingNavigationSource: BrowserNavigationPolicy.Source?,
        callbackSource: BrowserNavigationPolicy.Source,
        boundIdentity: URL? = nil
    ) -> BrowserNavigationPolicy.Decision? {
        guard requestIsPending,
              callbackSource != .newWindow,
              baseDecision == .allow || baseDecision == .deny(.unsupportedScheme),
              let url,
              url.scheme?.lowercased() == "about" else {
            return nil
        }

        guard allowsLocalContent,
              pendingNavigationSource == .initial,
              isLocalHTMLDocumentURL(url) else {
            return .deny(.unsupportedScheme)
        }
        if let boundIdentity, boundIdentity != url {
            return .deny(.unsupportedScheme)
        }
        return .allow
    }

    /// The only exception for WebKit's normalized `about:` local-document URL.
    /// Call this after `finishNavigation` has verified the source web view and
    /// active WKNavigation; generic action/response/redirect policy callbacks
    /// must continue to use `pendingLocalHTMLDocumentDecision` above.
    nonisolated static func pendingLocalHTMLTerminalDocumentDecision(
        for url: URL?,
        baseDecision: BrowserNavigationPolicy.Decision,
        terminalRequestID: UUID?,
        activeRequestID: UUID?,
        hasPendingContinuation: Bool,
        sourceIsOwner: Bool,
        navigationMatchesActive: Bool,
        requestIsPending: Bool,
        allowsLocalContent: Bool,
        pendingNavigationSource: BrowserNavigationPolicy.Source?,
        resourceIsLive: Bool,
        boundIdentity: URL? = nil
    ) -> BrowserNavigationPolicy.Decision? {
        guard baseDecision == .deny(.unsupportedScheme),
              let terminalRequestID,
              activeRequestID == terminalRequestID,
              hasPendingContinuation,
              sourceIsOwner,
              navigationMatchesActive,
              requestIsPending,
              allowsLocalContent,
              pendingNavigationSource == .initial,
              resourceIsLive,
              let url,
              isNormalizedLocalHTMLAboutEmptyPathURL(url),
              boundIdentity == nil || boundIdentity == url else {
            return nil
        }
        return .allow
    }

    nonisolated private static func isNormalizedLocalHTMLAboutEmptyPathURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "about"
            && url.host == nil
            && url.path.isEmpty
            && url.query == nil
            && url.fragment == nil
    }

    nonisolated private static func isLocalHTMLDocumentURL(_ url: URL) -> Bool {
        // WebKit's NSURL-backed opaque URLs can report an empty `path` for
        // `about:blank`. Match the same two document identities themselves;
        // this does not authorize another scheme or another about document.
        return url.scheme?.lowercased() == "about"
            && url.host == nil
            && ["about:blank", "about:srcdoc"].contains(url.absoluteString.lowercased())
            && url.query == nil
            && url.fragment == nil
    }

    private func rejectPendingNavigation(_ denial: BrowserNavigationPolicy.Denial?) {
        guard let denial, let requestID = pendingRequestID else { return }
        settleNavigation(
            requestID: requestID,
            error: BrowserError.navigationDenied(denial),
            stopLoading: true
        )
    }
}

// MARK: - WKUIDelegate

extension BrowserSession: WKUIDelegate {
    /// Native approved multipart POST is the only upload path. A page cannot
    /// obtain an approved FileList or trigger onchange/fetch with file bytes.
    public func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                        initiatedByFrame frame: WKFrameInfo,
                        completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) {
        completionHandler(nil)
    }

    /// The browser owns one scoped WebView. A page cannot create a second
    /// window/resource; the same policy rejection is surfaced to the pending
    /// operation and no replacement WebView is returned.
    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard webView === self.webView else { return nil }
        let decision = policyDecision(
            from: webView,
            url: navigationAction.request.url,
            source: .newWindow
        )
        if case .deny(let denial) = decision {
            rejectPendingNavigation(denial)
        }
        return nil
    }
}


extension BrowserSession: WKDownloadDelegate {
    public func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                         suggestedFilename: String, completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        Task { @MainActor [weak self] in
            guard let self else { completionHandler(nil); return }
            await self.resolveDownloadDestination(download, response: response, completionHandler: completionHandler)
        }
    }

    private func resolveDownloadDestination(_ download: WKDownload, response: URLResponse,
                                            completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) async {
        guard let pending = pendingTransfer, pending.download === download, let target = pending.target else { completionHandler(nil); return }
        guard accepts(target.identity), currentURL()?.absoluteString == target.pageURL,
              let file = target.transferFile,
              let url = response.url, BrowserNavigationPolicy.sameOrigin(url, target.origin),
              navigationDecision(for: url, source: .response).isAllowed else { completionHandler(nil); finishTransfer(.failure(BrowserTransferError.prohibitedTarget), expectedID: pending.id); return }
        do {
            let staging = URL(fileURLWithPath: file.path).deletingLastPathComponent()
                .appendingPathComponent(".browser-transfer-" + pending.id.uuidString)
            try BrowserTransferFileIdentity.validateFloor(staging, upload: false)
            try await pending.fileAccess("file_write", staging)
            let current = try await BrowserTransferFileIdentity.capture(path: file.path, upload: false, access: pending.fileAccess)
            guard pendingTransfer?.id == pending.id, accepts(target.identity),
                  currentURL()?.absoluteString == target.pageURL, current == file else {
                throw BrowserTransferError.changedFile
            }
            pendingTransfer?.stagingURL = staging
            completionHandler(staging)
        } catch { completionHandler(nil); finishTransfer(.failure(error), expectedID: pending.id) }
    }

    public func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse,
                         newRequest request: URLRequest, decisionHandler: @escaping @MainActor @Sendable (WKDownload.RedirectPolicy) -> Void) {
        // Every redirect is denied: the human reviewed one exact source URL.
        decisionHandler(.cancel)
        guard pendingTransfer?.download === download else { return }
        if let id = pendingTransfer?.id { finishTransfer(.failure(BrowserTransferError.prohibitedTarget), expectedID: id) }
    }

    public func download(_ download: WKDownload, didReceive challenge: URLAuthenticationChallenge,
                         completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.cancelAuthenticationChallenge, nil)
        guard pendingTransfer?.download === download else { return }
        if let id = pendingTransfer?.id { finishTransfer(.failure(BrowserTransferError.prohibitedTarget), expectedID: id) }
    }

    public func downloadDidFinish(_ download: WKDownload) {
        Task { @MainActor [weak self] in await self?.commitFinishedDownload(download) }
    }

    private func commitFinishedDownload(_ download: WKDownload) async {
        guard let pending = pendingTransfer, pending.download === download, let target = pending.target else { return }
        guard accepts(target.identity), currentURL()?.absoluteString == target.pageURL,
              let file = target.transferFile,
              let staging = pending.stagingURL else { finishTransfer(.failure(BrowserTransferError.unavailable), expectedID: pending.id); return }
        do {
            try BrowserTransferFileIdentity.validateFloor(staging, upload: false)
            try await pending.fileAccess("file_write", staging)
            let current = try await BrowserTransferFileIdentity.capture(path: file.path, upload: false, access: pending.fileAccess)
            guard pendingTransfer?.id == pending.id, accepts(target.identity),
                  currentURL()?.absoluteString == target.pageURL, current == file else {
                throw BrowserTransferError.changedFile
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: staging.path)
            guard BrowserTransferFileIdentity.isPhysicalPath(staging),
                  attributes[.type] as? FileAttributeType == .typeRegular else {
                throw BrowserTransferError.changedFile
            }
            // moveItem refuses an existing destination; never clobber a file
            // created while the response was arriving.
            try FileManager.default.moveItem(at: staging, to: URL(fileURLWithPath: file.path))
            finishTransfer(.success("Download completed: \(file.path); output identity \(String(describing: attributes[.systemFileNumber])); bytes \(String(describing: attributes[.size]))."), expectedID: pending.id)
        } catch { finishTransfer(.failure(error), expectedID: pending.id) }
    }

    public func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard pendingTransfer?.download === download else { return }
        // No resumeData is stored or retried; credentials may be embedded.
        if let id = pendingTransfer?.id { finishTransfer(.failure(BrowserTransferError.failed), expectedID: id) }
    }
}
