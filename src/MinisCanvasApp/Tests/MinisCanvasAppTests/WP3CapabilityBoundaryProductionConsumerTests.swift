import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

private struct WP3ApprovingDelegate: ApprovalDelegate {
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        ApprovalDecision(
            approved: true,
            reason: "Approved",
            confirmed: true,
            requestID: request.requestID,
            bindingDigest: request.identityDigest
        )
    }
}

@Suite("WP-3 capability production consumer")
@MainActor
struct WP3CapabilityBoundaryProductionConsumerTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WP3CapabilityBoundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func configureOrdinaryChat(_ bridge: BridgeStore) {
        bridge.chat.agentEngine = ComposerSnapshotMockChatEngine()
        bridge.chat.streamingProviderOverride = MockProvider.shared
    }

    private func waitForChatIdle(_ bridge: BridgeStore, timeout: TimeInterval = 15) async {
        let deadline = Date().addingTimeInterval(timeout)
        while bridge.chat.isStreaming && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test
    func lateCanvasMutationRequestIsRejectedBeforeTargetWriteback() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let bridge = BridgeStore()
        bridge.attachProductionServices(
            fileAccessAllowedRoot: root,
            sessionDirectory: root,
            approvalDelegateOverride: WP3ApprovingDelegate()
        )
        let request = bridge.canvasMutationCoordinator.makeRequest(
            .addNode(type: "text", position: nil)
        )
        _ = bridge.canvas.addNode(ofType: "text", at: nil)

        await #expect(throws: CanvasMutationError.staleRevision(
            expected: request.baseRevision,
            actual: bridge.canvas.graph.revision
        )) {
            _ = try await bridge.canvasMutationCoordinator.execute(request)
        }
        #expect(bridge.canvasMutationReceipts.isEmpty)
        #expect(bridge.canvas.graph.nodes.count == 1)
    }

    @Test
    func productionCanvasRequestCapturesChatOriginSession() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let bridge = BridgeStore()
        bridge.attachProductionServices(
            fileAccessAllowedRoot: root,
            sessionDirectory: root,
            approvalDelegateOverride: WP3ApprovingDelegate()
        )
        let originSessionID = try #require(bridge.chat.activeSessionID?.uuidString)

        let request = bridge.canvasMutationCoordinator.makeRequest(.resetStatuses)

        #expect(request.originSessionID == originSessionID)
    }

    @Test
    func productionChatCanvasLikeTextHasZeroApprovalAndCanvasCalls() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let bridge = BridgeStore()
        bridge.attachProductionServices(
            fileAccessAllowedRoot: root,
            sessionDirectory: root,
            approvalDelegateOverride: WP3ApprovingDelegate()
        )
        configureOrdinaryChat(bridge)
        let approvalCountBefore = bridge.approvalReceipts.count
        let composerApprovalCountBefore = bridge.composerApprovalReceipts.count
        let messageCountBefore = bridge.chat.messages.count

        bridge.chat.draftText = "建节点 text"
        bridge.chat.submitComposer()
        await waitForChatIdle(bridge)

        #expect(bridge.chat.isStreaming == false)
        #expect(bridge.chat.messages.count > messageCountBefore)
        #expect(bridge.chat.messages.last?.role == .assistant)
        #expect(bridge.approvalReceipts.count == approvalCountBefore)
        #expect(bridge.composerApprovalReceipts.count == composerApprovalCountBefore)
        #expect(bridge.lastCanvasMutationTask == nil)
        #expect(bridge.canvasMutationReceipts.isEmpty)
        #expect(bridge.canvas.graph.nodes.isEmpty)
    }

    @Test
    func productionExplicitCanvasAPIMustProduceCoordinatorReceipt() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let bridge = BridgeStore()
        bridge.attachProductionServices(
            fileAccessAllowedRoot: root,
            sessionDirectory: root,
            approvalDelegateOverride: WP3ApprovingDelegate()
        )

        let receipt = try await bridge.executeCanvasMutation(.resetStatuses)

        #expect(bridge.canvasMutationReceipts.count == 1)
        #expect(receipt.operation == .resetStatuses)
        #expect(bridge.canvasMutationReceipts.first == receipt)
    }

    @Test
    func productionCanvasSnapshotWithMissingCeilingRejectsBeforeWriteback() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let bridge = BridgeStore()
        bridge.attachProductionServices(
            fileAccessAllowedRoot: root,
            sessionDirectory: root,
            approvalDelegateOverride: WP3ApprovingDelegate(),
            sessionReadSecretStore: EnvVarStore(directory: root.appendingPathComponent("env"))
        )
        let current = bridge.chat.composerPolicyFacts
        #expect(current.autonomyCeiling == .l2)
        // Keep the installed coordinator facts intact. Only the current
        // production snapshot source is legacy/missing, so it must fail closed.
        bridge.chat.configureComposerPolicy(
            ComposerPolicyFactSource(
                knownCapabilities: current.knownCapabilities,
                grantedCapabilities: current.grantedCapabilities,
                allowedWriteRoots: current.allowedWriteRoots,
                workspaceID: current.workspaceID,
                revision: current.revision,
                grantEpoch: current.grantEpoch,
                leaseID: current.leaseID,
                expiresAt: current.expiresAt,
                revoked: current.revoked,
                autonomyCeiling: nil
            )
        )
        let revisionBefore = bridge.canvas.graph.revision

        await #expect(throws: ComposerAuthorizationError.autonomyCeilingMissing) {
            _ = try await bridge.executeCanvasMutation(.addNode(type: "text", position: nil))
        }
        #expect(bridge.canvasMutationReceipts.isEmpty)
        #expect(bridge.canvas.graph.nodes.isEmpty)
        #expect(bridge.canvas.graph.revision == revisionBefore)
    }

    @Test
    func productionCanvasSnapshotPreservesLoweredCeilingBeforeWriteback() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let bridge = BridgeStore()
        bridge.attachProductionServices(
            fileAccessAllowedRoot: root,
            sessionDirectory: root,
            approvalDelegateOverride: WP3ApprovingDelegate(),
            policyDefaults: ProductionPolicyDefaults(
                budget: 10, deadlineHorizon: 3_600,
                autonomyLevel: .l0, networkDomains: []
            ),
            sessionReadSecretStore: EnvVarStore(directory: root.appendingPathComponent("env"))
        )
        bridge.chat.composerPolicySelection = .default
        #expect(bridge.chat.composerPolicyFacts.autonomyCeiling == .l0)
        let revisionBefore = bridge.canvas.graph.revision

        await #expect(throws: ComposerAuthorizationError.modeExceedsAutonomyCeiling(
            required: .l1, maximum: .l0
        )) {
            _ = try await bridge.executeCanvasMutation(.addNode(type: "text", position: nil))
        }
        #expect(bridge.canvasMutationReceipts.isEmpty)
        #expect(bridge.canvas.graph.nodes.isEmpty)
        #expect(bridge.canvas.graph.revision == revisionBefore)
    }

    @Test
    func productionPipelineLikeChatTextHasZeroApprovalAndCanvasCalls() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let bridge = BridgeStore()
        bridge.attachProductionServices(
            fileAccessAllowedRoot: root,
            sessionDirectory: root,
            approvalDelegateOverride: WP3ApprovingDelegate()
        )
        configureOrdinaryChat(bridge)
        let approvalCountBefore = bridge.approvalReceipts.count
        let composerApprovalCountBefore = bridge.composerApprovalReceipts.count
        let messageCountBefore = bridge.chat.messages.count

        bridge.chat.draftText = "一键流水线"
        bridge.chat.submitComposer()
        await waitForChatIdle(bridge)

        #expect(bridge.chat.isStreaming == false)
        #expect(bridge.chat.messages.count > messageCountBefore)
        #expect(bridge.chat.messages.last?.role == .assistant)
        #expect(bridge.approvalReceipts.count == approvalCountBefore)
        #expect(bridge.composerApprovalReceipts.count == composerApprovalCountBefore)
        #expect(bridge.lastCanvasMutationTask == nil)
        #expect(bridge.canvas.graph.nodes.isEmpty)
        #expect(bridge.canvasMutationReceipts.isEmpty)
    }

    @Test
    func productionTemplateEntryMustProduceCoordinatorReceipt() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let bridge = BridgeStore()
        bridge.attachProductionServices(
            fileAccessAllowedRoot: root,
            sessionDirectory: root,
            approvalDelegateOverride: WP3ApprovingDelegate()
        )

        bridge.applyTemplate(.textToVideo)

        guard let task = bridge.lastCanvasMutationTask else {
            Issue.record("template entry did not publish a completion task")
            return
        }
        await task.value

        #expect(bridge.canvas.graph.nodes.count == 2)
        #expect(bridge.canvas.graph.edges.isEmpty)
        #expect(bridge.canvasMutationReceipts.count == 1)
        #expect(
            bridge.canvasMutationReceipts.first?.operation
                == .applyTemplate(template: .textToVideo)
        )
    }

    @Test
    func productionChatCanvasLikeTextIgnoresCanvasGrantState() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let bridge = BridgeStore()
        bridge.attachProductionServices(
            fileAccessAllowedRoot: root,
            sessionDirectory: root,
            approvalDelegateOverride: WP3ApprovingDelegate()
        )
        let current = bridge.chat.composerPolicyFacts
        bridge.chat.configureComposerPolicy(
            ComposerPolicyFactSource(
                knownCapabilities: current.knownCapabilities,
                grantedCapabilities: [],
                allowedWriteRoots: current.allowedWriteRoots,
                workspaceID: current.workspaceID,
                revision: current.revision,
                grantEpoch: current.grantEpoch,
                leaseID: current.leaseID,
                expiresAt: current.expiresAt,
                revoked: current.revoked,
                autonomyCeiling: current.autonomyCeiling
            )
        )
        configureOrdinaryChat(bridge)
        let approvalCountBefore = bridge.approvalReceipts.count
        let composerApprovalCountBefore = bridge.composerApprovalReceipts.count
        let messageCountBefore = bridge.chat.messages.count

        bridge.chat.draftText = "执行"
        bridge.chat.submitComposer()
        await waitForChatIdle(bridge)

        #expect(bridge.chat.isStreaming == false)
        #expect(bridge.chat.messages.count > messageCountBefore)
        #expect(bridge.chat.messages.last?.role == .assistant)
        #expect(bridge.approvalReceipts.count == approvalCountBefore)
        #expect(bridge.composerApprovalReceipts.count == composerApprovalCountBefore)
        #expect(bridge.lastCanvasMutationTask == nil)
        #expect(bridge.canvasMutationReceipts.isEmpty)
        #expect(bridge.canvas.graph.nodes.isEmpty)
    }
}
