import Foundation
import Testing
import CanvasCore
import MinisCore
@testable import MinisCanvasApp

/// D-CANVAS-24: run the event/error/node-state storm against a real BridgeStore
/// and compare the four ordinary Chat consumer surfaces with their live values.
/// The Canvas feature lane is explicitly phase4OptIn, while the legacy command
/// projection gate remains closed; this exercises the callback wiring without
/// turning Canvas notices into Chat transcript rows.
@Suite("D-CANVAS-24 runtime event storm", .serialized)
@MainActor
struct DCanvas24RuntimeEventStormTests {
    private struct ChatStatusSnapshot: Equatable {
        let usedTokens: Int
        let requestCount: Int
        let usageFraction: Double
        let isOverLimit: Bool
        let providerLabel: String
        let isMockMode: Bool
    }

    private struct ConsumerSnapshot: Equatable {
        let messages: [ChatMessageUI]
        let statusBar: ChatStatusSnapshot
        let taskCenter: TaskCenterObservationSnapshot
        let goalProjection: GoalTaskCenterProjection
        let composerDraft: String
        let composerStreaming: Bool
        let composerAttachmentCount: Int
    }

    private func snapshot(_ bridge: BridgeStore) -> ConsumerSnapshot {
        ConsumerSnapshot(
            messages: bridge.chat.messages,
            statusBar: ChatStatusSnapshot(
                usedTokens: bridge.chat.budgetUsedTokens,
                requestCount: bridge.chat.budgetRequestCount,
                usageFraction: bridge.chat.budgetUsageFraction,
                isOverLimit: bridge.chat.budgetIsOverLimit,
                providerLabel: bridge.chat.providerLabel,
                isMockMode: bridge.chat.isMockMode
            ),
            taskCenter: bridge.taskCenterObservation,
            goalProjection: bridge.taskCenterGoalProjection(
                now: Date(timeIntervalSince1970: 0)
            ),
            composerDraft: bridge.chat.draftText,
            composerStreaming: bridge.chat.isStreaming,
            composerAttachmentCount: bridge.chat.pendingAttachments.count
        )
    }

