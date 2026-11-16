import Testing
import Foundation
@testable import MinisCanvasApp

// MARK: - F16b-2 文档 AI 流水线执行引擎测试
// 覆盖：单阶段执行即停（铁律）/ input 解析与 {{input}} 组装 / 编辑后 rerun +
// markDownstreamStale 联动 / 错误中文文案 / runAllRemaining 次要入口语义。

/// mock LLM 闭包：记录 prompt，按序返回预设输出；shouldThrow 时抛英文 NSError
///（验证被转成中文友好文案）。
final class MockStageLLM: @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [String]
    var shouldThrow: Bool
    private(set) var prompts: [String] = []
    private(set) var callCount = 0

    init(outputs: [String] = [], shouldThrow: Bool = false) {
        self.outputs = outputs
        self.shouldThrow = shouldThrow
    }

    /// 记录 + 取输出（同步，NSLock 安全）；async 上下文禁锁，锁内逻辑收敛于此。
    private func take(for prompt: String) -> (shouldThrow: Bool, output: String) {
        lock.lock(); defer { lock.unlock() }
        prompts.append(prompt)
        let index = callCount
        callCount += 1
        return (shouldThrow, index < outputs.count ? outputs[index] : "输出-\(index + 1)")
    }

    func call(_ prompt: String) async throws -> String {
        let step = take(for: prompt)
        if step.shouldThrow {
            throw NSError(domain: "mock.llm.error", code: 500,
                          userInfo: [NSLocalizedDescriptionKey: "connection timeout (mock)"])
        }
        return step.output
    }

    var lastPrompt: String? { lock.lock(); defer { lock.unlock() }; return prompts.last }
}

@Suite("F16b-2 runStage 单阶段执行即停")
struct RunStageStopTests {
    @Test func runStageStopsAtAwaitingReviewNotDone() async throws {
        var p = ManjuDocumentTemplate.make()
        let mock = MockStageLLM(outputs: ["整理后正文"])
        try await DocumentStageRunner.runStage(pipeline: &p, index: 0, documentContent: "小说原文", llm: mock.call)
        #expect(p.stages[0].status == .awaitingReview) // 停下等审核，不是 .done
        #expect(p.stages[0].output == "整理后正文")
        #expect(p.stages[0].input == "小说原文")
        // 铁律：绝不自动连跑下一阶段
        for i in 1..<p.stages.count {
            #expect(p.stages[i].status == .pending && p.stages[i].output.isEmpty)
        }
        #expect(mock.callCount == 1)
    }
    @Test func confirmStageOnlyAfterReview() async throws {
        var p = ManjuDocumentTemplate.make()
        let mock = MockStageLLM(outputs: ["v1"])
        try await DocumentStageRunner.runStage(pipeline: &p, index: 0, documentContent: "正文", llm: mock.call)
        DocumentStageRunner.confirmStage(pipeline: &p, index: 99) // 越界无操作
        DocumentStageRunner.confirmStage(pipeline: &p, index: 1)  // 未执行不确认
        #expect(p.stages[1].status == .pending)
        DocumentStageRunner.confirmStage(pipeline: &p, index: 0)  // 人工审核通过
        #expect(p.stages[0].status == .done)
    }
    @Test func outOfBoundsThrowsChineseError() async {
        var p = ManjuDocumentTemplate.make()
        let mock = MockStageLLM()
        await #expect(throws: DocumentStageError.self) {
            try await DocumentStageRunner.runStage(pipeline: &p, index: 99, documentContent: "x", llm: mock.call)
        }
        #expect(mock.callCount == 0)
    }

    @Test func missingUpstreamOutputRefusesWithChineseMessage() async throws {
        var p = ManjuDocumentTemplate.make()
        let mock = MockStageLLM()
        let e = try await #require(throws: DocumentStageError.self) {
            try await DocumentStageRunner.runStage(pipeline: &p, index: 1, documentContent: "正文", llm: mock.call)
        }
        #expect(e.message.contains("剧情大纲"))
        #expect(e.message.contains("先完成上一阶段"))
        #expect(p.stages[1].status == .pending)
        #expect(mock.callCount == 0)
    }
}

