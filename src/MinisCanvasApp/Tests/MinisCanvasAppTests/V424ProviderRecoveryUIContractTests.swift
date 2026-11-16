import Foundation
import Testing
@testable import MinisCanvasApp

@Suite("V424 provider recovery UI consumer contract")
struct V424ProviderRecoveryUIContractTests {
    private let scope = ProviderRecoveryScope(
        providerID: "DEEPSEEK_API_KEY",
        modelIDs: ["deepseek-v4-flash", "deepseek-v4-pro"]
    )

    @Test("blank recovery submission stays blocked while replacement submits")
    func recoverySubmissionDecisionsAreFailClosed() {
        let awaiting = ProviderRecoveryReducer.reduce(
            .idle,
            command: .credentialReadFailed(
                scope: scope,
                reason: .keychainReadMissing
            )
        )
        let blank = ProviderRecoveryReducer.reduce(
            awaiting,
            command: .submitReplacement(scope: scope, hasNonEmptyKey: false)
        )
        #expect(blank == .awaitingReplacement(scope: scope, reason: .missingCredential))

        let replacing = ProviderRecoveryReducer.reduce(
            awaiting,
            command: .submitReplacement(scope: scope, hasNonEmptyKey: true)
        )
        #expect(replacing == .replacing(scope: scope))

        let succeeded = ProviderRecoveryReducer.reduce(
            replacing,
            command: .saveSucceeded(scope: scope)
        )
        #expect(succeeded.readinessResetScope == scope)
    }

    @Test("SettingsView blocks keep-existing fallthrough and restores focus")
    func settingsSourceGuardsRecoverySave() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "src/MinisCanvasApp/Sources/MinisCanvasApp/SettingsView.swift"
            ),
            encoding: .utf8
        )
        let submitStart = try #require(source.range(of: "private func submitIfValid()"))
        let submit = String(source[submitStart.lowerBound..<source.endIndex])

        #expect(submit.contains("if isCurrentRecoveryProvider && !hasReplacementKey"))
        #expect(submit.contains("errorMessage = ProviderSaveFailureCategory.missingCredential.message"))
        #expect(submit.contains("focusedField = .apiKey"))
        #expect(submit.contains("focusedField = nil"))
        #expect(submit.contains("ProviderEditSaveTransition(outcome: onSave(draft))"))
        #expect(submit.contains("command: .saveSucceeded(scope: recoveryScope)"))
    }
}
