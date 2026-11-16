import Foundation
import Testing
@testable import MinisCore

// MARK: - N1: ToolLoopDetector 接线（AgentLoop.loopDetector）
//
// 复用 AgentLoopTests.swift 中的 MockLLMProvider（同模块 internal）。
// 场景：
//   1. mock 重复调用同一工具（同参数）→ 第 loopThreshold 次起被 BLOCK，
//     上下文注入 [LOOP BLOCKED] is_error 结果，executor 不再被调用；
//   2. 非循环（不同签名/低于阈值）→ 全部正常执行，无 LOOP BLOCKED；
//   3. 与 approvalGate 共存：被审批拒绝的工具照常拒绝，循环检测互不干扰。

/// 记录型 executor：统计实际执行次数，便于断言"被 BLOCK 的调用从未触达 executor"。
private final class RecordingLoopExecutor: ToolExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(name: String, input: [String: Any])] = []
    var executed: [(name: String, input: [String: Any])] {
        lock.withLock { recorded }
    }

    func execute(name: String, input: [String: Any]) async throws -> String {
        let count = lock.withLock {
            recorded.append((name, input))
            return recorded.count
        }
        return "output-\(name)-\(count)"
    }
}

/// 构造单工具调用 envelope 响应（与 AgentLoopTests 的 toolCallEnvelope 等价）。
private func loopEnvelope(id: String, name: String, input: [String: Any]) -> String {
    let object: [String: Any] = ["tool_calls": [["id": id, "name": name, "input": input]]]
    let data = try! JSONSerialization.data(withJSONObject: object)
    return String(data: data, encoding: .utf8)!
}

/// 从消息历史中收集所有 tool_result 的 content（含 is_error 标记）。
private func toolResultContents(_ messages: [LLMMessage]) -> [(content: String, isError: Bool)] {
    messages.flatMap { msg in
        msg.toAgentContentParts().compactMap { part -> (String, Bool)? in
            if case .toolResult(_, _, let content, let isError, _, _, _, _) = part {
                return (content, isError)
            }
            return nil
        }
    }
}

struct LoopDetectorWiringTests {

