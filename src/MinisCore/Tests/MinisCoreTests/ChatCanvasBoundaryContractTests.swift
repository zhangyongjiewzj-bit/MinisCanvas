import Foundation
import Testing
@testable import MinisCore

@Suite("Chat/Canvas boundary contract")
struct ChatCanvasBoundaryContractTests {
    @Test("unknown or unbound Canvas capability is rejected")
    func unknownOrUnboundCapabilityIsRejected() throws {
        let contract = ChatCanvasBoundaryContract(
            capability: "canvas_command",
            workspaceID: "workspace",
            originSessionID: "session-a",
            activeSessionID: "session-a",
            canvasProviderID: nil,
            canvasModelID: nil,
            approvalReceiptDigest: nil
        )

        #expect(throws: ChatCanvasBoundaryError.unknownCapability("canvas_command")) {
            try contract.validate()
        }
    }

    @Test("missing Canvas provider/model is rejected without Chat fallback")
    func missingCanvasModelDoesNotUseChatSelection() throws {
        let contract = ChatCanvasBoundaryContract(
            capability: ChatCanvasBoundaryContract.canvasMutationCapability,
            workspaceID: "workspace",
            originSessionID: "session-a",
            activeSessionID: "session-a",
            canvasProviderID: nil,
            canvasModelID: nil,
            approvalReceiptDigest: "approval"
        )

        #expect(throws: ChatCanvasBoundaryError.canvasModelUnavailable) {
            try contract.validate(requiresCanvasModel: true)
        }
    }

    @Test("cross-session requests are rejected before authorization can be consumed")
    func crossSessionRequestIsRejected() throws {
        let contract = ChatCanvasBoundaryContract(
            capability: ChatCanvasBoundaryContract.canvasMutationCapability,
            workspaceID: "workspace",
            originSessionID: "session-a",
            activeSessionID: "session-b",
            canvasProviderID: "canvas-provider",
            canvasModelID: "canvas-model",
            approvalReceiptDigest: "approval"
        )

        #expect(throws: ChatCanvasBoundaryError.sessionMismatch(
            origin: "session-a",
            active: "session-b"
        )) {
            try contract.validate()
        }
    }

    @Test("missing origin session is rejected before Canvas execution")
    func missingOriginSessionIsRejected() throws {
        let contract = ChatCanvasBoundaryContract(
            capability: ChatCanvasBoundaryContract.canvasMutationCapability,
            workspaceID: "workspace",
            originSessionID: " ",
            activeSessionID: "session-a",
            canvasProviderID: "canvas-provider",
            canvasModelID: "canvas-model",
            approvalReceiptDigest: "approval"
        )

        #expect(throws: ChatCanvasBoundaryError.originSessionMissing) {
            try contract.validate()
        }
    }

    @Test("mutation requires an explicit approval receipt")
    func mutationRequiresApprovalReceipt() throws {
        let contract = ChatCanvasBoundaryContract(
            capability: ChatCanvasBoundaryContract.canvasMutationCapability,
            workspaceID: "workspace",
            originSessionID: "session-a",
            activeSessionID: "session-a",
            canvasProviderID: "canvas-provider",
            canvasModelID: "canvas-model",
            approvalReceiptDigest: nil
        )

        #expect(throws: ChatCanvasBoundaryError.approvalReceiptMissing) {
            try contract.validate()
        }
    }

    @Test("workspace scope is required even when session identity matches")
    func missingWorkspaceScopeIsRejected() throws {
        let contract = ChatCanvasBoundaryContract(
            capability: ChatCanvasBoundaryContract.canvasMutationCapability,
            workspaceID: " \n",
            originSessionID: "session-a",
            activeSessionID: "session-a",
            canvasProviderID: "canvas-provider",
            canvasModelID: "canvas-model",
            approvalReceiptDigest: "approval"
        )

        #expect(throws: ChatCanvasBoundaryError.workspaceMissing) {
            try contract.validate()
        }
    }
}
