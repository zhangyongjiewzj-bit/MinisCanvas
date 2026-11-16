import Foundation

// MARK: - 漫剧流水线模板工厂
//
// 一键生成完整骨架 NodeGraph：
// 小说导入 → 剧情大纲 → 剧本 → 分镜 →（Blender 预演）→ 图片/视频提示词 → 图片生成 → 视频生成 → 质检
// 资产引用节点作为全局资产源，注入到图片/视频提示词节点的 assets 输入。
//
// 节点 type 使用 ManjuNodeType.rawValue，保证与模板库/资产注入可互查。
// 每个节点 backendConfig.params 携带对应 ManjuPromptTemplates 系统提示词（键 `systemPrompt`），
// 提示词节点额外携带资产锁定槽位文本（键 `slot.<槽名>`，生成时强制携带）。
//
// Phase B（用户产品方向拍板）：画布新建入口瘦身为 7 类生成类节点，文本创作类 6 节点
// 不再可手动新建，但仍由本模板一键生成（骨架语义：只建节点与连线，不自动执行）。

public enum ManjuPipelineTemplate {

    /// backendConfig.params 中系统提示词的键
    public static let systemPromptKey = "systemPrompt"

    /// assetRef 节点 params 中全部资产图路径的键（JSON 数组字符串，P0 资产层承载图）
    public static let assetImagesKey = "asset.images"

    /// assetRef 节点 params 中全部资产视频路径的键（JSON 数组字符串，B2 视频承载）
    public static let assetVideosKey = "asset.videos"

    // MARK: - 默认后端配置（F10 P0-02：一键流水线节点必须带有效 provider/model）
    //
    // 修复前：makeNode 不写 backendConfig，LLM 节点 providerID 为空 →
    // MinisCanvasLLMInvoker 走「provider 未接入」占位引导，一键流水线执行不出真实结果。
    // 默认值对齐 MinisCore 内置模型表（ProviderType.dashScope.builtInModels 首项
    // LLMModel.qwen38MaxPreview.id == "qwen3.8-max-preview"；生图 gimage2 /
    // 生视频 kling 与 NodeTypeRegistry 默认一致）。CanvasCore 不依赖 MinisCore，
    // 故此处为对齐常量——新增内置模型时两处需同步。

    /// LLM 节点默认后端：百炼 · qwen3.8-max-preview（DashScope OpenAI 兼容模式）
    public static let defaultLLMConfig = NodeBackendConfig(
        providerType: .cloud,
        providerID: "bailian",
        modelID: "qwen3.8-max-preview",
        params: ["temperature": "0.7", "maxTokens": "4096"]
    )

    /// 生图节点默认后端：gimage2 · gpt-image-2-official
    public static let defaultImageGenConfig = NodeBackendConfig(
        providerType: .cloud,
        providerID: "gimage2",
        modelID: "gpt-image-2-official",
        params: ["size": "1024x1024"]
    )

    /// 生视频节点默认后端：可灵 · kling-v2（时长用 UI 选择器格式 "5s"，
    /// 执行层 MinisCanvasVideoInvoker 归一化为纯秒数后透传 Provider）
    public static let defaultVideoGenConfig = NodeBackendConfig(
        providerType: .cloud,
        providerID: "kling",
        modelID: "kling-v2",
        params: ["duration": "5s", "resolution": "720p"]
    )

    /// 按节点类型返回默认后端配置：
    /// LLM 类（novelImport/plotOutline/script/storyboard/imagePrompt/videoPrompt/qcCheck）→
    /// 百炼；imageGen → gimage2；videoGen → 可灵；blenderPreview/assetRef 不依赖模型后端（nil）。
    public static func defaultBackendConfig(for type: ManjuNodeType) -> NodeBackendConfig? {
        switch type {
        case .imageGen:
            return defaultImageGenConfig
        case .videoGen:
            return defaultVideoGenConfig
        case .blenderPreview, .assetRef:
            return nil
        case .novelImport, .plotOutline, .script, .storyboard,
             .imagePrompt, .videoPrompt, .qcCheck, .reviewGate:
            return defaultLLMConfig
        }
    }

