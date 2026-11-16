import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

// P3-OUTPUT-01（DEV-305 接线）：会话旁路突变的台账会话键刷新闭环。
// DEV-304 裁定 GAP：删除/归档当前活跃会话经 ChatStore 旁路回落
// （removeActiveSession :2048-2049 / archiveSession :2751-2752），只触发
// onSessionsChanged（生产仅绑 persistSessions，ChatStore :5235），不经
// performSessionAction 刷新缝（BridgeStore :1029-1030），使生产执行器的
// fileChangeSessionID 滞留已删除/归档会话的旧键，后续生产 file_write 把
// 新活跃会话的改动记到旧会话键下。修复=装配段在 attachPersistence 之后
// 把 onSessionsChanged 包一层，用与 :1029-1030 同源同形表达式刷新。
// 本组测试按 297 生产消费测试口径走同一组合根
// （BridgeStore.attachProductionServices），断言形态按 DEV-304 gap_proof
// §4 方案 3：删除活跃会话后 executor.fileChangeSessionID 等于新活跃会话
// uuidString；归档到无活跃会话按同源表达式语义为空串（未接线、不登记）。
// 修复前第一段断言即 RED（键滞留被删会话旧值）。
// DEV-307（q305 首跑真红归因）：首错 :84 红在测试前提层，不在包装层——
// "回落到 survivor"不是实测生产语义。ChatStore.init :1792-1795 无条件
// 直建 bootstrap 欢迎壳会话并占数组 0 位；删除/归档的回落目标按
// :2049/:2752 是 `sessions.first?.id`，即该壳（本 fixture 的会话目录为
// 全新空目录，RECOVERY-10 :5204 仅在磁盘非空时丢弃未触碰壳）。断言已
// 按实测语义改准为突变前捕获的回落目标（canonical：P3-OUTPUT-01
// 「台账键跟随当期活跃会话」），并新增 survivor 键零记录负断言；
// 未删除、未弱化任何原断言。
@Suite("P3-OUTPUT-01 session bypass mutations refresh ledger session key (DEV-305)")
@MainActor
struct P3Output01SessionBypassKeyRefreshDEV305Tests {

    private struct Fixture {
        let bridge: BridgeStore
        let workspace: URL
        let sessions: URL
    }

