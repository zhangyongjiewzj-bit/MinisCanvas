import Testing
import Foundation
import CanvasCore
@testable import MinisCanvasApp

// MARK: - B1 审核节点三态持久化 + UI 状态映射
//
// 覆盖 4 项：
// 1. setReviewStatus 写入 backendConfig.params["review.status"] 正确值（PASS/REJECT）
// 2. 无节点返回 false
// 3. undo 可回退（setReviewStatus 前压入快照）
// 4. UI 状态映射纯函数：三态 → 文案/颜色（fromParams / label / hexColor）
//
// 注：测试显式构造节点端口（不依赖 NodeTypeRegistry 规格，避免与其他任务
// 并行改动该规格冲突），据此验证 setReviewStatus/reviewStatus 的纯行为。

@Suite("B1 审核节点三态持久化与 UI 映射")
@MainActor
struct B1ReviewStatusTests {

    /// 构造 reviewGate 节点（text 输入 + pass/status 输出，对齐 ManjuNodeType.reviewGateInputPorts/OutputPorts）
    /// 并直接加入 store 图（不经 addNode(ofType:)，避免依赖注册表规格）。
    private func makeReviewGateNode(in store: CanvasStore) -> CanvasNode {
        let node = CanvasNode(
            type: ManjuNodeType.reviewGate.rawValue, title: "审核",
            inputs: [Port(name: "text", direction: .input, dataType: "string")],
            outputs: [
                Port(name: "pass", direction: .output, dataType: "string"),
                Port(name: "status", direction: .output, dataType: "string"),
            ]
        )
        store.graph.addNode(node)
        return node
    }

    // MARK: - 1) setReviewStatus 写入 params["review.status"] 正确值

