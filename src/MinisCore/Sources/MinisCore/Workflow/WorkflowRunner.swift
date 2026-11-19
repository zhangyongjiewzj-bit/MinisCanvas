import Foundation

// MARK: - WorkflowProvider

/// 工作流执行所需的文本生成能力。`WorkflowRunner` 每步调用它一次；
/// 测试用 mock 实现，生产环境用 `LLMWorkflowProvider` 桥接 MinisCore 的 LLMProvider。
public protocol WorkflowProvider: Sendable {
    /// 给定填充完成的提示词与步骤元信息，返回步骤输出文本。
    func generate(prompt: String, step: WorkflowStep) async throws -> String
}

/// 桥接 `LLMProvider` 的默认实现：单轮 user 消息，maxTokens 4096，不传温度（用各模型自己的默认值）。
/// LLMProvider 非 Sendable，沿用代码库惯例用 `@unchecked Sendable` 包装。
public final class LLMWorkflowProvider: WorkflowProvider, @unchecked Sendable {
    public let provider: any LLMProvider
    public let maxTokens: Int
    public let temperature: Double?

    public init(provider: any LLMProvider, maxTokens: Int = 4096, temperature: Double? = nil) {
        self.provider = provider
        self.maxTokens = maxTokens
        self.temperature = temperature
    }

    public func generate(prompt: String, step: WorkflowStep) async throws -> String {
        let response = try await provider.sendMessage(
            messages: [LLMMessage(role: .user, content: prompt)],
            systemPrompt: nil,
            maxTokens: maxTokens,
            temperature: temperature
        )
        return response.text
    }
}

// MARK: - WorkflowCheckpoint / WorkflowRunResult

/// 断点：已成功步骤的输出缓存。
///
/// F15 断点隔离（P1-6）：`completed` 为「模板 id → 该模板的 ScopedCheckpoint」二级结构 ——
/// 共享 outputKey 的不同模板（manju-full 与 manju-novel-breakdown 的 novel/plot/script/storyboard）
/// 断点互不污染；ScopedCheckpoint 记录输入指纹，换输入自动失效；成功完成即清空该模板条目。
public struct WorkflowCheckpoint: Codable, Equatable, Sendable {

    /// 单模板断点：输入指纹 + outputKey → 输出文本。
    /// 指纹变化（换 novel= 等输入）→ 续跑时整段失效，旧输出不会静默覆盖新输入。
    public struct ScopedCheckpoint: Codable, Equatable, Sendable {
        public var fingerprint: String
        public var outputs: [String: String]

        public init(fingerprint: String, outputs: [String: String] = [:]) {
            self.fingerprint = fingerprint
            self.outputs = outputs
        }
    }

    /// 模板 id → 该模板的断点快照。
    public var completed: [String: ScopedCheckpoint]

    public init(completed: [String: ScopedCheckpoint] = [:]) {
        self.completed = completed
    }
}

/// 一次完整（或断点续跑后）执行的结果。
public struct WorkflowRunResult: Sendable, Equatable {
    /// 全部输出（含从断点缓存恢复的），outputKey → 文本。
    public let outputs: [String: String]
    /// 本次实际调用了 LLM 的步骤 id（按执行顺序）。
    public let executedStepIDs: [String]
    /// 从断点缓存恢复、未调 LLM 的步骤 id。
    public let cachedStepIDs: [String]
    /// 执行后的最新断点，可持久化供下次续跑。
    public let checkpoint: WorkflowCheckpoint

    public init(outputs: [String: String], executedStepIDs: [String], cachedStepIDs: [String], checkpoint: WorkflowCheckpoint) {
        self.outputs = outputs
        self.executedStepIDs = executedStepIDs
        self.cachedStepIDs = cachedStepIDs
        self.checkpoint = checkpoint
    }
}

// MARK: - WorkflowError

public enum WorkflowError: Error, Equatable, Sendable {
    /// 模板自检失败。
    case invalidTemplate(id: String, reason: String)
    /// 模板步骤数超过 runner 的 maxSteps 限制。
    case tooManySteps(limit: Int, actual: Int)
    /// 模板缺少必需的顶层输入。
    case missingRequiredInput(templateID: String, key: String)
    /// 某步骤的占位符无法从 inputs / 先前输出中解析。
    case missingInput(stepID: String, key: String)
    /// 某步骤调 LLM 失败（underlying 为错误描述）。
    case stepFailed(stepID: String, index: Int, underlying: String)
}

// MARK: - WorkflowRunner

