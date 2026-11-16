import Testing
import Foundation
@testable import MinisCanvasApp

// MARK: - F16b 文档 AI 流水线：纯数据模型测试
// 覆盖：模板加载 / 增删 / moveStage 顺序 / markDownstreamStale 传播 / Codable 往返。

@Suite("F16b 漫剧六阶段模板")
struct ManjuDocumentTemplateTests {
    @Test func templateHasSixStagesInOrder() {
        let p = ManjuDocumentTemplate.make()
        #expect(p.stages.count == 6)
        #expect(p.stages.map(\.name) == [
            "小说导入", "剧情大纲", "剧本", "分镜", "图片提示词", "视频提示词",
        ])
        #expect(p.currentIndex == 0)
    }

    @Test func templateStagesStartPendingWithEmptyModelSelection() {
        let p = ManjuDocumentTemplate.make()
        for stage in p.stages {
            #expect(stage.status == .pending)
            #expect(stage.providerID.isEmpty)
            #expect(stage.modelID.isEmpty)
            #expect(stage.input.isEmpty)
            #expect(stage.output.isEmpty)
            #expect(!stage.promptTemplate.isEmpty)
            #expect(stage.promptTemplate.contains(ManjuDocumentTemplate.inputPlaceholder))
        }
        // 每个阶段模板带中文占位提示（抽查首尾）
        #expect(p.stages.first!.promptTemplate.contains("小说原文"))
        #expect(p.stages.last!.promptTemplate.contains("视频生成提示词"))
    }

    @Test func templateMakesFreshIDsPerCall() {
        let a = ManjuDocumentTemplate.make()
        let b = ManjuDocumentTemplate.make()
        #expect(Set(a.stages.map(\.id)).isDisjoint(with: Set(b.stages.map(\.id))))
    }
}

@Suite("F16b DocumentPipeline 增删")
struct DocumentPipelineAddRemoveTests {
    @Test func appendMaintainsOrderAndFocus() {
        var p = DocumentPipeline()
        #expect(p.stages.isEmpty)
        #expect(p.currentIndex == 0)
        #expect(p.nextPendingIndex == nil)

        p.appendStage(DocumentStage(name: "A"))
        #expect(p.currentIndex == 0)
        p.appendStage(DocumentStage(name: "B"))
        p.appendStage(DocumentStage(name: "C"))
        #expect(p.stages.map(\.name) == ["A", "B", "C"])
        #expect(p.currentIndex == 0) // 追加不动焦点
    }

    @Test func removeShiftsAndClampsCurrentIndex() {
        var p = ManjuDocumentTemplate.make()
        p.currentIndex = 3 // 「分镜」

        // 删焦点之后的阶段：焦点不动
        let removed = p.removeStage(at: 4)
        #expect(removed?.name == "图片提示词")
        #expect(p.stages.count == 5)
        #expect(p.currentIndex == 3)

        // 删焦点之前的阶段：焦点前移一位，仍指向「分镜」
        p.removeStage(at: 0)
        #expect(p.stages.count == 4)
        #expect(p.currentIndex == 2)
        #expect(p.stages[p.currentIndex].name == "分镜")

        // 越界删除为无操作
        #expect(p.removeStage(at: 99) == nil)
        #expect(p.removeStage(at: -1) == nil)
        #expect(p.stages.count == 4)
    }

    @Test func removeLastStageResetsIndex() {
        var p = DocumentPipeline(stages: [DocumentStage(name: "only")])
        p.removeStage(at: 0)
        #expect(p.stages.isEmpty)
        #expect(p.currentIndex == 0)
    }
}

