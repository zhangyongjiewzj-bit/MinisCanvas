import Foundation
import Testing
@testable import MinisCore

/// P3-OUTPUT-01（DEV-286）：逐文件变更台账生产者测试。
/// 全部使用合成 fixture（假工作区根 + 内存正文），不触真实磁盘与网络。
struct FileChangeLedgerTests {

    private static let root = "/fixture/workspace-root"
    private static let sessionA = "sess-A-0001"
    private static let sessionB = "sess-B-0002"
    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeLedger(capacity: Int = 512) -> FileChangeLedger {
        FileChangeLedger(workspaceRoot: Self.root, capacity: capacity)
    }

    // MARK: - created / modified / deleted 三态与增删行数

    @Test func createdRecordCountsInsertions() throws {
        let ledger = makeLedger()
        let record = try ledger.register(
            sessionID: Self.sessionA,
            path: "/fixture/workspace-root/notes/new.md",
            kind: .created,
            oldContent: nil,
            newContent: "line1\nline2\nline3",
            timestamp: Self.t0
        )
        #expect(record.kind == .created)
        #expect(record.path == "notes/new.md")
        #expect(record.insertions == 3)
        #expect(record.deletions == 0)
        #expect(record.sessionID == Self.sessionA)
        #expect(record.timestamp == Self.t0)
    }

    @Test func modifiedRecordCountsInsertionsAndDeletions() throws {
        let ledger = makeLedger()
        let record = try ledger.register(
            sessionID: Self.sessionA,
            path: "a.txt",
            kind: .modified,
            oldContent: "keep\ndrop-me\n",
            newContent: "keep\nadded\n",
            timestamp: Self.t0
        )
        #expect(record.kind == .modified)
        #expect(record.insertions == 1)  // drop-me → added（行级 replace）
        #expect(record.deletions == 1)
        #expect(record.path == "a.txt")
    }

    @Test func deletedRecordEmptiesContent() throws {
        let ledger = makeLedger()
        let record = try ledger.register(
            sessionID: Self.sessionA,
            path: "gone.txt",
            kind: .deleted,
            oldContent: "x\ny\n",
            newContent: "",
            timestamp: Self.t0
        )
        #expect(record.kind == .deleted)
        #expect(record.deletions >= 2)
        #expect(record.insertions == 0)
        let payload = try #require(ledger.diffPayload(diffID: record.diffID, sessionID: Self.sessionA))
        #expect(payload.unifiedDiff.contains("-x"))
        #expect(payload.unifiedDiff.contains("-y"))
    }

    // MARK: - diffID 稳定性与查回

