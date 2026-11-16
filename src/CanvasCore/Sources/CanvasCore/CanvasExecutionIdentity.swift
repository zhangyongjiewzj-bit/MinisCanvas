import Foundation

private let zeroUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

/// 一次画布节点执行的不可变身份。所有异步结果写回前必须匹配它。
public struct CanvasExecutionIdentity: Codable, Equatable, Sendable, Hashable {
    public static let currentSchemaVersion = CanvasSchema.currentVersion
    public let schemaVersion: Int
    public let canvasID: UUID
    public let runID: UUID
    public let graphRevision: Int
    public let nodeID: UUID
    public let nodeRevision: Int

    public init(
        canvasID: UUID,
        runID: UUID,
        graphRevision: Int,
        nodeID: UUID,
        nodeRevision: Int,
        schemaVersion: Int = CanvasExecutionIdentity.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.canvasID = canvasID
        self.runID = runID
        self.graphRevision = graphRevision
        self.nodeID = nodeID
        self.nodeRevision = nodeRevision
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, canvasID, runID, graphRevision, nodeID, nodeRevision
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try CanvasSchema.decodeVersion(from: container, key: .schemaVersion)
        self.canvasID = try container.decode(UUID.self, forKey: .canvasID)
        self.runID = try container.decode(UUID.self, forKey: .runID)
        self.graphRevision = try container.decode(Int.self, forKey: .graphRevision)
        self.nodeID = try container.decode(UUID.self, forKey: .nodeID)
        self.nodeRevision = try container.decode(Int.self, forKey: .nodeRevision)
        try validate()
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw CanvasSchemaError.unsupportedVersion(
                expected: Self.currentSchemaVersion,
                actual: schemaVersion
            )
        }
        guard canvasID != zeroUUID, runID != zeroUUID, nodeID != zeroUUID else {
            throw CanvasSchemaError.invalidField("executionIdentity.id")
        }
        try CanvasSchema.requireNonNegative(graphRevision, "graphRevision")
        try CanvasSchema.requireNonNegative(nodeRevision, "nodeRevision")
    }

    public var isValid: Bool { (try? validate()) != nil }
}

/// 提交任务时冻结的 Provider 配置，后续切换全局 Provider 不影响在途任务。
public enum CanvasProviderCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case streaming
    case tools
    case vision
    case audio
    case image
    case video
}

/// 异步写回的最小校验结果。取消、画布或 revision 不匹配时统一拒绝。
public enum CanvasWritebackDecision: Equatable, Sendable {
    case accepted
    case rejected(WritebackRejection)
}

public enum WritebackRejection: String, Codable, Equatable, Sendable {
    case cancelled
    case canvasMismatch
    case runMismatch
    case graphRevisionMismatch
    case nodeMismatch
    case nodeRevisionMismatch
}

public func validateCanvasWriteback(
    expected: CanvasExecutionIdentity,
    actual: CanvasExecutionIdentity,
    isCancelled: Bool
) -> CanvasWritebackDecision {
    guard !isCancelled else { return .rejected(.cancelled) }
    guard expected.isValid, actual.isValid else { return .rejected(.graphRevisionMismatch) }
    guard expected.canvasID == actual.canvasID else { return .rejected(.canvasMismatch) }
    guard expected.runID == actual.runID else { return .rejected(.runMismatch) }
    guard expected.graphRevision == actual.graphRevision else { return .rejected(.graphRevisionMismatch) }
    guard expected.nodeID == actual.nodeID else { return .rejected(.nodeMismatch) }
    guard expected.nodeRevision == actual.nodeRevision else { return .rejected(.nodeRevisionMismatch) }
    return .accepted
}

/// 普通 DAG 一次运行的不可变信封。
///
/// `CanvasExecutionIdentity` 绑定单个节点；DAG 信封绑定整次运行，因而在
/// 节点完成、资产登记和结果写回之间始终携带 origin canvas。图结构相同
/// 不代表执行目标相同：A/B 画布可以有相同的 revision 和 fingerprint，但
/// `canvasID` 仍必须匹配。
public struct DAGExecutionEnvelope: Codable, Equatable, Sendable, Hashable {
    public static let currentSchemaVersion = CanvasSchema.currentVersion

    public let schemaVersion: Int
    public let canvasID: UUID
    public let runID: UUID
    public let graphRevision: Int
    public let graphFingerprint: String
    public let cancellationGeneration: Int
    public let providerSnapshotFingerprint: String?
    public let idempotencyKey: String?

    public init(
        canvasID: UUID,
        runID: UUID,
        graphRevision: Int,
        graphFingerprint: String,
        cancellationGeneration: Int = 0,
        providerSnapshotFingerprint: String? = nil,
        idempotencyKey: String? = nil,
        schemaVersion: Int = DAGExecutionEnvelope.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.canvasID = canvasID
        self.runID = runID
        self.graphRevision = graphRevision
        self.graphFingerprint = graphFingerprint
        self.cancellationGeneration = cancellationGeneration
        self.providerSnapshotFingerprint = providerSnapshotFingerprint
        self.idempotencyKey = idempotencyKey
    }

