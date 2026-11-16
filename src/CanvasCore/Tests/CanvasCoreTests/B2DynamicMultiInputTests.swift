import Testing
import Foundation
@testable import CanvasCore

// MARK: - B2 动态多输入端口：执行器消费多输入 + 资产视频承载
//
// 覆盖：
// 1. 资产视频路径收集/去重/空白跳过 + JSON 往返 + 模板注入 assetRef
// 2. AssetLockExecutor 输出 videoPaths（全量）+ video（首条）；无视频时不输出
// 3. QCNodeExecutor 多路 image 输入（image/image1/…/image9）审计计数
// 4. resolveReferenceVideos 多路 video 收集（去重/空白跳过）

@Suite("B2 动态多输入端口")
struct B2DynamicMultiInputTests {

    // MARK: - 1) 资产视频路径收集 / JSON / 模板注入

    @Test func assetVideoPathsCollectsDedupesAndSkipsEmpty() {
        let assets = ManjuAssetLibrary(
            characters: [
                ManjuCharacterCard(name: "魏衔", lockParts: ["脸"], referenceVideoPath: "/v/ref-a.mp4"),
                ManjuCharacterCard(name: "重复", lockParts: [], referenceVideoPath: "/v/ref-a.mp4"),
                ManjuCharacterCard(name: "无视频", lockParts: []),
            ],
            costumes: [
                ManjuCostumeAsset(name: "道袍", structure: "麻织", referenceVideoPath: "/v/ref-b.mp4"),
                ManjuCostumeAsset(name: "空", structure: "棉"),
            ],
            scenes: [
                ManjuSceneAsset(name: "大殿", layout: "纵深", masterVideoPath: "/v/ref-c.mp4"),
                ManjuSceneAsset(name: "空白", layout: "x", masterVideoPath: "   "),
            ]
        )
        #expect(ManjuPipelineTemplate.assetVideoPaths(of: assets)
                == ["/v/ref-a.mp4", "/v/ref-b.mp4", "/v/ref-c.mp4"],
                "角色→服装→场景声明序收集；重复只出现一次；空/空白跳过")
    }

    @Test func assetVideosJSONRoundTripAndInvalidInput() {
        let assets = ManjuAssetLibrary(
            characters: [ManjuCharacterCard(name: "A", lockParts: [], referenceVideoPath: "/v/a.mp4")],
            scenes: [ManjuSceneAsset(name: "S", layout: "x", masterVideoPath: "/v/s.mp4")]
        )
        let json = ManjuPipelineTemplate.assetVideosJSON(of: assets)
        #expect(ManjuPipelineTemplate.parseAssetVideos(json) == ["/v/a.mp4", "/v/s.mp4"])
        #expect(ManjuPipelineTemplate.parseAssetVideos(nil) == [])
        #expect(ManjuPipelineTemplate.parseAssetVideos("not-json") == [])
    }

    @Test func templateInjectsVideosAndAddsVideoPortToAssetRef() {
        let assets = ManjuAssetLibrary(
            characters: [ManjuCharacterCard(name: "A", lockParts: [], referenceVideoPath: "/v/a.mp4")]
        )
        let graph = ManjuPipelineTemplate.makeManjuPipeline(assets: assets)
        guard let assetRef = graph.nodes.first(where: { $0.type == ManjuNodeType.assetRef.rawValue }) else {
            Issue.record("模板应含 assetRef 节点")
            return
        }
        #expect(assetRef.outputs.map(\.name) == ["assets", "video", "image"],
                "assetRef 模板规格应含 video 输出端口（B2 V2V 参考视频）+ image 输出端口（B7 资产参考图喂 img2img）")
        #expect(ManjuPipelineTemplate.parseAssetVideos(
            assetRef.backendConfig?.params[ManjuPipelineTemplate.assetVideosKey]
        ) == ["/v/a.mp4"], "assetRef 节点应注入 asset.videos JSON")
    }

    // MARK: - 2) AssetLockExecutor：videoPaths + video 输出

    @Test func assetLockExecutorOutputsVideoPathsAndFirstVideo() async throws {
        var node = CanvasNode(type: ManjuNodeType.assetRef.rawValue, title: "资产引用")
        var config = NodeBackendConfig()
        config.params[ManjuPipelineTemplate.assetVideosKey] = ManjuPipelineTemplate.assetVideosJSON(
            of: ManjuAssetLibrary(
                characters: [ManjuCharacterCard(name: "A", lockParts: [], referenceVideoPath: "/v/a.mp4")],
                scenes: [ManjuSceneAsset(name: "S", layout: "x", masterVideoPath: "/v/s.mp4")]
            )
        )
        node.backendConfig = config
        let out = try await AssetLockExecutor().execute(node: node, inputs: nil, backend: nil)
        #expect(out["videoPaths"] as? [String] == ["/v/a.mp4", "/v/s.mp4"])
        #expect(out["video"] as? String == "/v/a.mp4",
                "video 输出 = 首条视频路径，供 assetRef.video 输出端口连线取值")
    }

    @Test func assetLockExecutorWithoutVideosOmitsVideoOutputs() async throws {
        var node = CanvasNode(type: ManjuNodeType.assetRef.rawValue, title: "资产引用")
        var config = NodeBackendConfig()
        config.params[ManjuPipelineTemplate.assetVideosKey] = "[]"
        node.backendConfig = config
        let out = try await AssetLockExecutor().execute(node: node, inputs: nil, backend: nil)
        #expect(out["video"] == nil)
        #expect(out["videoPaths"] == nil)
    }

    // MARK: - 3) QCNodeExecutor：多路 image 输入

    @Test func qcExecutorCountsMultipleImageInputs() async throws {
        var node = CanvasNode(type: ManjuNodeType.qcCheck.rawValue, title: "QC")
        node.inputs = ["image", "image1", "image2"].map {
            Port(name: $0, direction: .input, dataType: "image")
        }
        let out = try await QCNodeExecutor().execute(
            node: node,
            inputs: ["image": "/out/a.png", "image1": "/out/b.png", "image2": "/out/c.png"],
            backend: nil
        )
        #expect(out["images_reviewed"] as? Int == 3,
                "多路 image 输入应全部计入审图范围")
        #expect(out["status"] != nil)
        #expect((out["report"] as? String)?.isEmpty == false)
    }

    @Test func qcExecutorSingleImageOmitsCount() async throws {
        var node = CanvasNode(type: ManjuNodeType.qcCheck.rawValue, title: "QC")
        node.inputs = [Port(name: "image", direction: .input, dataType: "image")]
        let out = try await QCNodeExecutor().execute(
            node: node,
            inputs: ["image": "/out/a.png"],
            backend: nil
        )
        #expect(out["images_reviewed"] == nil, "单路 image 不写审计计数")
        #expect(out["status"] != nil)
    }

    // MARK: - 4) resolveReferenceVideos：多路 video 解析

    @Test func resolveReferenceVideosCollectsDedupesAndSkipsEmpty() {
        let inputs: [String: AnyHashable] = [
            "video": "/v/1.mp4",
            "video1": "/v/2.mp4",
            "video2": "/v/1.mp4",
            "video3": "   ",
        ]
        #expect(GraphExecutionContext.resolveReferenceVideos(from: inputs) == ["/v/1.mp4", "/v/2.mp4"],
                "video/video1/… 保序收集；重复去重；空白跳过")
        #expect(GraphExecutionContext.resolveReferenceVideos(from: nil) == [])
        #expect(GraphExecutionContext.resolveReferenceVideos(from: [:]) == [])
    }
}
