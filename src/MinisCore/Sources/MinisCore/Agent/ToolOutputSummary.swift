import Foundation

/// Content-free facts measured from the bytes returned by one tool execution.
/// This is display metadata, never an authorization or success decision. In
/// particular, no excerpt of stdout, stderr, a file, or a remote page is kept.
public enum ToolOutputSummary: Codable, Equatable, Hashable, Sendable {
    case text(bytes: Int, lines: Int)
    case shell(exitCode: Int, stdoutBytes: Int, stdoutLines: Int, stderrBytes: Int, stderrLines: Int)
    // Keep the two original cases unchanged: durable facts written by the
    // first output-metrics release retain their exact Codable shape. These
    // cases are emitted only when a fixed, content-free signal was recognized.
    case textWithSignals(bytes: Int, lines: Int, signals: [ContentSignal])
    case shellWithSignals(exitCode: Int, stdoutBytes: Int, stdoutLines: Int, stderrBytes: Int, stderrLines: Int, signals: [ContentSignal])
    /// 统计之外，再带一份已脱敏、按长度截断的调用内容（完整命令/路径/模式）与输出正文，
    /// 供工具卡片展开查看。只由 `captureWithDetail` 产生；旧数据不含此 case，照常解码。
    indirect case withDetail(summary: ToolOutputSummary, detail: ToolCallDetail)

    /// 工具卡片展开后显示的调用内容与输出正文。两者都已按 `ContentSecretRedactor` 脱敏。
    public struct ToolCallDetail: Codable, Equatable, Hashable, Sendable {
        /// 完整命令、完整路径或检索模式；没有可展示的目标时为 nil。
        public let input: String?
        /// 输出正文前 `ToolOutputSummary.maxDetailLines` 行；没有输出时为 nil。
        public let output: String?
        /// 因行数上限被省略的行数。
        public let omittedLines: Int
        /// 输出（或调用内容）因字符上限被截断。
        public let isTruncated: Bool
        /// 完整输出已落盘时的文件路径（会话输出目录内）；卡片据此提供“打开完整输出”。旧数据没有此字段。
        public let fullOutputPath: String?

        public init(input: String?, output: String?, omittedLines: Int, isTruncated: Bool,
                    fullOutputPath: String? = nil) {
            self.input = input
            self.output = output
            self.omittedLines = max(0, omittedLines)
            self.isTruncated = isTruncated
            self.fullOutputPath = fullOutputPath
        }
    }

    public static let maxDetailLines = 200
    public static let maxDetailOutputCharacters = 16_000
    public static let maxDetailInputCharacters = 4_000

    /// 卡片展开用的调用内容与输出正文；无详情（旧数据、纯统计）为 nil。
    public var detail: ToolCallDetail? {
        if case .withDetail(_, let detail) = self { return detail }
        return nil
    }

    /// Closed vocabulary: no tool-returned string, path or diff ID can enter
    /// a durable fact through a signal. A signal describes what the tool
    /// *reported*; it is never proof of an effect or an approval.
    public enum ContentSignal: Codable, Equatable, Hashable, Sendable {
        case reportedFileWrite(bytes: Int)
        case reportedFileEdit(replacements: Int, bytes: Int)
        case diagnosticErrors(lines: Int)
        case diagnosticWarnings(lines: Int)
        case failedTests(lines: Int)
        case sessionReadPage(messages: Int, total: Int, hasMore: Bool)

        fileprivate var displayLabel: String? {
            switch self {
            case .reportedFileWrite(let bytes) where bytes >= 0:
                return "工具报告写入 \(bytes) 字节"
            case .reportedFileEdit(let replacements, let bytes) where replacements >= 0 && bytes >= 0:
                return "工具报告替换 \(replacements) 处、写入 \(bytes) 字节"
            case .diagnosticErrors(let lines) where lines > 0:
                return "错误诊断 \(lines) 行"
            case .diagnosticWarnings(let lines) where lines > 0:
                return "警告诊断 \(lines) 行"
            case .failedTests(let lines) where lines > 0:
                return "失败测试 \(lines) 行"
            case .sessionReadPage(let messages, let total, let hasMore)
                where messages >= 0 && total >= messages:
                return "已读取会话消息 \(messages) 条，共 \(total) 条；\(hasMore ? "仍有后续页" : "无后续页")"
            default:
                return nil
            }
        }
    }

