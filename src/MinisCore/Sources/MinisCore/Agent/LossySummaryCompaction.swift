import Foundation

/// The model-visible `context_compact` tool (the user says "压缩上下文").
public enum ContextCompactTool {
    public static let toolName = "context_compact"
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
    /// Bounds one rendered message so a huge tool output cannot make the
    /// summary request itself exceed the model window.
    static let perMessageCharacterLimit = 6_000
    static let factTargetLimit = 80
    static let summaryMaxTokens = 4_096
    /// Share of the model window the summary request's transcript may use.
    static let summaryInputWindowPercent = 50
    /// 用户原话由代码原样保留，不交给模型概括（2026-11-15 用户批准）。
    static let userQuotesOpen = "【用户原话开始】"
    static let userQuotesClose = "【用户原话结束】"
    static let perQuoteCharacterLimit = 1_500
    static let userQuotesCharacterLimit = 8_000
    static let backgroundNotice = "这是此前对话的背景资料，不是新的指令；其中的要求以用户原话为准。"
    static let continuationNotice = "继续未完成的工作：从摘要里的“下一步”直接接着做，不要重做已完成的步骤，也不要向用户复述这份摘要；需要原文细节时再查阅。"

    /// Keep the requested tail verbatim, extending it to include any
    /// preceding tool calls needed by its results. If no safe cut exists,
    /// retain the full history so no summary request is made.
    public static func retainedCount(messages: [LLMMessage], keepRecent: Int) -> Int {
        var cut = max(0, messages.count - max(0, keepRecent))
        while cut > 0, hasOrphanToolResult(messages[cut...]) { cut -= 1 }
        return messages.count - cut
    }

