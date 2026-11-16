import Foundation
import CanvasCore
import MinisCore

// CanvasDraft is a value-only Codable DTO; the coordinator carries an
// immutable snapshot across its authorization task.
extension CanvasDraft: @unchecked Sendable {}

/// The small set of Canvas mutations that can originate at a UI command boundary.
enum CanvasMutationOperation: Equatable, Sendable {
    case addNode(type: String, position: Point?)
    case addNodeWithContent(type: String, content: String, position: Point?)
    case renameNode(id: UUID, title: String)
    case updateNodeContent(content: String, id: UUID)
    case updateBackendConfig(config: NodeBackendConfig, id: UUID)
    case addImageAsset(path: String, name: String?, position: Point?)
    case addVideoAsset(path: String, name: String?, position: Point?)
    case expandStoryboard(id: UUID)
    case connect(fromID: UUID, toID: UUID)
    case runGraph(nodeIDs: [UUID]?)
    case autoLayout
    case resetStatuses
    case deleteCanvas(id: UUID)
    case removeNode(id: UUID)
    case removeNodes(ids: [UUID])
    case createPipeline
    case applyTemplate(template: CanvasTemplate)
    case restoreCanvas(draft: CanvasDraft)
}

/// Frozen Canvas identity captured before Composer authorization starts.
struct CanvasMutationRequest: Equatable, Sendable, Identifiable {
    let id: UUID
    let canvasID: UUID
    let baseRevision: Int
    let baseFingerprint: String
    let originSessionID: String?
    let operation: CanvasMutationOperation

    init(
        id: UUID = UUID(),
        canvasID: UUID,
        baseRevision: Int,
        baseFingerprint: String,
        originSessionID: String? = nil,
        operation: CanvasMutationOperation
    ) {
        self.id = id
        self.canvasID = canvasID
        self.baseRevision = baseRevision
        self.baseFingerprint = baseFingerprint
        self.originSessionID = originSessionID
        self.operation = operation
    }
}

/// Immutable local receipt for a mutation that passed Composer and identity checks.
struct CanvasMutationReceipt: Equatable, Sendable, Identifiable {
    let id: UUID
    let requestID: UUID
    let canvasID: UUID
    let baseRevision: Int
    let resultRevision: Int
    let operation: CanvasMutationOperation
    let approvalReceipt: ComposerApprovalReceipt?
    let appliedAt: Date
}

enum CanvasMutationError: Error, Equatable, Sendable, LocalizedError {
    case staleCanvas(expected: UUID, actual: UUID?)
    case staleRevision(expected: Int, actual: Int)
    case staleFingerprint(expected: String, actual: String)
    case duplicateRequest(UUID)
    case canvasModelUnavailable
    case targetRejected
    case dryRun

    var errorDescription: String? {
        switch self {
        case let .staleCanvas(expected, actual):
            return "画布身份已变化：期望 \(expected)，实际 \(String(describing: actual))"
        case let .staleRevision(expected, actual):
            return "画布 revision 已变化：期望 \(expected)，实际 \(actual)"
        case let .staleFingerprint(expected, actual):
            return "画布内容已变化：期望 \(expected)，实际 \(actual)"
        case let .duplicateRequest(requestID):
            return "画布操作已处理，拒绝重复写回：\(requestID)"
        case .canvasModelUnavailable:
            return "画布模型不可用：请先为受影响节点配置 provider/model"
        case .targetRejected:
            return "画布目标拒绝操作"
        case .dryRun:
            return "计划模式只生成预览，不执行画布变更"
        }
    }
}

/// The only mutation surface used by the coordinator. Tests can replace the
/// production CanvasStore with a counting target without touching the UI.
@MainActor
protocol CanvasMutationTarget: AnyObject {
    var currentCanvasID: UUID { get }
    var graph: NodeGraph { get }

