import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("P3 provider-local readiness summary")
struct P3ProviderLocalReadinessSummaryTests {
    @Test("one blocked provider does not contaminate a healthy sibling")
    func providerFailuresStayLocal() {
        let blockedReport = report(
            providerID: "blocked-provider",
            state: .blocked,
            authentication: .failed
        )
        let healthyReport = report(
            providerID: "healthy-provider",
            state: .mock,
            authentication: .passed
        )

        let blocked = ProviderLocalReadinessSummary.aggregate(
            providerID: "blocked-provider",
            report: blockedReport,
            modelStates: [],
            isChecking: false
        )
        let healthy = ProviderLocalReadinessSummary.aggregate(
            providerID: "healthy-provider",
            report: healthyReport,
            modelStates: [],
            isChecking: false
        )

        #expect(blocked.state == .blocked)
        #expect(blocked.action == .replaceAPIKey)
        #expect(blocked.message.contains("鉴权失败"))
        #expect(healthy.state == .ready)
        #expect(healthy.action == .none)
    }

    @Test("successor rebind exposes blocked to checking to ready")
    func successorRebindTransitionIsExplicit() {
        let checking = ProviderLocalReadinessTransition.successorRebindStarted(
            providerID: "provider-a"
        )
        let ready = ProviderLocalReadinessTransition.successorRebindCompleted(
            providerID: "provider-a",
            report: report(
                providerID: "provider-a",
                state: .mock,
                authentication: .passed
            ),
            modelStates: []
        )

        #expect(checking.state == .checking)
        #expect(checking.message.contains("重新绑定"))
        #expect(ready.state == .ready)
        #expect(ready.message.contains("已就绪"))
    }

    @Test("provider summary remains secret-free and actionable")
    func summaryDoesNotEchoTransportDetails() {
        let summary = ProviderLocalReadinessSummary.aggregate(
            providerID: "provider-secret",
            report: report(
                providerID: "provider-secret",
                state: .blocked,
                authentication: .failed
            ),
            modelStates: [],
            isChecking: false
        )

        #expect(summary.isActionable)
        #expect(summary.action == .replaceAPIKey)
        #expect(!summary.message.contains("sk-"))
        #expect(!summary.message.localizedCaseInsensitiveContains("authorization"))
        #expect(!summary.message.localizedCaseInsensitiveContains("body"))
        #expect(!summary.message.contains("?"))
    }

    private func report(
        providerID: String,
        state: ProviderReadinessState,
        authentication: MinisCanvasApp.ProviderReadinessStageStatus
    ) -> SettingsProviderReadinessReport {
        let date = Date(timeIntervalSince1970: 1_756_000_000)
        let stage = ProviderReadinessStage(
            status: .passed,
            detail: "通过",
            statusCode: 200
        )
        return SettingsProviderReadinessReport(
            recordID: providerID,
            providerID: providerID,
            checkedAt: date,
            configuration: stage,
            reachability: stage,
            authentication: ProviderReadinessStage(
                status: authentication,
                detail: authentication == .passed ? "鉴权通过" : "鉴权失败",
                statusCode: authentication == .passed ? 200 : 401
            ),
            modelDiscovery: stage,
            discoveredModelIDs: ["model"],
            modelChecks: [],
            state: state,
            redactedResult: ""
        )
    }
}
