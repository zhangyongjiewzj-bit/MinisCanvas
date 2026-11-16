import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

// P3-HOOK-01（总表 :284）生产合并线接证。
//
// 被测对象是 `ChatEngineHookDecisionMerge.mergedDecision` —— ChatAgentEngine
// 唯一的生产决策合并入口（内部即 `HookDecisionReducer.decide`），以及真实
// 生产路径 `AgentLoopChatEngine.oneShotAgentReply` 在该合并结果为 terminal
// deny 时对模型发起工具调用的实际拒绝。全部断言只观察合并出口的行为，
// 不钉 reducer 的实现细节。

private func matchingIdentityHook(_ verdict: HookLayerVerdict) -> HookLayerSignal {
    HookLayerSignal(
        verdict: verdict,
        handlerInvocationID: "inv-wire-258",
        handlerResultID: "inv-wire-258"
    )
}

@Suite("P3-HOOK-01 production hook decision merge (lane 258)")
struct HookDecisionReducerProductionWiring258Tests {

    // MARK: deny > ask > allow（固定优先级，经生产合并入口）

    @Test func policyDenyBeatsAskAndAllowFromEveryOtherLayerAndCannotBeReOpened() {
        let decision = ChatEngineHookDecisionMerge.mergedDecision(
            policy: PolicyLayerSignal(verdict: .deny),
            approval: ApprovalLayerSignal(verdict: .ask),
            stop: StopLayerSignal(continueRequested: true),
            timeout: TimeoutLayerSignal(expired: false),
            hook: matchingIdentityHook(.allow)
        )
        #expect(decision.outcome == .deny)
        #expect(decision.reason == .policyDeny)
        #expect(decision.isTerminalDeny)
    }

    @Test func approvalDenyWinsOverAllowingStopTimeoutAndHookLayers() {
        let decision = ChatEngineHookDecisionMerge.mergedDecision(
            policy: PolicyLayerSignal(verdict: .allow),
            approval: ApprovalLayerSignal(verdict: .deny),
            stop: StopLayerSignal(continueRequested: true),
            timeout: TimeoutLayerSignal(expired: false),
            hook: matchingIdentityHook(.allow)
        )
        #expect(decision.outcome == .deny)
        #expect(decision.reason == .approvalDeny)
        #expect(decision.isTerminalDeny)
    }

    @Test func askFromAnyLayerBeatsAllowWhenNoDenyIsPresent() {
        let decision = ChatEngineHookDecisionMerge.mergedDecision(
            policy: PolicyLayerSignal(verdict: .allow),
            approval: ApprovalLayerSignal(verdict: .ask),
            stop: StopLayerSignal(continueRequested: true),
            timeout: TimeoutLayerSignal(expired: false),
            hook: matchingIdentityHook(.allow)
        )
        #expect(decision.outcome == .ask)
        #expect(decision.reason == .approvalAsk)
        #expect(!decision.isTerminalDeny)
    }

    // MARK: continue=false sticky

    @Test func stopContinueFalseIsStickyAgainstAllowingLaterLayers() {
        let decision = ChatEngineHookDecisionMerge.mergedDecision(
            policy: PolicyLayerSignal(verdict: .allow),
            approval: ApprovalLayerSignal(verdict: .allow),
            stop: StopLayerSignal(continueRequested: false),
            timeout: TimeoutLayerSignal(expired: false),
            hook: matchingIdentityHook(.allow)
        )
        #expect(decision.outcome == .deny)
        #expect(decision.reason == .stopContinueFalse)
        #expect(decision.isTerminalDeny)
    }

    @Test func expiredTimeoutDeniesDespiteEveryOtherLayerAllowing() {
        let decision = ChatEngineHookDecisionMerge.mergedDecision(
            policy: PolicyLayerSignal(verdict: .allow),
            approval: ApprovalLayerSignal(verdict: .allow),
            stop: StopLayerSignal(continueRequested: true),
            timeout: TimeoutLayerSignal(expired: true),
            hook: matchingIdentityHook(.allow)
        )
        #expect(decision.outcome == .deny)
        #expect(decision.reason == .timeoutExpired)
        #expect(decision.isTerminalDeny)
    }

    // MARK: handler invocation/result 同 identity

    @Test func handlerIdentityMismatchDeniesEvenWhenAllOtherLayersAllow() {
        let decision = ChatEngineHookDecisionMerge.mergedDecision(
            policy: PolicyLayerSignal(verdict: .allow),
            approval: ApprovalLayerSignal(verdict: .allow),
            stop: StopLayerSignal(continueRequested: true),
            timeout: TimeoutLayerSignal(expired: false),
            hook: HookLayerSignal(
                verdict: .allow,
                handlerInvocationID: "inv-wire-258-a",
                handlerResultID: "inv-wire-258-b"
            )
        )
        #expect(decision.outcome == .deny)
        #expect(decision.reason == .hookHandlerIdentityMismatch)
        #expect(decision.isTerminalDeny)
    }

