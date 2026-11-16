import Foundation

/// CanvasCore DTO 使用的 schema 版本错误。未知的未来版本必须拒绝，避免静默丢字段。
public enum CanvasSchemaError: Error, Equatable, Sendable, LocalizedError {
    case unsupportedVersion(expected: Int, actual: Int)
    case invalidField(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(expected, actual):
            return "CanvasCore schemaVersion 不受支持：期望 \(expected)，实际 \(actual)"
        case let .invalidField(field):
            return "CanvasCore 字段无效：\(field)"
        }
    }
}

internal enum CanvasSchema {
    static let currentVersion = 1

    static func decodeVersion<Key: CodingKey>(
        from container: KeyedDecodingContainer<Key>,
        key: Key
    ) throws -> Int {
        let version = try container.decodeIfPresent(Int.self, forKey: key) ?? 1
        guard version == currentVersion else {
            throw CanvasSchemaError.unsupportedVersion(expected: currentVersion, actual: version)
        }
        return version
    }

    static func requireNonNegative(_ value: Int, _ field: String) throws {
        guard value >= 0 else { throw CanvasSchemaError.invalidField(field) }
    }

    static func requireNonEmpty(_ value: String, _ field: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CanvasSchemaError.invalidField(field)
        }
    }
}

/// 可安全传输的画布 patch 操作。
public enum CanvasPatchOperation: Codable, Equatable, Sendable {
    case addNode(CanvasNode)
    case updateNode(CanvasNode)
    case removeNode(UUID)
    case addEdge(Edge)
    case removeEdge(UUID)

    public static let currentSchemaVersion = CanvasSchema.currentVersion
    public var schemaVersion: Int { Self.currentSchemaVersion }

    private enum CodingKeys: String, CodingKey { case schemaVersion, kind, node, edge, id }
    private enum Kind: String, Codable { case addNode, updateNode, removeNode, addEdge, removeEdge }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        switch self {
        case let .addNode(node):
            try container.encode(Kind.addNode, forKey: .kind)
            try container.encode(node, forKey: .node)
        case let .updateNode(node):
            try container.encode(Kind.updateNode, forKey: .kind)
            try container.encode(node, forKey: .node)
        case let .removeNode(id):
            try container.encode(Kind.removeNode, forKey: .kind)
            try container.encode(id, forKey: .id)
        case let .addEdge(edge):
            try container.encode(Kind.addEdge, forKey: .kind)
            try container.encode(edge, forKey: .edge)
        case let .removeEdge(id):
            try container.encode(Kind.removeEdge, forKey: .kind)
            try container.encode(id, forKey: .id)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try CanvasSchema.decodeVersion(from: container, key: .schemaVersion)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .addNode: self = .addNode(try container.decode(CanvasNode.self, forKey: .node))
        case .updateNode: self = .updateNode(try container.decode(CanvasNode.self, forKey: .node))
        case .removeNode: self = .removeNode(try container.decode(UUID.self, forKey: .id))
        case .addEdge: self = .addEdge(try container.decode(Edge.self, forKey: .edge))
        case .removeEdge: self = .removeEdge(try container.decode(UUID.self, forKey: .id))
        }
    }
}

public enum CanvasPatchError: Error, Equatable, Sendable, LocalizedError {
    case canvasMismatch(expected: UUID, actual: UUID?)
    case revisionMismatch(expected: Int, actual: Int)
    case fingerprintMismatch(expected: String, actual: String)
    case duplicateNode(UUID)
    case nodeNotFound(UUID)
    case duplicateEdge(UUID)
    case edgeNotFound(UUID)
    case invalidEdge(UUID)
    case invalidGraph
    case cycleDetected

    public var errorDescription: String? {
        switch self {
        case let .canvasMismatch(expected, actual): return "canvasID 不匹配：期望 \(expected)，实际 \(String(describing: actual))"
        case let .revisionMismatch(expected, actual): return "revision 已过期：期望 \(expected)，实际 \(actual)"
        case let .fingerprintMismatch(expected, actual): return "图 fingerprint 不匹配：期望 \(expected)，实际 \(actual)"
        case let .duplicateNode(id): return "节点已存在：\(id)"
        case let .nodeNotFound(id): return "节点不存在：\(id)"
        case let .duplicateEdge(id): return "连线已存在：\(id)"
        case let .edgeNotFound(id): return "连线不存在：\(id)"
        case let .invalidEdge(id): return "连线引用的节点或端口无效：\(id)"
        case .invalidGraph: return "当前图不满足 CanvasCore 图约束"
        case .cycleDetected: return "patch 会产生环，已拒绝"
        }
    }
}

