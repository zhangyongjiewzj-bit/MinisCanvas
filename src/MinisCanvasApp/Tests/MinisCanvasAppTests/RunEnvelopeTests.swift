import Foundation
import Testing
import CanvasCore
@testable import MinisCanvasApp

// MARK: - P0-1 RunEnvelope（runID + graphRevision 写回前校验）
//
// 用户级 P0：原 runGraph 只快照图跑调度，写回（finishRun）不校验版本——
// 用户中途加了/删了节点、改连线/内容/模型配置后，旧运行结果会覆盖当前画布。
// 修复：①运行开始时记录 RunEnvelope(runID, graphRevision)；
//       ②finishRun 写回前校验当前图版本 vs 信封版本，不一致→不覆盖并提示可能过期。

@Suite("P0-1 RunEnvelope 写回前校验", .serialized)
@MainActor
struct RunEnvelopeTests {

    /// T1 测试隔离：无 key → LLM 走引导输出，离线快速且确定
    init() {
        TestEnvIsolation.hermeticize()
    }

    private func makeChain(count: Int) throws -> CanvasStore {
        let store = CanvasStore()
        let first = try #require(store.addNode(ofType: "text"))
        var previous = first
        for _ in 1..<count {
            let next = try #require(store.addNode(ofType: "llm"))
            #expect(store.connectNodes(fromID: previous.id, toID: next.id))
            previous = next
        }
        return store
    }

