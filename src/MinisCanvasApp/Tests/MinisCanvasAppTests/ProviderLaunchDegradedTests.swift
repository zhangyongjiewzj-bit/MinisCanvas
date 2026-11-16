import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("K26 provider-degraded launch")
@MainActor
struct ProviderLaunchDegradedTests {
    private struct FixtureError: Error {}

    @Test("composition failure selects a degraded dependency without trapping")
    func compositionFailureUsesDegradedDependency() {
        let value = AppLaunchCoordinator.resolve(
            primary: { throw FixtureError() },
            degraded: { "degraded-bridge" }
        )

        #expect(value == "degraded-bridge")
    }

    @Test("one provider failure does not suppress healthy providers or window")
    func isolatesOneProviderFailure() {
        let result = ProviderLaunchCoordinator.initialize([
            .init(providerID: "healthy", initialize: { "healthy-instance" }),
            .init(providerID: "broken", initialize: { throw FixtureError() })
        ])

        #expect(result.ready == ["healthy-instance"])
        #expect(result.canPresentWindow)
        #expect(result.degradedProviderIDs == ["broken"])
        #expect(result.statuses == [
            ProviderLaunchStatus(providerID: "healthy", state: .ready),
            ProviderLaunchStatus(
                providerID: "broken",
                state: .degraded(.initializationFailed)
            )
        ])
    }

    @Test("credential and Keychain failures stay secret-free and provider-local")
    func classifiesCredentialFailures() {
        let result = ProviderLaunchCoordinator.initialize([
            .init(providerID: "missing", initialize: {
                throw ProviderFactory.FactoryError.noCredentials("secret-free")
            }),
            .init(providerID: "denied", initialize: {
                throw EnvVarPersistenceError.keychainReadDenied
            })
        ])

        #expect(result.ready.isEmpty)
        #expect(result.canPresentWindow)
        #expect(result.statuses == [
            ProviderLaunchStatus(
                providerID: "missing",
                state: .degraded(.credentialUnavailable)
            ),
            ProviderLaunchStatus(
                providerID: "denied",
                state: .degraded(.keychainUnavailable)
            )
        ])
    }

    @Test("empty Keychain-backed custom credential fails closed without app crash")
    func emptyCustomCredentialBecomesDegraded() {
        let previous = EnvCredentials.supplementarySource
        defer { EnvCredentials.supplementarySource = previous }
        EnvCredentials.supplementarySource = { _ in nil }

        let chat = ChatStore()
        let provider = EnvVarEntry(
            name: "BROKEN_KEYCHAIN_PROVIDER",
            value: "",
            isSecret: true,
            valueInKeychain: true,
            baseURL: "https://provider.example.test/v1",
            modelNames: ["fixture-model"],
            protocolType: .openaiCompatible
        )
        chat.providerRecordsSource = { [provider] }
        chat.setCustomProvider(provider)

        #expect(throws: ProviderFactory.FactoryError.noCredentials(
            "BROKEN_KEYCHAIN_PROVIDER"
        )) {
            try chat.activeProvider()
        }
        #expect(chat.providerLaunchStatus(for: provider.name) == ProviderLaunchStatus(
            providerID: provider.name,
            state: .degraded(.credentialUnavailable)
        ))
    }

    @Test("healthy custom credential clears a previous degraded status")
    func healthyProviderRecovers() throws {
        let previous = EnvCredentials.supplementarySource
        defer { EnvCredentials.supplementarySource = previous }
        EnvCredentials.supplementarySource = { name in
            name == "RECOVERING_PROVIDER" ? "fixture-key" : nil
        }

        let chat = ChatStore()
        let provider = EnvVarEntry(
            name: "RECOVERING_PROVIDER",
            value: "",
            isSecret: true,
            valueInKeychain: true,
            baseURL: "https://provider.example.test/v1",
            modelNames: ["fixture-model"],
            protocolType: .openaiCompatible
        )
        chat.providerRecordsSource = { [provider] }
        chat.setCustomProvider(provider)
        _ = try chat.activeProvider()

        #expect(chat.providerLaunchStatus(for: provider.name) == ProviderLaunchStatus(
            providerID: provider.name,
            state: .ready
        ))
    }
}
