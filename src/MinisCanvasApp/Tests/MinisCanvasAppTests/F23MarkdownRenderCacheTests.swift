import Testing
import MinisCore
@testable import MinisCanvasApp

// MARK: - F23（Q8-r4 P2-4/P2-5）流式渲染缓存与稳定 id

@Suite("F23 Markdown 渲染缓存")
struct MarkdownRenderCacheTests {

    /// P2-5 核心：同一文本重复取 blocks 只 parse 一次（body 重算不重解析）。
    @Test func sameTextParsedOnce() {
        let cache = MarkdownRenderCache()
        let text = "# 标题\n\n正文 `code`"
        _ = cache.blocks(for: text)
        _ = cache.blocks(for: text)
        _ = cache.blocks(for: text)
        #expect(cache.parseCount == 1)
    }

    /// Streaming body 重算可能只改变父级状态；相同文本不能再次构建完整富文本。
    @Test func sameTextRenderStateBuiltOnce() {
        let cache = MarkdownRenderCache()
        let text = "# 标题\n\n正文 `code`"
        _ = cache.renderState(for: text, baseSize: 13)
        _ = cache.renderState(for: text, baseSize: 13)
        _ = cache.renderState(for: text, baseSize: 13)

        #expect(cache.renderStateBuildCount == 1)
    }

    /// 文本或字号变化都必须失效富文本状态，避免复用旧内容或旧字号。
    @Test func changedRenderStateRebuilds() {
        let cache = MarkdownRenderCache()
        _ = cache.renderState(for: "正文", baseSize: 13)
        _ = cache.renderState(for: "正文!", baseSize: 13)
        _ = cache.renderState(for: "正文!", baseSize: 14)

        #expect(cache.renderStateBuildCount == 3)
    }

    /// 文本变化才重新 parse（打字机逐 tick 场景每次新文本 parse 一次）。
    @Test func changedTextReparses() {
        let cache = MarkdownRenderCache()
        _ = cache.blocks(for: "a")
        _ = cache.blocks(for: "ab")
        _ = cache.blocks(for: "abc")
        _ = cache.blocks(for: "abc")
        #expect(cache.parseCount == 3)
    }

    /// 缓存结果与直接 parse 一致（不改变语义）。
    @Test func cachedResultMatchesDirectParse() {
        let cache = MarkdownRenderCache()
        let text = "```\ncode\n```\n\n| a |\n|---|\n| b |"
        #expect(cache.blocks(for: text) == MinisCore.MarkdownParser.parse(text))
    }

    /// P2-4：indexed 给未变块稳定 renderID——同一 blocks 序列两次 indexed，
    /// 对应项 id 完全相同（翻转只影响变化块，不牵连全列表重建）。
    @Test func indexedIDsStableForUnchangedBlocks() {
        let blocks = MinisCore.MarkdownParser.parse("# 标题\n\n段落一\n\n段落二")
        let first = MarkdownRenderCache.indexed(blocks).map(\.renderID)
        let second = MarkdownRenderCache.indexed(blocks).map(\.renderID)
        #expect(first == second)
        #expect(Set(first).count == first.count, "id 必须互不相同")
    }

    /// P2-4：流式表格定型翻转模拟——「| a | b |」先到（paragraph），
    /// 补上分隔行后定型（table）。翻转前后：未受影响的块（前置标题）id 不变，
    /// 且翻转后块数与语义正确。
    @Test func streamingTableFlipKeepsUnrelatedBlockIDs() {
        let before = MinisCore.MarkdownParser.parse("# 标题\n\n| a | b |")
        let after = MinisCore.MarkdownParser.parse("# 标题\n\n| a | b |\n|---|---|\n| 1 | 2 |")

        let beforeIDs = MarkdownRenderCache.indexed(before).map(\.renderID)
        let afterIDs = MarkdownRenderCache.indexed(after).map(\.renderID)

        // 前置标题块 id 稳定（不受表格翻转牵连）
        #expect(beforeIDs[0] == afterIDs[0], "未受影响的标题块 id 应稳定")

        // 翻转语义正确：before 是 paragraph，after 含 table
        #expect(before.contains { if case .paragraph = $0 { return true }; return false })
        #expect(after.contains { if case .table = $0 { return true }; return false })

        // 翻转块的 id 确实变了（差量更新只重建它）
        #expect(beforeIDs[1] != afterIDs[1], "翻转块 id 应变化以触发重建")
    }

    /// 空文本安全：parse 空串 → 空 blocks，缓存正常工作。
    @Test func emptyTextSafe() {
        let cache = MarkdownRenderCache()
        #expect(cache.blocks(for: "").isEmpty)
        _ = cache.blocks(for: "")
        #expect(cache.parseCount == 1)
        #expect(MarkdownRenderCache.indexed([]).isEmpty)
    }
}
