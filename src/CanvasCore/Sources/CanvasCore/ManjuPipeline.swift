import Foundation

// MARK: - 漫剧流水线模板（M1b）
//
// 一键生成漫剧全流程骨架节点图 + 分镜节点占位生成。
// 流水线：小说导入 → 剧情拆解 → 脚本生成 → 分镜生成 → 图片提示词 → 视频提示词
//        → 生图 → 生视频 → QC检查（视频首帧图喂入生视频，I2V 链路）。
//
// 节点 type 使用 ManjuNodeType.rawValue；每个节点带默认 backendConfig：
//   - LLM 节点（小说导入…QC检查）：bailian / qwen3.8-max-preview
//   - 生图节点：gimage2
//   - 生视频节点：kling
// 位置按 GraphLayout 分层风格排布（层号由 DAGScheduler.layers 计算，顺带验证无环）。
// 纯 Foundation 实现，不依赖 SwiftUI / AppKit / CoreGraphics。

public struct ManjuPipeline {

    // MARK: - 默认模型配置

    /// LLM 节点默认后端：百炼 · qwen3.8-max-preview
    public static let defaultLLMConfig = NodeBackendConfig(
        providerType: .cloud,
        providerID: "bailian",
        modelID: "qwen3.8-max-preview",
        params: ["temperature": "0.7", "maxTokens": "4096"]
    )

    /// 生图节点默认后端：gimage2（9:16 竖屏，漫剧默认画幅）
    public static let defaultImageGenConfig = NodeBackendConfig(
        providerType: .cloud,
        providerID: "gimage2",
        modelID: "gimage2",
        params: ["size": "1024x1536", "aspectRatio": "9:16"]
    )

    /// 生视频节点默认后端：kling（5 秒 1080p）
    public static let defaultVideoGenConfig = NodeBackendConfig(
        providerType: .cloud,
        providerID: "kling",
        modelID: "kling",
        params: ["duration": "5", "resolution": "1080p"]
    )

    // MARK: - 流水线标题（任务约定中文名）

    private static func pipelineTitle(for type: ManjuNodeType) -> String {
        switch type {
        case .novelImport: return "小说导入"
        case .plotOutline: return "剧情拆解"
        case .script: return "脚本生成"
        case .storyboard: return "分镜生成"
        case .imagePrompt: return "图片提示词"
        case .videoPrompt: return "视频提示词"
        case .imageGen: return "生图"
        case .videoGen: return "生视频"
        case .qcCheck: return "QC检查"
        case .blenderPreview: return "Blender 预演"
        case .assetRef: return "资产引用"
        case .reviewGate: return "审核"
        }
    }

    // MARK: - 一键生成全流程骨架

    /// 一键生成漫剧标准流水线骨架节点图。
    ///
    /// 9 节点 + 9 连线：主链（小说导入→剧情拆解→脚本生成→分镜生成），
    /// 分镜后分流到图片/视频两个提示词节点，图片提示词→生图→生视频（首帧 I2V），
    /// 生视频→QC检查。节点已按依赖连好边、位置按 GraphLayout 分层风格排布，
    /// 可直接用 `DAGScheduler.layers(in:)` 验证无环。
    ///
    /// - Returns: 全流程骨架 NodeGraph
    public static func standardPipeline() -> NodeGraph {
        var graph = NodeGraph()

        // MARK: 节点（端口按数据流定义）

        let novelImport = makeNode(.novelImport, inputs: [], outputs: ["text"], config: defaultLLMConfig)
        let plotOutline = makeNode(.plotOutline, inputs: ["text"], outputs: ["text"], config: defaultLLMConfig)
        let script = makeNode(.script, inputs: ["text"], outputs: ["text"], config: defaultLLMConfig)
        let storyboard = makeNode(.storyboard, inputs: ["text"], outputs: ["text"], config: defaultLLMConfig)
        let imagePrompt = makeNode(.imagePrompt, inputs: ["storyboard"], outputs: ["prompt"], config: defaultLLMConfig)
        let videoPrompt = makeNode(.videoPrompt, inputs: ["storyboard"], outputs: ["prompt"], config: defaultLLMConfig)
        let imageGen = makeNode(.imageGen, inputs: ManjuNodeType.imageGenInputPorts, outputs: ManjuNodeType.imageGenOutputPorts, config: defaultImageGenConfig)
        let videoGen = makeNode(.videoGen, inputs: ManjuNodeType.videoGenInputPorts, outputs: ManjuNodeType.videoGenOutputPorts, config: defaultVideoGenConfig)
        let qcCheck = makeNode(.qcCheck, inputs: ["video"], outputs: ["report"], config: defaultLLMConfig)

        for node in [novelImport, plotOutline, script, storyboard,
                     imagePrompt, videoPrompt, imageGen, videoGen, qcCheck] {
            graph.addNode(node)
        }

        // MARK: 连线（按依赖；端口名匹配失败即崩溃，保证模板自洽）

        connect(novelImport, "text", to: plotOutline, "text", in: &graph)
        connect(plotOutline, "text", to: script, "text", in: &graph)
        connect(script, "text", to: storyboard, "text", in: &graph)
        // 分镜 → 两个提示词节点（分流）
        connect(storyboard, "text", to: imagePrompt, "storyboard", in: &graph)
        connect(storyboard, "text", to: videoPrompt, "storyboard", in: &graph)
        // 提示词 → 生成
        connect(imagePrompt, "prompt", to: imageGen, "prompt", in: &graph)
        connect(videoPrompt, "prompt", to: videoGen, "prompt", in: &graph)
        // 生图首帧 → 生视频（I2V）
        connect(imageGen, "image", to: videoGen, "image", in: &graph)
        // 视频 → 质检
        connect(videoGen, "video", to: qcCheck, "video", in: &graph)

        // MARK: 位置（GraphLayout 分层风格：层号×layerSpacing 横排，层内纵排）

        if let layers = try? DAGScheduler.layers(in: graph) {
            let origin = Point(x: 120, y: 120)
            let layerSpacing = 260.0
            let nodeSpacing = 160.0
            for (layerIndex, layer) in layers.enumerated() {
                for (rowIndex, nodeID) in layer.enumerated() {
                    if let index = graph.nodes.firstIndex(where: { $0.id == nodeID }) {
                        graph.nodes[index].position = Point(
                            x: origin.x + Double(layerIndex) * layerSpacing,
                            y: origin.y + Double(rowIndex) * nodeSpacing
                        )
                    }
                }
            }
        }

        return graph
    }

