import Foundation
import Testing
@testable import MinisCore

struct TextDiffTests {

    // MARK: - diff 行识别

    @Test func identicalTextYieldsOnlyEqualHunks() {
        let hunks = TextDiff.diff(old: "a\nb\nc", new: "a\nb\nc")
        #expect(hunks.allSatisfy { $0.type == .equal })
        #expect(hunks.count == 3)
    }

    @Test func insertionDetected() {
        let hunks = TextDiff.diff(old: "a\nc", new: "a\nb\nc")
        let inserts = hunks.filter { $0.type == .insert }
        #expect(inserts.count == 1)
        #expect(inserts[0].newLines == ["b"])
        #expect(inserts[0].oldLines.isEmpty)
    }

    @Test func deletionDetected() {
        let hunks = TextDiff.diff(old: "a\nb\nc", new: "a\nc")
        let deletes = hunks.filter { $0.type == .delete }
        #expect(deletes.count == 1)
        #expect(deletes[0].oldLines == ["b"])
        #expect(deletes[0].newLines.isEmpty)
    }

    @Test func replacementDetected() {
        let hunks = TextDiff.diff(old: "a\nold\nc", new: "a\nnew\nc")
        let replaces = hunks.filter { $0.type == .replace }
        #expect(replaces.count == 1)
        #expect(replaces[0].oldLines == ["old"])
        #expect(replaces[0].newLines == ["new"])
    }

    @Test func emptyInputs() {
        #expect(TextDiff.diff(old: "", new: "").isEmpty)
        let hunks = TextDiff.diff(old: "", new: "a\nb")
        #expect(hunks.count == 1)
        #expect(hunks[0].type == .insert)
        #expect(hunks[0].newLines == ["a", "b"])
    }

    @Test func singleLineDiff() {
        // 单行旧文本 -> 单行新文本：整块替换；相同则单个 equal
        let replaced = TextDiff.diff(old: "hello", new: "world")
        #expect(replaced.count == 1)
        #expect(replaced[0].type == .replace)
        #expect(replaced[0].oldLines == ["hello"])
        #expect(replaced[0].newLines == ["world"])
        #expect(replaced[0].oldStart == 0 && replaced[0].newStart == 0)

        let identical = TextDiff.diff(old: "hello", new: "hello")
        #expect(identical.count == 1)
        #expect(identical[0].type == .equal)
    }

    @Test func pureAdditionOnlyInserts() {
        // 纯新增：旧文本是新的前缀，不产生任何 delete
        let hunks = TextDiff.diff(old: "a\nb", new: "a\nb\nc\nd")
        #expect(hunks.allSatisfy { $0.type != .delete })
        let inserts = hunks.filter { $0.type == .insert }
        #expect(inserts.count == 1)
        #expect(inserts[0].newLines == ["c", "d"])
        #expect(inserts[0].oldLines.isEmpty)
        #expect(inserts[0].oldStart == 2 && inserts[0].newStart == 2)
    }

    @Test func pureDeletionOnlyDeletes() {
        // 纯删除：新文本是旧的前缀，不产生任何 insert
        let hunks = TextDiff.diff(old: "a\nb\nc", new: "a")
        #expect(hunks.allSatisfy { $0.type != .insert })
        let deletes = hunks.filter { $0.type == .delete }
        #expect(deletes.count == 1)
        #expect(deletes[0].oldLines == ["b", "c"])
        #expect(deletes[0].newLines.isEmpty)
        #expect(deletes[0].oldStart == 1 && deletes[0].newStart == 1)
    }

    @Test func hunkStartPositionsAreOrderedAndZeroBased() {
        // 多个 hunk：oldStart/newStart 从 0 起始且随文本顺序递增
        let hunks = TextDiff.diff(old: "a\nb\nc\nd", new: "a\nX\nc\nY")
        #expect(hunks.map(\.type) == [.equal, .replace, .equal, .replace])
        #expect(hunks.map(\.oldStart) == [0, 1, 2, 3])
        #expect(hunks.map(\.newStart) == [0, 1, 2, 3])
        #expect(hunks[1].oldLines == ["b"] && hunks[1].newLines == ["X"])
        #expect(hunks[3].oldLines == ["d"] && hunks[3].newLines == ["Y"])
    }

