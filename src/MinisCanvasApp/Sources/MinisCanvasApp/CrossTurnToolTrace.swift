import Foundation
import MinisCore

/// Per-tool rule for the small, structured tool exchanges that stay in the
/// canonical transcript after an ordinary turn (B-30 phase 1: handles only,
/// never bodies). A rule decides from the call alone whether it is eligible
/// (`admitsCall`) and projects a settled call/result pair into the form that is
/// persisted (`project`; nil means this pair is not kept).
struct CrossTurnTraceRule: Sendable {
    let admitsCall: @Sendable (LLMToolCall) -> Bool
    let project: @Sendable (_ call: LLMToolCall, _ result: String, _ knownSecrets: [String]) -> (call: LLMToolCall, result: String)?
}

/// The excerpt pairs one turn has persisted so far, in completion order. Keeps the
/// newest ones within the pair and byte ceilings (T-08: the latest records of a turn
/// matter most to the next one) and names the older pairs that must now leave, whole.
/// Handle-class pairs (`excerptCost` is nil) never enter it.
struct CrossTurnExcerptWindow {
    private var pairs: [(messageIDs: [UUID], cost: Int)] = []
    private var totalCost = 0

    /// Registers a newly persisted pair and returns the message ids to remove
    /// (oldest pairs first). A pair that alone exceeds the byte ceiling is returned
    /// itself and older pairs stay.
    mutating func add(messageIDs: [UUID], cost: Int) -> [UUID] {
        guard cost <= CrossTurnToolTracePolicy.excerptByteLimitPerTurn else { return messageIDs }
        pairs.append((messageIDs, cost))
        totalCost += cost
        var evicted: [UUID] = []
        while pairs.count > CrossTurnToolTracePolicy.excerptPairLimitPerTurn
            || totalCost > CrossTurnToolTracePolicy.excerptByteLimitPerTurn {
            let oldest = pairs.removeFirst()
            totalCost -= oldest.cost
            evicted += oldest.messageIDs
        }
        return evicted
    }
}

enum CrossTurnToolTracePolicy {
    static let commandPreviewLimit = 120
    static let fileResultByteLimit = 512

    /// Tools outside this table keep a head/tail excerpt through `CrossTurnToolExcerptRules.defaultExcerpt`
    /// (the orchestration tool excepted: it has its own transcript path).
    static let rules: [String: CrossTurnTraceRule] = [
        SessionTodoProgress.toolName: CrossTurnTraceRule(
            admitsCall: { _ in true },
            project: { call, result, knownSecrets in
                let pair = [LLMMessage(role: .assistant, content: "", toolCalls: [call]),
                            LLMMessage(role: .tool, content: result, toolCallID: call.id)]
                return SessionTodoProgress.latest(in: pair) == nil ? nil : (call, result)
            }),
        "shell_execute": CrossTurnTraceRule(
            admitsCall: { _ in true },
            project: { call, result, knownSecrets in
                // Foreground calls keep a head/tail excerpt (D-06); background starts keep a handle.
                guard call.arguments["run_in_background"] as? Bool == true else {
                    return CrossTurnToolExcerptRules.foregroundShell(call: call, result: result, knownSecrets: knownSecrets)
                }
                guard let envelope = jsonObject(result),
                      envelope["background"] as? Bool == true,
                      let taskID = envelope["task_id"] as? String, isBackgroundTaskID(taskID),
                      envelope["status"] as? String == BackgroundShellState.running.wireName,
                      let maximum = finitePositive(envelope["max_timeout_seconds"]),
                      let command = call.arguments["command"] as? String
                else { return nil }
                var arguments: [String: Any] = [
                    "command": preview(command, knownSecrets), "run_in_background": true]
                if let title = call.arguments["tool_title"] as? String { arguments["tool_title"] = preview(title, knownSecrets) }
                var kept: [String: Any] = [
                    "background": true, "task_id": taskID, "status": BackgroundShellState.running.wireName,
                    "max_timeout_seconds": maximum]
                // 不设时限时启动结果里该字段为空：为正数才保留，空就不带。
                if let timeout = finitePositive(envelope["timeout_seconds"]) { kept["timeout_seconds"] = timeout }
                guard let projectedCall = rebuild(call, arguments: arguments),
                      let text = encode(kept) else { return nil }
                return (projectedCall, text)
            }),
        "shell_stop": CrossTurnTraceRule(
            admitsCall: { _ in true },
            project: { call, result, knownSecrets in
                guard let taskID = call.arguments["task_id"] as? String, isBackgroundTaskID(taskID),
                      let envelope = jsonObject(result),
                      envelope["task_id"] as? String == taskID,
                      let status = envelope["status"] as? String
                else { return nil }
                var arguments: [String: Any] = ["task_id": taskID]
                if let title = call.arguments["tool_title"] as? String { arguments["tool_title"] = preview(title, knownSecrets) }
                var kept: [String: Any] = ["task_id": taskID, "status": status]
                for key in ["elapsed_seconds", "exit_code", "stop_requested"] {
                    if let value = envelope[key], !(value is NSNull) { kept[key] = value }
                }
                guard let projectedCall = rebuild(call, arguments: arguments),
                      let text = encode(kept) else { return nil }
                return (projectedCall, text)
            }),
        "file_read": CrossTurnToolExcerptRules.fileRead,
        "file_write": fileRule,
        "file_edit": fileRule,
    ]