    @discardableResult
    func addNode(ofType type: String, at position: Point?) -> CanvasNode?
    @discardableResult
    func updateNodeContent(_ content: String, for nodeID: UUID) -> Bool
    @discardableResult
    func renameNode(id: UUID, title newTitle: String) -> Bool
    func updateBackendConfig(_ config: NodeBackendConfig, for nodeID: UUID)
    @discardableResult
    func addImageAssetNode(from path: String, name: String?, near position: Point?) -> CanvasNode?
    @discardableResult
    func addVideoAssetNode(from path: String, name: String?, near position: Point?) -> CanvasNode?
    @discardableResult
    func expandStoryboard(nodeID: UUID) -> Int
    @discardableResult
    func connectNodes(fromID: UUID, toID: UUID) -> Bool
    @discardableResult
    func createManjuPipeline() -> NodeGraph
    @discardableResult
    func applyTemplate(_ template: CanvasTemplate) -> NodeGraph
    func runGraph(from nodeIDs: Set<UUID>?)
    func autoLayout()
    func resetStatuses()
    @discardableResult
    func deleteCanvas(id: UUID) -> Bool
    func removeNode(id: UUID)
    @discardableResult
    func restoreCanvas(from draft: CanvasDraft) -> Bool
}

@MainActor
extension CanvasMutationTarget {
    @discardableResult
    func updateNodeContent(_: String, for _: UUID) -> Bool {
        false
    }

    @discardableResult
    func renameNode(id _: UUID, title _: String) -> Bool {
        false
    }

    func updateBackendConfig(_: NodeBackendConfig, for _: UUID) {}

    @discardableResult
    func addImageAssetNode(from _: String, name _: String?, near _: Point?) -> CanvasNode? {
        nil
    }

    @discardableResult
    func addVideoAssetNode(from _: String, name _: String?, near _: Point?) -> CanvasNode? {
        nil
    }

    @discardableResult
    func expandStoryboard(nodeID _: UUID) -> Int {
        0
    }

    @discardableResult
    func connectNodes(fromID _: UUID, toID _: UUID) -> Bool {
        false
    }

    @discardableResult
    func createManjuPipeline() -> NodeGraph {
        NodeGraph()
    }

    @discardableResult
    func applyTemplate(_: CanvasTemplate) -> NodeGraph {
        NodeGraph()
    }

    @discardableResult
    func restoreCanvas(from _: CanvasDraft) -> Bool {
        false
    }
}

@MainActor
extension CanvasStore: CanvasMutationTarget {}

@MainActor
final class CanvasMutationCoordinator {
    typealias SnapshotFactory =
        @MainActor (CanvasMutationRequest, ComposerToolInput) -> ComposerSubmissionSnapshot
    typealias OriginSessionIDProvider = @MainActor () -> String?

    private let target: any CanvasMutationTarget
    private var facts: ComposerPolicyFactSource
    private var grants: ComposerApprovalGrantStore
    private var approvalGate: ApprovalGate?
    private var snapshotFactory: SnapshotFactory
    private var originSessionIDProvider: OriginSessionIDProvider
    private var activeRequestIDs: Set<UUID> = []
    private var completedRequestIDs: Set<UUID> = []

    private(set) var receipts: [CanvasMutationReceipt] = []

    init(
        target: any CanvasMutationTarget,
        facts: ComposerPolicyFactSource = .unconfigured,
        grants: ComposerApprovalGrantStore = ComposerApprovalGrantStore(),
        approvalGate: ApprovalGate? = nil,
        snapshotFactory: @escaping SnapshotFactory = CanvasMutationCoordinator.defaultSnapshot,
        originSessionIDProvider: @escaping OriginSessionIDProvider = { nil }
    ) {
        self.target = target
        self.facts = facts
        self.grants = grants
        self.approvalGate = approvalGate
        self.snapshotFactory = snapshotFactory
        self.originSessionIDProvider = originSessionIDProvider
    }

