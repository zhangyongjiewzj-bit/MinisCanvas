import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private struct P0AApprovingDelegate: ApprovalDelegate {
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        ApprovalDecision(
            approved: true,
            confirmed: true,
            requestID: request.requestID,
            bindingDigest: request.identityDigest
        )
    }
}

private enum P0AComposerBrowserProbe {
    nonisolated(nonsending) static func execute(
        _ executor: ComposerPolicyEnforcedToolExecutor,
        context: AgentExecutionContextSnapshot,
        callID: String,
        input: [String: Any]
    ) async throws -> String {
        try await AgentExecutionContext.$current.withValue(context) {
            try await executor.execute(callID: callID, name: "browser", input: input)
        }
    }
}

/// Every P0-A production gate test owns one explicit packaged-field profile.
/// In particular, this prevents BridgeStore's default WorkflowStore from
/// evaluating the ambient Application Support directory before the fixture is
/// assembled.
@MainActor
private struct P0AProductionFixture {
    let profile: RuntimeIsolationProfile
    let settings: SettingsCenter
    let bridge: BridgeStore

    init(label: String) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p0a-field-\(label)-\(UUID().uuidString)", isDirectory: true)
        let profile = try RuntimeIsolationProfile.resolveLaunchProfile(
            processEnvironment: [
                RuntimeIsolationProfile.fieldActivationMarkerKey: "1",
                RuntimeIsolationProfile.fieldActivationRootKey: root.path
            ],
            processArguments: ["MinisCanvas", RuntimeIsolationProfile.fieldActivationArgument],
            processName: "MinisCanvasApp"
        )
        let defaults = profile.makeUserDefaults()
        let shortcuts = ShortcutStore(defaults: defaults)
        let sessions = SessionStore(directory: profile.sessionDirectory)
        let badges = SessionBadgeStore(directory: profile.minisCanvasDirectory)
        let log = profile.makeLogManager()
        let readiness = ProviderReadinessStore(directory: profile.providerConfigurationDirectory)
        let settings = ProductionDomainAssembly.makeSettings(
            profile: profile,
            keychain: KeychainStore(backing: InMemoryKeychainBacking()),
            sessionStore: sessions,
            sessionBadgeStore: badges,
            logManager: log,
            store: shortcuts,
            readinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessStore: readiness
        )
        let skills = SkillsStore(
            appStore: settings.skillStore,
            stateFileURL: profile.skillStateURL,
            loadImmediately: false
        )
        let scheduler = SchedulerTaskStore(
            defaults: defaults,
            occurrenceLedgerURL: profile.minisCanvasDirectory
                .appendingPathComponent("scheduler-occurrences-v1.json")
        )
        let workflows = WorkflowStore(
            storeDirectory: profile.minisCanvasDirectory
                .appendingPathComponent("Workflows", isDirectory: true)
        )
        let bridge = ProductionDomainAssembly.makeBridge(
            profile: profile,
            bootstrapFailure: nil,
            settings: settings,
            store: shortcuts,
            defaults: defaults,
            skillsStore: skills,
            schedulerStore: scheduler,
            logManager: log,
            workflowStore: workflows,
            sessionBadgeStore: badges,
            sessionStore: sessions
        )
        self.profile = profile
        self.settings = settings
        self.bridge = bridge
    }

    func attach(
        policy: ApprovalPolicy = .alwaysAsk,
        approvalDelegate: (any ApprovalDelegate)? = nil
    ) {
        var agent = AgentSettings.default
        agent.approvalPolicy = policy
        _ = bridge.attachProductionServices(
            agentSettings: agent,
            browserSettings: settings.effectiveBrowserSettings,
            fileAccessAllowedRoot: profile.rootDirectory,
            fileAccessDeniedRoots: [],
            sessionDirectory: profile.sessionDirectory,
            mcpManager: settings.mcpManager,
            skillStore: settings.skillStore,
            approvalDelegateOverride: approvalDelegate,
            canvasRuntimeState: profile.canvasRuntimeState,
            sessionReadSecretStore: settings.envStore
        )
    }

    func cleanup() {
        try? profile.cleanupDisposableRoots()
    }
}

