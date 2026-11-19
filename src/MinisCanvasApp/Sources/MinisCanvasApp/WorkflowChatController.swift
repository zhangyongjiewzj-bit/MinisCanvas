import Foundation
import Observation
import MinisCore

// MARK: - E10 工作流接入聊天
//
// 聊天里输入 `/workflow <模板名>` 或 `运行工作流 <模板名>` 直接执行 D2 的
// WorkflowRunner（用聊天当前选择的 Provider/模型），执行过程在聊天流里显示：
//   · 开始时：「▶️ 开始执行工作流「漫剧全流程」（共 7 步）…」
//   · 每步：「⏳ 工作流执行中（2/7）· 当前步骤：剧情拆解」（原地更新）
//   · 完成：「✅ …执行完成 + 结果摘要」（每步 outputKey 输出预览）
//   · 失败：「❌ …失败于第 N 步 + 断点续跑提示」（runner 保留断点，重发同指令续跑）

/// 解析出的工作流聊天指令。
struct WorkflowChatRequest: Sendable, Equatable {
    let templateName: String
    /// 显式 `key=value` 输入（如 novel=小说内容）
    let inputs: [String: String]
    /// 模板名之后的剩余文本（无 key=value 时作为第一个必填输入的兜底）
    let leftover: String?
}

/// Correlates a workflow's own Provider calls with the approved command and
/// runner generation. Ordinary chat Provider dispatch has no such identity.
struct WorkflowProviderInvocation: Sendable, Equatable {
    let occurrenceID: UUID?
    let runID: UUID
}

enum WorkflowProviderInvocationContext {
    @TaskLocal static var current: WorkflowProviderInvocation?
}

/// A snapshot of one controller-owned workflow Task's actual completion.
/// Retain this before yielding or cancelling; it remains awaitable after the
/// controller retires that run. It cannot cancel a Task or bypass run identity.
struct WorkflowChatRunCompletion: Sendable {
    let runID: UUID
    private let task: Task<Void, Never>

    fileprivate init(runID: UUID, task: Task<Void, Never>) {
        self.runID = runID
        self.task = task
    }

    func wait() async {
        await task.value
    }
}

/// 聊天 → Workflow 桥接控制器。
///
/// - 触发词：消息以 `/workflow ` 或 `运行工作流 ` 开头（BridgeStore.handleChatCommand 优先拦截）
/// - 执行：`WorkflowRunner.run`，Provider 由聊天当前选择冻结后异步准备，
///   经 `LLMWorkflowProvider` 桥接；进度由 `WorkflowProgressProvider` 逐步回调上屏
/// - 断点续跑：runner 实例在控制器内复用（`sharedRunner`），失败后重发同一条指令自动跳过
///   已完成步骤；断点按模板 id 隔离（F15 P1-6，见 WorkflowRunner），成功完成后自动清空
///   该模板断点（重跑 = 真正重跑）；`/workflow 重置` 清空全部断点从头开始
/// - 深链复用：DeepLinkHandler.runWorkflow 使用同一 `sharedRunner`（F15 P2-5），
///   深链触发的断点续跑与聊天的断点互通
@MainActor
@Observable
final class WorkflowChatController {

    /// 是否正在执行（防并发触发）
    private(set) var isRunning = false

    /// 当前聊天工作流的取消句柄。取消仍走 `cancel()`；完成凭据只允许等待。
    private var runningTask: Task<Void, Never>?

    /// 用于屏蔽已取消运行的迟到进度/结果写回。
    private var activeRunID: UUID?

    /// 复用的 runner：断点随实例保留，失败续跑 / 多次执行共享缓存
    private var runner: WorkflowRunner?

    /// 测试注入点：nil 时按聊天当前 Provider/模型冻结并异步准备。
    var providerOverride: (any LLMProvider)?

    /// 工作流模板解析（注入以便测试用临时目录，默认 App 共享实例；与 DeepLinkHandler 一致）。
    var workflowStore: WorkflowStore

    init(workflowStore: WorkflowStore = .shared) {
        self.workflowStore = workflowStore
    }

    /// F15 P2-5：共享 runner 实例（惰性创建并保存）。DeepLinkHandler.runWorkflow
    /// 通过它拿到与聊天同一个 runner —— 深链触发的失败也能留下断点，
    /// 后续从聊天或深链重发同模板指令都能续跑（断点按模板 id 隔离）。
    var sharedRunner: WorkflowRunner {
        let current = runner ?? WorkflowRunner()
        runner = current
        return current
    }

