import Foundation
import Testing
@testable import CanvasCore

private final class ContractContext: NodeExecutionContext {
    private(set) var executed = 0

    func resolveInputs(
        for node: CanvasNode,
        in graph: NodeGraph,
        outputs: @escaping (UUID) -> [String: AnyHashable]?
    ) throws -> [String: AnyHashable]? {
        let predecessors = graph.predecessors(of: node.id)
        guard !predecessors.isEmpty else { return nil }
        return ["value": AnyHashable(predecessors.compactMap { outputs($0.id)?["value"] }.count)]
    }

    func execute(node: CanvasNode, inputs: [String: AnyHashable]?) throws -> [String: AnyHashable] {
        executed += 1
        return ["value": AnyHashable(node.title)]
    }
}

private func contractUUID(_ index: Int, _ salt: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-%04x-%012x", salt, index + 1))!
}

private func contractGraph(_ count: Int) -> NodeGraph {
    var graph = NodeGraph()
    for index in 0..<count {
        let input = Port(id: contractUUID(index, 0x5100), name: "in", direction: .input, dataType: "text")
        let output = Port(id: contractUUID(index, 0x5200), name: "out", direction: .output, dataType: "text")
        graph.addNode(CanvasNode(
            id: contractUUID(index, 0x5300), type: "contract", title: "N\(index)",
            inputs: [input], outputs: [output]
        ))
        if index > 0 {
            graph.addEdge(Edge(
                id: contractUUID(index, 0x5400),
                fromNode: contractUUID(index - 1, 0x5300), fromPort: contractUUID(index - 1, 0x5200),
                toNode: contractUUID(index, 0x5300), toPort: contractUUID(index, 0x5100)
            ))
        }
    }
    return graph
}

struct CanvasPerfBaselineContractTests {
    @Test func normalAndStressFinishEveryNode() throws {
        let graph = contractGraph(8)
        let context = ContractContext()
        var scheduler = DAGScheduler()
        let normal = try scheduler.run(graph: graph, context: context)
        #expect(normal.statuses.values.allSatisfy { $0 == .succeeded })
        #expect(context.executed == graph.nodes.count)
        let stress = try scheduler.run(graph: graph, context: context)
        #expect(stress.statuses.values.allSatisfy { $0 == .cached })
    }

    @Test func cancellationAndResumeAreComplete() throws {
        let graph = contractGraph(8)
        let context = ContractContext()
        var scheduler = DAGScheduler()
        let interrupted = try scheduler.run(
            graph: graph, context: context,
            isCancelled: { context.executed >= 4 }
        )
        #expect(interrupted.wasCancelled)
        let resumeFrom = Set(interrupted.statuses.compactMap { id, status in
            status == .succeeded || status == .cached ? id : nil
        })
        let recovered = try scheduler.run(
            graph: graph, context: context, resumeFrom: resumeFrom,
            seedOutputs: interrupted.outputs
        )
        #expect(recovered.statuses.count == graph.nodes.count)
        #expect(recovered.statuses.values.allSatisfy { $0 == .succeeded || $0 == .cached })
    }

    @Test func cacheSecondRunDoesNotExecuteAgain() throws {
        let graph = contractGraph(8)
        let context = ContractContext()
        var scheduler = DAGScheduler()
        _ = try scheduler.run(graph: graph, context: context)
        let executedAfterFirst = context.executed
        let cached = try scheduler.run(graph: graph, context: context)
        #expect(context.executed == executedAfterFirst)
        #expect(cached.statuses.values.allSatisfy { $0 == .cached })
        #expect(scheduler.cacheCount == graph.nodes.count)
    }
}