@Suite("F16b-2 input 解析与模板组装")
struct InputResolutionTests {
    @Test func firstStageUsesDocContentLaterUsesPreviousOutput() async throws {
        var p = ManjuDocumentTemplate.make()
        let mock0 = MockStageLLM(outputs: ["ok"])
        try await DocumentStageRunner.runStage(pipeline: &p, index: 0, documentContent: "原文", llm: mock0.call)
        // 首阶段：{{input}} 替换为文档正文
        #expect(mock0.lastPrompt == "请将以下小说原文导入并整理排版，保留章节结构与原文内容，不做剧情改写：\n\n原文")

        var p2 = ManjuDocumentTemplate.make()
        p2.stages[0].output = "整理后正文文本"
        p2.stages[0].status = .done
        let mock1 = MockStageLLM(outputs: ["大纲 v1"])
        try await DocumentStageRunner.runStage(pipeline: &p2, index: 1, documentContent: "小说原文", llm: mock1.call)
        // 后续阶段：input = 上一阶段 output（不是文档正文）
        #expect(p2.stages[1].input == "整理后正文文本")
        #expect(mock1.lastPrompt == "请根据以下小说内容提炼剧情大纲，梳理主线、关键冲突、转折点与结局走向：\n\n整理后正文文本")
        #expect(!mock1.lastPrompt!.contains("小说原文"))
    }
    @Test func composePromptPlaceholderAndAppend() {
        // 含 {{input}} → 替换（全部出现处）
        #expect(DocumentStageRunner.composePrompt(template: "前{{input}}后", input: "X") == "前X后")
        #expect(DocumentStageRunner.composePrompt(template: "{{input}}→{{input}}", input: "X") == "X→X")
        // 无占位符 → input 拼接在模板后；空模板 → 仅 input
        #expect(DocumentStageRunner.composePrompt(template: "请总结：", input: "内容A") == "请总结：\n\n内容A")
        #expect(DocumentStageRunner.composePrompt(template: "  ", input: "裸输入") == "裸输入")
    }
}

@Suite("F16b-2 编辑后 rerun 与下游 stale 联动")
struct RerunStageTests {
    private func progressedPipeline() -> DocumentPipeline {
        DocumentPipeline(stages: ["导入", "大纲", "剧本"].enumerated().map { i, name in
            DocumentStage(name: name, promptTemplate: "T\(i)\n{{input}}",
                          output: "输出 v1", status: i < 2 ? .done : .awaitingReview)
        })
    }
    @Test func rerunAfterEditBackToAwaitingReviewAndMarksDownstreamStale() async throws {
        var p = progressedPipeline()
        // 回跳编辑上游（阶段 0）output → UI 标下游 stale → 重跑阶段 1
        p.stages[0].output = "正文 v1（人工润色）"
        p.markDownstreamStale(fromIndex: 0) // UI 回跳编辑 → 下游 stale
        #expect(p.stages[1].status == .stale)
        // 阶段 2 之前已跑完待审核（awaitingReview）：验证重跑成功后引擎重新标其 stale
        p.stages[2].status = .awaitingReview
        let mock = MockStageLLM(outputs: ["大纲 v2"])
        try await DocumentStageRunner.rerunStage(pipeline: &p, index: 1, documentContent: "正文", llm: mock.call)
        // 重跑后回 awaitingReview（需再次人工审核），input 取编辑后的上游 output
        #expect(p.stages[1].status == .awaitingReview)
        #expect(p.stages[1].output == "大纲 v2")
        #expect(p.stages[1].input == "正文 v1（人工润色）")
        // 联动：重跑成功 → 阶段 1 output 已变 → 下游标 stale；上游不动
        #expect(p.stages[0].status == .done)
        #expect(p.stages[2].status == .stale)
    }
    @Test func rerunErrorKeepsEditedOutput() async {
        var p = progressedPipeline()
        p.stages[1].output = "人工润色的大纲"
        let mock = MockStageLLM(shouldThrow: true)
        await #expect(throws: DocumentStageError.self) {
            try await DocumentStageRunner.rerunStage(pipeline: &p, index: 1, documentContent: "正文", llm: mock.call)
        }
        #expect(p.stages[1].status == .pending)
        #expect(p.stages[1].output == "人工润色的大纲") // 失败保留人工编辑
        #expect(p.stages[2].status == .awaitingReview)  // 失败不动下游
    }
}

