import Foundation
import Testing
@testable import CanvasCore

// MARK: - 线G：资产视频入口（assetRef 视频媒体 Codable 往返 / 资产摘要含视频 / videoGen 消费 assetRef.video）

/// 覆盖「资产视频入口 App UI 层闭环」的 CanvasCore 侧三个新测试：
/// 1. assetRef 视频媒体（result.kind=video + result.path）经 NodeBackendConfig Codable 往返无损，
///    重建的 assetKind / assetMediaPath 与原始一致（ManjuAssetKind 原始串同 F12 结果媒体键约定）
/// 2. 资产摘要含视频：资产带参考视频时 assetSummary 追加「参考视频：<路径>」行
/// 3. videoGen 可消费 assetRef.video 引用：assetRef 挂载视频 → AssetLockExecutor 输出 video →
///    经 assetRef.video 输出端口连线进 videoGen.video 输入端口 → resolveReferenceVideos 解析成功
@Suite("线G 资产视频入口")
struct LineGVideoAssetEntryTests {

    /// assetRef 视频媒体 Codable 往返：backendConfig.params 的 result.kind=video / result.path
    /// 经 JSON 编解码无损，重建的 assetKind / assetMediaPath 与原始一致。
    @Test func assetRefVideoMediaCodableRoundTrip() throws {
        var node = CanvasNode(type: ManjuNodeType.assetRef.rawValue, title: "资产引用")
        var config = NodeBackendConfig()
        config.params["result.path"] = "/v/mounted.mp4"
        config.params["result.kind"] = "video"
        config.params["result.name"] = "mounted.mp4"
        node.backendConfig = config

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(NodeBackendConfig.self, from: data)
        node.backendConfig = decoded

        #expect(node.assetKind == .video, "Codable 往返后 assetRef 仍识别为视频资产")
        #expect(node.assetMediaPath == "/v/mounted.mp4", "往返后媒体路径无损")
        #expect(node.assetKind?.rawParamValue == "video", "原始串与 result.kind 键约定同源")
    }

    /// 资产摘要含视频：资产库带参考视频时，assetSummary 逐条追加「参考视频：<路径>」行
    /// （与锁定清单同文本流进 assets 输出端口，供 assetRef 节点展示）。
    @Test func assetSummaryIncludesReferenceVideos() {
        let assets = ManjuAssetLibrary(
            characters: [ManjuCharacterCard(name: "魏衔", lockParts: ["脸"], referenceVideoPath: "/v/ref-a.mp4")],
            costumes: [ManjuCostumeAsset(name: "道袍", structure: "麻织", referenceVideoPath: "/v/ref-b.mp4")],
            scenes: [ManjuSceneAsset(name: "大殿", layout: "纵深", masterVideoPath: "/v/ref-c.mp4")]
        )
        let summary = ManjuPipelineTemplate.assetSummary(of: assets)
        #expect(summary.contains("参考视频：/v/ref-a.mp4"), "角色参考视频应进摘要")
        #expect(summary.contains("参考视频：/v/ref-b.mp4"), "服装参考视频应进摘要")
        #expect(summary.contains("参考视频：/v/ref-c.mp4"), "场景母视频应进摘要")
    }

    /// videoGen 可消费 assetRef.video 引用（挂载视频路径）：
    /// assetRef 挂载视频（result.kind=video + result.path）→ AssetLockExecutor 输出 video（首条）
    /// → 该值经 assetRef.video 输出端口连线进 videoGen.video 输入端口 → resolveReferenceVideos 解析成功。
    @Test func videoGenConsumesMountedAssetRefVideoViaResolveReferenceVideos() async throws {
        var node = CanvasNode(type: ManjuNodeType.assetRef.rawValue, title: "资产引用")
        var config = NodeBackendConfig()
        config.params["result.path"] = "/v/mounted.mp4"
        config.params["result.kind"] = "video"
        node.backendConfig = config
        let out = try await AssetLockExecutor().execute(node: node, inputs: nil, backend: nil)
        let video = try #require(out["video"] as? String)
        #expect(video == "/v/mounted.mp4", "挂载视频经 video 输出端口取值（首条）")
        #expect(out["videoPaths"] as? [String] == ["/v/mounted.mp4"], "挂载视频进 videoPaths 全量")
        // 下游 videoGen 输入端口 video 收到该值 → resolveReferenceVideos 解析为参考视频
        let inputs: [String: AnyHashable] = ["video": video]
        #expect(GraphExecutionContext.resolveReferenceVideos(from: inputs) == ["/v/mounted.mp4"],
                "videoGen 可消费 assetRef.video 引用（走 resolveReferenceVideos 路径）")
    }
}