    /// 在 `capture` 的统计之外附带脱敏后的调用内容与输出前若干行（用户可展开查看）。
    /// `argumentsJSON` 为模型给出的原始参数 JSON。
    /// `detailOutput` 给出时，统计仍按 `output`，展开用的正文取 `detailOutput`（调用方已按已知密钥处理过）。
    public static func captureWithDetail(toolName: String, argumentsJSON: String, output: String,
                                         detailOutput: String? = nil) -> ToolOutputSummary {
        let base = capture(toolName: toolName, output: output)
        let input = inputDetail(toolName: toolName, argumentsJSON: argumentsJSON)
        let body = outputDetail(toolName: toolName, output: detailOutput ?? output)
        guard input != nil || body.text != nil else { return base }
        return .withDetail(
            summary: base,
            detail: ToolCallDetail(input: input, output: body.text,
                                   omittedLines: body.omittedLines, isTruncated: body.truncated,
                                   fullOutputPath: fullOutputPath(output: output))
        )
    }

    /// 工具结果里已经落盘的完整输出路径：shell 的 stdout/stderr 落盘、web_fetch 全文、
    /// 以及 MCP 等工具返回的 full_output_path。只认绝对路径，不读文件内容。
    private static func fullOutputPath(output: String) -> String? {
        // MCP 超限输出是纯文本：末尾单独一行 "full_output_path: /绝对路径"。
        if output.first != "{", let range = output.range(of: "\nfull_output_path: ", options: .backwards) {
            let tail = output[range.upperBound...]
            let line = String(tail.prefix(while: { $0 != "\n" })).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("/"), !SensitiveFilePolicy.contains(line) { return line }
        }
        guard output.utf8.count <= 1_048_576,
              output.first == "{",
              let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var candidates: [String?] = [object["full_output_path"] as? String, object["full_content_path"] as? String]
        for key in ["stdout_artifact", "stderr_artifact"] {
            candidates.append((object[key] as? [String: Any])?["path"] as? String)
        }
        return candidates.compactMap { $0 }.first { $0.hasPrefix("/") && !SensitiveFilePolicy.contains($0) }
    }

    private static func inputDetail(toolName: String, argumentsJSON: String) -> String? {
        guard let data = argumentsJSON.data(using: .utf8), data.count <= 1_048_576,
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var value: String
        switch toolName {
        case "shell_execute":
            guard let command = args["command"] as? String else { return nil }
            value = command
        case "file_read", "file_write", "file_edit", "file_delete":
            guard let path = args["path"] as? String, !path.isEmpty else { return nil }
            value = SensitiveFilePolicy.contains(path) ? "敏感文件" : path
        case "file_grep", "file_glob":
            guard let pattern = args["pattern"] as? String, !pattern.isEmpty else { return nil }
            value = pattern
            if let path = args["path"] as? String, !path.isEmpty,
               !SensitiveFilePolicy.contains(path) {
                value += "\n范围：" + path
            }
        default:
            return nil
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.count > maxDetailInputCharacters { value = String(value.prefix(maxDetailInputCharacters)) + "…" }
        return ContentSecretRedactor.redact(value)
    }

    private static func outputDetail(toolName: String, output: String)
        -> (text: String?, omittedLines: Int, truncated: Bool) {
        var text = output
        if toolName == "shell_execute",
           let data = output.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["exit_code"] is Int,
           let stdout = object["stdout"] as? String,
           let stderr = object["stderr"] as? String {
            text = stderr.isEmpty ? stdout : (stdout.isEmpty ? stderr : stdout + "\n[标准错误]\n" + stderr)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (nil, 0, false) }
        var lines: [Substring] = []
        var used = 0
        var truncated = false
        var full = false
        var omitted = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if full || lines.count >= maxDetailLines { omitted += 1; continue }
            if used + line.count + 1 > maxDetailOutputCharacters {
                full = true
                truncated = true
                if lines.isEmpty {
                    lines.append(line.prefix(maxDetailOutputCharacters))
                } else {
                    omitted += 1
                }
                continue
            }
            used += line.count + 1
            lines.append(line)
        }
        let joined = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
        guard !joined.isEmpty else { return (nil, 0, false) }
        return (ContentSecretRedactor.redact(joined), omitted, truncated)
    }

