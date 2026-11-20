import Foundation

// MARK: - Result & Errors

public struct AgentLoopResult: Sendable {
    /// Full message history after the loop finishes (user/assistant/tool_result).
    public let messages: [LLMMessage]
    /// Number of LLM round-trips performed.
    public let iterationCount: Int
    /// Total number of tool calls executed across all iterations.
    public let toolCallsExecuted: Int
    /// Stable identity for consumers that write the result back asynchronously.
    public let executionIdentity: AgentExecutionIdentity?
    /// Canonical terminal facts from the durable tool-fact authority.
    public let toolExecutionFacts: [ToolExecutionFact]
    public var facts: [ToolExecutionFact] { toolExecutionFacts }

    public init(
        messages: [LLMMessage],
        iterationCount: Int,
        toolCallsExecuted: Int,
        executionIdentity: AgentExecutionIdentity? = nil,
        toolExecutionFacts: [ToolExecutionFact] = []
    ) {
        self.messages = messages
        self.iterationCount = iterationCount
        self.toolCallsExecuted = toolCallsExecuted
        self.executionIdentity = executionIdentity
        self.toolExecutionFacts = toolExecutionFacts
    }
}

public struct AgentLoopStructuredFailure: LocalizedError, Equatable, Sendable {
    public let agentError: AgentLoopError?
    public let message: String
    public let toolExecutionFacts: [ToolExecutionFact]

    public init(
        agentError: AgentLoopError?,
        message: String,
        toolExecutionFacts: [ToolExecutionFact]
    ) {
        self.agentError = agentError
        self.message = message
        self.toolExecutionFacts = toolExecutionFacts
    }

    public var errorDescription: String? { message }
}

public struct AgentLoopExecutionOutcome: Sendable {
    public let result: AgentLoopResult?
    public let failure: AgentLoopStructuredFailure?
    public let toolExecutionFacts: [ToolExecutionFact]

    public var succeeded: Bool { result != nil && failure == nil }

    public init(
        result: AgentLoopResult?,
        failure: AgentLoopStructuredFailure?,
        toolExecutionFacts: [ToolExecutionFact]
    ) {
        self.result = result
        self.failure = failure
        self.toolExecutionFacts = toolExecutionFacts
    }
}

public enum AgentLoopError: LocalizedError, Equatable, Sendable {
    /// Constructed only from the completed provider's same-request catalog.
    public struct TruncatedToolCallDiagnostic: Equatable, Sendable {
        fileprivate let count: Int
        fileprivate let offeredNames: [String]
        fileprivate let additionalOfferedNameCount: Int
        fileprivate let unknownToolCallCount: Int

        fileprivate init(count: Int, notice: DiscardedToolCallNotice) {
            self.count = count
            self.offeredNames = notice.offeredNames
            self.additionalOfferedNameCount = notice.additionalOfferedNameCount
            self.unknownToolCallCount = notice.unknownToolCallCount
        }
    }

    case maxIterationsExceeded(Int)
    /// Provider returned an empty response with no tool calls.
    case emptyResponse
    /// The Provider explicitly stopped at its single-response output limit
    /// (plain text, no discarded tool calls). Partial text is preserved.
    case outputTruncated
    case truncatedToolCalls(Int)
    case truncatedToolCallsWithDiagnostic(TruncatedToolCallDiagnostic)
    /// F19 (P1-4): the session request/token budget is exhausted and the
    /// over-budget policy is `.pause` — the loop refuses to run (or halts
    /// mid-turn) instead of burning more tokens.
    case budgetExhausted
    /// A caller-supplied output ceiling has no capacity for a Provider call.
    case outputTokenCeilingExhausted
    /// The provider or turn exceeded the configured execution timeout.
    case timedOut(TimeInterval)
    /// The offered tool definitions are malformed or inconsistent.
    case invalidToolCatalog(String)
    /// The Composer execution wrapper was built from a different turn
    /// snapshot than the one used to derive this loop's execution profile.
    case composerSnapshotMismatch
    /// A Composer turn without its Core authorization wrapper may not call a
    /// Provider or run tools, even if another PolicyRuntime wrapper exists.
    case composerAuthorizationUnavailable
    /// No durable fact authority was supplied for a real tool execution.
    case toolExecutionFactsUnavailable
    /// Automatic compaction was configured for a durable session but could
    /// not bind a canonical conversation identity/checkpoint.
    case compactionCheckpointUnavailable(String)
    /// Direct/legacy execution did not provide a positive canonical attempt.
    case invalidToolExecutionAttempt
    /// The supplied writeback identity does not belong to the current
    /// conversation/turn or child boundary.
    case executionIdentityMismatch
    /// A terminal fact could not be durably persisted; no fake terminal fact
    /// is returned for the affected receipt.
    case toolExecutionFactSettlementFailed(String)
    /// A parent with dispatched children cannot claim a terminal join when
    /// its per-child fact failed to reach the durable task ledger.
    case parentTerminalPersistenceFailed
    /// Window admission: occupancy is at or above 95% of the window and
    /// neither reduction nor compaction can lower it. No Provider request was made.
    case contextWindowFull(fraction: Double)
    /// 同一个工具在本回合连续失败达到上限，回合已停下（失败结果已写回对话）。
    case repeatedToolFailure(tool: String, count: Int)

    private static func truncationDescription(count: Int, isChinese: Bool) -> String {
        isChinese
            ? "模型输出截断，丢弃 \(count) 个工具调用。请分段继续。"
            : "The model output was truncated. Discarded \(count) tool calls. Please continue in smaller steps."
    }

    /// 用户可读错误描述（随系统语言中/英），供 UI 直接显示。
    public var errorDescription: String? {
        let isChinese = Locale.current.language.languageCode?.identifier.lowercased().hasPrefix("zh") ?? false
        switch self {
        case .repeatedToolFailure(let tool, let count):
            return isChinese
                ? "工具 \(tool) 已连续失败 \(count) 次，本回合先停下。请展开失败的工具卡片查看原因，处理后点「继续」"
                : "Tool \(tool) failed \(count) times in a row, so this turn stopped. Expand the failed tool card for the reason, then continue."
        case .maxIterationsExceeded(let n):
            return isChinese
                ? "本回合的工具调用已达上限（\(n) 次），已先停下。点「继续」可接着做，也可以把任务拆小后再试"
                : "Max iterations exceeded (\(n)) — please simplify the task or split it into steps"
        case .emptyResponse:
            return isChinese
                ? "模型未返回任何内容，请重试"
                : "The model returned an empty response — please try again"
        case .outputTruncated:
            return isChinese
                ? "回复因达到单次输出上限而被截断；已保留部分文本。可输入‘继续’，或要求分段回答。"
                : "The reply was truncated at the output limit. Partial text was preserved; ask to continue or request smaller parts."
        case .truncatedToolCalls(let count):
            return Self.truncationDescription(count: count, isChinese: isChinese)
        case .truncatedToolCallsWithDiagnostic(let diagnostic):
            var description = Self.truncationDescription(count: diagnostic.count, isChinese: isChinese)
            if !diagnostic.offeredNames.isEmpty {
                let names = diagnostic.offeredNames.map { String(reflecting: $0) }
                    .joined(separator: isChinese ? "、" : ", ")
                description += isChinese ? " 已公布工具：\(names)。" : " Offered tools: \(names)."
            }
            if diagnostic.additionalOfferedNameCount > 0 {
                let count = diagnostic.additionalOfferedNameCount
                description += isChinese ? " 另有 \(count) 个。" : " \(count) more offered tool names."
            }
            if diagnostic.unknownToolCallCount > 0 {
                let count = diagnostic.unknownToolCallCount
                description += isChinese ? " 未知工具 \(count) 个。" : " Unknown tool calls: \(count)."
            }
            return description
        case .budgetExhausted:
            return isChinese
                ? "已达到本会话用量预算上限，已停止发起新的模型调用；请重置或提高预算后重试"
                : "Session usage budget exhausted — further model calls are blocked until the budget is reset or raised"
        case .outputTokenCeilingExhausted:
            return isChinese
                ? "当前上下文没有剩余输出额度，请增大上下文长度或缩短输入后重试"
                : "No output tokens remain in this context — increase the context length or shorten the input"
        case .timedOut(let seconds):
            return isChinese
                ? "智能体执行超过时限（\(seconds) 秒）"
                : "Agent execution timed out after \(seconds) seconds"
        case .invalidToolCatalog(let detail):
            return "Invalid tool catalog: \(detail)"
        case .composerSnapshotMismatch:
            return isChinese
                ? "Composer 执行器与当前回合策略快照不一致，已拒绝执行"
                : "Composer executor does not match the current turn snapshot"
        case .composerAuthorizationUnavailable:
            return isChinese
                ? "Composer 回合缺少授权执行器，已在模型调用前拒绝"
                : "Composer authorization executor is unavailable before model execution"
        case .toolExecutionFactsUnavailable:
            return isChinese
                ? "工具事实持久化权威不可用，已拒绝执行"
                : "Durable tool-execution fact authority is unavailable"
        case .compactionCheckpointUnavailable(let detail):
            return isChinese
                ? "上下文压缩缺少可恢复的持久化身份（\(detail)），已拒绝继续"
                : "Compaction checkpoint is not recoverable (\(detail)); execution was refused"
        case .invalidToolExecutionAttempt:
            return isChinese
                ? "工具执行缺少有效的正 attempt identity，已拒绝执行"
                : "Tool execution requires a positive canonical attempt identity"
        case .executionIdentityMismatch:
            return isChinese
                ? "执行身份与当前会话或回合不一致，已拒绝执行"
                : "Execution identity does not match the current session or turn"
        case .toolExecutionFactSettlementFailed(let detail):
            return "Tool execution fact settlement failed: \(detail)"
        case .parentTerminalPersistenceFailed:
            return isChinese
                ? "父任务的子任务结局未能持久保存，请人工核对"
                : "Parent child outcomes could not be persisted; review is required"
        case .contextWindowFull(let fraction):
            let percent = Int((fraction * 100).rounded())
            return isChinese
                ? "上下文已占模型窗口的 \(percent)%，本回合内无法压缩或缩减；可点“压缩后重试”，或新开会话继续，原会话保留"
                : "The context fills \(percent)% of the model window and cannot be compacted or reduced within this turn; use Compact and retry, or continue in a new session (this one is kept)"
        }
    }
}

extension AgentLoopError {
    /// 窗口已满（`contextWindowFull`）在没有“压缩后重试”按钮的路径上的失败说明：
    /// 子智能体（`subagent == true`）由主智能体重派；后台、项目这类无人值守回合由用户重新运行。
    /// 前台对话仍用 `errorDescription` 里的“压缩后重试 / 新开会话继续”。
    public static func contextWindowFullDelegatedDescription(subagent: Bool, isChinese: Bool? = nil) -> String {
        let chinese = isChinese
            ?? (Locale.current.language.languageCode?.identifier.lowercased().hasPrefix("zh") ?? false)
        if subagent {
            return chinese
                ? "子任务的上下文已满，无法继续；请缩小任务范围后重派"
                : "The sub-task's context is full and cannot continue; narrow its scope and delegate it again"
        }
        return chinese
            ? "这个后台任务的上下文已满，无法继续；请缩小任务范围，或新开会话后重新运行"
            : "This background task's context is full and cannot continue; narrow its scope or start a new session and run it again"
    }

    /// 是否是前台的“窗口已满”说明文字（被包装成只带文案的失败信封后，只能按文字识别）。
    public static func isContextWindowFullForegroundDescription(_ text: String) -> Bool {
        text.contains("压缩后重试") && text.contains("新开会话继续")
            || text.contains("Compact and retry") && text.contains("continue in a new session")
    }
}

/// The same local text estimate used at the App context handoff and
/// before each Provider request. Actual tokenization remains Provider-owned.
public enum AgentContextTokenBudget {
    /// `toolSchemaTokens` is the estimated size of the offered tool definitions
    /// (see `estimatedToolSchemaTokens`); they are part of every request.
    public static func estimatedInputCost(
        _ messages: [LLMMessage],
        systemPrompt: String,
        toolSchemaTokens: Int = 0
    ) -> Int? {
        guard let messagesCost = estimatedMessagesCost(messages) else { return nil }
        let (partial, overflow) = max(1, estimatedTextTokens(systemPrompt)).addingReportingOverflow(messagesCost)
        let (total, overflow2) = partial.addingReportingOverflow(max(0, toolSchemaTokens))
        return overflow || overflow2 ? nil : total
    }

    /// Local token estimate of a text: CJK characters (Han, kana, Hangul and
    /// their punctuation) count about one token each, everything else about
    /// four characters per token. Actual tokenization remains Provider-owned.
    public static func estimatedTextTokens(_ text: String) -> Int {
        var cjk = 0
        var other = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3000...0x303F, 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
                 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x2FA1F:
                cjk += 1
            default:
                other += 1
            }
        }
        return cjk + other / 4
    }

    /// Estimated tokens of the tool definitions sent with every request.
    public static func estimatedToolSchemaTokens(_ tools: [AgentToolDefinition]) -> Int {
        tools.reduce(0) { total, tool in
            var tokens = 12 + estimatedTextTokens(tool.name) + estimatedTextTokens(tool.description)
            for (key, param) in tool.parameters {
                tokens += 8 + estimatedTextTokens(key) + estimatedTextTokens(param.description)
                    + (param.enumValues ?? []).reduce(0) { $0 + 2 + estimatedTextTokens($1) }
            }
            return total + tokens
        }
    }

    /// 每张图片的本地估值（约 1500 个 token）。
    public static let estimatedImageTokens = 1_500

    /// Local estimate (CJK-aware, at least 1 per message) of the messages
    /// alone, without a system prompt. Nil on integer overflow.
    public static func estimatedMessagesCost(_ messages: [LLMMessage]) -> Int? {
        var total = 0
        for message in messages {
            var cost = estimatedTextTokens(message.content)
            // 图片按固定估值、音频按数据量折算计入（本地估算只用于显示和压缩触发）。
            cost += message.images.count * estimatedImageTokens
            for audio in message.audios {
                cost += max(50, audio.base64Data.utf8.count * 3 / 4 / 640)
            }
            for call in message.toolCalls {
                let (next, overflow) = cost.addingReportingOverflow(estimatedTextTokens(call.rawArguments))
                guard !overflow else { return nil }
                cost = next
            }
            cost = max(1, cost)
            let (next, sumOverflow) = total.addingReportingOverflow(cost)
            guard !sumOverflow else { return nil }
            total = next
        }
        return total
    }
}

// MARK: - Agent Loop

/// The agent conversation loop (B1b).
///
/// Flow per iteration:
/// 1. Send the accumulated `[LLMMessage]` history to the `LLMProvider`.
/// 2. The response text is appended as an assistant message. If it encodes
///    one or more tool calls (canonical JSON envelope, see
///    `parseToolCalls(from:)`), each is executed via `ToolExecutor`.
/// 3. Every result is fed back as an Anthropic-style `tool_result` user
///    message, then the loop continues.
/// 4. A response without tool calls ends the turn.
///
/// The loop stops after `maxIterations` (default 50) and throws
/// `AgentLoopError.maxIterationsExceeded`.
public struct AgentLoop: Sendable {

    /// Maximum LLM round-trips before giving up. `unlimitedIterations`
    /// means no per-turn cap (settings「不限制循环次数」).
    public var maxIterations: Int

    /// Sentinel for "no per-turn round-trip cap". Token budgets, the loop
    /// detector and cancellation still stop a run.
    public static let unlimitedIterations = Int.max

    /// 有限值仍按旧规则限制在 1…100；“不限”原样保留。
    public static func normalizedIterations(_ value: Int) -> Int {
        value >= unlimitedIterations ? unlimitedIterations : min(100, max(1, value))
    }

    /// Optional approval gate (E1 工具审批流). A nil gate is not approval:
    /// unclassified, high-risk, and input-escalated calls fail closed. When
    /// set, each tool call is gated first; refused calls become `is_error`
    /// tool results and the tool is never handed to the executor.
    public var approvalGate: ApprovalGate?

    /// Optional turn controller enabling interrupt support (E2). When set, the
    /// loop checks `isCancelled()` between iterations and throws
    /// `InterruptedError` if the user interrupted the turn.
    public var turnController: TurnController?

    /// Optional tool-loop detector (N1). Every parsed tool call is recorded
    /// before execution; once the same signature (tool + stable input) repeats
    /// `loopThreshold` times consecutively, the call is blocked — never handed
    /// to the executor — and a `[LOOP BLOCKED]` warning is injected as an
    /// `is_error` tool_result so the model changes tack instead of burning
    /// tokens on a dead loop. Coexists with `approvalGate` and
    /// `turnController`: the gate still runs for unblocked calls, and the
    /// blocked result is fed back like any other tool result.
    ///
    /// F19 (P1-1) production wiring: the default is now a fresh
    /// `ToolLoopDetector()`, so every loop — including the production chat
    /// engine, which constructs `AgentLoop` without naming this parameter —
    /// is protected against dead tool loops. Pass `loopDetector: nil`
    /// explicitly to opt out.
    public var loopDetector: ToolLoopDetector?

    /// Optional shared request/token budget (F19 P1-4 enforcement).
    ///
    /// When set, every provider round-trip is recorded into the tracker and
    /// the returned over-budget policy is *enforced*, not merely displayed:
    /// - `.pause` → the loop halts with `AgentLoopError.budgetExhausted`
    ///   (mid-turn), and a turn started while the budget is exhausted is
    ///   refused before its first provider call.
    /// - `.autoCompact` → only a verifiably lossless text history is compacted
    ///   before the loop continues; otherwise the turn stops.
    /// - `.warn` → continue (callers surface the warning via the tracker).
    /// `nil` (default) keeps the legacy behavior (no budget checks).
    public var requestBudget: BudgetTracker?

    /// Compactor used by the `.autoCompact` budget policy (F19 P1-4).
    /// Defaults to `Compactor()`. Automatic calls require the strict
    /// verbatim-text mode; a lossy summary cannot certify retained context.
    public var compactor: Compactor?

    /// Window admission (C10). nil keeps the loop exactly as before. When set,
    /// this loop alone decides, before every Provider request, whether the
    /// request copy is reduced (`config.reduction`, applied by the App's
    /// delivery projection), whether the history is compacted, whether the
    /// request is sent, and whether a Provider "context too long" error is
    /// recovered once by compaction/reduction.
    public var contextAdmission: ContextAdmissionConfig?

    /// Durable sink installed by the app composition root.  Manual compaction
    /// uses the same ChatSessionBridge boundary; when this sink is present,
    /// automatic compaction must durably install its checkpoint before the
    /// local history is replaced.
    public typealias CompactionCheckpointSink = @Sendable (
        _ sessionID: String,
        _ sourceMessages: [LLMMessage],
        _ result: CompactionResult
    ) async throws -> CompactionCheckpoint?
    public var compactionCheckpointSink: CompactionCheckpointSink?

    /// Production automatic compaction reads canonical history at the App
    /// boundary. The loop's history may already be a projection and include
    /// uncommitted tool rounds, so it must never become checkpoint source.
    public struct AutomaticCompactionTransition: Sendable {
        public let checkpoint: CompactionCheckpoint
        public let sourcePrefix: [LLMMessage]
        public let liveSuffix: [LLMMessage]
        public let runtimeSuffix: [LLMMessage]
        public let messages: [LLMMessage]

