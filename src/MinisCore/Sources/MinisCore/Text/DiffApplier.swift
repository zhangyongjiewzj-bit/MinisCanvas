import Foundation

/// 把 `[DiffHunk]` 应用到原文，返回新文本；遇到冲突返回 nil。
///
/// 应用时逐 hunk 校验原文对应行与 `oldLines` 完全一致（行级三向校验），
/// 任何不匹配都视为冲突，返回 nil，绝不产生错误合并。
public enum DiffApplier {

    /// 将 `patches` 应用到 `original`。
    ///
    /// - 要求 hunks 按旧文本顺序排列且行号与原文一致（`TextDiff.diff` 的输出满足）。
    /// - 成功返回应用后的完整新文本；冲突（原文行与 hunk 的 oldLines 不符）
    ///   返回 nil。
    public static func apply(original: String, patches: [DiffHunk]) -> String? {
        var lines = TextDiff.splitLines(original)
        // 从后往前应用，避免行号偏移
        for hunk in patches.reversed() {
            guard hunk.oldStart >= 0, hunk.oldStart <= lines.count else { return nil }
            let end = hunk.oldStart + hunk.oldLines.count
            guard end <= lines.count else { return nil }
            // 校验原文行
            for (offset, expected) in hunk.oldLines.enumerated() {
                if lines[hunk.oldStart + offset] != expected { return nil }
            }
            // 替换区间
            lines.replaceSubrange(hunk.oldStart..<end, with: hunk.newLines)
        }
        return lines.joined(separator: "\n")
    }

    /// 便捷方法：`diff` + `apply` 一步完成。
    public static func applyDiff(original: String, new: String) -> String? {
        let patches = TextDiff.diff(old: original, new: new)
        return apply(original: original, patches: patches)
    }

    /// 校验 `patches` 是否能无冲突地应用到 `original`（不修改文本）。
    public static func canApply(original: String, patches: [DiffHunk]) -> Bool {
        apply(original: original, patches: patches) != nil
    }
}