    // MARK: - Phase B 分类（与瘦身后的 NodeTypeRegistry 对齐）
    //
    // 画布「添加节点」入口只保留生成类节点；文本创作类仍由本模板一键生成（全流程骨架
    // 需要它们），类型定义全部保留以兼容旧图数据。分类与 app 层
    // NodeTypeRegistry.creatableTypes/textCreativeTypes 为同一事实的两处投影，
    // 新增节点类型时两处需同步（测试 PhaseBTemplateClassificationTests 守护一致性）。

    /// 模板 11 类中画布可新建的生成类节点（对齐 registry 保留清单）
    public static let creatableNodeTypes: Set<ManjuNodeType> = [
        .imageGen, .videoGen, .blenderPreview, .qcCheck, .assetRef,
    ]

    /// 模板 11 类中的文本创作类节点（仅经一键流水线/旧图数据出现，不进新建入口）
    public static let textCreativeNodeTypes: Set<ManjuNodeType> = [
        .novelImport, .plotOutline, .script, .storyboard, .imagePrompt, .videoPrompt,
    ]

    /// 一键生成漫剧流水线骨架图。
    ///
    /// - Parameters:
    ///   - assets: 全局资产库（角色卡/服装/场景/色板/风格锁）；传 `.demo` 可得演示资产
    ///   - origin: 布局起点，默认 (120, 120)
    /// - Returns: 12 节点 + 16 连线的完整骨架 NodeGraph（已自动布局）
    public static func makeManjuPipeline(
        assets: ManjuAssetLibrary = .demo,
        origin: Point = Point(x: 120, y: 120)
    ) -> NodeGraph {
        var graph = NodeGraph()

        // MARK: 节点（端口按数据流定义）

        let novelImport = makeNode(.novelImport, inputs: [], outputs: ["text"])
        let plotOutline = makeNode(.plotOutline, inputs: ["text"], outputs: ["text"])
        let script = makeNode(.script, inputs: ["text"], outputs: ["text"])
        let storyboard = makeNode(.storyboard, inputs: ["text"], outputs: ["text", "frames"])
        let blenderPreview = makeNode(.blenderPreview, inputs: ["storyboard"], outputs: ["blocking"])
        // B7：模板侧 assetRef 输出补 image 端口（与 App 侧 spec 对齐）：资产参考图片首条，
        // 经 assetRef.image → imageGen.image 连线喂 img2img 参考图（执行器输出 image = imagePaths 首条）
        let assetRef = makeNode(.assetRef, inputs: [], outputs: ["assets", "video", "image"])
        let imagePrompt = makeNode(.imagePrompt, inputs: ["storyboard", "blocking", "assets"], outputs: ["prompt"])
        let videoPrompt = makeNode(.videoPrompt, inputs: ["storyboard", "blocking", "assets"], outputs: ["prompt"])
        let imageGen = makeNode(.imageGen, inputs: ManjuNodeType.imageGenInputPorts, outputs: ManjuNodeType.imageGenOutputPorts)
        let videoGen = makeNode(.videoGen, inputs: ManjuNodeType.videoGenInputPorts, outputs: ManjuNodeType.videoGenOutputPorts)
        let reviewGate = makeNode(.reviewGate, inputs: ManjuNodeType.reviewGateInputPorts, outputs: ManjuNodeType.reviewGateOutputPorts)
        // 质检：规范端口 image/text/video（主链接 videoGen.video → qcCheck.video 审视频成片；
        // image/text 可选——多图待审 / 提示词任务单文本，见 ManjuNodeType.qcCheckInputPorts）
        let qcCheck = makeNode(.qcCheck,
                               inputs: ManjuNodeType.qcCheckInputPorts,
                               outputs: ManjuNodeType.qcCheckOutputPorts)

        for node in [novelImport, plotOutline, script, storyboard, blenderPreview, assetRef,
                     imagePrompt, videoPrompt, imageGen, videoGen, reviewGate, qcCheck] {
            graph.addNode(node)
        }

        // MARK: 连线（主链 + 资产注入 + 首尾帧喂视频）

        func connect(_ from: CanvasNode, _ outPort: String, _ to: CanvasNode, _ inPort: String) {
            guard
                let fromPort = from.outputs.first(where: { $0.name == outPort }),
                let toPort = to.inputs.first(where: { $0.name == inPort })
            else {
                assertionFailure("漫剧流水线模板端口不匹配：\(from.type).\(outPort) → \(to.type).\(inPort)")
                return
            }
            graph.addEdge(Edge(fromNode: from.id, fromPort: fromPort.id,
                               toNode: to.id, toPort: toPort.id))
        }

        // 主链：小说 → 剧情 → 脚本 → 分镜
        connect(novelImport, "text", plotOutline, "text")
        connect(plotOutline, "text", script, "text")
        connect(script, "text", storyboard, "text")
        // 分镜 → 预演 / 两个提示词节点
        connect(storyboard, "text", blenderPreview, "storyboard")
        connect(storyboard, "text", imagePrompt, "storyboard")
        connect(storyboard, "text", videoPrompt, "storyboard")
        // 预演站位图 → 提示词
        connect(blenderPreview, "blocking", imagePrompt, "blocking")
        connect(blenderPreview, "blocking", videoPrompt, "blocking")
        // 资产锁定注入：资产引用 → 两个提示词节点
        connect(assetRef, "assets", imagePrompt, "assets")
        connect(assetRef, "assets", videoPrompt, "assets")
        // 提示词 → 生成；首帧图喂视频生成（I2V）
        connect(imagePrompt, "prompt", imageGen, "prompt")
        connect(videoPrompt, "prompt", videoGen, "prompt")
        connect(imageGen, "image", videoGen, "image")
        // B2 V2V：资产参考视频（assetRef.video 输出端口 = 资产视频首条）→ 生视频 video 输入端口。
        // 资产库无视频时执行端不输出 video 键，videoGen 侧 resolveReferenceVideos 跳过（无害）。
        connect(assetRef, "video", videoGen, "video")
        // 视频提示词 → 审核闸口（单份文本审核：PASS/REJECT/PENDING）
        connect(videoPrompt, "prompt", reviewGate, "text")
        // 视频 → 质检
        connect(videoGen, "video", qcCheck, "video")

        // MARK: 系统提示词 + 资产锁定注入（写入 backendConfig.params）

        for index in graph.nodes.indices {
            let node = graph.nodes[index]
            guard let type = ManjuNodeType(rawValue: node.type),
                  let template = ManjuPromptTemplates.template(for: type) else { continue }
            var config = node.backendConfig ?? NodeBackendConfig()
            config.params[systemPromptKey] = template.systemPrompt
            // 提示词节点：注入资产锁定槽位文本（生成时强制携带，保证角色一致性）
            for (key, value) in ManjuAssetInjection.injectionParams(for: assets, nodeType: type) {
                config.params[key] = value
            }
            // 资产引用节点：附带资产摘要 + 真实图片路径（P0 资产层承载图）
            if type == .assetRef {
                config.params[ManjuAssetInjection.assetRefSummaryKey] = assetSummary(of: assets)
                // 全部资产图路径 JSON 注入 → 执行端通过 canonical resolver
                // 输出 imagePaths 供下游 img2img；不再写 legacy result.*。
                config.params[assetImagesKey] = assetImagesJSON(of: assets)
                // B2 视频承载：全部资产视频路径 JSON 注入 → AssetLockExecutor 输出 videoPaths + video
                // （V2V 参考视频，经 assetRef.video 输出端口进生视频节点多输入）
                config.params[assetVideosKey] = assetVideosJSON(of: assets)
            }
            graph.nodes[index].backendConfig = config
        }

        // MARK: 自动布局（分层，未手动定位节点全部计算坐标）

        if let positions = try? GraphLayout(nodeSpacing: 140, layerSpacing: 260, origin: origin)
            .layeredLayout(graph: graph) {
            for index in graph.nodes.indices {
                if let pos = positions[graph.nodes[index].id] {
                    graph.nodes[index].position = pos
                }
            }
        }

        return graph
    }

