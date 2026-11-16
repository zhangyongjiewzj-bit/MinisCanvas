import Foundation
import Testing
@testable import MinisCore

// D2 Workflow 记忆：模板预置完整性 / runner 全流程（mock provider）/ 断点续跑 /
// maxSteps / 缺输入 / 存储持久化 / DeepLink 接线。
// NOTE: Swift Testing（CLT toolchain，无 XCTest）——见 SanitizeToolIdTests 头注释。

// MARK: - Mock Provider

private enum WorkflowTestError: Error, Equatable {
    case boom
}

/// 记录每次调用的 step id 与填充后的 prompt；可选「首次调用某步骤时失败一次」。
private actor RecordingProvider: WorkflowProvider {
    var calls: [(stepID: String, prompt: String)] = []
    var failOnceStepID: String?

    init(failOnceStepID: String? = nil) {
        self.failOnceStepID = failOnceStepID
    }

    func generate(prompt: String, step: WorkflowStep) async throws -> String {
        if let fail = failOnceStepID, step.id == fail {
            failOnceStepID = nil
            throw WorkflowTestError.boom
        }
        calls.append((step.id, prompt))
        return "OUT:\(step.id)"
    }

    func callStepIDs() -> [String] { calls.map { $0.stepID } }
    func prompt(for stepID: String) -> String? { calls.first { $0.stepID == stepID }?.prompt }
    /// 最后一次调用某步骤的 prompt（换输入重跑场景：验证新输入生效）。
    func lastPrompt(for stepID: String) -> String? { calls.last { $0.stepID == stepID }?.prompt }
}

