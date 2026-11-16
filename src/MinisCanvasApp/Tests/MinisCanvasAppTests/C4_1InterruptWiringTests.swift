import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - C4-1 打断接线（停止按钮 → TurnController.interrupt）
//
// C4 Codex 对照检查 Top1：UI 停止按钮只取消流任务，AgentLoop 的 in-flight
// 调用不会被干净中断（TurnController 引擎已就绪但 AgentLoopChatEngine 未传参）。
// 本文件覆盖接线链路（引擎层边界抛 InterruptedError 行为已由 MinisCore
// TurnControlTests 覆盖，不重复）：
//   · AgentLoopChatEngine.interrupt() → TurnController 标志置位（引擎转发）
//   · ChatStore.stopStreaming() → 引擎 interrupt 被调 + isStreaming 复位
//     + 按钮切回发送态（isStreaming 驱动）+ 流式气泡「已中断」提示 + 已输出保留

@Suite("C4-1 停止按钮 → TurnController.interrupt 接线")
@MainActor
struct C4_1InterruptWiringTests {

    // MARK: 引擎层：interrupt() 转发到 TurnController

    @Test func agentLoopEngineInterruptForwardsToTurnController() async throws {
        let controller = TurnController()
        let engine = AgentLoopChatEngine(turnController: controller)

        // 引擎构造已把控制器传给 AgentLoop（C4 Top1 缺失的一环）。
        // 真实场景=流式中点停止：回合运行中（depth>0）调 interrupt()，
        // 信号指向当前回合（pending=turnID），isCancelled() 立即为真。
        await controller.start()
        engine.interrupt()

        // engine.interrupt() 经 unstructured Task 异步置位 actor 标志：
        // 有界轮询等待生效（回合保持运行，信号不会被 start() 清除）。
        var cancelled = false
        for _ in 0..<200 {
            if await controller.isCancelled() { cancelled = true; break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        await controller.finish()
        #expect(cancelled, "engine.interrupt() 应转发到 TurnController")
    }

    // MARK: ChatStore 层：停止按钮调用链 + 状态复位

    @Test func stopStreamingCallsEngineInterruptAndResetsState() async throws {
        let chat = ChatStore()
        let mock = InterruptRecordingEngine()
        chat.agentEngine = mock

        chat.draftText = "打断测试"
        chat.sendDraft()
        #expect(chat.isStreaming)

        // 等首段输出上屏（打字机 3 字/16ms），确认「已输出保留」可断言
        var waited: TimeInterval = 0
        while !(chat.messages.last?.content.contains("部分输出") ?? false) && waited < 5 {
            try await Task.sleep(for: .milliseconds(20))
            waited += 0.02
        }
        #expect(chat.messages.last?.content.contains("部分输出") == true)
        let beforeStop = try #require(chat.messages.last)
        #expect(beforeStop.role == .assistant)
        #expect(!beforeStop.wasInterrupted)

        chat.stopStreaming()

        // 1) 引擎 interrupt 被调（C4-1 核心接线）
        #expect(mock.interruptCount == 1)
        // 2) 状态复位：isStreaming 关 → 发送/停止按钮切回发送态
        #expect(!chat.isStreaming)
        // 3) 流式气泡收尾：isStreaming 复位 + 「已中断」提示
        #expect(chat.messages.last?.isStreaming == false)
        // P-08: the visible interruption marker is metadata, never body text.
        let stopped = try #require(chat.messages.last)
        #expect(stopped.id == beforeStop.id)
        #expect(stopped.wasInterrupted)
        #expect(stopped.content == beforeStop.content)
        #expect(!stopped.content.contains("已中断"))
        #expect(stopped.asLLMMessage().content == beforeStop.content)
        // 4) 已输出保留（打断不清空已有文本）
        #expect(chat.messages.last?.content.contains("部分输出") == true)
    }

    @Test func stopStreamingWhenIdleDoesNotAppendHint() {
        let chat = ChatStore()
        let before = chat.messages.last?.content

        chat.stopStreaming()

        #expect(!chat.isStreaming)
        #expect(chat.messages.last?.content == before)
        #expect(chat.messages.last?.content.contains("已中断") == false)
    }

    @Test func repeatedStopStreamingAppendsHintOnlyOnce() async throws {
        let chat = ChatStore()
        let mock = InterruptRecordingEngine()
        chat.agentEngine = mock

        chat.draftText = "连续停止"
        chat.sendDraft()
        #expect(chat.isStreaming)

        let beforeStop = try #require(chat.messages.last)
        #expect(beforeStop.role == .assistant)
        #expect(!beforeStop.wasInterrupted)
        let messageIDs = chat.messages.map(\.id)
        chat.stopStreaming()
        let firstStop = try #require(chat.messages.last)
        #expect(firstStop.id == beforeStop.id)
        #expect(firstStop.wasInterrupted)
        #expect(firstStop.content == beforeStop.content)
        chat.stopStreaming()

        #expect(mock.interruptCount == 1, "重复停止不得向引擎重复排队 interrupt")
        #expect(!chat.isStreaming)
        let repeatedStop = try #require(chat.messages.last)
        #expect(chat.messages.map(\.id) == messageIDs)
        #expect(repeatedStop.id == firstStop.id)
        #expect(repeatedStop.wasInterrupted)
        #expect(chat.messages.filter { $0.wasInterrupted }.map(\.id) == [beforeStop.id],
                "重复停止只保留同一条助手消息的一个中断标记")
        #expect(repeatedStop.content == firstStop.content)
        #expect(repeatedStop.content == beforeStop.content)
        #expect(!repeatedStop.content.contains("已中断"))
        #expect(repeatedStop.asLLMMessage().content == beforeStop.content)
    }

    @Test func programmaticStopWhileIdleDoesNotInterruptNextSend() async throws {
        let chat = ChatStore()
        let mock = InterruptRecordingEngine(finishesImmediately: true)
        chat.agentEngine = mock

        chat.draftText = "第一轮"
        chat.sendDraft()

        var waited: TimeInterval = 0
        while chat.isStreaming && waited < 5 {
            try await Task.sleep(for: .milliseconds(20))
            waited += 0.02
        }
        #expect(!chat.isStreaming)
        #expect(chat.messages.last?.content.contains("完成输出") == true)

        // 会话切换等程序性停止发生在空闲态时，不能给 TurnController 排队下一轮中断。
        let interruptCountAfterFirstTurn = mock.interruptCount
        chat.stopStreamingForSwitch()
        #expect(mock.interruptCount == interruptCountAfterFirstTurn)
        #expect(chat.messages.last?.content.contains("已中断") == false)

        chat.draftText = "第二轮"
        chat.sendDraft()
        waited = 0
        while chat.isStreaming && waited < 5 {
            try await Task.sleep(for: .milliseconds(20))
            waited += 0.02
        }

        #expect(!chat.isStreaming)
        #expect(chat.messages.last?.content.contains("完成输出") == true)
        #expect(chat.messages.last?.content.contains("已中断") == false)
        #expect(mock.interruptCount == interruptCountAfterFirstTurn)
    }

    @Test func programmaticStopWhileStreamingDoesNotInterruptEngine() async throws {
        let chat = ChatStore()
        let mock = InterruptRecordingEngine()
        chat.agentEngine = mock

        chat.draftText = "流式切换"
        chat.sendDraft()
        #expect(chat.isStreaming)

        var waited: TimeInterval = 0
        while !(chat.messages.last?.content.contains("部分输出") ?? false) && waited < 5 {
            try await Task.sleep(for: .milliseconds(20))
            waited += 0.02
        }
        #expect(chat.messages.last?.content.contains("部分输出") == true)

        // 程序性停止（切换/新建/压缩等）绝不向引擎发 interrupt()：
        // 打字机阶段 isStreaming 仍 true 但 TurnController depth==0，异步 interrupt
        // 会被排队给下一 turn → 所有后续对话首轮必「已中断」（用户实测全灭）。
        chat.stopStreamingForSwitch()

        #expect(mock.interruptCount == 0, "程序性停止不得调用引擎 interrupt")
        #expect(!chat.isStreaming)
        // 程序性停止不是用户主动打断，不加「⏹ 已中断」提示。
        #expect(chat.messages.last?.content.contains("已中断") == false)
    }

    @Test func programmaticStopWhileStreamingThenNextSendSucceeds() async throws {
        let chat = ChatStore()
        let hanging = InterruptRecordingEngine()          // 第一轮：挂起流（模拟生成中）
        let immediate = InterruptRecordingEngine(finishesImmediately: true) // 第二轮：立即完成
        chat.agentEngine = hanging

        chat.draftText = "第一轮"
        chat.sendDraft()
        #expect(chat.isStreaming)
        var waited: TimeInterval = 0
        while !(chat.messages.last?.content.contains("部分输出") ?? false) && waited < 5 {
            try await Task.sleep(for: .milliseconds(20))
            waited += 0.02
        }
        #expect(chat.messages.last?.content.contains("部分输出") == true)

        // 流式态程序性停止（模拟：切到别的对话）。
        chat.stopStreamingForSwitch()
        #expect(!chat.isStreaming)
        #expect(hanging.interruptCount == 0)

        // 切回/新对话发送：不得被上一轮排队中断命中，正常完成。
        chat.agentEngine = immediate
        chat.draftText = "第二轮"
        chat.sendDraft()
        waited = 0
        // immediate 引擎同步完成，isStreaming 可能瞬时翻转——轮询内容而非 isStreaming。
        while !(chat.messages.last?.content.contains("完成输出") ?? false) && waited < 5 {
            try await Task.sleep(for: .milliseconds(20))
            waited += 0.02
        }
        #expect(chat.messages.last?.content.contains("完成输出") == true)
        #expect(chat.messages.last?.content.contains("已中断") == false)
    }
}