    @Test func stoppedGenerationRejectsLateToolEvents() async {
        let lifecycle = ToolLoopLifecycle()
        let controller = TurnController(toolLoopLifecycle: lifecycle)
        let detector = ToolLoopDetector(lifecycle: lifecycle)
        let handle = await controller.beginTurn()
        let input: [String: Any] = ["query": "swift"]

        #expect(await handle.acceptsToolEvent())
        #expect(detector.recordInvocation(
            tool: "web_search",
            input: input,
            identity: handle.loopIdentity
        ))

        await handle.interrupt()
        #expect(await handle.acceptsToolEvent() == false)
        #expect(detector.recordInvocation(
            tool: "web_search",
            input: input,
            identity: handle.loopIdentity
        ) == false)
        #expect(detector.historySnapshot().count == 1)
        await handle.finish()
    }

    @Test func finishedGenerationCannotResurrectAfterNextTurnStarts() async {
        let lifecycle = ToolLoopLifecycle()
        let controller = TurnController(toolLoopLifecycle: lifecycle)
        let detector = ToolLoopDetector(lifecycle: lifecycle)
        let first = await controller.beginTurn()
        await first.finish()
        let second = await controller.beginTurn()

        #expect(first.loopIdentity != second.loopIdentity)
        #expect(detector.accepts(first.loopIdentity) == false)
        #expect(await second.acceptsToolEvent())
        #expect(detector.recordInvocation(
            tool: "web_search",
            input: ["query": "late"],
            identity: first.loopIdentity
        ) == false)
        #expect(detector.recordInvocation(
            tool: "web_search",
            input: ["query": "current"],
            identity: second.loopIdentity
        ))
        await second.finish()
    }

    @Test func timedOutGenerationRejectsLateToolEvents() async {
        let lifecycle = ToolLoopLifecycle()
        let controller = TurnController(toolLoopLifecycle: lifecycle)
        let detector = ToolLoopDetector(lifecycle: lifecycle)
        let handle = await controller.beginTurn()

        #expect(detector.recordInvocation(
            tool: "poll",
            input: ["id": "job-1"],
            identity: handle.loopIdentity
        ))
        await controller.timeout(turnID: handle.turnID)
        #expect(await handle.acceptsToolEvent() == false)
        #expect(detector.recordInvocation(
            tool: "poll",
            input: ["id": "job-1"],
            identity: handle.loopIdentity
        ) == false)
        await handle.finish()
    }

    @Test func loopThresholdStopsGenerationBeforeLateFourthEvent() async {
        let lifecycle = ToolLoopLifecycle()
        let controller = TurnController(toolLoopLifecycle: lifecycle)
        let detector = ToolLoopDetector(loopThreshold: 2, lifecycle: lifecycle)
        let handle = await controller.beginTurn()
        let input: [String: Any] = ["id": "job-1"]

        #expect(detector.recordInvocation(tool: "poll", input: input, identity: handle.loopIdentity))
        #expect(detector.recordInvocation(tool: "poll", input: input, identity: handle.loopIdentity))
        #expect(await handle.acceptsToolEvent() == false)
        #expect(detector.recordInvocation(tool: "poll", input: input, identity: handle.loopIdentity) == false)
        await handle.finish()
    }

    @Test func repeatedIdenticalCallInjectsLoopBlockedAndSkipsExecutor() async throws {
        // 默认阈值 3：前 2 次执行，第 3、4 次连续被 BLOCK（streak 继续累计）。
        let executor = RecordingLoopExecutor()
        let detector = ToolLoopDetector() // loopThreshold = 3
        let root = try minisCoreToolContractRoot("loop-detector-repeated")
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = minisCoreToolContractIdentity("loop-detector-repeated")
        let loop = AgentLoop(
            maxIterations: 6,
            loopDetector: detector,
            toolExecutionFactLedger: try minisCoreToolContractLedger(at: root)
        )
        let mock = MockLLMProvider(responses: [
            loopEnvelope(id: "c1", name: "web_search", input: ["query": "swift"]),
            loopEnvelope(id: "c2", name: "web_search", input: ["query": "swift"]),
            loopEnvelope(id: "c3", name: "web_search", input: ["query": "swift"]),
            loopEnvelope(id: "c4", name: "web_search", input: ["query": "swift"]),
            "已改用其他方法。",
        ])

        let result = try await loop.run(
            messages: [],
            systemPrompt: "test",
            provider: mock,
            toolExecutor: executor,
            tools: minisCoreToolContractCatalog(["web_search"]),
            executionIdentity: identity
        )

        // 只有前 2 次触达 executor；被 BLOCK 的不计 toolCallsExecuted。
        #expect(executor.executed.count == 2)
        #expect(executor.executed.allSatisfy { $0.name == "web_search" })
        #expect(result.toolCallsExecuted == 2)

        // 上下文含 2 条 [LOOP BLOCKED] is_error 结果，指明工具名。
        let results = toolResultContents(result.messages)
        let blocked = results.filter { $0.isError && $0.content.contains("[LOOP BLOCKED]") }
        #expect(blocked.count == 2)
        #expect(blocked.allSatisfy { $0.content.contains("web_search") })

        // 循环照常推进：模型看到警告后给出纯文本收尾。
        #expect(result.messages.last?.content == "已改用其他方法。")

        // 检测器仍处于 looping 状态（后续同类调用会继续被 BLOCK）。
        #expect(detector.isLooping())
        #expect(detector.historySnapshot().count == 4)
    }

    @Test func distinctCallsAreNeverBlocked() async throws {
        // 非循环：不同签名互相打断，全部正常执行。
        let executor = RecordingLoopExecutor()
        let root = try minisCoreToolContractRoot("loop-detector-distinct")
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = minisCoreToolContractIdentity("loop-detector-distinct")
        let loop = AgentLoop(
            maxIterations: 6,
            loopDetector: ToolLoopDetector(),
            toolExecutionFactLedger: try minisCoreToolContractLedger(at: root)
        )
        let mock = MockLLMProvider(responses: [
            loopEnvelope(id: "c1", name: "web_search", input: ["query": "one"]),
            loopEnvelope(id: "c2", name: "web_search", input: ["query": "two"]),
            loopEnvelope(id: "c3", name: "file_read", input: ["path": "/a.txt"]),
            "完成。",
        ])

        let result = try await loop.run(
            messages: [],
            systemPrompt: "test",
            provider: mock,
            toolExecutor: executor,
            tools: minisCoreToolContractCatalog(["web_search", "file_read"]),
            executionIdentity: identity
        )

        #expect(executor.executed.count == 3)
        #expect(result.toolCallsExecuted == 3)
        #expect(toolResultContents(result.messages).filter { $0.content.contains("[LOOP BLOCKED]") }.isEmpty)
        #expect(result.messages.last?.content == "完成。")
    }

    @Test func belowThresholdIdenticalCallsAreNotBlocked() async throws {
        // 同签名但只重复 2 次（默认阈值 3）→ 不判定循环，全部执行。
        let executor = RecordingLoopExecutor()
        let root = try minisCoreToolContractRoot("loop-detector-below-threshold")
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = minisCoreToolContractIdentity("loop-detector-below-threshold")
        let loop = AgentLoop(
            maxIterations: 6,
            loopDetector: ToolLoopDetector(),
            toolExecutionFactLedger: try minisCoreToolContractLedger(at: root)
        )
        let mock = MockLLMProvider(responses: [
            loopEnvelope(id: "c1", name: "web_search", input: ["query": "swift"]),
            loopEnvelope(id: "c2", name: "web_search", input: ["query": "swift"]),
            "完成。",
        ])

        let result = try await loop.run(
            messages: [],
            systemPrompt: "test",
            provider: mock,
            toolExecutor: executor,
            tools: minisCoreToolContractCatalog(["web_search"]),
            executionIdentity: identity
        )

        #expect(executor.executed.count == 2)
        #expect(result.toolCallsExecuted == 2)
        #expect(toolResultContents(result.messages).filter { $0.content.contains("[LOOP BLOCKED]") }.isEmpty)
    }

    @Test func loopDetectorCoexistsWithApprovalGate() async throws {
        // 共存：file_write 被审批拒绝（gate，默认 .alwaysAsk 策略），
        // web_search（默认 .autoApprove）重复触发 LOOP BLOCKED（detector）。
        // 两者各自生效、互不干扰。
        final class DenyAllDelegate2: ApprovalDelegate {
            func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
                .deny
            }
        }
        let gate = ApprovalGate(
            policyByTool: ["file_write": .alwaysAsk],
            delegate: DenyAllDelegate2()
        )
        let executor = RecordingLoopExecutor()
        let root = try minisCoreToolContractRoot("loop-detector-approval")
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = minisCoreToolContractIdentity("loop-detector-approval")
        let loop = AgentLoop(
            maxIterations: 8,
            approvalGate: gate,
            loopDetector: ToolLoopDetector(),
            toolExecutionFactLedger: try minisCoreToolContractLedger(at: root)
        )
        let mock = MockLLMProvider(responses: [
            loopEnvelope(id: "g1", name: "file_write", input: ["path": "/tmp/a"]), // gate 拒绝
            loopEnvelope(id: "c1", name: "web_search", input: ["query": "swift"]),
            loopEnvelope(id: "c2", name: "web_search", input: ["query": "swift"]),
            loopEnvelope(id: "c3", name: "web_search", input: ["query": "swift"]), // 第 3 次 → BLOCK
            "收工。",
        ])

        let result = try await loop.run(
            messages: [],
            systemPrompt: "test",
            provider: mock,
            toolExecutor: executor,
            tools: minisCoreToolContractCatalog(["file_write", "web_search"]),
            executionIdentity: identity
        )

        // file_write 从未执行；web_search 只执行 2 次（第 3 次被 BLOCK）。
        #expect(executor.executed.count == 2)
        #expect(executor.executed.allSatisfy { $0.name == "web_search" })
        #expect(result.toolCallsExecuted == 2)

        let results = toolResultContents(result.messages)
        // gate 拒绝：一条涉及 file_write 的 is_error（且非 LOOP BLOCKED）。
        let gateDenied = results.filter { $0.isError && $0.content.contains("file_write") && !$0.content.contains("[LOOP BLOCKED]") }
        #expect(gateDenied.count == 1)
        // detector：一条 [LOOP BLOCKED] 涉及 web_search。
        let blocked = results.filter { $0.isError && $0.content.contains("[LOOP BLOCKED]") }
        #expect(blocked.count == 1)
        #expect(blocked.first?.content.contains("web_search") == true)
        // 循环正常收尾。
        #expect(result.messages.last?.content == "收工。")
    }
}