private func makeTempStoreDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("WorkflowTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - 模板预置完整性

struct WorkflowTemplatePresetTests {

    @Test func threePresetsExistWithExpectedShape() throws {
        let presets = WorkflowTemplate.presets
        #expect(presets.count == 3)
        #expect(presets.map(\.id) == ["manju-full", "manju-novel-breakdown", "manju-storyboard-prompts"])
        #expect(presets.map(\.name) == ["漫剧全流程", "小说拆解", "分镜提示词"])
    }

    @Test func presetStepCounts() throws {
        #expect(WorkflowTemplate.manjuFullFlow.steps.count == 7)
        #expect(WorkflowTemplate.manjuNovelBreakdown.steps.count == 4)
        #expect(WorkflowTemplate.manjuStoryboardPrompts.steps.count == 3)
    }

    @Test func allPresetsValidate() throws {
        for preset in WorkflowTemplate.presets {
            #expect(throws: Never.self) { try preset.validate() }
        }
    }

    @Test func everyStepReferencesManjuRules() throws {
        // 每步 prompt 模板都要引用 manju 铁律
        for preset in WorkflowTemplate.presets {
            for step in preset.steps {
                #expect(step.promptTemplate.contains("manju"), "步骤 \(step.id) 未引用 manju 铁律")
                #expect(step.promptTemplate.contains("铁律"), "步骤 \(step.id) 未引用铁律")
            }
        }
    }

    @Test func fullFlowOutputChainIsResolvable() throws {
        // 每个步骤的 inputs 必须能被 requiredInputs + 前面步骤 outputKey 覆盖
        let template = WorkflowTemplate.manjuFullFlow
        var available = Set(template.requiredInputs)
        for step in template.steps {
            for input in step.inputs {
                #expect(available.contains(input), "步骤 \(step.id) 的输入 \(input) 无法解析")
            }
            available.insert(step.outputKey)
        }
        #expect(template.steps.map(\.outputKey) == ["novel", "plot", "script", "storyboard", "imagePrompt", "imageJob", "videoJob"])
    }

    @Test func storyboardPromptsChainIsResolvable() throws {
        let template = WorkflowTemplate.manjuStoryboardPrompts
        var available = Set(template.requiredInputs)
        for step in template.steps {
            for input in step.inputs {
                #expect(available.contains(input), "步骤 \(step.id) 的输入 \(input) 无法解析")
            }
            available.insert(step.outputKey)
        }
        #expect(template.steps.map(\.outputKey) == ["storyboardNormalized", "imagePrompt", "videoPrompt"])
    }

    @Test func presetTemplatesAreValidWorkflowsForRunner() throws {
        // 预置模板必须都能通过 WorkflowRunner 的静态填充校验（占位符可解析）
        for preset in WorkflowTemplate.presets {
            var inputs: [String: String] = [:]
            for key in preset.requiredInputs { inputs[key] = "输入\(key)" }
            var outputs: [String: String] = [:]
            for step in preset.steps {
                let filled = try WorkflowRunner.fill(template: step.promptTemplate, stepID: step.id, inputs: inputs, outputs: outputs)
                #expect(!filled.isEmpty)
                #expect(!filled.contains("{{"), "步骤 \(step.id) 仍有未填充占位符")
                outputs[step.outputKey] = "输出\(step.outputKey)"
            }
        }
    }
}

// MARK: - Runner 全流程（mock provider）

struct WorkflowRunnerFlowTests {

    @Test func runsAllStepsInOrderWithFilledPrompts() async throws {
        let provider = RecordingProvider()
        let runner = WorkflowRunner()
        let template = WorkflowTemplate.manjuStoryboardPrompts

        let result = try await runner.run(template: template, inputs: ["storyboard": "分镜文本A"], provider: provider)

        // 步骤顺序
        #expect(result.executedStepIDs == ["storyboard_normalize", "image_prompt_8slot", "video_prompt_9slot"])
        #expect(result.cachedStepIDs.isEmpty)
        // 输出传递
        #expect(result.outputs["storyboardNormalized"] == "OUT:storyboard_normalize")
        #expect(result.outputs["imagePrompt"] == "OUT:image_prompt_8slot")
        #expect(result.outputs["videoPrompt"] == "OUT:video_prompt_9slot")
        // LLM 调用次数 = 步骤数
        #expect(await provider.callStepIDs() == ["storyboard_normalize", "image_prompt_8slot", "video_prompt_9slot"])
        // 输入填充：第一步 prompt 含用户输入的分镜文本
        let step1Prompt = await provider.prompt(for: "storyboard_normalize")
        #expect(step1Prompt?.contains("分镜文本A") == true)
        // 输出传递：第 2 步引用第 1 步输出，第 3 步引用第 1、2 步输出
        let step2Prompt = await provider.prompt(for: "image_prompt_8slot")
        #expect(step2Prompt?.contains("OUT:storyboard_normalize") == true)
        let step3Prompt = await provider.prompt(for: "video_prompt_9slot")
        #expect(step3Prompt?.contains("OUT:storyboard_normalize") == true)
        #expect(step3Prompt?.contains("OUT:image_prompt_8slot") == true)
    }

    @Test func fullFlowRunsAllSevenSteps() async throws {
        let provider = RecordingProvider()
        let runner = WorkflowRunner()
        let result = try await runner.run(
            template: WorkflowTemplate.manjuFullFlow,
            inputs: ["novel": "第一章：少年醒来。"],
            provider: provider
        )
        #expect(result.executedStepIDs.count == 7)
        #expect(result.outputs["videoJob"] == "OUT:video_gen")
        #expect(await provider.callStepIDs().count == 7)
    }

    @Test func missingRequiredInputThrows() async {
        let runner = WorkflowRunner()
        await #expect(throws: WorkflowError.missingRequiredInput(templateID: "manju-full", key: "novel")) {
            try await runner.run(template: WorkflowTemplate.manjuFullFlow, inputs: [:], provider: RecordingProvider())
        }
    }

    @Test func unresolvablePlaceholderThrows() async throws {
        let template = WorkflowTemplate(
            id: "bad", name: "坏模板", description: "引用了不存在的输入",
            steps: [WorkflowStep(id: "s1", type: .custom, title: "步骤", promptTemplate: "内容：{{ghost}}", inputs: ["ghost"], outputKey: "out")]
        )
        let runner = WorkflowRunner()
        await #expect(throws: WorkflowError.missingInput(stepID: "s1", key: "ghost")) {
            try await runner.run(template: template, inputs: [:], provider: RecordingProvider())
        }
    }

    @Test func maxStepsLimitEnforced() async throws {
        let runner = WorkflowRunner(configuration: .init(maxSteps: 2))
        await #expect(throws: WorkflowError.tooManySteps(limit: 2, actual: 3)) {
            try await runner.run(template: WorkflowTemplate.manjuStoryboardPrompts, inputs: ["storyboard": "x"], provider: RecordingProvider())
        }
    }

    @Test func firstStepFailureLeavesEmptyCheckpoint() async {
        // 边界：第 1 步（index 0）就失败 → stepFailed(index: 0)，断点保持为空
        let provider = RecordingProvider(failOnceStepID: "storyboard_normalize")
        let runner = WorkflowRunner()
        await #expect(throws: WorkflowError.stepFailed(stepID: "storyboard_normalize", index: 0, underlying: "Provider error")) {
            try await runner.run(
                template: WorkflowTemplate.manjuStoryboardPrompts,
                inputs: ["storyboard": "文本"],
                provider: provider
            )
        }
        #expect(runner.completedOutputs(templateID: WorkflowTemplate.manjuStoryboardPrompts.id).isEmpty)
    }

    @Test func emptyStringInputCountsAsPresent() async throws {
        // 边界：inputs 中 key 存在但值为空串 → 不算缺失，照常执行
        let provider = RecordingProvider()
        let runner = WorkflowRunner()
        let result = try await runner.run(
            template: WorkflowTemplate.manjuStoryboardPrompts,
            inputs: ["storyboard": ""],
            provider: provider
        )
        #expect(result.executedStepIDs.count == 3)
        #expect(result.outputs["storyboardNormalized"] == "OUT:storyboard_normalize")
    }
}