    @Test func trailingNewlineRoundTrip() {
        // 经典坑：尾部换行 —— diff + apply 必须稳定还原
        let old = "第一行\n"
        let new = "第一行\n第二行\n"
        #expect(DiffApplier.applyDiff(original: old, new: new) == new)
        // 尾部追加一个空行（"a\nb\n" -> "a\nb\n\n"）
        #expect(DiffApplier.applyDiff(original: "a\nb\n", new: "a\nb\n\n") == "a\nb\n\n")
        // 尾部空行被删除
        #expect(DiffApplier.applyDiff(original: "a\nb\n\n", new: "a\nb\n") == "a\nb\n")
    }

    @Test func chineseLinesDiff() {
        let old = "第一行\n保持不变\n旧句子"
        let new = "第一行\n保持不变\n新句子\n多了一行"
        let hunks = TextDiff.diff(old: old, new: new)
        // 相邻的删除+插入合并为一个 replace：旧句子 -> 新句子 + 多了一行
        let replaces = hunks.filter { $0.type == .replace }
        #expect(replaces.count == 1)
        #expect(replaces[0].oldLines == ["旧句子"])
        #expect(replaces[0].newLines == ["新句子", "多了一行"])
    }

    @Test func emptyLinesPreserved() {
        let hunks = TextDiff.diff(old: "a\n\nb", new: "a\n\n\nb")
        let inserts = hunks.filter { $0.type == .insert }
        #expect(inserts.count == 1)
        #expect(inserts[0].newLines == [""])
    }

    // MARK: - changeStats

    @Test func changeStatsCountsLines() {
        let old = "1\n2\n3\n4\n5"
        let new = "1\nX\n3\n4\n6\n7"
        let stats = DiffRenderer.changeStats(TextDiff.diff(old: old, new: new))
        #expect(stats.additions == 3)   // X, 6, 7
        #expect(stats.deletions == 2)   // 2, 5
    }

    @Test func changeStatsEmpty() {
        let stats = DiffRenderer.changeStats([])
        #expect(stats.additions == 0)
        #expect(stats.deletions == 0)
    }

    // MARK: - unified 渲染

    @Test func unifiedRenderShowsMarkers() {
        let hunks = TextDiff.diff(old: "a\nold\nc", new: "a\nnew\nc")
        let text = DiffRenderer.renderUnified(hunks)
        #expect(text.contains("-old"))
        #expect(text.contains("+new"))
        #expect(text.contains(" a"))
    }

    @Test func unifiedWithHeadersHasHunkHeader() {
        let hunks = TextDiff.diff(old: "a\nb\nc\nd\ne\nf\ng", new: "a\nb\nX\nd\ne\nf\ng")
        let text = DiffRenderer.renderUnifiedWithHeaders(hunks)
        #expect(text.hasPrefix("@@ "))
        #expect(text.contains("+X"))
        #expect(text.contains("-c"))
    }

    @Test func unifiedWithHeadersLineNumbersAndGroups() {
        // 两处不相邻的修改 → 两个独立 @@ 组；行号 1 起始且与上下文窗口一致
        let old = (0..<20).map { "l\($0)" }.joined(separator: "\n")
        var newLines = (0..<20).map { "l\($0)" }
        newLines[2] = "X2"
        newLines[17] = "Y17"
        let text = DiffRenderer.renderUnifiedWithHeaders(TextDiff.diff(old: old, new: newLines.joined(separator: "\n")))
        let headers = text.components(separatedBy: "\n").filter { $0.hasPrefix("@@") }
        #expect(headers == ["@@ -1,6 +1,6 @@", "@@ -15,6 +15,6 @@"])
        #expect(text.contains("-l2") && text.contains("+X2"))
        #expect(text.contains("-l17") && text.contains("+Y17"))
    }

    // MARK: - markdown 渲染

    @Test func markdownRenderHasTableAndStats() {
        let hunks = TextDiff.diff(old: "a\nold\nc", new: "a\nnew\nc")
        let md = DiffRenderer.renderMarkdown(hunks)
        #expect(md.contains("变更摘要"))
        #expect(md.contains("|"))
        #expect(md.contains("✏️"))
    }

    @Test func markdownEscapesPipes() {
        let hunks = TextDiff.diff(old: "x", new: "a|b")
        let md = DiffRenderer.renderMarkdown(hunks)
        #expect(md.contains("a\\|b"))
    }

    // MARK: - apply 往返

