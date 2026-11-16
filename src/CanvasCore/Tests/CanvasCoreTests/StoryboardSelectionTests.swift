import Testing
import Foundation
@testable import CanvasCore

/// 行选中定位（R5-P0-1 修复）：只依赖图内稳定锚点 nodeIDs，不依赖随机行 id。
/// 视图层 StoryboardWorkbenchView 的选中判定/滚动定位全部走这两个纯函数。
struct StoryboardSelectionTests {
    private let a1 = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let a2 = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let a3 = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    private func makeTable() -> StoryboardTable {
        StoryboardTable(rows: [
            StoryboardRow(sceneIndex: 1, title: "镜1", prompt: "段落A", nodeIDs: [a1]),
            StoryboardRow(sceneIndex: 2, title: "镜1", prompt: "段落B", nodeIDs: [a1]),
            StoryboardRow(sceneIndex: 3, title: "镜2", prompt: "", nodeIDs: [a2, a3]),
        ])
    }

    // MARK: row(containing:)

    @Test func rowHitByAnchor() throws {
        let table = makeTable()
        let row = try #require(StoryboardAggregator.row(containing: a2, in: table))
        #expect(row.sceneIndex == 3)
        #expect(row.nodeIDs.contains(a2))
    }

    @Test func rowNilWhenAnchorMissing() {
        let table = makeTable()
        let ghost = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        #expect(StoryboardAggregator.row(containing: ghost, in: table) == nil)
    }

    @Test func rowNilWhenAnchorIsNil() {
        let table = makeTable()
        #expect(StoryboardAggregator.row(containing: nil, in: table) == nil)
    }

    /// 未展开多段分镜：多行共享同一锚点 → first 命中第一镜（既有语义，行 id 随机不得改变该结果）
    @Test func multiSegmentRowsShareAnchorHitsFirst() throws {
        let table = makeTable()
        let row = try #require(StoryboardAggregator.row(containing: a1, in: table))
        #expect(row.sceneIndex == 1)
        #expect(row.prompt == "段落A")
    }

    // MARK: index(ofRowContaining:)

    @Test func indexStableAcrossRebuilds() {
        // 行 id 每次聚合随机（UUID() 默认），但 nodeIDs/行序确定 → 下标跨聚合稳定
        let first = StoryboardAggregator.index(ofRowContaining: a1, in: makeTable())
        let second = StoryboardAggregator.index(ofRowContaining: a1, in: makeTable())
        #expect(first == second)
        #expect(first == 0)
    }

    @Test func indexHitAndMiss() {
        let table = makeTable()
        #expect(StoryboardAggregator.index(ofRowContaining: a3, in: table) == 2)
        #expect(StoryboardAggregator.index(ofRowContaining: nil, in: table) == nil)
    }
}
