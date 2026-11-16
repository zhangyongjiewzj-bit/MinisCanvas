import Foundation
import Testing
import CanvasCore
import MinisCore
@testable import MinisCanvasApp

@Suite("R36 普通 Chat/Canvas mutation zero-call")
@MainActor
struct R36ChatCanvasMutationSpyTests {
    @Test("ordinary sendDraft assistant reply does not reach the Canvas target")
    func ordinarySendDraftDoesNotDispatchCanvasMutation() async throws {
        let target = R36CanvasMutationTargetSpy()
        let bridge = BridgeStore(
            canvas: CanvasStore(),
            canvasMutationCoordinator: makeCoordinator(target: target)
        )
        bridge.chat.agentEngine = ComposerSnapshotMockChatEngine()
        bridge.chat.streamingProviderOverride = MockProvider.shared
        bridge.chat.draftText = "请用普通聊天回答这个问题，不要修改画布。"

        bridge.chat.sendDraft()
        let deadline = Date().addingTimeInterval(15)
        while bridge.chat.isStreaming && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(bridge.chat.isStreaming == false)
        #expect(bridge.chat.messages.last?.role == .assistant)
        #expect(bridge.canvasMutationReceipts.isEmpty)
        #expect(target.totalMutationCalls == 0)
    }

    @Test("Canvas-like text remains a normal Chat submit")
    func canvasLikeTextDoesNotInterceptChatSubmit() async throws {
        let target = R36CanvasMutationTargetSpy()
        let bridge = BridgeStore(
            canvas: CanvasStore(),
            canvasMutationCoordinator: makeCoordinator(target: target)
        )
        bridge.chat.agentEngine = ComposerSnapshotMockChatEngine()
        bridge.chat.streamingProviderOverride = MockProvider.shared
        bridge.chat.draftText = "执行"

        #expect(bridge.chat.onSendCommand == nil)
        bridge.chat.submitComposer()
        let deadline = Date().addingTimeInterval(15)
        while bridge.chat.isStreaming && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(bridge.chat.isStreaming == false)
        #expect(bridge.chat.messages.last?.role == .assistant)
        #expect(bridge.canvasMutationReceipts.isEmpty)
        #expect(target.totalMutationCalls == 0)
    }

    @Test("unknown capability, missing grant, wrong scope, expired and revoked facts never call Canvas")
    func authorizationFailuresAreZeroCall() async throws {
        let scenarios: [(String, ComposerPolicyFactSource, String?)] = [
            (
                "unknown",
                facts(known: [], granted: []),
                nil
            ),
            (
                "missing-grant",
                facts(granted: []),
                nil
            ),
            (
                "wrong-scope",
                facts(workspaceID: "workspace-a"),
                "workspace-b"
            ),
            (
                "expired",
                facts(expiresAt: Date(timeIntervalSince1970: 0)),
                nil
            ),
            (
                "revoked",
                facts(revoked: true),
                nil
            ),
        ]

        for (name, policyFacts, snapshotWorkspaceID) in scenarios {
            let target = R36CanvasMutationTargetSpy()
            let coordinator = makeCoordinator(
                target: target,
                facts: policyFacts,
                snapshotWorkspaceID: snapshotWorkspaceID
            )

            do {
                _ = try await coordinator.execute(.removeNode(id: UUID()))
                Issue.record("\(name) must reject before Canvas target")
            } catch {
                // Expected: policy rejects before the mutation adapter.
            }
            #expect(target.totalMutationCalls == 0)
        }
    }

    @Test("late writeback is rejected before Canvas target")
    func lateWritebackIsZeroCall() async throws {
        let target = R36CanvasMutationTargetSpy()
        let coordinator = makeCoordinator(target: target)
        let request = coordinator.makeRequest(.updateNodeContent(
            content: "迟到的 assistant 写回",
            id: UUID()
        ))
        target.currentCanvasID = UUID()

        await #expect(throws: CanvasMutationError.staleCanvas(
            expected: request.canvasID,
            actual: target.currentCanvasID
        )) {
            _ = try await coordinator.execute(request)
        }
        #expect(target.totalMutationCalls == 0)
    }

    private func makeCoordinator(
        target: any CanvasMutationTarget,
        facts: ComposerPolicyFactSource? = nil,
        snapshotWorkspaceID: String? = nil
    ) -> CanvasMutationCoordinator {
        let policyFacts = facts ?? self.facts()
        return CanvasMutationCoordinator(
            target: target,
            facts: policyFacts,
            grants: ComposerApprovalGrantStore(),
            snapshotFactory: { request, input in
                ComposerSubmissionSnapshot(
                    mode: .auto,
                    approvalScope: .request,
                    effort: .standard,
                    sessionID: "r36-chat-session",
                    turnID: 1,
                    taskID: "r36-chat-task:\(request.id.uuidString)",
                    attemptID: request.id.uuidString,
                    messageID: request.id.uuidString,
                    inputDigest: input.digest,
                    workspaceID: snapshotWorkspaceID ?? policyFacts.workspaceID,
                    createdAt: Date(),
                    policyRevision: policyFacts.revision,
                    grantEpoch: policyFacts.grantEpoch,
                    autonomyCeiling: policyFacts.autonomyCeiling
                )
            },
            originSessionIDProvider: {
                "r36-chat-session"
            }
        )
    }

    private func facts(
        known: Set<String> = ["canvas_mutation"],
        granted: Set<String> = ["canvas_mutation"],
        workspaceID: String = "r36-chat-workspace",
        expiresAt: Date = Date().addingTimeInterval(60),
        revoked: Bool = false
    ) -> ComposerPolicyFactSource {
        ComposerPolicyFactSource(
            knownCapabilities: known,
            grantedCapabilities: granted,
            allowedWriteRoots: [],
            workspaceID: workspaceID,
            revision: "r36-chat-revision",
            grantEpoch: "r36-chat-epoch",
            leaseID: "r36-chat-lease",
            expiresAt: expiresAt,
            revoked: revoked,
            autonomyCeiling: .l3
        )
    }
}

@MainActor
private final class R36CanvasMutationTargetSpy: CanvasMutationTarget {
    var currentCanvasID = UUID()
    var graph = NodeGraph()
    var totalMutationCalls = 0

    @discardableResult
    func addNode(ofType _: String, at _: Point?) -> CanvasNode? {
        totalMutationCalls += 1
        return nil
    }

    func runGraph(from _: Set<UUID>?) {
        totalMutationCalls += 1
    }

    func autoLayout() {
        totalMutationCalls += 1
    }

    func resetStatuses() {
        totalMutationCalls += 1
    }

    @discardableResult
    func deleteCanvas(id _: UUID) -> Bool {
        totalMutationCalls += 1
        return true
    }

    func removeNode(id _: UUID) {
        totalMutationCalls += 1
    }

    @discardableResult
    func updateNodeContent(_: String, for _: UUID) -> Bool {
        totalMutationCalls += 1
        return true
    }
}
