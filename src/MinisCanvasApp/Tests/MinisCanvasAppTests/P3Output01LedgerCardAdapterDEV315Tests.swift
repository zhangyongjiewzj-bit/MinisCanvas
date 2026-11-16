import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

/// P3-OUTPUT-01 · DEV-315「台账→卡片投影适配器」同头判别测试。
///
/// 判别目标（reprobe §1 附带观察的差额面）：`AgentOutputLedgerCardAdapter`
/// 是否把 FileChangeLedger 既有查询 API 的结果，按会话键投影为 244B 卡片
/// 四字段（AgentOutputDiffReference），并可供 AgentOutputCardProjection 消费。
///
/// 断言方法（防 q305 式测试前提错误）：期望值一律由**生产表达式**推导——
/// diffID 用 `FileChangeLedger.stableDiffID/stableChangeID` 现算，
/// insertions/deletions 取 `register` 返回记录（即 DiffRenderer 统计），
/// changedFileCount 由 register 的「同键覆盖保留槽位」分支语义推导。
/// 会话键全部为本文件显式夹具字符串：不创建 ChatStore/BridgeStore，
/// 不依赖任何 bootstrap 会话或 `sessions.first?.id` 回落形态。
/// 台账 confine 为纯词法判定、register 不触盘，本文件不读写真实文件系统。
@Suite("P3-OUTPUT-01 DEV-315 ledger→card projection adapter")
struct P3Output01LedgerCardAdapterDEV315Tests {

    private static let workspaceRoot = "/tmp/minis-p3-output-01-dev315/workspace"
    private static let sessionKey = "11111111-2222-4333-8444-555555555555"
    private static let otherSessionKey = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"

    private static func makeLedger() -> FileChangeLedger {
        FileChangeLedger(workspaceRoot: workspaceRoot)
    }

    /// 生产表达式独立复算 diffID：stableDiffID(sessionID, stableChangeID(相对路径, 写后内容))。
    private static func expectedDiffID(sessionID: String, relativePath: String, newContent: String) -> String {
        FileChangeLedger.stableDiffID(
            sessionID: sessionID,
            changeID: FileChangeLedger.stableChangeID(path: relativePath, newContent: newContent)
        )
    }

