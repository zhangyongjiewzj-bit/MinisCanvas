import Foundation
import MinisCore
import CanvasCore

// MARK: - F16b-2 文档 AI 流水线：执行引擎
//
// 产品铁律（用户原话）：
//   1. 逐阶段手动触发 —— runStage 只跑单个阶段，跑完停在 .awaitingReview
//      等人工审核，绝不自动连跑下一阶段。
//   2. 人工审核通过走 confirmStage → .done；输出可人工编辑后 rerunStage 重跑。
//   3. runAllRemaining 只是次要辅助入口（非主路径）：内部仍是逐阶段串行、
//      每阶段 .awaitingReview 即停 —— 每次调用至多跑一个阶段，不自动连跑。
//   4. 回跳编辑前序阶段则下游标 stale（markDownstreamStale，见 rerunStage 联动）。
//
// LLM 注入：调用方传入 StageLLMCall 闭包。生产用 makeLLM(provider:) 组装
// （包 MinisCore LLMProvider.sendMessage 单次调用）；阶段级 providerID/modelID
// 由 UI 层（F16b-3）解析成 provider 后注入。测试直接注入 mock 闭包。

/// 阶段 LLM 调用闭包：入参 = 组装好的 prompt，返回模型输出文本。
typealias StageLLMCall = @Sendable (_ prompt: String) async throws -> String

/// 阶段执行错误：message 恒为中文友好文案（不向用户糊英文堆栈）。
struct DocumentStageError: Error, LocalizedError, Equatable, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// 文档流水线执行引擎（无状态命名空间，全部静态方法）。
enum DocumentStageRunner {

    // MARK: 主路径：单阶段手动触发

    /// 执行单个阶段（主路径）。成功后写回 output 并停在 .awaitingReview（不是 .done，
    /// 等人工审核确认）。
    ///
    /// input 解析：index == 0 → 文档正文 `documentContent`；否则 → 上一阶段 output
    ///（为空则拒绝执行，中文报错）。
    /// prompt 组装：模板含 {{input}} → 替换为 input；否则 → input 拼接在模板后。
    /// LLM 抛错：status 回落 .pending（可重跑），output 不动，抛中文 DocumentStageError。
    static func runStage(
        pipeline: inout DocumentPipeline,
        index: Int,
        documentContent: String,
        llm: StageLLMCall
    ) async throws {
        try await execute(
            pipeline: &pipeline, index: index,
            documentContent: documentContent, llm: llm,
            markDownstreamStaleOnSuccess: false
        )
    }

    /// Scoped variant. The result is committed only while the caller confirms
    /// that the original canvas/run/graph/node identity is still current.
    static func runStage(
        pipeline: inout DocumentPipeline,
        index: Int,
        documentContent: String,
        context: DocumentStageExecutionContext,
        isCurrent: @escaping @Sendable () async -> Bool,
        llm: StageLLMCall
    ) async throws {
        try await execute(
            pipeline: &pipeline,
            index: index,
            documentContent: documentContent,
            llm: llm,
            markDownstreamStaleOnSuccess: false,
            context: context,
            isCurrent: isCurrent
        )
    }

    /// Pure-LLM session-document entry. No Canvas identity or tool authority is
    /// constructed. The canonical Store performs the final attempt/revision CAS.
    static func runSessionStage(pipeline: DocumentPipeline, index: Int,
                                documentContent: String, llm: StageLLMCall) async throws -> String {
        var working = pipeline
        try Task.checkCancellation()
        try await runStage(pipeline: &working, index: index, documentContent: documentContent, llm: llm)
        try Task.checkCancellation()
        return working.stages[index].output
    }

    // MARK: 人工审核

    /// 人工审核通过：.awaitingReview → .done。
    /// 越界或状态非 .awaitingReview 为无操作（不确认未执行/未审核的阶段）。
    static func confirmStage(pipeline: inout DocumentPipeline, index: Int) {
        guard pipeline.stages.indices.contains(index),
              pipeline.stages[index].status == .awaitingReview else { return }
        pipeline.stages[index].status = .done
    }