@Suite("P0-A 审批策略生产门")
@MainActor
struct P0AApprovalPolicyGateTests {
    private func source(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    @Test("风险询问文案不能继续映射为永久拒绝")
    func riskOnlyLabelUsesDedicatedPolicyCase() throws {
        let settings = try source(
            "src/MinisCanvasApp/Sources/MinisCanvasApp/SettingsView.swift"
        )

        #expect(settings.contains(
            "Text(\"只问高风险\").tag(ApprovalPolicy.riskOnlyAsk)"
        ))
        for label in ["仅风险操作询问", "只问高风险"] {
            #expect(!settings.contains("Text(\"\(label)\").tag(ApprovalPolicy.never)"))
            #expect(!settings.contains("Text(\"\(label)\").tag(ApprovalPolicy.deny)"))
        }
    }

    @Test("生产装配消费用户选择的审批策略")
    func productionAssemblyForwardsApprovalPolicy() throws {
        let ask = try P0AProductionFixture(label: "assembly-ask")
        defer { ask.cleanup() }
        ask.attach(policy: .alwaysAsk)
        let askEngine = try #require(ask.bridge.chat.agentEngine as? AgentLoopChatEngine)
        let askGate = try #require(askEngine.loop.approvalGate)
        // 用户 2026-11-16：浏览器只读动作不弹卡，因此 .alwaysAsk 下 browser 整体免问；
        // 点击、输入、下载、上传这类写动作仍按输入逐次审批（BrowserSideEffectPolicy）。
        #expect(askGate.policy(for: "browser") == .autoApprove)
        // 用户 2026-11-16：授权目录内只读文件工具不弹卡。
        #expect(askGate.policy(for: "file_read") == .autoApprove)

        let approve = try P0AProductionFixture(label: "assembly-auto")
        defer { approve.cleanup() }
        approve.attach(policy: .autoApprove)
        let approveEngine = try #require(approve.bridge.chat.agentEngine as? AgentLoopChatEngine)
        let approveGate = try #require(approveEngine.loop.approvalGate)
        #expect(approveGate.policy(for: "file_write") == .autoApprove)

        let risk = try P0AProductionFixture(label: "assembly-risk")
        defer { risk.cleanup() }
        risk.attach(policy: .riskOnlyAsk)
        let riskEngine = try #require(risk.bridge.chat.agentEngine as? AgentLoopChatEngine)
        let riskGate = try #require(riskEngine.loop.approvalGate)
        #expect(riskGate.policy(for: "file_read") == .autoApprove)
        #expect(riskGate.policy(for: "file_write") == .alwaysAsk)

        let deny = try P0AProductionFixture(label: "assembly-deny")
        defer { deny.cleanup() }
        deny.attach(policy: .deny)
        let denyEngine = try #require(deny.bridge.chat.agentEngine as? AgentLoopChatEngine)
        let denyGate = try #require(denyEngine.loop.approvalGate)
        #expect(denyGate.policy(for: "file_read") == .deny)
        #expect(denyGate.policy(for: "file_write") == .deny)
    }

    @Test("生产审批门记录脱敏 receipt")
    func productionGateRecordsApprovalReceipt() async throws {
        let fixture = try P0AProductionFixture(label: "receipt")
        defer { fixture.cleanup() }
        fixture.attach(policy: .riskOnlyAsk, approvalDelegate: P0AApprovingDelegate())
        let engine = try #require(fixture.bridge.chat.agentEngine as? AgentLoopChatEngine)
        let gate = try #require(engine.loop.approvalGate)
        _ = try await gate.gate(
            tool: "file_write",
            input: [
                "path": fixture.profile.rootDirectory.appendingPathComponent("a.txt").path,
                "content": "secret-body"
            ]
        )
        let receipt = try #require(fixture.bridge.approvalReceipts.first)
        #expect(receipt.toolName == "file_write")
        #expect(receipt.policy == .alwaysAsk)
        #expect(!receipt.inputSummary.contains("secret-body"))
    }

    @Test("Composer 生产审批在浏览器动作前交付同一调用的一次性授权")
    func composerBrowserApprovalReachesProductionToolBeforeAction() async throws {
        let fixture = try P0AProductionFixture(label: "browser-composer")
        defer { fixture.cleanup() }
        fixture.attach(policy: .riskOnlyAsk, approvalDelegate: P0AApprovingDelegate())
        let browser = try #require(fixture.bridge.productionBrowserTool)
        defer { browser.session.close() }
        // The production interaction target requires an explicitly admitted web origin.
        let origin = try #require(URL(string: "https://p0a.synthetic/approval"))
        browser.session.setNavigationPolicy(BrowserNavigationPolicy(allowedHosts: ["p0a.synthetic"]))
        try await browser.session.loadHTMLString(
            "<html><body><button id=\"submit\">go</button></body></html>",
            baseURL: origin
        )
        let engine = try #require(fixture.bridge.chat.agentEngine as? AgentLoopChatEngine)
        let gate = try #require(engine.loop.approvalGate)
        let base = try #require(fixture.bridge.productionBuiltinToolExecutor)
        let facts = fixture.bridge.chat.composerPolicyFacts
        let sessionID = try #require(fixture.bridge.chat.activeSessionID?.uuidString)
        let snapshot = ComposerSubmissionSnapshot(
            mode: .manual,
            approvalScope: .request,
            effort: .standard,
            sessionID: sessionID,
            turnID: 1,
            taskID: "approval-task",
            attemptID: "approval-attempt",
            messageID: "approval-message",
            workspaceID: facts.workspaceID,
            createdAt: Date(),
            policyRevision: facts.revision,
            grantEpoch: facts.grantEpoch,
            autonomyCeiling: facts.autonomyCeiling
        )
        let executor = ComposerPolicyEnforcedToolExecutor(
            base: base,
            controller: ComposerAuthorizationController(snapshot: snapshot, facts: facts),
            approvalGate: gate
        )
        let input: [String: Any] = ["action": "click", "selector": "#submit"]
        let context = AgentExecutionContextSnapshot(
            provider: MockProvider.shared,
            approvalGate: gate,
            turnController: nil,
            currentConversationID: sessionID,
            makeChildBudget: nil,
            deadline: nil
        )
        let output = try await P0AComposerBrowserProbe.execute(
            executor, context: context,
            callID: "approved-click-1", input: input
        )
        #expect(output.contains("clicked"))
        #expect(fixture.bridge.approvalReceipts.last?.requestID == "approved-click-1")
        #expect(browser.session.sideEffectGrants.pendingGrantCount == 0)

        // A second call does not inherit the first call's consumed grant.
        let unmatched = try await browser.execute(name: "browser", input: input)
        #expect(unmatched.contains("write_authorization_required"))
    }

    @Test("普通审批门返回前完成浏览器授权兑换")
    func genericBrowserGateAwaitsProductionRedemption() async throws {
        let fixture = try P0AProductionFixture(label: "browser-gate")
        defer { fixture.cleanup() }
        fixture.attach(approvalDelegate: P0AApprovingDelegate())
        let browser = try #require(fixture.bridge.productionBrowserTool)
        defer { browser.session.close() }
        // The production interaction target requires an explicitly admitted web origin.
        let origin = try #require(URL(string: "https://p0a.synthetic/approval"))
        browser.session.setNavigationPolicy(BrowserNavigationPolicy(allowedHosts: ["p0a.synthetic"]))
        try await browser.session.loadHTMLString(
            "<html><body><button id=\"submit\">go</button></body></html>",
            baseURL: origin
        )
        let engine = try #require(fixture.bridge.chat.agentEngine as? AgentLoopChatEngine)
        let gate = try #require(engine.loop.approvalGate)
        let action = "click"
        let selector = "#submit"
        let input: [String: Any] = ["action": action, "selector": selector]
        _ = try await gate.gate(tool: "browser", input: input, callID: "generic-click-1")
        #expect(browser.session.sideEffectGrants.pendingGrantCount == 1)
        let identity = BrowserSideEffectExecutionIdentity(
            callID: "generic-click-1",
            inputDigest: try ComposerToolInput(input).digest
        )
        let output = try await BrowserSideEffectCallContext.$current.withValue(identity) {
            try await browser.execute(
                name: "browser", input: ["action": action, "selector": selector]
            )
        }
        #expect(output.contains("clicked"))
        #expect(browser.session.sideEffectGrants.pendingGrantCount == 0)
    }

    @Test("运行中修改设置立即刷新 Agent、Canvas 与 Composer 策略")
    func runtimeSettingsChangeRebindsProductionGates() async throws {
        let fixture = try P0AProductionFixture(label: "runtime-policy")
        defer { fixture.cleanup() }
        fixture.attach(policy: .alwaysAsk, approvalDelegate: P0AApprovingDelegate())
        fixture.settings.onApprovalPolicyChanged = { policy in
            fixture.bridge.updateApprovalPolicy(policy)
        }

        let initialEngine = try #require(fixture.bridge.chat.agentEngine as? AgentLoopChatEngine)
        #expect(initialEngine.loop.approvalGate?.policy(for: "browser") == .autoApprove)
        let initialRevision = fixture.bridge.chat.composerPolicyFacts.revision
        let initialEpoch = fixture.bridge.chat.composerPolicyFacts.grantEpoch

        fixture.settings.approvalPolicy = .riskOnlyAsk

        let refreshedEngine = try #require(fixture.bridge.chat.agentEngine as? AgentLoopChatEngine)
        #expect(refreshedEngine.loop.approvalGate?.policy(for: "file_read") == .autoApprove)
        #expect(refreshedEngine.loop.approvalGate?.policy(for: "file_write") == .alwaysAsk)
        #expect(fixture.bridge.chat.composerPolicyFacts.revision != initialRevision)
        #expect(fixture.bridge.chat.composerPolicyFacts.grantEpoch != initialEpoch)

        fixture.settings.approvalPolicy = .deny
        let deniedEngine = try #require(fixture.bridge.chat.agentEngine as? AgentLoopChatEngine)
        #expect(deniedEngine.loop.approvalGate?.policy(for: "file_read") == .deny)
        // phase3NonCanvas rejects before the inner approval policy gate.
        let receiptsBeforeCanvas = fixture.bridge.approvalReceipts.count
        await #expect(throws: SafetyRuntimeAdmissionError.featureDisabled(.canvas)) {
            _ = try await fixture.bridge.executeCanvasMutation(.resetStatuses)
        }
        #expect(fixture.bridge.approvalReceipts.count == receiptsBeforeCanvas)
        #expect(deniedEngine.loop.approvalGate?.policy(for: "file_read") == .deny)
        await Task.yield()
    }
}
