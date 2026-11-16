import Foundation
import Testing
import CanvasCore
import MinisCore
@testable import MinisCanvasApp

@Suite("P1 BridgeStore Canvas mutation coordinator")
@MainActor
struct P1BridgeMutationCoordinatorTests {
    @Test("legacy add, update, and remove commands use the injected coordinator")
    func legacyCommandsUseCoordinator() async throws {
        let canvas = CanvasStore()
        let coordinator = makeCoordinator(target: canvas)
        let bridge = BridgeStore(
            canvas: canvas,
            allowsLegacyCanvasCommandExecutionForTests: true,
            canvasMutationCoordinator: coordinator
        )

        bridge.chat.draftText = "建节点 text"
        bridge.chat.sendDraft()
        await awaitLegacyCanvasCommandCompletion(bridge)
        let node = try #require(bridge.canvas.graph.nodes.first)

        bridge.chat.draftText = "设置 文本输入：受控内容"
        bridge.chat.sendDraft()
        await awaitLegacyCanvasCommandCompletion(bridge)

        bridge.chat.draftText = "删除节点 文本输入"
        bridge.chat.sendDraft()
        await awaitLegacyCanvasCommandCompletion(bridge)

        #expect(bridge.canvasMutationReceipts.map(\.operation) == [
            .addNode(type: "text", position: nil),
            .updateNodeContent(content: "受控内容", id: node.id),
            .removeNode(id: node.id),
        ])
        #expect(bridge.chat.messages.contains {
            $0.role == .assistant && $0.content.contains("已删除节点")
        })
    }

    @Test("agent late writeback is guarded by a frozen mutation request")
    func agentWritebackUsesFrozenRequestAndReportsRejection() async throws {
        let source = try bridgeStoreSource()
        let agentStart = try #require(
            source.range(of: "private func runNodeAgentAdjust", options: .literal)
        )
        let agentBody = source[agentStart.lowerBound...]
        #expect(agentBody.contains("canvasMutationCoordinator.makeRequest"))
        #expect(agentBody.contains("canvasMutationCoordinator.execute"))
        #expect(agentBody.contains("toSession: originSessionID"))
        #expect(!agentBody.contains("self.canvas.updateNodeContent(trimmed"))
    }

    @Test("coordinator rejects a late Agent request before any target write")
    func staleAgentRequestIsFailClosed() async throws {
        let target = CanvasMutationTargetSpy()
        let coordinator = makeCoordinator(target: target)
        let node = try #require(target.addNode(ofType: "text", at: nil))
        let request = coordinator.makeRequest(
            .updateNodeContent(content: "late model output", id: node.id)
        )
        #expect(target.updateNodeContent("newer user content", for: node.id))

        await #expect(throws: CanvasMutationError.staleRevision(
            expected: request.baseRevision,
            actual: target.graph.revision
        )) {
            _ = try await coordinator.execute(
                CanvasMutationRequest(
                    id: request.id,
                    canvasID: request.canvasID,
                    baseRevision: request.baseRevision,
                    baseFingerprint: request.baseFingerprint,
                    originSessionID: request.originSessionID,
                    operation: .updateNodeContent(content: "late model output", id: node.id)
                )
            )
        }

        #expect(target.nodeContent == "newer user content")
        #expect(target.updateCalls == 1)
    }

    private func bridgeStoreSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root
                .appendingPathComponent("MinisCanvasApp/Sources/MinisCanvasApp/BridgeStore.swift"),
            encoding: .utf8
        )
    }

    private func makeCoordinator(
        target: any CanvasMutationTarget
    ) -> CanvasMutationCoordinator {
        let facts = ComposerPolicyFactSource(
            knownCapabilities: ["canvas_mutation"],
            grantedCapabilities: ["canvas_mutation"],
            allowedWriteRoots: [],
            workspaceID: "bridge-test-workspace",
            revision: "bridge-test-revision",
            grantEpoch: "bridge-test-epoch",
            leaseID: "bridge-test-lease",
            expiresAt: Date().addingTimeInterval(60),
            autonomyCeiling: .l3
        )
        return CanvasMutationCoordinator(
            target: target,
            facts: facts,
            grants: ComposerApprovalGrantStore(),
            snapshotFactory: { request, input in
                ComposerSubmissionSnapshot(
                    mode: .auto,
                    approvalScope: .request,
                    effort: .standard,
                    sessionID: "bridge-test-session",
                    turnID: 1,
                    taskID: "bridge-test:\(request.id.uuidString)",
                    attemptID: request.id.uuidString,
                    messageID: request.id.uuidString,
                    inputDigest: input.digest,
                    workspaceID: facts.workspaceID,
                    createdAt: Date(),
                    policyRevision: facts.revision,
                    grantEpoch: facts.grantEpoch,
                    autonomyCeiling: facts.autonomyCeiling
                )
            },
            originSessionIDProvider: {
                "bridge-test-session"
            }
        )
    }
}

@MainActor
private final class CanvasMutationTargetSpy: CanvasMutationTarget {
    var currentCanvasID = UUID()
    var graph = NodeGraph()
    var updateCalls = 0
    var nodeContent = ""

    @discardableResult
    func addNode(ofType type: String, at position: Point?) -> CanvasNode? {
        let node = CanvasNode(type: type, title: type, position: position ?? .zero)
        graph.addNode(node)
        return node
    }

    @discardableResult
    func updateNodeContent(_ content: String, for _: UUID) -> Bool {
        updateCalls += 1
        nodeContent = content
        graph.revision += 1
        return true
    }

    func runGraph(from _: Set<UUID>?) {}
    func autoLayout() {}
    func resetStatuses() {}
    @discardableResult
    func deleteCanvas(id _: UUID) -> Bool { true }
    func removeNode(id: UUID) { graph.removeNode(id: id) }
}