        public init(checkpoint: CompactionCheckpoint, sourcePrefix: [LLMMessage],
                    liveSuffix: [LLMMessage], runtimeSuffix: [LLMMessage],
                    messages: [LLMMessage]) {
            self.checkpoint = checkpoint
            self.sourcePrefix = sourcePrefix
            self.liveSuffix = liveSuffix
            self.runtimeSuffix = runtimeSuffix
            self.messages = messages
        }
    }
    public typealias AutomaticCompaction = @Sendable (
        _ sessionID: String, _ currentMessages: [LLMMessage], _ compactor: Compactor
    ) async throws -> AutomaticCompactionTransition
    public var automaticCompaction: AutomaticCompaction?

    /// Maximum duration of one provider request. Tool-specific timeouts remain
    /// enforced by the executor; this bound prevents a stalled provider from
    /// holding the whole turn forever.
    public var timeout: TimeInterval?

    /// Optional App limit on non-shell, non-browser tool effects.
    public var otherToolTimeout: TimeInterval?

    func toolTimeout(for name: String) -> TimeInterval? {
        if name == AskUserQuestionTool.toolName { return nil }
        // 子智能体派发与 MCP 工具各有自己的时限（子任务 2 小时上限、MCP 服务器配置的调用超时），
        // 不受"其它工具超时"和父回合时钟约束。
        if name == OrchestrationToolExecutor.toolName || name.hasPrefix("mcp_") { return nil }
        guard name != "shell_execute",
              !BrowserSideEffectPolicy.browserToolNames.contains(name.lowercased()),
              let otherToolTimeout, otherToolTimeout > 0 else { return timeout }
        guard let timeout, timeout > 0 else { return otherToolTimeout }
        return min(timeout, otherToolTimeout)
    }
    /// Optional Agent-First task ledger inherited by orchestration tools.
    public var taskStore: AgentTaskStore?
    public private(set) var parentBinding: ParentContextSnapshotV1?
    /// Optional child boundary. When present it owns the child catalog,
    /// cancellation, deadline and approval scope.
    public var childBoundary: AgentChildBoundary?
    public let childToolRuntimeBinding: AgentChildToolRuntimeBinding?
    // Set by the production orchestrator for the independently budgeted child.
    var childBudgetConsumingResponseAtRequestCap: BudgetTracker? = nil
    /// PolicyRuntime facts supplied by a production composition root.
    /// When present, `run` wraps the supplied executor before any tool call;
    /// missing/expired/denied policy therefore fails closed at the same
    /// per-tool seam as the real executor.
    public var policyRuntime: PolicyRuntimeBinding?
    /// Durable authority used for minting and settling per-call tool facts.
    public var toolExecutionFactLedger: ToolExecutionFactLedger?
    /// Scheduling only; per-call admission and effect-time authority stay unchanged.
    public var concurrentReadToolLimit: Int = 4
    /// Secure factory-created loops reject raw executors before provider/tool
    /// work. Legacy direct `AgentLoop` construction remains compatible.
    private let requiresPolicyRuntime: Bool

    /// D-CHAT-03：增量文本回调（AgentLoop→ChatAgentEngine 流式接线）。
    ///
    /// 安装后，若本轮 provider 链符合 `AssistantStreamingLLMProvider`，
    /// 每次 provider 调用的 assistant 文本增量会以 (iteration, delta) 实时
    /// 回调；`completed` 事件仍走原响应结算路径（预算、取消、超时语义
    /// 与缓冲 `sendMessage` 完全一致）。未安装回调或 provider 不流式时，
    /// 行为与旧缓冲路径逐字节相同（回调一次也不会触发）。
    /// 回调可能在非 MainActor 的 provider 消费任务上执行，必须 @Sendable。
    public typealias AssistantTextDeltaHandler = @Sendable (
        _ iteration: Int,
        _ delta: String
    ) async -> Void
    public var onAssistantTextDelta: AssistantTextDeltaHandler?
    /// 模型思考过程增量（仅显示用，不属于正文，也不进入后续请求历史）。
    /// 仅在 provider 流式返回思考内容时触发；不影响缓冲路径。
    public var onAssistantThinkingDelta: AssistantTextDeltaHandler?

    /// Reports an admitted truncated response so the App can reconcile its
    /// partial text with provider deltas already displayed for this iteration.
    public var onTruncatedAssistantResponse: (@Sendable (Int, String, String?) -> Void)?

    /// D-TOOL-16/17: producer-owned preterminal phases. Terminal state is
    /// published only by the durable ToolExecutionFactLedger; this callback
    /// never grants approval and never carries tool input or output.
    public var onToolExecutionPhase: (@Sendable (ToolExecutionPhaseFact) -> Void)?

    /// Content-free observation emitted only by a known dry-run, a typed
    /// authorization rejection before executor dispatch, or this request's
    /// first-Provider policy preflight. No tool input/output crosses this seam.
    public var onToolNonExecution: (@Sendable (String, ToolNonExecutionReason) -> Void)?

    /// 前台命令（shell_execute）的实时输出：参数是工具调用 ID 与一批已脱敏的新输出文本。
    /// 只给界面显示，不进入工具结果和模型历史，也不会触发新一轮。
    public var onToolLiveOutput: (@Sendable (String, String) -> Void)?

    /// The exact trusted child scope is shared by pre-Gate preparation and
    /// actual execution. App/model inputs cannot construct or widen this value.
    var childWorkspaceScope: ChildToolWorkspaceScope? = nil

    /// Freeze the selected project for this loop only. The shared builtin
    /// keeps an explicit safety ceiling. Only a session-derived owner admits
    /// the App-selected project here; model tool input never enters this seam.
    public mutating func captureToolWorkspace(
        directory: URL, owner: BuiltinToolExecutor, projectScoped: Bool = true, projectTask: Bool? = nil
    ) throws {
        let physical = directory.resolvingSymlinksInPath().standardizedFileURL
        let validated = try owner.validatedSessionWorkspaceDirectory(physical.path)
        let candidates = projectScoped
            ? [validated.path] + owner.additionalAllowedRoots.map { $0.resolvingSymlinksInPath().path }
            : ([owner.allowedRoot] + owner.additionalAllowedRoots).map { $0.resolvingSymlinksInPath().path }
        let roots = candidates.reduce(into: [String]()) { roots, path in
            if !roots.contains(path) { roots.append(path) }
        }
        childWorkspaceScope = ChildToolWorkspaceScope(
            readRoots: roots, writeRoots: roots,
            workingDirectory: validated.path, deniedRoots: owner.deniedRoots.map(\.path),
            parentAuthorityCheck: nil, filesOpen: true,
            explicitDeniedRoots: owner.explicitDeniedRoots.map(\.path),
            backgroundOrigin: !(projectTask ?? projectScoped) && childBoundary == nil && childToolRuntimeBinding == nil
                ? .globalParent : .restricted)
    }

    /// A projectless top-level chat has no inherited project scope. Clearing
    /// this value prevents the previously selected session from lending cwd.
    public mutating func clearCapturedToolWorkspace() {
        childWorkspaceScope = nil
    }

    /// Trusted child composition supplies only this exact run/attempt mailbox.
    /// Values become user instructions at the next model iteration; this does
    /// not interrupt a tool or change permissions, mode or the parent's queue.
    public var takeAdditionalChildInstructions: (@Sendable () throws -> [String])?

    /// Observational approval facts share the same ordered stream as tool
    /// phases. Only the real UI pending producer emits `.presented`; the gate
    /// and Composer remain the sole authorities for approval decisions.
    public var onApprovalLifecycle: (@Sendable (ApprovalLifecycleFact) -> Void)?

    /// App-owned projection of tool feedback before it enters model history.
    /// The optional callback carries no authority over execution or settlement.
    public var toolResultProjection: (@Sendable (String) async -> String)?

    public init(
        maxIterations: Int = 50,
        approvalGate: ApprovalGate? = nil,
        turnController: TurnController? = nil,
        loopDetector: ToolLoopDetector? = ToolLoopDetector(),
        requestBudget: BudgetTracker? = nil,
        compactor: Compactor? = nil,
        timeout: TimeInterval? = nil,
        taskStore: AgentTaskStore? = nil,
        parentBinding: ParentContextSnapshotV1? = nil,
        childBoundary: AgentChildBoundary? = nil,
        childToolRuntimeBinding: AgentChildToolRuntimeBinding? = nil,
        policyRuntime: PolicyRuntimeBinding? = nil,
        requiresPolicyRuntime: Bool = false,
        toolExecutionFactLedger: ToolExecutionFactLedger? = nil
    ) {
        self.maxIterations = Self.normalizedIterations(maxIterations)
        self.approvalGate = childBoundary?.approvalGate ?? approvalGate
        self.turnController = childBoundary?.childTurnController ?? turnController
        self.loopDetector = loopDetector
        self.requestBudget = childBoundary?.budget ?? requestBudget
        self.compactor = compactor
        self.compactionCheckpointSink = nil
        self.automaticCompaction = nil
        self.timeout = minTimeout(
            timeout.map { max(0, $0) },
            childBoundary?.remainingTimeout()
        )
        self.taskStore = taskStore
        self.parentBinding = parentBinding
        self.childBoundary = childBoundary
        self.childToolRuntimeBinding = childToolRuntimeBinding
        self.policyRuntime = policyRuntime
        self.requiresPolicyRuntime = requiresPolicyRuntime
        self.toolExecutionFactLedger = toolExecutionFactLedger
    }

    /// Completes composition of an unbound top-level loop. Returns a value
    /// copy so callbacks, policy, ledger, budget and all safety fields survive.
    /// An existing binding or any child boundary cannot be rebound.
    public func withParentBinding(_ binding: ParentContextSnapshotV1) throws -> AgentLoop {
        guard childBoundary == nil,
              parentBinding == nil || parentBinding == binding else {
            throw AgentLoopError.executionIdentityMismatch
        }
        var copy = self
        copy.parentBinding = binding
        return copy
    }

    /// Admit a user-initiated Task Center retry through the same Core turn
    /// controller and Composer identity checks as an ordinary loop turn.
    /// The caller owns the returned handle until it durably settles the new
    /// parent result; this does not create a child or grant a tool capability.
    public func admitDirectRetryParent(
        providerRuntimeRoute: ProviderRuntimeRoute,
        conversationID: String,
        composerSnapshot: ComposerSubmissionSnapshot,
        executionIdentity: AgentExecutionIdentity,
        offeredTools: [AgentToolDefinition],
        toolExecutor: any ToolExecutor,
        composerPolicyFacts: ComposerPolicyFactSource,
        childMutationsEnabled: Bool = false,
        parentAuthorityCheck: @escaping @Sendable () async -> Bool
    ) async throws -> AgentExecutionContextSnapshot {
        guard !composerPolicyFacts.revoked, composerPolicyFacts.expiresAt > Date(),
              composerPolicyFacts.workspaceID == composerSnapshot.workspaceID,
              composerPolicyFacts.revision == composerSnapshot.policyRevision,
              composerPolicyFacts.grantEpoch == composerSnapshot.grantEpoch,
              childBoundary == nil,
              let controller = turnController,
              let store = taskStore,
              toolExecutionFactLedger?.hasDurableAuthority == true,
              composerSnapshot.sessionID == conversationID,
              providerRuntimeRoute.snapshot.providerID == providerRuntimeRoute.name,
              providerRuntimeRoute.snapshot.modelID == providerRuntimeRoute.model.id else {
            throw AgentLoopError.executionIdentityMismatch
        }
        let seed = ParentRuntimeIdentitySeed(
            sessionID: composerSnapshot.sessionID,
            conversationID: conversationID,
            taskID: composerSnapshot.taskID,
            actorID: "app"
        )
        let handle = await controller.beginTurn()
        do {
            try validateSuppliedExecutionIdentity(
                executionIdentity,
                currentConversationID: conversationID,
                parentIdentitySeed: seed,
                composerSnapshot: composerSnapshot,
                turn: handle
            )
            let parent = try seed.makeIdentity(using: handle)
            let route = providerRuntimeRoute.snapshot
            let routeBinding = ParentContextSnapshotV1(
                providerID: route.providerID,
                modelID: route.modelID,
                configurationFingerprint: route.configurationFingerprint
                    ?? "provider:\(route.providerID)|model:\(route.modelID)",
                conversationID: conversationID
            )
            // Match ordinary AgentLoop.run: a production composition root may
            // carry additional immutable profile/host/wire/reasoning facts.
            let binding = parentBinding ?? routeBinding
            guard binding.providerID == route.providerID,
                  binding.modelID == route.modelID,
                  binding.conversationID == nil
                    || binding.conversationID == conversationID else {
                throw AgentLoopError.executionIdentityMismatch
            }
            let makeBudget: (@Sendable () -> BudgetTracker?)?
            if let requestBudget {
                makeBudget = { requestBudget }
            } else {
                makeBudget = nil
            }
            let deadline: Date? = timeout.map { Date().addingTimeInterval($0) }
            return AgentExecutionContextSnapshot(
                provider: providerRuntimeRoute,
                approvalGate: approvalGate,
                turnController: controller,
                currentConversationID: conversationID,
                makeChildBudget: makeBudget,
                deadline: deadline,
                taskStore: store,
                toolExecutionFactLedger: toolExecutionFactLedger,
                parentBinding: binding,
                parentTurnHandle: handle,
                parentRuntimeIdentity: parent,
                composerSnapshot: composerSnapshot,
                composerPolicyFacts: composerPolicyFacts,
                nestedShellExecutor: toolExecutor as? any NestedShellToolExecutor,
                offeredToolNames: Set(offeredTools.map(\.name)),
                childMutationsEnabled: childMutationsEnabled,
                parentAuthorityCheck: parentAuthorityCheck,
                executionIdentity: executionIdentity
            )
        } catch {
            await handle.finish()
            throw error
        }
    }

    /// Run the loop over `initialMessages`, returning the final history.
    public func run(
        messages initialMessages: [LLMMessage],
        systemPrompt: String?,
        provider: any LLMProvider,
        providerRuntimeRoute: ProviderRuntimeRoute? = nil,
        /// Identity of the route already wrapped by the caller for recording,
        /// retry and tool-call tracking. This does not replace `provider`.
        providerRuntimeRouteSnapshot: ProviderRuntimeSnapshot? = nil,
        toolExecutor: any ToolExecutor,
        tools: [AgentToolDefinition],
        maxTokens: Int = 4096,
        maxOutputTokensCeiling: Int? = nil,
        contextSettings: ContextTurnSettingsSnapshot? = nil,
        temperature: Double? = nil,
        /// Current conversation identity supplied by the composition root.
        /// It is never read from model tool input.
        currentConversationID: String? = nil,
        /// A target session is accepted only after the user-facing layer has
        /// identified explicit authorization in the original message. The
        /// loop turns it into a typed, turn-bound capability below.
        authorizedSessionReadSessionID: String? = nil,
        /// The user-facing layer must choose one of the two read-only scopes.
        /// A target without a scope is intentionally not authorized.
        authorizedSessionReadScope: SessionReadScope? = nil,
        /// Composition-root identity facts. Core supplies the turn ID from
        /// the real handle created for this run.
        parentIdentitySeed: ParentRuntimeIdentitySeed? = nil,
        /// Immutable Composer turn snapshot. When present, effort changes
        /// execution budgets only; approval, scope, capabilities, and
        /// permissions remain caller-owned.
        composerSnapshot: ComposerSubmissionSnapshot? = nil,
        childMutationsEnabled: Bool = false,
        parentAuthorityCheck: (@Sendable () async -> Bool)? = nil,
        /// Assistant placeholder identity minted by the composition root.
        /// When supplied, AgentLoop must carry it through the result instead
        /// of inventing a second message identity.
        executionIdentity: AgentExecutionIdentity? = nil,
        onFailure: (@Sendable ([LLMMessage]) -> Void)? = nil,
        onMessage: (@Sendable (Int, LLMMessage) throws -> Void)? = nil
    ) async throws -> AgentLoopResult {
        try Self.validateToolCatalog(tools)
        let effectiveProvider: any LLMProvider = providerRuntimeRoute ?? provider
        if let snapshot = providerRuntimeRouteSnapshot {
            guard snapshot.providerID == provider.name else {
                throw ProviderRuntimeSnapshotError.providerBindingMismatch(snapshot.providerID)
            }
            guard snapshot.modelID == provider.model.id else {
                throw ProviderRuntimeSnapshotError.modelBindingMismatch(snapshot.modelID)
            }
        }
        let routeParentBinding = (providerRuntimeRoute?.snapshot ?? providerRuntimeRouteSnapshot).map { snapshot in
            ParentContextSnapshotV1(
                providerID: snapshot.providerID,
                modelID: snapshot.modelID,
                configurationFingerprint: snapshot.configurationFingerprint
                    ?? "provider:\(snapshot.providerID)|model:\(snapshot.modelID)",
                conversationID: currentConversationID
            )
        }
        try validateSuppliedExecutionIdentity(
            executionIdentity,
            currentConversationID: currentConversationID,
            parentIdentitySeed: parentIdentitySeed,
            composerSnapshot: composerSnapshot
        )
        let effectiveToolExecutor: any ToolExecutor
        if let policyRuntime,
           !(toolExecutor is ComposerPolicyEnforcedToolExecutor) {
            effectiveToolExecutor = policyRuntime.wrap(toolExecutor)
        } else {
            // ComposerPolicyEnforcedToolExecutor already owns the stronger
            // snapshot/approval policy chain; preserve its call-aware seam.
            effectiveToolExecutor = toolExecutor
        }
        if requiresPolicyRuntime,
           (effectiveToolExecutor as? any PolicyRuntimeBoundToolExecutor)?.policyRuntimeBound != true {
            throw SecureAgentLoopError.policyRuntimeRequired
        }
        if let childBoundary {
            guard tools.allSatisfy({ childBoundary.allowsTool($0.name) })
                && (!childBoundary.grantedCapabilities.contains(.tools) || !tools.isEmpty)
            else {
                throw AgentLoopError.invalidToolCatalog("child capability intersection")
            }
            try await checkChildBoundary(childBoundary)
        }
        let effectiveTimeout = minTimeout(
            timeout,
            childBoundary?.remainingTimeout()
        )
        if let composerSnapshot,
           let composerExecutor = effectiveToolExecutor as? ComposerPolicyEnforcedToolExecutor {
            // The production wrapper owns the policy facts. Validate them
            // before the first Provider call so stale authorization cannot
            // spend a model request and fail only at tool execution time.
            guard composerExecutor.controller.snapshot == composerSnapshot else {
                throw AgentLoopError.composerSnapshotMismatch
            }
            do {
                try await composerExecutor.controller.validateSnapshot()
            } catch let error as ComposerAuthorizationError {
                // This exact preflight runs before the first Provider call or
                // any tool dispatch in this request. Do not infer the same
                // status from a later factsExpired error after an effect.
                if case .factsExpired = error {
                    onToolNonExecution?("", .requestPreflightExpired)
                }
                throw error
            }
        } else if composerSnapshot != nil && requiresPolicyRuntime {
            // Production Composer may never fall back to a generic policy
            // executor that lacks the turn-bound mode-ceiling preflight.
            throw AgentLoopError.composerAuthorizationUnavailable
        }
        // Freeze the execution profile before entering async context/provider
        // work so one turn cannot observe a later Composer state.
        let effortProfile = composerSnapshot.map {
            ComposerEffortExecutionProfile(
                snapshot: $0,
                baseMaxIterations: maxIterations,
                baseMaxTokens: maxTokens,
                maxOutputTokensCeiling: maxOutputTokensCeiling
            )
        }
        let providerMaxTokens = min(
            effortProfile?.maxTokens ?? maxTokens,
            maxOutputTokensCeiling ?? Int.max
        )
        guard providerMaxTokens > 0 else {
            throw AgentLoopError.outputTokenCeilingExhausted
        }
        return try await runWithExecutionContext(
            messages: initialMessages,
            systemPrompt: systemPrompt,
            provider: effectiveProvider,
            toolExecutor: effectiveToolExecutor,
            tools: tools,
            maxIterations: effortProfile?.maxIterations ?? Self.normalizedIterations(maxIterations),
            maxTokens: providerMaxTokens,
            contextSettings: contextSettings,
            temperature: temperature,
            currentConversationID: currentConversationID,
            authorizedSessionReadSessionID: authorizedSessionReadSessionID,
            authorizedSessionReadScope: authorizedSessionReadScope,
            parentIdentitySeed: parentIdentitySeed,
            resolvedParentBinding: parentBinding ?? routeParentBinding,
            composerSnapshot: composerSnapshot,
            childMutationsEnabled: childMutationsEnabled,
            parentAuthorityCheck: parentAuthorityCheck,
            executionIdentity: executionIdentity,
            toolAttemptID: AgentToolExecutionAttemptID.canonical(
                executionIdentity: executionIdentity,
                composerSnapshot: composerSnapshot,
                childBoundary: childBoundary
            ),
            toolAttemptNumber: executionIdentity?.attempt ?? 0,
            timeout: effectiveTimeout,
            onFailure: onFailure,
            onMessage: onMessage
        )
    }

