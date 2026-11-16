import Testing
import Foundation
@testable import CanvasCore

// MARK: - B2 executeVideo 端到端：多视频输入消费（GraphExecutionContext 公开 API）
//
// 用 GraphExecutionContext.executeAsync（公开 API）验证 executeVideo 的多视频消费：
// 1. 多视频输入 [video, video1, video2] + stub invoker → invoker 收到的
//    backend.params["referenceVideos"]（JSON 数组字符串）解析后 == 三个路径，
//    且 firstFrame 仍正确取自 image 输入端口
// 2. videoInvoker 传 nil → 输出 status == "job_ticket"，jobTicket 文本含
//    「参考视频清单（B2 V2V」段标题与每个视频路径
// 3. 空 video 输入（只有 prompt）→ backend.params 无 referenceVideos 键

@Suite("B2 executeVideo 多视频消费")
struct B2ExecuteVideoMultiInputTests {

    // MARK: 测试桩

    /// 记录收到的 prompt/firstFrame/backend 的生视频 stub（验证多路参考视频真实到达 invoker）
    private final class CapturingVideoInvoker: VideoGenerating, @unchecked Sendable {
        struct Call {
            let prompt: String
            let firstFrame: String?
            let backend: NodeBackendConfig?
        }

        private let lock = NSLock()
        private var stored: Call?

        func generate(
            node: CanvasNode,
            prompt: String,
            firstFrame: String?,
            backend: NodeBackendConfig?
        ) async throws -> VideoGenerationOutcome {
            record(Call(prompt: prompt, firstFrame: firstFrame, backend: backend))
            return .video(path: "/tmp/b2_execute_video_out.mp4")
        }

        // NSLock.lock/unlock 在 async 上下文不可用，经同步辅助函数中转
        private func record(_ call: Call) {
            lock.lock(); defer { lock.unlock() }
            stored = call
        }

        func lastCall() -> Call? {
            lock.lock(); defer { lock.unlock() }
            return stored
        }
    }

    /// 生图 stub（本组测试不触发生图；仅满足 GraphExecutionContext 注入签名）
    private struct StubImageInvoker: ImageGenerating {
        func generate(
            node: CanvasNode, prompt: String, backend: NodeBackendConfig?
        ) async throws -> ImageGenerationOutcome {
            .image(path: "/tmp/b2_execute_video_stub.png")
        }
    }

    /// 构造 videoGen 节点：端口用 ManjuNodeType.videoGenInputPorts 生成
    /// （dataType "string" 即可，与 executeAsync 输入字典键 video/video1 对应）
    private func makeVideoGenNode() -> CanvasNode {
        CanvasNode(
            type: ManjuNodeType.videoGen.rawValue,
            title: "视频生成",
            inputs: ManjuNodeType.videoGenInputPorts.map {
                Port(name: $0, direction: .input, dataType: "string")
            },
            outputs: ManjuNodeType.videoGenOutputPorts.map {
                Port(name: $0, direction: .output, dataType: "video")
            }
        )
    }

    /// 解析 backend.params["referenceVideos"]（JSON 数组字符串）→ [String]
    private func decodeReferenceVideos(from backend: NodeBackendConfig?) throws -> [String] {
        let raw = try #require(backend?.params["referenceVideos"], "应注入 referenceVideos 键")
        let data = try #require(raw.data(using: .utf8), "referenceVideos 应为 UTF-8 JSON 字符串")
        return try JSONDecoder().decode([String].self, from: data)
    }

    // MARK: - 1) 多视频输入 [video, video1, video2] → invoker 收到 referenceVideos JSON

    @Test func multiVideoInputsReachInvokerAsReferenceVideosJSON() async throws {
        let invoker = CapturingVideoInvoker()
        let context = GraphExecutionContext(
            executors: NodeExecutors(llmInvoker: nil),
            imageInvoker: StubImageInvoker(),
            videoInvoker: invoker
        )
        let node = makeVideoGenNode()

        let output = try await context.executeAsync(
            node: node,
            inputs: [
                "prompt": AnyHashable("V2V 动作参考"),
                "image": AnyHashable("/tmp/first_frame.png"),
                "video": AnyHashable("/v/1.mp4"),
                "video1": AnyHashable("/v/2.mp4"),
                "video2": AnyHashable("/v/3.mp4"),
            ]
        )

        let call = try #require(invoker.lastCall(), "videoInvoker 必须被调用")
        #expect(call.prompt == "V2V 动作参考", "prompt 应原样到达 invoker")
        #expect(call.firstFrame == "/tmp/first_frame.png",
                "firstFrame 仍正确取自 image 输入端口（I2V/V2V 首帧）")
        let videos = try decodeReferenceVideos(from: call.backend)
        #expect(videos == ["/v/1.mp4", "/v/2.mp4", "/v/3.mp4"],
                "referenceVideos JSON 解析后应保序等于三个视频路径")
        #expect(output["status"] as? String == "succeeded")
        #expect(output["video"] as? String == "/tmp/b2_execute_video_out.mp4")
    }

    // MARK: - 2) videoInvoker 传 nil → 降级任务单，jobTicket 含参考视频清单

    @Test func nilVideoInvokerDegradesToTicketWithReferenceVideoList() async throws {
        let context = GraphExecutionContext(
            executors: NodeExecutors(llmInvoker: nil),
            imageInvoker: StubImageInvoker(),
            videoInvoker: nil
        )
        let node = makeVideoGenNode()

        let output = try await context.executeAsync(
            node: node,
            inputs: [
                "prompt": AnyHashable("V2V 多参考"),
                "video": AnyHashable("/v/a.mp4"),
                "video1": AnyHashable("/v/b.mp4"),
                "video2": AnyHashable("/v/c.mp4"),
            ]
        )

        #expect(output["status"] as? String == "job_ticket", "无 invoker 应降级任务单而非抛错")
        #expect(output["provider"] as? String == "none")
        let ticket = try #require(output["jobTicket"] as? String)
        #expect(ticket.contains("参考视频清单（B2 V2V"),
                "任务单应追加参考视频清单段（B2 V2V）")
        #expect(ticket.contains("/v/a.mp4"), "清单应列出每个参考视频路径")
        #expect(ticket.contains("/v/b.mp4"))
        #expect(ticket.contains("/v/c.mp4"))
        #expect(ticket.contains("共 3 条"), "清单应声明条数")
        #expect((output["video"] as? String) == ticket, "video 端口承载任务单全文")
    }

    // MARK: - 3) 空 video 输入（只有 prompt）→ 不注入 referenceVideos 键

    @Test func emptyVideoInputOmitsReferenceVideosKey() async throws {
        let invoker = CapturingVideoInvoker()
        let context = GraphExecutionContext(
            executors: NodeExecutors(llmInvoker: nil),
            imageInvoker: StubImageInvoker(),
            videoInvoker: invoker
        )
        var node = makeVideoGenNode()
        node.backendConfig = NodeBackendConfig(params: ["duration": "5s"])

        _ = try await context.executeAsync(
            node: node,
            inputs: ["prompt": AnyHashable("纯文生视频")]
        )

        let call = try #require(invoker.lastCall(), "videoInvoker 必须被调用")
        #expect(call.backend?.params["referenceVideos"] == nil,
                "无 video 输入时 backend.params 不得出现 referenceVideos 键")
        #expect(call.backend?.params["duration"] == "5s",
                "节点原有 backend 参数应原样保留（仅不注入 referenceVideos）")
        #expect(call.firstFrame == nil, "无 image 输入时 firstFrame 为 nil")
    }
}
