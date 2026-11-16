import Testing
import Foundation
import MinisCore
@testable import MinisCanvasApp

// MARK: - P3-MEM-01 剩余差额：supersede 链 JSON round-trip 覆盖（DEV-280）
//
// 由来：DEV-270 移除了自相矛盾的导入 fixture（active-supersedes-active 在产品侧
// 不可能合法产出：`MemoryStore.validatePersistedFacts` 对该形状 fail-closed，
// canonical append 路径把前驱降级为 `.superseded`，consumer 将校验失败映射为
// `.restoreConflict`）。该修正合法，但代价是 supersede 链的持久化/导出/导入
// round-trip 失去覆盖。本文件恢复这份覆盖，并正向钉住以下已测行为：
//   1. 合法链（前驱 `.superseded`、后继 `.active`、revision 相邻、scope 相同）
//      经 写盘→strict-load / 导出→导入 全环后逐字段存活，且能被
//      `validatePersistedFacts` 接受。
//   2. 全史可见（`facts()`/`loadFacts()` 含前驱），活动投影只含
//      `lifecycleState == .active`（SettingsCenter.reloadStorage 的
//      I2-MEMORY-PROJECTION 口径；代码字段名是 `lifecycleState`，
//      需求文案中的 `activityStatus` 字段在仓库中不存在——见交付报告 finding）。
//   3. `MemoryProposalConsumer` restore 去重按测量到的真实语义：仅按稳定 id
//      匹配、命中要求全 payload 相等（exact→skipped/整批回执幂等重放；
//      overlap→`.restoreConflict`；no-match→added）。仓库中不存在任何
//      “按 id 或 text” 的 text 匹配器（`hasMatchingFact` 这一名称与语义在
//      base `9c9bb2b1d` 全仓无对应实现）——本文件按测得行为断言，
//      该口径差异作为 finding 上报，不把任一侧包装成“正确”。
//   4. 空 proposal/事实文本 fail-closed（`.invalidText`）。
//   5. `activeFacts(within: MemoryScopeFilter)` 只返回 active 事实且按选择器
//      fail-closed 隔离。
//
// 全部使用临时目录注入，不触碰 Application Support 真实数据；id/文本均为合成假值。

@Suite("P3-MEM-01 supersede 链 round-trip")
@MainActor
struct MemorySupersedeChainRoundTripTests {

    private static let sessionA = "session-chain-0001"
    private static let sessionB = "session-chain-0002"
    private static let projectID = "project-chain"
    private static let ownerID = "local-owner-fake"
    private static let otherOwnerID = "local-owner-fake-2"

    private static let baseDate = Date(timeIntervalSince1970: 1_750_000_000)

