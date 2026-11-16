import Foundation
import Testing
import CanvasCore
import MinisCore
@testable import MinisCanvasApp

@Suite("P1 residual Canvas direct mutation boundaries")
@MainActor
struct P1CanvasDirectMutationBoundaryTests {
    @Test("Storyboard empty-state creation is coordinator-gated")
    func storyboardCreationUsesCoordinator() throws {
        let source = try source("StoryboardWorkbenchView.swift")

        #expect(source.contains("mutationCoordinator"))
        #expect(source.contains(".addNode(type: CanvasStore.storyboardNodeType"))
        #expect(!source.contains("store.addNode(ofType: CanvasStore.storyboardNodeType)"))
    }

    @Test("Novel import creation is coordinator-gated")
    func novelImportCreationUsesCoordinator() throws {
        let source = try source("BridgeStore.swift")

        #expect(source.contains("canvasMutationCoordinator"))
        #expect(source.contains(".addNodeWithContent("))
        #expect(!source.contains("self.canvas.addNode(ofType: ManjuNodeType.novelImport.rawValue)"))
        #expect(!source.contains("self.canvas.updateNodeContent(content"))
    }

    @Test("Pipeline Chat command cannot bypass the Canvas coordinator")
    func pipelineCommandUsesCoordinator() throws {
        let source = try source("BridgeStore.swift")
        let commandStart = try #require(
            source.range(of: "case .createPipeline:")
        )
        let commandBody = source[commandStart.lowerBound...]
        let commandEnd = commandBody.range(of: "\n\n")
        let commandBlock = commandEnd.map { commandBody[..<$0.lowerBound] } ?? commandBody

        #expect(commandBlock.contains("createManjuPipelineAuthorized"))
        #expect(!commandBlock.contains("createManjuPipeline()"))

