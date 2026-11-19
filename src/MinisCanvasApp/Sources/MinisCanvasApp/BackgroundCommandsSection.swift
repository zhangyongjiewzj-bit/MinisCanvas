import AppKit
import SwiftUI
import MinisCore

/// Task-centre block that lists `shell_execute run_in_background` commands.
/// It only reads registry snapshots and stops a command through the registry,
/// which signals the recorded private process group. It renders nothing while
/// no background command has ever been started in this app run.
///
/// The registry is a reference type, so SwiftUI cannot see its contents change.
/// This section therefore owns a small 0.5 s `TimelineView`: each tick re-reads
/// the snapshots and is the clock for the elapsed-time text. The rest of the
/// Task Center no longer ticks with it.
struct BackgroundCommandsSection: View {
    let registry: BackgroundShellRegistry
    /// Session id -> title, passed in by the Task Center (no extra observation here).
    let sessionTitles: [String: String]
    @Environment(\.typographyTokens) private var typography
    @State private var expandedID: String?

    static func statusLabel(_ state: BackgroundShellState) -> String {
        switch state {
        case .running: return "运行中"
        case .interrupted: return "应用中断后已恢复登记"
        case .outputFailure: return "输出保存失败，已停止"
        case .exited: return "已结束"
        case .timedOut: return "已超时终止"
        case .stopped: return "已停止"
        case .terminatedBySessionEnd: return "会话结束时终止"
        case .terminatedByApplicationExit: return "退出应用时终止"
        }
    }

    static func detailLine(_ snapshot: BackgroundShellSnapshot, now: Date = Date()) -> String {
        var parts = [statusLabel(snapshot.state), "用时 \(Int(snapshot.elapsed(now: now))) 秒"]
        if snapshot.state == .exited, let code = snapshot.exitCode { parts.append("退出码 \(code)") }
        if let note = snapshot.endNote, snapshot.state != .exited {
            if snapshot.state == .stopped, note == "stopped by shell_stop" {
                parts.append("由智能体停止")
            } else {
                parts.append(note)
            }
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let rows = registry.snapshots()
            if !rows.isEmpty {
                let labels = TaskCenterRowLabelFormatter.sourceLabels(
                    ids: rows.map(\.sessionID), knownTitles: sessionTitles
                )
                VStack(alignment: .leading, spacing: 8) {
                    Text("后台命令（\(rows.filter { $0.state == .running }.count) 个运行中）")
                        .font(typography?.headline ?? .headline)
                    ForEach(rows) { row in
                        commandRow(row, now: context.date, sessionLabel: labels[row.sessionID] ?? "来源会话不可用")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("task-center-background-commands")
            }
        }
    }

    /// 输出可滚动，各取最后 64KB；标准输出和标准错误分开显示，可在访达中显示完整日志。
    @ViewBuilder
    private func outputView(row: BackgroundShellSnapshot,
                            output: (stdout: String, stderr: String, logPath: String?)) -> some View {
        let font = typography?.monospaced ?? .system(.caption, design: .monospaced)
        VStack(alignment: .leading, spacing: 6) {
            if output.stdout.isEmpty && output.stderr.isEmpty {
                Text(row.outputDiscarded ? "（会话已结束，输出已清除）" : "（暂无输出）")
                    .font(font).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if !output.stdout.isEmpty {
                            Text("标准输出").font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                            Text(output.stdout)
                                .font(font).foregroundStyle(.secondary).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("background-command-output-\(row.id)")
                        }
                        if !output.stderr.isEmpty {
                            Text("标准错误").font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                            Text(output.stderr)
                                .font(font).foregroundStyle(.secondary).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("background-command-stderr-\(row.id)")
                        }
                    }
                }
                .frame(maxHeight: 220)
                Text("只显示最后 64KB，更早的内容在完整日志里。")
                    .font(typography?.caption ?? .caption).foregroundStyle(.secondary)
            }
            if let path = output.logPath, FileManager.default.fileExists(atPath: path) {
                Button("在访达中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("background-command-reveal-\(row.id)")
            }
        }
    }

    @ViewBuilder
    private func commandRow(_ row: BackgroundShellSnapshot, now: Date, sessionLabel: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(row.commandPreview)
                    .font(typography?.monospaced ?? .system(.body, design: .monospaced))
                    .lineLimit(1)
                    .accessibilityIdentifier("background-command-title-\(row.id)")
                Spacer(minLength: 8)
                if row.state == .running {
                    Button("停止") { registry.stop(id: row.id, reason: .user) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel("停止后台命令")
                        .accessibilityIdentifier("background-command-stop-\(row.id)")
                }
                Button(expandedID == row.id ? "收起输出" : "查看输出") {
                    expandedID = expandedID == row.id ? nil : row.id
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("background-command-output-toggle-\(row.id)")
            }
            Text("会话：\(sessionLabel) · " + Self.detailLine(row, now: now))
                .font(typography?.caption ?? .caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("background-command-status-\(row.id)")
            if expandedID == row.id, let output = registry.displayOutput(id: row.id) {
                outputView(row: row, output: output)
            }
        }
    }
}
