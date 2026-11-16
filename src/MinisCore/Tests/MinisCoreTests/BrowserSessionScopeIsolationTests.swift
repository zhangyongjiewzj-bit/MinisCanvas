import Foundation
import Testing
import WebKit
@testable import MinisCore

// MARK: - BROWSER-05 scope isolation
//
// Requirement: 登录态/Cookie/缓存/页面存储按用户浏览器、Agent 浏览器、会话及
// 工作区隔离. The identity that actually decides isolation is the
// `WKWebsiteDataStore` registry inside `BrowserSession`, so the isolation tests
// assert on the store objects themselves as well as on the pure identity rules.
//
// Every test uses its own dimension literals: the registry is process-wide, so
// reusing a literal across tests would make unrelated tests share a store.

// MARK: - Fixtures

private func isolationKey(
    surface: BrowserSessionSurface = .userBrowser,
    profile: String,
    session: String,
    workspace: String
) -> BrowserScopeIsolationKey {
    BrowserScopeIsolationKey(surface: surface, profile: profile, session: session, workspace: workspace)
}

private func structuredScope(
    surface: BrowserSessionSurface = .userBrowser,
    profile: String,
    session: String,
    workspace: String
) -> BrowserSessionScope {
    BrowserSessionScope(surface: surface, profile: profile, session: session, workspace: workspace)
}

