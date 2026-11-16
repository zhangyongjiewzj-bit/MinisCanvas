import Foundation
import Testing
@testable import CanvasCore

@Suite struct GraphImportedOutputsC0053Tests {
    private struct UnusedImageInvoker: ImageGenerating {
        func generate(node: CanvasNode, prompt: String, backend: NodeBackendConfig?) async throws -> ImageGenerationOutcome {
            throw CancellationError()
        }
    }

    private func makeContext() -> GraphExecutionContext {
        GraphExecutionContext(executors: NodeExecutors(llmInvoker: nil), imageInvoker: UnusedImageInvoker())
    }

    @Test func concurrentImportedSubscriptWritesKeepEveryPublishedValue() {
        let context = makeContext()
        let ids = (0..<512).map { _ in UUID() }
        DispatchQueue.concurrentPerform(iterations: ids.count) { index in
            context.importedOutputs[ids[index]] = ["text": AnyHashable(index)]
        }
        let snapshot = context.importedOutputs
        #expect(snapshot.count == ids.count)
        for index in ids.indices {
            #expect(snapshot[ids[index]]?["text"] as? Int == index)
        }
    }

    @Test func resolveInputsUsesOneImportedSnapshotAcrossAllEdges() throws {
        let context = makeContext()
        let first = CanvasNode(type: "text", title: "first", outputs: [Port(name: "text", direction: .output, dataType: "string")])
        let second = CanvasNode(type: "text", title: "second", outputs: [Port(name: "text", direction: .output, dataType: "string")])
        let sink = CanvasNode(type: "text", title: "sink", inputs: [
            Port(name: "left", direction: .input, dataType: "string"),
            Port(name: "right", direction: .input, dataType: "string")
        ])
        var graph = NodeGraph()
        for node in [first, second, sink] { graph.addNode(node) }
        graph.addEdge(Edge(fromNode: first.id, fromPort: first.outputs[0].id, toNode: sink.id, toPort: sink.inputs[0].id))
        graph.addEdge(Edge(fromNode: second.id, fromPort: second.outputs[0].id, toNode: sink.id, toPort: sink.inputs[1].id))
        var calls = 0
        let inputs = try context.resolveInputs(for: sink, in: graph) { nodeID in
            calls += 1
            // A real consumer callback publishes a new generation between edge reads.
            // The in-flight resolve must retain its entry snapshot, then the next resolve sees the update.
            context.importedOutputs = [first.id: ["text": "new-first"], second.id: ["text": "new-second"]]
            return ["text": AnyHashable(nodeID == first.id ? "old-first" : "old-second")]
        }
        #expect(calls == 2)
        #expect(inputs?["left"] as? String == "old-first")
        #expect(inputs?["right"] as? String == "old-second")
        let next = try context.resolveInputs(for: sink, in: graph) { _ in
            Issue.record("published imports must take precedence over fallback")
            return nil
        }
        #expect(next?["left"] as? String == "new-first")
        #expect(next?["right"] as? String == "new-second")
    }
}