// MARK: - 断点续跑

struct WorkflowRunnerResumeTests {

    @Test func failedStepResumesFromCheckpointWithoutRedo() async throws {
        // 第 3 步（script）首次调用失败
        let provider = RecordingProvider(failOnceStepID: "script")
        let runner = WorkflowRunner()
        let template = WorkflowTemplate.manjuNovelBreakdown

        // 第一次运行：novel/plot 成功，script 失败
        await #expect(throws: WorkflowError.stepFailed(stepID: "script", index: 2, underlying: "Provider error")) {
            try await runner.run(template: template, inputs: ["novel": "小说"], provider: provider)
        }
        // 断点已缓存前两步（按模板 id 隔离，F15）
        let cached = runner.completedOutputs(templateID: template.id)
        #expect(cached["novel"] == "OUT:novel_import")
        #expect(cached["plot"] == "OUT:plot_outline")
        #expect(cached["script"] == nil)

        // 第二次运行（同一 runner）：前两步从断点恢复，只补跑 script/storyboard
        let result = try await runner.run(template: template, inputs: ["novel": "小说"], provider: provider)
        #expect(result.cachedStepIDs == ["novel_import", "plot_outline"])
        #expect(result.executedStepIDs == ["script", "storyboard"])
        #expect(result.outputs["storyboard"] == "OUT:storyboard")
        // 前两步没有被重复调用
        let callCounts = await provider.callStepIDs()
        #expect(callCounts.filter { $0 == "novel_import" }.count == 1)
        #expect(callCounts.filter { $0 == "plot_outline" }.count == 1)
    }

    @Test func explicitCheckpointRestoreSkipsCompletedSteps() async throws {
        let provider = RecordingProvider()
        // 手动构造断点：前两步已完成（F15：断点按模板 id 分槽 + 输入指纹校验）
        let inputs = ["novel": "小说"]
        let fingerprint = WorkflowRunner.inputFingerprint(templateID: "manju-novel-breakdown", inputs: inputs)
        let checkpoint = WorkflowCheckpoint(completed: [
            "manju-novel-breakdown": .init(
                fingerprint: fingerprint,
                outputs: ["novel": "已缓存小说", "plot": "已缓存剧情"]
            ),
        ])
        let runner = WorkflowRunner(checkpoint: checkpoint)
        let result = try await runner.run(
            template: WorkflowTemplate.manjuNovelBreakdown,
            inputs: inputs,
            provider: provider
        )
        #expect(result.cachedStepIDs == ["novel_import", "plot_outline"])
        #expect(result.executedStepIDs == ["script", "storyboard"])
        #expect(result.outputs["novel"] == "已缓存小说")
        #expect(result.outputs["plot"] == "已缓存剧情")
        #expect(result.outputs["storyboard"] == "OUT:storyboard")
    }

    @Test func resetClearsCheckpoint() async throws {
        let provider = RecordingProvider(failOnceStepID: "script")
        let runner = WorkflowRunner()
        let template = WorkflowTemplate.manjuNovelBreakdown
        // 失败后留下断点（前 2 步已完成）
        await #expect(throws: WorkflowError.self) {
            try await runner.run(template: template, inputs: ["novel": "小说"], provider: provider)
        }
        #expect(runner.completedOutputs(templateID: template.id).count == 2)
        runner.reset()
        #expect(runner.completedOutputs(templateID: template.id).isEmpty)
    }
}

// MARK: - F15 P1-6 断点隔离（模板 id 分槽 + 输入指纹 + 成功后清空）

struct WorkflowRunnerCheckpointIsolationTests {

