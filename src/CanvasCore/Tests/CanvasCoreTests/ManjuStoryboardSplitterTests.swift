import Testing
import Foundation
@testable import CanvasCore

// MARK: - P1 分镜批量展开：文本切分器（画布逻辑审查 P1 缺口修复）

@Suite struct ManjuStoryboardSplitterTests {

    @Test("镜号行识别：第N镜/镜N/镜头N/N、/N. 均为分镜起始行")
    func markerLineRecognition() {
        #expect(ManjuStoryboardSplitter.isMarkerLine("第1镜：魏衔踏雾而来"))
        #expect(ManjuStoryboardSplitter.isMarkerLine("第 12 镜 特写"))
        #expect(ManjuStoryboardSplitter.isMarkerLine("镜3 转身"))
        #expect(ManjuStoryboardSplitter.isMarkerLine("镜头 5 全景"))
        #expect(ManjuStoryboardSplitter.isMarkerLine("2、近景"))
        #expect(ManjuStoryboardSplitter.isMarkerLine("7. 中景"))
        #expect(ManjuStoryboardSplitter.isMarkerLine("  第2镜 缩进也识别"))
        #expect(!ManjuStoryboardSplitter.isMarkerLine("他走向第1镜的方向"))
        #expect(!ManjuStoryboardSplitter.isMarkerLine("普通对白行"))
        #expect(!ManjuStoryboardSplitter.isMarkerLine(""))
    }

    @Test("按镜号行切分：每镜一段，含镜号行文本")
    func splitByMarkerLines() {
        let script = """
        第1镜：魏衔踏雾而来，长袍翻卷。
        他停下，望向山门。
        第2镜：大殿内，香炉青烟。
        第3镜：神像暗部，朱砂一点。
        """
        let segments = ManjuStoryboardSplitter.split(script: script)
        #expect(segments.count == 3)
        #expect(segments[0].contains("第1镜"))
        #expect(segments[0].contains("望向山门"))
        #expect(segments[1].contains("第2镜"))
        #expect(segments[1].contains("香炉青烟"))
        #expect(segments[2].contains("第3镜"))
    }

    @Test("无镜号行时按空行分段")
    func splitByBlankLines() {
        let script = """
        第一个段落：山门。
        山风。

        第二个段落：大殿。

        第三个段落：神像。
        """
        let segments = ManjuStoryboardSplitter.split(script: script)
        #expect(segments.count == 3)
        #expect(segments[0].contains("山门"))
        #expect(segments[1].contains("大殿"))
        #expect(segments[2].contains("神像"))
    }

    @Test("空文本返回 0 段（调用方不展开）；单段返回 1")
    func emptyAndSingleSegment() {
        #expect(ManjuStoryboardSplitter.split(script: "").isEmpty)
        #expect(ManjuStoryboardSplitter.split(script: "   \n  ").isEmpty)
        #expect(ManjuStoryboardSplitter.split(script: "只有一个镜头的文本").count == 1)
    }

    @Test("段数上限 24（对齐 storyboardCount 约定）")
    func capsAtMaxSegments() {
        let lines = (1...40).map { "第\($0)镜：镜头内容\($0)" }
        let segments = ManjuStoryboardSplitter.split(script: lines.joined(separator: "\n"))
        #expect(segments.count == ManjuStoryboardSplitter.maxSegments)
    }

    @Test("单个镜号行不触发切分（可能是正文提及），走空行分段")
    func singleMarkerFallsBackToBlankLines() {
        let script = """
        他念道：第1镜不过是障眼法。
        继续前行。

        第二段。
        """
        let segments = ManjuStoryboardSplitter.split(script: script)
        #expect(segments.count == 2)
    }
}