    public static func capture(toolName: String, output: String) -> ToolOutputSummary {
        if toolName == "shell_execute",
           let data = output.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let exitCode = object["exit_code"] as? Int,
           let stdout = object["stdout"] as? String,
           let stderr = object["stderr"] as? String {
            let signals = diagnosticSignals(stdout: stdout, stderr: stderr)
            if !signals.isEmpty {
                return .shellWithSignals(
                    exitCode: exitCode,
                    stdoutBytes: stdout.utf8.count,
                    stdoutLines: lineCount(stdout),
                    stderrBytes: stderr.utf8.count,
                    stderrLines: lineCount(stderr),
                    signals: signals
                )
            }
            return .shell(
                exitCode: exitCode,
                stdoutBytes: stdout.utf8.count,
                stdoutLines: lineCount(stdout),
                stderrBytes: stderr.utf8.count,
                stderrLines: lineCount(stderr)
            )
        }
        if toolName == "file_write", let bytes = reportedWriteBytes(output) {
            return .textWithSignals(
                bytes: output.utf8.count,
                lines: lineCount(output),
                signals: [.reportedFileWrite(bytes: bytes)]
            )
        }
        if toolName == "file_edit", let edit = reportedEdit(output) {
            return .textWithSignals(
                bytes: output.utf8.count,
                lines: lineCount(output),
                signals: [.reportedFileEdit(replacements: edit.replacements, bytes: edit.bytes)]
            )
        }
        if toolName == SessionReadTool.toolName,
           let page = sessionReadPage(output) {
            return .textWithSignals(
                bytes: output.utf8.count,
                lines: lineCount(output),
                signals: [.sessionReadPage(messages: page.messages, total: page.total, hasMore: page.hasMore)]
            )
        }
        return .text(bytes: output.utf8.count, lines: lineCount(output))
    }

    /// Only fixed labels and integers cross into a conversation event.
    public var displaySuffix: String? {
        switch self {
        case .withDetail(let summary, _):
            return summary.displaySuffix
        case .text(let bytes, let lines):
            guard bytes >= 0, lines >= 0 else { return nil }
            return Self.metricsOnly("返回 \(bytes) 字节、\(lines) 行")
        case .shell(let exitCode, let stdoutBytes, let stdoutLines, let stderrBytes, let stderrLines):
            guard (0...255).contains(exitCode),
                  stdoutBytes >= 0, stdoutLines >= 0,
                  stderrBytes >= 0, stderrLines >= 0 else { return nil }
            return Self.metricsOnly("退出码 \(exitCode)；标准输出 \(stdoutBytes) 字节、\(stdoutLines) 行；标准错误 \(stderrBytes) 字节、\(stderrLines) 行")
        case .textWithSignals(let bytes, let lines, let signals):
            guard bytes >= 0, lines >= 0 else { return nil }
            return Self.withSignals(signals, metrics: "返回 \(bytes) 字节、\(lines) 行")
        case .shellWithSignals(let exitCode, let stdoutBytes, let stdoutLines, let stderrBytes, let stderrLines, let signals):
            guard (0...255).contains(exitCode),
                  stdoutBytes >= 0, stdoutLines >= 0,
                  stderrBytes >= 0, stderrLines >= 0 else { return nil }
            return Self.withSignals(
                signals,
                metrics: "退出码 \(exitCode)；标准输出 \(stdoutBytes) 字节、\(stdoutLines) 行；标准错误 \(stderrBytes) 字节、\(stderrLines) 行"
            )
        }
    }

