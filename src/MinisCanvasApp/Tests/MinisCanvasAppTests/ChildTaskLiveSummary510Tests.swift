import AppKit
import ApplicationServices
import SwiftUI
import Testing
import MinisCore
@testable import MinisCanvasApp

/// Deliberately not Observable: only the mounted production TimelineView can
/// refresh ledger changes and parent switching in this same hosting window.
@MainActor
private final class Child510Source {
    var store: AgentTaskStore
    var parentID = "parent510"
    init(store: AgentTaskStore) { self.store = store }

    func read() -> TaskSummaryChildProjection {
        TaskSummaryChildProjection(
            currentTaskID: parentID,
            receiptRows: TaskCenterControlConsumer(store: store).receiptRows()
        )
    }
}

@Suite("D-AGENT-08 mounted main-chat child summary consumes live canonical facts")
@MainActor
struct ChildTaskLiveSummary510Tests {
    @Test("same open host shows real transitions without Inspector/Task Center; parent switch and reopen stay scoped")
    func mountedSummaryRefreshesLedgerWithoutObservableMutation() async throws {
        let profile = try #require(RuntimeIsolationProfile.formalTestProfileForDefaultConsumer())
        let root = profile.rootDirectory.appendingPathComponent("child510-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        let url = root.appendingPathComponent("tasks.json")
        let store = try AgentTaskStore(persistenceURL: url)
        let source = Child510Source(store: store)
        for taskID in ["child510-failed", "child510-success", "child510-cancel"] {
            _ = try store.enqueue(taskID: taskID, parentID: source.parentID,
                                  providerID: "synthetic510", modelID: "synthetic-model510")
        }
        _ = try store.enqueue(taskID: "foreign510", parentID: "foreign-parent510",
                              providerID: "synthetic510", modelID: "synthetic-model510")
        func rowIdentifier(_ taskID: String) throws -> String {
            let row = try #require(TaskCenterControlConsumer(store: store).receiptRows().first { $0.taskID == taskID })
            return "chat-child-summary-" + row.stableID
        }
        let frozenBefore = source.read()
        #expect(frozenBefore.rows.count == 3)
        #expect(frozenBefore.runningCount == 0)
        #expect(frozenBefore.rows.allSatisfy { frozenBefore.progressTitle(for: $0) == "进度未知" })

        let lease = NativeTestHostLifecycle.begin("ChildLive510")
        let controller = NSHostingController(rootView: ChatChildTaskSummaryView(readProjection: source.read)
            .frame(width: 720, height: 180))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 180),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        NativeTestHostLifecycle.bind(lease, to: window)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
            NativeTestHostLifecycle.end(window)
        }
        try await expectLabel("chat-child-summary-counts", containing: "子智能体 3 个", in: window)
        try await expectLabel(try rowIdentifier("child510-failed"), containing: "最近：排队", in: window)
        #expect(NativeConsumerOwnedAX.hasNoIdentifier(in: window, prefix: "chat-inspector") == true)
        #expect(NativeConsumerOwnedAX.hasNoIdentifier(in: window, prefix: "task-center") == true)
        #expect(NativeConsumerOwnedAX.hasNoIdentifier(in: window, prefix: try rowIdentifier("foreign510")) == true)

        let first = try store.startRun(taskID: "child510-failed", parentID: source.parentID, runID: "run510-failed")
        let second = try store.startRun(taskID: "child510-success", parentID: source.parentID, runID: "run510-success")
        _ = try store.appendEvent(runID: first.runID, kind: .progress, detail: "synthetic measured event only")
        _ = try store.appendEvent(runID: second.runID, kind: .approvalRequired, detail: "synthetic approval wait")
        try await expectLabel("chat-child-summary-counts", containing: "运行 1 · 待审批 1", in: window)
        try await expectLabel(try rowIdentifier("child510-failed"), containing: "最近：进展", in: window)
        try await expectLabel(try rowIdentifier("child510-success"), containing: "等待审批", in: window)
        // This immutable old projection remains queued. Passing the above AX
        // checks cannot come from manually recomputing and injecting a view value.
        #expect(frozenBefore.runningCount == 0 && frozenBefore.approvalCount == 0)

