import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("P3 provider-local readiness summary consumer")
struct P3ProviderLocalReadinessSummaryConsumerTests {
    @Test("provider row consumes the center-local seam and routes typed actions")
    func providerRowConsumerContractIsWired() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let view = try String(
            contentsOf: root.appendingPathComponent(
                "src/MinisCanvasApp/Sources/MinisCanvasApp/SettingsView.swift"
            ),
            encoding: .utf8
        )
        let center = try String(
            contentsOf: root.appendingPathComponent(
                "src/MinisCanvasApp/Sources/MinisCanvasApp/SettingsCenter.swift"
            ),
            encoding: .utf8
        )

        #expect(view.contains("providerLocalReadinessSummary(for: provider)"))
        #expect(view.contains("performProviderLocalSummaryAction(localSummary, for: provider)"))
        #expect(view.contains("case .replaceAPIKey:"))
        #expect(view.contains("editingProvider = provider"))
        #expect(view.contains("checkProviderReadiness(forProviderName: provider.name)"))
        #expect(view.contains("ProviderLocalReadinessSummaryView(summary: localSummary)"))
        #expect(view.contains("ProviderSecretField("))
        #expect(view.contains("focus: $focusedField"))
        #expect(!view.contains("readCredential: center.providerCredentialRead(named:)"))
        #expect(view.contains("center.saveProvider(name: draft.name, credential: draft.credential"))
        #expect(center.contains("func providerLocalReadinessSummary("))
        #expect(center.contains("providerReadinessCheckingProviderID == provider.id"))
        #expect(center.contains("providerReadinessCheckingProviderID = record.id"))
    }

    @Test("consumer transition is blocked to checking to ready and remains secret-safe")
    func consumerTransitionAndAccessibilityContract() {
        let blocked = ProviderLocalReadinessSummary.aggregate(
            providerID: "provider-a",
            report: report(state: .blocked, authentication: .failed),
            modelStates: [],
            isChecking: false
        )
        let checking = ProviderLocalReadinessSummary.aggregate(
            providerID: "provider-a",
            report: report(state: .blocked, authentication: .failed),
            modelStates: [],
            isChecking: true
        )
        let ready = ProviderLocalReadinessSummary.aggregate(
            providerID: "provider-a",
            report: report(state: .mock, authentication: .passed),
            modelStates: [],
            isChecking: false
        )

        #expect(blocked.state == .blocked)
        #expect(blocked.action == .replaceAPIKey)
        #expect(checking.state == .checking)
        #expect(checking.message.contains("其他供应商状态不受影响"))
        #expect(ready.state == .ready)
        #expect(ready.action == .none)
        for message in [blocked.message, checking.message, ready.message] {
            #expect(!message.contains("sk-"))
            #expect(!message.localizedCaseInsensitiveContains("authorization"))
            #expect(!message.localizedCaseInsensitiveContains("bearer"))
            #expect(!message.localizedCaseInsensitiveContains("body"))
            #expect(!message.contains("?"))
        }
        #expect(ProviderLocalSummaryAction.replaceAPIKey.accessibilityHint?.contains("当前供应商") == true)
        #expect(ProviderLocalSummaryAction.retryReadiness.accessibilityHint?.contains("当前供应商") == true)
    }

    private func report(
        state: ProviderReadinessState,
        authentication: MinisCanvasApp.ProviderReadinessStageStatus
    ) -> SettingsProviderReadinessReport {
        let date = Date(timeIntervalSince1970: 1_756_000_000)
        let passed = ProviderReadinessStage(status: .passed, detail: "通过", statusCode: 200)
        return SettingsProviderReadinessReport(
            recordID: "provider-a",
            providerID: "provider-a",
            checkedAt: date,
            configuration: passed,
            reachability: passed,
            authentication: ProviderReadinessStage(
                status: authentication,
                detail: authentication == .passed ? "鉴权通过" : "鉴权失败",
                statusCode: authentication == .passed ? 200 : 401
            ),
            modelDiscovery: passed,
            discoveredModelIDs: ["model"],
            modelChecks: [],
            state: state,
            redactedResult: ""
        )
    }
}
