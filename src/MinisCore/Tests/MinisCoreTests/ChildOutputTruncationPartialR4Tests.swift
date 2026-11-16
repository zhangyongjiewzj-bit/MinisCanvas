import Foundation
import Testing
@testable import MinisCore

/// R4 修补：子代理遇 `AgentLoopError.outputTruncated` 时与迭代上限一样返回
/// 失败 + 半截报告（`partialOutput`），文案说明是输出上限截断，保持“失败”。
@Suite("R4 child output truncation keeps partial report")
struct ChildOutputTruncationPartialR4Tests {
    /// 外部边界：Provider 把一段纯文本以 stopReason=length 截断返回。
    final class LengthCutProvider: LLMProvider, @unchecked Sendable {
        var name: String { "LengthCut" }
        var model: LLMModel = .claudeHaiku45
        var capabilities: Set<ProviderCapability> { [.tools] }
        let text: String
        init(text: String) { self.text = text }

        func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                         temperature: Double?) async throws -> LLMResponse {
            LLMResponse(text: text, stopReason: "length", usage: nil)
        }

        func sendMessage(messages: [LLMMessage], systemPrompt: String?, tools: [AgentToolDefinition],
                         maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
            LLMResponse(text: text, stopReason: "length", usage: nil)
        }

        func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int,
                           temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    @Test("truncated child reply fails with partial report and an accurate truncation note")
    func truncatedChildReturnsFailedWithPartialReport() async throws {
        actor Approval: ApprovalDelegate {
            func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
                ApprovalDecision(approved: true, confirmed: true,
                    requestID: request.requestID, bindingDigest: request.identityDigest)
            }
        }
        let profile = try #require(FormalTestIsolationPaths.currentOrFail())
        let root = profile.rootDirectory.appendingPathComponent("r4trunc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let source = try sessions.createSession(id: "r4trunc-source")
        let tasks = try AgentTaskStore(persistenceURL: root.appendingPathComponent("tasks.json"))
        let ledger = try ToolExecutionFactLedger(persistenceURL: root.appendingPathComponent("facts.json"))
        let controller = TurnController()
        let turn = await controller.beginTurn()
        defer { Task { await turn.finish() } }
        let parent = try ParentRuntimeIdentitySeed(sessionID: source.id,
            conversationID: source.id, taskID: "r4trunc-parent", actorID: "test")
            .makeIdentity(using: turn)
        let provider = LengthCutProvider(text: "半截报告正文：前三节已完成")
        let builtin = BuiltinToolExecutor(allowedRoot: root, deniedRoots: [])
        let orchestrator = AgentOrchestrator(maxIterationsPerTask: 3,
            provider: provider, toolExecutor: ScopedForwardingExecutor(base: builtin),
            approvalGate: ApprovalGate(policyByTool: ["file_read": .alwaysAsk], delegate: Approval()),
            turnController: controller, makeLoopDetector: { nil }, currentConversationID: source.id,
            taskStore: tasks, sessionStore: sessions, toolExecutionFactLedger: ledger,
            parentID: parent.taskID, parentRuntimeIdentity: parent, parentTurnHandle: turn,
            runtimeMode: .production,
            capabilityPolicy: AgentCapabilityPolicy(allowedCapabilities: [.tools], allowedToolNames: ["file_read"]),
            parentCapabilities: [.tools], parentFileAccessCeiling: ChildParentFileAccessCeiling(executor: builtin),
            concreteBuiltinToolExecutorOwner: builtin)
        let reports = await orchestrator.orchestrate(tasks: [SubAgentTask(id: "r4trunc-child",
            title: "report", instructions: "write report", requiredCapabilities: [.tools],
            resourceRequest: SubAgentResourceRequest(allowedToolNames: ["file_read"],
                allowedReadRoots: [root.path]))], strategy: .sequential)
        let report = try #require(reports.first)

        // 保持“失败”，不改成功。
        #expect(report.result.isSuccess == false)
        // 半截报告随结果返回，且说明是输出上限截断。
        let partial = try #require(report.partialOutput)
        #expect(partial.contains("半截报告正文：前三节已完成"))
        #expect(partial.contains("输出上限"))
        // 不得出现只对交互会话成立的文案。
        #expect(!partial.contains("输入‘继续’"))
        // 父模型可读的持久化结果：部分结果（非空输出、无 error）。
        let envelope = try #require(tasks.allReceipts().first?.childResultEnvelope)
        #expect(envelope.isPartial)
        #expect(envelope.output?.contains("半截报告正文：前三节已完成") == true)
    }
}
