import Foundation
import Testing
@testable import MinisCanvasApp

@Suite("F-TASK-LONG field fixture")
struct TaskPackageFieldFixtureLongTests {
    @Test("long31Navigation4")
    func long31Navigation4() {
        let batch = "selector"
        let ids = TaskPackageFieldFixture.longSampleTaskIDs(batch: batch)

        #expect(ids.count == 35)
        #expect(ids.prefix(31).allSatisfy { $0.hasPrefix("F-TASK-LONG-") })
        #expect(ids[31] == TaskPackageFieldFixture.longNavigationTargetID(batch: batch))
        #expect(ids.suffix(3).allSatisfy { $0.contains("-NAV-") })
    }

    @Test("approval phase opens Task Center before the pending request")
    func approvalPhaseOpensTaskCenterBeforePendingRequest() throws {
        let source = try fixtureSource()
        let openTaskCenter = try #require(
            source.range(of: "bridge.taskCenterOpenIntent = TaskCenterOpenIntent")
        )
        let pendingApproval = try #require(
            source.range(
                of: "async let approval: [SubAgentReport] = launch(.approval, \"approval\")",
                range: openTaskCenter.upperBound..<source.endIndex
            )
        )
        #expect(openTaskCenter.lowerBound < pendingApproval.lowerBound)
        #expect(source[openTaskCenter.upperBound..<pendingApproval.lowerBound]
            .contains("await Task.yield()"))
    }

    private func fixtureSource() throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MinisCanvasApp/TaskPackageFieldFixture.swift")
        return try String(contentsOf: file, encoding: .utf8)
    }
}

extension TaskPackageFieldFixture {
    @Test("long31Navigation4")
    static func long31Navigation4() {
        let ids = longSampleTaskIDs(batch: "selector")
        #expect(ids.count == 35)
        #expect(ids[31] == longNavigationTargetID(batch: "selector"))
    }
}
