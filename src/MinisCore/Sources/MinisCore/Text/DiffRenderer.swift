import Foundation

/// 把 `[DiffHunk]` 渲染成各种可读格式。
public enum DiffRenderer {

    /// 变更统计：(新增行数, 删除行数)。
    public static func changeStats(_ hunks: [DiffHunk]) -> (additions: Int, deletions: Int) {
        var additions = 0
        var deletions = 0
        for hunk in hunks {
            switch hunk.type {
            case .insert:
                additions += hunk.newLines.count
            case .delete:
                deletions += hunk.oldLines.count
            case .replace:
                additions += hunk.newLines.count
                deletions += hunk.oldLines.count
            case .equal:
                break
            }
        }
        return (additions, deletions)
    }

    /// 渲染为 unified diff 文本（类似 `git diff`，1 起始行号，hunk 头 `@@ -a,b +c,d @@`）。
    public static func renderUnified(_ hunks: [DiffHunk]) -> String {
        var out: [String] = []
        for hunk in hunks {
            switch hunk.type {
            case .equal:
                for line in hunk.oldLines {
                    out.append(" " + line)
                }
            case .insert:
                for line in hunk.newLines {
                    out.append("+" + line)
                }
            case .delete:
                for line in hunk.oldLines {
                    out.append("-" + line)
                }
            case .replace:
                for line in hunk.oldLines {
                    out.append("-" + line)
                }
                for line in hunk.newLines {
                    out.append("+" + line)
                }
            }
        }
        return out.joined(separator: "\n")
    }

    /// 渲染为带 `@@` hunk 头的完整 unified diff（供 git-apply 风格消费）。
    public static func renderUnifiedWithHeaders(_ hunks: [DiffHunk]) -> String {
        // 1. 收集变更组：每组 = 变更 + 前/后最多 3 行上下文，重叠的合并
        struct Group { var start: Int; var end: Int }
        var groups: [Group] = []
        for (idx, h) in hunks.enumerated() where h.type != .equal {
            let s = max(0, idx - 3)
            var e = min(hunks.count - 1, idx + 3)
            var j = idx + 1
            while j < hunks.count && hunks[j].type != .equal {
                e = min(hunks.count - 1, j + 3)
                j += 1
            }
            if let last = groups.last, s <= last.end + 1 {
                groups[groups.count - 1].end = max(last.end, e)
            } else {
                groups.append(Group(start: s, end: e))
            }
        }
        if groups.isEmpty {
            var lines: [String] = []
            for h in hunks {
                for l in h.oldLines { lines.append(" " + l) }
            }
            return lines.joined(separator: "\n")
        }

        // 2. 输出每个组
        var out: [String] = []
        for g in groups {
            let slice = Array(hunks[g.start...g.end])
            let oldStart = slice[0].oldStart + 1
            let newStart = slice[0].newStart + 1
            var oc = 0, nc = 0
            for h in slice {
                oc += h.oldLines.count
                nc += h.newLines.count
            }
            out.append("@@ -\(oldStart),\(oc) +\(newStart),\(nc) @@")
            for h in slice {
                switch h.type {
                case .equal:
                    for l in h.oldLines { out.append(" " + l) }
                case .insert:
                    for l in h.newLines { out.append("+" + l) }
                case .delete:
                    for l in h.oldLines { out.append("-" + l) }
                case .replace:
                    for l in h.oldLines { out.append("-" + l) }
                    for l in h.newLines { out.append("+" + l) }
                }
            }
        }
        return out.joined(separator: "\n")
    }

    /// 渲染为 Markdown（聊天友好）：表格展示每一处变更。
    public static func renderMarkdown(_ hunks: [DiffHunk]) -> String {
        let (add, del) = changeStats(hunks)
        var out: [String] = []
        out.append("变更摘要：+\(add) / -\(del) 行")
        out.append("")
        out.append("| 类型 | 旧行 | 新行 |")
        out.append("| --- | --- | --- |")
        for hunk in hunks {
            switch hunk.type {
            case .equal:
                break // 上下文不展示
            case .insert:
                for line in hunk.newLines {
                    out.append("| ➕ 新增 | — | `\(escape(line))` |")
                }
            case .delete:
                for line in hunk.oldLines {
                    out.append("| ➖ 删除 | `\(escape(line))` | — |")
                }
            case .replace:
                for line in hunk.oldLines {
                    out.append("| ✏️ 修改 | `\(escape(line))` | — |")
                }
                for line in hunk.newLines {
                    out.append("| ✏️ 修改 | — | `\(escape(line))` |")
                }
            }
        }
        return out.joined(separator: "\n")
    }

    /// 渲染为紧凑行列表（每行带 +/-/ 前缀，无表头），适合代码块展示。
    public static func renderLines(_ hunks: [DiffHunk]) -> String {
        renderUnified(hunks)
    }

    private static func escape(_ line: String) -> String {
        line.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "`", with: "\\`")
    }
}