    private func makeCenter(dir: URL, sessionID: String) -> SettingsCenter {
        let center = SettingsCenter(
            settingsStore: SettingsStore(directory: dir),
            envStore: EnvVarStore(directory: dir),
            memoryStore: MemoryStore(directory: dir),
            sessionStore: SessionStore(directory: dir),
            logManager: LogManager(directory: dir, ringCapacity: 50),
            mcpManager: MCPServerManager(fileURL: dir.appendingPathComponent("mcps.json")),
            skillStore: SkillStore(skillsRoot: dir.appendingPathComponent("skills", isDirectory: true))
        )
        center.memoryScopeProvider = {
            MemoryScope(sessionID: sessionID, projectID: Self.projectID)
        }
        return center
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemorySupersedeChain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func scope(_ sessionID: String) -> MemoryScope {
        MemoryScope(sessionID: sessionID, projectID: Self.projectID)
    }

    /// 通过 canonical 生产路径（addFact + appendRevision）构造一条合法 supersede 链，
    /// 返回 (前驱, 后继)。前驱必须经由 `appendRevision` 被降级为 `.superseded`，
    /// 不允许手工拼装。
    private func buildLegitChain(
        in store: MemoryStore,
        chainTag tag: String,
        memoryScope: MemoryScope,
        ownerUserID: String?
    ) throws -> (predecessor: MemoryFact, successor: MemoryFact) {
        let predecessorID = "chain-\(tag)-pre-0001"
        let successorID = "chain-\(tag)-succ-0002"
        let predecessorText = "supersede 链前驱文本（\(tag)）"
        let successorText = "supersede 链后继文本（\(tag)）"

        let predecessor = try store.addFact(
            id: predecessorID,
            text: predecessorText,
            sourceSessionID: "synthetic-origin-session",
            category: .lesson,
            createdAt: Self.baseDate,
            memoryScope: memoryScope,
            ownerUserID: ownerUserID,
            sourceProposalID: "proposal-\(tag)-pre",
            sourceRef: "memory-test://\(tag)/pre",
            contentDigest: MemoryStore.contentDigest(for: predecessorText),
            revision: 1,
            supersedesFactID: nil,
            lifecycleState: .active,
            activatedAt: Self.baseDate
        )
        let successor = try store.appendRevision(
            to: predecessor.id,
            id: successorID,
            text: successorText,
            sourceSessionID: "synthetic-origin-session",
            category: .lesson,
            memoryScope: memoryScope,
            ownerUserID: ownerUserID,
            sourceProposalID: "proposal-\(tag)-succ",
            sourceRef: "memory-test://\(tag)/succ",
            contentDigest: MemoryStore.contentDigest(for: successorText),
            createdAt: Self.baseDate.addingTimeInterval(600)
        )
        return (predecessor, successor)
    }

    private func factsByID(_ facts: [MemoryFact]) -> [String: MemoryFact] {
        Dictionary(uniqueKeysWithValues: facts.map { ($0.id, $0) })
    }

    // MARK: - 1. 写盘 → strict-load 全环

    @Test("合法 supersede 链经磁盘 strict-load 逐字段存活，全史可见且校验被真正执行")
    func legitChainSurvivesDiskStrictLoad() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MemoryStore(directory: dir)
        let chain = try buildLegitChain(
            in: store,
            chainTag: "disk",
            memoryScope: scope(Self.sessionA),
            ownerUserID: Self.ownerID
        )

        // appendRevision 即时状态：前驱降级、revision 相邻、scope 相同。
        let persisted = try store.facts()
        #expect(persisted.count == 2)
        let live = factsByID(persisted)
        #expect(live[chain.predecessor.id]?.lifecycleState == .superseded)
        #expect(live[chain.successor.id]?.lifecycleState == .active)
        #expect(live[chain.predecessor.id]?.revision == 1)
        #expect(live[chain.successor.id]?.revision == 2)
        #expect(live[chain.successor.id]?.supersedesFactID == chain.predecessor.id)
        #expect(live[chain.successor.id]?.memoryScope == live[chain.predecessor.id]?.memoryScope)

        // strict-load：同目录新建 store，loadFacts() 会走 decoder + validatePersistedFacts。
        let reloadedStore = MemoryStore(directory: dir)
        let reloaded = try reloadedStore.loadFacts()
        #expect(reloaded.count == 2)
        #expect(Set(reloaded) == Set(persisted))
        let reloadedById = factsByID(reloaded)
        let reloadedPre = try #require(reloadedById[chain.predecessor.id])
        let reloadedSucc = try #require(reloadedById[chain.successor.id])
        #expect(reloadedPre.lifecycleState == .superseded)
        #expect(reloadedSucc.lifecycleState == .active)
        #expect(reloadedSucc.supersedesFactID == reloadedPre.id)
        #expect(reloadedSucc.revision == reloadedPre.revision + 1)
        #expect(MemoryStore.contentDigest(for: reloadedSucc.text) == reloadedSucc.contentDigest)

        // 活动投影只含 active（canonical 口径；字段实名是 lifecycleState）。
        let active = try store.activeFacts()
        #expect(active.map(\.id) == [chain.successor.id])
        #expect(active.allSatisfy { $0.lifecycleState == .active })
    }

    // MARK: - 2. 导出 → 导入全环（跨会话重绑 scope 后链仍合法）

