import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

/// P3-P1-03(a)（lane QODER-DEV-W10-P1-03A-LIVE-SETTINGS-REAPPLY-149）：
/// 运行中提交的生产 Agent 设置必须在运行时真正生效，不要求重启。
/// 本文件钉住刷新缝的每个真实作用点：
/// · 迭代上限 → 引擎 AgentLoop 的 maxIterations（loop 每轮值拷贝，下一轮可见）；
/// · 并发上限 → 引擎 executorBox 的 ConcurrentToolLimitingExecutor 拆包/重包；
/// · 工具超时 → BuiltinToolExecutor.defaultShellTimeout（真实作用点本体）；
/// · fallback → productionFallbackEnabled + 逐轮 provider/turn 路由工厂的链形状。
/// 另含正向护栏：P3-CHILD-40（lane 142）的 childGovernor 生产接线在刷新后仍存续。
@Suite("Live settings re-apply (P3-P1-03(a) lane 149)")
@MainActor
struct LiveSettingsReapplyP103A149Tests {

    @Test func productionReattachmentKeepsTheSessionQuotaAndPendingLeaseOwner() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("budget-reattach-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = BridgeStore()
        defer { bridge.chat.stopAllStreamingForSafety() }
        await bridge.attachProductionServices(sessionDirectory: root, externalNetworkAllowed: false).value
        let chat = bridge.chat
        let sessionID = try #require(chat.activeSessionID)
        let tracker = chat.budgetTracker
        let first = try await tracker.beginRequest()
        _ = await tracker.completeRequest(first, usage: LLMUsage(inputTokens: 100, outputTokens: 2))
        await chat.syncBudgetStatus(for: sessionID)
        let pending = try await tracker.beginRequest()
        await bridge.attachProductionServices(sessionDirectory: root, externalNetworkAllowed: false).value
        #expect(chat.activeSessionID == sessionID && chat.budgetTracker === tracker)
        let engine = try #require(chat.agentEngine as? AgentLoopChatEngine)
        #expect(engine.requestBudget === tracker)
        _ = await tracker.completeRequest(pending, usage: LLMUsage(inputTokens: 3, outputTokens: 1))
        await chat.syncBudgetStatus(for: sessionID)
        #expect(chat.budgetUsedTokens == 106 && chat.budgetRequestCount == 2)
        #expect(await tracker.pendingRequestCount == 0)
    }