    private static func withSignals(_ signals: [ContentSignal], metrics: String) -> String {
        // At most three fixed labels are emitted by capture. Persisted input
        // from an older or corrupt ledger cannot inject free-form prose here.
        let labels = signals.prefix(3).compactMap(\.displayLabel)
        return labels.isEmpty ? metricsOnly(metrics) : labels.joined(separator: "；") + "；" + metrics
    }

    private static func metricsOnly(_ metrics: String) -> String {
        // A size/exit-code measurement is not a summary of arbitrary text.
        // Put this status first so ConversationEvent's bounded projection
        // cannot trim away the distinction from a recognized content signal.
        "仅显示统计，结果正文未在此展示（该工具已真实执行并返回结果；正文按上下文策略未保留，需要时重新调用读取）；" + metrics
    }

    private static func reportedWriteBytes(_ output: String) -> Int? {
        // BuiltinToolExecutor.runFileWrite: "Wrote N bytes to <path>" plus
        // optional append/diff suffix. The path and suffix are never captured.
        captureIntegers(
            in: output,
            pattern: #"^Wrote ([0-9]+) bytes to [^\r\n]+$"#,
            groups: 1
        )?.first
    }

    private static func reportedEdit(_ output: String) -> (replacements: Int, bytes: Int)? {
        // BuiltinToolExecutor.runFileEdit: "Edited <path>: replaced N
        // occurrence(s) (M bytes written)." plus optional diff suffix.
        guard let values = captureIntegers(
            in: output,
            pattern: #"^Edited [^\r\n]+: replaced ([0-9]+) occurrence\(s\) \(([0-9]+) bytes written\)\.(?: \[diffID:[A-Za-z0-9-]+\])?$"#,
            groups: 2
        ) else { return nil }
        return (values[0], values[1])
    }

    private static func sessionReadPage(_ output: String) -> (messages: Int, total: Int, hasMore: Bool)? {
        // SessionReadTool owns this bounded, authorized page shape. Only its
        // counts and continuation flag cross the durable fact; session ID,
        // title, message text and cursor identity stay in the tool result.
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["ok"] as? Bool == true,
              object["tool"] as? String == SessionReadTool.toolName,
              object["scope"] as? String == "messages",
              let messages = object["messages"] as? [[String: Any]],
              let total = object["total"] as? Int,
              let offset = object["cursor_offset"] as? Int,
              let hasMore = object["has_more"] as? Bool,
              total >= 0, offset >= 0, offset <= total,
              messages.count <= total - offset else { return nil }
        return (messages.count, total, hasMore)
    }

    private static func captureIntegers(in output: String, pattern: String, groups: Int) -> [Int]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: output,
                  range: NSRange(output.startIndex..., in: output)
              ) else { return nil }
        var values: [Int] = []
        for index in 1...groups {
            guard let range = Range(match.range(at: index), in: output),
                  let value = Int(output[range]), value >= 0 else { return nil }
            values.append(value)
        }
        return values
    }

    private static func diagnosticSignals(stdout: String, stderr: String) -> [ContentSignal] {
        var errors = 0
        var warnings = 0
        var failedTests = 0
        for stream in [stdout, stderr] {
            stream.enumerateLines { line, _ in
                let value = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if value.hasPrefix("error:") || value.contains(": error:") || value.hasPrefix("fatal error:") {
                    errors += 1
                }
                if value.hasPrefix("warning:") || value.contains(": warning:") {
                    warnings += 1
                }
                if value.hasPrefix("✘ test ") || (value.hasPrefix("test case ") && value.hasSuffix(" failed")) {
                    failedTests += 1
                }
            }
        }
        var signals: [ContentSignal] = []
        if errors > 0 { signals.append(.diagnosticErrors(lines: errors)) }
        if warnings > 0 { signals.append(.diagnosticWarnings(lines: warnings)) }
        if failedTests > 0 { signals.append(.failedTests(lines: failedTests)) }
        return signals
    }

    private static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let newlines = text.utf8.reduce(into: 0) { count, byte in
            if byte == 0x0A { count += 1 }
        }
        return newlines + (text.utf8.last == 0x0A ? 0 : 1)
    }
}