    /// Structured counterpart to `run`: every thrown path returns the
    /// caller-owned failure together with the durable ledger's terminal facts.
    /// This is the consumable boundary for cancellation, timeout, provider,
    /// child-deadline, and max-iteration failures.
    public func runOutcome(
        messages initialMessages: [LLMMessage],
        systemPrompt: String?,
        provider: any LLMProvider,
        providerRuntimeRoute: ProviderRuntimeRoute? = nil,
        providerRuntimeRouteSnapshot: ProviderRuntimeSnapshot? = nil,
        toolExecutor: any ToolExecutor,
        tools: [AgentToolDefinition],
        maxTokens: Int = 4096,
        maxOutputTokensCeiling: Int? = nil,
        contextSettings: ContextTurnSettingsSnapshot? = nil,
        temperature: Double? = nil,
        currentConversationID: String? = nil,
        authorizedSessionReadSessionID: String? = nil,
        authorizedSessionReadScope: SessionReadScope? = nil,
        parentIdentitySeed: ParentRuntimeIdentitySeed? = nil,
        composerSnapshot: ComposerSubmissionSnapshot? = nil,
        executionIdentity: AgentExecutionIdentity? = nil,
        onMessage: (@Sendable (Int, LLMMessage) throws -> Void)? = nil
    ) async -> AgentLoopExecutionOutcome {
        do {
            let result = try await run(
                messages: initialMessages,
                systemPrompt: systemPrompt,
                provider: provider,
                providerRuntimeRoute: providerRuntimeRoute,
                providerRuntimeRouteSnapshot: providerRuntimeRouteSnapshot,
                toolExecutor: toolExecutor,
                tools: tools,
                maxTokens: maxTokens,
                maxOutputTokensCeiling: maxOutputTokensCeiling,
                contextSettings: contextSettings,
                temperature: temperature,
                currentConversationID: currentConversationID,
                authorizedSessionReadSessionID: authorizedSessionReadSessionID,
                authorizedSessionReadScope: authorizedSessionReadScope,
                parentIdentitySeed: parentIdentitySeed,
                composerSnapshot: composerSnapshot,
                executionIdentity: executionIdentity,
                onMessage: onMessage
            )
            return AgentLoopExecutionOutcome(
                result: result,
                failure: nil,
                toolExecutionFacts: result.toolExecutionFacts
            )
        } catch let error as AgentLoopError {
            return AgentLoopExecutionOutcome(
                result: nil,
                failure: AgentLoopStructuredFailure(
                    agentError: error,
                    message: error.localizedDescription,
                    toolExecutionFacts: factsForOutcome(
                        executionIdentity: executionIdentity,
                        composerSnapshot: composerSnapshot
                    )
                ),
                toolExecutionFacts: factsForOutcome(
                    executionIdentity: executionIdentity,
                    composerSnapshot: composerSnapshot
                )
            )
        } catch {
            return AgentLoopExecutionOutcome(
                result: nil,
                failure: AgentLoopStructuredFailure(
                    agentError: nil,
                    message: error.localizedDescription,
                    toolExecutionFacts: factsForOutcome(
                        executionIdentity: executionIdentity,
                        composerSnapshot: composerSnapshot
                    )
                ),
                toolExecutionFacts: factsForOutcome(
                    executionIdentity: executionIdentity,
                    composerSnapshot: composerSnapshot
                )
            )
        }
    }