        _ = try store.finish(runID: first.runID, outcome: .failed(reason: "execution-failed"))
        _ = try store.finish(runID: second.runID, outcome: .succeeded)
        let third = try store.startRun(taskID: "child510-cancel", parentID: source.parentID, runID: "run510-cancel")
        _ = try store.finish(runID: third.runID, outcome: .cancelled)
        try await expectLabel("chat-child-summary-counts", containing: "失败 1 · 完成 1", in: window)
        try await expectLabel(try rowIdentifier("child510-failed"), containing: "失败 · 最近：已失败", in: window)
        try await expectLabel(try rowIdentifier("child510-success"), containing: "结果未记录", in: window)
        try await expectLabel(try rowIdentifier("child510-cancel"), containing: "已取消", in: window)
        let settledBytes = try Data(contentsOf: url)
        let receiptsBeforeRead = store.allReceipts()

        source.parentID = "empty-parent510"
        try await expectAbsent("chat-child-summary", in: window)
        source.parentID = "foreign-parent510"
        try await expectLabel("chat-child-summary-counts", containing: "子智能体 1 个", in: window)
        try await expectLabel(try rowIdentifier("foreign510"), containing: "最近：排队", in: window)
        #expect(try ["child510-failed", "child510-success", "child510-cancel"].allSatisfy {
            NativeConsumerOwnedAX.hasNoIdentifier(in: window, prefix: try rowIdentifier($0)) == true
        })

        source.store = try AgentTaskStore(persistenceURL: url)
        source.parentID = "parent510"
        try await expectLabel("chat-child-summary-counts", containing: "子智能体 3 个", in: window)
        try await expectLabel(try rowIdentifier("child510-failed"), containing: "失败 · 最近：已失败", in: window)
        try await expectLabel(try rowIdentifier("child510-cancel"), containing: "已取消", in: window)
        #expect(source.store.allReceipts() == receiptsBeforeRead)
        #expect(try Data(contentsOf: url) == settledBytes)
        NativeTestHostLifecycle.observe(window, phase: "live-ledger-reopened")
    }

    private func expectLabel(_ identifier: String, containing expected: String,
                             in window: NSWindow) async throws {
        let deadline = Date().addingTimeInterval(4)
        var actual: String?
        var recordedAttributes = false
        repeat {
            window.layoutIfNeeded()
            if let element = NativeConsumerOwnedAX.find(in: window, identifier: identifier) {
                let role = NativeConsumerOwnedAX.role(element)
                let description = NativeConsumerOwnedAX.attribute(element, kAXDescriptionAttribute as CFString) as? String
                let title = NativeConsumerOwnedAX.attribute(element, kAXTitleAttribute as CFString) as? String
                let value = NativeConsumerOwnedAX.attribute(element, kAXValueAttribute as CFString) as? String
                if !recordedAttributes {
                    // This exact synthetic host/identifier is unique in the
                    // complete owned traversal; record public text once only.
                    print("CHILD510_PUBLIC_TEXT identifier=\(identifier) role=\(String(describing: role?.rawValue)) description=\(String(reflecting: description)) title=\(String(reflecting: title)) value=\(String(reflecting: value))")
                    recordedAttributes = true
                }
                switch role {
                case .staticText: actual = value ?? NativeConsumerOwnedAX.label(element)
                case .button: actual = NativeConsumerOwnedAX.label(element)
                default: actual = nil
                }
                if actual?.contains(expected) == true { break }
            }
            try await Task.sleep(for: .milliseconds(50))
        } while Date() < deadline
        #expect(actual?.contains(expected) == true,
                "identifier=\(identifier), expected=\(expected), actual=\(actual ?? "missing")")
    }

    private func expectAbsent(_ prefix: String, in window: NSWindow) async throws {
        let deadline = Date().addingTimeInterval(4)
        var absent: Bool?
        repeat {
            window.layoutIfNeeded()
            absent = NativeConsumerOwnedAX.hasNoIdentifier(in: window, prefix: prefix)
            if absent == true { break }
            try await Task.sleep(for: .milliseconds(50))
        } while Date() < deadline
        #expect(absent == true)
    }
}