    /// 取消当前聊天工作流。
    ///
    /// 先撤销运行身份再取消底层 Task，确保即使 Provider 忽略取消并稍后返回，
    /// 该次运行也不会再向聊天会话写入进度、成功或失败结果。
    func cancel() {
        guard isRunning else { return }
        activeRunID = nil
        isRunning = false
        runningTask?.cancel()
        runningTask = nil
    }

    /// Capture completion of the current run in the same actor turn as launch.
    /// The returned value owns the original Task handle, so a caller can first
    /// call cancel() and then await its completion before releasing resources.
    /// nil means no current handle is available; it does not join an earlier run.
    func currentRunCompletion() -> WorkflowChatRunCompletion? {
        guard let runID = activeRunID, let task = runningTask else { return nil }
        return WorkflowChatRunCompletion(runID: runID, task: task)
    }

    // MARK: - 触发词识别

    /// 是否命中工作流触发词。
    static func isWorkflowTrigger(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t == "/workflow"
            || t.hasPrefix("/workflow ")
            || t.hasPrefix("运行工作流")
    }

    /// 解析触发消息 → 模板名 + 输入。
    ///
    /// F15 P2-4：`key=value` 的值支持带空格 ——
    /// - 无引号：`key=` 后取到行尾（`novel=长 文本` 完整保留，不再按空白截断）
    /// - 引号包裹（"..." / '...'）：值可跨行、可后接更多 key=value
    /// - 非 `key=` 开头的剩余文本整体作为 leftover（多行全文模式，兜底到第一个缺失的必填输入）
    static func parse(_ text: String) -> WorkflowChatRequest? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var body: String
        if t.hasPrefix("/workflow") {
            body = String(t.dropFirst("/workflow".count))
        } else if t.hasPrefix("运行工作流") {
            body = String(t.dropFirst("运行工作流".count))
        } else {
            return nil
        }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }

        // 模板名：第一个非空白 token（到首个空白/换行为止）
        guard let nameEnd = body.firstIndex(where: { $0.isWhitespace }) else {
            return WorkflowChatRequest(templateName: body, inputs: [:], leftover: nil)
        }
        let name = String(body[..<nameEnd])
        var rest = String(body[nameEnd...])

        var inputs: [String: String] = [:]
        var leftover: String? = nil
        while leftover == nil {
            let trimmed = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { break }
            // 行首是 `key=` → 解析一对输入；否则进入全文模式（剩余整体 leftover）
            guard let (key, afterEquals) = Self.readKeyPrefix(from: trimmed) else {
                leftover = trimmed
                break
            }
            let value: String
            if let quote = afterEquals.first, quote == "\"" || quote == "'" {
                // 引号值：找匹配闭合引号（可跨行）；未闭合则取到末尾
                let content = afterEquals[afterEquals.index(after: afterEquals.startIndex)...]
                if let close = content.firstIndex(of: quote) {
                    value = String(content[..<close])
                    rest = String(content[content.index(after: close)...])
                } else {
                    value = String(content)
                    rest = ""
                }
            } else if let newline = afterEquals.firstIndex(of: "\n") {
                // 无引号：取到行尾
                value = String(afterEquals[..<newline]).trimmingCharacters(in: .whitespaces)
                rest = String(afterEquals[afterEquals.index(after: newline)...])
            } else {
                value = String(afterEquals).trimmingCharacters(in: .whitespaces)
                rest = ""
            }
            guard !value.isEmpty else { continue }
            inputs[key] = value
        }
        let trimmedLeftover = leftover?.trimmingCharacters(in: .whitespacesAndNewlines)
        return WorkflowChatRequest(
            templateName: name,
            inputs: inputs,
            leftover: trimmedLeftover?.isEmpty == false ? trimmedLeftover : nil
        )
    }

    /// 读取文本开头的 `key=` 前缀：key 由字母/数字/`_`/`-` 组成且紧跟 `=`。
    /// 命中返回（小写 key，等号之后的剩余子串）；否则 nil（→ 全文模式）。
    private static func readKeyPrefix(from text: String) -> (key: String, afterEquals: Substring)? {
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            if ch == "=" {
                let key = String(text[..<index]).lowercased()
                guard !key.isEmpty else { return nil }
                return (key, text[text.index(after: index)...])
            }
            guard ch.isLetter || ch.isNumber || ch == "_" || ch == "-" else { return nil }
            index = text.index(after: index)
        }
        return nil
    }

    // MARK: - 执行入口

    /// 执行工作流聊天指令（BridgeStore 在指令拦截处调用）。
    /// 异步执行，进度/结果/错误写入 chat 消息流。
    func run(text: String, chat: ChatStore, occurrenceID: UUID? = nil) {
        guard !isRunning else {
            chat.appendAssistant("⏳ 工作流正在执行中，请稍候再试…")
            return
        }
        guard let request = Self.parse(text) else {
            chat.appendAssistant(usageHint)
            return
        }

        // 重置断点：`/workflow 重置` / `运行工作流 重置`
        if request.templateName.contains("重置") || request.templateName.contains("重新") {
            runner?.reset()
            chat.appendAssistant("🔄 工作流断点已清空，下次执行将从第一步开始。")
            return
        }

        let store = workflowStore
        guard let template = store.template(id: request.templateName) else {
            let available = store.listTemplates().map(\.name).joined(separator: "、")
            chat.appendAssistant("❓ 未找到工作流模板「\(request.templateName)」。可用：\(available)")
            return
        }

        // 输入组装：显式 key=value 优先；剩余文本兜底到第一个缺失的必填输入
        var inputs = request.inputs
        if let leftover = request.leftover, !leftover.isEmpty,
           let firstMissing = template.requiredInputs.first(where: { inputs[$0] == nil }) {
            inputs[firstMissing] = leftover
        }
        let missing = template.requiredInputs.filter { inputs[$0] == nil }
        guard missing.isEmpty else {
            chat.appendAssistant(
                "❌ 工作流「\(template.name)」需要输入：\(missing.joined(separator: "、"))。\n"
                    + "例如：`/workflow \(template.name) \(missing[0])=内容`"
            )
            return
        }

        let selectedOverride = providerOverride
        let providerPreparation: ChatStore.WorkflowProviderPreparation?
        do {
            if selectedOverride == nil {
                providerPreparation = try chat.freezeWorkflowProviderSelection()
            } else {
                providerPreparation = nil
            }
        } catch {
            chat.appendAssistant("❌ 无法创建 LLM Provider：\(UserFacingErrorText.describe(error))")
            return
        }

        let activeRunner = sharedRunner
        isRunning = true
        let runID = UUID()
        activeRunID = runID
        let invocation = WorkflowProviderInvocation(
            occurrenceID: occurrenceID, runID: runID
        )

        let total = template.steps.count
        chat.appendAssistant("▶️ 开始执行工作流「\(template.name)」（共 \(total) 步）…")
        let progressIndex = chat.messages.count - 1
        // F3 会话安全：捕获触发时的 sessionID —— 执行中切会话，进度/结果只写原会话。
        let sessionID = chat.activeSessionID

        runningTask = Task { [weak self] in
            guard let self else { return }
            let provider: any LLMProvider
            do {
                if let override = selectedOverride {
                    provider = override
                } else {
                    provider = try await chat.prepareWorkflowProvider(from: providerPreparation)
                }
            } catch {
                guard self.isCurrentRun(runID) else { return }
                chat.replaceMessageContent(
                    sessionID: sessionID, at: progressIndex,
                    with: "❌ 无法创建 LLM Provider：\(UserFacingErrorText.describe(error))"
                )
                self.finishRun(runID)
                return
            }
            guard self.isCurrentRun(runID), !Task.isCancelled else { return }
            let progressProvider = WorkflowProgressProvider(
                inner: LLMWorkflowProvider(provider: provider),
                total: total
            ) { [weak self] stepIndex, step in
                self?.updateProgress(
                    runID: runID, chat: chat, sessionID: sessionID, index: progressIndex,
                    stepIndex: stepIndex, total: total, step: step
                )
            }
            do {
                let result = try await WorkflowProviderInvocationContext.$current.withValue(
                    invocation
                ) {
                    try await activeRunner.run(
                        template: template,
                        inputs: inputs,
                        provider: progressProvider
                    )
                }
                guard self.isCurrentRun(runID) else { return }
                self.finishSuccess(
                    runID: runID, chat: chat, sessionID: sessionID, index: progressIndex,
                    template: template, result: result
                )
            } catch {
                guard self.isCurrentRun(runID) else { return }
                self.finishFailure(
                    runID: runID, chat: chat, sessionID: sessionID, index: progressIndex,
                    template: template, runner: activeRunner, error: error
                )
            }
            self.finishRun(runID)
        }
    }

    // MARK: - 进度 / 结果上屏

    /// F3：进度写回按 sessionID 定位（会话已删除/切走都不串会话）。
    private func updateProgress(
        runID: UUID, chat: ChatStore, sessionID: UUID?, index: Int,
        stepIndex: Int, total: Int, step: WorkflowStep
    ) {
        guard isCurrentRun(runID) else { return }
        chat.replaceMessageContent(
            sessionID: sessionID, at: index,
            with: "⏳ 工作流执行中（\(stepIndex)/\(total)）· 当前步骤：**\(step.title)**"
        )
    }

    private func finishSuccess(
        runID: UUID, chat: ChatStore, sessionID: UUID?, index: Int,
        template: WorkflowTemplate, result: WorkflowRunResult
    ) {
        guard isCurrentRun(runID) else { return }
        let resumeNote = result.cachedStepIDs.isEmpty ? "" : "，断点续跑 \(result.cachedStepIDs.count) 步"
        chat.replaceMessageContent(
            sessionID: sessionID, at: index,
            with: "✅ 工作流「\(template.name)」执行完成：本次执行 \(result.executedStepIDs.count) 步\(resumeNote)"
        )
        var lines: [String] = []
        for step in template.steps {
            guard let output = result.outputs[step.outputKey] else { continue }
            let preview = output.count > 120 ? String(output.prefix(120)) + "…" : output
            lines.append("· **\(step.title)**（`\(step.outputKey)`）：\(preview)")
        }
        // F3：摘要追加进原会话（不再写活跃会话）
        chat.appendAssistant("**结果摘要**：\n" + lines.joined(separator: "\n"), toSession: sessionID)
    }

    private func finishFailure(
        runID: UUID, chat: ChatStore, sessionID: UUID?, index: Int,
        template: WorkflowTemplate, runner: WorkflowRunner, error: Error
    ) {
        guard isCurrentRun(runID) else { return }
        let total = template.steps.count
        let completedOutputs = runner.completedOutputs(templateID: template.id)
        let completed = template.steps.filter { completedOutputs[$0.outputKey] != nil }.count

        let detail: String
        if case WorkflowError.stepFailed(let stepID, let stepIndex, let underlying) = error {
            let title = template.steps.indices.contains(stepIndex) ? template.steps[stepIndex].title : stepID
            detail = "第 \(stepIndex + 1)/\(total) 步「\(title)」失败（\(underlying)）"
        } else {
            detail = UserFacingErrorText.describe(error)
        }

        let text = """
        ❌ 工作流「\(template.name)」执行失败：\(detail)。

        已完成 \(completed)/\(total) 步，断点已保存 —— 重新发送同一条指令将从断点继续，已完成步骤不重复调用 LLM。
        """
        // F3：写回原会话；原会话已删除则丢弃（不再追加到活跃会话）
        if chat.replaceMessageContent(sessionID: sessionID, at: index, with: text) {
            chat.touchSession(sessionID)
        }
    }

    private func isCurrentRun(_ runID: UUID) -> Bool {
        isRunning && activeRunID == runID
    }

    private func finishRun(_ runID: UUID) {
        guard activeRunID == runID else { return }
        isRunning = false
        activeRunID = nil
        runningTask = nil
    }

    // MARK: - 提示

    private var usageHint: String {
        let available = workflowStore.listTemplates().map(\.name).joined(separator: "、")
        return """
        ❓ 工作流指令格式：`/workflow <模板名> [输入1=值] [输入2=值]` 或 `运行工作流 <模板名> [输入1=值]`。
        可用模板：\(available)。`/workflow 重置` 可清空断点重新开始。
        """
    }
}