    private func runWithExecutionContext(
        messages initialMessages: [LLMMessage],
        systemPrompt: String?,
        provider: any LLMProvider,
        toolExecutor: any ToolExecutor,
        tools: [AgentToolDefinition],
        maxIterations: Int,
        maxTokens: Int,
        contextSettings: ContextTurnSettingsSnapshot?,
        temperature: Double?,
        currentConversationID: String?,
        authorizedSessionReadSessionID: String?,
        authorizedSessionReadScope: SessionReadScope?,
        parentIdentitySeed: ParentRuntimeIdentitySeed?,
        resolvedParentBinding: ParentContextSnapshotV1?,
        composerSnapshot: ComposerSubmissionSnapshot?,
        childMutationsEnabled: Bool,
        parentAuthorityCheck: (@Sendable () async -> Bool)?,
        executionIdentity suppliedExecutionIdentity: AgentExecutionIdentity?,
        toolAttemptID: String?,
        toolAttemptNumber: Int,
        timeout: TimeInterval?,
        onFailure: (@Sendable ([LLMMessage]) -> Void)?,
        onMessage: (@Sendable (Int, LLMMessage) throws -> Void)?
    ) async throws -> AgentLoopResult {
        if let validator = toolExecutor as? any ToolCatalogValidatingExecutor {
            try validator.validateToolCatalog(tools)
        }
        // Composer approval is recognized only on the final, non-subclassable
        // wrapper. A public protocol marker would let an arbitrary executor
        // self-declare ownership and bypass this gate.
        let composerExecutor = toolExecutor as? ComposerPolicyEnforcedToolExecutor
        let toolOwnership = await ToolExecutionOwnershipRegistry.shared.ownership(for: toolExecutor)
        // F19 (P1-4): refuse the turn outright when the budget is already
        // exhausted under a `.pause` policy — no provider call is made.
        if let tracker = requestBudget, await tracker.shouldBlockNewRequests {
            throw AgentLoopError.budgetExhausted
        }

        let turn = await turnController?.beginTurn()
        do {
            try validateSuppliedExecutionIdentity(
                suppliedExecutionIdentity,
                currentConversationID: currentConversationID,
                parentIdentitySeed: parentIdentitySeed,
                composerSnapshot: composerSnapshot,
                turn: turn
            )
            let parentRuntimeIdentity: ParentRuntimeIdentity?
            if let parentIdentitySeed {
                guard let turn else {
                    throw ParentRuntimeIdentitySeedError.turnHandleRequired
                }
                if let currentConversationID,
                   currentConversationID != parentIdentitySeed.conversationID {
                    throw ParentRuntimeIdentitySeedError.conversationMismatch
                }
                if let boundConversationID = parentBinding?.conversationID,
                   boundConversationID != parentIdentitySeed.conversationID {
                    throw ParentRuntimeIdentitySeedError.parentBindingMismatch
                }
                parentRuntimeIdentity = try parentIdentitySeed.makeIdentity(using: turn)
            } else {
                parentRuntimeIdentity = nil
            }
            var makeChildBudget: (@Sendable () -> BudgetTracker?)?
            if let requestBudget {
                makeChildBudget = { requestBudget }
            } else {
                makeChildBudget = nil
            }
            // Each newly constructed loop (including retry) resolves its own
            // current native grant. Never inherit a prior run's grant snapshot.
            let taskArtifactProject: TaskFileArtifactProjectGrant?
            if let childToolRuntimeBinding,
               let owner = ((composerExecutor?.base ?? toolExecutor) as? any BuiltinOwnerBoundToolExecutor)?.currentBuiltinOwner {
                taskArtifactProject = await owner.captureChildTaskArtifactProject(
                    workingDirectory: childToolRuntimeBinding.boundary.identity.workingDirectory)
            } else { taskArtifactProject = nil }
            let executionContext = AgentExecutionContextSnapshot(
                provider: provider,
                approvalGate: approvalGate,
                turnController: turnController,
                currentConversationID: currentConversationID,
                makeChildBudget: makeChildBudget,
                deadline: timeout.map { Date().addingTimeInterval($0) },
                taskStore: taskStore,
                toolExecutionFactLedger: toolExecutionFactLedger,
                parentBinding: resolvedParentBinding ?? ParentContextSnapshotV1(
                    providerID: provider.name,
                    modelID: provider.model.id,
                    configurationFingerprint: "provider:\(provider.name)|model:\(provider.model.id)",
                    conversationID: currentConversationID
                ),
                parentTurnHandle: turn,
                parentRuntimeIdentity: parentRuntimeIdentity,
                childRuntimeSnapshot: childBoundary.map { AgentChildRuntimeSnapshot(identity: $0.identity) },
                childToolRuntimeBinding: childToolRuntimeBinding,
                taskArtifactProject: taskArtifactProject,
                composerSnapshot: composerSnapshot,
                composerPolicyFacts: (toolExecutor as? ComposerPolicyEnforcedToolExecutor)?.controller.facts,
                nestedShellExecutor: toolExecutor as? any NestedShellToolExecutor,
                offeredToolNames: Set(tools.map(\.name)),
                childMutationsEnabled: childMutationsEnabled,
                parentAuthorityCheck: parentAuthorityCheck,
                executionIdentity: suppliedExecutionIdentity
            )
            return try await ChildToolWorkspaceScope.$current.withValue(childWorkspaceScope) {
            try await AgentExecutionContext.$current.withValue(executionContext) {
            var messages = initialMessages
            var admittedMessageIndex = 0
            let executionIdentity: AgentExecutionIdentity? = {
                if let suppliedExecutionIdentity { return suppliedExecutionIdentity }
                guard let currentConversationID, let turn else { return nil }
                return AgentExecutionIdentity(
                    turn: AgentTurnIdentity(
                        sessionID: currentConversationID,
                        turnID: turn.turnID,
                        messageID: UUID().uuidString
                    )
                )
            }()
            do {
            if let onMessage {
                for message in initialMessages {
                    try onMessage(admittedMessageIndex, message)
                    admittedMessageIndex += 1
                }
            } else {
                admittedMessageIndex = initialMessages.count
            }
            var toolCallsExecuted = 0
            // `.autoCompact` compacts at most once per run: the budget counts
            // cumulative session tokens, so the policy keeps firing on every
            // subsequent record; re-compacting each iteration would churn the
            // history without freeing any counted budget.
            var didAutoCompact = false
            // Compaction is a model summary (one extra request), so it is only
            // worth doing when the run continues: it runs at the start of the
            // next iteration, after the tool results of the response that
            // exhausted the budget are in `messages` (summarized whole).
            var budgetCompactionDue = false
            var admissionRun = contextAdmission.map(ContextAdmissionRun.init(config:))
            let toolSchemaTokens = AgentContextTokenBudget.estimatedToolSchemaTokens(tools)
            var continuationTruncationNotice: String?
            // Only runs that actually offer todo_write nudge about its checklist.
            var todoReminder = SessionTodoReminder(
                history: tools.contains { $0.name == SessionTodoProgress.toolName } ? initialMessages : [])
            var repeatedToolFailures = RepeatedToolFailureCounter()

        for iteration in 1...maxIterations {
            if let childBoundary {
                guard await parentAuthorityCheck?() != false else { throw CancellationError() }
                try await checkChildBoundary(childBoundary)
            }
            // A handle is tied to this exact turn. A sibling turn sharing the
            // controller cannot cancel this loop.
            if let turn, await turn.isCancelled() {
                throw InterruptedError()
            }
            try Task.checkCancellation()

            if let takeAdditionalChildInstructions {
                for instruction in try takeAdditionalChildInstructions() {
                    let message = LLMMessage(role: .user, content: "[用户追加指令]\n" + instruction)
                    messages.append(message)
                    try onMessage?(admittedMessageIndex, message)
                    admittedMessageIndex += 1
                }
            }

            if budgetCompactionDue {
                budgetCompactionDue = false
                messages = try await applyAutomaticCompaction(
                    messages: messages, currentConversationID: currentConversationID, turn: turn)
                didAutoCompact = true
                admissionRun?.transcriptReplaced()
            }

            let requestSystemPrompt: String?
            let todoNotice = todoReminder.requestReminder()
            if continuationTruncationNotice != nil || todoNotice != nil {
                requestSystemPrompt = [systemPrompt, continuationTruncationNotice, todoNotice]
                    .compactMap { $0 }.filter { !$0.isEmpty }
                    .joined(separator: "\n\n")
            } else {
                requestSystemPrompt = systemPrompt
            }

            // Window admission (C10): decided here and nowhere else.
            // Reduction (free) -> compaction -> send / refuse at >= 95%.
            if var run = admissionRun {
                var decision = try run.decide(messages: messages, systemPrompt: requestSystemPrompt ?? "",
                                              toolSchemaTokens: toolSchemaTokens)
                if case .compact = decision {
                    if run.compactionsPerformed < ContextAdmissionRun.maximumCompactionsPerRun,
                       let compacted = try await attemptContextCompaction(
                        messages: messages, currentConversationID: currentConversationID, turn: turn) {
                        if let turn, await turn.isCancelled() { throw InterruptedError() }
                        try Task.checkCancellation()
                        messages = compacted
                        run.compactionsPerformed += 1
                        run.transcriptReplaced()
                    }
                    run.compactionJudged = true
                    decision = try run.decide(messages: messages, systemPrompt: requestSystemPrompt ?? "",
                                              toolSchemaTokens: toolSchemaTokens)
                }
                run.overflowRecoveriesInIteration = 0
                admissionRun = run
                if case .blocked(let fraction) = decision {
                    throw AgentLoopError.contextWindowFull(fraction: fraction)
                }
            }

            var sent: (response: LLMResponse, lease: BudgetRequestLease?, capture: UsageServedRouteCapture)?
            repeat {
            // The selected context length is frozen for this turn, but tool
            // results and assistant calls grow `messages` between requests.
            // Recompute only the remaining window; effort/model caps above
            // remain fixed and are never applied a second time.
            let requestMaxTokens: Int
            if let contextSettings, contextSettings.isContextLengthUserSelected {
                let requestView = try admissionRun?.requestView(messages) ?? messages
                guard let inputCost = AgentContextTokenBudget.estimatedInputCost(
                    requestView, systemPrompt: requestSystemPrompt ?? ""
                ) else {
                    throw AgentLoopError.outputTokenCeilingExhausted
                }
                let remaining = contextSettings.contextLengthTokens - inputCost
                guard remaining > 0 else {
                    throw AgentLoopError.outputTokenCeilingExhausted
                }
                requestMaxTokens = min(maxTokens, remaining)
            } else {
                requestMaxTokens = maxTokens
            }

            // Reserve before entering the provider. Failed/cancelled attempts
            // release the lease without charging the budget.
            let lease: BudgetRequestLease?
            if let tracker = requestBudget {
                do {
                    lease = try await tracker.beginRequest()
                } catch is BudgetTrackerError {
                    throw AgentLoopError.budgetExhausted
                }
            } else {
                lease = nil
            }

            let usageRouteCapture = UsageServedRouteCapture()
            do {
                if let turn, await turn.isCancelled() {
                    throw InterruptedError()
                }
                try Task.checkCancellation()
                let requestMessages = admissionRun?.deliveryCopy(messages) ?? messages
                let attempt = try await UsageTelemetryContext.$servedRouteCapture.withValue(usageRouteCapture) {
                    try await sendProvider(
                        provider: provider,
                        messages: requestMessages,
                        systemPrompt: requestSystemPrompt,
                        tools: tools,
                        maxTokens: requestMaxTokens,
                        temperature: temperature,
                        timeout: timeout,
                        iteration: iteration,
                        turnHandle: turn,
                        thinkingLevel: resolvedParentBinding?.reasoningConfiguration.flatMap(ThinkingLevel.init(rawValue:))
                    )
                }
                sent = (attempt, lease, usageRouteCapture)
            } catch {
                if let tracker = requestBudget, let lease {
                    await tracker.failRequest(lease)
                }
                // C3-11: the newest message's own media already fills the whole history
                // media budget, so every older image is gone from the request and neither
                // compaction nor reduction can make it smaller. Do not summarize for nothing:
                // surface the plain "request too large" error (reduce the images), not
                // "compress the conversation".
                if let llmError = error as? LLMError, case .contextLengthExceeded = llmError,
                   HistoryMediaBudget.protectedMediaBytes(messages) >= HistoryMediaBudget.defaultMaxBytes {
                    throw LLMError.httpStatus(code: 413, detail: "")
                }
                // Provider "context too long": compact once (or reduce the
                // request copy) and resend. At most 1 per iteration, 2 per run;
                // the next overflow surfaces as the typed error.
                if var run = admissionRun,
                   let llmError = error as? LLMError, case .contextLengthExceeded = llmError,
                   run.overflowRecoveriesInIteration < ContextAdmissionRun.maximumOverflowRecoveriesPerIteration,
                   run.overflowRecoveriesInRun < ContextAdmissionRun.maximumOverflowRecoveriesPerRun {
                    run.overflowRecoveriesInIteration += 1
                    run.overflowRecoveriesInRun += 1
                    var progressed = false
                    if run.mayCompact,
                       let compacted = try await attemptContextCompaction(
                        messages: messages, currentConversationID: currentConversationID, turn: turn) {
                        if let turn, await turn.isCancelled() { throw InterruptedError() }
                        try Task.checkCancellation()
                        messages = compacted
                        run.compactionsPerformed += 1
                        run.transcriptReplaced()
                        progressed = true
                    }
                    if !progressed, !run.config.reduction.isActive {
                        run.config.reduction.activate()
                        run.transcriptReplaced()
                        progressed = run.config.reduction.reducedView(of: messages).changedAnything
                    }
                    admissionRun = run
                    if progressed { continue }
                }
                // 压缩或缩减已经做过一次仍然超长，而最新一条用户消息自己带着图片或音频：
                // 还能减的只有这条消息的媒体，提示“请求内容太大”，不再让用户去“压缩对话”。
                if let llmError = error as? LLMError, case .contextLengthExceeded = llmError,
                   (admissionRun?.overflowRecoveriesInRun ?? 0) > 0,
                   HistoryMediaBudget.newestUserMessageHasMedia(messages) {
                    throw LLMError.httpStatus(code: 413, detail: "")
                }
                throw error
            }
            } while sent == nil
            let response = sent!.response
            let lease = sent!.lease
            let usageRouteCapture = sent!.capture
            let sentMessages = messages

            // A cancellation that arrives while the provider is in flight
            // invalidates this response before it becomes billable. The
            // lease must be released before any success settlement.
            if let turn, await turn.isCancelled() {
                if let tracker = requestBudget, let lease {
                    await tracker.failRequest(lease)
                }
                throw InterruptedError()
            }
            if let childBoundary {
                do {
                    try await checkChildBoundary(childBoundary)
                } catch {
                    // A rejected child response is still an unsettled request.
                    // Release its reservation before propagating the boundary error.
                    if let tracker = requestBudget, let lease {
                        await tracker.failRequest(lease)
                    }
                    throw error
                }
            }
            if Task.isCancelled {
                if let tracker = requestBudget, let lease {
                    await tracker.failRequest(lease)
                }
                throw CancellationError()
            }

            // A user stop has precedence over every response-shape error. In
            // particular, do not let an empty provider response mask an
            // interruption that arrived while the request was in flight.
            if let turn, await turn.isCancelled() {
                if let tracker = requestBudget, let lease {
                    await tracker.failRequest(lease)
                }
                throw InterruptedError()
            }

            if let origin = UsageTelemetryContext.childOrigin, let usage = response.usage {
                let route = await usageRouteCapture.value() ?? UsageTelemetryContext.directRoute(of: provider)
                await UsageTelemetryContext.observer?(.childUsage(origin: origin, usage: usage, route: route))
            }

            // F19 (P1-4): every round-trip is recorded into the shared budget
            // and the returned policy is ENFORCED (not just displayed):
            //   .pause       → halt the turn with budgetExhausted
            //   .autoCompact → compact history once, then continue
            //   .warn        → continue (UI reads the tracker state)
            if let tracker = requestBudget, let lease {
                if let policy = await tracker.completeRequest(
                    lease, usage: response.usage,
                    consumeResponseAtRequestCap: childBudgetConsumingResponseAtRequestCap === tracker
                        && childBoundary?.budget === tracker
                ) {
                    switch policy {
                    case .pause:
                        throw AgentLoopError.budgetExhausted
                    case .autoCompact:
                        if !didAutoCompact { budgetCompactionDue = true }
                    case .warn:
                        break
                    }
                }
            }

            if admissionRun != nil {
                try admissionRun!.recordResponse(sentMessages: sentMessages, usage: response.usage)
            }

            // A stop/cancel that arrived while Provider was in flight must not
            // reach approval, tools, or response validation. The successful
            // response was charged above before this guard.
            if let turn, await turn.isCancelled() {
                throw InterruptedError()
            }
            try Task.checkCancellation()

            let text = response.text
            let nativeCalls = response.toolCalls

            let truncation: AgentLoopError?
            if response.discardedToolCallCount <= 0 {
                truncation = nil
            } else if let notice = response.discardedToolCallNotice {
                truncation = .truncatedToolCallsWithDiagnostic(
                    .init(count: response.discardedToolCallCount, notice: notice)
                )
            } else {
                truncation = .truncatedToolCalls(response.discardedToolCallCount)
            }

            // Plain-text reply cut by the Provider's output limit. Discarded tool
            // calls keep their own typed notice above.
            let outputTruncated = truncation == nil && nativeCalls.isEmpty
                && (response.stopReason == "length" || response.stopReason == "max_tokens"
                    || response.stopReason?.hasPrefix("incomplete") == true)

            guard truncation != nil || outputTruncated
                || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !nativeCalls.isEmpty else {
                throw AgentLoopError.emptyResponse
            }

            let legacyCalls = nativeCalls.isEmpty && truncation == nil && !outputTruncated
                ? Self.parseToolCalls(from: text) : nil
            if budgetCompactionDue, automaticCompaction != nil,
               nativeCalls.isEmpty, legacyCalls?.isEmpty != false, truncation == nil, !outputTruncated {
                // A plain reply ends the loop. Compact while its assistant
                // placeholder still belongs to the frozen canonical source.
                let compacted = try await attemptContextCompaction(
                    messages: messages, currentConversationID: currentConversationID, turn: turn)
                if let turn, await turn.isCancelled() { throw InterruptedError() }
                try Task.checkCancellation()
                if let compacted { messages = compacted }
            }

            // The provider's reply is still parsed and executed from its original
            // bytes below. Its assistant-history echo, however, is sent back on
            // the next request and must receive the same known-value protection
            // as tool results before it enters that history.
            var historyText = text
            var historyCalls = nativeCalls
            if let toolResultProjection {
                historyText = await toolResultProjection(text)
                historyCalls = []
                historyCalls.reserveCapacity(nativeCalls.count)
                for call in nativeCalls {
                    let projectedRaw = await toolResultProjection(call.rawArguments)
                    // 回传给服务商的 reasoning_content 与正文、参数一样要先过已知敏感值保护。
                    var projectedReasoning: String?
                    if let reasoning = call.reasoningContent {
                        projectedReasoning = await toolResultProjection(reasoning)
                    }
                    let projectedArguments: [String: Any]
                    if projectedRaw == call.rawArguments {
                        projectedArguments = call.arguments
                    } else if let data = projectedRaw.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: data),
                              let dictionary = object as? [String: Any] {
                        projectedArguments = dictionary
                    } else {
                        // If projection altered the JSON shape, do not echo the
                        // original argument dictionary or malformed raw payload.
                        var emptyCall = LLMToolCall(
                            id: call.id, name: call.name,
                            rawArguments: "{}", arguments: [:]
                        )
                        emptyCall.thinkingBlocks = call.thinkingBlocks
                        emptyCall.reasoningContent = projectedReasoning
                        historyCalls.append(emptyCall)
                        continue
                    }
                    var projectedCall = LLMToolCall(
                        id: call.id, name: call.name,
                        rawArguments: projectedRaw, arguments: projectedArguments
                    )
                    projectedCall.thinkingBlocks = call.thinkingBlocks
                    projectedCall.reasoningContent = projectedReasoning
                    historyCalls.append(projectedCall)
                }
            }
            let truncationNotice = truncation?.errorDescription
            if truncationNotice != nil {
                if let turn, await turn.isCancelled() { throw InterruptedError() }
                try Task.checkCancellation()
            }
            let assistantMessage = LLMMessage(
                role: .assistant, content: historyText, toolCalls: historyCalls
            )
            messages.append(assistantMessage)
            try onMessage?(admittedMessageIndex, assistantMessage)
            admittedMessageIndex += 1

            if let truncationNotice {
                let displayNotice = historyText.isEmpty ? truncationNotice : "\n\n" + truncationNotice
                onTruncatedAssistantResponse?(iteration, historyText, nativeCalls.isEmpty ? nil : displayNotice)
            }

            // Never execute a legacy text envelope or report success from a
            // reply the Provider explicitly cut off; the partial text above is
            // already in the failure history and flushed to the display.
            if outputTruncated {
                onTruncatedAssistantResponse?(iteration, historyText, nil)
                throw AgentLoopError.outputTruncated
            }

            // An entirely discarded native response is terminal. Its partial
            // text cannot become an executable legacy envelope.
            if let truncation, nativeCalls.isEmpty { throw truncation }

            // A mixed response already requires a continuation for admitted
            // calls. Carry the count on that request, outside the transcript.
            continuationTruncationNotice = truncationNotice

            // Determine the tool calls to execute. Native tool_calls take
            // priority; otherwise fall back to the legacy text envelope.
            let isNative = !nativeCalls.isEmpty
            let calls: [ParsedToolCall]
            if isNative {
                calls = nativeCalls.map { ParsedToolCall(id: $0.id, name: $0.name, input: $0.arguments) }
            } else if let legacyCalls, !legacyCalls.isEmpty {
                calls = legacyCalls
            } else {
                // Plain text — turn complete.
                if let taskStore, let parentRuntimeIdentity, let executionIdentity {
                    // An accepted orchestration failure is sticky for this
                    // parent turn. Ordinary tool errors may be recovered by
                    // later model steps, but a failed child join cannot become
                    // a durable parent success merely because the model ended
                    // with plain text.
                    let failedOrchestration = toolExecutionFactLedger?.facts(
                        executionIdentity: executionIdentity,
                        attemptID: toolAttemptID ?? "",
                        attemptNumber: toolAttemptNumber
                    ).contains {
                        $0.toolName == OrchestrationToolExecutor.toolName
                            && $0.status == .failed
                    } ?? false
                    do {
                        _ = try taskStore.recordParentTurnTerminal(
                            parent: parentRuntimeIdentity, execution: executionIdentity,
                            outcome: failedOrchestration ? .failed : .succeeded)
                    } catch {
                        throw AgentLoopError.parentTerminalPersistenceFailed
                    }
                }
                await turn?.finish()
                return AgentLoopResult(
                    messages: Self.withoutToolImages(messages),
                    iterationCount: iteration,
                    toolCallsExecuted: toolCallsExecuted,
                    executionIdentity: executionIdentity,
                    toolExecutionFacts: {
                        guard let executionIdentity,
                              let toolExecutionFactLedger else {
                            return []
                        }
                        return toolExecutionFactLedger.facts(
                            executionIdentity: executionIdentity,
                            attemptID: toolAttemptID ?? "",
                            attemptNumber: toolAttemptNumber
                        )
                    }()
                )
            }

            // Execute each tool call in order and build per-call results.
            var resultParts: [[String: Any]] = []
            var successfulSettingsCatalogResults: [Int: String] = [:]
            resultParts.reserveCapacity(calls.count)
            var preparedReads: [PreparedRead] = []
            // Scheduling must respect the existing runtime ceiling before
            // effects race its fail-closed active-task admission boundary.
            let boundPolicy = (composerExecutor?.base ?? toolExecutor) as? PolicyEnforcedToolExecutor
            let runtimeReadLimit = min(policyRuntime?.goal.concurrencyLimit ?? concurrentReadToolLimit,
                boundPolicy?.goal.concurrencyLimit ?? concurrentReadToolLimit)
            let readLimit = min(max(1, concurrentReadToolLimit), max(1, runtimeReadLimit))
            let readRunner = ConcurrentToolRunner(maxConcurrent: readLimit)
            func abandonPreparedReads() async throws {
                let abandoned = preparedReads
                preparedReads.removeAll()
                var firstFailure: (any Error)?
                for item in abandoned {
                    guard item.state.closeIfNotEntered() else { continue }
                    await item.authorization?.observeUnexecutedCancellation()
                    do {
                        if let ledger = toolExecutionFactLedger,
                           ledger.pendingReceipts.contains(where: { $0.receiptID == item.receipt.receiptID }) {
                            try settleToolExecutionFact(ledger, receipt: item.receipt, status: .cancelled)
                        }
                    } catch { firstFailure = firstFailure ?? error }
                }
                if let firstFailure { throw firstFailure }
            }
            func drainPreparedReads() async throws {
                guard !preparedReads.isEmpty else { return }
                let turnCancelled = await turn?.isCancelled() == true
                if Task.isCancelled || turnCancelled {
                    try await abandonPreparedReads()
                    throw InterruptedError()
                }
                let batch = preparedReads
                preparedReads.removeAll()
                let invocations = batch.map { ToolInvocation(id: $0.call.id, name: $0.call.name, input: $0.call.input) }
                let outcomes: [ToolRunResult]
                let enqueuedAt = DispatchTime.now().uptimeNanoseconds
                do {
                    outcomes = try await toolOwnership.performReadCohort(count: batch.count,
                        timeout: timeout, enqueuedAt: enqueuedAt) { children in
                    let effects = zip(batch, children).reduce(into: [String: @Sendable () async throws -> String]()) {
                        let item = $1.0
                        let child = $1.1
                        $0[item.call.id] = {
                            let remaining = ToolExecutionOwnership.remainingReadCohortTimeout(toolTimeout(for: item.call.name), enqueuedAt: enqueuedAt)
                            return try await item.effect(child, remaining)
                        }
                    }
                    return await readRunner.runPreparedEffects(invocations, executor: toolExecutor,
                        executionIdentity: executionIdentity, effects: effects, childBoundary: childBoundary)
                }
                } catch {
                    // Logical cancellation may return while the physical FIFO
                    // entry still drains. Only never-entered effects are ours
                    // to settle here; entered effects retain their real owner.
                    outcomes = batch.enumerated().map {
                        ToolRunResult(index: $0.offset, invocation: invocations[$0.offset],
                            output: nil, errorMessage: error.localizedDescription, underlyingError: error)
                    }
                }
                // The join above is a hard model-step/barrier boundary. Only
                // this serial merge touches shared history or result order.
                var fatal: (any Error)?
                for (item, outcome) in zip(batch, outcomes) {
                    let childError = outcome.underlyingError as? AgentChildLifecycleError
                    let cancelled = outcome.underlyingError is CancellationError
                        || outcome.underlyingError is InterruptedError || childError == .cancelled
                    let deadline = childError == .deadlineExceeded
                        || { if let error = outcome.underlyingError, case ToolExecutorError.toolTimeout = error { return true }; return false }()
                    if let error = outcome.underlyingError {
                        if childError == .cancelled { fatal = fatal ?? InterruptedError() }
                        else if childError == .deadlineExceeded { fatal = fatal ?? AgentLoopError.timedOut(childBoundary?.remainingTimeout() ?? 0) }
                        else if case ToolExecutorError.toolTimeout = error { fatal = fatal ?? error }
                        else if cancelled || error is AgentLoopError || error is ToolExecutionFactLedgerError {
                            fatal = fatal ?? error
                        }
                    }
                    do {
                        if item.state.closeIfNotEntered(), let ledger = toolExecutionFactLedger,
                           ledger.pendingReceipts.contains(where: { $0.receiptID == item.receipt.receiptID }) {
                            await item.authorization?.observeUnexecutedCancellation()
                            try settleToolExecutionFact(ledger, receipt: item.receipt,
                                status: cancelled ? .cancelled : .failed,
                                failureCategory: deadline ? .timeout : nil)
                        }
                    } catch { fatal = fatal ?? error }
                    resultParts.append(["type": "tool_result", "tool_use_id": item.call.id,
                        "content": outcome.output ?? "Error executing tool \(item.call.name): \(outcome.errorMessage ?? "execution failed")",
                        "is_error": !outcome.isSuccess])
                }
                if let fatal { throw fatal }
            }
            do {
            // V-6：参数超过边界上限的调用不执行、不审批，给模型回一条固定的工具错误，让它分段重试。
            let oversizedCallIDs: Set<String> = isNative
                ? Set(nativeCalls.filter(\.argumentsExceedLimit).map(\.id)) : []
            for parsedCall in calls {
                if oversizedCallIDs.contains(parsedCall.id) {
                    try await drainPreparedReads()
                    resultParts.append([
                        "type": "tool_result",
                        "tool_use_id": parsedCall.id,
                        "content": ProviderToolCallBoundary.oversizedArgumentsToolResult,
                        "is_error": true,
                    ])
                    continue
                }
                let routedOwner = ((composerExecutor?.base ?? toolExecutor) as? any BuiltinOwnerBoundToolExecutor)?.currentBuiltinOwner
                // Exact native names and a concrete bound owner; never MCP
                // annotations, model assertions, browser hints, or risk level.
                let concurrentRead = readLimit > 1 && routedOwner != nil
                    && (ApprovedFileReadScope.isRead(parsedCall.name)
                        || parsedCall.name == OrchestrationToolExecutor.resultToolName)
                if !concurrentRead { try await drainPreparedReads() }
                // Children never create a user-facing waiter. Return a structured
                // clarification failure through the existing parent report path.
                if parsedCall.name == AskUserQuestionTool.toolName,
                   childBoundary != nil || UsageTelemetryContext.childOrigin != nil {
                    throw try AskUserQuestionTool.NeedsClarification(request: AskUserQuestionTool.parse(parsedCall.input))
                }
                let call: ParsedToolCall
                if ToolPathResolution.toolNames.contains(parsedCall.name),
                   let path = parsedCall.input["path"] as? String, !path.isEmpty, !path.hasPrefix("/"),
                   let absolute = ToolPathResolution.absolutePath(
                       for: path,
                       workingDirectory: childToolRuntimeBinding?.boundary.identity.workingDirectory
                           ?? childWorkspaceScope?.workingDirectory
                           ?? routedOwner?.effectiveWorkingDirectory.path) {
                    // `~` and relative paths resolve against this call's working
                    // directory (a child's frozen one, else the session project)
                    // before policy, approval and locking, so every consumer sees
                    // the same absolute target. A path with `..` stays as given
                    // and is refused downstream.
                    var input = parsedCall.input
                    input["path"] = absolute
                    call = ParsedToolCall(id: parsedCall.id, name: parsedCall.name, input: input)
                } else { call = parsedCall }
                var receipt: ToolExecutionReceipt?
                var fileMutationLease: ToolFileMutationLease?
                var rejectedFilePreflight = false
                var dispatchStartedAtNanoseconds: UInt64?
                var executorDispatchStarted = false
                let shellApprovalCapture = call.name == "shell_execute" ? ApprovedShellReceiptCapture() : nil
                // N1: record every parsed tool call before it can execute.
                // Once the same signature repeats `loopThreshold` times
                // consecutively, block the call (never handed to the
                // executor) and inject a `[LOOP BLOCKED]` is_error result so
                // the model changes tack instead of burning tokens on a dead
                // loop. The detector also counts gate-refused calls, so a
                // model stuck re-requesting a denied tool is caught too.
                if let detector = loopDetector {
                    detector.recordInvocation(tool: call.name, input: call.input)
                    if detector.isLooping() {
                        try await drainPreparedReads()
                        let toolName = call.name
                        let threshold = detector.loopThreshold
                        resultParts.append([
                            "type": "tool_result",
                            "tool_use_id": call.id,
                            "content": "[LOOP BLOCKED] 检测到重复调用 \(toolName) 连续 \(threshold) 次，请改用其他方法或终止该操作",
                            "is_error": true,
                        ])
                        continue
                    }
                }
                do {
                    if childToolRuntimeBinding != nil,
                       ["file_write", "file_edit"].contains(parsedCall.name),
                       let path = parsedCall.input["path"] as? String, path.hasPrefix("~") {
                        throw ToolExecutorError.pathViolation(path)
                    }
                    // A caller-provided catalog is authoritative. An empty
                    // catalog still falls back to the canonical built-in set;
                    // it never turns arbitrary executor input into a tool.
                    let offeredTools: [AgentToolDefinition]
                    if tools.isEmpty && childBoundary == nil {
                        // Keep the executor's compatibility alias visible in
                        // legacy empty-catalog calls without accepting
                        // arbitrary names or unregistered MCP tools.
                        // P3-P1-05: the former bare `web_search` definition was
                        // removed — the capability is un-wired (absent from
                        // defaultRegisteredToolNames and from AgentToolCatalog),
                        // so the fallback must not accept its calls either;
                        // web_search now fails at the gate below as
                        // unknownTool, which the loop records as an
                        // error-class (is_error) tool_result.
                        offeredTools = AgentToolCatalog.makeTools()
                            + [
                                AgentToolDefinition(
                                    name: BrowserTool.legacyToolName,
                                    description: "",
                                    parameters: [:],
                                    required: []
                                ),
                            ]
                    } else {
                        offeredTools = tools
                    }
                    if !offeredTools.contains(where: { $0.name == call.name }) {
                        throw ToolExecutorError.unknownTool(call.name)
                    }
                    if let turn, await turn.isCancelled() {
                        throw InterruptedError()
                    }
                    if let childBoundary {
                        try await checkChildBoundary(childBoundary)
                    }
                    try Task.checkCancellation()
                    // Bind only this parsed call to the eventual UI pending
                    // and authority result. No receipt or permission is minted
                    // here; a missing canonical identity leaves no context.
                    let approvalPresentationContext = makeApprovalPresentationContext(
                        executionIdentity: executionIdentity,
                        attemptID: toolAttemptID,
                        attemptNumber: toolAttemptNumber,
                        toolCallID: call.id,
                        toolName: call.name
                    )
                    if ["file_write", "file_edit", "file_delete"].contains(call.name),
                       let owner = ((composerExecutor?.base ?? toolExecutor) as? any BuiltinOwnerBoundToolExecutor)?.currentBuiltinOwner,
                       let approvalPresentationContext {
                        // Transparent owners must not move an ordinary
                        // Composer policy refusal into builtin failed-effect
                        // accounting. Preserve the original policy-first gate;
                        // accepted calls still take every physical precheck.
                        if let composerExecutor {
                            // Keep the existing live cancellation boundary
                            // ahead of policy refusal classification as well.
                            try Task.checkCancellation()
                            guard await parentAuthorityCheck?() != false else { throw CancellationError() }
                            try await composerExecutor.controller.revalidate(
                                capability: call.name, input: ComposerToolInput(call.input))
                        }
                        do {
                            guard let raw = call.input["path"] as? String else { throw ToolExecutorError.invalidParameter("path") }
                            let validate = owner.fileArtifactTargetValidator()
                            let roots = [owner.allowedRoot] + owner.additionalAllowedRoots
                            // 绕过模式（已确认）下项目授权根不再限制文件目标；
                            // 系统底线与凭据保护仍由 validate / 执行器判断。
                            let openBypass = composerSnapshot?.mode == .bypassPermission
                                && composerSnapshot?.bypassModeConfirmed == true
                            guard let target = BypassOpenScope.$isActive.withValue(openBypass, operation: {
                                roots.lazy.compactMap({ validate(raw, $0.path) }).first
                            }) else {
                                throw ToolExecutorError.pathViolation(raw)
                            }
                            // 子任务文件跟随父会话：已确认绕过 + 子任务写入开关（scope.filesOpen）时不限根。
                            if let scope = ChildToolWorkspaceScope.current, !(scope.filesOpen && openBypass) {
                                guard PolicyRuntimePathBoundary.isWithinRoots(path: target.path, roots: scope.writeRoots),
                                      !scope.deniedRoots.contains(where: { PolicyRuntimePathBoundary.foldedCandidate(target.path, isWithin: $0) }) else {
                                    throw ToolExecutorError.pathViolation(raw)
                                }
                            }
                            fileMutationLease = try await ToolFileMutationScope.acquireForApproval(
                                path: target, context: approvalPresentationContext)
                        } catch let error as ToolExecutorError {
                            // This branch only validates/locks; no executor or
                            // filesystem effect has started. Keep its refusal
                            // observable through the ordinary durable ledger.
                            rejectedFilePreflight = true
                            throw error
                        }
                    }
                    do {
                    try await ToolFileMutationLease.$current.withValue(fileMutationLease) {
                    try Task.checkCancellation()
                    guard await parentAuthorityCheck?() != false else { throw CancellationError() }
                    if let lease = fileMutationLease {
                        guard let raw = call.input["path"] as? String,
                              let physical = PolicyRuntimePathBoundary.canonicalPath(raw),
                              PolicyRuntimePathBoundary.foldedForPathComparison(physical) == lease.key else {
                            throw ToolExecutorError.pathViolation(call.input["path"] as? String ?? "")
                        }
                        // 同上：只有 scope.filesOpen 且当前快照是已确认绕过时才跳过子任务根限制。
                        if let scope = ChildToolWorkspaceScope.current,
                           !(scope.filesOpen && composerSnapshot?.mode == .bypassPermission
                             && composerSnapshot?.bypassModeConfirmed == true) {
                            guard (scope.readRoots + scope.writeRoots).allSatisfy({ PolicyRuntimePathBoundary.canonicalPath($0) == $0 }),
                                  PolicyRuntimePathBoundary.isWithinRoots(path: physical, roots: scope.writeRoots),
                                  !scope.deniedRoots.contains(where: { PolicyRuntimePathBoundary.foldedCandidate(physical, isWithin: $0) }) else {
                                throw ToolExecutorError.pathViolation(raw)
                            }
                        }
                    }
                    let preparation: ChildDeletionReviewPreparation?
                    let preparationGate = composerExecutor?.approvalGate ?? approvalGate
                    let preparationDemand = preparationGate?.delegate as? any ChildDeletionReviewPreparationDemand
                    if call.name == "file_delete", preparationDemand?.requiresDeletionPreparation == true,
                       let preparationGate, preparationGate.policy(for: call.name) != .deny,
                       preparationGate.policy(for: call.name) != .never,
                       childToolRuntimeBinding != nil, let approvalPresentationContext,
                       let context = AgentExecutionContext.current,
                       let owner = ((composerExecutor?.base ?? toolExecutor) as? any BuiltinOwnerBoundToolExecutor)?.currentBuiltinOwner,
                       let path = call.input["path"] as? String {
                        do {
                            preparation = try await owner.prepareChildDeletionReview(path: path,
                                context: context, approvalContext: approvalPresentationContext)
                        } catch is CancellationError { throw CancellationError() }
                        catch { preparation = nil } // Original human delegate; never fake recoverability.
                    } else { preparation = nil }
                    try await ChildDeletionReviewPreparationContext.$current.withValue(preparation) {
                    // E1: an absent gate is not approval. High-risk and
                    // unclassified calls fail closed before the executor;
                    // catalogued low-risk calls may remain autonomous.
                    var approvedFilePreview: ApprovalFilePreview?
                    if composerExecutor != nil {
                        // The executor owns the full Policy -> Approval ->
                        // Executor sequence and revalidates after the prompt.
                    } else if var gate = approvalGate {
                        if call.name == "shell_execute", let command = call.input["command"] as? String,
                           gate.terminalPolicySnapshot.classify(command: command) == .unknown,
                           gate.policy(for: call.name) != .deny, gate.policy(for: call.name) != .never {
                            gate.policyByTool[call.name] = .alwaysAsk
                            let originalSink = gate.onApprovalReceipt
                            gate.onApprovalReceipt = { receipt in
                                try await originalSink?(receipt)
                                shellApprovalCapture?.record(receipt)
                            }
                        }
                        let decision = try await ApprovalPresentationContext.$current.withValue(
                            approvalPresentationContext
                        ) {
                            try await gate.gateAgentCall(
                                tool: call.name,
                                input: call.input,
                                callID: call.id,
                                executionIdentity: executionIdentity,
                                attemptID: toolAttemptID,
                                attemptNumber: toolAttemptNumber,
                                childBoundary: childBoundary
                            )
                        }
                        approvedFilePreview = decision.filePreview
                    } else {
                        // A nil gate is never approval for an arbitrary
                        // executor. Only the canonical, low-risk, low-input
                        // catalog may remain autonomous; unknown, high-risk,
                        // and input-escalated calls fail closed.
                        let isCataloguedLowRisk =
                            ApprovalGate.defaultPolicies[call.name] == .autoApprove
                            && ApprovalGate.riskByTool[call.name] == .low
                            && ApprovalGate.inputRiskLevel(tool: call.name, input: call.input) == .low
                        guard isCataloguedLowRisk else {
                            throw ToolExecutorError.approvalRequired(call.name)
                        }
                    }
                    // F3 取消闭环：gate 通过后、execute 前复查取消状态。
                    // 场景：审批弹窗挂起期间用户按了停止 —— stopStreaming 一方面经
                    // dismissPending 把挂起的 continuation 按拒绝恢复（gate 抛 denied，
                    // 下方 catch 兜成 is_error 结果）；另一方面这里是竞态兜底：gate
                    // 已返回 approved 但中断信号随后才到（或 Task 被取消），没有这道
                    // 复查工具仍会执行。InterruptedError/CancellationError 不落入
                    // 工具错误 catch —— 直接上抛终止整轮（取消不应再回传结果烧 token）。
                    if let turn, await turn.isCancelled() {
                        throw InterruptedError()
                    }
                    if let childBoundary {
                        try await checkChildBoundary(childBoundary)
                    }
                    try Task.checkCancellation()
                    let composerAuthorization: ComposerExecutionAuthorization?
                    if let composerExecutor {
                        composerAuthorization = try await ApprovalPresentationContext.$current.withValue(
                            approvalPresentationContext
                        ) {
                            try await composerExecutor.authorizeExecution(
                                callID: call.id,
                                name: call.name,
                                input: call.input,
                                bypassApprovalGate: composerSnapshot?.mode == .bypassPermission
                                    && composerSnapshot?.bypassModeConfirmed == true
                            )
                        }
                    } else {
                        composerAuthorization = nil
                    }
                    // Authorization may have reached a real pending prompt,
                    // yet the session-read guard, durable mint or cancellation
                    // check can still stop this call before the authorization
                    // is consumed. Close only that original pending fact on
                    // every error; the actor ignores an already used grant.
                    do {
                    var composerDryRun = false
                    if let composerAuthorization {
                        composerDryRun = await composerAuthorization.isDryRun
                    }
                    if let executionIdentity,
                       executionIdentity.attempt <= 0 {
                        throw AgentLoopError.invalidToolExecutionAttempt
                    }
                    // session_read authority exists only after the approval card
                    // was allowed: issued here for this one call's target and
                    // scope; the executor validates it on dispatch.
                    let sessionReadAuthorization: CrossSessionReadAuthorization?
                    if call.name == SessionReadTool.toolName {
                        guard let currentConversationID, let turn else {
                            throw CrossSessionReadAuthorizationError.capabilityRequired
                        }
                        guard let scopeValue = call.input["scope"] as? String,
                              let readScope = SessionReadScope(rawValue: scopeValue) else {
                            throw ToolExecutorError.invalidParameter("scope")
                        }
                        // list/export act on the whole session list / the current
                        // session, so they need no target session_id.
                        let sessionID: String
                        if readScope.isSessionLevel {
                            sessionID = currentConversationID
                        } else {
                            guard let rawID = call.input["session_id"] as? String,
                                  !rawID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                                throw ToolExecutorError.missingParameter("session_id")
                            }
                            sessionID = rawID
                        }
                        sessionReadAuthorization = await turn.issueSessionReadAuthorization(
                            currentConversationID: currentConversationID,
                            authorizedSessionID: sessionID.trimmingCharacters(in: .whitespacesAndNewlines),
                            scope: readScope
                        )
                    } else {
                        sessionReadAuthorization = nil
                    }
                    // A plan dry-run returns explicit feedback without handing
                    // an effect to the base executor. Only actual execution
                    // attempts mint a durable tool fact or increment the count.
                    if !composerDryRun {
                        guard let ledger = toolExecutionFactLedger else {
                            throw ToolExecutionFactLedgerError.durableAuthorityRequired
                        }
                        guard let toolAttemptID, toolAttemptNumber > 0 else {
                            throw ToolExecutionFactLedgerError.invalidAttemptIdentity
                        }
                        // Freeze the existing child producer identity into the same
                        // durable receipt, before dispatch. Never reconstruct it from
                        // a selected session or a later current task/attempt.
                        if let binding = childToolRuntimeBinding {
                            guard await binding.verifiedParentSessionID(
                                for: call.name, context: executionContext
                            ) == binding.parent.sessionID else {
                                throw ToolExecutionFactLedgerError.invalidCanonicalIdentity
                            }
                        }
                        let targetOrigin = try BuiltinToolExecutor.captureTargetTaskOrigin(
                            context: executionContext, executionIdentity: executionIdentity
                        )
                        receipt = try ledger.mint(
                            toolCallID: call.id,
                            toolName: call.name,
                            attemptID: toolAttemptID,
                            attemptNumber: toolAttemptNumber,
                            executionIdentity: executionIdentity,
                            parentRuntimeIdentity: childToolRuntimeBinding?.parent,
                            childTranscriptLocator: childToolRuntimeBinding?.locator,
                            targetTaskBinding: targetOrigin?.binding, targetTaskSource: targetOrigin?.source
                        )
                        if ["file_write", "file_edit"].contains(call.name),
                           executionContext.taskArtifactProject != nil, let receipt {
                            _ = try BuiltinToolExecutor.captureChildTaskArtifactBinding(
                                context: executionContext, receipt: receipt)
                        }
                        if composerExecutor == nil, let fileMutationLease {
                            // Classic/direct calls have no Composer/Recording
                            // authorization borrower to attach this real mint.
                            // Existing full-identity attach is resource-only;
                            // Gate approval and builtin one-use claims remain.
                            guard let actualReceipt = receipt,
                                  fileMutationLease.attachReceipt(actualReceipt) else {
                                throw ToolExecutionFactLedgerError.receiptIdentityMismatch
                            }
                        }
                        // A real executor failure remains an attempted call.
                        toolCallsExecuted += 1
                        // Queued is observable only after the canonical
                        // receipt was durably minted. No model input or
                        // guessed approval state enters this phase.
                        if let compositeKey = receipt?.compositeKey,
                           let identity = receipt?.executionIdentity {
                            onToolExecutionPhase?(
                                ToolExecutionPhaseFact(
                                    compositeKey: compositeKey,
                                    executionIdentity: identity,
                                    toolName: call.name,
                                    phase: .queued,
                                    occurredAt: Date()
                                )
                            )
                        }
                    }
                    if concurrentRead, !composerDryRun, let receipt, let routedOwner {
                        let frozenInput = try ComposerToolInput(call.input)
                        let admittedReceipt = receipt
                        let admittedAuthorization = composerAuthorization
                        let readState = ReadEffectState()
                        preparedReads.append(PreparedRead(state: readState, call: call, receipt: admittedReceipt,
                            authorization: admittedAuthorization, effect: { readOwnership, remainingTimeout in
                                try await performPreparedRead(call: call, input: frozenInput,
                                    receipt: admittedReceipt, authorization: admittedAuthorization,
                                    state: readState, executor: toolExecutor, composer: composerExecutor, owner: routedOwner,
                                    turn: turn, context: executionContext, ownership: readOwnership,
                                    parentAuthorityCheck: parentAuthorityCheck, timeout: remainingTimeout)
                            }))
                        return
                    }
                    try await drainPreparedReads()
                    let orchestrationCapture: OrchestrationTerminalCapture? =
                        call.name == OrchestrationToolExecutor.toolName
                        ? OrchestrationTerminalCapture() : nil
                    try Task.checkCancellation()
                    let filePreview = approvedFilePreview
                    let legacyShellReceipt = shellApprovalCapture?.load()
                    // Clarification owns its explicit opt-in wait policy; the
                    // ordinary per-tool watchdog must not silently answer it.
                    let invocationTimeout = toolTimeout(for: call.name)
                    let browserObservation: BrowserAutomaticExecutionCapture? = {
                        guard BrowserSideEffectPolicy.browserToolNames.contains(call.name.lowercased()),
                              let receipt, let ledger = toolExecutionFactLedger,
                              let frozen = try? ComposerToolInput(call.input) else { return nil }
                        return BrowserAutomaticExecutionCapture(receipt: receipt, ledger: ledger,
                            identity: BrowserSideEffectExecutionIdentity(callID: call.id, inputDigest: frozen.digest))
                    }()
                    defer { browserObservation?.discard() }
                    // 前台命令的实时输出只给界面，不进工具结果。
                    let liveShellSink: ShellLiveOutput.Sink? = {
                        guard call.name == "shell_execute", let handler = onToolLiveOutput else { return nil }
                        let callID = call.id
                        return { @Sendable text in handler(callID, text) }
                    }()
                    let output: String = try await BrowserSideEffectCallContext.$executionObservation.withValue(browserObservation) {
                    try await ApprovalFilePreviewContext.$current.withValue(filePreview) {
                    try await ShellLiveOutput.$sink.withValue(liveShellSink) {
                    let output: String
                    if let composerExecutor {
                        guard let composerAuthorization else {
                            throw ComposerAuthorizationError.authorizationBindingMismatch
                        }
                        if call.name == SessionReadTool.toolName {
                            guard let sessionReadAuthorization,
                                  let currentConversationID,
                                  let turn else {
                                throw CrossSessionReadAuthorizationError.capabilityRequired
                            }
                            let context = SessionReadExecutionContext(
                                currentConversationID: currentConversationID,
                                turnID: turn.turnID,
                                isStopped: await turn.isCancelled()
                            )
                            let frozenInput = try ComposerToolInput(call.input)
                            let callID = call.id
                            let auth = composerAuthorization
                            let readAuth = sessionReadAuthorization
                            dispatchStartedAtNanoseconds = beginToolDispatch(
                                receipt, toolName: call.name
                            )
                            executorDispatchStarted = true
                            output = try await executeToolWithTimeout(
                                name: call.name,
                                timeout: invocationTimeout,
                                input: call.input, executor: toolExecutor,
                                childTimeout: childBoundary?.remainingTimeout(),
                                receipt: receipt,
                                ledger: toolExecutionFactLedger,
                                ownership: toolOwnership
                            ) {
                                try await composerExecutor.execute(
                                    preauthorization: auth,
                                    callID: callID,
                                    input: frozenInput.toolExecutionDictionary,
                                    authorization: readAuth,
                                    context: context,
                                    now: Date()
                                )
                            }
                        } else {
                            let frozenInput = try ComposerToolInput(call.input)
                            let callID = call.id
                            let toolName = call.name
                            let auth = composerAuthorization
                            dispatchStartedAtNanoseconds = beginToolDispatch(
                                receipt, toolName: call.name
                            )
                            executorDispatchStarted = true
                            output = try await OrchestrationTerminalContext.$current.withValue(
                                orchestrationCapture
                            ) {
                                try await executeToolWithTimeout(
                                    name: call.name,
                                    timeout: invocationTimeout,
                                    input: call.input, executor: toolExecutor,
                                    childTimeout: childBoundary?.remainingTimeout(),
                                    receipt: receipt,
                                    ledger: toolExecutionFactLedger,
                                    ownership: toolOwnership
                                ) {
                                    try await composerExecutor.execute(
                                        preauthorization: auth,
                                        callID: callID,
                                        name: toolName,
                                        input: frozenInput.toolExecutionDictionary
                                    )
                                }
                            }
                        }
                    } else if call.name == SessionReadTool.toolName {
                        guard let capabilityExecutor = toolExecutor as? any SessionReadCapabilityAwareToolExecutor,
                              let sessionReadAuthorization,
                              let currentConversationID,
                              let turn else {
                            throw CrossSessionReadAuthorizationError.capabilityRequired
                        }
                        let context = SessionReadExecutionContext(
                            currentConversationID: currentConversationID,
                            turnID: turn.turnID,
                            isStopped: await turn.isCancelled()
                        )
                        let frozenInput = try ComposerToolInput(call.input)
                        let readAuth = sessionReadAuthorization
                        dispatchStartedAtNanoseconds = beginToolDispatch(
                            receipt, toolName: call.name
                        )
                        executorDispatchStarted = true
                        output = try await executeToolWithTimeout(
                            name: call.name,
                            timeout: invocationTimeout,
                            input: call.input, executor: toolExecutor,
                            childTimeout: childBoundary?.remainingTimeout(),
                            receipt: receipt,
                            ledger: toolExecutionFactLedger,
                            ownership: toolOwnership
                        ) {
                            try await capabilityExecutor.executeSessionRead(
                                input: frozenInput.toolExecutionDictionary,
                                authorization: readAuth,
                                context: context,
                                now: Date()
                            )
                        }
                    } else {
                        let frozenInput = try ComposerToolInput(call.input)
                        let callID = call.id
                        let toolName = call.name
                        let requiresBrowserApproval = BrowserSideEffectPolicy.inputRequiresApproval(
                            tool: toolName, input: call.input
                        )
                        dispatchStartedAtNanoseconds = beginToolDispatch(
                            receipt, toolName: call.name
                        )
                        executorDispatchStarted = true
                        output = try await OrchestrationTerminalContext.$current.withValue(
                            orchestrationCapture
                        ) {
                            try await executeToolWithTimeout(
                                name: call.name,
                                timeout: invocationTimeout,
                                input: call.input, executor: toolExecutor,
                                childTimeout: childBoundary?.remainingTimeout(),
                                receipt: receipt,
                                ledger: toolExecutionFactLedger,
                                ownership: toolOwnership
                            ) {
                                if requiresBrowserApproval {
                                    return try await BrowserSideEffectCallContext.$current.withValue(
                                        BrowserSideEffectExecutionIdentity(
                                            callID: callID,
                                            inputDigest: frozenInput.digest
                                        )
                                    ) {
                                        try await toolExecutor.execute(
                                            name: toolName, input: frozenInput.toolExecutionDictionary
                                        )
                                    }
                                }
                                return try await ApprovedShellCallScope.$currentLegacyReceipt.withValue(legacyShellReceipt) {
                                    try await toolExecutor.execute(
                                        name: toolName, input: frozenInput.toolExecutionDictionary
                                    )
                                }
                            }
                        }
                    }
                    return output
                    }
                    }
                    }
                    if let turn, await turn.isCancelled() {
                        throw InterruptedError()
                    }
                    if let childBoundary {
                        try await checkChildBoundary(childBoundary)
                    }
                    try Task.checkCancellation()
                    // BrowserTool returns a structured result even for a
                    // refusal. A returned string is not proof of success:
                    // decode only the canonical browser response, keep page
                    // data out of the durable fact, and mark denial or an
                    // invalid response as an error-class terminal result.
                    let browserEvidence = browserObservation?.takeAndFreeze()
                    // 截图成功时输出末尾带有图片标记行；先拆开再解码 JSON，
                    // 结果文字之后再把标记接回，让图片通道取得到图。
                    let browserSplit = ToolResultImageChannel.splitTrailingMarkers(output)
                    let browserTerminal = composerDryRun ? nil : Self.browserTerminal(
                        toolName: call.name,
                        input: call.input,
                        output: browserSplit.body,
                        automaticExecutionEvidence: browserEvidence, receipt: receipt,
                        inputDigest: try? ComposerToolInput(call.input).digest
                    )
                    // The summary is feedback, never authorization to settle
                    // a parent execution as succeeded. A missing observation
                    // also fails closed if a wrapper skipped the producer.
                    let orchestrationOutcome = await orchestrationCapture?.takeAndFreeze()
                    let orchestrationFailed = !composerDryRun
                        && orchestrationCapture != nil
                        && orchestrationOutcome?.allSucceeded != true
                    if let receipt, let ledger = toolExecutionFactLedger {
                        let detailedSummary = await toolOutputSummaryWithDetail(call: call, output: output)
                        try settleToolExecutionFact(
                            ledger,
                            receipt: receipt,
                            status: browserTerminal?.status ?? (orchestrationFailed ? .failed : .succeeded),
                            browserDetail: browserTerminal?.detail,
                            outputSummary: detailedSummary,
                            dispatchStartedAtNanoseconds: dispatchStartedAtNanoseconds
                        )
                    }
                    if executorDispatchStarted, !composerDryRun, !orchestrationFailed,
                       browserTerminal?.isError != true,
                       call.name == BL6SettingsToolApproval.catalogToolName {
                        successfulSettingsCatalogResults[resultParts.count] = call.id
                    }
                    resultParts.append([
                        "type": "tool_result",
                        "tool_use_id": call.id,
                        "content": browserTerminal.map { $0.feedback + browserSplit.markers }
                            ?? (orchestrationFailed && orchestrationOutcome?.allSucceeded == nil
                                ? "[ORCHESTRATION RESULT UNVERIFIED]" : output),
                        "is_error": composerDryRun || orchestrationFailed || (browserTerminal?.isError ?? false),
                    ])
                    if composerDryRun {
                        onToolNonExecution?(call.id, .dryRun)
                    }
                    } catch {
                        await composerAuthorization?.observeUnexecutedCancellation()
                        throw error
                    }
                    }
                    }
                    if let fileMutationLease { await ToolFileMutationScope.release(fileMutationLease) }
                    } catch {
                        if let fileMutationLease { await ToolFileMutationScope.release(fileMutationLease) }
                        throw error
                    }
                } catch let ledgerError as ToolExecutionFactLedgerError {
                    try await drainPreparedReads()
                    switch ledgerError {
                    case .duplicateToolCallID:
                        resultParts.append([
                            "type": "tool_result",
                            "tool_use_id": call.id,
                            "content": "[TOOL CALL BLOCKED] duplicate or late tool call identity",
                            "is_error": true,
                        ])
                    case .invalidAttemptIdentity, .invalidCanonicalIdentity:
                        throw AgentLoopError.invalidToolExecutionAttempt
                    default:
                        throw AgentLoopError.toolExecutionFactsUnavailable
                    }
                } catch is InterruptedError {
                    if let receipt, let ledger = toolExecutionFactLedger,
                       ledger.pendingFileWriteEvidence(for: receipt) != nil {
                        throw AgentLoopError.toolExecutionFactsUnavailable
                    }
                    if let receipt, let ledger = toolExecutionFactLedger {
                        try settleToolExecutionFact(
                            ledger,
                            receipt: receipt,
                            status: .cancelled,
                            dispatchStartedAtNanoseconds: dispatchStartedAtNanoseconds
                        )
                    }
                    throw InterruptedError()
                } catch let error where error is CancellationError || error is MCPElicitationUserCancelled {
                    if let receipt, let ledger = toolExecutionFactLedger,
                       ledger.pendingFileWriteEvidence(for: receipt) != nil {
                        throw AgentLoopError.toolExecutionFactsUnavailable
                    }
                    if let receipt, let ledger = toolExecutionFactLedger {
                        try settleToolExecutionFact(
                            ledger,
                            receipt: receipt,
                            status: .cancelled,
                            dispatchStartedAtNanoseconds: dispatchStartedAtNanoseconds
                        )
                    }
                    throw error
                } catch let error as ToolExecutorError {
                    try await drainPreparedReads()
                    if rejectedFilePreflight, receipt == nil {
                        // Record only a witnessed pre-dispatch refusal. This
                        // receipt cannot authorize an effect: execution remains
                        // on this error path and immediately settles failed.
                        guard let ledger = toolExecutionFactLedger else {
                            throw AgentLoopError.toolExecutionFactsUnavailable
                        }
                        guard let toolAttemptID, toolAttemptNumber > 0 else {
                            throw AgentLoopError.invalidToolExecutionAttempt
                        }
                        if let binding = childToolRuntimeBinding {
                            guard await binding.verifiedParentSessionID(
                                for: call.name, context: executionContext
                            ) == binding.parent.sessionID else {
                                throw AgentLoopError.invalidToolExecutionAttempt
                            }
                        }
                        let targetOrigin = try BuiltinToolExecutor.captureTargetTaskOrigin(
                            context: executionContext, executionIdentity: executionIdentity
                        )
                        receipt = try ledger.mint(
                            toolCallID: call.id, toolName: call.name,
                            attemptID: toolAttemptID, attemptNumber: toolAttemptNumber,
                            executionIdentity: executionIdentity,
                            parentRuntimeIdentity: childToolRuntimeBinding?.parent,
                            childTranscriptLocator: childToolRuntimeBinding?.locator,
                            targetTaskBinding: targetOrigin?.binding, targetTaskSource: targetOrigin?.source
                        )
                        if call.name == "file_write", let receipt { try ledger.prepareFileWrite(receipt) }
                        if let actualReceipt = receipt,
                           let key = actualReceipt.compositeKey,
                           let identity = actualReceipt.executionIdentity {
                            onToolExecutionPhase?(ToolExecutionPhaseFact(
                                compositeKey: key, executionIdentity: identity,
                                toolName: call.name, phase: .queued, occurredAt: Date()
                            ))
                        }
                    }
                    if let receipt, let ledger = toolExecutionFactLedger,
                       ledger.pendingFileWriteEvidence(for: receipt) != nil {
                        throw AgentLoopError.toolExecutionFactsUnavailable
                    }
                    if case .toolTimeout = error {
                        if let receipt, let ledger = toolExecutionFactLedger {
                            try settleToolExecutionFact(
                                ledger,
                                receipt: receipt,
                                status: .failed,
                                failureCategory: .timeout,
                                dispatchStartedAtNanoseconds: dispatchStartedAtNanoseconds
                            )
                        }
                        throw error
                    }
                    if let receipt, let ledger = toolExecutionFactLedger {
                        try settleToolExecutionFact(
                            ledger,
                            receipt: receipt,
                            status: .failed,
                            outputSummary: await failureOutputSummary(call: call, error: error),
                            failureCategory: { if case .shellTimeout = error { return .timeout }; return nil }(),
                            liveFailureReason: Self.fileReadFailureFeedback(
                                error, toolName: call.name, dispatchedAt: dispatchStartedAtNanoseconds,
                                verifiedBuiltinOwner: routedOwner != nil
                                    && ((composerExecutor?.base ?? toolExecutor) as? any BuiltinOwnerBoundToolExecutor)?.currentBuiltinOwner === routedOwner
                            ),
                            dispatchStartedAtNanoseconds: dispatchStartedAtNanoseconds
                        )
                    }
                    let message = "Error executing tool \(call.name): \(error.localizedDescription)"
                    resultParts.append([
                        "type": "tool_result",
                        "tool_use_id": call.id,
                        "content": message,
                        "is_error": true,
                    ])
                } catch let lifecycleError as AgentChildLifecycleError {
                    try await drainPreparedReads()
                    if let receipt, let ledger = toolExecutionFactLedger,
                       ledger.pendingFileWriteEvidence(for: receipt) != nil {
                        throw AgentLoopError.toolExecutionFactsUnavailable
                    }
                    switch lifecycleError {
                    case .cancelled:
                        if let receipt, let ledger = toolExecutionFactLedger {
                            try settleToolExecutionFact(
                                ledger,
                                receipt: receipt,
                                status: .cancelled,
                                dispatchStartedAtNanoseconds: dispatchStartedAtNanoseconds
                            )
                        }
                        throw InterruptedError()
                    case .deadlineExceeded:
                        if let receipt, let ledger = toolExecutionFactLedger {
                            try settleToolExecutionFact(
                                ledger,
                                receipt: receipt,
                                status: .failed,
                                failureCategory: .timeout,
                                dispatchStartedAtNanoseconds: dispatchStartedAtNanoseconds
                            )
                        }
                        throw AgentLoopError.timedOut(
                            childBoundary?.remainingTimeout() ?? 0
                        )
                    default:
                        if let receipt, let ledger = toolExecutionFactLedger {
                            try settleToolExecutionFact(
                                ledger,
                                receipt: receipt,
                                status: .failed,
                                dispatchStartedAtNanoseconds: dispatchStartedAtNanoseconds
                            )
                        }
                        let message = "Error executing tool \(call.name): \(lifecycleError.localizedDescription)"
                        resultParts.append([
                            "type": "tool_result",
                            "tool_use_id": call.id,
                            "content": message,
                            "is_error": true,
                        ])
                    }
                } catch let error as AgentLoopError {
                    // Loop-level guards, including invalid attempt identity,
                    // are fail-closed control flow rather than tool failures.
                    throw error
                } catch {
                    try await drainPreparedReads()
                    if let receipt, let ledger = toolExecutionFactLedger,
                       ledger.pendingFileWriteEvidence(for: receipt) != nil {
                        throw AgentLoopError.toolExecutionFactsUnavailable
                    }
                    if let receipt, let ledger = toolExecutionFactLedger {
                        try settleToolExecutionFact(
                            ledger,
                            receipt: receipt,
                            status: .failed,
                            outputSummary: await failureOutputSummary(call: call, error: error),
                            dispatchStartedAtNanoseconds: dispatchStartedAtNanoseconds
                        )
                    }
                    // This is an observed pre-dispatch authorization failure,
                    // not an inference from an absent receipt. Once dispatch
                    // began, even an error may have produced an uncertain effect.
                    if !executorDispatchStarted,
                       (error is ComposerAuthorizationError
                        || error is CrossSessionReadAuthorizationError) {
                        let category = (error as? ComposerAuthorizationError)?.blockCategory
                            ?? .sessionRead
                        onToolNonExecution?(call.id, .blockedByPolicy(category))
                    }
                    let message = "Error executing tool \(call.name): \(error.localizedDescription)"
                    resultParts.append([
                        "type": "tool_result",
                        "tool_use_id": call.id,
                        "content": message,
                        "is_error": true,
                    ])
                }
            }

            try await drainPreparedReads()
            } catch {
                do { try await abandonPreparedReads() }
                catch let cleanup {
                    throw AgentLoopError.toolExecutionFactSettlementFailed(
                        "read cohort cleanup: \(cleanup.localizedDescription)")
                }
                throw error
            }

            // 工具图片（file_read 读图片、MCP image 内容）走旁路：先取走标记再做脱敏与限长，
            // 只在模型声明支持图片输入且是原生工具调用时随本轮请求发送。
            var toolResultImages: [Int: [LLMMessage.ImageAttachment]] = [:]
            let modelAcceptsImages = provider.model.capabilities.supportedModalities.contains(.imageInput)
            for index in resultParts.indices {
                guard let content = resultParts[index]["content"] as? String else { continue }
                let extracted = ToolResultImageChannel.extract(from: content)
                guard extracted.text != content || !extracted.images.isEmpty else { continue }
                var text = extracted.text
                if extracted.droppedForLimit > 0 {
                    text += "\n[图片超过单次 \(ToolResultImageChannel.maxImagesPerResult) 张的上限，另有 \(extracted.droppedForLimit) 张未提供]"
                }
                if !extracted.images.isEmpty {
                    if isNative && modelAcceptsImages {
                        toolResultImages[index] = extracted.images
                    } else {
                        text += isNative
                            ? "\n[当前模型不支持图片输入，上述图片没有发送给你。]"
                            : "\n[当前工具调用方式不支持传图，上述图片没有发送给你。]"
                        // 看不了图的模型：用本地文字识别把图里的字交给它，并标明可能有误。
                        let recognized = await ToolResultImageChannel.recognizeText(in: extracted.images)
                        if !recognized.isEmpty {
                            text += "\n[以下是本地文字识别（OCR）从图片中识别出的文字，可能有误]\n" + recognized
                        }
                    }
                }
                resultParts[index]["content"] = text
            }

            // Apply the App's known-value protection to every success/refusal
            // body, including structured browser feedback and error text.
            // Facts and execution status above remain based on raw evidence.
            if let toolResultProjection {
                for index in resultParts.indices {
                    if let content = resultParts[index]["content"] as? String {
                        resultParts[index]["content"] = await toolResultProjection(content)
                    }
                }
            }

            // O-13: bound the final model-visible projection for every tool,
            // including errors and session reads. Durable effect facts above
            // retain their original authority; only the returned text is capped.
            for index in resultParts.indices {
                if let content = resultParts[index]["content"] as? String {
                    let actualCallID = resultParts[index]["tool_use_id"] as? String
                    let trustedCatalog = actualCallID.map { successfulSettingsCatalogResults[index] == $0 } == true
                        && (resultParts[index]["is_error"] as? Bool) == false
                    let matchingCalls = calls.filter { $0.id == actualCallID }
                    let successfulFileRead = matchingCalls.count == 1 && matchingCalls.first?.name == "file_read"
                        && (resultParts[index]["is_error"] as? Bool) == false
                        && ((composerExecutor?.base ?? toolExecutor) as? any BuiltinOwnerBoundToolExecutor)?.currentBuiltinOwner != nil
                    resultParts[index]["content"] = trustedCatalog
                        ? MCPOutputLimiter.projectSettingsCatalog(content)
                        : (successfulFileRead ? MCPOutputLimiter.projectFileRead(content) : MCPOutputLimiter.project(content))
                }
            }

            // Feed back results. Native tool calls use OpenAI `tool` role
            // messages (one per call, each tagged with its tool_call_id);
            // text-envelope calls use the legacy Anthropic-style `tool_result`
            // user message aggregating all calls.
            if isNative {
                for (index, call) in calls.enumerated() {
                    let part = index < resultParts.count ? resultParts[index] : [:]
                    let content = (part["content"] as? String) ?? ""
                    var toolMessage = LLMMessage(role: .tool, content: content, toolCallID: call.id)
                    // 图片只随请求发送：持久化的消息不带图片；更早的工具图片超出保留预算后由 pruneHistoryImages 摘掉。
                    let persistedMessage = toolMessage
                    toolMessage.images = toolResultImages[index] ?? []
                    messages.append(toolMessage)
                    try onMessage?(admittedMessageIndex, persistedMessage)
                    admittedMessageIndex += 1
                }
                // 图片只保留最近的若干张（按张数和总字节预算），更早的从请求里摘掉；
                // 不再每轮全部清空，模型能继续参照前几轮看过的图。
                ToolResultImageChannel.pruneHistoryImages(&messages)
            } else {
                let payload = try JSONSerialization.data(withJSONObject: resultParts)
                let jsonString = String(data: payload, encoding: .utf8) ?? "[]"
                let toolResultMessage = LLMMessage(
                    role: .user, content: jsonString,
                    legacyToolOutputSummary: jsonString.count > ProductRedactionPolicy.maxTranscriptFieldLength
                        ? ToolOutputSummary.capture(toolName: "", output: jsonString) : nil
                )
                messages.append(toolResultMessage)
                try onMessage?(admittedMessageIndex, toolResultMessage)
                admittedMessageIndex += 1
            }
            todoReminder.recordRound(toolNames: calls.map(\.name), messages: messages)
            // 同一个工具连续失败到上限就结束本回合（结果已写回对话），交给用户处理，
            // 不让模型在不限循环次数下反复重试同一种失败（用户 11/20 会话 893B52D5）。
            // 只数真正执行过、执行事实记为失败的调用；被权限拦下、没执行的不算（那归审批与重复调用检测管）。
            let failedFactCallIDs: Set<String>? = toolExecutionFactLedger.map { ledger in
                let ids = Set(calls.map(\.id))
                return Set(ledger.facts.filter { ids.contains($0.toolCallID) && $0.status == .failed }.map(\.toolCallID))
            }
            for (index, call) in calls.enumerated() {
                let isError = index < resultParts.count && (resultParts[index]["is_error"] as? Bool) == true
                let failed = isError && (failedFactCallIDs?.contains(call.id) ?? false)
                if let stop = repeatedToolFailures.record(tool: call.name, failed: failed) {
                    throw AgentLoopError.repeatedToolFailure(tool: stop.tool, count: stop.count)
                }
            }
        }

            throw AgentLoopError.maxIterationsExceeded(maxIterations)
            } catch {
                if let taskStore, let parentRuntimeIdentity, let executionIdentity,
                   error as? AgentLoopError != .parentTerminalPersistenceFailed {
                    let terminalOutcome: AgentParentTurnTerminalFact.Outcome
                    if error is InterruptedError || error is CancellationError {
                        terminalOutcome = .cancelled
                    } else if case AgentLoopError.timedOut = error {
                        terminalOutcome = .timedOut
                    } else {
                        terminalOutcome = .failed
                    }
                    do {
                        _ = try taskStore.recordParentTurnTerminal(
                            parent: parentRuntimeIdentity, execution: executionIdentity,
                            outcome: terminalOutcome)
                    } catch {
                        throw AgentLoopError.parentTerminalPersistenceFailed
                    }
                }
                onFailure?(Self.withoutToolImages(messages))
                throw error
            }
            }
            }
        } catch {
            await turn?.finish()
            throw error
        }
    }

    /// 工具图片只随当轮请求发送，交给调用方持久化的历史里不带图片字节。
    static func withoutToolImages(_ messages: [LLMMessage]) -> [LLMMessage] {
        messages.map { message in
            guard message.role == .tool, !message.images.isEmpty else { return message }
            var stripped = message
            stripped.images = []
            return stripped
        }
    }

    // MARK: Execution guards

    private func makeApprovalPresentationContext(
        executionIdentity: AgentExecutionIdentity?,
        attemptID: String?,
        attemptNumber: Int,
        toolCallID: String,
        toolName: String
    ) -> ApprovalPresentationContext? {
        guard let executionIdentity, executionIdentity.isValid,
              let attemptID,
              attemptNumber == executionIdentity.attempt else { return nil }
        let key = ToolExecutionCompositeKey(
            sessionID: executionIdentity.turn.sessionID,
            turnID: executionIdentity.turn.turnID,
            messageID: executionIdentity.turn.messageID,
            operationID: executionIdentity.operationID,
            attemptID: attemptID,
            attemptNumber: attemptNumber,
            toolCallID: toolCallID
        )
        guard key.isValid else { return nil }
        return ApprovalPresentationContext(
            compositeKey: key,
            executionIdentity: executionIdentity,
            toolName: toolName,
            eventSink: onApprovalLifecycle ?? { _ in }
        )
    }

    private func validateSuppliedExecutionIdentity(
        _ identity: AgentExecutionIdentity?,
        currentConversationID: String?,
        parentIdentitySeed: ParentRuntimeIdentitySeed?,
        composerSnapshot: ComposerSubmissionSnapshot?,
        turn: TurnController.TurnHandle? = nil
    ) throws {
        guard let identity else { return }
        guard identity.isValid else {
            throw AgentLoopError.executionIdentityMismatch
        }

        if let childBoundary {
            let childIdentity = childBoundary.identity
            guard let generationID = childIdentity.generationID else {
                throw AgentLoopError.executionIdentityMismatch
            }
            guard identity.attempt > 0,
                  identity.turn.sessionID == childIdentity.childSessionID,
                  identity.turn.turnID == childIdentity.cancelGeneration,
                  identity.turn.messageID == childIdentity.childTaskID,
                  identity.operationID == generationID else {
                throw AgentLoopError.executionIdentityMismatch
            }
        } else {
            let expectedConversationID = currentConversationID ?? parentIdentitySeed?.conversationID
            if let expectedConversationID,
               identity.turn.sessionID != expectedConversationID {
                throw AgentLoopError.executionIdentityMismatch
            }
            if let composerSnapshot {
                // Composer owns the durable chat turn identity. A fresh local
                // TurnController handle is only a cancellation scope and may
                // start at 1 even when this is chat turn 8.
                guard identity.turn.sessionID == composerSnapshot.sessionID,
                      identity.turn.turnID == composerSnapshot.turnID,
                      identity.turn.messageID == composerSnapshot.messageID else {
                    throw AgentLoopError.executionIdentityMismatch
                }
            } else if let turn,
                      identity.turn.turnID != turn.turnID {
                throw AgentLoopError.executionIdentityMismatch
            }
        }
    }

    struct BrowserTerminal {
        let status: ToolExecutionStatus
        let detail: BrowserToolExecutionDetail?
        let feedback: String
        let isError: Bool

        static let invalid = BrowserTerminal(
            status: .failed,
            detail: nil,
            feedback: "[BROWSER RESULT INVALID]",
            isError: true
        )
    }

    /// Browser output is data from the executed tool, not a policy decision or
    /// an instruction. The accepted shapes mirror BrowserToolResponse's six
    /// actions; raw result/page text is never passed to the durable detail.
    static func browserTerminal(
        toolName: String,
        input: [String: Any],
        output: String,
        automaticExecutionEvidence: BrowserAutomaticExecutionEvidence? = nil,
        receipt: ToolExecutionReceipt? = nil, inputDigest: String? = nil
    ) -> BrowserTerminal? {
        guard toolName == BrowserTool.toolName
                || toolName == BrowserTool.legacyToolName else {
            return nil
        }
        guard let requestedAction = input["action"] as? String,
              let response = try? JSONDecoder().decode(
                BrowserToolResponse.self,
                from: Data(output.utf8)
              ),
              response.action == requestedAction,
              !response.scopeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .invalid
        }

        let status: ToolExecutionStatus
        let isError: Bool
        switch response.outcome {
        case "succeeded":
            guard response.action != "read",
                  response.result != nil,
                  response.untrustedPageContent == nil,
                  response.refusalReason == nil,
                  response.failureCode == nil else {
                return .invalid
            }
            status = .succeeded
            isError = false
        case "read":
            guard response.action == "read",
                  response.result == nil,
                  response.untrustedPageContent != nil,
                  response.refusalReason == nil,
                  response.failureCode == nil else {
                return .invalid
            }
            status = .succeeded
            isError = false
        case "denied":
            guard response.result == nil,
                  response.untrustedPageContent == nil,
                  let reason = response.refusalReason,
                  isCanonicalBrowserDenial(reason),
                  response.failureCode == nil else {
                return .invalid
            }
            status = .failed
            isError = true
        case "failed":
            // Only BrowserTool's executed empty-history back failure is a
            // bounded terminal fact. No page or arbitrary error text survives.
            guard response.action == "back",
                  response.failureCode == "cannot_go_back",
                  response.result == nil,
                  response.untrustedPageContent == nil,
                  response.refusalReason == nil else {
                return .invalid
            }
            status = .failed
            isError = true
        default:
            return .invalid
        }
        let automaticCategory = response.outcome == "succeeded"
            ? automaticExecutionEvidence?.category(matching: receipt, digest: inputDigest,
                action: response.action, scopeID: response.scopeID) : nil
        guard let detail = BrowserToolExecutionDetail(
            action: response.action,
            outcome: response.outcome,
            result: nil,
            refusalReason: response.refusalReason,
            untrustedPageContent: response.untrustedPageContent,
            failureCode: response.failureCode,
            automaticRuleCategory: automaticCategory
        ) else {
            return .invalid
        }
        return BrowserTerminal(
            status: status,
            detail: detail,
            feedback: response.outcome == "failed"
                ? "[BROWSER BACK FAILED] cannot_go_back"
                // 被拒时只在给模型的文本里追加固定的中文设置入口说明；
                // 结构化 detail 与规范码不变。
                : BrowserNavigationPolicy.modelFacingGuidance(forBrowserRefusalReason: response.refusalReason)
                    .map { output + "\n" + $0 } ?? output,
            isError: isError
        )
    }

    private static func isCanonicalBrowserDenial(_ reason: String) -> Bool {
        if reason == "write_authorization_required" || reason == "invalid_scope" {
            return true
        }
        let prefix = "navigation_denied:"
        guard reason.hasPrefix(prefix) else { return false }
        return BrowserNavigationPolicy.Denial(
            rawValue: String(reason.dropFirst(prefix.count))
        ) != nil
    }

    private func beginToolDispatch(
        _ receipt: ToolExecutionReceipt?,
        toolName: String
    ) -> UInt64? {
        guard let receipt,
              let compositeKey = receipt.compositeKey,
              let identity = receipt.executionIdentity else {
            return nil
        }
        onToolExecutionPhase?(
            ToolExecutionPhaseFact(
                compositeKey: compositeKey,
                executionIdentity: identity,
                toolName: toolName,
                phase: .running,
                occurredAt: Date()
            )
        )
        // The callback is outside the measured executor interval.
        return DispatchTime.now().uptimeNanoseconds
    }

    private final class ReadEffectState: @unchecked Sendable {
        private let lock = NSLock()
        private var entered = false
        private var closed = false
        func tryEnterEffect() -> Bool {
            lock.withLock {
                guard !closed, !entered else { return false }
                entered = true
                return true
            }
        }
        func closeIfNotEntered() -> Bool {
            lock.withLock {
                guard !entered, !closed else { return false }
                closed = true
                return true
            }
        }
    }

    private struct PreparedRead: Sendable {
        let state: ReadEffectState
        let call: ParsedToolCall
        let receipt: ToolExecutionReceipt
        let authorization: ComposerExecutionAuthorization?
        let effect: @Sendable (ToolExecutionOwnership, TimeInterval?) async throws -> String
    }

    private func performPreparedRead(
        call: ParsedToolCall, input: ComposerToolInput,
        receipt: ToolExecutionReceipt, authorization: ComposerExecutionAuthorization?,
        state: ReadEffectState, executor: any ToolExecutor, composer: ComposerPolicyEnforcedToolExecutor?,
        owner: BuiltinToolExecutor, turn: TurnController.TurnHandle?,
        context: AgentExecutionContextSnapshot, ownership: ToolExecutionOwnership,
        parentAuthorityCheck: (@Sendable () async -> Bool)?, timeout: TimeInterval?
    ) async throws -> String {
        guard let ledger = toolExecutionFactLedger else { throw AgentLoopError.toolExecutionFactsUnavailable }
        guard state.tryEnterEffect() else { throw CancellationError() }
        let effectEnteredAt = DispatchTime.now().uptimeNanoseconds
        var dispatchedAt: UInt64?
        do {
            try Task.checkCancellation()
            if let turn, await turn.isCancelled() { throw InterruptedError() }
            guard await parentAuthorityCheck?() != false else { throw CancellationError() }
            if let childBoundary { try await checkChildBoundary(childBoundary) }
            let routed = composer?.base ?? executor
            guard (routed as? any BuiltinOwnerBoundToolExecutor)?.currentBuiltinOwner === owner else {
                throw ToolExecutorError.resourceScopeInvalid
            }
            if let binding = childToolRuntimeBinding {
                guard await binding.verifiedParentSessionID(for: call.name, context: context) == binding.parent.sessionID else {
                    throw ToolExecutionFactLedgerError.invalidCanonicalIdentity
                }
            }
            try Task.checkCancellation()
            let now = DispatchTime.now().uptimeNanoseconds
            let spent = now >= effectEnteredAt ? Double(now - effectEnteredAt) / 1_000_000_000 : 0
            let remaining = timeout.map { max(0, $0 - spent) }
            if let remaining, remaining <= 0 { throw ToolExecutorError.toolTimeout("Read cohort expired before dispatch") }
            dispatchedAt = beginToolDispatch(receipt, toolName: call.name)
            let output = try await executeToolWithTimeout(name: call.name, timeout: remaining,
                input: call.input, executor: executor, childTimeout: childBoundary?.remainingTimeout(),
                receipt: receipt, ledger: ledger, ownership: ownership) {
                // Keep the original Composer consume/revalidate boundary and
                // the original concrete-owner forwarding chain for every call.
                if let composer {
                    guard let authorization else { throw ComposerAuthorizationError.authorizationBindingMismatch }
                    return try await composer.execute(preauthorization: authorization,
                        callID: call.id, name: call.name, input: input.toolExecutionDictionary)
                }
                return try await executeThroughBoundBuiltinOwner(executor, owner: owner,
                    name: call.name, input: input.toolExecutionDictionary)
            }
            if let turn, await turn.isCancelled() { throw InterruptedError() }
            if let childBoundary { try await checkChildBoundary(childBoundary) }
            try Task.checkCancellation()
            let detailedSummary = await toolOutputSummaryWithDetail(call: call, output: output)
            try settleToolExecutionFact(ledger, receipt: receipt, status: .succeeded,
                outputSummary: detailedSummary,
                dispatchStartedAtNanoseconds: dispatchedAt)
            return output
        } catch {
            await authorization?.observeUnexecutedCancellation()
            let cancelled = error is CancellationError || error is InterruptedError
                || (error as? AgentChildLifecycleError) == .cancelled
            let timedOut = (error as? AgentChildLifecycleError) == .deadlineExceeded
                || { if case ToolExecutorError.toolTimeout = error { return true }; return false }()
            if ledger.pendingReceipts.contains(where: { $0.receiptID == receipt.receiptID }) {
                try settleToolExecutionFact(ledger, receipt: receipt, status: cancelled ? .cancelled : .failed,
                    outputSummary: cancelled ? nil : await failureOutputSummary(call: call, error: error),
                    failureCategory: timedOut ? .timeout : nil,
                    liveFailureReason: cancelled ? nil : Self.fileReadFailureFeedback(
                        error, toolName: call.name, dispatchedAt: dispatchedAt, verifiedBuiltinOwner: true
                    ), dispatchStartedAtNanoseconds: dispatchedAt)
            }
            if (error as? AgentChildLifecycleError) == .cancelled { throw InterruptedError() }
            if (error as? AgentChildLifecycleError) == .deadlineExceeded {
                throw AgentLoopError.timedOut(childBoundary?.remainingTimeout() ?? 0)
            }
            throw error
        }
    }

    private static func fileReadFailureFeedback(
        _ error: Error, toolName: String, dispatchedAt: UInt64?, verifiedBuiltinOwner: Bool
    ) -> ToolExecutionLiveFailureFeedback.Reason? {
        guard verifiedBuiltinOwner, toolName == "file_read", dispatchedAt != nil,
              let failure = error as? ToolExecutorError,
              case .permissionDenied = failure else { return nil }
        return .builtinFileReadPermissionDenied
    }

    private func settleToolExecutionFact(
        _ ledger: ToolExecutionFactLedger,
        receipt: ToolExecutionReceipt,
        status: ToolExecutionStatus,
        browserDetail: BrowserToolExecutionDetail? = nil,
        outputSummary: ToolOutputSummary? = nil,
        failureCategory: ToolExecutionFailureCategory? = nil,
        liveFailureReason: ToolExecutionLiveFailureFeedback.Reason? = nil,
        dispatchStartedAtNanoseconds: UInt64? = nil
    ) throws {
        let elapsedMilliseconds: Int?
        if let start = dispatchStartedAtNanoseconds {
            let end = DispatchTime.now().uptimeNanoseconds
            elapsedMilliseconds = Int(min(
                end >= start ? (end - start) / 1_000_000 : 0,
                UInt64(Int.max)
            ))
        } else {
            elapsedMilliseconds = nil
        }
        do {
            _ = try ledger.settle(
                receipt,
                status: status,
                browserDetail: browserDetail,
                outputSummary: outputSummary,
                elapsedMilliseconds: elapsedMilliseconds,
                failureCategory: failureCategory,
                liveFailureReason: liveFailureReason
            )
        } catch let error as ToolExecutionFactLedgerError {
            throw AgentLoopError.toolExecutionFactSettlementFailed(
                String(describing: error)
            )
        } catch {
            throw AgentLoopError.toolExecutionFactSettlementFailed(
                error.localizedDescription
            )
        }
    }

    private func factsForOutcome(
        executionIdentity: AgentExecutionIdentity?,
        composerSnapshot: ComposerSubmissionSnapshot?
    ) -> [ToolExecutionFact] {
        guard let executionIdentity,
              let attemptID = AgentToolExecutionAttemptID.canonical(
                  executionIdentity: executionIdentity,
                  composerSnapshot: composerSnapshot,
                  childBoundary: childBoundary
              ),
              let ledger = toolExecutionFactLedger else {
            return []
        }
        return ledger.facts(
            executionIdentity: executionIdentity,
            attemptID: attemptID,
            attemptNumber: executionIdentity.attempt
        )
    }

    /// Compacts `messages` through the App-supplied canonical transition, or
    /// the local strict-verbatim path when none is installed. Shared by the
    /// `.autoCompact` budget policy and window admission. Refusals throw
    /// `AgentLoopError.compactionCheckpointUnavailable` with one of
    /// `compactionRefusalDetails`; every other failure is a real error.
    private func applyAutomaticCompaction(
        messages: [LLMMessage],
        currentConversationID: String?,
        turn: TurnController.TurnHandle?
    ) async throws -> [LLMMessage] {
        if let automaticCompaction {
            guard let currentConversationID,
                  !currentConversationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentLoopError.compactionCheckpointUnavailable("missing conversation identity")
            }
            let transition = try await automaticCompaction(
                currentConversationID, messages, compactor ?? Compactor()
            )
            if let turn, await turn.isCancelled() { throw InterruptedError() }
            try Task.checkCancellation()
            let checkpoint = transition.checkpoint
            let upperBound = checkpoint.compactedMessageRange.upperBound
            let projectionVerified: Bool
            if checkpoint.schemaVersion == CompactionCheckpoint.segmentedProjectionSchemaVersion
                || checkpoint.schemaVersion == CompactionCheckpoint.lossySummarySchemaVersion,
               let recent = checkpoint.projectionRecentCount,
               let facts = checkpoint.retentionFacts {
                let boundsHold = recent >= 0 && upperBound > 0
                    && upperBound <= transition.sourcePrefix.count
                    && recent == transition.sourcePrefix.count - upperBound
                let factsBound = facts.allSatisfy { fact in
                    fact.source.map {
                        $0.sessionID == checkpoint.sessionID
                            && $0.transcriptRevision == checkpoint.sourceTranscriptRevision
                            && $0.matchesTranscript(transition.sourcePrefix)
                    } ?? true
                }
                let factsLive = CompactionFactCapture.verifyStores(facts, taskStore: taskStore,
                    effectLedger: toolExecutionFactLedger)
                var verified = boundsHold && factsBound && factsLive
                if checkpoint.schemaVersion == CompactionCheckpoint.segmentedProjectionSchemaVersion {
                    verified = verified && checkpoint.projectionSpans.map {
                        Compactor.isSourceAnchoredProjection(
                            from: transition.sourcePrefix, to: checkpoint.replacementHistory,
                            spans: $0, keepRecentMessages: recent, requiredFacts: facts)
                    } == true
                } else {
                    // A model-written summary cannot be re-derived; the prefix
                    // digest below and the exact tail are its proof.
                    verified = verified
                        && Array(checkpoint.replacementHistory.suffix(recent))
                            == Array(transition.sourcePrefix.suffix(recent))
                }
                projectionVerified = verified
            } else {
                projectionVerified = false
            }
            guard checkpoint.sessionID == currentConversationID,
                  checkpoint.hasValidDigest, projectionVerified,
                  checkpoint.sourcePrefixDigest == CompactionCheckpoint.digestOfSourcePrefix(
                    Array(transition.sourcePrefix.prefix(upperBound))),
                  transition.messages == checkpoint.replacementHistory
                    + transition.liveSuffix + transition.runtimeSuffix,
                  messages.count >= transition.runtimeSuffix.count,
                  Array(messages.suffix(transition.runtimeSuffix.count)) == transition.runtimeSuffix,
                  Compactor.hasMaterialRequestReduction(
                    from: messages, to: transition.messages) else {
                throw AgentLoopError.compactionCheckpointUnavailable("invalid canonical transition")
            }
            return transition.messages
        } else {
            // No provider or inferred authorization facts are
            // supplied. The strict Compactor contract refuses
            // any text truncation or metadata loss.
            let sourceMessages = messages
            let compacted = try await (compactor ?? Compactor()).compact(
                messages: messages,
                safetyMode: .requireVerbatimText
            )
            if let turn, await turn.isCancelled() {
                throw InterruptedError()
            }
            try Task.checkCancellation()
            guard compacted.refusalReason == nil,
                  compacted.compactedCount > 0,
                  Compactor.hasMaterialRequestReduction(
                    from: sourceMessages, to: compacted.messages
                  ) else {
                throw AgentLoopError.compactionCheckpointUnavailable(
                    "unverified context would be lost"
                )
            }
            if let sink = compactionCheckpointSink {
                guard let currentConversationID,
                      !currentConversationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    throw AgentLoopError.compactionCheckpointUnavailable(
                        "missing conversation identity"
                    )
                }
                // Do not mutate the local history until the
                // durable sink succeeds.  Failure/cancel thus
                // leaves resumeMessages on the pre-compaction
                // transcript instead of creating a fake pass.
                guard try await sink(
                    currentConversationID,
                    sourceMessages,
                    compacted
                ) != nil else {
                    throw AgentLoopError.compactionCheckpointUnavailable(
                        "durable checkpoint not produced"
                    )
                }
            }
            return compacted.messages
        }
    }

    static let compactionRefusalDetails: Set<String> = [
        "no verified request reduction", "unverified context would be lost",
    ]

    /// C3-05: failures of an automatic compaction that must not fail a request which can still
    /// be sent below 95% of the window: the summary request's provider errors (a cancellation
    /// is not one) and a checkpoint that did not pass validation (for example too many retained
    /// facts). Conflicts, cancellation and recovery-required storage errors keep propagating.
    public static func isRecoverableAutomaticCompactionFailure(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let provider = error as? LLMError {
            switch provider {
            case .cancelled: return false
            case .networkError(let underlying): return (underlying as? URLError)?.code != .cancelled
            default: return true
            }
        }
        if case .invalidCompactionCheckpoint? = error as? SessionStoreError { return true }
        return false
    }

    /// nil = the compactor refused, or the attempt failed in a recoverable way (the admission
    /// above still blocks at >= 95%); conflicts and cancellation propagate.
    private func attemptContextCompaction(
        messages: [LLMMessage],
        currentConversationID: String?,
        turn: TurnController.TurnHandle?
    ) async throws -> [LLMMessage]? {
        do {
            return try await applyAutomaticCompaction(
                messages: messages, currentConversationID: currentConversationID, turn: turn)
        } catch AgentLoopError.compactionCheckpointUnavailable(let detail)
                    where Self.compactionRefusalDetails.contains(detail) {
            return nil
        } catch let failure where !Task.isCancelled && Self.isRecoverableAutomaticCompactionFailure(failure) {
            return nil
        }
    }

    private func sendProvider(
        provider: any LLMProvider,
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?,
        timeout: TimeInterval?,
        iteration: Int,
        turnHandle: TurnController.TurnHandle?,
        thinkingLevel: ThinkingLevel?
    ) async throws -> LLMResponse {
        // A display callback or explicit frozen thinking level uses the shared
        // assistant seam. nil with no callback retains the buffered path.
        if let streamingProvider = provider as? any AssistantStreamingLLMProvider,
           onAssistantTextDelta != nil || thinkingLevel != nil {
            // A child without display deltas still consumes the same completed
            // response and budget/timeout path when an explicit level is frozen.
            let handler: AssistantTextDeltaHandler = onAssistantTextDelta ?? { _, _ in }
            return try await sendProviderStreaming(
                provider: streamingProvider,
                handler: handler,
                iteration: iteration,
                messages: messages,
                systemPrompt: systemPrompt,
                tools: tools,
                maxTokens: maxTokens,
                temperature: temperature,
                timeout: timeout,
                turnHandle: turnHandle,
                thinkingLevel: thinkingLevel
            )
        }
        guard let timeout, timeout > 0 else {
            return try await provider.sendMessage(
                messages: messages,
                systemPrompt: systemPrompt,
                tools: tools,
                maxTokens: maxTokens,
                temperature: temperature
            )
        }

        final class ProviderBox: @unchecked Sendable {
            let provider: any LLMProvider
            init(_ provider: any LLMProvider) { self.provider = provider }
        }
        let box = ProviderBox(provider)
        let race = ProviderTimeoutRace<LLMResponse>()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LLMResponse, Error>) in
                guard race.install(continuation) else { return }

                // Retain before spawning: cancellation may return the caller
                // before this task even enters the provider implementation.
                let finishProviderOperation = ChildLaunchPermitLifetime.current?.retainOperation()
                let providerTask = Task<Void, Never> {
                    defer { finishProviderOperation?() }
                    do {
                        let response = try await box.provider.sendMessage(
                            messages: messages,
                            systemPrompt: systemPrompt,
                            tools: tools,
                            maxTokens: maxTokens,
                            temperature: temperature
                        )
                        race.finish(.success(response))
                    } catch {
                        race.finish(.failure(error))
                    }
                }
                // Use a GCD wall-clock timer for the deadline. A Swift task
                // can be delayed behind a saturated cooperative executor,
                // which would let an uncooperative provider hold the caller
                // past its configured wall-clock bound.
                let watchdogTask = ProviderTimeoutWatchdog(after: timeout) {
                    race.finish(.failure(AgentLoopError.timedOut(timeout)))
                }
                race.setCancelTasks {
                    providerTask.cancel()
                    watchdogTask.cancel()
                }
            }
        }, onCancel: {
            race.cancel()
        })
    }

    /// D-CHAT-03 streaming producer.
    ///
    /// Semantics parity with the buffered path:
    /// - same `ProviderTimeoutRace` + GCD wall-clock watchdog (the deadline
    ///   bounds the WHOLE provider call, acquisition through `completed`);
    /// - same prompt cancellation: `onCancel` resolves the race so the loop
    ///   returns `CancellationError` without waiting for the provider task;
    /// - budget leases stay in the iteration body (unchanged), settled from
    ///   the `completed` response's usage exactly like a buffered response;
    /// - `textDelta` events are forwarded to `handler` live, tagged with the
    ///   current iteration so the consumer can reconcile the final text.
    private func sendProviderStreaming(
        provider: any AssistantStreamingLLMProvider,
        handler: @escaping AssistantTextDeltaHandler,
        iteration: Int,
        messages: [LLMMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        temperature: Double?,
        timeout: TimeInterval?,
        turnHandle: TurnController.TurnHandle?,
        thinkingLevel: ThinkingLevel?
    ) async throws -> LLMResponse {
        final class StreamingProviderBox: @unchecked Sendable {
            let provider: any AssistantStreamingLLMProvider
            let handler: AssistantTextDeltaHandler
            let thinkingHandler: AssistantTextDeltaHandler?
            init(
                provider: any AssistantStreamingLLMProvider,
                handler: @escaping AssistantTextDeltaHandler,
                thinkingHandler: AssistantTextDeltaHandler? = nil
            ) {
                self.provider = provider
                self.handler = handler
                self.thinkingHandler = thinkingHandler
            }
        }
        let box = StreamingProviderBox(provider: provider, handler: handler,
                                       thinkingHandler: onAssistantThinkingDelta)
        let race = ProviderTimeoutRace<LLMResponse>()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LLMResponse, Error>) in
                guard race.install(continuation) else { return }

                // Retain before spawning: cancellation may return the caller
                // before this task even enters the provider implementation.
                let finishProviderOperation = ChildLaunchPermitLifetime.current?.retainOperation()
                let providerTask = Task<Void, Never> {
                    defer { finishProviderOperation?() }
                    do {
                        let events = try await box.provider.streamAssistantMessage(
                            messages: messages,
                            systemPrompt: systemPrompt,
                            tools: tools,
                            maxTokens: maxTokens,
                            temperature: temperature,
                            thinkingLevel: thinkingLevel
                        )
                        var accumulatedText = ""
                        var completedResponse: LLMResponse?
                        var iterator = events.makeAsyncIterator()
                        while let event = try await iterator.next() {
                            if Task.isCancelled {
                                race.finish(.failure(CancellationError()))
                                return
                            }
                            // The public controller can stop this exact turn
                            // without cancelling the provider task. Reject its
                            // next event before forwarding any live delta.
                            if let turnHandle, await turnHandle.isCancelled() {
                                race.finish(.failure(InterruptedError()))
                                return
                            }
                            switch event {
                            case .textDelta(let delta):
                                accumulatedText += delta
                                await box.handler(iteration, delta)
                            case .thinkingDelta(let delta):
                                await box.thinkingHandler?(iteration, delta)
                            case .completed(let response):
                                completedResponse = response
                            }
                        }
                        // 未给出 completed 的流按已累积文本收敛（usage 缺省），
                        // 空文本将由迭代体的 emptyResponse 卫口统一处理。
                        race.finish(.success(
                            completedResponse
                                ?? LLMResponse(
                                    text: accumulatedText,
                                    stopReason: nil,
                                    usage: nil
                                )
                        ))
                    } catch {
                        race.finish(.failure(error))
                    }
                }
                // Use a GCD wall-clock timer for the deadline. A Swift task
                // can be delayed behind a saturated cooperative executor,
                // which would let an uncooperative provider hold the caller
                // past its configured wall-clock bound.
                let boundedTimeout = timeout.flatMap { $0 > 0 ? $0 : nil }
                let watchdogTask: ProviderTimeoutWatchdog? = boundedTimeout.map { seconds in
                    ProviderTimeoutWatchdog(after: seconds) {
                        race.finish(.failure(AgentLoopError.timedOut(seconds)))
                    }
                }
                race.setCancelTasks {
                    providerTask.cancel()
                    watchdogTask?.cancel()
                }
            }
        }, onCancel: {
            race.cancel()
        })
    }

    private func checkChildBoundary(
        _ boundary: AgentChildBoundary
    ) async throws {
        do {
            try await boundary.check()
        } catch let error as AgentChildLifecycleError {
            switch error {
            case .cancelled:
                throw InterruptedError()
            case .deadlineExceeded:
                throw AgentLoopError.timedOut(
                    boundary.remainingTimeout() ?? 0
                )
            default:
                throw error
            }
        }
    }

    private static func validateToolCatalog(_ tools: [AgentToolDefinition]) throws {
        var seen = Set<String>()
        for tool in tools {
            let name = tool.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                throw AgentLoopError.invalidToolCatalog("tool name is empty")
            }
            guard seen.insert(name).inserted else {
                throw AgentLoopError.invalidToolCatalog("duplicate tool '\(name)'")
            }
            guard Set(tool.required).isSubset(of: Set(tool.parameters.keys)) else {
                throw AgentLoopError.invalidToolCatalog("required parameter is missing from '\(name)'")
            }
        }
    }

    // MARK: Tool-call envelope parsing

    /// A tool call decoded from a model response.
    /// (`[String: Any]` blocks automatic Sendable synthesis — same `@unchecked`
    /// convention as `AgentContentPart` in this module.)
    public struct ParsedToolCall: @unchecked Sendable {
        public let id: String
        public let name: String
        public let input: [String: Any]

        public init(id: String, name: String, input: [String: Any]) {
            self.id = id
            self.name = name
            self.input = input
        }
    }

    /// Parse the canonical tool-call envelope out of a response text.
    ///
    /// The plain-text `LLMProvider` protocol has no structured tool-call
    /// field, so tool calls travel inside a JSON envelope:
    ///
    ///     {"tool_calls": [{"id": "call_1", "name": "shell_execute",
    ///                      "input": {"command": "echo hi"}}]}
    ///
    /// Also tolerates a fenced ```json block around the envelope. Returns
    /// nil when the text is not a tool-call envelope (i.e. it is a normal
    /// assistant reply).
    public static func parseToolCalls(from text: String) -> [ParsedToolCall]? {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip a single ```json ... ``` fence if present.
        if candidate.hasPrefix("```") {
            var lines = candidate.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.first?.hasPrefix("```") == true { lines.removeFirst() }
            if lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") == true { lines.removeLast() }
            candidate = lines.joined(separator: "\n")
        }

        guard let data = candidate.data(using: .utf8),
              data.count <= ProviderToolCallBoundary.maximumEnvelopeBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let calls = object["tool_calls"] as? [[String: Any]] else {
            return nil
        }
        guard calls.count <= ProviderToolCallBoundary.maximumCalls else {
            return nil
        }

        let result = calls.compactMap { call -> ParsedToolCall? in
            guard let parsed = ProviderToolCallBoundary.parseTextEnvelopeCall(call) else { return nil }
            return ParsedToolCall(id: parsed.id, name: parsed.name, input: parsed.input)
        }
        guard Set(result.map(\.id)).count == result.count else { return nil }
        return result.isEmpty ? nil : result
    }
}

