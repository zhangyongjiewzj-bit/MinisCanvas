import Foundation
import Testing
import MinisCore
@testable import MinisCanvasApp

@Suite("R35 Task Center receipt visibility App contract")
@MainActor
struct R35TaskCenterReceiptVisibilityAppContractTests {
    @Test func productionTaskAndGoalProjectionsShareTheCanonicalStoreAndReceiptIdentity() throws {
        let store = AgentTaskStore()
        let bridge = BridgeStore(agentTaskStore: store)
        let task = try store.enqueue(
            taskID: "r35-receipt-task",
            parentID: "r35-receipt-parent",
            providerID: "offline",
            modelID: "test"
        )
        let run = try store.startRun(
            taskID: task.taskID,
            parentID: task.parentID,
            runID: "r35-receipt-run"
        )
        _ = try store.finish(
            runID: run.runID,
            outcome: .failed(reason: "execution-failed")
        )

        let taskProjection = bridge.taskCenterObservation
        let goalProjection = bridge.taskCenterGoalProjection(now: observationNow)
        let receipt = try #require(
            bridge.taskCenterControlConsumer.receiptRows(now: observationNow).first
        )
        let fact = try #require(
            goalProjection.fact(taskID: task.taskID, parentID: task.parentID)
        )

        #expect(bridge.agentTaskStore === store)
        #expect(
            taskProjection.taskSnapshots.contains {
                $0.taskID == task.taskID && $0.parentID == task.parentID
            }
        )
        #expect(fact.taskID == receipt.taskID)
        #expect(fact.parentID == receipt.parentID)
        #expect(receipt.sessionID == task.parentID)
        #expect(receipt.receiptID == run.runID)
        #expect(receipt.runID == run.runID)
        #expect(receipt.attemptID == "\(run.runID):attempt:1")
        #expect(receipt.effectID == "effect:\(run.runID)")
        #expect(receipt.failureReason == "execution-failed")
        #expect(receipt.retryAvailable)
        #expect(!receipt.cancelAvailable)
        #expect(receipt.stableID == fact.taskCenterStableIDForContract)
    }

    @Test func runningProjectionKeepsCancelIdentityBoundToTheSameTaskAndParent() throws {
        let store = AgentTaskStore()
        let bridge = BridgeStore(agentTaskStore: store)
        let task = try store.enqueue(
            taskID: "r35-cancel-task",
            parentID: "r35-cancel-parent",
            providerID: "offline",
            modelID: "test"
        )
        let run = try store.startRun(
            taskID: task.taskID,
            parentID: task.parentID,
            runID: "r35-cancel-run"
        )
        let receipt = try #require(
            bridge.taskCenterControlConsumer.receiptRows(now: observationNow).first
        )

        #expect(receipt.taskID == task.taskID)
        #expect(receipt.parentID == task.parentID)
        #expect(receipt.receiptID == run.runID)
        #expect(receipt.cancelAvailable)
        #expect(!receipt.retryAvailable)
    }

    @Test func viewConsumesReceiptProjectionWithoutCreatingAnotherTaskFactSource() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MinisCanvasApp/TaskCenterObservationView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        for contract in [
            "bridge.taskCenterObservation",
            "bridge.taskCenterGoalProjection",
            "bridge.taskCenterControlConsumer.receiptRows",
            "receipt.receiptID",
            "receipt.sessionID",
            "receipt.retryAvailable",
            "receipt.cancelAvailable",
            "TaskCenterControlRequest("
        ] {
            #expect(
                source.contains(contract),
                "Missing Task Center production projection contract: \(contract)"
            )
        }

        #expect(!source.contains("AgentTaskStore("))
        #expect(!source.contains("@State var task"))
        #expect(!source.contains("ChatStore"))
        #expect(!source.contains("CanvasStore"))
    }

    private var observationNow: Date {
        Date(timeIntervalSince1970: 1_850_000_000)
    }
}

private extension GoalTaskCenterTaskFact {
    var taskCenterStableIDForContract: String {
        let key = "\(parentID.count):\(parentID)\(taskID.count):\(taskID)"
        return Data(key.utf8).base64EncodedString()
    }
}
