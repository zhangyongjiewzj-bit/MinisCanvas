import Foundation
import Testing
@testable import MinisCanvasApp

@Suite("D-OUTPUT-02 逐会话文件变更消费")
struct P3AcceptanceM04_FileChangeSessionConsumerTests {
    private func change(_ name: String) -> AgentFileChangeRecord {
        AgentFileChangeRecord(
            id: UUID(),
            path: "/synthetic/\(name).txt",
            kind: .created,
            timestamp: Date(timeIntervalSince1970: 1_000),
            toolName: "file_write",
            diffText: "+\(name)",
            additions: 1,
            deletions: 0,
            diffIsPartial: false
        )
    }

    private func record(_ name: String, sourceSessionID: String?) -> ActionRecord {
        ActionRecord(
            toolName: "file_write",
            argsSummary: "{}",
            resultSummary: "ok",
            fileChange: change(name),
            sourceSessionID: sourceSessionID
        )
    }

    @Test("A/B 原始身份隔离，unknown 不借当前会话归属，限额在筛选后执行")
    func viewerGetsOnlyItsOwnVerifiedChanges() {
        let a = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!.uuidString
        let b = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!.uuidString
        let records = [
            record("a-old", sourceSessionID: a),
            record("a-new", sourceSessionID: a),
            record("b", sourceSessionID: b),
            record("legacy", sourceSessionID: nil),
            record("unbound", sourceSessionID: ""),
        ]

        #expect(
            ChatInspectorFileChangeConsumer.changes(
                from: records, viewerSessionID: a, limit: 1
            ).map(\.path) == ["/synthetic/a-new.txt"]
        )
        #expect(
            ChatInspectorFileChangeConsumer.changes(
                from: records, viewerSessionID: b, limit: 10
            ).map(\.path) == ["/synthetic/b.txt"]
        )
        #expect(ChatInspectorFileChangeConsumer.changes(from: records, viewerSessionID: nil, limit: 10).isEmpty)
        #expect(ChatInspectorFileChangeConsumer.changes(from: records, viewerSessionID: "", limit: 10).isEmpty)
        #expect(ChatInspectorFileChangeConsumer.changes(from: records, viewerSessionID: a, limit: 0).isEmpty)
    }
}
