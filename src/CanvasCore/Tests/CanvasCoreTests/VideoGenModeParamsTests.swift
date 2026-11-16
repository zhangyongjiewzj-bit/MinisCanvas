import Testing
import Foundation
import Synchronization
@testable import CanvasCore

// MARK: - 生视频节点生成模式（params["mode"]）→ 首帧透传策略（右侧栏参数面板数据链）

/// 覆盖「生视频参数面板 → config.params.mode → executeVideo 首帧路由」：
///   i2v（图生视频，默认）：image 输入端口透传为首帧
///   t2v（文生视频）：忽略 image 输入，即使上游接了参考图也不当首帧
///   r2v（首尾帧）：image 输入端口透传为首帧
/// 无 mode 参数（老节点/手写配置）保持旧行为：透传首帧（向后兼容）。
struct VideoGenModeParamsTests {

    /// 记录调用参数的视频 stub（返回 .video 成功路径，验证 executeVideo 传给 provider 的参数）
    /// 2026-08-06：NSLock 在 async 上下文不可用（Swift 6）且 Synchronization.Mutex 需 macOS 15+，
    /// 部署目标更低 → 改用 actor 隔离捕获状态（无版本限制、真并发安全）。
    private actor CapturedState {
        var node: CanvasNode?
        var prompt: String?
        var firstFrame: String?
        var backend: NodeBackendConfig?

        func set(node: CanvasNode?, prompt: String?, firstFrame: String?, backend: NodeBackendConfig?) {
            self.node = node
            self.prompt = prompt
            self.firstFrame = firstFrame
            self.backend = backend
        }

        func snapshot() -> (node: CanvasNode?, prompt: String?, firstFrame: String?, backend: NodeBackendConfig?) {
            (node, prompt, firstFrame, backend)
        }
    }
    private final class CapturingVideoInvoker: VideoGenerating, @unchecked Sendable {
        private let state = CapturedState()

        func generate(
            node: CanvasNode, prompt: String, firstFrame: String?, backend: NodeBackendConfig?
        ) async throws -> VideoGenerationOutcome {
            await state.set(node: node, prompt: prompt, firstFrame: firstFrame, backend: backend)
            return .video(path: "https://cdn.example.com/clips/v1.mp4")
        }

        func lastCall() async -> (node: CanvasNode?, prompt: String?, firstFrame: String?, backend: NodeBackendConfig?) {
            await state.snapshot()
        }
    }

    /// 生图 stub（本组测试不触发生图；仅满足 GraphExecutionContext 注入签名）
    private struct StubImageInvoker: ImageGenerating {
        func generate(
            node: CanvasNode, prompt: String, backend: NodeBackendConfig?
        ) async throws -> ImageGenerationOutcome {
            .jobTicket(prompt: prompt, markdown: "# 生成任务单")
        }
    }

    private func makeContext(video: (any VideoGenerating)?) -> GraphExecutionContext {
        GraphExecutionContext(
            executors: NodeExecutors(llmInvoker: nil),
            imageInvoker: StubImageInvoker(),
            videoInvoker: video
        )
    }

    private func runVideoNode(mode: String?) async throws -> CapturingVideoInvoker {
        let invoker = CapturingVideoInvoker()
        let context = makeContext(video: invoker)
        let node = CanvasNode(
            type: ManjuNodeType.videoGen.rawValue,
            title: "生视频",
            backendConfig: NodeBackendConfig(
                providerType: .cloud, providerID: "kling", modelID: "kling-v2",
                params: mode.map { ["mode": $0] } ?? [:]
            )
        )
        _ = try await context.executeAsync(
            node: node,
            inputs: ["prompt": "[MODE]\nI2V 一段打斗", "image": "/tmp/first-frame.png"]
        )
        return invoker
    }

    @Test func t2vModeDropsImageFirstFrame() async throws {
        let invoker = try await runVideoNode(mode: "t2v")
        #expect(await invoker.lastCall().firstFrame == nil,
                "文生视频（t2v）应忽略 image 输入端口，不把参考图当首帧传给 provider")
    }

    @Test func i2vModeForwardsImageFirstFrame() async throws {
        let invoker = try await runVideoNode(mode: "i2v")
        #expect(await invoker.lastCall().firstFrame == "/tmp/first-frame.png",
                "图生视频（i2v）应把 image 输入端口透传为首帧")
    }

    @Test func r2vModeForwardsImageFirstFrame() async throws {
        let invoker = try await runVideoNode(mode: "r2v")
        #expect(await invoker.lastCall().firstFrame == "/tmp/first-frame.png",
                "首尾帧（r2v）应把 image 输入端口透传为首帧")
    }

    @Test func missingModeKeepsLegacyFirstFrameForwarding() async throws {
        // 老节点/手写配置无 mode 参数 → 保持旧行为：透传首帧（不回归）
        let invoker = try await runVideoNode(mode: nil)
        #expect(await invoker.lastCall().firstFrame == "/tmp/first-frame.png",
                "无 mode 参数（老节点）应保持首帧透传旧行为")
    }

    @Test func videoOutcomeExposesPathAndProvider() async throws {
        let invoker = CapturingVideoInvoker()
        let context = makeContext(video: invoker)
        let node = CanvasNode(type: ManjuNodeType.videoGen.rawValue, title: "生视频")
        let output = try await context.executeAsync(node: node, inputs: ["prompt": "p"])
        #expect(output["status"] as? String == "succeeded")
        #expect(output["provider"] as? String == "video")
        #expect(output["video"] as? String == "https://cdn.example.com/clips/v1.mp4")
    }
}
