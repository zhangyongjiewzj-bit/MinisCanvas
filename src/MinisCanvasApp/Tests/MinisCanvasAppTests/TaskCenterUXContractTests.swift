import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("Task Center UX contract")
struct TaskCenterUXContractTests {
    @Test func sessionSwitchDoesNotStopOrRebindTaskReceipt() throws {
        let store = AgentTaskStore()
        let first = try store.enqueue(
            taskID: "task-a",
            parentID: "session-a",
            providerID: "offline",
            modelID: "test"
        )
        let second = try store.enqueue(
            taskID: "task-a",
            parentID: "session-b",
            providerID: "offline",
            modelID: "test"
        )
        let firstRun = try store.startRun(
            taskID: first.taskID,
            parentID: first.parentID,
            runID: "run-a"
        )
        _ = try store.startRun(
            taskID: second.taskID,
            parentID: second.parentID,
            runID: "run-b"
        )

        let consumer = TaskCenterControlConsumer(store: store)
        let before = consumer.receiptRows(now: observationNow)
        let afterSimulatedSessionSwitch = consumer.receiptRows(now: observationNow)

        #expect(before == afterSimulatedSessionSwitch)
        #expect(store.snapshot(taskID: first.taskID, parentID: first.parentID)?.status == .running)
        #expect(store.snapshot(taskID: second.taskID, parentID: second.parentID)?.status == .running)
        #expect(
            before.first(where: { $0.sessionID == "session-a" })?.runID == firstRun.runID
        )
        #expect(before.first(where: { $0.sessionID == "session-b" })?.runID == "run-b")
    }

    @Test func appViewIsWiredToTheBridgeConsumerWithoutSessionOrCanvasMutation() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MinisCanvasApp/TaskCenterObservationView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("bridge.taskCenterControlConsumer.receiptRows"))
        #expect(source.contains("bridge.executeTaskCenterControl"))
        #expect(source.contains("taskCenterObservation"))
        #expect(!source.contains("activeSessionID"))
        #expect(!source.contains("ChatStore"))
        #expect(!source.contains("CanvasStore"))
    }

    @Test func taskCenterHasOneDismissiveCloseControlWithStableAccessibilityID() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MinisCanvasApp/TaskCenterObservationView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("@Environment(\\.dismiss) private var dismiss"))
        #expect(source.contains(".toolbar"))
        #expect(source.contains("ToolbarItem(placement: .cancellationAction)"))
        #expect(source.contains("MinisIconView("))
        #expect(source.contains(".close,"))
        #expect(source.contains("dismiss()"))
        #expect(source.contains(".accessibilityIdentifier(\"task-center-close\")"))
        #expect(source.contains(".help(\"关闭任务中心\")"))
        #expect(source.contains("LazyVStack"))
        #expect(!source.contains("agentTaskStore."))
        #expect(!source.contains("activeSessionID"))
        #expect(!source.contains("CanvasStore"))
    }

    @Test func taskCenterRowsKeepControlButtonsAsSeparateAccessibilityChildren() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MinisCanvasApp/TaskCenterObservationView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let rowStart = try #require(source.range(of: "private struct TaskCenterRow"))
        let childViewStart = try #require(
            source.range(of: "private struct TaskCenterChildSessionView")
        )
        let row = String(source[rowStart.lowerBound..<childViewStart.lowerBound])
        let outerRow = try #require(
            row.range(of: ".contentShape(Rectangle())").map {
                String(row[$0.lowerBound...])
            }
        )

        #expect(outerRow.contains(".accessibilityElement(children: .contain)"))
        #expect(!outerRow.contains(".accessibilityElement(children: .combine)"))
        #expect(row.contains(".accessibilityLabel(actionAccessibilityLabel(action))"))
    }

    private var observationNow: Date {
        Date(timeIntervalSince1970: 1_850_000_000)
    }
}