    @Test("adapter projects registered ledger record into card four fields via production expressions")
    func adapterProjectsRegisteredRecord() throws {
        let ledger = Self.makeLedger()
        let content = "line-one\nline-two\nline-three\n"
        let record = try ledger.register(
            sessionID: Self.sessionKey,
            path: Self.workspaceRoot + "/notes/dev315.txt",
            kind: .created,
            oldContent: nil,
            newContent: content
        )

        // 期望四字段全部来自生产表达式：
        // diffID=stableDiffID 现算；统计=register 内 DiffRenderer.changeStats 的返回值；
        // changedFileCount=单次登记下 register 去重分支的 matching 计数（1）。
        let expectedDiffID = Self.expectedDiffID(
            sessionID: Self.sessionKey,
            relativePath: "notes/dev315.txt",
            newContent: content
        )
        #expect(record.diffID == expectedDiffID)

        let reference = try #require(
            AgentOutputLedgerCardAdapter.diffReference(
                diffID: expectedDiffID,
                sessionID: Self.sessionKey,
                ledger: ledger
            )
        )
        #expect(reference.diffID == expectedDiffID)
        #expect(reference.changedFileCount == 1)
        #expect(reference.insertions == record.insertions)
        #expect(reference.deletions == record.deletions)
        // 写新建的内容级统计不写死行数（trailing-newline 由生产 splitLines 计行）：
        // 期望值用同一生产表达式 TextDiff+DiffRenderer 现算，防测试前提错误。
        let expectedStats = DiffRenderer.changeStats(TextDiff.diff(old: "", new: content))
        #expect(record.insertions == expectedStats.additions)
        #expect(record.deletions == expectedStats.deletions)
        #expect(expectedStats.additions > 0)
    }

    @Test("adapter output feeds AgentOutputCardProjection as resolved diff with same four fields")
    func adapterFeedsCardProjection() throws {
        let ledger = Self.makeLedger()
        let content = "alpha\nbeta\n"
        let record = try ledger.register(
            sessionID: Self.sessionKey,
            path: Self.workspaceRoot + "/relative-ok.md",
            kind: .created,
            oldContent: nil,
            newContent: content
        )
        // confine 后为工作区相对路径（纯词法，不触盘）。
        #expect(record.path == "relative-ok.md")
        let diffLedger = AgentOutputLedgerCardAdapter.diffLedger(
            diffIDs: [record.diffID],
            sessionID: Self.sessionKey,
            ledger: ledger
        )
        let cardRecord = AgentOutputRecord(
            outputID: "dev315-out-1",
            kind: .file,
            title: "dev315",
            bodyLineCount: 0,
            relativeFilePath: record.path,
            diffID: record.diffID
        )
        let result = AgentOutputCardProjection.project(
            AgentOutputCardProjectionRequest(
                record: cardRecord,
                pageCursor: nil,
                diffLedger: diffLedger,
                workspaceRoot: URL(fileURLWithPath: Self.workspaceRoot, isDirectory: true),
                requestedOpenMode: nil
            ),
            fileExists: { _ in true }
        )
        if case .resolved(let reference) = result.diff {
            #expect(reference == AgentOutputDiffReference(
                diffID: record.diffID,
                changedFileCount: 1,
                insertions: record.insertions,
                deletions: record.deletions
            ))
        } else {
            Issue.record("expected resolved card diff, got \(String(describing: result.diff))")
        }
        // 卡片能力位（四字段消费面）：diffID 在场即暴露 Diff 跳转。
        #expect(result.summary.offersDiffJump)
    }

    @Test("miss, cross-session, empty key and unwired ledger all fail-closed to absent map entries")
    func failClosedPathsLeaveMapEntriesAbsent() throws {
        let ledger = Self.makeLedger()
        let record = try ledger.register(
            sessionID: Self.sessionKey,
            path: "only-here.txt",
            kind: .created,
            oldContent: nil,
            newContent: "x\n"
        )

        // 无该 diffID → nil / 缺席。
        let absentID = FileChangeLedger.stableDiffID(sessionID: Self.sessionKey, changeID: "chg-never")
        #expect(AgentOutputLedgerCardAdapter.diffReference(diffID: absentID, sessionID: Self.sessionKey, ledger: ledger) == nil)

        // 跨会话 → nil（台账隔离键语义，非适配器新造）。
        #expect(AgentOutputLedgerCardAdapter.diffReference(diffID: record.diffID, sessionID: Self.otherSessionKey, ledger: ledger) == nil)

        // 空会话键 → 不发起查询，即使台账里确有记录。
        #expect(AgentOutputLedgerCardAdapter.diffReference(diffID: record.diffID, sessionID: "", ledger: ledger) == nil)
        #expect(AgentOutputLedgerCardAdapter.diffLedger(diffIDs: [record.diffID], sessionID: "", ledger: ledger).isEmpty)

        // 未装配（nil ledger）→ nil / 空 map。
        #expect(AgentOutputLedgerCardAdapter.diffReference(diffID: record.diffID, sessionID: Self.sessionKey, ledger: nil) == nil)
        #expect(AgentOutputLedgerCardAdapter.diffLedger(diffIDs: [record.diffID], sessionID: Self.sessionKey, ledger: nil).isEmpty)

        // 缺席映射到卡片侧既有 .missing（resolver 语义，不伪造零值引用）。
        let resolution = AgentOutputDiffResolver.resolve(
            diffID: record.diffID,
            in: AgentOutputLedgerCardAdapter.diffLedger(
                diffIDs: [record.diffID],
                sessionID: Self.otherSessionKey,
                ledger: ledger
            )
        )
        #expect(resolution == .failure(.missing))
    }

    @Test("re-registration keeps single slot so changedFileCount stays one, new content yields new diffID")
    func reRegistrationSemanticsFollowLedgerProducer() throws {
        let ledger = Self.makeLedger()
        let contentV1 = "v1\n"
        let first = try ledger.register(
            sessionID: Self.sessionKey,
            path: "same-file.txt",
            kind: .created,
            oldContent: nil,
            newContent: contentV1
        )
        // 同 session + 同 path + 同写后内容 → 同 changeID → 同 diffID；
        // register 去重分支覆盖原槽位（不追加），故聚合计数仍为 1。
        _ = try ledger.register(
            sessionID: Self.sessionKey,
            path: "same-file.txt",
            kind: .created,
            oldContent: nil,
            newContent: contentV1
        )
        let repeated = try #require(
            AgentOutputLedgerCardAdapter.diffReference(
                diffID: first.diffID,
                sessionID: Self.sessionKey,
                ledger: ledger
            )
        )
        #expect(repeated.changedFileCount == 1)

        // 写后内容变化 → changeID/diffID 变化；旧 diffID 查询仍命中覆盖后的旧槽？
        // 否：旧 diffID 的槽位未被触碰（覆盖只发生在同键），故旧引用仍可解析，
        // 而新 diffID 是另一条目——两条记录各计各的（与 diffReference 的
        // filter 同键聚合语义一致）。
        let second = try ledger.register(
            sessionID: Self.sessionKey,
            path: "same-file.txt",
            kind: .modified,
            oldContent: contentV1,
            newContent: "v1\nv2\n"
        )
        #expect(second.diffID != first.diffID)
        let newer = try #require(
            AgentOutputLedgerCardAdapter.diffReference(
                diffID: second.diffID,
                sessionID: Self.sessionKey,
                ledger: ledger
            )
        )
        #expect(newer.changedFileCount == 1)
        #expect(newer.insertions == second.insertions)
        #expect(newer.deletions == second.deletions)
        // 批量组装两个 diffID：均命中，map 键即 diffID。
        let map = AgentOutputLedgerCardAdapter.diffLedger(
            diffIDs: [first.diffID, second.diffID],
            sessionID: Self.sessionKey,
            ledger: ledger
        )
        #expect(Set(map.keys) == [first.diffID, second.diffID])
    }
}
