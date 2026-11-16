import SwiftUI
import MinisCore

/// Task-centre block that lists `shell_execute run_in_background` commands.
/// It only reads registry snapshots and stops a command through the registry,
/// which signals the recorded private process group. It renders nothing while
/// no background command has ever been started in this app run.
///
/// The registry is a reference type, so SwiftUI cannot see its contents change.
/// The enclosing `TimelineView` (0.5 s) therefore passes its tick as `now`:
/// a changed input forces `body` to re-run and re-read the snapshots, and it
/// is also the clock for the elapsed-time text.
struct BackgroundCommandsSection: View {
    let registry: BackgroundShellRegistry
    /// The timeline tick; see the type comment. Do not default it.
    let now: Date
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
        let rows = registry.snapshots()
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("后台命令（\(rows.filter { $0.state == .running }.count) 个运行中）")
                    .font(typography?.headline ?? .headline)
                ForEach(rows) { row in
                    commandRow(row)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("task-center-background-commands")
        }
    }

    @ViewBuilder
    private func commandRow(_ row: BackgroundShellSnapshot) -> some View {
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
            Text("会话：\(row.sessionID) · " + Self.detailLine(row, now: now))
                .font(typography?.caption ?? .caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("background-command-status-\(row.id)")
            if expandedID == row.id, let tail = registry.tail(id: row.id) {
                let text = [tail.stdout, tail.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
                Text(text.isEmpty ? (row.outputDiscarded ? "（会话已结束，输出已清除）" : "（暂无输出）") : text)
                    .font(typography?.monospaced ?? .system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(12)
                    .accessibilityIdentifier("background-command-output-\(row.id)")
            }
        }
    }
}