    /// 跨模板不命中旧缓存：manju-full 与 manju-novel-breakdown 共享
    /// novel/plot/script/storyboard 四个 outputKey。先在 manju-full 上失败留下断点，
    /// 再跑 manju-novel-breakdown —— 不得命中 manju-full 的缓存（修复前会跳步）。
    @Test func checkpointDoesNotLeakAcrossTemplatesSharingOutputKeys() async throws {
        let provider = RecordingProvider(failOnceStepID: "script") // manju-full 第 3 步失败
        let runner = WorkflowRunner()
        let inputs = ["novel": "同一本小说"]
        await #expect(throws: WorkflowError.self) {
            try await runner.run(template: WorkflowTemplate.manjuFullFlow, inputs: inputs, provider: provider)
        }
        #expect(runner.completedOutputs(templateID: "manju-full").count == 2)

        // 换模板：4 步全部真实执行，0 步命中缓存
        let result = try await runner.run(
            template: WorkflowTemplate.manjuNovelBreakdown, inputs: inputs, provider: provider
        )
        #expect(result.cachedStepIDs.isEmpty)
        #expect(result.executedStepIDs.count == 4)
        // manju-full 自己的断点未被污染
        #expect(runner.completedOutputs(templateID: "manju-full")["novel"] == "OUT:novel_import")
    }

    /// 成功后重跑不跳步：成功完成即丢弃该模板断点（修复前重发同模板 0 步执行直接回显旧结果）。
    @Test func successClearsCheckpointSoRerunExecutesAllSteps() async throws {
        let provider = RecordingProvider()
        let runner = WorkflowRunner()
        let template = WorkflowTemplate.manjuNovelBreakdown
        _ = try await runner.run(template: template, inputs: ["novel": "小说A"], provider: provider)
        // 成功后断点已清空
        #expect(runner.completedOutputs(templateID: template.id).isEmpty)

        // 重跑 = 真正重跑：全部 4 步重新调用 LLM
        let result = try await runner.run(template: template, inputs: ["novel": "小说A"], provider: provider)
        #expect(result.cachedStepIDs.isEmpty)
        #expect(result.executedStepIDs.count == 4)
        #expect(await provider.callStepIDs().count == 8) // 两次运行各 4 步
    }

    /// 换输入不命中旧缓存：失败留断点后换 novel= 输入 → 指纹变化 → 旧断点作废，
    /// 全部重新执行且新输入进入 prompt（修复前旧输出静默覆盖新输入）。
    @Test func changedInputsInvalidateCheckpoint() async throws {
        let provider = RecordingProvider(failOnceStepID: "script")
        let runner = WorkflowRunner()
        let template = WorkflowTemplate.manjuNovelBreakdown
        await #expect(throws: WorkflowError.self) {
            try await runner.run(template: template, inputs: ["novel": "旧小说"], provider: provider)
        }
        #expect(runner.completedOutputs(templateID: template.id).count == 2)

        // 换输入重跑：0 步命中缓存，新输入生效
        let result = try await runner.run(template: template, inputs: ["novel": "新小说"], provider: provider)
        #expect(result.cachedStepIDs.isEmpty)
        #expect(result.executedStepIDs.count == 4)
        let lastNovelPrompt = await provider.lastPrompt(for: "novel_import")
        #expect(lastNovelPrompt?.contains("新小说") == true)
        #expect(lastNovelPrompt?.contains("旧小说") == false)
    }
}

// MARK: - 存储持久化

struct WorkflowStoreTests {

    @Test func emptyStoreListsPresetsOnly() throws {
        let store = WorkflowStore(storeDirectory: try makeTempStoreDir())
        #expect(store.listTemplates().count == 3)
        #expect(store.template(id: "manju-full")?.name == "漫剧全流程")
        #expect(store.template(id: "漫剧全流程")?.id == "manju-full") // name 也可查
    }

