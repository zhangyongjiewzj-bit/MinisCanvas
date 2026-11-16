import Testing
@testable import CanvasCore

/// Regression coverage for task-ticket strings that previously displayed the
/// interpolation expression literally instead of the runtime value.
struct LegacyInterpolationBehaviorTests {
    @Test func taskTicketLinesInterpolateNodeTitleAndSlotCount() {
        let node = CanvasNode(type: ManjuNodeType.videoGen.rawValue, title: "视频任务")
        let markdown = GraphExecutionContext.fallbackVideoTicketMarkdown(
            node: node,
            prompt: "[MODE]\nI2V"
        )

        #expect(markdown.contains("# 生成任务单 · 视频任务"))
        #expect(markdown.contains("## 完整提示词（9 槽，复制到网页版逐槽粘贴）"))
        #expect(!markdown.contains(#"\(node.title)"#))
        #expect(!markdown.contains(#"\(template.slots.count)"#))
    }
}
