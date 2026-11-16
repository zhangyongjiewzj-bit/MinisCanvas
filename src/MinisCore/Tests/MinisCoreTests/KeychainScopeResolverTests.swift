import Testing
@testable import MinisCore

@Suite("typed Keychain scope resolver")
struct KeychainScopeResolverTests {
    private let packagedService = "com.miniscanvas.packaged-field.fixture"

    @Test("canonical DeepSeek scope is stable and contains no credential value")
    func canonicalDeepSeekScope() throws {
        let resolution = try #require(KeychainScopeResolver.resolve(
            providerID: " DeepSeek ",
            account: " hermes_custom_deepseek_api_key ",
            canonicalService: packagedService,
            canonicalAccessGroup: "group.com.miniscanvas.shared"
        ))

        guard case .canonical(let scope) = resolution else {
            Issue.record("a canonical namespace must not require a legacy lookup")
            return
        }
        #expect(scope.providerID == "deepseek")
        #expect(scope.service == packagedService)
        #expect(scope.account == "HERMES_CUSTOM_DEEPSEEK_API_KEY")
        #expect(scope.accessGroup == "group.com.miniscanvas.shared")
        #expect(String(describing: scope).contains("fixture-secret") == false)
    }

    @Test("only the fixed old service becomes a legacy rebind candidate")
    func finiteLegacyAliasLookup() throws {
        let resolution = try #require(KeychainScopeResolver.resolve(
            providerID: "deepseek",
            account: "DEEPSEEK_API_KEY",
            canonicalService: packagedService,
            legacyServices: [
                "com.unknown.service",
                KeychainScopeResolver.legacyService,
                KeychainScopeResolver.legacyService,
                packagedService,
            ]
        ))

        guard case .rebind(let canonical, let legacy) = resolution else {
            Issue.record("the fixed old service should produce one rebind candidate")
            return
        }
        #expect(canonical.service == packagedService)
        #expect(canonical.account == "DEEPSEEK_API_KEY")
        #expect(legacy.map(\.service) == [KeychainScopeResolver.legacyService])
        #expect(legacy[0].account == canonical.account)
        #expect(legacy[0].accessGroup == nil)
    }

    @Test("unknown provider or alias fails closed")
    func unknownFailsClosed() {
        #expect(KeychainScopeResolver.resolve(
            providerID: "deepseek",
            account: "UNKNOWN_API_KEY",
            canonicalService: packagedService
        ) == nil)
        #expect(KeychainScopeResolver.resolve(
            providerID: "other-provider",
            account: "DEEPSEEK_API_KEY",
            canonicalService: packagedService
        ) == nil)
        #expect(KeychainScopeResolver.resolve(
            providerID: "deepseek",
            account: "DEEPSEEK_API_KEY",
            canonicalService: "   "
        ) == nil)
    }

    @Test("other provider keeps an independent scope")
    func providerIsolation() throws {
        let deepSeek = try #require(KeychainScopeResolver.resolve(
            providerID: "deepseek",
            account: "DEEPSEEK_API_KEY",
            canonicalService: packagedService,
            legacyServices: [KeychainScopeResolver.legacyService]
        ))
        let openAI = try #require(KeychainScopeResolver.resolve(
            providerID: "openai",
            account: "OPENAI_API_KEY",
            canonicalService: packagedService,
            legacyServices: [KeychainScopeResolver.legacyService]
        ))

        #expect(deepSeek != openAI)
        guard case .rebind(let deepCanonical, let deepLegacy) = deepSeek,
              case .rebind(let openCanonical, let openLegacy) = openAI else {
            Issue.record("both known providers should retain their own legacy plan")
            return
        }
        #expect(deepCanonical.providerID == "deepseek")
        #expect(openCanonical.providerID == "openai")
        #expect(deepCanonical.account != openCanonical.account)
        #expect(deepLegacy.allSatisfy { $0.providerID == "deepseek" })
        #expect(openLegacy.allSatisfy { $0.providerID == "openai" })
    }
}
