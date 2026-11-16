import Foundation
import Testing
@testable import MinisCore

@Suite("D-MCP-06 child diagnostic redaction")
struct AgentOrchestratorMCPDiagnosticTests {
    private let remoteToolToken = "DMCP06_REMOTE_TOOL_9A6C3D"
    private let remotePropertyToken = "DMCP06_REMOTE_PROPERTY_41E8B7"
    private let fixedMessage = "Invalid MCP tool schema"

    @Test("child MCP schema failure redacts remote identity from every sink")
    func childMalformedMCPToolSchemaRedactsRemoteIdentityFromFailureReport() async throws {
        let fullName = MCPBoundTool.makeFullName(
            serverID: "dmcp06-server",
            toolName: "malformed-schema"
        )
        let malformed = MCPBoundTool(
            fullName: fullName,
            serverID: "dmcp06-server",
            tool: MCPTool(
                name: remoteToolToken,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        remotePropertyToken: .string("not-an-object")
                    ])
                ])
            )
        )

        let provider = DMCP06DiagnosticProvider()
        let executor = BuiltinToolExecutor(
            allowedRoot: FileManager.default.temporaryDirectory,
            mcpBridge: DMCP06DiagnosticBridge(tool: malformed)
        )
        let store = AgentTaskStore()
        let controller = TurnController()
        let parentTurn = await controller.beginTurn()
        defer {
            Task { await parentTurn.finish() }
        }
        let conversationID = "dmcp06-diagnostic-conversation"
        let orchestrator = AgentOrchestrator(
            provider: provider,
            toolExecutor: executor,
            currentConversationID: conversationID,
            taskStore: store,
            parentID: "dmcp06-parent",
            parentBinding: ParentContextSnapshotV1(
                providerID: provider.name,
                modelID: provider.model.id,
                configurationFingerprint: "dmcp06-diagnostic-fingerprint",
                conversationID: conversationID
            ),
            parentRuntimeIdentity: ParentRuntimeIdentity(
                sessionID: "dmcp06-session",
                conversationID: conversationID,
                turnID: "turn-handle:\(parentTurn.turnID)",
                taskID: "dmcp06-parent",
                actorID: "dmcp06-test"
            ),
            parentTurnHandle: parentTurn,
            runtimeMode: .production,
            capabilityPolicy: AgentCapabilityPolicy(
                allowedCapabilities: [.tools],
                allowedToolNames: [],
                allowedMCPToolNames: [fullName]
            ),
            parentCapabilities: provider.capabilities
        )

        let reports = await orchestrator.orchestrate(
            tasks: [
                SubAgentTask(
                    id: "dmcp06-child",
                    title: "malformed MCP schema",
                    instructions: "diagnose the child tool catalog",
                    requiredCapabilities: [.tools],
                    resourceRequest: SubAgentResourceRequest(
                        allowedToolNames: [fullName],
                        allowedReadRoots: []
                    )
                )
            ],
            strategy: .sequential
        )
        let report = try #require(reports.first)
        let receipt = try #require(store.allReceipts().first)
        let envelope = try #require(receipt.childResultEnvelope)
        let reportError = try #require(report.result.error)
        let envelopeError = try #require(envelope.error)
        let orchestrationSummary = OrchestrationToolExecutor.makeSummary(reports: reports)
        let ledgerDetails = store.events(runID: receipt.runID)
            .map(\.detail)
            .joined(separator: "\n")
        let receiptDescription = String(describing: receipt)

        #expect(reportError == fixedMessage)
        #expect(envelopeError == fixedMessage)
        #expect(report.summaryLine.contains(fixedMessage))
        #expect(orchestrationSummary.contains(fixedMessage))
        #expect(reportError != remoteToolToken)
        #expect(envelopeError != remotePropertyToken)

        let userSurfaces = [
            reportError,
            envelopeError,
            report.summaryLine,
            orchestrationSummary
        ]
        for surface in userSurfaces {
            #expect(surface.contains(fixedMessage))
            #expect(!surface.contains(remoteToolToken))
            #expect(!surface.contains(remotePropertyToken))
        }

        let rawLikeSurfaces = [ledgerDetails, receiptDescription]
        for surface in rawLikeSurfaces {
            #expect(!surface.contains(remoteToolToken))
            #expect(!surface.contains(remotePropertyToken))
        }
    }
}

private struct DMCP06DiagnosticBridge: MCPToolBridge {
    let tool: MCPBoundTool

    func mcpBoundTools() async throws -> [MCPBoundTool] {
        [tool]
    }

    func callMCPTool(fullName: String, arguments: [String: Any]?) async throws -> String {
        throw MCPClientError.toolNotFound(fullName)
    }
}

private struct DMCP06DiagnosticProvider: LLMProvider {
    let name = "dmcp06-diagnostic-provider"
    var model = LLMModel(
        id: "dmcp06-diagnostic-model",
        displayName: "D-MCP-06 diagnostic model",
        provider: "dmcp06-diagnostic-provider"
    )
    let capabilities: Set<ProviderCapability> = [.tools]

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        LLMResponse(text: "unused", stopReason: "stop", usage: nil)
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        LLMResponse(text: "unused", stopReason: "stop", usage: nil)
    }

    func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}