    func configure(
        facts: ComposerPolicyFactSource,
        grants: ComposerApprovalGrantStore,
        approvalGate: ApprovalGate?,
        snapshotFactory: @escaping SnapshotFactory,
        originSessionIDProvider: OriginSessionIDProvider? = nil
    ) {
        self.facts = facts
        self.grants = grants
        self.approvalGate = approvalGate
        self.snapshotFactory = snapshotFactory
        if let originSessionIDProvider {
            self.originSessionIDProvider = originSessionIDProvider
        }
    }

    /// Refresh the live policy identity and gate without replacing the
    /// coordinator's target.
    func updateComposerPolicy(
        facts: ComposerPolicyFactSource,
        grants: ComposerApprovalGrantStore,
        approvalGate: ApprovalGate?
    ) {
        self.facts = facts
        self.grants = grants
        self.approvalGate = approvalGate
    }

    func bindOriginSessionIDProvider(
        _ provider: @escaping OriginSessionIDProvider
    ) {
        originSessionIDProvider = provider
    }

    func makeRequest(
        _ operation: CanvasMutationOperation,
        originSessionID: String? = nil
    ) -> CanvasMutationRequest {
        CanvasMutationRequest(
            canvasID: target.currentCanvasID,
            baseRevision: target.graph.revision,
            baseFingerprint: target.graph.fingerprint,
            originSessionID: originSessionID ?? originSessionIDProvider(),
            operation: operation
        )
    }

    func execute(
        _ operation: CanvasMutationOperation,
        originSessionID: String? = nil
    ) async throws -> CanvasMutationReceipt {
        try await execute(makeRequest(operation, originSessionID: originSessionID))
    }

    func dispatch(_ operation: CanvasMutationOperation) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await execute(operation)
            } catch {
                (target as? CanvasStore)?.statusMessage = "画布操作已拒绝：\(error.localizedDescription)"
            }
        }
    }

    func execute(_ request: CanvasMutationRequest) async throws -> CanvasMutationReceipt {
        guard !activeRequestIDs.contains(request.id),
              !completedRequestIDs.contains(request.id) else {
            throw CanvasMutationError.duplicateRequest(request.id)
        }
        activeRequestIDs.insert(request.id)
        defer { activeRequestIDs.remove(request.id) }

        let input = ComposerToolInput(values: [
            "requestID": .string(request.id.uuidString),
            "canvasID": .string(request.canvasID.uuidString),
            "baseRevision": .integer(Int64(request.baseRevision)),
            "baseFingerprint": .string(request.baseFingerprint),
            "operation": .string(operationName(request.operation))
        ])
        let snapshot = snapshotFactory(request, input)
        let boundary = ChatCanvasBoundaryContract(
            capability: "canvas_mutation",
            workspaceID: snapshot.workspaceID,
            originSessionID: request.originSessionID ?? "",
            activeSessionID: snapshot.sessionID,
            canvasProviderID: nil,
            canvasModelID: nil,
            approvalReceiptDigest: nil
        )
        // Approval receipts are produced by the shared Composer executor. The
        // executor remains the source of truth for whether this mode needs a
        // receipt; this preflight only enforces immutable scope identity.
        try boundary.validate(requiresApprovalReceipt: false)
        let controller = ComposerAuthorizationController(
            snapshot: snapshot,
            facts: facts,
            grants: grants
        )
        let approvalReceipt = ReceiptBox()
        let executor = ComposerPolicyEnforcedToolExecutor(
            base: CanvasMutationTargetExecutor(target: target, request: request),
            controller: controller,
            approvalGate: approvalGate,
            onApprovalReceipt: { receipt in
                approvalReceipt.store(receipt)
            }
        )

        let output = try await executor.execute(
            callID: request.id.uuidString,
            name: "canvas_mutation",
            input: input
        )
        guard !output.contains("\"status\":\"dry-run\"") else {
            throw CanvasMutationError.dryRun
        }

        let receipt = CanvasMutationReceipt(
            id: request.id,
            requestID: request.id,
            canvasID: request.canvasID,
            baseRevision: request.baseRevision,
            resultRevision: target.graph.revision,
            operation: request.operation,
            approvalReceipt: approvalReceipt.value,
            appliedAt: Date()
        )
        completedRequestIDs.insert(request.id)
        receipts.append(receipt)
        return receipt
    }

    private static func defaultSnapshot(
        request: CanvasMutationRequest,
        input: ComposerToolInput
    ) -> ComposerSubmissionSnapshot {
        ComposerSubmissionSnapshot(
            mode: .manual,
            approvalScope: .request,
            effort: .standard,
            sessionID: "canvas-session",
            turnID: 0,
            taskID: "canvas:\(request.id.uuidString)",
            attemptID: request.id.uuidString,
            messageID: request.id.uuidString,
            inputDigest: input.digest,
            workspaceID: "unconfigured",
            createdAt: Date(),
            policyRevision: "",
            grantEpoch: ""
        )
    }
}

