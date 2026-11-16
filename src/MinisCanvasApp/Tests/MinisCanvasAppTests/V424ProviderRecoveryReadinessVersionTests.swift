import Foundation
import Testing
@testable import MinisCanvasApp

@Suite("V424 provider recovery readiness credential version")
struct V424ProviderRecoveryReadinessVersionTests {
    @Test("a replacement receives a new opaque version and cannot reuse old passed state")
    func replacementVersionIsOpaqueAndFresh() {
        let oldVersion = ProviderCredentialVersion.fresh()
        let newVersion = ProviderCredentialVersion.fresh()
        #expect(oldVersion != newVersion)
        #expect(!oldVersion.opaqueValue.isEmpty)
        #expect(oldVersion.opaqueValue != newVersion.opaqueValue)
        #expect(!ProviderCredentialVersionBoundary.canReuse(
            observed: oldVersion,
            current: newVersion
        ))

        let oldScope = ProviderRecoveryScope(
            providerID: "DEEPSEEK_API_KEY",
            modelIDs: ["deepseek-v4-flash"],
            credentialVersion: oldVersion
        )
        let newScope = ProviderRecoveryScope(
            providerID: oldScope.providerID,
            modelIDs: oldScope.modelIDs,
            credentialVersion: newVersion
        )
        let replacing = ProviderRecoveryReducer.reduce(
            .awaitingReplacement(scope: oldScope, reason: .keychainReadMissing),
            command: .submitReplacement(scope: newScope, hasNonEmptyKey: true)
        )
        let succeeded = ProviderRecoveryReducer.reduce(
            replacing,
            command: .saveSucceeded(scope: newScope)
        )
        #expect(succeeded.readinessResetCredentialVersion == newVersion)
        #expect(succeeded.readinessResetCredentialVersion != oldVersion)
    }

    @Test("other provider/model readiness remains outside the rotated boundary")
    func siblingScopeCannotReuseOrReset() {
        let current = ProviderRecoveryScope(
            providerID: "DEEPSEEK_API_KEY",
            modelIDs: ["deepseek-v4-flash"],
            credentialVersion: .fresh()
        )
        let sibling = ProviderRecoveryScope(
            providerID: "OPENAI_API_KEY",
            modelIDs: ["gpt-5.4"],
            credentialVersion: .fresh()
        )
        let replacing = ProviderRecoveryReducer.reduce(
            .idle,
            command: .submitReplacement(scope: current, hasNonEmptyKey: true)
        )
        let unchanged = ProviderRecoveryReducer.reduce(
            replacing,
            command: .saveSucceeded(scope: sibling)
        )
        #expect(unchanged == replacing)
        #expect(unchanged.readinessResetCredentialVersion == nil)
    }

    @Test("source binds rotation to successful replacement and scoped invalidation")
    func sourceContractContainsVersionBoundary() throws {
        let center = try source(named: "src/MinisCanvasApp/Sources/MinisCanvasApp/SettingsCenter.swift")
        #expect(center.contains("struct ProviderCredentialVersion: Equatable, Hashable, Sendable"))
        #expect(center.contains("enum ProviderCredentialVersionBoundary"))
        #expect(center.contains("currentCredentialVersion = .fresh()"))
        #expect(center.contains("providerCredentialVersions[savedProvider.name] = currentCredentialVersion"))
        #expect(center.contains("ProviderCredentialVersionBoundary.canReuse"))
        #expect(center.contains("if configurationChanged"))
        #expect(center.contains("invalidateProviderReadinessAfterConfigurationChange(for: savedProvider)"))
        #expect(center.contains("if configurationChanged || credentialVersionChanged"))
        #expect(center.contains("$0.providerID.caseInsensitiveCompare(provider.name) == .orderedSame"))
        #expect(center.contains("readinessState: .unverified"))
        #expect(center.contains("isApplied: false"))

        let view = try source(named: "src/MinisCanvasApp/Sources/MinisCanvasApp/SettingsView.swift")
        #expect(view.contains("let credentialVersion: ProviderCredentialVersion"))
        #expect(view.contains("credentialVersion: ProviderCredentialVersion = .fresh()"))
        #expect(view.contains("readinessResetCredentialVersion"))
        #expect(view.contains("command: .saveSucceeded(scope: recoveryScope)"))
    }

    private func source(named path: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(path),
            encoding: .utf8
        )
    }
}
