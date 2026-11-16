import Foundation
import MinisCore

// MARK: - P3-OUTPUT-01 · 244B「台账→卡片」投影适配器（生产者接线，DEV-315）
//
// 差额来源（GOV/OUTPUT01-SESSKEY-REPROBE §1 diffID 行附带观察，头 de7b1fa2c）：
// `Sources` 内无任何把生产台账（BridgeStore.productionFileChangeLedger）
// 的只读查询结果投影为卡片四字段（AgentOutputCardModel.swift 的
// `AgentOutputDiffReference{diffID, changedFileCount, insertions, deletions}`）
// 的适配器调用点；查询 API（FileChangeLedger.swift record/diffPayload/
// records/diffReference）的运行时消费方此前仅测试文件。
// MinisCore 侧注释（FileChangeLedger.swift:8-11）与 App 组合根注释
// （BridgeStore.swift:1539-1541）均自证「App 侧适配器（下一条线）」尚未落地。
//
// 本文件即该下一条线的最小落地：一个纯投影适配器，把台账查询结果转换为
// 卡片侧四字段并组装 `AgentOutputCardProjectionRequest.diffLedger` 入参。
// 范围合同：
// - 只消费 FileChangeLedger 既有查询 API，不改 MinisCore、不新增语义、
//   不动登记/淘汰/会话隔离边界；
// - 不触碰会话键：sessionID 由调用方（组合根/UI 接线线）透传，本线不派生、
//   不刷新、不复现任何会话键语义（该差额已由 DEV-311 单作者闭合）；
// - 不做 SwiftUI/ChatStore/ContentView 消费接线（244B 头注释明言归后续
//   OUTPUT-01 接线线）；本线补的是「台账→卡片四字段」这一段生产者接线；
// - 无 IO、无网络、不读写全局可变状态。
//
// fail-closed 契约（与台账查询语义、244B resolver 对齐，不新造第三套）：
// - ledger 为 nil（生产未装配）或 sessionID 为空串（生产者侧空=未接线，
//   同 ToolExecutor 空串 guard 形）⇒ 不发起查询，对应 diffID 不入 map；
// - 台账无该 diffID / 跨会话 ⇒ `diffReference(for:sessionID:)` 返回 nil ⇒
//   对应 diffID 不入 map ⇒ 卡片侧 `AgentOutputDiffResolver` 依既有语义
//   判 `.failure(.missing)`。适配器自身从不伪造零值引用。

/// App 侧「逐文件变更台账 → 244B 卡片 Diff 引用」纯投影适配器。
enum AgentOutputLedgerCardAdapter {
    /// The Inspector's existing artifact projection. Exact successful receipt
    /// evidence remains authoritative; a diff or matching session alone is not
    /// an artifact. Extraction keeps the UI and consumer regressions on one path.
    static func fileArtifacts(
        sessionID: String?,
        ledger: FileChangeLedger?,
        facts: [ToolExecutionFact],
        limit: Int
    ) -> [ProducedFileArtifactEvidence] {
        guard let sessionID, !sessionID.isEmpty, let ledger, limit > 0 else { return [] }
        let factsByReceipt = Dictionary(grouping: facts, by: \.receiptID)
        var newest: [ProducedFileArtifactEvidence] = []
        for record in ledger.records(sessionID: sessionID).reversed() {
            guard let receiptID = record.producerReceiptID,
                  let fact = factsByReceipt[receiptID]?.first(where: {
                      $0.compositeKey == record.producerCompositeKey
                  }),
                  let evidence = ledger.artifactEvidence(
                      diffID: record.diffID, sessionID: sessionID, fact: fact
                  ) else { continue }
            newest.append(evidence)
            if newest.count == limit { break }
        }
        return Array(newest.reversed())
    }

    /// 单视图转换：MinisCore 投影载体 → App 卡片四字段；nil ⇒ nil（由消费端判 missing）。
    static func diffReference(from view: FileChangeDiffReferenceView?) -> AgentOutputDiffReference? {
        guard let view else { return nil }
        return AgentOutputDiffReference(
            diffID: view.diffID,
            changedFileCount: view.changedFileCount,
            insertions: view.insertions,
            deletions: view.deletions
        )
    }

    /// 按会话键查询单个 diffID 并转换为卡片四字段；未装配/空键/无命中 ⇒ nil。
    static func diffReference(
        diffID: String,
        sessionID: String,
        ledger: FileChangeLedger?
    ) -> AgentOutputDiffReference? {
        guard let ledger, !sessionID.isEmpty else { return nil }
        return diffReference(from: ledger.diffReference(for: diffID, sessionID: sessionID))
    }

    /// 批量组装 `AgentOutputCardProjectionRequest.diffLedger` 入参：
    /// 键为 diffID，只有命中条目入 map；未命中/空键/未装配一律缺席，
    /// 交由卡片侧 resolver 映射 `.missing`。
    static func diffLedger(
        diffIDs: [String],
        sessionID: String,
        ledger: FileChangeLedger?
    ) -> [String: AgentOutputDiffReference] {
        var projected: [String: AgentOutputDiffReference] = [:]
        guard let ledger, !sessionID.isEmpty else { return projected }
        for diffID in diffIDs {
            if let reference = diffReference(diffID: diffID, sessionID: sessionID, ledger: ledger) {
                projected[reference.diffID] = reference
            }
        }
        return projected
    }
}
