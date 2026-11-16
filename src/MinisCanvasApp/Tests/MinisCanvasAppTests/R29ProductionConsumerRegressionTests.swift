import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("R29 production consumer regression")
@MainActor
struct R29ProductionConsumerRegressionTests {
    @Test("project tools remain an all-or-none catalog when a child narrows its tools")
    func projectCatalogAcceptsScopedChildAndRejectsPartialOrDuplicateProjectTools() async throws {
        let fixture = try R29ProductionConsumerFixture()
        await fixture.productionAttachment.value
        let handler = try #require(fixture.bridge.productionProjectSessionHandler)
        let builtin = try #require(fixture.bridge.productionBuiltinToolExecutor)
        let engine = try #require(fixture.chat.agentEngine as? AgentLoopChatEngine)
        let projectTools = try #require(engine.projectSessionDefinitions)
        try #require(Set(projectTools.map(\.name)) == ProjectSessionToolContract.toolNames)
        let fileRead = try #require(AgentToolCatalog.makeTools().first { $0.name == "file_read" })
        let route = ProjectSessionCompositeToolExecutor(
            base: builtin, builtin: builtin, handler: handler,
            workspaceBindings: ProjectSessionWorkspaceBindings()
        )

        try route.validateToolCatalog([])
        try route.validateToolCatalog([fileRead])
        try route.validateToolCatalog(projectTools)
        #expect(throws: ProjectSessionAppError.grantUnavailable) {
            try route.validateToolCatalog([projectTools[0]])
        }
        #expect(throws: ProjectSessionAppError.grantUnavailable) {
            try route.validateToolCatalog(projectTools + [projectTools[0]])
        }
    }

    @Test("sendDraft reaches orchestration and child dispatch")
    func sendDraftReachesChildDispatch() async throws {
        let fixture = try R29ProductionConsumerFixture()
        await fixture.productionAttachment.value
        fixture.chat.switchSession(id: fixture.parentSessionID)
        try #require(fixture.chat.activeSessionID == fixture.parentSessionID)
        try #require(fixture.chat.sessionStore === fixture.sessionStore)
        try #require(fixture.sessionStore.loadSession(
            id: fixture.parentSessionID.uuidString
        ) != nil)
        #expect(fixture.bridge.orchestrationEnabled)
        #expect((fixture.chat.agentEngine as? AgentLoopChatEngine)?.hasOrchestrationCapability == true)
        #expect(fixture.chat.providerRuntimeRouteFactory != nil)
        #expect(fixture.chat.turnRuntimeSnapshotFactory != nil)
        let readiness = try #require(
            fixture.readinessStore.records.first {
                $0.providerID == "r29-provider" && $0.modelID == "r29-model"
            }
        )
        #expect(readiness.isApplied)
        #expect(!readiness.discoveryReceiptID.isEmpty)
        #expect(readiness.applyReceiptID?.isEmpty == false)
        fixture.chat.draftText = "invoke child"
        fixture.chat.sendDraft()
        await fixture.approvePendingApproval()
        try await fixture.waitForReceipt()
        if await fixture.probe.childDispatchCount() == 0 {
            print("TASK2467_R29_PREPROVIDER_DIAG task_snapshots=\(String(describing: fixture.taskStore.taskCenterSnapshots())) receipts=\(String(describing: fixture.taskStore.allReceipts())) chat_messages=\(String(describing: fixture.chat.messages.map(\.content)))")
        }

        #expect(await fixture.probe.parentHandleWasVerified())
        #expect(await fixture.probe.parentProvenanceWasVerified())
        #expect(await fixture.probe.childDispatchCount() == 1)
        #expect(
            fixture.bridge.providerRuntimeObservations.last?.servedProviderID
                == "r29-provider"
        )
        let receipt = try #require(fixture.taskStore.allReceipts().first {
            $0.taskID == "child-1"
        })
        #expect(receipt.outcome == .succeeded)
        #expect(fixture.taskStore.events(runID: receipt.runID).map(\.kind) == [.started, .progress, .completed])
    }
}

@MainActor
private final class R29ProductionConsumerFixture: @unchecked Sendable {
    let bridge: BridgeStore
    let chat: ChatStore
    let probe: R29ProviderProbe
    let taskStore: AgentTaskStore
    let readinessStore: ProviderReadinessStore
    let sessionStore: SessionStore
    let parentSessionID: UUID
    let productionAttachment: Task<Void, Never>
    let root: URL