/// 顺序执行 `WorkflowTemplate` 的可复用运行器。
///
/// - 每步用 `{{key}}` 占位符填充 `promptTemplate`（key 来自用户 inputs 或先前步骤 outputKey）
/// - 输出存入该步 `outputKey`，供后续步骤引用
/// - 断点续跑：已成功步骤缓存于 `checkpoint`，失败后带着同一 runner（或 checkpoint）重跑，
///   成功步骤直接跳过；`maxSteps` 限制单次执行步骤上限
/// - F15 断点隔离：断点按模板 id 分槽存放（`WorkflowCheckpoint.completed[模板id]`）——
///   共享 outputKey 的不同模板（如 manju-full 与 manju-novel-breakdown 的 novel/plot/script/storyboard）
///   互不命中旧缓存；成功完成即丢弃该模板断点（重跑 = 真正重跑）；inputs 变化（指纹不同）
///   自动作废该模板断点（换输入不命中旧缓存）
///
/// 线程安全：内部用 NSLock 保护 checkpoint 状态，可跨任务共享。
public final class WorkflowRunner: @unchecked Sendable {

    public struct Configuration: Sendable {
        /// 单次执行允许的最大步骤数（防模板失控）。
        public var maxSteps: Int

        public init(maxSteps: Int = 50) {
            self.maxSteps = maxSteps
        }
    }

    private let lock = NSLock()
    private var checkpoint: WorkflowCheckpoint
    // A reset/restore or newer run retires the previous checkpoint writer.
    private var checkpointRuns: [String: UUID] = [:]
    public let configuration: Configuration

    public init(checkpoint: WorkflowCheckpoint = WorkflowCheckpoint(), configuration: Configuration = Configuration()) {
        self.checkpoint = checkpoint
        self.configuration = configuration
    }

    /// 恢复断点（续跑前可换成持久化的旧断点）。
    /// checkpoint.completed 以模板 id 为键；ScopedCheckpoint.fingerprint 必须与
    /// 续跑时的 `inputFingerprint(templateID:inputs:)` 一致才会命中。
    public func restore(checkpoint: WorkflowCheckpoint) {
        lock.lock()
        self.checkpoint = checkpoint
        checkpointRuns.removeAll()
        lock.unlock()
    }

    /// 清空断点，重新从第一步开始。
    public func reset() {
        lock.lock()
        self.checkpoint = WorkflowCheckpoint()
        checkpointRuns.removeAll()
        lock.unlock()
    }

    /// F15：模板 + 输入指纹（键有序、值间带控制字符分隔，防拼接歧义；仅作断点失效判定，
    /// 不做安全用途）。同一模板换输入 → 指纹变化 → 旧断点作废。
    static func inputFingerprint(templateID: String, inputs: [String: String]) -> String {
        let canonical = inputs.keys.sorted().map { "\($0)=\u{1}|\(inputs[$0] ?? "")" }.joined(separator: "\u{1F}")
        return "\(templateID)::\(canonical)"
    }

    /// 执行模板。
    ///
    /// - Parameters:
    ///   - template: 要执行的模板
    ///   - inputs: 顶层输入（如 ["novel": "小说原文"]），会与断点缓存一起参与占位符填充
    ///   - provider: 文本生成实现
    /// - Returns: 全部输出 + 本次执行的步骤清单 + 最新断点
    /// - Throws: `WorkflowError`（模板非法 / 超限 / 缺输入 / 步骤失败）
    public func run(
        template: WorkflowTemplate,
        inputs: [String: String],
        provider: any WorkflowProvider
    ) async throws -> WorkflowRunResult {
        try template.validate()

        guard template.steps.count <= configuration.maxSteps else {
            throw WorkflowError.tooManySteps(limit: configuration.maxSteps, actual: template.steps.count)
        }
        for key in template.requiredInputs where inputs[key] == nil {
            throw WorkflowError.missingRequiredInput(templateID: template.id, key: key)
        }

        // F15 断点隔离：按模板 id 取断点；输入指纹变化（换了 novel= 等）→ 丢弃旧断点
        let fingerprint = Self.inputFingerprint(templateID: template.id, inputs: inputs)
        let checkpointRunID = UUID()
        defer { finishCheckpointRun(templateID: template.id, runID: checkpointRunID) }
        var cachedOutputs = scopedOutputs(templateID: template.id, fingerprint: fingerprint, runID: checkpointRunID)

        var outputs: [String: String] = [:]
        var executed: [String] = []
        var cached: [String] = []

        for (index, step) in template.steps.enumerated() {
            // 断点命中：该 outputKey 已成功产出，跳过 LLM
            if let cachedValue = cachedOutputs[step.outputKey] {
                outputs[step.outputKey] = cachedValue
                cached.append(step.id)
                continue
            }

            let prompt: String
            do {
                prompt = try fillPrompt(step: step, inputs: inputs, outputs: outputs)
            } catch {
                // 填充失败也保存断点：已完成步骤不丢，修正输入后可续跑
                setValue(outputs: cachedOutputs, fingerprint: fingerprint, templateID: template.id, runID: checkpointRunID)
                throw error
            }
            let result: String
            do {
                try Task.checkCancellation()
                result = try await provider.generate(prompt: prompt, step: step)
                // A provider may return after the task was cancelled. Do not
                // commit that late result as a successful step.
                try Task.checkCancellation()
            } catch {
                // Cancellation is a terminal request outcome. Normalize every
                // provider cancellation to CancellationError and leave the
                // checkpoint untouched; it must not become stepFailed.
                if let cancellation = ProviderCancellationPolicy.terminalCancellation(for: error) {
                    throw cancellation
                }
                if Task.isCancelled {
                    throw CancellationError()
                }

                // 失败：把已完成步骤写回该模板的断点（带输入指纹），重发同指令续跑
                setValue(outputs: cachedOutputs, fingerprint: fingerprint, templateID: template.id, runID: checkpointRunID)
                throw WorkflowError.stepFailed(
                    stepID: step.id,
                    index: index,
                    underlying: Self.safeUnderlyingDescription(for: error)
                )
            }

            outputs[step.outputKey] = result
            executed.append(step.id)
            cachedOutputs[step.outputKey] = result
        }

        // 成功完成：丢弃该模板断点 —— 重跑 = 真正重跑（不再静默回显旧结果）
        setValue(outputs: [:], fingerprint: fingerprint, templateID: template.id, runID: checkpointRunID)

        return WorkflowRunResult(
            outputs: outputs,
            executedStepIDs: executed,
            cachedStepIDs: cached,
            checkpoint: snapshot()
        )
    }

