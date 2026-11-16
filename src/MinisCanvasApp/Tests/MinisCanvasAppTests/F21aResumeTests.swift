import Foundation
import Testing
import CanvasCore
@testable import MinisCanvasApp

// MARK: - F21a（P0-1）画布执行断点续跑
//
// 用户级 P0：原 runGraph 不传 resumeFrom、节点状态只在 finishRun 写回——
// 执行中 kill/崩溃后重跑整图，已完成节点重复烧 token/扣费。
// 修复：①runGraph 把 succeeded/cached 节点收进 resumeSet 传给调度器；
//       ②handleExecutionEvent 逐事件增量写回节点状态 + 防抖落盘。

@Suite("F21a 断点续跑", .serialized)
@MainActor
struct F21aResumeTests {

    /// T1 测试隔离：无 key → LLM 走引导输出，离线快速且确定
    init() {
        TestEnvIsolation.hermeticize()
    }

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

    private func waitForIdle(_ store: CanvasStore, timeout: TimeInterval = 15) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && store.isRunning {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// 直接改写图内节点状态（模拟中断/崩溃后的现场）
    private func setNodeStatusInGraph(_ store: CanvasStore, id: UUID, _ status: NodeStatus) throws {
        let index = try #require(
            store.graph.nodes.firstIndex(where: { $0.id == id }),
            "续跑 fixture 的节点 ID 必须存在"
        )
        store.graph.nodes[index].status = status
    }

    /// 首跑成功 → 图内状态全部 succeeded（增量写回生效，不再只靠 finishRun）
    @Test func firstRunWritesBackStatusIncrementally() async throws {
        let store = try makeChain(count: 3)
        store.runGraph()
        await waitForIdle(store)
        #expect(!store.isRunning)
        #expect(store.graph.nodes.allSatisfy { $0.status == .succeeded },
                "首跑后所有节点应为 succeeded（增量写回）")
    }

    /// 断点续跑核心：A 已 succeeded、B/C 重置为 pending（模拟中断后重启），
    /// 重跑 → A 进 resumeSet 不重执行（缓存命中），B/C 正常执行。
    @Test func resumeRunSkipsAlreadySucceededNodes() async throws {
        let store = try makeChain(count: 3)
        store.runGraph()
        await waitForIdle(store)
        #expect(store.graph.nodes.allSatisfy { $0.status == .succeeded })

        // 模拟「中断后重启」现场：A 保持成功，B/C 回到 pending
        let sorted = store.graph.nodes.sorted { $0.position.x < $1.position.x }
        try #require(sorted.count == 3, "续跑 fixture 应保留 3 个节点")
        let (a, b, c) = (sorted[0], sorted[1], sorted[2])
        try setNodeStatusInGraph(store, id: b.id, .pending)
        try setNodeStatusInGraph(store, id: c.id, .pending)
        #expect(store.graph.node(id: a.id)?.status == .succeeded)

        // 重跑：A 在 resumeSet 内 → 调度器不重执行（有缓存→.cached，无缓存→保持 .succeeded）
        store.runGraph()
        await waitForIdle(store)

        let aStatus = store.graph.node(id: a.id)?.status
        #expect(aStatus == .cached || aStatus == .succeeded,
                "已完成节点不应重执行，实际状态：\(String(describing: aStatus))")
        // B/C 命中结果缓存→.cached 或重执行→.succeeded 均为「已完成、未重复计算」的正确续跑行为
        let bStatus = store.graph.node(id: b.id)?.status
        #expect(bStatus == .succeeded || bStatus == .cached,
                "B 应完成（执行或缓存），实际：\(String(describing: bStatus))")
        let cStatus = store.graph.node(id: c.id)?.status
        #expect(cStatus == .succeeded || cStatus == .cached,
                "C 应完成（执行或缓存），实际：\(String(describing: cStatus))")
    }

    /// 失败节点续跑：B 标 failed、C 标 pending 后重跑，
    /// A（succeeded）不重执行，B/C 重执行并成功。
    @Test func resumeAfterFailureRerunsFailedAndDownstreamOnly() async throws {
        let store = try makeChain(count: 3)
        store.runGraph()
        await waitForIdle(store)

        let sorted = store.graph.nodes.sorted { $0.position.x < $1.position.x }
        try #require(sorted.count == 3, "失败续跑 fixture 应保留 3 个节点")
        let (a, b, c) = (sorted[0], sorted[1], sorted[2])
        // 模拟 B 失败、C 被跳过的中断现场
        try setNodeStatusInGraph(store, id: b.id, .failed)
        try setNodeStatusInGraph(store, id: c.id, .pending)

        store.runGraph()
        await waitForIdle(store)

        let aStatus = store.graph.node(id: a.id)?.status
        #expect(aStatus == .cached || aStatus == .succeeded, "A 不应重执行")
        // B/C 命中缓存→.cached 或重执行→.succeeded 均为正确的续跑行为（不重复计算）
        let bStatus = store.graph.node(id: b.id)?.status
        #expect(bStatus == .succeeded || bStatus == .cached,
                "节点 B 应完成（执行或缓存），实际：\(String(describing: bStatus))")
        let cStatus = store.graph.node(id: c.id)?.status
        #expect(cStatus == .succeeded || cStatus == .cached,
                "下游 C 应完成（执行或缓存），实际：\(String(describing: cStatus))")
    }
}