        let helperStart = try #require(
            source.range(of: "private func createManjuPipelineAuthorized")
        )
        let helperBody = source[helperStart.lowerBound...]
        let helperEnd = helperBody.range(of: "\n    private func createManjuPipelineForLegacyTests")
        let helperBlock = helperEnd.map { helperBody[..<$0.lowerBound] } ?? helperBody
        #expect(helperBlock.contains("executeCanvasMutation"))
    }

    @Test("Public pipeline entry cannot write Canvas directly")
    func publicPipelineEntryUsesBoundary() throws {
        let source = try source("BridgeStore.swift")
        let methodStart = try #require(
            source.range(of: "func createManjuPipeline()")
        )
        let methodBody = source[methodStart.lowerBound...]
        let methodEnd = methodBody.range(of: "\n    private func createManjuPipelineAuthorized")
        let methodBlock = methodEnd.map { methodBody[..<$0.lowerBound] } ?? methodBody

        #expect(methodBlock.contains("createManjuPipelineAuthorized"))
        #expect(!methodBlock.contains("canvas.createManjuPipeline()"))
    }

    @Test("Public template entry cannot write Canvas directly")
    func publicTemplateEntryUsesBoundary() throws {
        let source = try source("BridgeStore.swift")
        let methodStart = try #require(
            source.range(of: "func applyTemplate(_ template: CanvasTemplate)")
        )
        let methodBody = source[methodStart.lowerBound...]
        let methodEnd = methodBody.range(of: "\n    private func applyTemplateAuthorized")
        let methodBlock = methodEnd.map { methodBody[..<$0.lowerBound] } ?? methodBody

        #expect(methodBlock.contains("applyTemplateAuthorized"))
        #expect(!methodBlock.contains("canvas.applyTemplate(template)"))
    }

    @Test("Novel import uses an explicitly injected coordinator")
    func novelImportUsesInjectedCoordinator() async throws {
        let canvas = CanvasStore()
        let facts = makeFacts(workspaceID: "bridge-test-workspace")
        let coordinator = makeCoordinator(target: canvas, facts: facts)
        let bridge = BridgeStore(
            canvas: canvas,
            allowsLegacyCanvasCommandExecutionForTests: true,
            canvasMutationCoordinator: coordinator
        )

        bridge.chat.draftText = "小说内容：受控注入测试文本"
        bridge.chat.sendDraft()
        await awaitLegacyCanvasCommandCompletion(bridge)

        #expect(bridge.canvasMutationCoordinator === coordinator)
        let novel = bridge.canvas.novelNode()
        #expect(novel != nil)
        #expect(bridge.canvas.nodeContent(id: novel!.id) == "受控注入测试文本")
    }

    @Test("Canvas delete shortcut dispatches through the coordinator")
    func canvasDeleteUsesCoordinator() throws {
        let source = try source("CanvasView.swift")

        #expect(source.contains("mutationCoordinator?.dispatch(.removeNodes"))
        #expect(!source.contains("onDelete: { store.deleteSelected() }"))
    }

    @Test("CanvasView inline content writes use the coordinator")
    func canvasInlineContentUsesCoordinator() throws {
        let source = try source("CanvasView.swift")

        #expect(source.contains("mutationCoordinator?.dispatch(\n            .updateNodeContent(content: inlineDraft, id: node.id)\n        )"))
        #expect(!source.contains("store.updateNodeContent(inlineDraft, for: node.id)"))
    }

    @Test("Inline content update stays fail-closed across policy, identity, and revision")
    func inlineContentUpdatePreservesCoordinatorGates() async throws {
        let deniedTarget = CanvasMutationBoundarySpy()
        let deniedCoordinator = makeCoordinator(
            target: deniedTarget,
            facts: ComposerPolicyFactSource(
                knownCapabilities: ["canvas_mutation"],
                grantedCapabilities: [],
                allowedWriteRoots: [],
                workspaceID: "workspace",
                revision: "revision",
                grantEpoch: "epoch",
                leaseID: "canvas-inline-denied-lease",
                expiresAt: Date().addingTimeInterval(60),
                autonomyCeiling: .l3
            )
        )

        await #expect(throws: ComposerAuthorizationError.missingCapabilityGrant("canvas_mutation")) {
            _ = try await deniedCoordinator.execute(
                .updateNodeContent(content: "拒绝写入", id: UUID())
            )
        }
        #expect(deniedTarget.totalMutationCalls == 0)

        let driftTarget = CanvasMutationBoundarySpy()
        let driftCoordinator = makeCoordinator(
            target: driftTarget,
            facts: makeFacts()
        )
        let request = driftCoordinator.makeRequest(
            .updateNodeContent(content: "迟到写入", id: UUID())
        )
        driftTarget.currentCanvasID = UUID()

        await #expect(throws: CanvasMutationError.staleCanvas(
            expected: request.canvasID,
            actual: driftTarget.currentCanvasID
        )) {
            _ = try await driftCoordinator.execute(request)
        }
        #expect(driftTarget.totalMutationCalls == 0)

        let revisionTarget = CanvasMutationBoundarySpy()
        let revisionCoordinator = makeCoordinator(
            target: revisionTarget,
            facts: makeFacts()
        )
        let revisionRequest = revisionCoordinator.makeRequest(
            .updateNodeContent(content: "过期写入", id: UUID())
        )
        revisionTarget.graph.revision = revisionRequest.baseRevision + 1

        await #expect(throws: CanvasMutationError.staleRevision(
            expected: revisionRequest.baseRevision,
            actual: revisionTarget.graph.revision
        )) {
            _ = try await revisionCoordinator.execute(revisionRequest)
        }
        #expect(revisionTarget.totalMutationCalls == 0)
    }

    @Test("Wrong workspace scope reaches zero underlying mutation calls")
    func wrongScopeDoesNotCallTarget() async throws {
        let target = CanvasMutationBoundarySpy()
        let coordinator = makeCoordinator(
            target: target,
            facts: makeFacts(workspaceID: "workspace-a"),
            snapshotWorkspaceID: "workspace-b"
        )

        await #expect(throws: ComposerAuthorizationError.scopeMismatch) {
            _ = try await coordinator.execute(.removeNode(id: UUID()))
        }

        #expect(target.totalMutationCalls == 0)
    }

    @Test("Missing canvas mutation grant reaches zero underlying mutation calls")
    func missingGrantDoesNotCallTarget() async throws {
        let target = CanvasMutationBoundarySpy()
        let coordinator = makeCoordinator(
            target: target,
            facts: ComposerPolicyFactSource(
                knownCapabilities: ["canvas_mutation"],
                grantedCapabilities: [],
                allowedWriteRoots: [],
                workspaceID: "workspace",
                revision: "revision",
                grantEpoch: "epoch",
                leaseID: "canvas-missing-grant-lease",
                expiresAt: Date().addingTimeInterval(60),
                autonomyCeiling: .l3
            )
        )

        await #expect(throws: ComposerAuthorizationError.missingCapabilityGrant("canvas_mutation")) {
            _ = try await coordinator.execute(.removeNode(id: UUID()))
        }

        #expect(target.totalMutationCalls == 0)
    }

    @Test("Expired Composer facts reach zero underlying mutation calls")
    func expiredFactsDoNotCallTarget() async throws {
        let target = CanvasMutationBoundarySpy()
        let coordinator = makeCoordinator(
            target: target,
            facts: makeFacts(expiresAt: Date(timeIntervalSince1970: 0))
        )

        await #expect(throws: ComposerAuthorizationError.factsExpired) {
            _ = try await coordinator.execute(.removeNode(id: UUID()))
        }

        #expect(target.totalMutationCalls == 0)
    }

    @Test("Missing Canvas provider/model blocks before target and never borrows Chat selection")
    func missingCanvasModelDoesNotCallTargetOrBorrowChatModel() async throws {
        let chat = ChatStore()
        chat.selectModel(.deepSeekReasoner)

        let unavailableConfigs: [NodeBackendConfig?] = [
            nil,
            NodeBackendConfig(providerType: .cloud, providerID: " ", modelID: "gpt-image-2"),
            NodeBackendConfig(providerType: .cloud, providerID: "gimage2", modelID: " ")
        ]
        for config in unavailableConfigs {
            let nodeID = UUID()
            let target = CanvasMutationBoundarySpy(
                graph: NodeGraph(nodes: [
                    CanvasNode(
                        id: nodeID,
                        type: ManjuNodeType.imageGen.rawValue,
                        title: "缺少画布模型",
                        backendConfig: config
                    )
                ])
            )
            let coordinator = makeCoordinator(target: target, facts: makeFacts())

            await #expect(throws: CanvasMutationError.canvasModelUnavailable) {
                _ = try await coordinator.execute(.runGraph(nodeIDs: [nodeID]))
            }
            #expect(target.totalMutationCalls == 0)
        }

        #expect(chat.selectedProviderType == .deepSeek)
        #expect(chat.selectedModelID == "deepseek-reasoner")
    }

    @Test("Run graph does not require a Canvas model for local QC nodes")
    func localQcRunGraphDoesNotRequireCanvasModel() async throws {
        let nodeID = UUID()
        let target = CanvasMutationBoundarySpy(
            graph: NodeGraph(nodes: [
                CanvasNode(
                    id: nodeID,
                    type: ManjuNodeType.qcCheck.rawValue,
                    title: "本地质检",
                    backendConfig: nil
                )
            ])
        )
        let coordinator = makeCoordinator(target: target, facts: makeFacts())

        _ = try await coordinator.execute(.runGraph(nodeIDs: [nodeID]))

        #expect(target.totalMutationCalls == 1)
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
            leaseID: "canvas-direct-lease",
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
private final class CanvasMutationBoundarySpy: CanvasMutationTarget {
    var currentCanvasID = UUID()
    var graph: NodeGraph
    var totalMutationCalls = 0

    init(graph: NodeGraph = NodeGraph()) {
        self.graph = graph
    }

    @discardableResult
    func addNode(ofType _: String, at _: Point?) -> CanvasNode? {
        totalMutationCalls += 1
        graph.revision += 1
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