    @Test func tokenSettingsRefreshRetainsCurrentTrackerCountersAndOutstandingLease() async throws {
        let bridge = BridgeStore()
        let chat = bridge.chat
        let tracker = chat.budgetTracker
        let lease = try await tracker.beginRequest()
        bridge.refreshProductionAgentSettings(AgentSettings(maxTokensPerSession: 2))
        for _ in 0..<200 {
            if chat.requestBudget.maxTokensPerSession == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(chat.budgetTracker === tracker && chat.requestBudget.maxTokensPerSession == 2)
        _ = await tracker.completeRequest(lease, usage: LLMUsage(inputTokens: 7, outputTokens: 1))
        await chat.syncBudgetStatus(for: chat.activeSessionID)
        #expect(chat.requestBudget.usedTokens == 8 && chat.requestBudget.usedRequests == 1)
        #expect(chat.budgetIsOverLimit)
        bridge.refreshProductionAgentSettings(AgentSettings(maxTokensPerSession: 2, tokenBudgetUnlimited: true))
        for _ in 0..<200 {
            if chat.requestBudget.maxTokensPerSession == nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(chat.budgetTracker === tracker && chat.requestBudget.maxTokensPerSession == nil)
        #expect(chat.requestBudget.usedTokens == 8 && chat.requestBudget.usedRequests == 1)
        #expect(!chat.budgetIsOverLimit)
    }

    /// 两个内置聊天 Provider 走同一配置指纹与显式 Apply 路径。候选池必须
    /// 真正非空，才能检验开关刷新是否改变逐轮 fallback 路由。
    private func makeFallbackHarness(
        fallbackEnabled: Bool
    ) throws -> (bridge: BridgeStore, readinessDirectory: URL, sessionDirectory: URL) {
        let readinessDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniscanvas-p103a-149-readiness-\(UUID().uuidString)")
        let sessionDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniscanvas-p103a-149-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: readinessDirectory,
            withIntermediateDirectories: true
        )
        let store = ProviderReadinessStore(directory: readinessDirectory)
        var configuredRecords: [EnvVarEntry] = []
        for type in [ProviderType.anthropic, ProviderType.openAI] {
            let model = try #require(type.builtInModels.first)
            let route = try #require(ChatStore.BuiltinReadinessBinding.route(for: type))
            let configured = EnvVarEntry(
                name: type.rawValue.uppercased(),
                value: "fixture-key",
                isSecret: true,
                baseURL: route.baseURL,
                modelNames: [model.id],
                protocolType: route.wire
            )
            configuredRecords.append(configured)
            let checkedAt = Date()
            store.upsert(ProviderReadinessPersistenceRecord(
                providerID: type.rawValue,
                modelID: model.id,
                status: .passed,
                readinessState: .live,
                checkedAt: checkedAt,
                evidenceID: "live-settings:" + String(repeating: "a", count: 64),
                isApplied: false,
                configurationFingerprint: ChatStore.BuiltinReadinessBinding.fingerprint(
                    record: configured,
                    credentialRevision: "p103a-149-revision"
                ),
                expiresAt: checkedAt.addingTimeInterval(3600)
            ))
            #expect(store.applyDiscoveredModels(
                providerID: type.rawValue,
                modelIDs: [model.id],
                appliedAt: checkedAt
            ).map(\.modelID) == [model.id])
        }
        let bridge = BridgeStore(providerReadinessStore: store)
        bridge.attachProductionServices(
            agentSettings: AgentSettings(fallbackEnabled: fallbackEnabled),
            sessionDirectory: sessionDirectory,
            externalNetworkAllowed: true
        )
        bridge.chat.providerRecordsSource = { configuredRecords }
        bridge.chat.schedulerCredentialVersionSource = { _ in "p103a-149-revision" }
        return (bridge, readinessDirectory, sessionDirectory)
    }

    // MARK: - 1. 引擎层：迭代上限 / 并发门控就地刷新

    @Test("engine reapply moves iteration limit, unwraps then rewraps the concurrency gate")
    func engineReapplyUpdatesLoopAndConcurrencyGate() throws {
        let engine = AgentLoopChatEngine(
            maxIterations: 3,
            concurrentToolLimit: 2,
            toolTimeoutSeconds: 30,
            fallbackEnabled: false
        )
        #expect(engine.loop.maxIterations == 3)
        let attachedLimiter = try #require(
            engine.composedExecutor as? ConcurrentToolLimitingExecutor
        )
        #expect(attachedLimiter.maxConcurrent == 2)

        var narrowed = engine
        narrowed.reapplyRuntimeAgentSettings(AgentSettings(
            maxLoopIterations: 12,
            toolTimeoutSeconds: 90,
            concurrentToolLimit: 1,
            fallbackEnabled: true
        ))
        #expect(narrowed.loop.maxIterations == 12)
        #expect(narrowed.toolTimeoutSeconds == 90)
        #expect(narrowed.concurrentToolLimit == 1)
        #expect(narrowed.fallbackEnabled)
        // ≤1 回到直连 base，与构造期「nil/≤1 = 原样直连」语义一致。
        #expect(!(narrowed.composedExecutor is ConcurrentToolLimitingExecutor))
        #expect(narrowed.composedExecutor is BuiltinToolExecutor)

        var raised = narrowed
        raised.reapplyRuntimeAgentSettings(AgentSettings(
            maxLoopIterations: 12,
            toolTimeoutSeconds: 90,
            concurrentToolLimit: 5,
            fallbackEnabled: true
        ))
        let rewrapped = try #require(
            raised.composedExecutor as? ConcurrentToolLimitingExecutor
        )
        #expect(rewrapped.maxConcurrent == 5)
        // 重包必须包在同一个 base 上：连续刷新不得层层套娃。
        #expect(rewrapped.baseBox.value is BuiltinToolExecutor)
        #expect(
            !(rewrapped.baseBox.value is ConcurrentToolLimitingExecutor)
        )

        var loweredAgain = raised
        loweredAgain.reapplyRuntimeAgentSettings(AgentSettings(
            maxLoopIterations: 12,
            toolTimeoutSeconds: 90,
            concurrentToolLimit: 2,
            fallbackEnabled: true
        ))
        let swapped = try #require(
            loweredAgain.composedExecutor as? ConcurrentToolLimitingExecutor
        )
        #expect(swapped.maxConcurrent == 2)
        #expect(swapped.baseBox.value is BuiltinToolExecutor)
    }

    // MARK: - 2. BridgeStore 刷新缝：真实作用点被写入且身份不变

    @Test("refresh seam writes the live shell timeout, loop limit and gate")
    func bridgeRefreshWritesRealEffectPoints() throws {
        let bridge = BridgeStore()
        let sessionDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniscanvas-p103a-149-refresh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }
        bridge.attachProductionServices(sessionDirectory: sessionDirectory)

        let attachedExecutor = try #require(bridge.productionBuiltinToolExecutor)
        // AgentSettings 默认：toolTimeoutSeconds = 300、maxLoopIterations = 50、
        // concurrentToolLimit = 4（>1 → 装配期已包门控）。
        #expect(attachedExecutor.defaultShellTimeout == 120)
        let attachedEngine = try #require(
            bridge.chat.agentEngine as? AgentLoopChatEngine
        )
        #expect(attachedEngine.loop.maxIterations == 50)
        #expect(attachedEngine.composedExecutor is ConcurrentToolLimitingExecutor)

        bridge.refreshProductionAgentSettings(AgentSettings(
            maxLoopIterations: 42,
            toolTimeoutSeconds: 90,
            shellCommandTimeoutSeconds: 45,
            concurrentToolLimit: 1,
            fallbackEnabled: false
        ))

        // 超时真实作用点在同一个 executor 实例的 var 上被直写（不重建 executor）。
        #expect(bridge.productionBuiltinToolExecutor === attachedExecutor)
        #expect(attachedExecutor.defaultShellTimeout == 45)
        let refreshedEngine = try #require(
            bridge.chat.agentEngine as? AgentLoopChatEngine
        )
        #expect(refreshedEngine.loop.maxIterations == 42)
        #expect(refreshedEngine.toolTimeoutSeconds == 90)
        #expect(bridge.lastAgentSettingsReapplyReceipt?.shellCommandTimeoutSeconds == 45)
        #expect(refreshedEngine.concurrentToolLimit == 1)
        // 刷新缝只写 var，不更换 executor 身份（allowedRoot 按设计不可变；
        // 边界变更走 attachCurrentProductionConfiguration 组合缝重建）。
        #expect(
            bridge.productionBuiltinToolExecutor?.allowedRoot.path
                == attachedExecutor.allowedRoot.path
        )
        // 拆包后链首回到未包装的生产组合层（不再套门控），而非丢链。
        #expect(!(refreshedEngine.composedExecutor is ConcurrentToolLimitingExecutor))
    }

    // MARK: - 3. fallback：逐轮路由工厂读取实时开关

    @Test("fallback toggle flips the per-turn route factories without re-attachment")
    func fallbackToggleIsReadPerTurn() async throws {
        let harness = try makeFallbackHarness(fallbackEnabled: false)
        defer {
            try? FileManager.default.removeItem(at: harness.readinessDirectory)
            try? FileManager.default.removeItem(at: harness.sessionDirectory)
        }
        let bridge = harness.bridge
        let provider = try bridge.chat.activeProvider()
        let routeFactory = try #require(bridge.chat.providerRuntimeRouteFactory)
        // 冻结前提：装配期关闭 → 空链；而候选池本身非空（下方证伪 vacuity）。
        #expect(
            bridge.chat.providerRuntimeFallbackCandidates(
                excludingProviderID: provider.name
            ).count == 2
        )
        #expect(
            routeFactory(provider)?.snapshot.fallbackProviderIDs.isEmpty ?? false
        )

        bridge.refreshProductionAgentSettings(AgentSettings(
            maxLoopIterations: 10,
            toolTimeoutSeconds: 300,
            concurrentToolLimit: 4,
            fallbackEnabled: true
        ))
        #expect(bridge.productionFallbackEnabled)
        let opened = try #require(routeFactory(provider))
        #expect(opened.snapshot.fallbackProviderIDs.count == 2)

        // 同一 harness、无任何重新装配，再关回去。
        bridge.refreshProductionAgentSettings(AgentSettings(
            maxLoopIterations: 10,
            toolTimeoutSeconds: 300,
            concurrentToolLimit: 4,
            fallbackEnabled: false
        ))
        #expect(
            routeFactory(provider)?.snapshot.fallbackProviderIDs.isEmpty ?? false
        )

        // 逐轮 turn 快照工厂同样读取实时开关（不是构建期捕获的 enabled）。
        let snapshotFactory = try #require(bridge.chat.turnRuntimeSnapshotFactory)
        let capturedTurn = snapshotFactory(
            AgentTurnIdentity(
                sessionID: "p103a-149-live-fallback",
                turnID: 0,
                messageID: "p103a-149-live-fallback-message"
            ),
            provider
        )
        let turn = try #require(await capturedTurn.preparedForExecution())
        #expect(turn.providerRuntimeRouteError == nil)
        let closedTurnRoute = try #require(turn.providerRuntimeRoute)
        #expect(closedTurnRoute.snapshot.fallbackProviderIDs.isEmpty)

        bridge.refreshProductionAgentSettings(AgentSettings(
            maxLoopIterations: 10,
            toolTimeoutSeconds: 300,
            concurrentToolLimit: 4,
            fallbackEnabled: true
        ))
        let reopenedCapture = snapshotFactory(
            AgentTurnIdentity(
                sessionID: "p103a-149-live-fallback-2",
                turnID: 0,
                messageID: "p103a-149-live-fallback-message-2"
            ),
            provider
        )
        let reopenedTurn = try #require(await reopenedCapture.preparedForExecution())
        #expect(reopenedTurn.providerRuntimeRouteError == nil)
        let openedTurnRoute = try #require(reopenedTurn.providerRuntimeRoute)
        #expect(openedTurnRoute.snapshot.fallbackProviderIDs.count == 2)
    }

    // MARK: - 4. lane 142 回归护栏：刷新不得掉 childGovernor 接线

    @Test("refresh keeps the P3-CHILD-40 production governor wiring intact")
    func refreshKeepsChildGovernorWiring() async throws {
        let bridge = BridgeStore()
        let sessionDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniscanvas-p103a-149-governor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }
        bridge.attachProductionServices(
            sessionDirectory: sessionDirectory,
            enableOrchestration: true
        )
        let attachedGovernor = try #require(bridge.orchestrationChildGovernor)
        let attachedBudget = await attachedGovernor.globalBudget

        bridge.refreshProductionAgentSettings(AgentSettings(
            maxLoopIterations: 30,
            toolTimeoutSeconds: 60,
            concurrentToolLimit: 2,
            fallbackEnabled: false
        ))

        let pinnedGovernor = try #require(bridge.orchestrationChildGovernor)
        #expect(pinnedGovernor === attachedGovernor)
        let afterRefreshBudget = await pinnedGovernor.globalBudget
        #expect(afterRefreshBudget == attachedBudget)
        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        // 引擎仍是同一个 orchestration 组合（刷新只换数值，不拆能力）。
        #expect(engine.hasOrchestrationCapability)
        #expect(engine.loop.maxIterations == 30)
    }

    // MARK: - 5. 默认 Provider/模型：运行中重放保留既有守卫语义

    @Test("default provider/model live re-apply keeps the explicit-selection guard")
    func defaultProviderModelReapplyRespectsExplicitSelection() throws {
        let chat = ChatStore()
        let anthropicModel = try #require(ProviderType.anthropic.builtInModels.first)
        let general = GeneralSettings(
            defaultProviderID: ProviderType.anthropic.rawValue,
            defaultModelID: anthropicModel.id
        )
        #expect(chat.applyDefaultProviderModel(general: general))
        #expect(chat.selectedProviderType == .anthropic)
        #expect(chat.selectedModelID == anthropicModel.id)

        // 显式选择（实时 picker 的同型写入）之后，重放新的默认值不得覆盖它 ——
        // MinisCanvasApp 的运行中重放调用因此与启动一次性应用共享同一优先级链。
        chat.selectedModelID = "explicit-model-\(UUID().uuidString)"
        let openAIModel = try #require(ProviderType.openAI.builtInModels.first)
        let rerun = GeneralSettings(
            defaultProviderID: ProviderType.openAI.rawValue,
            defaultModelID: openAIModel.id
        )
        #expect(!chat.applyDefaultProviderModel(general: rerun))
        #expect(chat.selectedProviderType == .anthropic)
        #expect(chat.selectedModelID != openAIModel.id)
    }

    // MARK: - 6. 回执缝（149B 补齐）：运行中生效不得静默

    @Test("refresh and re-attach emit monotonic receipts, never a silent path")
    func reapplyEmitsMonotonicReceipts() async throws {
        let bridge = BridgeStore()
        let sessionDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniscanvas-p103a-149b-receipt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }
        #expect(bridge.lastAgentSettingsReapplyReceipt == nil)

        bridge.attachProductionServices(sessionDirectory: sessionDirectory)
        let initial = try #require(bridge.lastAgentSettingsReapplyReceipt)
        #expect(initial.source == .initialAttach)
        // AgentSettings.default：maxLoopIterations = 50、toolTimeoutSeconds = 300、
        // concurrentToolLimit = 4、fallbackEnabled = false（跨供应商自动回退默认关闭，2026-11-16）。
        #expect(initial.maxLoopIterations == 50)
        #expect(initial.toolTimeoutSeconds == 300)
        #expect(initial.concurrentToolLimit == 4)
        #expect(!initial.fallbackEnabled)

        bridge.refreshProductionAgentSettings(AgentSettings(
            maxLoopIterations: 42,
            toolTimeoutSeconds: 45,
            concurrentToolLimit: 1,
            fallbackEnabled: false
        ))
        let refreshed = try #require(bridge.lastAgentSettingsReapplyReceipt)
        #expect(refreshed.source == .runtimeRefresh)
        #expect(refreshed.generation == initial.generation + 1)
        #expect(refreshed.maxLoopIterations == 42)
        #expect(refreshed.toolTimeoutSeconds == 45)
        #expect(refreshed.concurrentToolLimit == 1)
        #expect(!refreshed.fallbackEnabled)

        // 文件访问边界变更走的组合缝重建（MinisCanvasApp 运行时缝即调用它）同样
        // 必须留下回执 —— 重建是显式事件，不是静默 reset。
        await bridge.attachProductionServices(sessionDirectory: sessionDirectory).value
        let reattached = try #require(bridge.lastAgentSettingsReapplyReceipt)
        #expect(reattached.source == .compositionReattach)
        #expect(reattached.generation == refreshed.generation + 1)

        // 代号单调递增、永不重置：任何后续刷新不复用旧代号。
        bridge.refreshProductionAgentSettings(.default)
        let final = try #require(bridge.lastAgentSettingsReapplyReceipt)
        #expect(final.generation == reattached.generation + 1)
        #expect(final.source == .runtimeRefresh)
        #expect(!final.fallbackEnabled)
    }

    // MARK: - 7. 正向存续护栏（149B）：childGovernor 注入与 Kill Switch 调和缝在重施后仍存续
    //
    // C0 派工缺陷曾让 149/150 两条线并发写 BridgeStore.swift。lane 150 的已接受
    // 工作（ecc984c82）把共享 governor 的 Kill Switch 调和挂在
    // updateSafetyRuntimeSnapshot 观察缝与 attach 上。本测试正向钉住：
    // · lane 142 的 childGovernor 生产注入（orchestrationChildGovernor）在
    //   刷新、安全态切换、以及重新组合后必须原样存续；
    // · updateSafetyRuntimeSnapshot 仍是唯一的 Kill Switch 观察缝，重施缝
    //   不得重置/绕过它；
    // · governor 的 checkpoint()/killSwitchEngaged 面可达（lane 150 的调和
    //   正是驱动这些既有算子）。
    // 为兼容"本补丁单独存在"与"已与 lane 150 合流"两种树，此处只断言 governor
    // 身份存续与安全缝仍被如实反映，不静态引用 reconcileChildGovernorKillSwitch
    // （它不在本基座头上），也不断言 governor 内部 engage 结果（那是 150 的
    // 异步收敛行为）。这保证本线的任何重施/重建路径都不可能静默拆掉 150 的接线。
    @Test("re-apply keeps childGovernor injection and the kill-switch reconcile seam alive")
    func reapplyPreservesGovernorKillSwitchSeam() async throws {
        let bridge = BridgeStore()
        let sessionDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniscanvas-p103a-149b-governor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }
        bridge.attachProductionServices(
            sessionDirectory: sessionDirectory,
            enableOrchestration: true
        )
        let governor = try #require(bridge.orchestrationChildGovernor)
        let attachedCheckpoint = await governor.checkpoint()
        #expect(!attachedCheckpoint.killSwitchEngaged)
        #expect(attachedCheckpoint.globalActive == 0)

        // Kill Switch 观察缝：提交后 safetyRuntimeSnapshot 必须如实反映，
        // 且 governor 身份不因安全态切换被拆除。
        let transitionReceipt = bridge.updateSafetyRuntimeSnapshot(
            SafetyRuntimeSnapshot(safeModeEnabled: false, killSwitchEnabled: true)
        )
        #expect(transitionReceipt.generation >= 1)
        #expect(bridge.safetyRuntimeSnapshot.killSwitchEnabled)
        #expect(bridge.orchestrationChildGovernor === governor)

        // 刷新缝不得掉 governor 接线，也不得丢回执轨。
        bridge.refreshProductionAgentSettings(AgentSettings(
            maxLoopIterations: 20,
            toolTimeoutSeconds: 75,
            concurrentToolLimit: 3,
            fallbackEnabled: true
        ))
        let afterRefreshGovernor = try #require(bridge.orchestrationChildGovernor)
        #expect(afterRefreshGovernor === governor)
        let midCheckpoint = await afterRefreshGovernor.checkpoint()
        #expect(midCheckpoint.globalActive == attachedCheckpoint.globalActive)
        let refreshedReceipt = try #require(bridge.lastAgentSettingsReapplyReceipt)
        #expect(refreshedReceipt.source == .runtimeRefresh)
        #expect(refreshedReceipt.maxLoopIterations == 20)
        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        #expect(engine.hasOrchestrationCapability)
        #expect(engine.loop.maxIterations == 20)

        // 恢复默认安全态：缝仍可用，governor 与引擎组合身份依旧。
        bridge.updateSafetyRuntimeSnapshot(.defaults)
        #expect(!bridge.safetyRuntimeSnapshot.killSwitchEnabled)
        #expect(bridge.orchestrationChildGovernor === governor)
        #expect(
            bridge.chat.agentEngine is AgentLoopChatEngine
        )
    }
}