    @Test func setReviewStatusWritesPass() {
        let store = CanvasStore()
        let node = makeReviewGateNode(in: store)
        #expect(store.setReviewStatus(nodeID: node.id, pass: true))
        let params = store.graph.node(id: node.id)?.backendConfig?.params
        #expect(params?[CanvasStore.reviewStatusKey] == "PASS",
                "放行 → params[review.status] 应为大写 PASS")
        #expect(store.reviewStatus(of: node.id) == .pass)
        #expect(store.statusMessage == "已放行")
    }

    @Test func setReviewStatusWritesReject() {
        let store = CanvasStore()
        let node = makeReviewGateNode(in: store)
        #expect(store.setReviewStatus(nodeID: node.id, pass: false))
        let params = store.graph.node(id: node.id)?.backendConfig?.params
        #expect(params?[CanvasStore.reviewStatusKey] == "REJECT",
                "打回 → params[review.status] 应为大写 REJECT")
        #expect(store.reviewStatus(of: node.id) == .reject)
        #expect(store.statusMessage == "已打回")
    }

    @Test func setReviewStatusTogglesBetweenStates() {
        let store = CanvasStore()
        let node = makeReviewGateNode(in: store)
        _ = store.setReviewStatus(nodeID: node.id, pass: true)
        #expect(store.graph.node(id: node.id)?.backendConfig?.params[CanvasStore.reviewStatusKey] == "PASS")
        _ = store.setReviewStatus(nodeID: node.id, pass: false)
        #expect(store.graph.node(id: node.id)?.backendConfig?.params[CanvasStore.reviewStatusKey] == "REJECT",
                "反复放行/打回应互相覆盖")
        _ = store.setReviewStatus(nodeID: node.id, pass: true)
        #expect(store.graph.node(id: node.id)?.backendConfig?.params[CanvasStore.reviewStatusKey] == "PASS")
    }

    @Test func setReviewStatusCreatesBackendConfigIfMissing() {
        let store = CanvasStore()
        let node = makeReviewGateNode(in: store)
        #expect(store.graph.node(id: node.id)?.backendConfig == nil, "前置：节点无 backendConfig")
        _ = store.setReviewStatus(nodeID: node.id, pass: true)
        #expect(store.graph.node(id: node.id)?.backendConfig?.params[CanvasStore.reviewStatusKey] == "PASS",
                "无 backendConfig 时自动创建并写入")
    }

    // MARK: - 2) 无节点返回 false

    @Test func setReviewStatusUnknownNodeReturnsFalse() {
        let store = CanvasStore()
        #expect(!store.setReviewStatus(nodeID: UUID(), pass: true))
        #expect(!store.setReviewStatus(nodeID: UUID(), pass: false))
        #expect(store.statusMessage != "已放行" && store.statusMessage != "已打回",
                "无节点时不应写入状态消息")
    }

    // MARK: - 3) undo 可回退

    @Test func setReviewStatusIsUndoable() {
        let store = CanvasStore()
        let node = makeReviewGateNode(in: store)
        _ = store.setReviewStatus(nodeID: node.id, pass: true)
        #expect(store.graph.node(id: node.id)?.backendConfig?.params[CanvasStore.reviewStatusKey] == "PASS")
        #expect(store.undo(), "放行后应可撤销")
        #expect(store.graph.node(id: node.id)?.backendConfig?.params[CanvasStore.reviewStatusKey] == nil,
                "undo 回退到放行前（无 review.status）")
        #expect(store.graph.node(id: node.id) != nil, "undo 只回滚审核状态，节点本身保留")
    }

    @Test func setReviewStatusRejectUndoRestoresPending() {
        let store = CanvasStore()
        let node = makeReviewGateNode(in: store)
        _ = store.setReviewStatus(nodeID: node.id, pass: false)
        #expect(store.graph.node(id: node.id)?.backendConfig?.params[CanvasStore.reviewStatusKey] == "REJECT")
        _ = store.undo()
        #expect(store.reviewStatus(of: node.id) == .pending, "打回撤销后回到待审")
    }

    // MARK: - 4) UI 状态映射纯函数（三态 → 文案/颜色）

    @Test func reviewStatusFromParamsMapping() {
        #expect(ReviewStatus.fromParams(["review.status": "PASS"]) == .pass)
        #expect(ReviewStatus.fromParams(["review.status": "REJECT"]) == .reject)
        #expect(ReviewStatus.fromParams(["review.status": "PENDING"]) == .pending)
        #expect(ReviewStatus.fromParams(nil) == .pending, "未设置 → 待审")
        #expect(ReviewStatus.fromParams([:]) == .pending, "空 params → 待审")
        #expect(ReviewStatus.fromParams(["review.status": "UNKNOWN"]) == .pending, "未知值 → 待审")
        #expect(ReviewStatus.fromParams(["review.status": "pass"]) == .pending, "值必须大写")
        #expect(ReviewStatus.fromParams(["content": "x"]) == .pending, "无关键不影响三态")
    }

    @Test func reviewStatusLabels() {
        #expect(ReviewStatus.pass.label == "通过")
        #expect(ReviewStatus.reject.label == "打回")
        #expect(ReviewStatus.pending.label == "待审")
        #expect(ReviewStatus.pass.rawValue == "PASS")
        #expect(ReviewStatus.reject.rawValue == "REJECT")
        #expect(ReviewStatus.pending.rawValue == "PENDING")
    }

    @Test func reviewStatusThreeStateColors() {
        // 契约：PASS 青 / REJECT 红 / PENDING 黄（三态互不相同）
        #expect(ReviewStatus.pass.hexColor == "#78BFC8")
        #expect(ReviewStatus.reject.hexColor == "#E06060")
        #expect(ReviewStatus.pending.hexColor == "#E0B94D")
        #expect(ReviewStatus.pass.hexColor != ReviewStatus.reject.hexColor)
        #expect(ReviewStatus.reject.hexColor != ReviewStatus.pending.hexColor)
        #expect(ReviewStatus.pass.hexColor != ReviewStatus.pending.hexColor)
    }

    @Test func reviewStatusStoreReaderDefaultsToPending() {
        let store = CanvasStore()
        #expect(store.reviewStatus(of: UUID()) == .pending, "未知节点 → 待审")
        let node = makeReviewGateNode(in: store)
        #expect(store.reviewStatus(of: node.id) == .pending, "未设置 → 待审")
        _ = store.setReviewStatus(nodeID: node.id, pass: false)
        #expect(store.reviewStatus(of: node.id) == .reject)
    }
}