    @Test func applyRoundTrip() {
        let old = "第一行\n第二行\n第三行\n第四行"
        let new = "第一行\n修改行\n第三行\n新增行\n第四行"
        let patches = TextDiff.diff(old: old, new: new)
        let applied = DiffApplier.apply(original: old, patches: patches)
        #expect(applied == new)
    }

    @Test func applyEmptyOriginal() {
        let patches = TextDiff.diff(old: "", new: "a\nb")
        #expect(DiffApplier.apply(original: "", patches: patches) == "a\nb")
    }

    @Test func applyNoChanges() {
        let patches = TextDiff.diff(old: "x\ny", new: "x\ny")
        #expect(DiffApplier.apply(original: "x\ny", patches: patches) == "x\ny")
    }

    @Test func applyConflictReturnsNil() {
        let patches = TextDiff.diff(old: "a\nb", new: "a\nX")
        // 原文已被改动，oldLines 不匹配 -> 冲突
        #expect(DiffApplier.apply(original: "a\nCHANGED", patches: patches) == nil)
    }

    @Test func applyDiffHelperRoundTrip() {
        let old = "版本一的内容\n第二行"
        let new = "版本二的内容\n第二行\n第三行"
        #expect(DiffApplier.applyDiff(original: old, new: new) == new)
    }

    @Test func canApplyDetectsConflict() {
        let patches = TextDiff.diff(old: "a\nb", new: "a\nX")
        #expect(DiffApplier.canApply(original: "a\nb", patches: patches))
        #expect(!DiffApplier.canApply(original: "a\nOTHER", patches: patches))
    }

    // MARK: - 中文内容完整往返

    @Test func chineseRoundTrip() {
        let old = """
        这是第一行
        保持不变的中间行
        需要删除的旧行
        末尾行
        """
        let new = """
        这是第一行
        保持不变的中间行
        新增的中文行
        修改后的末尾行
        """
        let patches = TextDiff.diff(old: old, new: new)
        #expect(DiffApplier.apply(original: old, patches: patches) == new)
    }

    // MARK: - F24：性能与退化保护

    /// 2000×2000 行相似文本（典型编辑场景）应快速完成。
    /// 前/后缀裁剪后中段极小，实测应远低于旧实现的 1.2s。
    @Test func largeSimilarTextDiffPerformance() {
        var oldLines: [String] = []
        var newLines: [String] = []
        for i in 0..<2000 {
            let line = "行内容 \(i)：这是第 \(i) 行的文本数据"
            oldLines.append(line)
            newLines.append(i >= 1000 && i < 1010 ? "修改后的行 \(i)" : line)
        }
        let old = oldLines.joined(separator: "\n")
        let new = newLines.joined(separator: "\n")

        let start = Date()
        let hunks = TextDiff.diff(old: old, new: new)
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 0.5, "2000×2000 行 diff 耗时 \(elapsed)s，应 <0.5s")
        let replaces = hunks.filter { $0.type == .replace }
        #expect(!replaces.isEmpty, "应检测到修改区域")
    }

    /// 超大文本（>5000 行）走快路径：全等→单 equal，不等→单 replace。
    @Test func hugeTextFastPath() {
        let lines = (0..<6000).map { "第 \($0) 行" }
        let text = lines.joined(separator: "\n")

        let equalHunks = TextDiff.diff(old: text, new: text)
        #expect(equalHunks.count == 1)
        #expect(equalHunks[0].type == .equal)

        let modified = (lines.dropLast(1) + ["不同的最后一行"]).joined(separator: "\n")
        let diffHunks = TextDiff.diff(old: text, new: modified)
        #expect(diffHunks.count == 1)
        #expect(diffHunks[0].type == .replace)
    }

    /// 前后缀裁剪正确性：裁剪不改变 diff 语义，DiffApplier 往返仍成立。
    @Test func prefixSuffixTrimPreservesSemantics() {
        let old = "共同前缀行1\n共同前缀行2\n旧中间行\n共同后缀行1\n共同后缀行2"
        let new = "共同前缀行1\n共同前缀行2\n新中间行\n额外行\n共同后缀行1\n共同后缀行2"
        let hunks = TextDiff.diff(old: old, new: new)
        let equalCount = hunks.filter { $0.type == .equal }.count
        #expect(equalCount >= 4, "前后缀行应识别为 equal")
        let applied = DiffApplier.apply(original: old, patches: hunks)
        #expect(applied == new, "裁剪后 diff 仍应支持往返 apply")
    }
}
