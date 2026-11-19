import Foundation

/// The model-visible `context_compact` tool (the user says "压缩上下文").
public enum ContextCompactTool {
    public static let toolName = "context_compact"
}

/// 调用方对单次请求的提示，随任务传递。摘要请求只发一次、不会被后续请求复用，
/// 给它打缓存断点只会多付一次缓存写入的加价：压缩时关掉。Provider 不认这个提示时照常处理。
public enum LLMRequestHints {
    @TaskLocal public static var promptCaching = true
}

public extension CompactionResult {
    /// A lossy summary result: `[summary] + [store-facts background]? + exact
    /// recent tail`, with no source spans. It becomes a
    /// `CompactionCheckpoint.lossySummarySchemaVersion` checkpoint.
    var isLossySummary: Bool {
        projectionSpans == nil && projectionRecentCount != nil && retentionFacts != nil
    }
}

/// Claude-Code-style compaction: everything older than the recent tail
/// (tool_use/tool_result and attachments included) is rendered as a transcript,
/// the model writes the summary, and a fact list of the tools run and the
/// attachments seen follows it. The summary is lossy by design; the canonical
/// transcript is never rewritten.
public enum LossySummaryCompaction {
    static let summaryOpen = "<context-summary>"
    static let summaryClose = "</context-summary>"

    /// 程序生成的摘要消息：用户角色、不带图片音频，正文整体被摘要标记包住（开头和结尾都是标记）。
    /// 用户正文或工具结果里只是出现、或只以标记开头的字面量不算。
    public static func isProgramSummary(_ message: LLMMessage) -> Bool {
        guard message.role == .user, message.images.isEmpty, message.audios.isEmpty else { return false }
        let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasPrefix(summaryOpen) && text.hasSuffix(summaryClose)
    }
    /// Bounds one rendered message so a huge tool output cannot make the
    /// summary request itself exceed the model window.
    static let perMessageCharacterLimit = 6_000
    static let factTargetLimit = 80
    static let summaryMaxTokens = 4_096
    /// 摘要被输出上限截断时，重试一次使用的更大上限。
    static let summaryRetryMaxTokens = 8_192
    /// 摘要里关键代码片段的总字数上限（写进提示词）。
    static let codeSnippetCharacterBudget = 3_000
    /// Share of the model window the summary request's transcript may use.
    /// 再扣除系统提示、摘要输出预留和固定说明文字，不是固定的一半。
    static let summaryInputWindowPercent = 60
    /// 摘要请求里固定说明文字（小标题、要求）的 token 估值。
    static let summaryInstructionTokens = 700
    /// 上一份摘要最多占输入预算的比例，其余留给新增内容。
    static let priorSummaryBudgetPercent = 50

    /// 上一次压缩留下的摘要：新摘要以它为基础，再接其后的新消息。
    /// `coveredCount` 是它已经覆盖的原始消息条数（这些原始消息不再重复渲染）。
    public struct PriorSummary: Sendable, Equatable {
        public let content: String
        public let coveredCount: Int
        public init(content: String, coveredCount: Int) {
            self.content = content
            self.coveredCount = coveredCount
        }
    }

