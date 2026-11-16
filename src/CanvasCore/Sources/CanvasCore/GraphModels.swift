import Foundation

/// 二维坐标点（纯 Foundation，不依赖 CoreGraphics）
public struct Point: Codable, Equatable, Sendable, Hashable {
    public static let currentSchemaVersion = CanvasSchema.currentVersion
    public let schemaVersion: Int
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double, schemaVersion: Int = Point.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.x = x
        self.y = y
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, x, y }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try CanvasSchema.decodeVersion(from: c, key: .schemaVersion)
        self.x = try c.decode(Double.self, forKey: .x)
        self.y = try c.decode(Double.self, forKey: .y)
        guard x.isFinite, y.isFinite else { throw CanvasSchemaError.invalidField("Point") }
    }

    public func validate() throws {
        guard x.isFinite, y.isFinite else { throw CanvasSchemaError.invalidField("Point") }
    }
}

/// 端口方向
public enum PortDirection: String, Codable, Equatable, Sendable {
    case input
    case output
}

/// 节点端口
public struct Port: Identifiable, Codable, Equatable, Sendable {
    public static let currentSchemaVersion = CanvasSchema.currentVersion
    public let schemaVersion: Int
    public let id: UUID
    public var name: String
    public var direction: PortDirection
    public var dataType: String

    public init(
        id: UUID = UUID(),
        name: String,
        direction: PortDirection,
        dataType: String,
        schemaVersion: Int = Port.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.direction = direction
        self.dataType = dataType
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, id, name, direction, dataType }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try CanvasSchema.decodeVersion(from: c, key: .schemaVersion)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.direction = try c.decode(PortDirection.self, forKey: .direction)
        self.dataType = try c.decode(String.self, forKey: .dataType)
        try validate()
    }

    public func validate() throws {
        try CanvasSchema.requireNonEmpty(name, "port.name")
        try CanvasSchema.requireNonEmpty(dataType, "port.dataType")
    }
}

/// 节点执行状态
public enum NodeStatus: String, Codable, Equatable, Sendable {
    case pending
    case running
    case succeeded
    /// 缓存命中：同输入结果直接复用，不重跑（UI 灰显「已缓存」，等价 ComfyUI execution_cached）
    case cached
    case failed
    case skipped
}

/// 画布节点
public struct CanvasNode: Identifiable, Codable, Equatable, Sendable {
    public static let currentSchemaVersion = CanvasSchema.currentVersion
    public let schemaVersion: Int
    public let id: UUID
    public var type: String
    public var title: String
    public var position: Point
    public var inputs: [Port]
    public var outputs: [Port]
    public var status: NodeStatus
    /// 预留：每节点可选本地/云端后端（如 ollama / gimage2 / kling）
    public var backendID: String?
    /// 节点级模型配置；nil = 使用全局默认模型
    public var backendConfig: NodeBackendConfig?

    public init(
        id: UUID = UUID(),
        type: String,
        title: String,
        position: Point = Point(x: 0, y: 0),
        inputs: [Port] = [],
        outputs: [Port] = [],
        status: NodeStatus = .pending,
        backendID: String? = nil,
        backendConfig: NodeBackendConfig? = nil,
        schemaVersion: Int = CanvasNode.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.type = type
        self.title = title
        self.position = position
        self.inputs = inputs
        self.outputs = outputs
        self.status = status
        self.backendID = backendID
        self.backendConfig = backendConfig
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, type, title, position, inputs, outputs, status, backendID, backendConfig
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try CanvasSchema.decodeVersion(from: c, key: .schemaVersion)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.type = try c.decode(String.self, forKey: .type)
        self.title = try c.decode(String.self, forKey: .title)
        self.position = try c.decode(Point.self, forKey: .position)
        self.inputs = try c.decode([Port].self, forKey: .inputs)
        self.outputs = try c.decode([Port].self, forKey: .outputs)
        self.status = try c.decode(NodeStatus.self, forKey: .status)
        self.backendID = try c.decodeIfPresent(String.self, forKey: .backendID)
        self.backendConfig = try c.decodeIfPresent(NodeBackendConfig.self, forKey: .backendConfig)
        try validate()
    }

    public func validate() throws {
        try CanvasSchema.requireNonEmpty(type, "node.type")
        try CanvasSchema.requireNonEmpty(title, "node.title")
        try position.validate()
        try inputs.forEach { try $0.validate() }
        try outputs.forEach { try $0.validate() }
        guard Set(inputs.map(\.id)).count == inputs.count,
              Set(outputs.map(\.id)).count == outputs.count else {
            throw CanvasSchemaError.invalidField("node.ports")
        }
    }
}

/// 节点间连线（port 级连接）
public struct Edge: Identifiable, Codable, Equatable, Sendable {
    public static let currentSchemaVersion = CanvasSchema.currentVersion
    public let schemaVersion: Int
    public let id: UUID
    public var fromNode: UUID
    public var fromPort: UUID
    public var toNode: UUID
    public var toPort: UUID