    init(childDelay: Duration = .milliseconds(20)) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("r29-production-consumer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        probe = R29ProviderProbe()
        taskStore = AgentTaskStore()
        parentSessionID = UUID()
        sessionStore = SessionStore(directory: root.appendingPathComponent("sessions", isDirectory: true))
        try sessionStore.createSession(id: parentSessionID.uuidString, title: "R29 synthetic parent")
        let readinessDirectory = root.appendingPathComponent(
            "provider-readiness",
            isDirectory: true
        )
        readinessStore = ProviderReadinessStore(directory: readinessDirectory)
        let checkedAt = Date(timeIntervalSince1970: 1_787_200_000)
        let lineage = ProviderReadinessLineage.derived(
            providerID: "r29-provider",
            modelID: "r29-model",
            checkedAt: checkedAt
        )
        readinessStore.upsert(
            ProviderReadinessPersistenceRecord(
                providerID: "r29-provider",
                modelID: "r29-model",
                status: .passed,
                readinessState: .mock,
                checkedAt: checkedAt,
                evidenceID: "r29-readiness-evidence",
                isApplied: false,
                discoveryReceiptID: lineage.discoveryReceiptID,
                discoveredAt: lineage.discoveredAt
            )
        )
        let applied = readinessStore.applyDiscoveredModels(
            providerID: "r29-provider",
            modelIDs: ["r29-model"],
            appliedAt: checkedAt.addingTimeInterval(1)
        )
        precondition(applied.count == 1)
        precondition(applied.first?.applyReceiptID?.isEmpty == false)
        bridge = BridgeStore(
            sessionDocumentStore: SessionDocumentStore(directory: sessionStore.directory),
            sessionStore: sessionStore,
            canvasRuntimeState: .disabled,
            agentTaskStore: taskStore,
            providerReadinessStore: readinessStore,
            canvasFeatureLane: .phase3NonCanvas
        )
        productionAttachment = ProductionOrchestrationDefaults.attachProductionServices(
            to: bridge,
            fileAccessAllowedRoot: root,
            sessionDirectory: sessionStore.directory,
            mcpManager: MCPServerManager(fileURL: root.appendingPathComponent("mcps.json")),
            skillStore: SkillStore(skillsRoot: root.appendingPathComponent("skills", isDirectory: true)),
            canvasRuntimeState: .disabled
        )
        chat = bridge.chat
        chat.streamingProviderOverride = R29Provider(probe: probe, childDelay: childDelay)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func approvePendingApproval() async {
        for _ in 0..<400 {
            if bridge.approvalCenter.pendingRequest != nil {
                bridge.approvalCenter.approvePending()
                if bridge.approvalCenter.awaitingConfirmation {
                    bridge.approvalCenter.confirmPending()
                }
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func waitForReceipt() async throws {
        for _ in 0..<600 {
            if taskStore.allReceipts().contains(where: { $0.taskID == "child-1" }) {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor R29ProviderProbe {
    private var sawVerifiedParent = false
    private var sawParentProvenance = false
    private var childCalls = 0

    func record(context: AgentExecutionContextSnapshot?, isChild: Bool) {
        if context?.hasVerifiedParentRuntime == true {
            sawVerifiedParent = true
        }
        if let context,
           context.hasVerifiedParentRuntime,
           context.parentBinding?.conversationID?.isEmpty == false,
           context.taskStore != nil {
            sawParentProvenance = true
        }
        if isChild {
            childCalls += 1
        }
    }

    func parentHandleWasVerified() -> Bool { sawVerifiedParent }
    func parentProvenanceWasVerified() -> Bool { sawParentProvenance }
    func childDispatchCount() -> Int { childCalls }
}

private final class R29Provider: LLMProvider, @unchecked Sendable {
    let name = "r29-provider"
    var model = LLMModel(id: "r29-model", displayName: "R29 model", provider: "r29-provider")
    let capabilities: Set<ProviderCapability> = [.tools]
    private let probe: R29ProviderProbe
    private let childDelay: Duration

    init(probe: R29ProviderProbe, childDelay: Duration) {
        self.probe = probe
        self.childDelay = childDelay
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        let content = messages.last?.content ?? ""
        let isChild = content.contains("child instructions")
        await probe.record(context: AgentExecutionContext.current, isChild: isChild)
        if isChild {
            try await Task.sleep(for: childDelay)
            return LLMResponse(text: "child complete", stopReason: "stop", usage: nil)
        }
        if content.contains("invoke child") {
            return LLMResponse(text: r29ToolCallEnvelope(), stopReason: "tool_calls", usage: nil)
        }
        return LLMResponse(text: "\(content) complete", stopReason: "stop", usage: nil)
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
        AsyncThrowingStream { $0.finish() }
    }
}

private func r29ToolCallEnvelope() -> String {
    let tasks: [[String: Any]] = [[
        "id": "child-1",
        "title": "child",
        "instructions": "child instructions"
    ]]
    let input: [String: Any] = [
        "input_version": 1,
        "tasks": tasks,
        "strategy": "sequential"
    ]
    let object: [String: Any] = [
        "tool_calls": [[
            "id": "r29-orchestrate",
            "name": "orchestrate",
            "input": input
        ]]
    ]
    return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
}
