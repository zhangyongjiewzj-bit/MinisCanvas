import Testing
import Foundation
@testable import CanvasCore

private struct TestMediaAssetResolver: MediaAssetResolving {
    let value: MediaAsset

    func asset(id: UUID) async -> MediaAsset? {
        value.id == id ? value : nil
    }
}

// MARK: - P0 资产层承载图：定妆图/服装/场景母图进画布资产层

@Suite struct ManjuAssetImageInjectionTests {

    /// 构造带真实图片路径的演示资产库（角色定妆图 / 服装图 / 场景母图）
    private var assetsWithImages: ManjuAssetLibrary {
        ManjuAssetLibrary(
            characters: [
                ManjuCharacterCard(
                    name: "魏衔", lockParts: ["脸", "五官", "眼型"],
                    referenceImageID: "asset://weixian-face-8angle",
                    referenceImagePath: "/assets/weixian/face_8angle.png"
                ),
                ManjuCharacterCard(
                    name: "阿岚", lockParts: ["脸", "肤色"],
                    referenceImageID: "asset://alan-face-4x",
                    referenceImagePath: nil // 无图角色：应被跳过
                ),
            ],
            costumes: [
                ManjuCostumeAsset(
                    name: "魏衔·玄色道袍", structure: "粗麻织纹、袖口磨损起毛",
                    referenceImageID: "asset://weixian-costume-4x",
                    referenceImagePath: "/assets/weixian/costume_4x.png"
                ),
            ],
            scenes: [
                ManjuSceneAsset(
                    name: "青崖观·大殿", layout: "纵深三进",
                    masterImageID: "asset://qingya-hall-master",
                    masterImagePath: "/assets/scenes/qingya_hall_master.png"
                ),
            ],
            styleLock: "weixian-lock：伪仙写实"
        )
    }

