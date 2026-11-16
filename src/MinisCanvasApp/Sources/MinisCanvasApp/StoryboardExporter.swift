import Foundation
import AppKit
import CanvasCore

// MARK: - P2 分镜表工具栏批量操作：导出 / 逐镜提示词 / 全部展开
//
// 设计文档：issues/p2_storyboard_design_20260805.md §5.2 工具栏
// 结构约定（任务书 P2 子线要求）：
//   - 可测逻辑（JSON/Markdown/汇总文本/文件名/可展开节点收集）全部下沉为本文件纯函数，
//     不依赖 UI 与文件系统，可定向单测；
//   - 写盘 / 剪贴板 / 批量展开入口在 CanvasStore 扩展：仅做「生成内容 → 落盘/复制 →
//     statusMessage 提示」，验证路径走逻辑测试（临时目录），不触发 GUI 弹窗。

/// P2 分镜表导出 / 批量操作的纯函数集合（无 UI、无 IO 副作用，可单测）。
enum StoryboardExporter {

    // MARK: 导出 JSON

    /// StoryboardTable → JSON 字符串（prettyPrinted + sortedKeys；非 ASCII 原样输出，中文不转义）。
    static func exportJSON(_ table: StoryboardTable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(table)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: 导出 Markdown（分镜脚本表）

    /// StoryboardTable → Markdown 分镜脚本表：
    /// `# 标题` / 每镜 `## 镜号.标题` + 提示词 + 参考图路径 + 审核状态 + 备注。
    static func exportMarkdown(_ table: StoryboardTable) -> String {
        var lines: [String] = []
        lines.append("# \(table.title)")
        lines.append("")
        for row in table.rows {
            lines.append("## \(String(format: "%02d", row.sceneIndex)). \(row.title)")
            lines.append("")
            lines.append("**提示词**")
            lines.append("")
            lines.append(row.prompt.isEmpty ? "（无）" : row.prompt)
            lines.append("")
            lines.append("**参考图路径**")
            lines.append("")
            if row.imageRefs.isEmpty {
                lines.append("（无）")
            } else {
                lines.append(contentsOf: row.imageRefs.map { "- \($0)" })
            }
            lines.append("")
            lines.append("**审核状态**")
            lines.append("")
            lines.append(row.reviewStatus.label)
            lines.append("")
            lines.append("**锚点**")
            lines.append("")
            if let anchor = row.anchor {
                lines.append(String(format: "(%.2f, %.2f)", anchor.x, anchor.y))
            } else {
                lines.append("（无）")
            }
            lines.append("")
            lines.append("**备注**")
            lines.append("")
            lines.append(row.notes.isEmpty ? "（无）" : row.notes)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: 逐镜提示词汇总（「逐镜生成提示词」按钮的数据源）

    /// 逐镜提示词汇总文本：每镜一行「镜号.标题」，随后是本镜提示词全文；
    /// 空提示词标注（无）。供「逐镜生成提示词」按钮写入剪贴板 / 导出。
    static func promptSummaryText(_ table: StoryboardTable) -> String {
        var lines: [String] = []
        lines.append("【逐镜提示词】\(table.title)")
        lines.append("")
        for row in table.rows {
            lines.append("\(String(format: "%02d", row.sceneIndex)). \(row.title)")
            lines.append(row.prompt.isEmpty ? "（无）" : row.prompt)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: 导出文件名

    /// 导出文件名（不含扩展名）：`MinisCanvas-分镜表-yyyyMMdd_HHmmss`。
    /// date 可注入以便测试断言精确值。
    static func exportFileName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "MinisCanvas-分镜表-\(formatter.string(from: date))"
    }

    // MARK: 全部展开（可展开节点收集）

    /// 收集图中所有分镜节点 id（y 主、x 次排序，与聚合器锚点排序一致）。
    /// 「全部展开」按钮据此遍历调用 CanvasStore.expandStoryboard(nodeID:)；
    /// expandStoryboard 对内容不足 2 段的节点返回 1 不改图（幂等），
    /// 因此重复点击不会重复展开。
    static func expandableStoryboardNodeIDs(in graph: NodeGraph) -> [UUID] {
        graph.nodes
            .filter { $0.type == ManjuNodeType.storyboard.rawValue }
            .sorted { a, b in
                if a.position.y != b.position.y { return a.position.y < b.position.y }
                return a.position.x < b.position.x
            }
            .map(\.id)
    }
}

// MARK: - CanvasStore 扩展：按钮只做「生成内容 → 落盘/复制 → statusMessage」

extension CanvasStore {

    /// 导出分镜表 JSON 到 Downloads（或指定目录）。返回落盘路径；失败返回 nil 并设 statusMessage。
    /// 验证路径传临时目录（NSTemporaryDirectory），不污染用户 Downloads。
    @discardableResult
    func exportStoryboardJSON(to directory: URL? = nil) -> String? {
        let table = storyboardTable
        do {
            let json = try StoryboardExporter.exportJSON(table)
            let dir = directory ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(StoryboardExporter.exportFileName() + ".json")
            try json.write(to: url, atomically: true, encoding: .utf8)
            statusMessage = "已导出分镜表 JSON：\(url.path)"
            return url.path
        } catch {
            statusMessage = "导出 JSON 失败：\(error.localizedDescription)"
            return nil
        }
    }

    /// 导出分镜表 Markdown 到 Downloads（或指定目录）。返回落盘路径；失败返回 nil 并设 statusMessage。
    @discardableResult
    func exportStoryboardMarkdown(to directory: URL? = nil) -> String? {
        let table = storyboardTable
        do {
            let md = StoryboardExporter.exportMarkdown(table)
            let dir = directory ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(StoryboardExporter.exportFileName() + ".md")
            try md.write(to: url, atomically: true, encoding: .utf8)
            statusMessage = "已导出分镜表 Markdown：\(url.path)"
            return url.path
        } catch {
            statusMessage = "导出 Markdown 失败：\(error.localizedDescription)"
            return nil
        }
    }

    /// 「逐镜生成提示词」：收集全部行 prompt 拼接为汇总文本，写入剪贴板。
    /// 设计文档 §5.2 原语义为「逐镜调 OptimizePromptService 回填草稿」，但 §9 标注
    /// 该直调需总控批准（消耗 token）；本轮按任务书低风险候选实现为「拼接汇总 → 剪贴板」，
    /// 直调服务留待批准后接入（按钮语义点已预留）。
    /// - Returns: 参与汇总的镜数（剪贴板写入失败仍返回镜数，statusMessage 注明）。
    @discardableResult
    func copyPromptSummaryToPasteboard() -> Int {
        let table = storyboardTable
        let text = StoryboardExporter.promptSummaryText(table)
        NSPasteboard.general.clearContents()
        let ok = NSPasteboard.general.setString(text, forType: .string)
        statusMessage = ok
            ? "已复制 \(table.rows.count) 镜提示词汇总到剪贴板"
            : "复制提示词汇总到剪贴板失败"
        return table.rows.count
    }

    /// 「全部展开」：遍历所有分镜节点逐个调 expandStoryboard（幂等），返回实际展开段数。
    /// 已展开 / 内容不足 2 段的节点返回 1 不改图，重复点击安全。
    @discardableResult
    func expandAllStoryboards() -> Int {
        let ids = StoryboardExporter.expandableStoryboardNodeIDs(in: graph)
        var total = 0
        for id in ids {
            let n = expandStoryboard(nodeID: id)
            if n > 1 { total += n }
        }
        statusMessage = total > 0
            ? "已全部展开为 \(total) 个分镜节点"
            : "没有可展开的分镜（内容不足 2 段）"
        return total
    }
}
