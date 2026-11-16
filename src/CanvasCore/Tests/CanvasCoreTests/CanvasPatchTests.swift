import Foundation
import Testing
@testable import CanvasCore

struct CanvasPatchTests {
    private let canvasID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!

    private func graph() -> (NodeGraph, CanvasNode, CanvasNode, Edge) {
        let output = Port(id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!, name: "out", direction: .output, dataType: "text")
        let input = Port(id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!, name: "in", direction: .input, dataType: "text")
        let a = CanvasNode(id: UUID(uuidString: "00000000-0000-0000-0000-000000000013")!, type: "source", title: "A", outputs: [output])
        let b = CanvasNode(id: UUID(uuidString: "00000000-0000-0000-0000-000000000014")!, type: "sink", title: "B", inputs: [input])
        let edge = Edge(id: UUID(uuidString: "00000000-0000-0000-0000-000000000015")!, fromNode: a.id, fromPort: output.id, toNode: b.id, toPort: input.id)
        return (NodeGraph(nodes: [a, b], edges: [edge], revision: 4), a, b, edge)
    }

    private struct EmptyContext: NodeExecutionContext {
        func resolveInputs(
            for node: CanvasNode,
            in graph: NodeGraph,
            outputs: @escaping (UUID) -> [String: AnyHashable]?
        ) throws -> [String: AnyHashable]? { nil }

        func execute(node: CanvasNode, inputs: [String: AnyHashable]?) throws -> [String: AnyHashable] {
            [:]
        }
    }

    @Test func patchAppliesAtomicallyAndAdvancesRevision() throws {
        let (graph, _, b, _) = graph()
        let patch = CanvasPatch(
            canvasID: canvasID,
            baseRevision: graph.revision,
            baseFingerprint: graph.fingerprint,
            operations: [.updateNode(CanvasNode(id: b.id, type: b.type, title: "B2", inputs: b.inputs))]
        )

        let updated = try patch.applying(to: graph, canvasID: canvasID)
        #expect(updated.revision == 5)
        #expect(updated.node(id: b.id)?.title == "B2")
        #expect(updated.edges.count == 1)
    }

    @Test func staleRevisionAndFingerprintAreRejectedBeforeMutation() throws {
        let (graph, _, b, _) = graph()
        let operation = CanvasPatchOperation.updateNode(CanvasNode(id: b.id, type: b.type, title: "changed", inputs: b.inputs))
        let oldRevision = CanvasPatch(canvasID: canvasID, baseRevision: 3, baseFingerprint: graph.fingerprint, operations: [operation])
        #expect(throws: CanvasPatchError.self) { _ = try oldRevision.applying(to: graph, canvasID: canvasID) }

        let oldFingerprint = CanvasPatch(canvasID: canvasID, baseRevision: graph.revision, baseFingerprint: "stale", operations: [operation])
        #expect(throws: CanvasPatchError.self) { _ = try oldFingerprint.applying(to: graph, canvasID: canvasID) }
    }