private final class CanvasMutationTargetExecutor: ToolExecutor, @unchecked Sendable {
    private let target: any CanvasMutationTarget
    private let request: CanvasMutationRequest

    init(target: any CanvasMutationTarget, request: CanvasMutationRequest) {
        self.target = target
        self.request = request
    }

    func execute(name: String, input: [String: Any]) async throws -> String {
        guard name == "canvas_mutation",
              input["requestID"] as? String == request.id.uuidString else {
            throw ComposerAuthorizationError.invalidInput
        }
        return try await MainActor.run {
            guard target.currentCanvasID == request.canvasID else {
                throw CanvasMutationError.staleCanvas(
                    expected: request.canvasID,
                    actual: target.currentCanvasID
                )
            }
            guard target.graph.revision == request.baseRevision else {
                throw CanvasMutationError.staleRevision(
                    expected: request.baseRevision,
                    actual: target.graph.revision
                )
            }
            let actualFingerprint = target.graph.fingerprint
            guard actualFingerprint == request.baseFingerprint else {
                throw CanvasMutationError.staleFingerprint(
                    expected: request.baseFingerprint,
                    actual: actualFingerprint
                )
            }
            try Self.validateModelDependencies(
                for: request.operation,
                graph: target.graph
            )
            // Approval may resume after the caller has cancelled or timed out.
            // Check immediately before the synchronous target write so a late
            // authorization result cannot commit a Canvas mutation.
            try Task.checkCancellation()

            switch request.operation {
            case let .addNode(type, position):
                target.addNode(ofType: type, at: position)
            case let .addNodeWithContent(type, content, position):
                guard let node = target.addNode(ofType: type, at: position),
                      target.updateNodeContent(content, for: node.id) else {
                    throw CanvasMutationError.targetRejected
                }
            case let .renameNode(id, title):
                guard target.renameNode(id: id, title: title) else {
                    throw CanvasMutationError.targetRejected
                }
            case let .updateNodeContent(content, id):
                guard target.updateNodeContent(content, for: id) else {
                    throw CanvasMutationError.targetRejected
                }
            case let .updateBackendConfig(config, id):
                guard target.graph.node(id: id) != nil else {
                    throw CanvasMutationError.targetRejected
                }
                target.updateBackendConfig(config, for: id)
            case let .addImageAsset(path, name, position):
                guard target.addImageAssetNode(from: path, name: name, near: position) != nil else {
                    throw CanvasMutationError.targetRejected
                }
            case let .addVideoAsset(path, name, position):
                guard target.addVideoAssetNode(from: path, name: name, near: position) != nil else {
                    throw CanvasMutationError.targetRejected
                }
            case let .expandStoryboard(id):
                _ = target.expandStoryboard(nodeID: id)
            case let .connect(fromID, toID):
                guard target.connectNodes(fromID: fromID, toID: toID) else {
                    throw CanvasMutationError.targetRejected
                }
            case let .runGraph(nodeIDs):
                target.runGraph(from: nodeIDs.map(Set.init))
            case .autoLayout:
                target.autoLayout()
            case .resetStatuses:
                target.resetStatuses()
            case let .deleteCanvas(id):
                _ = target.deleteCanvas(id: id)
            case let .removeNode(id):
                target.removeNode(id: id)
            case let .removeNodes(ids):
                for id in ids {
                    target.removeNode(id: id)
                }
            case .createPipeline:
                _ = target.createManjuPipeline()
            case let .applyTemplate(template):
                _ = target.applyTemplate(template)
            case let .restoreCanvas(draft):
                guard target.restoreCanvas(from: draft) else {
                    throw CanvasMutationError.targetRejected
                }
            }
            return #"{"status":"applied","capability":"canvas_mutation"}"#
        }
    }