@Suite("F16b-2 错误中文文案")
struct StageErrorTests {
    @Test func llmErrorKeepsPendingAndReturnsChineseMessage() async throws {
        var p = ManjuDocumentTemplate.make()
        let mock = MockStageLLM(shouldThrow: true)
        let e = try await #require(throws: DocumentStageError.self) {
            try await DocumentStageRunner.runStage(pipeline: &p, index: 0, documentContent: "正文", llm: mock.call)
        }
        #expect(e.message.contains("小说导入"))
        #expect(e.message.contains("执行失败"))
        // 友好文案：不糊英文堆栈/错误域/原始英文描述
        #expect(!e.message.contains("NSError"))
        #expect(!e.message.contains("mock.llm.error"))
        #expect(!e.message.contains("connection timeout"))
        #expect(e.errorDescription == e.message)
        #expect(p.stages[0].status == .pending)
        #expect(p.stages[0].output.isEmpty)
    }
    @Test func cancellationGivesChineseMessage() async throws {
        var p = ManjuDocumentTemplate.make()
        let cancelLLM: StageLLMCall = { _ in throw CancellationError() }
        let e = try await #require(throws: DocumentStageError.self) {
            try await DocumentStageRunner.runStage(pipeline: &p, index: 0, documentContent: "正文", llm: cancelLLM)
        }
        #expect(e.message.contains("取消"))
        #expect(p.stages[0].status == .pending)
    }
}

@Suite("F16b-2 runAllRemaining 次要辅助入口")
struct RunAllRemainingTests {
    @Test func runsOneStagePerCallAndStopsEachTime() async throws {
        var p = ManjuDocumentTemplate.make()
        let mock = MockStageLLM(outputs: ["A", "B", "C"])
        // 第 1 次调用：只跑阶段 0 即停；再次调用仍只推进一个阶段，前一阶段不自动确认
        let i1 = try await DocumentStageRunner.runAllRemaining(pipeline: &p, documentContent: "小说原文", llm: mock.call)
        #expect(i1 == 0)
        #expect(p.stages[0].status == .awaitingReview)
        #expect(mock.callCount == 1)
        let i2 = try await DocumentStageRunner.runAllRemaining(pipeline: &p, documentContent: "小说原文", llm: mock.call)
        #expect(i2 == 1)
        #expect(p.stages[1].status == .awaitingReview)
        #expect(p.stages[0].status == .awaitingReview)
        #expect(p.stages[1].input == "A") // 链式：input = 上阶段 output
        #expect(mock.callCount == 2)
        // 模拟人工逐个审核后继续
        DocumentStageRunner.confirmStage(pipeline: &p, index: 0)
        DocumentStageRunner.confirmStage(pipeline: &p, index: 1)
        let i3 = try await DocumentStageRunner.runAllRemaining(pipeline: &p, documentContent: "小说原文", llm: mock.call)
        #expect(i3 == 2)
        #expect(p.stages[2].status == .awaitingReview)
        #expect(p.stages[2].input == "B")
        #expect(mock.callCount == 3)
    }

    @Test func prefersStaleOverLaterPending() async throws {
        var p = ManjuDocumentTemplate.make()
        p.stages[0].output = "正文"
        p.stages[0].status = .done
        p.stages[1].output = "旧大纲"
        p.stages[1].status = .stale
        let mock = MockStageLLM(outputs: ["新大纲"])
        let i = try await DocumentStageRunner.runAllRemaining(pipeline: &p, documentContent: "小说原文", llm: mock.call)
        #expect(i == 1) // 优先重跑 stale（待重跑），而不是后面的 pending
        #expect(p.stages[1].status == .awaitingReview)
        #expect(p.stages[1].output == "新大纲")
        #expect(p.stages[1].input == "正文")
    }

    @Test func nothingRunnableReturnsNil() async throws {
        var p = DocumentPipeline(stages: [
            DocumentStage(name: "A", status: .done),
            DocumentStage(name: "B", status: .awaitingReview),
        ])
        let mock = MockStageLLM()
        let i = try await DocumentStageRunner.runAllRemaining(pipeline: &p, documentContent: "x", llm: mock.call)
        #expect(i == nil)
        #expect(mock.callCount == 0)
        var empty = DocumentPipeline()
        let j = try await DocumentStageRunner.runAllRemaining(pipeline: &empty, documentContent: "x", llm: mock.call)
        #expect(j == nil)
    }

    @Test func llmErrorPropagatesAndStageStaysPending() async {
        var p = ManjuDocumentTemplate.make()
        let mock = MockStageLLM(shouldThrow: true)
        await #expect(throws: DocumentStageError.self) {
            try await DocumentStageRunner.runAllRemaining(pipeline: &p, documentContent: "正文", llm: mock.call)
        }
        #expect(p.stages[0].status == .pending)
    }
}
