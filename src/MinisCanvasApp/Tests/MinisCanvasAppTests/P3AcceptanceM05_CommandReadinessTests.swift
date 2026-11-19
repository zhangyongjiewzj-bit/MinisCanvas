import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("D-COMMAND-09 real blocker projection")
@MainActor
struct P3AcceptanceM05CommandReadinessTests {
    @Test func currentConfigurationBlockerKeepsCommandDiscoverableButNotDispatchable() {
        let registry = CommandRegistry()
        registry.registerComposerCommands()
        var session = ComposerSlashSessionState.neutral
        session.unavailableReasonsByCommandID["provider.use"] = "未配置 Provider"

        let rows = ComposerSlashCommandMenu.entries(
            matching: "/provider.use", registry: registry, sessionState: session
        )
        #expect(rows.map(\.id) == ["provider.use"])
        #expect(rows.first?.state == .blocked(reason: "未配置 Provider"))
        #expect(rows.first?.shouldSendOnAccept == false)
        #expect(rows.first?.accessibilityValue(isSelected: true).contains("未配置 Provider") == true)
    }

    @Test func missingExecutorIsDerivedFromTheAdjudicationConsumer() {
        #expect(ComposerCommandAdjudicationCenter.missingExecutorReason(for: "canvas.run") != nil)
        #expect(ComposerCommandAdjudicationCenter.missingExecutorReason(for: "memory.propose") == nil)
        #expect(ComposerCommandAdjudicationCenter.readinessContract(for: "memory.propose") == .scopedMemoryProposal)
        #expect(ComposerCommandAdjudicationCenter.missingExecutorReason(for: "help") == nil)
        #expect(ComposerCommandAdjudicationCenter.missingExecutorReason(for: "compact") == nil)
    }

    @Test func registeredRoutesExposeOnlyTheirProvenExecutionDependencies() {
        let contract = ComposerCommandAdjudicationCenter.readinessContract(for:)

        #expect(contract("provider") == .displayOnly)
        #expect(contract("boundary") == .displayOnly)
        #expect(contract("help") == .displayOnly)
        #expect(contract("model") == .localDesktopAction)
        #expect(contract("compact") == .compactConditionalProvider(keepRecent: 3))

        // Opening the model picker is a local desktop action, not a Provider call. /compact only
        // reaches activeProvider after the production short-history guard;
        // this contract does not turn a missing live Provider into blanket
        // blockers for unrelated rows or claim that Mock is live-ready.
        #expect(contract("settings.open") == .unregistered)
        #expect(contract("not-a-composer-command") == .unregistered)
    }

    @Test func unsupportedRegisteredCommandsCannotMasqueradeAsReadyRoutes() {
        let contract = ComposerCommandAdjudicationCenter.readinessContract(for:)
        #expect(ComposerCommandAdjudicationCenter.readinessContract(for: "provider.use") == .canonicalModelSelection)
        #expect(contract("approve") == .presentedToolApproval)
        for id in ["canvas.run", "boundary.set"] {
            guard case .missingExecutor(let reason) = contract(id) else {
                Issue.record("/\(id) must remain discoverable with its actual missing-executor blocker")
                continue
            }
            #expect(reason == (id == "boundary.set"
                ? "暂不可用，请在设置→智能体调整最高模式。" : "当前没有已接线的生产执行入口"))
        }
        #expect(ComposerCommandAdjudicationCenter.missingExecutorReason(for: "workflow") == nil)
        // The runner is bound by the App root; a concrete template/provider
        // still has to pass submit-time and approval-time checks.
        #expect(contract("workflow") == .unverifiedExecutionRoute)
    }
}
