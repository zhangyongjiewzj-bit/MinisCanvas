import Foundation
import Testing
@testable import MinisCanvasApp

@Suite("K45 provider recovery navigation")
@MainActor
struct ProviderRecoveryNavigationTests {
    private let healthy = ProviderLaunchStatus(providerID: "HEALTHY", state: .ready)
    private let degraded = ProviderLaunchStatus(
        providerID: "BROKEN_PROVIDER",
        state: .degraded(.credentialUnavailable)
    )

    @Test("degraded known provider routes to its stable API Key focus")
    func degradedProviderGetsStableDestination() {
        let destination = ProviderRecoveryNavigation.destination(
            providerID: "broken_provider",
            status: degraded,
            availableProviderIDs: ["BROKEN_PROVIDER"]
        )

        #expect(destination?.providerID == "BROKEN_PROVIDER")
        #expect(destination?.focus == .apiKey)
        #expect(destination?.id == "provider-recovery:BROKEN_PROVIDER:apiKey")
    }

    @Test("healthy and unknown providers have no recovery action")
    func healthyAndUnknownStayUnaffected() {
        #expect(
            ProviderRecoveryNavigation.destination(
                providerID: "healthy",
                status: healthy,
                availableProviderIDs: ["HEALTHY"]
            ) == nil
        )
        #expect(
            ProviderRecoveryNavigation.destination(
                providerID: "missing",
                status: degraded,
                availableProviderIDs: ["OTHER"]
            ) == nil
        )
    }

    @Test("ambiguous or stale provider identities fail closed")
    func ambiguousOrStaleProviderIdentityStaysClosed() {
        #expect(
            ProviderRecoveryNavigation.destination(
                providerID: "broken_provider",
                status: degraded,
                availableProviderIDs: ["BROKEN_PROVIDER", "broken_provider"]
            ) == nil
        )
        #expect(
            ProviderRecoveryNavigation.destination(
                providerID: "broken_provider",
                status: ProviderLaunchStatus(
                    providerID: "BROKEN_PROVIDER_OLD",
                    state: .degraded(.credentialUnavailable)
                ),
                availableProviderIDs: ["BROKEN_PROVIDER"]
            ) == nil
        )
        #expect(
            ProviderRecoveryNavigation.destination(
                providerID: " broken_provider ",
                status: degraded,
                availableProviderIDs: ["BROKEN_PROVIDER"]
            )?.providerID == "BROKEN_PROVIDER"
        )
    }

    @Test("destination rejects empty identifiers and contains no secret payload")
    func destinationIsSecretFree() {
        #expect(ProviderRecoveryDestination(providerID: "") == nil)
        let destination = ProviderRecoveryDestination(providerID: "BROKEN_PROVIDER")
        #expect(destination?.focus == .apiKey)
        #expect(destination?.id.contains("credential") == false)
    }

    @Test("settings surface wires recovery route to the stable field identifier")
    func settingsContract() throws {
        let source = try String(
            contentsOf: repositoryRoot().appendingPathComponent(
                "src/MinisCanvasApp/Sources/MinisCanvasApp/SettingsView.swift"
            ),
            encoding: .utf8
        )
        #expect(source.contains("providerRecoveryDestination(for: provider.name)"))
        #expect(source.contains("settings.provider.recovery"))
        #expect(source.contains("initialFocus ?? (isEditing ? .name : .apiKey)"))
        #expect(source.contains("settings.provider.apiKey"))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
