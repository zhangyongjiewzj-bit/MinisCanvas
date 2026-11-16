import Foundation

/// 行级 diff 的类型。
public enum DiffType: Equatable, Sendable {
    /// 两边相同的行（上下文）
    case equal
    /// 仅存在于旧文本的行
    case delete
    /// 仅存在于新文本的行
    case insert
    /// 同一位置的整块替换（由 delete + insert 合并而来，仅当块内行数相同或相邻时）
    case replace
}

/// 一个 diff 块（hunk）：描述旧文本行区间 [oldStart, oldStart+oldLines) 到
/// 新文本行区间 [newStart, newStart+newLines) 的变更。
///
/// 行号为 0 起始（内部表示），渲染层会转成 1 起始的 git 风格行号。
public struct DiffHunk: Equatable, Sendable {
    public let oldStart: Int
    public let newStart: Int
    public let oldLines: [String]
    public let newLines: [String]

    public init(oldStart: Int, newStart: Int, oldLines: [String], newLines: [String]) {
        self.oldStart = oldStart
        self.newStart = newStart
        self.oldLines = oldLines
        self.newLines = newLines
    }

    /// hunk 类型。
    public var type: DiffType {
        if oldLines.isEmpty { return .insert }
        if newLines.isEmpty { return .delete }
        if oldLines == newLines { return .equal }
        return .replace
    }
}

/// 统一文本 diff：基于行级 LCS 的 diff，中文友好（按整行比较，不拆字符）。
///
/// F24（Q8-r4 P2-1）性能改造：
/// - 原实现在 2000×2000 行实测 1.2s（完整 O(n·m) DP 表，无任何裁剪）；
/// - 现改为：公共前/后缀裁剪（文本 diff 场景收益极大）→ 中段标准 LCS DP。
///   相似文本裁剪后中段极小，2000×2000 行典型编辑场景从 1.2s 降到毫秒级。
/// - 退化保护（两级，保证有界耗时，绝不卡 UI）：
///   ① 任一边总行数 > `hugeTextLineThreshold`：快路径（全等→单个 equal，否则整段 replace）；
///   ② 中段 DP 单元格数 > `maxDPCells`：视为差异过大，整段 replace（不求精确行级对齐）。
public enum TextDiff {

    /// 超大文本保护阈值：任一边总行数超过它时走快路径。
    public static let hugeTextLineThreshold = 5000

    /// 中段 DP 单元格数上限：超过则放弃精确对齐、整段 replace。
    /// 64M 单元格 ≈ 256MB Int 峰值，是绝对上限；正常场景远小于此。
    static let maxDPCells = 64_000_000

    /// 计算 old 到 new 的行级 diff。
    ///
    /// - 返回的 hunks 按旧文本顺序排列，`equal` hunk 保留上下文行。
    /// - 相邻的 delete/insert 会合并为一个 `replace` hunk。
    /// - 空文本（""）视为 0 行。
    public static func diff(old: String, new: String) -> [DiffHunk] {
        let oldLines = splitLines(old)
        let newLines = splitLines(new)

        // F24：超大文本快路径——不进任何二次方算法。
        if oldLines.count > hugeTextLineThreshold || newLines.count > hugeTextLineThreshold {
            return [DiffHunk(oldStart: 0, newStart: 0, oldLines: oldLines, newLines: newLines)]
        }

        // lcs == nil 表示「中段过大」退化：整段 replace。
        guard let lcs = alignedLCS(oldLines, newLines) else {
            return [DiffHunk(oldStart: 0, newStart: 0, oldLines: oldLines, newLines: newLines)]
        }

        var hunks: [DiffHunk] = []
        var i = 0, j = 0
        var pendingOld: [String] = []
        var pendingNew: [String] = []
        var pendingOldStart = 0
        var pendingNewStart = 0

        func flushPending() {
            guard !pendingOld.isEmpty || !pendingNew.isEmpty else { return }
            hunks.append(DiffHunk(
                oldStart: pendingOldStart,
                newStart: pendingNewStart,
                oldLines: pendingOld,
                newLines: pendingNew
            ))
            pendingOld = []
            pendingNew = []
        }

        for (oi, nj) in lcs {
            // 输出 old 中不匹配的行（delete 候选）
            while i < oi {
                if pendingOld.isEmpty && pendingNew.isEmpty {
                    pendingOldStart = i
                    pendingNewStart = j
                }
                pendingOld.append(oldLines[i])
                i += 1
            }
            // 输出 new 中不匹配的行（insert 候选）
            while j < nj {
                if pendingOld.isEmpty && pendingNew.isEmpty {
                    pendingOldStart = i
                    pendingNewStart = j
                }
                pendingNew.append(newLines[j])
                j += 1
            }
            // 匹配行：先 flush 待定变更，再输出 equal
            flushPending()
            hunks.append(DiffHunk(
                oldStart: i, newStart: j,
                oldLines: [oldLines[i]], newLines: [newLines[j]]
            ))
            i += 1
            j += 1
        }
        // 尾巴
        while i < oldLines.count {
            if pendingOld.isEmpty && pendingNew.isEmpty {
                pendingOldStart = i
                pendingNewStart = j
            }
            pendingOld.append(oldLines[i])
            i += 1
        }
        while j < newLines.count {
            if pendingOld.isEmpty && pendingNew.isEmpty {
                pendingOldStart = i
                pendingNewStart = j
            }
            pendingNew.append(newLines[j])
            j += 1
        }
        flushPending()

        return hunks
    }