    /// 执行状态写回（增量 status 变更）不应改变结构版本——否则正常执行会被误判为「画布已改」。
    @Test func structuralRevisionStableAcrossStatusWrites() throws {
        let store = try makeChain(count: 3)
        let rev0 = store.graph.structuralRevision
        if let index = store.graph.nodes.firstIndex(where: { $0.status != .succeeded }) {
            store.graph.nodes[index].status = .succeeded
        }
        #expect(store.graph.structuralRevision == rev0,
                "执行状态写回不应改变结构版本（否则正常执行误判过期）")
    }

    /// 结构变更（移动节点 / 加节点）→ 版本变化。
    @Test func structuralRevisionChangesWhenStructureChanges() throws {
        let store = try makeChain(count: 2)
        let rev0 = store.graph.structuralRevision

        // 移动节点 → 版本变化
        var moved = store.graph
        moved.nodes[0].position.x += 10
        #expect(moved.structuralRevision != rev0, "移动节点应改变结构版本")

        // 加节点 → 版本变化
        let store3 = try makeChain(count: 3)
        #expect(store3.graph.structuralRevision != rev0, "加节点应改变结构版本")
    }

    /// 内容变更（用户中途改节点内容）→ 版本变化（内容在 backendConfig.params["content"]）。
    @Test func structuralRevisionChangesWhenContentChanges() throws {
        let store = try makeChain(count: 2)
        let rev0 = store.graph.structuralRevision
        var edited = store.graph
        if let index = edited.nodes.firstIndex(where: { $0.type == "llm" }) {
            var config = edited.nodes[index].backendConfig ?? NodeBackendConfig()
            config.params["content"] = "用户中途改的内容"
            edited.nodes[index].backendConfig = config
        }
        #expect(edited.structuralRevision != rev0, "改节点内容应改变结构版本")
    }

    /// 过期信封（当前图版本 ≠ 信封版本）→ 写回被拦截：图不变、无 lastResult、提示过期。
    @Test func staleEnvelopeBlocksWriteback() throws {
        let store = try makeChain(count: 2)
        store.isRunning = true
        store.injectRunEnvelopeForTest(
            RunEnvelope(runID: UUID(), graphRevision: store.graph.structuralRevision + 1)
        )
        let before = store.graph
        let result = DAGExecutionResult(
            statuses: Dictionary(uniqueKeysWithValues: store.graph.nodes.map { ($0.id, NodeStatus.succeeded) }),
            outputs: [:], wasCancelled: false, skipReasons: [:]
        )
        store.finishRun(result, before: [:])

        #expect(store.graph == before, "过期结果不应覆盖画布")
        #expect(store.lastResult == nil, "过期结果不应写入 lastResult")
        #expect(store.isRunning == false, "写回拦截后应复位 running")
        #expect(store.currentRunEnvelope == nil, "写回拦截后应清空信封")
        let msg = store.statusMessage ?? ""
        #expect(msg.contains("已修改") || msg.contains("过期"),
                "应提示结果可能过期，实际：\(msg)")
    }

    /// 有效信封（当前图版本 == 信封版本）→ 正常写回。
    @Test func freshEnvelopeAllowsWriteback() throws {
        let store = try makeChain(count: 2)
        store.isRunning = true
        store.injectRunEnvelopeForTest(
            RunEnvelope(runID: UUID(), graphRevision: store.graph.structuralRevision)
        )
        let result = DAGExecutionResult(
            statuses: Dictionary(uniqueKeysWithValues: store.graph.nodes.map { ($0.id, NodeStatus.succeeded) }),
            outputs: [:], wasCancelled: false, skipReasons: [:]
        )
        store.finishRun(result, before: [:])

        #expect(store.graph.nodes.allSatisfy { $0.status == .succeeded }, "有效结果应正常写回")
        #expect(store.lastResult != nil, "有效结果应写入 lastResult")
        #expect(store.isRunning == false)
        #expect(store.currentRunEnvelope == nil, "写回后应清空信封")
    }

    /// 视频资产查询在 finishRun 后通过 actor 异步回主线程；完成后用户立刻
    /// 编辑节点时，迟到的 asset.id 不能绑定到已改变的图。
    @Test func lateVideoAssetProjectionAfterGraphEditIsRejected() async throws {
        let node = CanvasNode(type: ManjuNodeType.videoGen.rawValue, title: "视频")
        let store = CanvasStore(graph: NodeGraph(nodes: [node]))
        let artifactID = "artifact-late-writeback"
        let asset = MediaAsset(
            kind: .video,
            source: .generated,
            localURL: "/tmp/late-writeback.mp4",
            sourceCanvasID: store.currentCanvasID,
            sourceNodeID: node.id,
            metadata: ["artifactID": artifactID]
        )
        #expect(await store.assetStore.register(asset, canvasID: store.currentCanvasID))

        let runID = UUID()
        store.isRunning = true
        store.injectRunEnvelopeForTest(
            RunEnvelope(
                runID: runID,
                canvasID: store.currentCanvasID,
                graphRevision: store.graph.structuralRevision
            )
        )
        let result = DAGExecutionResult(
            statuses: [node.id: .succeeded],
            outputs: [
                node.id: [
                    "status": "succeeded",
                    "video": "/tmp/late-writeback.mp4",
                    "artifactID": artifactID
                ]
            ]
        )

        store.finishRun(result, before: [:])

        var editedConfig = store.graph.nodes[0].backendConfig ?? NodeBackendConfig()
        editedConfig.params["content"] = "用户在完成后立即编辑"
        store.updateBackendConfig(editedConfig, for: node.id)
        try await Task.sleep(for: .milliseconds(50))

        #expect(store.graph.nodes[0].backendConfig?.params[CanvasStore.assetIDKey] == nil)
        #expect(store.graph.nodes[0].backendConfig?.params["artifact.id"] == nil)
    }

    @Test func videoAssetProjectionBindsWhenGraphRemainsCurrent() async throws {
        let node = CanvasNode(type: ManjuNodeType.videoGen.rawValue, title: "视频")
        let store = CanvasStore(graph: NodeGraph(nodes: [node]))
        let artifactID = "artifact-current-writeback"
        let asset = MediaAsset(
            kind: .video,
            source: .generated,
            localURL: "/tmp/current-writeback.mp4",
            sourceCanvasID: store.currentCanvasID,
            sourceNodeID: node.id,
            metadata: ["artifactID": artifactID]
        )
        #expect(await store.assetStore.register(asset, canvasID: store.currentCanvasID))

        store.isRunning = true
        store.injectRunEnvelopeForTest(
            RunEnvelope(
                runID: UUID(),
                canvasID: store.currentCanvasID,
                graphRevision: store.graph.structuralRevision
            )
        )
        store.finishRun(
            DAGExecutionResult(
                statuses: [node.id: .succeeded],
                outputs: [
                    node.id: [
                        "status": "succeeded",
                        "video": "/tmp/current-writeback.mp4",
                        "artifactID": artifactID
                    ]
                ]
            ),
            before: [:]
        )
        try await Task.sleep(for: .milliseconds(50))

        #expect(store.graph.nodes[0].backendConfig?.params[CanvasStore.assetIDKey] == asset.id.uuidString)
        #expect(store.graph.nodes[0].backendConfig?.params["artifact.id"] == artifactID)
    }

    /// 增量事件会先把节点状态写回当前图；L7 envelope fingerprint 仍代表
    /// 运行开始时的图，因此 finishRun 必须用 before 恢复出的 actualGraph
    /// 做受保护写回，而不能把带执行态的当前图直接拿去比较。
    @Test func incrementalStatusWritebackStillAllowsFinishWriteback() throws {
        let store = try makeChain(count: 2)
        let frozenGraph = store.graph
        let runID = UUID()
        let executionEnvelope = DAGExecutionEnvelope(
            canvasID: store.currentCanvasID,
            runID: runID,
            graph: frozenGraph
        )
        store.isRunning = true
        store.injectRunEnvelopeForTest(
            RunEnvelope(
                runID: runID,
                canvasID: store.currentCanvasID,
                graphRevision: frozenGraph.structuralRevision,
                executionEnvelope: executionEnvelope
            )
        )

        // 模拟 runGraph 期间已经收到 nodeSucceeded/nodeCached 事件。
        for index in store.graph.nodes.indices {
            store.graph.nodes[index].status = .succeeded
        }
        let before = Dictionary(uniqueKeysWithValues: frozenGraph.nodes.map { ($0.id, $0.status) })
        let result = DAGExecutionResult(
            statuses: Dictionary(uniqueKeysWithValues: frozenGraph.nodes.map { ($0.id, .succeeded) }),
            outputs: [:],
            wasCancelled: false,
            skipReasons: [:],
            executionEnvelope: executionEnvelope
        )

        store.finishRun(result, before: before)

        #expect(store.graph.nodes.allSatisfy { $0.status == .succeeded },
                "增量状态已写回时，finishRun 仍应通过 actualGraph fingerprint 校验")
        #expect(store.lastResult != nil, "有效的完成结果应写入 lastResult")
        #expect(store.statusMessage?.contains("执行结果信封不匹配") == false,
                "正常完成不应报告信封不匹配")
    }

    /// L7 DAGExecutionEnvelope 不能被 App consumer 忽略：即使旧的本地
    /// RunEnvelope 画布身份和 revision 都匹配，结果 envelope 指向另一画布
    /// 也必须在触碰图状态前拒绝。
    @Test func staleDAGExecutionEnvelopeBlocksWriteback() throws {
        let store = try makeChain(count: 2)
        let runID = UUID()
        store.isRunning = true
        store.injectRunEnvelopeForTest(
            RunEnvelope(
                runID: runID,
                canvasID: store.currentCanvasID,
                graphRevision: store.graph.structuralRevision
            )
        )
        let result = DAGExecutionResult(
            statuses: Dictionary(uniqueKeysWithValues: store.graph.nodes.map { ($0.id, NodeStatus.succeeded) }),
            outputs: [:],
            wasCancelled: false,
            skipReasons: [:],
            executionEnvelope: DAGExecutionEnvelope(
                canvasID: UUID(),
                runID: runID,
                graph: store.graph
            )
        )

        store.finishRun(result, before: [:])

        #expect(store.graph.nodes.allSatisfy { $0.status == .pending },
                "DAG envelope 画布不匹配时不得写回节点状态")
        #expect(store.lastResult == nil, "DAG envelope 画布不匹配时不得写入结果")
        #expect(store.statusMessage?.contains("执行") == true)
    }

    /// 集成：runGraph 运行开始时记录信封，且信封版本与当前图一致。
    @Test func runGraphRecordsEnvelopeAtStart() async throws {
        let store = try makeChain(count: 2)
        store.runGraph()
        let envelope = store.currentRunEnvelope
        #expect(envelope != nil, "runGraph 应记录运行信封")
        if let envelope {
            #expect(envelope.isGraphCurrent(store.graph.structuralRevision),
                    "信封版本应等于运行开始时的图版本")
            #expect(envelope.executionEnvelope != nil,
                    "生产 runGraph 应保存 L7 DAGExecutionEnvelope")
        }
        // 等待后台执行结束，避免测试退出时仍有任务在跑
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline && store.isRunning {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(!store.isRunning)
        #expect(store.currentRunEnvelope == nil, "执行结束后信封应清空")
    }
}
