import Foundation

/// Shared fail-closed contract for the Chat -> Canvas boundary.
///
/// Chat model selection is intentionally absent from this contract. Canvas
/// execution may only use an explicitly bound Canvas provider/model; it never
/// derives one from the active Chat selection.
public struct ChatCanvasBoundaryContract: Equatable, Sendable {
    public static let canvasMutationCapability = "canvas_mutation"

    public let capability: String
    public let workspaceID: String
    public let originSessionID: String
    public let activeSessionID: String
    public let canvasProviderID: String?
    public let canvasModelID: String?
    public let approvalReceiptDigest: String?

    public init(
        capability: String,
        workspaceID: String,
        originSessionID: String,
        activeSessionID: String,
        canvasProviderID: String?,
        canvasModelID: String?,
        approvalReceiptDigest: String?
    ) {
        self.capability = capability
        self.workspaceID = workspaceID
        self.originSessionID = originSessionID
        self.activeSessionID = activeSessionID
        self.canvasProviderID = canvasProviderID
        self.canvasModelID = canvasModelID
        self.approvalReceiptDigest = approvalReceiptDigest
    }

    public func validate(
        requiresCanvasModel: Bool = false,
        requiresApprovalReceipt: Bool = true
    ) throws {
        guard capability == Self.canvasMutationCapability else {
            throw ChatCanvasBoundaryError.unknownCapability(capability)
        }
        guard !workspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChatCanvasBoundaryError.workspaceMissing
        }
        guard !originSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChatCanvasBoundaryError.originSessionMissing
        }
        guard originSessionID == activeSessionID else {
            throw ChatCanvasBoundaryError.sessionMismatch(
                origin: originSessionID,
                active: activeSessionID
            )
        }
        if requiresCanvasModel {
            guard let provider = canvasProviderID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !provider.isEmpty,
                  let model = canvasModelID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !model.isEmpty else {
                throw ChatCanvasBoundaryError.canvasModelUnavailable
            }
        }
        if requiresApprovalReceipt {
            guard let digest = approvalReceiptDigest?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !digest.isEmpty else {
                throw ChatCanvasBoundaryError.approvalReceiptMissing
            }
        }
    }
}

public enum ChatCanvasBoundaryError: Error, Equatable, Sendable, LocalizedError {
    case unknownCapability(String)
    case workspaceMissing
    case originSessionMissing
    case sessionMismatch(origin: String, active: String)
    case canvasModelUnavailable
    case approvalReceiptMissing

    public var errorDescription: String? {
        switch self {
        case .unknownCapability(let capability):
            return "Chat/Canvas 未知能力已拒绝：\(capability)"
        case .workspaceMissing:
            return "Chat/Canvas 缺少 workspace scope"
        case .originSessionMissing:
            return "Chat/Canvas 缺少发起会话身份，禁止执行 Canvas 变更"
        case .sessionMismatch(let origin, let active):
            return "Chat/Canvas 会话已变化：发起 \(origin)，当前 \(active)"
        case .canvasModelUnavailable:
            return "Canvas 未单独绑定 provider/model，禁止继承 Chat 模型"
        case .approvalReceiptMissing:
            return "Canvas 变更缺少审批回执"
        }
    }
}