    @Test func patchFromAnotherCanvasIsRejectedBeforeMutation() throws {
        let (graph, _, b, _) = graph()
        let otherCanvasID = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        let patch = CanvasPatch(
            canvasID: otherCanvasID,
            baseRevision: graph.revision,
            baseFingerprint: graph.fingerprint,
            operations: [.updateNode(CanvasNode(id: b.id, type: b.type, title: "wrong canvas", inputs: b.inputs))]
        )

        #expect(throws: CanvasPatchError.canvasMismatch(expected: otherCanvasID, actual: canvasID)) {
            _ = try patch.applying(to: graph, canvasID: canvasID)
        }
        #expect(graph.node(id: b.id)?.title == "B")
    }

    @Test func invalidEdgePatchIsRejectedWithoutPartialApply() throws {
        let (graph, a, b, _) = graph()
        let badEdge = Edge(fromNode: a.id, fromPort: UUID(), toNode: b.id, toPort: b.inputs[0].id)
        let patch = CanvasPatch(baseRevision: graph.revision, baseFingerprint: graph.fingerprint, operations: [
            .updateNode(CanvasNode(id: b.id, type: b.type, title: "should-not-apply", inputs: b.inputs)),
            .addEdge(badEdge)
        ])
        #expect(throws: CanvasPatchError.self) { _ = try patch.applying(to: graph) }
        #expect(graph.node(id: b.id)?.title == "B")
    }

    @Test func patchRoundTripAndFutureSchemaInputFailClosed() throws {
        let (graph, _, _, _) = graph()
        let patch = CanvasPatch(baseRevision: graph.revision, baseFingerprint: graph.fingerprint, operations: [])
        #expect(try JSONDecoder().decode(CanvasPatch.self, from: JSONEncoder().encode(patch)) == patch)
        let future = Data("{\"schemaVersion\":99,\"id\":\"00000000-0000-0000-0000-000000000001\",\"baseRevision\":0,\"baseFingerprint\":\"x\",\"operations\":[]}".utf8)
        #expect(throws: CanvasSchemaError.self) { _ = try JSONDecoder().decode(CanvasPatch.self, from: future) }
    }

    @Test func malformedCoreDTOsAreRejected() {
        let negativeRevision = Data("{\"schemaVersion\":1,\"canvasID\":\"00000000-0000-0000-0000-000000000001\",\"runID\":\"00000000-0000-0000-0000-000000000002\",\"graphRevision\":-1,\"nodeID\":\"00000000-0000-0000-0000-000000000003\",\"nodeRevision\":0}".utf8)
        #expect(throws: CanvasSchemaError.self) { _ = try JSONDecoder().decode(CanvasExecutionIdentity.self, from: negativeRevision) }

        let emptyProviderFingerprint = Data("{\"schemaVersion\":1,\"providerID\":\"p\",\"modelID\":\"m\",\"capabilities\":[],\"configurationFingerprint\":\" \"}".utf8)
        #expect(throws: CanvasSchemaError.self) { _ = try JSONDecoder().decode(ProviderSnapshot.self, from: emptyProviderFingerprint) }
    }

    @Test func mediaValueRejectsEmptyCollections() {
        let data = Data("{\"schemaVersion\":1,\"valueKind\":\"assets\",\"assets\":[]}".utf8)
        #expect(throws: CanvasSchemaError.self) { _ = try JSONDecoder().decode(MediaValue.self, from: data) }
    }

    @Test func dagRejectsStaleRevisionAndFingerprintBeforeExecution() throws {
        let (graph, _, _, _) = graph()
        var scheduler = DAGScheduler()
        #expect(throws: DAGSchedulerError.self) {
            _ = try scheduler.run(graph: graph, context: EmptyContext(), expectedRevision: graph.revision - 1)
        }
        #expect(throws: DAGSchedulerError.self) {
            _ = try scheduler.run(graph: graph, context: EmptyContext(), expectedFingerprint: "stale")
        }
    }

    @Test func legacyMigrationIsIdempotentAndHandlesRemoteOnlyAssets() throws {
        let nodeID = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
        let node = CanvasNode(
            id: nodeID,
            type: "assetRef",
            title: "legacy",
            backendConfig: NodeBackendConfig(params: [
                "result.path": " https://cdn.example.invalid/a.png ",
                "result.kind": "image"
            ])
        )
        let first = LegacyMediaMigration.migrate(nodes: [node, node], canvasID: canvasID)
        #expect(first.count == 1)
        #expect(first[0].localURL == nil)
        #expect(first[0].remoteURL == "https://cdn.example.invalid/a.png")

        var existing = first[0]
        existing.metadata["kept"] = "yes"
        let second = LegacyMediaMigration.migrate(nodes: [node], canvasID: canvasID, existingAssets: [existing])
        #expect(second == [existing])
    }

    @Test func legacyCanonicalizationPromotesResultPathToStableAssetID() throws {
        let node = CanvasNode(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!,
            type: "assetRef",
            title: "legacy",
            backendConfig: NodeBackendConfig(params: [
                "result.path": "/tmp/legacy.png",
                "result.kind": "image"
            ])
        )

        let first = try #require(LegacyMediaMigration.canonicalize(node: node, canvasID: canvasID))
        let second = try #require(LegacyMediaMigration.canonicalize(node: first.node, canvasID: canvasID))

        #expect(first.node.backendConfig?.params["asset.id"] == first.asset.id.uuidString)
        #expect(first.node.backendConfig?.params["result.path"] == "/tmp/legacy.png")
        #expect(second.asset.id == first.asset.id)
        #expect(second.node.backendConfig?.params["asset.id"] == first.asset.id.uuidString)
        #expect(LegacyMediaMigration.migrate(nodes: [first.node], canvasID: canvasID, existingAssets: [first.asset]) == [first.asset])
    }
}