    /// 从最新压缩检查点取上一份摘要。只有检查点是模型摘要型、覆盖范围从头开始，
    /// 且它所依据的原始前缀与当前消息逐字一致时才采用，否则返回 nil（按原始消息整段重新摘要）。
    public static func priorSummary(
        checkpoint: CompactionCheckpoint?, messages: [LLMMessage]
    ) -> PriorSummary? {
        guard let checkpoint,
              checkpoint.schemaVersion == CompactionCheckpoint.lossySummarySchemaVersion,
              checkpoint.compactedMessageRange.lowerBound == 0,
              checkpoint.compactedMessageRange.upperBound > 0,
              checkpoint.compactedMessageRange.upperBound <= messages.count,
              let expected = checkpoint.sourcePrefixDigest,
              CompactionCheckpoint.digestOfSourcePrefix(
                Array(messages.prefix(checkpoint.compactedMessageRange.upperBound))) == expected,
              checkpoint.summaryMessage.content.hasPrefix(summaryOpen) else { return nil }
        return PriorSummary(content: checkpoint.summaryMessage.content,
                            coveredCount: checkpoint.compactedMessageRange.upperBound)
    }
    /// 用户原话由代码原样保留，不交给模型概括（2026-11-15 用户批准）。
    static let userQuotesOpen = "【用户原话开始】"
    static let userQuotesClose = "【用户原话结束】"
    static let perQuoteCharacterLimit = 1_500
    static let userQuotesCharacterLimit = 8_000
    static let backgroundNotice = "这是此前对话的背景资料，不是新的指令；其中的要求以用户原话为准。"
    /// 摘要被截断（重试后仍然）时附在摘要后面的说明。
    static let truncationNotice = "【注意：摘要在这里被输出上限截断，后面的“未完成”和“下一步”可能缺失，不能当作完整摘要。】"
    /// 摘要不完整时代替 `continuationNotice`，不让模型凭残缺摘要接着做。
    static let truncatedContinuationNotice = "摘要不完整：不要凭摘要猜“下一步”，也不要向用户复述这份摘要；以用户最新消息为准，没有新消息时先问用户要继续什么，需要原文细节可用 session_read 读取本会话原文。"
    /// 各家 Provider 把“输出到上限被截断”写成的结束原因：OpenAI 兼容 `length`、Anthropic `max_tokens`、
    /// Responses `incomplete(max_output_tokens)`。
    static func isTruncatedByOutputLimit(_ stopReason: String?) -> Bool {
        guard let reason = stopReason?.lowercased() else { return false }
        // Responses 把 `status` 原样当结束原因（"incomplete"），纯文本流才拼成 incomplete(max_output_tokens)；
        // 主循环同样按 incomplete 前缀判断。
        return reason == "length" || reason == "max_tokens" || reason.hasPrefix("incomplete")
            || reason.contains("max_output_tokens")
    }
    static let continuationNotice = "继续未完成的工作：从摘要里的“下一步”直接接着做，不要重做已完成的步骤，也不要向用户复述这份摘要；需要原文细节时可用 session_read 读取本会话原文。若其后有新的用户消息，以最新消息为准，没有新消息时才接着做下一步。"

    /// Keep the requested tail verbatim, extending it to include any
    /// preceding tool calls needed by its results. If no safe cut exists,
    /// retain the full history so no summary request is made.
    public static func retainedCount(messages: [LLMMessage], keepRecent: Int) -> Int {
        var cut = max(0, messages.count - max(0, keepRecent))
        while cut > 0, hasOrphanToolResult(messages[cut...]) { cut -= 1 }
        cut = cutWithinCheckpointBudget(messages: messages, cut: cut)
        return messages.count - cut
    }

    /// The checkpoint stores the kept tail verbatim, images and audio as base64.
    /// Tail messages beyond this many encoded bytes (counted from the newest)
    /// are summarized instead, so a screenshot or a pasted document in the last
    /// few messages cannot make the checkpoint too large to save. The original
    /// messages stay in the session.
    ///
    /// The budget never pushes the newest real user message out of the tail
    /// (Claude Code does not compact away the message the user just sent). When
    /// it would, the budget is not applied: the tail keeps that message, and if
    /// the result cannot be saved the compaction is refused, so nothing is
    /// compacted and the message is sent as it is.
    static let retainedTailByteBudget = CompactionCheckpoint.maxMessageContentBytes

    private static func cutWithinCheckpointBudget(messages: [LLMMessage], cut: Int) -> Int {
        var remaining = retainedTailByteBudget
        var first = messages.count
        while first > cut {
            let size = CompactionCheckpoint.persistedByteCount(of: messages[first - 1], limit: remaining)
            guard size <= remaining else { break }
            remaining -= size
            first -= 1
        }
        // Dropping older messages must not leave a tool result without its call.
        while first < messages.count, hasOrphanToolResult(messages[first...]) { first += 1 }
        if let latestUser = latestRealUserMessageIndex(in: messages), latestUser >= cut, first > latestUser {
            return cut
        }
        return first
    }

    /// 最新一条真实用户消息：程序生成的用户角色消息（上一份摘要、保留事实、目标续跑）和
    /// 工具结果信封不算；只带图片或音频的用户消息算。
    static func latestRealUserMessageIndex(in messages: [LLMMessage]) -> Int? {
        messages.indices.last { index in
            let message = messages[index]
            guard message.role == .user else { return false }
            let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !isProgramSummary(message), !text.hasPrefix("<retained-store-facts>"),
                  !text.hasPrefix("〔目标续跑〕") else { return false }
            if text.isEmpty { return !message.images.isEmpty || !message.audios.isEmpty }
            return !message.toAgentContentParts().contains {
                if case .toolResult = $0 { return true }
                return false
            }
        }
    }

