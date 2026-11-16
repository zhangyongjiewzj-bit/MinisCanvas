import Testing
import Foundation
@testable import MinisCore
@testable import MinisCanvasApp

private actor FallbackRouteWorkerBarrier {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var cancelledAfterRelease = false

    func pause() async {
        entered = true
        for waiter in enteredWaiters { waiter.resume() }
        enteredWaiters.removeAll()
        await withCheckedContinuation { releaseWaiter = $0 }
        cancelledAfterRelease = Task.isCancelled
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func observedCancellation() -> Bool { cancelledAfterRelease }
}

@Suite("Production orchestration wiring")
@MainActor
struct ProductionOrchestrationWiringTests {
    @Test func defaultProductionCompositionKeepsOrchestrationDisabled() async {
        let bridge = BridgeStore()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniscanvas-orchestration-default-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        bridge.attachProductionServices(sessionDirectory: dir)
        #expect(!bridge.orchestrationEnabled)
        guard let engine = bridge.chat.agentEngine as? AgentLoopChatEngine else {
            Issue.record("生产默认引擎不是 AgentLoopChatEngine")
            return
        }
        #expect(engine.hasOrchestrationCapability == false)
        do {
            _ = try await engine.composedExecutor.execute(
                name: OrchestrationToolExecutor.toolName,
                input: ["input_version": OrchestrationToolExecutor.inputVersion, "tasks": []]
            )
            Issue.record("默认生产链不应调度 orchestrate")
        } catch {
            // Disabled-by-default must fail closed before a child run is created.
        }
    }

    @Test func appProductionCompositionEnablesOrchestrationByDefault() async throws {
        let bridge = BridgeStore()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniscanvas-orchestration-app-default-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        ProductionOrchestrationDefaults.attachProductionServices(
            to: bridge,
            sessionDirectory: dir
        )

        #expect(bridge.orchestrationEnabled)
        #expect(bridge.orchestrationTaskStore === bridge.agentTaskStore)
        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        #expect(engine.hasOrchestrationCapability)
        let output = try await engine.composedExecutor.execute(
            name: OrchestrationToolExecutor.toolName,
            input: ["input_version": OrchestrationToolExecutor.inputVersion, "tasks": []]
        )
        let payload = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let version = try JSONDecoder().decode(Int.self, from: JSONSerialization.data(
            withJSONObject: try #require(payload["version"]), options: .fragmentsAllowed))
        let results = try #require(payload["results"] as? [Any])
        #expect(Set(payload.keys) == ["version", "results"] && version == 1 && results.isEmpty)
    }

    @Test("production Mock route carries deterministic intrinsic readiness provenance")
    func productionMockRouteCarriesIntrinsicReadinessProvenance() throws {
        let bridge = BridgeStore()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniscanvas-mock-route-provenance-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        ProductionOrchestrationDefaults.attachProductionServices(
            to: bridge,
            sessionDirectory: directory
        )

        let provider = try bridge.chat.activeProvider()
        #expect((provider as? MockProvider) === MockProvider.shared)
        let factory = try #require(bridge.chat.turnRuntimeSnapshotFactory)
        let first = factory(
            AgentTurnIdentity(sessionID: "mock-route-1", turnID: 0, messageID: "message-1"),
            provider
        )
        let second = factory(
            AgentTurnIdentity(sessionID: "mock-route-2", turnID: 0, messageID: "message-2"),
            provider
        )
        let firstRoute = try #require(first.providerRuntimeRoute)
        let secondRoute = try #require(second.providerRuntimeRoute)

        #expect(first.providerRuntimeRouteError == nil)
        #expect(firstRoute.snapshot.providerID == "Mock")
        #expect(firstRoute.snapshot.modelID == "mock-echo")
        #expect(firstRoute.snapshot.readinessEvidenceID == "builtin-mock:readiness:v1")
        #expect(
            firstRoute.snapshot.applyReceiptID
                == "provider-readiness-apply:builtin-mock:readiness:v1"
        )
        #expect(firstRoute.snapshot.hasReadinessEvidence)
        #expect(
            secondRoute.snapshot.readinessEvidenceID
                == firstRoute.snapshot.readinessEvidenceID
        )
        #expect(secondRoute.snapshot.applyReceiptID == firstRoute.snapshot.applyReceiptID)
    }

    @Test("production attachment keeps the built-in Mock route offline")
    func productionAttachmentKeepsOfflineMockRoute() throws {
        let bridge = BridgeStore()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniscanvas-offline-mock-route-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        bridge.attachProductionServices(
            agentSettings: AgentSettings(fallbackEnabled: true),
            sessionDirectory: directory,
            externalNetworkAllowed: false
        )

        let provider = try bridge.chat.activeProvider()
        #expect((provider as? MockProvider) === MockProvider.shared)
        let routeFactory = try #require(bridge.chat.providerRuntimeRouteFactory)
        let route = try #require(routeFactory(provider))
        #expect(route.snapshot.providerID == "Mock")
        #expect(route.snapshot.hasReadinessEvidence)
        #expect(route.snapshot.fallbackProviderIDs.isEmpty)

        let snapshotFactory = try #require(bridge.chat.turnRuntimeSnapshotFactory)
        let snapshot = snapshotFactory(
            AgentTurnIdentity(
                sessionID: "offline-mock-route",
                turnID: 0,
                messageID: "offline-mock-message"
            ),
            provider
        )
        #expect(snapshot.providerRuntimeRoute != nil)
        #expect(snapshot.providerRuntimeRouteError == nil)
    }

    // MARK: - P3-P1-05 verification half: the production fallback chain

    /// Positive half of the `fallbackEnabled` gate at the real production
    /// builder (`BridgeStore.makeProviderRuntimeRouteBuilder`, reached through
    /// the `providerRuntimeRouteFactory` / `turnRuntimeSnapshotFactory`
    /// closures that `attachProductionServices` installs). The offline
    /// negative gate above only proves an empty chain when the network is
    /// barred; nothing pinned the case where the setting is on, the network
    /// is allowed, and two Providers really are eligible.
    @Test("production fallback-enabled builder freezes a non-empty ordered chain")
    func productionAttachmentBuildsOrderedFallbackChain() async throws {
        let harness = try makeFallbackChainHarness(fallbackEnabled: true)
        defer {
            try? FileManager.default.removeItem(at: harness.directory)
            try? FileManager.default.removeItem(at: harness.sessionDirectory)
        }
        let bridge = harness.bridge
        let expectedChain = [
            ProviderType.anthropic.runtimeProviderID,
            ProviderType.openAI.runtimeProviderID
        ]

        let provider = try bridge.chat.activeProvider()
        #expect((provider as? MockProvider) === MockProvider.shared)
        // Eligibility must be proven before the gate is consulted, otherwise
        // an empty chain would be vacuous. Two applied Providers are visible
        // to the picker projection the builder consumes.
        #expect(
            bridge.chat.providerRuntimeFallbackCandidates(
                excludingProviderID: provider.name
            ).map(\.providerID) == expectedChain
        )

        let routeFactory = try #require(bridge.chat.providerRuntimeRouteFactory)
        let route = try #require(routeFactory(provider))
        let chain = route.snapshot.fallbackProviderIDs
        #expect(route.snapshot.providerID == "Mock")
        #expect(route.snapshot.hasReadinessEvidence)
        #expect(chain == expectedChain)
        #expect(!chain.isEmpty)
        #expect(!chain.contains(provider.name))
        // The requirement's ordering is the builder's own contract: the
        // primary is excluded and the survivors keep case-insensitive
        // ascending provider order.
        #expect(chain == chain.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        })
        #expect(route.snapshot.hasCompleteFallbackProvenance)
        #expect(route.snapshot.fallbackProvenance.map(\.providerID) == expectedChain)
        #expect(route.snapshot.fallbackProvenance.map(\.modelID) == [
            harness.anthropicModelID,
            harness.openAIModelID
        ])
        #expect(route.snapshot.fallbackProvenance.map(\.readinessEvidenceID) == [
            "anthropic-fallback-pin",
            "openai-fallback-pin"
        ])

        let snapshotFactory = try #require(bridge.chat.turnRuntimeSnapshotFactory)
        let turn = snapshotFactory(
            AgentTurnIdentity(
                sessionID: "fallback-chain-positive",
                turnID: 0,
                messageID: "fallback-chain-positive-message"
            ),
            provider
        )
        #expect(turn.providerRuntimeRouteError == nil)
        #expect(turn.providerRuntimeRoute == nil)
        let preparation = try #require(turn.providerRuntimeRoutePreparation)
        let turnRoute: ProviderRuntimeRoute
        switch await preparation.value {
        case .success(let route): turnRoute = route
        case .failure(let error):
            Issue.record("fallback preparation failed: \(error)")
            return
        }
        #expect(turnRoute.snapshot.fallbackProviderIDs == chain)
        #expect(turnRoute.snapshot.fallbackProvenance == route.snapshot.fallbackProvenance)
    }

    @Test("cancelling a real fallback route stops its detached preparation")
    func cancelledFallbackRouteCancelsWorkerWithoutBlockingMainActor() async throws {
        let harness = try makeFallbackChainHarness(fallbackEnabled: true)
        defer {
            try? FileManager.default.removeItem(at: harness.directory)
            try? FileManager.default.removeItem(at: harness.sessionDirectory)
        }
        let bridge = harness.bridge
        let barrier = FallbackRouteWorkerBarrier()
        bridge.providerRuntimeFallbackPauseForTests = { await barrier.pause() }
        let provider = try bridge.chat.activeProvider()
        let snapshotFactory = try #require(bridge.chat.turnRuntimeSnapshotFactory)
        let turn = snapshotFactory(AgentTurnIdentity(
            sessionID: "fallback-cancel-2325", turnID: 0,
            messageID: "fallback-cancel-2325-message"
        ), provider)
        let preparation = try #require(turn.providerRuntimeRoutePreparation)
        await barrier.waitUntilEntered()
        // A blocked provider-preparation worker must leave UI work runnable.
        let heartbeat = Task { @MainActor in 1 }
        #expect(await heartbeat.value == 1)

        preparation.cancel()
        await barrier.release()
        let result = await preparation.value
        #expect(await barrier.observedCancellation())
        switch result {
        case .success:
            Issue.record("cancelled fallback preparation published a route")
        case .failure(let error):
            #expect(error == .missingPrimaryProvenance)
        }
    }

    @Test("Responses fallback route is prepared after the turn factory returns")
    func responsesFallbackUsesFrozenAsyncRoute() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("responses-fallback-775-\(UUID().uuidString)")
        let readinessDirectory = root.appendingPathComponent("readiness")
        let sessionDirectory = root.appendingPathComponent("sessions")
        let checkpointDirectory = root.appendingPathComponent("checkpoints")
        try FileManager.default.createDirectory(
            at: readinessDirectory, withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: checkpointDirectory, withIntermediateDirectories: true
        )
        OpenAIResponsesProvider.attemptCheckpointDirectoryOverride = checkpointDirectory
        defer {
            OpenAIResponsesProvider.attemptCheckpointDirectoryOverride = nil
            try? FileManager.default.removeItem(at: root)
        }
        let type = ProviderType.openAIResponses
        let model = try #require(type.builtInModels.first)
        let record = EnvVarEntry(
            name: type.rawValue,
            value: "",
            baseURL: "https://api.openai.com/v1",
            modelNames: [model.id],
            protocolType: .openaiResponses
        )
        let revision = "responses-fallback-775-revision"
        let store = ProviderReadinessStore(directory: readinessDirectory)
        upsertAppliedReadiness(
            into: store, providerID: type.rawValue, modelID: model.id,
            evidenceID: "responses-fallback-775-pin",
            configurationFingerprint: ChatStore.BuiltinReadinessBinding.fingerprint(
                record: record, credentialRevision: revision
            )
        )
        let bridge = BridgeStore(providerReadinessStore: store)
        bridge.chat.providerRecordsSource = { [record] in [record] }
        bridge.chat.schedulerCredentialVersionSource = { name in
            name == record.name ? revision : nil
        }
        bridge.attachProductionServices(
            agentSettings: AgentSettings(fallbackEnabled: true),
            sessionDirectory: sessionDirectory,
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json")),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            externalNetworkAllowed: true
        )
        let primary = try bridge.chat.activeProvider()
        #expect((primary as? MockProvider) === MockProvider.shared)
        #expect(bridge.chat.providerRuntimeFallbackCandidates(
            excludingProviderID: primary.name
        ).map(\.providerID) == [type.runtimeProviderID])
        let factory = try #require(bridge.chat.turnRuntimeSnapshotFactory)
        let turn = factory(AgentTurnIdentity(
            sessionID: "responses-fallback-775", turnID: 0,
            messageID: "responses-fallback-775-message"
        ), primary)
        #expect(turn.providerRuntimeRoute == nil)
        #expect(turn.providerRuntimeRouteError == nil)
        let preparation = try #require(turn.providerRuntimeRoutePreparation)
        let route: ProviderRuntimeRoute
        switch await preparation.value {
        case .success(let value): route = value
        case .failure(let error):
            Issue.record("Responses fallback route failed: \(error)")
            return
        }
        #expect(route.snapshot.providerID == "Mock")
        #expect(route.snapshot.fallbackProviderIDs == [type.runtimeProviderID])
        #expect(route.snapshot.fallbackProvenance.map(\.readinessEvidenceID)
            == ["responses-fallback-775-pin"])
        #expect(route.snapshot.hasCompleteFallbackProvenance)
    }

    /// Negative half pinned at the SAME builder with the SAME eligible pool:
    /// only `AgentSettings.fallbackEnabled` differs, so an empty chain here
    /// can come from the flag and not from the network gate or from missing
    /// readiness. Dropping `enabled &&` at BridgeStore.swift:1213 would turn
    /// this test red.
    @Test("production builder yields an empty chain when fallback is disabled")
    func productionAttachmentBuildsEmptyChainWhenFallbackDisabled() throws {
        let harness = try makeFallbackChainHarness(fallbackEnabled: false)
        defer {
            try? FileManager.default.removeItem(at: harness.directory)
            try? FileManager.default.removeItem(at: harness.sessionDirectory)
        }
        let bridge = harness.bridge

        let provider = try bridge.chat.activeProvider()
        #expect((provider as? MockProvider) === MockProvider.shared)
        #expect(
            bridge.chat.providerRuntimeFallbackCandidates(
                excludingProviderID: provider.name
            ).count == 2
        )

        let routeFactory = try #require(bridge.chat.providerRuntimeRouteFactory)
        let route = try #require(routeFactory(provider))
        #expect(route.snapshot.providerID == "Mock")
        #expect(route.snapshot.hasReadinessEvidence)
        #expect(route.snapshot.fallbackProviderIDs.isEmpty)
        #expect(route.snapshot.fallbackProvenance.isEmpty)

        let snapshotFactory = try #require(bridge.chat.turnRuntimeSnapshotFactory)
        let turn = snapshotFactory(
            AgentTurnIdentity(
                sessionID: "fallback-chain-negative",
                turnID: 0,
                messageID: "fallback-chain-negative-message"
            ),
            provider
        )
        #expect(turn.providerRuntimeRouteError == nil)
        let turnRoute = try #require(turn.providerRuntimeRoute)
        #expect(turnRoute.snapshot.fallbackProviderIDs.isEmpty)
    }

    /// Two built-in chat Providers carry an applied, selectable readiness
    /// record bound to synthetic configuration/revision facts on their first
    /// built-in model, as `ChatStore.providerRuntimeFallbackCandidates` demands.
    /// Built-ins are used deliberately: a custom record needs a credential at
    /// `makeCustomProvider`, and that failure would silently shrink the
    /// chain instead of exercising the gate.
    private func makeFallbackChainHarness(
        fallbackEnabled: Bool
    ) throws -> (
        bridge: BridgeStore,
        directory: URL,
        sessionDirectory: URL,
        anthropicModelID: String,
        openAIModelID: String
    ) {
        let readinessDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniscanvas-fallback-pin-readiness-\(UUID().uuidString)")
        let sessionDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniscanvas-fallback-pin-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: readinessDirectory,
            withIntermediateDirectories: true
        )
        let anthropicModel = try #require(ProviderType.anthropic.builtInModels.first)
        let openAIModel = try #require(ProviderType.openAI.builtInModels.first)

        // Reuse the configured built-in readiness contract without loading
        // credentials or probing either endpoint. These values are metadata.
        let credentialRevision = "fallback-fixture-revision"
        let anthropicRecord = EnvVarEntry(
            name: ProviderType.anthropic.rawValue,
            value: "",
            baseURL: "https://api.anthropic.com/v1",
            modelNames: [anthropicModel.id],
            protocolType: .anthropic
        )
        let openAIRecord = EnvVarEntry(
            name: ProviderType.openAI.rawValue,
            value: "",
            baseURL: "https://api.openai.com/v1",
            modelNames: [openAIModel.id],
            protocolType: .openaiCompatible
        )
        let records = [anthropicRecord, openAIRecord]
        let store = ProviderReadinessStore(directory: readinessDirectory)
        upsertAppliedReadiness(
            into: store,
            providerID: ProviderType.anthropic.rawValue,
            modelID: anthropicModel.id,
            evidenceID: "anthropic-fallback-pin",
            configurationFingerprint: ChatStore.BuiltinReadinessBinding.fingerprint(
                record: anthropicRecord,
                credentialRevision: credentialRevision
            )
        )
        upsertAppliedReadiness(
            into: store,
            providerID: ProviderType.openAI.rawValue,
            modelID: openAIModel.id,
            evidenceID: "openai-fallback-pin",
            configurationFingerprint: ChatStore.BuiltinReadinessBinding.fingerprint(
                record: openAIRecord,
                credentialRevision: credentialRevision
            )
        )

        let bridge = BridgeStore(providerReadinessStore: store)
        bridge.chat.providerRecordsSource = { records }
        bridge.chat.schedulerCredentialVersionSource = { providerID in
            records.contains { $0.name.caseInsensitiveCompare(providerID) == .orderedSame }
                ? credentialRevision : nil
        }
        bridge.attachProductionServices(
            agentSettings: AgentSettings(fallbackEnabled: fallbackEnabled),
            sessionDirectory: sessionDirectory,
            externalNetworkAllowed: true
        )
        return (
            bridge,
            readinessDirectory,
            sessionDirectory,
            anthropicModel.id,
            openAIModel.id
        )
    }

    private func upsertAppliedReadiness(
        into store: ProviderReadinessStore,
        providerID: String,
        modelID: String,
        evidenceID: String,
        configurationFingerprint: String
    ) {
        store.upsert(ProviderReadinessPersistenceRecord(
            providerID: providerID,
            modelID: modelID,
            status: .passed,
            readinessState: .mock,
            checkedAt: Date(timeIntervalSince1970: 1_787_200_000),
            evidenceID: evidenceID,
            isApplied: true,
            configurationFingerprint: configurationFingerprint
        ))
    }

    @Test("runtime production orchestration preserves the absolute parent deadline")
    func runtimeProductionOrchestratorReceivesAbsoluteDeadline() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("r35e-app-deadline-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AgentTaskStore()
        let bridge = BridgeStore(agentTaskStore: store)
        bridge.attachProductionServices(
            sessionDirectory: directory,
            enableOrchestration: true
        )
        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let provider = CountingContextProvider(
            model: LLMModel(
                id: "r35e-app-deadline-model",
                displayName: "R35/E App Deadline",
                provider: "r35e-app-deadline-provider"
            )
        )
        let turnController = TurnController()
        let parentTurn = await turnController.beginTurn()
        defer {
            Task { await parentTurn.finish() }
        }
        let conversationID = "r35e-app-deadline-conversation"
        let parentBinding = ParentContextSnapshotV1(
            providerID: provider.name,
            modelID: provider.model.id,
            configurationFingerprint: "r35e-app-deadline-fingerprint",
            conversationID: conversationID
        )
        let parentIdentity = ParentRuntimeIdentity(
            sessionID: conversationID,
            conversationID: conversationID,
            turnID: "turn-handle:\(parentTurn.turnID)",
            taskID: "r35e-app-deadline-parent",
            actorID: "app"
        )
        let context = AgentExecutionContextSnapshot(
            provider: provider,
            approvalGate: nil,
            turnController: turnController,
            currentConversationID: conversationID,
            makeChildBudget: nil,
            deadline: Date().addingTimeInterval(-1),
            taskStore: store,
            parentBinding: parentBinding,
            parentTurnHandle: parentTurn,
            parentRuntimeIdentity: parentIdentity
        )

        let output = try await AgentExecutionContext.$current.withValue(context) {
            try await engine.composedExecutor.execute(
                name: OrchestrationToolExecutor.toolName,
                input: [
                    "input_version": OrchestrationToolExecutor.inputVersion,
                    "strategy": "sequential",
                    "tasks": [[
                        "id": "r35e-app-deadline-child",
                        "title": "expired deadline",
                        "instructions": "must not call provider",
                    ]],
                ]
            )
        }

        #expect(output.contains("DEADLINE_EXCEEDED"))
        #expect(provider.calls == 0)
    }

    @Test func appProductionCompositionAcceptsJSONBridgedIntegerVersion() async throws {
        let bridge = BridgeStore()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniscanvas-orchestration-json-int-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        ProductionOrchestrationDefaults.attachProductionServices(
            to: bridge,
            sessionDirectory: dir
        )

        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let output = try await engine.composedExecutor.execute(
            name: OrchestrationToolExecutor.toolName,
            input: ["input_version": Int64(OrchestrationToolExecutor.inputVersion), "tasks": []]
        )
        let payload = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let version = try JSONDecoder().decode(Int.self, from: JSONSerialization.data(
            withJSONObject: try #require(payload["version"]), options: .fragmentsAllowed))
        let results = try #require(payload["results"] as? [Any])
        #expect(Set(payload.keys) == ["version", "results"] && version == 1 && results.isEmpty)
    }

    @Test(arguments: [false, true])
    func productionCompositionScopesDurableTurnContextToSessionDirectory(foreignSettingsOwnerPresent: Bool) async throws {
        try await runDurableContextFixture(foreignSettingsOwnerPresent: foreignSettingsOwnerPresent,
            bindOwnedSettings: true)
    }

    @Test func productionContextRejectsForeignSettingsOwnerBeforeProviderCall() async throws {
        try await runDurableContextFixture(foreignSettingsOwnerPresent: true, bindOwnedSettings: false)
    }

    private func runDurableContextFixture(foreignSettingsOwnerPresent: Bool, bindOwnedSettings: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniscanvas-turn-context-scope-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let providerID = "turn-context-scope-provider"
        let modelID = "turn-context-scope-model"
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        var readinessPersistenceError: Error?
        let readinessStore = ProviderReadinessStore(
            directory: directory,
            onPersistError: { readinessPersistenceError = $0 }
        )
        let readinessAccepted = readinessStore.upsert([
            ProviderReadinessPersistenceRecord(
                providerID: providerID,
                modelID: modelID,
                status: .passed,
                readinessState: .mock,
                checkedAt: Date(timeIntervalSince1970: 1_000),
                evidenceID: "fixture-readiness-evidence",
                isApplied: true,
                discoveryReceiptID: "fixture-discovery-receipt",
                discoveredAt: Date(timeIntervalSince1970: 1_000),
                applyReceiptID: "provider-readiness-apply:fixture-apply-receipt",
                appliedAt: Date(timeIntervalSince1970: 1_001)
            )
        ])
        #expect(
            readinessAccepted,
            "readiness persistence failed: \(String(describing: readinessPersistenceError))"
        )
        let bridge = BridgeStore(
            agentTaskStore: AgentTaskStore(),
            providerReadinessStore: readinessStore
        )
        let attachment = bridge.attachProductionServices(
            sessionDirectory: directory,
            mcpManager: MCPServerManager(fileURL: directory.appendingPathComponent("mcps.json"))
        )
        await attachment.value
        let provider = CountingContextProvider(
            model: LLMModel(
                id: modelID,
                displayName: "Turn Context Scope",
                provider: providerID
            ),
            runtimeConfigurationMaterial: "turn-context-route-material"
        )
        // Model another profile's legitimate settings owner without reading user
        // configuration, then bind this fixture's own root for its positive path.
        let foreignSettings = foreignSettingsOwnerPresent
            ? try makeDurableContextSettingsOwner(directory: directory.appendingPathComponent("foreign-sessions"))
            : nil
        let ownedSettings = bindOwnedSettings ? try makeDurableContextSettingsOwner(directory: directory) : nil
        defer {
            withExtendedLifetime(ownedSettings) {}
            withExtendedLifetime(foreignSettings) {}
        }
        #expect(SettingsCenter.active === (ownedSettings ?? foreignSettings))
        let sessionID = try #require(bridge.chat.activeSessionID)
        let runtimeSnapshotFactory = try #require(bridge.chat.turnRuntimeSnapshotFactory)
        let runtimeSnapshot = runtimeSnapshotFactory(
            AgentTurnIdentity(
                sessionID: sessionID.uuidString,
                turnID: 0,
                messageID: "durable-context-diagnostic-probe"
            ),
            provider
        )
        #expect(runtimeSnapshot.providerRuntimeRouteError == nil)
        #expect(runtimeSnapshot.providerRuntimeRoute?.snapshot.providerID == providerID)
        #expect(runtimeSnapshot.providerRuntimeRoute?.snapshot.modelID == modelID)
        #expect(runtimeSnapshot.providerRuntimeRoute?.snapshot.readinessEvidenceID == "fixture-readiness-evidence")
        #expect(runtimeSnapshot.providerRuntimeRoute?.snapshot.applyReceiptID == "provider-readiness-apply:fixture-apply-receipt")
        let routeFingerprint = try #require(runtimeSnapshot.providerRuntimeRoute?.snapshot.configurationFingerprint)
        var foreignFailure: ChatTurnFailureObservationForTests?
        let previousFailureObserver = bridge.chat.turnFailureObserverForTests
        bridge.chat.turnFailureObserverForTests = { observation in
            previousFailureObserver?(observation)
            if observation.sessionID == sessionID, foreignFailure == nil {
                foreignFailure = observation
            }
        }
        defer { bridge.chat.turnFailureObserverForTests = previousFailureObserver }
        bridge.chat.streamingProviderOverride = provider
        bridge.chat.draftText = "write durable context"
        bridge.chat.sendDraft()
        let submittedIdentity = try #require(bridge.chat.activeExecutionIdentity(for: sessionID))

        let ledger = directory.appendingPathComponent("agent-turn-context-v1.json")
        var waited: TimeInterval = 0
        while (
            !FileManager.default.fileExists(atPath: ledger.path)
                || (try? Data(contentsOf: ledger))?.isEmpty == true
                || provider.calls == 0
        ), waited < 5 {
            try await Task.sleep(for: .milliseconds(25))
            waited += 0.025
        }

        let terminal = bridge.chat.executionSnapshot(forSessionID: sessionID)
        if bindOwnedSettings {
            #expect(terminal?.state != .failed)
            #expect(terminal?.failureReason == nil)
            #expect(provider.calls == 1)
            #expect(provider.receivedParentBinding?.configurationFingerprint == routeFingerprint)
            #expect(FileManager.default.fileExists(atPath: ledger.path))
        } else {
            // The real AgentLoop must reject the foreign-root capture, retaining
            // its canonical failure and zero actual provider/effect dispatch.
            #expect(terminal?.state == .failed)
            let failure = try #require(foreignFailure)
            #expect(failure.executionIdentity == submittedIdentity)
            #expect(failure.stage == .enginePreparation)
            #expect(failure.errorCaseName == "contextSettingsScopeMismatch")
            #expect(provider.calls == 0)
            #expect(provider.receivedParentBinding == nil)
            #expect(!FileManager.default.fileExists(atPath: ledger.path))
        }
        bridge.chat.stopStreaming()
    }

    private func makeDurableContextSettingsOwner(directory: URL) throws -> SettingsCenter {
        let profile = try RuntimeIsolationProfile.makeIsolatedTest(
            label: "production-orch-owned-context", processEnvironment: [:],
            processArguments: ["/tmp/MinisCanvasAppTests.xctest"], canvasRuntimeState: .disabled)
        let defaults = profile.makeUserDefaults()
        let keychain = profile.makeKeychainStore()
        return SettingsCenter(
            settingsStore: SettingsStore(directory: profile.settingsDirectory),
            envStore: EnvVarStore(directory: profile.providerConfigurationDirectory, keychain: keychain,
                privacyStore: EnvVarPrivacyStore(defaults: defaults)),
            memoryStore: MemoryStore(directory: profile.memoryDirectory),
            memoryFileStore: MemoryFileStore(directory: profile.rootDirectory.appendingPathComponent("memory-files")),
            sessionStore: SessionStore(directory: directory),
            sessionBadgeStore: SessionBadgeStore(directory: profile.rootDirectory.appendingPathComponent("badges")),
            logManager: profile.makeLogManager(),
            mcpManager: MCPServerManager(fileURL: profile.mcpConfigurationURL, keychain: keychain),
            skillStore: SkillStore(skillsRoot: profile.rootDirectory.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: profile.usageStoreDefaultsDomain),
            providerReadinessTransport: FailClosedProviderReadinessTransport(),
            providerReadinessDeployment: .mock,
            providerReadinessStore: ProviderReadinessStore(directory: profile.providerConfigurationDirectory))
    }

    @Test func explicitProductionCompositionExposesOrchestrationCapability() async throws {
        let bridge = BridgeStore()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniscanvas-orchestration-enabled-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        bridge.attachProductionServices(sessionDirectory: dir, enableOrchestration: true)
        #expect(bridge.orchestrationEnabled)
        guard let engine = bridge.chat.agentEngine as? AgentLoopChatEngine else {
            Issue.record("显式生产引擎不是 AgentLoopChatEngine")
            return
        }
        #expect(engine.hasOrchestrationCapability == true)
        let output: String? = try await engine.composedExecutor.execute(
            name: OrchestrationToolExecutor.toolName,
            input: ["input_version": OrchestrationToolExecutor.inputVersion, "tasks": []]
        )
        let raw = try #require(output)
        let payload = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let version = try JSONDecoder().decode(Int.self, from: JSONSerialization.data(
            withJSONObject: try #require(payload["version"]), options: .fragmentsAllowed))
        let results = try #require(payload["results"] as? [Any])
        #expect(Set(payload.keys) == ["version", "results"] && version == 1 && results.isEmpty,
            Comment(rawValue: "owned empty-tasks output=" + raw))
    }
    @Test func productionCompositionSharesCanonicalPersistentTaskStore() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniscanvas-agent-store-\(UUID().uuidString)", isDirectory: true)
        let ledger = root.appendingPathComponent("agent-ledger-v1.json")
        let sessionDirectory = root.appendingPathComponent("sessions", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bridge = try BridgeStore(
            taskStorePersistenceURL: ledger
        )
        bridge.attachProductionServices(
            sessionDirectory: sessionDirectory,
            enableOrchestration: true
        )

        guard let engine = bridge.chat.agentEngine as? AgentLoopChatEngine else {
            Issue.record("生产组合未创建 AgentLoopChatEngine")
            return
        }
        #expect(engine.loop.taskStore === bridge.agentTaskStore)
        #expect(bridge.orchestrationTaskStore === bridge.agentTaskStore)

        _ = try bridge.agentTaskStore.enqueue(
            taskID: "composition-task",
            parentID: "composition-parent",
            providerID: "offline",
            modelID: "test"
        )
        let restored = try AgentTaskStore(persistenceURL: ledger)
        #expect(restored.snapshot(taskID: "composition-task", parentID: "composition-parent")?.status == .queued)

        let restarted = try BridgeStore(taskStorePersistenceURL: ledger)
        #expect(restarted.agentTaskStore.snapshot(taskID: "composition-task", parentID: "composition-parent")?.status == .queued)
    }

    @Test func productionCompositionExposesReadOnlyTaskCenterObservation() {
        let bridge = BridgeStore()

        let observation = bridge.taskCenterObservation

        #expect(observation.totalTasks == 0)
        #expect(observation.projection.totalTasks == 0)
    }

    @Test func productionCompositionRoutesSlashReadsToCanonicalTaskStore() throws {
        let store = AgentTaskStore()
        let bridge = BridgeStore(agentTaskStore: store)
        _ = try store.enqueue(
            taskID: "production-slash-task",
            parentID: "production-parent",
            providerID: "offline",
            modelID: "test"
        )
        let before = store.taskCenterSnapshots()

        let output = bridge.executeTaskCenterSlashCommand("/tasks")
        let data = try #require(output.data(using: .utf8))
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try #require(root["payload"] as? [String: Any])
        let rows = try #require(payload["tasks"] as? [[String: Any]])

        #expect(root["ok"] as? Bool == true)
        #expect(rows.first?["task_id"] as? String == "production-slash-task")
        #expect(store.taskCenterSnapshots() == before)
    }

    @Test func productionOrchestrationRegistersCodexAndHermesRunnersWithoutStartingThem() async {
        let bridge = BridgeStore()
        await bridge.attachProductionServices(enableOrchestration: true).value

        #expect(bridge.productionExternalRunnerNames.contains("codex"))
        #expect(bridge.productionExternalRunnerNames.contains("hermes"))
        #expect(bridge.productionExternalRunnerNames.contains("claude"))
        #expect(bridge.productionExternalRunnerAvailability["codex"] != nil)
        #expect(bridge.productionExternalRunnerAvailability["hermes"] != nil)
    }

    @Test func productionCompositionPersistsContextManifestWithAgentLedger() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniscanvas-context-manifest-consumer-\(UUID().uuidString)")
        let ledger = directory.appendingPathComponent("agent-tasks-v1.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let bridge = try BridgeStore(taskStorePersistenceURL: ledger)
        let snapshot = ConversationContextSnapshotV1(
            sessionID: "a4-session",
            providerID: "offline",
            modelID: "a4-model",
            configurationFingerprint: "a4-configuration",
            skillIdentifiers: ["a4-skill"],
            conversationID: "a4-conversation"
        )
        let manifest = ContextManifest(
            snapshot: snapshot,
            entries: [
                .init(
                    identifier: "system",
                    tokenCost: 2,
                    scope: "conversation",
                    provenance: "a4-test",
                    contentHash: ContextItem.hash(content: "system", identifier: "system")
                )
            ]
        )
        let receipt = ContextManifestReceipt(
            runID: "a4-run",
            requestedBudget: 4,
            usedBudget: 2,
            droppedEntryIDs: []
        )

        #expect(try bridge.contextManifestStore.record(manifest: manifest, receipt: receipt) == receipt)

        let restarted = try BridgeStore(taskStorePersistenceURL: ledger)
        #expect(restarted.contextManifestStore.manifest(runID: receipt.runID) == manifest)
        #expect(restarted.contextManifestStore.receipt(runID: receipt.runID) == receipt)
    }

    @Test func contextConsumerRejectsProviderMismatchBeforeProviderCall() async throws {
        let provider = CountingContextProvider(
            model: LLMModel(id: "context-model", displayName: "Context", provider: "runtime")
        )
        let snapshot = ConversationContextSnapshotV1(
            sessionID: "context-session",
            providerID: "different",
            modelID: provider.model.id,
            configurationFingerprint: "config",
            skillIdentifiers: [],
            conversationID: "context-session"
        )
        let result = ContextOrchestrator().makeManifest(
            ContextOrchestrator.Input(
                snapshot: snapshot,
                contextItems: [
                    ContextItem(identifier: "system", content: "system", tokenCost: 1)
                ]
            ),
            budget: 2
        )
        let engine = AgentLoopChatEngine(
            contextManifestInput: .init(
                snapshot: snapshot,
                result: result,
                runID: "context-provider-mismatch"
            )
        )

        await #expect(throws: AgentLoopChatEngine.ContextManifestConsumptionError.providerMismatch) {
            _ = try await engine.streamReply(
                provider: provider,
                history: [.init(role: .user, content: "hello")],
                systemPrompt: "system",
                maxTokens: 8,
                conversationID: "context-session",
                authorizedSessionReadSessionID: nil,
                turnID: 1
            )
        }
        #expect(provider.calls == 0)
    }

    @Test func contextConsumerRejectsMalformedResultBeforeProviderCall() async throws {
        let provider = CountingContextProvider(
            model: LLMModel(id: "context-model", displayName: "Context", provider: "runtime")
        )
        let snapshot = ConversationContextSnapshotV1(
            sessionID: "context-session",
            providerID: "runtime",
            modelID: provider.model.id,
            configurationFingerprint: "config",
            skillIdentifiers: [],
            conversationID: "context-session"
        )
        let malformed = ContextOrchestrator.Result(
            manifest: .init(snapshotID: snapshot.snapshotID, entries: []),
            receipt: .init(
                requestedBudget: 0,
                usedBudget: 0,
                droppedEntryIDs: [],
                cacheDisposition: .notApplicable,
                rejection: nil
            )
        )
        let engine = AgentLoopChatEngine(
            contextManifestInput: .init(
                snapshot: snapshot,
                result: malformed,
                runID: "context-malformed"
            )
        )

        await #expect(throws: AgentLoopChatEngine.ContextManifestConsumptionError.rejected) {
            _ = try await engine.streamReply(
                provider: provider,
                history: [.init(role: .user, content: "hello")],
                systemPrompt: "system",
                maxTokens: 8,
                conversationID: "context-session",
                authorizedSessionReadSessionID: nil,
                turnID: 1
            )
        }
        #expect(provider.calls == 0)
    }

    @Test func contextConsumerRejectsInvalidExecutionIdentityBeforeProviderCall() async throws {
        let provider = CountingContextProvider(
            model: LLMModel(id: "context-model", displayName: "Context", provider: "runtime")
        )
        let snapshot = ConversationContextSnapshotV1(
            sessionID: "context-session",
            providerID: "runtime",
            modelID: provider.model.id,
            configurationFingerprint: "config",
            skillIdentifiers: [],
            conversationID: "context-session"
        )
        let result = ContextOrchestrator().makeManifest(
            ContextOrchestrator.Input(
                snapshot: snapshot,
                contextItems: [
                    ContextItem(identifier: "system", content: "system", tokenCost: 1)
                ]
            ),
            budget: 2
        )
        let invalidIdentity = AgentExecutionIdentity(
            turn: AgentTurnIdentity(sessionID: "", turnID: 0, messageID: "")
        )
        let engine = AgentLoopChatEngine(
            contextManifestInput: .init(
                snapshot: snapshot,
                result: result,
                runID: "context-invalid-identity",
                executionIdentity: invalidIdentity
            )
        )

        await #expect(throws: AgentLoopChatEngine.ContextManifestConsumptionError.invalidExecutionIdentity) {
            _ = try await engine.streamReply(
                provider: provider,
                history: [.init(role: .user, content: "hello")],
                systemPrompt: "system",
                maxTokens: 8,
                conversationID: "context-session",
                authorizedSessionReadSessionID: nil,
                turnID: 1
            )
        }
        #expect(provider.calls == 0)
    }

    @Test func contextConsumerRejectsDuplicateExecutionIdentityBeforeSecondProviderCall() async throws {
        let provider = CountingContextProvider(
            model: LLMModel(id: "context-model", displayName: "Context", provider: "runtime")
        )
        let snapshot = ConversationContextSnapshotV1(
            sessionID: "context-session",
            providerID: "runtime",
            modelID: provider.model.id,
            configurationFingerprint: "config",
            skillIdentifiers: [],
            conversationID: "context-session"
        )
        let result = ContextOrchestrator().makeManifest(
            ContextOrchestrator.Input(
                snapshot: snapshot,
                contextItems: [
                    ContextItem(identifier: "system", content: "system", tokenCost: 1)
                ]
            ),
            budget: 2
        )
        let identity = AgentExecutionIdentity(
            turn: AgentTurnIdentity(
                sessionID: "context-session",
                turnID: 7,
                messageID: "assistant-message"
            )
        )
        let composer = contextComposerFixture(identity: identity)
        let engine = AgentLoopChatEngine(
            contextManifestInput: .init(
                snapshot: snapshot,
                result: result,
                runID: "context-duplicate-identity",
                executionIdentity: identity
            ),
            composerPolicyFacts: composer.facts
        )

        let firstStream = try await engine.streamReply(
            provider: provider,
            history: [.init(role: .user, content: "hello")],
            systemPrompt: "system",
            maxTokens: 8,
            conversationID: "context-session",
            authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil,
            turnID: 7,
            composerSnapshot: composer.snapshot,
            executionIdentity: identity
        )
        for try await _ in firstStream {}
        let firstCallCount = provider.calls
        #expect(firstCallCount == 1)

        await #expect(throws: AgentLoopChatEngine.ContextManifestConsumptionError.executionIdentityRejected) {
            _ = try await engine.streamReply(
                provider: provider,
                history: [.init(role: .user, content: "hello")],
                systemPrompt: "system",
                maxTokens: 8,
                conversationID: "context-session",
                authorizedSessionReadSessionID: nil,
                authorizedSessionReadScope: nil,
                turnID: 7,
                composerSnapshot: composer.snapshot,
                executionIdentity: identity
            )
        }
        #expect(provider.calls == firstCallCount)
    }

    @Test func productionComposerCarriesAssistantIdentityThroughAgentLoopWritebackGate() async throws {
        let provider = CountingContextProvider(
            model: LLMModel(id: "context-model", displayName: "Context", provider: "runtime")
        )
        let snapshot = ConversationContextSnapshotV1(
            sessionID: "context-session",
            providerID: "runtime",
            modelID: provider.model.id,
            configurationFingerprint: "config",
            skillIdentifiers: [],
            conversationID: "context-session"
        )
        let result = ContextOrchestrator().makeManifest(
            ContextOrchestrator.Input(
                snapshot: snapshot,
                contextItems: [
                    ContextItem(identifier: "system", content: "system", tokenCost: 1)
                ]
            ),
            budget: 2
        )
        let identity = AgentExecutionIdentity(
            turn: AgentTurnIdentity(
                sessionID: "context-session",
                turnID: 8,
                messageID: "assistant-placeholder"
            ),
            operationID: "context-operation"
        )
        let facts = ComposerPolicyFactSource(
            knownCapabilities: [],
            grantedCapabilities: [],
            allowedWriteRoots: [],
            workspaceID: "context-session",
            revision: "policy-1",
            grantEpoch: "grant-1",
            leaseID: "lease-1",
            expiresAt: .distantFuture,
            autonomyCeiling: .l1
        )
        let composerSnapshot = ComposerSubmissionSnapshot(
            mode: .manual,
            approvalScope: .request,
            effort: .standard,
            sessionID: "context-session",
            turnID: 8,
            taskID: "context-task",
            messageID: "assistant-placeholder",
            workspaceID: "context-session",
            createdAt: Date(timeIntervalSince1970: 1),
            policyRevision: facts.revision,
            grantEpoch: facts.grantEpoch,
            autonomyCeiling: facts.autonomyCeiling
        )
        let engine = AgentLoopChatEngine(
            contextManifestInput: .init(
                snapshot: snapshot,
                result: result,
                runID: "context-composer-identity",
                executionIdentity: identity
            ),
            composerPolicyFacts: facts
        )

        let stream = try await engine.streamReply(
            provider: provider,
            history: [.init(role: .user, content: "hello")],
            systemPrompt: "system",
            maxTokens: 8,
            conversationID: "context-session",
            authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil,
            turnID: 8,
            composerSnapshot: composerSnapshot,
            executionIdentity: identity
        )
        for try await _ in stream {}

        #expect(provider.calls == 1)
    }

    @Test func productionContextConsumerPersistsBeforeProviderCall() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniscanvas-context-consumer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ContextManifestStore(
            persistenceURL: directory.appendingPathComponent("context.json")
        )
        let provider = CountingContextProvider(
            model: LLMModel(id: "context-model", displayName: "Context", provider: "runtime")
        )
        let identity = AgentExecutionIdentity(
            turn: AgentTurnIdentity(
                sessionID: "context-session",
                turnID: 9,
                messageID: "context-persist-assistant"
            )
        )
        let composer = contextComposerFixture(identity: identity)
        let engine = AgentLoopChatEngine(
            contextManifestStore: store,
            composerPolicyFacts: composer.facts
        )

        let stream = try await engine.streamReply(
            provider: provider,
            history: [.init(role: .user, content: "hello")],
            systemPrompt: "manifest-system",
            maxTokens: 8,
            conversationID: "context-session",
            authorizedSessionReadSessionID: nil,
            authorizedSessionReadScope: nil,
            turnID: 9,
            composerSnapshot: composer.snapshot,
            executionIdentity: identity
        )
        for try await _ in stream {}

        #expect(provider.calls == 1)
        #expect(provider.receivedSystemPrompt == "manifest-system")
        #expect(store.receipt(runID: try AgentLoopChatEngine.generatedContextManifestRunID(for: identity))?.usedBudget != nil)
    }

    /// Chat turn IDs outlive an engine's local cancellation controller.
    /// Freeze the durable identity in Composer, as the production ChatStore
    /// does, so turns 7/9 exercise identity gates rather than legacy turn 1.
    private func contextComposerFixture(
        identity: AgentExecutionIdentity
    ) -> (facts: ComposerPolicyFactSource, snapshot: ComposerSubmissionSnapshot) {
        let facts = ComposerPolicyFactSource(
            knownCapabilities: [],
            grantedCapabilities: [],
            allowedWriteRoots: [],
            workspaceID: identity.turn.sessionID,
            revision: "context-fixture-policy",
            grantEpoch: "context-fixture-grant",
            leaseID: "context-fixture-lease",
            expiresAt: .distantFuture,
            autonomyCeiling: .l1
        )
        let snapshot = ComposerSubmissionSnapshot(
            mode: .manual,
            approvalScope: .request,
            effort: .standard,
            sessionID: identity.turn.sessionID,
            turnID: identity.turn.turnID,
            taskID: "context-fixture-task",
            messageID: identity.turn.messageID,
            workspaceID: identity.turn.sessionID,
            createdAt: Date(),
            policyRevision: facts.revision,
            grantEpoch: facts.grantEpoch,
            autonomyCeiling: facts.autonomyCeiling
        )
        return (facts, snapshot)
    }

    @Test func productionCompositionDoesNotFailStartupOnCorruptContextManifest() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniscanvas-context-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let taskLedgerURL = directory.appendingPathComponent("agent-tasks-v1.json")
        let contextManifestURL = directory.appendingPathComponent("context-manifests-v1.json")
        try Data(#"{"schemaVersion":999,"records":{}}"#.utf8)
            .write(to: contextManifestURL, options: .atomic)

        let bridge = try BridgeStore(taskStorePersistenceURL: taskLedgerURL)
        let diagnostic = try #require(bridge.contextManifestStore.persistenceDiagnostics())
        #expect(diagnostic.operation == "recover")
        #expect(diagnostic.reason == "unsupported-schema")
        #expect(!diagnostic.message.contains(directory.path))
    }

    @Test func productionCompositionRecoversFromPartialContextManifest() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniscanvas-context-partial-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let taskLedgerURL = directory.appendingPathComponent("agent-tasks-v1.json")
        let contextManifestURL = directory.appendingPathComponent("context-manifests-v1.json")
        try Data(#"{"schemaVersion":1,"records":"#.utf8)
            .write(to: contextManifestURL, options: .atomic)

        let bridge = try BridgeStore(taskStorePersistenceURL: taskLedgerURL)
        let diagnostic = try #require(bridge.contextManifestStore.persistenceDiagnostics())
        #expect(diagnostic.operation == "recover")
        #expect(diagnostic.reason == "invalid-payload")
        #expect(!diagnostic.message.contains(contextManifestURL.path))
    }

    // MARK: - P3-CHILD-40: the cross-session governor is wired into production

    /// (i) The production orchestration path carries a non-nil governor whose
    /// policy is derived from the passed selection. The seam is read back off
    /// the live static orchestrator, so reverting the `childGovernor:` injection
    /// at the composition root makes this `#require` fail.
    @Test func productionCompositionWiresNonNilChildGovernor() async throws {
        let bridge = BridgeStore()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniscanvas-child40-governor-present-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let selection = try ChildConcurrencySelection(
            userSelected: 3,
            recommended: 3,
            effective: 2,
            enabledSessionCount: 2
        )
        bridge.attachProductionServices(
            sessionDirectory: dir,
            enableOrchestration: true,
            childConcurrencySelection: selection
        )

        let governor = try #require(bridge.orchestrationChildGovernor)
        // Policy.derived(from:) = enabledSessionCount × userSelected (2×3),
        // and the user's own selection values are untouched by the wiring.
        let globalBudget = await governor.globalBudget
        #expect(globalBudget == 6)
        #expect(bridge.childConcurrencySelection.userSelected == 3)
        #expect(bridge.childConcurrencySelection.effective == 2)
    }

    /// (ii) The static executor and the runtime-built orchestrator consult the
    /// SAME governor instance: the kill switch is engaged on the instance read
    /// back from the static orchestrator, and both orchestration entries must
    /// refuse to launch their child. A per-orchestrator instance or a dropped
    /// injection at either site would let the other path run its child (and the
    /// runtime one call the provider), turning this test red.
    @Test("static and runtime production orchestration share one governor instance")
    func staticAndRuntimeOrchestrationShareOneGovernor() async throws {
        let store = AgentTaskStore()
        let bridge = BridgeStore(agentTaskStore: store)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniscanvas-child40-shared-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        bridge.attachProductionServices(sessionDirectory: dir, enableOrchestration: true)

        let governor = try #require(bridge.orchestrationChildGovernor)
        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        await bridge.lastChildGovernorSafetyTask?.value
        let controlRevision = try #require(bridge.childGovernorControlRevision)
        #expect(await governor.engageKillSwitch(controlRevision: controlRevision))
        #expect(await governor.isKillSwitchEngaged == true)

        // Static executor (no AgentExecutionContext → the composite routes to
        // the static orchestrator). Without the governor the production-mode
        // static child would fail inside runChild with PARENT_TURN_UNVERIFIED;
        // the governor-aware path must refuse earlier with the kill-switch row.
        let staticOutput = try await engine.composedExecutor.execute(
            name: OrchestrationToolExecutor.toolName,
            input: [
                "input_version": OrchestrationToolExecutor.inputVersion,
                "strategy": "sequential",
                "tasks": [[
                    "id": "child40-static-blocked",
                    "title": "must not launch",
                    "instructions": "must not launch",
                    "model_binding": [
                        "kind": "explicit",
                        "provider_id": "child40-static-provider",
                        "model_id": "child40-static-model",
                        "configuration_fingerprint": "child40-static-fingerprint",
                    ],
                ]],
            ]
        )
        #expect(staticOutput.contains("GLOBAL_CHILD_BUDGET_KILL_SWITCH"))

        // Runtime-built orchestrator (AgentExecutionContext present). Its
        // deadline is in the FUTURE, so a missing/instance-diverging governor
        // would dispatch the child and call the provider instead of blocking.
        let provider = CountingContextProvider(
            model: LLMModel(
                id: "child40-shared-model",
                displayName: "Child40 Shared",
                provider: "child40-shared-provider"
            )
        )
        let turnController = TurnController()
        let parentTurn = await turnController.beginTurn()
        defer {
            Task { await parentTurn.finish() }
        }
        let conversationID = "child40-shared-conversation"
        let context = AgentExecutionContextSnapshot(
            provider: provider,
            approvalGate: nil,
            turnController: turnController,
            currentConversationID: conversationID,
            makeChildBudget: nil,
            deadline: Date().addingTimeInterval(120),
            taskStore: store,
            parentBinding: ParentContextSnapshotV1(
                providerID: provider.name,
                modelID: provider.model.id,
                configurationFingerprint: "child40-shared-fingerprint",
                conversationID: conversationID
            ),
            parentTurnHandle: parentTurn,
            parentRuntimeIdentity: ParentRuntimeIdentity(
                sessionID: conversationID,
                conversationID: conversationID,
                turnID: "turn-handle:\(parentTurn.turnID)",
                taskID: "child40-shared-parent",
                actorID: "app"
            )
        )
        let runtimeOutput = try await AgentExecutionContext.$current.withValue(context) {
            try await engine.composedExecutor.execute(
                name: OrchestrationToolExecutor.toolName,
                input: [
                    "input_version": OrchestrationToolExecutor.inputVersion,
                    "strategy": "sequential",
                    "tasks": [[
                        "id": "child40-runtime-blocked",
                        "title": "must not launch",
                        "instructions": "must not launch",
                    ]],
                ]
            )
        }
        #expect(runtimeOutput.contains("GLOBAL_CHILD_BUDGET_KILL_SWITCH"))
        #expect(provider.calls == 0)
    }

    /// (iii) Sequential orchestration accounts against the global ceiling: every
    /// child passes the governor's cross-session admission (one grant = one
    /// epoch touch and one slot), and every slot is released afterwards. With
    /// the governor-blind sequential path the epoch would be unchanged.
    @Test("sequential production orchestration accounts against the global governor")
    func sequentialOrchestrationAccountsAgainstGlobalGovernor() async throws {
        let store = AgentTaskStore()
        let bridge = BridgeStore(agentTaskStore: store)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("miniscanvas-child40-seq-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        bridge.attachProductionServices(sessionDirectory: dir, enableOrchestration: true)

        let governor = try #require(bridge.orchestrationChildGovernor)
        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let epochBefore = await governor.checkpoint().epoch
        let activeBefore = await governor.currentGlobalActive
        #expect(activeBefore == 0)

        // Expired parent deadline: each child fails fast INSIDE runChild
        // without provider work, so the only observable governor activity is
        // the sequential admission/release cycle itself.
        let provider = CountingContextProvider(
            model: LLMModel(
                id: "child40-seq-model",
                displayName: "Child40 Sequential",
                provider: "child40-seq-provider"
            )
        )
        let turnController = TurnController()
        let parentTurn = await turnController.beginTurn()
        defer {
            Task { await parentTurn.finish() }
        }
        let conversationID = "child40-seq-conversation"
        let context = AgentExecutionContextSnapshot(
            provider: provider,
            approvalGate: nil,
            turnController: turnController,
            currentConversationID: conversationID,
            makeChildBudget: nil,
            deadline: Date().addingTimeInterval(-1),
            taskStore: store,
            parentBinding: ParentContextSnapshotV1(
                providerID: provider.name,
                modelID: provider.model.id,
                configurationFingerprint: "child40-seq-fingerprint",
                conversationID: conversationID
            ),
            parentTurnHandle: parentTurn,
            parentRuntimeIdentity: ParentRuntimeIdentity(
                sessionID: conversationID,
                conversationID: conversationID,
                turnID: "turn-handle:\(parentTurn.turnID)",
                taskID: "child40-seq-parent",
                actorID: "app"
            )
        )
        _ = try await AgentExecutionContext.$current.withValue(context) {
            try await engine.composedExecutor.execute(
                name: OrchestrationToolExecutor.toolName,
                input: [
                    "input_version": OrchestrationToolExecutor.inputVersion,
                    "strategy": "sequential",
                    "tasks": [
                        [
                            "id": "child40-seq-1",
                            "title": "accounted child 1",
                            "instructions": "accounted",
                        ],
                        [
                            "id": "child40-seq-2",
                            "title": "accounted child 2",
                            "instructions": "accounted",
                        ],
                    ],
                ]
            )
        }

        let checkpoint = await governor.checkpoint()
        // Two sequential children → two governor grants → at least two epoch
        // touches. A governor-blind sequential branch leaves the epoch frozen.
        #expect(checkpoint.epoch >= epochBefore + 2)
        // Every acquired slot was released: no leaked global accounting.
        #expect(checkpoint.globalActive == 0)
        #expect(checkpoint.perSessionActive.values.allSatisfy { $0 == 0 })
    }

}

private final class CountingContextProvider: LLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    let name: String
    var model: LLMModel
    let capabilities: Set<ProviderCapability> = [.tools]
    var runtimeConfigurationMaterial: String?
    private(set) var calls = 0
    private(set) var receivedSystemPrompt: String?
    private(set) var receivedParentBinding: ParentContextSnapshotV1?

    init(model: LLMModel, runtimeConfigurationMaterial: String? = nil) {
        name = model.provider
        self.model = model
        self.runtimeConfigurationMaterial = runtimeConfigurationMaterial
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        calls += 1
        receivedSystemPrompt = systemPrompt
        receivedParentBinding = AgentExecutionContext.current?.parentBinding
        return LLMResponse(
            text: "ok",
            stopReason: "stop",
            usage: LLMUsage(inputTokens: 0, outputTokens: 0)
        )
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        try await sendMessage(
            messages: messages,
            systemPrompt: systemPrompt,
            maxTokens: maxTokens,
            temperature: temperature
        )
    }

    func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.finished(stopReason: "stop"))
            continuation.finish()
        }
    }
}