    private func assertNoProjection(
        _ bridge: BridgeStore,
        baseline: ConsumerSnapshot,
        method: StaticString = #function
    ) {
        let actual = snapshot(bridge)
        let label = String(describing: method)
        #expect(actual.messages == baseline.messages, "\(label): chat.messages changed")
        #expect(actual.statusBar == baseline.statusBar, "\(label): Chat status bar changed")
        #expect(actual.taskCenter == baseline.taskCenter, "\(label): TaskCenter changed")
        #expect(actual.goalProjection == baseline.goalProjection, "\(label): TaskCenter goal projection changed")
        #expect(actual.composerDraft == baseline.composerDraft, "\(label): Composer draft changed")
        #expect(actual.composerStreaming == baseline.composerStreaming, "\(label): Composer streaming changed")
        #expect(actual.composerAttachmentCount == baseline.composerAttachmentCount,
                "\(label): Composer attachments changed")
    }

    private func waitForIdle(_ canvas: CanvasStore, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while canvas.isRunning && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func cyclicGraph() -> NodeGraph {
        let aInput = Port(name: "in", direction: .input, dataType: "string")
        let aOutput = Port(name: "out", direction: .output, dataType: "string")
        let bInput = Port(name: "in", direction: .input, dataType: "string")
        let bOutput = Port(name: "out", direction: .output, dataType: "string")
        let a = CanvasNode(
            type: "synthetic-cycle", title: "Synthetic Cycle A",
            inputs: [aInput], outputs: [aOutput]
        )
        let b = CanvasNode(
            type: "synthetic-cycle", title: "Synthetic Cycle B",
            inputs: [bInput], outputs: [bOutput]
        )
        return NodeGraph(
            nodes: [a, b],
            edges: [
                Edge(fromNode: a.id, fromPort: aOutput.id, toNode: b.id, toPort: bInput.id),
                Edge(fromNode: b.id, fromPort: bOutput.id, toNode: a.id, toPort: aInput.id),
            ]
        )
    }

    @Test("real nine-event storm plus failed node and run error keeps Chat consumers unchanged")
    func realEventStormHasZeroOrdinaryChatProjection() async throws {
        TestEnvIsolation.hermeticize()
        let envKeys = [
            FormalTestIsolationPaths.profileMarkerKey,
            FormalTestIsolationPaths.profileDirectoryKey,
            FormalTestIsolationPaths.profileIdentityKey,
            FormalTestIsolationPaths.runIDKey,
            FormalTestIsolationPaths.packageKey,
            FormalTestIsolationPaths.scratchDirectoryKey,
            FormalTestIsolationPaths.rootDeviceKey,
            FormalTestIsolationPaths.rootInodeKey,
            FormalTestIsolationPaths.rootOwnerKey,
        ]
        let envValues = envKeys.map { key in
            "\(key)=\(ProcessInfo.processInfo.environment[key] ?? "<missing>")"
        }
        print("D-CANVAS-24.formalEnv=" + envValues.joined(separator: ","))
        let bridge = BridgeStore(canvasFeatureLane: .phase4OptIn)
        bridge.chat.draftText = "synthetic composer sentinel D-CANVAS-24"
        let baseline = snapshot(bridge)

        print("D-CANVAS-24.eventStorm.started")

        print("D-CANVAS-24.nodeAdded.started")
        let text = try #require(bridge.canvas.addNode(ofType: "text"))
        #expect(bridge.canvas.graph.nodes.contains { $0.id == text.id })
        assertNoProjection(bridge, baseline: baseline, method: "nodeAdded")
        print("D-CANVAS-24.nodeAdded.passed")

        print("D-CANVAS-24.edgeAdded.started")
        let image = try #require(bridge.canvas.addNode(ofType: "imageGen"))
        #expect(bridge.canvas.connectNodes(fromID: text.id, toID: image.id))
        #expect(bridge.canvas.graph.edges.count == 1)
        assertNoProjection(bridge, baseline: baseline, method: "edgeAdded")
        print("D-CANVAS-24.edgeAdded.passed")

        print("D-CANVAS-24.nodeSelected.started")
        bridge.canvas.selectNode(id: text.id)
        #expect(bridge.selectedNodeContext?.title == text.title)
        assertNoProjection(bridge, baseline: baseline, method: "nodeSelected")
        print("D-CANVAS-24.nodeSelected.passed")

        print("D-CANVAS-24.selectionCleared.started")
        bridge.canvas.deselectAll()
        #expect(bridge.selectedNodeContext == nil)
        assertNoProjection(bridge, baseline: baseline, method: "selectionCleared")
        print("D-CANVAS-24.selectionCleared.passed")

        print("D-CANVAS-24.layoutDone.started")
        bridge.canvas.autoLayout()
        #expect(bridge.canvas.statusMessage == "自动布局完成")
        assertNoProjection(bridge, baseline: baseline, method: "layoutDone")
        print("D-CANVAS-24.layoutDone.passed")

        print("D-CANVAS-24.nodeRemoved.started")
        bridge.canvas.removeNode(id: image.id)
        #expect(bridge.canvas.graph.node(id: image.id) == nil)
        assertNoProjection(bridge, baseline: baseline, method: "nodeRemoved")
        print("D-CANVAS-24.nodeRemoved.passed")

        print("D-CANVAS-24.runStarted.started")
        let failedNode = CanvasNode(type: "synthetic-unknown", title: "Synthetic Unknown")
        bridge.canvas.graph = NodeGraph(nodes: [failedNode])
        bridge.canvas.runGraph()
        #expect(bridge.canvas.isRunning, "runStarted must be observable before completion")
        print("D-CANVAS-24.runStarted.passed")

        print("D-CANVAS-24.nodeStatusChanged.failed.started")
        await waitForIdle(bridge.canvas)
        #expect(bridge.canvas.graph.node(id: failedNode.id)?.status == .failed)
        assertNoProjection(bridge, baseline: baseline, method: "nodeStatusChanged.failed")
        print("D-CANVAS-24.nodeStatusChanged.failed.passed")

        print("D-CANVAS-24.runFinished.error.started")
        bridge.canvas.graph = cyclicGraph()
        bridge.canvas.runGraph()
        #expect(bridge.canvas.isRunning, "cycle probe must emit runStarted")
        await waitForIdle(bridge.canvas)
        #expect(!bridge.canvas.isRunning)
        #expect(bridge.canvas.statusMessage?.hasPrefix("执行失败：") == true,
                "cycle probe must produce the real runFinished(error) path")
        assertNoProjection(bridge, baseline: baseline, method: "runFinished.error")
        print("D-CANVAS-24.runFinished.error.passed")

        let final = snapshot(bridge)
        #expect(final == baseline)
        print("D-CANVAS-24.eventStorm.passed")
    }
}
