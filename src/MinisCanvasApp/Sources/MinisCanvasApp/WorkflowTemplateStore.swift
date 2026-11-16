import Foundation
import CanvasCore

// MARK: - AJ-37 工作流模板库（小规模预设节点组合，非一键流水线）
//
// 参照 ComfyUI 的预设节点组合：把「常用节点组合 + 端口连线」固化成可复用模板，
// 一键应用到当前画布（创建节点 + 连线），但**不自动执行**——静置骨架，由用户
// 手动填写内容后显式「执行」。与 MinisCore 的 WorkflowTemplate（文本执行流水线）
// 是两套概念：本库操作的是画布节点图。
//
// 内置模板（NodeTypeRegistry 七大生成类节点范围内）：
//   1. 文本→LLM：文本输入 → LLM 推理
//   2. 文生图：文本 → LLM → 生图
//   3. 文生视频：文本 → LLM → 生视频
//   4. 图生视频：文本 → LLM → 生图 → 生视频（I2V：生图 image 喂生视频 image）

// MARK: - 模板模型

/// 单个模板的连线声明：from 节点索引 → to 节点索引，端口按名匹配。
struct CanvasTemplateLink: Equatable, Sendable {
    let from: Int
    let fromPort: String
    let to: Int
    let toPort: String

    init(from: Int, fromPort: String, to: Int, toPort: String) {
        self.from = from
        self.fromPort = fromPort
        self.to = to
        self.toPort = toPort
    }
}

/// 画布工作流模板：一组节点类型 + 端口连线（静态预设，无执行语义）。
struct CanvasTemplate: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let description: String
    let icon: String
    /// 节点类型列表（顺序即布局横排顺序）。标题留空用注册表默认标题。
    let nodeTypes: [String]
    /// 节点标题（可选，与 nodeTypes 等长；空串用默认标题）
    let nodeTitles: [String]
    /// 端口连线列表
    let links: [CanvasTemplateLink]

    init(
        id: String,
        name: String,
        description: String,
        icon: String,
        nodeTypes: [String],
        nodeTitles: [String] = [],
        links: [CanvasTemplateLink]
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.icon = icon
        self.nodeTypes = nodeTypes
        self.nodeTitles = nodeTitles
        self.links = links
    }
}

// MARK: - 模板库

/// 预设工作流模板库：读取 + 校验 + 构建节点图。
enum WorkflowTemplateStore {
    /// 全部内置模板（id 稳定）。
    static let presets: [CanvasTemplate] = [
        .textToLLM,
        .textToImage,
        .textToVideo,
        .imageToVideo,
    ]

    static func template(id: String) -> CanvasTemplate? {
        presets.first { $0.id == id }
    }

    /// 模板自检：节点类型全部在注册表、连线索引越界、端口名不匹配。
    /// 返回所有校验问题（空数组 = 通过）。
    static func validate(_ template: CanvasTemplate) -> [String] {
        var problems: [String] = []
        guard !template.nodeTypes.isEmpty else {
            problems.append("模板「\(template.name)」没有节点")
            return problems
        }
        for (index, type) in template.nodeTypes.enumerated() {
            guard NodeTypeRegistry.spec(for: type) != nil else {
                problems.append("模板「\(template.name)」节点 \(index) 类型「\(type)」不在注册表")
                continue
            }
        }
        for link in template.links {
            guard link.from < template.nodeTypes.count, link.to < template.nodeTypes.count else {
                problems.append("模板「\(template.name)」连线索引越界：\(link.from)→\(link.to)")
                continue
            }
            guard let fromSpec = NodeTypeRegistry.spec(for: template.nodeTypes[link.from]),
                  let toSpec = NodeTypeRegistry.spec(for: template.nodeTypes[link.to]) else { continue }
            guard fromSpec.outputs.contains(where: { $0.name == link.fromPort }) else {
                problems.append("节点 \(link.from) 无输出端口「\(link.fromPort)」")
                continue
            }
            if !toSpec.inputs.contains(where: { $0.name == link.toPort }) {
                problems.append("节点 \(link.to) 无输入端口「\(link.toPort)」")
            }
        }
        return problems
    }

