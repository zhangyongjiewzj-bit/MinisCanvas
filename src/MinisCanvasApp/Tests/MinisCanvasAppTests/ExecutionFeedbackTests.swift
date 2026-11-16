import Foundation
import Testing
import CanvasCore
@testable import MinisCanvasApp

// MARK: - C2-2 执行反馈闭环（学 ComfyUI）：进度 / 缓存灰显 / 中断

/// 画布级执行反馈测试：
/// - runGraph 后台线程调度 + 逐节点事件回主线程 → 进度条状态（value/max）
/// - 同输入第二次运行 → 节点全部 .cached（灰显「已缓存」）
/// - cancelRun（停止按钮）→ 剩余节点全部跳过、结果标记 wasCancelled
@Suite("执行反馈闭环", .serialized)
@MainActor
struct ExecutionFeedbackTests {

    /// T1 测试隔离：unset API key env，真实执行上下文无 key → 占位/任务单，
    /// 离线快速且确定（不依赖开发机 shell 是否有真实 key）
    init() {
        TestEnvIsolation.hermeticize()
    }

    /// 构造 text → llm → … → llm 链式图（真实执行上下文：无 key 走占位/任务单，离线快速）
    private func makeChain(count: Int) throws -> CanvasStore {
        let store = CanvasStore()
        let first = try #require(store.addNode(ofType: "text"))
        var previous = first
        for _ in 1..<count {
            let next = try #require(store.addNode(ofType: "llm"))
            #expect(store.connectNodes(fromID: previous.id, toID: next.id))
            previous = next
        }
        return store
    }

    /// 等待执行结束（主线程挂起让事件投递执行；后台调度线程独立推进）
    private func waitForIdle(_ store: CanvasStore, timeout: TimeInterval = 15) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && store.isRunning {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func runGraphStartsProgressAndCompletes() async throws {
        let store = try makeChain(count: 3)
        store.runGraph()

        // runGraph 同步初始化进度（值在后台事件到达前保持 0）
        #expect(store.isRunning)
        #expect(store.executionProgress?.max == 3)
        #expect(store.executionProgress?.value == 0)
        #expect(store.statusMessage == "执行中…")

        await waitForIdle(store)
        #expect(!store.isRunning)
        #expect(store.executionProgress == nil, "执行结束进度条应消失")
        #expect(store.graph.nodes.allSatisfy { $0.status == .succeeded })
        #expect(store.statusMessage?.hasPrefix("执行完成") == true)
    }

    @Test func secondRunMarksCacheHitGray() async throws {
        let store = try makeChain(count: 3)
        store.runGraph()
        await waitForIdle(store)
        #expect(store.graph.nodes.allSatisfy { $0.status == .succeeded })

        // 同输入第二次运行：全部缓存命中 → .cached（灰显「已缓存」，不重跑）
        store.runGraph()
        await waitForIdle(store)
        #expect(store.graph.nodes.allSatisfy { $0.status == .cached })
        #expect(store.statusMessage?.contains("缓存") == true)
    }

    @Test func cancelRunStopsRemainingNodes() async throws {
        let store = try makeChain(count: 40)
        store.runGraph()
        // 与 runGraph 同一主线程回合调用：中断标志必先于后台任务首个节点检查置位
        store.cancelRun()
        #expect(store.statusMessage == "正在停止…")

        await waitForIdle(store)
        #expect(!store.isRunning)
        #expect(store.executionProgress == nil)
        #expect(store.lastResult?.wasCancelled == true, "中断应标记 wasCancelled")
        #expect(store.statusMessage?.hasPrefix("已中断") == true)
        // 剩余节点全部跳过（最多首个节点已开始执行）
        let skipped = store.graph.nodes.filter { $0.status == .skipped }.count
        #expect(skipped >= 39, "中断后剩余节点标记 skipped，实际跳过 \(skipped)/40")
    }
}