private func encodeJSON(_ scope: BrowserSessionScope) throws -> [String: Any] {
    let data = try JSONEncoder().encode(scope)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func decodeScope(_ json: [String: Any]) throws -> BrowserSessionScope {
    let data = try JSONSerialization.data(withJSONObject: json)
    return try JSONDecoder().decode(BrowserSessionScope.self, from: data)
}

/// A persisted pre-BROWSER-05 record: one `id` and nothing else.
private func legacy119JSON() -> [String: Any] {
    ["id": "chat:119-legacy-session"]
}

/// Build an unverified scope by declaring structure the record cannot prove:
/// the id is not the canonical encoding of the declared dimensions.
private func tamperedScope119() throws -> BrowserSessionScope {
    try decodeScope([
        "id": "browser:v1:11:userBrowser#5:other#7:session-A#10:workspace-1",
        "version": 1,
        "surface": "userBrowser",
        "profile": "profile-119",
        "session": "session-A",
        "workspace": "workspace-1"
    ])
}

// MARK: - Structured identity rules (no WebKit)

struct BrowserScopeIsolationKeyTests {

    @Test func identicalFourTupleAlwaysProducesTheSameCanonicalIdentity() {
        let first = isolationKey(profile: "profile-119a", session: "session-119a", workspace: "workspace-119a")
        let second = isolationKey(profile: "profile-119a", session: "session-119a", workspace: "workspace-119a")

        #expect(first.canonicalID == second.canonicalID)
        #expect(BrowserSessionScope(key: first) == BrowserSessionScope(key: second))
        #expect(BrowserSessionScope(key: first).registryKey == BrowserSessionScope(key: second).registryKey)
    }

    @Test func everyDimensionChangesTheCanonicalIdentity() {
        let variants = [
            isolationKey(profile: "profile-119b", session: "session-119b", workspace: "workspace-119b"),
            isolationKey(surface: .agentBrowser, profile: "profile-119b", session: "session-119b", workspace: "workspace-119b"),
            isolationKey(profile: "other-119b", session: "session-119b", workspace: "workspace-119b"),
            isolationKey(profile: "profile-119b", session: "other-119b", workspace: "workspace-119b"),
            isolationKey(profile: "profile-119b", session: "session-119b", workspace: "other-119b")
        ]
        let ids = Set(variants.map(\.canonicalID))
        let registryKeys = Set(variants.map { BrowserSessionScope(key: $0).registryKey })

        #expect(ids.count == variants.count)
        #expect(registryKeys.count == variants.count)
    }

    @Test func dimensionOrderCanBeRecoveredFromTheCanonicalID() throws {
        let candidate = isolationKey(
            surface: .agentBrowser,
            profile: "profile#with:separator",
            session: "session 119c",
            workspace: "workspace-119c"
        )
        let parsed = try #require(BrowserScopeIsolationKey.parse(canonicalID: candidate.canonicalID))

        #expect(parsed == candidate)
        #expect(parsed.surface == .agentBrowser)
        // Whitespace inside a component survives; only the edges are trimmed.
        #expect(parsed.session == "session 119c")
    }

    @Test func craftedStringsNeverParseAsStructuredIdentity() {
        let notCanonical = [
            "chat:119d",
            "browser:v1:",
            "browser:v1:11:userBrowser",
            "browser:v1:11:userBrowser#5:profi",
            "browser:v1:11:userBrowser#5:profi#7:session",
            "browser:v1:11:userBrowser#5:profi#7:session#10:workspace",
            "browser:v1:9:notABrowser#5:profi#7:session#9:workspace",
            "browser:v1:11:userBrowser#0:#7:session#9:workspace",
            "userBrowser/profile-119d/session-119d/workspace-119d"
        ]
        for text in notCanonical {
            #expect(BrowserScopeIsolationKey.parse(canonicalID: text) == nil)
            let scope = BrowserSessionScope(id: text)
            #expect(scope.isLegacyOpaque)
            #expect(scope.isolationKey == nil)
            #expect(scope.registryKey == .opaque(scope.id))
        }
    }

    @Test func dimensionsAreTrimmedAndAnEmptyDimensionFailsClosed() {
        let padded = isolationKey(profile: "  profile-119e  ", session: "\nsession-119e\t", workspace: " workspace-119e ")
        #expect(padded.profile == "profile-119e")
        #expect(padded.session == "session-119e")
        #expect(padded.workspace == "workspace-119e")
        #expect(padded.isValid)

        let emptyProfile = isolationKey(profile: "   ", session: "session-119e", workspace: "workspace-119e")
        #expect(!emptyProfile.isValid)
        let wrapped = BrowserSessionScope(key: emptyProfile)
        #expect(wrapped.isIsolationUnverified)
        #expect(!wrapped.isValid)
        #expect(wrapped.registryKey == nil)
    }

    @Test func legacyStringInitBehaviourIsUnchanged() {
        let plain = BrowserSessionScope(id: "  production:agent  ")
        #expect(plain.id == "production:agent")
        #expect(plain.isValid)
        #expect(plain.isLegacyOpaque)
        #expect(plain.isolationKey == nil)
        #expect(plain.registryKey == .opaque("production:agent"))

        let empty = BrowserSessionScope(id: " \n ")
        #expect(empty.id.isEmpty)
        #expect(!empty.isValid)
        #expect(empty.registryKey == nil)

        // The unique-by-construction default scope stays its own boundary.
        #expect(BrowserSessionScope.ephemeral().id != BrowserSessionScope.ephemeral().id)
    }
}

// MARK: - Codable back-compatibility and grant binding (no WebKit)

struct BrowserSessionScopeCodableTests {

    @Test func legacyRecordEncodesAsTheSingleIdItAlwaysWas() throws {
        let json = try encodeJSON(BrowserSessionScope(id: "chat:119-legacy-session"))

        #expect(json.count == 1)
        #expect(json["id"] as? String == "chat:119-legacy-session")
    }

    @Test func legacyPersistedIDStillDecodesAndIsNeverPromoted() throws {
        let decoded = try decodeScope(legacy119JSON())

        #expect(decoded.id == "chat:119-legacy-session")
        #expect(decoded.isValid)
        #expect(decoded.isLegacyOpaque)
        #expect(decoded.isolationKey == nil)
        #expect(decoded == BrowserSessionScope(id: "chat:119-legacy-session"))
    }

    @Test func legacyIDNeverCollidesWithAStructuredScopeOfTheSameWords() throws {
        let structured = structuredScope(
            profile: "profile-119f",
            session: "session-119f",
            workspace: "workspace-119f"
        )
        // A caller that flattens the four dimensions into a convention string
        // keeps its own namespace: same words, different identity.
        let asLegacy = BrowserSessionScope(id: "userBrowser/profile-119f/session-119f/workspace-119f")

        #expect(asLegacy.registryKey != structured.registryKey)
        #expect(asLegacy.id != structured.id)
        #expect(BrowserWriteAuthorization(grantID: "g", scopeID: asLegacy.id).authorizes(structured) == false)
    }

    @Test func truncatedCanonicalIDStaysOpaqueRatherThanHalfStructured() throws {
        let decoded = try decodeScope(["id": "browser:v1:11:userBrowser#5:profi"])

        #expect(decoded.isLegacyOpaque)
        #expect(decoded.isolationKey == nil)
        #expect(decoded.registryKey == .opaque("browser:v1:11:userBrowser#5:profi"))
    }

    @Test func structuredScopeSurvivesARoundTrip() throws {
        let original = structuredScope(
            surface: .agentBrowser,
            profile: "profile-119g",
            session: "session-119g",
            workspace: "workspace-119g"
        )
        let json = try encodeJSON(original)
        let decoded = try decodeScope(json)

        #expect(json["version"] as? Int == 1)
        #expect(json["surface"] as? String == "agentBrowser")
        #expect(decoded == original)
        #expect(decoded.isolationKey == original.isolationKey)
        #expect(decoded.registryKey == original.registryKey)
        // Rebuilding from the canonical string recovers the same identity.
        #expect(BrowserSessionScope(id: original.id) == original)
    }

    @Test func structuredRecordWithAnUnprovableShapeFailsClosed() throws {
        let tampered = try tamperedScope119()

        #expect(tampered.isIsolationUnverified)
        #expect(!tampered.isValid)
        #expect(tampered.isolationKey == nil)
        #expect(tampered.registryKey == nil)

        let partialRecords: [[String: Any]] = [
            ["id": "chat:119h", "profile": "profile-119h"],
            ["id": "chat:119h", "version": 1, "surface": "userBrowser", "profile": "p", "session": "s"],
            ["id": "chat:119h", "version": 2, "surface": "userBrowser", "profile": "p", "session": "s", "workspace": "w"],
            ["id": "chat:119h", "version": 1, "surface": "everythingBrowser", "profile": "p", "session": "s", "workspace": "w"],
            ["id": "chat:119h", "version": 1, "surface": "userBrowser", "profile": " ", "session": "s", "workspace": "w"],
            ["id": "browser:v1:11:userBrowser#5:profi#7:session#13:workspace-other", "version": 1,
             "surface": "userBrowser", "profile": "profi", "session": "session", "workspace": "workspace"]
        ]
        for record in partialRecords {
            let rejected = try decodeScope(record)
            #expect(rejected.isIsolationUnverified)
            #expect(!rejected.isValid)
            #expect(rejected.registryKey == nil)
            #expect(rejected.id == (record["id"] as? String))
        }
    }

    @Test func rejectedRecordStaysRejected() throws {
        let rejected = try tamperedScope119()
        let json = try encodeJSON(rejected)
        let again = try decodeScope(json)

        #expect(json["isolationRejected"] as? Bool == true)
        #expect(again == rejected)
        #expect(again.isIsolationUnverified)
    }

    @Test func authorizationIsBoundToTheConcreteFourTuple() {
        let home = structuredScope(profile: "profile-119i", session: "session-119i", workspace: "workspace-119i")
        let grant = BrowserWriteAuthorization(grantID: "grant-119i", scope: home)

        #expect(grant.scopeID == home.id)
        #expect(grant.boundScope == home)
        #expect(grant.authorizes(home))
        #expect(!grant.authorizes(structuredScope(
            surface: .agentBrowser, profile: "profile-119i", session: "session-119i", workspace: "workspace-119i"
        )))
        #expect(!grant.authorizes(structuredScope(
            profile: "other-119i", session: "session-119i", workspace: "workspace-119i"
        )))
        #expect(!grant.authorizes(structuredScope(
            profile: "profile-119i", session: "other-119i", workspace: "workspace-119i"
        )))
        #expect(!grant.authorizes(structuredScope(
            profile: "profile-119i", session: "session-119i", workspace: "other-119i"
        )))
        // A legacy string scope is a different identity, even carrying the
        // same words.
        #expect(!grant.authorizes(BrowserSessionScope(id: "userBrowser/profile-119i/session-119i/workspace-119i")))
        #expect(!grant.authorizes(BrowserSessionScope(id: "  ")))
    }

    @Test func crossShapeGrantsAreRejectedInBothDirections() throws {
        let legacy = BrowserSessionScope(id: "chat:119j")
        let structured = structuredScope(profile: "profile-119j", session: "session-119j", workspace: "workspace-119j")

        #expect(!BrowserWriteAuthorization(grantID: "g", scopeID: legacy.id).authorizes(structured))
        #expect(!BrowserWriteAuthorization(grantID: "g", scope: structured).authorizes(legacy))
        // The untouched legacy path still authorizes its own exact string.
        #expect(BrowserWriteAuthorization(grantID: "g", scopeID: "chat:119j").authorizes(legacy))
        #expect(!BrowserWriteAuthorization(grantID: "g", scopeID: "chat:119-other").authorizes(legacy))
        #expect(!BrowserWriteAuthorization(grantID: " ", scopeID: "chat:119j").authorizes(legacy))

        // An unverified persisted shape rejects every grant, including one
        // carrying the very same id.
        let tampered = try tamperedScope119()
        let sameIDGrant = BrowserWriteAuthorization(grantID: "g", scopeID: tampered.id)
        #expect(sameIDGrant.isValid)
        #expect(!sameIDGrant.authorizes(tampered))
    }

    @Test func writeAuthorizationKeepsItsLegacyCodableShape() throws {
        let grant = BrowserWriteAuthorization(grantID: "grant-119k", scopeID: "chat:119k")
        let data = try JSONEncoder().encode(grant)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let decoded = try JSONDecoder().decode(BrowserWriteAuthorization.self, from: data)

        #expect(Set(json.keys) == ["grantID", "scopeID"])
        #expect(decoded == grant)
        #expect(decoded.authorizes(BrowserSessionScope(id: "chat:119k")))
    }
}