    @Test("导出含全史；导入到 fresh 会话后链结构存活、投影只剩 active、重放幂等")
    func exportImportRoundTripPreservesChain() throws {
        let exportDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: exportDir) }
        let importDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: importDir) }

        let exporter = makeCenter(dir: exportDir, sessionID: Self.sessionA)
        let chain = try buildLegitChain(
            in: exporter.memoryStore,
            chainTag: "cycle",
            memoryScope: scope(Self.sessionA),
            ownerUserID: Self.ownerID
        )

        // 导出走 strict store 读，必须同时携带前驱与后继（全史，而非活动投影）。
        let payload = try exporter.exportMemoryJSON()
        let exportedFacts = try JSONDecoder().decode([MemoryFact].self, from: payload)
        #expect(exportedFacts.count == 2)
        let exportedById = factsByID(exportedFacts)
        #expect(exportedById[chain.predecessor.id]?.lifecycleState == .superseded)
        #expect(exportedById[chain.successor.id]?.lifecycleState == .active)

        // 导入到不同会话的 fresh 库：entry 层剥离不信任 scope 并重绑当前活动 scope，
        // 链内两事实被绑定到同一 scope，validatePersistedFacts 的相邻/同 scope 校验通过。
        let importer = makeCenter(dir: importDir, sessionID: Self.sessionB)
        #expect(try importer.importMemoryJSON(payload) == MemoryImportResult(added: 2, skipped: 0))
        let importedFacts = try importer.memoryStore.loadFacts()
        #expect(importedFacts.count == 2)
        let importedById = factsByID(importedFacts)
        let importedPre = try #require(importedById[chain.predecessor.id])
        let importedSucc = try #require(importedById[chain.successor.id])
        let reboundScope = scope(Self.sessionB)
        #expect(importedPre.memoryScope == reboundScope)
        #expect(importedSucc.memoryScope == reboundScope)
        #expect(importedPre.lifecycleState == .superseded)
        #expect(importedSucc.lifecycleState == .active)
        #expect(importedSucc.supersedesFactID == importedPre.id)
        #expect(importedSucc.revision == 2 && importedPre.revision == 1)
        // 除 scope 重绑外逐字段无损（含时间戳与全部 provenance）。
        #expect(importedPre.text == chain.predecessor.text)
        #expect(importedPre.createdAt == chain.predecessor.createdAt)
        #expect(importedPre.activatedAt == chain.predecessor.activatedAt)
        #expect(importedPre.sourceSessionID == chain.predecessor.sourceSessionID)
        #expect(importedPre.category == chain.predecessor.category)
        #expect(importedPre.ownerUserID == Self.ownerID)
        #expect(importedPre.sourceProposalID == chain.predecessor.sourceProposalID)
        #expect(importedPre.sourceRef == chain.predecessor.sourceRef)
        #expect(importedPre.contentDigest == chain.predecessor.contentDigest)
        #expect(importedSucc.text == chain.successor.text)
        #expect(importedSucc.createdAt == chain.successor.createdAt)
        #expect(importedSucc.activatedAt == chain.successor.activatedAt)
        #expect(importedSucc.sourceProposalID == chain.successor.sourceProposalID)
        #expect(importedSucc.sourceRef == chain.successor.sourceRef)
        #expect(importedSucc.contentDigest == chain.successor.contentDigest)

        // 全史可见 vs 活动投影（I2-MEMORY-PROJECTION 口径）。
        importer.reloadStorage()
        #expect(importer.memoryFactTotalCount == 2)
        #expect(importer.memoryFacts.map(\.id) == [chain.successor.id])
        #expect(importer.memoryFacts.allSatisfy { $0.lifecycleState == .active })
        let scopedActive = try importer.memoryStore.activeFacts(within: .session(reboundScope))
        #expect(scopedActive.map(\.id) == [chain.successor.id])

        // 再导出可与导入前导出内容级一致（除 scope 已被重绑）。
        let reexported = try JSONDecoder().decode(
            [MemoryFact].self,
            from: try importer.exportMemoryJSON()
        )
        #expect(Set(reexported) == Set(importedFacts))

        // 同一文件重复导入走幂等 receipt：零新增、事实文件不再变化。
        let bytesBeforeReplay = try Data(contentsOf: importer.memoryStore.fileURL)
        #expect(try importer.importMemoryJSON(payload) == MemoryImportResult(added: 0, skipped: 2))
        #expect(try importer.memoryProposalConsumer.restoreReceipts().count == 1)
        #expect(try importer.memoryStore.facts().count == 2)
        #expect(try Data(contentsOf: importer.memoryStore.fileURL) == bytesBeforeReplay)
    }

    // MARK: - 3. consumer restore 三态去重（按稳定 id，命中要求全 payload 相等）

    @Test("consumer restore：no-match 新增、exact 整批回执幂等重放、overlap 冲突 fail-closed")
    func consumerRestoreTriStateMatchesByStableIDOnly() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MemoryStore(directory: dir)
        let consumer = MemoryProposalConsumer(store: store)
        let targetScope = scope(Self.sessionA)

        let fact = MemoryFact(
            id: "restore-exact-0001",
            text: "三态去重测试事实",
            sourceSessionID: "synthetic-origin-session",
            createdAt: Self.baseDate,
            category: .lesson,
            memoryScope: nil,
            ownerUserID: Self.ownerID,
            sourceProposalID: "proposal-restore-exact",
            sourceRef: "memory-test://restore/exact",
            contentDigest: MemoryStore.contentDigest(for: "三态去重测试事实"),
            revision: 1,
            supersedesFactID: nil,
            lifecycleState: .active,
            activatedAt: Self.baseDate
        )

        // no-match：库中无同 id → added 1。
        let first = try consumer.restoreFacts(
            [fact],
            within: targetScope,
            mode: .merge,
            reason: "三态：no-match 新增"
        )
        #expect(first.receipt.added == 1)
        #expect(first.receipt.skipped == 0)

        // exact：同 id + 全 payload 相等（含同一 text）→ 重放同一持久回执，零新增。
        let replay = try consumer.restoreFacts(
            [fact],
            within: targetScope,
            mode: .merge,
            reason: "三态：exact 重放"
        )
        #expect(replay.receipt.restoreID == first.receipt.restoreID)
        #expect(try store.facts().count == 1)
        #expect(try consumer.restoreReceipts().count == 1)

        // 同批内同 id 且等值 → normalize 去重为一条，added 仍为 1。
        let sameIDTextBoth = MemoryFact(
            id: "restore-inbatch-dup-0002",
            text: "同批重复条目",
            sourceSessionID: "synthetic-origin-session",
            createdAt: Self.baseDate,
            category: .fact,
            memoryScope: nil,
            ownerUserID: Self.ownerID,
            sourceProposalID: "proposal-inbatch-dup",
            sourceRef: "memory-test://restore/inbatch",
            contentDigest: MemoryStore.contentDigest(for: "同批重复条目"),
            revision: 1,
            supersedesFactID: nil,
            lifecycleState: .active,
            activatedAt: Self.baseDate
        )
        let dedup = try consumer.restoreFacts(
            [sameIDTextBoth, sameIDTextBoth],
            within: targetScope,
            mode: .merge,
            reason: "三态：同批同 id 等值去重"
        )
        #expect(dedup.receipt.added == 1)
        #expect(try store.facts().count == 2)

        // overlap：同 id + 不同 text → fail-closed `.restoreConflict`，磁盘字节不变。
        let bytesBeforeConflict = try Data(contentsOf: store.fileURL)
        let conflictingText = MemoryFact(
            id: "restore-exact-0001",
            text: "同 id 但文本不同——必须被视为冲突而不是合并",
            sourceSessionID: "synthetic-origin-session",
            createdAt: Self.baseDate,
            category: .lesson,
            memoryScope: nil,
            ownerUserID: Self.ownerID,
            sourceProposalID: "proposal-restore-exact",
            sourceRef: "memory-test://restore/exact",
            contentDigest: MemoryStore.contentDigest(for: "同 id 但文本不同——必须被视为冲突而不是合并"),
            revision: 1,
            supersedesFactID: nil,
            lifecycleState: .active,
            activatedAt: Self.baseDate
        )
        #expect(throws: MemoryProposalConsumerError.restoreConflict) {
            try consumer.restoreFacts(
                [conflictingText],
                within: targetScope,
                mode: .merge,
                reason: "三态：overlap 冲突"
            )
        }
        // restore 在写锁事务内失败时不落新快照：磁盘事实仍只含已入账的 2 条。
        let factsAfterConflict = try Data(contentsOf: store.fileURL)
        #expect(factsAfterConflict == bytesBeforeConflict)
        #expect(try store.facts().count == 2)

        // 测得语义：匹配键只有稳定 id，不存在“按 text 命中”的旁路。
        // 不同 id、完全相同 text → 两条都保留（added 2），不去重。
        let sameTextOtherID = MemoryFact(
            id: "restore-text-twin-0003",
            text: "三态去重测试事实",
            sourceSessionID: "synthetic-origin-session",
            createdAt: Self.baseDate.addingTimeInterval(60),
            category: .lesson,
            memoryScope: nil,
            ownerUserID: Self.ownerID,
            sourceProposalID: "proposal-text-twin",
            sourceRef: "memory-test://restore/text-twin",
            contentDigest: MemoryStore.contentDigest(for: "三态去重测试事实"),
            revision: 1,
            supersedesFactID: nil,
            lifecycleState: .active,
            activatedAt: Self.baseDate.addingTimeInterval(60)
        )
        let twin = try consumer.restoreFacts(
            [sameTextOtherID],
            within: targetScope,
            mode: .merge,
            reason: "测得语义：同 text 不同 id 不合并"
        )
        #expect(twin.receipt.added == 1)
        #expect(try store.facts().count == 3)
    }

    @Test("空 proposal/事实文本 fail-closed：submit 与 restore 均零写入")
    func emptyTextFailsClosedOnBothEntryPaths() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MemoryStore(directory: dir)
        let consumer = MemoryProposalConsumer(store: store)
        let targetScope = scope(Self.sessionA)

        // submit：proposal 文本为空白 → `.invalidText`，不产生任何 envelope。
        #expect(throws: MemoryProposalConsumerError.invalidText) {
            try consumer.submit(
                proposalID: "proposal-empty-text",
                text: "   \n ",
                within: targetScope
            )
        }
        #expect(try consumer.envelopes().isEmpty)

        // restore：批内任一事实文本为空 → `.invalidText`，整批拒绝，事实文件不出现。
        let blankFact = MemoryFact(text: "   ")
        let validFact = MemoryFact(
            id: "restore-valid-with-blank-batch",
            text: "同批里合法的那条"
        )
        #expect(throws: MemoryProposalConsumerError.invalidText) {
            try consumer.restoreFacts(
                [validFact, blankFact],
                within: targetScope,
                mode: .merge,
                reason: "空文本整批 fail-closed"
            )
        }
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        #expect(try store.facts().isEmpty)
        #expect(try consumer.restoreReceipts().isEmpty)
    }

    // MARK: - 4. 非法形状（active-supersedes-active）在持久边界 fail-closed

    @Test("手工拼装的 active-supersedes-active 形状被 strict-load 与 persist 双重拒绝")
    func illegalActiveSupersedesActiveShapeIsRejectedAtPersistence() throws {
        let predecessor = MemoryFact(
            id: "illegal-pre-0001",
            text: "非法形状前驱（仍 active）",
            sourceSessionID: "synthetic-origin-session",
            createdAt: Self.baseDate,
            category: .lesson,
            memoryScope: nil,
            ownerUserID: Self.ownerID,
            sourceProposalID: "proposal-illegal-pre",
            sourceRef: "memory-test://illegal/pre",
            contentDigest: MemoryStore.contentDigest(for: "非法形状前驱（仍 active）"),
            revision: 1,
            supersedesFactID: nil,
            lifecycleState: .active,
            activatedAt: Self.baseDate
        )
        let successorText = "非法形状后继（active 且 supersedes active）"
        let successor = MemoryFact(
            id: "illegal-succ-0002",
            text: successorText,
            sourceSessionID: "synthetic-origin-session",
            createdAt: Self.baseDate.addingTimeInterval(600),
            category: .lesson,
            memoryScope: nil,
            ownerUserID: Self.ownerID,
            sourceProposalID: "proposal-illegal-succ",
            sourceRef: "memory-test://illegal/succ",
            contentDigest: MemoryStore.contentDigest(for: successorText),
            revision: 2,
            supersedesFactID: predecessor.id,
            lifecycleState: .active,
            activatedAt: Self.baseDate.addingTimeInterval(600)
        )
        let illegalBatch = try JSONEncoder().encode([predecessor, successor])
        let targetScope = scope(Self.sessionA)

        // 路径一（strict-load）：把该形状直接伪造到盘上 → 读侧抛
        // `.invalidLifecycleState`（损坏持久化不可被误当成空库）。
        let loadDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: loadDir) }
        try FileManager.default.createDirectory(
            at: loadDir.appendingPathComponent("memory", isDirectory: true),
            withIntermediateDirectories: true
        )
        try illegalBatch.write(
            to: loadDir.appendingPathComponent("memory/facts.json"),
            options: .atomic
        )
        let loadedSide = MemoryStore(directory: loadDir)
        #expect(throws: MemoryStoreError.invalidLifecycleState) {
            try loadedSide.loadFacts()
        }

        // 路径二（persist-time 校验）：从空库出发，经合法 consumer.restoreFacts
        // 注入同一形状 → store 侧 persistUnlocked 的 validatePersistedFacts 拒绝，
        // consumer 映射为 `.restoreConflict`，零写入、无回执。
        let persistDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: persistDir) }
        let persistStore = MemoryStore(directory: persistDir)
        let consumer = MemoryProposalConsumer(store: persistStore)
        #expect(throws: MemoryProposalConsumerError.restoreConflict) {
            try consumer.restoreFacts(
                [predecessor, successor],
                within: targetScope,
                mode: .replace,
                reason: "非法形状经 restore 进入必须 fail-closed"
            )
        }
        #expect(try persistStore.facts().isEmpty)
        #expect(try consumer.restoreReceipts().isEmpty)
    }

    // MARK: - 5. activeFacts(within:) 只返回 active 且按选择器隔离

    @Test("activeFacts(within: scope) 只含 active 事实并按选择器 fail-closed 隔离")
    func scopedActiveProjectionReturnsOnlyActive() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MemoryStore(directory: dir)
        let scopeA = scope(Self.sessionA)
        let scopeB = scope(Self.sessionB)

        let chainA = try buildLegitChain(
            in: store,
            chainTag: "projA",
            memoryScope: scopeA,
            ownerUserID: Self.ownerID
        )
        let chainB = try buildLegitChain(
            in: store,
            chainTag: "projB",
            memoryScope: scopeB,
            ownerUserID: Self.otherOwnerID
        )
        // 全史此刻为 4 条：两条链各含 1 前驱（superseded）+ 1 后继（active）。
        #expect(try store.facts().count == 4)

        // session 选择器：只命中该 scope 的后继，绝不泄漏前驱或别的会话。
        let sessionAView = try store.activeFacts(within: .session(scopeA))
        #expect(sessionAView.map(\.id) == [chainA.successor.id])
        #expect(sessionAView.allSatisfy { $0.lifecycleState == .active })

        // project 选择器：跨会话但同项目 → 两条后继都可见，两条前驱都不可见。
        let projectView = try store.activeFacts(within: .project(projectID: Self.projectID))
        #expect(Set(projectView.map(\.id)) == [chainA.successor.id, chainB.successor.id])
        #expect(projectView.count == 2)
        #expect(projectView.allSatisfy { $0.lifecycleState == .active })

        // user 选择器：owner 精确匹配，仍只含 active。
        let ownerView = try store.activeFacts(within: .user(userID: Self.otherOwnerID))
        #expect(ownerView.map(\.id) == [chainB.successor.id])

        // 无效选择器 fail-closed 返回空，而不是退化为全库投影。
        #expect(try store.activeFacts(within: .project(projectID: "   ")).isEmpty)
        #expect(try store.activeFacts(within: .session(MemoryScope(sessionID: "", projectID: Self.projectID))).isEmpty)
    }
}
