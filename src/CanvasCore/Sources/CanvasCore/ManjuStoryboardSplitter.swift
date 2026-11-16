import Foundation

// MARK: - P1 分镜批量展开：文本切分器
//
// 漫剧一集几十镜，画布上靠手动复制分镜节点不现实（画布逻辑审查 P1 缺口）。
// 批量展开 = 读取分镜节点内容 → 切成 N 个分镜片段 → 替换为 N 个分镜节点。
// 本文件只做纯文本切分（可单测），图结构变更在 CanvasStore.expandStoryboard。

public enum ManjuStoryboardSplitter {

    /// 最多展开数（对齐 ManjuPipeline.storyboardCount 上限 24）
    public static let maxSegments = 24

    /// 镜号行正则：行首「第N镜/镜N/镜头N/第N幕/第N场/Shot N/N、/N./N：/N:」。
    /// 匹配即视为一个分镜的起始行（铁律：分镜表常用「第1镜：描述」格式）。
    private static let markerPattern = #"^\s*(?:第?\s*(\d{1,3})\s*[镜幕场]|[镜幕场]\s*(\d{1,3})|镜头\s*(\d{1,3})|Shot\s*(\d{1,3})|(\d{1,3})\s*[、.．:：\-])"#

    /// 判断一行是否为镜号起始行（行首标记，纯函数）
    public static func isMarkerLine(_ line: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: markerPattern) else { return false }
        let ns = line as NSString
        return regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil
    }

    /// 把脚本文本切分为分镜片段：
    /// 1. 优先按「镜号行」切（至少 2 个镜号行才启用——单个可能是正文提及）；
    /// 2. 否则按空行分段；
    /// 3. 最少 1 段（空文本返回 0，调用方据此不展开）；最多 24 段；每段 trim 非空。
    public static func split(script: String) -> [String] {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let lines = trimmed.components(separatedBy: "\n")
        let markerIndices = lines.enumerated()
            .filter { isMarkerLine($0.element) }
            .map { $0.offset }

        var segments: [String] = []
        if markerIndices.count >= 2 {
            // 镜号行切分：每镜从镜号行到下一镜号行前
            for (k, start) in markerIndices.enumerated() {
                let end = k + 1 < markerIndices.count ? markerIndices[k + 1] : lines.count
                let seg = lines[start..<end]
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !seg.isEmpty { segments.append(seg) }
            }
        } else {
            // 空行分段
            segments = trimmed
                .components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        if segments.isEmpty { segments = [trimmed] }
        return Array(segments.prefix(maxSegments))
    }
}