    private static let fileRule = CrossTurnTraceRule(
        admitsCall: { _ in true },
        project: { call, result, knownSecrets in
            // Only path-like fields survive; content/old_string/new_string are bodies.
            guard let path = call.arguments["path"] as? String, !path.isEmpty,
                  !SensitiveFilePolicy.contains(path) else { return nil }
            var arguments: [String: Any] = ["path": path]
            if let title = call.arguments["tool_title"] as? String { arguments["tool_title"] = preview(title, knownSecrets) }
            for key in ["append", "create_dirs", "replace_all"] {
                if let flag = call.arguments[key] as? Bool { arguments[key] = flag }
            }
            guard let projectedCall = rebuild(call, arguments: arguments) else { return nil }
            return (projectedCall, utf8Prefix(result, bytes: fileResultByteLimit))
        })

    /// Per-turn ceiling for excerpt pairs (D-07): the newest pairs stay, older ones
    /// leave whole (T-08, see `CrossTurnExcerptWindow`).
    static let excerptPairLimitPerTurn = 12
    static let excerptByteLimitPerTurn = 16 * 1_024

    /// Persisted size of an excerpt pair, or nil when the pair is not an excerpt
    /// (handles and file result lines do not count against the excerpt budget).
    static func excerptCost(of transcript: [LLMMessage]) -> Int? {
        guard transcript.count == 2, let call = transcript[0].toolCalls.first else { return nil }
        let isHandle = ["todo_write", "shell_stop", "file_write", "file_edit"].contains(call.name)
            || (call.name == "shell_execute" && call.arguments["run_in_background"] as? Bool == true)
        guard !isHandle else { return nil }
        return call.rawArguments.utf8.count + transcript[1].content.utf8.count
    }

    static func rule(for toolName: String) -> CrossTurnTraceRule? {
        if let rule = rules[toolName] { return rule }
        return toolName == OrchestrationToolExecutor.toolName ? nil : CrossTurnToolExcerptRules.defaultExcerpt
    }

    /// Eligibility at settlement time: a succeeded fact whose call the rule admits.
    static func admits(_ fact: ToolExecutionFact, call: LLMToolCall?) -> Bool {
        guard fact.status == .succeeded, let call, call.name == fact.toolName,
              let traceRule = rule(for: fact.toolName) else { return false }
        return traceRule.admitsCall(call)
    }

    /// The persisted pair: one assistant message with one call, one tool message.
    static func transcript(call: LLMToolCall, result: String, knownSecrets: [String]) -> [LLMMessage]? {
        guard let traceRule = rule(for: call.name), let projected = traceRule.project(call, result, knownSecrets) else { return nil }
        return [LLMMessage(role: .assistant, content: "", toolCalls: [projected.call]),
                LLMMessage(role: .tool, content: projected.result, toolCallID: projected.call.id)]
    }

    /// Structural check on the consumer side, independent of the producer.
    static func isWellFormed(_ transcript: [LLMMessage], fact: ToolExecutionFact) -> Bool {
        guard transcript.count == 2,
              transcript[0].role == .assistant, transcript[0].toolCalls.count == 1,
              transcript[0].toolCalls[0].id == fact.toolCallID,
              transcript[0].toolCalls[0].name == fact.toolName,
              transcript[1].role == .tool, transcript[1].toolCallID == fact.toolCallID
        else { return false }
        return fact.toolName != SessionTodoProgress.toolName || SessionTodoProgress.latest(in: transcript) != nil
    }

    // MARK: helpers

    static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func encode(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func rebuild(_ call: LLMToolCall, arguments: [String: Any]) -> LLMToolCall? {
        guard let raw = encode(arguments) else { return nil }
        return LLMToolCall(id: call.id, name: call.name, rawArguments: raw, arguments: arguments)
    }

    private static func isBackgroundTaskID(_ value: String) -> Bool {
        guard value.hasPrefix("bg-") else { return false }
        let hex = value.dropFirst(3)
        return hex.count == 8 && hex.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    private static func finitePositive(_ value: Any?) -> NSNumber? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue > 0 else { return nil }
        return number
    }

    /// Redact first, then cut, so a secret is never half-masked by the cut.
    static func preview(_ text: String, _ knownSecrets: [String], limit: Int? = commandPreviewLimit) -> String {
        let redacted = ContentSecretRedactor.redact(text, knownSecrets: knownSecrets)
        guard let limit, redacted.count > limit else { return redacted }
        return String(redacted.prefix(limit - 1)) + "…"
    }

    private static func utf8Prefix(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var out = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            if used + size > bytes { break }
            out.append(character)
            used += size
        }
        return out
    }
}