    @Test("资产图路径收集：角色→服装→场景顺序，跳过 nil，去重")
    func collectAssetImagePaths() {
        let paths = ManjuPipelineTemplate.assetImagePaths(of: assetsWithImages)
        #expect(paths == [
            "/assets/weixian/face_8angle.png",
            "/assets/weixian/costume_4x.png",
            "/assets/scenes/qingya_hall_master.png",
        ])
    }

    @Test("空路径/空白串被跳过；同一路径多资产引用只出现一次")
    func collectSkipsEmptyAndDeduplicates() {
        var assets = ManjuAssetLibrary()
        assets.characters = [
            ManjuCharacterCard(name: "A", lockParts: ["脸"], referenceImagePath: "/shared.png"),
            ManjuCharacterCard(name: "B", lockParts: ["脸"], referenceImagePath: "/shared.png"),
            ManjuCharacterCard(name: "C", lockParts: ["脸"], referenceImagePath: "   "),
            ManjuCharacterCard(name: "D", lockParts: ["脸"], referenceImagePath: nil),
        ]
        #expect(ManjuPipelineTemplate.assetImagePaths(of: assets) == ["/shared.png"])
    }

    @Test("JSON 注入键往返：assetImagesJSON → parseAssetImages 无损还原")
    func jsonRoundTrip() {
        let json = ManjuPipelineTemplate.assetImagesJSON(of: assetsWithImages)
        #expect(ManjuPipelineTemplate.parseAssetImages(json) == [
            "/assets/weixian/face_8angle.png",
            "/assets/weixian/costume_4x.png",
            "/assets/scenes/qingya_hall_master.png",
        ])
        // 空资产库编码为 [] 且可解析
        let empty = ManjuPipelineTemplate.assetImagesJSON(of: ManjuAssetLibrary())
        #expect(ManjuPipelineTemplate.parseAssetImages(empty).isEmpty)
        // 非法输入返回空数组（不崩溃）
        #expect(ManjuPipelineTemplate.parseAssetImages("not-json").isEmpty)
        #expect(ManjuPipelineTemplate.parseAssetImages(nil).isEmpty)
    }

    @Test("一键流水线：assetRef 节点只注入 canonical 资产引用 + asset.images（全量）")
    func pipelineInjectsAssetImagesIntoAssetRef() throws {
        let graph = ManjuPipelineTemplate.makeManjuPipeline(assets: assetsWithImages)
        let assetRef = try #require(graph.nodes.first { $0.type == ManjuNodeType.assetRef.rawValue })
        let params = try #require(assetRef.backendConfig?.params)

        // 模板只提供资产输入清单；媒体卡片必须由 CanvasAssetStore 的 canonical
        // projection 提供，不能把路径重复写进 legacy result.*。
        #expect(params["result.path"] == nil)
        #expect(params["result.kind"] == nil)
        #expect(params["result.name"] == nil)
        // 全量 → asset.images JSON
        let images = ManjuPipelineTemplate.parseAssetImages(params[ManjuPipelineTemplate.assetImagesKey])
        #expect(images.count == 3)
        #expect(images.contains("/assets/weixian/costume_4x.png"))
        #expect(images.contains("/assets/scenes/qingya_hall_master.png"))
        // 文本摘要仍保留（双轨：文本锁定清单 + 图资产）
        #expect(params[ManjuAssetInjection.assetRefSummaryKey]?.contains("魏衔") == true)
    }

    @Test("一键流水线：资产库无图片路径时 asset.images 为空数组")
    func pipelineWithoutImagePaths() throws {
        let graph = ManjuPipelineTemplate.makeManjuPipeline(assets: .demo)
        let assetRef = try #require(graph.nodes.first { $0.type == ManjuNodeType.assetRef.rawValue })
        let params = try #require(assetRef.backendConfig?.params)
        #expect(params["result.path"] == nil)
        #expect(params["result.kind"] == nil)
        // 空数组 JSON 仍注入，保证执行端可解析
        #expect(ManjuPipelineTemplate.parseAssetImages(params[ManjuPipelineTemplate.assetImagesKey]).isEmpty)
        // 摘要仍在（文本锁定不受影响）
        #expect(params[ManjuAssetInjection.assetRefSummaryKey]?.contains("魏衔") == true)
    }

    @Test("AssetLockExecutor：注入资产图后输出 imagePaths；无图时不输出该键")
    func executorOutputsImagePaths() async throws {
        // 带图资产库 → assetRef 节点带 asset.images → 执行输出 imagePaths
        let graph = ManjuPipelineTemplate.makeManjuPipeline(assets: assetsWithImages)
        let node = try #require(graph.nodes.first { $0.type == ManjuNodeType.assetRef.rawValue })
        let output = try await AssetLockExecutor().execute(node: node, inputs: nil, backend: nil)
        let paths = try #require(output["imagePaths"] as? [String])
        #expect(paths.count == 3)
        #expect(paths.first == "/assets/weixian/face_8angle.png")
        #expect(output["assets"] != nil)
        #expect(output["locked"] as? String == "1")

        // 无图资产库（demo）→ 不输出 imagePaths（不崩溃）
        let demoGraph = ManjuPipelineTemplate.makeManjuPipeline(assets: .demo)
        let demoNode = try #require(demoGraph.nodes.first { $0.type == ManjuNodeType.assetRef.rawValue })
        let demoOutput = try await AssetLockExecutor().execute(node: demoNode, inputs: nil, backend: nil)
        #expect(demoOutput["imagePaths"] == nil)
        #expect(demoOutput["status"] as? String == "succeeded")
    }

    @Test("AssetLockExecutor：canonical asset.id 经 resolver 输出挂载媒体")
    func executorResolvesCanonicalMountedAsset() async throws {
        let assetID = UUID()
        let asset = MediaAsset(
            id: assetID,
            kind: .image,
            source: .imported,
            localURL: "/canonical/mounted.png"
        )
        let node = CanvasNode(
            type: ManjuNodeType.assetRef.rawValue,
            title: "canonical asset",
            backendConfig: NodeBackendConfig(params: ["asset.id": assetID.uuidString])
        )
        let output = try await AssetLockExecutor(
            mediaAssetResolver: TestMediaAssetResolver(value: asset)
        ).execute(node: node, inputs: nil, backend: nil)

        #expect(output["imagePaths"] as? [String] == ["/canonical/mounted.png"])
        #expect(output["image"] as? String == "/canonical/mounted.png")
    }
}