/// 以 revision/fingerprint 为 compare-and-swap 前提的原子画布变更。
public struct CanvasPatch: Codable, Equatable, Sendable, Identifiable {
    public static let currentSchemaVersion = CanvasSchema.currentVersion
    public let schemaVersion: Int
    public let id: UUID
    public let canvasID: UUID?
    public let baseRevision: Int
    public let baseFingerprint: String
    public let operations: [CanvasPatchOperation]

    public init(
        id: UUID = UUID(),
        canvasID: UUID? = nil,
        baseRevision: Int,
        baseFingerprint: String,
        operations: [CanvasPatchOperation],
        schemaVersion: Int = CanvasPatch.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.canvasID = canvasID
        self.baseRevision = baseRevision
        self.baseFingerprint = baseFingerprint
        self.operations = operations
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, canvasID, baseRevision, baseFingerprint, operations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try CanvasSchema.decodeVersion(from: container, key: .schemaVersion)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.canvasID = try container.decodeIfPresent(UUID.self, forKey: .canvasID)
        self.baseRevision = try container.decode(Int.self, forKey: .baseRevision)
        try CanvasSchema.requireNonNegative(baseRevision, "baseRevision")
        self.baseFingerprint = try container.decode(String.self, forKey: .baseFingerprint)
        try CanvasSchema.requireNonEmpty(baseFingerprint, "baseFingerprint")
        self.operations = try container.decode([CanvasPatchOperation].self, forKey: .operations)
    }

    public func validate() throws {
        try CanvasSchema.requireNonNegative(baseRevision, "baseRevision")
        try CanvasSchema.requireNonEmpty(baseFingerprint, "baseFingerprint")
    }

    public var isValid: Bool { (try? validate()) != nil }

    /// 无 canvasID 时只校验图本身；有 canvasID 时必须传入当前画布身份。
    public func applying(to graph: NodeGraph, canvasID actualCanvasID: UUID? = nil) throws -> NodeGraph {
        try validate()
        if let canvasID, canvasID != actualCanvasID {
            throw CanvasPatchError.canvasMismatch(expected: canvasID, actual: actualCanvasID)
        }
        guard graph.revision == baseRevision else {
            throw CanvasPatchError.revisionMismatch(expected: baseRevision, actual: graph.revision)
        }
        let actualFingerprint = graph.fingerprint
        guard actualFingerprint == baseFingerprint else {
            throw CanvasPatchError.fingerprintMismatch(expected: baseFingerprint, actual: actualFingerprint)
        }
        guard graph.isValid else { throw CanvasPatchError.invalidGraph }

        var updated = graph
        for operation in operations {
            try apply(operation, to: &updated)
        }
        do {
            try updated.validate()
            _ = try DAGScheduler.topologicalSort(in: updated)
        } catch let error as DAGSchedulerError {
            if case .cycleDetected = error { throw CanvasPatchError.cycleDetected }
            throw CanvasPatchError.invalidGraph
        } catch {
            throw CanvasPatchError.invalidGraph
        }
        updated.revision = baseRevision + 1
        return updated
    }

    public func applying(to graph: NodeGraph, canvasID actualCanvasID: UUID) throws -> NodeGraph {
        try applying(to: graph, canvasID: Optional(actualCanvasID))
    }

    private func apply(_ operation: CanvasPatchOperation, to graph: inout NodeGraph) throws {
        switch operation {
        case let .addNode(node):
            guard graph.node(id: node.id) == nil else { throw CanvasPatchError.duplicateNode(node.id) }
            graph.nodes.append(node)
        case let .updateNode(node):
            guard let index = graph.nodes.firstIndex(where: { $0.id == node.id }) else {
                throw CanvasPatchError.nodeNotFound(node.id)
            }
            graph.nodes[index] = node
        case let .removeNode(id):
            guard graph.node(id: id) != nil else { throw CanvasPatchError.nodeNotFound(id) }
            graph.nodes.removeAll { $0.id == id }
            graph.edges.removeAll { $0.fromNode == id || $0.toNode == id }
        case let .addEdge(edge):
            guard graph.edge(id: edge.id) == nil else { throw CanvasPatchError.duplicateEdge(edge.id) }
            guard valid(edge: edge, in: graph) else { throw CanvasPatchError.invalidEdge(edge.id) }
            graph.edges.append(edge)
        case let .removeEdge(id):
            guard graph.edge(id: id) != nil else { throw CanvasPatchError.edgeNotFound(id) }
            graph.edges.removeAll { $0.id == id }
        }
    }

    private func valid(edge: Edge, in graph: NodeGraph) -> Bool {
        guard let from = graph.node(id: edge.fromNode), let to = graph.node(id: edge.toNode),
              let fromPort = from.outputs.first(where: { $0.id == edge.fromPort }),
              let toPort = to.inputs.first(where: { $0.id == edge.toPort }) else { return false }
        return fromPort.direction == .output && toPort.direction == .input
    }
}
