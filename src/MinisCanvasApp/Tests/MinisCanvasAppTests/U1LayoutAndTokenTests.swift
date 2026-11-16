import Testing
import Foundation
import CoreGraphics
import CanvasCore
@testable import MinisCanvasApp

// MARK: - U1 布局重构：
// 画布视图 = 主内容 + 左侧伴随对话栏（替代底部全局对话条）；
// B17（2026-08-06）：文档视图重新梳理——去掉伴随对话栏（四栏嵌套挤压：
// 240+310+420+240=1210 > 窗口960），输入统一走底部全局通栏；
// token 状态行去 C: 前缀乱码 → 「已用 x / y tokens」；
// 连线几何：控制点与端点同画布坐标统一乘 zoom（修复拖线控制点错位）。

@Suite("U1 布局重构：伴随对话 + token 文案 + 连线几何")
@MainActor
struct U1LayoutAndTokenTests {

    // MARK: - 布局策略：画布视图对话在左（伴随栏）；文档视图用底部通栏输入；聊天视图保留全局对话条

    @Test func chatPaneKeepsGlobalComposer() {
        // 聊天主视图（三栏主区或聊天独占）→ 不用伴随栏，保留底部全局对话条
        #expect(!LayoutPolicy.usesCompanionChat(layoutMode: .split, mainPane: .chat))
        #expect(!LayoutPolicy.usesCompanionChat(layoutMode: .chat, mainPane: .canvas))
        #expect(!LayoutPolicy.usesCompanionChat(layoutMode: .chat, mainPane: .chat))
    }

    @Test func canvasPaneUsesCompanionChat() {
        // 三栏主区切画布 / 画布独占 → 对话在左侧伴随栏，底部全局条隐藏
        #expect(LayoutPolicy.usesCompanionChat(layoutMode: .split, mainPane: .canvas))
        #expect(LayoutPolicy.usesCompanionChat(layoutMode: .canvas, mainPane: .canvas))
        #expect(LayoutPolicy.usesCompanionChat(layoutMode: .canvas, mainPane: .chat))
        #expect(!LayoutPolicy.usesCompanionChat(layoutMode: .split, mainPane: .chat))
    }

    @Test func globalComposerAlwaysHidden() {
        // 2026-08-06 工作板块整体移除：底部全局通栏无场景 → 恒 false。
        // 聊天输入在分栏内、画布输入在伴随栏内；原 documents 场景（B17 底部通栏）已随工作区删除。
        #expect(!LayoutPolicy.showsGlobalComposer(layoutMode: .split, mainPane: .canvas))
        #expect(!LayoutPolicy.showsGlobalComposer(layoutMode: .canvas, mainPane: .canvas))
        #expect(!LayoutPolicy.showsGlobalComposer(layoutMode: .chat, mainPane: .chat))
    }

    // MARK: - token 状态行文案（去 C: 前缀乱码，用户可读）

    @Test func tokenLabelIsHumanReadableWithoutCPrefix() {
        let label = ChatStore.tokenUsageLabel(used: 1_200, cap: 100_000)
        #expect(label == "已用 1.2k / 100k tokens")
        #expect(!label.hasPrefix("C:"))
        #expect(!label.contains("C:1.2k"))
    }

    @Test func tokenLabelZeroAndFull() {
        #expect(ChatStore.tokenUsageLabel(used: 0, cap: 100_000) == "已用 0 / 100k tokens")
        #expect(ChatStore.tokenUsageLabel(used: 100_000, cap: 100_000) == "已用 100k / 100k tokens")
    }

    @Test func tokenLabelSmallAndMillion() {
        #expect(ChatStore.tokenUsageLabel(used: 999, cap: 999) == "已用 999 / 999 tokens")
        #expect(ChatStore.tokenUsageLabel(used: 1_300_000, cap: 1_000_000) == "已用 1.3m / 1m tokens")
    }

    @Test func tokenLabelUsesBudgetNameArgs() {
        // 与 E8 预算接线一致：used = budgetUsedTokens / cap = budgetCapTokens
        let chat = ChatStore()
        chat.recordTokens(1_200)
        let label = ChatStore.tokenUsageLabel(used: chat.budgetUsedTokens, cap: chat.budgetCapTokens)
        #expect(label == "已用 1.2k / 1m tokens")
    }

    // MARK: - 连线几何（控制点与端点同画布坐标，统一乘 zoom）

