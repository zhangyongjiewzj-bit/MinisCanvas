import Testing
@testable import CanvasCore

struct GraphModelsTests {

    // MARK: - 辅助构造

    private func makeNode(
        type: String = "llm",
        title: String = "node",
        inputs: [Port] = [],
        outputs: [Port] = []
    ) -> CanvasNode {
        CanvasNode(type: type, title: title, inputs: inputs, outputs: outputs)
    }

    // MARK: - Port / CanvasNode

    @Test func portDefaultsAndEquality() {
        let a = Port(name: "prompt", direction: .input, dataType: "string")
        let b = Port(name: "prompt", direction: .input, dataType: "string")
        #expect(a.id != b.id, "两个 Port 的 id 应互不相同")
        #expect(a.name == b.name)
        #expect(a.direction == .input)
        #expect(a.dataType == "string")
        #expect(a != b, "id 不同则 Port 不应相等")
    }

    @Test func nodeDefaultValues() {
        let node = makeNode()
        #expect(node.status == .pending)
        #expect(node.backendID == nil)
        #expect(node.position == Point(x: 0, y: 0))
        #expect(node.inputs.isEmpty)
        #expect(node.outputs.isEmpty)
    }

    @Test func nodeBackendIDAndStatusMutation() {
        var node = makeNode()
        node.backendID = "gimage2"
        node.status = .running
        #expect(node.backendID == "gimage2")
        #expect(node.status == .running)
    }

