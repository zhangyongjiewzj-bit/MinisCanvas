import Foundation
import Testing
@testable import MinisCanvasApp

@Suite("V424 provider credential recovery action")
struct V424ProviderRecoveryActionTests {
    private let scope = ProviderRecoveryScope(
        providerID: "DEEPSEEK_API_KEY",
        modelIDs: ["deepseek-v4-flash", "deepseek-v4-flash", " deepseek-v4-pro "]
    )

    @Test("missing and denied reads allow a scoped replacement")
    func readFailuresEnterReplacementAndSuccessResetsOnlyScope() {
        #expect(scope.modelIDs == ["deepseek-v4-flash", "deepseek-v4-pro"])

        for reason in [
            ProviderSaveFailureCategory.keychainReadMissing,
            ProviderSaveFailureCategory.keychainReadDenied,
        ] {
            let awaiting = ProviderRecoveryReducer.reduce(
                .idle,
                command: .credentialReadFailed(scope: scope, reason: reason)
            )
            #expect(awaiting == .awaitingReplacement(scope: scope, reason: reason))

            let replacing = ProviderRecoveryReducer.reduce(
                awaiting,
                command: .submitReplacement(scope: scope, hasNonEmptyKey: true)
            )
            #expect(replacing == .replacing(scope: scope))

            let succeeded = ProviderRecoveryReducer.reduce(
                replacing,
                command: .saveSucceeded(scope: scope)
            )
            #expect(succeeded == .succeeded(scope: scope))
            #expect(succeeded.readinessResetScope == scope)
        }
    }

    @Test("blank replacement remains blocked and never enters replacing")
    func blankReplacementIsRejected() {
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
        #expect(blank.readinessResetScope == nil)
    }

    @Test("write failure stays typed and cancel produces no readiness reset")
    func failureAndCancelAreFailClosed() {
        let replacing = ProviderRecoveryReducer.reduce(
            .idle,
            command: .submitReplacement(scope: scope, hasNonEmptyKey: true)
        )
        let failed = ProviderRecoveryReducer.reduce(
            replacing,
            command: .saveFailed(scope: scope, failure: .keychainWriteFailed)
        )
        #expect(failed == .failed(scope: scope, failure: .keychainWriteFailed))
        #expect(failed.readinessResetScope == nil)

        let cancelled = ProviderRecoveryReducer.reduce(
            .awaitingReplacement(scope: scope, reason: .keychainReadDenied),
            command: .cancel(scope: scope)
        )
        #expect(cancelled == .cancelled(scope: scope))
        #expect(cancelled.readinessResetScope == nil)
    }

    @Test("a sibling provider cannot consume or reset this recovery scope")
    func siblingProviderIsUnaffected() {
        let sibling = ProviderRecoveryScope(
            providerID: "OPENAI_API_KEY",
            modelIDs: ["gpt-5.4"]
        )
        let replacing = ProviderRecoveryReducer.reduce(
            .idle,
            command: .submitReplacement(scope: scope, hasNonEmptyKey: true)
        )
        let afterSiblingSuccess = ProviderRecoveryReducer.reduce(
            replacing,
            command: .saveSucceeded(scope: sibling)
        )
        let afterSiblingCancel = ProviderRecoveryReducer.reduce(
            replacing,
            command: .cancel(scope: sibling)
        )
        let afterSiblingReadFailure = ProviderRecoveryReducer.reduce(
            replacing,
            command: .credentialReadFailed(scope: sibling, reason: .keychainReadDenied)
        )

        #expect(afterSiblingSuccess == replacing)
        #expect(afterSiblingCancel == replacing)
        #expect(afterSiblingReadFailure == replacing)
        #expect(afterSiblingSuccess.readinessResetScope == nil)
    }

    @Test("settings UI wires typed recovery commands around the existing save boundary")
    func settingsSourceContainsRecoveryWiring() throws {
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

        for contract in [
            "ProviderRecoveryReducer.reduce",
            ".submitReplacement(",
            ".saveSucceeded(scope:",
            ".saveFailed(scope:",
            "cancelProviderRecovery()",
            "focusedField = nil",
            "ProviderEditSaveTransition(outcome: outcome)",
        ] {
            #expect(source.contains(contract), "缺少 provider recovery UI contract: \(contract)")
        }
        #expect(!source.contains("onCredentialReadFailure:"))
    }
}
