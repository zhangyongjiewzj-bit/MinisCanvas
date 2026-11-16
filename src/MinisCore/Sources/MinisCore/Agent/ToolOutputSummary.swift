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