    @Test func graphValidationRejectsDuplicateNodeAndEdgeIDs() {
        let output = Port(name: "out", direction: .output, dataType: "text")
        let input = Port(name: "in", direction: .input, dataType: "text")
        let source = makeNode(title: "source", outputs: [output])
        let sink = makeNode(title: "sink", inputs: [input])
        let edge = Edge(fromNode: source.id, fromPort: output.id, toNode: sink.id, toPort: input.id)

        #expect(throws: CanvasSchemaError.invalidField("graph.nodes")) {
            try NodeGraph(nodes: [source, source]).validate()
        }
        #expect(throws: CanvasSchemaError.invalidField("graph.edges")) {
            try NodeGraph(nodes: [source, sink], edges: [edge, edge]).validate()
        }
    }

    // MARK: - 节点增删

    @Test func addNode() {
        var graph = NodeGraph()
        let a = makeNode(title: "A")
        let b = makeNode(title: "B")
        graph.addNode(a)
        graph.addNode(b)
        #expect(graph.nodes.count == 2)
        #expect(graph.node(id: a.id) != nil)
        #expect(graph.node(id: b.id) != nil)
    }

    @Test func removeNodeAlsoRemovesConnectedEdges() {
        var graph = NodeGraph()
        let a = makeNode(title: "A")
        let b = makeNode(title: "B")
        let c = makeNode(title: "C")
        graph.addNode(a)
        graph.addNode(b)
        graph.addNode(c)

        let pOut = Port(name: "out", direction: .output, dataType: "image")
        let pIn = Port(name: "in", direction: .input, dataType: "image")
        let e1 = Edge(fromNode: a.id, fromPort: pOut.id, toNode: b.id, toPort: pIn.id)
        let e2 = Edge(fromNode: b.id, fromPort: pOut.id, toNode: c.id, toPort: pIn.id)
        graph.addEdge(e1)
        graph.addEdge(e2)

        graph.removeNode(id: b.id)

        #expect(graph.nodes.count == 2)
        #expect(graph.node(id: b.id) == nil)
        #expect(graph.edges.isEmpty, "删除节点应同时删除其关联边")
    }

    // MARK: - 边增删

    @Test func addAndRemoveEdge() {
        var graph = NodeGraph()
        let a = makeNode(title: "A")
        let b = makeNode(title: "B")
        graph.addNode(a)
        graph.addNode(b)

        let pOut = Port(name: "out", direction: .output, dataType: "text")
        let pIn = Port(name: "in", direction: .input, dataType: "text")
        let edge = Edge(fromNode: a.id, fromPort: pOut.id, toNode: b.id, toPort: pIn.id)
        graph.addEdge(edge)
        #expect(graph.edges.count == 1)
        #expect(graph.edge(id: edge.id) != nil)

        graph.removeEdge(id: edge.id)
        #expect(graph.edges.isEmpty)
        #expect(graph.edge(id: edge.id) == nil)
    }

    // MARK: - 查询方法

    @Test func neighborsAndPredecessorsSuccessors() {
        var graph = NodeGraph()
        let a = makeNode(title: "A")
        let b = makeNode(title: "B")
        let c = makeNode(title: "C")
        [a, b, c].forEach { graph.addNode($0) }

        let pOut = Port(name: "out", direction: .output, dataType: "text")
        let pIn = Port(name: "in", direction: .input, dataType: "text")
        graph.addEdge(Edge(fromNode: a.id, fromPort: pOut.id, toNode: b.id, toPort: pIn.id))
        graph.addEdge(Edge(fromNode: b.id, fromPort: pOut.id, toNode: c.id, toPort: pIn.id))

        let neighborsOfB = Set(graph.neighbors(of: b.id).map(\.id))
        let expectedNeighbors = Set([a.id, c.id])
        #expect(neighborsOfB == expectedNeighbors, "B 的邻居应为 A 和 C")

        let predOfC = graph.predecessors(of: c.id).map(\.id)
        #expect(predOfC == [b.id], "C 的前驱应为 B")

        let succOfA = graph.successors(of: a.id).map(\.id)
        #expect(succOfA == [b.id], "A 的后继应为 B")
    }

    @Test func incomingAndOutgoingEdges() {
        var graph = NodeGraph()
        let a = makeNode(title: "A")
        let b = makeNode(title: "B")
        let c = makeNode(title: "C")
        [a, b, c].forEach { graph.addNode($0) }

        let pOut = Port(name: "out", direction: .output, dataType: "text")
        let pIn = Port(name: "in", direction: .input, dataType: "text")
        graph.addEdge(Edge(fromNode: a.id, fromPort: pOut.id, toNode: b.id, toPort: pIn.id))
        graph.addEdge(Edge(fromNode: b.id, fromPort: pOut.id, toNode: c.id, toPort: pIn.id))
        graph.addEdge(Edge(fromNode: a.id, fromPort: pOut.id, toNode: c.id, toPort: pIn.id))

        #expect(graph.outgoingEdges(from: a.id).count == 2)
        #expect(graph.incomingEdges(to: b.id).count == 1)
        #expect(graph.incomingEdges(to: c.id).count == 2)
        #expect(graph.outgoingEdges(from: c.id).isEmpty)
    }

    @Test func edgesBetweenTwoNodes() {
        var graph = NodeGraph()
        let a = makeNode(title: "A")
        let b = makeNode(title: "B")
        let c = makeNode(title: "C")
        [a, b, c].forEach { graph.addNode($0) }

        let pOut = Port(name: "out", direction: .output, dataType: "text")
        let pIn = Port(name: "in", direction: .input, dataType: "text")
        let ab = Edge(fromNode: a.id, fromPort: pOut.id, toNode: b.id, toPort: pIn.id)
        let ba = Edge(fromNode: b.id, fromPort: pOut.id, toNode: a.id, toPort: pIn.id)
        let bc = Edge(fromNode: b.id, fromPort: pOut.id, toNode: c.id, toPort: pIn.id)
        graph.addEdge(ab)
        graph.addEdge(ba)
        graph.addEdge(bc)

        let betweenAB = graph.edges(from: a.id, to: b.id)
        let betweenABIDs = Set(betweenAB.map(\.id))
        let expectedABIDs = Set([ab.id, ba.id])
        #expect(betweenABIDs == expectedABIDs, "应返回 A↔B 双向所有边")
    }

    @Test func nodeGraphEquality() {
        var g1 = NodeGraph()
        var g2 = NodeGraph()
        let a = makeNode(title: "A")
        g1.addNode(a)
        g2.addNode(a)
        #expect(g1 == g2)

        let b = makeNode(title: "B")
        g2.addNode(b)
        #expect(g1 != g2, "节点不同则图不应相等")
    }
}
