import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("N08 turn changes review")
struct N08TurnFileChangesTests {
    @Test("回合按成功回执隔离，三个文件的计数来自原账本")
    func receiptAndTurnScope() throws {
        let ledger = FileChangeLedger(workspaceRoot: NSTemporaryDirectory())
        let facts = try ToolExecutionFactLedger(persistenceURL: FileManager.default.temporaryDirectory.appendingPathComponent("N08-facts-\(UUID().uuidString).json"))
        for (index, turn) in [1, 1, 1, 2].enumerated() {
            let identity = AgentExecutionIdentity(
                turn: AgentTurnIdentity(sessionID: "review-session", turnID: turn, messageID: "m\(turn)"),
                operationID: "op\(index)", attempt: 1)
            let receipt = try facts.mint(toolCallID: "call\(index)", toolName: "file_write",
                attemptID: "attempt\(index)", attemptNumber: 1, executionIdentity: identity)
            try ledger.register(sessionID: "review-session", path: "review-\(index).txt", kind: .created,
                oldContent: nil, newContent: "line \(index)", producerReceipt: receipt)
            _ = try facts.settle(receipt, status: .succeeded)
        }
        let changes = TurnFileChangesProjection.capture(sessionID: "review-session", ledger: ledger,
            facts: facts.facts, redact: ChatTranscriptRedactor(secretValues: []).redactVisibleConversationBody)
        #expect(changes.filter { $0.turnID == 1 }.count == 3)
        #expect(changes.filter { $0.turnID == 2 }.map(\.path) == ["review-3.txt"])
        #expect(changes.map(\.additions) == [1, 1, 1, 1])
        #expect(changes.map(\.deletions) == [0, 0, 0, 0])
        #expect(TurnFileChangesProjection.capture(sessionID: "another-session", ledger: ledger,
            facts: facts.facts, redact: { $0 }).isEmpty)
        #expect(TurnFileChangesProjection.capture(sessionID: "review-session", ledger: ledger,
            facts: [], redact: { $0 }).isEmpty)
    }

    @Test("删除行与新增行保留各自坐标，评论可直接作为用户消息")
    func lineComments() throws {
        let lines = DiffReviewLine.parse("@@ -8,2 +8,2 @@\n keep\n-old\n+new")
        let removed = try #require(lines.first { $0.text == "-old" })
        let added = try #require(lines.first { $0.text == "+new" })
        #expect(removed.oldLine == 9)
        #expect(removed.newLine == nil)
        #expect(added.newLine == 9)
        #expect(added.oldLine == nil)
        #expect(TurnFileChangesProjection.comment(path: "src/a.swift", line: removed, text: " 请保留 ")
            == "针对 src/a.swift:9（删除前） 的修改意见：请保留")
        #expect(TurnFileChangesProjection.comment(path: "src/a.swift", line: added, text: "改名")
            == "针对 src/a.swift:9 的修改意见：改名")
        #expect(TurnFileChangesProjection.comment(path: "src/a.swift", line: lines[0], text: "意见") == nil)
    }

    @Test("展开预算按UTF8字节切边界，不破坏多字节字符")
    func expansionLimit() {
        let original = String(repeating: "中", count: 24_000)
        let bounded = TurnFileChangesProjection.utf8Prefix(original, bytes: 64 * 1024)
        #expect(bounded.utf8.count == 65_535)
        #expect(bounded.count > 6_000)
        #expect(!bounded.contains("�"))
    }

    private func register(
        ledger: FileChangeLedger, facts: ToolExecutionFactLedger,
        session: String, path: String, content: String, delete: Bool = false
    ) throws {
        let identity = AgentExecutionIdentity(
            turn: AgentTurnIdentity(sessionID: session, turnID: 1, messageID: "message-" + path),
            operationID: "operation-" + path, attempt: 1)
        let receipt = try facts.mint(toolCallID: "call-" + path,
            toolName: delete ? "file_delete" : "file_write", attemptID: "attempt-" + path,
            attemptNumber: 1, executionIdentity: identity)
        try ledger.register(sessionID: session, path: path, kind: delete ? .deleted : .created,
            oldContent: delete ? content : nil, newContent: delete ? nil : content,
            producerReceipt: receipt,
            verifiedDeletedContentSHA256: delete ? String(repeating: "a", count: 64) : nil)
        _ = try facts.settle(receipt, status: .succeeded)
    }

    @Test("脱敏器不可用时即使有成功账本也不显示任何Diff")
    func missingRedactorHidesDiff() throws {
        let ledger = FileChangeLedger(workspaceRoot: NSTemporaryDirectory())
        let facts = try ToolExecutionFactLedger(persistenceURL: FileManager.default.temporaryDirectory.appendingPathComponent("N08-facts-\(UUID().uuidString).json"))
        try register(ledger: ledger, facts: facts, session: "redaction-session",
            path: "nil-redactor.txt", content: "synthetic private content")
        #expect(TurnFileChangesProjection.capture(sessionID: "redaction-session", ledger: ledger,
            facts: facts.facts, redact: nil).isEmpty)
        let redactor = ChatTranscriptRedactor(secretValues: [])
        #expect(TurnFileChangesProjection.capture(sessionID: "redaction-session", ledger: ledger,
            facts: facts.facts, redact: redactor.redactVisibleConversationBody).count == 1)
    }

    @Test("生产脱敏器在6000字符和64KiB边界前处理合成密钥")
    func productionRedactionBeforeBounds() throws {
        let ledger = FileChangeLedger(workspaceRoot: NSTemporaryDirectory())
        let facts = try ToolExecutionFactLedger(persistenceURL: FileManager.default.temporaryDirectory.appendingPathComponent("N08-facts-\(UUID().uuidString).json"))
        let syntheticSecret = "N08_SYNTHETIC_SECRET_ONLY_FOR_TEST"
        let body = String(repeating: "x", count: 5_980) + syntheticSecret
            + String(repeating: "y", count: 59_500) + syntheticSecret
            + String(repeating: "z", count: 100)
        try register(ledger: ledger, facts: facts, session: "secret-session",
            path: "secret-boundary.txt", content: body)
        let redactor = ChatTranscriptRedactor(secretValues: [syntheticSecret])
        let projected = try #require(TurnFileChangesProjection.capture(sessionID: "secret-session",
            ledger: ledger, facts: facts.facts, redact: redactor.redactVisibleConversationBody).first)
        let payload = try #require(ledger.records(sessionID: "secret-session").first.flatMap {
            ledger.diffPayload(diffID: $0.diffID, sessionID: "secret-session")
        })
        let redactedFirst = redactor.redactVisibleConversationBody(payload.unifiedDiff)
        #expect(projected.diff == TurnFileChangesProjection.utf8Prefix(redactedFirst, bytes: 64 * 1024))
        #expect(!projected.diff.contains(syntheticSecret))
        #expect(!projected.diff.contains("N08_SYNTHETIC"))
        #expect(!String(projected.diff.prefix(6_000)).contains("N08_SYNTHETIC"))
        #expect(projected.exceedsExpandedLimit)
    }

    @Test("同一投影入口切换会话仅返回当前会话账本，切回也不混入")
    func switchingSessionDoesNotMixDiffs() throws {
        let ledger = FileChangeLedger(workspaceRoot: NSTemporaryDirectory())
        let facts = try ToolExecutionFactLedger(persistenceURL: FileManager.default.temporaryDirectory.appendingPathComponent("N08-facts-\(UUID().uuidString).json"))
        try register(ledger: ledger, facts: facts, session: "session-a", path: "a.txt", content: "A only")
        try register(ledger: ledger, facts: facts, session: "session-b", path: "b.txt", content: "B only")
        let redactor = ChatTranscriptRedactor(secretValues: [])
        let a = TurnFileChangesProjection.capture(sessionID: "session-a", ledger: ledger,
            facts: facts.facts, redact: redactor.redactVisibleConversationBody)
        let b = TurnFileChangesProjection.capture(sessionID: "session-b", ledger: ledger,
            facts: facts.facts, redact: redactor.redactVisibleConversationBody)
        let aAgain = TurnFileChangesProjection.capture(sessionID: "session-a", ledger: ledger,
            facts: facts.facts, redact: redactor.redactVisibleConversationBody)
        #expect(a.map(\.path) == ["a.txt"])
        #expect(b.map(\.path) == ["b.txt"])
        #expect(aAgain == a)
        #expect(a.allSatisfy { !$0.diff.contains("B only") })
        #expect(b.allSatisfy { !$0.diff.contains("A only") })
    }

    @Test("源删除载荷已截断时标明无法恢复，不承诺64KB完整Diff")
    func sourceTruncatedDeleteIsExplicit() throws {
        let ledger = FileChangeLedger(workspaceRoot: NSTemporaryDirectory())
        let facts = try ToolExecutionFactLedger(persistenceURL: FileManager.default.temporaryDirectory.appendingPathComponent("N08-facts-\(UUID().uuidString).json"))
        try register(ledger: ledger, facts: facts, session: "delete-session",
            path: "deleted.txt", content: String(repeating: "x", count: 7_000), delete: true)
        let redactor = ChatTranscriptRedactor(secretValues: [])
        let change = try #require(TurnFileChangesProjection.capture(sessionID: "delete-session",
            ledger: ledger, facts: facts.facts, redact: redactor.redactVisibleConversationBody).first)
        #expect(change.sourceIsTruncated)
        #expect(change.sourceTruncationNotice == "源已截断，展开不能恢复未保留的内容。")
        #expect(change.expansionLabel == "显示已保留的源片段")
        #expect(!change.exceedsExpandedLimit)
    }

}