@Suite("F16b moveStage 顺序")
struct DocumentPipelineMoveTests {
    @Test func moveForwardAndBackward() {
        var p = ManjuDocumentTemplate.make()
        // 「剧本」(2) 移到末尾 (5)
        p.moveStage(from: 2, to: 5)
        #expect(p.stages.map(\.name) == [
            "小说导入", "剧情大纲", "分镜", "图片提示词", "视频提示词", "剧本",
        ])
        // 「剧本」(5) 移回原位 (2)
        p.moveStage(from: 5, to: 2)
        #expect(p.stages.map(\.name) == [
            "小说导入", "剧情大纲", "剧本", "分镜", "图片提示词", "视频提示词",
        ])
    }

    @Test func moveNoOpOnOutOfBoundsOrSameIndex() {
        var p = ManjuDocumentTemplate.make()
        let before = p.stages
        p.moveStage(from: 0, to: 0)
        p.moveStage(from: -1, to: 2)
        p.moveStage(from: 1, to: 99)
        #expect(p.stages == before)
    }
}

@Suite("F16b markDownstreamStale 传播")
struct DocumentPipelineStaleTests {
    @Test func downstreamStagesMarkedStaleUpstreamUntouched() {
        var p = ManjuDocumentTemplate.make()
        p.stages[0].status = .done
        p.stages[1].status = .done
        p.stages[2].status = .awaitingReview

        // 回跳编辑「剧情大纲」(index 1)
        p.markDownstreamStale(fromIndex: 1)

        #expect(p.stages[0].status == .done)           // 上游不动
        #expect(p.stages[1].status == .done)           // 自身不动（由编辑方决定）
        #expect(p.stages[2].status == .stale)
        #expect(p.stages[3].status == .stale)
        #expect(p.stages[4].status == .stale)
        #expect(p.stages[5].status == .stale)
    }

    @Test func staleFromLastIndexIsNoOp() {
        var p = ManjuDocumentTemplate.make()
        for i in p.stages.indices { p.stages[i].status = .done }
        p.markDownstreamStale(fromIndex: 5)
        #expect(p.stages.allSatisfy { $0.status == .done })
        // 越界无操作
        p.markDownstreamStale(fromIndex: 99)
        p.markDownstreamStale(fromIndex: -1)
        #expect(p.stages.allSatisfy { $0.status == .done })
    }

    @Test func nextPendingIndexSkipsNonPendingAndFindsStale() {
        var p = ManjuDocumentTemplate.make()
        #expect(p.nextPendingIndex == 0)

        p.stages[0].status = .done
        #expect(p.nextPendingIndex == 1)

        p.stages[1].status = .running
        #expect(p.nextPendingIndex == 2)

        p.markDownstreamStale(fromIndex: 1) // 2... 全部 stale
        #expect(p.nextPendingIndex == nil) // stale 不算 pending
    }
}

@Suite("F16b Codable 往返")
struct DocumentPipelineCodableTests {
    @Test func roundTripPreservesPipeline() throws {
        var p = ManjuDocumentTemplate.make()
        p.stages[0].input = "第一章 少年下山……"
        p.stages[0].output = "（整理后正文）"
        p.stages[0].status = .done
        p.stages[1].providerID = "bailian"
        p.stages[1].modelID = "qwen3.8-max-preview"
        p.stages[1].status = .awaitingReview
        p.stages[2].status = .stale
        p.currentIndex = 1

        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(DocumentPipeline.self, from: data)

        #expect(decoded == p)
        #expect(decoded.stages.map(\.name) == p.stages.map(\.name))
        #expect(decoded.stages.map(\.status) == p.stages.map(\.status))
        #expect(decoded.stages.map(\.id) == p.stages.map(\.id))
        #expect(decoded.currentIndex == 1)
    }

    @Test func stageStatusRawValuesAreStable() throws {
        // 持久化契约：rawValue 字符串固定，改动会破坏已存盘文档
        #expect(StageStatus.pending.rawValue == "pending")
        #expect(StageStatus.running.rawValue == "running")
        #expect(StageStatus.awaitingReview.rawValue == "awaitingReview")
        #expect(StageStatus.done.rawValue == "done")
        #expect(StageStatus.stale.rawValue == "stale")

        let stage = DocumentStage(name: "剧本", status: .stale)
        let decoded = try JSONDecoder().decode(
            DocumentStage.self, from: JSONEncoder().encode(stage))
        #expect(decoded == stage)
    }
}