    /// 资产库摘要（资产引用节点展示用）
    /// 视频资产与图片并列注入：资产带参考视频（角色/服装/场景 referenceVideoPath）时，
    /// 逐条追加「参考视频：<路径>」行（去重），与锁定清单同文本流进 assets 输出端口。
    public static func assetSummary(of assets: ManjuAssetLibrary) -> String {
        var lines: [String] = []
        for c in assets.characters { lines.append("角色卡：" + c.name + "（锁 " + c.lockParts.joined(separator: "、") + "）") }
        for c in assets.costumes { lines.append("服装：" + c.name) }
        for s in assets.scenes { lines.append("场景：" + s.name) }
        if let p = assets.palette { lines.append("色板 " + p.version + "：" + p.entries.map { "#" + $0.hex }.joined(separator: "/")) }
        if let lock = assets.styleLock { lines.append("风格锁：" + lock) }
        for path in assetVideoPaths(of: assets) { lines.append("参考视频：" + path) }
        return lines.joined(separator: "\n")
    }

    // MARK: - P0 资产层承载图：真实图片路径收集/注入（定妆图/服装/场景母图进画布资产层）

    /// 收集资产库全部真实图片路径（角色定妆图 → 服装图 → 场景母图），
    /// 按声明顺序、跳过空值、去重（同一文件被多资产引用只出现一次）。
    /// 供 assetRef 节点注入 asset.images（全量，下游 img2img）。
    public static func assetImagePaths(of assets: ManjuAssetLibrary) -> [String] {
        var paths: [String] = []
        var seen = Set<String>()
        func appendIfValid(_ path: String?) {
            guard let path,
                  !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seen.insert(path).inserted else { return }
            paths.append(path)
        }
        for c in assets.characters { appendIfValid(c.referenceImagePath) }
        for c in assets.costumes { appendIfValid(c.referenceImagePath) }
        for s in assets.scenes { appendIfValid(s.masterImagePath) }
        return paths
    }

