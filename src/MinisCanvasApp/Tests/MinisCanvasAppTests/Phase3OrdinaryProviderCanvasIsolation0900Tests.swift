import Foundation
import Testing
import MinisCore
import CanvasCore
@testable import MinisCanvasApp

private actor Canvas0900Gate {
    private(set) var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func park() async {
        entered = true
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func open() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor Canvas0900Wire {
    struct Request: Sendable {
        let userTexts: [String]
        let toolNames: [String]
    }
    private(set) var requests: [Request] = []
    func record(messages: [LLMMessage], tools: [AgentToolDefinition]) {
        requests.append(Request(userTexts: messages.filter { $0.role == .user }.map(\.content),
                                toolNames: tools.map(\.name)))
    }
}

/// Only the offline Provider response is synthetic. The ordinary production
/// ChatStore policy admits and invokes the concrete AgentLoopChatEngine.
private final class Canvas0900Provider: LLMProvider, ProviderRuntimeConfigurationIdentity, @unchecked Sendable {
    let name = "canvas0900-offline"
    let capabilities: Set<ProviderCapability> = [.tools]
    private let lock = NSLock()
    private var storedModel = LLMModel(id: "canvas0900-model", displayName: "Canvas 0900", provider: "canvas0900-offline")
    private var storedMaterial: String? = "canvas0900-isolated"
    var model: LLMModel {
        get { lock.withLock { storedModel } }
        set { lock.withLock { storedModel = newValue } }
    }
    var runtimeConfigurationMaterial: String? {
        get { lock.withLock { storedMaterial } }
        set { lock.withLock { storedMaterial = newValue } }
    }
    let wire = Canvas0900Wire()
    let gate = Canvas0900Gate()
    let marker: String
    init(marker: String) { self.marker = marker }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                     temperature: Double?) async throws -> LLMResponse {
        try await sendMessage(messages: messages, systemPrompt: systemPrompt, tools: [],
                              maxTokens: maxTokens, temperature: temperature)
    }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                     maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        await wire.record(messages: messages, tools: tools)
        await gate.park()
        try Task.checkCancellation()
        return LLMResponse(text: marker, stopReason: "stop", usage: nil)
    }
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                       temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private actor Canvas0900Approval: ApprovalDelegate {
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        ApprovalDecision(approved: true, confirmed: true,
                         requestID: request.requestID, bindingDigest: request.identityDigest)
    }
}

private struct Canvas0900SyntheticFailure: LocalizedError, CustomStringConvertible {
    var description: String { "synthetic Canvas execution failure" }
    var errorDescription: String? { "synthetic Canvas execution failure" }
}

private struct Canvas0900FailingLLMInvoker: LLMInvoker {
    let gate: Canvas0900Gate

    func invoke(prompt: String, backend: NodeBackendConfig) async throws -> String {
        await gate.park()
        throw Canvas0900SyntheticFailure()
    }
}

@MainActor private final class Canvas0900Factories {
    var canvasCalls = 0
    var coordinatorCalls = 0
    var damagedSnapshot = URL(fileURLWithPath: "/unused-owned-fixture")
    let originalBytes = Data("damaged synthetic Canvas media snapshot 0900".utf8)
}