    @Test func matchingHandlerIdentityIsHonouredAndAllowsWhenOthersAllow() {
        let decision = ChatEngineHookDecisionMerge.mergedDecision(
            policy: PolicyLayerSignal(verdict: .allow),
            approval: ApprovalLayerSignal(verdict: .allow),
            stop: StopLayerSignal(continueRequested: true),
            timeout: TimeoutLayerSignal(expired: false),
            hook: matchingIdentityHook(.allow)
        )
        #expect(decision.outcome == .allow)
        #expect(decision.reason == .allLayersConcur)
        #expect(!decision.isTerminalDeny)
    }

    // MARK: 后层不可重新放开 deny（含缺层 fail-closed 与固定扫描序）

    @Test func missingLaterLayerFailsClosedAndCannotRescueAnEarlierAllow() {
        let decision = ChatEngineHookDecisionMerge.mergedDecision(
            policy: PolicyLayerSignal(verdict: .allow),
            approval: ApprovalLayerSignal(verdict: .allow),
            stop: StopLayerSignal(continueRequested: true),
            timeout: TimeoutLayerSignal(expired: false),
            hook: nil
        )
        #expect(decision.outcome == .deny)
        #expect(decision.reason == .missingLayerInputFailClosed)
        #expect(decision.isTerminalDeny)
    }

    @Test func denyScanOrderIsStableWhenMultipleLayersDeny() {
        // 前层 deny 固定先出（policy → approval → …），后层的 deny/allow
        // 都不能改变已产生的终态身份。
        let first = ChatEngineHookDecisionMerge.mergedDecision(
            policy: PolicyLayerSignal(verdict: .deny),
            approval: ApprovalLayerSignal(verdict: .deny),
            stop: StopLayerSignal(continueRequested: true),
            timeout: TimeoutLayerSignal(expired: false),
            hook: matchingIdentityHook(.deny)
        )
        let replay = ChatEngineHookDecisionMerge.mergedDecision(
            policy: PolicyLayerSignal(verdict: .deny),
            approval: ApprovalLayerSignal(verdict: .deny),
            stop: StopLayerSignal(continueRequested: true),
            timeout: TimeoutLayerSignal(expired: false),
            hook: matchingIdentityHook(.deny)
        )
        #expect(first.outcome == .deny)
        #expect(first.reason == .policyDeny)
        #expect(first == replay)
    }

    // MARK: 真实生产路径：oneShotAgentReply 在合并 terminal deny 下拒绝工具执行

    @Test func oneShotProductionPathRejectsModelInitiatedToolCallUnderMergedDeny() async throws {
        let marker = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".oneShotWire258Marker-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: marker) }

        let provider = Wire258ToolEmittingProvider(
            toolName: "file_write",
            toolArguments: ["path": marker.path, "content": "wire"]
        )
        let reply = try await AgentLoopChatEngine.oneShotAgentReply(
            provider: provider,
            systemPrompt: "只输出纯文本，禁止调用工具",
            userText: "调整节点内容",
            maxTokens: 256
        )

        // 合并出口为 terminal deny → 执行器保持能力冻结：底层执行 = 0。
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(provider.receivedToolResults.contains { $0.contains("Error executing tool file_write") })
        // 纯文本路径保持可用（合并未放宽既有拒绝语义）。
        #expect(reply == "OK")
    }
}

/// 脚本化 Provider：第一轮返回一个工具调用，其后返回纯文本；记录 tool-role
/// 回填用于断言工具被拒绝而非执行。
private final class Wire258ToolEmittingProvider: LLMProvider, @unchecked Sendable {
    let name = "Wiring258 provider"
    var model = LLMModel(id: "wire-258", displayName: "Wiring 258", provider: "Test")
    let capabilities: Set<ProviderCapability> = [.streaming, .tools]

    private let toolName: String
    private let toolArguments: [String: Any]
    private var callIndex = 0
    private var toolResultMessages: [String] = []

    init(toolName: String, toolArguments: [String: Any]) {
        self.toolName = toolName
        self.toolArguments = toolArguments
    }

    var receivedToolResults: [String] { toolResultMessages }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        LLMResponse(text: "OK", stopReason: "stop", usage: nil)
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        for message in messages where message.role == .tool {
            toolResultMessages.append(message.content)
        }
        defer { callIndex += 1 }
        if callIndex == 0 {
            return LLMResponse(
                text: "",
                stopReason: "tool_calls",
                usage: nil,
                toolCalls: [LLMToolCall(
                    id: "wire-258-tool-1",
                    name: toolName,
                    rawArguments: (try? JSONSerialization.data(withJSONObject: toolArguments))
                        .map { String(data: $0, encoding: .utf8) ?? "{}" } ?? "{}",
                    arguments: toolArguments
                )]
            )
        }
        return LLMResponse(text: "OK", stopReason: "stop", usage: nil)
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