// MARK: - 进度观察 Provider

/// 包装 `WorkflowProvider`，每次 generate 前回调（stepIndex 从 1 起）。
/// 断点续跑命中的步骤不会调 generate，因此不触发回调（进度只反映实际执行）。
/// 回调为 @MainActor：聊天消息更新必须回主线程。
final class WorkflowProgressProvider: WorkflowProvider, @unchecked Sendable {
    private let inner: any WorkflowProvider
    private let onStep: @MainActor @Sendable (Int, WorkflowStep) -> Void
    private let lock = NSLock()
    private var nextIndex = 1

    init(
        inner: any WorkflowProvider,
        total: Int,
        onStep: @escaping @MainActor @Sendable (Int, WorkflowStep) -> Void
    ) {
        self.inner = inner
        self.onStep = onStep
    }

    func generate(prompt: String, step: WorkflowStep) async throws -> String {
        try Task.checkCancellation()
        let index = nextStepIndex()
        await onStep(index, step)
        let output = try await inner.generate(prompt: prompt, step: step)
        try Task.checkCancellation()
        return output
    }

    /// 取下一个步骤序号（同步方法内加锁，避免 async 上下文的 NSLock 限制）。
    private func nextStepIndex() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let index = nextIndex
        nextIndex += 1
        return index
    }
}