    /// 把模板构建成独立节点图（节点 + 端口匹配连线），横排布局。
    /// - Parameters:
    ///   - template: 画布模板
    ///   - origin: 布局起点（默认 120,120）
    /// - Returns: 已连线、已横排定位的 NodeGraph；连线端口不匹配时跳过该条。
    static func buildGraph(
        for template: CanvasTemplate,
        origin: Point = Point(x: 120, y: 120)
    ) -> NodeGraph {
        var graph = NodeGraph()
        var nodes: [CanvasNode] = []
        for (index, type) in template.nodeTypes.enumerated() {
            guard let spec = NodeTypeRegistry.spec(for: type) else { continue }
            let title = index < template.nodeTitles.count && !template.nodeTitles[index].isEmpty
                ? template.nodeTitles[index]
                : spec.title
            var node = spec.makeNode(position: Point(x: origin.x + Double(index) * 260, y: origin.y))
            node.title = title
            graph.addNode(node)
            nodes.append(node)
        }
        for link in template.links {
            guard link.from < nodes.count, link.to < nodes.count,
                  let fromNode = nodes[safe: link.from],
                  let toNode = nodes[safe: link.to],
                  let outPort = fromNode.outputs.first(where: { $0.name == link.fromPort }),
                  let inPort = toNode.inputs.first(where: { $0.name == link.toPort })
            else { continue }
            graph.addEdge(Edge(fromNode: fromNode.id, fromPort: outPort.id,
                               toNode: toNode.id, toPort: inPort.id))
        }
        return graph
    }
}

// MARK: - 内置模板

extension CanvasTemplate {
    /// 文本 → LLM：文本输入 → LLM 推理
    static let textToLLM = CanvasTemplate(
        id: "text-llm",
        name: "文本→LLM",
        description: "文本输入 → LLM 推理",
        icon: "text.bubble.fill",
        nodeTypes: ["text", "llm"],
        links: [CanvasTemplateLink(from: 0, fromPort: "text", to: 1, toPort: "prompt")]
    )

    /// 文生图：文本 → LLM → 生图
    static let textToImage = CanvasTemplate(
        id: "text-to-image",
        name: "文生图",
        description: "文本 → LLM → 生图",
        icon: "photo.fill",
        nodeTypes: ["text", "llm", ManjuNodeType.imageGen.rawValue],
        links: [
            CanvasTemplateLink(from: 0, fromPort: "text", to: 1, toPort: "prompt"),
            CanvasTemplateLink(from: 1, fromPort: "text", to: 2, toPort: "prompt"),
        ]
    )

    /// 文生视频：文本 → LLM → 生视频
    static let textToVideo = CanvasTemplate(
        id: "text-to-video",
        name: "文生视频",
        description: "文本 → LLM → 生视频",
        icon: "film.fill",
        nodeTypes: ["text", "llm", ManjuNodeType.videoGen.rawValue],
        links: [
            CanvasTemplateLink(from: 0, fromPort: "text", to: 1, toPort: "prompt"),
            CanvasTemplateLink(from: 1, fromPort: "text", to: 2, toPort: "prompt"),
        ]
    )

    /// 图生视频（I2V）：文本 → LLM → 生图 → 生视频（生图 image 喂生视频 image）
    static let imageToVideo = CanvasTemplate(
        id: "image-to-video",
        name: "图生视频",
        description: "文本 → LLM → 生图 → 生视频（I2V）",
        icon: "video.fill",
        nodeTypes: ["text", "llm", ManjuNodeType.imageGen.rawValue, ManjuNodeType.videoGen.rawValue],
        links: [
            CanvasTemplateLink(from: 0, fromPort: "text", to: 1, toPort: "prompt"),
            CanvasTemplateLink(from: 1, fromPort: "text", to: 2, toPort: "prompt"),
            CanvasTemplateLink(from: 2, fromPort: "image", to: 3, toPort: "image"),
            CanvasTemplateLink(from: 1, fromPort: "text", to: 3, toPort: "prompt"),
        ]
    )
}

// MARK: - 越界安全索引

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}