    public init(
        id: UUID = UUID(),
        fromNode: UUID,
        fromPort: UUID,
        toNode: UUID,
        toPort: UUID,
        schemaVersion: Int = Edge.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.fromNode = fromNode
        self.fromPort = fromPort
        self.toNode = toNode
        self.toPort = toPort
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, fromNode, fromPort, toNode, toPort
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try CanvasSchema.decodeVersion(from: c, key: .schemaVersion)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.fromNode = try c.decode(UUID.self, forKey: .fromNode)
        self.fromPort = try c.decode(UUID.self, forKey: .fromPort)
        self.toNode = try c.decode(UUID.self, forKey: .toNode)
        self.toPort = try c.decode(UUID.self, forKey: .toPort)
    }
}

/// 节点图（无向增删 + 有向查询）
public struct NodeGraph: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = CanvasSchema.currentVersion
    public let schemaVersion: Int
    public var nodes: [CanvasNode]
    public var edges: [Edge]
    public var revision: Int

    public init(
        nodes: [CanvasNode] = [],
        edges: [Edge] = [],
        revision: Int = 0,
        schemaVersion: Int = NodeGraph.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.nodes = nodes
        self.edges = edges
        self.revision = max(0, revision)
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, nodes, edges, revision }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try CanvasSchema.decodeVersion(from: c, key: .schemaVersion)
        self.nodes = try c.decode([CanvasNode].self, forKey: .nodes)
        self.edges = try c.decode([Edge].self, forKey: .edges)
        self.revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        try validate()
    }

    /// 内容指纹不包含 revision，便于 compare-and-swap 检查内容是否仍相同。
    public var fingerprint: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(FingerprintPayload(nodes: nodes, edges: edges))) ?? Data()
        return StableFingerprint.hex(data)
    }

    public func validate() throws {
        try CanvasSchema.requireNonNegative(revision, "graph.revision")
        try nodes.forEach { try $0.validate() }
        guard Set(nodes.map(\.id)).count == nodes.count else {
            throw CanvasSchemaError.invalidField("graph.nodes")
        }
        guard Set(edges.map(\.id)).count == edges.count else {
            throw CanvasSchemaError.invalidField("graph.edges")
        }
        for edge in edges {
            guard let from = node(id: edge.fromNode), let to = node(id: edge.toNode),
                  let fromPort = from.outputs.first(where: { $0.id == edge.fromPort }),
                  let toPort = to.inputs.first(where: { $0.id == edge.toPort }),
                  fromPort.direction == .output, toPort.direction == .input else {
                throw CanvasSchemaError.invalidField("graph.edge.\(edge.id)")
            }
        }
    }

    public var isValid: Bool { (try? validate()) != nil }

    // MARK: - 增删

    public mutating func addNode(_ node: CanvasNode) {
        nodes.append(node)
        revision += 1
    }

    public mutating func addEdge(_ edge: Edge) {
        edges.append(edge)
        revision += 1
    }

    /// 删除节点及其关联的所有边
    public mutating func removeNode(id: UUID) {
        let oldCount = nodes.count + edges.count
        nodes.removeAll { $0.id == id }
        edges.removeAll { $0.fromNode == id || $0.toNode == id }
        if nodes.count + edges.count != oldCount { revision += 1 }
    }

    public mutating func removeEdge(id: UUID) {
        let oldCount = edges.count
        edges.removeAll { $0.id == id }
        if edges.count != oldCount { revision += 1 }
    }

    // MARK: - 查询

    public func node(id: UUID) -> CanvasNode? {
        nodes.first { $0.id == id }
    }

    public func edge(id: UUID) -> Edge? {
        edges.first { $0.id == id }
    }

    /// 与指定节点直接相连的邻居节点（含输入与输出方向）。
    /// 平行重复边 / 双向边只计一次（语义为「邻居节点集合」，保持首次出现顺序）。
    public func neighbors(of nodeID: UUID) -> [CanvasNode] {
        var seen: Set<UUID> = []
        var result: [CanvasNode] = []
        for edge in edges {
            let otherID: UUID?
            if edge.fromNode == nodeID {
                otherID = edge.toNode
            } else if edge.toNode == nodeID {
                otherID = edge.fromNode
            } else {
                otherID = nil
            }
            if let otherID, let node = node(id: otherID), seen.insert(otherID).inserted {
                result.append(node)
            }
        }
        return result
    }

    /// 从指定节点出发的出边
    public func outgoingEdges(from nodeID: UUID) -> [Edge] {
        edges.filter { $0.fromNode == nodeID }
    }

    /// 指向指定节点的入边
    public func incomingEdges(to nodeID: UUID) -> [Edge] {
        edges.filter { $0.toNode == nodeID }
    }

    /// 两节点之间的所有边（任一方向）
    public func edges(from a: UUID, to b: UUID) -> [Edge] {
        edges.filter { ($0.fromNode == a && $0.toNode == b) || ($0.fromNode == b && $0.toNode == a) }
    }

    /// 指定节点的直接前驱（有边指向它）
    public func predecessors(of nodeID: UUID) -> [CanvasNode] {
        incomingEdges(to: nodeID).compactMap { node(id: $0.fromNode) }
    }

    /// 指定节点的直接后继（它指向的节点）
    public func successors(of nodeID: UUID) -> [CanvasNode] {
        outgoingEdges(from: nodeID).compactMap { node(id: $0.toNode) }
    }
}

private struct FingerprintPayload: Codable {
    let nodes: [CanvasNode]
    let edges: [Edge]
}

private enum StableFingerprint {
    static func hex(_ data: Data) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in data { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return String(format: "%016llx", hash)
    }
}