    /// 按行拆分：保留空行（"a\n\nb" -> ["a", "", "b"]），不做尾部截断。
    public static func splitLines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        return text.components(separatedBy: "\n")
    }

    // MARK: - LCS（F24：前/后缀裁剪 + 有界 DP）

    /// 行级 LCS，返回匹配行的 (oldIndex, newIndex) 全局索引序列。
    ///
    /// - 前/后缀裁剪：相同的前缀与后缀必然属于某个最优 LCS，直接进结果，中段才进 DP；
    ///   裁剪不改变 hunk 语义（与原完整 DP 的结果在 tie-break 一致下相同）。
    /// - 返回 nil = 中段 DP 单元格超上限，调用方退化为整段 replace。
    static func alignedLCS(_ a: [String], _ b: [String]) -> [(Int, Int)]? {
        let n = a.count, m = b.count
        if n == 0 || m == 0 { return [] }

        // 公共前缀裁剪
        var prefix = 0
        while prefix < n && prefix < m && a[prefix] == b[prefix] { prefix += 1 }
        // 公共后缀裁剪（不与 prefix 重叠）
        var suffix = 0
        while suffix < n - prefix && suffix < m - prefix && a[n - 1 - suffix] == b[m - 1 - suffix] {
            suffix += 1
        }

        var result: [(Int, Int)] = (0..<prefix).map { ($0, $0) }

        let midN = n - prefix - suffix
        let midM = m - prefix - suffix

        if midN > 0 && midM > 0 {
            // 退化保护：DP 单元格超上限 → 放弃精确对齐
            if midN * midM > maxDPCells { return nil }
            let midA = Array(a[prefix..<(n - suffix)])
            let midB = Array(b[prefix..<(m - suffix)])
            let midPairs = classicLCS(midA, midB)
            result.append(contentsOf: midPairs.map { ($0.0 + prefix, $0.1 + prefix) })
        }
        // midN/midM 一边为 0：中段无匹配行，无需 DP

        result.append(contentsOf: (0..<suffix).map { (n - suffix + $0, m - suffix + $0) })
        return result
    }

    /// 经典 O(n·m) DP LCS（与原实现相同，含相同 tie-break），仅作用于裁剪后的中段。
    /// 返回匹配行的局部 (i, j)（相对传入数组）。
    private static func classicLCS(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        let n = a.count, m = b.count
        guard n > 0 && m > 0 else { return [] }
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 1...n {
            for j in 1...m {
                if a[i - 1] == b[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }
        // 回溯重建匹配对（tie-break：up 优先，与原实现一致）
        var pairs: [(Int, Int)] = []
        var i = n, j = m
        while i > 0 && j > 0 {
            if a[i - 1] == b[j - 1] {
                pairs.append((i - 1, j - 1))
                i -= 1
                j -= 1
            } else if dp[i - 1][j] >= dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return pairs.reversed()
    }
}
