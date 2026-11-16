import Testing
import Foundation
@testable import CanvasCore

// MARK: - P2 分镜表工作台：数据模型测试
//
// 设计文档：issues/p2_storyboard_design_20260805.md §3 数据模型契约 + §8 测试计划
// 覆盖：Codable round-trip、JSON 契约键形状、§3.2 示例 JSON 可解码、
//       reviewStatus 三态归一与 label。

@Suite struct StoryboardModelsTests {

    @Test("Codable round-trip：编码→解码→相等（全字段）")
    func codableRoundTrip() throws {
        let row = StoryboardRow(
            sceneIndex: 1,
            title: "分镜1",
            prompt: "[MODE]9槽视频提示词全文",
            imageRefs: ["/a.png", "/b.png"],
            videoRefs: ["/s1.mp4"],
            reviewStatus: .pass,
            notes: "打回意见",
            nodeIDs: [UUID(), UUID()]
        )
        let table = StoryboardTable(title: "分镜表", rows: [row], sourceNodeID: UUID())
        let data = try JSONEncoder().encode(table)
        let decoded = try JSONDecoder().decode(StoryboardTable.self, from: data)
        #expect(decoded == table)
        #expect(decoded.rows.count == 1)
    }

    @Test("JSON 形状：reviewStatus 大写字符串编码、契约键存在、nil 可选键编码为 null")
    func jsonShapeUsesContractKeys() throws {
        let row = StoryboardRow(sceneIndex: 1, title: "分镜1", reviewStatus: .pass)
        let table = StoryboardTable(rows: [row])
        let data = try JSONEncoder().encode(table)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"reviewStatus\":\"PASS\""))
        #expect(json.contains("\"sceneIndex\":1"))
        // nil 可选键按 Swift Codable 合成编码默认省略（非显式 null）；
        // 解码端缺失即 nil，与文档示例（显式 null）双向兼容。
        #expect(!json.contains("sourceNodeID"))
        #expect(json.contains("\"title\":\"分镜表\""))
    }

    @Test("reviewStatus.fromParams：PASS/REJECT/PENDING/未知/缺失 全部归一")
    func reviewStatusFromParams() {
        #expect(StoryboardReviewStatus.fromParams(["review.status": "PASS"]) == .pass)
        #expect(StoryboardReviewStatus.fromParams(["review.status": "REJECT"]) == .reject)
        #expect(StoryboardReviewStatus.fromParams(["review.status": "PENDING"]) == .pending)
        #expect(StoryboardReviewStatus.fromParams(["review.status": "未知值"]) == .pending)
        #expect(StoryboardReviewStatus.fromParams(["review.status": "pass"]) == .pending) // 大小写敏感
        #expect(StoryboardReviewStatus.fromParams(nil) == .pending)
        #expect(StoryboardReviewStatus.fromParams([:]) == .pending)
    }

    @Test("reviewStatus.label：通过/打回/待审")
    func reviewStatusLabels() {
        #expect(StoryboardReviewStatus.pass.label == "通过")
        #expect(StoryboardReviewStatus.reject.label == "打回")
        #expect(StoryboardReviewStatus.pending.label == "待审")
    }

    @Test("设计文档 §3.2 JSON 示例可解码（ISO8601 日期策略）")
    func designJSONExampleDecodable() throws {
        let json = """
        {
          "id": "8D660B1A-0000-0000-0000-000000000001",
          "title": "分镜表",
          "rows": [
            {
              "id": "A1B2C3D4-0000-0000-0000-000000000001",
              "sceneIndex": 1,
              "title": "分镜1",
              "prompt": "[MODE]9槽视频提示词全文",
              "imageRefs": ["/path/frame1.png", "/path/asset-face-8angle.png"],
              "videoRefs": ["/path/shot1.mp4"],
              "reviewStatus": "PASS",
              "notes": "",
              "nodeIDs": ["11111111-1111-1111-1111-111111111111",
                           "22222222-2222-2222-2222-222222222222"]
            }
          ],
          "sourceNodeID": null,
          "updatedAt": "2026-08-05T10:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let table = try decoder.decode(StoryboardTable.self, from: Data(json.utf8))
        #expect(table.title == "分镜表")
        #expect(table.rows.count == 1)
        #expect(table.rows[0].sceneIndex == 1)
        #expect(table.rows[0].title == "分镜1")
        #expect(table.rows[0].reviewStatus == .pass)
        #expect(table.rows[0].imageRefs == ["/path/frame1.png", "/path/asset-face-8angle.png"])
        #expect(table.rows[0].videoRefs == ["/path/shot1.mp4"])
        #expect(table.rows[0].nodeIDs.count == 2)
        #expect(table.sourceNodeID == nil)
    }
}
