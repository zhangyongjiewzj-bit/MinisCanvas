import Testing
@testable import MinisCanvasApp

@Suite("Child checkpoint review target scope")
struct ChildTaskFileReviewCheckpointScopeTests {
    @Test("Both verified child and full path must match; parent, sibling and same basename are excluded")
    func targetRequiresBothIdentities() {
        let scope = ChildTaskFileReviewCheckpointScope(childTaskID: "child-a", absolutePath: "/work/src/a.swift")
        #expect(scope.contains(childTaskID: "child-a", path: "/work/src/a.swift"))
        #expect(!scope.contains(childTaskID: nil, path: "/work/src/a.swift"))
        #expect(!scope.contains(childTaskID: "child-b", path: "/work/src/a.swift"))
        #expect(!scope.contains(childTaskID: "child-a", path: "/work/other/a.swift"))
        #expect(!scope.contains(childTaskID: "child-a", path: "src/a.swift"))
        #expect(!scope.contains(childTaskID: "child-b", path: "/work/other/a.swift"))
    }
}