    // MARK: - 占位符填充

    /// 把 promptTemplate 中的 `{{key}}` 替换为 inputs 或先前步骤输出；找不到则抛错。
    /// 查找优先级：用户 inputs > 步骤输出（含断点缓存）。
    /// 实现：只扫描原始模板（Substring 切片），插入值永不被二次解析，避免索引失效。
    static func fill(
        template: String,
        stepID: String,
        inputs: [String: String],
        outputs: [String: String]
    ) throws -> String {
        var result = ""
        var rest: Substring = template[...]
        while let open = rest.range(of: "{{"),
              let close = rest.range(of: "}}", range: open.upperBound..<rest.endIndex) {
            let key = String(rest[open.upperBound..<close.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                throw WorkflowError.missingInput(stepID: stepID, key: "<empty>")
            }
            let value: String
            if let input = inputs[key] {
                value = input
            } else if let output = outputs[key] {
                value = output
            } else {
                throw WorkflowError.missingInput(stepID: stepID, key: key)
            }
            result += rest[rest.startIndex..<open.lowerBound]
            result += value
            rest = rest[close.upperBound...]
        }
        result += rest
        return result
    }

    private func fillPrompt(step: WorkflowStep, inputs: [String: String], outputs: [String: String]) throws -> String {
        try Self.fill(template: step.promptTemplate, stepID: step.id, inputs: inputs, outputs: outputs)
    }

    /// Approval denials carry delegate supplied text in their raw associated
    /// value so equality and audit identity remain intact.  A workflow failure
    /// is a diagnostic boundary, however, so never stringify that enum case
    /// directly (its synthesized description includes the raw reason).
    /// Other provider errors use the shared payload-free projection policy.
    private static func safeUnderlyingDescription(for error: Error) -> String {
        if let approvalError = error as? ApprovalError {
            return approvalError.localizedDescription
        }
        return ProviderErrorDiagnosticProjectionPolicy.project(error)
    }

    // MARK: - 断点读写

    /// 某模板当前断点中的已完成输出（outputKey → 输出）；无断点返回空字典。
    public func completedOutputs(templateID: String) -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return checkpoint.completed[templateID]?.outputs ?? [:]
    }

    /// 读取某模板断点并校验输入指纹：指纹不符（换输入）视为无断点（同步方法内加锁，
    /// 避免 async 上下文的 NSLock 限制）。
    private func scopedOutputs(templateID: String, fingerprint: String, runID: UUID) -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        checkpointRuns[templateID] = runID
        guard let scoped = checkpoint.completed[templateID], scoped.fingerprint == fingerprint else {
            return [:]
        }
        return scoped.outputs
    }

    /// 写入/清空某模板的断点：outputs 为空 → 移除该模板条目（成功后重跑=真正重跑）。
    private func setValue(outputs: [String: String], fingerprint: String, templateID: String, runID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard checkpointRuns[templateID] == runID else { return }
        if outputs.isEmpty {
            checkpoint.completed[templateID] = nil
        } else {
            checkpoint.completed[templateID] = WorkflowCheckpoint.ScopedCheckpoint(
                fingerprint: fingerprint,
                outputs: outputs
            )
        }
    }

    private func finishCheckpointRun(templateID: String, runID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard checkpointRuns[templateID] == runID else { return }
        checkpointRuns.removeValue(forKey: templateID)
    }

    private func snapshot() -> WorkflowCheckpoint {
        lock.lock()
        defer { lock.unlock() }
        return checkpoint
    }
}