    @Test func saveAndReloadPersistsUserTemplate() throws {
        let dir = try makeTempStoreDir()
        let custom = WorkflowTemplate(
            id: "my-custom", name: "我的模板", description: "自定义",
            steps: [WorkflowStep(id: "s1", type: .custom, title: "步骤", promptTemplate: "做{{x}}", inputs: ["x"], outputKey: "out")],
            requiredInputs: ["x"]
        )

        let store1 = WorkflowStore(storeDirectory: dir)
        try store1.saveTemplate(custom)
        #expect(store1.listTemplates().count == 4)

        // 新实例（同目录）能读回
        let store2 = WorkflowStore(storeDirectory: dir)
        #expect(store2.listTemplates().count == 4)
        #expect(store2.template(id: "my-custom")?.name == "我的模板")
        // 持久化文件确实存在
        let file = dir.appendingPathComponent(WorkflowStore.fileName)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func removeTemplateDeletesUserTemplateButKeepsPresets() throws {
        let dir = try makeTempStoreDir()
        let store = WorkflowStore(storeDirectory: dir)
        let custom = WorkflowTemplate(
            id: "my-custom", name: "我的模板", description: "自定义",
            steps: [WorkflowStep(id: "s1", type: .custom, title: "步骤", promptTemplate: "做{{x}}", inputs: ["x"], outputKey: "out")],
            requiredInputs: ["x"]
        )
        try store.saveTemplate(custom)
        #expect(store.removeTemplate(id: "my-custom") == true)
        #expect(store.removeTemplate(id: "my-custom") == false)
        #expect(store.template(id: "my-custom") == nil)
        #expect(store.listTemplates().count == 3)

        // 删除后新实例也不再有
        let store2 = WorkflowStore(storeDirectory: dir)
        #expect(store2.template(id: "my-custom") == nil)
        #expect(store2.listTemplates().count == 3)
    }

    @Test func userCanOverrideAndRestorePreset() throws {
        let dir = try makeTempStoreDir()
        let store = WorkflowStore(storeDirectory: dir)
        var override = WorkflowTemplate.manjuFullFlow
        override.name = "漫剧全流程（定制版）"
        try store.saveTemplate(override)
        #expect(store.template(id: "manju-full")?.name == "漫剧全流程（定制版）")
        #expect(store.listTemplates().count == 3) // 覆盖不增加数量
        store.removeTemplate(id: "manju-full")
        #expect(store.template(id: "manju-full")?.name == "漫剧全流程")
    }

    @Test func saveInvalidTemplateThrows() throws {
        let store = WorkflowStore(storeDirectory: try makeTempStoreDir())
        let bad = WorkflowTemplate(
            id: "bad", name: "坏模板", description: "重复 outputKey",
            steps: [
                WorkflowStep(id: "a", type: .custom, title: "A", promptTemplate: "x", outputKey: "same"),
                WorkflowStep(id: "b", type: .custom, title: "B", promptTemplate: "y", outputKey: "same"),
            ]
        )
        #expect(throws: WorkflowError.invalidTemplate(id: "bad", reason: "outputKey 重复: same")) {
            try store.saveTemplate(bad)
        }
    }
}

// MARK: - DeepLink 接线

struct WorkflowDeepLinkTests {

    @Test func resolveWorkflowResolvesByIDAndName() throws {
        let router = DeepLinkRouter()
        let store = WorkflowStore(storeDirectory: try makeTempStoreDir())
        #expect(router.resolveWorkflow(.runWorkflow(name: "manju-full", input: nil), store: store)?.name == "漫剧全流程")
        #expect(router.resolveWorkflow(.runWorkflow(name: "漫剧全流程", input: nil), store: store)?.id == "manju-full")
        #expect(router.resolveWorkflow(.runWorkflow(name: "不存在", input: nil), store: store) == nil)
    }

    @Test func resolveWorkflowIgnoresOtherActions() throws {
        let router = DeepLinkRouter()
        #expect(router.resolveWorkflow(.newSession) == nil)
        #expect(router.resolveWorkflow(.sendPrompt(text: "hi", session: nil)) == nil)
    }

    @Test func parseRunWorkflowThenResolveRoundTrip() throws {
        // miniscanvas://run/manju-storyboard-prompts → 模板
        let url = try #require(URL(string: "miniscanvas://run/manju-storyboard-prompts"))
        let action = try #require(DeepLinkRouter.parse(url: url))
        #expect(action == .runWorkflow(name: "manju-storyboard-prompts", input: nil))
        let template = DeepLinkRouter().resolveWorkflow(action)
        #expect(template?.steps.count == 3)
    }

    @Test func parseRunManjuFullResolvesToFullFlow() throws {
        // D1-fix 接线：miniscanvas://run/manju-full（及旧 minis:// 前缀）
        // → .runWorkflow("manju-full") → 漫剧全流程模板（7 步）。
        for scheme in ["miniscanvas", "minis"] {
            let url = try #require(URL(string: "\(scheme)://run/manju-full"))
            let action = try #require(DeepLinkRouter.parse(url: url))
            #expect(action == .runWorkflow(name: "manju-full", input: nil))
            let store = WorkflowStore(storeDirectory: try makeTempStoreDir())
            let template = DeepLinkRouter().resolveWorkflow(action, store: store)
            #expect(template?.id == "manju-full")
            #expect(template?.name == "漫剧全流程")
            #expect(template?.steps.count == 7)
            #expect(template?.requiredInputs.contains("novel") == true)
        }
    }
}