    // MARK: 编辑后重跑

    /// output 被人工编辑后重跑：重新执行 index 阶段（input 解析同 runStage，
    /// 自动取到上游被编辑后的 output），成功后 status 回 .awaitingReview（不是 .done，
    /// 需再次人工审核）。联动：重跑成功即该阶段 output 已变 →
    /// markDownstreamStale(fromIndex: index)，下游全部标 stale 待重跑。
    static func rerunStage(
        pipeline: inout DocumentPipeline,
        index: Int,
        documentContent: String,
        llm: StageLLMCall
    ) async throws {
        try await execute(
            pipeline: &pipeline, index: index,
            documentContent: documentContent, llm: llm,
            markDownstreamStaleOnSuccess: true
        )
    }

    static func rerunStage(
        pipeline: inout DocumentPipeline,
        index: Int,
        documentContent: String,
        context: DocumentStageExecutionContext,
        isCurrent: @escaping @Sendable () async -> Bool,
        llm: StageLLMCall
    ) async throws {
        try await execute(
            pipeline: &pipeline,
            index: index,
            documentContent: documentContent,
            llm: llm,
            markDownstreamStaleOnSuccess: true,
            context: context,
            isCurrent: isCurrent
        )
    }

    // MARK: 次要辅助入口（非主路径）

    /// 次要辅助入口，非主路径：省去手动选阶段，但绝不自动连跑。
    ///
    /// 语义：从当前到末尾按序逐阶段串行扫描，只执行第一个可跑（.pending / .stale）
    /// 的阶段，且每阶段 .awaitingReview 即停 —— 「运行到末尾」实际是每次调用/每次
    /// 人工审核只推进一个阶段，需调用方反复调用（每次停下都是人工审核点）。
    /// 返回实际执行的阶段索引；nil = 无可执行阶段。LLM 错误处理同 runStage。
    @discardableResult
    static func runAllRemaining(
        pipeline: inout DocumentPipeline,
        documentContent: String,
        llm: StageLLMCall
    ) async throws -> Int? {
        // 按序串行扫描：找到第一个可执行阶段即跑、跑完即停
        guard let index = pipeline.stages.firstIndex(where: {
            $0.status == .pending || $0.status == .stale
        }) else { return nil }
        try await runStage(
            pipeline: &pipeline, index: index,
            documentContent: documentContent, llm: llm
        )
        return index
    }

    // MARK: prompt 组装

    /// 模板组装：含 {{input}} → 替换全部占位符为 input；
    /// 不含 → input 拼接在模板后；空模板 → 仅 input。
    static func composePrompt(template: String, input: String) -> String {
        if template.contains(ManjuDocumentTemplate.inputPlaceholder) {
            return template.replacingOccurrences(
                of: ManjuDocumentTemplate.inputPlaceholder, with: input)
        }
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? input : trimmed + "\n\n" + input
    }

    // MARK: 内部共用执行核心

