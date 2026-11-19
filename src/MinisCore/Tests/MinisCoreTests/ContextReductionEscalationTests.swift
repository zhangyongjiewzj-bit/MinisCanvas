import Foundation
import Testing
@testable import MinisCore

/// R3-04：一个回合里连续读了几份长文件，最近 6 条工具结果原样保留，请求就到了 95%。
/// 拒绝之前先把“原样保留最近几条”逐级降到 2 条、1 条再算一次；只动请求副本。
@Suite("窗口准入：到 95% 拒绝之前先降低工具结果保留条数")
struct ContextReductionEscalationTests {
    private func toolRounds(_ count: Int, characters: Int = 30_000) -> [LLMMessage] {
        var messages = [LLMMessage(role: .user, content: "读这几份文件")]
        for index in 0..<count {
            let call = LLMToolCall(id: "call-\(index)", name: "file_read", rawArguments: "{}", arguments: [:])
            messages.append(LLMMessage(role: .assistant, content: "", toolCalls: [call]))
            messages.append(LLMMessage(role: .tool,
                content: String(repeating: Character(UnicodeScalar(0x4E00 + index)!), count: characters),
                toolCallID: "call-\(index)"))
        }
        return messages
    }

    /// 窗口按当前估算占用 97% 反推；不允许压缩，所以只剩缩减和 95% 拒绝。
    private func run(for messages: [LLMMessage]) throws -> (ContextAdmissionRun, ContextAdmissionConfig) {
        let cost = try #require(AgentContextTokenBudget.estimatedInputCost(messages, systemPrompt: ""))
        let config = try #require(ContextAdmissionConfig(
            windowTokens: Int(Double(cost) / 0.97), triggerFraction: 0.8, allowsCompaction: false))
        return (ContextAdmissionRun(config: config), config)
    }

    @Test func sixLargeToolResultsAreNotRefusedAndOnlyTheNewestTwoStayInFull() throws {
        let messages = toolRounds(6)
        let (initial, config) = try run(for: messages)
        var admission = initial
        let decision = try admission.decide(messages: messages, systemPrompt: "")
        #expect(decision == .proceed)
        let lengths = config.reduction.apply(messages).filter { $0.role == .tool }.map(\.content.count)
        #expect(lengths.count == 6)
        #expect(lengths.suffix(2).allSatisfy { $0 == 30_000 })
        #expect(lengths.prefix(4).allSatisfy { $0 < 30_000 })
        // 只动请求副本：原消息不变，配对不变。
        #expect(messages.filter { $0.role == .tool }.allSatisfy { $0.content.count == 30_000 })
    }

    @Test func protectionIsLoweredOneStepAtATimeNotMoreThanNeeded() throws {
        // 三条：保留 6 条时占 97% 被拦；降到 2 条后最早一条被缩减，占用降到 95% 以下就停。
        let messages = toolRounds(3)
        let (initial, config) = try run(for: messages)
        var admission = initial
        let decision = try admission.decide(messages: messages, systemPrompt: "")
        if case .blocked = decision { Issue.record("should not be blocked, got \(decision)") }
        let lengths = config.reduction.apply(messages).filter { $0.role == .tool }.map(\.content.count)
        #expect(lengths.suffix(2).allSatisfy { $0 == 30_000 })
        #expect(lengths[0] < 30_000)
    }

    @Test func aSingleHugeResultStillEndsInTheTypedRefusal() throws {
        let messages = toolRounds(1)
        let (initial, _) = try run(for: messages)
        var admission = initial
        let decision = try admission.decide(messages: messages, systemPrompt: "")
        guard case .blocked = decision else {
            Issue.record("a lone full-size result cannot be reduced, expected blocked, got \(decision)")
            return
        }
    }

    /// 子智能体、后台任务没有“压缩后重试”按钮，也不能新开会话继续：它们的窗口已满说明不能再指向这些。
    @Test func delegatedWindowFullTextDoesNotPointAtForegroundButtons() {
        let foreground = AgentLoopError.contextWindowFull(fraction: 0.97).localizedDescription
        #expect(AgentLoopError.isContextWindowFullForegroundDescription(foreground))
        for chinese in [true, false] {
            for subagent in [true, false] {
                let text = AgentLoopError.contextWindowFullDelegatedDescription(subagent: subagent, isChinese: chinese)
                #expect(!AgentLoopError.isContextWindowFullForegroundDescription(text), "text was: \(text)")
                #expect(!text.contains("压缩后重试") && !text.contains("新开会话继续") && !text.contains("Compact and retry"))
            }
        }
        #expect(AgentLoopError.contextWindowFullDelegatedDescription(subagent: true, isChinese: true).contains("重派"))
    }

    @Test func theRefusalTextPointsAtTheButtonsThatExist() {
        // 文案随系统语言，中英文两种写法都要点到“压缩后重试”这个按钮。
        let text = AgentLoopError.contextWindowFull(fraction: 0.97).localizedDescription
        #expect(text.contains("压缩后重试") || text.contains("Compact and retry"), "refusal text was: \(text)")
    }
}