    @Test func controlOffsetUsesHalfDistanceOrMinimum() {
        // 近距：至少 50 画布单位（防近距线过弯）
        #expect(EdgeGeometry.controlOffset(from: Point(x: 0, y: 0), to: Point(x: 10, y: 0)) == 50)
        // 中距：水平距离一半
        #expect(EdgeGeometry.controlOffset(from: Point(x: 0, y: 0), to: Point(x: 200, y: 0)) == 100)
        // 远距：封顶 150（第二层病根：长距离边不再无限放大控制点 → 防大回环）
        #expect(EdgeGeometry.controlOffset(from: Point(x: 0, y: 0), to: Point(x: 1_000, y: 0)) == 150)
        #expect(EdgeGeometry.controlOffset(from: Point(x: 0, y: 0), to: Point(x: 10_000, y: 0)) == 150)
    }

    @Test func autoDirectionByGeometry() {
        // 目标在源右侧（正向）：+1
        #expect(EdgeGeometry.autoDirection(from: Point(x: 0, y: 0), to: Point(x: 200, y: 0)) == 1.0)
        // 同轴/等宽（不反向）：+1
        #expect(EdgeGeometry.autoDirection(from: Point(x: 0, y: 0), to: Point(x: 0, y: 0)) == 1.0)
        // 目标在源左侧（反向边）：-1（第二层病根：旧硬编码 1.0 导致反向边大回环）
        #expect(EdgeGeometry.autoDirection(from: Point(x: 500, y: 300), to: Point(x: 100, y: 300)) == -1.0)
    }

    @Test func reverseEdgeControlPointsBendLeftward() {
        // 反向边：终节点在源左侧 → 控制点应向左凸且封顶（不画大回环）
        let from = Point(x: 800, y: 300)
        let to = Point(x: 100, y: 300)
        let (c1, c2) = EdgeGeometry.controlPoints(
            from: from, to: to,
            direction: EdgeGeometry.autoDirection(from: from, to: to)
        )
        // 从源右边缘向左凸、从目标左边缘向左收 → 曲线在两端之间，不绕到右侧
        #expect(c1.x < from.x && c2.x > to.x)
        #expect(c1.x >= to.x && c2.x <= from.x)
        // 远距封顶：偏移不超过 150
        #expect(from.x - c1.x <= EdgeGeometry.maxControlOffset)
        #expect(c2.x - to.x <= EdgeGeometry.maxControlOffset)
    }

    @Test func controlPointsFollowDirectionAwareness() {
        // 输出→输入（正向）：控制点向右凸
        let (c1, c2) = EdgeGeometry.controlPoints(
            from: Point(x: 300, y: 300), to: Point(x: 600, y: 300), direction: 1
        )
        #expect(c1.x == 450 && c1.y == 300)
        #expect(c2.x == 450 && c2.y == 300)
        // 输入口反向拖线（direction = -1）：控制点向左凸（E17 方向感知语义）
        let (r1, r2) = EdgeGeometry.controlPoints(
            from: Point(x: 600, y: 300), to: Point(x: 300, y: 300), direction: -1
        )
        #expect(r1.x == 450 && r1.y == 300)
        #expect(r2.x == 450 && r2.y == 300)
    }

    @Test func controlPointsShareCanvasCoordinateSpaceWithEndpoints() {
        // U1 回归：控制点与端点同属画布坐标（渲染统一乘 zoom）——
        // 旧 pendingEdgeLayer 控制点漏乘 zoom，zoom≠1 时拖线不从端口正确发出。
        let from = Point(x: 300, y: 300)
        let to = Point(x: 600, y: 300)
        let (c1, c2) = EdgeGeometry.controlPoints(from: from, to: to, direction: 1)
        for zoom in [0.5, 1.0, 2.0] {
            let f = CGPoint(x: from.x * zoom, y: from.y * zoom)
            let t = CGPoint(x: to.x * zoom, y: to.y * zoom)
            let s1 = CGPoint(x: c1.x * zoom, y: c1.y * zoom)
            let s2 = CGPoint(x: c2.x * zoom, y: c2.y * zoom)
            // 控制点落在两端点之间 → 线从端口正确发出、不越过端点
            #expect(s1.x >= f.x && s1.x <= t.x)
            #expect(s2.x >= f.x && s2.x <= t.x)
            #expect(s1.y == f.y && s2.y == t.y)
        }
    }
}