final class ProviderTimeoutRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var cancellationRequested = false
    private var continuation: CheckedContinuation<Value, Error>?
    private var cancelTasks: (@Sendable () -> Void)?

    func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        if cancellationRequested {
            completed = true
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func setCancelTasks(_ cancel: @escaping @Sendable () -> Void) {
        lock.lock()
        let cancelNow = completed
        if !cancelNow { cancelTasks = cancel }
        lock.unlock()
        if cancelNow { cancel() }
    }

    func cancel() {
        lock.lock()
        if continuation == nil && !completed {
            cancellationRequested = true
            lock.unlock()
            return
        }
        lock.unlock()
        finish(.failure(CancellationError()))
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let continuation = self.continuation
        self.continuation = nil
        let cancel = cancelTasks
        cancelTasks = nil
        lock.unlock()

        continuation?.resume(with: result)
        cancel?()
    }
}

final class ProviderTimeoutWatchdog: @unchecked Sendable {
    private let timer: DispatchSourceTimer

    init(after timeout: TimeInterval, operation: @escaping @Sendable () -> Void) {
        let queue = DispatchQueue(
            label: "com.miniscanvas.miniscore.provider-timeout",
            qos: .userInitiated
        )
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler(handler: operation)
        timer.resume()
    }

    func cancel() {
        timer.cancel()
    }
}