    public init(
        canvasID: UUID,
        runID: UUID,
        graph: NodeGraph,
        cancellationGeneration: Int = 0,
        providerSnapshotFingerprint: String? = nil,
        idempotencyKey: String? = nil,
        schemaVersion: Int = DAGExecutionEnvelope.currentSchemaVersion
    ) {
        self.init(
            canvasID: canvasID,
            runID: runID,
            graphRevision: graph.revision,
            graphFingerprint: graph.fingerprint,
            cancellationGeneration: cancellationGeneration,
            providerSnapshotFingerprint: providerSnapshotFingerprint,
            idempotencyKey: idempotencyKey,
            schemaVersion: schemaVersion
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, canvasID, runID, graphRevision, graphFingerprint
        case cancellationGeneration, providerSnapshotFingerprint, idempotencyKey
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try CanvasSchema.decodeVersion(from: container, key: .schemaVersion)
        self.canvasID = try container.decode(UUID.self, forKey: .canvasID)
        self.runID = try container.decode(UUID.self, forKey: .runID)
        self.graphRevision = try container.decode(Int.self, forKey: .graphRevision)
        self.graphFingerprint = try container.decode(String.self, forKey: .graphFingerprint)
        self.cancellationGeneration = try container.decodeIfPresent(Int.self, forKey: .cancellationGeneration) ?? 0
        self.providerSnapshotFingerprint = try container.decodeIfPresent(
            String.self,
            forKey: .providerSnapshotFingerprint
        )
        self.idempotencyKey = try container.decodeIfPresent(String.self, forKey: .idempotencyKey)
        try validate()
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw CanvasSchemaError.unsupportedVersion(
                expected: Self.currentSchemaVersion,
                actual: schemaVersion
            )
        }
        guard canvasID != zeroUUID else {
            throw CanvasSchemaError.invalidField("dagExecutionEnvelope.canvasID")
        }
        guard runID != zeroUUID else {
            throw CanvasSchemaError.invalidField("dagExecutionEnvelope.runID")
        }
        try CanvasSchema.requireNonNegative(graphRevision, "dagExecutionEnvelope.graphRevision")
        try CanvasSchema.requireNonEmpty(graphFingerprint, "dagExecutionEnvelope.graphFingerprint")
        try CanvasSchema.requireNonNegative(
            cancellationGeneration,
            "dagExecutionEnvelope.cancellationGeneration"
        )
        if let providerSnapshotFingerprint {
            try CanvasSchema.requireNonEmpty(
                providerSnapshotFingerprint,
                "dagExecutionEnvelope.providerSnapshotFingerprint"
            )
        }
        if let idempotencyKey {
            try CanvasSchema.requireNonEmpty(idempotencyKey, "dagExecutionEnvelope.idempotencyKey")
        }
    }

    public var isValid: Bool { (try? validate()) != nil }

    /// 将运行级 origin 绑定到节点级 identity，供节点异步结果继续沿用同一画布。
    public func identity(for nodeID: UUID, nodeRevision: Int) -> CanvasExecutionIdentity {
        CanvasExecutionIdentity(
            canvasID: canvasID,
            runID: runID,
            graphRevision: graphRevision,
            nodeID: nodeID,
            nodeRevision: nodeRevision,
            schemaVersion: schemaVersion
        )
    }
}

/// 兼容调用方对“Canvas execution envelope”的命名。
public typealias CanvasExecutionEnvelope = DAGExecutionEnvelope
public typealias CanvasDAGExecutionEnvelope = DAGExecutionEnvelope

public enum DAGWritebackDecision: Equatable, Sendable {
    case accepted
    case rejected(DAGWritebackRejection)
}

public enum DAGWritebackRejection: String, Codable, Equatable, Sendable {
    case invalidEnvelope
    case cancelled
    case canvasMismatch
    case runMismatch
    case graphRevisionMismatch
    case graphFingerprintMismatch
    case cancellationGenerationMismatch
    case providerSnapshotMismatch
    case idempotencyMismatch
}

/// 完成事件/结果写回前的纯函数校验。任何不匹配都在触碰资产或图状态前拒绝。
public func validateDAGWriteback(
    expected: DAGExecutionEnvelope,
    actual: DAGExecutionEnvelope,
    isCancelled: Bool
) -> DAGWritebackDecision {
    guard !isCancelled else { return .rejected(.cancelled) }
    guard expected.isValid, actual.isValid else { return .rejected(.invalidEnvelope) }
    guard expected.canvasID == actual.canvasID else { return .rejected(.canvasMismatch) }
    guard expected.runID == actual.runID else { return .rejected(.runMismatch) }
    guard expected.graphRevision == actual.graphRevision else {
        return .rejected(.graphRevisionMismatch)
    }
    guard expected.graphFingerprint == actual.graphFingerprint else {
        return .rejected(.graphFingerprintMismatch)
    }
    guard expected.cancellationGeneration == actual.cancellationGeneration else {
        return .rejected(.cancellationGenerationMismatch)
    }
    guard expected.providerSnapshotFingerprint == actual.providerSnapshotFingerprint else {
        return .rejected(.providerSnapshotMismatch)
    }
    guard expected.idempotencyKey == actual.idempotencyKey else {
        return .rejected(.idempotencyMismatch)
    }
    return .accepted
}

public enum DAGAssetRegistrationDecision: Equatable, Sendable {
    case accepted
    case rejected(DAGAssetRegistrationRejection)
}

public enum DAGAssetRegistrationRejection: String, Codable, Equatable, Sendable {
    case invalidEnvelope
    case canvasMismatch
}

/// 资产登记必须使用执行 envelope 的 origin canvas，而不是当前 UI canvas。
public func validateDAGAssetRegistration(
    envelope: DAGExecutionEnvelope,
    targetCanvasID: UUID
) -> DAGAssetRegistrationDecision {
    guard envelope.isValid else { return .rejected(.invalidEnvelope) }
    guard targetCanvasID == envelope.canvasID else { return .rejected(.canvasMismatch) }
    return .accepted
}