    private func makeFixture() -> Fixture {
        let root = FileManager.default.temporaryDirectory
        let workspace = root.appendingPathComponent("dev305-stalekey-ws-\(UUID().uuidString)")
        let sessions = root.appendingPathComponent("dev305-stalekey-sessions-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let bridge = BridgeStore()
        // 与 297 fixture 同款：首个会话沿用 App 启动直建路径，之后的
        // 会话变化经统一生产入口/旁路突变，均为被测形态。
        bridge.chat.applyNewSession()
        bridge.attachProductionServices(
            fileAccessAllowedRoot: workspace,
            fileAccessDeniedRoots: [],
            sessionDirectory: sessions,
            mcpManager: MCPServerManager(
                fileURL: sessions.appendingPathComponent("mcps.json")
            )
        )
        return Fixture(bridge: bridge, workspace: workspace, sessions: sessions)
    }

    private func discard(_ fixture: Fixture) {
        try? FileManager.default.removeItem(at: fixture.workspace)
        try? FileManager.default.removeItem(at: fixture.sessions)
    }

    /// 生产 UI 同款两步确认整形（ChatSidebarView executeDeletion 前置）。
    private func confirmed(_ intent: OperationIntent) -> OperationIntent {
        intent.withFirstConfirmation("已核对这份预览")
            .withSecondConfirmation("永久删除")
    }

    // MARK: - 删除活跃会话（旁路突变）后键必须跟随新活跃会话

    @Test("deleting the active session refreshes the ledger key to the fallback session and later writes register under it")
    func deleteActiveSessionRefreshesLedgerSessionKey() async throws {
        let fixture = makeFixture()
        defer { discard(fixture) }
        let bridge = fixture.bridge
        let chat = bridge.chat
        let ledger = try #require(bridge.productionFileChangeLedger)
        let executor = try #require(bridge.productionBuiltinToolExecutor)

        // 基座：经统一生产入口新建会话后键=当期活跃（297 已证形态）。
        let survivor = try #require(chat.activeSessionID)
        chat.newSession()
        let doomed = try #require(chat.activeSessionID)
        #expect(doomed != survivor)
        #expect(executor.fileChangeSessionID == doomed.uuidString)

        // 旁路突变：删除当前活跃会话（ChatStore :1992 → :2048-2049）。
        // DEV-307 实测语义：回落目标 = :2049 `sessions.first?.id`，即
        // init :1792-1795 直建、仍在数组 0 位的 bootstrap 欢迎壳，不是
        // survivor（磁盘空目录不触发 :5204 的壳丢弃）。修复前 executor 键
        // 滞留 doomed 旧值，本段对回落目标的键断言 RED。
        #expect(chat.sessions.count == 3)
        let fallback = try #require(chat.sessions.first?.id)
        #expect(fallback != doomed)
        #expect(fallback != survivor)
        let intent = try chat.previewDeletion(id: doomed)
        _ = try chat.deleteSession(id: doomed, intent: confirmed(intent))
        #expect(chat.activeSessionID == fallback)
        #expect(executor.fileChangeSessionID == fallback.uuidString)

        // 消费端（gap_proof H5）：删除后直接发消息无需任何会话动作，
        // 真实 file_write 必须按新活跃会话（=实测回落目标）键入账；
        // 被删键与前活跃 survivor 键下均零记录（台账键只跟随当期活跃）。
        let marker = fixture.workspace
            .appendingPathComponent("dev305-after-delete-\(UUID().uuidString).txt")
        let result = try await P3Output01VerifiedFileWriteProbe.execute(
            bridge: bridge,
            input: ["tool_title": "删除后写入探针", "path": marker.path, "content": "after delete\n"]
        )
        let diffID = (try #require(result.components(separatedBy: " [diffID:").last))
            .replacingOccurrences(of: "]", with: "")
        let record = try #require(ledger.record(diffID: diffID, sessionID: fallback.uuidString))
        #expect(record.sessionID == fallback.uuidString)
        #expect(ledger.records(sessionID: doomed.uuidString).isEmpty)
        #expect(ledger.records(sessionID: survivor.uuidString).isEmpty)
    }

    // MARK: - 归档活跃会话后键跟随；归档到无活跃会话按同源表达式置空串

    @Test("archiving sessions follows the fallback to nil with the same expression semantics as the session-action seam")
    func archiveSessionsRefreshLedgerSessionKey() throws {
        let fixture = makeFixture()
        defer { discard(fixture) }
        let bridge = fixture.bridge
        let chat = bridge.chat
        let executor = try #require(bridge.productionBuiltinToolExecutor)

        // 归档当前活跃会话 → DEV-307 实测回落目标 = :2752
        // `sessions.first?.id`（init 直建的 bootstrap 欢迎壳，非 survivor，
        // 口径同删除场景）。:2758 只触发 onSessionsChanged；修复前键滞留
        // archivedActive 旧值，RED。
        let survivor = try #require(chat.activeSessionID)
        chat.newSession()
        let archivedActive = try #require(chat.activeSessionID)
        #expect(archivedActive != survivor)
        #expect(executor.fileChangeSessionID == archivedActive.uuidString)
        #expect(chat.sessions.count == 3)
        let fallback = try #require(chat.sessions.first?.id)
        #expect(fallback != archivedActive)
        #expect(fallback != survivor)
        chat.archiveSession(id: archivedActive)
        #expect(chat.activeSessionID == fallback)
        #expect(executor.fileChangeSessionID == fallback.uuidString)

        // 归档全部会话：生产语义允许归到 0 个（ChatStore :2727 注释），
        // activeSessionID 置 nil；同源表达式（:1029-1030 `?? ""`）语义为
        // 空串=未接线、不登记。非新发明：与装配初值口径一致
        // （BridgeStore :1768-1769「无会话时空串」）。
        for id in chat.sessions.map(\.id) {
            chat.archiveSession(id: id)
        }
        #expect(chat.activeSessionID == nil)
        #expect(executor.fileChangeSessionID == "")
    }

    // MARK: - 启动磁盘对账窗口（DEV-311，reprobe §2b）：非空磁盘装配后键必须跟随最终活跃会话

    // OUTPUT01-SESSKEY-REPROBE §2b/§4：BridgeStore :1774 在 chat.attachPersistence
    // （:2099）之前把键写成 init bootstrap 壳会话 UUID；磁盘快照非空时
    // ChatStore :5204-5228 丢弃未触碰壳并 activeSessionID = restored.first?.id，
    // onSessionsChanged 绑定不触发钩子且包装层在其后才安装 ⇒ 装配完成到首个
    // 会话突变之间键滞留=已丢弃壳（非空、≠活跃会话）。修复=包装层安装语句后
    // 追加一次同源同形初始刷新（BridgeStore :2115 后）。本测试按 297/305/307
    // 先例合同与修复同头交付：修复前第一段断言即 RED（键=壳 uuidString，
    // 且首回合 file_write 记到壳键下、壳键 records 非空）。走同一组合根
    // （attachProductionServices），场景=以同一 sessionDirectory 两次重开。
    @Test("reopening with a non-empty session directory refreshes the ledger key past the discarded bootstrap shell")
    func startupDiskReconciliationRefreshesLedgerSessionKey() async throws {
        let root = FileManager.default.temporaryDirectory
        let workspace = root.appendingPathComponent("dev311-sesskey-ws-\(UUID().uuidString)")
        let sessions = root.appendingPathComponent("dev311-sesskey-sessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: sessions)
        }

        // 1) 首次启动：同目录装配后触发一次会话突变，使 ≥1 会话真实落盘
        //（onSessionsChanged → persistSessions 同步写盘，ChatStore :5235/:5445-5447）。
        var first: BridgeStore? = BridgeStore()
        first!.chat.applyNewSession()
        first!.attachProductionServices(
            fileAccessAllowedRoot: workspace,
            fileAccessDeniedRoots: [],
            sessionDirectory: sessions,
            mcpManager: MCPServerManager(fileURL: sessions.appendingPathComponent("mcps.json"))
        )
        first!.chat.newSession()
        first = nil  // 释放首实例，模拟重启后以同一 sessionDirectory 重开。

        // 2) 重开：捕获装配前的 init 欢迎壳，再走生产装配。
        let bridge = BridgeStore()
        let chat = bridge.chat
        let shell = try #require(chat.activeSessionID)
        bridge.attachProductionServices(
            fileAccessAllowedRoot: workspace,
            fileAccessDeniedRoots: [],
            sessionDirectory: sessions,
            mcpManager: MCPServerManager(fileURL: sessions.appendingPathComponent("mcps.json"))
        )
        let executor = try #require(bridge.productionBuiltinToolExecutor)
        let ledger = try #require(bridge.productionFileChangeLedger)

        // 前置事实：磁盘对账确实发生（非空快照丢弃未触碰壳，:5204/:5227）。
        let active = try #require(chat.activeSessionID)
        #expect(active != shell)
        #expect(chat.sessions.contains(where: { $0.id == active }))
        #expect(!chat.sessions.contains(where: { $0.id == shell }))

        // 验收表达式第一段（reprobe §4）：装配完成即键=当期活跃会话、
        // ≠被丢弃壳。修复前此处 RED：:1774 写入的壳值滞留到首个突变事件。
        #expect(executor.fileChangeSessionID == active.uuidString)
        #expect(executor.fileChangeSessionID != shell.uuidString)

        // 验收表达式第二段：无任何会话动作的首回合生产 file_write 按活跃键
        // 入账，壳键下零记录。修复前登记走的是壳键（ToolExecutor :773 空串
        // guard 对壳值放行、register :194-224 无存在性校验）。
        let marker = workspace
            .appendingPathComponent("dev311-startup-window-\(UUID().uuidString).txt")
        let result = try await P3Output01VerifiedFileWriteProbe.execute(
            bridge: bridge,
            input: ["tool_title": "启动对账后首回合写入探针", "path": marker.path, "content": "startup window\n"]
        )
        let diffID = (try #require(result.components(separatedBy: " [diffID:").last))
            .replacingOccurrences(of: "]", with: "")
        #expect(ledger.record(diffID: diffID, sessionID: active.uuidString) != nil)
        #expect(ledger.records(sessionID: shell.uuidString).isEmpty)
    }
}
