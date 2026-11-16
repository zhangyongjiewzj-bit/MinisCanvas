import Foundation
import Testing
import CanvasCore
import MinisCore
@testable import MinisCanvasApp

@Suite("R45 Chat/Canvas mutation boundary")
@MainActor
struct R45ChatCanvasBoundaryWriteTests {
    @Test("Canvas recovery is routed through the explicit mutation boundary")
    func recoveryDoesNotWriteCanvasStoreDirectly() throws {
        let source = try source("BridgeStore.swift")
        let start = try #require(source.range(of: "func handleRecoverCanvasDraft()"))
        let body = source[start.lowerBound...]
        let end = body.range(of: "\n    /// 丢弃画布草稿")
        let recoveryBody = end.map { body[..<$0.lowerBound] } ?? body

        #expect(recoveryBody.contains("canvasMutationCoordinator"))
        #expect(!recoveryBody.contains("canvas.restoreCanvas(from: draft)"))
    }

    @Test("ordinary Chat with an attachment never reaches a Canvas mutation target")
    func attachmentSendDraftHasZeroCanvasCalls() async throws {
        let target = R45CanvasMutationTargetSpy()
        let bridge = BridgeStore(
            canvas: CanvasStore(),
            canvasMutationCoordinator: makeCoordinator(target: target)
        )
        bridge.chat.agentEngine = ComposerSnapshotMockChatEngine()
        bridge.chat.streamingProviderOverride = MockProvider.shared

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("r45-attachment-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let attachmentURL = directory.appendingPathComponent("note.txt")
        try Data("ordinary attachment".utf8).write(to: attachmentURL)
        bridge.chat.addAttachments(urls: [attachmentURL])
        bridge.chat.draftText = "请用普通聊天总结附件。"

        bridge.chat.sendDraft()
        let deadline = Date().addingTimeInterval(10)
        while bridge.chat.isStreaming && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(bridge.chat.isStreaming == false)
        #expect(bridge.chat.messages.last?.role == .assistant)
        #expect(bridge.canvasMutationReceipts.isEmpty)
        #expect(target.mutationCount == 0)
    }

    @Test("Canvas actions preserve local selection without writing Chat state")
    func canvasActionDoesNotWriteChatTranscriptOrStatus() async throws {
        let canvas = CanvasStore()
        let coordinator = makeCoordinator(target: canvas)
        let bridge = BridgeStore(
            canvas: canvas,
            canvasMutationCoordinator: coordinator
        )
        let sessionID = bridge.chat.activeSessionID
        let messagesBefore = bridge.chat.messages
        let revisionBefore = bridge.chat.transcriptRevision(forSession: sessionID)
        let streamingBefore = bridge.chat.isStreaming

        #expect(canvas.onEvent != nil)
        _ = try await coordinator.execute(
            .addNode(type: "text", position: nil),
            originSessionID: "session-a"
        )
        let node = try #require(canvas.graph.nodes.first)
        canvas.selectNode(id: node.id)

        #expect(bridge.selectedNodeContext?.title == node.title)
        #expect(bridge.selectedNodeContext?.type == node.type)
        #expect(bridge.chat.messages == messagesBefore)
        #expect(bridge.chat.transcriptRevision(forSession: sessionID) == revisionBefore)
        #expect(bridge.chat.isStreaming == streamingBefore)

        canvas.deselectAll()
        #expect(bridge.selectedNodeContext == nil)
        #expect(bridge.chat.messages == messagesBefore)
        #expect(bridge.chat.transcriptRevision(forSession: sessionID) == revisionBefore)
    }

    @Test("a cross-session sendDraft snapshot cannot write Canvas")
    func crossSessionSendDraftHasZeroCanvasCalls() async throws {
        let target = R45CanvasMutationTargetSpy()
        let policyFacts = facts()
        let coordinator = CanvasMutationCoordinator(
            target: target,
            facts: policyFacts,
            grants: ComposerApprovalGrantStore(),
            snapshotFactory: { request, input in
                ComposerSubmissionSnapshot(
                    mode: .auto,
                    approvalScope: .request,
                    effort: .standard,
                    sessionID: "session-b",
                    turnID: 2,
                    taskID: "r45-cross-session:\(request.id.uuidString)",
                    attemptID: request.id.uuidString,
                    messageID: request.id.uuidString,
                    inputDigest: input.digest,
                    workspaceID: policyFacts.workspaceID,
                    createdAt: Date(),
                    policyRevision: policyFacts.revision,
                    grantEpoch: policyFacts.grantEpoch,
                    autonomyCeiling: policyFacts.autonomyCeiling
                )
            },
            originSessionIDProvider: { "session-b" }
        )

        await #expect(throws: ChatCanvasBoundaryError.sessionMismatch(
            origin: "session-a",
            active: "session-b"
        )) {
            _ = try await coordinator.execute(
                .removeNode(id: UUID()),
                originSessionID: "session-a"
            )
        }
        #expect(coordinator.receipts.isEmpty)
        #expect(target.mutationCount == 0)
    }

    @Test("late Canvas writeback is rejected before any target call")
    func lateWritebackHasZeroCanvasCalls() async throws {
        let target = R45CanvasMutationTargetSpy()
        let coordinator = makeCoordinator(target: target)
        let request = coordinator.makeRequest(
            .updateNodeContent(content: "迟到写回", id: UUID()),
            originSessionID: "session-a"
        )
        target.currentCanvasID = UUID()

        await #expect(throws: CanvasMutationError.staleCanvas(
            expected: request.canvasID,
            actual: target.currentCanvasID
        )) {
            _ = try await coordinator.execute(request)
        }
        #expect(target.mutationCount == 0)
    }

    @Test("a duplicate request ID cannot write Canvas a second time")
    func duplicateRequestHasOneCanvasWrite() async throws {
        let target = R45CanvasMutationTargetSpy()
        let coordinator = makeCoordinator(target: target)
        let request = coordinator.makeRequest(
            .updateNodeContent(content: "只允许一次", id: UUID()),
            originSessionID: "session-a"
        )

        _ = try await coordinator.execute(request)
        await #expect(throws: CanvasMutationError.duplicateRequest(request.id)) {
            _ = try await coordinator.execute(request)
        }

        #expect(target.mutationCount == 1)
        #expect(coordinator.receipts.count == 1)
    }

    private func source(_ fileName: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root
                .appendingPathComponent("MinisCanvasApp/Sources/MinisCanvasApp")
                .appendingPathComponent(fileName),
            encoding: .utf8
        )
    }

    private func facts() -> ComposerPolicyFactSource {
        ComposerPolicyFactSource(
            knownCapabilities: ["canvas_mutation"],
            grantedCapabilities: ["canvas_mutation"],
            allowedWriteRoots: [],
            workspaceID: "r45-boundary-workspace",
            revision: "r45-boundary-revision",
            grantEpoch: "r45-boundary-epoch",
            leaseID: "r45-boundary-lease",
            expiresAt: Date().addingTimeInterval(60),
            autonomyCeiling: .l3
        )
    }

    private func makeCoordinator(
        target: any CanvasMutationTarget
    ) -> CanvasMutationCoordinator {
        let policyFacts = facts()
        return CanvasMutationCoordinator(
            target: target,
            facts: policyFacts,
            grants: ComposerApprovalGrantStore(),
            snapshotFactory: { request, input in
                ComposerSubmissionSnapshot(
                    mode: .auto,
                    approvalScope: .request,
                    effort: .standard,
                    sessionID: "session-a",
                    turnID: 1,
                    taskID: "r45-task:\(request.id.uuidString)",
                    attemptID: request.id.uuidString,
                    messageID: request.id.uuidString,
                    inputDigest: input.digest,
                    workspaceID: policyFacts.workspaceID,
                    createdAt: Date(),
                    policyRevision: policyFacts.revision,
                    grantEpoch: policyFacts.grantEpoch,
                    autonomyCeiling: policyFacts.autonomyCeiling
                )
            },
            originSessionIDProvider: { "session-a" }
        )
    }
}

@MainActor
private final class R45CanvasMutationTargetSpy: CanvasMutationTarget {
    var currentCanvasID = UUID()
    var graph = NodeGraph()
    var mutationCount = 0

    @discardableResult
    func addNode(ofType _: String, at _: Point?) -> CanvasNode? {
        mutationCount += 1
        return nil
    }

    func runGraph(from _: Set<UUID>?) { mutationCount += 1 }
    func autoLayout() { mutationCount += 1 }
    func resetStatuses() { mutationCount += 1 }
    @discardableResult
    func deleteCanvas(id _: UUID) -> Bool {
        mutationCount += 1
        return true
    }
    func removeNode(id _: UUID) { mutationCount += 1 }
    @discardableResult
    func updateNodeContent(_: String, for _: UUID) -> Bool {
        mutationCount += 1
        return true
    }
}
