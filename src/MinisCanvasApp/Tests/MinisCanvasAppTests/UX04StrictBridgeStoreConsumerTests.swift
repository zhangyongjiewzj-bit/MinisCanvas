import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("UX-04 strict BridgeStore consumer")
@MainActor
struct UX04StrictBridgeStoreConsumerTests {
    @Test("production orchestration declares an explicit child capability boundary")
    func productionOrchestrationDeclaresStrictChildBoundary() async throws {
        let bridge = BridgeStore()
        await bridge.attachProductionServices(enableOrchestration: true).value

        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let composite = try #require(findComposite(in: engine.composedExecutor))
        let childOrchestrator = composite.orchestration.orchestrator

        #expect(childOrchestrator.capabilityPolicy != nil)
        #expect(childOrchestrator.parentCapabilities != nil)
        #expect(childOrchestrator.capabilityPolicy?.allowedCapabilities != Set(ProviderCapability.allCases))
        #expect(childOrchestrator.requiresPolicyRuntime)

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let bridgeSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "src/MinisCanvasApp/Sources/MinisCanvasApp/BridgeStore.swift"
            ),
            encoding: .utf8
        )
        #expect(bridgeSource.contains("requiresPolicyRuntime: true"))
    }

    @Test("runtime child capability denial is visible in the task fact")
    func runtimeChildCapabilityDenialCannotProjectFakeSuccess() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ux04-strict-consumer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bridge = BridgeStore()
        await bridge.attachProductionServices(
            fileAccessAllowedRoot: root,
            sessionDirectory: root,
            enableOrchestration: true
        ).value
        let engine = try #require(bridge.chat.agentEngine as? AgentLoopChatEngine)
        let provider = UX04CapabilityProvider()
        let parentBinding = ParentContextSnapshotV1(
            providerID: provider.name,
            modelID: provider.model.id,
            configurationFingerprint: "ux04-parent-fingerprint",
            conversationID: "ux04-parent"
        )
        let turnController = TurnController()
        let parentTurn = await turnController.beginTurn()
        defer {
            Task { await parentTurn.finish() }
        }
        let parentRuntimeIdentity = ParentRuntimeIdentity(
            sessionID: "ux04-parent",
            conversationID: "ux04-parent",
            turnID: "turn-handle:\(parentTurn.turnID)",
            taskID: "ux04-parent",
            actorID: "app"
        )
        let context = AgentExecutionContextSnapshot(
            provider: provider,
            approvalGate: nil,
            turnController: turnController,
            currentConversationID: "ux04-parent",
            makeChildBudget: nil,
            deadline: Date().addingTimeInterval(60),
            taskStore: bridge.agentTaskStore,
            parentBinding: parentBinding,
            parentTurnHandle: parentTurn,
            parentRuntimeIdentity: parentRuntimeIdentity
        )

        let output = try await AgentExecutionContext.$current.withValue(context) {
            try await engine.composedExecutor.execute(
                name: OrchestrationToolExecutor.toolName,
                input: [
                    "input_version": OrchestrationToolExecutor.inputVersion,
                    "strategy": "sequential",
                    "tasks": [[
                        "id": "vision-child",
                        "title": "能力边界测试",
                        "instructions": "只返回完成",
                        "required_capabilities": ["vision"],
                    ]],
                ]
            )
        }

        #expect(output.contains("CAPABILITY_UNAVAILABLE"))
        let fact = try #require(
            bridge.taskCenterObservation.taskSnapshots.first {
                $0.taskID == "vision-child" && $0.parentID == "ux04-parent"
            }
        )
        #expect(fact.status == .failed)
        #expect(bridge.agentTaskStore.allReceipts().first?.outcome == .failed(reason: "execution-failed"))
        let intent = try #require(bridge.agentTaskStore.childLaunchIntents().first {
            $0.intent.taskID == "vision-child"
                && $0.intent.parent == parentRuntimeIdentity
        })
        #expect(intent.status == .notAdmitted)
        #expect(intent.intent.runID == nil)
    }
}

private func findComposite(in executor: any ToolExecutor) -> OrchestrationCompositeToolExecutor? {
    if let composite = executor as? OrchestrationCompositeToolExecutor {
        return composite
    }
    if let concurrent = executor as? ConcurrentToolLimitingExecutor {
        return findComposite(in: concurrent.baseBox.value)
    }
    if let recording = executor as? RecordingToolExecutor {
        return findComposite(in: recording.base)
    }
    if let policy = executor as? PolicyEnforcedToolExecutor {
        return findComposite(in: policy.base)
    }
    // SafetyRuntimeToolGate is private to the production module; follow only
    // its private base executor so this probe remains an observation seam.
    for child in Mirror(reflecting: executor).children where child.label == "base" {
        if let base = child.value as? any ToolExecutor {
            return findComposite(in: base)
        }
    }
    return nil
}

private final class UX04CapabilityProvider: LLMProvider, @unchecked Sendable {
    let name = "UX04CapabilityProvider"
    var model = LLMModel(
        id: "ux04-model",
        displayName: "UX04 Model",
        provider: "UX04CapabilityProvider"
    )
    let capabilities: Set<ProviderCapability> = [.streaming, .tools, .vision]

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        LLMResponse(
            text: "child-success",
            stopReason: "stop",
            usage: LLMUsage(inputTokens: 1, outputTokens: 1)
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