    private static func execute(
        pipeline: inout DocumentPipeline,
        index: Int,
        documentContent: String,
        llm: StageLLMCall,
        markDownstreamStaleOnSuccess: Bool,
        context: DocumentStageExecutionContext? = nil,
        isCurrent: (@Sendable () async -> Bool)? = nil
    ) async throws {
        guard pipeline.stages.indices.contains(index) else {
            throw DocumentStageError(message: "要执行的阶段不存在，请检查流水线配置。")
        }
        let stageName = pipeline.stages[index].name
        if let context {
            guard context.identity.isValid,
                  context.providerSnapshot.isValid,
                  context.identity.nodeID == pipeline.stages[index].id else {
                throw DocumentStageError(message: "阶段身份不匹配，已拒绝执行。")
            }
            let configuredProvider = pipeline.stages[index].providerID
            guard configuredProvider.isEmpty || configuredProvider == context.providerSnapshot.providerID else {
                throw DocumentStageError(message: "阶段 Provider 已变化，已拒绝使用旧任务结果。")
            }
            guard isCurrent != nil else {
                throw DocumentStageError(message: "阶段缺少迟到写回校验，已拒绝执行。")
            }
        }
        // input 解析：首阶段 = 文档正文；否则 = 上一阶段 output
        let input: String
        if index == 0 {
            input = documentContent
        } else {
            let prev = pipeline.stages[index - 1]
            guard !prev.output.isEmpty else {
                throw DocumentStageError(
                    message: "上一阶段「\(prev.name)」还没有输出，请先完成上一阶段再运行「\(stageName)」。")
            }
            input = prev.output
        }
        let prompt = composePrompt(
            template: pipeline.stages[index].promptTemplate, input: input)
        pipeline.stages[index].input = input
        pipeline.stages[index].status = .running
        do {
            let output = try await llm(prompt)
            if context != nil {
                let current = await isCurrent!()
                guard !Task.isCancelled, current else {
                    pipeline.stages[index].status = .stale
                    throw DocumentStageError(
                        message: "阶段「\(stageName)」结果已过期，未写回当前文档。"
                    )
                }
            }
            pipeline.stages[index].output = output
            pipeline.stages[index].status = .awaitingReview
            if markDownstreamStaleOnSuccess {
                pipeline.markDownstreamStale(fromIndex: index)
            }
        } catch {
            // 失败：回落 .pending（可重跑），不覆盖已有 output（保留人工编辑）
            if let stageError = error as? DocumentStageError,
               stageError.message.contains("结果已过期") {
                pipeline.stages[index].status = .stale
            } else {
                pipeline.stages[index].status = .pending
            }
            throw DocumentStageError(
                message: friendlyMessage(for: error, stageName: stageName))
        }
    }

    // MARK: 中文友好错误文案

    /// 把任意错误转成中文友好文案（不向用户糊英文堆栈/原始错误类型名）。
    /// Closed, payload-free projection shared by runtime execution and provider preparation.
    static func userFailureMessage(_ error: Error) -> String {
        if let stage = error as? DocumentStageError { return stage.message }
        if error is CancellationError { return "阶段已停止或输入已变化（DOC:cancelled）。" }
        if let model = error as? ChildModelBindingError {
            switch model {
            case .notReady: return "模型未就绪（DOC:model-not-ready），请重新检查并应用模型。"
            case .unauthorized: return "模型选择未获允许（DOC:model-unauthorized）。"
            default: return "模型配置或上下文已变化（DOC:model-context），请重新选择模型。"
            }
        }
        if let llm = error as? LLMError { return llm.userMessageZH + "（" + llm.technicalDetail + "）" }
        if let network = error as? URLError {
            return userFailureMessage(LLMError.networkError(underlying: network))
        }
        return "模型调用出错（DOC:unknown），请检查模型状态后重试。"
    }

    private static func friendlyMessage(for error: Error, stageName: String) -> String {
        if error is CancellationError {
            return "阶段「\(stageName)」已取消执行。"
        }
        if let stageError = error as? DocumentStageError {
            return stageError.message
        }
        return "阶段「\(stageName)」执行失败：" + userFailureMessage(error)
    }

    // MARK: 生产装配

    /// 把 MinisCore LLMProvider 包成 StageLLMCall（单次非流式调用）。
    /// LLMProvider 协议非 Sendable（具体实现均 @unchecked Sendable），
    /// 复用 ChatAgentEngine 的 LLMProviderBox 跨 Task 安全传递。
    /// 阶段级 provider/model 选择（providerID/modelID）由 UI 层解析后传入。
    static func makeLLM(provider: any LLMProvider, maxTokens: Int = 4096) -> StageLLMCall {
        let box = LLMProviderBox(value: provider)
        return { prompt in
            let response = try await box.value.sendMessage(
                messages: [LLMMessage(role: .user, content: prompt)],
                systemPrompt: nil,
                maxTokens: maxTokens,
                temperature: nil
            )
            return response.text
        }
    }
}