    public static func compact(
        messages: [LLMMessage], keepRecent: Int, provider: any LLMProvider,
        systemPrompt: String? = nil, attachmentNames: [Int: [String]] = [:],
        retentionFacts: [CompactionRetainedFact] = [],
        handover: Bool = false,
        priorSummary: PriorSummary? = nil
    ) async throws -> CompactionResult {
        let retained = retainedCount(messages: messages, keepRecent: keepRecent)
        let count = messages.count - retained
        guard count > 0 else {
            return CompactionResult(messages: messages, summary: nil, compactedCount: 0)
        }
        // 保留的尾部自己就存不进检查点（最新一条用户消息带大图或大段文字时会这样）：
        // 不必先花一次摘要请求，直接拒绝，本次不压缩。
        guard CompactionCheckpoint.fitsPersistenceBounds(Array(messages.suffix(retained)), facts: []) else {
            return CompactionResult(messages: messages, summary: nil, compactedCount: 0,
                                    refusalReason: .unverifiableInformationLoss)
        }
        try Task.checkCancellation()
        let rendered = messages.prefix(count).enumerated().map { index, message in
            render(message, attachments: attachmentNames[index] ?? [], number: index + 1)
        }
        // 上一份摘要已覆盖的原始消息不再重复渲染；新摘要基于“上一份摘要 + 其后的新消息”。
        let covered = min(max(0, priorSummary?.coveredCount ?? 0), count)
        let priorBody = covered > 0
            ? priorSummary.map { previousSummaryBody($0.content) }.flatMap { $0.isEmpty ? nil : $0 }
            : nil
        let usePrior = priorBody != nil
        let fresh = usePrior ? Array(rendered.dropFirst(covered)) : rendered
        // The summary request itself must fit the model window: keep the newest
        // rendered messages within the input budget, drop the oldest.
        // 输入预算 = 窗口的 60% 扣除系统提示、摘要输出预留和固定说明文字。
        let window = provider.model.contextWindowTokens
        // 小窗口模型（如 8k 本地模型）不能固定预留 4096 输出，否则一条消息都放不进摘要请求。
        let outputReserve = max(512, min(summaryMaxTokens, window / 4))
        let baseRemaining = max(window / 5, window * summaryInputWindowPercent / 100
            - AgentContextTokenBudget.estimatedTextTokens(systemPrompt ?? "")
            - outputReserve - summaryInstructionTokens)
        // 输入估算偏小（代码、JSON、日志）时请求可能超窗：被拒后输入预算减半重试一次。
        func buildRequest(budgetDivisor: Int) -> (request: LLMMessage, omittedNote: String) {
        var remaining = baseRemaining / budgetDivisor
        var priorSection = ""
        if let priorBody {
            let limit = max(1, remaining * priorSummaryBudgetPercent / 100)
            var text = priorBody
            // 上一份摘要过长时保留结尾（“未完成、下一步”在后面），省略开头。
            while AgentContextTokenBudget.estimatedTextTokens(text) > limit, text.count > 200 {
                text = String(text.suffix(text.count * 3 / 4))
            }
            priorSection = "【此前摘要（已覆盖更早的 \(covered) 条消息）】\n" + text
            remaining = max(0, remaining - max(1, AgentContextTokenBudget.estimatedTextTokens(priorSection)))
        }
        func keepNewest(within budget: Int) -> (first: Int, left: Int) {
            var left = budget
            var first = fresh.count
            while first > 0 {
                // 中日韩文字约一字一 token，按 4 字一 token 会把请求估小到超出模型窗口。
                let cost = max(1, AgentContextTokenBudget.estimatedTextTokens(fresh[first - 1]))
                guard cost <= left else { break }
                left -= cost
                first -= 1
            }
            return (first, left)
        }
        var (firstKept, leftover) = keepNewest(within: remaining)
        // 第一条用户消息（通常是任务目标）省不得：被挤出时固定放在摘要输入开头，其余照常保留最新的。
        // 已有上一份摘要时，目标已经在摘要里，不再固定。
        var pinned = ""
        if !usePrior, let index = firstGoalMessageIndex(in: messages.prefix(count)),
           index < fresh.count - 1, firstKept > index {
            var text = fresh[index]
            let cap = max(200, remaining / 3)
            if AgentContextTokenBudget.estimatedTextTokens(text) > cap { text = String(text.prefix(cap)) + "……" }
            pinned = text
            (firstKept, leftover) = keepNewest(
                within: max(0, remaining - max(1, AgentContextTokenBudget.estimatedTextTokens(text))))
        }
        var transcript = fresh[firstKept...].joined(separator: "\n\n")
        // 连最新一条都放不下时，截取它的开头和结尾放进去，不能让摘要请求里没有对话内容。
        if firstKept == fresh.count, let newest = fresh.last, leftover > 64 {
            let head = min(200, leftover / 4)
            let tail = max(0, leftover - head - 16)
            transcript = String(newest.prefix(head)) + "\n…（中间已截断）…\n" + String(newest.suffix(tail))
            firstKept -= 1
        }
        // 固定放回的第一条用户消息不算被省略。
        let omittedCount = max(0, firstKept - (pinned.isEmpty ? 0 : 1))
        if omittedCount > 0 { transcript = "（更早内容已省略 \(omittedCount) 条）\n\n" + transcript }
        if !pinned.isEmpty { transcript = pinned + "\n\n" + transcript }
        if !priorSection.isEmpty {
            transcript = priorSection + (transcript.isEmpty ? "" : "\n\n" + transcript)
        }
        let omittedNote = omittedCount > 0
            ? "\n\n（更早 \(omittedCount) 条消息未纳入这次摘要，原文可用 session_read 读取。）" : ""
        let request = LLMMessage(role: .user, content: """
            请把下面这段较早的对话压缩成一份摘要，供后续对话继续使用。按以下小标题分段输出，没有内容的段写“无”：
            1. 目标：用户要达成什么。
            2. 要求与限制：用户提出的要求、偏好和禁止事项（尽量用用户原话）。
            3. 已做的决定：做了什么选择、为什么。
            4. 文件与命令：涉及的文件路径、命令、数据和结论。
            5. 错误与修正：遇到的问题以及怎么解决的。
            6. 已完成：已经做完的事项，尤其是已成功写入、修改、删除、发送的内容（写明对象），后续不要重复执行。
            7. 未完成：还没做完或卡住的事项。
            8. 下一步：接下来要做的第一件事。
            在“文件与命令”里保留后续继续工作必需的关键代码片段（原样、带文件路径），所有片段合计不超过约 \(codeSnippetCharacterBudget) 字。
            记录里“附件”后面的文件路径要原样写进“文件与命令”；图片不会被带入后续对话，只用文字写清图里与任务有关的内容。
            如果记录开头有“此前摘要”，它是更早对话的摘要：请在它的基础上并入其后的新内容，更新各段，保留仍然有效的目标、要求、决定、文件和未完成事项，不要丢掉它。
            不要加入对话里没有的内容。只输出摘要正文。
            ===== 对话记录 =====
            \(transcript)
            ===== 记录结束 =====
            """)
        return (request, omittedNote)
        }
        // 摘要请求只发一次，不打 Anthropic 缓存断点（多付一次缓存写入的加价，后面没有请求会读它）。
        func sendSummary(_ request: LLMMessage, maxTokens: Int) async throws -> LLMResponse {
            try await LLMRequestHints.$promptCaching.withValue(false) {
                try await provider.sendMessage(
                    messages: [request], systemPrompt: systemPrompt, maxTokens: maxTokens, temperature: nil)
            }
        }
        let first = buildRequest(budgetDivisor: 1)
        var omittedNote = first.omittedNote
        var sentRequest = first.request
        let response: LLMResponse
        do {
            response = try await sendSummary(first.request, maxTokens: outputReserve)
        } catch LLMError.contextLengthExceeded {
            try Task.checkCancellation()
            let retry = buildRequest(budgetDivisor: 2)
            omittedNote = retry.omittedNote
            sentRequest = retry.request
            response = try await sendSummary(retry.request, maxTokens: outputReserve)
        }
        try Task.checkCancellation()
        var finalResponse = response
        // 摘要写满输出上限会丢掉最后的“未完成、下一步”：用更大的上限重试一次。
        if isTruncatedByOutputLimit(response.stopReason) {
            // 重试上限不能超过模型自己的最大输出（不少本地模型和老模型只有 4096）。
            let modelOutputCeiling = provider.model.maxOutputTokens
                ?? LLMModel.allModels.first { $0.id == provider.model.id }?.maxOutputTokens ?? Int.max
            let retryTokens = max(outputReserve, min(summaryRetryMaxTokens, window / 2, modelOutputCeiling))
            if retryTokens > outputReserve {
                do {
                    finalResponse = try await sendSummary(sentRequest, maxTokens: retryTokens)
                } catch {
                    // 第一次的摘要虽被截断但可用：重试失败（限流、超时等）就沿用它，下面照常加截断标注。
                    try Task.checkCancellation()
                }
                try Task.checkCancellation()
            }
        }
        let summaryIsTruncated = isTruncatedByOutputLimit(finalResponse.stopReason)
        var text = strippingMarkers(finalResponse.text).trimmingCharacters(in: .whitespacesAndNewlines)
        // A blank reply is no summary: refuse, as the strict Compactor does.
        guard !text.isEmpty else {
            return CompactionResult(messages: messages, summary: nil, compactedCount: 0,
                                    refusalReason: .unverifiableInformationLoss)
        }
        text += omittedNote
        if summaryIsTruncated { text += "\n\n\(truncationNotice)" }
        // 交接模式（在新聊天中继续）：只要摘要正文，不带用户原话块、事实清单和续做提示，
        // 免得新会话把“继续未完成的工作”当成要立刻执行的指令。
        if handover {
            return CompactionResult(messages: [LLMMessage(role: .user, content: text)],
                                    summary: text, compactedCount: count)
        }
        let facts = factList(messages: messages.prefix(count), attachmentNames: attachmentNames)
        // 原话总量不超过被压缩内容的 30%，保证压缩后请求确实变小。
        let compactedCharacters = rendered.reduce(0) { $0 + $1.count }
        let quotes = userQuotes(messages: messages.prefix(count),
                                characterLimit: min(userQuotesCharacterLimit, compactedCharacters * 3 / 10))
        let body = "以下是此前对话的摘要（由模型生成，会有损）。\(backgroundNotice)\n\(text)"
            + (quotes.isEmpty ? "" : "\n\n\(quotes)")
            + (facts.isEmpty ? "" : "\n\n\(facts)")
            + "\n\n\(summaryIsTruncated ? truncatedContinuationNotice : continuationNotice)"
        let summary = LLMMessage(role: .user, content: "\(summaryOpen)\n\(body)\n\(summaryClose)")
        // Facts read from the task/effect stores (not model-written) stay a
        // separate, refreshable message, so a dispatched effect is never replayed.
        let background = CompactionFactCapture.backgroundMessage(retentionFacts).map { [$0] } ?? []
        let tail = Array(messages.suffix(retained))
        // A result the store cannot persist is a refusal, not a failed turn.
        guard CompactionCheckpoint.fitsPersistenceBounds([summary] + background + tail, facts: retentionFacts) else {
            return CompactionResult(messages: messages, summary: nil, compactedCount: 0,
                                    refusalReason: .unverifiableInformationLoss)
        }
        return CompactionResult(messages: [summary] + background + tail, summary: body,
                                compactedCount: count, projectionRecentCount: retained,
                                retentionFacts: retentionFacts)
    }

