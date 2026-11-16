import Foundation
import Testing
@testable import MinisCanvasApp

@Suite("D-TASK-12 approval navigation consumer")
struct P3AcceptanceM08_TaskApprovalNavigationConsumerTests {
    @Test("task row uses the typed canonical destination with the current pending request")
    func rowDoesNotConstructApprovalDestinationFromStatusText() throws {
        let source = try viewSource()
        let row = try section(
            source,
            from: "private struct TaskCenterRow",
            to: "private struct TaskCenterChildSessionView"
        )

        #expect(row.contains("childTranscriptConsumer.approvalNavigation("))
        #expect(row.contains("pendingRequest: approvalCenter.pendingRequest"))
        #expect(row.contains("TaskCenterApprovalDetailView("))
        #expect(row.contains("NavigationLink"))
        #expect(row.contains("approval-detail-link-"))
        #expect(!row.contains("ApprovalPromptView("))
    }

    @Test("detail refresh rechecks the live prompt and only offers return")
    func detailDropsReplacedOrExpiredPromptWithoutApprovalAction() throws {
        let source = try viewSource()
        let detail = try section(
            source,
            from: "private struct TaskCenterApprovalDetailView",
            to: "private struct TaskCenterSourceSessionView"
        )

        #expect(detail.contains("TimelineView(.periodic"))
        #expect(detail.contains("consumer.pendingApproval("))
        #expect(detail.contains("pendingRequest: approvalCenter.pendingRequest"))
        #expect(detail.contains("待审批请求已失效或不可读取"))
        #expect(detail.contains("Button(\"返回\") { dismiss() }"))
        #expect(detail.contains("approval-detail-return"))
        #expect(!detail.contains("ApprovalPromptView("))
        #expect(!detail.contains("resolve("))
        #expect(!detail.contains("approvePending"))
        #expect(!detail.contains("dismissPending"))
    }

    private func viewSource() throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MinisCanvasApp/TaskCenterObservationView.swift")
        return try String(contentsOf: file, encoding: .utf8)
    }

    private func section(_ source: String, from start: String, to end: String) throws -> String {
        let first = try #require(source.range(of: start))
        let last = try #require(source.range(of: end, range: first.upperBound..<source.endIndex))
        return String(source[first.lowerBound..<last.lowerBound])
    }
}
