import Foundation
import Testing
@testable import MinisCore

@Suite("A4 P0 agent timeout")
struct P0AgentTimeoutTests {
    @Test("secure factory supplies a production wall-clock timeout")
    func secureFactorySuppliesTimeout() throws {
        let loop = SecureAgentLoopFactory.make(approvalGate: ApprovalGate())
        #expect(loop.timeout == SecureAgentLoopFactory.defaultTimeout)
    }

    @Test("secure orchestrator supplies a child wall-clock timeout")
    func secureOrchestratorSuppliesChildTimeout() {
        let orchestrator = SecureAgentLoopFactory.makeOrchestrator(
            approvalDelegate: P0ApproveAllDelegate()
        )
        #expect(orchestrator.childTimeout == SecureAgentLoopFactory.defaultTimeout)
    }

    @Test("tool timeout returns before an executor that ignores cancellation")
    func toolTimeoutReturnsBeforeLateExecutor() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("P0AgentTimeout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try ToolExecutionFactLedger(
            persistenceURL: root.appendingPathComponent("tool-execution-facts-v4.json")
        )
        let executionIdentity = AgentExecutionIdentity(
            turn: AgentTurnIdentity(
                sessionID: "p0-timeout-session",
                turnID: 1,
                messageID: "p0-timeout-message"
            ),
            operationID: "p0-timeout-operation",
            attempt: 1
        )
        let executor = P0BlockingExecutor()
        let provider = P0ToolCallProvider()
        let approvals = P0ApprovalProbe()
        let controller = TurnController()
        let task = Task.detached {
            do {
                let result = try await AgentLoop(
                    maxIterations: 1,
                    approvalGate: ApprovalGate(
                        policyByTool: ["file_read": .alwaysAsk],
                        delegate: P0ApproveAllDelegate(probe: approvals)
                    ),
                    turnController: controller,
                    loopDetector: nil,
                    timeout: 0.01,
                    toolExecutionFactLedger: ledger
                ).run(
                    messages: [],
                    systemPrompt: nil,
                    provider: provider,
                    toolExecutor: executor,
                    tools: [
                        AgentToolDefinition(
                            name: "file_read",
                            description: "synthetic read handled by the blocking executor",
                            parameters: [:],
                            required: []
                        )
                    ],
                    currentConversationID: executionIdentity.turn.sessionID,
                    parentIdentitySeed: ParentRuntimeIdentitySeed(
                        sessionID: executionIdentity.turn.sessionID,
                        conversationID: executionIdentity.turn.sessionID,
                        taskID: "task:\(executionIdentity.operationID)",
                        actorID: "p0-timeout-test"
                    ),
                    executionIdentity: executionIdentity
                )
                await executor.markLoopFinished()
                return result
            } catch {
                await executor.markLoopFinished()
                throw error
            }
        }

        guard await executor.waitUntilStartedOrLoopFinished() else {
            // A gate rejection is a failed fixture, not a timeout pass. Release
            // any late executor before collecting the loop's real terminal.
            await executor.release()
            task.cancel()
            _ = await task.result
            Issue.record("the bound tool call must reach the blocking executor before timeout")
            return
        }
        let requests = await approvals.requests
        #expect(requests.count == 1)
        #expect(requests.first?.binding != nil)
        let result = await task.result
        guard case .failure(let error) = result else {
            Issue.record("a stalled tool must fail with a timeout")
            await executor.release()
            return
        }
        #expect(error as? ToolExecutorError == .toolTimeout("Tool 'file_read' timed out after 0.01s"))

        // The executor is deliberately released only after the caller has
        // received the timeout. Its late output must remain unobservable.
        await executor.release()
        #expect(await executor.wasReleased)
    }
}

private struct P0ApproveAllDelegate: ApprovalDelegate {
    let probe: P0ApprovalProbe?

    init(probe: P0ApprovalProbe? = nil) {
        self.probe = probe
    }

    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        await probe?.record(request)
        return ApprovalDecision(
            approved: true,
            confirmed: true,
            requestID: request.requestID,
            bindingDigest: request.identityDigest
        )
    }
}

private actor P0ApprovalProbe {
    private(set) var requests: [ApprovalRequest] = []

    func record(_ request: ApprovalRequest) {
        requests.append(request)
    }
}

private final class P0BlockingExecutor: ToolExecutor, @unchecked Sendable {
    private let gate = P0AsyncGate()

    func execute(name: String, input: [String: Any]) async throws -> String {
        await gate.markStarted()
        await gate.waitForRelease()
        return "late"
    }

    func waitUntilStartedOrLoopFinished() async -> Bool {
        await gate.waitUntilStartedOrLoopFinished()
    }

    func markLoopFinished() async {
        await gate.markLoopFinished()
    }

    func release() async {
        await gate.release()
    }

    var wasReleased: Bool {
        get async { await gate.isReleased }
    }
}

private actor P0AsyncGate {
    private var started = false
    private var loopFinished = false
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
    }

    func markLoopFinished() {
        loopFinished = true
    }

    func waitUntilStartedOrLoopFinished() async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if started { return true }
            if loopFinished { return false }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return started
    }

    func waitForRelease() async {
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    var isReleased: Bool { released }
}

private final class P0ToolCallProvider: LLMProvider, @unchecked Sendable {
    var name: String { "P0TimeoutProvider" }
    var model: LLMModel = .claudeHaiku45
    var capabilities: Set<ProviderCapability> { [.tools] }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        return LLMResponse(text: toolCallText, stopReason: nil, usage: nil)
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        return LLMResponse(text: toolCallText, stopReason: nil, usage: nil)
    }

    func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    private var toolCallText: String {
        let object: [String: Any] = [
            "tool_calls": [[
                "id": "file-read-call",
                "name": "file_read",
                "input": [:],
            ]]
        ]
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)!
    }
}
