import Foundation
import Testing
import CanvasCore
import MinisCore
@testable import MinisCanvasApp

@Suite("P1 inspector and result Canvas mutation boundaries")
@MainActor
struct P1CanvasInspectorMutationBoundaryTests {
    @Test("Inspector text writes use the Composer Canvas mutation boundary")
    func inspectorTextWritesUseCoordinator() throws {
        let textInspector = try source("NodeTextInspectorView.swift")
        let nodeInspector = try source("NodeInspectorView.swift")

        #expect(textInspector.contains("bridge.dispatchCanvasMutation"))
        #expect(!textInspector.contains("store.updateNodeContent("))
        #expect(nodeInspector.contains("bridge.dispatchCanvasMutation"))
        #expect(!nodeInspector.contains("store.renameNode("))
        #expect(!nodeInspector.contains("store.updateNodeContent("))
        #expect(!nodeInspector.contains("store.updateBackendConfig("))
    }

    @Test("Asset panel writes use the Composer Canvas mutation boundary")
    func assetPanelWritesUseCoordinator() throws {
        let source = try source("AssetPanelView.swift")

        #expect(source.contains("bridge.executeCanvasMutation"))
        #expect(!source.contains("store.addImageAssetNode("))
        #expect(!source.contains("store.addVideoAssetNode("))
    }

    @Test("Canvas result loading and storyboard expansion use the coordinator")
    func canvasResultWritesUseCoordinator() throws {
        let source = try source("CanvasView.swift")

        #expect(source.contains(".addImageAsset("))
        #expect(source.contains(".addVideoAsset("))
        #expect(source.contains(".expandStoryboard("))
        #expect(!source.contains("store.addImageAssetNode("))
        #expect(!source.contains("store.addVideoAssetNode("))
        #expect(!source.contains("store.expandStoryboard("))
    }

    @Test("Wrong workspace scope keeps inspector mutation at zero target calls")
    func wrongScopeDoesNotCallTarget() async throws {
        let target = InspectorMutationSpy()
        let facts = makeFacts(workspaceID: "workspace-a")
        let coordinator = makeCoordinator(
            target: target,
            facts: facts,
            snapshotWorkspaceID: "workspace-b"
        )

        await #expect(throws: ComposerAuthorizationError.scopeMismatch) {
            _ = try await coordinator.execute(
                .updateBackendConfig(config: NodeBackendConfig(), id: UUID())
            )
        }

        #expect(target.totalMutationCalls == 0)
    }

    @Test("Missing Canvas mutation grant keeps asset loading at zero target calls")
    func missingGrantDoesNotCallTarget() async throws {
        let target = InspectorMutationSpy()
        let facts = ComposerPolicyFactSource(
            knownCapabilities: ["canvas_mutation"],
            grantedCapabilities: [],
            allowedWriteRoots: [],
            workspaceID: "workspace",
            revision: "revision",
            grantEpoch: "epoch",
            leaseID: "canvas-inspector-missing-grant-lease",
            expiresAt: Date().addingTimeInterval(60),
            autonomyCeiling: .l3
        )
        let coordinator = makeCoordinator(target: target, facts: facts)

        await #expect(throws: ComposerAuthorizationError.missingCapabilityGrant("canvas_mutation")) {
            _ = try await coordinator.execute(
                .addImageAsset(path: "/tmp/result.png", name: "result.png", position: nil)
            )
        }

        #expect(target.totalMutationCalls == 0)
    }

    @Test("Expired Composer facts keep storyboard expansion at zero target calls")
    func expiredFactsDoNotCallTarget() async throws {
        let target = InspectorMutationSpy()
        let coordinator = makeCoordinator(
            target: target,
            facts: makeFacts(expiresAt: Date(timeIntervalSince1970: 0))
        )

        await #expect(throws: ComposerAuthorizationError.factsExpired) {
            _ = try await coordinator.execute(.expandStoryboard(id: UUID()))
        }

        #expect(target.totalMutationCalls == 0)
    }

    private func source(_ fileName: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("MinisCanvasApp/Sources/MinisCanvasApp")
                .appendingPathComponent(fileName),
            encoding: .utf8
        )
    }

    private func makeFacts(
        workspaceID: String = "workspace",
        expiresAt: Date = Date().addingTimeInterval(60)
    ) -> ComposerPolicyFactSource {
        ComposerPolicyFactSource(
            knownCapabilities: ["canvas_mutation"],
            grantedCapabilities: ["canvas_mutation"],
            allowedWriteRoots: [],
            workspaceID: workspaceID,
            revision: "revision",
            grantEpoch: "epoch",
            leaseID: "canvas-inspector-lease",
            expiresAt: expiresAt,
            autonomyCeiling: .l3
        )
    }

    private func makeCoordinator(
        target: any CanvasMutationTarget,
        facts: ComposerPolicyFactSource,
        snapshotWorkspaceID: String? = nil
    ) -> CanvasMutationCoordinator {
        CanvasMutationCoordinator(
            target: target,
            facts: facts,
            grants: ComposerApprovalGrantStore(),
            snapshotFactory: { request, input in
                ComposerSubmissionSnapshot(
                    mode: .auto,
                    approvalScope: .request,
                    effort: .standard,
                    sessionID: "session",
                    turnID: 1,
                    taskID: "task:\(request.id.uuidString)",
                    attemptID: "attempt",
                    messageID: request.id.uuidString,
                    inputDigest: input.digest,
                    workspaceID: snapshotWorkspaceID ?? facts.workspaceID,
                    createdAt: Date(),
                    policyRevision: facts.revision,
                    grantEpoch: facts.grantEpoch,
                    autonomyCeiling: facts.autonomyCeiling
                )
            },
            originSessionIDProvider: {
                "session"
            }
        )
    }
}

@MainActor
private final class InspectorMutationSpy: CanvasMutationTarget {
    var currentCanvasID = UUID()
    var graph = NodeGraph()
    var totalMutationCalls = 0

    @discardableResult
    func addNode(ofType _: String, at _: Point?) -> CanvasNode? {
        totalMutationCalls += 1
        return nil
    }

    @discardableResult
    func updateNodeContent(_: String, for _: UUID) -> Bool {
        totalMutationCalls += 1
        return true
    }

    @discardableResult
    func renameNode(id _: UUID, title _: String) -> Bool {
        totalMutationCalls += 1
        return true
    }

    func updateBackendConfig(_: NodeBackendConfig, for _: UUID) {
        totalMutationCalls += 1
    }

    @discardableResult
    func addImageAssetNode(from _: String, name _: String?, near _: Point?) -> CanvasNode? {
        totalMutationCalls += 1
        return nil
    }

    @discardableResult
    func addVideoAssetNode(from _: String, name _: String?, near _: Point?) -> CanvasNode? {
        totalMutationCalls += 1
        return nil
    }

    @discardableResult
    func expandStoryboard(nodeID _: UUID) -> Int {
        totalMutationCalls += 1
        return 0
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
}