// MARK: - WebKit data-store isolation

@MainActor
struct BrowserSessionDataStoreIsolationTests {

    /// Distinct workspace ⇒ distinct login/cookie boundary.
    @Test func distinctWorkspaceNeverSharesADataStore() {
        let first = BrowserSession(scope: structuredScope(
            profile: "profile-119l", session: "session-119l", workspace: "workspace-A"
        ))
        let second = BrowserSession(scope: structuredScope(
            profile: "profile-119l", session: "session-119l", workspace: "workspace-B"
        ))

        #expect(first.scope.isolationKey?.workspace == "workspace-A")
        #expect(second.scope.isolationKey?.workspace == "workspace-B")
        #expect(first.scopeID != second.scopeID)
        #expect(first.webView.configuration.websiteDataStore
                    !== second.webView.configuration.websiteDataStore)
        first.close()
        second.close()
    }

    /// Distinct session ⇒ distinct boundary.
    @Test func distinctSessionNeverSharesADataStore() {
        let first = BrowserSession(scope: structuredScope(
            profile: "profile-119m", session: "session-A", workspace: "workspace-119m"
        ))
        let second = BrowserSession(scope: structuredScope(
            profile: "profile-119m", session: "session-B", workspace: "workspace-119m"
        ))

        #expect(first.webView.configuration.websiteDataStore
                    !== second.webView.configuration.websiteDataStore)
        first.close()
        second.close()
    }

    /// 用户浏览器 vs Agent 浏览器 ⇒ distinct boundary, and a grant minted for
    /// one surface unlocks neither the other nor a foreign workspace.
    @Test func userBrowserAndAgentBrowserNeverShareADataStore() {
        let userScope = structuredScope(
            surface: .userBrowser, profile: "profile-119n", session: "session-119n", workspace: "workspace-119n"
        )
        let agentScope = structuredScope(
            surface: .agentBrowser, profile: "profile-119n", session: "session-119n", workspace: "workspace-119n"
        )
        let agentGrant = BrowserWriteAuthorization(grantID: "grant-119n", scope: agentScope)
        let user = BrowserSession(scope: userScope, writeAuthorization: agentGrant)
        let agent = BrowserSession(scope: agentScope, writeAuthorization: agentGrant)
        let foreignWorkspace = BrowserSession(scope: structuredScope(
            surface: .agentBrowser, profile: "profile-119n", session: "session-119n", workspace: "other-119n"
        ))

        #expect(user.scope.isolationKey?.surface == .userBrowser)
        #expect(agent.scope.isolationKey?.surface == .agentBrowser)
        #expect(user.webView.configuration.websiteDataStore !== agent.webView.configuration.websiteDataStore)
        #expect(agent.isReadOnly == false)
        #expect(user.isReadOnly)
        #expect(foreignWorkspace.isReadOnly)
        user.close()
        agent.close()
        foreignWorkspace.close()
    }

    /// Distinct browser instance inside the same surface ⇒ distinct boundary.
    @Test func distinctProfileNeverSharesADataStore() {
        let first = BrowserSession(scope: structuredScope(
            profile: "profile-A-119o", session: "session-119o", workspace: "workspace-119o"
        ))
        let second = BrowserSession(scope: structuredScope(
            profile: "profile-B-119o", session: "session-119o", workspace: "workspace-119o"
        ))

        #expect(first.webView.configuration.websiteDataStore
                    !== second.webView.configuration.websiteDataStore)
        first.close()
        second.close()
    }

    /// Identical four-tuple ⇒ exactly one store, no second instance leaking.
    @Test func identicalFourTupleReusesOneDataStore() throws {
        let scope = structuredScope(
            profile: "profile-119p", session: "session-119p", workspace: "workspace-119p"
        )
        let first = BrowserSession(scope: scope)
        let second = BrowserSession(scope: scope)
        let third = BrowserSession(scope: scope)
        // Rebuilt from the canonical string, and re-decoded from persistence:
        // both must land on the same single instance.
        let rebuilt = BrowserSession(scope: BrowserSessionScope(id: scope.id))
        let decoded = try decodeScope(encodeJSON(scope))
        let persisted = BrowserSession(scope: decoded)
        #expect(decoded.isolationKey == scope.isolationKey)

        let store = first.webView.configuration.websiteDataStore
        #expect(second.webView.configuration.websiteDataStore === store)
        #expect(third.webView.configuration.websiteDataStore === store)
        #expect(rebuilt.webView.configuration.websiteDataStore === store)
        #expect(persisted.webView.configuration.websiteDataStore === store)
        for session in [first, second, third, rebuilt, persisted] { session.close() }
    }

    /// Reopening the resource re-binds the very same scoped store, so an idle
    /// reclaim cannot move login state into another boundary.
    @Test func reopenedResourceKeepsTheSameScopedDataStore() throws {
        let scope = structuredScope(
            profile: "profile-119q", session: "session-119q", workspace: "workspace-119q"
        )
        let session = BrowserSession(scope: scope, idleTimeoutMinutes: 1)
        let originalStore = session.webView.configuration.websiteDataStore
        let originalNavigation = session.webView

        session.setUserVisible(false)
        #expect(session.reclaimIfIdle(at: Date().addingTimeInterval(61)))
        let lease = try session.acquireOperationLease()

        #expect(session.webView !== originalNavigation)
        #expect(session.webView.configuration.websiteDataStore === originalStore)
        session.releaseOperationLease(lease)
        session.close()
    }

    /// A legacy persisted record keeps its own boundary, still shares one store
    /// between instances of the same string, and cannot alias a structured one.
    @Test func legacyRecordKeepsItsOwnBoundaryAndStillSharesItsOwnString() throws {
        let legacy = try decodeScope(legacy119JSON())
        let first = BrowserSession(scope: legacy)
        let sameLegacy = BrowserSession(scope: legacy)
        let structured = BrowserSession(scope: structuredScope(
            profile: "profile-119r", session: "chat:119-legacy-session", workspace: "workspace-119r"
        ))
        // The same structured identity reached through its canonical string is
        // the same boundary, which is what the requirement asks for.
        let recovered = BrowserSession(scope: BrowserSessionScope(id: structured.scope.id))

        #expect(first.webView.configuration.websiteDataStore === sameLegacy.webView.configuration.websiteDataStore)
        #expect(first.webView.configuration.websiteDataStore !== structured.webView.configuration.websiteDataStore)
        #expect(recovered.webView.configuration.websiteDataStore === structured.webView.configuration.websiteDataStore)
        #expect(legacy.registryKey != structured.scope.registryKey)
        for session in [first, sameLegacy, structured, recovered] { session.close() }
    }

    /// An unverified shape is never cached and never shared: every resource
    /// gets its own private store, and nothing unlocks.
    @Test func unverifiedScopeNeverSharesADataStore() throws {
        let tampered = try tamperedScope119()
        let first = BrowserSession(scope: tampered)
        let second = BrowserSession(scope: tampered)
        let grant = BrowserWriteAuthorization(grantID: "grant-119s", scopeID: tampered.id)

        #expect(first.webView.configuration.websiteDataStore !== second.webView.configuration.websiteDataStore)
        #expect(first.isReadOnly)
        #expect(second.isReadOnly)
        #expect(!grant.authorizes(tampered))
        first.close()
        second.close()

        // Same fail-closed treatment for an empty identity.
        let empty = BrowserSessionScope(id: "   ")
        let emptyFirst = BrowserSession(scope: empty)
        let emptySecond = BrowserSession(scope: empty)
        #expect(emptyFirst.webView.configuration.websiteDataStore !== emptySecond.webView.configuration.websiteDataStore)
        emptyFirst.close()
        emptySecond.close()
    }

    /// The composite identity also fences the live-resource identity and the
    /// operation leases, which both carry `scope.id`.
    @Test func compositeIdentityFencesSessionIdentityAndLeaseOwnership() throws {
        let home = structuredScope(profile: "profile-119t", session: "session-119t", workspace: "workspace-119t")
        let foreign = structuredScope(profile: "profile-119t", session: "session-119t", workspace: "workspace-other-119t")
        let session = BrowserSession(scope: home)
        let other = BrowserSession(scope: foreign)

        #expect(session.identity.scopeID == home.id)
        #expect(session.identity.scopeID != other.identity.scopeID)
        #expect(session.accepts(session.identity))
        #expect(!session.accepts(other.identity))

        let lease = try session.acquireOperationLease()
        other.releaseOperationLease(lease)
        #expect(other.activeOperationCount == 0)
        #expect(session.activeOperationCount == 1)
        session.releaseOperationLease(lease)
        #expect(session.activeOperationCount == 0)
        session.close()
        other.close()
    }
}