    public static func compact(
        messages: [LLMMessage], keepRecent: Int, provider: any LLMProvider,
        systemPrompt: String? = nil, attachmentNames: [Int: [String]] = [:],
        retentionFacts: [CompactionRetainedFact] = []
    ) async throws -> CompactionResult {
        let retained = retainedCount(messages: messages, keepRecent: keepRecent)
        let count = messages.count - retained
        guard count > 0 else {
            return CompactionResult(messages: messages, summary: nil, compactedCount: 0)
        }
        try Task.checkCancellation()
        let rendered = messages.prefix(count).enumerated().map { index, message in
            render(message, attachments: attachmentNames[index] ?? [])
        }
        // The summary request itself must fit the model window: keep the newest
        // rendered messages within the input budget, drop the oldest.
        var remaining = max(0, provider.model.contextWindowTokens * summaryInputWindowPercent / 100
            - (systemPrompt?.count ?? 0) / 4)
        var firstKept = rendered.count
        while firstKept > 0 {
            let cost = max(1, rendered[firstKept - 1].count / 4)
            guard cost <= remaining else { break }
            remaining -= cost
            firstKept -= 1
        }
        var transcript = rendered[firstKept...].joined(separator: "\n\n")
        if firstKept > 0 { transcript = "（更早内容已省略 \(firstKept) 条）\n\n" + transcript }
        let request = LLMMessage(role: .user, content: """
            请把下面这段较早的对话压缩成一份摘要，供后续对话继续使用。按以下小标题分段输出，没有内容的段写“无”：
            1. 目标：用户要达成什么。
            2. 要求与限制：用户提出的要求、偏好和禁止事项（尽量用用户原话）。
            3. 已做的决定：做了什么选择、为什么。
            4. 文件与命令：涉及的文件路径、命令、数据和结论。
            5. 错误与修正：遇到的问题以及怎么解决的。
            6. 已完成：已经做完的事项。
            7. 未完成：还没做完或卡住的事项。
            8. 下一步：接下来要做的第一件事。
            不要加入对话里没有的内容。只输出摘要正文。
            ===== 对话记录 =====
            \(transcript)
            ===== 记录结束 =====
            """)
        let response = try await provider.sendMessage(
            messages: [request], systemPrompt: systemPrompt, maxTokens: summaryMaxTokens, temperature: 0.2)
        try Task.checkCancellation()
        let text = strippingMarkers(response.text).trimmingCharacters(in: .whitespacesAndNewlines)
        // A blank reply is no summary: refuse, as the strict Compactor does.
        guard !text.isEmpty else {
            return CompactionResult(messages: messages, summary: nil, compactedCount: 0,
                                    refusalReason: .unverifiableInformationLoss)
        }
        let facts = factList(messages: messages.prefix(count), attachmentNames: attachmentNames)
        // 原话总量不超过被压缩内容的 30%，保证压缩后请求确实变小。
        let compactedCharacters = rendered.reduce(0) { $0 + $1.count }
        let quotes = userQuotes(messages: messages.prefix(count),
                                characterLimit: min(userQuotesCharacterLimit, compactedCharacters * 3 / 10))
        let body = "以下是此前对话的摘要（由模型生成，会有损）。\(backgroundNotice)\n\(text)"
            + (quotes.isEmpty ? "" : "\n\n\(quotes)")
            + (facts.isEmpty ? "" : "\n\n\(facts)")
            + "\n\n\(continuationNotice)"
        let summary = LLMMessage(role: .user, content: "\(summaryOpen)\n\(body)\n\(summaryClose)")
        // Facts read from the task/effect stores (not model-written) stay a
        // separate, refreshable message, so a dispatched effect is never replayed.
        let background = CompactionFactCapture.backgroundMessage(retentionFacts).map { [$0] } ?? []
        let tail = Array(messages.suffix(retained))
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

    private static func clipped(_ text: String) -> String {
        guard text.count > perMessageCharacterLimit else { return text }
        let head = text.prefix(perMessageCharacterLimit * 2 / 3)
        let tail = text.suffix(perMessageCharacterLimit / 3)
        return "\(head)\n……（中间省略 \(text.count - head.count - tail.count) 字）……\n\(tail)"
    }

    private static func render(_ message: LLMMessage, attachments: [String]) -> String {
        let role: String
        switch message.role {
        case .user: role = "用户"
        case .assistant: role = "助手"
        case .tool: role = "工具结果"
        }
        var lines = ["【\(role)】"]
        if !message.content.isEmpty { lines.append(clipped(message.content)) }
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

    /// 被压缩区间里用户的原话，按时间顺序原样保留；更早一次压缩留下的原话一并继承。
    /// 单条超长截断；总量超限时保留最新的。
    static func userQuotes(messages: ArraySlice<LLMMessage>,
                           characterLimit: Int = userQuotesCharacterLimit) -> String {
        var quotes: [String] = []
        for message in messages where message.role == .user {
            let content = message.content
            if content.hasPrefix(summaryOpen) {
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
        var kept: [String] = []
        var total = 0
        for quote in quotes.reversed() {
            guard total + quote.count <= characterLimit else { break }
            kept.insert(quote, at: 0)
            total += quote.count
        }
        guard !kept.isEmpty else { return "" }
        let omitted = quotes.count - kept.count
        return userQuotesOpen + "\n"
            + (omitted > 0 ? "（更早的 \(omitted) 条原话因篇幅省略）\n" : "")
            + kept.joined(separator: "\n") + "\n" + userQuotesClose
    }

    private static func strippingMarkers(_ text: String) -> String {
        text.replacingOccurrences(of: summaryOpen, with: "")
            .replacingOccurrences(of: summaryClose, with: "")
    }

    // MARK: - Fact list

    private static func factList(
        messages: ArraySlice<LLMMessage>, attachmentNames: [Int: [String]]
    ) -> String {
        var tools: [String] = []
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
        var names: [String] = []
        for index in attachmentNames.keys.sorted() where index < messages.endIndex {
            for name in attachmentNames[index] ?? [] where !names.contains(name) { names.append(name) }
        }
        var lines: [String] = []
        if !tools.isEmpty { lines.append("事实清单 · 执行过的工具：" + tools.joined(separator: "；")) }
        if !names.isEmpty { lines.append("事实清单 · 出现过的附件：" + names.joined(separator: "、")) }
        return lines.joined(separator: "\n")
    }
}