// MARK: - LLMMessage ↔ AgentContentPart conversion

public extension AgentMessage {
    /// Flatten this agent message into `LLMMessage`(s).
    ///
    /// - `.text` parts → plain messages with the message role.
    /// - `.toolUse` parts → assistant messages carrying the tool-use JSON
    ///   envelope (so the call survives round-trips).
    /// - `.toolResult` parts → user messages carrying the Anthropic-style
    ///   `tool_result` JSON envelope.
    /// - `.imageData` parts are dropped (no image channel on LLMMessage).
    func toLLMMessages() -> [LLMMessage] {
        var result: [LLMMessage] = []
        for part in parts {
            switch part {
            case .text(let text):
                result.append(LLMMessage(role: role == .user ? .user : .assistant, content: text))
            case .toolUse(let id, let name, let input):
                let envelope: [String: Any] = [
                    "type": "tool_use", "id": id, "name": name, "input": input,
                ]
                if let data = try? JSONSerialization.data(withJSONObject: envelope),
                   let json = String(data: data, encoding: .utf8) {
                    result.append(LLMMessage(role: .assistant, content: json))
                }
            case .toolResult(let id, _, let content, let isError, _, _, _, _):
                let envelope: [String: Any] = [
                    "type": "tool_result", "tool_use_id": id, "content": content, "is_error": isError,
                ]
                if let data = try? JSONSerialization.data(withJSONObject: envelope),
                   let json = String(data: data, encoding: .utf8) {
                    result.append(LLMMessage(role: .user, content: json))
                }
            case .imageData:
                break
            }
        }
        return result
    }
}