    // MARK: - 分镜节点占位生成

    /// 给定脚本文本，生成 N 个分镜节点（占位实现，后续接真实 LLM 拆解）。
    ///
    /// 占位启发式：按空行分段数估算分镜数（最少 1，最多 24）。
    /// 每个分镜节点输入 `script`（整段脚本文本），输出 `prompt` 一个提示词槽位占位。
    ///
    /// - Parameter script: 脚本文本
    /// - Returns: N 个分镜节点，标题「分镜1..N」
    public static func storyboardNodes(script: String) -> [CanvasNode] {
        let count = storyboardCount(from: script)
        return (1...count).map { index in
            CanvasNode(
                type: ManjuNodeType.storyboard.rawValue,
                title: "分镜\(index)",
                inputs: [Port(name: "script", direction: .input, dataType: "string")],
                outputs: [Port(name: "prompt", direction: .output, dataType: "string")],
                backendConfig: defaultLLMConfig
            )
        }
    }

    /// 分镜数量占位启发式：按空行分段数估算（1...24）。
    /// 空文本也返回 1，保证画布上始终有可填写的占位节点。
    public static func storyboardCount(from script: String) -> Int {
        let paragraphs = script
            .split(separator: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !paragraphs.isEmpty else { return 1 }
        return min(paragraphs.count, 24)
    }

    // MARK: - 私有工具

    /// 创建单个流水线节点：type = ManjuNodeType.rawValue，标题 = 中文名，带默认 backendConfig
    private static func makeNode(
        _ type: ManjuNodeType,
        inputs: [String],
        outputs: [String],
        config: NodeBackendConfig
    ) -> CanvasNode {
        CanvasNode(
            type: type.rawValue,
            title: pipelineTitle(for: type),
            position: .zero,
            inputs: inputs.map { Port(name: $0, direction: .input, dataType: "string") },
            outputs: outputs.map { Port(name: $0, direction: .output, dataType: "string") },
            backendConfig: config
        )
    }

    /// 按端口名连线；端口不匹配说明模板定义有误，直接崩溃暴露问题
    private static func connect(
        _ from: CanvasNode,
        _ fromPortName: String,
        to: CanvasNode,
        _ toPortName: String,
        in graph: inout NodeGraph
    ) {
        guard
            let fromPort = from.outputs.first(where: { $0.name == fromPortName }),
            let toPort = to.inputs.first(where: { $0.name == toPortName })
        else {
            fatalError("漫剧流水线模板端口不匹配：\(from.type).\(fromPortName) → \(to.type).\(toPortName)")
        }
        graph.addEdge(Edge(fromNode: from.id, fromPort: fromPort.id,
                           toNode: to.id, toPort: toPort.id))
    }
}