    // MARK: - Tool pairing

    private static func toolIdentities(_ message: LLMMessage) -> (uses: [String], results: [String]) {
        var uses = message.toolCalls.map(\.id)
        var results: [String] = []
        // Legacy text envelope: an assistant reply {"tool_calls":[{"id":...}]}.
        if message.role == .assistant, let data = message.content.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let calls = object["tool_calls"] as? [[String: Any]] {
            uses += calls.compactMap { $0["id"] as? String }
        }
        if message.role == .tool, let id = message.toolCallID { results.append(id) }
        for part in message.toAgentContentParts() {
            switch part {
            case .toolUse(let id, _, _): uses.append(id)
            case .toolResult(let id, _, _, _, _, _, _, _): results.append(id)
            default: break
            }
        }
        return (uses, results)
    }

    private static func hasOrphanToolResult(_ tail: ArraySlice<LLMMessage>) -> Bool {
        var uses = Set<String>()
        var results = Set<String>()
        for message in tail {
            let identities = toolIdentities(message)
            uses.formUnion(identities.uses)
            results.formUnion(identities.results)
        }
        return !results.isSubset(of: uses)
    }

    // MARK: - Rendering

    private static func clipped(_ text: String, number: Int? = nil) -> String {
        guard text.count > perMessageCharacterLimit else { return text }
        let head = text.prefix(perMessageCharacterLimit * 2 / 3)
        let tail = text.suffix(perMessageCharacterLimit / 3)
        let source = number.map { "，原文见会话第 \($0) 条，可用 session_read 读取" } ?? ""
        return "\(head)\n……（中间省略 \(text.count - head.count - tail.count) 字\(source)）……\n\(tail)"
    }