    @Test func diffIDIsStableForSameSessionAndChangeID() throws {
        let ledger = makeLedger()
        let first = try ledger.register(
            sessionID: Self.sessionA,
            path: "stable.txt",
            kind: .modified,
            oldContent: "one\n",
            newContent: "two\n",
            timestamp: Self.t0
        )
        let second = try ledger.register(
            sessionID: Self.sessionA,
            path: "stable.txt",
            kind: .modified,
            oldContent: "one\n",
            newContent: "two\n",
            timestamp: Self.t0.addingTimeInterval(60)
        )
        // 同一 session + 同一确定性 changeID → 同一 diffID（无随机量）。
        #expect(first.diffID == second.diffID)
        #expect(FileChangeLedger.stableDiffID(sessionID: Self.sessionA, changeID: first.changeID) == first.diffID)
        #expect(FileChangeLedger.stableDiffID(sessionID: Self.sessionA, changeID: first.changeID)
                    == FileChangeLedger.stableDiffID(sessionID: Self.sessionA, changeID: first.changeID))
        // 复登不增长容量（覆盖同一条目）。
        #expect(ledger.count == 1)
    }

    @Test func recordAndPayloadAreQueryableByDiffID() throws {
        let ledger = makeLedger()
        let record = try ledger.register(
            sessionID: Self.sessionA,
            path: "q.md",
            kind: .created,
            oldContent: nil,
            newContent: "hello\nworld\n",
            timestamp: Self.t0
        )
        let fetched = try #require(ledger.record(diffID: record.diffID, sessionID: Self.sessionA))
        #expect(fetched == record)
        let payload = try #require(ledger.diffPayload(diffID: record.diffID, sessionID: Self.sessionA))
        #expect(payload.path == "q.md")
        #expect(payload.insertions == record.insertions)
        #expect(payload.deletions == record.deletions)
        // 正文由现有 DiffRenderer 的 unified+hunk 视图产出（含 hunk 行前缀）。
        #expect(payload.unifiedDiff.contains("+hello"))
        #expect(payload.unifiedDiff.contains("+world"))
    }

    // MARK: - 台账缺失（对齐消费端 .missing）

    @Test func unknownDiffIDReturnsNilForBothQueries() {
        let ledger = makeLedger()
        #expect(ledger.record(diffID: "diff-never-registered", sessionID: Self.sessionA) == nil)
        #expect(ledger.diffPayload(diffID: "diff-never-registered", sessionID: Self.sessionA) == nil)
        #expect(ledger.diffReference(for: "diff-never-registered", sessionID: Self.sessionA) == nil)
    }

    // MARK: - 路径越界拒绝登记

    @Test func outOfBoundsPathsAreRejected() throws {
        let ledger = makeLedger()
        let escapees = [
            "/etc/passwd",                       // 根外绝对路径
            "../outside.txt",                    // 相对逃逸
            "/fixture/workspace-root/../evil.txt", // 词法 .. 逃逸（standardize 后出根）
            "~/.ssh/id_ed25519",                 // 波浪号逃逸
            "~/anywhere",
        ]
        for raw in escapees {
            #expect(throws: FileChangeLedger.RegistrationError.outOfBounds(raw)) {
                try ledger.register(
                    sessionID: Self.sessionA,
                    path: raw,
                    kind: .modified,
                    oldContent: "a",
                    newContent: "b",
                    timestamp: Self.t0
                )
            }
        }
        #expect(ledger.count == 0)
        // 空正文的越界路径同样拒绝（不触盘）。
        #expect(FileChangeLedger.confine(relativeToWorkspaceRoot: "", workspaceRoot: Self.root) == nil)
    }

    // MARK: - 跨 sessionID 隔离

    @Test func sessionsCannotReadEachOtherRecords() throws {
        let ledger = makeLedger()
        let recordA = try ledger.register(
            sessionID: Self.sessionA,
            path: "iso.txt",
            kind: .created,
            oldContent: nil,
            newContent: "A-only\n",
            timestamp: Self.t0
        )
        #expect(ledger.record(diffID: recordA.diffID, sessionID: Self.sessionB) == nil)
        #expect(ledger.diffPayload(diffID: recordA.diffID, sessionID: Self.sessionB) == nil)
        #expect(ledger.records(sessionID: Self.sessionB).isEmpty)
        #expect(ledger.records(sessionID: Self.sessionA).count == 1)
        // 即使 changeID 成分相同，diffID 也随 session 不同而不同。
        let recordB = try ledger.register(
            sessionID: Self.sessionB,
            path: "iso.txt",
            kind: .created,
            oldContent: nil,
            newContent: "A-only\n",
            timestamp: Self.t0
        )
        #expect(recordA.changeID == recordB.changeID)
        #expect(recordA.diffID != recordB.diffID)
    }

    // MARK: - 容量上界与淘汰（FIFO，丢最旧）

    @Test func capacityEvictsOldestFirst() throws {
        let ledger = makeLedger(capacity: 3)
        var ids: [String] = []
        for i in 0..<3 {
            let record = try ledger.register(
                sessionID: Self.sessionA,
                path: "cap/f\(i).txt",
                kind: .created,
                oldContent: nil,
                newContent: "v\(i)\n",
                timestamp: Self.t0
            )
            ids.append(record.diffID)
        }
        #expect(ledger.count == 3)
        let overflow = try ledger.register(
            sessionID: Self.sessionA,
            path: "cap/f3.txt",
            kind: .created,
            oldContent: nil,
            newContent: "v3\n",
            timestamp: Self.t0
        )
        #expect(ledger.count == 3)
        // 最旧的 ids[0] 被淘汰，其余与新登记可查回。
        #expect(ledger.record(diffID: ids[0], sessionID: Self.sessionA) == nil)
        #expect(ledger.diffPayload(diffID: ids[0], sessionID: Self.sessionA) == nil)
        #expect(ledger.record(diffID: ids[1], sessionID: Self.sessionA) != nil)
        #expect(ledger.record(diffID: ids[2], sessionID: Self.sessionA) != nil)
        #expect(ledger.record(diffID: overflow.diffID, sessionID: Self.sessionA) != nil)
    }

    // MARK: - 对 244B 四字段的投影

    @Test func diffReferenceProjectsFourFieldsForConsumer() throws {
        let ledger = makeLedger()
        let record = try ledger.register(
            sessionID: Self.sessionA,
            path: "proj.md",
            kind: .created,
            oldContent: nil,
            newContent: "p\nq\nr\n",
            timestamp: Self.t0
        )
        let view = try #require(ledger.diffReference(for: record.diffID, sessionID: Self.sessionA))
        // AgentOutputDiffReference{diffID, changedFileCount, insertions, deletions}
            // 一一投影：diffID 原样；一次工具调用改一个文件 → 计数 1；增删行数取记录值。
            #expect(view.diffID == record.diffID)
            #expect(view.changedFileCount == 1)
            #expect(view.insertions == record.insertions)
            #expect(view.deletions == record.deletions)
    }
}