    private static let modelDependentNodeTypes: Set<String> = [
        "llm",
        "image",
        "video",
        ManjuNodeType.novelImport.rawValue,
        ManjuNodeType.plotOutline.rawValue,
        ManjuNodeType.script.rawValue,
        ManjuNodeType.storyboard.rawValue,
        ManjuNodeType.imagePrompt.rawValue,
        ManjuNodeType.videoPrompt.rawValue,
        ManjuNodeType.imageGen.rawValue,
        ManjuNodeType.videoGen.rawValue,
    ]

    private static func validateModelDependencies(
        for operation: CanvasMutationOperation,
        graph: NodeGraph
    ) throws {
        guard case let .runGraph(nodeIDs) = operation else { return }

        let roots = nodeIDs.map(Set.init)
        let affectedNodeIDs = executionNodeIDs(from: roots, graph: graph)
        guard graph.nodes.contains(where: {
            affectedNodeIDs.contains($0.id)
                && modelDependentNodeTypes.contains($0.type)
        }) else {
            return
        }

        let hasUnavailableModel = graph.nodes.contains { node in
            guard affectedNodeIDs.contains(node.id),
                  modelDependentNodeTypes.contains(node.type) else {
                return false
            }
            guard let config = node.backendConfig else {
                return true
            }
            let providerID = config.providerID.trimmingCharacters(in: .whitespacesAndNewlines)
            let modelID = config.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            return providerID.isEmpty || modelID.isEmpty
        }
        if hasUnavailableModel {
            throw CanvasMutationError.canvasModelUnavailable
        }
    }

    private static func executionNodeIDs(
        from roots: Set<UUID>?,
        graph: NodeGraph
    ) -> Set<UUID> {
        guard let roots else {
            return Set(graph.nodes.map(\.id))
        }

        var closure = roots
        var stack = Array(roots)
        while let current = stack.popLast() {
            for successor in graph.successors(of: current)
            where closure.insert(successor.id).inserted {
                stack.append(successor.id)
            }
        }
        return closure
    }
}

private final class ReceiptBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ComposerApprovalReceipt?

    var value: ComposerApprovalReceipt? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func store(_ receipt: ComposerApprovalReceipt) {
        lock.lock()
        stored = receipt
        lock.unlock()
    }
}

private func operationName(_ operation: CanvasMutationOperation) -> String {
    switch operation {
    case .addNode: return "addNode"
    case .addNodeWithContent: return "addNodeWithContent"
    case .renameNode: return "renameNode"
    case .updateNodeContent: return "updateNodeContent"
    case .updateBackendConfig: return "updateBackendConfig"
    case .addImageAsset: return "addImageAsset"
    case .addVideoAsset: return "addVideoAsset"
    case .expandStoryboard: return "expandStoryboard"
    case .connect: return "connect"
    case .runGraph: return "runGraph"
    case .autoLayout: return "autoLayout"
    case .resetStatuses: return "resetStatuses"
    case .deleteCanvas: return "deleteCanvas"
    case .removeNode: return "removeNode"
    case .removeNodes: return "removeNodes"
    case .createPipeline: return "createPipeline"
    case .applyTemplate: return "applyTemplate"
    case .restoreCanvas: return "restoreCanvas"
    }
}