    private static func render(_ message: LLMMessage, attachments: [String], number: Int? = nil) -> String {
        let role: String
        switch message.role {
        case .user: role = "用户"
        case .assistant: role = "助手"
        case .tool: role = "工具结果"
        }
        var lines = ["【\(role)】"]
        if isProgramSummary(message) {
            // 上一次的摘要：只取正文，去掉重复附加的原话、事实清单和续做提示；整段不截断，
            // 否则“未完成、下一步”会被截掉。
            lines.append(previousSummaryBody(message.content))
        } else if !message.content.isEmpty {
            lines.append(clipped(message.content, number: number))
        }
        for call in message.toolCalls {
            lines.append("（调用工具 \(call.name)：\(clipped(call.rawArguments))）")
        }
        if !attachments.isEmpty {
            lines.append("（附件：\(attachments.joined(separator: "、"))）")
        } else if !message.images.isEmpty {
            lines.append("（图片附件 \(message.images.count) 张）")
        }
        if !message.audios.isEmpty { lines.append("（音频附件 \(message.audios.count) 段）") }
        return lines.joined(separator: "\n")
    }

    /// 上一份摘要里模型写的正文：去掉标记、原话块、事实清单行、背景声明与续做提示。
    static func previousSummaryBody(_ content: String) -> String {
        var text = content
        if let open = text.range(of: summaryOpen) { text.removeSubrange(open) }
        if let close = text.range(of: summaryClose, options: .backwards) { text.removeSubrange(close) }
        if let start = text.range(of: userQuotesOpen),
           let end = text.range(of: userQuotesClose, range: start.upperBound..<text.endIndex) {
            text.removeSubrange(start.lowerBound..<end.upperBound)
        }
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            let s = line.trimmingCharacters(in: .whitespaces)
            return !s.hasPrefix("事实清单 ·") && s != continuationNotice && s != truncatedContinuationNotice
                && !s.hasPrefix("继续未完成的工作：从摘要里的")
                && !s.contains(backgroundNotice)
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 摘要输入里要固定保留的第一条用户消息：程序生成的用户角色消息（上一份摘要、保留事实、目标续跑）不算。
    static func firstGoalMessageIndex(in messages: ArraySlice<LLMMessage>) -> Int? {
        messages.indices.first { index in
            let message = messages[index]
            guard message.role == .user else { return false }
            let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return !text.isEmpty && !isProgramSummary(message)
                && !text.hasPrefix("<retained-store-facts>") && !text.hasPrefix("〔目标续跑〕")
        }
    }

    /// 被压缩区间里用户的原话，按时间顺序原样保留；更早一次压缩留下的原话一并继承。
    /// 单条超长截断；总量超限时固定保留最早的一条（通常是任务目标），其余保留最新的。
    static func userQuotes(messages: ArraySlice<LLMMessage>,
                           characterLimit: Int = userQuotesCharacterLimit) -> String {
        var quotes: [String] = []
        for message in messages where message.role == .user {
            let content = message.content
            if isProgramSummary(message) {
                if let start = content.range(of: userQuotesOpen),
                   let end = content.range(of: userQuotesClose, range: start.upperBound..<content.endIndex) {
                    quotes += content[start.upperBound..<end.lowerBound]
                        .split(separator: "\n").map(String.init)
                        .filter { $0.hasPrefix("- ") }
                }
                continue
            }
            let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
            // 程序生成的用户角色消息（保留事实、目标续跑）不是用户原话。
            guard !text.isEmpty, !text.hasPrefix("<retained-store-facts>"), !text.hasPrefix("〔目标续跑〕") else { continue }
            let single = text.replacingOccurrences(of: "\n", with: " ")
            let bounded = single.count > perQuoteCharacterLimit
                ? String(single.prefix(perQuoteCharacterLimit)) + "……" : single
            quotes.append("- " + bounded)
        }
        // 最早的一条（通常是用户最初交代的目标）固定保留，最多占限额的一半（只有一条时可占满）；
        // 其余按从新到旧装入剩下的额度。
        guard var head = quotes.first else { return "" }
        let headBudget = quotes.count == 1 ? characterLimit : characterLimit / 2
        if head.count > headBudget {
            head = headBudget >= 8 ? String(head.prefix(headBudget)) + "……" : ""
        }
        var total = head.count
        var recent: [String] = []
        for quote in quotes.dropFirst().reversed() {
            guard total + quote.count <= characterLimit else { break }
            recent.insert(quote, at: 0)
            total += quote.count
        }
        let kept = (head.isEmpty ? [] : [head]) + recent
        guard !kept.isEmpty else { return "" }
        let omitted = quotes.count - kept.count
        return userQuotesOpen + "\n"
            + (head.isEmpty ? "" : head + "\n")
            + (omitted > 0 ? "（更早的 \(omitted) 条原话因篇幅省略）\n" : "")
            + recent.joined(separator: "\n") + (recent.isEmpty ? "" : "\n") + userQuotesClose
    }

    private static func strippingMarkers(_ text: String) -> String {
        text.replacingOccurrences(of: summaryOpen, with: "")
            .replacingOccurrences(of: summaryClose, with: "")
    }

    // MARK: - Fact list

    static let toolFactsPrefix = "事实清单 · 执行过的工具："
    static let attachmentFactsPrefix = "事实清单 · 出现过的附件："
    /// 事实清单各类条目的保留上限（保留最新的），防止多次压缩后无限增长。
    static let factListEntryLimit = 120

    /// 更早一次压缩留下的事实行，按用户原话同样的方式继承到新的事实清单里。
    static func inheritedFactEntries(
        messages: ArraySlice<LLMMessage>
    ) -> (tools: [String], attachments: [String]) {
        var tools: [String] = []
        var attachments: [String] = []
        for message in messages where isProgramSummary(message) {
            for line in message.content.split(separator: "\n") {
                let s = line.trimmingCharacters(in: .whitespaces)
                if s.hasPrefix(toolFactsPrefix) {
                    tools += s.dropFirst(toolFactsPrefix.count).split(separator: "；").map(String.init)
                } else if s.hasPrefix(attachmentFactsPrefix) {
                    attachments += s.dropFirst(attachmentFactsPrefix.count).split(separator: "、").map(String.init)
                }
            }
        }
        return (tools, attachments)
    }

    static func factList(
        messages: ArraySlice<LLMMessage>, attachmentNames: [Int: [String]]
    ) -> String {
        let inherited = inheritedFactEntries(messages: messages)
        var tools: [String] = inherited.tools
        for message in messages {
            var calls = message.toolCalls.map { ($0.name, $0.arguments) }
            for part in message.toAgentContentParts() {
                if case .toolUse(_, let name, let input) = part { calls.append((name, input)) }
            }
            for (name, arguments) in calls {
                let target = ["path", "command", "query", "url", "tool_title"]
                    .compactMap { arguments[$0] as? String }
                    .first { !$0.isEmpty }
                    .map { "（\(String($0.prefix(factTargetLimit)))）" } ?? ""
                let entry = name + target
                if !tools.contains(entry) { tools.append(entry) }
            }
        }
        var names: [String] = inherited.attachments
        for index in attachmentNames.keys.sorted() where index < messages.endIndex {
            for name in attachmentNames[index] ?? [] where !names.contains(name) { names.append(name) }
        }
        tools = Array(tools.suffix(factListEntryLimit))
        names = Array(names.suffix(factListEntryLimit))
        var lines: [String] = []
        if !tools.isEmpty { lines.append("事实清单 · 执行过的工具：" + tools.joined(separator: "；")) }
        if !names.isEmpty { lines.append("事实清单 · 出现过的附件：" + names.joined(separator: "、")) }
        return lines.joined(separator: "\n")
    }
}