public extension LLMMessage {
    /// Parse this message back into `AgentContentPart`(s).
    ///
    /// Recognizes the canonical `tool_use` / `tool_result` JSON envelopes
    /// (single object or array); anything else is treated as plain `.text`.
    func toAgentContentParts() -> [AgentContentPart] {
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return [.text(content)]
        }

        func part(from object: [String: Any]) -> AgentContentPart? {
            guard let type = object["type"] as? String else { return nil }
            switch type {
            case "tool_use":
                guard let id = ProviderToolCallBoundary.boundedIdentifier(
                    object["id"], maximumBytes: ProviderToolCallBoundary.maximumIdentifierBytes
                ),
                let name = ProviderToolCallBoundary.boundedIdentifier(
                    object["name"], maximumBytes: ProviderToolCallBoundary.maximumToolNameBytes
                ),
                let input = object["input"] as? [String: Any],
                ProviderToolCallBoundary.validateInputObject(input) else { return nil }
                return .toolUse(id: id, name: name, input: input)
            case "tool_result":
                guard let id = object["tool_use_id"] as? String else { return nil }
                let name = (object["name"] as? String) ?? ""
                let content = (object["content"] as? String) ?? ""
                let isError = (object["is_error"] as? Bool) ?? false
                return .toolResult(id: id, name: name, content: content, isError: isError)
            default:
                return nil
            }
        }

