import Testing
import Foundation
import CanvasCore
import MinisCore
@testable import MinisCanvasApp

// MARK: - P2-2-fix 收尾（App 层）：MinisCanvasVideoInvoker 注入 + 无 key 降级任务单

@Suite("P2-2-fix 收尾", .serialized)
@MainActor
struct P2_2VideoTicketFinishTests {

    /// 等待执行结束（主线程挂起让事件投递执行；后台调度线程独立推进）
    private func waitForIdle(_ store: CanvasStore, timeout: TimeInterval = 15) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && store.isRunning {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func canvasStoreInjectsVideoInvoker() {
        let store = CanvasStore()
        #expect(store.context.videoInvoker != nil,
                "CanvasStore 默认上下文应注入 MinisCanvasVideoInvoker（P2-2 P0-3）")
    }

    @Test func videoInvokerWithoutKeyDegradesToJobTicket() async throws {
        // 本机未配置 KLING_API_KEY / JIMENG_API_KEY → 确定性走无 key 降级（不触网）
        // F10 P0-04 契约：显式 kling 后端 + 无 key → 降级任务单；
        // 空 backend → 明确报 unconfigured（不再静默路由 Kling）
        let invoker = MinisCanvasVideoInvoker()
        let node = CanvasNode(type: ManjuNodeType.videoGen.rawValue, title: "视频生成")
        var backend = NodeBackendConfig()
        backend.providerID = "kling"
        let outcome = try await invoker.generate(
            node: node, prompt: "[MODE]\nI2V 一段打斗", firstFrame: nil, backend: backend
        )
        guard case .jobTicket(let prompt, let markdown) = outcome else {
            Issue.record("无 key 应降级任务单（.jobTicket），实际：\(outcome)")
            return
        }
        #expect(prompt.contains("I2V"))
        #expect(markdown.contains("生成任务单"), "任务单应含标题标记（QC 据此识别「待生成后复检」）")
        #expect(markdown.contains("## 9 槽结构"),
                "App 层无 key 降级应复用 CanvasCore 9 槽任务单（铁律7）")
    }

    @Test func videoInvokerWithoutBackendReportsUnconfigured() async {
        // F10 P0-04：空 providerID → 明确报错，不静默落到 Kling
        let invoker = MinisCanvasVideoInvoker()
        let node = CanvasNode(type: ManjuNodeType.videoGen.rawValue, title: "视频生成")
        await #expect(throws: CanvasVideoRoutingError.self,
                      "无 backend 应报 unconfigured 而非静默路由 Kling") {
            try await invoker.generate(
                node: node, prompt: "[MODE]\nI2V 一段打斗", firstFrame: nil, backend: nil
            )
        }
    }

    @Test func videoGenNodeSucceedsAsJobTicketOnCanvasRun() async throws {
        let store = CanvasStore()
        let node = try #require(store.addNode(ofType: "videoGen"))
        store.runGraph()
        await waitForIdle(store)

        // 无 key 降级任务单：节点标记成功（不阻塞画布、不标红失败）
        #expect(store.graph.node(id: node.id)?.status == .succeeded,
                "无 key 生视频应降级任务单而非失败")
        let outputs = store.lastResult?.outputs[node.id]
        #expect(outputs?["status"] as? String == "job_ticket")
        #expect((outputs?["jobTicket"] as? String)?.contains("9 槽") == true,
                "调度输出应带 9 槽任务单（QC 下游可识别）")
    }

    @Test func builtinVideoNodeRoutesToKlingAndDegrades() async throws {
        // 裸 "video" 节点自带 defaultBackendConfig（providerID=kling）→ 显式路由 Kling，
        // 无 key 降级任务单（F10 P0-04 后显式 kling 配置仍走 Kling，行为不变）
        let store = CanvasStore()
        let node = try #require(store.addNode(ofType: "video"))
        store.runGraph()
        await waitForIdle(store)

        #expect(store.graph.node(id: node.id)?.status == .succeeded)
        let outputs = store.lastResult?.outputs[node.id]
        #expect(outputs?["provider"] as? String == "video",
                "已注入 invoker（kling 后端无 key）→ provider=video 降级任务单（未真实生成）")
        #expect(outputs?["status"] as? String == "job_ticket")
    }
}
