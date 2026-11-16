import Foundation
import Testing
@testable import MinisCore

private actor ChildActivityLog {
    var active: Set<String> = []
    var starts = 0
    var finishes = 0
    var startedIDs: Set<String> = []
    var finishedIDs: Set<String> = []
    func observe(_ id: String, running: Bool) {
        if running { active.insert(id); startedIDs.insert(id); starts += 1 }
        else { active.remove(id); finishedIDs.insert(id); finishes += 1 }
    }
    func hasActiveWork() -> Bool { !active.isEmpty }
}
private struct ActivityOnlyRunner: ExternalAgentRunner {
    enum Failure: Error { case synthetic }
    let name = "activity-only"
    let isAvailable = true
    let log: ChildActivityLog
    let fails: Bool
    func run(task: SubAgentTask) async throws -> String {
        #expect(await log.hasActiveWork())
        if fails { throw Failure.synthetic }
        return "done"
    }
}

@Suite("Actual child invocation activity")
struct ChildExecutionActivityTests {
    @Test(arguments: [false, true])
    func pairedObservationSurvivesCompositionAndWaitsForActualBody(fails: Bool) async {
        let log = ChildActivityLog()
        let runner = ActivityOnlyRunner(log: log, fails: fails)
        let original = AgentOrchestrator(externalRunners: [runner.name: runner],
            childExecutionActivityObserver: { id, running in await log.observe(id, running: running) })
        let controlled = original.withChildControls(approvalGate: nil, turnController: nil)
        let result = await controlled.orchestrate(tasks: [SubAgentTask(id: "activity", title: "activity",
            instructions: "synthetic", agentType: .external(name: runner.name))], strategy: .sequential)
        #expect(result.first?.result.isSuccess == !fails)
        #expect(await log.starts == 1)
        #expect(await log.finishes == 1)
        #expect(await log.hasActiveWork() == false)
    }
    @Test func earlyReturnsAndParallelInvocationsKeepBalancedDistinctIDs() async {
        let log = ChildActivityLog()
        let owner = AgentOrchestrator(childExecutionActivityObserver: { id, running in
            await log.observe(id, running: running)
        })
        // No provider: each real invocation exits through the original failure
        // body. Observation must still finish, including under parallel dispatch.
        let reports = await owner.orchestrate(tasks: (1...3).map {
            SubAgentTask(id: "early-\($0)", title: "early", instructions: "synthetic")
        }, strategy: .parallelWithLimit(limit: 3))
        #expect(reports.count == 3 && reports.allSatisfy { !$0.result.isSuccess })
        #expect(await log.startedIDs.count == 3)
        #expect(await log.startedIDs == log.finishedIDs)
        #expect(await log.hasActiveWork() == false)
        let cancelledLog = ChildActivityLog()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await AgentOrchestrator(childExecutionActivityObserver: { id, running in
                await cancelledLog.observe(id, running: running)
            }).orchestrate(tasks: [SubAgentTask(id: "cancelled", title: "cancelled", instructions: "synthetic")])
        }
        _ = await cancelled.value
        #expect(await cancelledLog.startedIDs == cancelledLog.finishedIDs)
        #expect(await cancelledLog.hasActiveWork() == false)
    }

}
