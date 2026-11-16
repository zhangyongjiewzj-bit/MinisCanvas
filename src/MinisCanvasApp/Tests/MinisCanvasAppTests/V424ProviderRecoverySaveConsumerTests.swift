import Foundation
import Testing
@testable import MinisCanvasApp

@Suite("V424 provider recovery save consumer contract")
struct V424ProviderRecoverySaveConsumerTests {
    private let scope = ProviderRecoveryScope(
        providerID: "DEEPSEEK_API_KEY",
        modelIDs: ["deepseek-v4-flash", "deepseek-v4-pro"]
    )

    @Test("successful replacement exposes only its provider/model reset scope")
    func successfulReplacementIsScoped() {
        let replacing = ProviderRecoveryReducer.reduce(
            .awaitingReplacement(scope: scope, reason: .keychainReadMissing),
            command: .submitReplacement(scope: scope, hasNonEmptyKey: true)
        )
        let succeeded = ProviderRecoveryReducer.reduce(
            replacing,
            command: .saveSucceeded(scope: scope)
        )
        #expect(succeeded.readinessResetScope == scope)

        let failed = ProviderRecoveryReducer.reduce(
            replacing,
            command: .saveFailed(scope: scope, failure: .keychainWriteFailed)
        )
        #expect(failed.readinessResetScope == nil)
    }

    @Test("SettingsView passes typed credential intent through the real save boundary")
    func settingsPassesCredentialIntent() throws {
        let source = try source(named: "src/MinisCanvasApp/Sources/MinisCanvasApp/SettingsView.swift")
        #expect(source.components(separatedBy: "credential: draft.credential").count - 1 == 3)
        #expect(source.contains("let outcome = onSave(draft)"))
        #expect(source.contains("command: .saveSucceeded(scope: recoveryScope)"))
        #expect(source.contains("command: .saveFailed(scope: recoveryScope, failure: failure)"))
        #expect(source.contains("case .present(let message)"))
        #expect(source.contains("focusedField = .apiKey"))
    }

    @Test("SettingsCenter invalidates readiness only after a successful scoped save")
    func settingsCenterScopesInvalidationAfterPersistence() throws {
        let source = try source(named: "src/MinisCanvasApp/Sources/MinisCanvasApp/SettingsCenter.swift")
        let saveStart = try #require(source.range(of: "    func saveProvider(\n        name: String,\n        credential: ProviderCredentialUpdate"))
        let saveEnd = try #require(source.range(
            of: "    private func providerCredentialUpdate(",
            range: saveStart.upperBound..<source.endIndex
        ))
        let save = String(source[saveStart.lowerBound..<saveEnd.lowerBound])

        #expect(save.contains("let ok = envStore.saveProvider("))
        #expect(save.contains("credential: credential"))
        #expect(save.contains("providerSaveFailure = ok"))
        #expect(save.contains("if ok, let savedProvider"))
        #expect(save.contains("if configurationChanged"))
        #expect(save.contains("invalidateProviderReadinessAfterConfigurationChange(for: savedProvider)"))
        #expect(save.contains("syncSavedProviderModels(savedProvider)"))
    }

    @Test("explicit replacement never probes the old Keychain item")
    func replacementPathIsReadIndependent() throws {
        let source = try source(named: "src/MinisCore/Sources/MinisCore/Support/EnvVarStore.swift")
        let saveStart = try #require(source.range(of: "    public func saveProvider(\n        name: String,\n        credential: ProviderCredentialUpdate"))
        let saveEnd = try #require(source.range(
            of: "    /// Number of stored variables.",
            range: saveStart.upperBound..<source.endIndex
        ))
        let save = String(source[saveStart.lowerBound..<saveEnd.lowerBound])
        let replaceStart = try #require(save.range(of: "        case .replace(let apiKey):"))
        let transactionStart = try #require(save.range(of: "        let previousEntry = entries[canonical]"))
        let replacePath = String(save[replaceStart.lowerBound..<transactionStart.lowerBound])

        #expect(replacePath.contains("existing.value = existingCredentialWasDeferred ? \"\" : trimmedAPIKey"))
        #expect(replacePath.contains("case .replace = credential"))
        #expect(!replacePath.contains("keychain.readResult"))
        #expect(save.contains("let existingCredentialWasDeferred = entries[canonical].map {"))
        #expect(save.contains("$0.valueInKeychain && $0.value.isEmpty"))
        #expect(save.contains("guard keychain.set(trimmedAPIKey, forKey: canonical)"))
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