        if let array = json as? [[String: Any]] {
            let parts = array.compactMap(part(from:))
            return parts.isEmpty ? [.text(content)] : parts
        }
        if let object = json as? [String: Any] {
            if let part = part(from: object) {
                return [part]
            }
        }
        return [.text(content)]
    }
}

extension AgentLoop {
    /// 工具卡片展开用的完整命令与输出正文：与发给模型的工具结果走同一套已知密钥保护，
    /// 统计数字仍按原始输出计算。
    private func toolOutputSummaryWithDetail(call: ParsedToolCall, output: String) async -> ToolOutputSummary {
        let body = ToolResultImageChannel.splitTrailingMarkers(output).body
        var arguments = Self.toolArgumentsJSON(call.input)
        var detailBody = body
        if let toolResultProjection {
            detailBody = await toolResultProjection(body)
            arguments = await toolResultProjection(arguments)
        }
        return ToolOutputSummary.captureWithDetail(
            toolName: call.name, argumentsJSON: arguments, output: body, detailOutput: detailBody)
    }

    /// 失败调用也留一份卡片详情：调用参数＋发给模型的同一条报错，界面展开即可看到失败原因
    /// （用户 11/20 会话 893B52D5：读取文件连续失败，卡片只写“请查看结果详情”，原因却看不到）。
    private func failureOutputSummary(call: ParsedToolCall, error: Error) async -> ToolOutputSummary {
        await toolOutputSummaryWithDetail(
            call: call, output: "Error executing tool \(call.name): \(error.localizedDescription)")
    }

    /// 工具卡片展开详情用的参数 JSON（键排序，便于稳定显示）。
    static func toolArgumentsJSON(_ input: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(input),
              let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}


/// 本回合内同一个工具的连续失败计数：该工具成功一次即清零，换成别的工具失败则重新计数。
struct RepeatedToolFailureCounter {
    static let limit = 8
    private var tool: String?
    private var count = 0

    mutating func record(tool name: String, failed: Bool) -> (tool: String, count: Int)? {
        guard failed else {
            if name == tool { tool = nil; count = 0 }
            return nil
        }
        if name == tool { count += 1 } else { tool = name; count = 1 }
        return count >= Self.limit ? (name, count) : nil
    }
}
