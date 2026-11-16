import Testing
import Foundation
@testable import CanvasCore

// MARK: - AJ-18 审图/生视频节点补齐：端口 + 执行逻辑（图像/视频/参考图）
//
// 覆盖 4 项：
// 1. 审图（qcCheck）节点规范端口：image 输入 + report/status 输出（U2 端口规范）
// 2. 生视频（videoGen）节点规范端口：prompt/image/duration 三输入 + video 输出
// 3. videoGen 执行逻辑：duration 输入端口覆盖节点默认时长 → 传入 invoker / 任务单
// 4. qcCheck 执行逻辑：image 输入端口同样被 QC 读取（审图路径）

@Suite("AJ-18 审图/生视频节点补齐")
struct AJ18ReviewVideoNodeTests {

    // MARK: - 1) 审图（qcCheck）规范端口

    @Test func qcCheckCanonicalPorts() {
        #expect(ManjuNodeType.qcCheckInputPorts == ["image", "text", "video"],
                "审图节点应有 image + text + video 三输入端口（image = 待审图产物，video = 审视频路径）")
        #expect(ManjuNodeType.qcCheckOutputPorts == ["report", "status"],
                "审图节点应有 report + status 输出端口（结果）")
        #expect(ManjuNodeType.qcCheck.generationInputPortNames.isEmpty,
                "审图非生成类节点，无生成端口定义")
    }

    @Test func qcCheckMaxReferenceImagesZero() {
        #expect(ManjuNodeType.qcCheck.maxReferenceImages == 0,
                "审图节点不支持动态参考图端口（AJ-19 上限）")
        #expect(ManjuNodeType.qcCheck.supportsReferenceImages == false)
    }

    // MARK: - 2) 生视频（videoGen）规范端口

    @Test func videoGenCanonicalPortsIncludeDuration() {
        #expect(ManjuNodeType.videoGenInputPorts == ["prompt", "image", "duration", "video"],
                "生视频应有 prompt + image + duration + video 四输入端口（video = B2 V2V 参考视频基础端口）")
        #expect(ManjuNodeType.videoGenOutputPorts == ["video"])
        #expect(ManjuNodeType.videoGen.generationInputPortNames == ["prompt", "image", "duration", "video"])
        #expect(ManjuNodeType.videoGen.generationOutputPortNames == ["video"])
    }

    @Test func videoGenReferenceImageLimitOne() {
        #expect(ManjuNodeType.videoGen.maxReferenceImages == 1,
                "生视频仅 I2V 首帧 1 张参考图（AJ-19 上限）")
        #expect(ManjuNodeType.videoGen.supportsReferenceImages == true)
    }

    // MARK: - 3) videoGen 执行逻辑：duration 输入端口

    /// 捕获 backend 参数的生视频 stub（验证 duration 输入真实到达 invoker）
    private final class CapturingVideoInvoker: VideoGenerating, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: (prompt: String, firstFrame: String?, duration: String?)?

        // 同步 helper：把 NSLock 操作包出 async 上下文（Swift 6 禁止 async 内 lock）
        private func record(_ prompt: String, _ firstFrame: String?, _ duration: String?) {
            lock.lock(); defer { lock.unlock() }
            stored = (prompt, firstFrame, duration)
        }
        private func captured() -> (prompt: String, firstFrame: String?, duration: String?)? {
            lock.lock(); defer { lock.unlock() }
            return stored
        }

        func generate(
            node: CanvasNode, prompt: String, firstFrame: String?, backend: NodeBackendConfig?
        ) async throws -> VideoGenerationOutcome {
            let duration = backend?.params["duration"]
            record(prompt, firstFrame, duration)
            return .video(path: "/tmp/aj18_video.mp4")
        }

        func lastCall() -> (prompt: String, firstFrame: String?, duration: String?)? {
            captured()
        }
    }

    private func makeContext(video: (any VideoGenerating)? = nil) -> GraphExecutionContext {
        GraphExecutionContext(
            executors: NodeExecutors(),
            imageInvoker: StubImageInvoker(),
            videoInvoker: video
        )
    }

    private struct StubImageInvoker: ImageGenerating {
        func generate(
            node: CanvasNode, prompt: String, backend: NodeBackendConfig?
        ) async throws -> ImageGenerationOutcome {
            .jobTicket(prompt: prompt, markdown: "# 生成任务单")
        }
    }

    @Test func durationInputPortOverridesBackendDefault() async throws {
        let invoker = CapturingVideoInvoker()
        let context = makeContext(video: invoker)
        let node = CanvasNode(
            type: ManjuNodeType.videoGen.rawValue, title: "生视频",
            backendConfig: NodeBackendConfig(
                providerType: .cloud, providerID: "kling", modelID: "kling-v2",
                params: ["duration": "5s", "resolution": "720p"]
            )
        )

        _ = try await context.executeAsync(
            node: node,
            inputs: ["prompt": AnyHashable("[MODE]\nI2V"), "duration": AnyHashable("10s")]
        )

        let call = try #require(invoker.lastCall(), "生视频 invoker 必须被调用")
        #expect(call.duration == "10s",
                "duration 输入端口应覆盖节点默认时长（5s → 10s）传入 invoker")
        #expect(call.firstFrame == nil, "无 image 输入时首帧仍为 nil")
    }

    @Test func durationInputAbsentKeepsBackendDefault() async throws {
        let invoker = CapturingVideoInvoker()
        let context = makeContext(video: invoker)
        let node = CanvasNode(
            type: ManjuNodeType.videoGen.rawValue, title: "生视频",
            backendConfig: NodeBackendConfig(
                providerType: .cloud, providerID: "kling", modelID: "kling-v2",
                params: ["duration": "5s"]
            )
        )

        _ = try await context.executeAsync(node: node, inputs: ["prompt": AnyHashable("[MODE]\nI2V")])
        #expect(invoker.lastCall()?.duration == "5s",
                "无 duration 输入时保留节点默认时长 5s")
    }

    @Test func durationInputFlowsIntoJobTicketFallback() async throws {
        // 无 videoInvoker 降级：duration 输入端口应合并进任务单构建（覆盖默认时长）
        let context = makeContext() // videoInvoker = nil
        let node = CanvasNode(
            type: ManjuNodeType.videoGen.rawValue, title: "生视频",
            backendConfig: NodeBackendConfig(
                providerType: .cloud, providerID: "kling", modelID: "kling-v2",
                params: ["duration": "5s"]
            )
        )

        let output = try await context.executeAsync(
            node: node,
            inputs: ["prompt": AnyHashable("[MODE]\nI2V"), "duration": AnyHashable("10s")]
        )
        #expect(output["status"] as? String == "job_ticket", "无 invoker 降级任务单")
        let ticket = output["jobTicket"] as? String ?? ""
        #expect(ticket.contains("生成任务单"), "任务单应含标题标记")
    }

    // MARK: - 4) qcCheck 执行逻辑：image 输入端口

    @Test func qcImageInputProducesReport() async throws {
        let executor = QCNodeExecutor()
        let output = try await executor.execute(
            node: CanvasNode(type: "qcCheck", title: "QC"),
            inputs: ["image": AnyHashable("/tmp/aj18_review.png")],
            backend: nil
        )
        // 非任务单输入：image 端口被读取，走正常结构/审美校验（无 8/9 槽标记 → FAIL）
        #expect(output["status"] as? String == "FAIL", "审图输入无槽位结构 → FAIL")
        #expect((output["report"] as? String)?.contains("QC 检查报告") == true,
                "审图应输出 QC 报告")
        #expect(output["job_ticket"] == nil, "image 路径输入非任务单")
    }

    @Test func qcImageJobTicketInputRecognized() async throws {
        let executor = QCNodeExecutor()
        let output = try await executor.execute(
            node: CanvasNode(type: "qcCheck", title: "QC"),
            inputs: ["image": AnyHashable("# 生成任务单 · 生图\n\n## 完整提示词")],
            backend: nil
        )
        #expect(output["status"] as? String == "待生成后复检",
                "image 端口承载任务单文本时识别为待复检")
        #expect(output["job_ticket"] as? String == "1")
    }
}