    /// 资产图路径数组 → JSON 字符串（asset.images 键值；空数组也编码为 `[]`，保证执行端可解析）。
    public static func assetImagesJSON(of assets: ManjuAssetLibrary) -> String {
        let paths = assetImagePaths(of: assets)
        guard let data = try? JSONSerialization.data(withJSONObject: paths),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    /// 解析 asset.images JSON 字符串 → 路径数组（执行端 AssetLockExecutor 用；非法输入返回空数组）。
    public static func parseAssetImages(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return list
    }

    /// 收集资产库全部真实视频路径（角色参考视频 → 服装参考视频 → 场景母视频），
    /// 按声明顺序、跳过空值、去重（同一视频被多资产引用只出现一次）。
    /// 供 assetRef 节点注入 asset.videos（全量，下游 V2V 参考视频）。
    public static func assetVideoPaths(of assets: ManjuAssetLibrary) -> [String] {
        var paths: [String] = []
        var seen = Set<String>()
        func appendIfValid(_ path: String?) {
            guard let path,
                  !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seen.insert(path).inserted else { return }
            paths.append(path)
        }
        for c in assets.characters { appendIfValid(c.referenceVideoPath) }
        for c in assets.costumes { appendIfValid(c.referenceVideoPath) }
        for s in assets.scenes { appendIfValid(s.masterVideoPath) }
        return paths
    }

    /// 资产视频路径数组 → JSON 字符串（asset.videos 键值；空数组也编码为 `[]`，保证执行端可解析）。
    public static func assetVideosJSON(of assets: ManjuAssetLibrary) -> String {
        let paths = assetVideoPaths(of: assets)
        guard let data = try? JSONSerialization.data(withJSONObject: paths),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    /// 解析 asset.videos JSON 字符串 → 路径数组（执行端 AssetLockExecutor 用；非法输入返回空数组）。
    public static func parseAssetVideos(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return list
    }

    /// 创建单个流水线节点：type = ManjuNodeType.rawValue，标题 = 中文名。
    /// F10 P0-02：携带有效默认 backendConfig（LLM→百炼 / 生图→gimage2 / 生视频→可灵），
    /// 保证一键流水线执行即走真实 Provider 链，而非「未接入」占位引导。
    private static func makeNode(
        _ type: ManjuNodeType,
        inputs: [String],
        outputs: [String]
    ) -> CanvasNode {
        CanvasNode(
            type: type.rawValue,
            title: type.displayName,
            position: .zero,
            inputs: inputs.map { Port(name: $0, direction: .input, dataType: "string") },
            outputs: outputs.map { Port(name: $0, direction: .output, dataType: "string") },
            backendConfig: defaultBackendConfig(for: type)
        )
    }
}