@Suite("Phase3 ordinary actual Provider Canvas isolation 0900", .serialized)
@MainActor
struct Phase3OrdinaryProviderCanvasIsolation0900Tests {
    private func makeFixture(
        includeSyntheticSkill: Bool = false,
        canonicalSkillsState: Bool = false
    ) throws -> (SettingsCenter, BridgeStore, URL, Canvas0900Factories) {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("canvas0900-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let badges = SessionBadgeStore(directory: root.appendingPathComponent("badges"))
        let keychain = KeychainStore(backing: InMemoryKeychainBacking())
        let readiness = ProviderReadinessStore(directory: root.appendingPathComponent("readiness"))
        let now = Date()
        try #require(readiness.upsert([
            ProviderReadinessPersistenceRecord(
                providerID: "canvas0900-offline", modelID: "canvas0900-model",
                status: .passed, readinessState: .mock, checkedAt: now,
                evidenceID: "canvas0900-synthetic-readiness", isApplied: true,
                discoveryReceiptID: "canvas0900-synthetic-discovery", discoveredAt: now,
                applyReceiptID: "provider-readiness-apply:canvas0900-synthetic",
                appliedAt: now
            )
        ]))
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: root.appendingPathComponent("settings")),
            envStore: EnvVarStore(directory: root.appendingPathComponent("providers"), keychain: keychain),
            memoryStore: MemoryStore(directory: root.appendingPathComponent("memory")),
            sessionStore: sessions, sessionBadgeStore: badges,
            logManager: LogManager(directory: root.appendingPathComponent("logs")),
            mcpManager: MCPServerManager(
                fileURL: root.appendingPathComponent("mcps.json"), keychain: keychain
            ),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills")),
            usageStore: UsageStore(domain: .suite("canvas0900-\(UUID().uuidString)")),
            providerReadinessStore: readiness
        )
        let defaults = try #require(UserDefaults(suiteName: "canvas0900-\(UUID().uuidString)"))
        let hermes = root.appendingPathComponent("hermes", isDirectory: true)
        if includeSyntheticSkill {
            let skill = hermes.appendingPathComponent("creative/catalog-owned", isDirectory: true)
            try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
            try "---\nname: catalog-owned\ndescription: synthetic\n---\nowned body".write(
                to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
            )
        }
        let skills = SkillsStore(
             appStore: center.skillStore,
            stateFileURL: root.appendingPathComponent(canonicalSkillsState ? "skills-enabled.json" : "skill-state.json")
        )
        let scheduler = SchedulerTaskStore(
            defaults: defaults,
            occurrenceLedgerURL: root.appendingPathComponent("scheduler-occurrences.json")
        )
        let factories = Canvas0900Factories()
        let damagedDirectory = root.appendingPathComponent("canvas-media", isDirectory: true)
        try FileManager.default.createDirectory(at: damagedDirectory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        factories.damagedSnapshot = damagedDirectory.appendingPathComponent(VideoTaskStore.fileName)
        try factories.originalBytes.write(to: factories.damagedSnapshot)
        let taskStore = try AgentTaskStore(persistenceURL: root.appendingPathComponent("agent-tasks.json"))
        let bridge = BridgeStore(
            shortcutStore: ShortcutStore(defaults: defaults), preferencesDefaults: defaults,
            settingsCatalogSkillsStore: skills,
            settingsCatalogSchedulerStore: scheduler,
            logManager: LogManager(directory: root.appendingPathComponent("bridge-logs")),
            workflowStore: WorkflowStore(storeDirectory: root.appendingPathComponent("workflows")),
            sessionBadgeStore: badges,
            sessionDocumentStore: SessionDocumentStore(directory: sessions.directory),
            sessionStore: sessions,
            canvasFactory: { preferences in
                factories.canvasCalls += 1
                return CanvasStore(videoTaskStore: VideoTaskStore(directory: damagedDirectory),
                    artifactStore: ArtifactStore(directory: damagedDirectory.appendingPathComponent("artifacts")),
                    preferencesDefaults: preferences)
            },
            canvasRuntimeState: .enabled,
            agentTaskStore: taskStore, memoryStore: center.memoryStore,
            canvasMutationCoordinatorFactory: { canvas in
                factories.coordinatorCalls += 1
                return CanvasMutationCoordinator(target: canvas)
            },
            providerReadinessStore: readiness,
            canvasFeatureLane: .phase3NonCanvas
        )
        // Only the explicit owned local catalog participates in this fixture;
        // app-managed Hermes deployment is a separate original consumer.
        bridge.bindProductionEffectiveSettingsSource { [weak center] in
            center?.bl6EffectiveSettingsSnapshot
        }
        // The native Settings setter commits the Store before publishing its
        // effective/UI mirror. reloadAll() reloads other domains, not scalars.
        center.maxLoopIterations = 3
        try #require(center.lastPersistenceError == nil)
        #expect(center.settingsStore.settings.agent.maxLoopIterations == 3)
        #expect(center.maxLoopIterations == 3)
        #expect(SettingsStore(directory: center.settingsStore.directory).settings.agent.maxLoopIterations == 3)
        return (center, bridge, root, factories)
    }

    @Test("ordinary prose and old Canvas words reach the concrete AgentLoop Provider without Canvas construction or tools")
    func ordinaryAndLegacyCanvasWordsReachActualProviderWithoutCanvas() async throws {
        let (center, bridge, root, factories) = try makeFixture()
        let chat = bridge.chat
        defer { chat.stopAllStreamingForSafety() }
        let defaults = center.policyRuntimeDefaults
        try #require(center.updatePolicyRuntimeDefaults(ProductionPolicyDefaults(
            budget: defaults.budget, deadlineHorizon: defaults.deadlineHorizon,
            autonomyLevel: .l3, networkDomains: defaults.networkDomains)))
        #expect(center.policyRuntimeDefaults.budget == defaults.budget)
        #expect(center.policyRuntimeDefaults.deadlineHorizon == defaults.deadlineHorizon)
        #expect(center.policyRuntimeDefaults.networkDomains == defaults.networkDomains)
        await bridge.attachProductionServices(agentSettings: center.settings.agent,
            fileAccessAllowedRoot: root, sessionDirectory: center.sessionStore.directory,
            approvalDelegateOverride: Canvas0900Approval(),
            policyDefaults: center.policyRuntimeDefaults, externalNetworkAllowed: true).value
        center.onApprovalPolicyChanged = { [weak bridge] policy in bridge?.updateApprovalPolicy(policy) }
        center.approvalPolicy = .autoApprove
        try #require(center.lastPersistenceError == nil)
        try #require(chat.agentEngine is AgentLoopChatEngine)
        #expect(bridge.canvasFeatureLane == .phase3NonCanvas)
        #expect(bridge.canvasRuntimeState == .disabled)
        #expect(bridge.productionChatComposition.chatStartupIndependent)
        #expect(bridge.productionChatComposition.canvasCapabilities.isEmpty)
        #expect(chat.onSendCommand == nil)
        #expect(factories.canvasCalls == 0)
        #expect(factories.coordinatorCalls == 0)
        let inputs = ["owned ordinary chat request 0900", "执行", "添加节点 文本"]
        var operations: Set<String> = []
        for (index, input) in inputs.enumerated() {
            let session = chat.applyNewSession(title: "canvas0900-ordinary-\(index)")
            let provider = Canvas0900Provider(marker: "canvas0900-provider-completed-\(index)")
            defer { Task { await provider.gate.open() } }
            chat.streamingProviderOverride = provider
            chat.draftText = input
            chat.submitComposer()
            let task = try #require(chat.turnTaskForTests(sessionID: session))
            let enteredDeadline = Date().addingTimeInterval(15)
            while !(await provider.gate.entered) && Date() < enteredDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(await provider.gate.entered)
            let actual = try #require(chat.activeExecutionIdentity(for: session))
            #expect(actual.turn.sessionID == session.uuidString)
            #expect(operations.insert(actual.operationID).inserted)
            #expect(chat.agentEngine is AgentLoopChatEngine)
            let requests = await provider.wire.requests
            try #require(requests.count == 1)
            #expect(requests[0].userTexts.last == input)
            #expect(requests[0].toolNames.contains("file_read"))
            #expect(!requests[0].toolNames.contains { $0.lowercased().contains("canvas") })
            #expect(chat.onSendCommand == nil)
            #expect(bridge.canvasIfAvailable == nil)
            #expect(bridge.canvasBoundaryIfAvailable == nil)
            #expect(bridge.canvasMutationReceipts.isEmpty)
            #expect(bridge.composerCanvasDispatchCount == 0)
            #expect(factories.canvasCalls == 0)
            #expect(factories.coordinatorCalls == 0)
            #expect(try Data(contentsOf: factories.damagedSnapshot) == factories.originalBytes)
            await provider.gate.open()
            let terminalDeadline = Date().addingTimeInterval(15)
            while chat.turnTaskForTests(sessionID: session) != nil && Date() < terminalDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(chat.turnTaskForTests(sessionID: session) == nil)
            await task.value
            #expect(await provider.wire.requests.count == 1)
            #expect(chat.terminalReceipt(for: actual) != nil)
            #expect(chat.messages.contains { $0.role == .user && $0.content == input })
            #expect(chat.messages.contains { $0.role == .assistant && $0.content.contains(provider.marker) })
            let restored = try #require(SessionStore(directory: center.sessionStore.directory).loadSession(id: session.uuidString))
            #expect(restored.messages == chat.messages.map { $0.asLLMMessage() })
            #expect(restored.messages.contains { $0.role == .user && $0.content == input })
            #expect(restored.messages.contains { $0.role == .assistant && $0.content.contains(provider.marker) })
            #expect(try Data(contentsOf: factories.damagedSnapshot) == factories.originalBytes)
            #expect(factories.canvasCalls == 0)
            #expect(factories.coordinatorCalls == 0)
            print("TASK0900 inputIndex=\(index) actualProviderCalls=1 toolCount=\(requests[0].toolNames.count) nativeJoin=1 canvasFactories=0 durableReply=1")
        }
        #expect(operations.count == inputs.count)
        #expect(bridge.canvasMutationReceipts.isEmpty)
        #expect(bridge.composerCanvasDispatchCount == 0)
        #expect(factories.canvasCalls == 0)
        #expect(factories.coordinatorCalls == 0)
    }

    @Test("a stalled then failed Canvas executor does not hold the ordinary Provider turn")
    func canvasExecutionFailureDoesNotBlockOrdinaryChat() async throws {
        let (center, bridge, root, factories) = try makeFixture()
        let chat = bridge.chat
        defer { chat.stopAllStreamingForSafety() }
        let defaults = center.policyRuntimeDefaults
        try #require(center.updatePolicyRuntimeDefaults(ProductionPolicyDefaults(
            budget: defaults.budget, deadlineHorizon: defaults.deadlineHorizon,
            autonomyLevel: .l3, networkDomains: defaults.networkDomains)))
        await bridge.attachProductionServices(agentSettings: center.settings.agent,
            fileAccessAllowedRoot: root, sessionDirectory: center.sessionStore.directory,
            approvalDelegateOverride: Canvas0900Approval(),
            policyDefaults: center.policyRuntimeDefaults, externalNetworkAllowed: true).value
        center.onApprovalPolicyChanged = { [weak bridge] policy in bridge?.updateApprovalPolicy(policy) }
        center.approvalPolicy = .autoApprove
        try #require(chat.agentEngine is AgentLoopChatEngine)

        // The phase-3 bridge has no Canvas consumer. Exercise a separate
        // Canvas executor in the same process so its blocked worker and error
        // are real, while the ordinary Chat path uses the production engine.
        let canvasGate = Canvas0900Gate()
        defer { Task { await canvasGate.open() } }
        let canvas = CanvasStore(graph: NodeGraph(), context: GraphExecutionContext(
            executors: NodeExecutors(llmInvoker: Canvas0900FailingLLMInvoker(gate: canvasGate)),
            imageInvoker: MinisCanvasImageInvoker()
        ))
        let canvasNode = try #require(canvas.addNode(ofType: "imagePrompt"))
        canvas.runGraph()
        let canvasDeadline = Date().addingTimeInterval(15)
        while !(await canvasGate.entered) && Date() < canvasDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(await canvasGate.entered)
        #expect(canvas.isRunning)

        let session = chat.applyNewSession(title: "canvas0900-failure-isolation")
        let provider = Canvas0900Provider(marker: "canvas0900-chat-completed-before-canvas-failure")
        defer { Task { await provider.gate.open() } }
        chat.streamingProviderOverride = provider
        chat.draftText = "Canvas 执行挂起时，请完成普通聊天。"
        chat.submitComposer()
        let chatTask = try #require(chat.turnTaskForTests(sessionID: session))
        let providerDeadline = Date().addingTimeInterval(15)
        while !(await provider.gate.entered) && Date() < providerDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(await provider.gate.entered)
        #expect(canvas.isRunning)
        let requests = await provider.wire.requests
        try #require(requests.count == 1)
        #expect(requests[0].userTexts.last == "Canvas 执行挂起时，请完成普通聊天。")
        #expect(!requests[0].toolNames.contains { $0.lowercased().contains("canvas") })
        await provider.gate.open()
        let chatDeadline = Date().addingTimeInterval(15)
        while chat.turnTaskForTests(sessionID: session) != nil && Date() < chatDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(chat.turnTaskForTests(sessionID: session) == nil)
        await chatTask.value
        #expect(chat.messages.contains { $0.role == .assistant && $0.content.contains(provider.marker) })
        #expect(canvas.isRunning)

        await canvasGate.open()
        let failureDeadline = Date().addingTimeInterval(15)
        while canvas.isRunning && Date() < failureDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!canvas.isRunning)
        #expect(canvas.graph.node(id: canvasNode.id)?.status == .failed)
        #expect(canvas.statusMessage?.contains("失败 1") == true)
        #expect(chat.messages.contains { $0.role == .assistant && $0.content.contains(provider.marker) })
        #expect(bridge.canvasIfAvailable == nil)
        #expect(bridge.canvasMutationReceipts.isEmpty)
        #expect(factories.canvasCalls == 0)
        #expect(factories.coordinatorCalls == 0)

        let cancelledSession = chat.applyNewSession(title: "canvas0900-cancel-after-failure")
        let cancelledProvider = Canvas0900Provider(marker: "must-not-write-after-cancel")
        defer { Task { await cancelledProvider.gate.open() } }
        chat.streamingProviderOverride = cancelledProvider
        chat.draftText = "取消这次普通聊天，再正常发送。"
        chat.submitComposer()
        let cancelledTask = try #require(chat.turnTaskForTests(sessionID: cancelledSession))
        let cancelDeadline = Date().addingTimeInterval(15)
        while !(await cancelledProvider.gate.entered) && Date() < cancelDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(await cancelledProvider.gate.entered)
        chat.stopStreaming()
        await cancelledProvider.gate.open()
        await cancelledTask.value
        #expect(chat.turnTaskForTests(sessionID: cancelledSession) == nil)
        #expect(!chat.messages.contains { $0.role == .assistant && $0.content.contains(cancelledProvider.marker) })

        let recoveredSession = chat.applyNewSession(title: "canvas0900-recovered-chat")
        let recoveredProvider = Canvas0900Provider(marker: "canvas0900-recovery-completed")
        defer { Task { await recoveredProvider.gate.open() } }
        chat.streamingProviderOverride = recoveredProvider
        chat.draftText = "新的普通聊天应继续完成。"
        chat.submitComposer()
        let recoveredTask = try #require(chat.turnTaskForTests(sessionID: recoveredSession))
        let recoveryDeadline = Date().addingTimeInterval(15)
        while !(await recoveredProvider.gate.entered) && Date() < recoveryDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(await recoveredProvider.gate.entered)
        await recoveredProvider.gate.open()
        await recoveredTask.value
        #expect(chat.turnTaskForTests(sessionID: recoveredSession) == nil)
        #expect(chat.messages.contains { $0.role == .assistant && $0.content.contains(recoveredProvider.marker) })
        #expect(factories.canvasCalls == 0)
        print("TASK-CANVAS22 canvasStalled=1 ordinaryProviderCalls=1 chatFinishedBeforeCanvasFailure=1 canvasFailed=1 cancelNoWriteback=1 recoveryProviderCalls=1 canvasFactories=0")
    }
}
