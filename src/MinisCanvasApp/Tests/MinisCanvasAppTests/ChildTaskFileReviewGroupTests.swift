import Testing
@testable import MinisCanvasApp

@Suite("Child task file review grouping")
struct ChildTaskFileReviewGroupTests {
    private func row(_ id: String, child: String?, turn: Int = 1) -> TurnFileChange {
        TurnFileChange(id: id, turnID: turn, path: "src/a.swift", absolutePath: "/workspace/src/a.swift",
            additions: 1, deletions: 1, diff: "@@ -8 +8 @@\n-old\n+new", exceedsExpandedLimit: false,
            sourceIsTruncated: false, childTaskID: child)
    }

    @Test("Same path retains distinct parent, child and repeated receipt rows")
    func ownershipAndRows() {
        let rows = [row("p", child: nil), row("a", child: "parent"),
                    row("b", child: "sibling"), row("a2", child: "parent"), row("other", child: "parent", turn: 2)]
        let groups = ChildTaskFileReviewGroup.capture(rows, turnID: 1)
        #expect(groups.map(\.id) == ["parent", "child:parent", "child:sibling"])
        #expect(groups[1].changes == [rows[1], rows[3]])
        #expect(groups[0].changes == [rows[0]])
        #expect(groups[2].changes == [rows[2]])
        #expect(ChildTaskFileReviewGroup.capture(rows, turnID: nil).isEmpty)
        #expect(ChildTaskFileReviewGroup.capture(rows, turnID: 3).isEmpty)
    }

    @Test("Grouping preserves relative path and deletion comment coordinates")
    func originalDiffSemantics() throws {
        let original = row("a", child: "child")
        let grouped = try #require(ChildTaskFileReviewGroup.capture([original], turnID: 1).first?.changes.first)
        #expect(grouped == original)
        let deleted = try #require(DiffReviewLine.parse(grouped.diff).first { $0.isDeletion })
        #expect(TurnFileChangesProjection.comment(path: grouped.path, line: deleted, text: "保留")
                == "针对 src/a.swift:8（删除前） 的修改意见：保留")
    }
}
