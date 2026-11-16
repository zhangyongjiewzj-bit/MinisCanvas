import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - R8 对话执行阶段新输入优先级（显式打断 / 默认排队）
//
// Goal18：默认排队，显式打断偏好与打断快捷键仍立即执行；
// Esc 停止后队列保留，展示元数据不进入模型正文。
// 设置：AgentSettings.newMessageInterruptsGeneration（Goal18 默认 false）+ SettingsCenter + 设置页 Toggle。

@Suite("R8 对话新输入优先级")
@MainActor
struct R8InterruptOnNewMessageTests {

    /// 等 isStreaming 翻转（有界等待，Mock 逐字上屏有延迟）。
    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && !condition() {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    // MARK: 显式打断模式

    @Test func interruptModeNewMessageStopsOldGeneration() async {
        let chat = ChatStore()
        chat.newMessageInterruptsGeneration = { true }
        chat.draftText = "第一个任务"
        chat.sendDraft()
        // 流式开始
        let started = await waitUntil { chat.isStreaming }
        #expect(started)
        let userCountBefore = chat.messages.filter { $0.role == .user }.count

        // 生成中发送新消息 → 默认打断：旧任务停止 + 新消息立即执行
        chat.draftText = "新任务"
        chat.sendDraft()

        let stopped = await waitUntil { !chat.isStreaming }
        #expect(stopped) // 旧生成被打断
        let userCountAfter = chat.messages.filter { $0.role == .user }.count
        #expect(userCountAfter == userCountBefore + 1) // 新消息已发出并执行
        // 被打断的消息带「已中断」标注
        let interrupted = chat.messages.contains { $0.wasInterrupted }
        #expect(interrupted)
        // 新任务有自己的 assistant 回复（新流式）
        let newReply = chat.messages.last
        #expect(newReply?.role == .assistant)
    }

    // MARK: 排队模式（关闭打断开关）

    @Test func queueModeNewMessagePreservesCurrentGeneration() async {
        let chat = ChatStore()
        chat.newMessageInterruptsGeneration = { false } // 设置里关闭打断
        chat.draftText = "第一个任务"
        chat.sendDraft()
        let started = await waitUntil { chat.isStreaming }
        #expect(started)
        let userCountBefore = chat.messages.filter { $0.role == .user }.count

        // 转向模式：新消息不打断，加入队列等待当前回合结束
        chat.draftText = "转向指令"
        chat.sendDraft()
        let stillStreaming = await waitUntil { chat.isStreaming }
        #expect(stillStreaming) // 旧生成继续
        #expect(chat.activeQueuedComposerMessages.contains { $0.text == "转向指令" })
        #expect(chat.pendingSteers.isEmpty)
        let userCountAfter = chat.messages.filter { $0.role == .user }.count
        #expect(userCountAfter == userCountBefore) // 未追加用户消息
    }

    // MARK: 设置默认 + 持久化

    @Test func agentSettingDefaultsToQueue() {
        #expect(AgentSettings.default.newMessageInterruptsGeneration == false)
    }

    @Test func agentSettingRoundTripsThroughCodable() throws {
        var settings = AgentSettings.default
        settings.newMessageInterruptsGeneration = false
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AgentSettings.self, from: data)
        #expect(decoded.newMessageInterruptsGeneration == false)
    }

    @Test func agentSettingMissingKeyDefaultsToQueue() throws {
        // 旧 JSON 无该字段 → 解码默认 false（排队）
        let legacyJSON = """
        {"maxLoopIterations":10,"toolTimeoutSeconds":300,"concurrentToolLimit":4,
         "autoCompactThreshold":0.8,"fallbackEnabled":true,"personaEnabled":false,
         "personaPreset":"professional","memoryEnabled":true,
         "approvalPolicy":"alwaysAsk","availableModelWhitelist":[]}
        """
        let decoded = try JSONDecoder().decode(
            AgentSettings.self,
            from: Data(legacyJSON.utf8)
        )
        #expect(decoded.newMessageInterruptsGeneration == false)
    }
}
