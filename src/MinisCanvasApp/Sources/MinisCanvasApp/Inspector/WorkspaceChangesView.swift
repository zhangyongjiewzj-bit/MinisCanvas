import SwiftUI
import MinisCore

/// 只读的“工作区改动”页：git status + git diff HEAD，含命令行造成的改动。
/// 输出已封顶并脱敏；敏感文件只列名字。不提供任何写入操作。
struct WorkspaceChangesView: View {
    let directory: String?
    @State private var result: WorkspaceGitChanges?
    @State private var isLoading = false
    @Environment(\.typographyTokens) private var typography

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("工作区改动（只读）").font(typography?.contextBody ?? .body)
                Spacer()
                Button(isLoading ? "读取中…" : "刷新") { Task { await reload() } }
                    .disabled(isLoading || directory == nil)
            }
            Text("来自 git status 与 git diff HEAD，包含命令行造成的改动；敏感文件只显示文件名。")
                .font(typography?.caption ?? .caption).foregroundStyle(.secondary)
            if let result {
                if let notice = result.notice {
                    Text(notice).font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                }
                if result.entries.isEmpty, result.notice == nil {
                    Text("工作区干净，没有未提交的改动。")
                        .font(typography?.contextBody ?? .body).foregroundStyle(.secondary)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(result.entries) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Text(entry.status).font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Text(entry.path).lineLimit(2).truncationMode(.middle)
                                if entry.isSensitive {
                                    Text("敏感文件，内容不显示").font(.caption).foregroundStyle(.secondary)
                                } else if entry.status == "??" {
                                    Text("新文件，内容不在下面的差异里").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .font(typography?.caption ?? .caption)
                        }
                        if !result.diff.isEmpty {
                            Divider()
                            ScrollView(.horizontal) {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    let lines = result.diff.split(separator: "\n", omittingEmptySubsequences: false)
                                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                        Text(String(line))
                                            .font(.system(.caption, design: .monospaced))
                                            .fontWeight(Self.isFileHeader(line) ? .bold : .regular)
                                            .foregroundStyle(Self.lineColor(line))
                                            .fixedSize(horizontal: true, vertical: false)
                                    }
                                }
                                .textSelection(.enabled)
                            }
                            if result.diffTruncated {
                                Text("输出过长，已截断显示；完整内容请在终端查看 git diff。")
                                    .font(typography?.caption ?? .caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else if directory == nil {
                Text("当前会话没有工作目录。").foregroundStyle(.secondary)
            }
        }
        .task(id: directory) { await reload() }
        .accessibilityIdentifier("changes.workspace")
    }

    private static func isFileHeader(_ line: Substring) -> Bool { line.hasPrefix("diff --git") }

    private static func lineColor(_ line: Substring) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .secondary }
        if line.hasPrefix("+") { return AppStatusColor.success }
        if line.hasPrefix("-") { return AppStatusColor.danger }
        if line.hasPrefix("@@") { return AppStatusColor.info }
        return .primary
    }

    private func reload() async {
        guard let directory, !isLoading else { return }
        isLoading = true
        let loaded = await WorkspaceGitChanges.load(directory: directory)
        result = loaded
        isLoading = false
    }
}
